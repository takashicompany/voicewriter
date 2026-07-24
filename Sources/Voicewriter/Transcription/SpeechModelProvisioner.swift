import Foundation
import Speech
import os.log

/// SpeechAnalyzerストリーミングモードで使う日本語モデル資産(`AssetInventory`)の状態確認・
/// ダウンロードを行う。whisper.cppモデル用の`ModelDownloader`と同様、進捗をSwiftUIへ公開するための
/// `ObservableObject`。
///
/// クラス自体はmacOS 26未満でも(SwiftUIの`@State`/`@StateObject`から素直に保持できるよう)
/// 利用可能にしておき、Speech関連APIを呼ぶ箇所だけを`#available(macOS 26.0, *)`でガードする
/// (`SpeechAnalyzerEngine`のようにクラス全体を`@available`にすると、これを保持する
/// `TranscriptionSettingsView`側の型宣言まで可用性の伝播に巻き込まれてしまうため)。
@MainActor
final class SpeechModelProvisioner: ObservableObject {
    enum State: Equatable {
        case checking
        /// macOS 26未満、またはSpeechTranscriberがja非対応の環境。
        case unsupported(reason: String)
        case notInstalled
        case downloading(progress: Double)
        case installed
        case failure(String)
    }

    @Published private(set) var state: State = .checking

    private let log = Logger(subsystem: "dev.voicewriter.app", category: "SpeechModelProvisioner")
    private var progressPollTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    /// 現在の状態(`AssetInventory`照会)を反映する。設定画面表示時(`.task`)に呼ぶ。
    func refreshStatus() async {
        guard #available(macOS 26.0, *) else {
            state = .unsupported(reason: "この機能にはmacOS 26以降が必要です")
            return
        }
        guard let locale = await StreamingTranscriptionAvailability.resolvedLocale() else {
            state = .unsupported(reason: "この端末では日本語のSpeechTranscriberが利用できません")
            return
        }
        // `SpeechAnalyzerSession`は設定次第でプレビュー用+確定用の2モジュール、または確定用のみの
        // 1モジュール構成を使う。ここでは両方まとめて状態確認することで、実際に使われうる構成の
        // 上位集合をカバーする(`SpeechTranscriberFactory`のドキュメントコメント参照)。
        let modules = Self.makeAllTranscribers(locale: locale)
        let status = await AssetInventory.status(forModules: modules)
        if case .installed = status {
            state = .installed
        } else {
            state = .notInstalled
        }
    }

    /// モデル資産のダウンロードを開始する。`.notInstalled`/`.failure`からのみ開始できる。
    func startDownload() {
        switch state {
        case .notInstalled, .failure:
            break
        case .checking, .unsupported, .downloading, .installed:
            return
        }
        state = .downloading(progress: 0)
        downloadTask = Task { [weak self] in
            await self?.performDownload()
        }
    }

    private func performDownload() async {
        guard #available(macOS 26.0, *) else {
            state = .unsupported(reason: "この機能にはmacOS 26以降が必要です")
            return
        }
        guard let locale = await StreamingTranscriptionAvailability.resolvedLocale() else {
            state = .unsupported(reason: "この端末では日本語のSpeechTranscriberが利用できません")
            return
        }
        let modules = Self.makeAllTranscribers(locale: locale)
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                // 追加のダウンロードが不要(既にインストール済み)。
                state = .installed
                return
            }
            let progress = request.progress
            progressPollTask = Task { [weak self] in
                while !progress.isFinished, !Task.isCancelled {
                    self?.state = .downloading(progress: progress.fractionCompleted)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            try await request.downloadAndInstall()
            progressPollTask?.cancel()
            progressPollTask = nil
            state = .installed
            log.info("SpeechAnalyzer model asset installed for locale \(locale.identifier(.bcp47), privacy: .public)")
        } catch {
            progressPollTask?.cancel()
            progressPollTask = nil
            log.error("SpeechAnalyzer model asset installation failed: \(String(describing: error), privacy: .public)")
            state = .failure("モデル資産のダウンロードに失敗しました: \(error.localizedDescription)")
        }
    }

    /// `SpeechAnalyzerSession`が実際に使いうる全モジュール(プレビュー用+確定用)を返す。
    /// `AssetInventory`の状態確認・ダウンロードはこの上位集合に対して行う(詳細は
    /// `SpeechTranscriberFactory`のドキュメントコメント参照)。
    @available(macOS 26.0, *)
    private static func makeAllTranscribers(locale: Locale) -> [any SpeechModule] {
        [
            SpeechTranscriberFactory.makePreviewTranscriber(locale: locale),
            SpeechTranscriberFactory.makeFinalTranscriber(locale: locale)
        ]
    }
}
