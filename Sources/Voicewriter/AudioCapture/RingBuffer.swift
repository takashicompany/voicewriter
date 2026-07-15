import Foundation

/// 16kHz/mono/Float32サンプルを保持する固定長リングバッファ。
/// AlwaysOnモードで「直近N秒」を常時保持し、プリロールに使う。
final class AudioRingBuffer {
    private var storage: [Float]
    private var writeIndex: Int = 0
    private var filledCount: Int = 0
    private let capacity: Int
    private let lock = NSLock()

    init(capacitySamples: Int) {
        self.capacity = max(capacitySamples, 1)
        self.storage = [Float](repeating: 0, count: self.capacity)
    }

    convenience init(seconds: Double, sampleRate: Double) {
        self.init(capacitySamples: Int(seconds * sampleRate))
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var samplesToWrite = samples
        // バッファ容量を超える分は先頭を捨てて末尾のみ採用
        if samplesToWrite.count > capacity {
            samplesToWrite = Array(samplesToWrite.suffix(capacity))
        }

        for sample in samplesToWrite {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        filledCount = min(filledCount + samplesToWrite.count, capacity)
    }

    /// 直近 `seconds` 秒分のサンプルを古い順に返す。
    /// `filledCount`の読み取りも含め、丸ごと単一のロック区間で行う
    /// (以前は`filledCount`をロック外で読んでから`recentSamples`内で再度ロックしており、
    ///  その間に`append`が割り込むと`writeIndex`とズレた不整合な範囲を読みうるデータレースがあった)。
    func recent(seconds: Double, sampleRate: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let count = min(Int(seconds * sampleRate), filledCount)
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        var readIndex = (writeIndex - count + capacity * 2) % capacity
        for i in 0..<count {
            result[i] = storage[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        return result
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        filledCount = 0
        storage = [Float](repeating: 0, count: capacity)
    }
}
