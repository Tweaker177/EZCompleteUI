// BRRicochetGameView.m
// BrainRotGame
// EZCompleteUI

#import "BRRicochetGameView.h"

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

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx || !self.model) return;

    if (self.backgroundImage) {
        UIGraphicsPushContext(ctx);
        [self.backgroundImage drawInRect:self.bounds];
        UIGraphicsPopContext();
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

        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.35].CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        [path stroke];

        // Show remaining hits on anything tougher than a one-hit particle,
        // same intent as the maze's crack overlays — a quick durability read.
        if (obstacle.maxHP > 1) {
            NSString *hpLabel = [NSString stringWithFormat:@"%ld", (long)obstacle.hp];
            NSDictionary<NSAttributedStringKey, id> *attrs = @{
                NSFontAttributeName: [UIFont boldSystemFontOfSize:13],
                NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.78]
            };
            CGSize textSize = [hpLabel sizeWithAttributes:attrs];
            CGPoint origin = CGPointMake(CGRectGetMidX(obstacle.frame) - textSize.width  / 2.0,
                                          CGRectGetMidY(obstacle.frame) - textSize.height / 2.0);
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
