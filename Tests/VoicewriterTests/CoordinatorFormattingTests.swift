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

/// テスト用のフェイク`TextInserting`。即座に挿入完了とみなす。
private final class FakeTextInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
        insertedTexts.append(text)
        onPasted()
    }
}

/// ハルシネーション対策の第2層(エネルギーゲート)を通過させるためのダミー音声サンプル。
private let nonSilentDummySamples: [Float] = Array(repeating: Float(0.3), count: 4800)

/// テスト用のフェイク`TranscriptionEngine`。即座に固定テキストを返す。
private final class ImmediateTranscriptionEngine: TranscriptionEngine {
    let text: String
    init(text: String) { self.text = text }
    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String { text }
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
    private(set) var lastModel: String?
    private(set) var lastTimeoutSeconds: TimeInterval?

    func format(text: String, vocabularyHint: String, model: String, timeoutSeconds: TimeInterval) async throws -> String {
        callCount += 1
        lastVocabularyHint = vocabularyHint
        lastModel = model
        lastTimeoutSeconds = timeoutSeconds
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

    func format(text: String, vocabularyHint: String, model: String, timeoutSeconds: TimeInterval) async throws -> String {
        switch outcome {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }
}

private enum FakeFormatterError: Error { case boom }

/// `Task.cancel()`に反応してすぐ`CancellationError`をthrowするフェイク`TextFormatter`。
/// 実際の`OllamaFormatter`(`URLSession.data(for:)`がSwift ConcurrencyのTaskキャンセルを
/// 尊重し、キャンセルされると即座にエラーを投げる)の挙動を模す。Coordinatorが登録した
/// キャンセルハンドル(`Task.cancel()`)が実際に整形処理を中断させることを検証するために使う
/// (Codexレビュー指摘#6: 以前はRegistryのフラグを立てるだけで、実行中のタスクは解放されず
/// FIFOの先頭を占有し続けていた)。
private actor CancellationAwareTextFormatter: TextFormatter {
    private(set) var callCount = 0
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func format(text: String, vocabularyHint: String, model: String, timeoutSeconds: TimeInterval) async throws -> String {
        callCount += 1
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        // 実際のURLSession.data(for:)同様、キャンセルされるまで待ち続ける。
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CancellationError()
    }

    func waitUntilFormatStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }
}

/// LLM整形パイプライン統合のテスト:
/// 1. 整形が成功した場合、挿入されるテキストは整形後のものになる
/// 2. 整形が失敗した場合、原文へフォールバックする(致命的にならない)
/// 3. `Settings.formattingEnabled == false`の場合、整形自体をスキップする
/// 4. 整形の実行中(await中)にEscでキャンセルされた場合、結果が破棄される
///    (CoordinatorCancelDuringTranscribingTestsの「文字起こし中のキャンセル」と同じ考え方を、
///    「整形中のキャンセル」にも適用する回帰テスト)
@MainActor
final class CoordinatorFormattingTests: XCTestCase {
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
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, textInserter: textInserter, now: clock.now, dictionaryProvider: { [] })

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["こんにちは。"])
    }

    func testRawTextIsUsedWhenFormattingFails() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "生の文字起こし結果")
        let formatter = FixedTextFormatter(outcome: .failure(FakeFormatterError.boom))
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, textInserter: textInserter, now: clock.now, dictionaryProvider: { [] })

        var formattingFailedMessages: [String] = []
        coordinator.onFormattingFailed = { formattingFailedMessages.append($0) }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["生の文字起こし結果"], "整形失敗時は原文へフォールバックするべき")
        XCTAssertEqual(formattingFailedMessages.count, 1, "整形失敗時はonFormattingFailedが1回呼ばれるべき")
    }

    func testFormattingIsSkippedWhenDisabled() async {
        Settings.formattingEnabled = false
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "生の文字起こし結果")
        // 呼ばれたら即座に失敗する(=呼ばれないことを期待する)フォーマッタ。
        let formatter = FixedTextFormatter(outcome: .failure(FakeFormatterError.boom))
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, textInserter: textInserter, now: clock.now, dictionaryProvider: { [] })

        var formattingFailedCount = 0
        coordinator.onFormattingFailed = { _ in formattingFailedCount += 1 }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["生の文字起こし結果"])
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
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, textInserter: textInserter, now: clock.now, dictionaryProvider: { [] })

        await coordinator.beginPushToTalk()
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
            textInserter.insertedTexts.isEmpty,
            "整形実行中にキャンセルされた場合、結果は挿入されず破棄されるべき"
        )
    }

    /// 語彙ヒント(`Settings.sttVocabularyHint`)・整形モデル(`Settings.formattingModel`)が、
    /// ジョブの設定スナップショット経由でフォーマッタへそのまま伝播することを確認する。
    func testVocabularyHintAndModelArePassedToFormatterViaJobSnapshot() async {
        Settings.formattingEnabled = true
        let originalHint = Settings.sttVocabularyHint
        Settings.sttVocabularyHint = "Voicewriter, TestHint"
        defer { Settings.sttVocabularyHint = originalHint }
        let originalModel = Settings.formattingModel
        Settings.formattingModel = "test-model:1b"
        defer { Settings.formattingModel = originalModel }

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "テスト")
        let formatter = ControllableTextFormatter()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, textInserter: textInserter, now: clock.now, dictionaryProvider: { [] })

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        await formatter.waitUntilFormatStarted()
        await formatter.resume(with: .success("テスト。"))

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        let hint = await formatter.lastVocabularyHint
        let model = await formatter.lastModel
        XCTAssertEqual(hint, "Voicewriter, TestHint")
        XCTAssertEqual(model, "test-model:1b")
    }

    /// Codexレビュー指摘#8の回帰テスト: 整形タイムアウト秒数もジョブの録音時点の設定スナップショット
    /// に含まれ、待ち行列中に設定画面から変更されても、既に録音済みのジョブには影響しないべき
    /// (以前は`OllamaFormatter`が実行時に毎回`Settings.formattingTimeoutSeconds`を直接読んでいた)。
    func testFormattingTimeoutSnapshotIsCapturedAtRecordingStartAndNotAffectedByLaterSettingChange() async {
        Settings.formattingEnabled = true
        let originalTimeout = Settings.formattingTimeoutSeconds
        Settings.formattingTimeoutSeconds = 12
        defer { Settings.formattingTimeoutSeconds = originalTimeout }

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "テスト")
        let formatter = ControllableTextFormatter()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, textInserter: textInserter, now: clock.now, dictionaryProvider: { [] })

        await coordinator.beginPushToTalk()
        // 録音中に設定を変更する(待ち行列中の設定変更を模す)。
        Settings.formattingTimeoutSeconds = 3
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        await formatter.waitUntilFormatStarted()
        await formatter.resume(with: .success("テスト。"))

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        let timeout = await formatter.lastTimeoutSeconds
        XCTAssertEqual(timeout, 12, "録音開始時点のタイムアウト設定スナップショットが使われるべき")
    }

    /// Codexレビュー指摘#6の回帰テスト: Escによるキャンセルは、Registryのフラグを立てるだけでなく、
    /// 実行中の整形タスク(実際にはOllamaへのURLSessionリクエスト)自体を`Task.cancel()`で
    /// 中断させ、FIFOの先頭を即座に解放するべき。またキャンセル起因のエラーでは
    /// `onFormattingFailed`(「整形失敗」警告)を出すべきではない。
    func testCancelActuallyInterruptsFormattingTaskAndDoesNotReportFormattingFailedWarning() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "こんにちは")
        let formatter = CancellationAwareTextFormatter()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, textInserter: textInserter, now: clock.now, dictionaryProvider: { [] })

        var committed: [DictationJobCommitEvent] = []
        coordinator.onJobCommitted = { _, result in committed.append(result) }
        var formattingFailedMessages: [String] = []
        coordinator.onFormattingFailed = { formattingFailedMessages.append($0) }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        await formatter.waitUntilFormatStarted()

        // Esc(非録音時キャンセル、まだ挿入されていない最新の未終端ジョブが対象)。
        coordinator.cancelRecording()

        // 実際にキャンセルハンドル(Task.cancel())が呼ばれ、フェイク整形処理が中断されて
        // 短時間で終端することを確認する(以前はフラグを立てるだけで実行中のタスクは解放されず、
        // FIFOの先頭を占有し続けていた)。
        for _ in 0..<200 where coordinator.state != .idle {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(coordinator.state, .idle, "キャンセルされた整形タスクが実際に中断され、短時間でidleへ戻るべき")
        XCTAssertTrue(textInserter.insertedTexts.isEmpty)
        XCTAssertEqual(committed.count, 1)
        if case .cancelled = committed.first {
            // expected
        } else {
            XCTFail("Expected .cancelled, got \(String(describing: committed.first))")
        }
        XCTAssertTrue(formattingFailedMessages.isEmpty, "キャンセル起因のエラーでは「整形失敗」警告を出すべきではない")
    }

    /// Ollama未検出(サーバー到達不可)による整形失敗は、発話のたびに5秒間フェードする警告バナー
    /// (`onFormattingFailed`)ではなく、メニューバーの常設状態表示用の`onFormattingUnavailable`を
    /// 呼ぶべき(Ollama未導入は例外的な障害ではなく通常運用でありうる状態のため、ナグを避ける)。
    func testServerUnavailableCallsOnFormattingUnavailableNotOnFormattingFailed() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "生の文字起こし結果")
        let formatter = FixedTextFormatter(outcome: .failure(TextFormatterError.serverUnavailable("connection refused")))
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, textInserter: textInserter, now: clock.now, dictionaryProvider: { [] })

        var formattingFailedCount = 0
        coordinator.onFormattingFailed = { _ in formattingFailedCount += 1 }
        var formattingUnavailableCount = 0
        coordinator.onFormattingUnavailable = { formattingUnavailableCount += 1 }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["生の文字起こし結果"], "Ollama未検出時も原文へフォールバックするべき")
        XCTAssertEqual(formattingUnavailableCount, 1, "Ollama未検出時はonFormattingUnavailableが1回呼ばれるべき")
        XCTAssertEqual(formattingFailedCount, 0, "Ollama未検出時は5秒間のナグ警告(onFormattingFailed)を出すべきではない")
    }

    /// 整形が成功した場合は、Ollama未検出からの回復を示す`onFormattingRecovered`が呼ばれるべき
    /// (メニューバーの「LLM整形: 無効(Ollama未検出)」表示を消す契機に使う)。
    func testFormattingSuccessCallsOnFormattingRecovered() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "えーっと、こんにちは")
        let formatter = FixedTextFormatter(outcome: .success("こんにちは。"))
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, textInserter: textInserter, now: clock.now, dictionaryProvider: { [] })

        var formattingRecoveredCount = 0
        coordinator.onFormattingRecovered = { formattingRecoveredCount += 1 }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(formattingRecoveredCount, 1, "整形成功時はonFormattingRecoveredが1回呼ばれるべき")
    }

    /// HUD表示用の`onPhaseChanged`が、整形が実際に行われる場合は
    /// 認識中→整形中の順で通知されることを確認する(状態機械`AppState`自体は`.transcribing`のまま)。
    func testPhaseChangedNotifiesRecognizingThenFormattingWhenFormattingWillRun() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "こんにちは")
        let formatter = FixedTextFormatter(outcome: .success("こんにちは。"))
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, textInserter: textInserter, now: clock.now, dictionaryProvider: { [] })

        var phases: [TranscriptionPhase] = []
        coordinator.onPhaseChanged = { phases.append($0) }

        await coordinator.beginPushToTalk()
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
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: formatter, textInserter: textInserter, now: clock.now, dictionaryProvider: { [] })

        var phases: [TranscriptionPhase] = []
        coordinator.onPhaseChanged = { phases.append($0) }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(phases, [.recognizing])
    }
}
