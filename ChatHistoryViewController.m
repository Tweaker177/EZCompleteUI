// ChatHistoryViewController.m
// EZCompleteUI

#import "ChatHistoryViewController.h"
#import "helpers.h"

static NSString * const kCellID = @"EZThreadCell";

@interface ChatHistoryViewController ()
@property (nonatomic, strong) NSArray<EZChatThread *> *threads;
@end

@implementation ChatHistoryViewController

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Chat History";

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(dismissSelf)];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                             target:self
                             action:@selector(confirmDeleteAll)];

    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kCellID];
    self.tableView.rowHeight          = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 70;

    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    self.threads = EZThreadList();
    [self.tableView reloadData];
    // Hide trash button if nothing to delete
    self.navigationItem.rightBarButtonItem.enabled = (self.threads.count > 0);
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Table view data source
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.threads.count == 0 ? 1 : (NSInteger)self.threads.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID
                                                            forIndexPath:indexPath];
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
        [self dismissViewControllerAnimated:YES completion:^{
            [self.delegate chatHistoryDidSelectThread:full];
        }];
    }]];

    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

// Swipe-to-delete individual thread
- (BOOL)tableView:(UITableView *)tableView
canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.threads.count > 0;
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && self.threads.count > 0) {
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
