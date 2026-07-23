import Foundation

/// ユーザー辞書の1エントリ(置換ルール)。
///
/// 音声認識・LLM整形の結果テキストに対し、挿入直前に「置換元(`from`)→置換先(`to`)」を
/// 適用する。誤認識の確定修正(例:「ボイスライダー」→「Voicewriter」)や、専門用語・固有名詞の
/// 表記統一に使う(Amicalの同種機能を参考にした独立レイヤー、詳細はREADME参照)。
///
/// `from`が空文字のルールは`UserDictionaryReplacer`が無視する(「空不可」制約は型では強制せず、
/// 実質的な無害化という形で担保している。設定画面で行を追加した直後や編集中の一時的な空文字を
/// 弾く必要がないため)。
struct UserDictionaryRule: Codable, Equatable, Identifiable, Sendable {
    var from: String
    var to: String
    var isEnabled: Bool
    var id: UUID

    init(from: String = "", to: String = "", isEnabled: Bool = true, id: UUID = UUID()) {
        self.from = from
        self.to = to
        self.isEnabled = isEnabled
        self.id = id
    }
}

/// `dictionary.json`のトップレベル構造。将来のフォーマットバージョニングの余地を残すため、
/// 配列そのものではなくオブジェクトでラップしている。
struct UserDictionary: Codable, Equatable, Sendable {
    var rules: [UserDictionaryRule]

    init(rules: [UserDictionaryRule] = []) {
        self.rules = rules
    }
}
