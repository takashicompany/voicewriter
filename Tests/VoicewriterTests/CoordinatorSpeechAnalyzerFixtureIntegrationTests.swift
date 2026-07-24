import AVFoundation
import XCTest
@testable import Voicewriter

/// 実機バグ調査(SpeechAnalyzerストリーミングモードで何も表示・挿入されない)のための、
/// `Coordinator`を含む完全なパイプラインの結合テスト。
///
/// `CoordinatorStreamingPipelineTests`はフェイク`StreamingTranscriptionEngine`で
/// Coordinatorとの配線ロジックのみを検証しており、`SpeechAnalyzerEngineIntegrationTests`は
/// 実際の`SpeechAnalyzerEngine`/`SpeechAnalyzerSession`を検証しているが`Coordinator`を経由しない
/// (セッションへ直接サンプルを渡している)。本テストはその中間: 実際の`SpeechAnalyzerEngine`を
/// `Coordinator`へ注入し、`Coordinator.supplyStreamingAudioChunk`(実`AudioCaptureEngine`が
/// 呼ぶのと同じエントリポイント)経由でフィクスチャWAVを流し込み、
/// ライブプレビュー(`onStreamingPreviewUpdate`)〜確定〜挿入までの全経路を実機のSpeechAnalyzerで検証する。
///
/// 実機でのマイク入力の合成が困難なため、タスクの指示に従い「フィクスチャWAVをストリーミング
/// セッションに直接流す統合テスト」としてこれを代替検証に用いる。
@available(macOS 26.0, *)
@MainActor
final class CoordinatorSpeechAnalyzerFixtureIntegrationTests: XCTestCase {
    private func requireStreamingSupport() async throws {
        let status = await StreamingTranscriptionAvailability.currentStatus()
        try XCTSkipUnless(status.isSupported, "この環境ではSpeechAnalyzerストリーミングが利用できないためスキップ: \(status.reason ?? "unknown")")
    }

    private func loadSamples(fixtureName: String) throws -> (samples: [Float], sampleRate: Double) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/VoicewriterTests/<this file>.swift -> Tests/VoicewriterTests
            .deletingLastPathComponent() // -> Tests
            .deletingLastPathComponent() // -> リポジトリルート
            .appendingPathComponent("scripts/fixtures/\(fixtureName)")
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "CoordinatorSpeechAnalyzerFixtureIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to allocate PCM buffer"])
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { return ([], file.processingFormat.sampleRate) }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        return (samples, file.processingFormat.sampleRate)
    }

    private final class FakeAudioCaptureEngine: AudioCaptureEngineControlling {
        weak var delegate: AudioCaptureEngineDelegate?
        private(set) var startRecordingCallCount = 0
        private(set) var stopRecordingCallCount = 0
        private(set) var cancelRecordingCallCount = 0
        func startRecording() { startRecordingCallCount += 1 }
        func stopRecording() { stopRecordingCallCount += 1 }
        func cancelRecording() { cancelRecordingCallCount += 1 }
    }

    private final class FakeTextInserter: TextInserting {
        private(set) var insertedTexts: [String] = []
        func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
            insertedTexts.append(text)
            onPasted()
        }
    }

    /// このテストではwhisper.cpp経路は絶対に呼ばれてはいけない(ストリーミングモードの仕様)。
    private final class MustNotBeCalledTranscriptionEngine: TranscriptionEngine {
        func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
            XCTFail("SpeechAnalyzerストリーミングモードではwhisper.cpp(TranscriptionEngine.transcribe)を呼んではいけない")
            return "should-not-be-used"
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

    /// 実際の`SpeechAnalyzerEngine`を注入した`Coordinator`へ、実`AudioCaptureEngine`が呼ぶのと
    /// 同じ`supplyStreamingAudioChunk`経由でフィクスチャWAV(実発話)を流し込み、
    /// ライブプレビュー更新が発生すること、および最終的にSpeechAnalyzerの確定テキストが
    /// (whisper.cppを経由せず)そのまま挿入経路に乗ることを検証する。
    func testFixtureWavThroughCoordinatorProducesPreviewAndInsertion() async throws {
        try await requireStreamingSupport()
        Settings.sttEngine = .speechAnalyzer

        let (samples, sampleRate) = try loadSamples(fixtureName: "sample-ja-16k.wav")
        XCTAssertFalse(samples.isEmpty)

        let audioEngine = FakeAudioCaptureEngine()
        let transcriptionEngine = MustNotBeCalledTranscriptionEngine()
        let streamingEngine = SpeechAnalyzerEngine(locale: Locale(identifier: StreamingTranscriptionAvailability.targetLocaleIdentifier))
        let textInserter = FakeTextInserter()
        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            streamingEngine: streamingEngine,
            textInserter: textInserter,
            dictionaryProvider: { [] }
        )

        var previewUpdates: [(finalized: String, volatile: String)] = []
        var sawNonEmptyUpdateBeforeStop = false
        var recordingStopped = false
        coordinator.onStreamingPreviewUpdate = { finalizedText, volatileText in
            previewUpdates.append((finalizedText, volatileText))
            if !recordingStopped, !finalizedText.isEmpty || !volatileText.isEmpty {
                sawNonEmptyUpdateBeforeStop = true
            }
        }
        var committed: [(Int, DictationJobCommitEvent)] = []
        coordinator.onJobCommitted = { sequence, result in committed.append((sequence, result)) }

        await coordinator.beginPushToTalk()

        // 実`AudioCaptureEngine.handleIncomingLocked`と同様、~100msチャンクで
        // `Coordinator.supplyStreamingAudioChunk`(実マイク入力時と全く同じエントリポイント)へ
        // 流し込む。チャンク間に短いsleepを挟み、バックグラウンドの`AsyncStream`処理・
        // フォーマット変換・SpeechAnalyzerへの供給が擬似リアルタイムで進むようにする。
        let chunkSize = max(1, Int(sampleRate * 0.1))
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            coordinator.supplyStreamingAudioChunk(Array(samples[offset..<end]), sampleRate: sampleRate)
            offset = end
            // 実マイク入力と同じ速度(等速)でチャンクを供給する。以前は20msの固定sleepで
            // (チャンク自体は音声100ms分)音声を実時間の5倍速で流し込んでいたため、
            // SpeechAnalyzerが本来リアルタイムの録音中に出すはずのvolatile結果が、
            // 録音「後」にまとめて届くという不自然な条件になっていた(実マイクでの挙動を
            // 正しく代替できていなかった)。
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // 実機バグ回帰テスト(発話中にライブプレビューが一切表示されない): ここまでの時点
        // (=まだ`endPushToTalk()`/`didFinishRecording`を呼んでいない、キーを離す前)で、
        // 非空テキストを持つプレビュー更新が最低1回は届いているべき。修正前
        // (`SpeechTranscriberFactory`が`.fastResults`を指定していなかった頃)は、この端末では
        // `.update`が録音終了後にまとめてバーストで届いていたため、このアサーションは失敗していた。
        XCTAssertTrue(
            sawNonEmptyUpdateBeforeStop,
            "キーを離す(endPushToTalk)前、つまり音声供給中に一度も非空のライブプレビュー更新が" +
            "発火しなかった。実機バグ(発話中にライブプレビューが一切更新されず、キーを離した後に" +
            "まとめて表示される)の再現を疑う。"
        )

        recordingStopped = true
        coordinator.endPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didFinishRecording: samples, sampleRate: sampleRate)

        for _ in 0..<200 where committed.isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms x 200 = up to 10s real wall-clock wait
        }

        XCTAssertFalse(
            previewUpdates.isEmpty,
            "録音中に一度もライブプレビュー更新(onStreamingPreviewUpdate)が発火しなかった。" +
            "実機バグ(ライブプレビューが一切表示されない)の再現を疑う。"
        )

        XCTAssertEqual(committed.count, 1)
        guard case .inserted(let text, _) = committed.first?.1 else {
            return XCTFail("ジョブがinsertedとしてコミットされなかった: \(String(describing: committed.first?.1))")
        }
        XCTAssertTrue(
            text.contains("こんにちは") && text.contains("天気"),
            "フィクスチャの発話内容(「こんにちは、今日は良い天気ですね…」)に対応する確定テキストが" +
            "Coordinator経由の挿入経路に乗るべき。実際の挿入テキスト: \(text)"
        )
        XCTAssertEqual(textInserter.insertedTexts, [text])
    }
}
