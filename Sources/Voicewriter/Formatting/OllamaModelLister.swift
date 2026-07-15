import Foundation
import os.log

/// 設定画面の整形タブで、Ollamaに実際に配置されているモデル一覧を`/api/tags`から動的に取得する。
@MainActor
final class OllamaModelLister: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case success([String])
        case failure(String)
    }

    @Published private(set) var state: State = .idle

    private let log = Logger(subsystem: "dev.voicewriter.app", category: "OllamaModelLister")
    private let baseURL: URL
    /// 連続で`refresh()`が呼ばれた場合、古いリクエストの遅延応答が新しい呼び出しの結果を
    /// 上書きしないようにするための世代カウンタ(ModelDownloader/DynamicTranscriptionEngineと同じ方針)。
    private let generation = GenerationCounter()

    init(baseURL: URL = OllamaFormatter.defaultBaseURL) {
        self.baseURL = baseURL
    }

    func refresh() {
        let requestedGeneration = generation.next()
        state = .loading
        Task {
            do {
                let models = try await Self.fetchModelNames(baseURL: baseURL)
                guard self.generation.isCurrent(requestedGeneration) else { return }
                self.state = .success(models)
            } catch {
                guard self.generation.isCurrent(requestedGeneration) else { return }
                self.log.warning("Failed to fetch Ollama model list: \(error.localizedDescription, privacy: .public)")
                self.state = .failure(
                    "Ollamaからモデル一覧を取得できませんでした。Ollamaが起動しているか確認してください。(\(error.localizedDescription))"
                )
            }
        }
    }

    private static func fetchModelNames(baseURL: URL) async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]]
        else {
            throw URLError(.cannotParseResponse)
        }
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}
