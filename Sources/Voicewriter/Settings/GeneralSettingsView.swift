import SwiftUI

/// 一般タブ: ログイン時に起動するかどうか(SMAppService)、状態表示HUD・効果音のON/OFF。
struct GeneralSettingsView: View {
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var errorMessage: String?

    @AppStorage(SettingsKey.hudEnabled) private var hudEnabled: Bool = true
    @AppStorage(SettingsKey.soundEffectsEnabled) private var soundEffectsEnabled: Bool = true

    var body: some View {
        Form {
            Section {
                Toggle("ログイン時に起動", isOn: $launchAtLoginEnabled)
                    .onChange(of: launchAtLoginEnabled) { _, newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            errorMessage = nil
                        } catch {
                            errorMessage = "変更に失敗しました: \(error.localizedDescription)"
                            launchAtLoginEnabled = LaunchAtLogin.isEnabled
                        }
                    }

                Text(LaunchAtLogin.statusDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("状態表示HUDを表示", isOn: $hudEnabled)
                Text("画面下部中央に、録音中・認識/整形中・挿入完了などの状態を小さなパネルで表示します。フォーカスは奪いません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("効果音を鳴らす", isOn: $soundEffectsEnabled)
                Text("録音開始時・テキスト挿入完了時に控えめな効果音を鳴らします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }
}
