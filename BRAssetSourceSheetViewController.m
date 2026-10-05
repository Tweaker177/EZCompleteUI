// BRAssetSourceSheetViewController.m
// BrainRotGame
// EZCompleteUI v1.0 — Reusable Asset Source Bottom Sheet
//
// Purpose:
//   Implementation of BRAssetSourceSheetViewController. See the header for
//   the public contract. The sheet is just a header (title + current-state
//   description) above a 3-row inset-grouped table view, one row per
//   BRAssetSourceOption.

#import "BRAssetSourceSheetViewController.h"

/// Static description of a single row so the table view data source and
/// row-tap handler stay in sync without duplicating strings.
@interface BRAssetSourceRowInfo : NSObject
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, assign) BRAssetSourceOption option;
@property (nonatomic, assign) BOOL isDestructive;
@end

@implementation BRAssetSourceRowInfo
@end

@interface BRAssetSourceSheetViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, copy) NSString *assetDisplayName;
@property (nonatomic, copy) NSString *currentStateLabel;
@property (nonatomic, assign) BOOL hasCustomAsset;
@property (nonatomic, copy) BRAssetSourceSheetCompletion completion;

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<BRAssetSourceRowInfo *> *rows;

@end

@implementation BRAssetSourceSheetViewController

#pragma mark - Factory

+ (instancetype)sheetForAssetDisplayName:(NSString *)displayName
                        currentStateLabel:(NSString *)currentStateLabel
                           hasCustomAsset:(BOOL)hasCustomAsset
                               completion:(BRAssetSourceSheetCompletion)completion {
    BRAssetSourceSheetViewController *sheet = [[BRAssetSourceSheetViewController alloc] init];
    sheet.assetDisplayName = displayName;
    sheet.currentStateLabel = currentStateLabel;
    sheet.hasCustomAsset = hasCustomAsset;
    sheet.completion = completion;
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    return sheet;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.03 blue:0.16 alpha:1.0];

    self.rows = [self buildRowInfos];

    [self buildTableView];
    [self configureSheetPresentationDetents];
}

/// Configured in viewDidLoad (not viewDidAppear): the sheet presentation
/// controller already exists by this point, and setting the detents here
/// means the sheet is presented directly at its final size. Doing this in
/// viewDidAppear instead causes a visible "presents large, then snaps down
/// to medium" jump, because the initial presentation animates to the
/// default (large) detent before the medium-only detent is applied.
- (void)configureSheetPresentationDetents {
    UISheetPresentationController *sheetController = self.sheetPresentationController;
    if (!sheetController) return;

    sheetController.prefersGrabberVisible = YES;
    sheetController.preferredCornerRadius = 24.0;
    sheetController.detents = @[[UISheetPresentationControllerDetent mediumDetent]];
}

#pragma mark - Row Definitions

- (NSArray<BRAssetSourceRowInfo *> *)buildRowInfos {
    BRAssetSourceRowInfo *uploadRow = [BRAssetSourceRowInfo new];
    uploadRow.option = BRAssetSourceOptionUploadPhoto;
    uploadRow.symbolName = @"photo.on.rectangle";
    uploadRow.title = @"Upload From Photo Library";
    uploadRow.subtitle = @"Choose an image already on your device.";

    BRAssetSourceRowInfo *fileRow = [BRAssetSourceRowInfo new];
    fileRow.option = BRAssetSourceOptionUploadFile;
    fileRow.symbolName = @"folder";
    fileRow.title = @"Import From Files";
    fileRow.subtitle = @"Use an image from iCloud Drive or another provider.";

    BRAssetSourceRowInfo *promptRow = [BRAssetSourceRowInfo new];
    promptRow.option = BRAssetSourceOptionAIPrompt;
    promptRow.symbolName = @"sparkles";
    promptRow.title = @"Generate With AI Prompt";
    promptRow.subtitle = @"Describe what you want and the AI will create it.";

    BRAssetSourceRowInfo *resetRow = [BRAssetSourceRowInfo new];
    resetRow.option = BRAssetSourceOptionResetToDefault;
    resetRow.symbolName = @"arrow.counterclockwise";
    resetRow.title = @"Use Default AI Generation";
    resetRow.subtitle = @"Clear any custom photo or prompt for this asset.";
    resetRow.isDestructive = self.hasCustomAsset;

    return @[uploadRow, fileRow, promptRow, resetRow];
}

#pragma mark - Layout

- (void)buildTableView {
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = [NSString stringWithFormat:@"Configure: %@", self.assetDisplayName];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:22.0];
    titleLabel.numberOfLines = 0;

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = self.currentStateLabel;
    subtitleLabel.textColor = [UIColor systemGrayColor];
    subtitleLabel.font = [UIFont systemFontOfSize:14.0];
    subtitleLabel.numberOfLines = 0;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64.0;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"AssetSourceRow"];

    for (UIView *view in @[titleLabel, subtitleLabel, self.tableView]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20.0],

        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],

        // Pinning the bottom anchor (rather than a `<=` inequality) gives the
        // table view an unambiguous height. With scrollEnabled left at its
        // default (YES), 3 rows fit comfortably within the medium detent on
        // every device, and the table would simply scroll if they didn't.
        [self.tableView.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:12.0],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12.0],
    ]];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AssetSourceRow" forIndexPath:indexPath];
    BRAssetSourceRowInfo *row = self.rows[indexPath.row];

    UIColor *tintColor = row.isDestructive ? [UIColor systemRedColor] : [UIColor systemYellowColor];

    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = row.title;
    content.secondaryText = row.subtitle;
    content.textProperties.color = row.isDestructive ? [UIColor systemRedColor] : [UIColor whiteColor];
    content.secondaryTextProperties.color = [UIColor systemGrayColor];
    content.image = [UIImage systemImageNamed:row.symbolName];
    content.imageProperties.tintColor = tintColor;

    cell.contentConfiguration = content;
    cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BRAssetSourceOption selectedOption = self.rows[indexPath.row].option;

    __weak typeof(self) weakSelf = self;
    [self dismissViewControllerAnimated:YES completion:^{
        if (weakSelf.completion) {
            weakSelf.completion(selectedOption);
        }
    }];
}

@end
