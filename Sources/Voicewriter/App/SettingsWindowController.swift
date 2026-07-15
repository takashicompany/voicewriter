import AppKit
import SwiftUI

/// 設定ウィンドウを管理する。
/// このアプリは`LSUIElement=true`(Dockアイコン無し)のため、ウィンドウを表示するたびに
/// `NSApp.activate` + `makeKeyAndOrderFront` で明示的に前面化しないと、他アプリの裏に隠れたままになる。
@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        audioEngine: AudioCaptureEngine,
        transcriptionEngine: DynamicTranscriptionEngine,
        onCancelShortcutChanged: @escaping () -> Void = {}
    ) {
        let rootView = SettingsView(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            onCancelShortcutChanged: onCancelShortcutChanged
        )
        let hosting = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Voicewriter 設定"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // ウィンドウを閉じても破棄せず、次回「設定...」選択時に同じインスタンスを再表示する。
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// ウィンドウを表示し、前面化する。
    func showAndActivate() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
