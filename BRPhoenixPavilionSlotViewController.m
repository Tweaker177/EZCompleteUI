// BRPhoenixPavilionSlotViewController.m
// EZCompleteUI — Phoenix Pavilion (凤凰阁)
//
// Client half of the `ez-phoenix-pavilion-spin` edge function. The server owns
// the reels, every payout, the free-spin award roll, the x2/x3/x5 card pick and
// all EZ Coins; this screen renders what it is told and stages the drama:
//   - reels blur while the request is in flight, then land left to right
//   - each golden hat that lands rings the same bell one pentatonic step higher
//   - from the second hat a drum roll builds, and the remaining reels slow down
//   - five hats fire an alarm with ringing bells, confetti and a shaking cabinet
//   - 3+ hats open a three-card pick; the server decides what each card hides
//   - free spins then play themselves with every win multiplied
// All art and sound are generated in code (BRPhoenixPavilionArt / Audio).

#import "BRPhoenixPavilionSlotViewController.h"
#import "BRSlotChatBar.h"
#import "BRPhoenixPavilionEngine.h"
#import "BRPhoenixPavilionArt.h"
#import "BRPhoenixPavilionAudio.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZSupabaseConfig.h"
#import "EZAppErrorReporter.h"
#import "EZCoinStoreViewController.h"

#define PPLoc(key, en) NSLocalizedStringWithDefaultValue(key, nil, NSBundle.mainBundle, en, nil)

static NSString *const kPPMutedKey = @"BRPhoenixPavilionMuted";
static NSString *const kPPLinesKey = @"BRPhoenixPavilionLines";
static NSString *const kPPBetKey = @"BRPhoenixPavilionBetIndex";
static const NSInteger kPPLoopPeriod = 8;        // cells in the seamless blur loop
static const CGFloat kPPLoopSpeed = 22.0;        // cells per second while blurring

static NSArray<NSNumber *> *PPBets(void) { return @[@1, @2, @5, @10]; }
/// Line counts the LINES button steps through (the server accepts any 1...25).
static NSArray<NSNumber *> *PPLineChoices(void) { return @[@1, @5, @10, @15, @20, @25]; }
static NSArray<NSString *> *PPSymbolNames(void) {
    return @[@"envelope", @"tea", @"peony", @"pagoda", @"crane", @"ruyi", @"coins", @"phoenix", @"hat"];
}

static UIColor *PPC(uint32_t hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:1];
}
static UIColor *PPGold(void) { return PPC(0xF2C14E); }

static NSString *PPNum(NSInteger n) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [NSNumberFormatter new]; formatter.numberStyle = NSNumberFormatterDecimalStyle; });
    return [formatter stringFromNumber:@(n)] ?: [NSString stringWithFormat:@"%ld", (long)n];
}

/// NSNull-safe JSON readers. The server should always send numbers and
/// strings, but a null or mistyped value must fail closed, never crash on
/// integerValue / boolValue (NSNull answers neither).
static NSInteger PPInteger(id value) { return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0; }
static BOOL PPBool(id value) { return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO; }
static NSString *PPString(id value) { return [value isKindOfClass:NSString.class] && ((NSString *)value).length ? value : nil; }

/// Random symbol for the blur. Hats only appear when `allowHat` so a stopped
/// reel never shows a stray hat next to the real result.
static int PPFiller(BOOL allowHat) {
    if (allowHat && arc4random_uniform(18) == 0) return PPSymbolHat;
    return (int)arc4random_uniform(PPSymbolHat);
}

static UIImage *PPParticleImage(BOOL coin) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 2;
    CGSize size = CGSizeMake(18, 18);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        if (coin) {   // a Chinese cash coin: gold disc with a square hole
            UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 16, 16)];
            [path appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(6.5, 6.5, 5, 5)]];
            path.usesEvenOddFillRule = YES;
            [PPGold() setFill]; [path fill];
            [PPC(0x9A6A08) setStroke]; path.lineWidth = 1; [path stroke];
        } else {      // a red-and-gold paper diamond
            UIBezierPath *path = [UIBezierPath bezierPath];
            [path moveToPoint:CGPointMake(9, 1)]; [path addLineToPoint:CGPointMake(15, 9)];
            [path addLineToPoint:CGPointMake(9, 17)]; [path addLineToPoint:CGPointMake(3, 9)]; [path closePath];
            [PPC(0xD4161E) setFill]; [path fill];
            [PPGold() setStroke]; path.lineWidth = 1.2; [path stroke];
        }
    }];
}

#pragma mark - Gradient view

@interface PPGradientView : UIView
@property (nonatomic, readonly) CAGradientLayer *gradientLayer;
@end
@implementation PPGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }
- (CAGradientLayer *)gradientLayer { return (CAGradientLayer *)self.layer; }
@end

#pragma mark - Pay table sheet

@interface PPPaytableViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@end

@implementation PPPaytableViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PPC(0x061C22);
    UISheetPresentationController *sheet = self.sheetPresentationController;
    if (sheet) {
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    }
    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = PPLoc(@"BRSlot.PP.Pays.Title", @"Phoenix Pavilion Pays");
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightHeavy];
    title.textColor = PPGold();
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = UIColor.clearColor;
    self.table.separatorColor = [PPGold() colorWithAlphaComponent:.25];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.allowsSelection = NO;
    self.table.rowHeight = 62;
    UILabel *footer = [UILabel new];
    footer.numberOfLines = 0;
    footer.textColor = [UIColor colorWithWhite:1 alpha:.82];
    footer.font = [UIFont systemFontOfSize:13];
    footer.text = PPLoc(@"BRSlot.PP.Pays.Rules",
        @"HOW TO PLAY\n\n• 25 paylines (choose how many to play). Matching symbols pay left to right from reel 1: 3, 4 or 5 in a row. Prizes multiply your bet per line.\n• Golden Hats are scatters and pay anywhere. A spin never shows more than five.\n• 3 hats = 5–8 free spins, 4 hats = 14–16, 5 hats = 25–30.\n• Before free spins begin, pick one of three face-down cards. It hides ×2, ×3 or ×5, and that multiplies every line win in the bonus.\n• Hats during free spins add more spins (up to 100 banked).\n• Free spins cost nothing. Spins and payouts are decided on the server.");
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

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return PPSymbolCount; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"pay"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"pay"];
    PPSymbol symbol = (PPSymbol)(PPSymbolCount - 1 - path.row);   // hat first, then dragon down to lantern
    cell.backgroundColor = UIColor.clearColor;
    cell.imageView.image = [BRPhoenixPavilionArt imageForSymbol:symbol size:CGSizeMake(46, 46)];
    cell.textLabel.textColor = PPGold();
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:.85];
    cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    cell.detailTextLabel.numberOfLines = 2;
    cell.textLabel.text = [BRPhoenixPavilionArt nameForSymbol:symbol];
    if (symbol == PPSymbolHat) {
        cell.detailTextLabel.text = PPLoc(@"BRSlot.PP.Pays.Hat", @"Scatter · 3 = 5–8 free spins · 4 = 14–16 · 5 = 25–30");
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:PPLoc(@"BRSlot.PP.Pays.Row", @"3×  %ld    4×  %ld    5×  %ld   (× bet per line)"),
                                     (long)PPPayoutUnits(symbol, 3), (long)PPPayoutUnits(symbol, 4), (long)PPPayoutUnits(symbol, 5)];
    }
    return cell;
}

@end

#pragma mark - Main screen

@interface BRPhoenixPavilionSlotViewController ()
@property (nonatomic, strong) BRPhoenixPavilionAudio *audio;
@property (nonatomic, strong) BRSlotChatBar *chatBar;
@property (nonatomic, strong) PPGradientView *background;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UILabel *balanceLabel, *winLabel, *bannerLabel, *messageLabel, *totalBetLabel;
@property (nonatomic, strong) UIView *machine;
@property (nonatomic, strong) NSMutableArray<UIView *> *reelViews;
@property (nonatomic, strong) NSMutableArray<UIView *> *strips;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<UIImageView *> *> *stripCells;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<UIView *> *> *highlights;
@property (nonatomic, strong) UIButton *linesButton, *betButton, *maxButton, *spinButton, *soundButton;
@property (nonatomic, strong) UIView *celebrationOverlay, *summaryOverlay, *pickOverlay;
@property (nonatomic, strong) NSDictionary *result;
// Card pick
@property (nonatomic, strong) NSMutableArray<UIView *> *pickCards;      // by identity 0...2
@property (nonatomic, strong) NSMutableArray<UIView *> *pickSlots;      // card in each slot, left to right
@property (nonatomic, strong) UILabel *pickTitle, *pickSubtitle, *pickPrompt;
@end

@implementation BRPhoenixPavilionSlotViewController {
    int _grid[PP_REELS][PP_ROWS];       // the result being revealed
    int _board[PP_REELS][PP_ROWS];      // what the reels currently show
    int _hatsOnReel[PP_REELS];
    int _hatTotal;
    CGPoint _slotCenters[3];
    NSInteger _lines, _betIndex;
    NSInteger _balance;                 // what the label shows
    BOOL _balanceChecked;               // _balance verified by the server (entry, settle, or bet change)
    NSInteger _freeRemaining, _freeBonusRemaining, _freeClaimRemaining, _bonusMult, _bonusTotal, _bonusLines, _bonusBet, _lastAwarded, _spinWager;
    BOOL _pickPending, _bonusMode, _busy, _spinFree, _leaving, _pickEnabled, _pickInFlight, _stripsBuilt, _reelsMoving;
    NSUInteger _epoch;
    NSTimeInterval _celebrationEnd;
    CGFloat _cellSize;
}

#pragma mark Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    _lines = [defaults objectForKey:kPPLinesKey] ? MAX(1, MIN(PP_MAX_LINES, [defaults integerForKey:kPPLinesKey])) : PP_MAX_LINES;
    _betIndex = [defaults objectForKey:kPPBetKey] ? MAX(0, MIN((NSInteger)PPBets().count - 1, [defaults integerForKey:kPPBetKey])) : 0;
    _bonusLines = _lines;
    _bonusBet = PPBets()[_betIndex].integerValue;
    self.reelViews = [NSMutableArray array];
    self.strips = [NSMutableArray array];
    self.stripCells = [NSMutableArray array];
    self.highlights = [NSMutableArray array];
    for (int r = 0; r < PP_REELS; r++) for (int row = 0; row < PP_ROWS; row++) _board[r][row] = PPFiller(NO);

    [self buildUI];
    self.audio = [BRPhoenixPavilionAudio new];
    self.audio.muted = [defaults boolForKey:kPPMutedKey];
    [self.audio prepare];
    [self refreshSoundButton];
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
    [self layoutReelsIfNeeded];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    _leaving = NO;
    [self.audio startThemeBonus:_bonusMode];
    [self refreshState];
    if (!self.chatBar) { self.chatBar = [[BRSlotChatBar alloc] initWithRoomID:@"phoenix-pavilion"]; self.chatBar.hostViewController = self; [self.chatBar attachToView:self.view]; }
    [self.chatBar start];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        _leaving = YES;
        _epoch++;
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
    [BRPhoenixPavilionArt purgeCache];
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
    button.tintColor = PPGold();
    button.backgroundColor = [PPC(0x0D4A52) colorWithAlphaComponent:.96];
    button.layer.cornerRadius = 9;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [PPGold() colorWithAlphaComponent:.72].CGColor;
    button.contentEdgeInsets = UIEdgeInsetsMake(7, 10, 7, 10);
    [button sizeToFit];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)controlButton:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightHeavy];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:PPGold() forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1 alpha:.4] forState:UIControlStateDisabled];
    button.backgroundColor = color;
    button.layer.cornerRadius = 14;
    button.layer.borderWidth = 1.5;
    button.layer.borderColor = [PPGold() colorWithAlphaComponent:.8].CGColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)statBlockCaption:(NSString *)caption value:(UILabel *)value alignment:(NSTextAlignment)alignment {
    UILabel *cap = [UILabel new];
    cap.text = caption;
    cap.font = [UIFont systemFontOfSize:10 weight:UIFontWeightHeavy];
    cap.textColor = [PPGold() colorWithAlphaComponent:.8];
    cap.textAlignment = alignment;
    value.font = [UIFont monospacedDigitSystemFontOfSize:19 weight:UIFontWeightHeavy];
    value.textColor = UIColor.whiteColor;
    value.textAlignment = alignment;
    value.adjustsFontSizeToFitWidth = YES;
    value.minimumScaleFactor = .6;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[cap, value]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 1;
    return stack;
}

- (void)buildUI {
    self.view.backgroundColor = PPC(0x04141A);
    self.background = [[PPGradientView alloc] initWithFrame:self.view.bounds];
    self.background.userInteractionEnabled = NO;
    self.background.gradientLayer.colors = @[(id)PPC(0x0C3A44).CGColor, (id)PPC(0x04141A).CGColor];
    [self.view insertSubview:self.background atIndex:0];

    self.navigationItem.hidesBackButton = YES;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:[self navButton:PPLoc(@"BRSlot.Picker.Back", @"‹  BRAINROT") action:@selector(backTapped)]];
    UIButton *pays = [self navButton:PPLoc(@"BRSlot.PP.Pays", @"PAYS") action:@selector(showPays)];
    self.soundButton = [self navButton:@"🔊" action:@selector(toggleSound)];
    self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc] initWithCustomView:self.soundButton],
                                                [[UIBarButtonItem alloc] initWithCustomView:pays]];

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

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.textAlignment = NSTextAlignmentCenter;
    title.attributedText = [[NSAttributedString alloc] initWithString:@"凤凰阁" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:34 weight:UIFontWeightHeavy],
        NSForegroundColorAttributeName: PPGold(), NSKernAttributeName: @6}];
    title.layer.shadowColor = PPC(0xFF8A1F).CGColor;
    title.layer.shadowOpacity = .7; title.layer.shadowRadius = 10; title.layer.shadowOffset = CGSizeZero;
    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.attributedText = [[NSAttributedString alloc] initWithString:@"PHOENIX PAVILION" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightHeavy],
        NSForegroundColorAttributeName: [UIColor colorWithRed:1 green:.96 blue:.86 alpha:.85], NSKernAttributeName: @4}];

    self.balanceLabel = [UILabel new];
    self.winLabel = [UILabel new];
    UIView *balanceBlock = [self statBlockCaption:PPLoc(@"BRSlot.PP.Balance", @"BALANCE") value:self.balanceLabel alignment:NSTextAlignmentLeft];
    UIView *winBlock = [self statBlockCaption:PPLoc(@"BRSlot.PP.Win", @"WIN") value:self.winLabel alignment:NSTextAlignmentRight];
    UIStackView *info = [[UIStackView alloc] initWithArrangedSubviews:@[balanceBlock, winBlock]];
    info.translatesAutoresizingMaskIntoConstraints = NO;
    info.distribution = UIStackViewDistributionFillEqually;

    self.bannerLabel = [UILabel new];
    self.bannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.bannerLabel.numberOfLines = 2;
    self.bannerLabel.textAlignment = NSTextAlignmentCenter;
    self.bannerLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightHeavy];
    self.bannerLabel.textColor = PPGold();
    self.bannerLabel.backgroundColor = [PPC(0x0F5A5A) colorWithAlphaComponent:.9];
    self.bannerLabel.layer.cornerRadius = 12;
    self.bannerLabel.layer.borderWidth = 1;
    self.bannerLabel.layer.borderColor = [PPGold() colorWithAlphaComponent:.6].CGColor;
    self.bannerLabel.clipsToBounds = YES;

    // Cabinet
    self.machine = [UIView new];
    self.machine.translatesAutoresizingMaskIntoConstraints = NO;
    self.machine.backgroundColor = PPC(0x0B3F45);
    self.machine.layer.cornerRadius = 22;
    self.machine.layer.borderWidth = 4;
    self.machine.layer.borderColor = PPGold().CGColor;
    self.machine.layer.shadowColor = PPC(0xFFB02E).CGColor;
    self.machine.layer.shadowRadius = 18;
    self.machine.layer.shadowOffset = CGSizeZero;
    self.machine.layer.shadowOpacity = 0;
    UIStackView *reelStack = [UIStackView new];
    reelStack.translatesAutoresizingMaskIntoConstraints = NO;
    reelStack.axis = UILayoutConstraintAxisHorizontal;
    reelStack.distribution = UIStackViewDistributionFillEqually;
    reelStack.spacing = 4;
    [self.machine addSubview:reelStack];
    for (int r = 0; r < PP_REELS; r++) {
        UIView *reel = [UIView new];
        reel.clipsToBounds = YES;
        reel.layer.cornerRadius = 6;
        reel.layer.borderWidth = 1;
        reel.layer.borderColor = [PPGold() colorWithAlphaComponent:.6].CGColor;
        PPGradientView *paper = [[PPGradientView alloc] initWithFrame:CGRectZero];
        paper.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        paper.gradientLayer.colors = @[(id)PPC(0xFFF8E7).CGColor, (id)PPC(0xF1DFB5).CGColor];
        [reel addSubview:paper];
        UIView *strip = [UIView new];
        [reel addSubview:strip];
        NSMutableArray<UIView *> *marks = [NSMutableArray array];
        for (int row = 0; row < PP_ROWS; row++) {
            UIView *mark = [UIView new];
            mark.hidden = YES;
            mark.userInteractionEnabled = NO;
            mark.layer.borderWidth = 3;
            mark.layer.cornerRadius = 8;
            [reel addSubview:mark];
            [marks addObject:mark];
        }
        PPGradientView *shade = [[PPGradientView alloc] initWithFrame:CGRectZero];
        shade.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        shade.userInteractionEnabled = NO;
        shade.gradientLayer.colors = @[(id)[UIColor colorWithWhite:0 alpha:.38].CGColor, (id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                                       (id)[UIColor colorWithWhite:0 alpha:0].CGColor, (id)[UIColor colorWithWhite:0 alpha:.38].CGColor];
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
    self.totalBetLabel.textColor = [PPGold() colorWithAlphaComponent:.85];

    UIColor *deepRed = PPC(0x0D5560);
    self.linesButton = [self controlButton:@"" color:deepRed action:@selector(cycleLines)];
    self.betButton = [self controlButton:@"" color:deepRed action:@selector(cycleBet)];
    self.maxButton = [self controlButton:@"" color:PPC(0x8A5A00) action:@selector(maxBet)];
    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[self.linesButton, self.betButton, self.maxButton]];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.distribution = UIStackViewDistributionFillEqually;
    controls.spacing = 10;
    self.spinButton = [self controlButton:PPLoc(@"BRSlot.PP.Spin", @"SPIN") color:PPC(0xC8141E) action:@selector(spinTapped)];
    self.spinButton.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBlack];
    self.spinButton.layer.borderWidth = 2.5;

    [content addSubview:title]; [content addSubview:subtitle]; [content addSubview:info]; [content addSubview:self.bannerLabel];
    [content addSubview:self.machine]; [content addSubview:self.messageLabel]; [content addSubview:self.totalBetLabel];
    [content addSubview:controls]; [content addSubview:self.spinButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
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

        [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:6],
        [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:0],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [info.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:10],
        [info.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:22],
        [info.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-22],
        [self.bannerLabel.topAnchor constraintEqualToAnchor:info.bottomAnchor constant:10],
        [self.bannerLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [self.bannerLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.bannerLabel.heightAnchor constraintEqualToConstant:40],
        [self.machine.topAnchor constraintEqualToAnchor:self.bannerLabel.bottomAnchor constant:12],
        [self.machine.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [self.machine.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
        [reelStack.topAnchor constraintEqualToAnchor:self.machine.topAnchor constant:12],
        [reelStack.bottomAnchor constraintEqualToAnchor:self.machine.bottomAnchor constant:-12],
        [reelStack.leadingAnchor constraintEqualToAnchor:self.machine.leadingAnchor constant:12],
        [reelStack.trailingAnchor constraintEqualToAnchor:self.machine.trailingAnchor constant:-12],
        [self.messageLabel.topAnchor constraintEqualToAnchor:self.machine.bottomAnchor constant:10],
        [self.messageLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
        [self.messageLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
        [self.messageLabel.heightAnchor constraintGreaterThanOrEqualToConstant:36],
        [self.totalBetLabel.topAnchor constraintEqualToAnchor:self.messageLabel.bottomAnchor constant:2],
        [self.totalBetLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
        [self.totalBetLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
        [controls.topAnchor constraintEqualToAnchor:self.totalBetLabel.bottomAnchor constant:8],
        [controls.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [controls.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [controls.heightAnchor constraintEqualToConstant:52],
        [self.spinButton.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:10],
        [self.spinButton.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [self.spinButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.spinButton.heightAnchor constraintEqualToConstant:56],
        [self.spinButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-18],
    ]];
    [self refreshBanner];
}

#pragma mark Reel layout

- (void)layoutReelsIfNeeded {
    if (self.reelViews.count != PP_REELS) return;
    CGFloat width = self.reelViews[0].bounds.size.width;
    if (width < 10 || _reelsMoving) return;
    if (_stripsBuilt && fabs(width - _cellSize) < 0.5) return;
    _cellSize = width;
    _stripsBuilt = YES;
    for (NSInteger r = 0; r < PP_REELS; r++) {
        [self configureStripForReel:r final:_board[r] old:_board[r] fillers:0];
        for (NSInteger row = 0; row < PP_ROWS; row++) {
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
        if (i == 0) symbol = PPFiller(NO);
        else if (i <= 3) symbol = fin[i - 1];
        else if (i < 4 + K) symbol = PPFiller(YES);
        else symbol = old[i - (4 + K)];
        cell.image = [BRPhoenixPavilionArt imageForSymbol:(PPSymbol)symbol size:imageSize];
    }
    strip.frame = CGRectMake(0, -s, s, total * s);
}

/// Seamless blur: a repeating pattern slid by exactly one period, forever, until
/// the result arrives.
- (void)startReelLoops {
    _reelsMoving = YES;
    CGFloat s = _cellSize, inset = s * 0.05;
    CGSize imageSize = CGSizeMake(s - 2 * inset, s - 2 * inset);
    NSInteger P = kPPLoopPeriod, total = P + 3;
    for (NSInteger r = 0; r < PP_REELS; r++) {
        UIView *strip = self.strips[r];
        NSMutableArray<UIImageView *> *cells = self.stripCells[r];
        int pattern[kPPLoopPeriod];
        for (NSInteger i = 0; i < P; i++) pattern[i] = PPFiller(NO);
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
            cell.image = [BRPhoenixPavilionArt imageForSymbol:(PPSymbol)pattern[i % P] size:imageSize];
        }
        strip.frame = CGRectMake(0, -(CGFloat)P * s, s, total * s);
        CABasicAnimation *loop = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        loop.fromValue = @0;
        loop.toValue = @((CGFloat)P * s);
        loop.duration = P / kPPLoopSpeed;
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

- (NSInteger)betPerLine { return PPBets()[_betIndex].integerValue; }

- (void)refreshLabels {
    self.balanceLabel.text = [NSString stringWithFormat:PPLoc(@"BRSlot.Balance.Value", @"🪙 %ld EZ Coins"), (long)_balance];
    NSInteger lines = _bonusMode ? _bonusLines : _lines, bet = _bonusMode ? _bonusBet : [self betPerLine];
    self.linesButton.titleLabel.text = nil;
    [self.linesButton setTitle:[NSString stringWithFormat:PPLoc(@"BRSlot.PP.Lines", @"LINES\n%ld"), (long)lines] forState:UIControlStateNormal];
    [self.betButton setTitle:[NSString stringWithFormat:PPLoc(@"BRSlot.PP.Bet", @"BET / LINE\n%ld"), (long)bet] forState:UIControlStateNormal];
    [self.maxButton setTitle:[NSString stringWithFormat:PPLoc(@"BRSlot.PP.MaxBet", @"MAX BET\n%ld + SPIN"), (long)(PP_MAX_LINES * PPBets().lastObject.integerValue)] forState:UIControlStateNormal];
    self.totalBetLabel.text = _bonusMode ? PPLoc(@"BRSlot.PP.FreeNoWager", @"FREE SPINS — NO WAGER TAKEN")
        : [NSString stringWithFormat:PPLoc(@"BRSlot.PP.TotalBet", @"TOTAL BET  %ld COINS"), (long)(lines * bet)];
}

- (void)refreshBanner {
    if (_bonusMode) {
        if (_freeClaimRemaining > 0 && _freeBonusRemaining == 0) {
            // Claim spins only: they play at the claim shape (25 lines x 1)
            // with no multiplier, so there is no × badge to show.
            self.bannerLabel.text = [NSString stringWithFormat:PPLoc(@"BRSlot.PP.FreeSpinsLeftClaim", @"FREE SPINS  %ld LEFT  ·  WON %@"), (long)_freeRemaining, PPNum(_bonusTotal)];
            self.bannerLabel.textColor = PPC(0xFFE48F);
            return;
        }
        NSString *mult = _bonusMult > 0 ? [NSString stringWithFormat:@"%ld", (long)_bonusMult] : @"?";
        self.bannerLabel.text = [NSString stringWithFormat:PPLoc(@"BRSlot.PP.FreeSpinsLeft", @"FREE SPINS  %ld LEFT  ·  ×%@  ·  WON %@"), (long)_freeRemaining, mult, PPNum(_bonusTotal)];
        self.bannerLabel.textColor = PPC(0xFFE48F);
    } else {
        self.bannerLabel.text = PPLoc(@"BRSlot.PP.Hint", @"3+ GOLDEN HATS = FREE SPINS\nPICK A CARD FOR ×2 / ×3 / ×5");
        self.bannerLabel.textColor = PPGold();
    }
}

- (void)setMessage:(NSString *)text highlight:(BOOL)highlight {
    self.messageLabel.text = text;
    self.messageLabel.textColor = highlight ? PPC(0xFFD86B) : [UIColor colorWithWhite:.85 alpha:1];
}

- (void)updateControls {
    BOOL idle = !_busy && !_bonusMode && _freeRemaining == 0;
    for (UIButton *button in @[self.linesButton, self.betButton, self.maxButton, self.spinButton]) {
        button.enabled = idle;
        button.alpha = idle ? 1 : 0.5;
    }
    [self.spinButton setTitle:_bonusMode ? PPLoc(@"BRSlot.PP.FreeSpinsButton", @"FREE SPINS") : PPLoc(@"BRSlot.PP.Spin", @"SPIN") forState:UIControlStateNormal];
}

- (void)cycleLines {
    if (_busy || _bonusMode) return;
    NSInteger next = 0;
    for (NSNumber *choice in PPLineChoices()) { if (choice.integerValue > _lines) { next = choice.integerValue; break; } }
    _lines = next ?: PPLineChoices().firstObject.integerValue;
    [NSUserDefaults.standardUserDefaults setInteger:_lines forKey:kPPLinesKey];
    [self refreshLabels];
    [self checkBalanceSilently];
}

- (void)cycleBet {
    if (_busy || _bonusMode) return;
    _betIndex = (_betIndex + 1) % (NSInteger)PPBets().count;
    [NSUserDefaults.standardUserDefaults setInteger:_betIndex forKey:kPPBetKey];
    [self refreshLabels];
    [self checkBalanceSilently];
}

- (void)maxBet {
    if (_busy || _bonusMode) return;
    _lines = PP_MAX_LINES;
    _betIndex = (NSInteger)PPBets().count - 1;
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


- (void)toggleSound {
    self.audio.muted = !self.audio.muted;
    [NSUserDefaults.standardUserDefaults setBool:self.audio.muted forKey:kPPMutedKey];
    [self refreshSoundButton];
}

- (void)refreshSoundButton {
    [self.soundButton setTitle:self.audio.muted ? @"🔇" : @"🔊" forState:UIControlStateNormal];
    [self.soundButton sizeToFit];
}

- (void)showPays {
    PPPaytableViewController *pays = [PPPaytableViewController new];
    pays.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:pays animated:YES completion:nil];
}

- (void)showCoinStore {
    if (self.presentedViewController) return;
    EZCoinStoreViewController *store = [EZCoinStoreViewController new];
    store.showLowCoinsWarning = YES;
    store.triggeringFeatureName = PPLoc(@"BRSlot.PP.StoreFeature", @"Phoenix Pavilion");
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:store];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark Server

- (void)request:(NSDictionary *)payload completion:(void (^)(NSDictionary *result, NSString *error, NSInteger status))completion {
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *authError) {
        if (!token) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, PPLoc(@"BRSlot.PP.SignIn", @"Please sign in to play Phoenix Pavilion."), 401); });
            return;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/ez-phoenix-pavilion-spin"]]];
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
            else if (status < 200 || status >= 300) error = PPString(result[@"reason"]) ?: PPString(result[@"error"]) ?: PPLoc(@"BRSlot.PP.RequestFailed", @"The request failed. Your balance is unchanged.");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error, status); });
        }] resume];
    }];
}

/// Syncs balance and any in-progress bonus, and resumes it if the player left
/// mid-way (including a card pick that was never made).
- (void)refreshState {
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        if (self->_busy) return;
        self->_balance = balance;
        self->_balanceChecked = YES;
        [self refreshLabels];
    }];
    [self request:@{@"action": @"status"} completion:^(NSDictionary *result, NSString *error, NSInteger status) {
        if (self->_leaving || self->_busy || !result || error) return;
        self->_freeRemaining = PPInteger(result[@"free_spins_remaining"]);
        self->_freeBonusRemaining = PPInteger(result[@"free_spins_bonus_remaining"]);
        self->_freeClaimRemaining = PPInteger(result[@"free_spins_claim_remaining"]);
        self->_pickPending = PPBool(result[@"pick_pending"]);
        self->_bonusMult = PPInteger(result[@"multiplier"]);
        self->_bonusTotal = PPInteger(result[@"bonus_total"]);
        if (self->_freeRemaining > 0) {
            self->_bonusLines = MAX(1, MIN(PP_MAX_LINES, PPInteger(result[@"lines"])));
            self->_bonusBet = PPInteger(result[@"bet_per_line"]) ?: 1;
            [self resumeBonus];
        } else {
            [self refreshLabels]; [self refreshBanner]; [self updateControls];
        }
    }];
}

- (void)resumeBonus {
    if (_busy || _freeRemaining <= 0) return;
    _busy = YES;
    [self enterBonusMode];
    [self setMessage:PPLoc(@"BRSlot.PP.Resuming", @"Resuming your free spins…") highlight:YES];
    if (_pickPending) [self after:0.8 do:^{ [self presentCardPick]; }];
    else [self after:1.0 do:^{ [self beginSpinFree:YES]; }];
}

#pragma mark Spinning

- (void)spinTapped {
    if (_busy || _bonusMode || _freeRemaining > 0) return;
    NSInteger wager = _lines * [self betPerLine];
    if (_balanceChecked) {
        // Balance was verified on entry, after the last settled spin, or on
        // the last bet change — trust the cache and fire immediately
        // instead of waiting on a round trip.
        if (_balance < wager) {
            [self setMessage:[NSString stringWithFormat:PPLoc(@"BRSlot.PP.NeedCoins", @"You need %ld coins for that bet."), (long)wager] highlight:NO];
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
            [self setMessage:[NSString stringWithFormat:PPLoc(@"BRSlot.PP.NeedCoins", @"You need %ld coins for that bet."), (long)wager] highlight:NO];
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
    [self setMessage:PPLoc(@"BRSlot.Spinning", @"Spinning…") highlight:NO];
    [self startReelLoops];
    [self.audio playSpinStart];
    [self haptic:UIImpactFeedbackStyleMedium];

    NSUInteger epoch = _epoch;
    [self request:@{@"lines": @(lines), @"bet_per_line": @(bet)} completion:^(NSDictionary *result, NSString *error, NSInteger status) {
        if (self->_epoch != epoch || self->_leaving) return;
        if (error || ![self parseResult:result]) {
            [self failSpin:error ?: PPLoc(@"BRSlot.PP.BadResponse", @"Unexpected response. Your balance is unchanged.") status:status];
            return;
        }
        [self revealResult:result];
    }];
}

- (void)failSpin:(NSString *)message status:(NSInteger)status {
    [EZAppErrorReporter reportSource:@"phoenix_pavilion" code:@"spin_failed" message:message];
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
    if (![reels isKindOfClass:NSArray.class] || reels.count != PP_REELS) return NO;
    int grid[PP_REELS][PP_ROWS], perReel[PP_REELS] = {0}, hats = 0;
    for (NSInteger c = 0; c < PP_REELS; c++) {
        NSArray *column = reels[c];
        if (![column isKindOfClass:NSArray.class] || column.count != PP_ROWS) return NO;
        for (NSInteger row = 0; row < PP_ROWS; row++) {
            if (![column[row] isKindOfClass:NSString.class]) return NO;
            NSUInteger index = [PPSymbolNames() indexOfObject:column[row]];
            if (index == NSNotFound) return NO;
            grid[c][row] = (int)index;
            if (index == PPSymbolHat) { perReel[c]++; hats++; }
        }
    }
    memcpy(_grid, grid, sizeof(grid));
    memcpy(_hatsOnReel, perReel, sizeof(perReel));
    _hatTotal = hats;
    return YES;
}

/// Lands the reels left to right. Once two hats are showing, every remaining
/// reel takes longer so the drum roll has time to build.
- (void)revealResult:(NSDictionary *)result {
    self.result = result;
    [self stopReelLoops];
    CGFloat s = _cellSize;
    double stopAt[PP_REELS];
    double t = 0.7;
    int hatsBefore = 0;
    for (int r = 0; r < PP_REELS; r++) {
        if (r > 0) {
            t += 0.30;
            if (hatsBefore >= 2 && hatsBefore < PP_MAX_SCATTERS) t += 0.65;
        }
        stopAt[r] = t;
        hatsBefore += _hatsOnReel[r];
    }
    NSUInteger epoch = _epoch;
    for (NSInteger r = 0; r < PP_REELS; r++) {
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
    for (int row = 0; row < PP_ROWS; row++) _board[reel][row] = _grid[reel][row];
    int before = 0;
    for (int r = 0; r < reel; r++) before += _hatsOnReel[r];
    int here = _hatsOnReel[reel];
    int total = before + here;
    [self.audio playReelStop:reel];
    [self haptic:here ? UIImpactFeedbackStyleHeavy : UIImpactFeedbackStyleLight];

    // Same bell for every hat, one pentatonic step higher each time.
    int k = 0;
    for (int row = 0; row < PP_ROWS; row++) {
        if (_grid[reel][row] != PPSymbolHat) continue;
        NSInteger noteIndex = before + k;
        NSInteger rowCopy = row;
        [self after:0.05 + k * 0.17 do:^{
            [self.audio playScatterNoteAtIndex:noteIndex];
            [self pulseHatAtReel:reel row:rowCopy];
        }];
        k++;
    }
    // The drum roll starts with the second hat and grows with each one after.
    if (total >= 2 && total < PP_MAX_SCATTERS && reel < PP_REELS - 1) {
        NSInteger level = MIN(3, total - 1);
        [self after:(here ? 0.3 + here * 0.1 : 0) do:^{ [self.audio startDrumRollLevel:level]; }];
    }
    if (total == PP_MAX_SCATTERS && here > 0) {
        [self.audio stopDrumRoll];
        [self after:0.3 + here * 0.17 do:^{ [self celebrateHats:PP_MAX_SCATTERS]; }];
    }
    if (reel == PP_REELS - 1) {
        [self after:(here ? 0.45 + here * 0.17 : 0.3) do:^{ [self finishSpin]; }];
    }
}

- (void)finishSpin {
    [self.audio stopDrumRoll];
    _reelsMoving = NO;
    NSDictionary *res = self.result;
    BOOL free = _spinFree;
    NSInteger awarded = PPInteger(res[@"free_spins_awarded"]);
    NSInteger balance = PPInteger(res[@"balance"]);
    _lastAwarded = awarded;
    _freeRemaining = PPInteger(res[@"free_spins_remaining"]);
    _freeBonusRemaining = PPInteger(res[@"free_spins_bonus_remaining"]);
    _freeClaimRemaining = PPInteger(res[@"free_spins_claim_remaining"]);
    _pickPending = PPBool(res[@"pick_pending"]);
    if (free) {
        _bonusTotal = PPInteger(res[@"bonus_total"]);
    } else if (awarded > 0) {
        _bonusLines = _lines; _bonusBet = [self betPerLine]; _bonusMult = 0; _bonusTotal = 0;
    }
    [EZEntitlementManager.shared applyKnownBalance:balance];

    NSTimeInterval wait = 0;
    if (awarded > 0 && _hatTotal < PP_MAX_SCATTERS) {
        if (_hatTotal >= 4) [self.audio playCrash];
        [self.audio playBonusFanfare];
        [self celebrateHats:_hatTotal];
    } else if (_hatTotal == 2) {
        [self.audio playNearMissSigh];
    }
    wait = MAX(0, _celebrationEnd - CACurrentMediaTime());
    [self after:wait + 0.15 do:^{
        [self presentWinsThen:^{ [self afterSpin]; }];
    }];
}

- (void)afterSpin {
    BOOL triggered = _lastAwarded > 0;
    if (_spinFree) {
        if (_pickPending && triggered) {
            // A claim spin landed 3+ hats: those spins are bonus spins now,
            // and they open the card pick exactly like a paid trigger. The
            // pick's completion resumes the free-spin chain.
            _bonusMult = 0;
            [self setMessage:[NSString stringWithFormat:PPLoc(@"BRSlot.PP.MoreSpins", @"+%ld MORE FREE SPINS!"), (long)_lastAwarded] highlight:YES];
            [self refreshBanner];
            [self after:0.7 do:^{ [self presentCardPick]; }];
            return;
        }
        if (_freeRemaining > 0) {
            if (triggered) {
                [self setMessage:[NSString stringWithFormat:PPLoc(@"BRSlot.PP.MoreSpins", @"+%ld MORE FREE SPINS!"), (long)_lastAwarded] highlight:YES];
            }
            [self refreshBanner];
            [self after:triggered ? 1.7 : 0.9 do:^{ [self beginSpinFree:YES]; }];
        } else {
            [self showSummary];
        }
        return;
    }
    if (triggered) {
        [self highlightHatsSticky];
        [self enterBonusMode];
        [self after:0.7 do:^{ [self presentCardPick]; }];
        return;
    }
    _busy = NO;
    [self updateControls];
    if (_balance <= 0) [self after:0.5 do:^{ [self showCoinStore]; }];
}

#pragma mark Wins and highlights

static NSArray<UIColor *> *PPLineColors(void) {
    return @[PPC(0xFFD60A), PPC(0x30D158), PPC(0x64D2FF), PPC(0xFF453A), PPC(0xBF5AF2), PPC(0xFF9F0A), PPC(0x5E5CE6), PPC(0xFF375F), PPC(0xA7F432), PPC(0x00C7BE), PPC(0xFFD6A5), PPC(0xFF6482)];
}

- (void)clearHighlights {
    for (NSInteger r = 0; r < PP_REELS; r++) {
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

- (void)highlightHatsSticky {
    for (NSInteger r = 0; r < PP_REELS; r++)
        for (NSInteger row = 0; row < PP_ROWS; row++)
            if (_grid[r][row] == PPSymbolHat) [self lightCellAtReel:r row:row color:PPGold() pulse:YES];
}

- (void)presentWinsThen:(dispatch_block_t)completion {
    NSDictionary *res = self.result;
    NSInteger payout = PPInteger(res[@"payout"]);
    NSInteger balance = PPInteger(res[@"balance"]);
    NSInteger bet = PPInteger(res[@"bet_per_line"]) ?: 1;
    NSInteger lines = PPInteger(res[@"lines"]) ?: 1;
    NSInteger fromBalance = _balance;
    _balance = balance;
    _balanceChecked = YES;
    NSArray *winners = [res[@"winning_lines"] isKindOfClass:NSArray.class] ? res[@"winning_lines"] : @[];
    if (payout <= 0) {
        [self refreshLabels];
        [self setMessage:_spinFree ? PPLoc(@"BRSlot.PP.FreeNoWin", @"Free spin · no win")
                                   : [NSString stringWithFormat:PPLoc(@"BRSlot.PP.NoWin", @"No win · −%ld coins"), (long)_spinWager] highlight:NO];
        [self after:_spinFree ? 0.5 : 0.2 do:completion];
        return;
    }
    [self.audio playWinForPayoutRatio:(double)payout / (double)MAX(1, lines * bet)];
    [self countLabel:self.winLabel from:0 to:payout duration:0.9 formatter:^NSString *(NSInteger v) { return PPNum(v); }];
    [self countLabel:self.balanceLabel from:fromBalance to:balance duration:0.9 formatter:^NSString *(NSInteger v) {
        return [NSString stringWithFormat:PPLoc(@"BRSlot.Balance.Value", @"🪙 %ld EZ Coins"), (long)v];
    }];
    [self setMessage:[NSString stringWithFormat:PPLoc(@"BRSlot.PP.WonCoins", @"Won %ld coins!"), (long)payout] highlight:YES];

    NSArray<UIColor *> *palette = PPLineColors();
    NSTimeInterval per = _spinFree ? 0.75 : 1.0;
    BOOL oneByOne = winners.count <= 3;
    for (NSUInteger i = 0; i < winners.count; i++) {
        NSDictionary *line = winners[i];
        if (![line isKindOfClass:NSDictionary.class]) continue;
        NSArray *rows = [line[@"rows"] isKindOfClass:NSArray.class] ? line[@"rows"] : @[];
        NSInteger matches = MIN(5, MAX(0, PPInteger(line[@"matches"])));
        NSInteger lineIndex = MAX(0, PPInteger(line[@"index"]));
        UIColor *color = palette[lineIndex % (NSInteger)palette.count];
        NSString *symbolName = [line[@"symbol"] isKindOfClass:NSString.class] ? line[@"symbol"] : @"";
        NSString *detail = [NSString stringWithFormat:PPLoc(@"BRSlot.PP.WinLine", @"Line %ld · %ld× %@ · +%@"),
                            (long)(lineIndex + 1), (long)matches,
                            [BRPhoenixPavilionArt nameForSymbol:(PPSymbol)MAX(0, MIN(PPSymbolHat, (NSInteger)[PPSymbolNames() indexOfObject:symbolName]))],
                            PPNum(PPInteger(line[@"coins"]))];
        void (^show)(void) = ^{
            if (oneByOne) [self clearHighlights];
            for (NSInteger col = 0; col < matches && col < (NSInteger)rows.count; col++) {
                NSInteger row = PPInteger(rows[col]);
                if (row >= 0 && row < PP_ROWS) [self lightCellAtReel:col row:row color:color pulse:oneByOne];
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
        if (self->_lastAwarded <= 0) [self clearHighlights];   // keep hats lit if a bonus follows
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

#pragma mark Hat effects

- (void)pulseHatAtReel:(NSInteger)reel row:(NSInteger)row {
    CGFloat s = _cellSize;
    UIView *reelView = self.reelViews[reel];
    CGRect slot = [reelView convertRect:CGRectMake(0, row * s, s, s) toView:self.machine];
    CGRect frame = CGRectInset(slot, s * 0.05, s * 0.05);
    UIImageView *copy = [[UIImageView alloc] initWithImage:[BRPhoenixPavilionArt imageForSymbol:PPSymbolHat size:frame.size]];
    copy.frame = frame;
    copy.layer.shadowColor = PPC(0xFFD86B).CGColor;
    copy.layer.shadowOpacity = 1; copy.layer.shadowRadius = 14; copy.layer.shadowOffset = CGSizeZero;
    UIView *ring = [[UIView alloc] initWithFrame:CGRectMake(0, 0, slot.size.width, slot.size.width)];
    ring.center = CGPointMake(CGRectGetMidX(slot), CGRectGetMidY(slot));
    ring.layer.cornerRadius = slot.size.width / 2;
    ring.layer.borderWidth = 3;
    ring.layer.borderColor = PPC(0xFFD86B).CGColor;
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

/// 3 or 4 hats: banner and a short confetti burst. 5 hats: alarm, flashing
/// light, shaking cabinet, swinging bells and a long confetti shower.
- (void)celebrateHats:(NSInteger)hats {
    NSTimeInterval duration = hats >= 5 ? 5.4 : hats == 4 ? 3.8 : 3.2;
    NSTimeInterval end = CACurrentMediaTime() + duration;
    if (end < _celebrationEnd - 0.2) return;           // already celebrating something bigger
    _celebrationEnd = end;
    if (hats >= 5) [self.audio playAlarmCelebration];
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
    main.text = [NSString stringWithFormat:PPLoc(@"BRSlot.PP.Hats", @"%ld GOLDEN HATS!"), (long)hats];
    main.font = [UIFont systemFontOfSize:hats >= 5 ? 40 : 34 weight:UIFontWeightBlack];
    main.textColor = PPC(0xFFE48F);
    main.textAlignment = NSTextAlignmentCenter;
    main.layer.shadowColor = PPC(0xD4161E).CGColor;
    main.layer.shadowOpacity = 1; main.layer.shadowRadius = 8; main.layer.shadowOffset = CGSizeZero;
    main.frame = CGRectMake(0, 0, width, 50);
    UILabel *sub = [UILabel new];
    sub.text = PPLoc(@"BRSlot.PP.HatsSub", @"金帽 · FREE SPINS UNLOCKED");
    sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    sub.textColor = UIColor.whiteColor;
    sub.textAlignment = NSTextAlignmentCenter;
    sub.frame = CGRectMake(0, 48, width, 22);
    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 76)];
    banner.backgroundColor = [PPC(0x0B3F45) colorWithAlphaComponent:.9];
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

    if (hats >= 5) {
        UIView *flash = [[UIView alloc] initWithFrame:overlay.bounds];
        flash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        flash.alpha = 0.3;
        flash.backgroundColor = PPC(0xFF2A2A);
        [overlay insertSubview:flash atIndex:0];
        CABasicAnimation *strobe = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
        strobe.fromValue = (id)PPC(0xFF2A2A).CGColor; strobe.toValue = (id)PPC(0xFFC83A).CGColor;
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
        cell.contents = (id)PPParticleImage(coin.boolValue).CGImage;
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
        self.machine.layer.borderColor = PPC(0xFFE066).CGColor;
        self.machine.backgroundColor = PPC(0x0F5A5A);
    }];
    self.machine.layer.shadowOpacity = 0.85;
    self.background.gradientLayer.colors = @[(id)PPC(0x0F5A5A).CGColor, (id)PPC(0x07242A).CGColor];
    [self.audio startThemeBonus:YES];
}

- (void)exitBonusMode {
    _bonusMode = NO;
    [UIView animateWithDuration:0.4 animations:^{
        self.machine.layer.borderColor = PPGold().CGColor;
        self.machine.backgroundColor = PPC(0x0B3F45);
    }];
    self.machine.layer.shadowOpacity = 0;
    self.background.gradientLayer.colors = @[(id)PPC(0x0C3A44).CGColor, (id)PPC(0x04141A).CGColor];
    [self.audio startThemeBonus:NO];
    [self refreshLabels];
    [self refreshBanner];
    [self updateControls];
}

#pragma mark Card pick

- (UIView *)makeCardAtIdentity:(NSInteger)identity size:(CGSize)size {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
    card.tag = identity;
    UIImageView *back = [[UIImageView alloc] initWithImage:[BRPhoenixPavilionArt cardBackWithSize:size]];
    back.frame = card.bounds;
    back.tag = 1;
    UIView *front = [[UIView alloc] initWithFrame:card.bounds];
    front.tag = 2;
    front.hidden = YES;
    front.layer.cornerRadius = 10;
    front.layer.borderWidth = 3;
    front.layer.borderColor = PPGold().CGColor;
    front.clipsToBounds = YES;
    PPGradientView *gold = [[PPGradientView alloc] initWithFrame:card.bounds];
    gold.gradientLayer.colors = @[(id)PPC(0xFFF3AE).CGColor, (id)PPC(0xE9B52A).CGColor, (id)PPC(0xB07A0C).CGColor];
    [front addSubview:gold];
    UILabel *value = [[UILabel alloc] initWithFrame:front.bounds];
    value.tag = 3;
    value.textAlignment = NSTextAlignmentCenter;
    value.font = [UIFont systemFontOfSize:size.width * 0.5 weight:UIFontWeightBlack];
    value.textColor = PPC(0x8E0F18);
    value.adjustsFontSizeToFitWidth = YES;
    [front addSubview:value];
    [card addSubview:back];
    [card addSubview:front];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTapped:)];
    [card addGestureRecognizer:tap];
    return card;
}

- (void)presentCardPick {
    [self.pickOverlay removeFromSuperview];
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithRed:.01 green:.05 blue:.06 alpha:.9];
    overlay.alpha = 0;
    [self.view addSubview:overlay];
    self.pickOverlay = overlay;
    _pickEnabled = NO; _pickInFlight = NO;
    CGFloat width = overlay.bounds.size.width, height = overlay.bounds.size.height;

    NSInteger spins = MAX(1, _freeRemaining);
    self.pickTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, height * 0.16, width - 32, 44)];
    self.pickTitle.text = [NSString stringWithFormat:PPLoc(@"BRSlot.PP.Pick.Title", @"%ld FREE SPINS"), (long)spins];
    self.pickTitle.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBlack];
    self.pickTitle.textColor = PPC(0xFFE48F);
    self.pickTitle.textAlignment = NSTextAlignmentCenter;
    self.pickSubtitle = [[UILabel alloc] initWithFrame:CGRectMake(16, CGRectGetMaxY(self.pickTitle.frame), width - 32, 30)];
    self.pickSubtitle.text = @"选择一张牌";
    self.pickSubtitle.font = [UIFont systemFontOfSize:22 weight:UIFontWeightHeavy];
    self.pickSubtitle.textColor = PPGold();
    self.pickSubtitle.textAlignment = NSTextAlignmentCenter;
    self.pickPrompt = [[UILabel alloc] initWithFrame:CGRectMake(24, CGRectGetMaxY(self.pickSubtitle.frame) + 6, width - 48, 44)];
    self.pickPrompt.numberOfLines = 2;
    self.pickPrompt.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.pickPrompt.textColor = [UIColor colorWithWhite:1 alpha:.88];
    self.pickPrompt.textAlignment = NSTextAlignmentCenter;
    self.pickPrompt.text = PPLoc(@"BRSlot.PP.Pick.Shuffling", @"Shuffling…");
    [overlay addSubview:self.pickTitle]; [overlay addSubview:self.pickSubtitle]; [overlay addSubview:self.pickPrompt];

    CGFloat cardWidth = MIN(104, (width - 72) / 3), cardHeight = cardWidth * 1.4;
    self.pickCards = [NSMutableArray array];
    self.pickSlots = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        _slotCenters[i] = CGPointMake(width / 2 + (i - 1) * (cardWidth + 14), height * 0.55);
        UIView *card = [self makeCardAtIdentity:i size:CGSizeMake(cardWidth, cardHeight)];
        card.center = CGPointMake(_slotCenters[i].x, -cardHeight);
        [overlay addSubview:card];
        [self.pickCards addObject:card];
        [self.pickSlots addObject:card];
        [UIView animateWithDuration:0.5 delay:0.12 * i usingSpringWithDamping:0.7 initialSpringVelocity:0 options:0 animations:^{
            card.center = self->_slotCenters[i];
        } completion:nil];
    }
    [UIView animateWithDuration:0.3 animations:^{ overlay.alpha = 1; }];
    [self.audio playBonusFanfare];
    [self after:1.1 do:^{ [self shuffleStep:0 of:11]; }];
}

/// Theatrical shuffle: the server decides what each card hides only when one
/// is picked, so the shuffle changes nothing about the odds.
- (void)shuffleStep:(NSInteger)step of:(NSInteger)total {
    if (!self.pickOverlay) return;
    if (step >= total) {
        _pickEnabled = YES;
        self.pickPrompt.text = PPLoc(@"BRSlot.PP.Pick.Prompt", @"Pick a card. One hides your multiplier for every free spin.");
        return;
    }
    NSInteger a = arc4random_uniform(3);
    NSInteger b = (a + 1 + arc4random_uniform(2)) % 3;
    UIView *cardA = self.pickSlots[a], *cardB = self.pickSlots[b];
    self.pickSlots[a] = cardB;
    self.pickSlots[b] = cardA;
    NSTimeInterval duration = 0.34 - 0.18 * ((double)step / MAX(1, total - 1));
    CGPoint ca = _slotCenters[a], cb = _slotCenters[b];
    CGPoint mid = CGPointMake((ca.x + cb.x) / 2, (ca.y + cb.y) / 2);
    [self.pickOverlay bringSubviewToFront:cardA];
    [self.audio playCardFlip];
    [UIView animateKeyframesWithDuration:duration delay:0 options:UIViewKeyframeAnimationOptionCalculationModeLinear animations:^{
        [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.5 animations:^{
            cardA.center = CGPointMake(mid.x, mid.y - 30);
            cardB.center = CGPointMake(mid.x, mid.y + 30);
        }];
        [UIView addKeyframeWithRelativeStartTime:0.5 relativeDuration:0.5 animations:^{
            cardA.center = cb;
            cardB.center = ca;
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
    [self.audio playCardPick];
    [self haptic:UIImpactFeedbackStyleMedium];
    self.pickPrompt.text = PPLoc(@"BRSlot.PP.Pick.Wait", @"Opening…");
    [self request:@{@"action": @"pick", @"card": @(identity)} completion:^(NSDictionary *result, NSString *error, NSInteger status) {
        if (self->_leaving) return;
        NSArray *cards = result[@"cards"];
        if (error || ![cards isKindOfClass:NSArray.class] || cards.count != 3) {
            self->_pickInFlight = NO;
            if (status == 409) {                 // nothing to pick; re-sync and close
                [self closePickOverlayThen:^{ self->_busy = NO; [self refreshState]; }];
                return;
            }
            self.pickPrompt.text = PPLoc(@"BRSlot.PP.Pick.Retry", @"Couldn't reach the server. Tap a card to try again.");
            return;
        }
        self->_pickEnabled = NO;
        [self revealPick:result identity:identity];
    }];
}

- (void)revealPick:(NSDictionary *)result identity:(NSInteger)identity {
    NSArray *cards = result[@"cards"];
    NSInteger multiplier = PPInteger(result[@"multiplier"]);
    // Values stay bound to card identity: the card the player tapped
    // (pickCards[identity] — the same view that carries that tag) shows
    // cards[identity], the value the server recorded for this pick.
    for (NSInteger i = 0; i < 3; i++) {
        UILabel *value = (UILabel *)[self.pickCards[i] viewWithTag:3];
        value.text = [NSString stringWithFormat:@"×%ld", (long)PPInteger(cards[i])];
    }
    _bonusMult = multiplier;
    _pickPending = NO;
    UIView *picked = self.pickCards[identity];
    [self.pickOverlay bringSubviewToFront:picked];

    // 1. Turn over ALL THREE cards at once, so the player sees what
    // every card hid — including the two they did not pick.
    for (UIView *card in self.pickCards) {
        [UIView transitionWithView:card duration:0.45 options:UIViewAnimationOptionTransitionFlipFromLeft animations:^{
            [card viewWithTag:1].hidden = YES;
            [card viewWithTag:2].hidden = NO;
        } completion:nil];
    }
    // 2. Hold on the full reveal, then the two unpicked cards fade out
    // completely and the picked card takes center stage, still showing
    // its value — the picked card is the one that stays visible.
    [self after:1.15 do:^{
        for (NSInteger i = 0; i < 3; i++) {
            if (i == identity) continue;
            UIView *card = self.pickCards[i];
            [UIView animateWithDuration:0.35 animations:^{ card.alpha = 0; } completion:^(BOOL finished) {
                card.hidden = YES;
            }];
        }
        [UIView animateWithDuration:0.35 animations:^{
            picked.center = self->_slotCenters[1];
            picked.transform = CGAffineTransformMakeScale(1.18, 1.18);
        }];
    }];
    // 3. A beat with only the picked card on screen, then celebrate the
    // multiplier it revealed before the free spins begin.
    [self after:2.15 do:^{
        [self.audio playMultiplierReveal:multiplier];
        [self haptic:UIImpactFeedbackStyleHeavy];
        self.pickPrompt.text = [NSString stringWithFormat:PPLoc(@"BRSlot.PP.Pick.Result", @"Your multiplier: ×%ld"), (long)multiplier];
        self.pickPrompt.textColor = PPC(0xFFE48F);
        self.pickPrompt.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBlack];
    }];
    [self after:3.3 do:^{
        [self closePickOverlayThen:^{
            [self refreshBanner];
            [self setMessage:[NSString stringWithFormat:PPLoc(@"BRSlot.PP.BonusStart", @"×%ld free spins begin!"), (long)multiplier] highlight:YES];
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
    overlay.backgroundColor = [UIColor colorWithRed:.01 green:.05 blue:.06 alpha:.88];
    overlay.alpha = 0;
    [self.view addSubview:overlay];
    self.summaryOverlay = overlay;
    CGFloat width = overlay.bounds.size.width, height = overlay.bounds.size.height;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, height * 0.30, width - 32, 44)];
    title.text = PPLoc(@"BRSlot.PP.Summary.Title", @"FREE SPINS COMPLETE");
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBlack];
    title.textColor = PPC(0xFFE48F);
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(16, CGRectGetMaxY(title.frame) + 4, width - 32, 24)];
    sub.text = [NSString stringWithFormat:PPLoc(@"BRSlot.PP.Summary.Sub", @"×%ld  ·  TOTAL WIN"), (long)MAX(1, mult)];
    sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    sub.textColor = PPGold();
    sub.textAlignment = NSTextAlignmentCenter;
    UILabel *amount = [[UILabel alloc] initWithFrame:CGRectMake(16, CGRectGetMaxY(sub.frame) + 10, width - 32, 64)];
    amount.text = [NSString stringWithFormat:@"🪙 %@", PPNum(0)];
    amount.font = [UIFont monospacedDigitSystemFontOfSize:48 weight:UIFontWeightBlack];
    amount.textColor = UIColor.whiteColor;
    amount.textAlignment = NSTextAlignmentCenter;
    amount.adjustsFontSizeToFitWidth = YES;
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, CGRectGetMaxY(amount.frame) + 12, width - 32, 20)];
    hint.text = PPLoc(@"BRSlot.PP.Summary.Tap", @"Tap to continue");
    hint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    hint.textColor = [UIColor colorWithWhite:1 alpha:.6];
    hint.textAlignment = NSTextAlignmentCenter;
    [overlay addSubview:title]; [overlay addSubview:sub]; [overlay addSubview:amount]; [overlay addSubview:hint];
    [overlay addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSummary)]];
    [UIView animateWithDuration:0.35 animations:^{ overlay.alpha = 1; }];
    if (total > 0) {
        [self.audio playWinForPayoutRatio:30];
        [self countLabel:amount from:0 to:total duration:1.4 formatter:^NSString *(NSInteger v) { return [NSString stringWithFormat:@"🪙 %@", PPNum(v)]; }];
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
    [self setMessage:PPLoc(@"BRSlot.PP.Idle", @"Match 3 or more symbols from the left on a payline.") highlight:NO];
    [self refreshState];
}

@end
