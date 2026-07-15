import SwiftUI

/// 設定ウィンドウのルートビュー。マイク/ショートカット/音声認識/一般の4タブで構成する。
struct SettingsView: View {
    let audioEngine: AudioCaptureEngine
    @ObservedObject var transcriptionEngine: DynamicTranscriptionEngine
    /// キャンセルショートカットが設定画面で再割当てされた直後に呼ばれる(`ShortcutsSettingsView`参照)。
    var onCancelShortcutChanged: () -> Void = {}

    var body: some View {
        TabView {
            MicSettingsView(audioEngine: audioEngine)
                .tabItem { Label("マイク", systemImage: "mic") }

            ShortcutsSettingsView(onCancelShortcutChanged: onCancelShortcutChanged)
                .tabItem { Label("ショートカット", systemImage: "keyboard") }

            TranscriptionSettingsView(transcriptionEngine: transcriptionEngine)
                .tabItem { Label("音声認識", systemImage: "waveform") }

            FormattingSettingsView()
                .tabItem { Label("整形", systemImage: "wand.and.stars") }

            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 420)
    }
}
