import XCTest
@testable import Voicewriter

/// `UserDictionaryStore`(ユーザー辞書のファイル永続化)の単体テスト。
/// `UserDictionaryStore.shared`(アプリ内シングルトン、既定の実ファイルパス)とは独立に、
/// 一時ディレクトリ内のファイルを指す専用インスタンスを都度生成してテストする。
@MainActor
final class UserDictionaryStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoicewriterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    private var testFileURL: URL {
        tempDirectory.appendingPathComponent("dictionary.json")
    }

    func testStartsWithEmptyDictionaryWhenFileDoesNotExist() {
        let store = UserDictionaryStore(fileURL: testFileURL)
        XCTAssertTrue(store.dictionary.rules.isEmpty)
    }

    func testSetRulesPersistsToDiskAndCanBeReloaded() {
        let store = UserDictionaryStore(fileURL: testFileURL)
        let rules = [
            UserDictionaryRule(from: "ボイスライダー", to: "Voicewriter"),
            UserDictionaryRule(from: "おらま", to: "Ollama", isEnabled: false),
        ]
        store.setRules(rules)

        XCTAssertTrue(FileManager.default.fileExists(atPath: testFileURL.path))

        let reloaded = UserDictionaryStore(fileURL: testFileURL)
        XCTAssertEqual(reloaded.dictionary.rules.map(\.from), ["ボイスライダー", "おらま"])
        XCTAssertEqual(reloaded.dictionary.rules.map(\.to), ["Voicewriter", "Ollama"])
        XCTAssertEqual(reloaded.dictionary.rules.map(\.isEnabled), [true, false])
    }

    func testWrittenFileIsHumanReadableJson() throws {
        let store = UserDictionaryStore(fileURL: testFileURL)
        store.setRules([UserDictionaryRule(from: "A", to: "B")])

        let data = try Data(contentsOf: testFileURL)
        let text = String(data: data, encoding: .utf8)
        XCTAssertNotNil(text)
        // .prettyPrintedにより改行・インデントが入り、人間が読める整形になっているべき。
        XCTAssertTrue(text!.contains("\n"))
        XCTAssertTrue(text!.contains("\"from\""))
        XCTAssertTrue(text!.contains("\"to\""))
    }

    func testAddRuleAppendsAnEmptyRule() {
        let store = UserDictionaryStore(fileURL: testFileURL)
        store.addRule()
        XCTAssertEqual(store.dictionary.rules.count, 1)
        XCTAssertEqual(store.dictionary.rules[0].from, "")
        XCTAssertEqual(store.dictionary.rules[0].to, "")
        XCTAssertTrue(store.dictionary.rules[0].isEnabled)
    }

    func testCorruptedFileStartsWithEmptyDictionaryAndDoesNotCrash() throws {
        try "{ this is not valid json".write(to: testFileURL, atomically: true, encoding: .utf8)
        let store = UserDictionaryStore(fileURL: testFileURL)
        XCTAssertTrue(store.dictionary.rules.isEmpty, "破損したdictionary.jsonの場合は空辞書で起動するべき")
    }

    func testSavingAfterLoadingFromCorruptedFileOverwritesItWithValidJson() {
        try? "{ broken".write(to: testFileURL, atomically: true, encoding: .utf8)
        let store = UserDictionaryStore(fileURL: testFileURL)
        store.setRules([UserDictionaryRule(from: "X", to: "Y")])

        let reloaded = UserDictionaryStore(fileURL: testFileURL)
        XCTAssertEqual(reloaded.dictionary.rules.map(\.from), ["X"])
    }

    /// アトミック書き込みの回帰確認: `writeAtomically`が返した後、書き込み先には常に有効な
    /// JSONファイルが存在するべき(一時ファイルが残ったままになる、部分書き込みのまま終わる、
    /// といった状態にならないこと)。
    func testWriteAtomicallyLeavesNoStrayTempFiles() throws {
        try UserDictionaryStore.writeAtomically(
            UserDictionary(rules: [UserDictionaryRule(from: "A", to: "B")]),
            to: testFileURL
        )
        try UserDictionaryStore.writeAtomically(
            UserDictionary(rules: [UserDictionaryRule(from: "C", to: "D")]),
            to: testFileURL
        )

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertEqual(contents, ["dictionary.json"], "一時ファイル(.tmp)が残らず、最終ファイルのみが存在するべき")

        let data = try Data(contentsOf: testFileURL)
        let decoded = try JSONDecoder().decode(UserDictionary.self, from: data)
        XCTAssertEqual(decoded.rules.map(\.from), ["C"])
    }
}
