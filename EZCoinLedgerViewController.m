// EZCoinLedgerViewController.m
// EZCompleteUI v1.4
//
// Purpose:
//   Admin-only ledger displaying every coin transaction across all users.
//   Connects to the get-admin-ledger edge function (mode=user), which requires
//   both a valid user JWT and an admin secret header. The secret is entered once
//   via an in-app prompt and stored in NSUserDefaults — it is never hardcoded in
//   the binary. A 403 response clears the stored secret and re-shows the prompt.
//
//   The summary header shows platform-wide totals (calls, coins spent, API cost,
//   margin, and coins currently in circulation). Individual rows show per-call
//   detail: email, feature, model, prompt snippet, coins charged, running balance,
//   token counts, API cost, and efficiency.
//
//   A search bar at the top filters by email (type "@") or feature name (anything
//   else — e.g. "tts", "chat", "image"). Filters are sent to the server so paging
//   and aggregates always reflect the filtered set, not just the loaded page.
//
//   The Export button fetches all pages of the current filter (up to 2,000 rows)
//   and produces either a CSV file (for Numbers/Excel) or a formatted PDF report,
//   delivered via the standard iOS share sheet.
//
// DEBUG-only: excluded from Release builds entirely. The admin secret prompt is
//   real protection on its own, but per-call prompts, costs, and user data have
//   no business being reachable from a shipped binary. The call site in
//   EZCoinStoreViewController is gated to match; any non-DEBUG reference to this
//   class will fail to compile rather than silently shipping.
//
// v1.8 — Status display, copyable cards, status filter
//   - Cards now show an explicit status label (Completed / Pending / Error)
//     next to the existing status dot, and an error message line (from
//     error_text, per get-admin-ledger's ez_all_ledger_rows select) when
//     status = "error".
//   - Long-press on any card copies a plain-text summary of that transaction
//     to the pasteboard (haptic + brief flash for feedback).
//   - Search bar gained a scope bar (All / Completed / Pending / Error).
//     get-admin-ledger has no status query param, so this filters
//     client-side over whatever rows are already loaded rather than
//     refetching; scrolling near the bottom still pages in more rows from
//     the server as before, which then also get filtered.
//
// v1.7 — CSV data quality fixes
//   - Double header row: the appendString call was split across three string
//     literals during a prior fix pass, producing the first 10 column names
//     twice. Consolidated back into a single string.
//   - Floating-point margin % and cost/100 columns (e.g. 78.15000000000001):
//     new csvRound:decimals: helper formats numeric fields to a fixed decimal
//     count before writing to CSV, preventing JS float artifacts from the
//     server appearing in the exported file.
//   - TTS model column showed raw voice IDs (e.g. nPczCjzI2devNBz1zQrb)
//     instead of a human-readable name. New csvEscapeModel:feature: helper
//     detects TTS voice IDs (16+ char alphanumeric, no hyphens, feature=tts)
//     and replaces them with "TTS Voice" in the export.
//
// v1.6 — CSV export crash fix
//   - csvEscape: parameter changed from NSString * to id. JSON null fields
//     deserialise to [NSNull null], which is truthy and passes through ?: @""
//     unchanged. Calling containsString: on NSNull crashes with "unrecognized
//     selector" (EXC_CRASH / SIGABRT). Method now guards NSNull and non-string
//     types explicitly and converts them to strings via -description.
//   - Fixed @"\\n" → @"\n" in the same method (newlines in CSV values were
//     not being detected and quoted correctly).
//   - generateCSVFromRows: numeric fields replaced ?: @"0" / ?: @"" with a
//     jsonNum block helper that guards both nil and NSNull, so null numeric
//     fields produce "0" or "" rather than "<null>" in the exported file.
//
// v1.5 — Credit row display
//   - EZAdminLedgerCell now handles direction = "credit" rows returned by the
//     updated ez_all_ledger_rows view: coins show as "+5 coins" in green
//     rather than "−5 coins" in orange; token/image/cost fields are suppressed
//     since they are NULL for credit rows and would otherwise show as zeroes.
//   - friendlyFeature: added daily_reward, topup, subscription_renewal,
//     adjustment so credit rows show readable names instead of raw keys.
//
// v1.4 — Export feature
//   - Export button (nav bar, left of Refresh) fetches the full filtered dataset
//     and presents a CSV or PDF via UIActivityViewController
//   - activeFilterQueryString: helper centralises filter param construction so
//     fetchPage: and the export fetch always use identical params
//   - Large-dataset warning (>2,000 rows) with option to cancel before exporting
//   - CSV: RFC-4180 compliant, all key columns, opens in Numbers/Excel
//   - PDF: HTML-rendered via UIMarkupTextPrintFormatter, landscape US Letter,
//     repeating header row across pages, colour-coded debit/credit/error rows
//
// v1.3 — Coins in circulation + search/filter
//   - Search/filter bar: "@" → email filter, else → feature name filter
//     (e.g. "tts", "chat", "image"). Debounced 0.4s, fires immediately on
//     Search key. Summary subtitle and empty-state label reflect active filter.
//   - Summary header now shows platform-wide coins in circulation plus a drift
//     warning if the coin_transactions ledger total disagrees with the sum of
//     live subscriptions.coins_balance values
//
// v1.2 — All-users admin view
//   - Endpoint changed from get-usage-log to get-admin-ledger (mode=user)
//   - Admin secret prompt added; secret stored in NSUserDefaults, never binary
//   - Added user_email and ip_address per row
//   - Summary header shows all-users aggregate instead of personal balance
//   - implied_margin_pct now read from server; client-side calc removed
//
// v1.1 — Initial admin port
//   - Whole file wrapped in #if DEBUG

#import "EZCoinLedgerViewController.h"
#import "EZAuthManager.h"

#if DEBUG

static NSString *const kAdminLedgerBase    = @"https://spuoimtqofhbdzosrbng.supabase.co";
static NSString *const kAdminLedgerPath    = @"/functions/v1/get-admin-ledger";
// NOTE: placeholder path — point this at whatever edge function actually
// performs manual coin grants server-side (must log a manual_grant row to
// coin_transactions and bump the user's balance). Adjust the payload keys
// in performGrantCoinsForUserId:email:amount:reason: to match it.
static NSString *const kGrantCoinsPath     = @"/functions/v1/grant-admin-coins";
static NSString *const kAdminSecretUDKey   = @"EZAdminSecret";   // NSUserDefaults key
static NSString *const kLedgerCellID       = @"EZAdminLedgerCell";

// Cost breakeven thresholds ($ per 100 coins) — matches edge function constants
static double const kBreakevenBest  = 0.80;  // Ultra tier
static double const kBreakevenWorst = 1.25;  // Basic tier

// ── Colors ────────────────────────────────────────────────────────────────────

static UIColor *EZGold(void)  { return [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0]; }
static UIColor *EZBg(void)    { return [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:1.0]; }
static UIColor *EZCard(void)  { return [UIColor colorWithRed:0.09 green:0.09 blue:0.14 alpha:1.0]; }
static UIColor *EZMuted(void) { return [UIColor colorWithWhite:0.45 alpha:1]; }
// Lighter than EZMuted — for the date/time and IP fields, which were
// previously near-illegible against the dark card background.
static UIColor *EZMutedLight(void) { return [UIColor colorWithWhite:0.70 alpha:1]; }

// ── Efficiency color ──────────────────────────────────────────────────────────

static UIColor *efficiencyColor(double costPer100) {
    if (costPer100 <= kBreakevenBest)  return [UIColor systemGreenColor];
    if (costPer100 <= kBreakevenWorst) return [UIColor systemOrangeColor];
    return [UIColor systemRedColor];
}

// ── Date formatter ────────────────────────────────────────────────────────────

static NSDateFormatter *sharedDisplayFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale     = [NSLocale currentLocale];
        // Ledger timestamps are stored by Supabase in UTC. Show them in the
        // product's Eastern time zone (EST in winter, EDT during daylight
        // saving time) instead of treating their UTC clock values as local.
        formatter.timeZone   = [NSTimeZone timeZoneWithName:@"America/New_York"];
        formatter.dateFormat = @"MMM d, h:mm a z";
    });
    return formatter;
}

// Supabase emits UTC timestamps such as "2026-09-19T22:32:00.000Z". Parsing
// only the first 19 characters without a time zone makes 22:32 look like local
// time; preserve the UTC meaning first, then let sharedDisplayFormatter convert
// it to Eastern time for the card.
static NSDate *dateFromLedgerISOString(NSString *isoDate) {
    if (isoDate.length == 0) return nil;

    static NSDateFormatter *withMilliseconds;
    static NSDateFormatter *withoutMilliseconds;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLocale *posixLocale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        withMilliseconds = [NSDateFormatter new];
        withMilliseconds.locale = posixLocale;
        withMilliseconds.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";
        withoutMilliseconds = [NSDateFormatter new];
        withoutMilliseconds.locale = posixLocale;
        withoutMilliseconds.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    });

    NSDate *date = [withMilliseconds dateFromString:isoDate]
        ?: [withoutMilliseconds dateFromString:isoDate];
    if (date || isoDate.length < 19) return date;

    // Defensive fallback for legacy rows with no explicit offset. Their
    // created_at values were still written in UTC by the backend.
    NSDateFormatter *legacyParser = [NSDateFormatter new];
    legacyParser.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    legacyParser.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    legacyParser.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
    return [legacyParser dateFromString:[isoDate substringToIndex:19]];
}

// ── Coin count formatter ──────────────────────────────────────────────────────
// Circulation totals run into 5+ digits quickly — grouping separators make
// them readable at a glance instead of a wall of digits.

static NSString *formattedCoinCount(NSInteger count) {
    static NSNumberFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSNumberFormatter new];
        formatter.numberStyle          = NSNumberFormatterDecimalStyle;
        formatter.usesGroupingSeparator = YES;
        formatter.groupingSeparator      = @",";
    });
    return [formatter stringFromNumber:@(count)] ?: [NSString stringWithFormat:@"%ld", (long)count];
}

// ── Admin ledger row cell ─────────────────────────────────────────────────────
// Shows all fields returned by get-admin-ledger mode=user, including user
// identity fields (email, IP) that are only available via the admin endpoint.

// Fired when the user double-taps the card's + button. userId/email describe
// the account the row belongs to, so the presenting VC can build a grant
// request without reaching back into the row dictionary itself.
typedef void (^EZGrantCoinsHandler)(NSString *userId, NSString *email);

@interface EZAdminLedgerCell : UITableViewCell
- (void)configureWithRow:(NSDictionary *)row;
+ (CGFloat)rowHeight;
+ (CGFloat)rowHeightForRow:(NSDictionary *)row;
@property (nonatomic, copy) EZGrantCoinsHandler grantCoinsHandler;
@end

@implementation EZAdminLedgerCell {
    UIView  *_card;
    UILabel *_featureLabel;
    UILabel *_modelLabel;
    UILabel *_userEmailLabel;   // user_email — admin-only field
    UILabel *_ipLabel;          // ip_address — admin-only field
    UILabel *_promptLabel;
    UILabel *_coinsLabel;
    UILabel *_balanceLabel;
    UILabel *_tokensLabel;
    UILabel *_imagesLabel;
    UILabel *_costLabel;
    UILabel *_effLabel;
    UILabel *_timeLabel;
    UIView  *_statusDot;
    UILabel *_statusLabel;      // "Completed" / "Pending" / "Error" text next to the dot
    UILabel *_errorLabel;       // error_message text, only populated when status = "error"
    UIView  *_grantButton;      // small "+" affordance, double-tap opens the grant-coins sheet
    UILabel *_grantButtonLabel;
    NSString *_contactEmail;
    NSString *_contactUserId;
    NSString *_contactFeature;
    NSString *_contactModel;
    NSString *_contactPrompt;
    NSString *_contactDateTime;
    NSString *_contactCoinChange;
    NSString *_contactBalanceAfter;
    NSString *_contactTokens;
    NSString *_contactCost;
    NSString *_contactStatus;
    NSString *_contactErrorMessage;
    BOOL _isPennySlotAudit;
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

    // Helper block — creates a label, adds it to the card, returns it
    UILabel* (^makeLabel)(CGFloat, UIFontWeight, UIColor *, NSInteger) =
    ^UILabel *(CGFloat size, UIFontWeight weight, UIColor *color, NSInteger lines) {
        UILabel *label       = [UILabel new];
        label.font           = [UIFont systemFontOfSize:size weight:weight];
        label.textColor      = color;
        label.numberOfLines  = (int)lines;
        [self->_card addSubview:label];
        return label;
    };

    _featureLabel   = makeLabel(13, UIFontWeightBold,    EZGold(),                              1);
    _modelLabel     = makeLabel(11, UIFontWeightRegular, EZMuted(),                             1);
    _userEmailLabel = makeLabel(13, UIFontWeightMedium,  [UIColor systemBlueColor],              1);
    _userEmailLabel.userInteractionEnabled = YES;

    // Single tap copies just the email address; double tap opens the mailto
    // compose sheet (existing behavior). The single-tap recognizer must wait
    // for the double-tap one to fail before firing, or every double tap would
    // also fire a spurious single-tap copy first.
    UITapGestureRecognizer *emailSingleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(copyEmailTapped:)];
    emailSingleTap.numberOfTapsRequired = 1;
    UITapGestureRecognizer *emailDoubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(contactUser:)];
    emailDoubleTap.numberOfTapsRequired = 2;
    [emailSingleTap requireGestureRecognizerToFail:emailDoubleTap];
    [_userEmailLabel addGestureRecognizer:emailSingleTap];
    [_userEmailLabel addGestureRecognizer:emailDoubleTap];

    _ipLabel        = makeLabel(12, UIFontWeightRegular, EZMutedLight(),                        1);
    // Slot audits intentionally use one row per reel. Allow enough room for
    // the complete outcome rather than truncating it into a two-line snippet.
    _promptLabel    = makeLabel(12, UIFontWeightRegular, [UIColor colorWithWhite:0.80 alpha:1], 12);
    _promptLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _promptLabel.userInteractionEnabled = YES;
    // Tap the prompt to copy just its text, separate from the long-press
    // "copy everything" gesture on the card as a whole.
    [_promptLabel addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(copyPromptTapped:)]];
    _coinsLabel     = makeLabel(14, UIFontWeightBold,    [UIColor systemOrangeColor],           1);
    _balanceLabel   = makeLabel(16, UIFontWeightSemibold, [UIColor whiteColor],                  1);
    _tokensLabel    = makeLabel(11, UIFontWeightRegular, [UIColor colorWithWhite:0.60 alpha:1], 1);
    _imagesLabel    = makeLabel(11, UIFontWeightRegular, [UIColor colorWithWhite:0.60 alpha:1], 1);
    // Keep the per-call API cost prominent: it is the bottom-left value in
    // each ledger card and needs to remain readable at a glance.
    _costLabel      = makeLabel(16, UIFontWeightSemibold, [UIColor whiteColor],                  1);
    _effLabel       = makeLabel(14, UIFontWeightSemibold,[UIColor systemGreenColor],            1);
    _timeLabel      = makeLabel(13, UIFontWeightMedium,  [UIColor colorWithWhite:0.88 alpha:1], 1);
    _timeLabel.textAlignment = NSTextAlignmentRight;

    _coinsLabel.textAlignment   = NSTextAlignmentRight;
    _balanceLabel.textAlignment = NSTextAlignmentRight;

    _statusDot = [UIView new];
    _statusDot.layer.cornerRadius = 4;
    [_card addSubview:_statusDot];

    _statusLabel = makeLabel(10, UIFontWeightBold, EZMuted(), 1);

    _errorLabel = makeLabel(11, UIFontWeightMedium, [UIColor systemRedColor], 2);
    _errorLabel.hidden = YES;

    // Long-press anywhere on the card copies a plain-text summary of the
    // transaction to the pasteboard.
    _card.userInteractionEnabled = YES;
    [_card addGestureRecognizer:[[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(copyCardTapped:)]];

    // "+" affordance — vertically centered on the right edge of the card.
    // Double-tap (not single-tap) opens the grant-coins sheet, since this
    // moves real value onto an account and shouldn't fire on a stray touch.
    _grantButton = [UIView new];
    _grantButton.backgroundColor    = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.16];
    _grantButton.layer.borderWidth  = 1;
    _grantButton.layer.borderColor  = [EZGold() colorWithAlphaComponent:0.55].CGColor;
    _grantButton.userInteractionEnabled = YES;
    [_card addSubview:_grantButton];

    _grantButtonLabel = [UILabel new];
    _grantButtonLabel.text = @"+";
    _grantButtonLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    _grantButtonLabel.textColor = EZGold();
    _grantButtonLabel.textAlignment = NSTextAlignmentCenter;
    _grantButtonLabel.userInteractionEnabled = NO;
    [_grantButton addSubview:_grantButtonLabel];

    UITapGestureRecognizer *grantDoubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(grantButtonTapped:)];
    grantDoubleTap.numberOfTapsRequired = 2;
    [_grantButton addGestureRecognizer:grantDoubleTap];

    return self;
}

- (void)configureWithRow:(NSDictionary *)row {
    // Safe value extractor — handles NSNull and non-string types from JSON
    NSString *(^safeString)(id) = ^NSString *(id value) {
        if (!value || value == (id)[NSNull null]) return @"";
        if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
        if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
        return @"";
    };

    // Feature + model
    NSString *featureKey = safeString(row[@"feature"]);
    _isPennySlotAudit = [featureKey isEqualToString:@"brainrot_penny_slots"];
    _featureLabel.text   = [self friendlyFeature:featureKey.length ? featureKey : @"unknown"];
    _modelLabel.text     = safeString(row[@"model"]);
    _contactModel        = _modelLabel.text;

    // User identity (admin-only fields)
    NSString *email = safeString(row[@"user_email"]);
    NSString *ip    = safeString(row[@"ip_address"]);
    _contactEmail = email;
    _contactUserId = safeString(row[@"user_id"]);
    _contactFeature = _featureLabel.text;
    BOOL hasContactEmail = [email containsString:@"@"] && ![email containsString:@" "];
    _userEmailLabel.text = email.length ? email : safeString(row[@"user_id"]);
    _userEmailLabel.alpha = hasContactEmail ? 1.0 : 0.55;
    _ipLabel.text        = ip.length   ? [NSString stringWithFormat:@"IP: %@", ip] : @"";

    // Prompt
    NSString *prompt  = safeString(row[@"prompt"]);
    _promptLabel.text = prompt.length ? prompt : @"(no prompt recorded)";
    _promptLabel.textColor = prompt.length
        ? [UIColor colorWithWhite:0.78 alpha:1] : EZMuted();
    _contactPrompt = prompt;

    // Coins + running balance
    // direction = "credit" for daily claims, top-ups, subscription renewals,
    // and adjustments; "debit" for feature usage. Credits show green with a +,
    // debits show orange with a −. Missing direction defaults to debit so
    // existing rows display correctly before the new view is deployed.
    NSString  *direction     = safeString(row[@"direction"]);
    BOOL       isCredit      = [direction isEqualToString:@"credit"];
    NSInteger  coinsCharged  = [row[@"coins_charged"]   integerValue];
    NSInteger  runningBalance = [row[@"running_balance"] integerValue];
    NSInteger  quantity      = [row[@"quantity"]         integerValue];

    if (isCredit) {
        _coinsLabel.text      = [NSString stringWithFormat:@"+%ld coins", (long)coinsCharged];
        _coinsLabel.textColor = [UIColor systemGreenColor];
    } else {
        _coinsLabel.text = quantity > 1
            ? [NSString stringWithFormat:@"−%ld coins ×%ld", (long)coinsCharged, (long)quantity]
            : [NSString stringWithFormat:@"−%ld coins", (long)coinsCharged];
        _coinsLabel.textColor = [UIColor systemOrangeColor];
    }
    _balanceLabel.text = [NSString stringWithFormat:@"Balance after: %ld", (long)runningBalance];
    _contactCoinChange = _coinsLabel.text;
    _contactBalanceAfter = [NSString stringWithFormat:@"%ld coins", (long)runningBalance];

    // Token counts, image counts, API cost, and efficiency are meaningless for
    // credit rows (no model was called). Suppress them so the card doesn't
    // show "In: 0 / Out: 0 tokens" and "API cost: $0.0000" for a daily claim.
    if (isCredit) {
        _tokensLabel.text  = @"";
        _imagesLabel.text  = @"";
        _costLabel.text    = @"";
        _effLabel.text     = @"";
        _contactTokens     = @"";
        _contactCost       = @"";
    } else {
        // Token counts
        id inputTokens  = row[@"input_tokens"];
        id outputTokens = row[@"output_tokens"];
        if (inputTokens && ![inputTokens isKindOfClass:[NSNull class]]) {
            _tokensLabel.text = [NSString stringWithFormat:@"In: %@ / Out: %@ tokens",
                                 inputTokens, outputTokens ?: @"0"];
        } else {
            _tokensLabel.text = @"";
        }
        _contactTokens = _tokensLabel.text;

        // Image counts
        id imagesReturned  = row[@"images_returned"];
        id imagesRequested = row[@"images_requested"];
        if (imagesReturned && ![imagesReturned isKindOfClass:[NSNull class]]) {
            _imagesLabel.text = [NSString stringWithFormat:@"Images: %@ returned / %@ requested",
                                 imagesReturned, imagesRequested ?: @"?"];
        } else {
            _imagesLabel.text = @"";
        }

        // API cost
        id apiCostValue = row[@"api_cost_usd"];
        if (apiCostValue && ![apiCostValue isKindOfClass:[NSNull class]]) {
            _costLabel.text = [NSString stringWithFormat:@"API cost: $%.4f", [apiCostValue doubleValue]];
        } else {
            _costLabel.text = @"";
        }
        _contactCost = _costLabel.text;

        // Cost per 100 coins efficiency
        id effValue = row[@"cost_per_100_coins"];
        if (effValue && ![effValue isKindOfClass:[NSNull class]]) {
            double eff          = [effValue doubleValue];
            _effLabel.text      = [NSString stringWithFormat:@"$%.4f / 100 coins", eff];
            _effLabel.textColor = efficiencyColor(eff);
        } else {
            _effLabel.text      = @"—";
            _effLabel.textColor = EZMuted();
        }
    }

    // Timestamp
    NSString *isoDate = safeString(row[@"created_at"]);
    NSDate *parsedDate = dateFromLedgerISOString(isoDate);
    _timeLabel.text = parsedDate ? [sharedDisplayFormatter() stringFromDate:parsedDate] : isoDate;
    _contactDateTime = _timeLabel.text.length ? _timeLabel.text : @"Not recorded";

    // Status dot + label
    NSString *status = safeString(row[@"status"]);
    if (!status.length) status = @"complete";
    _contactStatus = status.capitalizedString;
    if ([status isEqualToString:@"pending"]) {
        _statusDot.backgroundColor  = [UIColor systemYellowColor];
        _statusLabel.text           = @"PENDING";
        _statusLabel.textColor      = [UIColor systemYellowColor];
    } else if ([status isEqualToString:@"error"]) {
        _statusDot.backgroundColor  = [UIColor systemRedColor];
        _statusLabel.text           = @"ERROR";
        _statusLabel.textColor      = [UIColor systemRedColor];
    } else {
        _statusDot.backgroundColor  = [UIColor systemGreenColor];
        _statusLabel.text           = @"COMPLETED";
        _statusLabel.textColor      = [UIColor systemGreenColor];
    }

    // Error message — the get-admin-ledger edge function returns this as
    // error_text (confirmed from index.ts's ez_all_ledger_rows select list).
    if ([status isEqualToString:@"error"]) {
        NSString *errorMessage = safeString(row[@"error_text"]);
        _contactErrorMessage = errorMessage.length ? errorMessage : @"No error message recorded";
        _errorLabel.text = [NSString stringWithFormat:@"⚠️ %@", _contactErrorMessage];
        _errorLabel.hidden = NO;
    } else {
        _contactErrorMessage = @"";
        _errorLabel.text = @"";
        _errorLabel.hidden = YES;
    }

    [self setNeedsLayout];
}

// Long-press anywhere on the card copies a plain-text summary of the
// transaction to the pasteboard. Gives a quick flash + haptic as feedback
// since there's no toast/snackbar system in this view.
- (void)copyCardTapped:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    NSMutableString *summary = [NSMutableString new];
    [summary appendFormat:@"%@\n", _contactFeature.length ? _contactFeature : @"Transaction"];
    if (_contactModel.length)        [summary appendFormat:@"Model: %@\n", _contactModel];
    if (_contactEmail.length)        [summary appendFormat:@"User: %@\n", _contactEmail];
    [summary appendFormat:@"Status: %@\n", _contactStatus.length ? _contactStatus : @"Unknown"];
    if (_contactErrorMessage.length) [summary appendFormat:@"Error: %@\n", _contactErrorMessage];
    [summary appendFormat:@"Date: %@\n", _contactDateTime.length ? _contactDateTime : @"Not recorded"];
    if (_contactCoinChange.length)   [summary appendFormat:@"Coins: %@\n", _contactCoinChange];
    if (_contactBalanceAfter.length) [summary appendFormat:@"Balance after: %@\n", _contactBalanceAfter];
    if (_contactTokens.length)       [summary appendFormat:@"%@\n", _contactTokens];
    if (_contactCost.length)         [summary appendFormat:@"%@\n", _contactCost];
    if (_contactPrompt.length)       [summary appendFormat:@"Prompt: %@\n", _contactPrompt];

    [UIPasteboard generalPasteboard].string = summary;

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];

    UIColor *originalColor = _card.backgroundColor;
    [UIView animateWithDuration:0.12 animations:^{
        self->_card.backgroundColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.25];
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.25 animations:^{
            self->_card.backgroundColor = originalColor;
        }];
    }];
}

// Brief highlight flash on an arbitrary view — shared feedback for the
// smaller, single-field copy actions (email alone, prompt alone), distinct
// from the full-card flash used by the long-press "copy everything" gesture.
- (void)flashFeedbackView:(UIView *)view {
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    UIColor *originalColor = view.backgroundColor;
    [UIView animateWithDuration:0.10 animations:^{
        view.backgroundColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.30];
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.22 animations:^{
            view.backgroundColor = originalColor;
        }];
    }];
}

// Single tap on the email label — copies just the email address, as opposed
// to the double-tap gesture on the same label which opens the mail compose
// sheet, and the long-press-anywhere gesture which copies the whole card.
- (void)copyEmailTapped:(UITapGestureRecognizer *)gesture {
    if (_contactEmail.length == 0) return;
    [UIPasteboard generalPasteboard].string = _contactEmail;
    [self flashFeedbackView:_userEmailLabel];
}

// Single tap on the prompt label — copies just the prompt text.
- (void)copyPromptTapped:(UITapGestureRecognizer *)gesture {
    if (_contactPrompt.length == 0) return;
    [UIPasteboard generalPasteboard].string = _contactPrompt;
    [self flashFeedbackView:_promptLabel];
}

// Double tap on the "+" — hands off to the presenting view controller via
// grantCoinsHandler, since the cell has no access to the admin secret / JWT
// needed to actually perform the grant.
- (void)grantButtonTapped:(UITapGestureRecognizer *)gesture {
    if (!self.grantCoinsHandler) return;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
    self.grantCoinsHandler(_contactUserId, _contactEmail);
}

// Tapping an email address opens the user's chosen mail app with a concise,
// contextual follow-up ready to send. Prompt contents stay out of the draft
// because ledger prompts can contain sensitive user-provided information.
- (void)contactUser:(UITapGestureRecognizer *)gesture {
    if (_contactEmail.length == 0 || ![_contactEmail containsString:@"@"]) return;

    NSString *feature = _contactFeature.length ? _contactFeature : @"recent";
    NSString *subject = [NSString stringWithFormat:@"EZCompleteUI — about your %@ request", feature];
    NSString *body = [NSString stringWithFormat:
                      @"Hi,\n\nI'm following up about your %@ request in EZCompleteUI.\n\n"
                      @"Transaction details:\n"
                      @"• Date and time: %@\n"
                      @"• Status: %@\n"
                      @"• Coins charged/credited: %@\n"
                      @"• Balance after this transaction: %@\n\n"
                      @"The balance shown is the ledger balance after this transaction's credits and deductions were applied.\n\n"
                      @"Best,",
                      feature,
                      _contactDateTime.length ? _contactDateTime : @"Not recorded",
                      _contactStatus.length ? _contactStatus : @"Unknown",
                      _contactCoinChange.length ? _contactCoinChange : @"Not recorded",
                      _contactBalanceAfter.length ? _contactBalanceAfter : @"Not recorded"];
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"mailto";
    components.path = _contactEmail;
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"subject" value:subject],
        [NSURLQueryItem queryItemWithName:@"body" value:body],
    ];
    NSURL *url = components.URL;
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (NSString *)friendlyFeature:(NSString *)featureKey {
    NSDictionary *featureNames = @{
        // Credit events
        @"daily_reward":          @"🎁 Daily Reward",
        @"topup":                 @"💰 Coin Top-up",
        @"subscription_renewal":  @"⭐️ Subscription",
        @"manual_grant":          @"🎁 Manual Grant",
        @"manual_reversal":       @"↩️ Manual Grant Reversal",
        @"promo":                 @"🎁 Promo",
        @"adjustment":            @"🔧 Adjustment",
        // Feature spend
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
        @"brainrot_penny_slots": @"🎰 EZCoin Penny Slots",
    };
    return featureNames[featureKey] ?: featureKey;
}


- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat cellWidth  = self.contentView.bounds.size.width;
    CGFloat cellHeight = self.contentView.bounds.size.height;
    CGFloat padding    = 12;
    _card.frame = CGRectMake(12, 6, cellWidth - 24, cellHeight - 12);

    CGFloat cardWidth = _card.bounds.size.width;
    CGFloat x = padding, y = padding;

    // Status dot — top-right corner
    _statusDot.frame = CGRectMake(cardWidth - padding - 8, padding, 8, 8);

    // Row 1: feature (left) + Eastern timestamp (right). Give the now-larger,
    // brighter time label room for its EST/EDT suffix.
    _featureLabel.frame = CGRectMake(x, y, cardWidth - 164, 18);
    _timeLabel.frame    = CGRectMake(cardWidth - 158, y, 146, 18);
    y += 22;

    // Row 2: model (left) + user email (right)
    _modelLabel.frame     = CGRectMake(x, y, cardWidth * 0.45, 14);
    _userEmailLabel.frame = CGRectMake(cardWidth - 190, y, 178, 18);
    y += 16;

    // Row 3: status text (left, unused space next to the right-aligned IP
    // label) + IP address (right-aligned). Same size/color bump as the
    // timestamp above.
    _statusLabel.frame = CGRectMake(x, y, cardWidth - 210, 13);
    _ipLabel.frame      = CGRectMake(cardWidth - 190, y, 178, 16);
    y += 18;

    // Prompt / audit outcome (up to six explicit lines)
    CGFloat promptHeight = _isPennySlotAudit ? 174 : 90;
    _promptLabel.frame = CGRectMake(x, y, cardWidth - x * 2, promptHeight);
    y += promptHeight + 4;

    // "+" grant-coins button — vertically centered on the whole card, right
    // edge. Sized/positioned first so the detail rows below can be kept clear
    // of it.
    CGFloat grantSize = 32;
    CGFloat grantX    = cardWidth - padding - grantSize;
    CGFloat grantY    = (_card.bounds.size.height - grantSize) / 2.0;
    _grantButton.frame = CGRectMake(grantX, grantY, grantSize, grantSize);
    _grantButton.layer.cornerRadius = grantSize / 2.0;
    _grantButtonLabel.frame = _grantButton.bounds;

    // Detail rows stay above the financial summary at the bottom of the card,
    // and are narrowed to leave the grant button clear on the right.
    CGFloat detailWidth = grantX - 8 - x;
    _tokensLabel.frame  = CGRectMake(x, y, detailWidth, 14);
    y += 17;
    _imagesLabel.frame  = CGRectMake(x, y, detailWidth, 14);
    y += 16;

    // Error message — only populated/visible for status = "error". Sits in
    // the gap between the detail rows and the bottom financial summary.
    _errorLabel.frame = CGRectMake(x, y, cardWidth - x * 2, 30);

    // Bottom two-column financial summary:
    // left = cost efficiency over API cost; right = coin change over balance.
    CGFloat rightColumnWidth = MIN(178, cardWidth * 0.50);
    CGFloat rightColumnX     = cardWidth - padding - rightColumnWidth;
    CGFloat leftColumnWidth  = rightColumnX - x - 8;
    CGFloat bottomRowY       = _card.bounds.size.height - padding - 20;
    CGFloat topRowY          = bottomRowY - 22;

    _effLabel.frame     = CGRectMake(x, topRowY, leftColumnWidth, 20);
    _costLabel.frame    = CGRectMake(x, bottomRowY, leftColumnWidth, 20);
    _coinsLabel.frame   = CGRectMake(rightColumnX, topRowY, rightColumnWidth, 20);
    _balanceLabel.frame = CGRectMake(rightColumnX, bottomRowY, rightColumnWidth, 20);
}

+ (CGFloat)rowHeight { return 290; }
+ (CGFloat)rowHeightForRow:(NSDictionary *)row { return [row[@"feature"] isEqual:@"brainrot_penny_slots"] ? 374 : [self rowHeight]; }

@end

// ── Admin summary header view ─────────────────────────────────────────────────
// Shows aggregate stats across all users for the current filter/page set.
// Data comes from the aggregate block in get-admin-ledger mode=user response.

@interface EZAdminSummaryView : UIView
- (void)configureWithAggregate:(NSDictionary *)aggregate;
// Updates the subtitle line to show an active filter description.
// Pass nil to restore the default "N transactions loaded" text.
- (void)setFilterDescription:(nullable NSString *)filterDescription;
@end

@implementation EZAdminSummaryView {
    UILabel *_headlineLabel;      // "🌐 All Users"
    UILabel *_subtitleLabel;      // row count, or active filter description
    UILabel *_globalEffLabel;     // cost/100 coins
    UILabel *_marginLabel;        // implied margin %
    UILabel *_circulationLabel;   // platform-wide coins in circulation (global, unfiltered)
    UILabel *_driftLabel;         // ledger-vs-balances drift warning; hidden when zero
    UILabel *_totalCoinsLabel;
    UILabel *_totalCostLabel;
    UILabel *_totalCallsLabel;
    UILabel *_totalImagesLabel;
    UILabel *_totalTokensLabel;
    NSInteger _lastTotalCalls;    // preserved so setFilterDescription:nil can restore the default subtitle
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.backgroundColor = EZBg();

    UILabel* (^makeLabel)(CGFloat, UIFontWeight, UIColor *, NSTextAlignment) =
    ^UILabel *(CGFloat size, UIFontWeight weight, UIColor *color, NSTextAlignment alignment) {
        UILabel *label       = [UILabel new];
        label.font           = [UIFont systemFontOfSize:size weight:weight];
        label.textColor      = color;
        label.textAlignment  = alignment;
        label.numberOfLines  = 2;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor        = 0.7;
        [self addSubview:label];
        return label;
    };

    _headlineLabel   = makeLabel(26, UIFontWeightBold,    EZGold(),                              NSTextAlignmentCenter);
    _subtitleLabel   = makeLabel(12, UIFontWeightRegular, EZMuted(),                             NSTextAlignmentCenter);
    _globalEffLabel  = makeLabel(20, UIFontWeightBold,    [UIColor systemGreenColor],            NSTextAlignmentCenter);
    _marginLabel     = makeLabel(12, UIFontWeightRegular, [UIColor colorWithWhite:0.6 alpha:1],  NSTextAlignmentCenter);
    _circulationLabel= makeLabel(17, UIFontWeightSemibold,[UIColor whiteColor],                  NSTextAlignmentCenter);
    _driftLabel      = makeLabel(11, UIFontWeightRegular, [UIColor systemRedColor],              NSTextAlignmentCenter);
    _totalCoinsLabel = makeLabel(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalCostLabel  = makeLabel(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalCallsLabel = makeLabel(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalImagesLabel= makeLabel(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);
    _totalTokensLabel= makeLabel(12, UIFontWeightMedium,  [UIColor colorWithWhite:0.75 alpha:1], NSTextAlignmentCenter);

    _driftLabel.hidden = YES;   // shown only when ledger and live balances disagree

    // Gold divider line (above the per-call stats)
    UIView *divider = [UIView new];
    divider.backgroundColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.25];
    divider.tag = 99;
    [self addSubview:divider];

    // Second divider, between margin and the circulation total
    UIView *circulationDivider = [UIView new];
    circulationDivider.backgroundColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.15];
    circulationDivider.tag = 100;
    [self addSubview:circulationDivider];

    return self;
}

- (void)configureWithAggregate:(NSDictionary *)aggregate {
    _headlineLabel.text = @"🌐 All Users";

    // get-admin-ledger mode=user uses different aggregate keys than get-usage-log:
    //   total_coins  (not total_coins_charged)
    //   total_input_tokens + total_output_tokens  (not total_tokens)
    //   implied_margin_pct  (computed server-side, not client-side)
    NSInteger totalCalls    = [aggregate[@"total_calls"]          integerValue];
    NSInteger totalCoins    = [aggregate[@"total_coins"]          integerValue];
    double    totalCostUsd  = [aggregate[@"total_api_cost_usd"]   doubleValue];
    NSInteger totalImages   = [aggregate[@"total_images"]         integerValue];
    NSInteger inputTokens   = [aggregate[@"total_input_tokens"]   integerValue];
    NSInteger outputTokens  = [aggregate[@"total_output_tokens"]  integerValue];
    NSInteger totalTokens   = inputTokens + outputTokens;

    _subtitleLabel.text = [NSString stringWithFormat:@"%ld transactions loaded", (long)totalCalls];
    _lastTotalCalls     = totalCalls;

    // Efficiency and margin — prefer server-computed values from the response
    id costPer100Value  = aggregate[@"cost_per_100_coins"];
    id marginPctValue   = aggregate[@"implied_margin_pct"];

    if (costPer100Value && ![costPer100Value isKindOfClass:[NSNull class]]) {
        double costPer100          = [costPer100Value doubleValue];
        _globalEffLabel.text       = [NSString stringWithFormat:@"$%.4f / 100 coins", costPer100];
        _globalEffLabel.textColor  = efficiencyColor(costPer100);

        double marginPct = (marginPctValue && ![marginPctValue isKindOfClass:[NSNull class]])
            ? [marginPctValue doubleValue]
            : (totalCoins > 0 ? (totalCoins * 0.0100 - totalCostUsd) / (totalCoins * 0.0100) * 100 : 0);

        _marginLabel.text      = [NSString stringWithFormat:
            @"Implied margin: %.1f%%   |   Breakeven: $%.2f–$%.2f",
            marginPct, kBreakevenBest, kBreakevenWorst];
        _marginLabel.textColor = marginPct >= 0
            ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    } else {
        _globalEffLabel.text = @"No cost data yet";
        _marginLabel.text    = @"";
    }

    _totalCoinsLabel.text  = [NSString stringWithFormat:@"Coins used\n%ld",  (long)totalCoins];
    _totalCostLabel.text   = [NSString stringWithFormat:@"API cost\n$%.4f",  totalCostUsd];
    _totalCallsLabel.text  = [NSString stringWithFormat:@"Calls\n%ld",       (long)totalCalls];
    _totalImagesLabel.text = [NSString stringWithFormat:@"Images\n%ld",      (long)totalImages];
    _totalTokensLabel.text = [NSString stringWithFormat:@"Tokens\n%ld",      (long)totalTokens];

    // Platform-wide circulation — global and unfiltered, unlike everything
    // above. See get-admin-ledger's comment on the global_* aggregate keys.
    NSInteger globalCirculating = [aggregate[@"global_total_circulating"] integerValue];
    NSInteger globalBalances    = [aggregate[@"global_total_balances"]    integerValue];
    NSInteger drift              = [aggregate[@"global_circulation_drift"] integerValue];

    _circulationLabel.text = [NSString stringWithFormat:@"🪙 %@ coins in circulation",
                               formattedCoinCount(globalCirculating)];

    if (drift != 0) {
        // Ledger total (credits − debits) disagrees with the actual sum of
        // every live balance. Either a coin-mutating path changed a balance
        // without logging a matching coin_transactions row, or something
        // outside the edge functions touched a balance directly — exactly
        // the kind of thing this metric exists to catch.
        _driftLabel.hidden = NO;
        _driftLabel.text   = [NSString stringWithFormat:
            @"⚠️ Drift: %@%@ coins — live balances total %@",
            drift > 0 ? @"+" : @"−", formattedCoinCount(ABS(drift)), formattedCoinCount(globalBalances)];
    } else {
        _driftLabel.hidden = YES;
        _driftLabel.text   = @"";
    }
}

// Updates the subtitle to show which filter is currently active.
// Pass nil to restore the default "N transactions loaded" text.
- (void)setFilterDescription:(NSString *)filterDescription {
    if (filterDescription.length > 0) {
        _subtitleLabel.text = [NSString stringWithFormat:@"Filter: %@", filterDescription];
    } else {
        _subtitleLabel.text = [NSString stringWithFormat:@"%ld transactions loaded", (long)_lastTotalCalls];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat viewWidth = self.bounds.size.width;
    CGFloat padding   = 16;

    _headlineLabel.frame  = CGRectMake(0, 14, viewWidth, 34);
    _subtitleLabel.frame  = CGRectMake(0, 50, viewWidth, 18);

    UIView *divider = [self viewWithTag:99];
    divider.frame = CGRectMake(padding * 2, 74, viewWidth - padding * 4, 0.5);

    _globalEffLabel.frame = CGRectMake(0, 82, viewWidth, 28);
    _marginLabel.frame    = CGRectMake(padding, 112, viewWidth - padding * 2, 30);

    UIView *circulationDivider = [self viewWithTag:100];
    circulationDivider.frame = CGRectMake(padding * 2, 144, viewWidth - padding * 4, 0.5);

    _circulationLabel.frame = CGRectMake(0, 150, viewWidth, 22);
    _driftLabel.frame       = CGRectMake(padding, 172, viewWidth - padding * 2, 14);

    CGFloat columnWidth = viewWidth / 5;
    NSArray *statLabels = @[_totalCoinsLabel, _totalCostLabel, _totalCallsLabel,
                            _totalImagesLabel, _totalTokensLabel];
    for (NSInteger i = 0; i < (NSInteger)statLabels.count; i++) {
        ((UILabel *)statLabels[(NSUInteger)i]).frame =
            CGRectMake(columnWidth * i, 190, columnWidth, 36);
    }
}

+ (CGFloat)height { return 234; }

@end

// ── Main VC ───────────────────────────────────────────────────────────────────

@interface EZCoinLedgerViewController () <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@property (nonatomic, strong) UITableView            *tableView;
@property (nonatomic, strong) UISearchBar            *searchBar;
@property (nonatomic, strong) EZAdminSummaryView     *summaryView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredRows;   // self.rows after activeStatusFilter is applied
@property (nonatomic, strong) NSString               *activeStatusFilter; // nil/"all", "completed", "pending", "error"
@property (nonatomic, strong) NSDictionary           *aggregate;
@property (nonatomic, assign) BOOL                    loading;
@property (nonatomic, assign) BOOL                    hasMore;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel                *emptyLabel;
@property (nonatomic, strong) NSString               *adminSecret;   // from NSUserDefaults
@property (nonatomic, strong) NSString               *activeSearchQuery;  // nil = no filter
@property (nonatomic, strong) NSTimer                *searchDebounceTimer;
@property (nonatomic, strong) UIBarButtonItem        *exportButton;
@property (nonatomic, strong) UIBarButtonItem        *excludeButton;
@property (nonatomic, assign) BOOL                    excludesFeature;
@end

@implementation EZCoinLedgerViewController

static NSInteger const kPageSize = 50;

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"🌐 Admin Ledger";
    self.view.backgroundColor = EZBg();
    self.rows    = [NSMutableArray array];
    self.hasMore = YES;
    self.loading = NO;

    // Load stored admin secret — never prompts on its own; fetchPage triggers the prompt
    self.adminSecret = [[NSUserDefaults standardUserDefaults] stringForKey:kAdminSecretUDKey];

    [self styleNav];
    [self setupTable];
    [self fetchPage:0];
}

- (void)styleNav {
    UINavigationBarAppearance *navAppearance = [UINavigationBarAppearance new];
    [navAppearance configureWithOpaqueBackground];
    navAppearance.backgroundColor       = EZBg();
    navAppearance.titleTextAttributes   = @{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName:            [UIFont boldSystemFontOfSize:17],
    };
    self.navigationController.navigationBar.standardAppearance   = navAppearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = navAppearance;
    self.navigationController.navigationBar.tintColor            = EZGold();

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeTapped)];
    self.navigationItem.leftBarButtonItem.tintColor = [UIColor colorWithWhite:0.6 alpha:1];

    self.exportButton = [[UIBarButtonItem alloc]
        initWithTitle:@"Export"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(exportButtonTapped)];
    self.exportButton.tintColor = EZGold();

    self.excludeButton = [[UIBarButtonItem alloc]
        initWithTitle:@"Exclude"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(excludeButtonTapped)];
    [self updateExcludeButtonAppearance];

    UIBarButtonItem *refreshButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(refreshTapped)];

    // These controls exist only in the DEBUG/admin controller.
    self.navigationItem.rightBarButtonItems = @[self.exportButton, self.excludeButton, refreshButton];
}

- (void)setupTable {
    // ── Search bar ────────────────────────────────────────────────────────────
    // Floats at the top of the view, above the table. Does not scroll away.
    // Typing an @-sign triggers an email filter; anything else filters by
    // feature name (case-insensitive substring, e.g. "tts", "chat", "image").
    // Fetches are debounced 0.4s after the last keystroke to avoid hammering
    // the server on every character. Clearing the field instantly resets.
    self.searchBar                    = [UISearchBar new];
    self.searchBar.placeholder        = @"email or feature (tts, chat, image…)";
    self.searchBar.searchBarStyle     = UISearchBarStyleMinimal;
    self.searchBar.barStyle           = UIBarStyleBlack;
    self.searchBar.tintColor          = EZGold();
    self.searchBar.returnKeyType      = UIReturnKeySearch;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate           = self;

    // Status filter — uses the search bar's built-in scope bar rather than a
    // separate control. Filters client-side over whatever rows are already
    // loaded (see activeStatusFilter / refreshFilteredRows).
    self.searchBar.scopeButtonTitles = @[@"All", @"Completed", @"Pending", @"Error"];
    self.searchBar.showsScopeBar     = YES;
    self.searchBar.selectedScopeButtonIndex = 0;

    [self.view addSubview:self.searchBar];

    // ── Summary view (scrolls as tableHeaderView) ─────────────────────────────
    self.summaryView = [EZAdminSummaryView new];
    self.summaryView.frame = CGRectMake(0, 0,
        self.view.bounds.size.width, [EZAdminSummaryView height]);

    // ── Table view ────────────────────────────────────────────────────────────
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                                  style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor     = EZBg();
    self.tableView.separatorStyle      = UITableViewCellSeparatorStyleNone;
    self.tableView.tableHeaderView     = self.summaryView;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.delegate            = self;
    self.tableView.dataSource          = self;
    self.tableView.rowHeight           = [EZAdminLedgerCell rowHeight];
    [self.tableView registerClass:[EZAdminLedgerCell class]
           forCellReuseIdentifier:kLedgerCellID];
    [self.view addSubview:self.tableView];

    // ── Layout — search bar pinned to safe area top, table fills the rest ─────
    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor      constraintEqualToAnchor:safeArea.topAnchor],
        [self.searchBar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.tableView.topAnchor      constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.tableView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // ── Spinner ───────────────────────────────────────────────────────────────
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color            = EZGold();
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center           = self.view.center;
    [self.view addSubview:self.spinner];

    // ── Empty state label ─────────────────────────────────────────────────────
    self.emptyLabel               = [UILabel new];
    self.emptyLabel.text          = @"No transactions found.";
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

// ── Admin secret prompt ───────────────────────────────────────────────────────
// The ADMIN_SECRET is never hardcoded. It is entered once here, stored in
// NSUserDefaults, and reused on every subsequent fetch. A 403 from the server
// clears the stored value and re-triggers this prompt.

- (void)promptForAdminSecretThenFetchPage:(NSInteger)offset {
    UIAlertController *secretAlert = [UIAlertController
        alertControllerWithTitle:@"Admin Secret Required"
                         message:@"Enter the ADMIN_SECRET value from your Supabase edge function environment."
                  preferredStyle:UIAlertControllerStyleAlert];

    [secretAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder    = @"ADMIN_SECRET";
        textField.secureTextEntry = YES;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    [secretAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                    style:UIAlertActionStyleCancel
                                                  handler:nil]];

    [secretAlert addAction:[UIAlertAction actionWithTitle:@"Continue"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *action) {
        NSString *enteredSecret = secretAlert.textFields.firstObject.text;
        if (!enteredSecret.length) return;

        self.adminSecret = enteredSecret;
        [[NSUserDefaults standardUserDefaults] setObject:enteredSecret
                                                  forKey:kAdminSecretUDKey];
        [self fetchPage:offset];
    }]];

    [self presentViewController:secretAlert animated:YES completion:nil];
}

// ── Fetch ─────────────────────────────────────────────────────────────────────

- (void)fetchPage:(NSInteger)offset {
    if (self.loading) return;

    // Prompt for admin secret if not yet stored
    if (!self.adminSecret.length) {
        [self promptForAdminSecretThenFetchPage:offset];
        return;
    }

    self.loading = YES;
    if (offset == 0) [self.spinner startAnimating];

    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) {
        [self.spinner stopAnimating];
        self.loading = NO;
        return;
    }

    NSString *urlString = [NSString stringWithFormat:
        @"%@%@?mode=user&limit=%ld&offset=%ld",
        kAdminLedgerBase, kAdminLedgerPath, (long)kPageSize, (long)offset];
    urlString = [urlString stringByAppendingString:[self activeFilterQueryString]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:urlString]];
    request.timeoutInterval = 20;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
   forHTTPHeaderField:@"Authorization"];
    [request setValue:self.adminSecret
   forHTTPHeaderField:@"x-admin-secret"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.loading = NO;

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

            // Wrong secret — clear stored value and prompt again
            if (httpResponse.statusCode == 403) {
                self.adminSecret = nil;
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAdminSecretUDKey];
                [self promptForAdminSecretThenFetchPage:offset];
                return;
            }

            if (error || !data) return;

            NSDictionary *json     = [NSJSONSerialization JSONObjectWithData:data
                                                                     options:0
                                                                       error:nil];
            NSArray      *newRows  = json[@"rows"];
            NSDictionary *agg      = json[@"aggregate"];

            if (offset == 0) [self.rows removeAllObjects];

            if ([newRows isKindOfClass:[NSArray class]]) {
                [self.rows addObjectsFromArray:newRows];
                self.hasMore = ((NSInteger)newRows.count == kPageSize);
            }

            if ([agg isKindOfClass:[NSDictionary class]]) {
                self.aggregate = agg;
                [self.summaryView configureWithAggregate:agg];
            }

            // Recomputes filteredRows, reloads the table, and sets the
            // subtitle/empty-state text (covers both search + status filter).
            [self refreshFilteredRows];
        });
    }] resume];
}

// ── Grant coins ───────────────────────────────────────────────────────────────
// Triggered by double-tapping the "+" on a ledger card. Two steps: first
// collect the amount + reason (with the account's email shown prominently so
// an admin doesn't credit the wrong person), then a second confirmation that
// restates exactly what's about to happen before anything is sent.
//
// NOTE: performGrantCoinsForUserId:email:amount:reason: posts to
// kGrantCoinsPath, a placeholder — point it at your real grant edge function
// and adjust the request body to match its expected payload.

- (void)presentGrantCoinsSheetForUserId:(NSString *)userId email:(NSString *)email {
    NSString *displayEmail = email.length ? email : (userId.length ? userId : @"(unknown account)");
    UIAlertController *choice = [UIAlertController alertControllerWithTitle:@"Manual Coin Adjustment"
                                                                     message:[NSString stringWithFormat:@"Account: %@", displayEmail]
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [choice addAction:[UIAlertAction actionWithTitle:@"Grant Coins"
                                                style:UIAlertActionStyleDefault
                                              handler:^(__unused UIAlertAction *action) {
        [weakSelf presentCoinAdjustmentSheetForUserId:userId email:email reversal:NO];
    }]];
    [choice addAction:[UIAlertAction actionWithTitle:@"Reverse Previous Grant"
                                                style:UIAlertActionStyleDestructive
                                              handler:^(__unused UIAlertAction *action) {
        [weakSelf presentCoinAdjustmentSheetForUserId:userId email:email reversal:YES];
    }]];
    [choice addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    choice.popoverPresentationController.sourceView = self.view;
    choice.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:choice animated:YES completion:nil];
}

- (void)presentCoinAdjustmentSheetForUserId:(NSString *)userId
                                      email:(NSString *)email
                                   reversal:(BOOL)isReversal {
    NSString *displayEmail = email.length ? email : (userId.length ? userId : @"(unknown account)");
    NSString *verb = isReversal ? @"Reverse" : @"Grant";
    NSString *ledgerTerm = isReversal ? @"manual reversal" : @"manual grant";

    UIAlertController *inputAlert = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"%@ Manual Coins", verb]
                         message:[NSString stringWithFormat:
                            @"Account: %@\n\nEnter how many coins to %@ and a short reason. "
                            @"This is logged to the ledger as a %@; prior entries remain visible.",
                            displayEmail, isReversal ? @"remove" : @"grant", ledgerTerm]
                  preferredStyle:UIAlertControllerStyleAlert];

    [inputAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = isReversal ? @"Coins to remove (e.g. 100)" : @"Coins to grant (e.g. 100)";
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [inputAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Reason (e.g. refund for failed image gen)";
        textField.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    }];

    [inputAlert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                    style:UIAlertActionStyleCancel
                                                  handler:nil]];

    __weak typeof(self) weakSelf = self;
    [inputAlert addAction:[UIAlertAction actionWithTitle:@"Next"
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *action) {
        NSString *amountText = inputAlert.textFields.firstObject.text;
        NSString *reason = [inputAlert.textFields.lastObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        NSInteger amount = [amountText integerValue];
        BOOL amountLooksNumeric = amountText.length > 0 &&
            [[NSCharacterSet decimalDigitCharacterSet] isSupersetOfSet:
                [NSCharacterSet characterSetWithCharactersInString:amountText]];

        if (!amountLooksNumeric || amount <= 0) {
            [weakSelf presentSimpleAlertWithTitle:@"Invalid Amount"
                                          message:@"Enter a whole number of coins greater than zero."];
            return;
        }
        if (reason.length == 0) {
            [weakSelf presentSimpleAlertWithTitle:@"Reason Required"
                                          message:@"A short reason is required so this grant is traceable later."];
            return;
        }

        [weakSelf presentCoinAdjustmentConfirmationForUserId:userId
                                                        email:displayEmail
                                                       amount:amount
                                                       reason:reason
                                                    reversal:isReversal];
    }]];

    [self presentViewController:inputAlert animated:YES completion:nil];
}

// Second, explicit confirmation restating the account, amount, and reason —
// the last checkpoint before crediting a real account.
- (void)presentCoinAdjustmentConfirmationForUserId:(NSString *)userId
                                               email:(NSString *)email
                                              amount:(NSInteger)amount
                                              reason:(NSString *)reason
                                           reversal:(BOOL)isReversal {
    NSString *verb = isReversal ? @"Reverse" : @"Grant";
    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Confirm %@", verb]
                         message:[NSString stringWithFormat:
                            @"%@ %ld coins %@:\n%@\n\nReason: %@\n\nThis creates a permanent, auditable ledger entry.",
                            verb, (long)amount, isReversal ? @"from" : @"to", email, reason]
                  preferredStyle:UIAlertControllerStyleAlert];

    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:isReversal ? @"Reverse Coins" : @"Grant Coins"
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *action) {
        [weakSelf performCoinAdjustmentForUserId:userId email:email amount:amount reason:reason reversal:isReversal];
    }]];

    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)performCoinAdjustmentForUserId:(NSString *)userId
                                  email:(NSString *)email
                                 amount:(NSInteger)amount
                                 reason:(NSString *)reason
                              reversal:(BOOL)isReversal {
    if (!self.adminSecret.length) {
        [self presentSimpleAlertWithTitle:@"Not Authenticated"
                                  message:@"Admin secret is missing — pull to refresh the ledger to re-enter it, then try again."];
        return;
    }
    if (![EZAuthManager shared].accessToken) {
        [self presentSimpleAlertWithTitle:@"Not Authenticated" message:@"No active session was found."];
        return;
    }

    [self.spinner startAnimating];
    __weak typeof(self) weakSelf = self;
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *tokenError) {
        if (!token.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                [self.spinner stopAnimating];
                [self presentSimpleAlertWithTitle:@"Not Authenticated"
                                           message:tokenError.localizedDescription ?: @"Your session could not be refreshed."];
            });
            return;
        }
        NSString *urlString = [NSString stringWithFormat:@"%@%@", kAdminLedgerBase, kGrantCoinsPath];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        request.HTTPMethod = @"POST";
        request.timeoutInterval = 20;
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [request setValue:self.adminSecret forHTTPHeaderField:@"x-admin-secret"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
            @"user_id": userId ?: @"", @"email": email ?: @"",
            @"amount": @(amount), @"reason": reason ?: @"",
            @"operation": isReversal ? @"reversal" : @"grant",
            // Allows a safe retry of this exact submission if its response is
            // lost.  The server treats the request ID as idempotent.
            @"request_id": NSUUID.UUID.UUIDString,
        } options:0 error:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.spinner stopAnimating];

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            BOOL success = !error && httpResponse.statusCode >= 200 && httpResponse.statusCode < 300;

            if (!success) {
                NSDictionary *body = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                NSString *serverError = [body[@"error"] isKindOfClass:[NSString class]] ? body[@"error"] : nil;
                NSString *detail = serverError.length ? serverError : error.localizedDescription
                    ?: [NSString stringWithFormat:@"Server returned status %ld.", (long)httpResponse.statusCode];
                if (httpResponse.statusCode == 403) {
                    strongSelf.adminSecret = nil;
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAdminSecretUDKey];
                }
                [strongSelf presentSimpleAlertWithTitle:@"Grant Failed" message:detail];
                return;
            }

            UINotificationFeedbackGenerator *haptic = [UINotificationFeedbackGenerator new];
            [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

            // Refresh so the new manual_grant row and updated balance show up.
            strongSelf.hasMore = YES;
            [strongSelf fetchPage:0];
        });
        }] resume];
    }];
}

- (void)presentSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ── UITableView ───────────────────────────────────────────────────────────────

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.filteredRows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EZAdminLedgerCell *cell = [tableView dequeueReusableCellWithIdentifier:kLedgerCellID
                                                              forIndexPath:indexPath];
    [cell configureWithRow:self.filteredRows[(NSUInteger)indexPath.row]];

    __weak typeof(self) weakSelf = self;
    cell.grantCoinsHandler = ^(NSString *userId, NSString *email) {
        [weakSelf presentGrantCoinsSheetForUserId:userId email:email];
    };
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [EZAdminLedgerCell rowHeightForRow:self.filteredRows[(NSUInteger)indexPath.row]];
}

- (void)tableView:(UITableView *)tableView
  willDisplayCell:(UITableViewCell *)cell
forRowAtIndexPath:(NSIndexPath *)indexPath {
    // Paginate — load the next server page when nearing the bottom of what's
    // currently displayed. With a status filter active, filteredRows can be
    // much shorter than rows, so this triggers on the last few *filtered*
    // rows rather than self.rows, so a narrow filter (e.g. "Error") still
    // pages in more data instead of silently stopping.
    if (self.hasMore && !self.loading &&
        indexPath.row >= (NSInteger)self.filteredRows.count - 5) {
        [self fetchPage:(NSInteger)self.rows.count];
    }
}

// ── Export ────────────────────────────────────────────────────────────────────
// Export button in the nav bar generates a CSV or PDF of the current filtered
// dataset. If the user has only scrolled part-way through the results, the
// export fetches all remaining pages first (up to kExportRowLimit rows) before
// generating the file. Both formats are delivered via the standard iOS share
// sheet — Files, Mail, AirDrop, etc.

// Maximum rows the export will fetch. Exceeding this shows a warning and caps.
static NSInteger const kExportRowLimit  = 2000;
// Rows per export fetch request — server caps limit at 1000.
static NSInteger const kExportPageSize  = 1000;

// Builds the active filter query string suffix used by both fetchPage: and the
// export fetch, so both always send the same filter params to the server.
// Returns an empty string when no filter is active.
- (NSString *)activeFilterQueryString {
    if (self.activeSearchQuery.length == 0) return @"";
    NSString *encoded = [self.activeSearchQuery
        stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet URLQueryAllowedCharacterSet]];
    if ([self.activeSearchQuery containsString:@"@"]) {
        return [NSString stringWithFormat:@"&email=%@", encoded];
    }
    if (self.excludesFeature) {
        return [NSString stringWithFormat:@"&exclude_feature=%@", encoded];
    }
    return [NSString stringWithFormat:@"&feature=%@", encoded];
}

- (void)exportButtonTapped {
    if (self.loading) return; // Pagination in progress — wait for it to finish

    if (!self.hasMore) {
        // All rows are already in memory — no extra fetch needed
        [self presentExportOptionsWithRows:[self.rows copy]];
        return;
    }

    // Some pages haven't been loaded yet. Disable the button and show the
    // spinner while we fetch the complete dataset.
    self.exportButton.enabled = NO;
    [self.spinner startAnimating];

    [self fetchAllRowsForExportWithCompletion:^(NSArray *allRows, BOOL wasCapped) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.exportButton.enabled = YES;

            if (wasCapped) {
                NSString *msg = [NSString stringWithFormat:
                    @"The dataset has more than %ld rows. "
                    @"Only the first %ld will be exported. "
                    @"Apply a tighter filter to export the full set.",
                    (long)kExportRowLimit, (long)kExportRowLimit];
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"Large Dataset"
                                     message:msg
                              preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                          style:UIAlertActionStyleCancel
                                                        handler:nil]];
                [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Export %ld Rows", (long)kExportRowLimit]
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction *a) {
                    [self presentExportOptionsWithRows:allRows];
                }]];
                [self presentViewController:alert animated:YES completion:nil];
            } else {
                [self presentExportOptionsWithRows:allRows];
            }
        });
    }];
}

// Fetches all pages of the current filter into a temporary array without
// touching self.rows. Does NOT set self.loading — the export button is
// disabled instead so the two fetches don't interfere.
- (void)fetchAllRowsForExportWithCompletion:(void(^)(NSArray<NSDictionary *> *rows, BOOL wasCapped))completion {
    [self _fetchExportPage:0
              accumulated:[NSMutableArray array]
               completion:completion];
}

- (void)_fetchExportPage:(NSInteger)offset
             accumulated:(NSMutableArray<NSDictionary *> *)accumulated
              completion:(void(^)(NSArray<NSDictionary *> *rows, BOOL wasCapped))completion {

    NSString *token = [EZAuthManager shared].accessToken;
    if (!token.length) {
        completion([accumulated copy], NO);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:
        @"%@%@?mode=user&limit=%ld&offset=%ld",
        kAdminLedgerBase, kAdminLedgerPath, (long)kExportPageSize, (long)offset];
    urlString = [urlString stringByAppendingString:[self activeFilterQueryString]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 30;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [request setValue:self.adminSecret forHTTPHeaderField:@"x-admin-secret"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

        // 403 means the admin secret is wrong. Don't prompt from the export
        // path — the user can tap Refresh which handles 403 + re-prompt.
        if (httpResponse.statusCode == 403 || error || !data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([accumulated copy], NO);
            });
            return;
        }

        NSDictionary *json   = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray      *newRows = json[@"rows"];

        if ([newRows isKindOfClass:[NSArray class]]) {
            [accumulated addObjectsFromArray:newRows];
        }

        BOOL serverHasMore = ((NSInteger)newRows.count == kExportPageSize);
        BOOL hitCap        = (NSInteger)accumulated.count >= kExportRowLimit;

        if (serverHasMore && !hitCap) {
            [self _fetchExportPage:offset + kExportPageSize
                       accumulated:accumulated
                        completion:completion];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion([accumulated copy], hitCap && serverHasMore);
            });
        }
    }] resume];
}

- (void)presentExportOptionsWithRows:(NSArray<NSDictionary *> *)rows {
    if (rows.count == 0) {
        UIAlertController *empty = [UIAlertController
            alertControllerWithTitle:@"Nothing to Export"
                             message:@"No rows match the current filter."
                      preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:empty animated:YES completion:nil];
        return;
    }

    NSString *filterDesc = self.activeSearchQuery.length > 0
        ? [NSString stringWithFormat:@"Filter: %@  —  ", self.activeSearchQuery]
        : @"";
    NSString *subtitle = [NSString stringWithFormat:@"%@%ld rows", filterDesc, (long)rows.count];

    UIAlertController *formatPicker = [UIAlertController
        alertControllerWithTitle:@"Export Ledger"
                         message:subtitle
                  preferredStyle:UIAlertControllerStyleActionSheet];

    [formatPicker addAction:[UIAlertAction
        actionWithTitle:@"CSV  —  Spreadsheet / Numbers / Excel"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
            NSData   *csvData  = [self generateCSVFromRows:rows];
            NSString *fileName = [self exportFileNameWithExtension:@"csv"];
            [self presentShareSheetWithData:csvData fileName:fileName];
    }]];

    [formatPicker addAction:[UIAlertAction
        actionWithTitle:@"PDF  —  Formatted Report"
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
            NSData   *pdfData  = [self generatePDFFromRows:rows];
            NSString *fileName = [self exportFileNameWithExtension:@"pdf"];
            [self presentShareSheetWithData:pdfData fileName:fileName];
    }]];

    [formatPicker addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                     style:UIAlertActionStyleCancel
                                                   handler:nil]];

    // iPad requires an anchor; on iPhone this is ignored
    formatPicker.popoverPresentationController.barButtonItem = self.exportButton;
    [self presentViewController:formatPicker animated:YES completion:nil];
}

// Returns a timestamped filename that includes the active filter if set,
// with characters that are unsafe for filenames replaced by underscores.
- (NSString *)exportFileNameWithExtension:(NSString *)ext {
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd_HHmm";
    NSString *dateStr = [df stringFromDate:[NSDate date]];

    if (self.activeSearchQuery.length > 0) {
        NSCharacterSet *unsafe = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
        NSString *safeQuery = [[self.activeSearchQuery
            componentsSeparatedByCharactersInSet:unsafe]
            componentsJoinedByString:@"_"];
        return [NSString stringWithFormat:@"EZLedger_%@_%@.%@", safeQuery, dateStr, ext];
    }
    return [NSString stringWithFormat:@"EZLedger_all_%@.%@", dateStr, ext];
}

// ── CSV generation ────────────────────────────────────────────────────────────

- (NSData *)generateCSVFromRows:(NSArray<NSDictionary *> *)rows {
    NSMutableString *csv = [NSMutableString string];

    // Header row — matches the column order of the data rows below
    [csv appendString:
        @"Date (UTC),User Email,IP Address,Feature,Model,Prompt,Coins Charged,Balance After,Input Tokens,Output Tokens,Total Tokens,API Cost USD,Cost/100 Coins,Margin %,Status,Error\n"];




    // jsonNum: safely stringifies a JSON number field, returning a fallback for
    // nil and NSNull (which JSON null deserialises to — it's truthy, so ?: misses it).
    NSString *(^jsonNum)(id, NSString *) = ^NSString *(id val, NSString *fallback) {
        return (!val || [val isKindOfClass:[NSNull class]]) ? fallback : [NSString stringWithFormat:@"%@", val];
    };

    for (NSDictionary *row in rows) {
        NSArray<NSString *> *fields = @[
            [self csvEscape:row[@"created_at"]],
            [self csvEscape:row[@"user_email"]],
            [self csvEscape:row[@"ip_address"]],
            [self csvEscape:row[@"feature"]],
            [self csvEscapeModel:row[@"model"] feature:row[@"feature"]],
            [self csvEscape:row[@"prompt"]],
            jsonNum(row[@"coins_charged"],      @"0"),
            jsonNum(row[@"running_balance"],    @"0"),
            jsonNum(row[@"input_tokens"],       @"0"),
            jsonNum(row[@"output_tokens"],      @"0"),
            jsonNum(row[@"total_tokens"],       @"0"),
            jsonNum(row[@"api_cost_usd"],       @"0"),
            [self csvRound:row[@"cost_per_100_coins"] decimals:4],
            [self csvRound:row[@"implied_margin_pct"] decimals:2],
            [self csvEscape:row[@"status"]],
            [self csvEscape:row[@"error_text"]],
        ];
        [csv appendString:[fields componentsJoinedByString:@","]];
        [csv appendString:@"\n"];
    }

    return [csv dataUsingEncoding:NSUTF8StringEncoding];
}

// RFC-4180 CSV escaping: wraps values containing commas, newlines, or quotes in
// double-quotes, and escapes any internal double-quotes by doubling them.
//
// Accepts any JSON-deserialised type — JSON null becomes [NSNull null] after
// deserialisation, which is a real object (truthy), not nil. Callers using
// ?: @"" don't catch it. Handling it here means every call site is safe
// regardless of what the server returns for a given field.
- (NSString *)csvEscape:(id)rawValue {
    if (!rawValue || [rawValue isKindOfClass:[NSNull class]]) return @"";
    NSString *value = [rawValue isKindOfClass:[NSString class]]
        ? (NSString *)rawValue
        : [rawValue description];
    if (!value.length) return @"";
    BOOL needsQuoting = [value containsString:@","]
                     || [value containsString:@"\n"]
                     || [value containsString:@"\""];
    if (!needsQuoting) return value;
    NSString *escapedValue = [value stringByReplacingOccurrencesOfString:@"\""
                                                            withString:@"\"\""];
    return [NSString stringWithFormat:@"\"%@\"", escapedValue];
}

// Returns a human-readable model label for CSV export.
// TTS voice IDs are opaque alphanumeric strings that mean nothing outside the
// TTS provider dashboard — they are replaced with "TTS Voice" in exports.
// All other model names (gpt-5-mini, sora-2, etc.) are kept as-is.
- (NSString *)csvEscapeModel:(id)modelValue feature:(id)featureValue {
    NSString *modelString   = [modelValue isKindOfClass:[NSString class]] ? modelValue : @"";
    NSString *featureString = [featureValue isKindOfClass:[NSString class]] ? featureValue : @"";
    BOOL looksLikeVoiceId = (modelString.length >= 16)
        && [featureString isEqualToString:@"tts"]
        && ([modelString rangeOfCharacterFromSet:
               [NSCharacterSet characterSetWithCharactersInString:@"-. "]].location == NSNotFound);
    return looksLikeVoiceId ? @"TTS Voice" : [self csvEscape:modelString];
}

// Formats a numeric JSON value to a fixed number of decimal places.
// Prevents floating-point artifacts like 78.15000000000001 from appearing in the CSV.
- (NSString *)csvRound:(id)value decimals:(NSInteger)decimals {
    if (!value || [value isKindOfClass:[NSNull class]]) return @"";
    NSString *formatString = [NSString stringWithFormat:@"%%.%ldf", (long)decimals];
    return [NSString stringWithFormat:formatString, [value doubleValue]];
}

// ── PDF generation ────────────────────────────────────────────────────────────
// Builds an HTML table and renders it to PDF via UIMarkupTextPrintFormatter.
// Landscape US Letter (792×612pt) gives enough horizontal room for the columns.

- (NSData *)generatePDFFromRows:(NSArray<NSDictionary *> *)rows {
    NSString *html = [self buildHTMLReportForRows:rows];

    UIMarkupTextPrintFormatter *formatter =
        [[UIMarkupTextPrintFormatter alloc] initWithMarkupText:html];
    UIPrintPageRenderer *renderer = [[UIPrintPageRenderer alloc] init];
    [renderer addPrintFormatter:formatter startingAtPageAtIndex:0];

    CGRect paperRect    = CGRectMake(0, 0, 792, 612);  // US Letter landscape
    CGRect printableRect = CGRectInset(paperRect, 36, 36);
    [renderer setValue:[NSValue valueWithCGRect:paperRect]     forKey:@"paperRect"];
    [renderer setValue:[NSValue valueWithCGRect:printableRect] forKey:@"printableRect"];

    NSMutableData *pdfData = [NSMutableData data];
    UIGraphicsBeginPDFContextToData(pdfData, CGRectZero, nil);
    for (NSInteger pageIndex = 0; pageIndex < renderer.numberOfPages; pageIndex++) {
        UIGraphicsBeginPDFPage();
        [renderer drawPageAtIndex:pageIndex inRect:UIGraphicsGetPDFContextBounds()];
    }
    UIGraphicsEndPDFContext();
    return pdfData;
}

- (NSString *)buildHTMLReportForRows:(NSArray<NSDictionary *> *)rows {
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateStyle = NSDateFormatterMediumStyle;
    df.timeStyle = NSDateFormatterShortStyle;
    NSString *exportDate = [df stringFromDate:[NSDate date]];

    NSString *filterLine = self.activeSearchQuery.length > 0
        ? [NSString stringWithFormat:@"Filter: %@ &nbsp;|&nbsp; ",
           [self htmlEscape:self.activeSearchQuery]]
        : @"";

    NSMutableString *html = [NSMutableString string];
    [html appendString:@"<!DOCTYPE html><html><head><meta charset='UTF-8'><style>"
     @"body{font-family:-apple-system,Helvetica;font-size:8.5px;color:#111;margin:0}"
     @"h1{font-size:13px;margin:0 0 3px}"
     @".meta{font-size:7.5px;color:#555;margin-bottom:8px}"
     @"table{width:100%;border-collapse:collapse;page-break-inside:auto}"
     @"thead{display:table-header-group}"   /* repeat header on each printed page */
     @"th{background:#0d1117;color:#e6c94a;padding:4px 5px;text-align:left;font-size:7.5px;white-space:nowrap}"
     @"td{padding:3px 5px;border-bottom:1px solid #e8e8e8;font-size:7.5px;vertical-align:top}"
     @"tr:nth-child(even)td{background:#f7f7f7}"
     @".debit{color:#b71c1c;font-weight:600}"
     @".credit{color:#1b5e20;font-weight:600}"
     @".err{color:#b71c1c}"
     @"</style></head><body>"];

    [html appendFormat:@"<h1>EZCompleteUI Admin Ledger</h1>"
     @"<div class='meta'>%@Exported: %@ &nbsp;|&nbsp; %ld rows</div>",
     filterLine, exportDate, (long)rows.count];

    [html appendString:
     @"<table><thead><tr>"
     @"<th>Date (UTC)</th><th>Email</th><th>Feature</th><th>Model</th><th>Prompt</th>"
     @"<th>Coins</th><th>Balance</th><th>Tokens</th><th>API Cost</th>"
     @"<th>¢/100</th><th>Status</th>"
     @"</tr></thead><tbody>"];

    for (NSDictionary *row in rows) {
        // Trim ISO timestamp: "2025-06-21T10:59:00.000Z" → "2025-06-21 10:59"
        NSString *dateStr = row[@"created_at"] ?: @"";
        if (dateStr.length >= 16) {
            dateStr = [[dateStr substringToIndex:16]
                stringByReplacingOccurrencesOfString:@"T" withString:@" "];
        }

        NSInteger coins     = [row[@"coins_charged"] integerValue];
        NSString *coinClass = coins > 0 ? @"debit" : @"credit";
        NSString *coinStr   = [NSString stringWithFormat:@"%@%ld",
                               coins > 0 ? @"−" : @"+", (long)ABS(coins)];

        NSString *statusStr = row[@"status"] ?: @"";
        NSString *statusClass = [statusStr isEqualToString:@"error"] ? @" class='err'" : @"";

        [html appendFormat:
         @"<tr>"
         @"<td>%@</td>"
         @"<td>%@</td>"
         @"<td>%@</td>"
         @"<td>%@</td>"
         @"<td class='%@'>%@</td>"
         @"<td>%@</td>"
         @"<td>%@</td>"
         @"<td>$%@</td>"
         @"<td>%@</td>"
         @"<td%@>%@</td>"
         @"</tr>",
         [self htmlEscape:dateStr],
         [self htmlEscape:row[@"user_email"] ?: @""],
         [self htmlEscape:row[@"feature"]    ?: @""],
         [self htmlEscape:row[@"model"]      ?: @""],
         coinClass, coinStr,
         row[@"running_balance"]    ?: @"",
         row[@"total_tokens"]       ?: @"",
         row[@"api_cost_usd"]       ?: @"0",
         row[@"cost_per_100_coins"] ?: @"",
         statusClass,
         [self htmlEscape:statusStr]];
    }

    [html appendString:@"</tbody></table></body></html>"];
    return html;
}

// Escapes the five characters that have special meaning in HTML.
// Accepts any JSON-deserialised type — same NSNull hazard as csvEscape:.
- (NSString *)htmlEscape:(id)rawValue {
    if (!rawValue || [rawValue isKindOfClass:[NSNull class]]) return @"";
    NSString *string = [rawValue isKindOfClass:[NSString class]]
        ? (NSString *)rawValue
        : [rawValue description];
    if (!string.length) return @"";
    return [[[[[string
        stringByReplacingOccurrencesOfString:@"&"  withString:@"&amp;"]
        stringByReplacingOccurrencesOfString:@"<"  withString:@"&lt;"]
        stringByReplacingOccurrencesOfString:@">"  withString:@"&gt;"]
        stringByReplacingOccurrencesOfString:@"\""  withString:@"&quot;"]
        stringByReplacingOccurrencesOfString:@"'"  withString:@"&#39;"];
}

// ── Share sheet ───────────────────────────────────────────────────────────────

- (void)presentShareSheetWithData:(NSData *)fileData fileName:(NSString *)fileName {
    if (!fileData.length) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Export Failed"
                             message:@"The file could not be generated."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSURL *tempURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:fileName];

    NSError *writeError;
    [fileData writeToURL:tempURL options:NSDataWritingAtomic error:&writeError];

    if (writeError) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Export Failed"
                             message:writeError.localizedDescription
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIActivityViewController *activityVC = [[UIActivityViewController alloc]
        initWithActivityItems:@[tempURL]
        applicationActivities:nil];
    // These activity types don't make sense for a data file
    activityVC.excludedActivityTypes = @[
        UIActivityTypeAssignToContact,
        UIActivityTypePostToFacebook,
        UIActivityTypePostToTwitter,
        UIActivityTypePostToWeibo,
    ];
    activityVC.popoverPresentationController.barButtonItem = self.exportButton;
    [self presentViewController:activityVC animated:YES completion:nil];
}

// ── UISearchBarDelegate ───────────────────────────────────────────────────────

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;

    NSString *trimmed = [searchText stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (trimmed.length == 0) {
        // Clear filter immediately — no debounce needed for an empty field
        self.activeSearchQuery = nil;
        self.hasMore = YES;
        [self fetchPage:0];
        return;
    }

    // Store the pending query and wait 0.4s after the last keystroke before
    // hitting the server — avoids a request for every character typed.
    self.activeSearchQuery = trimmed;
    self.searchDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                                target:self
                                                              selector:@selector(searchDebounceTimerFired)
                                                              userInfo:nil
                                                               repeats:NO];
}

- (void)searchDebounceTimerFired {
    self.searchDebounceTimer = nil;
    self.hasMore = YES;
    [self fetchPage:0];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    // Keyboard Search button — fire immediately without waiting for the timer
    [searchBar resignFirstResponder];
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;
    self.hasMore = YES;
    [self fetchPage:0];
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
    switch (selectedScope) {
        case 1:  self.activeStatusFilter = @"completed"; break;
        case 2:  self.activeStatusFilter = @"pending";   break;
        case 3:  self.activeStatusFilter = @"error";     break;
        default: self.activeStatusFilter = nil;          break;
    }
    [self refreshFilteredRows];
}

// Recomputes filteredRows from rows using activeStatusFilter, reloads the
// table, and updates the subtitle/empty-state text to reflect both the
// text search and the status filter, whichever are active.
- (void)refreshFilteredRows {
    if (self.activeStatusFilter.length == 0) {
        self.filteredRows = [self.rows copy];
    } else {
        NSMutableArray<NSDictionary *> *matched = [NSMutableArray array];
        for (NSDictionary *row in self.rows) {
            NSString *status = [row[@"status"] isKindOfClass:[NSString class]]
                ? row[@"status"] : @"complete";
            if (!status.length) status = @"complete";
            BOOL isMatch = NO;
            if ([self.activeStatusFilter isEqualToString:@"completed"]) {
                isMatch = ![status isEqualToString:@"pending"] && ![status isEqualToString:@"error"];
            } else {
                isMatch = [status isEqualToString:self.activeStatusFilter];
            }
            if (isMatch) [matched addObject:row];
        }
        self.filteredRows = matched;
    }

    [self.tableView reloadData];

    NSMutableArray<NSString *> *filterParts = [NSMutableArray array];
    if (self.activeSearchQuery.length > 0) [filterParts addObject:self.excludesFeature && ![self.activeSearchQuery containsString:@"@"] ? [NSString stringWithFormat:@"excluding %@", self.activeSearchQuery] : self.activeSearchQuery];
    if (self.activeStatusFilter.length > 0) [filterParts addObject:self.activeStatusFilter];
    [self.summaryView setFilterDescription:filterParts.count
        ? [filterParts componentsJoinedByString:@" • "] : nil];

    self.emptyLabel.hidden = self.filteredRows.count > 0;
    if (self.filteredRows.count == 0) {
        self.emptyLabel.text = filterParts.count
            ? [NSString stringWithFormat:@"No results for \"%@\"", [filterParts componentsJoinedByString:@" • "]]
            : @"No transactions found.";
    }
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)refreshTapped {
    // Preserve the active filter — refresh re-runs the current query from page 0
    self.hasMore = YES;
    [self fetchPage:0];
}

- (void)excludeButtonTapped {
    self.excludesFeature = !self.excludesFeature;
    [self updateExcludeButtonAppearance];
    self.hasMore = YES;
    [self fetchPage:0];
}

- (void)updateExcludeButtonAppearance {
    self.excludeButton.title = self.excludesFeature ? @"Exclude ✓" : @"Exclude";
    self.excludeButton.tintColor = self.excludesFeature ? [UIColor systemRedColor] : EZGold();
}

- (void)closeTapped {
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#endif // DEBUG
