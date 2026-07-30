import AVFoundation
import Foundation
import os.log
import VoicewriterObjC

protocol AudioCaptureEngineDelegate: AnyObject {
    /// 録音が正常終了し、16kHz/mono/Float32のPCMサンプルが確定した
    func audioCaptureEngine(_ engine: AudioCaptureEngineControlling, didFinishRecording samples: [Float], sampleRate: Double)
    /// 録音がキャンセルされた(Escなど)
    func audioCaptureEngineDidCancelRecording(_ engine: AudioCaptureEngineControlling)
    /// タップ再設置失敗・不正な入力フォーマット・エンジン起動失敗など、
    /// 録音を継続できない致命的な状態になった。録音中だった場合は呼び出し側でidleへ戻すこと。
    func audioCaptureEngine(_ engine: AudioCaptureEngineControlling, didEncounterFatalError message: String)
    /// `didEncounterFatalError`で通知した障害から自動復旧した(タップ再設置に成功し、
    /// 必要ならエンジンも再起動できた)。呼び出し側はメニューバー警告を取り下げてよい。
    /// デフォルト実装は何もしないため、実装は任意。
    func audioCaptureEngineDidRecoverFromFatalError(_ engine: AudioCaptureEngineControlling)
}

extension AudioCaptureEngineDelegate {
    func audioCaptureEngineDidRecoverFromFatalError(_ engine: AudioCaptureEngineControlling) {}
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
    /// タップ再設置(`installTap`)が失敗したときの自動リトライ上限回数。
    /// Bluetoothヘッドセットの接続直後などは、macOSが既定入力/出力の集約デバイス
    /// (CADefaultDeviceAggregate)を組み直す間、入力ハードウェアのサンプルレートが
    /// 数百ms〜数秒かけて落ち着く。その間はタップを張れないため、諦めずに再試行する。
    static let tapRetryMaxAttempts = 10
    /// 1回の障害エピソードで復旧を諦めるまでの上限時間。
    /// `AVAudioEngineConfigurationChange`が繰り返し届く状況では試行回数が毎回リセットされるため、
    /// 回数だけでは「復旧できないまま警告も出ずに再試行し続ける」状態になりうる。
    /// 経過時間でも打ち切ることで、必ずユーザーへ警告が出るようにする。
    static let tapRecoveryGiveUpInterval: TimeInterval = 60

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

    // MARK: - タップ再設置リトライ状態(controlQueue上でのみ読み書きすること)

    /// 現在のリトライ試行回数(成功したら0に戻す)。
    private var tapRetryAttempt = 0
    private var tapRetryWorkItem: DispatchWorkItem?
    /// タップを張り直せた後にエンジンを起動し直すべきか(障害発生前に起動していたか)。
    private var shouldRestartEngineAfterTapRetry = false
    /// `didEncounterFatalError`をdelegateへ通知済みか。復旧時に一度だけ
    /// `audioCaptureEngineDidRecoverFromFatalError`を送って警告を取り下げるためのフラグ。
    private var hasReportedDeviceFailure = false
    /// 現在のタップで最初のバッファを受け取ったことをログしたか。
    /// 「タップは張れたが音声が1つも届かない」状態(デバイス構成変更の復旧漏れ)を
    /// ログだけで切り分けられるようにするための1回限りの診断。
    private var didLogFirstBufferForCurrentTap = false
    /// タップの世代。張り直すたびに増やし、タップのコールバックへ捕捉させる。
    /// デバイス切替の最中は、外した直後の古いタップのコールバックが遅れて`controlQueue`へ
    /// 届くことがある。世代が古いバッファは(別フォーマットで録音へ混入しうるため)捨てる。
    private var tapGeneration: UInt64 = 0
    /// 現在の障害エピソードが始まった時刻(復旧できたらnilに戻す)。
    private var tapFailureEpisodeStartedAt: Date?
    /// 現在の障害エピソードで「復旧を諦めた」警告を出したか。
    private var hasReportedRetryExhaustion = false

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
            if !installTapIfNeededLocked() {
                // 起動直後は既定デバイスの集約(CADefaultDeviceAggregate)構築中で
                // 入力フォーマットが安定していないことがある。諦めずにリトライを予約する
                // (この時点ではまだユーザーへ警告は出さない。リトライを使い切ってから出す)。
                scheduleTapReinstallRetryLocked()
            }
            prepareEngineLocked()
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
            // 起動時の自動起動なので、この時点でタップが張れていなくてもすぐには警告を出さない
            // (既定デバイスの構成が落ち着くのを待って自動的に再試行する。それでも復帰できなければ
            //  リトライ上限に達した時点で警告が出る)。
            self?.startEngineLocked(reportTapFailureImmediately: false)
        }
    }

    // MARK: - Engine lifecycle (controlQueue上でのみ呼ぶこと)

    /// 現在のinputNodeのフォーマットを見てタップを設置し、コンバータを生成する。
    /// タップに渡すフォーマットの選び方は`tapFormatSpec`を参照。
    /// 使えるフォーマットが無い(サンプルレート/チャンネル数が0以下)、コンバータ生成に失敗、
    /// `installTap`がObjC例外を投げた場合は、何もインストールせずfalseを返す
    /// (呼び出し側は録音状態に遷移しない/戻すこと。必要ならリトライを予約すること)。
    @discardableResult
    private func installTapIfNeededLocked() -> Bool {
        guard !isTapInstalled else { return true }
        let input = engine.inputNode
        // 張り直す直前に取り直す。構成変更通知の直後は、通知を受けた時点のフォーマットが
        // すでに古くなっていることがある。
        let format = input.outputFormat(forBus: 0)
        // inputNodeの入力側フォーマット = 実オーディオハードウェアのフォーマット。
        // AVFoundationは`installTap`時に「タップのフォーマットのサンプルレート == 入力ハードウェアの
        // サンプルレート」を要求し、破ると`NSException`をraiseする。この2つは通常一致するが、
        // 実測では既定入力デバイスがBluetoothヘッドセットのときに恒常的に食い違うことがある
        // (詳細は`tapFormatSpec`のコメント)。
        let hardwareFormat = input.inputFormat(forBus: 0)
        // タップ設置は起動時とデバイス構成変更時にしか起きないため、調査に必須のこの情報は
        // info(永続化される)で残す。実際に起きたクラッシュの原因究明にはこの2つの
        // フォーマットの食い違いが決定的だった。
        log.info("""
            Input node formats: client=\(format.sampleRate, privacy: .public)Hz/\(format.channelCount, privacy: .public)ch \
            hardware=\(hardwareFormat.sampleRate, privacy: .public)Hz/\(hardwareFormat.channelCount, privacy: .public)ch
            """)

        guard let spec = Self.tapFormatSpec(
            clientSampleRate: format.sampleRate,
            clientChannelCount: format.channelCount,
            hardwareSampleRate: hardwareFormat.sampleRate,
            hardwareChannelCount: hardwareFormat.channelCount
        ) else {
            log.error("""
                No tappable input format available: client=\(format.sampleRate)Hz/\(format.channelCount)ch \
                hardware=\(hardwareFormat.sampleRate)Hz/\(hardwareFormat.channelCount)ch
                """)
            return false
        }

        let tapFormat: AVAudioFormat
        if spec.sampleRate == format.sampleRate, spec.channelCount == format.channelCount {
            // 通常ケース: ノードが公開しているフォーマットのまま張る。
            tapFormat = format
        } else {
            // ハードウェアのサンプルレートに合わせ直すケース(Bluetoothヘッドセットなど)。
            guard let rebuilt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: spec.sampleRate,
                channels: spec.channelCount,
                interleaved: false
            ) else {
                log.error("Failed to build tap format \(spec.sampleRate)Hz/\(spec.channelCount)ch")
                return false
            }
            log.warning("""
                Input node format disagrees with the hardware; tapping at the hardware format instead: \
                \(spec.sampleRate, privacy: .public)Hz/\(spec.channelCount, privacy: .public)ch
                """)
            tapFormat = rebuilt
        }

        guard let newConverter = makeConverterLocked(from: tapFormat) else { return false }

        tapGeneration &+= 1
        let generation = tapGeneration
        var installError: NSError?
        let installed = VWCatchException({
            input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
                guard let self else { return }
                self.controlQueue.async {
                    self.handleIncomingLocked(buffer: buffer, generation: generation)
                }
            }
        }, &installError)

        guard installed else {
            // AVFoundationの事前条件違反(例: `format.sampleRate == inputHWFormat.sampleRate`)。
            // Swiftでは捕捉できずプロセスがabortしていたケース。タップ未設置として扱い、
            // 呼び出し側でリトライさせる。
            log.error("""
                installTap raised an ObjC exception; treating tap as not installed: \
                \(installError?.localizedDescription ?? "unknown", privacy: .public)
                """)
            // 例外の投げられ方によっては内部状態に半端なタップが残る可能性があるため、
            // 念のため取り外しておく(タップが無いバスへのremoveTapは無害)。
            _ = VWCatchException({ input.removeTap(onBus: 0) }, nil)
            converter = nil
            return false
        }

        converter = newConverter
        isTapInstalled = true
        didLogFirstBufferForCurrentTap = false
        log.info("Input tap installed: \(tapFormat.sampleRate, privacy: .public)Hz ch=\(tapFormat.channelCount, privacy: .public)")
        return true
    }

    /// `targetFormat`(16kHz/mono/Float32)へ変換するコンバータを生成する。
    /// 生成自体もObjC例外を投げうる(想定外のフォーマットの場合)ため`@try/@catch`で包む。
    private func makeConverterLocked(from format: AVAudioFormat) -> AVAudioConverter? {
        var created: AVAudioConverter?
        var error: NSError?
        let ok = VWCatchException({ created = AVAudioConverter(from: format, to: targetFormat) }, &error)
        guard ok, let created else {
            log.error("""
                Failed to create AVAudioConverter for format sampleRate=\(format.sampleRate) \
                channels=\(format.channelCount): \(error?.localizedDescription ?? "nil converter", privacy: .public)
                """)
            return nil
        }
        // 既定のまま(未指定)だとサンプルレート変換の品質・アルゴリズムがシステム任せになる。
        // マイクの native sample rate(多くは44.1/48kHz)から16kHzへ毎回ダウンサンプルするため、
        // 明示的に最高品質を指定する(認識精度に影響しうるエイリアシング・リサンプル品質の劣化を避ける)。
        // 一次情報: https://developer.apple.com/documentation/avfaudio/avaudioconverter/samplerateconverterquality
        created.sampleRateConverterQuality = .max
        return created
    }

    /// 入力フォーマットとして妥当か(純粋関数・テスト用に切り出し)。
    static func isValidInputFormat(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && sampleRate.isFinite && channelCount > 0
    }

    /// タップに渡すべきフォーマット(サンプルレートとチャンネル数)を決める(純粋関数・テスト用に切り出し)。
    /// 張れるフォーマットが無い場合はnil(=タップを張らずにリトライする)。
    ///
    /// AVFoundationの`InstallTapOnNode`は「タップに渡すフォーマットのサンプルレート ==
    /// 入力ハードウェアのサンプルレート」という事前条件を持ち、破ると`NSException`をraiseして
    /// プロセスをabortさせる(2026-07-30の起動時クラッシュの直接原因)。
    ///
    /// ところが`AVAudioInputNode`が公開するフォーマット(`outputFormat(forBus:0)`)は、
    /// 入力と出力でサンプルレートが異なるデバイス(Bluetoothヘッドセット: 入力16kHz/出力44.1kHz)が
    /// 既定デバイスのとき、macOSが組む既定入出力の集約デバイス(CADefaultDeviceAggregate)の
    /// 都合で出力側の44.1kHzを名乗り続けることがあり、実ハードウェアの入力(16kHz)と一致しない。
    /// この食い違いは一時的とは限らず、待っても解消しない。
    ///
    /// そこで、両者が食い違う場合は「実ハードウェア側」を正としてタップのフォーマットを決める
    /// (inputNodeのバスは他ノードへ接続していないため、タップ側からフォーマットを指定してよい)。
    /// 一次情報: https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)
    static func tapFormatSpec(
        clientSampleRate: Double,
        clientChannelCount: AVAudioChannelCount,
        hardwareSampleRate: Double,
        hardwareChannelCount: AVAudioChannelCount
    ) -> (sampleRate: Double, channelCount: AVAudioChannelCount)? {
        let clientIsValid = isValidInputFormat(sampleRate: clientSampleRate, channelCount: clientChannelCount)
        let hardwareIsValid = isValidInputFormat(sampleRate: hardwareSampleRate, channelCount: hardwareChannelCount)

        // 通常ケース: 公開フォーマットが妥当で、ハードウェアのサンプルレートと一致している
        // (またはハードウェア情報が取得できない)ならそのまま使う。
        if clientIsValid, !hardwareIsValid || clientSampleRate == hardwareSampleRate {
            return (clientSampleRate, clientChannelCount)
        }
        // 食い違うケース: ハードウェア側に合わせる。
        if hardwareIsValid {
            return (hardwareSampleRate, hardwareChannelCount)
        }
        return nil
    }

    /// n回目のリトライまでの待ち時間(純粋関数・テスト用に切り出し)。
    /// 指数バックオフ(0.3s→0.6s→1.2s…)で、上限5秒。
    static func tapRetryDelay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(max(1, attempt) - 1)
        return min(0.3 * pow(2, exponent), 5.0)
    }

    // MARK: - タップ再設置のリトライ(controlQueue上でのみ呼ぶこと)

    /// タップ設置(またはその後のエンジン起動)に失敗した状態からの自動復旧を予約する。
    /// 試行回数または経過時間の上限に達している場合は復旧を諦め、メニューバー警告用の
    /// 致命的エラーを通知する。
    private func scheduleTapReinstallRetryLocked() {
        tapRetryWorkItem?.cancel()
        tapRetryWorkItem = nil

        let episodeStart = tapFailureEpisodeStartedAt ?? Date()
        tapFailureEpisodeStartedAt = episodeStart
        let elapsed = Date().timeIntervalSince(episodeStart)
        guard tapRetryAttempt < Self.tapRetryMaxAttempts, elapsed < Self.tapRecoveryGiveUpInterval else {
            log.error("""
                Gave up recovering the input tap (attempts=\(self.tapRetryAttempt, privacy: .public) \
                elapsed=\(elapsed, privacy: .public)s)
                """)
            // 「再設定を試みています」という途中経過の警告が残ったままにならないよう、
            // 諦めたことは(既に別の警告を出していても)必ず一度は通知する。
            // 同じエピソード中の重複通知だけを`hasReportedRetryExhaustion`で抑止する。
            if !hasReportedRetryExhaustion {
                hasReportedRetryExhaustion = true
                reportFatalErrorLocked(
                    "マイク入力を利用できません(入力デバイスの再設定を繰り返し試みましたが復帰できませんでした)。マイクの接続を確認するか、Voicewriterを再起動してください。"
                )
            }
            return
        }

        tapRetryAttempt += 1
        let attempt = tapRetryAttempt
        let delay = Self.tapRetryDelay(forAttempt: attempt)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.log.info("Retrying input tap installation (attempt \(attempt, privacy: .public)/\(Self.tapRetryMaxAttempts, privacy: .public))")
            self.retryTapInstallLocked()
        }
        tapRetryWorkItem = workItem
        controlQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        log.info("Scheduled input tap reinstall in \(delay, privacy: .public)s (attempt \(attempt, privacy: .public))")
    }

    private func retryTapInstallLocked() {
        tapRetryWorkItem = nil
        // 「タップは張れたが、その後のエンジン起動に失敗した」ケースもここへ来るため、
        // タップ設置済みでも打ち切らずに起動のやり直しまで面倒を見る。
        if !isTapInstalled, !installTapIfNeededLocked() {
            scheduleTapReinstallRetryLocked()
            return
        }
        prepareEngineLocked()

        // 障害前に起動していた場合、またはAlwaysOnモードで常時起動が期待される場合は起動し直す。
        if shouldRestartEngineAfterTapRetry || Settings.micMode == .alwaysOn {
            startEngineLocked(reportTapFailureImmediately: false)
            guard isEngineRunning else {
                // 起動にも失敗した。同じバックオフで再試行を続ける
                // (`startEngineLocked`が予約済みだが、取りこぼしがないよう念のため確認する)。
                ensureTapRecoveryScheduledLocked()
                return
            }
            scheduleIdleStopIfNeededLocked()
        }

        shouldRestartEngineAfterTapRetry = false
        tapRetryAttempt = 0
        tapFailureEpisodeStartedAt = nil
        hasReportedRetryExhaustion = false
        log.info("Input tap recovered")
        clearFatalErrorLocked()
    }

    /// OnDemandモードで録音していないのにエンジンが動いている状態(復旧のために起動し直した直後など)
    /// を、既存のアイドル停止タイマーに載せてマイクをオフに戻す。
    /// AlwaysOnモードや録音中は何もしない。
    private func scheduleIdleStopIfNeededLocked() {
        guard Settings.micMode == .onDemand, !isRecording, isEngineRunning else { return }
        scheduleIdleStop()
    }

    /// 復旧が必要な状態(タップ未設置、またはエンジンを起動し直せていない)のときに、
    /// リトライ予約を(まだ無ければ)入れる。
    private func ensureTapRecoveryScheduledLocked() {
        guard tapRetryWorkItem == nil else { return }
        scheduleTapReinstallRetryLocked()
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
        // `removeTap`自体もグラフの状態次第でObjC例外をraiseしうるため保護する
        // (ここで落ちるとタップを外せないまま復旧不能になる)。
        var error: NSError?
        if !VWCatchException({ self.engine.inputNode.removeTap(onBus: 0) }, &error) {
            log.error("removeTap raised an ObjC exception: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        }
        isTapInstalled = false
        didLogFirstBufferForCurrentTap = false
    }

    /// - Parameter reportTapFailureImmediately: タップが張れずエンジンを起動できなかった場合に、
    ///   その場でメニューバー警告用の致命的エラーを通知するか。ユーザー操作(録音開始)起因なら`true`、
    ///   起動時の自動起動のように「黙って再試行すればよい」場合は`false`。
    private func startEngineLocked(reportTapFailureImmediately: Bool = true) {
        guard !isEngineRunning else { return }
        guard installTapIfNeededLocked() else {
            // タップが張れない = 入力デバイスの構成がまだ落ち着いていない可能性がある。
            // 自動復旧を予約したうえで、今回の起動要求は失敗として通知する。
            shouldRestartEngineAfterTapRetry = true
            ensureTapRecoveryScheduledLocked()
            if reportTapFailureImmediately {
                reportFatalErrorLocked("マイク入力の準備ができていないため録音を開始できません。マイクの接続を確認してください(自動的に再試行します)。")
            }
            return
        }
        do {
            var startError: NSError?
            // `engine.start()`はSwiftのthrowsで受け取れるNSErrorのほかに、グラフの構成が
            // 壊れている場合はObjC例外もraiseしうるため`@try/@catch`でも包む。
            var thrownSwiftError: Error?
            let didNotRaise = VWCatchException({
                do { try self.engine.start() } catch { thrownSwiftError = error }
            }, &startError)
            if let thrownSwiftError { throw thrownSwiftError }
            guard didNotRaise else {
                throw startError ?? NSError(domain: VWExceptionCatcherErrorDomain, code: 1)
            }
            isEngineRunning = true
            log.info("AVAudioEngine started")
            clearFatalErrorLocked()
        } catch {
            log.error("AVAudioEngine start failed: \(error.localizedDescription, privacy: .public)")
            // タップは張れているが起動できなかった。デバイス切替の途中などで一時的に起きうるため、
            // タップ設置失敗と同じバックオフで起動をやり直す(そのままだと警告が出たきり
            // ユーザー操作か次の構成変更まで復旧しない)。
            shouldRestartEngineAfterTapRetry = true
            ensureTapRecoveryScheduledLocked()
            reportFatalErrorLocked("マイクの起動に失敗しました: \(error.localizedDescription)")
        }
    }

    private func stopEngineLocked() {
        guard isEngineRunning else { return }
        // 半端なグラフ状態では`stop()`もObjC例外をraiseしうる。
        var error: NSError?
        if !VWCatchException({ self.engine.stop() }, &error) {
            log.error("AVAudioEngine stop raised an ObjC exception: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        }
        isEngineRunning = false
        log.info("AVAudioEngine stopped")
    }

    /// `engine.prepare()`のObjC例外保護版。例外を捕まえてもグラフは半端なままなので、
    /// 呼び出し側はこの後の操作(タップ設置・起動)が失敗しうる前提で扱うこと。
    private func prepareEngineLocked() {
        var error: NSError?
        if !VWCatchException({ self.engine.prepare() }, &error) {
            log.error("AVAudioEngine prepare raised an ObjC exception: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        }
    }

    private func reportFatalErrorLocked(_ message: String) {
        log.error("\(message, privacy: .public)")
        hasReportedDeviceFailure = true
        delegate?.audioCaptureEngine(self, didEncounterFatalError: message)
    }

    /// `reportFatalErrorLocked`で通知した障害から復旧したことをdelegateへ伝える
    /// (メニューバー警告の取り下げ用)。未通知の場合は何もしない。
    private func clearFatalErrorLocked() {
        guard hasReportedDeviceFailure else { return }
        hasReportedDeviceFailure = false
        log.info("Audio device failure recovered; withdrawing warning")
        delegate?.audioCaptureEngineDidRecoverFromFatalError(self)
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

        // ユーザーの明示的な操作(録音開始)なので、過去に使い切ったリトライ回数と
        // 経過時間はリセットして改めて復旧を試せるようにする
        // (タップが張れていない場合のみ意味を持つ)。
        if !isTapInstalled {
            tapRetryAttempt = 0
            tapFailureEpisodeStartedAt = nil
            hasReportedRetryExhaustion = false
        }

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
                // タイマーのキャンセルが間に合わなかった場合(既に内側のクロージャを
                // `controlQueue`へ投入した後に次の録音が始まった場合など)に、
                // 動作中の録音を止めてしまわないよう実行時にも条件を確認する。
                guard Settings.micMode == .onDemand, !self.isRecording else { return }
                self.stopEngineLocked()
            }
        }
        idleStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.onDemandIdleTimeoutSeconds, execute: workItem)
    }

    // MARK: - Audio processing (controlQueue上でのみ呼ぶこと)

    /// タップから届いたバッファのフォーマットに対応するコンバータを返す。
    /// フォーマットがコンバータ生成時と食い違っている場合は作り直す。
    ///
    /// デバイス構成変更の前後では、タップ設置時に取得したフォーマットと実際に届くバッファの
    /// フォーマットが一致しないことがありうる。食い違ったままのコンバータへ渡すと変換エラー
    /// (最悪の場合ObjC例外)になるため、届いた実バッファのフォーマットを正として追従する。
    private func converterForIncomingLocked(bufferFormat: AVAudioFormat) -> AVAudioConverter? {
        if let converter, converter.inputFormat.isEqual(bufferFormat) { return converter }
        log.warning("""
            Tap buffer format changed (\(bufferFormat.sampleRate)Hz/\(bufferFormat.channelCount)ch); \
            rebuilding converter
            """)
        guard let rebuilt = makeConverterLocked(from: bufferFormat) else {
            converter = nil
            // 届いた音声を1つも変換できない = 録音しても無音になる。
            // 「録音中に見えるのに全部捨てている」状態を避けるため、復旧対象として扱う。
            handleUnusableTapLocked(
                reason: "tap buffer format \(bufferFormat.sampleRate)Hz/\(bufferFormat.channelCount)ch is not convertible"
            )
            return nil
        }
        converter = rebuilt
        return rebuilt
    }

    /// タップは張れているのに音声を使えない(変換できない)状態から復旧を試みる。
    /// 録音中ならその録音を中断し、タップを張り直すところからやり直す。
    private func handleUnusableTapLocked(reason: String) {
        log.error("Input tap is unusable (\(reason, privacy: .public)); reinstalling")
        if isRecording {
            isRecording = false
            recordingBuffer = []
            reportFatalErrorLocked("マイク入力の音声を処理できなかったため録音を中断しました。マイク入力の再設定を試みています。")
        }
        let wasRunning = isEngineRunning
        removeTapLocked()
        stopEngineLocked()
        shouldRestartEngineAfterTapRetry = wasRunning
        ensureTapRecoveryScheduledLocked()
    }

    private func handleIncomingLocked(buffer: AVAudioPCMBuffer, generation: UInt64) {
        // 張り替え前の古いタップから遅れて届いたバッファは、フォーマットが異なりうるため捨てる
        // (受理するとコンバータが古いフォーマットへ作り直され、録音に切替前後の音声が混ざる)。
        guard generation == tapGeneration else { return }
        if !didLogFirstBufferForCurrentTap {
            didLogFirstBufferForCurrentTap = true
            log.info("""
                First tap buffer received: \(buffer.format.sampleRate, privacy: .public)Hz/\
                \(buffer.format.channelCount, privacy: .public)ch frames=\(buffer.frameLength, privacy: .public)
                """)
        }
        guard buffer.format.sampleRate > 0 else { return }
        guard let converter = converterForIncomingLocked(bufferFormat: buffer.format) else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        var status: AVAudioConverterOutputStatus = .error
        // フォーマットの不整合が残っていた場合、`convert`はObjC例外をraiseしうる
        // (Swiftでは捕捉できずabortする)。ここも例外境界で囲む。
        var conversionException: NSError?
        let converted = VWCatchException({
            status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return buffer
            }
        }, &conversionException)
        guard converted else {
            handleUnusableTapLocked(
                reason: "convert raised an ObjC exception: \(conversionException?.localizedDescription ?? "unknown")"
            )
            return
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

            // デバイス構成が変わった以上、前回のリトライ予約と試行回数はここでリセットする
            // (でないと、以前に上限まで使い切っていた場合に一度も再試行せず諦めてしまう)。
            self.tapRetryWorkItem?.cancel()
            self.tapRetryWorkItem = nil
            self.tapRetryAttempt = 0
            if self.hasReportedRetryExhaustion {
                // 前の障害エピソードは「復旧できませんでした」と警告して終了済み。
                // 新しいデバイスイベントなので、エピソードを開き直して改めて復旧を試みる。
                self.hasReportedRetryExhaustion = false
                self.tapFailureEpisodeStartedAt = nil
            }
            // 逆に、まだ終了していないエピソードの開始時刻は保持する。構成変更通知が
            // 繰り返し届く状況でも、経過時間の上限で必ず打ち切って警告が出るようにするため。
            self.shouldRestartEngineAfterTapRetry = wasRunning

            guard self.installTapIfNeededLocked() else {
                // 新フォーマットが不正/ハードウェアと不一致、またはコンバータ生成に失敗した。
                // 例外クラッシュや無音録音を避けるためこの時点ではタップを張らず、
                // 少し待ってから自動的に再試行する(Bluetoothデバイスの接続直後など、
                // 数百ms〜数秒で入力フォーマットが落ち着くケースが実際にある)。
                if wasRecording {
                    // 録音中だった場合は、その録音を安全に破棄してidleへ戻す(fatalError通知経由)。
                    // 復旧を待たせても取りこぼした音声は戻らないため、録音は諦める。
                    self.isRecording = false
                    self.recordingBuffer = []
                    self.reportFatalErrorLocked("音声デバイスの構成が変わったため録音を中断しました。マイク入力の再設定を試みています。")
                }
                self.scheduleTapReinstallRetryLocked()
                return
            }
            self.shouldRestartEngineAfterTapRetry = false

            self.prepareEngineLocked()
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
                self.scheduleIdleStopIfNeededLocked()
            }
            if self.isTapInstalled, !wasRunning || self.isEngineRunning {
                // 復旧完了。エンジン再起動を伴わない(OnDemandで停止中だった)場合は
                // `startEngineLocked()`を通らないため、ここでも警告を取り下げる。
                self.tapRetryAttempt = 0
                self.tapFailureEpisodeStartedAt = nil
                self.hasReportedRetryExhaustion = false
                self.clearFatalErrorLocked()
            }
        }
    }
}
