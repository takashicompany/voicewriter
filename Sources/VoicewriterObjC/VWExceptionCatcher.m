#import "VWExceptionCatcher.h"

NSString *const VWExceptionCatcherErrorDomain = @"dev.voicewriter.app.ObjCException";
NSString *const VWExceptionCatcherNameKey = @"VWExceptionName";
NSString *const VWExceptionCatcherReasonKey = @"VWExceptionReason";
NSString *const VWExceptionCatcherCallStackKey = @"VWExceptionCallStackSymbols";

BOOL VWCatchException(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary<NSString *, id> *info = [NSMutableDictionary dictionary];
            NSString *name = exception.name ?: @"NSException";
            NSString *reason = exception.reason ?: @"(no reason)";
            info[VWExceptionCatcherNameKey] = name;
            info[VWExceptionCatcherReasonKey] = reason;
            info[NSLocalizedDescriptionKey] = [NSString stringWithFormat:@"%@: %@", name, reason];
            NSArray<NSString *> *callStack = exception.callStackSymbols;
            if (callStack != nil) {
                info[VWExceptionCatcherCallStackKey] = callStack;
            }
            *error = [NSError errorWithDomain:VWExceptionCatcherErrorDomain code:1 userInfo:info];
        }
        return NO;
    }
}
