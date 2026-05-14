//
//  BRGameView.m
//

#import "BRGameView.h"
#import "BRGameModel.h"

@implementation BRGameView

- (void)drawRect:(CGRect)rect {
    if (!self.model) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    NSInteger cols = self.model.cols;
    NSInteger rows = self.model.rows;
    CGFloat w = CGRectGetWidth(self.bounds) / (CGFloat)cols;
    CGFloat h = CGRectGetHeight(self.bounds) / (CGFloat)rows;
    for (NSInteger r=0;r<rows;r++) {
        for (NSInteger c=0;c<cols;c++) {
            BRTile *t = [self.model tileAtCol:c row:r];
            CGRect tileRect = CGRectMake(c*w, r*h, w, h);
            UIColor *fill = [UIColor blackColor];
            switch (t.type) {
                case BRTileTypeWall: fill = [UIColor colorWithWhite:0.12 alpha:1.0]; break;
                case BRTileTypeFloor: fill = [UIColor colorWithWhite:0.95 alpha:1.0]; break;
                case BRTileTypeExit: fill = [UIColor colorWithRed:0.15 green:0.75 blue:0.25 alpha:1.0]; break;
            }
            CGContextSetFillColorWithColor(ctx, fill.CGColor);
            CGContextFillRect(ctx, tileRect);
            // item or enemy overlays
            if (t.itemName) {
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:1.0 green:0.85 blue:0.15 alpha:1.0].CGColor);
                CGRect dot = CGRectInset(tileRect, w*0.25, h*0.25);
                CGContextFillEllipseInRect(ctx, dot);
            }
            if (t.enemyName) {
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1.0].CGColor);
                CGRect dot = CGRectInset(tileRect, w*0.15, h*0.15);
                CGContextFillEllipseInRect(ctx, dot);
            }
            // grid lines
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.8 alpha:0.6].CGColor);
            CGContextStrokeRect(ctx, tileRect);
        }
    }
    // draw player
    CGFloat pw = w * 0.8, ph = h * 0.8;
    CGRect playerRect = CGRectMake(self.model.playerCol * w + (w-pw)/2.0,
                                   self.model.playerRow * h + (h-ph)/2.0,
                                   pw, ph);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.12 green:0.45 blue:0.9 alpha:1.0].CGColor);
    CGContextFillEllipseInRect(ctx, playerRect);
}

@end