// ViewController+EZKeepAwake.h
// Keeps the screen on and holds a BG task while a long operation is active.

#import "ViewController.h"

/// Shared reference-counted wake lock for long work owned outside ViewController
/// (for example, Gallery video rendering).
FOUNDATION_EXPORT void EZKeepDeviceAwakeBegin(NSString * _Nullable reason);
FOUNDATION_EXPORT void EZKeepDeviceAwakeEnd(void);

@interface ViewController (EZKeepAwake)
- (void)ezcui_beginLongOperation:(NSString * _Nullable)reason; // call when you start a completion
- (void)ezcui_endLongOperation;                       // call in all completion/failure paths
@end
