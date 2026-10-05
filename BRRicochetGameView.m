// BRRicochetGameView.m
// BrainRotGame
// EZCompleteUI

#import "BRRicochetGameView.h"

@interface BRRicochetGameView ()
@property (nonatomic, assign) CGRect hitPointFrame;
@property (nonatomic, assign) CFTimeInterval hitPointVisibleUntil;
@end

@implementation BRRicochetGameView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.06 green:0.04 blue:0.12 alpha:1.0];
        self.opaque = NO;
    }
    return self;
}

- (void)setModel:(BRRicochetGameModel *)model {
    _model = model;
    [self setNeedsDisplay];
}

- (void)setBackgroundImage:(UIImage *)backgroundImage {
    _backgroundImage = backgroundImage;
    [self setNeedsDisplay];
}

- (void)setObstacleImage:(UIImage *)obstacleImage {
    _obstacleImage = obstacleImage;
    [self setNeedsDisplay];
}

- (void)showHitPointsForObstacleAtFrame:(CGRect)frame {
    self.hitPointFrame = frame;
    self.hitPointVisibleUntil = CACurrentMediaTime() + 0.65;
    [self setNeedsDisplay];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.68 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (CACurrentMediaTime() >= self.hitPointVisibleUntil) [self setNeedsDisplay];
    });
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx || !self.model) return;

    if (self.backgroundImage) {
        UIGraphicsPushContext(ctx);
        [self.backgroundImage drawInRect:self.bounds];
        UIGraphicsPopContext();
    }

    // Pickups are revealed when their covering obstacle breaks. Drawing them
    // before obstacles makes them naturally appear underneath the remaining
    // block layer until the player can collect them.
    UIImage *heartImage = [UIImage imageNamed:@"heart"];
    UIImage *coinImage = [UIImage imageNamed:@"EZCoin"];
    for (BRRicochetPickup *pickup in self.model.pickups) {
        CGRect drawRect = CGRectInset(pickup.frame, 1.0, 1.0);
        UIImage *image = pickup.kind == BRRicochetPickupKindHeart ? heartImage : coinImage;
        if (image) {
            UIGraphicsPushContext(ctx);
            [image drawInRect:drawRect];
            UIGraphicsPopContext();
        }
    }

    for (BRObstacle *obstacle in self.model.obstacles) {
        UIColor *fillColor;
        switch (obstacle.hp) {
            case 1:  fillColor = [UIColor colorWithRed:0.30 green:0.36 blue:0.51 alpha:0.92]; break;
            case 2:  fillColor = [UIColor colorWithRed:0.47 green:0.53 blue:0.70 alpha:0.92]; break;
            default: fillColor = [UIColor colorWithRed:0.68 green:0.72 blue:0.85 alpha:0.92]; break;
        }

        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:obstacle.frame cornerRadius:6.0];
        [fillColor setFill];
        [path fill];

        if (self.obstacleImage) {
            UIGraphicsPushContext(ctx);
            [self.obstacleImage drawInRect:CGRectInset(obstacle.frame, 1.0, 1.0)];
            UIGraphicsPopContext();
        }

        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.35].CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        [path stroke];

        // The durability badge is feedback for a contact, rather than a
        // permanent overlay that obscures the obstacle art.
        if (obstacle.maxHP > 1 && CACurrentMediaTime() < self.hitPointVisibleUntil &&
            CGRectEqualToRect(obstacle.frame, self.hitPointFrame)) {
            NSString *hpLabel = [NSString stringWithFormat:@"%ld", (long)obstacle.hp];
            NSDictionary<NSAttributedStringKey, id> *attrs = @{
                NSFontAttributeName: [UIFont boldSystemFontOfSize:13],
                NSForegroundColorAttributeName: UIColor.whiteColor,
                NSStrokeColorAttributeName: UIColor.blackColor,
                NSStrokeWidthAttributeName: @(-3.0),
            };
            CGSize textSize = [hpLabel sizeWithAttributes:attrs];
            CGPoint origin = CGPointMake(CGRectGetMidX(obstacle.frame) - textSize.width  / 2.0,
                                          CGRectGetMidY(obstacle.frame) - textSize.height / 2.0);
            CGRect badge = CGRectInset(CGRectMake(origin.x, origin.y, textSize.width, textSize.height), -5.0, -2.0);
            UIBezierPath *badgePath = [UIBezierPath bezierPathWithRoundedRect:badge cornerRadius:badge.size.height / 2.0];
            [[UIColor colorWithWhite:0 alpha:0.72] setFill];
            [badgePath fill];
            [hpLabel drawAtPoint:origin withAttributes:attrs];
        }
    }

    if (self.showingBlastPreview) {
        CGRect ring = CGRectMake(self.blastPreviewCenter.x - self.blastPreviewRadius,
                                  self.blastPreviewCenter.y - self.blastPreviewRadius,
                                  self.blastPreviewRadius * 2,
                                  self.blastPreviewRadius * 2);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.42 blue:0.55 alpha:0.45].CGColor);
        CGContextSetLineWidth(ctx, 2.0);
        CGContextStrokeEllipseInRect(ctx, ring);
    }
}

@end
