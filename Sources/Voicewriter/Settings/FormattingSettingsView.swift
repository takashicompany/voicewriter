import SwiftUI

/// 整形タブ: LLM整形のON/OFF・モデル選択(Ollama `/api/tags`から動的取得)・タイムアウト設定。
struct FormattingSettingsView: View {
    @StateObject private var modelLister = OllamaModelLister()

    @AppStorage(SettingsKey.formattingEnabled) private var formattingEnabled: Bool = true
    @AppStorage(SettingsKey.formattingModel) private var formattingModel: String = Settings.defaultFormattingModel
    @AppStorage(SettingsKey.formattingTimeoutSeconds) private var formattingTimeoutSeconds: Double = 10.0

    var body: some View {
        Form {
            Section {
                Toggle("音声認識後にLLMで整形する", isOn: $formattingEnabled)
                Text("誤字修正・句読点補完・フィラー(「えー」「あの」等)除去のみを行い、内容の言い換え・要約・翻訳はしません。Ollama(ローカル)が未起動、またはタイムアウト・整形失敗時は自動的に未整形のテキストへフォールバックします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("モデル (Ollama)") {
                modelPickerView

                HStack {
                    Text("タイムアウト: \(Int(formattingTimeoutSeconds))秒")
                    Stepper("", value: $formattingTimeoutSeconds, in: 3...30, step: 1)
                        .labelsHidden()
                }
                Text("タイムアウトを超えた場合は未整形のテキストへフォールバックします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("既定は qwen3:14b(Thinking無効)です。実測ベンチマークでqwen2.5:7b/llama3.1:8bにも試したところ、原文の一節を丸ごと落とす・ニュアンスを変えて言い換えるといった内容忠実性の逸脱が見られたため、レイテンシがやや高い点を許容してqwen3:14bをデフォルトに選びました。速度を優先したい場合はqwen2.5:7bへの切り替えも選べます。詳細はREADME参照。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Ollamaが未導入の場合") {
                Text("LLM整形にはOllama(ローカルで動くLLM実行環境)が必要です。未インストール、または起動していない間はこの機能を自動的に無効(未整形のまま挿入)として動作します。整形を使いたい場合は、以下からOllamaをインストールし、起動した上でモデル(既定は qwen3:14b、例: ターミナルで `ollama pull qwen3:14b`)を取得してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("https://ollama.com/download")
                    .font(.footnote)
                    .textSelection(.enabled)
                Text("Ollamaを後から起動した場合、次回の音声入力から自動的に整形が有効になります(再起動不要)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .onAppear {
            modelLister.refresh()
        }
    }

    @ViewBuilder
    private var modelPickerView: some View {
        switch modelLister.state {
        case .idle, .loading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("モデル一覧を取得中...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .success(let models):
            if models.isEmpty {
                Text("Ollamaにモデルが見つかりません。`ollama pull qwen3:14b` 等でモデルを取得してください。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("モデル", selection: $formattingModel) {
                    ForEach(models, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    // 現在の設定値が一覧に無い場合(例: 手入力した値、Ollama側で削除された等)でも、
                    // 設定自体を失わないよう選択肢として保持しておく。
                    if !models.contains(formattingModel) {
                        Text(formattingModel).tag(formattingModel)
                    }
                }
                Button("一覧を更新") {
                    modelLister.refresh()
                }
                .font(.footnote)
            }

        case .failure(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("モデル名(例: qwen3:14b)", text: $formattingModel)
                    .textFieldStyle(.roundedBorder)
                Button("再取得") {
                    modelLister.refresh()
                }
                .font(.footnote)
            }
        }
    }
}
