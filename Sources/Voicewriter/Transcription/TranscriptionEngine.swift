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

/// 内部で実エンジン(whisper.cpp/stub)を差し替え可能なラッパー(`DynamicTranscriptionEngine`)が、
/// 「ある時点で実際に使われていた実エンジンそのもの」への参照を外部へ渡すための小さなプロトコル。
///
/// `Coordinator`は録音開始時点でこれを通じて実エンジンの参照を捕捉し、`DictationJob`へ焼き付ける。
/// こうすることで、待ち行列中(録音済み・認識待ち)に設定画面/メニューバーからエンジン種別
/// (whisper.cpp / SpeechAnalyzer / stub)が切り替わり`DynamicTranscriptionEngine.reload()`が
/// 呼ばれても、既に録音済みのジョブは録音時点に実際に使われていた実エンジンのインスタンスで
/// 処理され続ける(バグ修正: whisperジョブが待機中にSpeechAnalyzerへ切替されると、reload後の
/// `DynamicTranscriptionEngine`内部エンジンがプレースホルダーの`StubTranscriptionEngine`に
/// 差し替わってしまい、待機中のwhisperジョブまでダミーテキストで処理されてしまっていた)。
///
/// `DynamicTranscriptionEngine`以外(テスト用フェイク等、`reload()`により内部エンジンが
/// 差し替わることのない実装)はこれに準拠する必要はない。呼び出し元は`as?`でのダウンキャストが
/// 失敗した場合、渡された`TranscriptionEngine`自体をそのまま使う。
protocol TranscriptionEngineSnapshotProviding {
    /// 呼び出し時点で実際に使われている実エンジンをそのまま返す(差し替えは行わない、読み取り専用)。
    func currentEngineSnapshot() -> TranscriptionEngine
}

enum TranscriptionError: Error, LocalizedError {
    case emptyAudio
    /// `SpeechAnalyzerStreamingPlaceholderTranscriptionEngine`が実際に呼ばれてしまった
    /// (=ストリーミングセッションが使われるはずの録音がバッチ経路に落ちた)ことを示す。
    /// 詳細は`SpeechAnalyzerStreamingPlaceholderTranscriptionEngine`のドキュメント参照。
    case streamingPlaceholderInvokedUnexpectedly

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "音声データが空でした"
        case .streamingPlaceholderInvokedUnexpectedly:
            return "SpeechAnalyzerストリーミングモードのプレースホルダーエンジンが予期せず呼ばれました(ストリーミングセッションが利用できなかった可能性があります)"
        }
    }
}
