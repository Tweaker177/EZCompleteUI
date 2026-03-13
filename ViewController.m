    // ViewController.m
    // EZCompleteUI
    //
    // v2.0 additions:
    //   - OpenAI Web Search via Responses API (web_search_preview tool)
    //   - Smart DALL-E context: image history tracked so follow-up prompts
    //     ("try again but...") get previous image context injected
    //   - Expanded file picker: PDF, ePub, text, images, audio, video
    //   - File analysis: PDF/text/ePub sent to GPT for reading/summary
    //   - Text-to-video (Sora) with settings in Settings panel
    //   - Settings expanded: web search toggle, video model/quality/duration

    #import "ViewController.h"
    #import "SettingsViewController.h"
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

    @interface ViewController () <UIDocumentPickerDelegate, UITextFieldDelegate,
                                   QLPreviewControllerDataSource,
                                   SFSpeechRecognizerDelegate>
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
    @property (nonatomic, strong) NSArray       *models;
    @property (nonatomic, strong) NSString      *selectedModel;
    @property (nonatomic, strong) NSMutableArray<NSDictionary *> *chatContext;
    @property (nonatomic, strong) NSLayoutConstraint *containerBottomConstraint;
    @property (nonatomic, strong) NSURL         *previewURL;
    @property (nonatomic, strong) AVSpeechSynthesizer *speechSynthesizer;
    @property (nonatomic, strong) AVAudioPlayer *audioPlayer;
    @property (nonatomic, strong) NSString      *lastAIResponse;
    @property (nonatomic, strong) NSString      *lastUserPrompt;
    @property (nonatomic, strong) NSString      *lastImagePrompt;
    @property (nonatomic, strong) NSString      *lastImageURL;
    @property (nonatomic, assign) BOOL          webSearchEnabled;
    @property (nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
    @property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *recognitionRequest;
    @property (nonatomic, strong) SFSpeechRecognitionTask *recognitionTask;
    @property (nonatomic, strong) AVAudioEngine *audioEngine;
    @property (nonatomic, assign) BOOL          isDictating;
    @property (nonatomic, strong) NSString      *pendingFileContext;
    @property (nonatomic, strong) NSString      *pendingFileName;
    @end

    @implementation ViewController

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Lifecycle
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)viewDidLoad {
        [super viewDidLoad];
        EZLogRotateIfNeeded(512 * 1024);
        EZLog(EZLogLevelInfo, @"APP", @"EZCompleteUI viewDidLoad — helpers active");
        [self setupData];
        [self setupUI];
        [self setupKeyboardObservers];
        [self setupDictation];
    }

    - (void)setupData {
        self.models = @[
            @"gpt-5-pro", @"gpt-5", @"gpt-5-mini",
            @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4",
            @"gpt-3.5-turbo",
            @"dall-e-3",
            @"sora",
            @"whisper-1"
        ];
        self.chatContext       = [NSMutableArray array];
        self.speechSynthesizer = [[AVSpeechSynthesizer alloc] init];
        self.selectedModel     = [[NSUserDefaults standardUserDefaults] stringForKey:@"selectedModel"] ?: self.models[0];
        self.webSearchEnabled  = [[NSUserDefaults standardUserDefaults] boolForKey:@"webSearchEnabled"];
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Shake
    // ─────────────────────────────────────────────────────────────────────────────

    - (BOOL)canBecomeFirstResponder { return YES; }

    - (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
        if (motion == UIEventSubtypeMotionShake) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"EZHelper Stats"
                                                                           message:EZHelperStats()
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Dictation
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)setupDictation {
        self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
        self.speechRecognizer.delegate = self;
        self.audioEngine = [[AVAudioEngine alloc] init];
        self.isDictating = NO;
    }

    - (void)speechRecognizer:(SFSpeechRecognizer *)speechRecognizer availabilityDidChange:(BOOL)available {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.dictateButton.enabled = available;
            EZLogf(EZLogLevelDebug, @"DICTATE", @"SFSpeechRecognizer availability: %@", available ? @"YES" : @"NO");
        });
    }

    - (void)toggleDictation {
        if (self.isDictating) {
            [self stopDictation];
            return;
        }
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
                    [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (granted) [self startDictation];
                            else { [self appendToChat:@"[Dictation Error]: Microphone permission denied."]; }
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
        NSError *sessionError = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryRecord mode:AVAudioSessionModeMeasurement
                     options:AVAudioSessionCategoryOptionDuckOthers error:&sessionError];
        [session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&sessionError];
        if (sessionError) { EZLogf(EZLogLevelError, @"DICTATE", @"Session error: %@", sessionError); return; }

        self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        self.recognitionRequest.shouldReportPartialResults = YES;
        AVAudioInputNode *inputNode = self.audioEngine.inputNode;
        __weak typeof(self) weakSelf = self;
        self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest
                                                                   resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (result) dispatch_async(dispatch_get_main_queue(), ^{ strongSelf.messageTextField.text = result.bestTranscription.formattedString; });
            if (error || result.isFinal) {
                EZLogf(EZLogLevelDebug, @"DICTATE", @"Task ended. error=%@ isFinal=%d", error, result.isFinal);
                [strongSelf.audioEngine stop];
                [inputNode removeTapOnBus:0];
                strongSelf.recognitionRequest = nil;
                strongSelf.recognitionTask    = nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    strongSelf.isDictating = NO;
                    [strongSelf.dictateButton setTintColor:[UIColor systemBlueColor]];
                });
            }
        }];

        AVAudioFormat *fmt = [inputNode outputFormatForBus:0];
        [inputNode installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
            [self.recognitionRequest appendAudioPCMBuffer:buf];
        }];
        [self.audioEngine prepare];
        NSError *engineError = nil;
        [self.audioEngine startAndReturnError:&engineError];
        if (engineError) { EZLogf(EZLogLevelError, @"DICTATE", @"Engine error: %@", engineError); return; }
        self.isDictating = YES;
        [self.dictateButton setTintColor:[UIColor systemRedColor]];
        EZLog(EZLogLevelInfo, @"DICTATE", @"Started dictation");
    }

    - (void)stopDictation {
        if (self.audioEngine.isRunning) { [self.audioEngine stop]; [self.recognitionRequest endAudio]; }
        self.isDictating = NO;
        [self.dictateButton setTintColor:[UIColor systemBlueColor]];
        EZLog(EZLogLevelInfo, @"DICTATE", @"Stopped by user");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - UI Setup
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)setupUI {
        self.view.backgroundColor = [UIColor systemBackgroundColor];

        self.settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.settingsButton setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
        [self.settingsButton addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];

        self.clipboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.clipboardButton setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
        [self.clipboardButton addTarget:self action:@selector(copyLastResponse) forControlEvents:UIControlEventTouchUpInside];

        self.speakButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.speakButton setImage:[UIImage systemImageNamed:@"speaker.wave.2.fill"] forState:UIControlStateNormal];
        [self.speakButton addTarget:self action:@selector(speakLastResponse) forControlEvents:UIControlEventTouchUpInside];

        self.clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.clearButton setImage:[UIImage systemImageNamed:@"trash.fill"] forState:UIControlStateNormal];
        [self.clearButton setTintColor:[UIColor systemRedColor]];
        [self.clearButton addTarget:self action:@selector(clearConversation) forControlEvents:UIControlEventTouchUpInside];

        self.webSearchButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.webSearchButton setImage:[UIImage systemImageNamed:@"globe"] forState:UIControlStateNormal];
        [self.webSearchButton addTarget:self action:@selector(toggleWebSearch) forControlEvents:UIControlEventTouchUpInside];
        [self updateWebSearchButtonTint];

        UIStackView *topStack = [[UIStackView alloc] initWithArrangedSubviews:@[
            self.clearButton, self.clipboardButton, self.speakButton,
            self.webSearchButton, self.settingsButton
        ]];
        topStack.spacing = 15;
        topStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:topStack];

        self.chatHistoryView = [[UITextView alloc] init];
        self.chatHistoryView.editable = NO;
        self.chatHistoryView.font = [UIFont systemFontOfSize:16];
        self.chatHistoryView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.chatHistoryView];

        self.inputContainer = [[UIView alloc] init];
        self.inputContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.inputContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.inputContainer];

        self.modelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", self.selectedModel] forState:UIControlStateNormal];
        [self.modelButton addTarget:self action:@selector(showModelPicker) forControlEvents:UIControlEventTouchUpInside];
        self.modelButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.inputContainer addSubview:self.modelButton];

        self.attachButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.attachButton setImage:[UIImage systemImageNamed:@"paperclip.circle.fill"] forState:UIControlStateNormal];
        [self.attachButton addTarget:self action:@selector(showAttachMenu) forControlEvents:UIControlEventTouchUpInside];
        self.attachButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.inputContainer addSubview:self.attachButton];

        self.dictateButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.dictateButton setImage:[UIImage systemImageNamed:@"mic.fill"] forState:UIControlStateNormal];
        [self.dictateButton setTintColor:[UIColor systemBlueColor]];
        [self.dictateButton addTarget:self action:@selector(toggleDictation) forControlEvents:UIControlEventTouchUpInside];
        self.dictateButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.inputContainer addSubview:self.dictateButton];

        self.messageTextField = [[UITextField alloc] init];
        self.messageTextField.placeholder = @"Type message...";
        self.messageTextField.borderStyle = UITextBorderStyleRoundedRect;
        self.messageTextField.delegate = self;
        self.messageTextField.returnKeyType = UIReturnKeyDone;
        self.messageTextField.translatesAutoresizingMaskIntoConstraints = NO;
        [self.inputContainer addSubview:self.messageTextField];

        self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.sendButton setTitle:@"Send" forState:UIControlStateNormal];
        [self.sendButton addTarget:self action:@selector(handleSend) forControlEvents:UIControlEventTouchUpInside];
        self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.inputContainer addSubview:self.sendButton];

        [self.sendButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.messageTextField setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        self.containerBottomConstraint = [self.inputContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];

        [NSLayoutConstraint activateConstraints:@[
            [topStack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:5],
            [topStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
            [self.chatHistoryView.topAnchor constraintEqualToAnchor:topStack.bottomAnchor constant:10],
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
            [self.inputContainer.bottomAnchor constraintEqualToAnchor:self.messageTextField.bottomAnchor constant:12]
        ]];
    }

    - (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Web Search Toggle
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)toggleWebSearch {
        self.webSearchEnabled = !self.webSearchEnabled;
        [[NSUserDefaults standardUserDefaults] setBool:self.webSearchEnabled forKey:@"webSearchEnabled"];
        [self updateWebSearchButtonTint];
        [self appendToChat:[NSString stringWithFormat:@"[System: Web Search %@]", self.webSearchEnabled ? @"ON" : @"OFF"]];
        EZLogf(EZLogLevelInfo, @"WEBSEARCH", @"Web search toggled %@", self.webSearchEnabled ? @"ON" : @"OFF");
    }

    - (void)updateWebSearchButtonTint {
        [self.webSearchButton setTintColor:self.webSearchEnabled ? [UIColor systemGreenColor] : [UIColor systemGrayColor]];
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
                                               handler:^(UIAlertAction *a) { [self presentFilePickerForMode:EZAttachModeWhisper]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"📄 Analyze PDF / ePub / Text"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) { [self presentFilePickerForMode:EZAttachModeAnalyze]; }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"🖼 Analyze Image (Vision)"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
            p.delegate = self;
            p.view.tag = (NSInteger)EZAttachModeAnalyze;
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
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        picker.delegate = self;
        picker.view.tag = (NSInteger)mode;
        [self presentViewController:picker animated:YES completion:nil];
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Document Picker Delegate
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
        NSURL *fileURL = urls.firstObject;
        if (!fileURL) return;
        EZAttachMode mode = (EZAttachMode)controller.view.tag;
        if (mode == EZAttachModeWhisper) {
            [self transcribeAudio:fileURL];
        } else {
            [self analyzeFile:fileURL];
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - File Analysis
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)analyzeFile:(NSURL *)fileURL {
        NSString *ext  = fileURL.pathExtension.lowercaseString;
        NSString *name = fileURL.lastPathComponent;
        EZLogf(EZLogLevelInfo, @"FILE", @"Analyzing: %@", name);
        [self appendToChat:[NSString stringWithFormat:@"[System: Reading %@...]", name]];

        // Image files — special path (vision API)
        if ([@[@"jpg",@"jpeg",@"png",@"gif",@"webp",@"heic"] containsObject:ext]) {
            [self analyzeImageFile:fileURL];
            return;
        }

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *extractedText = nil;
            if ([ext isEqualToString:@"pdf"]) {
                extractedText = [self extractTextFromPDF:fileURL];
            } else if ([ext isEqualToString:@"epub"]) {
                extractedText = [self extractTextFromEPUB:fileURL];
            } else {
                extractedText = [NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:nil];
                if (!extractedText) extractedText = [NSString stringWithContentsOfURL:fileURL encoding:NSISOLatin1StringEncoding error:nil];
            }

            if (!extractedText || extractedText.length == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self appendToChat:@"[Error: Could not extract text from file]"]; });
                return;
            }
            // Truncate to ~12k chars for context budget
            if (extractedText.length > 12000) {
                extractedText = [[extractedText substringToIndex:12000] stringByAppendingString:@"\n[...file truncated...]"];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.pendingFileContext = extractedText;
                self.pendingFileName    = name;
                [self appendToChat:[NSString stringWithFormat:@"[System: %@ ready (%lu chars). Ask me anything about it.]",
                                    name, (unsigned long)extractedText.length]];
                EZLogf(EZLogLevelInfo, @"FILE", @"Pending context set: %@ (%lu chars)", name, (unsigned long)extractedText.length);
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
        // Strip XML/HTML tags
        NSMutableString *stripped = [NSMutableString string];
        BOOL inTag = NO;
        for (NSUInteger i = 0; i < raw.length; i++) {
            unichar c = [raw characterAtIndex:i];
            if (c == '<') { inTag = YES; continue; }
            if (c == '>') { inTag = NO; [stripped appendString:@" "]; continue; }
            if (!inTag) [stripped appendFormat:@"%C", c];
        }
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\s{3,}" options:0 error:nil];
        return [re stringByReplacingMatchesInString:stripped options:0
                                              range:NSMakeRange(0, stripped.length)
                                       withTemplate:@"\n\n"];
    }

    - (void)analyzeImageFile:(NSURL *)fileURL {
        NSData *imageData = [NSData dataWithContentsOfURL:fileURL];
        if (!imageData) { dispatch_async(dispatch_get_main_queue(), ^{ [self appendToChat:@"[Error: Could not read image]"]; }); return; }
        NSString *ext = fileURL.pathExtension.lowercaseString;
        NSDictionary *mimeMap = @{@"jpg":@"image/jpeg",@"jpeg":@"image/jpeg",@"png":@"image/png",@"gif":@"image/gif",@"webp":@"image/webp",@"heic":@"image/heic"};
        NSString *mime    = mimeMap[ext] ?: @"image/jpeg";
        NSString *base64  = [imageData base64EncodedStringWithOptions:0];
        NSString *dataURL = [NSString stringWithFormat:@"data:%@;base64,%@", mime, base64];
        NSString *name    = fileURL.lastPathComponent;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *visionMsg = @{
                @"role": @"user",
                @"content": @[
                    @{@"type": @"image_url", @"image_url": @{@"url": dataURL}},
                    @{@"type": @"text", @"text": @"The user attached this image. Await their question."}
                ]
            };
            [self.chatContext addObject:visionMsg];
            [self appendToChat:[NSString stringWithFormat:@"[System: Image %@ loaded. Ask me to describe or analyze it.]", name]];
            EZLogf(EZLogLevelInfo, @"FILE", @"Image %@ added to context", name);
        });
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - TTS
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)speakLastResponse {
        if (!self.lastAIResponse) return;
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *elKey   = [d stringForKey:@"elevenKey"];
        NSString *elVoice = [d stringForKey:@"elevenVoiceID"];
        if (elKey.length > 0 && elVoice.length > 0) {
            EZLog(EZLogLevelInfo, @"TTS", @"Using ElevenLabs TTS");
            [self speakWithElevenLabs:self.lastAIResponse key:elKey voiceID:elVoice];
        } else {
            EZLog(EZLogLevelInfo, @"TTS", @"Using Apple TTS");
            [self speakWithApple:self.lastAIResponse];
        }
    }

    - (void)speakWithApple:(NSString *)text {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionDuckOthers error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        if (self.speechSynthesizer.isSpeaking) [self.speechSynthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
        u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
        u.rate  = AVSpeechUtteranceDefaultSpeechRate;
        [self.speechSynthesizer speakUtterance:u];
    }

    - (void)speakWithElevenLabs:(NSString *)text key:(NSString *)key voiceID:(NSString *)voiceID {
        EZLogf(EZLogLevelInfo, @"TTS", @"ElevenLabs: voiceID=%@ textLen=%lu", voiceID, (unsigned long)text.length);
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.elevenlabs.io/v1/text-to-speech/%@", voiceID]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:key forHTTPHeaderField:@"xi-api-key"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
            @"text": text, @"model_id": @"eleven_turbo_v2_5",
            @"voice_settings": @{@"stability": @0.5, @"similarity_boost": @0.5}
        } options:0 error:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) { dispatch_async(dispatch_get_main_queue(), ^{ [self speakWithApple:text]; }); return; }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            EZLogf(EZLogLevelInfo, @"TTS", @"ElevenLabs HTTP %ld, %lu bytes", (long)http.statusCode, (unsigned long)data.length);
            if (http.statusCode != 200) {
                NSString *errBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                EZLogf(EZLogLevelError, @"TTS", @"ElevenLabs non-200: %@", errBody);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self appendToChat:[NSString stringWithFormat:@"[ElevenLabs HTTP %ld — using Apple TTS]", (long)http.statusCode]];
                    [self speakWithApple:text];
                });
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:nil];
                [[AVAudioSession sharedInstance] setActive:YES error:nil];
                NSError *playerErr = nil;
                self.audioPlayer = [[AVAudioPlayer alloc] initWithData:data error:&playerErr];
                if (playerErr) { [self speakWithApple:text]; return; }
                EZLogf(EZLogLevelInfo, @"TTS", @"Playing audio, duration=%.1fs", self.audioPlayer.duration);
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

        // Inject pending file context if present
        NSString *fullPrompt = text;
        if (self.pendingFileContext.length > 0) {
            fullPrompt = [NSString stringWithFormat:@"[Attached file: %@]\n\n%@\n\n[User question]: %@",
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

        // DALL-E 3 — run context analyzer too (smart follow-ups)
        if ([self.selectedModel isEqualToString:@"dall-e-3"]) {
            if (self.lastImagePrompt.length > 0) {
                // Has prior image — check if follow-up needs context
                NSString *memories = loadMemoryContext(15);
                self.sendButton.enabled = NO;
                analyzePromptForContext(text, memories, apiKey, ^(EZContextResult *result) {
                    self.sendButton.enabled = YES;
                    NSString *finalPrompt = text;
                    if (result.needsContext) {
                        finalPrompt = [NSString stringWithFormat:@"Previous image prompt was: \"%@\". Now create: %@",
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

        // Sora
        if ([self.selectedModel isEqualToString:@"sora"]) {
            EZLog(EZLogLevelInfo, @"SEND", @"Sora text-to-video request");
            [self callSora:fullPrompt];
            return;
        }

        // Chat models
        NSString *memories = loadMemoryContext(15);
        EZLog(EZLogLevelInfo, @"SEND", @"Running context analyzer before send...");
        self.sendButton.enabled = NO;

        analyzePromptForContext(text, memories, apiKey, ^(EZContextResult *result) {
            self.sendButton.enabled = YES;
            EZLogf(EZLogLevelInfo, @"SEND", @"Analyzer done — needsContext=%@ tokens≈%ld reason: %@",
                   result.needsContext ? @"YES" : @"NO", (long)result.estimatedTokens, result.reason);
            if (result.needsContext) [self appendToChat:@"[System: Memory context included ✓]"];
            if (self.chatContext.count > 0) [self.chatContext removeLastObject];
            [self.chatContext addObject:@{@"role": @"user", @"content": result.finalPrompt}];
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

        NSURL *url = [NSURL URLWithString:endpointStr];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

        NSMutableDictionary *body = [NSMutableDictionary dictionary];
        body[@"model"] = self.selectedModel;
        NSString *sys  = [defaults stringForKey:@"systemMessage"];

        if (useResponsesAPI) {
            if (sys.length > 0) body[@"instructions"] = sys;
            body[@"input"] = self.chatContext;
            if (useWebSearch) {
                NSString *loc = [defaults stringForKey:@"webSearchLocation"] ?: @"";
                NSMutableDictionary *webTool = [NSMutableDictionary dictionaryWithDictionary:@{@"type": @"web_search_preview"}];
                if (loc.length > 0) webTool[@"user_location"] = @{@"type": @"approximate", @"city": loc};
                body[@"tools"] = @[webTool];
                EZLog(EZLogLevelInfo, @"WEBSEARCH", @"Web search tool attached");
            }
        } else {
            float temp = [defaults floatForKey:@"temperature"];
            body[@"temperature"]       = @(temp > 0 ? temp : 0.7);
            body[@"frequency_penalty"] = @([defaults floatForKey:@"frequency"]);
            NSMutableArray *messages = [NSMutableArray array];
            if (sys.length > 0) [messages addObject:@{@"role": @"system", @"content": sys}];
            [messages addObjectsFromArray:self.chatContext];
            body[@"messages"] = messages;
        }

        NSError *bodyErr = nil;
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyErr];
        if (bodyErr) { [self handleAPIError:@"Failed to build request"]; return; }

        EZLogf(EZLogLevelInfo, @"API", @"Calling %@ with model %@%@",
               endpointStr, self.selectedModel, useWebSearch ? @" [+WebSearch]" : @"");

        NSString *capturedPrompt = self.lastUserPrompt;

        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) { [self handleAPIError:error.localizedDescription]; return; }

            NSError *jsonErr = nil;
            id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (jsonErr || !jsonObj || [jsonObj isKindOfClass:[NSNull class]]) {
                [self handleAPIError:@"Could not parse API response"]; return;
            }
            NSDictionary *json = jsonObj;

            id errObj = json[@"error"];
            if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
                id msg = ((NSDictionary *)errObj)[@"message"];
                [self handleAPIError:(msg && ![msg isKindOfClass:[NSNull class]]) ? (NSString *)msg : @"Unknown API error"];
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
                if (choicesObj && ![choicesObj isKindOfClass:[NSNull class]] && [(NSArray *)choicesObj count] > 0) {
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

            if (!reply || reply.length == 0) {
                EZLogf(EZLogLevelError, @"API", @"Could not extract reply. Raw: %@", json);
                [self handleAPIError:@"Unexpected response format"]; return;
            }

            EZLogf(EZLogLevelInfo, @"API", @"Reply received (%lu chars)", (unsigned long)reply.length);

            dispatch_async(dispatch_get_main_queue(), ^{
                self.lastAIResponse = reply;
                [self.chatContext addObject:@{@"role": @"assistant", @"content": reply}];
                [self appendToChat:[NSString stringWithFormat:@"AI: %@", reply]];
            });

            createMemoryFromCompletion(capturedPrompt ?: @"", reply, apiKey, ^(NSString *entry) {
                if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved (%lu chars)", (unsigned long)entry.length);
            });

        }] resume];
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - DALL-E 3
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)callDalle3:(NSString *)prompt {
        [self appendToChat:@"[System: Generating Image...]"];
        EZLog(EZLogLevelInfo, @"DALLE", @"Sending DALL-E 3 generation request");
        NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"apiKey"];
        NSURL *url = [NSURL URLWithString:@"https://api.openai.com/v1/images/generations"];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"model":@"dall-e-3",@"prompt":prompt,@"n":@1,@"size":@"1024x1024"} options:0 error:nil];
        NSString *savedPrompt = prompt;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!data) { [self handleAPIError:error.localizedDescription ?: @"DALL-E request failed"]; return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            id errObj = json[@"error"];
            if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
                id m = ((NSDictionary *)errObj)[@"message"];
                [self handleAPIError:(m && ![m isKindOfClass:[NSNull class]]) ? m : @"DALL-E error"]; return;
            }
            id dataArr = json[@"data"];
            if (!dataArr || [dataArr isKindOfClass:[NSNull class]] || [(NSArray *)dataArr count] == 0) {
                [self handleAPIError:@"No image in response"]; return;
            }
            id imgObj = ((NSArray *)dataArr)[0];
            id imgURL = ([imgObj isKindOfClass:[NSDictionary class]]) ? imgObj[@"url"] : nil;
            if (!imgURL || [imgURL isKindOfClass:[NSNull class]]) { [self handleAPIError:@"No image URL"]; return; }
            EZLog(EZLogLevelInfo, @"DALLE", @"Image URL received, downloading...");
            dispatch_async(dispatch_get_main_queue(), ^{
                self.lastImagePrompt = savedPrompt;
                self.lastImageURL    = (NSString *)imgURL;
            });
            [self downloadAndShowImage:(NSString *)imgURL];
        }] resume];
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Sora Text-to-Video
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)callSora:(NSString *)prompt {
        [self appendToChat:@"[System: Generating video — this may take a minute...]"];
        EZLog(EZLogLevelInfo, @"SORA", @"Sending Sora generation request");
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        NSString *apiKey      = [d stringForKey:@"apiKey"];
        NSString *videoModel  = [d stringForKey:@"soraModel"]    ?: @"sora-1.0-turbo";
        NSString *videoSize   = [d stringForKey:@"soraSize"]     ?: @"1280x720";
        NSInteger videoDur    = [d integerForKey:@"soraDuration"] ?: 5;

        NSURL *url = [NSURL URLWithString:@"https://api.openai.com/v1/video/generations"];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
            @"model":videoModel, @"prompt":prompt,
            @"size":videoSize, @"n":@1, @"duration":@(videoDur)
        } options:0 error:nil];

        EZLogf(EZLogLevelInfo, @"SORA", @"model=%@ size=%@ duration=%lds", videoModel, videoSize, (long)videoDur);

        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) { [self handleAPIError:error.localizedDescription]; return; }
            id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (!jsonObj || [jsonObj isKindOfClass:[NSNull class]]) { [self handleAPIError:@"Could not parse Sora response"]; return; }
            NSDictionary *json = jsonObj;
            id errObj = json[@"error"];
            if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
                id m = ((NSDictionary *)errObj)[@"message"];
                [self handleAPIError:(m && ![m isKindOfClass:[NSNull class]]) ? m : @"Sora error"]; return;
            }
            // Check for direct URL
            id dataArr = json[@"data"];
            NSString *videoURL = nil;
            if (dataArr && ![dataArr isKindOfClass:[NSNull class]] && [(NSArray *)dataArr count] > 0) {
                id first = ((NSArray *)dataArr)[0];
                if (first && ![first isKindOfClass:[NSNull class]]) {
                    id u = ((NSDictionary *)first)[@"url"];
                    if (u && ![u isKindOfClass:[NSNull class]]) videoURL = (NSString *)u;
                }
            }
            if (videoURL) { [self downloadAndShowVideo:videoURL]; return; }
            // Async job
            id jobId = json[@"id"];
            if (jobId && ![jobId isKindOfClass:[NSNull class]]) {
                EZLogf(EZLogLevelInfo, @"SORA", @"Async job: %@", jobId);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self appendToChat:[NSString stringWithFormat:@"[Sora: Job started — polling for completion...]"]];
                });
                [self pollSoraJob:(NSString *)jobId apiKey:apiKey];
                return;
            }
            EZLogf(EZLogLevelError, @"SORA", @"No URL or job ID: %@", json);
            [self handleAPIError:@"No video URL in Sora response"];
        }] resume];
    }

    - (void)pollSoraJob:(NSString *)jobId apiKey:(NSString *)apiKey {
        __block NSInteger attempts = 0;
        dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

        // weak/strong dance breaks the retain cycle from a __block block capturing itself
        __block __weak void (^weakPoll)(void);
        void (^poll)(void);

        poll = ^{
            void (^strongPoll)(void) = weakPoll;
            if (!strongPoll) return;
            attempts++;
            if (attempts > 12) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self appendToChat:@"[Sora: Timed out. Check your OpenAI dashboard.]"]; });
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), q, ^{
                NSString *pollStr = [NSString stringWithFormat:@"https://api.openai.com/v1/video/generations/%@", jobId];
                NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:pollStr]];
                r.HTTPMethod = @"GET";
                [r setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
                [[[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    void (^s)(void) = weakPoll;
                    if (!data) { if (s) s(); return; }
                    id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if (!j || [j isKindOfClass:[NSNull class]]) { if (s) s(); return; }
                    NSDictionary *jd = j;
                    NSString *status = jd[@"status"];
                    EZLogf(EZLogLevelInfo, @"SORA", @"Poll %ld — status: %@", (long)attempts, status);
                    if ([status isEqualToString:@"completed"] || [status isEqualToString:@"succeeded"]) {
                        id da = jd[@"data"];
                        if (da && ![da isKindOfClass:[NSNull class]] && [(NSArray *)da count] > 0) {
                            id u = ((NSDictionary *)((NSArray *)da)[0])[@"url"];
                            if (u && ![u isKindOfClass:[NSNull class]]) { [self downloadAndShowVideo:(NSString *)u]; return; }
                        }
                    } else if ([status isEqualToString:@"failed"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{ [self appendToChat:@"[Sora: Video generation failed]"]; });
                        return;
                    }
                    if (s) s();
                }] resume];
            });
        };

        weakPoll = poll;
        poll();
    }

    - (void)downloadAndShowVideo:(NSString *)urlString {
        EZLog(EZLogLevelInfo, @"SORA", @"Downloading video...");
        [[[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:urlString]
                                        completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
            if (!location) { [self handleAPIError:@"Video download failed"]; return; }
            NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"sora_gen.mp4"]];
            [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
            [[NSFileManager defaultManager] copyItemAtURL:location toURL:tmp error:nil];
            EZLog(EZLogLevelInfo, @"SORA", @"Video ready, presenting QuickLook");
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
    // MARK: - Whisper
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)transcribeAudio:(NSURL *)fileURL {
        [self appendToChat:@"[System: Whisper Uploading...]"];
        EZLog(EZLogLevelInfo, @"WHISPER", @"Starting transcription");
        NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"apiKey"];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.openai.com/v1/audio/transcriptions"]];
        req.HTTPMethod = @"POST";
        NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
        [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
        NSMutableData *body = [NSMutableData data];
        [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n", fileURL.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[@"Content-Type: audio/mpeg\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[NSData dataWithContentsOfURL:fileURL]];
        [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[@"Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        req.HTTPBody = body;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString *formatted = [self formatWhisperTranscript:json[@"text"]];
                EZLogf(EZLogLevelInfo, @"WHISPER", @"Done (%lu chars)", (unsigned long)formatted.length);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.messageTextField.text = formatted;
                    [self appendToChat:[NSString stringWithFormat:@"[Whisper]: %@", formatted]];
                });
            } else { EZLogf(EZLogLevelError, @"WHISPER", @"Failed: %@", error.localizedDescription); }
        }] resume];
    }

    - (NSString *)formatWhisperTranscript:(NSString *)raw {
        if (!raw) return @"";
        return [[[raw stringByReplacingOccurrencesOfString:@". " withString:@".\n"]
                      stringByReplacingOccurrencesOfString:@"! " withString:@"!\n"]
                      stringByReplacingOccurrencesOfString:@"? " withString:@"?\n"];
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Image QuickLook
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)downloadAndShowImage:(NSString *)urlString {
        [[[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:urlString]
                                        completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
            if (!location) { EZLogf(EZLogLevelError, @"DALLE", @"Download failed: %@", err.localizedDescription); return; }
            NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"gen.png"]];
            [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
            [[NSFileManager defaultManager] copyItemAtURL:location toURL:tmp error:nil];
            EZLog(EZLogLevelInfo, @"DALLE", @"Image downloaded, presenting QuickLook");
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewURL = tmp;
                QLPreviewController *ql = [[QLPreviewController alloc] init];
                ql.dataSource = self;
                [self presentViewController:ql animated:YES completion:nil];
            });
        }] resume];
    }

    - (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)c { return 1; }
    - (id<QLPreviewItem>)previewController:(QLPreviewController *)c previewItemAtIndex:(NSInteger)i { return self.previewURL; }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Misc
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)handleAPIError:(NSString *)msg {
        EZLogf(EZLogLevelError, @"API", @"Error: %@", msg);
        dispatch_async(dispatch_get_main_queue(), ^{ [self appendToChat:[NSString stringWithFormat:@"[API Error]: %@", msg]]; });
    }

    - (void)keyboardWillChange:(NSNotification *)notification {
        CGRect kbFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        double duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
        BOOL isHiding = [notification.name isEqualToString:UIKeyboardWillHideNotification];
        self.containerBottomConstraint.constant = isHiding ? 0 : -(kbFrame.size.height - self.view.safeAreaInsets.bottom);
        [UIView animateWithDuration:duration animations:^{ [self.view layoutIfNeeded]; }];
    }

    - (void)setupKeyboardObservers {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
    }

    - (void)clearConversation {
        [self.chatContext removeAllObjects];
        self.chatHistoryView.text = @"[System: Cleared]";
        self.lastAIResponse = self.lastUserPrompt = self.lastImagePrompt = self.lastImageURL = nil;
        self.pendingFileContext = self.pendingFileName = nil;
        EZLog(EZLogLevelInfo, @"APP", @"Conversation cleared by user");
    }

    - (void)copyLastResponse {
        if (self.lastAIResponse) {
            [UIPasteboard generalPasteboard].string = self.lastAIResponse;
            EZLog(EZLogLevelInfo, @"APP", @"Last response copied to clipboard");
        }
    }

    - (void)showModelPicker {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Model" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *model in self.models) {
            [alert addAction:[UIAlertAction actionWithTitle:model style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                self.selectedModel = model;
                [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", model] forState:UIControlStateNormal];
                [[NSUserDefaults standardUserDefaults] setObject:model forKey:@"selectedModel"];
                EZLogf(EZLogLevelInfo, @"APP", @"Model switched to %@", model);
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }

    - (void)appendToChat:(NSString *)text {
        self.chatHistoryView.text = [self.chatHistoryView.text stringByAppendingFormat:@"\n\n%@", text];
        [self.chatHistoryView scrollRangeToVisible:NSMakeRange(self.chatHistoryView.text.length - 1, 1)];
    }

    - (void)openSettings {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[SettingsViewController alloc] init]];
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
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(saveAndClose)];
        [self setupUI];
        [self loadSettings];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardShow:) name:UIKeyboardWillShowNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardHide:) name:UIKeyboardWillHideNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardShow:) name:UIKeyboardWillChangeFrameNotification object:nil];
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

        // ── OpenAI ───────────────────────────────────────────────────────────────
        [self addSectionHeader:@"🤖 OpenAI" y:y]; y += 34;
        [self addLabel:@"API Key:" y:y]; y += 22;
        self.apiKeyField = [self addField:y w:w placeholder:@"sk-..."]; y += 50;
        [self addLabel:@"System Message:" y:y]; y += 22;
        self.systemMsgField = [self addField:y w:w placeholder:@"e.g. You are a helpful assistant"]; y += 50;
        self.tempLabel = [self addLabel:@"Temperature: 0.70" y:y]; y += 22;
        self.tempSlider = [self addSlider:y min:0 max:2]; y += 45;
        self.freqLabel = [self addLabel:@"Freq Penalty: 0.00" y:y]; y += 22;
        self.freqSlider = [self addSlider:y min:-2 max:2]; y += 50;

        // ── Web Search ───────────────────────────────────────────────────────────
        [self addSectionHeader:@"🌐 Web Search" y:y]; y += 34;
        [self addLabel:@"Enable web search by default:" y:y];
        self.webSearchSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 30, y - 4, 51, 31)];
        [self.scrollView addSubview:self.webSearchSwitch]; y += 42;
        [self addLabel:@"Location hint for search (optional city):" y:y]; y += 22;
        self.webLocationField = [self addField:y w:w placeholder:@"e.g. Miami, FL"]; y += 55;

        // ── ElevenLabs ───────────────────────────────────────────────────────────
        [self addSectionHeader:@"🎙 ElevenLabs TTS" y:y]; y += 34;
        [self addLabel:@"API Key:" y:y]; y += 22;
        self.elKeyField = [self addField:y w:w placeholder:@"ElevenLabs API key"]; y += 50;
        [self addLabel:@"Voice ID:" y:y]; y += 22;
        self.elVoiceField = [self addField:y w:w-95 placeholder:@"Voice ID"];
        UIButton *getVoices = [UIButton buttonWithType:UIButtonTypeSystem];
        getVoices.frame = CGRectMake(w - 74, y, 84, 40);
        [getVoices setTitle:@"Get Voices" forState:UIControlStateNormal];
        [getVoices addTarget:self action:@selector(fetchVoices) forControlEvents:UIControlEventTouchUpInside];
        [self.scrollView addSubview:getVoices]; y += 55;

        // ── Sora ─────────────────────────────────────────────────────────────────
        [self addSectionHeader:@"🎬 Sora Text-to-Video" y:y]; y += 34;
        [self addLabel:@"Model:" y:y]; y += 22;
        self.soraModelField = [self addField:y w:w placeholder:@"sora-1.0-turbo"]; y += 50;
        [self addLabel:@"Resolution:" y:y]; y += 22;
        self.soraSizeField = [self addField:y w:w placeholder:@"1280x720"]; y += 50;
        self.soraDurationLabel = [self addLabel:@"Duration: 5s" y:y]; y += 22;
        self.soraDurationSlider = [self addSlider:y min:1 max:20];
        [self.soraDurationSlider addTarget:self action:@selector(updateVideoLabels) forControlEvents:UIControlEventValueChanged];
        y += 50;

        // ── Memory ───────────────────────────────────────────────────────────────
        [self addSectionHeader:@"🧠 AI Memory" y:y]; y += 40;
        UIButton *clearMem = [self makeButton:@"Clear All Memories" color:[UIColor systemOrangeColor] y:y w:w];
        [clearMem addTarget:self action:@selector(confirmClearMemories) forControlEvents:UIControlEventTouchUpInside];
        y += 55;

        UIButton *statsBtn = [self makeButton:@"View Helper Stats" color:[UIColor systemIndigoColor] y:y w:w];
        [statsBtn addTarget:self action:@selector(showHelperStats) forControlEvents:UIControlEventTouchUpInside];
        y += 55;

        UIButton *donate = [self makeButton:@"💙 Donate via PayPal" color:[UIColor systemBlueColor] y:y w:w];
        [donate addTarget:self action:@selector(donate) forControlEvents:UIControlEventTouchUpInside];
        y += 65;

        self.scrollView.contentSize = CGSizeMake(self.view.frame.size.width, y + 30);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Settings UI helpers
    // ─────────────────────────────────────────────────────────────────────────────

    - (UILabel *)addSectionHeader:(NSString *)txt y:(CGFloat)y {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, y, self.view.frame.size.width - 40, 28)];
        l.text = txt; l.font = [UIFont boldSystemFontOfSize:15]; l.textColor = [UIColor systemBlueColor];
        [self.scrollView addSubview:l]; return l;
    }

    - (UILabel *)addLabel:(NSString *)txt y:(CGFloat)y {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, y, self.view.frame.size.width - 40, 20)];
        l.text = txt; l.font = [UIFont systemFontOfSize:13]; l.textColor = [UIColor secondaryLabelColor];
        [self.scrollView addSubview:l]; return l;
    }

    - (UITextField *)addField:(CGFloat)y w:(CGFloat)w placeholder:(NSString *)p {
        UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(20, y, w, 40)];
        f.borderStyle = UITextBorderStyleRoundedRect; f.placeholder = p;
        f.delegate = self; f.returnKeyType = UIReturnKeyDone; f.font = [UIFont systemFontOfSize:14];
        [self.scrollView addSubview:f]; return f;
    }

    - (UISlider *)addSlider:(CGFloat)y min:(float)min max:(float)max {
        UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(20, y, self.view.frame.size.width - 40, 30)];
        s.minimumValue = min; s.maximumValue = max;
        [s addTarget:self action:@selector(updateLabels) forControlEvents:UIControlEventValueChanged];
        [self.scrollView addSubview:s]; return s;
    }

    - (UIButton *)makeButton:(NSString *)title color:(UIColor *)color y:(CGFloat)y w:(CGFloat)w {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(20, y, w, 44);
        [b setTitle:title forState:UIControlStateNormal];
        b.backgroundColor = color; b.tintColor = [UIColor whiteColor]; b.layer.cornerRadius = 10;
        [self.scrollView addSubview:b]; return b;
    }

    - (void)updateLabels {
        self.tempLabel.text = [NSString stringWithFormat:@"Temperature: %.2f", self.tempSlider.value];
        self.freqLabel.text = [NSString stringWithFormat:@"Freq Penalty: %.2f", self.freqSlider.value];
    }

    - (void)updateVideoLabels {
        self.soraDurationLabel.text = [NSString stringWithFormat:@"Duration: %ds", (int)self.soraDurationSlider.value];
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Settings Actions
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)confirmClearMemories {
        UIAlertController *c = [UIAlertController alertControllerWithTitle:@"Clear All Memories?" message:@"Cannot be undone." preferredStyle:UIAlertControllerStyleAlert];
        [c addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            BOOL ok = clearMemoryLog();
            UIAlertController *r = [UIAlertController alertControllerWithTitle:@"Memory"
                message:(ok ? @"All memories cleared." : @"Error clearing memories.") preferredStyle:UIAlertControllerStyleAlert];
            [r addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:r animated:YES completion:nil];
        }]];
        [c addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:c animated:YES completion:nil];
    }

    - (void)showHelperStats {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"EZHelper Stats" message:EZHelperStats() preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        EZLog(EZLogLevelInfo, @"STATS", @"Stats viewed from Settings");
    }

    - (void)fetchVoices {
        if (self.elKeyField.text.length == 0) return;
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.elevenlabs.io/v1/voices"]];
        [req setValue:self.elKeyField.text forHTTPHeaderField:@"xi-api-key"];
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            if (!data) return;
            NSArray *voices = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil][@"voices"];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *s = [UIAlertController alertControllerWithTitle:@"Select Voice" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
                for (NSDictionary *v in voices) {
                    [s addAction:[UIAlertAction actionWithTitle:v[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                        self.elVoiceField.text = v[@"voice_id"];
                    }]];
                }
                [s addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:s animated:YES completion:nil];
            });
        }] resume];
    }

    - (void)donate {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://paypal.me/i0stweak3r"] options:@{} completionHandler:nil];
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
        self.soraModelField.text    = [d stringForKey:@"soraModel"]    ?: @"sora-1.0-turbo";
        self.soraSizeField.text     = [d stringForKey:@"soraSize"]     ?: @"1280x720";
        self.soraDurationSlider.value = (float)([d integerForKey:@"soraDuration"] ?: 5);
        [self updateLabels];
        [self updateVideoLabels];
    }

    - (void)saveAndClose {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:self.apiKeyField.text      forKey:@"apiKey"];
        [d setObject:self.systemMsgField.text   forKey:@"systemMessage"];
        [d setFloat:self.tempSlider.value       forKey:@"temperature"];
        [d setFloat:self.freqSlider.value       forKey:@"frequency"];
        [d setObject:self.elKeyField.text       forKey:@"elevenKey"];
        [d setObject:self.elVoiceField.text     forKey:@"elevenVoiceID"];
        [d setBool:self.webSearchSwitch.isOn    forKey:@"webSearchEnabled"];
        [d setObject:self.webLocationField.text forKey:@"webSearchLocation"];
        [d setObject:self.soraModelField.text   forKey:@"soraModel"];
        [d setObject:self.soraSizeField.text    forKey:@"soraSize"];
        [d setInteger:(NSInteger)self.soraDurationSlider.value forKey:@"soraDuration"];
        [d synchronize];
        EZLog(EZLogLevelInfo, @"SETTINGS", @"Settings saved");
        [self dismissViewControllerAnimated:YES completion:nil];
    }

    @end
