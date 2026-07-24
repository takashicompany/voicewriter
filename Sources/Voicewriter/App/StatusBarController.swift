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
    /// LLM整形が(起動時にOllamaへ到達できなかったため)無効の間だけ表示する、常設の状態表示。
    /// `warningMenuItem`(⚠️付き・自動的にアイコンも警告色にする)とは異なり、こちらは
    /// 「Ollama未導入は例外的な障害ではなく通常運用でありうる状態」という位置づけのため、
    /// 警告のような騒がしい見た目にはしない(アイコン変更もしない)。
    private let formattingStatusMenuItem: NSMenuItem
    /// 「音声認識エンジン」サブメニューの各項目。設定画面のPicker(`TranscriptionSettingsView`)と
    /// 選択肢を揃える(stubはデバッグ用のためここには出さない)。
    private let engineMenuItem: NSMenuItem
    private let engineSubmenu: NSMenu
    private let engineWhisperItem: NSMenuItem
    private let engineSpeechAnalyzerItem: NSMenuItem
    private let menu: NSMenu
    private var currentState: AppState = .idle
    private var warnings: [String] = []
    private var history: [HistoryEntry] = []
    /// SpeechAnalyzerストリーミングモードがこの環境で選択可能かどうか。`AppDelegate`が
    /// `StreamingTranscriptionAvailability.currentStatus()`(非同期)の結果を`updateSpeechAnalyzerAvailability`
    /// 経由で流し込む。判定ロジック自体は設定画面(`TranscriptionSettingsView`)と共通のものを再利用し、
    /// ここで再実装はしない。取得完了までは「未対応」側に倒し、誤って有効表示にしない。
    private var speechAnalyzerAvailability = StreamingTranscriptionAvailabilityStatus(isSupported: false, reason: "確認中…")
    private let onOpenSettings: () -> Void
    private let onCancelAllJobs: () -> Void
    /// メニューからのエンジン切替を受け取る。`Settings.sttEngine`への書き込みと
    /// `DynamicTranscriptionEngine.reload()`は呼び出し側(`AppDelegate`)が持つ既存の1経路
    /// (設定画面の`onChange`と同じ経路)をそのまま再利用し、ここでは二重実装しない。
    private let onSelectEngine: (SttEngineKind) -> Void

    /// メニューバー用の自前グリフ(採用アイコン案icon-33のピクトグラムから抽出したマイク+ペン先)。
    /// `Resources/MenuBarIcon/menubar-icon.png`(@1x, 10x18px)と`menubar-icon@2x.png`(@2x, 20x36px)
    /// から1つの`NSImage`に1x/2x両方の表現をまとめ、`isTemplate = true`でシステムに配色を任せる
    /// (`contentTintColor`による着色は従来のSF Symbolsアイコンと同様に効く)。
    /// グリフが縦長(高さ18pxに対し横幅10px程度)なため、表示上のポイントサイズは正方形に固定せず
    /// `rep1x`の実ピクセル寸法(@1xは1px=1pt相当)をそのまま使う。これを正方形に固定してしまうと
    /// 画像が横方向に間延びして再度余白過多に見えてしまう(過去の実機フィードバックで発生した不具合)。
    /// `.app`バンドル化されていない`swift run`実行時などリソースが見つからない場合はnilとなり、
    /// 呼び出し側(`applyIcon(for:)`)が既存のSF Symbolへフォールバックする。
    private static let brandGlyphImage: NSImage? = {
        guard let resourceDir = Bundle.main.resourcePath else { return nil }
        guard
            let data1x = FileManager.default.contents(atPath: "\(resourceDir)/MenuBarIcon/menubar-icon.png"),
            let data2x = FileManager.default.contents(atPath: "\(resourceDir)/MenuBarIcon/menubar-icon@2x.png"),
            let rep1x = NSBitmapImageRep(data: data1x),
            let rep2x = NSBitmapImageRep(data: data2x)
        else {
            return nil
        }
        let pointSize = NSSize(width: CGFloat(rep1x.pixelsWide), height: CGFloat(rep1x.pixelsHigh))
        rep1x.size = pointSize
        rep2x.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep1x)
        image.addRepresentation(rep2x)
        image.isTemplate = true
        return image
    }()

    init(
        coordinator: Coordinator,
        onOpenSettings: @escaping () -> Void,
        onCancelAllJobs: @escaping () -> Void,
        onSelectEngine: @escaping (SttEngineKind) -> Void
    ) {
        self.onOpenSettings = onOpenSettings
        self.onCancelAllJobs = onCancelAllJobs
        self.onSelectEngine = onSelectEngine
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

        formattingStatusMenuItem = NSMenuItem(title: "LLM整形: 無効(Ollama未検出)", action: nil, keyEquivalent: "")
        formattingStatusMenuItem.isEnabled = false
        formattingStatusMenuItem.isHidden = true
        menu.addItem(formattingStatusMenuItem)

        menu.addItem(NSMenuItem.separator())

        settingsMenuItem = NSMenuItem(title: "設定...", action: #selector(openSettings), keyEquivalent: ",")

        // 音声認識エンジン切替サブメニュー。stub(デバッグ用、設定画面のみ)は意図的に含めない。
        engineWhisperItem = NSMenuItem(title: Self.whisperTitle, action: #selector(selectWhisperEngine), keyEquivalent: "")
        engineSpeechAnalyzerItem = NSMenuItem(title: Self.speechAnalyzerTitle, action: #selector(selectSpeechAnalyzerEngine), keyEquivalent: "")
        engineSubmenu = NSMenu()
        engineSubmenu.addItem(engineWhisperItem)
        engineSubmenu.addItem(engineSpeechAnalyzerItem)
        engineMenuItem = NSMenuItem(title: "音声認識エンジン", action: nil, keyEquivalent: "")
        engineMenuItem.submenu = engineSubmenu

        historySubmenu = NSMenu()
        historyMenuItem = NSMenuItem(title: "最近の文字起こし結果", action: nil, keyEquivalent: "")
        historyMenuItem.submenu = historySubmenu
        historyMenuItem.isEnabled = false

        cancelAllMenuItem = NSMenuItem(title: "すべての処理をキャンセル", action: #selector(cancelAllJobs), keyEquivalent: "")

        // NSObjectを継承しないこのクラスでは、全ストアドプロパティの初期化が終わるまで`self`を使えない
        // (target割り当ても含む)ため、生成をすべて済ませてからまとめてtargetを割り当てる。
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        engineWhisperItem.target = self
        engineSpeechAnalyzerItem.target = self
        menu.addItem(engineMenuItem)

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
        refreshEngineMenu()
    }

    private static let whisperTitle = "Whisper(一括)"
    private static let speechAnalyzerTitle = "SpeechAnalyzer(ストリーミング)"
    // 半角括弧は既存の`TranscriptionSettingsView`の表記("Apple SpeechAnalyzer(ストリーミング)")に
    // 揃えたもの。

    /// 設定画面(`TranscriptionSettingsView`)からエンジンが切り替えられた場合に、メニューの
    /// チェックマーク表示を同期させる。`DynamicTranscriptionEngine.onWarningChanged`
    /// (`reload()`完了のたびに必ず呼ばれる、既存の配線)から`AppDelegate`経由で呼んでもらう想定。
    func syncEngineSelectionDisplay() {
        refreshEngineMenu()
    }

    /// SpeechAnalyzerストリーミングモードの可否判定結果を反映する。判定自体は
    /// `StreamingTranscriptionAvailability.currentStatus()`(設定画面と共通)の結果を
    /// `AppDelegate`から渡してもらうだけで、ここでは判定ロジックを再実装しない。
    func updateSpeechAnalyzerAvailability(_ status: StreamingTranscriptionAvailabilityStatus) {
        speechAnalyzerAvailability = status
        refreshEngineMenu()
    }

    /// 「音声認識エンジン」サブメニューの選択状態(チェックマーク)・利用可否(disabled)を
    /// 現在の`Settings.sttEngine`とキャッシュ済みの可用性判定から再計算する。
    /// メニューを開くたびの表示だけでなく、切替直後・可用性判定到着時にも同じ関数で反映する
    /// (表示ロジックを1箇所にまとめ、状態のずれを防ぐ)。
    private func refreshEngineMenu() {
        let current = Settings.sttEngine
        engineWhisperItem.state = (current == .whisperCpp) ? .on : .off
        engineSpeechAnalyzerItem.state = (current == .speechAnalyzer) ? .on : .off

        engineSpeechAnalyzerItem.isEnabled = speechAnalyzerAvailability.isSupported
        if let reason = speechAnalyzerAvailability.reason, !speechAnalyzerAvailability.isSupported {
            engineSpeechAnalyzerItem.title = "\(Self.speechAnalyzerTitle) - 利用不可"
            engineSpeechAnalyzerItem.toolTip = reason
        } else {
            engineSpeechAnalyzerItem.title = Self.speechAnalyzerTitle
            engineSpeechAnalyzerItem.toolTip = nil
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

    /// LLM整形が(Ollama未検出のため)無効かどうかの常設状態表示を切り替える。冪等
    /// (既に同じ状態であれば何もしない)。
    func setFormattingUnavailable(_ unavailable: Bool) {
        formattingStatusMenuItem.isHidden = !unavailable
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
        // 通常時・録音中は自前のブランドグリフ(マイク+ペン先)を使う。文字起こし中(処理中を示す
        // アニメーション的な三点)・警告(注意喚起の三角+感嘆符)は形そのものに意味があり、静的な
        // グリフでは代替できないため、既存のSF Symbolsによる状態表現を維持する。
        var useBrandGlyph = false

        switch state {
        case .idle:
            symbolName = "mic"
            label = "状態: 待機中"
            tintColor = nil
            useBrandGlyph = true
        case .recording:
            symbolName = "mic.fill"
            label = "状態: 録音中"
            tintColor = .systemRed
            useBrandGlyph = true
        case .transcribing:
            symbolName = "ellipsis.circle"
            label = "状態: 文字起こし中"
            tintColor = .systemOrange
        }

        if !warnings.isEmpty && state == .idle {
            symbolName = "mic.trianglebadge.exclamationmark"
            tintColor = .systemYellow
            useBrandGlyph = false
        }

        if let button = statusItem.button {
            if useBrandGlyph, let brandImage = Self.brandGlyphImage {
                button.image = brandImage
            } else {
                button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Voicewriter")
            }
            button.contentTintColor = tintColor
        }
        stateMenuItem.title = label
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func selectWhisperEngine() {
        selectEngine(.whisperCpp)
    }

    @objc private func selectSpeechAnalyzerEngine() {
        // 通常はdisabledでクリックできないはずだが、念のための二重防御。
        guard speechAnalyzerAvailability.isSupported else { return }
        selectEngine(.speechAnalyzer)
    }

    /// メニューからのエンジン切替の実処理。`Settings.sttEngine`書き込み+
    /// `DynamicTranscriptionEngine.reload()`は`onSelectEngine`(`AppDelegate`側、設定画面の
    /// `onChange`ハンドラと同一のロジック)へ委譲する。チェックマークは書き込みが同期的に
    /// 完了した時点で即座に再計算し(実際のエンジン差し替え=`reload()`自体は非同期でモデル
    /// ロードを伴いうるが、設定値と選択表示自体は待たずに即時反映する)。
    private func selectEngine(_ kind: SttEngineKind) {
        guard Settings.sttEngine != kind else { return }
        onSelectEngine(kind)
        refreshEngineMenu()
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
