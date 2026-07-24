// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Voicewriter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Voicewriter", targets: ["Voicewriter"]),
        .executable(name: "verify-whisper", targets: ["VerifyWhisper"]),
        .executable(name: "verify-speech-analyzer", targets: ["VerifySpeechAnalyzer"])
    ],
    dependencies: [
        // 2026-07-24: リモート版(2.4.0, revision 1aef855)をvendor/KeyboardShortcutsへ取り込み、
        // ローカルpathパッケージに切り替えた。「設定→ショートカット」タブを開くと配布先で
        // クラッシュする不具合(Bundle.moduleの解決失敗によるfatalError)を修正するための
        // 最小パッチをUtilities.swiftに当てている。詳細はvendor/KeyboardShortcuts/Sources/
        // KeyboardShortcuts/Utilities.swiftのコメント参照。
        .package(path: "vendor/KeyboardShortcuts")
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            path: "vendor/whisper.xcframework"
        ),
        .executableTarget(
            name: "Voicewriter",
            dependencies: [
                "KeyboardShortcuts",
                "whisper"
            ],
            path: "Sources/Voicewriter",
            linkerSettings: [
                // whisper.xcframeworkはdynamic framework。.appバンドル化した際に
                // Contents/Frameworks に配置する前提でrpathを通す(scripts/build-app.sh参照)。
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        // whisper.cpp統合の検証用スタンドアロンCLI。
        // 使い方: swift run verify-whisper <wav-path> [model-path] [language]
        .executableTarget(
            name: "VerifyWhisper",
            dependencies: [
                "whisper"
            ],
            path: "Sources/VerifyWhisper"
        ),
        // Apple SpeechAnalyzer/SpeechTranscriber(macOS 26+)統合の検証用スタンドアロンCLI。
        // 使い方: swift run verify-speech-analyzer <wav-path> [locale-identifier]
        // macOS 26未満のビルド環境でもコンパイルできるよう、API呼び出しはすべて
        // #available(macOS 26, *)でガードしている(Package全体の最低ターゲットはmacOS 14のまま)。
        .executableTarget(
            name: "VerifySpeechAnalyzer",
            path: "Sources/VerifySpeechAnalyzer"
        ),
        // Codexレビューで指摘された競合修正(リングバッファのロック境界、入力フォーマット検証、
        // ModelDownloaderの状態遷移)の回帰テスト。AVAudioEngine自体はハードウェア依存のため対象外。
        .testTarget(
            name: "VoicewriterTests",
            dependencies: ["Voicewriter"],
            path: "Tests/VoicewriterTests"
        )
    ]
)
