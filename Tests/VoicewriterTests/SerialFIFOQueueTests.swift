import XCTest
@testable import Voicewriter

/// `SerialFIFOQueue`(推論の直列化に使う汎用FIFOキュー)の単体テスト。
/// whisper.cpp(認識)とOllama(整形)がUnified Memory/GPUを奪い合わないよう、Coordinatorは
/// ジョブ単位の処理をこのキューへenqueueしてJ1→J2→…の順で完全に直列実行する設計になっている。
@MainActor
final class SerialFIFOQueueTests: XCTestCase {
    /// 核心の回帰テスト: 「#2が先に完了しても#1を待つ」。
    /// #1は外部からの合図があるまで完了しない操作、#2は即座に完了する操作としてenqueueし、
    /// #2の`operation`本体が実際に実行され始めるのは#1が完了した後であることを確認する。
    func testSecondOperationWaitsForFirstEvenIfSecondWouldFinishFaster() async {
        let queue = SerialFIFOQueue()
        let gate = Gate()
        var executionOrder: [String] = []
        let orderBox = OrderBox()

        let task1 = queue.enqueue { () -> String in
            await gate.wait()
            await orderBox.append("op1")
            return "result1"
        }
        let task2 = queue.enqueue { () -> String in
            await orderBox.append("op2")
            return "result2"
        }

        // op2はゲートを待たないので、ここで少し猶予を与えても「まだ実行されていない」ことを確認する。
        try? await Task.sleep(nanoseconds: 50_000_000)
        executionOrder = await orderBox.snapshot()
        XCTAssertTrue(executionOrder.isEmpty, "op1が完了するまでop2は開始されるべきではない")

        await gate.open()

        let result1 = await task1.value
        let result2 = await task2.value

        XCTAssertEqual(result1, "result1")
        XCTAssertEqual(result2, "result2")
        executionOrder = await orderBox.snapshot()
        XCTAssertEqual(executionOrder, ["op1", "op2"], "enqueueされた順(FIFO)に実行されるべき")
    }

    /// 3件以上でも順序が保たれることの確認。
    func testMultipleOperationsRunInEnqueueOrder() async {
        let queue = SerialFIFOQueue()
        let orderBox = OrderBox()

        let tasks = (1...5).map { index in
            queue.enqueue { () -> Int in
                // 逆順に近い遅延を与えても、実行順はenqueue順を保つはず。
                let delayNanos = UInt64((5 - index) * 5_000_000)
                try? await Task.sleep(nanoseconds: delayNanos)
                await orderBox.append("op\(index)")
                return index
            }
        }

        var results: [Int] = []
        for task in tasks {
            results.append(await task.value)
        }

        XCTAssertEqual(results, [1, 2, 3, 4, 5])
        let order = await orderBox.snapshot()
        XCTAssertEqual(order, ["op1", "op2", "op3", "op4", "op5"])
    }
}

/// テスト用の手動ゲート。`wait()`は`open()`が呼ばれるまでサスペンドする。
private actor Gate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations = []
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// テスト用の実行順序記録。
private actor OrderBox {
    private var order: [String] = []
    func append(_ value: String) { order.append(value) }
    func snapshot() -> [String] { order }
}
