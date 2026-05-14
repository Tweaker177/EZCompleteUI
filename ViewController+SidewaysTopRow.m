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
        @"galleryButton":        @"Gallery",
        @"settingsButton":       @"Settings",
    };
    NSDictionary<NSString *, NSString *> *buttonImageNames = @{
        @"speakButton":          @"SpeakButton.PNG",
        @"webSearchButton":      @"WebSearchButton.PNG",
        @"addChatButton":        @"NewChatButton.png",
        @"memoriesButton":       @"MemoriesButton.PNG",
        @"textToSpeechButton":   @"TTSButton.PNG",
        @"supportRequestButton": @"SupportButton.PNG",
        @"cloningButton":        @"VoiceCloneButton.PNG",
        @"galleryButton":        @"galleryButton.png",
        @"settingsButton":       @"SettingsButton.png",
    };

    // Preserve original button order for consistent display
    NSArray<NSString *> *buttonOrder = @[
        @"memoriesButton",
        @"speakButton",
        @"supportRequestButton",
        @"textToSpeechButton",
        @"webSearchButton",
        @"settingsButton",
        @"addChatButton",
        @"cloningButton",
        @"galleryButton",
    ];

    for (NSString *key in buttonOrder) {
        @try {
            id obj = [self valueForKey:key];
            if ([obj isKindOfClass:[UIButton class]]) {
                UIButton *orig = (UIButton *)obj;
                UIButton *p = [UIButton buttonWithType:UIButtonTypeCustom];
                p.tag = orig.tag;

                NSString *label = buttonLabels[key] ?: key;
                NSString *imageName = buttonImageNames[key];
                UIImage *icon = imageName ? [UIImage imageNamed:imageName] : [orig imageForState:UIControlStateNormal];

                if (icon) {
                    // Image card — no title, no insets, clear bg.
                    // SidewaysScrollView.cloneFrom: handles all styling.
                    [p setImage:icon forState:UIControlStateNormal];
                    p.backgroundColor = UIColor.clearColor;
                    p.layer.masksToBounds = NO;
                } else {
                    // Text fallback
                    [p setTitle:label forState:UIControlStateNormal];
                    p.backgroundColor = orig.backgroundColor ?: [UIColor systemBlueColor];
                    p.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
                    p.titleLabel.numberOfLines = 1;
                    p.contentEdgeInsets = UIEdgeInsetsMake(10, 12, 10, 12);
                }

                p.accessibilityLabel = label;
                p.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
                p.contentVerticalAlignment   = UIControlContentVerticalAlignmentCenter;

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

    // Fallback placeholder buttons if none of the originals were found
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

    // ── Container ──────────────────────────────────────────────────────────
    // Taller row so icon cards have more breathing room.
    CGFloat headerH = 120.0;

    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.clipsToBounds = NO;

    // Frosted glass background — content scrolls under it, row stays crisp.
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.alpha = 0.72;
    [container addSubview:blurView];
    [NSLayoutConstraint activateConstraints:@[
        [blurView.topAnchor    constraintEqualToAnchor:container.topAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [blurView.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];

    // Thin separator line at the bottom of the row
    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    [container addSubview:separator];
    [NSLayoutConstraint activateConstraints:@[
        [separator.bottomAnchor  constraintEqualToAnchor:container.bottomAnchor],
        [separator.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [separator.heightAnchor   constraintEqualToConstant:0.5],
    ]];

    SidewaysScrollView *ssv = [[SidewaysScrollView alloc] initWithFrame:CGRectZero];
    ssv.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ssv];

    // Small vertical padding so shadow glows don't get clipped by the container edge
    const CGFloat vPad = 6.0;
    [NSLayoutConstraint activateConstraints:@[
        [ssv.topAnchor      constraintEqualToAnchor:container.topAnchor    constant:vPad],
        [ssv.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-vPad],
        [ssv.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor],
        [ssv.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];
    [ssv configureWithButtons:protos doubleSize:NO];

    [self.view addSubview:container];

    // Deactivate any existing top constraint on chatTableView
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
        [container.topAnchor    constraintEqualToAnchor:self.threadTitleLabel.bottomAnchor constant:4],
        [container.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [container.heightAnchor   constraintEqualToConstant:headerH],
        tableTop,
    ]];

    objc_setAssociatedObject(self, kTableTopConstraint, tableTop,  OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kTopContainerKey,   container,  OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kSidewaysKey,       ssv,        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kInstalledKey,      @(YES),     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
