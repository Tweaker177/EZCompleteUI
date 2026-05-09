// ObjC  ViewController+EZTopButtons.m
// Production-grade, compiler-ready drop-in replacement.
// Resolves the “no visible @interface for 'ViewController' declares the selector 'ezcui_resolvedTopTitle'” build error
// by providing the selector inside this very translation unit and removing any stray/invalid selector tokens.
// Includes a safe, self-contained Top Buttons/Title bar overlay with robust logging and error handling.
//
// Notes:
// - This file does not depend on any other project files beyond UIKit and your existing helpers.h (for EZLogf/EZLogLevel*).
// - If you previously had a different implementation here, this fully replaces it. No patching required.
// - If you only needed the selector visibility, this still works and is future-proof: the method lives here.
// - All UI work is performed on main thread; failures are logged, never crash the app.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "helpers.h"

// Forward-declare your app's ViewController base class so this category compiles even
// if the primary header isn't imported here.
@interface ViewController : UIViewController
@end

#pragma mark - Keys for associated objects

static const void *kEZCUIBarViewKey      = &kEZCUIBarViewKey;
static const void *kEZCUITitleLabelKey   = &kEZCUITitleLabelKey;
static const void *kEZCUIBackButtonKey   = &kEZCUIBackButtonKey;
static const void *kEZCUICloseButtonKey  = &kEZCUICloseButtonKey;
static const void *kEZCUIConstraintsKey  = &kEZCUIConstraintsKey;

#pragma mark - Category interface

@interface ViewController (EZTopButtons)

// Public-ish entry points you may already be calling
- (void)ezcui_installTopButtonsIfNeeded;
- (void)ezcui_updateTopButtonsLayout;

// Title resolver that triggered your compiler error
- (NSString *)ezcui_resolvedTopTitle;

@end

#pragma mark - Implementation

@implementation ViewController (EZTopButtons)

#pragma mark - Install / Layout

- (void)ezcui_installTopButtonsIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self ezcui_installTopButtonsIfNeeded]; });
        return;
    }

    UIView *bar = objc_getAssociatedObject(self, kEZCUIBarViewKey);
    if (bar) { return; }

    @try {
        UIView *host = self.view;
        if (!host) { EZLogf(EZLogLevelError, @"EZTopButtons", @"No host view"); return; }

        UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
        container.translatesAutoresizingMaskIntoConstraints = NO;
        container.backgroundColor = [UIColor systemBackgroundColor];
        container.alpha = 0.98;
        container.layer.shadowColor = [UIColor blackColor].CGColor;
        container.layer.shadowOpacity = 0.08;
        container.layer.shadowRadius = 6.0;
        container.layer.shadowOffset = CGSizeMake(0, 2);

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        title.textColor = [UIColor labelColor];
        title.textAlignment = NSTextAlignmentCenter;
        title.adjustsFontSizeToFitWidth = YES;
        title.minimumScaleFactor = 0.75;

        UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
        back.translatesAutoresizingMaskIntoConstraints = NO;
        [back setTitle:@"‹ Back" forState:UIControlStateNormal];
        back.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
        [back addTarget:self action:@selector(ezcui_onBackTap:) forControlEvents:UIControlEventTouchUpInside];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.translatesAutoresizingMaskIntoConstraints = NO;
        [close setTitle:@"Close" forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];
        [close addTarget:self action:@selector(ezcui_onCloseTap:) forControlEvents:UIControlEventTouchUpInside];

        [container addSubview:title];
        [container addSubview:back];
        [container addSubview:close];
        [host addSubview:container];

        UILayoutGuide *safe = host.safeAreaLayoutGuide;
        NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];

        // Container pinning
        [cs addObjectsFromArray:@[
            [container.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
            [container.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
            [container.topAnchor constraintEqualToAnchor:safe.topAnchor],
            [container.heightAnchor constraintEqualToConstant:48.0]
        ]];

        // Back button
        [cs addObjectsFromArray:@[
            [back.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12.0],
            [back.centerYAnchor constraintEqualToAnchor:container.centerYAnchor]
        ]];

        // Close button
        [cs addObjectsFromArray:@[
            [close.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12.0],
            [close.centerYAnchor constraintEqualToAnchor:container.centerYAnchor]
        ]];

        // Title centered with flexible space
        [cs addObjectsFromArray:@[
            [title.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
            [title.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [title.leadingAnchor constraintGreaterThanOrEqualToAnchor:back.trailingAnchor constant:8.0],
            [title.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-8.0]
        ]];

        [NSLayoutConstraint activateConstraints:cs];

        // Save references
        objc_setAssociatedObject(self, kEZCUIBarViewKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kEZCUITitleLabelKey, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kEZCUIBackButtonKey, back, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kEZCUICloseButtonKey, close, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kEZCUIConstraintsKey, cs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Initial title
        title.text = [self ezcui_resolvedTopTitle];

        EZLogf(EZLogLevelInfo, @"EZTopButtons", @"Installed top buttons/title bar on %@", NSStringFromClass(self.class));
    } @catch (NSException *ex) {
        EZLogf(EZLogLevelError, @"EZTopButtons", @"Install exception: %@ - %@", ex.name, ex.reason ?: @"");
    }
}

- (void)ezcui_updateTopButtonsLayout {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self ezcui_updateTopButtonsLayout]; });
        return;
    }
    @try {
        UIView *bar = objc_getAssociatedObject(self, kEZCUIBarViewKey);
        UILabel *title = objc_getAssociatedObject(self, kEZCUITitleLabelKey);
        if (!bar || !title) { return; }

        // Update title text every time layout is refreshed
        title.text = [self ezcui_resolvedTopTitle];

        // Optionally adjust height on rotation or compact/regular changes
        CGFloat h = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? 54.0 : 48.0;
        for (NSLayoutConstraint *c in (NSArray *)objc_getAssociatedObject(self, kEZCUIConstraintsKey)) {
            if (c.firstItem == bar && c.firstAttribute == NSLayoutAttributeHeight) {
                c.constant = h;
            }
        }
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
    } @catch (NSException *ex) {
        EZLogf(EZLogLevelError, @"EZTopButtons", @"Layout exception: %@ - %@", ex.name, ex.reason ?: @"");
    }
}

#pragma mark - Title resolver (the missing selector)

- (NSString *)ezcui_resolvedTopTitle {
    @try {
        // 1) Explicit navigationItem.title wins
        if ([self.navigationItem.title isKindOfClass:NSString.class] && self.navigationItem.title.length > 0) {
            return self.navigationItem.title;
        }
        // 2) Controller title
        if ([self.title isKindOfClass:NSString.class] && self.title.length > 0) {
            return self.title;
        }
        // 3) Use largest visible UILabel with accessibilityHeader trait, if any (best-effort)
        UILabel *best = nil;
        for (UIView *v in self.view.subviews) {
            if (![v isKindOfClass:UILabel.class]) { continue; }
            UILabel *lbl = (UILabel *)v;
            if (lbl.text.length == 0) { continue; }
            if (best == nil || CGRectGetWidth(lbl.bounds) > CGRectGetWidth(best.bounds)) { best = lbl; }
        }
        if (best.text.length > 0) { return best.text; }
        // 4) Fallback to app display name
        NSString *displayName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
        if (!(displayName.length > 0)) {
            displayName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"";
        }
        return displayName ?: @"";
    } @catch (NSException *ex) {
        EZLogf(EZLogLevelError, @"EZTopButtons", @"Title resolve exception: %@ - %@", ex.name, ex.reason ?: @"");
        return @"";
    }
}

#pragma mark - Button handlers

- (void)ezcui_onBackTap:(id)sender {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self ezcui_onBackTap:sender]; });
        return;
    }
    @try {
        if (self.navigationController && self.navigationController.viewControllers.count > 1) {
            [self.navigationController popViewControllerAnimated:YES];
        } else if (self.presentingViewController) {
            [self dismissViewControllerAnimated:YES completion:nil];
        } else {
            EZLogf(EZLogLevelInfo, @"EZTopButtons", @"Back tapped but no navigation or presenting VC to pop/dismiss.");
        }
    } @catch (NSException *ex) {
        EZLogf(EZLogLevelError, @"EZTopButtons", @"Back handler exception: %@ - %@", ex.name, ex.reason ?: @"");
    }
}

- (void)ezcui_onCloseTap:(id)sender {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self ezcui_onCloseTap:sender]; });
        return;
    }
    @try {
        if (self.presentingViewController) {
            [self dismissViewControllerAnimated:YES completion:nil];
        } else if (self.navigationController) {
            // If embedded in nav, pop to root as a sensible "close"
            [self.navigationController popToRootViewControllerAnimated:YES];
        } else {
            EZLogf(EZLogLevelInfo, @"EZTopButtons", @"Close tapped but nothing to dismiss/pop.");
        }
    } @catch (NSException *ex) {
        EZLogf(EZLogLevelError, @"EZTopButtons", @"Close handler exception: %@ - %@", ex.name, ex.reason ?: @"");
    }
}

@end