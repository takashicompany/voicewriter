import XCTest
@testable import Voicewriter

/// Codexレビュー指摘#7(ModelDownloaderの進捗/完了コールバックが独立した非構造化Taskで、
/// 後から届いた古い結果が新しい状態を上書きしうる)・#8(DynamicTranscriptionEngine.reload()の
/// 連続呼び出しで、モデルロードが遅い古い呼び出しの結果が新しい呼び出しの結果を後から
/// 上書きしうる)の回帰テスト。
///
/// どちらの修正も、非同期処理の完了順序が呼び出し順と一致しない場合に「自分より新しい世代が
/// 既に始まっているか」を判定する`GenerationCounter`に依存している。`ModelDownloader`は実際の
/// ネットワークダウンロード、`DynamicTranscriptionEngine`はモデルファイルI/Oを伴うため、
/// それら自体をハードウェア・ネットワーク非依存で決定的にテストすることは難しい。
/// そのため、両方が依存する共通の同期プリミティブ自体を直接テストする。
final class GenerationCounterTests: XCTestCase {
    func testFirstGenerationIsOne() {
        let counter = GenerationCounter()
        XCTAssertEqual(counter.next(), 1)
    }

    func testGenerationsIncreaseMonotonically() {
        let counter = GenerationCounter()
        XCTAssertEqual(counter.next(), 1)
        XCTAssertEqual(counter.next(), 2)
        XCTAssertEqual(counter.next(), 3)
    }

    func testOnlyLatestGenerationIsCurrent() {
        let counter = GenerationCounter()
        let first = counter.next()
        let second = counter.next()

        // 後から発行された世代(second)だけが「現在の世代」であり、
        // 先に発行された世代(first, 追い越された古い呼び出しに相当)はもう現在の世代ではない。
        XCTAssertFalse(counter.isCurrent(first))
        XCTAssertTrue(counter.isCurrent(second))
    }

    /// 「遅い呼び出し(古い世代)が後から完了しても、既に新しい世代が始まっていれば無視すべき」
    /// という、#7・#8双方で要求されている振る舞いそのものを表す回帰テスト。
    func testStaleGenerationIsIgnoredEvenIfItsWorkFinishesLast() {
        let counter = GenerationCounter()
        let staleGeneration = counter.next() // 例: 遅いreload()/古いダウンロード世代

        // 割り込みで新しい呼び出しが発生し、世代が進む。
        let freshGeneration = counter.next() // 例: 直後に呼ばれた新しいreload()/新しいダウンロード

        // 実際の完了順序としては、古い方(staleGeneration)の処理が後から終わることがある
        // (ロード時間・ネットワーク速度が呼び出し順と無関係なため)。
        // それでも、古い世代は「現在の世代」ではないと判定されなければならない。
        XCTAssertFalse(counter.isCurrent(staleGeneration), "古い世代の遅延結果を反映してはいけない")
        XCTAssertTrue(counter.isCurrent(freshGeneration), "常に最新世代の結果だけが有効であるべき")
    }

    func testUnknownGenerationIsNeverCurrent() {
        let counter = GenerationCounter()
        _ = counter.next()
        XCTAssertFalse(counter.isCurrent(999))
        XCTAssertFalse(counter.isCurrent(0))
    }

    /// `next()`/`isCurrent()`を多数のスレッドから同時に呼んでもクラッシュ・データレースが
    /// 起きないことのスモークテスト(`NSLock`によるロック保護の確認)。
    func testConcurrentNextAndIsCurrentDoesNotCrash() {
        let counter = GenerationCounter()
        let iterations = 1000
        let expectation = expectation(description: "concurrent access completes")
        expectation.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for _ in 0..<iterations {
                _ = counter.next()
            }
            expectation.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<iterations {
                _ = counter.isCurrent(Int.random(in: 0...iterations))
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10)
    }
}
