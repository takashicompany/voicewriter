import Foundation

/// Float32 PCMサンプルをモノラル16bit PCM WAVファイルとして書き出す簡易ユーティリティ。
enum WavWriter {
    static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)

        var data = Data()

        func appendString(_ s: String) {
            data.append(s.data(using: .ascii)!)
        }
        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            data.append(Data(bytes: &le, count: 4))
        }
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }

        appendString("RIFF")
        appendUInt32(36 + dataSize)
        appendString("WAVE")

        appendString("fmt ")
        appendUInt32(16) // PCMフォーマットチャンクサイズ
        appendUInt16(1) // PCM
        appendUInt16(channels)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)

        appendString("data")
        appendUInt32(dataSize)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let intValue = Int16(clamped * Float(Int16.max))
            var le = intValue.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}
