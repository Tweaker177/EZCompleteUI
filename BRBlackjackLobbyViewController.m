// BRBlackjackLobbyViewController.m
// EZCompleteUI v1.1
//
// Purpose:
//   See BRBlackjackLobbyViewController.h. Table data comes from the
//   list_tables action; the list refreshes every few seconds while the screen
//   is visible and via pull-to-refresh, and shows a retry message instead of a
//   blank screen when the request fails.
//
// Changes from v1:
//   - The plain table list is now a set of casino table cards in the style
//     of the lobby mockup: a dealer hero header, one card per table with a
//     chip stack in the table's colors, its bet range, seats taken, the
//     dealing dealer's name, and a round gold join button. The balance sits
//     in a pill in the navigation bar and opens the coin store.
//   - High Limit is a VIP table: its card carries a VIP pill, and for
//     players without VIP standing its join button is a lock that
//     explains the unlock instead of entering. The server enforces
//     the same rule on join; the card state comes from the vip_only /
//     vip_eligible fields on each list_tables row.

#import "BRBlackjackLobbyViewController.h"
#import "BRBlackjackAPI.h"
#import "BRBlackjackTableViewController.h"
#import "EZCoinStoreViewController.h"

static const NSTimeInterval kLobbyRefreshInterval = 5.0;

static NSInteger BRBlackjackLobbyInt(id value) { return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0; }
static BOOL BRBlackjackLobbyBool(id value) { return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO; }
static NSString *BRBlackjackLobbyString(id value) { return [value isKindOfClass:[NSString class]] ? value : @""; }

static UIColor *BRBJLobbyGold(void) { return [UIColor colorWithRed:.85 green:.67 blue:.33 alpha:1]; }
static UIColor *BRBJLobbyGoldDim(void) { return [BRBJLobbyGold() colorWithAlphaComponent:.55]; }

static NSString *BRBJLobbyGrouped(NSInteger value) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSNumberFormatter new];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
    });
    return [formatter stringFromNumber:@(value)] ?: [NSString stringWithFormat:@"%ld", (long)value];
}

#pragma mark - Chip stack drawing

typedef NS_ENUM(NSInteger, BRBJLobbyChipStyle) {
    BRBJLobbyChipStyleGreen = 0,
    BRBJLobbyChipStyleRed   = 1,
    BRBJLobbyChipStyleBlack = 2,
};

/// A small stack of three poker chips drawn in the table's colors — the
/// front chip carries the spade. Drawn in code so it stays sharp at any size.
@interface BRBJLobbyChipsView : UIView
@property (nonatomic) BRBJLobbyChipStyle chipStyle;
@end

@implementation BRBJLobbyChipsView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) self.backgroundColor = UIColor.clearColor;
    return self;
}

- (void)drawChipAt:(CGPoint)origin diameter:(CGFloat)diameter {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect face = CGRectMake(origin.x, origin.y, diameter, diameter);
    UIColor *faceColor, *edgeColor, *pipColor;
    switch (self.chipStyle) {
        case BRBJLobbyChipStyleRed:
            faceColor = [UIColor colorWithRed:.52 green:.10 blue:.13 alpha:1];
            edgeColor = [UIColor colorWithRed:.93 green:.86 blue:.70 alpha:1];
            pipColor  = edgeColor;
            break;
        case BRBJLobbyChipStyleBlack:
            faceColor = [UIColor colorWithRed:.05 green:.05 blue:.06 alpha:1];
            edgeColor = BRBJLobbyGold();
            pipColor  = BRBJLobbyGold();
            break;
        case BRBJLobbyChipStyleGreen:
        default:
            faceColor = [UIColor colorWithRed:.09 green:.45 blue:.24 alpha:1];
            edgeColor = [UIColor colorWithWhite:1 alpha:.92];
            pipColor  = [UIColor colorWithWhite:1 alpha:.95];
            break;
    }
    CGContextSetFillColorWithColor(ctx, faceColor.CGColor);
    CGContextFillEllipseInRect(ctx, face);
    // Dashed edge ring, like the white marks around a real chip.
    CGContextSetStrokeColorWithColor(ctx, edgeColor.CGColor);
    CGContextSetLineWidth(ctx, diameter * .09);
    CGFloat dash[] = { diameter * .16, diameter * .13 };
    CGContextSetLineDash(ctx, 0, dash, 2);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(face, diameter * .07, diameter * .07));
    CGContextSetLineDash(ctx, 0, NULL, 0);
    // Inner circle and the spade pip.
    CGContextSetStrokeColorWithColor(ctx, [edgeColor colorWithAlphaComponent:.8].CGColor);
    CGContextSetLineWidth(ctx, 1);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(face, diameter * .24, diameter * .24));
    NSString *spade = @"♠";
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:diameter * .34 weight:UIFontWeightBold],
                             NSForegroundColorAttributeName: pipColor };
    CGSize textSize = [spade sizeWithAttributes:attrs];
    [spade drawAtPoint:CGPointMake(CGRectGetMidX(face) - textSize.width / 2, CGRectGetMidY(face) - textSize.height / 2) withAttributes:attrs];
}

- (void)drawRect:(CGRect)rect {
    CGFloat unit = MIN(rect.size.width / 76.0, rect.size.height / 64.0);
    CGFloat d = 42 * unit;
    [self drawChipAt:CGPointMake(0, 10 * unit) diameter:d];
    [self drawChipAt:CGPointMake(30 * unit, 2 * unit) diameter:d];
    [self drawChipAt:CGPointMake(15 * unit, 20 * unit) diameter:d];
}

@end

/// A view backed by a gradient layer that always matches its bounds.
@interface BRBJLobbyGradientView : UIView
@end

@implementation BRBJLobbyGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
        gradient.colors = @[ (id)[UIColor colorWithRed:.05 green:.19 blue:.12 alpha:1].CGColor,
                             (id)[UIColor colorWithRed:.012 green:.05 blue:.035 alpha:1].CGColor ];
        gradient.startPoint = CGPointMake(0, 0);
        gradient.endPoint = CGPointMake(1, 1);
    }
    return self;
}
@end

#pragma mark - Controller

@interface BRBlackjackLobbyViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *tables;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic) NSInteger balance;
@property (nonatomic) BOOL loading;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) UIButton *balancePill;
@end

@implementation BRBlackjackLobbyViewController

- (instancetype)init { return [super initWithStyle:UITableViewStylePlain]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Title", nil, NSBundle.mainBundle, @"Blackjack", nil);
    self.tables = @[];
    self.tableView.backgroundColor = [UIColor colorWithRed:.012 green:.035 blue:.028 alpha:1];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.showsVerticalScrollIndicator = NO;
    self.refreshControl = [UIRefreshControl new];
    self.refreshControl.tintColor = BRBJLobbyGold();
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];

    // Balance pill in the top bar, in the style of the mockup; tapping it
    // opens the coin store.
    UIButton *pill = [UIButton buttonWithType:UIButtonTypeCustom];
    pill.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    [pill setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    pill.contentEdgeInsets = UIEdgeInsetsMake(5, 12, 5, 12);
    pill.layer.cornerRadius = 14;
    pill.layer.borderWidth = 1;
    pill.layer.borderColor = BRBJLobbyGoldDim().CGColor;
    pill.backgroundColor = [UIColor colorWithWhite:1 alpha:.06];
    [pill addTarget:self action:@selector(balancePillTapped) forControlEvents:UIControlEventTouchUpInside];
    self.balancePill = pill;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:pill];
    [self updateBalancePill];
}

- (void)updateBalancePill {
    NSString *title = [NSString stringWithFormat:@"🪙 %@  +", BRBJLobbyGrouped(self.balance)];
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

    UIView *banner = [[BRBJLobbyGradientView alloc] initWithFrame:CGRectZero];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.layer.cornerRadius = 16;
    banner.layer.masksToBounds = YES;
    banner.layer.borderWidth = 1;
    banner.layer.borderColor = [BRBJLobbyGold() colorWithAlphaComponent:.35].CGColor;
    [cell.contentView addSubview:banner];

    UILabel *watermark = [self labelWithText:@"♠" font:[UIFont systemFontOfSize:170 weight:UIFontWeightBold]
                                       color:[UIColor colorWithWhite:1 alpha:.06]];
    [banner addSubview:watermark];

    UILabel *spade = [self labelWithText:@"♠" font:[UIFont systemFontOfSize:20 weight:UIFontWeightBold] color:BRBJLobbyGold()];
    spade.textAlignment = NSTextAlignmentCenter;
    [banner addSubview:spade];

    UILabel *headline = [self labelWithText:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.HeroTitle", nil, NSBundle.mainBundle, @"YOUR AI DEALER & HOST", nil)
                                       font:[UIFont fontWithName:@"Georgia-Bold" size:25] ?: [UIFont systemFontOfSize:25 weight:UIFontWeightBold]
                                      color:BRBJLobbyGold()];
    headline.numberOfLines = 2;
    [banner addSubview:headline];

    UILabel *sub = [self labelWithText:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.HeroSub", nil, NSBundle.mainBundle, @"Step up to the table, enjoy the game, and let's make it a great night.", nil)
                                  font:[UIFont systemFontOfSize:13.5]
                                 color:[UIColor colorWithWhite:1 alpha:.85]];
    sub.numberOfLines = 3;
    [banner addSubview:sub];

    // Who is dealing tonight, from the tables themselves.
    NSMutableArray<NSString *> *dealers = [NSMutableArray array];
    for (NSDictionary *table in self.tables) {
        NSString *hostName = BRBlackjackLobbyString(table[@"host_name"]);
        NSString *hostEmoji = BRBlackjackLobbyString(table[@"host_emoji"]);
        if (hostName.length && ![dealers containsObject:hostName]) {
            [dealers addObject:hostEmoji.length ? [NSString stringWithFormat:@"%@ %@", hostEmoji, hostName] : hostName];
        }
    }
    UILabel *dealerLine = [self labelWithText:[dealers componentsJoinedByString:@"  ·  "]
                                         font:[UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold]
                                        color:[UIColor colorWithWhite:1 alpha:.75]];
    dealerLine.textAlignment = NSTextAlignmentCenter;
    [banner addSubview:dealerLine];

    [NSLayoutConstraint activateConstraints:@[
        [banner.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [banner.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [banner.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [banner.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],

        [watermark.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:6],
        [watermark.centerYAnchor constraintEqualToAnchor:banner.centerYAnchor],

        [spade.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:20],
        [spade.topAnchor constraintEqualToAnchor:banner.topAnchor constant:16],

        [headline.leadingAnchor constraintEqualToAnchor:spade.leadingAnchor],
        [headline.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-90],
        [headline.topAnchor constraintEqualToAnchor:spade.bottomAnchor constant:6],

        [sub.leadingAnchor constraintEqualToAnchor:spade.leadingAnchor],
        [sub.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-110],
        [sub.topAnchor constraintEqualToAnchor:headline.bottomAnchor constant:7],

        [dealerLine.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:12],
        [dealerLine.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12],
        [dealerLine.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-10],
    ]];
    return cell;
}

- (UITableViewCell *)stateCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = UIColor.clearColor;
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:.7];
    cell.textLabel.text = self.errorMessage ?: NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Loading", nil, NSBundle.mainBundle, @"Loading tables…", nil);
    cell.detailTextLabel.text = self.errorMessage ? NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.PullToRetry", nil, NSBundle.mainBundle, @"Pull down to try again.", nil) : @"";
    return cell;
}

- (UITableViewCell *)footerCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = UIColor.clearColor;
    UILabel *line = [self labelWithText:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Footer", nil, NSBundle.mainBundle, @"BIGGER BETS  ✦  HIGHER STAKES  ✦  SAME THRILL", nil)
                                   font:[UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold]
                                  color:BRBJLobbyGoldDim()];
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
    icon.tintColor = BRBJLobbyGold();
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

    NSString *tableID = BRBlackjackLobbyString(table[@"id"]);
    BOOL isPenny = [tableID isEqualToString:@"bj-penny"];
    BOOL isHigh  = [tableID isEqualToString:@"bj-high"];
    BRBJLobbyChipStyle chipStyle = isPenny ? BRBJLobbyChipStyleGreen : (isHigh ? BRBJLobbyChipStyleBlack : BRBJLobbyChipStyleRed);

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 14;
    card.layer.borderWidth = isHigh ? 1.5 : 1;
    card.layer.borderColor = [BRBJLobbyGold() colorWithAlphaComponent:isHigh ? .95 : .65].CGColor;
    card.backgroundColor = isPenny ? [UIColor colorWithRed:.045 green:.19 blue:.12 alpha:1]
                         : isHigh  ? [UIColor colorWithRed:.07 green:.06 blue:.04 alpha:1]
                                   : [UIColor colorWithRed:.13 green:.045 blue:.05 alpha:1];
    if (isHigh) {
        card.layer.shadowColor = BRBJLobbyGold().CGColor;
        card.layer.shadowOpacity = .35;
        card.layer.shadowRadius = 9;
        card.layer.shadowOffset = CGSizeZero;
    }
    [cell.contentView addSubview:card];

    BRBJLobbyChipsView *chips = [[BRBJLobbyChipsView alloc] initWithFrame:CGRectZero];
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    chips.chipStyle = chipStyle;
    [card addSubview:chips];

    NSString *tableName = BRBlackjackLobbyString(table[@"name"]);
    UILabel *nameLabel = [self labelWithText:tableName.length ? tableName.uppercaseString : @"TABLE"
                                        font:[UIFont fontWithName:@"Georgia-Bold" size:20] ?: [UIFont systemFontOfSize:20 weight:UIFontWeightBold]
                                       color:isHigh ? BRBJLobbyGold() : UIColor.whiteColor];
    nameLabel.adjustsFontSizeToFitWidth = YES;
    nameLabel.minimumScaleFactor = .7;
    [card addSubview:nameLabel];

    UILabel *crown = [self labelWithText:@"♛" font:[UIFont systemFontOfSize:13 weight:UIFontWeightBold] color:BRBJLobbyGold()];
    crown.hidden = !isHigh;
    [card addSubview:crown];

    NSInteger minBet = BRBlackjackLobbyInt(table[@"min_bet"]);
    NSInteger maxBet = BRBlackjackLobbyInt(table[@"max_bet"]);
    UILabel *rangeCaption = [self labelWithText:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.BetRange", nil, NSBundle.mainBundle, @"BET RANGE", nil)
                                           font:[UIFont systemFontOfSize:9 weight:UIFontWeightSemibold]
                                          color:[UIColor colorWithWhite:1 alpha:.55]];
    [card addSubview:rangeCaption];
    UILabel *rangeValue = [self labelWithText:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.CoinsRange", nil, NSBundle.mainBundle, @"%ld – %ld coins", nil), (long)minBet, (long)maxBet]
                                         font:[UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold]
                                        color:UIColor.whiteColor];
    rangeValue.adjustsFontSizeToFitWidth = YES;
    rangeValue.minimumScaleFactor = .7;
    [card addSubview:rangeValue];

    NSString *hostName = BRBlackjackLobbyString(table[@"host_name"]);
    NSString *hostEmoji = BRBlackjackLobbyString(table[@"host_emoji"]);
    BOOL mine = BRBlackjackLobbyBool(table[@"my_table"]);
    BOOL vipOnly = BRBlackjackLobbyBool(table[@"vip_only"]);
    BOOL vipEligible = BRBlackjackLobbyBool(table[@"vip_eligible"]);
    BOOL vipLocked = vipOnly && !vipEligible && !mine;
    NSString *dealerText = @"";
    if (hostName.length) {
        dealerText = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Dealing", nil, NSBundle.mainBundle, @"%@ dealing", nil),
                      hostEmoji.length ? [NSString stringWithFormat:@"%@ %@", hostEmoji, hostName] : hostName];
        if (mine) dealerText = [dealerText stringByAppendingFormat:@" · %@", NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.YoureSeated", nil, NSBundle.mainBundle, @"you're seated", nil)];
    }
    UILabel *dealerLabel = [self labelWithText:dealerText font:[UIFont systemFontOfSize:11.5] color:[UIColor colorWithWhite:1 alpha:.78]];
    dealerLabel.adjustsFontSizeToFitWidth = YES;
    dealerLabel.minimumScaleFactor = .8;
    [card addSubview:dealerLabel];

    UIView *sep1 = [self cardSeparator];
    [card addSubview:sep1];
    NSInteger seated = BRBlackjackLobbyInt(table[@"seated"]);
    NSInteger maxSeats = BRBlackjackLobbyInt(table[@"max_seats"]);
    UIView *seatedColumn = [self columnWithIcon:@"person.fill"
                                         value:[NSString stringWithFormat:@"%ld/%ld", (long)seated, (long)maxSeats]
                                       caption:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Seated", nil, NSBundle.mainBundle, @"SEATED", nil)];
    [card addSubview:seatedColumn];

    UIView *sep2 = [self cardSeparator];
    [card addSubview:sep2];
    UIView *paysColumn = [self columnWithIcon:@"rectangle.on.rectangle"
                                        value:@"3:2"
                                      caption:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Pays", nil, NSBundle.mainBundle, @"BLACKJACK PAYS", nil)];
    [card addSubview:paysColumn];

    // Round gold join button; the whole card is tappable too.
    UIView *joinWrap = [UIView new];
    joinWrap.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:joinWrap];
    UIButton *join = [UIButton buttonWithType:UIButtonTypeCustom];
    join.translatesAutoresizingMaskIntoConstraints = NO;
    join.tag = index;
    join.layer.cornerRadius = 25;
    join.layer.borderWidth = 2;
    join.layer.borderColor = BRBJLobbyGold().CGColor;
    [join setImage:[UIImage systemImageNamed:vipLocked ? @"lock.fill" : @"arrow.right"] forState:UIControlStateNormal];
    if ((isHigh || mine) && !vipLocked) {
        join.backgroundColor = BRBJLobbyGold();
        join.tintColor = [UIColor colorWithRed:.10 green:.08 blue:.02 alpha:1];
    } else {
        join.tintColor = BRBJLobbyGold();
    }
    [join addTarget:self action:@selector(joinButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    join.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", vipLocked ? NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Vip", nil, NSBundle.mainBundle, @"VIP", nil)
                                                                              : NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Join", nil, NSBundle.mainBundle, @"JOIN", nil), tableName];
    [joinWrap addSubview:join];
    UILabel *joinLabel = [self labelWithText:vipLocked ? NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Vip", nil, NSBundle.mainBundle, @"VIP", nil)
                                                      : NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Join", nil, NSBundle.mainBundle, @"JOIN", nil)
                                         font:[UIFont systemFontOfSize:10 weight:UIFontWeightBold]
                                        color:BRBJLobbyGold()];
    joinLabel.textAlignment = NSTextAlignmentCenter;
    [joinWrap addSubview:joinLabel];

    UIView *vipPill = nil;
    if (vipOnly) {
        vipPill = [UIView new];
        vipPill.translatesAutoresizingMaskIntoConstraints = NO;
        vipPill.layer.cornerRadius = 8.5;
        vipPill.layer.borderWidth = 1;
        vipPill.layer.borderColor = BRBJLobbyGold().CGColor;
        vipPill.backgroundColor = [BRBJLobbyGold() colorWithAlphaComponent:.14];
        [card addSubview:vipPill];
        UILabel *vipText = [self labelWithText:[NSString stringWithFormat:@"★ %@", NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Vip", nil, NSBundle.mainBundle, @"VIP", nil)]
                                          font:[UIFont systemFontOfSize:9.5 weight:UIFontWeightBold]
                                         color:BRBJLobbyGold()];
        vipText.textAlignment = NSTextAlignmentCenter;
        [vipPill addSubview:vipText];
        [NSLayoutConstraint activateConstraints:@[
            [vipText.centerXAnchor constraintEqualToAnchor:vipPill.centerXAnchor],
            [vipText.centerYAnchor constraintEqualToAnchor:vipPill.centerYAnchor],
        ]];
    }

    NSMutableArray<NSLayoutConstraint *> *cardConstraints = [NSMutableArray arrayWithObjects:
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:6],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],

        [chips.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10],
        [chips.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [chips.widthAnchor constraintEqualToConstant:66],
        [chips.heightAnchor constraintEqualToConstant:56],

        [crown.leadingAnchor constraintEqualToAnchor:chips.trailingAnchor constant:10],
        [crown.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],

        [nameLabel.leadingAnchor constraintEqualToAnchor:chips.trailingAnchor constant:10],
        [nameLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:isHigh ? 24 : 14],
        [nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:sep1.leadingAnchor constant:-8],

        [rangeCaption.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [rangeCaption.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:5],
        [rangeValue.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [rangeValue.topAnchor constraintEqualToAnchor:rangeCaption.bottomAnchor constant:1],
        [rangeValue.trailingAnchor constraintLessThanOrEqualToAnchor:sep1.leadingAnchor constant:-8],
        [dealerLabel.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [dealerLabel.topAnchor constraintEqualToAnchor:rangeValue.bottomAnchor constant:4],
        [dealerLabel.trailingAnchor constraintLessThanOrEqualToAnchor:sep1.leadingAnchor constant:-6],

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

        [sep2.trailingAnchor constraintEqualToAnchor:joinWrap.leadingAnchor constant:-6],
        [sep2.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [sep2.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
        [paysColumn.trailingAnchor constraintEqualToAnchor:sep2.leadingAnchor constant:-2],
        [paysColumn.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [paysColumn.widthAnchor constraintEqualToConstant:58],

        [sep1.trailingAnchor constraintEqualToAnchor:paysColumn.leadingAnchor constant:-2],
        [sep1.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [sep1.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
        [seatedColumn.trailingAnchor constraintEqualToAnchor:sep1.leadingAnchor constant:-2],
        [seatedColumn.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [seatedColumn.widthAnchor constraintEqualToConstant:40],
        nil];
    if (vipPill) {
        [cardConstraints addObjectsFromArray:@[
            [vipPill.topAnchor constraintEqualToAnchor:card.topAnchor constant:9],
            [vipPill.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [vipPill.widthAnchor constraintEqualToConstant:48],
            [vipPill.heightAnchor constraintEqualToConstant:17],
        ]];
    }
    [NSLayoutConstraint activateConstraints:cardConstraints];

    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@, %@ %@",
        tableName, rangeValue.text,
        [NSString stringWithFormat:@"%ld/%ld", (long)seated, (long)maxSeats],
        NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.Seated", nil, NSBundle.mainBundle, @"SEATED", nil)];
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
    BOOL vipLocked = BRBlackjackLobbyBool(table[@"vip_only"]) && !BRBlackjackLobbyBool(table[@"vip_eligible"]) && !BRBlackjackLobbyBool(table[@"my_table"]);
    if (vipLocked) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.VipTitle", nil, NSBundle.mainBundle, @"VIP table", nil)
            message:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Lobby.VipMessage", nil, NSBundle.mainBundle, @"High Limit is for VIP players. Reach Silver VIP (50,000 VIP points) or start any subscription to unlock it.", nil)
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSString *tableID = [table[@"id"] isKindOfClass:[NSString class]] ? table[@"id"] : nil;
    if (!tableID) return;
    NSString *tableName = BRBlackjackLobbyString(table[@"name"]);
    BRBlackjackTableViewController *controller = [[BRBlackjackTableViewController alloc] initWithTableID:tableID tableName:tableName.length ? tableName : nil];
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
