import Foundation

/// 文字起こしエンジンの抽象。将来whisper.cpp(large-v3-turbo)実装に差し替える。
protocol TranscriptionEngine {
    /// 16kHz/mono/Float32のPCMサンプルを受け取り、文字起こし結果を返す。
    ///
    /// - Parameters:
    ///   - language: "ja"等のISO 639-1言語コード、または自動判定の"auto"。呼び出しごとに渡す
    ///     (連続音声入力パイプラインでは、ジョブが録音開始時点の設定スナップショットを保持しており、
    ///     待ち行列中に設定画面から言語が変更されても、既に録音済みのジョブは録音時点の言語で
    ///     処理されるべきため。エンジン内部で`Settings`を直接読まないことで、これを保証する)。
    ///   - vocabularyHint: 固有名詞・専門用語のヒント(`initial_prompt`相当)。同様に呼び出しごとに渡す。
    ///   - vadEnabled: VAD(Voice Activity Detection)を有効にするか。同様に呼び出しごとに渡す
    ///     (ジョブの録音時点の設定スナップショットを使うため。待ち行列中に設定画面からVADの
    ///     有効/無効が変更されても、既に録音済みのジョブは録音時点の設定のまま処理されるべき
    ///     ため、実装側は`Settings.vadEnabled`を直接読まずこの引数を使うこと)。
    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String
}

enum TranscriptionError: Error {
    case emptyAudio
}
