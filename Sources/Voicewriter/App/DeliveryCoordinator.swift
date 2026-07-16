import AppKit
import Foundation
import os.log

/// ジョブの処理結果(認識・整形の完了、またはキャンセル/スキップ/失敗)。
/// `DeliveryCoordinator.complete(sequence:outcome:)`へ渡す。
enum DictationJobOutcome: Sendable {
    /// 挿入すべきテキストが得られた(整形結果、または整形なしの原文)。
    case insertText(String, usedFormattingFallback: Bool)
    /// 挿入を伴わない終端状態(キャンセル/スキップ/失敗)。sequenceの順序だけを消費する「墓標」。
    case tombstone(DictationJobTerminalState)
}

/// 実際にコミットされた結果。HUD/メニューバー配線用の通知に使う。
enum DeliveryCommitResult {
    /// `text`は履歴記録用(挿入成功後も「最近の文字起こし結果」から再コピーできるようにするため)。
    case inserted(text: String, usedFormattingFallback: Bool)
    case skipped(RecordingSkipReason)
    case cancelled
    /// `error`はテキスト挿入自体が失敗した場合のみ設定される(アクセシビリティ未許可等、メニューバー
    /// 警告の出し分けに使う)。それ以外(ジョブ処理側の失敗を墓標化した場合)は`nil`。
    case failed(error: Error?)
    /// 挿入時点でフォーカスが録音開始時と一致しなかったため自動挿入を見送った。`text`は履歴回収用。
    case focusMismatch(text: String)
}

/// 発話順(sequence順)を厳守してテキスト挿入をコミットするリオーダーバッファ。
///
/// - 各ジョブの処理(認識・整形)は完了順が入れ替わりうるが、`nextCommitSequence`を維持し、
///   sequence順に揃うまで結果を`pending`に貯めておく(#2が先に完了しても#1がコミットされるまで待つ)。
/// - キャンセル/無音スキップ/失敗/フォーカス不一致も「墓標」としてsequenceを消費する
///   (これを消費しないと、欠番のジョブを永遠に待ち続けて後続が詰まってしまう)。
/// - 録音中(`setRecordingActive(true)`〜`false`)はコミット処理自体を保留する。理由: 別アプリで
///   録音中に前ジョブの結果が挿入されると、挿入先を録音中の対象と取り違えたり、HUDの録音中表示
///   (レベルメーター)を完了通知が上書きしてしまう事故を防ぐため。録音終了後にまとめて順次コミットする。
/// - 実際の挿入(フォーカス確認〜Cmd+V送出)はMainActor上の単一のクリティカル区間として行い、
///   その間`isInsertionCriticalSection`をtrueにする(`Coordinator`が新規録音開始要求を
///   この区間が終わるまで待つかどうかの判定に使う。`onInsertionCriticalSectionEnded`で
///   区間終了を通知できる)。
@MainActor
final class DeliveryCoordinator {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "DeliveryCoordinator")

    private let registry: DictationJobRegistry
    private let textInserter: TextInserting
    private let currentFrontmostApp: () -> NSRunningApplication?

    private var pending: [Int: PendingEntry] = [:]
    private var nextCommitSequence = 1
    private var isRecordingActive = false
    private var isDraining = false

    /// 挿入クリティカル区間(フォーカス確認開始〜Cmd+V送出直後)の間true。
    private(set) var isInsertionCriticalSection = false {
        didSet {
            guard isInsertionCriticalSection != oldValue, !isInsertionCriticalSection else { return }
            let waiters = criticalSectionWaiters
            criticalSectionWaiters = []
            for waiter in waiters { waiter() }
        }
    }
    /// `isInsertionCriticalSection`が`false`になるのを待っている待機者。
    /// `Coordinator`が新規録音開始要求を、タイムアウトによる打ち切りなしに正確に待つために使う
    /// (Codexレビュー指摘#3: 以前は最大100msのポーリングで打ち切り、区間が実際に閉じたかを
    /// 確認せずに録音を開始してしまっていた)。
    private var criticalSectionWaiters: [() -> Void] = []

    /// 実際にコミットが行われるたびに呼ばれる(HUD/メニューバー配線用)。
    var onCommitted: ((_ sequence: Int, _ result: DeliveryCommitResult) -> Void)?

    private struct PendingEntry {
        let outcome: DictationJobOutcome
        let frontmostAppAtRecordingStart: NSRunningApplication?
    }

    init(
        registry: DictationJobRegistry,
        textInserter: TextInserting,
        currentFrontmostApp: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    ) {
        self.registry = registry
        self.textInserter = textInserter
        self.currentFrontmostApp = currentFrontmostApp
    }

    /// `Coordinator`の録音状態が変わるたびに呼ぶ。録音終了(false)になった時点で保留分を排出する。
    func setRecordingActive(_ active: Bool) {
        isRecordingActive = active
        if !active {
            Task { await drainIfPossible() }
        }
    }

    /// ジョブの処理結果を登録する。sequence順に揃うまで実際のコミットは保留される。
    func complete(sequence: Int, outcome: DictationJobOutcome, frontmostAppAtRecordingStart: NSRunningApplication?) {
        pending[sequence] = PendingEntry(outcome: outcome, frontmostAppAtRecordingStart: frontmostAppAtRecordingStart)
        Task { await drainIfPossible() }
    }

    /// 挿入クリティカル区間が終了するのを待つ。既に区間中でなければ即座に呼ばれる。
    /// `Coordinator.waitForInsertionCriticalSectionIfNeeded()`専用(Codexレビュー指摘#3)。
    func onInsertionCriticalSectionEnded(_ completion: @escaping () -> Void) {
        if !isInsertionCriticalSection {
            completion()
            return
        }
        criticalSectionWaiters.append(completion)
    }

    private func drainIfPossible() async {
        guard !isRecordingActive, !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while !isRecordingActive, let entry = pending[nextCommitSequence] {
            let sequence = nextCommitSequence
            pending.removeValue(forKey: sequence)
            nextCommitSequence += 1
            await commit(sequence: sequence, entry: entry)
        }
    }

    private func commit(sequence: Int, entry: PendingEntry) async {
        // コミット処理の開始をもって、このジョブは以後キャンセル不能になる(Codexレビュー指摘#10:
        // Escとの競合により.insertedで確定するジョブを「キャンセルできた」と誤認させないため)。
        registry.beginCommitting(sequence)

        switch entry.outcome {
        case .tombstone(let state):
            // 墓標化(スキップ/失敗)の直前にキャンセルが要求されていた場合は、`.cancelled`を優先する
            // (Codexレビュー指摘#10: ユーザーの意図はあくまでキャンセルであり、たまたま先に
            // スキップ/失敗として確定していたとしても、その結果より優先して扱うべきため)。
            let finalState: DictationJobTerminalState = registry.isCancelled(sequence) ? .cancelled : state
            registry.markTerminal(sequence, state: finalState)
            onCommitted?(sequence, Self.commitResult(for: finalState, text: nil))

        case .insertText(let text, let usedFallback):
            // Escによる非録音時キャンセルは、処理完了後・コミット前にも要求されうる(処理は完了済みだが
            // 「まだ挿入されていない」ジョブとして扱う設計のため)。ここで改めて確認する。
            if registry.isCancelled(sequence) {
                registry.markTerminal(sequence, state: .cancelled)
                onCommitted?(sequence, .cancelled)
                return
            }

            let recordingFrontmost = entry.frontmostAppAtRecordingStart
            let currentFrontmost = currentFrontmostApp()
            if let recordingFrontmost, currentFrontmost?.processIdentifier != recordingFrontmost.processIdentifier {
                log.warning("Frontmost app changed since recording started; skipping auto-insert for sequence \(sequence, privacy: .public)")
                registry.markTerminal(sequence, state: .focusMismatch)
                onCommitted?(sequence, .focusMismatch(text: text))
                return
            }

            isInsertionCriticalSection = true
            do {
                try await textInserter.insert(
                    text: text,
                    expectedFrontmostProcessIdentifier: recordingFrontmost?.processIdentifier
                ) { [weak self] in
                    self?.isInsertionCriticalSection = false
                }
            } catch TextInsertionError.focusChanged {
                // sendCommandV()直前の最終確認(TextInserter内部)でフォーカス不一致を検出した
                // (Codexレビュー指摘#4: 上のフォーカス確認からここまでの間にawaitを挟むため、
                // その間にユーザーがアプリを切り替えるTOCTOUが起こりうる)。
                isInsertionCriticalSection = false
                log.warning("Frontmost app changed just before paste; skipping auto-insert for sequence \(sequence, privacy: .public)")
                registry.markTerminal(sequence, state: .focusMismatch)
                onCommitted?(sequence, .focusMismatch(text: text))
                return
            } catch {
                isInsertionCriticalSection = false
                log.error("Text insertion failed for sequence \(sequence, privacy: .public): \(String(describing: error), privacy: .public)")
                registry.markTerminal(sequence, state: .failed)
                onCommitted?(sequence, .failed(error: error))
                return
            }
            isInsertionCriticalSection = false
            registry.markTerminal(sequence, state: .inserted)
            onCommitted?(sequence, .inserted(text: text, usedFormattingFallback: usedFallback))
        }
    }

    private static func commitResult(for state: DictationJobTerminalState, text: String?) -> DeliveryCommitResult {
        switch state {
        case .inserted:
            // 墓標経路では発生しない(挿入成功は`insertText`分岐でのみ確定するため)が、
            // 網羅性のために残す。
            return .inserted(text: text ?? "", usedFormattingFallback: false)
        case .cancelled:
            return .cancelled
        case .skipped(let reason):
            return .skipped(reason)
        case .failed:
            return .failed(error: nil)
        case .focusMismatch:
            return .focusMismatch(text: text ?? "")
        }
    }
}
