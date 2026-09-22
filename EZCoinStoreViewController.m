// EZCoinStoreViewController.m

// EZCompleteUI

//

// Gamified EZ Coin store with subscription tiers, one-time top-ups, and daily free coins.

// Uses SFSafariViewController for PayPal checkout flow.

// Coin image: EZCoin.png (bundled asset).

//

// Subscription architecture:

//   The app never holds PayPal plan IDs. Each subscription tier is identified

//   by a name ("basic", "standard", "pro", "ultra") and the edge function

//   (create-paypal-subscription) resolves the real plan_id from server-side

//   env vars. This keeps plan IDs out of the binary, which is especially

//   important given the jailbreak audience — plan IDs in the binary can be

//   read and potentially misused via method hooks.

//

// Recent changes:

//   - Removed hardcoded PayPal plan ID constants (kPlanBasic, kPlanStandard,

//     kPlanPro, kPlanUltra). Subscription items now store tier names instead.

//     The edge function resolves the real plan_id from environment variables.

//     Previously, sandbox plan IDs were baked into the binary causing "failed

//     to open store" errors when the backend switched to live mode.

//   - createPayPalSubscriptionForPlanID:token: renamed to

//     createPayPalSubscriptionForTier:token: and updated to send { tier, user_id }

//     instead of { plan_id, user_id } to match the updated edge function contract.

//   - startSubscriptionForPlanID:token: renamed to startSubscriptionForTier:token:

//   - pendingPlanID property renamed to pendingTierName to reflect the new

//     tier-name-based architecture (property remains reserved for future retry logic)

//   - Free coins every 6 hours: 5 per claim for free users, 10 per claim for active subscribers (any tier)

//   - Floating "Free Coins" button added top-left, mirroring the Ledger button on the right

//   - Ledger button and its methods wrapped in #if DEBUG — absent in Release/production builds

//   - Coin eligibility is always verified server-side (claim-daily-coins edge function)

//   - Successful claim triggers the same coin celebration overlay used for purchases

//   - Button shows a live ticking countdown (e.g. "Next: 4h 22m", "Next: 3m 45s", "Next: 12s")

//     driven by an NSTimer that fires every second; timer starts when the server confirms

//     coins were already claimed and stops automatically when the countdown reaches zero,

//     when coins become available, or when the view disappears

//   - Short local variable names (pad, w, h, req, url, card, etc.) renamed for readability

//   - Replaced NSISO8601DateFormatter with NSDateFormatter (crash fix: SIGABRT on iOS 15 / jailbreak)

//   - All JSON value reads now use NSNull-safe helpers (crash fix: JSON null → [NSNull null] → ___forwarding___)

#import <QuartzCore/QuartzCore.h>
#import <UserNotifications/UserNotifications.h>

#import "EZCoinStoreViewController.h"

#import "EZAuthManager.h"

#import "EZEntitlementManager.h"

#import "EZCoinPotView.h"

#import "helpers.h"

#import "EZCoinLedgerViewController.h"



#import "EZCoinUsageViewController.h"

// ── Safe JSON value helpers ───────────────────────────────────────────────────

// NSJSONSerialization maps JSON `null` to [NSNull null], a real Objective-C object

// that crashes on any message it doesn't implement (boolValue, integerValue, length, etc.)

// because those calls go through ___forwarding___ and abort.

// Confirmed crash on iPhone OS 15.8.7 / jailbroken: frames 5–6 in EZCompleteUI binary

// followed immediately by _CF_forwarding_prep_0 → ___forwarding___ → objc_exception_throw.

// Always use these helpers instead of messaging json[key] directly.

static BOOL jsonBool(NSDictionary *json, NSString *key) {

    id value = json[key];

    return (value && value != (id)[NSNull null]) ? [value boolValue] : NO;

}

static NSInteger jsonInteger(NSDictionary *json, NSString *key) {

    id value = json[key];

    return (value && value != (id)[NSNull null]) ? [value integerValue] : 0;

}

// Returns the string value for key, or nil if the value is absent, null, or not a string.

static NSString *jsonString(NSDictionary *json, NSString *key) {

    id value = json[key];

    return [value isKindOfClass:[NSString class]] ? value : nil;

}

// ── ISO 8601 date parsing ─────────────────────────────────────────────────────

// NSISO8601DateFormatter triggers a SIGABRT inside ___forwarding___ on iOS 15

// jailbroken devices (confirmed crash: com.i0stweak3r.ezcompleteui / iPhone OS 15.8.7).

// NSDateFormatter with explicit format strings is available since iOS 2 and is stable.

// Accepts `id` so callers never need to cast — NSNull and nil both return nil safely.

// Formatters are created once per process via dispatch_once.

static NSDate *dateFromISO8601String(id isoStringOrNull) {

    // Reject nil, [NSNull null], and any non-string type that JSON might produce

    if (![isoStringOrNull isKindOfClass:[NSString class]]) return nil;

    NSString *isoString = (NSString *)isoStringOrNull;

    if (isoString.length == 0) return nil;

    // Two formats to cover what Supabase / the edge function may return:

    //   Format A (JavaScript toISOString): "2026-06-09T20:28:18.000Z"

    //   Format B (PostgreSQL timestamptz): "2026-06-09T20:28:18+00:00"

    static NSDateFormatter *formatterWithMilliseconds    = nil;

    static NSDateFormatter *formatterWithoutMilliseconds = nil;

    static dispatch_once_t  onceToken;

    dispatch_once(&onceToken, ^{

        NSLocale *posixLocale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

        formatterWithMilliseconds            = [[NSDateFormatter alloc] init];

        formatterWithMilliseconds.locale     = posixLocale;

        formatterWithMilliseconds.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";

        formatterWithoutMilliseconds            = [[NSDateFormatter alloc] init];

        formatterWithoutMilliseconds.locale     = posixLocale;

        formatterWithoutMilliseconds.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";

    });

    NSDate *parsedDate = [formatterWithMilliseconds dateFromString:isoString];

    return parsedDate ?: [formatterWithoutMilliseconds dateFromString:isoString];

}

// ── Supabase / PayPal constants ───────────────────────────────────────────────

static NSString *const kStoreSupabaseURL   = @"https://spuoimtqofhbdzosrbng.supabase.co";

// Daily coins endpoint — see supabase/functions/claim-daily-coins/index.ts

static NSString *const kDailyCoinsEndpoint = @"/functions/v1/claim-daily-coins";

// One non-repeating local reminder is scheduled for the authoritative server
// claim time. It is replaced after every successful claim, never used as a
// generic engagement notification, and is only scheduled after the person
// opts in to notifications.
static NSString *const kDailyCoinsReadyNotificationIdentifier = @"com.i0stweak3r.ezcompleteui.daily-coins-ready";

// Subscription tier names sent to the create-paypal-subscription edge function.

// The edge function resolves the real PayPal plan_id from server-side env vars

// (PAYPAL_PLAN_BASIC, PAYPAL_PLAN_STANDARD, etc.) so plan IDs never live in

// the binary. To add a tier: add a constant here, add it to buildItems, and

// set the matching PAYPAL_PLAN_* env var in Supabase.

static NSString *const kTierBasic    = @"basic";

static NSString *const kTierStandard = @"standard";

static NSString *const kTierPro      = @"pro";

static NSString *const kTierUltra    = @"ultra";

static NSString *const kTierBasicWeekly = @"basic_weekly";

static NSString *const kTierPower = @"power";

static NSString *const kTierPowerAnnual = @"power_annual";

static NSString *const kTierEnterprise = @"enterprise";

static NSString *const kTierEnterpriseAnnual = @"enterprise_annual";

static NSString *const kTierStandardAnnual = @"standard_annual";

static NSString *const kTierProAnnual      = @"pro_annual";

static NSString *const kTierUltraAnnual    = @"ultra_annual";

// ── Promo banner ───────────────────────────────────────────────────────────────

// Height reserved at the top of the table header when a promo is running.

// isPromoActive (see below) is a manual flag for now — flip it to match

// whatever promo rows are currently active/unexpired in the `promotions`

// table. It is intentionally NOT fetched from the server here to keep this

// simple; if the banner ever needs to auto-hide the instant a promo's

// valid_until passes (without an app update), that would be a small

// GET-style status check mirroring refreshDailyCoinsStatus's pattern.

static CGFloat const kPromoBannerHeight = 108.0;

// Now 0 — the Daily Coins button moved into the nav bar, so nothing floats

// over the header content anymore and the banner can sit flush at the top.

static CGFloat const kPromoBannerTopPadding = 0.0;

// ── Store item model ──────────────────────────────────────────────────────────

typedef NS_ENUM(NSUInteger, EZStoreItemType) {

    EZStoreItemTypeSubscription,

    EZStoreItemTypeTopUp,

};

@interface EZStoreItem : NSObject

@property (nonatomic, copy)   NSString        *title;

@property (nonatomic, copy)   NSString        *subtitle;       // e.g. "400 coins / month"

@property (nonatomic, copy)   NSString        *priceString;    // e.g. "$5.00 / mo"

@property (nonatomic, copy)   NSString        *planOrPackageID;

@property (nonatomic, assign) EZStoreItemType  type;

@property (nonatomic, assign) NSInteger        coins;

@property (nonatomic, assign) BOOL             isCurrentPlan;

@property (nonatomic, strong) UIColor         *accentColor;

@property (nonatomic, copy)   NSString        *badgeText;      // e.g. "BEST VALUE" — nil for none

@property (nonatomic, copy)   NSString        *badgeFootnoteText; // small disclaimer under badgeText — nil for none

@end

@implementation EZStoreItem

@end

// ── Cell ──────────────────────────────────────────────────────────────────────

@interface EZStoreCell : UITableViewCell

@property (nonatomic, strong) UIView      *cardView;

@property (nonatomic, strong) UIImageView *coinImageView;

@property (nonatomic, strong) UILabel     *titleLabel;

@property (nonatomic, strong) UILabel     *subtitleLabel;

@property (nonatomic, strong) UILabel     *priceLabel;

@property (nonatomic, strong) UILabel     *badgeLabel;

@property (nonatomic, strong) UILabel     *footnoteLabel;

@property (nonatomic, strong) UIButton    *actionButton;

@property (nonatomic, copy)   void (^onAction)(void);

- (void)configureWithItem:(EZStoreItem *)item coinImage:(UIImage * _Nullable)coinImage;

@end

@implementation EZStoreCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {

    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];

    if (self) {

        self.backgroundColor = [UIColor clearColor];

        self.selectionStyle  = UITableViewCellSelectionStyleNone;

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

        self.titleLabel.font      = [UIFont boldSystemFontOfSize:17];

        self.titleLabel.textColor = [UIColor labelColor];

        self.titleLabel.numberOfLines = 2;
        self.titleLabel.adjustsFontSizeToFitWidth = YES;
        self.titleLabel.minimumScaleFactor = 0.75;

        [self.cardView addSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];

        self.subtitleLabel.font          = [UIFont systemFontOfSize:13];

        self.subtitleLabel.textColor     = [UIColor secondaryLabelColor];

        self.subtitleLabel.numberOfLines = 3;

        [self.cardView addSubview:self.subtitleLabel];

        self.priceLabel = [[UILabel alloc] init];

        self.priceLabel.font          = [UIFont boldSystemFontOfSize:15];

        self.priceLabel.textAlignment = NSTextAlignmentRight;

        self.priceLabel.numberOfLines = 2;
        self.priceLabel.adjustsFontSizeToFitWidth = YES;
        self.priceLabel.minimumScaleFactor = 0.65;

        [self.cardView addSubview:self.priceLabel];

        self.badgeLabel = [[UILabel alloc] init];

        self.badgeLabel.font                        = [UIFont boldSystemFontOfSize:10];

        self.badgeLabel.textColor                   = [UIColor whiteColor];

        self.badgeLabel.textAlignment               = NSTextAlignmentCenter;

        self.badgeLabel.layer.cornerRadius          = 8;

        self.badgeLabel.layer.masksToBounds         = YES;

        self.badgeLabel.hidden                      = YES;

        self.badgeLabel.adjustsFontSizeToFitWidth   = YES;

        self.badgeLabel.minimumScaleFactor          = 0.6; // room for longer text like "+2500 FREE Coins*"

        self.badgeLabel.numberOfLines               = 2;

        [self.cardView addSubview:self.badgeLabel];

        // Small disclaimer shown under badgeLabel for subscription promo

        // items only (e.g. "*Extra coins are a one time bonus..."). Hidden

        // whenever an item has no badgeFootnoteText.

        self.footnoteLabel = [[UILabel alloc] init];

        self.footnoteLabel.font          = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];

        self.footnoteLabel.textColor     = [UIColor colorWithWhite:1.0 alpha:0.82];

        self.footnoteLabel.textAlignment = NSTextAlignmentCenter;

        self.footnoteLabel.numberOfLines = 4;

        self.footnoteLabel.hidden        = YES;

        [self.cardView addSubview:self.footnoteLabel];

        self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];

        self.actionButton.layer.cornerRadius  = 10;

        self.actionButton.titleLabel.font     = [UIFont boldSystemFontOfSize:14];

        [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

        [self.actionButton addTarget:self

                              action:@selector(actionTapped)

                    forControlEvents:UIControlEventTouchUpInside];

        [self.cardView addSubview:self.actionButton];

    }

    return self;

}

- (void)configureWithItem:(EZStoreItem *)item coinImage:(UIImage *)coinImage {

    UIColor *accentColor = item.accentColor ?: [UIColor systemBlueColor];

    self.cardView.backgroundColor   = [accentColor colorWithAlphaComponent:0.12];

    self.cardView.layer.borderColor = [accentColor colorWithAlphaComponent:0.3].CGColor;

    self.coinImageView.image  = coinImage;

    self.titleLabel.text      = item.title;

    self.subtitleLabel.text   = item.subtitle;

    self.priceLabel.text      = item.priceString;

    self.priceLabel.textColor = accentColor;

    if (item.badgeText) {

        self.badgeLabel.hidden          = NO;

        self.badgeLabel.text            = [NSString stringWithFormat:@" %@ ", item.badgeText];

        self.badgeLabel.backgroundColor = accentColor;

    } else {

        self.badgeLabel.hidden = YES;

    }

    if (item.badgeFootnoteText) {

        self.footnoteLabel.hidden = NO;

        self.footnoteLabel.text   = item.badgeFootnoteText;

    } else {

        self.footnoteLabel.hidden = YES;

    }

    if (item.isCurrentPlan) {

        [self.actionButton setTitle:NSLocalizedString(@"EZCoinStore.CancelPlan", @"Cancel plan button title") forState:UIControlStateNormal];

        self.actionButton.backgroundColor = [UIColor systemRedColor];

        self.actionButton.enabled         = YES;

    } else if (item.type == EZStoreItemTypeSubscription) {

        [self.actionButton setTitle:NSLocalizedString(@"EZCoinStore.Subscribe", @"Subscribe button title") forState:UIControlStateNormal];

        self.actionButton.backgroundColor = accentColor;

        self.actionButton.enabled         = YES;

    } else {

        [self.actionButton setTitle:NSLocalizedString(@"EZCoinStore.BuyNow", @"Buy now button title") forState:UIControlStateNormal];

        self.actionButton.backgroundColor = accentColor;

        self.actionButton.enabled         = YES;

    }

}

- (void)actionTapped {

    if (self.onAction) self.onAction();

}

- (void)layoutSubviews {

    [super layoutSubviews];

    CGFloat cellPadding  = 12;

    CGFloat cardWidth    = self.contentView.bounds.size.width - 32;

    CGFloat cardHeight   = self.contentView.bounds.size.height - 16;

    self.cardView.frame  = CGRectMake(16, 8, cardWidth, cardHeight);

    // The purchase button owns the bottom of every card. Center artwork in the
    // information area above it, rather than the entire card, so shorter
    // top-up cards do not make the coin appear to sink toward the bottom.
    CGFloat buttonHeight = 40;
    CGFloat actionTop = cardHeight - buttonHeight - cellPadding;
    CGFloat infoTop = cellPadding;
    CGFloat infoBottom = MAX(infoTop, actionTop - 8);
    CGFloat infoHeight = infoBottom - infoTop;
    CGFloat coinSize = MIN(60, MAX(42, infoHeight - 10));
    CGFloat coinY = infoTop + (infoHeight - coinSize) / 2.0;
    self.coinImageView.frame = CGRectMake(cellPadding, coinY, coinSize, coinSize);

    CGFloat textX = coinSize + cellPadding * 2;

    // Reserve a flexible right column for prices and sale text. It wraps
    // localized content instead of clipping it on narrow screens.
    CGFloat rightColumnWidth = MIN(140, MAX(112, floor(cardWidth * 0.34)));
    CGFloat rightX = cardWidth - rightColumnWidth - cellPadding;
    CGFloat textW = MAX(92, rightX - textX - 8);

    self.titleLabel.frame    = CGRectMake(textX, cellPadding, textW, 40);

    self.subtitleLabel.frame = CGRectMake(textX, cellPadding + 42, textW, 54);

    self.priceLabel.frame = CGRectMake(rightX, cellPadding, rightColumnWidth, 38);

    self.badgeLabel.frame = CGRectMake(rightX, cellPadding + 42, rightColumnWidth, 30);

    self.footnoteLabel.frame = CGRectMake(rightX, cellPadding + 74, rightColumnWidth, 48);

    CGFloat buttonWidth  = cardWidth - cellPadding * 2;

    self.actionButton.frame = CGRectMake(cellPadding, cardHeight - buttonHeight - cellPadding, buttonWidth, buttonHeight);

}

@end

// ── Main VC ───────────────────────────────────────────────────────────────────

@interface EZCoinStoreViewController () <UITableViewDelegate, UITableViewDataSource, SFSafariViewControllerDelegate>

@property (nonatomic, strong) UITableView             *tableView;

@property (nonatomic, strong) UIView                  *headerView;

@property (nonatomic, strong) UIView                  *promoBannerView;

@property (nonatomic, assign) BOOL                     isPromoActive;   // Manual flag — see kPromoBannerHeight comment above

@property (nonatomic, strong) UILabel                 *balanceLabel;

@property (nonatomic, strong) UILabel                 *warningLabel;

@property (nonatomic, strong) NSArray<EZStoreItem *>  *items;

@property (nonatomic, strong) UIImage                 *coinImage;

@property (nonatomic, strong) NSString                *pendingPurchaseType;  // @"subscription" or @"topup"

@property (nonatomic, strong) NSString                *pendingTierName;      // Reserved for subscription retry logic (currently unused)

@property (nonatomic, strong) NSString                *pendingOrderID;

@property (nonatomic, strong) EZCoinPotView           *storePotView;

@property (nonatomic, strong) UIActivityIndicatorView *spinner;

// Daily coins UI and state

@property (nonatomic, strong) UIButton  *dailyCoinsButton;       // Floating button top-left

@property (nonatomic, strong) UIButton  *usageLogButton;

@property (nonatomic, assign) BOOL       isDailyCoinsAvailable;  // Whether the server says coins can be claimed now

@property (nonatomic, strong) NSDate    *nextDailyClaimDate;     // ISO date from server; drives the countdown label

@property (nonatomic, assign) NSInteger  dailyCoinsPendingAmount; // 10 or 15 depending on membership; from server

//@property (nonatomic, strong) NSTimer   *countdownTimer;         // Fires every second to tick the "Next: Xh Ym Xs" label

@end

@implementation EZCoinStoreViewController

- (void)viewDidLoad {

    [super viewDidLoad];

    self.title = NSLocalizedString(@"EZCoinStore.Title", @"Coin store navigation title");

    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // No explicit close button — this VC is presented as a swipe-to-dismiss

    // sheet, and the left nav bar slot is used by the Daily Coins button

    // instead (see addDailyCoinsButton).

    // "History" — user-facing coin usage log (right nav bar button)

    self.coinImage = [UIImage imageNamed:@"EZCoin"];

    // ⚠️ Flip this manually to match whatever promo rows are active/unexpired

    // in the `promotions` table right now. Turning this on shows the BOGO

    // banner + badges below; it does NOT itself grant any coins — the actual

    // bonus crediting is entirely server-side (capture-paypal-order /

    // paypal-webhook), so this flag being briefly out of sync with the DB

    // only affects what the store *advertises*, never what gets paid out.

    self.isPromoActive = YES;

    [self buildItems];

    [self setupUI];

    [self refreshBalance];

    [self addDailyCoinsButton];

    [self refreshDailyCoinsStatus];

#if DEBUG
    // Debug-only transaction inspector lives on the title row; customer-facing
    // builds never compile this control, while Usage Log remains below.
    [self addLedgerButton];
#endif

}

- (void)viewWillAppear:(BOOL)animated {

    [super viewWillAppear:animated];

    // Lightweight countdown refresh using already-cached timing data.

    // No network call here — refreshDailyCoinsStatus handles that on load

    // and again after each refreshBalance.

    if (self.nextDailyClaimDate) {

        [self updateDailyCoinsButtonState];

    }

}

- (void)viewWillDisappear:(BOOL)animated {

    [super viewWillDisappear:animated];

    [self stopCountdownTimer];

}

// ── Build store items ─────────────────────────────────────────────────────────

// Overrides an item's badge + accent color to scream "promo" when

// isPromoActive is on. Applied to every package/tier. Skipped for a

// user's current active plan so the Cancel Plan button / status badge

// (CANCELLED, SUSPENDED, etc.) isn't stomped by promo styling — that status

// is more important for the user to see than a sale banner.

- (void)applyPromoBadgeIfNeededToItem:(EZStoreItem *)item {

    if (!self.isPromoActive || item.isCurrentPlan) return;

    item.badgeText   = NSLocalizedString(@"EZCoinStore.Badge.Buy1Get1", @"Buy one get one promo badge");

    item.accentColor = [UIColor colorWithRed:1.0 green:0.13 blue:0.35 alpha:1.0]; // hot pink/red — distinct from every other card color

}

// Subscription-specific version: shows the exact bonus coin amount instead

// of "BUY 1 GET 1" (subscriptions aren't literally bought-in-pairs — this

// makes clear it's a one-time bonus on the coin grant, not a doubled price

// or a recurring doubling), plus a small disclaimer footnote.

- (void)applySubscriptionPromoBadgeToItem:(EZStoreItem *)item {

    if (!self.isPromoActive || item.isCurrentPlan) return;

    item.badgeText         = [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.Promo.SubscriptionBadgeFormat", @"Subscription promo badge with bonus coins"), (long)item.coins];

    item.badgeFootnoteText = NSLocalizedString(@"EZCoinStore.Promo.SubscriptionFootnote", @"Subscription promo footnote");

    item.accentColor       = [UIColor colorWithRed:1.0 green:0.13 blue:0.35 alpha:1.0]; // matches the top-up promo color

}

- (void)buildItems {

    NSString *currentTier   = [EZEntitlementManager shared].currentTier;

    NSString *currentStatus = [EZEntitlementManager shared].currentStatus;

    // A plan only counts as "current" if the subscription is actually active.

    // Cancelled/suspended/expired accounts should see the Subscribe button again.

    BOOL isActive = [currentStatus isEqualToString:@"active"];

    NSMutableArray *items = [NSMutableArray array];

    // ── Subscription tiers ────────────────────────────────────────────────────

    // "basic" is being retired as a new-signup option in favor of the
    // $4.99/wk tier below, but existing subscribers on the old $4.99/mo plan
    // are grandfathered indefinitely -- their PayPal subscription is untouched,
    // this only changes what NEW purchases look like. isLegacyBasicSubscriber
    // detects that case so the card still shows correctly for them instead of
    // looking like an orphaned plan with no matching row.
    BOOL isLegacyBasicSubscriber = isActive && [currentTier isEqualToString:@"basic"];

    EZStoreItem *basic    = [EZStoreItem new];
    basic.title           = NSLocalizedString(@"EZCoinStore.Tier.Basic", @"Basic subscription tier name");
    if (isLegacyBasicSubscriber) {
        basic.subtitle        = NSLocalizedString(@"EZCoinStore.Tier.BasicSubtitle", @"Basic subscription description");
        basic.priceString     = NSLocalizedString(@"EZCoinStore.Tier.BasicPrice", @"Basic subscription price");
        basic.planOrPackageID = kTierBasic;
    } else {
        basic.title           = NSLocalizedString(@"EZCoinStore.Tier.BasicWeekly", @"Basic weekly subscription tier name");
        basic.subtitle        = NSLocalizedString(@"EZCoinStore.Tier.BasicWeeklySubtitle", @"Basic weekly subscription description");
        basic.priceString     = NSLocalizedString(@"EZCoinStore.Tier.BasicWeeklyPrice", @"Basic weekly subscription price");
        basic.planOrPackageID = kTierBasicWeekly;
    }
    basic.type            = EZStoreItemTypeSubscription;
    basic.coins           = 400;
    basic.accentColor     = [UIColor systemBlueColor];
    basic.isCurrentPlan   = isActive && ([currentTier isEqualToString:@"basic"] || [currentTier isEqualToString:@"basic_weekly"]);
    if (([currentTier isEqualToString:@"basic"] || [currentTier isEqualToString:@"basic_weekly"]) && !isActive && currentStatus)
        basic.badgeText   = currentStatus.uppercaseString;
    [self applySubscriptionPromoBadgeToItem:basic];
    [items addObject:basic];

    EZStoreItem *standard    = [EZStoreItem new];

    standard.title           = NSLocalizedString(@"EZCoinStore.Tier.Standard", @"Standard subscription tier name");

    standard.subtitle        = NSLocalizedString(@"EZCoinStore.Tier.StandardSubtitle", @"Standard subscription description");

    standard.priceString     = NSLocalizedString(@"EZCoinStore.Tier.StandardPrice", @"Standard subscription price");

    standard.planOrPackageID = kTierStandard;

    standard.type            = EZStoreItemTypeSubscription;

    standard.coins           = 900;

    standard.accentColor     = [UIColor systemPurpleColor];

    standard.isCurrentPlan = isActive && ([currentTier isEqualToString:@"standard"] || [currentTier isEqualToString:@"standard_annual"]);

    if (([currentTier isEqualToString:@"standard"] || [currentTier isEqualToString:@"standard_annual"]) && !isActive && currentStatus)

        standard.badgeText   = currentStatus.uppercaseString;

    else if (!standard.isCurrentPlan)

        standard.badgeText   = NSLocalizedString(@"EZCoinStore.Badge.Popular", @"Popular badge");

    [self applySubscriptionPromoBadgeToItem:standard]; // takes priority over POPULAR

    [items addObject:standard];

    EZStoreItem *pro    = [EZStoreItem new];

    pro.title           = NSLocalizedString(@"EZCoinStore.Tier.Pro", @"Pro subscription tier name");

    pro.subtitle        = NSLocalizedString(@"EZCoinStore.Tier.ProSubtitle", @"Pro subscription description");

    pro.priceString     = NSLocalizedString(@"EZCoinStore.Tier.ProPrice", @"Pro subscription price");

    pro.planOrPackageID = kTierPro;

    pro.type            = EZStoreItemTypeSubscription;

    pro.coins           = 1600;

    pro.accentColor     = [UIColor systemOrangeColor];

    pro.isCurrentPlan = isActive && ([currentTier isEqualToString:@"pro"] || [currentTier isEqualToString:@"pro_annual"]);

    if (([currentTier isEqualToString:@"pro"] || [currentTier isEqualToString:@"pro_annual"]) && !isActive && currentStatus)

        pro.badgeText    = currentStatus.uppercaseString;

    else if (!pro.isCurrentPlan)

        pro.badgeText    = NSLocalizedString(@"EZCoinStore.Badge.BestValue", @"Best value badge");

    [self applySubscriptionPromoBadgeToItem:pro]; // now included — takes priority over BEST VALUE

    [items addObject:pro];

    EZStoreItem *ultra    = [EZStoreItem new];

    ultra.title           = NSLocalizedString(@"EZCoinStore.Tier.Ultra", @"Ultra subscription tier name");

    ultra.subtitle        = NSLocalizedString(@"EZCoinStore.Tier.UltraSubtitle", @"Ultra subscription description");

    ultra.priceString     = NSLocalizedString(@"EZCoinStore.Tier.UltraPrice", @"Ultra subscription price");

    ultra.planOrPackageID = kTierUltra;

    ultra.type            = EZStoreItemTypeSubscription;

    ultra.coins           = 2500;

    ultra.accentColor     = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0]; // gold

    ultra.isCurrentPlan = isActive && ([currentTier isEqualToString:@"ultra"] || [currentTier isEqualToString:@"ultra_annual"]);

    if (([currentTier isEqualToString:@"ultra"] || [currentTier isEqualToString:@"ultra_annual"]) && !isActive && currentStatus)

        ultra.badgeText   = currentStatus.uppercaseString;

    else

        ultra.badgeText   = NSLocalizedString(@"EZCoinStore.Badge.Ultra", @"Ultra badge");

    [self applySubscriptionPromoBadgeToItem:ultra]; // now included — takes priority over ULTRA

    [items addObject:ultra];

    // Power and Enterprise both offer an annual option, presented via an
    // upsell shown after the user taps Subscribe (see tableView:didSelectRowAtIndexPath:)
    // rather than as separate store rows, so the store list doesn't grow by
    // two more cards for something most people will only consider once
    // they've already decided to subscribe.

    EZStoreItem *power    = [EZStoreItem new];
    power.title           = NSLocalizedString(@"EZCoinStore.Tier.Power", @"Power subscription tier name");
    power.subtitle        = NSLocalizedString(@"EZCoinStore.Tier.PowerSubtitle", @"Power subscription description");
    power.priceString     = @"$49.99/mo";
    power.planOrPackageID = kTierPower;
    power.type            = EZStoreItemTypeSubscription;
    power.coins            = 6250;
    power.accentColor     = [UIColor systemIndigoColor];
    power.isCurrentPlan   = isActive && ([currentTier isEqualToString:@"power"] || [currentTier isEqualToString:@"power_annual"]);
    if (([currentTier isEqualToString:@"power"] || [currentTier isEqualToString:@"power_annual"]) && !isActive && currentStatus)
        power.badgeText   = currentStatus.uppercaseString;
    else if (!power.isCurrentPlan)
        power.badgeText   = NSLocalizedString(@"EZCoinStore.Badge.Power", @"Power tier badge");
    [self applySubscriptionPromoBadgeToItem:power];
    [items addObject:power];

    EZStoreItem *enterprise    = [EZStoreItem new];
    enterprise.title           = NSLocalizedString(@"EZCoinStore.Tier.Enterprise", @"Enterprise subscription tier name");
    enterprise.subtitle        = NSLocalizedString(@"EZCoinStore.Tier.EnterpriseSubtitle", @"Enterprise subscription description");
    enterprise.priceString     = @"$99.99/mo";
    enterprise.planOrPackageID = kTierEnterprise;
    enterprise.type            = EZStoreItemTypeSubscription;
    enterprise.coins            = 12500;
    enterprise.accentColor     = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:1.0]; // black — top-tier accent
    enterprise.isCurrentPlan   = isActive && ([currentTier isEqualToString:@"enterprise"] || [currentTier isEqualToString:@"enterprise_annual"]);
    if (([currentTier isEqualToString:@"enterprise"] || [currentTier isEqualToString:@"enterprise_annual"]) && !isActive && currentStatus)
        enterprise.badgeText   = currentStatus.uppercaseString;
    else if (!enterprise.isCurrentPlan)
        enterprise.badgeText   = NSLocalizedString(@"EZCoinStore.Badge.Enterprise", @"Enterprise tier badge");
    [self applySubscriptionPromoBadgeToItem:enterprise];
    [items addObject:enterprise];

    // ── One-time top-ups ──────────────────────────────────────────────────────

    EZStoreItem *topup1    = [EZStoreItem new];

    topup1.title           = NSLocalizedString(@"EZCoinStore.TopUp.Starter", @"Coin starter pack title");

    topup1.subtitle        = NSLocalizedString(@"EZCoinStore.TopUp.StarterSubtitle", @"Coin starter pack description");

    topup1.priceString     = @"$5.00";

    topup1.planOrPackageID = @"TOPUP_400";

    topup1.type            = EZStoreItemTypeTopUp;

    topup1.coins           = 400;

    topup1.accentColor     = [UIColor systemTealColor];

    [self applyPromoBadgeIfNeededToItem:topup1];

    [items addObject:topup1];

    EZStoreItem *topup2    = [EZStoreItem new];

    topup2.title           = NSLocalizedString(@"EZCoinStore.TopUp.Value", @"Coin value pack title");

    topup2.subtitle        = NSLocalizedString(@"EZCoinStore.TopUp.ValueSubtitle", @"Coin value pack description");

    topup2.priceString     = @"$10.00";

    topup2.planOrPackageID = @"TOPUP_900";

    topup2.type            = EZStoreItemTypeTopUp;

    topup2.coins           = 900;

    topup2.accentColor     = [UIColor systemGreenColor];

    topup2.badgeText       = NSLocalizedString(@"EZCoinStore.Badge.Save10", @"Savings badge");

    [self applyPromoBadgeIfNeededToItem:topup2]; // takes priority over SAVE 10%

    [items addObject:topup2];
    EZStoreItem *topup3    = [EZStoreItem new];
    topup3.title           = NSLocalizedString(@"EZCoinStore.TopUp.Ultra", @"Ultra coin pack title");
    topup3.subtitle        = NSLocalizedString(@"EZCoinStore.TopUp.UltraSubtitle", @"Ultra coin pack description");
    topup3.priceString     = @"$20.00";
    topup3.planOrPackageID = @"TOPUP_2500";
    topup3.type            = EZStoreItemTypeTopUp;
    topup3.coins           = 2500;
    topup3.accentColor     = [UIColor systemIndigoColor];
    [self applyPromoBadgeIfNeededToItem:topup3];
    [items addObject:topup3];
    // Power one-time top-up — mirrors the $49.99 Power monthly tier's coin
    // amount, matching the existing pattern where a top-up grants the same
    // coins as a monthly subscription at the same price point.
    EZStoreItem *topup4    = [EZStoreItem new];
    topup4.title           = NSLocalizedString(@"EZCoinStore.TopUp.Power", @"Power coin pack title");
    topup4.subtitle        = NSLocalizedString(@"EZCoinStore.TopUp.PowerSubtitle", @"Power coin pack description");
    topup4.priceString     = @"$49.99";
    topup4.planOrPackageID = @"TOPUP_6250";
    topup4.type            = EZStoreItemTypeTopUp;
    topup4.coins           = 6250;
    topup4.accentColor     = [UIColor systemIndigoColor];
    [self applyPromoBadgeIfNeededToItem:topup4];
    [items addObject:topup4];

    // Enterprise one-time top-up — mirrors the $99.99 Enterprise monthly tier.
    EZStoreItem *topup5    = [EZStoreItem new];
    topup5.title           = NSLocalizedString(@"EZCoinStore.TopUp.Enterprise", @"Enterprise coin pack title");
    topup5.subtitle        = NSLocalizedString(@"EZCoinStore.TopUp.EnterpriseSubtitle", @"Enterprise coin pack description");
    topup5.priceString     = @"$99.99";
    topup5.planOrPackageID = @"TOPUP_12500";
    topup5.type            = EZStoreItemTypeTopUp;
    topup5.coins           = 12500;
    topup5.accentColor     = [UIColor systemPinkColor];
    [self applyPromoBadgeIfNeededToItem:topup5];
    [items addObject:topup5];

    self.items = [items copy];

}

// ── UI Setup ──────────────────────────────────────────────────────────────────

// ── Promo banner ──────────────────────────────────────────────────────────────

// Attention-grabbing strip pinned to the top of the store, above the title.

// Hot red/orange gradient + a slow pulse so it reads as "sale" at a glance,

// without being so aggressive it feels broken. Purely visual — see

// isPromoActive's comment for how this relates to the server-side promo state.

- (UIView *)buildPromoBannerView {

    self.promoBannerView = [[UIView alloc]

        initWithFrame:CGRectMake(0, kPromoBannerTopPadding, self.view.bounds.size.width, kPromoBannerHeight)];

    self.promoBannerView.clipsToBounds = YES;

    CAGradientLayer *gradientLayer = [CAGradientLayer layer];

    gradientLayer.frame  = self.promoBannerView.bounds;

    gradientLayer.colors = @[

        (id)[UIColor colorWithRed:1.0 green:0.15 blue:0.30 alpha:1.0].CGColor,

        (id)[UIColor colorWithRed:1.0 green:0.45 blue:0.05 alpha:1.0].CGColor,

    ];

    gradientLayer.startPoint = CGPointMake(0, 0.5);

    gradientLayer.endPoint   = CGPointMake(1, 0.5);

    [self.promoBannerView.layer insertSublayer:gradientLayer atIndex:0];

    UILabel *headlineLabel = [[UILabel alloc]

        initWithFrame:CGRectMake(12, 7, self.view.bounds.size.width - 24, 48)];

    headlineLabel.text          = NSLocalizedString(@"EZCoinStore.Promo.Headline", @"Promo banner headline");

    headlineLabel.font          = [UIFont boldSystemFontOfSize:22];

    headlineLabel.textColor     = [UIColor whiteColor];

    headlineLabel.textAlignment = NSTextAlignmentCenter;

    headlineLabel.numberOfLines = 2;

    headlineLabel.adjustsFontSizeToFitWidth = YES;

    [self.promoBannerView addSubview:headlineLabel];

    UILabel *subtextLabel = [[UILabel alloc]

        initWithFrame:CGRectMake(12, 57, self.view.bounds.size.width - 24, 44)];

    subtextLabel.text          = NSLocalizedString(@"EZCoinStore.Promo.Subtitle", @"Promo banner subtitle");

    subtextLabel.font          = [UIFont boldSystemFontOfSize:15];

    subtextLabel.textColor     = [UIColor colorWithWhite:1.0 alpha:0.92];

    subtextLabel.textAlignment = NSTextAlignmentCenter;

    subtextLabel.numberOfLines = 2;

    subtextLabel.adjustsFontSizeToFitWidth = YES;

    [self.promoBannerView addSubview:subtextLabel];

    // Slow, gentle pulse — enough to catch the eye scrolling past, not

    // frantic enough to look like a rendering glitch.

    CABasicAnimation *pulseAnimation = [CABasicAnimation animationWithKeyPath:@"transform.scale"];

    pulseAnimation.fromValue          = @1.0;

    pulseAnimation.toValue            = @1.05;

    pulseAnimation.duration           = 0.85;

    pulseAnimation.autoreverses       = YES;

    pulseAnimation.repeatCount        = HUGE_VALF;

    pulseAnimation.timingFunction     = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

    [headlineLabel.layer addAnimation:pulseAnimation forKey:@"promoPulse"];

    return self.promoBannerView;

}

- (void)setupUI {

    // When the promo banner is showing, everything else in the header shifts

    // down by kPromoBannerHeight so nothing overlaps it.

    CGFloat promoOffset = self.isPromoActive ? kPromoBannerHeight : 0;

    static CGFloat const kStoreControlsHeight = 48.0;
    CGFloat headerHeight = 62 + promoOffset + kStoreControlsHeight;

    // Leave enough clearance above the balance label for the floating

    // daily-coins countdown button (pinned to the safe area top-left).

    self.headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, headerHeight)];

    self.headerView.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1.0];

    if (self.isPromoActive) {

        UIView *promoBanner = [self buildPromoBannerView];
        CGRect promoFrame = promoBanner.frame;
        promoFrame.origin.y = kStoreControlsHeight;
        promoBanner.frame = promoFrame;
        [self.headerView addSubview:promoBanner];

    }

    self.balanceLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 8 + promoOffset + kStoreControlsHeight, self.view.bounds.size.width, 22)];

    self.balanceLabel.font          = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];

    self.balanceLabel.textColor     = [UIColor secondaryLabelColor];

    self.balanceLabel.textAlignment = NSTextAlignmentCenter;

    self.balanceLabel.text          = NSLocalizedString(@"EZCoinStore.LoadingBalance", @"Balance loading text");

    [self.headerView addSubview:self.balanceLabel];

    // Low-coin warning banner — shown when the store is opened because

    // the user ran out mid-session (triggeringFeatureName is set by the caller)

    self.warningLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 34 + promoOffset + kStoreControlsHeight, self.view.bounds.size.width, 28)];

    self.warningLabel.backgroundColor = [UIColor systemRedColor];

    self.warningLabel.font            = [UIFont boldSystemFontOfSize:13];

    self.warningLabel.textColor       = [UIColor whiteColor];

    self.warningLabel.textAlignment   = NSTextAlignmentCenter;

    self.warningLabel.hidden          = !self.showLowCoinsWarning;

    if (self.showLowCoinsWarning) {

        NSString *featureName = self.triggeringFeatureName ?: NSLocalizedString(@"EZCoinStore.ThisFeature", @"Fallback feature name in low balance warning");

        self.warningLabel.text = [NSString stringWithFormat:

            NSLocalizedString(@"EZCoinStore.NotEnoughCoins", @"Low balance warning with feature name"), featureName];

    }

    [self.headerView addSubview:self.warningLabel];

    self.usageLogButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.usageLogButton setImage:[UIImage systemImageNamed:@"clock.arrow.circlepath"] forState:UIControlStateNormal];
    [self.usageLogButton setTitle:[NSString stringWithFormat:@" %@", NSLocalizedString(@"EZCoinStore.UsageLog", @"Usage Log")] forState:UIControlStateNormal];
    self.usageLogButton.tintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];
    self.usageLogButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [self.usageLogButton addTarget:self action:@selector(historyTapped) forControlEvents:UIControlEventTouchUpInside];
    self.usageLogButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerView addSubview:self.usageLogButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.usageLogButton.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-16],
        [self.usageLogButton.centerYAnchor constraintEqualToAnchor:self.headerView.topAnchor constant:kStoreControlsHeight / 2.0],
    ]];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];

    self.tableView.delegate         = self;

    self.tableView.dataSource       = self;

    self.tableView.backgroundColor  = [UIColor systemBackgroundColor];

    self.tableView.separatorStyle   = UITableViewCellSeparatorStyleNone;

    self.tableView.tableHeaderView  = self.headerView;

    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [self.tableView registerClass:[EZStoreCell class] forCellReuseIdentifier:@"EZStoreCell"];

    [self.view addSubview:self.tableView];

    self.spinner = [[UIActivityIndicatorView alloc]

        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];

    self.spinner.center           = self.view.center;

    self.spinner.hidesWhenStopped = YES;

    [self.view addSubview:self.spinner];

}

- (void)refreshBalance {

    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {

        NSString *tier   = [EZEntitlementManager shared].currentTier;

        NSString *status = [EZEntitlementManager shared].currentStatus;

        NSString *planDisplay;

    BOOL hasTier = tier.length > 0 &&
        [tier caseInsensitiveCompare:@"null"] != NSOrderedSame;

        if ([status isEqualToString:@"coins_only"] || !hasTier) {

            planDisplay = NSLocalizedString(@"EZCoinStore.NoActiveSubscription", @"No active subscription status");

        } else if (status.length && ![status isEqualToString:@"active"]) {

            planDisplay = [NSString stringWithFormat:@"%@ (%@)",

                           tier.capitalizedString, status.capitalizedString];

        } else {

            planDisplay = tier.capitalizedString;

        }

        self.balanceLabel.text = [NSString stringWithFormat:

            NSLocalizedString(@"EZCoinStore.BalanceFormat", @"Balance and plan display format"), (long)balance, planDisplay];

        [self buildItems];

        [self.tableView reloadData];

        // Re-check daily coin availability after every balance refresh.

        // Handles the edge case where the user's membership tier changed since

        // the last check (e.g. they just subscribed or their plan was cancelled).

        [self refreshDailyCoinsStatus];

    }];

}

// ── UITableView ───────────────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {

    return 2;

}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {

    if (section == 0) return 6; // subscription tiers

    return 5;                   // top-up packages

}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {

    return section == 0 ? NSLocalizedString(@"EZCoinStore.Section.Subscriptions", @"Subscriptions section header") : NSLocalizedString(@"EZCoinStore.Section.OneTimeTopUps", @"One-time top-ups section header");

}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {

    UIView *sectionHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 36)];

    sectionHeaderView.backgroundColor = [UIColor clearColor];

    UILabel *sectionTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 8, 300, 20)];

    sectionTitleLabel.text                    = section == 0 ? NSLocalizedString(@"EZCoinStore.Section.Subscriptions", @"Subscriptions section header") : NSLocalizedString(@"EZCoinStore.Section.OneTimeTopUps", @"One-time top-ups section header");

    sectionTitleLabel.font                    = [UIFont boldSystemFontOfSize:11];

    sectionTitleLabel.textColor               = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.8];

    sectionTitleLabel.adjustsFontSizeToFitWidth = YES;

    [sectionHeaderView addSubview:sectionTitleLabel];

    UIView *goldDividerLine = [[UIView alloc] initWithFrame:CGRectMake(20, 30, tableView.bounds.size.width - 40, 0.5)];

    goldDividerLine.backgroundColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.3];

    [sectionHeaderView addSubview:goldDividerLine];

    return sectionHeaderView;

}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {

    return 36;

}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {

    // Subscription cards (section 0) need extra room only when the promo

    // badge + footnote are showing; top-ups (section 1) still just show the

    // short "BUY 1 GET 1" badge and never need the taller layout.

    if (indexPath.section == 0 && self.isPromoActive) {

        return 222;

    }

        return 184;

}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    EZStoreCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZStoreCell"

                                                        forIndexPath:indexPath];

    NSInteger itemIndex = indexPath.section == 0 ? indexPath.row : 6 + indexPath.row;

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

// ── Free Coins button ─────────────────────────────────────────────────────────

// Floats top-left over the table content, mirroring the DEBUG Ledger button on the right.

// Coin amounts and eligibility are always enforced server-side. The button state here

// is purely informational — a jailbreak user can enable a disabled button, but the

// edge function will still reject the claim if the 6-hour window hasn't elapsed.

- (void)addDailyCoinsButton {

    self.dailyCoinsButton = [UIButton buttonWithType:UIButtonTypeSystem];

    [self.dailyCoinsButton setTitle:NSLocalizedString(@"EZCoinStore.DailyCoins", @"Daily coins button title") forState:UIControlStateNormal];

    self.dailyCoinsButton.contentEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 0);

    self.dailyCoinsButton.titleLabel.font   = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.dailyCoinsButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // Muted until the server confirms eligibility

    self.dailyCoinsButton.tintColor = [UIColor secondaryLabelColor];

    self.dailyCoinsButton.enabled   = NO;

    [self.dailyCoinsButton addTarget:self

                              action:@selector(dailyCoinsTapped:)

                    forControlEvents:UIControlEventTouchUpInside];

    self.dailyCoinsButton.translatesAutoresizingMaskIntoConstraints = NO;

    // Keep the claim countdown on its own row directly under the title.
    // This leaves the navigation title centered and keeps it independent from
    // the Usage Log control on the same row's right edge.
    [self.headerView addSubview:self.dailyCoinsButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.dailyCoinsButton.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:16],
        [self.dailyCoinsButton.centerYAnchor constraintEqualToAnchor:self.headerView.topAnchor constant:24],
        [self.dailyCoinsButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.usageLogButton.leadingAnchor constant:-8],
        [self.dailyCoinsButton.widthAnchor constraintLessThanOrEqualToAnchor:self.headerView.widthAnchor multiplier:0.52],
    ]];

}

// Refreshes the button label and enabled state from the current cached values.

// Does NOT make a network call — call refreshDailyCoinsStatus for that.

- (void)updateDailyCoinsButtonState {

    if (self.isDailyCoinsAvailable) {

        [self stopCountdownTimer];

        NSString *buttonTitle = self.dailyCoinsPendingAmount > 0

            ? [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.DailyCoins.FreeFormat", @"Available daily coins button title"), (long)self.dailyCoinsPendingAmount]

            : NSLocalizedString(@"EZCoinStore.DailyCoins.Free", @"Available daily coins button title");

        [self.dailyCoinsButton setTitle:buttonTitle forState:UIControlStateNormal];

        self.dailyCoinsButton.tintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

        self.dailyCoinsButton.enabled   = YES;

    } else if (self.nextDailyClaimDate) {

        NSTimeInterval secondsRemaining = [self.nextDailyClaimDate timeIntervalSinceNow];

        if (secondsRemaining > 0) {

            [self updateCountdownLabel:secondsRemaining];

            self.dailyCoinsButton.tintColor = [UIColor whiteColor];

            self.dailyCoinsButton.enabled   = NO;

            [self startCountdownTimer];

        } else {

            // Countdown hit zero — optimistically enable; server still verifies on tap

            [self stopCountdownTimer];

            [self.dailyCoinsButton setTitle:NSLocalizedString(@"EZCoinStore.DailyCoins.Free", @"Available daily coins button title") forState:UIControlStateNormal];

            self.dailyCoinsButton.tintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

            self.dailyCoinsButton.enabled   = YES;

            self.isDailyCoinsAvailable      = YES;

        }

    } else {

        // No cached data yet — stays muted until first server response arrives

        [self stopCountdownTimer];

        [self.dailyCoinsButton setTitle:NSLocalizedString(@"EZCoinStore.DailyCoins", @"Daily coins button title") forState:UIControlStateNormal];

        self.dailyCoinsButton.tintColor = [UIColor secondaryLabelColor];

        self.dailyCoinsButton.enabled   = NO;

    }

}

// Sets the button title to a human-readable countdown for the given number of seconds.

// Called both from updateDailyCoinsButtonState (initial render) and the repeating timer.

- (void)updateCountdownLabel:(NSTimeInterval)secondsRemaining {

    NSInteger totalSeconds = (NSInteger)secondsRemaining;

    NSInteger hours        = totalSeconds / 3600;

    NSInteger minutes      = (totalSeconds % 3600) / 60;

    NSInteger seconds      = totalSeconds % 60;

    NSString *countdownText;

    if (hours > 0) {

        countdownText = [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.DailyCoins.NextHours", @"Daily coins countdown in hours and minutes"), (long)hours, (long)minutes];

    } else if (minutes > 0) {

        countdownText = [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.DailyCoins.NextMinutes", @"Daily coins countdown in minutes and seconds"), (long)minutes, (long)seconds];

    } else {

        countdownText = [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.DailyCoins.NextSeconds", @"Daily coins countdown in seconds"), (long)seconds];

    }

    [self.dailyCoinsButton setTitle:countdownText forState:UIControlStateNormal];

}

// Starts the per-second timer if it isn't already running.

- (void)startCountdownTimer {

    if (self.countdownTimer) return; // Already ticking

    self.countdownTimer = [NSTimer scheduledTimerWithTimeInterval:1.0

                                                           target:self

                                                         selector:@selector(countdownTimerFired:)

                                                         userInfo:nil

                                                          repeats:YES];

}

// Stops and releases the timer.

- (void)stopCountdownTimer {

    [self.countdownTimer invalidate];

    self.countdownTimer = nil;

}

// Fires every second while the countdown is active.

- (void)countdownTimerFired:(NSTimer *)timer {

    if (!self.nextDailyClaimDate) {

        [self stopCountdownTimer];

        return;

    }

    NSTimeInterval secondsRemaining = [self.nextDailyClaimDate timeIntervalSinceNow];

    if (secondsRemaining <= 0) {

        // Time's up — flip to available and let updateDailyCoinsButtonState handle the rest

        [self stopCountdownTimer];

        self.isDailyCoinsAvailable = YES;

        [self cancelDailyCoinsReadyReminder];

        [self updateDailyCoinsButtonState];

    } else {

        [self updateCountdownLabel:secondsRemaining];

    }

}

// MARK: - Daily coin ready reminder

- (void)cancelDailyCoinsReadyReminder {

    [[UNUserNotificationCenter currentNotificationCenter]
        removePendingNotificationRequestsWithIdentifiers:@[kDailyCoinsReadyNotificationIdentifier]];
}

// Requests permission only immediately after a successful daily claim, when
// the value of this reminder is clear. Status refreshes can restore a pending
// reminder for people who have already granted permission, but never prompt.
- (void)scheduleDailyCoinsReadyReminderForDate:(NSDate *)date requestPermissionIfNeeded:(BOOL)requestPermissionIfNeeded {

    NSTimeInterval interval = [date timeIntervalSinceNow];
    if (!date || interval < 60.0) {
        [self cancelDailyCoinsReadyReminder];
        return;
    }

    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
    void (^scheduleReminder)(void) = ^{
        [notificationCenter removePendingNotificationRequestsWithIdentifiers:@[kDailyCoinsReadyNotificationIdentifier]];

        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = NSLocalizedString(@"EZCoinStore.DailyReminder.Title", @"Daily coins reminder notification title");
        content.body = NSLocalizedString(@"EZCoinStore.DailyReminder.Body", @"Daily coins reminder notification body");
        content.sound = [UNNotificationSound defaultSound];
        content.userInfo = @{ @"destination": @"daily-coins" };

        // A non-repeating interval trigger preserves the exact server cooldown
        // even if the cooldown changes from four to six hours in a future build.
        UNTimeIntervalNotificationTrigger *trigger =
            [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:interval repeats:NO];
        UNNotificationRequest *request =
            [UNNotificationRequest requestWithIdentifier:kDailyCoinsReadyNotificationIdentifier
                                                  content:content
                                                  trigger:trigger];
        [notificationCenter addNotificationRequest:request withCompletionHandler:^(NSError *error) {
            if (error) {
                NSLog(@"[EZCoinStore] Could not schedule daily coin reminder: %@", error.localizedDescription);
            }
        }];
    };

    [notificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusAuthorized ||
            settings.authorizationStatus == UNAuthorizationStatusProvisional ||
            settings.authorizationStatus == UNAuthorizationStatusEphemeral) {
            scheduleReminder();
        } else if (requestPermissionIfNeeded &&
                   settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [notificationCenter requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                                                   completionHandler:^(BOOL granted, NSError *error) {
                    if (granted) {
                        scheduleReminder();
                    } else if (error) {
                        NSLog(@"[EZCoinStore] Daily coin notification permission error: %@", error.localizedDescription);
                    }
                }];
            });
        }
    }];
}

// Asks the server whether coins can be claimed right now and how many would be awarded.

// Uses a GET request with ?check=1 so no coins are credited during a status poll.

- (void)refreshDailyCoinsStatus {

    NSString *token = [EZAuthManager shared].accessToken;

    if (!token) return; // Not signed in — button stays disabled

    NSURL *statusURL = [NSURL URLWithString:[[kStoreSupabaseURL

        stringByAppendingString:kDailyCoinsEndpoint]

        stringByAppendingString:@"?check=1"]];

    NSMutableURLRequest *statusRequest = [NSMutableURLRequest requestWithURL:statusURL];

    statusRequest.HTTPMethod      = @"GET";

    statusRequest.timeoutInterval = 10;

    [statusRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]

         forHTTPHeaderField:@"Authorization"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:statusRequest

        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        dispatch_async(dispatch_get_main_queue(), ^{

            if (error || !data) return; // Silent failure; button stays in its current state

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

            if (!json) return;

            self.isDailyCoinsAvailable   = jsonBool(json, @"available");

            self.dailyCoinsPendingAmount = jsonInteger(json, @"coins_to_award");

            self.nextDailyClaimDate      = dateFromISO8601String(jsonString(json, @"next_claim_at"));

            if (self.isDailyCoinsAvailable) {
                [self cancelDailyCoinsReadyReminder];
            } else {
                [self scheduleDailyCoinsReadyReminderForDate:self.nextDailyClaimDate requestPermissionIfNeeded:NO];
            }

            [self updateDailyCoinsButtonState];

        });

    }] resume];

}

// Called when the user taps the Daily Coins button.

- (void)dailyCoinsTapped:(UIButton *)sender {

    // Disable immediately to block double-taps while the request is in-flight

    self.dailyCoinsButton.enabled = NO;

    [self.dailyCoinsButton setTitle:NSLocalizedString(@"EZCoinStore.DailyCoins.Claiming", @"Daily coins claim in progress") forState:UIControlStateNormal];

    [self claimDailyCoins];

}

// POSTs to the claim-daily-coins edge function, which enforces the 6-hour cooldown

// server-side, determines the award amount by checking subscription status in the DB,

// credits coins, and returns the new balance.

- (void)claimDailyCoins {

    NSString *token = [EZAuthManager shared].accessToken;

    if (!token) {

        [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.NotSignedIn", @"Not signed in alert title") message:NSLocalizedString(@"EZCoinStore.Alert.SignInDailyCoins", @"Sign in message for daily coins")];

        self.isDailyCoinsAvailable = YES;

        [self updateDailyCoinsButtonState];

        return;

    }

    NSURL *claimURL = [NSURL URLWithString:[kStoreSupabaseURL

        stringByAppendingString:kDailyCoinsEndpoint]];

    NSMutableURLRequest *claimRequest = [NSMutableURLRequest requestWithURL:claimURL];

    claimRequest.HTTPMethod      = @"POST";

    claimRequest.timeoutInterval = 15;

    [claimRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [claimRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]

        forHTTPHeaderField:@"Authorization"];

    claimRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{} options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:claimRequest

        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        dispatch_async(dispatch_get_main_queue(), ^{

            if (error) {

                // Network error — let them retry

                [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.NetworkError", @"Network error alert title")

                        message:NSLocalizedString(@"EZCoinStore.Alert.ServerUnreachable", @"Server unreachable message")];

                self.isDailyCoinsAvailable = YES;

                [self updateDailyCoinsButtonState];

                return;

            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data

                                                                 options:0

                                                                   error:nil];

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

            if (httpResponse.statusCode == 200 && [json[@"success"] boolValue]) {

                NSInteger coinsAdded = jsonInteger(json, @"coins_added");

                NSInteger newBalance = jsonInteger(json, @"balance");

                // Record next-claim time from server so the countdown is accurate

                self.nextDailyClaimDate    = dateFromISO8601String(jsonString(json, @"next_claim_at"));

                self.isDailyCoinsAvailable = NO;

                [self scheduleDailyCoinsReadyReminderForDate:self.nextDailyClaimDate requestPermissionIfNeeded:YES];

                // Reflect new balance immediately before the delayed full refresh

                [[EZEntitlementManager shared] applyKnownBalance:newBalance];

                [self updateDailyCoinsButtonState];

                [self showCoinCelebration:coinsAdded newBalance:newBalance];

                [[NSNotificationCenter defaultCenter]

                    postNotificationName:@"EZSubscriptionUpdated" object:nil];

                // Delayed sync to pick up any secondary server-side processing

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),

                               dispatch_get_main_queue(), ^{

                    [self refreshBalance];

                });

            } else if (httpResponse.statusCode == 429

                       || [json[@"error"] isEqualToString:@"too_soon"]) {

                // Server rejected the claim — update countdown from authoritative server time

                self.nextDailyClaimDate    = dateFromISO8601String(jsonString(json, @"next_claim_at"));

                self.isDailyCoinsAvailable = NO;

                [self scheduleDailyCoinsReadyReminderForDate:self.nextDailyClaimDate requestPermissionIfNeeded:NO];

                [self updateDailyCoinsButtonState];

                [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.AlreadyClaimed", @"Daily coins already claimed alert title")

                        message:NSLocalizedString(@"EZCoinStore.Alert.AlreadyClaimedMessage", @"Daily coins cooldown message")];

            } else {

                // Unexpected server error — allow retry

                NSString *serverError = jsonString(json, @"error") ?: NSLocalizedString(@"EZCoinStore.Alert.GenericRetry", @"Generic retry error message");

                [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.Error", @"Generic error alert title") message:serverError];

                self.isDailyCoinsAvailable = YES;

                [self updateDailyCoinsButtonState];

            }

        });

    }] resume];

}

// ── Coin Ledger ───────────────────────────────────────────────────────────────

// Raw transaction inspector showing cost info and balance history.

// TODO: wrap in #if DEBUG before release build.

#if DEBUG

- (void)addLedgerButton {

    UIButton *ledgerButton = [UIButton buttonWithType:UIButtonTypeSystem];

    [ledgerButton setTitle:NSLocalizedString(@"EZCoinStore.Ledger", @"Debug ledger button title") forState:UIControlStateNormal];

    ledgerButton.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);

    ledgerButton.titleLabel.font   = [UIFont systemFontOfSize:16.0];

    [ledgerButton addTarget:self

                     action:@selector(ledgerButtonTapped:)

           forControlEvents:UIControlEventTouchUpInside];

    // Keep debug controls in the navigation bar so they never cover promo text.
    UIBarButtonItem *ledgerItem = [[UIBarButtonItem alloc] initWithCustomView:ledgerButton];
    if (self.navigationItem.rightBarButtonItem) {
        self.navigationItem.rightBarButtonItems = @[
            self.navigationItem.rightBarButtonItem, ledgerItem
        ];
    } else {
        self.navigationItem.rightBarButtonItem = ledgerItem;
    }

}

- (void)ledgerButtonTapped:(UIButton *)sender {

    EZCoinLedgerViewController *ledgerVC = [[EZCoinLedgerViewController alloc] init];

    if (self.navigationController) {

        [self.navigationController pushViewController:ledgerVC animated:YES];

    } else {

        UINavigationController *ledgerNav = [[UINavigationController alloc]

            initWithRootViewController:ledgerVC];

        ledgerNav.modalPresentationStyle = UIModalPresentationFullScreen;

        [self presentViewController:ledgerNav animated:YES completion:nil];

    }

}

#endif

/// User-facing coin usage history — triggered via the clock icon in the nav bar

- (void)historyTapped {

    EZCoinUsageViewController *usageVC = [[EZCoinUsageViewController alloc] init];

    UINavigationController *usageNav = [[UINavigationController alloc]

        initWithRootViewController:usageVC];

    usageNav.modalPresentationStyle = UIModalPresentationPageSheet;

    if (@available(iOS 15, *)) {

        UISheetPresentationController *sheet = usageNav.sheetPresentationController;

        sheet.detents               = @[UISheetPresentationControllerDetent.largeDetent];

        sheet.prefersGrabberVisible = YES;

    }

    [self presentViewController:usageNav animated:YES completion:nil];

}

// ── Purchase flow ─────────────────────────────────────────────────────────────

- (void)handlePurchaseForItem:(EZStoreItem *)item {

    NSString *token = [EZAuthManager shared].accessToken;

    if (!token) {

        [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.NotLoggedIn", @"Not logged in alert title") message:NSLocalizedString(@"EZCoinStore.Alert.SignInFirst", @"Sign in first message")];

        return;

    }

    // If the user taps their current active plan, offer to cancel it

    if (item.isCurrentPlan && item.type == EZStoreItemTypeSubscription) {

        UIAlertController *cancelAlert = [UIAlertController

            alertControllerWithTitle:NSLocalizedString(@"EZCoinStore.Alert.CancelSubscription", @"Cancel subscription confirmation title")

                             message:NSLocalizedString(@"EZCoinStore.Alert.CancelSubscriptionMessage", @"Cancel subscription confirmation message")

                      preferredStyle:UIAlertControllerStyleAlert];

        [cancelAlert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZCoinStore.KeepPlan", @"Keep subscription button title")

                                                        style:UIAlertActionStyleCancel

                                                      handler:nil]];

        [cancelAlert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZCoinStore.CancelPlan", @"Cancel plan button title")

                                                        style:UIAlertActionStyleDestructive

                                                      handler:^(UIAlertAction *action) {

            [self.spinner startAnimating];

            self.tableView.userInteractionEnabled = NO;

            [self cancelCurrentSubscriptionWithToken:token completion:^(BOOL success) {

                [self.spinner stopAnimating];

                self.tableView.userInteractionEnabled = YES;

                if (success) {

                    [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.Cancelled", @"Subscription cancelled alert title")

                            message:NSLocalizedString(@"EZCoinStore.Alert.CancelledMessage", @"Subscription cancelled message")];

                    [self refreshBalance];

                } else {

                    [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.Error", @"Generic error alert title")

                            message:NSLocalizedString(@"EZCoinStore.Alert.CancelFailed", @"Subscription cancellation failure message")];

                }

            }];

        }]];

        [self presentViewController:cancelAlert animated:YES completion:nil];

        return;

    }

    // Standard, Pro, Ultra, Power, and Enterprise all offer an annual option
    // at signup time via an upsell interstitial, rather than as separate
    // store rows (see buildItems). Everything else proceeds straight to
    // checkout as before. Basic Weekly deliberately has no annual option —
    // it's the low-commitment entry tier, an annual ask there works against
    // the point of it.
    if (item.type == EZStoreItemTypeSubscription &&
        ([item.planOrPackageID isEqualToString:kTierStandard]  ||
         [item.planOrPackageID isEqualToString:kTierPro]       ||
         [item.planOrPackageID isEqualToString:kTierUltra]     ||
         [item.planOrPackageID isEqualToString:kTierPower]     ||
         [item.planOrPackageID isEqualToString:kTierEnterprise])) {

        [self presentAnnualUpsellForMonthlyTier:item.planOrPackageID token:token];

        return;

    }

    [self.spinner startAnimating];

    self.tableView.userInteractionEnabled = NO;

    if (item.type == EZStoreItemTypeSubscription) {

        [self startSubscriptionForTier:item.planOrPackageID token:token];

    } else {

        [self startTopUpForPackageID:item.planOrPackageID coins:item.coins token:token];

    }

}

// ── Annual upsell ──────────────────────────────────────────────────────────────
// Shown only for Power/Enterprise, only at the moment of subscribing (not
// shown for cancel or for other tiers). Lets the user compare the monthly
// price against the discounted annual price and savings before committing,
// without the annual option taking up a permanent row in the store list.
- (void)presentAnnualUpsellForMonthlyTier:(NSString *)monthlyTier token:(NSString *)token {

    // Each tier has two annual-button copy variants: the plain "save $X"
    // version, and a promo-aware version used only while isPromoActive is on
    // (see the comment on that property -- it's the manual flag you flip to
    // match real rows in the `promotions` table). The promo framing compares
    // against what a promo'd monthly signup nets (1 free month) rather than
    // full price, so it reads correctly as "2 MORE months" on top of that,
    // not as a claim that this stacks with the monthly bonus itself.
    NSDictionary *upsellConfig = @{
        kTierStandard: @{
            @"annualTier":  kTierStandardAnnual,
            @"tierTitle": NSLocalizedString(@"EZCoinStore.Tier.Standard", @"Standard tier name"), @"monthlyPrice": @"$10.00", @"annualPrice": @"$89.99", @"savings": @"$30",
        },
        kTierPro: @{
            @"annualTier":  kTierProAnnual,
            @"tierTitle": NSLocalizedString(@"EZCoinStore.Tier.Pro", @"Pro tier name"), @"monthlyPrice": @"$15.00", @"annualPrice": @"$134.99", @"savings": @"$45",
        },
        kTierUltra: @{
            @"annualTier":  kTierUltraAnnual,
            @"tierTitle": NSLocalizedString(@"EZCoinStore.Tier.Ultra", @"Ultra tier name"), @"monthlyPrice": @"$20.00", @"annualPrice": @"$179.99", @"savings": @"$60",
        },
        kTierPower: @{
            @"annualTier":  kTierPowerAnnual,
            @"tierTitle": NSLocalizedString(@"EZCoinStore.Tier.Power", @"Power tier name"), @"monthlyPrice": @"$49.99", @"annualPrice": @"$449.99", @"savings": @"$150",
        },
        kTierEnterprise: @{
            @"annualTier":  kTierEnterpriseAnnual,
            @"tierTitle": NSLocalizedString(@"EZCoinStore.Tier.Enterprise", @"Enterprise tier name"), @"monthlyPrice": @"$99.99", @"annualPrice": @"$899.99", @"savings": @"$300",
        },
    };

    NSDictionary *config = upsellConfig[monthlyTier];
    if (!config) {
        // Shouldn't happen -- the tap-handler condition above only routes
        // tiers that have an entry here. Fail safe to a normal monthly
        // subscribe rather than silently doing nothing.
        [self.spinner startAnimating];
        self.tableView.userInteractionEnabled = NO;
        [self startSubscriptionForTier:monthlyTier token:token];
        return;
    }

    NSString *annualTier       = config[@"annualTier"];
    NSString *title = [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.Upsell.AnnualTitleFormat", @"Annual offer title"), config[@"tierTitle"]];
    NSString *monthlyButtonText = [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.Upsell.MonthlyButtonFormat", @"Monthly option button"), config[@"monthlyPrice"]];
    NSString *annualButtonText = self.isPromoActive
        ? [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.Upsell.AnnualButtonPromoFormat", @"Annual promotional option button"), config[@"annualPrice"]]
        : [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.Upsell.AnnualButtonFormat", @"Annual option button"), config[@"annualPrice"], config[@"savings"]];

    NSString *message = NSLocalizedString(@"EZCoinStore.Upsell.Message", @"Pay yearly and save 25% vs monthly message");

    // Tint the card's title/border with the tapped tier's own accent color
    // (matching buildItems) rather than always using plain gold, so the
    // upsell still visually ties back to the card the user just tapped.
    // Enterprise's accent is black in buildItems, which wouldn't read
    // against this card's dark background, so it falls back to gold here.
    NSDictionary *tierAccents = @{
        kTierStandard:  [UIColor systemPurpleColor],
        kTierPro:       [UIColor systemOrangeColor],
        kTierUltra:     [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0],
        kTierPower:     [UIColor systemIndigoColor],
        kTierEnterprise:[UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0],
    };
    UIColor *accent = tierAccents[monthlyTier] ?: [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.75];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.alpha            = 0;
    overlay.tag              = 9911;
    [self.view addSubview:overlay];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 400)];
    card.center             = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2);
    card.backgroundColor    = [UIColor colorWithRed:0.08 green:0.08 blue:0.14 alpha:1.0];
    card.layer.cornerRadius = 24;
    card.layer.borderWidth  = 1.5;
    card.layer.borderColor  = [accent colorWithAlphaComponent:0.6].CGColor;
    card.transform          = CGAffineTransformMakeScale(0.7, 0.7);
    [overlay addSubview:card];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 28, 260, 50)];
    titleLabel.text          = title;
    titleLabel.font          = [UIFont boldSystemFontOfSize:20];
    titleLabel.textColor     = accent;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 2;
    [card addSubview:titleLabel];

    UILabel *messageLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 84, 252, 44)];
    messageLabel.text          = message;
    messageLabel.font          = [UIFont systemFontOfSize:14];
    messageLabel.textColor     = [UIColor secondaryLabelColor];
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.numberOfLines = 2;
    [card addSubview:messageLabel];

    // Primary CTA — annual, styled like the celebration screen's gold
    // dismiss button so it reads as the recommended choice.
    UIButton *annualButton = [UIButton buttonWithType:UIButtonTypeSystem];
    annualButton.frame              = CGRectMake(30, 150, 240, 56);
    annualButton.backgroundColor    = accent;
    annualButton.layer.cornerRadius = 14;
    annualButton.titleLabel.font    = [UIFont boldSystemFontOfSize:16];
    annualButton.titleLabel.numberOfLines = 2;
    annualButton.titleLabel.textAlignment = NSTextAlignmentCenter;
    [annualButton setTitle:annualButtonText forState:UIControlStateNormal];
    [annualButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [annualButton addAction:[UIAction actionWithHandler:^(UIAction *action) {
        [self dismissAnnualUpsellThen:^{
            [self.spinner startAnimating];
            self.tableView.userInteractionEnabled = NO;
            [self startSubscriptionForTier:annualTier token:token];
        }];
    }] forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:annualButton];

    UILabel *orLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 214, 260, 18)];
    orLabel.text          = NSLocalizedString(@"EZCoinStore.Upsell.Or", @"'or' divider text");
    orLabel.font          = [UIFont systemFontOfSize:12];
    orLabel.textColor     = [UIColor tertiaryLabelColor];
    orLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:orLabel];

    // Secondary option — monthly, outlined rather than filled so it doesn't
    // compete visually with the annual CTA above it.
    UIButton *monthlyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    monthlyButton.frame                  = CGRectMake(30, 240, 240, 56);
    monthlyButton.backgroundColor        = [UIColor clearColor];
    monthlyButton.layer.cornerRadius     = 14;
    monthlyButton.layer.borderWidth      = 1.5;
    monthlyButton.layer.borderColor      = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
    monthlyButton.titleLabel.font        = [UIFont boldSystemFontOfSize:16];
    monthlyButton.titleLabel.numberOfLines = 2;
    monthlyButton.titleLabel.textAlignment = NSTextAlignmentCenter;
    [monthlyButton setTitle:monthlyButtonText forState:UIControlStateNormal];
    [monthlyButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [monthlyButton addAction:[UIAction actionWithHandler:^(UIAction *action) {
        [self dismissAnnualUpsellThen:^{
            [self.spinner startAnimating];
            self.tableView.userInteractionEnabled = NO;
            [self startSubscriptionForTier:monthlyTier token:token];
        }];
    }] forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:monthlyButton];

    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelButton.frame       = CGRectMake(30, 316, 240, 40);
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:14];
    [cancelButton setTitle:NSLocalizedString(@"EZCoinStore.Cancel", @"Cancel button") forState:UIControlStateNormal];
    [cancelButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [cancelButton addAction:[UIAction actionWithHandler:^(UIAction *action) {
        [self dismissAnnualUpsellThen:nil];
    }] forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancelButton];

    [UIView animateWithDuration:0.4
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:0
                     animations:^{
        overlay.alpha    = 1;
        card.transform    = CGAffineTransformIdentity;
    } completion:nil];

}

// Fades and removes the annual-upsell overlay, then runs completion (if
// given) once it's fully gone -- so checkout doesn't visually start on top
// of the closing animation.
- (void)dismissAnnualUpsellThen:(void (^ _Nullable)(void))completion {

    UIView *overlay = [self.view viewWithTag:9911];
    [UIView animateWithDuration:0.25 animations:^{
        overlay.alpha = 0;
    } completion:^(BOOL done) {
        [overlay removeFromSuperview];
        if (completion) completion();
    }];

}

// ── Subscription checkout ─────────────────────────────────────────────────────

- (void)startSubscriptionForTier:(NSString *)tierName token:(NSString *)token {

    NSString *currentTier   = [EZEntitlementManager shared].currentTier;

    NSString *currentStatus = [EZEntitlementManager shared].currentStatus;

    // Only cancel an existing subscription if it's genuinely active.

    // Cancelled/suspended/expired accounts go straight to checkout.

    BOOL hasActiveSub = currentTier.length > 0 && [currentStatus isEqualToString:@"active"];

    if (hasActiveSub) {

        [self cancelCurrentSubscriptionWithToken:token completion:^(BOOL success) {

            // Proceed to new plan regardless — PayPal handles the new charge

            [self createPayPalSubscriptionForTier:tierName token:token];

        }];

    } else {

        [self createPayPalSubscriptionForTier:tierName token:token];

    }

}

- (void)cancelCurrentSubscriptionWithToken:(NSString *)token

                                completion:(void(^)(BOOL success))completion {

    NSURL *cancelURL = [NSURL URLWithString:[kStoreSupabaseURL

        stringByAppendingString:@"/functions/v1/cancel-paypal-subscription"]];

    NSMutableURLRequest *cancelRequest = [NSMutableURLRequest requestWithURL:cancelURL];

    cancelRequest.HTTPMethod      = @"POST";

    cancelRequest.timeoutInterval = 15;

    [cancelRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [cancelRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]

         forHTTPHeaderField:@"Authorization"];

    cancelRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{} options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:cancelRequest

        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        dispatch_async(dispatch_get_main_queue(), ^{

            completion(!error);

        });

    }] resume];

}

- (void)createPayPalSubscriptionForTier:(NSString *)tierName token:(NSString *)token {

    // Sends the tier name, not a plan ID. The edge function resolves the real

    // PayPal plan_id from server-side env vars so it never lives in the binary.

    NSURL *createSubURL = [NSURL URLWithString:[kStoreSupabaseURL

        stringByAppendingString:@"/functions/v1/create-paypal-subscription"]];

    NSMutableURLRequest *createSubRequest = [NSMutableURLRequest requestWithURL:createSubURL];

    createSubRequest.HTTPMethod      = @"POST";

    createSubRequest.timeoutInterval = 15;

    [createSubRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [createSubRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]

            forHTTPHeaderField:@"Authorization"];

    createSubRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{

        @"tier":    tierName,

        @"user_id": [EZAuthManager shared].userId ?: @""

    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:createSubRequest

        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        dispatch_async(dispatch_get_main_queue(), ^{

            [self.spinner stopAnimating];

            self.tableView.userInteractionEnabled = YES;

            if (error) { [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.Error", @"Generic error alert title") message:error.localizedDescription]; return; }

            NSDictionary *json       = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

            NSString     *approveURL = json[@"approve_url"];

            if (!approveURL) {

                [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.Error", @"Generic error alert title") message:NSLocalizedString(@"EZCoinStore.Alert.CheckoutStartFailed", @"Checkout start failure message")];

                return;

            }

            self.pendingPurchaseType = @"subscription";

            SFSafariViewController *safari = [[SFSafariViewController alloc]

                initWithURL:[NSURL URLWithString:approveURL]];

            safari.delegate                = self;

            safari.preferredBarTintColor     = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1.0];

            safari.preferredControlTintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

            [self presentViewController:safari animated:YES completion:nil];

        });

    }] resume];

}

// ── One-time top-up checkout ──────────────────────────────────────────────────

- (void)startTopUpForPackageID:(NSString *)packageID coins:(NSInteger)coins token:(NSString *)token {

    // amount and coins are no longer sent -- create-paypal-order resolves
    // both server-side from package_id alone now, so a jailbroken client
    // can't submit a mismatched amount/coins pair for a real package_id.
    NSURL *orderURL = [NSURL URLWithString:[kStoreSupabaseURL
        stringByAppendingString:@"/functions/v1/create-paypal-order"]];

    NSMutableURLRequest *orderRequest = [NSMutableURLRequest requestWithURL:orderURL];
    orderRequest.HTTPMethod      = @"POST";
    orderRequest.timeoutInterval = 15;
    [orderRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [orderRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]
        forHTTPHeaderField:@"Authorization"];

    orderRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"user_id":    [EZAuthManager shared].userId ?: @"",
        @"package_id": packageID,
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:orderRequest

        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        dispatch_async(dispatch_get_main_queue(), ^{

            [self.spinner stopAnimating];

            self.tableView.userInteractionEnabled = YES;

            if (error) { [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.Error", @"Generic error alert title") message:error.localizedDescription]; return; }

            NSDictionary *json       = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

            NSString     *approveURL = json[@"approve_url"];

            if (!approveURL) {

                [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.Error", @"Generic error alert title") message:NSLocalizedString(@"EZCoinStore.Alert.CheckoutStartFailed", @"Checkout start failure message")];

                return;

            }

            self.pendingPurchaseType = @"topup";

            self.pendingOrderID      = json[@"order_id"];

            SFSafariViewController *safari = [[SFSafariViewController alloc]

                initWithURL:[NSURL URLWithString:approveURL]];

            safari.delegate                = self;

            safari.preferredBarTintColor     = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1.0];

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

    NSURL *captureURL = [NSURL URLWithString:[kStoreSupabaseURL

        stringByAppendingString:@"/functions/v1/capture-paypal-order"]];

    NSMutableURLRequest *captureRequest = [NSMutableURLRequest requestWithURL:captureURL];

    captureRequest.HTTPMethod      = @"POST";

    captureRequest.timeoutInterval = 20;

    [captureRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [captureRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]

          forHTTPHeaderField:@"Authorization"];

    captureRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{

        @"order_id": orderID

    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:captureRequest

        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        dispatch_async(dispatch_get_main_queue(), ^{

            [self.spinner stopAnimating];

            self.tableView.userInteractionEnabled = YES;

            if (error) {

                [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.Error", @"Generic error alert title")

                        message:NSLocalizedString(@"EZCoinStore.Alert.PurchaseConfirmFailed", @"Purchase confirmation failure message")];

                [self refreshBalance];

                return;

            }

            NSDictionary      *json         = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

            if (httpResponse.statusCode == 200 && jsonBool(json, @"success")) {

                NSInteger coinsAdded = jsonInteger(json, @"coins_added");

                NSInteger newBalance = jsonInteger(json, @"balance");

                // Trust the capture response — apply balance directly so

                // a racing refreshBalance can't overwrite it with a stale value.

                [[EZEntitlementManager shared] applyKnownBalance:newBalance];

                [self showCoinCelebration:coinsAdded newBalance:newBalance];

                [[NSNotificationCenter defaultCenter]

                    postNotificationName:@"EZSubscriptionUpdated" object:nil];

                // Delayed refresh to sync any server-side changes after upsert settles

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),

                               dispatch_get_main_queue(), ^{

                    [self refreshBalance];

                });

            } else {

                NSString *errorMessage = jsonString(json, @"error") ?: NSLocalizedString(@"EZCoinStore.Alert.PurchaseNotConfirmed", @"Purchase not confirmed fallback message");

                [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.PurchaseIssue", @"Purchase issue alert title") message:errorMessage];

                [self refreshBalance];

            }

        });

    }] resume];

}

// ── Coin celebration overlay ──────────────────────────────────────────────────

// Shown after any successful coin credit: purchases, top-ups, and daily rewards.

- (void)showCoinCelebration:(NSInteger)coinsAdded newBalance:(NSInteger)newBalance {

    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];

    overlay.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.75];

    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    overlay.alpha            = 0;

    overlay.tag              = 9901;

    [self.view addSubview:overlay];

    UIView *celebrationCard = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 320)];

    celebrationCard.center             = CGPointMake(self.view.bounds.size.width / 2,

                                                     self.view.bounds.size.height / 2);

    celebrationCard.backgroundColor    = [UIColor colorWithRed:0.08 green:0.08 blue:0.14 alpha:1.0];

    celebrationCard.layer.cornerRadius = 24;

    celebrationCard.layer.borderWidth  = 1.5;

    celebrationCard.layer.borderColor  = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.6].CGColor;

    celebrationCard.transform          = CGAffineTransformMakeScale(0.7, 0.7);

    [overlay addSubview:celebrationCard];

    EZCoinPotView *coinPot = [[EZCoinPotView alloc] initWithFrame:CGRectMake(90, 20, 100, 110)];

    coinPot.coinImage = self.coinImage;

    [celebrationCard addSubview:coinPot];

    self.storePotView = coinPot;

    UILabel *headlineLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 138, 240, 30)];

    headlineLabel.text          = NSLocalizedString(@"EZCoinStore.Celebration.CoinsAdded", @"Coin celebration headline");

    headlineLabel.font          = [UIFont boldSystemFontOfSize:20];

    headlineLabel.textColor     = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

    headlineLabel.textAlignment = NSTextAlignmentCenter;

    [celebrationCard addSubview:headlineLabel];

    UILabel *amountLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 172, 240, 28)];

    amountLabel.text          = [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.Celebration.AmountFormat", @"Coin celebration amount"), (long)coinsAdded];

    amountLabel.font          = [UIFont boldSystemFontOfSize:26];

    amountLabel.textColor     = [UIColor whiteColor];

    amountLabel.textAlignment = NSTextAlignmentCenter;

    [celebrationCard addSubview:amountLabel];

    UILabel *newBalanceLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 204, 240, 22)];

    newBalanceLabel.text          = [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.Celebration.NewBalanceFormat", @"Coin celebration new balance"), (long)newBalance];

    newBalanceLabel.font          = [UIFont systemFontOfSize:14];

    newBalanceLabel.textColor     = [UIColor secondaryLabelColor];

    newBalanceLabel.textAlignment = NSTextAlignmentCenter;

    [celebrationCard addSubview:newBalanceLabel];

    UIButton *dismissButton = [UIButton buttonWithType:UIButtonTypeSystem];

    dismissButton.frame                  = CGRectMake(40, 248, 200, 44);

    dismissButton.backgroundColor        = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

    dismissButton.layer.cornerRadius     = 12;

    dismissButton.titleLabel.font        = [UIFont boldSystemFontOfSize:16];

    dismissButton.tag                    = 9900;

    [dismissButton setTitle:NSLocalizedString(@"EZCoinStore.Celebration.Sweet", @"Coin celebration dismiss button") forState:UIControlStateNormal];

    [dismissButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];

    [dismissButton addTarget:self

                      action:@selector(dismissCelebration:)

            forControlEvents:UIControlEventTouchUpInside];

    [celebrationCard addSubview:dismissButton];

    [UIView animateWithDuration:0.4

                          delay:0

         usingSpringWithDamping:0.7

          initialSpringVelocity:0.5

                        options:0

                     animations:^{

        overlay.alpha             = 1;

        celebrationCard.transform = CGAffineTransformIdentity;

    } completion:^(BOOL done) {

        // Set pot to the pre-credit fill level, then animate coins flying in

        NSString     *tier        = [EZEntitlementManager shared].currentTier ?: @"basic";

        NSDictionary *tierCoinMap = @{
            @"basic":             @400,
            @"basic_weekly":      @400,
            @"standard":          @900,
            @"standard_annual":   @10800,
            @"pro":               @1600,
            @"pro_annual":        @19200,
            @"ultra":             @2500,
            @"ultra_annual":      @30000,
            @"power":             @6250,
            @"power_annual":      @75000,
            @"enterprise":        @12500,
            @"enterprise_annual": @150000,
        };

        NSInteger includedCoins = [tierCoinMap[tier.lowercaseString] integerValue] ?: 400;

        [coinPot updateBalance:newBalance - coinsAdded includedCoins:includedCoins animated:NO];

        [coinPot animateCoinToss:coinsAdded completion:^{

            [coinPot updateBalance:newBalance includedCoins:includedCoins animated:YES];

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

        [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZCoinStore.OK", @"Alert confirmation button")

                                                  style:UIAlertActionStyleDefault

                                                handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];

    });

}

@end
