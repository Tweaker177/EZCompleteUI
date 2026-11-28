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

// Seasonal themes + sale polish (2026-11-25):
//   - New EZCoinStoreSeason: a Thanksgiving theme (Nov 1 through Thanksgiving day) and a winter
//     holiday theme (Black Friday through Jan 6), picked by date in America/New_York so the
//     switch lands at midnight Eastern, the same moment the Black Friday store_sales row begins.
//     Cosmetic only; coins are still granted entirely server-side. Each theme restyles the
//     header, banner, card accents and section headers and adds falling leaves / snow
//     (skipped when Reduce Motion is on). Debug override: set the NSUserDefaults string
//     EZCoinStoreSeasonOverride to "thanksgiving", "winter" or "none".
//   - Web store button is now the hero of the store: taller, pulsing, and it advertises the
//     live sale multiplier. The last server-provided web_store_url is cached so the button
//     shows instantly (TestFlight builds buy through it); only https URLs are opened.
//   - Card badges and footnotes now actually render (the cell hid the badge label and never
//     showed it). Top-ups show the sale amount; subscriptions show their regular recurring
//     amount beside the multiplier and a first-period-only note.
//   - Sale banner shows a live "Ends in" countdown; when the sale or season rolls over while
//     the store is open the store rebuilds itself once.
//   - Fixed: the web button no longer clears the table footer (it wiped the sale fine print),
//     and a rebuild no longer leaves the header without the web button.
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

#import "EZSupabaseConfig.h"

#import "EZAuthManager.h"

#import "EZEntitlementManager.h"

#import "EZCoinPotView.h"

#import "EZTheme.h"

#import "helpers.h"

#import "EZCoinLedgerViewController.h"



#import "EZCoinUsageViewController.h"

#if APPSTORE
#import "EZStoreKitManager.h"
#endif

#import "BRSlotMachineViewController.h"

#import "BRPennySlotViewController.h"
#import "BRPlunderBayViewController.h"
#import "BRPhoenixPavilionSlotViewController.h"

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

// Headline + sub-line + a live "Ends in" countdown row.
static CGFloat const kPromoBannerHeight = 132.0;

// Height of the hero web store button, and the vertical space it takes at
// the top of the header while it is showing: 12 above + button + 12 below.
static CGFloat const kWebStoreButtonHeight = 76.0;
static CGFloat const kWebStoreSlotHeight = 100.0;

// NSUserDefaults keys. The season override is a debug aid (cosmetic only);
// the web store URL cache lets the hero button appear before the daily-coins
// status request has answered.
static NSString *const kSeasonOverrideDefaultsKey   = @"EZCoinStoreSeasonOverride";
static NSString *const kWebStoreURLCacheDefaultsKey = @"EZCoinStoreWebStoreURLCache";

// Now 0 — the Daily Coins button moved into the nav bar, so nothing floats

// over the header content anymore and the banner can sit flush at the top.

static CGFloat const kPromoBannerTopPadding = 0.0;

// ── Seasonal themes ───────────────────────────────────────────────────────────
// Purely cosmetic. A season restyles the header, sale banner, card accents and
// section headers and adds falling leaves or snow. Which season is showing is
// decided by the date in America/New_York so it flips at midnight Eastern —
// the same instant the Black Friday store_sales row begins (05:00 UTC). What
// the store pays out is never decided here; see the sale comments in the VC.

typedef NS_ENUM(NSUInteger, EZCoinStoreSeasonKind) {
    EZCoinStoreSeasonKindNone,
    EZCoinStoreSeasonKindThanksgiving,
    EZCoinStoreSeasonKindWinterHoliday,
};

static UIColor *EZSeasonColor(CGFloat red, CGFloat green, CGFloat blue) {
    return [UIColor colorWithRed:red green:green blue:blue alpha:1.0];
}

@interface EZCoinStoreSeason : NSObject

@property (nonatomic, readonly) EZCoinStoreSeasonKind kind;
@property (nonatomic, readonly, copy,   nullable) NSString *storeTitle;          // nav bar title; nil keeps the stock title
@property (nonatomic, readonly, copy,   nullable) NSString *greeting;             // header greeting, e.g. "Happy Thanksgiving!"
@property (nonatomic, readonly, copy,   nullable) NSArray<UIColor *> *bannerColors;
@property (nonatomic, readonly, strong, nullable) UIColor *saleAccentColor;       // card accent for sale items
@property (nonatomic, readonly, strong, nullable) UIColor *sectionHeaderColor;
@property (nonatomic, readonly, strong, nullable) UIColor *headerColor;
@property (nonatomic, readonly, strong, nullable) UIColor *backgroundTintColor;
@property (nonatomic, readonly, copy,   nullable) NSArray<UIColor *> *tierAccentColors; // cycled over non-sale cards

+ (EZCoinStoreSeasonKind)kindForDate:(NSDate *)date;
+ (EZCoinStoreSeasonKind)currentKind;
+ (instancetype)seasonForKind:(EZCoinStoreSeasonKind)kind;

/// Falling leaves or snow, spanning `width` and emitting from just above the top
/// edge. Returns nil for the no-season look.
- (nullable CAEmitterLayer *)newEmitterLayerForWidth:(CGFloat)width;

/// Standing winter figures for the store header, drawn in code like the
/// particle artwork. Full colour; not tinted by an emitter cell.
+ (UIImage *)snowmanImage;
+ (UIImage *)evergreenImage;

@end

@implementation EZCoinStoreSeason

- (instancetype)initWithKind:(EZCoinStoreSeasonKind)kind {
    self = [super init];
    if (!self) return nil;
    _kind = kind;
    if (kind == EZCoinStoreSeasonKindThanksgiving) {
        _storeTitle = NSLocalizedStringWithDefaultValue(@"EZCoinStore.Title.Thanksgiving", nil, NSBundle.mainBundle, @"🍂 EZ Coin Store 🦃", @"Coin store title during the Thanksgiving theme");
        _greeting   = NSLocalizedStringWithDefaultValue(@"EZCoinStore.Greeting.Thanksgiving", nil, NSBundle.mainBundle, @"🦃 Happy Thanksgiving!", @"Header greeting during the Thanksgiving theme");
        _bannerColors = @[EZSeasonColor(0.58, 0.10, 0.12), EZSeasonColor(0.93, 0.46, 0.08)]; // cranberry → pumpkin
        _saleAccentColor    = EZSeasonColor(0.95, 0.30, 0.10);
        _sectionHeaderColor = EZSeasonColor(1.00, 0.72, 0.28);
        _headerColor        = EZSeasonColor(0.20, 0.12, 0.10);
        _backgroundTintColor = EZSeasonColor(0.90, 0.42, 0.06);
        _tierAccentColors = @[
            EZSeasonColor(0.92, 0.45, 0.10), // pumpkin
            EZSeasonColor(0.95, 0.70, 0.15), // harvest gold
            EZSeasonColor(0.76, 0.16, 0.26), // cranberry
            EZSeasonColor(0.45, 0.58, 0.22), // sage
            EZSeasonColor(0.68, 0.42, 0.26), // copper
        ];
    } else if (kind == EZCoinStoreSeasonKindWinterHoliday) {
        _storeTitle = NSLocalizedStringWithDefaultValue(@"EZCoinStore.Title.Winter", nil, NSBundle.mainBundle, @"❄️ EZ Coin Store 🎄", @"Coin store title during the winter holiday theme");
        _greeting   = NSLocalizedStringWithDefaultValue(@"EZCoinStore.Greeting.Winter", nil, NSBundle.mainBundle, @"🎄 Happy Holidays!", @"Header greeting during the winter holiday theme");
        _bannerColors = @[EZSeasonColor(0.78, 0.09, 0.17), EZSeasonColor(0.04, 0.40, 0.26)]; // holiday red → pine
        _saleAccentColor    = EZSeasonColor(0.90, 0.10, 0.25);
        _sectionHeaderColor = EZSeasonColor(0.70, 0.88, 1.00);
        _headerColor        = EZSeasonColor(0.07, 0.14, 0.26);
        _backgroundTintColor = EZSeasonColor(0.25, 0.60, 0.98);
        _tierAccentColors = @[
            EZSeasonColor(0.35, 0.70, 0.96), // ice
            EZSeasonColor(0.12, 0.62, 0.38), // pine
            EZSeasonColor(0.86, 0.16, 0.22), // candy red
            EZSeasonColor(0.74, 0.80, 0.90), // silver
            EZSeasonColor(1.00, 0.80, 0.20), // gold
        ];
    }
    return self;
}

+ (instancetype)seasonForKind:(EZCoinStoreSeasonKind)kind {
    return [[EZCoinStoreSeason alloc] initWithKind:kind];
}

// All date math is done in Eastern time so the switch is the same moment for
// every user, whatever their device time zone.
+ (NSCalendar *)easternCalendar {
    static NSCalendar *calendar = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        calendar.timeZone = [NSTimeZone timeZoneWithName:@"America/New_York"] ?: [NSTimeZone localTimeZone];
    });
    return calendar;
}

// Thanksgiving is the fourth Thursday of November.
+ (NSInteger)thanksgivingDayOfMonthForYear:(NSInteger)year {
    NSCalendar *calendar = [self easternCalendar];
    NSDateComponents *components = [[NSDateComponents alloc] init];
    components.year = year;
    components.month = 11;
    components.weekday = 5;        // Thursday
    components.weekdayOrdinal = 4; // fourth one
    components.hour = 12;
    NSDate *thanksgiving = [calendar dateFromComponents:components];
    return thanksgiving ? [calendar component:NSCalendarUnitDay fromDate:thanksgiving] : 26;
}

+ (EZCoinStoreSeasonKind)kindForDate:(NSDate *)date {
    NSCalendar *calendar = [self easternCalendar];
    NSDateComponents *today = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:date];
    // Early January still belongs to the season that began at Black Friday.
    if (today.month == 1 && today.day <= 6) return EZCoinStoreSeasonKindWinterHoliday;
    if (today.month == 12) return EZCoinStoreSeasonKindWinterHoliday;
    if (today.month == 11) {
        // Through Thanksgiving day itself; the next midnight (Black Friday) flips to winter.
        return today.day <= [self thanksgivingDayOfMonthForYear:today.year] ? EZCoinStoreSeasonKindThanksgiving : EZCoinStoreSeasonKindWinterHoliday;
    }
    return EZCoinStoreSeasonKindNone;
}

+ (EZCoinStoreSeasonKind)currentKind {
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:kSeasonOverrideDefaultsKey];
    if ([override isEqualToString:@"thanksgiving"]) return EZCoinStoreSeasonKindThanksgiving;
    if ([override isEqualToString:@"winter"])       return EZCoinStoreSeasonKindWinterHoliday;
    if ([override isEqualToString:@"none"])         return EZCoinStoreSeasonKindNone;
    return [self kindForDate:[NSDate date]];
}

// ── Particle artwork (drawn once, in code — no image assets) ──────────────────

+ (UIImage *)leafImage {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(40, 40)];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            UIBezierPath *leaf = [UIBezierPath bezierPath];
            [leaf moveToPoint:CGPointMake(20, 2)];
            [leaf addCurveToPoint:CGPointMake(20, 38) controlPoint1:CGPointMake(41, 12) controlPoint2:CGPointMake(38, 30)];
            [leaf addCurveToPoint:CGPointMake(20, 2)  controlPoint1:CGPointMake(2, 30)  controlPoint2:CGPointMake(-1, 12)];
            [leaf closePath];
            [[UIColor whiteColor] setFill];
            [leaf fill];
            // A darker center vein; it multiplies with the cell color, so it reads as a vein.
            UIBezierPath *vein = [UIBezierPath bezierPath];
            [vein moveToPoint:CGPointMake(20, 6)];
            [vein addLineToPoint:CGPointMake(20, 39)];
            vein.lineWidth = 1.5;
            [[UIColor colorWithWhite:0.55 alpha:1.0] setStroke];
            [vein stroke];
        }];
    });
    return image;
}

+ (UIImage *)snowflakeImage {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(36, 36)];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGContextRef cg = context.CGContext;
            CGContextSetStrokeColorWithColor(cg, [UIColor whiteColor].CGColor);
            CGContextSetLineWidth(cg, 2.2);
            CGContextSetLineCap(cg, kCGLineCapRound);
            for (NSInteger arm = 0; arm < 3; arm++) {
                CGFloat angle = (CGFloat)arm * M_PI / 3.0;
                CGContextMoveToPoint(cg, 18 - cos(angle) * 15, 18 - sin(angle) * 15);
                CGContextAddLineToPoint(cg, 18 + cos(angle) * 15, 18 + sin(angle) * 15);
            }
            CGContextStrokePath(cg);
        }];
    });
    return image;
}

+ (UIImage *)snowDotImage {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(16, 16)];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[UIColor whiteColor] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(2, 2, 12, 12)] fill];
        }];
    });
    return image;
}

+ (UIImage *)snowmanImage {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(96, 128)];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            UIColor *snowFill = [UIColor colorWithRed:0.97 green:0.99 blue:1.0 alpha:1.0];
            UIColor *snowEdge = [UIColor colorWithRed:0.72 green:0.82 blue:0.92 alpha:1.0];
            UIColor *coal = [UIColor colorWithRed:0.10 green:0.10 blue:0.14 alpha:1.0];
            // Stick arms first, so the body balls overlap their roots.
            UIBezierPath *arms = [UIBezierPath bezierPath];
            [arms moveToPoint:CGPointMake(27, 56)];
            [arms addLineToPoint:CGPointMake(7, 42)];
            [arms moveToPoint:CGPointMake(69, 56)];
            [arms addLineToPoint:CGPointMake(89, 40)];
            [arms moveToPoint:CGPointMake(7, 42)];
            [arms addLineToPoint:CGPointMake(3, 34)];
            [arms moveToPoint:CGPointMake(89, 40)];
            [arms addLineToPoint:CGPointMake(93, 32)];
            arms.lineWidth = 3.0;
            arms.lineCapStyle = kCGLineCapRound;
            [[UIColor colorWithRed:0.45 green:0.30 blue:0.16 alpha:1.0] setStroke];
            [arms stroke];
            // Three stacked balls.
            for (NSValue *rectValue in @[ [NSValue valueWithCGRect:CGRectMake(16, 74, 64, 52)],
                                          [NSValue valueWithCGRect:CGRectMake(25, 42, 46, 40)],
                                          [NSValue valueWithCGRect:CGRectMake(31, 10, 34, 32)] ]) {
                UIBezierPath *ball = [UIBezierPath bezierPathWithOvalInRect:rectValue.CGRectValue];
                [snowFill setFill];
                [ball fill];
                [snowEdge setStroke];
                ball.lineWidth = 2.0;
                [ball stroke];
            }
            // Scarf: a band across the neck and a tail down the right side.
            UIBezierPath *scarf = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(28, 38, 40, 9) cornerRadius:4];
            UIBezierPath *tail = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(58, 44, 10, 24) cornerRadius:4];
            [[UIColor colorWithRed:0.85 green:0.20 blue:0.22 alpha:1.0] setFill];
            [scarf fill];
            [tail fill];
            // Face: coal eyes, a carrot nose, and a dotted smile.
            [coal setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(40, 20, 5, 5)] fill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(51, 20, 5, 5)] fill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(42, 31, 3, 3)] fill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(47, 33, 3, 3)] fill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(52, 31, 3, 3)] fill];
            UIBezierPath *carrot = [UIBezierPath bezierPath];
            [carrot moveToPoint:CGPointMake(47, 25)];
            [carrot addLineToPoint:CGPointMake(63, 28)];
            [carrot addLineToPoint:CGPointMake(47, 30)];
            [carrot closePath];
            [[UIColor colorWithRed:0.96 green:0.55 blue:0.12 alpha:1.0] setFill];
            [carrot fill];
            // Coal buttons down the middle and bottom balls.
            [coal setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(46, 56, 5, 5)] fill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(46, 68, 5, 5)] fill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(46, 90, 5, 5)] fill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(46, 104, 5, 5)] fill];
        }];
    });
    return image;
}

+ (UIImage *)evergreenImage {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(80, 112)];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            // Trunk.
            [[UIColor colorWithRed:0.45 green:0.30 blue:0.16 alpha:1.0] setFill];
            [[UIBezierPath bezierPathWithRect:CGRectMake(35, 96, 10, 12)] fill];
            // Three tiers, widest first so the upper ones overlap cleanly.
            NSArray<NSValue *> *tiers = @[ [NSValue valueWithCGRect:CGRectMake(6, 40, 68, 62)],
                                           [NSValue valueWithCGRect:CGRectMake(14, 22, 52, 48)],
                                           [NSValue valueWithCGRect:CGRectMake(22, 6, 36, 38)] ];
            [[UIColor colorWithRed:0.13 green:0.45 blue:0.25 alpha:1.0] setFill];
            for (NSValue *rectValue in tiers) {
                CGRect r = rectValue.CGRectValue;
                UIBezierPath *tier = [UIBezierPath bezierPath];
                [tier moveToPoint:CGPointMake(CGRectGetMidX(r), CGRectGetMinY(r))];
                [tier addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r))];
                [tier addLineToPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r))];
                [tier closePath];
                [tier fill];
            }
            // Snow resting on each tier's shoulders.
            UIBezierPath *snow = [UIBezierPath bezierPath];
            for (NSValue *rectValue in tiers) {
                CGRect r = rectValue.CGRectValue;
                CGFloat apexX = CGRectGetMidX(r), apexY = CGRectGetMinY(r);
                [snow moveToPoint:CGPointMake(apexX - CGRectGetWidth(r) * 0.20, apexY + CGRectGetHeight(r) * 0.38)];
                [snow addLineToPoint:CGPointMake(apexX, apexY + 2)];
                [snow addLineToPoint:CGPointMake(apexX + CGRectGetWidth(r) * 0.20, apexY + CGRectGetHeight(r) * 0.38)];
            }
            snow.lineWidth = 4.0;
            snow.lineCapStyle = kCGLineCapRound;
            snow.lineJoinStyle = kCGLineJoinRound;
            [[UIColor colorWithRed:0.97 green:0.99 blue:1.0 alpha:1.0] setStroke];
            [snow stroke];
            // A gold bauble at the very top.
            [[UIColor colorWithRed:1.0 green:0.78 blue:0.1 alpha:1.0] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(36, 0, 8, 8)] fill];
        }];
    });
    return image;
}

+ (CAEmitterCell *)cellWithImage:(UIImage *)image color:(UIColor *)color birthRate:(float)birthRate scale:(CGFloat)scale spin:(CGFloat)spin velocity:(CGFloat)velocity {
    CAEmitterCell *cell = [CAEmitterCell emitterCell];
    cell.contents = (id)image.CGImage;
    cell.color = color.CGColor;
    cell.birthRate = birthRate;
    cell.lifetime = 18.0;
    cell.velocity = velocity;
    cell.velocityRange = velocity * 0.5;
    cell.emissionLongitude = M_PI_2; // straight down
    cell.emissionRange = M_PI / 7.0;
    cell.xAcceleration = 3.0;        // a slight drift
    cell.spin = 0;
    cell.spinRange = spin;
    cell.scale = scale;
    cell.scaleRange = scale * 0.5;
    cell.alphaRange = 0.25;
    return cell;
}

- (CAEmitterLayer *)newEmitterLayerForWidth:(CGFloat)width {
    if (self.kind == EZCoinStoreSeasonKindNone) return nil;
    CAEmitterLayer *emitter = [CAEmitterLayer layer];
    emitter.emitterShape = kCAEmitterLayerLine;
    emitter.emitterPosition = CGPointMake(width / 2.0, -14.0);
    emitter.emitterSize = CGSizeMake(MAX(width, 1.0), 1.0);
    // Start the clock a full cell lifetime in the past so the first frame
    // already has flakes at every height, not just near the top.
    emitter.beginTime = CACurrentMediaTime() - 18.0;
    if (self.kind == EZCoinStoreSeasonKindThanksgiving) {
        emitter.emitterCells = @[
            [EZCoinStoreSeason cellWithImage:[EZCoinStoreSeason leafImage] color:EZSeasonColor(0.95, 0.50, 0.10) birthRate:0.7 scale:0.55 spin:2.6 velocity:42],
            [EZCoinStoreSeason cellWithImage:[EZCoinStoreSeason leafImage] color:EZSeasonColor(0.98, 0.76, 0.20) birthRate:0.6 scale:0.48 spin:2.2 velocity:38],
            [EZCoinStoreSeason cellWithImage:[EZCoinStoreSeason leafImage] color:EZSeasonColor(0.74, 0.20, 0.14) birthRate:0.5 scale:0.52 spin:3.0 velocity:46],
        ];
    } else {
        emitter.emitterCells = @[
            [EZCoinStoreSeason cellWithImage:[EZCoinStoreSeason snowflakeImage] color:EZSeasonColor(0.92, 0.97, 1.0) birthRate:3.2 scale:0.42 spin:1.2 velocity:44],
            [EZCoinStoreSeason cellWithImage:[EZCoinStoreSeason snowDotImage]   color:[UIColor whiteColor]             birthRate:6.4 scale:0.40 spin:0.0 velocity:36],
        ];
    }
    return emitter;
}

@end

// A plain view whose layer is a gradient, used for the seasonal tint behind the
// table (backgroundView) so it follows bounds changes without manual layout.
@interface EZCoinStoreTintView : UIView
@end

@implementation EZCoinStoreTintView
+ (Class)layerClass {
    return [CAGradientLayer class];
}
@end

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

@property (nonatomic, copy)   NSString        *annualPlanOrPackageID; // nil when the tier has no annual option

@property (nonatomic, copy)   NSString        *monthlyPriceString;    // e.g. "$10.00", for the monthly button on the card

@property (nonatomic, copy)   NSString        *annualPriceString;     // e.g. "$89.99", for the yearly button on the card
@property (nonatomic, copy)   NSString        *annualSavingsString;   // e.g. "$60", saved per year vs paying monthly

@property (nonatomic, assign) EZStoreItemType  type;

@property (nonatomic, assign) NSInteger        coins;

@property (nonatomic, assign) BOOL             isCurrentPlan;

@property (nonatomic, strong) UIColor         *accentColor;

@property (nonatomic, copy)   NSString        *badgeText;      // e.g. "BEST VALUE" — nil for none

@property (nonatomic, copy)   NSString        *badgeFootnoteText; // small disclaimer under badgeText — nil for none

@property (nonatomic, assign) BOOL             isSaleItem;     // YES while a sale/promo restyles this card; seasonal accents leave it alone

@property (nonatomic, assign) NSInteger        saleMultiplier; // server sale multiplier shown on this card (0 when none)

@property (nonatomic, assign) NSInteger        saleBaseCoins;  // coins before the multiplier, for the "Normally N coins" line

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

@property (nonatomic, strong) UIButton    *annualButton;

@property (nonatomic, copy)   void (^onAction)(void);

@property (nonatomic, copy)   void (^onAnnualAction)(void);

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
        
        self.subtitleLabel.adjustsFontSizeToFitWidth = YES;
        
        self.subtitleLabel.minimumScaleFactor = 0.5;

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
        
        self.footnoteLabel.adjustsFontSizeToFitWidth = YES;
        
        self.footnoteLabel.minimumScaleFactor = 0.5;

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

        self.annualButton = [UIButton buttonWithType:UIButtonTypeSystem];

        self.annualButton.layer.cornerRadius  = 10;

        self.annualButton.titleLabel.font            = [UIFont boldSystemFontOfSize:14];

        self.annualButton.titleLabel.numberOfLines   = 2;

        self.annualButton.titleLabel.textAlignment   = NSTextAlignmentCenter;

        self.annualButton.titleLabel.lineBreakMode   = NSLineBreakByWordWrapping;

        [self.annualButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

        [self.annualButton addTarget:self

                              action:@selector(annualTapped)

                    forControlEvents:UIControlEventTouchUpInside];

        self.annualButton.hidden = YES;

        [self.cardView addSubview:self.annualButton];

    }

    return self;

}

- (void)configureWithItem:(EZStoreItem *)item coinImage:(UIImage *)coinImage {

    UIColor *accentColor = item.accentColor ?: [UIColor systemBlueColor];

    self.cardView.backgroundColor   = [accentColor colorWithAlphaComponent:0.12];

    self.cardView.layer.borderColor = [accentColor colorWithAlphaComponent:0.3].CGColor;

    self.coinImageView.image  = coinImage;

    self.titleLabel.text      = item.title;

    self.subtitleLabel.text   = [item.subtitle componentsSeparatedByString:@"\n"].firstObject;

    self.priceLabel.text      = item.priceString;

    self.priceLabel.textColor = accentColor;

    // Light accents (silver, gold, harvest yellow) need dark text on the badge
    // and the buy button; saturated ones keep white.
    CGFloat accentRed = 0, accentGreen = 0, accentBlue = 0, accentAlpha = 0;

    [accentColor getRed:&accentRed green:&accentGreen blue:&accentBlue alpha:&accentAlpha];

    CGFloat accentLuminance = 0.299 * accentRed + 0.587 * accentGreen + 0.114 * accentBlue;

    UIColor *onAccentColor = accentLuminance > 0.62 ? [EZTheme backgroundColor] : [UIColor whiteColor];

    self.badgeLabel.textColor = onAccentColor;

    [self.actionButton setTitleColor:onAccentColor forState:UIControlStateNormal];

    // Badge ("5X COINS", "POPULAR", a plan status…) and its fine print. Both
    // were previously hidden unconditionally, which made every sale and tier
    // badge invisible; they now show whenever the item carries text.
    if (item.badgeText.length > 0) {

        self.badgeLabel.text            = item.badgeText;
        self.badgeLabel.backgroundColor = accentColor;
        self.badgeLabel.hidden          = NO;

    } else {

        self.badgeLabel.text   = nil;
        self.badgeLabel.hidden = YES;

    }

    if (item.badgeText.length > 0 && item.badgeFootnoteText.length > 0) {

        self.footnoteLabel.text   = item.badgeFootnoteText;
        self.footnoteLabel.hidden = NO;

    } else {

        self.footnoteLabel.text   = nil;
        self.footnoteLabel.hidden = YES;

    }

    [self setNeedsLayout];

    BOOL twoButtons = !item.isCurrentPlan && item.type == EZStoreItemTypeSubscription && item.annualPlanOrPackageID.length > 0;

    self.annualButton.hidden = !twoButtons;

    self.priceLabel.hidden   = twoButtons;

    if (twoButtons) {

        [self.actionButton setTitle:[NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"EZCoinStore.Card.MonthlyButtonFormat", nil, [NSBundle mainBundle], @"Monthly %@", @"Monthly option button on a store card"), item.monthlyPriceString] forState:UIControlStateNormal];

        self.actionButton.backgroundColor = accentColor;

        [self.actionButton setTitleColor:onAccentColor forState:UIControlStateNormal];

        self.actionButton.enabled         = YES;

        NSString *annualTitle = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"EZCoinStore.Card.AnnualButtonFormat", nil, [NSBundle mainBundle], @"Yearly %@", @"Yearly option button on a store card"), item.annualPriceString];

        if (item.annualSavingsString.length > 0) {

            // The yearly button also states what it saves against paying
            // monthly, on a smaller second line.
            NSString *savingsLine = [NSString stringWithFormat:NSLocalizedStringWithDefaultValue(@"EZCoinStore.Card.AnnualSavingsFormat", nil, [NSBundle mainBundle], @"Save %@/yr", @"Yearly savings line on a store card"), item.annualSavingsString];

            NSMutableParagraphStyle *centered = [[NSMutableParagraphStyle alloc] init];

            centered.alignment = NSTextAlignmentCenter;

            NSAttributedString *title = [[NSAttributedString alloc] initWithString:annualTitle attributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:14], NSParagraphStyleAttributeName: centered }];

            NSAttributedString *savings = [[NSAttributedString alloc] initWithString:savingsLine attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:10.5], NSParagraphStyleAttributeName: centered }];

            NSMutableAttributedString *combined = [[NSMutableAttributedString alloc] initWithAttributedString:title];

            [combined appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];

            [combined appendAttributedString:savings];

            [self.annualButton setAttributedTitle:combined forState:UIControlStateNormal];

        } else {

            [self.annualButton setAttributedTitle:nil forState:UIControlStateNormal];

            [self.annualButton setTitle:annualTitle forState:UIControlStateNormal];

        }

        self.annualButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];

        [self.annualButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

        self.annualButton.enabled         = YES;

    } else if (item.isCurrentPlan) {

        [self.actionButton setTitle:NSLocalizedString(@"EZCoinStore.CancelPlan", @"Cancel plan button title") forState:UIControlStateNormal];

        self.actionButton.backgroundColor = [UIColor systemRedColor];

        [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

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

- (void)annualTapped {

    if (self.onAnnualAction) self.onAnnualAction();

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

    // The footnote fills whatever room is left above the purchase button, so
    // short top-up cards get a line or two and the taller subscription cards
    // (promo layout) get the full four lines — it never runs under the button.
    CGFloat footnoteTop    = cellPadding + 74;
    CGFloat footnoteHeight = MAX(0, MIN(48, actionTop - 6 - footnoteTop));
    self.footnoteLabel.frame = CGRectMake(rightX, footnoteTop, rightColumnWidth, footnoteHeight);

    CGFloat buttonWidth  = cardWidth - cellPadding * 2;

    if (!self.annualButton.hidden) {

        // Both terms on the card: the yearly button is small on the left,
        // the monthly button is the wide primary action on the right.
        CGFloat buttonGap   = 8;
        CGFloat yearlyWidth = floor((buttonWidth - buttonGap) * 0.36);
        self.annualButton.frame = CGRectMake(cellPadding, actionTop, yearlyWidth, buttonHeight);
        self.actionButton.frame = CGRectMake(cellPadding + yearlyWidth + buttonGap, actionTop, buttonWidth - yearlyWidth - buttonGap, buttonHeight);

    } else {

        self.actionButton.frame = CGRectMake(cellPadding, cardHeight - buttonHeight - cellPadding, buttonWidth, buttonHeight);
        self.annualButton.frame = CGRectZero;

    }

}

@end

// ── Main VC ───────────────────────────────────────────────────────────────────

@interface EZCoinStoreViewController () <UITableViewDelegate, UITableViewDataSource, SFSafariViewControllerDelegate>

@property (nonatomic, strong) UITableView             *tableView;

@property (nonatomic, strong) UIView                  *headerView;

@property (nonatomic, strong) UIView                  *promoBannerView;

@property (nonatomic, assign) BOOL                     isPromoActive;   // Promo/sale presentation flag — see kPromoBannerHeight comment above

@property (nonatomic, strong) NSDictionary            *activeSale;     // Live store_sales row when a server sale is on, else nil

@property (nonatomic, strong) UILabel                 *balanceLabel;

@property (nonatomic, strong) UILabel                 *warningLabel;

@property (nonatomic, strong) NSArray<EZStoreItem *>  *items;

@property (nonatomic, assign) NSInteger               visibleSubscriptionCount; // subscriptions at the head of items; the rest are top-ups

@property (nonatomic, strong) UIImage                 *coinImage;

@property (nonatomic, strong) NSString                *pendingPurchaseType;  // @"subscription" or @"topup"

@property (nonatomic, strong) NSString                *pendingTierName;      // Reserved for subscription retry logic (currently unused)

@property (nonatomic, strong) NSString                *pendingOrderID;

@property (nonatomic, strong) EZCoinPotView           *storePotView;

@property (nonatomic, strong) NSTimer                 *freeSpinsReelTimer;  // Cycles the celebration reels until they land

@property (nonatomic, strong) NSTimer                 *freeSpinsCountTimer; // Counts the won spins up inside the win message

@property (nonatomic, strong) UIActivityIndicatorView *spinner;

// Daily coins UI and state

@property (nonatomic, strong) UIButton  *dailyCoinsButton;       // Floating button top-left

@property (nonatomic, strong) UIButton  *usageLogButton;

@property (nonatomic, assign) BOOL       isDailyCoinsAvailable;  // Whether the server says coins can be claimed now

@property (nonatomic, strong) NSDate    *nextDailyClaimDate;     // ISO date from server; drives the countdown label

@property (nonatomic, assign) BOOL       openSlotAfterClaimCelebration; // Set only by a successful daily claim; dismissing that celebration opens the first Brainrot slot

@property (nonatomic, assign) NSInteger  pendingClaimSpins; // Free spins awarded alongside a coins claim (spins_added in the claim response); celebrated once the coin celebration is dismissed

@property (nonatomic, copy)   NSString        *pendingClaimSpinsMachine; // Server-suggested machine for the pending claim spins (claim response spins_machine: "classic", "penny", "plunder" or "phoenix"); nil = no suggestion (older server) — celebration keeps the original copy and Play Now opens the Classic slot

@property (nonatomic, assign) NSInteger  dailyCoinsPendingAmount; // 10 or 15 depending on membership; from server

@property (nonatomic, copy)   NSString        *webStoreURLString; // web_store_url from the status response; nil or empty when the server sends none

@property (nonatomic, strong) UIButton        *webStoreButton;    // Big button at the top of the store; opens webStoreURLString in Safari
@property (nonatomic, assign) BOOL            webStoreSlotVisible; // YES while the header is grown to fit webStoreButton

//@property (nonatomic, strong) NSTimer   *countdownTimer;         // Fires every second to tick the "Next: Xh Ym Xs" label

// Seasonal theme + sale clock
@property (nonatomic, strong) EZCoinStoreSeason *season;               // Theme currently presented; never nil after viewDidLoad
@property (nonatomic, strong) UIView            *seasonOverlayView;    // Non-interactive layer above the table that hosts the emitter
@property (nonatomic, strong) CAEmitterLayer    *seasonEmitterLayer;   // Falling leaves / snow; nil for no season or Reduce Motion
@property (nonatomic, strong) UILabel           *saleCountdownLabel;   // "Ends in …" row of the sale banner; nil when no sale has an end time
@property (nonatomic, strong) NSTimer           *storeClockTimer;      // 1 Hz: ticks the sale countdown and notices a season or sale rollover
@property (nonatomic, strong) NSDate            *lastSaleRefreshDate;  // Throttles refreshStoreSale when a sale's end time has passed

@end

@implementation EZCoinStoreViewController

- (void)viewDidLoad {

    [super viewDidLoad];

    self.season = [EZCoinStoreSeason seasonForKind:[EZCoinStoreSeason currentKind]];

    self.title = self.season.storeTitle ?: NSLocalizedString(@"EZCoinStore.Title", @"Coin store navigation title");

    self.view.backgroundColor = [EZTheme chatBackgroundColor];

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

    // Server-driven store sale (store_sales): when a sale is live, the
    // store presents it — banner with the server's title/body, sale
    // badges and multiplied coin amounts on top-up packs. Granting is
    // entirely server-side (capture-paypal-order /
    // verify-appstore-purchase read the same table), so this
    // presentation only advertises what the server will actually pay.
    // The cache read here is written by the app-launch fetch and by
    // refreshStoreSale below; a fresh fetch that disagrees with what
    // was presented rebuilds the store once, so a sale that starts or
    // ends mid-session is picked up without an app update. (The
    // 2026-11-18 note that used to sit here — x2 signage deliberately
    // removed while the server kept granting — still holds whenever
    // no sale is live: isPromoActive stays NO and nothing is shown.)
    self.activeSale = EZCachedActiveStoreSale();
    self.isPromoActive = (self.activeSale != nil);

    [self buildItems];

    [self setupUI];

    [self refreshBalance];

    [self addDailyCoinsButton];

    // Show the web store button right away from the last URL the server gave
    // us; refreshDailyCoinsStatus below confirms or clears it. TestFlight
    // builds buy through this button, so it must not wait on the network.
    NSString *cachedWebStoreURL = [[NSUserDefaults standardUserDefaults] stringForKey:kWebStoreURLCacheDefaultsKey];
    if (cachedWebStoreURL.length > 0) {
        self.webStoreURLString = cachedWebStoreURL;
        [self updateWebStoreButton];
    }

    [self refreshStoreSale];

    [self refreshDailyCoinsStatus];

#if APPSTORE
    // StoreKit: register the transaction observer (unfinished transactions
    // from a previous session redeliver and verify here) and add the
    // Restore Purchases button Apple requires for auto-renewable subs.
    [[EZStoreKitManager shared] startObserving];
    [self addRestorePurchasesButton];
#endif

#if DEBUG
    // Debug-only transaction inspector lives on the title row; customer-facing
    // builds never compile this control, while Usage Log remains below.
    [self addLedgerButton];
#endif

}

- (void)viewWillAppear:(BOOL)animated {

    [super viewWillAppear:animated];

    // Release the game pin when the store is back on top. Play Now

    // (openClaimCelebrationSlot / openFirstBrainrotSlot) pins this

    // sheet (modalInPresentation = YES) so a swipe down can't kill

    // the game mid-session — but this store has no close button;

    // swipe-down is its only exit. Once the game has been popped

    // and the store is showing again, the session the pin was

    // protecting is over, so unpin here or the user is trapped in

    // the store with no way out. Only when the store is the root

    // of its own presented sheet: when it's pushed inside the

    // slot flow, that flow's pin is not ours to release.

    UINavigationController *sheetNav = self.navigationController;

    if (sheetNav && sheetNav.viewControllers.firstObject == self && sheetNav.presentingViewController) {

        sheetNav.modalInPresentation = NO;

    }

    // Lightweight countdown refresh using already-cached timing data.

    // No network call here — refreshDailyCoinsStatus handles that on load

    // and again after each refreshBalance.

    if (self.nextDailyClaimDate) {

        [self updateDailyCoinsButtonState];

    }

    // A season or sale may have rolled over while the store was off screen.
    [self storeClockTicked];

    [self startStoreClockTimer];

    self.seasonEmitterLayer.birthRate = UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 1.0;

    [self startWebStorePulse];

    // Reduce Motion can flip while this screen is up; the handler below
    // stops the motion the moment it turns on.
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reduceMotionStatusDidChange) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];

}

- (void)viewWillDisappear:(BOOL)animated {

    [super viewWillDisappear:animated];

    [self stopCountdownTimer];

    [self stopStoreClockTimer];

    // Stop spawning particles while off screen (cells already falling finish).
    self.seasonEmitterLayer.birthRate = 0.0;

    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];

}

- (void)dealloc {

    [self.storeClockTimer invalidate];

    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];

}

// Keeps the emitter spanning the view when its width changes (rotation, split view).
- (void)viewDidLayoutSubviews {

    [super viewDidLayoutSubviews];

    if (self.seasonEmitterLayer) {

        CGFloat width = CGRectGetWidth(self.view.bounds);

        self.seasonEmitterLayer.frame = self.view.bounds;
        self.seasonEmitterLayer.emitterPosition = CGPointMake(width / 2.0, -14.0);
        self.seasonEmitterLayer.emitterSize = CGSizeMake(MAX(width, 1.0), 1.0);

    }

}

// ── Season + sale clock ───────────────────────────────────────────────────────

- (void)startStoreClockTimer {

    [self stopStoreClockTimer];

    __weak typeof(self) weakSelf = self;

    self.storeClockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {

        [weakSelf storeClockTicked];

    }];

}

- (void)stopStoreClockTimer {

    [self.storeClockTimer invalidate];

    self.storeClockTimer = nil;

}

// Runs once a second while the store is on screen. Rebuilds the store when the
// season has changed (midnight Eastern on Black Friday), re-checks the server
// once a sale's end time passes (it may have been replaced by the next one),
// and otherwise just ticks the banner countdown.
- (void)storeClockTicked {

    EZCoinStoreSeasonKind currentKind = [EZCoinStoreSeason currentKind];

    if (currentKind != self.season.kind) {

        self.season = [EZCoinStoreSeason seasonForKind:currentKind];

        [self rebuildStorePresentation];

        return;

    }

    NSDate *saleEndDate = dateFromISO8601String(self.activeSale[@"ends_at"]);

    if (!saleEndDate) return;

    NSDate *now = [NSDate date];

    NSTimeInterval secondsRemaining = [saleEndDate timeIntervalSinceDate:now];

    if (secondsRemaining <= 0) {

        if (!self.lastSaleRefreshDate || [now timeIntervalSinceDate:self.lastSaleRefreshDate] >= 10.0) {

            self.lastSaleRefreshDate = now;

            [self refreshStoreSale];

        }

        return;

    }

    [self updateSaleCountdownLabelWithSecondsRemaining:secondsRemaining];

}

- (NSString *)compactDurationStringForSeconds:(NSTimeInterval)seconds {

    NSInteger total   = MAX(0, (NSInteger)ceil(seconds));
    NSInteger days    = total / 86400;
    NSInteger hours   = (total % 86400) / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger secs    = total % 60;

    if (days > 0)  return [NSString stringWithFormat:@"%ldd %ldh %02ldm", (long)days, (long)hours, (long)minutes];
    if (hours > 0) return [NSString stringWithFormat:@"%ldh %02ldm %02lds", (long)hours, (long)minutes, (long)secs];
    return [NSString stringWithFormat:@"%ldm %02lds", (long)minutes, (long)secs];

}

- (void)updateSaleCountdownLabelWithSecondsRemaining:(NSTimeInterval)secondsRemaining {

    if (!self.saleCountdownLabel) return;

    NSString *format = NSLocalizedStringWithDefaultValue(@"EZCoinStore.Sale.EndsInFormat", nil, NSBundle.mainBundle, @"⏰ Ends in %@", @"Sale banner countdown; %@ is a duration like 5h 12m 03s");

    self.saleCountdownLabel.text = [NSString stringWithFormat:format, [self compactDurationStringForSeconds:secondsRemaining]];

}

// Tears the table, header and particle layer down and builds them again for
// the current season and sale. The web store button lives in the header, so
// its state is reset here — otherwise updateWebStoreButton would believe the
// (discarded) header still holds it and never put it back.
- (void)rebuildStorePresentation {

    [self.tableView removeFromSuperview];

    [self.spinner removeFromSuperview];

    [self.seasonOverlayView removeFromSuperview];

    self.seasonOverlayView  = nil;
    self.seasonEmitterLayer = nil;
    self.saleCountdownLabel = nil;
    self.tableView          = nil;
    self.webStoreButton     = nil;
    self.webStoreSlotVisible = NO;

    self.title = self.season.storeTitle ?: NSLocalizedString(@"EZCoinStore.Title", @"Coin store navigation title");

    [self buildItems];

    [self setupUI];

    [self updateWebStoreButton];

    [self addDailyCoinsButton];

    [self refreshDailyCoinsStatus];

    [self refreshBalance];

    self.seasonEmitterLayer.birthRate = 1.0;

}

// Falling leaves / snow above the table. Skipped for the no-season look and
// whenever Reduce Motion is on.
- (void)installSeasonOverlay {

    [self.seasonOverlayView removeFromSuperview];

    self.seasonOverlayView  = nil;
    self.seasonEmitterLayer = nil;

    if (self.season.kind == EZCoinStoreSeasonKindNone || UIAccessibilityIsReduceMotionEnabled()) return;

    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];

    overlay.userInteractionEnabled = NO;
    overlay.clipsToBounds          = YES;
    overlay.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.isAccessibilityElement = NO;

    CAEmitterLayer *emitter = [self.season newEmitterLayerForWidth:CGRectGetWidth(overlay.bounds)];

    if (!emitter) return;

    emitter.frame = overlay.bounds;

    [overlay.layer addSublayer:emitter];

    [self.view insertSubview:overlay aboveSubview:self.tableView];

    self.seasonOverlayView  = overlay;
    self.seasonEmitterLayer = emitter;

}

// Reduce Motion can flip while the store is on screen. Stop the seasonal
// motion and the button pulse the moment it turns on; put them back if it
// turns off again.
- (void)reduceMotionStatusDidChange {

    if (!self.isViewLoaded || !self.view.window) return;

    if (UIAccessibilityIsReduceMotionEnabled()) {

        [self.seasonOverlayView removeFromSuperview];

        self.seasonOverlayView  = nil;
        self.seasonEmitterLayer = nil;

        [self stopWebStorePulse];

    } else {

        [self installSeasonOverlay];

        [self startWebStorePulse];

    }

}

// ── Store sale (server-driven) ────────────────────────────────────────

// Fetches the live sale; when it differs from what this store
// presented (a sale started or ended since the cached read in
// viewDidLoad), rebuilds the presentation once with the fresh state.
- (void)refreshStoreSale {

    EZFetchActiveStoreSale(^(NSDictionary *sale) {

        NSString *freshID = [sale[@"id"] isKindOfClass:[NSString class]] ? sale[@"id"] : @"";
        NSString *shownID = [self.activeSale[@"id"] isKindOfClass:[NSString class]] ? self.activeSale[@"id"] : @"";

        if ([freshID isEqualToString:shownID]) return;

        self.activeSale = sale;
        self.isPromoActive = (sale != nil);

        [self rebuildStorePresentation];

    });

}

// The amount the server will actually grant for a top-up during a
// sale: the subtitle's first line is the coins line ("400 coins, one
// time") in every locale, so swap its leading amount for the
// multiplied one. Falls back to the untouched subtitle when no
// leading amount is found.
- (NSString *)saleAdjustedSubtitleForItem:(EZStoreItem *)item multiplier:(NSInteger)multiplier {

    NSString *subtitle = item.subtitle ?: @"";
    NSString *firstLine = [subtitle componentsSeparatedByString:@"\n"].firstObject ?: @"";
    NSString *rest = subtitle.length > firstLine.length ? [subtitle substringFromIndex:firstLine.length] : @"";

    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSString *amount = [formatter stringFromNumber:@(item.coins * multiplier)] ?: @"";

    // Digit groups only, never the space after them: the old
    // ^[\d][\d.,\s]* swallowed the space before "coins", so a sale
    // subtitle read "24,000coins, one-time".
    NSRegularExpression *amountRun = [NSRegularExpression regularExpressionWithPattern:@"^[\\d.,]+(?:[\\s][\\d.,]+)*" options:0 error:nil];
    NSString *adjusted = [amountRun stringByReplacingMatchesInString:firstLine options:0 range:NSMakeRange(0, firstLine.length) withTemplate:amount];

    if (amount.length == 0 || [adjusted isEqualToString:firstLine]) return subtitle;
    return [adjusted stringByAppendingString:rest];

}

// ── Build store items ─────────────────────────────────────────────────────────

// Overrides an item's badge + accent color to scream "promo" when

// isPromoActive is on. Applied to every package/tier. Skipped for a

// user's current active plan so the Cancel Plan button / status badge

// (CANCELLED, SUSPENDED, etc.) isn't stomped by promo styling — that status

// is more important for the user to see than a sale banner.

- (void)applyPromoBadgeIfNeededToItem:(EZStoreItem *)item {

    if (!self.isPromoActive || item.isCurrentPlan) return;

    // Server sale: badge the multiplier and show the multiplied coins
    // line — that is the amount the server will grant for this pack.
    if (self.activeSale) {

        id multiplierValue = self.activeSale[@"multiplier"];
        NSInteger multiplier = [multiplierValue respondsToSelector:@selector(integerValue)] ? [multiplierValue integerValue] : 1;

        if (multiplier > 1) {

            item.isSaleItem     = YES;
            item.saleMultiplier = multiplier;
            item.saleBaseCoins  = item.coins;
            item.badgeText      = [NSString stringWithFormat:@"%ldX COINS", (long)multiplier];
            item.accentColor    = [self saleAccentColor];
            item.subtitle       = [self saleAdjustedSubtitleForItem:item multiplier:multiplier];

            NSNumberFormatter *formatter = [NSNumberFormatter new];
            formatter.numberStyle = NSNumberFormatterDecimalStyle;

            NSString *normallyFormat = NSLocalizedStringWithDefaultValue(@"EZCoinStore.Sale.NormallyFormat", nil, NSBundle.mainBundle, @"Normally %@ coins", @"Sale card fine print; %@ is the pack's regular coin amount");

            item.badgeFootnoteText = [NSString stringWithFormat:normallyFormat, [formatter stringFromNumber:@(item.coins)] ?: @""];

        }

        return;

    }

    item.isSaleItem  = YES;

    item.badgeText   = NSLocalizedString(@"EZCoinStore.Badge.Buy1Get1", @"Buy one get one promo badge");

    item.accentColor = [self saleAccentColor]; // hot pink/red by default (or the season's sale color) — distinct from every other card color

}

// The color sale cards use: the season's sale color while a theme is active,
// otherwise the original hot pink/red.
- (UIColor *)saleAccentColor {

    return self.season.saleAccentColor ?: [UIColor colorWithRed:1.0 green:0.13 blue:0.35 alpha:1.0];

}

// Cycles the season's accent palette over the cards that no sale or active
// plan has already styled, one cycle per section so the two sections look alike.
- (void)applySeasonAccentsToItems:(NSArray<EZStoreItem *> *)storeItems {

    NSArray<UIColor *> *palette = self.season.tierAccentColors;

    if (palette.count == 0) return;

    NSUInteger subscriptionIndex = 0;
    NSUInteger topUpIndex        = 0;

    for (EZStoreItem *storeItem in storeItems) {

        NSUInteger paletteIndex = (storeItem.type == EZStoreItemTypeSubscription) ? subscriptionIndex++ : topUpIndex++;

        if (storeItem.isSaleItem || storeItem.isCurrentPlan) continue;

        storeItem.accentColor = palette[paletteIndex % palette.count];

    }

}

// Subscription-specific version: shows the exact bonus coin amount instead

// of "BUY 1 GET 1" (subscriptions aren't literally bought-in-pairs — this

// makes clear it's a one-time bonus on the coin grant, not a doubled price

// or a recurring doubling), plus a small disclaimer footnote.

- (void)applySubscriptionPromoBadgeToItem:(EZStoreItem *)item {

    if (item.isCurrentPlan) return;

    // Server sale: keep the regular recurring coin amount on the card.
    // The multiplier applies only to the first billing period, not renewals;
    // the badge and its footnote describe that one-time sale. The sale
    // replaces the promo below — the two never stack.
    if (self.activeSale) {

        id multiplierValue = self.activeSale[@"multiplier"];
        NSInteger multiplier = [multiplierValue respondsToSelector:@selector(integerValue)] ? [multiplierValue integerValue] : 1;

        if (multiplier > 1) {

            item.isSaleItem     = YES;
            item.saleMultiplier = multiplier;
            item.saleBaseCoins  = item.coins;
            item.badgeText      = [NSString stringWithFormat:@"%ldX COINS", (long)multiplier];
            item.accentColor    = [self saleAccentColor]; // matches the top-up sale styling

            // Spell out the term on the card itself, not only in the footer:
            // the server credits the multiplier on the first billing period
            // (paypal-webhook, ACTIVATED events), never on renewals.
            NSString *firstPeriodFormat = NSLocalizedStringWithDefaultValue(@"EZCoinStore.Sale.FirstPeriodCardFormat", nil, NSBundle.mainBundle, @"First billing period gets %ldX coins", @"Subscription sale card fine print; %ld is the sale multiplier");

            item.badgeFootnoteText = [NSString stringWithFormat:firstPeriodFormat, (long)multiplier];

        }

        return;

    }

    if (!self.isPromoActive) return;

    item.isSaleItem        = YES;

    item.badgeText         = [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.Promo.SubscriptionBadgeFormat", @"Subscription promo badge with bonus coins"), (long)item.coins];

    item.badgeFootnoteText = NSLocalizedString(@"EZCoinStore.Promo.SubscriptionFootnote", @"Subscription promo footnote");

    item.accentColor       = [self saleAccentColor]; // matches the top-up promo color

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

    ultra.coins           = 2000;

    ultra.accentColor     = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0]; // gold

    ultra.isCurrentPlan = isActive && ([currentTier isEqualToString:@"ultra"] || [currentTier isEqualToString:@"ultra_annual"]);

    if (([currentTier isEqualToString:@"ultra"] || [currentTier isEqualToString:@"ultra_annual"]) && !isActive && currentStatus)

        ultra.badgeText   = currentStatus.uppercaseString;

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
    power.coins            = 6000;
    power.accentColor     = [UIColor systemIndigoColor];
    power.isCurrentPlan   = isActive && ([currentTier isEqualToString:@"power"] || [currentTier isEqualToString:@"power_annual"]);
    if (([currentTier isEqualToString:@"power"] || [currentTier isEqualToString:@"power_annual"]) && !isActive && currentStatus)
        power.badgeText   = currentStatus.uppercaseString;
    [self applySubscriptionPromoBadgeToItem:power];
    [items addObject:power];

    EZStoreItem *enterprise    = [EZStoreItem new];
    enterprise.title           = NSLocalizedString(@"EZCoinStore.Tier.Enterprise", @"Enterprise subscription tier name");
    enterprise.subtitle        = NSLocalizedString(@"EZCoinStore.Tier.EnterpriseSubtitle", @"Enterprise subscription description");
    enterprise.priceString     = @"$99.99/mo";
    enterprise.planOrPackageID = kTierEnterprise;
    enterprise.type            = EZStoreItemTypeSubscription;
    enterprise.coins            = 12500;
    enterprise.accentColor     = [UIColor colorWithRed:0.0 green:0.58 blue:0.42 alpha:1.0]; // deep emerald — top-tier accent
    enterprise.isCurrentPlan   = isActive && ([currentTier isEqualToString:@"enterprise"] || [currentTier isEqualToString:@"enterprise_annual"]);
    if (([currentTier isEqualToString:@"enterprise"] || [currentTier isEqualToString:@"enterprise_annual"]) && !isActive && currentStatus)
        enterprise.badgeText   = currentStatus.uppercaseString;
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
    topup3.coins           = 2000;
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
    topup4.coins           = 6000;
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

    // Store trim (trial): only the products that are also sold
    // on the web store are offered for new purchases — Basic Weekly,
    // Ultra, Power and Enterprise subscriptions, and the $5, $20,
    // $49.99 and $99.99 top-ups. Every other tier and pack keeps its full
    // definition above; this filter only decides what is displayed
    // for sale, and removing it restores the full store. A card also
    // stays visible when it is the signed-in user's own active plan,
    // so existing subscribers on a trimmed tier keep their
    // current-plan card and its manage/cancel path — renewals are
    // server-side and unaffected either way.
    NSSet<NSString *> *saleIDs = [NSSet setWithObjects:
        kTierBasic, kTierBasicWeekly, kTierUltra, kTierPower, kTierEnterprise,
        @"TOPUP_400", @"TOPUP_2500", @"TOPUP_6250", @"TOPUP_12500", nil];
    NSMutableArray<EZStoreItem *> *visible = [NSMutableArray array];
    for (EZStoreItem *item in items) {
        if ([saleIDs containsObject:item.planOrPackageID] || item.isCurrentPlan) {
            [visible addObject:item];
        }
    }
    // Annual-capable tiers carry their yearly option on the item itself, so
    // the card can offer both terms as buttons (see EZStoreCell).
    for (EZStoreItem *item in visible) {

        NSDictionary *annualInfo = [self annualConfigForMonthlyTier:item.planOrPackageID];

        if (annualInfo) {

            item.annualPlanOrPackageID = annualInfo[@"annualTier"];

            item.monthlyPriceString    = annualInfo[@"monthlyPrice"];

            item.annualPriceString     = annualInfo[@"annualPrice"];

            item.annualSavingsString   = annualInfo[@"savings"];

        }

    }

    self.items = [visible copy];

    // Season colors go on after the sale styling above so a running sale
    // keeps its own accent; only plain cards pick up the theme palette.
    [self applySeasonAccentsToItems:visible];

    // The visible list is subscriptions first, then top-ups (build
    // order, kept by the filter). The table's two sections split the
    // list at this count, so the sections must be measured from the
    // filtered list itself — a fixed split puts top-ups under the
    // Subscriptions header whenever the trim hides a tier.
    NSInteger subscriptionCount = 0;
    for (EZStoreItem *item in visible) {
        if (item.type == EZStoreItemTypeSubscription) subscriptionCount++;
    }
    self.visibleSubscriptionCount = subscriptionCount;

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

    NSArray<UIColor *> *seasonBannerColors = self.season.bannerColors;

    if (seasonBannerColors.count >= 2) {

        NSMutableArray *seasonGradientColors = [NSMutableArray arrayWithCapacity:seasonBannerColors.count];

        for (UIColor *bannerColor in seasonBannerColors) [seasonGradientColors addObject:(id)bannerColor.CGColor];

        gradientLayer.colors = seasonGradientColors;

    } else {

        gradientLayer.colors = @[

            (id)[UIColor colorWithRed:1.0 green:0.15 blue:0.30 alpha:1.0].CGColor,

            (id)[UIColor colorWithRed:1.0 green:0.45 blue:0.05 alpha:1.0].CGColor,

        ];

    }

    gradientLayer.startPoint = CGPointMake(0, 0.5);

    gradientLayer.endPoint   = CGPointMake(1, 0.5);

    [self.promoBannerView.layer insertSublayer:gradientLayer atIndex:0];

    UILabel *headlineLabel = [[UILabel alloc]

        initWithFrame:CGRectMake(12, 6, self.view.bounds.size.width - 24, 44)];

    NSString *saleHeadline      = [self.activeSale[@"title"] isKindOfClass:[NSString class]] ? self.activeSale[@"title"] : nil;
    headlineLabel.text          = saleHeadline.length ? saleHeadline : NSLocalizedString(@"EZCoinStore.Promo.Headline", @"Promo banner headline");

    headlineLabel.font          = [UIFont boldSystemFontOfSize:22];

    headlineLabel.textColor     = [UIColor whiteColor];

    headlineLabel.textAlignment = NSTextAlignmentCenter;

    headlineLabel.numberOfLines = 2;

    headlineLabel.adjustsFontSizeToFitWidth = YES;

    [self.promoBannerView addSubview:headlineLabel];

    UILabel *subtextLabel = [[UILabel alloc]

        initWithFrame:CGRectMake(12, 50, self.view.bounds.size.width - 24, 40)];

    NSString *saleSubtext       = [self.activeSale[@"body"] isKindOfClass:[NSString class]] ? self.activeSale[@"body"] : nil;
    subtextLabel.text          = saleSubtext.length ? saleSubtext : NSLocalizedString(@"EZCoinStore.Promo.Subtitle", @"Promo banner subtitle");

    subtextLabel.font          = [UIFont boldSystemFontOfSize:15];

    subtextLabel.textColor     = [UIColor colorWithWhite:1.0 alpha:0.92];

    subtextLabel.textAlignment = NSTextAlignmentCenter;

    subtextLabel.numberOfLines = 2;

    subtextLabel.adjustsFontSizeToFitWidth = YES;

    [self.promoBannerView addSubview:subtextLabel];

    // Live "Ends in …" row, only when the sale carries an end time (the BOGO
    // fallback promo has none). storeClockTicked keeps it current each second.
    NSDate *saleEndDate = dateFromISO8601String(self.activeSale[@"ends_at"]);

    self.saleCountdownLabel = nil;

    if (saleEndDate) {

        UILabel *countdownLabel = [[UILabel alloc]

            initWithFrame:CGRectMake(12, 94, self.view.bounds.size.width - 24, 30)];

        countdownLabel.font          = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightHeavy];

        countdownLabel.textColor     = [UIColor whiteColor];

        countdownLabel.textAlignment = NSTextAlignmentCenter;

        countdownLabel.adjustsFontSizeToFitWidth = YES;

        countdownLabel.minimumScaleFactor = 0.6;

        countdownLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.22];

        countdownLabel.layer.cornerRadius = 15;

        countdownLabel.layer.masksToBounds = YES;

        [self.promoBannerView addSubview:countdownLabel];

        self.saleCountdownLabel = countdownLabel;

        [self updateSaleCountdownLabelWithSecondsRemaining:MAX(0, [saleEndDate timeIntervalSinceNow])];

    }

    // Slow, gentle pulse — enough to catch the eye scrolling past, not

    // frantic enough to look like a rendering glitch. Skipped under Reduce Motion.

    CABasicAnimation *pulseAnimation = [CABasicAnimation animationWithKeyPath:@"transform.scale"];

    pulseAnimation.fromValue          = @1.0;

    pulseAnimation.toValue            = @1.05;

    pulseAnimation.duration           = 0.85;

    pulseAnimation.autoreverses       = YES;

    pulseAnimation.repeatCount        = HUGE_VALF;

    pulseAnimation.timingFunction     = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

    if (!UIAccessibilityIsReduceMotionEnabled()) {

        [headlineLabel.layer addAnimation:pulseAnimation forKey:@"promoPulse"];

    }

    return self.promoBannerView;

}

- (void)setupUI {

    // When the promo banner is showing, everything else in the header shifts

    // down by kPromoBannerHeight so nothing overlaps it.

    CGFloat promoOffset = self.isPromoActive ? kPromoBannerHeight : 0;

    static CGFloat const kStoreControlsHeight = 48.0;
    CGFloat headerHeight = 62 + promoOffset + kStoreControlsHeight;

    // Winter gets a decoration strip at the bottom of the header: a snowman
    // between two evergreens, in the empty band above the first section.
    CGFloat decorHeight = self.season.kind == EZCoinStoreSeasonKindWinterHoliday ? 88.0 : 0.0;
    headerHeight += decorHeight;

    // Leave enough clearance above the balance label for the floating

    // daily-coins countdown button (pinned to the safe area top-left).

    self.headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, headerHeight)];

    self.headerView.backgroundColor = self.season.headerColor ?: [EZTheme cardColor];

    if (self.isPromoActive) {

        UIView *promoBanner = [self buildPromoBannerView];
        CGRect promoFrame = promoBanner.frame;
        promoFrame.origin.y = kStoreControlsHeight;
        promoBanner.frame = promoFrame;
        [self.headerView addSubview:promoBanner];

    }

    self.balanceLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 8 + promoOffset + kStoreControlsHeight, self.view.bounds.size.width, 22)];
    
    self.balanceLabel.adjustsFontSizeToFitWidth = YES;
    
    self.balanceLabel.minimumScaleFactor = 0.5;

    self.balanceLabel.font          = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];

    self.balanceLabel.textColor     = [UIColor secondaryLabelColor];

    self.balanceLabel.textAlignment = NSTextAlignmentCenter;

    self.balanceLabel.text          = NSLocalizedString(@"EZCoinStore.LoadingBalance", @"Balance loading text");

    [self.headerView addSubview:self.balanceLabel];

    // Low-coin warning banner — shown when the store is opened because

    // the user ran out mid-session (triggeringFeatureName is set by the caller)

    self.warningLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 34 + promoOffset + kStoreControlsHeight, self.view.bounds.size.width, 28)];
    
    self.warningLabel.adjustsFontSizeToFitWidth = YES;
    
    self.warningLabel.minimumScaleFactor = 0.5;

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

    if (decorHeight > 0) {

        CGFloat stripY = headerHeight - decorHeight;
        CGFloat viewWidth = self.view.bounds.size.width;

        UIImageView *leftTree = [[UIImageView alloc] initWithImage:[EZCoinStoreSeason evergreenImage]];
        leftTree.frame = CGRectMake(26, stripY + 16, 46, 64);
        leftTree.contentMode = UIViewContentModeScaleAspectFit;
        leftTree.userInteractionEnabled = NO;
        [self.headerView addSubview:leftTree];

        UIImageView *snowman = [[UIImageView alloc] initWithImage:[EZCoinStoreSeason snowmanImage]];
        snowman.frame = CGRectMake((viewWidth - 56) / 2.0, stripY + 5, 56, 78);
        snowman.contentMode = UIViewContentModeScaleAspectFit;
        snowman.userInteractionEnabled = NO;
        [self.headerView addSubview:snowman];

        UIImageView *rightTree = [[UIImageView alloc] initWithImage:[EZCoinStoreSeason evergreenImage]];
        rightTree.frame = CGRectMake(viewWidth - 26 - 46, stripY + 16, 46, 64);
        rightTree.contentMode = UIViewContentModeScaleAspectFit;
        rightTree.userInteractionEnabled = NO;
        [self.headerView addSubview:rightTree];

    }

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

    // Seasonal greeting on the left of the controls row, in the row's top half:
    // the free-coins button takes the bottom half (see addDailyCoinsButton), so
    // the two never draw over each other. It sits at y = 0 (above the 48 pt
    // controls row boundary), so the web-button shift never moves it, and it
    // stops short of the Usage Log button on the right.
    if (self.season.greeting.length > 0) {

        UILabel *greetingLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, MAX(0, self.view.bounds.size.width - 16 - 150), 24.0)];

        greetingLabel.text      = self.season.greeting;

        greetingLabel.font      = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];

        greetingLabel.textColor = self.season.sectionHeaderColor ?: [UIColor whiteColor];

        greetingLabel.adjustsFontSizeToFitWidth = YES;

        greetingLabel.minimumScaleFactor = 0.6;

        [self.headerView addSubview:greetingLabel];

    }

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];

    self.tableView.delegate         = self;

    self.tableView.dataSource       = self;

    self.tableView.backgroundColor  = [EZTheme chatBackgroundColor];

    // A soft seasonal wash fading down from the top, over the doodle pattern.
    if (self.season.backgroundTintColor) {

        EZCoinStoreTintView *tintView = [[EZCoinStoreTintView alloc] init];

        CAGradientLayer *tintGradient = (CAGradientLayer *)tintView.layer;

        tintGradient.colors     = @[(id)[self.season.backgroundTintColor colorWithAlphaComponent:0.30].CGColor,
                                    (id)[self.season.backgroundTintColor colorWithAlphaComponent:0.0].CGColor];

        tintGradient.startPoint = CGPointMake(0.5, 0.0);

        tintGradient.endPoint   = CGPointMake(0.5, 0.75);

        tintView.userInteractionEnabled = NO;

        self.tableView.backgroundView = tintView;

    }

    self.tableView.separatorStyle   = UITableViewCellSeparatorStyleNone;

    self.tableView.tableHeaderView  = self.headerView;

    // While a sale runs, one fine-print line at the bottom of the

    // store: subscription sale bonuses land on the first billing

    // period only.
    if (self.activeSale) {

        UILabel *saleNote = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, CGRectGetWidth(self.view.bounds) - 32, 34)];

        saleNote.text = NSLocalizedStringWithDefaultValue(@"EZCoinStore.Sale.FirstPeriodNote", nil, NSBundle.mainBundle, @"Subscription sale bonus: first billing period only.", nil);

        saleNote.font = [UIFont systemFontOfSize:11];

        saleNote.textColor = [UIColor colorWithWhite:1 alpha:.55];

        saleNote.textAlignment = NSTextAlignmentCenter;

        self.tableView.tableFooterView = saleNote;

    }

    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [self.tableView registerClass:[EZStoreCell class] forCellReuseIdentifier:@"EZStoreCell"];

    [self.view addSubview:self.tableView];

    self.spinner = [[UIActivityIndicatorView alloc]

        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];

    self.spinner.center           = self.view.center;

    self.spinner.hidesWhenStopped = YES;

    [self.view addSubview:self.spinner];

    [self installSeasonOverlay];

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

    if (section == 0) return self.visibleSubscriptionCount; // subscription tiers

    return (NSInteger)self.items.count - self.visibleSubscriptionCount; // top-up packages

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

    sectionTitleLabel.textColor               = self.season.sectionHeaderColor ?: [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.8];

    sectionTitleLabel.adjustsFontSizeToFitWidth = YES;

    [sectionHeaderView addSubview:sectionTitleLabel];

    UIView *goldDividerLine = [[UIView alloc] initWithFrame:CGRectMake(20, 30, tableView.bounds.size.width - 40, 0.5)];

    goldDividerLine.backgroundColor = self.season.sectionHeaderColor ? [self.season.sectionHeaderColor colorWithAlphaComponent:0.35] : [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.3];

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

    NSInteger itemIndex = indexPath.section == 0 ? indexPath.row : self.visibleSubscriptionCount + indexPath.row;

    if (itemIndex < (NSInteger)self.items.count) {

        EZStoreItem *item = self.items[itemIndex];

        [cell configureWithItem:item coinImage:self.coinImage];

        __weak typeof(self) weakSelf = self;

        cell.onAction = ^{

            if (!item.isCurrentPlan && item.type == EZStoreItemTypeSubscription && item.annualPlanOrPackageID.length > 0) {

                [weakSelf handleTermPurchaseForItem:item annual:NO];

            } else {

                [weakSelf handlePurchaseForItem:item];

            }

        };

        cell.onAnnualAction = ^{

            [weakSelf handleTermPurchaseForItem:item annual:YES];

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
        [self.dailyCoinsButton.centerYAnchor constraintEqualToAnchor:self.headerView.topAnchor constant:(self.season.greeting.length > 0 ? 36.0 : 24.0)],
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

    NSString *statusSuffix = @"?check=1";

    NSString *storefront = nil;
#if APPSTORE
    storefront = [EZStoreKitManager storefrontCountryCode];
#endif

    if (storefront.length) statusSuffix = [statusSuffix stringByAppendingFormat:@"&storefront=%@", storefront];

    NSURL *statusURL = [NSURL URLWithString:[[kStoreSupabaseURL

        stringByAppendingString:kDailyCoinsEndpoint]

        stringByAppendingString:statusSuffix]];

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

            self.webStoreURLString = jsonString(json, @"web_store_url");

            [self persistWebStoreURL];

            [self updateWebStoreButton];

            if (self.isDailyCoinsAvailable) {
                [self cancelDailyCoinsReadyReminder];
            } else {
                [self scheduleDailyCoinsReadyReminderForDate:self.nextDailyClaimDate requestPermissionIfNeeded:NO];
            }

            [self updateDailyCoinsButtonState];

        });

    }] resume];

}

// Shows or hides the big web store button at the top of the store, right
// under the controls row. The button exists only while the status response
// carries a web_store_url; with no URL (older server, or a storefront the
// server does not send one for) the header looks exactly as before. While
// the button is showing the header grows by kWebStoreSlotHeight and every
// frame-based header subview below the controls row shifts down with it;
// the two utility buttons are constraint-anchored to the header top and
// stay put. There is no footer button anymore.
- (void)updateWebStoreButton {

    BOOL shouldShow = self.webStoreURLString.length > 0;

    if (shouldShow == self.webStoreSlotVisible) return;

    if (shouldShow && !self.webStoreButton) {

        self.webStoreButton = [UIButton buttonWithType:UIButtonTypeCustom];

        // The hero of the store: TestFlight builds can only buy through the
        // website, and sideloaded builds get the sale here too. Two lines —
        // the call to action, and while a sale runs, what it is worth.
        [self.webStoreButton setAttributedTitle:[self webStoreButtonTitle] forState:UIControlStateNormal];

        self.webStoreButton.titleLabel.numberOfLines = 2;

        self.webStoreButton.titleLabel.textAlignment = NSTextAlignmentCenter;

        self.webStoreButton.titleLabel.adjustsFontSizeToFitWidth = YES;

        self.webStoreButton.titleLabel.minimumScaleFactor = 0.6;

        self.webStoreButton.contentEdgeInsets = UIEdgeInsetsMake(6, 18, 6, 18);

        [self.webStoreButton setBackgroundImage:[EZTheme primaryGradientImage] forState:UIControlStateNormal];

        self.webStoreButton.layer.cornerRadius = kWebStoreButtonHeight / 2.0;

        self.webStoreButton.layer.borderWidth = 2.5;

        self.webStoreButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.65].CGColor;

        self.webStoreButton.layer.masksToBounds = YES;

        self.webStoreButton.accessibilityHint = NSLocalizedStringWithDefaultValue(@"EZCoinStore.WebStore.Hint", nil, NSBundle.mainBundle, @"Opens the EZ Coin web store in Safari", @"Accessibility hint for the web store button");

        [self.webStoreButton addTarget:self

                                action:@selector(webStoreTapped:)

                      forControlEvents:UIControlEventTouchUpInside];

    }

    CGFloat delta = shouldShow ? kWebStoreSlotHeight : -kWebStoreSlotHeight;

    for (UIView *subview in self.headerView.subviews) {

        if (subview == self.webStoreButton) continue;

        if (!subview.translatesAutoresizingMaskIntoConstraints) continue;

        CGRect frame = subview.frame;

        if (frame.origin.y >= 48.0) {

            frame.origin.y += delta;

            subview.frame = frame;

        }

    }

    CGRect headerFrame = self.headerView.frame;

    headerFrame.size.height += delta;

    self.headerView.frame = headerFrame;

    if (shouldShow) {

        [self.headerView addSubview:self.webStoreButton];

        self.webStoreButton.frame = CGRectMake(16, 48.0 + 12.0, self.headerView.bounds.size.width - 32, kWebStoreButtonHeight);

        [self startWebStorePulse];

    } else {

        [self.webStoreButton removeFromSuperview];

    }

    self.webStoreSlotVisible = shouldShow;

    self.tableView.tableHeaderView = self.headerView;

    // There is no footer button anymore, but a running sale keeps its
    // fine-print footer (set in setupUI) — only clear it when there is none.
    if (!self.activeSale) self.tableView.tableFooterView = nil;

}

// Headline plus, while a server sale is live, one line saying what it is worth.
- (NSAttributedString *)webStoreButtonTitle {

    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];

    paragraph.alignment = NSTextAlignmentCenter;

    UIColor *textColor = [EZTheme backgroundColor];

    NSString *headline = NSLocalizedStringWithDefaultValue(@"EZCoinStore.WebStore.Title", nil, NSBundle.mainBundle, @"Buy coins on our website", @"Web store button headline");

    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:headline attributes:@{

        NSFontAttributeName:            [UIFont systemFontOfSize:21.0 weight:UIFontWeightHeavy],
        NSForegroundColorAttributeName: textColor,
        NSParagraphStyleAttributeName:  paragraph,

    }];

    id multiplierValue = self.activeSale[@"multiplier"];

    NSInteger multiplier = [multiplierValue respondsToSelector:@selector(integerValue)] ? [multiplierValue integerValue] : 1;

    if (multiplier > 1) {

        NSString *saleFormat = NSLocalizedStringWithDefaultValue(@"EZCoinStore.WebStore.SaleLineFormat", nil, NSBundle.mainBundle, @"%ldX COINS on every pack + your first subscription period", @"Second line of the web store button during a sale; %ld is the multiplier");

        NSString *saleLine = [@"\n" stringByAppendingString:[NSString stringWithFormat:saleFormat, (long)multiplier]];

        [title appendAttributedString:[[NSAttributedString alloc] initWithString:saleLine attributes:@{

            NSFontAttributeName:            [UIFont systemFontOfSize:13.0 weight:UIFontWeightBold],
            NSForegroundColorAttributeName: textColor,
            NSParagraphStyleAttributeName:  paragraph,

        }]];

    }

    return title;

}

// Slow scale pulse so the button keeps drawing the eye. Core Animation drops
// running animations when the view leaves the window, so viewWillAppear calls
// this again. Skipped under Reduce Motion.
- (void)startWebStorePulse {

    [self.webStoreButton.layer removeAnimationForKey:@"webStorePulse"];

    if (!self.webStoreButton || UIAccessibilityIsReduceMotionEnabled()) return;

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];

    pulse.fromValue      = @1.0;
    pulse.toValue        = @1.025;
    pulse.duration       = 1.1;
    pulse.autoreverses   = YES;
    pulse.repeatCount    = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

    [self.webStoreButton.layer addAnimation:pulse forKey:@"webStorePulse"];

}

- (void)stopWebStorePulse {

    [self.webStoreButton.layer removeAnimationForKey:@"webStorePulse"];

}

// Remembers the URL the server last gave us (or forgets it when the server
// stops sending one) so the button can show before the next status answer.
- (void)persistWebStoreURL {

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if (self.webStoreURLString.length > 0) {

        [defaults setObject:self.webStoreURLString forKey:kWebStoreURLCacheDefaultsKey];

    } else {

        [defaults removeObjectForKey:kWebStoreURLCacheDefaultsKey];

    }

}

// Opens the web store in Safari, the same way the PayPal checkout does.

- (void)webStoreTapped:(UIButton *)sender {

    NSURL *url = [NSURL URLWithString:self.webStoreURLString];

    // SFSafariViewController raises an exception for anything but http(s);
    // the URL comes from the network, so check before presenting.
    if (!url || !([url.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame || [url.scheme caseInsensitiveCompare:@"http"] == NSOrderedSame)) return;

    SFSafariViewController *safari = [[SFSafariViewController alloc]

        initWithURL:url];

    safari.delegate                = self;

    safari.preferredBarTintColor     = [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1.0];

    safari.preferredControlTintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

    [self presentViewController:safari animated:YES completion:nil];

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

    claimRequest.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"spins_machines": @[@"classic", @"penny", @"plunder", @"phoenix"]} options:0 error:nil];

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

                NSString *rewardType = jsonString(json, @"reward_type");

                self.nextDailyClaimDate    = dateFromISO8601String(jsonString(json, @"next_claim_at"));

                self.isDailyCoinsAvailable = NO;

                [self updateDailyCoinsButtonState];

                if ([rewardType isEqualToString:@"spins"]) {

                    NSInteger spinsAdded = jsonInteger(json, @"spins_added");

                    self.pendingClaimSpinsMachine = jsonString(json, @"spins_machine");

                    [self showFreeSpinsCelebration:spinsAdded];

                } else {

                    NSInteger coinsAdded = jsonInteger(json, @"coins_added");

                    NSInteger newBalance = jsonInteger(json, @"balance");

                    [[EZEntitlementManager shared] applyKnownBalance:newBalance];

                    // After the celebration is dismissed, continue into the
                    // first Brainrot slot (see dismissCelebration:).
                    self.openSlotAfterClaimCelebration = YES;

                    // The claim may also award free spins alongside the
                    // coins (spins_added, rolled server-side). They get
                    // their own celebration once this one is dismissed
                    // (see dismissCelebration:). Absent the field this
                    // stays 0 and the claim behaves exactly as before.
                    self.pendingClaimSpins = jsonInteger(json, @"spins_added");

                    self.pendingClaimSpinsMachine = jsonString(json, @"spins_machine");

                    [self showCoinCelebration:coinsAdded newBalance:newBalance];

                }

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

#if APPSTORE
// ── StoreKit: restore purchases + subscription management ────────────────────

- (void)addRestorePurchasesButton {
    UIButton *restoreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [restoreButton setTitle:NSLocalizedStringWithDefaultValue(@"EZCoinStore.RestorePurchases", nil, [NSBundle mainBundle], @"Restore Purchases", @"Restore purchases button title")
                   forState:UIControlStateNormal];
    restoreButton.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
    restoreButton.titleLabel.font   = [UIFont systemFontOfSize:16.0];
    [restoreButton addTarget:self
                      action:@selector(restorePurchasesTapped:)
            forControlEvents:UIControlEventTouchUpInside];
    UIBarButtonItem *restoreItem = [[UIBarButtonItem alloc] initWithCustomView:restoreButton];
    if (self.navigationItem.rightBarButtonItem) {
        NSMutableArray *items = [self.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
        if (self.navigationItem.rightBarButtonItem && ![items containsObject:self.navigationItem.rightBarButtonItem]) {
            [items addObject:self.navigationItem.rightBarButtonItem];
        }
        [items addObject:restoreItem];
        self.navigationItem.rightBarButtonItems = items;
    } else {
        self.navigationItem.rightBarButtonItem = restoreItem;
    }
}

- (void)restorePurchasesTapped:(UIButton *)sender {
    [self.spinner startAnimating];
    self.tableView.userInteractionEnabled = NO;
    [[EZStoreKitManager shared] restorePurchasesWithCompletion:^(BOOL restored, NSString *errorMessage) {
        [self.spinner stopAnimating];
        self.tableView.userInteractionEnabled = YES;
        if (errorMessage) {
            [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.Error", @"Generic error alert title")
                    message:errorMessage];
            return;
        }
        if (restored) {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"EZSubscriptionUpdated" object:nil];
            [self refreshBalance];
            [self showAlert:NSLocalizedStringWithDefaultValue(@"EZCoinStore.RestoreDone", nil, [NSBundle mainBundle], @"Purchases restored", @"Restore purchases success title")
                    message:NSLocalizedStringWithDefaultValue(@"EZCoinStore.RestoreDoneMessage", nil, [NSBundle mainBundle], @"Your subscription has been restored.", @"Restore purchases success message")];
        } else {
            [self showAlert:NSLocalizedStringWithDefaultValue(@"EZCoinStore.RestoreNone", nil, [NSBundle mainBundle], @"Nothing to restore", @"Restore purchases none found title")
                    message:NSLocalizedStringWithDefaultValue(@"EZCoinStore.RestoreNoneMessage", nil, [NSBundle mainBundle], @"No previous purchases were found for this Apple ID.", @"Restore purchases none found message")];
        }
    }];
}

- (void)presentManageSubscriptionsAlert {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:NSLocalizedString(@"EZCoinStore.Alert.CancelSubscription", @"Cancel subscription confirmation title")
                                            message:NSLocalizedStringWithDefaultValue(@"EZCoinStore.ManageSubscriptionsMessage", nil, [NSBundle mainBundle], @"This subscription is managed by Apple. You can change or cancel it in your Apple ID subscriptions.", @"Manage subscriptions message for the App Store build")
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZCoinStore.KeepPlan", @"Keep subscription button title")
                                               style:UIAlertActionStyleCancel
                                             handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringWithDefaultValue(@"EZCoinStore.ManageSubscriptions", nil, [NSBundle mainBundle], @"Manage Subscription", @"Manage subscription button title")
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://apps.apple.com/account/subscriptions"]
                                           options:@{}
                                 completionHandler:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
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

#if APPSTORE
        // App Store subscriptions are managed by Apple, not the server —
        // send the user to their Apple subscription page instead of the
        // PayPal cancel flow.
        [self presentManageSubscriptionsAlert];
        return;
#endif

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

// Direct checkout for one term from the term buttons on a store card. The card
// itself presented both options, so there is no upsell step on this path.
- (void)handleTermPurchaseForItem:(EZStoreItem *)item annual:(BOOL)annual {

    NSString *token = [EZAuthManager shared].accessToken;

    if (!token) {

        [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.NotLoggedIn", @"Not logged in alert title") message:NSLocalizedString(@"EZCoinStore.Alert.SignInFirst", @"Sign in first message")];

        return;

    }

    NSString *tier = annual ? item.annualPlanOrPackageID : item.planOrPackageID;

    if (!tier.length) return;

    [self.spinner startAnimating];

    self.tableView.userInteractionEnabled = NO;

    [self startSubscriptionForTier:tier token:token];

}

// Per-tier annual option info — the annual tier id and the prices both
// the store card buttons and the upsell sheet quote, from one table so
// the two surfaces can never disagree.
- (NSDictionary *)annualConfigForMonthlyTier:(NSString *)monthlyTier {

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
    if (!config) return nil;

    // While the live store sale carries annual prices
    // (store_sales.annual_prices), the yearly price — and the savings
    // against 12 monthly payments — come from the sale, so the card
    // buttons and the upsell quote exactly what checkout charges.
    // EZCachedActiveStoreSale checks the sale window, so the regular
    // prices return on their own when the window ends.
    NSDictionary *annualPrices = EZCachedActiveStoreSale()[@"annual_prices"];
    id salePrice = [annualPrices isKindOfClass:[NSDictionary class]] ? annualPrices[monthlyTier] : nil;
    if ([salePrice isKindOfClass:[NSNumber class]]) {
        double monthly = [[config[@"monthlyPrice"] stringByReplacingOccurrencesOfString:@"$" withString:@""] doubleValue];
        double yearly  = [salePrice doubleValue];
        double saved   = monthly * 12.0 - yearly;
        NSMutableDictionary *saleConfig = [config mutableCopy];
        saleConfig[@"annualPrice"] = [NSString stringWithFormat:@"$%.2f", yearly];
        saleConfig[@"savings"] = (saved == floor(saved))
            ? [NSString stringWithFormat:@"$%.0f", saved]
            : [NSString stringWithFormat:@"$%.2f", saved];
        saleConfig[@"annualSale"] = @YES;
        return saleConfig;
    }

    return config;

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
    NSDictionary *config = [self annualConfigForMonthlyTier:monthlyTier];
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

    NSString *message = [config[@"annualSale"] boolValue]
        ? NSLocalizedStringWithDefaultValue(@"EZCoinStore.Upsell.MessageAnnualSale", nil, [NSBundle mainBundle], @"Pay annually and save 75% compared with monthly billing.", @"Pay yearly and save 75% vs monthly message while an annual sale is live")
        : NSLocalizedString(@"EZCoinStore.Upsell.Message", @"Pay yearly and save 25% vs monthly message");

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
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.5;
    titleLabel.text          = title;
    titleLabel.font          = [UIFont boldSystemFontOfSize:20];
    titleLabel.textColor     = accent;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 2;
    [card addSubview:titleLabel];

    UILabel *messageLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 84, 252, 44)];
    messageLabel.adjustsFontSizeToFitWidth = YES;
    messageLabel.minimumScaleFactor = 0.5;
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
    orLabel.adjustsFontSizeToFitWidth = YES;
    orLabel.minimumScaleFactor = 0.5;
    orLabel.text          = NSLocalizedString(@"EZCoinStore.Upsell.Or", @"'or' divider text");
    orLabel.font          = [UIFont systemFontOfSize:12];
    orLabel.textColor     = [UIColor secondaryLabelColor];
    orLabel.textAlignment = NSTextAlignmentCenter;
    [card addSubview:orLabel];

    // Secondary option — monthly, outlined rather than filled so it doesn't
    // compete visually with the annual CTA above it.
    UIButton *monthlyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    monthlyButton.frame                  = CGRectMake(30, 240, 240, 56);
    monthlyButton.backgroundColor        = [UIColor colorWithWhite:1 alpha:0.12];
    monthlyButton.layer.cornerRadius     = 14;
    monthlyButton.layer.borderWidth      = 1.5;
    monthlyButton.layer.borderColor      = [accent colorWithAlphaComponent:0.8].CGColor;
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

#if APPSTORE
    // App Store build: StoreKit purchase. All tiers are one subscription
    // group, so switching plans needs no cancel step — Apple prorates and
    // moves the subscription. The server grant lands via
    // verify-appstore-purchase; mirror the PayPal path's success handling
    // (refresh + EZSubscriptionUpdated) once it does.
    [[EZStoreKitManager shared] purchaseSubscriptionTier:tierName
        completion:^(EZStoreKitOutcome outcome, NSInteger coinsAdded, NSInteger balance, BOOL alreadyGranted, NSString *errorMessage) {
            [self.spinner stopAnimating];
            self.tableView.userInteractionEnabled = YES;
            switch (outcome) {
                case EZStoreKitOutcomeSuccess:
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:@"EZSubscriptionUpdated" object:nil];
                    [self refreshBalance];
                    break;
                case EZStoreKitOutcomeFailed:
                    [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.Error", @"Generic error alert title")
                            message:errorMessage ?: NSLocalizedString(@"EZCoinStore.Alert.CheckoutStartFailed", @"Checkout start failure message")];
                    break;
                case EZStoreKitOutcomeCancelled:
                case EZStoreKitOutcomePendingVerification:
                    [self refreshBalance];
                    break;
            }
        }];
    return;
#endif

#if !APPSTORE

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

#endif

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

#if !APPSTORE
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

#endif

// ── One-time top-up checkout ──────────────────────────────────────────────────

- (void)startTopUpForPackageID:(NSString *)packageID coins:(NSInteger)coins token:(NSString *)token {

#if APPSTORE
    // App Store build: StoreKit purchase (consumable). On a verified grant
    // run the exact success path the PayPal capture uses — apply the known
    // balance, celebrate, notify, then a delayed sync refresh.
    [[EZStoreKitManager shared] purchaseTopUpPackage:packageID
        completion:^(EZStoreKitOutcome outcome, NSInteger coinsAdded, NSInteger balance, BOOL alreadyGranted, NSString *errorMessage) {
            [self.spinner stopAnimating];
            self.tableView.userInteractionEnabled = YES;
            switch (outcome) {
                case EZStoreKitOutcomeSuccess:
                    if (alreadyGranted) {
                        [self refreshBalance];
                    } else {
                        [[EZEntitlementManager shared] applyKnownBalance:balance];
                        [self showCoinCelebration:coinsAdded newBalance:balance];
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:@"EZSubscriptionUpdated" object:nil];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            [self refreshBalance];
                        });
                    }
                    break;
                case EZStoreKitOutcomeFailed:
                    [self showAlert:NSLocalizedString(@"EZCoinStore.Alert.Error", @"Generic error alert title")
                            message:errorMessage ?: NSLocalizedString(@"EZCoinStore.Alert.PurchaseNotConfirmed", @"Purchase not confirmed fallback message")];
                    [self refreshBalance];
                    break;
                case EZStoreKitOutcomeCancelled:
                case EZStoreKitOutcomePendingVerification:
                    [self refreshBalance];
                    break;
            }
        }];
    return;
#endif

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

#if !APPSTORE
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

#endif

// ── Coin celebration overlay ──────────────────────────────────────────────────

// Shown after any successful coin credit: purchases, top-ups, and daily rewards.

- (NSString *)freeSpinsAmountTextForCount:(NSInteger)count {

    // When the claim named a machine for these spins, the celebration

    // says so; the named machine is also where Play Now goes (see

    // openClaimCelebrationSlot). No suggestion (older server): the

    // original copy, byte for byte.

    NSString *machine = self.pendingClaimSpinsMachine;

    if ([machine isEqualToString:@"penny"]) {

        return [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.FreeSpins.MessagePenny", @"Free spins celebration message naming the Penny Slots"), (long)count];

    }

    if ([machine isEqualToString:@"plunder"]) {

        return [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.FreeSpins.MessagePlunder", @"Free spins celebration message naming Plunder Bay"), (long)count];

    }

    if ([machine isEqualToString:@"phoenix"]) {

        return [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.FreeSpins.MessagePhoenix", @"Free spins celebration message naming Phoenix Pavilion"), (long)count];

    }

    if ([machine isEqualToString:@"classic"]) {

        return [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.FreeSpins.MessageClassic", @"Free spins celebration message naming the Classic Slots"), (long)count];

    }

    return [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.FreeSpins.Message", @"Free spins celebration message"), (long)count];

}

- (void)showFreeSpinsCelebration:(NSInteger)spinsAdded {

    // Same overlay family as the coin celebration, slot-machine edition: a

    // card springs in, three reels spin and land one by one on a jackpot

    // 7-7-7, the prize counts up inside the localized win message, and

    // sparkles burst when the last reel lands. Play Now opens the first

    // Brainrot slot (the old alert button's destination); Later dismisses.

    // If a celebration is somehow already up, replace it synchronously.

    [self.freeSpinsReelTimer invalidate];

    self.freeSpinsReelTimer = nil;

    [self.freeSpinsCountTimer invalidate];

    self.freeSpinsCountTimer = nil;

    [[self.view viewWithTag:9902] removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];

    overlay.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.75];

    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    overlay.alpha            = 0;

    overlay.tag              = 9902;

    [self.view addSubview:overlay];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 316)];

    card.center            = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2);

    card.backgroundColor   = [UIColor colorWithRed:0.08 green:0.08 blue:0.14 alpha:1.0];

    card.layer.cornerRadius = 24;

    card.layer.borderWidth  = 1.5;

    card.layer.borderColor  = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.6].CGColor;

    card.transform          = CGAffineTransformMakeScale(0.7, 0.7);

    [overlay addSubview:card];

    UILabel *headlineLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 16, 240, 30)];
    
    headlineLabel.adjustsFontSizeToFitWidth = YES;
    
    headlineLabel.minimumScaleFactor = 0.5;

    headlineLabel.text          = NSLocalizedString(@"EZCoinStore.FreeSpins.Title", @"Free spins celebration title");

    headlineLabel.font          = [UIFont boldSystemFontOfSize:20];

    headlineLabel.textColor     = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

    headlineLabel.textAlignment = NSTextAlignmentCenter;

    [card addSubview:headlineLabel];

    // The reels cycle the Classic machine's own fallback glyphs; the

    // jackpot they land on is its red seven.

    NSArray<NSString *> *spinGlyphs = @[@"🍒", @"🔔", @"♦︎", @"🧠", @"▰", @"7"];

    NSMutableArray<UILabel *> *glyphLabels = [NSMutableArray array];

    NSMutableArray<UIView *> *tiles = [NSMutableArray array];

    for (NSInteger reel = 0; reel < 3; reel++) {

        UIView *tile = [[UIView alloc] initWithFrame:CGRectMake(20 + reel * 84, 58, 72, 84)];

        tile.backgroundColor    = [UIColor colorWithRed:0.16 green:0.10 blue:0.28 alpha:1.0];

        tile.layer.cornerRadius = 12;

        tile.layer.borderWidth  = 1.0;

        tile.layer.borderColor  = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;

        [card addSubview:tile];

        [tiles addObject:tile];

        UILabel *glyph = [[UILabel alloc] initWithFrame:tile.bounds];
        
        glyph.adjustsFontSizeToFitWidth = YES;
        
        glyph.minimumScaleFactor = 0.5;

        glyph.text          = spinGlyphs[(NSUInteger)reel % spinGlyphs.count];

        glyph.font          = [UIFont systemFontOfSize:38 weight:UIFontWeightBlack];

        glyph.textColor     = [UIColor colorWithRed:1.0 green:0.77 blue:0.18 alpha:1.0];

        glyph.textAlignment = NSTextAlignmentCenter;

        [tile addSubview:glyph];

        [glyphLabels addObject:glyph];

    }

    UILabel *amountLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 158, 248, 30)];

    amountLabel.text          = [self freeSpinsAmountTextForCount:0];

    amountLabel.font          = [UIFont boldSystemFontOfSize:21];

    amountLabel.textColor     = [UIColor whiteColor];

    amountLabel.textAlignment = NSTextAlignmentCenter;

    amountLabel.adjustsFontSizeToFitWidth = YES;

    amountLabel.minimumScaleFactor        = 0.65;

    [card addSubview:amountLabel];

    UIButton *playNowButton = [UIButton buttonWithType:UIButtonTypeSystem];

    playNowButton.frame              = CGRectMake(40, 224, 200, 46);

    playNowButton.backgroundColor    = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

    playNowButton.layer.cornerRadius = 12;

    playNowButton.titleLabel.font    = [UIFont boldSystemFontOfSize:16];

    [playNowButton setTitle:NSLocalizedString(@"EZCoinStore.FreeSpins.PlayNow", @"Play now button") forState:UIControlStateNormal];

    [playNowButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];

    [playNowButton addTarget:self action:@selector(freeSpinsPlayNowTapped) forControlEvents:UIControlEventTouchUpInside];

    [card addSubview:playNowButton];


    __block NSInteger stoppedReels = 0;

    __weak typeof(self) weakSelf = self;

    self.freeSpinsReelTimer = [NSTimer scheduledTimerWithTimeInterval:0.07 repeats:YES block:^(NSTimer *timer) {

        if (!overlay.superview) { [timer invalidate]; return; }

        for (NSInteger reel = stoppedReels; reel < 3; reel++) {

            glyphLabels[(NSUInteger)reel].text = spinGlyphs[arc4random_uniform((u_int32_t)spinGlyphs.count)];

        }

    }];

    // The reels stop left to right; each stop bounces its tile and clicks,

    // and the last one pays out: sparkles, a success buzz, a prize pulse.

    NSArray<NSNumber *> *stopDelays = @[@0.75, @1.2, @1.65];

    for (NSInteger reel = 0; reel < 3; reel++) {

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stopDelays[(NSUInteger)reel].doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

            if (!overlay.superview) return;

            stoppedReels = reel + 1;

            UILabel *glyph = glyphLabels[(NSUInteger)reel];

            glyph.text      = @"7";

            glyph.textColor = [UIColor redColor];

            glyph.font      = [UIFont systemFontOfSize:44 weight:UIFontWeightBlack];

            UIView *tile = tiles[(NSUInteger)reel];

            tile.layer.borderColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.9].CGColor;

            [UIView animateWithDuration:0.14 animations:^{

                tile.transform = CGAffineTransformMakeScale(1.12, 1.12);

            } completion:^(BOOL finished) {

                [UIView animateWithDuration:0.18 animations:^{

                    tile.transform = CGAffineTransformIdentity;

                }];

            }];

            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];

            if (reel == 2) {

                [weakSelf.freeSpinsReelTimer invalidate];

                weakSelf.freeSpinsReelTimer = nil;

                [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];

                [weakSelf burstSparklesOverReelsInCard:card];

                [UIView animateWithDuration:0.18 animations:^{

                    amountLabel.transform = CGAffineTransformMakeScale(1.12, 1.12);

                } completion:^(BOOL finished) {

                    [UIView animateWithDuration:0.18 animations:^{

                        amountLabel.transform = CGAffineTransformIdentity;

                    }];

                }];

            }

        });

    }

    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:0 animations:^{

        overlay.alpha  = 1;

        card.transform = CGAffineTransformIdentity;

    } completion:^(BOOL finished) {

        if (!overlay.superview) return;

        // Count the prize up inside the win message while the reels land,

        // easing out so the last numbers arrive with a little weight.

        __block NSInteger ticks = 0;

        weakSelf.freeSpinsCountTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {

            if (!overlay.superview) { [timer invalidate]; return; }

            ticks += 1;

            double progress = MIN(1.0, ticks / 26.0);

            double eased = 1.0 - (1.0 - progress) * (1.0 - progress);

            NSInteger shown = (NSInteger)llround(spinsAdded * eased);

            amountLabel.text = [self freeSpinsAmountTextForCount:shown];

            if (progress >= 1.0) {

                [timer invalidate];

                if (weakSelf.freeSpinsCountTimer == timer) weakSelf.freeSpinsCountTimer = nil;

            }

        }];

    }];

}

- (void)freeSpinsPlayNowTapped {

    [self dismissFreeSpinsCelebrationOpeningSlot:YES];

}


- (void)dismissFreeSpinsCelebrationOpeningSlot:(BOOL)openSlot {

    [self.freeSpinsReelTimer invalidate];

    self.freeSpinsReelTimer = nil;

    [self.freeSpinsCountTimer invalidate];

    self.freeSpinsCountTimer = nil;

    UIView *overlay = [self.view viewWithTag:9902];

    if (!overlay) {

        if (openSlot) [self openClaimCelebrationSlot];

        return;

    }

    [UIView animateWithDuration:0.25 animations:^{

        overlay.alpha = 0;

    } completion:^(BOOL finished) {

        [overlay removeFromSuperview];

        if (openSlot) [self openClaimCelebrationSlot];

    }];

}

// A one-shot burst of gold stars over the reels when the jackpot lands.

- (void)burstSparklesOverReelsInCard:(UIView *)card {

    CAEmitterLayer *emitter = [CAEmitterLayer layer];

    emitter.emitterPosition = CGPointMake(card.bounds.size.width / 2, 100);

    emitter.emitterSize     = CGSizeMake(240, 30);

    emitter.emitterShape    = kCAEmitterLayerRectangle;

    CAEmitterCell *star = [CAEmitterCell emitterCell];

    star.contents      = (id)[self sparkleStarImage].CGImage;

    star.birthRate     = 240;

    star.lifetime      = 0.9;

    star.lifetimeRange = 0.3;

    star.velocity      = 170;

    star.velocityRange = 90;

    star.emissionRange = 6.283185307179586;

    star.spin          = 4;

    star.spinRange     = 6;

    star.scale         = 0.55;

    star.scaleRange    = 0.4;

    star.alphaSpeed    = -1.1;

    star.color         = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0].CGColor;

    emitter.emitterCells = @[star];

    [card.layer addSublayer:emitter];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

        emitter.birthRate = 0;

    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

        [emitter removeFromSuperlayer];

    });

}

// A small four-point star drawn in code — no bundled asset needed. Drawn

// white; the emitter cell's color tints it gold.

- (UIImage *)sparkleStarImage {

    CGSize size = CGSizeMake(16, 16);

    UIGraphicsBeginImageContextWithOptions(size, NO, 0);

    UIBezierPath *starPath = [UIBezierPath bezierPath];

    [starPath moveToPoint:CGPointMake(8, 0)];

    [starPath addLineToPoint:CGPointMake(10, 6)];

    [starPath addLineToPoint:CGPointMake(16, 8)];

    [starPath addLineToPoint:CGPointMake(10, 10)];

    [starPath addLineToPoint:CGPointMake(8, 16)];

    [starPath addLineToPoint:CGPointMake(6, 10)];

    [starPath addLineToPoint:CGPointMake(0, 8)];

    [starPath addLineToPoint:CGPointMake(6, 6)];

    [starPath closePath];

    [[UIColor whiteColor] setFill];

    [starPath fill];

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();

    UIGraphicsEndImageContext();

    return image;

}

// Opens the first Brainrot slot — the Classic machine, first card in
// BRSlotGamePickerViewController — the same way the picker opens it: a plain
// BRSlotMachineViewController pushed onto the current navigation stack.
// The slot fetches free_spins_remaining when it appears, so the user's free
// spins show on its spin button automatically.
- (void)openFirstBrainrotSlot {

    BRSlotMachineViewController *slot = [BRSlotMachineViewController new];

    if (self.navigationController) {

        self.navigationController.modalInPresentation = YES; // Pin: a swipe down must not dismiss the game (or this sheet under it) mid-session

        [self.navigationController pushViewController:slot animated:YES];

    } else {

        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:slot];

        nav.modalPresentationStyle = UIModalPresentationPageSheet;

        nav.modalInPresentation = YES; // Pin: a swipe down must not dismiss the game mid-session

        [self presentViewController:nav animated:YES completion:nil];

    }

}

// Play Now destination for a claim free-spins celebration: the

// machine the claim suggested, or the Classic slot when it didn't

// (older server). The suggestion is consumed either way. The spins

// themselves land in that machine's own pool server-side —

// this only chooses where the

// player is taken to play them.

- (void)openClaimCelebrationSlot {

    NSString *machine = self.pendingClaimSpinsMachine;

    self.pendingClaimSpinsMachine = nil;

    UIViewController *slot = nil;

    if ([machine isEqualToString:@"penny"]) {

        slot = [BRPennySlotViewController new];

    } else if ([machine isEqualToString:@"plunder"]) {

        slot = [BRPlunderBayViewController new];

    } else if ([machine isEqualToString:@"phoenix"]) {

        slot = [BRPhoenixPavilionSlotViewController new];

    }

    if (!slot) {

        [self openFirstBrainrotSlot];

        return;

    }

    if (self.navigationController) {

        self.navigationController.modalInPresentation = YES; // Pin: a swipe down must not dismiss the game (or this sheet under it) mid-session

        [self.navigationController pushViewController:slot animated:YES];

    } else {

        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:slot];

        nav.modalPresentationStyle = UIModalPresentationPageSheet;

        nav.modalInPresentation = YES; // Pin: a swipe down must not dismiss the game mid-session

        [self presentViewController:nav animated:YES completion:nil];

    }

}

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
    
    headlineLabel.adjustsFontSizeToFitWidth = YES;
    
    headlineLabel.minimumScaleFactor = 0.5;

    headlineLabel.text          = NSLocalizedString(@"EZCoinStore.Celebration.CoinsAdded", @"Coin celebration headline");

    headlineLabel.font          = [UIFont boldSystemFontOfSize:20];

    headlineLabel.textColor     = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

    headlineLabel.textAlignment = NSTextAlignmentCenter;

    [celebrationCard addSubview:headlineLabel];

    UILabel *amountLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 172, 240, 28)];
    
    amountLabel.adjustsFontSizeToFitWidth = YES;
    
    amountLabel.minimumScaleFactor = 0.5;

    amountLabel.text          = [NSString stringWithFormat:NSLocalizedString(@"EZCoinStore.Celebration.AmountFormat", @"Coin celebration amount"), (long)coinsAdded];

    amountLabel.font          = [UIFont boldSystemFontOfSize:26];

    amountLabel.textColor     = [UIColor whiteColor];

    amountLabel.textAlignment = NSTextAlignmentCenter;

    [celebrationCard addSubview:amountLabel];

    UILabel *newBalanceLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 204, 240, 22)];
    
    newBalanceLabel.adjustsFontSizeToFitWidth = YES;
    
    newBalanceLabel.minimumScaleFactor = 0.5;

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
            @"ultra":             @2000,
            @"ultra_annual":      @24000,
            @"power":             @6000,
            @"power_annual":      @72000,
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

        // Spins awarded alongside the coins get their own celebration
        // first — its Play Now button opens the same first slot.
        if (self.pendingClaimSpins > 0) {

            NSInteger spins = self.pendingClaimSpins;

            self.pendingClaimSpins = 0;

            self.openSlotAfterClaimCelebration = NO;

            [self showFreeSpinsCelebration:spins];

            return;

        }

        // A successful daily claim continues straight into the first
        // Brainrot slot once its celebration is dismissed. Purchase and
        // top-up celebrations never set the flag, so they are unchanged.
        if (self.openSlotAfterClaimCelebration) {

            self.openSlotAfterClaimCelebration = NO;

            [self openFirstBrainrotSlot];

        }

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
