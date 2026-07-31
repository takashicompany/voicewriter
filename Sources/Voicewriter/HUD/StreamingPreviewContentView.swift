import SwiftUI

/// SpeechAnalyzerストリーミングモードのライブプレビュー表示。既存`StatusHUDContentView`と同じ
/// 視覚言語(ダーク寄りの半透明マテリアル・角丸)を踏襲しつつ、確定テキストは白・未確定
/// (volatile)テキストは薄色で区別して表示する。
struct StreamingPreviewContentView: View {
    @ObservedObject var viewModel: StreamingPreviewViewModel

    static let panelSize = NSSize(width: 560, height: 88)

    /// プレビューパネル背景の不透明度(0.8 = 透明20%)。状態表示HUD(`StatusHUDContentView`)は
    /// 別パネルであり、こちらの変更の影響を受けない。
    static let backgroundOpacity: Double = 0.7

    var body: some View {
        Group {
            switch viewModel.display {
            case .hidden:
                Color.clear
            case .visible(let finalizedText, let volatileText, let isProcessing):
                bubble {
                    HStack(alignment: .top, spacing: 10) {
                        if isProcessing {
                            processingIndicator
                        }
                        (Text(finalizedText).foregroundStyle(.white)
                            + Text(volatileText).foregroundStyle(Color.white.opacity(0.5)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

    /// 録音終了後、確定〜整形〜挿入が終わるまでの間、認識テキストの左に重ねる「変換中…」表示。
    /// 状態表示HUD(`StatusHUDContentView`)の「認識中…/整形中…」と同じ視覚言語
    /// (小さいスピナー+白のラベル)を踏襲する。パネルは固定高さのため、行を増やさず横並びで置く。
    @ViewBuilder
    private var processingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("変換中…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(1)
        }
        .fixedSize()
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
                // 背景の不透明度は70%(=透明30%)。マテリアル(すりガラス)はそれ自体がほぼ不透明な
                // 描画になり、重ねると全体opacityを掛けても実際には透けて見えない(実機で確認)。
                // そのため単純な「黒80%」の半透明塗りにし、確実に下地が20%透けるようにする。
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(Self.backgroundOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}
