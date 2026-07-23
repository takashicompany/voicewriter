import Foundation

/// ユーザー辞書(置換ルール)をテキストへ適用する純粋関数群。ネットワークI/O・ファイルI/Oを
/// 含まないため単体テストしやすいよう分離している(`FormattingPrompt`と同じ方針)。
enum UserDictionaryReplacer {
    /// 有効なルールを、渡された順(=リスト上から下)に単純な文字列置換(`String.replacingOccurrences`)
    /// として適用する。最長一致や単語境界の考慮は行わない(仕様通りシンプルな置換)。
    /// 大文字小文字は区別する。
    ///
    /// 各ルールは直前のルールまでの適用結果に対して適用される(チェーン適用)ため、例えば
    /// 「A→B」「B→C」の2ルールがこの順で登録されていれば、最終的に"A"は"C"になる。
    ///
    /// - `from`が空文字のルールは無視する(空文字への`replacingOccurrences`は意味を持たない/
    ///   無限に一致してしまう操作のため、安全側でスキップする)。
    /// - `isEnabled == false`のルールは無視する。
    static func apply(_ rules: [UserDictionaryRule], to text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            guard rule.isEnabled, !rule.from.isEmpty else { continue }
            result = result.replacingOccurrences(of: rule.from, with: rule.to)
        }
        return result
    }
}
