import XCTest
@testable import Voicewriter

/// テスト用のフェイク`AudioCaptureEngineControlling`実装(他のCoordinatorテストと同じもの)。
private final class FakeAudioCaptureEngine: AudioCaptureEngineControlling {
    weak var delegate: AudioCaptureEngineDelegate?
    func startRecording() {}
    func stopRecording() {}
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

/// 即座に固定の成功/失敗を返すシンプルなフェイク`TextFormatter`。
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

/// 整形の開始まで待機し、任意のタイミングで結果を返せるフェイク`TextFormatter`
/// (`CoordinatorFormattingTests.ControllableTextFormatter`と同じ方針。ジョブ処理中に
/// テスト側から辞書を書き換えるタイミングを制御するために使う)。
private actor ControllableTextFormatter: TextFormatter {
    private var resultContinuation: CheckedContinuation<String, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    private(set) var lastVocabularyHint: String?

    func format(text: String, vocabularyHint: String, model: String, timeoutSeconds: TimeInterval) async throws -> String {
        hasStarted = true
        lastVocabularyHint = vocabularyHint
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

    func resume(with text: String) {
        resultContinuation?.resume(returning: text)
        resultContinuation = nil
    }
}

/// テスト側から`rules`を差し替えられるだけの単純な可変ホルダー。
/// `Coordinator(dictionaryProvider:)`へ`{ holder.rules }`として渡すことで、実ファイル
/// (`UserDictionaryStore.shared`)へ一切触れずに「録音開始時点の辞書」を制御する。
@MainActor
private final class MutableRulesHolder {
    var rules: [UserDictionaryRule]
    init(rules: [UserDictionaryRule] = []) { self.rules = rules }
}

/// ユーザー辞書(置換ルール)のパイプライン統合テスト。
/// 1. LLM整形が有効な場合、整形後のテキストに辞書が最終適用されること
/// 2. 整形が無効/失敗した場合、whisper生出力(のフォールバック)に辞書が最終適用されること
/// 3. 録音開始後(=ジョブの設定スナップショット確定後)に辞書(`dictionaryProvider`が返す値)を
///    書き換えても、既に録音済みのそのジョブには影響しないこと
@MainActor
final class CoordinatorDictionaryTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.formattingEnabled)
        super.tearDown()
    }

    func testDictionaryIsAppliedAfterSuccessfulFormatting() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "ぼいすらいだーを起動")
        let formatter = FixedTextFormatter(outcome: .success("ボイスライダーを起動しました。"))
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let holder = MutableRulesHolder(rules: [UserDictionaryRule(from: "ボイスライダー", to: "Voicewriter")])
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            textFormatter: formatter,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { holder.rules }
        )

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["Voicewriterを起動しました。"], "整形後のテキストに辞書が最終適用されるべき")
    }

    func testDictionaryIsAppliedToRawTextWhenFormattingDisabled() async {
        Settings.formattingEnabled = false
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "ボイスライダーで音声入力")
        // 整形が呼ばれないことを期待するため、呼ばれたら失敗するフォーマッタを使う。
        let formatter = FixedTextFormatter(outcome: .failure(FakeFormatterError.boom))
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let holder = MutableRulesHolder(rules: [UserDictionaryRule(from: "ボイスライダー", to: "Voicewriter")])
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            textFormatter: formatter,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { holder.rules }
        )

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["Voicewriterで音声入力"], "整形無効時もwhisper生出力へ辞書が最終適用されるべき")
    }

    func testDictionaryIsAppliedToRawTextWhenFormattingFails() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "ボイスライダーで音声入力")
        let formatter = FixedTextFormatter(outcome: .failure(FakeFormatterError.boom))
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let holder = MutableRulesHolder(rules: [UserDictionaryRule(from: "ボイスライダー", to: "Voicewriter")])
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            textFormatter: formatter,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { holder.rules }
        )

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["Voicewriterで音声入力"], "整形失敗によるフォールバック後も辞書が最終適用されるべき")
    }

    func testDisabledRuleIsNotAppliedByPipeline() async {
        Settings.formattingEnabled = false
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "ボイスライダーで音声入力")
        let formatter = FixedTextFormatter(outcome: .failure(FakeFormatterError.boom))
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let holder = MutableRulesHolder(rules: [UserDictionaryRule(from: "ボイスライダー", to: "Voicewriter", isEnabled: false)])
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            textFormatter: formatter,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { holder.rules }
        )

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["ボイスライダーで音声入力"], "無効化されたルールは適用されないべき")
    }

    /// 核心の回帰テスト: 録音開始時点(=ジョブの設定スナップショット確定時点)より後に
    /// `dictionaryProvider`が返す辞書の内容を書き換えても、既に録音済みの当該ジョブは
    /// 録音開始時点のスナップショットのまま処理されるべき(待ち行列中の設定変更が既存ジョブに
    /// 影響しないという既存の不変条件と同じものを、辞書についても満たす)。
    func testDictionaryChangeAfterRecordingStartedDoesNotAffectAlreadyRecordedJob() async {
        Settings.formattingEnabled = true
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "ボイスライダーで音声入力")
        let formatter = ControllableTextFormatter()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        // 録音開始時点では辞書が空。
        let holder = MutableRulesHolder(rules: [])
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            textFormatter: formatter,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { holder.rules }
        )

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        // ジョブ処理中(整形の完了を待つ間)に辞書を書き換える。既に録音開始時点で
        // スナップショットは確定済みのため、このジョブには影響しないはず。
        await formatter.waitUntilFormatStarted()
        holder.rules = [UserDictionaryRule(from: "ボイスライダー", to: "Voicewriter")]

        await formatter.resume(with: "ボイスライダーで音声入力しました。")

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(
            textInserter.insertedTexts,
            ["ボイスライダーで音声入力しました。"],
            "録音後に辞書を書き換えても、既に録音済みのジョブには反映されないべき"
        )

        // 次のジョブ(この書き換え後に録音開始したもの)には新しい辞書が反映されることの確認
        // (「影響しない」が単に辞書読み込みが壊れているだけではないことの裏付け)。
        let formatter2 = FixedTextFormatter(outcome: .success("ボイスライダーで音声入力しました。"))
        let coordinator2 = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            textFormatter: formatter2,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { holder.rules }
        )
        await coordinator2.beginPushToTalk()
        coordinator2.endPushToTalk()
        coordinator2.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)
        for _ in 0..<200 where coordinator2.state != .idle {
            await Task.yield()
        }
        XCTAssertEqual(textInserter.insertedTexts.last, "Voicewriterで音声入力しました。", "新しい録音では更新後の辞書が反映されるべき")
    }

    /// 語彙ヒントへの自動連動: 有効な置換先(`to`)がwhisper/LLM整形へ渡す語彙ヒントに
    /// 追加されることを、フォーマッタが実際に受け取った`vocabularyHint`引数で確認する。
    func testDictionaryTermsAreAddedToVocabularyHintPassedToFormatter() async {
        Settings.formattingEnabled = true
        let originalHint = Settings.sttVocabularyHint
        Settings.sttVocabularyHint = "Voicewriter"
        defer { Settings.sttVocabularyHint = originalHint }

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = ImmediateTranscriptionEngine(text: "テスト")
        let formatter = ControllableTextFormatter()
        let clock = FakeClock()
        let textInserter = FakeTextInserter()
        let holder = MutableRulesHolder(rules: [UserDictionaryRule(from: "きゃやっく", to: "KAYAC")])
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            textFormatter: formatter,
            textInserter: textInserter,
            now: clock.now,
            dictionaryProvider: { holder.rules }
        )

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: nonSilentDummySamples, sampleRate: 16000)

        await formatter.waitUntilFormatStarted()
        let hintSeenByFormatter = await formatter.lastVocabularyHint
        await formatter.resume(with: "テスト。")

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(textInserter.insertedTexts, ["テスト。"])
        // whisperのinitial_promptとLLM整形の語彙注入は、いずれも同じ
        // `DictationJobSettingsSnapshot.vocabularyHint`を経由するため、フォーマッタが受け取った
        // 値を見れば両方への連動を確認できる。
        XCTAssertEqual(hintSeenByFormatter, "Voicewriter, KAYAC", "有効な置換先の語が既存の語彙ヒントへ自動的に追加されるべき")
    }
}
