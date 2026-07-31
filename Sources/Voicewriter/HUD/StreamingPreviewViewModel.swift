import Combine
import Foundation

/// ライブプレビューパネルに表示する内容。
enum StreamingPreviewDisplay: Equatable {
    case hidden
    /// - Parameters:
    ///   - finalizedText: 確定済みテキスト(表示用に末尾のみへ切り詰め済み)。
    ///   - volatileText: 未確定(volatile)テキスト。今後書き換わりうる。挿入先アプリへは流し込まない。
    ///   - isProcessing: 録音は終了済みで、認識確定〜LLM整形〜挿入までの後処理中。この間も
    ///     直前の認識テキストを表示したまま「変換中…」インジケーターを重ねる(仕様: キーを離した
    ///     瞬間にプレビューを消さず、挿入が終わる(または失敗/キャンセル/スキップで終端する)まで
    ///     表示を残す)。
    case visible(finalizedText: String, volatileText: String, isProcessing: Bool)
    /// モデル資産が未インストールで、初回自動ダウンロード/インストール中。`progress`は0.0〜1.0(不明ならnil)。
    case preparing(progress: Double?)
}

@MainActor
final class StreamingPreviewViewModel: ObservableObject {
    @Published var display: StreamingPreviewDisplay = .hidden
}
