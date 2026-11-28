// BRRouletteTableViewController.m
// EZCompleteUI v1.0
//
// Purpose:
//   The live multiplayer roulette table (European, single zero, 37 pockets).
//   The server (br-roulette / rl_* database functions) owns everything that
//   matters: the winning number, which bets are accepted, every coin debit and
//   payout, and the betting / spinning / results timers. This screen:
//     1. joins the table, then polls "state" about every 1.5 seconds,
//     2. lets the player stack chips on a real-table board and sends them in
//        one "bet" request (the server validates limits and balance again),
//     3. draws the wheel, ball, last numbers, players and the balance,
//     4. shows the shared table chat through BRSlotChatBar (room "rl:<id>"),
//     5. calls out each phase change in the table dealer's recorded voice
//        (BRRouletteDealer: shared ElevenLabs clips, Apple voice only as a
//        fallback) and plays the table sound effects (BRRouletteAudio: chips,
//        the spinning wheel and ball, wins, a quiet casino ambience). Both obey
//        the shared game-sounds switch, BRSlotSoundEnabled.
//   Because the client never decides an outcome, a tweaked app cannot pick the
//   number, bet after the spin or invent coins.
//
// Screen layout (top to bottom): header row (Leave, balance), status + timer,
// then a scrolling column with the wheel, last numbers, board, chips,
// buttons and the player list. The chat bar is pinned under the scroll area.
//
// Changes from v0 (new file):
//   - Initial version.
//   - Dealer call-outs with the device speech voice, in the device language.
//   - Dealer call-outs now use BRRouletteDealer (the same ElevenLabs clips as the
//     blackjack dealers, per table and per language); the device voice is only
//     the fallback while clips are missing.
//   - Table sound effects through BRRouletteAudio (chip place/remove, betting
//     bell, wheel spin timed to the server's spin window, win/loss, ambience).
//   - Every player-facing string goes through NSLocalizedStringWithDefaultValue
//     (keys BRRoulette.*), with the English text as the default value.

#import "BRRouletteTableViewController.h"
#import "BRRouletteAPI.h"
#import "BRRouletteAudio.h"
#import "BRRouletteDealer.h"
#import "BRSlotChatBar.h"
#import "EZEntitlementManager.h"
#import <AVFoundation/AVFoundation.h>

// Defined in BRSlotChatBar.m: the shared "game sounds" switch.
extern BOOL BRSlotSoundEnabled(void);

static const NSTimeInterval kPollInterval = 1.5;
static const NSTimeInterval kMaxPollBackoff = 6.0;
// Space reserved at the bottom of the screen for the collapsed chat bar.
static const CGFloat kChatBarReservedHeight = 60.0;
static const CGFloat kBoardCellHeight = 36.0;
static const CGFloat kBoardGap = 2.0;
static const CGFloat kDozenColumnWidth = 54.0;
static const CGFloat kWheelSize = 230.0;
static const NSInteger kMaxChipChoices = 6;

#pragma mark - Wheel data and small helpers

// Pocket order around a European wheel, clockwise starting at zero.
static const NSInteger kWheelOrder[37] = {
    0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10, 5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26
};

static NSDictionary *BRRouletteDict(id value) { return [value isKindOfClass:[NSDictionary class]] ? value : @{}; }
static NSArray *BRRouletteArray(id value) { return [value isKindOfClass:[NSArray class]] ? value : @[]; }
static NSInteger BRRouletteInt(id value) { return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0; }
static NSString *BRRouletteString(id value) { return [value isKindOfClass:[NSString class]] ? value : @""; }

/// Matches the server's rl_color(): 0 is green, the listed numbers are red.
static BOOL BRRouletteIsRed(NSInteger number) {
    static NSSet<NSNumber *> *reds;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reds = [NSSet setWithArray:@[@1, @3, @5, @7, @9, @12, @14, @16, @18, @19, @21, @23, @25, @27, @30, @32, @34, @36]];
    });
    return [reds containsObject:@(number)];
}

static NSString *BRRouletteColorName(NSInteger number) {
    if (number == 0) return NSLocalizedStringWithDefaultValue(@"BRRoulette.Color.Green", nil, NSBundle.mainBundle, @"green", nil);
    return BRRouletteIsRed(number) ? NSLocalizedStringWithDefaultValue(@"BRRoulette.Color.Red", nil, NSBundle.mainBundle, @"red", nil) : NSLocalizedStringWithDefaultValue(@"BRRoulette.Color.Black", nil, NSBundle.mainBundle, @"black", nil);
}

static UIColor *BRRouletteColorForNumber(NSInteger number) {
    if (number == 0) return [UIColor colorWithRed:.05 green:.55 blue:.25 alpha:1];
    if (BRRouletteIsRed(number)) return [UIColor colorWithRed:.78 green:.10 blue:.12 alpha:1];
    return [UIColor colorWithRed:.08 green:.08 blue:.10 alpha:1];
}

/// Key used locally for one board spot: "straight:17", "red", "dozen2", ...
static NSString *BRRouletteSpotKey(NSString *betType, NSInteger number) {
    return [betType isEqualToString:@"straight"] ? [NSString stringWithFormat:@"straight:%ld", (long)number] : betType;
}

static NSString *BRRouletteFormatCoins(NSInteger coins) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [NSNumberFormatter new]; formatter.numberStyle = NSNumberFormatterDecimalStyle; });
    return [formatter stringFromNumber:@(coins)] ?: [NSString stringWithFormat:@"%ld", (long)coins];
}

#pragma mark - Wheel view

/// Draws the 37-pocket wheel and animates the wheel and ball. It only draws:
/// the number it is told to land on always comes from the server.
@interface BRRouletteWheelView : UIView
@property (nonatomic, strong) UILabel *centerLabel;
/// Rotates the wheel and orbits the ball so the ball ends on the given number.
- (void)spinToNumber:(NSInteger)number duration:(NSTimeInterval)duration;
/// Jumps straight to the finished position (joined late, or came back from the background).
- (void)settleOnNumber:(NSInteger)number;
@end

@implementation BRRouletteWheelView {
    CALayer *_wheelLayer;
    CALayer *_ballOrbitLayer;
    CGSize _builtSize;
    CGFloat _currentWheelAngle;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        _wheelLayer = [CALayer layer];
        _ballOrbitLayer = [CALayer layer];
        [self.layer addSublayer:_wheelLayer];
        [self.layer addSublayer:_ballOrbitLayer];

        _centerLabel = [UILabel new];
        _centerLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _centerLabel.textAlignment = NSTextAlignmentCenter;
        _centerLabel.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBlack];
        _centerLabel.textColor = UIColor.whiteColor;
        _centerLabel.adjustsFontSizeToFitWidth = YES;
        _centerLabel.minimumScaleFactor = 0.5;
        [self addSubview:_centerLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_centerLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_centerLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_centerLabel.widthAnchor constraintEqualToAnchor:self.widthAnchor multiplier:0.34],
        ]];
        self.isAccessibilityElement = NO;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (CGSizeEqualToSize(_builtSize, self.bounds.size) || self.bounds.size.width < 40) return;
    _builtSize = self.bounds.size;
    [self rebuildLayers];
}

/// Builds the pocket wedges, number labels and ball once per size.
- (void)rebuildLayers {
    [_wheelLayer.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
    [_ballOrbitLayer.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    CGRect bounds = self.bounds;
    CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    CGFloat outerRadius = MIN(bounds.size.width, bounds.size.height) / 2.0 - 2.0;
    CGFloat pocketOuter = outerRadius * 0.93;
    CGFloat pocketInner = outerRadius * 0.66;
    CGFloat segment = 2.0 * M_PI / 37.0;

    _wheelLayer.frame = bounds;
    _ballOrbitLayer.frame = bounds;
    _wheelLayer.transform = CATransform3DMakeRotation(_currentWheelAngle, 0, 0, 1);

    CAShapeLayer *rim = [CAShapeLayer layer];
    rim.path = [UIBezierPath bezierPathWithArcCenter:center radius:outerRadius startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
    rim.fillColor = [UIColor colorWithRed:.36 green:.20 blue:.08 alpha:1].CGColor;
    rim.strokeColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1].CGColor;
    rim.lineWidth = 2;
    [_wheelLayer addSublayer:rim];

    for (NSInteger index = 0; index < 37; index++) {
        NSInteger number = kWheelOrder[index];
        // Pocket 0 is centred straight up; angles in UIKit run clockwise from the +x axis.
        CGFloat centerAngle = index * segment - M_PI_2;
        CGFloat startAngle = centerAngle - segment / 2.0;
        CGFloat endAngle = centerAngle + segment / 2.0;
        UIBezierPath *wedge = [UIBezierPath bezierPathWithArcCenter:center radius:pocketOuter startAngle:startAngle endAngle:endAngle clockwise:YES];
        [wedge addArcWithCenter:center radius:pocketInner startAngle:endAngle endAngle:startAngle clockwise:NO];
        [wedge closePath];
        CAShapeLayer *pocket = [CAShapeLayer layer];
        pocket.path = wedge.CGPath;
        pocket.fillColor = BRRouletteColorForNumber(number).CGColor;
        pocket.strokeColor = [UIColor colorWithWhite:1 alpha:.55].CGColor;
        pocket.lineWidth = 0.6;
        [_wheelLayer addSublayer:pocket];

        CATextLayer *text = [CATextLayer layer];
        text.string = [NSString stringWithFormat:@"%ld", (long)number];
        text.fontSize = MAX(7.5, outerRadius * 0.075);
        text.alignmentMode = kCAAlignmentCenter;
        text.foregroundColor = UIColor.whiteColor.CGColor;
        text.contentsScale = UIScreen.mainScreen.scale;
        CGFloat labelRadius = (pocketOuter + pocketInner) / 2.0 + 1.0;
        text.bounds = CGRectMake(0, 0, 18, 12);
        text.position = CGPointMake(center.x + cos(centerAngle) * labelRadius, center.y + sin(centerAngle) * labelRadius);
        // Rotate the label so its top points away from the hub.
        text.affineTransform = CGAffineTransformMakeRotation(centerAngle + M_PI_2);
        [_wheelLayer addSublayer:text];
    }

    CAShapeLayer *hub = [CAShapeLayer layer];
    hub.path = [UIBezierPath bezierPathWithArcCenter:center radius:pocketInner - 3 startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
    hub.fillColor = [UIColor colorWithRed:.03 green:.17 blue:.11 alpha:1].CGColor;
    hub.strokeColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:.8].CGColor;
    hub.lineWidth = 2;
    [_wheelLayer addSublayer:hub];

    // The ball sits at the top of its orbit layer; rotating the orbit layer moves it around.
    CGFloat ballDiameter = MAX(9.0, outerRadius * 0.085);
    CALayer *ball = [CALayer layer];
    ball.bounds = CGRectMake(0, 0, ballDiameter, ballDiameter);
    ball.cornerRadius = ballDiameter / 2.0;
    ball.backgroundColor = UIColor.whiteColor.CGColor;
    ball.shadowColor = UIColor.blackColor.CGColor;
    ball.shadowOpacity = 0.6;
    ball.shadowRadius = 2;
    ball.shadowOffset = CGSizeMake(0, 1);
    ball.position = CGPointMake(center.x, center.y - (pocketOuter + pocketInner) / 2.0);
    [_ballOrbitLayer addSublayer:ball];
    [CATransaction commit];
}

- (void)settleOnNumber:(NSInteger)number {
    [_wheelLayer removeAllAnimations];
    [_ballOrbitLayer removeAllAnimations];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _currentWheelAngle = [self restingAngleForNumber:number];
    _wheelLayer.transform = CATransform3DMakeRotation(_currentWheelAngle, 0, 0, 1);
    _ballOrbitLayer.transform = CATransform3DIdentity;
    [CATransaction commit];
}

- (void)spinToNumber:(NSInteger)number duration:(NSTimeInterval)duration {
    if (duration < 1.0) { [self settleOnNumber:number]; return; }
    CGFloat fromAngle = _currentWheelAngle;
    // The wheel turns counter-clockwise for a few full turns and stops with the
    // winning pocket at the top; the ball laps clockwise and stops at the top too.
    CGFloat toAngle = [self restingAngleForNumber:number] - 2.0 * M_PI * 3.0;
    CAMediaTimingFunction *easeOut = [CAMediaTimingFunction functionWithControlPoints:0.15 :0.6 :0.25 :1.0];

    CABasicAnimation *wheelSpin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    wheelSpin.fromValue = @(fromAngle);
    wheelSpin.toValue = @(toAngle);
    wheelSpin.duration = duration;
    wheelSpin.timingFunction = easeOut;
    [_wheelLayer addAnimation:wheelSpin forKey:@"spin"];

    CABasicAnimation *ballSpin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    ballSpin.fromValue = @0;
    ballSpin.toValue = @(2.0 * M_PI * 6.0);
    ballSpin.duration = duration;
    ballSpin.timingFunction = easeOut;
    [_ballOrbitLayer addAnimation:ballSpin forKey:@"orbit"];

    // Model values match the end of the animations so nothing snaps back.
    _currentWheelAngle = [self restingAngleForNumber:number];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _wheelLayer.transform = CATransform3DMakeRotation(_currentWheelAngle, 0, 0, 1);
    _ballOrbitLayer.transform = CATransform3DIdentity;
    [CATransaction commit];
}

/// Angle that puts the pocket of `number` at the top of the wheel.
- (CGFloat)restingAngleForNumber:(NSInteger)number {
    NSInteger index = 0;
    for (NSInteger i = 0; i < 37; i++) {
        if (kWheelOrder[i] == number) { index = i; break; }
    }
    return -(CGFloat)index * (2.0 * M_PI / 37.0);
}

@end

#pragma mark - Table view controller

@interface BRRouletteTableViewController ()
@property (nonatomic, copy) NSString *tableID;
@property (nonatomic, copy) NSString *tableName;
@property (nonatomic, strong) NSDictionary *tableState;
@property (nonatomic) NSInteger lastVersion;
@property (nonatomic) NSTimeInterval pollDelay;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTimer *countdownTimer;
@property (nonatomic, strong) NSTimer *balanceTimer;
@property (nonatomic) BOOL requestInFlight;
@property (nonatomic) BOOL actionInFlight;
@property (nonatomic) BOOL hasJoined;
@property (nonatomic) BOOL leaving;
@property (nonatomic) NSTimeInterval serverClockOffset;

// Betting state. Pending stakes are only on this device until "Place bets" is
// tapped; confirmed stakes come back from the server in my_bets.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pendingStakes;
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *confirmedStakes;
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *confirmedPayouts;
@property (nonatomic, copy) NSArray<NSDictionary *> *previousRoundBets; // for the Repeat button
@property (nonatomic) NSInteger selectedChip;
@property (nonatomic, copy) NSArray<NSNumber *> *chipValues;

// Round tracking so each spin animates once and results are announced once.
@property (nonatomic) NSInteger animatedRound;
@property (nonatomic) NSInteger announcedRound;
@property (nonatomic) NSInteger displayedBalance;
@property (nonatomic) BOOL hasShownBalance;

// Views
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UIView *balancePill;
@property (nonatomic, strong) UILabel *balanceLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) BRRouletteWheelView *wheelView;
@property (nonatomic, strong) UIStackView *historyStack;
@property (nonatomic, strong) UIStackView *chipStack;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIButton *> *spotButtons;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *spotBadges;
@property (nonatomic, strong) UIButton *placeBetsButton;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) UIButton *repeatButton;
@property (nonatomic, strong) UILabel *limitsLabel;
@property (nonatomic, strong) UILabel *playersLabel;
@property (nonatomic, strong) BRSlotChatBar *chatBar;
@property (nonatomic, strong) BRRouletteDealer *dealer;   // recorded dealer calls
@property (nonatomic, strong) BRRouletteAudio *audio;      // table sound effects
@property (nonatomic) BOOL skipNextSpeech; // set after time away so old phase changes are not announced
@end

@implementation BRRouletteTableViewController

- (instancetype)initWithTableID:(NSString *)tableID tableName:(NSString *)tableName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _tableID = [tableID copy];
        _tableName = [tableName copy] ?: NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.Title", nil, NSBundle.mainBundle, @"Roulette", nil);
        _pollDelay = kPollInterval;
        _lastVersion = -1;
        _tableState = @{};
        _pendingStakes = [NSMutableDictionary new];
        _confirmedStakes = @{};
        _confirmedPayouts = @{};
        _previousRoundBets = @[];
        _spotButtons = [NSMutableDictionary new];
        _spotBadges = [NSMutableDictionary new];
        _animatedRound = -1;
        _announcedRound = -1;
        _chipValues = @[];
    }
    return self;
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:.03 green:.22 blue:.14 alpha:1];
    self.title = self.tableName;
    [self buildInterface];
    [self setDisplayedBalance:0];
    [self refreshControls];

    self.dealer = [[BRRouletteDealer alloc] initWithTableID:self.tableID];
    [self.dealer loadClips];
    self.audio = [BRRouletteAudio new];
    [self.audio prepare];
    // Switching game sounds off mid-call cuts the dealer off at once.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(soundSettingChanged:) name:BRSlotSoundSettingChangedNotification object:nil];

    // Stop polling in the background; resume (and resync) when active again.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResignActive) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.chatBar) {
        // Room id for roulette tables is "rl:<table id>".
        self.chatBar = [[BRSlotChatBar alloc] initWithRoomID:[@"rl:" stringByAppendingString:self.tableID]];
        self.chatBar.hostViewController = self;
        [self.chatBar attachToView:self.view];
    }
    [self.chatBar start];
    [self startTimers];
    [self.audio startAmbience];
    if (!self.hasJoined) [self joinTable];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // The expanded chat (or an alert) is presented over this screen; the
    // table must keep updating behind it, so only wind down when really leaving.
    if (self.presentedViewController != nil && !self.isMovingFromParentViewController) return;
    [self.chatBar stop];
    [self stopTimers];
    [self stopDealerSpeech];
    [self.audio stopAmbience];
    [self.audio stopSpin];
    if (self.isMovingFromParentViewController || self.isBeingDismissed || self.navigationController == nil) {
        // An interactive back-swipe reports isMovingFromParentViewController
        // while the gesture is still in flight: leaving now would strand
        // the table dead if the swipe is cancelled (leaving is never reset,
        // so the join completion frees the seat and the poll guard blocks
        // every update). Only leave once the pop actually commits.
        id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
        if (coordinator && coordinator.isInteractive) {
            __weak typeof(self) weakSelf = self;
            [coordinator notifyWhenInteractionEndsUsingBlock:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                __strong typeof(self) self = weakSelf;
                if (!self || context.isCancelled) return;
                [self leaveTableSilently];
                [self.dealer shutdown];
                [self.audio shutdown];
            }];
            return;
        }
        [self leaveTableSilently];
        [self.dealer shutdown];
        [self.audio shutdown];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopTimers];
    [self.balanceTimer invalidate];
}

- (void)appWillResignActive { [self stopTimers]; [self stopDealerSpeech]; [self.audio stopSpin]; }

- (void)soundSettingChanged:(NSNotification *)note {
    if (!BRSlotSoundEnabled()) [self stopDealerSpeech];
}

- (void)appDidBecomeActive {
    if (self.viewIfLoaded.window == nil || self.leaving) return;
    self.lastVersion = -1; // force a full redraw after time away
    self.skipNextSpeech = YES;
    [self.audio resume];
    [self startTimers];
    [self pollNow];
}

#pragma mark Interface construction

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    return label;
}

- (UIButton *)pillButtonWithTitle:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1 alpha:.4] forState:UIControlStateDisabled];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.7;
    button.backgroundColor = color;
    button.layer.cornerRadius = 12;
    [button.heightAnchor constraintEqualToConstant:46].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

/// One tappable board spot (a number or an outside bet) with a chip badge on top.
- (UIButton *)boardSpotWithTitle:(NSString *)title betType:(NSString *)betType number:(NSInteger)number background:(UIColor *)background {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.6;
    button.backgroundColor = background;
    button.layer.cornerRadius = 5;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:.35].CGColor;
    button.tag = number;
    NSString *key = BRRouletteSpotKey(betType, number);
    button.accessibilityIdentifier = key;
    button.accessibilityLabel = [betType isEqualToString:@"straight"] ? [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.A11y.NumberFormat", nil, NSBundle.mainBundle, @"Number %1$ld, %2$@", nil), (long)number, BRRouletteColorName(number)] : title;
    [button addTarget:self action:@selector(spotTapped:) forControlEvents:UIControlEventTouchUpInside];
    // Long press removes this spot's pending chips.
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(spotLongPressed:)];
    [button addGestureRecognizer:longPress];

    UILabel *badge = [UILabel new];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightHeavy];
    badge.textColor = UIColor.blackColor;
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = UIColor.whiteColor;
    badge.layer.cornerRadius = 9;
    badge.layer.borderWidth = 2;
    badge.clipsToBounds = YES;
    badge.adjustsFontSizeToFitWidth = YES;
    badge.minimumScaleFactor = 0.5;
    badge.hidden = YES;
    badge.userInteractionEnabled = NO;
    [button addSubview:badge];
    [NSLayoutConstraint activateConstraints:@[
        [badge.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
        [badge.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [badge.heightAnchor constraintEqualToConstant:18],
        [badge.widthAnchor constraintGreaterThanOrEqualToConstant:30],
        [badge.widthAnchor constraintLessThanOrEqualToAnchor:button.widthAnchor multiplier:0.95],
    ]];
    self.spotButtons[key] = button;
    self.spotBadges[key] = badge;
    return button;
}

- (UIStackView *)horizontalStackWithViews:(NSArray<UIView *> *)views {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = kBoardGap;
    return stack;
}

- (void)buildInterface {
    UIColor *gold = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // Header row: Leave on the left, large balance pill beside it.
    UIButton *leaveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    leaveButton.translatesAutoresizingMaskIntoConstraints = NO;
    [leaveButton setTitle:NSLocalizedStringWithDefaultValue(@"BRRoulette.Leave", nil, NSBundle.mainBundle, @"Leave", nil) forState:UIControlStateNormal];
    [leaveButton setTitleColor:gold forState:UIControlStateNormal];
    leaveButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [leaveButton addTarget:self action:@selector(leaveTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:leaveButton];

    self.balancePill = [UIView new];
    self.balancePill.translatesAutoresizingMaskIntoConstraints = NO;
    self.balancePill.backgroundColor = [gold colorWithAlphaComponent:.16];
    self.balancePill.layer.cornerRadius = 24;
    self.balancePill.layer.borderWidth = 2;
    self.balancePill.layer.borderColor = gold.CGColor;
    self.balancePill.isAccessibilityElement = YES;
    self.balancePill.accessibilityLabel = NSLocalizedStringWithDefaultValue(@"BRRoulette.A11y.Balance", nil, NSBundle.mainBundle, @"Coin balance", nil);
    [self.view addSubview:self.balancePill];
    self.balanceLabel = [self labelWithSize:28 weight:UIFontWeightBlack color:gold];
    self.balanceLabel.textAlignment = NSTextAlignmentCenter;
    self.balanceLabel.minimumScaleFactor = 0.6;
    [self.balancePill addSubview:self.balanceLabel];

    self.statusLabel = [self labelWithSize:16 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:1 alpha:.92]];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    [self.view addSubview:self.statusLabel];
    self.timerLabel = [self labelWithSize:13 weight:UIFontWeightMedium color:[UIColor colorWithWhite:1 alpha:.65]];
    self.timerLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.timerLabel];

    self.scrollView = [UIScrollView new];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];

    self.contentStack = [UIStackView new];
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 12;
    self.contentStack.alignment = UIStackViewAlignmentFill;
    [self.scrollView addSubview:self.contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [leaveButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [leaveButton.centerYAnchor constraintEqualToAnchor:self.balancePill.centerYAnchor],
        [self.balancePill.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [self.balancePill.heightAnchor constraintEqualToConstant:48],
        [self.balancePill.leadingAnchor constraintEqualToAnchor:leaveButton.trailingAnchor constant:12],
        [self.balancePill.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.balanceLabel.leadingAnchor constraintEqualToAnchor:self.balancePill.leadingAnchor constant:12],
        [self.balanceLabel.trailingAnchor constraintEqualToAnchor:self.balancePill.trailingAnchor constant:-12],
        [self.balanceLabel.centerYAnchor constraintEqualToAnchor:self.balancePill.centerYAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.balancePill.bottomAnchor constant:6],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.timerLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:2],
        [self.timerLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [self.timerLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.scrollView.topAnchor constraintEqualToAnchor:self.timerLabel.bottomAnchor constant:6],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-kChatBarReservedHeight],
        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-12],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.leadingAnchor constant:12],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.trailingAnchor constant:-12],
        // Content width follows the frame so the stack only scrolls vertically.
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-24],
    ]];

    [self buildWheelSection];
    [self buildBoardSection];
    [self buildChipSection];
    [self buildPlayersSection];
}

- (void)buildWheelSection {
    self.wheelView = [[BRRouletteWheelView alloc] initWithFrame:CGRectMake(0, 0, kWheelSize, kWheelSize)];
    self.wheelView.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *wheelHolder = [UIView new];
    [wheelHolder addSubview:self.wheelView];
    [NSLayoutConstraint activateConstraints:@[
        [self.wheelView.centerXAnchor constraintEqualToAnchor:wheelHolder.centerXAnchor],
        [self.wheelView.topAnchor constraintEqualToAnchor:wheelHolder.topAnchor],
        [self.wheelView.bottomAnchor constraintEqualToAnchor:wheelHolder.bottomAnchor],
        [self.wheelView.widthAnchor constraintEqualToConstant:kWheelSize],
        [self.wheelView.heightAnchor constraintEqualToConstant:kWheelSize],
    ]];
    [self.contentStack addArrangedSubview:wheelHolder];

    // Last numbers, newest on the left.
    self.historyStack = [UIStackView new];
    self.historyStack.axis = UILayoutConstraintAxisHorizontal;
    self.historyStack.spacing = 4;
    self.historyStack.alignment = UIStackViewAlignmentCenter;
    UIScrollView *historyScroll = [UIScrollView new];
    historyScroll.translatesAutoresizingMaskIntoConstraints = NO;
    historyScroll.showsHorizontalScrollIndicator = NO;
    self.historyStack.translatesAutoresizingMaskIntoConstraints = NO;
    [historyScroll addSubview:self.historyStack];
    [NSLayoutConstraint activateConstraints:@[
        [historyScroll.heightAnchor constraintEqualToConstant:30],
        [self.historyStack.leadingAnchor constraintEqualToAnchor:historyScroll.contentLayoutGuide.leadingAnchor],
        [self.historyStack.trailingAnchor constraintEqualToAnchor:historyScroll.contentLayoutGuide.trailingAnchor],
        [self.historyStack.topAnchor constraintEqualToAnchor:historyScroll.contentLayoutGuide.topAnchor],
        [self.historyStack.bottomAnchor constraintEqualToAnchor:historyScroll.contentLayoutGuide.bottomAnchor],
        [self.historyStack.heightAnchor constraintEqualToAnchor:historyScroll.frameLayoutGuide.heightAnchor],
    ]];
    [self.contentStack addArrangedSubview:historyScroll];
}

- (void)buildBoardSection {
    UIColor *feltGreen = [UIColor colorWithRed:.05 green:.38 blue:.22 alpha:1];
    UIColor *outsideColor = [UIColor colorWithRed:.07 green:.30 blue:.19 alpha:1];

    UIStackView *board = [UIStackView new];
    board.axis = UILayoutConstraintAxisVertical;
    board.spacing = kBoardGap;

    // Zero spans the full width above the grid.
    UIButton *zero = [self boardSpotWithTitle:@"0" betType:@"straight" number:0 background:BRRouletteColorForNumber(0)];
    [zero.heightAnchor constraintEqualToConstant:kBoardCellHeight].active = YES;
    [board addArrangedSubview:zero];

    // Dozens on the left, 12 rows of 3 numbers on the right: number = 3 * row + column + 1.
    UIStackView *numbersStack = [UIStackView new];
    numbersStack.axis = UILayoutConstraintAxisVertical;
    numbersStack.spacing = kBoardGap;
    for (NSInteger row = 0; row < 12; row++) {
        NSMutableArray<UIView *> *cells = [NSMutableArray new];
        for (NSInteger column = 0; column < 3; column++) {
            NSInteger number = row * 3 + column + 1;
            UIButton *cell = [self boardSpotWithTitle:[NSString stringWithFormat:@"%ld", (long)number] betType:@"straight" number:number background:BRRouletteColorForNumber(number)];
            [cell.heightAnchor constraintEqualToConstant:kBoardCellHeight].active = YES;
            [cells addObject:cell];
        }
        [numbersStack addArrangedSubview:[self horizontalStackWithViews:cells]];
    }

    UIStackView *dozenStack = [UIStackView new];
    dozenStack.axis = UILayoutConstraintAxisVertical;
    dozenStack.spacing = kBoardGap;
    dozenStack.distribution = UIStackViewDistributionFillEqually;
    NSArray<NSString *> *dozenTypes = @[@"dozen1", @"dozen2", @"dozen3"];
    NSArray<NSString *> *dozenTitles = @[NSLocalizedStringWithDefaultValue(@"BRRoulette.Board.Dozen1", nil, NSBundle.mainBundle, @"1st 12", nil), NSLocalizedStringWithDefaultValue(@"BRRoulette.Board.Dozen2", nil, NSBundle.mainBundle, @"2nd 12", nil), NSLocalizedStringWithDefaultValue(@"BRRoulette.Board.Dozen3", nil, NSBundle.mainBundle, @"3rd 12", nil)];
    for (NSInteger i = 0; i < 3; i++) {
        UIButton *dozen = [self boardSpotWithTitle:dozenTitles[(NSUInteger)i] betType:dozenTypes[(NSUInteger)i] number:-1 background:outsideColor];
        [dozenStack addArrangedSubview:dozen];
    }
    [dozenStack.widthAnchor constraintEqualToConstant:kDozenColumnWidth].active = YES;

    UIStackView *gridRow = [UIStackView new];
    gridRow.axis = UILayoutConstraintAxisHorizontal;
    gridRow.spacing = kBoardGap;
    gridRow.alignment = UIStackViewAlignmentFill;
    [gridRow addArrangedSubview:dozenStack];
    [gridRow addArrangedSubview:numbersStack];
    [board addArrangedSubview:gridRow];

    // Column bets (2 to 1) under the grid, lined up with the three number columns.
    NSArray<NSString *> *columnTypes = @[@"col1", @"col2", @"col3"];
    NSMutableArray<UIView *> *columnButtons = [NSMutableArray new];
    for (NSInteger i = 0; i < 3; i++) {
        UIButton *column = [self boardSpotWithTitle:NSLocalizedStringWithDefaultValue(@"BRRoulette.Board.Column", nil, NSBundle.mainBundle, @"2 to 1", nil) betType:columnTypes[(NSUInteger)i] number:-1 background:outsideColor];
        [columnButtons addObject:column];
    }
    UIView *columnSpacer = [UIView new];
    [columnSpacer.widthAnchor constraintEqualToConstant:kDozenColumnWidth].active = YES;
    UIStackView *columnRow = [UIStackView new];
    columnRow.axis = UILayoutConstraintAxisHorizontal;
    columnRow.spacing = kBoardGap;
    [columnRow addArrangedSubview:columnSpacer];
    [columnRow addArrangedSubview:[self horizontalStackWithViews:columnButtons]];
    [columnRow.heightAnchor constraintEqualToConstant:kBoardCellHeight].active = YES;
    [board addArrangedSubview:columnRow];

    // Even-money bets in one row of six.
    NSArray<NSArray<NSString *> *> *outside = @[
        @[@"low", @"1-18"], @[@"even", NSLocalizedStringWithDefaultValue(@"BRRoulette.Board.Even", nil, NSBundle.mainBundle, @"EVEN", nil)], @[@"red", NSLocalizedStringWithDefaultValue(@"BRRoulette.Board.Red", nil, NSBundle.mainBundle, @"RED", nil)],
        @[@"black", NSLocalizedStringWithDefaultValue(@"BRRoulette.Board.Black", nil, NSBundle.mainBundle, @"BLACK", nil)], @[@"odd", NSLocalizedStringWithDefaultValue(@"BRRoulette.Board.Odd", nil, NSBundle.mainBundle, @"ODD", nil)], @[@"high", @"19-36"],
    ];
    NSMutableArray<UIView *> *outsideButtons = [NSMutableArray new];
    for (NSArray<NSString *> *entry in outside) {
        UIColor *color = [entry[0] isEqualToString:@"red"] ? BRRouletteColorForNumber(1)
            : [entry[0] isEqualToString:@"black"] ? BRRouletteColorForNumber(2) : outsideColor;
        [outsideButtons addObject:[self boardSpotWithTitle:entry[1] betType:entry[0] number:-1 background:color]];
    }
    UIStackView *outsideRow = [self horizontalStackWithViews:outsideButtons];
    [outsideRow.heightAnchor constraintEqualToConstant:44].active = YES;
    [board addArrangedSubview:outsideRow];

    UIView *felt = [UIView new];
    felt.backgroundColor = feltGreen;
    felt.layer.cornerRadius = 10;
    felt.layer.borderWidth = 2;
    felt.layer.borderColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:.5].CGColor;
    board.translatesAutoresizingMaskIntoConstraints = NO;
    [felt addSubview:board];
    [NSLayoutConstraint activateConstraints:@[
        [board.topAnchor constraintEqualToAnchor:felt.topAnchor constant:6],
        [board.bottomAnchor constraintEqualToAnchor:felt.bottomAnchor constant:-6],
        [board.leadingAnchor constraintEqualToAnchor:felt.leadingAnchor constant:6],
        [board.trailingAnchor constraintEqualToAnchor:felt.trailingAnchor constant:-6],
    ]];
    [self.contentStack addArrangedSubview:felt];
}

- (void)buildChipSection {
    self.limitsLabel = [self labelWithSize:12 weight:UIFontWeightMedium color:[UIColor colorWithWhite:1 alpha:.65]];
    self.limitsLabel.textAlignment = NSTextAlignmentCenter;
    self.limitsLabel.numberOfLines = 2;
    [self.contentStack addArrangedSubview:self.limitsLabel];

    self.chipStack = [UIStackView new];
    self.chipStack.axis = UILayoutConstraintAxisHorizontal;
    self.chipStack.distribution = UIStackViewDistributionFillEqually;
    self.chipStack.spacing = 8;
    [self.chipStack.heightAnchor constraintEqualToConstant:46].active = YES;
    [self.contentStack addArrangedSubview:self.chipStack];

    self.clearButton = [self pillButtonWithTitle:NSLocalizedStringWithDefaultValue(@"BRRoulette.Clear", nil, NSBundle.mainBundle, @"Clear", nil) color:[UIColor colorWithWhite:1 alpha:.16] action:@selector(clearTapped)];
    self.repeatButton = [self pillButtonWithTitle:NSLocalizedStringWithDefaultValue(@"BRRoulette.Repeat", nil, NSBundle.mainBundle, @"Repeat", nil) color:[UIColor colorWithWhite:1 alpha:.16] action:@selector(repeatTapped)];
    self.placeBetsButton = [self pillButtonWithTitle:NSLocalizedStringWithDefaultValue(@"BRRoulette.PlaceBets", nil, NSBundle.mainBundle, @"Place bets", nil) color:[UIColor colorWithRed:.12 green:.55 blue:.28 alpha:1] action:@selector(placeBetsTapped)];
    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.clearButton, self.repeatButton, self.placeBetsButton]];
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 8;
    buttonRow.distribution = UIStackViewDistributionFill;
    [self.clearButton.widthAnchor constraintEqualToConstant:80].active = YES;
    [self.repeatButton.widthAnchor constraintEqualToConstant:90].active = YES;
    [self.contentStack addArrangedSubview:buttonRow];
}

- (void)buildPlayersSection {
    self.playersLabel = [self labelWithSize:14 weight:UIFontWeightMedium color:[UIColor colorWithWhite:1 alpha:.85]];
    self.playersLabel.numberOfLines = 0;
    self.playersLabel.adjustsFontSizeToFitWidth = NO;
    [self.contentStack addArrangedSubview:self.playersLabel];
}

#pragma mark Networking

- (void)joinTable {
    if (self.requestInFlight) return;
    self.requestInFlight = YES;
    self.statusLabel.text = NSLocalizedStringWithDefaultValue(@"BRRoulette.Joining", nil, NSBundle.mainBundle, @"Taking a seat…", nil);
    // This completion captures self strongly on purpose: popping the table
    // while the join is in flight would otherwise dealloc this screen with
    // the seat already taken on the server and no leave ever sent. The block
    // is released when this one-shot request resolves (12s timeout, one
    // retry at most), so the lifetime extension is bounded, and self never
    // retains the request, so there is no cycle.
    [BRRouletteAPI performAction:@"join" params:@{ @"table_id": self.tableID } completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        self.requestInFlight = NO;
        if (error) {
            // Already gone: nothing to retry and no alert to show on a
            // screen that is no longer visible.
            if (self.leaving) return;
            // A dead join (table full, bets live at another table...) can't be
            // retried meaningfully: tell the player and go back to the lobby.
            if ((status >= 400 && status < 500) || status == 409) {
                [self showFatalError:error];
            } else {
                self.statusLabel.text = error;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    // The player may have left while the retry was pending:
                    // rejoining then would take a seat nobody ever leaves.
                    if (self.viewIfLoaded.window == nil || self.leaving) return;
                    [self joinTable];
                });
            }
            return;
        }
        self.hasJoined = YES;
        if (self.leaving) {
            // Left while the join was in flight: free the seat just taken
            // instead of drawing a table nobody is looking at.
            [self sendLeaveRequest];
            return;
        }
        self.lastVersion = -1;
        [self applyResponse:json];
    }];
}

- (void)pollNow {
    if (!self.hasJoined || self.requestInFlight || self.leaving) return;
    self.requestInFlight = YES;
    NSMutableDictionary *params = [@{ @"table_id": self.tableID } mutableCopy];
    if (self.lastVersion >= 0) params[@"since_version"] = @(self.lastVersion);
    __weak typeof(self) weakSelf = self;
    [BRRouletteAPI performAction:@"state" params:params completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.requestInFlight = NO;
        if (error) {
            // The server dropped this seat after a long pause: take it again.
            if ([BRRouletteString(json[@"code"]) isEqualToString:@"rl_not_joined"]) {
                self.hasJoined = NO;
                [self joinTable];
                return;
            }
            // Back off while the connection is bad, then recover on its own.
            self.pollDelay = MIN(self.pollDelay * 1.6, kMaxPollBackoff);
            [self restartPollTimer];
            if (status == 0) self.timerLabel.text = error;
            if (json[@"view"]) [self applyResponse:json];
            return;
        }
        if (self.pollDelay != kPollInterval) { self.pollDelay = kPollInterval; [self restartPollTimer]; }
        if ([json[@"unchanged"] respondsToSelector:@selector(boolValue)] && [json[@"unchanged"] boolValue]) {
            return; // nothing new; the countdown keeps running from the last view
        }
        [self applyResponse:json];
    }];
}

/// Sends a player action and redraws from the answer. Buttons stay disabled
/// until the answer arrives so a double-tap can't send two requests.
- (void)sendAction:(NSString *)action params:(NSDictionary *)extra completion:(void (^)(BOOL success, NSString *error, NSInteger status))completion {
    if (self.actionInFlight || self.leaving) return;
    self.actionInFlight = YES;
    [self refreshControls];
    NSMutableDictionary *params = [@{ @"table_id": self.tableID } mutableCopy];
    [params addEntriesFromDictionary:extra ?: @{}];
    __weak typeof(self) weakSelf = self;
    [BRRouletteAPI performAction:action params:params completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.actionInFlight = NO;
        if (json[@"view"]) [self applyResponse:json]; // success, or a race: both carry the current table
        if (error) {
            self.statusLabel.text = error;
            if (status == 402) { // out of coins: refresh the shown balance from the server
                [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {}];
            }
            if ([BRRouletteString(json[@"code"]) isEqualToString:@"rl_not_joined"]) {
                self.hasJoined = NO;
                [self joinTable];
            }
        }
        if (completion) completion(error == nil, error, status);
        [self refreshControls];
    }];
}

/// Sends the "leave" request. Fire and forget: the server refunds bets still
/// open for betting, and keeps a player seated until a spin they are in has
/// paid out.
- (void)sendLeaveRequest {
    [BRRouletteAPI performAction:@"leave" params:@{ @"table_id": self.tableID } completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {}];
    }];
}

- (void)leaveTableSilently {
    if (self.leaving) return;
    self.leaving = YES;
    [self stopTimers];
    // The join may still be in flight: the join completion sends the leave
    // once the seat exists (see joinTable), so there is nothing to send yet.
    if (!self.hasJoined) return;
    [self sendLeaveRequest];
}

- (void)showFatalError:(NSString *)message {
    self.leaving = YES; // nothing was joined, so there is no seat to free
    [self stopTimers];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedStringWithDefaultValue(@"BRRoulette.CantJoin", nil, NSBundle.mainBundle, @"Can't join this table", nil)
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringWithDefaultValue(@"BRRoulette.OK", nil, NSBundle.mainBundle, @"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Applying server state

- (NSDate *)dateFromServerString:(NSString *)text {
    if (text.length == 0) return nil;
    static NSISO8601DateFormatter *withFraction, *plain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        withFraction = [NSISO8601DateFormatter new];
        withFraction.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [NSISO8601DateFormatter new];
    });
    return [withFraction dateFromString:text] ?: [plain dateFromString:text];
}

/// Measures how far this device's clock is from the server's so countdowns
/// stay right even when the phone's time is wrong.
- (void)updateClockOffsetFromServerNow:(id)serverNowValue {
    NSDate *serverDate = [self dateFromServerString:BRRouletteString(serverNowValue)];
    if (serverDate) self.serverClockOffset = [serverDate timeIntervalSinceNow];
}

- (void)applyResponse:(NSDictionary *)json {
    NSDictionary *view = BRRouletteDict(json[@"view"]);
    if (view.count == 0) return;
    NSInteger version = BRRouletteInt(BRRouletteDict(view[@"table"])[@"version"]);
    // Ignore a response older than what's already on screen (out-of-order replies).
    if (version < self.lastVersion) return;
    self.lastVersion = version;
    [self applyView:view];
}

- (NSString *)phase { return BRRouletteString(BRRouletteDict(self.tableState[@"table"])[@"phase"]); }

- (void)applyView:(NSDictionary *)view {
    NSString *previousPhase = [self phase];
    self.tableState = view;
    NSDictionary *table = BRRouletteDict(view[@"table"]);
    NSString *phase = BRRouletteString(table[@"phase"]);
    NSInteger round = BRRouletteInt(table[@"round_no"]);
    [self updateClockOffsetFromServerNow:view[@"server_now"]];
    self.title = BRRouletteString(table[@"name"]).length ? BRRouletteString(table[@"name"]) : self.tableName;

    // Confirmed bets and what they paid, keyed like the board spots.
    NSMutableDictionary<NSString *, NSNumber *> *confirmed = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSNumber *> *payouts = [NSMutableDictionary new];
    NSMutableArray<NSDictionary *> *betLines = [NSMutableArray new];
    for (id entry in BRRouletteArray(view[@"my_bets"])) {
        NSDictionary *bet = BRRouletteDict(entry);
        NSString *betType = BRRouletteString(bet[@"bet_type"]);
        if (betType.length == 0) continue;
        NSInteger number = bet[@"number"] == nil || bet[@"number"] == NSNull.null ? -1 : BRRouletteInt(bet[@"number"]);
        NSString *key = BRRouletteSpotKey(betType, number);
        confirmed[key] = @(confirmed[key].integerValue + BRRouletteInt(bet[@"amount"]));
        payouts[key] = @(payouts[key].integerValue + BRRouletteInt(bet[@"payout"]));
        [betLines addObject:bet];
    }
    self.confirmedStakes = confirmed;
    self.confirmedPayouts = payouts;

    // Betting is locked after the window: unsent chips can't be placed any more.
    if (![phase isEqualToString:@"betting"] && self.pendingStakes.count > 0) [self.pendingStakes removeAllObjects];
    // Remember the finished round's bets so Repeat can put them back.
    if ([phase isEqualToString:@"results"] && betLines.count > 0) self.previousRoundBets = betLines;

    [self updateChipChoicesFromTable:table];
    [self renderHistory:BRRouletteArray(view[@"history"])];
    [self handleWheelForPhase:phase round:round table:table];
    [self applyBalance:BRRouletteInt(BRRouletteDict(view[@"me"])[@"balance"]) phase:phase];
    [self renderPlayers:BRRouletteArray(view[@"players"]) phase:phase];
    [self announceResultIfNeededForPhase:phase round:round table:table view:view];
    [self speakDealerForPhase:phase previousPhase:previousPhase table:table];
    [self refreshBoard];
    [self renderStatusLine];
    [self refreshControls];
}

/// Starts the wheel animation once per round, or jumps to the finished
/// position when the player arrives late or returns from the background.
- (void)handleWheelForPhase:(NSString *)phase round:(NSInteger)round table:(NSDictionary *)table {
    BOOL revealed = [phase isEqualToString:@"spinning"] || [phase isEqualToString:@"results"];
    id winningValue = table[@"winning_number"];
    if (!revealed || winningValue == nil || winningValue == NSNull.null) {
        if ([phase isEqualToString:@"betting"] || [phase isEqualToString:@"idle"]) self.wheelView.centerLabel.text = @"";
        return;
    }
    NSInteger winning = BRRouletteInt(winningValue);
    if (self.animatedRound == round) {
        if ([phase isEqualToString:@"results"]) [self showWinningNumberInHub:winning];
        return;
    }
    self.animatedRound = round;
    NSDate *deadline = [self dateFromServerString:BRRouletteString(table[@"phase_deadline"])];
    NSTimeInterval remaining = deadline ? [deadline timeIntervalSinceNow] - self.serverClockOffset : 0;
    if ([phase isEqualToString:@"spinning"] && remaining > 1.0) {
        self.wheelView.centerLabel.text = @"…";
        self.wheelView.centerLabel.textColor = UIColor.whiteColor;
        [self.wheelView spinToNumber:winning duration:remaining];
        [self.audio playSpinWithRemaining:remaining];
    } else {
        [self.wheelView settleOnNumber:winning];
        if ([phase isEqualToString:@"results"]) [self showWinningNumberInHub:winning];
    }
}

- (void)showWinningNumberInHub:(NSInteger)winning {
    self.wheelView.centerLabel.text = [NSString stringWithFormat:@"%ld", (long)winning];
    self.wheelView.centerLabel.textColor = winning == 0 ? [UIColor colorWithRed:.3 green:.9 blue:.5 alpha:1]
        : BRRouletteIsRed(winning) ? [UIColor colorWithRed:1 green:.35 blue:.35 alpha:1] : UIColor.whiteColor;
}

- (void)renderHistory:(NSArray *)history {
    for (UIView *view in [self.historyStack.arrangedSubviews copy]) {
        [self.historyStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (id entry in history) {
        NSInteger number = BRRouletteInt(BRRouletteDict(entry)[@"n"]);
        UILabel *chip = [UILabel new];
        chip.translatesAutoresizingMaskIntoConstraints = NO;
        chip.text = [NSString stringWithFormat:@"%ld", (long)number];
        chip.textAlignment = NSTextAlignmentCenter;
        chip.textColor = UIColor.whiteColor;
        chip.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        chip.backgroundColor = BRRouletteColorForNumber(number);
        chip.layer.cornerRadius = 13;
        chip.layer.borderWidth = 1;
        chip.layer.borderColor = [UIColor colorWithWhite:1 alpha:.5].CGColor;
        chip.clipsToBounds = YES;
        chip.isAccessibilityElement = YES;
        chip.accessibilityLabel = [NSString stringWithFormat:@"%ld %@", (long)number, BRRouletteColorName(number)];
        [chip.widthAnchor constraintEqualToConstant:26].active = YES;
        [chip.heightAnchor constraintEqualToConstant:26].active = YES;
        [self.historyStack addArrangedSubview:chip];
    }
}

- (void)renderPlayers:(NSArray *)players phase:(NSString *)phase {
    if (players.count == 0) { self.playersLabel.text = @""; return; }
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (id entry in players) {
        NSDictionary *player = BRRouletteDict(entry);
        NSString *name = BRRouletteString(player[@"name"]);
        BOOL isMe = [player[@"is_me"] respondsToSelector:@selector(boolValue)] && [player[@"is_me"] boolValue];
        NSInteger totalBet = BRRouletteInt(player[@"total_bet"]);
        NSMutableString *line = [NSMutableString stringWithString:isMe ? NSLocalizedStringWithDefaultValue(@"BRRoulette.You", nil, NSBundle.mainBundle, @"⭐️ You", nil) : (name.length ? name : NSLocalizedStringWithDefaultValue(@"BRRoulette.Player", nil, NSBundle.mainBundle, @"Player", nil))];
        if (totalBet > 0) [line appendFormat:@"  ·  %@", [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.PlayerBetFormat", nil, NSBundle.mainBundle, @"bet 🪙 %@", nil), BRRouletteFormatCoins(totalBet)]];
        if ([phase isEqualToString:@"results"] && totalBet > 0 && player[@"payout"] != NSNull.null) {
            NSInteger payout = BRRouletteInt(player[@"payout"]);
            [line appendFormat:@"  ·  %@", payout > 0 ? [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.PlayerWonFormat", nil, NSBundle.mainBundle, @"won 🪙 %@", nil), BRRouletteFormatCoins(payout)] : NSLocalizedStringWithDefaultValue(@"BRRoulette.PlayerNoWin", nil, NSBundle.mainBundle, @"no win", nil)];
        }
        [lines addObject:line];
    }
    self.playersLabel.text = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.PlayersHeaderFormat", nil, NSBundle.mainBundle, @"At the table (%1$lu)\n%2$@", nil), (unsigned long)players.count, [lines componentsJoinedByString:@"\n"]];
}

/// Says what happened once per round when the results arrive.
- (void)announceResultIfNeededForPhase:(NSString *)phase round:(NSInteger)round table:(NSDictionary *)table view:(NSDictionary *)view {
    if (![phase isEqualToString:@"results"] || self.announcedRound == round) return;
    self.announcedRound = round;
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {}];
    NSInteger totalBet = BRRouletteInt(BRRouletteDict(view[@"me"])[@"total_bet"]);
    if (totalBet <= 0) return;
    NSInteger totalPayout = 0;
    for (NSNumber *payout in self.confirmedPayouts.allValues) totalPayout += payout.integerValue;
    [self.audio stopSpin];
    if (totalPayout > totalBet) [self.audio playWinForPayoutRatio:(double)totalPayout / (double)totalBet];
    else if (totalPayout < totalBet) [self.audio playLoss];
    UINotificationFeedbackGenerator *haptics = [UINotificationFeedbackGenerator new];
    [haptics notificationOccurred:totalPayout > totalBet ? UINotificationFeedbackTypeSuccess : (totalPayout == totalBet ? UINotificationFeedbackTypeWarning : UINotificationFeedbackTypeError)];
}

#pragma mark Dealer voice

/// Calls out each phase change ("Place your bets", "No more bets", the winning
/// number) with the device's speech voice. The text is the same translated
/// string shown on screen, so it is spoken in the device language.
- (void)speakDealerForPhase:(NSString *)phase previousPhase:(NSString *)previousPhase table:(NSDictionary *)table {
    if (self.skipNextSpeech) { self.skipNextSpeech = NO; return; }
    // Nothing to say on the first view after joining, or when the phase didn't change.
    if (previousPhase.length == 0 || [previousPhase isEqualToString:phase]) return;
    // keys: recorded clips to play; line: the translated text the Apple voice
    // reads when a clip isn't available (and the same text shown on screen).
    NSArray<NSString *> *keys = nil;
    NSString *line = nil;
    if ([phase isEqualToString:@"betting"]) {
        keys = @[BRRouletteClipPlaceBets];
        line = NSLocalizedStringWithDefaultValue(@"BRRoulette.Status.Betting", nil, NSBundle.mainBundle, @"Place your bets", nil);
        [self.audio playBettingOpen];
    } else if ([phase isEqualToString:@"spinning"]) {
        keys = @[BRRouletteClipNoMoreBets];
        line = NSLocalizedStringWithDefaultValue(@"BRRoulette.Status.Spinning", nil, NSBundle.mainBundle, @"No more bets! The wheel is spinning…", nil);
        [self.audio playBettingClosed];
    } else if ([phase isEqualToString:@"results"] && table[@"winning_number"] != nil && table[@"winning_number"] != NSNull.null) {
        NSInteger winning = BRRouletteInt(table[@"winning_number"]);
        keys = @[BRRouletteClipKeyForNumber(winning)];
        line = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Result.SummaryFormat", nil, NSBundle.mainBundle, @"%1$ld %2$@", nil), (long)winning, BRRouletteColorName(winning)];
    }
    if (keys.count > 0 && !self.leaving) [self.dealer speakKeys:keys fallbackText:line];
}

- (void)stopDealerSpeech {
    [self.dealer interrupt];
}

#pragma mark Balance

- (void)setDisplayedBalance:(NSInteger)balance {
    _displayedBalance = balance;
    self.balanceLabel.text = [NSString stringWithFormat:@"🪙 %@", BRRouletteFormatCoins(balance)];
    self.balancePill.accessibilityValue = BRRouletteFormatCoins(balance);
}

/// While the wheel is spinning the server has already paid out, so the new
/// balance is held back until the results phase to avoid spoiling the spin.
- (void)applyBalance:(NSInteger)newBalance phase:(NSString *)phase {
    if (!self.hasShownBalance) {
        [self setDisplayedBalance:newBalance];
        self.hasShownBalance = YES;
        return;
    }
    if ([phase isEqualToString:@"spinning"] && self.animatedRound == BRRouletteInt(BRRouletteDict(self.tableState[@"table"])[@"round_no"])) {
        return; // the results phase brings the same balance and animates it
    }
    [self animateBalanceTo:newBalance];
}

/// Counts the balance up or down over a short moment so wins are noticeable.
- (void)animateBalanceTo:(NSInteger)target {
    [self.balanceTimer invalidate];
    NSInteger start = self.displayedBalance;
    if (start == target) return;
    const NSInteger totalSteps = 20;
    __block NSInteger step = 0;
    __weak typeof(self) weakSelf = self;
    self.balanceTimer = [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *timer) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { [timer invalidate]; return; }
        step++;
        if (step >= totalSteps) {
            [timer invalidate];
            [self setDisplayedBalance:target];
            return;
        }
        double progress = (double)step / totalSteps;
        [self setDisplayedBalance:start + (NSInteger)llround((double)(target - start) * progress)];
    }];
}

#pragma mark Board rendering and betting

/// Builds the chip row from the table's limits: values that fit the bet step
/// and range, at most kMaxChipChoices of them.
- (void)updateChipChoicesFromTable:(NSDictionary *)table {
    NSInteger minBet = MAX(1, BRRouletteInt(table[@"min_bet"]));
    NSInteger betStep = MAX(1, BRRouletteInt(table[@"bet_step"]));
    NSInteger maxBet = BRRouletteInt(table[@"max_bet"]);
    NSMutableArray<NSNumber *> *values = [NSMutableArray new];
    for (NSNumber *candidate in @[@1, @5, @10, @25, @50, @100, @500, @1000, @5000, @10000]) {
        NSInteger value = candidate.integerValue;
        if (value < minBet || value % betStep != 0 || (maxBet > 0 && value > maxBet)) continue;
        [values addObject:candidate];
        if ((NSInteger)values.count >= kMaxChipChoices) break;
    }
    if (values.count == 0) [values addObject:@(minBet)];
    if ([values isEqualToArray:self.chipValues]) return;
    self.chipValues = values;
    if (![values containsObject:@(self.selectedChip)]) self.selectedChip = values.firstObject.integerValue;

    for (UIView *view in [self.chipStack.arrangedSubviews copy]) {
        [self.chipStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (NSNumber *value in values) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
        chip.translatesAutoresizingMaskIntoConstraints = NO;
        [chip setTitle:BRRouletteFormatCoins(value.integerValue) forState:UIControlStateNormal];
        [chip setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        chip.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightHeavy];
        chip.titleLabel.adjustsFontSizeToFitWidth = YES;
        chip.titleLabel.minimumScaleFactor = 0.5;
        chip.layer.cornerRadius = 23;
        chip.layer.borderWidth = 3;
        chip.tag = value.integerValue;
        chip.accessibilityLabel = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.A11y.ChipFormat", nil, NSBundle.mainBundle, @"%@ coin chip", nil), BRRouletteFormatCoins(value.integerValue)];
        [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.chipStack addArrangedSubview:chip];
    }
    [self refreshChipSelection];

    NSInteger maxStraight = BRRouletteInt(table[@"max_straight_bet"]);
    NSInteger maxTotal = BRRouletteInt(table[@"max_total_bet"]);
    self.limitsLabel.text = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.LimitsFormat", nil, NSBundle.mainBundle, @"Min 🪙 %1$@ · max %2$@ per spot (%3$@ on a single number) · %4$@ per spin", nil),
                             BRRouletteFormatCoins(minBet), BRRouletteFormatCoins(maxBet), BRRouletteFormatCoins(maxStraight), BRRouletteFormatCoins(maxTotal)];
}

- (void)refreshChipSelection {
    UIColor *gold = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];
    for (UIView *view in self.chipStack.arrangedSubviews) {
        if (![view isKindOfClass:[UIButton class]]) continue;
        BOOL selected = view.tag == self.selectedChip;
        view.backgroundColor = selected ? [UIColor colorWithRed:.55 green:.12 blue:.62 alpha:1] : [UIColor colorWithRed:.20 green:.20 blue:.28 alpha:1];
        view.layer.borderColor = (selected ? gold : [UIColor colorWithWhite:1 alpha:.4]).CGColor;
        view.transform = selected ? CGAffineTransformMakeScale(1.08, 1.08) : CGAffineTransformIdentity;
    }
}

/// Redraws every spot's chip badge and highlights the winning number.
- (void)refreshBoard {
    NSString *phase = [self phase];
    NSDictionary *table = BRRouletteDict(self.tableState[@"table"]);
    BOOL settled = [phase isEqualToString:@"results"];
    NSInteger winning = settled && table[@"winning_number"] != NSNull.null ? BRRouletteInt(table[@"winning_number"]) : -1;
    UIColor *gold = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];

    for (NSString *key in self.spotButtons) {
        UIButton *button = self.spotButtons[key];
        UILabel *badge = self.spotBadges[key];
        NSInteger confirmed = self.confirmedStakes[key].integerValue;
        NSInteger pending = self.pendingStakes[key].integerValue;
        NSInteger total = confirmed + pending;
        badge.hidden = total <= 0;
        if (total > 0) {
            badge.text = BRRouletteFormatCoins(total);
            // Gold border marks chips that are still only on this device.
            badge.layer.borderColor = (pending > 0 ? gold : [UIColor colorWithRed:.2 green:.7 blue:.3 alpha:1]).CGColor;
            badge.accessibilityLabel = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.A11y.StakeFormat", nil, NSBundle.mainBundle, @"%1$@ coins on %2$@", nil), BRRouletteFormatCoins(total), button.accessibilityLabel ?: key];
        }
        BOOL isWinningNumber = winning >= 0 && [key isEqualToString:BRRouletteSpotKey(@"straight", winning)];
        BOOL paid = settled && self.confirmedPayouts[key].integerValue > 0;
        button.layer.borderWidth = (isWinningNumber || paid) ? 3 : 1;
        button.layer.borderColor = (isWinningNumber || paid) ? gold.CGColor : [UIColor colorWithWhite:1 alpha:.35].CGColor;
    }
}

- (NSInteger)limitForSpotKey:(NSString *)key {
    NSDictionary *table = BRRouletteDict(self.tableState[@"table"]);
    return [key hasPrefix:@"straight:"] ? BRRouletteInt(table[@"max_straight_bet"]) : BRRouletteInt(table[@"max_bet"]);
}

- (NSInteger)pendingTotal {
    NSInteger total = 0;
    for (NSNumber *amount in self.pendingStakes.allValues) total += amount.integerValue;
    return total;
}

- (NSInteger)confirmedTotal {
    NSInteger total = 0;
    for (NSNumber *amount in self.confirmedStakes.allValues) total += amount.integerValue;
    return total;
}

- (BOOL)canBetNow {
    return [[self phase] isEqualToString:@"betting"] && !self.leaving && self.hasJoined;
}

/// Adds the selected chip to a spot. These limit checks only save the player a
/// wasted request; the server enforces every limit again.
- (void)addChipToSpotKey:(NSString *)key {
    if (![self canBetNow]) return;
    NSDictionary *table = BRRouletteDict(self.tableState[@"table"]);
    NSInteger spotLimit = [self limitForSpotKey:key];
    NSInteger spotNow = self.confirmedStakes[key].integerValue + self.pendingStakes[key].integerValue;
    NSInteger maxTotal = BRRouletteInt(table[@"max_total_bet"]);
    NSInteger balance = BRRouletteInt(BRRouletteDict(self.tableState[@"me"])[@"balance"]);
    NSInteger chip = self.selectedChip;

    if (spotLimit > 0 && spotNow + chip > spotLimit) {
        self.statusLabel.text = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Message.SpotLimitFormat", nil, NSBundle.mainBundle, @"Table limit on this spot is 🪙 %@.", nil), BRRouletteFormatCoins(spotLimit)];
        return;
    }
    if (maxTotal > 0 && [self confirmedTotal] + [self pendingTotal] + chip > maxTotal) {
        self.statusLabel.text = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Message.TotalLimitFormat", nil, NSBundle.mainBundle, @"You can bet up to 🪙 %@ per spin at this table.", nil), BRRouletteFormatCoins(maxTotal)];
        return;
    }
    if ([self pendingTotal] + chip > balance) {
        self.statusLabel.text = NSLocalizedStringWithDefaultValue(@"BRRoulette.Message.ChipTooBig", nil, NSBundle.mainBundle, @"Not enough coins for that chip.", nil);
        return;
    }
    self.pendingStakes[key] = @(self.pendingStakes[key].integerValue + chip);
    [[UIImpactFeedbackGenerator new] impactOccurred];
    [self.audio playChipPlace];
    [self refreshBoard];
    [self refreshControls];
}

- (void)spotTapped:(UIButton *)button {
    NSString *key = button.accessibilityIdentifier;
    if (key.length) [self addChipToSpotKey:key];
}

- (void)spotLongPressed:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    NSString *key = recognizer.view.accessibilityIdentifier;
    if (key.length && self.pendingStakes[key]) {
        [self.pendingStakes removeObjectForKey:key];
        [self.audio playChipRemove];
        [self refreshBoard];
        [self refreshControls];
    }
}

- (void)chipTapped:(UIButton *)chip {
    self.selectedChip = chip.tag;
    [self refreshChipSelection];
}

- (void)clearTapped {
    if (self.pendingStakes.count > 0) {
        [self.pendingStakes removeAllObjects];
        [self.audio playChipRemove];
        [self refreshBoard];
        [self refreshControls];
        return;
    }
    // No unsent chips: take back the bets already placed this spin (refunded by the server).
    if (![self canBetNow] || [self confirmedTotal] <= 0) return;
    [self sendAction:@"clear_bets" params:nil completion:nil];
}

- (void)repeatTapped {
    if (![self canBetNow] || self.previousRoundBets.count == 0 || [self confirmedTotal] > 0) return;
    [self.pendingStakes removeAllObjects];
    for (NSDictionary *bet in self.previousRoundBets) {
        NSString *betType = BRRouletteString(bet[@"bet_type"]);
        NSInteger number = bet[@"number"] == nil || bet[@"number"] == NSNull.null ? -1 : BRRouletteInt(bet[@"number"]);
        NSString *key = BRRouletteSpotKey(betType, number);
        self.pendingStakes[key] = @(self.pendingStakes[key].integerValue + BRRouletteInt(bet[@"amount"]));
    }
    NSInteger balance = BRRouletteInt(BRRouletteDict(self.tableState[@"me"])[@"balance"]);
    if ([self pendingTotal] > balance) {
        [self.pendingStakes removeAllObjects];
        self.statusLabel.text = NSLocalizedStringWithDefaultValue(@"BRRoulette.Message.RepeatTooBig", nil, NSBundle.mainBundle, @"Not enough coins to repeat your last bets.", nil);
    }
    [self refreshBoard];
    [self refreshControls];
}

- (void)placeBetsTapped {
    if (![self canBetNow] || self.pendingStakes.count == 0) return;
    NSMutableArray<NSDictionary *> *lines = [NSMutableArray new];
    for (NSString *key in self.pendingStakes) {
        NSInteger amount = self.pendingStakes[key].integerValue;
        if (amount <= 0) continue;
        if ([key hasPrefix:@"straight:"]) {
            NSInteger number = [[key substringFromIndex:@"straight:".length] integerValue];
            [lines addObject:@{ @"bet_type": @"straight", @"number": @(number), @"amount": @(amount) }];
        } else {
            [lines addObject:@{ @"bet_type": key, @"amount": @(amount) }];
        }
    }
    if (lines.count == 0) return;
    __weak typeof(self) weakSelf = self;
    [self sendAction:@"bet" params:@{ @"bets": lines } completion:^(BOOL success, NSString *error, NSInteger status) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // Accepted, or betting closed under us: either way the unsent chips are done.
        // Other failures (limits, coins) keep the chips so the player can adjust them.
        if (success || ![[self phase] isEqualToString:@"betting"]) {
            [self.pendingStakes removeAllObjects];
            [self refreshBoard];
            [self refreshControls];
        }
    }];
}

#pragma mark Status and controls

- (void)renderStatusLine {
    NSString *phase = [self phase];
    NSDictionary *table = BRRouletteDict(self.tableState[@"table"]);
    NSInteger totalBet = BRRouletteInt(BRRouletteDict(self.tableState[@"me"])[@"total_bet"]);
    if ([phase isEqualToString:@"idle"]) {
        self.statusLabel.text = NSLocalizedStringWithDefaultValue(@"BRRoulette.Status.Idle", nil, NSBundle.mainBundle, @"Waiting for players…", nil);
    } else if ([phase isEqualToString:@"betting"]) {
        self.statusLabel.text = totalBet > 0
            ? [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Status.InPlayFormat", nil, NSBundle.mainBundle, @"🪙 %@ in play. Add more or wait for the spin.", nil), BRRouletteFormatCoins(totalBet)]
            : NSLocalizedStringWithDefaultValue(@"BRRoulette.Status.Betting", nil, NSBundle.mainBundle, @"Place your bets", nil);
    } else if ([phase isEqualToString:@"spinning"]) {
        self.statusLabel.text = NSLocalizedStringWithDefaultValue(@"BRRoulette.Status.Spinning", nil, NSBundle.mainBundle, @"No more bets! The wheel is spinning…", nil);
    } else if ([phase isEqualToString:@"results"]) {
        NSInteger winning = BRRouletteInt(table[@"winning_number"]);
        NSString *summary = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Result.SummaryFormat", nil, NSBundle.mainBundle, @"%1$ld %2$@", nil), (long)winning, BRRouletteColorName(winning)];
        NSInteger totalPayout = 0;
        for (NSNumber *payout in self.confirmedPayouts.allValues) totalPayout += payout.integerValue;
        if (totalBet <= 0) {
            self.statusLabel.text = summary;
        } else if (totalPayout > totalBet) {
            self.statusLabel.text = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Result.WonFormat", nil, NSBundle.mainBundle, @"%1$@ — you won 🪙 %2$@!", nil), summary, BRRouletteFormatCoins(totalPayout - totalBet)];
        } else if (totalPayout == totalBet) {
            self.statusLabel.text = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Result.PushFormat", nil, NSBundle.mainBundle, @"%@ — you got your bet back.", nil), summary];
        } else {
            self.statusLabel.text = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Result.LostFormat", nil, NSBundle.mainBundle, @"%@ — no luck this spin.", nil), summary];
        }
    }
}

- (void)refreshControls {
    BOOL canBet = [self canBetNow] && !self.actionInFlight;
    NSInteger pending = [self pendingTotal];
    self.placeBetsButton.enabled = canBet && pending > 0;
    self.placeBetsButton.alpha = self.placeBetsButton.enabled ? 1.0 : 0.5;
    [self.placeBetsButton setTitle:pending > 0 ? [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.PlaceBetsAmountFormat", nil, NSBundle.mainBundle, @"Place bets (🪙 %@)", nil), BRRouletteFormatCoins(pending)] : NSLocalizedStringWithDefaultValue(@"BRRoulette.PlaceBets", nil, NSBundle.mainBundle, @"Place bets", nil) forState:UIControlStateNormal];
    self.clearButton.enabled = canBet && (pending > 0 || [self confirmedTotal] > 0);
    self.clearButton.alpha = self.clearButton.enabled ? 1.0 : 0.5;
    self.repeatButton.enabled = canBet && self.previousRoundBets.count > 0 && [self confirmedTotal] == 0;
    self.repeatButton.alpha = self.repeatButton.enabled ? 1.0 : 0.5;
    for (UIButton *button in self.spotButtons.allValues) button.alpha = [self canBetNow] ? 1.0 : 0.85;
}

- (void)leaveTapped {
    if (self.navigationController) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark Timers

- (void)startTimers {
    [self stopTimers];
    if (self.leaving) return;
    [self restartPollTimer];
    __weak typeof(self) weakSelf = self;
    self.countdownTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateCountdown];
    }];
}

- (void)restartPollTimer {
    [self.pollTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:self.pollDelay repeats:YES block:^(NSTimer *timer) {
        [weakSelf pollNow];
    }];
}

- (void)stopTimers {
    [self.pollTimer invalidate]; self.pollTimer = nil;
    [self.countdownTimer invalidate]; self.countdownTimer = nil;
}

- (void)updateCountdown {
    NSString *phase = [self phase];
    NSDate *deadline = [self dateFromServerString:BRRouletteString(BRRouletteDict(self.tableState[@"table"])[@"phase_deadline"])];
    if (!deadline || [phase isEqualToString:@"idle"] || [phase isEqualToString:@"spinning"]) {
        if (self.timerLabel.text.length && ![self.timerLabel.text hasPrefix:@"Connection"]) self.timerLabel.text = @"";
        // The spin ends on the server clock: nudge a poll once it should be over.
        if ([phase isEqualToString:@"spinning"] && deadline && [deadline timeIntervalSinceNow] - self.serverClockOffset < -0.3 && !self.requestInFlight) [self pollNow];
        return;
    }
    // Convert the server deadline into device time using the measured clock offset.
    NSTimeInterval remaining = [deadline timeIntervalSinceNow] - self.serverClockOffset;
    NSInteger seconds = MAX(0, (NSInteger)ceil(remaining));
    NSString *format = [phase isEqualToString:@"betting"] ? NSLocalizedStringWithDefaultValue(@"BRRoulette.Timer.BettingFormat", nil, NSBundle.mainBundle, @"Betting closes in %lds", nil) : NSLocalizedStringWithDefaultValue(@"BRRoulette.Timer.NextRoundFormat", nil, NSBundle.mainBundle, @"Next round in %lds", nil);
    self.timerLabel.text = [NSString stringWithFormat:format, (long)seconds];
    // The server advances lazily on the next poll once the deadline passes; nudge it.
    if (remaining < -0.3 && !self.requestInFlight) [self pollNow];
}

@end
