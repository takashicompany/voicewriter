import AppKit
import Foundation
import KeyboardShortcuts
import os.log

enum AppState {
    case idle
    case recording
    case transcribing
}

/// ハルシネーション対策(多層防御)により、文字起こし結果が得られず(または既知の
/// ハルシネーション定型句のみと判定され)録音サイクルがスキップされた理由。
/// HUD表示の出し分け専用の付加情報であり、状態機械のロジックには影響しない。
enum RecordingSkipReason: Equatable {
    /// 第1層: 録音実効長(キー押下〜離しの長さ、プリロール除く)が閾値未満だった。
    case tooShort
    /// 第2〜5層: 発話とみなせるエネルギーが無い、VAD/no_speech_probにより発話区間が
    /// 検出されなかった、または既知のハルシネーション定型句のみと判定された。
    case silence
}

/// どちらの操作方法で録音が開始されたか(PTTのkeyUpとトグルのkeyUpを混同しないため)
private enum ActivationSource {
    case pushToTalk
    case toggle
}

/// `.transcribing`中の内部フェーズ(HUD表示専用の付加情報)。
/// `AppState`自体はこの間ずっと`.transcribing`のままであり、状態機械のロジックには一切影響しない。
enum TranscriptionPhase {
    /// whisper.cppによる音声認識中
    case recognizing
    /// 認識結果をLLMで整形中
    case formatting
}

/// idle / recording / transcribing の状態機械。全体の司令塔。
@MainActor
final class Coordinator: AudioCaptureEngineDelegate {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "Coordinator")

    private(set) var state: AppState = .idle {
        didSet {
            log.info("State: \(String(describing: self.state))")
            onStateChanged?(state)
            updateCancelShortcutEnabled()
        }
    }

    /// 状態が変わるたびに呼ばれる(StatusBarControllerがアイコン更新に使う)
    var onStateChanged: ((AppState) -> Void)?
    /// 文字起こし結果が得られるたびに呼ばれる。録音開始時点でのフロントモストアプリ(挿入先の想定先)も渡す。
    var onTranscriptionResult: ((String, NSRunningApplication?) -> Void)?
    /// 文字起こし中に新たな録音操作が要求され、無視された(busy)ときに呼ばれる。
    /// メニューバー/サウンドでのフィードバック用。
    var onBusyRecordingAttempt: (() -> Void)?
    /// 録音を継続できない致命的なエラーが起きた際に呼ばれる(メニューバー警告用)。
    var onFatalAudioError: ((String) -> Void)?
    /// LLM整形が失敗し、原文へフォールバックした際に呼ばれる(メニューバーの軽い警告用)。
    var onFormattingFailed: ((String) -> Void)?
    /// `.transcribing`中の内部フェーズが変わるたびに呼ばれる(HUDの「認識中/整形中」表示切替用)。
    /// 表示専用の通知であり、状態機械のロジックには影響しない。
    var onPhaseChanged: ((TranscriptionPhase) -> Void)?
    /// ハルシネーション対策(多層防御)により文字起こし結果がスキップされた際に呼ばれる。
    /// テキスト挿入もLLM整形も行わない(HUDの「短すぎるためキャンセル」「無音のためキャンセル」表示用)。
    var onRecordingSkipped: ((RecordingSkipReason) -> Void)?

    private let audioEngine: AudioCaptureEngineControlling
    private let transcriptionEngine: TranscriptionEngine
    /// 音声認識結果の整形に使うLLMフォーマッタ。`nil`なら整形自体を行わない(未整形のまま挿入)。
    private let textFormatter: TextFormatter?
    private var activationSource: ActivationSource?
    /// 録音開始時点でのフロントモストアプリケーション(挿入先フォーカスのガード用)。
    private var recordingFrontmostApp: NSRunningApplication?
    /// `.transcribing`中にキャンセル(Esc)が押された場合にtrueになり、
    /// 結果が得られても挿入せず破棄する(whisper_full自体は中断しない)。
    private var discardPendingTranscriptionResult = false

    /// ハルシネーション対策(多層防御)の第1層: 録音実効長(キー押下〜離しの長さ、プリロール除く)の
    /// 最短閾値。これ未満なら文字起こし自体を行わない(設定不要のハードコード)。
    /// 誤ってホットキーに触れてすぐ離した場合の無音ハルシネーションを、whisper_full呼び出し前の
    /// 最も早い段階で弾くためのガード。
    static let minimumEffectiveRecordingDuration: TimeInterval = 0.3

    /// 現在時刻を取得するためのクロージャ。既定は実時計(`Date.init`)。
    /// テストでは`beginPushToTalk()`〜`endPushToTalk()`が実時間ではなく同期的に(数マイクロ秒で)
    /// 呼ばれるため、実時計のままだと第1層の最短録音時間ガードに常に引っかかってしまう。
    /// そのため単調に増加する値を返すフェイクへ差し替えられるようにしている
    /// (`minimumEffectiveRecordingDuration`自体は変更せず、時刻の取得元だけを注入する設計)。
    private let now: () -> Date
    /// 録音開始時刻(`now()`で取得)。録音実効長の算出に使う。
    private var recordingStartedAt: Date?

    init(
        audioEngine: AudioCaptureEngineControlling,
        transcriptionEngine: TranscriptionEngine,
        textFormatter: TextFormatter? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.audioEngine = audioEngine
        self.transcriptionEngine = transcriptionEngine
        self.textFormatter = textFormatter
        self.now = now
        self.audioEngine.delegate = self
        updateCancelShortcutEnabled()
    }

    /// 現在の`state`に基づいてキャンセルショートカットのenable/disableを再適用する。
    ///
    /// 呼び出しが必要な2箇所:
    /// 1. `HotkeyManager`の構築(=`KeyboardShortcuts.onKeyDown/onKeyUp`によるハンドラ登録)は、
    ///    対象のショートカットを無条件に再登録(有効化)してしまう。そのためCoordinator.init時点で
    ///    `updateCancelShortcutEnabled()`によりidle状態のEscをdisableしていても、その後の
    ///    `HotkeyManager`構築で再度enableされてしまう(起動時にEscが一瞬有効になる問題)。
    /// 2. 設定画面の`KeyboardShortcuts.Recorder`でキャンセルショートカットが再割当てされると、
    ///    ライブラリ側の`setShortcut`が無条件に`register`(有効化)してしまうため、idle時に
    ///    disableしていたはずのEscが再び有効になってしまう(`ShortcutsSettingsView`の
    ///    `Recorder`の`onChange`から呼ぶ)。
    func refreshShortcutEnablement() {
        updateCancelShortcutEnabled()
    }

    // MARK: - Push to talk

    func beginPushToTalk() {
        guard state == .idle else {
            if state == .transcribing { onBusyRecordingAttempt?() }
            return
        }
        activationSource = .pushToTalk
        recordingFrontmostApp = NSWorkspace.shared.frontmostApplication
        recordingStartedAt = now()
        state = .recording
        audioEngine.startRecording()
    }

    func endPushToTalk() {
        guard state == .recording, activationSource == .pushToTalk else { return }
        activationSource = nil
        state = .transcribing
        audioEngine.stopRecording()
    }

    // MARK: - Toggle

    func toggleRecording() {
        switch state {
        case .idle:
            activationSource = .toggle
            recordingFrontmostApp = NSWorkspace.shared.frontmostApplication
            recordingStartedAt = now()
            state = .recording
            audioEngine.startRecording()
        case .recording where activationSource == .toggle:
            activationSource = nil
            state = .transcribing
            audioEngine.stopRecording()
        case .transcribing:
            onBusyRecordingAttempt?()
        default:
            // PTT中のトグル操作は無視
            break
        }
    }

    // MARK: - Cancel

    /// 録音中: 蓄積分を破棄してidleへ戻す。
    /// 文字起こし中: whisper_full自体は中断しないが、結果が出ても挿入せず破棄するようフラグを立てる。
    func cancelRecording() {
        switch state {
        case .recording:
            activationSource = nil
            state = .idle
            audioEngine.cancelRecording()
        case .transcribing:
            discardPendingTranscriptionResult = true
            log.info("Cancel requested during transcribing; pending result will be discarded")
        case .idle:
            break
        }
    }

    // MARK: - Global shortcut enablement (Escの常時グローバル登録を避ける)

    /// 録音中/文字起こし中のみキャンセルショートカット(既定Esc)を有効化する。
    /// idle時は無効化(unregister)し、他アプリのEscを奪わないようにする。
    private func updateCancelShortcutEnabled() {
        switch state {
        case .idle:
            KeyboardShortcuts.disable(.cancelRecording)
        case .recording, .transcribing:
            KeyboardShortcuts.enable(.cancelRecording)
        }
    }

    // MARK: - LLM整形

    /// `Settings.formattingEnabled`かつフォーマッタが注入されている場合のみLLM整形を試みる。
    /// 整形失敗(Ollama未起動・タイムアウト・タグ欠落等)は握りつぶし、**必ず**原文(`rawText`)へ
    /// フォールバックする。フォールバックした場合は`onFormattingFailed`でメニューバーへ軽い警告を出す
    /// (致命的ではないため、挿入自体は継続する)。
    /// LLM整形を実際に試みるかどうか。`applyFormattingIfNeeded`のガード条件と、
    /// HUDへのフェーズ通知(`onPhaseChanged`)判定で共有する(整形処理自体のロジックは変えず、
    /// 条件を名前付きで共有するだけ)。
    private func willAttemptFormatting(for rawText: String) -> Bool {
        Settings.formattingEnabled && textFormatter != nil && !rawText.isEmpty
    }

    private func applyFormattingIfNeeded(to rawText: String) async -> String {
        guard willAttemptFormatting(for: rawText), let textFormatter else {
            return rawText
        }
        do {
            return try await textFormatter.format(text: rawText, vocabularyHint: Settings.sttVocabularyHint)
        } catch {
            log.warning("Text formatting failed; falling back to raw transcription: \(String(describing: error), privacy: .public)")
            onFormattingFailed?("LLM整形に失敗したため、未整形のテキストを使用しました: \(error)")
            return rawText
        }
    }

    // MARK: - AudioCaptureEngineDelegate

    nonisolated func audioCaptureEngine(_ engine: AudioCaptureEngineControlling, didFinishRecording samples: [Float], sampleRate: Double) {
        Task { @MainActor in
            // 録音長上限などによりAudioCaptureEngine側が自発的に停止した場合、
            // まだ.transcribingへ遷移していないことがあるためここで揃える。
            if state == .recording {
                activationSource = nil
                state = .transcribing
            }
            let frontmostAppAtRecordingStart = recordingFrontmostApp

            // ハルシネーション対策(多層防御)の第1層: 録音実効長(キー押下〜離しの長さ、プリロール除く)
            // が閾値未満なら、whisper_full自体を呼ばずここで打ち切る。
            let effectiveDuration = recordingStartedAt.map { now().timeIntervalSince($0) } ?? .infinity
            recordingStartedAt = nil
            guard effectiveDuration >= Self.minimumEffectiveRecordingDuration else {
                log.info("Recording effective duration (\(effectiveDuration, privacy: .public)s) below minimum (\(Self.minimumEffectiveRecordingDuration, privacy: .public)s); skipping transcription")
                finishSkipped(reason: .tooShort)
                return
            }

            // ハルシネーション対策(多層防御)の第2層: 先頭無音トリム後の実効サンプルに
            // 発話とみなせるエネルギーが無ければ、同じくwhisper_full自体を呼ばず打ち切る。
            let trimmedForEnergyCheck = AudioPreprocessing.trimLeadingSilence(samples: samples, sampleRate: sampleRate)
            guard AudioPreprocessing.hasSufficientEnergy(samples: trimmedForEnergyCheck, sampleRate: sampleRate) else {
                log.info("No sufficient speech energy detected in recording; skipping transcription")
                finishSkipped(reason: .silence)
                return
            }

            onPhaseChanged?(.recognizing)
            do {
                let transcribedText = try await transcriptionEngine.transcribe(samples: samples, sampleRate: sampleRate)
                log.info("Transcription result: \(transcribedText, privacy: .private)")

                // ハルシネーション対策(多層防御)の第5層(最終防衛線): 出力全体が既知の
                // ハルシネーション定型句のみで構成される場合は空文字扱いにする。
                // (第3層のVAD・第4層のno_speech_probセグメントフィルタは`transcriptionEngine`
                //  内部、すなわち`transcribedText`が既に反映された結果として届く)
                var rawText = transcribedText
                if !rawText.isEmpty, HallucinationFilter.isLikelyHallucination(rawText) {
                    log.info("Discarding output that matches a known hallucination phrase")
                    rawText = ""
                }

                guard !rawText.isEmpty else {
                    finishSkipped(reason: .silence)
                    return
                }

                // LLM整形(設定でON、かつフォーマッタが注入されている場合のみ)。状態は`.transcribing`の
                // ままなので、メニューバーは整形中も「処理中」表示を継続する。整形中にEscでキャンセルが
                // 要求された場合も、下の`discardPendingTranscriptionResult`チェックが整形完了後に行われる
                // ため取りこぼさない。
                if willAttemptFormatting(for: rawText) {
                    onPhaseChanged?(.formatting)
                }
                let finalText = await applyFormattingIfNeeded(to: rawText)

                // `await`後に改めてプロパティを読む(先読みしない)。文字起こし/整形実行中(await中)に
                // Escでキャンセルが要求された場合も確実に反映するため。
                if discardPendingTranscriptionResult {
                    log.info("Discarding transcription result due to cancel during transcribing")
                } else {
                    onTranscriptionResult?(finalText, frontmostAppAtRecordingStart)
                }
            } catch {
                log.error("Transcription failed: \(error.localizedDescription)")
            }
            discardPendingTranscriptionResult = false
            recordingFrontmostApp = nil
            if state == .transcribing {
                state = .idle
            }
        }
    }

    /// ハルシネーション対策の各層で「文字起こし自体をスキップ/空文字として扱う」と判定した際の
    /// 後始末(通常の完了経路と同じ状態リセットを行った上で、`onTranscriptionResult`の代わりに
    /// `onRecordingSkipped`を呼ぶ)。テキスト挿入もLLM整形も行わない。
    private func finishSkipped(reason: RecordingSkipReason) {
        if discardPendingTranscriptionResult {
            log.info("Recording was already flagged for cancel-discard; skip notification suppressed")
        } else {
            onRecordingSkipped?(reason)
        }
        discardPendingTranscriptionResult = false
        recordingFrontmostApp = nil
        if state == .transcribing {
            state = .idle
        }
    }

    nonisolated func audioCaptureEngineDidCancelRecording(_ engine: AudioCaptureEngineControlling) {
        Task { @MainActor in
            if state != .idle {
                state = .idle
            }
        }
    }

    nonisolated func audioCaptureEngine(_ engine: AudioCaptureEngineControlling, didEncounterFatalError message: String) {
        Task { @MainActor in
            log.error("Audio engine fatal error: \(message, privacy: .public)")
            if state != .idle {
                activationSource = nil
                discardPendingTranscriptionResult = false
                recordingFrontmostApp = nil
                state = .idle
            }
            onFatalAudioError?(message)
        }
    }
}
