import SwiftUI

/// superwhisper/Wispr Flow風の小さなピル型パネルの中身。
/// ダーク寄りの半透明マテリアル・角丸ピル型・コンパクト(幅約224px、連続入力の残件数表示のため
/// 従来より少しだけ幅を広げた)。
struct StatusHUDContentView: View {
    @ObservedObject var viewModel: StatusHUDViewModel

    static let panelSize = NSSize(width: 224, height: 40)

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if case .recording(let level, _) = viewModel.display {
                Spacer(minLength: 4)
                levelMeter(level: level)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.15), value: viewModel.display)
    }

    @ViewBuilder
    private var icon: some View {
        switch viewModel.display {
        case .hidden:
            EmptyView()
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundStyle(Color.red)
        case .recognizing, .formatting:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        case .fallbackWarning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.yellow)
        case .cancelled:
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(Color.white.opacity(0.7))
        case .queueFull:
            Image(systemName: "tray.full.fill")
                .foregroundStyle(Color.orange)
        case .settingUp:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .setupFailed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
        case .setupInProgressRejected:
            Image(systemName: "hourglass")
                .foregroundStyle(Color.white.opacity(0.7))
        }
    }

    private var label: String {
        switch viewModel.display {
        case .hidden:
            return ""
        case .recording(_, let pendingCount):
            return pendingCount > 0 ? "録音中 +\(pendingCount)件処理中" : "録音中"
        case .recognizing(let pendingCount):
            return pendingCount > 0 ? "認識中… 残り\(pendingCount)件" : "認識中…"
        case .formatting(let pendingCount):
            return pendingCount > 0 ? "整形中… 残り\(pendingCount)件" : "整形中…"
        case .success:
            return "挿入しました"
        case .fallbackWarning:
            return "整形なしで挿入"
        case .cancelled(let message):
            return message
        case .queueFull:
            return "処理が追いついていません"
        case .settingUp(let message):
            return message
        case .setupFailed(let message):
            return message
        case .setupInProgressRejected:
            return "セットアップ中です"
        }
    }

    /// 5本のバーによる簡易音声レベルメーター。
    @ViewBuilder
    private func levelMeter(level: Float) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let active = barIsActive(index: index, level: level)
                Capsule()
                    .fill(active ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 3, height: active ? barHeight(index: index) : 3)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private static let barThresholds: [Float] = [0.02, 0.08, 0.18, 0.32, 0.5]
    private static let barHeights: [CGFloat] = [4, 6, 9, 12, 14]

    private func barIsActive(index: Int, level: Float) -> Bool {
        level >= Self.barThresholds[index]
    }

    private func barHeight(index: Int) -> CGFloat {
        Self.barHeights[index]
    }
}
