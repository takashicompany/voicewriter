// Apple SpeechAnalyzer / SpeechTranscriber (macOS 26+) 統合検証用スタンドアロンCLI。
//
// ストリーミング入力モード実装の前段階のPoCとして、以下を実機確認する:
//   (a) SpeechTranscriber.supportedLocales に ja-JP 相当が含まれるか
//   (b) AssetInventory の状態(モデル資産のインストール状況)
//   (c) フィクスチャWAV(16kHz)を食わせて日本語の確定(final)結果が返るか
//   (d) volatile(暫定)結果が逐次届くか(チャンク分割 + 疑似リアルタイム送出で検証)
//
// 使い方:
//   swift run verify-speech-analyzer <wav-path> [locale-identifier (既定 ja-JP)]
//
// 注意: このターゲットはmacOS 26のSpeech APIをコンパイル時に参照するため、ビルドマシンの
// SwiftツールチェーンがmacOS 26 SDKを持っている必要がある(Package.swift自体はmacOS 14を
// 最低ターゲットにしたままで良い。実行時は#available(macOS 26, *)で分岐する)。

import AVFoundation
import Foundation
import Speech

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func logLine(_ message: String) {
    print(message)
    fflush(stdout)
}

@available(macOS 26.0, *)
func loadPCMBuffer(url: URL) throws -> (buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "verify-speech-analyzer", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to allocate PCM buffer"])
    }
    try file.read(into: buffer)
    return (buffer, file.processingFormat)
}

@available(macOS 26.0, *)
func convert(buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    if buffer.format == format {
        return buffer
    }
    guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
        throw NSError(domain: "verify-speech-analyzer", code: 2, userInfo: [NSLocalizedDescriptionKey: "failed to create AVAudioConverter"])
    }
    converter.sampleRateConverterQuality = .max
    let ratio = format.sampleRate / buffer.format.sampleRate
    let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity) else {
        throw NSError(domain: "verify-speech-analyzer", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed to allocate output buffer"])
    }
    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
        if suppliedInput {
            inputStatus.pointee = .noDataNow
            return nil
        }
        suppliedInput = true
        inputStatus.pointee = .haveData
        return buffer
    }
    guard status != .error else {
        throw conversionError ?? NSError(domain: "verify-speech-analyzer", code: 4, userInfo: [NSLocalizedDescriptionKey: "conversion failed with unknown error"])
    }
    return outBuffer
}

/// バッファの`[offset, offset+length)`区間を新しいバッファへコピーする。
/// `floatChannelData`はcommonFormatが`.pcmFormatFloat32`以外(今回のanalyzerFormatはInt16、
/// commonFormat.rawValue==3で`.pcmFormatInt16`)だとnilを返すため、フォーマットに依存しない
/// `audioBufferList`(生バイト列)ベースでコピーする(先に`floatChannelData`ベースで実装した際、
/// Int16フォーマットで無音同然のデータしかコピーされず、認識結果が「あ」1文字のみになる不具合が
/// あったため、このバイトコピー方式に修正した)。
@available(macOS 26.0, *)
func sliceBuffer(_ buffer: AVAudioPCMBuffer, offset: AVAudioFrameCount, length: AVAudioFrameCount) -> AVAudioPCMBuffer? {
    guard let newBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: length) else { return nil }
    newBuffer.frameLength = length

    let srcListPointer = buffer.audioBufferList
    let dstListPointer = newBuffer.mutableAudioBufferList
    let srcBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: srcListPointer))
    let dstBuffers = UnsafeMutableAudioBufferListPointer(dstListPointer)

    for i in 0..<min(srcBuffers.count, dstBuffers.count) {
        let srcBuf = srcBuffers[i]
        guard let srcData = srcBuf.mData, srcBuf.mNumberChannels > 0 else { continue }
        let bytesPerFrameForThisBuffer = Int(srcBuf.mDataByteSize) / max(1, Int(buffer.frameLength))
        let byteOffset = Int(offset) * bytesPerFrameForThisBuffer
        let byteLength = Int(length) * bytesPerFrameForThisBuffer
        guard let dstData = dstBuffers[i].mData else { continue }
        memcpy(dstData, srcData.advanced(by: byteOffset), byteLength)
        dstBuffers[i].mDataByteSize = UInt32(byteLength)
    }
    return newBuffer
}

/// バッファを`chunkFrames`ごとの小さいバッファへ分割する(疑似リアルタイム送出でvolatileの逐次性を確認するため)。
@available(macOS 26.0, *)
func splitIntoChunks(_ buffer: AVAudioPCMBuffer, chunkFrames: AVAudioFrameCount) -> [AVAudioPCMBuffer] {
    var chunks: [AVAudioPCMBuffer] = []
    let total = buffer.frameLength
    var offset: AVAudioFrameCount = 0
    while offset < total {
        let length = min(chunkFrames, total - offset)
        guard let chunk = sliceBuffer(buffer, offset: offset, length: length) else { break }
        chunks.append(chunk)
        offset += length
    }
    return chunks
}

@available(macOS 26.0, *)
func run() async {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        fail("usage: verify-speech-analyzer <wav-path> [locale-identifier (default ja-JP)]")
    }
    let wavPath = arguments[1]
    let localeIdentifier = arguments.count >= 3 ? arguments[2] : "ja-JP"
    guard FileManager.default.fileExists(atPath: wavPath) else {
        fail("wav file not found: \(wavPath)")
    }

    logLine("==> macOS version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    logLine("==> SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")

    // (a) supportedLocales に ja-JP 相当が含まれるか
    let supportedLocales = await SpeechTranscriber.supportedLocales
    logLine("==> SpeechTranscriber.supportedLocales count: \(supportedLocales.count)")
    let jaSupported = supportedLocales.contains { $0.identifier(.bcp47).lowercased().hasPrefix("ja") }
    logLine("    ja* present in supportedLocales: \(jaSupported)")
    logLine("    sample identifiers: \(supportedLocales.prefix(10).map { $0.identifier(.bcp47) })")

    let installedLocales = await SpeechTranscriber.installedLocales
    logLine("==> SpeechTranscriber.installedLocales: \(installedLocales.map { $0.identifier(.bcp47) })")

    let requestedLocale = Locale(identifier: localeIdentifier)
    guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
        fail("locale '\(localeIdentifier)' is not supported by SpeechTranscriber on this system (jaSupported=\(jaSupported))")
    }
    logLine("==> resolved locale: \(resolvedLocale.identifier(.bcp47))")

    // 実機バグ調査で判明した重要な設定: `.volatileResults`だけでは、この端末では録音中に
    // 一切結果が届かず、`finalizeAndFinishThroughEndOfInput()`後にまとめて届く(詳細は
    // `SpeechTranscriberFactory`のドキュメントコメント参照)。`.fastResults`を追加すると
    // 供給中も継続的にvolatile結果が届くようになる。アプリ本体(`SpeechTranscriberFactory`)と
    // 同じ設定をこのPoCでも使う。
    let transcriber = SpeechTranscriber(
        locale: resolvedLocale,
        transcriptionOptions: [],
        reportingOptions: [.volatileResults, .fastResults],
        attributeOptions: []
    )

    // (b) AssetInventory の状態
    let assetStatusBefore = await AssetInventory.status(forModules: [transcriber])
    logLine("==> AssetInventory.status before install attempt: \(assetStatusBefore)")

    if assetStatusBefore != .installed {
        logLine("==> Model asset not installed yet; requesting installation (may download)...")
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                logLine("    downloadAndInstall() starting...")
                try await request.downloadAndInstall()
                logLine("    downloadAndInstall() completed")
            } else {
                logLine("    assetInstallationRequest returned nil (already satisfied, or unsupported)")
            }
        } catch {
            fail("asset installation failed: \(error)")
        }
    }

    let assetStatusAfter = await AssetInventory.status(forModules: [transcriber])
    logLine("==> AssetInventory.status after install attempt: \(assetStatusAfter)")
    guard assetStatusAfter == .installed else {
        fail("SpeechTranscriber module is not installed for locale \(resolvedLocale.identifier(.bcp47)) (status=\(assetStatusAfter)); aborting PoC")
    }

    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        fail("could not determine a compatible audio format for the transcriber module")
    }
    logLine("==> analyzer format: sampleRate=\(analyzerFormat.sampleRate) channels=\(analyzerFormat.channelCount) commonFormat=\(analyzerFormat.commonFormat.rawValue)")

    logLine("==> Loading WAV: \(wavPath)")
    let rawBuffer: AVAudioPCMBuffer
    let sourceFormat: AVAudioFormat
    do {
        (rawBuffer, sourceFormat) = try loadPCMBuffer(url: URL(fileURLWithPath: wavPath))
    } catch {
        fail("failed to load wav: \(error)")
    }
    logLine("    source format: sampleRate=\(sourceFormat.sampleRate) channels=\(sourceFormat.channelCount) frames=\(rawBuffer.frameLength)")

    let convertedBuffer: AVAudioPCMBuffer
    do {
        convertedBuffer = try convert(buffer: rawBuffer, to: analyzerFormat)
    } catch {
        fail("format conversion (source -> analyzer format) failed: \(error)")
    }
    logLine("    converted frames: \(convertedBuffer.frameLength)")

    // (d) volatileの逐次性を確認するため、100ms相当のチャンクに分割し、疑似リアルタイムで送出する。
    let chunkFrames = AVAudioFrameCount(analyzerFormat.sampleRate * 0.1)
    let chunks = splitIntoChunks(convertedBuffer, chunkFrames: chunkFrames)
    logLine("==> split into \(chunks.count) chunks (~100ms each)")

    let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
    do {
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
    } catch {
        fail("prepareToAnalyze failed: \(error)")
    }

    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

    let startTime = Date()
    actor Counters {
        var volatileEventCount = 0
        var finalEventCount = 0
        var finalizedText = ""
        func recordVolatile() { volatileEventCount += 1 }
        func recordFinal(_ text: String) {
            finalEventCount += 1
            finalizedText += text
        }
    }
    let counters = Counters()

    let resultsTask = Task {
        do {
            for try await result in transcriber.results {
                let elapsed = Date().timeIntervalSince(startTime)
                let text = String(result.text.characters)
                if result.isFinal {
                    await counters.recordFinal(text)
                    logLine(String(format: "  [%6.3fs] FINAL   : %@", elapsed, text))
                } else {
                    await counters.recordVolatile()
                    logLine(String(format: "  [%6.3fs] volatile: %@", elapsed, text))
                }
            }
            logLine("==> transcriber.results sequence ended normally")
        } catch {
            logLine("==> transcriber.results sequence ended with error: \(error)")
        }
    }

    // analyzer.start(inputSequence:)は入力シーケンスが終わるまで継続するため、
    // 独立したTaskで実行し、フィード側とは並行に進める(WWDC25 Session 277のパターン)。
    let startTask = Task {
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            logLine("==> analyzer.start failed/ended with error: \(error)")
        }
    }

    for chunk in chunks {
        continuation.yield(AnalyzerInput(buffer: chunk))
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    continuation.finish()

    _ = await startTask.value

    do {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
        logLine("==> finalizeAndFinishThroughEndOfInput failed: \(error)")
    }

    _ = await resultsTask.value

    let volatileCount = await counters.volatileEventCount
    let finalCount = await counters.finalEventCount
    let finalizedText = await counters.finalizedText

    logLine("==> Summary: volatile events=\(volatileCount) final events=\(finalCount)")
    logLine("==> Finalized text (concatenated from FINAL events):")
    logLine(finalizedText)
}

if #available(macOS 26.0, *) {
    await run()
} else {
    fail("This machine's OS (\(ProcessInfo.processInfo.operatingSystemVersionString)) is below macOS 26; SpeechAnalyzer/SpeechTranscriber is unavailable. PoC cannot proceed.")
}
