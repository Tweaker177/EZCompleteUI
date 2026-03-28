// MemoriesViewController.m
// EZCompleteUI
//
// Displays, edits, and deletes saved AI memory entries from ezui_memories.json.
// Launched from SettingsViewController via "View / Edit Memories" button.

#import "MemoriesViewController.h"
#import "helpers.h"

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Cell
// ─────────────────────────────────────────────────────────────────────────────

@interface EZMemoryCell : UITableViewCell
@property (nonatomic, strong) UILabel *timestampLabel;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *attachmentBadge;
- (void)configureWithMemory:(NSDictionary *)memory;
@end

@implementation EZMemoryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _timestampLabel = [[UILabel alloc] init];
    _timestampLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _timestampLabel.textColor = [UIColor secondaryLabelColor];
    _timestampLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_timestampLabel];

    _summaryLabel = [[UILabel alloc] init];
    _summaryLabel.font = [UIFont systemFontOfSize:14];
    _summaryLabel.textColor = [UIColor labelColor];
    _summaryLabel.numberOfLines = 0;
    _summaryLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_summaryLabel];

    _attachmentBadge = [[UILabel alloc] init];
    _attachmentBadge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _attachmentBadge.textColor = [UIColor whiteColor];
    _attachmentBadge.backgroundColor = [UIColor systemTealColor];
    _attachmentBadge.text = @" 📎 attachment ";
    _attachmentBadge.layer.cornerRadius = 5;
    _attachmentBadge.clipsToBounds = YES;
    _attachmentBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_attachmentBadge];

    [NSLayoutConstraint activateConstraints:@[
        [_timestampLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
        [_timestampLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_timestampLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [_summaryLabel.topAnchor constraintEqualToAnchor:_timestampLabel.bottomAnchor constant:5],
        [_summaryLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_summaryLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],

        [_attachmentBadge.topAnchor constraintEqualToAnchor:_summaryLabel.bottomAnchor constant:6],
        [_attachmentBadge.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
        [_attachmentBadge.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
    ]];

    return self;
}

- (void)configureWithMemory:(NSDictionary *)memory {
    self.timestampLabel.text = memory[@"timestamp"] ?: @"";
    self.summaryLabel.text   = memory[@"summary"]   ?: @"(no summary)";

    NSArray *attachments = memory[@"attachmentPaths"];
    BOOL hasAttachment   = [attachments isKindOfClass:[NSArray class]] && attachments.count > 0;
    self.attachmentBadge.hidden = !hasAttachment;
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Private interface
// ─────────────────────────────────────────────────────────────────────────────

@interface MemoriesViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView            *tableView;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *memories;
@property (nonatomic, strong) UILabel                *emptyLabel;
@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation MemoriesViewController

static NSString * const kCellID = @"EZMemoryCell";

// ── Lifecycle ────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Memories";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.rightBarButtonItem = self.editButtonItem;

    [self setupTableView];
    [self setupEmptyLabel];
    [self loadMemories];
}

// ── Setup ────────────────────────────────────────────────────────────────────

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                  style:UITableViewStyleInsetGrouped];
    self.tableView.delegate   = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight  = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 90;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.tableView registerClass:[EZMemoryCell class] forCellReuseIdentifier:kCellID];
    [self.view addSubview:self.tableView];
}

- (void)setupEmptyLabel {
    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.emptyLabel.text = @"No memories saved yet.";
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont systemFontOfSize:16];
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
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"ezui_memory.json"];
}

- (void)loadMemories {
    self.memories = [NSMutableArray array];

    NSString *path = [self memoriesFilePath];
    NSData   *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        NSError *err = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if ([parsed isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)parsed) {
                if ([item isKindOfClass:[NSDictionary class]]) {
                    [self.memories addObject:[item mutableCopy]];
                }
            }
        }
    }

    // Newest first
    [self.memories sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *ta = a[@"timestamp"] ?: @"";
        NSString *tb = b[@"timestamp"] ?: @"";
        return [tb compare:ta];
    }];

    self.emptyLabel.hidden = (self.memories.count > 0);
    [self.tableView reloadData];
}

- (BOOL)persistMemories {
    // Sort chronologically before saving (oldest first, matching the original file order)
    NSMutableArray *toSave = [NSMutableArray array];
    for (NSMutableDictionary *m in self.memories) {
        [toSave addObject:[m copy]];
    }
    [toSave sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *ta = a[@"timestamp"] ?: @"";
        NSString *tb = b[@"timestamp"] ?: @"";
        return [ta compare:tb];
    }];

    NSError *err = nil;
    NSData  *data = [NSJSONSerialization dataWithJSONObject:toSave
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:&err];
    if (!data || err) {
        EZLog(EZLogLevelError, @"MEMORIES", @"Failed to serialize memories for save");
        return NO;
    }

    BOOL ok = [data writeToFile:[self memoriesFilePath] atomically:YES];
    if (!ok) {
        EZLog(EZLogLevelError, @"MEMORIES", @"Failed to write memories file");
    }
    return ok;
}

// ── UITableView editing mode toggle ─────────────────────────────────────────

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
}

// ── UITableViewDataSource ────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.memories.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EZMemoryCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID
                                                         forIndexPath:indexPath];
    [cell configureWithMemory:self.memories[(NSUInteger)indexPath.row]];
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView
titleForHeaderInSection:(NSInteger)section {
    if (self.memories.count == 0) return nil;
    return [NSString stringWithFormat:@"%lu saved %@",
            (unsigned long)self.memories.count,
            self.memories.count == 1 ? @"memory" : @"memories"];
}

// ── Swipe-to-delete ──────────────────────────────────────────────────────────

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;

    NSUInteger idx = (NSUInteger)indexPath.row;

    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Delete Memory?"
                         message:@"This memory entry will be permanently removed."
                  preferredStyle:UIAlertControllerStyleAlert];

    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
        [self.memories removeObjectAtIndex:idx];
        [tableView deleteRowsAtIndexPaths:@[indexPath]
                         withRowAnimation:UITableViewRowAnimationAutomatic];
        [self persistMemories];
        self.emptyLabel.hidden = (self.memories.count > 0);
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                 withRowAnimation:UITableViewRowAnimationNone];
        EZLog(EZLogLevelInfo, @"MEMORIES", @"Memory entry deleted");
    }]];

    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel
                                             handler:^(UIAlertAction *a) {
        // Deselect the row so it snaps back cleanly
        [tableView reloadRowsAtIndexPaths:@[indexPath]
                         withRowAnimation:UITableViewRowAnimationNone];
    }]];

    [self presentViewController:confirm animated:YES completion:nil];
}

// ── Tap row → Edit sheet ─────────────────────────────────────────────────────

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self showEditSheetForIndex:(NSUInteger)indexPath.row];
}

// ── Edit alert with text view ─────────────────────────────────────────────────

- (void)showEditSheetForIndex:(NSUInteger)index {
    NSMutableDictionary *memory = self.memories[index];
    NSString *currentSummary    = memory[@"summary"] ?: @"";
    NSString *timestamp         = memory[@"timestamp"] ?: @"";

    // Build a UIAlertController with a text field pre-filled with the summary.
    // For multiline editing we embed a UITextView inside a taller alert using
    // a standard UIAlertController with a text field (iOS-safe approach).

    UIAlertController *editor = [UIAlertController
        alertControllerWithTitle:@"Edit Memory"
                         message:[NSString stringWithFormat:@"%@\n\nSummary:", timestamp]
                  preferredStyle:UIAlertControllerStyleAlert];

    [editor addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text            = currentSummary;
        tf.font            = [UIFont systemFontOfSize:14];
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.returnKeyType   = UIReturnKeyDone;
    }];

    [editor addAction:[UIAlertAction actionWithTitle:@"Save"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        NSString *edited = editor.textFields.firstObject.text ?: @"";
        if (edited.length == 0) return;

        memory[@"summary"] = edited;
        BOOL ok = [self persistMemories];

        NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)index inSection:0];
        [self.tableView reloadRowsAtIndexPaths:@[ip]
                              withRowAnimation:UITableViewRowAnimationFade];

        if (!ok) {
            [self showToast:@"⚠️ Save failed"];
        } else {
            [self showToast:@"✅ Memory updated"];
            EZLog(EZLogLevelInfo, @"MEMORIES", @"Memory entry edited");
        }
    }]];

    [editor addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:editor animated:YES completion:nil];
}

// ── Toast helper ─────────────────────────────────────────────────────────────

- (void)showToast:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *toast        = [[UILabel alloc] init];
        toast.text            = message;
        toast.font            = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        toast.textColor       = [UIColor whiteColor];
        toast.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        toast.textAlignment   = NSTextAlignmentCenter;
        toast.layer.cornerRadius = 12;
        toast.clipsToBounds   = YES;
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:toast];

        [NSLayoutConstraint activateConstraints:@[
            [toast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [toast.bottomAnchor  constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
            [toast.widthAnchor   constraintGreaterThanOrEqualToConstant:180],
            [toast.heightAnchor  constraintEqualToConstant:40],
        ]];

        toast.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 1; } completion:^(BOOL done) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; }
                                 completion:^(BOOL f) { [toast removeFromSuperview]; }];
            });
        }];
    });
}

@end
