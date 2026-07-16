import XCTest
@testable import Voicewriter

/// `HallucinationFilter`(ハルシネーション対策 多層防御の第5層・最終防衛線)の単体テスト。
/// 出力全体が既知の無音ハルシネーション定型句のみで構成される場合にのみtrueを返すべきで、
/// 発話の一部として本当にその語句を言った場合(混在ケース)を誤って棄却してはならない。
final class HallucinationFilterTests: XCTestCase {
    func testEmptyStringIsNotHallucination() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination(""))
    }

    func testWhitespaceOnlyIsNotHallucination() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("   \n\t"))
    }

    func testKnownPhraseExactMatchIsHallucination() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("ご視聴ありがとうございました"))
    }

    func testKnownPhraseWithTrailingPunctuationIsHallucination() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("ご視聴ありがとうございました。"))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("ご視聴ありがとうございました!"))
    }

    func testKnownPhraseWithSurroundingWhitespaceIsHallucination() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("  ご視聴ありがとうございました  \n"))
    }

    func testOtherKnownPhrasesAreHallucination() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("ご清聴ありがとうございました"))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("ご静聴ありがとうございます"))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("チャンネル登録"))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("チャンネル登録よろしくお願いします。"))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("最後までご視聴いただきありがとうございました。"))
    }

    /// 汎用的な挨拶句(動画固有性が低く、単独でも正当なディクテーションとして成立しうるもの)は
    /// 語句リストから意図的に除外している。ユーザーがチャットへの短い返信として
    /// 「ありがとうございます」とだけ音声入力するのは普通の使い方であり、その場合VADも発話を
    /// 検出しwhisperも正しく認識しているにもかかわらず、この最終フィルタが全文一致で
    /// 消してしまうことは避けなければならない。
    func testGenericStandaloneGreetingsAreNotHallucination() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("ありがとうございます"))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("ありがとうございます。"))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("ありがとうございました"))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("ありがとうございました。"))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("おやすみなさい"))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("おやすみなさい。"))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("またね"))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("バイバイ"))
    }

    /// 混在ケース: 定型句が実発話の一部として含まれるだけの場合は棄却してはならない。
    func testPhraseEmbeddedInRealSpeechIsNotHallucination() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("今日の会議は以上です。ご視聴ありがとうございました。"))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("ご視聴ありがとうございました、というのが動画の締めの定番です。"))
    }

    func testUnrelatedRealSpeechIsNotHallucination() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("こんにちは、今日は良い天気ですね。音声入力のテストをしています。"))
    }

    func testPartialSubstringMatchAloneIsNotEnoughToTriggerHallucination() {
        // 「ご視聴」だけ、のように定型句の一部分のみでは判定しない(完全一致のみを対象とする設計)。
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("ご視聴"))
    }
}
