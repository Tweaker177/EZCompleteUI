// ViewController.m
// EZCompleteUI v4.0
//
// Changes from v3:
//   - analyzePromptForContext / createMemoryFromCompletion updated for new signatures
//   - 4-tier routing: Tier 1 answers directly, Tier 4 injects history turns
//   - clearConversation saves thread before wiping
//   - Chat history button → ChatHistoryViewController
//   - Thread restored via delegate
//   - Image edit API (dall-e-2 /v1/images/edits) for image+prompt combos
//   - Auto model selection: image attached → gpt-4o for analysis, dall-e-2 for edit
//   - Sora: always polls — initial response is always async job
//   - Attached files/images saved to EZAttachments via EZAttachmentSave

#import "ViewController.h"
#import "SettingsViewController.h"
#import "ChatHistoryViewController.h"
#import "helpers.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuickLook/QuickLook.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <PDFKit/PDFKit.h>

typedef NS_ENUM(NSInteger, EZAttachMode) {
    EZAttachModeNone,
    EZAttachModeWhisper,
    EZAttachModeAnalyze,
};

@interface ViewController () <UIDocumentPickerDelegate,
                               UITextFieldDelegate,
                               QLPreviewControllerDataSource,
                               SFSpeechRecognizerDelegate,
                               ChatHistoryViewControllerDelegate>

// UI
@property (nonatomic, strong) UITextView    *chatHistoryView;
@property (nonatomic, strong) UIView        *inputContainer;
@property (nonatomic, strong) UITextField   *messageTextField;
@property (nonatomic, strong) UIButton      *sendButton;
@property (nonatomic, strong) UIButton      *modelButton;
@property (nonatomic, strong) UIButton      *attachButton;
@property (nonatomic, strong) UIButton      *settingsButton;
@property (nonatomic, strong) UIButton      *clipboardButton;
@property (nonatomic, strong) UIButton      *speakButton;
@property (nonatomic, strong) UIButton      *clearButton;
@property (nonatomic, strong) UIButton      *dictateButton;
@property (nonatomic, strong) UIButton      *webSearchButton;
@property (nonatomic, strong) UIButton      *historyButton;
@property (nonatomic, strong) UIButton      *addChatButton;
@property (nonatomic, strong) NSLayoutConstraint *containerBottomConstraint;

// State
@property (nonatomic, strong) NSArray       *models;
@property (nonatomic, strong) NSString      *selectedModel;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *chatContext;
@property (nonatomic, assign) BOOL          webSearchEnabled;

// Active thread
@property (nonatomic, strong) EZChatThread  *activeThread;

// Media / file state
@property (nonatomic, strong) NSURL         *previewURL;
@property (nonatomic, strong) NSString      *pendingFileContext;   // text extracted from file
@property (nonatomic, strong) NSString      *pendingFileName;
@property (nonatomic, strong) NSString      *pendingImagePath;     // local path of attached image
@property (nonatomic, strong) NSString      *lastImagePrompt;      // last DALL-E prompt (for follow-ups)
@property (nonatomic, strong) NSString      *lastImageLocalPath;   // local path of last generated image

// TTS / audio
@property (nonatomic, strong) AVSpeechSynthesizer *speechSynthesizer;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSString      *lastAIResponse;
@property (nonatomic, strong) NSString      *lastUserPrompt;

// Dictation
@property (nonatomic, strong) SFSpeechRecognizer               *speechRecognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *recognitionRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask          *recognitionTask;
@property (nonatomic, strong) AVAudioEngine                    *audioEngine;
@property (nonatomic, assign) BOOL                              isDictating;

@end

@implementation ViewController

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    EZLogRotateIfNeeded(512 * 1024);
    EZLog(EZLogLevelInfo, @"APP", @"EZCompleteUI v4.0 viewDidLoad");
    [self setupData];
    [self setupUI];
    [self setupKeyboardObservers];
    [self setupDictation];
    [self requestSpeechPermissionsIfNeeded];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(resumePendingSoraJobIfNeeded)
        name:@"EZAppDidBecomeActive" object:nil];
}

- (void)setupData {
    self.models = @[
        @"gpt-5-pro", @"gpt-5", @"gpt-5-mini",
        @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4",
        @"gpt-3.5-turbo",
        @"dall-e-3",
        @"sora-2", @"sora-2-pro",
        @"whisper-1"
    ];
    self.chatContext       = [NSMutableArray array];
    self.speechSynthesizer = [[AVSpeechSynthesizer alloc] init];
    self.selectedModel     = [[NSUserDefaults standardUserDefaults] stringForKey:@"selectedModel"]
                             ?: self.models[0];
    self.webSearchEnabled  = [[NSUserDefaults standardUserDefaults] boolForKey:@"webSearchEnabled"];
    [self startNewThread];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Thread Management
// ─────────────────────────────────────────────────────────────────────────────

- (void)startNewThread {
    EZChatThread *t = [[EZChatThread alloc] init];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat       = @"yyyy-MM-dd'T'HH:mm:ss";
    fmt.locale           = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    t.threadID           = [fmt stringFromDate:[NSDate date]];
    t.modelName          = self.selectedModel;
    t.chatContext        = @[];
    t.attachmentPaths    = @[];
    self.activeThread    = t;
    EZLogf(EZLogLevelInfo, @"THREAD", @"New thread: %@", t.threadID);
}

- (void)saveActiveThread {
    if (!self.activeThread || self.chatContext.count == 0) return;

    // Sync chatContext into thread before saving
    self.activeThread.chatContext = [self.chatContext copy];
    self.activeThread.modelName   = self.selectedModel;

    // Set title from first user message if not set
    if ([self.activeThread.title isEqualToString:@"New Conversation"] ||
        self.activeThread.title.length == 0) {
        for (NSDictionary *msg in self.chatContext) {
            if ([msg[@"role"] isEqualToString:@"user"]) {
                id content = msg[@"content"];
                NSString *text = [content isKindOfClass:[NSString class]] ? content : @"";
                self.activeThread.title = text.length > 60
                    ? [[text substringToIndex:60] stringByAppendingString:@"…"]
                    : text;
                break;
            }
        }
    }
    // Carry last image path if any
    if (self.lastImageLocalPath) self.activeThread.lastImageLocalPath = self.lastImageLocalPath;

    EZThreadSave(self.activeThread, nil);
    EZLogf(EZLogLevelInfo, @"THREAD", @"Saved: %@", self.activeThread.threadID);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ChatHistoryViewControllerDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)chatHistoryDidSelectThread:(EZChatThread *)thread {
    // Restore thread into active state
    [self.chatContext removeAllObjects];
    [self.chatContext addObjectsFromArray:thread.chatContext];

    self.activeThread      = thread;
    self.selectedModel     = thread.modelName ?: self.selectedModel;
    self.lastImageLocalPath = thread.lastImageLocalPath;
    self.lastUserPrompt    = nil;
    self.lastAIResponse    = nil;
    self.pendingFileContext = nil;
    self.pendingFileName    = nil;
    self.pendingImagePath   = nil;

    // Update model button
    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", self.selectedModel]
                      forState:UIControlStateNormal];

    // Rebuild chat display from context
    NSMutableString *display = [NSMutableString string];
    for (NSDictionary *msg in self.chatContext) {
        NSString *role    = msg[@"role"] ?: @"";
        id        content = msg[@"content"];
        NSString *text    = [content isKindOfClass:[NSString class]] ? content : @"[attachment]";
        if ([role isEqualToString:@"user"]) {
            [display appendFormat:@"\n\nYou: %@", text];
        } else if ([role isEqualToString:@"assistant"]) {
            [display appendFormat:@"\n\nAI: %@", text];
            self.lastAIResponse = text;
        }
    }
    self.chatHistoryView.text = display.length > 0
        ? [display substringFromIndex:2]   // trim leading \n\n
        : @"[System: Conversation restored]";

    [self.chatHistoryView scrollRangeToVisible:
        NSMakeRange(self.chatHistoryView.text.length > 0 ? self.chatHistoryView.text.length - 1 : 0, 1)];

    [self appendToChat:[NSString stringWithFormat:@"[System: Thread \"%@\" restored ✓]", thread.title]];
    EZLogf(EZLogLevelInfo, @"THREAD", @"Restored: %@ (%lu turns)",
           thread.threadID, (unsigned long)self.chatContext.count);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shake → Stats
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        NSString *stats = EZHelperStats();
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"EZHelper Stats"
                                                                   message:stats
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [UIPasteboard generalPasteboard].string = stats;
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Dictation
// ─────────────────────────────────────────────────────────────────────────────

- (void)setupDictation {
    self.speechRecognizer = [[SFSpeechRecognizer alloc]
        initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    self.speechRecognizer.delegate = self;
    self.audioEngine = [[AVAudioEngine alloc] init];
    self.isDictating = NO;
}

/// Request both speech recognition and microphone permissions upfront
/// so they appear in Privacy settings and don't surprise the user mid-tap.
- (void)requestSpeechPermissionsIfNeeded {
    // Only prompt if not yet determined
    if ([SFSpeechRecognizer authorizationStatus] == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.dictateButton.enabled = (status == SFSpeechRecognizerAuthorizationStatusAuthorized);
                EZLogf(EZLogLevelInfo, @"DICTATE", @"Speech auth: %ld", (long)status);
            });
        }];
    }
    AVAuthorizationStatus micStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (micStatus == AVAuthorizationStatusNotDetermined) {
        [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
            EZLogf(EZLogLevelInfo, @"DICTATE", @"Mic permission: %@", granted ? @"granted" : @"denied");
        }];
    }
}

- (void)speechRecognizer:(SFSpeechRecognizer *)speechRecognizer availabilityDidChange:(BOOL)available {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.dictateButton.enabled = available;
        EZLogf(EZLogLevelDebug, @"DICTATE", @"Availability: %@", available ? @"YES" : @"NO");
    });
}

- (void)toggleDictation {
    if (self.isDictating) { [self stopDictation]; return; }
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (granted) [self startDictation];
                        else [self appendToChat:@"[Dictation Error]: Mic permission denied."];
                    });
                }];
            } else {
                [self appendToChat:@"[Dictation Error]: Speech recognition permission denied."];
            }
        });
    }];
}

- (void)startDictation {
    if (self.recognitionTask) { [self.recognitionTask cancel]; self.recognitionTask = nil; }
    NSError *err;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryRecord
                    mode:AVAudioSessionModeMeasurement
                 options:AVAudioSessionCategoryOptionDuckOthers error:&err];
    [session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&err];
    if (err) { EZLogf(EZLogLevelError, @"DICTATE", @"Session: %@", err); return; }

    self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.recognitionRequest.shouldReportPartialResults = YES;
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    __weak typeof(self) ws = self;
    self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest
        resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        __strong typeof(ws) ss = ws; if (!ss) return;
        if (result) dispatch_async(dispatch_get_main_queue(), ^{
            ss.messageTextField.text = result.bestTranscription.formattedString;
        });
        if (error || result.isFinal) {
            [ss.audioEngine stop]; [inputNode removeTapOnBus:0];
            ss.recognitionRequest = nil; ss.recognitionTask = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                ss.isDictating = NO;
                [ss.dictateButton setTintColor:[UIColor systemBlueColor]];
            });
        }
    }];
    [inputNode installTapOnBus:0 bufferSize:1024 format:[inputNode outputFormatForBus:0]
                         block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        [self.recognitionRequest appendAudioPCMBuffer:buf];
    }];
    [self.audioEngine prepare];
    NSError *engineErr;
    [self.audioEngine startAndReturnError:&engineErr];
    if (engineErr) { EZLogf(EZLogLevelError, @"DICTATE", @"Engine: %@", engineErr); return; }
    self.isDictating = YES;
    [self.dictateButton setTintColor:[UIColor systemRedColor]];
    EZLog(EZLogLevelInfo, @"DICTATE", @"Started");
}

- (void)stopDictation {
    if (self.audioEngine.isRunning) { [self.audioEngine stop]; [self.recognitionRequest endAudio]; }
    self.isDictating = NO;
    [self.dictateButton setTintColor:[UIColor systemBlueColor]];
    EZLog(EZLogLevelInfo, @"DICTATE", @"Stopped");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UI Setup
// ─────────────────────────────────────────────────────────────────────────────

- (void)setupUI {
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // Top bar buttons
    // + New chat (save current, start fresh)
    self.addChatButton   = [self _iconButton:@"square.and.pencil" tint:[UIColor systemGreenColor]
                                      action:@selector(newChat)];
    // History (browse/restore past threads)
    self.historyButton   = [self _iconButton:@"clock.arrow.circlepath" tint:nil
                                      action:@selector(openHistory)];
    // Copy last AI response
    self.clipboardButton = [self _iconButton:@"doc.on.doc" tint:nil
                                      action:@selector(copyLastResponse)];
    // Speak last AI response
    self.speakButton     = [self _iconButton:@"speaker.wave.2.fill" tint:nil
                                      action:@selector(speakLastResponse)];
    // Web search toggle
    self.webSearchButton = [self _iconButton:@"globe" tint:nil
                                      action:@selector(toggleWebSearch)];
    [self updateWebSearchButtonTint];
    // Settings
    self.settingsButton  = [self _iconButton:@"gearshape.fill" tint:nil
                                      action:@selector(openSettings)];
    // Trash = delete current chat (confirm) then start new one
    self.clearButton     = [self _iconButton:@"trash.fill" tint:[UIColor systemRedColor]
                                      action:@selector(deleteCurrentChat)];

    // Full-width stack — equalSpacing distributes buttons edge to edge
    UIStackView *topStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.addChatButton, self.historyButton, self.clipboardButton,
        self.speakButton, self.webSearchButton, self.settingsButton, self.clearButton
    ]];
    topStack.distribution = UIStackViewDistributionEqualSpacing;
    topStack.alignment    = UIStackViewAlignmentCenter;
    topStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:topStack];

    // Chat view
    self.chatHistoryView = [[UITextView alloc] init];
    self.chatHistoryView.editable = NO;
    self.chatHistoryView.font     = [UIFont systemFontOfSize:16];
    self.chatHistoryView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.chatHistoryView];

    // Input container
    self.inputContainer = [[UIView alloc] init];
    self.inputContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.inputContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.inputContainer];

    // Model picker button
    self.modelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", self.selectedModel]
                      forState:UIControlStateNormal];
    [self.modelButton addTarget:self action:@selector(showModelPicker)
                forControlEvents:UIControlEventTouchUpInside];
    self.modelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.modelButton];

    // Attach button
    self.attachButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.attachButton setImage:[UIImage systemImageNamed:@"paperclip.circle.fill"]
                       forState:UIControlStateNormal];
    [self.attachButton addTarget:self action:@selector(showAttachMenu)
                forControlEvents:UIControlEventTouchUpInside];
    self.attachButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.attachButton];

    // Dictate button
    self.dictateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.dictateButton setImage:[UIImage systemImageNamed:@"mic.fill"] forState:UIControlStateNormal];
    [self.dictateButton setTintColor:[UIColor systemBlueColor]];
    [self.dictateButton addTarget:self action:@selector(toggleDictation)
                 forControlEvents:UIControlEventTouchUpInside];
    self.dictateButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.dictateButton];

    // Text field
    self.messageTextField = [[UITextField alloc] init];
    self.messageTextField.placeholder  = @"Type message...";
    self.messageTextField.borderStyle  = UITextBorderStyleRoundedRect;
    self.messageTextField.delegate     = self;
    self.messageTextField.returnKeyType = UIReturnKeyDone;
    self.messageTextField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.messageTextField];

    // Send button
    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendButton setTitle:@"Send" forState:UIControlStateNormal];
    [self.sendButton addTarget:self action:@selector(handleSend)
              forControlEvents:UIControlEventTouchUpInside];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.sendButton];

    [self.sendButton setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                     forAxis:UILayoutConstraintAxisHorizontal];
    [self.messageTextField setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                           forAxis:UILayoutConstraintAxisHorizontal];

    self.containerBottomConstraint =
        [self.inputContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [topStack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:5],
        [topStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [topStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.chatHistoryView.topAnchor constraintEqualToAnchor:topStack.bottomAnchor constant:8],
        [self.chatHistoryView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.chatHistoryView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.chatHistoryView.bottomAnchor constraintEqualToAnchor:self.inputContainer.topAnchor],
        [self.inputContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.inputContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.containerBottomConstraint,
        [self.modelButton.topAnchor constraintEqualToAnchor:self.inputContainer.topAnchor constant:8],
        [self.modelButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],
        [self.attachButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],
        [self.attachButton.topAnchor constraintEqualToAnchor:self.modelButton.bottomAnchor constant:12],
        [self.dictateButton.leadingAnchor constraintEqualToAnchor:self.attachButton.trailingAnchor constant:6],
        [self.dictateButton.centerYAnchor constraintEqualToAnchor:self.attachButton.centerYAnchor],
        [self.messageTextField.leadingAnchor constraintEqualToAnchor:self.dictateButton.trailingAnchor constant:8],
        [self.messageTextField.centerYAnchor constraintEqualToAnchor:self.attachButton.centerYAnchor],
        [self.messageTextField.trailingAnchor constraintEqualToAnchor:self.sendButton.leadingAnchor constant:-8],
        [self.sendButton.trailingAnchor constraintEqualToAnchor:self.inputContainer.trailingAnchor constant:-12],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:self.messageTextField.centerYAnchor],
        [self.inputContainer.bottomAnchor constraintEqualToAnchor:self.messageTextField.bottomAnchor constant:12],
    ]];
}

- (UIButton *)_iconButton:(NSString *)sfSymbol tint:(nullable UIColor *)tint action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:sfSymbol] forState:UIControlStateNormal];
    if (tint) [b setTintColor:tint];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder]; return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Web Search Toggle
// ─────────────────────────────────────────────────────────────────────────────

- (void)toggleWebSearch {
    self.webSearchEnabled = !self.webSearchEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.webSearchEnabled forKey:@"webSearchEnabled"];
    [self updateWebSearchButtonTint];
    [self appendToChat:[NSString stringWithFormat:@"[System: Web Search %@]",
                        self.webSearchEnabled ? @"ON 🌐" : @"OFF"]];
    EZLogf(EZLogLevelInfo, @"WEBSEARCH", @"Toggled %@", self.webSearchEnabled ? @"ON" : @"OFF");
}

- (void)updateWebSearchButtonTint {
    [self.webSearchButton setTintColor:self.webSearchEnabled
        ? [UIColor systemGreenColor] : [UIColor systemGrayColor]];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat History
// ─────────────────────────────────────────────────────────────────────────────

- (void)openHistory {
    ChatHistoryViewController *vc = [[ChatHistoryViewController alloc] initWithStyle:UITableViewStylePlain];
    vc.delegate = self;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Attach Menu
// ─────────────────────────────────────────────────────────────────────────────

- (void)showAttachMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Attach File"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"🎙 Transcribe Audio/Video (Whisper)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        [self presentFilePickerForMode:EZAttachModeWhisper];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"📄 Analyze PDF / ePub / Text"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        [self presentFilePickerForMode:EZAttachModeAnalyze];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"🖼 Attach Image (Vision / Edit)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
        p.delegate    = self;
        p.view.tag    = (NSInteger)EZAttachModeAnalyze;
        [self presentViewController:p animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentFilePickerForMode:(EZAttachMode)mode {
    NSArray *types;
    if (mode == EZAttachModeWhisper) {
        types = @[UTTypeAudio, UTTypeVideo, UTTypeMovie, UTTypeAudiovisualContent];
    } else {
        types = @[UTTypePDF,
                  [UTType typeWithIdentifier:@"org.idpf.epub-container"],
                  UTTypePlainText, UTTypeRTF, UTTypeHTML,
                  UTTypeImage, UTTypeData];
    }
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.view.tag = (NSInteger)mode;
    [self presentViewController:picker animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Document Picker Delegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *fileURL = urls.firstObject;
    if (!fileURL) return;
    EZAttachMode mode = (EZAttachMode)controller.view.tag;
    NSString *ext = fileURL.pathExtension.lowercaseString;
    BOOL isImage = [@[@"jpg",@"jpeg",@"png",@"gif",@"webp",@"heic"] containsObject:ext];

    if (mode == EZAttachModeWhisper) {
        [self transcribeAudio:fileURL];
    } else if (isImage) {
        [self attachImage:fileURL];
    } else {
        [self analyzeFile:fileURL];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Attachment
// ─────────────────────────────────────────────────────────────────────────────

- (void)attachImage:(NSURL *)fileURL {
    NSData *imgData = [NSData dataWithContentsOfURL:fileURL];
    if (!imgData) {
        [self appendToChat:@"[Error: Could not read image]"]; return;
    }

    // Save to EZAttachments for persistence
    NSString *localPath = EZAttachmentSave(imgData, fileURL.lastPathComponent);
    self.pendingImagePath = localPath ?: fileURL.path;

    // Track in active thread
    if (localPath) {
        NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
        [att addObject:localPath];
        self.activeThread.attachmentPaths = [att copy];
    }

    NSString *name = fileURL.lastPathComponent;
    NSString *ext  = fileURL.pathExtension.lowercaseString;

    // Determine what mode this image will be used for
    BOOL inDalleMode = [self.selectedModel isEqualToString:@"dall-e-3"];
    if (inDalleMode) {
        // Auto-switch to dall-e-2 edit mode and inform user
        [self appendToChat:[NSString stringWithFormat:
            @"[System: Image %@ attached. Model switched to DALL-E 2 image edit. "
            @"Type a prompt to edit this image.]", name]];
        self.selectedModel = @"dall-e-2-edit";
        [self.modelButton setTitle:@"Model: dall-e-2 (edit)" forState:UIControlStateNormal];
    } else {
        // Auto-switch to gpt-4o for vision if not already a vision-capable model
        NSArray *visionModels = @[@"gpt-4o",@"gpt-4o-mini",@"gpt-4-turbo",@"gpt-4",
                                  @"gpt-5",@"gpt-5-mini",@"gpt-5-pro"];
        if (![visionModels containsObject:self.selectedModel]) {
            NSString *prev = self.selectedModel;
            self.selectedModel = @"gpt-4o";
            [self.modelButton setTitle:@"Model: gpt-4o" forState:UIControlStateNormal];
            [self appendToChat:[NSString stringWithFormat:
                @"[System: Image attached — switching from %@ to gpt-4o for vision. "
                @"Type a prompt or ask me to describe/analyze it.]", prev]];
        } else {
            [self appendToChat:[NSString stringWithFormat:
                @"[System: Image %@ attached. Type a prompt to analyze or describe it.]", name]];
        }
        // Build vision message and add to context
        NSDictionary *mimeMap = @{@"jpg":@"image/jpeg",@"jpeg":@"image/jpeg",@"png":@"image/png",
                                  @"gif":@"image/gif",@"webp":@"image/webp",@"heic":@"image/heic"};
        NSString *mime    = mimeMap[ext] ?: @"image/jpeg";
        NSString *base64  = [imgData base64EncodedStringWithOptions:0];
        NSString *dataURL = [NSString stringWithFormat:@"data:%@;base64,%@", mime, base64];
        NSDictionary *visionMsg = @{
            @"role": @"user",
            @"content": @[
                @{@"type": @"image_url", @"image_url": @{@"url": dataURL}},
                @{@"type": @"text", @"text": @"User attached this image. Await their question."}
            ]
        };
        [self.chatContext addObject:visionMsg];
    }
    EZLogf(EZLogLevelInfo, @"ATTACH", @"Image attached: %@ path=%@", name, self.pendingImagePath);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - File Analysis (PDF / ePub / text)
// ─────────────────────────────────────────────────────────────────────────────

- (void)analyzeFile:(NSURL *)fileURL {
    NSString *ext  = fileURL.pathExtension.lowercaseString;
    NSString *name = fileURL.lastPathComponent;
    EZLogf(EZLogLevelInfo, @"FILE", @"Analyzing: %@", name);
    [self appendToChat:[NSString stringWithFormat:@"[System: Reading %@...]", name]];

    // Save a copy for persistence
    NSData *fileData = [NSData dataWithContentsOfURL:fileURL];
    if (fileData) {
        NSString *savedPath = EZAttachmentSave(fileData, name);
        if (savedPath) {
            NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
            [att addObject:savedPath];
            self.activeThread.attachmentPaths = [att copy];
        }
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *extractedText = nil;
        if ([ext isEqualToString:@"pdf"]) {
            extractedText = [self extractTextFromPDF:fileURL];
        } else if ([ext isEqualToString:@"epub"]) {
            extractedText = [self extractTextFromEPUB:fileURL];
        } else {
            extractedText = [NSString stringWithContentsOfURL:fileURL
                                                     encoding:NSUTF8StringEncoding error:nil]
                         ?: [NSString stringWithContentsOfURL:fileURL
                                                     encoding:NSISOLatin1StringEncoding error:nil];
        }
        if (!extractedText.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[Error: Could not extract text from file]"];
            });
            return;
        }
        if (extractedText.length > 12000) {
            extractedText = [[extractedText substringToIndex:12000]
                             stringByAppendingString:@"\n[...truncated...]"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.pendingFileContext = extractedText;
            self.pendingFileName    = name;
            [self appendToChat:[NSString stringWithFormat:
                @"[System: %@ ready (%lu chars). Ask me anything about it.]",
                name, (unsigned long)extractedText.length]];
            EZLogf(EZLogLevelInfo, @"FILE", @"Context ready: %@ (%lu chars)",
                   name, (unsigned long)extractedText.length);
        });
    });
}

- (NSString *)extractTextFromPDF:(NSURL *)url {
    PDFDocument *doc = [[PDFDocument alloc] initWithURL:url];
    if (!doc) return nil;
    NSMutableString *text = [NSMutableString string];
    for (NSInteger i = 0; i < doc.pageCount; i++) {
        NSString *pg = [[doc pageAtIndex:i] string];
        if (pg) [text appendFormat:@"%@\n", pg];
    }
    return text;
}

- (NSString *)extractTextFromEPUB:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                 ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!raw) return @"[Could not decode ePub]";
    NSMutableString *stripped = [NSMutableString string];
    BOOL inTag = NO;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c == '<')      { inTag = YES; continue; }
        if (c == '>')      { inTag = NO; [stripped appendString:@" "]; continue; }
        if (!inTag)        [stripped appendFormat:@"%C", c];
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\s{3,}"
                                                                        options:0 error:nil];
    return [re stringByReplacingMatchesInString:stripped options:0
                                          range:NSMakeRange(0, stripped.length)
                                   withTemplate:@"\n\n"];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - TTS
// ─────────────────────────────────────────────────────────────────────────────

- (void)speakLastResponse {
    if (!self.lastAIResponse) return;
    NSUserDefaults *d  = [NSUserDefaults standardUserDefaults];
    NSString *elKey    = [d stringForKey:@"elevenKey"];
    NSString *elVoice  = [d stringForKey:@"elevenVoiceID"];
    if (elKey.length > 0 && elVoice.length > 0) {
        [self speakWithElevenLabs:self.lastAIResponse key:elKey voiceID:elVoice];
    } else {
        [self speakWithApple:self.lastAIResponse];
    }
}

- (void)speakWithApple:(NSString *)text {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                            mode:AVAudioSessionModeDefault
                                         options:AVAudioSessionCategoryOptionDuckOthers error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    if (self.speechSynthesizer.isSpeaking)
        [self.speechSynthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
    u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    u.rate  = AVSpeechUtteranceDefaultSpeechRate;
    [self.speechSynthesizer speakUtterance:u];
}

- (void)speakWithElevenLabs:(NSString *)text key:(NSString *)key voiceID:(NSString *)voiceID {
    EZLogf(EZLogLevelInfo, @"TTS", @"ElevenLabs voiceID=%@", voiceID);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://api.elevenlabs.io/v1/text-to-speech/%@", voiceID]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:key forHTTPHeaderField:@"xi-api-key"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"text": text, @"model_id": @"eleven_turbo_v2_5",
        @"voice_settings": @{@"stability": @0.5, @"similarity_boost": @0.5}
    } options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self speakWithApple:text]; });
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200) {
            NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            EZLogf(EZLogLevelError, @"TTS", @"ElevenLabs %ld: %@", (long)http.statusCode, body);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:[NSString stringWithFormat:
                    @"[ElevenLabs HTTP %ld — falling back to Apple TTS]", (long)http.statusCode]];
                [self speakWithApple:text];
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                                    mode:AVAudioSessionModeDefault
                                                 options:0 error:nil];
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
            NSError *playerErr;
            self.audioPlayer = [[AVAudioPlayer alloc] initWithData:data error:&playerErr];
            if (playerErr) { [self speakWithApple:text]; return; }
            [self.audioPlayer prepareToPlay];
            [self.audioPlayer play];
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - handleSend
// ─────────────────────────────────────────────────────────────────────────────

- (void)handleSend {
    NSString *text = self.messageTextField.text;
    if (text.length == 0) return;
    if (self.isDictating) [self stopDictation];

    self.lastUserPrompt = text;

    // Inject pending file context
    NSString *fullPrompt = text;
    if (self.pendingFileContext.length > 0) {
        fullPrompt = [NSString stringWithFormat:
            @"[Attached file: %@]\n\n%@\n\n[User question]: %@",
            self.pendingFileName, self.pendingFileContext, text];
        self.pendingFileContext = nil;
        self.pendingFileName    = nil;
        [self appendToChat:@"[System: File context injected ✓]"];
    }

    [self appendToChat:[NSString stringWithFormat:@"You: %@", text]];
    [self.chatContext addObject:@{@"role": @"user", @"content": fullPrompt}];
    self.messageTextField.text = @"";
    [self.view endEditing:YES];

    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"apiKey"];
    if (!apiKey.length) { [self appendToChat:@"[Error: No API Key]"]; return; }

    // ── DALL-E image edit (image attached while in dall-e mode) ──────────────
    if ([self.selectedModel isEqualToString:@"dall-e-2-edit"]) {
        [self callImageEdit:text imagePath:self.pendingImagePath ?: self.lastImageLocalPath];
        self.pendingImagePath = nil;
        return;
    }

    // ── DALL-E 3 generation ───────────────────────────────────────────────────
    if ([self.selectedModel isEqualToString:@"dall-e-3"]) {
        if (self.lastImagePrompt.length > 0) {
            // Has prior image — check if follow-up needs context
            NSString *memories = loadMemoryContext(15);
            self.sendButton.enabled = NO;
            analyzePromptForContext(text, memories, apiKey, self.activeThread.threadID,
            ^(EZContextResult *result) {
                self.sendButton.enabled = YES;
                NSString *finalPrompt = text;
                if (result.tier >= EZRoutingTierMemory) {
                    finalPrompt = [NSString stringWithFormat:
                        @"Previous image prompt was: \"%@\". Now create: %@",
                        self.lastImagePrompt, text];
                    [self appendToChat:@"[System: Previous image context included ✓]"];
                }
                [self callDalle3:finalPrompt];
            });
        } else {
            [self callDalle3:text];
        }
        return;
    }

    // ── Sora ─────────────────────────────────────────────────────────────────
    if ([self.selectedModel hasPrefix:@"sora-"]) {
        [self callSora:fullPrompt];
        return;
    }

    // ── Chat / reasoning models ───────────────────────────────────────────────
    NSString *memories = loadMemoryContext(15);
    self.sendButton.enabled = NO;

    analyzePromptForContext(text, memories, apiKey, self.activeThread.threadID,
    ^(EZContextResult *result) {
        self.sendButton.enabled = YES;
        EZLogf(EZLogLevelInfo, @"SEND",
               @"Tier %ld — conf=%.2f tokens≈%ld reason: %@",
               (long)result.tier, result.confidence,
               (long)result.estimatedTokens, result.reason);

        // Tier 1: helper answered directly
        if (result.tier == EZRoutingTierDirect && result.shortCircuitAnswer.length > 0) {
            NSString *answer = result.shortCircuitAnswer;
            self.lastAIResponse = answer;
            [self.chatContext addObject:@{@"role": @"assistant", @"content": answer}];
            [self appendToChat:[NSString stringWithFormat:@"AI: %@", answer]];
            [self appendToChat:@"[System: Answered directly by helper model ⚡]"];
            EZLogf(EZLogLevelInfo, @"SEND", @"Tier 1 direct answer displayed");
            // Still save a memory entry
            createMemoryFromCompletion(text, answer, apiKey, self.activeThread.threadID,
                                       ^(NSString *entry) {
                if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved: %lu chars",
                                  (unsigned long)entry.length);
            });
            [self saveActiveThread];
            return;
        }

        // Tiers 2-4: build the final context and call the main model

        // Tier 4: prepend injected history turns before the enriched prompt
        if (result.tier == EZRoutingTierFullChat && result.injectedHistory.count > 0) {
            // Remove the last chatContext entry (bare user message)
            if (self.chatContext.count > 0) [self.chatContext removeLastObject];
            // Prepend the history turns
            NSMutableArray *rebuilt = [NSMutableArray array];
            [rebuilt addObjectsFromArray:result.injectedHistory];
            [rebuilt addObjectsFromArray:self.chatContext];
            [rebuilt addObject:@{@"role": @"user", @"content": result.finalPrompt}];
            self.chatContext = rebuilt;
            [self appendToChat:@"[System: Full chat history injected ✓]"];
        } else if (result.tier >= EZRoutingTierMemory) {
            // Tier 3: replace last message with enriched prompt
            if (self.chatContext.count > 0) [self.chatContext removeLastObject];
            [self.chatContext addObject:@{@"role": @"user", @"content": result.finalPrompt}];
            [self appendToChat:@"[System: Memory context included ✓]"];
        }

        [self callChatCompletions];
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat Completions / Responses API
// ─────────────────────────────────────────────────────────────────────────────

- (void)callChatCompletions {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *apiKey = [defaults stringForKey:@"apiKey"];
    if (!apiKey) { [self appendToChat:@"[Error: No API Key]"]; return; }

    BOOL isGPT5          = [self.selectedModel hasPrefix:@"gpt-5"];
    BOOL useWebSearch    = self.webSearchEnabled;
    BOOL useResponsesAPI = isGPT5 || useWebSearch;

    NSString *endpointStr = useResponsesAPI
        ? @"https://api.openai.com/v1/responses"
        : @"https://api.openai.com/v1/chat/completions";

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:endpointStr]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
   forHTTPHeaderField:@"Authorization"];

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"model"] = self.selectedModel;
    NSString *sys  = [defaults stringForKey:@"systemMessage"];

    if (useResponsesAPI) {
        if (sys.length > 0) body[@"instructions"] = sys;
        body[@"input"] = self.chatContext;
        if (useWebSearch) {
            NSString *loc = [defaults stringForKey:@"webSearchLocation"] ?: @"";
            NSMutableDictionary *webTool = [@{@"type": @"web_search_preview"} mutableCopy];
            if (loc.length > 0) webTool[@"user_location"] = @{@"type":@"approximate",@"city":loc};
            body[@"tools"] = @[webTool];
            EZLog(EZLogLevelInfo, @"WEBSEARCH", @"Tool attached");
        }
    } else {
        float temp = [defaults floatForKey:@"temperature"];
        body[@"temperature"]       = @(temp > 0 ? temp : 0.7);
        body[@"frequency_penalty"] = @([defaults floatForKey:@"frequency"]);
        NSMutableArray *messages   = [NSMutableArray array];
        if (sys.length > 0) [messages addObject:@{@"role":@"system",@"content":sys}];
        [messages addObjectsFromArray:self.chatContext];
        body[@"messages"] = messages;
    }

    NSError *bodyErr;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyErr];
    if (bodyErr) { [self handleAPIError:@"Failed to build request"]; return; }

    EZLogf(EZLogLevelInfo, @"API", @"→ %@ [%@]%@",
           endpointStr, self.selectedModel, useWebSearch ? @" +web" : @"");

    NSString *capturedPrompt = self.lastUserPrompt;
    NSString *capturedThreadID = self.activeThread.threadID;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { [self handleAPIError:error.localizedDescription]; return; }

        NSError *jsonErr;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr || !jsonObj || [jsonObj isKindOfClass:[NSNull class]]) {
            [self handleAPIError:@"Could not parse API response"]; return;
        }
        NSDictionary *json = jsonObj;

        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id msg = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(msg && ![msg isKindOfClass:[NSNull class]])
                ? (NSString *)msg : @"Unknown API error"];
            return;
        }

        NSString *reply = nil;
        if (useResponsesAPI) {
            id outputObj = json[@"output"];
            if (outputObj && ![outputObj isKindOfClass:[NSNull class]]) {
                for (id item in (NSArray *)outputObj) {
                    if ([item isKindOfClass:[NSNull class]]) continue;
                    NSDictionary *d = item;
                    if (![[d[@"type"] description] isEqualToString:@"message"]) continue;
                    id contentArr = d[@"content"];
                    if (!contentArr || [contentArr isKindOfClass:[NSNull class]]) continue;
                    for (id block in (NSArray *)contentArr) {
                        if ([block isKindOfClass:[NSNull class]]) continue;
                        NSDictionary *b = block;
                        if (![[b[@"type"] description] isEqualToString:@"output_text"]) continue;
                        id t = b[@"text"];
                        if (t && ![t isKindOfClass:[NSNull class]]) { reply = (NSString *)t; break; }
                    }
                    if (reply) break;
                }
            }
        } else {
            id choicesObj = json[@"choices"];
            if (choicesObj && ![choicesObj isKindOfClass:[NSNull class]]
                && [(NSArray *)choicesObj count] > 0) {
                id first = ((NSArray *)choicesObj)[0];
                if (first && ![first isKindOfClass:[NSNull class]]) {
                    id msgObj = ((NSDictionary *)first)[@"message"];
                    if (msgObj && ![msgObj isKindOfClass:[NSNull class]]) {
                        id c = ((NSDictionary *)msgObj)[@"content"];
                        if (c && ![c isKindOfClass:[NSNull class]]) reply = (NSString *)c;
                    }
                }
            }
        }

        if (!reply.length) {
            EZLogf(EZLogLevelError, @"API", @"No reply. Raw: %@", json);
            [self handleAPIError:@"Unexpected response format"]; return;
        }
        EZLogf(EZLogLevelInfo, @"API", @"Reply %lu chars", (unsigned long)reply.length);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastAIResponse = reply;
            [self.chatContext addObject:@{@"role": @"assistant", @"content": reply}];
            [self appendToChat:[NSString stringWithFormat:@"AI: %@", reply]];
            [self saveActiveThread];
        });

        createMemoryFromCompletion(capturedPrompt ?: @"", reply, apiKey, capturedThreadID,
        ^(NSString *entry) {
            if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved %lu chars",
                              (unsigned long)entry.length);
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DALL-E 3 Generation
// ─────────────────────────────────────────────────────────────────────────────

- (void)callDalle3:(NSString *)prompt {
    [self appendToChat:@"[System: Generating Image...]"];
    EZLog(EZLogLevelInfo, @"DALLE", @"Sending DALL-E 3 request");
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"apiKey"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/images/generations"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"model":@"dall-e-3", @"prompt":prompt, @"n":@1, @"size":@"1024x1024"
    } options:0 error:nil];

    NSString *savedPrompt = prompt;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (!data) { [self handleAPIError:error.localizedDescription ?: @"DALL-E failed"]; return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id m = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(m && ![m isKindOfClass:[NSNull class]]) ? m : @"DALL-E error"];
            return;
        }
        id dataArr = json[@"data"];
        if (!dataArr || [dataArr isKindOfClass:[NSNull class]] || [(NSArray *)dataArr count] == 0) {
            [self handleAPIError:@"No image in response"]; return;
        }
        id imgObj = ((NSArray *)dataArr)[0];
        id imgURL = ([imgObj isKindOfClass:[NSDictionary class]]) ? imgObj[@"url"] : nil;
        if (!imgURL || [imgURL isKindOfClass:[NSNull class]]) {
            [self handleAPIError:@"No image URL"]; return;
        }
        EZLog(EZLogLevelInfo, @"DALLE", @"Image URL received");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastImagePrompt = savedPrompt;
        });
        [self downloadAndSaveImage:(NSString *)imgURL purpose:@"dalle"];
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DALL-E 2 Image Edit
// ─────────────────────────────────────────────────────────────────────────────

- (void)callImageEdit:(NSString *)prompt imagePath:(NSString *)imagePath {
    if (!imagePath) {
        [self appendToChat:@"[Error: No image attached for editing]"]; return;
    }
    [self appendToChat:@"[System: Editing image...]"];
    EZLog(EZLogLevelInfo, @"IMGEDIT", @"Sending image edit request");

    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"apiKey"];
    NSData *imageData = [NSData dataWithContentsOfFile:imagePath];
    if (!imageData) {
        // Try as URL path
        imageData = [NSData dataWithContentsOfURL:[NSURL fileURLWithPath:imagePath]];
    }
    if (!imageData) {
        [self appendToChat:@"[Error: Could not read image for editing]"]; return;
    }

    // /v1/images/edits requires PNG — convert if needed
    // We send the raw image data; if it fails the API will return an error we'll surface
    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    NSURL *url = [NSURL URLWithString:@"https://api.openai.com/v1/images/edits"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
        forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
        forHTTPHeaderField:@"Authorization"];

    NSMutableData *body = [NSMutableData data];

    // image field
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"image\"; filename=\"image.png\"\r\n"
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: image/png\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:imageData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // prompt field
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"prompt\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[prompt dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // model field
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"model\"\r\n\r\ndall-e-2\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // n and size
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"n\"\r\n\r\n1\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"size\"\r\n\r\n1024x1024\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    EZLogf(EZLogLevelInfo, @"IMGEDIT", @"Prompt: %@, imageData: %lu bytes",
           prompt, (unsigned long)imageData.length);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (!data) { [self handleAPIError:error.localizedDescription ?: @"Image edit failed"]; return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id m = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(m && ![m isKindOfClass:[NSNull class]]) ? m : @"Image edit error"];
            return;
        }
        id dataArr = json[@"data"];
        if (!dataArr || [dataArr isKindOfClass:[NSNull class]] || [(NSArray *)dataArr count] == 0) {
            [self handleAPIError:@"No image in edit response"]; return;
        }
        id imgObj = ((NSArray *)dataArr)[0];
        id imgURL = ([imgObj isKindOfClass:[NSDictionary class]]) ? imgObj[@"url"] : nil;
        if (!imgURL || [imgURL isKindOfClass:[NSNull class]]) {
            [self handleAPIError:@"No URL in edit response"]; return;
        }
        EZLog(EZLogLevelInfo, @"IMGEDIT", @"Edited image URL received");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastImagePrompt = prompt;
            // Reset back to dall-e-3 after edit completes
            self.selectedModel = @"dall-e-3";
            [self.modelButton setTitle:@"Model: dall-e-3" forState:UIControlStateNormal];
        });
        [self downloadAndSaveImage:(NSString *)imgURL purpose:@"edit"];
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sora Text-to-Video (always async job)
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Sora 2 API spec:
//   sora-2:     "seconds" param as STRING — "4" | "8" | "12" | "16"
//   sora-2-pro: "seconds" param as STRING — "5" | "10" | "15" | "20"
//   "size" param: "480p" | "720p" | "1080p"
// Endpoint: POST /v1/videos  →  async job {id, status:"queued"}
// Poll:     GET  /v1/videos/{id}
// Content:  GET  /v1/videos/{id}/content
// ─────────────────────────────────────────────────────────────────────────────

- (void)callSora:(NSString *)prompt {
    [self appendToChat:@"[System: Submitting Sora 2 video job...]"];
    EZLog(EZLogLevelInfo, @"SORA", @"Sending request");

    NSUserDefaults *d    = [NSUserDefaults standardUserDefaults];
    NSString *apiKey     = [d stringForKey:@"apiKey"];
    NSString *videoModel = [d stringForKey:@"soraModel"] ?: @"sora-2";
    NSString *resolution = [d stringForKey:@"soraSize"]  ?: @"720p";
    NSInteger rawDur     = [d integerForKey:@"soraDuration"] ?: 4;

    // Enforce model-specific duration constraints.
    // Both models want the value passed as a STRING, not an integer.
    NSString *secondsStr;
    BOOL isPro = [videoModel isEqualToString:@"sora-2-pro"];
    if (isPro) {
        // sora-2-pro: "5" | "10" | "15" | "20"
        NSArray<NSNumber *> *valid = @[@5, @10, @15, @20];
        NSInteger best = 5, bestDiff = NSIntegerMax;
        for (NSNumber *v in valid) {
            NSInteger diff = ABS(rawDur - v.integerValue);
            if (diff < bestDiff) { bestDiff = diff; best = v.integerValue; }
        }
        secondsStr = [NSString stringWithFormat:@"%ld", (long)best];
    } else {
        // sora-2: "4" | "8" | "12" | "16"
        NSArray<NSNumber *> *valid = @[@4, @8, @12, @16];
        NSInteger best = 4, bestDiff = NSIntegerMax;
        for (NSNumber *v in valid) {
            NSInteger diff = ABS(rawDur - v.integerValue);
            if (diff < bestDiff) { bestDiff = diff; best = v.integerValue; }
        }
        secondsStr = [NSString stringWithFormat:@"%ld", (long)best];
    }

    // Validate size — API accepts pixel dimension strings, not "480p" etc.
    // Supported: "720x1280" (portrait), "1280x720" (landscape),
    //            "1024x1792" (portrait tall), "1792x1024" (landscape wide)
    NSArray<NSString *> *validRes = @[@"1280x720", @"720x1280", @"1024x1792", @"1792x1024"];
    if (![validRes containsObject:resolution]) {
        // Map friendly names and old values to correct strings
        NSDictionary *resMap = @{
            @"480p":   @"1280x720",
            @"720p":   @"1280x720",
            @"1080p":  @"1792x1024",
            @"portrait": @"720x1280",
            @"landscape": @"1280x720",
            @"480x270":  @"1280x720",
            @"1280x720": @"1280x720",
            @"1920x1080":@"1792x1024"
        };
        resolution = resMap[resolution] ?: @"1280x720";
    }

    if (rawDur != secondsStr.integerValue) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:[NSString stringWithFormat:
                @"[System: Duration snapped to %@s (valid for %@)]",
                secondsStr, videoModel]];
        });
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/videos"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    NSError *bodyErr;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"model":   videoModel,
        @"prompt":  prompt,
        @"size":    resolution,   // "size" not "resolution"
        @"seconds": secondsStr    // "seconds" as STRING not integer
    } options:0 error:&bodyErr];
    if (bodyErr) { [self handleAPIError:@"Failed to build Sora request"]; return; }

    EZLogf(EZLogLevelInfo, @"SORA", @"model=%@ size=%@ seconds=%@", videoModel, resolution, secondsStr);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { [self handleAPIError:error.localizedDescription]; return; }

        // Always log raw body — helps diagnose API changes
        NSString *rawBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"(unreadable)";
        EZLogf(EZLogLevelDebug, @"SORA", @"Raw response: %@", rawBody);

        NSError *parseErr;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (parseErr || !jsonObj || [jsonObj isKindOfClass:[NSNull class]]) {
            EZLogf(EZLogLevelError, @"SORA", @"Parse failed. Raw: %@", rawBody);
            [self handleAPIError:@"Could not parse Sora response — check log"]; return;
        }
        NSDictionary *json = jsonObj;
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id m = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(m && ![m isKindOfClass:[NSNull class]]) ? m : @"Sora error"];
            return;
        }

        // Extract job ID — Sora 2 returns top-level "id"
        NSString *jobId = nil;
        id topId = json[@"id"];
        if (topId && ![topId isKindOfClass:[NSNull class]]) jobId = (NSString *)topId;

        if (!jobId.length) {
            EZLogf(EZLogLevelError, @"SORA", @"No job ID. Full response: %@", json);
            [self handleAPIError:@"Sora returned no job ID — check log"]; return;
        }

        EZLogf(EZLogLevelInfo, @"SORA", @"Job created: %@  status: %@", jobId, json[@"status"] ?: @"?");

        // Persist job ID so we can resume polling if app backgrounds
        [[NSUserDefaults standardUserDefaults] setObject:jobId forKey:@"soraActivejobId"];
        [[NSUserDefaults standardUserDefaults] setObject:apiKey forKey:@"soraActiveApiKey"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:[NSString stringWithFormat:
                @"[Sora: Job queued (%@) — polling for completion...]", jobId]];
        });
        [self pollSoraJob:jobId apiKey:apiKey];
    }] resume];
}

- (void)pollSoraJob:(NSString *)jobId apiKey:(NSString *)apiKey {
    __block NSInteger attempts = 0;
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    // Weak/strong block dance to avoid retain cycle
    __block __weak void (^weakPoll)(void);
    void (^poll)(void);
    poll = ^{
        void (^strongPoll)(void) = weakPoll;
        if (!strongPoll) return;
        attempts++;
        // sora-2-pro can take up to ~5 min, sora-2 typically under 2 min
        // Poll up to 36 times: first 6 every 5s, then every 10s = ~5.5 min total
        if (attempts > 36) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[Sora: Generation is taking unusually long. "
                 "Check platform.openai.com/storage for your video.]"];
            });
            return;
        }
        NSTimeInterval delay = (attempts <= 6) ? 5.0 : 10.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), q, ^{
            // GET /v1/videos/{id}
            NSString *pollURL = [NSString stringWithFormat:@"https://api.openai.com/v1/videos/%@", jobId];
            NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:pollURL]];
            r.HTTPMethod = @"GET";
            [r setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

            [[[NSURLSession sharedSession] dataTaskWithRequest:r
                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                void (^s)(void) = weakPoll;
                if (!data || err) { if (s) s(); return; }

                id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (!j || [j isKindOfClass:[NSNull class]]) { if (s) s(); return; }
                NSDictionary *jd = j;
                NSString *status = jd[@"status"] ?: @"";
                EZLogf(EZLogLevelInfo, @"SORA", @"Poll %ld — status: %@", (long)attempts, status);

                // Show status changes in chat so user knows it's alive
                static NSString *lastShownStatus = nil;
                if (![status isEqualToString:lastShownStatus]) {
                    lastShownStatus = [status copy];
                    NSString *emoji = [status isEqualToString:@"queued"]     ? @"⏳" :
                                      [status isEqualToString:@"processing"] ? @"⚙️" :
                                      ([status isEqualToString:@"completed"] ||
                                       [status isEqualToString:@"succeeded"] ||
                                       [status isEqualToString:@"ready"])    ? @"✅" :
                                      ([status isEqualToString:@"failed"] ||
                                       [status isEqualToString:@"error"])    ? @"❌" : @"🔄";
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self appendToChat:[NSString stringWithFormat:@"[Sora: %@ %@]", emoji, status]];
                    });
                }

                // Terminal failure states
                if ([status isEqualToString:@"failed"] || [status isEqualToString:@"error"]) {
                    id errDetail = jd[@"error"];
                    NSString *msg = (errDetail && ![errDetail isKindOfClass:[NSNull class]])
                        ? [errDetail description] : @"Video generation failed";
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"soraActivejobId"];
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"soraActiveApiKey"];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self appendToChat:[NSString stringWithFormat:@"[Sora failed: %@]", msg]];
                    });
                    return;
                }

                // Success — fetch content via /v1/videos/{id}/content
                BOOL done = ([status isEqualToString:@"completed"] ||
                             [status isEqualToString:@"succeeded"] ||
                             [status isEqualToString:@"ready"]);
                if (done) {
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"soraActivejobId"];
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"soraActiveApiKey"];
                    EZLogf(EZLogLevelInfo, @"SORA", @"Job complete — fetching content");
                    [self fetchSoraContent:jobId apiKey:apiKey];
                    return;
                }

                // Still processing — keep polling
                if (s) s();
            }] resume];
        });
    };
    weakPoll = poll;
    poll();
}

/// Called from applicationDidBecomeActive — resumes polling if a job was in flight when app backgrounded
- (void)resumePendingSoraJobIfNeeded {
    // Guard: don't run before the view is fully set up
    if (!self.isViewLoaded || !self.view.window) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *jobId   = [d stringForKey:@"soraActivejobId"];
    NSString *apiKey  = [d stringForKey:@"soraActiveApiKey"];
    if (!jobId.length || !apiKey.length) return;
    EZLogf(EZLogLevelInfo, @"SORA", @"Resuming poll for job: %@", jobId);
    [self appendToChat:[NSString stringWithFormat:
        @"[Sora: Resuming poll for job %@...]", jobId]];
    [self pollSoraJob:jobId apiKey:apiKey];
}

/// GET /v1/videos/{id}/content — follows redirect to actual mp4 URL
- (void)fetchSoraContent:(NSString *)jobId apiKey:(NSString *)apiKey {
    NSString *contentURL = [NSString stringWithFormat:
        @"https://api.openai.com/v1/videos/%@/content", jobId];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:contentURL]];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    // Use a session configured to follow redirects (default NSURLSession does follow them)
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { [self handleAPIError:error.localizedDescription]; return; }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        EZLogf(EZLogLevelInfo, @"SORA", @"Content fetch HTTP %ld, %lu bytes",
               (long)http.statusCode, (unsigned long)data.length);

        // If we got redirected to the actual video and the data is large enough to be a video
        if (http.statusCode == 200 && data.length > 10000) {
            // Save directly — no need to download again
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *savedPath = EZAttachmentSave(data, @"sora_video.mp4");
                NSURL *tmp = [NSURL fileURLWithPath:
                    [NSTemporaryDirectory() stringByAppendingPathComponent:@"sora_gen.mp4"]];
                [data writeToURL:tmp atomically:YES];
                if (savedPath) {
                    self.activeThread.lastVideoLocalPath = savedPath;
                    [self saveActiveThread];
                }
                self.previewURL = tmp;
                QLPreviewController *ql = [[QLPreviewController alloc] init];
                ql.dataSource = self;
                [self presentViewController:ql animated:YES completion:nil];
                [self appendToChat:@"[Sora: Video ready ✓]"];
                EZLog(EZLogLevelInfo, @"SORA", @"Video saved and presented");
            });
            return;
        }

        // If response is JSON, it might contain a download URL
        NSError *parseErr;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (!parseErr && jsonObj && ![jsonObj isKindOfClass:[NSNull class]]) {
            NSDictionary *json = jsonObj;
            EZLogf(EZLogLevelDebug, @"SORA", @"Content JSON: %@", json);
            // Look for a URL field
            id urlObj = json[@"url"] ?: json[@"download_url"] ?: json[@"video_url"];
            if (urlObj && ![urlObj isKindOfClass:[NSNull class]]) {
                [self downloadAndShowVideo:(NSString *)urlObj]; return;
            }
        }

        // Last resort: use the final response URL (after redirect) as the download source
        NSURL *finalURL = response.URL;
        if (finalURL && ![finalURL.absoluteString containsString:@"/content"]) {
            EZLogf(EZLogLevelInfo, @"SORA", @"Following redirect to: %@", finalURL);
            [self downloadAndShowVideo:finalURL.absoluteString]; return;
        }

        [self handleAPIError:@"Could not retrieve Sora video content"];
        EZLogf(EZLogLevelError, @"SORA", @"Content fetch failed. HTTP %ld body: %@",
               (long)http.statusCode,
               [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"?");
    }] resume];
}

- (void)downloadAndShowVideo:(NSString *)urlString {
    EZLog(EZLogLevelInfo, @"SORA", @"Downloading video...");
    [[[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:urlString]
        completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
        if (!location) { [self handleAPIError:@"Video download failed"]; return; }
        NSURL *tmp = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"sora_gen.mp4"]];
        [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:location toURL:tmp error:nil];

        // Also save to EZAttachments for persistence
        NSData *videoData = [NSData dataWithContentsOfURL:tmp];
        if (videoData) {
            NSString *savedPath = EZAttachmentSave(videoData, @"sora_video.mp4");
            if (savedPath) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.activeThread.lastVideoLocalPath = savedPath;
                    [self saveActiveThread];
                });
            }
        }

        EZLog(EZLogLevelInfo, @"SORA", @"Video ready");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.previewURL = tmp;
            QLPreviewController *ql = [[QLPreviewController alloc] init];
            ql.dataSource = self;
            [self presentViewController:ql animated:YES completion:nil];
            [self appendToChat:@"[Sora: Video ready ✓]"];
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Download / Save / QuickLook
// ─────────────────────────────────────────────────────────────────────────────

- (void)downloadAndSaveImage:(NSString *)urlString purpose:(NSString *)purpose {
    [[[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:urlString]
        completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
        if (!location) {
            EZLogf(EZLogLevelError, @"IMAGE", @"Download failed: %@", err.localizedDescription);
            [self handleAPIError:@"Image download failed"]; return;
        }
        // Copy to temp for QuickLook
        NSString *tmpName = [NSString stringWithFormat:@"%@_gen.png", purpose];
        NSURL *tmp = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName]];
        [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:location toURL:tmp error:nil];

        // Save to EZAttachments for persistence
        NSData *imgData = [NSData dataWithContentsOfURL:tmp];
        NSString *savedPath = imgData ? EZAttachmentSave(imgData, tmpName) : nil;

        EZLogf(EZLogLevelInfo, @"IMAGE", @"Image saved: %@", savedPath ?: @"(temp only)");

        dispatch_async(dispatch_get_main_queue(), ^{
            if (savedPath) {
                self.lastImageLocalPath = savedPath;
                self.activeThread.lastImageLocalPath = savedPath;
                NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
                [att addObject:savedPath];
                self.activeThread.attachmentPaths = [att copy];
                [self saveActiveThread];
            }
            self.previewURL = tmp;
            QLPreviewController *ql = [[QLPreviewController alloc] init];
            ql.dataSource = self;
            [self presentViewController:ql animated:YES completion:nil];
        });
    }] resume];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)c { return 1; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)c previewItemAtIndex:(NSInteger)i {
    return self.previewURL;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Whisper
// ─────────────────────────────────────────────────────────────────────────────

- (void)transcribeAudio:(NSURL *)fileURL {
    [self appendToChat:@"[System: Whisper uploading...]"];
    EZLog(EZLogLevelInfo, @"WHISPER", @"Starting transcription");
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"apiKey"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/audio/transcriptions"]];
    req.HTTPMethod = @"POST";
    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
       forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
       forHTTPHeaderField:@"Authorization"];
    NSMutableData *body = [NSMutableData data];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:
        @"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n",
        fileURL.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: audio/mpeg\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[NSData dataWithContentsOfURL:fileURL]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (!data) {
            EZLogf(EZLogLevelError, @"WHISPER", @"Failed: %@", error.localizedDescription); return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *formatted = [self formatWhisperTranscript:json[@"text"]];
        EZLogf(EZLogLevelInfo, @"WHISPER", @"Done (%lu chars)", (unsigned long)formatted.length);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.messageTextField.text = formatted;
            [self appendToChat:[NSString stringWithFormat:@"[Whisper]: %@", formatted]];
        });
    }] resume];
}

- (NSString *)formatWhisperTranscript:(NSString *)raw {
    if (!raw) return @"";
    return [[[raw stringByReplacingOccurrencesOfString:@". " withString:@".\n"]
                  stringByReplacingOccurrencesOfString:@"! " withString:@"!\n"]
                  stringByReplacingOccurrencesOfString:@"? " withString:@"?\n"];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Misc
// ─────────────────────────────────────────────────────────────────────────────

- (void)handleAPIError:(NSString *)msg {
    EZLogf(EZLogLevelError, @"API", @"Error: %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self appendToChat:[NSString stringWithFormat:@"[API Error]: %@", msg]];
    });
}

- (void)keyboardWillChange:(NSNotification *)notification {
    CGRect kbFrame  = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    double duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    BOOL isHiding   = [notification.name isEqualToString:UIKeyboardWillHideNotification];
    self.containerBottomConstraint.constant = isHiding
        ? 0 : -(kbFrame.size.height - self.view.safeAreaInsets.bottom);
    [UIView animateWithDuration:duration animations:^{ [self.view layoutIfNeeded]; }];
}

- (void)setupKeyboardObservers {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification       object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification       object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
}

/// Green + button — save current thread and start a fresh one, no confirmation needed
- (void)newChat {
    [self saveActiveThread];
    [self _resetConversation];
    [self appendToChat:@"[System: New chat started ✓]"];
    EZLog(EZLogLevelInfo, @"APP", @"New chat started by user");
}

/// Red trash button — confirm delete, then start fresh (deleted thread is gone)
- (void)deleteCurrentChat {
    if (self.chatContext.count == 0) return; // nothing to delete
    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Delete This Chat?"
                         message:@"This conversation will be permanently deleted."
                  preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
        // Delete from disk if it was ever saved
        if (self.activeThread.threadID.length > 0) {
            EZThreadDelete(self.activeThread.threadID);
        }
        [self _resetConversation];
        [self appendToChat:@"[System: Chat deleted]"];
        EZLog(EZLogLevelInfo, @"APP", @"Chat deleted by user");
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

/// Internal reset — clears state and starts a new thread (does NOT save or delete)
- (void)_resetConversation {
    [self.chatContext removeAllObjects];
    self.chatHistoryView.text  = @"";
    self.lastAIResponse        = nil;
    self.lastUserPrompt        = nil;
    self.lastImagePrompt       = nil;
    self.lastImageLocalPath    = nil;
    self.pendingFileContext    = nil;
    self.pendingFileName       = nil;
    self.pendingImagePath      = nil;
    [self startNewThread];
}

/// Legacy — kept so any internal callers still work
- (void)clearConversation {
    [self saveActiveThread];
    [self _resetConversation];
    EZLog(EZLogLevelInfo, @"APP", @"Conversation cleared — new thread started");
}

- (void)copyLastResponse {
    if (self.lastAIResponse) {
        [UIPasteboard generalPasteboard].string = self.lastAIResponse;
        EZLog(EZLogLevelInfo, @"APP", @"Last response copied to clipboard");
    }
}

- (void)showModelPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Model"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *model in self.models) {
        [alert addAction:[UIAlertAction actionWithTitle:model
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            self.selectedModel = model;
            [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", model]
                              forState:UIControlStateNormal];
            [[NSUserDefaults standardUserDefaults] setObject:model forKey:@"selectedModel"];
            EZLogf(EZLogLevelInfo, @"APP", @"Model → %@", model);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)appendToChat:(NSString *)text {
    self.chatHistoryView.text = [self.chatHistoryView.text stringByAppendingFormat:@"\n\n%@", text];
    NSUInteger len = self.chatHistoryView.text.length;
    if (len > 0) [self.chatHistoryView scrollRangeToVisible:NSMakeRange(len - 1, 1)];
}

- (void)openSettings {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[SettingsViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - SettingsViewController
// ─────────────────────────────────────────────────────────────────────────────

@interface SettingsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextField  *apiKeyField, *systemMsgField;
@property (nonatomic, strong) UISlider     *tempSlider, *freqSlider;
@property (nonatomic, strong) UILabel      *tempLabel, *freqLabel;
@property (nonatomic, strong) UITextField  *elKeyField, *elVoiceField;
@property (nonatomic, strong) UITextField  *webLocationField;
@property (nonatomic, strong) UISwitch     *webSearchSwitch;
@property (nonatomic, strong) UITextField  *soraModelField, *soraSizeField;
@property (nonatomic, strong) UISlider     *soraDurationSlider;
@property (nonatomic, strong) UILabel      *soraDurationLabel;
@end

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(saveAndClose)];
    [self setupUI];
    [self loadSettings];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(keyboardShow:) name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardHide:) name:UIKeyboardWillHideNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardShow:) name:UIKeyboardWillChangeFrameNotification object:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)keyboardShow:(NSNotification *)n {
    CGRect f = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIEdgeInsets i = UIEdgeInsetsMake(0, 0, f.size.height, 0);
    self.scrollView.contentInset = self.scrollView.scrollIndicatorInsets = i;
}
- (void)keyboardHide:(NSNotification *)n {
    self.scrollView.contentInset = self.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scrollView];
    CGFloat w = self.view.frame.size.width - 40;
    CGFloat y = 20;

    [self addSection:@"🤖 OpenAI" y:&y];
    [self addLabel:@"API Key:" y:&y];
    self.apiKeyField = [self addField:w y:&y placeholder:@"sk-..."];
    [self addLabel:@"System Message:" y:&y];
    self.systemMsgField = [self addField:w y:&y placeholder:@"e.g. You are a helpful assistant"];
    self.tempLabel = [self addLabel:@"Temperature: 0.70" y:&y];
    self.tempSlider = [self addSlider:w y:&y min:0 max:2];
    self.freqLabel = [self addLabel:@"Freq Penalty: 0.00" y:&y];
    self.freqSlider = [self addSlider:w y:&y min:-2 max:2];

    [self addSection:@"🌐 Web Search" y:&y];
    [self addLabel:@"Enable web search by default:" y:&y];
    self.webSearchSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 30, y - 28, 51, 31)];
    [self.scrollView addSubview:self.webSearchSwitch];
    [self addLabel:@"Location hint (optional city):" y:&y];
    self.webLocationField = [self addField:w y:&y placeholder:@"e.g. Miami, FL"];

    [self addSection:@"🎙 ElevenLabs TTS" y:&y];
    [self addLabel:@"API Key:" y:&y];
    self.elKeyField = [self addField:w y:&y placeholder:@"ElevenLabs API key"];
    [self addLabel:@"Voice ID:" y:&y];
    self.elVoiceField = [self addField:w - 95 y:&y placeholder:@"Voice ID"];
    UIButton *getVoices = [UIButton buttonWithType:UIButtonTypeSystem];
    getVoices.frame = CGRectMake(w - 74, y - 50, 84, 40);
    [getVoices setTitle:@"Get Voices" forState:UIControlStateNormal];
    [getVoices addTarget:self action:@selector(fetchVoices) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:getVoices];

    [self addSection:@"🎬 Sora Text-to-Video" y:&y];

    // Model picker — tap to choose sora-2 or sora-2-pro
    [self addLabel:@"Model:" y:&y];
    self.soraModelField = [self addField:w y:&y placeholder:@"sora-2"];
    // Make it read-only and tap to pick
    self.soraModelField.userInteractionEnabled = NO;
    UIButton *soraModelPicker = [UIButton buttonWithType:UIButtonTypeSystem];
    soraModelPicker.frame = CGRectMake(w - 74, y - 50, 84, 40);
    [soraModelPicker setTitle:@"Choose" forState:UIControlStateNormal];
    [soraModelPicker addTarget:self action:@selector(pickSoraModel)
              forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:soraModelPicker];

    // Resolution — tap to choose
    [self addLabel:@"Resolution: (480p / 720p / 1080p)" y:&y];
    self.soraSizeField = [self addField:w y:&y placeholder:@"1280x720"];
    self.soraSizeField.userInteractionEnabled = NO;
    UIButton *soraResPicker = [UIButton buttonWithType:UIButtonTypeSystem];
    soraResPicker.frame = CGRectMake(w - 74, y - 50, 84, 40);
    [soraResPicker setTitle:@"Choose" forState:UIControlStateNormal];
    [soraResPicker addTarget:self action:@selector(pickSoraResolution)
            forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:soraResPicker];

    // Duration — sora-2-pro max is 10s, sora-2 max is 20s.
    // Slider goes 1-20; callSora clamps to valid value for chosen model.
    self.soraDurationLabel = [self addLabel:@"Duration: 4s  (sora-2: 4/8/12/16s  •  sora-2-pro: 5/10/15/20s)" y:&y];
    self.soraDurationSlider = [self addSlider:w y:&y min:1 max:20];
    [self.soraDurationSlider addTarget:self action:@selector(updateVideoLabels)
                      forControlEvents:UIControlEventValueChanged];

    [self addSection:@"🧠 AI Memory" y:&y];
    y += 8;
    [self addButton:@"Clear All Memories" color:[UIColor systemOrangeColor]
            action:@selector(confirmClearMemories) y:&y w:w];
    [self addButton:@"View Helper Stats" color:[UIColor systemIndigoColor]
            action:@selector(showHelperStats) y:&y w:w];
    [self addButton:@"💙 Donate via PayPal" color:[UIColor systemBlueColor]
            action:@selector(donate) y:&y w:w];

    self.scrollView.contentSize = CGSizeMake(self.view.frame.size.width, y + 30);
}

// ─── Settings UI helpers ──────────────────────────────────────────────────────
- (void)addSection:(NSString *)txt y:(CGFloat *)y {
    *y += 10;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, *y, self.view.frame.size.width-40, 28)];
    l.text = txt; l.font = [UIFont boldSystemFontOfSize:15]; l.textColor = [UIColor systemBlueColor];
    [self.scrollView addSubview:l]; *y += 34;
}
- (UILabel *)addLabel:(NSString *)txt y:(CGFloat *)y {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, *y, self.view.frame.size.width-40, 20)];
    l.text = txt; l.font = [UIFont systemFontOfSize:13]; l.textColor = [UIColor secondaryLabelColor];
    [self.scrollView addSubview:l]; *y += 22; return l;
}
- (UITextField *)addField:(CGFloat)w y:(CGFloat *)y placeholder:(NSString *)p {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(20, *y, w, 40)];
    f.borderStyle = UITextBorderStyleRoundedRect; f.placeholder = p;
    f.delegate = self; f.returnKeyType = UIReturnKeyDone;
    f.font = [UIFont systemFontOfSize:14];
    [self.scrollView addSubview:f]; *y += 50; return f;
}
- (UISlider *)addSlider:(CGFloat)w y:(CGFloat *)y min:(float)mn max:(float)mx {
    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(20, *y, w, 30)];
    s.minimumValue = mn; s.maximumValue = mx;
    [s addTarget:self action:@selector(updateLabels) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:s]; *y += 45; return s;
}
- (void)addButton:(NSString *)title color:(UIColor *)color action:(SEL)action
                y:(CGFloat *)y w:(CGFloat)w {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(20, *y, w, 44);
    [b setTitle:title forState:UIControlStateNormal];
    b.backgroundColor = color; b.tintColor = [UIColor whiteColor]; b.layer.cornerRadius = 10;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:b]; *y += 55;
}
- (void)updateLabels {
    self.tempLabel.text = [NSString stringWithFormat:@"Temperature: %.2f", self.tempSlider.value];
    self.freqLabel.text = [NSString stringWithFormat:@"Freq Penalty: %.2f", self.freqSlider.value];
}
- (void)pickSoraModel {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Sora Model"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary *models = @{
        @"sora-2":     @"Fast, flexible — 5/10/15/20s",
        @"sora-2-pro": @"High fidelity — 5/10s only"
    };
    for (NSString *model in @[@"sora-2", @"sora-2-pro"]) {
        NSString *title = [NSString stringWithFormat:@"%@  (%@)", model, models[model]];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            self.soraModelField.text = model;
            [self updateVideoLabels];  // refresh duration hint
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickSoraResolution {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Video Size"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary *options = @{
        @"1280x720":  @"Landscape 720p  (recommended)",
        @"1792x1024": @"Landscape wide  (cinematic)",
        @"720x1280":  @"Portrait 720p   (social/reels)",
        @"1024x1792": @"Portrait tall   (stories)"
    };
    for (NSString *res in @[@"1280x720", @"1792x1024", @"720x1280", @"1024x1792"]) {
        NSString *title = [NSString stringWithFormat:@"%@  —  %@", res, options[res]];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            self.soraSizeField.text = res;
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)updateVideoLabels {
    NSString *model = self.soraModelField.text ?: @"sora-2";
    BOOL isPro = [model isEqualToString:@"sora-2-pro"];
    NSInteger raw = (NSInteger)self.soraDurationSlider.value;

    // Snap to nearest valid value for display
    NSArray<NSNumber *> *valid = isPro
        ? @[@5, @10, @15, @20]
        : @[@4, @8, @12, @16];
    NSInteger best = valid.firstObject.integerValue, bestDiff = NSIntegerMax;
    for (NSNumber *v in valid) {
        NSInteger diff = ABS(raw - v.integerValue);
        if (diff < bestDiff) { bestDiff = diff; best = v.integerValue; }
    }
    NSString *hint = isPro ? @"(5/10/15/20s)" : @"(4/8/12/16s)";
    self.soraDurationLabel.text = [NSString stringWithFormat:@"Duration: %lds %@",
                                   (long)best, hint];
}

// ─── Settings actions ─────────────────────────────────────────────────────────
- (void)confirmClearMemories {
    UIAlertController *c = [UIAlertController alertControllerWithTitle:@"Clear All Memories?"
        message:@"Cannot be undone." preferredStyle:UIAlertControllerStyleAlert];
    [c addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        BOOL ok = clearMemoryLog();
        UIAlertController *r = [UIAlertController alertControllerWithTitle:@"Memory"
            message:(ok ? @"All memories cleared." : @"Error clearing memories.")
            preferredStyle:UIAlertControllerStyleAlert];
        [r addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:r animated:YES completion:nil];
    }]];
    [c addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:c animated:YES completion:nil];
}
- (void)showHelperStats {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"EZHelper Stats"
        message:EZHelperStats() preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)fetchVoices {
    if (self.elKeyField.text.length == 0) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.elevenlabs.io/v1/voices"]];
    [req setValue:self.elKeyField.text forHTTPHeaderField:@"xi-api-key"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data) return;
        NSArray *voices = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil][@"voices"];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *s = [UIAlertController alertControllerWithTitle:@"Select Voice"
                message:nil preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSDictionary *v in voices) {
                [s addAction:[UIAlertAction actionWithTitle:v[@"name"]
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
                    self.elVoiceField.text = v[@"voice_id"];
                }]];
            }
            [s addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:s animated:YES completion:nil];
        });
    }] resume];
}
- (void)donate {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://paypal.me/i0stweak3r"]
                                       options:@{} completionHandler:nil];
}
- (void)loadSettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.apiKeyField.text       = [d stringForKey:@"apiKey"];
    self.systemMsgField.text    = [d stringForKey:@"systemMessage"];
    self.tempSlider.value       = [d floatForKey:@"temperature"] ?: 0.7;
    self.freqSlider.value       = [d floatForKey:@"frequency"];
    self.elKeyField.text        = [d stringForKey:@"elevenKey"];
    self.elVoiceField.text      = [d stringForKey:@"elevenVoiceID"];
    self.webSearchSwitch.on     = [d boolForKey:@"webSearchEnabled"];
    self.webLocationField.text  = [d stringForKey:@"webSearchLocation"];
    self.soraModelField.text    = [d stringForKey:@"soraModel"]    ?: @"sora-2";
    self.soraSizeField.text     = [d stringForKey:@"soraSize"]     ?: @"1280x720";
    self.soraDurationSlider.value = (float)([d integerForKey:@"soraDuration"] ?: 4);
    [self updateLabels];
    [self updateVideoLabels];
}
- (void)saveAndClose {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:self.apiKeyField.text       forKey:@"apiKey"];
    [d setObject:self.systemMsgField.text    forKey:@"systemMessage"];
    [d setFloat:self.tempSlider.value        forKey:@"temperature"];
    [d setFloat:self.freqSlider.value        forKey:@"frequency"];
    [d setObject:self.elKeyField.text        forKey:@"elevenKey"];
    [d setObject:self.elVoiceField.text      forKey:@"elevenVoiceID"];
    [d setBool:self.webSearchSwitch.isOn     forKey:@"webSearchEnabled"];
    [d setObject:self.webLocationField.text  forKey:@"webSearchLocation"];
    [d setObject:self.soraModelField.text    forKey:@"soraModel"];
    [d setObject:self.soraSizeField.text     forKey:@"soraSize"];
    [d setInteger:(NSInteger)self.soraDurationSlider.value forKey:@"soraDuration"];
    [d synchronize];
    EZLog(EZLogLevelInfo, @"SETTINGS", @"Settings saved");
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end
