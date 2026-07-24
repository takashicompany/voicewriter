import SwiftUI

/// 音声認識タブ: エンジン選択・言語選択・モデルファイルの状態表示とダウンロード。
struct TranscriptionSettingsView: View {
    @ObservedObject var transcriptionEngine: DynamicTranscriptionEngine
    /// `AppDelegate`が所有する単一インスタンスを注入する(起動時の自動ダウンロードと
    /// この画面の手動ダウンロードボタンが同一インスタンスを共有することで、二重起動を防ぐ。
    /// `ModelDownloader.canStartDownload(from:)`が状態機械レベルでも二重起動を防ぐ)。
    @ObservedObject var downloader: ModelDownloader

    @AppStorage(SettingsKey.sttEngine) private var sttEngine: SttEngineKind = .whisperCpp
    @AppStorage(SettingsKey.sttLanguage) private var sttLanguage: String = "ja"
    @AppStorage(SettingsKey.sttVocabularyHint) private var sttVocabularyHint: String = Settings.defaultVocabularyHint
    @AppStorage(SettingsKey.vadEnabled) private var vadEnabled: Bool = true
    @AppStorage(SettingsKey.streamingPreviewEnabled) private var streamingPreviewEnabled: Bool = true

    @State private var modelIsAvailable = WhisperCppEngine.isModelAvailable()
    @State private var vadModelIsAvailable = WhisperCppEngine.isVadModelAvailable()

    /// SpeechAnalyzerストリーミングモードがこの環境で選択可能かどうか。実行時に
    /// `SpeechTranscriber.supportedLocales`等を照会して判定する(固定表ではない)。
    @State private var streamingAvailability: StreamingTranscriptionAvailabilityStatus = .checking
    @StateObject private var speechModelProvisioner = SpeechModelProvisioner()

    var body: some View {
        // Formだけだとタブ内コンテンツがウィンドウ高さを超えた際に上下端で見切れてしまう
        // (VAD/SpeechAnalyzerセクション追加で縦に長くなったことで顕在化)。ScrollViewで包み、
        // 収まりきらない場合でもスクロールで全項目にアクセスできるようにする。
        ScrollView {
        Form {
            Section {
                Picker("エンジン", selection: $sttEngine) {
                    Text("whisper.cpp").tag(SttEngineKind.whisperCpp)
                    Text("スタブ(ダミーテキスト)").tag(SttEngineKind.stub)
                    Text("Apple SpeechAnalyzer(ストリーミング)").tag(SttEngineKind.speechAnalyzer)
                        .disabled(!streamingAvailability.isSupported)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: sttEngine) { _, _ in
                    transcriptionEngine.reload()
                }

                if let reason = streamingAvailability.reason {
                    Label(reason, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } else if sttEngine == .speechAnalyzer {
                    Text("SpeechAnalyzerモードでは、確定した認識結果を直接使います(whisper.cppは使用しません)。この後段のLLM整形→辞書置換→挿入は通常モードと同じです。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("言語", selection: $sttLanguage) {
                    Text("日本語 (ja)").tag("ja")
                    Text("自動判定 (auto)").tag("auto")
                }
                .pickerStyle(.radioGroup)
                .onChange(of: sttLanguage) { _, _ in
                    transcriptionEngine.reload()
                }

                Text("エンジン/言語の変更は次回の文字起こしから反映されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if transcriptionEngine.activeEngineIsFallback {
                    Label("現在はモデル未配置/ロード失敗のため、スタブにフォールバックして動作しています", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            Section("認識のヒント") {
                Text("固有名詞やアプリ名など、認識してほしい語をカンマ区切りで入力してください。強制ではありませんが、認識精度向上の手がかりとして使われます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 注意: TextField(_:text:)の第1引数はプレースホルダだが、Form内では
                // それが暗黙のラベル列としても描画されてしまい、値と紛らわしい上に
                // ウィンドウ幅が狭いとラベル側が左端で欠けて見える不具合があった。
                // ラベルを持たない`prompt:`ベースの初期化子 + `.labelsHidden()`で
                // プレースホルダ専用にする。
                TextField(text: $sttVocabularyHint, prompt: Text("例: Voicewriter, ChatGPT")) {
                    Text("語彙ヒント")
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                Text("変更は次回の文字起こしから反映されます(再ロード不要)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("whisper.cppモデル (ggml-large-v3-turbo)") {
                modelStatusView
            }

            Section("SpeechAnalyzer(ストリーミング)モデル資産") {
                speechModelStatusView
                Toggle("録音中にライブプレビューを表示する", isOn: $streamingPreviewEnabled)
                Text("SpeechAnalyzerモード選択時、録音中に確定/未確定のテキストを別のフローティングパネルに表示します。未確定部分は挿入先アプリへは流し込まれません。OFFにするとプレビュー用の認識処理自体を行わなくなり、CPU/メモリ負荷が下がります(挿入される確定テキストの精度・内容には影響しません)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("VAD (Voice Activity Detection)") {
                Toggle("VADを有効にする", isOn: $vadEnabled)
                Text("無音/非音声区間を検出し、発話区間だけをデコードすることでハルシネーション(無音時に定型句が出力される現象)を減らします。既定はONです(無音・誤押下対策の一環)。VADモデルが未配置の場合は自動的に無効として動作します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if vadModelIsAvailable {
                    Label("VADモデル配置済み", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                } else {
                    Label("VADモデル未配置(ターミナルで `scripts/download-vad-model.sh` を実行してください)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
        .onAppear {
            modelIsAvailable = WhisperCppEngine.isModelAvailable()
            vadModelIsAvailable = WhisperCppEngine.isVadModelAvailable()
        }
        .task {
            streamingAvailability = await StreamingTranscriptionAvailability.currentStatus()
            await speechModelProvisioner.refreshStatus()
        }
        .onChange(of: downloader.state) { _, newState in
            if case .success = newState {
                // エンジンのreload()自体は`AppDelegate`(`modelDownloader.$state`の一元的な購読元)が
                // 行う。ここでも呼ぶと二重ロードになる(自動トリガー・手動トリガーいずれの場合も
                // AppDelegate側が単一の経路として反映するため、ここではUI表示の更新のみ行う)。
                modelIsAvailable = WhisperCppEngine.isModelAvailable()
            }
        }
        }
    }

    @ViewBuilder
    private var modelStatusView: some View {
        if modelIsAvailable {
            VStack(alignment: .leading, spacing: 4) {
                Label("配置済み", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(WhisperCppEngine.defaultModelURL.path)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(WhisperCppEngine.defaultModelURL.path)
                    .textSelection(.enabled)
                if let size = modelFileSizeBytes {
                    Text("サイズ: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("モデルが未配置です。通常は初回起動時に自動的にダウンロードが始まります。進捗が表示されない、または失敗した場合は下のボタンで再試行するか、ターミナルで `scripts/download-model.sh` を実行して手動配置してください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                downloadControlView
            }
        }
    }

    @ViewBuilder
    private var downloadControlView: some View {
        switch downloader.state {
        case .idle:
            Button("モデルをダウンロード(約1.6GB)") {
                downloader.startDownload()
            }

        case .downloading(let progress, let received, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("キャンセル") {
                    downloader.cancel()
                }
            }

        case .success:
            Label("ダウンロード完了", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .failure(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("再試行") {
                    downloader.startDownload()
                }
            }
        }
    }

    @ViewBuilder
    private var speechModelStatusView: some View {
        switch speechModelProvisioner.state {
        case .checking:
            Label("確認中…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
                .font(.footnote)
        case .unsupported(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        case .installed:
            Label("日本語モデル資産は利用可能です", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                Text("日本語モデル資産が未取得です。SpeechAnalyzerモードを初めて使う際に自動的にダウンロードが始まりますが、ここから事前に取得しておくこともできます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("モデル資産をダウンロード") {
                    speechModelProvisioner.startDownload()
                }
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failure(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("再試行") {
                    speechModelProvisioner.startDownload()
                }
            }
        }
    }

    private var modelFileSizeBytes: Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: WhisperCppEngine.defaultModelURL.path) else {
            return nil
        }
        return attrs[.size] as? Int64
    }
}
