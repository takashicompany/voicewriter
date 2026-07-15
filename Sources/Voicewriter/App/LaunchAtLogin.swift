import Foundation
import ServiceManagement

/// ログイン時起動の登録/解除。`SMAppService`(macOS 13+)を使用する。
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return "状態: 未登録"
        case .enabled:
            return "状態: 有効(ログイン時に自動起動します)"
        case .requiresApproval:
            return "状態: システム設定 > 一般 > ログイン項目 での承認が必要です"
        case .notFound:
            return "状態: 見つかりません"
        @unknown default:
            return "状態: 不明"
        }
    }
}
