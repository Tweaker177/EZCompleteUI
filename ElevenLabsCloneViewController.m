// ElevenLabsCloneViewController.m
// EZCompleteUI v2.0
//
// Combines:
//  - All working record/playback/upload logic from the previous version
//  - WaveformView.h integration (live rolling waveform during recording,
//    full-file render on stop/import, animated progress during playback)
//  - "My Cloned Voices" section: fetched from GET /v1/voices, per-voice
//    DELETE /v1/voices/:id with optimistic removal + server-error rollback
//
// Changes from v1.x:
//   - All ElevenLabs API calls routed through ez-elevenlabs Supabase edge
//     function. No API key on device. Auth via EZAuthManager JWT.
//   - EZKeyVault import and apiKey method removed entirely.
//   - uploadIVCWithAPIKey:, createPVCWithAPIKey:, uploadPVCSampleWithAPIKey:
//     replaced by callEZElevenLabs:completion: edge function helper.
//   - deleteVoiceWithID: and refreshVoicesFromServer route through edge function.
//   - PVC segment (index 1) disabled + alpha 0.5 until Creator plan active.
//     Code retained so re-enabling is a one-line change.
//   - 402 (insufficient coins) and 403 (slot limit / membership required)
//     responses handled with descriptive alerts.
//   - Slot count and limit returned from edge function, shown in success alert.
//
// Requires: WaveformView.h

#import "ElevenLabsCloneViewController.h"
#import "WaveformView.h"
#import <AVFoundation/AVFoundation.h>
#import <QuickLook/QuickLook.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "helpers.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZCoinStoreViewController.h"

static NSString * const kMyVoicesDefaultsKey    = @"ELMyClonedVoices";
static NSString * const kEZElevenLabsURL         =
    @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-elevenlabs";

// ---------------------------------------------------------------------------
#pragma mark - Interface
// ---------------------------------------------------------------------------

@interface ElevenLabsCloneViewController () <
    AVAudioRecorderDelegate,
    AVAudioPlayerDelegate,
    UITextFieldDelegate,
    QLPreviewControllerDataSource,
    QLPreviewControllerDelegate,
    UIDocumentPickerDelegate
>

// ---- Scroll host ----
@property (nonatomic, strong) UIScrollView *scrollView;

// ---- Voice config ----
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *langField;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UISwitch *noiseSwitch;

// ---- Record / transport buttons ----
@property (nonatomic, strong) UIButton *recordButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UIButton *skipBackButton;
@property (nonatomic, strong) UIButton *skipFwdButton;
@property (nonatomic, strong) UIButton *quickLookButton;
@property (nonatomic, strong) UIButton *chooseFileButton;
@property (nonatomic, strong) UIButton *uploadButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

// ---- Timer + waveform ----
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) WaveformView *waveformView;

// ---- My Voices section ----
@property (nonatomic, strong) UIButton *refreshVoicesButton;
@property (nonatomic, strong) UIActivityIndicatorView *voicesSpinner;
@property (nonatomic, strong) UIView *voicesContainerView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *myVoices;
@property (nonatomic) CGFloat voicesContainerY; // fixed Y after static controls
@property (nonatomic) NSUInteger visibleVoiceRowCount;
@property (nonatomic) BOOL didRunInitialVoiceRefresh;
@property (nonatomic) BOOL isPresentingDeferredModal;

// ---- AV objects ----
@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSURL *recordedFileURL;
@property (nonatomic, strong) NSTimer *meterTimer;
@property (nonatomic, strong) CADisplayLink *playbackDisplayLink;

// ---- State ----
@property (nonatomic, copy) NSString *createdPVCVoiceID;
@property (nonatomic) BOOL hasShownQuickLookForCurrentFile;
@property (nonatomic) BOOL isCheckingCloneSubscription;

@end

// ---------------------------------------------------------------------------
#pragma mark - Implementation
// ---------------------------------------------------------------------------

@implementation ElevenLabsCloneViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedString(@"ElevenLabsClone.Title", @"Voice cloning screen title");
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.visibleVoiceRowCount = 40;

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.contentInsetAdjustmentBehavior =
        UIScrollViewContentInsetAdjustmentAlways;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scrollView];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.scrollView addGestureRecognizer:tap];

    [self buildUI];
    [self loadCachedVoices];
    [self rebuildVoiceRows];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didRunInitialVoiceRefresh) return;
    self.didRunInitialVoiceRefresh = YES;

    // Let the presentation transition finish before rebuilding a large voice list.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshVoicesFromServer];
    });
}

- (void)dealloc {
    [self.meterTimer invalidate];
    [self.playbackDisplayLink invalidate];
}

// ---------------------------------------------------------------------------
#pragma mark - UI Construction
// ---------------------------------------------------------------------------

- (void)buildUI {
    CGFloat m = 20.0;
    CGFloat vw = self.view.bounds.size.width;
    CGFloat w  = vw - m * 2.0;
    CGFloat y  = 16.0;

    // ---- Voice name ----
    [self.scrollView addSubview:[self makeSectionLabel:NSLocalizedString(@"ElevenLabsClone.VoiceName", @"Voice name field label")
                                                 frame:CGRectMake(m, y, w, 16)]];
    y += 20;
    self.nameField = [self makeTextField:NSLocalizedString(@"ElevenLabsClone.VoiceNamePlaceholder", @"Voice name field placeholder")
                                   frame:CGRectMake(m, y, w, 36)];
    [self.scrollView addSubview:self.nameField];
    y += 44;

    // ---- Language ----
    [self.scrollView addSubview:[self makeSectionLabel:NSLocalizedString(@"ElevenLabsClone.LanguageCode", @"Language code field label")
                                                 frame:CGRectMake(m, y, w, 16)]];
    y += 20;
    self.langField = [self makeTextField:NSLocalizedString(@"ElevenLabsClone.LanguageCodePlaceholder", @"Language code field placeholder")
                                   frame:CGRectMake(m, y, w, 36)];
    self.langField.text = @"en";
    self.langField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.langField.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.scrollView addSubview:self.langField];
    y += 44;

    // ---- Clone mode ----
    self.modeControl = [[UISegmentedControl alloc]
                        initWithItems:@[NSLocalizedString(@"ElevenLabsClone.Instant", @"Instant voice cloning mode"), NSLocalizedString(@"ElevenLabsClone.Professional", @"Professional voice cloning mode")]];
    self.modeControl.frame = CGRectMake(m, y, w, 32);
    self.modeControl.selectedSegmentIndex = 0;
    // PVC disabled until Creator plan active — segment stays in UI so
    // re-enabling is removing these two lines only.
    [self.modeControl setEnabled:NO forSegmentAtIndex:1];
    [self.modeControl setTitleTextAttributes:@{NSForegroundColorAttributeName:
        [UIColor tertiaryLabelColor]} forState:UIControlStateDisabled];
    [self.modeControl addTarget:self
                         action:@selector(modeChanged:)
               forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.modeControl];
    y += 38;

    UILabel *pvcNote = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w, 18)];
    pvcNote.text = NSLocalizedString(@"ElevenLabsClone.ProfessionalNote", @"Professional voice cloning availability note");
    pvcNote.font = [UIFont systemFontOfSize:11];
    pvcNote.textColor = [UIColor secondaryLabelColor];
    [self.scrollView addSubview:pvcNote];
    y += 26;

    // ---- Noise switch ----
    UILabel *noiseLbl = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w - 60, 24)];
    noiseLbl.text = NSLocalizedString(@"ElevenLabsClone.RemoveNoise", @"Noise removal switch label");
    noiseLbl.font = [UIFont systemFontOfSize:13];
    [self.scrollView addSubview:noiseLbl];
    self.noiseSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(m + w - 60, y - 4, 60, 32)];
    [self.scrollView addSubview:self.noiseSwitch];
    y += 44;

    // ---- Divider ----
    [self.scrollView addSubview:[self makeDivider:CGRectMake(m, y, w, 0.5)]];
    y += 16;

    // ---- Record button ----
    self.recordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.recordButton.frame = CGRectMake(m, y, w, 48);
    [self.recordButton setTitle:NSLocalizedString(@"ElevenLabsClone.StartRecording", @"Start recording button")
                       forState:UIControlStateNormal];
    self.recordButton.titleLabel.font =
        [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.recordButton.layer.cornerRadius = 10;
    self.recordButton.backgroundColor = [UIColor systemRedColor];
    [self.recordButton setTitleColor:UIColor.whiteColor
                            forState:UIControlStateNormal];
    [self.recordButton addTarget:self
                          action:@selector(toggleRecord:)
                forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.recordButton];
    y += 56;

    // ---- Timer ----
    self.timerLabel = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w, 22)];
    self.timerLabel.text = @"00:00";
    self.timerLabel.font =
        [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
    self.timerLabel.textAlignment = NSTextAlignmentCenter;
    [self.scrollView addSubview:self.timerLabel];
    y += 28;

    // ---- WaveformView ----
    self.waveformView = [[WaveformView alloc] initWithFrame:CGRectMake(m, y, w, 88)];
    self.waveformView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.waveformView.lineWidth    = 1.5;
    self.waveformView.symmetric    = YES;
    self.waveformView.waveColor    = [UIColor colorWithRed:0.12 green:0.56
                                                      blue:0.95 alpha:1.0];
    self.waveformView.secondaryWaveColor =
        [self.waveformView.waveColor colorWithAlphaComponent:0.40];
    self.waveformView.progressColor = [UIColor systemOrangeColor];
    self.waveformView.layer.cornerRadius = 10;
    self.waveformView.clipsToBounds = YES;
    self.waveformView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    [self.scrollView addSubview:self.waveformView];
    y += 96;

    // ---- Transport row: ⏪  ▶︎  ⏸  ⏹  ⏩ ----
    CGFloat gap  = 8.0;
    CGFloat btnW = (w - gap * 4.0) / 5.0;

    self.skipBackButton = [self makeTransportButton:@"⏪ -10"
        frame:CGRectMake(m, y, btnW, 40) action:@selector(skipBack:)];
    [self.scrollView addSubview:self.skipBackButton];

    self.playButton = [self makeTransportButton:NSLocalizedString(@"ElevenLabsClone.Play", @"Play recording button")
        frame:CGRectMake(m + (btnW + gap) * 1, y, btnW, 40)
        action:@selector(playRecording:)];
    [self.scrollView addSubview:self.playButton];

    self.pauseButton = [self makeTransportButton:@"⏸"
        frame:CGRectMake(m + (btnW + gap) * 2, y, btnW, 40)
        action:@selector(pausePlayback:)];
    [self.scrollView addSubview:self.pauseButton];

    self.stopButton = [self makeTransportButton:NSLocalizedString(@"ElevenLabsClone.Stop", @"Stop playback button")
        frame:CGRectMake(m + (btnW + gap) * 3, y, btnW, 40)
        action:@selector(stopPlayback:)];
    [self.scrollView addSubview:self.stopButton];

    self.skipFwdButton = [self makeTransportButton:@"+10 ⏩"
        frame:CGRectMake(m + (btnW + gap) * 4, y, btnW, 40)
        action:@selector(skipFwd:)];
    [self.scrollView addSubview:self.skipFwdButton];
    y += 50;

    // ---- Import + Quick Look row ----
    CGFloat halfW = (w - gap) / 2.0;

    self.chooseFileButton = [self makeOutlineButton:NSLocalizedString(@"ElevenLabsClone.ImportFile", @"Import audio file button")
        frame:CGRectMake(m, y, halfW, 44) action:@selector(pickAudioFile:)];
    [self.scrollView addSubview:self.chooseFileButton];

    self.quickLookButton = [self makeOutlineButton:NSLocalizedString(@"ElevenLabsClone.QuickLook", @"Preview audio file button")
        frame:CGRectMake(m + halfW + gap, y, halfW, 44) action:@selector(showQuickLook:)];
    self.quickLookButton.enabled = NO;
    [self.scrollView addSubview:self.quickLookButton];
    y += 52;

    // ---- Upload button ----
    self.uploadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.uploadButton.frame = CGRectMake(m, y, w, 50);
    [self.uploadButton setTitle:NSLocalizedString(@"ElevenLabsClone.UploadClone", @"Upload and clone button")
                       forState:UIControlStateNormal];
    self.uploadButton.titleLabel.font =
        [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.uploadButton.layer.cornerRadius = 10;
    self.uploadButton.backgroundColor = [UIColor systemBlueColor];
    [self.uploadButton setTitleColor:UIColor.whiteColor
                            forState:UIControlStateNormal];
    [self.uploadButton addTarget:self
                          action:@selector(uploadClone:)
                forControlEvents:UIControlEventTouchUpInside];
    self.uploadButton.enabled = NO;
    [self.scrollView addSubview:self.uploadButton];
    y += 58;

    // Spinner (centered, below upload)
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(vw / 2.0, y + 12);
    self.spinner.hidesWhenStopped = YES;
    [self.scrollView addSubview:self.spinner];
    y += 34;

    // ---- Divider before voices ----
    [self.scrollView addSubview:[self makeDivider:CGRectMake(m, y, w, 0.5)]];
    y += 20;

    // ---- "My Cloned Voices" header ----
    UILabel *voicesHeader = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w - 100, 24)];
    voicesHeader.text = NSLocalizedString(@"ElevenLabsClone.MyVoices", @"Cloned voices section title");
    voicesHeader.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.scrollView addSubview:voicesHeader];

    self.refreshVoicesButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.refreshVoicesButton.frame = CGRectMake(m + w - 90, y, 90, 24);
    [self.refreshVoicesButton setTitle:NSLocalizedString(@"ElevenLabsClone.Refresh", @"Refresh cloned voices button")
                              forState:UIControlStateNormal];
    self.refreshVoicesButton.titleLabel.font =
        [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [self.refreshVoicesButton addTarget:self
                                 action:@selector(refreshVoicesTapped:)
                       forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.refreshVoicesButton];

    self.voicesSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.voicesSpinner.center = CGPointMake(m + w - 45, y + 12);
    self.voicesSpinner.hidesWhenStopped = YES;
    [self.scrollView addSubview:self.voicesSpinner];
    y += 36;

    // ---- Voices container (rebuilt dynamically on each refresh) ----
    self.voicesContainerY = y;
    self.voicesContainerView = [[UIView alloc] initWithFrame:CGRectMake(0, y, vw, 0)];
    self.voicesContainerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.scrollView addSubview:self.voicesContainerView];

    [self rebuildVoiceRows];
}

// ---------------------------------------------------------------------------
#pragma mark - UI Helpers
// ---------------------------------------------------------------------------

- (UILabel *)makeSectionLabel:(NSString *)text frame:(CGRect)frame {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    l.textColor = [UIColor secondaryLabelColor];
    return l;
}

- (UITextField *)makeTextField:(NSString *)placeholder frame:(CGRect)frame {
    UITextField *tf = [[UITextField alloc] initWithFrame:frame];
    tf.placeholder = placeholder;
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.delegate = self;
    return tf;
}

- (UIButton *)makeTransportButton:(NSString *)title
                            frame:(CGRect)frame
                           action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = frame;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    b.layer.cornerRadius = 8;
    b.backgroundColor = [UIColor systemFillColor];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    b.enabled = NO;
    return b;
}

- (UIButton *)makeOutlineButton:(NSString *)title
                          frame:(CGRect)frame
                         action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = frame;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14];
    b.layer.cornerRadius = 8;
    b.backgroundColor = [UIColor systemGray5Color];
    [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    b.layer.borderWidth = 0.5;
    b.layer.borderColor = [UIColor systemGray3Color].CGColor;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView *)makeDivider:(CGRect)frame {
    UIView *v = [[UIView alloc] initWithFrame:frame];
    v.backgroundColor = [UIColor separatorColor];
    return v;
}

- (void)dismissKeyboard { [self.view endEditing:YES]; }

- (void)modeChanged:(UISegmentedControl *)seg {
    EZLogf(EZLogLevelInfo, @"ELEVEN", @"Mode → %@",
           seg.selectedSegmentIndex == 0 ? @"IVC" : @"PVC");
}

// Enable / disable all file-dependent controls as a group
- (void)setFileActionsEnabled:(BOOL)enabled {
    self.playButton.enabled     = enabled;
    self.pauseButton.enabled    = enabled;
    self.stopButton.enabled     = enabled;
    self.skipBackButton.enabled = enabled;
    self.skipFwdButton.enabled  = enabled;
    self.uploadButton.enabled   = enabled;
    self.quickLookButton.enabled = enabled;
}

- (void)setLoading:(BOOL)loading {
    if (loading) [self.spinner startAnimating];
    else         [self.spinner stopAnimating];
    self.view.userInteractionEnabled   = !loading;
    self.navigationItem.hidesBackButton = loading;
}

- (UIViewController *)topPresenterForModal {
    UIViewController *top = self;
    while (top.presentedViewController &&
           !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top;
}

- (void)presentViewControllerSafely:(UIViewController *)viewController
                           animated:(BOOL)animated
                         retryCount:(NSInteger)retryCount {
    if (!viewController || retryCount <= 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.viewIfLoaded.window || self.isBeingDismissed) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.20 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self presentViewControllerSafely:viewController
                                         animated:animated
                                       retryCount:retryCount - 1];
            });
            return;
        }

        UIViewController *host = [self topPresenterForModal];
        BOOL transitionInFlight = host.isBeingPresented || host.isBeingDismissed;
        if (!transitionInFlight && host.transitionCoordinator) {
            transitionInFlight = host.transitionCoordinator.isAnimated;
        }

        if (transitionInFlight || self.isPresentingDeferredModal) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.20 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self presentViewControllerSafely:viewController
                                         animated:animated
                                       retryCount:retryCount - 1];
            });
            return;
        }

        if ([host.presentedViewController isKindOfClass:UIAlertController.class] &&
            [viewController isKindOfClass:UIAlertController.class]) {
            return;
        }

        self.isPresentingDeferredModal = YES;
        [host presentViewController:viewController animated:animated completion:^{
            self.isPresentingDeferredModal = NO;
        }];
    });
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    NSString *safeTitle = title.length ? title : NSLocalizedString(@"ElevenLabsClone.Notice", @"Generic alert title");
    NSString *safeMessage = message.length ? message : @"";
    if (safeMessage.length > 500) {
        safeMessage = [[safeMessage substringToIndex:500] stringByAppendingString:@"..."];
    }

    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:safeTitle
                                            message:safeMessage
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"ElevenLabsClone.OK", @"Alert confirmation")
                                           style:UIAlertActionStyleDefault
                                         handler:nil]];
    [self presentViewControllerSafely:ac animated:NO retryCount:8];
}

// ---------------------------------------------------------------------------
#pragma mark - Recording
// ---------------------------------------------------------------------------

- (void)toggleRecord:(id)sender {
    if (self.recorder.isRecording) [self stopRecording];
    else                           [self startRecording];
}

- (void)startRecording {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;

    if (session.recordPermission == AVAudioSessionRecordPermissionUndetermined) {
        [session requestRecordPermission:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) [self startRecording];
                else [self showAlert:NSLocalizedString(@"ElevenLabsClone.MicrophoneDenied", @"Microphone permission denied alert title")
                             message:NSLocalizedString(@"ElevenLabsClone.MicrophoneDeniedMessage", @"Microphone permission denied alert message")];
            });
        }];
        return;
    }
    if (session.recordPermission != AVAudioSessionRecordPermissionGranted) {
        [self showAlert:NSLocalizedString(@"ElevenLabsClone.MicrophoneDenied", @"Microphone permission denied alert title")
                message:NSLocalizedString(@"ElevenLabsClone.MicrophoneDeniedMessage", @"Microphone permission denied alert message")];
        return;
    }

    [session setCategory:AVAudioSessionCategoryPlayAndRecord
                    mode:AVAudioSessionModeMeasurement
                 options:(AVAudioSessionCategoryOptionDefaultToSpeaker |
                          AVAudioSessionCategoryOptionMixWithOthers)
                   error:&err];
    if (err) EZLogf(EZLogLevelError, @"REC", @"Session setCategory: %@", err);
    [session setActive:YES error:&err];
    if (err) EZLogf(EZLogLevelError, @"REC", @"Session activate: %@", err);

    NSDictionary *settings = @{
        AVFormatIDKey:              @(kAudioFormatLinearPCM),
        AVSampleRateKey:            @48000,
        AVNumberOfChannelsKey:      @1,
        AVLinearPCMBitDepthKey:     @16,
        AVLinearPCMIsFloatKey:      @NO,
        AVLinearPCMIsBigEndianKey:  @NO,
        AVEncoderAudioQualityKey:   @(AVAudioQualityHigh)
    };

    NSString *fn = [NSString stringWithFormat:@"clone_sample_%ld.wav",
                    (long)NSDate.date.timeIntervalSince1970];
    NSURL *fileURL = [NSURL fileURLWithPath:
                      [NSTemporaryDirectory() stringByAppendingPathComponent:fn]];

    self.recorder = [[AVAudioRecorder alloc] initWithURL:fileURL
                                                settings:settings
                                                   error:&err];
    if (err || !self.recorder) {
        [self showAlert:NSLocalizedString(@"ElevenLabsClone.RecordError", @"Recording error alert title")
                message:err.localizedDescription ?: NSLocalizedString(@"ElevenLabsClone.RecordInitFailed", @"Recording setup failure")];
        return;
    }
    self.recorder.delegate = self;
    self.recorder.meteringEnabled = YES;

    if (![self.recorder prepareToRecord]) {
        [self showAlert:NSLocalizedString(@"ElevenLabsClone.RecordError", @"Recording error alert title") message:NSLocalizedString(@"ElevenLabsClone.RecordPrepareFailed", @"Recording preparation failure")];
        return;
    }

    [self.recorder record];
    self.recordedFileURL = fileURL;
    self.hasShownQuickLookForCurrentFile = NO;

    [self.waveformView clear];
    [self.waveformView setProgress:0.0 animated:NO];
    self.timerLabel.text = @"00:00";

    [self.recordButton setTitle:NSLocalizedString(@"ElevenLabsClone.StopRecording", @"Stop recording button") forState:UIControlStateNormal];
    self.recordButton.backgroundColor = [UIColor systemGrayColor];
    [self setFileActionsEnabled:NO];

    [self startMeterTimer];
    EZLogf(EZLogLevelInfo, @"REC", @"Recording to %@", fileURL.lastPathComponent);
}

- (void)stopRecording {
    [self.recorder stop];
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:nil];
    [self stopMeterTimer];

    [self.recordButton setTitle:NSLocalizedString(@"ElevenLabsClone.StartRecording", @"Start recording button") forState:UIControlStateNormal];
    self.recordButton.backgroundColor = [UIColor systemRedColor];

    if (self.recordedFileURL) {
        // Render the full waveform from the finished file
        [self.waveformView loadAudioFileAtURL:self.recordedFileURL
                                   completion:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.waveformView setProgress:0.0 animated:NO];
            });
        }];
        [self setFileActionsEnabled:YES];

        if (!self.hasShownQuickLookForCurrentFile) {
            self.hasShownQuickLookForCurrentFile = YES;
            dispatch_async(dispatch_get_main_queue(), ^{ [self showQuickLook:nil]; });
        }
    }
    EZLog(EZLogLevelInfo, @"REC", @"Stopped recording");
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder
                             successfully:(BOOL)flag {
    if (!flag) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:NSLocalizedString(@"ElevenLabsClone.RecordingFailed", @"Recording failed alert title")
                    message:NSLocalizedString(@"ElevenLabsClone.RecordingFailedMessage", @"Recording failed alert message")];
        });
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Playback
// ---------------------------------------------------------------------------

- (void)playRecording:(id)sender {
    if (!self.recordedFileURL) return;

    NSError *err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                            mode:AVAudioSessionModeDefault
                                         options:AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];

    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:self.recordedFileURL
                                                         error:&err];
    if (err || !self.player) {
        [self showAlert:NSLocalizedString(@"ElevenLabsClone.PlaybackError", @"Playback error alert title")
                message:err.localizedDescription ?: NSLocalizedString(@"ElevenLabsClone.PlayerCreateFailed", @"Playback setup failure")];
        return;
    }
    self.player.delegate = self;
    self.player.meteringEnabled = YES;
    [self.player prepareToPlay];
    [self.player play];

    [self startMeterTimer];
    [self startPlaybackDisplayLink];

    self.pauseButton.enabled    = YES;
    self.stopButton.enabled     = YES;
    self.skipBackButton.enabled = YES;
    self.skipFwdButton.enabled  = YES;
}

- (void)pausePlayback:(id)sender {
    if (self.player.isPlaying) {
        [self.player pause];
        [self stopPlaybackDisplayLink];
        [self stopMeterTimer];
    } else {
        [self.player play];
        [self startMeterTimer];
        [self startPlaybackDisplayLink];
    }
}

- (void)stopPlayback:(id)sender {
    [self.player stop];
    self.player.currentTime = 0;
    self.timerLabel.text = @"00:00";
    [self stopMeterTimer];
    [self stopPlaybackDisplayLink];
    [self.waveformView setProgress:0.0 animated:YES];
}

- (void)skipBack:(id)sender {
    if (!self.player) return;
    self.player.currentTime = MAX(0, self.player.currentTime - 10.0);
}

- (void)skipFwd:(id)sender {
    if (!self.player) return;
    self.player.currentTime = MIN(self.player.duration,
                                  self.player.currentTime + 10.0);
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    [self stopMeterTimer];
    [self stopPlaybackDisplayLink];
    [self.waveformView setProgress:1.0 animated:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.timerLabel.text = [self mmssFromTime:player.duration];
    });
}

// ---------------------------------------------------------------------------
#pragma mark - Metering / Timer
// ---------------------------------------------------------------------------

- (void)startMeterTimer {
    [self.meterTimer invalidate];
    self.meterTimer =
        [NSTimer scheduledTimerWithTimeInterval:0.05
                                         target:self
                                       selector:@selector(tickMeter)
                                       userInfo:nil
                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.meterTimer forMode:NSRunLoopCommonModes];
}

- (void)stopMeterTimer {
    [self.meterTimer invalidate];
    self.meterTimer = nil;
}

- (void)tickMeter {
    if (self.recorder.isRecording) {
        [self.recorder updateMeters];
        // Convert dBFS average → linear 0..1, then feed a small repeating
        // buffer into WaveformView to drive the live rolling display.
        float avg   = [self.recorder averagePowerForChannel:0];
        float level = powf(10.0f, 0.05f * avg); // linear amplitude
        float buf[64];
        for (int i = 0; i < 64; i++) buf[i] = level;
        [self.waveformView updateWithFloatSamples:buf count:64];
        self.timerLabel.text = [self mmssFromTime:self.recorder.currentTime];
    } else if (self.player.isPlaying) {
        self.timerLabel.text = [self mmssFromTime:self.player.currentTime];
    }
}

- (NSString *)mmssFromTime:(NSTimeInterval)t {
    NSInteger ti = (NSInteger)floor(t + 0.5);
    return [NSString stringWithFormat:@"%02ld:%02ld",
            (long)(ti / 60), (long)(ti % 60)];
}

// ---------------------------------------------------------------------------
#pragma mark - Playback progress → WaveformView
// ---------------------------------------------------------------------------

- (void)startPlaybackDisplayLink {
    [self.playbackDisplayLink invalidate];
    self.playbackDisplayLink =
        [CADisplayLink displayLinkWithTarget:self
                                    selector:@selector(tickPlaybackProgress)];
    [self.playbackDisplayLink addToRunLoop:[NSRunLoop mainRunLoop]
                                   forMode:NSRunLoopCommonModes];
}

- (void)stopPlaybackDisplayLink {
    [self.playbackDisplayLink invalidate];
    self.playbackDisplayLink = nil;
}

- (void)tickPlaybackProgress {
    if (!self.player || self.player.duration <= 0) return;
    CGFloat progress = (CGFloat)(self.player.currentTime / self.player.duration);
    [self.waveformView setProgress:progress animated:NO];
}

// ---------------------------------------------------------------------------
#pragma mark - Quick Look
// ---------------------------------------------------------------------------

- (void)showQuickLook:(id)sender {
    if (!self.recordedFileURL) {
        [self showAlert:NSLocalizedString(@"ElevenLabsClone.NoRecording", @"No recording alert title")
                message:NSLocalizedString(@"ElevenLabsClone.NoRecordingMessage", @"No recording alert message")];
        return;
    }
    QLPreviewController *ql = [QLPreviewController new];
    ql.dataSource = self;
    ql.delegate = self;
    [self presentViewControllerSafely:ql animated:YES retryCount:8];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return self.recordedFileURL ? 1 : 0;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller
                    previewItemAtIndex:(NSInteger)index {
    return self.recordedFileURL;
}

// ---------------------------------------------------------------------------
#pragma mark - File picker (import)
// ---------------------------------------------------------------------------

- (void)pickAudioFile:(id)sender {
    NSArray<UTType *> *types = @[UTTypeAudio, UTTypeWAV, UTTypeMPEG4Audio];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc]
             initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewControllerSafely:picker animated:YES retryCount:8];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    BOOL needsRelease = [url startAccessingSecurityScopedResource];
    @try {
        NSString *ext = url.pathExtension.length ? url.pathExtension : @"wav";
        NSString *fn  = [NSString stringWithFormat:@"picked_%ld.%@",
                         (long)NSDate.date.timeIntervalSince1970, ext];
        NSURL *dest = [NSURL fileURLWithPath:
                       [NSTemporaryDirectory() stringByAppendingPathComponent:fn]];

        NSError *err = nil;
        if ([NSFileManager.defaultManager fileExistsAtPath:dest.path])
            [NSFileManager.defaultManager removeItemAtURL:dest error:nil];

        if (![NSFileManager.defaultManager copyItemAtURL:url toURL:dest error:&err]) {
            [self showAlert:NSLocalizedString(@"ElevenLabsClone.ImportFailed", @"Import failed alert title")
                    message:err.localizedDescription ?: NSLocalizedString(@"ElevenLabsClone.CopyFailed", @"Audio file copy failure")];
            return;
        }

        self.recordedFileURL = dest;
        self.hasShownQuickLookForCurrentFile = NO;
        [self setFileActionsEnabled:YES];

        // Render waveform from imported file
        [self.waveformView loadAudioFileAtURL:dest
                                   completion:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.waveformView setProgress:0.0 animated:NO];
            });
        }];

        if (!self.hasShownQuickLookForCurrentFile) {
            self.hasShownQuickLookForCurrentFile = YES;
            dispatch_async(dispatch_get_main_queue(), ^{ [self showQuickLook:nil]; });
        }
        EZLogf(EZLogLevelInfo, @"PICK", @"Imported %@", dest.lastPathComponent);
    } @finally {
        if (needsRelease) [url stopAccessingSecurityScopedResource];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    EZLog(EZLogLevelInfo, @"PICK", @"User cancelled document picker");
}

// ---------------------------------------------------------------------------
#pragma mark - UITextFieldDelegate
// ---------------------------------------------------------------------------

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

// ---------------------------------------------------------------------------
#pragma mark - Upload / Clone
// ---------------------------------------------------------------------------

/// Returns the current user's JWT for authenticating edge function calls.
/// Returns nil when the user is not signed in.
- (NSString *)userJWT {
    return [EZAuthManager shared].accessToken;
}

- (BOOL)hasPurchasedAccess {
    EZEntitlementManager *entitlements = [EZEntitlementManager shared];
    static NSSet<NSString *> *supportedTiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        supportedTiers = [NSSet setWithObjects:@"basic", @"basic_weekly", @"standard", @"standard_annual",
                          @"pro", @"pro_annual", @"ultra", @"ultra_annual", @"power", @"power_annual",
                          @"enterprise", @"enterprise_annual", nil];
    });
    return entitlements.hasEverPurchased || [supportedTiers containsObject:entitlements.currentTier];
}

- (void)showSubscriptionRequiredAlert {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"ElevenLabsClone.SubscriptionRequired", @"Subscription required alert title")
                         message:NSLocalizedString(@"ElevenLabsClone.SubscriptionRequiredMessage", @"Subscription required alert message")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"ElevenLabsClone.NotNow", @"Subscription alert cancel button")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"ElevenLabsClone.ViewPlans", @"Subscription alert plans button")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self.navigationController pushViewController:[[EZCoinStoreViewController alloc] init]
                                             animated:YES];
    }]];
    [self presentViewControllerSafely:alert animated:YES retryCount:3];
}

- (void)uploadClone:(id)sender {
    if (!self.recordedFileURL) {
        [self showAlert:NSLocalizedString(@"ElevenLabsClone.NoRecording", @"No recording alert title")
                message:NSLocalizedString(@"ElevenLabsClone.NoRecordingMessage", @"No recording alert message")];
        return;
    }
    NSString *name = [[self.nameField.text ?: @""
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        copy];
    if (name.length == 0) {
        [self showAlert:NSLocalizedString(@"ElevenLabsClone.MissingName", @"Missing voice name alert title") message:NSLocalizedString(@"ElevenLabsClone.MissingNameMessage", @"Missing voice name alert message")];
        return;
    }
    NSString *jwt = [self userJWT];
    if (jwt.length == 0) {
        [self showAlert:NSLocalizedString(@"ElevenLabsClone.NotSignedIn", @"Not signed in alert title")
                message:NSLocalizedString(@"ElevenLabsClone.SignInCloneMessage", @"Sign in to clone alert message")];
        return;
    }

    if (self.isCheckingCloneSubscription) return;
    self.isCheckingCloneSubscription = YES;
    self.uploadButton.enabled = NO;

    // Refresh instead of trusting a cached plan, then fail closed if the
    // current subscription cannot be verified. This check never spends coins.
    __weak typeof(self) weakSelf = self;
    [[EZEntitlementManager shared] refreshSubscriptionStatusWithCompletion:
        ^(BOOL refreshed, __unused NSInteger balance) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.isCheckingCloneSubscription = NO;
            self.uploadButton.enabled = (self.recordedFileURL != nil);

            if (!refreshed) {
                [self showAlert:NSLocalizedString(@"ElevenLabsClone.SubscriptionCheckUnavailable", @"Subscription check failure title")
                        message:NSLocalizedString(@"ElevenLabsClone.SubscriptionCheckUnavailableMessage", @"Subscription check failure message")];
                return;
            }
            if (![self hasPurchasedAccess]) {
                EZLog(EZLogLevelInfo, @"CLONE", @"Blocked voice clone: no purchase history");
                [self showSubscriptionRequiredAlert];
                return;
            }
            [self submitCloneWithName:name jwt:jwt];
        }];
}

- (void)submitCloneWithName:(NSString *)name jwt:(NSString *)jwt {

    // PVC is currently disabled — segment index 1 is greyed out in buildUI.
    // If somehow triggered, route it to the server which will return 403 plan_required.
    NSString *action = (self.modeControl.selectedSegmentIndex == 0)
                     ? @"clone_voice" : @"pvc_clone";

    NSData *audioData = [NSData dataWithContentsOfURL:self.recordedFileURL];
    if (audioData.length == 0) {
        [self showAlert:NSLocalizedString(@"ElevenLabsClone.EmptyFile", @"Empty recording file alert title") message:NSLocalizedString(@"ElevenLabsClone.EmptyFileMessage", @"Empty recording file alert message")];
        return;
    }
    NSString *audioB64     = [audioData base64EncodedStringWithOptions:0];
    NSString *audioFilename = self.recordedFileURL.lastPathComponent ?: @"sample.wav";
    BOOL noiseRemoval      = self.noiseSwitch.isOn;

    [self setLoading:YES];
    NSDictionary *payload = @{
        @"action":                    action,
        @"name":                      name,
        @"audio_b64":                 audioB64,
        @"filename":                  audioFilename,
        @"remove_background_noise":   @(noiseRemoval),
    };

    [self callEZElevenLabs:payload jwt:jwt
               completion:^(NSDictionary *responseDict, NSInteger statusCode, NSError *networkError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoading:NO];

            if (networkError) {
                [self showAlert:NSLocalizedString(@"ElevenLabsClone.NetworkError", @"Network error alert title") message:networkError.localizedDescription];
                return;
            }
            if (statusCode == 402) {
                NSInteger balance = [responseDict[@"balance"] integerValue];
                NSInteger cost    = [responseDict[@"cost"]    integerValue];
                [self showAlert:NSLocalizedString(@"ElevenLabsClone.NeedMoreCoins", @"Insufficient coins alert title")
                        message:[NSString stringWithFormat:
                                 NSLocalizedString(@"ElevenLabsClone.NeedMoreCoinsMessage", @"Insufficient coins alert message format"),
                                 (long)balance, (long)cost]];
                return;
            }
            if (statusCode == 403) {
                NSString *errKey = responseDict[@"error"] ?: @"";
                NSString *reason = responseDict[@"reason"] ?: NSLocalizedString(@"ElevenLabsClone.AccessDenied", @"Access denied fallback message");
                NSString *title  = [errKey isEqualToString:@"clone_slot_limit"]
                                 ? NSLocalizedString(@"ElevenLabsClone.VoiceSlotFull", @"Voice clone slot limit title")
                                 : [errKey isEqualToString:@"membership_required"]
                                 ? NSLocalizedString(@"ElevenLabsClone.SubscriptionRequired", @"Subscription required alert title")
                                 : NSLocalizedString(@"ElevenLabsClone.NotAvailable", @"Unavailable alert title");
                [self showAlert:title message:reason];
                return;
            }
            if (statusCode < 200 || statusCode >= 300) {
                NSString *msg = responseDict[@"error"] ?: responseDict[@"detail"]
                             ?: NSLocalizedString(@"ElevenLabsClone.UploadFailed", @"Upload failure fallback message");
                [self showAlert:NSLocalizedString(@"ElevenLabsClone.CloneFailed", @"Clone failed alert title") message:msg];
                return;
            }

            NSString *voiceID     = responseDict[@"voice_id"];
            NSInteger slotsUsed   = [responseDict[@"slots_used"]  integerValue];
            NSInteger slotsLimit  = [responseDict[@"slots_limit"] integerValue];

            if (voiceID.length == 0) {
                [self showAlert:NSLocalizedString(@"ElevenLabsClone.CloneFailed", @"Clone failed alert title") message:NSLocalizedString(@"ElevenLabsClone.NoVoiceID", @"Missing voice ID alert message")];
                return;
            }

            NSDictionary *voiceEntry = @{
                @"voice_id": voiceID,
                @"name":     name,
                @"category": @"cloned",
            };
            [self saveVoiceLocally:voiceEntry];

            NSString *slotInfo = (slotsLimit > 0)
                ? [NSString stringWithFormat:NSLocalizedString(@"ElevenLabsClone.SlotsUsedFormat", @"Voice clone slots used format"),
                   (long)slotsUsed, (long)slotsLimit]
                : @"";
            [self showAlert:NSLocalizedString(@"ElevenLabsClone.VoiceCloned", @"Voice cloned success alert title")
                    message:[NSString stringWithFormat:NSLocalizedString(@"ElevenLabsClone.VoiceClonedMessage", @"Voice cloned success alert message format"), voiceID, slotInfo]];
            EZLogf(EZLogLevelInfo, @"CLONE", @"Created voice %@", voiceID);
        });
    }];
}

// ---------------------------------------------------------------------------
#pragma mark - Edge Function Helper
// ---------------------------------------------------------------------------

/// Posts a JSON payload to the ez-elevenlabs edge function and returns the
/// decoded response dictionary, HTTP status code, and any network error.
/// Always called on a background thread; completion is NOT dispatched to main —
/// callers are responsible for their own dispatch_async(main) if needed.
- (void)callEZElevenLabs:(NSDictionary *)payload
                     jwt:(NSString *)jwt
              completion:(void (^)(NSDictionary *responseDict,
                                   NSInteger     statusCode,
                                   NSError      *networkError))completion {
    NSMutableURLRequest *req =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kEZElevenLabsURL]];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 60;
    [req setValue:@"application/json"                       forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", jwt] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *networkError) {
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)resp;
        NSInteger statusCode = httpResp.statusCode;
        NSDictionary *responseDict = nil;
        if (data.length > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) responseDict = parsed;
        }
        completion(responseDict ?: @{}, statusCode, networkError);
    }] resume];
}

// ---------------------------------------------------------------------------
#pragma mark - My Voices: persistence
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------

- (void)loadCachedVoices {
    NSArray *cached =
        [[NSUserDefaults standardUserDefaults] objectForKey:kMyVoicesDefaultsKey];
    NSMutableArray *sanitized = [NSMutableArray array];
    if ([cached isKindOfClass:NSArray.class]) {
        for (id item in cached) {
            NSDictionary *voice = [self sanitizedVoiceDictionary:item];
            if (voice) [sanitized addObject:voice];
        }
    }
    self.myVoices = sanitized;
}

- (void)saveVoiceLocally:(NSDictionary *)voice {
    if (!self.myVoices) self.myVoices = [NSMutableArray array];
    NSDictionary *safeVoice = [self sanitizedVoiceDictionary:voice];
    if (!safeVoice) return;
    // Avoid duplicates by voice_id
    NSString *newID = safeVoice[@"voice_id"] ?: safeVoice[@"id"] ?: @"";
    for (NSDictionary *v in self.myVoices) {
        NSString *vid = v[@"voice_id"] ?: v[@"id"] ?: @"";
        if ([vid isEqualToString:newID]) return;
    }
    [self.myVoices insertObject:safeVoice atIndex:0];
    self.visibleVoiceRowCount = MAX(self.visibleVoiceRowCount, MIN((NSUInteger)40, self.myVoices.count));
    [[NSUserDefaults standardUserDefaults] setObject:self.myVoices
                                             forKey:kMyVoicesDefaultsKey];
    [self rebuildVoiceRows];
    // Full server refresh in background for authoritative list
    [self refreshVoicesFromServer];
}

// ---------------------------------------------------------------------------
#pragma mark - My Voices: server fetch
// ---------------------------------------------------------------------------

- (void)refreshVoicesTapped:(id)sender {
    [self refreshVoicesFromServer];
}

- (void)refreshVoicesFromServer {
    NSString *jwt = [self userJWT];
    if (jwt.length == 0) return; // not signed in — silently skip

    self.refreshVoicesButton.hidden = YES;
    [self.voicesSpinner startAnimating];

    __weak typeof(self) weakSelf = self;
    NSDictionary *payload = @{ @"action": @"fetch_voices" };
    [self callEZElevenLabs:payload jwt:jwt
               completion:^(NSDictionary *responseDict, NSInteger statusCode, NSError *networkError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.refreshVoicesButton.hidden = NO;
            [weakSelf.voicesSpinner stopAnimating];
            if (networkError || statusCode < 200 || statusCode >= 300) return;

            NSArray *voices = responseDict[@"voices"];
            if (![voices isKindOfClass:[NSArray class]]) return;

            NSMutableArray *cloned = [NSMutableArray array];
            for (NSDictionary *v in voices) {
                if (![v isKindOfClass:[NSDictionary class]]) continue;
                NSString *cat = v[@"category"];
                if ([cat isEqualToString:@"cloned"]) {
                    NSDictionary *safeVoice = [weakSelf sanitizedVoiceDictionary:v];
                    if (safeVoice) [cloned addObject:safeVoice];
                }
            }
            weakSelf.myVoices = cloned;
            weakSelf.visibleVoiceRowCount = MIN((NSUInteger)40, cloned.count);
            [[NSUserDefaults standardUserDefaults] setObject:cloned
                                                     forKey:kMyVoicesDefaultsKey];
            [weakSelf rebuildVoiceRows];
        });
    }];
}

- (id)plistSafeObject:(id)obj {
    if (!obj || obj == (id)kCFNull) return nil;
    if ([obj isKindOfClass:NSString.class] ||
        [obj isKindOfClass:NSNumber.class] ||
        [obj isKindOfClass:NSData.class] ||
        [obj isKindOfClass:NSDate.class]) {
        return obj;
    }
    if ([obj isKindOfClass:NSArray.class]) {
        NSMutableArray *safeArray = [NSMutableArray array];
        for (id item in (NSArray *)obj) {
            id safeItem = [self plistSafeObject:item];
            if (safeItem) [safeArray addObject:safeItem];
        }
        return safeArray;
    }
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *safeDict = [NSMutableDictionary dictionary];
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if (![key isKindOfClass:NSString.class]) return;
            id safeValue = [self plistSafeObject:value];
            if (safeValue) safeDict[key] = safeValue;
        }];
        return safeDict;
    }
    return [obj description];
}

- (NSDictionary *)sanitizedVoiceDictionary:(id)voice {
    if (![voice isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *safe = [self plistSafeObject:voice];
    if (![safe isKindOfClass:NSDictionary.class]) return nil;

    NSMutableDictionary *mutableSafe = [safe mutableCopy];
    NSString *voiceID = [mutableSafe[@"voice_id"] isKindOfClass:NSString.class]
        ? mutableSafe[@"voice_id"]
        : ([mutableSafe[@"id"] isKindOfClass:NSString.class] ? mutableSafe[@"id"] : @"");
    if (voiceID.length == 0) return nil;

    NSString *name = [mutableSafe[@"name"] isKindOfClass:NSString.class]
        ? mutableSafe[@"name"]
        : NSLocalizedString(@"ElevenLabsClone.UnnamedVoice", @"Fallback voice name");
    NSString *category = [mutableSafe[@"category"] isKindOfClass:NSString.class]
        ? mutableSafe[@"category"]
        : @"";

    return @{
        @"voice_id": voiceID,
        @"name": name,
        @"category": category
    };
}

// ---------------------------------------------------------------------------
#pragma mark - My Voices: UI rows
// ---------------------------------------------------------------------------

- (void)rebuildVoiceRows {
    for (UIView *sub in self.voicesContainerView.subviews)
        [sub removeFromSuperview];

    CGFloat vw = self.view.bounds.size.width;
    CGFloat m  = 20.0;
    CGFloat w  = vw - m * 2.0;
    CGFloat y  = 0;

    if (self.myVoices.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w, 52)];
        empty.text = NSLocalizedString(@"ElevenLabsClone.NoClonedVoices", @"Empty cloned voices list message");
        empty.font = [UIFont systemFontOfSize:13];
        empty.textColor = [UIColor secondaryLabelColor];
        empty.numberOfLines = 2;
        [self.voicesContainerView addSubview:empty];
        y += 60;
    } else {
        NSUInteger visibleCount = MIN(self.visibleVoiceRowCount, self.myVoices.count);
        for (NSUInteger i = 0; i < visibleCount; i++) {
            UIView *row = [self makeVoiceRow:self.myVoices[i]
                                       index:i
                                       width:vw];
            row.frame = CGRectMake(0, y, vw, 54);
            [self.voicesContainerView addSubview:row];
            y += 54;

            if (i < visibleCount - 1) {
                UIView *sep = [[UIView alloc]
                    initWithFrame:CGRectMake(m, y, w, 0.5)];
                sep.backgroundColor = [UIColor separatorColor];
                [self.voicesContainerView addSubview:sep];
                y += 0.5;
            }
        }

        if (visibleCount < self.myVoices.count) {
            UILabel *moreLabel = [[UILabel alloc] initWithFrame:CGRectMake(m, y + 4, w, 18)];
            moreLabel.text = [NSString stringWithFormat:NSLocalizedString(@"ElevenLabsClone.ShowingVoicesFormat", @"Visible cloned voices count format"),
                              (unsigned long)visibleCount,
                              (unsigned long)self.myVoices.count];
            moreLabel.font = [UIFont systemFontOfSize:12];
            moreLabel.textColor = [UIColor secondaryLabelColor];
            [self.voicesContainerView addSubview:moreLabel];
            y += 26;

            UIButton *moreButton = [self makeOutlineButton:NSLocalizedString(@"ElevenLabsClone.ShowMoreVoices", @"Show more cloned voices button")
                                                     frame:CGRectMake(m, y, w, 40)
                                                    action:@selector(showMoreVoicesTapped:)];
            [self.voicesContainerView addSubview:moreButton];
            y += 48;
        }
        y += 8;
    }

    self.voicesContainerView.frame =
        CGRectMake(0, self.voicesContainerY, vw, y);
    self.scrollView.contentSize =
        CGSizeMake(vw, self.voicesContainerY + y + 24);
}

- (void)showMoreVoicesTapped:(id)sender {
    if (self.visibleVoiceRowCount >= self.myVoices.count) return;
    self.visibleVoiceRowCount = MIN(self.visibleVoiceRowCount + 40, self.myVoices.count);
    [self rebuildVoiceRows];
}

- (UIView *)makeVoiceRow:(NSDictionary *)voice
                   index:(NSUInteger)index
                   width:(CGFloat)vw {
    CGFloat m   = 20.0;
    CGFloat delW = 72.0;
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, vw, 54)];

    NSString *name    = voice[@"name"] ?: NSLocalizedString(@"ElevenLabsClone.UnnamedVoice", @"Fallback voice name");
    NSString *voiceID = voice[@"voice_id"] ?: voice[@"id"] ?: @"";
    NSString *cat     = voice[@"category"] ?: @"";

    UILabel *nameLbl = [[UILabel alloc]
        initWithFrame:CGRectMake(m, 7, vw - m * 2 - delW - 8, 20)];
    nameLbl.text = name;
    nameLbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    nameLbl.numberOfLines = 1;
    nameLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    [row addSubview:nameLbl];

    // Show a truncated voice ID + category tag
    NSString *shortID = voiceID.length > 14
        ? [NSString stringWithFormat:@"%@…", [voiceID substringToIndex:14]]
        : voiceID;
    UILabel *detailLbl = [[UILabel alloc]
        initWithFrame:CGRectMake(m, 29, vw - m * 2 - delW - 8, 16)];
    detailLbl.text = cat.length
        ? [NSString stringWithFormat:@"%@  ·  %@", shortID, cat]
        : shortID;
    detailLbl.font = [UIFont systemFontOfSize:11];
    detailLbl.textColor = [UIColor secondaryLabelColor];
    detailLbl.numberOfLines = 1;
    detailLbl.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [row addSubview:detailLbl];

    UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
    del.frame = CGRectMake(vw - m - delW, 11, delW, 32);
    [del setTitle:NSLocalizedString(@"ElevenLabsClone.Delete", @"Delete voice button") forState:UIControlStateNormal];
    [del setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    del.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    del.layer.cornerRadius = 6;
    del.layer.borderWidth  = 0.5;
    del.layer.borderColor  = [UIColor systemRedColor].CGColor;
    del.tag = (NSInteger)index;
    [del addTarget:self
            action:@selector(deleteVoiceTapped:)
  forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:del];

    return row;
}

- (void)deleteVoiceTapped:(UIButton *)sender {
    NSUInteger index = (NSUInteger)sender.tag;
    if (index >= self.myVoices.count) return;

    NSDictionary *voice   = self.myVoices[index];
    NSString *displayName = voice[@"name"] ?: NSLocalizedString(@"ElevenLabsClone.ThisVoice", @"Fallback voice reference");
    NSString *voiceID     = voice[@"voice_id"] ?: voice[@"id"];

    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:NSLocalizedString(@"ElevenLabsClone.DeleteVoice", @"Delete voice confirmation title")
                                            message:[NSString stringWithFormat:
                                                     NSLocalizedString(@"ElevenLabsClone.DeleteVoiceMessage", @"Delete voice confirmation message format"),
                                                     displayName]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"ElevenLabsClone.Cancel", @"Cancel deletion button")
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"ElevenLabsClone.Delete", @"Delete voice button")
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action) {
        [self deleteVoiceWithID:voiceID atIndex:index];
    }]];
    [self presentViewControllerSafely:ac animated:NO retryCount:8];
}

- (void)deleteVoiceWithID:(NSString *)voiceID atIndex:(NSUInteger)index {
    NSString *jwt = [self userJWT];
    if (jwt.length == 0) {
        [self showAlert:NSLocalizedString(@"ElevenLabsClone.NotSignedIn", @"Not signed in alert title")
                message:NSLocalizedString(@"ElevenLabsClone.SignInDeleteMessage", @"Sign in to delete alert message")];
        return;
    }
    if (index >= self.myVoices.count) return;

    // Optimistic removal — restore on server error
    NSDictionary *removed = self.myVoices[index];
    [self.myVoices removeObjectAtIndex:index];
    [self rebuildVoiceRows];

    __weak typeof(self) weakSelf = self;
    NSDictionary *payload = @{ @"action": @"delete_voice", @"voice_id": voiceID };
    [self callEZElevenLabs:payload jwt:jwt
               completion:^(NSDictionary *responseDict, NSInteger statusCode, NSError *networkError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = (!networkError && statusCode >= 200 && statusCode < 300);
            if (!ok) {
                // Roll back optimistic removal
                NSUInteger restoreAt = MIN(index, weakSelf.myVoices.count);
                [weakSelf.myVoices insertObject:removed atIndex:restoreAt];
                [weakSelf rebuildVoiceRows];
                NSString *msg = networkError.localizedDescription
                    ?: responseDict[@"reason"] ?: responseDict[@"error"] ?: NSLocalizedString(@"ElevenLabsClone.DeleteFailedMessage", @"Delete failure fallback message");
                [weakSelf showAlert:NSLocalizedString(@"ElevenLabsClone.DeleteFailed", @"Delete failed alert title") message:msg];
                EZLogf(EZLogLevelError, @"DEL", @"Delete voice %@ failed: %@", voiceID, msg);
            } else {
                [[NSUserDefaults standardUserDefaults]
                    setObject:weakSelf.myVoices forKey:kMyVoicesDefaultsKey];
                EZLogf(EZLogLevelInfo, @"DEL", @"Deleted voice %@", voiceID);
            }
        });
    }];
}

// ---------------------------------------------------------------------------
#pragma mark - Shared helpers
// ---------------------------------------------------------------------------

- (NSString *)urlEncode:(NSString *)s {
    return [s stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLPathAllowedCharacterSet]];
}

+ (NSString *)prettyAPIErrMsgFromData:(NSData *)data
                           defaultMsg:(NSString *)fallback {
    if (!data.length) return fallback;
    NSError *jsonErr = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    if (!jsonErr && [obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = (NSDictionary *)obj;
        id detail = d[@"detail"];
        NSString *detailMsg = nil;
        if ([detail isKindOfClass:NSDictionary.class]) {
            detailMsg = ((NSDictionary *)detail)[@"message"]
                     ?: ((NSDictionary *)detail)[@"detail"];
        } else if ([detail isKindOfClass:NSString.class]) {
            detailMsg = (NSString *)detail;
        }
        NSString *msg = d[@"message"] ?: d[@"error"] ?: detailMsg;
        if ([msg isKindOfClass:NSString.class] && ((NSString *)msg).length)
            return (NSString *)msg;
    }
    NSString *raw = [[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding];
    return raw.length ? raw : fallback;
}

@end
