import AppKit

/// メニューバーアイコンとメニュー(録音状態表示 / 設定プレースホルダ / 終了)を管理する。
@MainActor
final class StatusBarController {
    /// 直近の文字起こし結果履歴(発話順)。挿入の成否(自動挿入済み/フォーカス不一致で見送り)によらず
    /// 記録し、メニューから手動コピーして回収できるようにする
    /// (「最後の結果をコピー」を直近数件の履歴に拡張したもの)。
    private struct HistoryEntry {
        let sequence: Int
        let text: String
    }

    /// 履歴として保持する最大件数。
    private static let maxHistoryEntries = 5

    private let statusItem: NSStatusItem
    private let stateMenuItem: NSMenuItem
    private let settingsMenuItem: NSMenuItem
    private let historyMenuItem: NSMenuItem
    private let historySubmenu: NSMenu
    private let cancelAllMenuItem: NSMenuItem
    private let warningMenuItem: NSMenuItem
    private let warningSeparator: NSMenuItem
    private let menu: NSMenu
    private var currentState: AppState = .idle
    private var warnings: [String] = []
    private var history: [HistoryEntry] = []
    private let onOpenSettings: () -> Void
    private let onCancelAllJobs: () -> Void

    init(coordinator: Coordinator, onOpenSettings: @escaping () -> Void, onCancelAllJobs: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onCancelAllJobs = onCancelAllJobs
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

        historySubmenu = NSMenu()
        historyMenuItem = NSMenuItem(title: "最近の文字起こし結果", action: nil, keyEquivalent: "")
        historyMenuItem.submenu = historySubmenu
        historyMenuItem.isEnabled = false

        cancelAllMenuItem = NSMenuItem(title: "すべての処理をキャンセル", action: #selector(cancelAllJobs), keyEquivalent: "")

        // NSObjectを継承しないこのクラスでは、全ストアドプロパティの初期化が終わるまで`self`を使えない
        // (target割り当ても含む)ため、生成をすべて済ませてからまとめてtargetを割り当てる。
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        menu.addItem(historyMenuItem)

        cancelAllMenuItem.target = self
        menu.addItem(cancelAllMenuItem)

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

    /// 文字起こし結果を履歴へ記録する。自動挿入の成否によらず呼ぶこと
    /// (フォーカス変化で自動挿入を中止した場合でも、ここから手動でコピーして回収できるようにするため)。
    /// 直近`maxHistoryEntries`件のみ保持し、新しいものを先頭に表示する。
    func recordHistory(sequence: Int, text: String) {
        guard !text.isEmpty else { return }
        history.removeAll { $0.sequence == sequence }
        history.append(HistoryEntry(sequence: sequence, text: text))
        if history.count > Self.maxHistoryEntries {
            history.removeFirst(history.count - Self.maxHistoryEntries)
        }
        refreshHistoryMenu()
    }

    private func refreshHistoryMenu() {
        historySubmenu.removeAllItems()
        if history.isEmpty {
            historyMenuItem.isEnabled = false
            let empty = NSMenuItem(title: "(履歴なし)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historySubmenu.addItem(empty)
            return
        }
        historyMenuItem.isEnabled = true
        for entry in history.reversed() {
            let preview = Self.previewText(for: entry.text)
            let item = NSMenuItem(title: preview, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.text
            historySubmenu.addItem(item)
        }
    }

    private static func previewText(for text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        let maxLength = 28
        if collapsed.count > maxLength {
            return String(collapsed.prefix(maxLength)) + "…"
        }
        return collapsed
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

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func cancelAllJobs() {
        onCancelAllJobs()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
