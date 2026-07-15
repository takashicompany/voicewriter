import ApplicationServices
import os.log

/// アクセシビリティ権限(AXIsProcessTrusted)の確認・要求をまとめる。
/// CGEventでのキーイベント合成にはこの権限が必要。
enum AccessibilityPermission {
    private static let log = Logger(subsystem: "dev.voicewriter.app", category: "AccessibilityPermission")

    /// 現在アクセシビリティ権限が許可されているか(プロンプトは出さない)
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 起動時に呼ぶ。未許可の場合、`promptIfNeeded`がtrueならシステムのアクセシビリティ許可プロンプトを表示する。
    /// - Returns: 呼び出し時点でtrustedだったかどうか(プロンプト表示直後はまだfalseであることが多い。
    ///   ユーザーが許可した後は次回起動時などにtrueへ切り替わる)。
    @discardableResult
    static func ensureTrusted(promptIfNeeded: Bool) -> Bool {
        let optionsKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [optionsKey: promptIfNeeded] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log.info("Accessibility trusted=\(trusted, privacy: .public) (promptIfNeeded=\(promptIfNeeded, privacy: .public))")
        return trusted
    }
}
