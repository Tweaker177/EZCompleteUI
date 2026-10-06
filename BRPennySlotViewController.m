#import "BRPennySlotViewController.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZSupabaseConfig.h"
#import "EZCoinStoreViewController.h"
#import "BRAssetSourceSheetViewController.h"
#import "BRAssetGenerationSheetViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>

static NSArray<NSString *> *PennySymbols(void) {
    return @[@"cherry", @"bar", @"double_bar", @"triple_bar", @"bell", @"diamond", @"seven", @"brain", @"ez_coin"];
}
static NSDictionary<NSString *, NSString *> *PennyGlyphs(void) {
    return @{@"cherry":@"🍒",@"bar":@"▰",@"double_bar":@"▰▰",@"triple_bar":@"▰▰▰",@"bell":@"🔔",@"diamond":@"♦︎",@"seven":@"7",@"brain":@"🧠"};
}
static NSArray<NSNumber *> *PennyBets(void) { return @[@1,@5,@10,@15,@25]; }
static UIImage *PennyEZCoinSymbolImage(void) {
    static UIImage *scaled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIImage *coin = [UIImage imageNamed:@"EZCoin"];
        if (!coin) return;
        CGSize canvas = CGSizeMake(180, 180);
        UIGraphicsBeginImageContextWithOptions(canvas, NO, 0);
        CGFloat side = 116; // Keeps the scatter visually level with the other symbols.
        [coin drawInRect:CGRectMake((canvas.width-side)/2.0, (canvas.height-side)/2.0, side, side)];
        scaled = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return scaled;
}

@interface BRPennySlotCustomizeSheetViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSDictionary<NSString *, UIImage *> *symbolImages;
@property (nonatomic, copy) void (^symbolSelected)(NSString *symbol);
@property (nonatomic, copy) void (^symbolReset)(NSString *symbol);
@property (nonatomic, copy) dispatch_block_t resetAll;
@end

@implementation BRPennySlotCustomizeSheetViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:.07 green:.03 blue:.16 alpha:1];
    self.modalPresentationStyle = UIModalPresentationPageSheet;
    self.sheetPresentationController.prefersGrabberVisible = YES;
    self.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
    UILabel *title = [UILabel new]; title.text = @"Customize Penny Slots"; title.textColor = UIColor.whiteColor; title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBlack]; title.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:title];
    UILabel *subtitle = [UILabel new]; subtitle.text = @"Tap a symbol to choose a photo, file, or generated image. The current art is shown here."; subtitle.textColor = [UIColor colorWithWhite:.67 alpha:1]; subtitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]; subtitle.numberOfLines = 2; subtitle.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:subtitle];
    UITableView *table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; table.backgroundColor = UIColor.clearColor; table.dataSource = self; table.delegate = self; table.rowHeight = 64; table.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:table];
    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem]; [reset setTitle:@"↺  Reset all artwork" forState:UIControlStateNormal]; [reset setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal]; reset.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold]; reset.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:.12]; reset.layer.cornerRadius = 12; [reset addTarget:self action:@selector(resetAllTapped) forControlEvents:UIControlEventTouchUpInside]; reset.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:reset];
    [NSLayoutConstraint activateConstraints:@[[title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:17], [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22], [title.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22], [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:5], [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [subtitle.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [table.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:8], [table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [table.bottomAnchor constraintEqualToAnchor:reset.topAnchor constant:-8], [reset.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [reset.trailingAnchor constraintEqualToAnchor:subtitle.trailingAnchor], [reset.heightAnchor constraintEqualToConstant:46], [reset.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-14]]];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return PennySymbols().count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]; NSString *symbol = PennySymbols()[path.row]; UIImage *image = self.symbolImages[symbol];
    cell.backgroundColor = [UIColor colorWithWhite:1 alpha:.055]; cell.textLabel.text = [[symbol stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString]; cell.textLabel.textColor = UIColor.whiteColor; cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold]; cell.detailTextLabel.text = image ? @"Custom image • tap to change" : @"Built-in image • tap to customize"; cell.detailTextLabel.textColor = [UIColor colorWithWhite:.62 alpha:1]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.imageView.backgroundColor = UIColor.whiteColor; cell.imageView.layer.cornerRadius = 7; cell.imageView.clipsToBounds = YES; cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
    if (image) cell.imageView.image = image; else if ([symbol isEqualToString:@"ez_coin"]) cell.imageView.image = [UIImage imageNamed:@"EZCoin"]; else { UIGraphicsBeginImageContextWithOptions(CGSizeMake(36,36), NO, 0); [PennyGlyphs()[symbol] drawInRect:CGRectMake(0,0,36,36) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:25]}]; cell.imageView.image=UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext(); }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path { [tableView deselectRowAtIndexPath:path animated:YES]; NSString *symbol=PennySymbols()[path.row]; [self dismissViewControllerAnimated:YES completion:^{ if (self.symbolSelected) self.symbolSelected(symbol); }]; }
- (void)resetAllTapped { [self dismissViewControllerAnimated:YES completion:^{ if (self.resetAll) self.resetAll(); }]; }
@end

@interface BRPennySlotViewController () <AVAudioPlayerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) NSMutableArray<NSArray<UIImageView *> *> *reels;
@property (nonatomic, strong) UILabel *balanceLabel, *bonusLabel, *messageLabel;
@property (nonatomic, strong) UIButton *linesButton, *betButton, *spinButton, *maxButton;
@property (nonatomic, strong) UIButton *customizeButton;
@property (nonatomic, strong) AVAudioPlayer *musicPlayer, *lossPlayer;
@property (nonatomic, strong) UIView *winOverlay;
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *preSpinBoard;
@property (nonatomic, copy) NSString *pendingImageSymbol;
@property (nonatomic, copy) NSDictionary<NSString *, UIImage *> *customImages;
@property (nonatomic) NSInteger lines, betIndex, freeSpinsRemaining;
@property (nonatomic) BOOL spinning, celebrating;
@property (nonatomic) NSUInteger animationID;
@end

@implementation BRPennySlotViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Penny Slots";
    self.view.backgroundColor = [UIColor colorWithRed:.045 green:.02 blue:.10 alpha:1];
    self.lines = 9; self.betIndex = 0;
    self.customImages = [self loadCustomImages];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:[self navButton:@"‹  BACK" action:@selector(backTapped)]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:[self navButton:@"ODDS" action:@selector(showOdds)]];
    [self buildUI]; [self setupAudio]; [self refreshState];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self refreshState]; if (!self.musicPlayer.isPlaying) [self playTheme:@"brainrot-theme1"]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; if (self.isMovingFromParentViewController) [self.musicPlayer stop]; }
- (void)backTapped { [self.navigationController popViewControllerAnimated:YES]; }

- (UIButton *)navButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithRed:1 green:.8 blue:.2 alpha:1] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBlack];
    button.backgroundColor = [UIColor colorWithRed:.18 green:.06 blue:.29 alpha:1];
    button.layer.cornerRadius = 10; button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithRed:1 green:.75 blue:.14 alpha:1].CGColor;
    button.frame = CGRectMake(0,0,[title hasPrefix:@"‹"] ? 74 : 53,32);
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
    UILabel *title = [UILabel new]; title.text = @"🪙  PENNY SLOTS  🪙"; title.font = [UIFont systemFontOfSize:23 weight:UIFontWeightBlack]; title.textColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1]; title.textAlignment = NSTextAlignmentCenter;
    self.balanceLabel = [UILabel new]; self.balanceLabel.text = @"🪙 — EZ Coins"; self.balanceLabel.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightBold]; self.balanceLabel.textColor = UIColor.whiteColor; self.balanceLabel.textAlignment = NSTextAlignmentCenter;
    self.bonusLabel = [UILabel new]; self.bonusLabel.text = @"3 EZCoins = 5 FREE SPINS • 4 = 15 • 5+ = 25"; self.bonusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold]; self.bonusLabel.textColor = [UIColor colorWithRed:1 green:.83 blue:.3 alpha:1]; self.bonusLabel.textAlignment = NSTextAlignmentCenter; self.bonusLabel.numberOfLines = 2; self.bonusLabel.backgroundColor = [UIColor colorWithRed:.4 green:.09 blue:.3 alpha:1]; self.bonusLabel.layer.cornerRadius = 10; self.bonusLabel.clipsToBounds = YES;
    UIView *machine = [UIView new]; machine.backgroundColor = [UIColor colorWithRed:.29 green:.08 blue:.42 alpha:1]; machine.layer.cornerRadius = 21; machine.layer.borderWidth = 3; machine.layer.borderColor = [UIColor colorWithRed:1 green:.71 blue:.12 alpha:1].CGColor;
    UIStackView *columns = [UIStackView new]; columns.axis = UILayoutConstraintAxisHorizontal; columns.distribution = UIStackViewDistributionFillEqually; columns.spacing = 5;
    self.reels = [NSMutableArray array];
    for (NSInteger col=0; col<5; col++) {
        UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical; stack.distribution = UIStackViewDistributionFillEqually; stack.spacing = 5;
        NSMutableArray *tiles = [NSMutableArray array];
        for (NSInteger row=0; row<3; row++) { UIImageView *tile = [UIImageView new]; tile.backgroundColor = UIColor.whiteColor; tile.layer.cornerRadius = 6; tile.clipsToBounds = YES; [self setSymbol:PennySymbols()[(col*3+row)%PennySymbols().count] onTile:tile]; [stack addArrangedSubview:tile]; [tiles addObject:tile]; }
        [self.reels addObject:tiles]; [columns addArrangedSubview:stack];
    }
    columns.translatesAutoresizingMaskIntoConstraints = NO; [machine addSubview:columns];
    self.messageLabel = [UILabel new]; self.messageLabel.text = @"9 paylines • 2× payouts during free spins"; self.messageLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]; self.messageLabel.textColor = [UIColor colorWithWhite:.85 alpha:1]; self.messageLabel.textAlignment = NSTextAlignmentCenter; self.messageLabel.numberOfLines = 2;
    self.customizeButton = [UIButton buttonWithType:UIButtonTypeSystem]; [self.customizeButton setTitle:@"Customize symbols" forState:UIControlStateNormal]; [self.customizeButton setTitleColor:[UIColor colorWithRed:1 green:.78 blue:.18 alpha:1] forState:UIControlStateNormal]; self.customizeButton.titleLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightBold]; [self.customizeButton addTarget:self action:@selector(customize) forControlEvents:UIControlEventTouchUpInside];
    self.linesButton = [self control:@"LINES\n9" color:UIColor.systemIndigoColor action:@selector(cycleLines)];
    self.betButton = [self control:@"BET / LINE\n🪙 1" color:[UIColor colorWithRed:.08 green:.54 blue:.62 alpha:1] action:@selector(cycleBet)];
    self.maxButton = [self control:@"MAX BET\n⚡ 225" color:[UIColor colorWithRed:.53 green:.18 blue:.72 alpha:1] action:@selector(maxBet)];
    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[self.linesButton,self.betButton,self.maxButton]]; controls.axis = UILayoutConstraintAxisHorizontal; controls.distribution = UIStackViewDistributionFillEqually; controls.spacing = 8;
    self.spinButton = [self control:@"⚡  SPIN" color:[UIColor colorWithRed:.86 green:.12 blue:.35 alpha:1] action:@selector(spin)]; self.spinButton.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBlack];
    for (UIView *view in @[title,self.balanceLabel,self.bonusLabel,machine,self.messageLabel,self.customizeButton,controls,self.spinButton]) { view.translatesAutoresizingMaskIntoConstraints = NO; [content addSubview:view]; }
    [NSLayoutConstraint activateConstraints:@[
      [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
      [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor], [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor], [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor], [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor], [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
      [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:12], [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12], [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-12],
      [self.balanceLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8], [self.balanceLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
      [self.bonusLabel.topAnchor constraintEqualToAnchor:self.balanceLabel.bottomAnchor constant:10], [self.bonusLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16], [self.bonusLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16], [self.bonusLabel.heightAnchor constraintEqualToConstant:38],
      [machine.topAnchor constraintEqualToAnchor:self.bonusLabel.bottomAnchor constant:12], [machine.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16], [machine.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16], [machine.heightAnchor constraintEqualToAnchor:machine.widthAnchor multiplier:.67],
      [columns.topAnchor constraintEqualToAnchor:machine.topAnchor constant:12], [columns.bottomAnchor constraintEqualToAnchor:machine.bottomAnchor constant:-12], [columns.leadingAnchor constraintEqualToAnchor:machine.leadingAnchor constant:12], [columns.trailingAnchor constraintEqualToAnchor:machine.trailingAnchor constant:-12],
      [self.messageLabel.topAnchor constraintEqualToAnchor:machine.bottomAnchor constant:12], [self.messageLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16], [self.messageLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16], [self.messageLabel.heightAnchor constraintGreaterThanOrEqualToConstant:38],
      [self.customizeButton.topAnchor constraintEqualToAnchor:self.messageLabel.bottomAnchor constant:2], [self.customizeButton.centerXAnchor constraintEqualToAnchor:content.centerXAnchor], [self.customizeButton.heightAnchor constraintEqualToConstant:31],
      [controls.topAnchor constraintEqualToAnchor:self.customizeButton.bottomAnchor constant:6], [controls.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16], [controls.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16], [controls.heightAnchor constraintEqualToConstant:54],
      [self.spinButton.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:9], [self.spinButton.leadingAnchor constraintEqualToAnchor:controls.leadingAnchor], [self.spinButton.trailingAnchor constraintEqualToAnchor:controls.trailingAnchor], [self.spinButton.heightAnchor constraintEqualToConstant:50], [self.spinButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16]
    ]];
}
- (void)setSymbol:(NSString *)symbol onTile:(UIImageView *)tile {
    tile.accessibilityIdentifier = symbol;
    [[tile viewWithTag:77] removeFromSuperview]; tile.image = nil;
    UIImage *custom = self.customImages[symbol];
    if (custom) { tile.image = custom; tile.contentMode = UIViewContentModeScaleAspectFill; return; }
    if ([symbol isEqualToString:@"ez_coin"]) { tile.image = PennyEZCoinSymbolImage(); tile.contentMode = UIViewContentModeScaleAspectFit; return; }
    UILabel *glyph = [UILabel new]; glyph.tag = 77; glyph.text = PennyGlyphs()[symbol] ?: @"?";
    glyph.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBlack]; glyph.textColor = [UIColor colorWithRed:.20 green:.07 blue:.28 alpha:1];
    glyph.textAlignment = NSTextAlignmentCenter; glyph.frame = tile.bounds; glyph.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; [tile addSubview:glyph];
}
- (NSInteger)betPerLine { return PennyBets()[self.betIndex].integerValue; }
- (void)cycleLines { if (self.spinning || self.freeSpinsRemaining) return; self.lines = self.lines%9+1; [self.linesButton setTitle:[NSString stringWithFormat:@"LINES\n%ld",(long)self.lines] forState:UIControlStateNormal]; }
- (void)cycleBet { if (self.spinning || self.freeSpinsRemaining) return; self.betIndex = (self.betIndex+1)%PennyBets().count; [self.betButton setTitle:[NSString stringWithFormat:@"BET / LINE\n🪙 %ld",(long)self.betPerLine] forState:UIControlStateNormal]; }
- (void)maxBet { if (self.spinning) return; if (self.freeSpinsRemaining == 0) { self.lines=9; self.betIndex=PennyBets().count-1; [self.linesButton setTitle:@"LINES\n9" forState:UIControlStateNormal]; [self.betButton setTitle:@"BET / LINE\n🪙 25" forState:UIControlStateNormal]; } [self spin]; }

- (void)customize {
    if (self.spinning) return;
    BRPennySlotCustomizeSheetViewController *sheet = [BRPennySlotCustomizeSheetViewController new]; sheet.symbolImages = self.customImages;
    __weak typeof(self) weakSelf = self;
    sheet.symbolSelected = ^(NSString *symbol) { [weakSelf presentSourceOptionsForSymbol:symbol]; };
    sheet.resetAll = ^{ __strong typeof(weakSelf) self = weakSelf; if (!self) return; self.customImages = @{}; [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"BRPennySlotCustomImages"]; [self redrawSymbols]; };
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)presentSourceOptionsForSymbol:(NSString *)symbol {
    self.pendingImageSymbol = symbol;
    NSString *name = [[symbol stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString];
    __weak typeof(self) weakSelf = self;
    BRAssetSourceSheetViewController *sheet = [BRAssetSourceSheetViewController sheetForAssetDisplayName:name currentStateLabel:self.customImages[symbol] ? @"Currently using your custom image." : @"Currently using the built-in Penny Slots image." hasCustomAsset:(self.customImages[symbol] != nil) completion:^(BRAssetSourceOption option) { [weakSelf handleSourceOption:option]; }];
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)handleSourceOption:(BRAssetSourceOption)option {
    if (option == BRAssetSourceOptionUploadPhoto) { UIImagePickerController *picker = [UIImagePickerController new]; picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary; picker.delegate = self; [self presentViewController:picker animated:YES completion:nil]; return; }
    if (option == BRAssetSourceOptionUploadFile) { UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage]]; picker.delegate = self; picker.allowsMultipleSelection = NO; [self presentViewController:picker animated:YES completion:nil]; return; }
    if (option == BRAssetSourceOptionAIPrompt) { [self presentGenerationSheet]; return; }
    [self resetCustomSymbol:self.pendingImageSymbol];
}
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info { UIImage *image=info[UIImagePickerControllerOriginalImage]; [picker dismissViewControllerAnimated:YES completion:^{ [self applyCustomSymbolImage:image]; }]; }
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker { [picker dismissViewControllerAnimated:YES completion:nil]; }
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls { NSURL *url=urls.firstObject; BOOL accessed=[url startAccessingSecurityScopedResource]; UIImage *image=[UIImage imageWithData:[NSData dataWithContentsOfURL:url]]; if (accessed) [url stopAccessingSecurityScopedResource]; [controller dismissViewControllerAnimated:YES completion:^{ [self applyCustomSymbolImage:image]; }]; }
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { [controller dismissViewControllerAnimated:YES completion:nil]; }
- (void)applyCustomSymbolImage:(UIImage *)image { if (!image || !self.pendingImageSymbol) return; NSMutableDictionary *images=[self.customImages mutableCopy] ?: [NSMutableDictionary dictionary]; images[self.pendingImageSymbol]=image; self.customImages=images; [self saveCustomImages]; [self redrawSymbols]; }
- (void)resetCustomSymbol:(NSString *)symbol { if (!symbol.length) return; NSMutableDictionary *images=[self.customImages mutableCopy] ?: [NSMutableDictionary dictionary]; [images removeObjectForKey:symbol]; self.customImages=images; [self saveCustomImages]; [self redrawSymbols]; }
- (void)saveCustomImages { NSMutableDictionary *stored=[NSMutableDictionary dictionary]; [self.customImages enumerateKeysAndObjectsUsingBlock:^(NSString *key, UIImage *image, BOOL *stop) { NSData *png=UIImagePNGRepresentation(image); if (png) stored[key]=png; }]; [[NSUserDefaults standardUserDefaults] setObject:stored forKey:@"BRPennySlotCustomImages"]; }
- (NSDictionary<NSString *, UIImage *> *)loadCustomImages { NSDictionary *stored=[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"BRPennySlotCustomImages"]; NSMutableDictionary *images=[NSMutableDictionary dictionary]; [stored enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSData *data, BOOL *stop) { UIImage *image=[UIImage imageWithData:data]; if (image) images[key]=image; }]; return images; }
- (void)redrawSymbols { for (NSArray<UIImageView *> *column in self.reels) for (UIImageView *tile in column) [self setSymbol:tile.accessibilityIdentifier ?: @"cherry" onTile:tile]; }
- (void)presentGenerationSheet { NSString *name=[[self.pendingImageSymbol stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString]; __weak typeof(self) weakSelf=self; BRAssetGenerationSheetViewController *sheet=[BRAssetGenerationSheetViewController sheetForAssetDisplayName:name costDescription:@"Each generation costs 3 EZ Coins." initialPrompt:nil initialImage:nil generateHandler:^(NSString *prompt, void (^completion)(UIImage *, NSString *)) { [weakSelf generateImageForPrompt:prompt completion:completion]; } onAccept:^(UIImage *image, NSString *prompt) { [weakSelf applyCustomSymbolImage:image]; }]; [self presentViewController:sheet animated:YES completion:nil]; }
- (void)generateImageForPrompt:(NSString *)prompt completion:(void (^)(UIImage *, NSString *))completion { if (!prompt.length) { completion(nil,@"Describe the symbol you want to create."); return; } [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *authError) { if (!token) { completion(nil,@"Please sign in to generate an image."); return; } NSURL *url=[NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/br-ai"]]; NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url]; request.HTTPMethod=@"POST"; request.timeoutInterval=70; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"]; [request setValue:[NSString stringWithFormat:@"Bearer %@",token] forHTTPHeaderField:@"Authorization"]; request.HTTPBody=[NSJSONSerialization dataWithJSONObject:@{ @"action":@"generate_workshop_asset", @"slot":@"player", @"prompt":[prompt stringByAppendingString:@"\nCreate a bold isolated five-reel slot-machine symbol. No text, background, floor, border, or shadow. Transparent PNG."], @"output_format":@"png", @"background":@"transparent", @"require_transparent_png":@YES } options:0 error:nil]; [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) { NSDictionary *json=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; dispatch_async(dispatch_get_main_queue(), ^{ if (networkError) { completion(nil,@"Network error — please try again."); return; } NSHTTPURLResponse *http=(NSHTTPURLResponse *)response; if (http.statusCode==402) { completion(nil,@"Not enough EZ Coins to generate this image."); return; } NSData *png=[json[@"b64_json"] isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:json[@"b64_json"] options:0] : nil; UIImage *image=[UIImage imageWithData:png]; completion(image,image ? nil : (json[@"error"] ?: @"Image generation failed.")); }); }] resume]; }]; }

- (void)refreshState {
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) { if (!self.spinning) self.balanceLabel.text = [NSString stringWithFormat:@"🪙 %ld EZ Coins",(long)balance]; }];
    [self request:@{@"action":@"status"} completion:^(NSDictionary *result, NSString *error) {
        if (self.spinning) return;
        if (error) { self.messageLabel.text = error; return; }
        self.freeSpinsRemaining = [result[@"free_spins_remaining"] integerValue];
        if (self.freeSpinsRemaining > 0) {
            self.lines = [result[@"lines"] integerValue]; NSInteger found = [PennyBets() indexOfObject:result[@"bet_per_line"]]; if (found != NSNotFound) self.betIndex = found;
            [self.linesButton setTitle:[NSString stringWithFormat:@"LINES\n%ld",(long)self.lines] forState:UIControlStateNormal];
            [self.betButton setTitle:[NSString stringWithFormat:@"BET / LINE\n🪙 %ld",(long)self.betPerLine] forState:UIControlStateNormal];
        }
        [self updateBonusLabel];
    }];
}
- (void)updateBonusLabel { self.bonusLabel.text = self.freeSpinsRemaining > 0 ? [NSString stringWithFormat:@"⚡ %ld FREE SPINS LEFT • ALL WINS 2×",(long)self.freeSpinsRemaining] : @"3 EZCoins = 5 FREE SPINS • 4 = 15 • 5+ = 25"; self.linesButton.enabled = self.betButton.enabled = self.freeSpinsRemaining == 0 && !self.spinning; }
- (void)request:(NSDictionary *)payload completion:(void (^)(NSDictionary *, NSString *))completion {
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *authError) {
        if (!token) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,@"Sign in to play Penny Slots."); }); return; }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/ez-penny-slot-spin"]]];
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
    if (self.spinning) return;
    self.spinning = YES; self.spinButton.enabled = self.maxButton.enabled = self.customizeButton.enabled = NO; [self updateBonusLabel];
    [self.winOverlay removeFromSuperview]; self.winOverlay=nil; self.celebrating=NO; [self playTheme:@"brainrot-theme1"];
    for (NSArray<UIImageView *> *column in self.reels) for (UIImageView *tile in column) tile.layer.borderWidth = 0;
    self.messageLabel.text = self.freeSpinsRemaining ? @"Free spin…" : @"Checking EZ Coins…";
    if (self.freeSpinsRemaining > 0) { [self beginSpin]; return; }
    NSInteger wager = self.lines*self.betPerLine;
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        self.balanceLabel.text = [NSString stringWithFormat:@"🪙 %ld EZ Coins",(long)balance];
        if (balance < wager) { [self finishWithError:[NSString stringWithFormat:@"Need %ld coins for this spin.",(long)wager]]; [self showCoinStore]; return; }
        [self beginSpin];
    }];
}
- (void)beginSpin {
    self.messageLabel.text = @"Spinning…"; NSUInteger animationID = ++self.animationID;
    NSMutableArray *before = [NSMutableArray arrayWithCapacity:5];
    for (NSArray<UIImageView *> *column in self.reels) { NSMutableArray *symbols = [NSMutableArray arrayWithCapacity:3]; for (UIImageView *tile in column) [symbols addObject:tile.accessibilityIdentifier ?: @"cherry"]; [before addObject:symbols]; }
    self.preSpinBoard = before;
    for (NSInteger tick=0;tick<5;tick++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(tick*.11*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ if (!self.spinning || self.animationID != animationID) return; for (NSArray *col in self.reels) for (UIImageView *tile in col) [self setSymbol:PennySymbols()[arc4random_uniform((uint32_t)PennySymbols().count)] onTile:tile]; });
    [self request:@{@"lines":@(self.lines),@"bet_per_line":@(self.betPerLine)} completion:^(NSDictionary *result, NSString *error) {
        if (error || ![result[@"reels"] isKindOfClass:NSArray.class]) { [self finishWithError:error ?: @"Spin failed; balance unchanged."]; [self refreshState]; if ([error.localizedLowercaseString containsString:@"insufficient"]) [self showCoinStore]; return; }
        [self reveal:result];
    }];
}
- (void)reveal:(NSDictionary *)result {
    NSArray *columns = result[@"reels"];
    if (columns.count != 5) { [self finishWithError:@"Invalid spin result."]; return; }
    for (NSArray *column in columns) if (![column isKindOfClass:NSArray.class] || column.count != 3) { [self finishWithError:@"Invalid spin result."]; return; }
    self.preSpinBoard = nil;
    ++self.animationID;
    for (NSInteger col=0;col<5;col++) {
        NSArray *symbols=columns[col];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(col*.10*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ for (NSInteger row=0;row<3;row++) [self setSymbol:symbols[row] onTile:self.reels[col][row]]; });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.56*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        NSInteger payout=[result[@"payout"] integerValue],balance=[result[@"balance"] integerValue],awarded=[result[@"free_spins_awarded"] integerValue];
        self.freeSpinsRemaining=[result[@"free_spins_remaining"] integerValue]; [self updateBonusLabel];
        [EZEntitlementManager.shared applyKnownBalance:balance]; self.balanceLabel.text=[NSString stringWithFormat:@"🪙 %ld EZ Coins",(long)balance];
        for (NSArray *col in self.reels) for (UIImageView *tile in col) tile.layer.borderWidth=0;
        for (NSDictionary *line in result[@"winning_lines"]) for (NSInteger col=0;col<[line[@"matches"] integerValue] && col<5;col++) { NSInteger row=[line[@"rows"][col] integerValue]; if (row>=0 && row<3) { UIImageView *tile=self.reels[col][row]; tile.layer.borderWidth=3; tile.layer.borderColor=UIColor.systemYellowColor.CGColor; } }
        self.messageLabel.text = awarded ? [NSString stringWithFormat:@"⚡ +%ld FREE SPINS! %@",(long)awarded,payout ? [NSString stringWithFormat:@"Won %ld coins",(long)payout] : @""] : payout ? [NSString stringWithFormat:@"🎉 Won %ld coins on %@ line%@",(long)payout,result[@"win_lines"],[result[@"win_lines"] integerValue]==1?@"":@"s"] : [result[@"was_free_spin"] boolValue] ? @"Free spin • no line win" : [NSString stringWithFormat:@"No win • −%@ coins",result[@"wager"]];
        self.messageLabel.textColor=(payout || awarded) ? UIColor.systemYellowColor : [UIColor colorWithWhite:.8 alpha:1];
        if (payout || awarded) { [self playTheme:@"brainrot-theme2"]; [self showWin:payout awarded:awarded]; } else { [self.lossPlayer stop]; self.lossPlayer.currentTime=0; [self.lossPlayer play]; [self playTheme:@"brainrot-theme1"]; }
        self.spinning=NO; self.spinButton.enabled=self.maxButton.enabled=self.customizeButton.enabled=YES; [self updateBonusLabel];
        if (balance==0 && self.freeSpinsRemaining==0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self showCoinStore]; });
    });
}
- (void)finishWithError:(NSString *)message { ++self.animationID; if (self.preSpinBoard.count == 5) { for (NSInteger col=0;col<5;col++) for (NSInteger row=0;row<3;row++) [self setSymbol:self.preSpinBoard[col][row] onTile:self.reels[col][row]]; self.preSpinBoard=nil; } self.spinning=NO; self.spinButton.enabled=self.maxButton.enabled=self.customizeButton.enabled=YES; [self updateBonusLabel]; self.messageLabel.text=message; self.messageLabel.textColor=UIColor.systemOrangeColor; }
- (void)showCoinStore {
    if (self.presentedViewController) return;
    EZCoinStoreViewController *store=[EZCoinStoreViewController new]; store.showLowCoinsWarning=YES; store.triggeringFeatureName=@"Penny Slots — suggested re-up: 400 coins";
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:store]; nav.modalPresentationStyle=UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)setupAudio { [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil]; NSURL *url=[[NSBundle mainBundle] URLForResource:@"hurt-player" withExtension:@"aiff" subdirectory:@"sounds"]; if (!url) url=[[NSBundle mainBundle] URLForResource:@"hurt-player" withExtension:@"aiff"]; if (url) { self.lossPlayer=[[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil]; self.lossPlayer.volume=.7; [self.lossPlayer prepareToPlay]; } }
- (void)playTheme:(NSString *)name { if ([self.musicPlayer.url.lastPathComponent isEqualToString:[name stringByAppendingString:@".mp3"]]) { if (!self.musicPlayer.isPlaying) [self.musicPlayer play]; return; } NSURL *url=[[NSBundle mainBundle] URLForResource:name withExtension:@"mp3" subdirectory:@"sounds"]; if (!url) url=[[NSBundle mainBundle] URLForResource:name withExtension:@"mp3"]; if (!url) return; [self.musicPlayer stop]; self.musicPlayer=[[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil]; self.musicPlayer.delegate=self; self.musicPlayer.numberOfLoops=[name isEqualToString:@"brainrot-theme2"]?0:-1; self.musicPlayer.volume=.32; [self.musicPlayer prepareToPlay]; [self.musicPlayer play]; }
- (void)showWin:(NSInteger)payout awarded:(NSInteger)awarded {
    UIView *overlay=[[UIView alloc] initWithFrame:self.view.bounds]; overlay.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; overlay.userInteractionEnabled=NO; self.winOverlay=overlay; self.celebrating=YES; [self.view addSubview:overlay];
    UIView *card=[[UIView alloc] initWithFrame:CGRectMake(22,CGRectGetMinY(self.view.safeAreaLayoutGuide.layoutFrame)+8,self.view.bounds.size.width-44,82)]; card.backgroundColor=[UIColor colorWithRed:.12 green:.025 blue:.23 alpha:.96]; card.layer.cornerRadius=18; card.layer.borderWidth=2; card.layer.borderColor=UIColor.systemYellowColor.CGColor; [overlay addSubview:card];
    UILabel *text=[UILabel new]; text.text=awarded ? [NSString stringWithFormat:@"⚡ %ld FREE SPINS%@",(long)awarded,payout?[NSString stringWithFormat:@"  +%ld COINS",(long)payout]:@""] : [NSString stringWithFormat:@"WINNER!  +%ld COINS",(long)payout]; text.numberOfLines=2; text.font=[UIFont systemFontOfSize:21 weight:UIFontWeightBlack]; text.textColor=UIColor.systemYellowColor; text.textAlignment=NSTextAlignmentCenter; text.frame=card.bounds; text.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; [card addSubview:text];
    [self coinWave:overlay];
}
- (void)coinWave:(UIView *)overlay { if (!self.celebrating || overlay!=self.winOverlay) return; UIImage *coin=[UIImage imageNamed:@"EZCoin"]; CGFloat baseX=CGRectGetMidX(overlay.bounds),bottom=CGRectGetMaxY(overlay.bounds)-40; for (NSInteger i=0;i<24;i++) { UIImageView *particle=[[UIImageView alloc] initWithImage:coin]; particle.frame=CGRectMake(baseX,bottom,20,20); [overlay insertSubview:particle atIndex:0]; CGFloat x=baseX+(NSInteger)arc4random_uniform(300)-150,y=100+arc4random_uniform(250); [UIView animateWithDuration:1.1 delay:arc4random_uniform(12)/100.0 options:0 animations:^{ particle.center=CGPointMake(x,y); particle.alpha=0; } completion:^(__unused BOOL done){ [particle removeFromSuperview]; }]; } dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.05*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self coinWave:overlay]; }); }
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag { if (player!=self.musicPlayer || !self.celebrating) return; self.celebrating=NO; [self.winOverlay removeFromSuperview]; self.winOverlay=nil; [self playTheme:@"brainrot-theme1"]; }
- (void)showOdds {
    UIViewController *sheet=[UIViewController new]; sheet.view.backgroundColor=[UIColor colorWithRed:.07 green:.03 blue:.16 alpha:1]; sheet.modalPresentationStyle=UIModalPresentationPageSheet; sheet.sheetPresentationController.prefersGrabberVisible=YES; sheet.sheetPresentationController.detents=@[[UISheetPresentationControllerDetent mediumDetent],[UISheetPresentationControllerDetent largeDetent]];
    UITextView *text=[UITextView new]; text.editable=NO; text.selectable=NO; text.backgroundColor=UIColor.clearColor; text.textColor=UIColor.whiteColor; text.font=[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium]; text.textContainerInset=UIEdgeInsetsMake(24,18,28,18); text.translatesAutoresizingMaskIntoConstraints=NO; [sheet.view addSubview:text];
    text.text=@"PENNY SLOTS PAYOUTS\n\n3, 4, or 5 consecutive symbols from the left on an active line pay per coin bet on that line:\n\n🍒 Cherry       8× / 19× / 55×\n▰ Bar          12× / 34× / 110×\n▰▰ Double Bar  19× / 55× / 172×\n▰▰▰ Triple Bar 27× / 80× / 258×\n🔔 Bell        43× / 123× / 430×\n♦ Diamond     74× / 221× / 738×\n7 Seven      154× / 492× / 1476×\n🧠 Brain      308× / 923× / 3075×\n\n🪙 EZCoin is a scatter anywhere on the board: exactly 3 = 5 free spins, exactly 4 = 15, 5 or more = 25. Free spins keep your active lines and bet; every line win pays 2×. Scatters during free spins add more. Theoretical long-run RTP is about 92%; results vary.";
    [NSLayoutConstraint activateConstraints:@[[text.topAnchor constraintEqualToAnchor:sheet.view.safeAreaLayoutGuide.topAnchor],[text.leadingAnchor constraintEqualToAnchor:sheet.view.leadingAnchor],[text.trailingAnchor constraintEqualToAnchor:sheet.view.trailingAnchor],[text.bottomAnchor constraintEqualToAnchor:sheet.view.safeAreaLayoutGuide.bottomAnchor]]];
    [self presentViewController:sheet animated:YES completion:nil];
}
@end
