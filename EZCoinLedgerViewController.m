 //
//  EZCoinLedgerViewController.m
//  EZCompleteUI
//
//  Dark, scrollable usage ledger. Fetches from /functions/v1/get-usage-log.
//  Each row shows: feature, model, prompt snippet, coins charged, token counts,
//  image count, api cost estimate, cost/100 coins efficiency, and timestamp.
//  Summary header shows totals and the global cost/100 coins metric.

#import "EZCoinLedgerViewController.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"

static NSString *const kSupabaseURL  = @"https://spuoimtqofhbdzosrbng.supabase.co";
static NSString *const kLedgerCellID = @"EZLedgerCell";

// Coin pricing breakevens ($ per 100 coins) — matches edge function constants
static double const kBreakevenBest  = 0.80;   // Ultra tier
static double const kBreakevenWorst = 1.25;   // Basic tier

// ── Colors ────────────────────────────────────────────────────────────────────

static UIColor *EZGold(void)   { return [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0]; }
static UIColor *EZBg(void)     { return [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:1.0]; }
static UIColor *EZCard(void)   { return [UIColor colorWithRed:0.09 green:0.09 blue:0.14 alpha:1.0]; }
static UIColor *EZMuted(void)  { return [UIColor colorWithWhite:0.45 alpha:1]; }

// ── Efficiency color ──────────────────────────────────────────────────────────
// Green = profitable, yellow = borderline, red = losing money

static UIColor *efficiencyColor(double costPer100) {
    if (costPer100 <= kBreakevenBest)  return [UIColor systemGreenColor];
    if (costPer100 <= kBreakevenWorst) return [UIColor systemOrangeColor];
    return [UIColor systemRedColor];
}

// ── Date formatter ────────────────────────────────────────────────────────────

static NSDateFormatter *sharedFormatter(void) {
    static NSDateFormatter *fmt;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        fmt = [NSDateFormatter new];
        fmt.locale     = [NSLocale currentLocale];
        fmt.dateFormat = @"MMM d, h:mm a";
    });
    return fmt;
}

// ── Ledger row cell ───────────────────────────────────────────────────────────

@interface EZLedgerCell : UITableViewCell
- (void)configureWithRow:(NSDictionary *)row;
@end

@implementation EZLedgerCell {
    UIView  *_card;
    UILabel *_featureLabel;
    UILabel *_modelLabel;
    UILabel *_promptLabel;
    UILabel *_coinsLabel;
    UILabel *_balanceLabel;
    UILabel *_tokensLabel;
    UILabel *_imagesLabel;
    UILabel *_costLabel;
    UILabel *_effLabel;
    UILabel *_timeLabel;
    UIView  *_statusDot;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle  = UITableViewCellSelectionStyleNone;

    _card = [UIView new];
    _card.backgroundColor    = EZCard();
    _card.layer.cornerRadius = 12;
    _card.layer.borderWidth  = 0.5;
    _card.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    [self.contentView addSubview:_card];
   
    UILabel* (^makeLabel)(CGFloat, UIFontWeight, UIColor *, NSInteger) = ^UILabel *(CGFloat size, UIFontWeight weight, UIColor *color, NSInteger lines) {
        UILabel *l = [UILabel new];
        l.font          = [UIFont systemFontOfSize:size weight:weight];
        l.textColor     = color;
        l.numberOfLines = (int)lines;
        [self->_card addSubview:l];
        return l;
    };

    _featureLabel = makeLabel(13, UIFontWeightBold,    EZGold(),                         1);
    _modelLabel   = makeLabel(11, UIFontWeightRegular, EZMuted(),                        1);
    _promptLabel  = makeLabel(12, UIFontWeightRegular, [UIColor colorWithWhite:0.8 alpha:1], 2);
    _coinsLabel   = makeLabel(14, UIFontWeightBold,    [UIColor systemOrangeColor],      1);
    _balanceLabel = makeLabel(11, UIFontWeightRegular, EZMuted(),                        1);
    _tokensLabel  = makeLabel(11, UIFontWeightRegular, [UIColor colorWithWhite:0.6 alpha:1], 1);
    _imagesLabel  = makeLabel(11, UIFontWeightRegular, [UIColor colorWithWhite:0.6 alpha:1], 1);
    _costLabel    = makeLabel(11, UIFontWeightRegular, EZMuted(),                        1);
    _effLabel     = makeLabel(12, UIFontWeightBold,    [UIColor systemGreenColor],       1);
    _timeLabel    = makeLabel(10, UIFontWeightRegular, EZMuted(),                        1);

    _statusDot = [UIView new];
    _statusDot.layer.cornerRadius = 4;
    [_card addSubview:_statusDot];

    return self;
}

- (void)configureWithRow:(NSDictionary *)row {
    // Helper: return an NSString for common types, never NSNull or nil.
    NSString *(^S)(id) = ^NSString *(id v) {
        if (v == nil || v == (id)[NSNull null]) return @"";
        if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
        if ([v respondsToSelector:@selector(stringValue)]) return [v stringValue];
        return @"";
    };

    // Feature + model
    NSString *feature = S(row[@"feature"]);
    NSString *model   = S(row[@"model"]);
    _featureLabel.text = [self friendlyFeature:feature.length ? feature : @"unknown"];
    _modelLabel.text   = model.length ? model : @"";

    // Prompt
    NSString *prompt = S(row[@"prompt"]);
    _promptLabel.text = prompt.length ? prompt : @"(no prompt recorded)";
    _promptLabel.textColor = prompt.length
        ? [UIColor colorWithWhite:0.78 alpha:1] : EZMuted();

    // Coins + balance
    NSInteger coins   = [row[@"coins_charged"] integerValue];
    NSInteger balance = [row[@"running_balance"] integerValue];
    NSInteger qty     = [row[@"quantity"] integerValue];
    _coinsLabel.text  = qty > 1
        ? [NSString stringWithFormat:@"−%ld coins ×%ld", (long)coins, (long)qty]
        : [NSString stringWithFormat:@"−%ld coins", (long)coins];
    _balanceLabel.text = [NSString stringWithFormat:@"Balance after: %ld", (long)balance];

    // Tokens
    id inTok  = row[@"input_tokens"];
    id outTok = row[@"output_tokens"];
    if (inTok && ![inTok isKindOfClass:[NSNull class]]) {
        _tokensLabel.text = [NSString stringWithFormat:@"In: %@ / Out: %@ tokens", inTok, outTok];
    } else {
        _tokensLabel.text = @"";
    }

    // Images
    id imgRet = row[@"images_returned"];
    id imgReq = row[@"images_requested"];
    if (imgRet && ![imgRet isKindOfClass:[NSNull class]]) {
        _imagesLabel.text = [NSString stringWithFormat:@"Images: %@ returned / %@ requested",
                             imgRet, imgReq ?: @"?"];
    } else {
        _imagesLabel.text = @"";
    }

    // API cost
    id apiCost = row[@"api_cost_usd"];
    if (apiCost && ![apiCost isKindOfClass:[NSNull class]]) {
        double cost = [apiCost doubleValue];
        _costLabel.text = [NSString stringWithFormat:@"API cost: $%.4f", cost];
    } else {
        _costLabel.text = @"";
    }

    // Cost per 100 coins
    id eff = row[@"cost_per_100_coins"];
    if (eff && ![eff isKindOfClass:[NSNull class]]) {
        double effVal = [eff doubleValue];
        _effLabel.text      = [NSString stringWithFormat:@"$%.4f / 100 coins", effVal];
        _effLabel.textColor = efficiencyColor(effVal);
    } else {
        _effLabel.text      = @"—";
        _effLabel.textColor = EZMuted();
    }

    // Timestamp
    NSString *isoDate = S(row[@"created_at"]);
    if (isoDate.length >= 19) {
        NSDateFormatter *iso = [NSDateFormatter new];
        iso.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
        NSDate *date   = [iso dateFromString:[isoDate substringToIndex:19]];
        _timeLabel.text = date ? [sharedFormatter() stringFromDate:date] : isoDate;
    } else {
        _timeLabel.text = isoDate;
    }

    // Status dot
    NSString *status = S(row[@"status"]);
    if (status.length == 0) status = @"complete";
    if ([status isEqualToString:@"pending"]) {
        _statusDot.backgroundColor = [UIColor systemYellowColor];
    } else if ([status isEqualToString:@"error"]) {
        _statusDot.backgroundColor = [UIColor systemRedColor];
    } else {
        _statusDot.backgroundColor = [UIColor systemGreenColor];
    }

    [self setNeedsLayout];
}

- (NSString *)friendlyFeature:(NSString *)f {
    NSDictionary *map = @{
        @"chat_mini":       @"💬 Chat Mini",
        @"chat_standard":   @"💬 Chat Standard",
        @"chat_premium":    @"💬 Chat Premium",
        @"image_low":       @"🖼 Image — Low",
        @"image_medium":    @"🖼 Image — Medium",
        @"image_high":      @"🖼 Image — High",
        @"dalle3_standard": @"🖼 DALL-E 3",
        @"dalle3_hd":       @"🖼 DALL-E 3 HD",
        @"sora_10s":        @"🎬 Sora 10s",
        @"sora_pro_10s":    @"🎬 Sora Pro 10s",
        @"tts":             @"🔊 TTS",
        @"voice_clone":     @"🎤 Voice Clone",
        @"whisper_minute":  @"🎙 Whisper",
        @"web_search":      @"🔍 Web Search",
    };
    return map[f] ?: f;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W   = self.contentView.bounds.size.width;
    CGFloat pad = 12;
    _card.frame = CGRectMake(12, 6, W - 24, self.contentView.bounds.size.height - 12);

    CGFloat cW  = _card.bounds.size.width;
    CGFloat x   = pad, y = pad;

    // Status dot
    _statusDot.frame = CGRectMake(cW - pad - 8, pad, 8, 8);

    // Feature + model row
    _featureLabel.frame = CGRectMake(x, y, cW - 60, 18);
    _modelLabel.frame   = CGRectMake(x, y + 20, cW * 0.6, 15);
    _timeLabel.frame    = CGRectMake(cW - 110, y, 100, 15);
    y += 38;

    // Prompt
    _promptLabel.frame  = CGRectMake(x, y, cW - x * 2, 36);
    y += 40;

    // Coins + balance
    _coinsLabel.frame   = CGRectMake(x, y, 160, 20);
    _balanceLabel.frame = CGRectMake(x, y + 22, 200, 15);
    y += 40;

    // Efficiency — right aligned, large
    _effLabel.frame     = CGRectMake(cW - 180, y - 40, 168, 20);

    // Tokens + images
    _tokensLabel.frame  = CGRectMake(x, y, cW - x * 2, 15);
    y += 18;
    _imagesLabel.frame  = CGRectMake(x, y, cW - x * 2, 15);
    y += 18;
    _costLabel.frame    = CGRectMake(x, y, cW - x * 2, 15);
}

+ (CGFloat)rowHeight { return 178; }

@end

// ── Summary header view ───────────────────────────────────────────────────────

@interface EZLedgerSummaryView : UIView
- (void)configureWithAggregate:(NSDictionary *)agg currentBalance:(NSInteger)balance;
@end

@implementation EZLedgerSummaryView {
    UILabel *_balanceLabel;
    UILabel *_totalCoinsLabel;
    UILabel *_totalCostLabel;
    UILabel *_globalEffLabel;
    UILabel *_marginLabel;
    UILabel *_totalCallsLabel;
    UILabel *_totalImagesLabel;
    UILabel *_totalTokensLabel;
    UILabel *_subtitleLabel;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.backgroundColor = EZBg();

    UILabel* (^label)(CGFloat, UIFontWeight, UIColor *, NSTextAlignment) =
    ^UILabel *(CGFloat size, UIFontWeight w, UIColor *c, NSTextAlignment align) {
        UILabel *l = [UILabel new];
        l.font          = [UIFont systemFontOfSize:size weight:w];
        l.textColor     = c;
        l.textAlignment = align;
        l.numberOfLines = 2;
        [self addSubview:l];
        return l;
    };

    _balanceLabel    = label(28, UIFontWeightBold,    EZGold(),                       NSTextAlignmentCenter);
    _subtitleLabel   = label(12, UIFontWeightRegular, EZMuted(),                      NSTextAlignmentCenter);
    _globalEffLabel  = label(20, UIFontWeightBold,    [UIColor systemGreenColor],     NSTextAlignmentCenter);
    _marginLabel     = label(12, UIFontWeightRegular, [UIColor colorWithWhite:0.6 alpha:1], NSTextAlignmentCenter);

    _totalCoinsLabel = label(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalCostLabel  = label(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalCallsLabel = label(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalImagesLabel= label(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalTokensLabel= label(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);

    // Gold divider
    UIView *div = [UIView new];
    div.backgroundColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.25];
    div.tag = 99;
    [self addSubview:div];

    return self;
}

- (void)configureWithAggregate:(NSDictionary *)agg currentBalance:(NSInteger)balance {
    _balanceLabel.text  = [NSString stringWithFormat:@"🪙 %ld coins", (long)balance];
    _subtitleLabel.text = @"Current Balance";

    NSInteger totalCoins   = [agg[@"total_coins_charged"] integerValue];
    double    totalCostUsd = [agg[@"total_api_cost_usd"]  doubleValue];
    NSInteger totalCalls   = [agg[@"total_calls"]         integerValue];
    NSInteger totalImages  = [agg[@"total_images"]        integerValue];
    NSInteger totalTokens  = [agg[@"total_tokens"]        integerValue];

    id cPer100 = agg[@"cost_per_100_coins"];
    if (cPer100 && ![cPer100 isKindOfClass:[NSNull class]]) {
        double eff = [cPer100 doubleValue];
        _globalEffLabel.text      = [NSString stringWithFormat:@"$%.4f / 100 coins", eff];
        _globalEffLabel.textColor = efficiencyColor(eff);

        // Implied margin at average tier ($1.00 per 100 coins)
        double revenue = totalCoins * 0.0100;
        double margin  = revenue > 0 ? (revenue - totalCostUsd) / revenue * 100 : 0;
        _marginLabel.text = [NSString stringWithFormat:
            @"Implied margin (avg tier): %.1f%%   |   Breakeven: $%.2f–$%.2f",
            margin, kBreakevenBest, kBreakevenWorst];
        _marginLabel.textColor = margin >= 0 ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    } else {
        _globalEffLabel.text  = @"No data yet";
        _marginLabel.text     = @"";
    }

    _totalCoinsLabel.text  = [NSString stringWithFormat:@"Coins used\n%ld", (long)totalCoins];
    _totalCostLabel.text   = [NSString stringWithFormat:@"API cost\n$%.4f", totalCostUsd];
    _totalCallsLabel.text  = [NSString stringWithFormat:@"Calls\n%ld",   (long)totalCalls];
    _totalImagesLabel.text = [NSString stringWithFormat:@"Images\n%ld",  (long)totalImages];
    _totalTokensLabel.text = [NSString stringWithFormat:@"Tokens\n%ld",  (long)totalTokens];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W   = self.bounds.size.width;
    CGFloat pad = 16;

    _balanceLabel.frame   = CGRectMake(0, 16, W, 36);
    _subtitleLabel.frame  = CGRectMake(0, 54, W, 18);

    // Gold divider
    UIView *div = [self viewWithTag:99];
    div.frame = CGRectMake(pad * 2, 78, W - pad * 4, 0.5);

    _globalEffLabel.frame = CGRectMake(0, 86, W, 28);
    _marginLabel.frame    = CGRectMake(pad, 116, W - pad * 2, 30);

    // 5-column stats grid
    CGFloat colW = W / 5;
    NSArray *stats = @[_totalCoinsLabel, _totalCostLabel, _totalCallsLabel,
                       _totalImagesLabel, _totalTokensLabel];
    for (NSInteger i = 0; i < (NSInteger)stats.count; i++) {
        ((UILabel *)stats[(NSUInteger)i]).frame = CGRectMake(colW * i, 152, colW, 36);
    }
}

+ (CGFloat)height { return 196; }

@end

// ── Main VC ───────────────────────────────────────────────────────────────────

@interface EZCoinLedgerViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView          *tableView;
@property (nonatomic, strong) EZLedgerSummaryView  *summaryView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSDictionary         *aggregate;
@property (nonatomic, assign) NSInteger             currentBalance;
@property (nonatomic, assign) BOOL                  loading;
@property (nonatomic, assign) BOOL                  hasMore;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel               *emptyLabel;
@end

@implementation EZCoinLedgerViewController

static NSInteger const kPageSize = 50;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Coin Ledger";
    self.view.backgroundColor = EZBg();
    self.rows      = [NSMutableArray array];
    self.hasMore   = YES;
    self.loading   = NO;

    [self styleNav];
    [self setupTable];
    [self fetchPage:0];
}

- (void)styleNav {
    UINavigationBarAppearance *a = [UINavigationBarAppearance new];
    [a configureWithOpaqueBackground];
    a.backgroundColor = EZBg();
    a.titleTextAttributes = @{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName: [UIFont boldSystemFontOfSize:17],
    };
    self.navigationController.navigationBar.standardAppearance   = a;
    self.navigationController.navigationBar.scrollEdgeAppearance = a;
    self.navigationController.navigationBar.tintColor = EZGold();

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self action:@selector(closeTapped)];
    self.navigationItem.leftBarButtonItem.tintColor = [UIColor colorWithWhite:0.6 alpha:1];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self action:@selector(refreshTapped)];
}

- (void)setupTable {
    self.summaryView = [EZLedgerSummaryView new];
    self.summaryView.frame = CGRectMake(0, 0, self.view.bounds.size.width,
                                        [EZLedgerSummaryView height]);

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor  = EZBg();
    self.tableView.separatorStyle   = UITableViewCellSeparatorStyleNone;
    self.tableView.tableHeaderView  = self.summaryView;
    self.tableView.delegate         = self;
    self.tableView.dataSource       = self;
    self.tableView.rowHeight        = [EZLedgerCell rowHeight];
    [self.tableView registerClass:[EZLedgerCell class]
           forCellReuseIdentifier:kLedgerCellID];
    [self.view addSubview:self.tableView];

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = EZGold();
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center = self.view.center;
    [self.view addSubview:self.spinner];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.text          = @"No transactions yet.";
    self.emptyLabel.textColor     = EZMuted();
    self.emptyLabel.font          = [UIFont systemFontOfSize:15];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.hidden        = YES;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

// ── Fetch ─────────────────────────────────────────────────────────────────────

- (void)fetchPage:(NSInteger)offset {
    if (self.loading) return;
    self.loading = YES;
    if (offset == 0) [self.spinner startAnimating];

    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) { [self.spinner stopAnimating]; self.loading = NO; return; }

    NSString *urlStr = [NSString stringWithFormat:
        @"%@/functions/v1/get-usage-log?limit=%ld&offset=%ld",
        kSupabaseURL, (long)kPageSize, (long)offset];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.loading = NO;

            if (!data || err) return;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *newRows   = json[@"rows"];
            NSDictionary *agg  = json[@"aggregate"];

            if (offset == 0) [self.rows removeAllObjects];
            if ([newRows isKindOfClass:[NSArray class]]) {
                [self.rows addObjectsFromArray:newRows];
                self.hasMore = ((NSInteger)newRows.count == kPageSize);
            }
            if ([agg isKindOfClass:[NSDictionary class]]) {
                self.aggregate = agg;
                self.currentBalance = [EZEntitlementManager shared].coinBalance;
                [self.summaryView configureWithAggregate:agg currentBalance:self.currentBalance];
            }

            [self.tableView reloadData];
            self.emptyLabel.hidden = self.rows.count > 0;
        });
    }] resume];
}

// ── UITableView ───────────────────────────────────────────────────────────────

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    EZLedgerCell *cell = [tv dequeueReusableCellWithIdentifier:kLedgerCellID forIndexPath:ip];
    [cell configureWithRow:self.rows[(NSUInteger)ip.row]];
    return cell;
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)ip {
    // Paginate — load next page when near bottom
    if (self.hasMore && !self.loading &&
        ip.row == (NSInteger)self.rows.count - 5) {
        [self fetchPage:(NSInteger)self.rows.count];
    }
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)refreshTapped {
    self.hasMore = YES;
    [self fetchPage:0];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
