#import "BRSlotGamePickerViewController.h"
#import "BRSlotMachineViewController.h"
#import "BRGameLibrary.h"
#import "BRGamePickerViewController.h"

static UIImage *BRSlotGameThumbnail(UIImage *image) {
    if (!image) return nil;
    CGSize size = CGSizeMake(54, 54);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
    CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
    [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
    UIImage *thumbnail = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return thumbnail;
}

@interface BRSlotGamePickerViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<BRGameRecord *> *importableGames;
@end

@implementation BRSlotGamePickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Brainrot Slots";
    self.view.backgroundColor = [UIColor colorWithRed:.04 green:.02 blue:.09 alpha:1];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark.circle.fill"] style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.importableGames = BRGameLibrary.shared.allRecords;
    UILabel *header = [UILabel new]; header.text = @"SLOT GAMES"; header.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBlack]; header.textColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:1]; header.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:header];
    UILabel *detail = [UILabel new]; detail.text = @"Pick the preinstalled machine or make a new theme with your own room and symbols."; detail.textColor = [UIColor colorWithWhite:.68 alpha:1]; detail.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium]; detail.numberOfLines = 2; detail.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:detail];
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; self.tableView.backgroundColor = UIColor.clearColor; self.tableView.delegate = self; self.tableView.dataSource = self; self.tableView.rowHeight = 82; self.tableView.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[[header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:18], [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24], [detail.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:6], [detail.leadingAnchor constraintEqualToAnchor:header.leadingAnchor], [detail.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24], [self.tableView.topAnchor constraintEqualToAnchor:detail.bottomAnchor constant:14], [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; self.importableGames = BRGameLibrary.shared.allRecords; [self.tableView reloadData]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.importableGames.count ? 3 : 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { if (section == 0) return 1; if (section == 1) return 2; return self.importableGames.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return nil; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path { UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil]; cell.backgroundColor = [UIColor colorWithWhite:1 alpha:.05]; cell.textLabel.textColor = UIColor.whiteColor; cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; if (path.section == 0) { cell.imageView.image = [UIImage systemImageNamed:@"7.circle.fill"]; cell.imageView.tintColor = [UIColor colorWithRed:1 green:.74 blue:.1 alpha:1]; cell.textLabel.text = @"Brainrot Slots"; } else if (path.section == 1 && path.row == 0) { cell.imageView.image = [UIImage systemImageNamed:@"paintpalette.fill"]; cell.imageView.tintColor = [UIColor systemTealColor]; cell.textLabel.text = @"Create New Slot Game"; } else if (path.section == 1) { cell.imageView.image = [UIImage systemImageNamed:@"person.3.fill"]; cell.imageView.tintColor = [UIColor systemPurpleColor]; cell.textLabel.text = @"Browse Community Games"; } else { BRGameRecord *game = self.importableGames[path.row]; cell.imageView.image = BRSlotGameThumbnail(game.backgroundImage) ?: [UIImage systemImageNamed:@"photo"]; cell.imageView.tintColor = game.backgroundImage ? nil : [UIColor systemPurpleColor]; cell.imageView.contentMode = UIViewContentModeScaleAspectFill; cell.imageView.layer.cornerRadius = 8; cell.imageView.clipsToBounds = YES; cell.textLabel.text = game.themeTitle; } return cell; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path { [tableView deselectRowAtIndexPath:path animated:YES]; if (path.section == 1 && path.row == 1) { BRGamePickerViewController *community = [BRGamePickerViewController new]; community.startsOnCommunityTab = YES; __weak typeof(self) weakSelf = self; community.onSlotThemeSelection = ^(BRGameRecord *record) { __strong typeof(weakSelf) self = weakSelf; if (!self) return; [self.navigationController pushViewController:[[BRSlotMachineViewController alloc] initWithBrainRotGameRecord:record] animated:YES]; }; community.modalPresentationStyle = UIModalPresentationFullScreen; [self presentViewController:community animated:YES completion:nil]; return; } BRSlotMachineViewController *slots = path.section == 2 ? [[BRSlotMachineViewController alloc] initWithBrainRotGameRecord:self.importableGames[path.row]] : [BRSlotMachineViewController new]; if (path.section == 1) slots.title = @"New Slot Game"; [self.navigationController pushViewController:slots animated:YES]; }
@end
