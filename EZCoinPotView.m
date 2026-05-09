// EZCoinPotView.m
// EZCompleteUI

#import "EZCoinPotView.h"

@interface EZCoinPotView ()
@property (nonatomic, strong) CAShapeLayer *potBodyLayer;
@property (nonatomic, strong) CAShapeLayer *potRimLayer;
@property (nonatomic, strong) CAShapeLayer *fillLayer;
@property (nonatomic, strong) CAShapeLayer *fillMaskLayer;
@property (nonatomic, strong) UILabel      *balanceLabel;
@property (nonatomic, assign) CGFloat       currentFill;
@end

@implementation EZCoinPotView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds   = NO;
        _fillLevel    = 0.0;
        _coinBalance  = 0;
        _currentFill  = 0.0;
        [self setupLayers];
    }
    return self;
}

- (void)setupLayers {
    // Pot body (black cauldron)
    self.potBodyLayer = [CAShapeLayer layer];
    self.potBodyLayer.fillColor   = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:1.0].CGColor;
    self.potBodyLayer.strokeColor = [UIColor colorWithRed:0.3 green:0.3 blue:0.35 alpha:1.0].CGColor;
    self.potBodyLayer.lineWidth   = 1.5;
    [self.layer addSublayer:self.potBodyLayer];

    // Gold fill inside pot (clipped to pot interior)
    self.fillLayer = [CAShapeLayer layer];
    self.fillLayer.fillColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.0 alpha:1.0].CGColor;
    [self.layer addSublayer:self.fillLayer];

    // Pot rim (gold ring at top)
    self.potRimLayer = [CAShapeLayer layer];
    self.potRimLayer.fillColor   = [UIColor colorWithRed:1.0 green:0.80 blue:0.0 alpha:1.0].CGColor;
    self.potRimLayer.strokeColor = [UIColor colorWithRed:0.85 green:0.65 blue:0.0 alpha:1.0].CGColor;
    self.potRimLayer.lineWidth   = 1.0;
    [self.layer addSublayer:self.potRimLayer];

    // Balance label (coin count inside pot)
    self.balanceLabel = [[UILabel alloc] init];
    self.balanceLabel.font          = [UIFont boldSystemFontOfSize:9];
    self.balanceLabel.textColor     = [UIColor colorWithRed:0.1 green:0.05 blue:0.0 alpha:1.0];
    self.balanceLabel.textAlignment = NSTextAlignmentCenter;
    self.balanceLabel.adjustsFontSizeToFitWidth = YES;
    [self addSubview:self.balanceLabel];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self rebuildPotPaths];
}

- (void)rebuildPotPaths {
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    // ── Pot geometry ─────────────────────────────────────────────────────────
    CGFloat rimH      = h * 0.18;
    CGFloat rimY      = h * 0.05;
    CGFloat rimW      = w * 0.82;
    CGFloat rimX      = (w - rimW) / 2.0;

    // Cauldron body: wider at bottom, narrower at top where it meets the rim
    CGFloat bodyTopW  = rimW * 0.85;
    CGFloat bodyTopX  = (w - bodyTopW) / 2.0;
    CGFloat bodyTopY  = rimY + rimH * 0.6;
    CGFloat bodyBotW  = w * 0.72;
    CGFloat bodyBotX  = (w - bodyBotW) / 2.0;
    CGFloat bodyBotY  = h * 0.92;
    CGFloat bodyH     = bodyBotY - bodyTopY;

    // Pot body path (rounded trapezoid)
    UIBezierPath *bodyPath = [UIBezierPath bezierPath];
    CGFloat r = 8.0;
    // Top-left
    [bodyPath moveToPoint:CGPointMake(bodyTopX + r, bodyTopY)];
    // Top edge
    [bodyPath addLineToPoint:CGPointMake(bodyTopX + bodyTopW - r, bodyTopY)];
    // Top-right curve
    [bodyPath addQuadCurveToPoint:CGPointMake(bodyTopX + bodyTopW, bodyTopY + r)
                     controlPoint:CGPointMake(bodyTopX + bodyTopW, bodyTopY)];
    // Right side → bottom-right
    [bodyPath addLineToPoint:CGPointMake(bodyBotX + bodyBotW - r, bodyBotY)];
    // Bottom-right curve
    [bodyPath addQuadCurveToPoint:CGPointMake(bodyBotX + bodyBotW - r - 4, bodyBotY + 4)
                     controlPoint:CGPointMake(bodyBotX + bodyBotW, bodyBotY)];
    // Bottom edge
    [bodyPath addLineToPoint:CGPointMake(bodyBotX + r + 4, bodyBotY + 4)];
    // Bottom-left curve
    [bodyPath addQuadCurveToPoint:CGPointMake(bodyBotX, bodyBotY)
                     controlPoint:CGPointMake(bodyBotX, bodyBotY)];
    // Left side → top-left
    [bodyPath addLineToPoint:CGPointMake(bodyTopX, bodyTopY + r)];
    // Top-left curve
    [bodyPath addQuadCurveToPoint:CGPointMake(bodyTopX + r, bodyTopY)
                     controlPoint:CGPointMake(bodyTopX, bodyTopY)];
    [bodyPath closePath];
    self.potBodyLayer.path = bodyPath.CGPath;

    // Rim path (rounded rect at top)
    UIBezierPath *rimPath = [UIBezierPath bezierPathWithRoundedRect:
        CGRectMake(rimX, rimY, rimW, rimH) cornerRadius:rimH / 2.0];
    self.potRimLayer.path = rimPath.CGPath;

    // ── Gold fill (animatable) ────────────────────────────────────────────────
    [self updateFillPathForLevel:self.currentFill
                        bodyTopX:bodyTopX bodyTopY:bodyTopY
                        bodyTopW:bodyTopW bodyBotX:bodyBotX
                        bodyBotW:bodyBotW bodyBotY:bodyBotY bodyH:bodyH];

    // Balance label positioned in lower 60% of pot interior
    CGFloat labelY = bodyTopY + bodyH * 0.35;
    CGFloat labelH = bodyH * 0.45;
    self.balanceLabel.frame = CGRectMake(bodyTopX + 4, labelY, bodyTopW - 8, labelH);
}

- (void)updateFillPathForLevel:(CGFloat)level
                      bodyTopX:(CGFloat)bodyTopX bodyTopY:(CGFloat)bodyTopY
                      bodyTopW:(CGFloat)bodyTopW bodyBotX:(CGFloat)bodyBotX
                      bodyBotW:(CGFloat)bodyBotW bodyBotY:(CGFloat)bodyBotY
                         bodyH:(CGFloat)bodyH {

    level = MAX(0.0, MIN(1.0, level));
    CGFloat fillH   = bodyH * level;
    CGFloat fillTopY = bodyBotY - fillH + 4;

    // Interpolate width at fill top
    CGFloat t        = 1.0 - level; // 0 = full (top width), 1 = empty (bot width)
    CGFloat fillTopW = bodyTopW * (1.0 - t) + bodyBotW * t;
    CGFloat fillTopX = (self.bounds.size.width - fillTopW) / 2.0;

    if (level < 0.01) {
        self.fillLayer.path = nil;
        return;
    }

    UIBezierPath *fillPath = [UIBezierPath bezierPath];
    [fillPath moveToPoint:CGPointMake(fillTopX, fillTopY)];
    [fillPath addLineToPoint:CGPointMake(fillTopX + fillTopW, fillTopY)];
    [fillPath addLineToPoint:CGPointMake(bodyBotX + bodyBotW - 4, bodyBotY + 3)];
    [fillPath addLineToPoint:CGPointMake(bodyBotX + 4, bodyBotY + 3)];
    [fillPath closePath];
    self.fillLayer.path = fillPath.CGPath;

    // Wavy top edge for the gold fill surface
    // Simple sine approximation via quadratic curves
    UIBezierPath *wavePath = [UIBezierPath bezierPath];
    [wavePath moveToPoint:CGPointMake(fillTopX, fillTopY)];
    CGFloat segments = 4;
    CGFloat segW     = fillTopW / segments;
    for (NSInteger i = 0; i < segments; i++) {
        CGFloat x0 = fillTopX + i * segW;
        CGFloat x1 = x0 + segW;
        CGFloat cy = fillTopY + (i % 2 == 0 ? -3.0 : 3.0);
        [wavePath addQuadCurveToPoint:CGPointMake(x1, fillTopY)
                         controlPoint:CGPointMake((x0 + x1) / 2.0, cy)];
    }
    // Complete the fill shape
    [wavePath addLineToPoint:CGPointMake(bodyBotX + bodyBotW - 4, bodyBotY + 3)];
    [wavePath addLineToPoint:CGPointMake(bodyBotX + 4, bodyBotY + 3)];
    [wavePath closePath];
    self.fillLayer.path = wavePath.CGPath;
}

// ── Public API ────────────────────────────────────────────────────────────────

- (void)updateBalance:(NSInteger)balance
        includedCoins:(NSInteger)includedCoins
             animated:(BOOL)animated {
    self.coinBalance = balance;

    CGFloat level = includedCoins > 0
        ? (CGFloat)balance / (CGFloat)includedCoins
        : 0.0;
    level = MAX(0.0, MIN(1.0, level));

    // Color shifts: gold → orange → red as it empties
    UIColor *fillColor;
    if (level > 0.5) {
        fillColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.0 alpha:1.0]; // gold
    } else if (level > 0.25) {
        fillColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.0 alpha:1.0]; // amber
    } else if (level > 0.10) {
        fillColor = [UIColor colorWithRed:0.9 green:0.3 blue:0.0 alpha:1.0];  // orange-red
    } else {
        fillColor = [UIColor colorWithRed:0.8 green:0.1 blue:0.1 alpha:1.0];  // red (critical)
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.balanceLabel.text = [NSString stringWithFormat:@"%ld", (long)balance];

        if (animated) {
            [UIView animateWithDuration:0.6
                                  delay:0
                 usingSpringWithDamping:0.7
                  initialSpringVelocity:0.3
                                options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{
                self.currentFill = level;
                [CATransaction begin];
                [CATransaction setAnimationDuration:0.6];
                self.fillLayer.fillColor = fillColor.CGColor;
                [self rebuildPotPaths];
                [CATransaction commit];
            } completion:nil];
        } else {
            self.currentFill = level;
            self.fillLayer.fillColor = fillColor.CGColor;
            [self rebuildPotPaths];
        }
    });
}

// ── Coin toss animation ───────────────────────────────────────────────────────

- (void)animateCoinToss:(NSInteger)coinsAdded completion:(void (^)(void))completion {
    NSInteger coinCount = MIN(MAX(3, coinsAdded / 40), 12);
    CGFloat potCenterX  = self.bounds.size.width / 2.0;
    CGFloat potMouthY   = self.bounds.size.height * 0.22;
    CGPoint potMouth    = [self convertPoint:CGPointMake(potCenterX, potMouthY) toView:self.window];

    UIWindow *window = self.window;
    if (!window) {
        if (completion) completion();
        return;
    }

    UIImage *img = self.coinImage ?: [UIImage systemImageNamed:@"circle.fill"];
    __block NSInteger landed = 0;

    for (NSInteger i = 0; i < coinCount; i++) {
        UIImageView *coin = [[UIImageView alloc] initWithImage:img];
        coin.frame = CGRectMake(0, 0, 28, 28);
        coin.layer.cornerRadius = 14;
        coin.clipsToBounds      = YES;

        // Start position: random point along top of screen
        CGFloat startX = 40 + arc4random_uniform((uint32_t)(window.bounds.size.width - 80));
        CGFloat startY = -30;
        coin.center    = CGPointMake(startX, startY);
        [window addSubview:coin];

        NSTimeInterval delay    = i * 0.08;
        NSTimeInterval duration = 0.45 + (arc4random_uniform(20) / 100.0);

        // Rotation
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue    = @(0);
        spin.toValue      = @(M_PI * 4 * (arc4random_uniform(2) == 0 ? 1 : -1));
        spin.duration     = duration;
        spin.beginTime    = CACurrentMediaTime() + delay;
        spin.fillMode     = kCAFillModeForwards;
        spin.removedOnCompletion = NO;
        [coin.layer addAnimation:spin forKey:@"spin"];

        // Arc trajectory
        [UIView animateWithDuration:duration delay:delay
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            coin.center = potMouth;
            coin.transform = CGAffineTransformMakeScale(0.3, 0.3);
            coin.alpha = 0.2;
        } completion:^(BOOL finished) {
            [coin removeFromSuperview];
            landed++;
            if (landed == coinCount) {
                // Brief pot glow
                [UIView animateWithDuration:0.15 animations:^{
                    self.potRimLayer.fillColor = [UIColor colorWithRed:1.0 green:1.0 blue:0.6 alpha:1.0].CGColor;
                } completion:^(BOOL f) {
                    [UIView animateWithDuration:0.3 animations:^{
                        self.potRimLayer.fillColor = [UIColor colorWithRed:1.0 green:0.80 blue:0.0 alpha:1.0].CGColor;
                    }];
                    if (completion) completion();
                }];
            }
        }];
    }
}

@end
