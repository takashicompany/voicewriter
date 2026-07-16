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

    /// ハルシネーション対策(多層防御)の第2層: 発話とみなせるエネルギーが録音全体に
    /// 存在するかどうかを判定する。
    ///
    /// 呼び出し側は`trimLeadingSilence`適用後のサンプルをここに渡すこと(先頭の無音/低レベル
    /// ノイズを除いた「実効サンプル」に対して判定するため)。
    ///
    /// 「確実な無音」と判定できる場合に限ってfalse(=文字起こしをスキップする対象)を返す、
    /// 保守的な設計にしている。判定は次の2条件の**AND**(両方成立して初めて無音とみなす):
    /// - 全体のRMS(平均的な音量)が`globalRmsThreshold`未満
    /// - 20ms単位のフレームで最大のRMS(`maxFrameRmsThreshold`)も未満
    ///
    /// 単純な瞬間ピーク振幅(1サンプルの最大値)は判定に使っていない。マイクのクリックノイズ・
    /// ポップノイズは瞬間ピークだけを不自然に押し上げることがあり、ピーク単独だと
    /// 「クリック音だけの録音」を発話ありと誤判定してしまう。一方でウィンドウ化した
    /// フレーム単位のRMS(20ms、`trimLeadingSilence`と同じ考え方)であれば、単発クリックの
    /// エネルギーは短時間平均に均されてもなお十分検出可能でありながら、瞬間値ほど過敏ではない。
    /// 2条件のANDにしているのは、globalRmsThresholdだけだと録音全体が長く大半が無音でも
    /// 一部に短い発話があるケースを誤って無音判定してしまう(全体平均に埋もれる)おそれがあり、
    /// maxFrameRmsThresholdだけだと逆に環境ノイズの瞬間的な揺らぎを拾いすぎるおそれがあるため。
    ///
    /// 閾値は既定で-50dBFS相当(globalRmsThreshold=0.003)・-44dBFS相当(maxFrameRmsThreshold=0.006)と、
    /// `trimLeadingSilence`のフレーム単位閾値(既定0.015、-36.5dBFS相当)よりもかなり低く(緩く)
    /// 設定している。これは「発話区間の先頭を検出する」トリム処理とは目的が異なり、
    /// ここでは「本当に発話が無い」ことに高い確信が持てる場合だけを棄却したいため
    /// (小声の正当な発話を誤って無音扱いしてしまう false negative のリスクを避ける)。
    static func hasSufficientEnergy(
        samples: [Float],
        sampleRate: Double = 16000,
        globalRmsThreshold: Float = 0.003,
        maxFrameRmsThreshold: Float = 0.006,
        frameDurationSeconds: Double = 0.02
    ) -> Bool {
        guard !samples.isEmpty, sampleRate > 0 else { return false }

        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        let globalRms = (sumSquares / Float(samples.count)).squareRoot()

        let frameSize = max(1, Int(sampleRate * frameDurationSeconds))
        var maxFrameRms: Float = 0
        var index = 0
        while index < samples.count {
            let end = min(index + frameSize, samples.count)
            var frameSumSquares: Float = 0
            for i in index..<end {
                frameSumSquares += samples[i] * samples[i]
            }
            let frameRms = (frameSumSquares / Float(end - index)).squareRoot()
            if frameRms > maxFrameRms { maxFrameRms = frameRms }
            index = end
        }

        let isDefiniteSilence = globalRms < globalRmsThreshold && maxFrameRms < maxFrameRmsThreshold
        return !isDefiniteSilence
    }
}
