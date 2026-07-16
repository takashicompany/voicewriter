import XCTest
@testable import Voicewriter

/// テスト用のフェイク`AudioCaptureEngineControlling`実装(他のCoordinatorテストと同じもの)。
private final class FakeAudioCaptureEngine: AudioCaptureEngineControlling {
    weak var delegate: AudioCaptureEngineDelegate?
    func startRecording() {}
    func stopRecording() {}
    func cancelRecording() {}
}

/// テスト用の単調増加フェイク時計。`step`秒ずつ進む値を返すことで、
/// 「録音実効長(キー押下〜離しの長さ)」を決定的に制御する。
private final class FakeClock {
    private var current = Date(timeIntervalSince1970: 1_700_000_000)
    private let step: TimeInterval
    init(step: TimeInterval) { self.step = step }
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

/// `transcribe(...)`が実際に呼ばれたかどうかを記録するフェイク。
/// ハルシネーション対策の第1層/第2層は「whisper_full自体を呼ばない」ことが要件のため、
/// 呼び出し回数そのものを検証する。
private final class RecordingCountingTranscriptionEngine: TranscriptionEngine {
    private(set) var callCount = 0
    private(set) var lastVadEnabled: Bool?
    let text: String
    init(text: String = "こんにちは") { self.text = text }
    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
        callCount += 1
        lastVadEnabled = vadEnabled
        return text
    }
}

/// ハルシネーション対策(多層防御)のうち、`Coordinator`が担当する層の統合テスト:
/// - 第1層: 最短録音時間ガード(既定0.3秒未満はwhisper_full自体を呼ばずスキップ)
/// - 第2層: エネルギーゲート(発話とみなせるエネルギーが無ければスキップ)
/// - 第5層: 既知ハルシネーション定型句フィルタ(出力全体が定型句のみの場合は空扱い)
/// 第3層(VAD)・第4層(no_speech_probセグメントフィルタ)は`WhisperCppEngine`内部の実装であり、
/// 別ファイル(`WhisperCppEngineSegmentFilterTests`)で純粋関数として検証している。
@MainActor
final class CoordinatorRecordingSkipTests: XCTestCase {
    private let sufficientEnergySamples: [Float] = Array(repeating: Float(0.3), count: 4800)
    private let silentSamples: [Float] = Array(repeating: Float(0), count: 4800)

    func testTooShortRecordingSkipsTranscriptionEntirely() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = RecordingCountingTranscriptionEngine()
        // 押下から離すまでを0.1秒(閾値0.3秒未満)としてシミュレートする。
        let clock = FakeClock(step: 0.1)
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var committed: [DictationJobCommitEvent] = []
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: sufficientEnergySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(transcriptionEngine.callCount, 0, "閾値未満の録音はwhisper_full(transcribe)自体を呼ばないべき")
        XCTAssertTrue(textInserter.insertedTexts.isEmpty, "短すぎる録音は挿入されないべき")
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first.flatMap(Self.skipReason), .tooShort)
    }

    func testSufficientlyLongButSilentRecordingSkipsTranscriptionEntirely() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = RecordingCountingTranscriptionEngine()
        // 押下から離すまでを1秒(閾値は十分満たす)としてシミュレートする。
        let clock = FakeClock(step: 1.0)
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var committed: [DictationJobCommitEvent] = []
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: silentSamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(transcriptionEngine.callCount, 0, "無音の録音はwhisper_full(transcribe)自体を呼ばないべき")
        XCTAssertTrue(textInserter.insertedTexts.isEmpty, "無音の録音は挿入されないべき")
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first.flatMap(Self.skipReason), .silence)
    }

    func testLongEnoughAndLoudRecordingIsTranscribedNormally() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = RecordingCountingTranscriptionEngine(text: "こんにちは、今日は良い天気ですね")
        let clock = FakeClock(step: 1.0)
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var committed: [DictationJobCommitEvent] = []
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: sufficientEnergySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(transcriptionEngine.callCount, 1, "通常の録音はtranscribeが呼ばれるべき")
        XCTAssertEqual(textInserter.insertedTexts, ["こんにちは、今日は良い天気ですね"])
        XCTAssertEqual(committed.count, 1)
        XCTAssertNil(committed.first.flatMap(Self.skipReason))
    }

    /// 第5層: whisper.cppの出力が既知のハルシネーション定型句のみだった場合、
    /// テキスト挿入もLLM整形も行わず`.skipped(.silence)`としてコミットされるべき。
    func testOutputThatIsOnlyAKnownHallucinationPhraseIsDiscarded() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = RecordingCountingTranscriptionEngine(text: "ご視聴ありがとうございました。")
        let clock = FakeClock(step: 1.0)
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var committed: [DictationJobCommitEvent] = []
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: sufficientEnergySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(transcriptionEngine.callCount, 1, "第5層はtranscribe後の出力に対するフィルタなので、transcribe自体は呼ばれる")
        XCTAssertTrue(textInserter.insertedTexts.isEmpty, "既知の定型句のみの出力は挿入されないべき")
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first.flatMap(Self.skipReason), .silence)
    }

    /// 混在ケース: ハルシネーション定型句が実発話の一部として含まれていても、
    /// 出力全体が定型句だけでなければ棄却してはならない。
    func testOutputContainingPhraseAlongsideRealSpeechIsNotDiscarded() async {
        let audioEngine = FakeAudioCaptureEngine()
        let realSpeechWithPhrase = "今日の会議の内容を共有します。ご視聴ありがとうございました。"
        let transcriptionEngine = RecordingCountingTranscriptionEngine(text: realSpeechWithPhrase)
        let clock = FakeClock(step: 1.0)
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        var committed: [DictationJobCommitEvent] = []
        coordinator.onJobCommitted = { _, result in committed.append(result) }

        await coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: sufficientEnergySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(textInserter.insertedTexts, [realSpeechWithPhrase], "定型句が実発話の一部に含まれるだけの場合は挿入されるべき")
        XCTAssertEqual(committed.count, 1)
        XCTAssertNil(committed.first.flatMap(Self.skipReason))
    }

    private static func skipReason(_ event: DictationJobCommitEvent) -> RecordingSkipReason? {
        if case .skipped(let reason) = event { return reason }
        return nil
    }

    /// Codexレビュー指摘#8の回帰テスト: VAD有効/無効はジョブの録音時点の設定スナップショットに
    /// 含まれ、待ち行列中に設定画面から変更されても、既に録音済みのジョブには影響しないべき
    /// (以前は`WhisperCppEngine`が実行時に毎回`Settings.vadEnabled`を直接読んでいた)。
    func testVadEnabledSnapshotIsCapturedAtRecordingStartAndNotAffectedByLaterSettingChange() async {
        let originalVadEnabled = Settings.vadEnabled
        Settings.vadEnabled = true
        defer { Settings.vadEnabled = originalVadEnabled }

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = RecordingCountingTranscriptionEngine()
        let clock = FakeClock(step: 1.0)
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textInserter: textInserter, now: clock.now)

        await coordinator.beginPushToTalk()
        // 録音中に設定を変更する(待ち行列中の設定変更を模す)。
        Settings.vadEnabled = false
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: sufficientEnergySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(transcriptionEngine.lastVadEnabled, true, "録音開始時点(true)のVAD設定スナップショットが使われるべき")
    }
}
