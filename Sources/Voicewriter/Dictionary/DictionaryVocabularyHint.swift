import Foundation

/// ユーザー辞書の置換先(`to`)語彙を、既存の語彙ヒント(`Settings.sttVocabularyHint`)へ
/// 自動的に追加するための純粋関数。
///
/// whisper.cppの`initial_prompt`とLLM整形プロンプトの語彙注入は、いずれも
/// `DictationJobSettingsSnapshot.vocabularyHint`という単一のフィールドを経由する
/// (`Coordinator.runJob`が同じ値を`TranscriptionEngine.transcribe`と`TextFormatter.format`の
/// 両方へそのまま渡す)ため、`DictationJobSettingsSnapshot.captureCurrent()`でこのマージを
/// 一度だけ行えば両方に反映される。
enum DictionaryVocabularyHint {
    /// 辞書側から語彙ヒントへ追加する語数の上限。ヒント全体が長くなりすぎてデコーダの文脈を
    /// 圧迫しないようにするための安全策(概ね20語程度で実用上十分という想定のハードコード)。
    static let maxDictionaryWords = 20

    /// - Parameters:
    ///   - baseHint: 既存の語彙ヒント(`Settings.sttVocabularyHint`)。カンマ区切り想定。
    ///   - rules: ユーザー辞書のルール一覧(有効/無効・順序は問わず全件渡してよい)。
    /// - Returns: `baseHint`の末尾に、有効な置換先(`to`)のうちユニークかつ`baseHint`に
    ///   まだ含まれていない語を、登録順で先頭から`maxDictionaryWords`件までカンマ区切りで
    ///   追加した文字列。追加すべき語が無ければ`baseHint`をそのまま返す。
    static func merge(baseHint: String, rules: [UserDictionaryRule]) -> String {
        let existingTerms = Set(
            baseHint
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        var seen = existingTerms
        var additions: [String] = []
        for rule in rules {
            guard rule.isEnabled else { continue }
            let term = rule.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !seen.contains(term) else { continue }
            seen.insert(term)
            additions.append(term)
            if additions.count >= maxDictionaryWords { break }
        }

        guard !additions.isEmpty else { return baseHint }

        let trimmedBase = baseHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let additionsJoined = additions.joined(separator: ", ")
        return trimmedBase.isEmpty ? additionsJoined : "\(trimmedBase), \(additionsJoined)"
    }
}
