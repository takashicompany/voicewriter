import AppKit
import Foundation
import KeyboardShortcuts
import os.log

enum AppState {
    case idle
    case recording
    case transcribing
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

    init(audioEngine: AudioCaptureEngineControlling, transcriptionEngine: TranscriptionEngine, textFormatter: TextFormatter? = nil) {
        self.audioEngine = audioEngine
        self.transcriptionEngine = transcriptionEngine
        self.textFormatter = textFormatter
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
            onPhaseChanged?(.recognizing)
            do {
                let rawText = try await transcriptionEngine.transcribe(samples: samples, sampleRate: sampleRate)
                log.info("Transcription result: \(rawText, privacy: .private)")

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
