// ViewController+EZKeepAwake.h
// Keeps the screen on and holds a BG task while a long operation is active.

#import "ViewController.h"

@interface ViewController (EZKeepAwake)
- (void)ezcui_beginLongOperation:(NSString *)reason; // call when you start a completion
- (void)ezcui_endLongOperation;                       // call in all completion/failure paths
@end