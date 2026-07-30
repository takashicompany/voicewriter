import XCTest
@testable import Voicewriter

private final class FakeAudioCaptureEngine: AudioCaptureEngineControlling {
    weak var delegate: AudioCaptureEngineDelegate?
    private(set) var cancelCount = 0
    func startRecording() {}
    func stopRecording() {}
    func cancelRecording() { cancelCount += 1 }
}

private final class StubTranscriber: TranscriptionEngine {
    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
        ""
    }
}

private final class NoopTextInserter: TextInserting {
    func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
        onPasted()
    }
}

/// オーディオデバイス障害(タップ再設置失敗)の警告表示と、自動復旧時の取り下げの回帰テスト。
///
/// 背景: 既定入力デバイスがBluetoothヘッドセットのとき、`AVAudioEngineConfigurationChange`後に
/// `installTap`がNSExceptionをraiseしてプロセスがabortしていた(2026-07-30の起動時クラッシュ)。
/// 修正では例外を捕捉して「タップ未設置」として扱い、復旧できたらメニューバー警告を取り下げる。
@MainActor
final class CoordinatorAudioDeviceRecoveryTests: XCTestCase {
    private func makeCoordinator(_ audioEngine: FakeAudioCaptureEngine) -> Coordinator {
        Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: StubTranscriber(),
            textInserter: NoopTextInserter(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            dictionaryProvider: { [] }
        )
    }

    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    func testFatalErrorIsReportedAndWithdrawnOnRecovery() async {
        let audioEngine = FakeAudioCaptureEngine()
        let coordinator = makeCoordinator(audioEngine)

        var warnings: [String] = []
        var withdrawn: [String] = []
        coordinator.onFatalAudioError = { warnings.append($0) }
        coordinator.onFatalAudioErrorRecovered = { withdrawn.append($0) }

        coordinator.audioCaptureEngine(audioEngine, didEncounterFatalError: "マイク入力を利用できません")
        await drain()
        XCTAssertEqual(warnings, ["マイク入力を利用できません"])
        XCTAssertTrue(withdrawn.isEmpty)

        coordinator.audioCaptureEngineDidRecoverFromFatalError(audioEngine)
        await drain()
        XCTAssertEqual(withdrawn, ["マイク入力を利用できません"], "復旧時は同じメッセージで警告を取り下げること")
    }

    func testRecoveryWithoutAPriorFatalErrorDoesNothing() async {
        let audioEngine = FakeAudioCaptureEngine()
        let coordinator = makeCoordinator(audioEngine)

        var withdrawn: [String] = []
        coordinator.onFatalAudioErrorRecovered = { withdrawn.append($0) }

        coordinator.audioCaptureEngineDidRecoverFromFatalError(audioEngine)
        await drain()
        XCTAssertTrue(withdrawn.isEmpty)
    }

    func testWarningIsWithdrawnOnlyOnceEvenIfRecoveryIsReportedTwice() async {
        let audioEngine = FakeAudioCaptureEngine()
        let coordinator = makeCoordinator(audioEngine)

        var withdrawn: [String] = []
        coordinator.onFatalAudioError = { _ in }
        coordinator.onFatalAudioErrorRecovered = { withdrawn.append($0) }

        coordinator.audioCaptureEngine(audioEngine, didEncounterFatalError: "エラーA")
        await drain()
        coordinator.audioCaptureEngineDidRecoverFromFatalError(audioEngine)
        coordinator.audioCaptureEngineDidRecoverFromFatalError(audioEngine)
        await drain()
        XCTAssertEqual(withdrawn, ["エラーA"])
    }

    func testAllOutstandingWarningsAreWithdrawnOnRecovery() async {
        let audioEngine = FakeAudioCaptureEngine()
        let coordinator = makeCoordinator(audioEngine)

        var withdrawn: Set<String> = []
        coordinator.onFatalAudioError = { _ in }
        coordinator.onFatalAudioErrorRecovered = { withdrawn.insert($0) }

        coordinator.audioCaptureEngine(audioEngine, didEncounterFatalError: "エラーA")
        coordinator.audioCaptureEngine(audioEngine, didEncounterFatalError: "エラーB")
        await drain()
        coordinator.audioCaptureEngineDidRecoverFromFatalError(audioEngine)
        await drain()
        XCTAssertEqual(withdrawn, ["エラーA", "エラーB"])
    }

    func testRecordingIsReturnedToIdleOnFatalError() async {
        let audioEngine = FakeAudioCaptureEngine()
        let coordinator = makeCoordinator(audioEngine)
        coordinator.onFatalAudioError = { _ in }

        await coordinator.beginPushToTalk()
        coordinator.audioCaptureEngine(audioEngine, didEncounterFatalError: "音声デバイスの構成が変わったため録音を中断しました")
        await drain()

        XCTAssertEqual(coordinator.state, .idle, "致命的エラー後は録音状態をidleへ戻すこと")
    }
}
