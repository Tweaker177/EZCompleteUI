// Objective-C  ElevenLabsCloneViewController.m
// Complete, compiler-ready drop-in replacement.
// - Records 48kHz / 16-bit mono WAV
// - Live elapsed timer + rolling waveform while recording
// - Playback transport: Play/Pause/Stop/Skip ±10s
// - Import audio via Files (UIDocumentPicker)
// - One-time Quick Look preview after capture/import + button to open again
// - IVC upload (POST /v1/voices/add) and PVC create + sample upload
// - Robust error handling, logging, and UI state management

#import "ElevenLabsCloneViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <QuickLook/QuickLook.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "EZKeyVault.h"
#import "helpers.h"

#pragma mark - Lightweight waveform view

@interface WaveformView : UIView
@property (nonatomic, strong) NSMutableArray<NSNumber *> *levels;
@property (nonatomic) NSUInteger maxSamples;
- (void)reset;
- (void)addLevel:(CGFloat)level; // 0..1
@end

@implementation WaveformView
- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        _levels = [NSMutableArray array];
        _maxSamples = 200; // ~10s @20Hz; adjust to taste
        self.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.isAccessibilityElement = NO;
    }
    return self;
}
- (void)reset {
    [self.levels removeAllObjects];
    [self setNeedsDisplay];
}
- (void)addLevel:(CGFloat)level {
    CGFloat clamped = MAX(0.0, MIN(1.0, level));
    [self.levels addObject:@(clamped)];
    if (self.levels.count > self.maxSamples) {
        [self.levels removeObjectAtIndex:0];
    }
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    CGFloat w = rect.size.width, h = rect.size.height;
    NSUInteger n = self.levels.count; if (n == 0) return;
    CGFloat barW = MAX(1.0, w / (CGFloat)self.maxSamples);
    CGFloat x = w - n * barW; // right-align the rolling waveform
    for (NSNumber *num in self.levels) {
        CGFloat v = num.floatValue; // 0..1
        CGFloat barH = MAX(2.0, v * h);
        CGRect bar = CGRectMake(x, (h - barH)/2.0, barW - 1.0, barH);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:1.0];
        [[UIColor systemBlueColor] setFill];
        [p fill];
        x += barW;
    }
}
@end

#pragma mark - Controller

@interface ElevenLabsCloneViewController () <AVAudioRecorderDelegate, AVAudioPlayerDelegate, UITextFieldDelegate, QLPreviewControllerDataSource, QLPreviewControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *langField;
@property (nonatomic, strong) UISegmentedControl *modeControl; // 0=Instant (IVC) 1=Pro (PVC)
@property (nonatomic, strong) UISwitch *noiseSwitch; // remove_background_noise
@property (nonatomic, strong) UIButton *recordButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *uploadButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@property (nonatomic, strong) UILabel *recordTimerLabel;
@property (nonatomic, strong) WaveformView *waveformView;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UIButton *skipBackButton;
@property (nonatomic, strong) UIButton *skipFwdButton;
@property (nonatomic, strong) UIButton *quickLookButton;
@property (nonatomic, strong) UIButton *chooseFileButton;

@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSURL *recordedFileURL;

@property (nonatomic, copy) NSString *createdPVCVoiceID; // remember last created PVC voice
@property (nonatomic, strong) NSTimer *meterTimer;
@property (nonatomic) BOOL hasShownQuickLookForCurrentFile;
@end

@implementation ElevenLabsCloneViewController

#pragma mark - Lifecycle / UI

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Voice Cloner";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // Scroll view host (keeps layout safe under nav bars, keyboards, rotations)
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scrollView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tap.cancelsTouchesInView = NO;
    [self.scrollView addGestureRecognizer:tap];

    CGFloat m = 20, w = self.view.bounds.size.width - m*2, y = 16;

    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w, 22)];
    titleLbl.text = @"Record or import audio, then upload for cloning.";
    titleLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [self.scrollView addSubview:titleLbl];
    y += 30;

    self.nameField = [[UITextField alloc] initWithFrame:CGRectMake(m, y, w, 36)];
    self.nameField.placeholder = @"Voice name (e.g., MyProVoice)";
    self.nameField.borderStyle = UITextBorderStyleRoundedRect;
    self.nameField.delegate = self;
    [self.scrollView addSubview:self.nameField];
    y += 44;

    self.langField = [[UITextField alloc] initWithFrame:CGRectMake(m, y, w, 36)];
    self.langField.placeholder = @"Language code (e.g., en)";
    self.langField.borderStyle = UITextBorderStyleRoundedRect;
    self.langField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.langField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.langField.text = @"en";
    [self.scrollView addSubview:self.langField];
    y += 44;

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Instant (IVC)", @"Professional (PVC)"]];
    self.modeControl.frame = CGRectMake(m, y, w, 32);
    self.modeControl.selectedSegmentIndex = 0; // default to IVC
    [self.modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.modeControl];
    y += 38;

    UILabel *pvcInfoLbl = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w, 30)];
    pvcInfoLbl.numberOfLines = 0;
    pvcInfoLbl.text = @"⚠️ PVC requires a Creator plan or higher.";
    pvcInfoLbl.font = [UIFont systemFontOfSize:11];
    pvcInfoLbl.textColor = [UIColor secondaryLabelColor];
    [self.scrollView addSubview:pvcInfoLbl];
    y += 36;

    UILabel *noiseLbl = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w-60, 24)];
    noiseLbl.text = @"Remove background noise";
    noiseLbl.font = [UIFont systemFontOfSize:13];
    [self.scrollView addSubview:noiseLbl];

    self.noiseSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(m+w-60, y-4, 60, 32)];
    [self.scrollView addSubview:self.noiseSwitch];
    y += 40;

    self.recordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.recordButton.frame = CGRectMake(m, y, w, 48);
    [self.recordButton setTitle:@"Start Recording" forState:UIControlStateNormal];
    self.recordButton.layer.cornerRadius = 8;
    self.recordButton.backgroundColor = [UIColor systemRedColor];
    [self.recordButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.recordButton addTarget:self action:@selector(toggleRecord:) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.recordButton];
    y += 56;

    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playButton.frame = CGRectMake(m, y, w, 44);
    [self.playButton setTitle:@"Play Recording" forState:UIControlStateNormal];
    self.playButton.layer.cornerRadius = 8;
    self.playButton.backgroundColor = [UIColor systemFillColor];
    [self.playButton addTarget:self action:@selector(playRecording:) forControlEvents:UIControlEventTouchUpInside];
    self.playButton.enabled = NO;
    [self.scrollView addSubview:self.playButton];
    y += 52;

    self.chooseFileButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.chooseFileButton.frame = CGRectMake(m, y, w, 44);
    [self.chooseFileButton setTitle:@"📂 Choose Audio File…" forState:UIControlStateNormal];
    self.chooseFileButton.layer.cornerRadius = 8;
    self.chooseFileButton.backgroundColor = [UIColor systemGray5Color];
    [self.chooseFileButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.chooseFileButton.layer.borderWidth = 0.5;
    self.chooseFileButton.layer.borderColor = [UIColor systemGray3Color].CGColor;
    [self.chooseFileButton addTarget:self action:@selector(pickAudioFile:) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.chooseFileButton];
    y += 52;

    self.uploadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.uploadButton.frame = CGRectMake(m, y, w, 50);
    [self.uploadButton setTitle:@"Upload & Clone Voice" forState:UIControlStateNormal];
    self.uploadButton.layer.cornerRadius = 8;
    self.uploadButton.backgroundColor = [UIColor systemBlueColor];
    [self.uploadButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.uploadButton addTarget:self action:@selector(uploadClone:) forControlEvents:UIControlEventTouchUpInside];
    self.uploadButton.enabled = NO;
    [self.scrollView addSubview:self.uploadButton];
    y += 58;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(self.view.center.x, y);
    self.spinner.hidesWhenStopped = YES;
    [self.scrollView addSubview:self.spinner];

    // Timer label (elapsed recording/playback)
    y += 16;
    self.recordTimerLabel = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w, 20)];
    self.recordTimerLabel.text = @"00:00";
    self.recordTimerLabel.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
    self.recordTimerLabel.textAlignment = NSTextAlignmentCenter;
    [self.scrollView addSubview:self.recordTimerLabel];
    y += 26;

    // Waveform
    self.waveformView = [[WaveformView alloc] initWithFrame:CGRectMake(m, y, w, 60)];
    self.waveformView.layer.cornerRadius = 8;
    self.waveformView.clipsToBounds = YES;
    [self.scrollView addSubview:self.waveformView];
    y += 68;

    // Playback controls row: ⏪, ▶︎, ⏸, ⏹, ⏩
    CGFloat gap = 12.0;
    CGFloat btnW = (w - gap*4)/5.0;

    self.skipBackButton = [self makeControlButton:@"⏪ -10s" frame:CGRectMake(m + (btnW+gap)*0, y, btnW, 40) action:@selector(skipBack:)];
    [self.scrollView addSubview:self.skipBackButton];

    // Reposition the existing play button in the control row
    self.playButton.frame = CGRectMake(m + (btnW+gap)*1, y, btnW, 40);
    [self.playButton setTitle:@"▶︎ Play" forState:UIControlStateNormal];

    self.pauseButton = [self makeControlButton:@"⏸ Pause" frame:CGRectMake(m + (btnW+gap)*2, y, btnW, 40) action:@selector(pausePlayback:)];
    [self.scrollView addSubview:self.pauseButton];

    self.stopButton = [self makeControlButton:@"⏹ Stop" frame:CGRectMake(m + (btnW+gap)*3, y, btnW, 40) action:@selector(stopPlayback:)];
    [self.scrollView addSubview:self.stopButton];

    self.skipFwdButton = [self makeControlButton:@"⏩ +10s" frame:CGRectMake(m + (btnW+gap)*4, y, btnW, 40) action:@selector(skipFwd:)];
    [self.scrollView addSubview:self.skipFwdButton];
    y += 48;

    // Quick Look button
    self.quickLookButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.quickLookButton.frame = CGRectMake(m, y, w, 44);
    [self.quickLookButton setTitle:@"Quick Look Recording" forState:UIControlStateNormal];
    self.quickLookButton.layer.cornerRadius = 8;
    self.quickLookButton.backgroundColor = [UIColor systemGray5Color];
    [self.quickLookButton addTarget:self action:@selector(showQuickLook:) forControlEvents:UIControlEventTouchUpInside];
    self.quickLookButton.enabled = NO;
    [self.scrollView addSubview:self.quickLookButton];
    y += 52;

    // Final content size
    self.scrollView.contentSize = CGSizeMake(self.view.bounds.size.width, y + 20);
}

#pragma mark - UI helpers

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)modeChanged:(UISegmentedControl *)seg {
    // Currently informational only; uploadClone: decides which flow to use
    EZLogf(EZLogLevelInfo, @"ELEVEN", @"Mode changed to %@", seg.selectedSegmentIndex == 0 ? @"IVC" : @"PVC");
}

- (UIButton *)makeControlButton:(NSString *)title frame:(CGRect)frame action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = frame;
    [b setTitle:title forState:UIControlStateNormal];
    b.layer.cornerRadius = 8;
    b.backgroundColor = [UIColor systemFillColor];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    b.enabled = NO;
    return b;
}

- (void)setLoading:(BOOL)loading {
    if (loading) { [self.spinner startAnimating]; } else { [self.spinner stopAnimating]; }
    self.view.userInteractionEnabled = !loading;
    self.navigationItem.hidesBackButton = loading;
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Recording

- (void)toggleRecord:(id)sender {
    if (!self.recorder || !self.recorder.isRecording) {
        [self startRecording];
    } else {
        [self stopRecording];
    }
}

- (void)startRecording {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;

    // Request permission if needed
    if (session.recordPermission == AVAudioSessionRecordPermissionUndetermined) {
        [session requestRecordPermission:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) { [self startRecording]; }
                else { [self showAlert:@"Microphone Access Denied" message:@"Enable microphone access in Settings to record."]; }
            });
        }];
        return;
    }
    if (session.recordPermission != AVAudioSessionRecordPermissionGranted) {
        [self showAlert:@"Microphone Access Denied" message:@"Enable microphone access in Settings to record."];
        return;
    }

    [session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeMeasurement options:AVAudioSessionCategoryOptionDefaultToSpeaker error:&err];
    if (err) { EZLogf(EZLogLevelError, @"REC", @"Session setCategory error: %@", err.localizedDescription); }

    [session setActive:YES error:&err];
    if (err) { EZLogf(EZLogLevelError, @"REC", @"Session activate error: %@", err.localizedDescription); }

    // 48kHz 16-bit mono WAV-friendly
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @48000,
        AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVEncoderAudioQualityKey: @(AVAudioQualityHigh)
    };

    NSString *fn = [NSString stringWithFormat:@"clone_sample_%@.wav", @((long)NSDate.date.timeIntervalSince1970)];
    NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fn]];

    self.recorder = [[AVAudioRecorder alloc] initWithURL:fileURL settings:settings error:&err];
    self.recorder.delegate = self;
    self.recorder.meteringEnabled = YES;

    if (err || ![self.recorder prepareToRecord]) {
        NSString *msg = err.localizedDescription ?: @"Recorder prepare failed.";
        EZLogf(EZLogLevelError, @"REC", @"Prepare failed: %@", msg);
        [self showAlert:@"Record error" message:msg];
        return;
    }

    [self.recorder record];
    self.recordedFileURL = fileURL;
    self.hasShownQuickLookForCurrentFile = NO;
    self.recordTimerLabel.text = @"00:00";
    [self.waveformView reset];
    [self startMeterTimer];

    [self.recordButton setTitle:@"Stop Recording" forState:UIControlStateNormal];
    self.recordButton.backgroundColor = [UIColor systemGrayColor];

    // Disable playback/QL while recording
    self.playButton.enabled = NO;
    self.pauseButton.enabled = NO;
    self.stopButton.enabled = NO;
    self.skipBackButton.enabled = NO;
    self.skipFwdButton.enabled = NO;
    self.quickLookButton.enabled = NO;
    self.uploadButton.enabled = NO;

    EZLogf(EZLogLevelInfo, @"REC", @"Recording to %@", fileURL.lastPathComponent);
}

- (void)stopRecording {
    [self.recorder stop];
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
    [self.recordButton setTitle:@"Start Recording" forState:UIControlStateNormal];
    self.recordButton.backgroundColor = [UIColor systemRedColor];

    [self stopMeterTimer];

    // Enable playback and actions
    BOOL hasFile = (self.recordedFileURL != nil);
    self.playButton.enabled = hasFile;
    self.pauseButton.enabled = hasFile;
    self.stopButton.enabled = hasFile;
    self.skipBackButton.enabled = hasFile;
    self.skipFwdButton.enabled = hasFile;
    self.uploadButton.enabled = hasFile;
    self.quickLookButton.enabled = hasFile;

    // Auto-open once in Quick Look
    if (hasFile && !self.hasShownQuickLookForCurrentFile) {
        self.hasShownQuickLookForCurrentFile = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showQuickLook:nil];
        });
    }
    EZLog(EZLogLevelInfo, @"REC", @"Stopped recording");
}

- (void)playRecording:(id)sender {
    if (!self.recordedFileURL) return;
    NSError *err = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:self.recordedFileURL error:&err];
    if (err) { [self showAlert:@"Play error" message:err.localizedDescription]; return; }
    self.player.delegate = self;
    self.player.meteringEnabled = YES;
    [self.player prepareToPlay];
    [self.player play];
    [self startMeterTimer];

    // Ensure controls are enabled during playback
    self.pauseButton.enabled = YES;
    self.stopButton.enabled = YES;
    self.skipBackButton.enabled = YES;
    self.skipFwdButton.enabled = YES;
}

- (void)pausePlayback:(id)sender {
    [self.player pause];
}

- (void)stopPlayback:(id)sender {
    [self.player stop];
    self.player.currentTime = 0;
    self.recordTimerLabel.text = @"00:00";
    [self stopMeterTimer];
}

- (void)skipBack:(id)sender {
    if (!self.player) return;
    self.player.currentTime = MAX(0, self.player.currentTime - 10.0);
}

- (void)skipFwd:(id)sender {
    if (!self.player) return;
    self.player.currentTime = MIN(self.player.duration, self.player.currentTime + 10.0);
}

#pragma mark - Metering / Timer

- (void)startMeterTimer {
    [self.meterTimer invalidate];
    self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(tickMeter) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.meterTimer forMode:NSRunLoopCommonModes];
}

- (void)stopMeterTimer {
    [self.meterTimer invalidate];
    self.meterTimer = nil;
}

- (void)tickMeter {
    if (self.recorder && self.recorder.isRecording) {
        [self.recorder updateMeters];
        float avg = [self.recorder averagePowerForChannel:0]; // dBFS [-160..0]
        float level = powf(10.0f, 0.05f * avg); // linear [0..1]
        [self.waveformView addLevel:level];
        self.recordTimerLabel.text = [self mmssFromTime:self.recorder.currentTime];
    } else if (self.player && self.player.isPlaying) {
        [self.player updateMeters];
        self.recordTimerLabel.text = [self mmssFromTime:self.player.currentTime];
        // To also visualize playback, uncomment:
        // float avg = [self.player averagePowerForChannel:0];
        // [self.waveformView addLevel:powf(10.0f, 0.05f * avg)];
    }
}

- (NSString *)mmssFromTime:(NSTimeInterval)t {
    NSInteger ti = (NSInteger)floor(t + 0.5);
    NSInteger m = ti / 60, s = ti % 60;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)m, (long)s];
}

#pragma mark - AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    [self stopMeterTimer];
}

#pragma mark - Quick Look

- (void)showQuickLook:(id)sender {
    if (!self.recordedFileURL) {
        [self showAlert:@"No recording" message:@"Please record or import a sample first."];
        return;
    }
    QLPreviewController *ql = [QLPreviewController new];
    ql.dataSource = self;
    ql.delegate = self;
    [self presentViewController:ql animated:YES completion:nil];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return self.recordedFileURL ? 1 : 0;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return self.recordedFileURL;
}

#pragma mark - File picking (import)

- (void)pickAudioFile:(id)sender {
    NSArray<UTType *> *types = @[UTTypeAudio, UTTypeWAV, UTTypeMPEG4Audio];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    // Security-scoped resource handling
    BOOL needsRelease = [url startAccessingSecurityScopedResource];
    @try {
        // Copy to a temp location with .wav or original extension
        NSString *ext = url.pathExtension.length ? url.pathExtension : @"wav";
        NSString *fn = [NSString stringWithFormat:@"picked_%@.%@", @((long)NSDate.date.timeIntervalSince1970), ext];
        NSURL *dest = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fn]];

        NSError *err = nil;
        if ([NSFileManager.defaultManager fileExistsAtPath:dest.path]) {
            [NSFileManager.defaultManager removeItemAtURL:dest error:nil];
        }
        BOOL ok = [NSFileManager.defaultManager copyItemAtURL:url toURL:dest error:&err];
        if (!ok || err) {
            EZLogf(EZLogLevelError, @"PICK", @"Copy failed: %@", err.localizedDescription);
            [self showAlert:@"Import Failed" message:err.localizedDescription ?: @"Unable to import the selected file."];
            return;
        }

        self.recordedFileURL = dest;
        self.hasShownQuickLookForCurrentFile = NO;

        // Enable actions
        BOOL hasFile = (self.recordedFileURL != nil);
        self.playButton.enabled = hasFile;
        self.pauseButton.enabled = hasFile;
        self.stopButton.enabled = hasFile;
        self.skipBackButton.enabled = hasFile;
        self.skipFwdButton.enabled = hasFile;
        self.uploadButton.enabled = hasFile;
        self.quickLookButton.enabled = hasFile;

        // Auto preview once
        if (hasFile && !self.hasShownQuickLookForCurrentFile) {
            self.hasShownQuickLookForCurrentFile = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showQuickLook:nil];
            });
        }
        EZLogf(EZLogLevelInfo, @"PICK", @"Imported audio to %@", dest.lastPathComponent);
    } @finally {
        if (needsRelease) { [url stopAccessingSecurityScopedResource]; }
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    EZLog(EZLogLevelInfo, @"PICK", @"User canceled document picker");
}

#pragma mark - Upload / Clone

- (NSString *)apiKey {
    NSString *k = [EZKeyVault loadKeyForIdentifier:EZVaultKeyElevenLabs];
    return k ?: @"";
}

- (void)uploadClone:(id)sender {
    if (!self.recordedFileURL) { [self showAlert:@"No recording" message:@"Please record or import a sample first."]; return; }
    if (self.nameField.text.length == 0) { [self showAlert:@"Missing name" message:@"Enter a voice name."]; return; }

    NSString *apiKey = [self apiKey];
    if (apiKey.length == 0) { [self showAlert:@"Missing API Key" message:@"Set your ElevenLabs API key in Settings."]; return; }

    [self setLoading:YES];

    if (self.modeControl.selectedSegmentIndex == 0) {
        // IVC: /v1/voices/add
        [self uploadIVCWithAPIKey:apiKey completion:^(NSString *voiceID, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setLoading:NO];
                if (err) {
                    [self showAlert:@"IVC upload failed" message:err.localizedDescription];
                    EZLogf(EZLogLevelError, @"IVC", @"Upload failed: %@", err);
                    return;
                }
                [self showAlert:@"Instant Clone Created" message:[NSString stringWithFormat:@"Voice ID: %@", voiceID]];
                EZLogf(EZLogLevelInfo, @"IVC", @"Created IVC voice %@", voiceID);
            });
        }];
    } else {
        // PVC: create, then upload sample
        [self createPVCWithAPIKey:apiKey completion:^(NSString *voiceID, NSError *err) {
            if (err || voiceID.length == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setLoading:NO];
                    [self showAlert:@"PVC create failed" message:err.localizedDescription ?: @"No voice id returned."];
                    EZLogf(EZLogLevelError, @"PVC", @"Create failed: %@", err ?: @"No voice id");
                });
                return;
            }
            self.createdPVCVoiceID = voiceID;
            [self uploadPVCSampleWithAPIKey:apiKey voiceID:voiceID completion:^(NSError *uErr) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setLoading:NO];
                    if (uErr) {
                        [self showAlert:@"PVC sample upload failed" message:uErr.localizedDescription];
                        EZLogf(EZLogLevelError, @"PVC", @"Sample upload failed for %@: %@", voiceID, uErr);
                        return;
                    }
                    [self showAlert:@"PVC Voice Updated" message:[NSString stringWithFormat:@"Voice ID: %@\nNext: complete verification and training.", voiceID]];
                    EZLogf(EZLogLevelInfo, @"PVC", @"Uploaded sample to PVC voice %@", voiceID);
                });
            }];
        }];
    }
}

#pragma mark IVC: POST /v1/voices/add (multipart: files, name, remove_background_noise?)

- (void)uploadIVCWithAPIKey:(NSString *)apiKey completion:(void(^)(NSString *voiceID, NSError *err))completion {
    // Validate file
    if (!self.recordedFileURL || ![NSFileManager.defaultManager fileExistsAtPath:self.recordedFileURL.path]) {
        completion(nil, [NSError errorWithDomain:@"VoiceCloner" code:-10 userInfo:@{NSLocalizedDescriptionKey: @"No recorded file on disk."}]);
        return;
    }
    NSData *fileData = [NSData dataWithContentsOfURL:self.recordedFileURL];
    if (fileData.length == 0) {
        completion(nil, [NSError errorWithDomain:@"VoiceCloner" code:-11 userInfo:@{NSLocalizedDescriptionKey: @"Recorded file is empty."}]);
        return;
    }

    NSString *endpoint = @"https://api.elevenlabs.io/v1/voices/add";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    [req setValue:apiKey forHTTPHeaderField:@"xi-api-key"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSString *boundary = [NSUUID UUID].UUIDString;
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];

    NSMutableData *body = [NSMutableData data];

    // name
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"name\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *voiceName = [self.nameField.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [body appendData:[(voiceName.length ? voiceName : @"My Voice") dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // remove_background_noise
    NSString *rbn = self.noiseSwitch.isOn ? @"true" : @"false";
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"remove_background_noise\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[rbn dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // files (not files[])
    NSString *filename = self.recordedFileURL.lastPathComponent ?: @"sample.wav";
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"files\"; filename=\"%@\"\r\n", filename] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: audio/wav\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:fileData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // end
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
        if (hr.statusCode < 200 || hr.statusCode >= 300) {
            NSString *msg = [self.class prettyAPIErrMsgFromData:data defaultMsg:@"Server error"];
            NSError *e = [NSError errorWithDomain:@"VoiceCloner" code:hr.statusCode userInfo:@{NSLocalizedDescriptionKey: msg}];
            completion(nil, e); return;
        }
        NSError *jsonErr = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr || ![obj isKindOfClass:NSDictionary.class]) {
            completion(nil, jsonErr ?: [NSError errorWithDomain:@"VoiceCloner" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response"}]);
            return;
        }
        NSDictionary *dict = (NSDictionary *)obj;
        NSString *voiceID = dict[@"voice_id"] ?: dict[@"voiceId"] ?: dict[@"id"];
        if (!voiceID) {
            completion(nil, [NSError errorWithDomain:@"VoiceCloner" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"No voice_id in response"}]);
            return;
        }
        completion(voiceID, nil);
    }] resume];
}

#pragma mark PVC: POST /v1/voices/pvc (JSON: {name, language})

- (void)createPVCWithAPIKey:(NSString *)apiKey completion:(void(^)(NSString *voiceID, NSError *err))completion {
    NSString *endpoint = @"https://api.elevenlabs.io/v1/voices/pvc";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    [req setValue:apiKey forHTTPHeaderField:@"xi-api-key"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSString *name = [self.nameField.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *lang = [self.langField.text ?: @"en" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSDictionary *payload = @{@"name": name.length ? name : @"MyProVoice",
                              @"language": lang.length ? lang : @"en"};
    NSError *jsonErr = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonErr];
    if (jsonErr) { completion(nil, jsonErr); return; }
    req.HTTPBody = body;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { completion(nil, error); return; }
        NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
        if (hr.statusCode < 200 || hr.statusCode >= 300) {
            NSString *msg = [self.class prettyAPIErrMsgFromData:data defaultMsg:@"Server error"];
            NSError *e = [NSError errorWithDomain:@"VoiceCloner" code:hr.statusCode userInfo:@{NSLocalizedDescriptionKey: msg}];
            completion(nil, e); return;
        }
        NSError *jsonErr2 = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr2];
        if (jsonErr2 || ![obj isKindOfClass:NSDictionary.class]) {
            completion(nil, jsonErr2 ?: [NSError errorWithDomain:@"VoiceCloner" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response"}]);
            return;
        }
        NSDictionary *dict = (NSDictionary *)obj;
        NSString *voiceID = dict[@"voice_id"] ?: dict[@"id"];
        if (!voiceID) {
            completion(nil, [NSError errorWithDomain:@"VoiceCloner" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"No voice_id in PVC create response"}]);
            return;
        }
        completion(voiceID, nil);
    }] resume];
}

#pragma mark PVC Samples: POST /v1/voices/pvc/:voice_id/samples (multipart: files, remove_background_noise?)

- (void)uploadPVCSampleWithAPIKey:(NSString *)apiKey voiceID:(NSString *)voiceID completion:(void(^)(NSError *err))completion {
    // Validate file
    if (!self.recordedFileURL || ![NSFileManager.defaultManager fileExistsAtPath:self.recordedFileURL.path]) {
        completion([NSError errorWithDomain:@"VoiceCloner" code:-10 userInfo:@{NSLocalizedDescriptionKey: @"No recorded file on disk."}]);
        return;
    }
    NSData *fileData = [NSData dataWithContentsOfURL:self.recordedFileURL];
    if (fileData.length == 0) {
        completion([NSError errorWithDomain:@"VoiceCloner" code:-11 userInfo:@{NSLocalizedDescriptionKey: @"Recorded file is empty."}]);
        return;
    }

    NSString *endpoint = [NSString stringWithFormat:@"https://api.elevenlabs.io/v1/voices/pvc/%@/samples", voiceID];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    [req setValue:apiKey forHTTPHeaderField:@"xi-api-key"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSString *boundary = [NSUUID UUID].UUIDString;
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];

    NSMutableData *body = [NSMutableData data];

    // remove_background_noise
    NSString *rbn = self.noiseSwitch.isOn ? @"true" : @"false";
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"remove_background_noise\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[rbn dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // files (not files[])
    NSString *filename = self.recordedFileURL.lastPathComponent ?: @"sample.wav";
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"files\"; filename=\"%@\"\r\n", filename] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: audio/wav\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:fileData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // end
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { completion(error); return; }
        NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
        if (hr.statusCode < 200 || hr.statusCode >= 300) {
            NSString *msg = [self.class prettyAPIErrMsgFromData:data defaultMsg:@"Server error"];
            NSError *e = [NSError errorWithDomain:@"VoiceCloner" code:hr.statusCode userInfo:@{NSLocalizedDescriptionKey: msg}];
            completion(e); return;
        }
        completion(nil);
    }] resume];
}

#pragma mark - Error message helper

+ (NSString *)prettyAPIErrMsgFromData:(NSData *)data defaultMsg:(NSString *)fallback {
    if (!data.length) return fallback;
    NSString *asString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSError *jsonErr = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    if (!jsonErr && [obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = (NSDictionary *)obj;
        NSString *detailMessage = nil;
        id detail = d[@"detail"];
        if ([detail isKindOfClass:NSDictionary.class]) {
            detailMessage = ((NSDictionary *)detail)[@"message"] ?: ((NSDictionary *)detail)[@"detail"];
        } else if ([detail isKindOfClass:NSString.class]) {
            detailMessage = (NSString *)detail;
        }
        NSString *msg = d[@"message"] ?: d[@"error"] ?: detailMessage;
        if ([msg isKindOfClass:NSString.class] && ((NSString *)msg).length) return (NSString *)msg;
    }
    return asString.length ? asString : fallback;
}

#pragma mark - Cleanup

- (void)dealloc {
    [self.meterTimer invalidate];
}

@end
