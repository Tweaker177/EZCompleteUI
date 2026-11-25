// BRBlackjackTableViewController.m
// EZCompleteUI v2.1
//
// Purpose:
//   See BRBlackjackTableViewController.h.
//
//   How it works, for anyone new to this file:
//     - The server owns the game. We send intents (bet, hit, stand, double,
//       split) and receive a "view" dictionary describing the whole table. The
//       view never contains the shoe or the dealer's hole card, and it tells us
//       which buttons are legal right now (seat["actions"]), so this screen never
//       has to re-implement blackjack rules.
//     - We poll "state" about every 1.5s, passing the last version and dealer
//       line number we saw. The server answers {unchanged:true} when nothing
//       happened, which keeps idle polling cheap. Every successful response
//       updates the screen.
//     - Timers (betting / turn countdown) are computed locally from the
//       server's phase_deadline, corrected by the clock difference between
//       the server and this device, so a wrong device clock can't mislead.
//     - Actions carry expected_version. If the table moved on (someone else
//       acted, a timer fired) the server rejects the action and sends the
//       current view, and we simply redraw: no stuck buttons.
//     - The dealer also calls the game like a real dealer ("Place your bets",
//       "No more bets", "Dealer shows nine", "Seat three, soft seventeen",
//       "Blackjack", "Bust", "Dealer has eighteen"). The app compares each new
//       table state with the previous one (announceChangesFrom:to:) and chains
//       short pre-rendered clips from a fixed library (action dealer_clips).
//       Because the library is fixed, the voice costs the same however many
//       cards are dealt. Captions show even when the voice is muted.
//     - The whole table scales with the number of players (tableScale). Heads
//       up, cards, seats and the dealer are drawn larger; with a full table
//       they shrink so every seat stays readable, and the seat row scrolls only
//       when even the smallest size doesn't fit. The scale is the smaller of
//       what the width allows (seats side by side) and what the height allows
//       (space between the header and the bet panel). See computeTableScale.
//     - A seat has one hand, or two after a split (seat["hand2"]). The hand
//       currently being played is seat["active_hand"] (0 or 1).
//     - Besides the call-outs, the dealer (Lucky Lou) chats only when a player
//       is clearly talking to him. That line arrives in view["dealer"]["line"] with an mp3 URL; we show it in a speech
//       bubble and play it unless the player muted him.
//     - Payouts: when a round settles with winnings the shown balance is held at
//       its old value, coins fly from the player's seat to the balance, then the
//       number counts up to the real balance.
//     - Card ids 0..51: rank = id % 13 (0 = Ace, 9...12 = 10, J, Q, K),
//       suit = id / 13 (spades, hearts, diamonds, clubs).
//
// Changes from v2.0:
//   - Table zoom: dealer, cards and seat panels scale with the player count and
//     the screen size (tableScale). Dealer cards squeeze together when he has
//     many cards so they never run off the screen. Long hands (6+ cards) overlap more.
//   - Dealer call-outs (BRBlackjackAnnouncer): table calls and every hand total,
//     with captions in the dealer bubble. Seat panels now show their seat number.
//
// Changes from v1.0:
//   - Bigger cards, bigger balance display, and an avatar for the dealer.
//   - Dealer speaks rarely: a speech bubble plus an ElevenLabs voice clip played
//     only when the server publishes a new line (it does so after table chat).
//     Speaker button in the header mutes him. Chat sends ping the server.
//   - Payout animation: coins fly into the balance, which then counts up.
//   - Splitting: Split button, two-hand seat layout, per-hand results.
//   - Kept the repo's NSNull-safe reads (BRBlackjackBool) and the join-retry
//     guard that stops a retry after the player left.
//   - Buttons now follow the server's per-seat "actions" flags; seat result and
//     haptics use total stake (both hands) so doubles and splits are correct.

#import "BRBlackjackTableViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "BRBlackjackAPI.h"
#import "BRSlotChatBar.h"
#import "EZEntitlementManager.h"
#import "EZSupabaseConfig.h"

// Defined in BRSlotChatBar.m: the shared "game sounds" switch.
extern BOOL BRSlotSoundEnabled(void);

static const NSTimeInterval kPollInterval = 1.5;
static const NSTimeInterval kMaxPollBackoff = 6.0;
// Space reserved at the bottom of the screen for the collapsed chat bar.
static const CGFloat kChatBarReservedHeight = 60.0;
// Card and seat sizing. Cards are 1.4x as tall as they are wide.
static const CGFloat kDealerCardWidth = 74.0;
static const CGFloat kSeatCardWidth = 58.0;
static const CGFloat kSplitCardWidth = 42.0;
static const CGFloat kSeatWidth = 172.0;
static const CGFloat kSeatPanelHeight = 240.0;
static const CGFloat kSeatSpacing = 14.0;
static const CGFloat kBetPanelHeight = 150.0;
static const CGFloat kDealerAvatarSize = 68.0;
// Height of everything between the timer line and the seat row at scale 1:
// the dealer card row (74 x 1.4 = 104), total label (22), room for a one-line speech bubble (38), gaps (16).
static const CGFloat kDealerAreaBaseHeight = 180.0;
static const CGFloat kMinTableScale = 0.75;
static const CGFloat kMaxTableScale = 1.8;
static const CGFloat kMaxDealerScale = 1.8;
// Bottom reserve while the action buttons (46pt) are the visible panel,
// instead of the full bet panel: the playing phase gets the difference
// as table room, which is when the cards matter most.
static const CGFloat kActionPanelReserveHeight = 56.0;
// Posted by BRSlotChatBar (object = room id) after a message was sent.
static NSString * const kChatMessageSentNotification = @"BRSlotChatMessageSentNotification";
static NSString * const kDealerVoiceMutedKey = @"BRBlackjackDealerVoiceMuted";

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
    card.layer.cornerRadius = MAX(5, width * 0.09);
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
static BOOL BRBlackjackBool(id value) { return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO; }
static NSString *BRBlackjackString(id value) { return [value isKindOfClass:[NSString class]] ? value : @""; }

#pragma mark - Dealer call-outs

/// Prepares audio for dealer speech. Ambient respects the silent switch and mixes
/// with other audio; an existing playback session (ez-music) is left alone.
static void BRBlackjackActivateAudioSession(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session.category isEqualToString:AVAudioSessionCategoryPlayback] && ![session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        [session setCategory:AVAudioSessionCategoryAmbient error:nil];
    }
    [session setActive:YES error:nil];
}

/// Plays the dealer's call-outs. Each call-out is a short list of clip keys
/// ("seat3", "soft", "n17") played back to back, with a caption shown meanwhile.
/// Clips are downloaded once per session from the library the server renders
/// (see the dealer_clips action). If a clip or the whole library is missing, or
/// the voice is off, the caption alone is shown at a readable pace, so the game
/// never waits on audio.
static const NSUInteger kMaxQueuedCalls = 6;
static const NSInteger kMaxManifestAttempts = 8;

@interface BRBlackjackAnnouncer : NSObject <AVAudioPlayerDelegate>
@property (nonatomic, copy) NSString *tableID;
@property (nonatomic) BOOL voiceEnabled;
@property (nonatomic, copy) void (^captionHandler)(NSString *caption);
@property (nonatomic, copy) void (^speakingHandler)(BOOL speaking);
- (instancetype)initWithTableID:(NSString *)tableID;
- (void)loadClips;
- (NSString *)nameClipKeyForName:(NSString *)name;
- (BOOL)hasNameClipForName:(NSString *)name;
- (void)ensureNameClipForName:(NSString *)name;
- (void)enqueueKeys:(NSArray<NSString *> *)keys caption:(NSString *)caption;
- (void)stop;
@end

@implementation BRBlackjackAnnouncer {
    NSMutableDictionary<NSString *, NSURL *> *_clipURLs;
    NSMutableDictionary<NSString *, NSData *> *_clipData;
    NSMutableSet<NSString *> *_requestedKeys;
    NSMutableArray<NSDictionary *> *_queue;
    NSArray<NSString *> *_currentKeys;
    NSUInteger _currentIndex;
    BOOL _busy;
    BOOL _stopped;
    BOOL _currentHadAudio;
    NSInteger _manifestAttempts;
    AVAudioPlayer *_player;
}

- (instancetype)initWithTableID:(NSString *)tableID {
    self = [super init];
    if (self) {
        _tableID = [tableID copy];
        _clipURLs = [NSMutableDictionary dictionary];
        _clipData = [NSMutableDictionary dictionary];
        _requestedKeys = [NSMutableSet set];
        _queue = [NSMutableArray array];
    }
    return self;
}

/// Fetches the clip manifest and downloads every clip. When the server is still
/// rendering the library the manifest is incomplete, so ask again a few times.
- (void)loadClips {
    if (_stopped) return;
    _manifestAttempts += 1;
    __weak typeof(self) weakSelf = self;
    [BRBlackjackAPI performAction:@"dealer_clips" params:@{ @"table_id": self.tableID } completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self->_stopped) return;
        NSDictionary *clips = BRBlackjackDict(json[@"clips"]);
        NSString *trustedHost = [NSURL URLWithString:EZSupabaseURL].host;
        for (NSString *key in clips) {
            NSURL *url = [NSURL URLWithString:BRBlackjackString(clips[key])];
            if (![url.scheme isEqualToString:@"https"] || ![url.host isEqualToString:trustedHost]) continue;
            self->_clipURLs[key] = url;
            [self downloadClipForKey:key];
        }
        BOOL complete = BRBlackjackBool(json[@"complete"]);
        if (!complete && self->_manifestAttempts < kMaxManifestAttempts) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf loadClips]; });
        }
    }];
}

- (NSString *)nameClipKeyForName:(NSString *)name {
    return [NSString stringWithFormat:@"name:%@", name];
}

- (BOOL)hasNameClipForName:(NSString *)name {
    return name.length > 0 && _clipData[[self nameClipKeyForName:name]] != nil;
}

// Name clips render on the server in this table's dealer's voice,
// once per name; the answer is a storage URL like any other clip.
- (void)ensureNameClipForName:(NSString *)name {
    if (name.length == 0 || _stopped) return;
    NSString *key = [self nameClipKeyForName:name];
    if (_clipData[key] != nil || [_requestedKeys containsObject:key]) return;
    [_requestedKeys addObject:key];
    __weak typeof(self) weakSelf = self;
    [BRBlackjackAPI performAction:@"dealer_name_clip" params:@{ @"table_id": self.tableID, @"name": name } completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self->_stopped) return;
        NSURL *url = [NSURL URLWithString:BRBlackjackString(json[@"url"])];
        NSString *trustedHost = [NSURL URLWithString:EZSupabaseURL].host;
        if (![url.scheme isEqualToString:@"https"] || ![url.host isEqualToString:trustedHost]) {
            [self->_requestedKeys removeObject:key]; // not seated / not rendered: allow a later retry
            return;
        }
        self->_clipURLs[key] = url;
        [self->_requestedKeys removeObject:key];
        [self downloadClipForKey:key];
    }];
}

- (void)downloadClipForKey:(NSString *)key {
    if (_clipData[key] != nil || [_requestedKeys containsObject:key]) return;
    [_requestedKeys addObject:key];
    NSURL *url = _clipURLs[key];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL usable = data.length > 0 && !error && [(NSHTTPURLResponse *)response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode == 200;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (usable) self->_clipData[key] = data;
            else [self->_requestedKeys removeObject:key]; // allow a retry on the next manifest pass
        });
    }] resume];
}

- (void)enqueueKeys:(NSArray<NSString *> *)keys caption:(NSString *)caption {
    if (_stopped || keys.count == 0) return;
    // After time away or a burst of play, drop the oldest calls instead of
    // talking about hands that are long gone.
    while (_queue.count >= kMaxQueuedCalls) [_queue removeObjectAtIndex:0];
    [_queue addObject:@{ @"keys": keys, @"caption": caption ?: @"" }];
    if (!_busy) [self playNextCall];
}

- (void)playNextCall {
    if (_stopped || _queue.count == 0) {
        _busy = NO;
        if (self.speakingHandler) self.speakingHandler(NO);
        return;
    }
    _busy = YES;
    NSDictionary *call = _queue.firstObject;
    [_queue removeObjectAtIndex:0];
    _currentKeys = call[@"keys"];
    _currentIndex = 0;
    _currentHadAudio = NO;
    if (self.captionHandler) self.captionHandler(call[@"caption"]);
    [self playCurrentKey];
}

- (void)playCurrentKey {
    if (_stopped) return;
    if (_currentIndex >= _currentKeys.count) {
        // A short breath after spoken calls; silent calls stay up long enough to read.
        if (self.speakingHandler) self.speakingHandler(NO);
        NSTimeInterval pause = _currentHadAudio ? 0.3 : 1.3;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pause * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf playNextCall]; });
        return;
    }
    NSData *data = self.voiceEnabled ? _clipData[_currentKeys[_currentIndex]] : nil;
    AVAudioPlayer *player = data ? [[AVAudioPlayer alloc] initWithData:data error:nil] : nil;
    if (!player) { // no clip for this word: skip it
        _currentIndex += 1;
        [self playCurrentKey];
        return;
    }
    BRBlackjackActivateAudioSession();
    player.delegate = self;
    [player prepareToPlay];
    [player play];
    _player = player;
    if (!_currentHadAudio && self.speakingHandler) self.speakingHandler(YES);
    _currentHadAudio = YES;
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player != _player) return;
    _currentIndex += 1;
    [self playCurrentKey];
}

- (void)stop {
    _stopped = YES;
    [_queue removeAllObjects];
    [_player stop];
    _player = nil;
    _busy = NO;
}

@end

#pragma mark - Controller

@interface BRBlackjackTableViewController () <AVAudioPlayerDelegate>
@property (nonatomic, copy) NSString *tableID;
@property (nonatomic, copy) NSString *tableName;

// Server state
@property (nonatomic, copy) NSDictionary *tableState;       // latest "view" from the server
@property (nonatomic) NSInteger lastVersion;
@property (nonatomic) NSInteger lastLineSeq;                // newest dealer line already shown (-1 = none seen yet)
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

// Balance display and payout animation
@property (nonatomic) NSInteger displayedBalance;           // what the pill shows right now
@property (nonatomic) NSInteger pendingBalance;             // real balance while the display is held
@property (nonatomic) BOOL holdingBalanceForPayout;
@property (nonatomic) BOOL hasShownBalance;
@property (nonatomic, strong) NSTimer *balanceTimer;
@property (nonatomic) NSInteger countFrom;
@property (nonatomic) NSInteger countTo;
@property (nonatomic) NSTimeInterval countStart;

// Dealer voice
@property (nonatomic, strong) AVAudioPlayer *dealerAudioPlayer;
@property (nonatomic) BOOL dealerVoiceMuted;
@property (nonatomic) NSInteger bubbleToken;
@property (nonatomic) NSTimeInterval lastChatPingTime;

// UI
@property (nonatomic, strong) UIView *balancePill;
@property (nonatomic, strong) UILabel *balanceLabel;
@property (nonatomic, strong) UIButton *voiceButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) UIView *dealerAvatarView;
@property (nonatomic, strong) UILabel *dealerAvatarFace;
@property (nonatomic, strong) UILabel *dealerNameLabel;
@property (nonatomic, strong) NSLayoutConstraint *dealerAvatarWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *dealerAvatarHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *dealerCardsHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *seatsHeightConstraint;
@property (nonatomic) CGFloat tableScale;                   // 1.0 = original size; see computeTableScale
@property (nonatomic, strong) UIView *dealerBubble;
@property (nonatomic, strong) UILabel *dealerBubbleLabel;
@property (nonatomic, strong) UIStackView *dealerCardsStack;
@property (nonatomic, strong) UILabel *dealerTotalLabel;
@property (nonatomic, strong) UIScrollView *seatsScroll;
@property (nonatomic, strong) UIStackView *seatsStack;
@property (nonatomic, weak) UIView *mySeatView;             // payout chips start here
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
@property (nonatomic, strong) UIButton *splitButton;
@property (nonatomic, strong) BRSlotChatBar *chatBar;
@property (nonatomic, strong) BRBlackjackAnnouncer *announcer;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *stiffHitSeats; // seats that hit on 12-20 this round (for the well-played calls)
@property (nonatomic) BOOL skipNextAnnouncements;           // set after time away so old events aren't replayed
@end

@implementation BRBlackjackTableViewController

- (instancetype)initWithTableID:(NSString *)tableID tableName:(NSString *)tableName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _tableID = [tableID copy];
        _tableName = [tableName copy] ?: @"Blackjack";
        _pollDelay = kPollInterval;
        _lastVersion = -1;
        _lastLineSeq = -1;
        _lastSettledRound = -1;
        _tableState = @{};
        _dealerVoiceMuted = [[NSUserDefaults standardUserDefaults] boolForKey:kDealerVoiceMutedKey];
    }
    return self;
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableScale = 1.0;
    self.view.backgroundColor = [UIColor colorWithRed:.03 green:.22 blue:.14 alpha:1];
    self.title = self.tableName;
    [self buildInterface];
    [self buildAnnouncer];

    // Stop polling in the background; resume (and resync) when active again.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResignActive) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    // The chat bar announces each sent message so the dealer can consider replying.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(chatMessageSent:) name:kChatMessageSentNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.chatBar) {
        // Room id matches the server's dealer chat ("bj:<table id>").
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
    [self stopDealerAudio];
    [self.announcer stop];
    // Popped off the navigation stack (not just covered by a sheet): free the seat.
    if (self.isMovingFromParentViewController || self.isBeingDismissed || self.navigationController == nil) {
        [self leaveTableSilently];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopTimers];
    [self.balanceTimer invalidate];
    [self.dealerAudioPlayer stop];
}

- (void)appWillResignActive { [self stopTimers]; [self stopDealerAudio]; }

- (void)appDidBecomeActive {
    if (self.viewIfLoaded.window == nil || self.leaving) return;
    self.lastVersion = -1; // force a full redraw after time away
    self.skipNextAnnouncements = YES; // don't narrate everything that happened meanwhile
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

    // Header row: leave button and the dealer-voice toggle flank the
    // balance pill. The table name lives only in the navigation bar —
    // an in-view copy of it used to sit on its own row here, and the
    // board gets that space back.
    UIButton *leaveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    leaveButton.translatesAutoresizingMaskIntoConstraints = NO;
    [leaveButton setTitle:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Leave", nil, NSBundle.mainBundle, @"Leave", nil) forState:UIControlStateNormal];
    [leaveButton setTitleColor:gold forState:UIControlStateNormal];
    leaveButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [leaveButton addTarget:self action:@selector(leaveTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:leaveButton];

    self.voiceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.voiceButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.voiceButton.titleLabel.font = [UIFont systemFontOfSize:22];
    [self.voiceButton addTarget:self action:@selector(toggleDealerVoice) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.voiceButton];
    [self updateVoiceButton];

    // Balance: large pill on the header row. Payout chips fly into it.
    self.balancePill = [UIView new];
    self.balancePill.translatesAutoresizingMaskIntoConstraints = NO;
    self.balancePill.backgroundColor = [gold colorWithAlphaComponent:.16];
    self.balancePill.layer.cornerRadius = 24;
    self.balancePill.layer.borderWidth = 2;
    self.balancePill.layer.borderColor = gold.CGColor;
    [self.view addSubview:self.balancePill];
    self.balanceLabel = [self labelWithSize:30 weight:UIFontWeightBlack color:gold];
    self.balanceLabel.textAlignment = NSTextAlignmentCenter;
    self.balanceLabel.minimumScaleFactor = 0.6;
    [self.balancePill addSubview:self.balanceLabel];
    self.balancePill.isAccessibilityElement = YES;
    self.balancePill.accessibilityLabel = @"Coin balance";

    // Status + countdown
    self.statusLabel = [self labelWithSize:16 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:1 alpha:.92]];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    [self.view addSubview:self.statusLabel];
    self.timerLabel = [self labelWithSize:13 weight:UIFontWeightMedium color:[UIColor colorWithWhite:1 alpha:.65]];
    self.timerLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.timerLabel];

    // Dealer: avatar + name on the left, cards beside him
    self.dealerAvatarView = [UIView new];
    self.dealerAvatarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.dealerAvatarView.backgroundColor = [UIColor colorWithRed:.12 green:.07 blue:.25 alpha:1];
    self.dealerAvatarView.layer.cornerRadius = 34;
    self.dealerAvatarView.layer.borderWidth = 3;
    self.dealerAvatarView.layer.borderColor = gold.CGColor;
    UILabel *avatarFace = [UILabel new];
    avatarFace.translatesAutoresizingMaskIntoConstraints = NO;
    avatarFace.text = @"🤵";
    avatarFace.font = [UIFont systemFontOfSize:38];
    self.dealerAvatarFace = avatarFace;
    [self.dealerAvatarView addSubview:avatarFace];
    [NSLayoutConstraint activateConstraints:@[
        [avatarFace.centerXAnchor constraintEqualToAnchor:self.dealerAvatarView.centerXAnchor],
        [avatarFace.centerYAnchor constraintEqualToAnchor:self.dealerAvatarView.centerYAnchor],
    ]];
    self.dealerAvatarWidthConstraint = [self.dealerAvatarView.widthAnchor constraintEqualToConstant:kDealerAvatarSize];
    self.dealerAvatarHeightConstraint = [self.dealerAvatarView.heightAnchor constraintEqualToConstant:kDealerAvatarSize];
    [NSLayoutConstraint activateConstraints:@[self.dealerAvatarWidthConstraint, self.dealerAvatarHeightConstraint]];
    self.dealerAvatarView.isAccessibilityElement = YES;
    self.dealerAvatarView.accessibilityLabel = @"Dealer, Lucky Lou";
    UILabel *dealerName = [self labelWithSize:12 weight:UIFontWeightBold color:[UIColor colorWithWhite:1 alpha:.85]];
    self.dealerNameLabel = dealerName;
    dealerName.text = @"Lucky Lou";
    dealerName.textAlignment = NSTextAlignmentCenter;
    UIStackView *avatarColumn = [[UIStackView alloc] initWithArrangedSubviews:@[self.dealerAvatarView, dealerName]];
    avatarColumn.axis = UILayoutConstraintAxisVertical;
    avatarColumn.alignment = UIStackViewAlignmentCenter;
    avatarColumn.spacing = 4;

    self.dealerCardsStack = [UIStackView new];
    self.dealerCardsStack.alignment = UIStackViewAlignmentCenter;
    self.dealerCardsHeightConstraint = [self.dealerCardsStack.heightAnchor constraintEqualToConstant:kDealerCardWidth * 1.4];
    self.dealerCardsHeightConstraint.active = YES;
    UIStackView *dealerRow = [[UIStackView alloc] initWithArrangedSubviews:@[avatarColumn, self.dealerCardsStack]];
    dealerRow.translatesAutoresizingMaskIntoConstraints = NO;
    dealerRow.spacing = 16;
    dealerRow.alignment = UIStackViewAlignmentCenter;
    [self.view addSubview:dealerRow];

    self.dealerTotalLabel = [self labelWithSize:18 weight:UIFontWeightHeavy color:UIColor.whiteColor];
    self.dealerTotalLabel.textAlignment = NSTextAlignmentCenter;
    self.dealerBubble = [UIView new];
    self.dealerBubble.backgroundColor = [UIColor colorWithWhite:1 alpha:.96];
    self.dealerBubble.layer.cornerRadius = 14;
    self.dealerBubble.hidden = YES;
    self.dealerBubbleLabel = [UILabel new];
    self.dealerBubbleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.dealerBubbleLabel.numberOfLines = 3;
    self.dealerBubbleLabel.textAlignment = NSTextAlignmentCenter;
    self.dealerBubbleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.dealerBubbleLabel.textColor = [UIColor colorWithWhite:.1 alpha:1];
    [self.dealerBubble addSubview:self.dealerBubbleLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.dealerBubbleLabel.topAnchor constraintEqualToAnchor:self.dealerBubble.topAnchor constant:8],
        [self.dealerBubbleLabel.bottomAnchor constraintEqualToAnchor:self.dealerBubble.bottomAnchor constant:-8],
        [self.dealerBubbleLabel.leadingAnchor constraintEqualToAnchor:self.dealerBubble.leadingAnchor constant:14],
        [self.dealerBubbleLabel.trailingAnchor constraintEqualToAnchor:self.dealerBubble.trailingAnchor constant:-14],
    ]];
    UIStackView *dealerInfo = [[UIStackView alloc] initWithArrangedSubviews:@[self.dealerTotalLabel, self.dealerBubble]];
    dealerInfo.translatesAutoresizingMaskIntoConstraints = NO;
    dealerInfo.axis = UILayoutConstraintAxisVertical;
    dealerInfo.alignment = UIStackViewAlignmentCenter;
    dealerInfo.spacing = 4;
    [self.view addSubview:dealerInfo];

    // Seats: a horizontally scrolling row so cards can be large even with 5 players
    self.seatsScroll = [UIScrollView new];
    self.seatsScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.seatsScroll.showsHorizontalScrollIndicator = NO;
    self.seatsScroll.alwaysBounceHorizontal = NO;
    [self.view addSubview:self.seatsScroll];
    self.seatsHeightConstraint = [self.seatsScroll.heightAnchor constraintEqualToConstant:kSeatPanelHeight];
    self.seatsHeightConstraint.active = YES;
    self.seatsStack = [UIStackView new];
    self.seatsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.seatsStack.axis = UILayoutConstraintAxisHorizontal;
    self.seatsStack.spacing = kSeatSpacing;
    self.seatsStack.alignment = UIStackViewAlignmentTop;
    [self.seatsScroll addSubview:self.seatsStack];

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
    self.betAmountLabel = [self labelWithSize:24 weight:UIFontWeightBlack color:gold];
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
    self.splitButton = [self pillButtonWithTitle:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Split", nil, NSBundle.mainBundle, @"Split", nil)
                                           color:[UIColor colorWithRed:.35 green:.22 blue:.60 alpha:1] action:@selector(splitTapped)];
    self.splitButton.hidden = YES;
    self.actionPanel = [[UIStackView alloc] initWithArrangedSubviews:@[self.hitButton, self.standButton, self.doubleButton, self.splitButton]];
    self.actionPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionPanel.distribution = UIStackViewDistributionFillEqually;
    self.actionPanel.spacing = 8;
    [self.view addSubview:self.actionPanel];

    [NSLayoutConstraint activateConstraints:@[
        [leaveButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [leaveButton.centerYAnchor constraintEqualToAnchor:self.balancePill.centerYAnchor],
        [self.voiceButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.voiceButton.centerYAnchor constraintEqualToAnchor:self.balancePill.centerYAnchor],

        [self.balancePill.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.balancePill.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.balancePill.heightAnchor constraintEqualToConstant:48],
        [self.balancePill.widthAnchor constraintGreaterThanOrEqualToConstant:170],
        [self.balanceLabel.topAnchor constraintEqualToAnchor:self.balancePill.topAnchor constant:4],
        [self.balanceLabel.bottomAnchor constraintEqualToAnchor:self.balancePill.bottomAnchor constant:-4],
        [self.balanceLabel.leadingAnchor constraintEqualToAnchor:self.balancePill.leadingAnchor constant:22],
        [self.balanceLabel.trailingAnchor constraintEqualToAnchor:self.balancePill.trailingAnchor constant:-22],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.balancePill.bottomAnchor constant:8],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.timerLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:2],
        [self.timerLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.timerLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [dealerRow.topAnchor constraintEqualToAnchor:self.timerLabel.bottomAnchor constant:16],
        [dealerRow.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [dealerInfo.topAnchor constraintEqualToAnchor:dealerRow.bottomAnchor constant:8],
        [dealerInfo.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [dealerInfo.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [dealerInfo.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],

        [self.seatsScroll.topAnchor constraintEqualToAnchor:dealerInfo.bottomAnchor constant:16],
        [self.seatsScroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [self.seatsScroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [self.seatsStack.topAnchor constraintEqualToAnchor:self.seatsScroll.contentLayoutGuide.topAnchor],
        [self.seatsStack.bottomAnchor constraintEqualToAnchor:self.seatsScroll.contentLayoutGuide.bottomAnchor],
        [self.seatsStack.leadingAnchor constraintEqualToAnchor:self.seatsScroll.contentLayoutGuide.leadingAnchor],
        [self.seatsStack.trailingAnchor constraintEqualToAnchor:self.seatsScroll.contentLayoutGuide.trailingAnchor],
        [self.seatsStack.heightAnchor constraintEqualToAnchor:self.seatsScroll.frameLayoutGuide.heightAnchor],
        [self.seatsStack.widthAnchor constraintGreaterThanOrEqualToAnchor:self.seatsScroll.frameLayoutGuide.widthAnchor],

        [self.actionPanel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.actionPanel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.actionPanel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-kChatBarReservedHeight],

        [self.betPanel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.betPanel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.betPanel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-kChatBarReservedHeight],
        [self.betPanel.heightAnchor constraintEqualToConstant:kBetPanelHeight],
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
    [self setDisplayedBalance:0];
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
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    // The player may have left while the retry was pending:
                    // rejoining then would take a seat nobody ever leaves.
                    if (self.viewIfLoaded.window == nil) return;
                    [self joinTable];
                });
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
    if (self.lastLineSeq >= 0) params[@"since_line_seq"] = @(self.lastLineSeq);
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
        if (![json[@"unchanged"] respondsToSelector:@selector(boolValue)] || !BRBlackjackBool(json[@"unchanged"])) {
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
    NSDictionary *previousView = self.tableState;
    self.tableState = view;
    [self handleDealerLineInView:view];
    [self updateClockOffsetFromServerNow:BRBlackjackDict(view[@"table"])[@"server_now"]];

    NSString *name = BRBlackjackString(BRBlackjackDict(view[@"table"])[@"name"]);
    if (name.length) { self.tableName = name; self.title = name; }

    // Who's dealing this table (server-sent): name + avatar emoji.
    // Older servers send no host block and the defaults stay.
    NSDictionary *host = BRBlackjackDict(view[@"host"]);
    NSString *hostName = BRBlackjackString(host[@"name"]);
    if (hostName.length) {
        self.dealerNameLabel.text = hostName;
        self.dealerAvatarView.accessibilityLabel = [NSString stringWithFormat:@"Dealer, %@", hostName];
    }
    NSString *hostEmoji = BRBlackjackString(host[@"emoji"]);
    if (hostEmoji.length) self.dealerAvatarFace.text = hostEmoji;

    // Play-by-play narration speaks names: make sure every seated
    // player's name clip is on its way (rendered once, server-side).
    for (NSDictionary *rawSeat in BRBlackjackArray(view[@"seats"])) {
        NSString *seatedName = BRBlackjackString(BRBlackjackDict(rawSeat)[@"display_name"]);
        if (seatedName.length) [self.announcer ensureNameClipForName:seatedName];
    }

    if (self.pendingBet == 0) [self resetPendingBet];
    [self renderTable];
    [self announceChangesFrom:previousView to:view];
    [self announceResultIfNeeded];
}

/// Shows a dealer line the first time its sequence number is seen. The first
/// response after joining only records the current number, so a line spoken
/// before this player sat down is never replayed.
- (void)handleDealerLineInView:(NSDictionary *)view {
    NSDictionary *dealer = BRBlackjackDict(view[@"dealer"]);
    id sequenceValue = dealer[@"line_seq"];
    if (![sequenceValue isKindOfClass:[NSNumber class]]) return;
    NSInteger sequence = [sequenceValue integerValue];
    if (self.lastLineSeq >= 0 && sequence > self.lastLineSeq) {
        [self dealerSaysLine:BRBlackjackString(dealer[@"line"]) audioURLString:BRBlackjackString(dealer[@"audio_url"])];
    }
    self.lastLineSeq = MAX(self.lastLineSeq, sequence);
}

- (NSDictionary *)mySeat {
    for (NSDictionary *seat in BRBlackjackArray(self.tableState[@"seats"])) {
        if (BRBlackjackBool(BRBlackjackDict(seat)[@"is_me"])) return seat;
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
    NSString *phase = [self phase];
    NSDictionary *mine = [self mySeat];

    // Balance. At the moment a round settles with a payout, hold the old number
    // so the chips can fly in and the count-up can play (see announceResultIfNeeded).
    NSNumber *balance = BRBlackjackDict(self.tableState[@"me"])[@"balance"];
    if ([balance isKindOfClass:[NSNumber class]]) {
        NSInteger newBalance = balance.integerValue;
        NSInteger round = BRBlackjackInt(tableInfo[@"round_no"]);
        BOOL settlingWithPayout = [phase isEqualToString:@"results"] && round != self.lastSettledRound && BRBlackjackInt(mine[@"payout"]) > 0 && self.hasShownBalance;
        if (settlingWithPayout) {
            self.pendingBalance = newBalance;
            self.holdingBalanceForPayout = YES;
        } else if (!self.holdingBalanceForPayout) {
            [self.balanceTimer invalidate];
            [self setDisplayedBalance:newBalance];
        } else {
            self.pendingBalance = newBalance;
        }
        self.hasShownBalance = YES;
    }

    [self refreshTableScale];
    [self renderTableCards];
    [self renderStatusLine];
    [self refreshControls];
}

#pragma mark Table zoom

/// Scale shared by the dealer, cards and seat panels. 1.0 is the original size.
/// It is the smaller of two limits: how wide each seat can be if every player sits
/// side by side, and how much vertical room is left between the header and the
/// bet panel. Never below kMinTableScale (the seat row scrolls instead).
/// Rounded to 5% steps so tiny layout changes don't cause constant redraws.
- (CGFloat)computeTableScale {
    CGRect safeFrame = self.view.safeAreaLayoutGuide.layoutFrame;
    if (safeFrame.size.width <= 0 || CGRectGetMaxY(self.timerLabel.frame) <= 0) return self.tableScale;
    NSInteger seatCount = MAX(1, (NSInteger)BRBlackjackArray(self.tableState[@"seats"]).count);
    CGFloat rowWidth = safeFrame.size.width - 16;
    CGFloat widthScale = (rowWidth - kSeatSpacing * (seatCount - 1)) / seatCount / kSeatWidth;
    CGFloat top = CGRectGetMaxY(self.timerLabel.frame) + 16;
    // Reserve only what the visible bottom panel actually occupies: the
    // bet panel is tall, the action row is short, and during results
    // neither is up. Reserving the bet panel's height in every phase
    // shrank the cards for the whole round.
    CGFloat panelReserve = (self.betPanel && !self.betPanel.hidden) ? kBetPanelHeight
        : (self.actionPanel && !self.actionPanel.hidden) ? kActionPanelReserveHeight : 10;
    CGFloat bottom = CGRectGetMaxY(safeFrame) - kChatBarReservedHeight - panelReserve - 10;
    CGFloat heightScale = (bottom - top) / (kDealerAreaBaseHeight + kSeatPanelHeight);
    CGFloat scale = MIN(widthScale, heightScale);
    scale = MAX(kMinTableScale, MIN(kMaxTableScale, scale));
    return floor(scale * 20.0) / 20.0;
}

/// The dealer grows a little less than the seats so his cards and avatar still fit across the screen.
- (CGFloat)dealerScale {
    return MIN(self.tableScale, kMaxDealerScale);
}

/// Recomputes the scale and resizes the fixed-size parts (avatar, dealer card row,
/// seat row height). Returns YES when the scale changed, so callers redraw cards and seats.
- (BOOL)refreshTableScale {
    CGFloat scale = [self computeTableScale];
    if (fabs(scale - self.tableScale) < 0.001) return NO;
    self.tableScale = scale;
    CGFloat dealerScale = [self dealerScale];
    CGFloat avatarSize = kDealerAvatarSize * dealerScale;
    self.dealerAvatarWidthConstraint.constant = avatarSize;
    self.dealerAvatarHeightConstraint.constant = avatarSize;
    self.dealerAvatarView.layer.cornerRadius = avatarSize / 2;
    self.dealerAvatarFace.font = [UIFont systemFontOfSize:38 * dealerScale];
    self.dealerNameLabel.font = [UIFont systemFontOfSize:12 * MIN(dealerScale, 1.3) weight:UIFontWeightBold];
    self.dealerTotalLabel.font = [UIFont systemFontOfSize:18 * dealerScale weight:UIFontWeightHeavy];
    self.dealerCardsHeightConstraint.constant = kDealerCardWidth * dealerScale * 1.4;
    self.seatsHeightConstraint.constant = kSeatPanelHeight * scale;
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Rotation, split-screen or a new player count can change the right size.
    if ([self refreshTableScale] && self.tableState.count > 0) [self renderTableCards];
}

/// Draws the dealer's hand and every seat at the current scale.
- (void)renderTableCards {
    NSDictionary *tableInfo = BRBlackjackDict(self.tableState[@"table"]);
    NSDictionary *dealer = BRBlackjackDict(self.tableState[@"dealer"]);
    CGFloat dealerScale = [self dealerScale];

    // Dealer. With many cards the overlap grows so the hand never runs off screen.
    NSArray *dealerCards = BRBlackjackArray(dealer[@"cards"]);
    BOOL holeHidden = BRBlackjackBool(dealer[@"hole_hidden"]);
    CGFloat dealerCardWidth = kDealerCardWidth * dealerScale;
    CGFloat overlap = 12 * dealerScale;
    NSInteger shownCards = (NSInteger)dealerCards.count + (holeHidden ? 1 : 0);
    CGFloat roomForCards = self.view.safeAreaLayoutGuide.layoutFrame.size.width - 16 - kDealerAvatarSize * dealerScale - 16;
    if (shownCards > 1 && roomForCards > dealerCardWidth) {
        CGFloat fittingStep = (roomForCards - dealerCardWidth) / (shownCards - 1);
        overlap = MIN(dealerCardWidth * 0.75, MAX(overlap, dealerCardWidth - fittingStep));
    }
    [self fillCardStack:self.dealerCardsStack cards:dealerCards hiddenExtra:holeHidden width:dealerCardWidth overlap:overlap];
    id dealerTotal = dealer[@"total"];
    self.dealerTotalLabel.text = [dealerTotal isKindOfClass:[NSNumber class]] ? [NSString stringWithFormat:@"%@", dealerTotal] : @"";

    // Seats, centered when they fit and scrollable when they don't
    [self clearStack:self.seatsStack];
    self.mySeatView = nil;
    NSInteger activeSeat = [tableInfo[@"active_seat"] isKindOfClass:[NSNumber class]] ? BRBlackjackInt(tableInfo[@"active_seat"]) : -1;
    UIView *leadingSpacer = [UIView new];
    UIView *trailingSpacer = [UIView new];
    [self.seatsStack addArrangedSubview:leadingSpacer];
    for (NSDictionary *seat in BRBlackjackArray(self.tableState[@"seats"])) {
        [self.seatsStack addArrangedSubview:[self viewForSeat:BRBlackjackDict(seat) active:BRBlackjackInt(seat[@"seat_no"]) == activeSeat]];
    }
    [self.seatsStack addArrangedSubview:trailingSpacer];
    [leadingSpacer.widthAnchor constraintEqualToAnchor:trailingSpacer.widthAnchor].active = YES;
}

/// Seat total stake: both hands after a split, otherwise the single bet.
- (NSInteger)totalBetForSeat:(NSDictionary *)seat {
    id total = seat[@"total_bet"];
    return [total isKindOfClass:[NSNumber class]] ? [total integerValue] : BRBlackjackInt(seat[@"bet"]);
}

- (NSString *)shortResultWord:(NSString *)result {
    if ([result isEqualToString:@"blackjack"]) return @"Blackjack";
    if ([result isEqualToString:@"win"]) return @"Win";
    if ([result isEqualToString:@"push"]) return @"Push";
    if ([result isEqualToString:@"bust"]) return @"Bust";
    if ([result isEqualToString:@"lose"]) return @"Lose";
    return @"";
}

/// One hand: its cards and a summary line (total, stake, result). Works for a
/// seat dictionary (first hand) and for seat["hand2"] because they share key names.
- (UIView *)handBlockForHand:(NSDictionary *)hand cardWidth:(CGFloat)cardWidth marker:(BOOL)marker showResult:(BOOL)showResult {
    NSArray *cards = BRBlackjackArray(hand[@"cards"]);
    UIStackView *cardStack = [UIStackView new];
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    cardStack.alignment = UIStackViewAlignmentCenter;
    [self fillCardStack:cardStack cards:cards hiddenExtra:NO width:cardWidth overlap:cards.count > 5 ? cardWidth * 0.65 : (cards.count > 3 ? cardWidth * 0.5 : cardWidth * 0.2)];
    UIView *cardHolder = [UIView new];
    cardHolder.translatesAutoresizingMaskIntoConstraints = NO;
    [cardHolder addSubview:cardStack];
    [NSLayoutConstraint activateConstraints:@[
        [cardStack.centerXAnchor constraintEqualToAnchor:cardHolder.centerXAnchor],
        [cardStack.topAnchor constraintEqualToAnchor:cardHolder.topAnchor],
        [cardStack.bottomAnchor constraintEqualToAnchor:cardHolder.bottomAnchor],
        [cardStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:cardHolder.leadingAnchor],
        [cardStack.trailingAnchor constraintLessThanOrEqualToAnchor:cardHolder.trailingAnchor],
        [cardHolder.heightAnchor constraintEqualToConstant:cardWidth * 1.4],
    ]];

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    id totalValue = hand[@"total"];
    if ([totalValue isKindOfClass:[NSNumber class]]) {
        BOOL soft = BRBlackjackBool(hand[@"soft"]) && BRBlackjackInt(totalValue) < 21;
        [parts addObject:soft ? [NSString stringWithFormat:@"soft %@", totalValue] : [NSString stringWithFormat:@"%@", totalValue]];
    }
    NSInteger bet = BRBlackjackInt(hand[@"bet"]);
    if (bet > 0) [parts addObject:[NSString stringWithFormat:@"🪙%ld%@", (long)bet, BRBlackjackBool(hand[@"doubled"]) ? @"×2" : @""]];
    if (showResult) {
        NSString *word = [self shortResultWord:BRBlackjackString(hand[@"result"])];
        if (word.length) [parts addObject:word];
    }
    UILabel *summary = [self labelWithSize:(cardWidth > kSplitCardWidth * self.tableScale ? 15 : 13) * self.tableScale weight:UIFontWeightHeavy color:UIColor.whiteColor];
    summary.textAlignment = NSTextAlignmentCenter;
    summary.text = [(marker ? @"▶ " : @"") stringByAppendingString:[parts componentsJoinedByString:@" · "]];

    UIStackView *block = [[UIStackView alloc] initWithArrangedSubviews:@[cardHolder, summary]];
    block.translatesAutoresizingMaskIntoConstraints = NO;
    block.axis = UILayoutConstraintAxisVertical;
    block.spacing = 5;
    return block;
}

- (UIView *)viewForSeat:(NSDictionary *)seat active:(BOOL)active {
    BOOL mine = BRBlackjackBool(seat[@"is_me"]);
    UIColor *gold = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithWhite:0 alpha:.28];
    card.layer.cornerRadius = 12;
    card.layer.borderWidth = (active || mine) ? 2 : 0;
    card.layer.borderColor = (active ? [UIColor colorWithRed:.3 green:.95 blue:.5 alpha:1] : gold).CGColor;
    CGFloat scale = self.tableScale;
    [card.widthAnchor constraintEqualToConstant:kSeatWidth * scale].active = YES;
    if (mine) self.mySeatView = card;

    UILabel *name = [self labelWithSize:14 * scale weight:UIFontWeightBold color:mine ? gold : UIColor.whiteColor];
    NSInteger seatNumber = BRBlackjackInt(seat[@"seat_no"]) + 1; // spoken and shown as "seat N"
    name.text = mine ? [NSString stringWithFormat:@"%@ · %ld", NSLocalizedStringWithDefaultValue(@"BRBlackjack.You", nil, NSBundle.mainBundle, @"You", nil), (long)seatNumber]
                     : [NSString stringWithFormat:@"%ld · %@", (long)seatNumber, BRBlackjackString(seat[@"display_name"])];
    name.adjustsFontSizeToFitWidth = YES;
    name.minimumScaleFactor = 0.7;
    name.textAlignment = NSTextAlignmentCenter;

    NSDictionary *secondHand = BRBlackjackDict(seat[@"hand2"]);
    BOOL split = secondHand.count > 0;
    NSInteger activeHand = BRBlackjackInt(seat[@"active_hand"]);
    NSString *phase = [self phase];
    BOOL settled = [phase isEqualToString:@"results"];

    NSMutableArray<UIView *> *rows = [NSMutableArray arrayWithObject:name];
    if (split) {
        [rows addObject:[self handBlockForHand:seat cardWidth:kSplitCardWidth * scale marker:active && activeHand == 0 showResult:settled]];
        [rows addObject:[self handBlockForHand:secondHand cardWidth:kSplitCardWidth * scale marker:active && activeHand == 1 showResult:settled]];
    } else {
        [rows addObject:[self handBlockForHand:seat cardWidth:kSeatCardWidth * scale marker:NO showResult:NO]];
    }

    UILabel *result = [self labelWithSize:14 * scale weight:UIFontWeightHeavy color:UIColor.whiteColor];
    result.textAlignment = NSTextAlignmentCenter;
    result.adjustsFontSizeToFitWidth = YES;
    result.minimumScaleFactor = 0.7;
    result.text = [self resultTextForSeat:seat];
    NSInteger net = BRBlackjackInt(seat[@"payout"]) - [self totalBetForSeat:seat];
    NSString *resultKey = BRBlackjackString(seat[@"result"]);
    BOOL positive = split ? net > 0 : ([resultKey isEqualToString:@"win"] || [resultKey isEqualToString:@"blackjack"]);
    BOOL negative = split ? net < 0 : ([resultKey isEqualToString:@"lose"] || [resultKey isEqualToString:@"bust"]);
    if (positive) result.textColor = [UIColor colorWithRed:.45 green:1 blue:.55 alpha:1];
    else if (negative) result.textColor = [UIColor colorWithRed:1 green:.5 blue:.5 alpha:1];
    [rows addObject:result];

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:rows];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 6;
    [card addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [column.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [column.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8],
        [column.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],
    ]];
    card.isAccessibilityElement = YES;
    card.accessibilityLabel = [NSString stringWithFormat:@"%@, %@%@, stake %ld", name.text,
        split ? @"two hands, " : @"", [self resultTextForSeat:seat], (long)[self totalBetForSeat:seat]];
    return card;
}

- (NSString *)resultTextForSeat:(NSDictionary *)seat {
    NSString *result = BRBlackjackString(seat[@"result"]);
    NSInteger payout = BRBlackjackInt(seat[@"payout"]);
    NSInteger stake = [self totalBetForSeat:seat];
    BOOL split = BRBlackjackDict(seat[@"hand2"]).count > 0;
    if (result.length > 0 && split) {
        NSInteger net = payout - stake;
        if (net > 0) return [NSString stringWithFormat:@"Split +%ld", (long)net];
        if (net < 0) return [NSString stringWithFormat:@"Split −%ld", (long)-net];
        return @"Split · even";
    }
    if ([result isEqualToString:@"blackjack"]) return [NSString stringWithFormat:@"Blackjack +%ld", (long)(payout - stake)];
    if ([result isEqualToString:@"win"]) return [NSString stringWithFormat:@"Win +%ld", (long)(payout - stake)];
    if ([result isEqualToString:@"push"]) return @"Push";
    if ([result isEqualToString:@"bust"]) return @"Bust";
    if ([result isEqualToString:@"lose"]) return @"Lose";
    NSString *status = BRBlackjackString(seat[@"status"]);
    if ([status isEqualToString:@"stood"]) return @"Stand";
    if (BRBlackjackBool(seat[@"leaving"])) return @"Leaving";
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
        BOOL splitHand = BRBlackjackDict(mine[@"hand2"]).count > 0;
        text = [self isMyTurn]
            ? (splitHand ? [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRBlackjack.YourTurnHand", nil, NSBundle.mainBundle, @"Your turn — hand %ld of 2", nil), (long)BRBlackjackInt(mine[@"active_hand"]) + 1]
                         : NSLocalizedStringWithDefaultValue(@"BRBlackjack.YourTurn", nil, NSBundle.mainBundle, @"Your turn", nil))
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
    BOOL canBet = mine && BRBlackjackInt(mine[@"bet"]) == 0 && ([phase isEqualToString:@"idle"] || [phase isEqualToString:@"betting"]) && !BRBlackjackBool(mine[@"leaving"]);
    BOOL myTurn = [self isMyTurn];

    self.betPanel.hidden = !canBet;
    self.actionPanel.hidden = !myTurn;
    // The visible panel sets the scale's bottom reserve, so a phase
    // change can mean a bigger table: re-measure and redraw now rather
    // than waiting for the next layout pass.
    if ([self refreshTableScale] && self.tableState.count > 0) [self renderTableCards];

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
        // The server decides what is legal (double needs two cards and coins,
        // split needs a pair and coins); we only mirror its answer.
        NSDictionary *actions = BRBlackjackDict(mine[@"actions"]);
        self.hitButton.enabled = !self.actionInFlight && BRBlackjackBool(actions[@"hit"]);
        self.standButton.enabled = !self.actionInFlight && BRBlackjackBool(actions[@"stand"]);
        self.doubleButton.enabled = !self.actionInFlight && BRBlackjackBool(actions[@"double"]);
        self.splitButton.hidden = !BRBlackjackBool(actions[@"split"]);
        self.splitButton.enabled = !self.actionInFlight && BRBlackjackBool(actions[@"split"]);
        for (UIButton *button in @[self.hitButton, self.standButton, self.doubleButton, self.splitButton]) button.alpha = button.enabled ? 1 : 0.5;
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
- (void)splitTapped { [self sendAction:@"split" params:@{ @"expected_version": @(self.lastVersion) }]; }

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
    if (result.length == 0) { [self releaseBalanceHold]; return; }
    // Judge by money, not by the first hand's label, so splits and doubles feel right.
    NSInteger payout = BRBlackjackInt(mine[@"payout"]);
    NSInteger stake = [self totalBetForSeat:mine];
    UINotificationFeedbackGenerator *haptics = [UINotificationFeedbackGenerator new];
    if (payout > stake) [haptics notificationOccurred:UINotificationFeedbackTypeSuccess];
    else if (payout < stake) [haptics notificationOccurred:UINotificationFeedbackTypeError];
    // Keep the shared balance (picker, slots, usage log) in step with the table.
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {}];
    [self resetPendingBet];

    // Payout: chips fly from the player's seat into the balance, then the number counts up.
    if (self.holdingBalanceForPayout && self.mySeatView) {
        NSInteger chipCount = [result isEqualToString:@"blackjack"] ? 12 : (payout > stake ? 8 : 4);
        __weak typeof(self) weakSelf = self;
        [self flyChipsFromView:self.mySeatView toView:self.balancePill count:chipCount completion:^{ [weakSelf releaseBalanceHold]; }];
        // Safety net: never leave the balance frozen if an animation is interrupted.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf releaseBalanceHold]; });
    } else {
        [self releaseBalanceHold];
    }
}

#pragma mark Balance display and payout animation

- (void)setDisplayedBalance:(NSInteger)balance {
    _displayedBalance = balance;
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [NSNumberFormatter new]; formatter.numberStyle = NSNumberFormatterDecimalStyle; });
    self.balanceLabel.text = [NSString stringWithFormat:@"🪙 %@", [formatter stringFromNumber:@(balance)]];
    self.balancePill.accessibilityValue = [formatter stringFromNumber:@(balance)];
}

/// Ends the "hold" set when a payout round settles and counts the displayed
/// balance up to the real one. Safe to call more than once.
- (void)releaseBalanceHold {
    if (!self.holdingBalanceForPayout) return;
    self.holdingBalanceForPayout = NO;
    [self countBalanceTo:self.pendingBalance];
}

- (void)countBalanceTo:(NSInteger)target {
    [self.balanceTimer invalidate];
    self.balanceTimer = nil;
    if (UIAccessibilityIsReduceMotionEnabled() || target == self.displayedBalance) { [self setDisplayedBalance:target]; return; }
    self.countFrom = self.displayedBalance;
    self.countTo = target;
    self.countStart = CACurrentMediaTime();
    self.balanceTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0 target:self selector:@selector(balanceCountTick) userInfo:nil repeats:YES];
}

- (void)balanceCountTick {
    const NSTimeInterval duration = 0.7;
    double progress = MIN(1.0, (CACurrentMediaTime() - self.countStart) / duration);
    double eased = 1.0 - pow(1.0 - progress, 3.0);
    [self setDisplayedBalance:(NSInteger)llround(self.countFrom + (self.countTo - self.countFrom) * eased)];
    if (progress >= 1.0) { [self.balanceTimer invalidate]; self.balanceTimer = nil; [self setDisplayedBalance:self.countTo]; }
}

- (void)pulseBalancePill {
    [UIView animateWithDuration:0.12 animations:^{ self.balancePill.transform = CGAffineTransformMakeScale(1.1, 1.1); }
                     completion:^(BOOL finished) {
        [UIView animateWithDuration:0.18 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0 options:0
                         animations:^{ self.balancePill.transform = CGAffineTransformIdentity; } completion:nil];
    }];
}

/// Flies `count` coin emoji along curved paths from one view to another, one
/// after another, pulsing the target as each lands. Respects Reduce Motion.
- (void)flyChipsFromView:(UIView *)source toView:(UIView *)target count:(NSInteger)count completion:(void (^)(void))completion {
    if (UIAccessibilityIsReduceMotionEnabled() || !source.window || !target.window || count <= 0) { completion(); return; }
    CGPoint start = [self.view convertPoint:CGPointMake(CGRectGetMidX(source.bounds), CGRectGetMidY(source.bounds)) fromView:source];
    CGPoint end = [self.view convertPoint:CGPointMake(CGRectGetMidX(target.bounds), CGRectGetMidY(target.bounds)) fromView:target];
    __block NSInteger landed = 0;
    for (NSInteger i = 0; i < count; i++) {
        UILabel *chip = [UILabel new];
        chip.text = @"🪙";
        chip.font = [UIFont systemFontOfSize:30];
        [chip sizeToFit];
        chip.center = start;
        chip.alpha = 0;
        chip.userInteractionEnabled = NO;
        [self.view addSubview:chip];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.07 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIBezierPath *path = [UIBezierPath bezierPath];
            [path moveToPoint:start];
            CGPoint control = CGPointMake((start.x + end.x) / 2.0 + ((CGFloat)arc4random_uniform(100) - 50),
                                          MIN(start.y, end.y) - 60 - (CGFloat)arc4random_uniform(50));
            [path addQuadCurveToPoint:end controlPoint:control];
            CAKeyframeAnimation *move = [CAKeyframeAnimation animationWithKeyPath:@"position"];
            move.path = path.CGPath;
            move.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
            CABasicAnimation *shrink = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            shrink.fromValue = @1.0;
            shrink.toValue = @0.55;
            CAAnimationGroup *group = [CAAnimationGroup animation];
            group.animations = @[move, shrink];
            group.duration = 0.75;
            chip.alpha = 1;
            [CATransaction begin];
            [CATransaction setCompletionBlock:^{
                [chip removeFromSuperview];
                landed++;
                [self pulseBalancePill];
                if (landed == count) completion();
            }];
            chip.layer.position = end; // final model value so the chip doesn't snap back
            [chip.layer addAnimation:group forKey:@"fly"];
            [CATransaction commit];
        });
    }
}

#pragma mark Dealer voice and speech bubble

- (void)updateVoiceButton {
    [self.voiceButton setTitle:self.dealerVoiceMuted ? @"🔇" : @"🔊" forState:UIControlStateNormal];
    self.voiceButton.accessibilityLabel = self.dealerVoiceMuted ? @"Unmute dealer voice" : @"Mute dealer voice";
}

- (void)toggleDealerVoice {
    self.dealerVoiceMuted = !self.dealerVoiceMuted;
    [[NSUserDefaults standardUserDefaults] setBool:self.dealerVoiceMuted forKey:kDealerVoiceMutedKey];
    self.announcer.voiceEnabled = !self.dealerVoiceMuted && BRSlotSoundEnabled();
    if (self.dealerVoiceMuted) [self stopDealerAudio];
    [self updateVoiceButton];
}

- (void)stopDealerAudio {
    [self.dealerAudioPlayer stop];
    self.dealerAudioPlayer = nil;
    [self setDealerTalking:NO];
}

/// Speech bubble above the dealer. Chat replies stay up for a while; table
/// call-outs only for a moment. A newer bubble cancels the older one's timer.
- (void)showDealerBubbleText:(NSString *)text duration:(NSTimeInterval)duration {
    self.dealerBubbleLabel.text = text;
    self.dealerBubble.hidden = NO;
    self.dealerBubble.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ self.dealerBubble.alpha = 1; }];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, [@"Dealer: " stringByAppendingString:text]);
    NSInteger token = ++self.bubbleToken;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || token != self.bubbleToken) return;
        [UIView animateWithDuration:0.3 animations:^{ self.dealerBubble.alpha = 0; } completion:^(BOOL finished) {
            if (token == self.bubbleToken) self.dealerBubble.hidden = YES;
        }];
    });
}

/// Gentle pulsing on the avatar while the dealer is speaking.
- (void)setDealerTalking:(BOOL)talking {
    if (!talking) {
        [self.dealerAvatarView.layer removeAnimationForKey:@"talk"];
        return;
    }
    if ([self.dealerAvatarView.layer animationForKey:@"talk"] || UIAccessibilityIsReduceMotionEnabled()) return;
    CABasicAnimation *talk = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    talk.fromValue = @1.0; talk.toValue = @1.08; talk.duration = 0.22; talk.autoreverses = YES; talk.repeatCount = HUGE_VALF;
    [self.dealerAvatarView.layer addAnimation:talk forKey:@"talk"];
}

/// Shows the dealer's line in a speech bubble and, unless muted, speaks it.
/// Only the Supabase storage host is trusted as an audio source.
- (void)dealerSaysLine:(NSString *)line audioURLString:(NSString *)audioURLString {
    if (line.length == 0) return;
    [self showDealerBubbleText:line duration:10];
    __weak typeof(self) weakSelf = self;

    BOOL canSpeak = !self.dealerVoiceMuted && BRSlotSoundEnabled() && audioURLString.length > 0;
    NSURL *audioURL = canSpeak ? [NSURL URLWithString:audioURLString] : nil;
    NSString *trustedHost = [NSURL URLWithString:EZSupabaseURL].host;
    if (!audioURL || ![audioURL.scheme isEqualToString:@"https"] || ![audioURL.host isEqualToString:trustedHost]) {
        [self bounceDealerAvatar];
        return;
    }
    [[[NSURLSession sharedSession] dataTaskWithURL:audioURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data.length == 0 || error) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.dealerVoiceMuted || self.leaving) return;
            BRBlackjackActivateAudioSession();
            AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:data error:nil];
            if (!player) return;
            [self stopDealerAudio];
            player.delegate = self;
            [player prepareToPlay];
            [player play];
            self.dealerAudioPlayer = player;
            [self setDealerTalking:YES];
        });
    }] resume];
}

- (void)bounceDealerAvatar {
    [UIView animateWithDuration:0.12 animations:^{ self.dealerAvatarView.transform = CGAffineTransformMakeScale(1.12, 1.12); }
                     completion:^(BOOL finished) {
        [UIView animateWithDuration:0.2 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0 options:0
                         animations:^{ self.dealerAvatarView.transform = CGAffineTransformIdentity; } completion:nil];
    }];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player == self.dealerAudioPlayer) { self.dealerAudioPlayer = nil; [self.dealerAvatarView.layer removeAnimationForKey:@"talk"]; }
}

#pragma mark Dealer call-outs

/// Creates the announcer and starts downloading the clip library.
- (void)buildAnnouncer {
    self.announcer = [[BRBlackjackAnnouncer alloc] initWithTableID:self.tableID];
    __weak typeof(self) weakSelf = self;
    self.announcer.captionHandler = ^(NSString *caption) {
        [weakSelf showDealerBubbleText:caption duration:3.0];
    };
    self.announcer.speakingHandler = ^(BOOL speaking) {
        [weakSelf setDealerTalking:speaking];
    };
    [self.announcer loadClips];
}

/// Clip key for a card's rank as the dealer's up card: ace, or the card's value (face cards say "ten").
static NSString *BRBlackjackRankKey(NSInteger cardID) {
    NSInteger rank = cardID % 13;
    return rank == 0 ? @"ace" : [NSString stringWithFormat:@"n%ld", (long)MIN(rank + 1, 10)];
}

static NSString *BRBlackjackRankWord(NSInteger cardID) {
    NSInteger rank = cardID % 13;
    return rank == 0 ? @"an ace" : [NSString stringWithFormat:@"%ld", (long)MIN(rank + 1, 10)];
}

- (void)queueCall:(NSMutableArray<NSDictionary *> *)calls keys:(NSArray<NSString *> *)keys caption:(NSString *)caption {
    [calls addObject:@{ @"keys": keys, @"caption": caption }];
}

/// Calls one hand: "Seat 3, soft 17", "You have 20", "Seat 2, bust", "You have blackjack".
/// withSpeaker is NO for the second hand of a split, which only says its total.
- (void)queueHandCall:(NSMutableArray<NSDictionary *> *)calls seat:(NSDictionary *)seat hand:(NSDictionary *)hand
              isNatural:(BOOL)natural withSpeaker:(BOOL)withSpeaker {
    BOOL mine = BRBlackjackBool(seat[@"is_me"]);
    NSInteger seatNumber = BRBlackjackInt(seat[@"seat_no"]) + 1;
    id totalValue = hand[@"total"];
    if (![totalValue isKindOfClass:[NSNumber class]]) return;
    NSInteger total = [totalValue integerValue];

    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    NSString *speakerText = @"";
    // Play-by-play: with the player's name clip downloaded, the call
    // is "<Name> has seventeen" instead of "Seat 2: seventeen".
    NSString *displayName = BRBlackjackString(seat[@"display_name"]);
    BOOL nameMode = NO;
    if (withSpeaker) {
        if (mine) { [keys addObject:@"you_have"]; speakerText = @"You have "; }
        else if (displayName.length && [self.announcer hasNameClipForName:displayName]) {
            [keys addObject:[self.announcer nameClipKeyForName:displayName]];
            speakerText = [NSString stringWithFormat:@"%@ has ", displayName];
            nameMode = YES;
        }
        else if (seatNumber >= 1 && seatNumber <= 8) { [keys addObject:[NSString stringWithFormat:@"seat%ld", (long)seatNumber]]; speakerText = [NSString stringWithFormat:@"Seat %ld: ", (long)seatNumber]; }
    }
    NSString *what;
    if (natural) {
        if (nameMode) [keys addObject:@"has"];
        [keys addObject:@"blackjack"];
        what = @"blackjack!";
    } else if (total > 21) {
        // "You have bust" sounds wrong: drop the speaker for the player's own bust.
        if (mine && withSpeaker) { [keys removeAllObjects]; speakerText = @""; }
        if (nameMode) {
            [keys addObject:@"busts"];
            speakerText = [NSString stringWithFormat:@"%@ ", displayName];
            what = @"busts";
        } else {
            [keys addObject:@"bust"];
            what = mine ? @"Bust!" : @"bust";
        }
    } else {
        BOOL soft = BRBlackjackBool(hand[@"soft"]) && total < 21;
        if (nameMode) [keys addObject:@"has"];
        if (soft) [keys addObject:@"soft"];
        [keys addObject:[NSString stringWithFormat:@"n%ld", (long)total]];
        what = soft ? [NSString stringWithFormat:@"soft %ld", (long)total] : [NSString stringWithFormat:@"%ld", (long)total];
    }
    [self queueCall:calls keys:keys caption:[speakerText stringByAppendingString:what]];

    // A natural or a made 21 earns a compliment about half the time.
    if (natural || total == 21) {
        NSArray<NSDictionary *> *pool = @[
            @{ @"keys": @[@"p21_quip1"], @"caption": @"There you go!" },
            @{ @"keys": @[@"p21_quip2"], @"caption": @"Way to go!" },
            @{ @"keys": @[@"p21_quip3"], @"caption": @"Very nice!" },
        ];
        if (arc4random_uniform(2) == 0) {
            NSDictionary *pick = pool[arc4random_uniform((uint32_t)pool.count)];
            NSString *displayName = BRBlackjackString(seat[@"display_name"]);
            NSString *prefix = mine ? @"" : (displayName.length ? [NSString stringWithFormat:@"%@: ", displayName]
                                                                 : [NSString stringWithFormat:@"Seat %ld: ", (long)seatNumber]);
            [self queueCall:calls keys:pick[@"keys"] caption:[prefix stringByAppendingString:pick[@"caption"]]];
        }
    }
}

/// Compares the table before and after an update and queues the dealer's calls.
/// Works from state alone, so it needs no server events and tolerates missed polls
/// (it simply reads out the totals as they are now).
/// Dealer 21 gets some variety: the plain call is in the rotation
/// twice, and Lucky Lou has five quips for it (d21_quip clips) that
/// share the rest. Picked fresh every hand. If a quip clip has not
/// rendered yet the announcer shows its caption without audio.
// "<Name> stands." / "<Name> doubles." — name clip + verb clip when
// the name is in, seat-number clips otherwise. The player's own
// action is called by name too; without the name clip it waits.
- (void)queueActionCall:(NSMutableArray<NSDictionary *> *)calls seat:(NSDictionary *)seat verbKey:(NSString *)verbKey verb:(NSString *)verb {
    NSString *displayName = BRBlackjackString(seat[@"display_name"]);
    if (displayName.length && [self.announcer hasNameClipForName:displayName]) {
        [self queueCall:calls keys:@[[self.announcer nameClipKeyForName:displayName], verbKey]
                caption:[NSString stringWithFormat:@"%@ %@.", displayName, verb]];
    } else if (!BRBlackjackBool(seat[@"is_me"])) {
        NSInteger seatNumber = BRBlackjackInt(seat[@"seat_no"]) + 1;
        if (seatNumber >= 1 && seatNumber <= 8) {
            [self queueCall:calls keys:@[[NSString stringWithFormat:@"seat%ld", (long)seatNumber], verbKey]
                    caption:[NSString stringWithFormat:@"Seat %ld %@.", (long)seatNumber, verb]];
        }
    }
}

// "<Name>, it's on you." when the turn moves to a seat.
- (void)queueTurnCall:(NSMutableArray<NSDictionary *> *)calls seat:(NSDictionary *)seat {
    NSString *displayName = BRBlackjackString(seat[@"display_name"]);
    if (displayName.length && [self.announcer hasNameClipForName:displayName]) {
        [self queueCall:calls keys:@[[self.announcer nameClipKeyForName:displayName], @"its_on_you"]
                caption:[NSString stringWithFormat:@"%@, it's on you.", displayName]];
    } else if (BRBlackjackBool(seat[@"is_me"])) {
        [self queueCall:calls keys:@[@"its_on_you"] caption:@"It's on you."];
    } else {
        NSInteger seatNumber = BRBlackjackInt(seat[@"seat_no"]) + 1;
        if (seatNumber >= 1 && seatNumber <= 8) {
            [self queueCall:calls keys:@[[NSString stringWithFormat:@"seat%ld", (long)seatNumber], @"its_on_you"]
                    caption:[NSString stringWithFormat:@"Seat %ld, it's on you.", (long)seatNumber]];
        }
    }
}

- (void)queueDealer21Call:(NSMutableArray<NSDictionary *> *)calls natural:(BOOL)natural {
    NSDictionary *plain = natural
        ? @{ @"keys": @[@"dealer_blackjack"], @"caption": @"Dealer has blackjack" }
        : @{ @"keys": @[@"dealer_has", @"n21"], @"caption": @"Dealer has 21" };
    NSArray<NSDictionary *> *options = @[
        plain, plain,
        @{ @"keys": @[@"d21_quip1"], @"caption": @"Twenty-one for the dealer. Tough break, guys." },
        @{ @"keys": @[@"d21_quip2"], @"caption": @"Dealer has twenty-one. Sorry about that, folks." },
        @{ @"keys": @[@"d21_quip3"], @"caption": @"Twenty-one. The house does it again." },
        @{ @"keys": @[@"d21_quip4"], @"caption": @"Dealer gets twenty-one. The house sends its regards." },
        @{ @"keys": @[@"d21_quip5"], @"caption": @"Ooh, twenty-one for me. Tough one, guys." },
    ];
    NSDictionary *pick = options[arc4random_uniform((uint32_t)options.count)];
    [self queueCall:calls keys:pick[@"keys"] caption:pick[@"caption"]];
}

- (void)announceChangesFrom:(NSDictionary *)oldView to:(NSDictionary *)newView {
    if (self.skipNextAnnouncements) { self.skipNextAnnouncements = NO; return; }
    if (oldView.count == 0 || self.leaving) return;

    NSDictionary *oldTable = BRBlackjackDict(oldView[@"table"]);
    NSDictionary *newTable = BRBlackjackDict(newView[@"table"]);
    NSString *oldPhase = BRBlackjackString(oldTable[@"phase"]);
    NSString *newPhase = BRBlackjackString(newTable[@"phase"]);
    BOOL seated = [self mySeat] != nil;
    NSMutableArray<NSDictionary *> *calls = [NSMutableArray array];

    if ([newPhase isEqualToString:@"betting"] && ![oldPhase isEqualToString:@"betting"]) {
        [self.stiffHitSeats removeAllObjects];
        if (seated) [self queueCall:calls keys:@[@"place_bets"] caption:@"Place your bets"];
    }

    BOOL dealtThisUpdate = ([oldPhase isEqualToString:@"idle"] || [oldPhase isEqualToString:@"betting"])
        && ([newPhase isEqualToString:@"playing"] || [newPhase isEqualToString:@"results"]);
    NSDictionary *newDealer = BRBlackjackDict(newView[@"dealer"]);
    NSArray *newDealerCards = BRBlackjackArray(newDealer[@"cards"]);
    if (dealtThisUpdate) {
        [self queueCall:calls keys:@[@"no_more_bets"] caption:@"No more bets"];
        if (newDealerCards.count > 0) {
            NSInteger upCard = BRBlackjackInt(newDealerCards[0]);
            [self queueCall:calls keys:@[@"dealer_shows", BRBlackjackRankKey(upCard)]
                    caption:[NSString stringWithFormat:@"Dealer shows %@", BRBlackjackRankWord(upCard)]];
            // A 5 or 6 up is a bust card waiting to happen, and Lou
            // knows it: half the time he says so.
            NSInteger upRank = upCard % 13;
            if ((upRank == 4 || upRank == 5) && arc4random_uniform(2) == 0) {
                NSArray<NSDictionary *> *pool = @[
                    @{ @"keys": @[@"dweak_quip1"], @"caption": @"Dealer's going to bust." },
                    @{ @"keys": @[@"dweak_quip2"], @"caption": @"Have some faith." },
                ];
                NSDictionary *pick = pool[arc4random_uniform((uint32_t)pool.count)];
                [self queueCall:calls keys:pick[@"keys"] caption:pick[@"caption"]];
            }
        }
    }

    // Seats, in table order: any hand whose card count grew gets its total called.
    NSMutableDictionary<NSNumber *, NSDictionary *> *oldSeats = [NSMutableDictionary dictionary];
    for (NSDictionary *seat in BRBlackjackArray(oldView[@"seats"])) oldSeats[@(BRBlackjackInt(BRBlackjackDict(seat)[@"seat_no"]))] = BRBlackjackDict(seat);
    for (NSDictionary *rawSeat in BRBlackjackArray(newView[@"seats"])) {
        NSDictionary *seat = BRBlackjackDict(rawSeat);
        NSDictionary *oldSeat = oldSeats[@(BRBlackjackInt(seat[@"seat_no"]))] ?: @{};
        NSInteger oldCount = BRBlackjackArray(oldSeat[@"cards"]).count;
        NSInteger newCount = BRBlackjackArray(seat[@"cards"]).count;
        NSDictionary *secondHand = BRBlackjackDict(seat[@"hand2"]);
        BOOL justSplit = secondHand.count > 0 && BRBlackjackDict(oldSeat[@"hand2"]).count == 0;
        if (justSplit) {
            NSString *splitName = BRBlackjackString(seat[@"display_name"]);
            if (!BRBlackjackBool(seat[@"is_me"]) && splitName.length && [self.announcer hasNameClipForName:splitName]) {
                [self queueCall:calls keys:@[[self.announcer nameClipKeyForName:splitName], @"split"] caption:[NSString stringWithFormat:@"%@ splits", splitName]];
            } else {
                [self queueCall:calls keys:@[@"split"] caption:BRBlackjackBool(seat[@"is_me"]) ? @"You split" : [NSString stringWithFormat:@"Seat %ld splits", (long)BRBlackjackInt(seat[@"seat_no"]) + 1]];
            }
            [self queueHandCall:calls seat:seat hand:seat isNatural:NO withSpeaker:YES];
            [self queueHandCall:calls seat:seat hand:secondHand isNatural:NO withSpeaker:NO];
            continue;
        }
        if (newCount > oldCount) {
            // Remember hitting on a stiff hand (12-20): if this seat
            // goes on to win, the dealer calls it well played.
            id oldTotal = oldSeat[@"total"];
            NSInteger hitFrom = [oldTotal isKindOfClass:[NSNumber class]] ? [oldTotal integerValue] : 0;
            if (hitFrom >= 12 && hitFrom <= 20) {
                if (!self.stiffHitSeats) self.stiffHitSeats = [NSMutableSet set];
                [self.stiffHitSeats addObject:@(BRBlackjackInt(seat[@"seat_no"]))];
            }
            BOOL natural = [BRBlackjackString(seat[@"status"]) isEqualToString:@"blackjack"] && newCount == 2;
            [self queueHandCall:calls seat:seat hand:seat isNatural:natural withSpeaker:YES];
        }
        NSInteger oldSecondCount = BRBlackjackArray(BRBlackjackDict(oldSeat[@"hand2"])[@"cards"]).count;
        if (secondHand.count > 0 && BRBlackjackArray(secondHand[@"cards"]).count > oldSecondCount) {
            [self queueHandCall:calls seat:seat hand:secondHand isNatural:NO withSpeaker:NO];
        }

        // Play-by-play: standing and doubling get called, by name
        // when the name clip is in. (Hits speak for themselves: the
        // new total is the call.)
        NSDictionary *oldSecond = BRBlackjackDict(oldSeat[@"hand2"]);
        if (![BRBlackjackString(seat[@"status"]) isEqualToString:BRBlackjackString(oldSeat[@"status"])]
            && [BRBlackjackString(seat[@"status"]) isEqualToString:@"stood"]) {
            [self queueActionCall:calls seat:seat verbKey:@"stands" verb:@"stands"];
        }
        if (![BRBlackjackString(secondHand[@"status"]) isEqualToString:BRBlackjackString(oldSecond[@"status"])]
            && [BRBlackjackString(secondHand[@"status"]) isEqualToString:@"stood"]) {
            [self queueActionCall:calls seat:seat verbKey:@"stands" verb:@"stands"];
        }
        if (!BRBlackjackBool(oldSeat[@"doubled"]) && BRBlackjackBool(seat[@"doubled"])) {
            [self queueActionCall:calls seat:seat verbKey:@"doubles" verb:@"doubles"];
        }
        if (!BRBlackjackBool(oldSecond[@"doubled"]) && BRBlackjackBool(secondHand[@"doubled"])) {
            [self queueActionCall:calls seat:seat verbKey:@"doubles" verb:@"doubles"];
        }
    }

    // The turn moving to a new seat gets a call: "<Name>, it's on you."
    if ([newPhase isEqualToString:@"playing"]) {
        id oldActive = oldTable[@"active_seat"];
        id newActive = newTable[@"active_seat"];
        NSInteger oldActiveSeat = [oldActive isKindOfClass:[NSNumber class]] ? [oldActive integerValue] : -1;
        NSInteger newActiveSeat = [newActive isKindOfClass:[NSNumber class]] ? [newActive integerValue] : -1;
        if (newActiveSeat >= 0 && newActiveSeat != oldActiveSeat) {
            for (NSDictionary *rawSeat in BRBlackjackArray(newView[@"seats"])) {
                NSDictionary *seat = BRBlackjackDict(rawSeat);
                if (BRBlackjackInt(seat[@"seat_no"]) == newActiveSeat) { [self queueTurnCall:calls seat:seat]; break; }
            }
        }
    }

    // Dealer's final hand once the cards are turned over.
    if ([newPhase isEqualToString:@"results"] && ![oldPhase isEqualToString:@"results"] && newDealerCards.count >= 2) {
        id totalValue = newDealer[@"total"];
        NSInteger dealerTotal = [totalValue isKindOfClass:[NSNumber class]] ? [totalValue integerValue] : 0;
        if (dealerTotal == 21) {
            [self queueDealer21Call:calls natural:(newDealerCards.count == 2)];
        } else if (dealerTotal > 21) {
            [self queueCall:calls keys:@[@"dealer_busts"] caption:@"Dealer busts"];
        } else if (dealerTotal >= 2) {
            [self queueCall:calls keys:@[@"dealer_has", [NSString stringWithFormat:@"n%ld", (long)dealerTotal]]
                    caption:[NSString stringWithFormat:@"Dealer has %ld", (long)dealerTotal]];
        }

        // Well played: a win that came from hitting a stiff hand or
        // from a double down earns a word from the dealer (max two
        // per round, so a hot table doesn't turn into a speech).
        NSInteger compliments = 0;
        for (NSDictionary *rawSeat in BRBlackjackArray(newView[@"seats"])) {
            if (compliments >= 2) break;
            NSDictionary *seat = BRBlackjackDict(rawSeat);
            id payoutValue = seat[@"payout"];
            NSInteger payout = [payoutValue isKindOfClass:[NSNumber class]] ? [payoutValue integerValue] : 0;
            if (payout <= [self totalBetForSeat:seat]) continue;
            BOOL doubled = BRBlackjackBool(seat[@"doubled"]) || BRBlackjackBool(BRBlackjackDict(seat[@"hand2"])[@"doubled"]);
            BOOL stiffHit = [self.stiffHitSeats containsObject:@(BRBlackjackInt(seat[@"seat_no"]))];
            if (!doubled && !stiffHit) continue;
            NSArray<NSDictionary *> *pool = @[
                @{ @"keys": @[@"wp_quip1"], @"caption": @"Well played." },
                @{ @"keys": @[@"p21_quip3"], @"caption": @"Very nice!" },
                @{ @"keys": @[@"wp_quip2"], @"caption": @"This isn't your first time at a table." },
            ];
            NSDictionary *pick = pool[arc4random_uniform((uint32_t)pool.count)];
            NSString *displayName = BRBlackjackString(seat[@"display_name"]);
            NSString *prefix = BRBlackjackBool(seat[@"is_me"]) ? @"" : (displayName.length ? [NSString stringWithFormat:@"%@: ", displayName]
                                                                                           : [NSString stringWithFormat:@"Seat %ld: ", (long)BRBlackjackInt(seat[@"seat_no"]) + 1]);
            [self queueCall:calls keys:pick[@"keys"] caption:[prefix stringByAppendingString:pick[@"caption"]]];
            compliments += 1;
        }
        [self.stiffHitSeats removeAllObjects];
    }

    self.announcer.voiceEnabled = !self.dealerVoiceMuted && BRSlotSoundEnabled();
    for (NSDictionary *call in calls) [self.announcer enqueueKeys:call[@"keys"] caption:call[@"caption"]];
}

/// Tells the server a player chatted so the dealer can decide whether to reply
/// (he usually won't). Throttled so a burst of messages sends one ping.
- (void)chatMessageSent:(NSNotification *)notification {
    if (![notification.object isEqual:[@"bj:" stringByAppendingString:self.tableID]]) return;
    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastChatPingTime < 5.0) return;
    self.lastChatPingTime = now;
    [BRBlackjackAPI performAction:@"chat_ping" params:@{ @"table_id": self.tableID } completion:^(NSDictionary *json, NSInteger status, NSString *error) {}];
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
