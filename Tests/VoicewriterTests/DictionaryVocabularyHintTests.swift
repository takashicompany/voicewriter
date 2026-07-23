import XCTest
@testable import Voicewriter

/// `DictionaryVocabularyHint.merge`(ユーザー辞書の置換先語彙をwhisper/LLM整形の語彙ヒントへ
/// 自動追加するロジック)の単体テスト。
final class DictionaryVocabularyHintTests: XCTestCase {
    func testEmptyBaseAndEmptyRulesReturnsEmpty() {
        XCTAssertEqual(DictionaryVocabularyHint.merge(baseHint: "", rules: []), "")
    }

    func testNoRulesReturnsBaseHintUnchanged() {
        XCTAssertEqual(DictionaryVocabularyHint.merge(baseHint: "Voicewriter", rules: []), "Voicewriter")
    }

    func testAddsDictionaryTermsToNonEmptyBaseHint() {
        let rules = [UserDictionaryRule(from: "ぎっと", to: "Git")]
        XCTAssertEqual(DictionaryVocabularyHint.merge(baseHint: "Voicewriter", rules: rules), "Voicewriter, Git")
    }

    func testAddsDictionaryTermsWhenBaseHintIsEmpty() {
        let rules = [UserDictionaryRule(from: "ぎっと", to: "Git")]
        XCTAssertEqual(DictionaryVocabularyHint.merge(baseHint: "", rules: rules), "Git")
    }

    func testDisabledRuleIsNotAdded() {
        let rules = [UserDictionaryRule(from: "ぎっと", to: "Git", isEnabled: false)]
        XCTAssertEqual(DictionaryVocabularyHint.merge(baseHint: "Voicewriter", rules: rules), "Voicewriter")
    }

    func testEmptyToIsNotAdded() {
        let rules = [UserDictionaryRule(from: "えーと", to: "")]
        XCTAssertEqual(DictionaryVocabularyHint.merge(baseHint: "Voicewriter", rules: rules), "Voicewriter")
    }

    func testDuplicateTermsAcrossRulesAreDedupedToOneOccurrence() {
        let rules = [
            UserDictionaryRule(from: "A", to: "Git"),
            UserDictionaryRule(from: "B", to: "Git"),
        ]
        XCTAssertEqual(DictionaryVocabularyHint.merge(baseHint: "", rules: rules), "Git")
    }

    func testTermAlreadyPresentInBaseHintIsNotDuplicated() {
        let rules = [UserDictionaryRule(from: "ぎっと", to: "Git")]
        XCTAssertEqual(DictionaryVocabularyHint.merge(baseHint: "Git, Voicewriter", rules: rules), "Git, Voicewriter")
    }

    func testDictionaryTermsAreCappedAtMaximum() {
        let rules = (0..<30).map { UserDictionaryRule(from: "from\($0)", to: "term\($0)") }
        let merged = DictionaryVocabularyHint.merge(baseHint: "", rules: rules)
        let terms = merged.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(terms.count, DictionaryVocabularyHint.maxDictionaryWords)
        XCTAssertEqual(terms.first, "term0")
        XCTAssertEqual(terms.last, "term\(DictionaryVocabularyHint.maxDictionaryWords - 1)")
    }

    func testWhitespaceIsTrimmedFromTerms() {
        let rules = [UserDictionaryRule(from: "a", to: "  Git  ")]
        XCTAssertEqual(DictionaryVocabularyHint.merge(baseHint: "", rules: rules), "Git")
    }
}
