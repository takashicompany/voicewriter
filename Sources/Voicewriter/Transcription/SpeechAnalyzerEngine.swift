@preconcurrency import AVFoundation
import Foundation
import Speech
import os.log

/// Apple SpeechAnalyzer/SpeechTranscriber(macOS 26+)によるストリーミング文字起こしエンジン。
///
/// PoC(`Sources/VerifySpeechAnalyzer/main.swift`、`scripts/fixtures/*.wav`で実機確認済み)で
/// 確認したAPIの使い方を踏襲する:
/// - `SpeechTranscriberFactory`が用意する**プレビュー用**(`reportingOptions:
///   [.volatileResults, .fastResults]`)と**確定用**(`reportingOptions: []`)の2モジュールを、
///   それぞれ独立した`SpeechAnalyzer`(1アナライザー1モジュール)に載せる(`Settings.
///   streamingPreviewEnabled`がfalseの場合はプレビュー用のアナライザー/モジュール自体を生成せず
///   確定用のみの1アナライザー構成にフォールバックする)。2モジュールを単一の`SpeechAnalyzer`に
///   同居させる構成は採用していない。詳細・実機で確認した理由は`SpeechTranscriberFactory`の
///   ドキュメントコメント参照。プレビュー用モジュールの結果はライブ表示イベント専用で挿入テキストには
///   使わず、確定用モジュールの`isFinal`結果のみを`finish()`の戻り値(挿入テキスト)の元にする。
/// - `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`で送出すべきPCMフォーマットを取得し、
///   `AVAudioConverter`で変換してから`AnalyzerInput`として送出する。プレビュー用アナライザーが
///   あれば、変換済みバッファを複製(`duplicateBuffer`)して両アナライザーへfan-outする
/// - 各モジュールの`results`をそれぞれ独立に購読し、`result.isFinal`で確定/未確定(volatile)を判定する
///
/// **セッションごとに新しい`SpeechAnalyzer`/`SpeechTranscriber`インスタンスを生成する**設計にしている。
/// 連続音声入力パイプライン(前の発話の処理中でも次の録音を即座に開始できる)と両立させるため、
/// 複数の録音が時間的に重なりうる(前の発話の`finish()`がまだ完了していないのに次の録音の
/// `makeSession()`が呼ばれる)ケースを、単一の共有`SpeechAnalyzer`インスタンスで直列化してしまうと
/// 破綻する。`SpeechAnalyzer.Options(modelRetention: .processLifetime)`を指定することで、
/// Swiftオブジェクト自体はセッションごとに使い捨てでも、内部のモデル資産はプロセス生存中
/// 保持され続け、2回目以降のセッションでモデル再ロードのコストを払わずに済む
/// (一次情報: `Speech.swiftinterface`の`SpeechAnalyzer.Options.ModelRetention`)。
@available(macOS 26.0, *)
final class SpeechAnalyzerEngine: StreamingTranscriptionEngine {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "SpeechAnalyzerEngine")
    private let locale: Locale

    init(locale: Locale) {
        self.locale = locale
    }

    func makeSession(onEvent: @escaping @Sendable (StreamingTranscriptionEvent) -> Void) -> StreamingTranscriptionSession {
        SpeechAnalyzerSession(locale: locale, log: log, onEvent: onEvent)
    }
}

enum StreamingTranscriptionError: Error {
    /// `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`が互換フォーマットを返さなかった。
    case noCompatibleAudioFormat
}

/// スレッドセーフな真偽値フラグ。`finish()`/`cancel()`の「一度だけ実行」保証に使う。
/// Codexレビュー指摘#8: 以前は`get()`(確認)と`set()`(反映)が別々のロック区間だったため、
/// 2つの呼び出しが競合すると両方とも「まだfalseだった」と判定してしまい、二重にteardown処理が
/// 走りうった。`setIfNotAlreadySet()`で確認と反映を単一のロック区間内にまとめ、アトミックにする。
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// 現在falseなら`true`にしてtrueを返す(=呼び出し元がこの遷移の実行権を得た)。
    /// 既にtrueならfalseを返す(既に他の呼び出しが実行権を得ている)。
    @discardableResult
    func setIfNotAlreadySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !value else { return false }
        value = true
        return true
    }

    /// 単純な無条件セット(`cancelFlag`のように、二重セット自体は問題にならない用途向け)。
    func set() {
        lock.lock(); value = true; lock.unlock()
    }

    func get() -> Bool {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// 確定(finalized)テキストと未確定(volatile)テキストの累積、およびバックグラウンド処理中に
/// 発生したエラー(最初の1件)を保持するアクター。各`SpeechTranscriber`モジュールの`results`購読Task・
/// フォーマット変換ループ・`analyzer.start`の各Task(いずれも書き込み元)と、`finish()`(読み出し元)
/// の両方からアクセスされるため、データレースを避けるためアクターとして分離している。
///
/// 2モジュール構成(`SpeechTranscriberFactory`参照)に伴い、**確定用**モジュールが集計する
/// `finalizedText`(挿入テキストの元、`finish()`が返す値)と、**プレビュー用**モジュールが集計する
/// `previewFinalizedText`/volatileテキスト(ライブ表示専用、挿入には一切使わない)を明確に分離している。
private actor StreamingSessionState {
    /// 確定用モジュール(`.fastResults`なし)の`isFinal`結果から集計した、挿入に使う確定テキスト。
    private(set) var finalizedText = ""
    /// プレビュー用モジュール(`.fastResults`あり)から集計した、表示専用の確定済みテキスト。
    /// `.fastResults`の精度影響を受けうるため、このテキストは挿入には使わない。
    private(set) var previewFinalizedText = ""
    /// バックグラウンド処理中に発生した最初のエラー。`finish()`はこれを検出したら例外として
    /// 呼び出し元(Coordinator)へ伝播させる(Codexレビュー指摘#5: 以前はログに警告を出すだけで
    /// 飲み込んでおり、部分的な(または空の)テキストが成功扱いで挿入・無音扱いされ得た)。
    /// プレビュー用モジュールのエラーは挿入結果に影響しないため、ここには記録しない
    /// (`run()`内のプレビュー購読Taskのcatch節を参照。ログ出力のみに留める)。
    private(set) var firstError: Error?

    /// 確定用モジュールの`isFinal`結果を集計する。挿入に使われる`finalizedText`(`finish()`の
    /// 戻り値)を更新する、この構成における唯一の書き込み経路。
    func recordAuthoritativeFinal(_ text: String) {
        finalizedText += text
    }

    /// プレビュー用モジュールの`isFinal`結果を集計する(表示専用)。
    @discardableResult
    func recordPreviewFinal(_ text: String) -> (finalizedText: String, volatileText: String) {
        previewFinalizedText += text
        return (previewFinalizedText, "")
    }

    /// プレビュー用モジュールのvolatile(未確定)結果を反映する(表示専用)。
    func recordPreviewVolatile(_ text: String) -> (finalizedText: String, volatileText: String) {
        (previewFinalizedText, text)
    }

    func recordError(_ error: Error) {
        if firstError == nil {
            firstError = error
        }
    }
}

/// 1回分の録音に対応するストリーミングセッション。`append`はオーディオキャプチャの
/// `controlQueue`(同期シリアルキュー)から直接呼ばれるため、即座に返る同期関数にしている。
/// 実際のSpeechAnalyzerセットアップ(非同期)・フォーマット変換・送出は内部のバックグラウンドTaskで
/// 行い、`append`はそのTaskへ生サンプルをバッファリング(`AsyncStream`)するだけにとどめる。
@available(macOS 26.0, *)
final class SpeechAnalyzerSession: StreamingTranscriptionSession, @unchecked Sendable {
    private let log: Logger
    private let rawContinuation: AsyncStream<(samples: [Float], sampleRate: Double)>.Continuation
    private let state = StreamingSessionState()
    private let cancelFlag = LockedFlag()
    private let finishedFlag = LockedFlag()
    private let workTask: Task<Void, Error>

    init(locale: Locale, log: Logger, onEvent: @escaping @Sendable (StreamingTranscriptionEvent) -> Void) {
        self.log = log
        let (stream, continuation) = AsyncStream<(samples: [Float], sampleRate: Double)>.makeStream()
        self.rawContinuation = continuation

        let stateRef = state
        let cancelFlagRef = cancelFlag
        let logRef = log
        workTask = Task {
            try await Self.run(
                locale: locale,
                rawStream: stream,
                state: stateRef,
                cancelFlag: cancelFlagRef,
                onEvent: onEvent,
                log: logRef
            )
        }
    }

    func append(samples: [Float], sampleRate: Double) {
        guard !finishedFlag.get() else { return }
        rawContinuation.yield((samples, sampleRate))
    }

    /// 録音終了(通常終了)を通知し、確定済みの最終テキストが得られるまで待つ。
    /// バックグラウンド処理中にエラーが発生していた場合はそれを再送出する(Codexレビュー指摘#5)。
    func finish() async throws -> String {
        guard finishedFlag.setIfNotAlreadySet() else {
            // 既にfinish()/cancel()済み。二重呼び出しは冪等に扱い、現時点の確定テキストを返す。
            return await state.finalizedText
        }
        rawContinuation.finish()
        try await workTask.value
        if let error = await state.firstError {
            throw error
        }
        return await state.finalizedText
    }

    func cancel() {
        guard finishedFlag.setIfNotAlreadySet() else { return }
        cancelFlag.set()
        rawContinuation.finish()
    }

    // MARK: - Background work (makeSession/appendを同期的に即座に返すためのバックグラウンド処理)

    private static func run(
        locale: Locale,
        rawStream: AsyncStream<(samples: [Float], sampleRate: Double)>,
        state: StreamingSessionState,
        cancelFlag: LockedFlag,
        onEvent: @escaping @Sendable (StreamingTranscriptionEvent) -> Void,
        log: Logger
    ) async throws {
        // 確定用モジュールは常に生成する(`finish()`の戻り値の唯一の元)。プレビュー用モジュールは
        // `Settings.streamingPreviewEnabled`がtrueの場合のみ追加で生成する(設定でライブプレビューを
        // OFFにすると、確定用のみの1モジュール構成になりCPU/メモリ負荷を抑えられる)。
        let finalTranscriber = SpeechTranscriberFactory.makeFinalTranscriber(locale: locale)
        let previewEnabled = Settings.streamingPreviewEnabled
        let previewTranscriber: SpeechTranscriber? = previewEnabled
            ? SpeechTranscriberFactory.makePreviewTranscriber(locale: locale)
            : nil
        let modules: [any SpeechModule] = previewTranscriber.map { [$0, finalTranscriber] } ?? [finalTranscriber]
        log.info("SpeechAnalyzerSession module configuration: previewEnabled=\(previewEnabled, privacy: .public) moduleCount=\(modules.count, privacy: .public)")

        // モデル資産(言語モデル)が未インストールなら、ここで自動的にダウンロード/インストールする
        // (Codexレビュー指摘#7: 以前は設定画面の手動ボタンからしか`SpeechModelProvisioner`が
        // 呼ばれず、「初回使用時に自動的にダウンロードが始まる」という設定UI上の説明文と実装が
        // 不一致だった)。進捗は`onEvent(.preparing(progress:))`でライブプレビューパネルへ中継する。
        // 実際に使う全モジュールをまとめて渡す(`SpeechTranscriberFactory`のドキュメントコメント参照)。
        try await Self.ensureModelInstalled(modules: modules, onEvent: onEvent, log: log)

        // 実機検証(macOS 26.4.1)により、プレビュー用+確定用を同一`SpeechAnalyzer`に同居させる構成
        // (Appleの`volatileRange`ドキュメントが言及する構成)は、この端末では確定用モジュールが
        // `.fastResults`を持たないことに全体が引きずられ、プレビュー用モジュール側の逐次(volatile)
        // 配信までもが`finalizeAndFinishThroughEndOfInput()`後のバースト配信に劣化する
        // (=ライブプレビューが一切表示されない、元の実機バグの再発)ことを
        // `SpeechAnalyzerEngineIntegrationTests.testVolatileUpdateArrivesWhileStillFeedingBeforeFinishIsCalled`
        // で確認した。そのため、各モジュールを独立した`SpeechAnalyzer`に載せ、同一の音声供給を
        // fan-out(バッファを複製して両方へ送出)する構成にしている。`results`購読自体は各
        // `SpeechTranscriber`インスタンス独立のシーケンスであるため変更不要。
        let finalAnalyzer = SpeechAnalyzer(
            modules: [finalTranscriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let previewAnalyzer: SpeechAnalyzer? = previewTranscriber.map { previewTranscriber in
            SpeechAnalyzer(
                modules: [previewTranscriber],
                options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
            )
        }

        // フォーマットは両モジュールをまとめて渡して決定する(同一locale/transcriptionOptionsのため
        // 実質同じ値になるが、`SpeechAnalyzer`インスタンスが分かれても互換フォーマットの決定自体は
        // モジュール単位の性質であり、分析器の分割とは独立している)。
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw StreamingTranscriptionError.noCompatibleAudioFormat
        }
        try await finalAnalyzer.prepareToAnalyze(in: analyzerFormat)
        if let previewAnalyzer {
            try await previewAnalyzer.prepareToAnalyze(in: analyzerFormat)
        }

        let (finalInputStream, finalInputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let previewInputPair: (stream: AsyncStream<AnalyzerInput>, continuation: AsyncStream<AnalyzerInput>.Continuation)? =
            previewAnalyzer != nil ? AsyncStream<AnalyzerInput>.makeStream() : nil

        // (d) 結果購読: 確定用モジュールの`isFinal`結果のみを`state.finalizedText`(`finish()`の
        // 戻り値、挿入テキストの元)へ集計する。エラーは`state`へ記録し、最終的に`finish()`から
        // 呼び出し元へ伝播させる(ログだけに留めない、Codexレビュー指摘#5)。
        let finalResultsTask = Task {
            do {
                for try await result in finalTranscriber.results {
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                    await state.recordAuthoritativeFinal(text)
                }
            } catch {
                log.warning("final SpeechTranscriber.results ended with error: \(String(describing: error), privacy: .public)")
                await state.recordError(error)
            }
        }

        // プレビュー用モジュールがあれば、その結果(volatile/final問わず)をライブ表示イベントとして
        // 中継する。この結果は表示専用であり、`state.finalizedText`(挿入テキスト)には一切書き込まない。
        // プレビュー用モジュールの購読でエラーが起きても、確定用モジュールの結果には影響しないため
        // (両モジュールは独立した`results`シーケンスを持つ)、ログに留め`state.recordError`へは
        // 記録しない(表示が止まるだけで、挿入テキストの正しさには影響させない)。
        let previewResultsTask: Task<Void, Never>? = previewTranscriber.map { previewTranscriber in
            Task {
                do {
                    for try await result in previewTranscriber.results {
                        let text = String(result.text.characters)
                        let snapshot: (finalizedText: String, volatileText: String)
                        if result.isFinal {
                            snapshot = await state.recordPreviewFinal(text)
                        } else {
                            snapshot = await state.recordPreviewVolatile(text)
                        }
                        onEvent(.update(finalizedText: snapshot.finalizedText, volatileText: snapshot.volatileText))
                    }
                } catch {
                    log.warning("preview SpeechTranscriber.results ended with error: \(String(describing: error), privacy: .public)")
                }
            }
        }

        let finalAnalyzeTask = Task {
            try await finalAnalyzer.start(inputSequence: finalInputStream)
        }
        let previewAnalyzeTask: Task<Void, Error>? = previewAnalyzer.map { previewAnalyzer in
            Task {
                try await previewAnalyzer.start(inputSequence: previewInputPair!.stream)
            }
        }

        // 生サンプル(16kHz/mono/Float32)をanalyzerFormatへ変換して送出する。
        // 呼び出し元(Coordinator/AudioCaptureEngine)は常に同一のsampleRate/チャンネル数で
        // 呼んでくるため、コンバータはループ内で使い回す(初回のみ生成)。
        var converter: AVAudioConverter?
        var converterSourceFormat: AVAudioFormat?
        for await (samples, sampleRate) in rawStream {
            // Codexレビュー指摘#4: cancel()後、バッファ済みの全チャンクを変換・送出してから
            // ようやくcancelAndFinishNowへ進んでいたため、キャンセルの即応性が低かった。
            // ループの各反復でフラグを確認し、キャンセル済みなら残りのチャンクは処理せず即座に抜ける。
            if cancelFlag.get() { break }
            guard !samples.isEmpty else { continue }
            guard let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else { continue }

            if converter == nil || converterSourceFormat != sourceFormat {
                converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
                converter?.sampleRateConverterQuality = .max
                converterSourceFormat = sourceFormat
            }
            guard let converter else { continue }
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
            sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress, let dst = sourceBuffer.floatChannelData?[0] else { return }
                dst.update(from: base, count: samples.count)
            }

            let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outCapacity) else { continue }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return sourceBuffer
            }
            guard status != .error else {
                if let conversionError {
                    log.error("SpeechAnalyzerSession: audio conversion error: \(conversionError.localizedDescription, privacy: .public)")
                }
                continue
            }
            guard outBuffer.frameLength > 0 else { continue }
            // 確定用アナライザーへ送出する。プレビュー用アナライザーがあれば、同じ音声を
            // (バッファを複製して)fan-outする。`AVAudioPCMBuffer`は参照型かつ変更されうるため、
            // 2つの独立したアナライザーへ安全に渡すには複製が必要(2アナライザー構成、上記コメント参照)。
            if let previewInputPair {
                if let duplicate = Self.duplicateBuffer(outBuffer) {
                    previewInputPair.continuation.yield(AnalyzerInput(buffer: duplicate))
                } else {
                    log.warning("SpeechAnalyzerSession: failed to duplicate audio buffer for preview analyzer fan-out")
                }
            }
            finalInputContinuation.yield(AnalyzerInput(buffer: outBuffer))
        }
        finalInputContinuation.finish()
        previewInputPair?.continuation.finish()

        if cancelFlag.get() {
            await finalAnalyzer.cancelAndFinishNow()
            if let previewAnalyzer {
                await previewAnalyzer.cancelAndFinishNow()
            }
        } else {
            do {
                try await finalAnalyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                log.warning("final analyzer finalizeAndFinishThroughEndOfInput failed: \(String(describing: error), privacy: .public)")
                await state.recordError(error)
            }
            if let previewAnalyzer {
                do {
                    try await previewAnalyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    // プレビュー用アナライザーの失敗は表示専用の不具合に留まるため、`state.recordError`
                    // へは記録せず(挿入テキストの成否には影響させない)、ログのみ残す。
                    log.warning("preview analyzer finalizeAndFinishThroughEndOfInput failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        do {
            try await finalAnalyzeTask.value
        } catch {
            log.warning("final analyzer.start ended with error: \(String(describing: error), privacy: .public)")
            await state.recordError(error)
        }
        if let previewAnalyzeTask {
            do {
                try await previewAnalyzeTask.value
            } catch {
                log.warning("preview analyzer.start ended with error: \(String(describing: error), privacy: .public)")
            }
        }

        _ = await finalResultsTask.value
        if let previewResultsTask {
            _ = await previewResultsTask.value
        }
    }

    /// `buffer`の内容を新しい`AVAudioPCMBuffer`へバイト単位で複製する(2アナライザーへの音声fan-out用)。
    /// `floatChannelData`ベースだとcommonFormatがInt16等の場合にnilを返すため、`sliceBuffer`
    /// (`Sources/VerifySpeechAnalyzer/main.swift`)と同様、フォーマットに依存しない
    /// `audioBufferList`(生バイト列)ベースでコピーする。
    private static func duplicateBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let duplicate = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else { return nil }
        duplicate.frameLength = buffer.frameLength

        let srcListPointer = buffer.audioBufferList
        let dstListPointer = duplicate.mutableAudioBufferList
        let srcBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: srcListPointer))
        let dstBuffers = UnsafeMutableAudioBufferListPointer(dstListPointer)

        for i in 0..<min(srcBuffers.count, dstBuffers.count) {
            let srcBuf = srcBuffers[i]
            guard let srcData = srcBuf.mData else { continue }
            guard let dstData = dstBuffers[i].mData else { continue }
            memcpy(dstData, srcData, Int(srcBuf.mDataByteSize))
            dstBuffers[i].mDataByteSize = srcBuf.mDataByteSize
        }
        return duplicate
    }

    /// モデル資産(言語モデル)が未インストールなら自動的にダウンロード/インストールする。
    /// 既にインストール済みなら即座に返る(通常の2回目以降の録音はこの分岐がほぼゼロコスト)。
    /// `modules`にはそのセッションで実際に使う全モジュール(プレビュー用+確定用、または確定用のみ)を渡す。
    private static func ensureModelInstalled(
        modules: [any SpeechModule],
        onEvent: @escaping @Sendable (StreamingTranscriptionEvent) -> Void,
        log: Logger
    ) async throws {
        let status = await AssetInventory.status(forModules: modules)
        guard status != .installed else { return }

        onEvent(.preparing(progress: 0))
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            // 追加のダウンロードが不要(既にインストール済み、またはこの環境では不要)。
            return
        }

        let progress = request.progress
        let progressPollTask = Task {
            while !progress.isFinished, !Task.isCancelled {
                onEvent(.preparing(progress: progress.fractionCompleted))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { progressPollTask.cancel() }

        try await request.downloadAndInstall()
        log.info("SpeechAnalyzer model asset installed on first use")
    }
}
