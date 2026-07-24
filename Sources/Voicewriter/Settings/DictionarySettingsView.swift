import AppKit
import SwiftUI

/// 辞書タブ: ユーザー定義の「置換元→置換先」ルール一覧の編集。
///
/// 音声認識・LLM整形の結果テキストに対し、挿入直前に上から順に適用される独立レイヤー
/// (Amicalの同種機能を参考。詳細は`Sources/Voicewriter/Dictionary/`とREADME参照)。
/// 編集は`UserDictionaryStore.shared`を経由して即座に`dictionary.json`へ保存される。
///
/// 行一覧は`List`ではなく`ScrollView` + `LazyVStack`の自前実装にしている。macOSのSwiftUIでは
/// `List`内の`TextField`はクリックしても即座にフォーカスが入らないことがある既知の挙動で
/// (Apple Developer Forums「SwiftUI on macOS, TextField inside List is completely
/// non-functional」https://developer.apple.com/forums/thread/676515 、
/// `List`の行は「クリックしてリネーム」的な単クリック+待機のジェスチャで実装されているためと
/// 説明されている)、さらに`onMove`(ドラッグ並べ替え)を付けると各行にドラッグジェスチャ認識が
/// 追加され、クリックがそちらに奪われてフォーカスがさらに入りにくくなる
/// (https://nilcoalescing.com/blog/ListReorderingWhileStillBeingAbleToEditTheListItems/ )。
/// 本アプリの不具合(置換元・置換先のテキスト欄をクリックしてもフォーカスが入らないことが多い)は
/// まさにこの`List` + `onMove`の組み合わせが原因だったため、`List`自体をやめ、並べ替えは行ごとの
/// 上下移動ボタンで代替する。
struct DictionarySettingsView: View {
    @ObservedObject private var store = UserDictionaryStore.shared

    var body: some View {
        // ウィンドウ高さより内容(説明文+ルール一覧+フッタ)が長くなった場合でも見切れないよう、
        // タブ内をScrollViewで包む。内側の行一覧用ScrollView(`.frame(minHeight: 140)`)は
        // 高さが固定的なため、外側のスクロールと競合しない。
        ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            Text("音声認識・整形の結果テキストに対し、登録した「置換元→置換先」を上から順に適用してから挿入します。誤認識の確定修正(例: 「ボイスライダー」→「Voicewriter」)や、専門用語・固有名詞の表記統一に使えます。有効な置換先の語は、認識・整形の語彙ヒントにも自動的に追加されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.dictionary.rules.isEmpty {
                Text("ルールがまだ登録されていません。「追加」から登録できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(store.dictionary.rules.enumerated()), id: \.element.id) { index, _ in
                        DictionaryRuleRow(
                            rule: ruleBinding(at: index),
                            isFirst: index == 0,
                            isLast: index == store.dictionary.rules.count - 1,
                            onMoveUp: { moveRule(at: index, by: -1) },
                            onMoveDown: { moveRule(at: index, by: 1) },
                            onDelete: { deleteRule(at: index) }
                        )

                        if index < store.dictionary.rules.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(6)
            }
            .frame(minHeight: 140)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )

            Text("置換元(左)が空の行は適用時に無視されます。大文字・小文字は区別します。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    store.addRule()
                } label: {
                    Label("追加", systemImage: "plus")
                }

                Spacer()

                Button("dictionary.jsonをFinderで表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                }
                .font(.footnote)
            }

            Text(store.fileURL.path)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(store.fileURL.path)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        }
    }

    /// 指定した`index`の1件だけへの双方向バインディング。`TextField`へキー入力があるたびに
    /// この`set`が呼ばれ、配列全体を組み立て直して`store.setRules`へ渡る
    /// (=キー入力のたびに即座にファイルへ保存される。仕様の「編集は即保存」を満たす)。
    private func ruleBinding(at index: Int) -> Binding<UserDictionaryRule> {
        Binding(
            get: {
                guard store.dictionary.rules.indices.contains(index) else {
                    return UserDictionaryRule()
                }
                return store.dictionary.rules[index]
            },
            set: { newValue in
                var rules = store.dictionary.rules
                guard rules.indices.contains(index) else { return }
                rules[index] = newValue
                store.setRules(rules)
            }
        )
    }

    /// ドラッグ並べ替えの代わりに、行の上下移動ボタンから呼ばれる。
    private func moveRule(at index: Int, by offset: Int) {
        var rules = store.dictionary.rules
        let target = index + offset
        guard rules.indices.contains(index), rules.indices.contains(target) else { return }
        rules.swapAt(index, target)
        store.setRules(rules)
    }

    private func deleteRule(at index: Int) {
        var rules = store.dictionary.rules
        guard rules.indices.contains(index) else { return }
        rules.remove(at: index)
        store.setRules(rules)
    }
}

/// 辞書ルール1件分の行。`List`を使わないため、`TextField`はクリックで即座にフォーカスが入る。
private struct DictionaryRuleRow: View {
    @Binding var rule: UserDictionaryRule
    let isFirst: Bool
    let isLast: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 0) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                }
                .disabled(isFirst)
                .help("この行を上へ移動")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                }
                .disabled(isLast)
                .help("この行を下へ移動")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle("", isOn: $rule.isEnabled)
                .labelsHidden()
                .help("このルールを有効にするかどうか")

            TextField("置換元", text: $rule.from)
                .textFieldStyle(.roundedBorder)

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField("置換先", text: $rule.to)
                .textFieldStyle(.roundedBorder)

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("この行を削除")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}
