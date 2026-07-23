import Foundation
import os.log

/// 起動時にOllama(既定`http://localhost:11434`)へ到達できるかどうかを、軽量な1回限りの
/// チェックで判定する。
///
/// **設計方針**: これは起動直後のメニューバー状態表示(「LLM整形: 無効(Ollama未検出)」)を
/// 即座に(=最初の発話で整形が実際に失敗するのを待たずに)出すためだけに使う。継続的な
/// ポーリング(定期的な再チェック)は行わない。後からOllamaが起動された場合の「自動的に
/// 有効へ戻す」判定は、`Coordinator.runJob`が実際の整形リクエストのたびに行っている
/// 到達確認(成功/失敗)で既に十分なため、ここに二重の仕組みは持ち込まない。
enum OllamaReachability {
    private static let log = Logger(subsystem: "dev.voicewriter.app", category: "OllamaReachability")

    /// `baseURL`へ短いタイムアウトでGETし、応答(ステータスコードによらずHTTPレスポンス自体)が
    /// 得られればtrue、接続不可(未起動等)ならfalseを返す。
    static func check(baseURL: URL = OllamaFormatter.defaultBaseURL, timeoutSeconds: TimeInterval = 1.5) async -> Bool {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            log.info("Ollama not reachable at launch: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
