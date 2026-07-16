import XCTest
@testable import Voicewriter

private enum FakePasteError: Error { case boom }

/// `TextInserter.insert(text:onPasted:)`(共有プロパティの`onPasted`をやめ、コール単位の引数に
/// 変更した)の回帰テスト。
///
/// 修正前は`onPasted`がインスタンス共有のプロパティだったため、複数の挿入呼び出しが重なると
/// (連続音声入力パイプラインでは普通に起こりうる)、後から設定した`onPasted`が先行する呼び出しの
/// 完了通知まで乗っ取ってしまう競合があった。この回帰テストでは、実際のアクセシビリティ権限・
/// CGEvent送出には依存しない差し替え可能なフック(`isAccessibilityTrusted`/`sendCommandV`)を使い、
/// 複数の呼び出しそれぞれが自分自身の`onPasted`だけを正しく受け取ることを確認する。
@MainActor
final class TextInserterTests: XCTestCase {
    func testOnPastedIsCallPerCallNotSharedAcrossOverlappingInserts() async throws {
        var sentTexts: [String] = []
        let inserter = TextInserter(
            isAccessibilityTrusted: { true },
            sendCommandV: { }
        )
        inserter.restoreDelaySeconds = 0

        var firstPastedCallCount = 0
        var secondPastedCallCount = 0

        let firstTask = Task { @MainActor in
            try await inserter.insert(text: "first") {
                firstPastedCallCount += 1
                sentTexts.append("first")
            }
        }
        let secondTask = Task { @MainActor in
            try await inserter.insert(text: "second") {
                secondPastedCallCount += 1
                sentTexts.append("second")
            }
        }

        try await firstTask.value
        try await secondTask.value

        XCTAssertEqual(firstPastedCallCount, 1, "1回目のonPastedはちょうど1回だけ呼ばれるべき")
        XCTAssertEqual(secondPastedCallCount, 1, "2回目のonPastedはちょうど1回だけ呼ばれるべき")
        XCTAssertEqual(sentTexts, ["first", "second"], "呼び出し順(=insert()を呼んだ順)で直列に処理されるべき")
    }

    func testInsertThrowsWhenAccessibilityNotTrustedAndDoesNotCallOnPasted() async {
        let inserter = TextInserter(isAccessibilityTrusted: { false })

        var onPastedCallCount = 0
        do {
            try await inserter.insert(text: "hello") { onPastedCallCount += 1 }
            XCTFail("Expected accessibilityNotTrusted error")
        } catch TextInsertionError.accessibilityNotTrusted {
            // expected
        } catch {
            XCTFail("Expected TextInsertionError.accessibilityNotTrusted, got \(error)")
        }
        XCTAssertEqual(onPastedCallCount, 0)
    }

    func testInsertPropagatesSendCommandVFailureWithoutCallingOnPasted() async {
        let inserter = TextInserter(
            isAccessibilityTrusted: { true },
            sendCommandV: { throw FakePasteError.boom }
        )

        var onPastedCallCount = 0
        do {
            try await inserter.insert(text: "hello") { onPastedCallCount += 1 }
            XCTFail("Expected FakePasteError.boom")
        } catch FakePasteError.boom {
            // expected
        } catch {
            XCTFail("Expected FakePasteError.boom, got \(error)")
        }
        XCTAssertEqual(onPastedCallCount, 0, "Cmd+V送出自体が失敗した場合はonPastedを呼ぶべきではない")
    }

    func testEmptyTextDoesNotCallSendCommandVOrOnPasted() async throws {
        var sendCommandVCallCount = 0
        let inserter = TextInserter(
            isAccessibilityTrusted: { true },
            sendCommandV: { sendCommandVCallCount += 1 }
        )
        var onPastedCallCount = 0
        try await inserter.insert(text: "") { onPastedCallCount += 1 }
        XCTAssertEqual(sendCommandVCallCount, 0)
        XCTAssertEqual(onPastedCallCount, 0)
    }
}
