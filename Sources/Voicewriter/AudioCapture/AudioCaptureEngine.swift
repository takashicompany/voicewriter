import AVFoundation
import Foundation
import os.log

protocol AudioCaptureEngineDelegate: AnyObject {
    /// 録音が正常終了し、16kHz/mono/Float32のPCMサンプルが確定した
    func audioCaptureEngine(_ engine: AudioCaptureEngineControlling, didFinishRecording samples: [Float], sampleRate: Double)
    /// 録音がキャンセルされた(Escなど)
    func audioCaptureEngineDidCancelRecording(_ engine: AudioCaptureEngineControlling)
    /// タップ再設置失敗・不正な入力フォーマット・エンジン起動失敗など、
    /// 録音を継続できない致命的な状態になった。録音中だった場合は呼び出し側でidleへ戻すこと。
    func audioCaptureEngine(_ engine: AudioCaptureEngineControlling, didEncounterFatalError message: String)
}

/// `Coordinator`がオーディオキャプチャエンジンを操作するために必要な最小限のインターフェース。
/// 実装は`AudioCaptureEngine`(実際のAVAudioEngineを操作する)だが、`AVAudioEngine`は実機のオーディオ
/// ハードウェアに依存し単体テストで直接動かすのが難しいため、`Coordinator`のテストでは
/// このプロトコルに対するフェイク実装に差し替えられるようにしている
/// (Codexレビュー指摘: `await transcribe`前にキャンセルフラグを先読みしてしまう競合の回帰テストで使用)。
protocol AudioCaptureEngineControlling: AnyObject {
    var delegate: AudioCaptureEngineDelegate? { get set }
    func startRecording()
    func stopRecording()
    func cancelRecording()
}

/// AVAudioEngineのinputNodeからタップを取り、16kHz/mono/Float32へ変換して保持する。
/// AlwaysOn/OnDemandの2モードを切り替え可能。
///
/// 重要: オーディオエンジンの起動/停止/タップ操作/prepare/フォーマット変更復旧、
/// 録音開始・終了の境界確定、リングバッファ参照の読み書きは、すべて`controlQueue`という
/// 単一のシリアルキューに直列化している。タップコールバックから届く音声データの変換・蓄積も
/// 同じキュー上で行うため、「録音開始/終了の境界」と「音声データの取り込み」が常に
/// 単一のタイムラインの上で解決され、二重取り込みや欠落、データレースが起こらない。
final class AudioCaptureEngine: AudioCaptureEngineControlling {
    static let targetSampleRate: Double = 16000
    /// 録音1回あたりの上限(既定5分)。上限に達したら自動的に録音を終了し、文字起こしへ回す。
    /// (暴走・無限録音でメモリを圧迫し続けることを防ぐための安全弁)
    static let maxRecordingSeconds: Double = 300
    /// `stopRecording()`が実際にfinalizeを`controlQueue`へ投入するまでの猶予。
    /// 入力バッファ1個分(bufferSize=2048、代表的な入力サンプルレート44.1kHz/48kHzで約43〜46ms)を
    /// 上回る余裕を持たせ、停止直前に発生した最後のタップコールバックが確実に
    /// finalizeより先に`controlQueue`へ届くようにする(語尾欠落対策)。
    static let stopGraceInterval: TimeInterval = 0.1

    weak var delegate: AudioCaptureEngineDelegate?

    /// 録音中の音声レベル(RMS)をメインスレッドで通知する(HUDのレベルメーター表示用の付加情報)。
    /// `delegate`と同様、録音開始前(アプリ起動時)に一度だけ設定される想定のため、
    /// `controlQueue`からの読み取りに追加の同期は設けていない。
    var onLevelUpdate: ((Float) -> Void)?

    /// 録音中、変換済み(16kHz/mono/Float32)の音声チャンクを`recordingBuffer`への蓄積と並行して
    /// 通知する(SpeechAnalyzerストリーミングモードでの逐次認識へのfan-out用)。`controlQueue`上で
    /// 同期的に呼ばれる(=呼び出し先はブロッキングしない同期関数であること)。ストリーミングモードを
    /// 使わない場合は`Coordinator`側が何もしないハンドラのままにしておいてよい(既存のwhisperモードの
    /// 挙動には一切影響しない、純粋な追加のfan-outポイント)。
    var onRecordingChunk: (([Float], Double) -> Void)?

    private let log = Logger(subsystem: "dev.voicewriter.app", category: "AudioCaptureEngine")

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    private var ringBuffer: AudioRingBuffer
    private var isTapInstalled = false
    private var isEngineRunning = false

    private var isRecording = false
    private var recordingBuffer: [Float] = []

    /// オーディオエンジン制御・録音境界・リングバッファ参照のすべてを直列化する単一のシリアルキュー。
    /// このクラスの private な `...Locked` サフィックスの付いたメソッドは、必ずこのキュー上で実行すること。
    private let controlQueue = DispatchQueue(label: "dev.voicewriter.audiocapture.control")

    private var idleStopWorkItem: DispatchWorkItem?

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        ringBuffer = AudioRingBuffer(seconds: Settings.ringBufferSeconds, sampleRate: Self.targetSampleRate)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
    }

    /// アプリ起動時に呼ぶ。タップ設置とprepare()まで済ませる。
    /// AlwaysOnモードでのエンジン自動起動は行わない
    /// (マイク権限確認の完了を待ってから`microphonePermissionResolved(granted:)`経由で行うため。
    ///  権限コールバックを待たずに起動すると、無許可状態での起動を試みてしまう)。
    func setup() {
        controlQueue.sync {
            _ = installTapIfNeededLocked()
            engine.prepare()
        }
        log.info("AudioCaptureEngine prepared")
    }

    /// マイク権限確認(`AVCaptureDevice.requestAccess`等)の結果を受けて呼ぶ。
    /// 許可されていて、かつAlwaysOnモードの場合のみエンジンを起動する。拒否時は起動しない
    /// (呼び出し側でメニューバー警告を出すこと)。
    func microphonePermissionResolved(granted: Bool) {
        guard granted else {
            log.warning("Microphone permission denied; AlwaysOn engine will not auto-start")
            return
        }
        guard Settings.micMode == .alwaysOn else { return }
        controlQueue.async { [weak self] in
            self?.startEngineLocked()
        }
    }

    // MARK: - Engine lifecycle (controlQueue上でのみ呼ぶこと)

    /// 現在のinputNodeのフォーマットを検証し、問題なければタップを設置してコンバータを生成する。
    /// フォーマットが不正(サンプルレート/チャンネル数が0以下)、またはコンバータ生成に失敗した場合は
    /// 何もインストールせずfalseを返す(呼び出し側は録音状態に遷移しない/戻すこと)。
    @discardableResult
    private func installTapIfNeededLocked() -> Bool {
        guard !isTapInstalled else { return true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard Self.isValidInputFormat(sampleRate: format.sampleRate, channelCount: format.channelCount) else {
            log.error("Invalid input format: sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
            return false
        }
        guard let newConverter = AVAudioConverter(from: format, to: targetFormat) else {
            log.error("Failed to create AVAudioConverter for format sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
            return false
        }
        // 既定のまま(未指定)だとサンプルレート変換の品質・アルゴリズムがシステム任せになる。
        // マイクの native sample rate(多くは44.1/48kHz)から16kHzへ毎回ダウンサンプルするため、
        // 明示的に最高品質を指定する(認識精度に影響しうるエイリアシング・リサンプル品質の劣化を避ける)。
        // 一次情報: https://developer.apple.com/documentation/avfaudio/avaudioconverter/samplerateconverterquality
        newConverter.sampleRateConverterQuality = .max
        converter = newConverter

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.controlQueue.async {
                self.handleIncomingLocked(buffer: buffer)
            }
        }
        isTapInstalled = true
        log.debug("Input tap installed: \(format.sampleRate)Hz ch=\(format.channelCount)")
        return true
    }

    /// 入力フォーマットとして妥当か(純粋関数・テスト用に切り出し)。
    static func isValidInputFormat(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && sampleRate.isFinite && channelCount > 0
    }

    /// RMS(二乗平均平方根)レベルを計算する(純粋関数・テスト用に切り出し)。HUDのレベルメーター表示に使う。
    static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    private func removeTapLocked() {
        guard isTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    private func startEngineLocked() {
        guard !isEngineRunning else { return }
        guard installTapIfNeededLocked() else {
            reportFatalErrorLocked("マイク入力フォーマットが不正なため録音を開始できません。マイクの接続を確認してください。")
            return
        }
        do {
            try engine.start()
            isEngineRunning = true
            log.info("AVAudioEngine started")
        } catch {
            log.error("AVAudioEngine start failed: \(error.localizedDescription)")
            reportFatalErrorLocked("マイクの起動に失敗しました: \(error.localizedDescription)")
        }
    }

    private func stopEngineLocked() {
        guard isEngineRunning else { return }
        engine.stop()
        isEngineRunning = false
        log.info("AVAudioEngine stopped")
    }

    private func reportFatalErrorLocked(_ message: String) {
        log.error("\(message, privacy: .public)")
        delegate?.audioCaptureEngine(self, didEncounterFatalError: message)
    }

    // MARK: - Recording control

    /// 録音開始。AlwaysOnモードではプリロール分をリングバッファから遡って先頭に含める。
    func startRecording() {
        controlQueue.async { [weak self] in
            self?.startRecordingLocked()
        }
    }

    private func startRecordingLocked() {
        idleStopWorkItem?.cancel()
        idleStopWorkItem = nil

        switch Settings.micMode {
        case .alwaysOn:
            // エンジンは常時起動済みのはず。念のため確認。
            startEngineLocked()
            guard isEngineRunning else {
                // エンジン起動/タップ設置に失敗した場合は録音を開始しない。
                // fatalErrorは既にstartEngineLocked内で通知済み。
                return
            }
            let preroll = ringBuffer.recent(seconds: Settings.prerollSeconds, sampleRate: Self.targetSampleRate)
            recordingBuffer = preroll
            isRecording = true
            // Codexレビュー指摘#3: プリロールは`recordingBuffer`(whisperモードが最後にまとめて使う経路)
            // には含まれていたが、`onRecordingChunk`(SpeechAnalyzerストリーミングモードへのfan-out)には
            // 一度も流れておらず、ストリーミングモードだけ発話冒頭の音声を取りこぼしていた。
            // whisper経路と同じ音声がストリーミング側にも届くよう、ここで明示的に1回fan-outする。
            if !preroll.isEmpty {
                onRecordingChunk?(preroll, Self.targetSampleRate)
            }
            log.info("Recording started (alwaysOn), preroll samples=\(preroll.count)")

        case .onDemand:
            startEngineLocked()
            guard isEngineRunning else { return }
            recordingBuffer = []
            isRecording = true
            log.info("Recording started (onDemand)")
        }
    }

    /// 録音終了。蓄積したサンプルをdelegateへ渡す。
    ///
    /// 停止直前にタップコールバックが開始済みだが、まだ`controlQueue`へのエンキューが済んでいない
    /// (=語尾を含む最後のバッファがまだ`handleIncomingLocked`に届いていない)ケースがある。
    /// そのままfinalizeすると、そのバッファはfinalize後に処理されて`isRecording`がfalseのため
    /// 捨てられ、語尾が欠落してしまう。そこで、finalize自体の`controlQueue`への投入を
    /// 入力バッファ1個分程度(既定100ms)だけ遅らせる。`controlQueue`はFIFOのため、
    /// この猶予期間内にタップコールバックが`controlQueue.async`を呼べば、それは
    /// 遅延実行されるfinalizeより先にキューへ積まれ、先に処理される。
    func stopRecording() {
        controlQueue.asyncAfter(deadline: .now() + Self.stopGraceInterval) { [weak self] in
            self?.stopRecordingLocked()
        }
    }

    /// finalize(録音確定)を冪等化するためのガード。
    /// 5分上限による自動停止(`handleIncomingLocked`)と、既に要求済みの手動停止が
    /// 両方とも`stopRecordingLocked()`を呼びうる。`isRecording`は`controlQueue`上でのみ
    /// 読み書きされるため、これを「確定済みフラグ」として兼用する:
    /// 一度目の呼び出しで`isRecording`をfalseにすることで、二度目の呼び出し
    /// (既にfalseになったバッファに対する空の完了)は無視され、二重発火を防ぐ。
    private func stopRecordingLocked() {
        guard isRecording else {
            log.debug("stopRecordingLocked called with no active recording; ignoring (already finalized)")
            return
        }
        isRecording = false
        let samples = recordingBuffer
        recordingBuffer = []
        log.info("Recording stopped, samples=\(samples.count)")
        delegate?.audioCaptureEngine(self, didFinishRecording: samples, sampleRate: Self.targetSampleRate)

        if Settings.micMode == .onDemand {
            scheduleIdleStop()
        }
    }

    /// 録音キャンセル(Escなど)。蓄積分は破棄。
    func cancelRecording() {
        controlQueue.async { [weak self] in
            self?.cancelRecordingLocked()
        }
    }

    /// `stopRecordingLocked()`と同様、`isRecording`を確定済みフラグとして扱い、
    /// 既に(自動停止や手動停止で)確定済みの場合は二重発火させない。
    private func cancelRecordingLocked() {
        guard isRecording else {
            log.debug("cancelRecordingLocked called with no active recording; ignoring (already finalized)")
            return
        }
        isRecording = false
        recordingBuffer = []
        log.info("Recording cancelled")
        delegate?.audioCaptureEngineDidCancelRecording(self)

        if Settings.micMode == .onDemand {
            scheduleIdleStop()
        }
    }

    // MARK: - Live settings changes (SettingsWindowから呼ばれる)

    /// マイクモードの変更を即座に反映する。
    func applyMicModeChange() {
        controlQueue.async { [weak self] in
            self?.applyMicModeChangeLocked()
        }
    }

    private func applyMicModeChangeLocked() {
        switch Settings.micMode {
        case .alwaysOn:
            startEngineLocked()
        case .onDemand:
            // 録音中は録音終了時のアイドルタイマーに任せる(録音を中断させないため)
            guard !isRecording else { return }
            idleStopWorkItem?.cancel()
            idleStopWorkItem = nil
            stopEngineLocked()
        }
    }

    /// リングバッファの秒数変更を即座に反映する(容量を再確保する)。
    func applyRingBufferSecondsChange() {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.ringBuffer = AudioRingBuffer(seconds: Settings.ringBufferSeconds, sampleRate: Self.targetSampleRate)
            self.log.info("Ring buffer resized to \(Settings.ringBufferSeconds, privacy: .public)s")
        }
    }

    private func scheduleIdleStop() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.controlQueue.async {
                self.stopEngineLocked()
            }
        }
        idleStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.onDemandIdleTimeoutSeconds, execute: workItem)
    }

    // MARK: - Audio processing (controlQueue上でのみ呼ぶこと)

    private func handleIncomingLocked(buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return }

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

        switch status {
        case .haveData, .endOfStream, .inputRanDry:
            // `.inputRanDry`でも、SDKヘッダの記載通り出力バッファにフレームが入っていることがあるため
            // ここでは破棄せずそのまま使う(以前は`.haveData`/`.endOfStream`以外を無条件に破棄していた)。
            break
        case .error:
            if let conversionError {
                log.error("Audio conversion error: \(conversionError.localizedDescription)")
            }
            return
        @unknown default:
            return
        }

        guard let channelData = outBuffer.floatChannelData else { return }
        let frameLength = Int(outBuffer.frameLength)
        guard frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        ringBuffer.append(samples)

        guard isRecording else { return }
        recordingBuffer.append(contentsOf: samples)
        onRecordingChunk?(samples, Self.targetSampleRate)

        if let onLevelUpdate {
            let rms = Self.computeRMS(samples)
            DispatchQueue.main.async { onLevelUpdate(rms) }
        }

        let maxSamples = Int(Self.maxRecordingSeconds * Self.targetSampleRate)
        if recordingBuffer.count >= maxSamples {
            log.warning("Recording reached max length (\(Self.maxRecordingSeconds, privacy: .public)s); auto-stopping")
            stopRecordingLocked()
        }
    }

    // MARK: - Device change recovery

    @objc private func handleConfigurationChange(_ notification: Notification) {
        log.warning("AVAudioEngineConfigurationChange received; reinstalling tap")
        // エンジンはこの通知後、内部でノードを再構成済みなことが多いが
        // タップとコンバータはフォーマット変更に追従できないため張り直す。
        controlQueue.async { [weak self] in
            guard let self else { return }
            let wasRunning = self.isEngineRunning
            let wasRecording = self.isRecording

            self.removeTapLocked()
            self.converter = nil
            self.isEngineRunning = false // engine内部状態はこの通知後不定なため、再構成前提でfalseに揃える

            guard self.installTapIfNeededLocked() else {
                // 新フォーマットが不正、またはコンバータ生成に失敗。例外クラッシュや無音録音を避けるため
                // ここでは復旧を諦め、録音中だった場合は破棄してidleへ戻す(fatalError通知経由)。
                if wasRecording {
                    self.isRecording = false
                    self.recordingBuffer = []
                }
                self.reportFatalErrorLocked("音声デバイスの再構成に失敗しました。デバイスの接続を確認し、Voicewriterを再起動してください。")
                return
            }

            self.engine.prepare()
            if wasRunning {
                self.startEngineLocked()
                if wasRecording, !self.isEngineRunning {
                    // タップ再設置には成功したが、その後のエンジン再起動(engine.start())に失敗した。
                    // `startEngineLocked()`内で既にfatalError通知はdelegateへ送っている(Coordinator側で
                    // 状態をidleへ戻す)ため、ここではAudioCaptureEngine内部の録音状態もそれに整合させて
                    // クリアするだけでよい(二重にdelegateを呼ぶと空バッファの完了が発火してしまうため、
                    // ここではdelegate呼び出しは行わない)。
                    self.isRecording = false
                    self.recordingBuffer = []
                }
            }
        }
    }
}
