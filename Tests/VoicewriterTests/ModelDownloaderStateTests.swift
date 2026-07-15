import XCTest
@testable import Voicewriter

/// Codexレビュー指摘#17のうち「失敗後の再試行が.idle以外を拒否して動かない」の回帰テスト。
/// 実際のネットワークダウンロードは行わず、状態遷移の可否だけを判定する純粋関数を検証する。
final class ModelDownloaderStateTests: XCTestCase {
    func testCanStartFromIdle() {
        XCTAssertTrue(ModelDownloader.canStartDownload(from: .idle))
    }

    func testCanStartFromFailure() {
        // 以前は.idle以外を拒否していたため、失敗後の「再試行」ボタンが機能しなかった。
        XCTAssertTrue(ModelDownloader.canStartDownload(from: .failure("network error")))
    }

    func testCannotStartWhileDownloading() {
        XCTAssertFalse(ModelDownloader.canStartDownload(from: .downloading(progress: 0.5, receivedBytes: 100, totalBytes: 200)))
    }

    func testCannotStartAfterSuccess() {
        XCTAssertFalse(ModelDownloader.canStartDownload(from: .success))
    }
}
