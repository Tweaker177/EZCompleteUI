//
//  ViewController+SidewaysTopRow.m
//  EZCompleteUI
//

#import "ViewController+SidewaysTopRow.h"
#import "SidewaysScrollView.h"
#import <objc/runtime.h>

static const void *kTopContainerKey = &kTopContainerKey;
static const void *kSidewaysKey     = &kSidewaysKey;
static const void *kInstalledKey    = &kInstalledKey;

@implementation ViewController (SidewaysTopRow)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class c = [self class];

        SEL orig1 = @selector(viewDidLoad);
        SEL swiz1 = @selector(ez_viewDidLoad_swizzled);
        method_exchangeImplementations(class_getInstanceMethod(c, orig1),
                                       class_getInstanceMethod(c, swiz1));

        SEL orig2 = @selector(viewDidLayoutSubviews);
        SEL swiz2 = @selector(ez_viewDidLayoutSubviews_swizzled);
        method_exchangeImplementations(class_getInstanceMethod(c, orig2),
                                       class_getInstanceMethod(c, swiz2));
    });
}

- (void)ez_viewDidLoad_swizzled {
    // Call original
    [self ez_viewDidLoad_swizzled];

    // Defer installation to the next runloop to ensure chatTableView exists
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf ez_installSidewaysIfNeeded];
    });
}

- (void)ez_viewDidLayoutSubviews_swizzled {
    [self ez_viewDidLayoutSubviews_swizzled];

    UIView *header = objc_getAssociatedObject(self, kTopContainerKey);
    if (header && [self.chatTableView.tableHeaderView isEqual:header]) {
        CGFloat targetW = CGRectGetWidth(self.chatTableView.bounds);
        if (fabs(header.frame.size.width - targetW) > 0.5) {
            CGRect f = header.frame;
            f.size.width = targetW;
            header.frame = f;
            self.chatTableView.tableHeaderView = header; // force table to re-measure
        }
    }
}

#pragma mark - Install

- (void)ez_installSidewaysIfNeeded {
    NSNumber *installed = objc_getAssociatedObject(self, kInstalledKey);
    if (installed.boolValue) return;
    if (!self.chatTableView) return;

    // Build prototype buttons from known properties if present
    NSMutableArray<UIButton *> *protos = [NSMutableArray array];

    NSArray<NSString *> *names = @[
        @"modelButton", @"attachButton", @"settingsButton", @"clipboardButton",
        @"speakButton", @"clearButton", @"imageSettingsButton", @"dictateButton",
        @"webSearchButton", @"historyButton", @"addChatButton"
    ];
    for (NSString *key in names) {
        @try {
            id obj = [self valueForKey:key];
            if ([obj isKindOfClass:[UIButton class]]) {
                UIButton *orig = (UIButton *)obj;
                UIButton *p = [UIButton buttonWithType:UIButtonTypeCustom];
                p.tag = orig.tag;
                [p setTitle:[orig titleForState:UIControlStateNormal] forState:UIControlStateNormal];
                [p setImage:[orig imageForState:UIControlStateNormal] forState:UIControlStateNormal];
                p.backgroundColor = orig.backgroundColor ?: [UIColor systemBlueColor];
                p.titleLabel.font = orig.titleLabel.font ?: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];

                // Copy actions to prototype so SidewaysScrollView can clone including actions
                for (id target in orig.allTargets) {
                    NSArray<NSString *> *actsUp = [orig actionsForTarget:target forControlEvent:UIControlEventTouchUpInside] ?: @[];
                    for (NSString *name in actsUp) {
                        SEL sel = NSSelectorFromString(name);
                        [p addTarget:target action:sel forControlEvents:UIControlEventTouchUpInside];
                    }
#ifdef UIControlEventPrimaryActionTriggered
                    NSArray<NSString *> *actsPrim = [orig actionsForTarget:target forControlEvent:UIControlEventPrimaryActionTriggered] ?: @[];
                    for (NSString *name in actsPrim) {
                        SEL sel = NSSelectorFromString(name);
                        [p addTarget:target action:sel forControlEvents:UIControlEventPrimaryActionTriggered];
                    }
#endif
                }

                [protos addObject:p];

                // Hide the original to avoid visual duplication; keep constraints intact
                orig.hidden = YES;
                orig.alpha = 0.0;
                orig.accessibilityElementsHidden = YES;
            }
        } @catch (__unused NSException *e) {
            // Ignore if property doesn't exist
        }
    }

    if (protos.count == 0) {
        // Fallback: create some colorful actions so UI is still useful
        NSArray<UIColor *> *colors = @[
            [UIColor colorWithRed:0.95 green:0.38 blue:0.38 alpha:1.0],
            [UIColor colorWithRed:0.95 green:0.70 blue:0.28 alpha:1.0],
            [UIColor colorWithRed:0.45 green:0.77 blue:0.33 alpha:1.0],
            [UIColor colorWithRed:0.36 green:0.66 blue:0.96 alpha:1.0],
            [UIColor colorWithRed:0.70 green:0.49 blue:0.96 alpha:1.0],
            [UIColor colorWithRed:0.95 green:0.55 blue:0.80 alpha:1.0],
            [UIColor colorWithRed:0.40 green:0.80 blue:0.72 alpha:1.0],
            [UIColor colorWithRed:0.98 green:0.62 blue:0.25 alpha:1.0]
        ];
        for (NSInteger i = 0; i < 8; i++) {
            UIButton *p = [UIButton buttonWithType:UIButtonTypeCustom];
            [p setTitle:[NSString stringWithFormat:@"Action %ld", (long)i+1] forState:UIControlStateNormal];
            p.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            p.backgroundColor = colors[i % colors.count];
            [protos addObject:p];
        }
    }

    // Build header container
    CGFloat headerH = 120.0; // buttons will be ~240pt tall, centered
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), headerH)];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    container.backgroundColor = UIColor.clearColor;
    container.clipsToBounds = NO;

    // Scroller
    SidewaysScrollView *ssv = [[SidewaysScrollView alloc] initWithFrame:container.bounds];
    ssv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:ssv];
    [ssv configureWithButtons:protos doubleSize:YES];

    // Install as table header
    self.chatTableView.tableHeaderView = container;

    objc_setAssociatedObject(self, kTopContainerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kSidewaysKey, ssv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kInstalledKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end