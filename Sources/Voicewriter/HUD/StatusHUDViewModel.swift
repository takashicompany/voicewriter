import Combine
import Foundation

/// HUDパネルに表示する内容。値そのものはViewの見た目にのみ関わり、状態機械には影響しない。
enum StatusHUDDisplay: Equatable {
    case hidden
    /// 録音中。`level`は0.0〜1.0程度に正規化した音声レベル(レベルメーター表示用)。
    case recording(level: Float)
    case recognizing
    case formatting
    case success
    case fallbackWarning
    /// ハルシネーション対策(多層防御)により録音サイクルがスキップされた際の表示。
    /// `message`は「短すぎるためキャンセル」/「無音のためキャンセル」。
    case cancelled(message: String)
}

/// `StatusHUDContentView`が購読するビューモデル。`StatusHUDController`がCoordinator等の
/// コールバックを受けて更新する。
@MainActor
final class StatusHUDViewModel: ObservableObject {
    @Published var display: StatusHUDDisplay = .hidden
}
