import XCTest
@testable import Voicewriter

/// `FormattingPrompt`のネットワークI/Oを含まない部分(プロンプト組み立て・レスポンス解析・
/// 長さ比チェック)の単体テスト。実際のOllama通信は`OllamaFormatterIntegrationTests`で確認する。
final class FormattingPromptTests: XCTestCase {
    // MARK: - systemPrompt

    func testSystemPromptOmitsVocabularyHintSectionWhenEmpty() {
        let prompt = FormattingPrompt.systemPrompt(vocabularyHint: "")
        XCTAssertFalse(prompt.contains("語彙ヒント"))
    }

    func testSystemPromptIncludesVocabularyHintWhenProvided() {
        let prompt = FormattingPrompt.systemPrompt(vocabularyHint: "Voicewriter, ChatGPT")
        XCTAssertTrue(prompt.contains("語彙ヒント"))
        XCTAssertTrue(prompt.contains("Voicewriter, ChatGPT"))
    }

    func testSystemPromptStatesGuardrails() {
        let prompt = FormattingPrompt.systemPrompt(vocabularyHint: "")
        // 要約・言い換え・応答禁止という核となるガードレールが必ず文言として含まれていることを確認する
        // (プロンプトの意図しない書き換えに対する回帰検知)。
        XCTAssertTrue(prompt.contains("要約"))
        XCTAssertTrue(prompt.contains("言い換え"))
        XCTAssertTrue(prompt.contains("応答すること"))
    }

    // MARK: - userMessage

    func testUserMessageWrapsInputInAsrTextTag() {
        let message = FormattingPrompt.userMessage(for: "こんにちは")
        XCTAssertEqual(message, "<ASR_TEXT>こんにちは</ASR_TEXT>")
    }

    // MARK: - extractFormattedText (structured JSON output, primary path)

    func testExtractFormattedTextParsesStructuredJson() {
        let raw = #"{"text": "整形済みのテキスト"}"#
        XCTAssertEqual(FormattingPrompt.extractFormattedText(from: raw), "整形済みのテキスト")
    }

    func testExtractFormattedTextTrimsWhitespaceInJson() {
        let raw = #"{"text": "  前後に空白  "}"#
        XCTAssertEqual(FormattingPrompt.extractFormattedText(from: raw), "前後に空白")
    }

    func testExtractFormattedTextReturnsNilForEmptyJsonText() {
        let raw = #"{"text": ""}"#
        XCTAssertNil(FormattingPrompt.extractFormattedText(from: raw))
    }

    func testExtractFormattedTextReturnsNilForWhitespaceOnlyJsonText() {
        let raw = #"{"text": "   "}"#
        XCTAssertNil(FormattingPrompt.extractFormattedText(from: raw))
    }

    // MARK: - extractFormattedText (tag fallback, for when structured output isn't honored)

    func testExtractFormattedTextFallsBackToTagWhenNotJson() {
        let raw = "<formatted_text>タグ形式のテキスト</formatted_text>"
        XCTAssertEqual(FormattingPrompt.extractFormattedText(from: raw), "タグ形式のテキスト")
    }

    func testExtractFormattedTextTagFallbackHandlesSurroundingNoise() {
        let raw = "はい、整形しました:\n<formatted_text>本文</formatted_text>\nご確認ください。"
        XCTAssertEqual(FormattingPrompt.extractFormattedText(from: raw), "本文")
    }

    func testExtractFormattedTextReturnsNilWhenNoTagAndNotJson() {
        let raw = "これは整形結果ではなく単なる自由文です。"
        XCTAssertNil(FormattingPrompt.extractFormattedText(from: raw))
    }

    func testExtractFormattedTextReturnsNilForEmptyTag() {
        let raw = "<formatted_text></formatted_text>"
        XCTAssertNil(FormattingPrompt.extractFormattedText(from: raw))
    }

    // MARK: - isLengthRatioAcceptable

    func testLengthRatioAcceptableForSimilarLengths() {
        XCTAssertTrue(FormattingPrompt.isLengthRatioAcceptable(inputText: "こんにちは今日は良い天気ですね", outputText: "こんにちは、今日は良い天気ですね。"))
    }

    func testLengthRatioRejectsExtremeSummarization() {
        let input = "先週のミーティングで話した件なんですけど、あの、来月のリリースに向けて、えーと、まず設計のレビューを今週中に終わらせて、それから実装に入って、テストは再来週から始める、みたいなスケジュールで進めたいと思っています。"
        let overSummarized = "来月リリース予定。"
        XCTAssertFalse(FormattingPrompt.isLengthRatioAcceptable(inputText: input, outputText: overSummarized))
    }

    func testLengthRatioRejectsExtremeExpansion() {
        XCTAssertFalse(FormattingPrompt.isLengthRatioAcceptable(inputText: "はい", outputText: "はい、それはとても良い質問ですね。詳しく説明しますと、まず前提として..."))
    }
}
