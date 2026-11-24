// BRPenguinParadeSlotViewController.m
// EZCompleteUI — Penguin Parade
//
// Client half of the `ez-penguin-parade-spin` edge function. The server owns
// the reels, every payout, the free-spin award roll, the x2/x3/x5 egg hatch and
// all EZ Coins; this screen renders what it is told and stages the drama:
//   - reels blur while the request is in flight, then land left to right
//   - each golden egg that lands rings the same bell one pentatonic step higher
//   - from the second egg a drum roll builds, and the remaining reels slow down
//   - five eggs fire an alarm with ringing bells, confetti and a shaking cabinet
//   - 3+ eggs open the penguin egg-hatch pick; the server decides what each egg hides
//   - free spins then play themselves with every win multiplied
// All art and sound are generated in code (BRPenguinParadeArt / Audio).

#import "BRPenguinParadeSlotViewController.h"
#import "BRSlotChatBar.h"
#import "BRPenguinParadeEngine.h"
#import "BRPenguinParadeArt.h"
#import "BRPenguinParadeAudio.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZSupabaseConfig.h"
#import "EZAppErrorReporter.h"
#import "EZCoinStoreViewController.h"

#define PGLoc(key, en) NSLocalizedStringWithDefaultValue(key, nil, NSBundle.mainBundle, en, nil)

static NSString *const kPGMutedKey = @"BRPenguinParadeMuted";
static NSString *const kPGLinesKey = @"BRPenguinParadeLines";
static NSString *const kPGBetKey = @"BRPenguinParadeBetIndex";
static NSString *const kPGVIPBetKey = @"BRPenguinParadeVIPBetIndex";
static NSString *const kPGMeterKey = @"BRPenguinParadeMeterEggs";   // display cache only; the server owns the real count
static const NSInteger kPGLoopPeriod = 8;        // cells in the seamless blur loop
static const CGFloat kPGLoopSpeed = 22.0;        // cells per second while blurring

static NSArray<NSNumber *> *PGBets(void) { return @[@1, @5, @10, @15, @25]; }
static NSArray<NSNumber *> *PGVIPBets(void) { return @[@1, @5, @10, @15, @25, @50, @75, @125]; }
static NSArray<NSString *> *PGSymbolNames(void) {
    return @[@"snowflake", @"fish", @"igloo", @"cocoa", @"seal", @"whale", @"chick", @"emperor", @"egg"];
}

static UIColor *PGC(uint32_t hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:1];
}
static UIColor *PGGold(void) { return PGC(0xF2C14E); }

static NSString *PGNum(NSInteger n) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [NSNumberFormatter new]; formatter.numberStyle = NSNumberFormatterDecimalStyle; });
    return [formatter stringFromNumber:@(n)] ?: [NSString stringWithFormat:@"%ld", (long)n];
}

/// NSNull-safe JSON readers. The server should always send numbers and
/// strings, but a null or mistyped value must fail closed, never crash on
/// integerValue / boolValue (NSNull answers neither).
static NSInteger PGInteger(id value) { return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0; }
static BOOL PGBool(id value) { return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO; }
static NSString *PGString(id value) { return [value isKindOfClass:NSString.class] && ((NSString *)value).length ? value : nil; }

/// Random symbol for the blur. Eggs only appear when `allowEgg` so a stopped
/// reel never shows a stray egg next to the real result.
static int PGFiller(BOOL allowEgg) {
    if (allowEgg && arc4random_uniform(18) == 0) return PGSymbolEgg;
    return (int)arc4random_uniform(PGSymbolEgg);
}

static UIImage *PGParticleImage(BOOL coin) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2;
    CGSize size = CGSizeMake(18, 18);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        if (coin) {   // a gold coin with a square hole
            UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 16, 16)];
            [path appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(6.5, 6.5, 5, 5)]];
            path.usesEvenOddFillRule = YES;
            [PGGold() setFill]; [path fill];
            [PGC(0x9A6A08) setStroke]; path.lineWidth = 1; [path stroke];
        } else {      // a blue-and-gold ice shard
            UIBezierPath *path = [UIBezierPath bezierPath];
            [path moveToPoint:CGPointMake(9, 1)]; [path addLineToPoint:CGPointMake(15, 9)];
            [path addLineToPoint:CGPointMake(9, 17)]; [path addLineToPoint:CGPointMake(3, 9)]; [path closePath];
            [PGC(0x4FB7F0) setFill]; [path fill];
            [PGGold() setStroke]; path.lineWidth = 1.2; [path stroke];
        }
    }];
}

/// One soft six-arm flake for the ambient snowfall.
static UIImage *PGSnowImage(void) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2;
    CGSize size = CGSizeMake(14, 14);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextTranslateCTM(c, 7, 7);
        [[UIColor colorWithWhite:1 alpha:.95] setStroke];
        for (int k = 0; k < 3; k++) {
            CGContextSaveGState(c);
            CGContextRotateCTM(c, k * M_PI / 3);
            UIBezierPath *arm = [UIBezierPath bezierPath];
            [arm moveToPoint:CGPointMake(0, -5.5)]; [arm addLineToPoint:CGPointMake(0, 5.5)];
            arm.lineWidth = 1.4; arm.lineCapStyle = kCGLineCapRound;
            [arm stroke];
            CGContextRestoreGState(c);
        }
        [UIColor.whiteColor setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(-1.2, -1.2, 2.4, 2.4)] fill];
    }];
}

#pragma mark - Gradient view

@interface PGGradientView : UIView
@property (nonatomic, readonly) CAGradientLayer *gradientLayer;
@end
@implementation PGGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }
- (CAGradientLayer *)gradientLayer { return (CAGradientLayer *)self.layer; }
@end

#pragma mark - Gradient button

/// A button filled with a vertical gradient instead of a flat colour,
/// with an optional glossy sheen across its top half and a small
/// press-down scale while it is held.
@interface PGControlButton : UIButton
@property (nonatomic, strong) CAGradientLayer *fillGradient;
@property (nonatomic, strong) CAGradientLayer *glossGradient;
@end

@implementation PGControlButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _fillGradient = [CAGradientLayer layer];
        _fillGradient.startPoint = CGPointMake(.5, 0);
        _fillGradient.endPoint = CGPointMake(.5, 1);
        [self.layer insertSublayer:_fillGradient atIndex:0];
        _glossGradient = [CAGradientLayer layer];
        _glossGradient.colors = @[(id)[UIColor colorWithWhite:1 alpha:.38].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
        _glossGradient.startPoint = CGPointMake(.5, 0);
        _glossGradient.endPoint = CGPointMake(.5, 1);
        _glossGradient.hidden = YES;
        [self.layer insertSublayer:_glossGradient atIndex:1];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.fillGradient.frame = self.bounds;
    self.fillGradient.cornerRadius = self.layer.cornerRadius;
    self.glossGradient.frame = CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height * .55);
    self.glossGradient.cornerRadius = self.layer.cornerRadius;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:.14 animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(.965, .965) : CGAffineTransformIdentity;
    }];
}

@end

#pragma mark - Pay table sheet

@interface PGPaytableViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@end

@implementation PGPaytableViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PGC(0x061A33);
    UISheetPresentationController *sheet = self.sheetPresentationController;
    if (sheet) {
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    }
    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = PGLoc(@"BRSlot.PG.Pays.Title", @"Penguin Parade Pays");
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightHeavy];
    title.textColor = PGGold();
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = UIColor.clearColor;
    self.table.separatorColor = [PGGold() colorWithAlphaComponent:.25];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.allowsSelection = NO;
    self.table.rowHeight = 62;
    UILabel *footer = [UILabel new];
    footer.numberOfLines = 0;
    footer.textColor = [UIColor colorWithWhite:1 alpha:.82];
    footer.font = [UIFont systemFontOfSize:13];
    footer.text = PGLoc(@"BRSlot.PG.Pays.Rules",
        @"HOW TO PLAY\n\n• 9 paylines. Matching symbols pay left to right from reel 1: 3, 4 or 5 in a row. Prizes multiply your bet per line.\n• Golden Eggs are scatters and pay anywhere. A spin never shows more than five.\n• 3 eggs = 5–8 free spins, 4 eggs = 14–16, 5 eggs = 25–30.\n• Before free spins begin, pick one of three penguins holding an egg. Every egg hatches a chick wearing ×2, ×3 or ×5, and your pick multiplies every line win in the bonus.\n• Eggs during free spins add more spins (up to 100 banked).\n• EGG METER: every golden egg that lands on any spin flies into the oval meter above the reels. When it is full it explodes and pays bonus coins, then starts over. It remembers its level between visits.\n• Free spins cost nothing. Spins and payouts are decided on the server.");
    CGSize fit = [footer sizeThatFits:CGSizeMake(UIScreen.mainScreen.bounds.size.width - 40, CGFLOAT_MAX)];
    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, fit.height + 40)];
    footer.frame = CGRectMake(20, 12, UIScreen.mainScreen.bounds.size.width - 40, fit.height);
    [wrap addSubview:footer];
    self.table.tableFooterView = wrap;
    [self.view addSubview:self.table];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.table.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return PGSymbolCount; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"pay"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"pay"];
    PGSymbol symbol = (PGSymbol)(PGSymbolCount - 1 - path.row);   // egg first, then emperor down to snowflake
    cell.backgroundColor = UIColor.clearColor;
    cell.imageView.image = [BRPenguinParadeArt imageForSymbol:symbol size:CGSizeMake(46, 46)];
    cell.textLabel.textColor = PGGold();
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:.85];
    cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    cell.detailTextLabel.numberOfLines = 2;
    cell.textLabel.text = [BRPenguinParadeArt nameForSymbol:symbol];
    if (symbol == PGSymbolEgg) {
        cell.detailTextLabel.text = PGLoc(@"BRSlot.PG.Pays.Egg", @"Scatter · 3 = 5–8 free spins · 4 = 14–16 · 5 = 25–30");
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:PGLoc(@"BRSlot.PG.Pays.Row", @"3×  %ld    4×  %ld    5×  %ld   (× bet per line)"),
                                     (long)PGPayoutUnits(symbol, 3), (long)PGPayoutUnits(symbol, 4), (long)PGPayoutUnits(symbol, 5)];
    }
    return cell;
}

@end

#pragma mark - Main screen

@interface BRPenguinParadeSlotViewController ()
@property (nonatomic, strong) BRPenguinParadeAudio *audio;
@property (nonatomic, strong) BRSlotChatBar *chatBar;
@property (nonatomic, strong) PGGradientView *background;
@property (nonatomic, strong) UIImageView *sceneryView;          // code-drawn arctic backdrop behind the header
@property (nonatomic, strong) UIImageView *headerPenguinView;   // the header penguin, pacing back and forth
@property (nonatomic, strong) NSLayoutConstraint *headerPenguinLeading;
@property (nonatomic, assign) BOOL penguinWalkActive;
@property (nonatomic, assign) CGFloat backdropWidth;            // width the backdrop was last rendered at
@property (nonatomic, strong) CAEmitterLayer *snowEmitter;      // ambient snowfall over the whole screen
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UILabel *balanceLabel, *winLabel, *bannerLabel, *messageLabel, *totalBetLabel;
@property (nonatomic, strong) PGGradientView *infoCard;         // elevated card behind the balance / win blocks
@property (nonatomic, strong) UIStackView *meterEggStack;       // the three golden eggs on the feature bar
@property (nonatomic, strong) NSMutableArray<UIImageView *> *meterEggViews;
@property (nonatomic, strong) UILabel *meterChevron;
@property (nonatomic, strong) NSLayoutConstraint *bannerLeading, *bannerTrailing;
@property (nonatomic, strong) UIView *machine;
@property (nonatomic, strong) UIView *meterView, *meterFill;      // the oval egg meter above the reels
@property (nonatomic, strong) CAGradientLayer *meterGradient;
@property (nonatomic, strong) NSMutableArray<UIView *> *reelViews;
@property (nonatomic, strong) NSMutableArray<UIView *> *strips;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<UIImageView *> *> *stripCells;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<UIView *> *> *highlights;
@property (nonatomic, strong) UIButton *linesButton, *betButton, *maxButton, *spinButton;
@property (nonatomic, strong) CAGradientLayer *spinMidShadow;
@property (nonatomic, strong) UIView *celebrationOverlay, *summaryOverlay, *pickOverlay;
@property (nonatomic, strong) NSDictionary *result;
// Egg hatch
@property (nonatomic, strong) NSMutableArray<UIView *> *pickCards;      // by identity 0...2
@property (nonatomic, strong) NSMutableArray<UIImageView *> *pickEggs, *pickChicks, *pickShellTops, *pickShellBottoms; // parallel to pickCards
@property (nonatomic, strong) NSMutableArray<UILabel *> *pickValues;     // parallel to pickCards
@property (nonatomic, strong) NSMutableArray<UIView *> *pickSlots;      // card in each slot, left to right
@property (nonatomic, strong) UILabel *pickTitle, *pickSubtitle, *pickPrompt;
@end

@implementation BRPenguinParadeSlotViewController {
    int _grid[PG_REELS][PG_ROWS];       // the result being revealed
    int _board[PG_REELS][PG_ROWS];      // what the reels currently show
    int _eggsOnReel[PG_REELS];
    int _eggTotal;
    CGPoint _slotCenters[3];
    NSInteger _lines, _betIndex;
    NSInteger _meterEggs, _meterSize;   // egg meter as displayed (server-authoritative)
    NSInteger _balance;                 // what the label shows
    BOOL _balanceChecked;               // _balance verified by the server (entry, settle, or bet change)
    NSInteger _freeRemaining, _bonusMult, _bonusTotal, _bonusLines, _bonusBet, _lastAwarded, _spinWager;
    BOOL _pickPending, _bonusMode, _busy, _spinFree, _leaving, _pickEnabled, _pickInFlight, _stripsBuilt, _reelsMoving, _forceBonusArmed;
    NSUInteger _epoch;
    NSTimeInterval _celebrationEnd;
    CGFloat _cellSize;
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    _lines = [defaults objectForKey:kPGLinesKey] ? MAX(1, MIN(PG_MAX_LINES, [defaults integerForKey:kPGLinesKey])) : PG_MAX_LINES;
    _betIndex = [defaults objectForKey:[self betDefaultsKey]] ? MAX(0, MIN((NSInteger)[self activeBets].count - 1, [defaults integerForKey:[self betDefaultsKey]])) : 0;
    _bonusLines = _lines;
    _bonusBet = [self activeBets][_betIndex].integerValue;
    _meterSize = 100;
    _meterEggs = MAX(0, MIN(_meterSize, [defaults integerForKey:kPGMeterKey]));
    self.reelViews = [NSMutableArray array];
    self.strips = [NSMutableArray array];
    self.stripCells = [NSMutableArray array];
    self.highlights = [NSMutableArray array];
    for (int r = 0; r < PG_REELS; r++) for (int row = 0; row < PG_ROWS; row++) _board[r][row] = PGFiller(NO);

    [self buildUI];
    self.audio = [BRPenguinParadeAudio new];
    self.audio.muted = [defaults boolForKey:kPGMutedKey];
    [self.audio prepare];
    [self refreshLabels];
    [self updateControls];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.audio shutdown];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.background.frame = self.view.bounds;
    self.spinMidShadow.frame = self.spinButton.bounds;
    self.spinMidShadow.cornerRadius = self.spinButton.layer.cornerRadius;
    CGFloat width = self.view.bounds.size.width;
    if (width > 10 && fabs(width - self.backdropWidth) > 1) {
        self.backdropWidth = width;
        // The scenery view bleeds 10pt past each edge so its parallax
        // drift never uncovers a gap.
        self.sceneryView.image = [BRPenguinParadeArt arcticBackdropWithSize:CGSizeMake(width + 20, 250)];
    }
    self.snowEmitter.frame = self.view.bounds;
    self.snowEmitter.emitterPosition = CGPointMake(width / 2, -12);
    self.snowEmitter.emitterSize = CGSizeMake(width, 2);
    [self layoutReelsIfNeeded];
    [self updateMeterAnimated:NO];
}

// The header penguin paces back and forth across the top of the scenery,
// waddling as it goes. The art faces the viewer, so there is no facing to
// flip - the rock is what sells the walk. Reduce Motion keeps it still.
- (void)startPenguinWalk {
    if (!self.headerPenguinView || !self.headerPenguinLeading) return;
    if (self.penguinWalkActive || UIAccessibilityIsReduceMotionEnabled()) return;
    self.penguinWalkActive = YES;
    [self stepPenguinWalkToRight:YES];
}

- (void)stepPenguinWalkToRight:(BOOL)right {
    if (!self.penguinWalkActive || !self.headerPenguinView) return;
    CGFloat home = 18, travel = 96;
    __weak typeof(self) weakSelf = self;
    [UIView animateKeyframesWithDuration:2.4 delay:0
        options:UIViewKeyframeAnimationOptionAllowUserInteraction | UIViewKeyframeAnimationOptionCalculationModeLinear
        animations:^{
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        self.headerPenguinLeading.constant = right ? home + travel : home;
        [self.headerPenguinView.superview layoutIfNeeded];
        [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.25 animations:^{ self.headerPenguinView.transform = CGAffineTransformMakeRotation(-0.09); }];
        [UIView addKeyframeWithRelativeStartTime:0.25 relativeDuration:0.25 animations:^{ self.headerPenguinView.transform = CGAffineTransformMakeRotation(0.09); }];
        [UIView addKeyframeWithRelativeStartTime:0.5 relativeDuration:0.25 animations:^{ self.headerPenguinView.transform = CGAffineTransformMakeRotation(-0.09); }];
        [UIView addKeyframeWithRelativeStartTime:0.75 relativeDuration:0.25 animations:^{ self.headerPenguinView.transform = CGAffineTransformIdentity; }];
    } completion:^(BOOL finished) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!finished || !self || !self.penguinWalkActive) return;
        [self stepPenguinWalkToRight:!right];
    }];
}

- (void)stopPenguinWalk {
    self.penguinWalkActive = NO;
    if (!self.headerPenguinView) return;
    self.headerPenguinView.transform = CGAffineTransformIdentity;
    self.headerPenguinLeading.constant = 18;
    [self.headerPenguinView.superview layoutIfNeeded];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    _leaving = NO;
    [self.audio startThemeBonus:_bonusMode];
    [self refreshState];
    if (!self.chatBar) { self.chatBar = [[BRSlotChatBar alloc] initWithRoomID:@"penguin-parade"]; self.chatBar.hostViewController = self; [self.chatBar attachToView:self.view]; }
    [self.chatBar start];
    [self startPenguinWalk];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        _leaving = YES;
        _epoch++;
        [self stopPenguinWalk];
        [self.audio shutdown];
        [self.chatBar stop];
        [self.machine.layer removeAllAnimations];
        for (UIView *overlay in @[self.celebrationOverlay ?: [NSNull null], self.summaryOverlay ?: [NSNull null], self.pickOverlay ?: [NSNull null]]) {
            if ([overlay isKindOfClass:UIView.class]) [overlay removeFromSuperview];
        }
    }
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [BRPenguinParadeArt purgeCache];
}

- (void)appDidBecomeActive {
    if (self.view.window && !_leaving) [self.audio resume];
}

- (void)backTapped {
    if (self.navigationController) [self.navigationController popViewControllerAnimated:YES];
    else [self dismissViewControllerAnimated:YES completion:nil];
}

/// Runs `block` after `delay` unless the screen has been left in the meantime.
- (void)after:(NSTimeInterval)delay do:(dispatch_block_t)block {
    NSUInteger epoch = _epoch;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, delay) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_epoch != epoch || strongSelf->_leaving) return;
        block();
    });
}

- (void)haptic:(UIImpactFeedbackStyle)style {
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [generator impactOccurred];
}

#pragma mark UI construction

- (UIButton *)navButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBlack];
    button.tintColor = PGGold();
    button.backgroundColor = [PGC(0x9FD8FF) colorWithAlphaComponent:.16];
    button.layer.cornerRadius = 9;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [PGC(0xBFE6FF) colorWithAlphaComponent:.55].CGColor;
    button.contentEdgeInsets = UIEdgeInsetsMake(7, 10, 7, 10);
    [button sizeToFit];
    // Frosted glass: a blur plate behind the title, clipped to the
    // button's rounded corners.
    button.clipsToBounds = YES;
    UIVisualEffectView *frost = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    frost.frame = button.bounds;
    frost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    frost.userInteractionEnabled = NO;
    [button insertSubview:frost atIndex:0];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)controlButton:(NSString *)title color:(UIColor *)color action:(SEL)action {
    PGControlButton *button = [PGControlButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightHeavy];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:PGGold() forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1 alpha:.4] forState:UIControlStateDisabled];
    // The flat colour becomes a mostly-solid vertical gradient: a
    // lighter tint of it at the top, a deeper shade at the bottom.
    CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 1;
    [color getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
    UIColor *top = [UIColor colorWithHue:hue saturation:MAX(0, saturation - .08) brightness:MIN(1, brightness + .22) alpha:1];
    UIColor *bottom = [UIColor colorWithHue:hue saturation:saturation brightness:MAX(0, brightness - .12) alpha:1];
    button.fillGradient.colors = @[(id)top.CGColor, (id)color.CGColor, (id)bottom.CGColor];
    button.backgroundColor = UIColor.clearColor;
    button.layer.cornerRadius = 14;
    button.layer.borderWidth = 1.5;
    button.layer.borderColor = [PGGold() colorWithAlphaComponent:.8].CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = .35;
    button.layer.shadowRadius = 6;
    button.layer.shadowOffset = CGSizeMake(0, 3);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)statBlockCaption:(NSString *)caption value:(UILabel *)value alignment:(NSTextAlignment)alignment icon:(UIImage *)icon {
    UILabel *cap = [UILabel new];
    cap.text = caption;
    cap.font = [UIFont systemFontOfSize:10 weight:UIFontWeightHeavy];
    cap.textColor = [PGGold() colorWithAlphaComponent:.8];
    cap.textAlignment = alignment;
    UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = PGGold();
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [iconView.widthAnchor constraintEqualToConstant:15].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:15].active = YES;
    UIStackView *capRow = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, cap]];
    capRow.axis = UILayoutConstraintAxisHorizontal;
    capRow.spacing = 4;
    capRow.alignment = UIStackViewAlignmentCenter;
    value.font = [UIFont monospacedDigitSystemFontOfSize:19 weight:UIFontWeightHeavy];
    value.textColor = UIColor.whiteColor;
    value.textAlignment = alignment;
    value.adjustsFontSizeToFitWidth = YES;
    value.minimumScaleFactor = .6;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[capRow, value]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 1;
    stack.alignment = alignment == NSTextAlignmentRight ? UIStackViewAlignmentTrailing : UIStackViewAlignmentLeading;
    return stack;
}

- (void)buildUI {
    self.view.backgroundColor = PGC(0x041226);
    self.background = [[PGGradientView alloc] initWithFrame:self.view.bounds];
    self.background.userInteractionEnabled = NO;
    self.background.gradientLayer.colors = @[(id)PGC(0x12447A).CGColor, (id)PGC(0x041226).CGColor];
    [self.view insertSubview:self.background atIndex:0];

    self.navigationItem.hidesBackButton = YES;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:[self navButton:PGLoc(@"BRSlot.Picker.Back", @"‹  BRAINROT") action:@selector(backTapped)]];
    UIButton *pays = [self navButton:PGLoc(@"BRSlot.PG.Pays", @"PAYS") action:@selector(showPays)];
    self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc] initWithCustomView:pays]];

    self.scroll = [UIScrollView new];
    // Reserve room for the chat bar pinned over the bottom of this screen,
    // so the last controls (Spin) can always scroll clear of it.
    self.scroll.contentInset = UIEdgeInsetsMake(0, 0, 50, 0); self.scroll.scrollIndicatorInsets = self.scroll.contentInset;
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.alwaysBounceVertical = NO;
    [self.view addSubview:self.scroll];
    UIView *content = [UIView new];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:content];

    // The illustrated header: a code-drawn arctic backdrop (aurora,
    // icebergs, a penguin) behind the title, balance card and meter.
    // Its image is rendered at the real width in viewDidLayoutSubviews.
    self.sceneryView = [UIImageView new];
    self.sceneryView.translatesAutoresizingMaskIntoConstraints = NO;
    self.sceneryView.contentMode = UIViewContentModeScaleToFill;
    self.sceneryView.userInteractionEnabled = NO;
    UIInterpolatingMotionEffect *driftX = [[UIInterpolatingMotionEffect alloc] initWithKeyPath:@"center.x" type:UIInterpolatingMotionEffectTypeTiltAlongHorizontalAxis];
    driftX.minimumRelativeValue = @(-6); driftX.maximumRelativeValue = @(6);
    UIInterpolatingMotionEffect *driftY = [[UIInterpolatingMotionEffect alloc] initWithKeyPath:@"center.y" type:UIInterpolatingMotionEffectTypeTiltAlongVerticalAxis];
    driftY.minimumRelativeValue = @(-4); driftY.maximumRelativeValue = @(4);
    [self.sceneryView addMotionEffect:driftX];
    [self.sceneryView addMotionEffect:driftY];

    // A hard offset copy of the title behind the real one, so the
    // lettering reads as extruded 3D type over the scenery.
    UILabel *titleExtrusion = [UILabel new];
    titleExtrusion.translatesAutoresizingMaskIntoConstraints = NO;
    titleExtrusion.textAlignment = NSTextAlignmentCenter;
    titleExtrusion.numberOfLines = 2;
    titleExtrusion.attributedText = [[NSAttributedString alloc] initWithString:@"PENGUIN\nPARADE" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:31 weight:UIFontWeightBlack],
        NSForegroundColorAttributeName: PGC(0x06366B), NSStrokeColorAttributeName: PGC(0x06366B), NSStrokeWidthAttributeName: @-4}];
    titleExtrusion.adjustsFontSizeToFitWidth = YES; titleExtrusion.minimumScaleFactor = .6;
    titleExtrusion.userInteractionEnabled = NO;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 2;
    title.attributedText = [[NSAttributedString alloc] initWithString:@"PENGUIN\nPARADE" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:31 weight:UIFontWeightBlack],
        NSForegroundColorAttributeName: PGC(0xEAFBFF), NSStrokeColorAttributeName: PGC(0x2376BC), NSStrokeWidthAttributeName: @-2}];
    title.adjustsFontSizeToFitWidth = YES; title.minimumScaleFactor = .6;
    title.layer.shadowColor = PGC(0x6FC3F0).CGColor;
    title.layer.shadowOpacity = .7; title.layer.shadowRadius = 10; title.layer.shadowOffset = CGSizeZero;
    UIImageView *headerPenguin = [[UIImageView alloc] initWithImage:[BRPenguinParadeArt bonusPenguinWithVariant:0 size:CGSizeMake(68, 95)]];
    self.headerPenguinView = headerPenguin;
    headerPenguin.translatesAutoresizingMaskIntoConstraints = NO;
    headerPenguin.contentMode = UIViewContentModeScaleAspectFit;
    headerPenguin.userInteractionEnabled = NO;
    headerPenguin.isAccessibilityElement = NO;
    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.attributedText = [[NSAttributedString alloc] initWithString:@"9 LINES · EGG HATCH BONUS" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightHeavy],
        NSForegroundColorAttributeName: [UIColor colorWithRed:1 green:.96 blue:.86 alpha:.95], NSKernAttributeName: @1}];
    subtitle.adjustsFontSizeToFitWidth = YES;
    subtitle.minimumScaleFactor = .7;

    self.balanceLabel = [UILabel new];
    self.winLabel = [UILabel new];
    UIView *balanceBlock = [self statBlockCaption:PGLoc(@"BRSlot.PG.Balance", @"BALANCE") value:self.balanceLabel alignment:NSTextAlignmentLeft icon:PGParticleImage(YES)];
    UIView *winBlock = [self statBlockCaption:PGLoc(@"BRSlot.PG.Win", @"WIN") value:self.winLabel alignment:NSTextAlignmentRight icon:[UIImage systemImageNamed:@"crown.fill"]];
    UIStackView *info = [[UIStackView alloc] initWithArrangedSubviews:@[balanceBlock, winBlock]];
    info.translatesAutoresizingMaskIntoConstraints = NO;
    info.distribution = UIStackViewDistributionFillEqually;
    // Balance and win live on one elevated card: deep-blue gradient
    // fill, a gold rim and a soft gold glow under it.
    self.infoCard = [[PGGradientView alloc] init];
    self.infoCard.translatesAutoresizingMaskIntoConstraints = NO;
    self.infoCard.gradientLayer.colors = @[(id)PGC(0x16406E).CGColor, (id)PGC(0x0A2344).CGColor];
    self.infoCard.gradientLayer.startPoint = CGPointMake(.5, 0);
    self.infoCard.gradientLayer.endPoint = CGPointMake(.5, 1);
    self.infoCard.layer.cornerRadius = 16;
    self.infoCard.layer.borderWidth = 1.5;
    self.infoCard.layer.borderColor = [PGGold() colorWithAlphaComponent:.55].CGColor;
    self.infoCard.layer.shadowColor = PGGold().CGColor;
    self.infoCard.layer.shadowOpacity = .35;
    self.infoCard.layer.shadowRadius = 12;
    self.infoCard.layer.shadowOffset = CGSizeMake(0, 4);
    [self.infoCard addSubview:info];

    self.bannerLabel = [UILabel new];
    self.bannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.bannerLabel.numberOfLines = 2;
    self.bannerLabel.adjustsFontSizeToFitWidth = YES; self.bannerLabel.minimumScaleFactor = .85;
    self.bannerLabel.textAlignment = NSTextAlignmentCenter;
    self.bannerLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightHeavy];
    self.bannerLabel.textColor = PGGold();
    self.bannerLabel.backgroundColor = UIColor.clearColor;
    self.bannerLabel.shadowColor = [UIColor colorWithWhite:0 alpha:.75];
    self.bannerLabel.shadowOffset = CGSizeMake(0, 1);

    // The egg meter: an oval track that fills left to right. The banner text
    // sits on top of it.
    self.meterView = [UIView new];
    self.meterView.translatesAutoresizingMaskIntoConstraints = NO;
    self.meterView.backgroundColor = [PGC(0x0A2344) colorWithAlphaComponent:.95];
    self.meterView.layer.cornerRadius = 22;
    self.meterView.layer.borderWidth = 1.5;
    self.meterView.layer.borderColor = [PGGold() colorWithAlphaComponent:.65].CGColor;
    self.meterView.clipsToBounds = YES;
    self.meterFill = [UIView new];
    self.meterFill.clipsToBounds = YES;
    self.meterFill.layer.cornerRadius = 22;
    self.meterGradient = [CAGradientLayer layer];
    self.meterGradient.colors = @[(id)PGC(0x1E8FE0).CGColor, (id)PGC(0x6FD6FF).CGColor, (id)PGC(0xFFE48F).CGColor];
    self.meterGradient.startPoint = CGPointMake(0, .5); self.meterGradient.endPoint = CGPointMake(1, .5);
    [self.meterFill.layer addSublayer:self.meterGradient];
    [self.meterView addSubview:self.meterFill];
    // Three golden eggs and a chevron dress the bar in its idle state;
    // refreshBanner hides them and gives the label the full width
    // whenever the bar is carrying free-spin or meter news instead.
    self.meterEggViews = [NSMutableArray array];
    NSMutableArray *eggViews = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        UIImageView *egg = [[UIImageView alloc] initWithImage:[BRPenguinParadeArt imageForSymbol:PGSymbolEgg size:CGSizeMake(20, 20)]];
        egg.contentMode = UIViewContentModeScaleAspectFit;
        egg.layer.shadowColor = PGC(0xFFD86B).CGColor;
        egg.layer.shadowOpacity = .9;
        egg.layer.shadowRadius = 5;
        egg.layer.shadowOffset = CGSizeZero;
        [egg.widthAnchor constraintEqualToConstant:20].active = YES;
        [egg.heightAnchor constraintEqualToConstant:20].active = YES;
        [self.meterEggViews addObject:egg];
        [eggViews addObject:egg];
    }
    self.meterEggStack = [[UIStackView alloc] initWithArrangedSubviews:eggViews];
    self.meterEggStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.meterEggStack.axis = UILayoutConstraintAxisHorizontal;
    self.meterEggStack.spacing = 3;
    self.meterEggStack.alignment = UIStackViewAlignmentCenter;
    [self.meterView addSubview:self.meterEggStack];
    self.meterChevron = [UILabel new];
    self.meterChevron.translatesAutoresizingMaskIntoConstraints = NO;
    self.meterChevron.text = @"›";
    self.meterChevron.font = [UIFont systemFontOfSize:20 weight:UIFontWeightHeavy];
    self.meterChevron.textColor = [PGGold() colorWithAlphaComponent:.8];
    [self.meterView addSubview:self.meterChevron];
    [self.meterView addSubview:self.bannerLabel];
    self.bannerLeading = [self.bannerLabel.leadingAnchor constraintEqualToAnchor:self.meterView.leadingAnchor constant:18];
    self.bannerTrailing = [self.bannerLabel.trailingAnchor constraintEqualToAnchor:self.meterView.trailingAnchor constant:-18];
    [NSLayoutConstraint activateConstraints:@[
        self.bannerLeading,
        self.bannerTrailing,
        [self.bannerLabel.topAnchor constraintEqualToAnchor:self.meterView.topAnchor],
        [self.bannerLabel.bottomAnchor constraintEqualToAnchor:self.meterView.bottomAnchor],
        [self.meterEggStack.leadingAnchor constraintEqualToAnchor:self.meterView.leadingAnchor constant:12],
        [self.meterEggStack.centerYAnchor constraintEqualToAnchor:self.meterView.centerYAnchor],
        [self.meterChevron.trailingAnchor constraintEqualToAnchor:self.meterView.trailingAnchor constant:-12],
        [self.meterChevron.centerYAnchor constraintEqualToAnchor:self.meterView.centerYAnchor],
    ]];

    // Cabinet
    self.machine = [UIView new];
    self.machine.translatesAutoresizingMaskIntoConstraints = NO;
    self.machine.backgroundColor = PGC(0x0F2E55);
    self.machine.layer.cornerRadius = 22;
    self.machine.layer.borderWidth = 4;
    self.machine.layer.borderColor = PGC(0x9FE4FF).CGColor;
    if (self.vipMode) { self.machine.layer.borderWidth = 6; self.machine.layer.shadowOpacity = .55; }
    self.machine.layer.shadowColor = PGC(0x8EDBFF).CGColor;
    self.machine.layer.shadowRadius = 18;
    self.machine.layer.shadowOffset = CGSizeZero;
    self.machine.layer.shadowOpacity = 0;
    UIStackView *reelStack = [UIStackView new];
    reelStack.translatesAutoresizingMaskIntoConstraints = NO;
    reelStack.axis = UILayoutConstraintAxisHorizontal;
    reelStack.distribution = UIStackViewDistributionFillEqually;
    reelStack.spacing = 4;
    [self.machine addSubview:reelStack];
    for (int r = 0; r < PG_REELS; r++) {
        UIView *reel = [UIView new];
        reel.clipsToBounds = YES;
        reel.layer.cornerRadius = 8;
        reel.layer.borderWidth = 1.5;
        reel.layer.borderColor = [PGC(0x9FD8FF) colorWithAlphaComponent:.85].CGColor;
        PGGradientView *paper = [[PGGradientView alloc] initWithFrame:CGRectZero];
        paper.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        paper.gradientLayer.colors = @[(id)PGC(0xF4FAFF).CGColor, (id)PGC(0xD5E8F7).CGColor];
        [reel addSubview:paper];
        UIView *strip = [UIView new];
        [reel addSubview:strip];
        NSMutableArray<UIView *> *marks = [NSMutableArray array];
        for (int row = 0; row < PG_ROWS; row++) {
            UIView *mark = [UIView new];
            mark.hidden = YES;
            mark.userInteractionEnabled = NO;
            mark.layer.borderWidth = 3;
            mark.layer.cornerRadius = 8;
            [reel addSubview:mark];
            [marks addObject:mark];
        }
        PGGradientView *shade = [[PGGradientView alloc] initWithFrame:CGRectZero];
        shade.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        shade.userInteractionEnabled = NO;
        shade.gradientLayer.colors = @[(id)[PGC(0x66B9E8) colorWithAlphaComponent:.12].CGColor, (id)[UIColor clearColor].CGColor,
                                       (id)[UIColor clearColor].CGColor, (id)[PGC(0x66B9E8) colorWithAlphaComponent:.08].CGColor];
        shade.gradientLayer.locations = @[@0, @.22, @.78, @1];
        [reel addSubview:shade];
        [reelStack addArrangedSubview:reel];
        [reel.heightAnchor constraintEqualToAnchor:reel.widthAnchor multiplier:3.0].active = YES;
        [self.reelViews addObject:reel];
        [self.strips addObject:strip];
        [self.stripCells addObject:[NSMutableArray array]];
        [self.highlights addObject:marks];
    }

    self.messageLabel = [UILabel new];
    self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.messageLabel.numberOfLines = 2;
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.messageLabel.textColor = [UIColor colorWithWhite:.85 alpha:1];
    self.totalBetLabel = [UILabel new];
    self.totalBetLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.totalBetLabel.textAlignment = NSTextAlignmentCenter;
    self.totalBetLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
    self.totalBetLabel.textColor = [PGGold() colorWithAlphaComponent:.85];

    // The result line and the total-bet line sit on one frosted panel
    // under the cabinet.
    UIView *messagePanel = [UIView new];
    messagePanel.translatesAutoresizingMaskIntoConstraints = NO;
    messagePanel.layer.cornerRadius = 14;
    messagePanel.layer.borderWidth = 1;
    messagePanel.layer.borderColor = [PGC(0xB8ECFF) colorWithAlphaComponent:.7].CGColor;
    messagePanel.backgroundColor = [PGC(0x16487C) colorWithAlphaComponent:.85];
    messagePanel.clipsToBounds = YES;
    UIVisualEffectView *panelFrost = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    panelFrost.translatesAutoresizingMaskIntoConstraints = NO;
    panelFrost.contentView.backgroundColor = [PGC(0x0A2344) colorWithAlphaComponent:.35];
    [messagePanel addSubview:panelFrost];
    for (NSInteger side = 0; side < 2; side++) {
        UIImageView *flake = [[UIImageView alloc] initWithImage:PGSnowImage()];
        flake.translatesAutoresizingMaskIntoConstraints = NO;
        flake.contentMode = UIViewContentModeScaleAspectFit;
        flake.userInteractionEnabled = NO;
        flake.alpha = .9;
        [messagePanel addSubview:flake];
        [NSLayoutConstraint activateConstraints:@[
            [flake.widthAnchor constraintEqualToConstant:14],
            [flake.heightAnchor constraintEqualToConstant:14],
            [flake.centerYAnchor constraintEqualToAnchor:messagePanel.centerYAnchor],
            side == 0 ? [flake.leadingAnchor constraintEqualToAnchor:messagePanel.leadingAnchor constant:8] : [flake.trailingAnchor constraintEqualToAnchor:messagePanel.trailingAnchor constant:-8]
        ]];
    }
    [messagePanel addSubview:self.messageLabel];
    [messagePanel addSubview:self.totalBetLabel];
    [NSLayoutConstraint activateConstraints:@[
        [panelFrost.leadingAnchor constraintEqualToAnchor:messagePanel.leadingAnchor],
        [panelFrost.trailingAnchor constraintEqualToAnchor:messagePanel.trailingAnchor],
        [panelFrost.topAnchor constraintEqualToAnchor:messagePanel.topAnchor],
        [panelFrost.bottomAnchor constraintEqualToAnchor:messagePanel.bottomAnchor],
        [self.messageLabel.topAnchor constraintEqualToAnchor:messagePanel.topAnchor constant:8],
        [self.messageLabel.leadingAnchor constraintEqualToAnchor:messagePanel.leadingAnchor constant:26],
        [self.messageLabel.trailingAnchor constraintEqualToAnchor:messagePanel.trailingAnchor constant:-26],
        [self.totalBetLabel.topAnchor constraintEqualToAnchor:self.messageLabel.bottomAnchor constant:2],
        [self.totalBetLabel.leadingAnchor constraintEqualToAnchor:messagePanel.leadingAnchor constant:14],
        [self.totalBetLabel.trailingAnchor constraintEqualToAnchor:messagePanel.trailingAnchor constant:-14],
        [self.totalBetLabel.bottomAnchor constraintEqualToAnchor:messagePanel.bottomAnchor constant:-8],
    ]];

    UIColor *deepRed = PGC(0x14487F);
    self.linesButton = [self controlButton:@"" color:deepRed action:@selector(cycleLines)];
    self.betButton = [self controlButton:@"" color:deepRed action:@selector(cycleBet)];
    self.maxButton = [self controlButton:@"" color:PGC(0xDF9900) action:@selector(maxBet)];
    NSArray<NSString *> *controlIcons = @[@"list.bullet", @"circle.grid.2x2.fill", @"bolt.fill"];
    NSArray<UIButton *> *betButtons = @[self.linesButton, self.betButton, self.maxButton];
    for (NSUInteger i = 0; i < betButtons.count; i++) {
        UIButton *button = betButtons[i];
        UIImage *icon = [[UIImage systemImageNamed:controlIcons[i]] imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold]];
        [button setImage:icon forState:UIControlStateNormal];
        button.tintColor = UIColor.whiteColor;
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightHeavy];
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = .7;
        button.contentEdgeInsets = UIEdgeInsetsMake(2, 5, 2, 5);
        button.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 4);
    }
    [self.maxButton setTitleColor:PGC(0x342000) forState:UIControlStateNormal];
    self.maxButton.tintColor = PGC(0x342000);
    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[self.linesButton, self.betButton, self.maxButton]];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.distribution = UIStackViewDistributionFillEqually;
    controls.spacing = 10;
    self.spinButton = [self controlButton:PGLoc(@"BRSlot.PG.Spin", @"SPIN") color:PGC(0x087C2D) action:@selector(spinTapped)];
    [self.spinButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.spinButton.layer.borderColor = PGC(0xA8F7C0).CGColor;
    self.spinButton.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBlack];
    self.spinButton.layer.borderWidth = 2.5;
    // Spin is the hero control: a glossy sheen across its top half and
    // a green glow in place of the plain drop shadow.
    ((PGControlButton *)self.spinButton).glossGradient.hidden = NO;
    self.spinButton.layer.shadowColor = PGC(0x2BD97B).CGColor;
    self.spinButton.layer.shadowOpacity = .5;
    self.spinButton.layer.shadowRadius = 16;
    self.spinButton.layer.shadowOffset = CGSizeMake(0, 4);
    // A soft shadow band across the button's middle, so the top gloss and
    // the bottom edge read as separate depths.
    self.spinMidShadow = [CAGradientLayer layer];
    self.spinMidShadow.colors = @[(id)UIColor.clearColor.CGColor, (id)[UIColor colorWithWhite:0 alpha:.22].CGColor, (id)UIColor.clearColor.CGColor];
    self.spinMidShadow.locations = @[@0.2, @0.5, @0.8];
    self.spinMidShadow.startPoint = CGPointMake(.5, 0);
    self.spinMidShadow.endPoint = CGPointMake(.5, 1);
    [self.spinButton.layer addSublayer:self.spinMidShadow];
    // Snowflakes flanking the SPIN label, tracking the title as it widens
    // for FREE SPINS.
    for (NSInteger side = 0; side < 2; side++) {
        UIImageView *flake = [[UIImageView alloc] initWithImage:PGSnowImage()];
        flake.translatesAutoresizingMaskIntoConstraints = NO;
        flake.contentMode = UIViewContentModeScaleAspectFit;
        flake.userInteractionEnabled = NO;
        [self.spinButton addSubview:flake];
        [NSLayoutConstraint activateConstraints:@[
            [flake.widthAnchor constraintEqualToConstant:16],
            [flake.heightAnchor constraintEqualToConstant:16],
            [flake.centerYAnchor constraintEqualToAnchor:self.spinButton.titleLabel.centerYAnchor],
            side == 0 ? [flake.trailingAnchor constraintEqualToAnchor:self.spinButton.titleLabel.leadingAnchor constant:-10] : [flake.leadingAnchor constraintEqualToAnchor:self.spinButton.titleLabel.trailingAnchor constant:10]
        ]];
    }
    UILongPressGestureRecognizer *forceBonusHold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(forceBonusHold:)];
    forceBonusHold.minimumPressDuration = 10.0;
    forceBonusHold.cancelsTouchesInView = YES;
    [self.spinButton addGestureRecognizer:forceBonusHold];

    // Snow settled along the cabinet's top edge, and a decorative
    // arrow at each side of the reels. Neither takes touches.
    UIImageView *snowCap = [[UIImageView alloc] initWithImage:[BRPenguinParadeArt snowCapWithSize:CGSizeMake(400, 36)]];
    snowCap.translatesAutoresizingMaskIntoConstraints = NO;
    snowCap.contentMode = UIViewContentModeScaleToFill;
    snowCap.userInteractionEnabled = NO;
    UILabel *leftArrow = [UILabel new];
    leftArrow.translatesAutoresizingMaskIntoConstraints = NO;
    leftArrow.text = @"◀";
    leftArrow.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    leftArrow.textColor = [PGGold() colorWithAlphaComponent:.8];
    leftArrow.shadowColor = [UIColor colorWithWhite:0 alpha:.6];
    leftArrow.shadowOffset = CGSizeMake(0, 1);
    leftArrow.userInteractionEnabled = NO;
    UILabel *rightArrow = [UILabel new];
    rightArrow.translatesAutoresizingMaskIntoConstraints = NO;
    rightArrow.text = @"▶";
    rightArrow.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    rightArrow.textColor = [PGGold() colorWithAlphaComponent:.8];
    rightArrow.shadowColor = [UIColor colorWithWhite:0 alpha:.6];
    rightArrow.shadowOffset = CGSizeMake(0, 1);
    rightArrow.userInteractionEnabled = NO;

    [content addSubview:self.sceneryView]; [content addSubview:headerPenguin]; [content addSubview:titleExtrusion]; [content addSubview:title]; [content addSubview:subtitle];
    [content bringSubviewToFront:headerPenguin];
    self.headerPenguinLeading = [headerPenguin.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18];
    [content addSubview:self.infoCard]; [content addSubview:self.meterView];
    [content addSubview:self.machine]; [content addSubview:snowCap]; [content addSubview:leftArrow]; [content addSubview:rightArrow];
    [content addSubview:messagePanel];
    [content addSubview:controls]; [content addSubview:self.spinButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
        // Landscape: the machine stops growing at its portrait width and
    // centers, instead of stretching to the full screen width. On
    // portrait-width screens the full-width rule wins and nothing changes.
    NSLayoutConstraint *machineWidthFull = [self.machine.widthAnchor constraintEqualToAnchor:content.widthAnchor constant:-28];
    machineWidthFull.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor],

        [self.sceneryView.topAnchor constraintEqualToAnchor:content.topAnchor],
        [self.sceneryView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:-10],
        [self.sceneryView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:10],
        [self.sceneryView.heightAnchor constraintEqualToConstant:250],
        self.headerPenguinLeading,
        [headerPenguin.topAnchor constraintEqualToAnchor:content.topAnchor constant:4],
        [headerPenguin.widthAnchor constraintEqualToConstant:68],
        [headerPenguin.heightAnchor constraintEqualToConstant:95],
        [titleExtrusion.topAnchor constraintEqualToAnchor:title.topAnchor constant:3],
        [titleExtrusion.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [titleExtrusion.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:6],
        [title.leadingAnchor constraintEqualToAnchor:headerPenguin.trailingAnchor constant:4],
        [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:0],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [self.infoCard.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:10],
        [self.infoCard.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [self.infoCard.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [info.topAnchor constraintEqualToAnchor:self.infoCard.topAnchor constant:10],
        [info.bottomAnchor constraintEqualToAnchor:self.infoCard.bottomAnchor constant:-10],
        [info.leadingAnchor constraintEqualToAnchor:self.infoCard.leadingAnchor constant:14],
        [info.trailingAnchor constraintEqualToAnchor:self.infoCard.trailingAnchor constant:-14],
        [self.meterView.topAnchor constraintEqualToAnchor:self.infoCard.bottomAnchor constant:10],
        [self.meterView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [self.meterView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.meterView.heightAnchor constraintEqualToConstant:44],
        [self.machine.topAnchor constraintEqualToAnchor:self.meterView.bottomAnchor constant:12],
        [self.machine.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [self.machine.widthAnchor constraintLessThanOrEqualToConstant:432],
        machineWidthFull,
        [reelStack.topAnchor constraintEqualToAnchor:self.machine.topAnchor constant:12],
        [reelStack.bottomAnchor constraintEqualToAnchor:self.machine.bottomAnchor constant:-12],
        [reelStack.leadingAnchor constraintEqualToAnchor:self.machine.leadingAnchor constant:12],
        [reelStack.trailingAnchor constraintEqualToAnchor:self.machine.trailingAnchor constant:-12],
        [snowCap.leadingAnchor constraintEqualToAnchor:self.machine.leadingAnchor constant:-4],
        [snowCap.trailingAnchor constraintEqualToAnchor:self.machine.trailingAnchor constant:4],
        [snowCap.bottomAnchor constraintEqualToAnchor:self.machine.topAnchor constant:12],
        [snowCap.heightAnchor constraintEqualToConstant:20],
        [leftArrow.centerYAnchor constraintEqualToAnchor:self.machine.centerYAnchor],
        [leftArrow.centerXAnchor constraintEqualToAnchor:self.machine.leadingAnchor constant:8],
        [rightArrow.centerYAnchor constraintEqualToAnchor:self.machine.centerYAnchor],
        [rightArrow.centerXAnchor constraintEqualToAnchor:self.machine.trailingAnchor constant:-8],
        [messagePanel.topAnchor constraintEqualToAnchor:self.machine.bottomAnchor constant:10],
        [messagePanel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [messagePanel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.messageLabel.heightAnchor constraintGreaterThanOrEqualToConstant:36],
        [controls.topAnchor constraintEqualToAnchor:messagePanel.bottomAnchor constant:8],
        [controls.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [controls.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [controls.heightAnchor constraintEqualToConstant:52],
        [self.spinButton.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:10],
        [self.spinButton.widthAnchor constraintEqualToConstant:280],
        [self.spinButton.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [self.spinButton.heightAnchor constraintEqualToConstant:56],
        [self.spinButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18],
    ]];

    // Ambient snowfall over the whole screen, kept gentle: a few
    // small flakes drifting down with a slight sideways wander. It is
    // a layer, so it never intercepts touches, and it sits above the
    // scroll content but below any overlay added later.
    self.snowEmitter = [CAEmitterLayer layer];
    self.snowEmitter.emitterShape = kCAEmitterLayerLine;
    self.snowEmitter.renderMode = kCAEmitterLayerUnordered;
    CAEmitterCell *flake = [CAEmitterCell emitterCell];
    flake.contents = (id)PGSnowImage().CGImage;
    flake.birthRate = 5;
    flake.lifetime = 16; flake.lifetimeRange = 4;
    flake.velocity = 34; flake.velocityRange = 18;
    flake.emissionLongitude = M_PI_2; flake.emissionRange = .35;
    flake.yAcceleration = 10;
    flake.xAcceleration = 2;
    flake.spin = 1; flake.spinRange = 2;
    flake.scale = .8; flake.scaleRange = .45;
    flake.alphaRange = .35; flake.alphaSpeed = -.02;
    self.snowEmitter.emitterCells = @[flake];
    [self.view.layer insertSublayer:self.snowEmitter below:self.scroll.layer];

    [self refreshBanner];
}

#pragma mark Reel layout

- (void)layoutReelsIfNeeded {
    if (self.reelViews.count != PG_REELS) return;
    CGFloat width = self.reelViews[0].bounds.size.width;
    if (width < 10 || _reelsMoving) return;
    if (_stripsBuilt && fabs(width - _cellSize) < 0.5) return;
    _cellSize = width;
    _stripsBuilt = YES;
    for (NSInteger r = 0; r < PG_REELS; r++) {
        [self configureStripForReel:r final:_board[r] old:_board[r] fillers:0];
        for (NSInteger row = 0; row < PG_ROWS; row++) {
            self.highlights[r][row].frame = CGRectInset(CGRectMake(0, row * width, width, width), 2, 2);
        }
    }
}

/// Strip layout, top to bottom: [buffer][final 3][K fillers][old 3]. At rest the
/// strip sits one cell up, showing the final three. A spin starts with the old
/// three showing and slides down to the final three.
- (void)configureStripForReel:(NSInteger)reel final:(const int *)fin old:(const int *)old fillers:(NSInteger)K {
    UIView *strip = self.strips[reel];
    NSMutableArray<UIImageView *> *cells = self.stripCells[reel];
    CGFloat s = _cellSize, inset = s * 0.05;
    CGSize imageSize = CGSizeMake(s - 2 * inset, s - 2 * inset);
    NSInteger total = 4 + K + 3;
    while ((NSInteger)cells.count < total) {
        UIImageView *view = [UIImageView new];
        view.contentMode = UIViewContentModeScaleAspectFit;
        [strip addSubview:view];
        [cells addObject:view];
    }
    for (NSInteger i = 0; i < (NSInteger)cells.count; i++) {
        UIImageView *cell = cells[i];
        if (i >= total) { cell.hidden = YES; continue; }
        cell.hidden = NO;
        cell.transform = CGAffineTransformIdentity;
        cell.frame = CGRectMake(inset, i * s + inset, imageSize.width, imageSize.height);
        int symbol;
        if (i == 0) symbol = PGFiller(NO);
        else if (i <= 3) symbol = fin[i - 1];
        else if (i < 4 + K) symbol = PGFiller(YES);
        else symbol = old[i - (4 + K)];
        cell.image = [BRPenguinParadeArt imageForSymbol:(PGSymbol)symbol size:imageSize];
    }
    strip.frame = CGRectMake(0, -s, s, total * s);
}

/// Seamless blur: a repeating pattern slid by exactly one period, forever, until
/// the result arrives.
- (void)startReelLoops {
    _reelsMoving = YES;
    CGFloat s = _cellSize, inset = s * 0.05;
    CGSize imageSize = CGSizeMake(s - 2 * inset, s - 2 * inset);
    NSInteger P = kPGLoopPeriod, total = P + 3;
    for (NSInteger r = 0; r < PG_REELS; r++) {
        UIView *strip = self.strips[r];
        NSMutableArray<UIImageView *> *cells = self.stripCells[r];
        int pattern[kPGLoopPeriod];
        for (NSInteger i = 0; i < P; i++) pattern[i] = PGFiller(NO);
        while ((NSInteger)cells.count < total) {
            UIImageView *view = [UIImageView new];
            view.contentMode = UIViewContentModeScaleAspectFit;
            [strip addSubview:view];
            [cells addObject:view];
        }
        for (NSInteger i = 0; i < (NSInteger)cells.count; i++) {
            UIImageView *cell = cells[i];
            if (i >= total) { cell.hidden = YES; continue; }
            cell.hidden = NO;
            cell.transform = CGAffineTransformIdentity;
            cell.frame = CGRectMake(inset, i * s + inset, imageSize.width, imageSize.height);
            cell.image = [BRPenguinParadeArt imageForSymbol:(PGSymbol)pattern[i % P] size:imageSize];
        }
        strip.frame = CGRectMake(0, -(CGFloat)P * s, s, total * s);
        CABasicAnimation *loop = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        loop.fromValue = @0;
        loop.toValue = @((CGFloat)P * s);
        loop.duration = P / kPGLoopSpeed;
        loop.repeatCount = HUGE_VALF;
        loop.timeOffset = r * 0.06;
        loop.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [strip.layer addAnimation:loop forKey:@"gmLoop"];
    }
}

- (void)stopReelLoops {
    for (UIView *strip in self.strips) [strip.layer removeAnimationForKey:@"gmLoop"];
}

#pragma mark State and labels

- (NSArray<NSNumber *> *)activeBets { return self.vipMode ? PGVIPBets() : PGBets(); }
- (NSString *)betDefaultsKey { return self.vipMode ? kPGVIPBetKey : kPGBetKey; }
- (NSInteger)betPerLine { return [self activeBets][_betIndex].integerValue; }

- (void)refreshLabels {
    self.balanceLabel.text = [NSString stringWithFormat:PGLoc(@"BRSlot.Balance.Value", @"🪙 %ld EZ Coins"), (long)_balance];
    NSInteger lines = _bonusMode ? _bonusLines : _lines, bet = _bonusMode ? _bonusBet : [self betPerLine];
    self.linesButton.titleLabel.text = nil;
    [self.linesButton setTitle:[NSString stringWithFormat:PGLoc(@"BRSlot.PG.Lines", @"LINES\n%ld"), (long)lines] forState:UIControlStateNormal];
    [self.betButton setTitle:[NSString stringWithFormat:PGLoc(@"BRSlot.PG.Bet", @"BET / LINE\n%ld"), (long)bet] forState:UIControlStateNormal];
    [self.maxButton setTitle:[NSString stringWithFormat:PGLoc(@"BRSlot.PG.MaxBet", @"MAX BET\n%ld + SPIN"), (long)(PG_MAX_LINES * [self activeBets].lastObject.integerValue)] forState:UIControlStateNormal];
    self.totalBetLabel.text = _bonusMode ? PGLoc(@"BRSlot.PG.FreeNoWager", @"FREE SPINS — NO WAGER TAKEN")
        : [NSString stringWithFormat:PGLoc(@"BRSlot.PG.TotalBet", @"TOTAL BET  %ld COINS"), (long)(lines * bet)];
}

- (void)refreshBanner {
    if (_bonusMode) {
        NSString *mult = _bonusMult > 0 ? [NSString stringWithFormat:@"%ld", (long)_bonusMult] : @"?";
        self.bannerLabel.text = [NSString stringWithFormat:PGLoc(@"BRSlot.PG.FreeSpinsLeft", @"FREE SPINS  %ld LEFT  ·  ×%@  ·  WON %@"), (long)_freeRemaining, mult, PGNum(_bonusTotal)];
        self.bannerLabel.textColor = PGC(0xFFE48F);
        // The free-spin readout needs the whole bar.
        self.meterEggStack.hidden = YES;
        self.meterChevron.hidden = YES;
        self.bannerLeading.constant = 18;
        self.bannerTrailing.constant = -18;
        for (UIImageView *egg in self.meterEggViews) [egg.layer removeAnimationForKey:@"pgEggShine"];
    } else {
        self.bannerLabel.text = PGLoc(@"BRSlot.PG.Hint", @"3 golden eggs triggers bonus game");
        self.bannerLabel.textColor = PGGold();
        self.meterEggStack.hidden = NO;
        self.meterChevron.hidden = NO;
        self.bannerLeading.constant = 86;
        self.bannerTrailing.constant = -32;
        // A slow shine rolling across the three eggs, one after another.
        for (NSUInteger i = 0; i < self.meterEggViews.count; i++) {
            CALayer *layer = self.meterEggViews[i].layer;
            if ([layer animationForKey:@"pgEggShine"]) continue;
            CABasicAnimation *shine = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            shine.fromValue = @1; shine.toValue = @1.08;
            shine.duration = .55; shine.autoreverses = YES; shine.repeatCount = HUGE_VALF;
            shine.beginTime = CACurrentMediaTime() + i * .16;
            [layer addAnimation:shine forKey:@"pgEggShine"];
        }
    }
}

/// A springy pop on the win figure and a flash of the card's glow
/// whenever a win lands.
- (void)pulseWin {
    self.winLabel.transform = CGAffineTransformMakeScale(1.25, 1.25);
    [UIView animateWithDuration:.45 delay:0 usingSpringWithDamping:.4 initialSpringVelocity:.6 options:0 animations:^{
        self.winLabel.transform = CGAffineTransformIdentity;
    } completion:nil];
    CABasicAnimation *glow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    glow.fromValue = @.35; glow.toValue = @.95;
    glow.duration = .22; glow.autoreverses = YES; glow.repeatCount = 1;
    [self.infoCard.layer addAnimation:glow forKey:@"pgWinGlow"];
}

- (void)setMessage:(NSString *)text highlight:(BOOL)highlight {
    self.messageLabel.text = text;
    self.messageLabel.textColor = highlight ? PGC(0xFFD86B) : [UIColor colorWithWhite:.85 alpha:1];
}

- (void)updateControls {
    BOOL idle = !_busy && !_bonusMode && _freeRemaining == 0 && !_pickPending;
    for (UIButton *button in @[self.linesButton, self.betButton, self.maxButton, self.spinButton]) {
        button.enabled = idle;
        button.alpha = idle ? 1 : 0.5;
    }
    [self.spinButton setTitle:_bonusMode ? PGLoc(@"BRSlot.PG.FreeSpinsButton", @"FREE SPINS") : PGLoc(@"BRSlot.PG.Spin", @"SPIN") forState:UIControlStateNormal];
}

- (void)cycleLines {
    if (_busy || _bonusMode) return;
    _lines = _lines % PG_MAX_LINES + 1;
    [NSUserDefaults.standardUserDefaults setInteger:_lines forKey:kPGLinesKey];
    [self refreshLabels];
    [self checkBalanceSilently];
}

- (void)cycleBet {
    if (_busy || _bonusMode) return;
    _betIndex = (_betIndex + 1) % (NSInteger)[self activeBets].count;
    [NSUserDefaults.standardUserDefaults setInteger:_betIndex forKey:[self betDefaultsKey]];
    [self refreshLabels];
    [self checkBalanceSilently];
}

- (void)maxBet {
    if (_busy || _bonusMode) return;
    _lines = PG_MAX_LINES;
    _betIndex = (NSInteger)[self activeBets].count - 1;
    [self refreshLabels];
    [self checkBalanceSilently];
    [self spinTapped];
}
// Silent balance verification: refreshes the cached balance the spin path
// trusts. Runs on screen entry and whenever the bet changes; never blocks
// a spin and never puts a "checking" message on screen.
- (void)checkBalanceSilently {
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        if (self->_busy || self->_leaving) return;
        self->_balance = balance;
        self->_balanceChecked = YES;
        [self refreshLabels];
    }];
}


- (void)showPays {
    PGPaytableViewController *pays = [PGPaytableViewController new];
    pays.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:pays animated:YES completion:nil];
}

- (void)showCoinStore {
    if (self.presentedViewController) return;
    EZCoinStoreViewController *store = [EZCoinStoreViewController new];
    store.showLowCoinsWarning = YES;
    store.triggeringFeatureName = PGLoc(@"BRSlot.PG.StoreFeature", @"Penguin Parade");
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:store];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark Server

- (void)request:(NSDictionary *)payload completion:(void (^)(NSDictionary *result, NSString *error, NSInteger status))completion {
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *authError) {
        if (!token) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, PGLoc(@"BRSlot.PG.SignIn", @"Please sign in to play Penguin Parade."), 401); });
            return;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/ez-penguin-parade-spin"]]];
        request.HTTPMethod = @"POST";
        request.timeoutInterval = 25;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSDictionary *result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![result isKindOfClass:NSDictionary.class]) result = nil;
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            NSString *error = nil;
            if (networkError) error = networkError.localizedDescription;
            else if (status < 200 || status >= 300) error = PGString(result[@"reason"]) ?: PGString(result[@"error"]) ?: PGLoc(@"BRSlot.PG.RequestFailed", @"The request failed. Your balance is unchanged.");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error, status); });
        }] resume];
    }];
}

/// Syncs balance and any in-progress bonus, and resumes it if the player left
/// mid-way (including an egg pick that was never made).
- (void)refreshState {
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        if (self->_busy) return;
        self->_balance = balance;
        self->_balanceChecked = YES;
        [self refreshLabels];
    }];
    [self request:@{@"action": @"status"} completion:^(NSDictionary *result, NSString *error, NSInteger status) {
        if (self->_leaving || self->_busy || !result || error) return;
        self->_freeRemaining = PGInteger(result[@"free_spins_remaining"]);
        self->_pickPending = PGBool(result[@"pick_pending"]);
        self->_bonusMult = PGInteger(result[@"multiplier"]);
        self->_bonusTotal = PGInteger(result[@"bonus_total"]);
        if (result[@"meter_eggs"]) {
            if (PGInteger(result[@"meter_size"]) > 0) self->_meterSize = PGInteger(result[@"meter_size"]);
            self->_meterEggs = MAX(0, MIN(self->_meterSize, PGInteger(result[@"meter_eggs"])));
            [self updateMeterAnimated:YES];
        }
        if (self->_freeRemaining > 0) {
            self->_bonusLines = MAX(1, MIN(PG_MAX_LINES, PGInteger(result[@"lines"])));
            self->_bonusBet = PGInteger(result[@"bet_per_line"]) ?: 1;
            [self resumeBonus];
        } else {
            [self refreshLabels]; [self refreshBanner]; [self updateControls];
            // A pick owed with no free spins left to count: the
            // server still rejects every spin until the card is
            // picked, so enter the bonus presentation and show the
            // cards instead of leaving SPIN live with no way to pick.
            if (self->_pickPending && !self.pickOverlay) {
                [self enterBonusMode];
                [self after:0.8 do:^{ [self presentCardPick]; }];
            }
        }
    }];
}

- (void)resumeBonus {
    if (_busy || _freeRemaining <= 0) return;
    _busy = YES;
    [self enterBonusMode];
    [self setMessage:PGLoc(@"BRSlot.PG.Resuming", @"Resuming your free spins…") highlight:YES];
    if (_pickPending) [self after:0.8 do:^{ [self presentCardPick]; }];
    else [self after:1.0 do:^{ [self beginSpinFree:YES]; }];
}

#pragma mark Spinning

// Test back door: a 10-second hold on SPIN arms a forced bonus for
// the next paid spin (a heavy buzz confirms it armed). The server
// honors force_bonus only for the owner's accounts, so for every
// other player the hold does nothing at all.
- (void)forceBonusHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    if (_busy || _pickPending) return;
    _forceBonusArmed = YES;
    [self haptic:UIImpactFeedbackStyleHeavy];
}

- (void)spinTapped {
    if (_busy || _bonusMode || _freeRemaining > 0 || _pickPending) return;
    NSInteger wager = _lines * [self betPerLine];
    if (_balanceChecked) {
        // Balance was verified on entry, after the last settled spin, or on
        // the last bet change — trust the cache and fire immediately
        // instead of waiting on a round trip.
        if (_balance < wager) {
            [self setMessage:[NSString stringWithFormat:PGLoc(@"BRSlot.PG.NeedCoins", @"You need %ld coins for that bet."), (long)wager] highlight:NO];
            [self showCoinStore];
            return;
        }
        [self beginSpinFree:NO];
        return;
    }
    _busy = YES;
    [self updateControls];
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        if (self->_leaving) return;
        self->_balance = balance;
        self->_balanceChecked = YES;
        [self refreshLabels];
        if (balance < wager) {
            self->_busy = NO;
            [self updateControls];
            [self setMessage:[NSString stringWithFormat:PGLoc(@"BRSlot.PG.NeedCoins", @"You need %ld coins for that bet."), (long)wager] highlight:NO];
            [self showCoinStore];
            return;
        }
        [self beginSpinFree:NO];
    }];
}

- (void)beginSpinFree:(BOOL)free {
    _busy = YES;
    _spinFree = free;
    [self updateControls];
    [self clearHighlights];
    NSInteger lines = free ? _bonusLines : _lines;
    NSInteger bet = free ? _bonusBet : [self betPerLine];
    _spinWager = free ? 0 : lines * bet;
    if (free) { _freeRemaining = MAX(0, _freeRemaining - 1); }
    else { _balance -= _spinWager; }
    self.winLabel.text = @"0";
    [self refreshLabels];
    [self refreshBanner];
    [self setMessage:PGLoc(@"BRSlot.Spinning", @"Spinning…") highlight:NO];
    [self startReelLoops];
    [self.audio playSpinStart];
    [self haptic:UIImpactFeedbackStyleMedium];

    NSUInteger epoch = _epoch;
    NSMutableDictionary *spinBody = [@{@"lines": @(lines), @"bet_per_line": @(bet)} mutableCopy];
    if (_forceBonusArmed && !free) { spinBody[@"force_bonus"] = @YES; _forceBonusArmed = NO; }
    if (self.vipMode) spinBody[@"vip"] = @YES;
    [self request:spinBody completion:^(NSDictionary *result, NSString *error, NSInteger status) {
        if (self->_epoch != epoch || self->_leaving) return;
        if (error || ![self parseResult:result]) {
            [self failSpin:error ?: PGLoc(@"BRSlot.PG.BadResponse", @"Unexpected response. Your balance is unchanged.") status:status];
            return;
        }
        [self revealResult:result];
    }];
}

- (void)failSpin:(NSString *)message status:(NSInteger)status {
    [EZAppErrorReporter reportSource:@"penguin_parade" code:@"spin_failed" message:message];
    _balanceChecked = NO;
    [self stopReelLoops];
    _reelsMoving = NO;
    [self.audio stopDrumRoll];
    _stripsBuilt = NO;
    [self layoutReelsIfNeeded];                 // puts the previous board back
    _busy = NO;
    [self updateControls];
    [self setMessage:message highlight:NO];
    self.messageLabel.textColor = UIColor.systemOrangeColor;
    [self refreshState];                        // the server may have settled; re-sync
    if (status == 402) [self showCoinStore];
    if (_freeRemaining > 0 || _bonusMode) _busy = NO;
}

- (BOOL)parseResult:(NSDictionary *)result {
    NSArray *reels = result[@"reels"];
    if (![reels isKindOfClass:NSArray.class] || reels.count != PG_REELS) return NO;
    int grid[PG_REELS][PG_ROWS], perReel[PG_REELS] = {0}, eggs = 0;
    for (NSInteger c = 0; c < PG_REELS; c++) {
        NSArray *column = reels[c];
        if (![column isKindOfClass:NSArray.class] || column.count != PG_ROWS) return NO;
        for (NSInteger row = 0; row < PG_ROWS; row++) {
            if (![column[row] isKindOfClass:NSString.class]) return NO;
            NSUInteger index = [PGSymbolNames() indexOfObject:column[row]];
            if (index == NSNotFound) return NO;
            grid[c][row] = (int)index;
            if (index == PGSymbolEgg) { perReel[c]++; eggs++; }
        }
    }
    memcpy(_grid, grid, sizeof(grid));
    memcpy(_eggsOnReel, perReel, sizeof(perReel));
    _eggTotal = eggs;
    return YES;
}

/// Lands the reels left to right. Once two eggs are showing, every remaining
/// reel takes longer so the drum roll has time to build.
- (void)revealResult:(NSDictionary *)result {
    self.result = result;
    [self stopReelLoops];
    CGFloat s = _cellSize;
    double stopAt[PG_REELS];
    double t = 0.7;
    int eggsBefore = 0;
    for (int r = 0; r < PG_REELS; r++) {
        if (r > 0) {
            t += 0.30;
            if (eggsBefore >= 2 && eggsBefore < PG_MAX_SCATTERS) t += 0.65;
        }
        stopAt[r] = t;
        eggsBefore += _eggsOnReel[r];
    }
    NSUInteger epoch = _epoch;
    for (NSInteger r = 0; r < PG_REELS; r++) {
        NSInteger K = MAX(6, lround(stopAt[r] * 11.0));
        [self configureStripForReel:r final:_grid[r] old:_board[r] fillers:K];
        UIView *strip = self.strips[r];
        CGRect start = CGRectMake(0, -(CGFloat)(4 + K) * s, s, strip.frame.size.height);
        CGRect end = CGRectMake(0, -s, s, start.size.height);
        CGRect over = CGRectOffset(end, 0, s * 0.12);
        strip.frame = start;
        [UIView animateWithDuration:stopAt[r] delay:r * 0.035 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction animations:^{
            strip.frame = over;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{ strip.frame = end; } completion:nil];
            if (self->_epoch != epoch || self->_leaving) return;
            [self reelDidStop:r];
        }];
    }
}

- (void)reelDidStop:(NSInteger)reel {
    for (int row = 0; row < PG_ROWS; row++) _board[reel][row] = _grid[reel][row];
    int before = 0;
    for (int r = 0; r < reel; r++) before += _eggsOnReel[r];
    int here = _eggsOnReel[reel];
    int total = before + here;
    [self.audio playReelStop:reel];
    [self haptic:here ? UIImpactFeedbackStyleHeavy : UIImpactFeedbackStyleLight];

    // Same bell for every egg, one pentatonic step higher each time.
    int k = 0;
    for (int row = 0; row < PG_ROWS; row++) {
        if (_grid[reel][row] != PGSymbolEgg) continue;
        NSInteger noteIndex = before + k;
        NSInteger rowCopy = row;
        [self after:0.05 + k * 0.17 do:^{
            [self.audio playScatterNoteAtIndex:noteIndex];
            [self pulseEggAtReel:reel row:rowCopy];
        }];
        k++;
    }
    // The drum roll starts with the second egg and grows with each one after.
    if (total >= 2 && total < PG_MAX_SCATTERS && reel < PG_REELS - 1) {
        NSInteger level = MIN(3, total - 1);
        [self after:(here ? 0.3 + here * 0.1 : 0) do:^{ [self.audio startDrumRollLevel:level]; }];
    }
    if (total == PG_MAX_SCATTERS && here > 0) {
        [self.audio stopDrumRoll];
        [self after:0.3 + here * 0.17 do:^{ [self celebrateEggs:PG_MAX_SCATTERS]; }];
    }
    if (reel == PG_REELS - 1) {
        [self after:(here ? 0.45 + here * 0.17 : 0.3) do:^{ [self finishSpin]; }];
    }
}

- (void)finishSpin {
    [self.audio stopDrumRoll];
    _reelsMoving = NO;
    NSDictionary *res = self.result;
    BOOL free = _spinFree;
    NSInteger awarded = PGInteger(res[@"free_spins_awarded"]);
    NSInteger balance = PGInteger(res[@"balance"]);
    _lastAwarded = awarded;
    _freeRemaining = PGInteger(res[@"free_spins_remaining"]);
    _pickPending = PGBool(res[@"pick_pending"]);
    if (free) {
        _bonusTotal = PGInteger(res[@"bonus_total"]);
    } else if (awarded > 0) {
        _bonusLines = _lines; _bonusBet = [self betPerLine]; _bonusMult = 0; _bonusTotal = 0;
    }
    [EZEntitlementManager.shared applyKnownBalance:balance];

    NSTimeInterval wait = 0;
    if (awarded > 0 && _eggTotal < PG_MAX_SCATTERS) {
        if (_eggTotal >= 4) [self.audio playCrash];
        [self.audio playBonusFanfare];
        [self celebrateEggs:_eggTotal];
    } else if (_eggTotal == 2) {
        [self.audio playNearMissSigh];
    }
    wait = MAX(0, _celebrationEnd - CACurrentMediaTime());
    [self after:wait + 0.15 do:^{
        [self presentWinsThen:^{ [self feedMeterThen:^{ [self afterSpin]; }]; }];
    }];
}

- (void)afterSpin {
    BOOL triggered = _lastAwarded > 0;
    if (_spinFree) {
        if (_freeRemaining > 0) {
            if (triggered) {
                [self setMessage:[NSString stringWithFormat:PGLoc(@"BRSlot.PG.MoreSpins", @"+%ld MORE FREE SPINS!"), (long)_lastAwarded] highlight:YES];
            }
            [self refreshBanner];
            [self after:triggered ? 1.7 : 0.9 do:^{ [self beginSpinFree:YES]; }];
        } else {
            [self showSummary];
        }
        return;
    }
    if (triggered) {
        [self highlightEggsSticky];
        [self enterBonusMode];
        [self after:0.7 do:^{ [self presentCardPick]; }];
        return;
    }
    _busy = NO;
    [self updateControls];
    if (_balance <= 0) [self after:0.5 do:^{ [self showCoinStore]; }];
}

#pragma mark Egg meter

- (CGFloat)meterFillWidthForEggs:(NSInteger)eggs {
    CGFloat w = self.meterView.bounds.size.width, h = self.meterView.bounds.size.height;
    if (eggs <= 0 || _meterSize <= 0) return 0;
    return MIN(w, MAX(h * 0.7, w * MIN(1.0, (CGFloat)eggs / _meterSize)));   // never a sliver
}

- (void)updateMeterAnimated:(BOOL)animated {
    CGFloat w = self.meterView.bounds.size.width, h = self.meterView.bounds.size.height;
    if (w < 1) return;
    self.meterGradient.frame = CGRectMake(0, 0, w, h);          // fixed, so colour maps to meter position
    [NSUserDefaults.standardUserDefaults setInteger:_meterEggs forKey:kPGMeterKey];
    CGRect target = CGRectMake(0, 0, [self meterFillWidthForEggs:_meterEggs], h);
    if (animated) {
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut animations:^{ self.meterFill.frame = target; } completion:nil];
    } else {
        self.meterFill.frame = target;
    }
    // Nearly full: the rim pulses to tease the explosion.
    BOOL near = _meterSize > 0 && (CGFloat)_meterEggs / _meterSize >= 0.85;
    if (near && ![self.meterView.layer animationForKey:@"pgNear"]) {
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"borderColor"];
        pulse.fromValue = (id)[PGGold() colorWithAlphaComponent:.65].CGColor;
        pulse.toValue = (id)UIColor.whiteColor.CGColor;
        pulse.duration = 0.5; pulse.autoreverses = YES; pulse.repeatCount = HUGE_VALF;
        [self.meterView.layer addAnimation:pulse forKey:@"pgNear"];
    } else if (!near) {
        [self.meterView.layer removeAnimationForKey:@"pgNear"];
    }
}

/// A small flourish on the meter each time an egg lands in it.
- (void)bumpMeter {
    [UIView animateWithDuration:0.09 animations:^{ self.meterView.transform = CGAffineTransformMakeScale(1.035, 1.12); }
                     completion:^(BOOL f) { [UIView animateWithDuration:0.16 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0 options:0 animations:^{ self.meterView.transform = CGAffineTransformIdentity; } completion:nil]; }];
}

/// After the wins: every golden egg on the board flies off its reel into the
/// meter with a whoosh. If that fills the meter, it explodes and pays out.
- (void)feedMeterThen:(dispatch_block_t)completion {
    NSDictionary *res = self.result;
    if (PGInteger(res[@"meter_size"]) > 0) _meterSize = PGInteger(res[@"meter_size"]);
    BOOL hasMeter = res[@"meter_eggs"] != nil;
    BOOL filled = PGBool(res[@"meter_filled"]);
    NSInteger payout = PGInteger(res[@"meter_payout"]);
    NSInteger after = MAX(0, MIN(_meterSize, PGInteger(res[@"meter_eggs"])));
    NSInteger finalBalance = PGInteger(res[@"balance"]);
    if (!hasMeter || _eggTotal <= 0) {
        if (hasMeter) { _meterEggs = after; [self updateMeterAnimated:YES]; }
        completion();
        return;
    }
    // Where every egg starts: its cell, in screen coordinates.
    NSMutableArray<NSValue *> *starts = [NSMutableArray array];
    CGFloat s = _cellSize;
    for (int r = 0; r < PG_REELS; r++) for (int row = 0; row < PG_ROWS; row++) {
        if (_grid[r][row] != PGSymbolEgg) continue;
        CGRect cell = [self.reelViews[r] convertRect:CGRectMake(0, row * s, s, s) toView:self.view];
        [starts addObject:[NSValue valueWithCGRect:CGRectInset(cell, s * 0.05, s * 0.05)]];
    }
    NSInteger count = starts.count;
    NSInteger before = _meterEggs;
    __block NSInteger arrived = 0;
    NSUInteger epoch = _epoch;
    for (NSInteger k = 0; k < count; k++) {
        CGRect start = starts[k].CGRectValue;
        NSTimeInterval delay = k * 0.15;
        [self after:delay do:^{
            if (self->_leaving || self->_epoch != epoch) return;
            UIImageView *egg = [[UIImageView alloc] initWithImage:[BRPenguinParadeArt imageForSymbol:PGSymbolEgg size:start.size]];
            egg.frame = start;
            egg.layer.shadowColor = PGC(0xFFD86B).CGColor;
            egg.layer.shadowOpacity = 1; egg.layer.shadowRadius = 12; egg.layer.shadowOffset = CGSizeZero;
            [self.view addSubview:egg];
            [self.audio playEggWhooshAtIndex:k];

            NSInteger expected = MIN(self->_meterSize, before + k + 1);
            CGPoint edge = [self.meterView convertPoint:CGPointMake([self meterFillWidthForEggs:expected] - 10, self.meterView.bounds.size.height / 2) toView:self.view];
            CGPoint from = egg.center;
            CGPoint control = CGPointMake((from.x + edge.x) / 2 + (k % 2 ? 60 : -60), MIN(from.y, edge.y) - 70);
            UIBezierPath *path = [UIBezierPath bezierPath];
            [path moveToPoint:from];
            [path addQuadCurveToPoint:edge controlPoint:control];

            // Sparkle trail: little glows left behind along the arc.
            for (int t = 1; t <= 6; t++) {
                [self after:0.07 * t do:^{
                    CGPoint here = egg.layer.presentationLayer ? egg.layer.presentationLayer.position : egg.center;
                    UIView *spark = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
                    spark.center = here;
                    spark.layer.cornerRadius = 4;
                    spark.backgroundColor = PGC(0xFFE48F);
                    spark.layer.shadowColor = PGC(0xFFE48F).CGColor; spark.layer.shadowOpacity = 1; spark.layer.shadowRadius = 5; spark.layer.shadowOffset = CGSizeZero;
                    [self.view insertSubview:spark belowSubview:egg];
                    [UIView animateWithDuration:0.35 animations:^{ spark.alpha = 0; spark.transform = CGAffineTransformMakeScale(0.2, 0.2); } completion:^(BOOL f) { [spark removeFromSuperview]; }];
                }];
            }
            CAKeyframeAnimation *fly = [CAKeyframeAnimation animationWithKeyPath:@"position"];
            fly.path = path.CGPath;
            fly.duration = 0.5;
            fly.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.55 :0.0 :0.8 :0.6];   // ease-in: it accelerates into the meter
            fly.fillMode = kCAFillModeForwards; fly.removedOnCompletion = NO;
            CABasicAnimation *shrink = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            shrink.fromValue = @1.0; shrink.toValue = @0.3; shrink.duration = 0.5;
            shrink.fillMode = kCAFillModeForwards; shrink.removedOnCompletion = NO;
            CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            spin.fromValue = @0; spin.toValue = @(M_PI * (k % 2 ? 2 : -2)); spin.duration = 0.5;
            spin.fillMode = kCAFillModeForwards; spin.removedOnCompletion = NO;
            [CATransaction begin];
            [CATransaction setCompletionBlock:^{
                [egg removeFromSuperview];
                if (self->_leaving || self->_epoch != epoch) return;
                self->_meterEggs = expected;
                [self updateMeterAnimated:YES];
                [self bumpMeter];
                [self haptic:UIImpactFeedbackStyleLight];
                arrived++;
                if (arrived == count) {
                    [self after:0.25 do:^{
                        if (self->_leaving || self->_epoch != epoch) return;
                        if (filled) {
                            self->_meterEggs = self->_meterSize;
                            [self updateMeterAnimated:YES];
                            [self explodeMeterWithPayout:payout newBalance:finalBalance remainder:after completion:completion];
                        } else {
                            self->_meterEggs = after;
                            [self updateMeterAnimated:YES];
                            completion();
                        }
                    }];
                }
            }];
            [egg.layer addAnimation:fly forKey:@"fly"];
            [egg.layer addAnimation:shrink forKey:@"shrink"];
            [egg.layer addAnimation:spin forKey:@"spin"];
            [CATransaction commit];
        }];
    }
}

/// Meter full: it charges, shakes, flashes and bursts into eggs, coins and ice
/// shards, a coin shower falls, the prize counts up and the meter starts over.
- (void)explodeMeterWithPayout:(NSInteger)payout newBalance:(NSInteger)newBalance remainder:(NSInteger)remainder completion:(dispatch_block_t)completion {
    UIView *host = self.view;
    CGPoint center = [self.meterView.superview convertPoint:self.meterView.center toView:host];
    NSUInteger epoch = _epoch;
    self.bannerLabel.text = PGLoc(@"BRSlot.PG.MeterFull", @"EGG METER FULL!");
    self.bannerLabel.textColor = UIColor.whiteColor;
    [self.audio playMeterCharge];
    [self haptic:UIImpactFeedbackStyleMedium];

    // 1. Charge: the meter trembles harder and glows.
    CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    NSMutableArray *xs = [NSMutableArray array];
    for (int i = 0; i < 36; i++) [xs addObject:@((i % 2 ? 1 : -1) * (1.0 + 7.0 * i / 36.0))];
    [xs addObject:@0];
    shake.values = xs; shake.duration = 1.3;
    [self.meterView.layer addAnimation:shake forKey:@"pgShake"];
    self.meterView.layer.masksToBounds = NO;
    self.meterView.layer.shadowColor = PGC(0xFFE48F).CGColor;
    self.meterView.layer.shadowOffset = CGSizeZero;
    CABasicAnimation *glow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    glow.fromValue = @0; glow.toValue = @1; glow.duration = 1.3; glow.fillMode = kCAFillModeForwards; glow.removedOnCompletion = NO;
    [self.meterView.layer addAnimation:glow forKey:@"pgGlow"];
    self.meterView.layer.shadowRadius = 22;
    for (int i = 0; i < 4; i++) {            // rising white flashes on the fill
        [self after:0.2 + i * 0.3 do:^{
            [UIView animateWithDuration:0.12 animations:^{ self.meterFill.alpha = 0.45; } completion:^(BOOL f) { [UIView animateWithDuration:0.12 animations:^{ self.meterFill.alpha = 1; }]; }];
            [self haptic:UIImpactFeedbackStyleLight];
        }];
    }

    // 2. Boom.
    [self after:1.4 do:^{
        if (self->_leaving || self->_epoch != epoch) { completion(); return; }
        [self.audio playMeterBoom];
        [self haptic:UIImpactFeedbackStyleHeavy];
        [self after:0.12 do:^{ [self haptic:UIImpactFeedbackStyleHeavy]; }];

        UIView *flash = [[UIView alloc] initWithFrame:host.bounds];
        flash.backgroundColor = UIColor.whiteColor; flash.userInteractionEnabled = NO; flash.alpha = 0.9;
        [host addSubview:flash];
        [UIView animateWithDuration:0.55 animations:^{ flash.alpha = 0; } completion:^(BOOL f) { [flash removeFromSuperview]; }];

        for (int i = 0; i < 3; i++) {        // expanding shock rings
            UIView *ring = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
            ring.center = center; ring.userInteractionEnabled = NO;
            ring.layer.cornerRadius = 30;
            ring.layer.borderWidth = 5 - i;
            ring.layer.borderColor = (i == 1 ? PGC(0x6FD6FF) : PGC(0xFFE48F)).CGColor;
            ring.alpha = 0.95;
            [host addSubview:ring];
            [UIView animateWithDuration:0.9 delay:0.1 * i options:UIViewAnimationOptionCurveEaseOut animations:^{
                ring.transform = CGAffineTransformMakeScale(12 + i * 3, 12 + i * 3);
                ring.alpha = 0;
            } completion:^(BOOL f) { [ring removeFromSuperview]; }];
        }

        // One-shot burst of eggs, coins and ice shards from the meter.
        CAEmitterLayer *burst = [CAEmitterLayer layer];
        burst.frame = host.bounds;
        burst.emitterPosition = center;
        burst.emitterShape = kCAEmitterLayerPoint;
        burst.renderMode = kCAEmitterLayerAdditive;
        NSMutableArray *cells = [NSMutableArray array];
        UIImage *eggImage = [BRPenguinParadeArt imageForSymbol:PGSymbolEgg size:CGSizeMake(34, 34)];
        for (NSNumber *kind in @[@0, @1, @2]) {
            CAEmitterCell *cell = [CAEmitterCell emitterCell];
            cell.contents = (id)(kind.intValue == 0 ? eggImage : PGParticleImage(kind.intValue == 1)).CGImage;
            cell.birthRate = 90; cell.lifetime = 2.6;
            cell.velocity = 380; cell.velocityRange = 170;
            cell.emissionRange = 2 * M_PI;
            cell.yAcceleration = 420;
            cell.spin = 3; cell.spinRange = 6;
            cell.scale = kind.intValue == 0 ? 0.7 : 0.55; cell.scaleRange = 0.3;
            cell.alphaSpeed = -0.3;
            [cells addObject:cell];
        }
        burst.emitterCells = cells;
        [host.layer addSublayer:burst];
        [self after:0.14 do:^{ burst.birthRate = 0; }];
        [self after:3.0 do:^{ [burst removeFromSuperlayer]; }];

        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.35 initialSpringVelocity:0 options:0 animations:^{
            self.meterView.transform = CGAffineTransformMakeScale(1.08, 1.4);
        } completion:^(BOOL f) { [UIView animateWithDuration:0.4 animations:^{ self.meterView.transform = CGAffineTransformIdentity; }]; }];
        [self startConfettiIn:host duration:3.2 intensity:1.8];

        // Prize banner.
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MIN(host.bounds.size.width - 40, 320), 130)];
        card.center = CGPointMake(host.bounds.size.width / 2, CGRectGetMidY([self.machine convertRect:self.machine.bounds toView:host]));
        card.backgroundColor = [PGC(0x0A2344) colorWithAlphaComponent:.94];
        card.layer.cornerRadius = 26; card.layer.borderWidth = 3; card.layer.borderColor = PGGold().CGColor;
        card.layer.shadowColor = PGC(0xFFE48F).CGColor; card.layer.shadowOpacity = 1; card.layer.shadowRadius = 24; card.layer.shadowOffset = CGSizeZero;
        card.userInteractionEnabled = NO;
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(8, 12, card.bounds.size.width - 16, 34)];
        title.text = PGLoc(@"BRSlot.PG.MeterBoom", @"EGG-SPLOSION!");
        title.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBlack];
        title.textColor = PGC(0xBFE6FF); title.textAlignment = NSTextAlignmentCenter;
        UILabel *prize = [[UILabel alloc] initWithFrame:CGRectMake(8, 52, card.bounds.size.width - 16, 56)];
        prize.font = [UIFont monospacedDigitSystemFontOfSize:44 weight:UIFontWeightBlack];
        prize.textColor = PGC(0xFFE48F); prize.textAlignment = NSTextAlignmentCenter;
        prize.adjustsFontSizeToFitWidth = YES; prize.minimumScaleFactor = 0.5;
        prize.text = @"+0";
        [card addSubview:title]; [card addSubview:prize];
        [host addSubview:card];
        card.transform = CGAffineTransformMakeScale(0.2, 0.2); card.alpha = 0;
        [UIView animateWithDuration:0.55 delay:0.15 usingSpringWithDamping:0.5 initialSpringVelocity:0.6 options:0 animations:^{
            card.transform = CGAffineTransformIdentity; card.alpha = 1;
        } completion:nil];
        [self after:0.3 do:^{
            [self.audio playWinForPayoutRatio:20];
            [self countLabel:prize from:0 to:payout duration:1.4 formatter:^NSString *(NSInteger v) { return [NSString stringWithFormat:@"+%@", PGNum(v)]; }];
            NSInteger fromBalance = self->_balance;
            [self countLabel:self.balanceLabel from:fromBalance to:newBalance duration:1.4 formatter:^NSString *(NSInteger v) {
                return [NSString stringWithFormat:PGLoc(@"BRSlot.Balance.Value", @"🪙 %ld EZ Coins"), (long)v];
            }];
            self->_balance = newBalance;
            self->_balanceChecked = YES;
        }];
        [self setMessage:[NSString stringWithFormat:PGLoc(@"BRSlot.PG.MeterWon", @"Egg meter bonus: %ld coins!"), (long)payout] highlight:YES];

        // 3. Reset: the card leaves and the meter drains back to the remainder.
        [self after:3.6 do:^{
            [UIView animateWithDuration:0.35 animations:^{ card.alpha = 0; card.transform = CGAffineTransformMakeScale(1.15, 1.15); } completion:^(BOOL f) { [card removeFromSuperview]; }];
            [self.meterView.layer removeAnimationForKey:@"pgGlow"];
            [self.meterView.layer removeAnimationForKey:@"pgShake"];
            self.meterView.layer.shadowOpacity = 0;
            self.meterView.layer.masksToBounds = YES;
            self->_meterEggs = remainder;
            [UIView animateWithDuration:0.9 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
                self.meterFill.frame = CGRectMake(0, 0, [self meterFillWidthForEggs:remainder], self.meterView.bounds.size.height);
            } completion:nil];
            [self updateMeterAnimated:YES];
            [self refreshBanner];
            [self after:1.0 do:completion];
        }];
    }];
}

#pragma mark Wins and highlights

static NSArray<UIColor *> *PGLineColors(void) {
    return @[PGC(0xFFD60A), PGC(0x30D158), PGC(0x64D2FF), PGC(0xFF453A), PGC(0xBF5AF2), PGC(0xFF9F0A), PGC(0x5E5CE6), PGC(0xFF375F), PGC(0xA7F432)];
}

- (void)clearHighlights {
    for (NSInteger r = 0; r < PG_REELS; r++) {
        for (UIView *mark in self.highlights[r]) { mark.hidden = YES; [mark.layer removeAllAnimations]; }
        for (UIImageView *cell in self.stripCells[r]) { [cell.layer removeAllAnimations]; cell.transform = CGAffineTransformIdentity; }
    }
}

- (void)lightCellAtReel:(NSInteger)reel row:(NSInteger)row color:(UIColor *)color pulse:(BOOL)pulse {
    UIView *mark = self.highlights[reel][row];
    mark.hidden = NO;
    mark.layer.borderColor = color.CGColor;
    mark.backgroundColor = [color colorWithAlphaComponent:.22];
    if (pulse) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @1; fade.toValue = @0.45; fade.duration = 0.4; fade.autoreverses = YES; fade.repeatCount = HUGE_VALF;
        [mark.layer addAnimation:fade forKey:@"gmPulse"];
        UIImageView *cell = self.stripCells[reel][1 + row];
        [UIView animateWithDuration:0.18 animations:^{ cell.transform = CGAffineTransformMakeScale(1.1, 1.1); }];
    }
}

- (void)highlightEggsSticky {
    for (NSInteger r = 0; r < PG_REELS; r++)
        for (NSInteger row = 0; row < PG_ROWS; row++)
            if (_grid[r][row] == PGSymbolEgg) [self lightCellAtReel:r row:row color:PGGold() pulse:YES];
}

- (void)presentWinsThen:(dispatch_block_t)completion {
    NSDictionary *res = self.result;
    NSInteger payout = PGInteger(res[@"payout"]);
    NSInteger balance = PGInteger(res[@"balance"]) - PGInteger(res[@"meter_payout"]);   // meter prize lands with the explosion
    NSInteger bet = PGInteger(res[@"bet_per_line"]) ?: 1;
    NSInteger lines = PGInteger(res[@"lines"]) ?: 1;
    NSInteger fromBalance = _balance;
    _balance = balance;
    _balanceChecked = YES;
    NSArray *winners = [res[@"winning_lines"] isKindOfClass:NSArray.class] ? res[@"winning_lines"] : @[];
    if (payout <= 0) {
        [self refreshLabels];
        [self setMessage:_spinFree ? PGLoc(@"BRSlot.PG.FreeNoWin", @"Free spin · no win")
                                   : [NSString stringWithFormat:PGLoc(@"BRSlot.PG.NoWin", @"No win · −%ld coins"), (long)_spinWager] highlight:NO];
        [self after:_spinFree ? 0.5 : 0.2 do:completion];
        return;
    }
    if ([BRSlotCelebration celebrateBigWinInView:self.view payout:payout totalBet:MAX(1, lines * bet)]) {
        [self.audio playBonusFanfare];
    }
    [self.audio playWinForPayoutRatio:(double)payout / (double)MAX(1, lines * bet)];
    [self countLabel:self.winLabel from:0 to:payout duration:0.9 formatter:^NSString *(NSInteger v) { return PGNum(v); }];
    [self pulseWin];
    [self countLabel:self.balanceLabel from:fromBalance to:balance duration:0.9 formatter:^NSString *(NSInteger v) {
        return [NSString stringWithFormat:PGLoc(@"BRSlot.Balance.Value", @"🪙 %ld EZ Coins"), (long)v];
    }];
    [self setMessage:[NSString stringWithFormat:PGLoc(@"BRSlot.PG.WonCoins", @"Won %ld coins!"), (long)payout] highlight:YES];

    NSArray<UIColor *> *palette = PGLineColors();
    NSTimeInterval per = _spinFree ? 0.75 : 1.0;
    BOOL oneByOne = winners.count <= 3;
    for (NSUInteger i = 0; i < winners.count; i++) {
        NSDictionary *line = winners[i];
        if (![line isKindOfClass:NSDictionary.class]) continue;
        NSArray *rows = [line[@"rows"] isKindOfClass:NSArray.class] ? line[@"rows"] : @[];
        NSInteger matches = MIN(5, MAX(0, PGInteger(line[@"matches"])));
        NSInteger lineIndex = MAX(0, PGInteger(line[@"index"]));
        UIColor *color = palette[lineIndex % (NSInteger)palette.count];
        NSString *symbolName = [line[@"symbol"] isKindOfClass:NSString.class] ? line[@"symbol"] : @"";
        NSString *detail = [NSString stringWithFormat:PGLoc(@"BRSlot.PG.WinLine", @"Line %ld · %ld× %@ · +%@"),
                            (long)(lineIndex + 1), (long)matches,
                            [BRPenguinParadeArt nameForSymbol:(PGSymbol)MAX(0, MIN(PGSymbolEgg, (NSInteger)[PGSymbolNames() indexOfObject:symbolName]))],
                            PGNum(PGInteger(line[@"coins"]))];
        void (^show)(void) = ^{
            if (oneByOne) [self clearHighlights];
            for (NSInteger col = 0; col < matches && col < (NSInteger)rows.count; col++) {
                NSInteger row = PGInteger(rows[col]);
                if (row >= 0 && row < PG_ROWS) [self lightCellAtReel:col row:row color:color pulse:oneByOne];
            }
            if (oneByOne) [self setMessage:detail highlight:YES];
        };
        if (oneByOne) [self after:i * per do:show]; else show();
    }
    if (!oneByOne) {
        for (UIView *mark in [self.highlights valueForKeyPath:@"@unionOfArrays.self"]) (void)mark;
    }
    NSTimeInterval total = oneByOne ? MAX(1.2, winners.count * per + 0.3) : 1.8;
    [self after:total do:^{
        if (self->_lastAwarded <= 0) [self clearHighlights];   // keep eggs lit if a bonus follows
        else { [self clearHighlights]; }
        completion();
    }];
}

- (void)countLabel:(UILabel *)label from:(NSInteger)from to:(NSInteger)to duration:(NSTimeInterval)duration formatter:(NSString *(^)(NSInteger))formatter {
    NSInteger steps = MAX(1, (NSInteger)(duration * 30));
    for (NSInteger i = 1; i <= steps; i++) {
        double p = (double)i / steps, eased = 1 - (1 - p) * (1 - p);
        NSInteger value = from + (NSInteger)llround((to - from) * eased);
        [self after:duration * p do:^{ label.text = formatter(value); }];
    }
}

#pragma mark Egg effects

- (void)pulseEggAtReel:(NSInteger)reel row:(NSInteger)row {
    CGFloat s = _cellSize;
    UIView *reelView = self.reelViews[reel];
    CGRect slot = [reelView convertRect:CGRectMake(0, row * s, s, s) toView:self.machine];
    CGRect frame = CGRectInset(slot, s * 0.05, s * 0.05);
    UIImageView *copy = [[UIImageView alloc] initWithImage:[BRPenguinParadeArt imageForSymbol:PGSymbolEgg size:frame.size]];
    copy.frame = frame;
    copy.layer.shadowColor = PGC(0xFFD86B).CGColor;
    copy.layer.shadowOpacity = 1; copy.layer.shadowRadius = 14; copy.layer.shadowOffset = CGSizeZero;
    UIView *ring = [[UIView alloc] initWithFrame:CGRectMake(0, 0, slot.size.width, slot.size.width)];
    ring.center = CGPointMake(CGRectGetMidX(slot), CGRectGetMidY(slot));
    ring.layer.cornerRadius = slot.size.width / 2;
    ring.layer.borderWidth = 3;
    ring.layer.borderColor = PGC(0xFFD86B).CGColor;
    [self.machine addSubview:ring];
    [self.machine addSubview:copy];
    [UIView animateWithDuration:0.16 animations:^{ copy.transform = CGAffineTransformMakeScale(1.4, 1.4); } completion:^(BOOL f) {
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0 options:0 animations:^{ copy.transform = CGAffineTransformIdentity; } completion:^(BOOL f2) {
            [UIView animateWithDuration:0.2 animations:^{ copy.alpha = 0; } completion:^(BOOL f3) { [copy removeFromSuperview]; }];
        }];
    }];
    [UIView animateWithDuration:0.6 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        ring.transform = CGAffineTransformMakeScale(2.6, 2.6);
        ring.alpha = 0;
    } completion:^(BOOL f) { [ring removeFromSuperview]; }];
}

/// 3 or 4 eggs: banner and a short confetti burst. 5 eggs: alarm, flashing
/// light, shaking cabinet, swinging bells and a long confetti shower.
- (void)celebrateEggs:(NSInteger)eggs {
    NSTimeInterval duration = eggs >= 5 ? 5.4 : eggs == 4 ? 3.8 : 3.2;
    NSTimeInterval end = CACurrentMediaTime() + duration;
    if (end < _celebrationEnd - 0.2) return;           // already celebrating something bigger
    _celebrationEnd = end;
    if (eggs >= 5) [self.audio playAlarmCelebration];
    UINotificationFeedbackGenerator *generator = [UINotificationFeedbackGenerator new];
    [generator notificationOccurred:UINotificationFeedbackTypeSuccess];

    [self.celebrationOverlay removeFromSuperview];
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.userInteractionEnabled = NO;
    [self.view addSubview:overlay];
    self.celebrationOverlay = overlay;
    CGFloat width = overlay.bounds.size.width;

    UILabel *main = [UILabel new];
    main.text = [NSString stringWithFormat:PGLoc(@"BRSlot.PG.Eggs", @"%ld GOLDEN EGGS!"), (long)eggs];
    main.font = [UIFont systemFontOfSize:eggs >= 5 ? 40 : 34 weight:UIFontWeightBlack];
    main.textColor = PGC(0xFFE48F);
    main.textAlignment = NSTextAlignmentCenter;
    main.layer.shadowColor = PGC(0x4FB7F0).CGColor;
    main.layer.shadowOpacity = 1; main.layer.shadowRadius = 8; main.layer.shadowOffset = CGSizeZero;
    main.frame = CGRectMake(0, 0, width, 50);
    UILabel *sub = [UILabel new];
    sub.text = PGLoc(@"BRSlot.PG.EggsSub", @"FREE SPINS UNLOCKED");
    sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    sub.textColor = UIColor.whiteColor;
    sub.textAlignment = NSTextAlignmentCenter;
    sub.frame = CGRectMake(0, 48, width, 22);
    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 76)];
    banner.backgroundColor = [PGC(0x0F2E55) colorWithAlphaComponent:.9];
    banner.center = CGPointMake(width / 2, CGRectGetMidY([self.machine convertRect:self.machine.bounds toView:self.view]));
    [banner addSubview:main]; [banner addSubview:sub];
    [overlay addSubview:banner];
    banner.transform = CGAffineTransformMakeScale(0.3, 0.3);
    banner.alpha = 0;
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.8 options:0 animations:^{
        banner.transform = CGAffineTransformIdentity; banner.alpha = 1;
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse | UIViewAnimationOptionAllowUserInteraction animations:^{
            banner.transform = CGAffineTransformMakeScale(1.05, 1.05);
        } completion:nil];
    }];

    if (eggs >= 5) {
        UIView *flash = [[UIView alloc] initWithFrame:overlay.bounds];
        flash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        flash.alpha = 0.3;
        flash.backgroundColor = PGC(0x2AA8FF);
        [overlay insertSubview:flash atIndex:0];
        CABasicAnimation *strobe = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
        strobe.fromValue = (id)PGC(0x2AA8FF).CGColor; strobe.toValue = (id)PGC(0xFFC83A).CGColor;
        strobe.duration = 0.18; strobe.autoreverses = YES; strobe.repeatCount = HUGE_VALF;
        [flash.layer addAnimation:strobe forKey:@"gmStrobe"];

        CABasicAnimation *shake = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        shake.fromValue = @-5; shake.toValue = @5; shake.duration = 0.05; shake.autoreverses = YES; shake.repeatCount = HUGE_VALF;
        [self.machine.layer addAnimation:shake forKey:@"gmShake"];
        [self after:duration do:^{ [self.machine.layer removeAnimationForKey:@"gmShake"]; }];

        CGFloat top = self.view.safeAreaInsets.top + 6;
        NSArray<NSNumber *> *xs = @[@(28), @(width - 28), @(width * 0.3), @(width * 0.7)];
        for (NSUInteger i = 0; i < xs.count; i++) {
            UILabel *bell = [UILabel new];
            bell.text = @"🔔";
            bell.font = [UIFont systemFontOfSize:i < 2 ? 46 : 38];
            [bell sizeToFit];
            bell.layer.anchorPoint = CGPointMake(0.5, 0);
            bell.center = CGPointMake(xs[i].doubleValue, top + (i < 2 ? 0 : 8));
            [overlay addSubview:bell];
            CABasicAnimation *swing = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
            swing.fromValue = @-0.5; swing.toValue = @0.5; swing.duration = 0.2 + 0.03 * i; swing.autoreverses = YES; swing.repeatCount = HUGE_VALF;
            [bell.layer addAnimation:swing forKey:@"gmSwing"];
        }
        [self startConfettiIn:overlay duration:4.2 intensity:1.0];
    } else {
        [self startConfettiIn:overlay duration:1.6 intensity:0.5];
    }

    [self after:duration do:^{
        [UIView animateWithDuration:0.35 animations:^{ overlay.alpha = 0; } completion:^(BOOL f) { [overlay removeFromSuperview]; }];
    }];
}

- (void)startConfettiIn:(UIView *)host duration:(NSTimeInterval)duration intensity:(CGFloat)intensity {
    CAEmitterLayer *emitter = [CAEmitterLayer layer];
    emitter.frame = host.bounds;
    emitter.emitterPosition = CGPointMake(host.bounds.size.width / 2, -12);
    emitter.emitterSize = CGSizeMake(host.bounds.size.width, 2);
    emitter.emitterShape = kCAEmitterLayerLine;
    emitter.renderMode = kCAEmitterLayerUnordered;
    NSMutableArray *cells = [NSMutableArray array];
    for (NSNumber *coin in @[@YES, @NO]) {
        CAEmitterCell *cell = [CAEmitterCell emitterCell];
        cell.contents = (id)PGParticleImage(coin.boolValue).CGImage;
        cell.birthRate = 12 * intensity;
        cell.lifetime = 5.5;
        cell.velocity = 170; cell.velocityRange = 70;
        cell.emissionLongitude = M_PI_2; cell.emissionRange = M_PI / 5;
        cell.yAcceleration = 260;
        cell.spin = 2.5; cell.spinRange = 4;
        cell.scale = 0.55; cell.scaleRange = 0.25;
        [cells addObject:cell];
    }
    emitter.emitterCells = cells;
    [host.layer addSublayer:emitter];
    [self after:duration do:^{ emitter.birthRate = 0; }];
    [self after:duration + 5.6 do:^{ [emitter removeFromSuperlayer]; }];
}

#pragma mark Bonus mode

- (void)enterBonusMode {
    _bonusMode = YES;
    [self refreshLabels];
    [self refreshBanner];
    [self updateControls];
    [UIView animateWithDuration:0.4 animations:^{
        self.machine.layer.borderColor = PGC(0xFFE066).CGColor;
        self.machine.backgroundColor = PGC(0x1A5A9A);
    }];
    self.machine.layer.shadowOpacity = 0.85;
    self.background.gradientLayer.colors = @[(id)PGC(0x1A5A9A).CGColor, (id)PGC(0x2A0508).CGColor];
    [self.audio startThemeBonus:YES];
}

- (void)exitBonusMode {
    _bonusMode = NO;
    [UIView animateWithDuration:0.4 animations:^{
        self.machine.layer.borderColor = PGC(0x9FE4FF).CGColor;
        self.machine.backgroundColor = PGC(0x0F2E55);
    }];
    self.machine.layer.shadowOpacity = 0;
    self.background.gradientLayer.colors = @[(id)PGC(0x12447A).CGColor, (id)PGC(0x041226).CGColor];
    [self.audio startThemeBonus:NO];
    [self refreshLabels];
    [self refreshBanner];
    [self updateControls];
}

#pragma mark Egg hatch

/// One bonus "slot": a penguin on an ice floe holding an egg. The egg hides a
/// chick; the chick wears the multiplier. Every sub-view is kept in a parallel
/// array indexed by identity — never viewWithTag: (the unit's own tag is its
/// identity 0/1/2, which would collide with sub-view tags).
- (UIView *)makeHatchUnitAtIdentity:(NSInteger)identity width:(CGFloat)w {
    CGFloat h = w * 1.6;
    UIView *unit = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    unit.tag = identity;

    UIImageView *floe = [[UIImageView alloc] initWithImage:[BRPenguinParadeArt floeWithSize:CGSizeMake(w * 1.1, w * 0.33)]];
    floe.frame = CGRectMake(-w * 0.05, h - w * 0.33, w * 1.1, w * 0.33);
    [unit addSubview:floe];

    CGFloat penguinH = w * 1.4;
    CGFloat penguinTop = h - penguinH - w * 0.12;
    UIImageView *penguin = [[UIImageView alloc] initWithImage:[BRPenguinParadeArt bonusPenguinWithVariant:identity size:CGSizeMake(w, penguinH)]];
    penguin.frame = CGRectMake(0, penguinTop, w, penguinH);
    [unit addSubview:penguin];

    CGPoint eggCenter = CGPointMake(w / 2, penguinTop + penguinH * 0.64);
    CGFloat e = w * 0.6;
    UIImageView *egg = [[UIImageView alloc] initWithImage:[BRPenguinParadeArt eggWithStage:0 size:CGSizeMake(e, e)]];
    egg.bounds = CGRectMake(0, 0, e, e);
    egg.center = eggCenter;
    [unit addSubview:egg];

    CGFloat c = w * 0.84;
    UIImageView *chick = [[UIImageView alloc] initWithImage:[BRPenguinParadeArt hatchlingWithSize:CGSizeMake(c, c)]];
    chick.bounds = CGRectMake(0, 0, c, c);
    chick.center = CGPointMake(eggCenter.x, eggCenter.y - w * 0.04);
    chick.hidden = YES;
    chick.transform = CGAffineTransformMakeScale(0.2, 0.2);
    [unit addSubview:chick];

    CGSize shell = CGSizeMake(e * 0.9, e * 0.54);
    UIImageView *shellTop = [[UIImageView alloc] initWithImage:[BRPenguinParadeArt shellHalfTop:YES size:shell]];
    shellTop.bounds = CGRectMake(0, 0, shell.width, shell.height);
    shellTop.center = CGPointMake(eggCenter.x, eggCenter.y - e * 0.2);
    shellTop.hidden = YES;
    UIImageView *shellBottom = [[UIImageView alloc] initWithImage:[BRPenguinParadeArt shellHalfTop:NO size:shell]];
    shellBottom.bounds = CGRectMake(0, 0, shell.width, shell.height);
    shellBottom.center = CGPointMake(eggCenter.x, eggCenter.y + e * 0.24);
    shellBottom.hidden = YES;
    [unit addSubview:shellBottom];
    [unit addSubview:shellTop];

    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(w * 0.1, eggCenter.y + w * 0.02, w * 0.8, w * 0.34)];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.font = [UIFont systemFontOfSize:w * 0.28 weight:UIFontWeightBlack];
    badge.textColor = PGC(0x14305A);
    badge.backgroundColor = [UIColor colorWithWhite:1 alpha:.95];
    badge.layer.cornerRadius = w * 0.17;
    badge.layer.borderWidth = 2.5;
    badge.layer.borderColor = PGGold().CGColor;
    badge.clipsToBounds = YES;
    badge.adjustsFontSizeToFitWidth = YES;
    badge.minimumScaleFactor = 0.6;
    badge.alpha = 0;
    [unit addSubview:badge];

    [self.pickEggs addObject:egg];
    [self.pickChicks addObject:chick];
    [self.pickShellTops addObject:shellTop];
    [self.pickShellBottoms addObject:shellBottom];
    [self.pickValues addObject:badge];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTapped:)];
    [unit addGestureRecognizer:tap];
    return unit;
}

- (void)presentCardPick {
    [self.pickOverlay removeFromSuperview];
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithRed:.02 green:.07 blue:.16 alpha:.92];
    overlay.alpha = 0;
    [self.view addSubview:overlay];
    self.pickOverlay = overlay;
    _pickEnabled = NO; _pickInFlight = NO;
    CGFloat width = overlay.bounds.size.width, height = overlay.bounds.size.height;

    NSInteger spins = MAX(1, _freeRemaining);
    self.pickTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, height * 0.12, width - 32, 44)];
    self.pickTitle.text = [NSString stringWithFormat:PGLoc(@"BRSlot.PG.Pick.Title", @"%ld FREE SPINS"), (long)spins];
    self.pickTitle.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBlack];
    self.pickTitle.textColor = PGC(0xBFE6FF);
    self.pickTitle.textAlignment = NSTextAlignmentCenter;
    self.pickSubtitle = [[UILabel alloc] initWithFrame:CGRectMake(16, CGRectGetMaxY(self.pickTitle.frame), width - 32, 30)];
    self.pickSubtitle.text = PGLoc(@"BRSlot.PG.Pick.Subtitle", @"PICK AN EGG");
    self.pickSubtitle.font = [UIFont systemFontOfSize:22 weight:UIFontWeightHeavy];
    self.pickSubtitle.textColor = PGGold();
    self.pickSubtitle.textAlignment = NSTextAlignmentCenter;
    self.pickPrompt = [[UILabel alloc] initWithFrame:CGRectMake(24, CGRectGetMaxY(self.pickSubtitle.frame) + 6, width - 48, 44)];
    self.pickPrompt.numberOfLines = 2;
    self.pickPrompt.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.pickPrompt.textColor = [UIColor colorWithWhite:1 alpha:.88];
    self.pickPrompt.textAlignment = NSTextAlignmentCenter;
    self.pickPrompt.text = PGLoc(@"BRSlot.PG.Pick.Shuffling", @"The penguins are shuffling the eggs…");
    [overlay addSubview:self.pickTitle]; [overlay addSubview:self.pickSubtitle]; [overlay addSubview:self.pickPrompt];

    CGFloat unitWidth = MIN(104, (width - 56) / 3), unitHeight = unitWidth * 1.6;
    self.pickCards = [NSMutableArray array];
    self.pickSlots = [NSMutableArray array];
    self.pickEggs = [NSMutableArray array];
    self.pickChicks = [NSMutableArray array];
    self.pickShellTops = [NSMutableArray array];
    self.pickShellBottoms = [NSMutableArray array];
    self.pickValues = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        _slotCenters[i] = CGPointMake(width / 2 + (i - 1) * (unitWidth + 10), height * 0.56);
        UIView *unit = [self makeHatchUnitAtIdentity:i width:unitWidth];
        unit.center = CGPointMake(_slotCenters[i].x, height + unitHeight);
        [overlay addSubview:unit];
        [self.pickCards addObject:unit];
        [self.pickSlots addObject:unit];
        [UIView animateWithDuration:0.55 delay:0.12 * i usingSpringWithDamping:0.7 initialSpringVelocity:0 options:0 animations:^{
            unit.center = self->_slotCenters[i];
        } completion:^(BOOL finished) { if (finished) [self.audio playPenguinHonk]; }];
    }
    [UIView animateWithDuration:0.3 animations:^{ overlay.alpha = 1; }];
    [self.audio playBonusFanfare];
    [self after:1.2 do:^{ [self shuffleStep:0 of:11]; }];
}

/// Theatrical shuffle: the server decides what each egg hides only when one is
/// picked, so the shuffle changes nothing about the odds.
- (void)shuffleStep:(NSInteger)step of:(NSInteger)total {
    if (!self.pickOverlay) return;
    if (step >= total) {
        _pickEnabled = YES;
        self.pickPrompt.text = PGLoc(@"BRSlot.PG.Pick.Prompt", @"Pick a penguin. One egg hatches a multiplier for every free spin.");
        return;
    }
    NSInteger a = arc4random_uniform(3);
    NSInteger b = (a + 1 + arc4random_uniform(2)) % 3;
    UIView *unitA = self.pickSlots[a], *unitB = self.pickSlots[b];
    self.pickSlots[a] = unitB;
    self.pickSlots[b] = unitA;
    NSTimeInterval duration = 0.36 - 0.18 * ((double)step / MAX(1, total - 1));
    CGPoint ca = _slotCenters[a], cb = _slotCenters[b];
    CGPoint mid = CGPointMake((ca.x + cb.x) / 2, (ca.y + cb.y) / 2);
    [self.pickOverlay bringSubviewToFront:unitA];
    if (step % 3 == 0) [self.audio playPenguinHonk];
    [UIView animateKeyframesWithDuration:duration delay:0 options:UIViewKeyframeAnimationOptionCalculationModeLinear animations:^{
        [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.5 animations:^{
            unitA.center = CGPointMake(mid.x, mid.y - 24);
            unitB.center = CGPointMake(mid.x, mid.y + 24);
            unitA.transform = CGAffineTransformMakeRotation(0.12);
            unitB.transform = CGAffineTransformMakeRotation(-0.12);
        }];
        [UIView addKeyframeWithRelativeStartTime:0.5 relativeDuration:0.5 animations:^{
            unitA.center = cb;
            unitB.center = ca;
            unitA.transform = CGAffineTransformIdentity;
            unitB.transform = CGAffineTransformIdentity;
        }];
    } completion:^(BOOL finished) {
        if (self->_leaving) return;
        [self shuffleStep:step + 1 of:total];
    }];
}

- (void)cardTapped:(UITapGestureRecognizer *)tap {
    if (!_pickEnabled || _pickInFlight || !tap.view) return;
    _pickInFlight = YES;
    NSInteger identity = tap.view.tag;
    [self.audio playPenguinHonk];
    [self haptic:UIImpactFeedbackStyleMedium];
    UIView *unit = tap.view;
    [UIView animateWithDuration:0.15 animations:^{ unit.transform = CGAffineTransformMakeTranslation(0, -12); }
                     completion:^(BOOL f) { [UIView animateWithDuration:0.15 animations:^{ unit.transform = CGAffineTransformIdentity; }]; }];
    self.pickPrompt.text = PGLoc(@"BRSlot.PG.Pick.Wait", @"Listening to the egg…");
    [self request:@{@"action": @"pick", @"card": @(identity)} completion:^(NSDictionary *result, NSString *error, NSInteger status) {
        if (self->_leaving) return;
        NSArray *cards = result[@"cards"];
        if (error || ![cards isKindOfClass:NSArray.class] || cards.count != 3) {
            self->_pickInFlight = NO;
            if (status == 409) {                 // nothing to pick; re-sync and close
                [self closePickOverlayThen:^{ self->_busy = NO; [self refreshState]; }];
                return;
            }
            self.pickPrompt.text = PGLoc(@"BRSlot.PG.Pick.Retry", @"Couldn't reach the server. Tap a penguin to try again.");
            return;
        }
        self->_pickEnabled = NO;
        [self revealPick:result identity:identity];
    }];
}

/// Wobble, crack, burst: egg `i` hatches into a chick wearing its value.
- (void)hatchEgg:(NSInteger)i value:(NSInteger)value chirp:(BOOL)chirp {
    UIImageView *egg = self.pickEggs[i];
    UIImageView *chick = self.pickChicks[i];
    UIImageView *top = self.pickShellTops[i], *bottom = self.pickShellBottoms[i];
    UILabel *badge = self.pickValues[i];
    CGFloat e = egg.bounds.size.width;
    badge.text = [NSString stringWithFormat:@"×%ld", (long)value];

    // Wobble.
    [UIView animateKeyframesWithDuration:0.6 delay:0 options:0 animations:^{
        static const CGFloat angles[5] = { -0.22, 0.22, -0.3, 0.3, 0 };
        for (int k = 0; k < 5; k++)
            [UIView addKeyframeWithRelativeStartTime:k * 0.2 relativeDuration:0.2 animations:^{ egg.transform = CGAffineTransformMakeRotation(angles[k]); }];
    } completion:nil];
    // Cracks.
    [self after:0.45 do:^{ egg.image = [BRPenguinParadeArt eggWithStage:1 size:CGSizeMake(e, e)]; }];
    [self after:0.75 do:^{ egg.image = [BRPenguinParadeArt eggWithStage:2 size:CGSizeMake(e, e)]; }];
    // Burst.
    [self after:1.05 do:^{
        egg.hidden = YES;
        top.hidden = NO; bottom.hidden = NO; chick.hidden = NO;
        [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.8 options:0 animations:^{
            chick.transform = CGAffineTransformIdentity;
        } completion:nil];
        [UIView animateWithDuration:0.5 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            top.center = CGPointMake(top.center.x - e * 0.5, top.center.y - e * 0.55);
            top.transform = CGAffineTransformMakeRotation(-0.9);
            top.alpha = 0;
            bottom.center = CGPointMake(bottom.center.x + e * 0.5, bottom.center.y + e * 0.15);
            bottom.transform = CGAffineTransformMakeRotation(0.8);
            bottom.alpha = 0;
        } completion:nil];
        [UIView animateWithDuration:0.3 delay:0.25 options:0 animations:^{ badge.alpha = 1; } completion:nil];
        badge.transform = CGAffineTransformMakeScale(0.4, 0.4);
        [UIView animateWithDuration:0.45 delay:0.25 usingSpringWithDamping:0.55 initialSpringVelocity:0.6 options:0 animations:^{ badge.transform = CGAffineTransformIdentity; } completion:nil];
        if (chirp) { [self.audio playHatchlingChirp]; [self haptic:UIImpactFeedbackStyleHeavy]; }
    }];
    [self after:0.45 do:^{ if (chirp) [self.audio playEggCrack]; }];
}

- (void)revealPick:(NSDictionary *)result identity:(NSInteger)identity {
    NSArray *cards = result[@"cards"];
    NSInteger multiplier = PGInteger(result[@"multiplier"]);
    // Values stay bound to identity: the penguin the player tapped
    // (pickCards[identity]) shows cards[identity], the value the server
    // recorded for this pick; the other two show what they would have been.
    _bonusMult = multiplier;
    _pickPending = NO;
    UIView *picked = self.pickCards[identity];
    [self.pickOverlay bringSubviewToFront:picked];
    self.pickPrompt.text = PGLoc(@"BRSlot.PG.Pick.Hatching", @"Something's hatching…");
    [self.audio playEggWobble];

    // 1. ALL THREE eggs hatch together so the player sees what every egg held.
    for (NSInteger i = 0; i < 3; i++) [self hatchEgg:i value:PGInteger(cards[i]) chirp:(i == identity)];

    // 2. Hold on the full reveal, then the two unpicked penguins fade and the
    // picked one takes centre stage, still showing its value.
    [self after:2.9 do:^{
        for (NSInteger i = 0; i < 3; i++) {
            if (i == identity) continue;
            UIView *unit = self.pickCards[i];
            [UIView animateWithDuration:0.35 animations:^{ unit.alpha = 0; } completion:^(BOOL finished) { unit.hidden = YES; }];
        }
        [UIView animateWithDuration:0.35 animations:^{
            picked.center = self->_slotCenters[1];
            picked.transform = CGAffineTransformMakeScale(1.18, 1.18);
        }];
    }];
    // 3. A beat with only the winner, then celebrate the multiplier.
    [self after:3.9 do:^{
        [self.audio playMultiplierReveal:multiplier];
        [self haptic:UIImpactFeedbackStyleHeavy];
        self.pickPrompt.text = [NSString stringWithFormat:PGLoc(@"BRSlot.PG.Pick.Result", @"Your multiplier: ×%ld"), (long)multiplier];
        self.pickPrompt.textColor = PGC(0xFFE48F);
        self.pickPrompt.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBlack];
    }];
    [self after:5.0 do:^{
        [self closePickOverlayThen:^{
            [self refreshBanner];
            [self setMessage:[NSString stringWithFormat:PGLoc(@"BRSlot.PG.BonusStart", @"×%ld free spins begin!"), (long)multiplier] highlight:YES];
            [self after:0.9 do:^{ [self beginSpinFree:YES]; }];
        }];
    }];
}

- (void)closePickOverlayThen:(dispatch_block_t)completion {
    UIView *overlay = self.pickOverlay;
    [UIView animateWithDuration:0.35 animations:^{ overlay.alpha = 0; } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
        if (self.pickOverlay == overlay) self.pickOverlay = nil;
        if (!self->_leaving) completion();
    }];
}

#pragma mark Bonus summary

- (void)showSummary {
    NSInteger total = _bonusTotal, mult = _bonusMult;
    [self.summaryOverlay removeFromSuperview];
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithRed:.02 green:.07 blue:.16 alpha:.88];
    overlay.alpha = 0;
    [self.view addSubview:overlay];
    self.summaryOverlay = overlay;
    CGFloat width = overlay.bounds.size.width, height = overlay.bounds.size.height;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, height * 0.30, width - 32, 44)];
    title.text = PGLoc(@"BRSlot.PG.Summary.Title", @"FREE SPINS COMPLETE");
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBlack];
    title.textColor = PGC(0xFFE48F);
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(16, CGRectGetMaxY(title.frame) + 4, width - 32, 24)];
    sub.text = [NSString stringWithFormat:PGLoc(@"BRSlot.PG.Summary.Sub", @"×%ld  ·  TOTAL WIN"), (long)MAX(1, mult)];
    sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    sub.textColor = PGGold();
    sub.textAlignment = NSTextAlignmentCenter;
    UILabel *amount = [[UILabel alloc] initWithFrame:CGRectMake(16, CGRectGetMaxY(sub.frame) + 10, width - 32, 64)];
    amount.text = [NSString stringWithFormat:@"🪙 %@", PGNum(0)];
    amount.font = [UIFont monospacedDigitSystemFontOfSize:48 weight:UIFontWeightBlack];
    amount.textColor = UIColor.whiteColor;
    amount.textAlignment = NSTextAlignmentCenter;
    amount.adjustsFontSizeToFitWidth = YES;
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, CGRectGetMaxY(amount.frame) + 12, width - 32, 20)];
    hint.text = PGLoc(@"BRSlot.PG.Summary.Tap", @"Tap to continue");
    hint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    hint.textColor = [UIColor colorWithWhite:1 alpha:.6];
    hint.textAlignment = NSTextAlignmentCenter;
    [overlay addSubview:title]; [overlay addSubview:sub]; [overlay addSubview:amount]; [overlay addSubview:hint];
    [overlay addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSummary)]];
    [UIView animateWithDuration:0.35 animations:^{ overlay.alpha = 1; }];
    if (total > 0) {
        [self.audio playWinForPayoutRatio:30];
        [self countLabel:amount from:0 to:total duration:1.4 formatter:^NSString *(NSInteger v) { return [NSString stringWithFormat:@"🪙 %@", PGNum(v)]; }];
        [self startConfettiIn:overlay duration:2.4 intensity:0.7];
    }
    [self after:5.0 do:^{ [self dismissSummary]; }];
}

- (void)dismissSummary {
    UIView *overlay = self.summaryOverlay;
    if (!overlay) return;
    self.summaryOverlay = nil;
    [UIView animateWithDuration:0.3 animations:^{ overlay.alpha = 0; } completion:^(BOOL finished) { [overlay removeFromSuperview]; }];
    _bonusMult = 0; _bonusTotal = 0; _freeRemaining = 0; _pickPending = NO;
    [self exitBonusMode];
    _busy = NO;
    [self updateControls];
    [self setMessage:PGLoc(@"BRSlot.PG.Idle", @"Match 3 or more symbols from the left on a payline.") highlight:NO];
    [self refreshState];
}

@end
