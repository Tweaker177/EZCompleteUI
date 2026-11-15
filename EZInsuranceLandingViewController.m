// EZInsuranceLandingViewController.m
// EZCompleteUI

#import "EZInsuranceLandingViewController.h"
#import "EZInsurancePolicyDetailViewController.h"
#import "EZInsurancePolicyManager.h"
#import "EZInsuranceDateUtils.h"

static NSString *const kCellReuseID = @"EZInsurancePolicyCell";

// Statuses that keep a policy on this screen. Terminal states (released,
// cancelled) are filtered out — see the .h file for why.
static BOOL EZStatusIsCurrent(NSString *status) {
    return [status isEqualToString:@"active"] ||
           [status isEqualToString:@"releasing"] ||
           [status isEqualToString:@"release_failed"];
}

@interface EZInsuranceLandingViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyStateLabel;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *policies;
@property (nonatomic, strong, nullable) NSTimer *tickTimer;

@end

@implementation EZInsuranceLandingViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Insurance Policies";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.policies = [NSMutableArray array];

    [self ez_buildUI];
    [self ez_reload];

    // Ticks visible row countdowns once a second. Invalidated in
    // viewWillDisappear so it isn't running while this screen is off
    // screen (e.g. while the detail VC is pushed on top of it).
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ez_reload]; // catches anything that changed while the detail VC was open
    [self ez_startTicking];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.tickTimer invalidate];
    self.tickTimer = nil;
}

- (void)ez_startTicking {
    [self.tickTimer invalidate];
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        target:self
                                                      selector:@selector(ez_tick)
                                                      userInfo:nil
                                                       repeats:YES];
}

- (void)ez_tick {
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
        if (!indexPath) continue;
        [self ez_configureCell:cell atIndexPath:indexPath];
    }
}

// ── UI setup ─────────────────────────────────────────────────────────────

- (void)ez_buildUI {
    UIButton *newPolicyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *icon = [UIImage systemImageNamed:@"lock.rectangle.stack.fill"];
    [newPolicyButton setImage:icon forState:UIControlStateNormal];
    [newPolicyButton setTitle:@"  Open New Insurance Policy" forState:UIControlStateNormal];
    newPolicyButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    newPolicyButton.contentEdgeInsets = UIEdgeInsetsMake(14, 20, 14, 20);
    newPolicyButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    newPolicyButton.layer.cornerRadius = 12;
    newPolicyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [newPolicyButton addTarget:self action:@selector(ez_openNewPolicyTapped)
               forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:newPolicyButton];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    // Deliberately NOT using registerClass: here — that forces
    // UITableViewCellStyleDefault, which has no visible detailTextLabel.
    // cellForRowAtIndexPath below does the classic manual dequeue-or-create
    // instead, so the subtitle style actually renders.
    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(ez_reload) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refresh;
    [self.view addSubview:self.tableView];

    self.emptyStateLabel = [[UILabel alloc] init];
    self.emptyStateLabel.adjustsFontSizeToFitWidth = YES;
    self.emptyStateLabel.minimumScaleFactor = 0.5;
    self.emptyStateLabel.text = @"No active policies.\nTap above to create one.";
    self.emptyStateLabel.numberOfLines = 0;
    self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyStateLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyStateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateLabel.hidden = YES;
    [self.view addSubview:self.emptyStateLabel];

    self.loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.loadingSpinner];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [newPolicyButton.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:16],
        [newPolicyButton.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:20],
        [newPolicyButton.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-20],

        [self.tableView.topAnchor constraintEqualToAnchor:newPolicyButton.bottomAnchor constant:16],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.emptyStateLabel.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.emptyStateLabel.topAnchor constraintEqualToAnchor:self.tableView.topAnchor constant:48],
        [self.emptyStateLabel.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:32],
        [self.emptyStateLabel.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-32],

        [self.loadingSpinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingSpinner.centerYAnchor constraintEqualToAnchor:self.tableView.topAnchor constant:48],
    ]];
}

- (void)ez_openNewPolicyTapped {
    EZInsurancePolicyDetailViewController *detail =
        [[EZInsurancePolicyDetailViewController alloc] initWithPolicy:nil];
    [self.navigationController pushViewController:detail animated:YES];
}

// ── Data ─────────────────────────────────────────────────────────────────

- (void)ez_reload {
    BOOL isPullRefresh = self.tableView.refreshControl.isRefreshing;
    if (!isPullRefresh) [self.loadingSpinner startAnimating];

    __weak typeof(self) weakSelf = self;
    [[EZInsurancePolicyManager shared] listPoliciesWithCompletion:^(NSArray<NSDictionary *> *policies, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        [strongSelf.loadingSpinner stopAnimating];
        [strongSelf.tableView.refreshControl endRefreshing];

        if (errorMessage) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Could Not Load Policies"
                                                                             message:errorMessage
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:alert animated:YES completion:nil];
            return;
        }

        NSMutableArray<NSDictionary *> *current = [NSMutableArray array];
        for (NSDictionary *policy in policies) {
            if (EZStatusIsCurrent(policy[@"status"])) [current addObject:policy];
        }

        strongSelf.policies = current;
        strongSelf.emptyStateLabel.hidden = (current.count > 0);
        [strongSelf.tableView reloadData];
    }];
}

// ── UITableViewDataSource / Delegate ────────────────────────────────────

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.policies.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellReuseID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kCellReuseID];
    }
    [self ez_configureCell:cell atIndexPath:indexPath];
    return cell;
}

- (void)ez_configureCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.policies.count) return; // guard against a mid-reload race with the tick timer
    NSDictionary *policy = self.policies[indexPath.row];
    NSString *status = policy[@"status"];

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if ([status isEqualToString:@"releasing"]) {
        cell.textLabel.text = @"Sending now…";
        cell.detailTextLabel.text = @"A release is currently in progress";
    } else if ([status isEqualToString:@"release_failed"]) {
        cell.textLabel.text = @"⚠️ Needs attention";
        cell.detailTextLabel.text = @"Automatic release failed repeatedly — open to retry";
    } else {
        NSDate *lastCheckin = [EZInsuranceDateUtils dateFromPostgRESTString:policy[@"last_checkin_at"]];
        NSInteger frequencyHours = [policy[@"frequency_hours"] integerValue];
        if (lastCheckin) {
            NSDate *deadline = [EZInsuranceDateUtils deadlineFromLastCheckinAt:lastCheckin frequencyHours:frequencyHours];
            cell.textLabel.text = [NSString stringWithFormat:@"Sends in %@",
                [EZInsuranceDateUtils countdownStringFromNowUntilDeadline:deadline]];
        } else {
            cell.textLabel.text = @"Active policy";
        }
        cell.detailTextLabel.text = [NSString stringWithFormat:@"Check in every %ld hours", (long)frequencyHours];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= self.policies.count) return;
    NSDictionary *policy = self.policies[indexPath.row];
    EZInsurancePolicyDetailViewController *detail =
        [[EZInsurancePolicyDetailViewController alloc] initWithPolicy:policy];
    [self.navigationController pushViewController:detail animated:YES];
}

@end
