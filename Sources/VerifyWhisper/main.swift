// whisper.cpp統合の検証用スタンドアロンCLI。
// WAVファイル(16kHz/mono推奨)を読み込み、文字起こしを実行し、標準出力に結果と処理時間を表示する。
//
// 使い方:
//   swift run verify-whisper <wav-path> [model-path] [language]
//
// model-path省略時は既定のモデル配置先
// (~/Library/Application Support/Voicewriter/models/ggml-large-v3-turbo.bin) を使う。
// language省略時は "ja"。
//
// 注意: VerifyWhisperはSwift Package Managerの制約上(実行ファイルターゲット同士は
// リンク時のシンボル解決ができないため)Voicewriterモジュールをimportできない。
// そのため、以下のwhisper_full呼び出しパラメータ・先頭無音トリムは
// `Sources/Voicewriter/Transcription/WhisperCppEngine.swift` / `AudioPreprocessing.swift` の内容と
// 意図的に同一に保っている。どちらか一方を変更したら、もう一方も必ず追随させること。

import AVFoundation
import Foundation
import whisper

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fail("usage: verify-whisper <wav-path> [model-path] [language]")
}

let wavPath = arguments[1]

let defaultModelPath = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Application Support/Voicewriter/models/ggml-large-v3-turbo.bin")
let modelPath = arguments.count >= 3 ? arguments[2] : defaultModelPath
let language = arguments.count >= 4 ? arguments[3] : "ja"

guard FileManager.default.fileExists(atPath: wavPath) else {
    fail("wav file not found: \(wavPath)")
}
guard FileManager.default.fileExists(atPath: modelPath) else {
    fail("model file not found: \(modelPath) (run scripts/download-model.sh first)")
}

func loadFloatSamples(wavPath: String) throws -> (samples: [Float], sampleRate: Double) {
    let url = URL(fileURLWithPath: wavPath)
    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "verify-whisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to allocate PCM buffer"])
    }
    try file.read(into: buffer)
    guard let channelData = buffer.floatChannelData else { return ([], file.processingFormat.sampleRate) }
    let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    return (samples, file.processingFormat.sampleRate)
}

/// `AudioPreprocessing.trimLeadingSilence`と同一のロジック(意図的な複製、上部の注意書き参照)。
func trimLeadingSilence(
    samples: [Float],
    sampleRate: Double,
    frameDurationSeconds: Double = 0.02,
    rmsThreshold: Float = 0.015,
    marginSeconds: Double = 0.15,
    maxTrimSeconds: Double = 1.0
) -> [Float] {
    guard !samples.isEmpty, sampleRate > 0 else { return samples }

    let frameSize = max(1, Int(sampleRate * frameDurationSeconds))
    var loudFrameStart: Int?

    var index = 0
    while index < samples.count {
        let end = min(index + frameSize, samples.count)
        var sumSquares: Float = 0
        for i in index..<end {
            sumSquares += samples[i] * samples[i]
        }
        let rms = (sumSquares / Float(end - index)).squareRoot()
        if rms >= rmsThreshold {
            loudFrameStart = index
            break
        }
        index = end
    }

    guard let loudStart = loudFrameStart else { return samples }

    let marginSamples = Int(marginSeconds * sampleRate)
    let maxTrimSamples = Int(maxTrimSeconds * sampleRate)
    let trimTo = min(max(0, loudStart - marginSamples), maxTrimSamples)

    guard trimTo > 0 else { return samples }
    return Array(samples[trimTo...])
}

/// `Optional<String>`をネストした`withCString`越しに扱うためのヘルパー(WhisperCppEngine.swiftと同一)。
func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    if let string {
        return string.withCString(body)
    }
    return body(nil)
}

print("==> Loading WAV: \(wavPath)")
let rawSamples: [Float]
let sampleRate: Double
do {
    (rawSamples, sampleRate) = try loadFloatSamples(wavPath: wavPath)
} catch {
    fail("failed to load wav: \(error)")
}
print("    samples=\(rawSamples.count) sampleRate=\(sampleRate)")

guard !rawSamples.isEmpty else {
    fail("wav contains no samples")
}

let samples = trimLeadingSilence(samples: rawSamples, sampleRate: sampleRate)
if samples.count != rawSamples.count {
    print("    leading silence trimmed: \(rawSamples.count - samples.count) samples (\(String(format: "%.3f", Double(rawSamples.count - samples.count) / sampleRate))s)")
}

print("==> Loading model: \(modelPath)")
let loadStart = Date()
var cparams = whisper_context_default_params()
cparams.use_gpu = true

guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
    fail("whisper_init_from_file_with_params failed")
}
defer { whisper_free(ctx) }
let loadElapsed = Date().timeIntervalSince(loadStart)

if let versionCString = whisper_version() {
    print("    whisper.cpp version: \(String(cString: versionCString))")
}
print("    model load time: \(String(format: "%.3f", loadElapsed))s")

// whisper.cpp本家CLI(whisper-cli, v1.9.1)の既定値に合わせる。WhisperCppEngine.swiftと同一のパラメータ。
// 一次情報:
//   https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/src/whisper.cpp (whisper_full_default_params:
//     WHISPER_SAMPLING_BEAM_SEARCH は beam_search.beam_size=5 が既定)
//   https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/examples/cli/cli.cpp#L31-L82
//     (params.beam_size/best_of の既定値がそれぞれ5であり、`beam_size > 1` なので
//      whisper-cliは常時ビームサーチをデフォルトで使っている)
//
// A/B比較用に以下の環境変数で挙動を切り替えられる(いずれも省略時はWhisperCppEngine.swiftと同一の既定):
//   VERIFY_WHISPER_STRATEGY=greedy|beam5   (既定 beam5)
//   VERIFY_WHISPER_VAD=1                   (既定 無効。有効時はggml-silero-v5.1.2.binを使用)
//   VERIFY_WHISPER_NO_TIMESTAMPS=1         (既定 無効。no_timestampsをtrueにする)
let env = ProcessInfo.processInfo.environment
let strategy = env["VERIFY_WHISPER_STRATEGY"] ?? "beam5"
let vadOverride = (env["VERIFY_WHISPER_VAD"] == "1")
let noTimestampsOverride = (env["VERIFY_WHISPER_NO_TIMESTAMPS"] == "1")

let samplingStrategy: whisper_sampling_strategy = (strategy == "greedy") ? WHISPER_SAMPLING_GREEDY : WHISPER_SAMPLING_BEAM_SEARCH
print("==> Running whisper_full (language=\(language), strategy=\(strategy)\(vadOverride ? " +VAD" : "")\(noTimestampsOverride ? " +no_timestamps" : ""))")
var params = whisper_full_default_params(samplingStrategy)
params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
params.print_progress = false
params.print_realtime = false
params.print_special = false
params.print_timestamps = false
params.translate = false
params.no_context = true
params.single_segment = false
params.no_timestamps = noTimestampsOverride

params.beam_search.beam_size = 5
// temperatureフォールバック時にgreedy経路のbest_of本を候補生成するため、strategy設定にかかわらず
// beam_search.beam_size同様5を明示する(WhisperCppEngine.swiftのコメント参照)。
params.greedy.best_of = 5
params.suppress_blank = true
params.temperature = 0.0
params.temperature_inc = 0.2
params.entropy_thold = 2.4
params.logprob_thold = -1.0

// suppress_nst=trueは維持。no_speech_tholdはwhisper-cli既定値の0.6に戻した
// (WhisperCppEngine.swiftのコメント参照: whisper.cppソース上、no_speech_tholdは
//  no_speech_prob > thold && avg_logprobs < logprob_tholdの複合条件でのみ効き、
//  自信を持って生成されたハルシネーションには単独では効果がないため)。
params.suppress_nst = true
params.no_speech_thold = 0.6

// VAD(既定OFF、VERIFY_WHISPER_VAD=1で有効化)。speech_pad_msはWhisperCppEngine.swiftと
// 同じく100ms(既定30msから引き上げ、語頭・語尾の欠落を防ぐ安全マージン)。
let vadModelPath = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Application Support/Voicewriter/models/ggml-silero-v5.1.2.bin")
let vadModelPathForWhisper: String?
if vadOverride {
    if FileManager.default.fileExists(atPath: vadModelPath) {
        vadModelPathForWhisper = vadModelPath
        print("    vad_model_path: \(vadModelPath)")
    } else {
        FileHandle.standardError.write("warning: VAD requested but model not found at \(vadModelPath) (run scripts/download-vad-model.sh); proceeding without VAD\n".data(using: .utf8)!)
        vadModelPathForWhisper = nil
    }
} else {
    vadModelPathForWhisper = nil
}
params.vad = (vadModelPathForWhisper != nil)
var vadParamsForVerify = whisper_vad_default_params()
vadParamsForVerify.speech_pad_ms = 100
params.vad_params = vadParamsForVerify

let languageForWhisper: String? = (language == "auto") ? nil : language

// 語彙ヒント(initial_prompt)。既定値はSettings.defaultVocabularyHintと同一の"Voicewriter"。
// 環境変数 VERIFY_WHISPER_VOCAB_HINT で上書き可能(空文字を渡すとヒントなしで検証できる)。
let vocabularyHint: String
if let override = ProcessInfo.processInfo.environment["VERIFY_WHISPER_VOCAB_HINT"] {
    vocabularyHint = override
} else {
    vocabularyHint = "Voicewriter"
}
let promptForWhisper: String? = vocabularyHint.isEmpty ? nil : vocabularyHint
if let promptForWhisper {
    print("    initial_prompt: \(promptForWhisper)")
}

let runStart = Date()
let result: Int32 = withOptionalCString(languageForWhisper) { languageCString in
    withOptionalCString(promptForWhisper) { promptCString in
        withOptionalCString(vadModelPathForWhisper) { vadModelPathCString in
            params.language = languageCString
            params.initial_prompt = promptCString
            params.vad_model_path = vadModelPathCString
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
    }
}
let runElapsed = Date().timeIntervalSince(runStart)

guard result == 0 else {
    fail("whisper_full failed with code \(result)")
}

// セグメント単位のno_speech_probフィルタ(WhisperCppEngine.swiftの`filterSegments`と同一ロジック、
// 意図的な複製。VERIFY_WHISPER_NO_SPEECH_FILTER=0で無効化して比較できる)。
let segmentNoSpeechFilterEnabled = (env["VERIFY_WHISPER_NO_SPEECH_FILTER"] ?? "1") != "0"
let segmentNoSpeechProbThreshold: Float = 0.6

let segmentCount = whisper_full_n_segments(ctx)
var text = ""
var excludedSegmentCount = 0
for i in 0..<segmentCount {
    let segmentText = whisper_full_get_segment_text(ctx, i).map { String(cString: $0) } ?? ""
    let noSpeechProb = whisper_full_get_segment_no_speech_prob(ctx, i)
    if segmentNoSpeechFilterEnabled, noSpeechProb >= segmentNoSpeechProbThreshold {
        excludedSegmentCount += 1
        print("    segment \(i) excluded: no_speech_prob=\(String(format: "%.3f", noSpeechProb)) text=\(segmentText)")
        continue
    }
    text += segmentText
}
text = text.trimmingCharacters(in: .whitespacesAndNewlines)
if excludedSegmentCount > 0 {
    print("    excluded \(excludedSegmentCount) of \(segmentCount) segment(s) with high no_speech_prob (threshold=\(segmentNoSpeechProbThreshold))")
}

let audioDurationSeconds = Double(rawSamples.count) / (sampleRate > 0 ? sampleRate : 16000)

print("==> Result (\(segmentCount) segments):")
print(text)
print("==> Timing: audio=\(String(format: "%.2f", audioDurationSeconds))s processing=\(String(format: "%.3f", runElapsed))s (realtime factor \(String(format: "%.2f", runElapsed / max(audioDurationSeconds, 0.001)))x)")
