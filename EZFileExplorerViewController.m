// EZFileExplorerViewController.m
// EZCompleteUI
//
// Conventions matched to the rest of the app:
//   - Programmatic Auto Layout, no storyboards.
//   - NSLocalizedString with dotted keys (EZFileExplorer.*), present in
//     every Localizable.strings.
//   - Private helpers prefixed ez_ (cf. EZInsuranceFilePreviewViewController).
//   - Delete never deletes: files move to Documents/.ez-trash, and
//     permanent erase lives only in the Trash folder, confirmed.

#import "EZFileExplorerViewController.h"
#import "EZFileItem.h"
#import "EZFileInfoViewController.h"
#import "EZInsuranceFilePreviewViewController.h"
#import "EZTextFileEditorViewController.h"
#import "EZArchiveService.h"

#import <QuickLook/QuickLook.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, EZFileExplorerMode) {
    EZFileExplorerModeHome = 0,
    EZFileExplorerModeFolder,
};

typedef NS_ENUM(NSInteger, EZFileExplorerSortMode) {
    EZFileExplorerSortByName = 0,
    EZFileExplorerSortByDate,
    EZFileExplorerSortBySize,
};

static NSString * const kEZFileExplorerSortDefaultsKey = @"EZFileExplorerSortMode";
static NSString * const kEZTrashFolderName = @".ez-trash";
static NSString * const kEZAppGroupIdentifier = @"group.com.i0stweak3r.ezcompleteui";

@interface EZFileExplorerViewController ()
    <UITableViewDataSource, UITableViewDelegate,
     UISearchResultsUpdating, QLPreviewControllerDataSource,
     UIDocumentPickerDelegate>

@property (nonatomic, assign) EZFileExplorerMode mode;
@property (nonatomic, strong, nullable) NSURL *rootURL; // folder mode only
@property (nonatomic, assign) BOOL readOnly;
@property (nonatomic, assign) BOOL isTrashFolder;

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIRefreshControl *refreshControl;

@property (nonatomic, copy) NSArray<EZFileItem *> *allItems;   // folder mode: unfiltered scan
@property (nonatomic, copy) NSArray<EZFileItem *> *items;      // folder mode: filtered + sorted
@property (nonatomic, copy) NSArray<EZFileItem *> *appRoots;   // home mode
@property (nonatomic, copy) NSArray<EZFileItem *> *deviceRoots; // home mode, probed
@property (nonatomic, copy, nullable) NSError *scanError;
@property (nonatomic, assign) NSUInteger scanGeneration;
@property (nonatomic, assign) EZFileExplorerSortMode sortMode;
@property (nonatomic, strong, nullable) NSURL *previewURL;
@property (nonatomic, strong, nullable) UIBarButtonItem *addButtonItem;
@property (nonatomic, strong, nullable) UIBarButtonItem *selectButtonItem;
@property (nonatomic, strong, nullable) UIBarButtonItem *createZipItem;
@property (nonatomic, strong, nullable) UIBarButtonItem *extractItem;
@property (nonatomic, strong, nullable) UIBarButtonItem *shareSelectionItem;
@property (nonatomic, strong, nullable) UIBarButtonItem *trashSelectionItem;
@property (nonatomic, strong, nullable) UIBarButtonItem *restoreSelectionItem;
@property (nonatomic, strong, nullable) UIBarButtonItem *deleteSelectionItem;
@property (nonatomic, strong, nullable) UIBarButtonItem *selectionCountItem;
@property (nonatomic, strong, nullable) UILabel *selectionCountLabel;
@property (nonatomic, strong, nullable) UIView *progressOverlay;
@property (nonatomic, strong, nullable) UIProgressView *progressBar;
@property (nonatomic, strong, nullable) UILabel *progressTitleLabel;
@property (nonatomic, strong, nullable) UILabel *progressEntryLabel;
@property (nonatomic, strong, nullable) UIButton *progressCancelButton;

@end

@implementation EZFileExplorerViewController

#pragma mark - Init

- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = EZFileExplorerModeHome;
        _allItems = @[];
        _items = @[];
        _appRoots = @[];
        _deviceRoots = @[];
        _sortMode = (EZFileExplorerSortMode)[[NSUserDefaults standardUserDefaults]
            integerForKey:kEZFileExplorerSortDefaultsKey];
        self.title = NSLocalizedString(@"EZNav.Files", @"Files screen title");
    }
    return self;
}

- (instancetype)initWithRootURL:(NSURL *)rootURL {
    return [self initWithRootURL:rootURL title:nil readOnly:NO];
}

- (instancetype)initWithRootURL:(NSURL *)rootURL
                          title:(nullable NSString *)title
                       readOnly:(BOOL)readOnly {
    self = [super init];
    if (self) {
        _mode = EZFileExplorerModeFolder;
        _rootURL = rootURL;
        _readOnly = readOnly;
        _allItems = @[];
        _items = @[];
        _appRoots = @[];
        _deviceRoots = @[];
        _sortMode = (EZFileExplorerSortMode)[[NSUserDefaults standardUserDefaults]
            integerForKey:kEZFileExplorerSortDefaultsKey];
        self.title = title ?: rootURL.lastPathComponent;
    }
    return self;
}

#pragma mark - Root locations (home mode)

+ (NSURL *)ez_documentsURL {
    return [[NSFileManager defaultManager]
        URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
}

+ (NSURL *)ez_trashURL {
    return [[self ez_documentsURL] URLByAppendingPathComponent:kEZTrashFolderName];
}

- (NSArray<EZFileItem *> *)ez_buildAppRoots {
    NSMutableArray<EZFileItem *> *roots = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSURL *docs = [[self class] ez_documentsURL];
    EZFileItem *docsItem = [EZFileItem rootItemWithURL:docs
                                   displayNameOverride:NSLocalizedString(@"EZFileExplorer.Documents",
                                                                         @"Documents root name")];
    if (docsItem) [roots addObject:docsItem];

    NSURL *library = [fm URLsForDirectory:NSLibraryDirectory
                                inDomains:NSUserDomainMask].firstObject;
    EZFileItem *libraryItem = [EZFileItem rootItemWithURL:library
                                      displayNameOverride:NSLocalizedString(@"EZFileExplorer.Library",
                                                                            @"Library root name")];
    if (libraryItem) [roots addObject:libraryItem];

    NSURL *tmp = [NSURL fileURLWithPath:NSTemporaryDirectory()];
    EZFileItem *tmpItem = [EZFileItem rootItemWithURL:tmp
                                  displayNameOverride:NSLocalizedString(@"EZFileExplorer.Temporary",
                                                                        @"Temporary files root name")];
    if (tmpItem) [roots addObject:tmpItem];

    NSURL *group = [fm containerURLForSecurityApplicationGroupIdentifier:kEZAppGroupIdentifier];
    if (group) {
        EZFileItem *groupItem = [EZFileItem rootItemWithURL:group
                                        displayNameOverride:NSLocalizedString(@"EZFileExplorer.SharedContainer",
                                                                              @"App group container root name")];
        if (groupItem) [roots addObject:groupItem];
    }

    // Trash is always listed, even before anything has been trashed —
    // an absent folder just means an empty trash. Its item is built by
    // hand because rootItemWithURL: returns nil for a path that does
    // not exist yet.
    NSURL *trash = [[self class] ez_trashURL];
    EZFileItem *trashItem = [EZFileItem rootItemWithURL:trash
                                    displayNameOverride:NSLocalizedString(@"EZFileExplorer.Trash",
                                                                          @"Trash root name")];
    if (!trashItem) {
        trashItem = [[EZFileItem alloc] initWithURL:trash
                                     resourceValues:@{ NSURLIsDirectoryKey: @YES }
                                          childCount:0
                                 displayNameOverride:NSLocalizedString(@"EZFileExplorer.Trash",
                                                                       @"Trash root name")];
    }
    [roots addObject:trashItem];
    return roots;
}

- (NSArray<EZFileItem *> *)ez_probeDeviceRoots {
    // Probed, never assumed: on a stock install all three fail the
    // readability check and the Device section simply never appears.
    // Read-only even when readable — writes outside the container are
    // out of scope for this feature.
    NSArray<NSArray<NSString *> *> *candidates = @[
        @[ @"/var/mobile/Documents", @"EZFileExplorer.Documents" ],
        @[ @"/var/mobile/Media",     @"EZFileExplorer.Media" ],
        @[ @"/var/mobile/Library",   @"EZFileExplorer.Library" ],
    ];
    NSMutableArray<EZFileItem *> *roots = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSArray<NSString *> *candidate in candidates) {
        NSString *path = candidate[0];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) continue;
        if (![fm isReadableFileAtPath:path]) continue;
        EZFileItem *item = [EZFileItem rootItemWithURL:[NSURL fileURLWithPath:path]
                                   displayNameOverride:NSLocalizedString(candidate[1],
                                                                         @"Device root name")];
        if (item) [roots addObject:item];
    }
    return roots;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    if (self.mode == EZFileExplorerModeHome) {
        self.appRoots = [self ez_buildAppRoots];
        self.deviceRoots = [self ez_probeDeviceRoots];
    }

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                                  style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.tableView];

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self
                            action:@selector(ez_reload)
                  forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = self.refreshControl;

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-32],
    ]];

    // Search filters the current listing in place (flat, current folder
    // only — recursive search is a later phase).
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder =
        NSLocalizedString(@"EZFileExplorer.SearchPlaceholder", @"Search field placeholder");
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    if (self.mode == EZFileExplorerModeFolder) {
        UIBarButtonItem *sortItem = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(ez_sortTapped)];
        sortItem.accessibilityLabel = NSLocalizedString(@"EZFileExplorer.Sort",
                                                        @"Sort button");
        if (!self.readOnly) {
            self.selectButtonItem = [[UIBarButtonItem alloc]
                initWithTitle:NSLocalizedString(@"EZFileExplorer.Select",
                                                @"Select button")
                        style:UIBarButtonItemStylePlain
                       target:self
                       action:@selector(ez_selectTapped)];
            self.navigationItem.rightBarButtonItems = @[self.selectButtonItem, sortItem];
        } else {
            self.navigationItem.rightBarButtonItem = sortItem;
        }
        [self ez_setupToolbar];
    }

    // When this screen is the root of a presented navigation controller
    // (the usual case — it is opened from the chat screen), there is no
    // back button to leave by, so give it an explicit Done.
    if (self.navigationController.presentingViewController &&
        self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:NSLocalizedString(@"EZFileExplorer.Done", @"Done button")
                    style:UIBarButtonItemStyleDone
                   target:self
                   action:@selector(ez_doneTapped)];
    }

    [self ez_reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The toolbar belongs to this screen only — shown while a folder
    // with toolbar actions is on top, hidden everywhere else (home,
    // Get Info, the chat screen behind us never sees it: different nav).
    self.navigationController.toolbarHidden = self.toolbarItems.count == 0;
    // Files change underneath us constantly (other features write into
    // Documents), so a rescan on appear beats a stale listing. Skipped
    // during multi-select — rescanning mid-selection would drop the
    // user's picks.
    if (!self.tableView.editing) [self ez_reload];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.toolbarHidden = YES;
}

- (void)ez_doneTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Loading

- (void)ez_reload {
    if (self.mode == EZFileExplorerModeHome) {
        // Roots are cheap to rebuild and their counts go stale too.
        self.appRoots = [self ez_buildAppRoots];
        self.deviceRoots = [self ez_probeDeviceRoots];
        [self.tableView reloadData];
        [self.refreshControl endRefreshing];
        [self ez_updateEmptyState];
        return;
    }
    NSUInteger generation = ++self.scanGeneration;
    if (self.items.count == 0) [self.spinner startAnimating];
    NSURL *root = self.rootURL;
    __weak typeof(self) weakSelf = self;
    [EZFileItem scanDirectoryAtURL:root
                        completion:^(NSArray<EZFileItem *> *items,
                                     NSError * _Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.scanGeneration) return;
        [self.spinner stopAnimating];
        [self.refreshControl endRefreshing];
        self.scanError = error;
        self.allItems = items;
        [self ez_applyFilterAndSort];
        [self ez_updateEmptyState];
    }];
}

- (NSString *)ez_searchText {
    return self.searchController.searchBar.text ?: @"";
}

- (void)ez_applyFilterAndSort {
    NSString *query = [self ez_searchText];
    NSArray<EZFileItem *> *source = self.allItems;
    if (query.length) {
        NSMutableArray<EZFileItem *> *filtered = [NSMutableArray array];
        for (EZFileItem *item in source) {
            if ([item.name rangeOfString:query
                                 options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
                [filtered addObject:item];
            }
        }
        source = filtered;
    }
    EZFileExplorerSortMode mode = self.sortMode;
    self.items = [source sortedArrayUsingComparator:
        ^NSComparisonResult(EZFileItem *a, EZFileItem *b) {
            if (a.isDirectory != b.isDirectory) {
                return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
            }
            switch (mode) {
                case EZFileExplorerSortByDate: {
                    NSDate *da = a.modifiedDate ?: [NSDate distantPast];
                    NSDate *db = b.modifiedDate ?: [NSDate distantPast];
                    NSComparisonResult byDate = [db compare:da]; // newest first
                    if (byDate != NSOrderedSame) return byDate;
                    break;
                }
                case EZFileExplorerSortBySize: {
                    if (!a.isDirectory && a.fileSize != b.fileSize) {
                        return a.fileSize > b.fileSize ? NSOrderedAscending
                                                       : NSOrderedDescending;
                    }
                    break;
                }
                case EZFileExplorerSortByName:
                    break;
            }
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];
    [self.tableView reloadData];
}

- (void)ez_updateEmptyState {
    BOOL hasContent;
    NSString *text = nil;
    if (self.mode == EZFileExplorerModeHome) {
        hasContent = (self.appRoots.count + self.deviceRoots.count) > 0;
    } else if (self.scanError) {
        hasContent = NO;
        text = NSLocalizedString(@"EZFileExplorer.LoadFailed",
                                 @"Folder could not be read");
    } else if ([self ez_searchText].length && self.allItems.count > 0) {
        hasContent = self.items.count > 0;
        text = [NSString stringWithFormat:
            NSLocalizedString(@"EZFileExplorer.NoResults", @"No search results"),
            [self ez_searchText]];
    } else {
        hasContent = self.items.count > 0;
        text = NSLocalizedString(@"EZFileExplorer.Empty", @"Empty folder");
    }
    self.emptyLabel.text = text;
    self.emptyLabel.hidden = hasContent;
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    if (self.mode == EZFileExplorerModeFolder) {
        [self ez_applyFilterAndSort];
    } else {
        [self.tableView reloadData];
    }
    [self ez_updateEmptyState];
}

#pragma mark - Sorting

- (void)ez_sortTapped {
    NSString *check = @" ✓";
    NSString *(^titleFor)(EZFileExplorerSortMode, NSString *, NSString *) =
        ^NSString *(EZFileExplorerSortMode m, NSString *key, NSString *comment) {
        NSString *base = NSLocalizedString(key, comment);
        return self.sortMode == m ? [base stringByAppendingString:check] : base;
    };
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.SortBy", @"Sort sheet title")
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction
        actionWithTitle:titleFor(EZFileExplorerSortByName,
                                 @"EZFileExplorer.SortName", @"Sort by name")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) { [self ez_setSortMode:EZFileExplorerSortByName]; }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:titleFor(EZFileExplorerSortByDate,
                                 @"EZFileExplorer.SortDate", @"Sort by date")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) { [self ez_setSortMode:EZFileExplorerSortByDate]; }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:titleFor(EZFileExplorerSortBySize,
                                 @"EZFileExplorer.SortSize", @"Sort by size")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) { [self ez_setSortMode:EZFileExplorerSortBySize]; }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Cancel", @"Cancel button")
                  style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)ez_setSortMode:(EZFileExplorerSortMode)mode {
    self.sortMode = mode;
    [[NSUserDefaults standardUserDefaults] setInteger:mode
                                               forKey:kEZFileExplorerSortDefaultsKey];
    [self ez_applyFilterAndSort];
}

#pragma mark - Table data source

- (NSArray<EZFileItem *> *)ez_homeRootsForSection:(NSInteger)section {
    NSArray<EZFileItem *> *roots = (section == 0) ? self.appRoots : self.deviceRoots;
    NSString *query = [self ez_searchText];
    if (!query.length) return roots;
    NSMutableArray<EZFileItem *> *filtered = [NSMutableArray array];
    for (EZFileItem *item in roots) {
        if ([item.displayName rangeOfString:query
                                    options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
            [filtered addObject:item];
        }
    }
    return filtered;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.mode == EZFileExplorerModeHome) {
        return self.deviceRoots.count > 0 ? 2 : 1;
    }
    return 1;
}

- (nullable NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
    if (self.mode != EZFileExplorerModeHome) return nil;
    if ([self ez_homeRootsForSection:section].count == 0) return nil;
    return section == 0
        ? NSLocalizedString(@"EZFileExplorer.SectionApp", @"App section header")
        : NSLocalizedString(@"EZFileExplorer.SectionDevice", @"Device section header");
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
    if (self.mode == EZFileExplorerModeHome) {
        return (NSInteger)[self ez_homeRootsForSection:section].count;
    }
    return (NSInteger)self.items.count;
}

- (EZFileItem *)ez_itemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == EZFileExplorerModeHome) {
        return [self ez_homeRootsForSection:indexPath.section][(NSUInteger)indexPath.row];
    }
    return self.items[(NSUInteger)indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const kCellID = @"EZFileExplorerCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:kCellID];
    }
    EZFileItem *item = [self ez_itemAtIndexPath:indexPath];
    UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
    cfg.text = item.displayName;
    cfg.image = [UIImage systemImageNamed:[self ez_symbolNameForItem:item]];
    cfg.imageProperties.tintColor = [UIColor secondaryLabelColor];
    if (item.isDirectory) {
        cfg.secondaryText = [self ez_folderDetailForItem:item];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)item.fileSize
                                                        countStyle:NSByteCountFormatterCountStyleFile];
        NSString *date = item.modifiedDate
            ? [NSDateFormatter localizedStringFromDate:item.modifiedDate
                                             dateStyle:NSDateFormatterShortStyle
                                             timeStyle:NSDateFormatterShortStyle]
            : @"";
        cfg.secondaryText = date.length
            ? [NSString stringWithFormat:@"%@ • %@", size, date]
            : size;
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    cell.contentConfiguration = cfg;
    cell.accessibilityLabel = item.displayName;
    return cell;
}

- (NSString *)ez_folderDetailForItem:(EZFileItem *)item {
    NSString *folder = NSLocalizedString(@"EZFileExplorer.Folder", @"Folder row detail");
    if (item.childCount == 1) {
        return [NSString stringWithFormat:@"%@ — %@",
                folder,
                NSLocalizedString(@"EZFileExplorer.ItemCountOne", @"One item")];
    }
    if (item.childCount > 1) {
        return [NSString stringWithFormat:@"%@ — %@",
                folder,
                [NSString stringWithFormat:
                    NSLocalizedString(@"EZFileExplorer.ItemCountMany", @"Item count"),
                    (long)item.childCount]];
    }
    return folder;
}

- (void)tableView:(UITableView *)tableView
    didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.editing) [self ez_updateSelectionState];
}

#pragma mark - Table delegate / navigation

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.editing) {
        [self ez_updateSelectionState];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    EZFileItem *item = [self ez_itemAtIndexPath:indexPath];
    if (item.isDirectory) {
        [self ez_pushFolderForItem:item fromHomeSection:indexPath.section];
    } else {
        [self ez_openFileItem:item];
    }
}

- (void)ez_pushFolderForItem:(EZFileItem *)item fromHomeSection:(NSInteger)section {
    BOOL readOnly = self.readOnly;
    NSString *title = item.displayName;
    if (self.mode == EZFileExplorerModeHome) {
        readOnly = (section == 1); // Device roots are always read-only
        // Opening Trash is a mode of its own (restore / permanent delete
        // live there), flagged on the pushed instance.
        EZFileExplorerViewController *next =
            [[EZFileExplorerViewController alloc] initWithRootURL:item.url
                                                            title:title
                                                         readOnly:readOnly];
        next.isTrashFolder = [item.url.path isEqualToString:[[self class] ez_trashURL].path];
        if (next.isTrashFolder) {
            // First visit: make sure the folder actually exists so the
            // listing is a real (empty) folder, not a scan error.
            [[NSFileManager defaultManager] createDirectoryAtURL:item.url
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:nil];
        }
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    EZFileExplorerViewController *next =
        [[EZFileExplorerViewController alloc] initWithRootURL:item.url
                                                        title:nil
                                                     readOnly:readOnly];
    next.isTrashFolder = self.isTrashFolder &&
        [item.url.path hasPrefix:[[self class] ez_trashURL].path];
    [self.navigationController pushViewController:next animated:YES];
}

#pragma mark - Opening files

- (void)ez_openFileItem:(EZFileItem *)item {
    if ([item isRARArchive]) {
        [self ez_presentRARExplanationForItem:item];
        return;
    }
    if ([item isUnsupportedArchive]) {
        // QuickLook can't show these either — an honest explanation
        // (and Open in…) beats a blank preview page.
        [self ez_presentUnsupportedExplanationForItem:item
                                       compressionName:[self ez_compressionNameForItem:item]];
        return;
    }
    if ([item isMediaFile]) {
        EZInsuranceFilePreviewViewController *preview =
            [[EZInsuranceFilePreviewViewController alloc]
                initWithFileURL:item.url
                       mimeType:item.contentType.preferredMIMEType
                          title:item.displayName
                          notes:nil];
        [self presentViewController:preview animated:YES completion:nil];
        return;
    }
    if ([item isTextFile]) {
        // The editor enforces its own rails (>2 MB, non-UTF-8, binary)
        // and honors this folder's read-only flag as a viewer.
        EZTextFileEditorViewController *editor =
            [[EZTextFileEditorViewController alloc] initWithFileURL:item.url
                                                           readOnly:self.readOnly];
        UINavigationController *nav = [[UINavigationController alloc]
            initWithRootViewController:editor];
        [self presentViewController:nav animated:YES completion:nil];
        return;
    }
    // Everything else — PDFs, Office docs, audio — goes through QuickLook.
    [self ez_presentQuickLookForURL:item.url];
}

- (void)ez_presentQuickLookForURL:(NSURL *)url {
    self.previewURL = url;
    QLPreviewController *ql = [[QLPreviewController alloc] init];
    ql.dataSource = self;
    [self presentViewController:ql animated:YES completion:nil];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return self.previewURL ? 1 : 0;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller
                  previewItemAtIndex:(NSInteger)index {
    return self.previewURL;
}

- (void)ez_presentRARExplanationForItem:(EZFileItem *)item {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.RARTitle",
                                                   @"RAR explanation title")
                         message:NSLocalizedString(@"EZFileExplorer.RARMessage",
                                                   @"RAR explanation body")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.OpenIn", @"Open in… button")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) {
        [self ez_shareItem:item fromRect:CGRectNull];
    }]];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.OK", @"OK button")
                  style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// Display name of the compression an archive uses, from its
/// extension chain — the explanation strings name it so "can't
/// extract yet" is specific instead of mysterious.
- (NSString *)ez_compressionNameForItem:(EZFileItem *)item {
    NSString *name = item.name.lowercaseString;
    if ([name hasSuffix:@".7z"]) return @"7-Zip";
    if ([name hasSuffix:@".zst"]) return @"Zstandard";
    if ([name hasSuffix:@".bz2"] || [name hasSuffix:@".bzip2"]) return @"bzip2";
    if ([name hasSuffix:@".lz4"]) return @"LZ4";
    if ([name hasSuffix:@".lzma"]) return @"LZMA";
    if ([name hasSuffix:@".xz"]) return @"XZ";
    return @"";
}

/// The plan's xz/zst rule: an archive this build can't decode gets an
/// explanation and an Open in… escape hatch — never a silent failure.
/// Deb packages phrase it around the package; standalone archives
/// around the file.
- (void)ez_presentUnsupportedExplanationForItem:(EZFileItem *)item
                              compressionName:(NSString *)compressionName {
    NSString *format = compressionName.length
        ? compressionName
        : [self ez_compressionNameForItem:item];
    NSString *messageKey = [item isDebPackage]
        ? @"EZFileExplorer.DebUnsupportedMessage"
        : @"EZFileExplorer.UnsupportedMessage";
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.UnsupportedTitle",
                                                   @"Unsupported compression title")
                         message:[NSString stringWithFormat:
            NSLocalizedString(messageKey, @"Unsupported compression body"),
            format]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.OpenIn", @"Open in… button")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) {
        [self ez_shareItem:item fromRect:CGRectNull];
    }]];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.OK", @"OK button")
                  style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Row actions (swipe + context menu)

- (BOOL)ez_canModifyItem:(EZFileItem *)item {
    // Write actions exist only where writes are allowed at all.
    return !self.readOnly;
}

- (BOOL)ez_canTrashItem:(EZFileItem *)item {
    // "Move to Trash" makes no sense while browsing the trash itself —
    // restoring and permanent erase are the trash folder's own actions
    // (P1), so the move action is hidden there rather than dead.
    if (self.readOnly || self.isTrashFolder) return NO;
    return ![item.url.path hasPrefix:[[self class] ez_trashURL].path];
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == EZFileExplorerModeHome) return nil;
    EZFileItem *item = [self ez_itemAtIndexPath:indexPath];
    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray array];

    UIContextualAction *share = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:NSLocalizedString(@"EZFileExplorer.Share", @"Share action")
                          handler:^(__kindof UIContextualAction *action,
                                    __kindof UIView *sourceView,
                                    void (^completion)(BOOL)) {
        CGRect rect = [tableView rectForRowAtIndexPath:indexPath];
        [self ez_shareItem:item fromRect:rect];
        completion(YES);
    }];
    share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    share.backgroundColor = [UIColor systemBlueColor];
    [actions addObject:share];

    if ([self ez_canTrashItem:item]) {
        UIContextualAction *trash = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleDestructive
                                title:NSLocalizedString(@"EZFileExplorer.MoveToTrash",
                                                        @"Move to trash action")
                              handler:^(__kindof UIContextualAction *action,
                                        __kindof UIView *sourceView,
                                        void (^completion)(BOOL)) {
            [self ez_moveItemToTrash:item];
            completion(YES);
        }];
        trash.image = [UIImage systemImageNamed:@"trash"];
        [actions insertObject:trash atIndex:0];
    }
    if (self.isTrashFolder && !self.readOnly) {
        UIContextualAction *restore = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
                                title:NSLocalizedString(@"EZFileExplorer.Restore",
                                                        @"Restore action")
                              handler:^(__kindof UIContextualAction *action,
                                        __kindof UIView *sourceView,
                                        void (^completion)(BOOL)) {
            [self ez_restoreItem:item];
            completion(YES);
        }];
        restore.image = [UIImage systemImageNamed:@"arrow.uturn.backward"];
        restore.backgroundColor = [UIColor systemGreenColor];
        [actions addObject:restore];

        UIContextualAction *delete = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleDestructive
                                title:NSLocalizedString(@"EZFileExplorer.DeletePermanently",
                                                        @"Delete permanently action")
                              handler:^(__kindof UIContextualAction *action,
                                        __kindof UIView *sourceView,
                                        void (^completion)(BOOL)) {
            [self ez_deletePermanentlyItem:item];
            completion(YES);
        }];
        delete.image = [UIImage systemImageNamed:@"trash.slash"];
        [actions insertObject:delete atIndex:0];
    }
    return [UISwipeActionsConfiguration configurationWithActions:actions];
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mode == EZFileExplorerModeHome) return nil;
    EZFileItem *item = [self ez_itemAtIndexPath:indexPath];
    UIContextualAction *info = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:NSLocalizedString(@"EZFileExplorer.GetInfo", @"Get Info action")
                          handler:^(__kindof UIContextualAction *action,
                                    __kindof UIView *sourceView,
                                    void (^completion)(BOOL)) {
        [self ez_showInfoForItem:item];
        completion(YES);
    }];
    info.image = [UIImage systemImageNamed:@"info.circle"];
    info.backgroundColor = [UIColor systemGrayColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[info]];
}

- (nullable UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                        point:(CGPoint)point {
    if (self.mode == EZFileExplorerModeHome) return nil;
    EZFileItem *item = [self ez_itemAtIndexPath:indexPath];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
        previewProvider:nil
         actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggested) {
        NSMutableArray<UIAction *> *menuActions = [NSMutableArray array];
        [menuActions addObject:[UIAction
            actionWithTitle:NSLocalizedString(@"EZFileExplorer.Share", @"Share action")
                      image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                 identifier:nil
                    handler:^(__kindof UIAction *a) {
            [self ez_shareItem:item fromRect:[tableView rectForRowAtIndexPath:indexPath]];
        }]];
        [menuActions addObject:[UIAction
            actionWithTitle:NSLocalizedString(@"EZFileExplorer.GetInfo", @"Get Info action")
                      image:[UIImage systemImageNamed:@"info.circle"]
                 identifier:nil
                    handler:^(__kindof UIAction *a) {
            [self ez_showInfoForItem:item];
        }]];
        if (!item.isDirectory && !self.readOnly &&
            ([item isZipArchive] || [item isTarArchive] ||
             [item isDebPackage] || [item isUnsupportedArchive])) {
            [menuActions addObject:[UIAction
                actionWithTitle:NSLocalizedString(@"EZFileExplorer.Extract", @"Extract action")
                          image:[UIImage systemImageNamed:@"arrow.up.bin"]
                     identifier:nil
                        handler:^(__kindof UIAction *a) {
                if ([item isUnsupportedArchive]) {
                    [self ez_presentUnsupportedExplanationForItem:item
                        compressionName:[self ez_compressionNameForItem:item]];
                    return;
                }
                [self ez_extractArchives:@[item] then:^{
                    [self ez_reload];
                }];
            }]];
        }
        if ([self ez_canModifyItem:item]) {
            [menuActions addObject:[UIAction
                actionWithTitle:NSLocalizedString(@"EZFileExplorer.Rename", @"Rename action")
                          image:[UIImage systemImageNamed:@"pencil"]
                     identifier:nil
handler:^(__kindof UIAction *a) {
                [self ez_renameItem:item];
            }                        ]];
            [menuActions addObject:[UIAction
                actionWithTitle:NSLocalizedString(@"EZFileExplorer.Duplicate", @"Duplicate action")
                          image:[UIImage systemImageNamed:@"plus.square.on.square"]
                     identifier:nil
                        handler:^(__kindof UIAction *a) {
                [self ez_duplicateItem:item];
            }]];
            if (self.isTrashFolder) {
                [menuActions addObject:[UIAction
                    actionWithTitle:NSLocalizedString(@"EZFileExplorer.Restore",
                                                      @"Restore action")
                              image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                         identifier:nil
                            handler:^(__kindof UIAction *a) {
                    [self ez_restoreItem:item];
                }]];
                UIAction *delete = [UIAction
                    actionWithTitle:NSLocalizedString(@"EZFileExplorer.DeletePermanently",
                                                      @"Delete permanently action")
                              image:[UIImage systemImageNamed:@"trash.slash"]
                         identifier:nil
                            handler:^(__kindof UIAction *a) {
                    [self ez_deletePermanentlyItem:item];
                }];
                delete.attributes = UIMenuElementAttributesDestructive;
                [menuActions addObject:delete];
            }
        }
        if ([self ez_canTrashItem:item]) {
            UIAction *trash = [UIAction
                actionWithTitle:NSLocalizedString(@"EZFileExplorer.MoveToTrash",
                                                  @"Move to trash action")
                          image:[UIImage systemImageNamed:@"trash"]
                     identifier:nil
                        handler:^(__kindof UIAction *a) {
                [self ez_moveItemToTrash:item];
            }];
            trash.attributes = UIMenuElementAttributesDestructive;
            [menuActions addObject:trash];
        }
        return [UIMenu menuWithTitle:@"" children:menuActions];
    }];
}

#pragma mark - File actions

- (void)ez_shareItem:(EZFileItem *)item fromRect:(CGRect)rect {
    UIActivityViewController *avc = [[UIActivityViewController alloc]
        initWithActivityItems:@[item.url] applicationActivities:nil];
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = self.tableView;
        avc.popoverPresentationController.sourceRect =
            CGRectIsNull(rect) ? self.tableView.bounds : rect;
    }
    [self presentViewController:avc animated:YES completion:nil];
}

- (void)ez_showInfoForItem:(EZFileItem *)item {
    EZFileInfoViewController *info = [[EZFileInfoViewController alloc]
        initWithFileItem:item];
    [self.navigationController pushViewController:info animated:YES];
}

/// A destination URL for `name` inside `directory` that does not exist
/// yet — collisions get " 2", " 3", … appended before the extension
/// instead of overwriting anything. Rename/move/import/duplicate all
/// share this, per the feature's never-overwrite rule.
- (NSURL *)ez_uniqueURLForName:(NSString *)name inDirectory:(NSURL *)directory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *candidate = [directory URLByAppendingPathComponent:name];
    if (![fm fileExistsAtPath:candidate.path]) return candidate;
    NSString *base = name.stringByDeletingPathExtension;
    NSString *ext = name.pathExtension;
    for (NSInteger i = 2; i < 10000; i++) {
        NSString *alt = ext.length
            ? [NSString stringWithFormat:@"%@ %ld.%@", base, (long)i, ext]
            : [NSString stringWithFormat:@"%@ %ld", base, (long)i];
        candidate = [directory URLByAppendingPathComponent:alt];
        if (![fm fileExistsAtPath:candidate.path]) return candidate;
    }
    return candidate;
}

- (void)ez_renameItem:(EZFileItem *)item {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.Rename", @"Rename title")
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = item.name;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Save", @"Save button")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        NSString *newName = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!self || !newName.length || [newName isEqualToString:item.name]) return;
        if ([newName containsString:@"/"]) {
            [self ez_presentErrorWithMessage:
                NSLocalizedString(@"EZFileExplorer.InvalidName",
                                  @"Name contains a slash")];
            return;
        }
        NSURL *directory = item.url.URLByDeletingLastPathComponent;
        NSURL *destination = [self ez_uniqueURLForName:newName inDirectory:directory];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:item.url
                                                     toURL:destination
                                                     error:&error]) {
            [self ez_presentError:error];
            return;
        }
        if (![destination.lastPathComponent isEqualToString:newName]) {
            [self ez_presentNotice:[NSString stringWithFormat:
                NSLocalizedString(@"EZFileExplorer.RenamedNotice",
                                  @"Renamed with suffix notice"),
                newName, destination.lastPathComponent]];
        }
        [self ez_reload];
    }]];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Cancel", @"Cancel button")
                  style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ez_duplicateItem:(EZFileItem *)item {
    NSString *base = item.name.stringByDeletingPathExtension;
    NSString *ext = item.name.pathExtension;
    NSString *copyName = ext.length
        ? [NSString stringWithFormat:@"%@ copy.%@", base, ext]
        : [NSString stringWithFormat:@"%@ copy", base];
    NSURL *directory = item.url.URLByDeletingLastPathComponent;
    NSURL *destination = [self ez_uniqueURLForName:copyName inDirectory:directory];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] copyItemAtURL:item.url
                                                 toURL:destination
                                                 error:&error]) {
        [self ez_presentError:error];
        return;
    }
    [self ez_reload];
}

/// Moves one URL into the trash folder under a unique name. The
/// caller handles presentation (alerts, reloads) so batch operations
/// can move many items and report once.
- (BOOL)ez_moveURLToTrash:(NSURL *)url error:(NSError **)error {
    NSURL *trash = [[self class] ez_trashURL];
    [[NSFileManager defaultManager] createDirectoryAtURL:trash
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    NSURL *destination = [self ez_uniqueURLForName:url.lastPathComponent
                                       inDirectory:trash];
    return [[NSFileManager defaultManager] moveItemAtURL:url
                                                   toURL:destination
                                                   error:error];
}

- (void)ez_moveItemToTrash:(EZFileItem *)item {
    // Already inside the trash? Permanent deletion is a separate,
    // confirmed action that only exists in the Trash folder (P1) — a
    // plain "move to trash" from here would be a no-op move onto
    // itself, so don't offer it there.
    if ([item.url.path hasPrefix:[[self class] ez_trashURL].path]) return;
    NSError *error = nil;
    if (![self ez_moveURLToTrash:item.url error:&error]) {
        [self ez_presentError:error];
        return;
    }
    [self ez_reload];
}

#pragma mark - Toolbar (create / import / empty trash)

- (void)ez_setupToolbar {
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    if (self.isTrashFolder) {
        if (!self.readOnly) {
            UIBarButtonItem *empty = [[UIBarButtonItem alloc]
                initWithTitle:NSLocalizedString(@"EZFileExplorer.EmptyTrash",
                                                @"Empty Trash button")
                        style:UIBarButtonItemStylePlain
                       target:self
                       action:@selector(ez_emptyTrashTapped)];
            empty.tintColor = [UIColor systemRedColor];
            [items addObject:[[UIBarButtonItem alloc]
                initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                     target:nil action:nil]];
            [items addObject:empty];
        }
    } else if (!self.readOnly) {
        self.addButtonItem = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"plus"]
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(ez_addTapped)];
        self.addButtonItem.accessibilityLabel =
            NSLocalizedString(@"EZFileExplorer.Add", @"Add button");
        [items addObject:self.addButtonItem];
    }
    self.toolbarItems = items;
}

- (void)ez_addTapped {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:nil message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.NewFolder", @"New folder")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) { [self ez_newFolder]; }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.NewTextFile", @"New text file")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) { [self ez_newTextFile]; }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.ImportFiles", @"Import files")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) { [self ez_importFiles]; }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Cancel", @"Cancel button")
                  style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.addButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

/// Shared name prompt for New Folder / New Text File. The handler gets
/// the trimmed name (non-empty — the Create action stays disabled
/// until the field has text? No: alerts can't easily gate on text
/// without a text-change hookup, so an empty submission simply
/// defaults to the suggested name).
- (void)ez_promptForNameWithTitle:(NSString *)title
                    suggestedName:(NSString *)suggestedName
                          handler:(void (^)(NSString *name))handler {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = suggestedName;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Create", @"Create button")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) {
        NSString *name = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length) name = suggestedName;
        if ([name containsString:@"/"]) {
            [self ez_presentErrorWithMessage:
                NSLocalizedString(@"EZFileExplorer.InvalidName",
                                  @"Name contains a slash")];
            return;
        }
        handler(name);
    }]];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Cancel", @"Cancel button")
                  style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ez_newFolder {
    [self ez_promptForNameWithTitle:NSLocalizedString(@"EZFileExplorer.NewFolder",
                                                      @"New folder")
                      suggestedName:NSLocalizedString(@"EZFileExplorer.UntitledFolder",
                                                      @"Untitled folder name")
                            handler:^(NSString *name) {
        NSURL *destination = [self ez_uniqueURLForName:name inDirectory:self.rootURL];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:destination
                                      withIntermediateDirectories:NO
                                                       attributes:nil
                                                            error:&error]) {
            [self ez_presentError:error];
            return;
        }
        if (![destination.lastPathComponent isEqualToString:name]) {
            [self ez_presentNotice:[NSString stringWithFormat:
                NSLocalizedString(@"EZFileExplorer.CreatedNotice",
                                  @"Created with suffix notice"),
                name, destination.lastPathComponent]];
        }
        [self ez_reload];
    }];
}

- (void)ez_newTextFile {
    [self ez_promptForNameWithTitle:NSLocalizedString(@"EZFileExplorer.NewTextFile",
                                                      @"New text file")
                      suggestedName:NSLocalizedString(@"EZFileExplorer.UntitledFile",
                                                      @"Untitled file name")
                            handler:^(NSString *name) {
        NSURL *destination = [self ez_uniqueURLForName:name inDirectory:self.rootURL];
        if (![[NSFileManager defaultManager] createFileAtPath:destination.path
                                                     contents:[NSData data]
                                                   attributes:nil]) {
            [self ez_presentError:nil];
            return;
        }
        [self ez_reload];
        // Straight into the editor — creating an empty text file and
        // then hunting for it in the list would be a two-step chore.
        EZTextFileEditorViewController *editor =
            [[EZTextFileEditorViewController alloc] initWithFileURL:destination
                                                           readOnly:NO];
        UINavigationController *nav = [[UINavigationController alloc]
            initWithRootViewController:editor];
        [self presentViewController:nav animated:YES completion:nil];
    }];
}

- (void)ez_importFiles {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *firstWanted = nil, *firstActual = nil;
    NSError *firstError = nil;
    for (NSURL *source in urls) {
        NSURL *destination = [self ez_uniqueURLForName:source.lastPathComponent
                                           inDirectory:self.rootURL];
        NSError *error = nil;
        if ([[NSFileManager defaultManager] copyItemAtURL:source
                                                    toURL:destination
                                                    error:&error]) {
            if (!firstWanted &&
                ![destination.lastPathComponent isEqualToString:source.lastPathComponent]) {
                firstWanted = source.lastPathComponent;
                firstActual = destination.lastPathComponent;
            }
        } else if (!firstError) {
            firstError = error;
        }
    }
    [self ez_reload];
    if (firstError) {
        [self ez_presentError:firstError];
    } else if (firstWanted) {
        [self ez_presentNotice:[NSString stringWithFormat:
            NSLocalizedString(@"EZFileExplorer.RenamedNotice",
                              @"Renamed with suffix notice"),
            firstWanted, firstActual]];
    }
}

#pragma mark - Trash folder actions

- (void)ez_restoreItem:(EZFileItem *)item {
    // There is deliberately no restore manifest, so "restore" lands the
    // item back in Documents — and the notice says exactly that, with
    // the final name, rather than pretending the original spot is known.
    NSURL *docs = [[self class] ez_documentsURL];
    NSURL *destination = [self ez_uniqueURLForName:item.name inDirectory:docs];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] moveItemAtURL:item.url
                                                 toURL:destination
                                                 error:&error]) {
        [self ez_presentError:error];
        return;
    }
    [self ez_reload];
    [self ez_presentNotice:[NSString stringWithFormat:
        NSLocalizedString(@"EZFileExplorer.RestoredNotice", @"Restored notice"),
        destination.lastPathComponent]];
}

- (void)ez_deletePermanentlyItem:(EZFileItem *)item {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.DeletePermanently",
                                                   @"Delete permanently title")
                         message:[NSString stringWithFormat:
            NSLocalizedString(@"EZFileExplorer.DeleteForeverMessage",
                              @"Delete forever body"), item.displayName]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Cancel", @"Cancel button")
                  style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Delete", @"Delete button")
                  style:UIAlertActionStyleDestructive
                handler:^(__unused UIAlertAction *a) {
        NSError *error = nil;
        if (![[NSFileManager defaultManager] removeItemAtURL:item.url error:&error]) {
            [self ez_presentError:error];
            return;
        }
        [self ez_reload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ez_emptyTrashTapped {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.EmptyTrash",
                                                   @"Empty Trash title")
                         message:NSLocalizedString(@"EZFileExplorer.EmptyTrashMessage",
                                                   @"Empty Trash body")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Cancel", @"Cancel button")
                  style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.EmptyTrash",
                                          @"Empty Trash button")
                  style:UIAlertActionStyleDestructive
                handler:^(__unused UIAlertAction *a) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *firstError = nil;
        for (NSURL *child in [fm contentsOfDirectoryAtURL:self.rootURL
                               includingPropertiesForKeys:nil
                                                  options:0
                                                    error:nil]) {
            NSError *error = nil;
            if (![fm removeItemAtURL:child error:&error] && !firstError) {
                firstError = error;
            }
        }
        [self ez_reload];
        if (firstError) [self ez_presentError:firstError];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Multi-select (P2)

- (void)ez_selectTapped {
    [self setEditing:!self.editing animated:YES];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
    self.selectButtonItem.title = editing
        ? NSLocalizedString(@"EZFileExplorer.Done", @"Done button")
        : NSLocalizedString(@"EZFileExplorer.Select", @"Select button");
    if (editing) {
        [self ez_setupSelectionToolbar];
    } else {
        for (NSIndexPath *path in self.tableView.indexPathsForSelectedRows ?: @[]) {
            [self.tableView deselectRowAtIndexPath:path animated:NO];
        }
        [self ez_setupToolbar];
    }
    [self ez_updateSelectionState];
}

- (void)ez_setupSelectionToolbar {
    if (!self.selectionCountItem) {
        self.selectionCountLabel = [[UILabel alloc] init];
        self.selectionCountLabel.font =
            [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        self.selectionCountLabel.textColor = [UIColor secondaryLabelColor];
        self.selectionCountItem = [[UIBarButtonItem alloc]
            initWithCustomView:self.selectionCountLabel];
        self.createZipItem = [[UIBarButtonItem alloc]
            initWithTitle:NSLocalizedString(@"EZFileExplorer.CreateZIP", @"Create ZIP")
                    style:UIBarButtonItemStylePlain
                   target:self action:@selector(ez_createZIPTapped)];
        self.extractItem = [[UIBarButtonItem alloc]
            initWithTitle:NSLocalizedString(@"EZFileExplorer.Extract", @"Extract")
                    style:UIBarButtonItemStylePlain
                   target:self action:@selector(ez_extractSelectionTapped)];
        self.shareSelectionItem = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
                    style:UIBarButtonItemStylePlain
                   target:self action:@selector(ez_shareSelectionTapped)];
        self.shareSelectionItem.accessibilityLabel =
            NSLocalizedString(@"EZFileExplorer.Share", @"Share action");
        self.trashSelectionItem = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"trash"]
                    style:UIBarButtonItemStylePlain
                   target:self action:@selector(ez_trashSelectionTapped)];
        self.trashSelectionItem.accessibilityLabel =
            NSLocalizedString(@"EZFileExplorer.MoveToTrash", @"Move to trash action");
        self.restoreSelectionItem = [[UIBarButtonItem alloc]
            initWithTitle:NSLocalizedString(@"EZFileExplorer.Restore", @"Restore action")
                    style:UIBarButtonItemStylePlain
                   target:self action:@selector(ez_restoreSelectionTapped)];
        self.deleteSelectionItem = [[UIBarButtonItem alloc]
            initWithTitle:NSLocalizedString(@"EZFileExplorer.DeletePermanently",
                                            @"Delete permanently action")
                    style:UIBarButtonItemStylePlain
                   target:self action:@selector(ez_deleteSelectionTapped)];
        self.deleteSelectionItem.tintColor = [UIColor systemRedColor];
    }
    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                             target:nil action:nil];
    if (self.isTrashFolder) {
        self.toolbarItems = @[self.selectionCountItem, flex,
                              self.restoreSelectionItem, self.deleteSelectionItem];
    } else {
        self.toolbarItems = @[self.selectionCountItem, flex,
                              self.createZipItem, self.extractItem,
                              self.shareSelectionItem, self.trashSelectionItem];
    }
}

- (NSArray<EZFileItem *> *)ez_selectedItems {
    NSMutableArray<EZFileItem *> *selected = [NSMutableArray array];
    NSArray<NSIndexPath *> *paths = [self.tableView.indexPathsForSelectedRows
        sortedArrayUsingComparator:^NSComparisonResult(NSIndexPath *a, NSIndexPath *b) {
            return a.row < b.row ? NSOrderedAscending : NSOrderedDescending;
        }];
    for (NSIndexPath *path in paths ?: @[]) {
        if (path.row < (NSInteger)self.items.count) {
            [selected addObject:self.items[(NSUInteger)path.row]];
        }
    }
    return selected;
}

- (void)ez_updateSelectionState {
    if (!self.editing) return;
    NSArray<EZFileItem *> *selected = [self ez_selectedItems];
    NSUInteger count = selected.count;
    self.selectionCountLabel.text = [NSString stringWithFormat:
        NSLocalizedString(@"EZFileExplorer.SelectedCount", @"Selected count"),
        (long)count];
    [self.selectionCountLabel sizeToFit];
    BOOL any = count > 0;
    BOOL anyExtractable = NO;
    for (EZFileItem *item in selected) {
        if ([item isZipArchive] || [item isTarArchive] ||
            [item isDebPackage] || [item isUnsupportedArchive]) {
            anyExtractable = YES;
            break;
        }
    }
    self.createZipItem.enabled = any;
    self.extractItem.enabled = anyExtractable;
    self.shareSelectionItem.enabled = any;
    self.trashSelectionItem.enabled = any;
    self.restoreSelectionItem.enabled = any;
    self.deleteSelectionItem.enabled = any;
}

- (void)ez_createZIPTapped {
    NSArray<EZFileItem *> *selected = [self ez_selectedItems];
    if (!selected.count) return;
    [self ez_promptForNameWithTitle:NSLocalizedString(@"EZFileExplorer.CreateZIP",
                                                      @"Create ZIP")
                      suggestedName:NSLocalizedString(@"EZFileExplorer.ArchiveName",
                                                      @"Default archive name")
                            handler:^(NSString *name) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"zip"]) {
            name = [name stringByAppendingPathExtension:@"zip"];
        }
        NSURL *destination = [self ez_uniqueURLForName:name inDirectory:self.rootURL];
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        for (EZFileItem *item in selected) [urls addObject:item.url];
        [self ez_showProgressWithTitle:
            NSLocalizedString(@"EZFileExplorer.CreatingZIP", @"Creating ZIP progress")];
        __weak typeof(self) weakSelf = self;
        [[EZArchiveService sharedService]
            createZIPAtURL:destination
              fromItemURLs:urls
                  progress:^(double fraction, NSString *entry) {
            [weakSelf ez_updateProgress:fraction entry:entry];
        } completion:^(BOOL success, NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            [self ez_hideProgress];
            if (!success && error.code != EZArchiveServiceErrorCancelled) {
                [self ez_presentErrorWithMessage:
                    NSLocalizedString(@"EZFileExplorer.CreateZIPFailed",
                                      @"Create ZIP failed")];
                return;
            }
            // Success — and cancellation, whose partial ZIP the service
            // already deleted — both just leave a refreshed listing.
            [self setEditing:NO animated:YES];
            [self ez_reload];
        }];
    }];
}

- (void)ez_extractSelectionTapped {
    NSMutableArray<EZFileItem *> *archives = [NSMutableArray array];
    EZFileItem *firstUnsupported = nil;
    for (EZFileItem *item in [self ez_selectedItems]) {
        if ([item isZipArchive] || [item isTarArchive] || [item isDebPackage]) {
            [archives addObject:item];
        } else if ([item isUnsupportedArchive] && !firstUnsupported) {
            firstUnsupported = item;
        }
    }
    if (!archives.count && !firstUnsupported) return;
    __weak typeof(self) weakSelf = self;
    void (^finish)(void) = ^{
        [weakSelf setEditing:NO animated:YES];
        [weakSelf ez_reload];
        if (firstUnsupported) {
            [weakSelf ez_presentUnsupportedExplanationForItem:firstUnsupported
                compressionName:[weakSelf ez_compressionNameForItem:firstUnsupported]];
        }
    };
    if (archives.count) {
        [self ez_extractArchives:archives then:finish];
    } else {
        finish();
    }
}

/// Extracts each archive into its own folder next to it ("Name", with
/// the usual never-overwrite suffixing), one at a time — password
/// prompts and progress stay per-archive so a failure is attributable
/// to the archive that caused it. The chain stops at the first hard
/// failure; skipped-entry reports accumulate and are summarized once
/// at the end.
- (void)ez_extractArchives:(NSArray<EZFileItem *> *)archives
                      then:(void (^)(void))done {
    [self ez_extractNextArchive:[archives mutableCopy]
                       skipped:[NSMutableArray array]
                          then:done];
}

- (void)ez_extractNextArchive:(NSMutableArray<EZFileItem *> *)queue
                      skipped:(NSMutableArray<NSString *> *)skipped
                         then:(void (^)(void))done {
    EZFileItem *item = queue.firstObject;
    if (!item) {
        if (skipped.count) {
            NSString *list = [[skipped subarrayWithRange:
                NSMakeRange(0, MIN(skipped.count, (NSUInteger)5))]
                componentsJoinedByString:@"\n"];
            [self ez_presentNotice:[NSString stringWithFormat:@"%@\n%@",
                [NSString stringWithFormat:
                    NSLocalizedString(@"EZFileExplorer.ExtractSkipped",
                                      @"Skipped entries summary"),
                    (long)skipped.count],
                list]];
        }
        if (done) done();
        return;
    }
    [queue removeObjectAtIndex:0];
    NSString *base = item.name.stringByDeletingPathExtension;
    NSURL *destination = [self ez_uniqueURLForName:base inDirectory:self.rootURL];
    if ([EZArchiveService archiveRequiresPassword:item.url]) {
        [self ez_promptForPasswordForItem:item
                                    then:^(NSString *password) {
            if (!password) { // cancelled: skip this archive, keep going
                [self ez_extractNextArchive:queue skipped:skipped then:done];
                return;
            }
            if (![EZArchiveService isPasswordValid:password forArchiveAtURL:item.url]) {
                [self ez_presentErrorWithMessage:
                    NSLocalizedString(@"EZFileExplorer.WrongPassword",
                                      @"Wrong password message")];
                if (done) done();
                return;
            }
            [self ez_runExtractionOfItem:item
                            toDirectory:destination
                               password:password
                                  queue:queue
                                skipped:skipped
                                   then:done];
        }];
        return;
    }
    [self ez_runExtractionOfItem:item
                    toDirectory:destination
                       password:nil
                          queue:queue
                        skipped:skipped
                           then:done];
}

- (void)ez_runExtractionOfItem:(EZFileItem *)item
                 toDirectory:(NSURL *)destination
                    password:(nullable NSString *)password
                       queue:(NSMutableArray<EZFileItem *> *)queue
                     skipped:(NSMutableArray<NSString *> *)skipped
                        then:(void (^)(void))done {
    [self ez_showProgressWithTitle:
        NSLocalizedString(@"EZFileExplorer.Extracting", @"Extracting progress")];
    __weak typeof(self) weakSelf = self;
    EZArchiveProgressBlock progressBlock = ^(double fraction, NSString *entry) {
        [weakSelf ez_updateProgress:fraction entry:entry];
    };
    EZArchiveExtractCompletion completionBlock =
        ^(BOOL success, NSArray<NSString *> *entrySkipped, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        [self ez_hideProgress];
        if (!success) {
            // The folder was created for this extraction — remove the
            // partial output so a failed extract leaves no debris that
            // looks like a result.
            [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
            if (error.code == EZArchiveServiceErrorCancelled) {
                // The user asked for this stop; nothing to report.
            } else if (error.code == EZArchiveServiceErrorUnsupportedCompression) {
                NSString *format = error.userInfo[EZArchiveServiceCompressionFormatKey]
                    ?: [self ez_compressionNameForItem:item];
                [self ez_presentUnsupportedExplanationForItem:item
                                              compressionName:format];
            } else {
                [self ez_presentErrorWithMessage:[NSString stringWithFormat:
                    NSLocalizedString(@"EZFileExplorer.ExtractFailed",
                                      @"Extract failed message"),
                    item.displayName]];
            }
            if (done) done();
            return;
        }
        [skipped addObjectsFromArray:entrySkipped];
        [self ez_extractNextArchive:queue skipped:skipped then:done];
    };
    EZArchiveService *service = [EZArchiveService sharedService];
    if ([item isDebPackage]) {
        [service extractDebAtURL:item.url
                   toDirectory:destination
                      progress:progressBlock
                    completion:completionBlock];
    } else if ([item isTarArchive]) {
        [service extractTarAtURL:item.url
                   toDirectory:destination
                      progress:progressBlock
                    completion:completionBlock];
    } else {
        [service extractZIPAtURL:item.url
                   toDirectory:destination
                      password:password
                      progress:progressBlock
                    completion:completionBlock];
    }
}

- (void)ez_promptForPasswordForItem:(EZFileItem *)item
                               then:(void (^)(NSString *_Nullable password))next {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.PasswordTitle",
                                                   @"Password prompt title")
                         message:[NSString stringWithFormat:
            NSLocalizedString(@"EZFileExplorer.PasswordMessage",
                              @"Password prompt body"), item.displayName]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.secureTextEntry = YES;
        textField.placeholder = NSLocalizedString(@"EZFileExplorer.PasswordPlaceholder",
                                                  @"Password field placeholder");
    }];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Cancel", @"Cancel button")
                  style:UIAlertActionStyleCancel
                handler:^(__unused UIAlertAction *a) { next(nil); }]];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Unlock", @"Unlock button")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *a) {
        next(alert.textFields.firstObject.text ?: @"");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ez_shareSelectionTapped {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (EZFileItem *item in [self ez_selectedItems]) [urls addObject:item.url];
    if (!urls.count) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc]
        initWithActivityItems:urls applicationActivities:nil];
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = self.view;
        avc.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds),
                       CGRectGetMaxY(self.view.bounds) - 60, 1, 1);
    }
    [self presentViewController:avc animated:YES completion:nil];
}

- (void)ez_trashSelectionTapped {
    NSError *firstError = nil;
    for (EZFileItem *item in [self ez_selectedItems]) {
        NSError *error = nil;
        if (![self ez_moveURLToTrash:item.url error:&error] && !firstError) {
            firstError = error;
        }
    }
    [self setEditing:NO animated:YES];
    [self ez_reload];
    if (firstError) [self ez_presentError:firstError];
}

- (void)ez_restoreSelectionTapped {
    NSURL *docs = [[self class] ez_documentsURL];
    NSError *firstError = nil;
    for (EZFileItem *item in [self ez_selectedItems]) {
        NSURL *destination = [self ez_uniqueURLForName:item.name inDirectory:docs];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] moveItemAtURL:item.url
                                                     toURL:destination
                                                     error:&error] && !firstError) {
            firstError = error;
        }
    }
    [self setEditing:NO animated:YES];
    [self ez_reload];
    if (firstError) [self ez_presentError:firstError];
}

- (void)ez_deleteSelectionTapped {
    NSArray<EZFileItem *> *selected = [self ez_selectedItems];
    if (!selected.count) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.DeletePermanently",
                                                   @"Delete permanently title")
                         message:[NSString stringWithFormat:
            NSLocalizedString(@"EZFileExplorer.DeleteMultipleMessage",
                              @"Delete multiple body"), (long)selected.count]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Cancel", @"Cancel button")
                  style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Delete", @"Delete button")
                  style:UIAlertActionStyleDestructive
                handler:^(__unused UIAlertAction *a) {
        NSError *firstError = nil;
        for (EZFileItem *item in selected) {
            NSError *error = nil;
            if (![[NSFileManager defaultManager] removeItemAtURL:item.url
                                                            error:&error] && !firstError) {
                firstError = error;
            }
        }
        [self setEditing:NO animated:YES];
        [self ez_reload];
        if (firstError) [self ez_presentError:firstError];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Progress overlay

/// A small modal progress card (dim + centered panel). Archive work is
/// usually seconds, but a multi-hundred-MB ZIP without feedback reads
/// as a hang — and a hang reads as a bug.
- (void)ez_showProgressWithTitle:(NSString *)title {
    [self ez_hideProgress];
    UIView *overlay = [[UIView alloc] init];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 14;

    self.progressTitleLabel = [[UILabel alloc] init];
    self.progressTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressTitleLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.progressTitleLabel.text = title;
    self.progressTitleLabel.textAlignment = NSTextAlignmentCenter;

    self.progressEntryLabel = [[UILabel alloc] init];
    self.progressEntryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressEntryLabel.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.progressEntryLabel.textColor = [UIColor secondaryLabelColor];
    self.progressEntryLabel.textAlignment = NSTextAlignmentCenter;
    self.progressEntryLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    self.progressBar = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressBar.progress = 0;

    // Long operations can be cancelled (plan safety rail) — the
    // service stops at the next chunk/entry boundary and its
    // completion dismisses this card.
    self.progressCancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.progressCancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.progressCancelButton setTitle:NSLocalizedString(@"EZFileExplorer.Cancel",
                                                          @"Cancel button")
                               forState:UIControlStateNormal];
    [self.progressCancelButton addTarget:self
                                  action:@selector(ez_cancelOperationTapped)
                        forControlEvents:UIControlEventTouchUpInside];

    [card addSubview:self.progressTitleLabel];
    [card addSubview:self.progressEntryLabel];
    [card addSubview:self.progressBar];
    [card addSubview:self.progressCancelButton];
    [overlay addSubview:card];
    [self.view addSubview:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:270],
        [self.progressTitleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [self.progressTitleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.progressTitleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.progressBar.topAnchor constraintEqualToAnchor:self.progressTitleLabel.bottomAnchor constant:14],
        [self.progressBar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.progressEntryLabel.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor constant:10],
        [self.progressEntryLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.progressEntryLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.progressCancelButton.topAnchor constraintEqualToAnchor:self.progressEntryLabel.bottomAnchor constant:6],
        [self.progressCancelButton.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [self.progressCancelButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10],
    ]];
    self.progressOverlay = overlay;
}

- (void)ez_cancelOperationTapped {
    self.progressCancelButton.enabled = NO;
    [[EZArchiveService sharedService] cancelCurrentOperation];
}

- (void)ez_updateProgress:(double)fraction entry:(NSString *)entry {
    if (!self.progressOverlay) return;
    self.progressBar.progress = (float)fraction;
    self.progressEntryLabel.text = entry;
}

- (void)ez_hideProgress {
    [self.progressOverlay removeFromSuperview];
    self.progressOverlay = nil;
    self.progressBar = nil;
    self.progressTitleLabel = nil;
    self.progressEntryLabel = nil;
    self.progressCancelButton = nil;
}

#pragma mark - Alerts

- (void)ez_presentError:(nullable NSError *)error {
    [self ez_presentErrorWithMessage:error.localizedDescription];
}

- (void)ez_presentErrorWithMessage:(nullable NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.Error", @"Error title")
                         message:message.length ? message
                             : NSLocalizedString(@"EZFileExplorer.ActionFailed",
                                                 @"Generic failure message")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.OK", @"OK button")
                  style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ez_presentNotice:(NSString *)message {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:nil
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.OK", @"OK button")
                  style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Icons

- (NSString *)ez_symbolNameForItem:(EZFileItem *)item {
    if (item.isDirectory) return @"folder";
    if ([item isRARArchive] || [item isArchiveFile]) return @"archivebox";
    UTType *t = item.contentType;
    if ([t conformsToType:UTTypeImage]) return @"photo";
    if ([t conformsToType:UTTypeMovie]) return @"film";
    if ([t conformsToType:UTTypeAudio]) return @"waveform";
    if ([t conformsToType:UTTypePDF]) return @"doc.richtext";
    if ([t conformsToType:UTTypeSpreadsheet]) return @"tablecells";
    if ([t conformsToType:UTTypePresentation]) return @"rectangle.on.rectangle";
    if ([t conformsToType:UTTypeSourceCode]) return @"chevron.left.forwardslash.chevron.right";
    if ([item isTextFile]) return @"doc.text";
    if ([t conformsToType:UTTypeText]) return @"doc.text";
    return @"doc";
}

@end

NS_ASSUME_NONNULL_END
