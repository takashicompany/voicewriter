import Combine
import Foundation
import os.log

/// `Settings.sttEngine` / `Settings.sttLanguage` の変更を、次回の文字起こしから反映できるようにするラッパー。
/// Coordinatorはこのインスタンス自体を固定の`TranscriptionEngine`として保持し続け、
/// 設定画面から`reload()`が呼ばれるたびに内部で保持する実エンジン(whisper.cpp/stub)だけを差し替える。
final class DynamicTranscriptionEngine: TranscriptionEngine, ObservableObject, @unchecked Sendable {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "DynamicTranscriptionEngine")
    private let lock = NSLock()
    private var engine: TranscriptionEngine
    /// `reload()`の世代カウンタ。連続で`reload()`が呼ばれた場合、モデルロード完了(=`makeEngine`完了)の
    /// 順序が呼び出し順と一致するとは限らない(ロード所要時間はエンジン/モデルサイズに依存するため)。
    /// 世代IDにより「自分より新しい`reload()`が既に呼ばれているか」を判定し、追い越された
    /// (＝古い設定の)結果を反映しないようにする(結果の後勝ちによる設定の巻き戻り防止)。
    private let reloadGeneration = GenerationCounter()

    /// 現在実際に使われているエンジンがフォールバック(スタブ)かどうか。
    /// `Settings.sttEngine == .whisperCpp` でもモデル未配置/ロード失敗ならtrueになる。
    @Published private(set) var activeEngineIsFallback: Bool
    /// モデル未配置/ロード失敗時の警告文(フォールバックしていなければnil)。StatusBarControllerの警告表示にも使う。
    @Published private(set) var warning: String?
    /// `warning`が変化するたびに呼ばれる(SwiftUI外、StatusBarControllerの警告同期用)
    var onWarningChanged: ((String?) -> Void)?

    init() {
        let (initialEngine, initialWarning) = Self.makeEngine(log: log)
        engine = initialEngine
        activeEngineIsFallback = (initialWarning != nil)
        warning = initialWarning
    }

    /// 設定変更を反映する。次回の`transcribe`呼び出しから新しいエンジン/言語が使われる。
    ///
    /// `Self.makeEngine`は`whisper_init_from_file_with_params`相当の同期的なモデルロードを含み、
    /// 数百MB〜GB級のモデルファイルを読み込むため数百ms〜数秒かかりうる。設定UIの`onChange`から
    /// 直接呼ばれるため、ここをメインスレッドで同期実行するとUIがフリーズしてしまう。
    /// そのためロード自体はバックグラウンド(Task.detached)で行う。
    ///
    /// 連続で`reload()`が呼ばれた場合、ロード完了順序が呼び出し順と一致するとは限らないため、
    /// 世代IDを発行してからロードし、ロード完了後に「自分が最新世代か」を確認した上で
    /// エンジンの差し替えとwarning系プロパティの更新を**単一の`MainActor.run`ブロック内**で
    /// アトミックに行う(世代チェックと反映を分離すると、その間に割り込んだ新しい`reload()`の
    /// 結果と入れ替わってしまいうるため、実行コンテキストを揃えている)。
    /// 差し替え後は旧エンジンへの参照をこのタスク内に残さないため、
    /// (進行中の文字起こしが保持しているものを除き)旧エンジンは差し替え直後に解放される。
    func reload() {
        let requestedGeneration = reloadGeneration.next()
        Task.detached(priority: .userInitiated) { [weak self, log] in
            guard let self else { return }
            let (newEngine, newWarning) = Self.makeEngine(log: log)

            await MainActor.run {
                guard self.reloadGeneration.isCurrent(requestedGeneration) else {
                    // 自分より新しいreload()が既に呼ばれている。古い(追い越された)結果は破棄する。
                    log.debug("Discarding stale reload() result (generation \(requestedGeneration) superseded)")
                    return
                }
                self.replaceEngineSynchronized(with: newEngine)
                self.activeEngineIsFallback = (newWarning != nil)
                self.warning = newWarning
                self.onWarningChanged?(newWarning)
            }
        }
    }

    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
        let current = currentEngineSynchronized()
        return try await current.transcribe(samples: samples, sampleRate: sampleRate, language: language, vocabularyHint: vocabularyHint, vadEnabled: vadEnabled)
    }

    /// asyncコンテキストから直接NSLockを呼ばないよう、同期関数越しにロックする。
    private func currentEngineSynchronized() -> TranscriptionEngine {
        lock.lock()
        defer { lock.unlock() }
        return engine
    }

    /// asyncコンテキストから直接NSLockを呼ばないよう、同期関数越しにロックする。
    /// `engine`を差し替えた時点で旧エンジンへの参照はこの関数のスコープを抜けるため、
    /// (進行中の文字起こしが保持しているものを除き)旧エンジンは差し替え直後に解放される。
    private func replaceEngineSynchronized(with newEngine: TranscriptionEngine) {
        lock.lock()
        defer { lock.unlock() }
        engine = newEngine
    }

    /// 設定に従って文字起こしエンジンを構築する。
    /// whisperCpp選択時にモデル未配置/ロード失敗ならStubへフォールバックし、警告メッセージを返す。
    static func makeEngine(log: Logger) -> (TranscriptionEngine, String?) {
        switch Settings.sttEngine {
        case .stub:
            return (StubTranscriptionEngine(), nil)

        case .whisperCpp:
            let modelURL = WhisperCppEngine.defaultModelURL
            guard WhisperCppEngine.isModelAvailable(at: modelURL) else {
                let message = "whisper.cppモデルが未配置のため、スタブ文字起こしで動作しています。設定 > 音声認識 からダウンロードするか、scripts/download-model.sh を実行してモデルを配置してください。(\(modelURL.path))"
                log.warning("\(message, privacy: .public)")
                return (StubTranscriptionEngine(), message)
            }
            do {
                let engine = try WhisperCppEngine(modelURL: modelURL)
                return (engine, nil)
            } catch {
                let message = "whisper.cppモデルの読み込みに失敗したため、スタブ文字起こしで動作しています: \(error)"
                log.error("\(message, privacy: .public)")
                return (StubTranscriptionEngine(), message)
            }
        }
    }
}
