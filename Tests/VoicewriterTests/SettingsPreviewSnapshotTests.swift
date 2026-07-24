import AppKit
import SwiftUI
import XCTest
@testable import Voicewriter

/// 設定ウィンドウのレイアウト崩れ修正の視覚検証用テスト。
///
/// サンドボックス化されたテスト実行環境では`screencapture`がパーミッション不足で使えないため、
/// 各タブのビューをオフスクリーン(画面外に表示はするがalphaValue: 0で不可視)の`NSWindow`へ
/// 実際に載せてレンダリングし、`assets/settings-previews/`へPNGとして書き出す
/// (試行錯誤の経緯は`render(_:name:assertExactSize:size:)`のコメント参照)。
/// 人間が目視確認できるようにすることが主目的で、あわせて出力画像の寸法が想定通りであることも
/// 機械的にチェックする(将来この寸法が大きく変わった場合に気づけるように)。
@MainActor
final class SettingsPreviewSnapshotTests: XCTestCase {
    /// `SettingsWindowController`が設定するウィンドウの初期コンテンツサイズ(560x560)に合わせる。
    private let previewSize = CGSize(width: 560, height: 560)

    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/VoicewriterTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // リポジトリルート
            .appendingPathComponent("assets/settings-previews", isDirectory: true)
    }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    @discardableResult
    private func render<V: View>(_ view: V, name: String, assertExactSize: Bool = true, size: CGSize? = nil) throws -> NSImage {
        let previewSize = size ?? self.previewSize
        // 試行錯誤の経緯:
        // 1) `ImageRenderer.nsImage`を生成直後に同期的に読むと、SwiftUI側のレイアウト/描画パスが
        //    まだ1回も回っておらず真っ白画像になった。
        // 2) `NSHostingView` + `cacheDisplay`系のクラシックAPIだと、明示的に色指定した要素だけ写り、
        //    通常のTextラベル(system色に依存)が透明/白抜けになった。
        // 3) `NSHostingView`のCALayerを`render(in:)`で直接CGContextへ転写すると、SwiftUIの実描画は
        //    Core Animationのプライベートな合成系に乗っており単純なlayer treeの再生では拾えず、
        //    真っ黒(未初期化のバッキングストア)になった。
        // → 実機で確実に動くのは、`NSWindow`へ実際に載せて`window.contentView`を確定させ、
        //   `displayIfNeeded()`後に`bitmapImageRepForCachingDisplay`/`cacheDisplay`で
        //   ウィンドウの描画結果をそのまま転写する方法。ウィンドウ自体は画面外(alphaValue: 0)に
        //   出すため、ユーザーには見えない。
        let hostingView = NSHostingView(rootView: view.environment(\.colorScheme, .light).frame(width: previewSize.width, height: previewSize.height))
        hostingView.frame = CGRect(origin: .zero, size: previewSize)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: previewSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = hostingView
        window.orderFrontRegardless()

        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // 初回の`displayIfNeeded`だけでは非同期に生成される状態(`.task`/`@StateObject`初期化など)が
        // 反映しきらないことがあるため、runloopを少し回してからもう一度確定させる。
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        defer { window.close() }

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("\(name): bitmapImageRepForCachingDisplayに失敗しました")
            return NSImage()
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("\(name): PNGへのエンコードに失敗しました")
            return NSImage()
        }

        let url = outputDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)

        let nsImage = NSImage(size: previewSize)
        nsImage.addRepresentation(bitmap)

        if assertExactSize {
            // レイアウト崩れ(意図しない幅/高さの拡大縮小)の機械的な回帰検知。
            XCTAssertEqual(Int(bitmap.size.width.rounded()), Int(previewSize.width), "\(name): 幅が想定(\(previewSize.width))と異なる")
            XCTAssertEqual(Int(bitmap.size.height.rounded()), Int(previewSize.height), "\(name): 高さが想定(\(previewSize.height))と異なる")
        }
        return nsImage
    }

    func testMicSettingsPreview() throws {
        try render(MicSettingsView(audioEngine: AudioCaptureEngine()), name: "01-mic")
    }

    func testShortcutsSettingsPreview() throws {
        try render(ShortcutsSettingsView(), name: "02-shortcuts")
    }

    func testTranscriptionSettingsPreview() throws {
        try render(
            TranscriptionSettingsView(
                transcriptionEngine: DynamicTranscriptionEngine(),
                downloader: ModelDownloader()
            ),
            name: "03-transcription"
        )
    }

    /// `SettingsWindowController`が課す`window.minSize`(560x480)まで縮めた最も厳しい条件での確認。
    /// 音声認識タブが全タブ中もっとも縦に長いため、ここで「はみ出さずスクロールで収まる」ことを
    /// 目視確認する(修正前は固定サイズかつ非リサイズだったため、この状態で上下端が見切れていた)。
    func testTranscriptionSettingsPreviewAtMinimumWindowSize() throws {
        try render(
            TranscriptionSettingsView(
                transcriptionEngine: DynamicTranscriptionEngine(),
                downloader: ModelDownloader()
            ),
            name: "03b-transcription-min-size",
            assertExactSize: false,
            size: CGSize(width: 560, height: 480)
        )
    }

    func testFormattingSettingsPreview() throws {
        try render(FormattingSettingsView(), name: "04-formatting")
    }

    func testDictionarySettingsPreview() throws {
        try render(DictionarySettingsView(), name: "05-dictionary")
    }

    func testGeneralSettingsPreview() throws {
        try render(GeneralSettingsView(), name: "06-general")
    }

    /// タブバー込みの全体像(タブ切替でタブバー自体が見切れる不具合が無いこと)の確認用。
    /// `TabView`はウィンドウ枠のクロームぶんだけ`SettingsView`側の`.frame`指定より
    /// 実際の描画が縦に伸びうるため、寸法の厳密一致は求めない(目視確認が目的)。
    func testFullSettingsWindowPreview() throws {
        try render(
            SettingsView(
                audioEngine: AudioCaptureEngine(),
                transcriptionEngine: DynamicTranscriptionEngine(),
                modelDownloader: ModelDownloader()
            ),
            name: "00-full-settings-window",
            assertExactSize: false
        )
    }
}
