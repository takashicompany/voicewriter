import Foundation

/// マイクの動作モード
enum MicMode: String, CaseIterable {
    /// 起動時からAVAudioEngineを起動しっぱなしにし、リングバッファで直近音声を保持する
    case alwaysOn
    /// 録音開始命令が来てからエンジンを起動する
    case onDemand
}

/// 文字起こしエンジンの種別
enum SttEngineKind: String, CaseIterable {
    /// whisper.cpp (ggml-large-v3-turbo)
    case whisperCpp
    /// ダミーテキストを返すスタブ
    case stub
}

/// UserDefaultsを介した設定値。すべてデフォルト値を持ち、未設定でも安全に動作する。
enum SettingsKey {
    static let micMode = "micMode"
    static let ringBufferSeconds = "ringBufferSeconds"
    static let prerollSeconds = "prerollSeconds"
    static let onDemandIdleTimeoutSeconds = "onDemandIdleTimeoutSeconds"
    static let sttEngine = "sttEngine"
    static let sttLanguage = "sttLanguage"
    static let sttVocabularyHint = "sttVocabularyHint"
    /// [隠し設定] UIには出さない。`defaults write dev.voicewriter.app debugSaveLastRecording -bool YES` で有効化する。
    static let debugSaveLastRecording = "debugSaveLastRecording"
    static let vadEnabled = "vadEnabled"
    static let formattingEnabled = "formattingEnabled"
    static let formattingModel = "formattingModel"
    static let formattingTimeoutSeconds = "formattingTimeoutSeconds"
    static let hudEnabled = "hudEnabled"
    static let soundEffectsEnabled = "soundEffectsEnabled"
}

enum Settings {
    static var micMode: MicMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: SettingsKey.micMode),
               let mode = MicMode(rawValue: raw) {
                return mode
            }
            return .alwaysOn
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.micMode)
        }
    }

    /// リングバッファに保持する秒数(AlwaysOnモード)。デフォルト3秒。
    static var ringBufferSeconds: Double {
        get {
            let value = UserDefaults.standard.double(forKey: SettingsKey.ringBufferSeconds)
            return value > 0 ? value : 3.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.ringBufferSeconds)
        }
    }

    /// 録音開始時に遡って含めるプリロール秒数。デフォルト0.5秒。
    static var prerollSeconds: Double {
        get {
            if UserDefaults.standard.object(forKey: SettingsKey.prerollSeconds) == nil {
                return 0.5
            }
            return UserDefaults.standard.double(forKey: SettingsKey.prerollSeconds)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.prerollSeconds)
        }
    }

    /// OnDemandモードで録音停止後、エンジンを止めるまでのアイドル秒数。デフォルト30秒。
    static var onDemandIdleTimeoutSeconds: Double {
        get {
            let value = UserDefaults.standard.double(forKey: SettingsKey.onDemandIdleTimeoutSeconds)
            return value > 0 ? value : 30.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.onDemandIdleTimeoutSeconds)
        }
    }

    /// 文字起こしエンジン。デフォルトはwhisperCpp(モデル未配置なら起動時にstubへフォールバック)。
    static var sttEngine: SttEngineKind {
        get {
            if let raw = UserDefaults.standard.string(forKey: SettingsKey.sttEngine),
               let kind = SttEngineKind(rawValue: raw) {
                return kind
            }
            return .whisperCpp
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: SettingsKey.sttEngine)
        }
    }

    /// whisper.cppの言語設定。デフォルト"ja"。"auto"で自動判定。
    static var sttLanguage: String {
        get {
            UserDefaults.standard.string(forKey: SettingsKey.sttLanguage) ?? "ja"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.sttLanguage)
        }
    }

    /// whisper.cppの`initial_prompt`に渡す語彙ヒント(固有名詞・専門用語など、カンマ区切り推奨)。
    /// デコーダの文脈として働き、強制はしないが「Voicewriter→ボイスライダー」のような
    /// 固有名詞の誤認識を減らす手がかりになる(Amicalの語彙ヒント機能を参考)。
    /// 空文字を明示的に設定した場合はヒントなし(initial_promptを渡さない)として扱う。
    /// エンジンの再ロードなしで次回の文字起こしから反映される(`WhisperCppEngine`が呼び出しごとに読む)。
    static var sttVocabularyHint: String {
        get {
            UserDefaults.standard.string(forKey: SettingsKey.sttVocabularyHint) ?? defaultVocabularyHint
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.sttVocabularyHint)
        }
    }

    static let defaultVocabularyHint = "Voicewriter"

    /// [隠し設定] 直近1回分の文字起こし対象音声(先頭無音トリム後、`whisper_full`に渡す直前の
    /// 16kHz/mono/Float32サンプル)をWAVとして保存するデバッグ機能。既定OFF。
    /// UI上の切り替えは設けていない。有効化するには例えばターミナルで
    /// `defaults write dev.voicewriter.app debugSaveLastRecording -bool YES` を実行する
    /// (アプリのbundle identifierは`Resources/Info.plist`参照)。
    /// `whisper_full`への実際の入力を保存するため、公式`whisper-cli`にそのまま渡して同一入力での
    /// 比較検証ができるほか、マイク入力パイプラインの音質(ゲイン・クリッピング・ノイズ)の
    /// 事後検証にも使える。
    static var debugSaveLastRecordingEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.debugSaveLastRecording)
    }

    /// デバッグ録音の保存先。直近1件のみを保持し、録音のたびに上書きする。
    static var debugRecordingURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Voicewriter/Debug/last-recording.wav", isDirectory: false)
    }

    /// VAD(Voice Activity Detection)を有効にするか。既定ON(無音・誤押下時のハルシネーション対策の
    /// 一環として、多層防御の第3層に位置づけている)。whisper.cpp v1.9.1で`whisper_full_params`自体に
    /// 統合されたSilero-VADベースの機能で、発話区間が検出できなければ空文字を返す(=ハルシネーション
    /// も含め一切出力しない)。有効化していてもVADモデル(`scripts/download-vad-model.sh`で配置)が
    /// 無ければ`WhisperCppEngine`が警告ログを出してVAD無しで動作する(=この層は事実上スキップされる、
    /// 安全側のフォールバック)ため、モデル未配置環境でも既定ONにして問題ない。
    static var vadEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: SettingsKey.vadEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: SettingsKey.vadEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.vadEnabled) }
    }

    /// 音声認識結果に対するLLM整形(誤字修正・句読点補完・フィラー除去)を行うかどうか。既定ON。
    /// Ollama未起動・整形失敗・タイムアウト時は`Coordinator`が必ずwhisper.cppの生出力へ
    /// フォールバックするため、OFFにしなくても安全に運用できる想定(不要ならOFFにもできる)。
    static var formattingEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: SettingsKey.formattingEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: SettingsKey.formattingEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.formattingEnabled)
        }
    }

    /// LLM整形(`OllamaFormatter`)に使うOllamaモデル名。
    ///
    /// 既定は`qwen3:14b`(Thinkingは`OllamaFormatter`が`think:false`で常に無効化して呼び出す)。
    /// `scripts/benchmark-formatter.py`による実測ベンチマーク(qwen2.5:7b/llama3.1:8b/qwen3:14bの
    /// 3モデル×8テストケース)では、Ollamaの構造化出力(`format`にJSON Schemaを指定)を使うことで
    /// 3モデルとも`<formatted_text>`タグ方式より格段に安定した(JSON解析失敗・空応答・ガードレール
    /// 違反が消えた)。その上でなお、qwen3:14bは他の2モデルで見られた問題
    /// (qwen2.5:7bは誤認識部分を「懸念がある」のように言い換えてニュアンスを変えてしまう、
    /// llama3.1:8bは整形の過程で意味のある一節を丸ごと落としてしまう、といった内容忠実性の逸脱)が
    /// 最も少なく、原文への忠実さを優先してデフォルトに選定した。ウォーム状態でのレイテンシは
    /// 短文で1秒未満・長文でも約2.6秒(既定タイムアウト10秒以内)。ただしコールドスタート
    /// (Ollama起動直後で当該モデル未ロード時)は約11秒かかり既定タイムアウトを超えうるため、
    /// `OllamaFormatter.preload()`をアプリ起動時に呼んでモデルを事前ロードしている。
    /// 速度を優先したい場合はqwen2.5:7b(コールド約3秒・ウォーム1秒未満)への切り替えも選べる
    /// (設定画面の「整形」タブ)。詳細・生の実測ログはREADME参照。
    static var formattingModel: String {
        get {
            UserDefaults.standard.string(forKey: SettingsKey.formattingModel) ?? defaultFormattingModel
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.formattingModel)
        }
    }

    static let defaultFormattingModel = "qwen3:14b"

    /// LLM整形リクエストのタイムアウト秒数。既定10秒。超過時は`Coordinator`が原文へフォールバックする。
    static var formattingTimeoutSeconds: Double {
        get {
            let value = UserDefaults.standard.double(forKey: SettingsKey.formattingTimeoutSeconds)
            return value > 0 ? value : 10.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.formattingTimeoutSeconds)
        }
    }

    /// 画面下部中央に浮遊表示する状態表示HUD(録音中/認識・整形中/挿入完了 等)を出すかどうか。既定ON。
    static var hudEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: SettingsKey.hudEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: SettingsKey.hudEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.hudEnabled)
        }
    }

    /// 録音開始時・挿入完了時の控えめな効果音を鳴らすかどうか。既定ON。
    static var soundEffectsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: SettingsKey.soundEffectsEnabled) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: SettingsKey.soundEffectsEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.soundEffectsEnabled)
        }
    }
}
