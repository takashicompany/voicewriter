import XCTest
@testable import Voicewriter

/// `AudioPreprocessing.trimLeadingSilence`(先頭無音/低エネルギーノイズのトリム)の単体テスト。
/// プリロールに混じる発話前ノイズがハルシネーションを誘発する問題への対策として追加した処理。
final class AudioPreprocessingTests: XCTestCase {
    private let sampleRate: Double = 16000

    private func silence(seconds: Double) -> [Float] {
        Array(repeating: Float(0), count: Int(seconds * sampleRate))
    }

    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        Array(repeating: amplitude, count: Int(seconds * sampleRate))
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(AudioPreprocessing.trimLeadingSilence(samples: [], sampleRate: sampleRate), [])
    }

    func testAllSilenceIsNotTrimmed() {
        let samples = silence(seconds: 1.0)
        let result = AudioPreprocessing.trimLeadingSilence(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(result.count, samples.count, "全区間が無音の場合はトリムしない")
    }

    func testLeadingSilenceIsTrimmedWithMargin() {
        // 0.5秒の無音(プリロール相当) + 1秒の音声(振幅0.3、閾値を十分上回る)
        let samples = silence(seconds: 0.5) + tone(seconds: 1.0, amplitude: 0.3)
        let result = AudioPreprocessing.trimLeadingSilence(samples: samples, sampleRate: sampleRate)

        XCTAssertLessThan(result.count, samples.count, "先頭の無音区間はトリムされるはず")
        // マージン(既定0.15秒)分は発話開始より手前を残すため、全体としては
        // 「無音0.5秒 - マージン」程度がトリムされ、音声本体は欠落しないはず。
        XCTAssertGreaterThanOrEqual(result.count, samples.count - Int(0.5 * sampleRate))
        // 音声本体(振幅0.3の区間)がまるごと残っていること。
        let nonZeroCount = result.filter { $0 != 0 }.count
        XCTAssertEqual(nonZeroCount, Int(1.0 * sampleRate))
    }

    func testLowLevelPrerollNoiseIsTrimmed() {
        // プリロールに混入する程度の低振幅ノイズ(振幅0.005、閾値0.015未満)+ 本編音声
        let noise = tone(seconds: 0.5, amplitude: 0.005)
        let speech = tone(seconds: 1.0, amplitude: 0.3)
        let samples = noise + speech
        let result = AudioPreprocessing.trimLeadingSilence(samples: samples, sampleRate: sampleRate)

        XCTAssertLessThan(result.count, samples.count, "閾値未満の低レベルノイズはトリムされるはず")
    }

    func testDoesNotTrimMoreThanMaxTrimSeconds() {
        // 2秒の無音(既定の上限1秒を超える)+ 音声
        let samples = silence(seconds: 2.0) + tone(seconds: 0.5, amplitude: 0.3)
        let result = AudioPreprocessing.trimLeadingSilence(samples: samples, sampleRate: sampleRate)

        let trimmed = samples.count - result.count
        XCTAssertLessThanOrEqual(trimmed, Int(1.0 * sampleRate), "上限(既定1秒)を超えてトリムしない")
    }

    func testSpeechStartingImmediatelyIsNotTrimmedAway() {
        // 先頭からいきなり発話が始まる(無音区間なし)場合はほぼトリムされない。
        let samples = tone(seconds: 1.0, amplitude: 0.3)
        let result = AudioPreprocessing.trimLeadingSilence(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(result.count, samples.count)
    }
}
