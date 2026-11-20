//
//  EZTheme.m
//  EZCompleteUI
//
//  See EZTheme.h. The chat pattern is an original doodle tile drawn in
//  code — thin gold outlines of coins, stars, notes, chat bubbles and
//  other small motifs scattered over the deep navy base at very low
//  alpha, so it reads as texture rather than pictures. Drawn once and
//  cached; tiles seamlessly by re-drawing each motif at the tile's
//  wrap-around offsets.
//

#import "EZTheme.h"

#pragma mark - Palette

@implementation EZTheme

+ (UIColor *)backgroundColor {
    static UIColor *color; static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithRed:0.07 green:0.06 blue:0.16 alpha:1.0];
    });
    return color;
}

+ (UIColor *)cardColor {
    static UIColor *color; static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithRed:0.12 green:0.11 blue:0.24 alpha:1.0];
    });
    return color;
}

+ (UIColor *)goldColor {
    static UIColor *color; static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithRed:1.0 green:0.78 blue:0.10 alpha:1.0];
    });
    return color;
}

+ (UIImage *)selectedSegmentGradientImage {
    static UIImage *image; static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize size = CGSizeMake(48, 32);
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
        UIImage *rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
            UIColor *top = [UIColor colorWithRed:1.0 green:0.81 blue:0.18 alpha:1.0];
            UIColor *bottom = [UIColor colorWithRed:0.97 green:0.74 blue:0.07 alpha:1.0];
            NSArray *colors = @[(id)top.CGColor, (id)[EZTheme goldColor].CGColor, (id)bottom.CGColor];
            CGGradientRef gradient = CGGradientCreateWithColors(CGColorSpaceCreateDeviceRGB(),
                                                                (__bridge CFArrayRef)colors, NULL);
            CGContextDrawLinearGradient(rendererContext.CGContext, gradient,
                                        CGPointMake(0, 0), CGPointMake(0, size.height), 0);
            CGGradientRelease(gradient);
        }];
        image = [rendered resizableImageWithCapInsets:UIEdgeInsetsMake(0, 8, 0, 8)
                                         resizingMode:UIImageResizingModeStretch];
    });
    return image;
}

+ (UIColor *)hairlineColor {
    static UIColor *color; static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithWhite:1.0 alpha:0.10];
    });
    return color;
}

+ (UIColor *)primaryTextColor {
    return [UIColor whiteColor];
}

+ (UIColor *)secondaryTextColor {
    static UIColor *color; static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithWhite:1.0 alpha:0.60];
    });
    return color;
}

+ (UIColor *)userBubbleColor {
    return [self goldColor];
}

+ (UIColor *)userBubbleTextColor {
    return [self backgroundColor];
}

+ (UIColor *)assistantBubbleColor {
    return [self cardColor];
}

+ (UIImage *)primaryGradientImage {
    static UIImage *image; static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize size = CGSizeMake(120, 56);
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
        UIImage *rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
            UIColor *top = [UIColor colorWithRed:1.0 green:0.84 blue:0.28 alpha:1.0];
            UIColor *bottom = [UIColor colorWithRed:0.95 green:0.71 blue:0.05 alpha:1.0];
            NSArray *colors = @[(id)top.CGColor, (id)[EZTheme goldColor].CGColor, (id)bottom.CGColor];
            CGGradientRef gradient = CGGradientCreateWithColors(CGColorSpaceCreateDeviceRGB(),
                                                                (__bridge CFArrayRef)colors, NULL);
            CGContextDrawLinearGradient(rendererContext.CGContext, gradient,
                                        CGPointMake(0, 0), CGPointMake(0, size.height), 0);
            CGGradientRelease(gradient);
        }];
        image = [rendered resizableImageWithCapInsets:UIEdgeInsetsMake(27, 27, 27, 27)
                                         resizingMode:UIImageResizingModeStretch];
    });
    return image;
}

+ (UIImage *)sliderThumbImage {
    static UIImage *image; static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGSize size = CGSizeMake(28, 28);
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
            CGContextRef ctx = rendererContext.CGContext;
            CGRect ring = CGRectInset(CGRectMake(0, 0, size.width, size.height), 1.0, 1.0);
            CGContextSetFillColorWithColor(ctx, [EZTheme goldColor].CGColor);
            CGContextFillEllipseInRect(ctx, ring);
            CGContextSetStrokeColorWithColor(ctx, [EZTheme backgroundColor].CGColor);
            CGContextSetLineWidth(ctx, 2.0);
            CGContextStrokeEllipseInRect(ctx, ring);
            CGRect shine = CGRectMake(8, 6, 12, 8);
            CGContextSetFillColorWithColor(ctx, [[UIColor whiteColor] colorWithAlphaComponent:0.25].CGColor);
            CGContextFillEllipseInRect(ctx, shine);
        }];
    });
    return image;
}

+ (UINavigationBarAppearance *)navigationBarAppearance {
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [self backgroundColor];
    appearance.shadowColor = [UIColor clearColor];
    appearance.titleTextAttributes = @{ NSForegroundColorAttributeName: [UIColor whiteColor] };
    appearance.largeTitleTextAttributes = @{ NSForegroundColorAttributeName: [UIColor whiteColor] };
    return appearance;
}

+ (UIColor *)chatBackgroundColor {
    static UIColor *color; static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithPatternImage:[self _patternTileImage]];
    });
    return color;
}

#pragma mark - Pattern tile

typedef struct {
    NSInteger type;     // one of the EZDoodleType values below
    CGFloat x, y;       // centre, in tile points
    CGFloat r;          // motif radius, in points
    CGFloat rot;        // rotation, degrees
    CGFloat alpha;      // stroke alpha
} EZDoodle;

enum {
    EZDoodleStar = 0,
    EZDoodleSparkle,
    EZDoodleCoin,
    EZDoodleNote,
    EZDoodleChatBubble,
    EZDoodleDiamond,
    EZDoodleBolt,
    EZDoodleWave,
    EZDoodlePlus,
    EZDoodlePlanet,
    EZDoodleRing,
};

// Scattered layout on a 288pt tile. Positions keep motifs clear of the
// tile edges where possible; the renderer also draws wrap-around copies,
// so the tile repeats seamlessly regardless.
static const EZDoodle kEZDoodles[] = {
    { EZDoodleCoin,      36,  40, 15,   0, 0.075 },
    { EZDoodleSparkle,   96,  26, 10,  15, 0.060 },
    { EZDoodleNote,     150,  52, 14, -10, 0.065 },
    { EZDoodleStar,     228,  34, 12,  20, 0.070 },
    { EZDoodleChatBubble, 272, 88, 13,   8, 0.055 },
    { EZDoodleWave,      52, 108, 16,   0, 0.050 },
    { EZDoodlePlanet,   128, 118, 15, -14, 0.060 },
    { EZDoodleDiamond,  196, 104, 11,   0, 0.065 },
    { EZDoodlePlus,     262, 160,  9,  12, 0.050 },
    { EZDoodleBolt,      30, 186, 12,  -8, 0.060 },
    { EZDoodleRing,      88, 168,  7,   0, 0.070 },
    { EZDoodleStar,     150, 196, 10,  40, 0.055 },
    { EZDoodleCoin,     222, 196, 12,   0, 0.060 },
    { EZDoodleSparkle,  272, 238,  9,   0, 0.070 },
    { EZDoodleNote,      66, 244, 12,  14, 0.055 },
    { EZDoodleChatBubble, 140, 258, 11, -6, 0.060 },
    { EZDoodleWave,     214, 262, 14,   0, 0.045 },
    { EZDoodleRing,     104,  84,  5,   0, 0.060 },
};

static void EZStrokePolygon(CGContextRef ctx, const CGPoint *points, NSUInteger count) {
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, points[0].x, points[0].y);
    for (NSUInteger i = 1; i < count; i++) {
        CGContextAddLineToPoint(ctx, points[i].x, points[i].y);
    }
    CGContextClosePath(ctx);
    CGContextStrokePath(ctx);
}

// Draws one motif centred on the origin; the caller sets the transform
// (translation + rotation) and the stroke colour beforehand.
static void EZDrawDoodle(CGContextRef ctx, NSInteger type, CGFloat r) {
    switch (type) {
        case EZDoodleStar: {
            CGPoint pts[10];
            for (NSInteger i = 0; i < 10; i++) {
                CGFloat rad = (i % 2 == 0) ? r : r * 0.48;
                CGFloat a = -M_PI_2 + i * M_PI / 5.0;
                pts[i] = CGPointMake(cos(a) * rad, sin(a) * rad);
            }
            EZStrokePolygon(ctx, pts, 10);
            break;
        }
        case EZDoodleSparkle: {
            CGPoint pts[8];
            for (NSInteger i = 0; i < 8; i++) {
                CGFloat rad = (i % 2 == 0) ? r : r * 0.16;
                CGFloat a = -M_PI_2 + i * M_PI / 4.0;
                pts[i] = CGPointMake(cos(a) * rad, sin(a) * rad);
            }
            EZStrokePolygon(ctx, pts, 8);
            break;
        }
        case EZDoodleCoin: {
            CGContextStrokeEllipseInRect(ctx, CGRectMake(-r, -r, 2 * r, 2 * r));
            CGFloat inner = r * 0.66;
            CGContextStrokeEllipseInRect(ctx, CGRectMake(-inner, -inner, 2 * inner, 2 * inner));
            break;
        }
        case EZDoodleNote: {
            // Head, stem and flag of a quaver.
            CGContextStrokeEllipseInRect(ctx, CGRectMake(-r * 0.95, r * 0.18, r * 0.78, r * 0.58));
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, -r * 0.20, r * 0.44);
            CGContextAddLineToPoint(ctx, -r * 0.20, -r * 0.92);
            CGContextAddQuadCurveToPoint(ctx, r * 0.42, -r * 0.62, r * 0.38, -r * 0.05);
            CGContextStrokePath(ctx);
            break;
        }
        case EZDoodleChatBubble: {
            CGRect body = CGRectMake(-r, -r * 0.78, 2 * r, r * 1.42);
            CGMutablePathRef bubblePath = CGPathCreateMutable();
            CGPathAddRoundedRect(bubblePath, NULL, body, r * 0.34, r * 0.34);
            CGContextAddPath(ctx, bubblePath);
            CGPathRelease(bubblePath);
            CGContextStrokePath(ctx);
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, -r * 0.55, r * 0.60);
            CGContextAddLineToPoint(ctx, -r * 0.34, r * 1.02);
            CGContextAddLineToPoint(ctx, -r * 0.05, r * 0.62);
            CGContextStrokePath(ctx);
            break;
        }
        case EZDoodleDiamond: {
            CGPoint pts[4] = {
                CGPointMake(0, -r), CGPointMake(r * 0.78, 0),
                CGPointMake(0, r),  CGPointMake(-r * 0.78, 0),
            };
            EZStrokePolygon(ctx, pts, 4);
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, -r * 0.78, 0);
            CGContextAddLineToPoint(ctx, r * 0.78, 0);
            CGContextStrokePath(ctx);
            break;
        }
        case EZDoodleBolt: {
            CGPoint pts[6] = {
                CGPointMake(r * 0.20, -r),       CGPointMake(-r * 0.45, r * 0.25),
                CGPointMake(-r * 0.05, r * 0.25), CGPointMake(-r * 0.20, r),
                CGPointMake(r * 0.45, -r * 0.25), CGPointMake(r * 0.05, -r * 0.25),
            };
            EZStrokePolygon(ctx, pts, 6);
            break;
        }
        case EZDoodleWave: {
            CGContextBeginPath(ctx);
            NSInteger steps = 24;
            for (NSInteger i = 0; i <= steps; i++) {
                CGFloat x = -r + (2 * r) * ((CGFloat)i / steps);
                CGFloat y = sin((CGFloat)i / steps * M_PI * 2) * r * 0.30;
                if (i == 0) CGContextMoveToPoint(ctx, x, y);
                else        CGContextAddLineToPoint(ctx, x, y);
            }
            CGContextStrokePath(ctx);
            break;
        }
        case EZDoodlePlus: {
            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, -r * 0.7, 0);
            CGContextAddLineToPoint(ctx, r * 0.7, 0);
            CGContextMoveToPoint(ctx, 0, -r * 0.7);
            CGContextAddLineToPoint(ctx, 0, r * 0.7);
            CGContextStrokePath(ctx);
            break;
        }
        case EZDoodlePlanet: {
            CGFloat body = r * 0.60;
            CGContextStrokeEllipseInRect(ctx, CGRectMake(-body, -body, 2 * body, 2 * body));
            CGContextStrokeEllipseInRect(ctx, CGRectMake(-r * 1.12, -r * 0.30, r * 2.24, r * 0.60));
            break;
        }
        case EZDoodleRing: {
            CGContextStrokeEllipseInRect(ctx, CGRectMake(-r, -r, 2 * r, 2 * r));
            break;
        }
        default:
            break;
    }
}

+ (UIImage *)_patternTileImage {
    static UIImage *tile; static dispatch_once_t once;
    dispatch_once(&once, ^{
        const CGFloat S = 288;
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.opaque = YES;
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(S, S) format:format];
        tile = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
            CGContextRef c = ctx.CGContext;
            [[self backgroundColor] setFill];
            CGContextFillRect(c, CGRectMake(0, 0, S, S));
            CGContextSetLineWidth(c, 1.1);
            CGContextSetLineCap(c, kCGLineCapRound);
            CGContextSetLineJoin(c, kCGLineJoinRound);
            NSUInteger count = sizeof(kEZDoodles) / sizeof(kEZDoodles[0]);
            for (NSUInteger i = 0; i < count; i++) {
                const EZDoodle *d = &kEZDoodles[i];
                UIColor *stroke = [[self goldColor] colorWithAlphaComponent:d->alpha];
                [stroke setStroke];
                // Draw the motif at every wrap-around offset that lands
                // on the tile, so the pattern repeats seamlessly.
                for (NSInteger ox = -1; ox <= 1; ox++) {
                    for (NSInteger oy = -1; oy <= 1; oy++) {
                        CGFloat cx = d->x + ox * S;
                        CGFloat cy = d->y + oy * S;
                        if (cx < -2 * d->r || cx > S + 2 * d->r ||
                            cy < -2 * d->r || cy > S + 2 * d->r) continue;
                        CGContextSaveGState(c);
                        CGContextTranslateCTM(c, cx, cy);
                        CGContextRotateCTM(c, d->rot * M_PI / 180.0);
                        EZDrawDoodle(c, d->type, d->r);
                        CGContextRestoreGState(c);
                    }
                }
            }
        }];
    });
    return tile;
}

@end
