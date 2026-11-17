// BRStarlightOdysseyArt.m
// EZCompleteUI — Starlight Odyssey slot
//
// Symbol illustrations drawn in code on a 100 x 100 grid, all space themed: a
// rocket, the moon, a satellite, an astronaut helmet, a ringed planet, a UFO, a
// friendly alien, a spiral galaxy (top pay) and the golden warp star scatter.

#import "BRStarlightOdysseyArt.h"

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

__attribute__((unused)) static void DrawGlyph(NSString *text, CGRect rect, CGFloat size, UIColor *color) {
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
__attribute__((unused)) static void WithMirror(CGContextRef c, BOOL mirrored, void (^body)(void)) {
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

#pragma mark - Symbols

static UIBezierPath *StarPath(CGFloat cx, CGFloat cy, CGFloat outer, CGFloat inner, int points, CGFloat rotDeg) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    for (int i = 0; i < points * 2; i++) {
        CGFloat r = (i % 2 == 0) ? outer : inner;
        CGFloat a = (rotDeg - 90 + i * 180.0 / points) * M_PI / 180.0;
        CGPoint pt = CGPointMake(cx + cos(a) * r, cy + sin(a) * r);
        if (i == 0) [p moveToPoint:pt]; else [p addLineToPoint:pt];
    }
    [p closePath];
    return p;
}

/// A few fixed twinkles so every symbol feels like it floats in space.
static void DrawTwinkles(CGFloat dx) {
    DrawSparkle(12 + dx, 16, 5, HX(0xFFFFFF, .95));
    DrawSparkle(90 - dx, 82, 4.5, HX(0xBFD4FF, .9));
    Fill(Disc(86, 14, 1.4), HX(0xFFFFFF, .9));
    Fill(Disc(10, 86, 1.2), HX(0xFFFFFF, .8));
}

static void DrawRocket(CGContextRef c) {
    // Exhaust glow first so the rocket sits on top of it.
    RadialFill(c, Disc(50, 50, 46), @[HX(0x6A7BFF, .30), HX(0x6A7BFF, 0)], CGPointMake(50, 50), 46);
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 52, 50);
    CGContextRotateCTM(c, 38 * M_PI / 180.0);
    CGContextScaleCTM(c, .84, .84);
    CGContextTranslateCTM(c, -50, -52);

    // Flame.
    UIBezierPath *flame = [UIBezierPath bezierPath];
    [flame moveToPoint:CGPointMake(42, 78)];
    [flame addCurveToPoint:CGPointMake(50, 104) controlPoint1:CGPointMake(40, 92) controlPoint2:CGPointMake(47, 98)];
    [flame addCurveToPoint:CGPointMake(58, 78) controlPoint1:CGPointMake(53, 98) controlPoint2:CGPointMake(60, 92)];
    [flame closePath];
    LinearFill(c, flame, @[HEX(0xFFF3A0), HEX(0xFF9A1F), HEX(0xFF3D1F)], CGPointMake(50, 78), CGPointMake(50, 104));
    UIBezierPath *core = [UIBezierPath bezierPath];
    [core moveToPoint:CGPointMake(45.5, 78)];
    [core addCurveToPoint:CGPointMake(50, 94) controlPoint1:CGPointMake(45, 86) controlPoint2:CGPointMake(48, 91)];
    [core addCurveToPoint:CGPointMake(54.5, 78) controlPoint1:CGPointMake(52, 91) controlPoint2:CGPointMake(55, 86)];
    [core closePath];
    Fill(core, HEX(0xFFFBD0));

    // Fins.
    for (int side = 0; side < 2; side++) {
        CGFloat s = side == 0 ? -1 : 1;
        UIBezierPath *fin = [UIBezierPath bezierPath];
        [fin moveToPoint:CGPointMake(50 + s * 13, 52)];
        [fin addQuadCurveToPoint:CGPointMake(50 + s * 30, 82) controlPoint:CGPointMake(50 + s * 30, 62)];
        [fin addLineToPoint:CGPointMake(50 + s * 13, 74)];
        [fin closePath];
        LinearFill(c, fin, @[HEX(0xFF5A4A), HEX(0xB3162A)], CGPointMake(50 + s * 13, 52), CGPointMake(50 + s * 30, 82));
        Stroke([fin copy], HEX(0x5A0A18), 1.0);
    }

    // Body.
    UIBezierPath *body = [UIBezierPath bezierPath];
    [body moveToPoint:CGPointMake(50, 6)];
    [body addCurveToPoint:CGPointMake(63, 54) controlPoint1:CGPointMake(58, 18) controlPoint2:CGPointMake(63, 34)];
    [body addLineToPoint:CGPointMake(63, 76)];
    [body addLineToPoint:CGPointMake(37, 76)];
    [body addLineToPoint:CGPointMake(37, 54)];
    [body addCurveToPoint:CGPointMake(50, 6) controlPoint1:CGPointMake(37, 34) controlPoint2:CGPointMake(42, 18)];
    [body closePath];
    LinearFill(c, body, @[HEX(0xB8C4E0), HEX(0xFFFFFF), HEX(0xC9D3EA), HEX(0x8190B4)], CGPointMake(37, 40), CGPointMake(63, 40));
    Stroke([body copy], HEX(0x39466E), 1.2);
    UIBezierPath *nose = [UIBezierPath bezierPath];
    [nose moveToPoint:CGPointMake(50, 6)];
    [nose addCurveToPoint:CGPointMake(59, 27) controlPoint1:CGPointMake(55, 12) controlPoint2:CGPointMake(58, 19)];
    [nose addLineToPoint:CGPointMake(41, 27)];
    [nose addCurveToPoint:CGPointMake(50, 6) controlPoint1:CGPointMake(42, 19) controlPoint2:CGPointMake(45, 12)];
    [nose closePath];
    LinearFill(c, nose, @[HEX(0xFF6A5A), HEX(0xC21B2E)], CGPointMake(41, 10), CGPointMake(60, 27));
    Stroke([nose copy], HEX(0x5A0A18), 1.0);
    Fill(RoundRect(37, 56, 26, 4, 1.5), HEX(0xC21B2E));
    // Porthole.
    RadialFill(c, Disc(50, 42, 8.5), @[HEX(0xCFF3FF), HEX(0x3F9BE8), HEX(0x14357A)], CGPointMake(47, 39), 12);
    Stroke(Disc(50, 42, 8.5), HEX(0xDDE5F5), 2.2);
    Stroke(Disc(50, 42, 10.2), HEX(0x39466E), .9);
    Fill(Disc(47.5, 39.5, 2), HX(0xFFFFFF, .85));
    // Nozzle.
    Fill(RoundRect(41, 76, 18, 5, 2), HEX(0x39466E));
    CGContextRestoreGState(c);
    DrawTwinkles(0);
}

static void DrawMoon(CGContextRef c) {
    RadialFill(c, Disc(50, 50, 48), @[HX(0xBFD4FF, .35), HX(0xBFD4FF, 0)], CGPointMake(50, 50), 48);
    UIBezierPath *moon = Disc(50, 50, 34);
    RadialFill(c, moon, @[HEX(0xFFFFFF), HEX(0xE4E8F2), HEX(0xA6B0C8), HEX(0x6D7898)], CGPointMake(40, 38), 62);
    Stroke(Disc(50, 50, 34), HX(0xFFFFFF, .55), 1.2);
    CGFloat cr[6][3] = { {36, 38, 8}, {60, 34, 5.5}, {62, 58, 9}, {40, 64, 6}, {50, 50, 3.6}, {28, 56, 3.4} };
    for (int i = 0; i < 6; i++) {
        RadialFill(c, Disc(cr[i][0], cr[i][1], cr[i][2]), @[HX(0x8A94B0, .9), HX(0xB6BED4, .9)], CGPointMake(cr[i][0] + 1, cr[i][1] + 1), cr[i][2]);
        Stroke(Disc(cr[i][0], cr[i][1], cr[i][2]), HX(0x5A6488, .8), .8);
        Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(cr[i][0], cr[i][1]) radius:cr[i][2] - .8 startAngle:M_PI * .95 endAngle:M_PI * 1.55 clockwise:YES], HX(0xFFFFFF, .7), 1.0);
    }
    // Small sleeping flag-pole: a gold pennant.
    Line(70, 30, 70, 14, HEX(0xE9ECF5), 1.4);
    UIBezierPath *flag = [UIBezierPath bezierPath];
    [flag moveToPoint:CGPointMake(70, 14)];
    [flag addLineToPoint:CGPointMake(82, 18)];
    [flag addLineToPoint:CGPointMake(70, 22)];
    [flag closePath];
    Fill(flag, HEX(0xF2C14E));
    DrawTwinkles(0);
}

static void DrawSatellite(CGContextRef c) {
    RadialFill(c, Disc(50, 50, 46), @[HX(0x6A7BFF, .22), HX(0x6A7BFF, 0)], CGPointMake(50, 50), 46);
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 50, 54);
    CGContextRotateCTM(c, -24 * M_PI / 180.0);
    CGContextTranslateCTM(c, -50, -54);
    // Solar panels.
    for (int side = 0; side < 2; side++) {
        CGFloat x = side == 0 ? 4 : 62;
        UIBezierPath *panel = RoundRect(x, 42, 34, 24, 2);
        LinearFill(c, panel, @[HEX(0x2F6BFF), HEX(0x0F2A8A)], CGPointMake(x, 42), CGPointMake(x + 34, 66));
        Stroke([panel copy], HEX(0xC9D6FF), 1.1);
        for (int k = 1; k < 4; k++) Line(x + k * 8.5, 42, x + k * 8.5, 66, HX(0xC9D6FF, .75), .7);
        Line(x, 54, x + 34, 54, HX(0xC9D6FF, .75), .7);
        Fill(RoundRect(x + 2, 44, 10, 3, 1), HX(0xFFFFFF, .35));
    }
    Line(38, 54, 62, 54, HEX(0xB8C4E0), 2.4);
    // Gold-foil body.
    UIBezierPath *body = RoundRect(37, 38, 26, 32, 4);
    LinearFill(c, body, @[HEX(0xFFE48F), HEX(0xE0A41F), HEX(0x9A6A08)], CGPointMake(37, 38), CGPointMake(63, 70));
    Stroke([body copy], HEX(0x6A4606), 1.2);
    for (int k = 1; k < 4; k++) Line(37, 38 + k * 8, 63, 38 + k * 8, HX(0x6A4606, .35), .7);
    RadialFill(c, Disc(50, 54, 6), @[HEX(0xCFF3FF), HEX(0x3F9BE8), HEX(0x14357A)], CGPointMake(48, 52), 9);
    Stroke(Disc(50, 54, 6), HEX(0xE9ECF5), 1.4);
    // Dish and beacon.
    Line(50, 38, 50, 27, HEX(0xB8C4E0), 2.0);
    UIBezierPath *dish = [UIBezierPath bezierPath];
    [dish moveToPoint:CGPointMake(38, 22)];
    [dish addQuadCurveToPoint:CGPointMake(62, 22) controlPoint:CGPointMake(50, 36)];
    [dish closePath];
    LinearFill(c, dish, @[HEX(0xFFFFFF), HEX(0x9AA6C6)], CGPointMake(50, 22), CGPointMake(50, 33));
    Stroke([dish copy], HEX(0x39466E), 1.0);
    RadialFill(c, Disc(50, 17, 4), @[HEX(0xFFFFFF), HEX(0xFF4A5A), HX(0xFF4A5A, 0)], CGPointMake(50, 17), 6);
    Fill(Disc(50, 17, 2), HEX(0xFF4A5A));
    CGContextRestoreGState(c);
    DrawTwinkles(0);
}

static void DrawHelmet(CGContextRef c) {
    RadialFill(c, Disc(50, 50, 48), @[HX(0xBFD4FF, .25), HX(0xBFD4FF, 0)], CGPointMake(50, 50), 48);
    // Collar ring and ear ports.
    UIBezierPath *collar = RoundRect(24, 76, 52, 14, 6);
    LinearFill(c, collar, @[HEX(0xD7DEEE), HEX(0x7C88A8)], CGPointMake(50, 76), CGPointMake(50, 90));
    Stroke([collar copy], HEX(0x39466E), 1.2);
    for (int k = 0; k < 3; k++) Line(34 + k * 16, 78, 34 + k * 16, 88, HX(0x39466E, .5), 1.0);
    for (int side = 0; side < 2; side++) {
        CGFloat x = side == 0 ? 13 : 87;
        RadialFill(c, Disc(x, 50, 7), @[HEX(0xFFFFFF), HEX(0xA6B0C8)], CGPointMake(x - 1, 48), 10);
        Stroke(Disc(x, 50, 7), HEX(0x39466E), 1.2);
        Fill(Disc(x, 50, 2.6), HEX(0xFF6A4A));
    }
    // Shell.
    UIBezierPath *shell = Disc(50, 48, 37);
    RadialFill(c, shell, @[HEX(0xFFFFFF), HEX(0xE8EDF8), HEX(0xAAB6D2)], CGPointMake(40, 32), 66);
    Stroke(Disc(50, 48, 37), HEX(0x39466E), 1.4);
    // Visor.
    UIBezierPath *visor = RoundRect(26, 30, 48, 36, 17);
    LinearFill(c, visor, @[HEX(0xF2C14E), HEX(0x9A6A08)], CGPointMake(50, 28), CGPointMake(50, 68));
    UIBezierPath *glass = RoundRect(29, 33, 42, 30, 14);
    LinearFill(c, glass, @[HEX(0x4B7BFF), HEX(0x16236E), HEX(0x0A0F33)], CGPointMake(34, 33), CGPointMake(64, 63));
    // Reflected planet and stars on the glass.
    CGContextSaveGState(c);
    [glass addClip];
    RadialFill(c, Disc(58, 58, 11), @[HEX(0xFFB36B), HEX(0xE0602F), HEX(0x7A2A5A)], CGPointMake(55, 55), 14);
    Stroke([UIBezierPath bezierPathWithOvalInRect:CGRectMake(44, 54, 28, 8)], HX(0xFFE48F, .8), 1.2);
    DrawSparkle(38, 42, 3.6, HX(0xFFFFFF, .95));
    Fill(Disc(48, 38, 1.1), HX(0xFFFFFF, .9));
    Fill(Disc(64, 40, 1.0), HX(0xFFFFFF, .9));
    CGContextRestoreGState(c);
    Stroke([glass copy], HX(0xFFFFFF, .35), 1.0);
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(50, 48) radius:29 startAngle:M_PI * 1.08 endAngle:M_PI * 1.42 clockwise:YES], HX(0xFFFFFF, .85), 2.2);
    // Orange stripe on the crown.
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(50, 48) radius:33 startAngle:M_PI * 1.3 endAngle:M_PI * 1.7 clockwise:YES], HEX(0xFF7A3D), 3.0);
    DrawTwinkles(0);
}

/// One half of a planet's ring, squashed into an ellipse. `front` is the half
/// nearest the viewer (it passes in front of the planet).
static void RingHalf(CGContextRef c, CGPoint ctr, CGFloat outer, CGFloat inner, BOOL front) {
    CGFloat a0 = front ? 0 : M_PI, a1 = front ? M_PI : 2 * M_PI;
    UIBezierPath *band = [UIBezierPath bezierPath];
    [band addArcWithCenter:ctr radius:outer startAngle:a0 endAngle:a1 clockwise:YES];
    [band addArcWithCenter:ctr radius:inner startAngle:a1 endAngle:a0 clockwise:NO];
    [band closePath];
    CGAffineTransform squash = CGAffineTransformTranslate(CGAffineTransformScale(CGAffineTransformMakeTranslation(ctr.x, ctr.y), 1, .3), -ctr.x, -ctr.y);
    [band applyTransform:squash];
    LinearFill(c, band, @[HEX(0xFFE48F), HEX(0xD98E2B), HEX(0xFFD27A)], CGPointMake(ctr.x - outer, ctr.y), CGPointMake(ctr.x + outer, ctr.y));
    Stroke([band copy], HEX(0x7A4A0B), .8);
}

static void DrawPlanet(CGContextRef c) {
    RadialFill(c, Disc(50, 50, 48), @[HX(0xC38BFF, .22), HX(0xC38BFF, 0)], CGPointMake(50, 50), 48);
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 50, 52);
    CGContextRotateCTM(c, -20 * M_PI / 180.0);
    CGContextTranslateCTM(c, -50, -52);
    RingHalf(c, CGPointMake(50, 52), 47, 36, NO);
    UIBezierPath *globe = Disc(50, 52, 25);
    RadialFill(c, globe, @[HEX(0xFFC48A), HEX(0xE0602F), HEX(0x8A2A66), HEX(0x3A1250)], CGPointMake(40, 42), 48);
    CGContextSaveGState(c);
    [globe addClip];
    Line(20, 44, 80, 40, HX(0xFFE0B0, .55), 3.2);
    Line(20, 54, 80, 58, HX(0x5A1A5A, .45), 4.0);
    Line(20, 64, 80, 62, HX(0xFFE0B0, .35), 2.4);
    Fill(Oval(52, 56, 14, 8), HX(0xFFE0B0, .5));
    CGContextRestoreGState(c);
    Stroke(Disc(50, 52, 25), HX(0xFFFFFF, .35), 1.0);
    RingHalf(c, CGPointMake(50, 52), 47, 36, YES);
    // A tiny moon.
    RadialFill(c, Disc(86, 30, 4), @[HEX(0xFFFFFF), HEX(0x8A94B0)], CGPointMake(85, 29), 6);
    CGContextRestoreGState(c);
    DrawTwinkles(0);
}

static void DrawUfo(CGContextRef c) {
    // Tractor beam.
    UIBezierPath *beam = [UIBezierPath bezierPath];
    [beam moveToPoint:CGPointMake(38, 70)];
    [beam addLineToPoint:CGPointMake(62, 70)];
    [beam addLineToPoint:CGPointMake(86, 98)];
    [beam addLineToPoint:CGPointMake(14, 98)];
    [beam closePath];
    LinearFill(c, beam, @[HX(0xFFF3A0, .65), HX(0xFFF3A0, 0)], CGPointMake(50, 70), CGPointMake(50, 98));
    // Dome with a little pilot.
    UIBezierPath *dome = [UIBezierPath bezierPath];
    [dome moveToPoint:CGPointMake(32, 52)];
    [dome addCurveToPoint:CGPointMake(68, 52) controlPoint1:CGPointMake(32, 18) controlPoint2:CGPointMake(68, 18)];
    [dome closePath];
    RadialFill(c, dome, @[HX(0xE6FBFF, .95), HX(0x7FD8F0, .85), HX(0x2A86B8, .85)], CGPointMake(44, 34), 30);
    Stroke([dome copy], HEX(0xBFEFFF), 1.2);
    RadialFill(c, Disc(50, 42, 7), @[HEX(0xC8FF8A), HEX(0x4CCB3C)], CGPointMake(48, 40), 9);
    Fill(Oval(44.5, 40, 4, 5), HEX(0x101030));
    Fill(Oval(51.5, 40, 4, 5), HEX(0x101030));
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(44, 30) radius:9 startAngle:M_PI * 1.15 endAngle:M_PI * 1.5 clockwise:YES], HX(0xFFFFFF, .8), 1.6);
    // Saucer body.
    UIBezierPath *saucer = Oval(10, 50, 80, 26);
    LinearFill(c, saucer, @[HEX(0xE4E9F6), HEX(0x8E98BA), HEX(0x4A4F7E)], CGPointMake(50, 50), CGPointMake(50, 76));
    Stroke([saucer copy], HEX(0x262B5A), 1.4);
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(50, 62) radius:36 startAngle:M_PI * 1.08 endAngle:M_PI * 1.92 clockwise:YES], HX(0xFFFFFF, .55), 1.4);
    UIColor *lamp[5] = { HEX(0xFF4A9A), HEX(0xFFE04A), HEX(0x4AFFC8), HEX(0xFFE04A), HEX(0xFF4A9A) };
    CGFloat lx[5] = { 22, 36, 50, 64, 78 }, ly[5] = { 64.5, 68.5, 70, 68.5, 64.5 };
    for (int i = 0; i < 5; i++) {
        RadialFill(c, Disc(lx[i], ly[i], 5), @[HX(0xFFFFFF, .9), HX(0xFFFFFF, 0)], CGPointMake(lx[i], ly[i]), 5);
        Fill(Disc(lx[i], ly[i], 2.6), lamp[i]);
    }
    DrawTwinkles(0);
}

static void DrawAlien(CGContextRef c) {
    RadialFill(c, Disc(50, 50, 48), @[HX(0x7CFF6A, .2), HX(0x7CFF6A, 0)], CGPointMake(50, 50), 48);
    // Antennae.
    for (int side = 0; side < 2; side++) {
        CGFloat s = side == 0 ? -1 : 1;
        UIBezierPath *stalk = [UIBezierPath bezierPath];
        [stalk moveToPoint:CGPointMake(50 + s * 10, 18)];
        [stalk addQuadCurveToPoint:CGPointMake(50 + s * 22, 5) controlPoint:CGPointMake(50 + s * 12, 8)];
        Stroke(stalk, HEX(0x2E9A3A), 2.4);
        RadialFill(c, Disc(50 + s * 22, 5, 4.2), @[HEX(0xFFFFFF), HEX(0xFFE04A), HEX(0xFF8A1F)], CGPointMake(50 + s * 21, 4), 6);
    }
    UIBezierPath *head = [UIBezierPath bezierPath];
    [head moveToPoint:CGPointMake(50, 14)];
    [head addCurveToPoint:CGPointMake(84, 42) controlPoint1:CGPointMake(70, 14) controlPoint2:CGPointMake(84, 26)];
    [head addCurveToPoint:CGPointMake(50, 92) controlPoint1:CGPointMake(84, 66) controlPoint2:CGPointMake(68, 92)];
    [head addCurveToPoint:CGPointMake(16, 42) controlPoint1:CGPointMake(32, 92) controlPoint2:CGPointMake(16, 66)];
    [head addCurveToPoint:CGPointMake(50, 14) controlPoint1:CGPointMake(16, 26) controlPoint2:CGPointMake(30, 14)];
    [head closePath];
    RadialFill(c, head, @[HEX(0xD6FF9A), HEX(0x6FE04A), HEX(0x2E9A3A), HEX(0x146A2A)], CGPointMake(40, 34), 62);
    Stroke([head copy], HEX(0x0E4A1E), 1.4);
    // Eyes.
    for (int side = 0; side < 2; side++) {
        CGFloat s = side == 0 ? -1 : 1;
        CGContextSaveGState(c);
        CGContextTranslateCTM(c, 50 + s * 17, 48);
        CGContextRotateCTM(c, s * -24 * M_PI / 180.0);
        UIBezierPath *eye = Oval(-10, -14, 20, 28);
        RadialFill(c, eye, @[HEX(0x30305A), HEX(0x0A0A1E), HEX(0x000000)], CGPointMake(-3, -6), 22);
        Stroke([eye copy], HEX(0x0E4A1E), 1.0);
        Fill(Oval(-6, -9, 6, 8), HX(0xFFFFFF, .9));
        Fill(Disc(3, 6, 1.6), HX(0xFFFFFF, .7));
        CGContextRestoreGState(c);
    }
    // Nostrils, smile and cheeks.
    Fill(Disc(47, 66, 1), HEX(0x146A2A));
    Fill(Disc(53, 66, 1), HEX(0x146A2A));
    Stroke([UIBezierPath bezierPathWithArcCenter:CGPointMake(50, 66) radius:9 startAngle:M_PI * .2 endAngle:M_PI * .8 clockwise:YES], HEX(0x0E4A1E), 1.6);
    Fill(Oval(24, 62, 7, 4), HX(0xFF9AC8, .45));
    Fill(Oval(69, 62, 7, 4), HX(0xFF9AC8, .45));
    DrawTwinkles(0);
}

static void DrawGalaxy(CGContextRef c) {
    RadialFill(c, Disc(50, 50, 48), @[HX(0x8A5CFF, .55), HX(0x3A1B9A, .3), HX(0x1A0B4A, 0)], CGPointMake(50, 50), 48);
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 50, 50);
    CGContextRotateCTM(c, -28 * M_PI / 180.0);
    CGContextScaleCTM(c, 1.0, .72);
    for (int arm = 0; arm < 2; arm++) {
        for (int i = 0; i < 110; i++) {
            CGFloat t = i / 109.0;
            CGFloat angle = arm * M_PI + t * 3.4 * M_PI;
            CGFloat radius = 6 + t * 40;
            CGFloat wobble = sin(i * 12.9898 + arm * 78.233) * (1.2 + t * 3.2);
            CGFloat x = cos(angle) * (radius + wobble), y = sin(angle) * (radius + wobble);
            CGFloat r = (3.0 - t * 1.8) * (0.8 + 0.4 * fabs(sin(i * 3.7)));
            UIColor *col = t < .25 ? HX(0xFFF3C4, .95) : t < .55 ? HX(0xFF9AE0, .9) : HX(0x6AD8FF, .85);
            Fill(Disc(x, y, r), col);
            RadialFill(c, Disc(x, y, r * 2.2), @[[col colorWithAlphaComponent:.35], [col colorWithAlphaComponent:0]], CGPointMake(x, y), r * 2.2);
        }
    }
    CGContextRestoreGState(c);
    RadialFill(c, Disc(50, 50, 15), @[HEX(0xFFFFFF), HX(0xFFE48F, .9), HX(0xFF9A3D, 0)], CGPointMake(50, 50), 15);
    for (int i = 0; i < 12; i++) {
        CGFloat x = 50 + cos(i * 2.4) * (30 + (i % 4) * 5), y = 50 + sin(i * 2.4) * (24 + (i % 3) * 7);
        Fill(Disc(x, y, 1.1 + (i % 2) * .5), HX(0xFFFFFF, .9));
    }
    DrawSparkle(14, 16, 6, HX(0xFFFFFF, .95));
    DrawSparkle(88, 84, 5.5, HX(0xBFD4FF, .95));
}

static void DrawHat(CGContextRef c) {
    // The scatter: a golden warp star ringed by an orbit.
    RadialFill(c, Disc(50, 50, 48), @[HX(0xFFF1A0, .65), HX(0xFFC83A, .28), HX(0xFF9A1F, 0)], CGPointMake(50, 50), 48);
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 50, 50);
    CGContextRotateCTM(c, -24 * M_PI / 180.0);
    Stroke(Oval(-44, -12, 88, 24), HX(0x7FE9FF, .8), 1.6);
    CGContextRestoreGState(c);
    UIBezierPath *star = StarPath(50, 52, 38, 16, 5, 0);
    LinearFill(c, star, @[HEX(0xFFF6B8), HEX(0xFFC83A), HEX(0xD98E10)], CGPointMake(30, 14), CGPointMake(70, 90));
    Stroke([star copy], HEX(0x7A4A00), 1.6);
    UIBezierPath *facet = StarPath(50, 52, 24, 10, 5, 0);
    LinearFill(c, facet, @[HEX(0xFFFFFF), HEX(0xFFE48F)], CGPointMake(36, 30), CGPointMake(64, 72));
    for (int i = 0; i < 5; i++) {
        CGFloat a = (-90 + i * 72) * M_PI / 180.0;
        Line(50, 52, 50 + cos(a) * 36, 52 + sin(a) * 36, HX(0x9A6A08, .45), .8);
    }
    RadialFill(c, Disc(50, 52, 6), @[HEX(0xFFFFFF), HEX(0x7FE9FF), HEX(0x2A86B8)], CGPointMake(48, 50), 8);
    Stroke(Disc(50, 52, 6), HEX(0x7A4A00), .9);
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 50, 50);
    CGContextRotateCTM(c, -24 * M_PI / 180.0);
    UIBezierPath *front = [UIBezierPath bezierPathWithArcCenter:CGPointZero radius:1 startAngle:0 endAngle:M_PI clockwise:YES];
    [front applyTransform:CGAffineTransformMakeScale(44, 12)];
    Stroke(front, HX(0xBFF4FF, .95), 1.8);
    Fill(Disc(44, 0, 3), HEX(0xFFFFFF));
    CGContextRestoreGState(c);
    DrawSparkle(12, 18, 6.5, HX(0xFFFFFF, .95));
    DrawSparkle(90, 80, 5.5, HX(0xFFF6C4, .95));
}

#pragma mark - Public API

static NSCache<NSString *, UIImage *> *ArtCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 40; });
    return cache;
}

@implementation BRStarlightOdysseyArt

+ (NSString *)nameForSymbol:(SOSymbol)symbol {
    switch (symbol) {
        case SOSymbolRocket: return @"Rocket";
        case SOSymbolMoon: return @"Moon";
        case SOSymbolSatellite: return @"Satellite";
        case SOSymbolHelmet: return @"Space Helmet";
        case SOSymbolPlanet: return @"Ringed Planet";
        case SOSymbolUfo: return @"UFO";
        case SOSymbolAlien: return @"Alien";
        case SOSymbolGalaxy: return @"Galaxy";
        case SOSymbolHat: return @"Warp Star";
        default: return @"";
    }
}

+ (UIImage *)imageForSymbol:(SOSymbol)symbol size:(CGSize)size {
    if (symbol < 0 || symbol >= SOSymbolCount || size.width < 1 || size.height < 1) return nil;
    NSString *key = [NSString stringWithFormat:@"s%d-%.0fx%.0f", (int)symbol, size.width, size.height];
    UIImage *cached = [ArtCache() objectForKey:key];
    if (cached) return cached;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextScaleCTM(c, size.width / 100.0, size.height / 100.0);
        switch (symbol) {
            case SOSymbolRocket: DrawRocket(c); break;
            case SOSymbolMoon: DrawMoon(c); break;
            case SOSymbolSatellite: DrawSatellite(c); break;
            case SOSymbolHelmet: DrawHelmet(c); break;
            case SOSymbolPlanet: DrawPlanet(c); break;
            case SOSymbolUfo: DrawUfo(c); break;
            case SOSymbolAlien: DrawAlien(c); break;
            case SOSymbolGalaxy: DrawGalaxy(c); break;
            case SOSymbolHat: DrawHat(c); break;
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
        LinearFill(c, card, @[HEX(0x2F2E8C), HEX(0x0C0C3A)], CGPointMake(50, 0), CGPointMake(50, 140));
        // Scattered stars across the back.
        CGContextSaveGState(c);
        [card addClip];
        for (int i = 0; i < 46; i++) {
            CGFloat x = fmod(i * 37.3 + 11, 96) + 2, y = fmod(i * 23.7 + 5, 136) + 2;
            Fill(Disc(x, y, .6 + (i % 3) * .35), HX(0xFFFFFF, .35 + (i % 4) * .12));
        }
        CGContextRestoreGState(c);
        Stroke(RoundRect(4.5, 4.5, 91, 131, 8), HEX(0x7FE9FF), 2.0);
        Stroke(RoundRect(8, 8, 84, 124, 6), HX(0x7FE9FF, .45), .8);
        UIBezierPath *medal = Disc(50, 70, 27);
        RadialFill(c, medal, @[HEX(0x4B4BD8), HEX(0x14146A)], CGPointMake(44, 62), 34);
        Stroke(Disc(50, 70, 27), HEX(0xF2C14E), 2.0);
        Stroke(Disc(50, 70, 22), HX(0xF2C14E, .5), .8);
        UIBezierPath *star = StarPath(50, 71, 19, 8, 5, 0);
        LinearFill(c, star, @[HEX(0xFFF6B8), HEX(0xFFC83A), HEX(0xD98E10)], CGPointMake(36, 54), CGPointMake(64, 88));
        Stroke([star copy], HEX(0x7A4A00), 1.0);
        for (NSArray *pt in @[@[@16, @70], @[@84, @70], @[@50, @22], @[@50, @118]]) DrawSparkle([pt[0] doubleValue], [pt[1] doubleValue], 4.5, HX(0xBFF4FF, .9));
    }];
    [ArtCache() setObject:image forKey:key];
    return image;
}

+ (void)purgeCache { [ArtCache() removeAllObjects]; }

@end
