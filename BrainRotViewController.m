// BrainRotViewController.m
// BrainRotGame
// EZCompleteUI v3.2
//
// Purpose:
//   Main game view controller for BrainRot — a top-down AI-generated maze
//   game. Owns the complete game lifecycle: new-run asset generation via the
//   br-ai edge function, saved-game loading from BRGameLibrary, player
//   movement and combat, item collection, HUD rendering, level-end card,
//   high-score submission, and the scrolling marquee banner. Audio is managed
//   here too: looping background music and reactive sound effects for all
//   meaningful player actions. Navigation into and out of this screen is
//   coordinated via block callbacks rather than tight coupling to child VCs.
//
// Changes from v3.1:
//   - Removed dispatch_async from the initial picker presentation in
//     viewDidAppear:. The async dispatch was added to guarantee the view is
//     in the window before presentViewController: runs, but viewDidAppear:
//     already provides that guarantee. The one-frame defer just left
//     BrainRotVC's view visible for an extra run-loop tick before the picker
//     appeared — now presentViewController is called synchronously.
//   - showGamePicker now presents the picker with animated:NO. The main VC
//     already presents BrainRotViewController with animated:NO, so there is
//     no visual transition to BrainRotVC itself. The picker appearing with
//     animated:YES on top of an already-animated BrainRotVC was the "two
//     animations" the player noticed as a delay. Net result: tap "BrainRot"
//     in the main app → picker appears instantly with no intermediate state.
//   - See BRGamePickerViewController v2.8 for the matching dismiss fix
//     (collapsing both BrainRotVC + picker into one dismiss animation).
//
// Changes from v3.0:
//   - bannerContainerView added to setGameChromeHidden:. The banner was
//     briefly visible (empty, colored border, no content) during the
//     BrainRotVC → picker transition. Hidden until a game actually starts.
//
// Changes from v2.7:
//   - FIXED: when BrainRotViewController first appeared, the player briefly
//     saw the empty game grid, d-pad, and HUD (no game loaded) before the
//     Game Picker slid in on top. On dismiss (X button, no game selected),
//     this same empty chrome was visible again while BrainRotViewController
//     was dismissing. Fixed via a new setGameChromeHidden: method that hides
//     all game-playing UI (gameView, playerImageView, HUD, d-pad, action/
//     restart/pause buttons) at the end of viewDidLoad and shows them only
//     at the start of startNewRun and loadGameRecord:. The scores banner is
//     unaffected — it stays visible at all times.
//   - HUD split into two rows. Row 1: HP hearts (left) and pause/restart
//     controls (right). Row 2: full-width level/score/items label. The
//     previous single-row layout squeezed all three into the space left after
//     the hearts, causing truncation on smaller screens.
//   - hudLabel format string widened: "Level %ld   Score: %ld   Items: %lu".
//   - Banner raised: effective top offset clamped to MAX(6, safeAreaInsets.top
//     - 24) to reclaim up to 24 pt of dead black space on Dynamic Island
//     devices. Banner height increased from 28 pt to 30 pt with the saved room.
//   Main game view controller for BrainRot — a top-down AI-generated maze game.
//   Owns the full game lifecycle: new-run asset generation, saved-game loading,
//   player movement and combat, HUD, level-end card, high-score submission, and
//   the marquee banner. Also manages all audio: looping background music and
//   reactive sound effects for every meaningful player action.
//
// Changes from v2.6:
//   - v2.6's fix for the "bare UI flashes before the picker" issue made
//     loadingOverlayView visible-by-default with "Creating your game…" +
//     spinner — which then showed on EVERY launch before the picker
//     appeared, even though nothing was being generated. Reverted: the
//     overlay is hidden by default again (back to v2.5), and
//     resetLoadingOverlayToPhase1WithStatusText: has been removed —
//     startNewRun's phase-1 reset (the only thing that should show this
//     overlay) is back to being self-contained.
//   - The actual fix for "bare UI flashes before the picker": the initial
//     showGamePicker/startNewRun kickoff moved from viewDidLoad's 0.1s
//     dispatch_after to a one-shot dispatch_async (no delay) in
//     viewDidAppear:, guarded by _hasPresentedInitialFlow. The view is
//     guaranteed to be in the window by viewDidAppear, so this reduces the
//     gap from ~100ms to ~1 frame.
//   - NEW: BRGamePickerViewController.onClosedWithoutSelection (see that
//     file's v2.2 changes) fires when the picker's "✕" is tapped with
//     nothing selected. showGamePicker now wires this to
//     dismissSelfBackToCaller, a new method that dismisses (if presented
//     modally) or pops (if pushed) THIS view controller — because its own
//     gameView/d-pad/HUD are just leftover chrome from before the picker
//     appeared, "closing the picker" should mean "leave this screen", not
//     "reveal that chrome". If neither applies, logs rather than failing
//     silently or risking a broken navigation state.
//
// Changes from v2.4:
//   - AVFoundation audio system added.
//   - Background music loops automatically from game start through end card.
//     Three theme tracks in Resources/sounds/ (brainrot-theme1/2/3.mp3);
//     theme1 is the primary loop (70% weight), theme2 and theme3 play
//     occasionally for variety.
//   - Nine categorised SFX in Resources/sounds/ (.aiff), preloaded at launch:
//       player-movement / player-movement2   — random variant on each step
//       found-item      / found-item2        — random variant on item pickup
//       hurt-player     / hurt-player2       — random variant when player is hit
//       wall-blast-success                   — wall breached or bare-hands crumble
//       wall-blast-fail                      — wall breach failure (warden spawns)
//       enemy-died                           — enemy defeated via Use action
//   - setupAudioSession, preloadSoundEffects, startBackgroundMusic,
//     stopBackgroundMusic, fadeOutAndStopPlayer:, playSoundNamed:,
//     playRandomVariantOfSound:variantCount: added under #pragma mark - Audio.
//   - Music starts in startNewRun (loading screen), loadGameRecord:, and
//     playAgainRun. Fades out in viewDidDisappear:.
//
// Changes from v1.5:
//   - flavorLabel removed entirely. The 76pt story-text strip is gone;
//     that vertical space is reclaimed by the game grid (~80-100pt taller).
//   - Story now told during loading only. The loading overlay is a 3-phase
//     story theater:
//       Phase 1 — spinner + small status text while premise API call runs.
//       Phase 2 — big story title + body fades in once premise JSON arrives;
//                 images continue generating in background while player reads.
//       Phase 3 — "▶ TAP TO BEGIN" appears once all assets are ready.
//                 Player taps when they want; overlay fades and game starts.
//   - All in-game callBrainRotAI narration removed from useAction and
//     attemptMoveByDeltaCol:deltaRow:. Game logic (score, inventory, HP,
//     tile mutation) is identical; the blocking chatbot commentary is gone.
//     callBrainRotAI is still used for asset building (premise + image prompts).
//   - Win/loss replaced UIAlertController with showLevelEndCardWithTitle:
//     subtitle:score:isWin: — a full-screen cinematic card with large text
//     and embedded high-score name entry.
//   - HUD compacted to one line: HP hearts + Score + item count.
//   - Layout recalculated: banner(28) → hud(22) → grid(max) → dpad+buttons.
//   - Renamed movePlayerImageToCol:row:animated: → repositionPlayerImageAnimated:
//     (it reads playerCol/Row from model directly; no redundant params).
//   - extractJSONDictFromString: helper pulled out of buildGameAssetsWithCompletion:
//     for clarity and reuse.
//   - Play Again added to level-end card (replays same seed + saved assets, zero
//     API calls). New Run still generates a fresh world.
//   - restartBtn relocated from next to the d-pad to the HUD row (top of screen)
//     so accidental taps during frantic movement are not possible.
//     Bottom action row is now Use-only (full width).
//   - savedRunSeed + savedRunAssets stored on completion so Play Again works.
//   - Enemy indicators now always drawn in BRGameView (v1.3) so players can
//     see what they are walking into regardless of sprite-sheet load success.

#import "BrainRotViewController.h"
#import "BRGameModel.h"
#import "BRGameView.h"
#import "BRGameLibrary.h"
#import "BRGamePickerViewController.h"
#import "BRCustomGameCreatorViewController.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - UITextField (MaxLength) category

@interface UITextField (MaxLength)
@property (nonatomic, assign) IBInspectable NSUInteger maxLength;
@end

@implementation UITextField (MaxLength)

static const void *kBRMaxLengthKey     = &kBRMaxLengthKey;
static const void *kBRObserverAddedKey = &kBRObserverAddedKey;

- (void)setMaxLength:(NSUInteger)maxLength {
    objc_setAssociatedObject(self, kBRMaxLengthKey, @(maxLength), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNumber *added = objc_getAssociatedObject(self, kBRObserverAddedKey);
    if (!added.boolValue) {
        [self addTarget:self action:@selector(br_enforceMaxLength:)
               forControlEvents:UIControlEventEditingChanged];
        objc_setAssociatedObject(self, kBRObserverAddedKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (NSUInteger)maxLength {
    NSNumber *stored = objc_getAssociatedObject(self, kBRMaxLengthKey);
    return stored ? stored.unsignedIntegerValue : 0;
}

- (void)br_enforceMaxLength:(UITextField *)textField {
    NSUInteger maxAllowed = self.maxLength;
    if (maxAllowed == 0) return;
    NSString *currentText = textField.text ?: @"";
    if (currentText.length <= maxAllowed) return;
    UITextRange *selection    = self.selectedTextRange;
    NSInteger    cursorOffset = selection
        ? [self offsetFromPosition:self.beginningOfDocument toPosition:selection.start] : 0;
    textField.text = [currentText substringToIndex:maxAllowed];
    NSInteger      clampedOffset = MIN((NSInteger)maxAllowed, cursorOffset);
    UITextPosition *newPosition  = [self positionFromPosition:self.beginningOfDocument
                                                       offset:clampedOffset];
    if (newPosition) {
        self.selectedTextRange = [self textRangeFromPosition:newPosition toPosition:newPosition];
    }
}

@end

#pragma mark - BrainRotViewController interface

@interface BrainRotViewController () <UITextFieldDelegate> {
    BOOL _endCardFired; // guards against double-triggering win/loss end card
    BOOL _hasPresentedInitialFlow; // guards the one-shot picker/startNewRun kickoff in viewDidAppear:
}

// ── Marquee banner ────────────────────────────────────────────────────────────
@property (nonatomic, strong) UIView        *bannerContainerView;
@property (nonatomic, strong) UILabel       *bannerLabel;
@property (nonatomic, strong) CADisplayLink *bannerDisplayLink;
@property (nonatomic, assign) CGFloat        bannerScrollOffset;
@property (nonatomic, strong) CADisplayLink *heartPulseDisplayLink;

// ── Compact single-line HUD ───────────────────────────────────────────────────
@property (nonatomic, strong) UILabel   *hudLabel;
@property (nonatomic, strong) UIView    *hudHeartContainer;
@property (nonatomic, strong) NSArray<UIImageView *> *hudHeartImageViews;
@property (nonatomic, strong) UIImage   *hudHeartFilledSymbol;
@property (nonatomic, strong) UIImage   *hudHeartEmptySymbol;
@property (nonatomic, assign) NSInteger lastDisplayedPlayerHP;
@property (nonatomic, strong) UIButton  *pauseBtn;
@property (nonatomic, assign) BOOL       isPaused;

// ── Game views ────────────────────────────────────────────────────────────────
// backgroundImageView removed in v2.0 — background image is now rendered
// inside BRGameView.drawRect, cropped to the viewport, so it scrolls in
// perfect sync with the tile overlay. See BRGameView v1.5.
@property (nonatomic, strong) BRGameView  *gameView;
@property (nonatomic, strong) UIImageView *playerImageView;
@property (nonatomic, strong) UIImage     *enemyImage;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImageView *> *enemyImageViews;

// ── Story/loading overlay (3-phase) ──────────────────────────────────────────
@property (nonatomic, strong) UIView                  *loadingOverlayView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) UILabel                 *loadingPhaseLabel;  // small status (phase 1)
@property (nonatomic, strong) UILabel                 *storyTitleLabel;    // big theme name (phase 2+)
@property (nonatomic, strong) UILabel                 *storyBodyLabel;     // premise text (phase 2+)
@property (nonatomic, strong) UIButton                *beginButton;        // tap-to-begin (phase 3)
@property (nonatomic, copy)   dispatch_block_t         beginButtonAction;  // set when assets ready

// ── Level-end card ────────────────────────────────────────────────────────────
@property (nonatomic, strong) UIView *levelEndCardView;

// ── Controls ──────────────────────────────────────────────────────────────────
@property (nonatomic, strong) UIButton *upBtn;
@property (nonatomic, strong) UIButton *downBtn;
@property (nonatomic, strong) UIButton *leftBtn;
@property (nonatomic, strong) UIButton *rightBtn;
@property (nonatomic, strong) UIButton *actionBtn;
@property (nonatomic, strong) UIButton *restartBtn;

// ── Model / state ─────────────────────────────────────────────────────────────
@property (nonatomic, strong) BRGameModel                *model;
@property (nonatomic, strong) NSMutableArray<NSString *> *inventory;
@property (nonatomic, assign) NSInteger                   score;
@property (nonatomic, strong) NSTimer                    *tickTimer;
@property (nonatomic, assign) NSInteger                   tickCount;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *enemyPositions;
@property (nonatomic, assign) NSInteger                   currentLevel;      ///< 1-based, carries across levels in a run
@property (nonatomic, assign) NSInteger                   scoreAtLevelStart; ///< score when the current level began (for Retry)

// ── Boss fight ────────────────────────────────────────────────────────────────
@property (nonatomic, assign) BOOL                         bossFightActive;
@property (nonatomic, assign) NSInteger                    bossHP;
@property (nonatomic, assign) NSInteger                    bossMaxHP;
@property (nonatomic, assign) BOOL                         bossIsBlocking;
@property (nonatomic, assign) BOOL                         bossStunned;
@property (nonatomic, assign) BOOL                         playerIsBlocking;
@property (nonatomic, assign) BOOL                         playerIsDucking;
@property (nonatomic, assign) BOOL                         playerInvincible;
@property (nonatomic, strong) NSTimer                     *bossFightTimer;
@property (nonatomic, weak)   UIView                      *bossFightOverlay;
@property (nonatomic, weak)   UIImageView                 *bossPlayerSpriteView;
@property (nonatomic, weak)   UIImageView                 *bossEnemySpriteView;
@property (nonatomic, weak)   UILabel                     *bossComboLabel;
@property (nonatomic, strong) NSMutableArray<NSString *>  *bossComboBuffer;
@property (nonatomic, strong) NSTimer                     *bossComboWindowTimer;

// ── Current game record (set after save, used by Play Again) ────────────────────
@property (nonatomic, strong, nullable) BRGameRecord *currentGameRecord;

// ── Saved run — for Play Again ────────────────────────────────────────────────
// Stored once all assets are ready so playAgainRun can skip API calls.
@property (nonatomic, strong) NSNumber     *savedRunSeed;    // same maze topology
@property (nonatomic, strong) NSDictionary *savedRunAssets;  // images + text from last build

// ── Audio ─────────────────────────────────────────────────────────────────────
// musicPlayer loops background music throughout gameplay. sfxPlayers holds one
// pre-loaded AVAudioPlayer per sound effect, keyed by the filename (sans extension).
// Both are set up once in viewDidLoad and reused for the lifetime of the controller.
@property (nonatomic, strong) AVAudioPlayer                          *musicPlayer;
@property (nonatomic, strong) NSMutableDictionary<NSString *,
                                                  AVAudioPlayer *>   *sfxPlayers;

// ── Maze template image ───────────────────────────────────────────────────────
// B&W rendering of the model's tile layout, passed as a reference image to the
// background image API call so the AI skins a known-good topology rather than
// inventing one that may have disconnected paths or no route to the exit.
@property (nonatomic, strong) NSData *savedMazeTemplateImageData;

@end

#pragma mark - BrainRotViewController implementation

@implementation BrainRotViewController

static NSString *const kBRBrainRotAIURL = @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/br-ai";
NSString *const kBRHighScoreURL  = @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/br-highscores";

static const NSInteger kBRMaxHeartDisplay = 3;

// File-scope keys for associated objects attached to the end-card submit button.
// Must be file-scope so checkHighScoreQualificationForScore: (setter) and
// submitScoreFromEndCard: (getter) resolve to the same pointer address.
static const void *kBREndCardNameFieldKey              = &kBREndCardNameFieldKey;
static const void *kBREndCardFinalScoreKey             = &kBREndCardFinalScoreKey;
static const void *kBREndCardNavigateAfterSubmitKey    = &kBREndCardNavigateAfterSubmitKey;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    _endCardFired = NO;

    // Audio must be configured before any game starts so SFX are ready to fire
    // the instant the player taps a button for the first time.
    [self setupAudioSession];
    [self preloadSoundEffects];

    // ── Marquee banner ────────────────────────────────────────────────────────
    self.bannerContainerView = [[UIView alloc] init];
    self.bannerContainerView.backgroundColor   = [UIColor colorWithRed:0.05 green:0.0 blue:0.15 alpha:1.0];
    self.bannerContainerView.layer.borderColor = [UIColor systemPurpleColor].CGColor;
    self.bannerContainerView.layer.borderWidth = 1.0;
    self.bannerContainerView.clipsToBounds     = YES;
    [self.view addSubview:self.bannerContainerView];

    self.bannerLabel = [[UILabel alloc] init];
    self.bannerLabel.font            = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightBold];
    self.bannerLabel.textColor       = [UIColor systemYellowColor];
    self.bannerLabel.backgroundColor = [UIColor clearColor];
    self.bannerLabel.text            = @"🕹 BRAINROT";
    [self.bannerLabel sizeToFit];
    [self.bannerContainerView addSubview:self.bannerLabel];
    [self fetchHighScoresForBanner];

    // ── Compact HUD (one line: hearts + score + item count) ───────────────────
    self.hudLabel = [[UILabel alloc] init];
    self.hudLabel.font          = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBold];
    self.hudLabel.textColor     = [UIColor whiteColor];
    self.hudLabel.textAlignment = NSTextAlignmentCenter;
    self.hudLabel.text          = @"L1   Score: 0   Items: 0";
    [self.view addSubview:self.hudLabel];

    UIImageSymbolConfiguration *heartConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIFontWeightSemibold];
    self.hudHeartFilledSymbol = [[UIImage systemImageNamed:@"heart.fill"
                                                withConfiguration:heartConfig]
                                 imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.hudHeartEmptySymbol = [[UIImage systemImageNamed:@"heart"
                                               withConfiguration:heartConfig]
                                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    self.hudHeartContainer = [[UIView alloc] init];
    self.hudHeartContainer.backgroundColor = [UIColor clearColor];
    self.hudHeartContainer.userInteractionEnabled = NO;
    [self.view addSubview:self.hudHeartContainer];

    NSMutableArray<UIImageView *> *heartViews = [NSMutableArray arrayWithCapacity:kBRMaxHeartDisplay];
    for (NSInteger i = 0; i < kBRMaxHeartDisplay; i++) {
        UIImageView *heartView = [[UIImageView alloc] initWithImage:self.hudHeartEmptySymbol];
        heartView.contentMode = UIViewContentModeScaleAspectFit;
        heartView.tintColor = [UIColor colorWithWhite:0.45 alpha:1.0];
        heartView.layer.shadowColor = [UIColor systemRedColor].CGColor;
        heartView.layer.shadowOpacity = 0.25;
        heartView.layer.shadowOffset = CGSizeZero;
        heartView.layer.shadowRadius = 3;
        [self.hudHeartContainer addSubview:heartView];
        [heartViews addObject:heartView];
    }
    self.hudHeartImageViews = [heartViews copy];
    self.lastDisplayedPlayerHP = -1;
    [self startHUDHeartLoopAnimation];

    // Background image is rendered inside BRGameView (v1.5), so no separate
    // UIImageView is needed. gameView.backgroundImage drives everything.

    // ── Game view (transparent tile overlay in image mode) ────────────────────
    self.gameView                     = [[BRGameView alloc] init];
    self.gameView.backgroundColor     = [UIColor colorWithWhite:0.1 alpha:1.0];
    self.gameView.layer.cornerRadius  = 8;
    self.gameView.layer.masksToBounds = YES;
    [self.view addSubview:self.gameView];

    // ── Player image view ─────────────────────────────────────────────────────
    self.playerImageView               = [[UIImageView alloc] init];
    self.playerImageView.contentMode   = UIViewContentModeScaleAspectFill;
    self.playerImageView.clipsToBounds = YES;
    self.playerImageView.layer.borderColor = [UIColor whiteColor].CGColor;
    self.playerImageView.layer.borderWidth = 1.5;
    self.playerImageView.hidden        = YES;
    [self.view addSubview:self.playerImageView];

    self.enemyImageViews = [NSMutableDictionary dictionary];
    self.enemyPositions  = [NSMutableDictionary dictionary];

    // ── Loading / story overlay ───────────────────────────────────────────────
    [self buildLoadingOverlay];
    [self.view addSubview:self.loadingOverlayView];

    // ── D-pad ─────────────────────────────────────────────────────────────────
    self.upBtn    = [self makeArrowButtonWithTitle:@"▲"  selector:@selector(moveUp)];
    self.downBtn  = [self makeArrowButtonWithTitle:@"▼"  selector:@selector(moveDown)];
    self.leftBtn  = [self makeArrowButtonWithTitle:@"◀︎" selector:@selector(moveLeft)];
    self.rightBtn = [self makeArrowButtonWithTitle:@"▶︎" selector:@selector(moveRight)];
    [self.view addSubview:self.upBtn];
    [self.view addSubview:self.downBtn];
    [self.view addSubview:self.leftBtn];
    [self.view addSubview:self.rightBtn];

    // ── Action + restart buttons ──────────────────────────────────────────────
    self.actionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.actionBtn setTitle:@"⚡ Use" forState:UIControlStateNormal];
    self.actionBtn.titleLabel.font    = [UIFont boldSystemFontOfSize:15];
    self.actionBtn.tintColor          = [UIColor systemYellowColor];
    self.actionBtn.layer.cornerRadius = 8;
    self.actionBtn.layer.borderWidth  = 1;
    self.actionBtn.layer.borderColor  = [UIColor systemYellowColor].CGColor;
    [self.actionBtn addTarget:self action:@selector(useAction)
             forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.actionBtn];

    // restartBtn lives in the HUD row at the top — far from the d-pad.
    // This prevents accidental "New Run" taps while tapping movement arrows.
    self.restartBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.restartBtn setTitle:@"↺" forState:UIControlStateNormal];

    self.pauseBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.pauseBtn setTitle:@"⏸" forState:UIControlStateNormal];
    [self.pauseBtn setTitle:@"▶︎" forState:UIControlStateSelected];
    self.pauseBtn.titleLabel.font    = [UIFont systemFontOfSize:16];
    self.pauseBtn.tintColor          = [UIColor colorWithWhite:0.85 alpha:1.0];
    self.pauseBtn.backgroundColor    = [UIColor colorWithWhite:0.2 alpha:0.85];
    self.pauseBtn.layer.cornerRadius = 8;
    self.pauseBtn.layer.borderColor  = [UIColor colorWithWhite:0.5 alpha:0.5].CGColor;
    self.pauseBtn.layer.borderWidth  = 0.5;
    [self.pauseBtn addTarget:self action:@selector(togglePause)
            forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.pauseBtn];
    self.restartBtn.titleLabel.font    = [UIFont boldSystemFontOfSize:18];
    self.restartBtn.tintColor          = [UIColor colorWithWhite:0.5 alpha:1.0];
    self.restartBtn.layer.cornerRadius = 6;
    self.restartBtn.layer.borderWidth  = 1;
    self.restartBtn.layer.borderColor  = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    [self.restartBtn addTarget:self action:@selector(startNewRun)
              forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.restartBtn];

    [self layoutViews];

    self.inventory = [NSMutableArray array];

    // Hidden until startNewRun's phase-1 reset shows it. (v2.6 briefly made
    // this visible-by-default to cover the gap before the picker appears,
    // but that meant "Creating your game…" + spinner showed even when
    // nothing was being created — see viewDidAppear: for the real fix.)
    self.loadingOverlayView.hidden = YES;
    self.loadingOverlayView.alpha  = 0;

    // Hide the game-playing UI until an actual game is selected. Without
    // this, the player briefly sees an empty maze grid, d-pad, and "Score: 0"
    // HUD every time BrainRotViewController appears — on first open before
    // the picker slides in, and on dismiss (X button, no selection) while
    // this VC is still transitioning out. setGameChromeHidden:NO is called
    // at the start of both loadGameRecord: and startNewRun.
    [self setGameChromeHidden:YES];

    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                      target:self
                                                    selector:@selector(tick)
                                                    userInfo:nil
                                                     repeats:YES];
}

#pragma mark - Loading Overlay Construction

/// Builds the 3-phase story theater overlay.
/// Phase 1: spinner + small status text while premise call runs.
/// Phase 2: big title + body text fades in when premise arrives; images still generating.
/// Phase 3: spinner hides, "TAP TO BEGIN" button appears when all assets are ready.
- (void)buildLoadingOverlay {
    self.loadingOverlayView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.loadingOverlayView.backgroundColor  = [UIColor colorWithRed:0.04 green:0.0 blue:0.12 alpha:0.97];
    self.loadingOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // Phase 1 — spinner
    self.loadingSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingSpinner.color = [UIColor systemYellowColor];
    self.loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadingSpinner startAnimating];
    [self.loadingOverlayView addSubview:self.loadingSpinner];

    // Phase 1 — small status text
    self.loadingPhaseLabel = [UILabel new];
    self.loadingPhaseLabel.text          = @"Creating your game…";
    self.loadingPhaseLabel.font          = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.loadingPhaseLabel.textColor     = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.loadingPhaseLabel.textAlignment = NSTextAlignmentCenter;
    self.loadingPhaseLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadingOverlayView addSubview:self.loadingPhaseLabel];

    // Phase 2 — big theme title
    self.storyTitleLabel = [UILabel new];
    self.storyTitleLabel.font          = [UIFont monospacedSystemFontOfSize:30 weight:UIFontWeightBold];
    self.storyTitleLabel.textColor     = [UIColor systemYellowColor];
    self.storyTitleLabel.textAlignment = NSTextAlignmentCenter;
    self.storyTitleLabel.numberOfLines = 2;
    self.storyTitleLabel.alpha         = 0;
    self.storyTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadingOverlayView addSubview:self.storyTitleLabel];

    // Phase 2 — premise body text
    self.storyBodyLabel = [UILabel new];
    self.storyBodyLabel.font          = [UIFont systemFontOfSize:19 weight:UIFontWeightMedium];
    self.storyBodyLabel.textColor     = [UIColor colorWithWhite:0.90 alpha:1.0];
    self.storyBodyLabel.textAlignment = NSTextAlignmentCenter;
    self.storyBodyLabel.numberOfLines = 0;
    self.storyBodyLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.storyBodyLabel.alpha         = 0;
    self.storyBodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loadingOverlayView addSubview:self.storyBodyLabel];

    // Phase 3 — begin button
    self.beginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.beginButton setTitle:@"▶  TAP TO BEGIN" forState:UIControlStateNormal];
    self.beginButton.titleLabel.font  = [UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightBold];
    self.beginButton.tintColor        = [UIColor blackColor];
    self.beginButton.backgroundColor  = [UIColor systemYellowColor];
    self.beginButton.layer.cornerRadius = 12;
    self.beginButton.alpha            = 0;
    self.beginButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.beginButton addTarget:self action:@selector(beginButtonTapped)
               forControlEvents:UIControlEventTouchUpInside];
    [self.loadingOverlayView addSubview:self.beginButton];

    [NSLayoutConstraint activateConstraints:@[
        // Spinner — vertically centered, slightly above midpoint
        [self.loadingSpinner.centerXAnchor constraintEqualToAnchor:self.loadingOverlayView.centerXAnchor],
        [self.loadingSpinner.centerYAnchor constraintEqualToAnchor:self.loadingOverlayView.centerYAnchor constant:-40],
        // Phase status text — below spinner
        [self.loadingPhaseLabel.centerXAnchor constraintEqualToAnchor:self.loadingOverlayView.centerXAnchor],
        [self.loadingPhaseLabel.topAnchor constraintEqualToAnchor:self.loadingSpinner.bottomAnchor constant:14],
        [self.loadingPhaseLabel.leadingAnchor constraintEqualToAnchor:self.loadingOverlayView.leadingAnchor constant:32],
        [self.loadingPhaseLabel.trailingAnchor constraintEqualToAnchor:self.loadingOverlayView.trailingAnchor constant:-32],
        // Story title — upper portion (leaves room for body and button below)
        [self.storyTitleLabel.centerXAnchor constraintEqualToAnchor:self.loadingOverlayView.centerXAnchor],
        [self.storyTitleLabel.topAnchor constraintEqualToAnchor:self.loadingOverlayView.topAnchor constant:100],
        [self.storyTitleLabel.leadingAnchor constraintEqualToAnchor:self.loadingOverlayView.leadingAnchor constant:28],
        [self.storyTitleLabel.trailingAnchor constraintEqualToAnchor:self.loadingOverlayView.trailingAnchor constant:-28],
        // Story body — below title
        [self.storyBodyLabel.centerXAnchor constraintEqualToAnchor:self.loadingOverlayView.centerXAnchor],
        [self.storyBodyLabel.topAnchor constraintEqualToAnchor:self.storyTitleLabel.bottomAnchor constant:24],
        [self.storyBodyLabel.leadingAnchor constraintEqualToAnchor:self.loadingOverlayView.leadingAnchor constant:32],
        [self.storyBodyLabel.trailingAnchor constraintEqualToAnchor:self.loadingOverlayView.trailingAnchor constant:-32],
        // Begin button — near bottom
        [self.beginButton.centerXAnchor constraintEqualToAnchor:self.loadingOverlayView.centerXAnchor],
        [self.beginButton.bottomAnchor constraintEqualToAnchor:self.loadingOverlayView.bottomAnchor constant:-80],
        [self.beginButton.widthAnchor constraintEqualToConstant:240],
        [self.beginButton.heightAnchor constraintEqualToConstant:52],
    ]];
}


#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutViews];
}

- (void)layoutViews {
    CGFloat screenWidth  = CGRectGetWidth(self.view.bounds);
    CGFloat screenHeight = CGRectGetHeight(self.view.bounds);

    // Clamp the top offset so the banner sits closer to the actual screen edge.
    // Dynamic Island phones have safeAreaInsets.top ≈ 59 pt, leaving large
    // dead black space above the banner when consumed in full. Subtracting 24 pt
    // reclaims that space while keeping ≥ 6 pt below the status bar so we never
    // clip the clock or battery indicator. On flat-top devices the MAX clamp
    // keeps a 6 pt minimum regardless.
    CGFloat rawSafeTop  = self.view.safeAreaInsets.top;
    CGFloat safeTop     = (rawSafeTop > 0) ? MAX(6.0, rawSafeTop - 24.0) : 6.0;
    CGFloat safeBottom  = self.view.safeAreaInsets.bottom;
    CGFloat sideMargin  = 10;

    // ── Banner ────────────────────────────────────────────────────────────────
    // 30 pt — taller than the previous 28 pt, using space recovered by the
    // safeTop reduction above.
    CGFloat bannerHeight = 30;
    self.bannerContainerView.frame = CGRectMake(0, safeTop, screenWidth, bannerHeight);
    CGFloat bannerLabelCenterY = bannerHeight / 2.0;
    CGFloat bannerLabelH       = CGRectGetHeight(self.bannerLabel.frame);
    self.bannerLabel.frame = CGRectMake(self.bannerScrollOffset,
                                        bannerLabelCenterY - bannerLabelH / 2.0,
                                        CGRectGetWidth(self.bannerLabel.frame),
                                        bannerLabelH);

    // ── HUD row 1: HP hearts (left) + pause/restart controls (right) ─────────
    // Controls on this row (far from d-pad) prevent accidental restart taps
    // during play. Giving hearts their own row removes the horizontal crowding
    // that caused the stats label to truncate on smaller screens.
    CGFloat hudRowOneHeight = 26;
    CGFloat hudControlWidth = 36;
    CGFloat hudRowOneTop    = safeTop + bannerHeight + 2;

    self.restartBtn.frame = CGRectMake(screenWidth - sideMargin - hudControlWidth,
                                       hudRowOneTop, hudControlWidth, hudRowOneHeight);
    self.pauseBtn.frame   = CGRectMake(screenWidth - sideMargin - hudControlWidth * 2 - 4,
                                       hudRowOneTop, hudControlWidth, hudRowOneHeight);

    CGFloat heartSize           = 22;
    CGFloat heartSpacing        = 4;
    CGFloat heartContainerWidth = kBRMaxHeartDisplay * heartSize
                                  + (kBRMaxHeartDisplay - 1) * heartSpacing;
    self.hudHeartContainer.frame = CGRectMake(sideMargin, hudRowOneTop,
                                              heartContainerWidth, hudRowOneHeight);
    for (NSInteger idx = 0; idx < (NSInteger)self.hudHeartImageViews.count; idx++) {
        UIImageView *heartView = self.hudHeartImageViews[idx];
        CGFloat xOffset = idx * (heartSize + heartSpacing);
        heartView.frame = CGRectMake(xOffset, (hudRowOneHeight - heartSize) / 2.0,
                                     heartSize, heartSize);
    }

    // ── HUD row 2: level / score / item count ─────────────────────────────────
    // Full screen width — no truncation regardless of inventory count.
    CGFloat hudRowTwoHeight = 20;
    CGFloat hudRowTwoTop    = hudRowOneTop + hudRowOneHeight + 3;
    self.hudLabel.frame = CGRectMake(sideMargin, hudRowTwoTop,
                                     screenWidth - sideMargin * 2, hudRowTwoHeight);

    // ── Game grid — use all remaining space above button area ─────────────────
    // Button area: up-row(40) + gap(6) + left/down/right-row(40) + gap(8) + action-row(40) + safeBottom + pad(8)
    CGFloat buttonAreaHeight = 40 + 6 + 40 + 8 + 40 + safeBottom + 8;
    CGFloat gridTop          = CGRectGetMaxY(self.hudLabel.frame) + 4;
    CGFloat gridAvailable    = screenHeight - gridTop - buttonAreaHeight;
    CGFloat gridSize         = MIN(screenWidth - sideMargin * 2, MAX(200, gridAvailable));
    CGFloat gridLeft         = (screenWidth - gridSize) / 2.0;

    self.gameView.frame = CGRectMake(gridLeft, gridTop, gridSize, gridSize);

    if (!self.playerImageView.hidden && self.model) {
        [self repositionPlayerImageAnimated:NO];
    }

    // ── D-pad ─────────────────────────────────────────────────────────────────
    CGFloat buttonW  = 54;
    CGFloat buttonH  = 40;
    CGFloat dpadTopY = CGRectGetMaxY(self.gameView.frame) + 8;
    CGFloat dpadCX   = screenWidth / 2.0;

    self.upBtn.frame    = CGRectMake(dpadCX - buttonW / 2.0, dpadTopY, buttonW, buttonH);
    self.downBtn.frame  = CGRectMake(dpadCX - buttonW / 2.0, dpadTopY + buttonH + 6, buttonW, buttonH);
    self.leftBtn.frame  = CGRectMake(dpadCX - buttonW * 1.5 - 6, dpadTopY + buttonH + 6, buttonW, buttonH);
    self.rightBtn.frame = CGRectMake(dpadCX + buttonW / 2.0  + 6, dpadTopY + buttonH + 6, buttonW, buttonH);

    // ── Action button — full width row; restart is in the HUD, not here ──────
    CGFloat actionRowY = CGRectGetMaxY(self.downBtn.frame) + 8;
    self.actionBtn.frame = CGRectMake(sideMargin, actionRowY,
                                      screenWidth - sideMargin * 2, 40);
}

/// Hides or reveals every piece of game-playing UI as a unit. Called with
/// YES at the end of viewDidLoad so the picker is the first thing the player
/// sees — no empty maze grid, zero-score HUD, d-pad, or unfilled banner.
/// Called with NO at the start of loadGameRecord: and startNewRun, the two
/// entry points that actually load game content. The loading overlay is
/// managed separately and is not affected by this method.
- (void)setGameChromeHidden:(BOOL)hidden {
    // Banner included here: the picker is full-screen so it covers
    // bannerContainerView while it's open anyway, but the empty/loading
    // banner with its colored border was briefly visible during the
    // BrainRotViewController→picker transition before content loaded.
    // Starting it hidden removes that flash entirely.
    self.bannerContainerView.hidden = hidden;
    self.gameView.hidden          = hidden;
    self.playerImageView.hidden   = hidden;
    self.hudLabel.hidden          = hidden;
    self.hudHeartContainer.hidden = hidden;
    self.pauseBtn.hidden          = hidden;
    self.restartBtn.hidden        = hidden;
    self.upBtn.hidden             = hidden;
    self.downBtn.hidden           = hidden;
    self.leftBtn.hidden           = hidden;
    self.rightBtn.hidden          = hidden;
    self.actionBtn.hidden         = hidden;
}

- (UIButton *)makeArrowButtonWithTitle:(NSString *)title selector:(SEL)selector {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font    = [UIFont boldSystemFontOfSize:22];
    button.tintColor          = [UIColor whiteColor];
    button.layer.cornerRadius = 8;
    button.layer.borderWidth  = 1;
    button.layer.borderColor  = [UIColor colorWithWhite:0.35 alpha:1.0].CGColor;
    button.backgroundColor    = [UIColor colorWithWhite:0.12 alpha:1.0];
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - Game Loop

- (void)togglePause {
    if (self.bossFightActive) {
        // In boss fight: pause/resume both the boss timer and freeze state
        if (!self.isPaused) {
            self.isPaused = YES;
            [self.bossFightTimer invalidate]; self.bossFightTimer = nil;
            [self.musicPlayer pause];
            self.pauseBtn.selected = YES;
            // Dim the boss overlay to signal pause
            UIView *dimmer = [[UIView alloc] initWithFrame:self.bossFightOverlay.bounds];
            dimmer.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
            dimmer.tag = 9999;
            [self.bossFightOverlay addSubview:dimmer];
            UILabel *pauseLbl = [UILabel new];
            pauseLbl.text = @"⏸  PAUSED"; pauseLbl.textAlignment = NSTextAlignmentCenter;
            pauseLbl.font = [UIFont monospacedSystemFontOfSize:26 weight:UIFontWeightBold];
            pauseLbl.textColor = [UIColor whiteColor];
            pauseLbl.frame = CGRectMake(0, self.bossFightOverlay.bounds.size.height / 2.0 - 20,
                                        self.bossFightOverlay.bounds.size.width, 44);
            pauseLbl.tag = 9998;
            [self.bossFightOverlay addSubview:pauseLbl];
        } else {
            self.isPaused = NO;
            self.pauseBtn.selected = NO;
            [[self.bossFightOverlay viewWithTag:9999] removeFromSuperview];
            [[self.bossFightOverlay viewWithTag:9998] removeFromSuperview];
            [self.musicPlayer play];
            self.bossFightTimer = [NSTimer scheduledTimerWithTimeInterval:2.4
                                                                    target:self
                                                                  selector:@selector(bossTick)
                                                                  userInfo:nil repeats:YES];
        }
    } else {
        // Normal gameplay pause
        if (!self.isPaused) {
            self.isPaused = YES;
            [self.tickTimer invalidate]; self.tickTimer = nil;
            [self.musicPlayer pause];
            self.pauseBtn.selected = YES;
            [self setGameInputEnabled:NO];
        } else {
            self.isPaused = NO;
            self.pauseBtn.selected = NO;
            [self.musicPlayer play];
            [self setGameInputEnabled:YES];
            if (!self.tickTimer || !self.tickTimer.isValid) {
                self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                                   target:self
                                                                 selector:@selector(tick)
                                                                 userInfo:nil repeats:YES];
            }
        }
    }
}

- (void)tick {
    self.tickCount++;
    if (self.tickCount % 2 == 0) [self moveEnemiesStep];
    [self.gameView setNeedsDisplay];
    [self updateHUD];
    [self refreshEnemyImageViews];
    [self checkForWinOrLoss];
}

- (void)updateHUD {
    if (!self.model) return;
    for (NSInteger heartIndex = 0; heartIndex < self.hudHeartImageViews.count; heartIndex++) {
        UIImageView *heartView = self.hudHeartImageViews[heartIndex];
        BOOL filled = heartIndex < self.model.playerHP;
        heartView.image = filled ? self.hudHeartFilledSymbol : self.hudHeartEmptySymbol;
        heartView.tintColor = filled ? [UIColor systemRedColor]
                                     : [UIColor colorWithWhite:0.45 alpha:1.0];
    }
    self.hudLabel.text = [NSString stringWithFormat:@"Level %ld   Score: %ld   Items: %lu",
                          (long)self.currentLevel, (long)self.score, (unsigned long)self.inventory.count];
    NSInteger previousHP = self.lastDisplayedPlayerHP;
    if (previousHP < 0) previousHP = self.model.playerHP;
    if (self.model.playerHP > previousHP) {
        [self animateHUDHeartGainFrom:previousHP to:self.model.playerHP];
    }
    self.lastDisplayedPlayerHP = self.model.playerHP;
}

- (void)startHUDHeartLoopAnimation {
    CABasicAnimation *loop = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    loop.fromValue = @1.0;
    loop.toValue = @1.06;
    loop.duration = 1.0;
    loop.autoreverses = YES;
    loop.repeatCount = INFINITY;
    loop.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.hudHeartContainer.layer addAnimation:loop forKey:@"hudHeartLoop"];
}

- (void)animateHUDHeartGainFrom:(NSInteger)previousHP to:(NSInteger)newHP {
    NSInteger startIndex = MIN(MAX(0, previousHP), kBRMaxHeartDisplay);
    NSInteger endIndex   = MIN(MAX(0, newHP), kBRMaxHeartDisplay);
    if (startIndex >= endIndex) return;
    for (NSInteger idx = startIndex; idx < endIndex; idx++) {
        UIImageView *heartView = self.hudHeartImageViews[idx];
        [self popHUDHeartView:heartView];
    }
}

- (void)popHUDHeartView:(UIImageView *)heartView {
    if (!heartView) return;
    CABasicAnimation *pop = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pop.fromValue = @1.0;
    pop.toValue = @1.35;
    pop.duration = 0.28;
    pop.autoreverses = YES;
    pop.repeatCount = 1;
    pop.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [heartView.layer addAnimation:pop forKey:@"hudHeartGainPop"];
}

- (void)startHeartPulseLink {
    [self stopHeartPulseLink];
    if (!self.gameView) return;
    self.gameView.heartPulsePhase = 0;
    self.heartPulseDisplayLink = [CADisplayLink displayLinkWithTarget:self
                                                              selector:@selector(heartPulseTick:)];
    [self.heartPulseDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopHeartPulseLink {
    [self.heartPulseDisplayLink invalidate];
    self.heartPulseDisplayLink = nil;
}

- (void)heartPulseTick:(CADisplayLink *)link {
    if (!self.gameView) return;
    CGFloat delta = link.duration * M_PI;
    CGFloat phase = self.gameView.heartPulsePhase + delta;
    if (phase > M_PI * 2) phase -= M_PI * 2;
    self.gameView.heartPulsePhase = phase;
    [self.gameView setNeedsDisplay];
}

- (void)checkForWinOrLoss {
    if (!self.model || _endCardFired) return;
    if (self.model.playerHP <= 0) {
        _endCardFired = YES;
        [self.tickTimer invalidate];
        self.tickTimer = nil;
        [self showLevelEndCardWithTitle:@"BUSTED"
                              subtitle:@"You collapsed. Better luck next time."
                                 score:self.score
                                 isWin:NO];
    } else if (self.model.playerCol == self.model.exitCol &&
               self.model.playerRow == self.model.exitRow) {
        _endCardFired = YES;
        [self.tickTimer invalidate];
        self.tickTimer = nil;
        // Reaching the exit triggers the boss fight. Scoring + end card happen
        // inside _bossFightVictory after the boss is defeated.
        [self startBossFight];
    }
}

#pragma mark - Level End Card

/// Dismisses the end card and routes appropriately.
/// Members see the full picker; non-members start a new run directly.
- (void)showGamePickerFromEndCard {
    [self.levelEndCardView removeFromSuperview];
    self.levelEndCardView = nil;
    if ([self userHasMembership]) {
        [self showGamePicker];
    } else {
        [self startNewRun];
    }
}

/// Full-screen cinematic end card. Replaces UIAlertController for win/loss so we
/// can style it and embed the high-score name field without nested alerts.
- (void)showLevelEndCardWithTitle:(NSString *)cardTitle
                         subtitle:(NSString *)cardSubtitle
                            score:(NSInteger)finalScore
                            isWin:(BOOL)isWin {
    [self.levelEndCardView removeFromSuperview];

    UIView *card = [[UIView alloc] initWithFrame:self.view.bounds];
    card.backgroundColor  = [UIColor colorWithRed:0.04 green:0.0 blue:0.12 alpha:0.96];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    card.alpha            = 0;
    self.levelEndCardView = card;
    [self.view addSubview:card];

    UILabel *titleLabel        = [UILabel new];
    titleLabel.text            = cardTitle;
    titleLabel.font            = [UIFont monospacedSystemFontOfSize:52 weight:UIFontWeightBold];
    titleLabel.textColor       = isWin ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    titleLabel.textAlignment   = NSTextAlignmentCenter;
    titleLabel.numberOfLines   = 2;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:titleLabel];

    UILabel *subtitleLabel     = [UILabel new];
    subtitleLabel.text         = cardSubtitle;
    subtitleLabel.font         = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    subtitleLabel.textColor    = [UIColor colorWithWhite:0.85 alpha:1.0];
    subtitleLabel.textAlignment = NSTextAlignmentCenter;
    subtitleLabel.numberOfLines = 2;
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:subtitleLabel];

    UILabel *scoreDisplayLabel  = [UILabel new];
    scoreDisplayLabel.text      = [NSString stringWithFormat:@"TOTAL  %ld", (long)finalScore];
    scoreDisplayLabel.font      = [UIFont monospacedSystemFontOfSize:38 weight:UIFontWeightBold];
    scoreDisplayLabel.textColor = [UIColor systemYellowColor];
    scoreDisplayLabel.textAlignment = NSTextAlignmentCenter;
    scoreDisplayLabel.translatesAutoresizingMaskIntoConstraints = NO;
    scoreDisplayLabel.tag = 9901; // used by checkHighScoreQualification to anchor banner
    [card addSubview:scoreDisplayLabel];

    // Primary action: "LEVEL N+1 →" on win, "↩ RETRY LEVEL" on loss
    UIButton *playAgainButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (isWin) {
        NSString *nextTitle = [NSString stringWithFormat:@"LEVEL %ld  →", (long)(self.currentLevel + 1)];
        [playAgainButton setTitle:nextTitle forState:UIControlStateNormal];
        [playAgainButton addTarget:self action:@selector(advanceToNextLevel)
                 forControlEvents:UIControlEventTouchUpInside];
    } else {
        [playAgainButton setTitle:@"↩  RETRY LEVEL" forState:UIControlStateNormal];
        [playAgainButton addTarget:self action:@selector(retryCurrentLevel)
                 forControlEvents:UIControlEventTouchUpInside];
    }
    playAgainButton.titleLabel.font    = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightBold];
    playAgainButton.tintColor          = [UIColor blackColor];
    playAgainButton.backgroundColor    = [UIColor systemYellowColor];
    playAgainButton.layer.cornerRadius = 12;
    playAgainButton.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:playAgainButton];

    // Secondary: "▶ NEW RUN" — always goes straight to the game picker
    UIButton *newRunButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [newRunButton setTitle:@"▶  NEW RUN" forState:UIControlStateNormal];
    [newRunButton addTarget:self action:@selector(showGamePickerFromEndCard)
          forControlEvents:UIControlEventTouchUpInside];
    newRunButton.titleLabel.font    = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium];
    newRunButton.tintColor          = [UIColor colorWithWhite:0.6 alpha:1.0];
    newRunButton.translatesAutoresizingMaskIntoConstraints = NO;
    playAgainButton.tag = 9902;
    newRunButton.tag    = 9903;
    [card addSubview:newRunButton];

    [NSLayoutConstraint activateConstraints:@[
        // Title — starts near the top so there's room for everything below
        [titleLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:120],
        // Bonus breakdown — tight under the title
        [subtitleLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:28],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-28],
        // Total score — extra gap so it reads as distinct from the bonus text
        [scoreDisplayLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [scoreDisplayLabel.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:24],
        // Play Again — anchored to bottom so it's always reachable
        [playAgainButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [playAgainButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-90],
        [playAgainButton.widthAnchor constraintEqualToConstant:220],
        [playAgainButton.heightAnchor constraintEqualToConstant:52],
        // New Run is secondary — smaller, dimmer, below Play Again
        [newRunButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [newRunButton.topAnchor constraintEqualToAnchor:playAgainButton.bottomAnchor constant:10],
    ]];

    [UIView animateWithDuration:0.5 animations:^{ card.alpha = 1.0; }];

    // Fire high score check immediately on death — no waiting for a button tap.
    // On win the check never runs (scores are submitted at end of a full run).
    if (!isWin) {
        [self checkHighScoreQualificationForScore:finalScore onCard:card aboveButton:newRunButton];
    }
}

/// Fetches top 10 scores. If this run qualifies, injects a name-entry field
/// and submit button into the already-visible end card. Non-qualifying runs: no-op.
///
/// Keyboard handling strategy:
///   - Card animates upward when keyboard appears so the name field is always visible.
///   - Return key dismisses the keyboard (textFieldShouldReturn:).
///   - Tapping anywhere outside the field on the card also dismisses the keyboard.
///   - Keyboard observers are removed when the card is removed from the hierarchy.
- (void)checkHighScoreQualificationForScore:(NSInteger)finalScore
                                     onCard:(UIView *)card
                                aboveButton:(UIButton *)newRunButton {
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:kBRHighScoreURL]];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSArray *topScores = nil;
        BOOL     qualifies = NO;
        NSInteger placement = 1; // 1-based rank this score would occupy
        if (data) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSArray class]]) topScores = parsed;
        }
        // Guard: if topScores is nil (network error / bad response) skip the check entirely
        if (!topScores) return;
        if (topScores.count < 10) {
            qualifies = YES;
            // Count how many existing scores beat us to find true placement
            placement = 1;
            for (NSDictionary *entry in topScores) {
                if ([entry[@"score"] integerValue] >= finalScore) placement++;
            }
        } else {
            qualifies = finalScore > [topScores.lastObject[@"score"] integerValue];
            if (qualifies) {
                placement = 1;
                for (NSDictionary *entry in topScores) {
                    if ([entry[@"score"] integerValue] >= finalScore) placement++;
                }
            }
        }
        if (!qualifies) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            // ── Name field ────────────────────────────────────────────────────
            UITextField *nameField       = [UITextField new];
            nameField.placeholder        = @"Enter your name";
            nameField.font               = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightRegular];
            nameField.textColor          = [UIColor whiteColor];
            nameField.textAlignment      = NSTextAlignmentCenter;
            nameField.backgroundColor    = [UIColor colorWithWhite:0.18 alpha:1.0];
            nameField.layer.cornerRadius = 10;
            nameField.layer.borderColor  = [UIColor systemYellowColor].CGColor;
            nameField.layer.borderWidth  = 1.5;
            nameField.returnKeyType      = UIReturnKeyDone;
            nameField.autocorrectionType = UITextAutocorrectionTypeNo;
            nameField.autocapitalizationType = UITextAutocapitalizationTypeWords;
            nameField.maxLength          = 20;
            nameField.delegate           = self;
            nameField.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:nameField];

            // ── Placement + "New High Score!" banner ──────────────────────────
            // Ordinal suffix: 1st, 2nd, 3rd, 4th…
            NSString *suffix;
            NSInteger mod100 = placement % 100;
            NSInteger mod10  = placement % 10;
            if (mod100 >= 11 && mod100 <= 13)      suffix = @"th";
            else if (mod10 == 1)                    suffix = @"st";
            else if (mod10 == 2)                    suffix = @"nd";
            else if (mod10 == 3)                    suffix = @"rd";
            else                                    suffix = @"th";

            NSString *bannerText = [NSString stringWithFormat:
                @"🎉 #%ld%@ — New High Score!", (long)placement, suffix];

            UILabel *newHighScoreLabel       = [UILabel new];
            newHighScoreLabel.text           = bannerText;
            newHighScoreLabel.font           = [UIFont boldSystemFontOfSize:21];
            newHighScoreLabel.textColor      = [UIColor systemYellowColor];
            newHighScoreLabel.textAlignment  = NSTextAlignmentCenter;
            newHighScoreLabel.adjustsFontSizeToFitWidth = YES;
            newHighScoreLabel.minimumScaleFactor = 0.7;
            newHighScoreLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:newHighScoreLabel];

            // Spring-pop entrance
            newHighScoreLabel.transform = CGAffineTransformMakeScale(0.7, 0.7);
            newHighScoreLabel.alpha = 0;
            [UIView animateWithDuration:0.45 delay:0.05
                 usingSpringWithDamping:0.55 initialSpringVelocity:0.8
                               options:0
                            animations:^{
                newHighScoreLabel.transform = CGAffineTransformIdentity;
                newHighScoreLabel.alpha     = 1.0;
            } completion:nil];

            // ── Submit button ─────────────────────────────────────────────────
            UIButton *submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
            [submitButton setTitle:@"🏆  Submit Score" forState:UIControlStateNormal];
            submitButton.titleLabel.font    = [UIFont boldSystemFontOfSize:16];
            submitButton.tintColor          = [UIColor blackColor];
            submitButton.backgroundColor    = [UIColor systemYellowColor];
            submitButton.layer.cornerRadius = 10;
            submitButton.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:submitButton];

            // ── Layout: anchored below the TOTAL score label (tag 9901) ──────
            // This guarantees the banner always sits in the gap between the score
            // and the Play Again button, never overlapping the white bonus text.
            UIView *scoreLbl = [card viewWithTag:9901];
            NSLayoutAnchor *topAnchor = scoreLbl
                ? scoreLbl.bottomAnchor
                : card.centerYAnchor;
            CGFloat topOffset = scoreLbl ? 28.0 : 10.0;

            [NSLayoutConstraint activateConstraints:@[
                [newHighScoreLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
                [newHighScoreLabel.topAnchor constraintEqualToAnchor:(NSLayoutYAxisAnchor *)topAnchor constant:topOffset],
                [newHighScoreLabel.widthAnchor constraintEqualToConstant:300],
                [newHighScoreLabel.heightAnchor constraintEqualToConstant:34],
                [submitButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
                [submitButton.topAnchor constraintEqualToAnchor:newHighScoreLabel.bottomAnchor constant:12],
                [submitButton.widthAnchor constraintEqualToConstant:240],
                [submitButton.heightAnchor constraintEqualToConstant:50],
                [nameField.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
                [nameField.topAnchor constraintEqualToAnchor:submitButton.bottomAnchor constant:14],
                [nameField.widthAnchor constraintEqualToConstant:280],
                [nameField.heightAnchor constraintEqualToConstant:50],
            ]];

            // ── Tap-to-dismiss keyboard on card background ────────────────────
            UITapGestureRecognizer *tapToDismiss =
                [[UITapGestureRecognizer alloc] initWithTarget:nameField
                                                        action:@selector(resignFirstResponder)];
            tapToDismiss.cancelsTouchesInView = NO; // let button taps still fire
            [card addGestureRecognizer:tapToDismiss];

            // ── Keyboard avoidance: slide card up when keyboard appears ───────
            // We capture the card in the blocks using a weak ref; if the card is
            // removed (user taps New Run) before the keyboard fires, we no-op.
            __weak UIView *weakCard = card;
            __block id keyboardShowObserver = nil;
            __block id keyboardHideObserver = nil;

            keyboardShowObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIKeyboardWillShowNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                UIView *strongCard = weakCard;
                if (!strongCard || !strongCard.window) return;
                NSDictionary *userInfo = note.userInfo;
                CGRect keyboardFrame = [userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
                double duration      = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
                UIViewAnimationCurve curve = [userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];

                // How much of the card is hidden behind the keyboard?
                CGRect cardFrameInWindow = [strongCard convertRect:strongCard.bounds
                                                            toView:strongCard.window];
                CGFloat cardBottom    = CGRectGetMaxY(cardFrameInWindow);
                CGFloat keyboardTop   = CGRectGetMinY(keyboardFrame);
                CGFloat overlap       = cardBottom - keyboardTop;
                CGFloat shiftUp       = (overlap > 0) ? -(overlap + 16) : 0;

                [UIView animateWithDuration:duration
                                      delay:0
                                    options:(UIViewAnimationOptions)(curve << 16)
                                 animations:^{
                    strongCard.transform = CGAffineTransformMakeTranslation(0, shiftUp);
                } completion:nil];
            }];

            keyboardHideObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIKeyboardWillHideNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                UIView *strongCard = weakCard;
                if (!strongCard) return;
                NSDictionary *userInfo = note.userInfo;
                double duration = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
                UIViewAnimationCurve curve = [userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
                [UIView animateWithDuration:duration
                                      delay:0
                                    options:(UIViewAnimationOptions)(curve << 16)
                                 animations:^{
                    strongCard.transform = CGAffineTransformIdentity;
                } completion:nil];
            }];

            // Remove keyboard observers when the card leaves the window
            // (user tapped New Run or Play Again before submitting)
            // We use a display-link-free approach: observe the card's
            // didMoveToWindow via a one-time dealloc block pattern using
            // a trampoline associated object.
            dispatch_block_t cleanupBlock = ^{
                [[NSNotificationCenter defaultCenter] removeObserver:keyboardShowObserver];
                [[NSNotificationCenter defaultCenter] removeObserver:keyboardHideObserver];
            };
            // Store cleanup on the card so it fires when card is deallocated
            static const void *kBRKeyboardCleanupKey = &kBRKeyboardCleanupKey;
            objc_setAssociatedObject(card, kBRKeyboardCleanupKey,
                cleanupBlock, OBJC_ASSOCIATION_COPY_NONATOMIC);

            // ── Wire submit ───────────────────────────────────────────────────
            [submitButton addTarget:self action:@selector(submitScoreFromEndCard:)
                   forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(submitButton, kBREndCardNameFieldKey,
                nameField, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(submitButton, kBREndCardFinalScoreKey,
                @(finalScore), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            // Auto-focus — pop the keyboard immediately so the user
            // doesn't have to tap the field to start typing
            [nameField becomeFirstResponder];
        });
    }] resume];
}

// ── UITextFieldDelegate — Return key dismisses keyboard ───────────────────────
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

/// Called when the submit button on the end card is tapped.
/// Reads the name field and final score from associated objects on the sender.
/// Handles submit tap. Dismisses keyboard first (which also slides the card
/// back down via the keyboard-hide observer) then posts the score.
- (void)submitScoreFromEndCard:(UIButton *)submitButton {
    UITextField *nameField  = objc_getAssociatedObject(submitButton, kBREndCardNameFieldKey);
    NSNumber    *scoreValue = objc_getAssociatedObject(submitButton, kBREndCardFinalScoreKey);

    // Dismiss keyboard — the UIKeyboardWillHide observer will animate the
    // card back to its original position automatically.
    [nameField resignFirstResponder];

    NSString  *playerName = nameField.text.length > 0 ? nameField.text : @"Anonymous";
    NSInteger  finalScore = scoreValue.integerValue;

    [self submitScore:finalScore playerName:playerName];
    submitButton.hidden = YES;
    nameField.enabled   = NO;
    nameField.text      = [NSString stringWithFormat:@"✓ %@", playerName];

    // Navigate to game picker if this submit was triggered from the end-of-run flow
    NSNumber *shouldNav = objc_getAssociatedObject(submitButton, kBREndCardNavigateAfterSubmitKey);
    if (shouldNav.boolValue) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self showGamePickerFromEndCard];
        });
    }
}



#pragma mark - Boss Fight

// ── Entry point ───────────────────────────────────────────────────────────────

- (void)startBossFight {
    if (self.bossFightActive) return;
    self.bossFightActive  = YES;
    self.bossMaxHP        = MIN(7, 2 + self.currentLevel);  // L1=3, L2=4 ... L5+=7
    self.bossHP           = self.bossMaxHP;
    self.bossComboBuffer  = [NSMutableArray array];
    self.playerIsBlocking = self.playerIsDucking = NO;
    self.playerInvincible = self.bossIsBlocking = self.bossStunned = NO;

    [self.tickTimer invalidate]; self.tickTimer = nil;
    [self _startBossFightMusic];

    [self _buildBossFightUI];

    // Boss AI: attacks every 2.4s initially, speeds up as it weakens
    self.bossFightTimer = [NSTimer scheduledTimerWithTimeInterval:2.4
                                                           target:self
                                                         selector:@selector(bossTick)
                                                         userInfo:nil
                                                          repeats:YES];
}

// ── UI construction ───────────────────────────────────────────────────────────

- (void)_buildBossFightUI {
    // Cover only the game view area — control buttons live below it and must
    // remain fully hittable. Using gameView.frame means the overlay never
    // intercepts touches on the dpad or action button.
    CGRect   bounds    = self.gameView.frame;
    CGFloat  W         = self.view.bounds.size.width;
    CGFloat  halfW     = W / 2.0;

    UIView *overlay = [[UIView alloc] initWithFrame:bounds];
    overlay.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.09 alpha:0.98];
    overlay.alpha = 0;
    [self.view addSubview:overlay];
    self.bossFightOverlay = overlay;

    // Controls must stay on top of the overlay so the player can still fight
    [self.view bringSubviewToFront:self.upBtn];
    [self.view bringSubviewToFront:self.downBtn];
    [self.view bringSubviewToFront:self.leftBtn];
    [self.view bringSubviewToFront:self.rightBtn];
    [self.view bringSubviewToFront:self.actionBtn];

    // Title
    UILabel *title = [UILabel new];
    title.text          = [NSString stringWithFormat:@"⚔️  LEVEL %ld BOSS FIGHT  ⚔️", (long)self.currentLevel];
    title.font          = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightBold];
    title.textColor     = [UIColor systemRedColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.frame         = CGRectMake(0, 50, W, 28);
    [overlay addSubview:title];

    // HP hearts — player (left) and boss (right)
    CGFloat hpY = 86;
    UILabel *pHP = [UILabel new]; pHP.tag = 8801;
    pHP.font = [UIFont systemFontOfSize:20]; pHP.textAlignment = NSTextAlignmentLeft;
    pHP.frame = CGRectMake(14, hpY, halfW - 20, 28);
    [overlay addSubview:pHP];

    UILabel *bHP = [UILabel new]; bHP.tag = 8802;
    bHP.font = [UIFont systemFontOfSize:20]; bHP.textAlignment = NSTextAlignmentRight;
    bHP.frame = CGRectMake(halfW + 6, hpY, halfW - 20, 28);
    [overlay addSubview:bHP];

    // Sprites
    CGFloat spriteSize = MIN(130, halfW * 0.72);
    CGFloat spriteY    = hpY + 36;

    UIImageView *pSpr = [[UIImageView alloc] initWithImage:self.playerImageView.image];
    pSpr.frame              = CGRectMake(halfW * 0.5 - spriteSize / 2.0, spriteY, spriteSize, spriteSize);
    pSpr.contentMode        = UIViewContentModeScaleAspectFill;
    pSpr.clipsToBounds      = YES;
    pSpr.layer.cornerRadius = spriteSize / 2.0;
    pSpr.layer.borderColor  = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:1.0].CGColor;
    pSpr.layer.borderWidth  = 3.0;
    pSpr.tag = 8803;
    [overlay addSubview:pSpr];
    self.bossPlayerSpriteView = pSpr;

    UIImageView *bSpr = [[UIImageView alloc] initWithImage:self.enemyImage];
    bSpr.frame              = CGRectMake(halfW * 1.5 - spriteSize / 2.0, spriteY, spriteSize, spriteSize);
    bSpr.contentMode        = UIViewContentModeScaleAspectFill;
    bSpr.clipsToBounds      = YES;
    bSpr.layer.cornerRadius = spriteSize / 2.0;
    bSpr.layer.borderColor  = [UIColor systemRedColor].CGColor;
    bSpr.layer.borderWidth  = 3.0;
    bSpr.transform          = CGAffineTransformMakeScale(-1, 1); // face player
    bSpr.tag = 8804;
    [overlay addSubview:bSpr];
    self.bossEnemySpriteView = bSpr;

    // Name labels
    UILabel *pName = [UILabel new];
    pName.text = @"YOU"; pName.textAlignment = NSTextAlignmentCenter;
    pName.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightBold];
    pName.textColor = [UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0];
    pName.frame = CGRectMake(0, spriteY + spriteSize + 4, halfW, 18);
    [overlay addSubview:pName];

    UILabel *bName = [UILabel new];
    bName.text = [NSString stringWithFormat:@"BOSS  Lv%ld", (long)self.currentLevel];
    bName.textAlignment = NSTextAlignmentCenter;
    bName.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightBold];
    bName.textColor = [UIColor systemRedColor];
    bName.frame = CGRectMake(halfW, spriteY + spriteSize + 4, halfW, 18);
    [overlay addSubview:bName];

    // VS divider
    UILabel *vs = [UILabel new];
    vs.text = @"VS"; vs.textAlignment = NSTextAlignmentCenter;
    vs.font = [UIFont monospacedSystemFontOfSize:26 weight:UIFontWeightBold];
    vs.textColor = [UIColor colorWithWhite:0.35 alpha:1.0];
    vs.frame = CGRectMake(halfW - 28, spriteY + spriteSize / 2.0 - 18, 56, 36);
    [overlay addSubview:vs];

    // Combo/action text
    UILabel *combo = [UILabel new]; combo.tag = 8805;
    combo.text = @"FIGHT!"; combo.textAlignment = NSTextAlignmentCenter;
    combo.font = [UIFont monospacedSystemFontOfSize:22 weight:UIFontWeightBold];
    combo.textColor = [UIColor systemYellowColor];
    combo.adjustsFontSizeToFitWidth = YES;
    combo.frame = CGRectMake(20, spriteY + spriteSize + 28, W - 40, 32);
    [overlay addSubview:combo];
    self.bossComboLabel = combo;

    // Control hint
    UILabel *hint = [UILabel new];
    hint.text = @"◀︎ BLOCK   ▼ DUCK   ▶︎ STEP   ▲ JUMP   ⚡ ATTACK";
    hint.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    hint.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    hint.textAlignment = NSTextAlignmentCenter; hint.adjustsFontSizeToFitWidth = YES;
    hint.frame = CGRectMake(10, spriteY + spriteSize + 66, W - 20, 16);
    [overlay addSubview:hint];

    // Combo cheat sheet
    UILabel *sheet = [UILabel new];
    sheet.text = @"R+L+R+⚡ TORNADO  •  R+R+⚡ RUSH  •  ▼▲+⚡ UPPERCUT  •  L+R+⚡ BLAST";
    sheet.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    sheet.textColor = [UIColor colorWithWhite:0.35 alpha:1.0];
    sheet.textAlignment = NSTextAlignmentCenter; sheet.adjustsFontSizeToFitWidth = YES;
    sheet.frame = CGRectMake(10, spriteY + spriteSize + 86, W - 20, 14);
    [overlay addSubview:sheet];

    [self _updateBossFightHPLabels];

    // Entrance
    overlay.transform = CGAffineTransformMakeScale(0.9, 0.9);
    [UIView animateWithDuration:0.4 delay:0
         usingSpringWithDamping:0.72 initialSpringVelocity:0.6
                       options:0
                    animations:^{ overlay.alpha = 1.0; overlay.transform = CGAffineTransformIdentity; }
                    completion:^(BOOL d) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self _showBossComboText:@"⚡  FIGHT!" color:[UIColor systemYellowColor]];
        });
    }];
}

- (void)_updateBossFightHPLabels {
    UIView *ov = self.bossFightOverlay; if (!ov) return;
    UILabel *pHP = (UILabel *)[ov viewWithTag:8801];
    UILabel *bHP = (UILabel *)[ov viewWithTag:8802];
    NSMutableString *ph = [NSMutableString string], *bh = [NSMutableString string];
    for (NSInteger i = 0; i < self.model.maxHP; i++)
        [ph appendString:(i < self.model.playerHP) ? @"♥" : @"♡"];
    for (NSInteger i = 0; i < self.bossMaxHP; i++)
        [bh appendString:(i < self.bossHP) ? @"♥" : @"♡"];
    pHP.text = ph;
    bHP.text = bh;
    bHP.textColor = (self.bossHP <= 1) ? [UIColor systemRedColor]
                                       : [UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0];
}

// ── Directional input ─────────────────────────────────────────────────────────

- (void)_bossFightInput:(NSString *)dir {
    [self.bossComboBuffer addObject:dir];
    if (self.bossComboBuffer.count > 6) [self.bossComboBuffer removeObjectAtIndex:0];

    // Reset combo expiry window
    [self.bossComboWindowTimer invalidate];
    self.bossComboWindowTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self
                                     selector:@selector(_clearBossComboBuffer) userInfo:nil repeats:NO];

    // Left = blocking stance, Down = ducking
    if ([dir isEqualToString:@"L"]) [self _setBossPlayerBlocking:YES];
    if ([dir isEqualToString:@"D"]) [self _setBossPlayerDucking:YES];

    // Nudge sprite to show movement
    UIImageView *spr = self.bossPlayerSpriteView; if (!spr) return;
    CGPoint orig = spr.center;
    // Exaggerated movement so input reads clearly as a physical action
    CGFloat dx = [dir isEqualToString:@"R"] ? 52 : [dir isEqualToString:@"L"] ? -34 : 0;
    CGFloat dy = [dir isEqualToString:@"U"] ? -55 : [dir isEqualToString:@"D"] ? 18 : 0;
    CGFloat bounce = [dir isEqualToString:@"U"] ? 12 : 0; // overshoot on landing
    [UIView animateWithDuration:0.13
                             delay:0
         usingSpringWithDamping:0.55 initialSpringVelocity:0.8
                   options:UIViewAnimationOptionCurveEaseOut
                animations:^{ spr.center = CGPointMake(orig.x+dx, orig.y+dy); }
             completion:^(BOOL d) {
        [UIView animateWithDuration:0.18
                                 delay:0
             usingSpringWithDamping:0.5 initialSpringVelocity:0.4
                       options:0
                    animations:^{ spr.center = CGPointMake(orig.x, orig.y+bounce); }
                 completion:^(BOOL d2) {
            [UIView animateWithDuration:0.1 animations:^{ spr.center = orig; }];
        }];
    }];
}

- (void)_clearBossComboBuffer { [self.bossComboBuffer removeAllObjects]; }

- (void)_setBossPlayerBlocking:(BOOL)on {
    self.playerIsBlocking = on;
    UIImageView *s = self.bossPlayerSpriteView;
    s.layer.borderColor = on ? [UIColor colorWithRed:0.0 green:0.85 blue:1.0 alpha:1.0].CGColor
                             : [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:1.0].CGColor;
    s.layer.borderWidth = on ? 5.0 : 3.0;
    if (on) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self _setBossPlayerBlocking:NO]; });
}

- (void)_setBossPlayerDucking:(BOOL)on {
    self.playerIsDucking = on;
    [UIView animateWithDuration:0.15 animations:^{
        self.bossPlayerSpriteView.transform = on
            ? CGAffineTransformMakeScale(0.82, 0.82) : CGAffineTransformIdentity;
    }];
    if (on) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self _setBossPlayerDucking:NO]; });
}

// ── Player attack & combo detection ──────────────────────────────────────────

- (void)_bossFightAttack {
    [self.bossComboWindowTimer invalidate];
    NSArray<NSString *> *buf = [self.bossComboBuffer copy];
    [self.bossComboBuffer removeAllObjects];

    // Resolve combo — check most powerful first
    NSString *name     = @"👊  JAB!";
    NSInteger damage   = 1;
    BOOL      piercing = NO;
    BOOL      stun     = NO;
    UIColor  *col      = [UIColor systemYellowColor];

    NSUInteger n = buf.count;
    if (n >= 3 && [buf[n-3] isEqual:@"R"] && [buf[n-2] isEqual:@"L"] && [buf[n-1] isEqual:@"R"]) {
        name = @"🌪  TORNADO SPIN!"; damage = 2; piercing = YES;
        col = [UIColor colorWithRed:0.4 green:0.9 blue:1.0 alpha:1.0];
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0; spin.toValue = @(M_PI * 2); spin.duration = 0.5;
        [self.bossPlayerSpriteView.layer addAnimation:spin forKey:@"spin"];
    } else if (n >= 2 && [buf[n-2] isEqual:@"D"] && [buf[n-1] isEqual:@"U"]) {
        name = @"👊  UPPERCUT!"; damage = 2; stun = YES;
        col = [UIColor colorWithRed:1.0 green:0.75 blue:0.0 alpha:1.0];
    } else if (n >= 2 && [buf[n-2] isEqual:@"R"] && [buf[n-1] isEqual:@"R"]) {
        name = @"⚡  RUSH PUNCH!"; damage = 2;
        col = [UIColor colorWithRed:1.0 green:0.9 blue:0.1 alpha:1.0];
    } else if (n >= 2 && [buf[n-2] isEqual:@"L"] && [buf[n-1] isEqual:@"R"]) {
        name = @"💥  CROSS BLAST!"; damage = 1; piercing = YES;
        col = [UIColor colorWithRed:1.0 green:0.4 blue:0.0 alpha:1.0];
    } else if (n >= 1 && [buf[n-1] isEqual:@"D"]) {
        name = @"🦵  LOW SWEEP!"; damage = 1; piercing = YES;
        col = [UIColor colorWithRed:0.75 green:0.4 blue:1.0 alpha:1.0];
    } else if (n >= 1 && [buf[n-1] isEqual:@"U"]) {
        name = @"🙌  OVERHEAD!"; damage = 1;
        col = [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0];
    }

    [self _showBossComboText:name color:col];
    [self playSoundNamed:@"use-item"];

    // Apply vs boss block
    NSInteger actual = damage;
    if (self.bossIsBlocking && !piercing) {
        actual = MAX(0, damage - 1);
        if (actual == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self _showBossComboText:@"🛡  BLOCKED!" color:[UIColor colorWithWhite:0.6 alpha:1.0]];
            });
            [self _shakeView:self.bossEnemySpriteView horiz:YES];
            return;
        }
    }

    if (actual > 0) {
        self.bossHP = MAX(0, self.bossHP - actual);
        [self _updateBossFightHPLabels];
        [self _flashView:self.bossEnemySpriteView color:[UIColor systemRedColor]];
        [self _shakeView:self.bossEnemySpriteView horiz:YES];
        [self playSoundNamed:@"enemy-died"];

        if (stun && !self.bossStunned) {
            self.bossStunned = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self _showBossComboText:@"⭐️  STUNNED!" color:[UIColor systemYellowColor]];
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ self.bossStunned = NO; });
        }
        [self _checkBossFightResult];
    }
}

// ── Boss AI tick ──────────────────────────────────────────────────────────────

- (void)bossTick {
    if (!self.bossFightActive || self.bossStunned) return;

    // Speed up when half HP lost
    NSInteger lost = self.bossMaxHP - self.bossHP;
    if (lost >= (self.bossMaxHP / 2) && self.bossFightTimer.timeInterval > 1.7) {
        [self.bossFightTimer invalidate];
        self.bossFightTimer = [NSTimer scheduledTimerWithTimeInterval:1.6 target:self
                                   selector:@selector(bossTick) userInfo:nil repeats:YES];
    }

    NSInteger roll = (NSInteger)arc4random_uniform(100);
    if (roll < 25) {
        // Block
        self.bossIsBlocking = YES;
        [self _flashView:self.bossEnemySpriteView color:[UIColor colorWithWhite:0.7 alpha:0.4]];
        [self _showBossComboText:@"🛡  BOSS GUARDS" color:[UIColor colorWithWhite:0.55 alpha:1.0]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ self.bossIsBlocking = NO; });
    } else {
        NSInteger aRoll = (NSInteger)arc4random_uniform(100);
        if (lost >= 2 && aRoll < 30) {
            [self _bossAttack:@"💪  HAYMAKER!" damage:2 blockDir:@"L" tele:0.9];
        } else if (aRoll < 58) {
            [self _bossAttack:@"👊  FAST JABS!" damage:1 blockDir:@"L" tele:0.45];
        } else {
            [self _bossAttack:@"🦵  SWEEP KICK!" damage:1 blockDir:@"D" tele:0.65];
        }
    }
}

/// Telegraph, then land attack. blockDir: "L"=standing block, "D"=duck.
- (void)_bossAttack:(NSString *)name damage:(NSInteger)dmg
           blockDir:(NSString *)bdir tele:(NSTimeInterval)secs {
    if (!self.bossFightActive) return;
    [self _showBossComboText:[NSString stringWithFormat:@"⚠️  %@", name]
                      color:[UIColor colorWithRed:1.0 green:0.35 blue:0.0 alpha:1.0]];
    [self _shakeView:self.bossEnemySpriteView horiz:NO];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.bossFightActive) return;
        BOOL defended = ([bdir isEqualToString:@"L"] && self.playerIsBlocking) ||
                        ([bdir isEqualToString:@"D"] && self.playerIsDucking);
        if (defended) {
            [self _showBossComboText:@"🛡  BLOCKED!" color:[UIColor colorWithRed:0.2 green:0.85 blue:1.0 alpha:1.0]];
            [self _shakeView:self.bossPlayerSpriteView horiz:YES];
            [self playSoundNamed:@"use-item"];
        } else if (!self.playerInvincible) {
            self.model.playerHP = MAX(0, self.model.playerHP - dmg);
            [self _updateBossFightHPLabels];
            [self updateHUD];
            [self _showBossComboText:[NSString stringWithFormat:@"💥  HIT! -%ld HP", (long)dmg]
                              color:[UIColor systemRedColor]];
            [self _flashView:self.bossPlayerSpriteView color:[UIColor systemRedColor]];
            [self _shakeView:self.bossPlayerSpriteView horiz:YES];
            [self playSoundNamed:@"hurt-player"];
            self.playerInvincible = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ self.playerInvincible = NO; });
            [self _checkBossFightResult];
        }
    });
}

// ── Visual effects ────────────────────────────────────────────────────────────

- (void)_showBossComboText:(NSString *)text color:(UIColor *)color {
    UILabel *lbl = self.bossComboLabel; if (!lbl) return;
    lbl.text = text; lbl.textColor = color;
    lbl.transform = CGAffineTransformMakeScale(0.65, 0.65); lbl.alpha = 0;
    [UIView animateWithDuration:0.18 animations:^{
        lbl.transform = CGAffineTransformIdentity; lbl.alpha = 1.0;
    }];
}

- (void)_flashView:(UIView *)view color:(UIColor *)color {
    UIView *f = [[UIView alloc] initWithFrame:view.bounds];
    f.backgroundColor = color; f.alpha = 0.72;
    f.layer.cornerRadius = view.layer.cornerRadius;
    [view addSubview:f];
    [UIView animateWithDuration:0.28 animations:^{ f.alpha = 0; }
                     completion:^(BOOL d) { [f removeFromSuperview]; }];
}

- (void)_shakeView:(UIView *)view horiz:(BOOL)h {
    if (!view) return;
    CGPoint c = view.center;
    CGFloat a = 9;
    NSValue *v0 = [NSValue valueWithCGPoint:CGPointMake(c.x+(h?a:0), c.y+(h?0:-a))];
    NSValue *v1 = [NSValue valueWithCGPoint:CGPointMake(c.x-(h?a:0), c.y+(h?0:a))];
    [UIView animateWithDuration:0.07 animations:^{ view.center = v0.CGPointValue; }
                     completion:^(BOOL d1) {
        [UIView animateWithDuration:0.07 animations:^{ view.center = v1.CGPointValue; }
                         completion:^(BOOL d2) {
            [UIView animateWithDuration:0.07 animations:^{ view.center = c; }];
        }];
    }];
}

// ── Win / Loss ────────────────────────────────────────────────────────────────

- (void)_checkBossFightResult {
    if (self.bossHP     <= 0) { [self _bossFightVictory]; }
    if (self.model.playerHP <= 0) { [self _bossFightDefeated]; }
}

- (void)_bossFightVictory {
    [self _tearDownBossFight];
    [self _showBossComboText:@"🏆  BOSS DEFEATED!" color:[UIColor systemYellowColor]];
    [self playSoundNamed:@"enemy-died"];

    // ── Boss death animation ───────────────────────────────────────────────────
    UIImageView *bSpr = self.bossEnemySpriteView;
    if (bSpr) {
        // 1. Big flash white
        [self _flashView:bSpr color:[UIColor whiteColor]];

        // 2. Spin and shrink — fall-over style
        [UIView animateWithDuration:0.6
                                 delay:0
             usingSpringWithDamping:0.4 initialSpringVelocity:1.0
                           options:0
                        animations:^{
            bSpr.transform = CGAffineTransformConcat(
                CGAffineTransformMakeScale(-0.1, 0.1),   // flip+shrink
                CGAffineTransformMakeRotation(M_PI * 1.5) // quarter spin
            );
            bSpr.alpha = 0.0;
        } completion:nil];

        // 3. Explosion: 8 fragments fly outward from boss position
        CGPoint center = bSpr.center;
        UIView  *parent = bSpr.superview;
        for (NSInteger i = 0; i < 8; i++) {
            UIImageView *frag = [[UIImageView alloc] initWithImage:bSpr.image];
            CGFloat fsize = 28 + arc4random_uniform(22);
            frag.frame = CGRectMake(center.x - fsize/2.0, center.y - fsize/2.0, fsize, fsize);
            frag.contentMode = UIViewContentModeScaleAspectFill;
            frag.clipsToBounds = YES;
            frag.layer.cornerRadius = fsize / 2.0;
            frag.alpha = 0.9;
            [parent addSubview:frag];

            CGFloat angle  = (M_PI * 2.0 / 8.0) * i + ((arc4random_uniform(30) - 15) * M_PI / 180.0);
            CGFloat dist   = 90.0 + arc4random_uniform(60);
            CGFloat destX  = center.x + cos(angle) * dist;
            CGFloat destY  = center.y + sin(angle) * dist;
            CGFloat rot    = ((NSInteger)arc4random_uniform(4) - 2) * M_PI / 2.0;
            NSTimeInterval delay = 0.05 + (i * 0.03);

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.55
                                         delay:0
                     usingSpringWithDamping:0.65 initialSpringVelocity:1.2
                                   options:0
                                animations:^{
                    frag.center    = CGPointMake(destX, destY);
                    frag.transform = CGAffineTransformMakeRotation(rot);
                    frag.alpha     = 0.0;
                } completion:^(BOOL d) { [frag removeFromSuperview]; }];
            });
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *ov = self.bossFightOverlay;
        [UIView animateWithDuration:0.35 animations:^{ ov.alpha = 0; }
                         completion:^(BOOL d) {
            [ov removeFromSuperview]; self.bossFightOverlay = nil;
            _endCardFired = YES;
            NSInteger cb = self.currentLevel * 100;
            NSInteger hb = self.model.playerHP * 20;
            NSInteger ib = (NSInteger)self.inventory.count * 15;
            self.score += cb + hb + ib;
            [self updateHUD];
            NSString *t = [NSString stringWithFormat:@"LEVEL %ld\nCOMPLETE!", (long)self.currentLevel];
            NSString *s = [NSString stringWithFormat:@"+%ld clear  +%ld hearts  +%ld items",
                           (long)cb, (long)hb, (long)ib];
            [self showLevelEndCardWithTitle:t subtitle:s score:self.score isWin:YES];
        }];
    });
}

- (void)_bossFightDefeated {
    [self _tearDownBossFight];
    [self _showBossComboText:@"💀  K.O.!" color:[UIColor systemRedColor]];

    // Player sprite falls over
    UIImageView *pSpr = self.bossPlayerSpriteView;
    if (pSpr) {
        [UIView animateWithDuration:0.5
                                 delay:0
             usingSpringWithDamping:0.5 initialSpringVelocity:0.8
                           options:0
                        animations:^{
            pSpr.transform = CGAffineTransformConcat(
                CGAffineTransformMakeRotation(M_PI / 2.0),  // tip over
                CGAffineTransformMakeTranslation(0, 30)
            );
            pSpr.alpha = 0.35;
        } completion:nil];
        [self _flashView:pSpr color:[UIColor systemRedColor]];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *ov = self.bossFightOverlay;
        [UIView animateWithDuration:0.35 animations:^{ ov.alpha = 0; }
                         completion:^(BOOL d) {
            [ov removeFromSuperview]; self.bossFightOverlay = nil;
            _endCardFired = YES;
            [self showLevelEndCardWithTitle:@"BUSTED"
                                  subtitle:@"The boss took you down."
                                     score:self.score
                                     isWin:NO];
        }];
    });
}

- (void)_tearDownBossFight {
    self.bossFightActive = NO;
    [self.bossFightTimer invalidate];       self.bossFightTimer      = nil;
    [self.bossComboWindowTimer invalidate]; self.bossComboWindowTimer = nil;
    self.bossPlayerSpriteView = nil;
    self.bossEnemySpriteView  = nil;
    self.bossComboLabel       = nil;
}

#pragma mark - End-of-run high score flow

/// Called when the player taps "NEW RUN" after dying.
/// Hides the action buttons and triggers the one-time high score check.
/// If the score qualifies, name entry appears on the current card and
/// submitting the score then navigates to the game picker.
/// If it doesn't qualify, navigation happens immediately.
- (void)endRunAfterLoss {
    // Hide the Retry and New Run buttons so only the score entry UI remains
    [[self.levelEndCardView viewWithTag:9902] setHidden:YES];
    [[self.levelEndCardView viewWithTag:9903] setHidden:YES];
    [self checkHighScoreAndProceedWithScore:self.score onCard:self.levelEndCardView];
}

/// Async leaderboard check. If score qualifies: injects banner + name field +
/// submit onto the card; submit navigates to the game picker when tapped.
/// If score doesn't qualify: navigates to the game picker directly.
- (void)checkHighScoreAndProceedWithScore:(NSInteger)finalScore onCard:(UIView *)card {
    NSURL *url = [NSURL URLWithString:@"https://brainrot-backend.vercel.app/api/scores"];
    if (!url) { [self showGamePickerFromEndCard]; return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:8.0];
    req.HTTPMethod = @"GET";
    __weak typeof(self) weakSelf = self;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        NSArray   *topScores = nil;
        BOOL       qualifies = NO;
        NSInteger  placement = 1;
        if (data) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSArray class]]) topScores = parsed;
        }
        // Guard: if topScores is nil (network error / bad response) skip the
        // high score check and navigate directly to the game picker.
        if (!topScores) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf showGamePickerFromEndCard];
            });
            return;
        }
        if (topScores.count < 10) {
            qualifies = YES;
            for (NSDictionary *entry in topScores) {
                if ([entry[@"score"] integerValue] >= finalScore) placement++;
            }
        } else {
            qualifies = finalScore > [topScores.lastObject[@"score"] integerValue];
            if (qualifies) {
                for (NSDictionary *entry in topScores) {
                    if ([entry[@"score"] integerValue] >= finalScore) placement++;
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!qualifies) {
                // Score doesn't make the leaderboard — go straight to the picker
                [weakSelf showGamePickerFromEndCard];
                return;
            }

            // ── Ordinal suffix ────────────────────────────────────────────────
            NSString  *suffix;
            NSInteger  mod100 = placement % 100, mod10 = placement % 10;
            if      (mod100 >= 11 && mod100 <= 13) suffix = @"th";
            else if (mod10 == 1)                   suffix = @"st";
            else if (mod10 == 2)                   suffix = @"nd";
            else if (mod10 == 3)                   suffix = @"rd";
            else                                   suffix = @"th";

            // ── Banner ────────────────────────────────────────────────────────
            NSString *bannerText = [NSString stringWithFormat:
                @"🎉 #%ld%@ — New High Score!", (long)placement, suffix];
            UILabel *bannerLabel       = [UILabel new];
            bannerLabel.text           = bannerText;
            bannerLabel.font           = [UIFont boldSystemFontOfSize:21];
            bannerLabel.textColor      = [UIColor systemYellowColor];
            bannerLabel.textAlignment  = NSTextAlignmentCenter;
            bannerLabel.adjustsFontSizeToFitWidth = YES;
            bannerLabel.minimumScaleFactor        = 0.7;
            bannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:bannerLabel];
            bannerLabel.transform = CGAffineTransformMakeScale(0.7, 0.7);
            bannerLabel.alpha     = 0;
            [UIView animateWithDuration:0.45 delay:0.05
                 usingSpringWithDamping:0.55 initialSpringVelocity:0.8
                               options:0
                            animations:^{ bannerLabel.transform = CGAffineTransformIdentity;
                                          bannerLabel.alpha = 1.0; }
                            completion:nil];

            // ── Name field ────────────────────────────────────────────────────
            UITextField *nameField       = [UITextField new];
            nameField.placeholder        = @"Enter your name";
            nameField.font               = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightRegular];
            nameField.textColor          = [UIColor whiteColor];
            nameField.textAlignment      = NSTextAlignmentCenter;
            nameField.backgroundColor    = [UIColor colorWithWhite:0.18 alpha:1.0];
            nameField.layer.cornerRadius = 10;
            nameField.layer.borderColor  = [UIColor systemYellowColor].CGColor;
            nameField.layer.borderWidth  = 1.5;
            nameField.returnKeyType      = UIReturnKeyDone;
            nameField.autocorrectionType = UITextAutocorrectionTypeNo;
            nameField.autocapitalizationType = UITextAutocapitalizationTypeWords;
            nameField.maxLength          = 20;
            nameField.delegate           = weakSelf;
            nameField.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:nameField];

            // ── Submit button ─────────────────────────────────────────────────
            UIButton *submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
            [submitButton setTitle:@"🏆  Submit & Continue" forState:UIControlStateNormal];
            submitButton.titleLabel.font    = [UIFont boldSystemFontOfSize:16];
            submitButton.tintColor          = [UIColor blackColor];
            submitButton.backgroundColor    = [UIColor systemYellowColor];
            submitButton.layer.cornerRadius = 10;
            submitButton.translatesAutoresizingMaskIntoConstraints = NO;
            [card addSubview:submitButton];

            // ── Layout: anchored below the TOTAL score label ──────────────────
            UIView   *scoreLbl  = [card viewWithTag:9901];
            NSLayoutYAxisAnchor *topAnchor = scoreLbl ? scoreLbl.bottomAnchor : card.centerYAnchor;
            CGFloat   topOffset = scoreLbl ? 28.0 : 10.0;

            [NSLayoutConstraint activateConstraints:@[
                [bannerLabel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
                [bannerLabel.topAnchor constraintEqualToAnchor:topAnchor constant:topOffset],
                [bannerLabel.widthAnchor constraintEqualToConstant:300],
                [bannerLabel.heightAnchor constraintEqualToConstant:34],
                [submitButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
                [submitButton.topAnchor constraintEqualToAnchor:bannerLabel.bottomAnchor constant:12],
                [submitButton.widthAnchor constraintEqualToConstant:260],
                [submitButton.heightAnchor constraintEqualToConstant:50],
                [nameField.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
                [nameField.topAnchor constraintEqualToAnchor:submitButton.bottomAnchor constant:14],
                [nameField.widthAnchor constraintEqualToConstant:280],
                [nameField.heightAnchor constraintEqualToConstant:50],
            ]];

            // ── Keyboard avoidance ────────────────────────────────────────────
            __weak UIView *weakCard = card;
            __block id showObs = nil, hideObs = nil;
            showObs = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIKeyboardWillShowNotification object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                UIView *c = weakCard; if (!c || !c.window) return;
                CGRect  kbFrame  = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
                double  dur      = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
                UIViewAnimationCurve curve = [note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
                CGRect  cardInWin = [c convertRect:c.bounds toView:c.window];
                CGFloat overlap   = CGRectGetMaxY(cardInWin) - CGRectGetMinY(kbFrame);
                CGFloat shift     = (overlap > 0) ? -(overlap + 16) : 0;
                [UIView animateWithDuration:dur delay:0
                                    options:(UIViewAnimationOptions)(curve << 16)
                                 animations:^{ c.transform = CGAffineTransformMakeTranslation(0, shift); }
                                 completion:nil];
            }];
            hideObs = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIKeyboardWillHideNotification object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                UIView *c = weakCard; if (!c) return;
                double dur = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
                UIViewAnimationCurve curve = [note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
                [UIView animateWithDuration:dur delay:0
                                    options:(UIViewAnimationOptions)(curve << 16)
                                 animations:^{ c.transform = CGAffineTransformIdentity; }
                                 completion:nil];
            }];
            dispatch_block_t cleanup = ^{
                [[NSNotificationCenter defaultCenter] removeObserver:showObs];
                [[NSNotificationCenter defaultCenter] removeObserver:hideObs];
            };
            static const void *kKbCleanup = &kKbCleanup;
            objc_setAssociatedObject(card, kKbCleanup, cleanup, OBJC_ASSOCIATION_COPY_NONATOMIC);

            // ── Wire submit — set navigate flag so it goes to picker after ────
            [submitButton addTarget:weakSelf action:@selector(submitScoreFromEndCard:)
                   forControlEvents:UIControlEventTouchUpInside];
            objc_setAssociatedObject(submitButton, kBREndCardNameFieldKey,
                nameField, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(submitButton, kBREndCardFinalScoreKey,
                @(finalScore), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // This flag tells submitScoreFromEndCard: to navigate after posting
            objc_setAssociatedObject(submitButton, kBREndCardNavigateAfterSubmitKey,
                @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            [nameField becomeFirstResponder];
        });
    }] resume];
}

#pragma mark - Controls

- (void)moveUp    { if (self.bossFightActive) { [self _bossFightInput:@"U"]; return; } [self attemptMoveByDeltaCol:0  deltaRow:-1]; }
- (void)moveDown  { if (self.bossFightActive) { [self _bossFightInput:@"D"]; return; } [self attemptMoveByDeltaCol:0  deltaRow:1];  }
- (void)moveLeft  { if (self.bossFightActive) { [self _bossFightInput:@"L"]; return; } [self attemptMoveByDeltaCol:-1 deltaRow:0];  }
- (void)moveRight { if (self.bossFightActive) { [self _bossFightInput:@"R"]; return; } [self attemptMoveByDeltaCol:1  deltaRow:0];  }

- (void)attemptMoveByDeltaCol:(NSInteger)deltaCol deltaRow:(NSInteger)deltaRow {
    if (!self.model) return;
    BOOL moved = [self.model movePlayerByDC:deltaCol DR:deltaRow];
    if (!moved) return; // wall or boundary — silent, no narration

    // Two movement sound variants for natural variety — alternate sound keeps
    // rapid tapping from sounding like a stuck record.
    [self playRandomVariantOfSound:@"player-movement" variantCount:2];

    [self updateCameraForPlayerCol:self.model.playerCol playerRow:self.model.playerRow];
    [self repositionPlayerImageAnimated:YES];
    BRTile *landedTile = [self.model tileAtCol:self.model.playerCol row:self.model.playerRow];

    if (landedTile.itemName) {
        NSString *pickedItem = landedTile.itemName;
        landedTile.itemName  = nil;
        self.score += 10;
        static const NSInteger kBRMaxPickupHP = 3;
        if ([pickedItem isEqualToString:@"❤️ heart"]) {
            // Heart pickup restores HP up to max instead of going to inventory
            if (self.model.playerHP < kBRMaxPickupHP) {
                self.model.playerHP += 1;
            } else {
                self.score += 15; // already at full health — bonus points instead
            }
        } else {
            [self.inventory addObject:pickedItem];
        }
        // Two found-item variants — same rationale as movement
        [self playRandomVariantOfSound:@"found-item" variantCount:2];
    } else if (landedTile.enemyName) {
        // Bare-hands bump: costs 1 HP but always drops a reward so the
        // player is never left with nothing. Priority: restore a heart if
        // below max, otherwise drop a random item from the level's item list.
        landedTile.enemyName = nil;
        self.model.playerHP -= 1;
        self.score += 15;
        static const NSInteger kBRMaxHeartDisplay = 3;
        if (self.model.playerHP < kBRMaxHeartDisplay) {
            // Restore 1 HP — heart drop
            self.model.playerHP += 1;
            landedTile.itemName = @"❤️ heart";
        } else {
            // Inventory drop — pick from level items, fall back to "scrap"
            NSArray<NSString *> *dropPool = self.model.aiItems;
            NSString *droppedItem = (dropPool.count > 0)
                ? dropPool[arc4random_uniform((uint32_t)dropPool.count)]
                : @"scrap";
            landedTile.itemName = droppedItem;
        }
        // Two hurt-player variants — keeps repeated hits from sounding monotonous
        [self playRandomVariantOfSound:@"hurt-player" variantCount:2];
    }
    [self updateHUD];

    // The next scheduled tick would eventually redraw the map, but requesting
    // a redraw immediately makes newly explored tiles appear the moment the
    // player completes a movement tap.
    [self.gameView setNeedsDisplay];
}

- (void)useAction {
    if (self.bossFightActive) { [self _bossFightAttack]; return; }
    if (!self.model) return;

    // ── No inventory: bare-hands wall push ───────────────────────────────
    // Gives the player something to do when cornered with no items.
    // 25% chance to crumble an adjacent wall revealing a hidden reward.
    // No penalty on failure so this is always safe to attempt.
    if (self.inventory.count == 0) {
        NSArray<NSValue *> *neighbors = [self.model neighborsOfCol:self.model.playerCol
                                                               row:self.model.playerRow];
        BRTile  *wallTarget    = nil;
        CGPoint  wallTargetPos = CGPointZero;
        for (NSValue *posValue in neighbors) {
            CGPoint pt   = posValue.CGPointValue;
            BRTile *tile = [self.model tileAtCol:pt.x row:pt.y];
            if (tile.type == BRTileTypeWall) {
                wallTarget    = tile;
                wallTargetPos = pt;
                break;
            }
        }
        if (wallTarget && arc4random_uniform(100) < 25) {
            // Snapshot the wall tile BEFORE clearing it so the explosion
            // fragments show the wall graphic, not the open floor behind it.
            UIImage *wallSnapshot = [self snapshotOfGameViewTileAtCol:(NSInteger)wallTargetPos.x
                                                                  row:(NSInteger)wallTargetPos.y];
            wallTarget.type = BRTileTypeFloor;
            // Reward: heart if injured, item otherwise
            static const NSInteger kBRMaxHPWallPush = 3;
            if (self.model.playerHP < kBRMaxHPWallPush) {
                wallTarget.itemName = @"❤️ heart";
            } else {
                NSArray<NSString *> *dropPool = self.model.aiItems;
                wallTarget.itemName = (dropPool.count > 0)
                    ? dropPool[arc4random_uniform((uint32_t)dropPool.count)]
                    : @"scrap";
            }
            self.score += 10;
            [self playSoundNamed:@"wall-blast-success"];
            [self playExplosionAtTileCol:(NSInteger)wallTargetPos.x
                                     row:(NSInteger)wallTargetPos.y
                             sourceImage:wallSnapshot];
            [self updateHUD];
            [self.gameView setNeedsDisplay];
        }
        return;
    }

    NSString *chosenItem = self.inventory.firstObject;
    NSArray<NSValue *> *neighborPositions = [self.model neighborsOfCol:self.model.playerCol
                                                                   row:self.model.playerRow];

    // ── Item behaviors — work on both enemies AND walls ───────────────────────
    // Require at least one enemy or wall neighbor; if completely surrounded by
    // open floor there's nothing to act on.
    BOOL hasTarget = NO;
    for (NSValue *posValue in neighborPositions) {
        BRTile *t = [self.model tileAtCol:posValue.CGPointValue.x row:posValue.CGPointValue.y];
        if (t.enemyName || t.type == BRTileTypeWall) { hasTarget = YES; break; }
    }
    if (!hasTarget) return;

    // ── Unified blast block ────────────────────────────────────────────────────
    // Handles a tile regardless of whether it's an enemy or a wall.
    //   Enemy → clear sprite + sound + explosion using enemy image, +40 score, drop reward
    //   Wall  → breach (always succeeds when an item is used) + sound + explosion
    //           using wall snapshot, drop scrap, +25 score
    //   Floor/exit → no effect
    __weak typeof(self) weakSelf = self;
    BOOL (^blastTile)(NSInteger, NSInteger) = ^BOOL(NSInteger col, NSInteger row) {
        BRTile *tile = [weakSelf.model tileAtCol:col row:row];
        if (!tile) return NO;

        if (tile.enemyName) {
            tile.enemyName = nil;
            weakSelf.score += 40;
            static const NSInteger kBRMaxHPEnemy = 3;
            if (weakSelf.model.playerHP < kBRMaxHPEnemy) {
                tile.itemName = @"❤️ heart";
            } else {
                NSArray<NSString *> *pool = weakSelf.model.aiItems;
                tile.itemName = pool.count > 0
                    ? pool[arc4random_uniform((uint32_t)pool.count)]
                    : @"scrap";
            }
            [weakSelf playSoundNamed:@"enemy-died"];
            // Remove enemy sprite immediately — don't wait for the 0.25s tick
            NSString *key = [NSString stringWithFormat:@"%ld,%ld", (long)col, (long)row];
            UIImageView *enemyView = weakSelf.enemyImageViews[key];
            [enemyView removeFromSuperview];
            [weakSelf.enemyImageViews removeObjectForKey:key];
            // Fragments use the enemy art so pieces look like the defeated character
            [weakSelf playExplosionAtTileCol:col row:row sourceImage:weakSelf.enemyImage];
            return YES;
        }

        if (tile.type == BRTileTypeWall) {
            // Snapshot BEFORE clearing — fragments must show the wall art
            UIImage *snap = [weakSelf snapshotOfGameViewTileAtCol:col row:row];
            tile.type     = BRTileTypeFloor;
            tile.itemName = @"scrap";
            weakSelf.score += 25;
            [weakSelf playSoundNamed:@"wall-blast-success"];
            [weakSelf playExplosionAtTileCol:col row:row sourceImage:snap];
            return YES;
        }

        return NO;
    };

    // ── Pick one of four behaviors (weighted) ─────────────────────────────────
    // 60% Normal    — first adjacent target (enemy or wall)
    // 13% Tornado   — all 4 neighbors, staggered with 360° spin animation
    // 14% Piercing  — 2 tiles deep in the direction of the first target found
    // 13% Cross     — both tiles on the first-target axis (front + behind player)
    NSInteger roll = (NSInteger)(arc4random_uniform(100));
    typedef NS_ENUM(NSInteger, BRItemBehavior) {
        BRItemBehaviorNormal   = 0,
        BRItemBehaviorTornado  = 1,
        BRItemBehaviorPiercing = 2,
        BRItemBehaviorCross    = 3,
    };
    BRItemBehavior behavior;
    if      (roll < 60) behavior = BRItemBehaviorNormal;
    else if (roll < 73) behavior = BRItemBehaviorTornado;
    else if (roll < 87) behavior = BRItemBehaviorPiercing;
    else                behavior = BRItemBehaviorCross;

    [self.inventory removeObjectAtIndex:0];

    // ── Direction scan: find first adjacent target and its axis ──────────────
    // Pass 1 checks enemies (priority); pass 2 falls back to walls.
    const NSInteger blastDC[] = { 0,  0, -1, 1 };
    const NSInteger blastDR[] = {-1,  1,  0, 0 };
    NSInteger firstDC = 0, firstDR = 0;
    CGPoint firstTargetPos = CGPointZero;
    for (NSInteger pass = 0; pass < 2; pass++) {
        for (NSInteger d = 0; d < 4; d++) {
            NSInteger nc = self.model.playerCol + blastDC[d];
            NSInteger nr = self.model.playerRow + blastDR[d];
            BRTile *t = [self.model tileAtCol:nc row:nr];
            BOOL hit = (pass == 0) ? (t.enemyName != nil) : (t.type == BRTileTypeWall);
            if (hit && CGPointEqualToPoint(firstTargetPos, CGPointZero)) {
                firstTargetPos = CGPointMake(nc, nr);
                firstDC = blastDC[d]; firstDR = blastDR[d];
            }
        }
        if (!CGPointEqualToPoint(firstTargetPos, CGPointZero)) break;
    }

    switch (behavior) {

        case BRItemBehaviorNormal: {
            // Blast the first adjacent target only — original behavior.
            blastTile((NSInteger)firstTargetPos.x, (NSInteger)firstTargetPos.y);
            [self updateHUD];
            [self.gameView setNeedsDisplay];
            break;
        }

        case BRItemBehaviorTornado: {
            // 360° spin on the player sprite, then blast all 4 neighbors
            // in sequence with 120ms stagger between each hit.
            UIImageView *piv = self.playerImageView;
            if (!piv.hidden) {
                CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
                spin.fromValue      = @(0);
                spin.toValue        = @(M_PI * 2.0);
                spin.duration       = 0.55;
                spin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                spin.repeatCount    = 1;
                [piv.layer addAnimation:spin forKey:@"tornadoSpin"];
            }
            NSArray<NSValue *> *tornadoNeighbors = neighborPositions;
            __weak typeof(self) ws = self;
            for (NSInteger i = 0; i < (NSInteger)tornadoNeighbors.count; i++) {
                CGPoint pt = tornadoNeighbors[i].CGPointValue;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)((0.10 + i * 0.12) * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    blastTile((NSInteger)pt.x, (NSInteger)pt.y);
                    [ws updateHUD];
                    [ws.gameView setNeedsDisplay];
                });
            }
            break;
        }

        case BRItemBehaviorPiercing: {
            // Blast 2 tiles deep in the direction of the first target.
            // Punches through both tiles regardless of type.
            NSInteger c1 = self.model.playerCol + firstDC;
            NSInteger r1 = self.model.playerRow + firstDR;
            NSInteger c2 = c1 + firstDC;
            NSInteger r2 = r1 + firstDR;
            blastTile(c1, r1);
            blastTile(c2, r2);
            [self updateHUD];
            [self.gameView setNeedsDisplay];
            break;
        }

        case BRItemBehaviorCross: {
            // Blast the target tile AND the tile directly behind the player
            // on the same axis — two hits, opposite directions.
            NSInteger c1 = self.model.playerCol + firstDC;
            NSInteger r1 = self.model.playerRow + firstDR;
            NSInteger c2 = self.model.playerCol - firstDC;
            NSInteger r2 = self.model.playerRow - firstDR;
            blastTile(c1, r1);
            blastTile(c2, r2);
            [self updateHUD];
            [self.gameView setNeedsDisplay];
            break;
        }
    }
}

#pragma mark - Membership

/// Returns YES if the current user has any active EZComplete subscription.
/// Used to gate save-game and library features. Membership is required to:
///   - access the game picker / saved library
///   - auto-save newly generated games
///   - play the free default game
/// Non-members can still generate new games (coins deducted) and play them,
/// but games are not persisted and the picker is not shown.
- (BOOL)userHasMembership {
    // EZAuthManager.shared.subscriptionTier returns nil/empty for non-subscribers.
    // Any non-empty tier string means the user has an active plan.
    NSString *tier = [EZEntitlementManager shared].currentTier;
    return (tier.length > 0);
}

#pragma mark - Game Picker

/// Presents the library picker modally. onSelection either loads a saved
/// record (no API calls) or kicks off startNewRun. onClosedWithoutSelection
/// fires if the player taps the picker's "✕" with no selection — since this
/// view controller's own content (gameView/d-pad/HUD) is just inherited
/// chrome from before the picker appeared, "closing the picker" should mean
/// "leave this screen entirely", not "reveal that chrome".
- (void)showGamePicker {
    // Cover whatever is currently on screen — game chrome is hidden, but
    // resetLoadingOverlayToPhase1 or startNewRun may have shown the overlay.
    // (See setGameChromeHidden: — the overlay is managed separately.)
    BRGamePickerViewController *picker = [[BRGamePickerViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    picker.onSelection = ^(BRGameRecord *selectedRecord) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (selectedRecord) {
            [strongSelf loadGameRecord:selectedRecord];
        } else {
            [strongSelf startNewRun];
        }
    };
    picker.onClosedWithoutSelection = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf dismissSelfBackToCaller];
    };
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    // animated:NO — BrainRotViewController itself is presented with
    // animated:NO by the main VC, so there is already no transition visible
    // when this VC appears. Adding a second animation here (BrainRotVC slides
    // in, then picker slides in) created the delay the player noticed.
    // The picker simply appears: tap → picker, no intermediate state.
    [self presentViewController:picker animated:NO completion:nil];
}

/// Starts the same Custom Workshop available from the New Game card, but
/// preloads a photo selected in EZ Attachments. The workshop itself asks the
/// player whether the image belongs to the character or background slot.
- (void)showCustomWorkshopWithInitialImage:(UIImage *)image {
    BRCustomGameCreatorViewController *workshop =
        [[BRCustomGameCreatorViewController alloc] init];
    workshop.initialWorkshopImage = image;

    __weak typeof(self) weakSelf = self;
    workshop.onPlayRequested = ^(BRGameRecord *record) {
        [weakSelf loadGameRecord:record];
    };

    UINavigationController *navWrapper =
        [[UINavigationController alloc] initWithRootViewController:workshop];
    navWrapper.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navWrapper animated:YES completion:nil];
}

/// "Go back" for this view controller itself, used when the picker is closed
/// with no selection. Handles both ways BrainRotViewController might have
/// been shown:
///   - presented modally from a "main menu" view controller -> dismiss.
///   - pushed onto a navigation stack -> pop.
/// If neither applies (this VC has no presenter and is the root of its own
/// nav stack, or has none), there's nowhere to go back to — log it and leave
/// the picker dismissed but this screen as-is, rather than doing nothing
/// silently or risking a broken navigation state.
- (void)dismissSelfBackToCaller {
    if (self.presentingViewController) {
        // animated:NO — the picker's own dismiss animation (triggered by its
        // "✕" handler just before this fires) already provides the visual
        // transition; animating this too would add a visible double-flash.
        [self dismissViewControllerAnimated:NO completion:nil];
    } else if (self.navigationController && self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:NO];
    } else {
        NSLog(@"[BrainRot] Picker closed with no selection, but BrainRotViewController has no presenter or nav stack to return to.");
    }
}

#pragma mark - Load Saved Game

/// Restores a previously saved game record with zero API calls.
/// Mirrors playAgainRun but sources everything from a BRGameRecord instead
/// of savedRunAssets/savedRunSeed, and skips the loading overlay entirely.
- (void)loadGameRecord:(BRGameRecord *)record {
    // Reveal the game-playing UI — hidden since viewDidLoad until a game
    // is actually being loaded (see setGameChromeHidden:).
    [self setGameChromeHidden:NO];

    // Immediately hide the loading overlay — a saved game does zero API calls
    // and needs no loading screen. startNewRun may have left it visible if
    // it was called first (e.g. from viewDidLoad before the picker appeared).
    self.loadingOverlayView.hidden = YES;
    self.loadingOverlayView.alpha  = 0;
    [self.loadingSpinner stopAnimating];

    _endCardFired          = NO;
    self.score             = 0;
    self.currentLevel      = 1;
    self.scoreAtLevelStart = 0;
    [self.inventory removeAllObjects];
    [self setGameInputEnabled:NO];

    [self.levelEndCardView removeFromSuperview];
    self.levelEndCardView       = nil;
    self.currentGameRecord      = record;
    self.savedRunSeed           = record.seed;

    // Reset visuals
    self.playerImageView.hidden = YES;
    self.playerImageView.image  = nil;
    self.enemyImage             = nil;
    [self clearEnemyImageViews];
    self.gameView.backgroundImage   = nil;
    self.gameView.wallImage         = nil;
    self.gameView.hidePlayerDot     = NO;
    self.gameView.backgroundColor   = [UIColor colorWithWhite:0.1 alpha:1.0];

    // Rebuild model from saved seed
    self.model = [[BRGameModel alloc] initWithCols:17 rows:13 seed:record.seed];
    self.gameView.model = self.model;

    // Build asset dict from record (images loaded lazily from disk)
    NSDictionary *assetDict = [record asAssetDict];
    UIImage *bgImage   = assetDict[@"bgImage"];
    UIImage *playerImg = assetDict[@"playerImage"];
    UIImage *enemyImg  = assetDict[@"enemyImage"];
    UIImage *wallImg   = assetDict[@"obstacleImage"];

    if (bgImage) {
        self.gameView.backgroundImage = bgImage;
        self.gameView.backgroundColor = [UIColor clearColor];
    }
    self.gameView.wallImage = wallImg;

    self.model.levelFlavor    = record.premise;
    self.model.aiItems        = record.items;
    self.model.aiEnemies      = record.enemies;
    self.model.vulnerableHint = record.hint;
    [self.model placeItems:record.items
                     count:MIN(6, (NSInteger)record.items.count  * 2)];
    [self.model placeEnemies:record.enemies
                       count:MIN(6, (NSInteger)record.enemies.count * 2)];

    [self updateCameraForPlayerCol:self.model.playerCol playerRow:self.model.playerRow];

    if (playerImg) {
        self.playerImageView.image  = playerImg;
        self.gameView.hidePlayerDot = YES;
        self.playerImageView.hidden = NO;
        [self repositionPlayerImageAnimated:NO];
    }
    self.enemyImage = enemyImg;

    // Save assets so Play Again works from a loaded game too
    self.savedRunAssets = assetDict;

    [self clearEnemyImageViews];
    [self refreshEnemyImageViews];
    [self updateHUD];
    [self.gameView setNeedsDisplay];
    [self setGameInputEnabled:YES];

    // Saved game has no loading screen, so start music here as the player
    // gains control. Stops and replaces any track already playing.
    [self startBackgroundMusic];

    if (!self.tickTimer || !self.tickTimer.isValid) {
        self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                          target:self
                                                        selector:@selector(tick)
                                                        userInfo:nil
                                                         repeats:YES];
    }
}

#pragma mark - New Run

- (void)startNewRun {
    // Reveal the game-playing UI — hidden since viewDidLoad until a game
    // is actually starting (see setGameChromeHidden:).
    [self setGameChromeHidden:NO];

    _endCardFired          = NO;
    self.score             = 0;
    self.currentLevel      = 1;
    self.scoreAtLevelStart = 0;
    [self.inventory removeAllObjects];
    [self setGameInputEnabled:NO];

    // Do not let old normal/boss timers or an old boss overlay affect the
    // newly loading game.
    [self.tickTimer invalidate];
    self.tickTimer = nil;
    [self.bossFightTimer invalidate];
    self.bossFightTimer = nil;
    [self.bossComboWindowTimer invalidate];
    self.bossComboWindowTimer = nil;
    self.bossFightActive = NO;
    self.isPaused = NO;
    self.pauseBtn.selected = NO;
    [self.bossFightOverlay removeFromSuperview];
    self.bossFightOverlay = nil;

    // Tear down previous run
    [self.levelEndCardView removeFromSuperview];
    self.levelEndCardView       = nil;
    self.playerImageView.hidden = YES;
    self.playerImageView.image  = nil;
    self.enemyImage             = nil;
    [self clearEnemyImageViews];
    self.gameView.backgroundImage = nil;
    self.gameView.hidePlayerDot   = NO;
    self.gameView.backgroundColor   = [UIColor colorWithWhite:0.1 alpha:1.0];

    // Seed model so grid exists while assets generate.
    // Store the seed so Play Again can reinitialise with the same topology.
    NSNumber *newSeed   = @((NSInteger)arc4random());
    self.savedRunSeed   = newSeed;
    self.savedRunAssets = nil; // cleared until buildGameAssets completes
    self.model = [[BRGameModel alloc] initWithCols:17 rows:13 seed:newSeed];
    self.gameView.model = self.model;
    [self updateHUD];

    // Reset overlay to phase 1
    self.loadingSpinner.alpha    = 1.0;
    self.loadingPhaseLabel.alpha = 1.0;
    self.loadingPhaseLabel.text  = @"Writing your story…";
    self.storyTitleLabel.alpha   = 0;
    self.storyBodyLabel.alpha    = 0;
    self.beginButton.alpha       = 0;
    self.beginButtonAction       = nil;
    self.loadingOverlayView.hidden = NO;
    self.loadingOverlayView.alpha  = 1.0;
    [self.view bringSubviewToFront:self.loadingOverlayView];

    // Start music immediately so the player hears it during the story loading screen.
    // Music carries through into gameplay — startBackgroundMusic handles stopping
    // any previous track before beginning the new one.
    [self startBackgroundMusic];

    [self buildGameAssetsWithCompletion:^(NSDictionary *assetDict) {
        NSString *themeTitle = assetDict[@"themeTitle"]  ?: @"BRAINROT";
        NSString *levelDesc  = assetDict[@"levelDesc"]   ?: @"Something stirs.";
        NSString *hint       = assetDict[@"hint"]        ?: @"";
        NSArray  *items      = assetDict[@"items"]       ?: @[@"widget", @"cable"];
        NSArray  *enemies    = assetDict[@"enemies"]     ?: @[@"warden", @"patrol"];
        UIImage  *bgImage    = assetDict[@"bgImage"];
        UIImage  *playerImg  = assetDict[@"playerImage"];
        UIImage  *enemyImg   = assetDict[@"enemyImage"];

        // Background image is set directly on gameView — it handles cropping
        // to the current viewport in drawRect. No separate UIImageView needed.
        // The DFS maze model is ground truth for movement; we no longer
        // reclassify tiles from image brightness (that was unreliable).
        if (bgImage) {
            self.gameView.backgroundImage = bgImage;
            self.gameView.backgroundColor = [UIColor clearColor];
        }

        // Place items/enemies on finalized tile layout
        self.model.levelFlavor    = levelDesc;
        self.model.aiItems        = items;
        self.model.aiEnemies      = enemies;
        self.model.vulnerableHint = hint;
        [self.model placeItems:items    count:MIN(6, (NSInteger)items.count   * 2)];
        [self.model placeEnemies:enemies count:MIN(6, (NSInteger)enemies.count * 2)];

        [self updateCameraForPlayerCol:self.model.playerCol playerRow:self.model.playerRow];
        if (playerImg) {
            self.playerImageView.image  = playerImg;
            self.gameView.hidePlayerDot = YES;
            self.playerImageView.hidden = NO;
            [self repositionPlayerImageAnimated:NO];
        }
        self.enemyImage = enemyImg;

        // Snapshot everything needed for Play Again (same world, zero API cost)
        self.savedRunAssets = assetDict;

        // Saving remains a membership feature. Do not return for
        // non-members: the universal "Tap To Begin" setup below must still run.
        if ([self userHasMembership]) {
            __weak typeof(self) weakSelfForSave = self;
            [[BRGameLibrary shared]
                saveGameWithThemeTitle:themeTitle
                               premise:levelDesc
                                  hint:hint
                                 items:items
                               enemies:enemies
                                  seed:self.savedRunSeed
                      backgroundImage:bgImage
                           playerImage:playerImg
                            enemyImage:enemyImg
                            completion:^(BRGameRecord *savedRecord) {
                __strong typeof(weakSelfForSave) strongSelfForSave = weakSelfForSave;
                strongSelfForSave.currentGameRecord = savedRecord;
            }];
        }

        // Phase 3: reveal begin button, let player tap when ready.
        // weakSelf breaks the retain cycle: self → beginButtonAction (property)
        // → block → self would be a cycle without it.
        self.loadingPhaseLabel.text = @"";
        __weak typeof(self) weakSelf = self;
        self.beginButtonAction = ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [UIView animateWithDuration:0.5 animations:^{
                strongSelf.loadingOverlayView.alpha = 0;
            } completion:^(BOOL finished) {
                strongSelf.loadingOverlayView.hidden = YES;
                [strongSelf setGameInputEnabled:YES];
                [strongSelf refreshEnemyImageViews];
                if (!strongSelf.tickTimer || !strongSelf.tickTimer.isValid) {
                    strongSelf.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                                            target:strongSelf
                                                                          selector:@selector(tick)
                                                                          userInfo:nil
                                                                           repeats:YES];
                }
                [strongSelf.gameView setNeedsDisplay];
            }];
        };
        [UIView animateWithDuration:0.4 animations:^{
            self.loadingSpinner.alpha    = 0;
            self.loadingPhaseLabel.alpha = 0;
            self.beginButton.alpha       = 1.0;
        }];
    }];
}

- (void)beginButtonTapped {
    if (self.beginButtonAction) self.beginButtonAction();
}

#pragma mark - Play Again (same world, no API calls)

/// Restores the same world the player just finished — same seed for tile topology,
/// same images, same items and enemies. Does NOT make any API calls.
/// Falls back to startNewRun if saved assets are missing for any reason.
- (void)playAgainRun {
    if (!self.savedRunSeed || !self.savedRunAssets) {
        [self startNewRun]; // safety fallback
        return;
    }

    _endCardFired          = NO;
    self.score             = 0;
    self.currentLevel      = 1;
    self.scoreAtLevelStart = 0;
    [self.inventory removeAllObjects];
    [self setGameInputEnabled:NO];

    [self.levelEndCardView removeFromSuperview];
    self.levelEndCardView = nil;

    // Reinitialise model with the same seed so tile layout matches the saved bgImage
    self.model = [[BRGameModel alloc] initWithCols:17 rows:13 seed:self.savedRunSeed];
    self.gameView.model = self.model;

    // Reapply saved assets (no image re-download, no text call)
    NSDictionary *assets  = self.savedRunAssets;
    NSString *levelDesc   = assets[@"levelDesc"]  ?: @"";
    NSString *hint        = assets[@"hint"]       ?: @"";
    NSArray  *items       = assets[@"items"]      ?: @[];
    NSArray  *enemies     = assets[@"enemies"]    ?: @[];
    UIImage  *bgImage     = assets[@"bgImage"];
    UIImage  *playerImg   = assets[@"playerImage"];
    UIImage  *enemyImg    = assets[@"enemyImage"];

    self.gameView.backgroundImage = bgImage;
    self.gameView.backgroundColor = bgImage ? [UIColor clearColor]
                                            : [UIColor colorWithWhite:0.1 alpha:1.0];

    self.model.levelFlavor    = levelDesc;
    self.model.aiItems        = items;
    self.model.aiEnemies      = enemies;
    self.model.vulnerableHint = hint;
    [self.model placeItems:items    count:MIN(6, (NSInteger)items.count   * 2)];
    [self.model placeEnemies:enemies count:MIN(6, (NSInteger)enemies.count * 2)];

    [self updateCameraForPlayerCol:self.model.playerCol playerRow:self.model.playerRow];
    self.gameView.hidePlayerDot     = (playerImg != nil);
    self.playerImageView.image      = playerImg;
    self.playerImageView.hidden     = (playerImg == nil);
    self.enemyImage                 = enemyImg;
    if (playerImg) {
        [self repositionPlayerImageAnimated:NO];
    }

    [self clearEnemyImageViews];
    [self refreshEnemyImageViews];
    [self updateHUD];
    [self.gameView setNeedsDisplay];
    [self setGameInputEnabled:YES];

    // Restart music for the new attempt — same world, fresh track selection.
    [self startBackgroundMusic];

    if (!self.tickTimer || !self.tickTimer.isValid) {
        self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                          target:self
                                                        selector:@selector(tick)
                                                        userInfo:nil
                                                         repeats:YES];
    }
}


#pragma mark - Level Progression

/// Called when the player taps "LEVEL N+1 →" on the win card.
/// Score carries over. Level increments. Same assets, more enemies.
- (void)advanceToNextLevel {
    if (!self.savedRunAssets) { [self startNewRun]; return; }

    _endCardFired          = NO;
    self.currentLevel     += 1;
    self.scoreAtLevelStart = self.score;
    [self.inventory removeAllObjects];
    [self setGameInputEnabled:NO];

    [self.levelEndCardView removeFromSuperview];
    self.levelEndCardView = nil;

    [self _rebuildLevelWithAssets:self.savedRunAssets];
}

/// Retry the current level — rolls score back to what it was at the start
/// of this level so repeated failures don't accumulate phantom points.
- (void)retryCurrentLevel {
    if (!self.savedRunAssets) { [self startNewRun]; return; }

    _endCardFired = NO;
    self.score    = self.scoreAtLevelStart;
    [self.inventory removeAllObjects];
    [self setGameInputEnabled:NO];

    [self.levelEndCardView removeFromSuperview];
    self.levelEndCardView = nil;

    [self _rebuildLevelWithAssets:self.savedRunAssets];
}

/// Shared rebuild logic for advanceToNextLevel and retryCurrentLevel.
/// Reinstalls the model, places enemies scaled to currentLevel, restores UI.
- (void)_rebuildLevelWithAssets:(NSDictionary *)assets {
    self.bossFightActive = NO;
    self.isPaused = NO;
    self.pauseBtn.selected = NO;
    [self setGameInputEnabled:NO];
    [self.bossFightTimer invalidate]; self.bossFightTimer = nil;
    [self.bossFightOverlay removeFromSuperview]; self.bossFightOverlay = nil;
    [self.bossComboWindowTimer invalidate]; self.bossComboWindowTimer = nil;

    self.model = [[BRGameModel alloc] initWithCols:17 rows:13 seed:self.savedRunSeed];
    self.gameView.model = self.model;

    NSString *levelDesc = assets[@"levelDesc"] ?: @"";
    NSString *hint      = assets[@"hint"]      ?: @"";
    NSArray  *items     = assets[@"items"]     ?: @[];
    NSArray  *enemies   = assets[@"enemies"]   ?: @[];
    UIImage  *bgImage   = assets[@"bgImage"];
    UIImage  *playerImg = assets[@"playerImage"];
    UIImage  *enemyImg  = assets[@"enemyImage"];

    self.gameView.backgroundImage = bgImage;
    self.gameView.backgroundColor = bgImage ? [UIColor clearColor]
                                            : [UIColor colorWithWhite:0.1 alpha:1.0];
    self.model.levelFlavor    = levelDesc;
    self.model.aiItems        = items;
    self.model.aiEnemies      = enemies;
    self.model.vulnerableHint = hint;

    // Items: constant across levels
    [self.model placeItems:items count:MIN(6, (NSInteger)items.count * 2)];

    // Enemies: +2 per level, capped at 15
    // Level 1 = MIN(6, count*2), Level 2 = +2, Level 3 = +4 ...
    NSInteger baseCount  = MIN(6, (NSInteger)enemies.count * 2);
    NSInteger enemyCount = MIN(15, baseCount + (self.currentLevel - 1) * 2);
    [self.model placeEnemies:enemies count:enemyCount];

    [self updateCameraForPlayerCol:self.model.playerCol playerRow:self.model.playerRow];
    self.gameView.hidePlayerDot = (playerImg != nil);
    self.playerImageView.image  = playerImg;
    self.playerImageView.hidden = (playerImg == nil);
    self.enemyImage             = enemyImg;
    if (playerImg) [self repositionPlayerImageAnimated:NO];

    [self clearEnemyImageViews];
    [self refreshEnemyImageViews];
    [self updateHUD];
    [self.gameView setNeedsDisplay];
    [self setGameInputEnabled:YES];
    [self startBackgroundMusic];

    if (!self.tickTimer || !self.tickTimer.isValid) {
        self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                          target:self
                                                        selector:@selector(tick)
                                                        userInfo:nil
                                                         repeats:YES];
    }
}

#pragma mark - Maze Template Image

/// Renders the current model's tile topology to a PNG UIImage using plain
/// Core Graphics. White = floor/exit, near-black = wall. This image is sent
/// alongside the background image prompt so the AI skins an already-correct
/// maze rather than guessing one — the generated image will have bright/dark
/// areas that match this reference, which our brightness-sampling grid rebuild
/// can then read back reliably.
///
/// Rendered at 2× the tile grid size (34×26 at 17×13 with 2px/tile) for a
/// compact but readable reference image.
- (NSData *)renderMazeTemplateImageData {
    if (!self.model) return nil;

    NSInteger gridCols = self.model.cols;  // 17
    NSInteger gridRows = self.model.rows;  // 13

    // CRITICAL: render at exactly 1024×1024 — the same size the API returns.
    //
    // The old approach used 32px/tile → 544×416, which is NOT square. The API
    // always outputs 1024×1024. When the AI edits a 544×416 reference into a
    // 1024×1024 output it has to decide how to handle the aspect ratio — it may
    // stretch, pad, or freely reinterpret, putting corridor centres at wrong
    // pixel positions. This caused the "maze inside a maze" visual mismatch.
    //
    // By sending a 1024×1024 template where each tile is exactly
    //   tileW = 1024/17 ≈ 60.2 px wide
    //   tileH = 1024/13 ≈ 78.8 px tall
    // the AI receives a reference that is 1:1 with its output canvas, so the
    // edit preserves tile positions exactly. BRGameView.drawRect divides the
    // same 1024×1024 image by (cols × rows) identically, giving perfect
    // structural alignment between the image and the tile overlay.
    //
    // round((col+1)*tileW) - round(col*tileW) avoids sub-pixel gaps at tile
    // boundaries that could confuse the model with hairline cracks.

    NSInteger canvasSize = 1024;
    CGFloat   tileW      = (CGFloat)canvasSize / (CGFloat)gridCols;
    CGFloat   tileH      = (CGFloat)canvasSize / (CGFloat)gridRows;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(canvasSize, canvasSize), YES, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    // Fill entire canvas with wall colour first — covers any sub-pixel seams
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.06 alpha:1.0].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, canvasSize, canvasSize));

    for (NSInteger row = 0; row < gridRows; row++) {
        for (NSInteger col = 0; col < gridCols; col++) {
            BRTile *tile = [self.model tileAtCol:col row:row];

            // Pixel-snapped rect: adjacent tiles share exact integer edges so
            // there are no gaps or overlaps, regardless of fractional tileW/H.
            CGFloat x = round(col       * tileW);
            CGFloat y = round(row       * tileH);
            CGFloat w = round((col + 1) * tileW) - x;
            CGFloat h = round((row + 1) * tileH) - y;

            UIColor *fill;
            switch (tile.type) {
                case BRTileTypeFloor:
                    fill = [UIColor colorWithWhite:0.94 alpha:1.0]; break;
                case BRTileTypeExit:
                    fill = [UIColor colorWithRed:0.2 green:1.0 blue:0.35 alpha:1.0]; break;
                case BRTileTypeWall:
                    fill = [UIColor colorWithWhite:0.06 alpha:1.0]; break;
                default:
                    fill = [UIColor blackColor]; break;
            }
            CGContextSetFillColorWithColor(ctx, fill.CGColor);
            CGContextFillRect(ctx, CGRectMake(x, y, w, h));
        }
    }

    // Player start in blue so the AI can orient the scene
    CGFloat sx = round(self.model.playerCol       * tileW);
    CGFloat sy = round(self.model.playerRow       * tileH);
    CGFloat sw = round((self.model.playerCol + 1) * tileW) - sx;
    CGFloat sh = round((self.model.playerRow + 1) * tileH) - sy;
    CGContextSetFillColorWithColor(ctx,
        [UIColor colorWithRed:0.1 green:0.4 blue:1.0 alpha:1.0].CGColor);
    CGContextFillRect(ctx, CGRectMake(sx, sy, sw, sh));

    UIImage *templateImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return UIImagePNGRepresentation(templateImage);
}

#pragma mark - Asset Building

- (void)buildGameAssetsWithCompletion:(void (^)(NSDictionary *assetDict))completion {
    NSString *systemPrompt =
        @"You are creating a completely unique, absurd game scenario for a top-down maze game. "
        "Pick something wildly different every time — a rubber duck, a confused grandma, "
        "a sentient hot dog, a wizard cat, a spy potato, anything goofy and unexpected. "
        "Return ONLY a valid JSON object with NO markdown, NO code fences, just raw JSON. "
        "Required keys:\n"
        "  themeTitle: 1-4 word punchy ALL-CAPS theme name (e.g. 'DUCK INSURGENCY')\n"
        "  premise: 2-3 SHORT punchy sentences. Movie-trailer energy. No fancy words.\n"
        "  items: array of 4 short thematic item names (under 20 chars each)\n"
        "  enemies: array of 2 short enemy names\n"
        "  vulnerableHint: 1 short sentence hinting which item is best for breaking walls\n"
        "  backgroundPrompt: DALL-E prompt for a SINGLE seamless top-down GAME FLOOR texture. "
        "This is NOT a maze image. Do NOT draw corridors, maze walls, paths, rooms, doors, "
        "grid lines, borders, text, characters, vehicles, or a visible destination. "
        "Create an evenly readable overhead terrain surface matching the theme, such as grass, "
        "marble, candy floor, alien carpet, moon dust, kitchen tiles, or neon pavement. "
        "Keep detail distributed across the entire square but leave enough visual calm for game markers. "
        "The app constructs all maze walls itself from individual image pieces, so this must be "
        "a floor/world background only. Top-down game-art style, square composition, no text.\n"
        "  spriteSheetPrompt: DALL-E prompt for a single 1024x1024 image. "
        "TOP HALF: hero character only, centered, full body, white background, bold cartoon outlines. "
        "Thin white dividing line across center. "
        "BOTTOM HALF: villain/enemy only, centered, full body, white background, "
        "bold cartoon outlines, menacing look.";

    [self callBrainRotAI:systemPrompt
             userMessage:@"Generate a new unexpected game premise."
               maxTokens:500
           deductNewGame:YES
              completion:^(NSString *aiResponse) {

        NSDictionary *premiseDict  = [self extractJSONDictFromString:aiResponse];
        NSString *themeTitle  = premiseDict[@"themeTitle"]     ?: @"BRAINROT";
        NSString *premise     = premiseDict[@"premise"]        ?: @"";
        NSString *hint        = premiseDict[@"vulnerableHint"] ?: @"";
        NSArray  *items       = [premiseDict[@"items"]   isKindOfClass:[NSArray class]]
                                     ? premiseDict[@"items"]   : @[@"widget",@"cable",@"chip",@"lens"];
        NSArray  *enemies     = [premiseDict[@"enemies"] isKindOfClass:[NSArray class]]
                                     ? premiseDict[@"enemies"] : @[@"warden",@"patrol"];
        NSString *bgPrompt    = premiseDict[@"backgroundPrompt"]
            ?: @"top-down game board, bright winding paths through dark zones, no characters";
        NSString *spritePrompt = premiseDict[@"spriteSheetPrompt"]
            ?: @"sprite sheet: top half hero on white, bottom half villain on white, dividing line";

        // Phase 2 — show story text while images generate
        if (premise.length > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.storyTitleLabel.text = themeTitle;
                self.storyBodyLabel.text  = premise;
                self.loadingPhaseLabel.text = @"Painting the world…";
                [UIView animateWithDuration:0.6 animations:^{
                    self.loadingSpinner.alpha  = 0.3;
                    self.storyTitleLabel.alpha = 1.0;
                    self.storyBodyLabel.alpha  = 1.0;
                }];
            });
        }

        // Generate a seamless floor/world texture only. BRGameView builds
        // the authoritative maze from individual wall image pieces, so generated
        // AI art can no longer invent corridors that disagree with the model.
        self.savedMazeTemplateImageData = nil;

        // Generate background + sprite sheet in parallel
        dispatch_group_t imageGroup      = dispatch_group_create();
        __block UIImage *backgroundImg   = nil;
        __block UIImage *spriteSheetImg  = nil;

        dispatch_group_enter(imageGroup);
        [self generateImageWithPrompt:bgPrompt
                          transparent:NO
                    referenceImageData:nil
                            completion:^(UIImage *img) {
            backgroundImg = img;
            dispatch_group_leave(imageGroup);
        }];

        dispatch_group_enter(imageGroup);
        [self generateImageWithPrompt:spritePrompt
                          transparent:YES
                    referenceImageData:nil
                            completion:^(UIImage *img) {
            spriteSheetImg = img;
            dispatch_group_leave(imageGroup);
        }];

        dispatch_group_notify(imageGroup, dispatch_get_main_queue(), ^{
            // Crop sprite sheet: top half = player, bottom half = enemy
            UIImage *playerImg = nil;
            UIImage *enemyImg  = nil;
            if (spriteSheetImg) {
                NSInteger fullPixelW  = (NSInteger)(spriteSheetImg.size.width  * spriteSheetImg.scale);
                NSInteger fullPixelH  = (NSInteger)(spriteSheetImg.size.height * spriteSheetImg.scale);
                NSInteger halfPixelH  = fullPixelH / 2;

                CGImageRef topRef = CGImageCreateWithImageInRect(
                    spriteSheetImg.CGImage, CGRectMake(0, 0, fullPixelW, halfPixelH));
                CGImageRef botRef = CGImageCreateWithImageInRect(
                    spriteSheetImg.CGImage, CGRectMake(0, halfPixelH, fullPixelW, halfPixelH));

                if (topRef) {
                    playerImg = [UIImage imageWithCGImage:topRef
                                                    scale:spriteSheetImg.scale
                                              orientation:UIImageOrientationUp];
                    CGImageRelease(topRef);
                }
                if (botRef) {
                    enemyImg = [UIImage imageWithCGImage:botRef
                                                   scale:spriteSheetImg.scale
                                             orientation:UIImageOrientationUp];
                    CGImageRelease(botRef);
                }
            }

            NSMutableDictionary *result = [NSMutableDictionary dictionary];
            result[@"themeTitle"] = themeTitle;
            result[@"levelDesc"]  = premise;
            result[@"hint"]       = hint;
            result[@"items"]      = items;
            result[@"enemies"]    = enemies;
            if (backgroundImg) result[@"bgImage"]     = backgroundImg;
            if (playerImg)     result[@"playerImage"] = playerImg;
            if (enemyImg)      result[@"enemyImage"]  = enemyImg;
            completion(result);
        });
    }];
}

/// Extracts a JSON dictionary from an AI response that may be pure JSON,
/// JSON inside markdown fences, or JSON embedded in prose.
- (NSDictionary *)extractJSONDictFromString:(NSString *)responseString {
    if (responseString.length == 0) return @{};

    // Try direct parse first
    NSData *directData   = [responseString dataUsingEncoding:NSUTF8StringEncoding];
    id      directParsed = [NSJSONSerialization JSONObjectWithData:directData options:0 error:nil];
    if ([directParsed isKindOfClass:[NSDictionary class]]) return directParsed;

    // Find first { … } block
    NSRange openBrace  = [responseString rangeOfString:@"{"];
    NSRange closeBrace = [responseString rangeOfString:@"}" options:NSBackwardsSearch];
    if (openBrace.location != NSNotFound && closeBrace.location > openBrace.location) {
        NSRange jsonRange = NSMakeRange(openBrace.location,
                                        closeBrace.location - openBrace.location + 1);
        NSString *jsonSubstring = [responseString substringWithRange:jsonRange];
        id subParsed = [NSJSONSerialization JSONObjectWithData:
            [jsonSubstring dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([subParsed isKindOfClass:[NSDictionary class]]) return subParsed;
    }
    return @{};
}

// Image-based grid generation and BFS exit-reachability methods removed in
// v2.0. The DFS backtracker in BRGameModel produces a guaranteed-solvable
// perfect maze from the seed. Using image brightness to reclassify tiles
// was unreliable across different AI art styles and was causing the
// passability problems. The background image is now purely visual.


#pragma mark - Image Generation

/// Generates an image via the br-ai edge function.
/// Pass a non-nil referenceImageData (PNG) to send a reference/template image
/// alongside the prompt for image-to-image generation. Pass nil for text-only.
- (void)generateImageWithPrompt:(NSString *)prompt
                    transparent:(BOOL)transparent
              referenceImageData:(nullable NSData *)referenceImageData
                      completion:(void (^)(UIImage *_Nullable image))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:kBRBrainRotAIURL]];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 90;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    // Build payload — include reference image as base64 if provided
    NSMutableDictionary *payload = [@{
        @"action":      @"generate_image",
        @"prompt":      prompt,
        @"size":        @"1024x1024",
        @"transparent": @(transparent),
    } mutableCopy];
    if (referenceImageData) {
        payload[@"reference_image_b64"] = [referenceImageData base64EncodedStringWithOptions:0];
    }
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *decodedImage = nil;
        if (!error && data) {
            NSDictionary *json      = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString     *base64Str = json[@"b64_json"];
            if (base64Str.length > 0) {
                NSData *imgData = [[NSData alloc] initWithBase64EncodedString:base64Str
                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
                if (imgData) {
                    decodedImage = [UIImage imageWithData:imgData scale:[UIScreen mainScreen].scale];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(decodedImage); });
    }] resume];
}

#pragma mark - Player Image Positioning

/// Recentres the camera on the given model coordinates, clamped so the viewport
/// never extends past the model edges.
- (void)updateCameraForPlayerCol:(NSInteger)playerCol playerRow:(NSInteger)playerRow {
    NSInteger halfViewCols = self.gameView.viewportCols / 2;
    NSInteger halfViewRows = self.gameView.viewportRows / 2;
    NSInteger maxCameraCol = MAX(0, self.model.cols - self.gameView.viewportCols);
    NSInteger maxCameraRow = MAX(0, self.model.rows - self.gameView.viewportRows);
    self.gameView.cameraCol = MAX(0, MIN(maxCameraCol, playerCol - halfViewCols));
    self.gameView.cameraRow = MAX(0, MIN(maxCameraRow, playerRow - halfViewRows));
}

/// Returns the on-screen CGRect for a model tile at (col, row), accounting for
/// the current camera offset. Returns CGRectZero if the tile is outside the viewport.
- (CGRect)tileFrameForCol:(NSInteger)col row:(NSInteger)row {
    if (!self.model || CGRectIsEmpty(self.gameView.frame)) return CGRectZero;
    NSInteger screenCol = col - self.gameView.cameraCol;
    NSInteger screenRow = row - self.gameView.cameraRow;
    // Return zero rect for tiles outside the visible viewport
    if (screenCol < 0 || screenCol >= self.gameView.viewportCols ||
        screenRow < 0 || screenRow >= self.gameView.viewportRows) {
        return CGRectZero;
    }
    CGFloat tileW = self.gameView.frame.size.width  / (CGFloat)self.gameView.viewportCols;
    CGFloat tileH = self.gameView.frame.size.height / (CGFloat)self.gameView.viewportRows;
    return CGRectMake(self.gameView.frame.origin.x + screenCol * tileW,
                      self.gameView.frame.origin.y + screenRow * tileH,
                      tileW, tileH);
}

/// Moves playerImageView to the current model.playerCol/playerRow position.
/// Hides the view if the player tile is outside the current viewport (camera offset).
- (void)repositionPlayerImageAnimated:(BOOL)animated {
    if (!self.model) return;
    CGRect tileFrame = [self tileFrameForCol:self.model.playerCol row:self.model.playerRow];
    if (CGRectIsEmpty(tileFrame)) {
        self.playerImageView.hidden = YES; // scrolled out of viewport
        return;
    }
    self.playerImageView.hidden = (self.playerImageView.image == nil);
    CGFloat inset    = tileFrame.size.width * 0.08;
    CGRect  newFrame = CGRectInset(tileFrame, inset, inset);
    self.playerImageView.layer.cornerRadius = newFrame.size.width / 2.0;
    if (animated) {
        [UIView animateWithDuration:0.12 delay:0
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{ self.playerImageView.frame = newFrame; }
                         completion:nil];
    } else {
        self.playerImageView.frame = newFrame;
    }
}

#pragma mark - Enemy Image Views

- (void)refreshEnemyImageViews {
    // Enemy positions must remain synchronized with the model even if the
    // generated enemy sprite failed to load. BRGameView can still draw its
    // fallback enemy indicator and moveEnemiesStep still needs these positions.
    if (!self.model) return;

    // ── Build the ground-truth set of live enemy tile keys ────────────────────
    NSMutableDictionary<NSString *, NSValue *> *liveEnemies = [NSMutableDictionary dictionary];
    for (NSInteger row = 0; row < self.model.rows; row++) {
        for (NSInteger col = 0; col < self.model.cols; col++) {
            if ([self.model tileAtCol:col row:row].enemyName) {
                NSString *key = [NSString stringWithFormat:@"%ld,%ld", (long)col, (long)row];
                liveEnemies[key] = [NSValue valueWithCGPoint:CGPointMake(col, row)];
            }
        }
    }

    // ── Remove image views for enemies that no longer exist ───────────────────
    for (NSString *key in self.enemyImageViews.allKeys.copy) {
        if (!liveEnemies[key]) {
            [self.enemyImageViews[key] removeFromSuperview];
            [self.enemyImageViews removeObjectForKey:key];
        }
    }

    // ── Create missing views; reposition ALL views to their correct tile ──────
    // We reposition every view each tick, not just new ones. This fixes the
    // "red circle with no image" bug: a view created while a tile was off-screen
    // gets a zero frame and is never corrected by the old "if exists, skip" path.
    // Now every live enemy view is guaranteed to match the current camera offset.
    for (NSString *key in liveEnemies) {
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@","];
        NSInteger col = [parts[0] integerValue];
        NSInteger row = [parts[1] integerValue];

        CGRect tileFrame = [self tileFrameForCol:col row:row];
        BOOL onScreen = !CGRectIsEmpty(tileFrame);

        UIImageView *enemyView = self.enemyImageViews[key];

        // If enemy art is missing, do not create an empty UIImageView. The
        // model remains active and BRGameView draws the fallback indicator.
        if (!enemyView && self.enemyImage) {
            enemyView = [[UIImageView alloc] initWithImage:self.enemyImage];
            enemyView.contentMode = UIViewContentModeScaleAspectFill;
            enemyView.clipsToBounds = YES;
            enemyView.layer.borderColor = [UIColor systemRedColor].CGColor;
            enemyView.layer.borderWidth = 1.5;
            [self.view insertSubview:enemyView aboveSubview:self.gameView];
            self.enemyImageViews[key] = enemyView;
        }

        if (onScreen && enemyView) {
            CGFloat inset = tileFrame.size.width * 0.12;
            CGRect frame = CGRectInset(tileFrame, inset, inset);

            // Do not snap an enemy back to its old location while the movement
            // animation is still in progress.
            if (!enemyView.layer.animationKeys.count) {
                enemyView.frame = frame;
                enemyView.layer.cornerRadius = frame.size.width / 2.0;
            }
            enemyView.hidden = NO;
        } else if (enemyView) {
            enemyView.hidden = YES;
        }
    }

    // ── Keep enemyPositions in sync ───────────────────────────────────────────
    [self.enemyPositions removeAllObjects];
    [self.enemyPositions addEntriesFromDictionary:liveEnemies];
}

- (void)clearEnemyImageViews {
    for (UIImageView *enemyView in self.enemyImageViews.allValues) {
        [enemyView removeFromSuperview];
    }
    [self.enemyImageViews removeAllObjects];
}


#pragma mark - Enemy Movement

/// Called every other tick (~0.5 s). Each enemy either steps toward the player
/// (if within 8 tiles Manhattan distance) or takes a random walkable step.
/// On contact with the player the enemy deals 1 HP of damage and stays put.
- (void)moveEnemiesStep {
    if (!self.model || self.enemyPositions.count == 0) return;

    NSInteger playerCol = self.model.playerCol;
    NSInteger playerRow = self.model.playerRow;

    // Snapshot positions so we don't iterate a mutating dictionary
    NSArray<NSString *> *keys = self.enemyPositions.allKeys.copy;

    // Track which destination tiles are claimed this step so two enemies
    // can't move onto the same tile simultaneously
    NSMutableSet<NSString *> *claimedTiles = [NSMutableSet set];

    const NSInteger dc[] = { 0,  0, -1, 1 };
    const NSInteger dr[] = {-1,  1,  0, 0 };

    for (NSString *key in keys) {
        NSValue *posValue = self.enemyPositions[key];
        if (!posValue) continue;
        CGPoint pos = posValue.CGPointValue;
        NSInteger eCol = (NSInteger)pos.x;
        NSInteger eRow = (NSInteger)pos.y;

        // Verify the tile still has this enemy (could have been blasted)
        BRTile *currentTile = [self.model tileAtCol:eCol row:eRow];
        if (!currentTile.enemyName) continue;

        NSInteger manhattan = ABS(eCol - playerCol) + ABS(eRow - playerRow);

        // ── Contact: adjacent to player → deal damage, don't move ────────────
        if (manhattan == 1) {
            self.model.playerHP -= 1;
            [self playSoundNamed:@"hurt-player"];
            // Flash the player image red to signal the hit
            UIImageView *piv = self.playerImageView;
            piv.layer.borderColor = [UIColor systemRedColor].CGColor;
            piv.layer.borderWidth = 3.0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                piv.layer.borderColor = [UIColor clearColor].CGColor;
                piv.layer.borderWidth = 0;
            });
            [self updateHUD];
            [self checkForWinOrLoss];
            continue;
        }

        // ── Choose next step ──────────────────────────────────────────────────
        // Within 8 tiles: pick the direction that reduces Manhattan distance.
        // Beyond 8 or all chase moves blocked: random walkable step.
        NSInteger bestCol = eCol, bestRow = eRow;
        BOOL      moved   = NO;

        if (manhattan <= 8) {
            // Greedy 1-step toward player — try directions that reduce distance first
            NSInteger bestDist = manhattan;
            // Shuffle the 4 directions slightly to avoid deterministic tie-breaking
            NSInteger order[4] = {0, 1, 2, 3};
            for (NSInteger i = 3; i > 0; i--) {
                NSInteger j = arc4random_uniform((uint32_t)(i + 1));
                NSInteger tmp = order[i]; order[i] = order[j]; order[j] = tmp;
            }
            for (NSInteger i = 0; i < 4; i++) {
                NSInteger d    = order[i];
                NSInteger nc   = eCol + dc[d];
                NSInteger nr   = eRow + dr[d];
                NSInteger dist = ABS(nc - playerCol) + ABS(nr - playerRow);
                if (dist >= bestDist) continue;
                BRTile *t = [self.model tileAtCol:nc row:nr];
                if (!t || t.type == BRTileTypeWall) continue;
                if (t.enemyName) continue; // occupied by another enemy
                NSString *destKey = [NSString stringWithFormat:@"%ld,%ld", (long)nc, (long)nr];
                if ([claimedTiles containsObject:destKey]) continue;
                bestCol = nc; bestRow = nr; bestDist = dist; moved = YES;
            }
        }

        if (!moved) {
            // Random walkable step (wandering or chase blocked)
            NSMutableArray<NSNumber *> *options = [NSMutableArray array];
            for (NSInteger d = 0; d < 4; d++) {
                NSInteger nc = eCol + dc[d];
                NSInteger nr = eRow + dr[d];
                BRTile *t = [self.model tileAtCol:nc row:nr];
                if (!t || t.type == BRTileTypeWall) continue;
                if (t.enemyName) continue;
                NSString *destKey = [NSString stringWithFormat:@"%ld,%ld", (long)nc, (long)nr];
                if ([claimedTiles containsObject:destKey]) continue;
                [options addObject:@(d)];
            }
            if (options.count > 0) {
                NSInteger d = options[arc4random_uniform((uint32_t)options.count)].integerValue;
                bestCol = eCol + dc[d];
                bestRow = eRow + dr[d];
                moved = YES;
            }
        }

        if (!moved || (bestCol == eCol && bestRow == eRow)) continue;

        // ── Apply move in model ───────────────────────────────────────────────
        BRTile *destTile = [self.model tileAtCol:bestCol row:bestRow];
        if (!destTile || destTile.type == BRTileTypeWall || destTile.enemyName) continue;

        NSString *destKey = [NSString stringWithFormat:@"%ld,%ld", (long)bestCol, (long)bestRow];
        [claimedTiles addObject:destKey];

        // Move enemy name from old tile to new tile
        destTile.enemyName  = currentTile.enemyName;
        currentTile.enemyName = nil;

        // Update positions dictionary
        [self.enemyPositions removeObjectForKey:key];
        self.enemyPositions[destKey] = [NSValue valueWithCGPoint:CGPointMake(bestCol, bestRow)];

        // ── Animate the image view sliding to the new tile ────────────────────
        UIImageView *enemyView = self.enemyImageViews[key];
        if (enemyView) {
            [self.enemyImageViews removeObjectForKey:key];
            self.enemyImageViews[destKey] = enemyView;

            CGRect destFrame = [self tileFrameForCol:bestCol row:bestRow];
            if (!CGRectIsEmpty(destFrame)) {
                CGFloat inset    = destFrame.size.width * 0.12;
                CGRect  newFrame = CGRectInset(destFrame, inset, inset);
                [UIView animateWithDuration:0.18
                                      delay:0
                                    options:UIViewAnimationOptionCurveEaseInOut
                                 animations:^{ enemyView.frame = newFrame; }
                                 completion:nil];
            } else {
                // Scrolled off-screen — hide until refreshEnemyImageViews shows it
                enemyView.hidden = YES;
            }
        }
    }
}

#pragma mark - Input Enable/Disable

- (void)setGameInputEnabled:(BOOL)enabled {
    self.upBtn.enabled      = enabled;
    self.downBtn.enabled    = enabled;
    self.leftBtn.enabled    = enabled;
    self.rightBtn.enabled   = enabled;
    self.actionBtn.enabled  = enabled;
    self.restartBtn.enabled = enabled;
}

#pragma mark - Explosion Animation

/// Renders the gameView's current visual state at a single tile position into a
/// UIImage. The snapshot is taken BEFORE any model changes so the returned image
/// shows what the tile looked like at the moment of impact (wall or enemy sprite),
/// not the floor/empty state that replaces it.
///
/// Returns nil if the tile is outside the viewport, the context couldn't be
/// created, or the gameView has no frame yet. All callers guard on nil.
- (nullable UIImage *)snapshotOfGameViewTileAtCol:(NSInteger)col row:(NSInteger)row {
    CGRect tileInViewCoords = [self tileFrameForCol:col row:row];
    if (CGRectIsEmpty(tileInViewCoords)) return nil;

    // tileFrameForCol:row: returns coords in self.view space.
    // We need the same rect in gameView's local coordinate system to crop
    // the layer render correctly, regardless of where gameView sits on screen
    // or how far the camera has scrolled.
    CGRect tileInGameViewCoords = [self.gameView convertRect:tileInViewCoords
                                                    fromView:self.view];
    CGSize tileSize = tileInGameViewCoords.size;
    if (tileSize.width <= 0 || tileSize.height <= 0) return nil;

    UIGraphicsBeginImageContextWithOptions(tileSize, NO, [UIScreen mainScreen].scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }
    // Shift the render origin so this tile's top-left maps to (0, 0) in the image.
    CGContextTranslateCTM(ctx, -tileInGameViewCoords.origin.x,
                               -tileInGameViewCoords.origin.y);
    [self.gameView.layer renderInContext:ctx];
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snapshot;
}

/// Plays a cinematic tile-destruction burst at the given model coordinates.
///
/// Visual sequence:
///   1. Impact flash — a bright disc scales up from the tile centre and fades
///      in ~0.2 s, giving an immediate "hit" cue before pieces fly.
///   2. Six fragments (2-column × 3-row grid) — each is a cropped slice of
///      sourceImage if one is provided, or an orange fallback otherwise.
///      Fragments launch outward from the tile centre with a perpendicular
///      wobble, tumble via random rotation (±150°), shrink, and fade over
///      ~0.45 s using spring physics.
///   3. All subviews clean up in their own completion blocks — nothing leaks.
///
/// Pass the snapshot image BEFORE mutating the model so fragments look like
/// the destroyed tile, not the floor that replaces it.
- (void)playExplosionAtTileCol:(NSInteger)col
                           row:(NSInteger)row
                   sourceImage:(nullable UIImage *)sourceImage {

    CGRect tileFrame = [self tileFrameForCol:col row:row];
    if (CGRectIsEmpty(tileFrame)) return;

    CGPoint explosionCenter = CGPointMake(CGRectGetMidX(tileFrame),
                                          CGRectGetMidY(tileFrame));
    CGFloat tileSize = MIN(tileFrame.size.width, tileFrame.size.height);

    // ── 1. Impact flash ───────────────────────────────────────────────────────
    // A bright yellow-orange disc that expands from 20% to 220% of the tile
    // and fades out quickly. It fires before the fragments so the player sees
    // an immediate response even on slower devices.
    CGFloat flashDiameter = tileSize * 0.85;
    UIView *flashView = [[UIView alloc] initWithFrame:
        CGRectMake(0, 0, flashDiameter, flashDiameter)];
    flashView.center          = explosionCenter;
    flashView.backgroundColor = [UIColor colorWithRed:1.0 green:0.88 blue:0.15 alpha:0.92];
    flashView.layer.cornerRadius = flashDiameter / 2.0;
    flashView.transform       = CGAffineTransformMakeScale(0.2, 0.2);
    // Insert below the player sprite but above the game grid
    [self.view insertSubview:flashView aboveSubview:self.gameView];

    [UIView animateWithDuration:0.22
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        flashView.transform = CGAffineTransformMakeScale(2.2, 2.2);
        flashView.alpha     = 0;
    } completion:^(BOOL finished) {
        [flashView removeFromSuperview];
    }];

    // ── 2. Fragment burst ─────────────────────────────────────────────────────
    // Six pieces arranged as a 2-column × 3-row grid over the tile rect.
    // Each is a cropped slice of the source image (or an orange fallback),
    // launched outward from the explosion centre with spring physics.
    static const NSInteger kFragmentCols = 2;
    static const NSInteger kFragmentRows = 3;
    CGFloat fragmentW = tileFrame.size.width  / kFragmentCols;
    CGFloat fragmentH = tileFrame.size.height / kFragmentRows;

    for (NSInteger fragmentRow = 0; fragmentRow < kFragmentRows; fragmentRow++) {
        for (NSInteger fragmentCol = 0; fragmentCol < kFragmentCols; fragmentCol++) {

            CGRect fragmentStartFrame = CGRectMake(
                tileFrame.origin.x + fragmentCol * fragmentW,
                tileFrame.origin.y + fragmentRow * fragmentH,
                fragmentW, fragmentH);

            // ── Build fragment visual ─────────────────────────────────────────
            UIView *fragment;
            if (sourceImage) {
                // Crop the proportional slice of sourceImage that matches this
                // fragment's position within the tile.
                //
                // sourceImage is in UIKit point space (size) with a scale factor.
                // CGImageCreateWithImageInRect expects pixel coordinates, so
                // multiply by scale before cropping.
                CGFloat tileW = tileFrame.size.width;
                CGFloat tileH = tileFrame.size.height;
                CGFloat imgW  = sourceImage.size.width;
                CGFloat imgH  = sourceImage.size.height;
                CGFloat sc    = sourceImage.scale;

                CGFloat cropX = (fragmentCol * fragmentW / tileW) * imgW * sc;
                CGFloat cropY = (fragmentRow * fragmentH / tileH) * imgH * sc;
                CGFloat cropW = (fragmentW / tileW) * imgW * sc;
                CGFloat cropH = (fragmentH / tileH) * imgH * sc;

                UIImageView *imgFragment =
                    [[UIImageView alloc] initWithFrame:fragmentStartFrame];
                imgFragment.contentMode = UIViewContentModeScaleAspectFill;
                imgFragment.clipsToBounds = YES;

                CGImageRef cropRef = CGImageCreateWithImageInRect(
                    sourceImage.CGImage,
                    CGRectMake(cropX, cropY, cropW, cropH));
                if (cropRef) {
                    imgFragment.image = [UIImage imageWithCGImage:cropRef
                                                            scale:sc
                                                      orientation:UIImageOrientationUp];
                    CGImageRelease(cropRef);
                }
                fragment = imgFragment;
            } else {
                // Fallback when no source image is available (e.g. game loaded
                // before the background image finished generating).
                fragment = [[UIView alloc] initWithFrame:fragmentStartFrame];
                fragment.backgroundColor =
                    [UIColor colorWithRed:1.0 green:0.45 blue:0.1 alpha:1.0];
            }

            fragment.layer.cornerRadius = 2.5;
            fragment.clipsToBounds      = YES;
            [self.view insertSubview:fragment aboveSubview:self.gameView];

            // ── Launch vector ─────────────────────────────────────────────────
            // Direction: unit vector from tile centre toward this fragment's
            // centre, so pieces always fly away from the impact point.
            CGPoint fragmentCenter = CGPointMake(CGRectGetMidX(fragmentStartFrame),
                                                 CGRectGetMidY(fragmentStartFrame));
            CGFloat dx = fragmentCenter.x - explosionCenter.x;
            CGFloat dy = fragmentCenter.y - explosionCenter.y;
            CGFloat magnitude = hypotf(dx, dy);
            if (magnitude > 0.001f) {
                dx /= magnitude;
                dy /= magnitude;
            } else {
                // Fragment is exactly at centre (unlikely but safe): send it
                // in a random direction so it doesn't stay frozen in place.
                CGFloat angle = arc4random_uniform(360) * M_PI / 180.0;
                dx = cosf(angle);
                dy = sinf(angle);
            }

            // Travel distance varies per fragment for a natural, uneven burst.
            // Perpendicular wobble adds lateral scatter so fragments don't all
            // fly in perfectly straight lines away from centre.
            CGFloat travelDistance  = 55.0f + arc4random_uniform(75);
            NSInteger wobbleAmount  = (NSInteger)arc4random_uniform(44) - 22;
            CGFloat finalX = fragmentCenter.x + dx * travelDistance + (-dy) * wobbleAmount;
            CGFloat finalY = fragmentCenter.y + dy * travelDistance +   dx  * wobbleAmount;

            // Random tumble ±150° — gives a "hit by a powerful force" feel
            CGFloat rotationAngle = ((NSInteger)arc4random_uniform(300) - 150) * (CGFloat)M_PI / 180.0f;

            // Tiny stagger (0–80 ms) so all six fragments don't leave at
            // the exact same frame; makes the burst look less mechanical.
            NSTimeInterval launchDelay = arc4random_uniform(80) / 1000.0;

            [UIView animateWithDuration:0.45
                                  delay:launchDelay
                 usingSpringWithDamping:0.62
                  initialSpringVelocity:2.2
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{
                fragment.center    = CGPointMake(finalX, finalY);
                fragment.transform = CGAffineTransformConcat(
                    CGAffineTransformMakeRotation(rotationAngle),
                    CGAffineTransformMakeScale(0.10, 0.10));
                fragment.alpha = 0;
            } completion:^(BOOL finished) {
                [fragment removeFromSuperview];
            }];
        }
    }
}

#pragma mark - AI Text Helper

/// Called when the server returns 402 (insufficient coins).
/// Hides the loading overlay, shows an alert with the shortfall, and offers
/// to open the EZ Coin Store. Does NOT start a new run.
- (void)handleInsufficientCoinsWithBalance:(NSInteger)balance needed:(NSInteger)needed {
    // Hide loading overlay if it's showing
    [UIView animateWithDuration:0.3 animations:^{
        self.loadingOverlayView.alpha = 0;
    } completion:^(BOOL finished) {
        self.loadingOverlayView.hidden = YES;
    }];
    [self setGameInputEnabled:YES];

    NSString *message = (needed > 0)
        ? [NSString stringWithFormat:
            @"You have %ld coin%@ but a new game costs %ld coins.\n\n"
             "Replay a saved game for free, or get more coins.",
            (long)balance, balance == 1 ? @"" : @"s",
            (long)(balance + needed)]
        : @"Not enough coins for a new game. Replay a saved game for free, or get more coins.";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Need More Coins"
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];

    // "Get Coins" — open EZ Coin Store via deep link if available
    [alert addAction:[UIAlertAction
        actionWithTitle:@"Get Coins"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
            NSURL *storeURL = [NSURL URLWithString:@"ezcomplete://coin-store"];
            if ([[UIApplication sharedApplication] canOpenURL:storeURL]) {
                [[UIApplication sharedApplication] openURL:storeURL
                                                   options:@{}
                                         completionHandler:nil];
            }
    }]];

    // Only offer the saved game picker to members who have a library to browse
    if ([self userHasMembership]) {
        [alert addAction:[UIAlertAction
            actionWithTitle:@"Pick Saved Game"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
                [self showGamePicker];
        }]];
    }

    [alert addAction:[UIAlertAction
        actionWithTitle:@"Cancel"
                  style:UIAlertActionStyleCancel
                handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

/// Calls the br-ai chat endpoint.
/// When deductForNewGame is YES, passes deduct_for_new_game: true and the
/// user's JWT so the edge function deducts coins before making any OpenAI
/// calls. A 402 response means insufficient coins — completion is called
/// with nil and handleInsufficientCoins is called on the main thread.
- (void)callBrainRotAI:(NSString *)systemPrompt
           userMessage:(NSString *)userMessage
             maxTokens:(NSInteger)maxTokens
       deductNewGame:(BOOL)deductForNewGame
            completion:(void (^)(NSString *_Nullable result))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:kBRBrainRotAIURL]];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    // Attach JWT so the edge function can identify the user for coin deduction.
    // EZAuthManager.shared.accessToken returns nil when not signed in.
    NSString *jwt = [EZAuthManager shared].accessToken;
    if (jwt.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", jwt]
   forHTTPHeaderField:@"Authorization"];
    }

    NSMutableDictionary *payload = [@{
        @"system_prompt": systemPrompt,
        @"user_message":  userMessage,
        @"max_tokens":    @(maxTokens),
    } mutableCopy];
    if (deductForNewGame && jwt.length > 0) {
        payload[@"deduct_for_new_game"] = @YES;
    }
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) { completion(nil); return; }
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            if (httpResp.statusCode == 402) {
                // Insufficient coins — parse balance info and show prompt
                NSDictionary *json    = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSInteger     balance = [json[@"balance"] integerValue];
                NSInteger     needed  = [json[@"needed"]  integerValue];
                [self handleInsufficientCoinsWithBalance:balance needed:needed];
                completion(nil);
                return;
            }
            NSDictionary *json   = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString     *result = json[@"result"];
            completion(result.length > 0 ? result : nil);
        });
    }] resume];
}

#pragma mark - Audio

/// Configures AVAudioSession for ambient playback.
/// AVAudioSessionCategoryAmbient respects the device silent/mute switch, which
/// is the expected behaviour for game audio — players who want silence get it.
/// It also mixes with any audio already playing (podcast, music app) rather than
/// interrupting it. Called once in viewDidLoad before any audio objects are created.
- (void)setupAudioSession {
    NSError *categoryError = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient
                                           error:&categoryError];
    if (categoryError) {
        NSLog(@"[BrainRot] AVAudioSession category error: %@",
              categoryError.localizedDescription);
    }
    NSError *activateError = nil;
    [[AVAudioSession sharedInstance] setActive:YES error:&activateError];
    if (activateError) {
        NSLog(@"[BrainRot] AVAudioSession activate error: %@",
              activateError.localizedDescription);
    }
}

/// Preloads every SFX file into its own AVAudioPlayer so playback is
/// instantaneous at runtime — no disk reads during gameplay.
/// Files are expected in Resources/sounds/ with a .aiff extension.
/// Missing files are logged and skipped; a missing SFX will never crash the game.
- (void)preloadSoundEffects {
    self.sfxPlayers = [NSMutableDictionary dictionary];

    NSArray<NSString *> *sfxFileNames = @[
        @"player-movement",    // step taken — primary variant
        @"player-movement2",   // step taken — alternate variant
        @"found-item",         // item picked up — primary variant
        @"found-item2",        // item picked up — alternate variant
        @"hurt-player",        // player takes damage — primary variant
        @"hurt-player2",       // player takes damage — alternate variant
        @"wall-blast-fail",    // wall breach attempt failed; warden spawns
        @"wall-blast-success", // wall breached successfully
        @"enemy-died",         // enemy defeated via Use action
    ];

    for (NSString *fileName in sfxFileNames) {
        // Try the sounds subdirectory first (folder reference in Xcode);
        // fall back to the bundle root (group-based import) if not found there.
        NSURL *fileURL = [[NSBundle mainBundle] URLForResource:fileName
                                                withExtension:@"aiff"
                                                 subdirectory:@"sounds"];
        if (!fileURL) {
            fileURL = [[NSBundle mainBundle] URLForResource:fileName
                                             withExtension:@"aiff"];
        }
        if (!fileURL) {
            NSLog(@"[BrainRot] SFX not found: %@.aiff", fileName);
            continue;
        }

        NSError *loadError = nil;
        AVAudioPlayer *sfxPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL
                                                                          error:&loadError];
        if (loadError || !sfxPlayer) {
            NSLog(@"[BrainRot] SFX load error for %@: %@",
                  fileName, loadError.localizedDescription);
            continue;
        }
        sfxPlayer.volume = 0.70; // SFX sit clearly above music (music is at 0.35)
        [sfxPlayer prepareToPlay];
        self.sfxPlayers[fileName] = sfxPlayer;
    }
}

/// Plays a preloaded sound effect by its filename (no extension).
/// If the effect is already mid-playback — e.g. the player taps movement
/// rapidly — it resets to the beginning and replays rather than stacking
/// duplicate audio on top of itself.
/// Safe to call with an unrecognised name; a cache miss is a silent no-op.
- (void)playSoundNamed:(NSString *)soundName {
    AVAudioPlayer *sfxPlayer = self.sfxPlayers[soundName];
    if (!sfxPlayer) return;
    if (sfxPlayer.isPlaying) {
        [sfxPlayer stop];
        sfxPlayer.currentTime = 0;
    }
    [sfxPlayer play];
}

/// Randomly picks one variant from a named sound family and plays it.
/// Variant 1 is the base name itself (e.g. "player-movement").
/// Variant 2+ are suffixed with the variant number ("player-movement2", etc.).
/// This keeps repeated actions — movement, getting hit — from sounding robotic.
///
/// Example: playRandomVariantOfSound:@"player-movement" variantCount:2
///   → plays either "player-movement" or "player-movement2" at random.
- (void)playRandomVariantOfSound:(NSString *)baseName variantCount:(NSUInteger)variantCount {
    if (variantCount <= 1) {
        [self playSoundNamed:baseName];
        return;
    }
    NSUInteger pickedVariant = arc4random_uniform((uint32_t)variantCount);
    // Variant index 0 maps to the base name; 1+ append the number (2, 3, …)
    NSString *variantName = (pickedVariant == 0)
        ? baseName
        : [NSString stringWithFormat:@"%@%lu", baseName, (unsigned long)(pickedVariant + 1)];
    [self playSoundNamed:variantName];
}

/// Starts background music, stopping any currently playing track first.
/// Theme selection is weighted so theme1 (the full-length main loop) plays most
/// of the time, while theme2 and theme3 add occasional variety:
///   0–69  → brainrot-theme1  (70%)
///  70–84  → brainrot-theme2  (15%)
///  85–99  → brainrot-theme3  (15%)
/// All three loop indefinitely. If the randomly chosen file is missing,
/// theme1 is tried as a fallback before giving up silently.
- (void)startBackgroundMusic {
    // Stop and release any currently playing track before starting a new one.
    [self.musicPlayer stop];
    self.musicPlayer = nil;

    NSUInteger themeRoll = arc4random_uniform(100);
    NSString *themeName;
    if      (themeRoll < 70) { themeName = @"brainrot-theme1"; }
    else if (themeRoll < 85) { themeName = @"brainrot-theme2"; }
    else                     { themeName = @"brainrot-theme3"; }

    // Try sounds subdirectory first, then bundle root
    NSURL *musicURL = [[NSBundle mainBundle] URLForResource:themeName
                                              withExtension:@"mp3"
                                               subdirectory:@"sounds"];
    if (!musicURL) {
        musicURL = [[NSBundle mainBundle] URLForResource:themeName withExtension:@"mp3"];
    }

    // Fall back to theme1 if the selected track is missing
    if (!musicURL && ![themeName isEqualToString:@"brainrot-theme1"]) {
        musicURL = [[NSBundle mainBundle] URLForResource:@"brainrot-theme1"
                                          withExtension:@"mp3"
                                           subdirectory:@"sounds"];
        if (!musicURL) {
            musicURL = [[NSBundle mainBundle] URLForResource:@"brainrot-theme1"
                                              withExtension:@"mp3"];
        }
    }

    if (!musicURL) {
        NSLog(@"[BrainRot] Background music not found — checked Resources/sounds/ and bundle root");
        return;
    }

    NSError *musicError = nil;
    self.musicPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:musicURL
                                                              error:&musicError];
    if (musicError || !self.musicPlayer) {
        NSLog(@"[BrainRot] Music load error (%@): %@",
              themeName, musicError.localizedDescription);
        return;
    }
    self.musicPlayer.numberOfLoops = -1;  // loop forever until explicitly stopped
    self.musicPlayer.volume        = 0.35; // lower than SFX so effects cut through cleanly
    [self.musicPlayer prepareToPlay];
    [self.musicPlayer play];
}

/// Starts boss-intro.mp3 on a loop as the boss fight music.
/// Falls back to the normal background music if the file is missing.
- (void)_startBossFightMusic {
    [self stopBackgroundMusic];
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"boss-intro" withExtension:@"mp3"
                                           subdirectory:@"sounds"];
    if (!url) url = [[NSBundle mainBundle] URLForResource:@"boss-intro" withExtension:@"mp3"];
    if (!url) { [self startBackgroundMusic]; return; }
    NSError *err = nil;
    self.musicPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
    if (err || !self.musicPlayer) { [self startBackgroundMusic]; return; }
    self.musicPlayer.numberOfLoops = -1;
    self.musicPlayer.volume        = 0.55; // slightly louder than normal — boss energy
    [self.musicPlayer prepareToPlay];
    [self.musicPlayer play];
}

/// Fades out and stops background music.
/// Uses a recursive dispatch_after approach to decrement volume in small steps —
/// AVAudioPlayer has no built-in fade, and CADisplayLink would be overkill here.
/// Safe to call when no music is playing; the nil check on musicPlayer is the guard.
- (void)stopBackgroundMusic {
    AVAudioPlayer *playerToFade = self.musicPlayer;
    self.musicPlayer = nil; // nil out immediately so no other caller restarts it
    if (!playerToFade || !playerToFade.isPlaying) return;
    [self fadeOutAndStopPlayer:playerToFade];
}

/// Recursively lowers a player's volume by a small step on each call until it
/// reaches near-zero, then stops it. The 0.05 s interval over ~9 steps gives a
/// ~0.45 s fade — perceptible but not slow enough to feel like a hang.
/// The player reference is kept alive by the dispatch block until stop is called.
- (void)fadeOutAndStopPlayer:(AVAudioPlayer *)player {
    if (!player || player.volume <= 0.04) {
        [player stop];
        return;
    }
    player.volume -= 0.04;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self fadeOutAndStopPlayer:player];
    });
}

#pragma mark - Marquee Banner

/// Fetches high scores and updates the marquee banner.
/// Silently no-ops on network error — the existing banner text (cached from the
/// last successful fetch, or the offline placeholder) is kept rather than
/// resetting to a zero-width label which breaks scrollBannerTick.
/// Schedules a retry after 30 s so the banner self-heals when connectivity returns.
- (void)fetchHighScoresForBanner {
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:kBRHighScoreURL]
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {

        // On any failure (offline, timeout, server error) keep existing banner
        // text and schedule a retry so the banner recovers automatically.
        if (networkError || !data) {
            NSLog(@"[BrainRot] Banner fetch failed (%@), retrying in 30s",
                  networkError.localizedDescription ?: @"no data");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf fetchHighScoresForBanner];
            });
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            NSLog(@"[BrainRot] Banner fetch HTTP %ld, retrying in 30s",
                  (long)httpResponse.statusCode);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf fetchHighScoresForBanner];
            });
            return;
        }

        NSArray *scores = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSArray class]]) scores = parsed;

        NSMutableString *marqueeText = [NSMutableString stringWithString:@"🕹 BRAINROT ✦ "];
        if (scores.count == 0) {
            [marqueeText appendString:@"No scores yet — be the first!"];
        } else {
            NSArray<NSString *> *medals = @[@"🥇",@"🥈",@"🥉",
                                            @"4th",@"5th",@"6th",
                                            @"7th",@"8th",@"9th",@"10th"];
            for (NSUInteger rankIndex = 0; rankIndex < scores.count; rankIndex++) {
                NSDictionary *entry = scores[rankIndex];
                NSString     *medal = rankIndex < medals.count ? medals[rankIndex] : @"—";
                [marqueeText appendFormat:@"%@ %@  %ld  ✦  ",
                    medal, entry[@"player_name"] ?: @"???",
                    (long)[entry[@"score"] integerValue]];
            }
        }
        // Duplicate the text so the scroll loop can wrap seamlessly
        NSString *fullScrollText = [NSString stringWithFormat:@"%@     %@",
                                    marqueeText, marqueeText];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            // Guard against zero-width label breaking scrollBannerTick
            if (fullScrollText.length == 0) return;
            BOOL wasScrolling = (strongSelf.bannerDisplayLink != nil);
            strongSelf.bannerLabel.text = fullScrollText;
            [strongSelf.bannerLabel sizeToFit];
            // Only reset scroll position if we weren't already scrolling valid text.
            // If the banner was scrolling an offline placeholder, preserve position
            // so the update is seamless rather than jumping back to the right edge.
            if (!wasScrolling || CGRectGetWidth(strongSelf.bannerLabel.frame) == 0) {
                strongSelf.bannerScrollOffset = CGRectGetWidth(strongSelf.view.bounds);
            }
            [strongSelf startScrollingBanner];
        });
    }] resume];
}

- (void)startScrollingBanner {
    [self stopScrollingBanner];
    // Guard: don't start the display link if the label has no width yet —
    // singleCopyWidth would be 0 and scrollBannerTick would oscillate forever.
    if (CGRectGetWidth(self.bannerLabel.frame) == 0) return;
    self.bannerDisplayLink = [CADisplayLink displayLinkWithTarget:self
                                                         selector:@selector(scrollBannerTick)];
    [self.bannerDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopScrollingBanner {
    [self.bannerDisplayLink invalidate];
    self.bannerDisplayLink = nil;
}

- (void)scrollBannerTick {
    CGFloat labelW          = CGRectGetWidth(self.bannerLabel.frame);
    CGFloat singleCopyWidth = labelW / 2.0;
    // Safety: if label has no width (e.g. text not yet set) stop the display
    // link rather than oscillating. fetchHighScoresForBanner will restart it.
    if (singleCopyWidth <= 0) {
        [self stopScrollingBanner];
        return;
    }
    CGFloat pointsPerFrame   = 50.0 / 60.0;
    self.bannerScrollOffset -= pointsPerFrame;
    if (self.bannerScrollOffset < -singleCopyWidth) {
        self.bannerScrollOffset += singleCopyWidth;
    }
    CGFloat containerH = CGRectGetHeight(self.bannerContainerView.frame);
    CGFloat labelH     = CGRectGetHeight(self.bannerLabel.frame);
    self.bannerLabel.frame = CGRectMake(self.bannerScrollOffset,
                                        (containerH - labelH) / 2.0,
                                        labelW, labelH);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Re-fetch when coming back into view — covers the case where the user
    // played offline, then backgrounded the app, then came back with WiFi.
    [self fetchHighScoresForBanner];
    [self startHeartPulseLink];

    // One-shot: present the picker (members) or start a new run (non-members).
    // Called directly here — no dispatch_async — because viewDidAppear: already
    // guarantees the view is in the window hierarchy. The old dispatch_async
    // deferred by one run-loop tick specifically to wait for that guarantee,
    // but that 1-tick gap was exactly what made BrainRotViewController briefly
    // visible (black screen or empty chrome) before the picker appeared.
    // Presenting synchronously here means the picker is pushed in the same
    // call stack as viewDidAppear:, which iOS handles correctly.
    if (!_hasPresentedInitialFlow) {
        _hasPresentedInitialFlow = YES;
        if (self.initialWorkshopImage) {
            [self showCustomWorkshopWithInitialImage:self.initialWorkshopImage];
        } else if ([self userHasMembership]) {
            [self showGamePicker];
        } else {
            [self startNewRun];
        }
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopScrollingBanner];
    [self stopBackgroundMusic];
    [self stopHeartPulseLink];
}

#pragma mark - High Score Submission

/// Submits a score. If the request fails (offline), queues one retry after
/// 10 s rather than silently losing the score.
- (void)submitScore:(NSInteger)finalScore playerName:(NSString *)playerName {
    NSMutableURLRequest *req = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:kBRHighScoreURL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"player_name": playerName,
        @"score":       @(finalScore),
    } options:0 error:nil];

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        if (networkError) {
            NSLog(@"[BrainRot] Score submit failed (%@), retrying in 10s",
                  networkError.localizedDescription);
            // Single retry — avoids hammering the server if truly offline
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf submitScore:finalScore playerName:playerName];
            });
            return;
        }
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode == 200 || httpResponse.statusCode == 201) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf fetchHighScoresForBanner];
            });
        } else {
            NSLog(@"[BrainRot] Score submit HTTP %ld", (long)httpResponse.statusCode);
        }
    }] resume];
}

@end
