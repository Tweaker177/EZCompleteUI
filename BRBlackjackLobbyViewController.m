// BRBlackjackLobbyViewController.m
// EZCompleteUI v1.0
//
// Purpose:
//   See BRBlackjackLobbyViewController.h. Table data comes from the
//   list_tables action; the list refreshes every few seconds while the screen
//   is visible and via pull-to-refresh, and shows a retry message instead of a
//   blank screen when the request fails.
//
// Changes from v0 (new file):
//   - Initial version.

#import "BRBlackjackLobbyViewController.h"
#import "BRBlackjackAPI.h"
#import "BRBlackjackTableViewController.h"

static const NSTimeInterval kLobbyRefreshInterval = 5.0;

static NSInteger BRBlackjackLobbyInt(id value) { return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0; }
static BOOL BRBlackjackLobbyBool(id value) { return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO; }
static NSString *BRBlackjackLobbyString(id value) { return [value isKindOfClass:[NSString class]] ? value : @""; }

@interface BRBlackjackLobbyViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *tables;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic) NSInteger balance;
@property (nonatomic) BOOL loading;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation BRBlackjackLobbyViewController

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Title", nil, NSBundle.mainBundle, @"Blackjack", nil);
    self.tables = @[];
    self.tableView.backgroundColor = [UIColor colorWithRed:.03 green:.22 blue:.14 alpha:1];
    self.tableView.rowHeight = 78;
    self.refreshControl = [UIRefreshControl new];
    self.refreshControl.tintColor = UIColor.whiteColor;
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
    [self.refreshTimer invalidate];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:kLobbyRefreshInterval target:self selector:@selector(reload) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)dealloc { [self.refreshTimer invalidate]; }

- (void)reload {
    if (self.loading) return;
    self.loading = YES;
    __weak typeof(self) weakSelf = self;
    [BRBlackjackAPI performAction:@"list_tables" params:nil completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.loading = NO;
        [self.refreshControl endRefreshing];
        if (error) {
            self.errorMessage = error;
        } else {
            self.errorMessage = nil;
            id tables = json[@"tables"];
            self.tables = [tables isKindOfClass:[NSArray class]] ? tables : @[];
            self.balance = [json[@"balance"] respondsToSelector:@selector(integerValue)] ? [json[@"balance"] integerValue] : 0;
        }
        [self.tableView reloadData];
    }];
}

#pragma mark UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.tables.count > 0 ? self.tables.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Balance", nil, NSBundle.mainBundle, @"Your balance: %ld coins", nil), (long)self.balance];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [UIColor colorWithWhite:0 alpha:.30];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:.7];
    cell.detailTextLabel.numberOfLines = 2;

    if (self.tables.count == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = self.errorMessage ?: NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Loading", nil, NSBundle.mainBundle, @"Loading tables…", nil);
        cell.detailTextLabel.text = self.errorMessage ? NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.PullToRetry", nil, NSBundle.mainBundle, @"Pull down to try again.", nil) : @"";
        return cell;
    }

    NSDictionary *table = [self.tables[indexPath.row] isKindOfClass:[NSDictionary class]] ? self.tables[indexPath.row] : @{};
    NSInteger seated = BRBlackjackLobbyInt(table[@"seated"]);
    NSInteger maxSeats = BRBlackjackLobbyInt(table[@"max_seats"]);
    BOOL mine = BRBlackjackLobbyBool(table[@"my_table"]);
    NSString *tableName = BRBlackjackLobbyString(table[@"name"]);
    NSInteger minBet = BRBlackjackLobbyInt(table[@"min_bet"]);
    NSInteger maxBet = BRBlackjackLobbyInt(table[@"max_bet"]);
    cell.textLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    cell.textLabel.text = [NSString stringWithFormat:@"🃏 %@%@", tableName.length ? tableName : @"Table", mine ? @"  ·  you're seated" : @""];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Bets %ld–%ld coins  ·  %ld/%ld seated  ·  Blackjack pays 3:2",
                                 (long)minBet, (long)maxBet, (long)seated, (long)maxSeats];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.tables.count == 0) return;
    NSDictionary *table = [self.tables[indexPath.row] isKindOfClass:[NSDictionary class]] ? self.tables[indexPath.row] : @{};
    NSString *tableID = [table[@"id"] isKindOfClass:[NSString class]] ? table[@"id"] : nil;
    if (!tableID) return;
    NSString *tableName = BRBlackjackLobbyString(table[@"name"]);
    BRBlackjackTableViewController *controller = [[BRBlackjackTableViewController alloc] initWithTableID:tableID tableName:tableName.length ? tableName : nil];
    [self.navigationController pushViewController:controller animated:YES];
}

@end
