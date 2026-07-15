import XCTest
@testable import Voicewriter

/// Codexレビュー指摘#5(デバイス切断時、フォーマット検証やコンバータ生成失敗の確認なしに
/// installTapしており、例外クラッシュや無音録音になりうる)の回帰テスト。
/// `AVAudioEngine`実機・ハードウェア依存の統合テストは対象外とし、
/// タップ設置前のフォーマット妥当性検証だけを純粋関数として切り出してテストする。
final class AudioCaptureEngineFormatTests: XCTestCase {
    func testValidFormatIsAccepted() {
        XCTAssertTrue(AudioCaptureEngine.isValidInputFormat(sampleRate: 48000, channelCount: 1))
        XCTAssertTrue(AudioCaptureEngine.isValidInputFormat(sampleRate: 16000, channelCount: 2))
    }

    func testZeroSampleRateIsRejected() {
        XCTAssertFalse(AudioCaptureEngine.isValidInputFormat(sampleRate: 0, channelCount: 1))
    }

    func testZeroChannelCountIsRejected() {
        XCTAssertFalse(AudioCaptureEngine.isValidInputFormat(sampleRate: 48000, channelCount: 0))
    }

    func testNonFiniteSampleRateIsRejected() {
        XCTAssertFalse(AudioCaptureEngine.isValidInputFormat(sampleRate: .nan, channelCount: 1))
        XCTAssertFalse(AudioCaptureEngine.isValidInputFormat(sampleRate: .infinity, channelCount: 1))
    }

    func testNegativeSampleRateIsRejected() {
        XCTAssertFalse(AudioCaptureEngine.isValidInputFormat(sampleRate: -48000, channelCount: 1))
    }

    // HUDのレベルメーター表示に使う`computeRMS`(純粋関数)の回帰テスト。
    func testComputeRMSOfEmptyArrayIsZero() {
        XCTAssertEqual(AudioCaptureEngine.computeRMS([]), 0)
    }

    func testComputeRMSOfSilenceIsZero() {
        XCTAssertEqual(AudioCaptureEngine.computeRMS([0, 0, 0, 0]), 0)
    }

    func testComputeRMSOfConstantSignalMatchesItsMagnitude() {
        // 全サンプルが同一の絶対値であれば、RMSはその絶対値と一致する。
        XCTAssertEqual(AudioCaptureEngine.computeRMS([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 0.0001)
    }

    func testComputeRMSIsNeverNegative() {
        XCTAssertGreaterThanOrEqual(AudioCaptureEngine.computeRMS([-1, 1, -0.3, 0.2]), 0)
    }
}
