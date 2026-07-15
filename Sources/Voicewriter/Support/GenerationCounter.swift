import Foundation

/// アクター境界をまたいで安全に読み書きできる、単調増加する世代カウンタ。
///
/// `Task.detached`や`URLSessionDelegate`など、MainActor外から非同期に完了する処理が
/// 「自分が始まった後により新しい世代が既に始まっているか」を判定するために使う。
/// 判定に使うため、完了順序が入れ替わっても常に最新の世代の結果だけが状態に反映され、
/// 古い(追い越された)結果による状態の巻き戻りを防げる
/// (`ModelDownloader`のダウンロードタスク世代、`DynamicTranscriptionEngine.reload()`の
/// リロード世代で使用)。
final class GenerationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// 新しい世代を開始し、そのIDを返す。
    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    /// 渡した世代IDが、現在の(最新の)世代と一致するか。
    func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }
}
