import AppKit
import SwiftUI

/// 状態表示HUD(画面下部中央の浮遊ピル)を管理する。
///
/// `Coordinator`/`AudioCaptureEngine`/`DeliveryCoordinator`の既存コールバック・状態変更点から
/// このクラスのメソッドを呼ぶだけで配線され、状態機械のロジック自体には一切関与しない。
/// `Settings.hudEnabled`がfalseの場合は常に非表示のまま何もしない。
///
/// 連続音声入力パイプライン対応: 個々のジョブイベントを直接表示するのではなく、
/// 「録音状態」「未終端ジョブ数(残件数)」「現在アクティブなフェーズ」を集約したスナップショットから
/// 表示を導出する。表示優先順位は 録音中 > 処理フェーズ > 完了通知 とし、
/// **録音中のレベルメーター表示を、他ジョブの完了通知が上書きすることは絶対にない**
/// (別ジョブがバックグラウンドで完了しても、ユーザーが今まさに話している録音表示を邪魔しないため)。
@MainActor
final class StatusHUDController {
    private let viewModel = StatusHUDViewModel()
    private let panel: StatusHUDPanel
    private var autoHideWorkItem: DispatchWorkItem?

    /// 集約スナップショット。
    private var isRecordingNow = false
    private var pendingCount = 0
    private var lastLevel: Float = 0
    /// 直近に通知された処理フェーズ(FIFOの先頭ジョブについての通知)。録音終了直後や、
    /// 完了通知の一時表示(成功/失敗等)が自動的に隠れるタイミングで、まだ未終端ジョブが
    /// 残っていればこのフェーズへ表示を復元するために保持する
    /// (Codexレビュー指摘#9: 以前は録音終了後に処理中フェーズ表示へ戻らなかったり、
    /// 完了通知が別ジョブの認識中/整形中表示を上書きしたまま自動的に隠れてしまっていた)。
    private var lastPhase: TranscriptionPhase?

    /// whisperモデルの初回自動セットアップ(ダウンロード)が進行中かどうか。trueの間は
    /// 通常の状態遷移由来の表示更新(録音/フェーズ/コミット/キュー満杯)を無視する
    /// (実際には`Coordinator.isModelSetupBlocking`により、この間は録音自体が開始されない
    /// ため通常は競合しないが、念のための防御)。
    private var isSetupBlockingDisplay = false
    /// セットアップ中に直近報告された進捗(0.0〜1.0)。「セットアップ中です」の一時通知の後、
    /// 進捗表示へ復元するために保持する。
    private var lastSetupProgress: Double = 0

    init() {
        let size = StatusHUDContentView.panelSize
        let panel = StatusHUDPanel(contentSize: size)
        let hosting = NSHostingView(rootView: StatusHUDContentView(viewModel: viewModel))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        self.panel = panel
    }

    // MARK: - Coordinator/AudioCaptureEngineからの配線

    /// `Coordinator.onStateChanged`から呼ぶ。
    func handleStateChanged(_ state: AppState) {
        // 内部スナップショット(isRecordingNow)は、セットアップ中の表示抑止(isSetupBlockingDisplay)
        // とは無関係に常に最新へ保つ(実際にはセットアップ中に録音自体が開始されないため、実質的には
        // 起こらない想定だが、セットアップ解除直後に古いスナップショットを引きずらないための防御)。
        switch state {
        case .recording: isRecordingNow = true
        case .transcribing, .idle: isRecordingNow = false
        }
        guard !isSetupBlockingDisplay else { return }
        guard Settings.hudEnabled else {
            hideImmediately()
            return
        }
        switch state {
        case .recording:
            autoHideWorkItem?.cancel()
            viewModel.display = .recording(level: lastLevel, pendingCount: pendingCount)
            show()
        case .transcribing:
            // 録音終了直後、まだこのジョブ自身のフェーズ通知が届く前でも、既に他の未終端ジョブが
            // 処理中(またはコミット待ち)であれば、直近の処理フェーズ表示へ戻す
            // (Codexレビュー指摘#9: 以前は録音中のレベルメーター表示のまま固まって見えたり、
            // 何も表示されないまま次のフェーズ通知を待つだけだった)。
            restoreProcessingPhaseDisplayIfPending()
        case .idle:
            // 挿入結果(成功/フォールバック警告)は`reportJobCommitted`で別途通知される。
            // 録音キャンセルや致命的エラーなど、結果が来ないまま idle に戻るケースもあるため、
            // 一定時間だれからも通知が来なければ隠す(自動キャンセル的なフェイルセーフ)。
            scheduleAutoHide(after: 0.6)
        }
    }

    /// `Coordinator.onPendingJobCountChanged`から呼ぶ(HUDの「残り件数」表示用)。
    func handlePendingJobCountChanged(_ count: Int) {
        // pendingCount/lastPhaseの内部スナップショットは、表示抑止中(isSetupBlockingDisplay)でも
        // 更新し続ける(解除後にすぐ古い値を表示してしまわないため)。
        pendingCount = count
        if count == 0 {
            // 未終端ジョブが無くなった時点で、直近のフェーズ記憶も破棄する。次に新しい発話が
            // 始まった際に、古いフェーズがそのまま復元されてしまわないようにするため。
            lastPhase = nil
        }
        guard !isSetupBlockingDisplay else { return }
        guard Settings.hudEnabled else { return }
        // 録音中表示は完了/件数変化で上書きしない(録音表示自体は`handleStateChanged`/`updateLevel`が
        // 都度`pendingCount`を織り込んで更新するため、ここでは反映するだけで良い)。
        if isRecordingNow {
            viewModel.display = .recording(level: lastLevel, pendingCount: pendingCount)
        }
    }

    /// `Coordinator.onPhaseChanged`から呼ぶ。録音中は表示を上書きしない(優先順位: 録音中 > フェーズ)。
    func handlePhaseChanged(_ phase: TranscriptionPhase) {
        // lastPhaseの内部スナップショットは表示抑止中でも更新し続ける(理由は上記メソッド群と同じ)。
        lastPhase = phase
        guard !isSetupBlockingDisplay else { return }
        guard Settings.hudEnabled else { return }
        guard !isRecordingNow else { return }
        switch phase {
        case .recognizing:
            viewModel.display = .recognizing(pendingCount: pendingCount)
        case .formatting:
            viewModel.display = .formatting(pendingCount: pendingCount)
        }
        autoHideWorkItem?.cancel()
        show()
    }

    /// `AudioCaptureEngine.onLevelUpdate`から呼ぶ(録音中のみ意味を持つ)。
    func updateLevel(_ rms: Float) {
        guard !isSetupBlockingDisplay else { return }
        guard Settings.hudEnabled else { return }
        guard isRecordingNow else { return }
        // RMSは概ね小さい値(発話でも0.05〜0.2程度)なので、バーが動く程度に見えるよう強調する。
        let normalized = min(1.0, max(0, rms) * 6)
        lastLevel = normalized
        viewModel.display = .recording(level: normalized, pendingCount: pendingCount)
    }

    /// `Coordinator.onJobCommitted`から呼ぶ(挿入完了/スキップ/キャンセル/失敗/フォーカス不一致)。
    /// 録音中は表示を上書きしない(不変条件: 録音中のレベルメーター表示を完了通知が奪わない)。
    func reportJobCommitted(_ result: DictationJobCommitEvent) {
        guard !isSetupBlockingDisplay else { return }
        guard Settings.hudEnabled else { return }
        guard !isRecordingNow else { return }

        autoHideWorkItem?.cancel()
        switch result {
        case .inserted(_, let usedFormattingFallback):
            viewModel.display = usedFormattingFallback ? .fallbackWarning : .success
            show()
            scheduleAutoHide(after: usedFormattingFallback ? 1.5 : 0.8)
        case .skipped(let reason):
            let message: String
            switch reason {
            case .tooShort: message = "短すぎるためキャンセル"
            case .silence: message = "無音のためキャンセル"
            }
            viewModel.display = .cancelled(message: message)
            show()
            scheduleAutoHide(after: 1.0)
        case .cancelled:
            viewModel.display = .cancelled(message: "キャンセルしました")
            show()
            scheduleAutoHide(after: 1.0)
        case .failed:
            viewModel.display = .cancelled(message: "文字起こしに失敗しました")
            show()
            scheduleAutoHide(after: 1.5)
        case .focusMismatch:
            viewModel.display = .cancelled(message: "挿入先変更のため中止")
            show()
            scheduleAutoHide(after: 1.5)
        }
    }

    /// `Coordinator.onQueueFull`から呼ぶ。通常のビープと区別できる表示。
    func reportQueueFull() {
        guard !isSetupBlockingDisplay else { return }
        guard Settings.hudEnabled else { return }
        guard !isRecordingNow else { return }
        autoHideWorkItem?.cancel()
        viewModel.display = .queueFull
        show()
        scheduleAutoHide(after: 1.2)
    }

    // MARK: - 初回モデルセットアップ(自動ダウンロード)の表示

    /// `AppDelegate`が`ModelDownloader.state`の変化から呼ぶ。ダウンロード中は自動的に隠れない
    /// (セットアップが終わるまでユーザーに常時見える状態を保つ)。
    func reportModelSetupDownloading(progress: Double) {
        isSetupBlockingDisplay = true
        lastSetupProgress = progress
        guard Settings.hudEnabled else { return }
        autoHideWorkItem?.cancel()
        viewModel.display = .settingUp(message: Self.setupDownloadingMessage(progress: progress))
        show()
    }

    private static func setupDownloadingMessage(progress: Double) -> String {
        "初回セットアップ中: モデルをダウンロードしています… \(Int((progress * 100).rounded()))%"
    }

    /// モデルの自動ダウンロードが成功した際に呼ぶ。短時間の完了表示の後、通常の表示へ戻す。
    func reportModelSetupSucceeded() {
        isSetupBlockingDisplay = false
        guard Settings.hudEnabled else { return }
        autoHideWorkItem?.cancel()
        viewModel.display = .success
        show()
        scheduleAutoHide(after: 1.2)
    }

    /// モデルの自動ダウンロードが失敗した際に呼ぶ(ディスク容量不足・ネットワーク失敗等)。
    /// 詳細な案内・再試行導線はメニューバー/設定画面側が担うため、ここでは短時間の通知のみ行う。
    func reportModelSetupFailed(message: String) {
        isSetupBlockingDisplay = false
        guard Settings.hudEnabled else { return }
        autoHideWorkItem?.cancel()
        viewModel.display = .setupFailed(message: message)
        show()
        scheduleAutoHide(after: 4.0)
    }

    /// セットアップが(ユーザーによるキャンセル等で)`.idle`へ戻った際に呼ぶ。
    /// セットアップ関連の表示中だった場合のみ隠す(無関係な表示を誤って隠さないため)。
    func reportModelSetupIdle() {
        isSetupBlockingDisplay = false
        switch viewModel.display {
        case .settingUp, .setupFailed:
            hide()
        default:
            break
        }
    }

    /// セットアップ中にF13(PTT)/トグルで録音が要求され、拒否したことを通知する。
    /// 通常の`scheduleAutoHide`(=`resolveAfterTemporaryDisplay`経由でHUDを完全に隠す)は使わず、
    /// 一定時間後もまだセットアップ中であれば進捗表示へ復元する(セットアップ中は常時表示という
    /// 不変条件を保つため)。
    func reportRecordingRejectedDuringSetup() {
        guard Settings.hudEnabled else { return }
        autoHideWorkItem?.cancel()
        viewModel.display = .setupInProgressRejected
        show()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isSetupBlockingDisplay {
                self.viewModel.display = .settingUp(message: Self.setupDownloadingMessage(progress: self.lastSetupProgress))
                self.show()
            } else {
                self.resolveAfterTemporaryDisplay()
            }
        }
        autoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    // MARK: - 表示/非表示(フェード)

    private func show() {
        positionPanel()
        if !panel.isVisible || panel.alphaValue == 0 {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func scheduleAutoHide(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.resolveAfterTemporaryDisplay()
        }
        autoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// 一時表示(挿入完了/キャンセル/失敗/キュー満杯等の通知)の自動非表示タイミングで呼ばれる。
    /// まだ他に未終端ジョブが処理中/処理待ちであれば、それを隠さず直近の処理フェーズ表示へ
    /// 差し替える(Codexレビュー指摘#9: 以前はJ1の完了通知がJ2の認識中表示を上書きした後、
    /// J2がまだ処理中でも自動的に隠れてしまっていた)。他に未終端ジョブが無ければ通常通り隠す。
    private func resolveAfterTemporaryDisplay() {
        guard Settings.hudEnabled, !isRecordingNow else {
            hide()
            return
        }
        guard restoreProcessingPhaseDisplayIfPending() else {
            hide()
            return
        }
    }

    /// `pendingCount > 0`かつ直近の処理フェーズが分かっていれば、その表示へ差し替える。
    /// 表示できた場合はtrueを返す(呼び出し元が「隠すべきか」を判断するために使う)。
    @discardableResult
    private func restoreProcessingPhaseDisplayIfPending() -> Bool {
        guard Settings.hudEnabled, !isRecordingNow, pendingCount > 0, let lastPhase else { return false }
        autoHideWorkItem?.cancel()
        switch lastPhase {
        case .recognizing:
            viewModel.display = .recognizing(pendingCount: pendingCount)
        case .formatting:
            viewModel.display = .formatting(pendingCount: pendingCount)
        }
        show()
        return true
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
                self.viewModel.display = .hidden
            }
        })
    }

    private func hideImmediately() {
        autoHideWorkItem?.cancel()
        panel.alphaValue = 0
        panel.orderOut(nil)
        viewModel.display = .hidden
    }

    /// メインスクリーン下部中央(Dockの少し上)へ配置する。
    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.minY + 24
        panel.setFrame(frame, display: false)
    }
}
