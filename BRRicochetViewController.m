// BRRicochetViewController.m
// BrainRotGame
// EZCompleteUI
//
// See BRRicochetViewController.h for the overall shape and wiring notes.

#import "BRRicochetViewController.h"
#import "BRRicochetGameModel.h"
#import "BRRicochetGameView.h"
#import "BRRicochetHighScoresViewController.h"
#import "BRSynthEngine.h"
#import "BRGameLibrary.h"  // BRGameRecord lives here; .seed and -asAssetDict are all we touch
#import "BRGamePickerViewController.h"        // reused as-is — it has no idea what VC presented it
#import "BRCustomGameCreatorViewController.h" // reused as-is — same Workshop, same asset pipeline
#import "EZEntitlementManager.h"
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, BRRicochetState) {
    BRRicochetStateReady,       // sitting at the slide, waiting for Launch
    BRRicochetStateLaunching,   // manual slide-in animation in progress
    BRRicochetStatePlaying,
    BRRicochetStateGameOver
};

static const NSTimeInterval kBRRicochetLaunchAnimDuration = 0.55;
static const CGFloat        kBRRicochetSteerRateRadPerSec = 3.3;
static const CGFloat        kBRRicochetBlastRadius        = 90.0;
static const NSTimeInterval kBRRicochetBlastCooldown       = 4.2; // seconds to fully recharge

static NSString * const kBRRicochetDefaultsRoot   = @"BRRicochetSynthRootSemitone";
static NSString * const kBRRicochetDefaultsScale  = @"BRRicochetSynthScale";
static NSString * const kBRRicochetDefaultsTempo  = @"BRRicochetSynthTempoBPM";
static NSString * const kBRRicochetDefaultsMIDISync = @"BRRicochetMIDIClockEnabled";

@interface BRRicochetViewController ()

@property (nonatomic, strong) BRRicochetGameModel *model;
@property (nonatomic, strong) BRRicochetGameView  *gameView;
@property (nonatomic, strong) UIImageView *playerImageView;
@property (nonatomic, strong) UIImageView *enemyImageView;

@property (nonatomic, strong) UIButton *leftBtn;
@property (nonatomic, strong) UIButton *rightBtn;
@property (nonatomic, strong) UIButton *actionBtn;   // "Use" blast
@property (nonatomic, strong) UIButton *launchBtn;
@property (nonatomic, strong) UIButton *settingsBtn;
@property (nonatomic, strong) UIButton *pauseBtn;
@property (nonatomic, strong) UIButton *restartBtn;
@property (nonatomic, strong) UIButton *highScoresBtn;
@property (nonatomic, strong) UILabel  *scoreLabel;
@property (nonatomic, strong) UILabel  *livesLabel;
@property (nonatomic, strong) UIView   *blastChargeTrack;
@property (nonatomic, strong) UIView   *blastChargeFill;
@property (nonatomic, strong) UILabel  *gameOverLabel;

@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastFrameTime;
@property (nonatomic, assign) BRRicochetState state;

@property (nonatomic, assign) BOOL steeringLeft;
@property (nonatomic, assign) BOOL steeringRight;
@property (nonatomic, assign) BOOL isPaused;
@property (nonatomic, assign) NSTimeInterval blastCooldownRemaining; // 0 == fully charged
@property (nonatomic, assign) NSInteger currentLevel;

@property (nonatomic, strong) BRSynthEngine *synth;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, AVAudioPlayer *> *sfxPlayers;

@property (nonatomic, strong, nullable) BRGameRecord *currentGameRecord;
@property (nonatomic, strong, nullable) BRGameRecord *pendingGameRecord; // set before view loads
@property (nonatomic, assign) BOOL hasPresentedInitialFlow; // guards the one-shot picker/workshop kickoff in viewDidAppear:

@end

@implementation BRRicochetViewController

#pragma mark - Init

+ (instancetype)ricochetControllerWithGameRecord:(BRGameRecord *)record {
    BRRicochetViewController *controller = [[self alloc] init];
    controller.pendingGameRecord = record;
    return controller;
}

+ (instancetype)ricochetController {
    return [[self alloc] init];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.0 blue:0.12 alpha:1.0];

    self.synth = [[BRSynthEngine alloc] init];
    [self restoreSynthSettings];
    [self preloadSoundEffects];

    [self buildUI];

    if (self.pendingGameRecord) {
        [self loadGameRecord:self.pendingGameRecord];
        self.pendingGameRecord = nil;
    }

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(frameTick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.hasPresentedInitialFlow || self.currentGameRecord || self.pendingGameRecord) return;
    self.hasPresentedInitialFlow = YES;

    if (self.initialWorkshopImage) {
        [self showCustomWorkshopWithInitialImage:self.initialWorkshopImage];
    } else if ([self userHasMembership]) {
        [self showGamePicker];
    } else {
        [self showCustomWorkshopWithInitialImage:nil];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.synth stop];
}

- (void)dealloc {
    [_displayLink invalidate];
}

#pragma mark - UI construction

- (void)buildUI {
    self.gameView = [[BRRicochetGameView alloc] init];
    [self.view addSubview:self.gameView];

    self.playerImageView = [[UIImageView alloc] init];
    self.playerImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.playerImageView.clipsToBounds = YES;
    self.playerImageView.layer.cornerRadius = 18;
    self.playerImageView.layer.borderColor = [UIColor whiteColor].CGColor;
    self.playerImageView.layer.borderWidth = 1.5;
    [self.view addSubview:self.playerImageView];

    self.enemyImageView = [[UIImageView alloc] init];
    self.enemyImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.enemyImageView.clipsToBounds = YES;
    self.enemyImageView.layer.cornerRadius = 20;
    self.enemyImageView.layer.borderColor = [UIColor colorWithRed:1 green:0.3 blue:0.4 alpha:1].CGColor;
    self.enemyImageView.layer.borderWidth = 1.5;
    [self.view addSubview:self.enemyImageView];

    self.scoreLabel = [self makeHUDLabel];
    self.livesLabel = [self makeHUDLabel];
    [self.view addSubview:self.scoreLabel];
    [self.view addSubview:self.livesLabel];

    self.pauseBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.pauseBtn setTitle:@"⏸" forState:UIControlStateNormal];
    [self.pauseBtn setTitle:@"▶︎" forState:UIControlStateSelected];
    self.pauseBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    self.pauseBtn.tintColor = [UIColor colorWithWhite:0.88 alpha:1];
    self.pauseBtn.backgroundColor = [UIColor colorWithWhite:0.20 alpha:0.85];
    self.pauseBtn.layer.cornerRadius = 8;
    self.pauseBtn.layer.borderWidth = 0.5;
    self.pauseBtn.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.5].CGColor;
    [self.pauseBtn addTarget:self action:@selector(togglePause) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.pauseBtn];

    self.restartBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.restartBtn setTitle:@"↺" forState:UIControlStateNormal];
    self.restartBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    self.restartBtn.tintColor = [UIColor colorWithWhite:0.75 alpha:1];
    self.restartBtn.backgroundColor = [UIColor colorWithWhite:0.20 alpha:0.85];
    self.restartBtn.layer.cornerRadius = 8;
    self.restartBtn.layer.borderWidth = 0.5;
    self.restartBtn.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.5].CGColor;
    [self.restartBtn addTarget:self action:@selector(startOverAction) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.restartBtn];

    self.highScoresBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.highScoresBtn setTitle:@"🏆" forState:UIControlStateNormal];
    self.highScoresBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    self.highScoresBtn.tintColor = [UIColor systemYellowColor];
    self.highScoresBtn.backgroundColor = [UIColor colorWithWhite:0.20 alpha:0.85];
    self.highScoresBtn.layer.cornerRadius = 8;
    self.highScoresBtn.layer.borderWidth = 0.5;
    self.highScoresBtn.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.5].CGColor;
    [self.highScoresBtn addTarget:self action:@selector(showHighScores) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.highScoresBtn];

    self.leftBtn  = [self makeArrowButtonWithTitle:@"◀︎"];
    self.rightBtn = [self makeArrowButtonWithTitle:@"▶︎"];
    // Continuous-hold steering (unlike the maze's tap-to-step-once D-pad):
    // touchDown starts steering, any release/drag-out stops it.
    [self.leftBtn  addTarget:self action:@selector(leftTouchDown)  forControlEvents:UIControlEventTouchDown];
    [self.leftBtn  addTarget:self action:@selector(leftTouchUp)    forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    [self.rightBtn addTarget:self action:@selector(rightTouchDown) forControlEvents:UIControlEventTouchDown];
    [self.rightBtn addTarget:self action:@selector(rightTouchUp)   forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    [self.view addSubview:self.leftBtn];
    [self.view addSubview:self.rightBtn];

    self.actionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.actionBtn setTitle:@"⚡ USE" forState:UIControlStateNormal];
    self.actionBtn.titleLabel.font    = [UIFont boldSystemFontOfSize:15];
    self.actionBtn.tintColor          = [UIColor systemYellowColor];
    self.actionBtn.layer.cornerRadius = 8;
    self.actionBtn.layer.borderWidth  = 1;
    self.actionBtn.layer.borderColor  = [UIColor systemYellowColor].CGColor;
    [self.actionBtn addTarget:self action:@selector(useAction) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.actionBtn];

    self.blastChargeTrack = [[UIView alloc] init];
    self.blastChargeTrack.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    self.blastChargeTrack.layer.cornerRadius = 2;
    [self.view addSubview:self.blastChargeTrack];

    self.blastChargeFill = [[UIView alloc] init];
    self.blastChargeFill.backgroundColor = [UIColor systemYellowColor];
    self.blastChargeFill.layer.cornerRadius = 2;
    [self.blastChargeTrack addSubview:self.blastChargeFill];

    self.launchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.launchBtn setTitle:@"Launch" forState:UIControlStateNormal];
    self.launchBtn.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.launchBtn.backgroundColor = [UIColor systemGreenColor];
    [self.launchBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.launchBtn.layer.cornerRadius = 10;
    [self.launchBtn addTarget:self action:@selector(launchAction) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.launchBtn];

    self.settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.settingsBtn setTitle:@"♪ Settings" forState:UIControlStateNormal];
    self.settingsBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    self.settingsBtn.tintColor = [UIColor colorWithWhite:1 alpha:0.7];
    [self.settingsBtn addTarget:self action:@selector(settingsAction) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.settingsBtn];

    self.gameOverLabel = [[UILabel alloc] init];
    self.gameOverLabel.numberOfLines = 0;
    self.gameOverLabel.textAlignment = NSTextAlignmentCenter;
    self.gameOverLabel.textColor = [UIColor whiteColor];
    self.gameOverLabel.font = [UIFont boldSystemFontOfSize:20];
    self.gameOverLabel.hidden = YES;
    [self.view addSubview:self.gameOverLabel];
}

- (UILabel *)makeHUDLabel {
    UILabel *label = [[UILabel alloc] init];
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont boldSystemFontOfSize:14];
    return label;
}

- (UIButton *)makeArrowButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    button.layer.cornerRadius = 10;
    return button;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat sideMargin = 16;
    CGFloat topSafe = self.view.safeAreaInsets.top;
    CGFloat bottomSafe = self.view.safeAreaInsets.bottom;

    CGFloat hudY = topSafe + 8;
    self.scoreLabel.frame = CGRectMake(sideMargin, hudY, 140, 20);
    CGFloat hudButtonSize = 32;
    self.highScoresBtn.frame = CGRectMake(self.view.bounds.size.width - sideMargin - hudButtonSize * 3 - 12, hudY - 5, hudButtonSize, hudButtonSize);
    self.pauseBtn.frame = CGRectMake(self.view.bounds.size.width - sideMargin - hudButtonSize * 2 - 6, hudY - 5, hudButtonSize, hudButtonSize);
    self.restartBtn.frame = CGRectMake(self.view.bounds.size.width - sideMargin - hudButtonSize, hudY - 5, hudButtonSize, hudButtonSize);
    self.livesLabel.frame = CGRectMake(self.pauseBtn.frame.origin.x - 104, hudY, 96, 20);

    CGFloat boardTop = hudY + 30;
    CGFloat boardBottom = self.view.bounds.size.height - bottomSafe - 150;
    self.gameView.frame = CGRectMake(sideMargin, boardTop,
                                      self.view.bounds.size.width - sideMargin * 2,
                                      MAX(boardBottom - boardTop, 100));
    self.gameView.model = self.model;

    if (self.model && self.currentGameRecord &&
        self.state == BRRicochetStateReady && !self.model.playerLaunched &&
        !CGSizeEqualToSize(self.model.boardSize, self.gameView.bounds.size)) {
        // The first record can arrive before Auto Layout has given the arena
        // its final size. Rebuild only then, preserving the record's seed so
        // the board remains reproducible.
        NSInteger score = self.model.score;
        NSInteger lives = self.model.lives;
        self.model = [[BRRicochetGameModel alloc] initWithBoardSize:self.gameView.bounds.size
                                                                 seed:self.currentGameRecord.seed
                                                                level:self.currentLevel];
        self.model.score = score;
        self.model.lives = lives;
        self.gameView.model = self.model;
        [self updateHUD];
    }

    if (self.model) {
        [self repositionSprites];
    }

    CGFloat controlsY = self.gameView.frame.origin.y + self.gameView.frame.size.height + 14;
    CGFloat buttonSize = 54;
    self.leftBtn.frame  = CGRectMake(sideMargin, controlsY, buttonSize, buttonSize);
    self.rightBtn.frame = CGRectMake(sideMargin + buttonSize + 10, controlsY, buttonSize, buttonSize);

    CGFloat actionW = 100;
    self.actionBtn.frame = CGRectMake(self.view.bounds.size.width - sideMargin - actionW, controlsY, actionW, buttonSize);
    self.blastChargeTrack.frame = CGRectMake(self.actionBtn.frame.origin.x, CGRectGetMaxY(self.actionBtn.frame) + 6, actionW, 4);
    self.blastChargeFill.frame  = CGRectMake(0, 0, 0, 4);

    self.launchBtn.frame = CGRectMake(sideMargin, controlsY + buttonSize + 20,
                                       self.view.bounds.size.width - sideMargin * 2, 46);
    self.settingsBtn.frame = CGRectMake(sideMargin, CGRectGetMaxY(self.launchBtn.frame) + 10, 160, 24);

    self.gameOverLabel.frame = CGRectMake(sideMargin, self.gameView.frame.origin.y + self.gameView.frame.size.height / 2 - 40,
                                           self.view.bounds.size.width - sideMargin * 2, 80);
}

#pragma mark - Shared game library / workshop flow

- (BOOL)userHasMembership {
    return [EZEntitlementManager shared].currentTier.length > 0;
}

- (void)showGamePicker {
    BRGamePickerViewController *picker = [BRGamePickerViewController new];
    __weak typeof(self) weakSelf = self;
    picker.onSelection = ^(BRGameRecord *selectedRecord) {
        [weakSelf loadGameRecord:selectedRecord];
    };
    picker.onClosedWithoutSelection = ^{
        [weakSelf dismissSelfBackToCaller];
    };
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:picker animated:NO completion:nil];
}

- (void)showCustomWorkshopWithInitialImage:(UIImage *)image {
    BRCustomGameCreatorViewController *workshop = [BRCustomGameCreatorViewController new];
    workshop.initialWorkshopImage = image;
    __weak typeof(self) weakSelf = self;
    workshop.onPlayRequested = ^(BRGameRecord *record) {
        [weakSelf loadGameRecord:record];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:workshop];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)dismissSelfBackToCaller {
    if (self.presentingViewController) {
        [self dismissViewControllerAnimated:NO completion:nil];
    } else if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:NO];
    }
}

#pragma mark - Loading a record (same shape as BrainRotViewController.loadGameRecord:)

- (void)loadGameRecord:(BRGameRecord *)record {
    self.currentGameRecord = record;
    self.currentLevel = 1;
    self.state = BRRicochetStateReady;
    self.isPaused = NO;
    self.pauseBtn.selected = NO;
    self.steeringLeft = NO;
    self.steeringRight = NO;
    self.blastCooldownRemaining = 0;
    self.lastFrameTime = 0;
    self.gameOverLabel.hidden = YES;
    self.launchBtn.hidden = NO;
    [self.launchBtn setTitle:@"Launch" forState:UIControlStateNormal];
    [self setGameControlsEnabled:NO]; // enabled once the player is actually launched
    self.restartBtn.enabled = YES;

    CGSize boardSize = self.gameView.bounds.size;
    if (CGSizeEqualToSize(boardSize, CGSizeZero)) {
        // Layout hasn't run yet (e.g. called from init before the view is on
        // screen) — fall back to a reasonable default; -viewDidLayoutSubviews
        // re-keys gameView.model once real bounds are known.
        boardSize = CGSizeMake(360, 480);
    }
    self.model = [[BRRicochetGameModel alloc] initWithBoardSize:boardSize
                                                            seed:record.seed
                                                           level:self.currentLevel];
    self.gameView.model = self.model;

    NSDictionary *assetDict = [record asAssetDict];
    UIImage *bgImage     = assetDict[@"bgImage"];
    UIImage *playerImage = assetDict[@"playerImage"];
    UIImage *enemyImage  = assetDict[@"enemyImage"];

    self.gameView.backgroundImage = bgImage;
    self.playerImageView.image = playerImage;
    self.enemyImageView.image  = enemyImage;

    [self updateHUD];
    [self repositionSprites];
    [self.view setNeedsLayout];
}

#pragma mark - HUD

- (void)updateHUD {
    self.scoreLabel.text = [NSString stringWithFormat:@"Level %ld  •  Score %ld", (long)self.currentLevel, (long)self.model.score];
    self.livesLabel.text = [NSString stringWithFormat:@"Lives %ld", (long)self.model.lives];
}

- (void)repositionSprites {
    CGFloat pr = self.model.playerRadius, er = self.model.enemyRadius;
    self.playerImageView.frame = CGRectMake(self.gameView.frame.origin.x + self.model.playerPosition.x - pr,
                                             self.gameView.frame.origin.y + self.model.playerPosition.y - pr,
                                             pr * 2, pr * 2);
    self.enemyImageView.frame = CGRectMake(self.gameView.frame.origin.x + self.model.enemyPosition.x - er,
                                            self.gameView.frame.origin.y + self.model.enemyPosition.y - er,
                                            er * 2, er * 2);
}

- (void)setGameControlsEnabled:(BOOL)enabled {
    self.leftBtn.enabled = enabled;
    self.rightBtn.enabled = enabled;
    self.actionBtn.enabled = enabled;
    self.leftBtn.alpha = self.rightBtn.alpha = self.actionBtn.alpha = enabled ? 1.0 : 0.4;
    self.pauseBtn.enabled = enabled;
    self.pauseBtn.alpha = enabled ? 1.0 : 0.4;
}

- (void)togglePause {
    if (self.state != BRRicochetStatePlaying) return;
    self.isPaused = !self.isPaused;
    self.pauseBtn.selected = self.isPaused;
    self.steeringLeft = NO;
    self.steeringRight = NO;
    if (self.isPaused) {
        [self.synth stop]; // also sends MIDI Stop
    } else {
        [self.synth start]; // resumes audio and MIDI transport from a tap
    }
}

- (void)startOverAction {
    if (!self.currentGameRecord) return;
    [self.synth stop];
    [self loadGameRecord:self.currentGameRecord];
    [self launchAction];
}

- (void)showHighScores {
    NSInteger pendingScore = self.state == BRRicochetStateGameOver ? self.model.score : -1;
    BRRicochetHighScoresViewController *scores = [[BRRicochetHighScoresViewController alloc] initWithPendingScore:pendingScore];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:scores];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Steering input

- (void)leftTouchDown  { self.steeringLeft = YES; }
- (void)leftTouchUp    { self.steeringLeft = NO; }
- (void)rightTouchDown { self.steeringRight = YES; }
- (void)rightTouchUp   { self.steeringRight = NO; }

#pragma mark - Launch

- (void)launchAction {
    if (self.state == BRRicochetStateGameOver && self.currentGameRecord) {
        // "Play Again" uses the same saved seed/assets but starts a clean
        // board and immediately begins the next launch.
        [self loadGameRecord:self.currentGameRecord];
    }
    if (self.state != BRRicochetStateReady) return;
    [self.synth start]; // must start from a user-gesture handler

    self.state = BRRicochetStateLaunching;
    self.isPaused = NO;
    self.pauseBtn.selected = NO;
    self.launchBtn.hidden = YES;

    CGPoint startPoint = CGPointMake(-24, self.gameView.bounds.size.height * 0.18);
    CGPoint endPoint   = CGPointMake(self.gameView.bounds.size.width * 0.22, self.gameView.bounds.size.height * 0.18);

    self.model.playerPosition = startPoint;
    [self repositionSprites];

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:kBRRicochetLaunchAnimDuration
                          delay:0
         usingSpringWithDamping:0.8
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        weakSelf.model.playerPosition = endPoint;
        [weakSelf repositionSprites];
    } completion:^(BOOL finished) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.model launchPlayer];
        strongSelf.state = BRRicochetStatePlaying;
        [strongSelf setGameControlsEnabled:YES];
    }];
}

#pragma mark - Use blast

- (void)useAction {
    if (self.state != BRRicochetStatePlaying) return;
    if (self.blastCooldownRemaining > 0) return;

    NSInteger cleared = [self.model blastAtPlayerWithRadius:kBRRicochetBlastRadius];
    if (cleared > 0) {
        [self playSoundNamed:@"wall-blast-success"];
    } else {
        [self playSoundNamed:@"wall-blast-fail"];
    }
    [self.synth queueHitWithVelocity:2.2];
    self.blastCooldownRemaining = kBRRicochetBlastCooldown;
    [self updateHUD];
    [self.gameView setNeedsDisplay];
}

#pragma mark - Game loop

- (void)frameTick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    if (self.lastFrameTime == 0) self.lastFrameTime = now;
    NSTimeInterval dt = MIN(now - self.lastFrameTime, 1.0 / 20.0); // clamp to avoid a huge step after a stall
    self.lastFrameTime = now;

    if (self.state == BRRicochetStatePlaying && !self.isPaused) {
        if (self.steeringLeft)  [self.model steerByRadians:-kBRRicochetSteerRateRadPerSec * dt];
        if (self.steeringRight) [self.model steerByRadians: kBRRicochetSteerRateRadPerSec * dt];

        NSArray<NSDictionary<NSString *, id> *> *events = [self.model stepWithDeltaTime:dt];
        [self handleEvents:events];

        if (self.blastCooldownRemaining > 0) {
            self.blastCooldownRemaining = MAX(0, self.blastCooldownRemaining - dt);
        }
        CGFloat chargeFraction = 1.0 - (self.blastCooldownRemaining / kBRRicochetBlastCooldown);
        CGRect fillFrame = self.blastChargeFill.frame;
        fillFrame.size.width = self.blastChargeTrack.bounds.size.width * chargeFraction;
        self.blastChargeFill.frame = fillFrame;

        [self repositionSprites];
        [self.gameView setNeedsDisplay]; // obstacles only change occasionally; cheap enough to redraw regardless
    }

    [self.synth tick];
}

- (void)handleEvents:(NSArray<NSDictionary<NSString *, id> *> *)events {
    BOOL scoreChanged = NO;

    for (NSDictionary<NSString *, id> *event in events) {
        NSString *type = event[BRRicochetEventType];

        if ([type isEqualToString:BRRicochetEventTypeBoundsHit]) {
            [self.synth queueHitWithVelocity:1.0];

        } else if ([type isEqualToString:BRRicochetEventTypeWallHit]) {
            [self.synth queueHitWithVelocity:1.4];
            scoreChanged = YES;

        } else if ([type isEqualToString:BRRicochetEventTypeBlockDestroyed]) {
            [self playSoundNamed:@"wall-blast-success"];
            [self.synth queueHitWithVelocity:1.8];
            scoreChanged = YES;

        } else if ([type isEqualToString:BRRicochetEventTypeEnemyHit]) {
            [self playSoundNamed:@"hurt-player"];
            [self.synth queueHitWithVelocity:2.0];
            scoreChanged = YES;

        } else if ([type isEqualToString:BRRicochetEventTypeHeartCollected]) {
            [self playSoundNamed:@"wall-blast-success"];
            [self.synth queueHitWithVelocity:2.3];
            scoreChanged = YES;

        } else if ([type isEqualToString:BRRicochetEventTypeCoinCollected]) {
            [self.synth queueHitWithVelocity:1.9];
            scoreChanged = YES;

        } else if ([type isEqualToString:BRRicochetEventTypeGameOver]) {
            [self endGameWithMessage:[NSString stringWithFormat:@"Board cleared you.\nScore: %@", event[BRRicochetEventScore]]];

        } else if ([type isEqualToString:BRRicochetEventTypeBoardCleared]) {
            [self advanceToNextLevel];
        }
    }

    if (scoreChanged) [self updateHUD];
}

- (void)advanceToNextLevel {
    if (!self.currentGameRecord || self.state == BRRicochetStateGameOver) return;

    NSInteger carriedScore = self.model.score;
    NSInteger carriedLives = self.model.lives;
    self.currentLevel += 1;
    self.state = BRRicochetStateReady;
    self.isPaused = NO;
    self.steeringLeft = NO;
    self.steeringRight = NO;
    self.blastCooldownRemaining = 0;
    self.lastFrameTime = 0;

    self.model = [[BRRicochetGameModel alloc] initWithBoardSize:self.gameView.bounds.size
                                                           seed:self.currentGameRecord.seed
                                                          level:self.currentLevel];
    self.model.score = carriedScore;
    self.model.lives = carriedLives;
    self.gameView.model = self.model;
    [self updateHUD];
    [self repositionSprites];
    [self.gameView setNeedsDisplay];

    self.gameOverLabel.text = [NSString stringWithFormat:@"LEVEL %ld", (long)self.currentLevel];
    self.gameOverLabel.hidden = NO;
    [self setGameControlsEnabled:NO];
    self.launchBtn.hidden = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.state != BRRicochetStateReady) return;
        strongSelf.gameOverLabel.hidden = YES;
        [strongSelf launchAction];
    });
}

- (void)endGameWithMessage:(NSString *)message {
    if (self.state == BRRicochetStateGameOver) return; // avoid double-firing within the same frame
    self.state = BRRicochetStateGameOver;
    self.isPaused = NO;
    self.pauseBtn.selected = NO;
    [self.synth stop]; // also emits MIDI Stop for any connected clock followers
    [self setGameControlsEnabled:NO];
    self.gameOverLabel.text = message;
    self.gameOverLabel.hidden = NO;
    self.launchBtn.hidden = NO;
    [self.launchBtn setTitle:@"Play Again" forState:UIControlStateNormal];
}

#pragma mark - Settings (key / scale / tempo)

- (void)restoreSynthSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kBRRicochetDefaultsRoot])  self.synth.rootSemitone = [defaults integerForKey:kBRRicochetDefaultsRoot];
    if ([defaults objectForKey:kBRRicochetDefaultsScale]) self.synth.scale        = [defaults integerForKey:kBRRicochetDefaultsScale];
    if ([defaults objectForKey:kBRRicochetDefaultsTempo]) self.synth.tempoBPM     = [defaults integerForKey:kBRRicochetDefaultsTempo];
    if ([defaults objectForKey:kBRRicochetDefaultsMIDISync]) self.synth.midiClockEnabled = [defaults boolForKey:kBRRicochetDefaultsMIDISync];
}

- (void)persistSynthSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.synth.rootSemitone forKey:kBRRicochetDefaultsRoot];
    [defaults setInteger:self.synth.scale        forKey:kBRRicochetDefaultsScale];
    [defaults setInteger:self.synth.tempoBPM     forKey:kBRRicochetDefaultsTempo];
    [defaults setBool:self.synth.midiClockEnabled forKey:kBRRicochetDefaultsMIDISync];
}

- (NSArray<NSString *> *)noteNames {
    return @[@"A", @"A#", @"B", @"C", @"C#", @"D", @"D#", @"E", @"F", @"F#", @"G", @"G#"];
}

- (NSString *)scaleName {
    switch (self.synth.scale) {
        case BRSynthScaleMajor:      return @"Major";
        case BRSynthScaleMinor:      return @"Minor";
        case BRSynthScalePentatonic: return @"Pentatonic";
    }
}

- (void)settingsAction {
    NSString *title = [NSString stringWithFormat:@"Key: %@   Scale: %@   Tempo: %ld bpm",
                        self.noteNames[self.synth.rootSemitone], self.scaleName, (long)self.synth.tempoBPM];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Music Settings"
                                                                     message:title
                                                              preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cycle Key" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        weakSelf.synth.rootSemitone = (weakSelf.synth.rootSemitone + 1) % 12;
        [weakSelf persistSynthSettings];
        [weakSelf settingsAction]; // re-present so the updated value is visible immediately
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cycle Scale" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        weakSelf.synth.scale = (weakSelf.synth.scale + 1) % 3;
        [weakSelf persistSynthSettings];
        [weakSelf settingsAction];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Tempo −10" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        weakSelf.synth.tempoBPM = MAX(60, weakSelf.synth.tempoBPM - 10);
        [weakSelf persistSynthSettings];
        [weakSelf settingsAction];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Tempo +10" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        weakSelf.synth.tempoBPM = MIN(200, weakSelf.synth.tempoBPM + 10);
        [weakSelf persistSynthSettings];
        [weakSelf settingsAction];
    }]];
    NSString *midiTitle = weakSelf.synth.isMIDIClockEnabled ? @"MIDI Sync: On" : @"MIDI Sync: Off";
    [sheet addAction:[UIAlertAction actionWithTitle:midiTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        weakSelf.synth.midiClockEnabled = !weakSelf.synth.isMIDIClockEnabled;
        [weakSelf persistSynthSettings];
        [weakSelf settingsAction];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];

    // iPad requires a popover source; harmless no-op on iPhone.
    sheet.popoverPresentationController.sourceView = self.settingsBtn;
    sheet.popoverPresentationController.sourceRect = self.settingsBtn.bounds;

    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - SFX (reuses the same bundled .aiff assets the maze game ships with)

- (void)preloadSoundEffects {
    self.sfxPlayers = [NSMutableDictionary dictionary];
    NSArray<NSString *> *fileNames = @[ @"wall-blast-success", @"wall-blast-fail", @"hurt-player" ];

    for (NSString *fileName in fileNames) {
        NSURL *fileURL = [[NSBundle mainBundle] URLForResource:fileName withExtension:@"aiff" subdirectory:@"sounds"];
        if (!fileURL) fileURL = [[NSBundle mainBundle] URLForResource:fileName withExtension:@"aiff"];
        if (!fileURL) {
            NSLog(@"[BRRicochet] SFX not found: %@.aiff", fileName);
            continue;
        }
        NSError *loadError = nil;
        AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&loadError];
        if (loadError || !player) continue;
        player.volume = 0.70;
        [player prepareToPlay];
        self.sfxPlayers[fileName] = player;
    }
}

- (void)playSoundNamed:(NSString *)soundName {
    AVAudioPlayer *player = self.sfxPlayers[soundName];
    if (!player) return;
    if (player.isPlaying) { [player stop]; player.currentTime = 0; }
    [player play];
}

@end
