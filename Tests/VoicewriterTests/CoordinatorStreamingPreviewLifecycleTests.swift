import XCTest
@testable import Voicewriter

/// テスト用のフェイク`AudioCaptureEngineControlling`実装(他のCoordinatorテストと同じ方針)。
private final class FakeAudioCaptureEngine: AudioCaptureEngineControlling {
    weak var delegate: AudioCaptureEngineDelegate?
    func startRecording() {}
    func stopRecording() {}
    func cancelRecording() {}
}

private final class FakeClock {
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    private let step: TimeInterval
    init(step: TimeInterval = 1.0) { self.step = step }
    func now() -> Date {
        defer { current = current.addingTimeInterval(step) }
        return current
    }
}

private final class FakeTextInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
        insertedTexts.append(text)
        onPasted()
    }
}

private final class MustNotBeCalledTranscriptionEngine: TranscriptionEngine {
    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
        XCTFail("SpeechAnalyzerストリーミングモードではwhisper.cpp(TranscriptionEngine.transcribe)を呼んではいけない")
        return "should-not-be-used"
    }
}

/// 呼ばれるまで待て、任意のタイミングで完了させられるフェイク`TranscriptionEngine`。
private actor GatedTranscriptionEngine: TranscriptionEngine {
    private var callCount = 0
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var startedCallIndices: Set<Int> = []
    private var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
        callCount += 1
        let index = callCount
        startedCallIndices.insert(index)
        startWaiters[index]?.resume()
        startWaiters[index] = nil
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
        }
    }

    func waitUntilCallStarted(_ index: Int) async {
        if startedCallIndices.contains(index) { return }
        await withCheckedContinuation { continuation in startWaiters[index] = continuation }
    }

    func resume(callIndex: Int, with text: String) {
        pending[callIndex]?.resume(returning: text)
        pending[callIndex] = nil
    }
}

/// 呼ばれるまで待て、任意のタイミングで完了させられるフェイク`TextFormatter`。
/// 「録音終了〜挿入完了」の間(=整形中)にプレビューが消えていないことを確認するための足場。
private actor GatedTextFormatter: TextFormatter {
    private var callCount = 0
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var startedCallIndices: Set<Int> = []
    private var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func format(text: String, vocabularyHint: String, model: String, timeoutSeconds: TimeInterval) async throws -> String {
        callCount += 1
        let index = callCount
        startedCallIndices.insert(index)
        startWaiters[index]?.resume()
        startWaiters[index] = nil
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
        }
    }

    func waitUntilCallStarted(_ index: Int) async {
        if startedCallIndices.contains(index) { return }
        await withCheckedContinuation { continuation in startWaiters[index] = continuation }
    }

    func resume(callIndex: Int, with text: String) {
        pending[callIndex]?.resume(returning: text)
        pending[callIndex] = nil
    }
}

private final class FakeStreamingTranscriptionSession: StreamingTranscriptionSession, @unchecked Sendable {
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0
    var finishResult: Result<String, Error> = .success("")

    func append(samples: [Float], sampleRate: Double) {}

    func finish() async throws -> String {
        finishCallCount += 1
        return try finishResult.get()
    }

    func cancel() { cancelCallCount += 1 }
}

private final class FakeStreamingTranscriptionEngine: StreamingTranscriptionEngine, @unchecked Sendable {
    private(set) var makeSessionCallCount = 0
    private(set) var lastSession: FakeStreamingTranscriptionSession?
    private(set) var lastOnEvent: (@Sendable (StreamingTranscriptionEvent) -> Void)?

    func makeSession(onEvent: @escaping @Sendable (StreamingTranscriptionEvent) -> Void) -> StreamingTranscriptionSession {
        makeSessionCallCount += 1
        let session = FakeStreamingTranscriptionSession()
        lastSession = session
        lastOnEvent = onEvent
        return session
    }
}

private let nonSilentDummySamples: [Float] = Array(repeating: Float(0.3), count: 4800)

/// ライブプレビューの表示ライフサイクル(仕様変更「生成中もプレビューを残す」)の回帰テスト。
///
/// 変更前: キーを離した瞬間(`didFinishRecording`)に`onStreamingPreviewHide`でフェードアウトし、
/// その後に新しい認識イベントが届いた場合しか再表示されなかったため、整形〜挿入までの数秒間
/// プレビューが消えていた。
///
/// 変更後の仕様:
/// 1. キーを離してもプレビューは消さず、`onStreamingPreviewProcessing`(「変換中…」表示)に切り替える
/// 2. 実際に隠すのはジョブの終端(挿入完了/フォーカス不一致/失敗/キャンセル/スキップ)の時点。
///    挿入は`DeliveryCoordinator`が非同期に行うため、認識・整形の完了時点(`runJob`の終了)では隠さない
/// 3. 世代管理は維持: 新しい録音が始まって世代が追い越された古いジョブの終端では隠さない
///    (新しい録音のプレビューを誤って消さないため)
/// 4. whisper(バッチ)モードの挙動は変えない
@MainActor
final class CoordinatorStreamingPreviewLifecycleTests: XCTestCase {
    private func flushMainActorQueue(iterations: Int = 50) async {
        for _ in 0..<iterations { await Task.yield() }
    }

    private var originalSttEngine: SttEngineKind = .whisperCpp
    private var originalFormattingEnabled = true

    override func setUp() {
        super.setUp()
        originalSttEngine = Settings.sttEngine
        originalFormattingEnabled = Settings.formattingEnabled
    }

    override func tearDown() {
        Settings.sttEngine = originalSttEngine
        Settings.formattingEnabled = originalFormattingEnabled
        super.tearDown()
    }

    /// 核心の回帰テスト: 録音終了(キーを離した時点)ではプレビューを隠さず「変換中」表示に切り替え、
    /// 実際に隠すのは挿入が完了した後であること。
    func testPreviewStaysVisibleDuringFormattingAndHidesOnlyAfterInsertion() async {
        Settings.sttEngine = .speechAnalyzer
        Settings.formattingEnabled = true

        let audioEngine = FakeAudioCaptureEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let formatter = GatedTextFormatter()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: MustNotBeCalledTranscriptionEngine(),
            streamingEngine: streamingEngine,
            textFormatter: formatter,
            textInserter: textInserter,
            now: FakeClock().now,
            dictionaryProvider: { [] }
        )

        var previewHideCount = 0
        var processingCount = 0
        /// プレビューを隠した各時点で「既に挿入が済んでいた件数」。挿入完了より前に隠していないことの確認用。
        var insertedCountsAtHide: [Int] = []
        coordinator.onStreamingPreviewHide = {
            previewHideCount += 1
            insertedCountsAtHide.append(textInserter.insertedTexts.count)
        }
        coordinator.onStreamingPreviewProcessing = { processingCount += 1 }

        await coordinator.beginPushToTalk()
        // 新しい録音の開始時点で残存プレビューを隠すのは従来通り(世代管理の維持)。
        let hideCountAfterRecordingStart = previewHideCount
        guard let session = streamingEngine.lastSession else {
            return XCTFail("session should have been created")
        }
        session.finishResult = .success("認識テキスト")
        streamingEngine.lastOnEvent?(.update(finalizedText: "認識テキスト", volatileText: ""))
        await flushMainActorQueue()

        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        // 整形(LLM)に入ったところで止める = 「録音は終わったがまだ挿入されていない」状態。
        await formatter.waitUntilCallStarted(1)
        await flushMainActorQueue()

        XCTAssertEqual(processingCount, 1, "録音終了時は『変換中』表示へ切り替えるべき")
        XCTAssertEqual(
            previewHideCount, hideCountAfterRecordingStart,
            "キーを離した時点ではプレビューを隠してはいけない(整形〜挿入の間も表示を残す)"
        )
        XCTAssertTrue(textInserter.insertedTexts.isEmpty, "この時点ではまだ挿入されていないはず(テストの前提)")

        await formatter.resume(callIndex: 1, with: "整形済みテキスト")
        for _ in 0..<400 where textInserter.insertedTexts.isEmpty { await Task.yield() }
        await flushMainActorQueue()

        XCTAssertEqual(textInserter.insertedTexts, ["整形済みテキスト"])
        XCTAssertEqual(
            previewHideCount, hideCountAfterRecordingStart + 1,
            "ジョブの終端(挿入完了)でちょうど1回だけプレビューを隠すべき"
        )
        XCTAssertEqual(
            insertedCountsAtHide.last, 1,
            "プレビューを隠すのは挿入が完了した後であるべき(挿入前に消えてはいけない)"
        )
    }

    /// 挿入を伴わない終端(ハルシネーション対策の第1層でスキップ)でも、ジョブの終端時点で
    /// 確実にプレビューが隠れること(出しっぱなしにならないこと)。
    func testPreviewHidesWhenJobTerminatesWithoutInsertion() async {
        Settings.sttEngine = .speechAnalyzer

        let audioEngine = FakeAudioCaptureEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: MustNotBeCalledTranscriptionEngine(),
            streamingEngine: streamingEngine,
            textInserter: textInserter,
            // 押下〜離しを0.1秒(最短録音時間0.3秒未満)としてスキップさせる。
            now: FakeClock(step: 0.1).now,
            dictionaryProvider: { [] }
        )

        var previewHideCount = 0
        var processingCount = 0
        var committed: [DictationJobCommitEvent] = []
        coordinator.onStreamingPreviewHide = { previewHideCount += 1 }
        coordinator.onStreamingPreviewProcessing = { processingCount += 1 }
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        let hideCountAfterRecordingStart = previewHideCount
        streamingEngine.lastOnEvent?(.update(finalizedText: "うっかり押した", volatileText: ""))
        await flushMainActorQueue()

        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<400 where committed.isEmpty { await Task.yield() }
        await flushMainActorQueue()

        XCTAssertEqual(processingCount, 1)
        if case .skipped(.tooShort) = committed.first {
            // expected
        } else {
            XCTFail("Expected .skipped(.tooShort), got \(String(describing: committed.first))")
        }
        XCTAssertEqual(
            previewHideCount, hideCountAfterRecordingStart + 1,
            "挿入されずにスキップで終端した場合も、終端時点でプレビューを隠すべき"
        )
    }

    /// 世代管理の維持: 前ジョブの変換中に次の録音を始めた場合、新しい録音のプレビューが優先され、
    /// 追い越された前ジョブの終端では(新しい表示を消してしまわないよう)何も隠さないこと。
    func testTerminationOfOvertakenJobDoesNotHideNewerRecordingsPreview() async {
        Settings.sttEngine = .speechAnalyzer
        Settings.formattingEnabled = true

        let audioEngine = FakeAudioCaptureEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let formatter = GatedTextFormatter()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: MustNotBeCalledTranscriptionEngine(),
            streamingEngine: streamingEngine,
            textFormatter: formatter,
            textInserter: textInserter,
            now: FakeClock().now,
            dictionaryProvider: { [] }
        )

        var previewHideCount = 0
        coordinator.onStreamingPreviewHide = { previewHideCount += 1 }

        // ジョブ#1: 録音して終了し、整形の途中(=「変換中」表示のまま)で止めておく。
        await coordinator.beginPushToTalk()
        guard let session1 = streamingEngine.lastSession else {
            return XCTFail("session #1 should have been created")
        }
        session1.finishResult = .success("job one raw")
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await formatter.waitUntilCallStarted(1)
        await flushMainActorQueue()

        // ジョブ#2: 前ジョブの変換中に次の録音を開始する(連続入力)。
        await coordinator.beginPushToTalk()
        guard let session2 = streamingEngine.lastSession, session2 !== session1 else {
            return XCTFail("session #2 should have been created")
        }
        session2.finishResult = .success("job two raw")
        let hideCountAfterJob2Start = previewHideCount

        // ジョブ#1の整形を完了させる(録音中のため`DeliveryCoordinator`はコミットを保留する)。
        await formatter.resume(callIndex: 1, with: "job one")
        await flushMainActorQueue()
        XCTAssertEqual(
            previewHideCount, hideCountAfterJob2Start,
            "録音中に前ジョブの処理が終わっても、コミットは保留されるためプレビューは隠されない"
        )

        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await formatter.waitUntilCallStarted(2)
        await formatter.resume(callIndex: 2, with: "job two")

        for _ in 0..<400 where textInserter.insertedTexts.count < 2 { await Task.yield() }
        await flushMainActorQueue()

        XCTAssertEqual(textInserter.insertedTexts, ["job one", "job two"])
        XCTAssertEqual(
            previewHideCount, hideCountAfterJob2Start + 1,
            "追い越された前ジョブ(#1)の終端では隠さず、最新世代のジョブ(#2)の終端でのみ1回隠すべき"
        )
    }

    /// 録音停止グレー中(`.finalizing`)にEscでキャンセルした場合、プレビューはその場で隠したまま
    /// にすべきで、直後に届く`didFinishRecording`で「変換中」表示へ入り直してはいけない。
    func testCancelDuringFinalizingDoesNotReenterProcessingPreview() async {
        Settings.sttEngine = .speechAnalyzer

        let audioEngine = FakeAudioCaptureEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: MustNotBeCalledTranscriptionEngine(),
            streamingEngine: streamingEngine,
            textInserter: textInserter,
            now: FakeClock().now,
            dictionaryProvider: { [] }
        )

        var previewHideCount = 0
        var processingCount = 0
        var committed: [DictationJobCommitEvent] = []
        coordinator.onStreamingPreviewHide = { previewHideCount += 1 }
        coordinator.onStreamingPreviewProcessing = { processingCount += 1 }
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        guard let session = streamingEngine.lastSession else {
            return XCTFail("session should have been created")
        }
        streamingEngine.lastOnEvent?(.update(finalizedText: "取り消す発話", volatileText: ""))
        await flushMainActorQueue()

        coordinator.endPushToTalk() // ここで.finalizingへ
        coordinator.cancelRecording()
        let hideCountAfterCancel = previewHideCount
        XCTAssertEqual(session.cancelCallCount, 1, "キャンセル時はセッションを後始末するべき")
        XCTAssertGreaterThan(hideCountAfterCancel, 0, "キャンセル時点でプレビューを隠すべき")

        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        for _ in 0..<400 where committed.isEmpty { await Task.yield() }
        await flushMainActorQueue()

        XCTAssertEqual(processingCount, 0, "キャンセル済みの録音で『変換中』表示へ入り直してはいけない")
        XCTAssertTrue(textInserter.insertedTexts.isEmpty)
        if case .cancelled = committed.first {
            // expected
        } else {
            XCTFail("Expected .cancelled, got \(String(describing: committed.first))")
        }
    }

    /// whisper(バッチ)モードの挙動は一切変えないこと: 「変換中」通知は発生せず、録音終了時に
    /// 従来通り`onStreamingPreviewHide`が呼ばれるだけ(プレビュー自体そもそも出していない)。
    func testWhisperModeIsUnaffected() async {
        Settings.sttEngine = .whisperCpp
        Settings.formattingEnabled = false

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = GatedTranscriptionEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: streamingEngine,
            textInserter: textInserter,
            now: FakeClock().now,
            dictionaryProvider: { [] }
        )

        var previewHideCount = 0
        var processingCount = 0
        coordinator.onStreamingPreviewHide = { previewHideCount += 1 }
        coordinator.onStreamingPreviewProcessing = { processingCount += 1 }

        await coordinator.beginPushToTalk()
        XCTAssertEqual(streamingEngine.makeSessionCallCount, 0, "whisperモードではストリーミングセッションを作らない")
        let hideCountAfterRecordingStart = previewHideCount

        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(1)
        await flushMainActorQueue()

        XCTAssertEqual(processingCount, 0, "whisperモードでは『変換中』プレビュー通知は発生しないべき")
        XCTAssertEqual(
            previewHideCount, hideCountAfterRecordingStart + 1,
            "whisperモードでは従来通り録音終了時に隠す(実質no-op)"
        )

        await transcriptionEngine.resume(callIndex: 1, with: "whisper text")
        for _ in 0..<400 where textInserter.insertedTexts.isEmpty { await Task.yield() }
        await flushMainActorQueue()

        XCTAssertEqual(textInserter.insertedTexts, ["whisper text"])
        XCTAssertEqual(
            previewHideCount, hideCountAfterRecordingStart + 1,
            "whisperジョブの終端では追加のプレビュー操作を行わないべき"
        )
    }
}
