#import "BRSlotMachineViewController.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZSupabaseConfig.h"
#import "EZCoinStoreViewController.h"
#import "BRAssetSourceSheetViewController.h"
#import "BRAssetGenerationSheetViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>

static NSArray<NSString *> *BRSlotSymbols(void) {
    return @[@"cherry", @"bar", @"double_bar", @"triple_bar", @"bell", @"diamond", @"seven", @"brain"];
}
static NSDictionary<NSString *, NSString *> *BRSlotFallbackSymbols(void) {
    return @{ @"cherry": @"🍒", @"bar": @"▰", @"double_bar": @"▰▰", @"triple_bar": @"▰▰▰",
              @"bell": @"🔔", @"diamond": @"♦︎", @"seven": @"7", @"brain": @"🧠" };
}

@interface BRSlotOddsSheetViewController : UIViewController <UITableViewDataSource>
@property (nonatomic, copy) NSDictionary<NSString *, UIImage *> *symbolImages;
@property (nonatomic, strong) UITableView *tableView;
@end

@implementation BRSlotOddsSheetViewController
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor = [UIColor colorWithRed:.07 green:.03 blue:.16 alpha:1]; self.modalPresentationStyle = UIModalPresentationPageSheet; UISheetPresentationController *sheet = self.sheetPresentationController; sheet.prefersGrabberVisible = YES; sheet.preferredCornerRadius = 24; sheet.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
    UILabel *title = [UILabel new]; title.text = @"Payout Table"; title.font = [UIFont systemFontOfSize:25 weight:UIFontWeightBlack]; title.textColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1]; title.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:title];
    UILabel *sub = [UILabel new]; sub.text = @"Three matching symbols, left-to-right on any active line"; sub.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]; sub.textColor = [UIColor colorWithWhite:.68 alpha:1]; sub.numberOfLines = 2; sub.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:sub];
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; self.tableView.backgroundColor = UIColor.clearColor; self.tableView.dataSource = self; self.tableView.rowHeight = 56; self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:.08]; self.tableView.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.tableView];
    UILabel *footer = [UILabel new]; footer.text = @"5 fixed paylines: top, middle, bottom, and both diagonals. Weighted reels target approximately 92% RTP. Triple 🧠 on a 25-coin max bet also claims the progressive jackpot."; footer.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]; footer.textColor = [UIColor colorWithWhite:.62 alpha:1]; footer.numberOfLines = 0; footer.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:footer];
    [NSLayoutConstraint activateConstraints:@[[title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:18], [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22], [title.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22], [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:5], [sub.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [sub.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [self.tableView.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:9], [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [self.tableView.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-7], [footer.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [footer.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [footer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-14]]]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return BRSlotSymbols().count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path { static NSString *reuse = @"Odds"; UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuse]; NSString *symbol = BRSlotSymbols()[path.row]; UIImage *custom = self.symbolImages[symbol]; cell.backgroundColor = [UIColor colorWithWhite:1 alpha:.045]; cell.textLabel.text = [[symbol stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString]; cell.textLabel.textColor = UIColor.whiteColor; cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold]; cell.detailTextLabel.text = @[@"13×", @"21×", @"37×", @"55×", @"75×", @"150×", @"300×", @"750×"][path.row]; cell.detailTextLabel.textColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1]; cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightBlack]; cell.imageView.backgroundColor = UIColor.whiteColor; cell.imageView.layer.cornerRadius = 6; cell.imageView.clipsToBounds = YES; if (custom) { cell.imageView.image = custom; cell.imageView.contentMode = UIViewContentModeScaleAspectFit; } else { UIGraphicsBeginImageContextWithOptions(CGSizeMake(34, 34), NO, 0); [BRSlotFallbackSymbols()[symbol] drawInRect:CGRectMake(0, 0, 34, 34) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:25]}]; UIImage *image = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext(); cell.imageView.image = image; } return cell; }
@end

/// Brain Rot-styled replacement for the stock action sheet used to select a
/// slot symbol. Keeping it here makes its imagery and naming share the slot
/// machine's single source of truth.
@interface BRSlotCustomizeSheetViewController : UIViewController
@property (nonatomic, copy) NSDictionary<NSString *, UIImage *> *symbolImages;
@property (nonatomic, copy) void (^symbolSelected)(NSString *symbol);
@property (nonatomic, copy) void (^symbolReset)(NSString *symbol);
@property (nonatomic, copy) dispatch_block_t resetSelected;
@end

@implementation BRSlotCustomizeSheetViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:.07 green:.03 blue:.16 alpha:1];
    self.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = self.sheetPresentationController;
    sheet.prefersGrabberVisible = YES; sheet.preferredCornerRadius = 24;
    sheet.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem]; [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal]; close.tintColor = [UIColor colorWithWhite:.70 alpha:1]; [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside]; close.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:close];
    UILabel *title = [UILabel new]; title.text = @"Customize your symbols"; title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBlack]; title.textColor = UIColor.whiteColor; title.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:title];
    UILabel *subtitle = [UILabel new]; subtitle.text = @"Choose a tile to use one of your photos. Your artwork stays on this device."; subtitle.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium]; subtitle.textColor = [UIColor colorWithWhite:.66 alpha:1]; subtitle.numberOfLines = 2; subtitle.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:subtitle];
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:scroll];
    UIView *content = [UIView new]; content.translatesAutoresizingMaskIntoConstraints = NO; [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[[close.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10], [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20], [close.widthAnchor constraintEqualToConstant:30], [close.heightAnchor constraintEqualToConstant:30], [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14], [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20], [title.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-12], [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6], [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [subtitle.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20], [scroll.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:16], [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor], [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor], [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor], [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor], [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor], [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];

    UIStackView *grid = [UIStackView new]; grid.axis = UILayoutConstraintAxisVertical; grid.spacing = 10; grid.translatesAutoresizingMaskIntoConstraints = NO; [content addSubview:grid];
    NSArray *symbols = BRSlotSymbols();
    for (NSInteger row = 0; row < 4; row++) { UIStackView *line = [UIStackView new]; line.axis = UILayoutConstraintAxisHorizontal; line.spacing = 10; line.distribution = UIStackViewDistributionFillEqually; for (NSInteger col = 0; col < 2; col++) { NSString *symbol = symbols[row * 2 + col]; [line addArrangedSubview:[self tileForSymbol:symbol]]; } [grid addArrangedSubview:line]; }
    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem]; [reset setTitle:@"↺  Reset all artwork" forState:UIControlStateNormal]; [reset setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal]; reset.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold]; reset.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:.10]; reset.layer.cornerRadius = 13; reset.layer.borderWidth = 1; reset.layer.borderColor = [[UIColor systemRedColor] colorWithAlphaComponent:.45].CGColor; [reset addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside]; reset.translatesAutoresizingMaskIntoConstraints = NO; [content addSubview:reset];
    [NSLayoutConstraint activateConstraints:@[[grid.topAnchor constraintEqualToAnchor:content.topAnchor], [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20], [grid.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20], [reset.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:18], [reset.leadingAnchor constraintEqualToAnchor:grid.leadingAnchor], [reset.trailingAnchor constraintEqualToAnchor:grid.trailingAnchor], [reset.heightAnchor constraintEqualToConstant:48], [reset.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-20]]];
}

- (UIButton *)tileForSymbol:(NSString *)symbol {
    UIButton *tile = [UIButton buttonWithType:UIButtonTypeCustom]; tile.accessibilityIdentifier = symbol; tile.backgroundColor = [UIColor colorWithWhite:1 alpha:.055]; tile.layer.cornerRadius = 16; tile.layer.borderWidth = 1; tile.layer.borderColor = [[UIColor colorWithRed:1 green:.72 blue:.14 alpha:1] colorWithAlphaComponent:.42].CGColor; [tile addTarget:self action:@selector(symbolTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIImageView *art = [UIImageView new]; art.contentMode = UIViewContentModeScaleAspectFit; art.translatesAutoresizingMaskIntoConstraints = NO; UIImage *custom = self.symbolImages[symbol]; art.image = custom; [tile addSubview:art];
    UILabel *fallback = [UILabel new]; fallback.text = custom ? @"" : BRSlotFallbackSymbols()[symbol]; fallback.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBlack]; fallback.textColor = [UIColor colorWithRed:1 green:.77 blue:.18 alpha:1]; fallback.textAlignment = NSTextAlignmentCenter; fallback.translatesAutoresizingMaskIntoConstraints = NO; [tile addSubview:fallback];
    UILabel *name = [UILabel new]; name.text = [symbol stringByReplacingOccurrencesOfString:@"_" withString:@" "].capitalizedString; name.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold]; name.textColor = UIColor.whiteColor; name.translatesAutoresizingMaskIntoConstraints = NO; [tile addSubview:name];
    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem]; [reset setImage:[UIImage systemImageNamed:@"arrow.counterclockwise.circle.fill"] forState:UIControlStateNormal]; reset.tintColor = [UIColor colorWithRed:1 green:.55 blue:.25 alpha:1]; reset.accessibilityIdentifier = symbol; reset.hidden = (custom == nil); [reset addTarget:self action:@selector(resetSymbolTapped:) forControlEvents:UIControlEventTouchUpInside]; reset.translatesAutoresizingMaskIntoConstraints = NO; [tile addSubview:reset];
    [NSLayoutConstraint activateConstraints:@[[tile.heightAnchor constraintEqualToConstant:72], [art.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:11], [art.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor], [art.widthAnchor constraintEqualToConstant:45], [art.heightAnchor constraintEqualToConstant:45], [fallback.leadingAnchor constraintEqualToAnchor:art.leadingAnchor], [fallback.centerYAnchor constraintEqualToAnchor:art.centerYAnchor], [fallback.widthAnchor constraintEqualToAnchor:art.widthAnchor], [fallback.heightAnchor constraintEqualToAnchor:art.heightAnchor], [name.leadingAnchor constraintEqualToAnchor:art.trailingAnchor constant:8], [name.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-28], [name.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor], [reset.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-8], [reset.topAnchor constraintEqualToAnchor:tile.topAnchor constant:7], [reset.widthAnchor constraintEqualToConstant:22], [reset.heightAnchor constraintEqualToConstant:22]]];
    return tile;
}
- (void)symbolTapped:(UIButton *)sender { NSString *symbol = sender.accessibilityIdentifier; [self dismissViewControllerAnimated:YES completion:^{ if (self.symbolSelected) self.symbolSelected(symbol); }]; }
- (void)resetSymbolTapped:(UIButton *)sender { NSString *symbol = sender.accessibilityIdentifier; [self dismissViewControllerAnimated:YES completion:^{ if (self.symbolReset) self.symbolReset(symbol); }]; }
- (void)resetTapped { [self dismissViewControllerAnimated:YES completion:^{ if (self.resetSelected) self.resetSelected(); }]; }
- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

@interface BRSlotMachineViewController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate, AVAudioPlayerDelegate>
@property (nonatomic, strong) NSMutableArray<NSMutableArray<UIImageView *> *> *reels;
@property (nonatomic, strong) UILabel *balanceLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UILabel *betLabel;
@property (nonatomic, strong) UIButton *spinButton;
@property (nonatomic, strong) UIButton *betButton;
@property (nonatomic, strong) UIButton *perLineButton;
@property (nonatomic, strong) UIButton *customizeButton;
@property (nonatomic, strong) UIView *leverKnob;
@property (nonatomic, strong) NSLayoutConstraint *leverKnobCenterY;
@property (nonatomic, strong) NSLayoutConstraint *machineLeadingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *machineTrailingConstraint;
@property (nonatomic) NSInteger activeLineCount;
@property (nonatomic) NSInteger betPerLine;
@property (nonatomic) BOOL spinning;
@property (nonatomic, copy) NSString *pendingImageSymbol;
@property (nonatomic, strong) NSDictionary<NSString *, UIImage *> *customImages;
@property (nonatomic, strong) AVAudioPlayer *musicPlayer;
@property (nonatomic, strong) AVAudioPlayer *lossPlayer;
@property (nonatomic, strong) UIView *winOverlay;
@property (nonatomic) BOOL winningThemeActive;
@property (nonatomic) NSUInteger placeholderAnimationID;
@property (nonatomic, strong) UIView *jackpotBanner;
@property (nonatomic, strong) UILabel *jackpotBannerLabel;
@property (nonatomic) NSInteger progressiveJackpot;
@property (nonatomic) NSInteger pendingProgressiveJackpot;
@property (nonatomic) BOOL progressiveBannerAnimating;
@property (nonatomic, strong) NSDictionary<NSString *, UIImage *> *importedThemeImages;
@property (nonatomic, strong) UIImage *importedRoomImage;
@end

@implementation BRSlotMachineViewController

- (instancetype)initWithBrainRotGameRecord:(BRGameRecord *)record {
    self = [super init];
    if (self) {
        NSMutableDictionary *images = [NSMutableDictionary dictionary];
        if (record.playerImage) images[@"brain"] = record.playerImage;
        if (record.enemyImage) images[@"seven"] = record.enemyImage;
        if (record.obstacleImage) images[@"cherry"] = record.obstacleImage;
        [images addEntriesFromDictionary:record.customAssetImages ?: @{}];
        _importedThemeImages = images;
        _importedRoomImage = record.backgroundImage;
        self.title = record.themeTitle.length ? [NSString stringWithFormat:@"%@ Slots", record.themeTitle] : @"Community Slots";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Brainrot Slots";
    self.view.backgroundColor = [UIColor colorWithRed:0.045 green:0.025 blue:0.09 alpha:1];
    self.activeLineCount = 5; self.betPerLine = 1;
    self.customImages = self.importedThemeImages.count ? self.importedThemeImages : [self loadCustomImages];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:[self slotNavigationButtonWithTitle:@"‹  BACK" action:@selector(backTapped)]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:[self slotNavigationButtonWithTitle:@"ODDS" action:@selector(showOdds)]];
    [self buildUI];
    [self refreshBalance];
    [self setupAudio];
}

- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; if (!self.musicPlayer.isPlaying) [self playTheme:@"brainrot-theme1"]; [self refreshProgressiveJackpot]; [self refreshBalance]; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews];
    // Keep the game usable on short safe areas (including Display Zoom or a
    // tweak that reduces usable height) without changing tall-device layout.
    CGFloat availableHeight = CGRectGetHeight(self.view.safeAreaLayoutGuide.layoutFrame);
    CGFloat naturalMachineWidth = MAX(0, CGRectGetWidth(self.view.bounds) - 44);
    CGFloat compactMachineWidth = MAX(230, availableHeight - 350);
    CGFloat targetWidth = MIN(naturalMachineWidth, compactMachineWidth);
    CGFloat inset = MAX(22, (CGRectGetWidth(self.view.bounds) - targetWidth) / 2.0);
    if (fabs(self.machineLeadingConstraint.constant - inset) > .5) {
        self.machineLeadingConstraint.constant = inset;
        self.machineTrailingConstraint.constant = -inset;
    }
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed) { [self.musicPlayer stop]; self.musicPlayer = nil; } }

- (void)buildUI {
    if (self.importedRoomImage) { UIImageView *room = [[UIImageView alloc] initWithImage:self.importedRoomImage]; room.frame = self.view.bounds; room.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; room.contentMode = UIViewContentModeScaleAspectFill; room.alpha = .22; [self.view insertSubview:room atIndex:0]; }
    UILabel *title = [UILabel new]; title.text = @"🧠  BRAINROT SLOTS  🧠";
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBlack]; title.textColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1];
    title.textAlignment = NSTextAlignmentCenter; title.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:title];
    self.balanceLabel = [UILabel new]; self.balanceLabel.text = @"🪙 — EZ Coins"; self.balanceLabel.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightBold]; self.balanceLabel.textColor = UIColor.whiteColor; self.balanceLabel.textAlignment = NSTextAlignmentCenter; self.balanceLabel.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.balanceLabel];
    self.jackpotBanner = [UIView new]; self.jackpotBanner.backgroundColor = [UIColor colorWithRed:.52 green:.08 blue:.34 alpha:1]; self.jackpotBanner.layer.cornerRadius = 10; self.jackpotBanner.layer.borderWidth = 1; self.jackpotBanner.layer.borderColor = [UIColor colorWithRed:1 green:.76 blue:.14 alpha:.9].CGColor; self.jackpotBanner.clipsToBounds = YES; self.jackpotBanner.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.jackpotBanner];
    self.jackpotBannerLabel = [UILabel new]; self.jackpotBannerLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightBlack]; self.jackpotBannerLabel.textColor = [UIColor colorWithRed:1 green:.84 blue:.2 alpha:1]; self.jackpotBannerLabel.text = @"  PROGRESSIVE JACKPOT • MAX BET ONLY • WIN UP TO — COINS  "; self.jackpotBannerLabel.translatesAutoresizingMaskIntoConstraints = NO; [self.jackpotBanner addSubview:self.jackpotBannerLabel];

    UIView *machine = [UIView new]; machine.backgroundColor = [UIColor colorWithRed:.28 green:.08 blue:.42 alpha:1]; machine.layer.cornerRadius = 24; machine.layer.borderWidth = 3; machine.layer.borderColor = [UIColor colorWithRed:1 green:.7 blue:.12 alpha:1].CGColor; machine.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:machine];
    UIView *lever = [UIView new]; lever.backgroundColor = [UIColor colorWithRed:.10 green:.03 blue:.18 alpha:1]; lever.layer.cornerRadius = 17; lever.layer.borderWidth = 2; lever.layer.borderColor = [UIColor colorWithRed:1 green:.72 blue:.12 alpha:1].CGColor; lever.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:lever];
    UIView *shaft = [UIView new]; shaft.backgroundColor = [UIColor colorWithRed:1 green:.72 blue:.12 alpha:1]; shaft.layer.cornerRadius = 3; shaft.translatesAutoresizingMaskIntoConstraints = NO; [lever addSubview:shaft];
    self.leverKnob = [UIView new]; self.leverKnob.backgroundColor = [UIColor colorWithRed:.9 green:.12 blue:.32 alpha:1]; self.leverKnob.layer.cornerRadius = 16; self.leverKnob.layer.borderWidth = 2; self.leverKnob.layer.borderColor = UIColor.whiteColor.CGColor; self.leverKnob.translatesAutoresizingMaskIntoConstraints = NO; [lever addSubview:self.leverKnob];
    UILabel *bolt = [UILabel new]; bolt.text = @"⚡"; bolt.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBlack]; bolt.textAlignment = NSTextAlignmentCenter; bolt.frame = self.leverKnob.bounds; bolt.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [self.leverKnob addSubview:bolt];
    [self.leverKnob addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pullLever:)]]; self.leverKnob.userInteractionEnabled = YES;
    self.leverKnobCenterY = [self.leverKnob.centerYAnchor constraintEqualToAnchor:lever.centerYAnchor];
    [NSLayoutConstraint activateConstraints:@[[shaft.centerXAnchor constraintEqualToAnchor:lever.centerXAnchor], [shaft.centerYAnchor constraintEqualToAnchor:lever.centerYAnchor], [shaft.widthAnchor constraintEqualToConstant:6], [shaft.heightAnchor constraintEqualToConstant:76], [self.leverKnob.centerXAnchor constraintEqualToAnchor:lever.centerXAnchor], self.leverKnobCenterY, [self.leverKnob.widthAnchor constraintEqualToConstant:32], [self.leverKnob.heightAnchor constraintEqualToConstant:32]]];
    UIStackView *reelStack = [[UIStackView alloc] init]; reelStack.axis = UILayoutConstraintAxisHorizontal; reelStack.distribution = UIStackViewDistributionFillEqually; reelStack.spacing = 8; reelStack.translatesAutoresizingMaskIntoConstraints = NO; [machine addSubview:reelStack];
    self.reels = [NSMutableArray array]; NSArray *initial = @[@"cherry", @"bell", @"seven", @"bar", @"diamond", @"brain", @"double_bar", @"triple_bar", @"cherry"];
    for (NSInteger col = 0; col < 3; col++) { UIStackView *column = [UIStackView new]; column.axis = UILayoutConstraintAxisVertical; column.distribution = UIStackViewDistributionFillEqually; column.spacing = 6; NSMutableArray *views = [NSMutableArray array]; for (NSInteger row = 0; row < 3; row++) { UIImageView *slot = [self slotView]; [self setSymbol:initial[col * 3 + row] onView:slot]; [column addArrangedSubview:slot]; [views addObject:slot]; } [self.reels addObject:views]; [reelStack addArrangedSubview:column]; }
    [NSLayoutConstraint activateConstraints:@[[reelStack.topAnchor constraintEqualToAnchor:machine.topAnchor constant:15], [reelStack.bottomAnchor constraintEqualToAnchor:machine.bottomAnchor constant:-15], [reelStack.leadingAnchor constraintEqualToAnchor:machine.leadingAnchor constant:15], [reelStack.trailingAnchor constraintEqualToAnchor:machine.trailingAnchor constant:-15]]];

    self.messageLabel = [UILabel new]; self.messageLabel.text = @"Five paylines • server-verified outcomes"; self.messageLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]; self.messageLabel.textColor = [UIColor colorWithWhite:.8 alpha:1]; self.messageLabel.textAlignment = NSTextAlignmentCenter; self.messageLabel.numberOfLines = 2; self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.messageLabel];
    UIButton *lines = [self controlButton:@"LINES" color:[UIColor systemIndigoColor] action:@selector(cycleLines)]; self.betButton = lines; [self setLinesButtonTitle];
    UIButton *perLine = [self controlButton:@"BET / LINE" color:[UIColor colorWithRed:.08 green:.55 blue:.62 alpha:1] action:@selector(cycleBetPerLine)]; self.perLineButton = perLine; [self setPerLineButtonTitle:perLine];
    UIButton *maxBet = [self controlButton:@"MAX BET\n⚡ 25" color:[UIColor colorWithRed:.53 green:.18 blue:.72 alpha:1] action:@selector(maxBet)]; maxBet.titleLabel.numberOfLines = 2; maxBet.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.customizeButton = [UIButton buttonWithType:UIButtonTypeSystem]; [self.customizeButton setTitle:@"Customize symbols" forState:UIControlStateNormal]; [self.customizeButton setTitleColor:[UIColor colorWithRed:1 green:.78 blue:.18 alpha:1] forState:UIControlStateNormal]; self.customizeButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold]; [self.customizeButton addTarget:self action:@selector(customize) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[lines, perLine, maxBet]]; controls.axis = UILayoutConstraintAxisHorizontal; controls.distribution = UIStackViewDistributionFillEqually; controls.spacing = 9; controls.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:controls];
    self.spinButton = [self controlButton:@"⚡  SPIN" color:[UIColor colorWithRed:.86 green:.12 blue:.35 alpha:1] action:@selector(spin)]; self.spinButton.titleLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBlack]; self.spinButton.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.spinButton];
    self.customizeButton.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.customizeButton];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    self.machineLeadingConstraint = [machine.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:22]; self.machineTrailingConstraint = [machine.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-22];
    [NSLayoutConstraint activateConstraints:@[[title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:18], [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12], [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12], [self.balanceLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:9], [self.balanceLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor], [self.jackpotBanner.topAnchor constraintEqualToAnchor:self.balanceLabel.bottomAnchor constant:12], [self.jackpotBanner.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18], [self.jackpotBanner.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18], [self.jackpotBanner.heightAnchor constraintEqualToConstant:30], [self.jackpotBannerLabel.centerYAnchor constraintEqualToAnchor:self.jackpotBanner.centerYAnchor], [machine.topAnchor constraintEqualToAnchor:self.jackpotBanner.bottomAnchor constant:14], self.machineLeadingConstraint, self.machineTrailingConstraint, [machine.heightAnchor constraintEqualToAnchor:machine.widthAnchor multiplier:1.0], [lever.leadingAnchor constraintEqualToAnchor:machine.trailingAnchor constant:-14], [lever.centerYAnchor constraintEqualToAnchor:machine.centerYAnchor], [lever.widthAnchor constraintEqualToConstant:34], [lever.heightAnchor constraintEqualToConstant:108], [self.messageLabel.topAnchor constraintEqualToAnchor:machine.bottomAnchor constant:16], [self.messageLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20], [self.messageLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20], [self.customizeButton.topAnchor constraintEqualToAnchor:self.messageLabel.bottomAnchor constant:4], [self.customizeButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor], [controls.topAnchor constraintEqualToAnchor:self.customizeButton.bottomAnchor constant:7], [controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18], [controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18], [controls.heightAnchor constraintEqualToConstant:53], [self.spinButton.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:10], [self.spinButton.leadingAnchor constraintEqualToAnchor:controls.leadingAnchor], [self.spinButton.trailingAnchor constraintEqualToAnchor:controls.trailingAnchor], [self.spinButton.heightAnchor constraintEqualToConstant:50]]];
}

- (UIImageView *)slotView { UIImageView *v = [UIImageView new]; v.backgroundColor = [UIColor colorWithWhite:1 alpha:.96]; v.contentMode = UIViewContentModeScaleAspectFit; v.layer.cornerRadius = 8; v.clipsToBounds = YES; v.accessibilityLabel = @"slot symbol"; return v; }
- (UIButton *)controlButton:(NSString *)title color:(UIColor *)color action:(SEL)action { UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:title forState:UIControlStateNormal]; [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold]; b.backgroundColor = color; b.layer.cornerRadius = 13; [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; return b; }
- (NSInteger)currentWager { return self.activeLineCount * self.betPerLine; }
- (void)pullLever:(UIPanGestureRecognizer *)pan { CGFloat delta = [pan translationInView:self.view].y; self.leverKnobCenterY.constant = MAX(-34, MIN(34, delta)); if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) { BOOL pulled = fabs(delta) > 24; [UIView animateWithDuration:.18 animations:^{ self.leverKnobCenterY.constant = 0; [self.view layoutIfNeeded]; }]; if (pulled) [self spin]; } }
- (void)setLinesButtonTitle { [self.betButton setTitle:[NSString stringWithFormat:@"LINES\n%ld", (long)self.activeLineCount] forState:UIControlStateNormal]; self.betButton.titleLabel.numberOfLines = 2; self.betButton.titleLabel.textAlignment = NSTextAlignmentCenter; }
- (void)setPerLineButtonTitle:(UIButton *)button { [button setTitle:[NSString stringWithFormat:@"BET / LINE\n🪙 %ld", (long)self.betPerLine] forState:UIControlStateNormal]; button.titleLabel.numberOfLines = 2; button.titleLabel.textAlignment = NSTextAlignmentCenter; }

- (UIButton *)slotNavigationButtonWithTitle:(NSString *)title action:(SEL)action { UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:title forState:UIControlStateNormal]; [button setTitleColor:[UIColor colorWithRed:1 green:.79 blue:.18 alpha:1] forState:UIControlStateNormal]; button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBlack]; button.backgroundColor = [UIColor colorWithRed:.18 green:.06 blue:.29 alpha:1]; button.layer.cornerRadius = 10; button.layer.borderWidth = 1; button.layer.borderColor = [UIColor colorWithRed:1 green:.75 blue:.14 alpha:1].CGColor; button.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10); [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; button.frame = CGRectMake(0, 0, [title hasPrefix:@"‹"] ? 74 : 53, 32); return button; }
- (void)backTapped { [self.navigationController popViewControllerAnimated:YES]; }

- (void)refreshBalance { [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) { self.balanceLabel.text = [NSString stringWithFormat:@"🪙 %ld EZ Coins", (long)balance]; }]; [self refreshProgressiveJackpot]; }
- (void)refreshProgressiveJackpot { if (!EZAuthManager.shared.isLoggedIn) return; [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *error) { if (!token) return; NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/ez-slot-spin"]]]; r.HTTPMethod = @"POST"; [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; [r setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"]; [r setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"]; r.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"action": @"jackpot_status" } options:0 error:nil]; [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) { NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; dispatch_async(dispatch_get_main_queue(), ^{ id amount = json[@"progressive_jackpot"]; if ([amount isKindOfClass:NSNumber.class] && [amount integerValue] > 0) [self updateProgressiveBanner:[amount integerValue]]; }); }] resume]; }]; }
- (void)updateProgressiveBanner:(NSInteger)amount { if (amount <= 0) return; self.pendingProgressiveJackpot = amount; if (!self.progressiveBannerAnimating) { self.progressiveJackpot = amount; [self startProgressiveBannerCycle]; } }
- (void)startProgressiveBannerCycle { if (self.jackpotBanner.bounds.size.width < 2) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self startProgressiveBannerCycle]; }); return; } self.progressiveBannerAnimating = YES; if (self.pendingProgressiveJackpot > 0) self.progressiveJackpot = self.pendingProgressiveJackpot; self.jackpotBannerLabel.text = [NSString stringWithFormat:@"  PROGRESSIVE JACKPOT • MAX BET (25) ONLY • WIN UP TO %ld COINS • TRIPLE 🧠 TO CLAIM  ", (long)self.progressiveJackpot]; [self.jackpotBannerLabel sizeToFit]; self.jackpotBannerLabel.transform = CGAffineTransformIdentity; CGFloat distance = self.jackpotBanner.bounds.size.width + self.jackpotBannerLabel.bounds.size.width; self.jackpotBannerLabel.center = CGPointMake(self.jackpotBanner.bounds.size.width + self.jackpotBannerLabel.bounds.size.width / 2, 15); [self refreshProgressiveJackpot]; [UIView animateWithDuration:MAX(7, distance / 30) delay:0 options:UIViewAnimationOptionCurveLinear animations:^{ self.jackpotBannerLabel.transform = CGAffineTransformMakeTranslation(-distance, 0); } completion:^(BOOL finished) { if (!finished) return; [self startProgressiveBannerCycle]; }]; }
- (void)cycleLines { if (self.spinning) return; self.activeLineCount = self.activeLineCount % 5 + 1; [self setLinesButtonTitle]; }
- (void)cycleBetPerLine { if (self.spinning) return; self.betPerLine = self.betPerLine % 5 + 1; [self setPerLineButtonTitle:self.perLineButton]; }
- (void)maxBet { if (self.spinning) return; self.activeLineCount = 5; self.betPerLine = 5; [self setLinesButtonTitle]; [self setPerLineButtonTitle:self.perLineButton]; [self spin]; }

- (void)spin {
    if (self.spinning) return; if (!EZAuthManager.shared.isLoggedIn) { [self alert:@"Sign in required" message:@"Sign in to spin with EZ Coins."]; return; }
    // Verify the account balance before animating anything. The Edge Function
    // still enforces this atomically, but this prevents a misleading "spin"
    // animation when the selected wager cannot be placed in the first place.
    self.spinning = YES; self.spinButton.enabled = NO; self.customizeButton.enabled = NO; self.messageLabel.text = @"Checking EZ Coins…";
    NSInteger wager = self.currentWager;
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        self.balanceLabel.text = [NSString stringWithFormat:@"🪙 %ld EZ Coins", (long)balance];
        if (balance < wager) {
            self.spinning = NO; self.spinButton.enabled = YES; self.customizeButton.enabled = YES;
            self.messageLabel.text = [NSString stringWithFormat:@"Need %ld coins to place this bet • Opening Coin Store…", (long)wager];
            self.messageLabel.textColor = [UIColor systemOrangeColor];
            [self presentCoinStoreForSlotWager:wager balance:balance];
            return;
        }
        [self beginConfirmedSpinWithWager:wager];
    }];
}

/// Presented over Slots (rather than navigating away) so buying coins feels
/// like topping up the same machine. viewDidAppear refreshes the balance when
/// this sheet is dismissed.
- (void)presentCoinStoreForSlotWager:(NSInteger)wager balance:(NSInteger)balance {
    if (self.presentedViewController) return;
    EZCoinStoreViewController *store = [EZCoinStoreViewController new];
    store.showLowCoinsWarning = YES;
    store.triggeringFeatureName = [NSString stringWithFormat:@"your %ld-coin Slots bet", (long)wager];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:store];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (nav.sheetPresentationController) {
        nav.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)beginConfirmedSpinWithWager:(NSInteger)wager {
    [self stopWinCelebration];
    [self playTheme:@"brainrot-theme1"];
    self.placeholderAnimationID += 1;
    self.messageLabel.text = @"Spinning…"; self.messageLabel.textColor = [UIColor colorWithWhite:.8 alpha:1]; [self clearWinningLineHighlights]; [self animatePlaceholders];
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *authError) {
        if (!token) { [self finishWithError:@"Your sign-in session has expired."]; return; }
        NSURL *url = [NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/ez-slot-spin"]]; NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url]; r.HTTPMethod = @"POST"; r.timeoutInterval = 20; [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; [r setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"]; [r setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"]; r.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"wager": @(wager), @"lines": @(self.activeLineCount), @"bet_per_line": @(self.betPerLine) } options:0 error:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) { dispatch_async(dispatch_get_main_queue(), ^{ NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; if (error || ![json isKindOfClass:NSDictionary.class] || ![json[@"reels"] isKindOfClass:NSArray.class]) { [self finishWithError:json[@"reason"] ?: json[@"error"] ?: @"Spin could not be completed. Your balance was not changed."]; return; } [self reveal:json]; }); }] resume];
    }];
}

- (void)animatePlaceholders { NSUInteger animationID = self.placeholderAnimationID; NSArray *symbols = BRSlotSymbols(); for (NSInteger tick = 0; tick < 5; tick++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(tick * .12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!self.spinning || self.placeholderAnimationID != animationID) return; for (NSArray *col in self.reels) for (UIImageView *v in col) [self setSymbol:symbols[arc4random_uniform((u_int32_t)symbols.count)] onView:v]; }); }
- (void)reveal:(NSDictionary *)json { self.placeholderAnimationID += 1; NSArray *matrix = json[@"reels"]; if (matrix.count != 3) { [self finishWithError:@"The server returned an invalid spin."]; return; } for (NSInteger col = 0; col < 3; col++) { NSArray *column = matrix[col]; if (![column isKindOfClass:NSArray.class] || column.count != 3) { [self finishWithError:@"The server returned an invalid spin."]; return; } dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((.15 * col) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ for (NSInteger row = 0; row < 3; row++) [self setSymbol:column[row] onView:self.reels[col][row]]; }); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.58 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ NSInteger payout = [json[@"payout"] integerValue]; NSInteger balance = [json[@"balance"] integerValue]; NSInteger net = [json[@"net"] integerValue]; BOOL jackpot = [json[@"is_jackpot"] boolValue]; id progressiveAmount = json[@"progressive_jackpot"]; if ([progressiveAmount isKindOfClass:NSNumber.class] && [progressiveAmount integerValue] > 0) [self updateProgressiveBanner:[progressiveAmount integerValue]]; [self highlightWinningLines:json[@"winning_lines"]]; [EZEntitlementManager.shared applyKnownBalance:balance]; self.balanceLabel.text = [NSString stringWithFormat:@"🪙 %ld EZ Coins", (long)balance]; self.messageLabel.text = payout > 0 ? [NSString stringWithFormat:@"🎉 Won %ld coins (%+ld) on %@ line%@!", (long)payout, (long)net, json[@"win_lines"] ?: @1, [json[@"win_lines"] integerValue] == 1 ? @"" : @"s"] : [NSString stringWithFormat:@"No win • −%ld coins", (long)self.currentWager]; self.messageLabel.textColor = payout > 0 ? [UIColor colorWithRed:.3 green:1 blue:.58 alpha:1] : [UIColor colorWithWhite:.8 alpha:1]; if (payout > 0) { [self playTheme:@"brainrot-theme2"]; [self eruptCoinsForPayout:payout jackpot:jackpot]; } else { [self playLossSound]; [self playTheme:@"brainrot-theme1"]; } self.spinning = NO; self.spinButton.enabled = YES; self.customizeButton.enabled = YES; }); }

- (void)clearWinningLineHighlights { for (NSArray *column in self.reels) for (UIImageView *tile in column) { tile.layer.borderWidth = 0; tile.layer.borderColor = nil; } }
- (void)highlightWinningLines:(NSArray *)lines { [self clearWinningLineHighlights]; for (NSDictionary *line in lines) { NSArray *rows = [line[@"rows"] isKindOfClass:NSArray.class] ? line[@"rows"] : @[]; if (rows.count != 3) continue; for (NSInteger col = 0; col < 3; col++) { NSInteger row = [rows[col] integerValue]; if (row < 0 || row > 2) continue; UIImageView *tile = self.reels[col][row]; tile.layer.borderWidth = 3; tile.layer.borderColor = [UIColor colorWithRed:1 green:.77 blue:.08 alpha:1].CGColor; } } }

#pragma mark - Win celebration and audio

- (void)setupAudio {
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:&error];
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    NSURL *lossURL = [[NSBundle mainBundle] URLForResource:@"hurt-player" withExtension:@"aiff" subdirectory:@"sounds"];
    if (!lossURL) lossURL = [[NSBundle mainBundle] URLForResource:@"hurt-player" withExtension:@"aiff"];
    if (lossURL) { self.lossPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:lossURL error:nil]; self.lossPlayer.volume = .72; [self.lossPlayer prepareToPlay]; }
}

- (void)playTheme:(NSString *)name {
    if ([self.musicPlayer.url.lastPathComponent isEqualToString:[name stringByAppendingString:@".mp3"]]) return;
    NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"mp3" subdirectory:@"sounds"];
    if (!url) url = [[NSBundle mainBundle] URLForResource:name withExtension:@"mp3"];
    if (!url) return;
    [self.musicPlayer stop];
    self.musicPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil];
    self.musicPlayer.delegate = self;
    self.musicPlayer.numberOfLoops = [name isEqualToString:@"brainrot-theme2"] ? 0 : -1;
    self.musicPlayer.volume = .32; [self.musicPlayer prepareToPlay]; [self.musicPlayer play];
}

- (void)playLossSound { [self.lossPlayer stop]; self.lossPlayer.currentTime = 0; [self.lossPlayer play]; }

- (void)eruptCoinsForPayout:(NSInteger)payout jackpot:(BOOL)jackpot {
    [self stopWinCelebration];
    self.winningThemeActive = YES;
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds]; overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; overlay.backgroundColor = [UIColor colorWithRed:1 green:.7 blue:.08 alpha:.10]; overlay.userInteractionEnabled = NO; self.winOverlay = overlay; [self.view addSubview:overlay];
    CGFloat cardY = CGRectGetMinY(self.view.safeAreaLayoutGuide.layoutFrame) + 12;
    UIView *winCard = [[UIView alloc] initWithFrame:CGRectMake(28, cardY, self.view.bounds.size.width - 56, 104)]; winCard.backgroundColor = [UIColor colorWithRed:.12 green:.025 blue:.23 alpha:.94]; winCard.layer.cornerRadius = 20; winCard.layer.borderWidth = 2; winCard.layer.borderColor = [UIColor colorWithRed:1 green:.78 blue:.16 alpha:1].CGColor; winCard.layer.shadowColor = UIColor.blackColor.CGColor; winCard.layer.shadowOpacity = .65; winCard.layer.shadowRadius = 14; winCard.layer.shadowOffset = CGSizeMake(0, 7); [overlay addSubview:winCard];
    UILabel *win = [UILabel new]; win.text = [NSString stringWithFormat:@"%@\n+%ld COINS", jackpot ? @"JACKPOT!" : @"WINNER!", (long)payout]; win.numberOfLines = 2; win.textAlignment = NSTextAlignmentCenter; win.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBlack]; win.textColor = [UIColor colorWithRed:1 green:.82 blue:.12 alpha:1]; win.shadowColor = UIColor.blackColor; win.shadowOffset = CGSizeMake(2, 3); win.frame = winCard.bounds; win.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [winCard addSubview:win];
    [overlay bringSubviewToFront:winCard]; winCard.transform = CGAffineTransformMakeScale(.55, .55); winCard.alpha = 0; [UIView animateWithDuration:.25 animations:^{ winCard.alpha = 1; winCard.transform = CGAffineTransformIdentity; }];
    [self launchCoinWaveOnOverlay:overlay];
}

- (void)launchCoinWaveOnOverlay:(UIView *)overlay {
    if (!self.winningThemeActive || self.winOverlay != overlay) return;
    UIImage *coin = [UIImage imageNamed:@"EZCoin"]; CGFloat baseX = CGRectGetMidX(overlay.bounds), baseY = CGRectGetMaxY(overlay.bounds) - 55;
    for (NSInteger i = 0; i < 38; i++) { UIImageView *particle = [[UIImageView alloc] initWithImage:coin]; particle.contentMode = UIViewContentModeScaleAspectFit; particle.backgroundColor = coin ? UIColor.clearColor : [UIColor colorWithRed:1 green:.75 blue:.08 alpha:1]; particle.layer.cornerRadius = 14; particle.clipsToBounds = YES; CGFloat size = 18 + arc4random_uniform(18); particle.frame = CGRectMake(baseX - size/2, baseY, size, size); [overlay addSubview:particle]; CGFloat targetX = baseX + ((NSInteger)arc4random_uniform(340) - 170); CGFloat targetY = 55 + arc4random_uniform((uint32_t)MAX(80, overlay.bounds.size.height * .52)); CGFloat delay = (arc4random_uniform(12) / 100.0); [UIView animateKeyframesWithDuration:1.25 delay:delay options:UIViewKeyframeAnimationOptionCalculationModeCubic animations:^{ [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:.44 animations:^{ particle.center = CGPointMake(targetX, targetY); particle.transform = CGAffineTransformMakeRotation((CGFloat)(arc4random_uniform(8) * M_PI_4)); }]; [UIView addKeyframeWithRelativeStartTime:.44 relativeDuration:.56 animations:^{ particle.center = CGPointMake(targetX + ((NSInteger)arc4random_uniform(90) - 45), CGRectGetMaxY(overlay.bounds) + size); particle.alpha = 0; }]; } completion:^(BOOL finished) { [particle removeFromSuperview]; }]; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self launchCoinWaveOnOverlay:overlay]; });
}

- (void)stopWinCelebration { self.winningThemeActive = NO; [self.winOverlay.layer removeAllAnimations]; [self.winOverlay removeFromSuperview]; self.winOverlay = nil; }

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player != self.musicPlayer || !self.winningThemeActive) return;
    [self stopWinCelebration];
    [self playTheme:@"brainrot-theme1"];
}
- (void)finishWithError:(NSString *)message { self.spinning = NO; self.spinButton.enabled = YES; self.customizeButton.enabled = YES; self.messageLabel.text = message; [self refreshBalance]; }

- (void)setSymbol:(NSString *)symbol onView:(UIImageView *)view { view.accessibilityIdentifier = symbol; UIImage *custom = self.customImages[symbol]; if (custom) { [[view viewWithTag:77] removeFromSuperview]; view.image = custom; return; } view.image = nil; UILabel *old = [view viewWithTag:77]; [old removeFromSuperview]; UILabel *label = [UILabel new]; label.tag = 77; label.text = BRSlotFallbackSymbols()[symbol] ?: @"?"; label.font = [UIFont systemFontOfSize:[symbol isEqual:@"seven"] ? 52 : 38 weight:UIFontWeightBlack]; label.textColor = [symbol isEqual:@"seven"] ? [UIColor redColor] : [UIColor colorWithRed:.18 green:.1 blue:.28 alpha:1]; label.textAlignment = NSTextAlignmentCenter; label.frame = view.bounds; label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [view addSubview:label]; }

- (void)customize { BRSlotCustomizeSheetViewController *sheet = [BRSlotCustomizeSheetViewController new]; sheet.symbolImages = self.customImages; __weak typeof(self) weakSelf = self; sheet.symbolSelected = ^(NSString *symbol) { [weakSelf presentSourceOptionsForSymbol:symbol]; }; sheet.symbolReset = ^(NSString *symbol) { [weakSelf resetCustomSymbol:symbol]; }; sheet.resetSelected = ^{ typeof(self) self = weakSelf; if (!self) return; [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"BRSlotCustomImages"]; self.customImages = @{}; [self redrawSymbols]; }; [self presentViewController:sheet animated:YES completion:nil]; }
- (void)presentSourceOptionsForSymbol:(NSString *)symbol { self.pendingImageSymbol = symbol; NSString *name = [[symbol stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString]; __weak typeof(self) weakSelf = self; BRAssetSourceSheetViewController *sheet = [BRAssetSourceSheetViewController sheetForAssetDisplayName:name currentStateLabel:self.customImages[symbol] ? @"Currently using your custom image." : @"Currently using the built-in slot image." hasCustomAsset:(self.customImages[symbol] != nil) completion:^(BRAssetSourceOption option) { [weakSelf handleSourceOption:option]; }]; [self presentViewController:sheet animated:YES completion:nil]; }
- (void)handleSourceOption:(BRAssetSourceOption)option { if (option == BRAssetSourceOptionUploadPhoto) { UIImagePickerController *picker = [UIImagePickerController new]; picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary; picker.delegate = self; [self presentViewController:picker animated:YES completion:nil]; return; } if (option == BRAssetSourceOptionUploadFile) { UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage]]; picker.delegate = self; picker.allowsMultipleSelection = NO; [self presentViewController:picker animated:YES completion:nil]; return; } if (option == BRAssetSourceOptionAIPrompt) { [self presentSlotGenerationSheet]; return; } [self resetCustomSymbol:self.pendingImageSymbol]; }
- (void)resetCustomSymbol:(NSString *)symbol { NSMutableDictionary *images = [self.customImages mutableCopy]; [images removeObjectForKey:symbol]; self.customImages = images; NSMutableDictionary *stored = [NSMutableDictionary dictionary]; [images enumerateKeysAndObjectsUsingBlock:^(NSString *key, UIImage *obj, BOOL *stop) { NSData *png = UIImagePNGRepresentation(obj); if (png) stored[key] = png; }]; [[NSUserDefaults standardUserDefaults] setObject:stored forKey:@"BRSlotCustomImages"]; [self redrawSymbols]; }
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info { UIImage *image = info[UIImagePickerControllerOriginalImage]; [picker dismissViewControllerAnimated:YES completion:^{ [self applyCustomSymbolImage:image]; }]; }
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker { [picker dismissViewControllerAnimated:YES completion:nil]; }
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls { NSURL *url = urls.firstObject; BOOL accessed = [url startAccessingSecurityScopedResource]; UIImage *image = [UIImage imageWithData:[NSData dataWithContentsOfURL:url]]; if (accessed) [url stopAccessingSecurityScopedResource]; [controller dismissViewControllerAnimated:YES completion:^{ [self applyCustomSymbolImage:image]; }]; }
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { [controller dismissViewControllerAnimated:YES completion:nil]; }
- (void)applyCustomSymbolImage:(UIImage *)image { if (!image || !self.pendingImageSymbol) return; NSMutableDictionary *images = [self.customImages mutableCopy] ?: [NSMutableDictionary dictionary]; images[self.pendingImageSymbol] = image; self.customImages = images; NSMutableDictionary *stored = [NSMutableDictionary dictionary]; [images enumerateKeysAndObjectsUsingBlock:^(NSString *key, UIImage *obj, BOOL *stop) { NSData *png = UIImagePNGRepresentation(obj); if (png) stored[key] = png; }]; [[NSUserDefaults standardUserDefaults] setObject:stored forKey:@"BRSlotCustomImages"]; [self redrawSymbols]; }

- (void)presentSlotGenerationSheet { NSString *name = [[self.pendingImageSymbol stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString]; __weak typeof(self) weakSelf = self; BRAssetGenerationSheetViewController *sheet = [BRAssetGenerationSheetViewController sheetForAssetDisplayName:name costDescription:@"Each generation costs 3 EZ Coins." initialPrompt:nil initialImage:nil generateHandler:^(NSString *prompt, void (^completion)(UIImage *, NSString *)) { [weakSelf generateSlotImageForPrompt:prompt completion:completion]; } onAccept:^(UIImage *image, NSString *prompt) { [weakSelf applyCustomSymbolImage:image]; }]; [self presentViewController:sheet animated:YES completion:nil]; }
- (void)generateSlotImageForPrompt:(NSString *)prompt completion:(void (^)(UIImage *, NSString *))completion { if (!prompt.length) { completion(nil, @"Describe the slot symbol you want to create."); return; } [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *authError) { if (!token) { completion(nil, @"Please sign in to generate an image."); return; } NSURL *url = [NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/br-ai"]]; NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url]; request.HTTPMethod = @"POST"; request.timeoutInterval = 70; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"]; [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"]; request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"action": @"generate_workshop_asset", @"slot": @"player", @"prompt": [prompt stringByAppendingString:@"\nCreate a bold isolated slot-machine symbol. No text, background, floor, border, or shadow. Transparent PNG."], @"output_format": @"png", @"background": @"transparent", @"require_transparent_png": @YES } options:0 error:nil]; [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) { NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; dispatch_async(dispatch_get_main_queue(), ^{ if (networkError) { completion(nil, @"Network error — please try again."); return; } NSHTTPURLResponse *http = (NSHTTPURLResponse *)response; if (http.statusCode == 402) { completion(nil, @"Not enough EZ Coins to generate this image."); return; } NSData *png = [json[@"b64_json"] isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:json[@"b64_json"] options:0] : nil; UIImage *image = [UIImage imageWithData:png]; completion(image, image ? nil : (json[@"error"] ?: @"Image generation failed.")); }); }] resume]; }]; }
- (NSDictionary *)loadCustomImages { NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"BRSlotCustomImages"]; NSMutableDictionary *images = [NSMutableDictionary dictionary]; [stored enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSData *data, BOOL *stop) { UIImage *image = [UIImage imageWithData:data]; if (image) images[key] = image; }]; return images; }
- (void)redrawSymbols { for (NSArray *column in self.reels) for (UIImageView *v in column) [self setSymbol:v.accessibilityIdentifier ?: @"cherry" onView:v]; }
- (void)showOdds { BRSlotOddsSheetViewController *sheet = [BRSlotOddsSheetViewController new]; sheet.symbolImages = self.customImages; [self presentViewController:sheet animated:YES completion:nil]; }
- (void)alert:(NSString *)title message:(NSString *)message { UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
@end
