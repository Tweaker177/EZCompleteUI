// HelperLogViewController.m
// EZCompleteUI
//
// Displays the full ezui_helpers.log in a card-based table view.
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
#import <QuickLook/QuickLook.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Parsed log entry model
// ─────────────────────────────────────────────────────────────────────────────

/// A single parsed line from ezui_helpers.log.
@interface EZLogEntry : NSObject
@property (nonatomic, copy)   NSString        *raw;          // full original line
@property (nonatomic, copy)   NSString        *timestamp;    // e.g. "2026-04-05 14:29:20"
@property (nonatomic, copy)   NSString        *level;        // "INFO" / "WARN" / "ERROR" / "DEBUG"
@property (nonatomic, copy)   NSString        *tag;          // e.g. "MEMORIES"
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
    _levelBadge.font              = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
    _levelBadge.textColor         = [UIColor whiteColor];
    _levelBadge.textAlignment     = NSTextAlignmentCenter;
    _levelBadge.layer.cornerRadius = 5;
    _levelBadge.clipsToBounds     = YES;
    _levelBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_levelBadge];

    _tagLabel = [[UILabel alloc] init];
    _tagLabel.font      = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
    _tagLabel.textColor = [UIColor secondaryLabelColor];
    _tagLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_tagLabel];

    _timestampLabel = [[UILabel alloc] init];
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
    _thumbButton.hidden = YES;
    [_thumbButton addTarget:self action:@selector(thumbTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:_thumbButton];

    _thumbBadge = [[UILabel alloc] init];
    _thumbBadge.font              = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _thumbBadge.textColor         = [UIColor whiteColor];
    _thumbBadge.backgroundColor   = [UIColor systemTealColor];
    _thumbBadge.text              = @"  📎  Tap to preview  ";
    _thumbBadge.layer.cornerRadius = 7;
    _thumbBadge.clipsToBounds     = YES;
    _thumbBadge.hidden            = YES;
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

    // Level badge colour
    self.levelBadge.text = [NSString stringWithFormat:@" %@ ", entry.level ?: @"LOG"];
    UIColor *badgeColor = [UIColor systemGrayColor];
    if ([entry.level isEqualToString:@"ERROR"])   badgeColor = [UIColor systemRedColor];
    else if ([entry.level isEqualToString:@"WARN"])  badgeColor = [UIColor systemOrangeColor];
    else if ([entry.level isEqualToString:@"INFO"])  badgeColor = [UIColor systemGreenColor];
    else if ([entry.level isEqualToString:@"DEBUG"]) badgeColor = [UIColor systemBlueColor];
    self.levelBadge.backgroundColor = badgeColor;

    self.tagLabel.text       = entry.tag.length ? [NSString stringWithFormat:@"[%@]", entry.tag] : @"";
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

- (NSAttributedString *)attributedBodyForEntry:(EZLogEntry *)entry {
    NSString *body = entry.body ?: @"";
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc]
        initWithString:body
            attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:13],
                NSForegroundColorAttributeName: [UIColor labelColor],
            }];

    // Highlight chatKey as a tappable link (custom URL scheme "ezchat://")
    if (entry.chatKey.length > 0) {
        NSRange range = [body rangeOfString:entry.chatKey];
        if (range.location != NSNotFound) {
            NSString *urlStr = [NSString stringWithFormat:@"ezchat://%@", entry.chatKey];
            [attr addAttributes:@{
                NSForegroundColorAttributeName: [UIColor systemBlueColor],
                NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
                NSLinkAttributeName: [NSURL URLWithString:urlStr],
            } range:range];
        }
    }

    return [attr copy];
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

- (BOOL)textView:(UITextView *)textView
    shouldInteractWithURL:(NSURL *)URL
                  inRange:(NSRange)characterRange
              interaction:(UITextItemInteraction)interaction {
    if ([URL.scheme isEqualToString:@"ezchat"]) {
        NSString *key = URL.host; // chatKey lives in the host portion
        if (key.length) [self.logDelegate logCellDidTapChatKey:key];
        return NO;
    }
    return YES;
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HelperLogViewController
// ─────────────────────────────────────────────────────────────────────────────

@interface HelperLogViewController () <UITableViewDelegate,
                                       UITableViewDataSource,
                                       UISearchBarDelegate,
                                       EZLogCellDelegate,
                                       QLPreviewControllerDataSource,
                                       QLPreviewControllerDelegate>

@property (nonatomic, strong) UITableView   *tableView;
@property (nonatomic, strong) UISearchBar   *searchBar;
@property (nonatomic, strong) UILabel       *emptyLabel;

/// Full parsed entries from log file
@property (nonatomic, strong) NSArray<EZLogEntry *> *allEntries;
/// Filtered subset shown in table
@property (nonatomic, strong) NSArray<EZLogEntry *> *displayedEntries;

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
    NSString *jbPath = @"/var/mobile/Documents/ezui_helpers.log";
    if ([[NSFileManager defaultManager] fileExistsAtPath:jbPath]) {
        return jbPath;
    }
    NSString *docs = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [docs stringByAppendingPathComponent:@"ezui_helpers.log"];
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
    self.navigationItem.rightBarButtonItem = closeItem;

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
            for (NSString *line in lines) {
                NSString *trimmed = [line stringByTrimmingCharactersInSet:
                                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (!trimmed.length) continue;
                [entries addObject:[self parseLogLine:trimmed]];
            }
        }

        // Show newest first (reverse chronological)
        NSArray<EZLogEntry *> *reversed = [[entries reverseObjectEnumerator] allObjects];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.allEntries       = reversed;
            self.displayedEntries = reversed;
            [self.tableView reloadData];
            [self updateEmptyLabel];
            [self generateThumbnailsIfNeeded];
        });
    });
}

/// Parses a single log line into an EZLogEntry.
/// Expected format (written by EZLog macro in helpers.h):
///   [YYYY-MM-DD HH:MM:SS] [LEVEL] [TAG] message body
/// Unknown formats are stored verbatim in body.
- (EZLogEntry *)parseLogLine:(NSString *)line {
    EZLogEntry *entry = [[EZLogEntry alloc] init];
    entry.raw         = line;

    // ── Try structured parse: [timestamp] [LEVEL] [TAG] body ─────────────────
    // Pattern: starts with [date time] [LEVEL] [TAG] …
    // We use a simple NSScanner-based approach to stay dependency-free.
    NSScanner *sc = [NSScanner scannerWithString:line];
    sc.charactersToBeSkipped = nil;

    NSString *timestamp = nil, *level = nil, *tag = nil, *body = nil;

    // Timestamp: "[2026-04-05 14:29:20]"
    if ([sc scanString:@"[" intoString:nil]) {
        [sc scanUpToString:@"]" intoString:&timestamp];
        [sc scanString:@"]" intoString:nil];
        [sc scanString:@" " intoString:nil];
    }

    // Level: "[INFO]" / "[ERROR]" etc.
    if ([sc scanString:@"[" intoString:nil]) {
        [sc scanUpToString:@"]" intoString:&level];
        [sc scanString:@"]" intoString:nil];
        [sc scanString:@" " intoString:nil];
    }

    // Tag: "[MEMORIES]"
    if ([sc scanString:@"[" intoString:nil]) {
        [sc scanUpToString:@"]" intoString:&tag];
        [sc scanString:@"]" intoString:nil];
        [sc scanString:@" " intoString:nil];
    }

    // Remainder = body
    if (!sc.isAtEnd) {
        body = [line substringFromIndex:sc.scanLocation];
    }

    entry.timestamp = timestamp ?: @"";
    entry.level     = level.uppercaseString ?: @"LOG";
    entry.tag       = tag ?: @"";
    entry.body      = body.length ? body : line; // fallback to raw line

    // ── Extract first file path mentioned in the body ─────────────────────────
    entry.filePath = [self extractFilePathFromString:entry.body];

    // ── Extract first chatKey (ISO-8601 thread key pattern) ───────────────────
    entry.chatKey  = [self extractChatKeyFromString:entry.body];

    return entry;
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
        self.displayedEntries = self.allEntries;
    } else {
        NSString *lower = term.lowercaseString;
        self.displayedEntries = [self.allEntries filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(EZLogEntry *entry, NSDictionary *_) {
                return [entry.raw.lowercaseString containsString:lower];
            }]];
    }
    [self.tableView reloadData];
    [self updateEmptyLabel];
}

- (void)updateEmptyLabel {
    BOOL noData = self.displayedEntries.count == 0;
    self.emptyLabel.hidden  = !noData;
    self.tableView.hidden   = noData;
    if (noData) {
        self.emptyLabel.text = self.searchTerm.length
            ? @"No log entries match that filter."
            : @"Log file is empty or could not be read.";
    }
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

                // Find the row in displayedEntries that matches this allEntries entry
                EZLogEntry *e = strongSelf.allEntries[capturedIndex];
                NSUInteger row = [strongSelf.displayedEntries indexOfObjectIdenticalTo:e];
                if (row == NSNotFound) return;

                NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)row inSection:0];
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
        self.displayedEntries = @[];
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    if (self.displayedEntries.count == 0) return 1; // empty state row
    return (NSInteger)self.displayedEntries.count;
}

- (NSString *)tableView:(UITableView *)tableView
titleForHeaderInSection:(NSInteger)section {
    if (self.allEntries.count == 0) return nil;
    NSString *suffix = self.searchTerm.length
        ? [NSString stringWithFormat:@"%lu matching / %lu total",
           (unsigned long)self.displayedEntries.count,
           (unsigned long)self.allEntries.count]
        : [NSString stringWithFormat:@"%lu entries (newest first)",
           (unsigned long)self.allEntries.count];
    return suffix;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    // ── Empty state ───────────────────────────────────────────────────────────
    if (self.displayedEntries.count == 0) {
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
    NSUInteger displayRow = (NSUInteger)indexPath.row;
    EZLogEntry *entry = self.displayedEntries[displayRow];

    // Map displayedEntries row back to allEntries index for thumb cache
    NSUInteger allIdx = [self.allEntries indexOfObjectIdenticalTo:entry];
    if (allIdx == NSNotFound) allIdx = displayRow;

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
