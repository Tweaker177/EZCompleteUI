// BRPenguinParadeArt.m
// EZCompleteUI — Penguin Parade
//
// Symbol illustrations drawn in code on a 100 x 100 grid: snowflake, fish, igloo,
// hot cocoa, seal, whale, chick, an emperor penguin and the golden-egg scatter,
// plus the egg-hatch bonus art (penguin, speckled egg, shell halves, hatchling).

#import "BRPenguinParadeArt.h"

#pragma mark - Drawing helpers

static UIColor *HX(uint32_t hex, CGFloat alpha) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:alpha];
}
#define HEX(h) HX((h), 1.0)

static CGGradientRef MakeGradient(NSArray<UIColor *> *colors) {
    NSMutableArray *cg = [NSMutableArray arrayWithCapacity:colors.count];
    for (UIColor *color in colors) [cg addObject:(__bridge id)color.CGColor];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)cg, NULL);
    CGColorSpaceRelease(space);
    return gradient; // caller releases
}

static void LinearFill(CGContextRef c, UIBezierPath *path, NSArray<UIColor *> *colors, CGPoint from, CGPoint to) {
    CGContextSaveGState(c);
    [path addClip];
    CGGradientRef g = MakeGradient(colors);
    CGContextDrawLinearGradient(c, g, from, to, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGContextRestoreGState(c);
}

static void RadialFill(CGContextRef c, UIBezierPath *path, NSArray<UIColor *> *colors, CGPoint center, CGFloat radius) {
    CGContextSaveGState(c);
    [path addClip];
    CGGradientRef g = MakeGradient(colors);
    CGContextDrawRadialGradient(c, g, center, 0, center, radius, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGContextRestoreGState(c);
}

static void Stroke(UIBezierPath *path, UIColor *color, CGFloat width) {
    [color setStroke];
    path.lineWidth = width;
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    [path stroke];
}

static void Fill(UIBezierPath *path, UIColor *color) { [color setFill]; [path fill]; }

static UIBezierPath *Oval(CGFloat x, CGFloat y, CGFloat w, CGFloat h) { return [UIBezierPath bezierPathWithOvalInRect:CGRectMake(x, y, w, h)]; }
static UIBezierPath *Disc(CGFloat cx, CGFloat cy, CGFloat r) { return Oval(cx - r, cy - r, r * 2, r * 2); }
static UIBezierPath *RoundRect(CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat r) { return [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, w, h) cornerRadius:r]; }

static void Line(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, UIColor *color, CGFloat width) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(x1, y1)];
    [p addLineToPoint:CGPointMake(x2, y2)];
    Stroke(p, color, width);
}

static void DrawGlyph(NSString *text, CGRect rect, CGFloat size, UIColor *color) {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:size weight:UIFontWeightHeavy],
                             NSForegroundColorAttributeName: color,
                             NSParagraphStyleAttributeName: style };
    CGSize textSize = [text sizeWithAttributes:attrs];
    CGRect box = CGRectMake(rect.origin.x, rect.origin.y + (rect.size.height - textSize.height) / 2.0, rect.size.width, textSize.height);
    [text drawInRect:box withAttributes:attrs];
}

/// Runs `body` with the context mirrored left-to-right about x = 50 when `mirrored`.
static void WithMirror(CGContextRef c, BOOL mirrored, void (^body)(void)) {
    CGContextSaveGState(c);
    if (mirrored) { CGContextTranslateCTM(c, 100, 0); CGContextScaleCTM(c, -1, 1); }
    body();
    CGContextRestoreGState(c);
}

static void DrawSparkle(CGFloat cx, CGFloat cy, CGFloat r, UIColor *color) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(cx, cy - r)];
    [p addLineToPoint:CGPointMake(cx + r * .22, cy - r * .22)];
    [p addLineToPoint:CGPointMake(cx + r, cy)];
    [p addLineToPoint:CGPointMake(cx + r * .22, cy + r * .22)];
    [p addLineToPoint:CGPointMake(cx, cy + r)];
    [p addLineToPoint:CGPointMake(cx - r * .22, cy + r * .22)];
    [p addLineToPoint:CGPointMake(cx - r, cy)];
    [p addLineToPoint:CGPointMake(cx - r * .22, cy - r * .22)];
    [p closePath];
    Fill(p, color);
}

static void DrawBlossom(CGContextRef c, CGPoint center, CGFloat radius) {
    for (int k = 0; k < 5; k++) {
        CGFloat angle = -M_PI_2 + k * (2 * M_PI / 5);
        CGPoint pc = CGPointMake(center.x + cos(angle) * radius * .55, center.y + sin(angle) * radius * .55);
        UIBezierPath *petal = Disc(pc.x, pc.y, radius * .52);
        RadialFill(c, petal, @[HEX(0xFFF4F7), HEX(0xFFB3C8), HEX(0xF27FA3)], pc, radius * .6);
        Stroke([Disc(pc.x, pc.y, radius * .52) copy], HX(0xD9547E, .7), MAX(.4, radius * .05));
    }
    Fill(Disc(center.x, center.y, radius * .2), HEX(0xF5C842));
    for (int k = 0; k < 6; k++) {
        CGFloat angle = k * (M_PI / 3);
        CGPoint tip = CGPointMake(center.x + cos(angle) * radius * .42, center.y + sin(angle) * radius * .42);
        Line(center.x, center.y, tip.x, tip.y, HEX(0xB02A4A), MAX(.3, radius * .04));
        Fill(Disc(tip.x, tip.y, radius * .06), HEX(0x7A1530));
    }
}

static void DrawLeaf(CGContextRef c, CGPoint base, CGFloat length, CGFloat degrees, CGFloat width) {
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, base.x, base.y);
    CGContextRotateCTM(c, degrees * M_PI / 180.0);
    UIBezierPath *leaf = [UIBezierPath bezierPath];
    [leaf moveToPoint:CGPointZero];
    [leaf addQuadCurveToPoint:CGPointMake(length, 0) controlPoint:CGPointMake(length * .5, -width)];
    [leaf addQuadCurveToPoint:CGPointZero controlPoint:CGPointMake(length * .5, width)];
    LinearFill(c, leaf, @[HEX(0x7BD36B), HEX(0x1F7A33)], CGPointMake(0, -width), CGPointMake(length, width));
    Stroke([leaf copy], HX(0x0C4A20, .8), .6);
    Line(0, 0, length * .88, 0, HX(0x0C4A20, .45), .5);
    CGContextRestoreGState(c);
}

#pragma mark - Shared penguin parts


/// A front-facing penguin on the 100 x 140 grid: used for the bonus "presenters".
/// `scarf` tints the little scarf so the three penguins are easy to tell apart.
static void DrawPenguinFront(CGContextRef c, uint32_t scarf, BOOL crown) {
    // Feet.
    for (int side = 0; side < 2; side++) {
        CGFloat s = side == 0 ? -1 : 1;
        UIBezierPath *foot = Oval(50 + s * 15 - 10, 124, 20, 9);
        LinearFill(c, foot, @[HEX(0xFFB347), HEX(0xE0701F)], CGPointMake(50, 124), CGPointMake(50, 133));
        Stroke([foot copy], HEX(0x8A3A0A), 1.0);
    }
    // Body.
    UIBezierPath *body = [UIBezierPath bezierPath];
    [body moveToPoint:CGPointMake(50, 14)];
    [body addCurveToPoint:CGPointMake(82, 78) controlPoint1:CGPointMake(72, 14) controlPoint2:CGPointMake(84, 48)];
    [body addCurveToPoint:CGPointMake(50, 128) controlPoint1:CGPointMake(80, 108) controlPoint2:CGPointMake(70, 128)];
    [body addCurveToPoint:CGPointMake(18, 78) controlPoint1:CGPointMake(30, 128) controlPoint2:CGPointMake(20, 108)];
    [body addCurveToPoint:CGPointMake(50, 14) controlPoint1:CGPointMake(16, 48) controlPoint2:CGPointMake(28, 14)];
    [body closePath];
    LinearFill(c, body, @[HEX(0x3A4A66), HEX(0x14213A)], CGPointMake(50, 14), CGPointMake(50, 128));
    Stroke([body copy], HEX(0x0A1426), 1.4);
    // Belly.
    UIBezierPath *belly = [UIBezierPath bezierPath];
    [belly moveToPoint:CGPointMake(50, 40)];
    [belly addCurveToPoint:CGPointMake(70, 86) controlPoint1:CGPointMake(64, 40) controlPoint2:CGPointMake(70, 64)];
    [belly addCurveToPoint:CGPointMake(50, 122) controlPoint1:CGPointMake(70, 106) controlPoint2:CGPointMake(62, 122)];
    [belly addCurveToPoint:CGPointMake(30, 86) controlPoint1:CGPointMake(38, 122) controlPoint2:CGPointMake(30, 106)];
    [belly addCurveToPoint:CGPointMake(50, 40) controlPoint1:CGPointMake(30, 64) controlPoint2:CGPointMake(36, 40)];
    [belly closePath];
    LinearFill(c, belly, @[HEX(0xFFFFFF), HEX(0xDCEBF7)], CGPointMake(50, 40), CGPointMake(50, 122));
    // Flippers.
    for (int side = 0; side < 2; side++) {
        CGFloat s = side == 0 ? -1 : 1;
        UIBezierPath *fl = [UIBezierPath bezierPath];
        [fl moveToPoint:CGPointMake(50 + s * 30, 58)];
        [fl addQuadCurveToPoint:CGPointMake(50 + s * 38, 100) controlPoint:CGPointMake(50 + s * 50, 78)];
        [fl addQuadCurveToPoint:CGPointMake(50 + s * 26, 76) controlPoint:CGPointMake(50 + s * 28, 92)];
        [fl closePath];
        LinearFill(c, fl, @[HEX(0x3A4A66), HEX(0x0F1A30)], CGPointMake(50 + s * 30, 58), CGPointMake(50 + s * 38, 100));
        Stroke([fl copy], HEX(0x0A1426), 1.0);
    }
    // Scarf.
    UIBezierPath *wrap = RoundRect(26, 44, 48, 11, 5.5);
    uint32_t dark = ((scarf >> 1) & 0x7F7F7F);
    LinearFill(c, wrap, @[HEX(scarf), HEX(dark)], CGPointMake(50, 44), CGPointMake(50, 55));
    Stroke([wrap copy], HX(0x000000, .35), 1.0);
    UIBezierPath *tail = RoundRect(60, 50, 9, 22, 3);
    LinearFill(c, tail, @[HEX(scarf), HEX(dark)], CGPointMake(60, 50), CGPointMake(69, 72));
    Stroke([tail copy], HX(0x000000, .35), 1.0);
    for (int k = 0; k < 3; k++) Line(60, 56 + k * 5.5, 69, 56 + k * 5.5, HX(0xFFFFFF, .5), 1.2);
    // Head.
    UIBezierPath *head = Oval(26, 6, 48, 44);
    LinearFill(c, head, @[HEX(0x3A4A66), HEX(0x14213A)], CGPointMake(50, 6), CGPointMake(50, 50));
    Stroke([head copy], HEX(0x0A1426), 1.4);
    UIBezierPath *face = [UIBezierPath bezierPath];
    [face moveToPoint:CGPointMake(50, 22)];
    [face addCurveToPoint:CGPointMake(66, 34) controlPoint1:CGPointMake(60, 18) controlPoint2:CGPointMake(66, 26)];
    [face addCurveToPoint:CGPointMake(50, 48) controlPoint1:CGPointMake(66, 44) controlPoint2:CGPointMake(58, 48)];
    [face addCurveToPoint:CGPointMake(34, 34) controlPoint1:CGPointMake(42, 48) controlPoint2:CGPointMake(34, 44)];
    [face addCurveToPoint:CGPointMake(50, 22) controlPoint1:CGPointMake(34, 26) controlPoint2:CGPointMake(40, 18)];
    [face closePath];
    Fill(face, HEX(0xFFFFFF));
    Fill(Oval(28, 30, 9, 12), HEX(0xFFC93C));      // golden ear patches
    Fill(Oval(63, 30, 9, 12), HEX(0xFFC93C));
    // Eyes.
    for (int side = 0; side < 2; side++) {
        CGFloat x = side == 0 ? 43 : 57;
        Fill(Disc(x, 33, 4.4), HEX(0x0A1426));
        Fill(Disc(x + 1.2, 31.6, 1.5), HEX(0xFFFFFF));
    }
    // Beak and blush.
    UIBezierPath *beak = [UIBezierPath bezierPath];
    [beak moveToPoint:CGPointMake(44, 39)];
    [beak addQuadCurveToPoint:CGPointMake(56, 39) controlPoint:CGPointMake(50, 36)];
    [beak addQuadCurveToPoint:CGPointMake(50, 49) controlPoint:CGPointMake(56, 46)];
    [beak addQuadCurveToPoint:CGPointMake(44, 39) controlPoint:CGPointMake(44, 46)];
    [beak closePath];
    LinearFill(c, beak, @[HEX(0xFFB347), HEX(0xE0701F)], CGPointMake(50, 37), CGPointMake(50, 49));
    Stroke([beak copy], HEX(0x8A3A0A), .8);
    Fill(Oval(36, 40, 7, 4), HX(0xFF8FA0, .5));
    Fill(Oval(57, 40, 7, 4), HX(0xFF8FA0, .5));
    if (crown) {
        UIBezierPath *cr = [UIBezierPath bezierPath];
        [cr moveToPoint:CGPointMake(36, 12)];
        [cr addLineToPoint:CGPointMake(33, -1)];
        [cr addLineToPoint:CGPointMake(43, 6)];
        [cr addLineToPoint:CGPointMake(50, -4)];
        [cr addLineToPoint:CGPointMake(57, 6)];
        [cr addLineToPoint:CGPointMake(67, -1)];
        [cr addLineToPoint:CGPointMake(64, 12)];
        [cr closePath];
        LinearFill(c, cr, @[HEX(0xFFF1A0), HEX(0xE9AE25), HEX(0xA8740B)], CGPointMake(50, -4), CGPointMake(50, 12));
        Stroke([cr copy], HEX(0x6A4606), 1.0);
        Fill(Disc(50, 6, 2.2), HEX(0xE0191F));
        Fill(Disc(40, 8, 1.6), HEX(0x2BB3E8));
        Fill(Disc(60, 8, 1.6), HEX(0x2BB3E8));
    }
}

static UIBezierPath *EggPath(CGFloat cx, CGFloat top, CGFloat bottom, CGFloat halfWidth) {
    CGFloat mid = top + (bottom - top) * 0.58;
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(cx, top)];
    [p addCurveToPoint:CGPointMake(cx + halfWidth, mid) controlPoint1:CGPointMake(cx + halfWidth * .78, top) controlPoint2:CGPointMake(cx + halfWidth, top + (mid - top) * .55)];
    [p addCurveToPoint:CGPointMake(cx, bottom) controlPoint1:CGPointMake(cx + halfWidth, mid + (bottom - mid) * .6) controlPoint2:CGPointMake(cx + halfWidth * .62, bottom)];
    [p addCurveToPoint:CGPointMake(cx - halfWidth, mid) controlPoint1:CGPointMake(cx - halfWidth * .62, bottom) controlPoint2:CGPointMake(cx - halfWidth, mid + (bottom - mid) * .6)];
    [p addCurveToPoint:CGPointMake(cx, top) controlPoint1:CGPointMake(cx - halfWidth, top + (mid - top) * .55) controlPoint2:CGPointMake(cx - halfWidth * .78, top)];
    [p closePath];
    return p;
}

/// A cozy speckled egg (cream with blue spots), `stage` 0 whole / 1 cracked / 2 badly cracked.
static void DrawSpeckledEgg(CGContextRef c, int stage) {
    UIBezierPath *egg = EggPath(50, 6, 94, 34);
    RadialFill(c, egg, @[HEX(0xFFFFFF), HEX(0xF3F0E4), HEX(0xD8D2BC)], CGPointMake(40, 34), 64);
    CGContextSaveGState(c);
    [egg addClip];
    CGFloat spots[9][3] = { {38, 30, 4}, {60, 38, 3.2}, {50, 54, 4.6}, {32, 62, 3}, {66, 66, 4}, {46, 80, 3.4}, {58, 22, 2.4}, {28, 46, 2.2}, {70, 52, 2.2} };
    for (int i = 0; i < 9; i++) Fill(Disc(spots[i][0], spots[i][1], spots[i][2]), HX(0x4A8FD8, .75));
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(50, 58) radius:30 startAngle:M_PI * .15 endAngle:M_PI * .85 clockwise:YES], HX(0x4A8FD8, .35), 5);
    CGContextRestoreGState(c);
    Stroke([egg copy], HEX(0x8A8470), 1.6);
    Fill(Oval(34, 18, 9, 16), HX(0xFFFFFF, .7));
    if (stage >= 1) {
        UIBezierPath *crack = [UIBezierPath bezierPath];
        [crack moveToPoint:CGPointMake(30, 50)];
        [crack addLineToPoint:CGPointMake(40, 58)]; [crack addLineToPoint:CGPointMake(46, 48)];
        [crack addLineToPoint:CGPointMake(54, 60)]; [crack addLineToPoint:CGPointMake(62, 50)]; [crack addLineToPoint:CGPointMake(70, 58)];
        Stroke(crack, HEX(0x3A2A18), 2.2);
    }
    if (stage >= 2) {
        for (NSArray *seg in @[@[@46, @48, @42, @34, @48, @26], @[@54, @60, @58, @74, @52, @84], @[@40, @58, @34, @72, @38, @82]]) {
            UIBezierPath *k = [UIBezierPath bezierPath];
            [k moveToPoint:CGPointMake([seg[0] doubleValue], [seg[1] doubleValue])];
            [k addLineToPoint:CGPointMake([seg[2] doubleValue], [seg[3] doubleValue])];
            [k addLineToPoint:CGPointMake([seg[4] doubleValue], [seg[5] doubleValue])];
            Stroke(k, HEX(0x3A2A18), 2.0);
        }
        RadialFill(c, Oval(40, 50, 22, 14), @[HX(0xFFF1A0, .8), HX(0xFFF1A0, 0)], CGPointMake(51, 57), 14);
    }
}

/// One half of a broken eggshell, 100 x 60 grid. top = YES: the cap; NO: the base cup.
static void DrawShellHalf(CGContextRef c, BOOL top) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    NSArray<NSNumber *> *zig = @[@8, @22, @34, @46, @58, @70, @84, @92];
    if (top) {
        [p moveToPoint:CGPointMake(8, 52)];
        [p addCurveToPoint:CGPointMake(50, 4) controlPoint1:CGPointMake(8, 22) controlPoint2:CGPointMake(28, 4)];
        [p addCurveToPoint:CGPointMake(92, 52) controlPoint1:CGPointMake(72, 4) controlPoint2:CGPointMake(92, 22)];
        for (NSInteger i = zig.count - 1; i >= 0; i--) [p addLineToPoint:CGPointMake(zig[i].doubleValue, (i % 2 == 0) ? 52 : 40)];
    } else {
        [p moveToPoint:CGPointMake(8, 8)];
        for (NSUInteger i = 0; i < zig.count; i++) [p addLineToPoint:CGPointMake(zig[i].doubleValue, (i % 2 == 0) ? 8 : 20)];
        [p addLineToPoint:CGPointMake(92, 8)];
        [p addCurveToPoint:CGPointMake(50, 56) controlPoint1:CGPointMake(92, 38) controlPoint2:CGPointMake(72, 56)];
        [p addCurveToPoint:CGPointMake(8, 8) controlPoint1:CGPointMake(28, 56) controlPoint2:CGPointMake(8, 38)];
    }
    [p closePath];
    LinearFill(c, p, @[HEX(0xFFFFFF), HEX(0xE4DFCB)], CGPointMake(20, top ? 4 : 8), CGPointMake(80, top ? 52 : 56));
    Stroke([p copy], HEX(0x8A8470), 1.4);
    CGContextSaveGState(c);
    [p addClip];
    CGFloat sx[4] = { 24, 52, 70, 38 }, sy[4] = { top ? 22 : 36, top ? 30 : 44, top ? 20 : 34, top ? 40 : 28 };
    for (int i = 0; i < 4; i++) Fill(Disc(sx[i], sy[i], 3.2), HX(0x4A8FD8, .75));
    CGContextRestoreGState(c);
}

#pragma mark - Symbols

static void DrawSnowflake(CGContextRef c) {
    Fill(Disc(50, 50, 42), HX(0x8EC9F2, .22));
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 50, 50);
    for (int k = 0; k < 6; k++) {
        CGContextSaveGState(c);
        CGContextRotateCTM(c, k * M_PI / 3);
        Line(0, 0, 0, -38, HEX(0x1E6FC4), 5.2);
        Line(0, 0, 0, -38, HEX(0x8EDBFF), 2.0);
        Line(0, -24, -11, -35, HEX(0x1E6FC4), 3.6); Line(0, -24, 11, -35, HEX(0x1E6FC4), 3.6);
        Line(0, -24, -11, -35, HEX(0x8EDBFF), 1.4); Line(0, -24, 11, -35, HEX(0x8EDBFF), 1.4);
        Line(0, -13, -7, -20, HEX(0x1E6FC4), 3.0); Line(0, -13, 7, -20, HEX(0x1E6FC4), 3.0);
        Fill(Disc(0, -39, 3.2), HEX(0x1E6FC4));
        Fill(Disc(0, -39, 1.4), HEX(0xE6F6FF));
        CGContextRestoreGState(c);
    }
    UIBezierPath *hex = [UIBezierPath bezierPath];
    for (int k = 0; k < 6; k++) {
        CGFloat a = k * M_PI / 3 + M_PI / 6;
        CGPoint p = CGPointMake(cos(a) * 9, sin(a) * 9);
        if (k == 0) [hex moveToPoint:p]; else [hex addLineToPoint:p];
    }
    [hex closePath];
    RadialFill(c, hex, @[HEX(0xFFFFFF), HEX(0x8EDBFF), HEX(0x1E6FC4)], CGPointMake(-2, -2), 12);
    Stroke([hex copy], HEX(0x14508F), 1.2);
    CGContextRestoreGState(c);
}

static void DrawFish(CGContextRef c) {
    Fill(Oval(14, 84, 72, 7), HX(0x1D3B5C, .18));
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 50, 50);
    CGContextRotateCTM(c, -14 * M_PI / 180.0);
    CGContextTranslateCTM(c, -50, -50);
    UIBezierPath *tail = [UIBezierPath bezierPath];
    [tail moveToPoint:CGPointMake(24, 50)];
    [tail addLineToPoint:CGPointMake(6, 30)]; [tail addQuadCurveToPoint:CGPointMake(10, 50) controlPoint:CGPointMake(14, 40)];
    [tail addQuadCurveToPoint:CGPointMake(6, 70) controlPoint:CGPointMake(14, 60)]; [tail addLineToPoint:CGPointMake(24, 50)];
    LinearFill(c, tail, @[HEX(0x8FB8E8), HEX(0x3F78C0)], CGPointMake(6, 30), CGPointMake(24, 70));
    Stroke([tail copy], HEX(0x1D3B5C), 1.2);
    UIBezierPath *dorsal = [UIBezierPath bezierPath];
    [dorsal moveToPoint:CGPointMake(40, 32)]; [dorsal addQuadCurveToPoint:CGPointMake(64, 32) controlPoint:CGPointMake(52, 16)];
    [dorsal closePath];
    Fill(dorsal, HEX(0x4F86CC)); Stroke([dorsal copy], HEX(0x1D3B5C), 1.1);
    UIBezierPath *body = [UIBezierPath bezierPath];
    [body moveToPoint:CGPointMake(22, 50)];
    [body addCurveToPoint:CGPointMake(70, 30) controlPoint1:CGPointMake(30, 30) controlPoint2:CGPointMake(52, 26)];
    [body addCurveToPoint:CGPointMake(92, 50) controlPoint1:CGPointMake(82, 34) controlPoint2:CGPointMake(90, 44)];
    [body addCurveToPoint:CGPointMake(70, 70) controlPoint1:CGPointMake(90, 58) controlPoint2:CGPointMake(82, 66)];
    [body addCurveToPoint:CGPointMake(22, 50) controlPoint1:CGPointMake(52, 74) controlPoint2:CGPointMake(30, 70)];
    [body closePath];
    LinearFill(c, body, @[HEX(0x5C95DA), HEX(0xBFD9F5), HEX(0xF4FAFF)], CGPointMake(50, 28), CGPointMake(50, 72));
    Stroke([body copy], HEX(0x1D3B5C), 1.5);
    CGContextSaveGState(c);
    [body addClip];
    for (int row = 0; row < 3; row++) for (int col = 0; col < 5; col++) {
        CGFloat x = 36 + col * 10 + (row % 2) * 5, y = 40 + row * 9;
        Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(x, y) radius:5 startAngle:M_PI * .55 endAngle:M_PI * 1.45 clockwise:YES], HX(0x1D3B5C, .35), 1.0);
    }
    CGContextRestoreGState(c);
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(74, 50) radius:11 startAngle:M_PI * .6 endAngle:M_PI * 1.4 clockwise:YES], HX(0x1D3B5C, .6), 1.6);
    Fill(Disc(80, 44, 4.2), HEX(0xFFFFFF)); Fill(Disc(81, 44, 2.3), HEX(0x0A1426));
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(88, 55) radius:3 startAngle:0 endAngle:M_PI clockwise:YES], HEX(0x1D3B5C), 1.2);
    CGContextRestoreGState(c);
    DrawSparkle(14, 18, 5, HX(0xFFFFFF, .95));
}

static void DrawIgloo(CGContextRef c) {
    Fill(Oval(6, 76, 88, 16), HX(0x9ACBEA, .55));
    UIBezierPath *tunnel = RoundRect(54, 62, 34, 26, 12);
    LinearFill(c, tunnel, @[HEX(0xFFFFFF), HEX(0xC4DDF0)], CGPointMake(54, 62), CGPointMake(88, 88));
    Stroke([tunnel copy], HEX(0x4A7AA8), 1.6);
    UIBezierPath *dome = [UIBezierPath bezierPathWithArcCenter:CGPointMake(44, 76) radius:36 startAngle:M_PI endAngle:2 * M_PI clockwise:YES];
    [dome addLineToPoint:CGPointMake(80, 80)]; [dome addLineToPoint:CGPointMake(8, 80)]; [dome closePath];
    RadialFill(c, dome, @[HEX(0xFFFFFF), HEX(0xE0EEF8), HEX(0xA8C9E4)], CGPointMake(32, 50), 60);
    Stroke([dome copy], HEX(0x4A7AA8), 1.8);
    CGContextSaveGState(c);
    [dome addClip];
    for (int row = 1; row < 4; row++) {
        CGFloat y = 76 - row * 11;
        Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(44, 76) radius:(76 - y) + 0.01 startAngle:M_PI endAngle:2 * M_PI clockwise:YES], HX(0x4A7AA8, .55), 1.1);
    }
    for (int col = 0; col < 7; col++) Line(44 + (col - 3) * 10, 76, 44 + (col - 3) * 5, 40, HX(0x4A7AA8, .4), 1.0);
    CGContextRestoreGState(c);
    UIBezierPath *door = [UIBezierPath bezierPath];
    [door moveToPoint:CGPointMake(62, 88)]; [door addLineToPoint:CGPointMake(62, 74)];
    [door addArcWithCenter:CGPointMake(70, 74) radius:8 startAngle:M_PI endAngle:2 * M_PI clockwise:YES]; [door addLineToPoint:CGPointMake(78, 88)]; [door closePath];
    Fill(door, HEX(0x1D3B5C));
    Fill(Oval(60, 84, 20, 6), HX(0xFFFFFF, .7));
    DrawSparkle(14, 20, 5.5, HX(0xFFFFFF, .95));
    DrawSparkle(88, 22, 4.5, HX(0x8EDBFF, .95));
}

static void DrawCocoa(CGContextRef c) {
    Fill(Oval(16, 84, 62, 8), HX(0x1D3B5C, .2));
    UIBezierPath *handle = [UIBezierPath bezierPath];
    [handle moveToPoint:CGPointMake(74, 46)];
    [handle addCurveToPoint:CGPointMake(74, 70) controlPoint1:CGPointMake(96, 44) controlPoint2:CGPointMake(96, 72)];
    Stroke(handle, HEX(0x8E1F1A), 8); Stroke(handle, HEX(0xE0483E), 5);
    UIBezierPath *mug = RoundRect(20, 38, 56, 48, 10);
    LinearFill(c, mug, @[HEX(0xF26A5C), HEX(0xC2312A), HEX(0x8E1F1A)], CGPointMake(20, 38), CGPointMake(76, 86));
    Stroke([mug copy], HEX(0x5A0F0C), 1.6);
    CGContextSaveGState(c);
    [mug addClip];
    for (int k = 0; k < 4; k++) {   // white snowflake dots band
        Fill(Disc(32 + k * 14, 62, 2.6), HX(0xFFFFFF, .9));
        Fill(Disc(39 + k * 14, 72, 2.0), HX(0xFFFFFF, .8));
    }
    Line(20, 54, 76, 54, HX(0xFFFFFF, .85), 3.0);
    CGContextRestoreGState(c);
    UIBezierPath *top = Oval(20, 31, 56, 16);
    LinearFill(c, top, @[HEX(0x7A4A2A), HEX(0x4A2A14)], CGPointMake(48, 31), CGPointMake(48, 47));
    Stroke([top copy], HEX(0x5A0F0C), 1.4);
    for (int k = 0; k < 3; k++) {
        UIBezierPath *mm = RoundRect(30 + k * 12, 29 - (k % 2) * 3, 11, 9, 3);
        LinearFill(c, mm, @[HEX(0xFFFFFF), HEX(0xE4EAF2)], CGPointMake(30 + k * 12, 29), CGPointMake(41 + k * 12, 38));
        Stroke([mm copy], HEX(0x8AA0B8), .9);
    }
    for (int k = 0; k < 2; k++) {
        UIBezierPath *steam = [UIBezierPath bezierPath];
        [steam moveToPoint:CGPointMake(38 + k * 20, 24)];
        [steam addCurveToPoint:CGPointMake(40 + k * 20, 6) controlPoint1:CGPointMake(30 + k * 20, 18) controlPoint2:CGPointMake(48 + k * 20, 12)];
        Stroke(steam, HX(0x7BA3C8, .8), 2.2);
    }
}

static void DrawSeal(CGContextRef c) {
    Fill(Oval(14, 86, 72, 7), HX(0x1D3B5C, .18));
    for (int side = 0; side < 2; side++) {
        CGFloat s = side == 0 ? -1 : 1;
        UIBezierPath *fl = Oval(50 + s * 30 - 11, 72, 22, 14);
        LinearFill(c, fl, @[HEX(0xDDE6EF), HEX(0x9FB2C6)], CGPointMake(50, 72), CGPointMake(50, 86));
        Stroke([fl copy], HEX(0x4A5C70), 1.4);
    }
    UIBezierPath *body = Oval(22, 54, 56, 36);
    LinearFill(c, body, @[HEX(0xF7FAFD), HEX(0xC4D2E0)], CGPointMake(50, 54), CGPointMake(50, 90));
    Stroke([body copy], HEX(0x4A5C70), 1.5);
    UIBezierPath *head = Disc(50, 42, 30);
    RadialFill(c, head, @[HEX(0xFFFFFF), HEX(0xE8EFF6), HEX(0xB4C4D6)], CGPointMake(42, 30), 54);
    Stroke([head copy], HEX(0x4A5C70), 1.6);
    for (int side = 0; side < 2; side++) {
        CGFloat x = side == 0 ? 37 : 63;
        Fill(Disc(x, 38, 6.4), HEX(0x14213A));
        Fill(Disc(x + 1.8, 35.8, 2.3), HEX(0xFFFFFF));
        Fill(Disc(x - 1.4, 40.6, 1.1), HX(0xFFFFFF, .8));
    }
    UIBezierPath *nose = [UIBezierPath bezierPath];
    [nose moveToPoint:CGPointMake(44, 49)]; [nose addQuadCurveToPoint:CGPointMake(56, 49) controlPoint:CGPointMake(50, 45)];
    [nose addQuadCurveToPoint:CGPointMake(44, 49) controlPoint:CGPointMake(50, 58)];
    Fill(nose, HEX(0x2A3448));
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(46, 55) radius:4 startAngle:0 endAngle:M_PI * .9 clockwise:YES], HEX(0x4A5C70), 1.3);
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(54, 55) radius:4 startAngle:M_PI * .1 endAngle:M_PI clockwise:YES], HEX(0x4A5C70), 1.3);
    for (int side = 0; side < 2; side++) {
        CGFloat s = side == 0 ? -1 : 1;
        for (int k = 0; k < 3; k++) Line(50 + s * 8, 52 + k * 2.5, 50 + s * 26, 48 + k * 6, HX(0x4A5C70, .8), .9);
    }
    Fill(Oval(24, 48, 9, 5), HX(0xFF9AAE, .45)); Fill(Oval(67, 48, 9, 5), HX(0xFF9AAE, .45));
    DrawSparkle(12, 16, 5, HX(0xFFFFFF, .95));
}

static void DrawWhale(CGContextRef c) {
    // Waves and spout.
    for (int k = 0; k < 3; k++) {
        CGFloat x = 50 + (k - 1) * 8;
        Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(x, 22) radius:8 startAngle:M_PI endAngle:M_PI * 1.9 clockwise:YES], HEX(0x6FC3F0), 2.6);
    }
    Line(52, 38, 52, 24, HEX(0x6FC3F0), 3.2);
    for (NSArray *d in @[@[@40, @10], @[@66, @12], @[@72, @24]]) Fill(Disc([d[0] doubleValue], [d[1] doubleValue], 2.6), HEX(0x8EDBFF));
    UIBezierPath *tail = [UIBezierPath bezierPath];
    [tail moveToPoint:CGPointMake(24, 66)];
    [tail addCurveToPoint:CGPointMake(6, 40) controlPoint1:CGPointMake(14, 66) controlPoint2:CGPointMake(8, 54)];
    [tail addQuadCurveToPoint:CGPointMake(22, 52) controlPoint:CGPointMake(14, 40)];
    [tail addQuadCurveToPoint:CGPointMake(38, 42) controlPoint:CGPointMake(30, 40)];
    [tail addLineToPoint:CGPointMake(36, 70)];
    [tail closePath];
    LinearFill(c, tail, @[HEX(0x5AA9F0), HEX(0x1F5FB0)], CGPointMake(6, 40), CGPointMake(36, 70));
    Stroke([tail copy], HEX(0x123E7A), 1.5);
    UIBezierPath *body = [UIBezierPath bezierPath];
    [body moveToPoint:CGPointMake(28, 70)];
    [body addCurveToPoint:CGPointMake(70, 38) controlPoint1:CGPointMake(28, 46) controlPoint2:CGPointMake(48, 36)];
    [body addCurveToPoint:CGPointMake(94, 62) controlPoint1:CGPointMake(84, 38) controlPoint2:CGPointMake(94, 50)];
    [body addCurveToPoint:CGPointMake(66, 84) controlPoint1:CGPointMake(94, 76) controlPoint2:CGPointMake(82, 84)];
    [body addCurveToPoint:CGPointMake(28, 70) controlPoint1:CGPointMake(50, 86) controlPoint2:CGPointMake(34, 80)];
    [body closePath];
    LinearFill(c, body, @[HEX(0x6BB6F5), HEX(0x2C7AD0), HEX(0x1F5FB0)], CGPointMake(60, 38), CGPointMake(60, 86));
    Stroke([body copy], HEX(0x123E7A), 1.6);
    CGContextSaveGState(c);
    [body addClip];
    Fill(Oval(34, 66, 66, 24), HEX(0xE6F4FF));
    for (int k = 0; k < 6; k++) Line(46 + k * 8, 70, 46 + k * 8, 80, HX(0x8EC0E8, .8), 1.0);
    CGContextRestoreGState(c);
    Fill(Disc(80, 56, 4), HEX(0xFFFFFF)); Fill(Disc(81, 56, 2.3), HEX(0x0A1426));
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(82, 64) radius:7 startAngle:M_PI * .15 endAngle:M_PI * .7 clockwise:YES], HEX(0x123E7A), 1.5);
    Fill(Oval(70, 62, 7, 4), HX(0xFF9AAE, .5));
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(50, 92) radius:6 startAngle:M_PI endAngle:2 * M_PI clockwise:YES], HEX(0x6FC3F0), 2.0);
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(66, 92) radius:6 startAngle:M_PI endAngle:2 * M_PI clockwise:YES], HEX(0x6FC3F0), 2.0);
}

/// The fluffy hatchling (also used in the bonus).
static void DrawChick(CGContextRef c) {
    Fill(Oval(22, 88, 56, 6), HX(0x1D3B5C, .18));
    for (int side = 0; side < 2; side++) {
        CGFloat s = side == 0 ? -1 : 1;
        Fill(Oval(50 + s * 13 - 8, 84, 16, 7), HEX(0xFF9A3D));
        Stroke(Oval(50 + s * 13 - 8, 84, 16, 7), HEX(0x8A3A0A), 1.0);
    }
    UIBezierPath *body = Oval(20, 44, 60, 46);
    RadialFill(c, body, @[HEX(0xE4E6EE), HEX(0xB4B8C8), HEX(0x8A90A6)], CGPointMake(42, 56), 52);
    Stroke([body copy], HEX(0x4A5068), 1.5);
    for (int k = 0; k < 10; k++) {     // fluffy tufts
        CGFloat a = k * M_PI / 5 + .3;
        Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(50 + cos(a) * 28, 66 + sin(a) * 20) radius:4 startAngle:a + M_PI * .6 endAngle:a + M_PI * 1.4 clockwise:YES], HX(0xFFFFFF, .5), 1.2);
    }
    UIBezierPath *head = Disc(50, 36, 26);
    RadialFill(c, head, @[HEX(0xE4E6EE), HEX(0xB4B8C8), HEX(0x8A90A6)], CGPointMake(42, 26), 48);
    Stroke([head copy], HEX(0x4A5068), 1.5);
    UIBezierPath *mask = [UIBezierPath bezierPath];
    [mask moveToPoint:CGPointMake(50, 30)];
    [mask addCurveToPoint:CGPointMake(70, 42) controlPoint1:CGPointMake(64, 26) controlPoint2:CGPointMake(70, 34)];
    [mask addCurveToPoint:CGPointMake(50, 56) controlPoint1:CGPointMake(70, 52) controlPoint2:CGPointMake(60, 56)];
    [mask addCurveToPoint:CGPointMake(30, 42) controlPoint1:CGPointMake(40, 56) controlPoint2:CGPointMake(30, 52)];
    [mask addCurveToPoint:CGPointMake(50, 30) controlPoint1:CGPointMake(30, 34) controlPoint2:CGPointMake(36, 26)];
    [mask closePath];
    Fill(mask, HEX(0xFFFFFF));
    UIBezierPath *cap = [UIBezierPath bezierPath];
    [cap moveToPoint:CGPointMake(26, 32)];
    [cap addCurveToPoint:CGPointMake(74, 32) controlPoint1:CGPointMake(30, 8) controlPoint2:CGPointMake(70, 8)];
    [cap addQuadCurveToPoint:CGPointMake(50, 28) controlPoint:CGPointMake(62, 26)];
    [cap addQuadCurveToPoint:CGPointMake(26, 32) controlPoint:CGPointMake(38, 26)];
    Fill(cap, HEX(0x1E2A44));
    for (int side = 0; side < 2; side++) {
        CGFloat x = side == 0 ? 41 : 59;
        Fill(Disc(x, 40, 5.4), HEX(0x0A1426)); Fill(Disc(x + 1.6, 38.2, 1.9), HEX(0xFFFFFF));
    }
    UIBezierPath *beak = [UIBezierPath bezierPath];
    [beak moveToPoint:CGPointMake(45, 47)]; [beak addQuadCurveToPoint:CGPointMake(55, 47) controlPoint:CGPointMake(50, 44)];
    [beak addQuadCurveToPoint:CGPointMake(50, 55) controlPoint:CGPointMake(55, 53)]; [beak addQuadCurveToPoint:CGPointMake(45, 47) controlPoint:CGPointMake(45, 53)];
    Fill(beak, HEX(0xFFA23D)); Stroke([beak copy], HEX(0x8A3A0A), .8);
    Fill(Oval(32, 48, 7, 4), HX(0xFF8FA0, .55)); Fill(Oval(61, 48, 7, 4), HX(0xFF8FA0, .55));
    // Tiny eggshell cap perched on top.
    UIBezierPath *shell = [UIBezierPath bezierPath];
    [shell moveToPoint:CGPointMake(36, 14)]; [shell addLineToPoint:CGPointMake(40, 8)]; [shell addLineToPoint:CGPointMake(44, 13)];
    [shell addLineToPoint:CGPointMake(50, 6)]; [shell addLineToPoint:CGPointMake(56, 13)]; [shell addLineToPoint:CGPointMake(60, 8)];
    [shell addLineToPoint:CGPointMake(64, 14)]; [shell addQuadCurveToPoint:CGPointMake(36, 14) controlPoint:CGPointMake(50, -4)];
    Fill(shell, HEX(0xFFFFFF)); Stroke([shell copy], HEX(0x8A8470), 1.1);
    DrawSparkle(14, 18, 5, HX(0xFFFFFF, .95));
}

static void DrawEmperor(CGContextRef c) {
    // Ice-blue glow so the top pay pops.
    RadialFill(c, Disc(50, 52, 48), @[HX(0xBFE6FF, .75), HX(0xBFE6FF, 0)], CGPointMake(50, 52), 48);
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 17, 4);
    CGContextScaleCTM(c, .66, .70);
    DrawPenguinFront(c, 0xE0191F, YES);
    CGContextRestoreGState(c);
    DrawSparkle(12, 20, 6, HX(0xFFFFFF, .95));
    DrawSparkle(90, 28, 5, HX(0xFFE48F, .95));
    DrawSparkle(86, 84, 5.5, HX(0xBFE6FF, .95));
}

static void DrawEggScatter(CGContextRef c) {
    RadialFill(c, Disc(50, 52, 48), @[HX(0xFFF1A0, .7), HX(0xFFC83A, .3), HX(0xFFC83A, 0)], CGPointMake(50, 52), 48);
    UIBezierPath *egg = EggPath(50, 6, 94, 34);
    RadialFill(c, egg, @[HEX(0xFFF6B8), HEX(0xFFC83A), HEX(0xD98E10), HEX(0x9A6A08)], CGPointMake(40, 34), 70);
    CGContextSaveGState(c);
    [egg addClip];
    // Snowflake and zig-zag bands in cream.
    UIBezierPath *zig = [UIBezierPath bezierPath];
    [zig moveToPoint:CGPointMake(14, 62)];
    for (int k = 1; k <= 9; k++) [zig addLineToPoint:CGPointMake(14 + k * 8.2, (k % 2) ? 52 : 62)];
    Stroke(zig, HX(0xFFFFFF, .85), 2.6);
    UIBezierPath *zig2 = [UIBezierPath bezierPath];
    [zig2 moveToPoint:CGPointMake(14, 74)];
    for (int k = 1; k <= 9; k++) [zig2 addLineToPoint:CGPointMake(14 + k * 8.2, (k % 2) ? 66 : 74)];
    Stroke(zig2, HX(0x7A4A00, .6), 2.0);
    for (int k = 0; k < 6; k++) Fill(Disc(50 + cos(k * M_PI / 3) * 7, 36 + sin(k * M_PI / 3) * 7, 1.8), HX(0xFFFFFF, .9));
    Fill(Disc(50, 36, 2.6), HEX(0xFFFFFF));
    CGContextRestoreGState(c);
    Stroke([egg copy], HEX(0x7A4A00), 1.8);
    Fill(Oval(33, 16, 9, 18), HX(0xFFFFFF, .75));
    DrawSparkle(12, 18, 6.5, HX(0xFFFFFF, .95));
    DrawSparkle(90, 78, 5.5, HX(0xFFF6C4, .95));
}

/// An ice floe for the bonus penguins to stand on (100 x 30 grid).
static void DrawFloe(CGContextRef c) {
    UIBezierPath *floe = [UIBezierPath bezierPath];
    [floe moveToPoint:CGPointMake(4, 12)];
    [floe addQuadCurveToPoint:CGPointMake(50, 4) controlPoint:CGPointMake(22, 4)];
    [floe addQuadCurveToPoint:CGPointMake(96, 12) controlPoint:CGPointMake(78, 4)];
    [floe addQuadCurveToPoint:CGPointMake(72, 28) controlPoint:CGPointMake(100, 26)];
    [floe addQuadCurveToPoint:CGPointMake(24, 28) controlPoint:CGPointMake(48, 32)];
    [floe addQuadCurveToPoint:CGPointMake(4, 12) controlPoint:CGPointMake(0, 26)];
    LinearFill(c, floe, @[HEX(0xFFFFFF), HEX(0xBFE0F5), HEX(0x7FB4DC)], CGPointMake(50, 4), CGPointMake(50, 30));
    Stroke([floe copy], HEX(0x4A7AA8), 1.4);
    Fill(Oval(20, 8, 24, 5), HX(0xFFFFFF, .8));
}

#pragma mark - Header scenery

/// The arctic header backdrop on a 400 x 250 grid: night sky, stars, a
/// moon, three aurora ribbons, layered icebergs and a penguin standing
/// on the right-hand berg, all above a snowy shore.
static void DrawBackdrop(CGContextRef c) {
    // Sky.
    UIBezierPath *sky = [UIBezierPath bezierPathWithRect:CGRectMake(0, 0, 400, 250)];
    LinearFill(c, sky, @[HEX(0x0A2C55), HEX(0x12447A), HEX(0x1B5E9E), HEX(0x0A2C55)],
               CGPointMake(200, 0), CGPointMake(200, 250));
    // Stars: fixed pseudo-random scatter so every render matches.
    for (int i = 0; i < 42; i++) {
        CGFloat x = (i * 67 + 23) % 400, y = (i * 41 + 11) % 128;
        CGFloat r = 0.7 + (i % 3) * 0.5;
        Fill(Disc(x, y, r), HX(0xFFFFFF, .3 + (i % 4) * .18));
    }
    // Moon with a soft halo.
    RadialFill(c, Disc(52, 44, 30), @[HX(0xDFF2FF, .5), HX(0xDFF2FF, 0)], CGPointMake(52, 44), 30);
    UIBezierPath *moon = Disc(52, 44, 14);
    RadialFill(c, moon, @[HEX(0xFFFFFF), HEX(0xD5E8F7)], CGPointMake(47, 39), 18);
    Fill(Disc(47, 40, 3), HX(0x9ACBEA, .5));
    Fill(Disc(57, 49, 2.2), HX(0x9ACBEA, .45));
    // Aurora ribbons: wavy bands that fade out at their lower edge,
    // each drawn twice, offset, to soften the fall.
    NSArray<NSArray *> *bands = @[ @[@0x3DFF9A, @46, @.50], @[@0x2BD9C7, @78, @.38], @[@0x8A6CFF, @24, @.26] ];
    for (NSArray *band in bands) {
        uint32_t hex = [band[0] unsignedIntValue];
        CGFloat top = [band[1] doubleValue], alpha = [band[2] doubleValue];
        for (int pass = 0; pass < 2; pass++) {
            CGFloat y0 = top + pass * 7;
            UIBezierPath *ribbon = [UIBezierPath bezierPath];
            [ribbon moveToPoint:CGPointMake(-10, y0 + 18)];
            [ribbon addCurveToPoint:CGPointMake(130, y0 - 8) controlPoint1:CGPointMake(50, y0 - 12) controlPoint2:CGPointMake(80, y0 + 16)];
            [ribbon addCurveToPoint:CGPointMake(280, y0 + 14) controlPoint1:CGPointMake(180, y0 - 22) controlPoint2:CGPointMake(230, y0 + 22)];
            [ribbon addCurveToPoint:CGPointMake(410, y0 - 4) controlPoint1:CGPointMake(330, y0 + 6) controlPoint2:CGPointMake(370, y0 - 14)];
            [ribbon addLineToPoint:CGPointMake(410, y0 + 34)];
            [ribbon addCurveToPoint:CGPointMake(280, y0 + 44) controlPoint1:CGPointMake(360, y0 + 22) controlPoint2:CGPointMake(320, y0 + 48)];
            [ribbon addCurveToPoint:CGPointMake(130, y0 + 24) controlPoint1:CGPointMake(220, y0 + 40) controlPoint2:CGPointMake(180, y0 + 14)];
            [ribbon addCurveToPoint:CGPointMake(-10, y0 + 48) controlPoint1:CGPointMake(70, y0 + 34) controlPoint2:CGPointMake(40, y0 + 40)];
            [ribbon closePath];
            LinearFill(c, ribbon, @[HX(hex, alpha * (pass ? .45 : 1)), HX(hex, 0)],
                       CGPointMake(200, y0 - 14), CGPointMake(200, y0 + 50));
        }
    }
    // Distant berg, centre-left, kept dark so it sits behind the others.
    UIBezierPath *far = [UIBezierPath bezierPath];
    [far moveToPoint:CGPointMake(84, 250)]; [far addLineToPoint:CGPointMake(112, 178)];
    [far addLineToPoint:CGPointMake(150, 156)]; [far addLineToPoint:CGPointMake(188, 182)];
    [far addLineToPoint:CGPointMake(214, 250)]; [far closePath];
    Fill(far, HX(0x2A5A8C, .8));
    // Left berg.
    UIBezierPath *left = [UIBezierPath bezierPath];
    [left moveToPoint:CGPointMake(-6, 250)]; [left addLineToPoint:CGPointMake(-6, 208)];
    [left addLineToPoint:CGPointMake(34, 170)]; [left addLineToPoint:CGPointMake(84, 184)];
    [left addLineToPoint:CGPointMake(118, 208)]; [left addLineToPoint:CGPointMake(128, 250)];
    [left closePath];
    LinearFill(c, left, @[HEX(0xEAF6FF), HEX(0x9CC8EA)], CGPointMake(50, 168), CGPointMake(50, 250));
    UIBezierPath *leftRidge = [UIBezierPath bezierPath];
    [leftRidge moveToPoint:CGPointMake(-6, 208)]; [leftRidge addLineToPoint:CGPointMake(34, 170)];
    [leftRidge addLineToPoint:CGPointMake(84, 184)]; [leftRidge addLineToPoint:CGPointMake(118, 208)];
    Stroke(leftRidge, HX(0xFFFFFF, .9), 3);
    // Right berg, the big one the penguin stands on.
    UIBezierPath *right = [UIBezierPath bezierPath];
    [right moveToPoint:CGPointMake(238, 250)]; [right addLineToPoint:CGPointMake(262, 178)];
    [right addLineToPoint:CGPointMake(300, 152)]; [right addLineToPoint:CGPointMake(344, 166)];
    [right addLineToPoint:CGPointMake(378, 158)]; [right addLineToPoint:CGPointMake(406, 192)];
    [right addLineToPoint:CGPointMake(406, 250)]; [right closePath];
    LinearFill(c, right, @[HEX(0xF2FAFF), HEX(0x8FC0E8)], CGPointMake(320, 150), CGPointMake(320, 250));
    UIBezierPath *rightRidge = [UIBezierPath bezierPath];
    [rightRidge moveToPoint:CGPointMake(262, 178)]; [rightRidge addLineToPoint:CGPointMake(300, 152)];
    [rightRidge addLineToPoint:CGPointMake(344, 166)]; [rightRidge addLineToPoint:CGPointMake(378, 158)];
    [rightRidge addLineToPoint:CGPointMake(406, 192)];
    Stroke(rightRidge, HX(0xFFFFFF, .95), 3.5);
    // The penguin, feet planted on the ridge between the two peaks.
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 297, 90);
    CGContextScaleCTM(c, .56, .56);
    DrawPenguinFront(c, 0xE0191F, NO);
    CGContextRestoreGState(c);
    // Snowy shore along the bottom.
    UIBezierPath *sea = [UIBezierPath bezierPathWithRect:CGRectMake(0, 216, 400, 34)];
    LinearFill(c, sea, @[HX(0x1E6FB0, .55), HX(0x041226, .95)], CGPointMake(200, 216), CGPointMake(200, 250));
    Fill(Oval(-16, 208, 120, 20), HX(0xFFFFFF, .92));
    Fill(Oval(96, 214, 130, 18), HX(0xEAF6FF, .9));
    Fill(Oval(214, 210, 120, 20), HX(0xFFFFFF, .92));
    Fill(Oval(322, 215, 110, 17), HX(0xEAF6FF, .9));
    DrawSparkle(150, 60, 6, HX(0xFFFFFF, .95));
    DrawSparkle(238, 96, 5, HX(0xBFE6FF, .9));
    DrawSparkle(36, 128, 5, HX(0xFFFFFF, .85));
}

/// Snow drifts on a 400 x 36 grid, bottoms aligned so the strip can sit
/// on a top edge and read as snow settled on it.
static void DrawSnowCap(CGContextRef c) {
    NSArray<NSArray *> *drifts = @[ @[@-12, @12, @96, @30], @[@58, @5, @116, @38], @[@148, @13, @96, @29],
                                    @[@218, @7, @124, @35], @[@318, @11, @104, @30] ];
    for (NSArray *d in drifts) {
        UIBezierPath *drift = Oval([d[0] doubleValue], [d[1] doubleValue], [d[2] doubleValue], [d[3] doubleValue]);
        RadialFill(c, drift, @[HEX(0xFFFFFF), HEX(0xD5E8F7)], CGPointMake([d[0] doubleValue] + [d[2] doubleValue] / 2, [d[1] doubleValue] + 4), [d[2] doubleValue] * .55);
    }
    Fill([UIBezierPath bezierPathWithRect:CGRectMake(0, 33.5, 400, 2.5)], HX(0x4A7AA8, .3));
    DrawSparkle(70, 10, 4.5, HX(0xFFFFFF, .95));
    DrawSparkle(212, 8, 4, HX(0xFFFFFF, .9));
    DrawSparkle(332, 13, 4.5, HX(0xBFE6FF, .95));
}

#pragma mark - Public API

static NSCache<NSString *, UIImage *> *ArtCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 60; });
    return cache;
}

/// Renders `draw` on a (gw x gh) design grid scaled to `size`, cached under `key`.
static UIImage *Rendered(NSString *key, CGSize size, CGFloat gw, CGFloat gh, void (^draw)(CGContextRef)) {
    if (size.width < 1 || size.height < 1) return nil;
    NSString *full = [NSString stringWithFormat:@"%@-%.0fx%.0f", key, size.width, size.height];
    UIImage *cached = [ArtCache() objectForKey:full];
    if (cached) return cached;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextScaleCTM(c, size.width / gw, size.height / gh);
        draw(c);
    }];
    [ArtCache() setObject:image forKey:full];
    return image;
}

@implementation BRPenguinParadeArt

+ (NSString *)nameForSymbol:(PGSymbol)symbol {
    switch (symbol) {
        case PGSymbolSnowflake: return @"Snowflake";
        case PGSymbolFish: return @"Fish";
        case PGSymbolIgloo: return @"Igloo";
        case PGSymbolCocoa: return @"Hot Cocoa";
        case PGSymbolSeal: return @"Seal";
        case PGSymbolWhale: return @"Whale";
        case PGSymbolChick: return @"Chick";
        case PGSymbolEmperor: return @"Emperor Penguin";
        case PGSymbolEgg: return @"Golden Egg";
        default: return @"";
    }
}

+ (UIImage *)imageForSymbol:(PGSymbol)symbol size:(CGSize)size {
    if (symbol < 0 || symbol >= PGSymbolCount) return nil;
    return Rendered([NSString stringWithFormat:@"s%d", (int)symbol], size, 100, 100, ^(CGContextRef c) {
        switch (symbol) {
            case PGSymbolSnowflake: DrawSnowflake(c); break;
            case PGSymbolFish: DrawFish(c); break;
            case PGSymbolIgloo: DrawIgloo(c); break;
            case PGSymbolCocoa: DrawCocoa(c); break;
            case PGSymbolSeal: DrawSeal(c); break;
            case PGSymbolWhale: DrawWhale(c); break;
            case PGSymbolChick: DrawChick(c); break;
            case PGSymbolEmperor: DrawEmperor(c); break;
            case PGSymbolEgg: DrawEggScatter(c); break;
            default: break;
        }
    });
}

+ (UIImage *)bonusPenguinWithVariant:(NSInteger)variant size:(CGSize)size {
    static const uint32_t scarves[3] = { 0xE0191F, 0x2BA84A, 0x8A3FD0 };
    NSInteger v = MAX(0, MIN(2, variant));
    return Rendered([NSString stringWithFormat:@"pen%ld", (long)v], size, 100, 140, ^(CGContextRef c) {
        DrawPenguinFront(c, scarves[v], NO);
    });
}

+ (UIImage *)eggWithStage:(NSInteger)stage size:(CGSize)size {
    NSInteger st = MAX(0, MIN(2, stage));
    return Rendered([NSString stringWithFormat:@"egg%ld", (long)st], size, 100, 100, ^(CGContextRef c) {
        DrawSpeckledEgg(c, (int)st);
    });
}

+ (UIImage *)shellHalfTop:(BOOL)top size:(CGSize)size {
    return Rendered(top ? @"shellT" : @"shellB", size, 100, 60, ^(CGContextRef c) { DrawShellHalf(c, top); });
}

+ (UIImage *)hatchlingWithSize:(CGSize)size {
    return Rendered(@"chick", size, 100, 100, ^(CGContextRef c) { DrawChick(c); });
}

+ (UIImage *)floeWithSize:(CGSize)size {
    return Rendered(@"floe", size, 100, 30, ^(CGContextRef c) { DrawFloe(c); });
}

+ (UIImage *)arcticBackdropWithSize:(CGSize)size {
    return Rendered(@"backdrop", size, 400, 250, ^(CGContextRef c) { DrawBackdrop(c); });
}

+ (UIImage *)snowCapWithSize:(CGSize)size {
    return Rendered(@"snowcap", size, 400, 36, ^(CGContextRef c) { DrawSnowCap(c); });
}

+ (void)purgeCache { [ArtCache() removeAllObjects]; }

@end
