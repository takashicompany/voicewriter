import XCTest
@testable import Voicewriter

/// `OllamaFormatter`が実際にローカルOllamaへHTTPリクエストを送り、整形結果を受け取れることを
/// 確認する統合テスト。CIやOllama未起動環境では`XCTSkip`で自動的にスキップする(単体テストの
/// 実行自体をOllamaの起動有無に依存させないため)。
///
/// 実行するには、あらかじめ以下を満たしていること:
/// - `http://localhost:11434` でOllamaが起動している
/// - `Settings.formattingModel`(既定`qwen3:14b`)のモデルが`ollama pull`済みであること
final class OllamaFormatterIntegrationTests: XCTestCase {
    /// Ollamaが到達可能かどうかを確認する。到達できない場合はテストをスキップする。
    private func skipIfOllamaUnreachable() async throws {
        var request = URLRequest(url: OllamaFormatter.defaultBaseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw XCTSkip("Ollama is not reachable at \(OllamaFormatter.defaultBaseURL) (unexpected response); skipping integration test")
            }
        } catch {
            throw XCTSkip("Ollama is not reachable at \(OllamaFormatter.defaultBaseURL): \(error.localizedDescription); skipping integration test")
        }
    }

    func testFormatReturnsNonEmptyResultFromRealOllama() async throws {
        try await skipIfOllamaUnreachable()

        let formatter = OllamaFormatter()
        let rawText = "えーっとですね、あの、今日の会議は14時からだと思います。"

        do {
            let formatted = try await formatter.format(text: rawText, vocabularyHint: "Voicewriter")
            XCTAssertFalse(formatted.isEmpty)
            // 「整形専用フォーマッタ」の核となる制約: 応答であってはならず、原文とかけ離れた
            // 長さになってもいけない(FormattingPrompt.isLengthRatioAcceptableと同じ簡易基準)。
            XCTAssertTrue(FormattingPrompt.isLengthRatioAcceptable(inputText: rawText, outputText: formatted))
        } catch {
            XCTFail("Expected formatting to succeed against a reachable Ollama instance, but got: \(error)")
        }
    }

    /// ガードレール確認: 入力が質問文であっても、フォーマッタがそれに応答してはならない
    /// (整形結果として同じ質問がそのまま、または句読点補完程度の変化で返るべき)。
    func testFormatDoesNotAnswerQuestionsInInput() async throws {
        try await skipIfOllamaUnreachable()

        let formatter = OllamaFormatter()
        let rawText = "今何時ですか"
        let formatted = try await formatter.format(text: rawText, vocabularyHint: "")

        XCTAssertFalse(formatted.isEmpty)
        // 応答(例: 具体的な時刻を答える等)であれば、入力にない情報が大量に追加され長さ比が
        // 大きく外れるはずなので、簡易的な長さチェックで検知する。
        XCTAssertTrue(FormattingPrompt.isLengthRatioAcceptable(inputText: rawText, outputText: formatted))
    }

    func testEmptyInputThrowsWithoutHittingNetwork() async throws {
        let formatter = OllamaFormatter()
        do {
            _ = try await formatter.format(text: "   ", vocabularyHint: "")
            XCTFail("Expected emptyInput error")
        } catch TextFormatterError.emptyInput {
            // expected
        } catch {
            XCTFail("Expected TextFormatterError.emptyInput, got \(error)")
        }
    }
}
