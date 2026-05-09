// Objective-C  ViewController+EZTitleResolver.m
// Adds a production-safe implementation of `-ezcui_resolvedTopTitle` to ViewController.
// Drop this file into your target. No other files need to be edited.

#import <UIKit/UIKit.h>
#import "helpers.h"

// Forward-declare your app's ViewController base class if not globally visible.
// If "ViewController" is in Swift or another module, ensure it's exported to ObjC.
@interface ViewController : UIViewController
@end

@interface ViewController (EZTitleResolver)
- (NSString *)ezcui_resolvedTopTitle;
@end

@implementation ViewController (EZTitleResolver)

- (NSString *)ezcui_resolvedTopTitle {
    @try {
        // 1) Prefer a custom title getter if your app defines one (optional hook)
        // Suppress "may cause leak because selector is unknown" by checking first.
        SEL customSel = NSSelectorFromString(@"customTopTitle");
        if ([self respondsToSelector:customSel]) {
            // id<NSObject> to avoid ARC warnings; cast result to NSString safely.
            IMP imp = [self methodForSelector:customSel];
            NSString* (*func)(id, SEL) = (void *)imp;
            NSString *custom = func(self, customSel);
            if ([custom isKindOfClass:NSString.class] && custom.length) return custom;
        }

        // 2) Navigation item title
        NSString *navTitle = self.navigationItem.title;
        if ([navTitle isKindOfClass:NSString.class] && navTitle.length) return navTitle;

        // 3) Controller title
        NSString *vcTitle = self.title;
        if ([vcTitle isKindOfClass:NSString.class] && vcTitle.length) return vcTitle;

        // 4) Fallback: app display name or bundle name
        NSString *displayName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
        if (![displayName isKindOfClass:NSString.class] || displayName.length == 0) {
            displayName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
        }
        if (![displayName isKindOfClass:NSString.class] || displayName.length == 0) {
            displayName = @"";
        }
        return displayName;
    } @catch (NSException *ex) {
        // Production-grade logging without interrupting UX
        EZLogf(EZLogLevelError, @"EZTopButtons", @"ezcui_resolvedTopTitle exception: %@\n%@", ex.name, ex.reason ?: @"");
        return @"";
    }
}

@end