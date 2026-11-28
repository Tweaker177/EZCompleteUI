// BRRouletteLobbyViewController.m
// EZCompleteUI v1.0
//
// Purpose:
//   See BRRouletteLobbyViewController.h. Table data comes from the br-roulette
//   "list_tables" action. The list refreshes every few seconds while the
//   screen is visible and via pull-to-refresh, and shows a retry message
//   instead of a blank screen when the request fails.
//
// Changes from v0 (new file):
//   - Initial version.
//   - Every player-facing string goes through NSLocalizedStringWithDefaultValue
//     (keys BRRoulette.*), with the English text as the default value.

#import "BRRouletteLobbyViewController.h"
#import "BRRouletteAPI.h"
#import "BRRouletteTableViewController.h"

static const NSTimeInterval kRouletteLobbyRefreshInterval = 5.0;

static NSInteger BRRouletteLobbyInt(id value) { return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0; }
static NSString *BRRouletteLobbyString(id value) { return [value isKindOfClass:[NSString class]] ? value : @""; }

static NSString *BRRouletteLobbyGrouped(NSInteger value) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [NSNumberFormatter new]; formatter.numberStyle = NSNumberFormatterDecimalStyle; });
    return [formatter stringFromNumber:@(value)] ?: [NSString stringWithFormat:@"%ld", (long)value];
}

@interface BRRouletteLobbyViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *tables;
@property (nonatomic) NSInteger balance;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic) BOOL loading;
@property (nonatomic, copy) NSString *loadError;
@end

@implementation BRRouletteLobbyViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.Title", nil, NSBundle.mainBundle, @"Roulette", nil);
    self.tables = @[];
    self.tableView.backgroundColor = [UIColor colorWithRed:.012 green:.035 blue:.028 alpha:1];
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:.12];
    self.refreshControl = [UIRefreshControl new];
    self.refreshControl.tintColor = [UIColor colorWithRed:.85 green:.67 blue:.33 alpha:1];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
    [self.refreshTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:kRouletteLobbyRefreshInterval repeats:YES block:^(NSTimer *timer) {
        [weakSelf reload];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)dealloc {
    [self.refreshTimer invalidate];
}

- (void)reload {
    if (self.loading) { [self.refreshControl endRefreshing]; return; }
    self.loading = YES;
    __weak typeof(self) weakSelf = self;
    [BRRouletteAPI performAction:@"list_tables" params:nil completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.loading = NO;
        [self.refreshControl endRefreshing];
        if (error) {
            self.loadError = error;
        } else {
            self.loadError = nil;
            NSArray *rows = [json[@"tables"] isKindOfClass:[NSArray class]] ? json[@"tables"] : @[];
            NSMutableArray<NSDictionary *> *clean = [NSMutableArray new];
            for (id row in rows) if ([row isKindOfClass:[NSDictionary class]]) [clean addObject:row];
            self.tables = clean;
            self.balance = BRRouletteLobbyInt(json[@"balance"]);
        }
        [self.tableView reloadData];
    }];
}

#pragma mark UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.tables.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.loadError.length) return [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.RetryFooterFormat", nil, NSBundle.mainBundle, @"%@ Pull down to retry.", nil), self.loadError];
    if (self.tables.count == 0 && !self.loading) return NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.NoTables", nil, NSBundle.mainBundle, @"No roulette tables are open right now.", nil);
    return [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.BalanceFormat", nil, NSBundle.mainBundle, @"Your balance: 🪙 %@", nil), BRRouletteLobbyGrouped(self.balance)];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        ((UITableViewHeaderFooterView *)view).textLabel.textColor = [UIColor colorWithWhite:1 alpha:.7];
        ((UITableViewHeaderFooterView *)view).textLabel.textAlignment = NSTextAlignmentCenter;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"RouletteTableCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    NSDictionary *table = self.tables[(NSUInteger)indexPath.row];
    NSInteger seated = BRRouletteLobbyInt(table[@"players"]);
    NSInteger capacity = BRRouletteLobbyInt(table[@"max_players"]);
    BOOL mine = [table[@"my_table"] respondsToSelector:@selector(boolValue)] && [table[@"my_table"] boolValue];

    cell.backgroundColor = [UIColor colorWithWhite:1 alpha:.05];
    cell.textLabel.text = [NSString stringWithFormat:@"🎡 %@%@", BRRouletteLobbyString(table[@"name"]), mine ? [@"  " stringByAppendingString:NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.Seated", nil, NSBundle.mainBundle, @"(you're seated)", nil)] : @""];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.textLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    cell.detailTextLabel.text = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.DetailFormat", nil, NSBundle.mainBundle, @"Bets 🪙 %1$@ – %2$@  ·  %3$ld/%4$ld seated", nil),
                                 BRRouletteLobbyGrouped(BRRouletteLobbyInt(table[@"min_bet"])),
                                 BRRouletteLobbyGrouped(BRRouletteLobbyInt(table[@"max_bet"])),
                                 (long)seated, (long)capacity];
    cell.detailTextLabel.textColor = [UIColor colorWithRed:.85 green:.67 blue:.33 alpha:1];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

#pragma mark UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *table = self.tables[(NSUInteger)indexPath.row];
    NSString *tableID = BRRouletteLobbyString(table[@"id"]);
    if (tableID.length == 0) return;
    NSString *tableName = BRRouletteLobbyString(table[@"name"]);
    BRRouletteTableViewController *controller = [[BRRouletteTableViewController alloc] initWithTableID:tableID tableName:tableName.length ? tableName : nil];
    [self.navigationController pushViewController:controller animated:YES];
}

@end
