// ViewController+EZKeepAwake.m
// Prevents screen sleep during long completions and survives short backgrounding.

#import "ViewController+EZKeepAwake.h"
#import "helpers.h"
#import <objc/runtime.h>

static const void *kEZKA_Count      = &kEZKA_Count;
static const void *kEZKA_BGTask     = &kEZKA_BGTask;
static const void *kEZKA_Timer      = &kEZKA_Timer;
static NSString *const kEZKA_Tag    = @"EZKeepAwake";

static inline NSInteger ezka_getCount(ViewController *vc) {
    NSNumber *n = objc_getAssociatedObject(vc, kEZKA_Count);
    return n ? n.integerValue : 0;
}
static inline void ezka_setCount(ViewController *vc, NSInteger c) {
    objc_setAssociatedObject(vc, kEZKA_Count, @(c), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#if TARGET_OS_IOS
static inline UIBackgroundTaskIdentifier ezka_getBG(ViewController *vc) {
    NSNumber *n = objc_getAssociatedObject(vc, kEZKA_BGTask);
    return n ? (UIBackgroundTaskIdentifier)n.unsignedIntegerValue : UIBackgroundTaskInvalid;
}
static inline void ezka_setBG(ViewController *vc, UIBackgroundTaskIdentifier t) {
    objc_setAssociatedObject(vc, kEZKA_BGTask, @(t), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
#endif

@implementation ViewController (EZKeepAwake)

- (void)ezcui_beginLongOperation:(NSString *)reason {
    @synchronized (self) {
        NSInteger c = ezka_getCount(self) + 1;
        ezka_setCount(self, c);

#if TARGET_OS_IOS
        if (c == 1) {
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            EZLogf(EZLogLevelInfo, kEZKA_Tag, @"Idle timer disabled (%@)", reason ?: @"op");

            UIBackgroundTaskIdentifier bg = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
                EZLog(EZLogLevelWarning, kEZKA_Tag, @"BG task expired; ending");
#if TARGET_OS_IOS
                UIBackgroundTaskIdentifier cur = ezka_getBG(self);
                if (cur != UIBackgroundTaskInvalid) {
                    [[UIApplication sharedApplication] endBackgroundTask:cur];
                    ezka_setBG(self, UIBackgroundTaskInvalid);
                }
#endif
            }];
            ezka_setBG(self, bg);

            // Failsafe: auto-end after 8 minutes if caller forgets
            NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:480.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
                EZLog(EZLogLevelWarning, kEZKA_Tag, @"Failsafe timer fired; forcing end");
                [self ezcui_endLongOperation];
            }];
            objc_setAssociatedObject(self, kEZKA_Timer, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
#else
        (void)reason;
#endif
    }
}

- (void)ezcui_endLongOperation {
    @synchronized (self) {
        NSInteger c = MAX(0, ezka_getCount(self) - 1);
        ezka_setCount(self, c);

#if TARGET_OS_IOS
        if (c == 0) {
            [UIApplication sharedApplication].idleTimerDisabled = NO;
            EZLog(EZLogLevelInfo, kEZKA_Tag, @"Idle timer re-enabled");

            NSTimer *t = objc_getAssociatedObject(self, kEZKA_Timer);
            if (t) { [t invalidate]; objc_setAssociatedObject(self, kEZKA_Timer, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }

            UIBackgroundTaskIdentifier bg = ezka_getBG(self);
            if (bg != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:bg];
                ezka_setBG(self, UIBackgroundTaskInvalid);
                EZLog(EZLogLevelInfo, kEZKA_Tag, @"Background task ended");
            }
        }
#endif
    }
}

@end