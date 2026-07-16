import AppKit
import Foundation

/// ジョブの終端状態。`DictationJobRegistry.markTerminal`により一度だけ確定し、以後変化しない。
enum DictationJobTerminalState: Equatable {
    /// テキスト挿入(Cmd+V送出)まで完了した。
    case inserted
    /// Esc等によりキャンセルされ、挿入されずに終わった。
    case cancelled
    /// ハルシネーション対策(多層防御)により、文字起こし結果が得られず録音サイクルがスキップされた。
    case skipped(RecordingSkipReason)
    /// whisper.cpp呼び出し自体が例外を投げた等、回復不能な失敗。
    case failed
    /// 挿入時点でジョブ記録時のフロントモストアプリと一致しなかったため、自動挿入を見送った
    /// (履歴からの手動回収は可能)。
    case focusMismatch
}

/// 録音開始時点の設定スナップショット。待ち行列中に設定(言語・語彙ヒント・VAD有効/無効・
/// 整形ON/OFF・整形モデル・整形タイムアウト)が変更されても、このジョブ自体は録音時点の設定の
/// ままで処理される(Codexレビュー指摘#8: 以前はVAD有効/無効・整形タイムアウトが実行時に
/// グローバルな`Settings`から直接読まれており、待ち行列中の設定変更が既に録音済みのジョブにも
/// 影響してしまっていた)。
struct DictationJobSettingsSnapshot: Sendable, Equatable {
    var sttLanguage: String
    var vocabularyHint: String
    /// VAD(Voice Activity Detection)を有効にするか。`TranscriptionEngine.transcribe`へ
    /// 呼び出しごとの引数として渡す。
    var vadEnabled: Bool
    var formattingEnabled: Bool
    var formattingModel: String
    /// LLM整形リクエストのタイムアウト秒数。`TextFormatter.format`へ呼び出しごとの引数として渡す。
    var formattingTimeoutSeconds: Double

    static func captureCurrent() -> DictationJobSettingsSnapshot {
        DictationJobSettingsSnapshot(
            sttLanguage: Settings.sttLanguage,
            vocabularyHint: Settings.sttVocabularyHint,
            vadEnabled: Settings.vadEnabled,
            formattingEnabled: Settings.formattingEnabled,
            formattingModel: Settings.formattingModel,
            formattingTimeoutSeconds: Settings.formattingTimeoutSeconds
        )
    }
}

/// 1回分の発話(録音)ジョブ。`sequence`は録音開始時に`DictationJobRegistry.beginJob()`が
/// 単調増加で採番し、挿入順序(発話順)の基準になる。
struct DictationJob: Sendable {
    let sequence: Int
    let samples: [Float]
    let sampleRate: Double
    /// 録音実効長(キー押下〜離しの長さ、プリロール除く)。多層防御の第1層判定に使う。
    let effectiveRecordingDuration: TimeInterval
    /// 録音開始時点のフロントモストアプリ(挿入時のフォーカス一致比較・挿入先の想定に使う)。
    let frontmostAppAtRecordingStart: NSRunningApplication?
    let settings: DictationJobSettingsSnapshot
}
