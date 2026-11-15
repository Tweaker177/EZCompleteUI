// HelperLogViewController.m
// EZCompleteUI
//
// Displays the full ezui_helper.log in a card-based table view.
// • One card per log line (parsed into level / tag / body).
// • File/image paths embedded in a log line get an inline QL thumbnail and
//   a tap gesture that opens QLPreviewController — same pattern as
//   MemoriesViewController.
// • chatKey tokens (ISO-8601 style, e.g. 2026-04-05T14-29-20) are rendered
//   as tappable deep-links that post EZOpenChatThread and dismiss the viewer.
// • Toolbar: share raw log  |  refresh  |  clear log (with confirmation).
// • Search bar filters displayed rows live.

#import "HelperLogViewController.h"
#import "helpers.h"
#import "SystemLogViewController.h"
#import <QuickLook/QuickLook.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Parsed log entry model
// ─────────────────────────────────────────────────────────────────────────────

/// A single parsed line from ezui_helper.log.
///
/// NOTE: ezui_helper.log is written exclusively by EZHelperLog() in helpers.m,
/// which formats every line as `[timestamp] [stageTag] body` — TWO bracketed
/// fields, not three. (The three-field `[ts] [LEVEL] [TAG] body` format is
/// what EZLog() writes to the *system* log instead.) There is no severity
/// level in this file; "stageTag" is the pipeline stage that produced the
/// line, e.g. "Stage1-Verdict", "Stage2-Ranker", "Stage1-ValidatorDecision".
@interface EZLogEntry : NSObject
@property (nonatomic, copy)   NSString        *raw;          // full original line
@property (nonatomic, copy)   NSString        *timestamp;    // e.g. "2026-04-05 14:29:20"
@property (nonatomic, copy)   NSString        *stageTag;     // e.g. "Stage1-Verdict", "Stage2-Ranker"
@property (nonatomic, copy, nullable) NSString *decision;    // parsed from a leading "DECISION: <value>" line, if present
@property (nonatomic, copy)   NSString        *body;         // message text
@property (nonatomic, copy, nullable) NSString *filePath;    // first valid path found in body, or nil
@property (nonatomic, copy, nullable) NSString *chatKey;     // first ISO-8601-style key found, or nil
@end

@implementation EZLogEntry
@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EZLogCell (card cell)
// ─────────────────────────────────────────────────────────────────────────────

@protocol EZLogCellDelegate <NSObject>
- (void)logCellDidTapFileAtIndex:(NSUInteger)index;
- (void)logCellDidTapChatKey:(NSString *)chatKey;
@end

@interface EZLogCell : UITableViewCell

@property (nonatomic, strong) UILabel     *levelBadge;
@property (nonatomic, strong) UILabel     *tagLabel;
@property (nonatomic, strong) UILabel     *timestampLabel;
@property (nonatomic, strong) UITextView  *bodyTextView;   // attributed — chatKey links
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, strong) UIButton    *thumbButton;
@property (nonatomic, strong) UILabel     *thumbBadge;

@property (nonatomic, strong) NSLayoutConstraint *thumbHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *bodyTopWithThumb;
@property (nonatomic, strong) NSLayoutConstraint *bodyTopNoThumb;

@property (nonatomic, weak)   id<EZLogCellDelegate> logDelegate;
@property (nonatomic, assign) NSUInteger entryIndex;
@property (nonatomic, copy, nullable) NSString *chatKeyToken;

- (void)configureWithEntry:(EZLogEntry *)entry
                     index:(NSUInteger)index
                  delegate:(id<EZLogCellDelegate>)delegate;
- (void)setThumbnailImage:(UIImage *)image;

@end

@implementation EZLogCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.selectionStyle     = UITableViewCellSelectionStyleNone;
    self.backgroundColor    = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];

    // ── Card ──────────────────────────────────────────────────────────────────
    UIView *card = [[UIView alloc] init];
    card.tag = 999;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor    = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 12;
    card.layer.borderWidth  = 1.0;
    card.layer.borderColor  = [UIColor separatorColor].CGColor;
    card.layer.shadowColor  = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.06;
    card.layer.shadowOffset  = CGSizeMake(0, 1);
    card.layer.shadowRadius  = 4;
    card.layer.masksToBounds = NO;
    [self.contentView addSubview:card];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor      constraintEqualToAnchor:self.contentView.topAnchor      constant:5],
        [card.bottomAnchor   constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-5],
        [card.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor  constant:12],
        [card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
    ]];

    // ── Top row: level badge + tag + timestamp ────────────────────────────────
    _levelBadge = [[UILabel alloc] init];
    _levelBadge.adjustsFontSizeToFitWidth = YES;
    _levelBadge.minimumScaleFactor = 0.5;
    _levelBadge.font              = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
    _levelBadge.textColor         = [UIColor whiteColor];
    _levelBadge.textAlignment     = NSTextAlignmentCenter;
    _levelBadge.layer.cornerRadius = 5;
    _levelBadge.clipsToBounds     = YES;
    _levelBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_levelBadge];

    _tagLabel = [[UILabel alloc] init];
    _tagLabel.adjustsFontSizeToFitWidth = YES;
    _tagLabel.minimumScaleFactor = 0.5;
    _tagLabel.font      = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
    _tagLabel.textColor = [UIColor secondaryLabelColor];
    _tagLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_tagLabel];

    _timestampLabel = [[UILabel alloc] init];
    _timestampLabel.adjustsFontSizeToFitWidth = YES;
    _timestampLabel.minimumScaleFactor = 0.5;
    _timestampLabel.font      = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _timestampLabel.textColor = [UIColor tertiaryLabelColor];
    _timestampLabel.textAlignment = NSTextAlignmentRight;
    _timestampLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_timestampLabel];

    // ── Thumbnail + overlay button ────────────────────────────────────────────
    _thumbView = [[UIImageView alloc] init];
    _thumbView.translatesAutoresizingMaskIntoConstraints = NO;
    _thumbView.contentMode        = UIViewContentModeScaleAspectFill;
    _thumbView.clipsToBounds      = YES;
    _thumbView.layer.cornerRadius = 8;
    _thumbView.backgroundColor    = [UIColor tertiarySystemFillColor];
    _thumbView.hidden             = YES;
    [card addSubview:_thumbView];

    _thumbButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _thumbButton.translatesAutoresizingMaskIntoConstraints = NO;
    _thumbButton.hidden = NO;
    [_thumbButton addTarget:self action:@selector(thumbTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:_thumbButton];

    _thumbBadge = [[UILabel alloc] init];
    _thumbBadge.adjustsFontSizeToFitWidth = YES;
    _thumbBadge.minimumScaleFactor = 0.5;
    _thumbBadge.font              = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _thumbBadge.textColor         = [UIColor whiteColor];
    _thumbBadge.backgroundColor   = [UIColor systemTealColor];
    _thumbBadge.text              = @"  📎  Tap to preview  ";
    _thumbBadge.layer.cornerRadius = 7;
    _thumbBadge.clipsToBounds     = YES;
    _thumbBadge.hidden            = NO;
    _thumbBadge.userInteractionEnabled = YES;
    _thumbBadge.translatesAutoresizingMaskIntoConstraints = NO;
    UITapGestureRecognizer *badgeTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(thumbTapped)];
    [_thumbBadge addGestureRecognizer:badgeTap];
    [card addSubview:_thumbBadge];

    // ── Body text view (non-scrolling, attributed for chatKey links) ──────────
    _bodyTextView = [[UITextView alloc] init];
    _bodyTextView.font            = [UIFont systemFontOfSize:13];
    _bodyTextView.textColor       = [UIColor labelColor];
    _bodyTextView.backgroundColor = [UIColor clearColor];
    _bodyTextView.scrollEnabled   = NO;
    _bodyTextView.editable        = NO;
    _bodyTextView.dataDetectorTypes = UIDataDetectorTypeNone;
    _bodyTextView.textContainerInset = UIEdgeInsetsZero;
    _bodyTextView.textContainer.lineFragmentPadding = 0;
    _bodyTextView.translatesAutoresizingMaskIntoConstraints = NO;
    _bodyTextView.delegate = (id<UITextViewDelegate>)self;
    [card addSubview:_bodyTextView];

    // ── Static constraints ────────────────────────────────────────────────────
    [NSLayoutConstraint activateConstraints:@[
        // Level badge
        [_levelBadge.topAnchor      constraintEqualToAnchor:card.topAnchor constant:10],
        [_levelBadge.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor constant:12],
        [_levelBadge.heightAnchor   constraintEqualToConstant:20],
        [_levelBadge.widthAnchor    constraintGreaterThanOrEqualToConstant:44],

        // Tag
        [_tagLabel.centerYAnchor   constraintEqualToAnchor:_levelBadge.centerYAnchor],
        [_tagLabel.leadingAnchor   constraintEqualToAnchor:_levelBadge.trailingAnchor constant:6],

        // Timestamp — right-aligned
        [_timestampLabel.centerYAnchor   constraintEqualToAnchor:_levelBadge.centerYAnchor],
        [_timestampLabel.trailingAnchor  constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [_timestampLabel.leadingAnchor   constraintGreaterThanOrEqualToAnchor:_tagLabel.trailingAnchor constant:4],

        // Thumbnail
        [_thumbView.topAnchor      constraintEqualToAnchor:_levelBadge.bottomAnchor constant:8],
        [_thumbView.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor constant:12],
        [_thumbView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],

        // Thumb button covers thumb
        [_thumbButton.topAnchor      constraintEqualToAnchor:_thumbView.topAnchor],
        [_thumbButton.bottomAnchor   constraintEqualToAnchor:_thumbView.bottomAnchor],
        [_thumbButton.leadingAnchor  constraintEqualToAnchor:_thumbView.leadingAnchor],
        [_thumbButton.trailingAnchor constraintEqualToAnchor:_thumbView.trailingAnchor],

        // Badge (shown while thumb loading)
        [_thumbBadge.topAnchor     constraintEqualToAnchor:_levelBadge.bottomAnchor constant:8],
        [_thumbBadge.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [_thumbBadge.heightAnchor  constraintEqualToConstant:30],

        // Body trailing/leading
        [_bodyTextView.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor  constant:12],
        [_bodyTextView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [_bodyTextView.bottomAnchor   constraintEqualToAnchor:card.bottomAnchor   constant:-10],
    ]];

    // ── Dynamic thumb height + body top ───────────────────────────────────────
    _thumbHeightConstraint = [_thumbView.heightAnchor constraintEqualToConstant:0];
    _thumbHeightConstraint.active = YES;

    _bodyTopWithThumb = [_bodyTextView.topAnchor
        constraintEqualToAnchor:_thumbView.bottomAnchor constant:8];
    _bodyTopNoThumb = [_bodyTextView.topAnchor
        constraintEqualToAnchor:_levelBadge.bottomAnchor constant:8];
    _bodyTopNoThumb.active = YES;

    return self;
}

// ── Configuration ─────────────────────────────────────────────────────────────

- (void)configureWithEntry:(EZLogEntry *)entry
                     index:(NSUInteger)index
                  delegate:(id<EZLogCellDelegate>)delegate {
    self.entryIndex   = index;
    self.logDelegate  = delegate;
    self.chatKeyToken = entry.chatKey;

    // Stage badge — colored by which pipeline stage produced this line.
    NSString *stage = entry.stageTag.length ? entry.stageTag : @"GENERAL";
    self.levelBadge.text = [NSString stringWithFormat:@" %@ ", stage.uppercaseString];
    self.levelBadge.backgroundColor = [self colorForStageTag:stage];

    self.tagLabel.text       = entry.decision.length ? [NSString stringWithFormat:@"[%@]", entry.decision] : @"";
    self.timestampLabel.text = entry.timestamp ?: @"";

    // Body — build attributed string with chatKey highlighted as deep-link
    self.bodyTextView.attributedText = [self attributedBodyForEntry:entry];

    // Thumbnail area
    BOOL hasFile = entry.filePath.length > 0;
    self.thumbView.image     = nil;
    self.thumbView.hidden    = YES;
    self.thumbButton.hidden  = YES;

    if (hasFile) {
        self.thumbBadge.hidden         = NO;
        self.thumbHeightConstraint.constant = 160;
        self.bodyTopWithThumb.active   = YES;
        self.bodyTopNoThumb.active     = NO;
    } else {
        self.thumbBadge.hidden         = YES;
        self.thumbHeightConstraint.constant = 0;
        self.bodyTopWithThumb.active   = NO;
        self.bodyTopNoThumb.active     = YES;
    }
}

/// Colors the stage badge by which part of the triage pipeline produced the
/// line (see helpers.m: analyzePromptForContext). Grouping by numeric stage
/// makes it easy to scan a run top-to-bottom and see it move through the
/// pipeline (Stage1 → Stage1a/1b validator → Stage2 search → Stage3 ranker).
- (UIColor *)colorForStageTag:(NSString *)stageTag {
    NSString *s = stageTag.lowercaseString;
    if ([s containsString:@"validator"]) return [UIColor systemTealColor];
    if ([s hasPrefix:@"stage1"])         return [UIColor systemBlueColor];
    if ([s hasPrefix:@"stage2"])         return [UIColor systemPurpleColor];
    if ([s hasPrefix:@"stage3"])         return [UIColor systemIndigoColor];
    return [UIColor systemGrayColor];
}

- (NSAttributedString *)attributedBodyForEntry:(EZLogEntry *)entry {

    NSString *body = entry.body ?: @"";

    NSMutableAttributedString *attr =
    [[NSMutableAttributedString alloc]
     initWithString:body
     attributes:@{
        NSFontAttributeName : [UIFont systemFontOfSize:13],
        NSForegroundColorAttributeName : [UIColor labelColor]
    }];

    // Base font for log-ish readability
    [attr addAttribute:NSFontAttributeName
                 value:[UIFont monospacedSystemFontOfSize:13
                                                    weight:UIFontWeightRegular]
                 range:NSMakeRange(0, body.length)];

#pragma mark - CHATKEY= deep link (blue + tappable)

    NSError *chatErr = nil;
    NSRegularExpression *chatRX =
    [NSRegularExpression regularExpressionWithPattern:
     @"CHATKEY=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2})"
                                                    options:NSRegularExpressionCaseInsensitive
                                                      error:&chatErr];

    NSArray<NSTextCheckingResult *> *chatMatches =
    [chatRX matchesInString:body
                    options:0
                      range:NSMakeRange(0, body.length)];

    for (NSTextCheckingResult *match in chatMatches) {

        if (match.numberOfRanges < 2) continue;

        NSRange fullRange = match.range;
        NSRange keyRange  = [match rangeAtIndex:1];

        NSString *chatKey = [body substringWithRange:keyRange];

        // Use query param so NSURL parsing stops being annoying.
        // IMPORTANT: encode the chatKey from *this* match, not entry.chatKey —
        // entry.chatKey is only the first chatKey-like token found anywhere in
        // the body, so if a body ever contains more than one CHATKEY=
        // reference, using entry.chatKey here would make every link silently
        // point at the same (first) thread regardless of which one it displays.
        NSString *encoded =
            [chatKey stringByAddingPercentEncodingWithAllowedCharacters:
                [NSCharacterSet URLPathAllowedCharacterSet]];

        NSString *urlString =
            [NSString stringWithFormat:@"ezchat://CHATKEY=%@", encoded];

        NSURL *url = [NSURL URLWithString:urlString];

        [attr addAttributes:@{
            NSForegroundColorAttributeName : [UIColor systemBlueColor],
            NSUnderlineStyleAttributeName : @(NSUnderlineStyleSingle),
            NSLinkAttributeName : url,
            NSFontAttributeName :
                [UIFont monospacedSystemFontOfSize:13
                                            weight:UIFontWeightSemibold]
        } range:fullRange];
    }

#pragma mark - Validator pass/fail coloring

    NSArray<NSDictionary *> *validatorRules = @[
        @{
            @"patterns" : @[
                @"approved",
                @"approve direct answer",
                @"direct answer approved",
                @"validator approved",
                @"pass"
            ],
            @"color" : [UIColor systemGreenColor]
        },
        @{
            @"patterns" : @[
                @"not approved",
                @"rejected",
                @"failed",
                @"validator denied",
                @"direct answer denied",
                @"no direct answer"
            ],
            @"color" : [UIColor systemRedColor]
        }
    ];

    for (NSDictionary *rule in validatorRules) {

        UIColor *color = rule[@"color"];

        for (NSString *pattern in rule[@"patterns"]) {

            NSRange searchRange =
            NSMakeRange(0, body.length);

            while (YES) {

                NSRange found =
                [body rangeOfString:pattern
                             options:NSCaseInsensitiveSearch
                               range:searchRange];

                if (found.location == NSNotFound) break;

                [attr addAttributes:@{
                    NSForegroundColorAttributeName : color,
                    NSFontAttributeName :
                        [UIFont systemFontOfSize:13
                                           weight:UIFontWeightBold]
                } range:found];

                NSUInteger next =
                found.location + found.length;

                if (next >= body.length) break;

                searchRange =
                NSMakeRange(next,
                            body.length - next);
            }
        }
    }

    return attr;
}
// ── Thumbnail ─────────────────────────────────────────────────────────────────

- (void)setThumbnailImage:(UIImage *)image {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!image) return;
        self.thumbView.image    = image;
        self.thumbView.hidden   = NO;
        self.thumbButton.hidden = NO;
        self.thumbBadge.hidden  = YES;
    });
}

- (void)thumbTapped {
    [self.logDelegate logCellDidTapFileAtIndex:self.entryIndex];
}

// ── UITextViewDelegate (chatKey link taps) ────────────────────────────────────

#pragma mark - UITextViewDelegate

- (BOOL)textView:(UITextView *)textView
shouldInteractWithURL:(NSURL *)URL
        inRange:(NSRange)characterRange
interaction:(UITextItemInteraction)interaction {

    if ([[URL scheme] isEqualToString:@"ezchat"]) {

        NSString *absolute = URL.absoluteString ?: @"";

        // ezchat://CHATKEY=2026-05-19T22:22:03
        NSString *chatKey = nil;

        NSRange prefixRange = [absolute rangeOfString:@"ezchat://"];
        if (prefixRange.location != NSNotFound) {
            chatKey = [absolute substringFromIndex:
                prefixRange.location + prefixRange.length];
        }

        // remove optional CHATKEY=
        if ([chatKey hasPrefix:@"CHATKEY="]) {
            chatKey = [chatKey substringFromIndex:8];
        }

        // URL decode just in case
        chatKey = [chatKey stringByRemovingPercentEncoding];

        NSLog(@"[EZLOG] tapped chatKey: %@", chatKey);

        if (chatKey.length > 0 &&
            [self.logDelegate respondsToSelector:@selector(logCellDidTapChatKey:)]) {

            [self.logDelegate logCellDidTapChatKey:chatKey];
        }

        return NO;
    }

    return YES;
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HelperLogViewController
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Run status (drives section header color)
//
// A "run" is one full call to analyzePromptForContext() in helpers.m — i.e.
// everything logged while routing a single user message through the triage
// pipeline, including the Stage 2/3 memory search + AI ranker steps if the
// pipeline gets that far. Every run starts with a "Stage1-Verdict" entry,
// since that's unconditionally the first thing _logHelperDecision writes for
// any call that completes Stage 1 (see analyzePromptForContext).
// ─────────────────────────────────────────────────────────────────────────────
typedef NS_ENUM(NSInteger, EZRunStatus) {
    EZRunStatusApproved,   // a Stage1/Stage1b validator approved a direct answer  → green
    EZRunStatusRejected,   // a Stage1/Stage1b validator rejected a direct answer  → red
    EZRunStatusNeutral,    // run completed without invoking the validator at all  → gray
};

@interface HelperLogViewController () <UITableViewDelegate,
                                       UITableViewDataSource,
                                       UISearchBarDelegate,
                                       EZLogCellDelegate,
                                       QLPreviewControllerDataSource,
                                       QLPreviewControllerDelegate>

@property (nonatomic, strong) UITableView   *tableView;
@property (nonatomic, strong) UISearchBar   *searchBar;
@property (nonatomic, strong) UILabel       *emptyLabel;

/// All parsed entries, grouped into pipeline runs (newest run first; entries
/// within a run stay in chronological order so a run reads top-to-bottom the
/// way it actually executed).
@property (nonatomic, strong) NSArray<NSArray<EZLogEntry *> *> *allRuns;
/// Filtered subset of allRuns shown in the table (search keeps a run's
/// section but only includes the rows that matched).
@property (nonatomic, strong) NSArray<NSArray<EZLogEntry *> *> *displayedRuns;

/// Flat view of allRuns (same objects, same order) — used for thumbnail
/// cache indexing and for resolving taps back to a specific entry.
@property (nonatomic, strong) NSArray<EZLogEntry *> *allEntries;

@property (nonatomic, copy)   NSString      *searchTerm;

/// Thumbnail cache keyed by entry index in allEntries
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIImage *> *thumbCache;

/// File URL currently open in QuickLook
@property (nonatomic, strong) NSURL         *previewURL;

@end

@implementation HelperLogViewController

static NSString * const kLogCellID      = @"EZLogCell";
static NSString * const kLogEmptyCellID = @"EZLogEmptyCell";

// ── Log file path ─────────────────────────────────────────────────────────────

- (NSString *)logFilePath {
    // On a jailbroken device use the fixed path; otherwise Documents directory.
    NSString *jbPath = @"/var/mobile/Documents/ezui_helper.log";
    if ([[NSFileManager defaultManager] fileExistsAtPath:jbPath]) {
        return jbPath;
    }
    NSString *helperPath = EZHelperLogGetPath();
    if (helperPath.length) return helperPath;
    NSString *docs = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docs stringByAppendingPathComponent:@"ezui_helper.log"];
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Helper Log";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.thumbCache = [NSMutableDictionary dictionary];

    [self setupNavigationBar];
    [self setupSearchBar];
    [self setupTableView];
    [self setupEmptyLabel];
    [self loadLog];
}

// ── Navigation bar ────────────────────────────────────────────────────────────

- (void)setupNavigationBar {
    // Close
    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(dismissSelf)];
    self.navigationItem.leftBarButtonItem = closeItem;

    UIBarButtonItem *systemLogItem = [[UIBarButtonItem alloc]
        initWithTitle:@"System Log"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(openSystemLog)];
    self.navigationItem.rightBarButtonItem = systemLogItem;

    // Toolbar: share | flex | refresh | flex | clear
    UIBarButtonItem *shareItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:self action:@selector(shareLog)];
    UIBarButtonItem *refreshItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self action:@selector(refreshLog)];
    UIBarButtonItem *clearItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Clear" style:UIBarButtonItemStylePlain
               target:self action:@selector(confirmClearLog)];
    clearItem.tintColor = [UIColor systemRedColor];

    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                             target:nil action:nil];

    self.toolbarItems = @[shareItem, flex, refreshItem, flex, clearItem];
    self.navigationController.toolbarHidden = NO;
}

- (void)openSystemLog {
    SystemLogViewController *systemVC = [[SystemLogViewController alloc] init];
    [self.navigationController pushViewController:systemVC animated:YES];
}

// ── Search bar ────────────────────────────────────────────────────────────────

- (void)setupSearchBar {
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.placeholder  = @"Filter log…";
    self.searchBar.delegate     = self;
    self.searchBar.autocorrectionType    = UITextAutocorrectionTypeNo;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.navigationItem.titleView = self.searchBar; // embed in nav bar to save vertical space
}

// ── Table view ────────────────────────────────────────────────────────────────

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStyleInsetGrouped];
    self.tableView.delegate           = self;
    self.tableView.dataSource         = self;
    self.tableView.rowHeight          = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 90;
    self.tableView.separatorStyle     = UITableViewCellSeparatorStyleNone;
    self.tableView.autoresizingMask   = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.tableView registerClass:[EZLogCell class]    forCellReuseIdentifier:kLogCellID];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kLogEmptyCellID];
    [self.view addSubview:self.tableView];
}

- (void)setupEmptyLabel {
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.adjustsFontSizeToFitWidth = YES;
    self.emptyLabel.minimumScaleFactor = 0.5;
    self.emptyLabel.text          = @"Log file is empty.";
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor     = [UIColor secondaryLabelColor];
    self.emptyLabel.font          = [UIFont systemFontOfSize:16];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.hidden        = YES;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor  constant:32],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
}

// ── Log loading & parsing ─────────────────────────────────────────────────────

- (void)loadLog {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = [self logFilePath];
        NSString *raw  = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        NSMutableArray<EZLogEntry *> *entries = [NSMutableArray array];

        if (raw.length) {
            NSArray<NSString *> *lines = [raw componentsSeparatedByString:@"\n"];
            NSMutableArray<NSString *> *chunks = [NSMutableArray array];
            NSMutableString *currentChunk = nil;
            for (NSString *line in lines) {
                NSString *trimmed = [line stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (!trimmed.length) continue;
                if ([trimmed hasPrefix:@"["]) {
                    if (currentChunk.length) {
                        [chunks addObject:[currentChunk copy]];
                    }
                    currentChunk = [NSMutableString stringWithString:line];
                } else {
                    if (!currentChunk) {
                        currentChunk = [NSMutableString stringWithString:line];
                    } else {
                        [currentChunk appendFormat:@"\n%@", line];
                    }
                }
            }
            if (currentChunk.length) {
                [chunks addObject:[currentChunk copy]];
            }
            for (NSString *chunk in chunks) {
                [entries addObject:[self parseLogLine:chunk]];
            }
        }

        // ── Group into pipeline runs ──────────────────────────────────────────
        // "Stage1-Verdict" is unconditionally the first thing written to this
        // log for any call to analyzePromptForContext() that gets past Stage 1
        // (see helpers.m), so it's a reliable run boundary. Anything logged
        // before the first Stage1-Verdict (stray/legacy lines) becomes its own
        // leading run.
        NSMutableArray<NSArray<EZLogEntry *> *> *runs = [NSMutableArray array];
        NSMutableArray<EZLogEntry *> *currentRun = nil;
        for (EZLogEntry *entry in entries) {
            BOOL startsNewRun = [entry.stageTag isEqualToString:@"Stage1-Verdict"] || !currentRun;
            if (startsNewRun) {
                if (currentRun.count) [runs addObject:[currentRun copy]];
                currentRun = [NSMutableArray array];
            }
            [currentRun addObject:entry];
        }
        if (currentRun.count) [runs addObject:[currentRun copy]];

        // Newest run first; entries *within* a run stay chronological so a
        // section reads top-to-bottom the way it actually executed.
        NSArray<NSArray<EZLogEntry *> *> *reversedRuns = [[runs reverseObjectEnumerator] allObjects];

        NSMutableArray<EZLogEntry *> *flat = [NSMutableArray array];
        for (NSArray<EZLogEntry *> *run in reversedRuns) {
            [flat addObjectsFromArray:run];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.allRuns       = reversedRuns;
            self.displayedRuns = reversedRuns;
            self.allEntries    = [flat copy];
            self.title = flat.count
                ? [NSString stringWithFormat:@"Helper Log (%lu runs, %lu entries)",
                   (unsigned long)reversedRuns.count, (unsigned long)flat.count]
                : @"Helper Log";
            [self.tableView reloadData];
            [self updateEmptyLabel];
            [self generateThumbnailsIfNeeded];
        });
    });
}

/// Parses a single log line into an EZLogEntry.
/// Expected format (written by EZHelperLog() in helpers.m):
///   [YYYY-MM-DD HH:MM:SS] [stageTag] message body
/// (Only TWO bracketed fields — there is no separate severity level in this
/// log; that's the system log's format, not the helper log's.)
/// Unknown formats are stored verbatim in body.
- (EZLogEntry *)parseLogLine:(NSString *)line {
    EZLogEntry *entry = [[EZLogEntry alloc] init];
    entry.raw         = line;

    // ── Structured parse: [timestamp] [stageTag] body ────────────────────────
    // We use a simple NSScanner-based approach to stay dependency-free.
    NSScanner *sc = [NSScanner scannerWithString:line];
    sc.charactersToBeSkipped = nil;

    NSString *timestamp = nil, *stageTag = nil, *body = nil;

    // Timestamp: "[2026-04-05 14:29:20]"
    if ([sc scanString:@"[" intoString:nil]) {
        [sc scanUpToString:@"]" intoString:&timestamp];
        [sc scanString:@"]" intoString:nil];
        [sc scanString:@" " intoString:nil];
    }

    // Stage tag: "[Stage1-Verdict]" / "[Stage2-Ranker]" / etc.
    if ([sc scanString:@"[" intoString:nil]) {
        [sc scanUpToString:@"]" intoString:&stageTag];
        [sc scanString:@"]" intoString:nil];
        [sc scanString:@" " intoString:nil];
    }

    // Remainder = body
    if (!sc.isAtEnd) {
        body = [line substringFromIndex:sc.scanLocation];
    }

    entry.timestamp = timestamp ?: @"";
    entry.stageTag  = stageTag.length ? stageTag : @"GENERAL";
    entry.body      = body.length ? body : line; // fallback to raw line

    // ── Pull "DECISION: <value>" off the first line of the body, if present
    // (written by _logHelperDecision in helpers.m) ────────────────────────────
    entry.decision = [self extractDecisionFromBody:entry.body];

    // ── Extract first file path mentioned in the body ─────────────────────────
    entry.filePath = [self extractFilePathFromString:entry.body];

    // ── Extract first chatKey (ISO-8601 thread key pattern) ───────────────────
    entry.chatKey  = [self extractChatKeyFromString:entry.body];

    return entry;
}

/// Pulls the value out of a leading "DECISION: <value>" line, e.g. the body
/// of a Stage1-ShortCircuit entry starts with "DECISION: SimpleDirectAnswer".
/// Returns nil if the body doesn't start with that prefix.
- (nullable NSString *)extractDecisionFromBody:(NSString *)body {
    static NSString * const kPrefix = @"DECISION: ";
    if (![body hasPrefix:kPrefix]) return nil;
    NSRange newlineRange = [body rangeOfString:@"\n"];
    NSString *firstLine = newlineRange.location == NSNotFound
        ? body
        : [body substringToIndex:newlineRange.location];
    return [firstLine substringFromIndex:kPrefix.length];
}

/// Returns the first path-like token in a string that exists on disk.
/// Looks for tokens starting with "/" or "~/" that end with a known extension
/// or at least look like absolute paths.
- (nullable NSString *)extractFilePathFromString:(NSString *)string {
    if (!string.length) return nil;

    // Supported attachment extensions (mirrors what EZCompleteUI generates)
    NSSet *imageExts = [NSSet setWithArray:@[
        @"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp",
        @"pdf", @"mp4", @"mov", @"m4a", @"mp3", @"wav",
        @"txt", @"json", @"csv", @"zip",
    ]];

    // Tokenise on whitespace/comma
    NSArray<NSString *> *tokens = [string componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@" ,;\"'()"]];

    for (NSString *raw in tokens) {
        NSString *tok = [raw stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!tok.length) continue;
        if (![tok hasPrefix:@"/"] && ![tok hasPrefix:@"~"]) continue;

        NSString *ext = tok.pathExtension.lowercaseString;
        if (ext.length && [imageExts containsObject:ext]) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:tok]) {
                return tok;
            }
        }
    }
    return nil;
}

/// Returns the first chatKey-style token (yyyy-MM-dd'T'HH-mm-ss) found in the
/// string, optionally with a .json suffix which is stripped.
- (nullable NSString *)extractChatKeyFromString:(NSString *)string {
    if (!string.length) return nil;

    // Regex: \d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}
    NSError *err = nil;
    NSRegularExpression *rx = [NSRegularExpression
        regularExpressionWithPattern:@"(\\d{4}-\\d{2}-\\d{2}T\\d{2}-\\d{2}-\\d{2})(\\.json)?"
                             options:0 error:&err];
    if (err || !rx) return nil;

    NSTextCheckingResult *match = [rx firstMatchInString:string
                                                 options:0
                                                   range:NSMakeRange(0, string.length)];
    if (!match) return nil;

    // Capture group 1 = the key without .json
    NSRange keyRange = [match rangeAtIndex:1];
    if (keyRange.location == NSNotFound) return nil;
    return [string substringWithRange:keyRange];
}

// ── Filter / search ───────────────────────────────────────────────────────────

- (void)applyFilter:(NSString *)term {
    self.searchTerm = term;
    if (!term.length) {
        self.displayedRuns = self.allRuns;
    } else {
        NSString *lower = term.lowercaseString;
        NSPredicate *matchPredicate = [NSPredicate predicateWithBlock:^BOOL(EZLogEntry *entry, NSDictionary *_) {
            return [entry.raw.lowercaseString containsString:lower];
        }];
        NSMutableArray<NSArray<EZLogEntry *> *> *filtered = [NSMutableArray array];
        for (NSArray<EZLogEntry *> *run in self.allRuns) {
            NSArray<EZLogEntry *> *matches = [run filteredArrayUsingPredicate:matchPredicate];
            if (matches.count) [filtered addObject:matches];
        }
        self.displayedRuns = filtered;
    }
    [self.tableView reloadData];
    [self updateEmptyLabel];
}

- (void)updateEmptyLabel {
    BOOL noData = self.displayedRuns.count == 0;
    self.emptyLabel.hidden  = !noData;
    self.tableView.hidden   = noData;
    if (noData) {
        self.emptyLabel.text = self.searchTerm.length
            ? @"No log entries match that filter."
            : @"Log file is empty or could not be read.";
    }
}

/// Finds where a given entry currently sits in displayedRuns (it may have
/// shifted sections under filtering), or nil if it isn't shown right now.
- (nullable NSIndexPath *)indexPathForDisplayedEntry:(EZLogEntry *)entry {
    for (NSUInteger s = 0; s < self.displayedRuns.count; s++) {
        NSUInteger r = [self.displayedRuns[s] indexOfObjectIdenticalTo:entry];
        if (r != NSNotFound) {
            return [NSIndexPath indexPathForRow:(NSInteger)r inSection:(NSInteger)s];
        }
    }
    return nil;
}

// ── Thumbnail generation ──────────────────────────────────────────────────────

- (void)generateThumbnailsIfNeeded {
    for (NSUInteger i = 0; i < self.allEntries.count; i++) {
        EZLogEntry *entry = self.allEntries[i];
        if (!entry.filePath.length) continue;
        if (self.thumbCache[@(i)]) continue;

        NSURL *fileURL = [NSURL fileURLWithPath:entry.filePath];
        QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc]
            initWithFileAtURL:fileURL
                         size:CGSizeMake(600, 320)
                        scale:[UIScreen mainScreen].scale
          representationTypes:QLThumbnailGenerationRequestRepresentationTypeAll];

        NSUInteger capturedIndex = i;
        __weak typeof(self) weakSelf = self;

        [QLThumbnailGenerator.sharedGenerator
            generateRepresentationsForRequest:req
            updateHandler:^(QLThumbnailRepresentation *thumb,
                            QLThumbnailRepresentationType type,
                            NSError *error) {
            UIImage *img = thumb.UIImage;
            if (!img || error) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.thumbCache[@(capturedIndex)] = img;

                EZLogEntry *e = strongSelf.allEntries[capturedIndex];
                NSIndexPath *ip = [strongSelf indexPathForDisplayedEntry:e];
                if (!ip) return;

                EZLogCell *cell = (EZLogCell *)[strongSelf.tableView cellForRowAtIndexPath:ip];
                [cell setThumbnailImage:img];
            });
        }];
    }
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)dismissSelf {
    [self requestCloseWithCompletion:nil];
}

- (void)requestCloseWithCompletion:(void (^)(void))completion {
    if (self.closeRequestHandler) {
        self.closeRequestHandler(completion);
        return;
    }
    [self dismissViewControllerAnimated:YES completion:completion];
}

- (void)refreshLog {
    self.thumbCache = [NSMutableDictionary dictionary];
    [self loadLog];
    [self showToast:@"🔄 Log refreshed"];
}

- (void)shareLog {
    NSString *path = [self logFilePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self showToast:@"⚠️ Log file not found"];
        return;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    UIActivityViewController *ac = [[UIActivityViewController alloc]
        initWithActivityItems:@[fileURL] applicationActivities:nil];
    ac.popoverPresentationController.barButtonItem = self.toolbarItems.firstObject;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)confirmClearLog {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Clear Log?"
                         message:@"All log entries will be permanently deleted."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *_) {
        [self clearLog];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearLog {
    NSString *path = [self logFilePath];
    NSError *err = nil;
    [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (err) {
        [self showToast:@"⚠️ Could not clear log"];
    } else {
        self.thumbCache   = [NSMutableDictionary dictionary];
        self.allEntries   = @[];
        self.allRuns      = @[];
        self.displayedRuns = @[];
        [self.tableView reloadData];
        [self updateEmptyLabel];
        [self showToast:@"🗑️ Log cleared"];
        EZLog(EZLogLevelInfo, @"HELPERLOG", @"Log file cleared by user");
    }
}

// ── UISearchBarDelegate ───────────────────────────────────────────────────────

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    [self applyFilter:text];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

// ── UITableViewDataSource ─────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.displayedRuns.count == 0) return 1; // empty state
    return (NSInteger)self.displayedRuns.count;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    if (self.displayedRuns.count == 0) return 1; // empty state row
    return (NSInteger)self.displayedRuns[(NSUInteger)section].count;
}

// ── Run status → color ────────────────────────────────────────────────────────
//
// Every entry in a run shares one header, so this is what makes "all the rows
// from the same ranked-memory-list run" read as one color: there's exactly
// one header per run, and its color is the run's outcome. See helpers.m,
// analyzePromptForContext, for exactly what each stageTag/decision means.

- (EZRunStatus)statusForRun:(NSArray<EZLogEntry *> *)run {
    for (EZLogEntry *e in run) {
        BOOL isStage1Family = [e.stageTag isEqualToString:@"Stage1-ShortCircuit"] ||
                               [e.stageTag isEqualToString:@"Stage1b-ShortCircuit"];
        if (isStage1Family && [e.decision isEqualToString:@"SimpleDirectAnswer"]) {
            return EZRunStatusApproved;
        }
    }
    for (EZLogEntry *e in run) {
        BOOL isValidatorDecision = [e.stageTag isEqualToString:@"Stage1-ValidatorDecision"] ||
                                    [e.stageTag isEqualToString:@"Stage1b-ValidatorDecision"];
        if (isValidatorDecision && [e.decision isEqualToString:@"Rejected"]) {
            return EZRunStatusRejected;
        }
    }
    return EZRunStatusNeutral;
}

- (UIColor *)colorForRunStatus:(EZRunStatus)status {
    switch (status) {
        case EZRunStatusApproved: return [UIColor systemGreenColor];
        case EZRunStatusRejected: return [UIColor systemRedColor];
        case EZRunStatusNeutral:  return [UIColor systemGrayColor];
    }
}

- (NSString *)labelForRunStatus:(EZRunStatus)status {
    switch (status) {
        case EZRunStatusApproved: return @"✓ VALIDATOR APPROVED";
        case EZRunStatusRejected: return @"✕ VALIDATOR REJECTED";
        case EZRunStatusNeutral:  return @"NO VALIDATOR VERDICT";
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (self.displayedRuns.count == 0) return nil;

    NSArray<EZLogEntry *> *run = self.displayedRuns[(NSUInteger)section];
    EZRunStatus status = [self statusForRun:run];
    UIColor *color = [self colorForRunStatus:status];
    EZLogEntry *first = run.firstObject;

    UIView *header = [[UIView alloc] init];
    header.backgroundColor = [color colorWithAlphaComponent:0.14];

    UIView *stripe = [[UIView alloc] init];
    stripe.backgroundColor = color;
    stripe.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:stripe];

    UILabel *label = [[UILabel alloc] init];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    label.font          = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    label.textColor      = color;
    label.numberOfLines  = 1;
    label.text = [NSString stringWithFormat:@"%@   %@   (%lu)",
                  first.timestamp.length ? first.timestamp : @"—",
                  [self labelForRunStatus:status],
                  (unsigned long)run.count];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [stripe.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [stripe.topAnchor     constraintEqualToAnchor:header.topAnchor],
        [stripe.bottomAnchor  constraintEqualToAnchor:header.bottomAnchor],
        [stripe.widthAnchor   constraintEqualToConstant:5],

        [label.leadingAnchor   constraintEqualToAnchor:stripe.trailingAnchor constant:14],
        [label.trailingAnchor  constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-14],
        [label.centerYAnchor   constraintEqualToAnchor:header.centerYAnchor],
    ]];

    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return self.displayedRuns.count == 0 ? 0 : 36;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    // ── Empty state ───────────────────────────────────────────────────────────
    if (self.displayedRuns.count == 0) {
        UITableViewCell *cell = [tableView
            dequeueReusableCellWithIdentifier:kLogEmptyCellID
                                 forIndexPath:indexPath];
        cell.textLabel.text      = self.searchTerm.length
            ? @"No entries match that filter."
            : @"Log file is empty.";
        cell.textLabel.textColor  = [UIColor secondaryLabelColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.userInteractionEnabled  = NO;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    // ── Log entry cell ────────────────────────────────────────────────────────
    EZLogCell *cell = [tableView dequeueReusableCellWithIdentifier:kLogCellID
                                                      forIndexPath:indexPath];
    EZLogEntry *entry = self.displayedRuns[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];

    // Map back to the flat allEntries index for thumb cache + tap-to-preview.
    NSUInteger allIdx = [self.allEntries indexOfObjectIdenticalTo:entry];
    if (allIdx == NSNotFound) allIdx = 0;

    [cell configureWithEntry:entry index:allIdx delegate:self];

    UIImage *cached = self.thumbCache[@(allIdx)];
    if (cached) [cell setThumbnailImage:cached];

    return cell;
}

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
}

// ── EZLogCellDelegate ─────────────────────────────────────────────────────────

/// Opens QLPreviewController for the file path embedded in this entry.
- (void)logCellDidTapFileAtIndex:(NSUInteger)index {
    if (index >= self.allEntries.count) return;
    NSString *path = self.allEntries[index].filePath;
    if (!path.length) return;

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self showToast:@"⚠️ File not found on disk"];
        return;
    }

    self.previewURL = [NSURL fileURLWithPath:path];
    QLPreviewController *ql = [[QLPreviewController alloc] init];
    ql.dataSource = self;
    ql.delegate   = self;
    [self presentViewController:ql animated:YES completion:nil];
}

/// Deep-links to the thread referenced by chatKey, mirroring the
/// MemoriesViewController approach: dismiss self first, then post notification.
- (void)logCellDidTapChatKey:(NSString *)chatKey {
    if (!chatKey.length) return;
    EZLog(EZLogLevelInfo, @"HELPERLOG",
          [NSString stringWithFormat:@"Opening thread from log deep-link: %@", chatKey]);

    [self requestCloseWithCompletion:^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"EZOpenChatThread"
                          object:nil
                        userInfo:@{ @"threadID" : chatKey }];
    }];
}

// ── QLPreviewControllerDataSource ─────────────────────────────────────────────

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return 1;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller
                    previewItemAtIndex:(NSInteger)index {
    return self.previewURL;
}

// ── Toast ─────────────────────────────────────────────────────────────────────

- (void)showToast:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *toast           = [[UILabel alloc] init];
        toast.adjustsFontSizeToFitWidth = YES;
        toast.minimumScaleFactor = 0.5;
        toast.text               = message;
        toast.font               = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        toast.textColor          = [UIColor whiteColor];
        toast.backgroundColor    = [UIColor colorWithWhite:0.1 alpha:0.88];
        toast.textAlignment      = NSTextAlignmentCenter;
        toast.layer.cornerRadius = 12;
        toast.clipsToBounds      = YES;
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:toast];
        [NSLayoutConstraint activateConstraints:@[
            [toast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [toast.bottomAnchor  constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
            [toast.widthAnchor   constraintGreaterThanOrEqualToConstant:200],
            [toast.heightAnchor  constraintEqualToConstant:42],
        ]];
        toast.alpha = 0;
        [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 1; }
                         completion:^(BOOL _) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 0; }
                                 completion:^(BOOL f) { [toast removeFromSuperview]; }];
            });
        }];
    });
}

@end
