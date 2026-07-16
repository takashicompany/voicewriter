import AppKit
import SwiftUI

/// 状態表示HUD(画面下部中央の浮遊ピル)を管理する。
///
/// `Coordinator`/`AudioCaptureEngine`/`TextInserter`の既存コールバック・状態変更点から
/// このクラスのメソッドを呼ぶだけで配線され、状態機械のロジック自体には一切関与しない。
/// `Settings.hudEnabled`がfalseの場合は常に非表示のまま何もしない。
@MainActor
final class StatusHUDController {
    private let viewModel = StatusHUDViewModel()
    private let panel: StatusHUDPanel
    private var autoHideWorkItem: DispatchWorkItem?

    init() {
        let size = StatusHUDContentView.panelSize
        let panel = StatusHUDPanel(contentSize: size)
        let hosting = NSHostingView(rootView: StatusHUDContentView(viewModel: viewModel))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        self.panel = panel
    }

    // MARK: - Coordinator/AudioCaptureEngine/TextInserterからの配線

    /// `Coordinator.onStateChanged`から呼ぶ。
    func handleStateChanged(_ state: AppState) {
        guard Settings.hudEnabled else {
            hideImmediately()
            return
        }
        switch state {
        case .recording:
            autoHideWorkItem?.cancel()
            viewModel.display = .recording(level: 0)
            show()
        case .transcribing:
            autoHideWorkItem?.cancel()
            viewModel.display = .recognizing
            show()
        case .idle:
            // 挿入結果(成功/フォールバック警告)は`reportInsertionSucceeded`で別途通知される。
            // 録音キャンセルや致命的エラーなど、結果が来ないまま idle に戻るケースもあるため、
            // 一定時間だれからも通知が来なければ隠す(自動キャンセル的なフェイルセーフ)。
            scheduleAutoHide(after: 0.6)
        }
    }

    /// `Coordinator.onPhaseChanged`から呼ぶ。
    func handlePhaseChanged(_ phase: TranscriptionPhase) {
        guard Settings.hudEnabled else { return }
        switch phase {
        case .recognizing:
            viewModel.display = .recognizing
        case .formatting:
            viewModel.display = .formatting
        }
        show()
    }

    /// `AudioCaptureEngine.onLevelUpdate`から呼ぶ(録音中のみ意味を持つ)。
    func updateLevel(_ rms: Float) {
        guard Settings.hudEnabled else { return }
        guard case .recording = viewModel.display else { return }
        // RMSは概ね小さい値(発話でも0.05〜0.2程度)なので、バーが動く程度に見えるよう強調する。
        let normalized = min(1.0, max(0, rms) * 6)
        viewModel.display = .recording(level: normalized)
    }

    /// `TextInserter.onPasted`経由(=実際にCmd+Vを送出した直後)に呼ぶ。
    /// `usedFormattingFallback`はLLM整形が失敗し原文へフォールバックしていた場合に`true`。
    func reportInsertionSucceeded(usedFormattingFallback: Bool) {
        guard Settings.hudEnabled else { return }
        autoHideWorkItem?.cancel()
        viewModel.display = usedFormattingFallback ? .fallbackWarning : .success
        show()
        scheduleAutoHide(after: usedFormattingFallback ? 1.5 : 0.8)
    }

    /// `Coordinator.onRecordingSkipped`から呼ぶ(ハルシネーション対策の多層防御により
    /// 文字起こし自体がスキップされた場合)。テキスト挿入は行われない。
    func reportRecordingSkipped(_ reason: RecordingSkipReason) {
        guard Settings.hudEnabled else { return }
        autoHideWorkItem?.cancel()
        let message: String
        switch reason {
        case .tooShort:
            message = "短すぎるためキャンセル"
        case .silence:
            message = "無音のためキャンセル"
        }
        viewModel.display = .cancelled(message: message)
        show()
        scheduleAutoHide(after: 1.0)
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
            self?.hide()
        }
        autoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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
