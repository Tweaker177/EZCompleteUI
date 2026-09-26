// BRSmartKeyboardView.m
// BrainRotGame
// EZCompleteUI
//
// See BRSmartKeyboardView.h. Touch routing relies on ordinary UIKit
// hit-testing: the four knob controls are real subviews near the bottom,
// so touches that land on them go straight to the knobs and never reach
// this view's own touchesBegan/Moved/Ended overrides below. Only touches
// over the empty key-row area (which has no subviews) reach those
// overrides, which is what keeps the multitouch key-tracking logic simple.

#import "BRSmartKeyboardView.h"
#import "BRSynthEngine.h"

#pragma mark - BRMiniKnobControl (private helper — see header's dependency note)

@interface BRMiniKnobControl : UIControl
@property (nonatomic, assign) float value; // 0...1
@property (nonatomic, copy) NSString *label;
@end

@interface BRMiniKnobControl ()
@property (nonatomic, strong) CAShapeLayer *indicatorLayer;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, assign) CGFloat valueAtTouchStart;
@property (nonatomic, strong) UIPanGestureRecognizer *panRecognizer;
@end

@implementation BRMiniKnobControl

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _value = 0.5f;
        self.backgroundColor = [UIColor clearColor];
        self.indicatorLayer = [CAShapeLayer layer];
        self.indicatorLayer.strokeColor = [UIColor whiteColor].CGColor;
        self.indicatorLayer.lineWidth = 2.0;
        self.indicatorLayer.lineCap = kCALineCapRound;
        [self.layer addSublayer:self.indicatorLayer];

        self.captionLabel = [[UILabel alloc] init];
        self.captionLabel.font = [UIFont boldSystemFontOfSize:9];
        self.captionLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
        self.captionLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:self.captionLabel];
        self.valueLabel = [[UILabel alloc] init];
        self.valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightBold];
        self.valueLabel.textColor = [UIColor colorWithWhite:1 alpha:0.92];
        self.valueLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:self.valueLabel];
        self.panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        self.panRecognizer.minimumNumberOfTouches = 1;
        self.panRecognizer.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:self.panRecognizer];
    }
    return self;
}

- (void)setLabel:(NSString *)label {
    _label = label;
    self.captionLabel.text = label;
}

- (void)setValue:(float)value {
    _value = MAX(0.0f, MIN(1.0f, value));
    self.valueLabel.text = [NSString stringWithFormat:@"%.0f%%", _value * 100.0f];
    [self setNeedsLayout];
    [self setNeedsDisplay];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat knobDiameter = MIN(self.bounds.size.width, self.bounds.size.height - 26);
    CGRect knobRect = CGRectMake((self.bounds.size.width - knobDiameter) / 2, 0, knobDiameter, knobDiameter);
    self.captionLabel.frame = CGRectMake(0, CGRectGetMaxY(knobRect), self.bounds.size.width, 11);
    self.valueLabel.frame = CGRectMake(0, CGRectGetMaxY(knobRect) + 10, self.bounds.size.width, 11);

    UIBezierPath *track = [UIBezierPath bezierPath];
    CGPoint center = CGPointMake(CGRectGetMidX(knobRect), CGRectGetMidY(knobRect));
    CGFloat radius = knobDiameter / 2 - 3;
    // Standard knob sweep: -135°...+135°, i.e. 270° of travel.
    CGFloat angle = -M_PI * 0.75 + self.value * (M_PI * 1.5);
    [track moveToPoint:center];
    [track addLineToPoint:CGPointMake(center.x + cos(angle) * radius, center.y + sin(angle) * radius)];
    self.indicatorLayer.path = track.CGPath;
}

- (void)drawRect:(CGRect)rect {
    // Knob body — drawn here rather than as a layer so it composites under
    // the CAShapeLayer indicator without extra layer bookkeeping.
    CGFloat knobDiameter = MIN(self.bounds.size.width, self.bounds.size.height - 26);
    CGRect knobRect = CGRectMake((self.bounds.size.width - knobDiameter) / 2, 0, knobDiameter, knobDiameter);
    UIBezierPath *body = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(knobRect, 2, 2)];
    [[UIColor colorWithRed:0.42 green:0.32 blue:0.78 alpha:1.0] setFill];
    [body fill];
    [[UIColor colorWithWhite:1 alpha:0.18] setStroke];
    body.lineWidth = 1.5;
    [body stroke];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) self.valueAtTouchStart = self.value;
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        // Matches the stationary Music Lab knobs: a short, direct vertical
        // drag gives precise adjustment without fighting parent touch routing.
        CGFloat delta = -[pan translationInView:self].y / 72.0;
        CGFloat previous = self.value;
        self.value = self.valueAtTouchStart + delta;
        if (fabs(self.value - previous) > 0.0001) {
            [self setNeedsDisplay];
            [self sendActionsForControlEvents:UIControlEventValueChanged];
        }
    }
}

@end

#pragma mark - BRSmartKeyboardView

@interface BRSmartKeyboardView ()
@property (nonatomic, strong) NSArray<NSNumber *> *keySemitones;   // left-to-right, ascending pitch
@property (nonatomic, strong) NSMutableDictionary<NSValue *, NSNumber *> *activeTouchKeyIndex; // wrapped UITouch* -> key index
@property (nonatomic, strong) NSArray<BRMiniKnobControl *> *knobs;
@end

@implementation BRSmartKeyboardView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
        self.layer.cornerRadius = 10;
        self.clipsToBounds = YES;
        self.multipleTouchEnabled = YES;
        self.activeTouchKeyIndex = [NSMutableDictionary dictionary];
        self.keySemitones = @[];

        NSMutableArray<BRMiniKnobControl *> *knobs = [NSMutableArray array];
        for (NSInteger i = 0; i < 3; i++) {
            BRMiniKnobControl *knob = [[BRMiniKnobControl alloc] init];
            [knob addTarget:self action:@selector(knobChanged:) forControlEvents:UIControlEventValueChanged];
            [self addSubview:knob];
            [knobs addObject:knob];
        }
        self.knobs = knobs;
        self.knobs[0].label = @"Filter";
        self.knobs[1].label = @"Saturate";
        self.knobs[2].label = @"Reverb";
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat knobRowHeight = 66;
    CGFloat knobY = self.bounds.size.height - knobRowHeight;
    CGFloat knobWidth = self.bounds.size.width / self.knobs.count;
    for (NSInteger i = 0; i < (NSInteger)self.knobs.count; i++) {
        self.knobs[i].frame = CGRectMake(i * knobWidth, knobY + 4, knobWidth, knobRowHeight - 8);
    }
    [self setNeedsDisplay];
}

#pragma mark - Key layout

- (NSArray<NSNumber *> *)scaleDegreesForCurrentSynthScale {
    // Mirrors BRSynthEngine's own scale tables. Duplicated rather than
    // exposed publicly from BRSynthEngine, since "what intervals make up a
    // scale" is UI-layout concern here, not something the audio engine
    // needs to hand out.
    switch (self.synth ? self.synth.scale : BRSynthScalePentatonic) {
        case BRSynthScaleMajor:      return @[@0, @2, @4, @5, @7, @9, @11];
        case BRSynthScaleMinor:      return @[@0, @2, @3, @5, @7, @8, @10];
        case BRSynthScalePentatonic: return @[@0, @2, @4, @7, @9];
    }
    return @[@0, @2, @4, @7, @9];
}

- (void)refreshFromSynth {
    NSArray<NSNumber *> *degrees = [self scaleDegreesForCurrentSynthScale];
    NSInteger root = self.synth ? self.synth.rootSemitone : 7;
    NSMutableArray<NSNumber *> *semis = [NSMutableArray array];
    for (NSNumber *degree in degrees) {
        [semis addObject:@(root + degree.integerValue)];
    }
    [semis addObject:@(root + 12)]; // always end on the octave-up root, so the ear has "home" to land on
    self.keySemitones = semis;

    if (self.synth) {
        self.knobs[0].value = self.synth.filterBrightness;
        self.knobs[1].value = self.synth.saturationDrive;
        self.knobs[2].value = self.synth.reverbMix;
    }

    [self setNeedsDisplay];
    [self setNeedsLayout];
}

- (CGRect)keyRowRect {
    // The controller reserves the middle strip for Use/Settings and places
    // these quick knobs along the bottom. Keep keyboard touches out of that
    // strip even though this view remains the shared background container.
    return CGRectMake(0, 0, self.bounds.size.width, MIN(90.0, self.bounds.size.height - 60));
}

- (CGFloat)centerXForKeyIndex:(NSInteger)index {
    if (self.keySemitones.count == 0) return self.bounds.size.width / 2;
    CGFloat keyWidth = self.bounds.size.width / self.keySemitones.count;
    return keyWidth * index + keyWidth / 2;
}

- (nullable NSNumber *)keyIndexAtPoint:(CGPoint)point {
    CGRect keyRow = [self keyRowRect];
    if (!CGRectContainsPoint(keyRow, point)) return nil;
    if (self.keySemitones.count == 0) return nil;
    CGFloat keyWidth = self.bounds.size.width / self.keySemitones.count;
    NSInteger index = (NSInteger)(point.x / keyWidth);
    index = MAX(0, MIN((NSInteger)self.keySemitones.count - 1, index));
    return @(index);
}

- (void)drawRect:(CGRect)rect {
    CGRect keyRow = [self keyRowRect];
    if (self.keySemitones.count == 0) return;
    CGFloat keyWidth = keyRow.size.width / self.keySemitones.count;

    static NSArray<NSString *> *noteNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        noteNames = @[@"A", @"A#", @"B", @"C", @"C#", @"D", @"D#", @"E", @"F", @"F#", @"G", @"G#"];
    });

    for (NSInteger i = 0; i < (NSInteger)self.keySemitones.count; i++) {
        CGRect keyRect = CGRectMake(keyRow.origin.x + i * keyWidth + 1, keyRow.origin.y + 1, keyWidth - 2, keyRow.size.height - 2);
        BOOL isHeld = [self.activeTouchKeyIndex.allValues containsObject:@(i)];
        UIColor *fill = isHeld
            ? [UIColor colorWithRed:0.62 green:0.47 blue:0.98 alpha:1.0]
            : [UIColor colorWithRed:0.16 green:0.12 blue:0.28 alpha:1.0];
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:keyRect cornerRadius:6];
        [fill setFill];
        [path fill];
        [[UIColor colorWithWhite:1 alpha:0.12] setStroke];
        path.lineWidth = 1;
        [path stroke];

        NSInteger semitone = self.keySemitones[i].integerValue;
        NSString *name = noteNames[((semitone % 12) + 12) % 12];
        NSDictionary *attrs = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:12],
                                  NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:isHeld ? 0.95 : 0.6] };
        CGSize textSize = [name sizeWithAttributes:attrs];
        [name drawAtPoint:CGPointMake(CGRectGetMidX(keyRect) - textSize.width / 2,
                                       CGRectGetMaxY(keyRect) - textSize.height - 6)
           withAttributes:attrs];
    }
}

#pragma mark - Touch handling (key row only — knobs are real subviews and absorb their own touches)

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        NSNumber *keyIndex = [self keyIndexAtPoint:[touch locationInView:self]];
        if (!keyIndex) continue;
        self.activeTouchKeyIndex[[NSValue valueWithNonretainedObject:touch]] = keyIndex;
        [self triggerKeyIndex:keyIndex.integerValue];
    }
    [self recomputeSteer];
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    BOOL changed = NO;
    for (UITouch *touch in touches) {
        NSValue *key = [NSValue valueWithNonretainedObject:touch];
        NSNumber *newIndex = [self keyIndexAtPoint:[touch locationInView:self]];
        NSNumber *oldIndex = self.activeTouchKeyIndex[key];
        if (!newIndex) {
            // Slid off the key row entirely (e.g. down toward the knobs) — release it.
            if (oldIndex) { [self.activeTouchKeyIndex removeObjectForKey:key]; changed = YES; }
            continue;
        }
        if (![newIndex isEqualToNumber:oldIndex]) {
            self.activeTouchKeyIndex[key] = newIndex;
            [self triggerKeyIndex:newIndex.integerValue]; // glissando — each newly-entered key re-triggers
            changed = YES;
        }
    }
    if (changed) {
        [self recomputeSteer];
        [self setNeedsDisplay];
    }
}

- (void)touchesEndedOrCancelled:(NSSet<UITouch *> *)touches {
    for (UITouch *touch in touches) {
        [self.activeTouchKeyIndex removeObjectForKey:[NSValue valueWithNonretainedObject:touch]];
    }
    [self recomputeSteer];
    [self setNeedsDisplay];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self touchesEndedOrCancelled:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self touchesEndedOrCancelled:touches]; }

- (void)triggerKeyIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.keySemitones.count) return;
    NSInteger semitone = self.keySemitones[index].integerValue;
    if (self.onNote) self.onNote(semitone, 1.1f); // slightly hotter than a passive collision hit — this is an intentional press
}

- (void)recomputeSteer {
    if (self.activeTouchKeyIndex.count == 0) {
        if (self.onSteerChanged) self.onSteerChanged(0);
        return;
    }
    CGFloat sumX = 0;
    for (NSNumber *index in self.activeTouchKeyIndex.allValues) {
        sumX += [self centerXForKeyIndex:index.integerValue];
    }
    CGFloat avgX = sumX / self.activeTouchKeyIndex.count;
    CGFloat normalized = (avgX / MAX(self.bounds.size.width, 1)) * 2.0 - 1.0;
    if (self.onSteerChanged) self.onSteerChanged(MAX(-1.0, MIN(1.0, normalized)));
}

#pragma mark - Knob row

- (void)knobChanged:(BRMiniKnobControl *)knob {
    if (!self.synth) return;
    NSInteger index = [self.knobs indexOfObject:knob];
    switch (index) {
        case 0: self.synth.filterBrightness = knob.value; break;
        case 1: self.synth.saturationDrive  = knob.value; break;
        case 2: self.synth.reverbMix        = knob.value; break;
        default: break;
    }
    if (self.onSettingsChanged) self.onSettingsChanged();
}

@end
