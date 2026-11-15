// BRPhoenixPavilionArt.m
// EZCompleteUI — Phoenix Pavilion (凤凰阁) slot
//
// Symbol illustrations drawn in code on a 100 x 100 grid. A respectful nod to
// traditional Chinese motifs: a red envelope sealed with 福, a celadon tea set,
// a peony, a three-tier pagoda, a crane before the red sun, a jade ruyi
// scepter, a string of cash coins, the phoenix, and the golden official's cap
// (with peacock plumes) that serves as the scatter.

#import "BRPhoenixPavilionArt.h"

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

/// A tapered, pointed plume (feather / leaf) from `base`, pointing `degrees`
/// clockwise from +x, filled from `from` at the quill to `to` at the tip.
static void DrawPlume(CGContextRef c, CGPoint base, CGFloat length, CGFloat degrees, CGFloat width, UIColor *from, UIColor *to, BOOL eye) {
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, base.x, base.y);
    CGContextRotateCTM(c, degrees * M_PI / 180.0);
    UIBezierPath *plume = [UIBezierPath bezierPath];
    [plume moveToPoint:CGPointZero];
    [plume addQuadCurveToPoint:CGPointMake(length, 0) controlPoint:CGPointMake(length * .55, -width)];
    [plume addQuadCurveToPoint:CGPointZero controlPoint:CGPointMake(length * .55, width)];
    LinearFill(c, plume, @[from, to], CGPointMake(0, 0), CGPointMake(length, 0));
    Stroke([plume copy], HX(0x4A1208, .7), .7);
    Line(0, 0, length * .9, 0, HX(0xFFF1B0, .55), .6);
    if (eye) {
        CGFloat ex = length * .74;
        Fill(Oval(ex - width * .5, -width * .34, width, width * .68), HEX(0xF2C14E));
        Fill(Disc(ex, 0, width * .22), HEX(0x138E86));
        Fill(Disc(ex, 0, width * .09), HEX(0x063C34));
    }
    CGContextRestoreGState(c);
}

#pragma mark - Symbols

static void DrawEnvelope(CGContextRef c) {
    Fill(Oval(26, 88, 50, 7), HX(0x000000, .2));
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 50, 52);
    CGContextRotateCTM(c, -7 * M_PI / 180.0);
    CGContextTranslateCTM(c, -50, -52);

    UIBezierPath *body = RoundRect(24, 8, 52, 82, 6);
    LinearFill(c, body, @[HEX(0xF5434A), HEX(0xC0121F), HEX(0x8E0A14)], CGPointMake(28, 8), CGPointMake(74, 90));
    Stroke([body copy], HEX(0x6E0610), 1.4);
    Stroke(RoundRect(28.5, 12.5, 43, 73, 3.5), HX(0xF2C14E, .85), 1.0);

    // Flap: a swooping curve with a gold edge.
    UIBezierPath *flap = [UIBezierPath bezierPath];
    [flap moveToPoint:CGPointMake(24, 14)];
    [flap addLineToPoint:CGPointMake(24, 30)];
    [flap addQuadCurveToPoint:CGPointMake(76, 30) controlPoint:CGPointMake(50, 66)];
    [flap addLineToPoint:CGPointMake(76, 14)];
    [flap addQuadCurveToPoint:CGPointMake(24, 14) controlPoint:CGPointMake(50, 2)];
    [flap closePath];
    LinearFill(c, flap, @[HEX(0xE02A33), HEX(0x9C0E19)], CGPointMake(50, 8), CGPointMake(50, 54));
    UIBezierPath *edge = [UIBezierPath bezierPath];
    [edge moveToPoint:CGPointMake(24, 30)];
    [edge addQuadCurveToPoint:CGPointMake(76, 30) controlPoint:CGPointMake(50, 66)];
    Stroke(edge, HEX(0xF2C14E), 1.8);

    // Gold seal with 福.
    RadialFill(c, Disc(50, 45, 12.5), @[HEX(0xFFF6B8), HEX(0xE9AE25), HEX(0xA8740B)], CGPointMake(46, 41), 16);
    Stroke(Disc(50, 45, 12.5), HEX(0x7A5206), 1.0);
    DrawGlyph(@"福", CGRectMake(38, 33, 24, 24), 17, HEX(0xA10F1A));

    // Little gold coins along the bottom.
    for (int i = 0; i < 3; i++) {
        CGFloat cx = 38 + i * 12;
        Fill(Disc(cx, 76, 4.2), HEX(0xF2C14E));
        Stroke(Disc(cx, 76, 4.2), HEX(0x7A5206), .6);
        Fill(RoundRect(cx - 1.2, 74.8, 2.4, 2.4, .3), HEX(0x8E0A14));
    }
    CGContextRestoreGState(c);
    DrawSparkle(14, 18, 6, HX(0xFFE48F, .95));
    DrawSparkle(88, 70, 5, HX(0xFFE48F, .9));
}

static void DrawTea(CGContextRef c) {
    Fill(Oval(14, 86, 72, 8), HX(0x000000, .2));
    // Saucer tray.
    UIBezierPath *tray = Oval(12, 82, 76, 11);
    LinearFill(c, tray, @[HEX(0xFFE48F), HEX(0xB8820F)], CGPointMake(50, 82), CGPointMake(50, 93));
    Stroke([tray copy], HEX(0x7A5206), .9);

    // Spout, then handle, then body over them.
    UIBezierPath *spout = [UIBezierPath bezierPath];
    [spout moveToPoint:CGPointMake(70, 62)];
    [spout addCurveToPoint:CGPointMake(93, 36) controlPoint1:CGPointMake(84, 64) controlPoint2:CGPointMake(90, 50)];
    [spout addLineToPoint:CGPointMake(86, 33)];
    [spout addCurveToPoint:CGPointMake(70, 50) controlPoint1:CGPointMake(82, 46) controlPoint2:CGPointMake(76, 50)];
    [spout closePath];
    LinearFill(c, spout, @[HEX(0x6FD9B8), HEX(0x1B8F72)], CGPointMake(70, 40), CGPointMake(90, 62));
    Stroke([spout copy], HEX(0x0B4F45), 1.2);

    UIBezierPath *handle = [UIBezierPath bezierPath];
    [handle moveToPoint:CGPointMake(25, 52)];
    [handle addCurveToPoint:CGPointMake(26, 74) controlPoint1:CGPointMake(4, 50) controlPoint2:CGPointMake(6, 76)];
    Stroke(handle, HEX(0x0B4F45), 8.5);
    Stroke(handle, HEX(0x2BB391), 5.5);
    Stroke(handle, HX(0xFFFFFF, .35), 1.2);

    UIBezierPath *body = Oval(20, 40, 56, 46);
    RadialFill(c, body, @[HEX(0xBFF5E0), HEX(0x4FCBA6), HEX(0x168A70), HEX(0x0B4F45)], CGPointMake(40, 54), 52);
    Stroke([body copy], HEX(0x0B4F45), 1.4);
    // Gold bands and a plum blossom medallion.
    UIBezierPath *band = [UIBezierPath bezierPathWithArcCenter:CGPointMake(48, 63) radius:26 startAngle:.35 * M_PI endAngle:.65 * M_PI clockwise:YES];
    Stroke(band, HX(0xF2C14E, .9), 1.6);
    Fill(Disc(48, 60, 10.5), HX(0xFFF8E7, .92));
    Stroke(Disc(48, 60, 10.5), HEX(0xE0A41F), 1.0);
    DrawBlossom(c, CGPointMake(48, 60), 8);

    // Lid and knob.
    UIBezierPath *lid = [UIBezierPath bezierPath];
    [lid moveToPoint:CGPointMake(30, 42)];
    [lid addCurveToPoint:CGPointMake(66, 42) controlPoint1:CGPointMake(32, 24) controlPoint2:CGPointMake(64, 24)];
    [lid closePath];
    LinearFill(c, lid, @[HEX(0x7BE3C2), HEX(0x168A70)], CGPointMake(44, 26), CGPointMake(56, 42));
    Stroke([lid copy], HEX(0x0B4F45), 1.2);
    Stroke(Oval(28, 39.5, 40, 6), HEX(0xE0A41F), 1.8);
    RadialFill(c, Disc(48, 27, 4.2), @[HEX(0xFFF6B8), HEX(0xE0A41F), HEX(0x9A6A08)], CGPointMake(46.5, 25.5), 6);
    Stroke(Disc(48, 27, 4.2), HEX(0x7A5206), .8);

    // Steam.
    for (NSNumber *dx in @[@0, @7]) {
        UIBezierPath *steam = [UIBezierPath bezierPath];
        CGFloat x = 88 + dx.doubleValue;
        [steam moveToPoint:CGPointMake(x - 6, 28)];
        [steam addCurveToPoint:CGPointMake(x - 4, 8) controlPoint1:CGPointMake(x - 14, 22) controlPoint2:CGPointMake(x + 4, 14)];
        Stroke(steam, HX(0xB9A98A, .85), 1.8);
    }
    DrawSparkle(14, 26, 5.5, HX(0xFFE48F, .95));
}

static void DrawPeony(CGContextRef c) {
    DrawLeaf(c, CGPointMake(50, 84), 38, 200, 9);
    DrawLeaf(c, CGPointMake(50, 84), 38, 340, 9);
    DrawLeaf(c, CGPointMake(50, 86), 30, 245, 7);
    DrawLeaf(c, CGPointMake(50, 86), 30, 295, 7);

    CGPoint ctr = CGPointMake(50, 46);
    struct { int count; CGFloat dist, radius, offset; uint32_t a, b, d; } rings[3] = {
        { 8, 22, 15, 0,    0xFFE6EE, 0xFF8FB1, 0xD13A6B },
        { 6, 14, 12.5, 30, 0xFFC4D6, 0xF2557F, 0xB82458 },
        { 5, 7.5, 9.5, 12, 0xFFA3C0, 0xE0386A, 0x9C1A47 },
    };
    for (int ring = 0; ring < 3; ring++) {
        for (int k = 0; k < rings[ring].count; k++) {
            CGFloat angle = (rings[ring].offset + k * 360.0 / rings[ring].count - 90) * M_PI / 180.0;
            CGPoint pc = CGPointMake(ctr.x + cos(angle) * rings[ring].dist, ctr.y + sin(angle) * rings[ring].dist);
            RadialFill(c, Disc(pc.x, pc.y, rings[ring].radius), @[HEX(rings[ring].a), HEX(rings[ring].b), HEX(rings[ring].d)], CGPointMake(pc.x - rings[ring].radius * .2, pc.y - rings[ring].radius * .2), rings[ring].radius * 1.25);
            Stroke(Disc(pc.x, pc.y, rings[ring].radius), HX(0x8A1740, .55), .7);
        }
    }
    RadialFill(c, Disc(ctr.x, ctr.y, 5.2), @[HEX(0xFFF6B8), HEX(0xF2C14E), HEX(0xB57A0B)], ctr, 6);
    for (int k = 0; k < 8; k++) {
        CGFloat a = k * M_PI / 4;
        Fill(Disc(ctr.x + cos(a) * 3.4, ctr.y + sin(a) * 3.4, .7), HEX(0x7A3A00));
    }
    DrawSparkle(12, 16, 5.5, HX(0xFFE48F, .95));
    DrawSparkle(90, 84, 5, HX(0xFFE48F, .9));
}

static void DrawEave(CGContextRef c, CGFloat cx, CGFloat top, CGFloat bottom, CGFloat halfWidth) {
    UIBezierPath *roof = [UIBezierPath bezierPath];
    [roof moveToPoint:CGPointMake(cx - halfWidth, bottom - 3)];
    [roof addQuadCurveToPoint:CGPointMake(cx - halfWidth * .38, top) controlPoint:CGPointMake(cx - halfWidth * .72, bottom - 2)];
    [roof addLineToPoint:CGPointMake(cx + halfWidth * .38, top)];
    [roof addQuadCurveToPoint:CGPointMake(cx + halfWidth, bottom - 3) controlPoint:CGPointMake(cx + halfWidth * .72, bottom - 2)];
    [roof addQuadCurveToPoint:CGPointMake(cx - halfWidth, bottom - 3) controlPoint:CGPointMake(cx, bottom + 3.5)];
    [roof closePath];
    LinearFill(c, roof, @[HEX(0x4FD1A8), HEX(0x168A70), HEX(0x0B4F45)], CGPointMake(cx, top), CGPointMake(cx, bottom + 3));
    Stroke([roof copy], HEX(0x063C34), 1.0);
    UIBezierPath *trim = [UIBezierPath bezierPath];
    [trim moveToPoint:CGPointMake(cx - halfWidth + 1.5, bottom - 2.4)];
    [trim addQuadCurveToPoint:CGPointMake(cx + halfWidth - 1.5, bottom - 2.4) controlPoint:CGPointMake(cx, bottom + 2.6)];
    Stroke(trim, HEX(0xF2C14E), 1.2);
    Fill(Disc(cx - halfWidth, bottom - 3, 1.7), HEX(0xF2C14E));
    Fill(Disc(cx + halfWidth, bottom - 3, 1.7), HEX(0xF2C14E));
    for (int k = 1; k < 4; k++) Line(cx - halfWidth * .38 + k * halfWidth * .19, top + .8, cx - halfWidth * .38 + k * halfWidth * .22 + (k - 2) * halfWidth * .1, bottom - 3, HX(0x063C34, .35), .6);
}

static void DrawPagoda(CGContextRef c) {
    Fill(Oval(10, 89, 80, 7), HX(0x000000, .2));
    UIBezierPath *base = RoundRect(12, 86, 76, 8, 2.5);
    LinearFill(c, base, @[HEX(0xE9D9B3), HEX(0xA99567)], CGPointMake(50, 86), CGPointMake(50, 94));
    Stroke([base copy], HEX(0x6A5632), .9);

    // Spire.
    Line(50, 8, 50, 32, HEX(0xB8820F), 2.2);
    for (int k = 0; k < 3; k++) {
        UIBezierPath *ring = Oval(46.5, 13 + k * 5.6, 7, 3.4);
        LinearFill(c, ring, @[HEX(0xFFE48F), HEX(0xB8820F)], CGPointMake(50, 13 + k * 5.6), CGPointMake(50, 16.4 + k * 5.6));
        Stroke([ring copy], HEX(0x7A5206), .6);
    }
    RadialFill(c, Disc(50, 8, 3.2), @[HEX(0xFFF6B8), HEX(0xE0A41F), HEX(0x9A6A08)], CGPointMake(49, 7), 4.5);

    CGFloat tops[3] = { 30, 47, 66 }, bottoms[3] = { 39, 57, 77 };
    CGFloat halfRoof[3] = { 20, 28, 36 }, halfBody[3] = { 9, 13, 17 }, bodyBottom[3] = { 47, 66, 86 };
    for (int i = 0; i < 3; i++) {
        UIBezierPath *wall = RoundRect(50 - halfBody[i], bottoms[i] - 1, halfBody[i] * 2, bodyBottom[i] - bottoms[i] + 1, 1.2);
        LinearFill(c, wall, @[HEX(0xE5303A), HEX(0x8E0F18)], CGPointMake(50, bottoms[i]), CGPointMake(50, bodyBottom[i]));
        Stroke([wall copy], HEX(0x5A0610), .9);
        // Gold pillars and a dark arched window.
        Line(50 - halfBody[i] + 2, bottoms[i], 50 - halfBody[i] + 2, bodyBottom[i], HX(0xF2C14E, .9), 1.1);
        Line(50 + halfBody[i] - 2, bottoms[i], 50 + halfBody[i] - 2, bodyBottom[i], HX(0xF2C14E, .9), 1.1);
        CGFloat wh = (bodyBottom[i] - bottoms[i]) * .62, ww = halfBody[i] * .7;
        UIBezierPath *window = [UIBezierPath bezierPath];
        [window moveToPoint:CGPointMake(50 - ww / 2, bodyBottom[i] - 1.2)];
        [window addLineToPoint:CGPointMake(50 - ww / 2, bodyBottom[i] - wh + ww / 2)];
        [window addArcWithCenter:CGPointMake(50, bodyBottom[i] - wh + ww / 2) radius:ww / 2 startAngle:M_PI endAngle:2 * M_PI clockwise:YES];
        [window addLineToPoint:CGPointMake(50 + ww / 2, bodyBottom[i] - 1.2)];
        [window closePath];
        Fill(window, HEX(0x2A0509));
        Stroke([window copy], HEX(0xF2C14E), .6);
        DrawEave(c, 50, tops[i], bottoms[i], halfRoof[i]);
    }
    DrawSparkle(12, 24, 5.5, HX(0xFFE48F, .95));
    DrawSparkle(89, 38, 5, HX(0xFFE48F, .9));
}

static void DrawCrane(CGContextRef c) {
    // Red sun.
    RadialFill(c, Disc(56, 42, 33), @[HEX(0xFFB46B), HEX(0xFF6A3D), HEX(0xD4161E)], CGPointMake(50, 34), 40);
    Stroke(Disc(56, 42, 33), HEX(0x8E0A12), 1.2);

    // Legs: one planted, one tucked.
    Line(52, 72, 50, 95, HEX(0x3A2A2A), 2.2);
    Line(48, 94, 56, 94, HEX(0x3A2A2A), 1.6);
    UIBezierPath *tucked = [UIBezierPath bezierPath];
    [tucked moveToPoint:CGPointMake(58, 72)];
    [tucked addLineToPoint:CGPointMake(68, 80)];
    [tucked addLineToPoint:CGPointMake(62, 88)];
    Stroke(tucked, HEX(0x3A2A2A), 1.8);

    // Neck (outlined), then head and beak.
    UIBezierPath *neck = [UIBezierPath bezierPath];
    [neck moveToPoint:CGPointMake(64, 54)];
    [neck addCurveToPoint:CGPointMake(74, 22) controlPoint1:CGPointMake(78, 48) controlPoint2:CGPointMake(58, 34)];
    Stroke(neck, HEX(0x4A5866), 9);
    Stroke(neck, HEX(0xFFFFFF), 6.2);
    UIBezierPath *beak = [UIBezierPath bezierPath];
    [beak moveToPoint:CGPointMake(78, 19.5)];
    [beak addLineToPoint:CGPointMake(95, 24)];
    [beak addLineToPoint:CGPointMake(78, 26)];
    [beak closePath];
    LinearFill(c, beak, @[HEX(0xF2C14E), HEX(0xA8740B)], CGPointMake(78, 20), CGPointMake(95, 26));
    Stroke([beak copy], HEX(0x4A2A00), .8);
    Fill(Disc(74, 22, 6.5), HEX(0xFFFFFF));
    Stroke(Disc(74, 22, 6.5), HEX(0x4A5866), 1.1);
    Fill(Oval(68, 14.5, 10, 6), HEX(0xD4161E));
    Fill(Disc(76, 22, 1.4), HEX(0x1A1A1A));

    // Body and folded wing.
    UIBezierPath *body = [UIBezierPath bezierPath];
    [body moveToPoint:CGPointMake(66, 50)];
    [body addCurveToPoint:CGPointMake(24, 62) controlPoint1:CGPointMake(56, 44) controlPoint2:CGPointMake(36, 48)];
    [body addCurveToPoint:CGPointMake(46, 78) controlPoint1:CGPointMake(24, 72) controlPoint2:CGPointMake(36, 80)];
    [body addCurveToPoint:CGPointMake(66, 50) controlPoint1:CGPointMake(56, 76) controlPoint2:CGPointMake(70, 64)];
    [body closePath];
    LinearFill(c, body, @[HEX(0xFFFFFF), HEX(0xDCE4EE)], CGPointMake(50, 48), CGPointMake(46, 80));
    Stroke([body copy], HEX(0x4A5866), 1.3);
    UIBezierPath *wing = [UIBezierPath bezierPath];
    [wing moveToPoint:CGPointMake(58, 54)];
    [wing addCurveToPoint:CGPointMake(30, 70) controlPoint1:CGPointMake(46, 52) controlPoint2:CGPointMake(34, 58)];
    [wing addCurveToPoint:CGPointMake(52, 72) controlPoint1:CGPointMake(38, 76) controlPoint2:CGPointMake(46, 76)];
    [wing addCurveToPoint:CGPointMake(58, 54) controlPoint1:CGPointMake(60, 68) controlPoint2:CGPointMake(62, 60)];
    [wing closePath];
    Fill(wing, HX(0xE7EDF5, .95));
    Stroke([wing copy], HX(0x4A5866, .6), .8);
    // Black wing and tail tips.
    for (int k = 0; k < 4; k++) DrawPlume(c, CGPointMake(36 + k * 2.2, 68 + k * .6), 17, 166 + k * 11, 3.4, HEX(0x2A2A32), HEX(0x0E0E12), NO);
    DrawSparkle(12, 18, 5.5, HX(0xFFE48F, .95));
    DrawSparkle(90, 78, 5, HX(0xFFE48F, .9));
}

static void DrawRuyi(CGContextRef c) {
    Fill(Oval(14, 89, 50, 6), HX(0x000000, .18));
    // Shaft: an S-curve in jade.
    UIBezierPath *shaft = [UIBezierPath bezierPath];
    [shaft moveToPoint:CGPointMake(22, 88)];
    [shaft addCurveToPoint:CGPointMake(58, 44) controlPoint1:CGPointMake(46, 86) controlPoint2:CGPointMake(30, 56)];
    Stroke(shaft, HEX(0x0B4F45), 10);
    Stroke(shaft, HEX(0x2BB391), 7);
    Stroke(shaft, HEX(0x8FE9CC), 2.2);

    // Cloud head: outline every lobe first, then fill so inner seams vanish.
    CGPoint lobes[3] = { {70, 26}, {54, 36}, {83, 40} };
    CGFloat radii[3] = { 15, 12, 12 };
    for (int i = 0; i < 3; i++) Stroke(Disc(lobes[i].x, lobes[i].y, radii[i]), HEX(0x0B4F45), 3.2);
    for (int i = 0; i < 3; i++) RadialFill(c, Disc(lobes[i].x, lobes[i].y, radii[i]), @[HEX(0xB6F5DD), HEX(0x3FC7A0), HEX(0x168A70)], CGPointMake(lobes[i].x - 4, lobes[i].y - 4), radii[i] * 1.4);
    RadialFill(c, Oval(56, 33, 32, 16), @[HEX(0x3FC7A0), HEX(0x168A70)], CGPointMake(72, 40), 20);
    UIBezierPath *swirl = [UIBezierPath bezierPathWithArcCenter:CGPointMake(70, 26) radius:7 startAngle:M_PI * .2 endAngle:M_PI * 1.7 clockwise:YES];
    Stroke(swirl, HEX(0xF2C14E), 1.5);
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(54, 36) radius:5 startAngle:M_PI * .3 endAngle:M_PI * 1.6 clockwise:YES], HX(0xF2C14E, .9), 1.2);
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(83, 40) radius:5 startAngle:M_PI * .3 endAngle:M_PI * 1.6 clockwise:YES], HX(0xF2C14E, .9), 1.2);

    // Gold bead and red tassel.
    RadialFill(c, Disc(22, 88, 4.4), @[HEX(0xFFF6B8), HEX(0xE0A41F), HEX(0x9A6A08)], CGPointMake(20.5, 86.5), 6);
    Stroke(Disc(22, 88, 4.4), HEX(0x7A5206), .7);
    for (int i = -3; i <= 3; i++) Line(22 + i * 1.2, 91, 22 + i * 2.6, 99, (i % 2) ? HEX(0xE0191F) : HEX(0xF2C14E), 1.3);
    DrawSparkle(14, 22, 5.5, HX(0xFFE48F, .95));
    DrawSparkle(90, 66, 5, HX(0xFFE48F, .9));
}

static void DrawCoinDisc(CGContextRef c, CGPoint ctr, CGFloat r, BOOL glyphs) {
    RadialFill(c, Disc(ctr.x, ctr.y, r), @[HEX(0xFFF6B8), HEX(0xE9AE25), HEX(0x9A6A08)], CGPointMake(ctr.x - r * .3, ctr.y - r * .3), r * 1.35);
    Stroke(Disc(ctr.x, ctr.y, r), HEX(0x6A4606), 1.3);
    Stroke(Disc(ctr.x, ctr.y, r - 3.2), HX(0x6A4606, .55), .8);
    CGFloat h = r * .24;
    UIBezierPath *hole = RoundRect(ctr.x - h, ctr.y - h, h * 2, h * 2, .8);
    Fill(hole, HEX(0x3A1A04));
    Stroke([hole copy], HEX(0xFFE48F), .8);
    if (glyphs) {
        CGFloat d = r * .62, gs = r * .42;
        DrawGlyph(@"開", CGRectMake(ctr.x - gs, ctr.y - d - gs * .6, gs * 2, gs * 1.2), gs, HEX(0x6A4606));
        DrawGlyph(@"通", CGRectMake(ctr.x - gs, ctr.y + d - gs * .6, gs * 2, gs * 1.2), gs, HEX(0x6A4606));
        DrawGlyph(@"元", CGRectMake(ctr.x + d - gs, ctr.y - gs * .6, gs * 2, gs * 1.2), gs, HEX(0x6A4606));
        DrawGlyph(@"寶", CGRectMake(ctr.x - d - gs, ctr.y - gs * .6, gs * 2, gs * 1.2), gs, HEX(0x6A4606));
    }
}

static void DrawCoins(CGContextRef c) {
    Fill(Oval(18, 86, 64, 7), HX(0x000000, .2));
    DrawCoinDisc(c, CGPointMake(33, 36), 22, NO);
    DrawCoinDisc(c, CGPointMake(68, 40), 22, NO);
    DrawCoinDisc(c, CGPointMake(50, 62), 27, YES);
    // Red knot and tassel under the front coin.
    for (int i = -3; i <= 3; i++) Line(50 + i * 1.3, 91, 50 + i * 2.6, 99, (i % 2) ? HEX(0xE0191F) : HEX(0xB30F1B), 1.4);
    RadialFill(c, Disc(50, 90, 3.4), @[HEX(0xFF6A47), HEX(0xB30F1B)], CGPointMake(49, 89), 5);
    Stroke(Disc(50, 90, 3.4), HEX(0x6E0610), .7);
    DrawSparkle(12, 70, 5.5, HX(0xFFF6C4, .95));
    DrawSparkle(90, 78, 5, HX(0xFFF6C4, .9));
}

static void DrawPhoenix(CGContextRef c) {
    RadialFill(c, Disc(52, 50, 46), @[HX(0xFFF1A0, .55), HX(0xFFC83A, .25), HX(0xFF9A1F, 0)], CGPointMake(52, 50), 46);

    // Tail plumes, long and trailing, each ending in an eye.
    UIColor *tail0 = HEX(0xE0191F), *tailEnd = HEX(0x138E86);
    DrawPlume(c, CGPointMake(46, 64), 38, 118, 8, tail0, tailEnd, YES);
    DrawPlume(c, CGPointMake(46, 64), 42, 148, 8.5, HEX(0xF5A21F), HEX(0x168A70), YES);
    DrawPlume(c, CGPointMake(46, 62), 40, 176, 8, tail0, HEX(0x1B6FB0), YES);

    // Rising wing: a fan of feathers.
    CGFloat wingAngles[5] = { 202, 222, 242, 262, 282 };
    CGFloat wingLens[5] = { 30, 35, 36, 33, 28 };
    for (int i = 0; i < 5; i++) {
        DrawPlume(c, CGPointMake(62, 56), wingLens[i], wingAngles[i], 7.5, HEX(0xFF8A2A), (i % 2) ? HEX(0xF2C14E) : HEX(0xE0191F), NO);
    }

    // Body.
    UIBezierPath *body = [UIBezierPath bezierPath];
    [body moveToPoint:CGPointMake(76, 46)];
    [body addCurveToPoint:CGPointMake(42, 62) controlPoint1:CGPointMake(70, 38) controlPoint2:CGPointMake(52, 44)];
    [body addCurveToPoint:CGPointMake(66, 76) controlPoint1:CGPointMake(38, 72) controlPoint2:CGPointMake(52, 80)];
    [body addCurveToPoint:CGPointMake(76, 46) controlPoint1:CGPointMake(76, 72) controlPoint2:CGPointMake(82, 58)];
    [body closePath];
    LinearFill(c, body, @[HEX(0xFFB347), HEX(0xE0191F), HEX(0x8E0A14)], CGPointMake(60, 42), CGPointMake(58, 80));
    Stroke([body copy], HEX(0xF2C14E), 1.3);
    for (int row = 0; row < 3; row++) for (int col = 0; col < 3; col++) {
        CGFloat x = 52 + col * 7 + (row % 2) * 3.5, y = 55 + row * 6;
        Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(x, y) radius:3.2 startAngle:0 endAngle:M_PI clockwise:YES], HX(0xFFE48F, .65), .8);
    }

    // Neck, head, beak.
    UIBezierPath *neck = [UIBezierPath bezierPath];
    [neck moveToPoint:CGPointMake(72, 50)];
    [neck addCurveToPoint:CGPointMake(82, 28) controlPoint1:CGPointMake(86, 48) controlPoint2:CGPointMake(70, 36)];
    Stroke(neck, HEX(0x8E0A14), 10);
    Stroke(neck, HEX(0xF0502A), 7.2);
    UIBezierPath *beak = [UIBezierPath bezierPath];
    [beak moveToPoint:CGPointMake(88, 25)];
    [beak addLineToPoint:CGPointMake(99, 30)];
    [beak addLineToPoint:CGPointMake(88, 33)];
    [beak closePath];
    LinearFill(c, beak, @[HEX(0xFFE48F), HEX(0xD4901B)], CGPointMake(88, 25), CGPointMake(99, 33));
    Stroke([beak copy], HEX(0x6A3A00), .8);
    RadialFill(c, Disc(82, 28, 8), @[HEX(0xFF9A5A), HEX(0xE0191F), HEX(0x8E0A14)], CGPointMake(80, 25), 11);
    Stroke(Disc(82, 28, 8), HEX(0xF2C14E), 1.0);
    Fill(Disc(84, 27, 2.1), HEX(0xFFFFFF));
    Fill(Disc(84.5, 27, 1.1), HEX(0x1A1A1A));
    // Crest.
    DrawPlume(c, CGPointMake(80, 21), 15, 228, 3.6, HEX(0xF2C14E), HEX(0xE0191F), NO);
    DrawPlume(c, CGPointMake(81, 20.5), 18, 255, 3.8, HEX(0xF2C14E), HEX(0x138E86), NO);
    DrawPlume(c, CGPointMake(83, 20.5), 15, 285, 3.6, HEX(0xF2C14E), HEX(0xE0191F), NO);

    DrawSparkle(12, 20, 6, HX(0xFFFFFF, .95));
    DrawSparkle(90, 80, 5.5, HX(0xFFF6C4, .95));
}

static void DrawHat(CGContextRef c) {
    // Glow behind the scatter.
    RadialFill(c, Disc(50, 50, 50), @[HX(0xFFF1A0, .9), HX(0xFFC83A, .55), HX(0xFF9A1F, 0)], CGPointMake(50, 50), 50);
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 0, 14);

    Fill(Oval(24, 56, 52, 7), HX(0x000000, .22));

    // Wings.
    for (int side = 0; side < 2; side++) {
        WithMirror(c, side == 1, ^{
            CGContextSaveGState(c);
            CGContextTranslateCTM(c, 38, 45);
            CGContextRotateCTM(c, -13 * M_PI / 180.0);
            CGContextTranslateCTM(c, -38, -45);
            UIBezierPath *wing = RoundRect(3, 40, 37, 9.5, 4.7);
            LinearFill(c, wing, @[HEX(0xFFF0A0), HEX(0xE0A41F), HEX(0xA9730A)], CGPointMake(3, 40), CGPointMake(3, 49.5));
            Stroke([wing copy], HEX(0x7A5206), .9);
            Line(8, 44.8, 34, 44.8, HX(0x7A5206, .4), .6);
            Fill(Disc(7.4, 44.7, 2.4), HEX(0xD4161E));
            Stroke(Disc(7.4, 44.7, 2.4), HEX(0xF7CF58), .6);
            CGContextRestoreGState(c);
        });
    }

    // Crimson band with gold trim.
    UIBezierPath *band = RoundRect(27, 43, 46, 14, 3.2);
    LinearFill(c, band, @[HEX(0xEB4343), HEX(0x8E0F18)], CGPointMake(50, 43), CGPointMake(50, 57));
    Stroke([band copy], HEX(0x7A5206), .9);
    Line(28.5, 45.2, 71.5, 45.2, HEX(0xF7CF58), 1.2);
    Line(28.5, 54.8, 71.5, 54.8, HEX(0xF7CF58), 1.2);
    for (int i = 0; i < 5; i++) if (i != 2) Fill(Disc(34 + i * 8, 50, 1.7), HEX(0xF7CF58));
    RadialFill(c, Disc(50, 50, 3.6), @[HEX(0xFFB4B4), HEX(0xC20F1F)], CGPointMake(49, 49), 4.5);
    Stroke(Disc(50, 50, 3.6), HEX(0xF7CF58), 1.0);

    // Dome.
    UIBezierPath *dome = [UIBezierPath bezierPath];
    [dome moveToPoint:CGPointMake(30, 44)];
    [dome addCurveToPoint:CGPointMake(70, 44) controlPoint1:CGPointMake(28, 16) controlPoint2:CGPointMake(72, 16)];
    [dome closePath];
    LinearFill(c, dome, @[HEX(0xFFF6B8), HEX(0xF0B92C), HEX(0xB57A0B)], CGPointMake(40, 18), CGPointMake(62, 44));
    Stroke([dome copy], HEX(0x7A5206), 1.0);
    for (NSNumber *dx in @[@-14, @-7, @0, @7, @14]) {
        UIBezierPath *rib = [UIBezierPath bezierPath];
        [rib moveToPoint:CGPointMake(50, 19)];
        [rib addCurveToPoint:CGPointMake(50 + dx.doubleValue * 1.2, 44) controlPoint1:CGPointMake(50 + dx.doubleValue * .35, 24) controlPoint2:CGPointMake(50 + dx.doubleValue * 1.1, 32)];
        Stroke(rib, HX(0x7A5206, .45), .8);
    }
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(50, 40) radius:14 startAngle:200 * M_PI / 180 endAngle:250 * M_PI / 180 clockwise:YES], HX(0xFFFFFF, .6), 1.6);

    // Red silk tassel over the dome.
    for (int k = -6; k <= 6; k++) {
        UIBezierPath *strand = [UIBezierPath bezierPath];
        [strand moveToPoint:CGPointMake(50, 17)];
        [strand addCurveToPoint:CGPointMake(50 + k * 3.4, 43.5) controlPoint1:CGPointMake(50 + k * 4.2, 20) controlPoint2:CGPointMake(50 + k * 5.4, 31)];
        Stroke(strand, HX(0xD4161E, .8), .9);
    }

    // Finial.
    RadialFill(c, Disc(50, 16, 5), @[HEX(0xFFF6B8), HEX(0xE0A41F), HEX(0x9A6A08)], CGPointMake(48.5, 14.5), 7);
    Stroke(Disc(50, 16, 5), HEX(0x7A5206), .8);
    RadialFill(c, Disc(50, 10.5, 3.2), @[HEX(0xFFB4B4), HEX(0xC20F1F)], CGPointMake(49, 9.5), 4);
    Stroke(Disc(50, 10.5, 3.2), HEX(0xF7CF58), .8);
    CGContextRestoreGState(c);

    // Peacock-style plumes rising from the finial, the Phoenix Pavilion touch.
    DrawPlume(c, CGPointMake(51, 25), 26, 292, 6.5, HEX(0xF2C14E), HEX(0x138E86), YES);
    DrawPlume(c, CGPointMake(49, 25), 22, 248, 5.5, HEX(0xF2C14E), HEX(0x1B6FB0), YES);
    DrawSparkle(12, 20, 7, HX(0xFFFFFF, .95));
    DrawSparkle(89, 24, 8, HX(0xFFFFFF, .95));
    DrawSparkle(84, 86, 5, HX(0xFFF6C4, .9));
    DrawSparkle(16, 82, 5.5, HX(0xFFF6C4, .9));
}

#pragma mark - Public API

static NSCache<NSString *, UIImage *> *ArtCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 40; });
    return cache;
}

@implementation BRPhoenixPavilionArt

+ (NSString *)nameForSymbol:(PPSymbol)symbol {
    switch (symbol) {
        case PPSymbolEnvelope: return @"Red Envelope";
        case PPSymbolTea: return @"Tea Set";
        case PPSymbolPeony: return @"Peony";
        case PPSymbolPagoda: return @"Pagoda";
        case PPSymbolCrane: return @"Crane";
        case PPSymbolRuyi: return @"Jade Ruyi";
        case PPSymbolCoins: return @"Coin String";
        case PPSymbolPhoenix: return @"Phoenix";
        case PPSymbolHat: return @"Golden Hat";
        default: return @"";
    }
}

+ (UIImage *)imageForSymbol:(PPSymbol)symbol size:(CGSize)size {
    if (symbol < 0 || symbol >= PPSymbolCount || size.width < 1 || size.height < 1) return nil;
    NSString *key = [NSString stringWithFormat:@"s%d-%.0fx%.0f", (int)symbol, size.width, size.height];
    UIImage *cached = [ArtCache() objectForKey:key];
    if (cached) return cached;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextScaleCTM(c, size.width / 100.0, size.height / 100.0);
        switch (symbol) {
            case PPSymbolEnvelope: DrawEnvelope(c); break;
            case PPSymbolTea: DrawTea(c); break;
            case PPSymbolPeony: DrawPeony(c); break;
            case PPSymbolPagoda: DrawPagoda(c); break;
            case PPSymbolCrane: DrawCrane(c); break;
            case PPSymbolRuyi: DrawRuyi(c); break;
            case PPSymbolCoins: DrawCoins(c); break;
            case PPSymbolPhoenix: DrawPhoenix(c); break;
            case PPSymbolHat: DrawHat(c); break;
            default: break;
        }
    }];
    [ArtCache() setObject:image forKey:key];
    return image;
}

+ (UIImage *)cardBackWithSize:(CGSize)size {
    NSString *key = [NSString stringWithFormat:@"card-%.0fx%.0f", size.width, size.height];
    UIImage *cached = [ArtCache() objectForKey:key];
    if (cached) return cached;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextScaleCTM(c, size.width / 100.0, size.height / 140.0);
        UIBezierPath *card = RoundRect(1.5, 1.5, 97, 137, 10);
        LinearFill(c, card, @[HEX(0xC8141E), HEX(0x7A0A14)], CGPointMake(50, 0), CGPointMake(50, 140));
        // Overlapping-wave pattern bands.
        CGContextSaveGState(c);
        [card addClip];
        for (int band = 0; band < 2; band++) {
            CGFloat baseY = band == 0 ? 10 : 104;
            for (int row = 0; row < 4; row++) for (int col = -1; col < 8; col++) {
                CGFloat cx = col * 14 + (row % 2) * 7 + 8, cy = baseY + row * 6.5;
                Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(cx, cy + 7) radius:7 startAngle:M_PI endAngle:2 * M_PI clockwise:YES], HX(0xF2C14E, .38), .8);
            }
        }
        CGContextRestoreGState(c);
        Stroke(RoundRect(4.5, 4.5, 91, 131, 8), HEX(0xF2C14E), 2.2);
        Stroke(RoundRect(8, 8, 84, 124, 6), HX(0xF2C14E, .55), .8);
        UIBezierPath *medal = Disc(50, 70, 26);
        RadialFill(c, medal, @[HEX(0xE5303A), HEX(0x8E0F18)], CGPointMake(44, 62), 32);
        Stroke(Disc(50, 70, 26), HEX(0xF2C14E), 2.0);
        Stroke(Disc(50, 70, 21.5), HX(0xF2C14E, .6), .8);
        DrawGlyph(@"凤", CGRectMake(26, 46, 48, 48), 38, HEX(0xFFD86B));
        for (NSArray *pt in @[@[@16, @70], @[@84, @70]]) DrawSparkle([pt[0] doubleValue], [pt[1] doubleValue], 4.5, HX(0xFFE48F, .9));
    }];
    [ArtCache() setObject:image forKey:key];
    return image;
}

+ (void)purgeCache { [ArtCache() removeAllObjects]; }

@end
