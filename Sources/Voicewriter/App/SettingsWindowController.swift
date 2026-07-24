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
        modelDownloader: ModelDownloader,
        onCancelShortcutChanged: @escaping () -> Void = {}
    ) {
        let rootView = SettingsView(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            modelDownloader: modelDownloader,
            onCancelShortcutChanged: onCancelShortcutChanged
        )
        let hosting = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Voicewriter 設定"
        // .resizableを付けないと、タブ切替でコンテンツがウィンドウ高さを超えた際に
        // ユーザー側で広げる手段が無くなり、上下が見切れたまま固定されてしまう
        // (実際に発生した不具合: 音声認識タブでラジオボタン群やVADセクションが見切れる)。
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // タブ内のコンテンツをこれ以上小さくすると、ScrollViewで包んでいても
        // ラベルや長いパス表示が窮屈になるための下限。
        window.minSize = NSSize(width: 560, height: 480)
        window.setContentSize(NSSize(width: 560, height: 560))
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
