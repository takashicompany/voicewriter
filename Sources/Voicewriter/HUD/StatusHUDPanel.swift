import AppKit

/// フォーカスを一切奪わない浮遊HUDパネル。
///
/// - `styleMask`に`.nonactivatingPanel`を指定し、かつ`canBecomeKey`/`canBecomeMain`を
///   常に`false`にオーバーライドすることで、`orderFront`してもキーウィンドウ/メインウィンドウに
///   絶対にならない(=前面化しても他アプリのテキストカーソル・キーボードフォーカスを奪わない)。
/// - `ignoresMouseEvents = true`により、クリック等のマウスイベントも一切受け取らず素通しする。
/// - `level = .statusBar`、`collectionBehavior`に`.canJoinAllSpaces`/`.fullScreenAuxiliary`を
///   指定し、Spaceを跨いでも・フルスクリーンアプリの上でも表示され続けるようにする。
final class StatusHUDPanel: NSPanel {
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
        // 起動直後から一切表示しない(idle時は完全に非表示、という要件をコードレベルでも保証する)。
        orderOut(nil)
    }
}
