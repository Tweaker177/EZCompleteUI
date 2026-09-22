// ChatHistoryViewController.m
// EZCompleteUI

#import "ChatHistoryViewController.h"
#import "helpers.h"

static NSString * const kCellID = @"EZThreadCell";
static NSString * const kNavigationCellID = @"EZNavigationCell";

@interface ChatHistoryViewController () <UISearchBarDelegate>
@property (nonatomic, strong) NSArray<EZChatThread *> *allThreads;
@property (nonatomic, strong) NSArray<EZChatThread *> *threads;
@property (nonatomic, strong) UISearchBar *searchBar;
@end

@implementation ChatHistoryViewController

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedString(@"EZNav.AppTitle", nil);

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(focusSearch)];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(dismissSelf)];

    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kCellID];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kNavigationCellID];
    self.tableView.rowHeight          = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 70;

    [self setupSearchBar];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    self.allThreads = EZThreadList();
    [self applySearchFilter];

    self.navigationItem.rightBarButtonItem.enabled = YES;
}

// ─────────────────────────────────────────────────────────────────────────────
- (void)setupSearchBar {
    if (self.searchBar) return;
    self.searchBar                     = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.autoresizingMask    = UIViewAutoresizingFlexibleWidth;
    self.searchBar.placeholder         = @"Search titles";
    self.searchBar.delegate            = self;
    self.searchBar.showsCancelButton   = NO;
}

- (void)applySearchFilter {
    NSString *text = [self.searchBar.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        self.threads = self.allThreads;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(EZChatThread *thread, NSDictionary *bindings) {
            NSString *title = thread.title ?: @"";
            return [title rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        self.threads = [self.allThreads filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
}

- (void)dismissSelf {
    if (self.closeHandler) {
        self.closeHandler();
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)focusSearch {
    if (self.tableView.tableHeaderView != self.searchBar) {
        self.tableView.tableHeaderView = self.searchBar;
        [self.tableView beginUpdates];
        [self.tableView endUpdates];
    }
    [self.searchBar becomeFirstResponder];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applySearchFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Table view data source
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 8;
    return self.threads.count == 0 ? 1 : (NSInteger)self.threads.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 1 ? NSLocalizedString(@"EZNav.RecentChats", nil) : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    if (indexPath.section == 0) {
        static NSArray<NSString *> *titles;
        static NSArray<NSString *> *icons;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            titles = @[
                NSLocalizedString(@"EZNav.NewChat", nil),
                NSLocalizedString(@"EZNav.PhotoGallery", nil),
                NSLocalizedString(@"EZNav.TextToSpeech", nil),
                NSLocalizedString(@"EZNav.VoiceCloning", nil),
                NSLocalizedString(@"EZNav.BrainRot", nil),
                NSLocalizedString(@"EZNav.Memories", nil),
                NSLocalizedString(@"EZNav.CoinStore", nil),
                NSLocalizedString(@"EZNav.Settings", nil)
            ];
            icons = @[@"square.and.pencil", @"photo.on.rectangle.angled", @"play.circle.fill", @"waveform", @"gamecontroller.fill", @"brain.head.profile", @"circle.hexagongrid.fill", @"gearshape.fill"];
        });
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kNavigationCellID
                                                                 forIndexPath:indexPath];
        if (@available(iOS 14.0, *)) {
            UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
            cfg.text = titles[(NSUInteger)indexPath.row];
            cfg.image = [UIImage systemImageNamed:icons[(NSUInteger)indexPath.row]];
            cfg.imageProperties.tintColor = [UIColor systemTealColor];
            cell.contentConfiguration = cfg;
        } else {
            cell.textLabel.text = titles[(NSUInteger)indexPath.row];
            cell.imageView.image = [UIImage systemImageNamed:icons[(NSUInteger)indexPath.row]];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.userInteractionEnabled = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID forIndexPath:indexPath];
    // Reset reused state
    cell.accessoryType          = UITableViewCellAccessoryNone;
    cell.userInteractionEnabled = YES;
    cell.selectionStyle         = UITableViewCellSelectionStyleDefault;

    if (self.threads.count == 0) {
        // Empty state row
        if (@available(iOS 14.0, *)) {
            UIListContentConfiguration *cfg = cell.defaultContentConfiguration;
            cfg.text                  = @"No saved conversations";
            cfg.textProperties.color  = [UIColor secondaryLabelColor];
            cell.contentConfiguration = cfg;
        } else {
            cell.textLabel.text      = @"No saved conversations";
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
        }
        cell.userInteractionEnabled = NO;
        cell.selectionStyle         = UITableViewCellSelectionStyleNone;
        return cell;
    }

    EZChatThread *thread = self.threads[(NSUInteger)indexPath.row];

    // Format relative date
    NSDateFormatter *fmt    = [[NSDateFormatter alloc] init];
    fmt.dateStyle           = NSDateFormatterShortStyle;
    fmt.timeStyle           = NSDateFormatterShortStyle;
    fmt.doesRelativeDateFormatting = YES;

    // Parse the ISO-8601 updatedAt string back to NSDate for formatting
    NSDateFormatter *isoFmt = [[NSDateFormatter alloc] init];
    isoFmt.dateFormat       = @"yyyy-MM-dd'T'HH:mm:ss";
    isoFmt.locale           = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSDate *updated         = [isoFmt dateFromString:thread.updatedAt];
    NSString *dateStr       = updated ? [fmt stringFromDate:updated] : thread.updatedAt;
    NSString *subtitle      = [NSString stringWithFormat:@"%@  •  %@",
                               thread.modelName ?: @"?", dateStr ?: @""];

    if (@available(iOS 14.0, *)) {
        UIListContentConfiguration *cfg  = cell.defaultContentConfiguration;
        cfg.text                         = thread.title ?: @"Untitled";
        cfg.textProperties.numberOfLines = 2;
        cfg.secondaryText                = subtitle;
        cfg.secondaryTextProperties.color = [UIColor secondaryLabelColor];
        cell.contentConfiguration        = cfg;
    } else {
        cell.textLabel.text              = thread.title ?: @"Untitled";
        cell.textLabel.numberOfLines     = 2;
        cell.detailTextLabel.text        = subtitle;
        cell.detailTextLabel.textColor   = [UIColor secondaryLabelColor];
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Table view delegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        static NSArray<NSString *> *actions;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            actions = @[@"newChat", @"gallery", @"tts", @"cloning", @"brainRot", @"memories", @"coinStore", @"settings"];
        });
        if (self.navigationActionHandler) {
            self.navigationActionHandler(actions[(NSUInteger)indexPath.row]);
        }
        return;
    }
    if (self.threads.count == 0) return;

    EZChatThread *stub = self.threads[(NSUInteger)indexPath.row];

    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Restore Conversation?"
                         message:@"Your current chat has been saved and can be restored later."
                  preferredStyle:UIAlertControllerStyleAlert];

    [confirm addAction:[UIAlertAction actionWithTitle:@"Restore"
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
        // Load full thread with messages
        EZChatThread *full = EZThreadLoad(stub.threadID);
        if (!full) {
            UIAlertController *err = [UIAlertController
                alertControllerWithTitle:@"Error"
                                 message:@"Could not load this conversation."
                          preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"OK"
                                                   style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:err animated:YES completion:nil];
            return;
        }
        EZLogf(EZLogLevelInfo, @"HISTORY", @"Restoring thread: %@", full.threadID);
        if (self.closeHandler) self.closeHandler();
        [self.delegate chatHistoryDidSelectThread:full];
    }]];

    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

// Swipe-to-delete individual thread
- (BOOL)tableView:(UITableView *)tableView
canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 && self.threads.count > 0;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1 && editingStyle == UITableViewCellEditingStyleDelete && self.threads.count > 0) {
        EZChatThread *thread = self.threads[(NSUInteger)indexPath.row];
        EZLogf(EZLogLevelInfo, @"HISTORY", @"Deleting thread: %@", thread.threadID);
        EZThreadDelete(thread.threadID);
        [self reload];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Delete All
// ─────────────────────────────────────────────────────────────────────────────

- (void)confirmDeleteAll {
    if (self.threads.count == 0) return;
    NSString *msg = [NSString stringWithFormat:
        @"Permanently delete all %lu saved conversations? This cannot be undone.",
        (unsigned long)self.threads.count];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Delete All History?"
                         message:msg
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Delete All"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) {
        for (EZChatThread *t in self.threads) EZThreadDelete(t.threadID);
        EZLog(EZLogLevelInfo, @"HISTORY", @"All threads deleted by user");
        [self reload];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
