import Foundation

/// ストリーミング文字起こしの逐次イベント。ライブプレビュー表示専用の情報であり、
/// 実際に挿入されるテキストは`StreamingTranscriptionSession.finish()`が返す確定テキストのみを使う
/// (仕様: 未確定(volatile)テキストは挿入先アプリへは一切流し込まない)。
enum StreamingTranscriptionEvent: Sendable {
    /// - Parameters:
    ///   - finalizedText: これまでに確定したテキスト全体(セッション開始からの累積)。
    ///   - volatileText: 現在進行中で、まだ確定していない末尾部分(今後書き換わりうる)。
    case update(finalizedText: String, volatileText: String)
    /// モデル資産(言語モデル)が未インストールで、初回自動ダウンロード/インストール中であることの通知。
    /// `progress`は0.0〜1.0(不明な場合はnil)。ダウンロード完了後は通常の`update`イベントへ続く。
    case preparing(progress: Double?)
}

/// 1回分の録音に対応するストリーミング文字起こしセッション。
///
/// `append`は`AudioCaptureEngine`の`controlQueue`(専用の同期シリアルキュー)から直接呼ばれるため、
/// ブロッキングしない同期関数として設計する(内部で非同期処理が必要な場合は、実装側が
/// バッファリング+バックグラウンドTaskで吸収すること)。
protocol StreamingTranscriptionSession: AnyObject, Sendable {
    /// 16kHz/mono/Float32のPCMサンプルを追加する。`finish()`/`cancel()`が呼ばれた後の呼び出しは無視してよい。
    func append(samples: [Float], sampleRate: Double)

    /// 録音終了(通常終了)を通知し、確定済みの最終テキストが得られるまで待つ。
    /// 仕様により、この戻り値がそのまま(whisperを経由せず)後段のLLM整形→辞書置換→挿入へ渡される。
    func finish() async throws -> String

    /// 録音キャンセル(Escなど)時に呼ぶ。以後`append`/`finish`は呼ばれない前提で内部リソースを破棄してよい。
    func cancel()
}

/// ストリーミング文字起こしエンジンの抽象。実装は`SpeechAnalyzerEngine`(macOS 26+のApple
/// SpeechAnalyzer/SpeechTranscriber)だが、`Coordinator`の結合テストではフェイク実装に差し替える。
protocol StreamingTranscriptionEngine: AnyObject, Sendable {
    /// 新しい録音セッションを開始する。`onEvent`は録音中、確定/未確定テキストが更新されるたびに
    /// 呼ばれる(ライブプレビュー表示用)。メインスレッド以外から呼ばれうるため、
    /// 呼び出し側(`Coordinator`)でMainActorへホップすること。
    ///
    /// 実際の非同期セットアップ(モデル準備等)がまだ完了していなくても、この関数自体は
    /// 即座に(同期的に)返す設計とする。`append`はその間バッファリングされ、準備完了後に
    /// 遅延なく処理される(録音開始直後の発話の取りこぼしを防ぐため)。
    func makeSession(onEvent: @escaping @Sendable (StreamingTranscriptionEvent) -> Void) -> StreamingTranscriptionSession
}
