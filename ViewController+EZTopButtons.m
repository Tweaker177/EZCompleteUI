// ObjC  ViewController+EZTopButtons.m
// Drop-in replacement (compiler-ready).
// - Installs in-carousel title as a subview of the detected carousel container.
// - Respects existing ezcui_resolvedTopTitle if implemented elsewhere (forward-declared).
// - Adjusts only the carousel's scroll insets (idempotent; stores original insets).
// - Uses EZLogf(...) for proper logging (production-grade).
// - Defensive: main-thread checks, exception handling, no duplicate selector definitions.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "helpers.h"
#import "ViewController+EZKeepAwake.h"



// Forward declare the resolver only (no implementation here) to avoid duplicate symbol warnings.
@interface ViewController (EZTitleResolverForward)
- (NSString *)ezcui_resolvedTopTitle;
@end

#pragma mark - Associated keys

static const void *kEZTB_TitleLabelKey          = &kEZTB_TitleLabelKey;
static const void *kEZTB_TitleBackdropKey       = &kEZTB_TitleBackdropKey;
static const void *kEZTB_TitleContainerKey      = &kEZTB_TitleContainerKey;
static const void *kEZTB_DidAdjustInsetsKey     = &kEZTB_DidAdjustInsetsKey;
static const void *kEZTB_StoredInsetsKey        = &kEZTB_StoredInsetsKey;
static const void *kEZTB_InstalledOnceKey       = &kEZTB_InstalledOnceKey;

#pragma mark - Category

@interface ViewController (EZTopButtons)
- (void)ezcui_installTopButtonsIfNeeded;
- (void)ezcui_updateTopButtonsLayout;
- (void)ezcui_onBackTap:(id)sender;
- (void)ezcui_onCloseTap:(id)sender;
@end

@implementation ViewController (EZTopButtons)

#pragma mark - Public entry points

- (void)ezcui_installTopButtonsIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self ezcui_installTopButtonsIfNeeded]; });
        return;
    }
    [self ezcui_installOrUpdateTitleInCarousel:YES];
}

- (void)ezcui_updateTopButtonsLayout {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self ezcui_updateTopButtonsLayout]; });
        return;
    }
    [self ezcui_installOrUpdateTitleInCarousel:NO];
}

#pragma mark - Core install/update

- (void)ezcui_installOrUpdateTitleInCarousel:(BOOL)firstTime {
    @try {
        UIView *container = objc_getAssociatedObject(self, kEZTB_TitleContainerKey);
        if (!container || !container.window) {
            container = [self eztb_findCarouselContainerIn:self.view];
            if (!container) {
                static BOOL loggedNoContainerOnce = NO;
                if (!loggedNoContainerOnce) {
                    EZLogf(EZLogLevelInfo, @"EZTopButtons", @"No carousel-like container detected for %@", NSStringFromClass(self.class));
                    loggedNoContainerOnce = YES;
                }
                return;
            }
            objc_setAssociatedObject(self, kEZTB_TitleContainerKey, container, OBJC_ASSOCIATION_ASSIGN);
        }

        // Resolve title using existing resolver if present
        NSString *resolved = @"";
        if ([self respondsToSelector:@selector(ezcui_resolvedTopTitle)]) {
            @try {
                resolved = [self ezcui_resolvedTopTitle] ?: @"";
            } @catch (NSException *ex) {
                EZLogf(EZLogLevelError, @"EZTopButtons", @"ezcui_resolvedTopTitle threw: %@ - %@", ex.name, ex.reason ?: @"");
                resolved = @"";
            }
        } else {
            NSString *nav = self.navigationItem.title;
            resolved = (nav.length ? nav : (self.title.length ? self.title : @""));
        }

        UILabel *title = objc_getAssociatedObject(self, kEZTB_TitleLabelKey);
        BOOL installedOnce = [objc_getAssociatedObject(self, kEZTB_InstalledOnceKey) boolValue];

        if (!title) {
            // Create title label
            UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectZero];
            lbl.translatesAutoresizingMaskIntoConstraints = NO;
            CGFloat baseSize = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? 24.0 : 20.0;
            lbl.font = [UIFont systemFontOfSize:baseSize weight:UIFontWeightSemibold];
            lbl.textColor = [UIColor labelColor];
            lbl.textAlignment = NSTextAlignmentCenter;
            lbl.adjustsFontSizeToFitWidth = YES;
            lbl.minimumScaleFactor = 0.75;
            lbl.text = resolved ?: @"";

            // Backdrop for readability
            UIVisualEffectView *bg = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
            bg.translatesAutoresizingMaskIntoConstraints = NO;
            bg.alpha = 0.88;
            bg.clipsToBounds = YES;
            bg.layer.cornerRadius = 12.0;

            [container addSubview:bg];
            [container addSubview:lbl];

            const CGFloat topPad = 8.0;
            const CGFloat sidePad = 16.0;
            const CGFloat height = 44.0;

            NSArray<NSLayoutConstraint *> *constraints = @[
                // Backdrop
                [bg.topAnchor constraintEqualToAnchor:container.topAnchor constant:topPad],
                [bg.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:sidePad],
                [bg.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-sidePad],
                [bg.heightAnchor constraintEqualToConstant:height],
                // Title centered in backdrop
                [lbl.centerXAnchor constraintEqualToAnchor:bg.centerXAnchor],
                [lbl.centerYAnchor constraintEqualToAnchor:bg.centerYAnchor],
                [lbl.leadingAnchor constraintGreaterThanOrEqualToAnchor:bg.leadingAnchor constant:12.0],
                [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:bg.trailingAnchor constant:-12.0],
            ];
            [NSLayoutConstraint activateConstraints:constraints];

            objc_setAssociatedObject(self, kEZTB_TitleBackdropKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kEZTB_TitleLabelKey, lbl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kEZTB_InstalledOnceKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            // If the container scrolls, push its content down so the title never overlaps cells/pages
            [self eztb_adjustInsetsIfNeededForContainer:container desiredTopExtra:(height + topPad + 4.0)];

            EZLogf(EZLogLevelInfo, @"EZTopButtons", @"Installed in-carousel title into %@ for %@", NSStringFromClass(container.class), NSStringFromClass(self.class));
        } else {
            // Update existing title text if changed
            if (resolved.length && ![resolved isEqualToString:title.text]) {
                title.text = resolved;
            }
            // Ensure insets remain correct on rotation/size change
            if (installedOnce) {
                const CGFloat height = 44.0;
                const CGFloat topPad = 8.0;
                [self eztb_adjustInsetsIfNeededForContainer:container desiredTopExtra:(height + topPad + 4.0)];
            }
        }
    } @catch (NSException *ex) {
        EZLogf(EZLogLevelError, @"EZTopButtons", @"Install/update exception: %@ - %@", ex.name, ex.reason ?: @"");
    }
}

#pragma mark - Insets for scrollable containers

- (void)eztb_adjustInsetsIfNeededForContainer:(UIView *)container desiredTopExtra:(CGFloat)extraTop {
    if ([container isKindOfClass:UIScrollView.class]) {
        UIScrollView *sv = (UIScrollView *)container;

        BOOL alreadyAdjusted = [objc_getAssociatedObject(self, kEZTB_DidAdjustInsetsKey) boolValue];
        if (!alreadyAdjusted) {
            // Store the original insets exactly once
            NSValue *store = [NSValue valueWithUIEdgeInsets:sv.contentInset];
            objc_setAssociatedObject(self, kEZTB_StoredInsetsKey, store, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kEZTB_DidAdjustInsetsKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        NSValue *stored = objc_getAssociatedObject(self, kEZTB_StoredInsetsKey);
        UIEdgeInsets base = stored ? [stored UIEdgeInsetsValue] : sv.contentInset;
        UIEdgeInsets newInsets = base;
        newInsets.top = base.top + extraTop;
        if (!UIEdgeInsetsEqualToEdgeInsets(sv.contentInset, newInsets)) {
            sv.contentInset = newInsets;
            sv.scrollIndicatorInsets = newInsets;
            EZLogf(EZLogLevelInfo, @"EZTopButtons", @"Adjusted contentInset.top to %.1f for container %@", newInsets.top, NSStringFromClass(container.class));
        }
    }
}

#pragma mark - Container detection

- (UIView *)eztb_findCarouselContainerIn:(UIView *)root {
    if (!root) return nil;

    UIView *fallback = nil;
    CGFloat fallbackArea = 0.0;

    // Iterative DFS using a stack avoids recursive block capture / retain-cycle warnings.
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    [stack addObject:root];

    while (stack.count > 0) {
        UIView *node = stack.lastObject;
        [stack removeLastObject];

        for (UIView *v in node.subviews) {
            NSString *clsName = NSStringFromClass(v.class);
            BOOL nameLooksCarousel = ([clsName rangeOfString:@"Carousel" options:NSCaseInsensitiveSearch].location != NSNotFound);
            if (nameLooksCarousel) {
                return v; // highest priority match
            }

            if ([v isKindOfClass:[UICollectionView class]]) {
                UICollectionView *cv = (UICollectionView *)v;
                if (cv.isPagingEnabled) {
                    return v; // paging collection view is a strong match
                }
                CGFloat area = CGRectGetWidth(v.bounds) * CGRectGetHeight(v.bounds);
                if (area > fallbackArea) { fallbackArea = area; fallback = v; }
            } else if ([v isKindOfClass:[UIScrollView class]]) {
                UIScrollView *sv = (UIScrollView *)v;
                if (sv.pagingEnabled) {
                    return v; // paging scroll view is a strong match
                }
                CGFloat area = CGRectGetWidth(v.bounds) * CGRectGetHeight(v.bounds);
                if (area > fallbackArea) { fallbackArea = area; fallback = v; }
            }

            // push child for later processing
            [stack addObject:v];
        }
    }

    return fallback;
}
#pragma mark - Button handlers (kept for compatibility)

- (void)ezcui_onBackTap:(id)sender {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self ezcui_onBackTap:sender]; }); return; }
    @try {
        if (self.navigationController && self.navigationController.viewControllers.count > 1) {
            [self.navigationController popViewControllerAnimated:YES];
        } else if (self.presentingViewController) {
            [self dismissViewControllerAnimated:YES completion:nil];
        } else {
            EZLogf(EZLogLevelInfo, @"EZTopButtons", @"Back tapped but nothing to pop/dismiss.");
        }
    } @catch (NSException *ex) {
        EZLogf(EZLogLevelError, @"EZTopButtons", @"Back handler exception: %@ - %@", ex.name, ex.reason ?: @"");
    }
}

- (void)ezcui_onCloseTap:(id)sender {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self ezcui_onCloseTap:sender]; }); return; }
    @try {
        if (self.presentingViewController) {
            [self dismissViewControllerAnimated:YES completion:nil];
        } else if (self.navigationController) {
            [self.navigationController popToRootViewControllerAnimated:YES];
        } else {
            EZLogf(EZLogLevelInfo, @"EZTopButtons", @"Close tapped but nothing to dismiss/pop.");
        }
    } @catch (NSException *ex) {
        EZLogf(EZLogLevelError, @"EZTopButtons", @"Close handler exception: %@ - %@", ex.name, ex.reason ?: @"");
    }
}

@end
