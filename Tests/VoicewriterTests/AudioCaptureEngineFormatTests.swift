import AVFoundation
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

    // MARK: - タップ設置可否の事前条件(起動時クラッシュ SIGABRT の回帰テスト)
    //
    // 2026-07-30の起動時クラッシュ: Bluetoothヘッドセット(入力16kHz/出力44.1kHz)が既定入力
    // デバイスの状態で起動すると、macOSが既定入出力の集約デバイスを組み直した直後に
    // AVAudioEngineConfigurationChangeが飛び、その時点では
    // inputNodeの公開フォーマット(client)と実ハードウェアのフォーマットのサンプルレートが
    // 食い違っていた。AVFoundationはこの状態で`installTap`されるとNSExceptionをraiseし、
    // Swift側では捕捉できずプロセスがabortしていた。

    func testMatchingFormatsUseTheNodeFormatAsIs() {
        let spec = AudioCaptureEngine.tapFormatSpec(
            clientSampleRate: 48000, clientChannelCount: 1,
            hardwareSampleRate: 48000, hardwareChannelCount: 1
        )
        XCTAssertEqual(spec?.sampleRate, 48000)
        XCTAssertEqual(spec?.channelCount, 1)
    }

    func testDisagreeingSampleRatesFallBackToTheHardwareFormat() {
        // 実際にクラッシュしたケース: client 44100Hz(既定出力のレート) / hardware 16000Hz(BluetoothのHFP入力)。
        // 44100Hzのまま`installTap`するとNSExceptionでabortするため、ハードウェア側を採る。
        let spec = AudioCaptureEngine.tapFormatSpec(
            clientSampleRate: 44100, clientChannelCount: 1,
            hardwareSampleRate: 16000, hardwareChannelCount: 1
        )
        XCTAssertEqual(spec?.sampleRate, 16000)
        XCTAssertEqual(spec?.channelCount, 1)
    }

    func testInvalidClientFormatFallsBackToTheHardwareFormat() {
        let spec = AudioCaptureEngine.tapFormatSpec(
            clientSampleRate: 0, clientChannelCount: 0,
            hardwareSampleRate: 48000, hardwareChannelCount: 2
        )
        XCTAssertEqual(spec?.sampleRate, 48000)
        XCTAssertEqual(spec?.channelCount, 2)
    }

    func testUnknownHardwareFormatKeepsTheNodeFormat() {
        // ハードウェア側のフォーマットが取得できない場合は公開フォーマットを信じる
        // (最終的な安全網は`installTap`を囲む`@try/@catch`が担う)。
        XCTAssertEqual(
            AudioCaptureEngine.tapFormatSpec(
                clientSampleRate: 48000, clientChannelCount: 1,
                hardwareSampleRate: 0, hardwareChannelCount: 0
            )?.sampleRate,
            48000
        )
        XCTAssertEqual(
            AudioCaptureEngine.tapFormatSpec(
                clientSampleRate: 48000, clientChannelCount: 1,
                hardwareSampleRate: .nan, hardwareChannelCount: 1
            )?.sampleRate,
            48000
        )
    }

    func testNoTappableFormatWhenBothSidesAreInvalid() {
        XCTAssertNil(AudioCaptureEngine.tapFormatSpec(
            clientSampleRate: 0, clientChannelCount: 0,
            hardwareSampleRate: 0, hardwareChannelCount: 0
        ))
        XCTAssertNil(AudioCaptureEngine.tapFormatSpec(
            clientSampleRate: 48000, clientChannelCount: 0,
            hardwareSampleRate: 48000, hardwareChannelCount: 0
        ))
        XCTAssertNil(AudioCaptureEngine.tapFormatSpec(
            clientSampleRate: .nan, clientChannelCount: 1,
            hardwareSampleRate: .infinity, hardwareChannelCount: 1
        ))
    }

    func testChosenFormatIsAlwaysConsistentWithTheHardwareSampleRateWhenKnown() {
        // 「タップのサンプルレート == 入力ハードウェアのサンプルレート」というAVFoundationの
        // 事前条件を、ハードウェアのレートが分かっている限り常に満たすこと。
        let hardwareRates: [Double] = [8000, 16000, 44100, 48000, 96000]
        let clientRates: [Double] = [0, 16000, 44100, 48000, 192000]
        for hardware in hardwareRates {
            for client in clientRates {
                let spec = AudioCaptureEngine.tapFormatSpec(
                    clientSampleRate: client, clientChannelCount: client > 0 ? 1 : 0,
                    hardwareSampleRate: hardware, hardwareChannelCount: 1
                )
                XCTAssertEqual(spec?.sampleRate, hardware, "client=\(client) hardware=\(hardware)")
            }
        }
    }

    // MARK: - タップ再設置リトライの待ち時間

    func testTapRetryDelayGrowsExponentiallyAndIsCapped() {
        XCTAssertEqual(AudioCaptureEngine.tapRetryDelay(forAttempt: 1), 0.3, accuracy: 0.0001)
        XCTAssertEqual(AudioCaptureEngine.tapRetryDelay(forAttempt: 2), 0.6, accuracy: 0.0001)
        XCTAssertEqual(AudioCaptureEngine.tapRetryDelay(forAttempt: 3), 1.2, accuracy: 0.0001)
        XCTAssertEqual(AudioCaptureEngine.tapRetryDelay(forAttempt: 4), 2.4, accuracy: 0.0001)
        XCTAssertEqual(AudioCaptureEngine.tapRetryDelay(forAttempt: 5), 4.8, accuracy: 0.0001)
        // 上限5秒
        XCTAssertEqual(AudioCaptureEngine.tapRetryDelay(forAttempt: 6), 5.0, accuracy: 0.0001)
        XCTAssertEqual(AudioCaptureEngine.tapRetryDelay(forAttempt: 100), 5.0, accuracy: 0.0001)
    }

    func testTapRetryDelayIsPositiveForNonPositiveAttempts() {
        XCTAssertEqual(AudioCaptureEngine.tapRetryDelay(forAttempt: 0), 0.3, accuracy: 0.0001)
        XCTAssertEqual(AudioCaptureEngine.tapRetryDelay(forAttempt: -5), 0.3, accuracy: 0.0001)
    }

    func testTapRetryIsBoundedAndTotalWaitIsReasonable() {
        XCTAssertGreaterThan(AudioCaptureEngine.tapRetryMaxAttempts, 1)
        let total = (1...AudioCaptureEngine.tapRetryMaxAttempts)
            .reduce(0.0) { $0 + AudioCaptureEngine.tapRetryDelay(forAttempt: $1) }
        // 数十秒以内には諦めてユーザーへ警告を出す(無限リトライで沈黙し続けないこと)。
        XCTAssertLessThan(total, 60)
        // 回数の上限に達する前に時間の上限が来てしまうと、回数の指定が意味を持たなくなる。
        XCTAssertLessThanOrEqual(total, AudioCaptureEngine.tapRecoveryGiveUpInterval)
    }
}
