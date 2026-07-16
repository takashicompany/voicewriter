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

/// `transcribe(samples:sampleRate:)`が実際に呼ばれたかどうかを記録するフェイク。
/// ハルシネーション対策の第1層/第2層は「whisper_full自体を呼ばない」ことが要件のため、
/// 呼び出し回数そのものを検証する。
private final class RecordingCountingTranscriptionEngine: TranscriptionEngine {
    private(set) var callCount = 0
    let text: String
    init(text: String = "こんにちは") { self.text = text }
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        callCount += 1
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
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, now: clock.now)

        var insertedResults: [String] = []
        coordinator.onTranscriptionResult = { text, _ in insertedResults.append(text) }
        var skippedReasons: [RecordingSkipReason] = []
        coordinator.onRecordingSkipped = { skippedReasons.append($0) }

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: sufficientEnergySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(transcriptionEngine.callCount, 0, "閾値未満の録音はwhisper_full(transcribe)自体を呼ばないべき")
        XCTAssertTrue(insertedResults.isEmpty, "短すぎる録音は挿入されないべき")
        XCTAssertEqual(skippedReasons, [.tooShort])
    }

    func testSufficientlyLongButSilentRecordingSkipsTranscriptionEntirely() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = RecordingCountingTranscriptionEngine()
        // 押下から離すまでを1秒(閾値は十分満たす)としてシミュレートする。
        let clock = FakeClock(step: 1.0)
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, now: clock.now)

        var insertedResults: [String] = []
        coordinator.onTranscriptionResult = { text, _ in insertedResults.append(text) }
        var skippedReasons: [RecordingSkipReason] = []
        coordinator.onRecordingSkipped = { skippedReasons.append($0) }

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: silentSamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(transcriptionEngine.callCount, 0, "無音の録音はwhisper_full(transcribe)自体を呼ばないべき")
        XCTAssertTrue(insertedResults.isEmpty, "無音の録音は挿入されないべき")
        XCTAssertEqual(skippedReasons, [.silence])
    }

    func testLongEnoughAndLoudRecordingIsTranscribedNormally() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = RecordingCountingTranscriptionEngine(text: "こんにちは、今日は良い天気ですね")
        let clock = FakeClock(step: 1.0)
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, now: clock.now)

        var insertedResults: [String] = []
        coordinator.onTranscriptionResult = { text, _ in insertedResults.append(text) }
        var skippedReasons: [RecordingSkipReason] = []
        coordinator.onRecordingSkipped = { skippedReasons.append($0) }

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: sufficientEnergySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(transcriptionEngine.callCount, 1, "通常の録音はtranscribeが呼ばれるべき")
        XCTAssertEqual(insertedResults, ["こんにちは、今日は良い天気ですね"])
        XCTAssertTrue(skippedReasons.isEmpty)
    }

    /// 第5層: whisper.cppの出力が既知のハルシネーション定型句のみだった場合、
    /// テキスト挿入もLLM整形も行わず`onRecordingSkipped(.silence)`が呼ばれるべき。
    func testOutputThatIsOnlyAKnownHallucinationPhraseIsDiscarded() async {
        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = RecordingCountingTranscriptionEngine(text: "ご視聴ありがとうございました。")
        let clock = FakeClock(step: 1.0)
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, now: clock.now)

        var insertedResults: [String] = []
        coordinator.onTranscriptionResult = { text, _ in insertedResults.append(text) }
        var skippedReasons: [RecordingSkipReason] = []
        coordinator.onRecordingSkipped = { skippedReasons.append($0) }

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: sufficientEnergySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(transcriptionEngine.callCount, 1, "第5層はtranscribe後の出力に対するフィルタなので、transcribe自体は呼ばれる")
        XCTAssertTrue(insertedResults.isEmpty, "既知の定型句のみの出力は挿入されないべき")
        XCTAssertEqual(skippedReasons, [.silence])
    }

    /// 混在ケース: ハルシネーション定型句が実発話の一部として含まれていても、
    /// 出力全体が定型句だけでなければ棄却してはならない。
    func testOutputContainingPhraseAlongsideRealSpeechIsNotDiscarded() async {
        let audioEngine = FakeAudioCaptureEngine()
        let realSpeechWithPhrase = "今日の会議の内容を共有します。ご視聴ありがとうございました。"
        let transcriptionEngine = RecordingCountingTranscriptionEngine(text: realSpeechWithPhrase)
        let clock = FakeClock(step: 1.0)
        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, now: clock.now)

        var insertedResults: [String] = []
        coordinator.onTranscriptionResult = { text, _ in insertedResults.append(text) }
        var skippedReasons: [RecordingSkipReason] = []
        coordinator.onRecordingSkipped = { skippedReasons.append($0) }

        coordinator.beginPushToTalk()
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: sufficientEnergySamples, sampleRate: 16000)

        for _ in 0..<200 where coordinator.state != .idle {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(insertedResults, [realSpeechWithPhrase], "定型句が実発話の一部に含まれるだけの場合は挿入されるべき")
        XCTAssertTrue(skippedReasons.isEmpty)
    }
}
