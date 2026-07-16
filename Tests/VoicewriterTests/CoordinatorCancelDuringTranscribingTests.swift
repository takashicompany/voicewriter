import XCTest
@testable import Voicewriter

/// テスト用のフェイク`AudioCaptureEngineControlling`実装。実際の`AVAudioEngine`(実機オーディオ
/// ハードウェア依存)を一切使わず、`Coordinator`が呼んだ操作の回数だけを記録する。
private final class FakeAudioCaptureEngine: AudioCaptureEngineControlling {
    weak var delegate: AudioCaptureEngineDelegate?
    private(set) var startRecordingCallCount = 0
    private(set) var stopRecordingCallCount = 0
    private(set) var cancelRecordingCallCount = 0

    func startRecording() { startRecordingCallCount += 1 }
    func stopRecording() { stopRecordingCallCount += 1 }
    func cancelRecording() { cancelRecordingCallCount += 1 }
}

/// テスト用の単調増加フェイク時計。`beginPushToTalk()`〜`endPushToTalk()`はテスト内では
/// 実時間ではなく同期的に(数マイクロ秒で)呼ばれるため、実時計のままだと
/// ハルシネーション対策の第1層(最短録音時間ガード、既定0.3秒)に常に引っかかってしまう。
/// 呼び出しごとに`step`秒ずつ進む値を返すことでこれを回避する
/// (`Coordinator.minimumEffectiveRecordingDuration`自体は変更しない)。
private final class FakeClock {
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    private let step: TimeInterval
    init(step: TimeInterval = 1.0) { self.step = step }
    func now() -> Date {
        defer { current = current.addingTimeInterval(step) }
        return current
    }
}

/// テスト用のフェイク`TextInserting`。即座に挿入完了とみなす。
private final class FakeTextInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
        insertedTexts.append(text)
        onPasted()
    }
}

/// ハルシネーション対策の第2層(エネルギーゲート)を通過させるためのダミー音声サンプル
/// (無音ではなく、発話とみなせる程度の振幅を持つ)。
private let nonSilentDummySamples: [Float] = Array(repeating: Float(0.3), count: 4800)

/// テスト用のフェイク`TranscriptionEngine`。`transcribe(...)`の完了タイミングを
/// テスト側から任意に制御できるようにし、「`await transcribe`実行中(=結果がまだ返っていない間)に
/// キャンセルが要求される」状況を決定的に再現するために使う。
private actor ControllableTranscriptionEngine: TranscriptionEngine {
    private var resultContinuation: CheckedContinuation<String, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    /// `transcribe`が呼ばれ、内部のcontinuationで待機状態に入るまで待つ。
    func waitUntilTranscribeStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    /// 待機中の`transcribe`呼び出しを、指定したテキストで完了させる。
    func resume(with text: String) {
        resultContinuation?.resume(returning: text)
        resultContinuation = nil
    }
}

/// Codexレビュー指摘#1の回帰テスト:
/// 修正前は`didFinishRecording`のハンドラが`discardPendingTranscriptionResult`を
/// `await transcribe(...)`の**前**にローカル変数へ先読みしていたため、文字起こし実行中
/// (=await中)にEscでキャンセルが要求されても、その時点で読んだ古い(false)値のまま判定してしまい、
/// キャンセルが無視されて結果が挿入されてしまっていた。
///
/// 連続音声入力パイプライン化後は、この「先読みしない」制約は`DictationJobRegistry.isCancelled`を
/// 各ステージ実行前に都度読むことで担保している。
@MainActor
final class CoordinatorCancelDuringTranscribingTests: XCTestCase {
    func testCancelRequestedWhileTranscribeIsAwaitingIsNotIgnored() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ControllableTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var committed: [DictationJobCommitEvent] = []
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        XCTAssertEqual(coordinator.state, .transcribing)

        // AudioCaptureEngineからの「録音終了、文字起こし開始」通知をシミュレートする。
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        // `transcribe()`がcontinuationで待機状態に入るまで、MainActor上の他のTaskに実行を譲る。
        await transcriptionEngine.waitUntilTranscribeStarted()

        // ここが本質: 文字起こし実行中(= transcribe()がまだ結果を返す前)にキャンセル(Esc、非録音時の
        // 階層(2): 最新の未挿入ジョブをキャンセル)が要求された状況を再現する。
        XCTAssertEqual(coordinator.state, .transcribing)
        coordinator.cancelRecording()

        // 文字起こしを完了させる。
        await transcriptionEngine.resume(with: "こんにちは")

        // 結果反映のTaskがMainActor上で完了し、状態がidleに戻るまで待つ。
        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(textInserter.insertedTexts.isEmpty, "await transcribe実行中にキャンセルされた場合、結果は挿入されず破棄されるべき")
        XCTAssertEqual(committed.count, 1)
        if case .cancelled = committed.first {
            // expected
        } else {
            XCTFail("Expected .cancelled, got \(String(describing: committed.first))")
        }
    }

    /// 対照実験: キャンセルされなかった場合は、通常通り結果が挿入されることを確認する
    /// (上のテストが「常に破棄される」ように壊れていないことの確認)。
    func testResultIsInsertedWhenNotCancelled() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ControllableTranscriptionEngine()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var committed: [DictationJobCommitEvent] = []
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        await transcriptionEngine.waitUntilTranscribeStarted()
        await transcriptionEngine.resume(with: "こんにちは")

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(textInserter.insertedTexts, ["こんにちは"])
        XCTAssertEqual(committed.count, 1)
        if case .inserted(let text, _) = committed.first {
            XCTAssertEqual(text, "こんにちは")
        } else {
            XCTFail("Expected .inserted, got \(String(describing: committed.first))")
        }
    }
}
