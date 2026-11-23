// BRBlackjackTableViewController.m
// EZCompleteUI v1.0
//
// Purpose:
//   See BRBlackjackTableViewController.h.
//
//   How it works, for anyone new to this file:
//     - The server owns the game. We send intents (bet, hit, stand, double)
//       and receive a "view" dictionary describing the whole table. The view
//       never contains the shoe or the dealer's hole card.
//     - We poll "state" about every 1.5s, passing the last version we saw.
//       The server answers {unchanged:true} when nothing happened, which keeps
//       idle polling cheap. Every successful response updates the screen.
//     - Timers (betting / turn countdown) are computed locally from the
//       server's phase_deadline, corrected by the clock difference between
//       the server and this device, so a wrong device clock can't mislead.
//     - Actions carry expected_version. If the table moved on (someone else
//       acted, a timer fired) the server rejects the action and sends the
//       current view, and we simply redraw: no stuck buttons.
//     - Card ids 0..51: rank = id % 13 (0 = Ace, 9...12 = 10, J, Q, K),
//       suit = id / 13 (spades, hearts, diamonds, clubs).
//
// Changes from v0 (new file):
//   - Initial version.

#import "BRBlackjackTableViewController.h"
#import "BRBlackjackAPI.h"
#import "BRSlotChatBar.h"
#import "EZEntitlementManager.h"

static const NSTimeInterval kPollInterval = 1.5;
static const NSTimeInterval kMaxPollBackoff = 6.0;
// Space reserved at the bottom of the screen for the collapsed chat bar.
static const CGFloat kChatBarReservedHeight = 60.0;

#pragma mark - Card helpers

static NSString *BRBlackjackRankText(NSInteger cardID) {
    static NSArray<NSString *> *ranks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ranks = @[@"A", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"10", @"J", @"Q", @"K"]; });
    return ranks[(NSUInteger)(cardID % 13)];
}

static NSString *BRBlackjackSuitText(NSInteger cardID) {
    static NSArray<NSString *> *suits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ suits = @[@"♠", @"♥", @"♦", @"♣"]; });
    return suits[(NSUInteger)(cardID / 13) % 4];
}

/// A small white playing card. cardID < 0 draws the face-down hole card.
static UIView *BRBlackjackCardView(NSInteger cardID, CGFloat width) {
    UILabel *card = [UILabel new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.textAlignment = NSTextAlignmentCenter;
    card.numberOfLines = 2;
    card.layer.cornerRadius = 5;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithWhite:0 alpha:.35].CGColor;
    card.clipsToBounds = YES;
    card.font = [UIFont systemFontOfSize:width * 0.42 weight:UIFontWeightHeavy];
    if (cardID < 0) {
        card.backgroundColor = [UIColor colorWithRed:.22 green:.10 blue:.45 alpha:1];
        card.text = @"?";
        card.textColor = [UIColor colorWithWhite:1 alpha:.7];
        card.accessibilityLabel = @"Face-down card";
    } else {
        BOOL red = (cardID / 13) == 1 || (cardID / 13) == 2;
        card.backgroundColor = UIColor.whiteColor;
        card.textColor = red ? [UIColor colorWithRed:.78 green:.08 blue:.12 alpha:1] : UIColor.blackColor;
        card.text = [NSString stringWithFormat:@"%@\n%@", BRBlackjackRankText(cardID), BRBlackjackSuitText(cardID)];
        card.accessibilityLabel = [NSString stringWithFormat:@"%@ of suit %@", BRBlackjackRankText(cardID), BRBlackjackSuitText(cardID)];
    }
    [card.widthAnchor constraintEqualToConstant:width].active = YES;
    [card.heightAnchor constraintEqualToConstant:width * 1.4].active = YES;
    return card;
}

static NSArray *BRBlackjackArray(id value) { return [value isKindOfClass:[NSArray class]] ? value : @[]; }
static NSDictionary *BRBlackjackDict(id value) { return [value isKindOfClass:[NSDictionary class]] ? value : @{}; }
static NSInteger BRBlackjackInt(id value) { return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0; }
static NSString *BRBlackjackString(id value) { return [value isKindOfClass:[NSString class]] ? value : @""; }

#pragma mark - Controller

@interface BRBlackjackTableViewController ()
@property (nonatomic, copy) NSString *tableID;
@property (nonatomic, copy) NSString *tableName;

// Server state
@property (nonatomic, copy) NSDictionary *tableState;       // latest "view" from the server
@property (nonatomic) NSInteger lastVersion;
@property (nonatomic) NSTimeInterval serverClockOffset;     // serverNow - deviceNow, seconds
@property (nonatomic) BOOL hasJoined;
@property (nonatomic) BOOL leaving;

// Networking / timers
@property (nonatomic) BOOL requestInFlight;
@property (nonatomic) BOOL actionInFlight;
@property (nonatomic) NSTimeInterval pollDelay;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTimer *countdownTimer;

// Betting UI state
@property (nonatomic) NSInteger pendingBet;
@property (nonatomic) NSInteger lastSettledRound;

// UI
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *balanceLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) UIStackView *dealerCardsStack;
@property (nonatomic, strong) UILabel *dealerTotalLabel;
@property (nonatomic, strong) UIStackView *seatsStack;
@property (nonatomic, strong) UIView *betPanel;
@property (nonatomic, strong) UILabel *betAmountLabel;
@property (nonatomic, strong) UIStackView *chipStack;
@property (nonatomic, strong) UIButton *betMinusButton;
@property (nonatomic, strong) UIButton *betPlusButton;
@property (nonatomic, strong) UIButton *placeBetButton;
@property (nonatomic, strong) UIStackView *actionPanel;
@property (nonatomic, strong) UIButton *hitButton;
@property (nonatomic, strong) UIButton *standButton;
@property (nonatomic, strong) UIButton *doubleButton;
@property (nonatomic, strong) BRSlotChatBar *chatBar;
@end

@implementation BRBlackjackTableViewController

- (instancetype)initWithTableID:(NSString *)tableID tableName:(NSString *)tableName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _tableID = [tableID copy];
        _tableName = [tableName copy] ?: @"Blackjack";
        _pollDelay = kPollInterval;
        _lastVersion = -1;
        _lastSettledRound = -1;
        _tableState = @{};
    }
    return self;
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:.03 green:.22 blue:.14 alpha:1];
    self.title = self.tableName;
    [self buildInterface];

    // Stop polling in the background; resume (and resync) when active again.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResignActive) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.chatBar) {
        // Room id matches the server's dealer banter ("bj:<table id>").
        self.chatBar = [[BRSlotChatBar alloc] initWithRoomID:[@"bj:" stringByAppendingString:self.tableID]];
        self.chatBar.hostViewController = self;
        [self.chatBar attachToView:self.view];
    }
    [self.chatBar start];
    [self startTimers];
    if (!self.hasJoined) [self joinTable];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // The expanded chat (or any alert) is presented over this screen; the
    // table must keep updating behind it, so only wind down when really leaving.
    if (self.presentedViewController != nil && !self.isMovingFromParentViewController) return;
    [self.chatBar stop];
    [self stopTimers];
    // Popped off the navigation stack (not just covered by a sheet): free the seat.
    if (self.isMovingFromParentViewController || self.isBeingDismissed || self.navigationController == nil) {
        [self leaveTableSilently];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopTimers];
}

- (void)appWillResignActive { [self stopTimers]; }
- (void)appDidBecomeActive {
    if (self.viewIfLoaded.window == nil || self.leaving) return;
    self.lastVersion = -1; // force a full redraw after time away
    [self startTimers];
    [self pollNow];
}

#pragma mark Interface construction

- (UIButton *)pillButtonWithTitle:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1 alpha:.4] forState:UIControlStateDisabled];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    button.backgroundColor = color;
    button.layer.cornerRadius = 12;
    [button.heightAnchor constraintEqualToConstant:46].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UILabel *)labelWithSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    return label;
}

- (void)buildInterface {
    UIColor *gold = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // Header: leave button, table name, balance
    UIButton *leaveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    leaveButton.translatesAutoresizingMaskIntoConstraints = NO;
    [leaveButton setTitle:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Leave", nil, NSBundle.mainBundle, @"Leave", nil) forState:UIControlStateNormal];
    [leaveButton setTitleColor:gold forState:UIControlStateNormal];
    leaveButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [leaveButton addTarget:self action:@selector(leaveTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:leaveButton];

    self.titleLabel = [self labelWithSize:18 weight:UIFontWeightBlack color:UIColor.whiteColor];
    self.titleLabel.text = self.tableName;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.titleLabel];

    self.balanceLabel = [self labelWithSize:15 weight:UIFontWeightBold color:gold];
    self.balanceLabel.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:self.balanceLabel];

    // Status + countdown line
    self.statusLabel = [self labelWithSize:15 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:1 alpha:.9]];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    [self.view addSubview:self.statusLabel];
    self.timerLabel = [self labelWithSize:13 weight:UIFontWeightMedium color:[UIColor colorWithWhite:1 alpha:.65]];
    self.timerLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.timerLabel];

    // Dealer
    UILabel *dealerCaption = [self labelWithSize:12 weight:UIFontWeightBold color:[UIColor colorWithWhite:1 alpha:.6]];
    dealerCaption.text = NSLocalizedStringWithDefaultValue(@"BRBlackjack.Dealer", nil, NSBundle.mainBundle, @"DEALER · LUCKY LOU", nil);
    dealerCaption.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:dealerCaption];
    self.dealerCardsStack = [UIStackView new];
    self.dealerCardsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.dealerCardsStack.spacing = 6;
    self.dealerCardsStack.alignment = UIStackViewAlignmentCenter;
    [self.view addSubview:self.dealerCardsStack];
    self.dealerTotalLabel = [self labelWithSize:14 weight:UIFontWeightBold color:UIColor.whiteColor];
    self.dealerTotalLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.dealerTotalLabel];

    // Seats
    self.seatsStack = [UIStackView new];
    self.seatsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.seatsStack.axis = UILayoutConstraintAxisHorizontal;
    self.seatsStack.distribution = UIStackViewDistributionFillEqually;
    self.seatsStack.spacing = 6;
    self.seatsStack.alignment = UIStackViewAlignmentTop;
    [self.view addSubview:self.seatsStack];

    // Betting panel
    self.betPanel = [UIView new];
    self.betPanel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.betPanel];
    self.chipStack = [UIStackView new];
    self.chipStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.chipStack.distribution = UIStackViewDistributionFillEqually;
    self.chipStack.spacing = 8;
    [self.betPanel addSubview:self.chipStack];
    self.betMinusButton = [self pillButtonWithTitle:@"−" color:[UIColor colorWithWhite:1 alpha:.14] action:@selector(betMinusTapped)];
    self.betPlusButton = [self pillButtonWithTitle:@"+" color:[UIColor colorWithWhite:1 alpha:.14] action:@selector(betPlusTapped)];
    self.betAmountLabel = [self labelWithSize:22 weight:UIFontWeightBlack color:gold];
    self.betAmountLabel.textAlignment = NSTextAlignmentCenter;
    self.placeBetButton = [self pillButtonWithTitle:NSLocalizedStringWithDefaultValue(@"BRBlackjack.PlaceBet", nil, NSBundle.mainBundle, @"Place bet", nil)
                                              color:[UIColor colorWithRed:.12 green:.55 blue:.28 alpha:1] action:@selector(placeBetTapped)];
    [self.betPanel addSubview:self.betMinusButton];
    [self.betPanel addSubview:self.betPlusButton];
    [self.betPanel addSubview:self.betAmountLabel];
    [self.betPanel addSubview:self.placeBetButton];

    // Action panel
    self.hitButton = [self pillButtonWithTitle:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Hit", nil, NSBundle.mainBundle, @"Hit", nil)
                                         color:[UIColor colorWithRed:.12 green:.55 blue:.28 alpha:1] action:@selector(hitTapped)];
    self.standButton = [self pillButtonWithTitle:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Stand", nil, NSBundle.mainBundle, @"Stand", nil)
                                           color:[UIColor colorWithRed:.70 green:.20 blue:.18 alpha:1] action:@selector(standTapped)];
    self.doubleButton = [self pillButtonWithTitle:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Double", nil, NSBundle.mainBundle, @"Double", nil)
                                            color:[UIColor colorWithRed:.55 green:.38 blue:.05 alpha:1] action:@selector(doubleTapped)];
    self.actionPanel = [[UIStackView alloc] initWithArrangedSubviews:@[self.hitButton, self.standButton, self.doubleButton]];
    self.actionPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionPanel.distribution = UIStackViewDistributionFillEqually;
    self.actionPanel.spacing = 10;
    [self.view addSubview:self.actionPanel];

    [NSLayoutConstraint activateConstraints:@[
        [leaveButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [leaveButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.balanceLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.balanceLabel.centerYAnchor constraintEqualToAnchor:leaveButton.centerYAnchor],
        [self.balanceLabel.widthAnchor constraintLessThanOrEqualToConstant:120],
        [self.titleLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:leaveButton.centerYAnchor],
        [self.titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:leaveButton.trailingAnchor constant:8],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.balanceLabel.leadingAnchor constant:-8],

        [self.statusLabel.topAnchor constraintEqualToAnchor:leaveButton.bottomAnchor constant:10],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.timerLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:2],
        [self.timerLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.timerLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [dealerCaption.topAnchor constraintEqualToAnchor:self.timerLabel.bottomAnchor constant:12],
        [dealerCaption.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.dealerCardsStack.topAnchor constraintEqualToAnchor:dealerCaption.bottomAnchor constant:6],
        [self.dealerCardsStack.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.dealerCardsStack.heightAnchor constraintEqualToConstant:70],
        [self.dealerTotalLabel.topAnchor constraintEqualToAnchor:self.dealerCardsStack.bottomAnchor constant:4],
        [self.dealerTotalLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],

        [self.seatsStack.topAnchor constraintEqualToAnchor:self.dealerTotalLabel.bottomAnchor constant:14],
        [self.seatsStack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [self.seatsStack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],

        [self.actionPanel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.actionPanel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.actionPanel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-kChatBarReservedHeight],

        [self.betPanel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.betPanel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.betPanel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-kChatBarReservedHeight],
        [self.betPanel.heightAnchor constraintEqualToConstant:150],
        [self.chipStack.topAnchor constraintEqualToAnchor:self.betPanel.topAnchor],
        [self.chipStack.leadingAnchor constraintEqualToAnchor:self.betPanel.leadingAnchor],
        [self.chipStack.trailingAnchor constraintEqualToAnchor:self.betPanel.trailingAnchor],
        [self.chipStack.heightAnchor constraintEqualToConstant:40],
        [self.betMinusButton.leadingAnchor constraintEqualToAnchor:self.betPanel.leadingAnchor],
        [self.betMinusButton.topAnchor constraintEqualToAnchor:self.chipStack.bottomAnchor constant:10],
        [self.betMinusButton.widthAnchor constraintEqualToConstant:56],
        [self.betPlusButton.trailingAnchor constraintEqualToAnchor:self.betPanel.trailingAnchor],
        [self.betPlusButton.centerYAnchor constraintEqualToAnchor:self.betMinusButton.centerYAnchor],
        [self.betPlusButton.widthAnchor constraintEqualToConstant:56],
        [self.betAmountLabel.centerYAnchor constraintEqualToAnchor:self.betMinusButton.centerYAnchor],
        [self.betAmountLabel.leadingAnchor constraintEqualToAnchor:self.betMinusButton.trailingAnchor constant:8],
        [self.betAmountLabel.trailingAnchor constraintEqualToAnchor:self.betPlusButton.leadingAnchor constant:-8],
        [self.placeBetButton.topAnchor constraintEqualToAnchor:self.betMinusButton.bottomAnchor constant:10],
        [self.placeBetButton.leadingAnchor constraintEqualToAnchor:self.betPanel.leadingAnchor],
        [self.placeBetButton.trailingAnchor constraintEqualToAnchor:self.betPanel.trailingAnchor],
    ]];
    self.betPanel.hidden = YES;
    self.actionPanel.hidden = YES;
}

#pragma mark Networking

- (void)joinTable {
    if (self.requestInFlight) return;
    self.requestInFlight = YES;
    self.statusLabel.text = NSLocalizedStringWithDefaultValue(@"BRBlackjack.Joining", nil, NSBundle.mainBundle, @"Taking a seat…", nil);
    __weak typeof(self) weakSelf = self;
    [BRBlackjackAPI performAction:@"join" params:@{ @"table_id": self.tableID } completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.requestInFlight = NO;
        if (error) {
            // A dead join (table full, hand live elsewhere...) can't be retried
            // meaningfully: tell the player and go back to the lobby.
            if (status >= 400 && status < 500 || status == 409) {
                [self showFatalError:error];
            } else {
                self.statusLabel.text = error;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self joinTable]; });
            }
            return;
        }
        self.hasJoined = YES;
        [self applyResponse:json];
    }];
}

- (void)pollNow {
    if (!self.hasJoined || self.requestInFlight || self.leaving) return;
    self.requestInFlight = YES;
    NSMutableDictionary *params = [@{ @"table_id": self.tableID } mutableCopy];
    if (self.lastVersion >= 0) params[@"since_version"] = @(self.lastVersion);
    __weak typeof(self) weakSelf = self;
    [BRBlackjackAPI performAction:@"state" params:params completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.requestInFlight = NO;
        if (error) {
            // Back off while the connection is bad, then recover on its own.
            self.pollDelay = MIN(self.pollDelay * 1.6, kMaxPollBackoff);
            [self restartPollTimer];
            if (status == 0) self.timerLabel.text = error;
            if (status == 409 && json[@"view"]) [self applyResponse:json];
            return;
        }
        if (self.pollDelay != kPollInterval) { self.pollDelay = kPollInterval; [self restartPollTimer]; }
        if (![json[@"unchanged"] respondsToSelector:@selector(boolValue)] || ![json[@"unchanged"] boolValue]) {
            [self applyResponse:json];
        } else if (json[@"server_now"]) {
            [self updateClockOffsetFromServerNow:json[@"server_now"]];
        }
    }];
}

/// Sends a player action and redraws from the answer. Buttons stay disabled
/// until the answer arrives so a double-tap can't send two actions.
- (void)sendAction:(NSString *)action params:(NSDictionary *)extra {
    if (self.actionInFlight || self.leaving) return;
    self.actionInFlight = YES;
    [self refreshControls];
    NSMutableDictionary *params = [@{ @"table_id": self.tableID } mutableCopy];
    [params addEntriesFromDictionary:extra ?: @{}];
    __weak typeof(self) weakSelf = self;
    [BRBlackjackAPI performAction:action params:params completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.actionInFlight = NO;
        if (json[@"view"]) [self applyResponse:json]; // success, or a race: both carry the current table
        if (error) {
            self.statusLabel.text = error;
            [self refreshControls];
            if (status == 402) { // out of coins: refresh the shown balance from the server
                [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {}];
            }
        }
    }];
}

- (void)leaveTableSilently {
    if (self.leaving || !self.hasJoined) return;
    self.leaving = YES;
    [self stopTimers];
    // Fire and forget: the server refunds a bet placed before the deal and
    // auto-stands (still paying out) a hand already in play.
    [BRBlackjackAPI performAction:@"leave" params:@{ @"table_id": self.tableID } completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {}];
    }];
}

#pragma mark Applying server state

- (void)updateClockOffsetFromServerNow:(id)serverNowValue {
    NSString *text = BRBlackjackString(serverNowValue);
    NSDate *serverDate = [self dateFromServerString:text];
    if (serverDate) self.serverClockOffset = [serverDate timeIntervalSinceNow];
}

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

- (void)applyResponse:(NSDictionary *)json {
    NSDictionary *view = BRBlackjackDict(json[@"view"]);
    if (view.count == 0) return;
    NSInteger version = BRBlackjackInt(BRBlackjackDict(view[@"table"])[@"version"]);
    // Ignore a response older than what's already on screen (out-of-order replies).
    if (version < self.lastVersion) return;
    self.lastVersion = version;
    self.tableState = view;
    [self updateClockOffsetFromServerNow:BRBlackjackDict(view[@"table"])[@"server_now"]];

    NSString *name = BRBlackjackString(BRBlackjackDict(view[@"table"])[@"name"]);
    if (name.length) { self.tableName = name; self.titleLabel.text = name; }

    if (self.pendingBet == 0) [self resetPendingBet];
    [self renderTable];
    [self announceResultIfNeeded];
}

- (NSDictionary *)mySeat {
    for (NSDictionary *seat in BRBlackjackArray(self.tableState[@"seats"])) {
        if ([BRBlackjackDict(seat)[@"is_me"] boolValue]) return seat;
    }
    return nil;
}

- (NSString *)phase { return BRBlackjackString(BRBlackjackDict(self.tableState[@"table"])[@"phase"]); }

#pragma mark Rendering

- (void)clearStack:(UIStackView *)stack {
    for (UIView *subview in [stack.arrangedSubviews copy]) { [stack removeArrangedSubview:subview]; [subview removeFromSuperview]; }
}

- (void)fillCardStack:(UIStackView *)stack cards:(NSArray *)cards hiddenExtra:(BOOL)hidden width:(CGFloat)width overlap:(CGFloat)overlap {
    [self clearStack:stack];
    stack.spacing = -overlap;
    for (id card in cards) [stack addArrangedSubview:BRBlackjackCardView(BRBlackjackInt(card), width)];
    if (hidden) [stack addArrangedSubview:BRBlackjackCardView(-1, width)];
}

- (void)renderTable {
    NSDictionary *tableInfo = BRBlackjackDict(self.tableState[@"table"]);
    NSDictionary *dealer = BRBlackjackDict(self.tableState[@"dealer"]);
    NSNumber *balance = BRBlackjackDict(self.tableState[@"me"])[@"balance"];
    if ([balance isKindOfClass:[NSNumber class]]) {
        self.balanceLabel.text = [NSString stringWithFormat:@"🪙 %@", balance];
    }

    // Dealer
    NSArray *dealerCards = BRBlackjackArray(dealer[@"cards"]);
    [self fillCardStack:self.dealerCardsStack cards:dealerCards hiddenExtra:[dealer[@"hole_hidden"] boolValue] width:44 overlap:8];
    id dealerTotal = dealer[@"total"];
    self.dealerTotalLabel.text = [dealerTotal isKindOfClass:[NSNumber class]] ? [NSString stringWithFormat:@"%@", dealerTotal] : @"";

    // Seats
    [self clearStack:self.seatsStack];
    NSInteger activeSeat = [tableInfo[@"active_seat"] isKindOfClass:[NSNumber class]] ? BRBlackjackInt(tableInfo[@"active_seat"]) : -1;
    for (NSDictionary *seat in BRBlackjackArray(self.tableState[@"seats"])) {
        [self.seatsStack addArrangedSubview:[self viewForSeat:BRBlackjackDict(seat) active:BRBlackjackInt(seat[@"seat_no"]) == activeSeat]];
    }

    [self renderStatusLine];
    [self refreshControls];
}

- (UIView *)viewForSeat:(NSDictionary *)seat active:(BOOL)active {
    BOOL mine = [seat[@"is_me"] boolValue];
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithWhite:0 alpha:.28];
    card.layer.cornerRadius = 10;
    card.layer.borderWidth = (active || mine) ? 2 : 0;
    card.layer.borderColor = (active ? [UIColor colorWithRed:.3 green:.95 blue:.5 alpha:1] : [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1]).CGColor;

    UILabel *name = [self labelWithSize:12 weight:UIFontWeightBold color:mine ? [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1] : UIColor.whiteColor];
    name.text = mine ? NSLocalizedStringWithDefaultValue(@"BRBlackjack.You", nil, NSBundle.mainBundle, @"You", nil) : BRBlackjackString(seat[@"display_name"]);
    name.textAlignment = NSTextAlignmentCenter;

    NSArray *cards = BRBlackjackArray(seat[@"cards"]);
    UIStackView *cardStack = [UIStackView new];
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    cardStack.alignment = UIStackViewAlignmentCenter;
    cardStack.distribution = UIStackViewDistributionFill;
    [self fillCardStack:cardStack cards:cards hiddenExtra:NO width:26 overlap:cards.count > 3 ? 14 : 8];
    UIView *cardHolder = [UIView new];
    cardHolder.translatesAutoresizingMaskIntoConstraints = NO;
    [cardHolder addSubview:cardStack];
    [NSLayoutConstraint activateConstraints:@[
        [cardStack.centerXAnchor constraintEqualToAnchor:cardHolder.centerXAnchor],
        [cardStack.topAnchor constraintEqualToAnchor:cardHolder.topAnchor],
        [cardStack.bottomAnchor constraintEqualToAnchor:cardHolder.bottomAnchor],
        [cardHolder.heightAnchor constraintEqualToConstant:26 * 1.4],
    ]];

    UILabel *total = [self labelWithSize:14 weight:UIFontWeightHeavy color:UIColor.whiteColor];
    total.textAlignment = NSTextAlignmentCenter;
    id totalValue = seat[@"total"];
    if ([totalValue isKindOfClass:[NSNumber class]]) {
        BOOL soft = [seat[@"soft"] boolValue] && BRBlackjackInt(totalValue) < 21;
        total.text = soft ? [NSString stringWithFormat:@"soft %@", totalValue] : [NSString stringWithFormat:@"%@", totalValue];
    }

    UILabel *bet = [self labelWithSize:12 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:1 alpha:.75]];
    bet.textAlignment = NSTextAlignmentCenter;
    NSInteger betAmount = BRBlackjackInt(seat[@"bet"]);
    bet.text = betAmount > 0 ? [NSString stringWithFormat:@"🪙 %ld%@", (long)betAmount, [seat[@"doubled"] boolValue] ? @" ×2" : @""] : @"—";

    UILabel *result = [self labelWithSize:12 weight:UIFontWeightHeavy color:UIColor.whiteColor];
    result.textAlignment = NSTextAlignmentCenter;
    result.text = [self resultTextForSeat:seat];
    NSString *resultKey = BRBlackjackString(seat[@"result"]);
    if ([resultKey isEqualToString:@"win"] || [resultKey isEqualToString:@"blackjack"]) result.textColor = [UIColor colorWithRed:.45 green:1 blue:.55 alpha:1];
    else if ([resultKey isEqualToString:@"lose"] || [resultKey isEqualToString:@"bust"]) result.textColor = [UIColor colorWithRed:1 green:.5 blue:.5 alpha:1];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[name, cardHolder, total, bet, result]];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 4;
    [card addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [column.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8],
        [column.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:4],
        [column.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-4],
    ]];
    card.isAccessibilityElement = YES;
    card.accessibilityLabel = [NSString stringWithFormat:@"%@, total %@, bet %ld", name.text, total.text ?: @"none", (long)betAmount];
    return card;
}

- (NSString *)resultTextForSeat:(NSDictionary *)seat {
    NSString *result = BRBlackjackString(seat[@"result"]);
    NSInteger payout = BRBlackjackInt(seat[@"payout"]);
    NSInteger bet = BRBlackjackInt(seat[@"bet"]);
    if ([result isEqualToString:@"blackjack"]) return [NSString stringWithFormat:@"Blackjack +%ld", (long)(payout - bet)];
    if ([result isEqualToString:@"win"]) return [NSString stringWithFormat:@"Win +%ld", (long)(payout - bet)];
    if ([result isEqualToString:@"push"]) return @"Push";
    if ([result isEqualToString:@"bust"]) return @"Bust";
    if ([result isEqualToString:@"lose"]) return @"Lose";
    NSString *status = BRBlackjackString(seat[@"status"]);
    if ([status isEqualToString:@"stood"]) return @"Stand";
    if ([seat[@"leaving"] boolValue]) return @"Leaving";
    return @"";
}

- (BOOL)isMyTurn {
    NSDictionary *tableInfo = BRBlackjackDict(self.tableState[@"table"]);
    NSDictionary *mine = [self mySeat];
    id active = tableInfo[@"active_seat"];
    return mine && [[self phase] isEqualToString:@"playing"] && [active isKindOfClass:[NSNumber class]]
        && BRBlackjackInt(active) == BRBlackjackInt(mine[@"seat_no"]);
}

- (void)renderStatusLine {
    NSString *phase = [self phase];
    NSDictionary *mine = [self mySeat];
    NSString *text = @"";
    if (!mine) {
        text = NSLocalizedStringWithDefaultValue(@"BRBlackjack.Spectating", nil, NSBundle.mainBundle, @"Watching — a seat will open next round.", nil);
    } else if ([phase isEqualToString:@"idle"]) {
        text = NSLocalizedStringWithDefaultValue(@"BRBlackjack.Idle", nil, NSBundle.mainBundle, @"Place a bet to start a round.", nil);
    } else if ([phase isEqualToString:@"betting"]) {
        text = BRBlackjackInt(mine[@"bet"]) > 0
            ? NSLocalizedStringWithDefaultValue(@"BRBlackjack.BetPlaced", nil, NSBundle.mainBundle, @"Bet placed. Waiting for the deal…", nil)
            : NSLocalizedStringWithDefaultValue(@"BRBlackjack.Betting", nil, NSBundle.mainBundle, @"Place your bet!", nil);
    } else if ([phase isEqualToString:@"playing"]) {
        text = [self isMyTurn]
            ? NSLocalizedStringWithDefaultValue(@"BRBlackjack.YourTurn", nil, NSBundle.mainBundle, @"Your turn", nil)
            : (BRBlackjackInt(mine[@"bet"]) > 0
               ? NSLocalizedStringWithDefaultValue(@"BRBlackjack.WaitTurn", nil, NSBundle.mainBundle, @"Waiting for other players…", nil)
               : NSLocalizedStringWithDefaultValue(@"BRBlackjack.SittingOut", nil, NSBundle.mainBundle, @"Sitting this round out.", nil));
    } else if ([phase isEqualToString:@"results"]) {
        text = [self resultTextForSeat:mine];
        if (text.length == 0) text = NSLocalizedStringWithDefaultValue(@"BRBlackjack.RoundOver", nil, NSBundle.mainBundle, @"Round over.", nil);
    }
    self.statusLabel.text = text;
    [self updateCountdown];
}

- (void)refreshControls {
    NSString *phase = [self phase];
    NSDictionary *mine = [self mySeat];
    NSDictionary *tableInfo = BRBlackjackDict(self.tableState[@"table"]);
    NSInteger balance = BRBlackjackInt(BRBlackjackDict(self.tableState[@"me"])[@"balance"]);
    BOOL canBet = mine && BRBlackjackInt(mine[@"bet"]) == 0 && ([phase isEqualToString:@"idle"] || [phase isEqualToString:@"betting"]) && ![mine[@"leaving"] boolValue];
    BOOL myTurn = [self isMyTurn];

    self.betPanel.hidden = !canBet;
    self.actionPanel.hidden = !myTurn;

    if (canBet) {
        [self rebuildChipsForTable:tableInfo];
        self.betAmountLabel.text = [NSString stringWithFormat:@"🪙 %ld", (long)self.pendingBet];
        BOOL affordable = self.pendingBet <= balance;
        self.placeBetButton.enabled = !self.actionInFlight && affordable && self.pendingBet > 0;
        self.placeBetButton.alpha = self.placeBetButton.enabled ? 1 : 0.5;
        [self.placeBetButton setTitle:affordable ? NSLocalizedStringWithDefaultValue(@"BRBlackjack.PlaceBet", nil, NSBundle.mainBundle, @"Place bet", nil)
                                                 : NSLocalizedStringWithDefaultValue(@"BRBlackjack.NotEnough", nil, NSBundle.mainBundle, @"Not enough coins", nil)
                             forState:UIControlStateNormal];
        self.betMinusButton.enabled = !self.actionInFlight && self.pendingBet > [self minBet];
        self.betPlusButton.enabled = !self.actionInFlight && self.pendingBet < MIN([self maxBet], MAX(balance, [self minBet]));
    }
    if (myTurn) {
        BOOL firstTwo = BRBlackjackArray(mine[@"cards"]).count == 2;
        self.hitButton.enabled = self.standButton.enabled = !self.actionInFlight;
        self.doubleButton.enabled = !self.actionInFlight && firstTwo && balance >= BRBlackjackInt(mine[@"bet"]);
        for (UIButton *button in @[self.hitButton, self.standButton, self.doubleButton]) button.alpha = button.enabled ? 1 : 0.5;
    }
}

#pragma mark Bet helpers

- (NSInteger)minBet { return MAX(1, BRBlackjackInt(BRBlackjackDict(self.tableState[@"table"])[@"min_bet"])); }
- (NSInteger)maxBet { return MAX([self minBet], BRBlackjackInt(BRBlackjackDict(self.tableState[@"table"])[@"max_bet"])); }
- (NSInteger)betStep { return MAX(1, BRBlackjackInt(BRBlackjackDict(self.tableState[@"table"])[@"bet_step"])); }
- (NSInteger)betIncrement { return MAX([self betStep], ([self minBet] / [self betStep]) * [self betStep]); }

/// Snaps an amount into the table's min/max and onto its bet step grid.
- (NSInteger)snappedBet:(NSInteger)amount {
    NSInteger step = [self betStep];
    NSInteger snapped = (amount / step) * step;
    return MAX([self minBet], MIN([self maxBet], snapped));
}

- (void)resetPendingBet {
    NSInteger balance = BRBlackjackInt(BRBlackjackDict(self.tableState[@"me"])[@"balance"]);
    self.pendingBet = [self snappedBet:[self minBet]];
    if (balance > 0 && balance < self.pendingBet) self.pendingBet = [self minBet];
}

- (void)rebuildChipsForTable:(NSDictionary *)tableInfo {
    NSInteger minBet = [self minBet], maxBet = [self maxBet];
    NSMutableOrderedSet<NSNumber *> *values = [NSMutableOrderedSet orderedSet];
    for (NSNumber *fraction in @[@0, @0.1, @0.25, @1]) {
        NSInteger value = fraction.doubleValue == 0 ? minBet : [self snappedBet:(NSInteger)(maxBet * fraction.doubleValue)];
        [values addObject:@(value)];
    }
    NSString *signature = [[values.array valueForKey:@"stringValue"] componentsJoinedByString:@","];
    if ([signature isEqualToString:self.chipStack.accessibilityIdentifier ?: @""]) return;
    self.chipStack.accessibilityIdentifier = signature;
    [self clearStack:self.chipStack];
    for (NSNumber *value in values) {
        UIButton *chip = [self pillButtonWithTitle:[NSString stringWithFormat:@"%@", value] color:[UIColor colorWithRed:.45 green:.12 blue:.55 alpha:1] action:@selector(chipTapped:)];
        chip.tag = value.integerValue;
        chip.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightHeavy];
        [self.chipStack addArrangedSubview:chip];
    }
}

- (void)chipTapped:(UIButton *)chip { self.pendingBet = [self snappedBet:chip.tag]; [self refreshControls]; }
- (void)betMinusTapped { self.pendingBet = [self snappedBet:self.pendingBet - [self betIncrement]]; [self refreshControls]; }
- (void)betPlusTapped { self.pendingBet = [self snappedBet:self.pendingBet + [self betIncrement]]; [self refreshControls]; }

#pragma mark Actions

- (void)placeBetTapped { [self sendAction:@"bet" params:@{ @"amount": @(self.pendingBet) }]; }

- (void)hitTapped { [self sendAction:@"hit" params:@{ @"expected_version": @(self.lastVersion) }]; }
- (void)standTapped { [self sendAction:@"stand" params:@{ @"expected_version": @(self.lastVersion) }]; }
- (void)doubleTapped { [self sendAction:@"double" params:@{ @"expected_version": @(self.lastVersion) }]; }

- (void)leaveTapped {
    NSDictionary *mine = [self mySeat];
    NSString *phase = [self phase];
    BOOL handLive = BRBlackjackInt(mine[@"bet"]) > 0 && [phase isEqualToString:@"playing"];
    void (^leave)(void) = ^{
        [self leaveTableSilently];
        if (self.navigationController && self.navigationController.viewControllers.firstObject != self) [self.navigationController popViewControllerAnimated:YES];
        else [self dismissViewControllerAnimated:YES completion:nil];
    };
    if (!handLive) { leave(); return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedStringWithDefaultValue(@"BRBlackjack.LeaveTitle", nil, NSBundle.mainBundle, @"Leave mid-hand?", nil)
        message:NSLocalizedStringWithDefaultValue(@"BRBlackjack.LeaveMessage", nil, NSBundle.mainBundle, @"Your hand will stand automatically and still be paid out if it wins.", nil)
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Leave", nil, NSBundle.mainBundle, @"Leave", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { leave(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showFatalError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedStringWithDefaultValue(@"BRBlackjack.CantJoin", nil, NSBundle.mainBundle, @"Can't join table", nil)
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self.leaving = YES; // nothing to release server-side
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Results feedback

- (void)announceResultIfNeeded {
    if (![[self phase] isEqualToString:@"results"]) return;
    NSInteger round = BRBlackjackInt(BRBlackjackDict(self.tableState[@"table"])[@"round_no"]);
    if (round == self.lastSettledRound) return;
    self.lastSettledRound = round;
    NSDictionary *mine = [self mySeat];
    NSString *result = BRBlackjackString(mine[@"result"]);
    if (result.length == 0) return;
    UINotificationFeedbackGenerator *haptics = [UINotificationFeedbackGenerator new];
    if ([result isEqualToString:@"win"] || [result isEqualToString:@"blackjack"]) [haptics notificationOccurred:UINotificationFeedbackTypeSuccess];
    else if ([result isEqualToString:@"lose"] || [result isEqualToString:@"bust"]) [haptics notificationOccurred:UINotificationFeedbackTypeError];
    // Keep the shared balance (picker, slots, usage log) in step with the table.
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {}];
    [self resetPendingBet];
}

#pragma mark Timers

- (void)startTimers {
    [self stopTimers];
    if (self.leaving) return;
    [self restartPollTimer];
    self.countdownTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(updateCountdown) userInfo:nil repeats:YES];
}

- (void)restartPollTimer {
    [self.pollTimer invalidate];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:self.pollDelay target:self selector:@selector(pollNow) userInfo:nil repeats:YES];
}

- (void)stopTimers {
    [self.pollTimer invalidate]; self.pollTimer = nil;
    [self.countdownTimer invalidate]; self.countdownTimer = nil;
}

- (void)updateCountdown {
    NSString *phase = [self phase];
    NSString *deadlineText = BRBlackjackString(BRBlackjackDict(self.tableState[@"table"])[@"phase_deadline"]);
    NSDate *deadline = [self dateFromServerString:deadlineText];
    if (!deadline || [phase isEqualToString:@"idle"]) { if (self.timerLabel.text.length && ![self.timerLabel.text hasPrefix:@"Connection"]) self.timerLabel.text = @""; return; }
    // Convert the server deadline into device time using the measured clock offset.
    NSTimeInterval remaining = [deadline timeIntervalSinceNow] - self.serverClockOffset;
    NSInteger seconds = MAX(0, (NSInteger)ceil(remaining));
    NSString *label = [phase isEqualToString:@"betting"] ? @"Betting closes in" : [phase isEqualToString:@"playing"] ? @"Time to act" : @"Next round in";
    self.timerLabel.text = [NSString stringWithFormat:@"%@ %lds", label, (long)seconds];
    // The server advances lazily on the next poll once the deadline passes; nudge it.
    if (remaining < -0.3 && !self.requestInFlight) [self pollNow];
}

@end
