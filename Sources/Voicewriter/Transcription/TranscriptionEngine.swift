import Foundation

/// 文字起こしエンジンの抽象。将来whisper.cpp(large-v3-turbo)実装に差し替える。
protocol TranscriptionEngine {
    /// 16kHz/mono/Float32のPCMサンプルを受け取り、文字起こし結果を返す。
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String
}

enum TranscriptionError: Error {
    case emptyAudio
}
