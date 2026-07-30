import XCTest
import VoicewriterObjC

/// `VWCatchException`(SwiftからObjCの`NSException`を捕捉するためのヘルパー)の回帰テスト。
///
/// 背景: AVFoundationは`installTapOnBus`の事前条件違反で`NSException`をraiseする。
/// SwiftのdoやcatchではObjC例外を捕まえられず、Swift側の検証をすり抜けた場合は
/// プロセスがabort(SIGABRT)して起動時クラッシュになっていた(2026-07-30)。
final class ObjCExceptionCatcherTests: XCTestCase {
    func testReturnsTrueAndRunsBlockWhenNoExceptionIsRaised() {
        var didRun = false
        var error: NSError?
        let ok = VWCatchException({ didRun = true }, &error)
        XCTAssertTrue(ok)
        XCTAssertTrue(didRun)
        XCTAssertNil(error)
    }

    func testCatchesObjCExceptionAndReportsNameAndReason() {
        var error: NSError?
        let ok = VWCatchException({
            NSException(
                name: NSExceptionName("com.apple.coreaudio.avfaudio"),
                reason: "required condition is false: format.sampleRate == inputHWFormat.sampleRate",
                userInfo: nil
            ).raise()
        }, &error)

        XCTAssertFalse(ok)
        XCTAssertNotNil(error)
        XCTAssertEqual(error?.domain, VWExceptionCatcherErrorDomain)
        XCTAssertEqual(error?.userInfo[VWExceptionCatcherNameKey] as? String, "com.apple.coreaudio.avfaudio")
        XCTAssertEqual(
            error?.userInfo[VWExceptionCatcherReasonKey] as? String,
            "required condition is false: format.sampleRate == inputHWFormat.sampleRate"
        )
        // ログに出す文字列としてそのまま使えること。
        XCTAssertTrue(error?.localizedDescription.contains("inputHWFormat") ?? false)
    }

    func testDoesNotCrashWhenErrorPointerIsNil() {
        let ok = VWCatchException({
            NSException(name: NSExceptionName("Test"), reason: nil, userInfo: nil).raise()
        }, nil)
        XCTAssertFalse(ok)
    }

    func testSideEffectsBeforeTheExceptionAreObservable() {
        // 例外を投げるブロック内で、投げる前に行った処理は反映されている
        // (=タップ設置の途中で例外が出た場合の後片付けを呼び出し側で行える)。
        var progress = 0
        let ok = VWCatchException({
            progress = 1
            NSException(name: NSExceptionName("Test"), reason: "boom", userInfo: nil).raise()
            progress = 2
        }, nil)
        XCTAssertFalse(ok)
        XCTAssertEqual(progress, 1)
    }
}
