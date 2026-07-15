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
    private let language: String
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

    /// - Parameters:
    ///   - modelURL: ggml-large-v3-turbo.bin 等、ggml形式モデルのパス
    ///   - language: "ja" 等のISO 639-1言語コード、または自動判定の "auto"
    init(modelURL: URL, language: String) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperCppEngineError.modelNotFound(modelURL.path)
        }

        var cparams = whisper_context_default_params()
        cparams.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(modelURL.path, cparams) else {
            throw WhisperCppEngineError.modelLoadFailed(modelURL.path)
        }
        self.context = ctx
        self.language = language

        let versionCString = whisper_version()
        let version = versionCString.map { String(cString: $0) } ?? "unknown"
        log.info("whisper.cpp model loaded from \(modelURL.path, privacy: .public) (whisper.cpp \(version, privacy: .public), language=\(language, privacy: .public))")
    }

    deinit {
        whisper_free(context)
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
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
                    let text = try self.runFull(samples: samples)
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 呼び出し元の`queue`上でのみ実行すること(whisper_fullは同一コンテキストに対して非再入)。
    private func runFull(samples: [Float]) throws -> String {
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

        // suppress_nst(非音声トークン抑制)とno_speech_tholdは、whisper-cliの既定値(false/0.6)ではなく、
        // 本アプリと同じ「プッシュ・トゥ・トークで短い発話単位を都度デコードする」ユースケースの
        // 実装であるHandy(cjpais/Handy、内部でcjpais/transcribe-rsのwhisper.cppラッパーを利用)の
        // 実運用値を採用した。非音声トークンの抑制とno_speech_tholdの引き下げは、いずれも
        // 無音・ノイズ区間での無関係なトークン出力(ハルシネーション)を抑える方向に働く。
        // 一次情報: https://github.com/cjpais/transcribe-rs/blob/main/src/whisper_cpp/mod.rs
        //           (WhisperInferenceParams::default(): suppress_non_speech_tokens=true, no_speech_thold=0.2)
        //           https://github.com/cjpais/Handy/blob/main/src-tauri/src/managers/transcription.rs
        //           (initial_promptにユーザー定義語彙をカンマ区切りで渡している箇所。本実装の語彙ヒントも同じ発想)
        params.suppress_nst = true
        params.no_speech_thold = 0.2

        // "auto" (または空文字) を渡すとwhisper.cpp側で言語自動判定になる。
        let languageForWhisper: String? = (language == "auto") ? nil : language

        // 固有名詞・専門用語の認識精度向上のためのヒント(initial_prompt)。強制ではなくデコーダの
        // 文脈として働く(Amicalの語彙ヒント機能を参考)。設定は呼び出しごとに読むため、
        // エンジン再ロードなしで次回の文字起こしから反映される。
        let vocabularyHint = Settings.sttVocabularyHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptForWhisper: String? = vocabularyHint.isEmpty ? nil : vocabularyHint

        // VAD(Voice Activity Detection、既定OFF)。有効化されておりモデルが配置済みの場合のみ使う。
        // whisper.cpp v1.9.1でwhisper_full_params自体にVADが統合されており、無音/非音声区間を
        // 検出して発話区間だけをデコードすることで、末尾無音でのハルシネーション
        // (例: https://github.com/ggml-org/whisper.cpp/issues/1724 )を軽減できるとされる。
        // 一次情報: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/README.md#voice-activity-detection-vad
        let vadModelPath: String? = Settings.vadEnabled && Self.isVadModelAvailable()
            ? Self.defaultVadModelURL.path
            : nil
        if Settings.vadEnabled, vadModelPath == nil {
            log.warning("VAD is enabled but model not found at \(Self.defaultVadModelURL.path, privacy: .public); proceeding without VAD")
        }
        params.vad = (vadModelPath != nil)
        params.vad_params = whisper_vad_default_params()

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

        var text = ""
        for i in 0..<segmentCount {
            if let cText = whisper_full_get_segment_text(context, i) {
                text += String(cString: cText)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
