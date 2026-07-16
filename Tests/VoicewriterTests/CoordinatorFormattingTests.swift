import XCTest
@testable import Voicewriter

/// テスト用のフェイク`AudioCaptureEngineControlling`実装(CoordinatorCancelDuringTranscribingTestsと同じもの)。
private final class FakeAudioCaptureEngine: AudioCaptureEngineControlling {
    weak var delegate: AudioCaptureEngineDelegate?
    func startRecording() {}
    func stopRecording() {}
    func cancelRecording() {}
}

/// テスト用の単調増加フェイク時計(CoordinatorCancelDuringTranscribingTestsと同じ方針)。
/// `beginPushToTalk()`〜`endPushToTalk()`が同期的に呼ばれるテストで、ハルシネーション対策の
/// 第1層(最短録音時間ガード、既定0.3秒)に引っかからないようにするために使う。
private final class FakeClock {
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    private let step: TimeInterval
    init(step: TimeInterval = 1.0) { self.step = step }
    func now() -> Date {
        defer { current = current.addingTimeInterval(step) }
        return current
    }
}

/// ハルシネーション対策の第2層(エネルギーゲート)を通過させるためのダミー音声サンプル。
private let nonSilentDummySamples: [Float] = Array(repeating: Float(0.3), count: 4800)

/// テスト用のフェイク`TranscriptionEngine`。即座に固定テキストを返す。
private final class ImmediateTranscriptionEngine: TranscriptionEngine {
    let text: String
    init(text: String) { self.text = text }
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String { text }
}

/// テスト用のフェイク`TextFormatter`。成功/失敗を固定できるほか、
/// `waitUntilFormatStarted()`/`resume(with:)`で完了タイミングを制御できる
/// (`ControllableTranscriptionEngine`と同じ方針。整形中のキャンセルを決定的に再現するため)。
private actor ControllableTextFormatter: TextFormatter {
    enum Outcome {
        case success(String)
        case failure(Error)
    }

    private var resultContinuation: CheckedContinuation<String, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private(set) var callCount = 0
    private(set) var lastVocabularyHint: String?

    func format(text: String, vocabularyHint: String) async throws -> String {
        callCount += 1
        lastVocabularyHint = vocabularyHint
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilFormatStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func resume(with outcome: Outcome) {
        switch outcome {
        case .success(let text):
            resultContinuation?.resume(returning: text)
        case .failure(let error):
            resultContinuation?.resume(throwing: error)
        }
        resultContinuation = nil
    }
}

/// 即座に固定の成功/失敗を返すシンプルなフェイク`TextFormatter`(タイミング制御が不要なテスト用)。
private struct FixedTextFormatter: TextFormatter {
    enum Outcome {
        case success(String)
        case failure(Error)
    }
    let outcome: Outcome

    func format(text: String, vocabularyHint: String) async throws -> String {
        switch outcome {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }
}

private enum FakeFormatterError: Error { case boom }

/// LLM整形パイプライン統合のテスト:
/// 1. 整形が成功した場合、挿入されるテキストは整形後のものになる
/// 2. 整形が失敗した場合、原文へフォールバックする(致命的にならない)
/// 3. `Settings.formattingEnabled == false`の場合、整形自体をスキップする
/// 4. 整形の実行中(await中)にEscでキャンセルされた場合、結果が破棄される
///    (CoordinatorCancelDuringTranscribingTestsの「文字起こし中のキャンセル」と同じ考え方を、
///    「整形中のキャンセル」にも適用する回帰テスト)
@MainActor
final class CoordinatorFormattingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 既定値(true)に依存するテストと明示的にfalseにするテストが混在するため、
        // 各テストの冒頭で明示的に設定してからテストを実行し、後始末で削除する。
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.formattingEnabled)
        super.tearDown()
    }

    func testFormattedTextIsUsedWhenFormattingSucceeds() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "えーっと、こんにちは")
        let formatter = FixedTextFormatter(outcome: .success("こんにちは。"))
        let clock = FakeClock()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, now: clock.now)

        var insertedResults: [String] = []
        coordinator.onTranscriptionResult = { text, _ in insertedResults.append(text) }

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(insertedResults, ["こんにちは。"])
    }

    func testRawTextIsUsedWhenFormattingFails() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "生の文字起こし結果")
        let formatter = FixedTextFormatter(outcome: .failure(FakeFormatterError.boom))
        let clock = FakeClock()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, now: clock.now)

        var insertedResults: [String] = []
        coordinator.onTranscriptionResult = { text, _ in insertedResults.append(text) }
        var formattingFailedMessages: [String] = []
        coordinator.onFormattingFailed = { formattingFailedMessages.append($0) }

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(insertedResults, ["生の文字起こし結果"], "整形失敗時は原文へフォールバックするべき")
        XCTAssertEqual(formattingFailedMessages.count, 1, "整形失敗時はonFormattingFailedが1回呼ばれるべき")
    }

    func testFormattingIsSkippedWhenDisabled() async {
        Settings.formattingEnabled = false
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "生の文字起こし結果")
        // 呼ばれたら即座に失敗する(=呼ばれないことを期待する)フォーマッタ。
        let formatter = FixedTextFormatter(outcome: .failure(FakeFormatterError.boom))
        let clock = FakeClock()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, now: clock.now)

        var insertedResults: [String] = []
        coordinator.onTranscriptionResult = { text, _ in insertedResults.append(text) }
        var formattingFailedCount = 0
        coordinator.onFormattingFailed = { _ in formattingFailedCount += 1 }

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(insertedResults, ["生の文字起こし結果"])
        XCTAssertEqual(formattingFailedCount, 0, "整形が無効な場合はonFormattingFailedも呼ばれないべき")
    }

    /// Escによるキャンセルが、LLM整形の実行中(await中)に要求された場合も正しく反映され、
    /// 結果が破棄されることを確認する(整形フェーズ挿入によって、文字起こし中のキャンセル処理が
    /// 壊れていないことの回帰テスト)。
    func testCancelRequestedWhileFormattingIsAwaitingIsNotIgnored() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "こんにちは")
        let formatter = ControllableTextFormatter()
        let clock = FakeClock()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, now: clock.now)

        var insertedResults: [String] = []
        coordinator.onTranscriptionResult = { text, _ in insertedResults.append(text) }

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        XCTAssertEqual(coordinator.state, .transcribing)

        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        // 整形(format())がcontinuationで待機状態に入るまで、MainActor上の他のTaskに実行を譲る。
        await formatter.waitUntilFormatStarted()

        // 整形実行中(= format()がまだ結果を返す前)にキャンセル(Esc)が要求された状況を再現する。
        XCTAssertEqual(coordinator.state, .transcribing)
        coordinator.cancelRecording()

        // 整形を完了させる。
        await formatter.resume(with: .success("こんにちは。"))

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(
            insertedResults.isEmpty,
            "整形実行中にキャンセルされた場合、結果は挿入されず破棄されるべき"
        )
    }

    /// 語彙ヒント(`Settings.sttVocabularyHint`)がフォーマッタへそのまま伝播することを確認する。
    func testVocabularyHintIsPassedToFormatter() async {
        Settings.formattingEnabled = true
        let originalHint = Settings.sttVocabularyHint
        Settings.sttVocabularyHint = "Voicewriter, TestHint"
        defer { Settings.sttVocabularyHint = originalHint }

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "テスト")
        let formatter = ControllableTextFormatter()
        let clock = FakeClock()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, now: clock.now)

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        await formatter.waitUntilFormatStarted()
        await formatter.resume(with: .success("テスト。"))

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        let hint = await formatter.lastVocabularyHint
        XCTAssertEqual(hint, "Voicewriter, TestHint")
    }

    /// HUD表示用の`onPhaseChanged`が、整形が実際に行われる場合は
    /// 認識中→整形中の順で通知されることを確認する(状態機械`AppState`自体は`.transcribing`のまま)。
    func testPhaseChangedNotifiesRecognizingThenFormattingWhenFormattingWillRun() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "こんにちは")
        let formatter = FixedTextFormatter(outcome: .success("こんにちは。"))
        let clock = FakeClock()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, now: clock.now)

        var phases: [TranscriptionPhase] = []
        coordinator.onPhaseChanged = { phases.append($0) }

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(phases, [.recognizing, .formatting])
    }

    /// 整形が無効な場合、`onPhaseChanged`は認識中のみを通知し、整形中は通知されないべき。
    func testPhaseChangedOnlyNotifiesRecognizingWhenFormattingIsSkipped() async {
        Settings.formattingEnabled = false
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "こんにちは")
        let formatter = FixedTextFormatter(outcome: .failure(FakeFormatterError.boom))
        let clock = FakeClock()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, now: clock.now)

        var phases: [TranscriptionPhase] = []
        coordinator.onPhaseChanged = { phases.append($0) }

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(phases, [.recognizing])
    }
}
