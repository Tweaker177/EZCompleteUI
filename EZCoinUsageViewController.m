// EZCoinUsageViewController.m
// EZCompleteUI v6.5
//
// Changes from v6.4:
//   - Fixed: TTS rows showed "(67 × 0 ea.)" because quantity stores char count,
//     not a repeating unit — TTS now shows "−2 coins (67 chars)" instead
//
// Changes from v6.3:
//   - Fixed: quantity label was misleading — "−12 coins (2×)" implied 12 each,
//     but 12 was the total; now shows "−12 coins (2 × 6 ea.)" for clarity
//
// Changes from v6.2:
//   - Fixed: JWT (accessToken) now attached to get-usage-log request — was commented
//     out, causing edge function to return no rows for every user
//   - Fixed: idToken → accessToken to match EZAuthManager property name
//   - Fixed: network errors and JSON parse failures now surface to UI instead of
//     silently returning (was showing "No usage yet" for all failure modes)
//   - Fixed: emptyLabel text reset to "No usage yet" at start of each fresh fetch
//     so stale error messages don't persist across retries
//   - Added: raw response NSLog when JSON parse fails to aid edge function debugging

#import "EZCoinUsageViewController.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"

static NSString *const kSupabaseURL  = @"https://spuoimtqofhbdzosrbng.supabase.co";
static NSString *const kUsageCellID  = @"EZUsageCell";
static NSInteger const kPageSize     = 100;

// ── Colors & helpers ──────────────────────────────────────────────────────────

static UIColor *EZUBg(void)   { return [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:1]; }
static UIColor *EZUCard(void) { return [UIColor colorWithRed:0.09 green:0.09 blue:0.14 alpha:1]; }
static UIColor *EZUGold(void) { return [UIColor colorWithRed:1.0 green:0.84 blue:0.0  alpha:1]; }
static UIColor *EZUMuted(void){ return [UIColor colorWithWhite:0.45 alpha:1]; }

static NSString *friendlyFeatureName(NSString *feature) {
    NSDictionary *map = @{
        @"chat_mini":       @"AI Chat",
        @"chat_standard":   @"AI Chat",
        @"chat_premium":    @"AI Chat (Premium)",
        @"image_low":       @"Image Generation",
        @"image_medium":    @"Image Generation",
        @"image_high":      @"Image Generation (High Quality)",
        @"dalle3_standard": @"DALL·E Image",
        @"dalle3_hd":       @"DALL·E HD Image",
        @"sora_4s":         @"AI Video (4s)",
        @"sora_8s":         @"AI Video (8s)",
        @"sora_10s":        @"AI Video (10s)",
        @"sora_12s":        @"AI Video (12s)",
        @"sora_16s":        @"AI Video (16s)",
        @"sora_pro_4s":     @"AI Video Pro (4s)",
        @"sora_pro_8s":     @"AI Video Pro (8s)",
        @"sora_pro_10s":    @"AI Video Pro (10s)",
        @"sora_pro_12s":    @"AI Video Pro (12s)",
        @"sora_pro_16s":    @"AI Video Pro (16s)",
        @"tts":             @"Text to Speech",
        @"voice_clone":     @"Voice Clone",
        @"whisper_minute":  @"Voice Transcription",
        @"web_search":      @"Web Search",
    };
    return map[feature] ?: feature;
}

static NSString *featureIcon(NSString *feature) {
    if ([feature hasPrefix:@"chat"])    return @"💬";
    if ([feature hasPrefix:@"image"] ||
        [feature hasPrefix:@"dalle"])   return @"🖼";
    if ([feature hasPrefix:@"sora"])    return @"🎬";
    if ([feature isEqual:@"tts"])       return @"🔊";
    if ([feature isEqual:@"voice_clone"]) return @"🎤";
    if ([feature isEqual:@"whisper_minute"]) return @"🎙";
    if ([feature isEqual:@"web_search"]) return @"🔍";
    return @"🪙";
}

// ── NSNull-safe helpers ───────────────────────────────────────────────────────

static NSString *safeString(id value) {
    if (!value || value == (id)kCFNull) return @"";
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    if ([value respondsToSelector:@selector(description)]) {
        return [[value description] copy];
    }
    return @"";
}

static NSNumber *safeNumber(id value) {
    if (!value || value == (id)kCFNull) return nil;
    if ([value isKindOfClass:[NSNumber class]]) return (NSNumber *)value;
    if ([value isKindOfClass:[NSString class]]) {
        NSString *strValue = (NSString *)value;
        if (strValue.length == 0) return nil;
        return @([strValue longLongValue]);
    }
    return nil;
}

// ── Usage cell ────────────────────────────────────────────────────────────────

@interface EZUsageCell : UITableViewCell
- (void)configureWithRow:(NSDictionary *)row;
+ (CGFloat)rowHeight;
@end

@implementation EZUsageCell {
    UIView  *_card;
    UILabel *_iconLabel;
    UILabel *_featureLabel;
    UILabel *_promptLabel;
    UILabel *_coinsLabel;
    UILabel *_balanceLabel;
    UILabel *_timeLabel;
    UILabel *_detailLabel;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle  = UITableViewCellSelectionStyleNone;

    _card = [UIView new];
    _card.backgroundColor    = EZUCard();
    _card.layer.cornerRadius = 12;
    _card.layer.borderWidth  = 0.5;
    _card.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.07].CGColor;
    [self.contentView addSubview:_card];

    UILabel * (^lbl)(CGFloat, UIFontWeight, UIColor *, NSInteger) =
    ^UILabel *(CGFloat size, UIFontWeight weight, UIColor *color, NSInteger lines) {
        UILabel *label = [UILabel new];
        label.font          = [UIFont systemFontOfSize:size weight:weight];
        label.textColor     = color;
        label.numberOfLines = (int)lines;
        [self->_card addSubview:label];
        return label;
    };

    _iconLabel    = lbl(22, UIFontWeightRegular, [UIColor whiteColor], 1);
    _featureLabel = lbl(14, UIFontWeightSemibold,[UIColor whiteColor], 1);
    _promptLabel  = lbl(12, UIFontWeightRegular, [UIColor colorWithWhite:0.70 alpha:1], 2);
    _coinsLabel   = lbl(15, UIFontWeightBold,    [UIColor systemOrangeColor], 1);
    _balanceLabel = lbl(11, UIFontWeightRegular, EZUMuted(), 1);
    _timeLabel    = lbl(11, UIFontWeightRegular, EZUMuted(), 1);
    _detailLabel  = lbl(11, UIFontWeightRegular, [UIColor colorWithWhite:0.55 alpha:1], 1);

    return self;
}

- (void)configureWithRow:(NSDictionary *)row {
    NSString *feature  = safeString(row[@"feature"]);
    _iconLabel.text    = featureIcon(feature);
    _featureLabel.text = friendlyFeatureName(feature);

    NSString *prompt   = safeString(row[@"prompt"]);
    _promptLabel.text  = prompt.length ? prompt : @"";
    _promptLabel.hidden = (prompt.length == 0);

    NSInteger coins    = [safeNumber(row[@"coins_charged"]) integerValue];
    NSInteger balance  = [safeNumber(row[@"running_balance"]) integerValue];
    NSInteger qty      = [safeNumber(row[@"quantity"]) integerValue];

    // TTS stores character count in quantity, not a repeating unit — show chars instead
    if ([feature isEqualToString:@"tts"]) {
        _coinsLabel.text = qty > 0
            ? [NSString stringWithFormat:@"−%ld coins  (%ld chars)", (long)coins, (long)qty]
            : [NSString stringWithFormat:@"−%ld coins", (long)coins];
    } else if (qty > 1) {
        NSInteger coinsPerUnit = coins / qty;
        _coinsLabel.text = [NSString stringWithFormat:@"−%ld coins  (%ld × %ld ea.)",
            (long)coins, (long)qty, (long)coinsPerUnit];
    } else {
        _coinsLabel.text = [NSString stringWithFormat:@"−%ld coins", (long)coins];
    }
    _balanceLabel.text = [NSString stringWithFormat:@"Balance: %ld coins", (long)balance];

    // Detail line — images, tokens, model, error
    NSString *status = safeString(row[@"status"]);
    if ([status isEqualToString:@"error"]) {
        NSString *errorText = safeString(row[@"error_text"]);
        _detailLabel.text      = [NSString stringWithFormat:@"⚠️ %@", errorText.length ? errorText : @"Request failed"];
        _detailLabel.textColor = [UIColor systemOrangeColor];
    } else {
        NSMutableArray *parts = [NSMutableArray array];

        id imgReturned = row[@"images_returned"];
        if (imgReturned && imgReturned != (id)kCFNull && [imgReturned respondsToSelector:@selector(integerValue)]) {
            NSInteger imgCount = [imgReturned integerValue];
            if (imgCount > 0) {
                [parts addObject:[NSString stringWithFormat:@"%ld image%@",
                    (long)imgCount, imgCount == 1 ? @"" : @"s"]];
            }
        }

        id totalTokens = row[@"total_tokens"];
        if (totalTokens && totalTokens != (id)kCFNull && [totalTokens respondsToSelector:@selector(integerValue)]) {
            NSInteger tokenCount = [totalTokens integerValue];
            if (tokenCount > 0) {
                [parts addObject:[NSString stringWithFormat:@"%ld tokens", (long)tokenCount]];
            }
        }

        NSString *model = safeString(row[@"model"]);
        if (model.length) {
            [parts addObject:model];
        }

        _detailLabel.text      = [parts componentsJoinedByString:@"  ·  "];
        _detailLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    }

    // Timestamp
    NSString *isoTimestamp = safeString(row[@"created_at"]);
    if (isoTimestamp.length >= 19) {
        static NSDateFormatter *isoFormatter, *displayFormatter;
        static dispatch_once_t formatterOnce;
        dispatch_once(&formatterOnce, ^{
            isoFormatter = [NSDateFormatter new];
            isoFormatter.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            isoFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
            displayFormatter = [NSDateFormatter new];
            displayFormatter.locale     = [NSLocale currentLocale];
            displayFormatter.dateFormat = @"MMM d, h:mm a";
        });
        NSDate *parsedDate = [isoFormatter dateFromString:[isoTimestamp substringToIndex:19]];
        _timeLabel.text = parsedDate ? [displayFormatter stringFromDate:parsedDate] : isoTimestamp;
    } else {
        _timeLabel.text = isoTimestamp;
    }

    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat totalWidth  = self.contentView.bounds.size.width;
    CGFloat totalHeight = self.contentView.bounds.size.height;
    CGFloat padding     = 12;
    _card.frame = CGRectMake(12, 5, totalWidth - 24, totalHeight - 10);

    CGFloat cardWidth  = _card.bounds.size.width;
    CGFloat cardHeight = _card.bounds.size.height;

    _iconLabel.frame    = CGRectMake(padding, padding, 28, 28);
    _featureLabel.frame = CGRectMake(padding + 32, padding + 4, cardWidth - 160, 20);
    _timeLabel.frame    = CGRectMake(cardWidth - 130, padding + 4, 118, 16);

    CGFloat currentY = padding + 30;
    _promptLabel.frame  = CGRectMake(padding, currentY, cardWidth - padding * 2, 34);
    currentY += _promptLabel.hidden ? 4 : 38;

    _coinsLabel.frame   = CGRectMake(padding, currentY, 200, 20);
    _balanceLabel.frame = CGRectMake(padding, currentY + 22, 200, 15);
    _detailLabel.frame  = CGRectMake(padding, cardHeight - 18, cardWidth - padding * 2, 15);
}

+ (CGFloat)rowHeight { return 120; }

@end

// ── Summary header ────────────────────────────────────────────────────────────

@interface EZUsageSummaryView : UIView
- (void)configureWithBalance:(NSInteger)balance
                  totalCoins:(NSInteger)totalCoins
                  totalCalls:(NSInteger)totalCalls;
+ (CGFloat)height;
@end

@implementation EZUsageSummaryView {
    UILabel *_balanceLabel;
    UILabel *_usedLabel;
    UILabel *_callsLabel;
    UILabel *_hintLabel;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.backgroundColor = EZUBg();

    UILabel * (^lbl)(CGFloat, UIFontWeight, UIColor *, NSTextAlignment, NSInteger) =
    ^UILabel *(CGFloat size, UIFontWeight weight, UIColor *color, NSTextAlignment alignment, NSInteger lines) {
        UILabel *label = [UILabel new];
        label.font          = [UIFont systemFontOfSize:size weight:weight];
        label.textColor     = color;
        label.textAlignment = alignment;
        label.numberOfLines = (int)lines;
        [self addSubview:label];
        return label;
    };

    _balanceLabel = lbl(30, UIFontWeightBold,    EZUGold(), NSTextAlignmentCenter, 1);
    _usedLabel    = lbl(13, UIFontWeightMedium,  [UIColor colorWithWhite:0.7 alpha:1],
                        NSTextAlignmentCenter, 1);
    _callsLabel   = lbl(12, UIFontWeightRegular, EZUMuted(), NSTextAlignmentCenter, 1);
    _hintLabel    = lbl(11, UIFontWeightRegular, EZUMuted(), NSTextAlignmentCenter, 2);
    _hintLabel.text = @"This log shows every coin deduction in your account.\nKeep it as a record of usage.";

    UIView *dividerLine = [UIView new];
    dividerLine.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    dividerLine.tag = 99;
    [self addSubview:dividerLine];

    return self;
}

- (void)configureWithBalance:(NSInteger)balance
                  totalCoins:(NSInteger)totalCoins
                  totalCalls:(NSInteger)totalCalls {
    _balanceLabel.text = [NSString stringWithFormat:@"🪙 %ld coins", (long)balance];
    _usedLabel.text    = [NSString stringWithFormat:@"%ld coins used across %ld requests",
                          (long)totalCoins, (long)totalCalls];
    _callsLabel.text   = @"";
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat viewWidth = self.bounds.size.width;
    CGFloat padding   = 16;
    _balanceLabel.frame = CGRectMake(0, 16, viewWidth, 40);
    _usedLabel.frame    = CGRectMake(padding, 58, viewWidth - padding * 2, 20);
    _callsLabel.frame   = CGRectMake(padding, 80, viewWidth - padding * 2, 18);
    UIView *dividerLine = [self viewWithTag:99];
    dividerLine.frame   = CGRectMake(padding * 2, 104, viewWidth - padding * 4, 0.5);
    _hintLabel.frame    = CGRectMake(padding, 110, viewWidth - padding * 2, 32);
}

+ (CGFloat)height { return 150; }

@end

// ── Main VC ───────────────────────────────────────────────────────────────────

@interface EZCoinUsageViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView            *tableView;
@property (nonatomic, strong) EZUsageSummaryView     *summaryView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rows;
@property (nonatomic, assign) NSInteger               currentBalance;
@property (nonatomic, assign) BOOL                    loading;
@property (nonatomic, assign) BOOL                    hasMore;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel                *emptyLabel;
@property (nonatomic, assign) NSInteger               nextPage;
@end

@implementation EZCoinUsageViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = EZUBg();
    self.rows     = [NSMutableArray array];
    self.hasMore  = YES;
    self.nextPage = 0;

    [self styleNav];
    [self setupTable];
    [self fetchPage:self.nextPage];
}

- (void)styleNav {
    self.title = @"Coin Usage";

    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor        = EZUBg();
    appearance.titleTextAttributes    = @{NSForegroundColorAttributeName: UIColor.whiteColor};
    self.navigationItem.standardAppearance   = appearance;
    self.navigationItem.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.tintColor = UIColor.whiteColor;
}

- (void)setupTable {
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.delegate   = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor           = EZUBg();
    self.tableView.separatorStyle            = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight                 = [EZUsageCell rowHeight];
    self.tableView.alwaysBounceVertical      = YES;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    [self.tableView registerClass:EZUsageCell.class forCellReuseIdentifier:kUsageCellID];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];

    self.summaryView = [EZUsageSummaryView new];
    self.summaryView.frame = CGRectMake(0, 0, self.view.bounds.size.width, [EZUsageSummaryView height]);
    self.tableView.tableHeaderView = self.summaryView;

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = [UIColor colorWithWhite:1 alpha:0.7];
    self.spinner.hidesWhenStopped = YES;
    UIView *footerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 60)];
    self.spinner.center = CGPointMake(footerView.bounds.size.width / 2.0,
                                      footerView.bounds.size.height / 2.0);
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [footerView addSubview:self.spinner];
    self.tableView.tableFooterView = footerView;

    self.emptyLabel = [UILabel new];
    self.emptyLabel.text          = @"No usage yet";
    self.emptyLabel.textColor     = [UIColor colorWithWhite:0.7 alpha:1];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 2;
    self.emptyLabel.hidden        = YES;
    self.emptyLabel.frame = CGRectMake(20, self.view.bounds.size.height / 3.0,
                                       self.view.bounds.size.width - 40, 60);
    self.emptyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                       UIViewAutoresizingFlexibleTopMargin |
                                       UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.emptyLabel];
}

- (void)updateSummary {
    NSInteger totalCoins = 0;
    for (NSDictionary *row in self.rows) {
        totalCoins += [safeNumber(row[@"coins_charged"]) integerValue];
    }
    [self.summaryView configureWithBalance:self.currentBalance
                                totalCoins:totalCoins
                                totalCalls:(NSInteger)self.rows.count];
}

- (void)fetchPage:(NSInteger)page {
    if (self.loading || !self.hasMore) return;
    self.loading = YES;
    [self.spinner startAnimating];

    // Reset stale error text on fresh fetches so it doesn't persist across retries
    if (page == 0) {
        self.emptyLabel.text   = @"No usage yet";
        self.emptyLabel.hidden = YES;
    }

    // Verify the user is logged in before hitting the network
    NSString *accessToken = [EZAuthManager shared].accessToken;
    if (!accessToken.length) {
        self.loading = NO;
        [self.spinner stopAnimating];
        self.emptyLabel.text   = @"Please sign in to view usage";
        self.emptyLabel.hidden = NO;
        return;
    }

    NSURLComponents *urlComponents = [NSURLComponents componentsWithString:
        [kSupabaseURL stringByAppendingString:@"/functions/v1/get-usage-log"]];
    urlComponents.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"page"  value:[NSString stringWithFormat:@"%ld", (long)page]],
        [NSURLQueryItem queryItemWithName:@"limit" value:[NSString stringWithFormat:@"%ld", (long)kPageSize]]
    ];
    NSURL *requestURL = urlComponents.URL ?:
        [NSURL URLWithString:[kSupabaseURL stringByAppendingString:@"/functions/v1/get-usage-log"]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:requestURL];
    req.HTTPMethod      = @"GET";
    req.timeoutInterval = 15;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", accessToken]
       forHTTPHeaderField:@"Authorization"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.loading = NO;
                [self.spinner stopAnimating];
                if (self.rows.count == 0) {
                    self.emptyLabel.text = [NSString stringWithFormat:
                        @"Couldn't load usage\n%@", error.localizedDescription];
                    self.emptyLabel.hidden = NO;
                }
            });
            return;
        }

        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data]
                                                  options:0
                                                    error:&jsonError];
        if (jsonError || !json) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.loading = NO;
                [self.spinner stopAnimating];
                NSString *rawResponse = [[NSString alloc] initWithData:data
                                                              encoding:NSUTF8StringEncoding];
                NSLog(@"[EZCoinUsage] Non-JSON response from get-usage-log: %@", rawResponse);
                if (self.rows.count == 0) {
                    self.emptyLabel.text   = @"Couldn't load usage\nUnexpected server response";
                    self.emptyLabel.hidden = NO;
                }
            });
            return;
        }

        NSMutableArray<NSDictionary *> *newRows = [NSMutableArray array];
        BOOL hasMorePages  = NO;
        NSInteger balance  = self.currentBalance;

        if ([json isKindOfClass:[NSDictionary class]]) {
            NSDictionary *responseDict = (NSDictionary *)json;
            id rowsValue = responseDict[@"rows"];
            if ([rowsValue isKindOfClass:[NSArray class]]) {
                for (id item in (NSArray *)rowsValue) {
                    if ([item isKindOfClass:[NSDictionary class]]) {
                        [newRows addObject:item];
                    }
                }
            }
            NSNumber *balanceNumber = safeNumber(responseDict[@"balance"]);
            if (balanceNumber) balance = [balanceNumber integerValue];
            id hasMoreValue = responseDict[@"has_more"];
            if ([hasMoreValue isKindOfClass:[NSNumber class]]) {
                hasMorePages = [hasMoreValue boolValue];
            }
        } else if ([json isKindOfClass:[NSArray class]]) {
            // Flat array fallback — edge function returned rows directly
            for (id item in (NSArray *)json) {
                if ([item isKindOfClass:[NSDictionary class]]) {
                    [newRows addObject:item];
                }
            }
            NSDictionary *lastRow = newRows.lastObject;
            if (lastRow) {
                NSNumber *balanceNumber = safeNumber(lastRow[@"running_balance"]);
                if (balanceNumber) balance = [balanceNumber integerValue];
            }
            hasMorePages = (newRows.count == kPageSize);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;
            [self.spinner stopAnimating];

            if (page == 0) {
                [self.rows removeAllObjects];
            }

            if (newRows.count > 0) {
                [self.rows addObjectsFromArray:newRows];
                self.nextPage          = page + 1;
                self.emptyLabel.hidden = YES;
            } else if (self.rows.count == 0) {
                self.emptyLabel.text   = @"No usage yet";
                self.emptyLabel.hidden = NO;
            }

            self.currentBalance = balance;
            self.hasMore        = hasMorePages;

            [self updateSummary];
            [self.tableView reloadData];
        });
    }] resume];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EZUsageCell *cell = [tableView dequeueReusableCellWithIdentifier:kUsageCellID
                                                        forIndexPath:indexPath];
    [cell configureWithRow:self.rows[indexPath.row]];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [EZUsageCell rowHeight];
}

- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    // Infinite scroll — start fetching the next page 5 rows before the end
    NSInteger triggerIndex = MAX(0, (NSInteger)self.rows.count - 5);
    if (indexPath.row >= triggerIndex && self.hasMore && !self.loading) {
        [self fetchPage:self.nextPage];
    }
}

@end
