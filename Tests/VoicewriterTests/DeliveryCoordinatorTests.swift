import AppKit
import XCTest
@testable import Voicewriter

/// テスト用のフェイク`TextInserting`。実際のアクセシビリティ権限・CGEvent送出には依存しない。
private final class FakeTextInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    var shouldThrow: Error?

    func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
        if let shouldThrow {
            throw shouldThrow
        }
        insertedTexts.append(text)
        onPasted()
    }
}

private enum FakeInsertionError: Error { case boom }

/// `TextInserter`内部の最終フォーカス確認(`TextInsertionError.focusChanged`)を模すフェイク
/// `TextInserting`。`DeliveryCoordinator`の最初のフォーカス比較を通過した後、実際に
/// `sendCommandV()`を送出する直前でフォーカスが変わっていたケースを再現する(Codexレビュー指摘#4)。
private final class FocusChangedAtSendTimeTextInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    func insert(text: String, expectedFrontmostProcessIdentifier: pid_t?, onPasted: @escaping () -> Void) async throws {
        throw TextInsertionError.focusChanged
    }
}

/// `DeliveryCoordinator`(リオーダーバッファ)の単体テスト。
/// 「発話順(sequence順)を厳守して挿入する」という核心の不変条件を、
/// Coordinatorのジョブパイプライン全体を組み立てずに直接検証する。
@MainActor
final class DeliveryCoordinatorTests: XCTestCase {
    func testSecondJobCompletingFirstStillWaitsForFirstJob() async {
        let registry = DictationJobRegistry()
        let inserter = FakeTextInserter()
        let coordinator = DeliveryCoordinator(registry: registry, textInserter: inserter)

        let sequence1 = registry.beginJob()
        let sequence2 = registry.beginJob()

        // #2が先に完了する。
        coordinator.complete(sequence: sequence2, outcome: .insertText("second", usedFormattingFallback: false), frontmostAppAtRecordingStart: nil)
        await Task.yield()
        XCTAssertTrue(inserter.insertedTexts.isEmpty, "#1が未完了のうちは#2も挿入されるべきではない")

        // #1が完了して初めて、#1→#2の順で挿入されるべき。
        coordinator.complete(sequence: sequence1, outcome: .insertText("first", usedFormattingFallback: false), frontmostAppAtRecordingStart: nil)

        for _ in 0..<200 where inserter.insertedTexts.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(inserter.insertedTexts, ["first", "second"])
    }

    func testTombstoneAdvancesOrderSoLaterJobsAreNotBlockedForever() async {
        let registry = DictationJobRegistry()
        let inserter = FakeTextInserter()
        let coordinator = DeliveryCoordinator(registry: registry, textInserter: inserter)

        var committed: [(Int, DeliveryCommitResult)] = []
        coordinator.onCommitted = { sequence, result in committed.append((sequence, result)) }

        let sequence1 = registry.beginJob()
        let sequence2 = registry.beginJob()

        // #1は無音スキップ(墓標)。
        coordinator.complete(sequence: sequence1, outcome: .tombstone(.skipped(.silence)), frontmostAppAtRecordingStart: nil)
        coordinator.complete(sequence: sequence2, outcome: .insertText("second", usedFormattingFallback: false), frontmostAppAtRecordingStart: nil)

        // `committed`(両方のコミット完了)を待つ。`insertedTexts`だけを見て待つと、textInserter呼び出しが
        // 実際にはactor境界を挟むため(FakeTextInserterはprotocol越しの呼び出し)、挿入直後・
        // markTerminal未実行のタイミングでテストの他アサーションが先走ってしまう競合がありうる。
        for _ in 0..<200 where committed.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(inserter.insertedTexts, ["second"], "墓標が順序を消費し、#2が詰まらず挿入されるべき")
        XCTAssertEqual(committed.count, 2)
        XCTAssertEqual(registry.terminalState(sequence1), .skipped(.silence))
        XCTAssertEqual(registry.terminalState(sequence2), .inserted)
    }

    func testCommitsAreHeldWhileRecordingIsActive() async {
        let registry = DictationJobRegistry()
        let inserter = FakeTextInserter()
        let coordinator = DeliveryCoordinator(registry: registry, textInserter: inserter)

        coordinator.setRecordingActive(true)
        let sequence = registry.beginJob()
        coordinator.complete(sequence: sequence, outcome: .insertText("held", usedFormattingFallback: false), frontmostAppAtRecordingStart: nil)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(inserter.insertedTexts.isEmpty, "録音中は挿入がコミットされるべきではない")

        coordinator.setRecordingActive(false)
        for _ in 0..<200 where inserter.insertedTexts.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(inserter.insertedTexts, ["held"], "録音終了後にまとめてコミットされるべき")
    }

    func testFocusMismatchSkipsAutoInsertAndTombstonesTheJob() async {
        let registry = DictationJobRegistry()
        let inserter = FakeTextInserter()
        let coordinator = DeliveryCoordinator(
            registry: registry,
            textInserter: inserter,
            currentFrontmostApp: { nil } // 録音開始時のフロントモストと必ず異なる(pidが一致しない)扱いにする
        )

        var focusMismatchTexts: [String] = []
        coordinator.onCommitted = { _, result in
            if case .focusMismatch(let text) = result {
                focusMismatchTexts.append(text)
            }
        }

        let sequence = registry.beginJob()
        // frontmostAppAtRecordingStartにダミー値(現在のプロセス自身)を渡すことで、
        // currentFrontmostApp()がnilを返す限り必ず不一致になる。
        coordinator.complete(
            sequence: sequence,
            outcome: .insertText("mismatched", usedFormattingFallback: false),
            frontmostAppAtRecordingStart: NSRunningApplication.current
        )

        for _ in 0..<200 where registry.terminalState(sequence) == nil {
            await Task.yield()
        }

        XCTAssertTrue(inserter.insertedTexts.isEmpty, "フォーカス不一致では自動挿入しないべき")
        XCTAssertEqual(registry.terminalState(sequence), .focusMismatch)
        XCTAssertEqual(focusMismatchTexts, ["mismatched"])
    }

    func testCancellationBetweenCompletionAndCommitDiscardsInsertion() async {
        let registry = DictationJobRegistry()
        let inserter = FakeTextInserter()
        let coordinator = DeliveryCoordinator(registry: registry, textInserter: inserter)

        coordinator.setRecordingActive(true)
        let sequence = registry.beginJob()
        // ジョブの認識・整形自体は完了しているが、まだコミット(挿入)されていない状態。
        coordinator.complete(sequence: sequence, outcome: .insertText("should be discarded", usedFormattingFallback: false), frontmostAppAtRecordingStart: nil)

        // ここでEscによる非録音時キャンセル相当が発生する(処理完了後・コミット前)。
        registry.requestCancel(sequence)

        coordinator.setRecordingActive(false)
        for _ in 0..<200 where registry.terminalState(sequence) == nil {
            await Task.yield()
        }

        XCTAssertTrue(inserter.insertedTexts.isEmpty, "コミット前にキャンセルされた場合は挿入されるべきではない")
        XCTAssertEqual(registry.terminalState(sequence), .cancelled)
    }

    /// Codexレビュー指摘#10の回帰テスト: 墓標化(スキップ/失敗)の直前にキャンセルが要求されて
    /// いた場合は、`.cancelled`を優先するべき(ユーザーの意図はあくまでキャンセルであり、
    /// たまたま先に別の墓標状態として確定していたとしても、その結果より優先されるべきため)。
    func testTombstoneCommitPrefersCancelledWhenAlreadyCancelled() async {
        let registry = DictationJobRegistry()
        let inserter = FakeTextInserter()
        let coordinator = DeliveryCoordinator(registry: registry, textInserter: inserter)

        var committed: [(Int, DeliveryCommitResult)] = []
        coordinator.onCommitted = { sequence, result in committed.append((sequence, result)) }

        let sequence = registry.beginJob()
        registry.requestCancel(sequence)
        // ジョブ処理側は(キャンセルに気づく前に)無音スキップとして墓標化していたとする。
        coordinator.complete(sequence: sequence, outcome: .tombstone(.skipped(.silence)), frontmostAppAtRecordingStart: nil)

        for _ in 0..<200 where committed.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(registry.terminalState(sequence), .cancelled, "キャンセル要求済みなら.skippedより.cancelledを優先するべき")
        if case .cancelled = committed.first?.1 {
            // expected
        } else {
            XCTFail("Expected .cancelled, got \(String(describing: committed.first))")
        }
    }

    /// Codexレビュー指摘#4の回帰テスト: `DeliveryCoordinator`の最初のフォーカス比較を通過した後
    /// (=フォーカスは一致していた)でも、`TextInserter`内部の`sendCommandV()`直前の最終確認で
    /// フォーカス不一致(`TextInsertionError.focusChanged`)が検出された場合、`.failed`ではなく
    /// `.focusMismatch`として扱い、テキストを履歴へ回収できるようにするべき。
    func testFocusChangedRightBeforeSendIsTreatedAsFocusMismatchNotFailure() async {
        let registry = DictationJobRegistry()
        let inserter = FocusChangedAtSendTimeTextInserter()
        // currentFrontmostApp()は録音開始時と一致させ、DeliveryCoordinator自身の最初の比較を
        // 通過させる(以降のフォーカス不一致はTextInserter内部の最終確認でのみ検出される)。
        let coordinator = DeliveryCoordinator(
            registry: registry,
            textInserter: inserter,
            currentFrontmostApp: { NSRunningApplication.current }
        )

        var results: [DeliveryCommitResult] = []
        coordinator.onCommitted = { _, result in results.append(result) }

        let sequence = registry.beginJob()
        coordinator.complete(
            sequence: sequence,
            outcome: .insertText("mismatched at send time", usedFormattingFallback: false),
            frontmostAppAtRecordingStart: NSRunningApplication.current
        )

        for _ in 0..<200 where registry.terminalState(sequence) == nil {
            await Task.yield()
        }

        XCTAssertEqual(registry.terminalState(sequence), .focusMismatch)
        if case .focusMismatch(let text) = results.first {
            XCTAssertEqual(text, "mismatched at send time")
        } else {
            XCTFail("Expected .focusMismatch, got \(String(describing: results.first))")
        }
    }

    func testInsertionFailureTombstonesJobAsFailed() async {
        let registry = DictationJobRegistry()
        let inserter = FakeTextInserter()
        inserter.shouldThrow = FakeInsertionError.boom
        let coordinator = DeliveryCoordinator(registry: registry, textInserter: inserter)

        var failureReported = false
        coordinator.onCommitted = { _, result in
            if case .failed = result { failureReported = true }
        }

        let sequence = registry.beginJob()
        coordinator.complete(sequence: sequence, outcome: .insertText("text", usedFormattingFallback: false), frontmostAppAtRecordingStart: nil)

        for _ in 0..<200 where registry.terminalState(sequence) == nil {
            await Task.yield()
        }

        XCTAssertEqual(registry.terminalState(sequence), .failed)
        XCTAssertTrue(failureReported)
    }
}
