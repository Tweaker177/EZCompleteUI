//
//  EZWaveformRangeSelector.m
//  EZTTSLibrary
//

#import "EZWaveformRangeSelector.h"

static CGFloat const kEZHandleWidth = 4.0;
static CGFloat const kEZMinGapFraction = 0.01;  // handles can't cross / fully overlap

typedef NS_ENUM(NSInteger, EZActiveHandle) {
    EZActiveHandleNone,
    EZActiveHandleStart,
    EZActiveHandleEnd,
};

@interface EZWaveformRangeSelector ()
@property (nonatomic, assign) EZActiveHandle activeHandle;
@end

@implementation EZWaveformRangeSelector

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _startFraction = 0.0;
        _endFraction = 1.0;
        _startHandleColor = [UIColor systemGreenColor];
        _endHandleColor = [UIColor systemRedColor];
        _highlightColor = [UIColor colorWithWhite:0.0 alpha:0.35];
        _loopBarColor = [UIColor systemYellowColor];
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)setStartFraction:(CGFloat)startFraction {
    _startFraction = MAX(0.0, MIN(startFraction, _endFraction - kEZMinGapFraction));
    [self setNeedsDisplay];
}

- (void)setEndFraction:(CGFloat)endFraction {
    _endFraction = MIN(1.0, MAX(endFraction, _startFraction + kEZMinGapFraction));
    [self setNeedsDisplay];
}

- (void)setLoopEnabled:(BOOL)loopEnabled {
    _loopEnabled = loopEnabled;
    [self setNeedsDisplay];
}

- (void)setLoopBarColor:(UIColor *)loopBarColor {
    _loopBarColor = loopBarColor;
    [self setNeedsDisplay];
}

#pragma mark - Touch tracking (UIControl, not gesture recognizers — see header comment)

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(nullable UIEvent *)event {
    CGFloat width = self.bounds.size.width;
    if (width <= 0) return NO;

    CGFloat touchX = [touch locationInView:self].x;
    CGFloat startX = self.startFraction * width;
    CGFloat endX = self.endFraction * width;

    CGFloat distToStart = fabs(touchX - startX);
    CGFloat distToEnd = fabs(touchX - endX);
    self.activeHandle = (distToStart <= distToEnd) ? EZActiveHandleStart : EZActiveHandleEnd;

    [self sendActionsForControlEvents:UIControlEventEditingDidBegin];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(nullable UIEvent *)event {
    CGFloat width = self.bounds.size.width;
    if (width <= 0) return NO;

    CGFloat fraction = [touch locationInView:self].x / width;
    fraction = MAX(0.0, MIN(1.0, fraction));

    if (self.activeHandle == EZActiveHandleStart) {
        self.startFraction = fraction;
    } else if (self.activeHandle == EZActiveHandleEnd) {
        self.endFraction = fraction;
    }

    [self sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

- (void)endTrackingWithTouch:(nullable UITouch *)touch withEvent:(nullable UIEvent *)event {
    self.activeHandle = EZActiveHandleNone;
    [self sendActionsForControlEvents:UIControlEventEditingDidEnd];
}

- (void)cancelTrackingWithEvent:(nullable UIEvent *)event {
    self.activeHandle = EZActiveHandleNone;
    [self sendActionsForControlEvents:UIControlEventEditingDidEnd];
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect {
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    CGFloat startX = self.startFraction * width;
    CGFloat endX = self.endFraction * width;

    // Dim everything OUTSIDE the selection rather than tinting the inside — this is the
    // convention pro audio editors (Ableton, Logic, Audacity) use, and reads much more
    // like an actual selection than a plain colored overlay on top of it.
    [self.highlightColor setFill];
    if (startX > 0) {
        [[UIBezierPath bezierPathWithRect:CGRectMake(0, 0, startX, height)] fill];
    }
    if (endX < width) {
        [[UIBezierPath bezierPathWithRect:CGRectMake(endX, 0, width - endX, height)] fill];
    }

    if (self.loopEnabled && endX > startX) {
        // A bar across the top connecting the two handles — the selection
        // is a loop. Drawn at the handle tabs' mid-height so it reads as
        // linking them, and under the handles themselves.
        CGFloat barHeight = 4.0;
        CGRect barRect = CGRectMake(startX, 2.5, endX - startX, barHeight);
        [self.loopBarColor setFill];
        [[UIBezierPath bezierPathWithRoundedRect:barRect cornerRadius:barHeight / 2.0] fill];
    }

    [self drawHandleAtX:startX color:self.startHandleColor height:height];
    [self drawHandleAtX:endX color:self.endHandleColor height:height];
}

/// A thin vertical line plus small rounded grip tabs at the top and bottom — brackets
/// the waveform the way a trim handle does in a real audio editor, rather than reading
/// as just a plain colored bar.
- (void)drawHandleAtX:(CGFloat)x color:(UIColor *)color height:(CGFloat)height {
    CGFloat lineWidth = kEZHandleWidth;
    CGFloat tabWidth = 14.0;
    CGFloat tabHeight = 9.0;

    [color setFill];

    UIBezierPath *line = [UIBezierPath bezierPathWithRect:CGRectMake(x - lineWidth / 2.0, 0, lineWidth, height)];
    [line fill];

    UIBezierPath *topTab = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x - tabWidth / 2.0, 0, tabWidth, tabHeight)
                                                        cornerRadius:3.0];
    [topTab fill];

    UIBezierPath *bottomTab = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x - tabWidth / 2.0, height - tabHeight, tabWidth, tabHeight)
                                                           cornerRadius:3.0];
    [bottomTab fill];
}

@end
