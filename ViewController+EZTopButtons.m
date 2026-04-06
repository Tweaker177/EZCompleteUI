//
//  ViewController+EZTopButtons.m
//  EZCompleteUI
//
//  Complete, compiler‑ready replacement.
//  - Distinct per‑button gradient colors (3D boxy look + shadow)
//  - Press animation with haptics (respects Reduce Motion)
//  - Upside‑down horseshoe layout via iCarousel
//  - Raised placement, blurred backdrop, gradient border sized on layout
//  - Large centered title below the buttons, auto‑syncs with self.title
//  - Correct EZLog / EZLogf usage per helpers.h
//

#import "ViewController.h"
#import "helpers.h"

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// If using a forked iCarousel that references UILongPressGestureRecognizerDelegate,
// include the tiny shim first.
#import "iCarouselCompat.h"
#import "iCarousel.h"

#pragma mark - Associated keys

static const void *kEZCUI_TopContainer   = &kEZCUI_TopContainer;
static const void *kEZCUI_Carousel       = &kEZCUI_Carousel;
static const void *kEZCUI_BorderGradient = &kEZCUI_BorderGradient;
static const void *kEZCUI_TitleLabel     = &kEZCUI_TitleLabel;
static const void *kEZCUI_BlurView       = &kEZCUI_BlurView;
static const void *kEZCUI_Buttons        = &kEZCUI_Buttons;

static NSString *const kEZCUI_LogTag     = @"EZTopButtons";

#pragma mark - Tunables

static const CGFloat kEZCUI_TopInset       = 2.0;   // closer to safe-area top
static const CGFloat kEZCUI_RowHeight      = 90.0;  // requested smaller row
static const CGFloat kEZCUI_TitleHeight    = 34.0;  // title label height
static const CGFloat kEZCUI_VertPadding    = 18.0;  // inner paddings
static const CGFloat kEZCUI_ButtonFont     = 15.0;  // 15pt Semibold
static const CGFloat kEZCUI_ContainerCR    = 16.0;

#pragma mark - Helpers

static inline BOOL ezcui_reduceMotion(void) {
#if TARGET_OS_IOS
    return UIAccessibilityIsReduceMotionEnabled();
#else
    return NO;
#endif
}

static inline CGFloat ezcui_clampUnit(CGFloat x) { return MAX(0.0, MIN(1.0, x)); }

static inline UIColor *ezcui_adjustBrightness(UIColor *c, CGFloat delta) {
    CGFloat r,g,b,a;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return c;
    r = ezcui_clampUnit(r + delta);
    g = ezcui_clampUnit(g + delta);
    b = ezcui_clampUnit(b + delta);
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

static UIImage *ezcui_verticalGradientImage(UIColor *top, UIColor *bottom) {
    CGSize sz = CGSizeMake(8, 60);
    UIGraphicsBeginImageContextWithOptions(sz, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[(__bridge id)top.CGColor, (__bridge id)bottom.CGColor];
    CGFloat locs[] = {0.0, 1.0};
    CGGradientRef g = CGGradientCreateWithColors(space, (CFArrayRef)colors, locs);
    CGContextDrawLinearGradient(ctx, g, CGPointZero, CGPointMake(0, sz.height), 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(space);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [img resizableImageWithCapInsets:UIEdgeInsetsMake(20, 3, 20, 3)];
}

static void ezcui_styleButton3D(UIButton *b, UIColor *base) {
    CGFloat r = 12.0;
    b.layer.cornerRadius = r;
    b.layer.masksToBounds = NO;

    UIColor *top    = ezcui_adjustBrightness(base, +0.10);
    UIColor *bottom = ezcui_adjustBrightness(base, -0.16);
    UIColor *topHi  = ezcui_adjustBrightness(base, -0.02);
    UIColor *botHi  = ezcui_adjustBrightness(base, -0.30);

    UIImage *gradNormal = ezcui_verticalGradientImage(top, bottom);
    UIImage *gradHigh   = ezcui_verticalGradientImage(topHi, botHi);

    [b setBackgroundImage:gradNormal forState:UIControlStateNormal];
    [b setBackgroundImage:gradHigh   forState:UIControlStateHighlighted];

    b.layer.borderWidth = 1.0;
    b.layer.borderColor = ezcui_adjustBrightness(base, -0.25).CGColor;

    b.layer.shadowColor   = [ezcui_adjustBrightness(base, -0.6) CGColor];
    b.layer.shadowOpacity = 0.28;
    b.layer.shadowRadius  = 12;
    b.layer.shadowOffset  = CGSizeMake(0, 8);

    dispatch_async(dispatch_get_main_queue(), ^{
        b.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:b.bounds cornerRadius:r].CGPath;
    });

    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:kEZCUI_ButtonFont weight:UIFontWeightSemibold];
    b.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
}

#pragma mark - Press animations

@interface ViewController (EZTopButtons_Press)
- (void)ezcui_btnDown:(UIButton *)sender;
- (void)ezcui_btnUp:(UIButton *)sender;
@end

@implementation ViewController (EZTopButtons_Press)

- (void)ezcui_btnDown:(UIButton *)sender {
    if (ezcui_reduceMotion()) return;
    UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [h impactOccurred];
    [UIView animateWithDuration:0.10
                          delay:0
                        options:UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionCurveEaseIn
                     animations:^{
        sender.transform = CGAffineTransformMakeScale(0.94, 0.94);
        sender.layer.shadowOffset = CGSizeMake(0, 2);
        sender.layer.shadowRadius = 6;
    } completion:nil];
}

- (void)ezcui_btnUp:(UIButton *)sender {
    if (ezcui_reduceMotion()) return;
    [UIView animateWithDuration:0.55
                          delay:0
         usingSpringWithDamping:0.55
          initialSpringVelocity:0.8
                        options:UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionCurveEaseOut
                     animations:^{
        sender.transform = CGAffineTransformIdentity;
        sender.layer.shadowOffset = CGSizeMake(0, 8);
        sender.layer.shadowRadius = 12;
    } completion:nil];
}

@end

static inline UIButton *ezcui_makeButton(NSString *title, UIColor *color, NSInteger tag, id target) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:title forState:UIControlStateNormal];
    b.tag = tag;
    ezcui_styleButton3D(b, color);

    [b addTarget:target action:@selector(ezcui_btnDown:) forControlEvents:UIControlEventTouchDown|UIControlEventTouchDragEnter];
    UIControlEvents upEvents = UIControlEventTouchCancel|UIControlEventTouchDragExit|UIControlEventTouchUpInside;
#ifdef UIControlEventPrimaryActionTriggered
    upEvents |= UIControlEventPrimaryActionTriggered;
#endif
    [b addTarget:target action:@selector(ezcui_btnUp:) forControlEvents:upEvents];

    return b;
}

static inline void ezcui_copyTargetsFromTo(UIButton *src, UIButton *dst) {
    if (!src) return;
    for (id target in src.allTargets) {
        NSArray<NSString *> *actsUp = [src actionsForTarget:target forControlEvent:UIControlEventTouchUpInside] ?: @[];
        for (NSString *name in actsUp) {
            [dst addTarget:target action:NSSelectorFromString(name) forControlEvents:UIControlEventTouchUpInside];
        }
#ifdef UIControlEventPrimaryActionTriggered
        NSArray<NSString *> *actsPrim = [src actionsForTarget:target forControlEvent:UIControlEventPrimaryActionTriggered] ?: @[];
        for (NSString *name in actsPrim) {
            [dst addTarget:target action:NSSelectorFromString(name) forControlEvents:UIControlEventPrimaryActionTriggered];
        }
#endif
    }
}

#pragma mark - Fallback screens with logging

@interface ViewController (EZTopButtons_Fallbacks)
- (void)ezcui_openSettings;
- (void)ezcui_openHistory;
- (void)ezcui_openMemories;
- (void)ezcui_openSupport;
- (void)ezcui_openTTS;
- (void)ezcui_openCloning;
@end

@implementation ViewController (EZTopButtons_Fallbacks)

- (void)ezcui_safelyPush:(UIViewController *)vc title:(NSString *)title {
    if (!vc) {
        EZLog(EZLogLevelWarning, kEZCUI_LogTag, @"Attempted to push nil VC");
        return;
    }
    vc.title = vc.title ?: title;
    @try {
        if (self.navigationController) {
            [self.navigationController pushViewController:vc animated:YES];
        } else {
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            [self presentViewController:nav animated:YES completion:nil];
        }
    } @catch (NSException *e) {
        EZLogf(EZLogLevelError, kEZCUI_LogTag, @"Present/push failed: %@", e);
    }
}

- (void)ezcui_openSettings {
    Class C = NSClassFromString(@"SettingsViewController");
    if (C) [self ezcui_safelyPush:[[C alloc] init] title:@"Settings"];
    else EZLog(EZLogLevelWarning, kEZCUI_LogTag, @"SettingsViewController not found");
}
- (void)ezcui_openHistory {
    Class C = NSClassFromString(@"ChatHistoryViewController");
    if (C) [self ezcui_safelyPush:[[C alloc] init] title:@"History"];
    else EZLog(EZLogLevelWarning, kEZCUI_LogTag, @"ChatHistoryViewController not found");
}
- (void)ezcui_openMemories {
    Class C = NSClassFromString(@"MemoriesViewController");
    if (C) [self ezcui_safelyPush:[[C alloc] init] title:@"Memories"];
    else EZLog(EZLogLevelWarning, kEZCUI_LogTag, @"MemoriesViewController not found");
}
- (void)ezcui_openSupport {
    Class C = NSClassFromString(@"SupportRequestViewController");
    if (C) [self ezcui_safelyPush:[[C alloc] init] title:@"Support"];
    else EZLog(EZLogLevelWarning, kEZCUI_LogTag, @"SupportRequestViewController not found");
}
- (void)ezcui_openTTS {
    Class C = NSClassFromString(@"TextToSpeechViewController");
    if (C) [self ezcui_safelyPush:[[C alloc] init] title:@"Text to Speech"];
    else EZLog(EZLogLevelWarning, kEZCUI_LogTag, @"TextToSpeechViewController not found");
}
- (void)ezcui_openCloning {
    NSArray<NSString *> *candidates = @[
        @"ElevenLabsCloneViewController",
        @"CloningViewController",
        @"VoiceCloneViewController"
    ];
    for (NSString *name in candidates) {
        Class C = NSClassFromString(name);
        if (C) {
            EZLogf(EZLogLevelInfo, kEZCUI_LogTag, @"Opening %@", name);
            [self ezcui_safelyPush:[[C alloc] init] title:@"Cloning"];
            return;
        }
    }
    EZLog(EZLogLevelWarning, kEZCUI_LogTag, @"No Cloning VC class found");
}

@end

#pragma mark - Decorative (blur, border, wiggle)

@implementation ViewController (EZTopButtons_Deco)

- (UIBlurEffectStyle)ezcui_blurStyleForCurrentTrait {
    if (@available(iOS 13.0, *)) {
        return UIUserInterfaceStyleDark == self.traitCollection.userInterfaceStyle
            ? UIBlurEffectStyleSystemThickMaterialDark
            : UIBlurEffectStyleSystemThickMaterialLight;
    }
    return UIBlurEffectStyleProminent;
}

- (void)ezcui_installBlurIn:(UIView *)container {
    @try {
        UIBlurEffect *effect = [UIBlurEffect effectWithStyle:[self ezcui_blurStyleForCurrentTrait]];
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:effect];
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        blur.layer.cornerRadius = kEZCUI_ContainerCR;
        blur.layer.masksToBounds = YES;
        [container insertSubview:blur atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [blur.topAnchor constraintEqualToAnchor:container.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
            [blur.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        ]];
        objc_setAssociatedObject(self, kEZCUI_BlurView, blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) {
        EZLogf(EZLogLevelError, kEZCUI_LogTag, @"Failed to add blur: %@", e);
    }
}

- (void)ezcui_applyGradientBorderTo:(UIView *)v {
    @try {
        CAGradientLayer *grad = [CAGradientLayer layer];
        grad.colors = @[
            (id)[UIColor colorWithRed:0.96 green:0.53 blue:0.22 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.53 green:0.76 blue:0.98 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.54 green:0.86 blue:0.56 alpha:1.0].CGColor
        ];
        grad.startPoint = CGPointMake(0, 0);
        grad.endPoint   = CGPointMake(1, 1);

        CAShapeLayer *shape = [CAShapeLayer layer];
        shape.lineWidth = 2.0;
        shape.fillColor = UIColor.clearColor.CGColor;
        shape.path = [UIBezierPath bezierPathWithRoundedRect:v.bounds cornerRadius:kEZCUI_ContainerCR].CGPath;

        grad.frame = v.bounds;
        grad.mask  = shape;

        [v.layer addSublayer:grad];
        objc_setAssociatedObject(self, kEZCUI_BorderGradient, grad, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) {
        EZLogf(EZLogLevelError, kEZCUI_LogTag, @"Failed to add gradient border: %@", e);
    }
}

- (void)ezcui_playScrollerShake:(UIView *)v {
    if (ezcui_reduceMotion()) return;
    @try {
        CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
        a.values = @[@0, @-10, @10, @-8, @8, @-5, @5, @0];
        a.keyTimes = @[@0.0, @0.15, @0.35, @0.50, @0.65, @0.78, @0.90, @1.0];
        a.duration = 1.0;
        a.additive = YES;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [v.layer addAnimation:a forKey:@"ezcui.wiggle"];
    } @catch (NSException *e) {
        EZLogf(EZLogLevelError, kEZCUI_LogTag, @"Shake animation failed: %@", e);
    }
}

@end

#pragma mark - iCarousel datasource/delegate (horseshoe)

@interface ViewController (EZTopButtons_Carousel) <iCarouselDataSource, iCarouselDelegate>
@end

@implementation ViewController (EZTopButtons_Carousel)

- (CATransform3D)carousel:(iCarousel *)carousel
   itemTransformForOffset:(CGFloat)offset
            baseTransform:(CATransform3D)transform
{
    // Upside‑down horseshoe curve
    CGFloat theta  = offset * 0.45;      // radians spread
    CGFloat radius = 180.0;              // arc radius

    CGFloat x = sin(theta) * radius * 0.72;
    CGFloat y = (1.0 - cos(theta)) * 70.0;

    CATransform3D t = CATransform3DIdentity;
    t.m34 = -1.0/700.0;
    t = CATransform3DTranslate(t, x, y, -fabs(offset) * 60.0);
    CGFloat s = 1.0 - MIN(0.25, fabs(offset) * 0.12);
    t = CATransform3DScale(t, s, s, 1.0);
    t = CATransform3DRotate(t, -theta * 0.15, 0, 1, 0);
    return CATransform3DConcat(t, transform);
}

- (NSInteger)numberOfItemsInCarousel:(iCarousel *)carousel {
    NSArray *buttons = objc_getAssociatedObject(self, kEZCUI_Buttons);
    return (NSInteger)buttons.count;
}

- (UIView *)carousel:(iCarousel *)carousel viewForItemAtIndex:(NSInteger)index reusingView:(UIView *)reusing {
    NSArray<UIButton *> *buttons = objc_getAssociatedObject(self, kEZCUI_Buttons);
    if (index < 0 || index >= (NSInteger)buttons.count) {
        EZLogf(EZLogLevelError, kEZCUI_LogTag, @"Invalid button index %ld", (long)index);
        return reusing ?: [UIView new];
    }
    UIButton *b = buttons[index];

    const CGFloat W = 140.0;
    const CGFloat H = 70.0;
    UIView *holder = reusing ?: [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, H)];
    holder.backgroundColor = UIColor.clearColor;

    if (b.superview != holder) {
        [holder.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
        b.frame = holder.bounds;
        b.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [holder addSubview:b];
    }
    return holder;
}

- (CGFloat)carouselItemWidth:(iCarousel *)carousel { return 140.0; }

@end

#pragma mark - Swizzle installer (viewDidLoad + viewDidLayoutSubviews)

@implementation ViewController (EZTopButtons)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class c = self;

        SEL orig1 = @selector(viewDidLoad);
        SEL repl1 = @selector(ezcui_viewDidLoad__installTopRow);
        Method m1 = class_getInstanceMethod(c, orig1);
        Method m2 = class_getInstanceMethod(c, repl1);
        if (m1 && m2) method_exchangeImplementations(m1, m2);

        SEL orig2 = @selector(viewDidLayoutSubviews);
        SEL repl2 = @selector(ezcui_viewDidLayout__syncBorder);
        Method m3 = class_getInstanceMethod(c, orig2);
        Method m4 = class_getInstanceMethod(c, repl2);
        if (m3 && m4) method_exchangeImplementations(m3, m4);
    });
}

- (void)ezcui_viewDidLoad__installTopRow {
    // Call original
    [self ezcui_viewDidLoad__installTopRow];

    @try {
        const CGFloat containerH = kEZCUI_RowHeight + kEZCUI_TitleHeight + kEZCUI_VertPadding;

        // Container
        UIView *container = [[UIView alloc] init];
        container.translatesAutoresizingMaskIntoConstraints = NO;
        container.backgroundColor = UIColor.clearColor;
        container.layer.cornerRadius = kEZCUI_ContainerCR;
        container.clipsToBounds = NO;

        // Soft elevation so chat scrolling under looks good
        container.layer.shadowColor = [UIColor colorWithWhite:0 alpha:0.85].CGColor;
        container.layer.shadowOpacity = 0.20;
        container.layer.shadowRadius = 16;
        container.layer.shadowOffset = CGSizeMake(0, 10);

        [self.view addSubview:container];
        [NSLayoutConstraint activateConstraints:@[
            [container.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:kEZCUI_TopInset],
            [container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
            [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
            [container.heightAnchor constraintEqualToConstant:containerH]
        ]];

        // Blur
        [self ezcui_installBlurIn:container];

        // Title label (base)
        UILabel *title = [[UILabel alloc] init];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.textAlignment = NSTextAlignmentCenter;
        title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightHeavy];
        title.textColor = UIColor.labelColor;
        title.adjustsFontSizeToFitWidth = YES;
        title.minimumScaleFactor = 0.7;
        title.text = [self ezcui_resolvedTopTitle];
        [container addSubview:title];

        // Carousel
        iCarousel *carousel = [[iCarousel alloc] initWithFrame:CGRectZero];
        carousel.translatesAutoresizingMaskIntoConstraints = NO;
        carousel.type = iCarouselTypeCustom;
        carousel.decelerationRate = 0.95;
        carousel.bounces = YES;
        carousel.clipsToBounds = NO;
        carousel.delegate = (id<iCarouselDelegate>)self;
        carousel.dataSource = (id<iCarouselDataSource>)self;
        [container addSubview:carousel];

        [NSLayoutConstraint activateConstraints:@[
            [title.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10],
            [title.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
            [title.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4],
            [title.heightAnchor constraintEqualToConstant:kEZCUI_TitleHeight],

            [carousel.topAnchor constraintEqualToAnchor:container.topAnchor constant:4],
            [carousel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
            [carousel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
            [carousel.bottomAnchor constraintEqualToAnchor:title.topAnchor constant:-10],
        ]];

        // Gradient border after layout
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ezcui_applyGradientBorderTo:container];
        });

        // Distinct base colors (rotating palette)
        NSArray<UIColor *> *colors = @[
            [UIColor colorWithRed:0.95 green:0.38 blue:0.38 alpha:1.0], // red
            [UIColor colorWithRed:0.98 green:0.62 blue:0.25 alpha:1.0], // orange
            [UIColor colorWithRed:0.45 green:0.77 blue:0.33 alpha:1.0], // green
            [UIColor colorWithRed:0.36 green:0.66 blue:0.96 alpha:1.0], // blue
            [UIColor colorWithRed:0.70 green:0.49 blue:0.96 alpha:1.0], // purple
            [UIColor colorWithRed:0.95 green:0.55 blue:0.80 alpha:1.0], // pink
            [UIColor colorWithRed:0.40 green:0.80 blue:0.72 alpha:1.0], // teal
            [UIColor colorWithRed:0.56 green:0.76 blue:0.98 alpha:1.0], // light blue
            [UIColor colorWithRed:0.85 green:0.46 blue:0.36 alpha:1.0], // brick
            [UIColor colorWithRed:0.20 green:0.72 blue:0.88 alpha:1.0], // cyan
            [UIColor colorWithRed:0.25 green:0.82 blue:0.55 alpha:1.0], // mint
            [UIColor colorWithRed:0.95 green:0.70 blue:0.28 alpha:1.0], // amber
        ];

        // Build buttons with requested titles
        NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
        struct { __unsafe_unretained NSString *key; __unsafe_unretained NSString *title; int colorIndex; } map[] = {
            {@"modelButton",        @"Model",              3},
            {@"attachButton",       @"Attach",             11},
            {@"settingsButton",     @"Settings",           2},
            {@"clipboardButton",    @"Copy to Clipboard",  7},
            {@"speakButton",        @"Speak Response",     9},
            {@"clearButton",        @"Delete Thread",      0},
            {@"imageSettingsButton",@"Image Settings",     8},
            {@"dictateButton",      @"Dictate",            10},
            {@"webSearchButton",    @"Web Search",         4},
            {@"historyButton",      @"Chat History",       6},
            {@"addChatButton",      @"New Conversation",   1},
            {@"renameButton",       @"Rename",             5},
        };
        const NSInteger mapCount = (NSInteger)(sizeof(map)/sizeof(map[0]));

        for (NSInteger i = 0; i < mapCount; i++) {
            NSString *key = map[i].key;
            NSString *titleTxt = map[i].title;
            UIColor  *base = colors[map[i].colorIndex % colors.count];

            UIButton *b = ezcui_makeButton(titleTxt, base, 1000 + (int)i, self);

            // Clone actions if an original property exists
            @try {
                id obj = [self valueForKey:key];
                if ([obj isKindOfClass:[UIButton class]]) {
                    ezcui_copyTargetsFromTo((UIButton *)obj, b);
                }
            } @catch (NSException *e) {
                EZLogf(EZLogLevelWarning, kEZCUI_LogTag, @"KVC fetch failed for key %@: %@", key, e);
            }

            // Fallback actions where useful
            if (b.allTargets.count == 0) {
                if ([key isEqualToString:@"settingsButton"]) {
                    [b addTarget:self action:@selector(ezcui_openSettings) forControlEvents:UIControlEventTouchUpInside];
                } else if ([key isEqualToString:@"historyButton"]) {
                    [b addTarget:self action:@selector(ezcui_openHistory) forControlEvents:UIControlEventTouchUpInside];
                }
            }
            [buttons addObject:b];
        }

        // Extra quick-access screens
        NSArray<NSDictionary *> *extras = @[
            @{@"title":@"Memories", @"sel":NSStringFromSelector(@selector(ezcui_openMemories)), @"color":colors[0]},
            @{@"title":@"Support",  @"sel":NSStringFromSelector(@selector(ezcui_openSupport)),  @"color":colors[1]},
            @{@"title":@"TTS",      @"sel":NSStringFromSelector(@selector(ezcui_openTTS)),      @"color":colors[2]},
            @{@"title":@"Cloning",  @"sel":NSStringFromSelector(@selector(ezcui_openCloning)),  @"color":colors[3]},
        ];
        for (NSInteger i = 0; i < (NSInteger)extras.count; i++) {
            NSDictionary *d = extras[i];
            UIButton *b = ezcui_makeButton(d[@"title"], d[@"color"], 2000 + (int)i, self);
            SEL sel = NSSelectorFromString(d[@"sel"]);
            [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
            [buttons addObject:b];
        }

        // Store + load
        objc_setAssociatedObject(self, kEZCUI_Buttons, buttons, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [carousel reloadData];

        // Gentle attention draw
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self ezcui_playScrollerShake:carousel];
        });

        // Keep above table; ensure inset
        [self.view bringSubviewToFront:container];
        if ([self respondsToSelector:@selector(chatTableView)] && self.chatTableView) {
            UIEdgeInsets insets = self.chatTableView.contentInset;
            CGFloat needed = containerH + 8.0;
            if (insets.top < needed) insets.top = needed;
            self.chatTableView.contentInset = insets;
            self.chatTableView.scrollIndicatorInsets = insets;
        } else {
            EZLog(EZLogLevelInfo, kEZCUI_LogTag, @"chatTableView is nil; skipping insets");
        }

        // Save associations
        objc_setAssociatedObject(self, kEZCUI_TopContainer, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kEZCUI_Carousel, carousel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kEZCUI_TitleLabel, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    } @catch (NSException *e) {
        EZLogf(EZLogLevelError, kEZCUI_LogTag, @"install failed: %@", e);
    }
}

// Swizzled layout to keep border sized correctly
- (void)ezcui_viewDidLayout__syncBorder {
    [self ezcui_viewDidLayout__syncBorder]; // call original
    @try {
        CAGradientLayer *g = objc_getAssociatedObject(self, kEZCUI_BorderGradient);
        UIView *c = objc_getAssociatedObject(self, kEZCUI_TopContainer);
        if (g && c) {
            g.frame = c.bounds;
            CAShapeLayer *mask = (CAShapeLayer *)g.mask;
            mask.path = [UIBezierPath bezierPathWithRoundedRect:c.bounds cornerRadius:kEZCUI_ContainerCR].CGPath;
        }
        if (c.layer.shadowOpacity > 0.0) {
            c.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:c.bounds cornerRadius:kEZCUI_ContainerCR].CGPath;
        }
    } @catch (NSException *e) {
        EZLogf(EZLogLevelWarning, kEZCUI_LogTag, @"layout sync failed: %@", e);
    }
}

@end

#pragma mark - Title resolution + sync (lives with top-buttons)

@interface ViewController (EZTopButtons_TitleSync_Private)
- (NSString *)ezcui_resolvedTopTitle;
@end

@implementation ViewController (EZTopButtons_TitleSync)

- (NSString *)ezcui_resolvedTopTitle {
    // Prefer self.title, then navigationItem.title, then activeThread.title, else default
    NSString *t = self.title;
    if (t.length == 0) t = self.navigationItem.title;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if (t.length == 0 && [self respondsToSelector:@selector(activeThread)]) {
        id thr = [self performSelector:@selector(activeThread)];
        if (thr && [thr respondsToSelector:@selector(title)]) {
            NSString *thrTitle = [thr performSelector:@selector(title)];
            if (thrTitle.length > 0) t = thrTitle;
        }
    }
#pragma clang diagnostic pop
    if (t.length == 0) t = @"New Thread";
    return t;
}

- (void)ezcui_setTopTitle:(NSString *)title {
    UILabel *lab = objc_getAssociatedObject(self, kEZCUI_TitleLabel);
    if (lab) {
        NSString *final = (title.length > 0) ? title : [self ezcui_resolvedTopTitle];
        lab.text = final;
    }
}

// Keep label synced if someone sets self.title later
- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    [self ezcui_setTopTitle:title ?: @""];
}

@end