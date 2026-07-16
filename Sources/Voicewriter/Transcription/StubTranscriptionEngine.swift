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
