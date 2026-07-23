import Foundation
import os.log

/// whisper.cppモデル(ggml-large-v3-turbo)を設定画面からダウンロードするための、
/// `scripts/download-model.sh` と同等のロジックをSwiftネイティブ(URLSession)で行うダウンローダー。
/// 進捗をSwiftUIへ公開するため`ObservableObject`に準拠する。
@MainActor
final class ModelDownloader: NSObject, ObservableObject {
    enum State: Equatable, Sendable {
        case idle
        case downloading(progress: Double, receivedBytes: Int64, totalBytes: Int64)
        case success
        case failure(String)
    }

    static let modelURLString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    /// ggml-large-v3-turbo.bin は約1.6GB。極端に小さいファイルは壊れたダウンロードとみなす(download-model.shと同じ閾値)。
    static let minExpectedSize: Int64 = 1_000_000_000

    @Published private(set) var state: State = .idle

    private let log = Logger(subsystem: "dev.voicewriter.app", category: "ModelDownloader")
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    /// 世代カウンタ。`startDownload`のたびに増分し、ダウンロードタスクの`taskDescription`に埋め込む。
    /// `cancel()`時にも増分することで、キャンセル済み(または既に古い)タスクからの遅延コールバックが
    /// 現在の世代と一致せず無視されるようにする(キャンセル後に届いた完了通知が状態を復活させるバグの修正)。
    /// ロック保護されているため、`URLSessionDelegate`のnonisolatedなコールバックからMainActorへ
    /// ホップせずに同期的に判定できる(コピー処理前の世代チェックに使う)。
    private let generation = GenerationCounter()

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: DelegateProxy(owner: self), delegateQueue: nil)
    }

    /// `state`からダウンロードを開始してよいかどうか(純粋関数・テスト用に切り出し)。
    /// `.idle`だけでなく`.failure`からの「再試行」も許可する
    /// (以前は`.idle`以外を拒否しており、失敗後の再試行ボタンが機能しなかった)。
    /// MainActor隔離状態に触れない純粋関数なので、テストから同期的に呼べるよう`nonisolated`にする。
    nonisolated static func canStartDownload(from state: State) -> Bool {
        switch state {
        case .idle, .failure:
            return true
        case .downloading, .success:
            return false
        }
    }

    func startDownload() {
        guard Self.canStartDownload(from: state) else { return }
        guard hasEnoughDiskSpace() else {
            state = .failure("空き容量が不足しています。約2.5GB以上の空き容量を確保してから再度お試しください。")
            return
        }
        guard let url = URL(string: Self.modelURLString) else { return }

        let destinationDirectory = WhisperCppEngine.defaultModelURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let currentGeneration = generation.next()
        state = .downloading(progress: 0, receivedBytes: 0, totalBytes: 0)
        let downloadTask = session.downloadTask(with: url)
        downloadTask.taskDescription = String(currentGeneration)
        task = downloadTask
        downloadTask.resume()
        log.info("Model download started")
    }

    func cancel() {
        generation.next()
        task?.cancel()
        task = nil
        state = .idle
    }

    /// ダウンロード〜配置に必要な空き容量。ダウンロード先一時ファイルは最終配置先と同一ボリューム内で
    /// `rename`されるだけ(コピーではない)ため、実質モデル1個分(約1.6GB)+安全マージンで足りる。
    /// ユーザー向けメッセージ(約2.5GB)と一致させておく。
    private static let requiredFreeSpace: Int64 = 2_500_000_000

    private func hasEnoughDiskSpace() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attrs[.systemFreeSize] as? Int64 else {
            return true // 取得できない場合は楽観的に続行する(download-model.sh側でも最終的にサイズ検証される)
        }
        return free > Self.requiredFreeSpace
    }

    // MARK: - Delegate callbacks (メインアクターへdispatchしてから状態を更新する)

    fileprivate func handleProgress(bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpected: Int64) {
        // 状態遷移の単調性: 既に`.success`/`.failure`(終了状態)へ到達済みの場合、
        // 遅延して届いたprogressコールバックで上書きしない。
        guard case .downloading = state else { return }
        let progress = totalBytesExpected > 0 ? Double(totalBytesWritten) / Double(totalBytesExpected) : 0
        state = .downloading(progress: progress, receivedBytes: totalBytesWritten, totalBytes: totalBytesExpected)
    }

    fileprivate func handleFinishedDownload(temporaryLocation: URL) {
        // 状態遷移の単調性: 既に終了状態へ到達済みなら何もしない(通常はここに来る前に
        // 世代チェックで弾かれているはずだが、念のための防御)。
        guard case .downloading = state else { return }
        let destinationURL = WhisperCppEngine.defaultModelURL
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: temporaryLocation.path)
            let size = (attrs[.size] as? Int64) ?? 0
            guard size >= Self.minExpectedSize else {
                try? FileManager.default.removeItem(at: temporaryLocation)
                state = .failure("ダウンロードされたファイルが小さすぎます(\(size) bytes)。ネットワーク接続を確認して再度お試しください。")
                return
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                // 既存モデルを先に削除してから移動すると、移動に失敗した場合に旧モデルまで失ってしまう。
                // `replaceItemAt`はアトミックな置き換えのため、失敗時も既存ファイルが失われない。
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryLocation)
            } else {
                try FileManager.default.moveItem(at: temporaryLocation, to: destinationURL)
            }
            log.info("Model download completed: \(destinationURL.path, privacy: .public)")
            state = .success
        } catch {
            try? FileManager.default.removeItem(at: temporaryLocation)
            log.error("Failed to move downloaded model: \(error.localizedDescription, privacy: .public)")
            state = .failure("ファイルの保存に失敗しました: \(error.localizedDescription)")
        }
    }

    fileprivate func handleCompletion(error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        // 状態遷移の単調性: 既に`.success`へ到達済みなら(通常はdidFinishDownloadingTo後の
        // `didCompleteWithError(nil)`のみのはずだが)上書きしない。
        guard case .downloading = state else { return }
        log.error("Model download failed: \(error.localizedDescription, privacy: .public)")
        state = .failure(error.localizedDescription)
    }

    /// この`task`が現在の世代(直近の`startDownload`)に属するものか。
    /// `cancel()`後や、新しいダウンロードを開始した後に届く古いタスクからの遅延コールバックを
    /// 無視するために使う(`taskDescription`に埋め込んだ世代IDと比較する)。
    /// `generation`がロック保護された`GenerationCounter`のため、MainActorへホップせず
    /// nonisolatedなURLSessionDelegateコールバックから同期的に呼べる
    /// (1.6GBの一時ファイルコピー前に世代チェックするために必要)。
    nonisolated fileprivate func isCurrentGeneration(of task: URLSessionTask) -> Bool {
        guard let description = task.taskDescription, let taskGeneration = Int(description) else { return false }
        return generation.isCurrent(taskGeneration)
    }

    /// URLSessionDelegateはNSObjectのnonisolatedなメソッドとして呼ばれるため、
    /// `ModelDownloader`本体(@MainActor)とは別に軽量なプロキシを介してメインアクターへ橋渡しする。
    private final class DelegateProxy: NSObject, URLSessionDownloadDelegate {
        weak var owner: ModelDownloader?

        init(owner: ModelDownloader) {
            self.owner = owner
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            Task { @MainActor [owner] in
                guard let owner, owner.isCurrentGeneration(of: downloadTask) else { return }
                owner.handleProgress(
                    bytesWritten: bytesWritten,
                    totalBytesWritten: totalBytesWritten,
                    totalBytesExpected: totalBytesExpectedToWrite
                )
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // 世代チェックを1.6GB相当のコピーより前に行う。`isCurrentGeneration`はロック保護された
            // `GenerationCounter`を読むだけなのでMainActorへホップせず同期的に呼べる。
            // 既にキャンセル済み/古い世代なら、無駄な大容量コピーI/Oを行わずここで打ち切る。
            guard let owner, owner.isCurrentGeneration(of: downloadTask) else {
                return
            }
            // `location`はこのメソッドを抜けると削除されるため、同期的に安全な場所へ退避してから非同期処理へ渡す。
            // 退避先は最終配置先(~/Library/Application Support/Voicewriter/models)と同じディレクトリ内にすることで、
            // 同一ボリューム内の`rename`で完結させる(コピーだと一時的にモデル約2個分のディスクを消費してしまうため)。
            let tempCopyURL = WhisperCppEngine.defaultModelURL
                .deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("part")
            do {
                // `moveItem`は同一ボリュームなら`rename(2)`相当で即座に完了し、追加のディスク消費が発生しない。
                // (URLSessionの一時ファイル置き場が万一別ボリュームの場合のみ、内部的にコピー+削除にフォールバックする)
                try FileManager.default.moveItem(at: location, to: tempCopyURL)
            } catch {
                Task { @MainActor [owner] in
                    guard owner.isCurrentGeneration(of: downloadTask) else { return }
                    owner.state = .failure("ダウンロードファイルの処理に失敗しました: \(error.localizedDescription)")
                }
                return
            }
            Task { @MainActor [owner] in
                guard owner.isCurrentGeneration(of: downloadTask) else {
                    // コピー中にキャンセル/新しいダウンロード開始で世代が古くなった。
                    // 状態を復活させず、コピーした一時ファイルだけ掃除する。
                    try? FileManager.default.removeItem(at: tempCopyURL)
                    return
                }
                owner.handleFinishedDownload(temporaryLocation: tempCopyURL)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            Task { @MainActor [owner] in
                guard let owner, owner.isCurrentGeneration(of: task) else { return }
                owner.handleCompletion(error: error)
            }
        }
    }
}
