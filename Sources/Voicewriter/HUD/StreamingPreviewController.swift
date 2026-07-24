import AppKit
import SwiftUI

/// SpeechAnalyzerストリーミングモードのライブプレビューパネルを管理する。
/// `Coordinator.onStreamingPreviewUpdate`/`onStreamingPreviewHide`から呼ばれるだけの配線用クラスで、
/// 状態機械のロジックには一切関与しない(既存`StatusHUDController`と同じ位置づけ)。
///
/// - 100〜250ms程度にスロットルしてから反映する(仕様通り。SpeechAnalyzerからのvolatileイベントは
///   1文字追加されるだけでも毎回届きうるため、そのまま反映するとSwiftUIの再描画が過剰になる)。
/// - 表示は末尾(直近)のみに切り詰める(仕様では固定サイズのパネルを想定しているため、
///   長い発話でも際限なく幅/高さが増えないようにする)。
/// - `Settings.streamingPreviewEnabled`がfalseの場合は常に非表示のまま何もしない。
@MainActor
final class StreamingPreviewController {
    private let viewModel = StreamingPreviewViewModel()
    private let panel: StreamingPreviewPanel

    /// パネルに表示する最大文字数(確定+未確定の合計)。これを超える古い部分は先頭から切り詰める。
    private static let maxVisibleCharacters = 160
    private static let throttleInterval: TimeInterval = 0.15

    private var latestPending: (finalizedText: String, volatileText: String)?
    private var throttleWorkItem: DispatchWorkItem?

    init() {
        let size = StreamingPreviewContentView.panelSize
        let panel = StreamingPreviewPanel(contentSize: size)
        let hosting = NSHostingView(rootView: StreamingPreviewContentView(viewModel: viewModel))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        self.panel = panel
    }

    /// `Coordinator.onStreamingPreviewUpdate`から呼ぶ。
    func update(finalizedText: String, volatileText: String) {
        guard Settings.streamingPreviewEnabled else { return }
        latestPending = (finalizedText, volatileText)
        guard throttleWorkItem == nil else { return }
        applyLatestAndShow()
        scheduleThrottleWindow()
    }

    /// `Coordinator.onStreamingModelPreparing`から呼ぶ(モデル資産の初回自動ダウンロード中)。
    /// スロットル/切り詰め対象の通常テキスト表示とは別扱いで、即座に反映する。
    func showPreparing(progress: Double?) {
        guard Settings.streamingPreviewEnabled else { return }
        throttleWorkItem?.cancel()
        throttleWorkItem = nil
        latestPending = nil
        viewModel.display = .preparing(progress: progress)
        show()
    }

    /// `Coordinator.onStreamingPreviewHide`から呼ぶ(録音終了/キャンセル/致命的エラー時)。
    func hide() {
        throttleWorkItem?.cancel()
        throttleWorkItem = nil
        latestPending = nil
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

    private func scheduleThrottleWindow() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.throttleWorkItem = nil
            if self.latestPending != nil {
                self.applyLatestAndShow()
            }
        }
        throttleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.throttleInterval, execute: item)
    }

    private func applyLatestAndShow() {
        guard let pending = latestPending else { return }
        guard Settings.streamingPreviewEnabled else { return }
        let (visibleFinalized, visibleVolatile) = Self.truncatedTail(
            finalizedText: pending.finalizedText,
            volatileText: pending.volatileText,
            maxCharacters: Self.maxVisibleCharacters
        )
        viewModel.display = .visible(finalizedText: visibleFinalized, volatileText: visibleVolatile)
        show()
    }

    /// 表示予算(`maxCharacters`)内に収まるよう、確定テキストの先頭から切り詰める(直近の内容を優先する)。
    /// 未確定(volatile)テキストは常に全体を残す(=今まさに認識中の末尾が見えなくなることはない)。
    static func truncatedTail(finalizedText: String, volatileText: String, maxCharacters: Int) -> (finalizedText: String, volatileText: String) {
        guard maxCharacters > 0 else { return ("", "") }
        let volatileCount = volatileText.count
        guard volatileCount < maxCharacters else {
            return ("", String(volatileText.suffix(maxCharacters)))
        }
        let remainingForFinalized = maxCharacters - volatileCount
        return (String(finalizedText.suffix(remainingForFinalized)), volatileText)
    }

    private func show() {
        positionPanel()
        if !panel.isVisible || panel.alphaValue == 0 {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
    }

    /// メインスクリーン下部中央、既存の状態表示HUD(`StatusHUDController`)の少し上に積む。
    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.minY + 24 + 40 + 12
        panel.setFrame(frame, display: false)
    }
}
