import AppKit
import AVFoundation
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "AppDelegate")

    private var statusBarController: StatusBarController?
    private var coordinator: Coordinator?
    private var hotkeyManager: HotkeyManager?
    private var textInserter: TextInserter?
    private var settingsWindowController: SettingsWindowController?
    private var statusHUDController: StatusHUDController?
    private var lastEngineWarning: String?
    private let audioEngine = AudioCaptureEngine()
    /// 直近の文字起こしサイクルでLLM整形が失敗し、原文へフォールバックしたかどうか。
    /// `onFormattingFailed`でtrueにし、`onTranscriptionResult`で読み取ってからリセットする
    /// (HUDに「整形なしで挿入」を出し分けるための付加情報。状態機械のロジックには影響しない)。
    private var formattingFellBackForPendingResult = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement=trueに加え、swift run等バンドル化されていない実行でもDockに出さないよう明示する
        NSApp.setActivationPolicy(.accessory)

        let accessibilityTrusted = AccessibilityPermission.ensureTrusted(promptIfNeeded: true)

        let transcriptionEngine = DynamicTranscriptionEngine()
        let textFormatter = OllamaFormatter()

        let coordinator = Coordinator(audioEngine: audioEngine, transcriptionEngine: transcriptionEngine, textFormatter: textFormatter)
        self.coordinator = coordinator
        let statusBarController = StatusBarController(coordinator: coordinator) { [weak self] in
            Task { @MainActor in
                self?.showSettingsWindow(transcriptionEngine: transcriptionEngine)
            }
        }
        self.statusBarController = statusBarController
        self.hotkeyManager = HotkeyManager(coordinator: coordinator)
        // HotkeyManagerの構築(ハンドラ登録)がキャンセルショートカットを再度有効化してしまうため、
        // Coordinator.initでのdisable状態を再適用する(起動時にEscが一時的に有効化される問題の対策)。
        coordinator.refreshShortcutEnablement()

        // 状態表示HUD(録音中/認識・整形中/挿入完了)の配線。`onStateChanged`は既に
        // StatusBarControllerがアイコン更新用に設定済みのため、上書きしないよう一旦保持してから
        // 両方を呼ぶラッパーに差し替える(既存の状態機械ロジックには手を入れない、配線の追加のみ)。
        let statusHUDController = StatusHUDController()
        self.statusHUDController = statusHUDController
        let previousOnStateChanged = coordinator.onStateChanged
        coordinator.onStateChanged = { [weak statusHUDController] state in
            previousOnStateChanged?(state)
            statusHUDController?.handleStateChanged(state)
            if state == .recording {
                // 録音開始の合図。詳細な判断根拠は`SoundEffects`のコメント/README参照。
                SoundEffects.playRecordingStarted()
            }
        }
        coordinator.onPhaseChanged = { [weak statusHUDController] phase in
            statusHUDController?.handlePhaseChanged(phase)
        }
        coordinator.onRecordingSkipped = { [weak statusHUDController] reason in
            statusHUDController?.reportRecordingSkipped(reason)
        }
        audioEngine.onLevelUpdate = { [weak statusHUDController] rms in
            statusHUDController?.updateLevel(rms)
        }

        if let engineWarning = transcriptionEngine.warning {
            statusBarController.addWarning(engineWarning)
            lastEngineWarning = engineWarning
        }
        // 設定画面からのエンジン/言語変更でフォールバック状態が変わったら、メニューバーの警告も同期する。
        transcriptionEngine.onWarningChanged = { [weak self, weak statusBarController] newWarning in
            guard let self, let statusBarController else { return }
            if let old = self.lastEngineWarning, old != newWarning {
                statusBarController.removeWarning(old)
            }
            if let newWarning, newWarning != self.lastEngineWarning {
                statusBarController.addWarning(newWarning)
            }
            self.lastEngineWarning = newWarning
        }

        let accessibilityWarning = "アクセシビリティ権限が未許可のため、カーソル位置へのテキスト挿入ができません。システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可してください。"
        if !accessibilityTrusted {
            statusBarController.addWarning(accessibilityWarning)
        }

        let textInserter = TextInserter()
        self.textInserter = textInserter
        coordinator.onTranscriptionResult = { [weak self, weak statusHUDController] text, recordingFrontmostApp in
            Task { @MainActor in
                guard let self else { return }
                statusBarController.updateLastResult(text)

                // このサイクルでLLM整形がフォールバックしていたかどうか(HUDの「整形なしで挿入」表示用)。
                // 読み取り次第リセットし、次サイクルへ持ち越さない。
                let usedFormattingFallback = self.formattingFellBackForPendingResult
                self.formattingFellBackForPendingResult = false

                // 挿入先フォーカスのガード: 録音開始時点のフロントモストアプリと、
                // 挿入直前のフロントモストアプリが異なる場合は自動挿入を中止する
                // (誤って別アプリへ挿入してしまうことを防ぐため)。結果はメニューバーの
                // 「最後の文字起こし結果をコピー」から回収できる。
                let currentFrontmost = NSWorkspace.shared.frontmostApplication
                if let recordingFrontmostApp,
                   currentFrontmost?.processIdentifier != recordingFrontmostApp.processIdentifier {
                    self.log.warning("Frontmost app changed since recording started (from=\(recordingFrontmostApp.bundleIdentifier ?? "?", privacy: .public), to=\(currentFrontmost?.bundleIdentifier ?? "?", privacy: .public)); skipping auto-insert")
                    let message = "挿入先アプリが録音中に切り替わったため、自動挿入を中止しました。メニューバーの「最後の文字起こし結果をコピー」から取得できます。"
                    statusBarController.addWarning(message)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak statusBarController] in
                        statusBarController?.removeWarning(message)
                    }
                    return
                }

                // 実際にCmd+Vを送出した直後(=挿入完了とみなせるタイミング)にHUD/効果音を鳴らす。
                textInserter.onPasted = { [weak statusHUDController] in
                    statusHUDController?.reportInsertionSucceeded(usedFormattingFallback: usedFormattingFallback)
                    SoundEffects.playInsertionCompleted()
                }

                do {
                    try await textInserter.insert(text: text)
                } catch {
                    self.log.error("Text insertion failed: \(String(describing: error), privacy: .public)")
                    if case TextInsertionError.accessibilityNotTrusted = error {
                        statusBarController.addWarning(accessibilityWarning)
                    }
                }
            }
        }

        coordinator.onBusyRecordingAttempt = {
            // 文字起こし中に録音操作が要求された(最低限のフィードバック。キューイングまでは行わない)
            NSSound.beep()
        }

        coordinator.onFatalAudioError = { [weak statusBarController] message in
            statusBarController?.addWarning(message)
        }

        // LLM整形の失敗(Ollama未起動・タイムアウト等)は致命的ではない(原文へフォールバック済み)ため、
        // 一定時間で自動的に消える軽い警告として表示する(挿入先フォーカス変化時の警告と同じ方針)。
        coordinator.onFormattingFailed = { [weak self, weak statusBarController] message in
            self?.formattingFellBackForPendingResult = true
            statusBarController?.addWarning(message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak statusBarController] in
                statusBarController?.removeWarning(message)
            }
        }

        // VAD(Voice Activity Detection)モデルが未配置ならバックグラウンドで自動ダウンロードする
        // (ハルシネーション対策の多層防御のうち、実測で最も効果が高いことを確認した第3層(VAD)を
        // 大半のユーザー環境でも機能させるため。詳細はVadModelAutoProvisioner.swift参照)。
        // ベストエフォートで、失敗しても他の初期化・機能には一切影響しない。
        VadModelAutoProvisioner.provisionIfNeeded()

        // タップ設置とprepare()まで済ませる。AlwaysOnモードのエンジン起動は
        // マイク権限確認の完了を待ってから行う(許可前に起動を試みる競合を避けるため)。
        audioEngine.setup()
        requestMicrophonePermissionIfNeeded { [weak self, weak statusBarController] granted in
            guard let self else { return }
            self.audioEngine.microphonePermissionResolved(granted: granted)
            if !granted {
                let message = "マイク権限が許可されていないため、音声入力が利用できません。システム設定 > プライバシーとセキュリティ > マイク で許可してください。"
                statusBarController?.addWarning(message)
            }
        }

        // 起動時にOllamaへ整形モデルの先読み(keep_alive:-1で常駐化)を依頼しておく。初回の実際の
        // 整形リクエストがモデルロード待ち(大型モデルだと数秒〜十数秒)でタイムアウトしないようにする
        // ための最適化で、失敗してもここでは無視してよい(その場合は通常通り初回リクエスト時にロードされる)。
        if Settings.formattingEnabled {
            Task.detached(priority: .utility) {
                await textFormatter.preload()
            }
        }

        let actualEngineName = transcriptionEngine.warning == nil ? Settings.sttEngine.rawValue : "stub (fallback)"
        log.info("Voicewriter launched. micMode=\(Settings.micMode.rawValue, privacy: .public) sttEngine=\(actualEngineName, privacy: .public) formattingEnabled=\(Settings.formattingEnabled, privacy: .public) formattingModel=\(Settings.formattingModel, privacy: .public)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("Voicewriter terminating")
    }

    /// メニューバーの「設定...」から呼ばれる。ウィンドウが未生成なら生成し、前面化する。
    @MainActor
    private func showSettingsWindow(transcriptionEngine: DynamicTranscriptionEngine) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                audioEngine: audioEngine,
                transcriptionEngine: transcriptionEngine,
                onCancelShortcutChanged: { [weak self] in
                    self?.coordinator?.refreshShortcutEnablement()
                }
            )
        }
        settingsWindowController?.showAndActivate()
        log.info("Settings window shown")
    }

    /// マイク権限の確認/要求を行い、結果が確定してからメインスレッドで`completion`を呼ぶ。
    /// AlwaysOnモードのエンジン自動起動は、この`completion`を待ってから行うこと
    /// (権限確認前にエンジンを起動しようとする競合を避けるため)。
    private func requestMicrophonePermissionIfNeeded(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            log.info("Microphone permission already granted")
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.log.info("Microphone permission requested. granted=\(granted)")
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            log.warning("Microphone permission denied/restricted. Please enable it in System Settings.")
            DispatchQueue.main.async { completion(false) }
        @unknown default:
            DispatchQueue.main.async { completion(false) }
        }
    }
}
