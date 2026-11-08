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
#import "EZTTSClipEditViewController.h"
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

// ── EZNeonSheet ─────────────────────────────────────────────────────────────
// App-styled replacement for UIAlertController action sheets and alerts on
// this screen: a dim backdrop with a neon panel — bottom-anchored for action
// lists, centered for alerts, text entry, and progress. Every menu this
// screen shows goes through here so nothing falls back to stock iOS styling.

@interface EZNeonSheet : UIView
@property (nonatomic, strong, readonly) UIView *panel;
@property (nonatomic, strong, readonly, nullable) UITextField *textField;
@property (nonatomic, assign) BOOL dismissOnBackdropTap;
+ (instancetype)sheetInHostView:(UIView *)host centered:(BOOL)centered;
- (void)setTitle:(nullable NSString *)title message:(nullable NSString *)message;
- (void)addButtonWithTitle:(NSString *)title
               destructive:(BOOL)destructive
                   handler:(nullable void (^)(void))handler;
- (void)addTextFieldWithText:(nullable NSString *)text placeholder:(nullable NSString *)placeholder;
- (void)addSpinner;
- (void)present;
- (void)dismissWithCompletion:(nullable void (^)(void))completion;
@end

@implementation EZNeonSheet {
    UIView *_dimView;
    UIStackView *_stack;
    NSMutableArray<void (^)(void)> *_handlers;
    BOOL _centered;
    CGFloat _keyboardShift;
}

+ (instancetype)sheetInHostView:(UIView *)host centered:(BOOL)centered {
    EZNeonSheet *sheet = [[EZNeonSheet alloc] initWithFrame:host.bounds];
    sheet->_centered = centered;
    sheet.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [sheet buildInHost:host];
    return sheet;
}

- (void)buildInHost:(UIView *)host {
    _handlers = [NSMutableArray array];
    _dimView = [[UIView alloc] initWithFrame:self.bounds];
    _dimView.backgroundColor = [UIColor blackColor];
    _dimView.alpha = 0;
    _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_dimView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backdropTapped)]];
    [self addSubview:_dimView];

    _panel = [[UIView alloc] init];
    _panel.backgroundColor = EZSoundsNeonPanel();
    _panel.layer.cornerRadius = 18;
    _panel.layer.borderWidth = 1.0;
    _panel.layer.borderColor = EZSoundsNeonViolet().CGColor;
    _panel.layer.shadowColor = EZSoundsNeonViolet().CGColor;
    _panel.layer.shadowOpacity = 0.45;
    _panel.layer.shadowRadius = 12;
    _panel.layer.shadowOffset = CGSizeZero;
    _panel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_panel];

    _stack = [[UIStackView alloc] init];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 10;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_panel addSubview:_stack];

    if (_centered) {
        _panel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                                     kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        [NSLayoutConstraint activateConstraints:@[
            [_panel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_panel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_panel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:24],
            [_panel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-24],
        ]];
    } else {
        _panel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        [NSLayoutConstraint activateConstraints:@[
            [_panel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_panel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_panel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
    }
    CGFloat bottomPad = _centered ? 16 : 16 + host.safeAreaInsets.bottom;
    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:_panel.topAnchor constant:16],
        [_stack.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor constant:16],
        [_stack.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor constant:-16],
        [_stack.bottomAnchor constraintEqualToAnchor:_panel.bottomAnchor constant:-bottomPad],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification object:nil];
    [host addSubview:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setTitle:(NSString *)title message:(NSString *)message {
    if (title.length) {
        UILabel *label = [[UILabel alloc] init];
        label.text = title;
        label.textColor = EZSoundsNeonText();
        label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        [_stack addArrangedSubview:label];
    }
    if (message.length) {
        UILabel *label = [[UILabel alloc] init];
        label.text = message;
        label.textColor = EZSoundsNeonDimText();
        label.font = [UIFont systemFontOfSize:14];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        [_stack addArrangedSubview:label];
    }
}

- (void)addButtonWithTitle:(NSString *)title
               destructive:(BOOL)destructive
                   handler:(void (^)(void))handler {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:(destructive ? EZSoundsNeonPink() : EZSoundsNeonText())
                 forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    button.backgroundColor = EZSoundsNeonField();
    button.layer.cornerRadius = 12;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = (destructive ? EZSoundsNeonPink() : EZSoundsNeonCyan()).CGColor;
    [button.heightAnchor constraintEqualToConstant:48].active = YES;
    button.tag = (NSInteger)_handlers.count;
    [_handlers addObject:(handler ?: ^{})];
    [button addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_stack addArrangedSubview:button];
}

- (void)addTextFieldWithText:(NSString *)text placeholder:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] init];
    field.text = text;
    field.placeholder = placeholder;
    field.textColor = EZSoundsNeonText();
    field.font = [UIFont systemFontOfSize:16];
    field.backgroundColor = EZSoundsNeonField();
    field.layer.cornerRadius = 10;
    field.layer.borderWidth = 1.0;
    field.layer.borderColor = EZSoundsNeonCyan().CGColor;
    field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 1)];
    field.leftViewMode = UITextFieldViewModeAlways;
    field.returnKeyType = UIReturnKeyDone;
    field.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    [field.heightAnchor constraintEqualToConstant:44].active = YES;
    _textField = field;
    [_stack addArrangedSubview:field];
}

- (void)addSpinner {
    UIActivityIndicatorView *spinner =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.color = EZSoundsNeonCyan();
    [spinner startAnimating];
    [_stack addArrangedSubview:spinner];
}

- (void)present {
    [self layoutIfNeeded];
    CGFloat travel = _centered ? 24 : _panel.bounds.size.height + 40;
    _panel.transform = CGAffineTransformMakeTranslation(0, _centered ? travel : travel);
    _panel.alpha = _centered ? 0 : 1;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_dimView.alpha = 0.55;
        self->_panel.transform = CGAffineTransformIdentity;
        self->_panel.alpha = 1;
    } completion:^(BOOL finished) {
        if (self->_textField) [self->_textField becomeFirstResponder];
    }];
}

- (void)dismissWithCompletion:(void (^)(void))completion {
    [_textField resignFirstResponder];
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_dimView.alpha = 0;
        if (self->_centered) {
            self->_panel.alpha = 0;
        } else {
            self->_panel.transform = CGAffineTransformMakeTranslation(0, self->_panel.bounds.size.height + 40);
        }
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
        if (completion) completion();
    }];
}

- (void)buttonTapped:(UIButton *)sender {
    void (^handler)(void) = (sender.tag >= 0 && sender.tag < (NSInteger)_handlers.count)
        ? _handlers[(NSUInteger)sender.tag] : nil;
    [self dismissWithCompletion:handler];
}

- (void)backdropTapped {
    if (self.dismissOnBackdropTap) [self dismissWithCompletion:nil];
}

- (void)keyboardWillShow:(NSNotification *)note {
    if (!_centered || !_textField) return;
    CGRect kb = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    _keyboardShift = MAX(0, kb.size.height - 150);
    [UIView animateWithDuration:0.25 animations:^{
        self->_panel.transform = CGAffineTransformMakeTranslation(0, -self->_keyboardShift);
    }];
}

- (void)keyboardWillHide:(NSNotification *)note {
    if (!_centered || !_textField) return;
    _keyboardShift = 0;
    [UIView animateWithDuration:0.25 animations:^{
        self->_panel.transform = CGAffineTransformIdentity;
    }];
}

@end

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
                                      UITextViewDelegate, UIGestureRecognizerDelegate,
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

// In-flight mix bookkeeping: every mix finishes through one funnel
// (finishProgressForToken:...) and a watchdog cancels anything that
// overruns, so the progress UI can never spin forever.
@property (nonatomic, strong) EZNeonSheet *progressSheet;
@property (nonatomic, copy) NSString *activeMixToken;
@property (nonatomic, strong) AVAssetExportSession *activeExport;
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
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(soundsKeyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(soundsKeyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
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

- (UIView *)sheetHostView {
    return self.navigationController.view ?: self.view;
}

/// The name shown for a sound everywhere: the user's custom title
/// (metadata[@"title"], set by Rename) when there is one, else the
/// prompt preview — same convention as the TTS library.
- (NSString *)displayTitleForEntry:(EZSoundManifestEntry *)entry {
    NSString *custom = [entry.metadata[@"title"] isKindOfClass:NSString.class] ? entry.metadata[@"title"] : nil;
    if (custom.length) return custom;
    return entry.preview.length ? entry.preview : entry.prompt;
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
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.createPanel = scroll;
    // Tap anywhere outside the prompt field to dismiss the keyboard.
    // cancelsTouchesInView stays NO so the slider, switch, and buttons
    // still receive their taps normally; the delegate below only keeps
    // the gesture out of the prompt field itself.
    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                 action:@selector(dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    dismissTap.delegate = self;
    [scroll addGestureRecognizer:dismissTap];
    [self.view addSubview:scroll];

    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    // Prompt panel
    UIView *promptPanel = [self panelWithAccent:EZSoundsNeonCyan()];
    [content addSubview:promptPanel];

    self.promptView = [[UITextView alloc] init];
    self.promptView.delegate = self;
    // A multi-line prompt has no Return-key way out of the keyboard, so
    // it gets the app's standard Done bar above the keyboard.
    UIToolbar *keyboardBar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    keyboardBar.barStyle = UIBarStyleBlack;
    keyboardBar.tintColor = EZSoundsNeonCyan();
    UIBarButtonItem *kbFlex = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *kbDone = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(dismissKeyboard)];
    keyboardBar.items = @[kbFlex, kbDone];
    self.promptView.inputAccessoryView = keyboardBar;
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

#pragma mark - Styled sheets / alerts (no stock UIAlertController on this screen)

- (void)showAlertTitle:(NSString *)title message:(NSString *)message {
    EZNeonSheet *sheet = [EZNeonSheet sheetInHostView:[self sheetHostView] centered:YES];
    [sheet setTitle:title message:message];
    [sheet addButtonWithTitle:@"OK" destructive:NO handler:nil];
    [sheet present];
}

/// Shows the neon progress sheet and arms a watchdog: if the operation
/// hasn't finished through finishProgressForToken: within `timeout`
/// seconds, the export is cancelled and the user gets an error instead
/// of an endless spinner.
- (NSString *)beginProgressWithTitle:(NSString *)title timeout:(NSTimeInterval)timeout {
    NSString *token = [[NSUUID UUID] UUIDString];
    self.activeMixToken = token;
    EZNeonSheet *sheet = [EZNeonSheet sheetInHostView:[self sheetHostView] centered:YES];
    sheet.dismissOnBackdropTap = NO;
    [sheet setTitle:title message:nil];
    [sheet addSpinner];
    self.progressSheet = sheet;
    [sheet present];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf.activeMixToken isEqualToString:token]) return;
        [strongSelf.activeExport cancelExport];
        NSError *timeoutError = [NSError errorWithDomain:@"EZSounds" code:-42
            userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"EZSounds.MixTimeout", nil)}];
        [strongSelf finishProgressForToken:token error:timeoutError successTitle:nil successMessage:nil];
    });
    return token;
}

/// The single exit door for both mixes. Runs on the main queue, fires
/// exactly once per token (late completions and the watchdog can't
/// double-finish), always dismisses the progress sheet, and always
/// shows the outcome.
- (void)finishProgressForToken:(NSString *)token
                         error:(nullable NSError *)error
                  successTitle:(nullable NSString *)successTitle
                successMessage:(nullable NSString *)successMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self.activeMixToken isEqualToString:token]) return;
        self.activeMixToken = nil;
        self.activeExport = nil;
        EZNeonSheet *sheet = self.progressSheet;
        self.progressSheet = nil;
        void (^showResult)(void) = ^{
            if (error) {
                [self showAlertTitle:NSLocalizedString(@"EZSounds.ErrorTitle", nil)
                             message:(error.localizedDescription
                                      ?: NSLocalizedString(@"EZSounds.GenericError", nil))];
            } else if (successMessage) {
                [self showAlertTitle:(successTitle ?: NSLocalizedString(@"EZSounds.Title", nil))
                             message:successMessage];
            }
        };
        if (sheet) {
            [sheet dismissWithCompletion:showResult];
        } else {
            showResult();
        }
    });
}

#pragma mark - Keyboard (Create tab)

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

/// The tap-to-dismiss gesture rides on the whole Create scroll view;
/// only a tap OUTSIDE the prompt field may dismiss — taps inside it
/// are text editing, and every other control keeps its own touches
/// because the gesture doesn't cancel them.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    if ([touch.view isDescendantOfView:self.promptView]) return NO;
    return YES;
}

/// Keyboard avoidance: while the keyboard is up, the Create scroll
/// view gets a bottom inset equal to the keyboard's overlap and the
/// Generate button is scrolled into view — it can never sit trapped
/// underneath the keyboard.
- (void)soundsKeyboardWillShow:(NSNotification *)note {
    if (self.createPanel.hidden || !self.promptView.isFirstResponder) return;
    UIScrollView *scroll = (UIScrollView *)self.createPanel;
    CGRect kbFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect kbInView = [self.view convertRect:kbFrame fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(scroll.frame) - CGRectGetMinY(kbInView));
    if (overlap <= 0) return;
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        scroll.contentInset = UIEdgeInsetsMake(0, 0, overlap, 0);
        scroll.scrollIndicatorInsets = scroll.contentInset;
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        UIView *content = self.generateButton.superview;
        CGRect buttonRect = [self.generateButton convertRect:self.generateButton.bounds
                                                     toView:content];
        buttonRect = CGRectInset(buttonRect, 0, -12);
        [scroll scrollRectToVisible:buttonRect animated:YES];
    }];
}

- (void)soundsKeyboardWillHide:(NSNotification *)note {
    UIScrollView *scroll = (UIScrollView *)self.createPanel;
    if (UIEdgeInsetsEqualToEdgeInsets(scroll.contentInset, UIEdgeInsetsZero)) return;
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        scroll.contentInset = UIEdgeInsetsZero;
        scroll.scrollIndicatorInsets = UIEdgeInsetsZero;
        [self.view layoutIfNeeded];
    }];
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
    [self.view endEditing:YES];
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
    // Honor a playback rate set in the clip editor, exactly like the
    // TTS library list does for its clips.
    id storedRate = entry.metadata[@"playbackRate"];
    float rate = [storedRate isKindOfClass:[NSNumber class]] ? [storedRate floatValue] : 1.0f;
    return [EZMediaPlayerItem itemWithIdentifier:[kEZSoundsPlayerIdentifierPrefix stringByAppendingString:entry.uuid]
                                           title:[self displayTitleForEntry:entry]
                                        subtitle:@"EZCompleteUI"
                                         fileURL:url
                                    durationHint:entry.duration
                                    playbackRate:rate];
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
    if (items.count > 1) {
        [player replaceUpNext:[items subarrayWithRange:NSMakeRange(1, items.count - 1)]];
    }
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

    cell.textLabel.text = [self displayTitleForEntry:entry];
    cell.textLabel.textColor = current ? EZSoundsNeonPink() : EZSoundsNeonText();
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.textLabel.numberOfLines = 1;

    NSString *durationText = [EZMediaPlayerManager formattedTime:entry.duration];
    BOOL loop = [entry.metadata[@"loop"] respondsToSelector:@selector(boolValue)] && [entry.metadata[@"loop"] boolValue];
    BOOL hasCustomTitle = [entry.metadata[@"title"] isKindOfClass:NSString.class] &&
                          [(NSString *)entry.metadata[@"title"] length] > 0;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@%@%@%@",
        durationText,
        loop ? @" • ∞" : @"",
        entry.isFavorite ? @" • ★" : @"",
        hasCustomTitle ? [NSString stringWithFormat:@" • %@", entry.preview ?: @""] : @"",
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
    [self presentActionsForEntry:self.entries[sender.tag]];
}

- (void)presentActionsForEntry:(EZSoundManifestEntry *)entry {
    EZNeonSheet *sheet = [EZNeonSheet sheetInHostView:[self sheetHostView] centered:NO];
    sheet.dismissOnBackdropTap = YES;
    [sheet setTitle:[self displayTitleForEntry:entry] message:nil];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.AddToVideo", nil)
                  destructive:NO
                      handler:^{ [self beginAddToVideoForEntry:entry]; }];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.UseAsTTSBackground", nil)
                  destructive:NO
                      handler:^{ [self beginTTSBackgroundForEntry:entry]; }];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.Rename", nil)
                  destructive:NO
                      handler:^{ [self presentRenameForEntry:entry]; }];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.Edit", nil)
                  destructive:NO
                      handler:^{
        // The app's existing clip editor, opened on this sound: its
        // edits archive back into the Sounds library as new entries
        // (original untouched), except in-place normalize.
        EZTTSClipEditViewController *editor =
            [[EZTTSClipEditViewController alloc] initWithSoundEntry:entry];
        [self.navigationController pushViewController:editor animated:YES];
    }];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.Share", nil)
                  destructive:NO
                      handler:^{ [self shareEntry:entry]; }];
    [sheet addButtonWithTitle:(entry.isFavorite
                                ? NSLocalizedString(@"EZSounds.Unfavorite", nil)
                                : NSLocalizedString(@"EZSounds.Favorite", nil))
                  destructive:NO
                      handler:^{
        [[EZSoundLibraryManager sharedManager] setFavorite:!entry.isFavorite
                                              forSoundUUID:entry.uuid
                                                completion:^(EZSoundManifestEntry *updated, NSError *error) {
            [self reloadEntries];
        }];
    }];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.Delete", nil)
                  destructive:YES
                      handler:^{ [self confirmDeleteEntry:entry]; }];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.Cancel", nil)
                  destructive:NO handler:nil];
    [sheet present];
}

- (void)presentRenameForEntry:(EZSoundManifestEntry *)entry {
    EZNeonSheet *sheet = [EZNeonSheet sheetInHostView:[self sheetHostView] centered:YES];
    [sheet setTitle:NSLocalizedString(@"EZSounds.Rename", nil) message:nil];
    NSString *current = [entry.metadata[@"title"] isKindOfClass:NSString.class] ? entry.metadata[@"title"] : nil;
    [sheet addTextFieldWithText:(current ?: @"")
                    placeholder:NSLocalizedString(@"EZSounds.RenamePlaceholder", nil)];
    __weak EZNeonSheet *weakSheet = sheet;
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.Save", nil)
                  destructive:NO
                      handler:^{
        NSString *title = [weakSheet.textField.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [[EZSoundLibraryManager sharedManager] renameSoundWithUUID:entry.uuid
                                                             title:title
                                                        completion:^(EZSoundManifestEntry *updated, NSError *error) {
            [self reloadEntries];
        }];
    }];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.Cancel", nil)
                  destructive:NO handler:nil];
    [sheet present];
}

- (void)shareEntry:(EZSoundManifestEntry *)entry {
    NSURL *url = [[EZSoundLibraryManager sharedManager] exportURLForSoundWithUUID:entry.uuid];
    if (!url) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                                                             applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)confirmDeleteEntry:(EZSoundManifestEntry *)entry {
    EZNeonSheet *sheet = [EZNeonSheet sheetInHostView:[self sheetHostView] centered:YES];
    [sheet setTitle:NSLocalizedString(@"EZSounds.DeleteConfirmTitle", nil)
            message:[self displayTitleForEntry:entry]];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.Delete", nil)
                  destructive:YES
                      handler:^{
        // removeItemWithIdentifier: also drops it from Up Next, and moves
        // playback on if it happens to be the current item.
        [[EZMediaPlayerManager sharedManager]
            removeItemWithIdentifier:[kEZSoundsPlayerIdentifierPrefix stringByAppendingString:entry.uuid]];
        [[EZSoundLibraryManager sharedManager] deleteSoundWithUUID:entry.uuid
                                                        completion:^(BOOL success, NSError *error) {
            [self reloadEntries];
        }];
    }];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.Cancel", nil)
                  destructive:NO handler:nil];
    [sheet present];
}

#pragma mark - Add to Video

- (void)beginAddToVideoForEntry:(EZSoundManifestEntry *)entry {
    self.pendingVideoEntry = entry;
    EZNeonSheet *sheet = [EZNeonSheet sheetInHostView:[self sheetHostView] centered:NO];
    sheet.dismissOnBackdropTap = YES;
    [sheet setTitle:NSLocalizedString(@"EZSounds.PickVideoSource", nil) message:nil];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.PhotoLibrary", nil)
                  destructive:NO
                      handler:^{
        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) return;
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[UTTypeMovie.identifier, UTTypeVideo.identifier];
        picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.Files", nil)
                  destructive:NO
                      handler:^{
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie, UTTypeVideo]];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    }];
    [sheet addButtonWithTitle:NSLocalizedString(@"EZSounds.Cancel", nil)
                  destructive:NO handler:nil];
    [sheet present];
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
/// Finishes through the watchdog-guarded funnel, like the TTS mix.
- (void)muxVideoAtURL:(NSURL *)videoURL withBedEntry:(EZSoundManifestEntry *)entry {
    NSURL *bedURL = [[EZSoundLibraryManager sharedManager] absoluteURLForEntry:entry];
    NSString *token = [self beginProgressWithTitle:NSLocalizedString(@"EZSounds.AddingToVideo", nil)
                                           timeout:240];
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

        // A video whose duration can't be read (indefinite / non-numeric) is
        // rejected up front — tiling a bed against an unknown length is how
        // exports wedge.
        BOOL durationOK = CMTIME_IS_NUMERIC(videoDuration) &&
                          CMTIME_COMPARE_INLINE(videoDuration, >, kCMTimeZero) &&
                          CMTimeGetSeconds(videoDuration) < 6 * 3600;
        if (videoTrack && bedTrack && durationOK &&
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
                    if (CMTIME_COMPARE_INLINE(part, <=, kCMTimeZero)) {
                        insertError = [NSError errorWithDomain:@"EZSounds" code:-43
                            userInfo:@{NSLocalizedDescriptionKey: @"Could not read that sound."}];
                        break;
                    }
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
            [self finishProgressForToken:token error:insertError successTitle:nil successMessage:nil];
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
        dispatch_async(dispatch_get_main_queue(), ^{ self.activeExport = exporter; });
        [exporter exportAsynchronouslyWithCompletionHandler:^{
            if (exporter.status == AVAssetExportSessionStatusCompleted) {
                // Success here has no message of its own — dismiss the
                // progress UI and hand the file to the share sheet.
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![self.activeMixToken isEqualToString:token]) return;
                    self.activeMixToken = nil;
                    self.activeExport = nil;
                    EZNeonSheet *sheet = self.progressSheet;
                    self.progressSheet = nil;
                    void (^share)(void) = ^{
                        UIActivityViewController *activity =
                            [[UIActivityViewController alloc] initWithActivityItems:@[outURL]
                                                              applicationActivities:nil];
                        activity.popoverPresentationController.sourceView = self.view;
                        activity.popoverPresentationController.sourceRect =
                            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
                        [self presentViewController:activity animated:YES completion:nil];
                    };
                    if (sheet) [sheet dismissWithCompletion:share]; else share();
                });
            } else {
                NSError *exportError = exporter.error ?: [NSError errorWithDomain:@"EZSounds" code:-44
                    userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"EZSounds.GenericError", nil)}];
                [self finishProgressForToken:token error:exportError successTitle:nil successMessage:nil];
            }
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
        // Start the mix only once the pop transition has settled — the
        // previous build presented its progress UI mid-transition and
        // chained dismissals off it, which is how the flow could wedge.
        id<UIViewControllerTransitionCoordinator> coordinator =
            weakSelf.navigationController.transitionCoordinator;
        [weakSelf.navigationController popViewControllerAnimated:YES];
        if (coordinator) {
            [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                [weakSelf mixTTSClip:clip withBedEntry:entry];
            }];
        } else {
            [weakSelf mixTTSClip:clip withBedEntry:entry];
        }
    };
    [self.navigationController pushViewController:picker animated:YES];
}

/// Mixes a TTS narration clip with this sound as its background bed, using the
/// same scene recipe as the TTS screen itself: bed at 0.5, looped to cover the
/// narration plus a 3-second tail that fades out. The two layers are copied
/// into the TTS library and linked from the mixed clip's scene metadata, so
/// the TTS clip editor can re-mix it later like any other scene.
///
/// Lengths come from the library manifests (measured when each file was
/// saved), not from AVAsset's own duration — an asset that misreports its
/// length can no longer stretch the mix, and every exit goes through the
/// watchdog-guarded finish funnel, so the progress UI always resolves.
- (void)mixTTSClip:(EZTTSManifestEntry *)clip withBedEntry:(EZSoundManifestEntry *)entry {
    EZTTSLibraryManager *ttsLibrary = [EZTTSLibraryManager sharedManager];
    NSURL *narrationURL = [ttsLibrary absoluteURLForEntry:clip];
    NSURL *bedURL = [[EZSoundLibraryManager sharedManager] absoluteURLForEntry:entry];
    NSString *token = [self beginProgressWithTitle:NSLocalizedString(@"EZSounds.MixingTTSBackground", nil)
                                           timeout:120];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 1. Archive the two layers in the TTS library, TTS-scene style.
        NSString *layerToken = [[NSUUID UUID] UUIDString];
        NSString *narrationName = [NSString stringWithFormat:@"narration_%@.%@", layerToken, narrationURL.pathExtension ?: @"mp3"];
        NSString *backgroundName = [NSString stringWithFormat:@"sound_%@.%@", layerToken, bedURL.pathExtension ?: @"mp3"];
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

        // Authoritative lengths: the manifests' measured durations, each
        // cross-checked against (and capped by) its track's real range when
        // the track reports a sane one.
        double narrationSeconds = clip.duration;
        double bedSeconds = entry.duration;
        if (voiceTrack && CMTIME_IS_NUMERIC(voiceTrack.timeRange.duration)) {
            double trackSeconds = CMTimeGetSeconds(voiceTrack.timeRange.duration);
            if (trackSeconds > 0) narrationSeconds = (narrationSeconds > 0)
                ? MIN(narrationSeconds, trackSeconds) : trackSeconds;
        }
        if (bedTrack && CMTIME_IS_NUMERIC(bedTrack.timeRange.duration)) {
            double trackSeconds = CMTimeGetSeconds(bedTrack.timeRange.duration);
            if (trackSeconds > 0) bedSeconds = (bedSeconds > 0)
                ? MIN(bedSeconds, trackSeconds) : trackSeconds;
        }

        NSError *mixError = nil;
        AVMutableComposition *composition = [AVMutableComposition composition];
        BOOL lengthsOK = voiceTrack && bedTrack &&
                         narrationSeconds > 0.05 && narrationSeconds < 6 * 3600 &&
                         bedSeconds > 0.05 && bedSeconds < 3600;
        if (lengthsOK) {
            CMTime narrationDuration = CMTimeMakeWithSeconds(narrationSeconds, 600);
            CMTime bedDuration = CMTimeMakeWithSeconds(bedSeconds, 600);
            CMTime tail = CMTimeMakeWithSeconds(3.0, 600);
            CMTime mixDuration = CMTimeAdd(narrationDuration, tail);
            AVMutableCompositionTrack *voice = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            [voice insertTimeRange:CMTimeRangeMake(kCMTimeZero, narrationDuration) ofTrack:voiceTrack atTime:kCMTimeZero error:&mixError];
            AVMutableCompositionTrack *bedOut = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
            CMTime cursor = kCMTimeZero;
            while (!mixError && CMTIME_COMPARE_INLINE(cursor, <, mixDuration)) {
                CMTime remaining = CMTimeSubtract(mixDuration, cursor);
                CMTime part = CMTimeMinimum(bedDuration, remaining);
                if (CMTIME_COMPARE_INLINE(part, <=, kCMTimeZero)) {
                    mixError = [NSError errorWithDomain:@"EZSounds" code:-43
                        userInfo:@{NSLocalizedDescriptionKey: @"Could not read that sound."}];
                    break;
                }
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
                    stringByAppendingPathComponent:[NSString stringWithFormat:@"sound_scene_%@.m4a", layerToken]]];
                [fm removeItemAtURL:outURL error:nil];
                AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:composition
                                                                                    presetName:AVAssetExportPresetAppleM4A];
                exporter.outputURL = outURL;
                exporter.outputFileType = AVFileTypeAppleM4A;
                exporter.audioMix = audioMix;
                dispatch_async(dispatch_get_main_queue(), ^{ self.activeExport = exporter; });
                [exporter exportAsynchronouslyWithCompletionHandler:^{
                    NSData *mixedData = (exporter.status == AVAssetExportSessionStatusCompleted)
                        ? [NSData dataWithContentsOfURL:outURL] : nil;
                    if (!mixedData.length) {
                        NSError *exportError = exporter.error ?: [NSError errorWithDomain:@"EZSounds" code:-44
                            userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"EZSounds.GenericError", nil)}];
                        [self finishProgressForToken:token error:exportError successTitle:nil successMessage:nil];
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
                        if (saved) {
                            [self finishProgressForToken:token
                                                   error:nil
                                            successTitle:NSLocalizedString(@"EZSounds.UseAsTTSBackground", nil)
                                          successMessage:NSLocalizedString(@"EZSounds.TTSBackgroundSaved", nil)];
                        } else {
                            [self finishProgressForToken:token
                                                   error:(saveError ?: [NSError errorWithDomain:@"EZSounds" code:-45
                                                       userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"EZSounds.GenericError", nil)}])
                                            successTitle:nil successMessage:nil];
                        }
                    }];
                }];
                return;
            }
        }
        NSError *failError = mixError ?: [NSError errorWithDomain:@"EZSounds" code:-41
            userInfo:@{NSLocalizedDescriptionKey: @"Could not prepare the audio tracks for mixing."}];
        [self finishProgressForToken:token error:failError successTitle:nil successMessage:nil];
    });
}

@end
