#import "BRRicochetHighScoresViewController.h"

static NSString * const kBRRicochetHighScoresURL = @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/br-ricochet-highscores";

@interface BRRicochetHighScoresViewController ()
@property (nonatomic, assign) NSInteger pendingScore;
@property (nonatomic, strong) NSArray<NSDictionary *> *scores;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UIButton *submitButton;
@end

@implementation BRRicochetHighScoresViewController

- (instancetype)initWithPendingScore:(NSInteger)pendingScore {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _pendingScore = pendingScore;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Ricochet High Scores";
    self.view.backgroundColor = [UIColor colorWithRed:0.025 green:0.03 blue:0.09 alpha:1];
    self.tableView.backgroundColor = self.view.backgroundColor;
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.13];
    self.tableView.rowHeight = 58;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(fetchScores) forControlEvents:UIControlEventValueChanged];
    [self fetchScores];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section != 0 || self.pendingScore < 0) return nil;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 164)];
    UIView *card = [[UIView alloc] initWithFrame:CGRectInset(header.bounds, 16, 8)];
    card.backgroundColor = [UIColor colorWithRed:0.92 green:0.18 blue:0.48 alpha:0.20];
    card.layer.cornerRadius = 18;
    card.layer.borderColor = [UIColor colorWithRed:0.92 green:0.18 blue:0.48 alpha:0.75].CGColor;
    card.layer.borderWidth = 1.25;
    [header addSubview:card];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, card.bounds.size.width - 32, 25)];
    label.text = [NSString stringWithFormat:@"🏆  Score: %ld", (long)self.pendingScore];
    label.font = [UIFont monospacedSystemFontOfSize:19 weight:UIFontWeightBold];
    label.textColor = UIColor.whiteColor;
    [card addSubview:label];
    self.nameField = [[UITextField alloc] initWithFrame:CGRectMake(16, 48, card.bounds.size.width - 32, 38)];
    self.nameField.placeholder = @"Enter your name";
    self.nameField.text = [[NSUserDefaults standardUserDefaults] stringForKey:@"BRRicochetHighScoreName"] ?: @"";
    self.nameField.textColor = UIColor.whiteColor;
    self.nameField.tintColor = UIColor.whiteColor;
    self.nameField.backgroundColor = [UIColor colorWithWhite:0 alpha:0.33];
    self.nameField.layer.cornerRadius = 9;
    self.nameField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    self.nameField.leftViewMode = UITextFieldViewModeAlways;
    self.nameField.autocorrectionType = UITextAutocorrectionTypeNo;
    [card addSubview:self.nameField];
    self.submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.submitButton.frame = CGRectMake(16, 96, card.bounds.size.width - 32, 38);
    [self.submitButton setTitle:@"Submit Score" forState:UIControlStateNormal];
    self.submitButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.submitButton.tintColor = UIColor.whiteColor;
    self.submitButton.backgroundColor = [UIColor colorWithRed:0.92 green:0.18 blue:0.48 alpha:1];
    self.submitButton.layer.cornerRadius = 10;
    [self.submitButton addTarget:self action:@selector(submitScore) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:self.submitButton];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 0 && self.pendingScore >= 0 ? 164 : 38;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.scores.count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.pendingScore >= 0 ? @"TOP 10" : @"RICHOCHET BLAST — TOP 10";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ScoreCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"ScoreCell"];
    NSDictionary *entry = self.scores[indexPath.row];
    NSArray *medals = @[ @"🥇", @"🥈", @"🥉" ];
    NSString *rank = indexPath.row < 3 ? medals[indexPath.row] : [NSString stringWithFormat:@"%ld.", (long)indexPath.row + 1];
    cell.textLabel.text = [NSString stringWithFormat:@"%@  %@", rank, entry[@"player_name"] ?: @"Anonymous"];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@", entry[@"score"] ?: @0];
    cell.detailTextLabel.textColor = [UIColor systemYellowColor];
    cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:18 weight:UIFontWeightBold];
    cell.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    return cell;
}

- (void)fetchScores {
    NSURL *url = [NSURL URLWithString:kBRRicochetHighScoresURL];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![parsed isKindOfClass:NSArray.class]) { dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf.refreshControl endRefreshing]; }); return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.scores = parsed;
            [weakSelf.tableView reloadData];
            [weakSelf.refreshControl endRefreshing];
        });
    }] resume];
}

- (void)submitScore {
    NSString *name = self.nameField.text.length ? self.nameField.text : @"Anonymous";
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:@"BRRicochetHighScoreName"];
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{ @"player_name": name, @"score": @(self.pendingScore) } options:0 error:nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kBRRicochetHighScoresURL]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = body;
    self.submitButton.enabled = NO;
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (http.statusCode == 201) {
                weakSelf.pendingScore = -1;
                [weakSelf.tableView reloadData];
                [weakSelf fetchScores];
            } else {
                weakSelf.submitButton.enabled = YES;
            }
        });
    }] resume];
}

@end
