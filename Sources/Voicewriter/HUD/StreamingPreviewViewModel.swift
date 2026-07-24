import Combine
import Foundation

/// ライブプレビューパネルに表示する内容。
enum StreamingPreviewDisplay: Equatable {
    case hidden
    /// - Parameters:
    ///   - finalizedText: 確定済みテキスト(表示用に末尾のみへ切り詰め済み)。
    ///   - volatileText: 未確定(volatile)テキスト。今後書き換わりうる。挿入先アプリへは流し込まない。
    case visible(finalizedText: String, volatileText: String)
    /// モデル資産が未インストールで、初回自動ダウンロード/インストール中。`progress`は0.0〜1.0(不明ならnil)。
    case preparing(progress: Double?)
}

@MainActor
final class StreamingPreviewViewModel: ObservableObject {
    @Published var display: StreamingPreviewDisplay = .hidden
}
