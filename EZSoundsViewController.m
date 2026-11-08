//
//  EZSoundsViewController.m
//  EZSounds
//

#import "EZSoundsViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "helpers.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZMediaPlayerManager.h"
#import "EZSoundLibraryManager.h"
#import "EZSoundManifestEntry.h"
#import "EZTTSLibraryManager.h"
#import "EZTTSManifestEntry.h"

// ── Neon arcade palette (mirrors TextToSpeechViewController) ────────────────
static UIColor *EZSoundsNeonBackground(void) { return [UIColor colorWithRed:0.03 green:0.02 blue:0.09 alpha:1.0]; }
static UIColor *EZSoundsNeonPanel(void)      { return [UIColor colorWithRed:0.09 green:0.05 blue:0.18 alpha:1.0]; }
static UIColor *EZSoundsNeonField(void)      { return [UIColor colorWithRed:0.14 green:0.09 blue:0.28 alpha:1.0]; }
static UIColor *EZSoundsNeonViolet(void)     { return [UIColor colorWithRed:0.70 green:0.28 blue:1.00 alpha:1.0]; }
static UIColor *EZSoundsNeonCyan(void)       { return [UIColor colorWithRed:0.00 green:0.88 blue:1.00 alpha:1.0]; }
static UIColor *EZSoundsNeonMint(void)       { return [UIColor colorWithRed:0.15 green:0.95 blue:0.80 alpha:1.0]; }
static UIColor *EZSoundsNeonPink(void)       { return [UIColor colorWithRed:1.00 green:0.25 blue:0.62 alpha:1.0]; }
static UIColor *EZSoundsNeonText(void)       { return [UIColor colorWithRed:0.94 green:0.92 blue:1.00 alpha:1.0]; }
static UIColor *EZSoundsNeonDimText(void)    { return [UIColor colorWithRed:0.66 green:0.60 blue:0.90 alpha:1.0]; }

static NSString * const kEZSoundsPlayerIdentifierPrefix = @"sound:";
static NSInteger const kEZSoundsMaxSeconds = 30;
static NSInteger const kEZSoundsMinSeconds = 1;
// Same rate the server charges for background audio (30 coins/minute,
// 5-coin minimum) — display only; the server is authoritative.
static NSInteger EZSoundsEstimatedCost(NSInteger seconds) {
    return MAX(5, (NSInteger)ceil(seconds * 0.5));
}

// ── TTS clip picker (used by "Use as TTS Background") ───────────────────────

@interface EZSoundsTTSClipPickerViewController : UITableViewController
@property (nonatomic, copy) void (^onPick)(EZTTSManifestEntry *entry);
@end

@implementation EZSoundsTTSClipPickerViewController {
    NSArray<EZTTSManifestEntry *> *_clips;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedString(@"EZSounds.PickTTSClip", nil);
    self.view.backgroundColor = EZSoundsNeonBackground();
    _clips = [[EZTTSLibraryManager sharedManager] allClipsSortedByDateDescending];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_clips.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"clip"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"clip"];
    EZTTSManifestEntry *entry = _clips[indexPath.row];
    cell.backgroundColor = EZSoundsNeonPanel();
    cell.textLabel.text = entry.preview.length ? entry.preview : entry.prompt;
    cell.textLabel.textColor = EZSoundsNeonText();
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@",
        [EZMediaPlayerManager formattedTime:entry.duration],
        entry.voiceName ?: @""];
    cell.detailTextLabel.textColor = EZSoundsNeonDimText();
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.onPick) self.onPick(_clips[indexPath.row]);
}

@end

// ── Sounds view controller ──────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, EZSoundsTab) {
    EZSoundsTabLibrary = 0,
    EZSoundsTabCreate  = 1,
};

@interface EZSoundsViewController () <UITableViewDataSource, UITableViewDelegate,
                                      UITextViewDelegate,
                                      UIImagePickerControllerDelegate, UINavigationControllerDelegate,
                                      UIDocumentPickerDelegate>
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UIView *createPanel;
@property (nonatomic, strong) UITableView *libraryTable;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIButton *playAllButton;

@property (nonatomic, strong) UITextView *promptView;
@property (nonatomic, strong) UILabel *promptPlaceholder;
@property (nonatomic, strong) UISlider *durationSlider;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UILabel *costLabel;
@property (nonatomic, strong) UISwitch *loopSwitch;
@property (nonatomic, strong) UIButton *generateButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@property (nonatomic, copy) NSArray<EZSoundManifestEntry *> *entries;
@property (nonatomic, strong) EZSoundManifestEntry *pendingVideoEntry;
@property (nonatomic, assign) BOOL generating;
@end

@implementation EZSoundsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedString(@"EZSounds.Title", nil);
    self.view.backgroundColor = EZSoundsNeonBackground();
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(closeTapped)];
    [self buildUI];
    [self reloadEntries];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerDidUpdate:)
                                                 name:EZMediaPlayerDidUpdateNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadEntries];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UI construction

- (void)buildUI {
    // Segmented tabs — Library on the left, Create on the right, and the
    // screen opens on Create (same arrangement as the Music screen).
    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[
        NSLocalizedString(@"EZSounds.LibraryTab", nil),
        NSLocalizedString(@"EZSounds.CreateTab", nil)]];
    self.tabControl.selectedSegmentIndex = EZSoundsTabCreate;
    self.tabControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabControl.backgroundColor = EZSoundsNeonPanel();
    self.tabControl.selectedSegmentTintColor = EZSoundsNeonViolet();
    [self.tabControl setTitleTextAttributes:@{NSForegroundColorAttributeName: EZSoundsNeonText()}
                                   forState:UIControlStateNormal];
    [self.tabControl addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabControl];

    [self buildCreatePanel];
    [self buildLibraryPanel];

    [NSLayoutConstraint activateConstraints:@[
        [self.tabControl.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [self.tabControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.tabControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [self.createPanel.topAnchor constraintEqualToAnchor:self.tabControl.bottomAnchor constant:12],
        [self.createPanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.createPanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.createPanel.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.libraryTable.topAnchor constraintEqualToAnchor:self.tabControl.bottomAnchor constant:12],
        [self.libraryTable.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.libraryTable.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.libraryTable.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self tabChanged];
}

- (UIView *)panelWithAccent:(UIColor *)accent {
    UIView *panel = [[UIView alloc] init];
    panel.backgroundColor = EZSoundsNeonPanel();
    panel.layer.cornerRadius = 14;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = accent.CGColor;
    panel.layer.shadowColor = EZSoundsNeonViolet().CGColor;
    panel.layer.shadowOpacity = 0.35;
    panel.layer.shadowRadius = 8;
    panel.layer.shadowOffset = CGSizeMake(0, 0);
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    return panel;
}

- (void)buildCreatePanel {
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    self.createPanel = scroll;
    [self.view addSubview:scroll];

    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    // Prompt panel
    UIView *promptPanel = [self panelWithAccent:EZSoundsNeonCyan()];
    [content addSubview:promptPanel];

    self.promptView = [[UITextView alloc] init];
    self.promptView.delegate = self;
    self.promptView.backgroundColor = [UIColor clearColor];
    self.promptView.textColor = EZSoundsNeonText();
    self.promptView.font = [UIFont systemFontOfSize:16];
    self.promptView.translatesAutoresizingMaskIntoConstraints = NO;
    [promptPanel addSubview:self.promptView];

    self.promptPlaceholder = [[UILabel alloc] init];
    self.promptPlaceholder.text = NSLocalizedString(@"EZSounds.PromptPlaceholder", nil);
    self.promptPlaceholder.textColor = EZSoundsNeonDimText();
    self.promptPlaceholder.font = [UIFont systemFontOfSize:16];
    self.promptPlaceholder.numberOfLines = 0;
    self.promptPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    [promptPanel addSubview:self.promptPlaceholder];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = NSLocalizedString(@"EZSounds.PromptHint", nil);
    hint.textColor = EZSoundsNeonDimText();
    hint.font = [UIFont systemFontOfSize:12.5];
    hint.numberOfLines = 0;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:hint];

    // Duration panel
    UIView *durationPanel = [self panelWithAccent:EZSoundsNeonViolet()];
    [content addSubview:durationPanel];

    self.durationLabel = [[UILabel alloc] init];
    self.durationLabel.textColor = EZSoundsNeonText();
    self.durationLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [durationPanel addSubview:self.durationLabel];

    self.costLabel = [[UILabel alloc] init];
    self.costLabel.textColor = EZSoundsNeonDimText();
    self.costLabel.font = [UIFont systemFontOfSize:12.5];
    self.costLabel.textAlignment = NSTextAlignmentRight;
    self.costLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [durationPanel addSubview:self.costLabel];

    self.durationSlider = [[UISlider alloc] init];
    self.durationSlider.minimumValue = (float)kEZSoundsMinSeconds;
    self.durationSlider.maximumValue = (float)kEZSoundsMaxSeconds;
    self.durationSlider.value = 15;
    self.durationSlider.minimumTrackTintColor = EZSoundsNeonCyan();
    self.durationSlider.maximumTrackTintColor = EZSoundsNeonField();
    self.durationSlider.thumbTintColor = EZSoundsNeonMint();
    self.durationSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.durationSlider addTarget:self action:@selector(durationChanged) forControlEvents:UIControlEventValueChanged];
    [durationPanel addSubview:self.durationSlider];

    // Loop row
    UIView *loopPanel = [self panelWithAccent:EZSoundsNeonViolet()];
    [content addSubview:loopPanel];

    UILabel *loopLabel = [[UILabel alloc] init];
    loopLabel.text = NSLocalizedString(@"EZSounds.Loop", nil);
    loopLabel.textColor = EZSoundsNeonText();
    loopLabel.font = [UIFont systemFontOfSize:16];
    loopLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [loopPanel addSubview:loopLabel];

    UILabel *loopHint = [[UILabel alloc] init];
    loopHint.text = NSLocalizedString(@"EZSounds.LoopHint", nil);
    loopHint.textColor = EZSoundsNeonDimText();
    loopHint.font = [UIFont systemFontOfSize:12.5];
    loopHint.numberOfLines = 0;
    loopHint.translatesAutoresizingMaskIntoConstraints = NO;
    [loopPanel addSubview:loopHint];

    self.loopSwitch = [[UISwitch alloc] init];
    self.loopSwitch.on = YES;
    self.loopSwitch.onTintColor = EZSoundsNeonMint();
    self.loopSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [loopPanel addSubview:self.loopSwitch];

    // Generate button + status
    self.generateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.generateButton setTitle:NSLocalizedString(@"EZSounds.Generate", nil) forState:UIControlStateNormal];
    [self.generateButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.generateButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    self.generateButton.backgroundColor = EZSoundsNeonPink();
    self.generateButton.layer.cornerRadius = 12;
    self.generateButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.generateButton addTarget:self action:@selector(generateTapped) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.generateButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = EZSoundsNeonCyan();
    self.spinner.hidesWhenStopped = YES;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.spinner];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.textColor = EZSoundsNeonMint();
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],

        [promptPanel.topAnchor constraintEqualToAnchor:content.topAnchor constant:4],
        [promptPanel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [promptPanel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.promptView.topAnchor constraintEqualToAnchor:promptPanel.topAnchor constant:6],
        [self.promptView.leadingAnchor constraintEqualToAnchor:promptPanel.leadingAnchor constant:8],
        [self.promptView.trailingAnchor constraintEqualToAnchor:promptPanel.trailingAnchor constant:-8],
        [self.promptView.bottomAnchor constraintEqualToAnchor:promptPanel.bottomAnchor constant:-6],
        [self.promptView.heightAnchor constraintEqualToConstant:96],
        [self.promptPlaceholder.topAnchor constraintEqualToAnchor:promptPanel.topAnchor constant:14],
        [self.promptPlaceholder.leadingAnchor constraintEqualToAnchor:promptPanel.leadingAnchor constant:13],
        [self.promptPlaceholder.trailingAnchor constraintEqualToAnchor:promptPanel.trailingAnchor constant:-13],

        [hint.topAnchor constraintEqualToAnchor:promptPanel.bottomAnchor constant:8],
        [hint.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [hint.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],

        [durationPanel.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:12],
        [durationPanel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [durationPanel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.durationLabel.topAnchor constraintEqualToAnchor:durationPanel.topAnchor constant:12],
        [self.durationLabel.leadingAnchor constraintEqualToAnchor:durationPanel.leadingAnchor constant:14],
        [self.costLabel.centerYAnchor constraintEqualToAnchor:self.durationLabel.centerYAnchor],
        [self.costLabel.trailingAnchor constraintEqualToAnchor:durationPanel.trailingAnchor constant:-14],
        [self.costLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.durationLabel.trailingAnchor constant:8],
        [self.durationSlider.topAnchor constraintEqualToAnchor:self.durationLabel.bottomAnchor constant:6],
        [self.durationSlider.leadingAnchor constraintEqualToAnchor:durationPanel.leadingAnchor constant:14],
        [self.durationSlider.trailingAnchor constraintEqualToAnchor:durationPanel.trailingAnchor constant:-14],
        [self.durationSlider.bottomAnchor constraintEqualToAnchor:durationPanel.bottomAnchor constant:-10],

        [loopPanel.topAnchor constraintEqualToAnchor:durationPanel.bottomAnchor constant:12],
        [loopPanel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [loopPanel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [loopLabel.topAnchor constraintEqualToAnchor:loopPanel.topAnchor constant:12],
        [loopLabel.leadingAnchor constraintEqualToAnchor:loopPanel.leadingAnchor constant:14],
        [self.loopSwitch.centerYAnchor constraintEqualToAnchor:loopLabel.centerYAnchor],
        [self.loopSwitch.trailingAnchor constraintEqualToAnchor:loopPanel.trailingAnchor constant:-14],
        [loopHint.topAnchor constraintEqualToAnchor:loopLabel.bottomAnchor constant:4],
        [loopHint.leadingAnchor constraintEqualToAnchor:loopPanel.leadingAnchor constant:14],
        [loopHint.trailingAnchor constraintEqualToAnchor:self.loopSwitch.leadingAnchor constant:-10],
        [loopHint.bottomAnchor constraintEqualToAnchor:loopPanel.bottomAnchor constant:-12],

        [self.generateButton.topAnchor constraintEqualToAnchor:loopPanel.bottomAnchor constant:18],
        [self.generateButton.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [self.generateButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [self.generateButton.heightAnchor constraintEqualToConstant:50],

        [self.spinner.topAnchor constraintEqualToAnchor:self.generateButton.bottomAnchor constant:14],
        [self.spinner.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.generateButton.bottomAnchor constant:14],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24],
    ]];
    [self durationChanged];
}

- (void)buildLibraryPanel {
    self.libraryTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.libraryTable.dataSource = self;
    self.libraryTable.delegate = self;
    self.libraryTable.backgroundColor = [UIColor clearColor];
    self.libraryTable.separatorColor = [EZSoundsNeonViolet() colorWithAlphaComponent:0.35];
    self.libraryTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.libraryTable.rowHeight = 64;
    [self.view addSubview:self.libraryTable];

    self.playAllButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.playAllButton setTitle:NSLocalizedString(@"EZSounds.PlayAll", nil) forState:UIControlStateNormal];
    [self.playAllButton setTitleColor:EZSoundsNeonCyan() forState:UIControlStateNormal];
    self.playAllButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.playAllButton addTarget:self action:@selector(playAllTapped) forControlEvents:UIControlEventTouchUpInside];
    self.playAllButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 40)];
    [header addSubview:self.playAllButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.playAllButton.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [self.playAllButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];
    self.libraryTable.tableHeaderView = header;

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text = NSLocalizedString(@"EZSounds.EmptyLibrary", nil);
    self.emptyLabel.textColor = EZSoundsNeonDimText();
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
}

- (void)tabChanged {
    BOOL library = (self.tabControl.selectedSegmentIndex == EZSoundsTabLibrary);
    self.createPanel.hidden = library;
    self.libraryTable.hidden = !library;
    self.emptyLabel.hidden = !library || self.entries.count > 0;
    if (library) [self.libraryTable reloadData];
}

#pragma mark - Create tab

- (NSInteger)selectedSeconds {
    return (NSInteger)lroundf(self.durationSlider.value);
}

- (void)durationChanged {
    NSInteger seconds = [self selectedSeconds];
    self.durationLabel.text = [NSString stringWithFormat:
        NSLocalizedString(@"EZSounds.Duration", nil), (long)seconds];
    self.costLabel.text = [NSString stringWithFormat:
        NSLocalizedString(@"EZSounds.Cost", nil), (long)EZSoundsEstimatedCost(seconds)];
}

- (void)textViewDidChange:(UITextView *)textView {
    self.promptPlaceholder.hidden = textView.text.length > 0;
}

- (void)generateTapped {
    if (self.generating) return;
    NSString *prompt = [self.promptView.text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (prompt.length < 3) {
        [self showAlertTitle:NSLocalizedString(@"EZSounds.Title", nil)
                     message:NSLocalizedString(@"EZSounds.PromptTooShort", nil)];
        return;
    }
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token.length) {
        [self showAlertTitle:NSLocalizedString(@"EZSounds.Title", nil)
                     message:NSLocalizedString(@"EZSounds.SignInRequired", nil)];
        return;
    }
    [self.promptView resignFirstResponder];
    [self setGenerating:YES status:NSLocalizedString(@"EZSounds.Generating", nil)];

    NSInteger seconds = [self selectedSeconds];
    BOOL loop = self.loopSwitch.on;
    NSURL *url = [NSURL URLWithString:@"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-elevenlabs"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 100;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"action":           @"generate_sound",
        @"prompt":           prompt,
        @"duration_seconds": @(seconds),
        @"loop":             @(loop),
    } options:0 error:nil];

    EZLogf(EZLogLevelInfo, @"SOUNDS", @"Requesting sound: %ld sec, loop=%d", (long)seconds, loop);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class]) json = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || http.statusCode != 200) {
                NSString *reason = [json[@"reason"] isKindOfClass:NSString.class] ? json[@"reason"] : nil;
                if (http.statusCode == 402) {
                    NSNumber *bal  = [json[@"balance"] isKindOfClass:NSNumber.class] ? json[@"balance"] : nil;
                    NSNumber *cost = [json[@"cost"] isKindOfClass:NSNumber.class] ? json[@"cost"] : nil;
                    if (bal && cost) {
                        reason = [NSString stringWithFormat:
                            NSLocalizedString(@"EZSounds.NeedCoins", nil), cost, bal];
                    }
                }
                [self setGenerating:NO status:nil];
                [self showAlertTitle:NSLocalizedString(@"EZSounds.ErrorTitle", nil)
                             message:(reason ?: error.localizedDescription
                                      ?: NSLocalizedString(@"EZSounds.GenericError", nil))];
                return;
            }
            NSString *b64 = [json[@"audio_b64"] isKindOfClass:NSString.class] ? json[@"audio_b64"] : nil;
            NSData *audio = b64.length ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
            if (!audio.length) {
                [self setGenerating:NO status:nil];
                [self showAlertTitle:NSLocalizedString(@"EZSounds.ErrorTitle", nil)
                             message:NSLocalizedString(@"EZSounds.GenericError", nil)];
                return;
            }
            NSNumber *balance = [json[@"balance"] isKindOfClass:NSNumber.class] ? json[@"balance"] : nil;
            if (balance) [[EZEntitlementManager shared] applyKnownBalance:balance.integerValue];
            NSNumber *coinsSpent = [json[@"coins_spent"] isKindOfClass:NSNumber.class] ? json[@"coins_spent"] : nil;

            NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
            metadata[@"requestedSeconds"] = @(seconds);
            metadata[@"loop"] = @(loop);
            if (coinsSpent) metadata[@"coinsSpent"] = coinsSpent;
            [[EZSoundLibraryManager sharedManager]
                saveAudioData:audio
                       prompt:prompt
                     provider:@"elevenlabs"
                        model:@"eleven_text_to_sound_v2"
                    extension:@"mp3"
                     metadata:metadata
                   completion:^(EZSoundManifestEntry *entry, NSError *saveError) {
                [self setGenerating:NO status:nil];
                if (!entry) {
                    [self showAlertTitle:NSLocalizedString(@"EZSounds.ErrorTitle", nil)
                                 message:(saveError.localizedDescription
                                          ?: NSLocalizedString(@"EZSounds.GenericError", nil))];
                    return;
                }
                self.statusLabel.text = NSLocalizedString(@"EZSounds.Saved", nil);
                [self reloadEntries];
                [self playEntry:entry queueRest:NO];
                self.tabControl.selectedSegmentIndex = EZSoundsTabLibrary;
                [self tabChanged];
            }];
        });
    }] resume];
}

- (void)setGenerating:(BOOL)generating status:(NSString *)status {
    self.generating = generating;
    self.generateButton.enabled = !generating;
    self.generateButton.alpha = generating ? 0.55 : 1.0;
    self.statusLabel.text = status;
    if (generating) [self.spinner startAnimating]; else [self.spinner stopAnimating];
}

#pragma mark - Library data + playback

- (void)reloadEntries {
    self.entries = [[EZSoundLibraryManager sharedManager] allSoundsSortedByDateDescending];
    self.playAllButton.enabled = self.entries.count > 0;
    self.playAllButton.alpha = self.entries.count > 0 ? 1.0 : 0.4;
    [self.libraryTable reloadData];
    if (self.tabControl.selectedSegmentIndex == EZSoundsTabLibrary) {
        self.emptyLabel.hidden = self.entries.count > 0;
    }
}

- (EZMediaPlayerItem *)playerItemForEntry:(EZSoundManifestEntry *)entry {
    NSURL *url = [[EZSoundLibraryManager sharedManager] absoluteURLForEntry:entry];
    return [EZMediaPlayerItem itemWithIdentifier:[kEZSoundsPlayerIdentifierPrefix stringByAppendingString:entry.uuid]
                                           title:(entry.preview.length ? entry.preview : entry.prompt)
                                        subtitle:@"EZCompleteUI"
                                         fileURL:url
                                    durationHint:entry.duration];
}

- (void)playEntry:(EZSoundManifestEntry *)entry queueRest:(BOOL)queueRest {
    EZMediaPlayerManager *player = [EZMediaPlayerManager sharedManager];
    if ([player isCurrentItemWithIdentifier:[kEZSoundsPlayerIdentifierPrefix stringByAppendingString:entry.uuid]]) {
        [player togglePlayPause];
        return;
    }
    [player playItem:[self playerItemForEntry:entry]];
    if (queueRest) {
        NSUInteger idx = [self.entries indexOfObject:entry];
        if (idx != NSNotFound && idx + 1 < self.entries.count) {
            NSMutableArray<EZMediaPlayerItem *> *rest = [NSMutableArray array];
            for (NSUInteger i = idx + 1; i < self.entries.count; i++) {
                [rest addObject:[self playerItemForEntry:self.entries[i]]];
            }
            [player replaceUpNext:rest];
        }
    }
}

- (void)playAllTapped {
    if (!self.entries.count) return;
    NSMutableArray<EZMediaPlayerItem *> *items = [NSMutableArray array];
    for (EZSoundManifestEntry *entry in self.entries) [items addObject:[self playerItemForEntry:entry]];
    EZMediaPlayerManager *player = [EZMediaPlayerManager sharedManager];
    [player playItem:items.firstObject];
    [player replaceUpNext:[items subarrayWithRange:NSMakeRange(1, items.count - 1)]];
}

- (void)playerDidUpdate:(NSNotification *)note {
    [self.libraryTable reloadData];
}

- (BOOL)entryIsCurrent:(EZSoundManifestEntry *)entry {
    return [[EZMediaPlayerManager sharedManager]
        isCurrentItemWithIdentifier:[kEZSoundsPlayerIdentifierPrefix stringByAppendingString:entry.uuid]];
}

- (BOOL)entryIsPlaying:(EZSoundManifestEntry *)entry {
    EZMediaPlayerManager *player = [EZMediaPlayerManager sharedManager];
    return [self entryIsCurrent:entry] &&
           (player.state == EZMediaPlayerStatePlaying || player.state == EZMediaPlayerStateLoading);
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"sound"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"sound"];
    EZSoundManifestEntry *entry = self.entries[indexPath.row];
    cell.backgroundColor = EZSoundsNeonPanel();
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    BOOL playing = [self entryIsPlaying:entry];
    BOOL current = [self entryIsCurrent:entry];
    NSString *symbol = playing ? @"pause.circle.fill" : @"play.circle.fill";
    UIImage *icon = [UIImage systemImageNamed:symbol];
    cell.imageView.image = icon;
    cell.imageView.tintColor = current ? EZSoundsNeonPink() : EZSoundsNeonCyan();

    cell.textLabel.text = entry.preview.length ? entry.preview : entry.prompt;
    cell.textLabel.textColor = current ? EZSoundsNeonPink() : EZSoundsNeonText();
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.textLabel.numberOfLines = 1;

    NSString *durationText = [EZMediaPlayerManager formattedTime:entry.duration];
    BOOL loop = [entry.metadata[@"loop"] respondsToSelector:@selector(boolValue)] && [entry.metadata[@"loop"] boolValue];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@%@%@",
        durationText,
        loop ? @" • ∞" : @"",
        entry.isFavorite ? @" • ★" : @"",
        [NSString stringWithFormat:@" • %@", [fmt stringFromDate:entry.created]]];
    cell.detailTextLabel.textColor = EZSoundsNeonDimText();
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12.5];

    UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
    more.frame = CGRectMake(0, 0, 44, 44);
    [more setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
    more.tintColor = EZSoundsNeonDimText();
    more.tag = indexPath.row;
    [more addTarget:self action:@selector(moreTapped:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = more;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [self playEntry:self.entries[indexPath.row] queueRest:YES];
    [tableView reloadData];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    EZSoundManifestEntry *entry = self.entries[indexPath.row];
    UIContextualAction *deleteAction =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:NSLocalizedString(@"EZSounds.Delete", nil)
                                              handler:^(UIContextualAction *action, UIView *sourceView,
                                                        void (^completionHandler)(BOOL)) {
        [self confirmDeleteEntry:entry];
        completionHandler(YES);
    }];
    UIContextualAction *favoriteAction =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                title:(entry.isFavorite
                                                       ? NSLocalizedString(@"EZSounds.Unfavorite", nil)
                                                       : NSLocalizedString(@"EZSounds.Favorite", nil))
                                              handler:^(UIContextualAction *action, UIView *sourceView,
                                                        void (^completionHandler)(BOOL)) {
        [[EZSoundLibraryManager sharedManager] setFavorite:!entry.isFavorite
                                              forSoundUUID:entry.uuid
                                                completion:^(EZSoundManifestEntry *updated, NSError *error) {
            [self reloadEntries];
        }];
        completionHandler(YES);
    }];
    favoriteAction.backgroundColor = [UIColor colorWithRed:0.85 green:0.65 blue:0.05 alpha:1.0];
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, favoriteAction]];
}

#pragma mark - Per-sound actions

- (void)moreTapped:(UIButton *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)self.entries.count) return;
    [self presentActionsForEntry:self.entries[sender.tag] sourceView:sender];
}

- (void)presentActionsForEntry:(EZSoundManifestEntry *)entry sourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:(entry.preview.length ? entry.preview : entry.prompt)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSounds.AddToVideo", nil)
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [self beginAddToVideoForEntry:entry];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSounds.UseAsTTSBackground", nil)
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [self beginTTSBackgroundForEntry:entry];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSounds.Share", nil)
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [self shareEntry:entry sourceView:sourceView];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:(entry.isFavorite
                                                     ? NSLocalizedString(@"EZSounds.Unfavorite", nil)
                                                     : NSLocalizedString(@"EZSounds.Favorite", nil))
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [[EZSoundLibraryManager sharedManager] setFavorite:!entry.isFavorite
                                              forSoundUUID:entry.uuid
                                                completion:^(EZSoundManifestEntry *updated, NSError *error) {
            [self reloadEntries];
        }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSounds.Delete", nil)
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *action) {
        [self confirmDeleteEntry:entry];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSounds.Cancel", nil)
                                               style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sourceView;
    sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)shareEntry:(EZSoundManifestEntry *)entry sourceView:(UIView *)sourceView {
    NSURL *url = [[EZSoundLibraryManager sharedManager] exportURLForSoundWithUUID:entry.uuid];
    if (!url) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                             applicationActivities:nil];
    activity.popoverPresentationController.sourceView = sourceView;
    activity.popoverPresentationController.sourceRect = sourceView.bounds;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)confirmDeleteEntry:(EZSoundManifestEntry *)entry {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"EZSounds.DeleteConfirmTitle", nil)
                                                                   message:(entry.preview.length ? entry.preview : entry.prompt)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSounds.Cancel", nil)
                                               style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSounds.Delete", nil)
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *action) {
        // removeItemWithIdentifier: also drops it from Up Next, and moves
        // playback on if it happens to be the current item.
        [[EZMediaPlayerManager sharedManager]
            removeItemWithIdentifier:[kEZSoundsPlayerIdentifierPrefix stringByAppendingString:entry.uuid]];
        [[EZSoundLibraryManager sharedManager] deleteSoundWithUUID:entry.uuid
                                                        completion:^(BOOL success, NSError *error) {
            [self reloadEntries];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Alerts / progress

- (void)showAlertTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIAlertController *)presentProgressAlertWithTitle:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:@"\n"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [alert.view addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:alert.view.bottomAnchor constant:-52],
    ]];
    [spinner startAnimating];
    [self presentViewController:alert animated:YES completion:nil];
    return alert;
}

#pragma mark - Add to Video

- (void)beginAddToVideoForEntry:(EZSoundManifestEntry *)entry {
    self.pendingVideoEntry = entry;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"EZSounds.PickVideoSource", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSounds.PhotoLibrary", nil)
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) return;
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[UTTypeMovie.identifier, UTTypeVideo.identifier];
        picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSounds.Files", nil)
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie, UTTypeVideo]];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSounds.Cancel", nil)
                                               style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    NSURL *mediaURL = info[UIImagePickerControllerMediaURL];
    EZSoundManifestEntry *entry = self.pendingVideoEntry;
    self.pendingVideoEntry = nil;
    [picker dismissViewControllerAnimated:YES completion:^{
        if (mediaURL && entry) [self muxVideoAtURL:mediaURL withBedEntry:entry];
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    self.pendingVideoEntry = nil;
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *picked = urls.firstObject;
    EZSoundManifestEntry *entry = self.pendingVideoEntry;
    self.pendingVideoEntry = nil;
    if (!picked || !entry) return;
    // Files outside the sandbox need a security-scoped copy before AVFoundation
    // can hold onto the file for the whole export.
    BOOL scoped = [picked startAccessingSecurityScopedResource];
    NSURL *cacheDir = [EZSoundLibraryManager sharedManager].cacheDirectoryURL;
    NSString *copyName = [NSString stringWithFormat:@"video_source_%@.%@",
        [[[NSUUID UUID] UUIDString] substringToIndex:8],
        picked.pathExtension.length ? picked.pathExtension : @"mov"];
    NSURL *copyURL = [cacheDir URLByAppendingPathComponent:copyName];
    NSError *copyError = nil;
    [[NSFileManager defaultManager] removeItemAtURL:copyURL error:nil];
    BOOL copied = [[NSFileManager defaultManager] copyItemAtURL:picked toURL:copyURL error:&copyError];
    if (scoped) [picked stopAccessingSecurityScopedResource];
    if (!copied) {
        [self showAlertTitle:NSLocalizedString(@"EZSounds.ErrorTitle", nil)
                     message:(copyError.localizedDescription ?: NSLocalizedString(@"EZSounds.GenericError", nil))];
        return;
    }
    [self muxVideoAtURL:copyURL withBedEntry:entry];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.pendingVideoEntry = nil;
}

/// Lays the sound under a video: the video's own audio stays at full volume,
/// the sound loops to fill the video's length at bed level and fades out over
/// the last two seconds. Exports an .mp4 into the Sounds cache and offers it
/// through the share sheet (Save Video lands it in Photos from there).
- (void)muxVideoAtURL:(NSURL *)videoURL withBedEntry:(EZSoundManifestEntry *)entry {
    NSURL *bedURL = [[EZSoundLibraryManager sharedManager] absoluteURLForEntry:entry];
    UIAlertController *progress = [self presentProgressAlertWithTitle:NSLocalizedString(@"EZSounds.AddingToVideo", nil)];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
        AVURLAsset *bedAsset = [AVURLAsset URLAssetWithURL:bedURL options:nil];
        AVAssetTrack *videoTrack = [[videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        AVAssetTrack *bedTrack = [[bedAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        CMTime videoDuration = videoAsset.duration;
        NSError *insertError = nil;
        AVMutableComposition *composition = [AVMutableComposition composition];
        AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
        NSMutableArray<AVMutableAudioMixInputParameters *> *mixParams = [NSMutableArray array];

        if (videoTrack && bedTrack && CMTIME_IS_NUMERIC(videoDuration) &&
            CMTIME_COMPARE_INLINE(videoDuration, >, kCMTimeZero) &&
            CMTIME_COMPARE_INLINE(bedAsset.duration, >, kCMTimeZero)) {
            AVMutableCompositionTrack *videoOut = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
            [videoOut insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoDuration) ofTrack:videoTrack atTime:kCMTimeZero error:&insertError];
            videoOut.preferredTransform = videoTrack.preferredTransform;

            AVAssetTrack *originalAudio = [[videoAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
            if (!insertError && originalAudio) {
                AVMutableCompositionTrack *audioOut = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
                [audioOut insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoDuration) ofTrack:originalAudio atTime:kCMTimeZero error:&insertError];
            }

            if (!insertError) {
                AVMutableCompositionTrack *bedOut = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
                CMTime cursor = kCMTimeZero;
                while (!insertError && CMTIME_COMPARE_INLINE(cursor, <, videoDuration)) {
                    CMTime remaining = CMTimeSubtract(videoDuration, cursor);
                    CMTime part = CMTimeMinimum(bedAsset.duration, remaining);
                    [bedOut insertTimeRange:CMTimeRangeMake(kCMTimeZero, part) ofTrack:bedTrack atTime:cursor error:&insertError];
                    cursor = CMTimeAdd(cursor, part);
                }
                if (!insertError) {
                    AVMutableAudioMixInputParameters *bedMix = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:bedOut];
                    [bedMix setVolume:0.7f atTime:kCMTimeZero];
                    Float64 total = CMTimeGetSeconds(videoDuration);
                    if (total > 2.5) {
                        [bedMix setVolumeRampFromStartVolume:0.7f toEndVolume:0.0f
                                                   timeRange:CMTimeRangeMake(CMTimeMakeWithSeconds(total - 2.0, 600),
                                                                             CMTimeMakeWithSeconds(2.0, 600))];
                    }
                    [mixParams addObject:bedMix];
                }
            }
        } else {
            insertError = insertError ?: [NSError errorWithDomain:@"EZSounds" code:-40
                userInfo:@{NSLocalizedDescriptionKey: @"Could not read that video or sound."}];
        }

        if (insertError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [progress dismissViewControllerAnimated:YES completion:^{
                    [self showAlertTitle:NSLocalizedString(@"EZSounds.ErrorTitle", nil)
                                 message:insertError.localizedDescription];
                }];
            });
            return;
        }
        audioMix.inputParameters = mixParams;

        NSString *outName = [NSString stringWithFormat:@"sound_video_%@.mp4",
            [[[NSUUID UUID] UUIDString] substringToIndex:8]];
        NSURL *outURL = [[EZSoundLibraryManager sharedManager].cacheDirectoryURL URLByAppendingPathComponent:outName];
        [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
        AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:composition
                                                                            presetName:AVAssetExportPresetHighestQuality];
        exporter.outputURL = outURL;
        exporter.outputFileType = AVFileTypeMPEG4;
        exporter.audioMix = audioMix;
        exporter.shouldOptimizeForNetworkUse = YES;
        [exporter exportAsynchronouslyWithCompletionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [progress dismissViewControllerAnimated:YES completion:^{
                    if (exporter.status == AVAssetExportSessionStatusCompleted) {
                        UIActivityViewController *activity =
                            [[UIActivityViewController alloc] initWithActivityItems:@[outURL]
                                                              applicationActivities:nil];
                        activity.popoverPresentationController.sourceView = self.view;
                        activity.popoverPresentationController.sourceRect =
                            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
                        [self presentViewController:activity animated:YES completion:nil];
                    } else {
                        [self showAlertTitle:NSLocalizedString(@"EZSounds.ErrorTitle", nil)
                                     message:(exporter.error.localizedDescription
                                              ?: NSLocalizedString(@"EZSounds.GenericError", nil))];
                    }
                }];
            });
        }];
    });
}

#pragma mark - Use as TTS Background

- (void)beginTTSBackgroundForEntry:(EZSoundManifestEntry *)entry {
    NSArray<EZTTSManifestEntry *> *clips = [[EZTTSLibraryManager sharedManager] allClipsSortedByDateDescending];
    if (!clips.count) {
        [self showAlertTitle:NSLocalizedString(@"EZSounds.UseAsTTSBackground", nil)
                     message:NSLocalizedString(@"EZSounds.NoTTSClips", nil)];
        return;
    }
    EZSoundsTTSClipPickerViewController *picker = [[EZSoundsTTSClipPickerViewController alloc] initWithStyle:UITableViewStylePlain];
    __weak typeof(self) weakSelf = self;
    picker.onPick = ^(EZTTSManifestEntry *clip) {
        [weakSelf.navigationController popViewControllerAnimated:YES];
        [weakSelf mixTTSClip:clip withBedEntry:entry];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

/// Mixes a TTS narration clip with this sound as its background bed, using the
/// same scene recipe as the TTS screen itself: bed at 0.5, looped to cover the
/// narration plus a 3-second tail that fades out. The two layers are copied
/// into the TTS library and linked from the mixed clip's scene metadata, so
/// the TTS clip editor can re-mix it later like any other scene.
- (void)mixTTSClip:(EZTTSManifestEntry *)clip withBedEntry:(EZSoundManifestEntry *)entry {
    EZTTSLibraryManager *ttsLibrary = [EZTTSLibraryManager sharedManager];
    NSURL *narrationURL = [ttsLibrary absoluteURLForEntry:clip];
    NSURL *bedURL = [[EZSoundLibraryManager sharedManager] absoluteURLForEntry:entry];
    UIAlertController *progress = [self presentProgressAlertWithTitle:NSLocalizedString(@"EZSounds.MixingTTSBackground", nil)];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 1. Archive the two layers in the TTS library, TTS-scene style.
        NSString *token = [[NSUUID UUID] UUIDString];
        NSString *narrationName = [NSString stringWithFormat:@"narration_%@.%@", token, narrationURL.pathExtension ?: @"mp3"];
        NSString *backgroundName = [NSString stringWithFormat:@"sound_%@.%@", token, bedURL.pathExtension ?: @"mp3"];
        NSString *narrationPath = [@"Sources" stringByAppendingPathComponent:narrationName];
        NSString *backgroundPath = [@"Sounds" stringByAppendingPathComponent:backgroundName];
        NSURL *narrationDest = [ttsLibrary.libraryRootURL URLByAppendingPathComponent:narrationPath];
        NSURL *backgroundDest = [ttsLibrary.libraryRootURL URLByAppendingPathComponent:backgroundPath];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *layerError = nil;
        BOOL layersReady =
            [fm createDirectoryAtURL:narrationDest.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&layerError] &&
            [fm createDirectoryAtURL:backgroundDest.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&layerError];
        if (layersReady) {
            [fm removeItemAtURL:narrationDest error:nil];
            [fm removeItemAtURL:backgroundDest error:nil];
            layersReady = [fm copyItemAtURL:narrationURL toURL:narrationDest error:&layerError] &&
                          [fm copyItemAtURL:bedURL toURL:backgroundDest error:&layerError];
        }
        NSDictionary *sceneMetadata = layersReady
            ? @{ @"sceneNarrationPath": narrationPath,
                 @"sceneBackgroundPath": backgroundPath,
                 @"sceneBackgroundLevel": @0.5 }
            : @{};
        if (!layersReady) {
            EZLogf(EZLogLevelWarning, @"SOUNDS", @"Could not archive scene layers: %@", layerError.localizedDescription);
        }

        // 2. Mix: narration full volume; bed tiled at 0.5 with a 3s faded tail.
        AVURLAsset *narration = [AVURLAsset URLAssetWithURL:narrationURL options:nil];
        AVURLAsset *bed = [AVURLAsset URLAssetWithURL:bedURL options:nil];
        AVAssetTrack *voiceTrack = [[narration tracksWithMediaType:AVMediaTypeAudio] firstObject];
        AVAssetTrack *bedTrack = [[bed tracksWithMediaType:AVMediaTypeAudio] firstObject];
        CMTime narrationDuration = narration.duration;
        CMTime tail = CMTimeMakeWithSeconds(3.0, 600);
        CMTime mixDuration = CMTimeAdd(narrationDuration, tail);
        NSError *mixError = nil;
        AVMutableComposition *composition = [AVMutableComposition composition];
        if (voiceTrack && bedTrack && CMTIME_IS_NUMERIC(narrationDuration) &&
            CMTIME_COMPARE_INLINE(narrationDuration, >, kCMTimeZero) &&
            CMTIME_COMPARE_INLINE(bed.duration, >, kCMTimeZero)) {
            AVMutableCompositionTrack *voice = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            [voice insertTimeRange:CMTimeRangeMake(kCMTimeZero, narrationDuration) ofTrack:voiceTrack atTime:kCMTimeZero error:&mixError];
            AVMutableCompositionTrack *bedOut = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            CMTime cursor = kCMTimeZero;
            while (!mixError && CMTIME_COMPARE_INLINE(cursor, <, mixDuration)) {
                CMTime remaining = CMTimeSubtract(mixDuration, cursor);
                CMTime part = CMTimeMinimum(bed.duration, remaining);
                [bedOut insertTimeRange:CMTimeRangeMake(kCMTimeZero, part) ofTrack:bedTrack atTime:cursor error:&mixError];
                cursor = CMTimeAdd(cursor, part);
            }
            if (!mixError) {
                AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
                AVMutableAudioMixInputParameters *bedMix = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:bedOut];
                [bedMix setVolume:0.5f atTime:kCMTimeZero];
                [bedMix setVolumeRampFromStartVolume:0.5f toEndVolume:0.0f
                                           timeRange:CMTimeRangeMake(narrationDuration, tail)];
                audioMix.inputParameters = @[bedMix];

                NSURL *outURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
                    stringByAppendingPathComponent:[NSString stringWithFormat:@"sound_scene_%@.m4a", token]]];
                [fm removeItemAtURL:outURL error:nil];
                AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:composition
                                                                                    presetName:AVAssetExportPresetAppleM4A];
                exporter.outputURL = outURL;
                exporter.outputFileType = AVFileTypeM4A;
                exporter.audioMix = audioMix;
                [exporter exportAsynchronouslyWithCompletionHandler:^{
                    NSData *mixedData = (exporter.status == AVAssetExportSessionStatusCompleted)
                        ? [NSData dataWithContentsOfURL:outURL] : nil;
                    if (!mixedData.length) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [progress dismissViewControllerAnimated:YES completion:^{
                                [self showAlertTitle:NSLocalizedString(@"EZSounds.ErrorTitle", nil)
                                             message:(exporter.error.localizedDescription
                                                      ?: NSLocalizedString(@"EZSounds.GenericError", nil))];
                            }];
                        });
                        return;
                    }
                    [ttsLibrary saveAudioData:mixedData
                                       prompt:clip.prompt
                                    voiceName:clip.voiceName
                                      voiceID:clip.voiceID
                                     provider:clip.provider
                                        model:clip.model
                                    extension:@"m4a"
                                     metadata:sceneMetadata
                                   completion:^(EZTTSManifestEntry *saved, NSError *saveError) {
                        [progress dismissViewControllerAnimated:YES completion:^{
                            if (saved) {
                                [self showAlertTitle:NSLocalizedString(@"EZSounds.UseAsTTSBackground", nil)
                                             message:NSLocalizedString(@"EZSounds.TTSBackgroundSaved", nil)];
                            } else {
                                [self showAlertTitle:NSLocalizedString(@"EZSounds.ErrorTitle", nil)
                                             message:(saveError.localizedDescription
                                                      ?: NSLocalizedString(@"EZSounds.GenericError", nil))];
                            }
                        }];
                    }];
                }];
                return;
            }
        }
        NSError *failError = mixError ?: [NSError errorWithDomain:@"EZSounds" code:-41
            userInfo:@{NSLocalizedDescriptionKey: @"Could not prepare the audio tracks for mixing."}];
        dispatch_async(dispatch_get_main_queue(), ^{
            [progress dismissViewControllerAnimated:YES completion:^{
                [self showAlertTitle:NSLocalizedString(@"EZSounds.ErrorTitle", nil)
                             message:failError.localizedDescription];
            }];
        });
    });
}

@end
