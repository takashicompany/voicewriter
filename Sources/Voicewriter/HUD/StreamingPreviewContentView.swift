import SwiftUI

/// SpeechAnalyzerストリーミングモードのライブプレビュー表示。既存`StatusHUDContentView`と同じ
/// 視覚言語(ダーク寄りの半透明マテリアル・角丸)を踏襲しつつ、確定テキストは白・未確定
/// (volatile)テキストは薄色で区別して表示する。
struct StreamingPreviewContentView: View {
    @ObservedObject var viewModel: StreamingPreviewViewModel

    static let panelSize = NSSize(width: 560, height: 88)

    var body: some View {
        Group {
            switch viewModel.display {
            case .hidden:
                Color.clear
            case .visible(let finalizedText, let volatileText):
                bubble {
                    Text(finalizedText).foregroundStyle(.white)
                        + Text(volatileText).foregroundStyle(Color.white.opacity(0.5))
                }
            case .preparing(let progress):
                bubble {
                    Text(Self.preparingLabel(progress: progress)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .animation(.easeInOut(duration: 0.1), value: viewModel.display)
    }

    private static func preparingLabel(progress: Double?) -> String {
        if let progress {
            return "初回セットアップ中: 日本語モデルをダウンロードしています… \(Int((progress * 100).rounded()))%"
        }
        return "初回セットアップ中: 日本語モデルを準備しています…"
    }

    @ViewBuilder
    private func bubble(@ViewBuilder text: () -> some View) -> some View {
        text()
            .font(.system(size: 15, weight: .medium))
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}
