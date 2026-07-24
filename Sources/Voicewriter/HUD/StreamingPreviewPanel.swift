import AppKit

/// SpeechAnalyzerストリーミングモードのライブプレビュー(確定+未確定テキスト)を表示する、
/// フォーカスを一切奪わない浮遊パネル。既存の`StatusHUDPanel`と同一の設計方針
/// (`.nonactivatingPanel`、`canBecomeKey`/`canBecomeMain`を常にfalse、マウスイベント素通し)を
/// 踏襲した、状態表示HUDとは独立の別パネル。
final class StreamingPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentSize: NSSize) {
        let contentRect = NSRect(origin: .zero, size: contentSize)
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        alphaValue = 0
        orderOut(nil)
    }
}
