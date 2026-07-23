import AppKit
import Foundation
import KeyboardShortcuts
import os.log

enum AppState {
    case idle
    case recording
    case transcribing
}

/// ハルシネーション対策(多層防御)により、文字起こし結果が得られず(または既知の
/// ハルシネーション定型句のみと判定され)録音サイクルがスキップされた理由。
/// HUD表示の出し分け専用の付加情報であり、状態機械のロジックには影響しない。
enum RecordingSkipReason: Equatable {
    /// 第1層: 録音実効長(キー押下〜離しの長さ、プリロール除く)が閾値未満だった。
    case tooShort
    /// 第2〜5層: 発話とみなせるエネルギーが無い、VAD/no_speech_probにより発話区間が
    /// 検出されなかった、または既知のハルシネーション定型句のみと判定された。
    case silence
}

/// どちらの操作方法で録音が開始されたか(PTTのkeyUpとトグルのkeyUpを混同しないため)
private enum ActivationSource: Equatable {
    case pushToTalk
    case toggle
}

/// `.transcribing`中の内部フェーズ(HUD表示専用の付加情報)。
/// `AppState`自体はこの間ずっと`.transcribing`のままであり、状態機械のロジックには一切影響しない。
enum TranscriptionPhase {
    /// whisper.cppによる音声認識中
    case recognizing
    /// 認識結果をLLMで整形中
    case formatting
}

/// 実際の録音デバイス操作の可否を決める状態。連続音声入力パイプライン導入に伴い、`AppState`
/// (表示用の導出値)とは分離した。**録音の可否はこの状態のみで判定し、処理中のジョブの有無は
/// 録音を妨げない**(これが今回のパイプライン化の核心)。
enum RecordingState: Equatable {
    case idle
    case recording
    /// `stopRecording()`を呼んだ後、`AudioCaptureEngine`内部の停止グレース(既定100ms)が
    /// 明けて`didFinishRecording`/`didCancelRecording`が届くまでの間。この間に新規録音開始要求
    /// (ホットキー)が来た場合は即座に開始せず保留し、グレースが明けて前ジョブのバッファが
    /// 確定した直後に自動的に開始する(`AudioCaptureEngine.controlQueue`上の完了と競合させないため)。
    case finalizing
}

/// ジョブのコミット結果を伴うイベント。`DeliveryCoordinator`のコミット結果をそのまま外へ中継する
/// (HUD/メニューバー配線用)。
typealias DictationJobCommitEvent = DeliveryCommitResult

/// idle / recording / transcribing の状態機械。全体の司令塔。
///
/// 連続音声入力パイプライン: 前の発話の認識・整形中でも次の録音を即座に開始できるようにするため、
/// 「録音の可否(`RecordingState`)」と「表示用の状態(`AppState`)」を分離し、複数ジョブの認識・整形
/// (`SerialFIFOQueue`で直列化)と、発話順を厳守したテキスト挿入(`DeliveryCoordinator`)を、
/// それぞれ独立した実行系として扱う。
@MainActor
final class Coordinator: AudioCaptureEngineDelegate {
    private let log = Logger(subsystem: "dev.voicewriter.app", category: "Coordinator")

    /// 未終端(コミット待ちも含む)ジョブ数の上限。到達時は新規録音の開始を拒否する
    /// (処理が全く追いつかなくなる状況でのメモリ膨張・体感遅延の暴走を防ぐための安全弁)。
    static let maxUnterminatedJobs = 8

    /// 表示用の状態(StatusBar/HUD互換)。録音可否には使わない。実体は`recordingState`と
    /// `jobRegistry`から導出される(`recomputeState()`)。
    private(set) var state: AppState = .idle {
        didSet {
            guard state != oldValue else { return }
            log.info("State: \(String(describing: self.state))")
            onStateChanged?(state)
            updateCancelShortcutEnabled()
        }
    }

    /// 実際の録音デバイス操作の可否を決める状態。録音可否の判定はこれのみで行う。
    private var recordingState: RecordingState = .idle {
        didSet {
            guard recordingState != oldValue else { return }
            deliveryCoordinator.setRecordingActive(recordingState != .idle)
            recomputeState()
        }
    }

    /// 状態が変わるたびに呼ばれる(StatusBarControllerがアイコン更新に使う)
    var onStateChanged: ((AppState) -> Void)?
    /// ジョブのコミット結果(挿入完了/スキップ/キャンセル/失敗/フォーカス不一致)が確定するたびに呼ばれる。
    /// sequenceは録音開始時に採番された発話順の番号。
    var onJobCommitted: ((_ sequence: Int, _ result: DictationJobCommitEvent) -> Void)?
    /// 未終端ジョブ数が変化するたびに呼ばれる(HUDの「残り件数」表示用)。
    var onPendingJobCountChanged: ((Int) -> Void)?
    /// キュー上限(`maxUnterminatedJobs`)に達しており新規録音を拒否したときに呼ばれる。
    /// 通常のビープと区別できるHUD表示(「処理が追いついていません」)用。
    var onQueueFull: (() -> Void)?
    /// 録音を継続できない致命的なエラーが起きた際に呼ばれる(メニューバー警告用)。
    var onFatalAudioError: ((String) -> Void)?
    /// LLM整形が失敗し、原文へフォールバックした際に呼ばれる(メニューバーの軽い警告用)。
    var onFormattingFailed: ((String) -> Void)?
    /// `.transcribing`中の内部フェーズが変わるたびに呼ばれる(HUDの「認識中/整形中」表示切替用)。
    /// 表示専用の通知であり、状態機械のロジックには影響しない。常にFIFOの先頭(=現在実際に
    /// 推論を実行しているジョブ)についての通知になる。
    var onPhaseChanged: ((TranscriptionPhase) -> Void)?
    /// LLM整形がOllama未起動(サーバー到達不可)により失敗した際に呼ばれる。`onFormattingFailed`とは
    /// 区別し、こちらは発話のたびに5秒間フェードする警告バナーを出さない(Ollama未導入は例外的状況
    /// ではなく通常運用でありうる状態のため、毎回のナグ通知を避ける)。メニューバーの
    /// 「LLM整形: 無効(Ollama未検出)」という常設の状態表示の切り替えに使う想定。
    var onFormattingUnavailable: (() -> Void)?
    /// LLM整形が成功した際に呼ばれる(整形自体が有効かつ実行された場合、成功のたびに毎回呼ばれる)。
    /// `onFormattingUnavailable`で立てた「Ollama未検出」の状態表示を元に戻す(後からOllamaが
    /// 起動された場合に、次の整形成功時点で自動的に状態表示を消すため)のに使う想定。
    /// 呼び出し側は冪等に扱ってよい(既に「利用可能」表示であれば無視してよい)。
    var onFormattingRecovered: (() -> Void)?

    /// whisperモデルの初回自動セットアップ(ダウンロード)が進行中かどうか。既定`false`
    /// (このプロパティを使わない呼び出し元・テストの挙動には一切影響しない)。`AppDelegate`が
    /// `ModelDownloader.state`の変化に応じて更新する。trueの間は新規録音の開始要求を
    /// (PTT/トグルいずれも)受け付けず拒否する。誤ってスタブへ流れダミーテキストが挿入される
    /// ことを防ぐため、フォールバックはさせず拒否のみとする(録音自体は開始しない)。
    var isModelSetupBlocking = false
    /// セットアップ中(`isModelSetupBlocking == true`)に録音開始が要求され、拒否した際に呼ばれる
    /// (HUDの「セットアップ中です」表示用)。
    var onRecordingRejectedDuringSetup: (() -> Void)?

    private let audioEngine: AudioCaptureEngineControlling
    private let transcriptionEngine: TranscriptionEngine
    /// 音声認識結果の整形に使うLLMフォーマッタ。`nil`なら整形自体を行わない(未整形のまま挿入)。
    private let textFormatter: TextFormatter?

    /// ジョブごとの状態(未終端/終端)とキャンセルフラグの一元管理。
    private let jobRegistry = DictationJobRegistry()
    /// whisper.cpp(認識)とOllama(整形)の直列化。J1(認識・整形)→J2(認識・整形)→…の順で実行する
    /// (両者が同じUnified Memory/GPUを奪い合うため、録音とは独立にこのFIFOでのみ直列化する)。
    private let inferenceQueue = SerialFIFOQueue()
    /// 発話順(sequence順)を厳守したテキスト挿入のリオーダーバッファ。
    private let deliveryCoordinator: DeliveryCoordinator

    private var activationSource: ActivationSource?
    /// 現在録音中(または録音停止グレー中)のセッションに関するスクラッチ変数。
    /// 同時に録音できるセッションは常に高々1つのため(`recordingState`が保証する)、
    /// このCoordinator上の単一スロットで保持して問題ない。録音終了(`didFinishRecording`)の
    /// 時点で`DictationJob`という不変な値へ切り出し、以後の非同期処理(認識・整形・配送)は
    /// その値だけを参照する(後続の録音がこのスクラッチ変数を上書きしても、既に切り出し済みの
    /// 古いジョブには影響しない)。
    private var recordingFrontmostApp: NSRunningApplication?
    private var recordingStartedAt: Date?
    private var pendingJobSettingsSnapshot: DictationJobSettingsSnapshot?
    /// 現在録音中(または録音停止グレー中)のジョブの`sequence`。仕様通り「録音開始時」に採番し、
    /// `didFinishRecording`/`didCancelRecording`/`didEncounterFatalError`のいずれでも、この値を
    /// そのまま該当ジョブの終端処理に使う(録音終了時に改めて採番はしない)。これにより、
    /// 「現在の録音のジョブID」が録音中から存在するようになり、Escの階層的キャンセル(後述)や
    /// キュー上限判定が録音中の枠も正しく数えられる。
    private var currentRecordingSequence: Int?
    /// `.finalizing`中(録音停止済みグレー待ち)にホットキーで新規録音が要求された場合、
    /// ここに保留し、グレースが明けた直後(`finalizeRecordingTransition()`)に自動的に開始する。
    private var pendingStartRequest: ActivationSource?
    /// PTT(Push-to-Talk)キーが現在押されているか。`beginPushToTalk()`でtrueに、
    /// `endPushToTalk()`でfalseにする。`finalizing`中の保留や挿入クリティカル区間待機など、
    /// 非同期の`await`を挟んでから実際に録音を開始する経路で、開始直前にキーが既に
    /// 離されていないかを確認するために使う(離されていた場合はkeyUpが来ないまま
    /// 録音し続けてしまうため、開始自体を取りやめる)。
    private var isPushToTalkKeyDown = false

    /// ハルシネーション対策(多層防御)の第1層: 録音実効長(キー押下〜離しの長さ、プリロール除く)の
    /// 最短閾値。これ未満なら文字起こし自体を行わない(設定不要のハードコード)。
    /// 誤ってホットキーに触れてすぐ離した場合の無音ハルシネーションを、whisper_full呼び出し前の
    /// 最も早い段階で弾くためのガード。
    static let minimumEffectiveRecordingDuration: TimeInterval = 0.3

    /// 現在時刻を取得するためのクロージャ。既定は実時計(`Date.init`)。
    /// テストでは`beginPushToTalk()`〜`endPushToTalk()`が実時間ではなく同期的に(数マイクロ秒で)
    /// 呼ばれるため、実時計のままだと第1層の最短録音時間ガードに常に引っかかってしまう。
    /// そのため単調に増加する値を返すフェイクへ差し替えられるようにしている
    /// (`minimumEffectiveRecordingDuration`自体は変更せず、時刻の取得元だけを注入する設計)。
    private let now: () -> Date
    private let maxUnterminatedJobs: Int

    init(
        audioEngine: AudioCaptureEngineControlling,
        transcriptionEngine: TranscriptionEngine,
        textFormatter: TextFormatter? = nil,
        textInserter: TextInserting? = nil,
        now: @escaping () -> Date = Date.init,
        maxUnterminatedJobs: Int? = nil
    ) {
        self.audioEngine = audioEngine
        self.transcriptionEngine = transcriptionEngine
        self.textFormatter = textFormatter
        self.now = now
        self.maxUnterminatedJobs = maxUnterminatedJobs ?? Self.maxUnterminatedJobs
        self.deliveryCoordinator = DeliveryCoordinator(registry: jobRegistry, textInserter: textInserter ?? TextInserter())
        self.audioEngine.delegate = self
        self.deliveryCoordinator.onCommitted = { [weak self] sequence, result in
            guard let self else { return }
            self.recomputeState()
            self.onPendingJobCountChanged?(self.jobRegistry.activeCount)
            self.onJobCommitted?(sequence, result)
        }
        updateCancelShortcutEnabled()
    }

    /// 現在の`state`に基づいてキャンセルショートカットのenable/disableを再適用する。
    ///
    /// 呼び出しが必要な2箇所:
    /// 1. `HotkeyManager`の構築(=`KeyboardShortcuts.onKeyDown/onKeyUp`によるハンドラ登録)は、
    ///    対象のショートカットを無条件に再登録(有効化)してしまう。そのためCoordinator.init時点で
    ///    `updateCancelShortcutEnabled()`によりidle状態のEscをdisableしていても、その後の
    ///    `HotkeyManager`構築で再度enableされてしまう(起動時にEscが一瞬有効になる問題)。
    /// 2. 設定画面の`KeyboardShortcuts.Recorder`でキャンセルショートカットが再割当てされると、
    ///    ライブラリ側の`setShortcut`が無条件に`register`(有効化)してしまうため、idle時に
    ///    disableしていたはずのEscが再び有効になってしまう(`ShortcutsSettingsView`の
    ///    `Recorder`の`onChange`から呼ぶ)。
    func refreshShortcutEnablement() {
        updateCancelShortcutEnabled()
    }

    /// 挿入クリティカル区間(フォーカス確認〜Cmd+V送出)が現在進行中かどうか。
    /// `applicationWillTerminate`が終了を短時間遅らせてクリップボード復元を待つ判断に使う。
    var isInsertionCriticalSection: Bool {
        deliveryCoordinator.isInsertionCriticalSection
    }

    /// 未終端(コミット待ちも含む)ジョブ数。`applicationWillTerminate`のログ出力に使う。
    var activeJobCount: Int {
        jobRegistry.activeCount
    }

    // MARK: - State derivation

    /// `recordingState`と`jobRegistry`(未終端ジョブの有無)から表示用の`state`を再計算する。
    /// 録音中(または録音停止グレー中)は`.recording`/`.transcribing`いずれかを優先的に示し、
    /// 録音していなければ未終端ジョブの有無で`.transcribing`/`.idle`を決める。
    private func recomputeState() {
        switch recordingState {
        case .recording:
            state = .recording
        case .finalizing:
            // 既存の見た目を踏襲: 録音停止直後(AudioCaptureEngine内部のグレース中)は
            // 従来と同じく即座に「処理中」表示にする。
            state = .transcribing
        case .idle:
            state = jobRegistry.hasActiveJobs ? .transcribing : .idle
        }
    }

    // MARK: - Push to talk

    func beginPushToTalk() async {
        isPushToTalkKeyDown = true
        switch recordingState {
        case .recording:
            return
        case .finalizing:
            pendingStartRequest = .pushToTalk
        case .idle:
            await waitForInsertionCriticalSectionIfNeeded()
            guard recordingState == .idle else {
                if recordingState == .finalizing, isPushToTalkKeyDown { pendingStartRequest = .pushToTalk }
                return
            }
            // 待機中にkeyUpが既に来ていた場合、ここで開始してしまうとkeyUpを受け取れないまま
            // 録音し続けてしまう(Codexレビュー指摘#2)。開始自体を取りやめる。
            guard isPushToTalkKeyDown else { return }
            attemptStartRecording(source: .pushToTalk)
        }
    }

    func endPushToTalk() {
        isPushToTalkKeyDown = false
        if pendingStartRequest == .pushToTalk {
            // finalizing中(または挿入クリティカル区間待機中)に保留していたPTT開始要求だが、
            // 実際に開始する前にキーが離された。開始要求自体を取り消す
            // (取り消さずに後で開始してしまうと、対応するkeyUpが来ないまま録音し続けてしまう)。
            pendingStartRequest = nil
            return
        }
        guard recordingState == .recording, activationSource == .pushToTalk else { return }
        activationSource = nil
        recordingState = .finalizing
        audioEngine.stopRecording()
    }

    // MARK: - Toggle

    func toggleRecording() async {
        switch recordingState {
        case .idle:
            await waitForInsertionCriticalSectionIfNeeded()
            guard recordingState == .idle else {
                if recordingState == .finalizing { pendingStartRequest = .toggle }
                return
            }
            attemptStartRecording(source: .toggle)
        case .recording where activationSource == .toggle:
            activationSource = nil
            recordingState = .finalizing
            audioEngine.stopRecording()
        case .recording:
            // PTT中のトグル操作は無視
            break
        case .finalizing:
            pendingStartRequest = .toggle
        }
    }

    // MARK: - Cancel (Escの階層的キャンセル)

    /// 1. 録音中 → 現在の録音のみキャンセル
    /// 2. `finalizing`(録音停止済みグレー待ち) → いま確定処理中の録音自体をキャンセル
    ///    (`latestCancellableSequence`ではなく、まさに今finalizeされようとしているジョブそのものを
    ///    対象にする。以前は非録音時と同じ扱いで「最新の未終端ジョブ」を対象にしていたため、
    ///    既に別のジョブとして確定・キュー投入済みのジョブを誤ってキャンセルしてしまっていた)
    /// 3. 非録音時(idle) → まだ挿入されていない最新(sequence最大)のジョブ1件をキャンセル
    ///    (「最後に話した内容の取り消し」がユーザー意図に近いため)
    func cancelRecording() {
        switch recordingState {
        case .recording:
            if let sequence = currentRecordingSequence {
                jobRegistry.requestCancel(sequence)
            }
            activationSource = nil
            recordingState = .finalizing
            audioEngine.cancelRecording()
        case .finalizing:
            if let sequence = currentRecordingSequence {
                jobRegistry.requestCancel(sequence)
                log.info("Cancel requested for the recording currently being finalized (sequence \(sequence, privacy: .public))")
            }
        case .idle:
            if let sequence = jobRegistry.latestCancellableSequence {
                jobRegistry.requestCancel(sequence)
                log.info("Cancel requested for latest pending job (sequence \(sequence, privacy: .public))")
            }
        }
    }

    /// メニューバー「すべての処理をキャンセル」から呼ぶ。未終端の全ジョブにキャンセルを要求する
    /// (現在進行中の録音自体はキャンセルしない。あくまで発話済みで処理待ち/処理中のジョブが対象)。
    /// `sequence`は録音開始時に採番されるようになったため、現在録音中/finalizing中のジョブの
    /// sequenceは明示的に除外する。
    func cancelAllJobs() {
        jobRegistry.requestCancelAll(excluding: currentRecordingSequence)
        log.info("Cancel requested for all pending jobs")
    }

    // MARK: - Global shortcut enablement (Escの常時グローバル登録を避ける)

    /// 録音中/文字起こし中のみキャンセルショートカット(既定Esc)を有効化する。
    /// idle時は無効化(unregister)し、他アプリのEscを奪わないようにする。
    private func updateCancelShortcutEnabled() {
        switch state {
        case .idle:
            KeyboardShortcuts.disable(.cancelRecording)
        case .recording, .transcribing:
            KeyboardShortcuts.enable(.cancelRecording)
        }
    }

    // MARK: - Recording start (共通化)

    /// 新規録音の開始を試みる。キュー上限到達時は`onQueueFull`を通知して開始せず`false`を返す
    /// (呼び出し元は`recordingState`を適切な状態に戻すこと。特に`.finalizing`からの遷移では、
    /// 失敗時に`.idle`へ戻さないと`recordingState`が`.finalizing`のまま永久に残ってしまう
    /// —Codexレビュー指摘#1)。
    @discardableResult
    private func attemptStartRecording(source: ActivationSource) -> Bool {
        // モデル自動セットアップ(ダウンロード)中は新規録音を開始しない(誤ってスタブへ流れ
        // ダミーテキストが挿入されるのを防ぐため)。この関数は`beginPushToTalk()`/
        // `toggleRecording()`の`.idle`分岐と、`finalizeRecordingTransition()`による
        // `pendingStartRequest`の再生(finalizing明け後の自動開始)の**両方**が通る唯一の
        // 経路であるため、ここでチェックすることで「セットアップがawait中や.finalizing中に
        // 開始した」場合の迂回も防げる(録音の**停止**操作はこの関数を経由しないため、
        // セットアップ中であっても進行中の録音停止は妨げない)。
        guard !isModelSetupBlocking else {
            log.info("Model setup in progress; rejecting new recording")
            onRecordingRejectedDuringSetup?()
            return false
        }
        guard jobRegistry.canAcceptNewJob(limit: maxUnterminatedJobs) else {
            log.warning("Queue is full (limit=\(self.maxUnterminatedJobs, privacy: .public)); rejecting new recording")
            onQueueFull?()
            return false
        }
        activationSource = source
        recordingFrontmostApp = NSWorkspace.shared.frontmostApplication
        recordingStartedAt = now()
        pendingJobSettingsSnapshot = .captureCurrent()
        currentRecordingSequence = jobRegistry.beginJob()
        recordingState = .recording
        onPendingJobCountChanged?(jobRegistry.activeCount)
        audioEngine.startRecording()
        return true
    }

    /// 録音停止グレー明け(`didFinishRecording`)・キャンセル確定(`didCancelRecording`)の
    /// どちらからも呼ぶ。保留中の開始要求があれば直ちに新しい録音を開始し、無ければidleへ戻る。
    /// 保留していた開始要求がキュー上限で拒否された場合も、必ず`.idle`へ戻す
    /// (Codexレビュー指摘#1の回帰: 以前は拒否時に何もせず`.finalizing`のまま残ってしまっていた)。
    private func finalizeRecordingTransition() {
        if let pending = pendingStartRequest {
            pendingStartRequest = nil
            if attemptStartRecording(source: pending) {
                return
            }
        }
        recordingState = .idle
    }

    /// 挿入クリティカル区間(`DeliveryCoordinator`がフォーカス確認〜Cmd+V送出を行っている間)は、
    /// 新規録音の開始要求を待つ。以前は最大100ms(20ms×5回)のポーリングで打ち切り、その後は
    /// クリティカル区間の状態を再確認せずに録音を開始してしまっていたため、「挿入中に録音を
    /// 開始しない」という不変条件が理論上破られうった(Codexレビュー指摘#3)。
    /// `DeliveryCoordinator`がクリティカル区間終了時に呼ぶコールバック(`onInsertionCriticalSectionEnded`)
    /// を使い、区間が実際に終わるまで無条件に待つ(既にクリティカル区間でなければ即座に返る)。
    ///
    /// **ループでの再確認が必須**: このコールバックによる目覚め(`continuation.resume()`)から
    /// このタスクが実際に再開されるまでの間に、`DeliveryCoordinator`が次に控えているジョブの
    /// コミットへ進み、新たな挿入クリティカル区間を開始してしまうことがありうる(`commit()`が
    /// 前ジョブの`insert()`から復帰した直後、他の`await`を挟まず同期的に次のジョブの`commit()`へ
    /// 進むため)。1回の待機だけで抜けてしまうと、この新しい区間と競合して録音を開始しかねない。
    /// そのため目覚めるたびに`isInsertionCriticalSection`を再確認し、まだ(または再び)trueの
    /// 間はループして待ち続ける(Codex検証レビューでの追加指摘)。
    private func waitForInsertionCriticalSectionIfNeeded() async {
        while deliveryCoordinator.isInsertionCriticalSection {
            await withCheckedContinuation { continuation in
                deliveryCoordinator.onInsertionCriticalSectionEnded {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - AudioCaptureEngineDelegate

    nonisolated func audioCaptureEngine(_ engine: AudioCaptureEngineControlling, didFinishRecording samples: [Float], sampleRate: Double) {
        Task { @MainActor in
            // 録音長上限などによりAudioCaptureEngine側が自発的に停止した場合、
            // まだ.finalizingへ遷移していないことがあるためここで揃える。
            if recordingState == .recording {
                activationSource = nil
                recordingState = .finalizing
            }

            let frontmostAppAtRecordingStart = recordingFrontmostApp
            let effectiveDuration = recordingStartedAt.map { now().timeIntervalSince($0) } ?? .infinity
            let settingsSnapshot = pendingJobSettingsSnapshot ?? .captureCurrent()
            // 仕様通り、sequenceは録音開始時(attemptStartRecording)に既に採番済み。
            // 万一nilの場合(理論上到達しないはずだが、安全側のフォールバック)はここで採番する。
            let sequence = currentRecordingSequence ?? {
                log.error("currentRecordingSequence was nil at didFinishRecording; assigning a new sequence as a fallback")
                return jobRegistry.beginJob()
            }()
            recordingFrontmostApp = nil
            recordingStartedAt = nil
            pendingJobSettingsSnapshot = nil
            currentRecordingSequence = nil

            let job = DictationJob(
                sequence: sequence,
                samples: samples,
                sampleRate: sampleRate,
                effectiveRecordingDuration: effectiveDuration,
                frontmostAppAtRecordingStart: frontmostAppAtRecordingStart,
                settings: settingsSnapshot
            )

            // 保留中の開始要求があれば直ちに次の録音を始める(このジョブの処理とは完全に独立)。
            finalizeRecordingTransition()

            enqueueProcessing(for: job)
        }
    }

    nonisolated func audioCaptureEngineDidCancelRecording(_ engine: AudioCaptureEngineControlling) {
        Task { @MainActor in
            let frontmostAppAtRecordingStart = recordingFrontmostApp
            let sequence = currentRecordingSequence
            recordingFrontmostApp = nil
            recordingStartedAt = nil
            pendingJobSettingsSnapshot = nil
            currentRecordingSequence = nil
            finalizeRecordingTransition()
            // sequenceは録音開始時に既に採番済み(未終端としてカウントされている)ため、
            // 実際に音声が得られなかったこのケースでも必ずtombstone化して終端させる
            // (そうしないとキュー上限の枠を永久に占有してしまう)。
            if let sequence {
                deliveryCoordinator.complete(sequence: sequence, outcome: .tombstone(.cancelled), frontmostAppAtRecordingStart: frontmostAppAtRecordingStart)
            }
        }
    }

    nonisolated func audioCaptureEngine(_ engine: AudioCaptureEngineControlling, didEncounterFatalError message: String) {
        Task { @MainActor in
            log.error("Audio engine fatal error: \(message, privacy: .public)")
            if recordingState != .idle {
                let sequence = currentRecordingSequence
                let frontmostAppAtRecordingStart = recordingFrontmostApp
                activationSource = nil
                recordingFrontmostApp = nil
                recordingStartedAt = nil
                pendingJobSettingsSnapshot = nil
                pendingStartRequest = nil
                currentRecordingSequence = nil
                recordingState = .idle
                // sequence採番を録音開始時に前倒ししたため、致命的エラー時も同様に
                // 必ず終端させてキュー上限の枠を解放する。
                if let sequence {
                    deliveryCoordinator.complete(sequence: sequence, outcome: .tombstone(.failed), frontmostAppAtRecordingStart: frontmostAppAtRecordingStart)
                }
            }
            onFatalAudioError?(message)
        }
    }

    // MARK: - Job processing (whisper.cpp認識 → LLM整形、SerialFIFOQueueで直列化)

    /// ジョブを推論用FIFOへ積む。呼び出し順(=sequence順)がそのままキューの実行順になるため、
    /// このメソッドはジョブ生成の直後、他のawaitを挟まずMainActor上で同期的に呼ぶこと。
    private func enqueueProcessing(for job: DictationJob) {
        inferenceQueue.enqueue { [weak self] in
            await self?.runJob(job)
        }
    }

    /// 起動時のOllamaプリロード等、推論FIFO(認識・整形の直列化キュー)経由で実行したい処理を追加する。
    /// 初回のwhisper.cpp呼び出しと同時にGPU/Unified Memoryを奪い合わないようにするための配線用
    /// (Codexレビュー指摘#12)。
    func enqueueBackgroundInferenceTask(_ operation: @escaping @Sendable () async -> Void) {
        inferenceQueue.enqueue(operation)
    }

    /// 1ジョブ分の「認識→整形」を実行し、結果を`DeliveryCoordinator`へ渡す。
    /// 各ステージの実行前にキャンセルフラグを確認し、キャンセル済みなら残りのステージを
    /// スキップして墓標化する(whisper_full自体の中断はしない。整形(Ollama)は実行中のTaskを
    /// キャンセルハンドルとして`DictationJobRegistry`に登録し、キャンセル時に`Task.cancel()`を
    /// 呼んで実際にURLSessionのリクエストを中断させ、FIFOの先頭を即座に解放する
    /// —Codexレビュー指摘#6)。
    private func runJob(_ job: DictationJob) async {
        func complete(_ outcome: DictationJobOutcome) {
            deliveryCoordinator.complete(sequence: job.sequence, outcome: outcome, frontmostAppAtRecordingStart: job.frontmostAppAtRecordingStart)
        }

        guard !jobRegistry.isCancelled(job.sequence) else {
            complete(.tombstone(.cancelled))
            return
        }

        // ハルシネーション対策(多層防御)の第1層: 録音実効長が閾値未満ならwhisper_full自体を呼ばない。
        guard job.effectiveRecordingDuration >= Self.minimumEffectiveRecordingDuration else {
            log.info("Recording effective duration (\(job.effectiveRecordingDuration, privacy: .public)s) below minimum; skipping transcription (sequence \(job.sequence, privacy: .public))")
            complete(.tombstone(.skipped(.tooShort)))
            return
        }

        // ハルシネーション対策(多層防御)の第2層: 先頭無音トリム後のエネルギーゲート。
        let trimmedForEnergyCheck = AudioPreprocessing.trimLeadingSilence(samples: job.samples, sampleRate: job.sampleRate)
        guard AudioPreprocessing.hasSufficientEnergy(samples: trimmedForEnergyCheck, sampleRate: job.sampleRate) else {
            log.info("No sufficient speech energy detected; skipping transcription (sequence \(job.sequence, privacy: .public))")
            complete(.tombstone(.skipped(.silence)))
            return
        }

        onPhaseChanged?(.recognizing)
        do {
            let transcribedText = try await transcriptionEngine.transcribe(
                samples: job.samples,
                sampleRate: job.sampleRate,
                language: job.settings.sttLanguage,
                vocabularyHint: job.settings.vocabularyHint,
                vadEnabled: job.settings.vadEnabled
            )
            log.info("Transcription result (sequence \(job.sequence, privacy: .public)): \(transcribedText, privacy: .private)")

            guard !jobRegistry.isCancelled(job.sequence) else {
                complete(.tombstone(.cancelled))
                return
            }

            // ハルシネーション対策(多層防御)の第5層(最終防衛線): 既知の定型句のみの出力を棄却する。
            var rawText = transcribedText
            if !rawText.isEmpty, HallucinationFilter.isLikelyHallucination(rawText) {
                log.info("Discarding output that matches a known hallucination phrase (sequence \(job.sequence, privacy: .public))")
                rawText = ""
            }
            guard !rawText.isEmpty else {
                complete(.tombstone(.skipped(.silence)))
                return
            }

            let willFormat = job.settings.formattingEnabled && textFormatter != nil
            if willFormat {
                onPhaseChanged?(.formatting)
            }

            var finalText = rawText
            var usedFormattingFallback = false
            if willFormat, let textFormatter {
                let formatTask = Task {
                    try await textFormatter.format(
                        text: rawText,
                        vocabularyHint: job.settings.vocabularyHint,
                        model: job.settings.formattingModel,
                        timeoutSeconds: job.settings.formattingTimeoutSeconds
                    )
                }
                jobRegistry.setCancellationHandle(job.sequence) { formatTask.cancel() }
                defer { jobRegistry.clearCancellationHandle(job.sequence) }
                do {
                    finalText = try await formatTask.value
                    // 整形が成功した=Ollamaへ到達できた。起動時にOllama未検出と判定していても
                    // (`onFormattingUnavailable`)、後から起動されて次の整形が成功すればここで
                    // 「利用可能」の状態へ戻す。未検出表示中でなければ呼び出し先で無視してよい。
                    onFormattingRecovered?()
                } catch {
                    if jobRegistry.isCancelled(job.sequence) {
                        complete(.tombstone(.cancelled))
                        return
                    }
                    log.warning("Text formatting failed; falling back to raw transcription (sequence \(job.sequence, privacy: .public)): \(String(describing: error), privacy: .public)")
                    if let formatterError = error as? TextFormatterError, case .serverUnavailable = formatterError {
                        // Ollama未導入/未起動は例外的な障害ではなく通常運用でありうる状態のため、
                        // 発話のたびに5秒間フェードする警告バナー(`onFormattingFailed`)は出さず、
                        // メニューバーの常設状態表示のみ更新する。
                        onFormattingUnavailable?()
                    } else {
                        onFormattingFailed?("LLM整形に失敗したため、未整形のテキストを使用しました: \(error)")
                    }
                    finalText = rawText
                    usedFormattingFallback = true
                }
            }

            guard !jobRegistry.isCancelled(job.sequence) else {
                complete(.tombstone(.cancelled))
                return
            }

            complete(.insertText(finalText, usedFormattingFallback: usedFormattingFallback))
        } catch {
            log.error("Transcription failed (sequence \(job.sequence, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            complete(.tombstone(.failed))
        }
    }
}
