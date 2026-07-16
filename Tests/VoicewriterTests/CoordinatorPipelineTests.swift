import XCTest
@testable import Voicewriter

/// テスト用のフェイク`AudioCaptureEngineControlling`実装。実際の`AVAudioEngine`には依存せず、
/// `Coordinator`が呼んだ操作の回数だけを記録する。
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
private let silentSamples: [Float] = Array(repeating: Float(0), count: 4800)

/// テスト用のフェイク`TextInserting`。`insert(...)`の呼び出しを、実際にCmd+Vを送出した瞬間
/// (`onPasted`呼び出し)と、その後の完了(ペーストボード復元待ちの終わり)とで別々に、
/// テスト側から任意のタイミングで制御できるようにする。挿入クリティカル区間
/// (`DeliveryCoordinator.isInsertionCriticalSection`)がタイムアウトなしに正しく維持される
/// ことを検証するために使う(Codexレビュー指摘#3)。
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

    /// `insert(...)`が呼ばれ、Cmd+V送出前の状態で待機し始めるまで待つ。
    func waitUntilInsertStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    /// Cmd+V送出直後相当(挿入クリティカル区間の終了トリガー)を発火する。
    func triggerOnPasted() {
        onPastedTrigger?()
        onPastedTrigger = nil
    }

    /// `insert(...)`呼び出し自体を完了させる(ペーストボード復元待ちの終わり相当)。
    func finishInsert() {
        completionContinuation?.resume()
        completionContinuation = nil
    }
}

/// 呼び出しごと(callIndex)に完了タイミングを個別に制御できるフェイク`TranscriptionEngine`。
/// 複数ジョブが同時に処理系に存在する状況(録音は即座に次を開始できるが、推論は
/// `SerialFIFOQueue`で直列化される)を決定的に再現するために使う。
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

/// 連続音声入力パイプライン全体(Coordinator + DictationJobRegistry + SerialFIFOQueue +
/// DeliveryCoordinator)の結合テスト。
@MainActor
final class CoordinatorPipelineTests: XCTestCase {
    /// `Coordinator.audioCaptureEngine(_:didFinishRecording:...)`等はMainActor上の`Task`として
    /// 非同期にディスパッチされる(`nonisolated`なdelegateメソッドが内部で`Task { @MainActor in ... }`
    /// するため、呼び出した直後はまだ実行されていない)。ジョブ生成・状態遷移が実際に走るまで
    /// スケジューラへ制御を譲るためのヘルパー。
    private func flushMainActorQueue(iterations: Int = 20) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }

    /// 要件1の核心: 前の発話の認識・整形中でも、次の録音を即座に開始できる
    /// (ビープで拒否されない。`audioEngine.startRecording()`が2回目も即座に呼ばれる)。
    func testNextRecordingCanStartImmediatelyWhilePreviousJobIsStillProcessing() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var queueFullCount = 0
        coordinator.onQueueFull = { queueFullCount += 1 }

        // ジョブ#1: 録音して停止(処理は保留、まだ完了しない)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(1)

        // ジョブ#1がまだ認識中でも、ジョブ#2の録音を即座に開始できるべき(ビープで拒否されない)。
        await coordinator.beginPushToTalk()
        XCTAssertEqual(audioEngine.startRecordingCallCount, 2, "処理中でも次の録音が即座に開始できるべき")
        XCTAssertEqual(queueFullCount, 0)
        XCTAssertEqual(coordinator.state, .recording, "録音中はrecordingが最優先で表示されるべき")
    }

    /// 発話順の厳守: 挿入はsequence順(録音開始時に採番した順)を守る。
    /// ジョブ#2の録音中にジョブ#1の処理が完了しても、挿入は録音終了後まで保留され、
    /// #1→#2の順にコミットされる。
    func testInsertionOrderIsPreservedAndHeldWhileNextRecordingIsInProgress() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var committed: [(Int, DictationJobCommitEvent)] = []
        coordinator.onJobCommitted = { sequence, result in committed.append((sequence, result)) }

        // ジョブ#1: 録音・停止。認識は保留する。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(1)

        // ジョブ#2: #1がまだ処理中のうちに、別の録音を開始する(要件1)。
        await coordinator.beginPushToTalk()

        // #1の認識を完了させる。この時点で#2はまだ「録音中」なので、挿入は保留されるべき。
        await transcriptionEngine.resume(callIndex: 1, with: "job one")
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(textInserter.insertedTexts.isEmpty, "#2の録音中は#1の挿入も保留されるべき(録音中の誤挿入事故防止)")

        // #2の録音を終了させ、認識も完了させる。
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(2)
        await transcriptionEngine.resume(callIndex: 2, with: "job two")

        for _ in 0..<200 where committed.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["job one", "job two"], "発話順(sequence順)で挿入されるべき")
        XCTAssertEqual(committed.map(\.0), [1, 2])
    }

    /// Escの階層的キャンセル(非録音時): まだ挿入されていない最新のジョブをキャンセルする。
    func testCancelRecordingWhileIdleCancelsLatestPendingJob() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var committed: [DictationJobCommitEvent] = []
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(1)

        // 録音中ではない(処理中)状態でEsc相当を呼ぶ。
        XCTAssertEqual(coordinator.state, .transcribing)
        coordinator.cancelRecording()

        await transcriptionEngine.resume(callIndex: 1, with: "should be discarded")

        for _ in 0..<200 where committed.isEmpty {
            await Task.yield()
        }

        XCTAssertTrue(textInserter.insertedTexts.isEmpty, "キャンセルされたジョブは挿入されないべき")
        if case .cancelled = committed.first {
            // expected
        } else {
            XCTFail("Expected .cancelled, got \(String(describing: committed.first))")
        }
    }

    /// キュー上限: 未終端ジョブが上限に達したら新規録音を拒否し、`onQueueFull`が呼ばれる。
    func testQueueFullRejectsNewRecordingAtLimit() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            textInserter: textInserter,
            now: clock.now,
            maxUnterminatedJobs: 2
        )

        var queueFullCount = 0
        coordinator.onQueueFull = { queueFullCount += 1 }

        // 上限(2件)まで録音・停止して未終端ジョブを作る(推論はSerialFIFOQueueで直列化されるため、
        // ジョブ#1の認識が完了(=継続を解決)するまでジョブ#2のtranscribeは呼ばれ始めない。
        // ここでは「ジョブが未終端として登録されること」だけを検証したいので、ジョブ#1の方だけ
        // 認識開始を待って同期点とし、ジョブ#2は`flushMainActorQueue()`で生成完了を待つ)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(1)

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await flushMainActorQueue()

        XCTAssertEqual(audioEngine.startRecordingCallCount, 2)

        // 3件目は上限到達により拒否されるべき。
        await coordinator.beginPushToTalk()
        XCTAssertEqual(audioEngine.startRecordingCallCount, 2, "上限到達時は新規録音を開始しないべき")
        XCTAssertEqual(queueFullCount, 1)
    }

    /// 停止グレー(finalizing)中の再押下: 開始要求を保留し、前ジョブのバッファ確定直後に
    /// 自動的に次の録音を開始する(`AudioCaptureEngine.controlQueue`経由の完了と競合させないため)。
    func testHotkeyDuringFinalizingGraceQueuesStartAndAutoStartsAfterPreviousBufferIsFinalized() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        await coordinator.beginPushToTalk()
        XCTAssertEqual(audioEngine.startRecordingCallCount, 1)
        coordinator.endPushToTalk()
        XCTAssertEqual(audioEngine.stopRecordingCallCount, 1)

        // まだAudioCaptureEngine側のグレース(100ms)が明けていない(=didFinishRecordingが
        // まだ届いていない)想定のタイミングで、次の録音開始が要求されたとする。
        await coordinator.beginPushToTalk()
        XCTAssertEqual(audioEngine.startRecordingCallCount, 1, "finalizing中は新規録音を即座に開始しないべき")

        // グレースが明け、前ジョブのバッファが確定した(didFinishRecordingが届いた)。
        // `audioCaptureEngine(_:didFinishRecording:...)`はnonisolatedなdelegateメソッドが内部で
        // `Task { @MainActor in ... }`するため、呼び出した直後はまだ実行されていない。
        // ジョブ生成・保留していた開始要求の実行が走るまでスケジューラへ制御を譲る。
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await flushMainActorQueue()

        XCTAssertEqual(audioEngine.startRecordingCallCount, 2, "前ジョブのバッファ確定直後に保留していた開始要求が実行されるべき")
        XCTAssertEqual(coordinator.state, .recording)
    }

    /// 無音スキップ(墓標)は順序を消費し、後続ジョブの挿入を詰まらせない。
    func testSilentJobTombstoneDoesNotBlockSubsequentInsertion() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var committed: [(Int, DictationJobCommitEvent)] = []
        coordinator.onJobCommitted = { sequence, result in committed.append((sequence, result)) }

        // ジョブ#1: 無音(第2層のエネルギーゲートでスキップされ、transcribeは呼ばれない)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: silentSamples, sampleRate: 16000)

        // #1が墓標としてコミットされる(=処理・録音状態のリセットが完了する)まで待ってから
        // #2を開始する(そうしないと#1のdidFinishRecordingハンドラがまだ`Task`として未実行のうちに
        // #2のbeginPushToTalk()が呼ばれ、finalizing中の開始要求保留の経路に入ってしまう)。
        for _ in 0..<200 where committed.isEmpty {
            await Task.yield()
        }

        // ジョブ#2: 通常の発話。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        await transcriptionEngine.waitUntilCallStarted(1)
        await transcriptionEngine.resume(callIndex: 1, with: "job two text")

        for _ in 0..<200 where committed.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["job two text"])
        XCTAssertEqual(committed.count, 2)
        XCTAssertEqual(committed[0].0, 1)
        if case .skipped(.silence) = committed[0].1 {
            // expected
        } else {
            XCTFail("Expected job #1 to be skipped as silence, got \(committed[0].1)")
        }
        XCTAssertEqual(committed[1].0, 2)
    }

    /// Codexレビュー指摘#1の回帰テスト: finalizing中に保留していた開始要求がキュー上限で拒否された
    /// 場合、以前は`recordingState`が`.finalizing`のまま残ってしまい、以後永久に録音を開始できなく
    /// なっていた。拒否後は必ず`.idle`へ戻り、以後のキュー上限判定・完成済みジョブの挿入再開も
    /// 正常に機能するべき。
    func testQueueFullDuringFinalizingReturnsToIdleAndResumesPendingInsertion() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            textInserter: textInserter,
            now: clock.now,
            maxUnterminatedJobs: 2
        )

        var queueFullCount = 0
        coordinator.onQueueFull = { queueFullCount += 1 }

        // ジョブ#1: 録音・停止。認識は保留したまま(未終端)にしておく。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(1)

        // ジョブ#2: 上限(2件)まで録音・停止(finalizingグレー待ちに入る)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()

        // finalizing中に3件目の開始要求(PTT)が保留される。
        await coordinator.beginPushToTalk()
        XCTAssertEqual(audioEngine.startRecordingCallCount, 2, "finalizing中は新規録音を開始しないべき")

        // ジョブ#2のグレースが明ける。未終端が既に2件(上限)のため、保留していた3件目の
        // 開始要求はキュー満杯で拒否されるべき。
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(audioEngine.startRecordingCallCount, 2)
        XCTAssertEqual(queueFullCount, 1)

        // 核心: 拒否後も`recordingState`が`.finalizing`のまま残ってはいけない。残っていると、
        // 次のPTTは即座に`attemptStartRecording`を試みず単に新しい保留要求として積むだけになり、
        // `onQueueFull`が再度呼ばれない。正しく`.idle`へ戻っていれば、次のPTTは即座に
        // `attemptStartRecording`を試み、まだ上限に達したままなので再度`onQueueFull`が呼ばれるはず。
        await coordinator.beginPushToTalk()
        XCTAssertEqual(queueFullCount, 2, "recordingStateがidleへ戻っており、新規録音を試みて再度キュー満杯と判定されるべき")
        XCTAssertEqual(audioEngine.startRecordingCallCount, 2)

        // 未終端の枠を空ける: ジョブ#1の認識を完了させ、完成済みジョブの挿入が再開されることを確認する。
        await transcriptionEngine.resume(callIndex: 1, with: "job one")
        for _ in 0..<200 where textInserter.insertedTexts.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(textInserter.insertedTexts, ["job one"], "キュー満杯からの復帰後も、完成済みジョブの挿入が再開されるべき")
    }

    /// Codexレビュー指摘#2の回帰テスト: finalizing中に非常に短いPTT(keyDown直後にkeyUp)が
    /// 発生した場合、以前は保留していた開始要求をそのまま実行してしまい、対応するkeyUpは既に
    /// 消費済みのため「録音が止まらない」バグになっていた。開始前にkeyUpが来ていた保留要求は
    /// 取り消され、新しい録音を開始しないべき。
    func testShortPTTDuringFinalizingDoesNotLeaveRecordingRunningForever() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        // ジョブ#1: 録音・停止(finalizingグレー待ちに入る。まだdidFinishRecordingは届いていない)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        XCTAssertEqual(audioEngine.startRecordingCallCount, 1)

        // finalizing中に、非常に短いPTT(keyDown直後にkeyUp)が発生したとする。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()

        // ジョブ#1のグレースが明ける。修正前は、ここで保留していた開始要求がそのまま実行され、
        // 新しい録音が開始されてしまっていた(そのkeyUpは既に消費済みのため、以後キーを離しても
        // 録音は止まらないバグになる)。
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(audioEngine.startRecordingCallCount, 1, "keyUpが既に来ていた保留PTT開始要求は取り消され、新しい録音を開始しないべき")
    }

    /// Codexレビュー指摘#3の回帰テスト: 挿入クリティカル区間(フォーカス確認〜Cmd+V送出)が
    /// 続いている間、新規録音の開始要求は(かつての最大100msのポーリング打ち切りに関わらず)
    /// クリティカル区間が実際に終わるまで待つべきで、タイムアウトで諦めて録音を開始しては
    /// いけない。区間が実際に終わった直後には、待っていた開始要求が即座に実行されるべき。
    func testRecordingStartWaitsForInsertionCriticalSectionToActuallyEndWithoutTimingOut() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = ControllableTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        // ジョブ#1: 録音・停止・認識完了→挿入クリティカル区間に入る(Cmd+V送出前で止めておく)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(1)
        await transcriptionEngine.resume(callIndex: 1, with: "job one")
        await textInserter.waitUntilInsertStarted()

        XCTAssertEqual(audioEngine.startRecordingCallCount, 1)

        // 挿入クリティカル区間が続いている間に、次の録音開始(PTT)を要求する。
        let beginTask = Task { await coordinator.beginPushToTalk() }

        // かつてのタイムアウト(20ms×5回=最大100ms)を大きく超えて待っても、クリティカル区間が
        // 実際に終わっていない限り録音を開始しないべき。
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(audioEngine.startRecordingCallCount, 1, "挿入クリティカル区間が続いている間は、タイムアウトで諦めて録音を開始してはいけない")

        // クリティカル区間を終了させる(Cmd+V送出相当)。
        await textInserter.triggerOnPasted()
        await beginTask.value

        XCTAssertEqual(audioEngine.startRecordingCallCount, 2, "クリティカル区間が実際に終わった直後は、待っていた録音開始要求が実行されるべき")

        await textInserter.finishInsert()
    }

    /// Codexレビュー指摘#5の回帰テスト: finalizing中(録音停止済みグレー待ち)にEscを押すと、
    /// 以前は「まだ挿入されていない最新の未終端ジョブ」を対象にしてしまい、既に別ジョブとして
    /// 確定・キュー投入済みの直前のジョブを誤ってキャンセルしていた。正しくは「いま確定処理中の
    /// 録音自体」を破棄するべきで、既に確定済みの前ジョブには影響しないべき。
    func testEscDuringFinalizingCancelsTheRecordingBeingFinalizedNotAnEarlierQueuedJob() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MultiCallTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var committed: [(Int, DictationJobCommitEvent)] = []
        coordinator.onJobCommitted = { sequence, result in committed.append((sequence, result)) }

        // ジョブ#1: 録音・停止(認識は保留のまま未終端)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        await transcriptionEngine.waitUntilCallStarted(1)

        // ジョブ#2: 録音・停止(finalizingグレー待ちに入る。まだdidFinishRecordingは届いていない)。
        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()

        // finalizing中にEscを押す。対象は「いま確定処理中のジョブ#2自身」であるべきで、
        // 既に別ジョブとして確定・キュー投入済みのジョブ#1を誤ってキャンセルしてはいけない。
        coordinator.cancelRecording()

        // ジョブ#2のグレースが明ける。キャンセル要求済みのため、ジョブ化はされるが即座に墓標化される。
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        // ジョブ#1の認識を完了させる。キャンセルされていなければ挿入されるはず。
        await transcriptionEngine.resume(callIndex: 1, with: "job one should be inserted")

        for _ in 0..<200 where committed.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(committed.count, 2)
        XCTAssertEqual(committed[0].0, 1)
        if case .inserted(let text, _) = committed[0].1 {
            XCTAssertEqual(text, "job one should be inserted", "finalizing中のEscは、既に確定済みのジョブ#1ではなく、いま確定処理中のジョブ#2自身を対象にするべき")
        } else {
            XCTFail("Expected job #1 to be inserted (not cancelled), got \(committed[0].1)")
        }
        XCTAssertEqual(committed[1].0, 2)
        if case .cancelled = committed[1].1 {
            // expected
        } else {
            XCTFail("Expected job #2 (the one being finalized) to be cancelled, got \(committed[1].1)")
        }
        XCTAssertEqual(textInserter.insertedTexts, ["job one should be inserted"])
    }
}
