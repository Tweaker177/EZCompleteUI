#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Best-effort client error reporting to the report-app-error edge
/// function (rows land in public.ez_app_errors, deduped by error
/// signature server-side). Fire-and-forget: no completion, no retry,
/// and a failed report is dropped silently — reporting must never
/// surface a second failure on top of the one being reported. Only
/// the error's own description is sent: no chat content, no prompts,
/// no user content of any kind.
@interface EZAppErrorReporter : NSObject

+ (void)reportSource:(NSString *)source code:(NSString *)code message:(nullable NSString *)message;

@end

NS_ASSUME_NONNULL_END
