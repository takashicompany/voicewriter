import Foundation
import os.log

/// ユーザー辞書(置換ルール)の永続化ストア。
///
/// `~/Library/Application Support/Voicewriter/dictionary.json` に人間が読める整形JSONで保存する
/// (UserDefaultsではなくファイルにしているのは、手編集・バックアップ・将来の共有を考慮したもの)。
/// 読み書きはアトミック(一時ファイルへ書いてから`rename`/`replaceItemAt`)で行い、書き込み途中の
/// クラッシュ・強制終了で壊れたファイルが残らないようにする。破損したJSON(パース失敗)を
/// 読み込んだ場合は空辞書として起動し、警告ログを出す(壊れたファイル自体はここでは上書きせず、
/// 次にユーザーが明示的に編集して保存するまでそのまま残す。誤って調査価値のあるファイルを
/// 消してしまわないため)。
///
/// `@MainActor`のObservableObjectとして実装しており(`ModelDownloader`と同じ方針)、設定画面の
/// 辞書タブがそのまま`@Published`を購読して即時反映できる。`DictationJobSettingsSnapshot
/// .captureCurrent()`(`Coordinator`、常にMainActor上で呼ばれる)から同期的に`dictionary`を読み、
/// 録音開始時点のスナップショットへ含める(処理中の辞書編集が進行中ジョブへ影響しないようにするため)。
@MainActor
final class UserDictionaryStore: ObservableObject {
    /// アプリ全体で共有する単一インスタンス。`Coordinator`(ジョブのスナップショット取得)と
    /// 設定画面の辞書タブの両方がこれを参照する。
    static let shared = UserDictionaryStore()

    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Voicewriter/dictionary.json", isDirectory: false)
    }

    /// 保存先。テストから一時ファイルへ差し替えられるよう`init`で注入可能にしている。
    let fileURL: URL

    private let log = Logger(subsystem: "dev.voicewriter.app", category: "UserDictionaryStore")

    @Published private(set) var dictionary: UserDictionary

    init(fileURL: URL = UserDictionaryStore.defaultFileURL) {
        self.fileURL = fileURL
        self.dictionary = Self.loadFromDisk(fileURL: fileURL)
    }

    /// ディスクから読み直す(通常のアプリ実行では不要だが、テストや将来の外部編集検知用に公開する)。
    func reload() {
        dictionary = Self.loadFromDisk(fileURL: fileURL)
    }

    /// ルール一覧全体を置き換えて即座に保存する。設定画面からの編集はすべてこの経路を通る
    /// (追加・削除・並べ替え・個々のフィールド編集のいずれも、最終的に配列全体を渡す形で呼ぶ)。
    func setRules(_ rules: [UserDictionaryRule]) {
        dictionary = UserDictionary(rules: rules)
        persist()
    }

    /// 空のルールを末尾に1件追加する(`from`/`to`とも空文字。ユーザーが設定画面でその場に入力する)。
    func addRule() {
        setRules(dictionary.rules + [UserDictionaryRule()])
    }

    private func persist() {
        do {
            try Self.writeAtomically(dictionary, to: fileURL)
        } catch {
            log.error("Failed to save dictionary.json: \(String(describing: error), privacy: .public)")
        }
    }

    private static func loadFromDisk(fileURL: URL) -> UserDictionary {
        let log = Logger(subsystem: "dev.voicewriter.app", category: "UserDictionaryStore")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return UserDictionary()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(UserDictionary.self, from: data)
        } catch {
            log.warning("dictionary.json is missing or corrupted; starting with an empty dictionary: \(String(describing: error), privacy: .public)")
            return UserDictionary()
        }
    }

    /// アトミック書き込み(一時ファイルへ書いてから`rename`/`replaceItemAt`)。単体テストからも
    /// 直接呼べるよう`static`にしている。
    static func writeAtomically(_ dictionary: UserDictionary, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(dictionary)

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            // 同一ディレクトリ内の`replaceItemAt`はrename(2)相当で行われ、途中状態が外部から
            // 観測されない(既存ファイルをアトミックに置き換える)。
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        }
    }
}
