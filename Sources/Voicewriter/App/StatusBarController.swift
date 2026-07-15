import AppKit

/// メニューバーアイコンとメニュー(録音状態表示 / 設定プレースホルダ / 終了)を管理する。
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let stateMenuItem: NSMenuItem
    private let settingsMenuItem: NSMenuItem
    private let copyLastResultMenuItem: NSMenuItem
    private let warningMenuItem: NSMenuItem
    private let warningSeparator: NSMenuItem
    private let menu: NSMenu
    private var currentState: AppState = .idle
    private var warnings: [String] = []
    private var lastResult: String?
    private let onOpenSettings: () -> Void

    init(coordinator: Coordinator, onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        self.menu = menu

        warningMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warningMenuItem.isEnabled = false
        warningMenuItem.isHidden = true
        warningSeparator = NSMenuItem.separator()

        stateMenuItem = NSMenuItem(title: "状態: 待機中", action: nil, keyEquivalent: "")
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)

        menu.addItem(NSMenuItem.separator())

        settingsMenuItem = NSMenuItem(title: "設定...", action: #selector(openSettings), keyEquivalent: ",")
        copyLastResultMenuItem = NSMenuItem(title: "最後の文字起こし結果をコピー", action: #selector(copyLastResult), keyEquivalent: "")
        copyLastResultMenuItem.isEnabled = false

        // NSObjectを継承しないこのクラスでは、全ストアドプロパティの初期化が終わるまで`self`を使えない
        // (target割り当ても含む)ため、生成をすべて済ませてからまとめてtargetを割り当てる。
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        copyLastResultMenuItem.target = self
        menu.addItem(copyLastResultMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        applyIcon(for: .idle)
        coordinator.onStateChanged = { [weak self] state in
            self?.applyIcon(for: state)
        }
    }

    /// モデル未配置・アクセシビリティ権限未許可などの警告をメニューバーに追加する。
    /// 同じ内容の警告を重複追加しないよう呼び出し側で判断する必要はない(内部で重複排除する)。
    func addWarning(_ message: String) {
        guard !warnings.contains(message) else { return }
        warnings.append(message)
        refreshWarningMenuItem()
    }

    func removeWarning(_ message: String) {
        warnings.removeAll { $0 == message }
        refreshWarningMenuItem()
    }

    /// 直近の文字起こし結果を保持する。自動挿入の成否によらず呼ぶこと
    /// (フォーカス変化で自動挿入を中止した場合でも、ここから手動でコピーして回収できるようにするため)。
    func updateLastResult(_ text: String) {
        lastResult = text
        copyLastResultMenuItem.isEnabled = !text.isEmpty
    }

    private func refreshWarningMenuItem() {
        if warnings.isEmpty {
            if menu.items.contains(warningMenuItem) {
                menu.removeItem(warningMenuItem)
            }
            if menu.items.contains(warningSeparator) {
                menu.removeItem(warningSeparator)
            }
            warningMenuItem.isHidden = true
        } else {
            warningMenuItem.title = warnings.map { "⚠️ \($0)" }.joined(separator: "\n")
            warningMenuItem.isHidden = false
            if !menu.items.contains(warningMenuItem) {
                menu.insertItem(warningMenuItem, at: 0)
                menu.insertItem(warningSeparator, at: 1)
            }
        }
        applyIcon(for: currentState)
    }

    private func applyIcon(for state: AppState) {
        currentState = state
        var symbolName: String
        let label: String
        var tintColor: NSColor?

        switch state {
        case .idle:
            symbolName = "mic"
            label = "状態: 待機中"
            tintColor = nil
        case .recording:
            symbolName = "mic.fill"
            label = "状態: 録音中"
            tintColor = .systemRed
        case .transcribing:
            symbolName = "ellipsis.circle"
            label = "状態: 文字起こし中"
            tintColor = .systemOrange
        }

        if !warnings.isEmpty && state == .idle {
            symbolName = "mic.trianglebadge.exclamationmark"
            tintColor = .systemYellow
        }

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Voicewriter")
            button.image = image
            button.contentTintColor = tintColor
        }
        stateMenuItem.title = label
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func copyLastResult() {
        guard let lastResult else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastResult, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
