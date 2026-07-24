import Foundation
import Speech

/// SpeechAnalyzer(ストリーミング)モードがこの環境で選択可能かどうかの判定結果。
struct StreamingTranscriptionAvailabilityStatus: Equatable, Sendable {
    let isSupported: Bool
    /// 非対応の場合の理由(設定UIのグレーアウト理由表示に使う)。対応している場合はnil。
    let reason: String?

    static let checking = StreamingTranscriptionAvailabilityStatus(isSupported: false, reason: "確認中…")
}

/// 実行環境がSpeechAnalyzer/SpeechTranscriberによるストリーミング入力モードに対応しているかを
/// 判定する。固定表ではなく、実行時に`SpeechTranscriber.supportedLocales`を照会して判定する
/// (仕様: macOS 26未満、またはSpeechTranscriberがja非対応の環境では選択不可)。
enum StreamingTranscriptionAvailability {
    /// ストリーミングモードで使うロケール識別子。日本語のみ対応する(既存whisper.cppの既定言語と同様)。
    static let targetLocaleIdentifier = "ja-JP"

    static func currentStatus() async -> StreamingTranscriptionAvailabilityStatus {
        guard #available(macOS 26.0, *) else {
            return StreamingTranscriptionAvailabilityStatus(
                isSupported: false,
                reason: "この機能にはmacOS 26以降が必要です(現在: \(ProcessInfo.processInfo.operatingSystemVersionString))"
            )
        }
        guard SpeechTranscriber.isAvailable else {
            return StreamingTranscriptionAvailabilityStatus(
                isSupported: false,
                reason: "この端末ではSpeechTranscriberが利用できません"
            )
        }
        let requestedLocale = Locale(identifier: targetLocaleIdentifier)
        guard await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) != nil else {
            return StreamingTranscriptionAvailabilityStatus(
                isSupported: false,
                reason: "この端末では日本語(ja-JP)のSpeechTranscriberが利用できません"
            )
        }
        return StreamingTranscriptionAvailabilityStatus(isSupported: true, reason: nil)
    }

    /// 対応済みの解決済みLocaleを返す(モデル資産の状態確認・ダウンロード・エンジン生成で使う)。
    @available(macOS 26.0, *)
    static func resolvedLocale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: targetLocaleIdentifier))
    }
}
