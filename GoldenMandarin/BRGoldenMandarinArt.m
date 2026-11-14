// BRGoldenMandarinArt.m
// EZCompleteUI — Golden Mandarin (金帽福运) slot
//
// Symbol illustrations drawn in code on a 100 x 100 grid. The set is a respectful
// nod to traditional Chinese motifs: paper lantern (福), silk fan, bamboo, plum
// blossom under a moon gate, koi, a jade bi disc, a gold yuanbao ingot, a
// dragon, and the golden official's hat that serves as the scatter.

#import "BRGoldenMandarinArt.h"

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

#pragma mark - Symbols

static void DrawLantern(CGContextRef c) {
    Line(50, 1, 50, 12, HEX(0xD9A21B), 2.4);
    UIBezierPath *top = RoundRect(33, 11, 34, 9, 3);
    LinearFill(c, top, @[HEX(0xFFE48F), HEX(0xB8820F)], CGPointMake(50, 11), CGPointMake(50, 20));
    Stroke([top copy], HEX(0x7A5206), .8);

    UIBezierPath *body = Oval(13, 19, 74, 62);
    RadialFill(c, body, @[HEX(0xFF6A47), HEX(0xE0191F), HEX(0x8E0A12)], CGPointMake(40, 38), 56);
    for (NSNumber *w in @[@54, @36, @18]) {
        CGFloat ww = w.doubleValue;
        Stroke(Oval(50 - ww / 2, 19, ww, 62), HX(0x6E0610, .55), 1.1);
    }
    Stroke([body copy], HEX(0x6E0610), 1.4);
    Fill(Oval(22, 27, 14, 26), HX(0xFFFFFF, .22));
    DrawGlyph(@"福", CGRectMake(28, 31, 44, 40), 34, HEX(0xFFD86B));

    UIBezierPath *bottom = RoundRect(33, 80, 34, 8, 3);
    LinearFill(c, bottom, @[HEX(0xFFE48F), HEX(0xB8820F)], CGPointMake(50, 80), CGPointMake(50, 88));
    Stroke([bottom copy], HEX(0x7A5206), .8);
    for (int i = -3; i <= 3; i++) Line(50 + i * 2.4, 88, 50 + i * 3.4, 99, (i % 2) ? HEX(0xE0191F) : HEX(0xF2C14E), 1.5);
    Fill(Disc(50, 89, 2.6), HEX(0xF2C14E));
}

static void DrawFan(CGContextRef c) {
    CGPoint pivot = CGPointMake(50, 84);
    CGFloat outer = 66, inner = 15, spread = 47 * M_PI / 180.0;
    CGFloat start = -M_PI_2 - spread, end = -M_PI_2 + spread;

    UIBezierPath *face = [UIBezierPath bezierPath];
    [face moveToPoint:CGPointMake(pivot.x + cos(start) * inner, pivot.y + sin(start) * inner)];
    [face addLineToPoint:CGPointMake(pivot.x + cos(start) * outer, pivot.y + sin(start) * outer)];
    [face addArcWithCenter:pivot radius:outer startAngle:start endAngle:end clockwise:YES];
    [face addLineToPoint:CGPointMake(pivot.x + cos(end) * inner, pivot.y + sin(end) * inner)];
    [face addArcWithCenter:pivot radius:inner startAngle:end endAngle:start clockwise:NO];
    [face closePath];
    LinearFill(c, face, @[HEX(0xE5303A), HEX(0x9B0F1D)], CGPointMake(50, 18), CGPointMake(50, 84));

    // Gold ribs and a gilded rim.
    for (int i = 0; i <= 8; i++) {
        CGFloat a = start + i * (2 * spread / 8.0);
        Line(pivot.x + cos(a) * inner, pivot.y + sin(a) * inner, pivot.x + cos(a) * (outer - 1), pivot.y + sin(a) * (outer - 1), HX(0xF2C14E, .85), 1.0);
    }
    UIBezierPath *rim = [UIBezierPath bezierPathWithArcCenter:pivot radius:outer - 2 startAngle:start endAngle:end clockwise:YES];
    Stroke(rim, HEX(0xF2C14E), 2.2);
    UIBezierPath *midArc = [UIBezierPath bezierPathWithArcCenter:pivot radius:outer * .56 startAngle:start + .06 endAngle:end - .06 clockwise:YES];
    Stroke(midArc, HX(0xF2C14E, .8), 1.0);

    // Plum blossoms painted on the paper.
    DrawBlossom(c, CGPointMake(50, 84 - 47), 8.5);
    DrawBlossom(c, CGPointMake(50 + cos(-M_PI_2 - .5) * 38, 84 + sin(-M_PI_2 - .5) * 38), 5.8);
    DrawBlossom(c, CGPointMake(50 + cos(-M_PI_2 + .5) * 38, 84 + sin(-M_PI_2 + .5) * 38), 5.8);

    // Outer guard sticks.
    for (NSNumber *angle in @[@(start), @(end)]) {
        CGFloat a = angle.doubleValue;
        Line(pivot.x, pivot.y, pivot.x + cos(a) * (outer + 1.5), pivot.y + sin(a) * (outer + 1.5), HEX(0x6B3B12), 4.2);
        Line(pivot.x, pivot.y, pivot.x + cos(a) * (outer + 1.5), pivot.y + sin(a) * (outer + 1.5), HEX(0xE1B73C), 2.4);
    }
    Fill(Disc(pivot.x, pivot.y, 3.6), HEX(0xF2C14E));
    Stroke(Disc(pivot.x, pivot.y, 3.6), HEX(0x7A5206), .8);
    Line(50, 88, 50, 94, HEX(0xE1B73C), 1.4);
    for (int i = -2; i <= 2; i++) Line(50, 94, 50 + i * 2, 99.5, HEX(0xD4161E), 1.4);
}

static void DrawStalk(CGContextRef c, CGFloat x, CGFloat width, CGFloat top, CGFloat bottom, NSArray<NSNumber *> *nodes) {
    UIBezierPath *stalk = RoundRect(x - width / 2, top, width, bottom - top, width / 2);
    LinearFill(c, stalk, @[HEX(0x8FE184), HEX(0x3FAA4B), HEX(0x1C6A30)], CGPointMake(x - width / 2, 0), CGPointMake(x + width / 2, 0));
    Stroke([stalk copy], HX(0x0C4A20, .8), .8);
    for (NSNumber *node in nodes) {
        CGFloat y = node.doubleValue;
        UIBezierPath *ring = RoundRect(x - width / 2 - 1, y - 1.7, width + 2, 3.4, 1.7);
        Fill(ring, HEX(0x1B5E2B));
        Line(x - width / 2, y - 1.9, x + width / 2, y - 1.9, HX(0xC7F5BF, .6), .6);
    }
}

static void DrawBamboo(CGContextRef c) {
    DrawStalk(c, 31, 9, 18, 93, @[@34, @56, @76]);
    DrawStalk(c, 68, 9, 14, 95, @[@30, @52, @74]);
    DrawStalk(c, 50, 12, 5, 97, @[@22, @44, @66, @86]);
    DrawLeaf(c, CGPointMake(31, 34), 25, -150, 6.5);
    DrawLeaf(c, CGPointMake(31, 56), 22, -28, 6);
    DrawLeaf(c, CGPointMake(68, 30), 25, -32, 6.5);
    DrawLeaf(c, CGPointMake(68, 52), 22, -152, 6);
    DrawLeaf(c, CGPointMake(50, 22), 26, -125, 7);
    DrawLeaf(c, CGPointMake(50, 22), 26, -55, 7);
    DrawLeaf(c, CGPointMake(50, 44), 24, 160, 6.5);
    DrawLeaf(c, CGPointMake(50, 66), 22, 22, 6);
}

static void DrawPlum(CGContextRef c) {
    // Moon gate backdrop.
    UIBezierPath *moon = Disc(50, 50, 45);
    RadialFill(c, moon, @[HEX(0x3A4D93), HEX(0x1D2A66), HEX(0x101845)], CGPointMake(40, 36), 62);
    Stroke(Disc(50, 50, 45), HEX(0xE1B73C), 2.2);
    Stroke(Disc(50, 50, 41.5), HX(0xF2C14E, .5), .7);

    CGContextSaveGState(c);
    [Disc(50, 50, 44) addClip];
    UIBezierPath *branch = [UIBezierPath bezierPath];
    [branch moveToPoint:CGPointMake(2, 90)];
    [branch addCurveToPoint:CGPointMake(58, 54) controlPoint1:CGPointMake(24, 76) controlPoint2:CGPointMake(42, 78)];
    [branch addCurveToPoint:CGPointMake(98, 20) controlPoint1:CGPointMake(70, 40) controlPoint2:CGPointMake(86, 40)];
    Stroke([branch copy], HEX(0x4A2A16), 6.4);
    Stroke(branch, HEX(0xA06E48), 4.2);
    UIBezierPath *twigA = [UIBezierPath bezierPath];
    [twigA moveToPoint:CGPointMake(58, 54)]; [twigA addCurveToPoint:CGPointMake(38, 28) controlPoint1:CGPointMake(58, 42) controlPoint2:CGPointMake(48, 34)];
    Stroke(twigA, HEX(0xA06E48), 2.6);
    UIBezierPath *twigB = [UIBezierPath bezierPath];
    [twigB moveToPoint:CGPointMake(30, 77)]; [twigB addCurveToPoint:CGPointMake(22, 60) controlPoint1:CGPointMake(30, 70) controlPoint2:CGPointMake(26, 64)];
    Stroke(twigB, HEX(0xA06E48), 2.2);
    UIBezierPath *twigC = [UIBezierPath bezierPath];
    [twigC moveToPoint:CGPointMake(78, 36)]; [twigC addCurveToPoint:CGPointMake(82, 20) controlPoint1:CGPointMake(78, 30) controlPoint2:CGPointMake(80, 24)];
    Stroke(twigC, HEX(0xA06E48), 2.0);
    DrawBlossom(c, CGPointMake(38, 28), 11);
    DrawBlossom(c, CGPointMake(63, 52), 13.5);
    DrawBlossom(c, CGPointMake(82, 20), 8.5);
    DrawBlossom(c, CGPointMake(22, 60), 8.5);
    Fill(Disc(50, 34, 2.4), HEX(0xFFB3C8)); Fill(Disc(74, 38, 2.2), HEX(0xFFB3C8)); Fill(Disc(40, 70, 2.2), HEX(0xFFB3C8));
    CGContextRestoreGState(c);
}

static void DrawKoi(CGContextRef c) {
    // Ripples.
    for (int i = 0; i < 3; i++) {
        CGFloat w = 94 - i * 18, h = 52 - i * 12;
        Stroke(Oval(50 - w / 2, 56 - h / 2, w, h), HX(0x4FC3D9, .42 - i * .08), 1.4);
    }
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 50, 50);
    CGContextRotateCTM(c, -12 * M_PI / 180.0);
    CGContextTranslateCTM(c, -50, -50);

    UIBezierPath *tail = [UIBezierPath bezierPath];
    [tail moveToPoint:CGPointMake(33, 47)];
    [tail addCurveToPoint:CGPointMake(5, 24) controlPoint1:CGPointMake(22, 40) controlPoint2:CGPointMake(14, 34)];
    [tail addCurveToPoint:CGPointMake(15, 48) controlPoint1:CGPointMake(6, 36) controlPoint2:CGPointMake(15, 42)];
    [tail addCurveToPoint:CGPointMake(4, 74) controlPoint1:CGPointMake(15, 56) controlPoint2:CGPointMake(6, 64)];
    [tail addCurveToPoint:CGPointMake(33, 50) controlPoint1:CGPointMake(16, 66) controlPoint2:CGPointMake(24, 56)];
    [tail closePath];
    LinearFill(c, tail, @[HX(0xFFB066, .95), HX(0xFF6A1A, .9)], CGPointMake(5, 24), CGPointMake(33, 74));
    Stroke([tail copy], HX(0xB8400E, .8), .9);
    for (int i = 0; i < 4; i++) Line(33, 48.5, 7 + i * 1.5, 30 + i * 14, HX(0xB8400E, .35), .6);

    UIBezierPath *dorsal = [UIBezierPath bezierPath];
    [dorsal moveToPoint:CGPointMake(64, 32)];
    [dorsal addCurveToPoint:CGPointMake(40, 28) controlPoint1:CGPointMake(60, 15) controlPoint2:CGPointMake(46, 15)];
    [dorsal addCurveToPoint:CGPointMake(64, 32) controlPoint1:CGPointMake(48, 30) controlPoint2:CGPointMake(56, 32)];
    Fill(dorsal, HX(0xE5480C, .95));
    Stroke([dorsal copy], HX(0xB8400E, .8), .8);

    UIBezierPath *body = [UIBezierPath bezierPath];
    [body moveToPoint:CGPointMake(88, 52)];
    [body addCurveToPoint:CGPointMake(60, 31) controlPoint1:CGPointMake(86, 38) controlPoint2:CGPointMake(74, 30)];
    [body addCurveToPoint:CGPointMake(30, 47) controlPoint1:CGPointMake(50, 32) controlPoint2:CGPointMake(40, 40)];
    [body addCurveToPoint:CGPointMake(56, 73) controlPoint1:CGPointMake(36, 60) controlPoint2:CGPointMake(44, 72)];
    [body addCurveToPoint:CGPointMake(88, 52) controlPoint1:CGPointMake(74, 75) controlPoint2:CGPointMake(88, 64)];
    [body closePath];
    LinearFill(c, body, @[HEX(0xFF9A3C), HEX(0xE5430B)], CGPointMake(60, 30), CGPointMake(60, 74));
    CGContextSaveGState(c);
    [body addClip];
    Fill(Oval(42, 30, 30, 20), HX(0xFFFFFF, .93));
    Fill(Oval(58, 36, 13, 10), HEX(0xE02A17));
    Fill(Oval(30, 50, 14, 10), HX(0xFFFFFF, .9));
    for (CGFloat x = 40; x < 90; x += 9) for (CGFloat y = 54; y < 76; y += 8) {
        Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(x + ((int)(y / 8) % 2) * 4, y) radius:4.5 startAngle:M_PI endAngle:2 * M_PI clockwise:YES], HX(0xFFFFFF, .28), .7);
    }
    CGContextRestoreGState(c);
    Stroke([body copy], HEX(0x9B2A0C), 1.2);

    UIBezierPath *pectoral = [UIBezierPath bezierPath];
    [pectoral moveToPoint:CGPointMake(62, 62)];
    [pectoral addCurveToPoint:CGPointMake(48, 80) controlPoint1:CGPointMake(66, 76) controlPoint2:CGPointMake(58, 84)];
    [pectoral addCurveToPoint:CGPointMake(62, 62) controlPoint1:CGPointMake(54, 74) controlPoint2:CGPointMake(58, 68)];
    Fill(pectoral, HX(0xFF7A26, .95));
    Stroke([pectoral copy], HX(0xB8400E, .8), .8);

    Fill(Disc(77, 46, 3.6), HEX(0xFFFFFF));
    Fill(Disc(77.6, 46.2, 2.0), HEX(0x1A1A1A));
    Fill(Disc(78.2, 45.4, .6), HEX(0xFFFFFF));
    UIBezierPath *barbel = [UIBezierPath bezierPath];
    [barbel moveToPoint:CGPointMake(86, 57)];
    [barbel addCurveToPoint:CGPointMake(91, 72) controlPoint1:CGPointMake(93, 60) controlPoint2:CGPointMake(95, 67)];
    Stroke(barbel, HEX(0xF2B040), 1.2);
    CGContextRestoreGState(c);
}

static void DrawJade(CGContextRef c) {
    // Gold bail and cord.
    Stroke(Oval(44, 2, 12, 11), HEX(0xE1B73C), 2.4);
    CGPoint center = CGPointMake(50, 48);
    UIBezierPath *disc = [UIBezierPath bezierPath];
    [disc appendPath:Disc(center.x, center.y, 33)];
    [disc appendPath:Disc(center.x, center.y, 10.5)];
    disc.usesEvenOddFillRule = YES;
    RadialFill(c, disc, @[HEX(0xC4F7D6), HEX(0x5ACB98), HEX(0x1B8057), HEX(0x0F5B3D)], CGPointMake(38, 34), 62);
    Stroke(Disc(center.x, center.y, 33), HEX(0xE1B73C), 2.6);
    Stroke(Disc(center.x, center.y, 10.5), HEX(0xE1B73C), 1.8);
    Stroke(Disc(center.x, center.y, 20), HX(0xFFFFFF, .3), .9);
    Stroke(Disc(center.x, center.y, 27.5), HX(0xFFFFFF, .25), .8);
    for (int i = 0; i < 12; i++) {
        CGFloat a = i * (2 * M_PI / 12) + .13;
        Fill(Disc(center.x + cos(a) * 15.5, center.y + sin(a) * 15.5, 1.3), HX(0xFFFFFF, .42));
    }
    for (int i = 0; i < 18; i++) {
        CGFloat a = i * (2 * M_PI / 18);
        Fill(Disc(center.x + cos(a) * 24, center.y + sin(a) * 24, 1.5), HX(0xFFFFFF, .32));
    }
    Stroke([UIBezierPath bezierPathWithArcCenter:center radius:29.5 startAngle:200 * M_PI / 180 endAngle:255 * M_PI / 180 clockwise:YES], HX(0xFFFFFF, .55), 1.6);

    // Red knot and tassel.
    UIBezierPath *knot = [UIBezierPath bezierPath];
    [knot moveToPoint:CGPointMake(50, 80)]; [knot addLineToPoint:CGPointMake(55, 85)]; [knot addLineToPoint:CGPointMake(50, 90)]; [knot addLineToPoint:CGPointMake(45, 85)]; [knot closePath];
    Fill(knot, HEX(0xD4161E)); Stroke([knot copy], HEX(0xF2C14E), .9);
    for (int i = -3; i <= 3; i++) Line(50 + i * 1.4, 90, 50 + i * 2.6, 99, HEX(0xD4161E), 1.3);
}

static void DrawIngot(CGContextRef c) {
    UIBezierPath *base = [UIBezierPath bezierPath];
    [base moveToPoint:CGPointMake(15, 54)]; [base addLineToPoint:CGPointMake(85, 54)];
    [base addLineToPoint:CGPointMake(73, 84)]; [base addLineToPoint:CGPointMake(27, 84)]; [base closePath];
    LinearFill(c, base, @[HEX(0xE9B52A), HEX(0x9A6A08)], CGPointMake(50, 54), CGPointMake(50, 84));
    Stroke([base copy], HEX(0x7A4F00), 1.3);
    DrawGlyph(@"福", CGRectMake(34, 56, 32, 26), 17, HEX(0x8E1414));

    UIBezierPath *top = [UIBezierPath bezierPath];
    [top moveToPoint:CGPointMake(3, 36)];
    [top addCurveToPoint:CGPointMake(50, 62) controlPoint1:CGPointMake(8, 54) controlPoint2:CGPointMake(30, 62)];
    [top addCurveToPoint:CGPointMake(97, 36) controlPoint1:CGPointMake(70, 62) controlPoint2:CGPointMake(92, 54)];
    [top addCurveToPoint:CGPointMake(63, 30) controlPoint1:CGPointMake(86, 42) controlPoint2:CGPointMake(70, 38)];
    [top addCurveToPoint:CGPointMake(37, 30) controlPoint1:CGPointMake(58, 18) controlPoint2:CGPointMake(42, 18)];
    [top addCurveToPoint:CGPointMake(3, 36) controlPoint1:CGPointMake(30, 38) controlPoint2:CGPointMake(14, 42)];
    [top closePath];
    LinearFill(c, top, @[HEX(0xFFF3AE), HEX(0xF5C033), HEX(0xC48A0E)], CGPointMake(50, 18), CGPointMake(50, 62));
    Stroke([top copy], HEX(0x8A5A00), 1.3);
    Stroke(Oval(40, 24, 20, 9), HX(0xFFFFFF, .5), 1.0);
    UIBezierPath *shine = [UIBezierPath bezierPath];
    [shine moveToPoint:CGPointMake(12, 40)]; [shine addCurveToPoint:CGPointMake(40, 54) controlPoint1:CGPointMake(16, 48) controlPoint2:CGPointMake(28, 53)];
    Stroke(shine, HX(0xFFFFFF, .55), 1.5);
    DrawSparkle(88, 18, 7, HX(0xFFF6C4, .95));
    DrawSparkle(12, 20, 5, HX(0xFFF6C4, .9));
}

static void DrawDragonHalf(CGContextRef c, BOOL layer) {
    if (layer == 0) {
        // Mane flames.
        for (int i = 0; i < 3; i++) {
            CGFloat y0 = 72 - i * 17;
            UIBezierPath *flame = [UIBezierPath bezierPath];
            [flame moveToPoint:CGPointMake(36, y0)];
            [flame addCurveToPoint:CGPointMake(7 + i * 2, y0 - 26) controlPoint1:CGPointMake(14, y0 - 2) controlPoint2:CGPointMake(4 + i * 3, y0 - 12)];
            [flame addCurveToPoint:CGPointMake(36, y0 - 16) controlPoint1:CGPointMake(15 + i * 2, y0 - 20) controlPoint2:CGPointMake(24, y0 - 20)];
            [flame closePath];
            LinearFill(c, flame, @[HEX(0xFFB02E), HEX(0xE0231F)], CGPointMake(36, y0 - 10), CGPointMake(6, y0 - 22));
            Stroke([flame copy], HX(0x8E0A12, .8), .8);
        }
        // Whiskers.
        UIBezierPath *w1 = [UIBezierPath bezierPath];
        [w1 moveToPoint:CGPointMake(35, 60)];
        [w1 addCurveToPoint:CGPointMake(12, 38) controlPoint1:CGPointMake(18, 62) controlPoint2:CGPointMake(8, 52)];
        [w1 addCurveToPoint:CGPointMake(10, 12) controlPoint1:CGPointMake(15, 28) controlPoint2:CGPointMake(8, 22)];
        UIBezierPath *w2 = [UIBezierPath bezierPath];
        [w2 moveToPoint:CGPointMake(36, 70)];
        [w2 addCurveToPoint:CGPointMake(8, 90) controlPoint1:CGPointMake(22, 80) controlPoint2:CGPointMake(10, 76)];
        for (UIBezierPath *w in @[w1, w2]) { Stroke([w copy], HEX(0x8A5A00), 4.4); Stroke(w, HEX(0xF7CF58), 2.6); }
        // Horn.
        UIBezierPath *horn = [UIBezierPath bezierPath];
        [horn moveToPoint:CGPointMake(39, 30)];
        [horn addCurveToPoint:CGPointMake(14, 9) controlPoint1:CGPointMake(35, 16) controlPoint2:CGPointMake(25, 8)];
        [horn addCurveToPoint:CGPointMake(34, 40) controlPoint1:CGPointMake(23, 16) controlPoint2:CGPointMake(28, 28)];
        [horn closePath];
        LinearFill(c, horn, @[HEX(0xFFF6D0), HEX(0xD9A21B)], CGPointMake(30, 10), CGPointMake(34, 40));
        Stroke([horn copy], HEX(0x8A5A00), .9);
        // Cheek fin.
        UIBezierPath *fin = [UIBezierPath bezierPath];
        [fin moveToPoint:CGPointMake(30, 52)];
        [fin addCurveToPoint:CGPointMake(10, 68) controlPoint1:CGPointMake(18, 52) controlPoint2:CGPointMake(12, 60)];
        [fin addCurveToPoint:CGPointMake(30, 64) controlPoint1:CGPointMake(18, 68) controlPoint2:CGPointMake(24, 66)];
        [fin closePath];
        LinearFill(c, fin, @[HEX(0xF7CF58), HEX(0x2AA58A)], CGPointMake(10, 60), CGPointMake(30, 58));
        Stroke([fin copy], HEX(0x063C34), .8);
    } else {
        // Brow and eye.
        Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(39, 43) radius:11 startAngle:200 * M_PI / 180 endAngle:300 * M_PI / 180 clockwise:YES], HEX(0x063C34), 2.8);
        UIBezierPath *eye = [UIBezierPath bezierPath];
        [eye moveToPoint:CGPointMake(30, 45)];
        [eye addCurveToPoint:CGPointMake(47, 45) controlPoint1:CGPointMake(34, 36) controlPoint2:CGPointMake(43, 37)];
        [eye addCurveToPoint:CGPointMake(30, 45) controlPoint1:CGPointMake(42, 50) controlPoint2:CGPointMake(35, 50)];
        [eye closePath];
        LinearFill(c, eye, @[HEX(0xFFE56A), HEX(0xFF9A1F)], CGPointMake(38, 38), CGPointMake(38, 50));
        Fill(Oval(36.4, 40.6, 4, 7.6), HEX(0x140A00));
        Fill(Disc(36.6, 41.4, 1.0), HEX(0xFFFFFF));
        Stroke([eye copy], HEX(0x2A1A00), .9);
        // Fang.
        UIBezierPath *fang = [UIBezierPath bezierPath];
        [fang moveToPoint:CGPointMake(41, 76)]; [fang addLineToPoint:CGPointMake(43.2, 84)]; [fang addLineToPoint:CGPointMake(46, 77.5)]; [fang closePath];
        Fill(fang, HEX(0xFFFFFF)); Stroke([fang copy], HEX(0x6B6B6B), .5);
    }
}

static void DrawDragon(CGContextRef c) {
    UIBezierPath *halo = Disc(50, 50, 49);
    RadialFill(c, halo, @[HX(0xFFD34A, .6), HX(0xFF8A1F, .0)], CGPointMake(50, 50), 49);

    WithMirror(c, NO, ^{ DrawDragonHalf(c, 0); });
    WithMirror(c, YES, ^{ DrawDragonHalf(c, 0); });

    UIBezierPath *head = [UIBezierPath bezierPath];
    [head moveToPoint:CGPointMake(50, 16)];
    [head addCurveToPoint:CGPointMake(74, 48) controlPoint1:CGPointMake(66, 16) controlPoint2:CGPointMake(76, 30)];
    [head addCurveToPoint:CGPointMake(60, 82) controlPoint1:CGPointMake(73, 60) controlPoint2:CGPointMake(66, 72)];
    [head addCurveToPoint:CGPointMake(40, 82) controlPoint1:CGPointMake(56, 88) controlPoint2:CGPointMake(44, 88)];
    [head addCurveToPoint:CGPointMake(26, 48) controlPoint1:CGPointMake(34, 72) controlPoint2:CGPointMake(27, 60)];
    [head addCurveToPoint:CGPointMake(50, 16) controlPoint1:CGPointMake(24, 30) controlPoint2:CGPointMake(34, 16)];
    [head closePath];
    RadialFill(c, head, @[HEX(0x58D9A8), HEX(0x1C9272), HEX(0x0B4F45)], CGPointMake(50, 34), 52);
    Stroke([head copy], HEX(0x063C34), 1.5);
    for (NSArray *pt in @[@[@40, @30], @[@50, @27], @[@60, @30], @[@45, @36], @[@55, @36], @[@35, @40], @[@65, @40]]) {
        Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake([pt[0] doubleValue], [pt[1] doubleValue]) radius:3.6 startAngle:M_PI endAngle:2 * M_PI clockwise:YES], HX(0xFFFFFF, .2), .8);
    }
    // Ruby on the brow.
    Fill(Disc(50, 22.5, 4.2), HEX(0xF2C14E));
    RadialFill(c, Disc(50, 22.5, 3.2), @[HEX(0xFF9A9A), HEX(0xC20F1F)], CGPointMake(49, 21.5), 4);

    WithMirror(c, NO, ^{ DrawDragonHalf(c, 1); });
    WithMirror(c, YES, ^{ DrawDragonHalf(c, 1); });

    // Muzzle.
    UIBezierPath *muzzle = Oval(35, 56, 30, 22);
    RadialFill(c, muzzle, @[HEX(0x9AF0CD), HEX(0x35B091), HEX(0x167A62)], CGPointMake(46, 62), 24);
    Stroke([muzzle copy], HEX(0x063C34), 1.1);
    Fill(Oval(41.2, 60.6, 4.4, 3.4), HEX(0x063C34));
    Fill(Oval(54.4, 60.6, 4.4, 3.4), HEX(0x063C34));
    UIBezierPath *mouth = [UIBezierPath bezierPath];
    [mouth moveToPoint:CGPointMake(38, 72)];
    [mouth addCurveToPoint:CGPointMake(62, 72) controlPoint1:CGPointMake(45, 77) controlPoint2:CGPointMake(55, 77)];
    Stroke(mouth, HEX(0x063C34), 1.4);

    // Pearl.
    RadialFill(c, Disc(50, 92, 6), @[HEX(0xFFFFFF), HEX(0xFFE48F), HEX(0xE1A21B)], CGPointMake(48.5, 90), 8);
    Stroke(Disc(50, 92, 6), HX(0x8A5A00, .8), .7);
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

@implementation BRGoldenMandarinArt

+ (NSString *)nameForSymbol:(GMSymbol)symbol {
    switch (symbol) {
        case GMSymbolLantern: return @"Paper Lantern";
        case GMSymbolFan: return @"Silk Fan";
        case GMSymbolBamboo: return @"Bamboo";
        case GMSymbolPlum: return @"Plum Blossom";
        case GMSymbolKoi: return @"Koi";
        case GMSymbolJade: return @"Jade Bi";
        case GMSymbolIngot: return @"Gold Ingot";
        case GMSymbolDragon: return @"Dragon";
        case GMSymbolHat: return @"Golden Hat";
        default: return @"";
    }
}

+ (UIImage *)imageForSymbol:(GMSymbol)symbol size:(CGSize)size {
    if (symbol < 0 || symbol >= GMSymbolCount || size.width < 1 || size.height < 1) return nil;
    NSString *key = [NSString stringWithFormat:@"s%d-%.0fx%.0f", (int)symbol, size.width, size.height];
    UIImage *cached = [ArtCache() objectForKey:key];
    if (cached) return cached;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextScaleCTM(c, size.width / 100.0, size.height / 100.0);
        switch (symbol) {
            case GMSymbolLantern: DrawLantern(c); break;
            case GMSymbolFan: DrawFan(c); break;
            case GMSymbolBamboo: DrawBamboo(c); break;
            case GMSymbolPlum: DrawPlum(c); break;
            case GMSymbolKoi: DrawKoi(c); break;
            case GMSymbolJade: DrawJade(c); break;
            case GMSymbolIngot: DrawIngot(c); break;
            case GMSymbolDragon: DrawDragon(c); break;
            case GMSymbolHat: DrawHat(c); break;
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
        DrawGlyph(@"福", CGRectMake(26, 46, 48, 48), 38, HEX(0xFFD86B));
        for (NSArray *pt in @[@[@16, @70], @[@84, @70]]) DrawSparkle([pt[0] doubleValue], [pt[1] doubleValue], 4.5, HX(0xFFE48F, .9));
    }];
    [ArtCache() setObject:image forKey:key];
    return image;
}

+ (void)purgeCache { [ArtCache() removeAllObjects]; }

@end
