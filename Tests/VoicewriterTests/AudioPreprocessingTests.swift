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

    // MARK: - hasSufficientEnergy (ハルシネーション対策 第2層: エネルギーゲート)

    func testEmptySamplesHaveNoSufficientEnergy() {
        XCTAssertFalse(AudioPreprocessing.hasSufficientEnergy(samples: []))
    }

    func testPureSilenceHasNoSufficientEnergy() {
        let samples = silence(seconds: 1.0)
        XCTAssertFalse(AudioPreprocessing.hasSufficientEnergy(samples: samples))
    }

    func testLoudToneHasSufficientEnergy() {
        let samples = tone(seconds: 0.5, amplitude: 0.3)
        XCTAssertTrue(AudioPreprocessing.hasSufficientEnergy(samples: samples))
    }

    func testLowLevelNoiseBelowThresholdHasNoSufficientEnergy() {
        // マイクの環境ノイズ程度(振幅0.001、全体RMS/フレーム最大RMSいずれも既定閾値未満)は
        // 「確実な無音」として扱われるはず。
        let samples = tone(seconds: 1.0, amplitude: 0.001)
        XCTAssertFalse(AudioPreprocessing.hasSufficientEnergy(samples: samples))
    }

    func testNoiseJustAboveGlobalThresholdHasSufficientEnergy() {
        // 全体RMSが既定閾値(0.003)をわずかに超える程度の低レベル音でも、
        // 「確実な無音」とは言い切れないため発話ありとみなすべき(false negativeを避ける設計)。
        let samples = tone(seconds: 1.0, amplitude: 0.005)
        XCTAssertTrue(AudioPreprocessing.hasSufficientEnergy(samples: samples))
    }

    func testBriefLoudPeakAloneCountsAsSufficientEnergy() {
        // 短い子音の頭のような、瞬間的に大きい振幅のみを含むケース。単発の振幅0.5は
        // 20msフレーム(320サンプル@16kHz)のRMSを閾値(0.006)より十分押し上げるため、
        // 全体RMSでは埋もれても「確実な無音」とは判定されない(=発話ありとみなす)はず。
        var samples = silence(seconds: 1.0)
        samples[100] = 0.5
        XCTAssertTrue(AudioPreprocessing.hasSufficientEnergy(samples: samples))
    }

    func testSingleSampleClickNoiseAloneIsStillTreatedAsHavingEnergy() {
        // クリック/ポップノイズを想定した単発スパイク(1サンプルのみ)でも、フレーム単位RMSでの
        // 判定により「確実な無音」の判定からは除外される(=瞬間ピークだけで判定していないことの確認。
        // クリックノイズはピーク単独判定だと誤検出しやすいことへの対応として、フレームRMSを採用した)。
        var samples = silence(seconds: 2.0)
        samples[500] = 0.9
        XCTAssertTrue(AudioPreprocessing.hasSufficientEnergy(samples: samples))
    }

    func testShortQuietSpeechBurstAmidLongMostlySilentBufferHasSufficientEnergy() {
        // 30秒の録音のうち0.05秒だけ小声の発話(振幅0.03)があるケース。
        // 全体(30秒分)のRMSで平均すると既定閾値未満に薄まってしまう(=globalRmsThresholdだけの
        // 判定だと無音と誤判定してしまう)が、フレーム単位(20ms)の最大RMSで見れば
        // その短い発話区間だけは明確に閾値を超えるはず。これが両条件のANDを取っている理由の
        // 具体例になっている。
        let samples = silence(seconds: 14.95) + tone(seconds: 0.05, amplitude: 0.03) + silence(seconds: 15.0)
        XCTAssertTrue(AudioPreprocessing.hasSufficientEnergy(samples: samples))
    }
}
