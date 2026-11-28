// BRRouletteLobbyViewController.m
// EZCompleteUI v1.1
//
// Purpose:
//   See BRRouletteLobbyViewController.h. Table data comes from the br-roulette
//   "list_tables" action. The list refreshes every few seconds while the
//   screen is visible and via pull-to-refresh, and shows a retry message
//   instead of a blank screen when the request fails.
//
// Changes from v1:
//   - The plain table list is now a set of casino table cards in the style
//     of the blackjack lobby: a hero header, one card per wheel with a
//     drawn roulette wheel in the tier's colors, its bet range, the
//     straight-up payout, and a round gold join button whose face carries
//     the seated count. The balance sits in a pill in the navigation bar
//     and opens the coin store.
//   - Every player-facing string goes through NSLocalizedStringWithDefaultValue
//     (keys BRRoulette.*), with the English text as the default value.

#import "BRRouletteLobbyViewController.h"
#import "BRRouletteAPI.h"
#import "BRRouletteTableViewController.h"
#import "EZCoinStoreViewController.h"

static const NSTimeInterval kRouletteLobbyRefreshInterval = 5.0;

static NSInteger BRRouletteLobbyInt(id value) { return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0; }
static BOOL BRRouletteLobbyBool(id value) { return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO; }
static NSString *BRRouletteLobbyString(id value) { return [value isKindOfClass:[NSString class]] ? value : @""; }

static UIColor *BRRouletteLobbyGold(void) { return [UIColor colorWithRed:.85 green:.67 blue:.33 alpha:1]; }
static UIColor *BRRouletteLobbyGoldDim(void) { return [BRRouletteLobbyGold() colorWithAlphaComponent:.55]; }

static NSString *BRRouletteLobbyGrouped(NSInteger value) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatter = [NSNumberFormatter new]; formatter.numberStyle = NSNumberFormatterDecimalStyle; });
    return [formatter stringFromNumber:@(value)] ?: [NSString stringWithFormat:@"%ld", (long)value];
}

#pragma mark - Wheel drawing

/// A roulette wheel drawn in code: gold rim, alternating red and black
/// pockets with a single green zero, and a gold-ringed hub. Stays sharp
/// at any size.
@interface BRRouletteLobbyWheelView : UIView
@end

@implementation BRRouletteLobbyWheelView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) self.backgroundColor = UIColor.clearColor;
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGFloat radius = MIN(rect.size.width, rect.size.height) / 2 - 2;
    if (radius <= 0) return;
    CGContextSetFillColorWithColor(ctx, BRRouletteLobbyGold().CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(center.x - radius, center.y - radius, radius * 2, radius * 2));
    CGFloat pocketRadius = radius * .82;
    NSInteger pockets = 12;
    for (NSInteger i = 0; i < pockets; i++) {
        CGFloat start = (CGFloat)(i * 2 * M_PI / pockets) - (CGFloat)M_PI_2;
        CGFloat end = (CGFloat)((i + 1) * 2 * M_PI / pockets) - (CGFloat)M_PI_2;
        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, center.x, center.y);
        CGContextAddArc(ctx, center.x, center.y, pocketRadius, start, end, 0);
        CGContextClosePath(ctx);
        UIColor *color = i == 0 ? [UIColor colorWithRed:.05 green:.45 blue:.20 alpha:1]
                        : (i % 2 ? [UIColor colorWithRed:.55 green:.08 blue:.10 alpha:1]
                                 : [UIColor colorWithRed:.05 green:.05 blue:.06 alpha:1]);
        CGContextSetFillColorWithColor(ctx, color.CGColor);
        CGContextFillPath(ctx);
    }
    CGFloat hub = radius * .34;
    CGRect hubRect = CGRectMake(center.x - hub, center.y - hub, hub * 2, hub * 2);
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:.10 green:.08 blue:.05 alpha:1].CGColor);
    CGContextFillEllipseInRect(ctx, hubRect);
    CGContextSetStrokeColorWithColor(ctx, BRRouletteLobbyGold().CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeEllipseInRect(ctx, hubRect);
}

@end

/// A view backed by a gradient layer that always matches its bounds.
@interface BRRouletteLobbyGradientView : UIView
@end

@implementation BRRouletteLobbyGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
        gradient.colors = @[ (id)[UIColor colorWithRed:.23 green:.04 blue:.06 alpha:1].CGColor,
                             (id)[UIColor colorWithRed:.05 green:.015 blue:.02 alpha:1].CGColor ];
        gradient.startPoint = CGPointMake(0, 0);
        gradient.endPoint = CGPointMake(1, 1);
    }
    return self;
}
@end

#pragma mark - Controller

@interface BRRouletteLobbyViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *tables;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic) NSInteger balance;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic) BOOL loading;
@property (nonatomic, strong) UIButton *balancePill;
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
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.refreshControl = [UIRefreshControl new];
    self.refreshControl.tintColor = BRRouletteLobbyGold();
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];

    // Balance pill in the top bar, in the style of the blackjack lobby;
    // tapping it opens the coin store.
    UIButton *pill = [UIButton buttonWithType:UIButtonTypeCustom];
    pill.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [pill setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    pill.contentEdgeInsets = UIEdgeInsetsMake(5, 12, 5, 12);
    pill.layer.cornerRadius = 14;
    pill.layer.borderWidth = 1;
    pill.layer.borderColor = BRRouletteLobbyGoldDim().CGColor;
    pill.backgroundColor = [UIColor colorWithWhite:1 alpha:.06];
    [pill addTarget:self action:@selector(balancePillTapped) forControlEvents:UIControlEventTouchUpInside];
    self.balancePill = pill;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:pill];
    [self updateBalancePill];
}

- (void)updateBalancePill {
    NSString *title = [NSString stringWithFormat:@"🪙 %@  +", BRRouletteLobbyGrouped(self.balance)];
    [self.balancePill setTitle:title forState:UIControlStateNormal];
    [self.balancePill sizeToFit];
}

- (void)balancePillTapped {
    EZCoinStoreViewController *store = [[EZCoinStoreViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:store];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
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
            self.errorMessage = error;
        } else {
            self.errorMessage = nil;
            NSArray *rows = [json[@"tables"] isKindOfClass:[NSArray class]] ? json[@"tables"] : @[];
            NSMutableArray<NSDictionary *> *clean = [NSMutableArray new];
            for (id row in rows) if ([row isKindOfClass:[NSDictionary class]]) [clean addObject:row];
            self.tables = clean;
            self.balance = BRRouletteLobbyInt(json[@"balance"]);
            [self updateBalancePill];
        }
        [self.tableView reloadData];
    }];
}

#pragma mark Rows

// Row layout: 0 = hero, 1..tables.count = cards, last = footer. With no
// tables loaded, row 1 is the loading / error row.
- (BOOL)isHeroRow:(NSIndexPath *)indexPath { return indexPath.row == 0; }
- (BOOL)isFooterRow:(NSIndexPath *)indexPath {
    NSInteger last = [self tableView:self.tableView numberOfRowsInSection:0] - 1;
    return indexPath.row == last && self.tables.count > 0;
}
- (NSInteger)tableIndexForRow:(NSInteger)row { return row - 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.tables.count > 0 ? (NSInteger)self.tables.count + 2 : 2;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isHeroRow:indexPath]) return 208;
    if ([self isFooterRow:indexPath]) return 46;
    if (self.tables.count == 0) return 84;
    return 128;
}

#pragma mark Cells

- (UILabel *)labelWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = font;
    label.textColor = color;
    return label;
}

- (UITableViewCell *)heroCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = UIColor.clearColor;

    UIView *banner = [[BRRouletteLobbyGradientView alloc] initWithFrame:CGRectZero];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.layer.cornerRadius = 16;
    banner.layer.masksToBounds = YES;
    banner.layer.borderWidth = 1;
    banner.layer.borderColor = [BRRouletteLobbyGold() colorWithAlphaComponent:.35].CGColor;
    [cell.contentView addSubview:banner];

    BRRouletteLobbyWheelView *watermark = [BRRouletteLobbyWheelView new];
    watermark.translatesAutoresizingMaskIntoConstraints = NO;
    watermark.alpha = .16;
    [banner addSubview:watermark];

    UILabel *wheel = [self labelWithText:@"🎡" font:[UIFont systemFontOfSize:20] color:UIColor.whiteColor];
    wheel.textAlignment = NSTextAlignmentCenter;
    [banner addSubview:wheel];

    UILabel *headline = [self labelWithText:NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.HeroTitle", nil, NSBundle.mainBundle, @"YOUR LIVE WHEEL & HOST", nil)
                                       font:[UIFont fontWithName:@"Georgia-Bold" size:25] ?: [UIFont systemFontOfSize:25 weight:UIFontWeightBold]
                                      color:BRRouletteLobbyGold()];
    headline.numberOfLines = 2;
    [banner addSubview:headline];

    UILabel *sub = [self labelWithText:NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.HeroSub", nil, NSBundle.mainBundle, @"Step up to the wheel, place your bets, and let's make it a great night.", nil)
                                  font:[UIFont systemFontOfSize:13.5]
                                 color:[UIColor colorWithWhite:1 alpha:.85]];
    sub.numberOfLines = 3;
    [banner addSubview:sub];

    [NSLayoutConstraint activateConstraints:@[
        [banner.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [banner.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [banner.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [banner.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],

        [watermark.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:24],
        [watermark.centerYAnchor constraintEqualToAnchor:banner.centerYAnchor],
        [watermark.widthAnchor constraintEqualToConstant:170],
        [watermark.heightAnchor constraintEqualToConstant:170],

        [wheel.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:20],
        [wheel.topAnchor constraintEqualToAnchor:banner.topAnchor constant:16],

        [headline.leadingAnchor constraintEqualToAnchor:wheel.leadingAnchor],
        [headline.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-90],
        [headline.topAnchor constraintEqualToAnchor:wheel.bottomAnchor constant:6],

        [sub.leadingAnchor constraintEqualToAnchor:wheel.leadingAnchor],
        [sub.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-110],
        [sub.topAnchor constraintEqualToAnchor:headline.bottomAnchor constant:7],
    ]];
    return cell;
}

- (UITableViewCell *)stateCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = UIColor.clearColor;
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:.7];
    cell.textLabel.text = self.errorMessage ?: NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.Loading", nil, NSBundle.mainBundle, @"Loading tables…", nil);
    cell.detailTextLabel.text = self.errorMessage ? NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.PullToRetry", nil, NSBundle.mainBundle, @"Pull down to try again.", nil) : @"";
    return cell;
}

- (UITableViewCell *)footerCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = UIColor.clearColor;
    UILabel *line = [self labelWithText:NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.Footer", nil, NSBundle.mainBundle, @"BIGGER BETS  ✦  HIGHER STAKES  ✦  SAME THRILL", nil)
                                   font:[UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold]
                                  color:BRRouletteLobbyGoldDim()];
    line.textAlignment = NSTextAlignmentCenter;
    [cell.contentView addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.centerXAnchor constraintEqualToAnchor:cell.contentView.centerXAnchor],
        [line.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
    ]];
    return cell;
}

- (UIView *)columnWithIcon:(NSString *)symbol value:(NSString *)value caption:(NSString *)caption {
    UIView *column = [UIView new];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = BRRouletteLobbyGold();
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [column addSubview:icon];
    UILabel *valueLabel = [self labelWithText:value font:[UIFont systemFontOfSize:15 weight:UIFontWeightBold] color:UIColor.whiteColor];
    valueLabel.textAlignment = NSTextAlignmentCenter;
    [column addSubview:valueLabel];
    UILabel *captionLabel = [self labelWithText:caption font:[UIFont systemFontOfSize:8.5 weight:UIFontWeightSemibold] color:[UIColor colorWithWhite:1 alpha:.55]];
    captionLabel.textAlignment = NSTextAlignmentCenter;
    captionLabel.numberOfLines = 2;
    [column addSubview:captionLabel];
    [NSLayoutConstraint activateConstraints:@[
        [icon.topAnchor constraintEqualToAnchor:column.topAnchor],
        [icon.centerXAnchor constraintEqualToAnchor:column.centerXAnchor],
        [icon.heightAnchor constraintEqualToConstant:17],
        [icon.widthAnchor constraintEqualToConstant:20],
        [valueLabel.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:4],
        [valueLabel.centerXAnchor constraintEqualToAnchor:column.centerXAnchor],
        [captionLabel.topAnchor constraintEqualToAnchor:valueLabel.bottomAnchor constant:2],
        [captionLabel.centerXAnchor constraintEqualToAnchor:column.centerXAnchor],
        [captionLabel.bottomAnchor constraintLessThanOrEqualToAnchor:column.bottomAnchor],
        [captionLabel.widthAnchor constraintLessThanOrEqualToConstant:64],
    ]];
    return column;
}

- (UIView *)cardSeparator {
    UIView *line = [UIView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:.13];
    [line.widthAnchor constraintEqualToConstant:1].active = YES;
    return line;
}

- (UITableViewCell *)cardCellForTable:(NSDictionary *)table index:(NSInteger)index {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = UIColor.clearColor;

    NSString *tableID = BRRouletteLobbyString(table[@"id"]);
    BOOL isPenny = [tableID isEqualToString:@"rl-penny"];
    BOOL isHigh  = [tableID isEqualToString:@"rl-high"];

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 14;
    card.layer.borderWidth = isHigh ? 1.5 : 1;
    card.layer.borderColor = [BRRouletteLobbyGold() colorWithAlphaComponent:isHigh ? .95 : .65].CGColor;
    card.backgroundColor = isPenny ? [UIColor colorWithRed:.045 green:.19 blue:.12 alpha:1]
                         : isHigh  ? [UIColor colorWithRed:.07 green:.06 blue:.04 alpha:1]
                                   : [UIColor colorWithRed:.13 green:.045 blue:.05 alpha:1];
    if (isHigh) {
        card.layer.shadowColor = BRRouletteLobbyGold().CGColor;
        card.layer.shadowOpacity = .35;
        card.layer.shadowRadius = 9;
        card.layer.shadowOffset = CGSizeZero;
    }
    [cell.contentView addSubview:card];

    BRRouletteLobbyWheelView *wheelView = [BRRouletteLobbyWheelView new];
    wheelView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:wheelView];

    NSString *tableName = BRRouletteLobbyString(table[@"name"]);
    UILabel *nameLabel = [self labelWithText:tableName.length ? tableName.uppercaseString : @"WHEEL"
                                        font:[UIFont fontWithName:@"Georgia-Bold" size:20] ?: [UIFont systemFontOfSize:20 weight:UIFontWeightBold]
                                       color:isHigh ? BRRouletteLobbyGold() : UIColor.whiteColor];
    nameLabel.adjustsFontSizeToFitWidth = YES;
    nameLabel.minimumScaleFactor = .7;
    [card addSubview:nameLabel];

    UILabel *crown = [self labelWithText:@"♛" font:[UIFont systemFontOfSize:13 weight:UIFontWeightBold] color:BRRouletteLobbyGold()];
    crown.hidden = !isHigh;
    [card addSubview:crown];

    NSInteger minBet = BRRouletteLobbyInt(table[@"min_bet"]);
    NSInteger maxBet = BRRouletteLobbyInt(table[@"max_bet"]);
    UILabel *rangeCaption = [self labelWithText:NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.BetRange", nil, NSBundle.mainBundle, @"BET RANGE", nil)
                                           font:[UIFont systemFontOfSize:9 weight:UIFontWeightSemibold]
                                          color:[UIColor colorWithWhite:1 alpha:.55]];
    [card addSubview:rangeCaption];
    UILabel *rangeValue = [self labelWithText:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.CoinsRange", nil, NSBundle.mainBundle, @"%@ – %@ coins", nil),
                                               BRRouletteLobbyGrouped(minBet), BRRouletteLobbyGrouped(maxBet)]
                                         font:[UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold]
                                        color:UIColor.whiteColor];
    rangeValue.adjustsFontSizeToFitWidth = YES;
    rangeValue.minimumScaleFactor = .7;
    [card addSubview:rangeValue];

    BOOL mine = BRRouletteLobbyBool(table[@"my_table"]);
    UILabel *seatedLabel = [self labelWithText:mine ? NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.YoureSeated", nil, NSBundle.mainBundle, @"you're seated", nil) : @""
                                          font:[UIFont systemFontOfSize:11.5]
                                         color:[UIColor colorWithWhite:1 alpha:.78]];
    seatedLabel.adjustsFontSizeToFitWidth = YES;
    seatedLabel.minimumScaleFactor = .8;
    [card addSubview:seatedLabel];

    NSInteger seated = BRRouletteLobbyInt(table[@"players"]);
    NSInteger capacity = BRRouletteLobbyInt(table[@"max_players"]);

    UIView *sep = [self cardSeparator];
    [card addSubview:sep];
    UIView *paysColumn = [self columnWithIcon:@"target"
                                        value:@"35:1"
                                      caption:NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.Pays", nil, NSBundle.mainBundle, @"STRAIGHT-UP PAYS", nil)];
    [card addSubview:paysColumn];

    // Round gold join button; its face carries the seated count, and the
    // whole card is tappable too.
    UIView *joinWrap = [UIView new];
    joinWrap.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:joinWrap];
    UIButton *join = [UIButton buttonWithType:UIButtonTypeCustom];
    join.translatesAutoresizingMaskIntoConstraints = NO;
    join.tag = index;
    join.layer.cornerRadius = 25;
    join.layer.borderWidth = 2;
    join.layer.borderColor = BRRouletteLobbyGold().CGColor;
    join.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [join setTitle:[NSString stringWithFormat:@"%ld/%ld", (long)seated, (long)capacity] forState:UIControlStateNormal];
    if (isHigh || mine) {
        join.backgroundColor = BRRouletteLobbyGold();
        [join setTitleColor:[UIColor colorWithRed:.10 green:.08 blue:.02 alpha:1] forState:UIControlStateNormal];
    } else {
        [join setTitleColor:BRRouletteLobbyGold() forState:UIControlStateNormal];
    }
    [join addTarget:self action:@selector(joinButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    join.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.Join", nil, NSBundle.mainBundle, @"JOIN", nil), tableName];
    [joinWrap addSubview:join];
    UILabel *joinLabel = [self labelWithText:NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.Join", nil, NSBundle.mainBundle, @"JOIN", nil)
                                         font:[UIFont systemFontOfSize:10 weight:UIFontWeightBold]
                                        color:BRRouletteLobbyGold()];
    joinLabel.textAlignment = NSTextAlignmentCenter;
    [joinWrap addSubview:joinLabel];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:6],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],

        [wheelView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [wheelView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [wheelView.widthAnchor constraintEqualToConstant:62],
        [wheelView.heightAnchor constraintEqualToConstant:62],

        [crown.leadingAnchor constraintEqualToAnchor:wheelView.trailingAnchor constant:10],
        [crown.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],

        [nameLabel.leadingAnchor constraintEqualToAnchor:wheelView.trailingAnchor constant:10],
        [nameLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:isHigh ? 24 : 14],
        [nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:paysColumn.leadingAnchor constant:-8],

        [rangeCaption.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [rangeCaption.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:5],
        [rangeValue.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [rangeValue.topAnchor constraintEqualToAnchor:rangeCaption.bottomAnchor constant:1],
        [rangeValue.trailingAnchor constraintLessThanOrEqualToAnchor:paysColumn.leadingAnchor constant:-8],
        [seatedLabel.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [seatedLabel.topAnchor constraintEqualToAnchor:rangeValue.bottomAnchor constant:4],
        [seatedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:paysColumn.leadingAnchor constant:-6],

        [joinWrap.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],
        [joinWrap.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [joinWrap.widthAnchor constraintEqualToConstant:54],
        [join.widthAnchor constraintEqualToConstant:50],
        [join.heightAnchor constraintEqualToConstant:50],
        [join.centerXAnchor constraintEqualToAnchor:joinWrap.centerXAnchor],
        [join.topAnchor constraintEqualToAnchor:joinWrap.topAnchor],
        [joinLabel.topAnchor constraintEqualToAnchor:join.bottomAnchor constant:3],
        [joinLabel.centerXAnchor constraintEqualToAnchor:joinWrap.centerXAnchor],
        [joinLabel.bottomAnchor constraintEqualToAnchor:joinWrap.bottomAnchor],

        [sep.trailingAnchor constraintEqualToAnchor:joinWrap.leadingAnchor constant:-6],
        [sep.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [sep.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
        [paysColumn.trailingAnchor constraintEqualToAnchor:sep.leadingAnchor constant:-2],
        [paysColumn.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [paysColumn.widthAnchor constraintEqualToConstant:58],
    ]];

    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %ld/%ld %@",
        tableName, rangeValue.text, (long)seated, (long)capacity,
        NSLocalizedStringWithDefaultValue(@"BRRoulette.Lobby.SeatedCaption", nil, NSBundle.mainBundle, @"SEATED", nil)];
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isHeroRow:indexPath]) return [self heroCell];
    if ([self isFooterRow:indexPath]) return [self footerCell];
    if (self.tables.count == 0) return [self stateCell];
    NSInteger index = [self tableIndexForRow:indexPath.row];
    NSDictionary *table = [self.tables[index] isKindOfClass:[NSDictionary class]] ? self.tables[index] : @{};
    return [self cardCellForTable:table index:index];
}

#pragma mark UITableViewDelegate

- (void)openTableAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.tables.count) return;
    NSDictionary *table = [self.tables[index] isKindOfClass:[NSDictionary class]] ? self.tables[index] : @{};
    NSString *tableID = BRRouletteLobbyString(table[@"id"]);
    if (tableID.length == 0) return;
    NSString *tableName = BRRouletteLobbyString(table[@"name"]);
    BRRouletteTableViewController *controller = [[BRRouletteTableViewController alloc] initWithTableID:tableID tableName:tableName.length ? tableName : nil];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)joinButtonTapped:(UIButton *)button {
    [self openTableAtIndex:button.tag];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.tables.count == 0 || [self isHeroRow:indexPath] || [self isFooterRow:indexPath]) return;
    [self openTableAtIndex:[self tableIndexForRow:indexPath.row]];
}

@end
