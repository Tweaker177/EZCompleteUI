// SettingsViewController.m
// EZCompleteUI v2.0
//
// Changes from v1.0:
//   - All app settings plus ElevenLabs voice cloning
//   - API keys stored encrypted via EZKeyVault (AES-256-GCM, Keychain-backed)
//   - Keys are masked after entry — the plaintext is never shown again
//   - App version read from Info.plist and displayed at top of settings
//   - Support & Feedback button opens SupportRequestViewController

#import "SettingsViewController.h"
#import "MemoriesViewController.h"
#import "SupportRequestViewController.h"
#import "EZKeyVault.h"
#import "helpers.h"
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "TextToSpeechViewController.h"
#import "ElevenLabsCloneViewController.h"


static const void * kEZCloneNameKey     = &kEZCloneNameKey;
static const void * kEZPickerPurposeKey = &kEZPickerPurposeKey;

// Placeholder shown in a key field once a key has been saved
static NSString * const kAPIKeyMaskedPlaceholder    = @"API key saved — tap to replace";
static NSString * const kELKeyMaskedPlaceholder     = @"API key saved — tap to replace";

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Private interface
// ─────────────────────────────────────────────────────────────────────────────

@interface SettingsViewController () <UITextFieldDelegate, UITextViewDelegate, UIDocumentPickerDelegate>

// ── Scroll container ──────────────────────────────────────────────────────────
@property (nonatomic, strong) UIScrollView *scrollView;

// ── OpenAI fields ─────────────────────────────────────────────────────────────
/// Text field used for key entry. Shows masked placeholder when key is saved.
@property (nonatomic, strong) UITextField  *apiKeyField;
/// YES while the field is in "masked" state (key exists, not being edited)
@property (nonatomic, assign) BOOL          apiKeyMasked;

// ── System prompt (inline multi-line UITextView) ───────────────────────────
@property (nonatomic, strong) UITextView   *systemMsgView;
/// Height constraint we update as the text view grows
@property (nonatomic, assign) CGFloat       systemMsgViewHeight;

// ── Sliders ───────────────────────────────────────────────────────────────────
@property (nonatomic, strong) UISlider     *tempSlider;
@property (nonatomic, strong) UISlider     *freqSlider;
@property (nonatomic, strong) UILabel      *tempLabel;
@property (nonatomic, strong) UILabel      *freqLabel;

// ── Web search ────────────────────────────────────────────────────────────────
@property (nonatomic, strong) UITextField  *webLocationField;
@property (nonatomic, strong) UISwitch     *webSearchSwitch;

// ── ElevenLabs TTS ────────────────────────────────────────────────────────────
@property (nonatomic, strong) UITextField  *elKeyField;
@property (nonatomic, assign) BOOL          elKeyMasked;
@property (nonatomic, strong) UITextField  *elVoiceField;

// ── ElevenLabs Voice Cloning ──────────────────────────────────────────────────
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *clonedVoices;
@property (nonatomic, strong) UILabel      *cloneStatusLabel;

// ── Sora video ────────────────────────────────────────────────────────────────
@property (nonatomic, strong) UITextField  *soraModelField;
@property (nonatomic, strong) UITextField  *soraSizeField;
@property (nonatomic, strong) UISlider     *soraDurationSlider;
@property (nonatomic, strong) UILabel      *soraDurationLabel;

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(saveAndClose)];

    self.clonedVoices = [NSMutableArray array];

    [self setupUI];
    [self loadSettings];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(keyboardShow:)
               name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardHide:)
               name:UIKeyboardWillHideNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardShow:)
               name:UIKeyboardWillChangeFrameNotification object:nil];

    // Dismiss keyboard on tap outside text inputs
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.scrollView addGestureRecognizer:tap];

    EZLog(EZLogLevelInfo, @"SETTINGS", @"Settings opened");
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Keyboard handling
// ─────────────────────────────────────────────────────────────────────────────

- (void)keyboardShow:(NSNotification *)notification {
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIEdgeInsets insets  = UIEdgeInsetsMake(0, 0, keyboardFrame.size.height, 0);
    self.scrollView.contentInset          = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)keyboardHide:(NSNotification *)notification {
    self.scrollView.contentInset          = UIEdgeInsetsZero;
    self.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - API Key field masking
// ─────────────────────────────────────────────────────────────────────────────

/// Called when the user taps an API key field that is currently masked.
- (void)apiKeyFieldTapped:(UITapGestureRecognizer *)tap {
    UITextField *field = (UITextField *)tap.view;
    if (field == self.apiKeyField && self.apiKeyMasked) {
        [self unmaskKeyField:field maskedFlag:&_apiKeyMasked];
    } else if (field == self.elKeyField && self.elKeyMasked) {
        [self unmaskKeyField:field maskedFlag:&_elKeyMasked];
    }
}

- (void)unmaskKeyField:(UITextField *)field maskedFlag:(BOOL *)flag {
    *flag = NO;
    field.text                  = @"";
    field.placeholder           = @"Enter new key";
    field.textColor             = [UIColor labelColor];
    field.backgroundColor       = [UIColor systemBackgroundColor];
    field.layer.borderWidth     = 0;
    [field becomeFirstResponder];
}

/// Renders a field in masked/saved state (no text shown, styled differently)
- (void)maskKeyField:(UITextField *)field placeholder:(NSString *)placeholder {
    field.text            = @"";
    field.placeholder     = placeholder;
    field.textColor       = [UIColor secondaryLabelColor];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UI Setup
// ─────────────────────────────────────────────────────────────────────────────

- (void)setupUI {
    
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scrollView];

    CGFloat w = self.view.frame.size.width - 40;
    CGFloat y = 20;

    // ── App Version (read from Info.plist) ───────────────────────────────────
    NSDictionary *infoPlist  = [NSBundle mainBundle].infoDictionary;
    NSString *appVersion     = infoPlist[@"CFBundleShortVersionString"] ?: @"?";
    NSString *buildNumber    = infoPlist[@"CFBundleVersion"]            ?: @"?";
    UILabel *versionLabel    = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 20)];
    versionLabel.text        = [NSString stringWithFormat:@"EZCompleteUI  v%@  (build %@)",
                                appVersion, buildNumber];
    versionLabel.font        = [UIFont systemFontOfSize:12];
    versionLabel.textColor   = [UIColor tertiaryLabelColor];
    versionLabel.textAlignment = NSTextAlignmentCenter;
    [self.scrollView addSubview:versionLabel];
    y += 30;

    // ── OpenAI ───────────────────────────────────────────────────────────────
    [self addSection:@"🤖 OpenAI" y:&y];
    [self addLabel:@"API Key:" y:&y];

    // API key field — tappable when masked
    self.apiKeyField = [[UITextField alloc] initWithFrame:CGRectMake(20, y, w, 40)];
    self.apiKeyField.borderStyle   = UITextBorderStyleRoundedRect;
    self.apiKeyField.placeholder   = @"sk-...";
    self.apiKeyField.delegate      = self;
    self.apiKeyField.returnKeyType = UIReturnKeyDone;
    self.apiKeyField.font          = [UIFont systemFontOfSize:14];
    self.apiKeyField.secureTextEntry = YES;
    UITapGestureRecognizer *apiTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(apiKeyFieldTapped:)];
    [self.apiKeyField addGestureRecognizer:apiTap];
    [self.scrollView addSubview:self.apiKeyField];
    y += 50;

    // ── System Prompt (inline multi-line UITextView) ──────────────────────
    [self addLabel:@"System Message:" y:&y];

    CGFloat minTextViewHeight = 80.0; // ~3 lines
    self.systemMsgView = [[UITextView alloc] initWithFrame:CGRectMake(20, y, w, minTextViewHeight)];
    self.systemMsgView.font          = [UIFont systemFontOfSize:14];
    self.systemMsgView.delegate      = self;
    self.systemMsgView.layer.cornerRadius  = 8;
    self.systemMsgView.layer.borderWidth   = 1.0;
    self.systemMsgView.layer.borderColor   = [UIColor systemGray4Color].CGColor;
    self.systemMsgView.backgroundColor     = [UIColor secondarySystemBackgroundColor];
    self.systemMsgView.textContainerInset  = UIEdgeInsetsMake(8, 6, 8, 6);
    self.systemMsgView.scrollEnabled       = NO; // We resize instead of scrolling
    self.systemMsgViewHeight               = minTextViewHeight;
    [self.scrollView addSubview:self.systemMsgView];
    y += minTextViewHeight + 10;

    // ── Sliders ───────────────────────────────────────────────────────────
    self.tempLabel  = [self addLabel:@"Temperature: 0.70" y:&y];
    self.tempSlider = [self addSlider:w y:&y min:0 max:2];
    self.freqLabel  = [self addLabel:@"Freq Penalty: 0.00" y:&y];
    self.freqSlider = [self addSlider:w y:&y min:-2 max:2];

    // ── Web Search ───────────────────────────────────────────────────────────
    [self addSection:@"🌐 Web Search" y:&y];
    [self addLabel:@"Enable web search by default:" y:&y];
    self.webSearchSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 30, y - 28, 51, 31)];
    [self.scrollView addSubview:self.webSearchSwitch];
    [self addLabel:@"Location hint (optional city):" y:&y];
    self.webLocationField = [self addField:w y:&y placeholder:@"e.g. Miami, FL"];

    // ── ElevenLabs TTS ───────────────────────────────────────────────────────
    [self addSection:@"🎙 ElevenLabs TTS" y:&y];
    [self addLabel:@"API Key:" y:&y];

    // ElevenLabs key field — same masking treatment
    self.elKeyField = [[UITextField alloc] initWithFrame:CGRectMake(20, y, w, 40)];
    self.elKeyField.borderStyle   = UITextBorderStyleRoundedRect;
    self.elKeyField.placeholder   = @"ElevenLabs API key";
    self.elKeyField.delegate      = self;
    self.elKeyField.returnKeyType = UIReturnKeyDone;
    self.elKeyField.font          = [UIFont systemFontOfSize:14];
    self.elKeyField.secureTextEntry = YES;
    UITapGestureRecognizer *elTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(apiKeyFieldTapped:)];
    [self.elKeyField addGestureRecognizer:elTap];
    [self.scrollView addSubview:self.elKeyField];
    y += 50;

    [self addLabel:@"Voice ID (preset or cloned):" y:&y];
    self.elVoiceField = [self addField:w - 95 y:&y placeholder:@"Voice ID"];

    UIButton *getVoicesBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    getVoicesBtn.frame = CGRectMake(w - 74, y - 50, 84, 40);
    [getVoicesBtn setTitle:@"Get Voices" forState:UIControlStateNormal];
    [getVoicesBtn addTarget:self action:@selector(fetchVoices)
          forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:getVoicesBtn];
    
        // ── ADD: Open "Text to Speech…" button ───────────────────────────────────────
        UIButton *ttsButton = [UIButton buttonWithType:UIButtonTypeSystem];
        ttsButton.frame = CGRectMake(20, y, w, 44);
        [ttsButton setTitle:@"Text to Speech…" forState:UIControlStateNormal];
        ttsButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        ttsButton.layer.cornerRadius = 8;
        ttsButton.backgroundColor = [UIColor systemFillColor];
        [ttsButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [ttsButton addTarget:self action:@selector(openTextToSpeech:) forControlEvents:UIControlEventTouchUpInside];
        [self.scrollView addSubview:ttsButton];
        y += 54;

        // ── ADD: Open "Voice Cloner" button (IVC + PVC) ─────────────────────────────
        UIButton *cloneButton = [UIButton buttonWithType:UIButtonTypeSystem];
        cloneButton.frame = CGRectMake(20, y, w, 44);
        [cloneButton setTitle:@"Voice Cloner (Instant + Pro PVC)..." forState:UIControlStateNormal];
        cloneButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        cloneButton.layer.cornerRadius = 8;
        cloneButton.backgroundColor = [UIColor secondarySystemFillColor];
        [cloneButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [cloneButton addTarget:self action:@selector(openVoiceCloner:) forControlEvents:UIControlEventTouchUpInside];
        [self.scrollView addSubview:cloneButton];
        y += 54;


    // ── ElevenLabs Voice Cloning ─────────────────────────────────────────────
    [self addSection:@"🎤 Voice Cloning (ElevenLabs)" y:&y];
    [self addLabel:@"Upload an audio sample to create a custom voice clone." y:&y];
    [self addButton:@"Create Voice Clone from Audio File"
              color:[UIColor systemPurpleColor]
             action:@selector(createInstantClone)
                  y:&y w:w];
    [self addButton:@"My Cloned Voices"
              color:[UIColor systemTealColor]
             action:@selector(showClonedVoices)
                  y:&y w:w];

    self.cloneStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 30)];
    self.cloneStatusLabel.font      = [UIFont systemFontOfSize:13];
    self.cloneStatusLabel.textColor = [UIColor secondaryLabelColor];
    self.cloneStatusLabel.text      = @"";
    [self.scrollView addSubview:self.cloneStatusLabel];
    y += 35;

    // ── Sora Text-to-Video ───────────────────────────────────────────────────
    [self addSection:@"🎬 Sora Text-to-Video" y:&y];

    [self addLabel:@"Model:" y:&y];
    self.soraModelField = [self addField:w y:&y placeholder:@"sora-2"];
    self.soraModelField.userInteractionEnabled = NO;
    UIButton *soraModelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    soraModelBtn.frame = CGRectMake(w - 74, y - 50, 84, 40);
    [soraModelBtn setTitle:@"Choose" forState:UIControlStateNormal];
    [soraModelBtn addTarget:self action:@selector(pickSoraModel)
          forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:soraModelBtn];

    [self addLabel:@"Resolution:" y:&y];
    self.soraSizeField = [self addField:w y:&y placeholder:@"1280x720"];
    self.soraSizeField.userInteractionEnabled = NO;
    UIButton *soraResBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    soraResBtn.frame = CGRectMake(w - 74, y - 50, 84, 40);
    [soraResBtn setTitle:@"Choose" forState:UIControlStateNormal];
    [soraResBtn addTarget:self action:@selector(pickSoraResolution)
         forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:soraResBtn];

    self.soraDurationLabel = [self addLabel:@"Duration: 4s  (sora-2: 4/8/12/16s  •  sora-2-pro: 5/10/15/20s)"
                                          y:&y];
    self.soraDurationSlider = [self addSlider:w y:&y min:1 max:20];
    [self.soraDurationSlider addTarget:self action:@selector(updateVideoLabels)
                      forControlEvents:UIControlEventValueChanged];

    // ── AI Memory ────────────────────────────────────────────────────────────
    [self addSection:@"🧠 AI Memory" y:&y];
    y += 8;
    [self addButton:@"📖 View / Edit Memories"
              color:[UIColor systemGreenColor]
             action:@selector(openMemoriesViewer)
                  y:&y w:w];
    [self addButton:@"Clear All Memories"
              color:[UIColor systemOrangeColor]
             action:@selector(confirmClearMemories)
                  y:&y w:w];
    [self addButton:@"View Helper Stats"
              color:[UIColor systemIndigoColor]
             action:@selector(showHelperStats)
                  y:&y w:w];
    [self addButton:@"💙 Donate via PayPal"
              color:[UIColor systemBlueColor]
             action:@selector(donate)
                  y:&y w:w];
    [self addButton:@"📬 Support & Feedback"
              color:[UIColor systemTealColor]
             action:@selector(openSupportRequest)
                  y:&y w:w];

    self.scrollView.contentSize = CGSizeMake(self.view.frame.size.width, y + 30);
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UITextViewDelegate (system prompt auto-expand)
// ─────────────────────────────────────────────────────────────────────────────

- (void)textViewDidChange:(UITextView *)textView {
    if (textView != self.systemMsgView) return;
    [self resizeSystemMsgView];
}

- (void)resizeSystemMsgView {
    CGFloat w = self.view.frame.size.width - 40;
    CGFloat minH = 80.0;

    // Calculate the height needed to show all text
    CGSize sizeThatFits = [self.systemMsgView sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    CGFloat newH = MAX(minH, sizeThatFits.height);

    if (ABS(newH - self.systemMsgViewHeight) < 1.0) return; // No meaningful change

    CGFloat delta = newH - self.systemMsgViewHeight;
    self.systemMsgViewHeight = newH;

    // Resize the text view frame
    CGRect tvFrame = self.systemMsgView.frame;
    tvFrame.size.height = newH;
    self.systemMsgView.frame = tvFrame;

    // Shift every subview below the text view down by delta
    CGFloat tvBottom = CGRectGetMaxY(tvFrame);
    for (UIView *sub in self.scrollView.subviews) {
        if (sub == self.systemMsgView) continue;
        if (sub.frame.origin.y >= tvBottom - delta - 1) {
            CGRect f  = sub.frame;
            f.origin.y += delta;
            sub.frame  = f;
        }
    }

    // Expand the scroll content
    CGSize cs = self.scrollView.contentSize;
    cs.height += delta;
    self.scrollView.contentSize = cs;
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UI Helper Methods
// ─────────────────────────────────────────────────────────────────────────────

- (void)addSection:(NSString *)title y:(CGFloat *)y {
    *y += 10;
    UILabel *label      = [[UILabel alloc] initWithFrame:
                           CGRectMake(20, *y, self.view.frame.size.width - 40, 28)];
    label.text          = title;
    label.font          = [UIFont boldSystemFontOfSize:15];
    label.textColor     = [UIColor systemBlueColor];
    [self.scrollView addSubview:label];
    *y += 34;
}

- (UILabel *)addLabel:(NSString *)text y:(CGFloat *)y {
    UILabel *label      = [[UILabel alloc] initWithFrame:
                           CGRectMake(20, *y, self.view.frame.size.width - 40, 20)];
    label.text          = text;
    label.font          = [UIFont systemFontOfSize:13];
    label.textColor     = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    [self.scrollView addSubview:label];
    *y += 22;
    return label;
}

- (UITextField *)addField:(CGFloat)width y:(CGFloat *)y placeholder:(NSString *)placeholder {
    UITextField *field  = [[UITextField alloc] initWithFrame:CGRectMake(20, *y, width, 40)];
    field.borderStyle   = UITextBorderStyleRoundedRect;
    field.placeholder   = placeholder;
    field.delegate      = self;
    field.returnKeyType = UIReturnKeyDone;
    field.font          = [UIFont systemFontOfSize:14];
    [self.scrollView addSubview:field];
    *y += 50;
    return field;
}

- (UISlider *)addSlider:(CGFloat)width y:(CGFloat *)y min:(float)minVal max:(float)maxVal {
    UISlider *slider    = [[UISlider alloc] initWithFrame:CGRectMake(20, *y, width, 30)];
    slider.minimumValue = minVal;
    slider.maximumValue = maxVal;
    [slider addTarget:self action:@selector(updateLabels)
     forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:slider];
    *y += 45;
    return slider;
}

- (void)addButton:(NSString *)title color:(UIColor *)color action:(SEL)action
                y:(CGFloat *)y w:(CGFloat)width {
    UIButton *button          = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame              = CGRectMake(20, *y, width, 44);
    button.backgroundColor    = color;
    button.tintColor          = [UIColor whiteColor];
    button.layer.cornerRadius = 10;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:button];
    *y += 55;
}

- (void)updateLabels {
    self.tempLabel.text = [NSString stringWithFormat:@"Temperature: %.2f", self.tempSlider.value];
    self.freqLabel.text = [NSString stringWithFormat:@"Freq Penalty: %.2f", self.freqSlider.value];
}

- (void)updateVideoLabels {
    NSString *model = self.soraModelField.text ?: @"sora-2";
    BOOL      isPro = [model isEqualToString:@"sora-2-pro"];
    NSInteger raw   = (NSInteger)self.soraDurationSlider.value;

    NSArray<NSNumber *> *validDurations = isPro
        ? @[@5, @10, @15, @20]
        : @[@4, @8, @12, @16];

    NSInteger snapped = validDurations.firstObject.integerValue;
    NSInteger bestDiff = NSIntegerMax;
    for (NSNumber *v in validDurations) {
        NSInteger diff = ABS(raw - v.integerValue);
        if (diff < bestDiff) { bestDiff = diff; snapped = v.integerValue; }
    }
    NSString *hint = isPro ? @"(5/10/15/20s)" : @"(4/8/12/16s)";
    self.soraDurationLabel.text = [NSString stringWithFormat:@"Duration: %lds %@",
                                   (long)snapped, hint];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sora Model / Resolution Pickers
// ─────────────────────────────────────────────────────────────────────────────

- (void)pickSoraModel {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Sora Model"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary *descriptions = @{
        @"sora-2":     @"Fast, flexible — 4/8/12/16s",
        @"sora-2-pro": @"High fidelity — 5/10/15/20s"
    };
    for (NSString *model in @[@"sora-2", @"sora-2-pro"]) {
        NSString *title = [NSString stringWithFormat:@"%@  (%@)", model, descriptions[model]];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            self.soraModelField.text = model;
            [self updateVideoLabels];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickSoraResolution {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Video Size"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary *descriptions = @{
        @"1280x720":  @"Landscape 720p  (recommended)",
        @"1792x1024": @"Landscape wide  (cinematic)",
        @"720x1280":  @"Portrait 720p   (social/reels)",
        @"1024x1792": @"Portrait tall   (stories)"
    };
    for (NSString *res in @[@"1280x720", @"1792x1024", @"720x1280", @"1024x1792"]) {
        NSString *title = [NSString stringWithFormat:@"%@  —  %@", res, descriptions[res]];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            self.soraSizeField.text = res;
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ElevenLabs Voice Fetching
// ─────────────────────────────────────────────────────────────────────────────

- (void)openTextToSpeech:(id)sender {
    EZLog(EZLogLevelInfo, @"SETTINGS", @"Opening TextToSpeechViewController");
    TextToSpeechViewController *vc = [[TextToSpeechViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openVoiceCloner:(id)sender {
    EZLog(EZLogLevelInfo, @"SETTINGS", @"Opening ElevenLabsCloneViewController");
    ElevenLabsCloneViewController *vc = [[ElevenLabsCloneViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}



/// Returns the current ElevenLabs key — from vault if masked, from field if being edited.
- (NSString *)resolvedElevenLabsKey {
    if (self.elKeyMasked) {
        return [EZKeyVault loadKeyForIdentifier:EZVaultKeyElevenLabs] ?: @"";
    }
    return self.elKeyField.text ?: @"";
}

- (void)fetchVoices {
    NSString *key = [self resolvedElevenLabsKey];
    if (key.length == 0) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.elevenlabs.io/v1/voices"]];
    [request setValue:key forHTTPHeaderField:@"xi-api-key"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data || error) return;
        NSDictionary *json   = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray      *voices = json[@"voices"];

        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Select Voice"
                message:nil preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSDictionary *voice in voices) {
                [sheet addAction:[UIAlertAction actionWithTitle:voice[@"name"]
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction *a) {
                    self.elVoiceField.text = voice[@"voice_id"];
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                      style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:sheet animated:YES completion:nil];
        });
    }] resume];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ElevenLabs Voice Cloning
// ─────────────────────────────────────────────────────────────────────────────

- (void)createInstantClone {
    NSString *key = [self resolvedElevenLabsKey];
    if (key.length == 0) {
        [self showAlert:@"ElevenLabs Key Required"
                message:@"Enter your ElevenLabs API key before creating a voice clone."];
        return;
    }

    UIAlertController *namePrompt = [UIAlertController
        alertControllerWithTitle:@"Name Your Clone"
                         message:@"Enter a display name for this voice."
                  preferredStyle:UIAlertControllerStyleAlert];
    [namePrompt addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"e.g. My Voice";
    }];
    [namePrompt addAction:[UIAlertAction actionWithTitle:@"Next"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
        NSString *name = namePrompt.textFields.firstObject.text;
        if (!name.length) name = @"My Clone";
        [self presentAudioPickerForCloneName:name];
    }]];
    [namePrompt addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                   style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:namePrompt animated:YES completion:nil];
}

- (void)presentAudioPickerForCloneName:(NSString *)cloneName {
    objc_setAssociatedObject(self, kEZCloneNameKey, cloneName, OBJC_ASSOCIATION_COPY_NONATOMIC);

    NSArray *audioTypes = @[
        UTTypeAudio, UTTypeMP3, UTTypeMPEG4Audio,
        [UTType typeWithIdentifier:@"public.ogg-audio"],
        [UTType typeWithIdentifier:@"com.microsoft.waveform-audio"]
    ];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:audioTypes asCopy:YES];
    picker.delegate = self;
    objc_setAssociatedObject(picker, kEZPickerPurposeKey,
                             @"voiceClone", OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *purpose = objc_getAssociatedObject(controller, kEZPickerPurposeKey);
    if (![purpose isEqualToString:@"voiceClone"]) return;

    NSURL *audioFile = urls.firstObject;
    if (!audioFile) return;

    NSString *cloneName = objc_getAssociatedObject(self, kEZCloneNameKey) ?: @"My Clone";
    [self updateCloneStatus:@"Uploading audio sample..."];
    [self uploadAudioForClone:cloneName fileURL:audioFile];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self updateCloneStatus:@""];
}

- (void)uploadAudioForClone:(NSString *)cloneName fileURL:(NSURL *)fileURL {
    NSData *audioData = [NSData dataWithContentsOfURL:fileURL];
    if (!audioData) {
        [self updateCloneStatus:@"Error: could not read audio file."];
        return;
    }

    NSString *elKey    = [self resolvedElevenLabsKey];
    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];

    NSURL *cloneURL = [NSURL URLWithString:@"https://api.elevenlabs.io/v1/voices/add"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:cloneURL];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 120;
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
   forHTTPHeaderField:@"Content-Type"];
    [request setValue:elKey forHTTPHeaderField:@"xi-api-key"];

    NSMutableData *body = [NSMutableData data];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"name\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[cloneName dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"description\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Created via EZCompleteUI" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"files\"; filename=\"%@\"\r\n",
                       fileURL.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: audio/mpeg\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:audioData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    request.HTTPBody = body;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            [self updateCloneStatus:@"Upload failed — check your connection."];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *voiceID  = json[@"voice_id"];

        id detailObj = json[@"detail"];
        NSString *errorMsg = @"";
        if ([detailObj isKindOfClass:[NSString class]]) {
            errorMsg = detailObj;
        } else if ([detailObj isKindOfClass:[NSArray class]]) {
            NSDictionary *first = [detailObj firstObject];
            if ([first isKindOfClass:[NSDictionary class]] && first[@"msg"]) {
                errorMsg = first[@"msg"];
            } else {
                errorMsg = @"Invalid file or parameters.";
            }
        } else if (json[@"message"]) {
            errorMsg = json[@"message"];
        }

        if ([voiceID isKindOfClass:[NSString class]] && voiceID.length > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.elVoiceField.text = voiceID;
                [self updateCloneStatus:[NSString stringWithFormat:@"✅ Clone '%@' created!", cloneName]];
            });
        } else {
            NSString *finalStatus = (errorMsg.length > 0)
                ? [NSString stringWithFormat:@"Failed: %@", errorMsg]
                : @"Clone creation failed.";
            [self updateCloneStatus:finalStatus];
        }
    }] resume];
}

- (void)updateCloneStatus:(NSString *)statusMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.cloneStatusLabel.text = statusMessage;
    });
}

- (void)showClonedVoices {
    NSString *key = [self resolvedElevenLabsKey];
    if (key.length == 0) {
        [self showAlert:@"ElevenLabs Key Required" message:@"Enter your ElevenLabs API key first."];
        return;
    }

    [self updateCloneStatus:@"Loading cloned voices..."];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.elevenlabs.io/v1/voices"]];
    [request setValue:key forHTTPHeaderField:@"xi-api-key"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data || error) {
            [self updateCloneStatus:@"Failed to load voices."];
            return;
        }
        NSDictionary *json   = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray      *voices = json[@"voices"];

        NSMutableArray<NSDictionary *> *cloned = [NSMutableArray array];
        for (NSDictionary *voice in voices) {
            if ([[voice[@"category"] description] isEqualToString:@"cloned"]) {
                [cloned addObject:voice];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateCloneStatus:@""];
            if (cloned.count == 0) {
                [self showAlert:@"No Cloned Voices"
                        message:@"You haven't created any voice clones yet."];
                return;
            }
            UIAlertController *sheet = [UIAlertController
                alertControllerWithTitle:@"My Cloned Voices"
                                 message:@"Tap a voice to select it, or swipe to delete."
                          preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSDictionary *v in cloned) {
                [sheet addAction:[UIAlertAction actionWithTitle:v[@"name"]
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction *a) {
                    self.elVoiceField.text = v[@"voice_id"];
                }]];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:@"🗑 Delete a Clone..."
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(UIAlertAction *a) {
                [self showDeleteCloneSheet:cloned];
            }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                      style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:sheet animated:YES completion:nil];
        });
    }] resume];
}

- (void)showDeleteCloneSheet:(NSArray<NSDictionary *> *)voices {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"Delete Voice Clone"
                         message:@"This permanently deletes the voice from ElevenLabs."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *voice in voices) {
        NSString *name    = voice[@"name"] ?: @"Unnamed";
        NSString *voiceID = voice[@"voice_id"];
        [sheet addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *a) {
            [self confirmDeleteVoice:voiceID name:name];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmDeleteVoice:(NSString *)voiceID name:(NSString *)voiceName {
    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Delete \"%@\"?", voiceName]
                         message:@"This cannot be undone."
                  preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
        [self deleteVoiceFromAPI:voiceID name:voiceName];
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)deleteVoiceFromAPI:(NSString *)voiceID name:(NSString *)voiceName {
    NSString *urlString = [NSString stringWithFormat:@"https://api.elevenlabs.io/v1/voices/%@", voiceID];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.HTTPMethod = @"DELETE";
    [request setValue:[self resolvedElevenLabsKey] forHTTPHeaderField:@"xi-api-key"];

    EZLogf(EZLogLevelInfo, @"SETTINGS", @"Deleting voice: %@ (%@)", voiceName, voiceID);
    [self updateCloneStatus:[NSString stringWithFormat:@"Deleting %@...", voiceName]];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode == 200 || http.statusCode == 204) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.elVoiceField.text isEqualToString:voiceID]) {
                    self.elVoiceField.text = @"";
                }
                [self updateCloneStatus:[NSString stringWithFormat:@"Deleted: %@", voiceName]];
            });
        } else {
            [self updateCloneStatus:@"Delete failed — check your API key."];
        }
    }] resume];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Memory & Stats Actions
// ─────────────────────────────────────────────────────────────────────────────

- (void)openMemoriesViewer {
    MemoriesViewController *vc = [[MemoriesViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)confirmClearMemories {
    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Clear All Memories?"
                         message:@"This deletes all saved conversation summaries. Cannot be undone."
                  preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
        BOOL cleared = clearMemoryLog();
        NSString *message = cleared ? @"All memories cleared." : @"Error clearing memories.";
        [self showAlert:@"Memory" message:message];
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)showHelperStats {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"EZHelper Stats"
        message:EZHelperStats() preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = EZHelperStats();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Donate
// ─────────────────────────────────────────────────────────────────────────────

- (void)donate {
    [[UIApplication sharedApplication]
        openURL:[NSURL URLWithString:@"https://paypal.me/i0stweak3r"]
        options:@{}
        completionHandler:nil];
}

- (void)openSupportRequest {
    SupportRequestViewController *supportVC = [[SupportRequestViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc]
                                   initWithRootViewController:supportVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Load / Save Settings
// ─────────────────────────────────────────────────────────────────────────────

- (void)loadSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // ── OpenAI key — load from vault, never show plaintext ───────────────────
    if ([EZKeyVault hasKeyForIdentifier:EZVaultKeyOpenAI]) {
        self.apiKeyMasked = YES;
        [self maskKeyField:self.apiKeyField placeholder:kAPIKeyMaskedPlaceholder];
    } else {
        // Migrate from UserDefaults if present (one-time upgrade path)
        NSString *legacyKey = [defaults stringForKey:@"apiKey"];
        if (legacyKey.length > 0) {
            [EZKeyVault saveKey:legacyKey forIdentifier:EZVaultKeyOpenAI];
            [defaults removeObjectForKey:@"apiKey"];
            [defaults synchronize];
            self.apiKeyMasked = YES;
            [self maskKeyField:self.apiKeyField placeholder:kAPIKeyMaskedPlaceholder];
        }
        // else: field stays blank for first-time entry
    }

    // ── ElevenLabs key — same treatment ──────────────────────────────────────
    if ([EZKeyVault hasKeyForIdentifier:EZVaultKeyElevenLabs]) {
        self.elKeyMasked = YES;
        [self maskKeyField:self.elKeyField placeholder:kELKeyMaskedPlaceholder];
    } else {
        NSString *legacyElKey = [defaults stringForKey:@"elevenKey"];
        if (legacyElKey.length > 0) {
            [EZKeyVault saveKey:legacyElKey forIdentifier:EZVaultKeyElevenLabs];
            [defaults removeObjectForKey:@"elevenKey"];
            [defaults synchronize];
            self.elKeyMasked = YES;
            [self maskKeyField:self.elKeyField placeholder:kELKeyMaskedPlaceholder];
        }
    }

    // ── Non-sensitive settings stay in UserDefaults ───────────────────────────
    self.systemMsgView.text        = [defaults stringForKey:@"systemMessage"] ?: @"";
    self.tempSlider.value          = [defaults floatForKey:@"temperature"] ?: 0.7f;
    self.freqSlider.value          = [defaults floatForKey:@"frequency"];
    self.elVoiceField.text         = [defaults stringForKey:@"elevenVoiceID"];
    self.webSearchSwitch.on        = [defaults boolForKey:@"webSearchEnabled"];
    self.webLocationField.text     = [defaults stringForKey:@"webSearchLocation"];
    self.soraModelField.text       = [defaults stringForKey:@"soraModel"]    ?: @"sora-2";
    self.soraSizeField.text        = [defaults stringForKey:@"soraSize"]     ?: @"1280x720";
    self.soraDurationSlider.value  = (float)([defaults integerForKey:@"soraDuration"] ?: 4);

    [self updateLabels];
    [self updateVideoLabels];

    // Resize system prompt text view to fit loaded content
    dispatch_async(dispatch_get_main_queue(), ^{
        [self resizeSystemMsgView];
    });
}

- (void)saveAndClose {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // ── OpenAI key: only save to vault if the user actually typed a new one ───
    if (!self.apiKeyMasked && self.apiKeyField.text.length > 0) {
        [EZKeyVault saveKey:self.apiKeyField.text forIdentifier:EZVaultKeyOpenAI];
    }

    // ── ElevenLabs key: same logic ────────────────────────────────────────────
    if (!self.elKeyMasked && self.elKeyField.text.length > 0) {
        [EZKeyVault saveKey:self.elKeyField.text forIdentifier:EZVaultKeyElevenLabs];
    }

    // ── Non-sensitive settings ────────────────────────────────────────────────
    [defaults setObject:self.systemMsgView.text      forKey:@"systemMessage"];
    [defaults setFloat:self.tempSlider.value         forKey:@"temperature"];
    [defaults setFloat:self.freqSlider.value         forKey:@"frequency"];
    [defaults setObject:self.elVoiceField.text       forKey:@"elevenVoiceID"];
    [defaults setBool:self.webSearchSwitch.isOn      forKey:@"webSearchEnabled"];
    [defaults setObject:self.webLocationField.text   forKey:@"webSearchLocation"];
    [defaults setObject:self.soraModelField.text     forKey:@"soraModel"];
    [defaults setObject:self.soraSizeField.text      forKey:@"soraSize"];
    [defaults setInteger:(NSInteger)self.soraDurationSlider.value forKey:@"soraDuration"];
    [defaults synchronize];

    EZLog(EZLogLevelInfo, @"SETTINGS", @"Settings saved");
    [self dismissViewControllerAnimated:YES completion:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Utility
// ─────────────────────────────────────────────────────────────────────────────

- (void)showAlert:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
            message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

@end
