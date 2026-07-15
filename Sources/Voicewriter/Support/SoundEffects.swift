import AppKit

/// 録音開始時・テキスト挿入完了時の控えめな効果音。`Settings.soundEffectsEnabled`がfalseの場合は何もしない。
///
/// 独自音源は追加せず、macOS標準のシステムサウンド(`NSSound(named:)`)から選定する。
///
/// 録音開始音("Tink")については、Amical(issue #122)で実際に報告された「通知音がマイク準備完了
/// より前に鳴り、録音の先頭にその音が混入する」問題を踏まえて対策を検討した。このアプリは
/// AlwaysOnモード(既定)ではマイクは常時起動済みで、`AudioCaptureEngine.startRecordingLocked()`が
/// プリロールをリングバッファから切り出すのは`Coordinator.state`が`.recording`に変わった直後
/// (=このメソッドが呼ばれるのとほぼ同時)であり、この切り出し自体は効果音の再生開始より先に
/// 完了する(効果音の再生には`NSSound.play()`呼び出し後もハードウェア出力までの遅延がある)。
/// そのため「プリロールへの混入」は発生しにくい。一方、効果音がスピーカーからマイクへ音響的に
/// 回り込み、録音開始直後の実ライブ音声(=まさに発話冒頭)に混入する可能性は原理的に残る
/// (再生タイミングをどうずらしても、マイクは常時収音しているため混入箇所が前後にずれるだけで、
/// 「プリロール窓+preroll秒数」より長い遅延を入れない限り根本的には解消しない。それだけの
/// 遅延を入れると録音開始のレイテンシが悪化し、発話冒頭を取りこぼすリスクの方が実害として大きい)。
/// よって、`AudioCaptureEngine`のタップ処理・タイミング不変条件には手を入れず、(1) 比較的短い
/// システムサウンド("Tink"、実測で約0.56秒)を選び、(2) 音量を控えめ(0.3)に絞る、という
/// 2点で実害を最小化する方針とした。これは混入の完全な防止ではなく被害軽減の判断であり、
/// 完全に避けたい場合は設定の「効果音を鳴らす」をOFFにし、HUD表示のみで録音開始を確認する
/// 運用が代替になる。挿入完了音("Pop")は録音終了後に鳴らすため、この混入問題とは無関係
/// (実測で約1.6秒とやや長いが、マイクは既に録音を終えているため影響しない)。
/// 詳細な判断根拠はREADMEおよび最終報告を参照。
@MainActor
enum SoundEffects {
    private static let recordingStartedSound = NSSound(named: "Tink")
    private static let insertionCompletedSound = NSSound(named: "Pop")

    /// 録音開始時に鳴らす。マイクへの回り込みの影響を抑えるため控えめな音量にしている。
    static func playRecordingStarted() {
        guard Settings.soundEffectsEnabled else { return }
        guard let sound = recordingStartedSound else { return }
        sound.volume = 0.3
        sound.stop()
        sound.play()
    }

    /// テキスト挿入完了時に鳴らす。
    static func playInsertionCompleted() {
        guard Settings.soundEffectsEnabled else { return }
        guard let sound = insertionCompletedSound else { return }
        sound.volume = 0.5
        sound.stop()
        sound.play()
    }
}
