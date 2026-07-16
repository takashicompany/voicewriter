import CryptoKit
import Foundation
import os.log

/// アプリ起動時にVAD(Silero-VAD)モデルが未配置であれば、バックグラウンドで自動的に
/// ダウンロード・配置する。
///
/// **経緯**: 当初はメインのSTTモデル(約1.6GB、`ModelDownloader`経由でユーザーが明示的に
/// ボタンを押してダウンロード)と同様、VADモデルも`scripts/download-vad-model.sh`による
/// 手動配置のみとし、自動ダウンロードは見送る方針で設計していた。しかし無音ハルシネーション
/// 対策の実装過程で、実際に無音のみのWAVをwhisper.cppに通して検証したところ、
/// VAD(第3層)は「発話区間が検出されなければ空文字を返す」という形で最も直接的かつ
/// 確実にハルシネーションを防いでいた一方、他の対策(no_speech_thold等のデコードパラメータ)は
/// 自信を持って生成されたハルシネーションには効果が無いことも実測で確認した
/// (`WhisperCppEngine.swift`の`no_speech_thold`コメント参照)。VADが多層防御の中でも
/// 特に効果が高いことが実証された以上、モデルが未配置のままでは大半のユーザーにとって
/// この防御層が機能しないことになり、対策として片手落ちになる。VADモデルは約885KBと
/// メインSTTモデルの1/1800程度のサイズであり、ダウンロードによるユーザー体験への影響も
/// 軽微と判断し、自動ダウンロードへ方針転換した(既存の`scripts/download-vad-model.sh`による
/// 手動配置・オフライン環境での代替手段は引き続き利用可能)。
///
/// - ダウンロード元・SHA-256は`scripts/download-vad-model.sh`と完全に同一のもの
///   (`https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin`)を使う。
/// - ベストエフォート: 失敗(ネットワーク不通・検証失敗等)してもアプリの起動・他の機能には
///   一切影響しない(ログに警告を出すのみ)。失敗時は次回起動時に再試行される。
/// - UIをブロックしない(`Task.detached`でバックグラウンド実行)。
enum VadModelAutoProvisioner {
    private static let log = Logger(subsystem: "dev.voicewriter.app", category: "VadModelAutoProvisioner")

    /// `scripts/download-vad-model.sh`と同一のダウンロード元URL。
    private static let modelURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!
    /// `scripts/download-vad-model.sh`と同一の期待SHA-256(2026-07-15検証済み)。
    private static let expectedSHA256 = "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
    /// `scripts/download-vad-model.sh`と同一の最小サイズ下限(実サイズ885,098バイトに対する下限チェック)。
    private static let minimumExpectedSize = 800_000

    /// VADモデルが既に配置済みなら何もしない。未配置の場合のみバックグラウンドでダウンロードを開始する。
    /// 呼び出し元(`AppDelegate`)をブロックしない。
    static func provisionIfNeeded() {
        guard !WhisperCppEngine.isVadModelAvailable() else { return }
        Task.detached(priority: .utility) {
            await downloadAndInstall()
        }
    }

    private static func downloadAndInstall() async {
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: modelURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                log.warning("VAD model auto-download failed: unexpected response \(String(describing: response), privacy: .public)")
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            guard let size = attrs[.size] as? Int, size >= minimumExpectedSize else {
                log.warning("VAD model auto-download failed: downloaded file too small")
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            let data = try Data(contentsOf: tempURL)
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            guard hex == expectedSHA256 else {
                log.warning("VAD model auto-download failed: sha256 mismatch (expected=\(expectedSHA256, privacy: .public) actual=\(hex, privacy: .public))")
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            let destination = WhisperCppEngine.defaultVadModelURL
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 既存の(壊れた/古い)ファイルがあれば置き換える。
            _ = try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            log.info("VAD model auto-downloaded and installed at \(destination.path, privacy: .public)")
        } catch {
            log.warning("VAD model auto-download failed: \(String(describing: error), privacy: .public)")
        }
    }
}
