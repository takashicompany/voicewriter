import Foundation
import Speech

/// `SpeechAnalyzerSession`(実際の認識)と`SpeechModelProvisioner`(モデル資産の状態確認・
/// ダウンロード)の両方で同一設定の`SpeechTranscriber`を使うための共通ファクトリ。
/// `AssetInventory`はこの設定(locale/オプション)単位でモデル資産の要否を判定するため、
/// 実際に認識で使うインスタンスと異なる設定で状態確認してしまうと不整合が生じうる。
/// `SpeechModelProvisioner`は本ファクトリの`makePreviewTranscriber`/`makeFinalTranscriber`両方を
/// まとめて`AssetInventory.status(forModules:)`へ渡すことで、実際に`SpeechAnalyzerSession`が
/// 使う構成(2モジュール、設定次第で1モジュール)全体をカバーしている。
///
/// ## 2モジュール構成(プレビュー用/確定用)
///
/// 単一の`SpeechTranscriber`で発話中のライブプレビュー(volatile表示)と挿入用の確定テキストの
/// 両方を賄っていたところ、A/B検証で`.fastResults`が最終(isFinal)テキストの精度にも影響することが
/// 判明した(発話速度が速いフィクスチャ`sample-ja-fast-16k.wav`で、末尾数文字が欠落する再現性のある
/// 差異を確認)。Appleの`SpeechAnalyzer.volatileRange`ドキュメント
/// (https://developer.apple.com/documentation/speech/speechanalyzer/volatilerange )が
/// volatile処理と最終処理に別モジュールを使う構成に言及していることも踏まえ、役割ごとに
/// 別インスタンスの`SpeechTranscriber`を用意する2モジュール構成に切り替えた:
///
/// - **プレビュー用**(`makePreviewTranscriber`): `reportingOptions: [.volatileResults, .fastResults]`。
///   低遅延を優先し、発話中のライブ表示イベント専用に使う。この結果(`isFinal`な結果を含む)は
///   表示にのみ用い、挿入テキストには一切使わない。
/// - **確定用**(`makeFinalTranscriber`): `reportingOptions: []`(空集合)。`.fastResults`は
///   低遅延化とひきかえに精度を犠牲にしうるため含めない。このモジュールの`results`は
///   `isFinal`な結果のみを消費する用途であり、発話中の逐次(volatile)表示は不要なため、
///   `.volatileResults`も含めない最小構成とする。`SpeechAnalyzerSession.finish()`が返す
///   最終テキストはこちらの`results`からのみ集計する。
///
/// ## 実装方式: 2つの独立した`SpeechAnalyzer`(1アナライザー1モジュールを2組)
///
/// Appleの`SpeechAnalyzer.volatileRange`ドキュメントは(volatile処理用/最終処理用の)2モジュールを
/// 同一の`SpeechAnalyzer`に同居させる構成を示唆しており、`SpeechAnalyzer(modules:)`が
/// `[any SpeechModule]`の配列を受け取れることからAPI的にも可能である。しかし実機検証
/// (macOS 26.4.1、`SpeechAnalyzerEngineIntegrationTests.
/// testVolatileUpdateArrivesWhileStillFeedingBeforeFinishIsCalled`)の結果、この端末では
/// **確定用モジュール(`.fastResults`なし)を同一アナライザーに同居させるだけで、プレビュー用
/// モジュール(`.fastResults`あり)側の逐次(volatile)配信までもが録音終了後のバースト配信に
/// 劣化してしまい**、ライブプレビューが一切表示されない元の実機バグが再発することを確認した
/// (確定用モジュールのreportingOptionsを`[.volatileResults, .fastResults]`に揃えると再発しないため、
/// 「確定用モジュールが`.fastResults`を持たないこと」自体がアナライザー全体の配信ペースを
/// 引き下げていると判断した)。そのため単一アナライザー2モジュール構成は採用せず、
/// **各モジュールを独立した`SpeechAnalyzer`に載せ、変換済みの同一音声バッファを複製して両方へ
/// fan-outする**構成にしている(`SpeechAnalyzerEngine`参照)。2アナライザー化によるCPU/メモリの
/// 増分は同ファイルの統合テスト(`testResourceComparisonBetweenTwoModuleAndFinalOnlyConfigurations`)
/// で概況を確認しており、既定で許容できる範囲だった。設定でライブプレビュー
/// (`Settings.streamingPreviewEnabled`)がOFFの場合は、プレビュー用モジュール/アナライザーを
/// 生成せず確定用のみの1モジュール構成にフォールバックし、CPU/メモリ負荷をさらに抑える。
///
/// 一次情報: `Speech.swiftinterface`(`/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk/
/// System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/
/// arm64e-apple-macos.swiftinterface`)の`SpeechTranscriber.ReportingOption`/`Preset`/
/// `SpeechAnalyzer.init(modules:options:)`定義。
@available(macOS 26.0, *)
enum SpeechTranscriberFactory {
    /// プレビュー(ライブ表示)専用モジュール。`.fastResults`により、録音中も継続的にvolatile結果が
    /// 届く(この端末で`.volatileResults`単独では録音中に`.update`が一切発行されない実機バグの
    /// ワークアラウンド)。この結果は表示にのみ使い、挿入テキストには使わない。
    static func makePreviewTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    /// 確定(最終)テキスト専用モジュール。`.fastResults`を含めないことで、挿入される最終テキストへの
    /// 精度影響(発話速度が速い場合の末尾欠落)を避ける。`isFinal`な結果のみを消費する用途のため、
    /// `.volatileResults`も含めない最小構成にしている。
    static func makeFinalTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }
}
