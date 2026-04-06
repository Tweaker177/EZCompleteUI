//
//  SidewaysScrollView.m
//  EZCompleteUI
//

#import "SidewaysScrollView.h"
#import <QuartzCore/QuartzCore.h>

@interface SidewaysScrollView () <UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) NSArray<UIButton *> *protoButtons;
@property (nonatomic, assign) CGFloat buttonWidth;
@property (nonatomic, assign) CGFloat buttonHeight;
@property (nonatomic, assign) BOOL doubleSize;
@property (nonatomic, assign) CGRect previousBounds;
@end

@implementation SidewaysScrollView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        _interItemSpacing = 12.0;

        _scrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
        _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.alwaysBounceHorizontal = YES;
        _scrollView.scrollEnabled = YES;
        _scrollView.delegate = self;
        _scrollView.clipsToBounds = NO; // allow button shadows to appear
        [self addSubview:_scrollView];

        [NSLayoutConstraint activateConstraints:@[
            [_scrollView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];

        _previousBounds = CGRectZero;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    if (!CGSizeEqualToSize(self.previousBounds.size, self.bounds.size) ||
        self.scrollView.contentSize.width == 0) {
        self.previousBounds = self.bounds;

        CGFloat h = CGRectGetHeight(self.bounds);
        if (h <= 0.0) return;

        // Big, easy-to-hit cards. Height is doubled if requested.
        self.buttonHeight = self.doubleSize ? (h * 2.0) : h;
        // Slightly wider than tall so titles fit nicely.
        self.buttonWidth  = MAX(88.0, self.buttonHeight * 1.1);

        [self rebuildContent];
    }
}

- (void)configureWithButtons:(NSArray<UIButton *> *)buttons doubleSize:(BOOL)doubleSize {
    self.protoButtons = buttons ?: @[];
    self.doubleSize   = doubleSize;
    [self setNeedsLayout];
}

#pragma mark - Build

- (void)rebuildContent {
    // Clear previous
    for (UIView *v in self.scrollView.subviews) { [v removeFromSuperview]; }

    NSInteger n = (NSInteger)self.protoButtons.count;
    if (n <= 0) {
        self.scrollView.contentSize = CGSizeZero;
        return;
    }

    const CGFloat itemW = self.buttonWidth;
    const CGFloat itemH = self.buttonHeight;
    const CGFloat spacing = self.interItemSpacing;

    const CGFloat containerH = CGRectGetHeight(self.bounds);
    const CGFloat y = (containerH - itemH) / 2.0; // center vertically (top/bottom overflow desired with doubleSize)

    // Total width of one sequence
    CGFloat singleWidth = n * itemW + MAX(0, n - 1) * spacing;

    // Duplicate sequence twice for seamless wrap
    for (NSInteger copyIdx = 0; copyIdx < 2; copyIdx++) {
        CGFloat x = copyIdx * (singleWidth + spacing);
        for (NSInteger i = 0; i < n; i++) {
            UIButton *btn = [self cloneFrom:self.protoButtons[i] itemHeight:itemH];

            btn.frame = CGRectMake(x, y, itemW, itemH);
            [self.scrollView addSubview:btn];
            x += itemW + spacing;
        }
    }

    CGFloat contentW = singleWidth * 2 + spacing; // small tail spacing
    self.scrollView.contentSize = CGSizeMake(contentW, containerH);
    self.scrollView.contentInset = UIEdgeInsetsZero;
    self.scrollView.contentOffset = CGPointZero;
}

- (UIButton *)cloneFrom:(UIButton *)proto itemHeight:(CGFloat)itemH {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.tag = proto.tag;

    // Title / image
    [btn setTitle:[proto titleForState:UIControlStateNormal] forState:UIControlStateNormal];
    UIImage *img = [proto imageForState:UIControlStateNormal];
    if (img) [btn setImage:img forState:UIControlStateNormal];

    // Font / bg
    btn.titleLabel.font = proto.titleLabel.font ?: [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    UIColor *bg = proto.backgroundColor ?: [UIColor systemBlueColor];
    btn.backgroundColor = bg;

    // Styling: corner, border, shadow
    btn.layer.cornerRadius = MAX(12.0, MIN(itemH * 0.18, 24.0));
    btn.layer.borderWidth  = 1.0;
    btn.layer.borderColor  = [UIColor colorWithWhite:0.92 alpha:1.0].CGColor;
    btn.layer.shadowColor  = [UIColor colorWithWhite:0 alpha:0.28].CGColor;
    btn.layer.shadowOffset = CGSizeMake(0, 3);
    btn.layer.shadowOpacity= 0.7;
    btn.layer.shadowRadius = 6.0;
    btn.clipsToBounds = NO;
    btn.contentEdgeInsets = UIEdgeInsetsMake(10, 14, 10, 14);

    // Title contrast
    CGFloat r=0,g=0,b=0,a=0;
    UIColor *titleColor = UIColor.labelColor;
    if ([bg getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat lum = 0.299*r + 0.587*g + 0.114*b;
        titleColor = (lum < 0.62) ? UIColor.whiteColor : UIColor.blackColor;
    }
    [btn setTitleColor:titleColor forState:UIControlStateNormal];

    // Copy target-actions exactly (TouchUpInside + Primary)
    for (id target in proto.allTargets) {
        NSArray<NSString *> *up = [proto actionsForTarget:target forControlEvent:UIControlEventTouchUpInside] ?: @[];
        for (NSString *n in up) {
            [btn addTarget:target action:NSSelectorFromString(n) forControlEvents:UIControlEventTouchUpInside];
        }
#ifdef UIControlEventPrimaryActionTriggered
        NSArray<NSString *> *prim = [proto actionsForTarget:target forControlEvent:UIControlEventPrimaryActionTriggered] ?: @[];
        for (NSString *n in prim) {
            [btn addTarget:target action:NSSelectorFromString(n) forControlEvents:UIControlEventPrimaryActionTriggered];
        }
#endif
    }

    return btn;
}

#pragma mark - Seamless wrap

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    NSInteger n = (NSInteger)self.protoButtons.count;
    if (n <= 0) return;

    CGFloat singleWidth = n * self.buttonWidth + MAX(0, n - 1) * self.interItemSpacing + self.interItemSpacing;
    if (singleWidth <= 0) return;

    CGFloat x = scrollView.contentOffset.x;
    if (x >= singleWidth) {
        scrollView.contentOffset = CGPointMake(fmod(x, singleWidth), 0);
    } else if (x < 0) {
        CGFloat wrapped = singleWidth + fmod(x, singleWidth);
        if (wrapped >= singleWidth) wrapped -= singleWidth;
        scrollView.contentOffset = CGPointMake(wrapped, 0);
    }
}

@end