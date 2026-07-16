import Foundation

/// 汎用のFIFO直列化キュー。`enqueue`が呼ばれた順序で1つずつ`operation`を実行し、
/// 前の`operation`が完了するまで次を開始しない。
///
/// 連続音声入力パイプラインでの用途: whisper.cppの認識とOllamaの整形は同じUnified Memory/GPUを
/// 奪い合うため、`Coordinator`はジョブごとの「認識→整形」をひとまとまりの`operation`としてこの
/// キューに通し、J1(認識・整形)→J2(認識・整形)→…の順で完全に直列実行する(J1の整形とJ2の認識が
/// 入れ替わらないようにするため、ステージ単位ではなくジョブ単位でenqueueすること)。
///
/// `@MainActor`にしている理由: `enqueue`自体は`await`を含まない同期的な処理(前回のTaskを読み、
/// 新しいTaskを作って`tail`を更新するだけ)だが、呼び出し順序がそのままFIFO順になることを
/// 保証する必要がある。`Coordinator`は元々`@MainActor`であり、ジョブの生成(sequence採番)から
/// `enqueue`呼び出しまでを同一のMainActorコンテキスト上で行うことで、複数のジョブが並行して
/// 生成されても`enqueue`が呼ばれる順序(=sequence順)を確定させられる。
/// (Swift Actorの`enqueue`にして「呼ばれた順」に頼ると、複数の呼び出し元Taskがどの順で
/// アクターに到達するかはランタイムのスケジューリング次第で保証されないため、あえて
/// `@MainActor`のシリアルな呼び出しコンテキストに乗せている)
@MainActor
final class SerialFIFOQueue {
    private var tail: Task<Void, Never>?

    /// `operation`を、これまでに`enqueue`された(=呼び出された)全ての`operation`が完了した後に
    /// 実行するようスケジュールする。戻り値の`Task`をawaitすると、実行順の到来を待って結果を得られる。
    /// このメソッド自体は同期的(awaitしない)なので、呼び出した順序がそのままキューの実行順になる。
    @discardableResult
    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> Task<T, Never> {
        let previousTail = tail
        let resultTask = Task<T, Never> {
            await previousTail?.value
            return await operation()
        }
        // 次のenqueue呼び出しが自分(resultTask)の完了を待てるよう、Voidに消去したTaskをtailへ積む。
        tail = Task {
            _ = await resultTask.value
        }
        return resultTask
    }
}
