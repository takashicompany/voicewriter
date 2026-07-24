import XCTest
@testable import Voicewriter

/// バグ回帰テスト: whisperモードで録音済み・認識待ち行列中のジョブ(`DictationJob.streamingSession
/// == nil`)があるとき、ユーザーが設定画面/メニューバーでエンジンをSpeechAnalyzerへ切り替えると、
/// 共有の`DynamicTranscriptionEngine`がその時点の設定で`reload()`され、待機中ジョブが実質
/// プレースホルダー(`StubTranscriptionEngine`、ダミーテキスト)で処理されてしまっていたバグの
/// 回帰テスト。
///
/// 修正後は、`Coordinator`が録音開始時点で`TranscriptionEngineSnapshotProviding`(実運用では
/// `DynamicTranscriptionEngine`が準拠)経由に捕捉した「その時点で実際に使われていた実エンジン」を
/// `DictationJob.batchTranscriptionEngine`へ焼き付け、`runJob`はそれを使う(共有の
/// `transcriptionEngine`を直接は呼ばない)。これにより、待ち行列中(=推論FIFOでまだ`transcribe()`が
/// 呼ばれていない段階)に共有エンジンの内部実体が差し替わっても、既に録音済みのジョブは
/// 録音時点の実エンジンで処理され続ける。
///
/// 実際の`DynamicTranscriptionEngine`(whisper.cppモデルの実ファイルロードを伴う)は決定的な
/// テストにしづらいため、`reload()`相当の「内部エンジンを差し替え可能」な挙動と
/// `TranscriptionEngineSnapshotProviding`準拠だけを再現した軽量フェイク(`FakeDynamicEngine`)を使う。
@MainActor
final class CoordinatorEngineSwitchTests: XCTestCase {
    private final class FakeAudioCaptureEngine: AudioCaptureEngineControlling {
        weak var delegate: AudioCaptureEngineDelegate?
        func startRecording() {}
        func stopRecording() {}
        func cancelRecording() {}
    }

    private final class FakeTextInserter: TextInserting {
        private(set) var insertedTexts: [String] = []
        func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
            insertedTexts.append(text)
            onPasted()
        }
    }

    private final class FakeClock {
        private var current = Date(timeIntervalSince1970: 1_700_000_000)
        func now() -> Date {
            defer { current = current.addingTimeInterval(1) }
            return current
        }
    }

    /// 呼び出しごと(callIndex)に完了タイミングを個別に制御できるフェイク`TranscriptionEngine`
    /// (`CoordinatorPipelineTests.MultiCallTranscriptionEngine`と同じ方針)。実運用のwhisper.cpp
    /// エンジンに相当し、FIFO(推論キュー)で複数ジョブが直列に処理される様子を決定的に再現する。
    private actor MultiCallTranscriptionEngine: TranscriptionEngine {
        private(set) var callCount = 0
        private var pendingContinuations: [Int: CheckedContinuation<String, Error>] = [:]

        func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
            callCount += 1
            let index = callCount
            return try await withCheckedThrowingContinuation { continuation in
                pendingContinuations[index] = continuation
            }
        }

        func resume(callIndex: Int, with text: String) {
            pendingContinuations[callIndex]?.resume(returning: text)
            pendingContinuations[callIndex] = nil
        }

        /// `XCTAssertEqual`の引数(autoclosure)内で直接`await`できないため、明示的に値を取り出す。
        func currentCallCount() -> Int { callCount }
    }

    /// 即座に固定テキストを返すフェイク(`DynamicTranscriptionEngine.makeEngine`が
    /// SpeechAnalyzerモード選択時に返す不活性なプレースホルダー`StubTranscriptionEngine`に相当)。
    /// テストごとに異なる`text`を与え、「どの実エンジンで処理されたか」を出力文字列で判別できるようにする。
    private final class ImmediateFixedTextEngine: TranscriptionEngine {
        private let text: String
        init(text: String) { self.text = text }
        func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
            text
        }
    }

    /// `DynamicTranscriptionEngine`の「内部の実エンジンを`reload()`で差し替え可能」
    /// 「`TranscriptionEngineSnapshotProviding`に準拠」という挙動だけを再現した軽量フェイク。
    private final class FakeDynamicEngine: TranscriptionEngine, TranscriptionEngineSnapshotProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var current: TranscriptionEngine

        init(initial: TranscriptionEngine) { current = initial }

        /// `DynamicTranscriptionEngine.reload()`相当: 内部の実エンジンを差し替える。
        func simulateReload(to newEngine: TranscriptionEngine) {
            lock.lock()
            current = newEngine
            lock.unlock()
        }

        func currentEngineSnapshot() -> TranscriptionEngine {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
            try await currentEngineSnapshot().transcribe(
                samples: samples, sampleRate: sampleRate, language: language, vocabularyHint: vocabularyHint, vadEnabled: vadEnabled
            )
        }
    }

    private let nonSilentDummySamples: [Float] = Array(repeating: Float(0.3), count: 4800)

    /// 束縛された(＝ハングし得ない)ポーリング待機。継続を無条件に待つと、修正が壊れて再退行した際に
    /// テストが永久にハングしてしまう(「失敗」ではなく「ハング」はCI上はるかに悪い)ため、
    /// 固定回数の`Task.yield()`で条件成立を待ち、成立しなくても必ず抜ける。
    private func waitUpTo(_ iterations: Int = 400, until condition: () async -> Bool) async {
        for _ in 0..<iterations {
            if await condition() { return }
            await Task.yield()
        }
    }

    /// 核心の回帰テスト: whisperジョブが推論FIFOで待機中(=まだ`transcribe()`が呼ばれていない)に
    /// エンジンがSpeechAnalyzer(スタブ)へ切り替わっても、そのジョブは録音開始時点で捕捉した
    /// whisperエンジンの結果で処理されるべき(切替後の共有エンジン=スタブで処理されてはいけない)。
    ///
    /// 「ジョブ#PRE」を推論FIFOの先頭に置いて未終了のまま保持し、その裏で「ジョブ#1」(whisperモード)を
    /// 録音・終了させる。この時点でジョブ#1はFIFOでまだ待機中(`transcribe()`未呼び出し)。ここで
    /// エンジンを切り替え、その後ジョブ#PREを完了させてFIFOをジョブ#1へ進める、という順序により、
    /// 実際のバグの発生条件(待ち行列中のジョブに対する`reload()`)を再現する。
    func testQueuedWhisperJobStaysOnCapturedEngineAfterMidFlightEngineSwitch() async {
        let audioEngine = FakeAudioCaptureEngine()
        let whisperFake = MultiCallTranscriptionEngine()
        let stubFake = ImmediateFixedTextEngine(text: "STUB PLACEHOLDER TEXT")
        let dynamicEngine = FakeDynamicEngine(initial: whisperFake)
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: dynamicEngine,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        // ジョブ#PRE: whisperモードで録音・停止。推論FIFOの先頭を占有し、認識を保留する(未終端)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await waitUpTo { await whisperFake.currentCallCount() >= 1 }
        let callCountAfterPreStarted = await whisperFake.currentCallCount()
        XCTAssertEqual(callCountAfterPreStarted, 1, "前提: ジョブ#PREの認識が開始しているべき")

        // ジョブ#1: #PREがまだ処理中(未終端)のうちに、whisperモードで録音・停止する。
        // 推論FIFOでは#PREの後ろに並ぶため、この時点ではまだ#1の`transcribe()`は呼ばれていない
        // (=まさに「録音済み・認識待ち行列中」のバグの発生条件)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        // ジョブ#1がFIFOで待機中(#PREの後ろ、まだtranscribe()未呼び出し)のうちに、ユーザーが
        // 設定画面/メニューバーでSpeechAnalyzerへ切り替えたとする
        // (`DynamicTranscriptionEngine.reload()`相当: 共有エンジンの内部実体がstubプレースホルダーへ
        // 差し替わる)。
        dynamicEngine.simulateReload(to: stubFake)

        // ジョブ#PREの認識を完了させる。これによりFIFOがジョブ#1へ進む。
        await whisperFake.resume(callIndex: 1, with: "job pre text")
        await waitUpTo { textInserter.insertedTexts.count >= 1 }
        XCTAssertEqual(textInserter.insertedTexts, ["job pre text"], "前提: ジョブ#PREが先に挿入されているべき")

        // 核心のアサーション: ジョブ#1は録音開始時点(=切替前)で捕捉したwhisperFakeへ実際に
        // 到達しているべき(callCountが2まで進む)。修正前の実装では、ここでジョブ#1は
        // (切替後の)共有エンジン=stubFakeへ即座に到達してしまい、whisperFakeのcallCountは
        // 2まで進まない。
        await waitUpTo { await whisperFake.currentCallCount() >= 2 }
        let callCountAfterJobOneShouldHaveStarted = await whisperFake.currentCallCount()
        XCTAssertEqual(
            callCountAfterJobOneShouldHaveStarted, 2,
            "待ち行列中にエンジンが切り替わっても、ジョブ#1は録音開始時点で捕捉したwhisperエンジンへ" +
            "到達するべき(切替後のstubで即座に処理されてはいけない)"
        )
        XCTAssertEqual(textInserter.insertedTexts, ["job pre text"], "ジョブ#1はまだwhisperFakeの認識完了待ちであるべき")

        // ジョブ#1の認識(録音時点で捕捉したwhisperFake)を完了させる。
        await whisperFake.resume(callIndex: 2, with: "job one text")
        await waitUpTo { textInserter.insertedTexts.count >= 2 }

        XCTAssertEqual(
            textInserter.insertedTexts,
            ["job pre text", "job one text"],
            "待ち行列中にエンジンが切り替わっても、ジョブ#1は録音開始時点で捕捉したwhisperエンジンの" +
            "結果が挿入されるべき(切替後のスタブのダミーテキストで処理されてはいけない)"
        )
    }

    /// 切替後の新規録音は、新しいエンジン(切替後にactiveなもの)の結果を使うべき、という
    /// 「捕捉は録音開始時点固定であって、いつまでも古いエンジンに固定されるわけではない」ことの確認。
    /// (SpeechAnalyzerストリーミングモードのジョブが`batchTranscriptionEngine`の影響を受けないことは
    /// `CoordinatorStreamingPipelineTests`の`MustNotBeCalledTranscriptionEngine`により既に検証されて
    /// いる — `streamingSession`が非nilの経路は本修正で一切変更していない)。
    func testNewRecordingAfterEngineSwitchUsesTheNewlyActiveEngine() async {
        let audioEngine = FakeAudioCaptureEngine()
        let oldFake = ImmediateFixedTextEngine(text: "OLD ENGINE TEXT")
        let newFake = ImmediateFixedTextEngine(text: "NEW ENGINE TEXT")
        let dynamicEngine = FakeDynamicEngine(initial: oldFake)
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: dynamicEngine,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        // 録音開始前に切り替えておく(=次の録音は新しいエンジンを捕捉するべき)。
        dynamicEngine.simulateReload(to: newFake)

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        await waitUpTo { textInserter.insertedTexts.count >= 1 }

        XCTAssertEqual(textInserter.insertedTexts, ["NEW ENGINE TEXT"], "録音開始時点でアクティブなエンジンの結果が使われるべき")
    }
}
