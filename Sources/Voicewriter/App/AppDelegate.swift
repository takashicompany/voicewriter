import AppKit
import AVFoundation
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "AppDelegate")

    private var statusBarController: StatusBarController?
    private var coordinator: Coordinator?
    private var hotkeyManager: HotkeyManager?
    private var settingsWindowController: SettingsWindowController?
    private var statusHUDController: StatusHUDController?
    private var lastEngineWarning: String?
    private let audioEngine = AudioCaptureEngine()
    /// `Coordinator.onPendingJobCountChanged`から更新する直近の未終端ジョブ数。
    /// `applicationWillTerminate`が終了時のログ出力に使う(Codexレビュー指摘#11)。
    private var lastKnownPendingJobCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement=trueに加え、swift run等バンドル化されていない実行でもDockに出さないよう明示する
        NSApp.setActivationPolicy(.accessory)

        let accessibilityTrusted = AccessibilityPermission.ensureTrusted(promptIfNeeded: true)

        let transcriptionEngine = DynamicTranscriptionEngine()
        let textFormatter = OllamaFormatter()
        let textInserter = TextInserter()

        let coordinator = Coordinator(
            audioEngine: audioEngine,
            transcriptionEngine: transcriptionEngine,
            textFormatter: textFormatter,
            textInserter: textInserter
        )
        self.coordinator = coordinator
        let statusBarController = StatusBarController(
            coordinator: coordinator,
            onOpenSettings: { [weak self] in
                Task { @MainActor in
                    self?.showSettingsWindow(transcriptionEngine: transcriptionEngine)
                }
            },
            onCancelAllJobs: { [weak coordinator] in
                coordinator?.cancelAllJobs()
            }
        )
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
        coordinator.onPendingJobCountChanged = { [weak self, weak statusHUDController] count in
            self?.lastKnownPendingJobCount = count
            statusHUDController?.handlePendingJobCountChanged(count)
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

        // ジョブのコミット結果(挿入完了/スキップ/キャンセル/失敗/フォーカス不一致)の配線。
        // 発話順(sequence)を厳守して`DeliveryCoordinator`が確定させた結果を、HUD/メニューバー/
        // 効果音へ反映するだけで、挿入自体のロジック(フォーカス確認・Cmd+V送出)には一切関与しない。
        coordinator.onJobCommitted = { [weak statusHUDController, weak statusBarController] sequence, result in
            statusHUDController?.reportJobCommitted(result)
            switch result {
            case .inserted(let text, _):
                statusBarController?.recordHistory(sequence: sequence, text: text)
                SoundEffects.playInsertionCompleted()
            case .focusMismatch(let text):
                statusBarController?.recordHistory(sequence: sequence, text: text)
                let message = "挿入先アプリが録音中に切り替わったため、自動挿入を中止しました。メニューバーの「最近の文字起こし結果」から取得できます。"
                statusBarController?.addWarning(message)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak statusBarController] in
                    statusBarController?.removeWarning(message)
                }
            case .failed(let error):
                if case .some(TextInsertionError.accessibilityNotTrusted) = error {
                    statusBarController?.addWarning(accessibilityWarning)
                }
            case .skipped, .cancelled:
                break
            }
        }

        coordinator.onQueueFull = { [weak statusHUDController] in
            // 処理が追いついていない(未終端ジョブが上限に達した)ため新規録音を拒否した。
            // 通常のビープと区別できるHUD表示を出す。
            NSSound.beep()
            statusHUDController?.reportQueueFull()
        }

        coordinator.onFatalAudioError = { [weak statusBarController] message in
            statusBarController?.addWarning(message)
        }

        // LLM整形の失敗(Ollama未起動・タイムアウト等)は致命的ではない(原文へフォールバック済み)ため、
        // 一定時間で自動的に消える軽い警告として表示する(挿入先フォーカス変化時の警告と同じ方針)。
        coordinator.onFormattingFailed = { [weak statusBarController] message in
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
        // 推論用FIFO(`Coordinator.inferenceQueue`)経由で実行することで、起動直後にユーザーが
        // すぐ話し始めた場合の初回whisper.cpp呼び出しと同時にGPU/Unified Memoryを奪い合わない
        // ようにする(Codexレビュー指摘#12: 以前は`Task.detached`で完全に独立して実行しており、
        // 初回の文字起こしと同時にOllamaのモデルロードが走ると両者が資源を奪い合ってしまっていた)。
        if Settings.formattingEnabled {
            coordinator.enqueueBackgroundInferenceTask {
                await textFormatter.preload()
            }
        }

        let actualEngineName = transcriptionEngine.warning == nil ? Settings.sttEngine.rawValue : "stub (fallback)"
        log.info("Voicewriter launched. micMode=\(Settings.micMode.rawValue, privacy: .public) sttEngine=\(actualEngineName, privacy: .public) formattingEnabled=\(Settings.formattingEnabled, privacy: .public) formattingModel=\(Settings.formattingModel, privacy: .public)")
    }

    /// 既知の制約(Codexレビュー指摘#11): 完全なドレイン(未終端ジョブ全ての処理・挿入完了を待つ)は
    /// 行わない。挿入クリティカル区間(フォーカス確認〜Cmd+V送出、ペーストボード復元待ち)が
    /// 進行中の場合のみ、最大1秒程度終了を遅らせて復元を完了させる(`NSApplicationDelegate`の
    /// このメソッド自体は非同期を待てないため、`RunLoop`を短時間ポンプして待つ)。
    /// それ以外の未終端ジョブ(認識・整形待ち、挿入待ち)は、そのまま終了する。件数はログに残す。
    func applicationWillTerminate(_ notification: Notification) {
        log.info("Voicewriter terminating")
        guard let coordinator else { return }

        if coordinator.isInsertionCriticalSection {
            log.info("Delaying termination briefly to let clipboard restore complete")
            let deadline = Date().addingTimeInterval(1.0)
            while coordinator.isInsertionCriticalSection, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }

        if lastKnownPendingJobCount > 0 {
            log.warning("Terminating with \(self.lastKnownPendingJobCount, privacy: .public) unterminated job(s) still pending (not drained; see README known limitations)")
        }
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
