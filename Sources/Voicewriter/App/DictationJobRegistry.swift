import Foundation
import os.log

/// ジョブごとの状態(未終端/終端)とキャンセルフラグを一元管理する。
///
/// 重要な設計判断: 「処理(認識・整形)が完了した」ことと「終端状態が確定した」ことは同義ではない。
/// 挿入は`DeliveryCoordinator`がsequence順にコミットするまで保留されうるため、処理自体は完了して
/// いても実際に挿入(またはtombstone化)されるまでは`markTerminal`を呼ばず、ジョブは
/// 「未終端(active)」のまま扱う。これにより:
/// - キュー上限判定(`canAcceptNewJob`)が「まだ発話順の順番待ちをしているジョブ」も正しく数える
/// - Escの階層的キャンセル(非録音時: 「まだ挿入されていない最新のジョブ」)が、処理完了後
///   コミット待ちのジョブも対象にできる
/// が両立する。終端状態を確定できるのは`DeliveryCoordinator`のコミット処理のみとする。
@MainActor
final class DictationJobRegistry {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "DictationJobRegistry")

    private struct Entry {
        var isCancelled: Bool = false
        /// `DeliveryCoordinator.commit(sequence:entry:)`が実際にコミット処理を開始した時点で
        /// trueになる。一度trueになったジョブへの`requestCancel`は無視する(Codexレビュー指摘#10:
        /// コミット開始後にEscが競合しても「キャンセル受理」と誤認させない。挿入自体は既に
        /// 決定済みの経路を進むため、フラグを立てても実際の結果には影響しないが、ログ上
        /// 「キャンセルできた」と誤解を招くのを防ぐ)。
        var isCommitting: Bool = false
        var terminalState: DictationJobTerminalState?
    }

    private var entries: [Int: Entry] = [:]
    private var nextSequenceValue = 1
    /// ジョブ単位のキャンセルハンドル(実行中のTask/URLSessionTaskの`cancel()`)。
    /// `setCancellationHandle`で登録し、`requestCancel`が呼ばれた瞬間に実行して、
    /// 実行中の重い処理(主にOllamaへのHTTPリクエスト)を即座に中断させる
    /// (Codexレビュー指摘#6: フラグを立てるだけではFIFOの先頭が解放されない)。
    private var cancellationHandles: [Int: () -> Void] = [:]

    /// 録音開始時に呼ぶ。新しいsequence(単調増加)を採番し、未終端ジョブとして登録する。
    func beginJob() -> Int {
        let sequence = nextSequenceValue
        nextSequenceValue += 1
        entries[sequence] = Entry()
        return sequence
    }

    /// 現在の未終端(終端状態が確定していない)ジョブ数。
    var activeCount: Int {
        entries.values.filter { $0.terminalState == nil }.count
    }

    var hasActiveJobs: Bool { activeCount > 0 }

    /// キュー上限チェック。上限に達している場合は新規録音の開始を拒否すること。
    func canAcceptNewJob(limit: Int) -> Bool {
        activeCount < limit
    }

    func isCancelled(_ sequence: Int) -> Bool {
        entries[sequence]?.isCancelled ?? false
    }

    /// 冪等。既に終端済み、または既にコミット処理が開始されたジョブへの要求は無視する
    /// (前者は墓標が確定済みなら今更キャンセルしても無意味、後者はコミットの結果が既に
    /// 決定済みのため今からキャンセルしても実際には反映されない — Codexレビュー指摘#10)。
    func requestCancel(_ sequence: Int) {
        guard var entry = entries[sequence], entry.terminalState == nil, !entry.isCommitting else { return }
        entry.isCancelled = true
        entries[sequence] = entry
        cancellationHandles[sequence]?()
    }

    /// 実行中のステージ(認識・整形)のキャンセルハンドルを登録する。ステージ実行前に呼び、
    /// 実行完了後(結果の成否によらず)は`clearCancellationHandle`で必ず解除すること。
    func setCancellationHandle(_ sequence: Int, handle: @escaping () -> Void) {
        cancellationHandles[sequence] = handle
    }

    func clearCancellationHandle(_ sequence: Int) {
        cancellationHandles.removeValue(forKey: sequence)
    }

    /// `DeliveryCoordinator`がコミット処理(挿入または墓標化)を開始する際に呼ぶ。以後、この
    /// sequenceへの`requestCancel`は無視され、`latestCancellableSequence`の対象からも外れる
    /// (Codexレビュー指摘#10)。
    func beginCommitting(_ sequence: Int) {
        guard var entry = entries[sequence] else { return }
        entry.isCommitting = true
        entries[sequence] = entry
    }

    /// 現在未終端かつ未キャンセル・未コミット開始の中で最もsequenceが大きいジョブ。
    /// Escの階層的キャンセル(非録音時: 「まだ挿入されていない最新に話した内容の取り消し」)に使う。
    /// 既にコミット処理が開始されている(=挿入するかどうかが決定済みの)ジョブは対象から除く
    /// (Codexレビュー指摘#10: 対象にしてしまうと、実際には間に合わないキャンセル要求を
    /// 「受理できた」ように見せてしまう)。
    var latestCancellableSequence: Int? {
        entries
            .filter { $0.value.terminalState == nil && !$0.value.isCancelled && !$0.value.isCommitting }
            .keys
            .max()
    }

    /// メニューバー「すべての処理をキャンセル」用。未終端かつ未キャンセルの全ジョブにキャンセルを
    /// 要求する。`excluding`に現在録音中/finalizing中のジョブのsequenceを渡すことで、
    /// 「現在進行中の録音自体はキャンセルしない」という仕様を守る
    /// (sequenceを録音開始時に採番するようになったため、対象から明示的に除く必要がある)。
    func requestCancelAll(excluding excludedSequence: Int? = nil) {
        for sequence in entries.keys where sequence != excludedSequence {
            requestCancel(sequence)
        }
    }

    /// 終端状態を確定する。呼び出せるのは`DeliveryCoordinator`のコミット処理のみを想定している。
    /// 一度確定したジョブに対する再度の呼び出しは不変条件違反だが、テストプロセス自体を落とす
    /// (`assertionFailure`/`fatalError`)と他のテストの実行結果まで巻き添えにしてしまうため、
    /// エラーログのみに留めて無視する(既存の終端状態は変化しない)。
    func markTerminal(_ sequence: Int, state: DictationJobTerminalState) {
        guard var entry = entries[sequence] else {
            log.error("markTerminal called for unknown sequence \(sequence, privacy: .public)")
            return
        }
        guard entry.terminalState == nil else {
            log.error("DictationJobRegistry: sequence \(sequence, privacy: .public) is already terminal (\(String(describing: entry.terminalState), privacy: .public)); ignoring new state \(String(describing: state), privacy: .public)")
            return
        }
        entry.terminalState = state
        entries[sequence] = entry
        cancellationHandles.removeValue(forKey: sequence)
    }

    func terminalState(_ sequence: Int) -> DictationJobTerminalState? {
        entries[sequence]?.terminalState
    }
}
