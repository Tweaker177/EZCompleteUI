// EZCoinStoreViewController.m
// EZCompleteUI
//
// Gamified EZ Coin store with subscription tiers and one-time top-up packages.
// Uses SFSafariViewController for PayPal checkout flow.
// Coin image: EZCoin.png (bundled asset).

#import "EZCoinStoreViewController.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZCoinPotView.h"
#import "helpers.h"

// ── Supabase / PayPal constants ───────────────────────────────────────────────

static NSString *const kStoreSupabaseURL   = @"https://spuoimtqofhbdzosrbng.supabase.co";

// Subscription plan IDs — replace sandbox IDs with live IDs before release
static NSString *const kPlanBasic    = @"P-1HW38522AL709604TNHUUASA"; // $5/mo  400 coins
static NSString *const kPlanStandard = @"P-0KG918617R081535MNH7AY4Y";  // $10/mo 900 coins
static NSString *const kPlanPro      = @"P-6MD31726ST362124GNH7A3YY";       // $15/mo 1600 coins
static NSString *const kPlanUltra    = @"P-73L708182D9034800NH7EXZY";     // $20/mo 2500 coins

// ── Store item model ──────────────────────────────────────────────────────────

typedef NS_ENUM(NSUInteger, EZStoreItemType) {
    EZStoreItemTypeSubscription,
    EZStoreItemTypeTopUp,
};

@interface EZStoreItem : NSObject
@property (nonatomic, copy)   NSString        *title;
@property (nonatomic, copy)   NSString        *subtitle;      // e.g. "400 coins / month"
@property (nonatomic, copy)   NSString        *priceString;   // e.g. "$5.00 / mo"
@property (nonatomic, copy)   NSString        *planOrPackageID;
@property (nonatomic, assign) EZStoreItemType  type;
@property (nonatomic, assign) NSInteger        coins;
@property (nonatomic, assign) BOOL             isCurrentPlan;
@property (nonatomic, strong) UIColor         *accentColor;
@property (nonatomic, copy)   NSString        *badgeText;     // e.g. "BEST VALUE" — nil for none
@end

@implementation EZStoreItem
@end

// ── Cell ──────────────────────────────────────────────────────────────────────

@interface EZStoreCell : UITableViewCell
@property (nonatomic, strong) UIView   *cardView;
@property (nonatomic, strong) UIImageView *coinImageView;
@property (nonatomic, strong) UILabel  *titleLabel;
@property (nonatomic, strong) UILabel  *subtitleLabel;
@property (nonatomic, strong) UILabel  *priceLabel;
@property (nonatomic, strong) UILabel  *badgeLabel;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, copy)   void (^onAction)(void);
- (void)configureWithItem:(EZStoreItem *)item coinImage:(UIImage * _Nullable)coinImage;
@end

@implementation EZStoreCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor    = [UIColor clearColor];
        self.selectionStyle     = UITableViewCellSelectionStyleNone;

        self.cardView = [[UIView alloc] init];
        self.cardView.layer.cornerRadius  = 16;
        self.cardView.layer.borderWidth   = 1;
        self.cardView.layer.borderColor   = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
        self.cardView.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.cardView.layer.shadowOpacity = 0.25;
        self.cardView.layer.shadowOffset  = CGSizeMake(0, 4);
        self.cardView.layer.shadowRadius  = 10;
        [self.contentView addSubview:self.cardView];

        self.coinImageView = [[UIImageView alloc] init];
        self.coinImageView.contentMode = UIViewContentModeScaleAspectFit;
        [self.cardView addSubview:self.coinImageView];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font          = [UIFont boldSystemFontOfSize:17];
        self.titleLabel.textColor     = [UIColor labelColor];
        [self.cardView addSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.font       = [UIFont systemFontOfSize:13];
        self.subtitleLabel.textColor  = [UIColor secondaryLabelColor];
        self.subtitleLabel.numberOfLines = 2;
        [self.cardView addSubview:self.subtitleLabel];

        self.priceLabel = [[UILabel alloc] init];
        self.priceLabel.font          = [UIFont boldSystemFontOfSize:15];
        self.priceLabel.textAlignment = NSTextAlignmentRight;
        [self.cardView addSubview:self.priceLabel];

        self.badgeLabel = [[UILabel alloc] init];
        self.badgeLabel.font          = [UIFont boldSystemFontOfSize:10];
        self.badgeLabel.textColor     = [UIColor whiteColor];
        self.badgeLabel.textAlignment = NSTextAlignmentCenter;
        self.badgeLabel.layer.cornerRadius = 8;
        self.badgeLabel.layer.masksToBounds = YES;
        self.badgeLabel.hidden        = YES;
        [self.cardView addSubview:self.badgeLabel];

        self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.actionButton.layer.cornerRadius = 10;
        self.actionButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.actionButton addTarget:self action:@selector(actionTapped)
                    forControlEvents:UIControlEventTouchUpInside];
        [self.cardView addSubview:self.actionButton];
    }
    return self;
}

- (void)configureWithItem:(EZStoreItem *)item coinImage:(UIImage *)coinImage {
    // Background gradient effect via color
    UIColor *baseColor = item.accentColor ?: [UIColor systemBlueColor];
    self.cardView.backgroundColor = [baseColor colorWithAlphaComponent:0.12];
    self.cardView.layer.borderColor = [baseColor colorWithAlphaComponent:0.3].CGColor;

    self.coinImageView.image = coinImage;
    self.titleLabel.text     = item.title;
    self.subtitleLabel.text  = item.subtitle;
    self.priceLabel.text     = item.priceString;
    self.priceLabel.textColor = baseColor;

    if (item.badgeText) {
        self.badgeLabel.hidden           = NO;
        self.badgeLabel.text             = [NSString stringWithFormat:@" %@ ", item.badgeText];
        self.badgeLabel.backgroundColor  = baseColor;
    } else {
        self.badgeLabel.hidden = YES;
    }

    if (item.isCurrentPlan) {
        [self.actionButton setTitle:@"Current Plan" forState:UIControlStateNormal];
        self.actionButton.backgroundColor = [UIColor systemGrayColor];
        self.actionButton.enabled = NO;
    } else if (item.type == EZStoreItemTypeSubscription) {
        [self.actionButton setTitle:@"Subscribe" forState:UIControlStateNormal];
        self.actionButton.backgroundColor = baseColor;
        self.actionButton.enabled = YES;
    } else {
        [self.actionButton setTitle:@"Buy Now" forState:UIControlStateNormal];
        self.actionButton.backgroundColor = baseColor;
        self.actionButton.enabled = YES;
    }
}

- (void)actionTapped {
    if (self.onAction) self.onAction();
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat pad  = 12;
    CGFloat w    = self.contentView.bounds.size.width - 32;
    CGFloat h    = self.contentView.bounds.size.height - 16;
    self.cardView.frame = CGRectMake(16, 8, w, h);

    CGFloat coinSize = 52;
    self.coinImageView.frame = CGRectMake(pad, (h - coinSize) / 2, coinSize, coinSize);

    CGFloat textX = coinSize + pad * 2;
    CGFloat textW = w - textX - 90 - pad;
    self.titleLabel.frame    = CGRectMake(textX, pad, textW, 22);
    self.subtitleLabel.frame = CGRectMake(textX, pad + 24, textW, 34);

    self.priceLabel.frame  = CGRectMake(w - 90 - pad, pad, 90, 22);
    self.badgeLabel.frame  = CGRectMake(w - 90 - pad, pad + 26, 90, 18);

    CGFloat btnW = w - textX - pad;
    CGFloat btnH = 34;
    self.actionButton.frame = CGRectMake(textX, h - btnH - pad, btnW, btnH);
}

@end

// ── Main VC ───────────────────────────────────────────────────────────────────

@interface EZCoinStoreViewController () <UITableViewDelegate, UITableViewDataSource, SFSafariViewControllerDelegate>
@property (nonatomic, strong) UITableView        *tableView;
@property (nonatomic, strong) UIView             *headerView;
@property (nonatomic, strong) UILabel            *balanceLabel;
@property (nonatomic, strong) UILabel            *warningLabel;
@property (nonatomic, strong) NSArray<EZStoreItem *> *items;
@property (nonatomic, strong) UIImage            *coinImage;
@property (nonatomic, strong) NSString           *pendingPurchaseType; // "subscription" or "topup"
@property (nonatomic, strong) NSString           *pendingPlanID;
@property (nonatomic, strong) NSString           *pendingOrderID;
@property (nonatomic, strong) EZCoinPotView      *storePotView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation EZCoinStoreViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"🪙 EZ Coin Store";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeTapped)];

    // Load coin image from bundle
    self.coinImage = [UIImage imageNamed:@"EZCoin"];

    [self buildItems];
    [self setupUI];
    [self refreshBalance];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// ── Build store items ─────────────────────────────────────────────────────────

- (void)buildItems {
    NSString *currentTier = [EZEntitlementManager shared].currentTier ?: @"none";

    NSMutableArray *items = [NSMutableArray array];

    // ── Subscription tiers ────────────────────────────────────────────────────

    EZStoreItem *basic    = [EZStoreItem new];
    basic.title           = @"Basic";
    basic.subtitle        = @"400 coins / month\nIdeal for casual use";
    basic.priceString     = @"$5 / mo";
    basic.planOrPackageID = kPlanBasic;
    basic.type            = EZStoreItemTypeSubscription;
    basic.coins           = 400;
    basic.accentColor     = [UIColor systemBlueColor];
    basic.isCurrentPlan   = [currentTier isEqualToString:@"basic"];
    [items addObject:basic];

    EZStoreItem *standard    = [EZStoreItem new];
    standard.title           = @"Standard";
    standard.subtitle        = @"900 coins / month\nGreat for daily users";
    standard.priceString     = @"$10 / mo";
    standard.planOrPackageID = kPlanStandard;
    standard.type            = EZStoreItemTypeSubscription;
    standard.coins           = 900;
    standard.accentColor     = [UIColor systemPurpleColor];
    standard.isCurrentPlan   = [currentTier isEqualToString:@"standard"];
    standard.badgeText       = @"POPULAR";
    [items addObject:standard];

    EZStoreItem *pro    = [EZStoreItem new];
    pro.title           = @"Pro";
    pro.subtitle        = @"1,600 coins / month\nFor power users & GPT-5";
    pro.priceString     = @"$15 / mo";
    pro.planOrPackageID = kPlanPro;
    pro.type            = EZStoreItemTypeSubscription;
    pro.coins           = 1600;
    pro.accentColor     = [UIColor systemOrangeColor];
    pro.isCurrentPlan   = [currentTier isEqualToString:@"pro"];
    pro.badgeText       = @"BEST VALUE";
    [items addObject:pro];

    EZStoreItem *ultra    = [EZStoreItem new];
    ultra.title           = @"Ultra";
    ultra.subtitle        = @"2,500 coins / month\nUnlimited power";
    ultra.priceString     = @"$20 / mo";
    ultra.planOrPackageID = kPlanUltra;
    ultra.type            = EZStoreItemTypeSubscription;
    ultra.coins           = 2500;
    ultra.accentColor     = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0]; // gold
    ultra.isCurrentPlan   = [currentTier isEqualToString:@"ultra"];
    ultra.badgeText       = @"ULTRA";
    [items addObject:ultra];

    // ── One-time top-ups ──────────────────────────────────────────────────────

    EZStoreItem *topup1    = [EZStoreItem new];
    topup1.title           = @"Coin Starter Pack";
    topup1.subtitle        = @"400 coins, one-time\nNever expires";
    topup1.priceString     = @"$5.00";
    topup1.planOrPackageID = @"TOPUP_400";
    topup1.type            = EZStoreItemTypeTopUp;
    topup1.coins           = 400;
    topup1.accentColor     = [UIColor systemTealColor];
    [items addObject:topup1];

    EZStoreItem *topup2    = [EZStoreItem new];
    topup2.title           = @"Coin Value Pack";
    topup2.subtitle        = @"900 coins, one-time\nNever expires";
    topup2.priceString     = @"$10.00";
    topup2.planOrPackageID = @"TOPUP_900";
    topup2.type            = EZStoreItemTypeTopUp;
    topup2.coins           = 900;
    topup2.accentColor     = [UIColor systemGreenColor];
    topup2.badgeText       = @"SAVE 10%";
    [items addObject:topup2];

    self.items = [items copy];
}

// ── UI Setup ──────────────────────────────────────────────────────────────────

- (void)setupUI {
    // Header
    self.headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 120)];
    self.headerView.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1.0];

    UILabel *storeTitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 20, self.view.bounds.size.width, 36)];
    storeTitle.text          = @"⚡ EZ Coin Store";
    storeTitle.font          = [UIFont boldSystemFontOfSize:24];
    storeTitle.textColor     = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
    storeTitle.textAlignment = NSTextAlignmentCenter;
    [self.headerView addSubview:storeTitle];
    
    [self addUseageButton];

    self.balanceLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 62, self.view.bounds.size.width, 22)];
    self.balanceLabel.font          = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.balanceLabel.textColor     = [UIColor secondaryLabelColor];
    self.balanceLabel.textAlignment = NSTextAlignmentCenter;
    self.balanceLabel.text          = @"Loading balance...";
    [self.headerView addSubview:self.balanceLabel];

    // Low coins warning banner
    self.warningLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 88, self.view.bounds.size.width, 28)];
    self.warningLabel.backgroundColor = [UIColor systemRedColor];
    self.warningLabel.font            = [UIFont boldSystemFontOfSize:13];
    self.warningLabel.textColor       = [UIColor whiteColor];
    self.warningLabel.textAlignment   = NSTextAlignmentCenter;
    self.warningLabel.hidden          = !self.showLowCoinsWarning;

    if (self.showLowCoinsWarning) {
        NSString *feature = self.triggeringFeatureName ?: @"this feature";
        self.warningLabel.text = [NSString stringWithFormat:
            @"⚠️  Not enough coins for %@. Top up below.", feature];
        // Expand header for warning
        CGRect f = self.headerView.frame;
        f.size.height = 124;
        self.headerView.frame = f;
    }
    [self.headerView addSubview:self.warningLabel];

    // Table
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.delegate         = self;
    self.tableView.dataSource       = self;
    self.tableView.backgroundColor  = [UIColor systemBackgroundColor];
    self.tableView.separatorStyle   = UITableViewCellSeparatorStyleNone;
    self.tableView.tableHeaderView  = self.headerView;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.tableView registerClass:[EZStoreCell class] forCellReuseIdentifier:@"EZStoreCell"];
    [self.view addSubview:self.tableView];

    // Section headers
    // (handled in tableView:titleForHeaderInSection:)

    // Spinner
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = self.view.center;
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
}

- (void)refreshBalance {
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        NSString *tier = [EZEntitlementManager shared].currentTier ?: @"none";
        self.balanceLabel.text = [NSString stringWithFormat:
            @"🪙 %ld coins   •   %@ plan", (long)balance, tier.capitalizedString];
        [self buildItems];
        [self.tableView reloadData];
    }];
}

// ── UITableView ───────────────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 4; // subscription tiers
    return 2;                   // top-up packages
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"  SUBSCRIPTIONS" : @"  ONE-TIME TOP-UPS";
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 36)];
    header.backgroundColor = [UIColor clearColor];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 8, 300, 20)];
    label.text      = section == 0 ? @"SUBSCRIPTIONS" : @"ONE-TIME TOP-UPS";
    label.font      = [UIFont boldSystemFontOfSize:11];
    label.textColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.8];
    label.adjustsFontSizeToFitWidth = YES;
    [header addSubview:label];

    // Gold divider line
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(20, 30, tableView.bounds.size.width - 40, 0.5)];
    line.backgroundColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.3];
    [header addSubview:line];

    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 36;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 120;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EZStoreCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZStoreCell"
                                                        forIndexPath:indexPath];
    NSInteger itemIndex = indexPath.section == 0 ? indexPath.row : 4 + indexPath.row;
    if (itemIndex < (NSInteger)self.items.count) {
        EZStoreItem *item = self.items[itemIndex];
        [cell configureWithItem:item coinImage:self.coinImage];

        __weak typeof(self) weakSelf = self;
        cell.onAction = ^{
            [weakSelf handlePurchaseForItem:item];
        };
    }
    return cell;
}

   
- (void)addUseageButton {
        UIButton *useageButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [useageButton setTitle:@"useage" forState:UIControlStateNormal];
        useageButton.translatesAutoresizingMaskIntoConstraints = NO;
        useageButton.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
        useageButton.titleLabel.font = [UIFont systemFontOfSize:16.0];
        [useageButton addTarget:self action:@selector(useageButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:useageButton];

        UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [useageButton.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8.0],
            [useageButton.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12.0]
        ]];
    }

- (void)useageButtonTapped:(UIButton *)sender {
        EZCoinLedgerViewController *ledgerVC = [[EZCoinLedgerViewController alloc] init];
        if (self.navigationController) {
            [self.navigationController pushViewController:ledgerVC animated:YES];
        } else {
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:ledgerVC];
            nav.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:nav animated:YES completion:nil];
        }
    }
// ── Purchase flow ─────────────────────────────────────────────────────────────

- (void)handlePurchaseForItem:(EZStoreItem *)item {
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) {
        [self showAlert:@"Not logged in" message:@"Please sign in first."];
        return;
    }

    [self.spinner startAnimating];
    self.tableView.userInteractionEnabled = NO;

    if (item.type == EZStoreItemTypeSubscription) {
        [self startSubscriptionForPlanID:item.planOrPackageID token:token];
    } else {
        [self startTopUpForPackageID:item.planOrPackageID coins:item.coins token:token];
    }
}

// ── Subscription checkout ─────────────────────────────────────────────────────

- (void)startSubscriptionForPlanID:(NSString *)planID token:(NSString *)token {
    // If user has an active subscription, cancel it first then start new one
    NSString *currentTier = [EZEntitlementManager shared].currentTier;
    BOOL hasActiveSub = currentTier && ![currentTier isEqualToString:@"none"];

    if (hasActiveSub) {
        [self cancelCurrentSubscriptionWithToken:token completion:^(BOOL success) {
            // Proceed regardless — PayPal will handle the new charge
            [self createPayPalSubscriptionForPlanID:planID token:token];
        }];
    } else {
        [self createPayPalSubscriptionForPlanID:planID token:token];
    }
}

- (void)cancelCurrentSubscriptionWithToken:(NSString *)token
                                completion:(void(^)(BOOL success))completion {
    NSURL *url = [NSURL URLWithString:[kStoreSupabaseURL
        stringByAppendingString:@"/functions/v1/cancel-paypal-subscription"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{} options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(!e);
        });
    }] resume];
}

- (void)createPayPalSubscriptionForPlanID:(NSString *)planID token:(NSString *)token {
    NSURL *url = [NSURL URLWithString:[kStoreSupabaseURL
        stringByAppendingString:@"/functions/v1/create-paypal-subscription"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"plan_id": planID,
        @"user_id": [EZAuthManager shared].userId ?: @""
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.tableView.userInteractionEnabled = YES;

            if (error) {
                [self showAlert:@"Error" message:error.localizedDescription]; return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *approveURL = json[@"approve_url"];
            if (!approveURL) {
                [self showAlert:@"Error" message:@"Could not start checkout. Try again."];
                return;
            }
            self.pendingPurchaseType = @"subscription";
            SFSafariViewController *safari = [[SFSafariViewController alloc]
                initWithURL:[NSURL URLWithString:approveURL]];
            safari.delegate = self;
            safari.preferredBarTintColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1.0];
            safari.preferredControlTintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
            [self presentViewController:safari animated:YES completion:nil];
        });
    }] resume];
}

// ── One-time top-up checkout ──────────────────────────────────────────────────

- (void)startTopUpForPackageID:(NSString *)packageID coins:(NSInteger)coins token:(NSString *)token {
    NSDictionary *packagePrices = @{
        @"TOPUP_400": @"5.00",
        @"TOPUP_900": @"10.00",
    };
    NSString *amount = packagePrices[packageID] ?: @"5.00";

    NSURL *url = [NSURL URLWithString:[kStoreSupabaseURL
        stringByAppendingString:@"/functions/v1/create-paypal-order"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"user_id":    [EZAuthManager shared].userId ?: @"",
        @"package_id": packageID,
        @"amount":     amount,
        @"coins":      @(coins),
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.tableView.userInteractionEnabled = YES;

            if (error) {
                [self showAlert:@"Error" message:error.localizedDescription]; return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *approveURL = json[@"approve_url"];
            if (!approveURL) {
                [self showAlert:@"Error" message:@"Could not start checkout. Try again."];
                return;
            }
            self.pendingPurchaseType = @"topup";
            self.pendingOrderID = json[@"order_id"];
            SFSafariViewController *safari = [[SFSafariViewController alloc]
                initWithURL:[NSURL URLWithString:approveURL]];
            safari.delegate = self;
            safari.preferredBarTintColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1.0];
            safari.preferredControlTintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
            [self presentViewController:safari animated:YES completion:nil];
        });
    }] resume];
}

// ── SFSafariViewControllerDelegate ───────────────────────────────────────────

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    if ([self.pendingPurchaseType isEqualToString:@"topup"] && self.pendingOrderID.length > 0) {
        // Capture the order directly — more reliable than a webhook for one-time payments
        [self captureOrderWithID:self.pendingOrderID];
        self.pendingOrderID = nil;
    } else {
        // Subscription — wait for webhook then refresh
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self refreshBalance];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"EZSubscriptionUpdated" object:nil];
        });
    }
    self.pendingPurchaseType = nil;
}

- (void)captureOrderWithID:(NSString *)orderID {
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token || !orderID) return;

    [self.spinner startAnimating];
    self.tableView.userInteractionEnabled = NO;

    NSURL *url = [NSURL URLWithString:[kStoreSupabaseURL
        stringByAppendingString:@"/functions/v1/capture-paypal-order"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"order_id": orderID
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.tableView.userInteractionEnabled = YES;

            if (error) {
                [self showAlert:@"Error" message:@"Could not confirm purchase. Check your balance — coins may still have been added."];
                [self refreshBalance];
                return;
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;

            if (http.statusCode == 200 && [json[@"success"] boolValue]) {
                NSInteger added   = [json[@"coins_added"] integerValue];
                NSInteger balance = [json[@"balance"] integerValue];
                [self showCoinCelebration:added newBalance:balance];
                [self refreshBalance];
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"EZSubscriptionUpdated" object:nil];
            } else {
                NSString *errMsg = json[@"error"] ?: @"Purchase could not be confirmed.";
                [self showAlert:@"Purchase Issue" message:errMsg];
                [self refreshBalance];
            }
        });
    }] resume];
}

// ── Coin celebration overlay ──────────────────────────────────────────────────

- (void)showCoinCelebration:(NSInteger)coinsAdded newBalance:(NSInteger)newBalance {
    // Dim overlay
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.alpha = 0;
    [self.view addSubview:overlay];

    // Card
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 320)];
    card.center = CGPointMake(self.view.bounds.size.width / 2,
                              self.view.bounds.size.height / 2);
    card.backgroundColor    = [UIColor colorWithRed:0.08 green:0.08 blue:0.14 alpha:1.0];
    card.layer.cornerRadius = 24;
    card.layer.borderWidth  = 1.5;
    card.layer.borderColor  = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.6].CGColor;
    card.transform          = CGAffineTransformMakeScale(0.7, 0.7);
    [overlay addSubview:card];

    // Pot view in card
    EZCoinPotView *pot = [[EZCoinPotView alloc] initWithFrame:CGRectMake(90, 20, 100, 110)];
    pot.coinImage = self.coinImage;
    [card addSubview:pot];
    self.storePotView = pot;

    // Title
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 138, 240, 30)];
    title.text          = @"🪙 Coins Added!";
    title.font          = [UIFont boldSystemFontOfSize:20];
    title.textColor     = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
    title.textAlignment = NSTextAlignmentCenter;
    [card addSubview:title];

    // Amount label
    UILabel *amountLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 172, 240, 28)];
    amountLabel.text          = [NSString stringWithFormat:@"+%ld coins", (long)coinsAdded];
    amountLabel.font          = [UIFont boldSystemFontOfSize:26];
    amountLabel.textColor     = [UIColor whiteColor];
    amountLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:amountLabel];

    // Balance label
    UILabel *balLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 204, 240, 22)];
    balLabel.text          = [NSString stringWithFormat:@"New balance: %ld coins", (long)newBalance];
    balLabel.font          = [UIFont systemFontOfSize:14];
    balLabel.textColor     = [UIColor secondaryLabelColor];
    balLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:balLabel];

    // Dismiss button
    UIButton *doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    doneBtn.frame           = CGRectMake(40, 248, 200, 44);
    doneBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
    doneBtn.layer.cornerRadius = 12;
    [doneBtn setTitle:@"Sweet!" forState:UIControlStateNormal];
    [doneBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    doneBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [doneBtn addTarget:self action:@selector(dismissCelebration:) forControlEvents:UIControlEventTouchUpInside];
    doneBtn.tag = 9900;
    [card addSubview:doneBtn];
    overlay.tag = 9901;

    // Animate in
    [UIView animateWithDuration:0.4
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:0
                     animations:^{
        overlay.alpha  = 1;
        card.transform = CGAffineTransformIdentity;
    } completion:^(BOOL done) {
        // Set pot to current fill before animation
        NSString *tier = [EZEntitlementManager shared].currentTier ?: @"basic";
        NSDictionary *tierCoins = @{@"basic":@400,@"standard":@900,@"pro":@1600,@"ultra":@2500};
        NSInteger included = [tierCoins[tier.lowercaseString] integerValue] ?: 400;
        [pot updateBalance:newBalance - coinsAdded includedCoins:included animated:NO];

        // Play coin toss then fill up
        [pot animateCoinToss:coinsAdded completion:^{
            [pot updateBalance:newBalance includedCoins:included animated:YES];
        }];
    }];
}

- (void)dismissCelebration:(UIButton *)sender {
    UIView *overlay = [self.view viewWithTag:9901];
    [UIView animateWithDuration:0.25 animations:^{
        overlay.alpha = 0;
    } completion:^(BOOL done) {
        [overlay removeFromSuperview];
        self.storePotView = nil;
    }];
}

// ── Utility ───────────────────────────────────────────────────────────────────

- (void)showAlert:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:title
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

@end
