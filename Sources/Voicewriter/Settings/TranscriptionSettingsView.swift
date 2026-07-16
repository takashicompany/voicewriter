import SwiftUI

/// 音声認識タブ: エンジン選択・言語選択・モデルファイルの状態表示とダウンロード。
struct TranscriptionSettingsView: View {
    @ObservedObject var transcriptionEngine: DynamicTranscriptionEngine
    @StateObject private var downloader = ModelDownloader()

    @AppStorage(SettingsKey.sttEngine) private var sttEngine: SttEngineKind = .whisperCpp
    @AppStorage(SettingsKey.sttLanguage) private var sttLanguage: String = "ja"
    @AppStorage(SettingsKey.sttVocabularyHint) private var sttVocabularyHint: String = Settings.defaultVocabularyHint
    @AppStorage(SettingsKey.vadEnabled) private var vadEnabled: Bool = true

    @State private var modelIsAvailable = WhisperCppEngine.isModelAvailable()
    @State private var vadModelIsAvailable = WhisperCppEngine.isVadModelAvailable()

    var body: some View {
        Form {
            Section {
                Picker("エンジン", selection: $sttEngine) {
                    Text("whisper.cpp").tag(SttEngineKind.whisperCpp)
                    Text("スタブ(ダミーテキスト)").tag(SttEngineKind.stub)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: sttEngine) { _, _ in
                    transcriptionEngine.reload()
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
                TextField("例: Voicewriter, ChatGPT", text: $sttVocabularyHint)
                    .textFieldStyle(.roundedBorder)
                Text("変更は次回の文字起こしから反映されます(再ロード不要)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("whisper.cppモデル (ggml-large-v3-turbo)") {
                modelStatusView
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
        .onChange(of: downloader.state) { _, newState in
            if case .success = newState {
                modelIsAvailable = WhisperCppEngine.isModelAvailable()
                if sttEngine == .whisperCpp {
                    transcriptionEngine.reload()
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
                    .textSelection(.enabled)
                if let size = modelFileSizeBytes {
                    Text("サイズ: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("モデルが未配置です。下のボタンでダウンロードするか、ターミナルで `scripts/download-model.sh` を実行して手動配置してください。")
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

    private var modelFileSizeBytes: Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: WhisperCppEngine.defaultModelURL.path) else {
            return nil
        }
        return attrs[.size] as? Int64
    }
}
