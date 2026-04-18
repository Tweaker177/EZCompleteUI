//
//  ViewController+SidewaysTopRow.m
//  EZCompleteUI
//

#import "ViewController+SidewaysTopRow.h"
#import "SidewaysScrollView.h"
#import <objc/runtime.h>
#import "helpers.h"
#import "ViewController.h"

static const void *kTopContainerKey    = &kTopContainerKey;
static const void *kSidewaysKey        = &kSidewaysKey;
static const void *kInstalledKey       = &kInstalledKey;
static const void *kTableTopConstraint = &kTableTopConstraint;

@implementation ViewController (SidewaysTopRow)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class c = [self class];

        SEL orig1 = @selector(viewDidLoad);
        SEL swiz1 = @selector(ez_viewDidLoad_swizzled);
        method_exchangeImplementations(class_getInstanceMethod(c, orig1),
                                       class_getInstanceMethod(c, swiz1));
    });
}

- (void)ez_viewDidLoad_swizzled {
    [self ez_viewDidLoad_swizzled];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf ez_installSidewaysIfNeeded];
    });
}

#pragma mark - Install

- (void)ez_installSidewaysIfNeeded {
    NSNumber *installed = objc_getAssociatedObject(self, kInstalledKey);
    if (installed.boolValue) return;
    if (!self.chatTableView) return;
    if (!self.threadTitleLabel) return;

    NSMutableArray<UIButton *> *protos = [NSMutableArray array];

    NSDictionary<NSString *, NSString *> *buttonLabels = @{
        @"speakButton":          @"Speak",
        @"webSearchButton":      @"Web Search",
        @"addChatButton":        @"New Chat",
        @"memoriesButton":       @"Memories",
        @"textToSpeechButton":   @"TTS",
        @"supportRequestButton": @"Support",
        @"cloningButton":        @"Clone Voice",
    };

    for (NSString *key in buttonLabels) {
        @try {
            id obj = [self valueForKey:key];
            if ([obj isKindOfClass:[UIButton class]]) {
                UIButton *orig = (UIButton *)obj;
                UIButton *p = [UIButton buttonWithType:UIButtonTypeCustom];
                p.tag = orig.tag;

                NSString *label = buttonLabels[key] ?: key;
                [p setTitle:label forState:UIControlStateNormal];
                [p setImage:[orig imageForState:UIControlStateNormal]
                   forState:UIControlStateNormal];
                p.backgroundColor = orig.backgroundColor ?: [UIColor systemBlueColor];
                p.titleLabel.font = [UIFont systemFontOfSize:15
                                                      weight:UIFontWeightSemibold];

                for (id target in orig.allTargets) {
                    NSArray<NSString *> *actsUp = [orig actionsForTarget:target
                                                        forControlEvent:UIControlEventTouchUpInside] ?: @[];
                    for (NSString *name in actsUp) {
                        [p addTarget:target action:NSSelectorFromString(name)
                            forControlEvents:UIControlEventTouchUpInside];
                    }
#ifdef UIControlEventPrimaryActionTriggered
                    NSArray<NSString *> *actsPrim = [orig actionsForTarget:target
                                                          forControlEvent:UIControlEventPrimaryActionTriggered] ?: @[];
                    for (NSString *name in actsPrim) {
                        [p addTarget:target action:NSSelectorFromString(name)
                            forControlEvents:UIControlEventPrimaryActionTriggered];
                    }
#endif
                }

                [protos addObject:p];

                orig.hidden = YES;
                orig.alpha = 0.0;
                orig.accessibilityElementsHidden = YES;
            }
        } @catch (__unused NSException *e) {}
    }

    if (protos.count == 0) {
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
            [p setTitle:[NSString stringWithFormat:@"Action %ld", (long)i+1]
               forState:UIControlStateNormal];
            p.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            p.backgroundColor = colors[i];
            [protos addObject:p];
        }
    }

    // Build container
    CGFloat headerH = 90.0;
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.backgroundColor = UIColor.clearColor;
    container.clipsToBounds = NO;

    SidewaysScrollView *ssv = [[SidewaysScrollView alloc] initWithFrame:CGRectZero];
    ssv.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ssv];
    [NSLayoutConstraint activateConstraints:@[
        [ssv.topAnchor constraintEqualToAnchor:container.topAnchor],
        [ssv.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [ssv.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ssv.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];
    [ssv configureWithButtons:protos doubleSize:NO];

    // Add container to self.view -- NOT as tableHeaderView
    [self.view addSubview:container];

    // Deactivate any existing top constraint on chatTableView --
    // check both self.view.constraints and threadTitleLabel.constraints
    // since AL can store the constraint on either view
    for (NSLayoutConstraint *c in [self.view.constraints copy]) {
        BOOL tableIsFirst  = (c.firstItem  == self.chatTableView &&
                              c.firstAttribute  == NSLayoutAttributeTop);
        BOOL tableIsSecond = (c.secondItem == self.chatTableView &&
                              c.secondAttribute == NSLayoutAttributeTop);
        if (tableIsFirst || tableIsSecond) {
            EZLogf(EZLogLevelDebug, @"EZSideways", @"Deactivating from self.view: %@", c);
            c.active = NO;
        }
    }
    for (NSLayoutConstraint *c in [self.threadTitleLabel.constraints copy]) {
        BOOL tableIsFirst  = (c.firstItem  == self.chatTableView &&
                              c.firstAttribute  == NSLayoutAttributeTop);
        BOOL tableIsSecond = (c.secondItem == self.chatTableView &&
                              c.secondAttribute == NSLayoutAttributeTop);
        if (tableIsFirst || tableIsSecond) {
            EZLogf(EZLogLevelDebug, @"EZSideways", @"Deactivating from threadTitleLabel: %@", c);
            c.active = NO;
        }
    }

    // Pin container below threadTitleLabel, push chatTableView below container
    NSLayoutConstraint *tableTop =
        [self.chatTableView.topAnchor constraintEqualToAnchor:container.bottomAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:self.threadTitleLabel.bottomAnchor constant:4],
        [container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [container.heightAnchor constraintEqualToConstant:headerH],
        tableTop,
    ]];

    objc_setAssociatedObject(self, kTableTopConstraint, tableTop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kTopContainerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kSidewaysKey, ssv, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kInstalledKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
