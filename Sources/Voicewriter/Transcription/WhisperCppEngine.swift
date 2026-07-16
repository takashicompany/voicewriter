import Foundation
import os.log
import whisper

enum WhisperCppEngineError: Error, CustomStringConvertible {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case transcriptionFailed

    var description: String {
        switch self {
        case .modelNotFound(let path):
            return "whisper.cpp model not found at \(path)"
        case .modelLoadFailed(let path):
            return "whisper.cpp failed to load model at \(path)"
        case .transcriptionFailed:
            return "whisper.cpp transcription failed"
        }
    }
}

/// whisper.cpp (ggml-large-v3-turbo) を使った文字起こしエンジン。
/// アプリ起動時に一度モデルをロードし、以後インスタンスを保持し続ける想定(常駐)。
/// `whisper_full` はコンテキスト単位で非再入のため、内部で専用のシリアルキューを介して呼び出す。
final class WhisperCppEngine: TranscriptionEngine, @unchecked Sendable {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "WhisperCppEngine")
    private let context: OpaquePointer
    private let queue = DispatchQueue(label: "dev.voicewriter.whispercpp", qos: .userInitiated)

    /// モデル配置ディレクトリ (~/Library/Application Support/Voicewriter/models)
    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Voicewriter/models", isDirectory: true)
    }

    static let modelFilename = "ggml-large-v3-turbo.bin"

    static var defaultModelURL: URL {
        modelsDirectory.appendingPathComponent(modelFilename)
    }

    /// 指定パスにモデルファイルが存在するか(サイズ0のファイル等、明らかに不完全なものは除く)
    static func isModelAvailable(at url: URL = defaultModelURL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else {
            return false
        }
        // ggml-large-v3-turbo.bin は約1.6GB。極端に小さいファイルは壊れたダウンロードとみなす。
        return size > 100_000_000
    }

    /// VAD(Voice Activity Detection、既定OFFの任意機能)用のSilero-VADモデルファイル名。
    /// `scripts/download-vad-model.sh`で`modelsDirectory`に配置する。
    static let vadModelFilename = "ggml-silero-v5.1.2.bin"

    static var defaultVadModelURL: URL {
        modelsDirectory.appendingPathComponent(vadModelFilename)
    }

    /// 指定パスにVADモデルファイルが存在するか(明らかに不完全なものは除く)。
    /// ggml-silero-v5.1.2.binは約885KB。
    static func isVadModelAvailable(at url: URL = defaultVadModelURL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else {
            return false
        }
        return size > 500_000
    }

    /// VAD既定ON化に伴い、モデル未配置環境での警告ログをアプリ寿命中1回だけに抑制するためのフラグ。
    nonisolated(unsafe) private static var hasWarnedMissingVadModel = false

    /// - Parameters:
    ///   - modelURL: ggml-large-v3-turbo.bin 等、ggml形式モデルのパス
    init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperCppEngineError.modelNotFound(modelURL.path)
        }

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(modelURL.path, cparams) else {
            throw WhisperCppEngineError.modelLoadFailed(modelURL.path)
        }
        self.context = ctx

        let versionCString = whisper_version()
        let version = versionCString.map { String(cString: $0) } ?? "unknown"
        log.info("whisper.cpp model loaded from \(modelURL.path, privacy: .public) (whisper.cpp \(version, privacy: .public))")
    }

    deinit {
        whisper_free(context)
    }

    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
        guard !samples.isEmpty else {
            throw TranscriptionError.emptyAudio
        }
        if sampleRate != 16000 {
            log.warning("transcribe called with sampleRate=\(sampleRate, privacy: .public); whisper.cpp expects 16kHz mono")
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: TranscriptionError.emptyAudio)
                    return
                }
                do {
                    let text = try self.runFull(samples: samples, language: language, vocabularyHint: vocabularyHint, vadEnabled: vadEnabled)
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 呼び出し元の`queue`上でのみ実行すること(whisper_fullは同一コンテキストに対して非再入)。
    private func runFull(samples: [Float], language: String, vocabularyHint: String, vadEnabled: Bool) throws -> String {
        // AlwaysOnモードのプリロールに混入した発話前ノイズがハルシネーションを誘発しないよう、
        // 先頭の低エネルギー区間をトリムしてから渡す(AudioPreprocessing.swift参照)。
        let trimmedSamples = AudioPreprocessing.trimLeadingSilence(samples: samples, sampleRate: 16000)

        // whisper.cpp本家CLI(whisper-cli, v1.9.1)の既定値に合わせる。
        // 一次情報:
        //   https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/src/whisper.cpp (whisper_full_default_params:
        //     WHISPER_SAMPLING_BEAM_SEARCH は beam_search.beam_size=5 が既定)
        //   https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/examples/cli/cli.cpp
        //     (params.beam_size の既定値がそのまま5であり、`beam_size > 1` なので
        //      whisper-cliは常時ビームサーチをデフォルトで使っている。以前の実装は
        //      WHISPER_SAMPLING_GREEDYを常時強制しており、本家の既定挙動と乖離していた)
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.translate = false
        params.no_context = true
        params.single_segment = false

        params.beam_search.beam_size = 5
        // temperatureフォールバック(下記)で温度>0になり多項分布サンプリングに切り替わった際、
        // ビームサーチではなくgreedy.best_of本の候補を生成して最良のものを選ぶ経路を通る
        // (whisper.cpp内部の温度フォールバック実装)。beam_search.beam_size同様5に設定しないと
        // 既定の0のままになり、フォールバック時の候補数が意図せず変わってしまうため明示的に設定する。
        // 一次情報: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/examples/cli/cli.cpp#L31-L82
        //           (whisper-cliは`wparams.greedy.best_of = params.best_of`を常に設定しており、
        //            `params.best_of`の既定値も5)
        params.greedy.best_of = 5

        // temperature/temperature_incはOpenAI Whisper由来のtemperatureフォールバック
        // (貪欲/ビームでの結果が下記閾値を満たさない場合、0.2刻みで温度を上げて再デコードする仕組み)。
        // ここまではwhisper.cpp既定値と同一だが、バージョン間の既定値変化に依存しないよう明示的に設定する。
        params.suppress_blank = true
        params.temperature = 0.0
        params.temperature_inc = 0.2
        params.entropy_thold = 2.4
        params.logprob_thold = -1.0

        // suppress_nst(非音声トークン抑制)は引き続き有効にする。一方でno_speech_tholdは
        // whisper-cli既定値の0.6に戻した(以前はHandyの実運用値0.2を採用していたが、
        // 無音・誤押下ハルシネーション対策の見直しの過程でwhisper.cpp本体のソース
        // (src/whisper.cpp、`is_no_speech`判定)を確認したところ、no_speech_tholdは単独では
        // 効かず、`no_speech_prob > no_speech_thold && avg_logprobs < logprob_thold`の
        // **複合条件**でのみそのセグメントの出力自体を抑制する実装だった。自信を持って
        // (=avg_logprobsが高いまま)生成されるハルシネーション定型句はこの複合条件の
        // avg_logprobs側を満たさないため、no_speech_tholdをいくら下げても抑制効果がない
        // (実測でも、無音のみのWAVに対しno_speech_thold=0.2のままハルシネーションが
        // 再現することを確認した)。それでいて閾値を下げると、本来は不確実なだけの
        // 正当な小声発話まで誤って抑制されるリスクだけが増える。そのため、この対策は
        // VAD(第3層)・エネルギーゲート(第2層)・セグメント単位no_speech_probフィルタ(第4層)・
        // 既知フレーズフィルタ(第5層)に委ね、no_speech_thold自体はwhisper-cli既定値に戻した。
        // 一次情報: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/src/whisper.cpp
        //   (`is_no_speech = (state->no_speech_prob > params.no_speech_thold &&
        //     best_decoder.sequence.avg_logprobs < params.logprob_thold)`、
        //     この条件がtrueの場合のみそのデコード結果を`result_all`へ出力しない)
        params.suppress_nst = true
        params.no_speech_thold = 0.6

        // "auto" (または空文字) を渡すとwhisper.cpp側で言語自動判定になる。
        let languageForWhisper: String? = (language == "auto") ? nil : language

        // 固有名詞・専門用語の認識精度向上のためのヒント(initial_prompt)。強制ではなくデコーダの
        // 文脈として働く(Amicalの語彙ヒント機能を参考)。呼び出し元(ジョブの設定スナップショット)
        // から渡されたものをそのまま使う(待ち行列中の設定変更の影響を受けないようにするため)。
        let trimmedVocabularyHint = vocabularyHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptForWhisper: String? = trimmedVocabularyHint.isEmpty ? nil : trimmedVocabularyHint

        // ハルシネーション対策(多層防御)の第3層: VAD(Voice Activity Detection、既定ON)。
        // 有効化されておりモデルが配置済みの場合のみ使う。whisper.cpp v1.9.1で
        // whisper_full_params自体にVADが統合されており、無音/非音声区間を検出して発話区間だけを
        // デコードすることで、発話区間が全く検出されなければ空文字を返す(=末尾/全体無音での
        // ハルシネーション、例: https://github.com/ggml-org/whisper.cpp/issues/1724 を軽減できる)。
        // 一次情報: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/README.md#voice-activity-detection-vad
        let vadModelPath: String? = vadEnabled && Self.isVadModelAvailable()
            ? Self.defaultVadModelURL.path
            : nil
        if vadEnabled, vadModelPath == nil {
            // 既定ONに変更したため、モデル未配置環境では毎回警告が出て冗長になる。
            // アプリの寿命中に1回だけ出せば十分な情報のため、以後は抑制する。
            if !Self.hasWarnedMissingVadModel {
                Self.hasWarnedMissingVadModel = true
                log.warning("VAD is enabled but model not found at \(Self.defaultVadModelURL.path, privacy: .public); proceeding without VAD (run scripts/download-vad-model.sh to enable)")
            }
        }
        params.vad = (vadModelPath != nil)
        var vadParams = whisper_vad_default_params()
        // speech_pad_ms(検出した発話区間の前後に足す余白)は既定30msから100msへ引き上げた。
        // VADを既定ONに変更し露出が増えたため、語頭の子音・語尾の音が短く削られて
        // 認識精度が落ちるリスクを避けるための安全マージンを広めに取った
        // (他のVADパラメータ(threshold=0.5, min_speech_duration_ms=250,
        //  min_silence_duration_ms=100)はwhisper.cpp既定値のまま)。
        vadParams.speech_pad_ms = 100
        params.vad_params = vadParams

        // デバッグ用: 隠し設定が有効な場合、whisper_fullに渡す直前(先頭無音トリム後)の
        // 16kHz/mono/Float32サンプルをWAVとして保存する。公式whisper-cliとの同一入力比較や、
        // マイク入力パイプラインの音質検証に使う(既定OFF、Settings.debugSaveLastRecordingEnabled参照)。
        if Settings.debugSaveLastRecordingEnabled {
            let url = Settings.debugRecordingURL
            do {
                try WavWriter.write(samples: trimmedSamples, sampleRate: 16000, to: url)
                log.info("Debug: saved pre-whisper_full recording to \(url.path, privacy: .public)")
            } catch {
                log.error("Debug: failed to save pre-whisper_full recording WAV: \(error.localizedDescription, privacy: .public)")
            }
        }

        let result: Int32 = withOptionalCString(languageForWhisper) { languageCString in
            withOptionalCString(promptForWhisper) { promptCString in
                withOptionalCString(vadModelPath) { vadModelPathCString in
                    params.language = languageCString
                    params.initial_prompt = promptCString
                    params.vad_model_path = vadModelPathCString
                    return trimmedSamples.withUnsafeBufferPointer { buffer in
                        whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                    }
                }
            }
        }

        guard result == 0 else {
            throw WhisperCppEngineError.transcriptionFailed
        }

        let segmentCount = whisper_full_n_segments(context)
        guard segmentCount > 0 else { return "" }

        // ハルシネーション対策(多層防御)の第4層: セグメント単位のno_speech_prob(このセグメントが
        // 無音/非音声である確率)を取得し、閾値以上のセグメントは出力から除外する。
        // `no_speech_thold`パラメータ(上記、decode時の温度フォールバック判定に使われる)とは別に、
        // whisper.cpp v1.9.1はセグメントごとの実測確率をAPI越しに公開しており
        // (`whisper_full_get_segment_no_speech_prob`)、デコード結果に対する後段フィルタとして使える。
        // 一次情報: vendor/whisper.xcframework内のwhisper.h
        //   (`WHISPER_API float whisper_full_get_segment_no_speech_prob(...)`、
        //    コメント「Get the no_speech probability for the specified segment」)
        var segments: [(text: String, noSpeechProb: Float)] = []
        segments.reserveCapacity(Int(segmentCount))
        for i in 0..<segmentCount {
            let segmentText = whisper_full_get_segment_text(context, i).map { String(cString: $0) } ?? ""
            let noSpeechProb = whisper_full_get_segment_no_speech_prob(context, i)
            segments.append((text: segmentText, noSpeechProb: noSpeechProb))
        }

        let filtered = Self.filterSegments(segments)
        if filtered.excludedCount > 0 {
            log.info("Excluded \(filtered.excludedCount, privacy: .public) of \(segmentCount, privacy: .public) segment(s) with high no_speech_prob (threshold=\(Self.segmentNoSpeechProbThreshold, privacy: .public))")
        }
        return filtered.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// セグメント単位のno_speech_prob(このセグメントが無音/非音声である確率)フィルタの閾値。
    /// VoiceInk(https://github.com/Beingpax/VoiceInk )の実装調査(値のみ参考、コード引用なし)で
    /// 60%(0.6)超のセグメントを棄却していることを確認したため、同じ値を採用した。
    static let segmentNoSpeechProbThreshold: Float = 0.6

    /// `runFull`から分離した純粋関数。セグメント一覧(テキスト・no_speech_prob)を受け取り、
    /// 閾値以上のno_speech_probを持つセグメントを除外して残りを連結する(単体テスト用に切り出し)。
    static func filterSegments(
        _ segments: [(text: String, noSpeechProb: Float)],
        threshold: Float = segmentNoSpeechProbThreshold
    ) -> (text: String, excludedCount: Int) {
        var text = ""
        var excludedCount = 0
        for segment in segments {
            if segment.noSpeechProb >= threshold {
                excludedCount += 1
                continue
            }
            text += segment.text
        }
        return (text, excludedCount)
    }
}

/// `Optional<String>`をネストした`withCString`越しに扱うためのヘルパー。
/// `nil`の場合はポインタも`nil`のまま`body`を呼ぶ(whisper_full_paramsの`language`/`initial_prompt`は
/// どちらも`nil`許容のconst char*)。
private func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    if let string {
        return string.withCString(body)
    }
    return body(nil)
}
