import Foundation

/// 文字起こし前の音声前処理ユーティリティ(whisper.cppへ渡す直前に適用)。
enum AudioPreprocessing {
    /// エネルギー(RMS)ベースで先頭の無音/低レベルノイズをトリムする。
    ///
    /// AlwaysOnモードのプリロール(既定0.5秒、`Settings.prerollSeconds`)には、発話開始前の
    /// 環境音・マイクノイズが混入することがある。whisper.cppは音声の先頭付近にある短いノイズ区間を
    /// 誤って音声として解釈し、無関係な単語を出力する(ハルシネーション)ことがあるため、
    /// 発話が実際に始まる位置より手前の低エネルギー区間を落としてから`whisper_full`に渡す。
    ///
    /// - フレーム単位(既定20ms)でRMSを計算し、`rmsThreshold`を最初に超えたフレームを「発話開始」とみなす。
    /// - 発話開始の`marginSeconds`手前までは残す(語頭の子音・息継ぎの欠落を防ぐための安全マージン)。
    /// - トリム量は`maxTrimSeconds`を超えない(万一の誤検出でも録音の大部分を失わないための上限)。
    /// - 全区間が閾値未満(録音全体が無音等)の場合はトリムしない(無音区間の扱いは`no_speech_thold`側に委ねる)。
    static func trimLeadingSilence(
        samples: [Float],
        sampleRate: Double,
        frameDurationSeconds: Double = 0.02,
        rmsThreshold: Float = 0.015,
        marginSeconds: Double = 0.15,
        maxTrimSeconds: Double = 1.0
    ) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return samples }

        let frameSize = max(1, Int(sampleRate * frameDurationSeconds))
        var loudFrameStart: Int?

        var index = 0
        while index < samples.count {
            let end = min(index + frameSize, samples.count)
            var sumSquares: Float = 0
            for i in index..<end {
                sumSquares += samples[i] * samples[i]
            }
            let rms = (sumSquares / Float(end - index)).squareRoot()
            if rms >= rmsThreshold {
                loudFrameStart = index
                break
            }
            index = end
        }

        guard let loudStart = loudFrameStart else {
            // 全区間が閾値未満。無音のみの録音を誤って空にしてしまわないよう、トリムせず返す。
            return samples
        }

        let marginSamples = Int(marginSeconds * sampleRate)
        let maxTrimSamples = Int(maxTrimSeconds * sampleRate)
        let trimTo = min(max(0, loudStart - marginSamples), maxTrimSamples)

        guard trimTo > 0 else { return samples }
        return Array(samples[trimTo...])
    }
}
