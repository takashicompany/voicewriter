import XCTest
@testable import Voicewriter

/// `DictationJobRegistry`(ジョブごとの状態・キャンセルフラグ管理)の単体テスト。
@MainActor
final class DictationJobRegistryTests: XCTestCase {
    func testBeginJobAssignsMonotonicallyIncreasingSequence() {
        let registry = DictationJobRegistry()
        let s1 = registry.beginJob()
        let s2 = registry.beginJob()
        let s3 = registry.beginJob()
        XCTAssertEqual([s1, s2, s3], [1, 2, 3])
    }

    func testJobRemainsActiveUntilExplicitlyMarkedTerminal() {
        let registry = DictationJobRegistry()
        let sequence = registry.beginJob()
        XCTAssertTrue(registry.hasActiveJobs)
        XCTAssertEqual(registry.activeCount, 1)

        // 処理(認識・整形)が完了しても、markTerminalを呼ぶまでは「未終端」のまま
        // (コミット待ちのジョブもキュー上限やEscの対象に含めるための設計)。
        XCTAssertNil(registry.terminalState(sequence))
        XCTAssertTrue(registry.hasActiveJobs)

        registry.markTerminal(sequence, state: .inserted)
        XCTAssertEqual(registry.terminalState(sequence), .inserted)
        XCTAssertFalse(registry.hasActiveJobs)
        XCTAssertEqual(registry.activeCount, 0)
    }

    func testTerminalStateIsSetOnlyOnce() {
        let registry = DictationJobRegistry()
        let sequence = registry.beginJob()
        registry.markTerminal(sequence, state: .inserted)
        // 2度目の呼び出しは無視される(既存の終端状態は変化しない)。
        registry.markTerminal(sequence, state: .failed)
        XCTAssertEqual(registry.terminalState(sequence), .inserted)
    }

    func testCanAcceptNewJobRespectsLimit() {
        let registry = DictationJobRegistry()
        for _ in 0..<8 {
            _ = registry.beginJob()
        }
        XCTAssertFalse(registry.canAcceptNewJob(limit: 8), "上限(8件)に達したら新規受付を拒否するべき")

        // 1件終端させれば枠が空く。
        registry.markTerminal(1, state: .inserted)
        XCTAssertTrue(registry.canAcceptNewJob(limit: 8))
    }

    func testLatestCancellableSequenceIsMaxActiveUncancelledSequence() {
        let registry = DictationJobRegistry()
        let s1 = registry.beginJob()
        let s2 = registry.beginJob()
        let s3 = registry.beginJob()

        XCTAssertEqual(registry.latestCancellableSequence, s3)

        registry.markTerminal(s3, state: .inserted)
        XCTAssertEqual(registry.latestCancellableSequence, s2, "s3が終端済みならs2が最新のキャンセル対象になるべき")

        registry.requestCancel(s2)
        XCTAssertEqual(registry.latestCancellableSequence, s1, "s2が既にキャンセル要求済みならs1が対象になるべき")
    }

    func testRequestCancelAllCancelsOnlyActiveJobs() {
        let registry = DictationJobRegistry()
        let s1 = registry.beginJob()
        let s2 = registry.beginJob()
        registry.markTerminal(s1, state: .inserted)

        registry.requestCancelAll()

        XCTAssertFalse(registry.isCancelled(s1), "既に終端済みのジョブへのキャンセル要求は無視されるべき")
        XCTAssertTrue(registry.isCancelled(s2))
    }

    func testRequestCancelOnAlreadyTerminalJobIsIgnored() {
        let registry = DictationJobRegistry()
        let sequence = registry.beginJob()
        registry.markTerminal(sequence, state: .inserted)
        registry.requestCancel(sequence)
        XCTAssertFalse(registry.isCancelled(sequence))
    }

    /// Codexレビュー指摘#10の回帰テスト: `DeliveryCoordinator`がコミット処理を開始した
    /// (`beginCommitting`)後は、Escとの競合による誤認("キャンセルできた"のに実際には
    /// 挿入される)を防ぐため、キャンセル要求自体を無視するべき。
    func testRequestCancelIsIgnoredOnceCommittingHasBegun() {
        let registry = DictationJobRegistry()
        let sequence = registry.beginJob()
        registry.beginCommitting(sequence)
        registry.requestCancel(sequence)
        XCTAssertFalse(registry.isCancelled(sequence), "コミット開始後のキャンセル要求は無視されるべき")
    }

    /// コミット処理が既に始まっているジョブは、Escの階層的キャンセル(非録音時)の対象からも
    /// 除外されるべき(対象にしてしまうと、実際には間に合わないキャンセル要求を
    /// 「受理できた」ように見せてしまう)。
    func testLatestCancellableSequenceExcludesCommittingJobs() {
        let registry = DictationJobRegistry()
        let s1 = registry.beginJob()
        let s2 = registry.beginJob()
        registry.beginCommitting(s2)
        XCTAssertEqual(registry.latestCancellableSequence, s1, "コミット中のジョブは対象から除外されるべき")
    }
}
