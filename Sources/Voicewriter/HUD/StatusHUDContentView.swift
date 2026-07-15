import SwiftUI

/// superwhisper/Wispr Flow風の小さなピル型パネルの中身。
/// ダーク寄りの半透明マテリアル・角丸ピル型・コンパクト(幅約200px)。
struct StatusHUDContentView: View {
    @ObservedObject var viewModel: StatusHUDViewModel

    static let panelSize = NSSize(width: 208, height: 40)

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if case .recording(let level) = viewModel.display {
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
        }
    }

    private var label: String {
        switch viewModel.display {
        case .hidden: return ""
        case .recording: return "録音中"
        case .recognizing: return "認識中…"
        case .formatting: return "整形中…"
        case .success: return "挿入しました"
        case .fallbackWarning: return "整形なしで挿入"
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
