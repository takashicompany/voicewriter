import Foundation
import os.log

/// Ollama(ローカル、`/api/chat`)を使ったLLM整形実装。
///
/// - `think: false`をリクエスト**直下**(`options`の外)に指定してThinkingを無効化する。
///   一次情報: https://docs.ollama.com/capabilities/thinking , https://docs.ollama.com/api/chat
///   (qwen3系はthink:false時にチャットテンプレートが自動的に`/no_think`相当を付与する実装になっている)
/// - `format`にJSON Schema(`FormattingPrompt.responseSchema`、`{"text": string}`のみを許可)を渡し、
///   構造化出力(一次情報: https://docs.ollama.com/capabilities/structured-outputs )で
///   `{"text": "..."}`以外の出力(前置き・説明文・タグの閉じ忘れ等)を文法制約レベルで防ぐ。
/// - `keep_alive: -1`でモデルをメモリに常駐させ続け、リクエストのたびにモデルがアンロード
///   されて再ロードが走る(数秒〜のコールドスタート)ことを避ける。アプリ起動時にも`preload()`で
///   空リクエストを送り、初回の実際の整形リクエストを待たせないようにする(一次情報:
///   https://docs.ollama.com/faq#how-can-i-preload-a-model-into-ollama-to-get-faster-response-times )。
/// - `options`は`temperature: 0, top_k: 20, top_p: 0.8, repeat_penalty: 1.0, seed: 42`で
///   決定的かつ逸脱の少ない出力を狙う。`num_ctx: 4096`はディクテーション用途の入力長に対して
///   十分な余裕を持たせつつ、既定(モデルによって異なる)より明示的に固定するため。
///   `num_predict: 512`は暴走出力(果てしない繰り返し等)による長時間占有を防ぐ上限。
///
/// プロンプトは`FormattingPrompt`(Amical/Handyの「フォーマッタであり書き換え者ではない」という
/// 方針を踏襲した独自文面)を使う。レスポンスは主に構造化出力のJSONとしてパースし、
/// `done_reason == "length"`(出力が`num_predict`で打ち切られた)や、入力に対して常識外れに
/// 長さが変わった場合(`FormattingPrompt.isLengthRatioAcceptable`)は暴走とみなして拒否する。
///
/// これらの検証に失敗した場合・タイムアウト・Ollama未起動などは全て`TextFormatterError`を
/// throwするのみで、**この実装自体は原文へのフォールバックを行わない**
/// (フォールバック判断は`Coordinator`に集約する)。
final class OllamaFormatter: TextFormatter, @unchecked Sendable {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "OllamaFormatter")
    private let baseURL: URL
    private let session: URLSession

    static let defaultBaseURL = URL(string: "http://localhost:11434")!

    init(baseURL: URL = OllamaFormatter.defaultBaseURL) {
        self.baseURL = baseURL
        // 常駐アプリ内で使い回す想定のため、Cookie/キャッシュ等は不要(ephemeral)。
        self.session = URLSession(configuration: .ephemeral)
    }

    func format(text: String, vocabularyHint: String, model: String, timeoutSeconds: TimeInterval) async throws -> String {
        let trimmedInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            throw TextFormatterError.emptyInput
        }

        // タイムアウト・モデル名はいずれも呼び出し元(ジョブの録音時点の設定スナップショット)から
        // 渡されたものをそのまま使う(待ち行列中の設定変更の影響を受けないようにするため。
        // Codexレビュー指摘#8: 以前はタイムアウトのみ`Settings`から直接読んでいた)。

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": FormattingPrompt.systemPrompt(vocabularyHint: vocabularyHint)],
                ["role": "user", "content": FormattingPrompt.userMessage(for: trimmedInput)],
            ],
            "stream": false,
            "think": false,
            "keep_alive": -1,
            "format": FormattingPrompt.responseSchema,
            "options": [
                "temperature": 0,
                "top_k": 20,
                "top_p": 0.8,
                "repeat_penalty": 1.0,
                "seed": 42,
                "num_ctx": 4096,
                "num_predict": 512,
            ],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw TextFormatterError.invalidResponse("failed to encode request body")
        }

        var mutableRequest = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        mutableRequest.httpMethod = "POST"
        mutableRequest.httpBody = bodyData
        mutableRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        mutableRequest.timeoutInterval = timeoutSeconds
        let request = mutableRequest

        let data: Data
        do {
            // URLRequest.timeoutIntervalに加え、外側でもタイムアウトを競わせる二重防御。
            // ストリーミング無効時は通常URLRequest側のタイムアウトで十分だが、Ollama側のハング
            // (モデルロード待ち等)に備えて上限を確実にする。
            data = try await Self.withTimeout(seconds: timeoutSeconds) { [session, request] in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode
                    throw TextFormatterError.serverUnavailable("unexpected HTTP status \(status.map(String.init) ?? "?")")
                }
                return data
            }
        } catch let error as TextFormatterError {
            log.warning("Formatting request failed: \(error.description, privacy: .public)")
            throw error
        } catch {
            log.warning("Ollama request failed (server unreachable?): \(error.localizedDescription, privacy: .public)")
            throw TextFormatterError.serverUnavailable(error.localizedDescription)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw TextFormatterError.invalidResponse("unexpected JSON shape from /api/chat")
        }

        // num_predictで出力が打ち切られた場合、整形結果が文の途中で終わっている可能性が高いため
        // 暴走とみなして拒否する(原文へのフォールバックはCoordinator側で行われる)。
        if let doneReason = json["done_reason"] as? String, doneReason == "length" {
            log.warning("Formatter response truncated (done_reason=length, model=\(model, privacy: .public))")
            throw TextFormatterError.invalidResponse("response truncated (done_reason=length)")
        }

        guard let extracted = FormattingPrompt.extractFormattedText(from: content) else {
            log.warning("Formatter response missing/empty structured text (model=\(model, privacy: .public))")
            throw TextFormatterError.missingOrEmptyTag
        }

        // 暴走・過剰な要約/言い換えの簡易検知: 入力に対して常識外れに長さが変わっていないか。
        guard FormattingPrompt.isLengthRatioAcceptable(inputText: trimmedInput, outputText: extracted) else {
            log.warning("Formatter output length ratio out of range (model=\(model, privacy: .public), inputLen=\(trimmedInput.count), outputLen=\(extracted.count))")
            throw TextFormatterError.invalidResponse("output length ratio out of acceptable range")
        }

        return extracted
    }

    /// アプリ起動時に空のchatリクエストを送り、モデルをOllamaのメモリに先読みさせる
    /// (`keep_alive: -1`と併用することで、以後アンロードされず常駐し続ける)。
    /// 失敗しても致命的ではない(初回の実際の整形リクエスト時に通常のロードが走るだけ)ため、
    /// エラーはログに残すのみで呼び出し元には伝播させない。
    func preload() async {
        let model = Settings.formattingModel
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [],
            "stream": false,
            "keep_alive": -1,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else { return }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 大型モデルの初回ロードはディスクI/O次第で数十秒かかりうるため、通常の整形タイムアウトとは
        // 別に余裕を持たせる。
        request.timeoutInterval = 60

        do {
            _ = try await session.data(for: request)
            log.info("Preloaded formatting model into Ollama: \(model, privacy: .public)")
        } catch {
            log.warning("Failed to preload formatting model \(model, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `operation`が`seconds`以内に完了しなければ`TextFormatterError.timeout`をthrowする。
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                throw TextFormatterError.timeout
            }
            guard let result = try await group.next() else {
                throw TextFormatterError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}
