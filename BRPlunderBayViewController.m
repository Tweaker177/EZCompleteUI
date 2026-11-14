#import "BRPlunderBayViewController.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZSupabaseConfig.h"
#import "EZCoinStoreViewController.h"
#import "BRSlotRoomViewController.h"
#import <AVFoundation/AVFoundation.h>

// Plunder Bay — the client half of ez-plunder-spin. The server owns
// the reels, the free-spin award roll and every coin; this screen
// renders what it is told and stages the chest landings: a boom per
// chest climbing +3 semitones, the drum roll from the second chest,
// bells into the bonus, and a song heard only inside free spins.
// Sound files live in Resources/sounds (pb_boom, pb_drumroll,
// pb_bells, pb_coins, pb_bonus_song); any missing file simply makes
// its hook silent until the file is added to the bundle.

static NSArray<NSString *> *PlunderSymbols(void) {
    return @[@"captain", @"galleon", @"map", @"cannon", @"parrot", @"anchor", @"compass", @"rum", @"doubloon", @"hook", @"wild", @"scatter"];
}
static NSArray<NSNumber *> *PlunderBets(void) { return @[@10, @20, @50, @100]; }

@interface BRPlunderBayViewController () <AVAudioPlayerDelegate>
@property (nonatomic, strong) NSMutableArray<NSArray<UIImageView *> *> *reels;
@property (nonatomic, strong) UILabel *balanceLabel, *bonusLabel, *messageLabel;
@property (nonatomic, strong) UIButton *betButton, *spinButton, *maxButton;
@property (nonatomic, strong) UIView *machineView, *bonusTint, *winOverlay;
@property (nonatomic, strong) AVAudioPlayer *bellsPlayer, *coinsPlayer, *reelsPlayer, *whooshPlayer, *cannonPlayer;
@property (nonatomic, strong) AVAudioEngine *loopEngine;
@property (nonatomic, strong) AVAudioPlayerNode *drumNode, *songNode, *ambienceNode;
@property (nonatomic, strong) AVAudioMixerNode *drumMixer, *songMixer, *ambienceMixer;
@property (nonatomic, strong) AVAudioPCMBuffer *drumBuffer, *songBuffer, *ambienceBuffer;
@property (nonatomic, strong) AVAudioEngine *sfxEngine;
@property (nonatomic, strong) AVAudioPlayerNode *boomNode;
@property (nonatomic, strong) AVAudioUnitVarispeed *boomSpeed;
@property (nonatomic, strong) AVAudioFile *boomFile;
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *preSpinBoard;
@property (nonatomic) NSInteger betIndex, freeSpinsRemaining, freeSpinSessionTotal, scatterStep;
@property (nonatomic) BOOL spinning, celebrating, inBonus, slamRequested, spinSettled, bonusLightsRunning;
@property (nonatomic, strong) NSDictionary *pendingSpinResult;
@property (nonatomic) NSUInteger autoSpinToken;
@property (nonatomic) NSUInteger animationID, lineCelebrationID;
@end

@implementation BRPlunderBayViewController

+ (UIImage *)plunderSymbolImage:(NSString *)symbol {
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    if (cache[symbol]) return cache[symbol];
    UIImage *image = [UIImage imageNamed:[NSString stringWithFormat:@"plunder_%@", symbol]];
    if (!image) {
        NSString *path = [[NSBundle mainBundle] pathForResource:[NSString stringWithFormat:@"plunder_%@", symbol] ofType:@"b64"];
        NSData *encoded = path ? [NSData dataWithContentsOfFile:path] : nil;
        NSData *jpeg = encoded ? [[NSData alloc] initWithBase64EncodedData:encoded options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
        image = jpeg ? [UIImage imageWithData:jpeg] : nil;
    }
    if (image) cache[symbol] = image;
    return image;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // One title per page: the big in-view heading is this screen's only title; no nav-bar duplicate.
    self.view.backgroundColor = [UIColor colorWithRed:.02 green:.04 blue:.10 alpha:1];
    self.betIndex = 1; // 20 coins
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:[self navButton:NSLocalizedString(@"BRSlot.Navigation.Back", nil) action:@selector(backTapped)]];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithCustomView:[self navButton:NSLocalizedString(@"BRSlot.Navigation.Lounge", nil) action:@selector(openLounge)]],
        [[UIBarButtonItem alloc] initWithCustomView:[self navButton:NSLocalizedString(@"BRSlot.Navigation.Odds", nil) action:@selector(showOdds)]]
    ];
    [self buildUI]; [self setupAudio]; [self refreshState];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self refreshState]; if (self.freeSpinsRemaining > 0) [self startBonusSong]; [self scheduleBonusAutoSpin]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; self.autoSpinToken++; [self clearLineHighlights]; [self stopDrumRoll]; if (self.isMovingFromParentViewController) { [self.songNode pause]; [self.ambienceNode pause]; [self.drumNode stop]; [self.reelsPlayer stop]; [self.whooshPlayer stop]; [self.loopEngine stop]; [self.sfxEngine stop]; } }
- (void)backTapped { [self.navigationController popViewControllerAnimated:YES]; }
- (void)openLounge { [self.navigationController pushViewController:[[BRSlotRoomViewController alloc] initWithRoomID:@"plunder-bay" title:NSLocalizedString(@"BRSlot.Plunder.LoungeTitle", nil)] animated:YES]; }

- (UIButton *)navButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithRed:1 green:.8 blue:.2 alpha:1] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBlack];
    button.backgroundColor = [UIColor colorWithRed:.05 green:.10 blue:.22 alpha:1];
    button.layer.cornerRadius = 10; button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithRed:1 green:.75 blue:.14 alpha:1].CGColor;
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    [button sizeToFit];
    button.frame = CGRectMake(0, 0, MAX(53, CGRectGetWidth(button.bounds) + 20), 32);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; return button;
}
- (UIButton *)control:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    button.titleLabel.numberOfLines = 2; button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.backgroundColor = color; button.layer.cornerRadius = 13;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; return button;
}
- (void)buildUI {
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO; scroll.alwaysBounceVertical = YES; [self.view addSubview:scroll];
    UIView *content = [UIView new]; content.translatesAutoresizingMaskIntoConstraints = NO; [scroll addSubview:content];
    UILabel *title = [UILabel new]; title.text = NSLocalizedString(@"BRSlot.Plunder.Heading", nil); title.font = [UIFont systemFontOfSize:23 weight:UIFontWeightBlack]; title.adjustsFontSizeToFitWidth = YES; title.minimumScaleFactor = .55; title.textColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1]; title.textAlignment = NSTextAlignmentCenter;
    self.balanceLabel = [UILabel new]; self.balanceLabel.text = NSLocalizedString(@"BRSlot.Balance.Loading", nil); self.balanceLabel.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightBold]; self.balanceLabel.textColor = UIColor.whiteColor; self.balanceLabel.textAlignment = NSTextAlignmentCenter;
    self.bonusLabel = [UILabel new]; self.bonusLabel.text = NSLocalizedString(@"BRSlot.Plunder.ScatterReward", nil); self.bonusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold]; self.bonusLabel.textColor = [UIColor colorWithRed:1 green:.83 blue:.3 alpha:1]; self.bonusLabel.textAlignment = NSTextAlignmentCenter; self.bonusLabel.numberOfLines = 2; self.bonusLabel.backgroundColor = [UIColor colorWithRed:.05 green:.16 blue:.28 alpha:1]; self.bonusLabel.layer.cornerRadius = 10; self.bonusLabel.clipsToBounds = YES;
    self.machineView = [UIView new]; self.machineView.backgroundColor = [UIColor colorWithRed:.05 green:.09 blue:.22 alpha:1]; self.machineView.layer.cornerRadius = 21; self.machineView.layer.borderWidth = 3; self.machineView.layer.borderColor = [UIColor colorWithRed:1 green:.71 blue:.12 alpha:1].CGColor;
    UIStackView *columns = [UIStackView new]; columns.axis = UILayoutConstraintAxisHorizontal; columns.distribution = UIStackViewDistributionFillEqually; columns.spacing = 5;
    self.reels = [NSMutableArray array];
    for (NSInteger col=0; col<5; col++) {
        UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical; stack.distribution = UIStackViewDistributionFillEqually; stack.spacing = 5;
        NSMutableArray *tiles = [NSMutableArray array];
        for (NSInteger row=0; row<3; row++) { UIImageView *tile = [UIImageView new]; tile.backgroundColor = [UIColor colorWithRed:.04 green:.07 blue:.16 alpha:1]; tile.layer.cornerRadius = 6; tile.clipsToBounds = YES; [self setSymbol:PlunderSymbols()[(col*3+row)%PlunderSymbols().count] onTile:tile]; [stack addArrangedSubview:tile]; [tiles addObject:tile]; }
        [self.reels addObject:tiles]; [columns addArrangedSubview:stack];
    }
    columns.translatesAutoresizingMaskIntoConstraints = NO; [self.machineView addSubview:columns];
    self.bonusTint = [UIView new]; self.bonusTint.backgroundColor = [UIColor colorWithRed:.01 green:.02 blue:.08 alpha:.30]; self.bonusTint.userInteractionEnabled = NO; self.bonusTint.hidden = YES; self.bonusTint.translatesAutoresizingMaskIntoConstraints = NO; [self.machineView addSubview:self.bonusTint];
    self.messageLabel = [UILabel new]; self.messageLabel.text = NSLocalizedString(@"BRSlot.Plunder.Description", nil); self.messageLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]; self.messageLabel.textColor = [UIColor colorWithWhite:.85 alpha:1]; self.messageLabel.textAlignment = NSTextAlignmentCenter; self.messageLabel.numberOfLines = 2;
    self.betButton = [self control:[NSString stringWithFormat:NSLocalizedString(@"BRSlot.Plunder.BetValue", nil), (long)self.betCoins] color:[UIColor colorWithRed:.08 green:.34 blue:.52 alpha:1] action:@selector(cycleBet)];
    self.maxButton = [self control:NSLocalizedString(@"BRSlot.Plunder.MaxBet", nil) color:[UIColor colorWithRed:.45 green:.28 blue:.08 alpha:1] action:@selector(maxBet)];
    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[self.betButton, self.maxButton]]; controls.axis = UILayoutConstraintAxisHorizontal; controls.distribution = UIStackViewDistributionFillEqually; controls.spacing = 8;
    self.spinButton = [self control:NSLocalizedString(@"BRSlot.Control.Spin", nil) color:[UIColor colorWithRed:.72 green:.10 blue:.16 alpha:1] action:@selector(spin)]; self.spinButton.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBlack];
    for (UIView *view in @[title, self.balanceLabel, self.bonusLabel, self.machineView, self.messageLabel, controls, self.spinButton]) { view.translatesAutoresizingMaskIntoConstraints = NO; [content addSubview:view]; }
    [NSLayoutConstraint activateConstraints:@[
      [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
      [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor], [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor], [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor], [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor], [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
      [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:12], [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12], [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
      [self.balanceLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8], [self.balanceLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
      [self.bonusLabel.topAnchor constraintEqualToAnchor:self.balanceLabel.bottomAnchor constant:10], [self.bonusLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16], [self.bonusLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16], [self.bonusLabel.heightAnchor constraintEqualToConstant:38],
      [self.machineView.topAnchor constraintEqualToAnchor:self.bonusLabel.bottomAnchor constant:12], [self.machineView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16], [self.machineView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16], [self.machineView.heightAnchor constraintEqualToAnchor:self.machineView.widthAnchor multiplier:.67],
      [columns.topAnchor constraintEqualToAnchor:self.machineView.topAnchor constant:12], [columns.bottomAnchor constraintEqualToAnchor:self.machineView.bottomAnchor constant:-12], [columns.leadingAnchor constraintEqualToAnchor:self.machineView.leadingAnchor constant:12], [columns.trailingAnchor constraintEqualToAnchor:self.machineView.trailingAnchor constant:-12],
      [self.bonusTint.topAnchor constraintEqualToAnchor:self.machineView.topAnchor], [self.bonusTint.bottomAnchor constraintEqualToAnchor:self.machineView.bottomAnchor], [self.bonusTint.leadingAnchor constraintEqualToAnchor:self.machineView.leadingAnchor], [self.bonusTint.trailingAnchor constraintEqualToAnchor:self.machineView.trailingAnchor],
      [self.messageLabel.topAnchor constraintEqualToAnchor:self.machineView.bottomAnchor constant:12], [self.messageLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16], [self.messageLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16], [self.messageLabel.heightAnchor constraintGreaterThanOrEqualToConstant:38],
      [controls.topAnchor constraintEqualToAnchor:self.messageLabel.bottomAnchor constant:8], [controls.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16], [controls.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16], [controls.heightAnchor constraintEqualToConstant:54],
      [self.spinButton.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:9], [self.spinButton.leadingAnchor constraintEqualToAnchor:controls.leadingAnchor], [self.spinButton.trailingAnchor constraintEqualToAnchor:controls.trailingAnchor], [self.spinButton.heightAnchor constraintEqualToConstant:50], [self.spinButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16]
    ]];
}
- (void)setSymbol:(NSString *)symbol onTile:(UIImageView *)tile {
    tile.accessibilityIdentifier = symbol;
    [[tile viewWithTag:77] removeFromSuperview]; tile.image = nil;
    UIImage *art = [BRPlunderBayViewController plunderSymbolImage:symbol];
    if (art) { tile.image = art; tile.contentMode = UIViewContentModeScaleAspectFill; return; }
    UILabel *glyph = [UILabel new]; glyph.tag = 77; glyph.text = [[symbol substringToIndex:1] uppercaseString];
    glyph.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBlack]; glyph.textColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1];
    glyph.textAlignment = NSTextAlignmentCenter; glyph.frame = tile.bounds; glyph.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; [tile addSubview:glyph];
}
- (NSInteger)betCoins { return PlunderBets()[self.betIndex].integerValue; }
- (void)cycleBet { if (self.spinning || self.freeSpinsRemaining) return; self.betIndex = (self.betIndex+1)%PlunderBets().count; [self.betButton setTitle:[NSString stringWithFormat:NSLocalizedString(@"BRSlot.Plunder.BetValue", nil),(long)self.betCoins] forState:UIControlStateNormal]; }
- (void)maxBet { if (self.spinning) return; if (self.freeSpinsRemaining == 0) { self.betIndex = (NSInteger)PlunderBets().count-1; [self.betButton setTitle:[NSString stringWithFormat:NSLocalizedString(@"BRSlot.Plunder.BetValue", nil),(long)self.betCoins] forState:UIControlStateNormal]; } [self spin]; }

- (void)refreshState {
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) { if (!self.spinning) self.balanceLabel.text = [NSString stringWithFormat:NSLocalizedString(@"BRSlot.Balance.Value", nil),(long)balance]; }];
    [self request:@{@"action":@"status"} completion:^(NSDictionary *result, NSString *error) {
        if (self.spinning) return;
        if (error) { self.messageLabel.text = error; return; }
        self.freeSpinsRemaining = [result[@"free_spins_remaining"] integerValue];
        if (self.freeSpinsRemaining > 0) {
            NSInteger found = [PlunderBets() indexOfObject:result[@"bet_coins"]]; if (found != NSNotFound) self.betIndex = found;
            [self.betButton setTitle:[NSString stringWithFormat:NSLocalizedString(@"BRSlot.Plunder.BetValue", nil),(long)self.betCoins] forState:UIControlStateNormal];
        }
        [self updateBonusLabel];
    }];
}
- (void)updateBonusLabel {
    self.bonusLabel.text = self.freeSpinsRemaining > 0 ? [NSString stringWithFormat:NSLocalizedString(@"BRSlot.Plunder.FreeSpinsRemaining", nil),(long)self.freeSpinsRemaining] : NSLocalizedString(@"BRSlot.Plunder.ScatterReward", nil);
    self.betButton.enabled = self.maxButton.enabled = self.freeSpinsRemaining == 0 && !self.spinning;
    [self applyBonusPresentation:self.freeSpinsRemaining > 0];
}
// Bonus light show: while free spins are live the cabinet flashes
// like a jackpot light - border strobing gold/red, the gold glow
// pulsing, and the dark reel tint breathing. Impossible to miss,
// which is the point. Idempotent: applyBonusPresentation: runs on
// every state refresh.
- (void)startBonusLights {
    if (self.bonusLightsRunning) return;
    self.bonusLightsRunning = YES;
    self.machineView.layer.borderWidth = 3;
    self.machineView.layer.borderColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1].CGColor;
    CABasicAnimation *border = [CABasicAnimation animationWithKeyPath:@"borderColor"];
    border.fromValue = (id)[UIColor colorWithRed:1 green:.78 blue:.18 alpha:1].CGColor;
    border.toValue = (id)[UIColor colorWithRed:1 green:.15 blue:.1 alpha:1].CGColor;
    border.duration = .45; border.autoreverses = YES; border.repeatCount = HUGE_VALF;
    [self.machineView.layer addAnimation:border forKey:@"bonusBorderFlash"];
    CABasicAnimation *glow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    glow.fromValue = @(.3); glow.toValue = @(1.0); glow.duration = .45; glow.autoreverses = YES; glow.repeatCount = HUGE_VALF;
    [self.machineView.layer addAnimation:glow forKey:@"bonusGlowPulse"];
    CABasicAnimation *glowR = [CABasicAnimation animationWithKeyPath:@"shadowRadius"];
    glowR.fromValue = @(12); glowR.toValue = @(32); glowR.duration = .45; glowR.autoreverses = YES; glowR.repeatCount = HUGE_VALF;
    [self.machineView.layer addAnimation:glowR forKey:@"bonusGlowRadius"];
    [UIView animateWithDuration:.45 delay:0 options:UIViewAnimationOptionRepeat|UIViewAnimationOptionAutoreverse|UIViewAnimationOptionAllowUserInteraction animations:^{ self.bonusTint.alpha = .08; } completion:nil];
}
- (void)stopBonusLights {
    self.bonusLightsRunning = NO;
    [self.machineView.layer removeAnimationForKey:@"bonusBorderFlash"];
    [self.machineView.layer removeAnimationForKey:@"bonusGlowPulse"];
    [self.machineView.layer removeAnimationForKey:@"bonusGlowRadius"];
    self.machineView.layer.borderWidth = 0;
    [self.bonusTint.layer removeAllAnimations];
    self.bonusTint.alpha = 1;
}
// Free spins play themselves: after a settle (or upon returning to
// the machine mid-bonus), the next bonus spin fires on its own after
// a short beat while any remain. Leaving the screen cancels the
// chain via the token.
- (void)scheduleBonusAutoSpin {
    if (self.freeSpinsRemaining == 0 || self.spinning) return;
    NSUInteger token = ++self.autoSpinToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.15*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if (self.autoSpinToken != token || self.spinning || self.freeSpinsRemaining == 0 || !self.view.window) return;
        [self spin];
    });
}
- (void)applyBonusPresentation:(BOOL)bonus {
    self.inBonus = bonus;
    self.bonusTint.hidden = !bonus;
    self.machineView.backgroundColor = bonus ? [UIColor colorWithRed:.015 green:.025 blue:.07 alpha:1] : [UIColor colorWithRed:.05 green:.09 blue:.22 alpha:1];
    self.machineView.layer.shadowColor = [UIColor colorWithRed:1 green:.75 blue:.2 alpha:1].CGColor;
    self.machineView.layer.shadowOpacity = bonus ? .85 : 0;
    self.machineView.layer.shadowRadius = 18;
    self.machineView.layer.shadowOffset = CGSizeZero;
    if (bonus) [self startBonusLights]; else [self stopBonusLights];
    if (bonus) { [self stopAmbience]; [self startBonusSong]; } else { [self.songNode pause]; [self startAmbience]; }
}
- (void)request:(NSDictionary *)payload completion:(void (^)(NSDictionary *, NSString *))completion {
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *authError) {
        if (!token) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,NSLocalizedString(@"BRSlot.Plunder.SignIn", nil)); }); return; }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/ez-plunder-spin"]]];
        request.HTTPMethod = @"POST"; request.timeoutInterval = 25;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@",token] forHTTPHeaderField:@"Authorization"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSDictionary *result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result, networkError.localizedDescription ?: result[@"reason"] ?: result[@"error"]); });
        }] resume];
    }];
}
- (void)spin {
    if (self.spinning) { [self slamStop]; return; }
    self.spinning = YES; self.maxButton.enabled = NO; [self updateBonusLabel]; // spin button stays enabled: a second tap slam-stops the spin
    [self.winOverlay removeFromSuperview]; self.winOverlay=nil; self.celebrating=NO;
    [self clearLineHighlights];
    self.messageLabel.text = self.freeSpinsRemaining ? NSLocalizedString(@"BRSlot.Plunder.FreeSpin", nil) : NSLocalizedString(@"BRSlot.CheckingBalance", nil);
    if (self.freeSpinsRemaining > 0) { [self beginSpin]; return; }
    NSInteger wager = self.betCoins;
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        self.balanceLabel.text = [NSString stringWithFormat:NSLocalizedString(@"BRSlot.Balance.Value", nil),(long)balance];
        if (balance < wager) { [self finishWithError:[NSString stringWithFormat:NSLocalizedString(@"BRSlot.Plunder.NeedCoins", nil),(long)wager]]; [self showCoinStore]; return; }
        [self beginSpin];
    }];
}
- (void)beginSpin {
    self.slamRequested = NO; self.pendingSpinResult = nil; self.spinSettled = NO;
    self.messageLabel.text = NSLocalizedString(@"BRSlot.Spinning", nil); NSUInteger animationID = ++self.animationID;
    NSMutableArray *before = [NSMutableArray arrayWithCapacity:5];
    for (NSArray<UIImageView *> *column in self.reels) { NSMutableArray *symbols = [NSMutableArray arrayWithCapacity:3]; for (UIImageView *tile in column) [symbols addObject:tile.accessibilityIdentifier ?: @"hook"]; [before addObject:symbols]; }
    self.preSpinBoard = before;
    [self startReelsSound]; [self playWhoosh];
    for (NSInteger tick=0;tick<5;tick++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(tick*.11*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ if (!self.spinning || self.animationID != animationID) return; for (NSArray *col in self.reels) for (UIImageView *tile in col) [self setSymbol:PlunderSymbols()[arc4random_uniform((uint32_t)PlunderSymbols().count)] onTile:tile]; });
    [self request:@{@"bet_coins":@(self.betCoins)} completion:^(NSDictionary *result, NSString *error) {
        if (error || ![result[@"reels"] isKindOfClass:NSArray.class]) { [self finishWithError:error ?: @"Spin failed; balance unchanged."]; [self refreshState]; if ([error.localizedLowercaseString containsString:@"insufficient"]) [self showCoinStore]; return; }
        [self reveal:result];
    }];
}
// Columns land one at a time. Each chest that lands booms — the first
// at base pitch, every next one +3 semitones — and the second chest
// starts the drum roll, which runs until the last column settles.
// Three or more chests ring the bells into the bonus.
// Slam stop: a second tap on Spin while a spin is running. If the
// result is already revealing, jump straight to the settled board;
// if it has not landed yet, the flag makes reveal: jump on entry.
// The celebrations all still run (they live in settleSpin:) - only
// the staged column landings and the drum roll are skipped.
- (void)slamStop {
    if (!self.spinning) return;
    self.slamRequested = YES;
    ++self.animationID; // freeze the shuffle ticks / staged blocks now
    if (self.pendingSpinResult) [self jumpToSettledBoard];
}
- (void)jumpToSettledBoard {
    NSDictionary *result = self.pendingSpinResult;
    if (!result || self.spinSettled) return;
    self.spinSettled = YES;
    ++self.animationID;
    [self stopDrumRoll]; [self stopReelsSound];
    NSArray *columns = result[@"reels"];
    for (NSInteger col=0;col<5;col++) for (NSInteger row=0;row<3;row++) {
        NSString *sym = columns[col][row];
        UIImageView *tile = self.reels[col][row];
        [self setSymbol:sym onTile:tile];
        if ([sym isEqualToString:@"scatter"]) { tile.layer.borderWidth = 3; tile.layer.borderColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1].CGColor; }
    }
    [self settleSpin:result];
}
- (void)reveal:(NSDictionary *)result {
    NSArray *columns = result[@"reels"];
    if (columns.count != 5) { [self finishWithError:NSLocalizedString(@"BRSlot.Error.InvalidSpin", nil)]; return; }
    for (NSArray *column in columns) if (![column isKindOfClass:NSArray.class] || column.count != 3) { [self finishWithError:NSLocalizedString(@"BRSlot.Error.InvalidSpin", nil)]; return; }
    self.preSpinBoard = nil;
    self.pendingSpinResult = result;
    self.spinSettled = NO;
    NSUInteger revealID = ++self.animationID;
    self.scatterStep = 0;
    if (self.slamRequested) { [self jumpToSettledBoard]; return; }
    for (NSInteger col=0;col<5;col++) {
        NSArray *symbols=columns[col];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(col*.24*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if (self.animationID != revealID || self.spinSettled) return;
            for (NSInteger row=0;row<3;row++) [self setSymbol:symbols[row] onTile:self.reels[col][row]];
            for (NSInteger row=0;row<3;row++) {
                if (![symbols[row] isEqualToString:@"scatter"]) continue;
                UIImageView *tile = self.reels[col][row];
                tile.layer.borderWidth = 3; tile.layer.borderColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1].CGColor;
                [UIView animateWithDuration:.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{ tile.transform=CGAffineTransformMakeScale(1.18,1.18); } completion:^(__unused BOOL done){ [UIView animateWithDuration:.4 delay:0 usingSpringWithDamping:.5 initialSpringVelocity:.3 options:0 animations:^{ tile.transform=CGAffineTransformIdentity; } completion:nil]; }];
                [self playBoomAtStep:self.scatterStep];
                self.scatterStep++;
                if (self.scatterStep == 2) [self startDrumRoll];
            }
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.45*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if (self.animationID != revealID || self.spinSettled) return;
        self.spinSettled = YES;
        [self settleSpin:result];
    });
}
// Everything after the reels land, shared by the timed reveal above
// and the slam-stop jump: balances, win lines, and the celebrations
// (bells, cannon, coins, win banner) all still run.
- (void)settleSpin:(NSDictionary *)result {
        [self stopDrumRoll]; [self stopReelsSound];
        NSInteger payout=[result[@"payout"] integerValue],balance=[result[@"balance"] integerValue],awarded=[result[@"free_spins_awarded"] integerValue],scatters=[result[@"scatter_count"] integerValue];
        if (scatters >= 3) [self playBells];
        self.freeSpinsRemaining=[result[@"free_spins_remaining"] integerValue]; [self updateBonusLabel];
        BOOL wasFreeSpin=[result[@"was_free_spin"] boolValue];
        if (wasFreeSpin) self.freeSpinSessionTotal+=payout;
        [EZEntitlementManager.shared applyKnownBalance:balance]; self.balanceLabel.text=[NSString stringWithFormat:NSLocalizedString(@"BRSlot.Balance.Value", nil),(long)balance];
        NSMutableArray *winLines=[NSMutableArray array];
        for (NSDictionary *line in result[@"winning_lines"]) { if (![line isKindOfClass:NSDictionary.class]) continue; NSArray *rows=[line[@"rows"] isKindOfClass:NSArray.class]?line[@"rows"]:@[]; NSInteger matches=MIN([line[@"matches"] integerValue],5); NSMutableArray *coords=[NSMutableArray array]; for (NSInteger col=0;col<matches && col<(NSInteger)rows.count;col++) { NSInteger row=[rows[col] integerValue]; if (row>=0 && row<3) [coords addObject:@[@(col),@(row)]]; } if (coords.count) [winLines addObject:coords]; }
        // Cannon celebration: a winning line paying 3+ cannons
        // (wilds count toward the run) fires the cannon.
        NSArray *settleColumns = result[@"reels"];
        BOOL cannonLine = NO;
        for (NSArray *coords in winLines) {
            if (coords.count < 3) continue;
            NSString *paySymbol = nil;
            for (NSArray *coord in coords) {
                id raw = settleColumns[[coord[0] integerValue]][[coord[1] integerValue]];
                NSString *sym = [raw isKindOfClass:NSString.class] ? raw : nil;
                if (sym && ![sym isEqualToString:@"wild"]) { paySymbol = sym; break; }
            }
            if (!paySymbol && coords.count < 5) {
                NSArray *last = coords.lastObject; NSInteger nextCol = [last[0] integerValue] + 1;
                if (nextCol < 5) { id raw = settleColumns[nextCol][[last[1] integerValue]]; if ([raw isKindOfClass:NSString.class] && ![raw isEqualToString:@"wild"]) paySymbol = raw; }
            }
            if ([paySymbol isEqualToString:@"cannon"]) { cannonLine = YES; break; }
        }
        if (cannonLine) [self playCannon];
        if (winLines.count) [self celebrateWinLines:winLines step:0 passes:(winLines.count<=2?3:winLines.count<=4?2:1) celebrationID:self.lineCelebrationID];
        self.messageLabel.text = awarded ? [NSString stringWithFormat:@"🧭 +%ld FREE SPINS! %@",(long)awarded,payout ? [NSString stringWithFormat:@"Won %ld coins",(long)payout] : @""] : payout ? [NSString stringWithFormat:@"🎉 Won %ld coins on %@ line%@",(long)payout,result[@"win_lines"],[result[@"win_lines"] integerValue]==1?@"":@"s"] : [result[@"was_free_spin"] boolValue] ? @"Free spin • no line win" : [NSString stringWithFormat:@"No win • −%@ coins",result[@"wager"]];
        self.messageLabel.textColor=(payout || awarded) ? UIColor.systemYellowColor : [UIColor colorWithWhite:.8 alpha:1];
        if (payout > 0) [self playCoins];
        if (payout || awarded) [self showWin:payout awarded:awarded];
        self.pendingSpinResult = nil;
        self.spinning=NO; self.spinButton.enabled=self.maxButton.enabled=YES; [self updateBonusLabel];
        if (balance==0 && self.freeSpinsRemaining==0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self showCoinStore]; });
        if (wasFreeSpin && self.freeSpinsRemaining==0 && self.freeSpinSessionTotal>0) { NSInteger total=self.freeSpinSessionTotal; self.freeSpinSessionTotal=0; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.75*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self showFreeSpinsComplete:total]; }); }
        [self scheduleBonusAutoSpin];
}
- (void)clearLineHighlights { self.lineCelebrationID++; for (NSArray *col in self.reels) for (UIImageView *tile in col) { [tile.layer removeAllAnimations]; tile.transform=CGAffineTransformIdentity; tile.layer.borderWidth=0; tile.layer.borderColor=nil; } }
- (void)celebrateWinLines:(NSArray *)lines step:(NSInteger)step passes:(NSInteger)passes celebrationID:(NSUInteger)celebrationID {
    if (celebrationID != self.lineCelebrationID) return;
    if (step >= (NSInteger)lines.count * passes) { for (NSInteger i=0;i<(NSInteger)lines.count;i++) [self applyWinLine:lines[i] index:i celebrate:NO]; return; }
    for (NSArray *col in self.reels) for (UIImageView *tile in col) { tile.layer.borderWidth=0; tile.layer.borderColor=nil; tile.transform=CGAffineTransformIdentity; }
    NSInteger lineIndex = step % (NSInteger)lines.count;
    [self applyWinLine:lines[lineIndex] index:lineIndex celebrate:YES];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self celebrateWinLines:lines step:step+1 passes:passes celebrationID:celebrationID]; });
}
- (void)applyWinLine:(NSArray *)coords index:(NSInteger)index celebrate:(BOOL)celebrate {
    NSArray *palette=@[ @[@1.0,@0.77,@0.08], @[@1.0,@0.25,@0.55], @[@0.15,@0.85,@1.0], @[@0.35,@1.0,@0.55], @[@0.72,@0.45,@1.0] ];
    NSArray *rgb=palette[index%(NSInteger)palette.count];
    UIColor *border=[UIColor colorWithRed:[rgb[0] doubleValue] green:[rgb[1] doubleValue] blue:[rgb[2] doubleValue] alpha:1];
    for (NSArray *coord in coords) { UIImageView *tile=self.reels[[coord[0] integerValue]][[coord[1] integerValue]]; tile.layer.borderWidth=3; tile.layer.borderColor=border.CGColor; if (!celebrate) continue; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)([coord[0] integerValue]*.13*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [UIView animateWithDuration:.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{ tile.transform=CGAffineTransformMakeScale(1.22,1.22); } completion:^(__unused BOOL done){ [UIView animateWithDuration:.5 delay:0 usingSpringWithDamping:.5 initialSpringVelocity:.35 options:0 animations:^{ tile.transform=CGAffineTransformIdentity; } completion:nil]; }]; }); }
}
- (void)finishWithError:(NSString *)message { ++self.animationID; [self stopDrumRoll]; [self stopReelsSound]; self.pendingSpinResult = nil; self.slamRequested = NO; [self clearLineHighlights]; if (self.preSpinBoard.count == 5) { for (NSInteger col=0;col<5;col++) for (NSInteger row=0;row<3;row++) [self setSymbol:self.preSpinBoard[col][row] onTile:self.reels[col][row]]; self.preSpinBoard=nil; } self.spinning=NO; self.spinButton.enabled=self.maxButton.enabled=YES; [self updateBonusLabel]; self.messageLabel.text=message; self.messageLabel.textColor=UIColor.systemOrangeColor; }
- (void)showCoinStore {
    if (self.presentedViewController) return;
    EZCoinStoreViewController *store=[EZCoinStoreViewController new]; store.showLowCoinsWarning=YES; store.triggeringFeatureName=NSLocalizedString(@"BRSlot.Plunder.StoreFeature", nil);
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:store]; nav.modalPresentationStyle=UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}
// Audio. Every lookup tolerates a missing file: the hook goes silent
// until the generated sound is dropped into Resources/sounds.
- (NSURL *)soundURL:(NSString *)name {
    NSURL *url=[[NSBundle mainBundle] URLForResource:name withExtension:@"mp3" subdirectory:@"sounds"];
    if (!url) url=[[NSBundle mainBundle] URLForResource:name withExtension:@"mp3"];
    return url;
}
- (void)setupAudio {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
    NSURL *boomURL = [self soundURL:@"pb_boom"];
    if (boomURL) {
        self.boomFile = [[AVAudioFile alloc] initForReading:boomURL error:nil];
        self.sfxEngine = [AVAudioEngine new];
        self.boomNode = [AVAudioPlayerNode new];
        self.boomNode.volume = .35;
        self.boomSpeed = [AVAudioUnitVarispeed new];
        [self.sfxEngine attachNode:self.boomNode];
        [self.sfxEngine attachNode:self.boomSpeed];
        [self.sfxEngine connect:self.boomNode to:self.boomSpeed format:self.boomFile.processingFormat];
        [self.sfxEngine connect:self.boomSpeed to:self.sfxEngine.mainMixerNode format:self.boomFile.processingFormat];
        [self.sfxEngine prepare];
    }
    NSURL *drumURL = [self soundURL:@"pb_drumroll"];
    if (drumURL) { AVAudioPCMBuffer *b = nil; AVAudioMixerNode *m = nil; self.drumNode = [self plunderLoopNodeForURL:drumURL volume:.8 gain:1.0 buffer:&b mixer:&m]; self.drumBuffer = b; self.drumMixer = m; }
    NSURL *bellsURL = [self soundURL:@"pb_bells"];
    if (bellsURL) { self.bellsPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:bellsURL error:nil]; self.bellsPlayer.volume = .9; [self.bellsPlayer prepareToPlay]; }
    NSURL *coinsURL = [self soundURL:@"pb_coins"];
    if (coinsURL) { self.coinsPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:coinsURL error:nil]; self.coinsPlayer.volume = .7; [self.coinsPlayer prepareToPlay]; }
    NSURL *whooshURL = [self soundURL:@"pb_whoosh"];
    if (whooshURL) { self.whooshPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:whooshURL error:nil]; self.whooshPlayer.volume = .6; [self.whooshPlayer prepareToPlay]; }
    NSURL *cannonURL = [[NSBundle mainBundle] URLForResource:@"pb_cannon" withExtension:@"caf" subdirectory:@"sounds"];
    if (!cannonURL) cannonURL = [[NSBundle mainBundle] URLForResource:@"pb_cannon" withExtension:@"caf"];
    if (!cannonURL) cannonURL = [self soundURL:@"pb_cannon"];
    if (cannonURL) { self.cannonPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:cannonURL error:nil]; self.cannonPlayer.volume = .9; [self.cannonPlayer prepareToPlay]; }
    NSURL *reelsURL = [[NSBundle mainBundle] URLForResource:@"pb_slot_reels" withExtension:@"caf" subdirectory:@"sounds"];
    if (!reelsURL) reelsURL = [[NSBundle mainBundle] URLForResource:@"pb_slot_reels" withExtension:@"caf"];
    if (!reelsURL) reelsURL = [self soundURL:@"pb_slot_reels"];
    if (reelsURL) { self.reelsPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:reelsURL error:nil]; self.reelsPlayer.numberOfLoops = -1; self.reelsPlayer.volume = .7; [self.reelsPlayer prepareToPlay]; }
    NSURL *ambienceURL = [self soundURL:@"pb_ambience"];
    if (ambienceURL) { AVAudioPCMBuffer *b = nil; AVAudioMixerNode *m = nil; self.ambienceNode = [self plunderLoopNodeForURL:ambienceURL volume:1.0 gain:2.0 buffer:&b mixer:&m]; self.ambienceBuffer = b; self.ambienceMixer = m; }
    NSURL *songURL = [self soundURL:@"pb_bonus_song"];
    if (songURL) { AVAudioPCMBuffer *b = nil; AVAudioMixerNode *m = nil; self.songNode = [self plunderLoopNodeForURL:songURL volume:.32 gain:1.0 buffer:&b mixer:&m]; self.songBuffer = b; self.songMixer = m; }
}
// Gapless loops: decode the whole file to a PCM buffer and schedule
// it on a player node with BufferLoops. AVAudioPlayer looping
// replays the compressed file's priming/padding samples as a silence
// gap at every wrap (very audible on a continuous ambience); a PCM
// buffer loops sample-accurately. Each loop gets its own mixer so the
// volumes stay independent.
- (AVAudioPlayerNode *)plunderLoopNodeForURL:(NSURL *)url volume:(float)volume gain:(float)gain buffer:(AVAudioPCMBuffer **)outBuffer mixer:(AVAudioMixerNode **)outMixer {
    if (!url) return nil;
    // A missing, corrupt or mislabeled sound file must never take the
    // screen down: AVAudioFile / buffer creation throw on bad input
    // where AVAudioPlayer simply returned nil. The whole build sits in
    // @try — any failure leaves this loop silent, like every other
    // sound hook, instead of crashing the machine on open.
    @try {
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:nil];
    if (!file || file.length == 0) return nil;
    AVAudioFormat *format = file.processingFormat;
    if (!format || format.sampleRate <= 0 || format.channelCount == 0) return nil;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)file.length];
    if (!buffer || ![file readIntoBuffer:buffer error:nil] || buffer.frameLength == 0) return nil;
    // Trim trailing digital silence before looping: for VBR files
    // without a packet table (AAC/MP3 in a .caf), the declared length
    // can overstate the real audio and the decode zero-pads the tail,
    // which then loops as a silent gap. Healthy files are untouched.
    if (buffer.format.commonFormat == AVAudioPCMFormatFloat32 && !buffer.format.interleaved && buffer.floatChannelData) {
        AVAudioFrameCount frames = buffer.frameLength;
        float * const *channels = buffer.floatChannelData;
        NSUInteger channelCount = buffer.format.channelCount;
        while (frames > 0) {
            BOOL silent = YES;
            for (NSUInteger c = 0; c < channelCount; c++) {
                if (fabsf(channels[c][frames - 1]) > 0.0005f) { silent = NO; break; }
            }
            if (!silent) break;
            frames--;
        }
        buffer.frameLength = frames;
    }
    // Decode-time gain for quiet source files (the ambience wash is
    // mastered low, and a mixer alone caps at unity): scale the
    // samples with a hard clamp so peaks cannot wrap.
    if (gain != 1.0f && buffer.format.commonFormat == AVAudioPCMFormatFloat32 && !buffer.format.interleaved && buffer.floatChannelData) {
        float * const *gch = buffer.floatChannelData;
        NSUInteger gChannels = buffer.format.channelCount;
        for (NSUInteger c = 0; c < gChannels; c++) {
            float *samples = gch[c];
            for (AVAudioFrameCount f = 0; f < buffer.frameLength; f++) {
                float v = samples[f] * gain;
                samples[f] = v > 1.0f ? 1.0f : (v < -1.0f ? -1.0f : v);
            }
        }
    }
    if (buffer.frameLength == 0) return nil;
    // Ride the boom SFX engine when it exists: a second engine in
    // this screen threw inside graph Initialize on open (crash log
    // 2026-11-13). One engine per screen, and no prepare anywhere -
    // start initializes the graph on first play.
    AVAudioEngine *engine = self.sfxEngine;
    if (!engine) { if (!self.loopEngine) self.loopEngine = [AVAudioEngine new]; engine = self.loopEngine; }
    AVAudioPlayerNode *node = [AVAudioPlayerNode new];
    AVAudioMixerNode *mixer = [AVAudioMixerNode new];
    [engine attachNode:node];
    [engine attachNode:mixer];
    [engine connect:node to:mixer format:file.processingFormat];
    [engine connect:mixer to:engine.mainMixerNode format:file.processingFormat];
    mixer.outputVolume = volume;
    [node scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    if (outBuffer) *outBuffer = buffer;
    if (outMixer) *outMixer = mixer;
    return node;
    } @catch (NSException *e) {
        return nil;
    }
}
- (void)plunderStartLoopNode:(AVAudioPlayerNode *)node {
    if (!node || node.isPlaying) return;
    @try {
        AVAudioEngine *engine = self.sfxEngine ?: self.loopEngine;
        if (engine && !engine.isRunning) [engine startAndReturnError:nil];
        [node play];
    } @catch (NSException *e) {
        // A loop that cannot start stays silent; the game plays on.
    }
}
- (void)playBoomAtStep:(NSInteger)step {
    if (!self.boomFile || !self.sfxEngine) return;
    if (!self.sfxEngine.running) [self.sfxEngine startAndReturnError:nil];
    self.boomSpeed.rate = powf(2.0f, (float)(step * 3) / 12.0f); // +3 semitones per chest
    [self.boomNode stop];
    [self.boomNode scheduleFile:self.boomFile atTime:nil completionHandler:nil];
    [self.boomNode play];
}
- (void)playCannon { if (self.cannonPlayer) { [self.cannonPlayer stop]; self.cannonPlayer.currentTime = 0; [self.cannonPlayer play]; } }
- (void)playWhoosh { if (self.whooshPlayer) { [self.whooshPlayer stop]; self.whooshPlayer.currentTime = 0; [self.whooshPlayer play]; } }
- (void)startReelsSound { if (self.reelsPlayer && !self.reelsPlayer.isPlaying) { self.reelsPlayer.currentTime = 0; [self.reelsPlayer play]; } }
- (void)stopReelsSound { [self.reelsPlayer stop]; }
- (void)startDrumRoll { if (!self.drumNode || !self.drumBuffer) return; [self.drumNode stop]; [self.drumNode scheduleBuffer:self.drumBuffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil]; [self plunderStartLoopNode:self.drumNode]; }
- (void)stopDrumRoll { [self.drumNode stop]; }
- (void)playBells { if (self.bellsPlayer) { self.bellsPlayer.currentTime = 0; [self.bellsPlayer play]; } }
- (void)playCoins { if (self.coinsPlayer) { self.coinsPlayer.currentTime = 0; [self.coinsPlayer play]; } }
- (void)startAmbience { if (self.inBonus || !self.view.window) return; [self plunderStartLoopNode:self.ambienceNode]; }
- (void)stopAmbience { [self.ambienceNode pause]; }
- (void)startBonusSong { [self plunderStartLoopNode:self.songNode]; }
- (void)showWin:(NSInteger)payout awarded:(NSInteger)awarded {
    UIView *overlay=[[UIView alloc] initWithFrame:self.view.bounds]; overlay.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; overlay.userInteractionEnabled=NO; self.winOverlay=overlay; self.celebrating=YES; [self.view addSubview:overlay];
    UIView *card=[[UIView alloc] initWithFrame:CGRectMake(22,CGRectGetMinY(self.view.safeAreaLayoutGuide.layoutFrame)+8,self.view.bounds.size.width-44,82)]; card.backgroundColor=[UIColor colorWithRed:.03 green:.05 blue:.14 alpha:.96]; card.layer.cornerRadius=18; card.layer.borderWidth=2; card.layer.borderColor=UIColor.systemYellowColor.CGColor; [overlay addSubview:card];
    UILabel *text=[UILabel new]; text.text=awarded ? [NSString stringWithFormat:@"🧭 %ld FREE SPINS%@",(long)awarded,payout?[NSString stringWithFormat:@"  +%ld COINS",(long)payout]:@""] : [NSString stringWithFormat:@"WINNER!  +%ld COINS",(long)payout]; text.numberOfLines=2; text.font=[UIFont systemFontOfSize:21 weight:UIFontWeightBlack]; text.textColor=UIColor.systemYellowColor; text.textAlignment=NSTextAlignmentCenter; text.frame=card.bounds; text.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; [card addSubview:text];
    [self coinWave:overlay];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ if (self.winOverlay==overlay) { self.celebrating=NO; [overlay removeFromSuperview]; self.winOverlay=nil; } });
}
- (void)showFreeSpinsComplete:(NSInteger)total {
    UIView *overlay=[[UIView alloc] initWithFrame:self.view.bounds]; overlay.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; overlay.userInteractionEnabled=NO; self.winOverlay=overlay; self.celebrating=YES; [self.view addSubview:overlay];
    UIView *card=[[UIView alloc] initWithFrame:CGRectMake(22,CGRectGetMinY(self.view.safeAreaLayoutGuide.layoutFrame)+8,self.view.bounds.size.width-44,82)]; card.backgroundColor=[UIColor colorWithRed:.03 green:.05 blue:.14 alpha:.96]; card.layer.cornerRadius=18; card.layer.borderWidth=2; card.layer.borderColor=UIColor.systemYellowColor.CGColor; [overlay addSubview:card];
    UILabel *text=[UILabel new]; text.text=[NSString stringWithFormat:@"⚓ FREE SPINS COMPLETE!\nTOTAL WON  +%ld COINS",(long)total]; text.numberOfLines=2; text.font=[UIFont systemFontOfSize:21 weight:UIFontWeightBlack]; text.textColor=UIColor.systemYellowColor; text.textAlignment=NSTextAlignmentCenter; text.frame=card.bounds; text.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; [card addSubview:text];
    [self coinWave:overlay];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ if (self.winOverlay==overlay) { self.celebrating=NO; [overlay removeFromSuperview]; self.winOverlay=nil; } });
}
- (void)coinWave:(UIView *)overlay { if (!self.celebrating || overlay!=self.winOverlay) return; UIImage *coin=[UIImage imageNamed:@"EZCoin"]; CGFloat baseX=CGRectGetMidX(overlay.bounds),bottom=CGRectGetMaxY(overlay.bounds)-40; for (NSInteger i=0;i<24;i++) { UIImageView *particle=[[UIImageView alloc] initWithImage:coin]; particle.frame=CGRectMake(baseX,bottom,20,20); [overlay insertSubview:particle atIndex:0]; CGFloat x=baseX+(NSInteger)arc4random_uniform(300)-150,y=100+arc4random_uniform(250); [UIView animateWithDuration:1.1 delay:arc4random_uniform(12)/100.0 options:0 animations:^{ particle.center=CGPointMake(x,y); particle.alpha=0; } completion:^(__unused BOOL done){ [particle removeFromSuperview]; }]; } dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.05*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self coinWave:overlay]; }); }
- (void)showOdds {
    UIViewController *sheet=[UIViewController new]; sheet.view.backgroundColor=[UIColor colorWithRed:.03 green:.05 blue:.13 alpha:1]; sheet.modalPresentationStyle=UIModalPresentationPageSheet; sheet.sheetPresentationController.prefersGrabberVisible=YES; sheet.sheetPresentationController.detents=@[[UISheetPresentationControllerDetent mediumDetent],[UISheetPresentationControllerDetent largeDetent]];
    UITextView *text=[UITextView new]; text.editable=NO; text.selectable=NO; text.backgroundColor=UIColor.clearColor; text.textColor=UIColor.whiteColor; text.font=[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium]; text.textContainerInset=UIEdgeInsetsMake(24,18,28,18); text.translatesAutoresizingMaskIntoConstraints=NO; [sheet.view addSubview:text];
    text.text=@"PLUNDER BAY PAYOUTS\n\nAll 20 lines are always active. 3, 4, or 5 consecutive symbols from the left on a line pay, as multiples of your total bet:\n\n👑 Captain    4× / 16× / 80×\n⛵ Galleon    3× / 12× / 60×\n🗺 Map        2.5× / 8× / 40×\n💣 Cannon     2× / 6× / 30×\n🦜 Parrot     1.5× / 5× / 25×\n⚓ Anchor     1× / 4× / 20×\n🧭 Compass    1× / 3× / 16×\n🍾 Rum        1× / 2.5× / 12×\n🪙 Doubloon   1× / 2× / 10×\n🪝 Hook       0.5× / 1.5× / 8×\n\n☠ The skull is wild and substitutes for every symbol except the chest.\n\n🧰 The treasure chest is a scatter — it pays anywhere and starts the bonus:\n3 chests: 2× your bet + 5–8 free spins\n4 chests: 8× your bet + 14–16 free spins\n5 chests: 40× your bet + 25–30 free spins\nA board can never show more than 5 chests.\n\nIn free spins every line win pays ×3, chest pays stay full, and chests can retrigger more free spins.\n\nTheoretical long-run RTP is about 94.4%, verified by simulating 10,000,000 spins of these exact tables; the bonus triggers about once in 158 spins. Results vary.";
    [NSLayoutConstraint activateConstraints:@[[text.topAnchor constraintEqualToAnchor:sheet.view.safeAreaLayoutGuide.topAnchor],[text.leadingAnchor constraintEqualToAnchor:sheet.view.leadingAnchor],[text.trailingAnchor constraintEqualToAnchor:sheet.view.trailingAnchor],[text.bottomAnchor constraintEqualToAnchor:sheet.view.safeAreaLayoutGuide.bottomAnchor]]];
    [self presentViewController:sheet animated:YES completion:nil];
}
@end
