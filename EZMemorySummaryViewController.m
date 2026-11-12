// EZMemorySummaryViewController.m
// EZCompleteUI
//
// Lists the important-memories store in file order (oldest first — the
// same order the facts ride in the always-in-context block on chat
// sends, and the order the store's index-based CRUD expects).
// Deliberately a sibling of MemoriesViewController: same card look,
// same inline tap-to-edit, same Edit-mode deletion with a
// confirmation — but backed by helpers' important-store functions
// (EZImportantMemoryLoadAll / AddFact / ReplaceFactAtIndex /
// DeleteAtIndex) instead of the summaries file, which this screen
// never reads or writes.

#import "EZMemorySummaryViewController.h"
#import "helpers.h"

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EZMemorySummaryCell
// ─────────────────────────────────────────────────────────────────────────────

@protocol EZMemorySummaryCellDelegate <NSObject>
- (void)summaryCellDidEndEditingWithText:(NSString *)text atIndex:(NSUInteger)index;
@end

@interface EZMemorySummaryCell : UITableViewCell <UITextViewDelegate>

@property (nonatomic, strong) UILabel    *timestampLabel;
@property (nonatomic, strong) UITextView *factTextView;
@property (nonatomic, strong) UILabel    *editHintLabel;

@property (nonatomic, weak)   id<EZMemorySummaryCellDelegate> summaryDelegate;
@property (nonatomic, assign) NSUInteger factIndex;

- (void)configureWithFact:(NSDictionary *)fact
                    index:(NSUInteger)index
                 delegate:(id<EZMemorySummaryCellDelegate>)delegate;
- (void)beginEditingFact;

@end

@implementation EZMemorySummaryCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];

    // ── Card (mirrors EZMemoryCell) ──────────────────────────────────────
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

    // ── Timestamp ────────────────────────────────────────────────────────
    _timestampLabel = [[UILabel alloc] init];
    _timestampLabel.font      = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    _timestampLabel.textColor = [UIColor systemBlueColor];
    _timestampLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_timestampLabel];

    // ── Fact text — the inline editor, same affordance as EZMemoryCell ──
    _factTextView = [[UITextView alloc] init];
    _factTextView.font             = [UIFont systemFontOfSize:15];
    _factTextView.textColor        = [UIColor labelColor];
    _factTextView.backgroundColor  = [UIColor clearColor];
    _factTextView.scrollEnabled    = NO;
    _factTextView.delegate         = self;
    _factTextView.textContainerInset = UIEdgeInsetsZero;
    _factTextView.textContainer.lineFragmentPadding = 0;
    _factTextView.translatesAutoresizingMaskIntoConstraints = NO;

    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    UIBarButtonItem *flex    = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(dismissKeyboard)];
    toolbar.items = @[flex, doneBtn];
    _factTextView.inputAccessoryView = toolbar;
    [card addSubview:_factTextView];

    // ── Edit hint ────────────────────────────────────────────────────────
    _editHintLabel = [[UILabel alloc] init];
    _editHintLabel.text            = @"✏️ Tap fact to edit";
    _editHintLabel.font            = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _editHintLabel.textColor       = [UIColor systemBlueColor];
    _editHintLabel.alpha           = 0.7;
    _editHintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:_editHintLabel];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor      constraintEqualToAnchor:self.contentView.topAnchor      constant:6],
        [card.bottomAnchor   constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-6],
        [card.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor  constant:12],
        [card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],

        [_timestampLabel.topAnchor      constraintEqualToAnchor:card.topAnchor      constant:12],
        [_timestampLabel.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor  constant:14],
        [_timestampLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],

        [_factTextView.topAnchor      constraintEqualToAnchor:_timestampLabel.bottomAnchor constant:10],
        [_factTextView.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor  constant:14],
        [_factTextView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],

        [_editHintLabel.topAnchor      constraintEqualToAnchor:_factTextView.bottomAnchor constant:6],
        [_editHintLabel.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor  constant:14],
        [_editHintLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [_editHintLabel.bottomAnchor   constraintEqualToAnchor:card.bottomAnchor   constant:-12],
    ]];
    return self;
}

- (void)configureWithFact:(NSDictionary *)fact
                    index:(NSUInteger)index
                 delegate:(id<EZMemorySummaryCellDelegate>)delegate {
    self.factIndex       = index;
    self.summaryDelegate = delegate;
    self.timestampLabel.text = [fact[@"timestamp"] isKindOfClass:[NSString class]]
        ? fact[@"timestamp"] : @"";
    NSString *text = [fact[@"explicitFact"] isKindOfClass:[NSString class]] ? fact[@"explicitFact"] : @"";
    if (text.length == 0 && [fact[@"summary"] isKindOfClass:[NSString class]]) text = fact[@"summary"];
    self.factTextView.text = text;
}

- (void)beginEditingFact {
    [self.factTextView becomeFirstResponder];
}

- (void)dismissKeyboard {
    [self.factTextView resignFirstResponder];
}

// ── UITextViewDelegate ───────────────────────────────────────────────────

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
    self.editHintLabel.text  = @"✏️ Tap fact to edit";
    self.editHintLabel.alpha = 0.7;
    [self.summaryDelegate summaryCellDidEndEditingWithText:textView.text atIndex:self.factIndex];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EZMemorySummaryViewController
// ─────────────────────────────────────────────────────────────────────────────

@interface EZMemorySummaryViewController () <UITableViewDelegate,
                                             UITableViewDataSource,
                                             EZMemorySummaryCellDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *facts;
@property (nonatomic, strong) UILabel *emptyLabel;
// YES while the "+" draft row (a not-yet-saved empty editor row) is shown.
@property (nonatomic, assign) BOOL addingDraft;

@end

@implementation EZMemorySummaryViewController

static NSString * const kSummaryCellID = @"EZMemorySummaryCell";

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Memory Summary";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // ── Left nav bar: add ────────────────────────────────────────────────
    UIBarButtonItem *addItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self
                             action:@selector(addFactTapped)];
    self.navigationItem.leftBarButtonItems = @[addItem];

    // ── Right nav bar: close + edit (mirrors MemoriesViewController) ────
    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(dismissSelf)];
    self.navigationItem.rightBarButtonItems = @[closeItem, self.editButtonItem];

    [self setupTableView];
    [self setupEmptyLabel];

    // NOTE: facts are loaded in viewWillAppear (every appearance), not
    // here — the same convention as MemoriesViewController.
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFacts];
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
    [self.tableView registerClass:[EZMemorySummaryCell class] forCellReuseIdentifier:kSummaryCellID];
    [self.view addSubview:self.tableView];
}

- (void)setupEmptyLabel {
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text          = @"No important memories yet.\nAsk the assistant to remember something important and it will appear here.";
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textColor     = [UIColor secondaryLabelColor];
    self.emptyLabel.font          = [UIFont systemFontOfSize:16];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
}

// ── Data ─────────────────────────────────────────────────────────────────

- (void)reloadFacts {
    self.facts = EZImportantMemoryLoadAll() ?: @[];
    self.emptyLabel.hidden = (self.facts.count > 0 || self.addingDraft);
    [self.tableView reloadData];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    // A half-typed draft does not survive Edit mode — discard it. The
    // flag drops first so the editor's end-editing callback (fired by
    // endEditing) no-ops instead of saving the draft.
    if (editing && self.addingDraft) {
        self.addingDraft = NO;
        [self.view endEditing:YES];
    }
    [self.tableView setEditing:editing animated:animated];
    if (editing) {
        self.emptyLabel.hidden = YES;
    } else {
        [self reloadFacts];
    }
}

// ── Add ──────────────────────────────────────────────────────────────────

- (void)addFactTapped {
    if (self.addingDraft) return;
    if (self.editing) [self setEditing:NO animated:YES];
    self.addingDraft = YES;
    self.emptyLabel.hidden = YES;
    NSIndexPath *draftPath = [NSIndexPath indexPathForRow:(NSInteger)self.facts.count inSection:0];
    [self.tableView insertRowsAtIndexPaths:@[draftPath]
                          withRowAnimation:UITableViewRowAnimationFade];
    [self.tableView scrollToRowAtIndexPath:draftPath
                          atScrollPosition:UITableViewScrollPositionBottom animated:YES];
    // Focus the draft's editor once the insert animation settles.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        EZMemorySummaryCell *cell = [self.tableView cellForRowAtIndexPath:draftPath];
        [cell beginEditingFact];
    });
}

// ── UITableViewDataSource ────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    // No placeholder row: the empty state is the label.
    return (NSInteger)self.facts.count + (self.addingDraft ? 1 : 0);
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EZMemorySummaryCell *cell = [tableView dequeueReusableCellWithIdentifier:kSummaryCellID
                                                                forIndexPath:indexPath];
    NSUInteger row = (NSUInteger)indexPath.row;
    if (self.addingDraft && row == self.facts.count) {
        [cell configureWithFact:@{ @"timestamp": @"New fact", @"explicitFact": @"" }
                          index:row
                       delegate:self];
    } else {
        [cell configureWithFact:self.facts[row] index:row delegate:self];
    }
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView
titleForHeaderInSection:(NSInteger)section {
    if (self.facts.count == 0) return nil;
    return [NSString stringWithFormat:@"%lu saved", (unsigned long)self.facts.count];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.addingDraft && indexPath.row == (NSInteger)self.facts.count)
        return UITableViewCellEditingStyleNone;
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSUInteger row = (NSUInteger)indexPath.row;
    if (row >= self.facts.count) return;

    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Delete Fact?"
                         message:@"This fact will be permanently removed from the Memory Summary."
                  preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
        EZImportantMemoryDeleteAtIndex(row);
        [self reloadFacts];
        EZLog(EZLogLevelInfo, @"MEMORIES", @"Important memory deleted from Memory Summary");
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
    if (self.editing) return;
    // Tapping anywhere on the card focuses its inline editor.
    EZMemorySummaryCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [cell beginEditingFact];
}

// ── EZMemorySummaryCellDelegate ──────────────────────────────────────────

- (void)summaryCellDidEndEditingWithText:(NSString *)text atIndex:(NSUInteger)index {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (self.addingDraft && index == self.facts.count) {
        // The draft row: non-empty text becomes a new fact; empty text
        // simply discards the draft.
        self.addingDraft = NO;
        if (trimmed.length > 0) {
            EZImportantMemoryAddFact(trimmed);
            [self showToast:@"✅ Fact added"];
        }
        [self reloadFacts];
        return;
    }

    if (index >= self.facts.count) return;
    if (trimmed.length == 0) { [self reloadFacts]; return; }  // an edit never blanks a fact
    id rawFact    = self.facts[index][@"explicitFact"];
    id rawSummary = self.facts[index][@"summary"];
    NSString *current = [rawFact isKindOfClass:[NSString class]] ? rawFact
                      : ([rawSummary isKindOfClass:[NSString class]] ? rawSummary : @"");
    if ([trimmed isEqualToString:current]) return;  // unchanged
    EZImportantMemoryReplaceFactAtIndex(index, trimmed);
    [self reloadFacts];
    [self showToast:@"✅ Fact updated"];
}

// ── Toast (mirrors MemoriesViewController) ───────────────────────────────

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
