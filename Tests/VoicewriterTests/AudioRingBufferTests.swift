import XCTest
@testable import Voicewriter

/// Codexレビュー指摘#12(`AudioRingBuffer.recent`が`filledCount`をロック外で読んでいた)の回帰テスト。
/// 現在は`recent`全体が単一のロック区間で実行されるため、`append`との同時実行下でも
/// クラッシュせず、常に妥当な範囲(要求数以下)のサンプル列が返ることを確認する。
final class AudioRingBufferTests: XCTestCase {
    func testRecentReturnsEmptyWhenNothingWritten() {
        let buffer = AudioRingBuffer(capacitySamples: 100)
        XCTAssertEqual(buffer.recent(seconds: 1.0, sampleRate: 10), [])
    }

    func testRecentReturnsMostRecentSamplesInOrder() {
        let buffer = AudioRingBuffer(capacitySamples: 100)
        buffer.append([1, 2, 3, 4, 5])
        // sampleRate=1なので3秒分=3サンプル、末尾3件(3,4,5)が古い順に返るはず
        XCTAssertEqual(buffer.recent(seconds: 3, sampleRate: 1), [3, 4, 5])
    }

    func testRecentClampsToFilledCountEvenIfRequestedMore() {
        let buffer = AudioRingBuffer(capacitySamples: 100)
        buffer.append([1, 2, 3])
        // 10秒分要求しても、実際に書き込まれた3サンプルしか無いのでそれだけ返る
        XCTAssertEqual(buffer.recent(seconds: 10, sampleRate: 1), [1, 2, 3])
    }

    func testAppendWrapsAroundCapacity() {
        let buffer = AudioRingBuffer(capacitySamples: 4)
        buffer.append([1, 2, 3, 4, 5, 6]) // capacity=4なので古い2つ(1,2)は捨てられ 3,4,5,6 が残るはず
        XCTAssertEqual(buffer.recent(seconds: 4, sampleRate: 1), [3, 4, 5, 6])
    }

    /// `recent`と`append`を多数のスレッドから同時に呼び続けてもクラッシュ・不整合が起きないことを確認する。
    /// (以前の実装は`filledCount`をロック外で読んでいたため、Thread Sanitizer等でデータレースとして
    ///  検出されうる状態だった。単一ロック化により解消されていることのスモークテスト。)
    func testConcurrentAppendAndRecentDoesNotCrash() {
        let buffer = AudioRingBuffer(capacitySamples: 1600) // 0.1秒 @16kHz相当
        let iterations = 500
        let expectation = expectation(description: "concurrent access completes")
        expectation.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for i in 0..<iterations {
                buffer.append([Float(i)])
            }
            expectation.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<iterations {
                let samples = buffer.recent(seconds: 1.0, sampleRate: 16000)
                XCTAssertLessThanOrEqual(samples.count, 1600)
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10)
    }
}
