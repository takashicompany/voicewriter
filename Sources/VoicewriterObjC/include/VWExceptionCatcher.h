#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// `VWCatchException`が生成する`NSError`のドメイン。
extern NSString *const VWExceptionCatcherErrorDomain;

/// 捕捉した`NSException`の`name`(`NSError.userInfo`のキー)。
extern NSString *const VWExceptionCatcherNameKey;
/// 捕捉した`NSException`の`reason`(`NSError.userInfo`のキー)。
extern NSString *const VWExceptionCatcherReasonKey;
/// 捕捉した`NSException`の`callStackSymbols`(`NSError.userInfo`のキー)。
extern NSString *const VWExceptionCatcherCallStackKey;

/// SwiftからはObjCの`NSException`をcatchできないため、`@try/@catch`で囲んだブロック実行を
/// Swift側へ提供する薄いヘルパー。
///
/// 主用途は`AVAudioNode.installTap(onBus:bufferSize:format:block:)`。AVFoundationは
/// 内部の事前条件(例: `format.sampleRate == inputHWFormat.sampleRate`)を満たさない場合
/// `NSException`をraiseする仕様で、Swift側ではどうしても捕捉できずプロセスがabortしてしまう。
/// オーディオデバイスの構成変更直後は、AVAudioEngineが公開するノードのフォーマットと
/// 実ハードウェアのフォーマットが一時的に食い違うことがあり、事前検証だけでは防ぎ切れない。
///
/// @param block 実行するブロック(non-escaping)。
/// @param error 非NULLかつ例外が発生した場合、`VWExceptionCatcherErrorDomain`の`NSError`が格納される。
/// @return ブロックが例外を投げずに完了した場合`YES`、`NSException`を捕捉した場合`NO`。
BOOL VWCatchException(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
