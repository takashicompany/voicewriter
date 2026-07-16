import Foundation

/// 音声認識結果(whisper.cppの生出力)に対するLLM整形の抽象。
///
/// 実装は「フォーマッタ」であり「書き換え者」ではないという制約を守る必要がある
/// (誤字修正・句読点補完・フィラー除去のみ許可、要約・言い換え・翻訳・入力への応答は禁止)。
/// 呼び出し側(`Coordinator`)は`format`が投げるエラーを捕捉し、**必ず**整形前の原文へ
/// フォールバックすること。この関数自体はフォールバックを行わない(責務を呼び出し側に寄せることで、
/// 「フォーマッタ失敗時は原文を使う」というポリシーを`Coordinator`側の1箇所に集約している)。
protocol TextFormatter: Sendable {
    /// - Parameters:
    ///   - text: 整形対象のテキスト(whisper.cppの生出力)。
    ///   - vocabularyHint: `Settings.sttVocabularyHint`と同じ値を渡す想定の語彙ヒント
    ///     (固有名詞・専門用語のカンマ区切り)。空文字なら無視してよい。
    ///   - model: 使用するOllamaモデル名。呼び出しごとに渡す(ジョブの録音時点の設定スナップショットを
    ///     使うため。待ち行列中に設定画面からモデルが変更されても、既に録音済みのジョブは
    ///     録音時点のモデルのまま処理されるべきため、実装側は`Settings.formattingModel`を
    ///     直接読まずこの引数を使うこと)。
    ///   - timeoutSeconds: リクエストのタイムアウト秒数。同様に呼び出しごとに渡す(実装側は
    ///     `Settings.formattingTimeoutSeconds`を直接読まずこの引数を使うこと。Codexレビュー
    ///     指摘#8: 待ち行列中の設定変更が既に録音済みのジョブにも影響してしまうのを防ぐため)。
    /// - Returns: 整形済みテキスト。
    /// - Throws: `TextFormatterError`(またはその他のエラー)。呼び出し側は必ず原文へフォールバックすること。
    func format(text: String, vocabularyHint: String, model: String, timeoutSeconds: TimeInterval) async throws -> String
}

enum TextFormatterError: Error, CustomStringConvertible {
    /// 整形対象が空文字だった。
    case emptyInput
    /// Ollamaサーバーへ到達できなかった(未起動・接続エラー等)。
    case serverUnavailable(String)
    /// 指定時間内に応答が得られなかった。
    case timeout
    /// レスポンスのJSON形式が想定と異なる。
    case invalidResponse(String)
    /// レスポンスは得られたが`<formatted_text>`タグが無い、または中身が空だった。
    case missingOrEmptyTag

    var description: String {
        switch self {
        case .emptyInput:
            return "整形対象のテキストが空です"
        case .serverUnavailable(let detail):
            return "Ollamaサーバーに接続できませんでした: \(detail)"
        case .timeout:
            return "整形リクエストがタイムアウトしました"
        case .invalidResponse(let detail):
            return "整形結果の解析に失敗しました: \(detail)"
        case .missingOrEmptyTag:
            return "整形結果に<formatted_text>タグが無いか、中身が空でした"
        }
    }
}
