// SystemLogViewController.m
// EZCompleteUI

#import "SystemLogViewController.h"
#import "helpers.h"

@interface SystemLogViewController () <UISearchBarDelegate>
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIBarButtonItem *excludeButton;
@property (nonatomic, strong) NSTimer *searchDebounceTimer;
@property (nonatomic, copy) NSString *rawLog;
@property (nonatomic, strong) NSArray<NSString *> *entries;
@property (nonatomic, assign) BOOL excludesTerms;
@property (nonatomic, assign) NSInteger filterGeneration;
@end

@implementation SystemLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"System Log";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self setupSearchBar];
    [self setupTextView];
    [self setupBarButtons];
    [self loadLog];
}

- (void)setupSearchBar {
    self.searchBar = [UISearchBar new];
    self.searchBar.placeholder = @"Tags or text, separated by commas";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.barStyle = UIBarStyleBlack;
    self.searchBar.returnKeyType = UIReturnKeySearch;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate = self;
    [self.view addSubview:self.searchBar];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    ]];
}

- (void)setupTextView {
    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.textView.backgroundColor = [UIColor clearColor];
    self.textView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    self.textView.alwaysBounceVertical = YES;
    [self.view addSubview:self.textView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    ]];
}

- (void)setupBarButtons {
    UIBarButtonItem *shareItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:self
                             action:@selector(shareLog)];
    UIBarButtonItem *refreshItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(loadLog)];
    self.excludeButton = [[UIBarButtonItem alloc]
        initWithTitle:@"Exclude"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(excludeButtonTapped)];
    [self updateExcludeButtonAppearance];
    self.navigationItem.rightBarButtonItems = @[shareItem, refreshItem, self.excludeButton];
}

- (void)updateExcludeButtonAppearance {
    self.excludeButton.title = self.excludesTerms ? @"Exclude ✓" : @"Exclude";
    self.excludeButton.tintColor = self.excludesTerms ? [UIColor systemRedColor] : nil;
}

- (void)excludeButtonTapped {
    self.excludesTerms = !self.excludesTerms;
    [self updateExcludeButtonAppearance];
    [self applyFilter];
}

- (void)loadLog {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *path = EZLogGetPath();
        NSString *raw  = [NSString stringWithContentsOfFile:path
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil];
        if (!raw) raw = @"(System log unavailable)";
        NSArray<NSString *> *entries = [self entriesFromLogText:raw];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.rawLog = raw;
            self.entries = entries;
            [self applyFilter];
        });
    });
}

// The log is a list of entries, not lines: an entry starts at a
// timestamped line ("[2026-11-23 06:30:08] ...") and runs until the
// next one, so a filter keeps or drops an entry's continuation lines
// (request bodies, stack traces) together with the entry itself.
- (NSArray<NSString *> *)entriesFromLogText:(NSString *)raw {
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    NSMutableString *current = nil;
    for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
        if ([self lineStartsEntry:line] && current.length) {
            [entries addObject:[current copy]];
            current = nil;
        }
        if (!current) current = [NSMutableString string];
        if (current.length) [current appendString:@"\n"];
        [current appendString:line];
    }
    if (current.length) [entries addObject:[current copy]];
    return entries;
}

- (BOOL)lineStartsEntry:(NSString *)line {
    if (line.length < 6 || [line characterAtIndex:0] != '[') return NO;
    for (NSInteger i = 1; i <= 4; i++) {
        unichar c = [line characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return [line characterAtIndex:5] == '-';
}

- (NSArray<NSString *> *)activeFilterTerms {
    NSMutableArray<NSString *> *terms = [NSMutableArray array];
    for (NSString *rawTerm in [self.searchBar.text componentsSeparatedByString:@","]) {
        NSString *term = [rawTerm stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (term.length) [terms addObject:term];
    }
    return terms;
}

// Same semantics as the admin ledger's filter: comma-separated terms,
// a row matches when any term appears in it; with Exclude on, a row
// matching any term is hidden instead.
- (void)applyFilter {
    NSArray<NSString *> *terms = [self activeFilterTerms];
    if (!terms.count || !self.entries) {
        self.title = @"System Log";
        self.textView.text = self.rawLog ?: @"";
        [self scrollTextViewToBottom];
        return;
    }
    NSInteger generation = ++self.filterGeneration;
    NSArray<NSString *> *entries = self.entries;
    BOOL exclude = self.excludesTerms;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *kept = [NSMutableArray array];
        for (NSString *entry in entries) {
            BOOL matches = NO;
            for (NSString *term in terms) {
                if ([entry rangeOfString:term
                                  options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    matches = YES;
                    break;
                }
            }
            if (matches != exclude) [kept addObject:entry];
        }
        NSString *text = [kept componentsJoinedByString:@"\n"];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.filterGeneration) return;
            self.title = [NSString stringWithFormat:@"System Log (%lu/%lu)",
                (unsigned long)kept.count, (unsigned long)entries.count];
            self.textView.text = text;
            [self scrollTextViewToBottom];
        });
    });
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                                 target:self
                                                               selector:@selector(applyFilter)
                                                               userInfo:nil
                                                                repeats:NO];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self.searchDebounceTimer invalidate];
    [self applyFilter];
    [searchBar resignFirstResponder];
}

- (void)shareLog {
    NSString *path = EZLogGetPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self showAlertWithTitle:@"Log Missing" message:@"System log file not found."];
        return;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    UIActivityViewController *ac = [[UIActivityViewController alloc]
        initWithActivityItems:@[fileURL] applicationActivities:nil];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)scrollTextViewToBottom {
    UITextView *tv = self.textView;
    if (!tv.text.length) return;
    NSRange bottom = NSMakeRange(tv.text.length - 1, 1);
    [tv scrollRangeToVisible:bottom];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
