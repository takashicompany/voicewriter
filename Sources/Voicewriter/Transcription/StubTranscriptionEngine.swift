import Foundation
import os.log

/// whisper.cpp統合前のスタブ実装。
/// 録音したPCMをWAVとしてログディレクトリに保存し、ダミーテキストを返す。
final class StubTranscriptionEngine: TranscriptionEngine {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "StubTranscriptionEngine")

    /// 録音WAVの保存先ディレクトリ (~/Library/Application Support/Voicewriter/Recordings)
    static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Voicewriter/Recordings", isDirectory: true)
    }

    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
        guard !samples.isEmpty else {
            throw TranscriptionError.emptyAudio
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let filename = "recording-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")).wav"
        let url = Self.recordingsDirectory.appendingPathComponent(filename)

        do {
            try WavWriter.write(samples: samples, sampleRate: sampleRate, to: url)
            log.info("Saved stub recording to \(url.path, privacy: .public)")
        } catch {
            log.error("Failed to save recording WAV: \(error.localizedDescription)")
        }

        let durationSeconds = Double(samples.count) / sampleRate
        return String(format: "[スタブ文字起こし: %.1f秒の音声を録音しました]", durationSeconds)
    }
}

/// `Settings.sttEngine == .speechAnalyzer`選択時に`DynamicTranscriptionEngine`が返す
/// バッチ(whisper.cpp)用プレースホルダー。
///
/// 通常、SpeechAnalyzerストリーミングモードでは`Coordinator`が`streamingSession`経由で確定テキストを
/// 直接取得するため、このインスタンスの`transcribe`は一切呼ばれない(仕様通り)。
///
/// 実機バグ修正の経緯: 以前はここに`StubTranscriptionEngine`(常にダミーテキストを返す)を割り当てて
/// いたため、`Coordinator.shouldUseStreamingForNewRecording`が何らかの理由(実行時に
/// `streamingEngine`が注入されなかった等)でfalseになり、このプレースホルダーが実際に呼ばれると、
/// ユーザーには何の警告も無いままダミーテキストが挿入されてしまっていた。
///
/// 一方、単純にwhisper.cppの実エンジンをここで毎回ロードする案は却下した: `DynamicTranscriptionEngine`
/// の`makeEngine`/`reload()`は`Settings.sttEngine == .speechAnalyzer`のとき(=ストリーミングが
/// 正常に機能している大多数のケースを含め)必ず呼ばれるため、数百MB〜GB級のwhisperモデルを
/// 毎回無条件にメモリ/GPUへロードしてしまい、ストリーミングを選んでいるユーザーに対して
/// 無駄なコスト(起動時間・メモリ・電力)を強いることになる(Codexレビュー指摘)。
///
/// そのため、このプレースホルダーは「実際に呼ばれたら何もごまかさず例外を投げる」設計にした。
/// `Coordinator.runJob`はこれを`catch`し、`.tombstone(.failed)`として扱う(ダミーテキストの
/// サイレント挿入は起こらない)。「ストリーミング利用不可時にwhisperへフォールバックする」という
/// ユーザー向けの振る舞いは、より早い段階(`Coordinator.attemptStartRecording`が
/// `onStreamingUnavailableFallback`で通知し、`AppDelegate`が起動時/非同期チェックで
/// `Settings.sttEngine`自体をwhisperCppへ補正する経路)で担保している。
final class SpeechAnalyzerStreamingPlaceholderTranscriptionEngine: TranscriptionEngine {
    func transcribe(samples: [Float], sampleRate: Double, language: String, vocabularyHint: String, vadEnabled: Bool) async throws -> String {
        throw TranscriptionError.streamingPlaceholderInvokedUnexpectedly
    }
}
