import XCTest
@testable import Voicewriter

/// `WhisperCppEngine.filterSegments`(ハルシネーション対策 多層防御の第4層:
/// セグメント単位のno_speech_probフィルタ)の単体テスト。
/// `whisper_full_get_segment_no_speech_prob`(whisper.cpp v1.9.1で公開されているAPI)から
/// 得られる値を模したタプル列を渡し、閾値以上のセグメントが除外されることを確認する。
final class WhisperCppEngineSegmentFilterTests: XCTestCase {
    func testEmptySegmentsProduceEmptyText() {
        let result = WhisperCppEngine.filterSegments([])
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.excludedCount, 0)
    }

    func testAllLowNoSpeechProbSegmentsAreKept() {
        let segments: [(text: String, noSpeechProb: Float)] = [
            ("こんにちは、", 0.05),
            ("今日は良い天気ですね。", 0.1)
        ]
        let result = WhisperCppEngine.filterSegments(segments)
        XCTAssertEqual(result.text, "こんにちは、今日は良い天気ですね。")
        XCTAssertEqual(result.excludedCount, 0)
    }

    func testHighNoSpeechProbSegmentIsExcluded() {
        // 末尾無音区間がハルシネーションを生んだ典型ケースを模す:
        // 実際の発話セグメント(低no_speech_prob) + 末尾の無音由来ハルシネーション(高no_speech_prob)。
        let segments: [(text: String, noSpeechProb: Float)] = [
            ("こんにちは。", 0.05),
            ("ご視聴ありがとうございました。", 0.85)
        ]
        let result = WhisperCppEngine.filterSegments(segments)
        XCTAssertEqual(result.text, "こんにちは。")
        XCTAssertEqual(result.excludedCount, 1)
    }

    func testAllHighNoSpeechProbSegmentsProduceEmptyText() {
        let segments: [(text: String, noSpeechProb: Float)] = [
            ("ご視聴ありがとうございました。", 0.9),
            ("チャンネル登録お願いします。", 0.95)
        ]
        let result = WhisperCppEngine.filterSegments(segments)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.excludedCount, 2)
    }

    func testThresholdIsInclusive() {
        // 閾値ちょうどの値は「閾値以上」として除外される(境界値テスト)。
        let segments: [(text: String, noSpeechProb: Float)] = [("テスト", 0.6)]
        let result = WhisperCppEngine.filterSegments(segments, threshold: 0.6)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.excludedCount, 1)
    }

    func testValueJustBelowThresholdIsKept() {
        let segments: [(text: String, noSpeechProb: Float)] = [("テスト", 0.59)]
        let result = WhisperCppEngine.filterSegments(segments, threshold: 0.6)
        XCTAssertEqual(result.text, "テスト")
        XCTAssertEqual(result.excludedCount, 0)
    }

    func testCustomThresholdIsRespected() {
        let segments: [(text: String, noSpeechProb: Float)] = [("テスト", 0.5)]
        XCTAssertEqual(WhisperCppEngine.filterSegments(segments, threshold: 0.4).excludedCount, 1)
        XCTAssertEqual(WhisperCppEngine.filterSegments(segments, threshold: 0.6).excludedCount, 0)
    }
}
