// MemoriesViewController.m
// EZCompleteUI
//
// Displays, edits, and deletes saved AI memory entries from ezui_memory.json.
// Features: inline editing, QLThumbnail previews, QuickLook, card cells.

#import "MemoriesViewController.h"
#import "helpers.h"
#import <QuickLook/QuickLook.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EZMemoryCell
// ─────────────────────────────────────────────────────────────────────────────

@protocol EZMemoryCellDelegate <NSObject>
- (void)cellDidEndEditingWithText:(NSString *)text atIndex:(NSUInteger)index;
- (void)cellDidTapAttachmentAtIndex:(NSUInteger)index;
- (void)cellDidTapTimestampAtIndex:(NSUInteger)index;
@end

@interface EZMemoryCell : UITableViewCell <UITextViewDelegate>

@property (nonatomic, strong) UILabel    *timestampLabel;
@property (nonatomic, strong) UITextView *summaryTextView;
@property (nonatomic, strong) UIImageView *attachmentThumb;
@property (nonatomic, strong) UILabel    *attachmentBadge;
@property (nonatomic, strong) UIButton   *attachmentButton;
@property (nonatomic, strong) UILabel    *editHintLabel;

// Toggled on/off depending on whether attachment exists
@property (nonatomic, strong) NSLayoutConstraint *thumbHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *summaryTopWithThumb;
@property (nonatomic, strong) NSLayoutConstraint *summaryTopNoThumb;
@property (nonatomic, strong) NSLayoutConstraint *badgeTopConstraint;

@property (nonatomic, weak)   id<EZMemoryCellDelegate> memoryDelegate;
@property (nonatomic, assign) NSUInteger memoryIndex;

- (void)configureWithMemory:(NSDictionary *)memory
                      index:(NSUInteger)index
                   delegate:(id<EZMemoryCellDelegate>)delegate;
- (void)setThumbnailImage:(UIImage *)image;

@end

@implementation EZMemoryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];

    // ── Card ─────────────────────────────────────────────────────────────────
    UIView *card = [[UIView alloc] init];
    card.tag = 999;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor     = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius  = 14;
    card.layer.borderWidth   = 1.0;
    card.layer.borderColor   = [UIColor separatorColor].CGColor;
    card.layer.shadowColor   = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.08;
    card.layer.shadowOffset  = CGSizeMake(0, 2);
    card.layer.shadowRadius  = 5;
    card.layer.masksToBounds = NO;
    [self.contentView addSubview:card];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor      constraintEqualToAnchor:self.contentView.topAnchor      constant:6],
        [card.bottomAnchor   constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-6],
        [card.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor  constant:12],
        [card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
    ]];

    // ── Timestamp — tappable link to source thread ────────────────────────────
    _timestampLabel = [[UILabel alloc] init];
    _timestampLabel.font      = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    _timestampLabel.textColor = [UIColor systemBlueColor];
    _timestampLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _timestampLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *tsTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(timestampTapped)];
    [_timestampLabel addGestureRecognizer:tsTap];
    [card addSubview:_timestampLabel];

    // ── Thumbnail ─────────────────────────────────────────────────────────────
    _attachmentThumb = [[UIImageView alloc] init];
    _attachmentThumb.translatesAutoresizingMaskIntoConstraints = NO;
    _attachmentThumb.contentMode        = UIViewContentModeScaleAspectFill;
    _attachmentThumb.clipsToBounds      = YES;
    _attachmentThumb.layer.cornerRadius = 8;
    _attachmentThumb.backgroundColor    = [UIColor tertiarySystemFillColor];
    _attachmentThumb.hidden             = YES;
    [card addSubview:_attachmentThumb];

    // ── Tap button over thumbnail ─────────────────────────────────────────────
    _attachmentButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _attachmentButton.translatesAutoresizingMaskIntoConstraints = NO;
    _attachmentButton.hidden = YES;
    [_attachmentButton addTarget:self action:@selector(attachmentTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:_attachmentButton];

    // ── Badge (teal pill, shown while thumb loading or as fallback) ───────────
    _attachmentBadge = [[UILabel alloc] init];
    _attachmentBadge.font              = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _attachmentBadge.textColor         = [UIColor whiteColor];
    _attachmentBadge.backgroundColor   = [UIColor systemTealColor];
    _attachmentBadge.text              = @"  📎  Tap to preview attachment  ";
    _attachmentBadge.layer.cornerRadius = 8;
    _attachmentBadge.clipsToBounds     = YES;
    _attachmentBadge.hidden            = YES;
    _attachmentBadge.userInteractionEnabled = YES;
    _attachmentBadge.translatesAutoresizingMaskIntoConstraints = NO;
    UITapGestureRecognizer *badgeTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(attachmentTapped)];
    [_attachmentBadge addGestureRecognizer:badgeTap];
    [card addSubview:_attachmentBadge];

    // ── Summary text view ─────────────────────────────────────────────────────
    _summaryTextView = [[UITextView alloc] init];
    _summaryTextView.font             = [UIFont systemFontOfSize:15];
    _summaryTextView.textColor        = [UIColor labelColor];
    _summaryTextView.backgroundColor  = [UIColor clearColor];
    _summaryTextView.scrollEnabled    = NO;
    _summaryTextView.delegate         = self;
    _summaryTextView.textContainerInset = UIEdgeInsetsZero;
    _summaryTextView.textContainer.lineFragmentPadding = 0;
    _summaryTextView.translatesAutoresizingMaskIntoConstraints = NO;

    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    UIBarButtonItem *flex    = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(dismissKeyboard)];
    toolbar.items = @[flex, doneBtn];
    _summaryTextView.inputAccessoryView = toolbar;
    [card addSubview:_summaryTextView];

    // ── Edit hint — bold and obvious ──────────────────────────────────────────
    _editHintLabel = [[UILabel alloc] init];
    _editHintLabel.text            = @"✏️ Tap summary to edit";
    _editHintLabel.font            = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _editHintLabel.textColor       = [UIColor systemBlueColor];
    _editHintLabel.alpha           = 0.7;
    _editHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_editHintLabel];

    // ── Static constraints ────────────────────────────────────────────────────
    [NSLayoutConstraint activateConstraints:@[
        // Timestamp
        [_timestampLabel.topAnchor      constraintEqualToAnchor:card.topAnchor      constant:12],
        [_timestampLabel.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor  constant:14],
        [_timestampLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],

        // Thumbnail — pinned left/right, zero height when hidden (toggled below)
        [_attachmentThumb.topAnchor      constraintEqualToAnchor:_timestampLabel.bottomAnchor constant:10],
        [_attachmentThumb.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor  constant:14],
        [_attachmentThumb.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],

        // Tap button covers thumbnail exactly
        [_attachmentButton.topAnchor      constraintEqualToAnchor:_attachmentThumb.topAnchor],
        [_attachmentButton.bottomAnchor   constraintEqualToAnchor:_attachmentThumb.bottomAnchor],
        [_attachmentButton.leadingAnchor  constraintEqualToAnchor:_attachmentThumb.leadingAnchor],
        [_attachmentButton.trailingAnchor constraintEqualToAnchor:_attachmentThumb.trailingAnchor],

        // Badge below timestamp, same vertical position as thumb top
        [_attachmentBadge.topAnchor     constraintEqualToAnchor:_timestampLabel.bottomAnchor constant:10],
        [_attachmentBadge.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [_attachmentBadge.heightAnchor  constraintEqualToConstant:34],

        // Summary trailing/leading fixed
        [_summaryTextView.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor  constant:14],
        [_summaryTextView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],

        // Edit hint
        [_editHintLabel.topAnchor      constraintEqualToAnchor:_summaryTextView.bottomAnchor constant:6],
        [_editHintLabel.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor  constant:14],
        [_editHintLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [_editHintLabel.bottomAnchor   constraintEqualToAnchor:card.bottomAnchor   constant:-12],
    ]];

    // ── Dynamic constraints (toggled in configure) ────────────────────────────
    // Thumb height: 180 when shown, 0 when hidden
    _thumbHeightConstraint = [_attachmentThumb.heightAnchor constraintEqualToConstant:0];
    _thumbHeightConstraint.active = YES;

    // Summary top: either below thumb (with attachment) or below timestamp (without)
    _summaryTopWithThumb = [_summaryTextView.topAnchor
        constraintEqualToAnchor:_attachmentThumb.bottomAnchor constant:10];
    _summaryTopNoThumb = [_summaryTextView.topAnchor
        constraintEqualToAnchor:_timestampLabel.bottomAnchor constant:10];
    _summaryTopNoThumb.active = YES;

    return self;
}

- (void)configureWithMemory:(NSDictionary *)memory
                      index:(NSUInteger)index
                   delegate:(id<EZMemoryCellDelegate>)delegate {
    self.memoryIndex    = index;
    self.memoryDelegate = delegate;

    NSString *ts = memory[@"timestamp"] ?: @"";
    self.timestampLabel.text  = ts.length ? ts : @"No timestamp";
    self.summaryTextView.text = memory[@"summary"] ?: @"(no summary)";

    NSArray *attachments = memory[@"attachmentPaths"];
    BOOL hasAttachment = [attachments isKindOfClass:[NSArray class]] && attachments.count > 0;

    // Reset thumb
    self.attachmentThumb.image   = nil;
    self.attachmentThumb.hidden  = YES;
    self.attachmentButton.hidden = YES;

    if (hasAttachment) {
        // Show badge while thumb generates; reserve 180pt for thumb area
        self.attachmentBadge.hidden       = NO;
        self.thumbHeightConstraint.constant = 180;
        self.summaryTopWithThumb.active   = YES;
        self.summaryTopNoThumb.active     = NO;
    } else {
        self.attachmentBadge.hidden       = YES;
        self.thumbHeightConstraint.constant = 0;
        self.summaryTopWithThumb.active   = NO;
        self.summaryTopNoThumb.active     = YES;
    }
}

- (void)setThumbnailImage:(UIImage *)image {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!image) return;
        self.attachmentThumb.image   = image;
        self.attachmentThumb.hidden  = NO;
        self.attachmentButton.hidden = NO;
        self.attachmentBadge.hidden  = YES;
    });
}

- (void)timestampTapped {
    [self.memoryDelegate cellDidTapTimestampAtIndex:self.memoryIndex];
}

- (void)attachmentTapped {
    [self.memoryDelegate cellDidTapAttachmentAtIndex:self.memoryIndex];
}

- (void)dismissKeyboard {
    [self.summaryTextView resignFirstResponder];
}

// ── UITextViewDelegate ───────────────────────────────────────────────────────

- (void)textViewDidBeginEditing:(UITextView *)textView {
    UIView *card = [self.contentView viewWithTag:999];
    card.layer.borderColor = [UIColor systemBlueColor].CGColor;
    card.layer.borderWidth = 2.0;
    self.editHintLabel.text  = @"✏️ Editing — Done to save";
    self.editHintLabel.alpha = 1.0;
}

- (void)textViewDidEndEditing:(UITextView *)textView {
    UIView *card = [self.contentView viewWithTag:999];
    card.layer.borderColor = [UIColor separatorColor].CGColor;
    card.layer.borderWidth = 1.0;
    self.editHintLabel.text  = @"✏️ Tap summary to edit";
    self.editHintLabel.alpha = 0.7;
    [self.memoryDelegate cellDidEndEditingWithText:textView.text atIndex:self.memoryIndex];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MemoriesViewController
// ─────────────────────────────────────────────────────────────────────────────

@interface MemoriesViewController () <UITableViewDelegate,
                                      UITableViewDataSource,
                                      UISearchBarDelegate,
                                      EZMemoryCellDelegate,
                                      QLPreviewControllerDataSource,
                                      QLPreviewControllerDelegate>

@property (nonatomic, strong) NSArray<NSMutableDictionary *> *displayedMemories;


@property (nonatomic, strong) UITableView  *tableView;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *memories;
@property (nonatomic, copy) NSString *searchTerm;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UILabel      *emptyLabel;
@property (nonatomic, strong) NSURL        *previewURL;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIImage *> *thumbCache;

@end

@implementation MemoriesViewController

static NSString * const kCellID = @"EZMemoryCell";
static NSString * const kEmptyCellID = @"EZMemoryEmptyCell";

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Memories";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.thumbCache = [NSMutableDictionary dictionary];
    UIBarButtonItem *searchItem = nil;
    if (@available(iOS 13.0, *)) {
        searchItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]
                                                      style:UIBarButtonItemStylePlain
                                                     target:self
                                                     action:@selector(focusSearch)];
    } else {
        searchItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch
                                                                   target:self
                                                                   action:@selector(focusSearch)];
    }
    self.navigationItem.leftBarButtonItem = searchItem;
    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItems = @[closeItem, self.editButtonItem];
    [self setupTableView];
    [self setupSearchBar];
    [self setupEmptyLabel];
    [self loadMemories];
}

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStyleInsetGrouped];
    self.tableView.delegate           = self;
    self.tableView.dataSource         = self;
    self.tableView.rowHeight          = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 120;
    self.tableView.separatorStyle     = UITableViewCellSeparatorStyleNone;
    self.tableView.autoresizingMask   = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.tableView registerClass:[EZMemoryCell class] forCellReuseIdentifier:kCellID];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kEmptyCellID];
    [self.view addSubview:self.tableView];
}

- (void)setupSearchBar {
    if (self.searchBar) return;
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.searchBar.placeholder = @"Search memories";
    self.searchBar.delegate = self;
    self.searchBar.showsCancelButton = NO;
    self.tableView.tableHeaderView = self.searchBar;
}

- (void)setupEmptyLabel {
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text          = @"No memories saved yet.";
    self.emptyLabel.textColor     = [UIColor secondaryLabelColor];
    self.emptyLabel.font          = [UIFont systemFontOfSize:16];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

// ── Data ─────────────────────────────────────────────────────────────────────

- (NSString *)memoriesFilePath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"ezui_memory.json"];
}

- (void)loadMemories {
    self.memories = [NSMutableArray array];
    NSData *data = [NSData dataWithContentsOfFile:[self memoriesFilePath]];
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)parsed) {
                if ([item isKindOfClass:[NSDictionary class]])
                    [self.memories addObject:[item mutableCopy]];
            }
        }
    }
    [self.memories sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(b[@"timestamp"] ?: @"") compare:(a[@"timestamp"] ?: @"")];
    }];
    if (!self.searchTerm) self.searchTerm = @"";
    [self applyMemorySearch:self.searchTerm];
    [self generateThumbnailsIfNeeded];
}

- (void)applyMemorySearch:(NSString *)term {
    NSString *trimmed = [term stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.searchTerm = trimmed;
    self.searchBar.text = trimmed;
    if (trimmed.length == 0) {
        self.displayedMemories = [self.memories copy];
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *memory, NSDictionary *bindings) {
            NSString *summary = memory[@"summary"] ?: @"";
            return [summary rangeOfString:trimmed options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        self.displayedMemories = [self.memories filteredArrayUsingPredicate:predicate];
    }
    BOOL hasResults = self.displayedMemories.count > 0;
    self.emptyLabel.hidden = hasResults;
    if (!hasResults) {
        self.emptyLabel.text = trimmed.length ? @"No memories match that search." : @"No memories saved yet.";
    }
    [self.tableView reloadData];
}

- (void)focusSearch {
    CGPoint topOffset = CGPointMake(0, -self.tableView.adjustedContentInset.top);
    [self.tableView setContentOffset:topOffset animated:NO];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.searchBar becomeFirstResponder];
    });
}

- (void)dismissSelf {
    [self requestCloseWithCompletion:nil];
}

- (void)requestCloseWithCompletion:(dispatch_block_t)completion {
    if (self.closeRequestHandler) {
        self.closeRequestHandler(completion);
        return;
    }
    [self dismissViewControllerAnimated:YES completion:completion];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applyMemorySearch:searchText];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (BOOL)persistMemories {
    NSMutableArray *toSave = [NSMutableArray array];
    for (NSMutableDictionary *m in self.memories) [toSave addObject:[m copy]];
    [toSave sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(a[@"timestamp"] ?: @"") compare:(b[@"timestamp"] ?: @"")];
    }];
    NSData *data = [NSJSONSerialization dataWithJSONObject:toSave
                                                   options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) { EZLog(EZLogLevelError, @"MEMORIES", @"Serialize failed"); return NO; }
    BOOL ok = [data writeToFile:[self memoriesFilePath] atomically:YES];
    if (!ok) EZLog(EZLogLevelError, @"MEMORIES", @"Write failed");
    return ok;
}

// ── Thumbnails ────────────────────────────────────────────────────────────────

- (void)generateThumbnailsIfNeeded {
    for (NSUInteger i = 0; i < self.memories.count; i++) {
        NSArray *paths = self.memories[i][@"attachmentPaths"];
        if (![paths isKindOfClass:[NSArray class]] || paths.count == 0) continue;
        if (self.thumbCache[@(i)]) continue;

        NSURL *fileURL = [NSURL fileURLWithPath:paths.firstObject];
        QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc]
            initWithFileAtURL:fileURL
                         size:CGSizeMake(600, 360)
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
            NSMutableDictionary *memory = strongSelf.memories[capturedIndex];
            NSInteger row = [strongSelf.displayedMemories indexOfObjectIdenticalTo:memory];
            if (row == NSNotFound) return;
            NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)row inSection:0];
            EZMemoryCell *cell = (EZMemoryCell *)[strongSelf.tableView cellForRowAtIndexPath:ip];
            [cell setThumbnailImage:img];
        });
        }];
    }
}

// ── Editing mode ──────────────────────────────────────────────────────────────

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
}

// ── UITableViewDataSource ────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    if (self.displayedMemories.count == 0) return 1;
    return (NSInteger)self.displayedMemories.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.displayedMemories.count == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kEmptyCellID
                                                                forIndexPath:indexPath];
        if (@available(iOS 14.0, *)) {
            UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
            if (self.searchTerm.length > 0) {
                cfg.text = @"No memories match that search.";
            } else {
                cfg.text = @"No memories saved yet.";
            }
            cfg.textProperties.color = [UIColor secondaryLabelColor];
            cell.contentConfiguration = cfg;
        } else {
            if (self.searchTerm.length > 0) {
                cell.textLabel.text = @"No memories match that search.";
            } else {
                cell.textLabel.text = @"No memories saved yet.";
            }
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
        }
        cell.userInteractionEnabled = NO;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    EZMemoryCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID
                                                         forIndexPath:indexPath];
    NSUInteger displayedIndex = (NSUInteger)indexPath.row;
    NSMutableDictionary *memory = self.displayedMemories[displayedIndex];
    NSUInteger actualIndex = [self.memories indexOfObjectIdenticalTo:memory];
    if (actualIndex == NSNotFound) actualIndex = displayedIndex;
    [cell configureWithMemory:memory index:actualIndex delegate:self];
    UIImage *cached = self.thumbCache[@(actualIndex)];
    if (cached) [cell setThumbnailImage:cached];
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView
titleForHeaderInSection:(NSInteger)section {
    if (self.memories.count == 0) return nil;
    if (self.searchTerm.length > 0) {
        return [NSString stringWithFormat:@"%lu matching %@",
                (unsigned long)self.displayedMemories.count,
                self.displayedMemories.count == 1 ? @"memory" : @"memories"];
    }
    return [NSString stringWithFormat:@"%lu saved %@",
            (unsigned long)self.memories.count,
            self.memories.count == 1 ? @"memory" : @"memories"];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (self.displayedMemories.count == 0) return;
    NSMutableDictionary *memory = self.displayedMemories[(NSUInteger)indexPath.row];
    NSUInteger idx = [self.memories indexOfObjectIdenticalTo:memory];
    if (idx == NSNotFound) return;

    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Delete Memory?"
                         message:@"This entry will be permanently removed."
                  preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
        [self.memories removeObjectAtIndex:idx];
        NSMutableDictionary *rebuilt = [NSMutableDictionary dictionary];
        [self.thumbCache enumerateKeysAndObjectsUsingBlock:
            ^(NSNumber *key, UIImage *img, BOOL *stop) {
            NSUInteger k = key.unsignedIntegerValue;
            if (k < idx)      rebuilt[@(k)]     = img;
            else if (k > idx) rebuilt[@(k - 1)] = img;
        }];
        self.thumbCache = rebuilt;
        [self persistMemories];
        [self applyMemorySearch:self.searchTerm ?: @""];
        EZLog(EZLogLevelInfo, @"MEMORIES", @"Memory entry deleted");
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel
                                             handler:^(UIAlertAction *a) {
        [tableView reloadRowsAtIndexPaths:@[indexPath]
                         withRowAnimation:UITableViewRowAnimationNone];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
}

// ── EZMemoryCellDelegate ─────────────────────────────────────────────────────

- (void)cellDidEndEditingWithText:(NSString *)text atIndex:(NSUInteger)index {
    if (index >= self.memories.count) return;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;
    self.memories[index][@"summary"] = trimmed;
    BOOL ok = [self persistMemories];
    [self applyMemorySearch:self.searchTerm ?: @""];
    [self showToast:ok ? @"✅ Memory updated" : @"⚠️ Save failed"];
    if (ok) EZLog(EZLogLevelInfo, @"MEMORIES", @"Memory entry edited inline");
}

- (void)cellDidTapAttachmentAtIndex:(NSUInteger)index {
    if (index >= self.memories.count) return;
    NSArray *paths = self.memories[index][@"attachmentPaths"];
    if (![paths isKindOfClass:[NSArray class]] || paths.count == 0) return;
    NSString *filePath = paths.firstObject;
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        [self showToast:@"⚠️ Attachment file not found"];
        return;
    }
    self.previewURL = [NSURL fileURLWithPath:filePath];
    QLPreviewController *ql = [[QLPreviewController alloc] init];
    ql.dataSource = self;
    ql.delegate   = self;
    [self presentViewController:ql animated:YES completion:nil];
}

// ── Thread navigation ─────────────────────────────────────────────────────────

/// Converts a memory entry to the thread filename key (without .json extension).
/// Strategy:
///   1. Use the stored "chatKey" field if present — it is already the raw
///      ISO-8601-style key used as the filename, e.g. "2026-04-05T14-29-20".
///   2. Fall back to parsing the display timestamp string by re-formatting it
///      through NSDateFormatter so we produce the same "yyyy-MM-dd'T'HH-mm-ss"
///      pattern the app uses when naming thread files.
- (nullable NSString *)threadIDFromMemory:(NSDictionary *)memory {

    // ── Preferred path: chatKey stored directly on the memory entry ───────────
    NSString *chatKey = memory[@"chatKey"];
    if (chatKey.length > 0) {
        // Strip .json suffix if someone stored it with the extension
        if ([chatKey hasSuffix:@".json"]) {
            chatKey = [chatKey substringToIndex:chatKey.length - 5];
        }
        return chatKey;
    }

    // ── Fallback: derive from the display timestamp string ────────────────────
    // The display format written by EZCompleteUI is, for example:
    //   "Apr 5, 2026 at 2:29 PM"  (MMM d, yyyy 'at' h:mm a)
    // Thread filenames use:
    //   "2026-04-05T14-29-20"     (yyyy-MM-dd'T'HH-mm-ss)
    // We parse with a loose formatter, then reformat to the filename pattern.
    // Seconds are unknown from the display string so we default to "00".
    NSString *displayTS = memory[@"timestamp"];
    if (!displayTS.length) return nil;

    NSDateFormatter *parser = [[NSDateFormatter alloc] init];
    parser.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

    // Try common display formats the app may have written
    NSArray<NSString *> *inputFormats = @[
        @"MMM d, yyyy 'at' h:mm a",
        @"MMM d, yyyy 'at' h:mm:ss a",
        @"yyyy-MM-dd'T'HH:mm:ss",
        @"yyyy-MM-dd'T'HH-mm-ss",
    ];

    NSDate *parsed = nil;
    for (NSString *fmt in inputFormats) {
        parser.dateFormat = fmt;
        parsed = [parser dateFromString:displayTS];
        if (parsed) break;
    }
    if (!parsed) {
        EZLog(EZLogLevelWarning, @"MEMORIES", [NSString stringWithFormat:@"Could not parse timestamp for thread nav: %@", displayTS]);
        return nil;
    }

    NSDateFormatter *writer = [[NSDateFormatter alloc] init];
    writer.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    writer.dateFormat = @"yyyy-MM-dd'T'HH-mm-ss";
    return [writer stringFromDate:parsed];
}

- (void)cellDidTapTimestampAtIndex:(NSUInteger)index {
    if (index >= self.memories.count) return;
    NSDictionary *memory = self.memories[index];

    NSString *threadID = [self threadIDFromMemory:memory];
    if (!threadID.length) {
        [self showToast:@"⚠️ Cannot locate source thread"];
        EZLog(EZLogLevelWarning, @"MEMORIES", [NSString stringWithFormat:@"Timestamp tap — no threadID for index %lu", (unsigned long)index]);
        return;
    }

    EZLog(EZLogLevelInfo, @"MEMORIES",[NSString stringWithFormat:@"Opening source thread: %@", threadID]);

    // MemoriesViewController is presented modally inside a UINavigationController.
    // We must dismiss the whole modal stack first, then post the notification inside
    // the completion block — that way ViewController is fully visible and on-screen
    // before it receives the notification and loads the thread.
    [self requestCloseWithCompletion:^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"EZOpenChatThread"
                          object:nil
                        userInfo:@{ @"threadID" : threadID }];
    }];
}

// ── QLPreviewControllerDataSource ────────────────────────────────────────────

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
                         completion:^(BOOL done) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 0; }
                                 completion:^(BOOL f) { [toast removeFromSuperview]; }];
            });
        }];
    });
}

@end
