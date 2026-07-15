import KeyboardShortcuts
import SwiftUI

/// ショートカットタブ: PTT/トグル/キャンセルの割当変更UI。
/// `KeyboardShortcuts.Recorder`はライブラリ側で登録・永続化・グローバル監視への反映まで面倒を見るため、
/// ここでは配置するだけでよい(変更は即座に反映される)。
struct ShortcutsSettingsView: View {
    /// キャンセルショートカット(既定Esc)が再割当てされた直後に呼ばれる。
    /// `KeyboardShortcuts.Recorder`の`setShortcut`は無条件にショートカットを有効化(register)して
    /// しまうため、Coordinatorがidle時にdisableしていたキャンセルショートカットが再び有効になって
    /// しまう。ここで`Coordinator.refreshShortcutEnablement()`を呼び直し、現在の状態に基づく
    /// enable/disableを再適用してもらう。
    var onCancelShortcutChanged: () -> Void = {}

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Push-to-Talk:", name: .pushToTalk)
                Text("押している間だけ録音し、離すと文字起こしを開始します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                KeyboardShortcuts.Recorder("トグル:", name: .toggleRecording)
                Text("1回押して録音開始、もう1回押して録音終了・文字起こしを開始します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                KeyboardShortcuts.Recorder("キャンセル:", name: .cancelRecording) { _ in
                    onCancelShortcutChanged()
                }
                Text("録音中のみ有効。押すと録音内容を破棄して待機状態に戻ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
