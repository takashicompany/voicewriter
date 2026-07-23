import XCTest
@testable import Voicewriter

/// `UserDictionaryReplacer`(ユーザー辞書の置換ロジック)の単体テスト。
/// ネットワーク/ファイルI/Oを含まない純粋関数のため、決定的に検証できる。
final class UserDictionaryReplacerTests: XCTestCase {
    func testEmptyDictionaryReturnsTextUnchanged() {
        XCTAssertEqual(UserDictionaryReplacer.apply([], to: "こんにちは"), "こんにちは")
    }

    func testEmptyTextReturnsEmptyRegardlessOfRules() {
        let rules = [UserDictionaryRule(from: "a", to: "b")]
        XCTAssertEqual(UserDictionaryReplacer.apply(rules, to: ""), "")
    }

    func testSingleRuleReplacesAllOccurrences() {
        let rules = [UserDictionaryRule(from: "ボイスライダー", to: "Voicewriter")]
        let result = UserDictionaryReplacer.apply(rules, to: "ボイスライダーからボイスライダーへ")
        XCTAssertEqual(result, "VoicewriterからVoicewriterへ")
    }

    func testMultipleRulesAreAppliedInOrder() {
        // 「A→B」の後に「B→C」を適用すると、元がAだった箇所も最終的にCになる(チェーン適用)。
        let rules = [
            UserDictionaryRule(from: "A", to: "B"),
            UserDictionaryRule(from: "B", to: "C"),
        ]
        XCTAssertEqual(UserDictionaryReplacer.apply(rules, to: "A"), "C")
    }

    func testPartialMatchChainAcrossMultipleRules() {
        // 「ボイスライダー→ボイスライター」→「ボイスライター→Voicewriter」の連鎖。
        let rules = [
            UserDictionaryRule(from: "ボイスライダー", to: "ボイスライター"),
            UserDictionaryRule(from: "ボイスライター", to: "Voicewriter"),
        ]
        XCTAssertEqual(UserDictionaryReplacer.apply(rules, to: "ボイスライダーを起動"), "Voicewriterを起動")
    }

    func testDisabledRuleIsSkipped() {
        let rules = [
            UserDictionaryRule(from: "A", to: "B", isEnabled: false),
        ]
        XCTAssertEqual(UserDictionaryReplacer.apply(rules, to: "A"), "A")
    }

    func testMixOfEnabledAndDisabledRules() {
        let rules = [
            UserDictionaryRule(from: "A", to: "1", isEnabled: false),
            UserDictionaryRule(from: "B", to: "2", isEnabled: true),
        ]
        XCTAssertEqual(UserDictionaryReplacer.apply(rules, to: "AB"), "A2")
    }

    func testEmptyFromRuleIsIgnored() {
        let rules = [UserDictionaryRule(from: "", to: "X")]
        XCTAssertEqual(UserDictionaryReplacer.apply(rules, to: "テスト"), "テスト")
    }

    func testReplacementToEmptyStringRemovesOccurrences() {
        let rules = [UserDictionaryRule(from: "えーと", to: "")]
        XCTAssertEqual(UserDictionaryReplacer.apply(rules, to: "えーと今日はえーと晴れです"), "今日は晴れです")
    }

    func testJapaneseTextWithMultipleRules() {
        let rules = [
            UserDictionaryRule(from: "きゃやっく", to: "KAYAC"),
            UserDictionaryRule(from: "おらま", to: "Ollama"),
        ]
        let result = UserDictionaryReplacer.apply(rules, to: "きゃやっくで働いていて、おらまを使っています。")
        XCTAssertEqual(result, "KAYACで働いていて、Ollamaを使っています。")
    }

    func testCaseSensitiveReplacement() {
        let rules = [UserDictionaryRule(from: "voicewriter", to: "Voicewriter")]
        XCTAssertEqual(UserDictionaryReplacer.apply(rules, to: "Voicewriter voicewriter"), "Voicewriter Voicewriter")
    }
}
