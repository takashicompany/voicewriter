import Combine
import Foundation

/// HUDパネルに表示する内容。値そのものはViewの見た目にのみ関わり、状態機械には影響しない。
///
/// 連続音声入力パイプライン導入に伴い、録音中・認識中・整形中の各表示に「他に処理待ち/処理中の
/// ジョブが何件あるか」(`pendingCount`)を付加できるようにした。これは個々のジョブイベントを
/// 直接表示するのではなく、`StatusHUDController`が集約したスナップショット(録音状態+残件数)から
/// 導出した値である。
enum StatusHUDDisplay: Equatable {
    case hidden
    /// 録音中。`level`は0.0〜1.0程度に正規化した音声レベル(レベルメーター表示用)。
    /// `pendingCount`は録音中のジョブ以外に処理待ち/処理中のジョブがある場合の件数。
    case recording(level: Float, pendingCount: Int)
    case recognizing(pendingCount: Int)
    case formatting(pendingCount: Int)
    case success
    case fallbackWarning
    /// ハルシネーション対策(多層防御)により録音サイクルがスキップされた、またはEscでキャンセルされた際の表示。
    case cancelled(message: String)
    /// キュー上限に達し新規録音を拒否した際の表示(通常のビープと区別できるようにするため)。
    case queueFull
    /// whisperモデルの初回自動セットアップ(ダウンロード)中。`message`は進捗込みの文言
    /// (例: 「初回セットアップ中: モデルをダウンロードしています… 42%」)。この間は
    /// 自動的に隠れず、セットアップが終わる(成功/失敗/キャンセル)まで表示し続ける。
    case settingUp(message: String)
    /// セットアップ(モデルの自動ダウンロード)が失敗した際の案内表示(ディスク容量不足・
    /// ネットワーク失敗等)。詳細な案内・再試行はメニューバー/設定画面側で行うため、
    /// ここでは短い理由のみを表示し、他の表示同様に一定時間で自動的に隠れる。
    case setupFailed(message: String)
    /// セットアップ中にF13(PTT)等で録音が要求されたが、まだセットアップ中のため拒否したことの通知。
    case setupInProgressRejected
}

/// `StatusHUDContentView`が購読するビューモデル。`StatusHUDController`がCoordinator等の
/// コールバックを受けて更新する。
@MainActor
final class StatusHUDViewModel: ObservableObject {
    @Published var display: StatusHUDDisplay = .hidden
}
