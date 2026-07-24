import XCTest
@testable import Voicewriter

/// テスト用のフェイク`AudioCaptureEngineControlling`実装(他のCoordinatorテストと同じ方針)。
private final class FakeAudioCaptureEngine: AudioCaptureEngineControlling {
    weak var delegate: AudioCaptureEngineDelegate?
    private(set) var startRecordingCallCount = 0
    private(set) var stopRecordingCallCount = 0
    private(set) var cancelRecordingCallCount = 0

    func startRecording() { startRecordingCallCount += 1 }
    func stopRecording() { stopRecordingCallCount += 1 }
    func cancelRecording() { cancelRecordingCallCount += 1 }
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

private let nonSilentDummySamples: [Float] = Array(repeating: Float(0.3), count: 4800)
private let silentDummySamples: [Float] = Array(repeating: Float(0), count: 4800)

/// SpeechAnalyzerストリーミングモードでは絶対に呼ばれてはいけないことを検証するための
/// フェイク`TranscriptionEngine`。呼ばれた場合は即座に`XCTFail`する(ハングを避けるため、
/// `MultiCallTranscriptionEngine`のような「呼ばれるまで待つ」フェイクは使わない)。
private final class MustNotBeCalledTranscriptionEngine: TranscriptionEngine {
    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
        XCTFail("SpeechAnalyzerストリーミングモードではwhisper.cpp(TranscriptionEngine.transcribe)を呼んではいけない")
        return "should-not-be-used"
    }
}

/// 呼ばれるまで待てるフェイク`TranscriptionEngine`(非対応環境でのフォールバック検証用)。
private actor MultiCallTranscriptionEngine: TranscriptionEngine {
    private var callCount = 0
    private var pendingContinuations: [Int: CheckedContinuation<String, Error>] = [:]
    private var startedCallIndices: Set<Int> = []
    private var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
        callCount += 1
        let index = callCount
        startedCallIndices.insert(index)
        startWaiters[index]?.resume()
        startWaiters[index] = nil
        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[index] = continuation
        }
    }

    func waitUntilCallStarted(_ index: Int) async {
        if startedCallIndices.contains(index) { return }
        await withCheckedContinuation { continuation in
            startWaiters[index] = continuation
        }
    }

    func resume(callIndex: Int, with text: String) {
        pendingContinuations[callIndex]?.resume(returning: text)
        pendingContinuations[callIndex] = nil
    }
}

/// テスト用のフェイク`StreamingTranscriptionSession`。`finish()`/`cancel()`/`append()`の
/// 呼び出し回数と、`finish()`が返す確定テキストをテスト側から制御できる。
private final class FakeStreamingTranscriptionSession: StreamingTranscriptionSession, @unchecked Sendable {
    private(set) var appendedSampleCounts: [Int] = []
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0
    var finishResult: Result<String, Error> = .success("")

    func append(samples: [Float], sampleRate: Double) {
        appendedSampleCounts.append(samples.count)
    }

    func finish() async throws -> String {
        finishCallCount += 1
        return try finishResult.get()
    }

    func cancel() {
        cancelCallCount += 1
    }
}

/// テスト用のフェイク`StreamingTranscriptionEngine`。`makeSession`の呼び出し回数と、
/// 直近に生成したセッション/onEventコールバックを記録する。
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

private enum FakeFormatterError: Error { case boom }

/// 即座に固定の成功を返すシンプルなフェイク`TextFormatter`(整形パス継続の確認用)。
private struct UppercasingTextFormatter: TextFormatter {
    func format(text: String, vocabularyHint: String, model: String, timeoutSeconds: TimeInterval) async throws -> String {
        "[formatted] \(text)"
    }
}

/// SpeechAnalyzerストリーミングモードのCoordinator結合テスト。
///
/// 確定仕様の核心を検証する:
/// 1. ストリーミングモードではwhisper.cpp(`TranscriptionEngine.transcribe`)を一切呼ばない
/// 2. 最終テキストはSpeechAnalyzerの確定結果(`StreamingTranscriptionSession.finish()`の戻り値)を使う
/// 3. その後段のLLM整形→辞書置換→挿入は既存パイプラインをそのまま通す
/// 4. 非対応環境(`streamingEngine`が注入されていない)ではwhisper.cppへ安全にフォールバックする
/// 5. 録音キャンセル時はセッションの`cancel()`が呼ばれ、`finish()`は呼ばれず、何も挿入されない
@MainActor
final class CoordinatorStreamingPipelineTests: XCTestCase {
    private func flushMainActorQueue(iterations: Int = 50) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }

    private var originalSttEngine: SttEngineKind = .whisperCpp

    override func setUp() {
        super.setUp()
        originalSttEngine = Settings.sttEngine
    }

    override func tearDown() {
        Settings.sttEngine = originalSttEngine
        super.tearDown()
    }

    func testStreamingModeUsesSessionFinishResultInsteadOfWhisperAndAppliesFormatting() async {
        Settings.sttEngine = .speechAnalyzer

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MustNotBeCalledTranscriptionEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: streamingEngine,
            textFormatter: UppercasingTextFormatter(),
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        var committed: [(Int, DictationJobCommitEvent)] = []
        coordinator.onJobCommitted = { sequence, result in committed.append((sequence, result)) }
        var previewUpdates: [(String, String)] = []
        coordinator.onStreamingPreviewUpdate = { finalizedText, volatileText in
            previewUpdates.append((finalizedText, volatileText))
        }
        var previewHideCount = 0
        coordinator.onStreamingPreviewHide = { previewHideCount += 1 }

        await coordinator.beginPushToTalk()
        XCTAssertEqual(streamingEngine.makeSessionCallCount, 1, "ストリーミングモードでは録音開始時にセッションを生成するべき")
        guard let session = streamingEngine.lastSession else {
            return XCTFail("session should have been created")
        }
        session.finishResult = .success("ストリーミング確定テキスト")

        // 録音中: fan-out経由で音声チャンクがセッションへ渡ることを確認する。
        coordinator.supplyStreamingAudioChunk(nonSilentDummySamples, sampleRate: 16000)
        await flushMainActorQueue()
        XCTAssertEqual(session.appendedSampleCounts, [nonSilentDummySamples.count], "録音中の音声チャンクはセッションへfan-outされるべき")

        // ライブプレビュー: onEventからのイベントが`onStreamingPreviewUpdate`へ中継されることを確認する。
        streamingEngine.lastOnEvent?(.update(finalizedText: "こんにちは", volatileText: "、今"))
        await flushMainActorQueue()
        XCTAssertEqual(previewUpdates.last?.0, "こんにちは")
        XCTAssertEqual(previewUpdates.last?.1, "、今")

        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where committed.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(session.finishCallCount, 1, "録音終了後、セッションのfinish()が呼ばれるべき")
        XCTAssertEqual(session.cancelCallCount, 0)
        XCTAssertEqual(
            textInserter.insertedTexts,
            ["[formatted] ストリーミング確定テキスト"],
            "SpeechAnalyzerの確定結果がwhisperを経由せず、後段のLLM整形を通って挿入されるべき"
        )
        XCTAssertEqual(committed.count, 1)
        XCTAssertGreaterThanOrEqual(previewHideCount, 1, "録音終了時にライブプレビューは隠されるべき")
    }

    func testFallsBackToWhisperEngineWhenStreamingEngineNotInjected() async {
        // 設定上は.speechAnalyzerが選択されたままでも、この環境(streamingEngine==nil、
        // macOS 26未満または非対応環境を模す)では安全にwhisper.cppへフォールバックするべき
        // (仕様: 非対応環境ではストリーミングモードは選択不可/機能しない)。
        Settings.sttEngine = .speechAnalyzer

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: nil,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        await transcriptionEngine.waitUntilCallStarted(1)
        await transcriptionEngine.resume(callIndex: 1, with: "whisper fallback text")

        for _ in 0..<200 where textInserter.insertedTexts.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["whisper fallback text"])
    }

    func testCancelDuringStreamingRecordingCancelsSessionAndDoesNotInsertAnything() async {
        Settings.sttEngine = .speechAnalyzer

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MustNotBeCalledTranscriptionEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: streamingEngine,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        var previewHideCount = 0
        coordinator.onStreamingPreviewHide = { previewHideCount += 1 }

        await coordinator.beginPushToTalk()
        guard let session = streamingEngine.lastSession else {
            return XCTFail("session should have been created")
        }

        coordinator.cancelRecording()
        XCTAssertEqual(session.cancelCallCount, 1, "録音中のEscキャンセルは即座にセッションのcancel()を呼ぶべき")

        coordinator.audioCaptureEngineDidCancelRecording(audioEngine)
        await flushMainActorQueue()

        XCTAssertEqual(session.finishCallCount, 0, "キャンセルされたセッションのfinish()は呼ばれないべき")
        XCTAssertTrue(textInserter.insertedTexts.isEmpty, "キャンセルされた録音は何も挿入しないべき")
        XCTAssertGreaterThanOrEqual(previewHideCount, 1)
    }

    /// Codexレビュー指摘#1(ブロッキング)の回帰テスト: 録音実効長が閾値未満(第1層)で
    /// `runJob`が早期returnする場合、以前はストリーミングセッションの`cancel()`/`finish()`が
    /// 一度も呼ばれず、バックグラウンドの購読Taskが永久にリークしていた。誤ってホットキーに
    /// 触れてすぐ離す操作は日常的に起きるため、必ず`cancel()`されるべき。
    func testTooShortStreamingRecordingCancelsSessionInsteadOfLeakingIt() async {
        Settings.sttEngine = .speechAnalyzer

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MustNotBeCalledTranscriptionEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        // 押下から離すまでを0.1秒(閾値0.3秒未満)としてシミュレートする(CoordinatorRecordingSkipTestsと同じ方針)。
        let clock = FakeClock(step: 0.1)
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: streamingEngine,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        var committed: [DictationJobCommitEvent] = []
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        guard let session = streamingEngine.lastSession else {
            return XCTFail("session should have been created")
        }
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where committed.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(committed.count, 1)
        if case .skipped(.tooShort) = committed.first {
            // expected
        } else {
            XCTFail("Expected .skipped(.tooShort), got \(String(describing: committed.first))")
        }
        XCTAssertEqual(session.cancelCallCount, 1, "短すぎる録音でも、ストリーミングセッションはcancel()で後始末されるべき(リーク防止)")
        XCTAssertEqual(session.finishCallCount, 0)
        XCTAssertTrue(textInserter.insertedTexts.isEmpty)
    }

    /// Codexレビュー指摘#1(ブロッキング)の回帰テスト: 無音(第2層のエネルギーゲート)で
    /// `runJob`が早期returnする場合も同様に、ストリーミングセッションが確実に後始末されるべき。
    /// 「無音録音は日常的に起きるため深刻」という指摘の核心にあたるケース。
    func testSilentStreamingRecordingCancelsSessionInsteadOfLeakingIt() async {
        Settings.sttEngine = .speechAnalyzer

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MustNotBeCalledTranscriptionEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let clock = FakeClock(step: 1.0)
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: streamingEngine,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        var committed: [DictationJobCommitEvent] = []
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        guard let session = streamingEngine.lastSession else {
            return XCTFail("session should have been created")
        }
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: silentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where committed.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(committed.count, 1)
        if case .skipped(.silence) = committed.first {
            // expected
        } else {
            XCTFail("Expected .skipped(.silence), got \(String(describing: committed.first))")
        }
        XCTAssertEqual(session.cancelCallCount, 1, "無音録音でも、ストリーミングセッションはcancel()で後始末されるべき(リーク防止、Codexレビュー指摘#1)")
        XCTAssertEqual(session.finishCallCount, 0)
        XCTAssertTrue(textInserter.insertedTexts.isEmpty)
    }

    /// Codexレビュー指摘#1(ブロッキング)の回帰テスト: メニューバー「すべての処理をキャンセル」
    /// (`cancelAllJobs()`)で、まだ処理(runJob)が開始されていないストリーミングジョブが
    /// キャンセルされた場合も、そのジョブの`streamingSession`が`runJob`の先頭ガードで
    /// 確実に`cancel()`されるべき(以前はここでもリークしていた)。
    func testCancelAllJobsCancelsQueuedStreamingSessionInsteadOfLeakingIt() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: streamingEngine,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        // ジョブ#1: whisperCppモードで録音し、認識を保留したままにしてinferenceQueueの先頭を
        // 占有させる(ジョブ#2がまだ処理され始めない状態を確実に作るため)。
        Settings.sttEngine = .whisperCpp
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(1)

        // ジョブ#2: SpeechAnalyzerストリーミングモードへ切り替えて録音する。
        Settings.sttEngine = .speechAnalyzer
        await coordinator.beginPushToTalk()
        guard let session = streamingEngine.lastSession else {
            return XCTFail("session should have been created")
        }
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await flushMainActorQueue()

        // ジョブ#2はまだ処理開始前(ジョブ#1がinferenceQueueの先頭を塞いでいる)のはずの状態で、
        // メニューバー「すべての処理をキャンセル」相当を呼ぶ。
        coordinator.cancelAllJobs()

        // ジョブ#1の認識を完了させ、ジョブ#2の番を回す。
        await transcriptionEngine.resume(callIndex: 1, with: "job one")

        for _ in 0..<200 where session.cancelCallCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(
            session.cancelCallCount, 1,
            "cancelAllJobs()でキャンセルされ、まだ処理開始前だったストリーミングセッションも、runJobの先頭ガードでcancel()され後始末されるべき"
        )
        XCTAssertEqual(session.finishCallCount, 0, "キャンセル済みジョブはfinish()を呼ばれないべき")
    }

    /// Codexレビュー指摘#6の回帰テスト: セッションが切り替わった(または既に終了した)後に届く
    /// 遅延イベント(例: `finalizeAndFinishThroughEndOfInput`の裏で発生する最後の確定イベント)は、
    /// 古い世代に属するため無視されるべきで、既に隠したプレビューパネルを再表示したり、
    /// 現行セッションの表示を上書きしたりしてはいけない。
    func testStalePreviewEventFromEndedSessionIsIgnored() async {
        Settings.sttEngine = .speechAnalyzer

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MustNotBeCalledTranscriptionEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: streamingEngine,
            textFormatter: UppercasingTextFormatter(),
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        var previewUpdates: [(String, String)] = []
        coordinator.onStreamingPreviewUpdate = { finalizedText, volatileText in
            previewUpdates.append((finalizedText, volatileText))
        }

        // セッション#1(ジョブ#1)。
        await coordinator.beginPushToTalk()
        guard let session1 = streamingEngine.lastSession, let onEvent1 = streamingEngine.lastOnEvent else {
            return XCTFail("session #1 should have been created")
        }
        session1.finishResult = .success("job one text")
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await flushMainActorQueue()

        // ジョブ#2: 前の発話の処理中でも次の録音を即座に開始できる(連続音声入力パイプラインの核心)。
        await coordinator.beginPushToTalk()
        guard let session2 = streamingEngine.lastSession, let onEvent2 = streamingEngine.lastOnEvent else {
            return XCTFail("session #2 should have been created")
        }
        XCTAssertFalse(session1 === session2, "セッション#2は#1とは別インスタンスであるべき")

        // 既に(録音終了時点で世代が進み)終了扱いのセッション#1由来の遅延イベントが届いたとする。
        onEvent1(.update(finalizedText: "stale finalized", volatileText: "stale volatile"))
        await flushMainActorQueue()

        XCTAssertTrue(previewUpdates.isEmpty, "既に終了したセッションからの遅延イベントは無視され、パネルを再表示/更新してはいけない")

        // セッション#2(現行世代)由来の正当なイベントは、通常通り表示されるべき。
        onEvent2(.update(finalizedText: "こんにちは", volatileText: ""))
        await flushMainActorQueue()
        XCTAssertEqual(previewUpdates.last?.0, "こんにちは", "現行世代(セッション#2)のイベントは表示されるべき")
        XCTAssertEqual(previewUpdates.count, 1, "古い世代のイベントは表示イベント数にカウントされないべき")
    }

    func testWhisperModeStillDoesNotCreateAStreamingSession() async {
        Settings.sttEngine = .whisperCpp

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: streamingEngine,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        await coordinator.beginPushToTalk()
        XCTAssertEqual(streamingEngine.makeSessionCallCount, 0, "whisperCppモード選択時はストリーミングセッションを生成しないべき(既存モードを一切壊さない)")

        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(1)
        await transcriptionEngine.resume(callIndex: 1, with: "whisper text")

        for _ in 0..<200 where textInserter.insertedTexts.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(textInserter.insertedTexts, ["whisper text"])
    }

    /// 実機バグ修正(Codexレビュー指摘)の回帰テスト: ストリーミング録音の直後にバッチ(whisper.cpp)
    /// モードへ切り替えて録音した場合、前のストリーミング録音からの遅延イベント(実機では
    /// `finish()`のfinalizeバーストで後から届きうる)が、バッチ録音中のプレビューパネルに
    /// 紛れ込んではいけない。以前はバッチ録音への切替時に世代を進めていなかったため、
    /// この遅延イベントがそのまま`onStreamingPreviewUpdate`へ配送されてしまっていた。
    func testLateStreamingEventDuringSubsequentBatchRecordingIsIgnored() async {
        Settings.sttEngine = .speechAnalyzer

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: streamingEngine,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        var previewUpdates: [(String, String)] = []
        coordinator.onStreamingPreviewUpdate = { finalizedText, volatileText in
            previewUpdates.append((finalizedText, volatileText))
        }

        // ジョブ#1: ストリーミングモードで録音・終了する。
        await coordinator.beginPushToTalk()
        guard let session1 = streamingEngine.lastSession, let onEvent1 = streamingEngine.lastOnEvent else {
            return XCTFail("session #1 should have been created")
        }
        session1.finishResult = .success("job one text")
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        // `didFinishRecording`は内部で`Task { @MainActor in ... }`により非同期に
        // `recordingState`を`.idle`へ戻す。次の`beginPushToTalk()`がこの遷移を
        // (`.finalizing`のまま誤って`pendingStartRequest`に積んでしまわず)正しく`.idle`として
        // 扱えるよう、ここで一度MainActorキューを空にしてからジョブ#2を開始する。
        await flushMainActorQueue()

        // ジョブ#2: whisper.cpp(バッチ)モードへ切り替えて録音する。
        Settings.sttEngine = .whisperCpp
        await coordinator.beginPushToTalk()
        XCTAssertEqual(streamingEngine.makeSessionCallCount, 1, "バッチモードの録音では新しいストリーミングセッションを生成しないべき")

        // ジョブ#1(既に終了済みのストリーミングセッション)からの遅延イベントが、
        // ジョブ#2(バッチ録音)が進行中のこの時点で届いたとする。
        onEvent1(.update(finalizedText: "stale from job one", volatileText: ""))
        await flushMainActorQueue()

        XCTAssertTrue(
            previewUpdates.isEmpty,
            "バッチ録音への切替後に届いた前のストリーミング録音の遅延イベントは無視されるべき"
        )

        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(1)
        await transcriptionEngine.resume(callIndex: 1, with: "whisper text")
        for _ in 0..<200 where textInserter.insertedTexts.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(
            textInserter.insertedTexts, ["job one text", "whisper text"],
            "ジョブ#1(ストリーミング)・ジョブ#2(バッチ)とも、それぞれ正しいテキストで挿入されるべき"
        )
    }

    /// 実機バグ修正(Codexレビュー指摘)の回帰テスト: 前の録音のライブプレビューがまだ画面に
    /// 残っている状態(前のジョブがまだ処理中で、非表示化がまだ済んでいない)で新しい録音を
    /// 開始した場合、新しい録音の開始時点で確実に(古い内容を)一旦隠すべき。
    func testStartingNewStreamingRecordingHidesResidualPreviewFromPreviousJob() async {
        Settings.sttEngine = .speechAnalyzer

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MustNotBeCalledTranscriptionEngine()
        let streamingEngine = FakeStreamingTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: streamingEngine,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { [] }
        )

        var previewHideCount = 0
        coordinator.onStreamingPreviewHide = { previewHideCount += 1 }

        // ジョブ#1を開始・終了する(処理自体はまだ完了していないかもしれないが、録音枠は空く)。
        await coordinator.beginPushToTalk()
        let hideCountAfterJob1Start = previewHideCount
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await flushMainActorQueue() // recordingStateが.idleへ戻るのを待つ(上記コメント参照)

        // ジョブ#2(新しい録音)を開始する。ジョブ#1の処理(認識・整形)が完了しているかどうかに
        // 関わらず、この開始時点で必ず一度は残存プレビューを隠すべき。
        await coordinator.beginPushToTalk()

        XCTAssertGreaterThan(
            previewHideCount, hideCountAfterJob1Start,
            "新しい録音の開始時点で、前の録音の残存プレビューを隠すべき"
        )
    }
}
