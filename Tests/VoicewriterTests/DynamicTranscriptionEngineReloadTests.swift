import XCTest
@testable import Voicewriter

/// `DynamicTranscriptionEngine.reloadAndWait()`(`reload()`のawait可能版、モデルの初回自動
/// セットアップ完了時に`AppDelegate`が「実際にエンジンが差し替わった」ことを確認してから録音の
/// ブロックを解除するために追加)の回帰テスト。
///
/// 実際のwhisper.cppモデルロード(数百MB〜GB級のファイルI/Oを伴う)は決定的なテストにしづらいため
/// (`GenerationCounterTests`のコメント参照)、`Settings.sttEngine = .stub`(ファイルI/O無し、
/// 常に警告なしで即座に構築できる)に固定した上で、`reloadAndWait()`が実際に完了してから
/// 呼び出し元へ制御を返すこと・戻り値が反映後の`activeEngineIsFallback`と一致すること・
/// `onWarningChanged`が呼ばれることを確認する。
@MainActor
final class DynamicTranscriptionEngineReloadTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.sttEngine)
        super.tearDown()
    }

    func testReloadAndWaitReturnsAfterCompletionAndReflectsActiveEngineIsFallback() async {
        Settings.sttEngine = .stub
        let engine = DynamicTranscriptionEngine()
        // stubエンジンはフォールバックではない(意図した選択のため)。
        XCTAssertFalse(engine.activeEngineIsFallback)

        let result = await engine.reloadAndWait()

        XCTAssertFalse(result, "stubエンジン選択時はactiveEngineIsFallback=falseであるべき")
        XCTAssertFalse(engine.activeEngineIsFallback)
        // 実際に文字起こしが動作すること(=差し替えが完了していること)も確認する。
        let text = try? await engine.transcribe(samples: [0.1, 0.2], sampleRate: 16000, language: "ja", vocabularyHint: "", vadEnabled: false)
        XCTAssertNotNil(text)
    }

    func testReloadAndWaitNotifiesOnWarningChanged() async {
        Settings.sttEngine = .stub
        let engine = DynamicTranscriptionEngine()

        var warningChangedCallCount = 0
        engine.onWarningChanged = { _ in warningChangedCallCount += 1 }

        _ = await engine.reloadAndWait()

        XCTAssertEqual(warningChangedCallCount, 1, "reloadAndWait()完了時にonWarningChangedが1回呼ばれるべき")
    }

    /// `reload()`(fire-and-forget版)も、内部で`reloadAndWait()`へ委譲するようリファクタリングした後も
    /// 引き続き非同期にエンジンを差し替えることの回帰テスト。
    func testReloadStillEventuallyUpdatesWarningState() async {
        Settings.sttEngine = .stub
        let engine = DynamicTranscriptionEngine()

        var warningChangedCallCount = 0
        engine.onWarningChanged = { _ in warningChangedCallCount += 1 }

        engine.reload()

        for _ in 0..<200 where warningChangedCallCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(warningChangedCallCount, 1)
    }
}
