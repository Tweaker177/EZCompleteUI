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
#import <math.h>

typedef NS_ENUM(NSInteger, BRRicochetState) {
    BRRicochetStateReady,       // sitting at the slide, waiting for Launch
    BRRicochetStateLaunching,   // manual slide-in animation in progress
    BRRicochetStatePlaying,
    BRRicochetStateGameOver
};

static const NSTimeInterval kBRRicochetLaunchAnimDuration = 0.55;
static const CGFloat        kBRRicochetSteerRateRadPerSec = 3.3;
static const CGFloat        kBRRicochetBlastRadius        = 90.0;

static NSString * const kBRRicochetDefaultsRoot   = @"BRRicochetSynthRootSemitone";
static NSString * const kBRRicochetDefaultsScale  = @"BRRicochetSynthScale";
static NSString * const kBRRicochetDefaultsTempo  = @"BRRicochetSynthTempoBPM";
static NSString * const kBRRicochetDefaultsMIDISync = @"BRRicochetMIDIClockEnabled";
static NSString * const kBRRicochetDefaultsOctave = @"BRRicochetSynthOctave";
static NSString * const kBRRicochetDefaultsAttack = @"BRRicochetSynthAttack";
static NSString * const kBRRicochetDefaultsRelease = @"BRRicochetSynthRelease";
static NSString * const kBRRicochetDefaultsFilter = @"BRRicochetSynthFilter";
static NSString * const kBRRicochetDefaultsReverb = @"BRRicochetSynthReverb";

/// Compact rotary control for the Music Lab. It owns its pan gesture, so it
/// remains responsive while the Music Lab is on screen instead of relying on
/// a sliding presentation's gesture recognizer.
@interface BRRicochetMusicKnob : UIControl
@property (nonatomic, assign) CGFloat value, minimumValue, maximumValue;
@property (nonatomic, strong) UILabel *captionLabel, *valueLabel;
@property (nonatomic, strong) UIView *indicator;
@property (nonatomic, assign) CGFloat touchStartY, valueAtTouchStart;
@property (nonatomic, strong) UIPanGestureRecognizer *panRecognizer;
- (instancetype)initWithCaption:(NSString *)caption;
@end

@implementation BRRicochetMusicKnob
- (instancetype)initWithCaption:(NSString *)caption {
    self = [super initWithFrame:CGRectMake(0, 0, 72, 104)]; if (!self) return nil;
    UIView *dial = [[UIView alloc] initWithFrame:CGRectMake(4, 0, 64, 64)];
    dial.backgroundColor = [UIColor colorWithRed:0.20 green:0.12 blue:0.34 alpha:1]; dial.layer.cornerRadius = 32;
    dial.userInteractionEnabled = NO;
    dial.layer.borderWidth = 1.5; dial.layer.borderColor = [UIColor colorWithRed:0.74 green:0.52 blue:1 alpha:0.75].CGColor; [self addSubview:dial];
    _indicator = [[UIView alloc] initWithFrame:CGRectMake(30, 7, 4, 20)]; _indicator.backgroundColor = [UIColor colorWithRed:0.88 green:0.80 blue:1 alpha:1]; _indicator.layer.cornerRadius = 2; _indicator.userInteractionEnabled = NO; _indicator.layer.anchorPoint = CGPointMake(0.5, 1.0); _indicator.center = CGPointMake(32, 32); [dial addSubview:_indicator];
    _captionLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 63, 72, 15)]; _captionLabel.text = caption; _captionLabel.textAlignment = NSTextAlignmentCenter; _captionLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold]; _captionLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1]; _captionLabel.userInteractionEnabled = NO; [self addSubview:_captionLabel];
    _valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 80, 72, 18)]; _valueLabel.textAlignment = NSTextAlignmentCenter; _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold]; _valueLabel.textColor = UIColor.whiteColor; _valueLabel.userInteractionEnabled = NO; [self addSubview:_valueLabel];
    self.minimumValue = 0; self.maximumValue = 1;
    _panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    _panRecognizer.minimumNumberOfTouches = 1;
    _panRecognizer.maximumNumberOfTouches = 1;
    [self addGestureRecognizer:_panRecognizer];
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    return self;
}
- (void)setValue:(CGFloat)value { _value = MAX(self.minimumValue, MIN(self.maximumValue, value)); CGFloat fraction = (_value - self.minimumValue) / MAX(0.001, self.maximumValue - self.minimumValue); self.indicator.transform = CGAffineTransformMakeRotation((fraction - 0.5) * (CGFloat)M_PI * 1.45); }
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) self.valueAtTouchStart = self.value;
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        // 72 pt covers the whole useful range: deliberate but not fussy.
        CGFloat delta = -[pan translationInView:self].y / 72.0;
        CGFloat previous = self.value;
        self.value = self.valueAtTouchStart + delta * (self.maximumValue - self.minimumValue);
        if (fabs(self.value - previous) > 0.0001) [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
}
- (void)accessibilityIncrement { self.value += (self.maximumValue - self.minimumValue) / 20.0; [self sendActionsForControlEvents:UIControlEventValueChanged]; }
- (void)accessibilityDecrement { self.value -= (self.maximumValue - self.minimumValue) / 20.0; [self sendActionsForControlEvents:UIControlEventValueChanged]; }
@end

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
@property (nonatomic, strong) UILabel  *gameOverLabel;
@property (nonatomic, strong) UIView   *musicSettingsOverlay;
@property (nonatomic, strong) UIView   *highScoreCelebrationOverlay;

@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastFrameTime;
@property (nonatomic, assign) BRRicochetState state;

@property (nonatomic, assign) BOOL steeringLeft;
@property (nonatomic, assign) BOOL steeringRight;
@property (nonatomic, assign) BOOL isPaused;
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
    self.playerImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.playerImageView.clipsToBounds = NO;
    [self.view addSubview:self.playerImageView];

    self.enemyImageView = [[UIImageView alloc] init];
    self.enemyImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.enemyImageView.clipsToBounds = NO;
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
    label.numberOfLines = 2;
    return label;
}

- (UIButton *)makeArrowButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:28];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    button.layer.cornerRadius = 12;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.30].CGColor;
    return button;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat sideMargin = 16;
    CGFloat topSafe = self.view.safeAreaInsets.top;
    CGFloat bottomSafe = self.view.safeAreaInsets.bottom;

    CGFloat hudY = topSafe + 8;
    self.scoreLabel.frame = CGRectMake(sideMargin, hudY, 150, 40);
    CGFloat hudButtonSize = 32;
    self.highScoresBtn.frame = CGRectMake(self.view.bounds.size.width - sideMargin - hudButtonSize * 3 - 12, hudY - 5, hudButtonSize, hudButtonSize);
    self.pauseBtn.frame = CGRectMake(self.view.bounds.size.width - sideMargin - hudButtonSize * 2 - 6, hudY - 5, hudButtonSize, hudButtonSize);
    self.restartBtn.frame = CGRectMake(self.view.bounds.size.width - sideMargin - hudButtonSize, hudY - 5, hudButtonSize, hudButtonSize);
    self.livesLabel.frame = CGRectMake(self.pauseBtn.frame.origin.x - 104, hudY + 11, 96, 20);

    CGFloat boardTop = hudY + 48;
    // The centered controls use a little more vertical room, leaving ample
    // space for the launch/settings controls below them.
    CGFloat boardBottom = self.view.bounds.size.height - bottomSafe - 210;
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

    CGFloat controlsY = self.gameView.frame.origin.y + self.gameView.frame.size.height + 12;
    CGFloat buttonW = 82, buttonH = 60, buttonGap = 18;
    CGFloat controlsCenterX = CGRectGetMidX(self.view.bounds);
    self.leftBtn.frame  = CGRectMake(controlsCenterX - buttonGap / 2.0 - buttonW, controlsY, buttonW, buttonH);
    self.rightBtn.frame = CGRectMake(controlsCenterX + buttonGap / 2.0, controlsY, buttonW, buttonH);

    self.launchBtn.frame = CGRectMake(sideMargin, CGRectGetMaxY(self.leftBtn.frame) + 16,
                                       self.view.bounds.size.width - sideMargin * 2, 46);
    // Use takes this former Launch / Play Again position while a run is active.
    self.actionBtn.frame = self.launchBtn.frame;
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
    self.lastFrameTime = 0;
    self.actionBtn.hidden = YES;
    self.gameOverLabel.hidden = YES;
    self.launchBtn.hidden = NO;
    self.actionBtn.hidden = YES;
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
    self.scoreLabel.text = [NSString stringWithFormat:@"SCORE  %ld\nLEVEL  %ld", (long)self.model.score, (long)self.currentLevel];
    self.livesLabel.text = [NSString stringWithFormat:@"Lives %ld", (long)self.model.lives];
}

- (void)repositionSprites {
    CGFloat pr = self.model.playerRadius, er = self.model.enemyRadius;
    // Art is much larger than its collision body; gameplay physics stay the same.
    CGFloat playerVisualRadius = pr * 1.62;
    CGFloat enemyVisualRadius = er * 1.62;
    self.playerImageView.frame = CGRectMake(self.gameView.frame.origin.x + self.model.playerPosition.x - playerVisualRadius,
                                             self.gameView.frame.origin.y + self.model.playerPosition.y - playerVisualRadius,
                                             playerVisualRadius * 2, playerVisualRadius * 2);
    self.enemyImageView.frame = CGRectMake(self.gameView.frame.origin.x + self.model.enemyPosition.x - enemyVisualRadius,
                                            self.gameView.frame.origin.y + self.model.enemyPosition.y - enemyVisualRadius,
                                            enemyVisualRadius * 2, enemyVisualRadius * 2);
    self.enemyImageView.hidden = !self.model.enemyActive;
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
    // The trophy button is browse-only. Score entry is offered only after the
    // finished score has been checked against the live leaderboard.
    BRRicochetHighScoresViewController *scores = [[BRRicochetHighScoresViewController alloc] initWithPendingScore:-1];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:scores];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)offerHighScoreEntryIfQualified:(NSInteger)score {
    NSURL *url = [NSURL URLWithString:@"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/br-ricochet-highscores"];
    if (!url) return;
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![parsed isKindOfClass:NSArray.class]) return;
        NSArray<NSDictionary *> *scores = parsed;
        NSInteger placement = -1;
        for (NSUInteger i = 0; i < scores.count; i++) {
            if (score > [scores[i][@"score"] integerValue]) { placement = (NSInteger)i + 1; break; }
        }
        if (scores.count < 10 && placement < 0) placement = (NSInteger)scores.count + 1;
        if (placement < 0 || placement > 10) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.state != BRRicochetStateGameOver) return;
            [strongSelf showHighScoreCelebrationForScore:score placement:placement];
        });
    }] resume];
}

- (void)showHighScoreCelebrationForScore:(NSInteger)score placement:(NSInteger)placement {
    if (self.highScoreCelebrationOverlay) return;
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78]; overlay.alpha = 0;
    [self.view addSubview:overlay]; self.highScoreCelebrationOverlay = overlay;

    CGFloat width = MIN(342.0, CGRectGetWidth(overlay.bounds) - 34.0);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 398)];
    card.center = CGPointMake(CGRectGetMidX(overlay.bounds), CGRectGetMidY(overlay.bounds));
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    card.layer.cornerRadius = 28; card.clipsToBounds = YES;
    CAGradientLayer *gradient = [CAGradientLayer layer]; gradient.frame = card.bounds;
    gradient.colors = @[(__bridge id)[UIColor colorWithRed:0.18 green:0.08 blue:0.34 alpha:1].CGColor,
                        (__bridge id)[UIColor colorWithRed:0.05 green:0.04 blue:0.16 alpha:1].CGColor];
    gradient.startPoint = CGPointMake(0, 0); gradient.endPoint = CGPointMake(1, 1); [card.layer insertSublayer:gradient atIndex:0];
    card.layer.borderWidth = 1.5; card.layer.borderColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.20 alpha:0.85].CGColor;
    card.transform = CGAffineTransformMakeScale(0.72, 0.72); [overlay addSubview:card];

    for (NSInteger i = 0; i < 22; i++) {
        UIView *spark = [[UIView alloc] initWithFrame:CGRectMake(width / 2.0 - 3, 112, 6, 12)];
        spark.backgroundColor = i % 3 == 0 ? UIColor.systemPinkColor : (i % 3 == 1 ? UIColor.systemYellowColor : UIColor.systemTealColor);
        spark.layer.cornerRadius = 3; [overlay addSubview:spark];
        CGFloat angle = (CGFloat)i / 22.0 * M_PI * 2.0;
        CGFloat radius = 95 + arc4random_uniform(78);
        [UIView animateWithDuration:0.70 delay:(arc4random_uniform(18) / 100.0) usingSpringWithDamping:0.72 initialSpringVelocity:1.6 options:UIViewAnimationOptionCurveEaseOut animations:^{
            spark.center = CGPointMake(CGRectGetMidX(overlay.bounds) + cos(angle) * radius, CGRectGetMidY(overlay.bounds) - 68 + sin(angle) * radius * 0.62);
            spark.transform = CGAffineTransformMakeRotation(angle * 4); spark.alpha = 0;
        } completion:^(__unused BOOL done) { [spark removeFromSuperview]; }];
    }
    UILabel *trophy = [[UILabel alloc] initWithFrame:CGRectMake(0, 34, width, 76)]; trophy.text = @"🏆"; trophy.textAlignment = NSTextAlignmentCenter; trophy.font = [UIFont systemFontOfSize:61]; [card addSubview:trophy];
    UILabel *eyebrow = [[UILabel alloc] initWithFrame:CGRectMake(20, 118, width - 40, 18)]; eyebrow.text = @"RICHOCHET BLAST"; eyebrow.textAlignment = NSTextAlignmentCenter; eyebrow.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold]; eyebrow.textColor = [UIColor colorWithRed:1 green:0.78 blue:0.20 alpha:1]; [card addSubview:eyebrow];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18, 140, width - 36, 38)]; title.text = @"NEW HIGH SCORE!"; title.textAlignment = NSTextAlignmentCenter; title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightHeavy]; title.textColor = UIColor.whiteColor; [card addSubview:title];
    UIView *scorePill = [[UIView alloc] initWithFrame:CGRectMake(38, 194, width - 76, 78)]; scorePill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09]; scorePill.layer.cornerRadius = 18; scorePill.layer.borderWidth = 1; scorePill.layer.borderColor = [UIColor colorWithRed:1 green:0.78 blue:0.20 alpha:0.42].CGColor; [card addSubview:scorePill];
    UILabel *rank = [[UILabel alloc] initWithFrame:CGRectMake(0, 9, scorePill.bounds.size.width, 20)]; rank.text = [NSString stringWithFormat:@"YOU PLACED #%ld", (long)placement]; rank.textAlignment = NSTextAlignmentCenter; rank.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold]; rank.textColor = [UIColor colorWithWhite:0.73 alpha:1]; [scorePill addSubview:rank];
    UILabel *scoreLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 28, scorePill.bounds.size.width, 40)]; scoreLabel.text = [NSString stringWithFormat:@"%ld", (long)score]; scoreLabel.textAlignment = NSTextAlignmentCenter; scoreLabel.font = [UIFont monospacedDigitSystemFontOfSize:32 weight:UIFontWeightBold]; scoreLabel.textColor = [UIColor colorWithRed:1 green:0.80 blue:0.25 alpha:1]; [scorePill addSubview:scoreLabel];
    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(28, 282, width - 56, 32)]; caption.text = @"That run deserves a place on the board."; caption.textAlignment = NSTextAlignmentCenter; caption.numberOfLines = 2; caption.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]; caption.textColor = [UIColor colorWithWhite:0.72 alpha:1]; [card addSubview:caption];
    UIButton *claim = [UIButton buttonWithType:UIButtonTypeSystem]; claim.frame = CGRectMake(24, 316, width - 48, 42); claim.backgroundColor = [UIColor colorWithRed:1 green:0.70 blue:0.12 alpha:1]; claim.layer.cornerRadius = 14; [claim setTitle:@"CLAIM YOUR SCORE" forState:UIControlStateNormal]; claim.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy]; claim.tintColor = [UIColor colorWithRed:0.10 green:0.05 blue:0.18 alpha:1]; [card addSubview:claim];
    __weak typeof(self) weakSelf = self;
    void (^dismissCard)(void) = ^{ [UIView animateWithDuration:0.20 animations:^{ overlay.alpha = 0; card.transform = CGAffineTransformMakeScale(0.9, 0.9); } completion:^(__unused BOOL done) { [overlay removeFromSuperview]; weakSelf.highScoreCelebrationOverlay = nil; }]; };
    [claim addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { dismissCard(); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ BRRicochetHighScoresViewController *entry = [[BRRicochetHighScoresViewController alloc] initWithPendingScore:score]; UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:entry]; nav.modalPresentationStyle = UIModalPresentationPageSheet; [weakSelf presentViewController:nav animated:YES completion:nil]; }); }] forControlEvents:UIControlEventTouchUpInside];
    UIButton *later = [UIButton buttonWithType:UIButtonTypeSystem]; later.frame = CGRectMake(24, 362, width - 48, 24); [later setTitle:@"Maybe later" forState:UIControlStateNormal]; later.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; later.tintColor = [UIColor colorWithWhite:0.70 alpha:1]; [later addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { dismissCard(); }] forControlEvents:UIControlEventTouchUpInside]; [card addSubview:later];
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.70 initialSpringVelocity:0.9 options:UIViewAnimationOptionCurveEaseOut animations:^{ overlay.alpha = 1; card.transform = CGAffineTransformIdentity; } completion:nil];
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
    self.actionBtn.hidden = YES;

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
        strongSelf.actionBtn.hidden = NO;
        [strongSelf setGameControlsEnabled:YES];
    }];
}

#pragma mark - Use blast

- (void)playUseSwordSweep {
    CGPoint center = self.playerImageView.center;
    CGFloat sweepSize = 150.0;
    UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, sweepSize, sweepSize)];
    host.center = center;
    host.userInteractionEnabled = NO;
    [self.view insertSubview:host aboveSubview:self.gameView];

    CGPoint arcCenter = CGPointMake(sweepSize / 2.0, sweepSize / 2.0);
    NSArray<UIColor *> *colors = @[
        [UIColor colorWithWhite:1.0 alpha:0.86],
        [UIColor colorWithWhite:0.68 alpha:0.48],
        [UIColor colorWithWhite:0.34 alpha:0.28],
    ];
    for (NSInteger i = 0; i < colors.count; i++) {
        UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:arcCenter
                                                             radius:46.0 + i * 10.0
                                                         startAngle:-1.0
                                                           endAngle:0.62
                                                          clockwise:YES];
        CAShapeLayer *band = [CAShapeLayer layer];
        band.path = arc.CGPath;
        band.fillColor = UIColor.clearColor.CGColor;
        band.strokeColor = colors[i].CGColor;
        band.lineWidth = 8.0 - i * 1.2;
        band.lineCap = kCALineCapRound;
        band.shadowColor = UIColor.whiteColor.CGColor;
        band.shadowOpacity = i == 0 ? 0.8 : 0.3;
        band.shadowRadius = 5.0;
        [host.layer addSublayer:band];
    }
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.fromValue = @(-M_PI_2);
    spin.toValue = @(M_PI * 1.5);
    spin.duration = 0.42;
    spin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [host.layer addAnimation:spin forKey:@"ricochetUseSweep"];
    [UIView animateWithDuration:0.16 delay:0.27 options:UIViewAnimationOptionCurveEaseOut animations:^{ host.alpha = 0; } completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.46 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [host removeFromSuperview]; });
}

- (void)playBlockShatterAtBoardFrame:(CGRect)boardFrame {
    static const NSInteger columns = 2, rows = 2;
    CGFloat pieceW = boardFrame.size.width / columns, pieceH = boardFrame.size.height / rows;
    NSArray<UIColor *> *shades = @[
        [UIColor colorWithRed:0.68 green:0.72 blue:0.85 alpha:0.94],
        [UIColor colorWithRed:0.47 green:0.53 blue:0.70 alpha:0.94],
        [UIColor colorWithRed:0.30 green:0.36 blue:0.51 alpha:0.94],
    ];
    for (NSInteger row = 0; row < rows; row++) for (NSInteger col = 0; col < columns; col++) {
        UIView *piece = [[UIView alloc] initWithFrame:CGRectMake(boardFrame.origin.x + col * pieceW,
                                                                   boardFrame.origin.y + row * pieceH,
                                                                   pieceW - 1.0, pieceH - 1.0)];
        piece.backgroundColor = shades[arc4random_uniform((uint32_t)shades.count)];
        piece.layer.cornerRadius = 2.0;
        [self.gameView addSubview:piece];
        CGFloat angle = ((CGFloat)arc4random_uniform(628) / 100.0) - (CGFloat)M_PI;
        CGFloat distance = 16.0 + arc4random_uniform(18);
        [UIView animateWithDuration:0.36 delay:arc4random_uniform(45) / 1000.0
             usingSpringWithDamping:0.76 initialSpringVelocity:1.3
                             options:UIViewAnimationOptionCurveEaseOut animations:^{
            piece.center = CGPointMake(piece.center.x + cos(angle) * distance,
                                       piece.center.y + sin(angle) * distance);
            piece.transform = CGAffineTransformConcat(CGAffineTransformMakeRotation(angle * 0.45), CGAffineTransformMakeScale(0.58, 0.58));
            piece.alpha = 0;
        } completion:^(__unused BOOL done) { [piece removeFromSuperview]; }];
    }
}

- (void)useAction {
    if (self.state != BRRicochetStatePlaying) return;
    [self playUseSwordSweep];
    NSMutableArray<NSValue *> *destroyedFrames = [NSMutableArray array];
    for (BRObstacle *obstacle in self.model.obstacles) {
        CGPoint center = CGPointMake(CGRectGetMidX(obstacle.frame), CGRectGetMidY(obstacle.frame));
        CGFloat obstacleRadius = MAX(obstacle.frame.size.width, obstacle.frame.size.height) / 2.0;
        if (hypot(center.x - self.model.playerPosition.x, center.y - self.model.playerPosition.y) <= kBRRicochetBlastRadius + obstacleRadius) {
            [destroyedFrames addObject:[NSValue valueWithCGRect:obstacle.frame]];
        }
    }
    NSInteger cleared = [self.model blastAtPlayerWithRadius:kBRRicochetBlastRadius];
    BOOL defeatedEnemy = [self.model defeatEnemyWithBlastRadius:kBRRicochetBlastRadius];
    for (NSValue *frameValue in destroyedFrames) {
        [self playBlockShatterAtBoardFrame:frameValue.CGRectValue];
    }
    if (defeatedEnemy) {
        self.enemyImageView.hidden = YES;
        [self playSoundNamed:@"wall-blast-success"];
    }
    if (cleared > 0) {
        [self playSoundNamed:@"wall-blast-success"];
    } else {
        [self playSoundNamed:@"wall-blast-fail"];
    }
    [self.synth queueHitWithVelocity:2.2];
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
            [self playBlockShatterAtBoardFrame:[event[BRRicochetEventFrame] CGRectValue]];
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
    self.actionBtn.hidden = YES;
    [self.launchBtn setTitle:@"Play Again" forState:UIControlStateNormal];
    [self offerHighScoreEntryIfQualified:self.model.score];
}

#pragma mark - Settings (key / scale / tempo)

- (void)restoreSynthSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kBRRicochetDefaultsRoot])  self.synth.rootSemitone = [defaults integerForKey:kBRRicochetDefaultsRoot];
    if ([defaults objectForKey:kBRRicochetDefaultsScale]) self.synth.scale        = [defaults integerForKey:kBRRicochetDefaultsScale];
    if ([defaults objectForKey:kBRRicochetDefaultsTempo]) self.synth.tempoBPM     = [defaults integerForKey:kBRRicochetDefaultsTempo];
    if ([defaults objectForKey:kBRRicochetDefaultsMIDISync]) self.synth.midiClockEnabled = [defaults boolForKey:kBRRicochetDefaultsMIDISync];
    if ([defaults objectForKey:kBRRicochetDefaultsOctave]) self.synth.octaveOffset = [defaults integerForKey:kBRRicochetDefaultsOctave];
    if ([defaults objectForKey:kBRRicochetDefaultsAttack]) self.synth.attackSeconds = [defaults floatForKey:kBRRicochetDefaultsAttack];
    if ([defaults objectForKey:kBRRicochetDefaultsRelease]) self.synth.releaseSeconds = [defaults floatForKey:kBRRicochetDefaultsRelease];
    if ([defaults objectForKey:kBRRicochetDefaultsFilter]) self.synth.filterBrightness = [defaults floatForKey:kBRRicochetDefaultsFilter];
    if ([defaults objectForKey:kBRRicochetDefaultsReverb]) self.synth.reverbMix = [defaults floatForKey:kBRRicochetDefaultsReverb];
    // Older builds stored a narrower range. Clamp corrupted/legacy values to
    // the full Music Lab range before the labels and stepper are constructed.
    self.synth.octaveOffset = MAX(-4, MIN(3, self.synth.octaveOffset));
    self.synth.tempoBPM = MAX(60, MIN(200, self.synth.tempoBPM));
}

- (void)persistSynthSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.synth.rootSemitone forKey:kBRRicochetDefaultsRoot];
    [defaults setInteger:self.synth.scale        forKey:kBRRicochetDefaultsScale];
    [defaults setInteger:self.synth.tempoBPM     forKey:kBRRicochetDefaultsTempo];
    [defaults setBool:self.synth.midiClockEnabled forKey:kBRRicochetDefaultsMIDISync];
    [defaults setInteger:self.synth.octaveOffset forKey:kBRRicochetDefaultsOctave];
    [defaults setFloat:self.synth.attackSeconds forKey:kBRRicochetDefaultsAttack];
    [defaults setFloat:self.synth.releaseSeconds forKey:kBRRicochetDefaultsRelease];
    [defaults setFloat:self.synth.filterBrightness forKey:kBRRicochetDefaultsFilter];
    [defaults setFloat:self.synth.reverbMix forKey:kBRRicochetDefaultsReverb];
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
    if (self.musicSettingsOverlay) return;

    // This follows the gallery's custom card treatment rather than using a
    // generic system sheet, so music controls feel like part of Ricochet.
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    overlay.alpha = 0;
    [self.view addSubview:overlay];
    self.musicSettingsOverlay = overlay;

    CGFloat cardWidth = MIN(350.0, CGRectGetWidth(self.view.bounds) - 36.0);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardWidth, 610)];
    card.center = CGPointMake(CGRectGetMidX(overlay.bounds), CGRectGetMidY(overlay.bounds));
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    card.backgroundColor = [UIColor colorWithRed:0.055 green:0.06 blue:0.13 alpha:1.0];
    card.layer.cornerRadius = 24.0;
    card.layer.borderWidth = 1.5;
    card.layer.borderColor = [UIColor colorWithRed:0.63 green:0.35 blue:1.0 alpha:0.72].CGColor;
    [overlay addSubview:card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 25, cardWidth - 40, 28)];
    title.text = @"♪  MUSIC LAB";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor colorWithRed:0.74 green:0.52 blue:1.0 alpha:1.0];
    title.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    [card addSubview:title];
    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(24, 55, cardWidth - 48, 34)];
    subtitle.text = @"Tune the bounce soundtrack for this run.";
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.textColor = [UIColor colorWithWhite:0.70 alpha:1.0];
    subtitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [card addSubview:subtitle];

    UILabel *keyValue = [UILabel new], *scaleValue = [UILabel new], *octaveValue = [UILabel new], *tempoValue = [UILabel new];
    NSArray<UILabel *> *values = @[keyValue, scaleValue, octaveValue, tempoValue];
    for (UILabel *value in values) {
        value.textAlignment = NSTextAlignmentRight;
        value.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightBold];
        value.textColor = UIColor.whiteColor;
    }
    BRRicochetMusicKnob *attackKnob = [[BRRicochetMusicKnob alloc] initWithCaption:@"ATTACK"];
    BRRicochetMusicKnob *releaseKnob = [[BRRicochetMusicKnob alloc] initWithCaption:@"RELEASE"];
    BRRicochetMusicKnob *filterKnob = [[BRRicochetMusicKnob alloc] initWithCaption:@"FILTER"];
    BRRicochetMusicKnob *reverbKnob = [[BRRicochetMusicKnob alloc] initWithCaption:@"REVERB"];
    NSArray<BRRicochetMusicKnob *> *knobs = @[attackKnob, releaseKnob, filterKnob, reverbKnob];
    for (BRRicochetMusicKnob *knob in knobs) { knob.minimumValue = 0; knob.maximumValue = 1; [card addSubview:knob]; }
    __weak typeof(self) weakSelf = self;
    __block void (^refresh)(void) = ^{
        typeof(self) self = weakSelf; if (!self) return;
        keyValue.text = self.noteNames[self.synth.rootSemitone];
        scaleValue.text = self.scaleName;
        octaveValue.text = [NSString stringWithFormat:@"%+ld OCT", (long)self.synth.octaveOffset];
        tempoValue.text = [NSString stringWithFormat:@"%ld BPM", (long)self.synth.tempoBPM];
        attackKnob.value = (self.synth.attackSeconds - 0.005f) / 0.245f;
        releaseKnob.value = (self.synth.releaseSeconds - 0.04f) / 0.66f;
        filterKnob.value = self.synth.filterBrightness;
        reverbKnob.value = self.synth.reverbMix;
        attackKnob.valueLabel.text = [NSString stringWithFormat:@"%.0f ms", self.synth.attackSeconds * 1000.0f];
        releaseKnob.valueLabel.text = [NSString stringWithFormat:@"%.0f ms", self.synth.releaseSeconds * 1000.0f];
        filterKnob.valueLabel.text = [NSString stringWithFormat:@"%.0f%%", self.synth.filterBrightness * 100.0f];
        reverbKnob.valueLabel.text = [NSString stringWithFormat:@"%.0f%%", self.synth.reverbMix * 100.0f];
    };
    NSArray<NSString *> *rowTitles = @[ @"ROOT KEY", @"SCALE", @"OCTAVE", @"TEMPO" ];
    NSArray<UILabel *> *rowValues = @[ keyValue, scaleValue, octaveValue, tempoValue ];
    for (NSInteger i = 0; i < rowTitles.count; i++) {
        CGFloat y = 96 + i * 53;
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(20, y, cardWidth - 40, 46)];
        row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
        row.layer.cornerRadius = 14;
        [card addSubview:row];
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(15, 0, 105, 46)];
        name.text = rowTitles[i]; name.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        name.textColor = [UIColor colorWithWhite:0.65 alpha:1.0]; [row addSubview:name];
        UILabel *value = rowValues[i]; value.frame = CGRectMake(112, 0, row.bounds.size.width - 127, 46); [row addSubview:value];
        if (i == 0 || i == 1) {
            UIButton *tapTarget = [UIButton buttonWithType:UIButtonTypeCustom];
            tapTarget.frame = row.bounds;
            [tapTarget addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
                if (i == 0) weakSelf.synth.rootSemitone = (weakSelf.synth.rootSemitone + 1) % 12;
                else weakSelf.synth.scale = (weakSelf.synth.scale + 1) % 3;
                [weakSelf persistSynthSettings]; refresh();
            }] forControlEvents:UIControlEventTouchUpInside];
            [row addSubview:tapTarget];
        } else if (i == 2) {
            UIStepper *stepper = [[UIStepper alloc] initWithFrame:CGRectMake(row.bounds.size.width - 102, 8, 88, 30)];
            stepper.minimumValue = -4; stepper.maximumValue = 3; stepper.stepValue = 1; stepper.value = weakSelf.synth.octaveOffset;
            [stepper addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { weakSelf.synth.octaveOffset = (NSInteger)stepper.value; [weakSelf persistSynthSettings]; refresh(); }] forControlEvents:UIControlEventValueChanged];
            value.frame = CGRectMake(112, 0, row.bounds.size.width - 222, 46); [row addSubview:stepper];
        }
    }
    UIButton *(^smallButton)(NSString *, CGFloat) = ^UIButton *(NSString *text, CGFloat x) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(x, 310, 58, 38); button.backgroundColor = [UIColor colorWithRed:0.63 green:0.35 blue:1 alpha:0.22];
        button.layer.cornerRadius = 12; button.layer.borderWidth = 1; button.layer.borderColor = [UIColor colorWithRed:0.74 green:0.52 blue:1 alpha:0.55].CGColor;
        [button setTitle:text forState:UIControlStateNormal]; button.titleLabel.font = [UIFont boldSystemFontOfSize:20]; button.tintColor = UIColor.whiteColor;
        [card addSubview:button]; return button;
    };
    UIButton *minus = smallButton(@"−", cardWidth / 2.0 - 70); UIButton *plus = smallButton(@"+", cardWidth / 2.0 + 12);
    [minus addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { weakSelf.synth.tempoBPM = MAX(60, weakSelf.synth.tempoBPM - 1); [weakSelf persistSynthSettings]; refresh(); }] forControlEvents:UIControlEventTouchUpInside];
    [plus addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { weakSelf.synth.tempoBPM = MIN(200, weakSelf.synth.tempoBPM + 1); [weakSelf persistSynthSettings]; refresh(); }] forControlEvents:UIControlEventTouchUpInside];
    CGFloat knobX = (cardWidth - knobs.count * 72.0) / 2.0;
    for (NSInteger i = 0; i < knobs.count; i++) {
        BRRicochetMusicKnob *knob = knobs[i]; knob.frame = CGRectMake(knobX + i * 72.0, 366, 72, 104);
        [knob addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            if (i == 0) weakSelf.synth.attackSeconds = 0.005f + knob.value * 0.245f;
            else if (i == 1) weakSelf.synth.releaseSeconds = 0.04f + knob.value * 0.66f;
            else if (i == 2) weakSelf.synth.filterBrightness = knob.value;
            else weakSelf.synth.reverbMix = knob.value;
            [weakSelf persistSynthSettings]; refresh();
        }] forControlEvents:UIControlEventValueChanged];
    }
    UISwitch *midiSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(cardWidth - 80, 480, 52, 32)]; midiSwitch.on = self.synth.isMIDIClockEnabled; midiSwitch.onTintColor = [UIColor colorWithRed:0.63 green:0.35 blue:1 alpha:1];
    [midiSwitch addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { weakSelf.synth.midiClockEnabled = midiSwitch.isOn; [weakSelf persistSynthSettings]; }] forControlEvents:UIControlEventValueChanged]; [card addSubview:midiSwitch];
    UILabel *midi = [[UILabel alloc] initWithFrame:CGRectMake(25, 472, 200, 44)]; midi.text = @"MIDI CLOCK SYNC"; midi.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold]; midi.textColor = [UIColor colorWithWhite:0.70 alpha:1]; [card addSubview:midi];
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem]; done.frame = CGRectMake(20, 544, cardWidth - 40, 42); done.backgroundColor = [UIColor colorWithRed:0.63 green:0.35 blue:1 alpha:0.92]; done.layer.cornerRadius = 12; [done setTitle:@"Done" forState:UIControlStateNormal]; done.titleLabel.font = [UIFont boldSystemFontOfSize:15]; done.tintColor = UIColor.whiteColor; [card addSubview:done];
    [done addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { [UIView animateWithDuration:0.16 animations:^{ overlay.alpha = 0; } completion:^(__unused BOOL done) { [overlay removeFromSuperview]; weakSelf.musicSettingsOverlay = nil; }]; }] forControlEvents:UIControlEventTouchUpInside];
    refresh();
    // The Music Lab remains pinned over the game: no sheet drag, slide-in, or
    // moving card competes with a knob gesture.
    [UIView animateWithDuration:0.16 animations:^{ overlay.alpha = 1; }];
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
