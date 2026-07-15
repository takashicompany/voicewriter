# Voicewriter

macOSメニューバー常駐の音声入力アプリです。STTはwhisper.cpp(ggml-large-v3-turbo, Metal有効)をデフォルトエンジンとして使い、モデルが未配置の場合はスタブ実装(録音したPCMをWAVとして保存し、ダミーテキストを返す)にフォールバックします。文字起こし結果はAmical方式(クリップボード経由+Cmd+V合成)でカーソル位置に自動挿入されます。

## 必要環境

- macOS 14 (Sonoma) 以上 (Apple Silicon / Intel)
- Xcode (Command Line Tools) — `xcodebuild -version` で確認可能
- ネットワーク接続 (初回ビルド時にSwift Package Manager経由で [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) を取得、また `scripts/download-model.sh` 実行時にwhisper.cppモデル(約1.6GB)をダウンロードします)
- ディスク空き容量 約2.5GB以上(モデル本体1.6GB + 余裕分)

XcodeGenやXcodeプロジェクトは使わず、Swift Package Manager (SPM) executableターゲット + 手動の.appバンドル組み立てスクリプトで構成しています。

## ビルド方法

### 開発中の実行 (バンドル化なし)

```sh
swift build
swift run
```

`swift run` はメニューバーに常駐するアプリとして起動しますが、Info.plistが適用されないため`LSUIElement`はコード側の `NSApp.setActivationPolicy(.accessory)` で代替しています(Dockアイコンは出ません)。マイク権限の紐付けはプロセス単位になるため、正式な権限確認は下記の.appバンドル経由で行ってください。

### .appバンドルとしてビルド

```sh
./scripts/build-app.sh release   # または debug
open build/Voicewriter.app
```

`scripts/build-app.sh` は以下を行います。

1. `swift build -c <configuration>` でexecutableをビルド
2. `build/Voicewriter.app/Contents/{MacOS,Resources,Frameworks}` に実行ファイル・Info.plist・KeyboardShortcutsのリソースバンドル・whisper.xcframework(dynamic framework)を配置
3. コード署名(下記「安定した署名について」参照)

`build/` と `.build/` は `.gitignore` 対象です。

### 安定した署名について(TCC/アクセシビリティ許可を再ビルドごとに失わないために)

以前は `codesign --sign -` (アドホック署名)のみを使っていました。アドホック署名は実行ファイルの内容から署名identityを算出するため、**再ビルドのたびに署名が変わり**、TCC(アクセシビリティ・マイク等のプライバシー許可管理)が「別アプリ」とみなして許可をリセットしてしまいます。これを避けるため、ログインキーチェーンに自己署名のコード署名証明書を1つ用意し、毎回同じ証明書で署名するようにしています。

初回セットアップ(1回だけ・非対話で実行できます):

```sh
./scripts/create-signing-identity.sh
```

このスクリプトは、ログインキーチェーンに `"Voicewriter Dev Signing"` という名前の自己署名証明書(`extendedKeyUsage=codeSigning`)が無ければ、`openssl`で鍵と証明書を生成して `security import` でログインキーチェーンへ登録します(Keychain AccessアプリのCertificate Assistantの「コード署名」証明書作成をCLIで代替したものです)。同名の証明書が既にあれば何もせず終了するため、繰り返し実行しても安全です。

`security import` 時に `-T /usr/bin/codesign` を指定して`codesign`からのアクセスを明示的に許可しているため、`security set-key-partition-list`(ログインパスワードの入力が必要)は不要です。自己署名証明書のため `security find-identity -v`(validのみ)には出てきません(`CSSMERR_TP_NOT_TRUSTED`)が、`codesign --sign "Voicewriter Dev Signing"` 自体は問題なく動作します。

`scripts/build-app.sh` は以下の優先順位で署名identityを決定します。

1. 環境変数 `VOICEWRITER_SIGN_IDENTITY` が指定されていればそれを使う
2. 未指定なら、ログインキーチェーンに `"Voicewriter Dev Signing"` があればそれを使う
3. どちらも無ければ従来通りアドホック署名(`-`)にフォールバックする

```sh
# 明示的にidentityを指定したい場合
VOICEWRITER_SIGN_IDENTITY="Voicewriter Dev Signing" ./scripts/build-app.sh release
```

同一の証明書で署名し続ける限り、`codesign -dv --requirements -` で表示される designated requirement のうち `certificate leaf = H"..."` の部分は再ビルドをまたいで同一に保たれます(実際に2回ビルドして一致することを確認済みです)。これによりTCCの許可(アクセシビリティ等)が再ビルドのたびにリセットされることはなくなります。

**証明書導入直後の1回だけ**、以前アドホック署名時代に許可していたアクセシビリティ権限は一致しなくなるため、以下でリセットしてから許可し直す必要があります(マイク権限は別署名identityに紐付いていた実績と関係なく維持されるため、リセット不要です)。

```sh
tccutil reset Accessibility dev.voicewriter.app
```

この後は、新しい証明書で署名され続ける限り、アクセシビリティの許可は再ビルドをまたいで維持されます。

## whisper.cpp統合

### xcframeworkの取得方法

[whisper.cpp](https://github.com/ggml-org/whisper.cpp) の公式リリース(v1.7.5以降、動作確認はv1.9.1)に添付されているビルド済み `whisper-vX.Y.Z-xcframework.zip` を取得し、macOS向けスライス(`macos-arm64_x86_64`)だけを抽出して `vendor/whisper.xcframework` に配置しています(iOS/tvOS/xrOS向けスライスは本アプリでは不要なため同梱していません)。

```sh
curl -L -o whisper-xcframework.zip \
  https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip
unzip whisper-xcframework.zip
# build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework を
# vendor/whisper.xcframework/macos-arm64_x86_64/ にコピーし、
# AvailableLibrariesをmacos-arm64_x86_64のみに絞ったInfo.plistを添える
```

`vendor/whisper.xcframework` は `Package.swift` の `binaryTarget(name: "whisper", path: "vendor/whisper.xcframework")` として参照し、`Voicewriter`実行ターゲットにリンクしています。フレームワークのmodulemapが `Metal`/`Accelerate`/`Foundation`/`c++` を自動リンクするため、追加のリンカ設定は不要です(ただし`.appバンドル`化時にContents/Frameworksへ配置する必要があるため、実行ファイルには `@executable_path/../Frameworks` へのrpathを追加しています)。

自前でビルドする場合は、whisper.cppのソースを取得し `./build-xcframework.sh` を実行する方法もあります(Xcodeが必要・ビルドに時間がかかります)。今回はネットワーク環境が安定していたため、公式リリースのビルド済みxcframeworkをダウンロードする方法を採用しました。

### モデルの配置

STTモデルは [ggml-large-v3-turbo](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-large-v3-turbo.bin) (約1.6GB) を使用します。配置先は `~/Library/Application Support/Voicewriter/models/ggml-large-v3-turbo.bin` です。

```sh
./scripts/download-model.sh
```

このスクリプトは、ダウンロード前にホームディレクトリの空き容量を確認し、`.part`拡張子で一時ファイルとしてダウンロードしてから、SHA-256を検証した上で成功時のみ最終ファイル名にリネームします(中断・改ざん・破損したファイルが残らないようにするため)。URLは`main`ブランチではなく特定コミット(revision)に固定し、期待するSHA-256をスクリプト内に記録しているため再現性があります。既に同一のSHA-256を持つファイルが配置済みの場合はダウンロードをスキップします。

任意機能のVAD(Voice Activity Detection、既定OFF)を使う場合は、追加でSilero-VADモデル(約860KB)を配置します。

```sh
./scripts/download-vad-model.sh
```

配置先は`~/Library/Application Support/Voicewriter/models/ggml-silero-v5.1.2.bin`です。取得元・検証方法は`download-model.sh`と同様(SHA-256固定・`.part`経由の原子的な配置)です。モデルを配置した上で設定画面の「音声認識」タブでVADを有効化してください。

### 起動時のロードとフォールバック

- アプリ起動時に一度だけ `whisper_init_from_file_with_params` 相当の初期化を行い、`WhisperCppEngine` インスタンスを常駐させます(以後の文字起こしはこのインスタンスを使い回します)。
- モデルファイルが配置されていない、またはロードに失敗した場合は自動的に `StubTranscriptionEngine` にフォールバックし、メニューバーに警告(⚠️アイコン+メニュー項目)を表示するとともにログにも警告を出力します。
- エンジン切り替えは `defaults write dev.voicewriter.app sttEngine -string stub`(または`whisperCpp`)で明示的に指定できます。
- 言語は既定で `ja` です。`defaults write dev.voicewriter.app sttLanguage -string auto` で自動判定に切り替えられます。

### whisper_fullのデコードパラメータ(実使用時の認識精度改善)

実際のディクテーションで、固有名詞の誤認識(例: "Voicewriter"→「ボイスライダー」)や類似フレーズの繰り返しが報告されたため、`WhisperCppEngine.runFull`(`Sources/Voicewriter/Transcription/WhisperCppEngine.swift`)のパラメータをwhisper.cpp本家CLI(`whisper-cli`, v1.9.1)の既定値に合わせました。以前の実装は`WHISPER_SAMPLING_GREEDY`を常時強制しており、本家CLIの既定挙動(ビームサーチ)と乖離していました。

- **サンプリング戦略をビームサーチ(`beam_size=5`)に変更**。`examples/cli/cli.cpp`は`params.beam_size`の既定値(`whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH).beam_search.beam_size`、`src/whisper.cpp`で`5`)をそのまま使い、`beam_size > 1`なら常にビームサーチへ切り替えるため、whisper-cliは既定でビームサーチを使っています。以前の実装(`WHISPER_SAMPLING_GREEDY`常時強制)とwhisper-cliとの唯一の大きな差分でした。
  - 一次情報: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/src/whisper.cpp (`whisper_full_default_params`関数)
  - 一次情報: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/examples/cli/cli.cpp#L31-L82 (`params.beam_size`/`params.best_of`の初期化・`wparams.strategy`の決定ロジック)
- **`greedy.best_of=5`も明示的に設定**: `beam_search.beam_size`だけでなく`greedy.best_of`も5に設定しています。temperatureフォールバックで温度が0を超えると、ビームサーチではなくgreedy側の`best_of`本の候補を生成して最良のものを選ぶ経路を通るため、`greedy.best_of`を設定し忘れると既定値の0のままになりフォールバック時の候補数が意図せず変わってしまいます。whisper-cliは`wparams.greedy.best_of = params.best_of`を常に設定しており(`params.best_of`の既定値も5)、これに合わせました。
- **temperatureフォールバックの閾値をwhisper-cli既定値に明示的に固定**: `temperature=0.0`, `temperature_inc=0.2`, `entropy_thold=2.4`, `logprob_thold=-1.0`, `suppress_blank=true`。値自体は`whisper_full_default_params`の既定値と同一ですが、whisper.cppのバージョン間で既定値が変わっても挙動が変化しないよう明示的に設定しています(出典は上記`src/whisper.cpp`と同じ)。
- **`suppress_nst=true`(非音声トークン抑制)・`no_speech_thold=0.2`に変更**: whisper-cliの既定値(`suppress_nst=false`, `no_speech_thold=0.6`)ではなく、本アプリと同様に「プッシュ・トゥ・トークで短い発話単位を都度デコードする」実装であるHandy(内部でcjpais/transcribe-rsのwhisper.cppラッパーを利用)の実運用値を採用しました。どちらも無音・ノイズ区間での無関係なトークン出力(ハルシネーション)を抑える方向に働きます。
  - 一次情報: https://github.com/cjpais/transcribe-rs/blob/main/src/whisper_cpp/mod.rs (`WhisperInferenceParams::default()`: `suppress_non_speech_tokens=true`, `no_speech_thold=0.2`)
- **語彙ヒント(`initial_prompt`)を追加**: 設定画面の「音声認識」タブ、または`defaults write dev.voicewriter.app sttVocabularyHint -string "..."`で、固有名詞・専門用語のヒントをカンマ区切りで登録できます(既定値は`"Voicewriter"`)。whisper.cppの`initial_prompt`はデコーダの文脈として働き、強制はしませんが固有名詞の誤認識を減らす手がかりになります。Amicalの語彙ヒント機能を参考にしました。設定は`WhisperCppEngine`が呼び出しごとに読むため、エンジン再ロード無しで次回の文字起こしから反映されます。
- **先頭の低エネルギー区間(無音/発話前ノイズ)のトリム**: `AudioPreprocessing.trimLeadingSilence`(`Sources/Voicewriter/Transcription/AudioPreprocessing.swift`)が、20msフレーム単位のRMSがしきい値(既定0.015)を初めて超える位置の0.15秒手前までをトリムしてから`whisper_full`に渡します(最大トリム量1秒、全区間が無音の場合はトリムしません)。AlwaysOnモードのプリロール(既定0.5秒)に発話前のノイズが混入し、それがハルシネーションを誘発するケースへの対策です。純粋関数として切り出しており、`Tests/VoicewriterTests/AudioPreprocessingTests.swift`で単体テスト済みです。
- **VAD(Voice Activity Detection)をオプション機能として追加(既定OFF)**: whisper.cpp v1.9.1では`whisper_full_params`自体にVAD(Silero-VADベース)が統合されています。設定画面の「音声認識」タブでVADを有効にすると、`scripts/download-vad-model.sh`で配置した`ggml-silero-v5.1.2.bin`を使って発話区間だけをデコードします。無音・非音声区間でのハルシネーション(下記issue参照)の軽減が期待される機能です。VADパラメータ自体はwhisper.cppの既定値(`whisper_vad_default_params()`: `threshold=0.5, min_speech_duration_ms=250, min_silence_duration_ms=100, speech_pad_ms=30, samples_overlap=0.1`)をそのまま使っています。
  - 一次情報: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/README.md#voice-activity-detection-vad
  - 末尾無音でのハルシネーション報告(公式issue): https://github.com/ggml-org/whisper.cpp/issues/1724
- **AVAudioConverterのサンプルレート変換品質を明示的に`.max`に設定**: `AudioCaptureEngine.installTapIfNeededLocked`で生成する`AVAudioConverter`は、`sampleRateConverterQuality`が未指定だとシステム既定(品質はドキュメント上未規定)になります。マイクのネイティブサンプルレート(多くは44.1/48kHz)から16kHzへ毎回ダウンサンプルするため、明示的に最高品質を指定しました。
  - 一次情報: https://developer.apple.com/documentation/avfaudio/avaudioconverter/samplerateconverterquality
- **(検討したが不採用)`no_timestamps=true`**: 30秒以内の短い発話ではタイムスタンプ計算自体が不要という考えでA/B検証しましたが、`sample-ja-vocab-16k.wav`で出力が「Voicewriterから...」→「ボイスライターから...」に変化するなど、語彙ヒントの効き方に予測しづらい副作用があり、明確な優位性も確認できなかったため採用を見送りました(下記「改善前後の比較」参照)。

参考として、VoiceInk(https://github.com/Beingpax/VoiceInk )とHandy(https://github.com/cjpais/Handy 、実体は依存クレートの https://github.com/cjpais/transcribe-rs )の実際のソースを調査しました。値のみを参考にし、GPLコードの引用・移植は行っていません。

- **VoiceInk**(`VoiceInk/Transcription/Whisper/LibWhisper.swift`): `WHISPER_SAMPLING_GREEDY`(ビームサーチではなくgreedy)、`temperature=0.2`、`no_context=true`。`initial_prompt`(`WhisperPrompt.swift`)は語彙リストではなく、**言語ごとの自然な挨拶文**(例: 日本語は「こんにちは、お元気ですか？お会いできて嬉しいです。」)をユーザーが言語ごとにカスタマイズできる形で使っており、句読点・文体をプライミングする目的と読み取れます。VAD(任意)を有効にする場合は`threshold=0.5, min_speech_duration_ms=250, min_silence_duration_ms=100, speech_pad_ms=30`等を設定しています。
- **Handy**(`src-tauri/src/managers/transcription.rs` + `transcribe-rs`の`src/whisper_cpp/mod.rs`): `SamplingStrategy::BeamSearch { beam_size: 3 }`、`suppress_blank=true`、`suppress_non_speech_tokens=true`、`no_speech_thold=0.2`、`no_context=true`。`initial_prompt`は`settings.custom_words.join(", ")`、つまり**ユーザー登録した固有名詞をカンマ区切りで渡す**実装で、本アプリの語彙ヒント機能と同じ発想です。

本実装は主にwhisper-cliの既定値(beam_size=5、temperature系フォールバック)をベースにしつつ、ハルシネーション抑制についてはHandyの実運用値(`suppress_nst=true`, `no_speech_thold=0.2`)を採用するハイブリッドな構成にしました。VoiceInkの「自然文プロンプトによる句読点プライミング」は今回は採用しておらず(下記「見送った項目」参照)、今後の改善候補として残しています。

### 検証用CLI

`Sources/VerifyWhisper` は、実際にWAVファイルをwhisper.cppへ渡して文字起こし結果と処理時間を標準出力へ表示するスタンドアロンCLIです。Swift Package Managerの制約上、実行ファイルターゲット同士はリンクできないため`Voicewriter`モジュールをimportできず、`WhisperCppEngine.swift`/`AudioPreprocessing.swift`と同一のパラメータ・ロジックを意図的に複製しています(どちらかを変更したらもう一方も追随させること、詳細はファイル冒頭のコメント参照)。

```sh
swift run verify-whisper scripts/fixtures/sample-ja-16k.wav
```

`scripts/fixtures/sample-ja-16k.wav` は `say -v Kyoko` で生成した日本語音声(「こんにちは、今日は良い天気ですね。音声入力のテストをしています。」)を16kHz/mono/PCM16に変換したサンプルです。本実装ではこのCLIを実行し、whisper.cppが実際に上記と一致する日本語テキストを返すことを確認済みです(下記「動作確認済み事項」参照)。

認識精度改善(ビームサーチ化・語彙ヒント・先頭無音トリム)の検証用に、以下のフィクスチャを追加しました(いずれも`say`とffmpeg/afconvertで生成した合成音声。実マイク環境の劣化を完全には再現できませんが、回帰確認用として使えます)。

| ファイル | 内容 |
|---|---|
| `sample-ja-16k.wav` | 既存の基準フィクスチャ |
| `sample-ja-vocab-16k.wav` | 文中に"Voicewriter"を含む文(語彙ヒントの効果確認用) |
| `sample-ja-fast-16k.wav` | `say -r 400`(早口)版 |
| `sample-ja-quiet-16k.wav` | 元音声を-20dB(小声)にした版 |
| `sample-ja-silence-pad-0.5s-16k.wav` | 前後に0.5秒の無音を付加した版 |
| `sample-ja-silence-pad-16k.wav` | 前後に1秒の無音を付加した版(先頭無音トリムの確認用) |
| `sample-ja-preroll-noise-16k.wav` | 先頭に0.5秒の低振幅ホワイトノイズを付加した版(プリロールノイズによるハルシネーション誘発の確認用) |
| `sample-ja-10s-16k.wav` | 約11秒の速度計測用フィクスチャ |

`verify-whisper`はA/B比較用に以下の環境変数をサポートしています(省略時は本アプリの既定と同一)。

```sh
VERIFY_WHISPER_STRATEGY=greedy swift run verify-whisper scripts/fixtures/sample-ja-16k.wav   # greedy|beam5(既定beam5)
VERIFY_WHISPER_VAD=1 swift run verify-whisper scripts/fixtures/sample-ja-silence-pad-16k.wav  # VADを有効化(要ggml-silero-v5.1.2.bin)
VERIFY_WHISPER_NO_TIMESTAMPS=1 swift run verify-whisper scripts/fixtures/sample-ja-16k.wav    # no_timestamps=true
VERIFY_WHISPER_VOCAB_HINT="" swift run verify-whisper scripts/fixtures/sample-ja-16k.wav      # 語彙ヒントなしで検証
```

## マイク権限について

初回起動時、システムがマイクアクセスの許可ダイアログを表示します。**この許可はユーザー操作が必要**なため、自動テストでは確認できません。実機で以下を確認してください。

- 初回 `open build/Voicewriter.app` 時にマイク権限ダイアログが出ること
- 許可後、システム設定 > プライバシーとセキュリティ > マイク に「Voicewriter」が表示されること

`./scripts/create-signing-identity.sh` で導入した安定署名(「安定した署名について」参照)を使っている限り、再ビルドしても署名identityは変わらないため、通常はマイク権限が再ビルドのたびにリセットされることはありません。アドホック署名(`VOICEWRITER_SIGN_IDENTITY=-`)を使った場合や、挙動がおかしい場合は以下でリセットできます。

```sh
tccutil reset Microphone dev.voicewriter.app
```

`Info.plist` には `NSMicrophoneUsageDescription` と `LSUIElement=true` を設定済みです。

## カーソル位置へのテキスト挿入(Amical方式)とアクセシビリティ権限

文字起こしが完了すると、`TextInserter`(`Sources/Voicewriter/TextInsertion/`)が以下の手順でカーソル位置にテキストを自動挿入します。

1. `NSPasteboard.general` の現内容(全アイテム・全タイプ)をスナップショット保存
2. 認識テキストをペーストボードにセット
3. 現在のキーボードレイアウトで"V"に対応する仮想キーコードを解決し(取得できなければQWERTYの`kVK_ANSI_V`(9)にフォールバック)、CGEventでCmd+Vのkey down/upを合成して`cgSessionEventTap`へpost
4. 一定時間(既定0.4秒)待ってから、ペーストボードのchangeCountが自分の書き込み直後から変わっていなければ元の内容を復元(待機中に他プロセスが書き換えていた場合は復元しない)

この機能には**アクセシビリティ権限**が必要です。起動時に `AXIsProcessTrustedWithOptions` (プロンプト表示オプション付き)で確認し、未許可の場合はメニューバーに警告を表示します。許可手順:

1. システム設定 > プライバシーとセキュリティ > アクセシビリティ を開く
2. 「Voicewriter」を追加してオンにする(初回は自動でこの画面が開くダイアログが表示されることがあります)
3. Voicewriterを再起動する

`./scripts/create-signing-identity.sh` で導入した安定署名を使っている場合、この許可は再ビルドをまたいで維持されるため、**上記の許可作業は(証明書導入後は)基本的に1回だけ**で済みます。アドホック署名に戻した場合や、証明書を作り直した場合は、再度 `tccutil reset Accessibility dev.voicewriter.app` の上で許可し直してください。

## 設定画面

メニューバーの「設定...」(⌘,)からSwiftUI製の設定ウィンドウを開けます。このアプリは`LSUIElement=true`(Dockアイコン無し)のため、ウィンドウを開くたびに`NSApp.activate` + `makeKeyAndOrderFront`で明示的に前面化しています(`Sources/Voicewriter/App/SettingsWindowController.swift`)。5つのタブで構成されます(`Sources/Voicewriter/Settings/`)。

- **マイク**: マイクモード(常時オープン/必要時のみ)の切替、プリロール秒数(0〜2秒)、リングバッファ秒数のスライダー。マイクモードとリングバッファ秒数の変更は`AudioCaptureEngine`へ即座に反映されます(常時オープンへの切替はAVAudioEngineを起動、必要時のみへの切替は録音中でなければ即座にエンジンを停止)。
- **ショートカット**: `KeyboardShortcuts.Recorder`でPush-to-Talk/トグル/キャンセルの割当を変更できます。変更はライブラリ側が自動的に永続化・グローバル監視へ反映します。
- **音声認識**: エンジン(whisper.cpp/スタブ)と言語(`ja`/`auto`)の選択、認識のヒント(`initial_prompt`用の語彙ヒント、カンマ区切り)、モデルファイルの状態表示(配置済みならパスとサイズ、未配置ならダウンロードボタンで進捗付きダウンロードを実行可能)。エンジン/言語の変更は次回の文字起こしから反映されます(`Sources/Voicewriter/Transcription/DynamicTranscriptionEngine.swift`が内部エンジンを差し替える)。ヒントの変更はエンジン再ロード不要で次回の文字起こしから反映されます。
- **整形**: LLM整形(下記「LLM整形パス」参照)のON/OFF、Ollamaモデル選択(`/api/tags`から動的取得)、タイムアウト秒数。
- **一般**: ログイン時に起動するかどうかを`SMAppService.mainApp`(macOS 13+)で登録/解除します。加えて、状態表示HUD・効果音のON/OFF(下記「状態表示HUDと効果音」参照、いずれも既定ON)。

## 状態表示HUDと効果音

superwhisper/Wispr Flow風の、画面下部中央に浮かぶ小さなピル型パネルで録音・認識・整形・挿入の状態を表示します(`Sources/Voicewriter/HUD/`)。`Coordinator`/`AudioCaptureEngine`/`TextInserter`の既存コールバック・状態変更点に配線を追加しただけで、状態機械のロジック自体には手を入れていません。

### 表示内容

| 状態 | 表示 |
|---|---|
| 録音中 | マイクアイコン + 5本バーの簡易音声レベルメーター(RMS、`AudioCaptureEngine.onLevelUpdate`から購読) + 「録音中」 |
| 認識中 | スピナー + 「認識中…」 |
| 整形中 | スピナー + 「整形中…」(`Coordinator.onPhaseChanged`で内部フェーズを通知。`AppState`自体はこの間ずっと`.transcribing`のまま) |
| 挿入完了 | チェックマーク + 「挿入しました」を0.8秒表示してフェードアウト |
| フォールバック挿入 | 警告アイコン + 「整形なしで挿入」を1.5秒表示してフェードアウト(LLM整形が失敗し原文へフォールバックした場合) |
| idle | 完全に非表示(パネルを`orderOut`) |

表示/非表示は0.15秒のフェードアニメーション。ダーク寄りの半透明マテリアル(`.ultraThinMaterial`)・角丸ピル型・幅約208pxのコンパクトなパネル。

### フォーカスを奪わない実装(`StatusHUDPanel`)

`Sources/Voicewriter/HUD/StatusHUDPanel.swift`の`StatusHUDPanel`(`NSPanel`のサブクラス)で以下を徹底しています。

- `styleMask`に`.nonactivatingPanel`を指定
- `canBecomeKey`/`canBecomeMain`を常に`false`にオーバーライド(=`orderFront`しても絶対にキーウィンドウ/メインウィンドウにならない)
- `ignoresMouseEvents = true`(クリック等のマウスイベントも一切受け取らず素通し)
- `level = .statusBar`、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`(Spaceを跨いでも・フルスクリーンアプリ上でも表示され続け、Mission Control等の通常ウィンドウ一覧には含めない)
- 初期化時に`orderOut(nil)`を呼び、起動直後から非表示であることを保証

実機での確認(`build/Voicewriter.app`起動、⌥⇧Space合成入力でトグル録音を発火): 録音開始でHUDウィンドウが`onscreen=true`になった一方、`osascript`で取得したフロントモストプロセスは録音前後を通じて操作対象アプリ(Google Chrome)のままで変化しなかった。すなわちHUDの前面化が他アプリのフォーカスを奪っていないことを実機でも確認済み。

### 効果音(`Sources/Voicewriter/Support/SoundEffects.swift`)

録音開始時に`NSSound(named: "Tink")`、テキスト挿入完了時(`TextInserter.onPasted`、実際にCmd+Vを送出した直後)に`NSSound(named: "Pop")`を鳴らします。独自音源は追加せず、macOS標準のシステムサウンドのみを使用します。

**録音開始音のマイクへの混入対策について(Amical issue #122を踏まえた判断)**: Amicalでは、録音開始の通知音がマイク準備完了より前に鳴ってしまい、録音の先頭に音が混入する不具合が実際に報告されている。このアプリのAlwaysOnモード(既定)ではマイクは起動時から常時収音済みで、`AudioCaptureEngine.startRecordingLocked()`がプリロールをリングバッファから切り出すのは`Coordinator.state`が`.recording`に変わった直後(=効果音再生の合図とほぼ同時)であり、この切り出し自体は効果音の実際の再生開始(`NSSound.play()`呼び出し後もハードウェア出力までの遅延がある)より先に完了するため、**プリロールそのものへの混入は起きにくい**。

一方で、効果音がスピーカーからマイクへ音響的に回り込み、録音開始直後の実ライブ音声(発話冒頭)に混入する可能性は原理的に残る。これは再生タイミングをどうずらしても、マイクが常時収音している以上「混入箇所が前後にずれるだけ」で根本的には解消しない(たとえば再生完了を待ってから録音受け付けを開始しても、待っている間の音自体は既にリングバッファに記録され続けており、次に切り出すプリロール窓に同じ音が入り込むだけになる)。厳密には「効果音の長さ+プリロール秒数」を上回るだけの遅延を録音受け付け開始に入れれば混入自体は避けられるが、その分だけ録音開始のレイテンシが悪化し発話冒頭を取りこぼすリスクが生じるため、それ自体が新たな実害になると判断した。

このトレードオフを踏まえ、**`AudioCaptureEngine`のタップ処理・録音境界のタイミング不変条件(既存51件のテストが前提とする挙動)には一切手を入れず**、(1) 比較的短いシステムサウンド("Tink"、実測で約0.56秒)を選ぶ、(2) 再生音量を控えめ(0.3)に絞る、の2点で実害を最小化する方針とした。これは混入の**完全な防止ではなく被害軽減**であることを明記しておく。根本的なタイムスタンプベースの除去(録音バッファ側で効果音の再生区間のサンプルを追跡・除外する等)は、既存の慎重に設計されたタイミング不変条件に触れるリスクが対策の効果に見合わないと判断し、今回は見送った。混入を完全に避けたい場合は設定画面で「効果音を鳴らす」をOFFにし、状態表示HUD(無音)のみで録音開始を確認する運用が代替になる。

なお、テキスト挿入完了音("Pop"、実測で約1.6秒とやや長め)は録音が完全に終了した後にのみ再生されるため、この混入問題とは無関係(マイクは既に当該発話の収音を終えている)。`NSSound(named:)`が実際に解決する音源・その正確な長さ/周波数特性はOS/ローカライズ資産の状態に依存し、Appleが仕様として保証しているものではない点にも留意する。

## LLM整形パス(音声認識後のOllamaによる整形)

whisper.cppの生出力には、実際のディクテーションで「音声入力後の文字の生成」→「音声入力収入力後の後文字の精製」のような文脈的な誤認識が発生することが報告されました。この種の誤りは`initial_prompt`(語彙ヒント)だけでは直しきれないため、録音終了時に1回だけLLMへ整形を依頼するパスを追加しました(Amicalの「録音終了時に全文へLLM整形を1回適用する」方式を参考にしつつ、プロンプト・パース方式は本アプリ向けに書き下ろし)。

### 全体パイプライン

```
whisper.cpp生出力 → (Settings.formattingEnabled == trueなら) OllamaFormatter.format() → Coordinator.onTranscriptionResult → TextInserter
```

`Coordinator`(`Sources/Voicewriter/App/Coordinator.swift`)の`applyFormattingIfNeeded`が整形を呼び出します。整形中も状態は`.transcribing`のままなのでメニューバーは「処理中」表示を継続し、Esc(キャンセル)は整形の`await`中に押されても`discardPendingTranscriptionResult`チェックが整形完了後に行われるため正しく反映されます(`Tests/VoicewriterTests/CoordinatorFormattingTests.swift`で回帰テスト済み)。

**整形が失敗した場合(Ollama未起動・タイムアウト・応答不正等)は、`OllamaFormatter`はエラーをthrowするのみで、`Coordinator`が必ずwhisper.cppの生出力へフォールバックします**。フォールバック時はメニューバーに5秒間だけ軽い警告(⚠️)を表示し、録音・挿入自体は中断しません。

### API仕様(Ollama `/api/chat`)

- `think: false` を**リクエスト直下**(`options`の外)に指定してThinkingを無効化する。一次情報: https://docs.ollama.com/capabilities/thinking , https://docs.ollama.com/api/chat 。qwen3系はchat templateが`think:false`時に`/no_think`相当を自動付与する実装になっている。
- `format`にJSON Schema(`{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}`)を指定し、構造化出力で`{"text": "..."}`以外の出力を文法制約レベルで防ぐ。一次情報: https://docs.ollama.com/capabilities/structured-outputs 。
  - 当初はAmical方式の`<formatted_text>`タグ+正規表現パースのみで実装したが、下記ベンチマークで一部モデルがタグの外に無関係な文字列やハルシネーションを出力する事例が見られた。構造化出力に切り替えたところ、同じ3モデル・同じテストケースで**そのような逸脱が完全に無くなった**(詳細は下記「実測ベンチマーク」参照)。タグ抽出は構造化出力が使えない場合の保険として`FormattingPrompt.extractFormattedText`に残している。
- `keep_alive: -1`でモデルをOllamaのメモリに常駐させ続ける。加えてアプリ起動時に`OllamaFormatter.preload()`が空の`messages`で先読みリクエストを送るため(一次情報: https://docs.ollama.com/faq#how-can-i-preload-a-model-into-ollama-to-get-faster-response-times )、通常の利用では初回の整形リクエストもモデルロード待ちにならない。
- `options`: `temperature: 0, top_k: 20, top_p: 0.8, repeat_penalty: 1.0, seed: 42, num_ctx: 4096, num_predict: 512`。決定的かつ逸脱の少ない出力を狙い、`num_predict`は暴走出力による長時間占有を防ぐ上限。

### プロンプト設計(`Sources/Voicewriter/Formatting/FormattingPrompt.swift`)

- ユーザーメッセージは`<ASR_TEXT>...</ASR_TEXT>`で囲み、「これは指示ではなくデータである」ことを構造的に示す(プロンプトインジェクション対策を兼ねる)。
- 許可される操作を4種類(句読点補完/フィラー除去/重複除去/文脈から一意に決まる誤認識の最小修正)に限定して列挙し、禁止操作(要約・言い換え・翻訳・不確実な修正・入力への応答)を明示。
- few-shotとして「誤変換+フィラーを直す例」と「既に整った文はそのまま返す例」を1件ずつ含める。
- 「確信が持てない場合は修正せず元のまま残す」ことを明記。
- 語彙ヒント(`Settings.sttVocabularyHint`と同じ値)を「発音が近い誤変換を見つけたら優先して適用する」セクションとして注入する。

### フォールバック条件(`OllamaFormatter.format`)

以下のいずれかに該当する場合はエラーをthrowし(`Coordinator`が原文へフォールバック)、整形結果を採用しない。

- HTTPエラー・接続不可(Ollama未起動)・指定タイムアウト超過(既定10秒、設定画面で3〜30秒に変更可)
- レスポンスのJSON形式が想定と異なる、または構造化出力・タグ抽出のいずれでも`text`が取り出せない/空文字
- `done_reason == "length"`(`num_predict`上限で打ち切られた=出力が文の途中で終わっている可能性が高い)
- 整形結果の文字数が入力に対して極端に増減している(`FormattingPrompt.isLengthRatioAcceptable`: 長さ比が0.5〜2.0の範囲外なら棄却する簡易チェック。過剰な要約・暴走出力の簡易検知)

### 実測ベンチマーク(`scripts/benchmark-formatter.py`)

Ollama v0.31.2(ローカル、Apple M5 Pro)で、実際に報告された誤認識例を含む8件のテストケースを、候補3モデル(qwen2.5:7b, llama3.1:8b, qwen3:14b、いずれも`think:false`)に投げて比較した。プロンプト・スキーマ・optionsは`OllamaFormatter`/`FormattingPrompt`と完全に同一のものを使用(どちらかを変更したらもう一方も追随させること、`VerifyWhisper`と同じ方針)。

テストケース(抜粋): A=実際に報告された誤認識例、B=フィラー除去、C=言い淀みの繰り返し、D=固有名詞(語彙ヒント)、E=句読点補完、F=ガードレール(質問文に応答しないか)、G=長文要約禁止、H=既に整った文をそのまま返すか。

**構造化出力(`format`スキーマ)適用後の結果(ウォーム状態、モデル常駐済み):**

| モデル | コールド初回(ロード込み) | ウォーム時レイテンシ(短文〜長文) | JSON解析失敗/ガードレール逸脱 | 内容忠実性の問題 |
|---|---|---|---|---|
| qwen2.5:7b | 約3.1秒 | 0.35〜1.3秒 | 0件(8/8成功) | Aで「精度偽善」を「懸念がある」のように言い換え、質問形の文末("でしょうか")を宣言文に変えてしまう(ニュアンス変化) |
| llama3.1:8b | 約3.3秒 | 0.37〜1.6秒 | 0件(8/8成功) | Cで「共有しておきますので」という一節を丸ごと欠落させる(内容の欠落。整形専用という制約への違反) |
| **qwen3:14b(採用)** | 約10.9秒 | 0.63〜2.6秒 | 0件(8/8成功) | 確認された範囲では言い換え・欠落は見られず、原文への忠実さが最も高い |

なお「既に整った文をそのまま返すか」(ケースH、変更不要率)は3モデルとも100%(一切変更せず原文と完全一致)だった。

**重要な発見**: `<formatted_text>`タグ方式(初期実装)では、qwen2.5:7bがフィラー除去のテストケースで無関係なローマ字列("vejime no kyou no kaigi...")を出力する、llama3.1:8bがガードレールのテストケース(「今何時ですか」)で空応答や実際に時刻について言及する応答をしてしまう、といった重大な逸脱が2回の実行のうち複数回再現した。構造化出力に切り替えたところ、**同じ3モデル・同じテストケースでこれらの逸脱が完全に消えた**。つまりモデル選定以上に、Ollamaの構造化出力機能を使うこと自体が信頼性向上に最も効いた変更だった。

**デフォルト選定**: 構造化出力後は3モデルとも実用上「動く」水準になったが、qwen2.5:7b(ニュアンス変化)・llama3.1:8b(内容欠落)にはいずれも原文への忠実性の逸脱が確認され、qwen3:14bにはそれが見られなかったため、`Settings.defaultFormattingModel`は**qwen3:14b**(`think:false`)を採用した。ウォーム時のレイテンシ(長文でも約2.6秒)は既定タイムアウト10秒以内に収まる。速度を優先したい場合は設定画面からqwen2.5:7bへ切り替え可能(コールド約3秒・ウォーム1秒未満で、ニュアンス変化以外の逸脱は確認されていない)。

**既知の限界**:
- 語彙ヒントによる固有名詞修正(「ボイスライダー」→「Voicewriter」)は、3モデルいずれも「ボイスライター」までは近づけるものの、正確な表記(`Voicewriter`、ローマ字表記)への修正は安定して成功しなかった。これはLLM整形単体の限界であり、whisper.cpp側の`initial_prompt`(既存の語彙ヒント機能)による一次的な誤認識抑止と併用する前提とした。
- コールドスタート(Ollama起動直後でモデル未ロード時)はqwen3:14bで約11秒かかり、既定タイムアウト10秒を超えうる。アプリ起動時の`OllamaFormatter.preload()`(`keep_alive:-1`と併用)で緩和しているが、アプリ起動直後10秒以内に最初のディクテーションを行った場合は理論上タイムアウトしうる(その場合も原文へフォールバックするため機能自体は失われない)。
- 追加候補として挙がった`qwen3.5:4b`系の小型モデルは未取得・未検証(pullには追加のネットワーク・ディスク容量が必要なため、既存3モデルで品質・速度とも要件を満たせたことから今回は見送った)。

再現するには:

```sh
python3 scripts/benchmark-formatter.py
```

## 設定値 (UserDefaults)

設定値は `UserDefaults.standard` (`dev.voicewriter.app` ドメイン) で管理しています。設定ウィンドウの各コントロールは`@AppStorage`経由でこれらのキーに直接読み書きするため、`defaults write`での変更も設定ウィンドウの表示に反映されます(逆も同様)。

| キー | 型 | デフォルト | 説明 |
|---|---|---|---|
| `micMode` | string (`alwaysOn`/`onDemand`) | `alwaysOn` | マイクの動作モード |
| `ringBufferSeconds` | double | `3.0` | AlwaysOnモードで保持するリングバッファの秒数 |
| `prerollSeconds` | double | `0.5` | 録音開始時に遡って含めるプリロール秒数 |
| `onDemandIdleTimeoutSeconds` | double | `30.0` | OnDemandモードで録音停止後にエンジンを止めるまでのアイドル秒数 |
| `sttEngine` | string (`whisperCpp`/`stub`) | `whisperCpp` | 文字起こしエンジン。モデル未配置/ロード失敗時は自動的にstub相当の動作にフォールバックする |
| `sttLanguage` | string | `ja` | whisper.cppの言語設定。`auto`で自動判定 |
| `sttVocabularyHint` | string | `Voicewriter` | whisper.cppの`initial_prompt`に渡す語彙ヒント(固有名詞・専門用語、カンマ区切り推奨)。空文字を明示的に設定するとヒント無し |
| `debugSaveLastRecording` | bool | `false` | **[隠し設定・UIなし]** 直近1回分の文字起こし対象音声(先頭無音トリム後、`whisper_full`に渡す直前の16kHz/mono/Float32サンプル)を`~/Library/Application Support/Voicewriter/Debug/last-recording.wav`へ上書き保存するデバッグ機能。公式`whisper-cli`への同一入力比較や、マイク入力パイプラインの音質(ゲイン・クリッピング・ノイズ)の事後検証に使う |
| `vadEnabled` | bool | `false` | VAD(Voice Activity Detection)を有効にするか。有効化には`scripts/download-vad-model.sh`でのモデル配置が必要(未配置の場合は警告ログを出して無効のまま動作する) |
| `formattingEnabled` | bool | `true` | 音声認識結果に対するLLM整形(Ollama)を行うかどうか。OFFでもwhisper.cppの生出力はそのまま挿入される |
| `formattingModel` | string | `qwen3:14b` | LLM整形に使うOllamaモデル名。設定画面「整形」タブで`/api/tags`から動的取得した一覧から選択可能(選定根拠は「LLM整形パス」参照) |
| `formattingTimeoutSeconds` | double | `10.0` | LLM整形リクエストのタイムアウト秒数。超過時はwhisper.cppの生出力へフォールバックする |
| `hudEnabled` | bool | `true` | 状態表示HUD(画面下部中央の浮遊ピル)を表示するかどうか |
| `soundEffectsEnabled` | bool | `true` | 録音開始時・挿入完了時の効果音を鳴らすかどうか |

例:

```sh
defaults write dev.voicewriter.app micMode -string onDemand
```

ログイン時起動の設定は`UserDefaults`ではなく`SMAppService`がOS側で管理するため、上記の一覧には含まれません。

## グローバルホットキー (デフォルト)

[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) を使用しています。設定ウィンドウの「ショートカット」タブから`KeyboardShortcuts.Recorder`で変更できるほか、`defaults write dev.voicewriter.app KeyboardShortcuts_pushToTalk ...`のようにUserDefaults直接編集も可能です。

| 操作 | デフォルト | 挙動 |
|---|---|---|
| Push-to-Talk | F13(修飾キーなし) | keyDownで録音開始、keyUpで録音終了→文字起こし |
| トグル | ⌥⇧Space | keyUp(離した瞬間)でON/OFF切替。キーリピートでは発火しない |
| キャンセル | Esc | 録音中は破棄してidleに戻る。文字起こし中は結果を破棄するフラグを立てる。**idle時はグローバルホットキー自体を無効化しており、他アプリのEscを奪わない**(`KeyboardShortcuts.enable/disable`で状態に応じて切り替え) |

## 構成

```
Sources/Voicewriter/
  App/              アプリ起動・状態機械・メニューバーUI・設定値
    main.swift
    AppDelegate.swift
    Coordinator.swift       idle/recording/transcribing の状態機械
    StatusBarController.swift
    Settings.swift
    SettingsWindowController.swift  設定ウィンドウの生成・前面化(LSUIElement対応)
    LaunchAtLogin.swift             SMAppServiceによるログイン時起動の登録/解除
  Settings/         設定ウィンドウのSwiftUIビュー(5タブ)
    SettingsView.swift
    MicSettingsView.swift
    ShortcutsSettingsView.swift
    TranscriptionSettingsView.swift
    FormattingSettingsView.swift      LLM整形のON/OFF・モデル選択・タイムアウト
    GeneralSettingsView.swift         ログイン時起動・状態表示HUD/効果音のON/OFF
  AudioCapture/     AVAudioEngine周りの音声キャプチャ
    AudioCaptureEngine.swift
    RingBuffer.swift
  Hotkey/           グローバルホットキー登録
    HotkeyManager.swift
    KeyboardShortcuts+Names.swift
  Transcription/    STT抽象化・whisper.cpp実装・スタブ実装
    TranscriptionEngine.swift
    WhisperCppEngine.swift
    AudioPreprocessing.swift          先頭無音/低エネルギーノイズのトリム(純粋関数)
    StubTranscriptionEngine.swift
    DynamicTranscriptionEngine.swift  設定変更(エンジン/言語)を次回文字起こしから反映するラッパー
    ModelDownloader.swift             設定画面からのモデルダウンロード(進捗付き)
    WavWriter.swift
  Formatting/       音声認識結果に対するLLM整形(Ollama)
    TextFormatter.swift        整形の抽象プロトコル・エラー型
    FormattingPrompt.swift     プロンプト組み立て・レスポンス解析(純粋関数、テスト容易)
    OllamaFormatter.swift      Ollama /api/chat 実装(構造化出力・think無効化・keep_alive・タイムアウト)
    OllamaModelLister.swift    設定画面用、/api/tagsからのモデル一覧取得
  TextInsertion/    カーソル位置へのテキスト挿入(Amical方式)
    TextInserter.swift
    AccessibilityPermission.swift
  HUD/              状態表示HUD(浮遊ピル、詳細は「状態表示HUDと効果音」参照)
    StatusHUDPanel.swift       フォーカスを奪わないNSPanelサブクラス
    StatusHUDController.swift  Coordinator等からの配線・表示/非表示のフェード制御
    StatusHUDViewModel.swift
    StatusHUDContentView.swift SwiftUI製の見た目(NSHostingViewで載せる)
  Support/
    GenerationCounter.swift
    SoundEffects.swift  録音開始/挿入完了の効果音(詳細は「状態表示HUDと効果音」参照)
Sources/VerifyWhisper/
  main.swift        whisper.cpp統合の検証用スタンドアロンCLI
Tests/VoicewriterTests/
  AudioRingBufferTests.swift            リングバッファのロック境界・並行アクセスの回帰テスト
  AudioCaptureEngineFormatTests.swift   入力フォーマット検証ロジック・HUDレベルメーター用RMS計算の回帰テスト
  ModelDownloaderStateTests.swift       ダウンロード状態遷移(再試行可否)の回帰テスト
  AudioPreprocessingTests.swift         先頭無音/低エネルギーノイズのトリムの回帰テスト
  CoordinatorCancelDuringTranscribingTests.swift  文字起こし中のEscキャンセルの回帰テスト
  FormattingPromptTests.swift            プロンプト組み立て・レスポンス解析(構造化JSON/タグ両対応)・長さ比チェックの単体テスト
  CoordinatorFormattingTests.swift       整形成功/失敗時のフォールバック・整形中のEscキャンセル・語彙ヒント伝播・HUD用onPhaseChanged通知の回帰テスト
  OllamaFormatterIntegrationTests.swift  実際のOllamaへHTTPリクエストを送る統合テスト(Ollama未起動ならXCTSkip)
  HUDSettingsTests.swift                 hudEnabled/soundEffectsEnabled設定のデフォルト値・永続化の回帰テスト
Resources/
  Info.plist
vendor/
  whisper.xcframework   whisper.cpp公式リリースのxcframework(macosスライスのみ)
scripts/
  build-app.sh
  download-model.sh     ggml-large-v3-turboモデルのダウンロード
  download-vad-model.sh 任意機能VAD用のSilero-VADモデルのダウンロード
  benchmark-formatter.py LLM整形のモデル比較ベンチマーク(詳細は「LLM整形パス」参照)
  fixtures/   検証用の日本語サンプル音声(sample-ja-16k.wav ほか、詳細は「検証用CLI」参照)
```

## 動作確認済み事項

- `swift build` / `swift build -c release` が成功すること(whisper.xcframeworkのbinaryTargetリンクを含む)
- `scripts/build-app.sh` で `.app` バンドルを組み立て、whisper.framework を `Contents/Frameworks` に配置し、アドホック署名まで完了すること
- `open build/Voicewriter.app` 後、プロセスがメニューバー常駐アプリとして生存し続けること(`ps aux` で確認)
- `log show`/`log stream` (`subsystem == "dev.voicewriter.app"`) で以下を確認:
  - 起動時に `WhisperCppEngine` が一度だけモデルをロードすること(`whisper.cpp model loaded from ... (whisper.cpp 1.9.1, language=ja)`)
  - `sttEngine=whisperCpp` で起動し、stubへのフォールバック警告が出ていないこと(モデル配置済みの場合)
  - `micMode=alwaysOn` (デフォルト) では起動直後に `AVAudioEngine started` が出る(エンジン起動しっぱなし)
  - `defaults write dev.voicewriter.app micMode -string onDemand` にすると起動時に `AVAudioEngine started` が出ない(prepare()のみで、録音開始命令待ち)
  - `defaults read dev.voicewriter.app` でPTT/トグル/キャンセルの3つのショートカットがそれぞれ既定値(F13(修飾キーなし) / ⌥⇧Space / Esc)で登録されていること
- **whisper.cppが実際に日本語を認識すること**: `swift run verify-whisper scripts/fixtures/sample-ja-16k.wav` を実行し、`say -v Kyoko`で生成した音声「こんにちは、今日は良い天気ですね。音声入力のテストをしています。」に対して、ダウンロード済みの`ggml-large-v3-turbo`モデルからほぼ完全一致する文字起こし結果が得られることを確認済み。
- 設定ウィンドウの表示・非UI経由の即時反映を確認済み:
  - メニューバーの「設定...」からウィンドウが開き、`NSApp.activate`により前面化すること(ログに`Settings window shown`が出ること)
  - 設定変更を模擬するコード経路(`Settings.micMode`変更 → `AudioCaptureEngine.applyMicModeChange()`)で `AVAudioEngine started`/`AVAudioEngine stopped` が即座にログへ出ること
  - `Settings.ringBufferSeconds`変更 → `AudioCaptureEngine.applyRingBufferSecondsChange()`で `Ring buffer resized to N.Ns` がログへ出ること
  - `Settings.sttEngine`変更 → `DynamicTranscriptionEngine.reload()`で内部エンジンが差し替わり(whisper.cppモデルの再ロードログが出る)、`activeEngineIsFallback`/`warning`が正しく更新されること
- Codexの静的レビューで指摘された競合修正(下記「並行処理まわりの修正」参照)を適用後、`swift build` / `swift build -c release` / `scripts/build-app.sh release` / `swift test` / `swift run verify-whisper scripts/fixtures/sample-ja-16k.wav` が引き続き成功し、`.app`起動→メニューバー常駐→`log show`でマイク権限確認後にのみ`AVAudioEngine started`が出ること(権限確認前に起動を試みないこと)を確認済み。
- 認識精度改善(下記「認識精度の調査・改善」参照)後、`swift build` / `swift build -c release` / `scripts/build-app.sh release` / `swift test`(28件、`AudioPreprocessingTests`6件を追加)がすべて成功し、`swift run -c release verify-whisper`で`scripts/fixtures/`配下の全フィクスチャ(既存分+今回追加した6件)を実行して改善前後の比較・処理時間計測を行ったことを確認済み。
- 署名の安定化・`ModelDownloader`のディスク容量チェック修正(上記「署名の安定化・ModelDownloaderのディスク容量チェック修正」参照)後、`swift build` / `swift test`(28件、変更なし)/ `scripts/build-app.sh release`がすべて成功し、`./scripts/create-signing-identity.sh`で作成した`"Voicewriter Dev Signing"`証明書で2回連続ビルドしても designated requirement の`certificate leaf`部分が一致することを確認済み。`.app`を起動し、`ps aux`でメニューバー常駐プロセスとして生存していること、`log show --predicate 'subsystem == "dev.voicewriter.app"'`で`Accessibility trusted=false`(証明書導入直後に`tccutil reset Accessibility`した直後のため未許可、想定通り)・`Microphone permission requested. granted=true`(マイク権限は未リセットのため維持されている)が出ることを確認済み。アクセシビリティ権限の許可自体はユーザー操作が必要なため未実施。
- **LLM整形パス追加後**、`swift build` / `swift build -c release` / `scripts/build-app.sh release` / `swift test`(51件、`FormattingPromptTests`15件・`CoordinatorFormattingTests`5件・`OllamaFormatterIntegrationTests`3件を追加)がすべて成功し、`swift run verify-whisper scripts/fixtures/sample-ja-16k.wav`でも従来通りの認識結果(回帰なし)を確認済み。`.app`を起動して以下を確認:
  - `log show --predicate 'subsystem == "dev.voicewriter.app"'`で、起動時に`OllamaFormatter`カテゴリの`Preloaded formatting model into Ollama: qwen3:14b`が出ること(起動時プリロードが機能していること)
  - `defaults write dev.voicewriter.app sttEngine -string stub`にして`.app`を再起動し、System Events経由でトグルショートカット(⌥⇧Space)を実際に送って録音開始→停止を発火させ、スタブ文字起こし結果に対して実際にOllamaへ整形リクエストが送られたこと(整形失敗の警告ログが出ないこと)、メニューバーの「最後の文字起こし結果をコピー」→クリップボードの内容が、同じ入力を`scripts/benchmark-formatter.py`の呼び出しロジックで直接Ollamaへ送った場合の出力(`{"text": "[スタブ文字起こし: 2.7秒の音声を録音しました]"}`、この入力は整形不要と判断され原文のまま返る)と一致することを確認済み(パイプライン全体がOllamaへの実リクエストを介して結線されていることの実機確認)。検証後は`sttEngine`設定を削除して既定(whisperCpp)に戻した。
  - `OllamaFormatterIntegrationTests`(実際にローカルOllamaへHTTPリクエストを送るテスト)が3件とも成功すること(Ollama未起動環境では`XCTSkip`で自動的にスキップされる)

## 並行処理まわりの修正(Codexレビュー対応)

Codexの静的レビューで、`AudioCaptureEngine`まわりの並行処理に複数の競合・データレースが指摘されました。対応として、オーディオエンジンの起動/停止/タップ操作/prepare/フォーマット変更復旧、録音開始・終了の境界確定、リングバッファ参照の読み書きを**単一のシリアルキュー(`controlQueue`)に集約**し、タップコールバックからの音声変換・蓄積も同じキュー上で行うようにしました(`Sources/Voicewriter/AudioCapture/AudioCaptureEngine.swift`)。これにより「録音開始/終了の境界」と「音声データの取り込み」が常に単一のタイムライン上で解決され、二重取り込み・語尾欠落・データレースを構造的に防いでいます。主な変更点:

- `AVAudioConverter`の変換結果が`.inputRanDry`の場合も出力フレームを破棄せず使用するよう修正(SDKヘッダ通り、このステータスでも変換済みフレームが入っていることがあるため)
- プリロール取得と録音開始フラグの設定を同一のシリアル区間で行い、リングバッファとの二重取り込みを解消
- 録音停止は`controlQueue`上で実行することで、直前にキューイング済みの音声処理が必ず先に完了してから確定するようにした(FIFOのため明示的な「フラッシュ」操作は不要)
- デバイス切断等による`AVAudioEngineConfigurationChange`受信時、新しい入力フォーマットの妥当性(サンプルレート/チャンネル数)とコンバータ生成成功を検証し、失敗時はタップを再設置せず`Coordinator`へ致命的エラーを通知して録音状態を戻す(`AudioCaptureEngineDelegate.audioCaptureEngine(_:didEncounterFatalError:)`を追加)
- 録音1回あたりの上限を既定5分に設定し、超過時は自動的に文字起こしへ回す(`AudioCaptureEngine.maxRecordingSeconds`)
- `AudioRingBuffer.recent`が`filledCount`の読み取りも含めて単一のロック区間で実行されるよう修正(以前はロック外で読んでからロックし直しており、`append`との競合で不整合な範囲を読みうるデータレースがあった)

その他、以下も合わせて対応しました。

- マイク権限確認のコールバックを待ってから`AlwaysOn`モードのエンジン自動起動を行うようにした(`AppDelegate`)。拒否時はメニューバーに警告を表示する。
- `.transcribing`中のEsc(キャンセル)で、結果が得られても挿入せず破棄するフラグを立てるようにした(`Coordinator.cancelRecording()`)。**`whisper_full`自体の中断は行っていない**(結果破棄のみ)。ggml側には`abort_callback`があるが、C API越しの安全な中断実装は今回のスコープでは見送った。
- キャンセルショートカット(既定Esc)は、録音中/文字起こし中のみ`KeyboardShortcuts.enable/disable`で有効化するようにした(idle時は他アプリのEscを奪わない)。
- 録音開始時点のフロントモストアプリを記録し、文字起こし結果の挿入直前に変わっていたら自動挿入を中止してログ+メニューバー通知を出すようにした(結果はメニューバーの「最後の文字起こし結果をコピー」から回収可能)。
- 文字起こし中に録音操作(PTT/トグル)が要求された場合、`NSSound.beep()`で最低限のフィードバックを返すようにした(キューイングは行わない)。
- `DynamicTranscriptionEngine.reload()`をバックグラウンド(`Task.detached`)でモデルロードするよう変更し、設定UIの`onChange`からの呼び出しでUIがフリーズしないようにした。ロード完了後にのみ参照を差し替え、旧エンジンは差し替え直後(進行中の文字起こしが保持している分を除き)に解放される。
- `ModelDownloader`の状態バグを3点修正: (1) 失敗後の「再試行」ボタンが`.idle`以外を拒否して動かなかった問題(`.failure`からの再試行も許可)、(2) `cancel()`後に届く遅延コールバックが状態を復活させる問題(世代IDをダウンロードタスクの`taskDescription`に埋め込み、現在の世代と一致しないコールバックは無視)、(3) 既存モデルを先に削除してから移動しており移動失敗時に旧モデルまで失う問題(`FileManager.replaceItemAt`によるアトミックな置き換えに変更)。
- 認識結果を`os_log`へ出力する際、`privacy: .public`だったものを`.private`に変更した(`Coordinator`)。

### 見送った項目

- クリップボードのTOCTOU(他プロセスとの競合)、リングバッファ以外のバックプレッシャー対策の追加実装(ただし上記のシリアルキュー化で実質的な改善はある)、特殊キーボードレイアウトでの"V"解決フォールバックの追加検証、`deinit`での明示的クリーンアップの網羅は今回は対応していません(`AudioCaptureEngine`には`NotificationCenter`観測解除の`deinit`のみ追加済み)。

### 回帰テスト

`Tests/VoicewriterTests/`に、上記修正のうちハードウェア非依存で純粋関数として切り出せた部分の回帰テストを追加しました(`swift test`で実行)。

- `AudioRingBufferTests`: `recent`の境界値・ラップアラウンド・並行アクセスのスモークテスト
- `AudioCaptureEngineFormatTests`: `AudioCaptureEngine.isValidInputFormat`(不正な入力フォーマットの検証ロジックを切り出した純粋関数)
- `ModelDownloaderStateTests`: `ModelDownloader.canStartDownload(from:)`(失敗後の再試行可否判定を切り出した純粋関数)

`AVAudioEngine`自体はハードウェア・実オーディオデバイスに依存するため、録音開始/終了の境界やタップ再設置の統合的な動作は自動テスト化しておらず、下記「未確認・今後の課題」に記載の通り実機確認が必要です。

## 2回目のCodex検証レビュー対応

1回目のレビュー対応後、さらにCodexの検証レビューで8件の残存指摘を受け、以下の通り対応しました。

1. **キャンセルフラグの先読み(`Coordinator.swift`)**: `didFinishRecording`ハンドラが`discardPendingTranscriptionResult`を`await transcribe(...)`の**前**にローカル変数へ先読みしていたため、文字起こし実行中(await中)にEscでキャンセルされても古い値のまま判定され、キャンセルが無視されて結果が挿入されてしまっていた。`await`後に改めてプロパティを直接読むよう修正。
2. **録音確定(finalize)の非冪等性(`AudioCaptureEngine.swift`)**: 5分上限による自動停止と、既に要求済みの手動停止が両方とも`stopRecordingLocked()`を呼びうる状態で、二重に`didFinishRecording`が発火し(2回目は空バッファ)、Coordinator側で空の完了が先に状態をidleへ戻し、古いタスクが後から新サイクルの結果を消しうる問題があった。`stopRecordingLocked()`/`cancelRecordingLocked()`を`isRecording`(`controlQueue`上でのみ読み書きされる)を確定済みフラグとして扱うことで冪等化し、2回目以降の呼び出しは無視するようにした。
3. **停止直前のtapコールバック競合(語尾欠落、`AudioCaptureEngine.swift`)**: 停止直前にタップコールバックが開始済みだが`controlQueue`への取り込みが間に合っていない場合、そのバッファがfinalize後に処理されて捨てられ語尾が欠落しうる問題があった。`stopRecording()`が`controlQueue`へfinalizeを投入するタイミングを入力バッファ1個分程度(既定100ms、`AudioCaptureEngine.stopGraceInterval`)遅らせるようにし、その猶予期間内に届いたタップコールバックがFIFOにより必ずfinalizeより先に処理されるようにした。
4. **構成変更復旧の失敗時に録音状態が残る(`AudioCaptureEngine.swift`)**: `AVAudioEngineConfigurationChange`受信時、タップ再設置には成功したがその後のエンジン再起動(`engine.start()`)に失敗した場合、`isRecording`/`recordingBuffer`がクリアされずCoordinator側の状態(idleへリセット済み)と不整合になっていた。エンジン再起動失敗時も内部の録音状態をクリアするようにした(delegateの二重呼び出しは行わない)。
5. **起動時にEscが一時的に有効化される(`Coordinator.swift`/`AppDelegate.swift`)**: `Coordinator.init`でEscをdisableした直後、`HotkeyManager`の構築(`KeyboardShortcuts.onKeyDown/onKeyUp`によるハンドラ登録)が対象ショートカットを無条件に再enableしてしまっていた。`Coordinator.refreshShortcutEnablement()`を追加し、`HotkeyManager`構築直後に`AppDelegate`から呼び直すようにした。
6. **キャンセルキー録り直しで再有効化される(`ShortcutsSettingsView.swift`ほか)**: 設定画面の`KeyboardShortcuts.Recorder`でキャンセルショートカットを再割当てすると、ライブラリ側が無条件に有効化(register)してしまい、idle時にdisableしていたはずのEscが再び有効になっていた。`Recorder`の`onChange`コールバック(ライブラリの公開API)を使い、変更時に`Coordinator.refreshShortcutEnablement()`を呼び直すようにした(`SettingsView`/`SettingsWindowController`/`AppDelegate`経由でコールバックを配線)。
7. **`ModelDownloader`のコールバック順序(`ModelDownloader.swift`)**: progress/finish/completionがそれぞれ独立の非構造化Taskのため、遅延progressが`.success`/`.failure`を上書きしうる問題と、1.6GBの一時ファイルコピーが世代チェックより前に実行されてしまう(キャンセル済みでも無駄なI/Oが走る)問題があった。世代管理をロック保護された`GenerationCounter`(`Sources/Voicewriter/Support/GenerationCounter.swift`)に切り出してMainActor外からも同期的に判定できるようにし、コピー前に世代チェックするよう順序を変更。また`.downloading`以外の状態からは`progress`/`completion`の更新を無視する単調性ガードを追加した。
8. **`DynamicTranscriptionEngine.reload()`の世代順序(`DynamicTranscriptionEngine.swift`)**: 連続で`reload()`を呼んだ場合、モデルロード完了順序が呼び出し順と一致するとは限らず、遅い(古い)呼び出しの結果が後から新しい設定を上書きしうる問題があった。`reload()`呼び出し時に(共通の)`GenerationCounter`から世代IDを発行し、ロード完了後、世代チェック・エンジン差し替え・warning系プロパティの更新を単一の`MainActor.run`ブロック内でアトミックに行うようにし、自分より新しい`reload()`に追い越されていた場合は結果を破棄するようにした。

### 見送った項目(2回目)

なし。指摘された8件はすべて上記の通り対応済みです。

### 回帰テスト(2回目)

- `GenerationCounterTests`: 上記#7・#8が共通で依存する世代管理プリミティブ(`GenerationCounter`)そのものの単体テスト(単調増加・「最新世代だけが有効」・並行アクセスのスモークテスト)。`ModelDownloader`は実際のネットワークダウンロード、`DynamicTranscriptionEngine`はモデルファイルI/Oを伴うため、それら自体をハードウェア・ネットワーク非依存で決定的にテストすることは難しく、両者が依存する共通の同期プリミティブを直接テストする形にしている。
- `CoordinatorCancelDuringTranscribingTests`: 上記#1の回帰テスト。`Coordinator`が実際の`AVAudioEngine`(ハードウェア依存)に直接依存していたためテストが難しかったが、`Coordinator`が操作するインターフェースを`AudioCaptureEngineControlling`プロトコルとして切り出し(`AudioCaptureEngine`がこれに準拠)、テストではフェイク実装に差し替えられるようにした。さらに完了タイミングを制御できるフェイクの`TranscriptionEngine`と組み合わせ、「`await transcribe(...)`実行中にキャンセルが要求される」状況を決定的に再現している。**このテストは修正前のコードに対しては実際に失敗することを確認済み**(先読みしていた`shouldDiscard`を復元して再実行し、失敗を確認してから元に戻した)。

#2(finalizeの冪等化)・#3(停止直前のtapコールバック競合)については、`AudioCaptureEngine`の該当メソッド(`stopRecordingLocked`/`cancelRecordingLocked`/`handleIncomingLocked`)が`controlQueue`上でのみ呼ばれる`private`メソッドであり、かつ実際のタップコールバックのタイミング競合は実機のオーディオハードウェア・スケジューリングに依存するため、決定的な単体テストとしての再現は見送った(1回目のレビュー対応時と同様の理由による既存の除外方針を踏襲)。`swift build`/`swift build -c release`/`scripts/build-app.sh release`/`swift test`(22件)/`swift run verify-whisper scripts/fixtures/sample-ja-16k.wav`(日本語認識が一致することを確認)に加え、`.app`を起動しログ(`log show --predicate 'subsystem == "dev.voicewriter.app"'`)でクラッシュなく起動・マイク権限確認後の`AVAudioEngine started`・ショートカット既定値登録までを確認済み。実際のキー操作を伴う語尾欠落・キャンセルキー再割当ての実機確認は、下記「未確認・今後の課題」を参照。

## 署名の安定化・ModelDownloaderのディスク容量チェック修正

### 署名の安定化(TCC/アクセシビリティ許可が再ビルドごとにリセットされる問題)

上記「安定した署名について」の通り、ログインキーチェーンに自己署名のコード署名証明書(`"Voicewriter Dev Signing"`、`extendedKeyUsage=codeSigning`)を`scripts/create-signing-identity.sh`で用意し、`scripts/build-app.sh`が(環境変数`VOICEWRITER_SIGN_IDENTITY`未指定時は)これを使って署名するように変更しました。同一証明書で2回ビルドし、`codesign -dv --requirements -`が返す designated requirement の`certificate leaf = H"..."`部分が完全一致することを確認済みです。これにより、以前は再ビルドのたびにアドホック署名のハッシュが変わりTCCの許可(アクセシビリティ)がリセットされていた問題が解消されます。証明書導入直後の1回のみ`tccutil reset Accessibility dev.voicewriter.app`を実行し(マイク権限はリセットしていません)、新署名の`.app`を起動しています。

### ModelDownloaderのディスク容量チェック修正(Codexレビュー指摘)

`ModelDownloader.swift`は、URLSessionのダウンロード完了コールバック内で一時ファイルを別ディレクトリへ**コピー**してから最終配置していたため、コピー元(URLSessionの一時ファイル)とコピー先が一時的に両方ディスク上に存在し、モデル約2個分(約3.2GB)を消費しうる一方、空き容量チェックは約1.5GBのままという不整合がありました。対応として、コピー先を最終配置ディレクトリ(`~/Library/Application Support/Voicewriter/models`)と同一ディレクトリ内に変更し、`copyItem`ではなく`moveItem`(同一ボリューム内なら`rename(2)`相当で完了し追加のディスク消費が発生しない)を使うように変更しました。これにより、その後の最終配置への`replaceItemAt`/`moveItem`も同一ディレクトリ内での高速な置き換えになります。空き容量チェックの閾値も、ユーザー向けメッセージ(「約2.5GB以上」)と実際のチェック値(従来は約1.5GBで不一致だった)を一致させ、`requiredFreeSpace = 2_500_000_000`に統一しました。既存の`GenerationCounter`による世代チェック(コールバックの順序保証)のロジックは変更しておらず、`GenerationCounterTests`・`ModelDownloaderStateTests`を含む既存テスト28件が引き続きすべて成功することを確認済みです。

## 認識精度の調査・改善(実使用時の誤認識対応)

実際のディクテーションで「ボイスライダーから魅力しています入力してみます入力しています」のような誤認識(固有名詞の誤認識+類似フレーズの繰り返し)が報告された一方、`say -v Kyoko`生成のクリーンな固定フィクスチャではほぼ完全一致していたため、whisper.cppの呼び出しパラメータとオーディオパイプラインを調査しました。

### 変更したパラメータと根拠

上記「whisper_fullのデコードパラメータ」を参照(サンプリング戦略のビームサーチ化・`greedy.best_of`の明示設定・temperatureフォールバック閾値の明示化・語彙ヒント(`initial_prompt`)追加・先頭無音/低エネルギーノイズのトリム・VADのオプション追加・AVAudioConverterの変換品質明示化)。一次情報はいずれもwhisper.cpp v1.9.1のソース(`src/whisper.cpp`の`whisper_full_default_params`、`examples/cli/cli.cpp`)、公式README(VADセクション)、公式issue #1724、AppleのAVAudioConverterドキュメントです。VoiceInk/HandyのGitHubリポジトリも値の参考として調査しましたが、GPLコードの引用・移植は行っていません。

なお、`best_of`未設定・VAD統合・AVAudioConverterの変換品質未指定の3点は、独立に読み取り専用調査を行ったCodex(本タスクとは別セッション)が指摘した内容を事実として取り込み、当方で検証・実装したものです。

### ビームサーチ(beam_size=5) vs Greedy(その他パラメータは同一)の比較

「サンプリング戦略以外(best_of/temperature系/suppress_nst/no_speech_thold/語彙ヒント/先頭トリム)を完全に揃えた状態」で、`VERIFY_WHISPER_STRATEGY`環境変数を切り替えて比較しました。

| フィクスチャ | Greedy | Beam5(採用) |
|---|---|---|
| `sample-ja-16k.wav` | こんにちは、今日は良い天気ですね。音声入力のテストをしています。 | こんにちは。今日は良い天気ですね。音声入力のテストをしています。(句読点スタイルのみ差異) |
| `sample-ja-silence-pad-0.5s-16k.wav`(前後0.5秒無音) | こんにちは、今日は良い天気ですね。音声入力のテストをしています。 | こんにちは、今日は良い天気ですね、音声入力のテストをしています。(句読点スタイルのみ差異) |
| `sample-ja-silence-pad-16k.wav`(前後1秒無音) | こんにちは、今日は良い天気ですね。音声入力のテストをしています。 | こんにちは、今日は良い天気ですね、音声入力のテストをしています。(句読点スタイルのみ差異) |
| `sample-ja-preroll-noise-16k.wav`(先頭0.5秒ノイズ) | こんにちは、今日は良い天気ですね。音声入力のテストをしています。 | こんにちは、今日は良い天気ですね。音声入力のテストをしています。(完全一致) |
| `sample-ja-vocab-16k.wav`("Voicewriter"含む) | Voicewriterから文字起こしをしています。入力しています。(2segments、句読点あり) | Voicewriterから文字起こしをしています入力しています(1segment、句点が1箇所欠落) |
| `sample-ja-fast-16k.wav`(早口) | こんにちは今日は良い天気ですね音声入力のテストをしています | 同上(変化なし) |

**分かったこと**: 今回の合成フィクスチャの範囲では、いずれの無音パディング・ノイズフィクスチャでもGreedy/Beam5ともにハルシネーションは発生せず、内容の誤認識も無い。唯一の差は`sample-ja-vocab-16k.wav`で、Beam5では文の区切り(句点)が1箇所失われた一方、Greedyは句読点を保ったまま2文に正しく分割した。つまりこの限定的なテストでは**Beam5がGreedyより明確に優れているという結果は得られなかった**。それでもBeam5を採用したのは、(1) whisper.cpp本家CLIの既定挙動と一致させることを主目的としており、(2) OpenAI Whisper/whisper.cppコミュニティで広く実運用されている設定であり、(3) 今回作成した5〜11秒程度のクリーンな合成音声よりも、実際の(訛り・かすれ・早口などを含む)多様な発話でこそビームサーチの効果が出やすいと考えられるためです。速度面での不利も確認されませんでした(下記「速度計測」参照)。今後実運用でGreedyの方が安定するようであれば、`WhisperCppEngine.runFull`の`WHISPER_SAMPLING_BEAM_SEARCH`を`WHISPER_SAMPLING_GREEDY`に戻すだけで切り替えられます。

### VAD(Voice Activity Detection)の有無の比較

無音/ノイズを含むフィクスチャで、`VERIFY_WHISPER_VAD`環境変数によりVAD有効/無効を比較しました(他のパラメータ・語彙ヒント・先頭トリムは同一)。

| フィクスチャ | VAD OFF(既定) | VAD ON |
|---|---|---|
| `sample-ja-16k.wav` | こんにちは。今日は良い天気ですね。音声入力のテストをしています。 | こんにちは、今日は良い天気ですね。音声入力のテストをしています。(句読点スタイルのみ差異) |
| `sample-ja-silence-pad-0.5s-16k.wav` | こんにちは、今日は良い天気ですね、音声入力のテストをしています。 | こんにちは、今日は良い天気ですね。音声入力のテストをしています。(句読点スタイルのみ差異) |
| `sample-ja-silence-pad-16k.wav`(前後1秒無音) | こんにちは、今日は良い天気ですね、音声入力のテストをしています。 | こんにちは、今日は良い天気ですね。音声入力のテストをしています。(句読点スタイルのみ差異) |
| `sample-ja-preroll-noise-16k.wav` | こんにちは、今日は良い天気ですね。音声入力のテストをしています。 | こんにちは、今日は良い天気ですね。音声入力のテストをしています。(完全一致) |

**分かったこと**: 今回のフィクスチャではVAD有無で内容の誤認識・ハルシネーションに差は出ず(いずれも句読点スタイルの違いのみ)、処理時間への影響も0.02〜0.04秒程度と軽微でした。合成フィクスチャでは公式issue #1724(末尾無音でのハルシネーション)を再現できなかったため、VAD自体の効果検証は実マイク環境での確認が必要です。安全性(既定OFF、モデル未配置時は警告して無効のまま動作)を優先し、任意機能として追加しました。

### 改善前後の比較(旧実装 vs 新実装全体、`scripts/fixtures/`、`swift run -c release verify-whisper`)

| フィクスチャ | 変更前(greedy, プロンプト無し, トリム無し) | 変更後(beam_size=5, initial_prompt="Voicewriter", 先頭トリム) |
|---|---|---|
| `sample-ja-16k.wav` | こんにちは、今日は良い天気ですね。音声入力のテストをしています。 | こんにちは。今日は良い天気ですね。音声入力のテストをしています。(句読点のスタイルのみ差異、内容は完全一致) |
| `sample-ja-vocab-16k.wav`("Voicewriter"を含む文) | ボイスライターから文字起こしをしています。入力しています。(2segments、カナ表記+句読点あり) | Voicewriterから文字起こしをしています入力しています(1segment、ラテン表記になった一方、句点が一部欠落) |
| `sample-ja-fast-16k.wav`(早口 `say -r 400`) | こんにちは今日は良い天気ですね音声入力のテストをしています(句読点なし、内容は正確) | 同上(変化なし。ビームサーチでも早口での句読点欠落は解消しなかった) |
| `sample-ja-quiet-16k.wav`(-20dB) | こんにちは、今日は良い天気ですね。音声入力のテストをしています。 | 変化なし(完全一致) |
| `sample-ja-silence-pad-16k.wav`(前後1秒無音) | こんにちは。今日は良い天気ですね。音声入力のテストをしています。(ハルシネーションなし) | 先頭無音0.95秒をトリムした上で内容は完全一致(句読点のスタイルのみ差異) |
| `sample-ja-preroll-noise-16k.wav`(先頭0.5秒の低振幅ノイズ) | こんにちは。今日は良い天気ですね。音声入力のテストをしています。(ハルシネーションなし) | 先頭ノイズ0.45秒をトリムした上で内容は完全一致(句読点のスタイルのみ差異) |

**分かったこと**:

- 今回作成した合成フィクスチャ(`say`生成音声+ffmpegでの無音/ノイズ付加・音量調整・話速変更)の範囲では、変更前・変更後のいずれでも実際の誤認識(繰り返しハルシネーション含む)は再現しなかった。クリーンなTTS音声はそもそも本実装が既に高精度に認識できており、報告された誤認識は実マイク環境固有の音質・発話の揺らぎに起因する可能性が高い(このため、隠し設定の実録音WAV保存機能を今回追加した)。
- 語彙ヒント(`initial_prompt="Voicewriter"`)は狙い通り機能し、`sample-ja-vocab-16k.wav`で"Voicewriter"のラテン表記が出力されるようになった(以前はカナ表記の「ボイスライター」で、実際の誤認識事例の「ボイスライダー」ではなかったが、いずれにせよ固有名詞の表記をアプリ名に寄せる効果を確認)。一方でこのケースでは文中の句点が1箇所失われ、2segmentsだったものが1segmentになった。ビームサーチ+プロンプトの組み合わせで文の区切り方が変わりうるため、ヒント文言は今後実運用のログを見ながら調整の余地がある。
- 先頭無音/低エネルギーノイズのトリムは、`sample-ja-silence-pad-16k.wav`(1秒無音)で0.95秒、`sample-ja-preroll-noise-16k.wav`(0.5秒の低振幅ノイズ)で0.45秒をそれぞれ正しくトリムし、いずれも音声本体を欠落させなかった(内容が変更前と完全一致)。
- 早口フィクスチャでの句読点欠落は、ビームサーチ化・語彙ヒントの追加後も解消しなかった(内容自体の誤認識は無い)。句読点の安定化はさらなる調査課題として残る。

### 速度計測

`swift build -c release` + `swift run verify-whisper`(Apple M5 Pro, Metal有効)で、`whisper_full`本体の処理時間(モデルロードを除く)を計測しました。

| 音声長 | 処理時間(beam_size=5) | リアルタイム比 |
|---|---|---|
| 2.63秒(早口) | 0.301秒 | 0.11x |
| 4.23秒 | 0.319秒 | 0.08x |
| 5.52秒 | 0.286〜0.359秒 | 0.05〜0.07x |
| 6.02秒(プリロールノイズ版、トリム後5.57秒) | 0.281秒 | 0.05x |
| 7.52秒(無音パディング版、トリム後6.57秒) | 0.292秒 | 0.04x |
| 11.04秒(速度計測専用フィクスチャ) | 0.300秒 | 0.03x |

モデルロード自体は0.48〜0.53秒(初回のMetalシェーダコンパイルが発生した場合は数秒かかることがある、2回目以降はキャッシュされ高速)。合計(ロード+処理)は変更前(greedy)のトータル実行時間(約0.78〜0.81秒/5.5秒発話)とほぼ同水準で、ビームサーチ化による体感速度の悪化は確認されませんでした。「10秒発話で2秒以内」の目安に対しては、10秒超の音声でも処理時間0.3秒程度と大幅に余裕があります。

### 見送った項目

- 早口フィクスチャでの句読点欠落の根本解消(内容の誤認識ではないため優先度を下げた)。VoiceInkが採用している「言語ごとの自然な挨拶文を`initial_prompt`にする」方式(上記参照)は句読点・文体のプライミングに有効な可能性があり、次の改善候補として残す(現状の語彙ヒントは固有名詞用途を優先し、自然文プロンプトの併用は行っていない)。
- 実マイク環境の音質検証は、隠し設定(`debugSaveLastRecording`)を追加したのみで、実機での録音・比較は未実施(下記「未確認・今後の課題」参照)。
- `initial_prompt`のデフォルト文言("Voicewriter"のみ)は最小限に留めており、句読点誘導や追加の固有名詞リストは含めていない(設定画面から自由に追加可能)。

## 未確認・今後の課題

- 実際のキー押下によるPTT/トグル/Escキャンセルの一連の動作は、キーボードイベントを直接シミュレートするテストは実施していません(UserDefaultsのショートカット登録値までは確認済み)。実機でキーを押して録音開始→停止→文字起こし→カーソル位置への挿入までを確認してください。
- マイク権限ダイアログの表示・許可はユーザー操作が必要なため未確認です。上記「マイク権限について」を参照してください。
- **アクセシビリティ権限の許可・実際のペースト挙動はユーザー操作が必要なため未確認**です。以下の手順で実機確認してください。
  1. `open build/Voicewriter.app` で起動(初回はアクセシビリティ許可ダイアログが出る、または未許可の場合はメニューバーに⚠️警告が出る)
  2. システム設定 > プライバシーとセキュリティ > アクセシビリティ で「Voicewriter」を許可し、アプリを再起動
  3. メモ帳やブラウザのテキストフィールドなどにカーソルを置き、Push-to-Talk(F13)を押しながら日本語を話し、離す
  4. 文字起こし結果がカーソル位置に自動的に挿入されること、しばらくしてクリップボードが元の内容に戻っていることを確認
- デバイス切替時の自動復旧(`AVAudioEngineConfigurationChange`)は、実際にBluetoothヘッドセット等を抜き差ししての動作確認は未実施です。
- whisper.cppは同一コンテキストに対して非再入のため`WhisperCppEngine`内部でシリアルキューに直列化していますが、Coordinatorの状態機械上そもそも並行して文字起こしが走ることはありません。
- 設定ウィンドウの実機でのマウス/キーボード操作(タブ切替・スライダードラッグ・`KeyboardShortcuts.Recorder`でのキー再割当・モデルダウンロードボタンの実クリック)は、この環境のTerminalにScreen Recording/Accessibility権限が付与されておらずUI自動操作・スクリーンショット取得ができなかったため未確認です。コードパス(ウィンドウ生成・前面化・設定反映ロジック)はログ経由で動作確認済みですが、実機で以下を確認してください。
  - 設定ウィンドウがメニューバーの裏に隠れず最前面に表示されること
  - 「音声認識」タブでモデル未配置時にダウンロードボタンを押すと進捗バーが表示され、完了後に「配置済み」表示に切り替わること
  - 「ショートカット」タブでキーを再割当てた直後から、実際のPTT/トグル/キャンセルの挙動が新しいキーで動作すること
  - 「一般」タブのトグルでシステム設定 > 一般 > ログイン項目にVoicewriterが追加/削除されること(初回は承認待ちになる場合があります)
- 既知の非関連事象: whisper.cppのMetalバックエンド(`ggml_metal_rsets_free`)が、アプリ終了(`NSApplication terminate:`)時の静的破棄処理中に稀に`abort()`することがある(本実装の変更以前から存在するwhisper.cpp側の既知の挙動で、今回の設定画面追加とは無関係)。今回の検証では`kill -TERM`によるクリーンな終了では再現しませんでした。
- **実マイク環境での認識精度改善の効果は未確認**です。今回の調査・改善(ビームサーチ化・語彙ヒント・先頭無音トリム・VAD・AVAudioConverter品質設定)は`say`生成の合成音声フィクスチャでの回帰確認に留まり、報告された実際の誤認識(「ボイスライダー」「魅力」等の誤変換、類似フレーズの繰り返し)がこれらの変更で改善するかどうかは実機でのディクテーションで確認する必要があります。`defaults write dev.voicewriter.app debugSaveLastRecording -bool YES`で直近録音のWAVを保存できるので、誤認識が再発した場合はこのWAVを`swift run verify-whisper`に通して音質・パラメータ両面から追加調査してください。
- **VADの実マイク環境での効果も未確認**です。公式issue #1724(末尾無音でのハルシネーション)は今回作成した合成フィクスチャでは再現できず、VAD有無の差も句読点スタイル程度でした。実際にハルシネーションが再発するようであれば、`defaults write dev.voicewriter.app vadEnabled -bool YES`(要`scripts/download-vad-model.sh`)で有効化して効果を確認してください。
- **LLM整形の実マイク環境での効果は未確認**です。ベンチマーク(`scripts/benchmark-formatter.py`)はテキストを直接Ollamaへ送るテストケースでの比較であり、実際のディクテーション(whisper.cppの生出力)に対する効果は実機で確認する必要があります。実際に報告された誤認識例(「音声入力収入力後の後文字の精製」等)については、本実装(構造化出力+qwen3:14b)がテキストとして与えた場合に部分的な修正ができることを確認済みですが、完全な修正には至っていません(README「LLM整形パス」参照)。実機で誤認識が再発する場合は、設定画面「整形」タブでモデルを切り替えるか、タイムアウトを調整して比較してください。
- 設定画面「整形」タブの実機でのモデル一覧取得・選択・タイムアウト変更のUI操作(マウスクリック・ピッカー選択)は、上記「設定ウィンドウの実機操作」と同様の理由でUI自動操作による確認ができていません。アプリのログ(`OllamaFormatter`/`Coordinator`カテゴリ)経由でのプリロード成功・整形リクエスト成功は確認済みです(下記「動作確認済み事項」参照)。
- 上記「並行処理まわりの修正」で追加した以下の挙動は、実機での対話的な確認(実際のキー押下・Bluetoothデバイスの抜き差し・複数アプリ間でのフォーカス切り替えなど)を行っていません。
  - `.transcribing`中にEsc(キャンセル)を押すと、結果が挿入されずに破棄されること(メニューバー状態がidleに戻らない点に注意: `.transcribing`のままキャンセル待ち状態が続く想定通りの挙動か含め確認)
  - idle時にEscを押しても他アプリ側でEscが正常に機能する(グローバルホットキーとして奪われない)こと
  - 録音中に別アプリへフォーカスを切り替えてから文字起こしを終えると、自動挿入が中止されメニューバーに警告が出て、「最後の文字起こし結果をコピー」から結果を回収できること
  - 文字起こし中にPTT/トグルを操作するとビープ音が鳴ること
  - 5分以上録音し続けると自動的に文字起こしへ回ること(長時間録音の実機確認)
  - Bluetoothヘッドセット等の抜き差しで、フォーマット不正/コンバータ生成失敗が実際に発生した場合にメニューバー警告が出て録音状態が安全にidleへ戻ること(通常のデバイス切替では従来通り自動復旧する想定)
  - 設定画面でwhisper.cppモデル未配置からダウンロード完了、または再試行(失敗後の「再試行」ボタン)・ダウンロード中キャンセルの一連の操作
  - エンジン/言語切り替え(`DynamicTranscriptionEngine.reload()`)がバックグラウンドロードになったことで、切り替え中もUIが操作可能なままであること
- 2回目のCodex検証レビュー対応(上記「2回目のCodex検証レビュー対応」参照)で追加した以下の挙動は、実機での対話的な確認を行っていません。
  - **語尾欠落対策(指摘#3)**: Push-to-Talkを離した瞬間、または実際に発話し終えてすぐにトグル/キャンセルした場合に、100msの猶予(`AudioCaptureEngine.stopGraceInterval`)により語尾が欠落せず文字起こしされること。逆に、この猶予が録音停止の体感レスポンスを損なっていないこと。
  - **キャンセルキー録り直し(指摘#6)**: 設定画面の「ショートカット」タブでキャンセル(既定Esc)を別のキーに再割当てした直後、idle状態であれば新しいキーも(録音中/文字起こし中以外は)他アプリの操作を奪わず、録音中/文字起こし中は正しく新しいキーでキャンセルできること。
  - **起動時のEsc一時有効化対策(指摘#5)**: アプリ起動直後、録音を一切開始していない状態でEscキーが他アプリの操作(ダイアログのキャンセル等)を奪わないこと。
  - **5分上限と手動停止の競合(指摘#2)**: 5分の録音上限に達するタイミングとほぼ同時に手動でPTT/トグルを離した場合でも、文字起こし結果が正しく1回だけ得られ、空文字が挿入されたり結果が消えたりしないこと。
  - **構成変更復旧の失敗(指摘#4)**: 録音中にBluetoothヘッドセット等を抜き差しし、かつその直後にエンジン再起動そのものが失敗するような状況(通常のデバイス切替では起きにくい)で、メニューバー警告が出た上で次回の録音開始が正常に行えること。
