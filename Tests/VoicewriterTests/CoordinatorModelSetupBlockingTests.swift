import XCTest
@testable import Voicewriter

/// テスト用のフェイク`AudioCaptureEngineControlling`実装。`startRecording()`/`stopRecording()`が
/// 実際に呼ばれた回数をカウントできる点が、他ファイルの同名フェイクとの違い(セットアップ中の
/// 拒否が「録音を一切開始しない」ことまで確認するために必要)。
private final class CountingFakeAudioCaptureEngine: AudioCaptureEngineControlling {
    weak var delegate: AudioCaptureEngineDelegate?
    private(set) var startRecordingCallCount = 0
    private(set) var stopRecordingCallCount = 0
    func startRecording() { startRecordingCallCount += 1 }
    func stopRecording() { stopRecordingCallCount += 1 }
    func cancelRecording() {}
}

/// テスト用の単調増加フェイク時計(他のCoordinatorテストと同じ方針)。
private final class FakeClock {
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    private let step: TimeInterval
    init(step: TimeInterval = 1.0) { self.step = step }
    func now() -> Date {
        defer { current = current.addingTimeInterval(step) }
        return current
    }
}

/// テスト用のフェイク`TranscriptionEngine`。固定テキストを即座に返す。
private final class ImmediateTranscriptionEngine: TranscriptionEngine {
    let text: String
    init(text: String = "unused") { self.text = text }
    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String { text }
}

private final class FakeTextInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
        insertedTexts.append(text)
        onPasted()
    }
}

private let nonSilentDummySamples: [Float] = Array(repeating: Float(0.3), count: 4800)

/// テスト用のフェイク`TextInserting`。`insert(...)`の呼び出しを、Cmd+V送出前(挿入クリティカル
/// 区間)で任意のタイミングまで止められる(`CoordinatorPipelineTests`の同名フェイクと同じ方針)。
/// 挿入クリティカル区間の`await`中にセットアップが開始された場合の競合を検証するために使う。
private actor ControllableTextInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    private var onPastedTrigger: (() -> Void)?
    private var completionContinuation: CheckedContinuation<Void, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
        insertedTexts.append(text)
        onPastedTrigger = onPasted
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        try await withCheckedThrowingContinuation { continuation in
            completionContinuation = continuation
        }
    }

    func waitUntilInsertStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func triggerOnPasted() {
        onPastedTrigger?()
        onPastedTrigger = nil
    }

    func finishInsert() {
        completionContinuation?.resume()
        completionContinuation = nil
    }
}

/// whisperモデルの初回自動セットアップ(`ModelDownloader`によるダウンロード)中は、`Coordinator`が
/// 新規録音の開始要求(PTT/トグルいずれも)を拒否し、スタブへフォールバックしてダミーテキストが
/// 挿入されてしまうことを防ぐことの回帰テスト。`isModelSetupBlocking`は`AppDelegate`が
/// `ModelDownloader.state`の変化に応じて更新する想定だが、ここでは直接プロパティを操作して検証する。
///
/// ゲートは`attemptStartRecording(source:)`という単一のチョークポイント(新規録音を実際に
/// 開始する経路が必ず通る場所。`beginPushToTalk()`/`toggleRecording()`の`.idle`分岐、および
/// `finalizeRecordingTransition()`による`pendingStartRequest`の再生(finalizing明け後の自動開始)の
/// **すべて**がここを通る)に置いている。これにより、`.finalizing`中や挿入クリティカル区間の
/// `await`中にセットアップが開始された場合の迂回も防げる一方、録音の**停止**操作はこの
/// チョークポイントを経由しないため、セットアップ中であっても進行中の録音停止は妨げない
/// (Codexレビュー指摘)。
@MainActor
final class CoordinatorModelSetupBlockingTests: XCTestCase {
    func testBeginPushToTalkIsRejectedWhileModelSetupIsBlocking() async {
        let audioEngine = CountingFakeAudioCaptureEngine()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: ImmediateTranscriptionEngine(), now: FakeClock().now)
        coordinator.isModelSetupBlocking = true

        var rejectedCount = 0
        coordinator.onRecordingRejectedDuringSetup = { rejectedCount += 1 }

        await coordinator.beginPushToTalk()

        XCTAssertEqual(rejectedCount, 1, "セットアップ中は録音開始要求が拒否されるべき")
        XCTAssertEqual(audioEngine.startRecordingCallCount, 0, "セットアップ中は録音デバイス自体を起動しないべき(スタブへのフォールバックを防ぐため)")
        XCTAssertEqual(coordinator.state, .idle, "セットアップ中の拒否は状態機械に影響しないべき")
    }

    func testToggleRecordingIsRejectedWhileModelSetupIsBlocking() async {
        let audioEngine = CountingFakeAudioCaptureEngine()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: ImmediateTranscriptionEngine(), now: FakeClock().now)
        coordinator.isModelSetupBlocking = true

        var rejectedCount = 0
        coordinator.onRecordingRejectedDuringSetup = { rejectedCount += 1 }

        await coordinator.toggleRecording()

        XCTAssertEqual(rejectedCount, 1, "セットアップ中は録音開始要求が拒否されるべき")
        XCTAssertEqual(audioEngine.startRecordingCallCount, 0)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testRecordingProceedsNormallyOnceSetupBlockingIsCleared() async {
        let audioEngine = CountingFakeAudioCaptureEngine()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: ImmediateTranscriptionEngine(), now: FakeClock().now)
        coordinator.isModelSetupBlocking = true
        coordinator.isModelSetupBlocking = false

        var rejectedCount = 0
        coordinator.onRecordingRejectedDuringSetup = { rejectedCount += 1 }

        await coordinator.beginPushToTalk()

        XCTAssertEqual(rejectedCount, 0, "セットアップ完了後は拒否されず通常通り録音開始できるべき")
        XCTAssertEqual(audioEngine.startRecordingCallCount, 1)
        XCTAssertEqual(coordinator.state, .recording)
    }

    /// セットアップ中であっても、**進行中の録音を止める操作**は妨げられないべき(Codexレビュー指摘:
    /// 「トグル録音中に手動ダウンロードが始まった場合、停止操作は拒否しない(開始のみ拒否)」)。
    /// 停止は`attemptStartRecording`を経由しないため、ゲートの影響を受けないことを確認する。
    func testToggleStopIsNotBlockedWhileModelSetupIsBlocking() async {
        let audioEngine = CountingFakeAudioCaptureEngine()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: ImmediateTranscriptionEngine(), textInserter: FakeTextInserter(), now: FakeClock().now)

        // トグルで録音を開始する(セットアップ開始前)。
        await coordinator.toggleRecording()
        XCTAssertEqual(coordinator.state, .recording)
        XCTAssertEqual(audioEngine.startRecordingCallCount, 1)

        // 録音中にセットアップが始まったとする(例: 設定画面から手動ダウンロードボタンを押した)。
        coordinator.isModelSetupBlocking = true

        var rejectedCount = 0
        coordinator.onRecordingRejectedDuringSetup = { rejectedCount += 1 }

        // トグルで停止しようとする操作は拒否されず、通常通り止まるべき。
        await coordinator.toggleRecording()

        XCTAssertEqual(audioEngine.stopRecordingCallCount, 1, "セットアップ中でも進行中の録音停止操作は拒否されないべき")
        XCTAssertEqual(rejectedCount, 0, "停止操作はonRecordingRejectedDuringSetupを呼ぶべきではない")
    }

    /// `.finalizing`(録音停止済みグレー待ち)中に次の開始要求が保留され、グレースが明けて
    /// `finalizeRecordingTransition()`が保留要求を再生しようとする直前にセットアップが始まった
    /// 場合も、`attemptStartRecording`が唯一のチョークポイントであるため正しく拒否され、
    /// `recordingState`が`.finalizing`のまま取り残されず`.idle`へ戻ることを確認する
    /// (Codexレビュー指摘: 「finalizeRecordingTransition()が入口ガードを迂回する」問題への回帰テスト)。
    func testPendingStartRequestReplayIsRejectedWhenSetupBlockingBecomesTrueDuringFinalizing() async {
        let audioEngine = CountingFakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "job one")
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: FakeClock().now)

        // ジョブ#1: 録音・停止(finalizingグレー待ちに入る。まだdidFinishRecordingは届いていない)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        XCTAssertEqual(audioEngine.startRecordingCallCount, 1)

        // finalizing中に次の開始要求(PTT)が保留される。
        await coordinator.beginPushToTalk()
        XCTAssertEqual(audioEngine.startRecordingCallCount, 1, "finalizing中は新規録音を即座に開始しないべき")

        var rejectedCount = 0
        coordinator.onRecordingRejectedDuringSetup = { rejectedCount += 1 }

        // グレースが明ける前にセットアップが始まったとする。
        coordinator.isModelSetupBlocking = true

        // グレースが明け、保留していた開始要求が再生されようとする。
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(audioEngine.startRecordingCallCount, 1, "セットアップ中はfinalizing明け後の保留開始要求も拒否されるべき")
        XCTAssertEqual(rejectedCount, 1)
        XCTAssertEqual(coordinator.state, .idle, "拒否後もrecordingStateがfinalizingのまま取り残されず.idleへ戻るべき")
    }

    /// 挿入クリティカル区間(フォーカス確認〜Cmd+V送出)の`await`中にセットアップが始まった場合も、
    /// 区間終了後に再開される録音開始が正しく拒否されることを確認する(Codexレビュー指摘: 「await中の
    /// blocking開始」への回帰テスト)。`attemptStartRecording`がawait解決後の唯一のチョークポイントで
    /// あるため、いつブロッキングが始まったかによらず、実際に開始しようとする瞬間に正しく判定される。
    func testRecordingRequestWaitingOnInsertionCriticalSectionIsRejectedIfSetupBlockingBeginsDuringTheWait() async {
        let audioEngine = CountingFakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "job one")
        let textInserter = ControllableTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: FakeClock().now)

        // ジョブ#1: 録音・停止・認識完了→挿入クリティカル区間に入る(Cmd+V送出前で止めておく)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await textInserter.waitUntilInsertStarted()

        XCTAssertEqual(audioEngine.startRecordingCallCount, 1)

        var rejectedCount = 0
        coordinator.onRecordingRejectedDuringSetup = { rejectedCount += 1 }

        // 挿入クリティカル区間が続いている間に、次の録音開始(PTT)を要求する
        // (waitForInsertionCriticalSectionIfNeeded()のawaitで待たされる)。
        let beginTask = Task { await coordinator.beginPushToTalk() }

        // 区間が続いている間にセットアップが始まったとする。
        try? await Task.sleep(nanoseconds: 50_000_000)
        coordinator.isModelSetupBlocking = true

        // クリティカル区間を終了させる(Cmd+V送出相当)。保留していた開始要求が再開される。
        await textInserter.triggerOnPasted()
        await beginTask.value

        XCTAssertEqual(audioEngine.startRecordingCallCount, 1, "await中に始まったセットアップにより、区間終了後の録音開始は拒否されるべき")
        XCTAssertEqual(rejectedCount, 1)

        await textInserter.finishInsert()
    }
}
