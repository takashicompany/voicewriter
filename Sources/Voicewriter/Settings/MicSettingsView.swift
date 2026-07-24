import SwiftUI

/// マイクタブ: 動作モード(常時オープン/必要時のみ)・プリロール秒数・リングバッファ秒数。
/// `@AppStorage`はSettings.swiftと同じキー・同じUserDefaults(標準ドメイン)を参照するため、
/// ここでの変更は`Settings.micMode`等からもすぐに読み取れる(単一の設定値ソース)。
struct MicSettingsView: View {
    let audioEngine: AudioCaptureEngine

    @AppStorage(SettingsKey.micMode) private var micMode: MicMode = .alwaysOn
    @AppStorage(SettingsKey.prerollSeconds) private var prerollSeconds: Double = 0.5
    @AppStorage(SettingsKey.ringBufferSeconds) private var ringBufferSeconds: Double = 3.0
    @AppStorage(SettingsKey.onDemandIdleTimeoutSeconds) private var onDemandIdleTimeoutSeconds: Double = 5.0

    var body: some View {
        // ウィンドウ高さより内容が長くなった場合でも見切れないよう、タブ内をScrollViewで包む。
        ScrollView {
        Form {
            Section {
                Picker("マイクモード", selection: $micMode) {
                    Text("常時オープン").tag(MicMode.alwaysOn)
                    Text("必要時のみ").tag(MicMode.onDemand)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: micMode) { _, _ in
                    audioEngine.applyMicModeChange()
                }

                Text(explanationText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("プリロール秒数: \(String(format: "%.1f", prerollSeconds))秒")
                    Slider(value: $prerollSeconds, in: 0...2, step: 0.1)
                        .disabled(micMode != .alwaysOn)
                    Text("録音開始の合図より前の音声を、常時オープン時のリングバッファから遡って含める長さです。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("リングバッファ秒数: \(String(format: "%.1f", ringBufferSeconds))秒")
                    Slider(value: $ringBufferSeconds, in: 1...10, step: 0.5)
                        .onChange(of: ringBufferSeconds) { _, _ in
                            audioEngine.applyRingBufferSecondsChange()
                        }
                    Text("常時オープン時に直近何秒分の音声を保持しておくか(プリロールの上限)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("マイクオフまでの秒数: \(String(format: "%.0f", onDemandIdleTimeoutSeconds))秒")
                    Slider(value: $onDemandIdleTimeoutSeconds, in: 2...30, step: 1)
                        .disabled(micMode != .onDemand)
                    Text("必要時のみモードで、録音終了後にマイクをオフにするまでのアイドル秒数です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        }
    }

    private var explanationText: String {
        switch micMode {
        case .alwaysOn:
            return "押した瞬間から録音でき、直前の声も含められます。マイク使用中インジケータが常時点灯します。"
        case .onDemand:
            return "録音開始命令が来てからマイクを起動します。マイク使用中インジケータは録音中のみ点灯しますが、押してから録音開始までにわずかな遅延が生じます。"
        }
    }
}
