//
//  EZTTSClipEditViewController.m
//  EZTTSLibrary
//

#import "EZTTSClipEditViewController.h"
#import "EZTTSLibraryManager.h"
#import "TextToSpeechViewController.h"
#import "EZVoicePickerViewController.h"
#import "EZWaveformRangeSelector.h"
#import "WaveformView.h"
#import "helpers.h"
#import <AVFoundation/AVFoundation.h>

static CGFloat const kEZMinSelectionFractionToShowActions = 0.02;

@interface EZTTSClipEditViewController () <AVAudioPlayerDelegate>

@property (nonatomic, strong) EZTTSManifestEntry *entry;

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UILabel *promptLabel;

// Waveform + range selection — at the top of the screen, directly under the prompt.
@property (nonatomic, strong) UILabel *waveformSectionLabel;
@property (nonatomic, strong) WaveformView *editWaveformView;
@property (nonatomic, strong) EZWaveformRangeSelector *rangeSelector;
@property (nonatomic, strong) UILabel *selectionTimeLabel;
@property (nonatomic, strong) UIButton *insertSilenceButton;
@property (nonatomic, strong) UIButton *normalizeButton;
@property (nonatomic, strong) UIButton *trimButton;
@property (nonatomic, strong) UIActivityIndicatorView *exportSpinner;

// Speed
@property (nonatomic, strong) UILabel *speedSectionLabel;
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UILabel *speedValueLabel;
@property (nonatomic, strong) UIButton *speedPreviewButton;

// Change voice
@property (nonatomic, strong) UILabel *voiceSectionLabel;
@property (nonatomic, strong) UIButton *voiceButton;
@property (nonatomic, strong) UIButton *regenerateWithVoiceButton;
@property (nonatomic, copy) NSString *selectedVoiceID;
@property (nonatomic, copy, nullable) NSString *selectedVoiceName;

@property (nonatomic, strong, nullable) AVAudioPlayer *previewPlayer;

// Effects — apply to the whole clip regardless of the current selection, and always
// save as a new clip (these are creative transformations, not the kind of small
// reversible enhancement Normalize is).
@property (nonatomic, strong) UILabel *effectsSectionLabel;
@property (nonatomic, strong) UILabel *pitchValueLabel;
@property (nonatomic, strong) UISlider *pitchSlider;
@property (nonatomic, strong) UIButton *applyPitchButton;
@property (nonatomic, strong) UIButton *reverbButton;
@property (nonatomic, strong) UIButton *echoButton;
@property (nonatomic, strong) UIButton *eqButton;

@end

@implementation EZTTSClipEditViewController

- (instancetype)initWithEntry:(EZTTSManifestEntry *)entry {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _entry = entry;
        _selectedVoiceID = entry.voiceID ?: @"";
        _selectedVoiceName = entry.voiceName;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Edit Clip";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.scrollView = [[UIScrollView alloc] init];
    [self.view addSubview:self.scrollView];

    self.promptLabel = [self sectionBodyLabel];
    NSString *displayTitle = self.entry.metadata[@"title"];
    self.promptLabel.text = [displayTitle isKindOfClass:[NSString class]] && displayTitle.length > 0
        ? displayTitle : self.entry.prompt;
    [self.scrollView addSubview:self.promptLabel];

    // Waveform sits directly under the prompt text now — it's the most important thing
    // on this screen, so it gets first billing.
    [self setupWaveformSection];
    [self setupSpeedSection];
    [self setupVoiceSection];
    [self setupEffectsSection];

    [self loadWaveform];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.previewPlayer stop];
    self.previewPlayer = nil;
}

- (UILabel *)sectionHeaderLabel {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    return label;
}

- (UILabel *)sectionBodyLabel {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:15];
    label.numberOfLines = 3;
    return label;
}

#pragma mark - Waveform + range selection section

- (void)setupWaveformSection {
    self.waveformSectionLabel = [self sectionHeaderLabel];
    self.waveformSectionLabel.text = @"WAVEFORM — DRAG TO SELECT A RANGE";
    [self.scrollView addSubview:self.waveformSectionLabel];

    self.editWaveformView = [[WaveformView alloc] init];
    self.editWaveformView.symmetric = YES;
    self.editWaveformView.lineWidth = 1.5;
    self.editWaveformView.waveColor = [UIColor systemGray3Color];
    self.editWaveformView.progressColor = self.view.tintColor;
    self.editWaveformView.userInteractionEnabled = NO; // purely visual — the range selector overlaid on top handles touches
    [self.scrollView addSubview:self.editWaveformView];

    self.rangeSelector = [[EZWaveformRangeSelector alloc] init];
    // Default to the whole clip selected — most of the range-based tools (Trim aside)
    // make sense applied to the entire clip out of the box, and it avoids the confusing
    // "both handles stuck together selecting nothing" starting state.
    self.rangeSelector.startFraction = 0.0;
    self.rangeSelector.endFraction = 1.0;
    [self.rangeSelector addTarget:self action:@selector(handleRangeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.rangeSelector addTarget:self action:@selector(handleRangeDragBegan:) forControlEvents:UIControlEventEditingDidBegin];
    [self.rangeSelector addTarget:self action:@selector(handleRangeDragEnded:) forControlEvents:UIControlEventEditingDidEnd];
    [self.scrollView addSubview:self.rangeSelector];

    self.selectionTimeLabel = [[UILabel alloc] init];
    self.selectionTimeLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.selectionTimeLabel.textColor = [UIColor secondaryLabelColor];
    self.selectionTimeLabel.textAlignment = NSTextAlignmentCenter;
    [self.scrollView addSubview:self.selectionTimeLabel];

    self.insertSilenceButton = [self smallActionButtonWithTitle:@"Silence" systemImage:@"speaker.slash.fill"];
    [self.insertSilenceButton addTarget:self action:@selector(handleInsertSilenceTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.insertSilenceButton];

    self.normalizeButton = [self smallActionButtonWithTitle:@"Normalize" systemImage:@"waveform.path.ecg"];
    [self.normalizeButton addTarget:self action:@selector(handleNormalizeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.normalizeButton];

    self.trimButton = [self smallActionButtonWithTitle:@"Trim" systemImage:@"scissors"];
    [self.trimButton addTarget:self action:@selector(handleTrimTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.trimButton];

    self.exportSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.exportSpinner.hidesWhenStopped = YES;
    [self.scrollView addSubview:self.exportSpinner];

    [self updateSelectionTimeLabel];
    [self updateActionRowVisibility];
}

- (void)loadWaveform {
    NSURL *audioURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:self.entry];
    [self.editWaveformView loadAudioFileAtURL:audioURL completion:^(BOOL success, NSError * _Nullable error) {
        if (!success) {
            EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Edit-view waveform render failed: %@", error.localizedDescription);
        }
    }];
}

- (void)handleRangeChanged:(EZWaveformRangeSelector *)selector {
    [self updateSelectionTimeLabel];
    [self updateActionRowVisibility];
}

- (void)handleRangeDragBegan:(EZWaveformRangeSelector *)selector {
    // Stop whatever's playing immediately so it doesn't keep sounding from the old
    // selection while the user is still dragging to a new one.
    [self.previewPlayer stop];
    self.previewPlayer = nil;
    [self.speedPreviewButton setImage:[UIImage systemImageNamed:@"play.circle"] forState:UIControlStateNormal];
}

- (void)handleRangeDragEnded:(EZWaveformRangeSelector *)selector {
    [self startScrubPreviewFromFraction:selector.startFraction];
}

- (void)updateActionRowVisibility {
    BOOL hasSelection = (self.rangeSelector.endFraction - self.rangeSelector.startFraction) > kEZMinSelectionFractionToShowActions;
    self.insertSilenceButton.hidden = !hasSelection;
    self.normalizeButton.hidden = !hasSelection;
    self.trimButton.hidden = !hasSelection;
}

- (void)updateSelectionTimeLabel {
    NSTimeInterval start = self.entry.duration * self.rangeSelector.startFraction;
    NSTimeInterval end = self.entry.duration * self.rangeSelector.endFraction;
    self.selectionTimeLabel.text = [NSString stringWithFormat:@"Selection: %@ – %@ (%@)",
        [self formattedTime:start], [self formattedTime:end], [self formattedTime:end - start]];
}

- (NSString *)formattedTime:(NSTimeInterval)seconds {
    NSInteger total = (NSInteger)round(MAX(0, seconds));
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

#pragma mark - Insert Silence (reuses the selection's start as the insertion point and its
#pragma mark   width as the silence duration — the same underlying composition-splice logic
#pragma mark   as before, just driven by the range selector instead of a separate duration picker)

- (void)handleInsertSilenceTapped {
    CGFloat fraction = self.rangeSelector.startFraction;
    NSTimeInterval silenceDuration = self.entry.duration * (self.rangeSelector.endFraction - self.rangeSelector.startFraction);
    if (silenceDuration <= 0) return;

    [self beginExportUI];
    [self insertSilenceAtFraction:fraction duration:silenceDuration completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithResult:newEntry error:error successMessage:@"A silent gap was inserted where you had selected." replacedInPlace:NO];
    }];
}

/// Splices a true silent gap into a copy of the clip using AVMutableComposition (an
/// empty time range on a composition track plays back as silence — no separately
/// generated silent audio file is needed), then exports and archives as a new clip.
- (void)insertSilenceAtFraction:(CGFloat)fraction
                        duration:(NSTimeInterval)silenceDuration
                      completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    NSURL *sourceURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:self.entry];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    AVAssetTrack *sourceTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!sourceTrack) {
        completion(nil, [self errorWithCode:-1 message:@"No audio track found in the source clip."]);
        return;
    }

    CMTime totalDuration = asset.duration;
    int32_t timescale = sourceTrack.naturalTimeScale > 0 ? sourceTrack.naturalTimeScale : 44100;
    CMTime insertTime = CMTimeMakeWithSeconds(CMTimeGetSeconds(totalDuration) * fraction, timescale);
    CMTime silenceTime = CMTimeMakeWithSeconds(silenceDuration, timescale);

    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *compTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                       preferredTrackID:kCMPersistentTrackID_Invalid];

    NSError *insertError;
    [compTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, insertTime) ofTrack:sourceTrack atTime:kCMTimeZero error:&insertError];
    if (insertError) { completion(nil, insertError); return; }

    [compTrack insertEmptyTimeRange:CMTimeRangeMake(insertTime, silenceTime)];

    CMTime secondPartDuration = CMTimeSubtract(totalDuration, insertTime);
    CMTime secondPartDestination = CMTimeAdd(insertTime, silenceTime);
    [compTrack insertTimeRange:CMTimeRangeMake(insertTime, secondPartDuration) ofTrack:sourceTrack atTime:secondPartDestination error:&insertError];
    if (insertError) { completion(nil, insertError); return; }

    [self exportComposition:composition promptSuffix:@" (edited)" completion:completion];
}

#pragma mark - Trim (keeps only the selected range, discards the rest)

- (void)handleTrimTapped {
    CGFloat start = self.rangeSelector.startFraction;
    CGFloat end = self.rangeSelector.endFraction;

    [self beginExportUI];
    [self trimToStartFraction:start endFraction:end completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithResult:newEntry error:error successMessage:@"Saved a new clip containing just your selection." replacedInPlace:NO];
    }];
}

- (void)trimToStartFraction:(CGFloat)startFraction
                  endFraction:(CGFloat)endFraction
                   completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    NSURL *sourceURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:self.entry];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    AVAssetTrack *sourceTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!sourceTrack) {
        completion(nil, [self errorWithCode:-1 message:@"No audio track found in the source clip."]);
        return;
    }

    CMTime totalDuration = asset.duration;
    int32_t timescale = sourceTrack.naturalTimeScale > 0 ? sourceTrack.naturalTimeScale : 44100;
    CMTime startTime = CMTimeMakeWithSeconds(CMTimeGetSeconds(totalDuration) * startFraction, timescale);
    CMTime endTime = CMTimeMakeWithSeconds(CMTimeGetSeconds(totalDuration) * endFraction, timescale);
    CMTime selectionDuration = CMTimeSubtract(endTime, startTime);

    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *compTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                       preferredTrackID:kCMPersistentTrackID_Invalid];
    NSError *insertError;
    [compTrack insertTimeRange:CMTimeRangeMake(startTime, selectionDuration) ofTrack:sourceTrack atTime:kCMTimeZero error:&insertError];
    if (insertError) { completion(nil, insertError); return; }

    [self exportComposition:composition promptSuffix:@" (trimmed)" completion:completion];
}

#pragma mark - Normalize (real peak analysis + gain applied only within the selection)

- (void)handleNormalizeTapped {
    CGFloat start = self.rangeSelector.startFraction;
    CGFloat end = self.rangeSelector.endFraction;
    // Normalizing is non-destructive and idempotent — running it again on the same
    // range converges on the same result rather than compounding — so when the whole
    // clip is selected there's little reason to keep the pre-normalized original around
    // as a separate clip. A partial selection is more like a targeted edit, so that case
    // still gets the choice.
    BOOL isFullClip = (start <= 0.01 && end >= 0.99);

    if (isFullClip) {
        [self performNormalizeStart:start end:end saveAsNew:NO];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Save normalized audio"
        message:@"You normalized part of the clip. Save it as a new clip to keep the original untouched, or overwrite this clip's audio."
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Save as New Clip" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf performNormalizeStart:start end:end saveAsNew:YES];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Overwrite This Clip" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf performNormalizeStart:start end:end saveAsNew:NO];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)performNormalizeStart:(CGFloat)start end:(CGFloat)end saveAsNew:(BOOL)saveAsNew {
    [self beginExportUI];
    [self normalizeStartFraction:start endFraction:end saveAsNew:saveAsNew completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        if (!error && !saveAsNew && newEntry) {
            // Same clip, new audio underneath it — keep this screen in sync so the
            // waveform and any further edits reflect what's actually on disk now.
            self.entry = newEntry;
        }
        NSString *message = saveAsNew
            ? @"Saved a new clip with your selection normalized."
            : @"This clip's audio has been normalized in place — its position in History, favorite status, and tags are all unchanged.";
        [self endExportUIWithResult:newEntry error:error successMessage:message replacedInPlace:!saveAsNew];
    }];
}

/// Reads the full clip into a PCM buffer, finds the peak sample magnitude within the
/// selected frame range, scales just those samples so that peak lands near -1 dBFS
/// (0.891 linear), then writes the whole buffer back out. Runs off the main thread since
/// it touches every sample in the file.
- (void)normalizeStartFraction:(CGFloat)startFraction
                     endFraction:(CGFloat)endFraction
                       saveAsNew:(BOOL)saveAsNew
                      completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    NSURL *sourceURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:self.entry];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *openError;
        AVAudioFile *audioFile = [[AVAudioFile alloc] initForReading:sourceURL error:&openError];
        if (!audioFile) { [self finishBackgroundWork:completion entry:nil error:openError]; return; }

        AVAudioFormat *format = audioFile.processingFormat;
        AVAudioFrameCount frameCount = (AVAudioFrameCount)audioFile.length;
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frameCount];
        if (!buffer) {
            [self finishBackgroundWork:completion entry:nil error:[self errorWithCode:-20 message:@"Couldn't allocate an audio buffer."]];
            return;
        }

        NSError *readError;
        if (![audioFile readIntoBuffer:buffer error:&readError]) {
            [self finishBackgroundWork:completion entry:nil error:readError];
            return;
        }
        buffer.frameLength = frameCount;

        AVAudioFrameCount startFrame = (AVAudioFrameCount)round(frameCount * startFraction);
        AVAudioFrameCount endFrame = MIN((AVAudioFrameCount)round(frameCount * endFraction), frameCount);
        if (startFrame >= endFrame || !buffer.floatChannelData) {
            [self finishBackgroundWork:completion entry:nil error:[self errorWithCode:-21 message:@"Selection is too small to normalize."]];
            return;
        }

        float peak = 0.0f;
        for (AVAudioChannelCount ch = 0; ch < format.channelCount; ch++) {
            float *samples = buffer.floatChannelData[ch];
            for (AVAudioFrameCount i = startFrame; i < endFrame; i++) {
                float v = fabsf(samples[i]);
                if (v > peak) peak = v;
            }
        }

        if (peak < 0.0001f) {
            [self finishBackgroundWork:completion entry:nil error:[self errorWithCode:-22 message:@"That section is silent — nothing to normalize."]];
            return;
        }

        float targetPeak = 0.891f; // ~ -1 dBFS headroom
        float gain = MIN(targetPeak / peak, 20.0f); // capped so a near-silent selection doesn't blow out

        for (AVAudioChannelCount ch = 0; ch < format.channelCount; ch++) {
            float *samples = buffer.floatChannelData[ch];
            for (AVAudioFrameCount i = startFrame; i < endFrame; i++) {
                float v = samples[i] * gain;
                samples[i] = MAX(-1.0f, MIN(1.0f, v));
            }
        }

        NSString *tempName = [NSString stringWithFormat:@"normalize_%.0f.caf", [[NSDate date] timeIntervalSince1970]];
        NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:tempName]];
        [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

        NSError *writeSetupError;
        AVAudioFile *outputFile = [[AVAudioFile alloc] initForWriting:outputURL
                                                              settings:format.settings
                                                          commonFormat:format.commonFormat
                                                           interleaved:format.isInterleaved
                                                                 error:&writeSetupError];
        if (!outputFile) { [self finishBackgroundWork:completion entry:nil error:writeSetupError]; return; }

        NSError *writeError;
        if (![outputFile writeFromBuffer:buffer error:&writeError]) {
            [self finishBackgroundWork:completion entry:nil error:writeError];
            return;
        }

        NSData *audioData = [NSData dataWithContentsOfURL:outputURL];
        if (!audioData) {
            [self finishBackgroundWork:completion entry:nil error:[self errorWithCode:-23 message:@"Couldn't read back the normalized audio."]];
            return;
        }

        if (saveAsNew) {
            [[EZTTSLibraryManager sharedManager] saveAudioData:audioData
                                                          prompt:[self.entry.prompt stringByAppendingString:@" (normalized)"]
                                                       voiceName:self.entry.voiceName
                                                         voiceID:self.entry.voiceID
                                                        provider:self.entry.provider
                                                           model:self.entry.model
                                                       extension:@"caf"
                                                      completion:completion];
        } else {
            [[EZTTSLibraryManager sharedManager] replaceAudioForClipUUID:self.entry.uuid
                                                                  withData:audioData
                                                                 extension:@"caf"
                                                                completion:completion];
        }
    });
}

- (void)finishBackgroundWork:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
                        entry:(EZTTSManifestEntry * _Nullable)entry
                        error:(NSError * _Nullable)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(entry, error);
    });
}

#pragma mark - Shared export/archive plumbing (Insert Silence + Trim both build a composition
#pragma mark   and just need it exported to m4a and archived as a new clip)

- (void)exportComposition:(AVMutableComposition *)composition
              promptSuffix:(NSString *)suffix
                completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    NSString *tempName = [NSString stringWithFormat:@"edit_%.0f.m4a", [[NSDate date] timeIntervalSince1970]];
    NSURL *exportURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:tempName]];
    [[NSFileManager defaultManager] removeItemAtURL:exportURL error:nil];

    AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:composition
                                                                             presetName:AVAssetExportPresetAppleM4A];
    exportSession.outputURL = exportURL;
    exportSession.outputFileType = AVFileTypeAppleM4A;

    [exportSession exportAsynchronouslyWithCompletionHandler:^{
        if (exportSession.status != AVAssetExportSessionStatusCompleted) {
            NSError *exportError = exportSession.error ?: [self errorWithCode:-2 message:@"Export did not complete."];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, exportError); });
            return;
        }

        NSError *readError;
        NSData *audioData = [NSData dataWithContentsOfURL:exportURL options:0 error:&readError];
        if (!audioData) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, readError); });
            return;
        }

        [[EZTTSLibraryManager sharedManager] saveAudioData:audioData
                                                      prompt:[self.entry.prompt stringByAppendingString:suffix]
                                                   voiceName:self.entry.voiceName
                                                     voiceID:self.entry.voiceID
                                                    provider:self.entry.provider
                                                       model:self.entry.model
                                                   extension:@"m4a"
                                                  completion:completion];
    }];
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:@"EZTTSClipEditViewController" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)beginExportUI {
    self.insertSilenceButton.enabled = NO;
    self.normalizeButton.enabled = NO;
    self.trimButton.enabled = NO;
    [self.exportSpinner startAnimating];
}

- (void)endExportUIWithResult:(EZTTSManifestEntry * _Nullable)newEntry
                         error:(NSError * _Nullable)error
                successMessage:(NSString *)successMessage
               replacedInPlace:(BOOL)replacedInPlace
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.insertSilenceButton.enabled = YES;
        self.normalizeButton.enabled = YES;
        self.trimButton.enabled = YES;
        self.applyPitchButton.enabled = YES;
        self.reverbButton.enabled = YES;
        self.echoButton.enabled = YES;
        self.eqButton.enabled = YES;
        [self.exportSpinner stopAnimating];

        if (error) {
            [self presentErrorAlert:error title:@"Couldn't complete that edit"];
            return;
        }

        if (replacedInPlace) {
            // Same clip, new audio — refresh what's on screen instead of leaving.
            [self loadWaveform];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Done"
                                                                             message:successMessage
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Saved as a new clip"
                                                                         message:[successMessage stringByAppendingString:@" The original clip was left untouched — check History for the edited version."]
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self.navigationController popViewControllerAnimated:YES];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Speed section

- (void)setupSpeedSection {
    self.speedSectionLabel = [self sectionHeaderLabel];
    self.speedSectionLabel.text = @"SPEED (PLAYBACK ONLY — DOES NOT REGENERATE)";
    [self.scrollView addSubview:self.speedSectionLabel];

    self.speedSlider = [[UISlider alloc] init];
    self.speedSlider.minimumValue = 0.5;
    self.speedSlider.maximumValue = 2.0;
    id storedRate = self.entry.metadata[@"playbackRate"];
    self.speedSlider.value = [storedRate isKindOfClass:[NSNumber class]] ? [storedRate floatValue] : 1.0f;
    [self.speedSlider addTarget:self action:@selector(handleSpeedSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.speedSlider addTarget:self action:@selector(handleSpeedSliderReleased:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.scrollView addSubview:self.speedSlider];

    self.speedValueLabel = [[UILabel alloc] init];
    self.speedValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.speedValueLabel.textAlignment = NSTextAlignmentRight;
    [self updateSpeedValueLabel];
    [self.scrollView addSubview:self.speedValueLabel];

    self.speedPreviewButton = [self actionButtonWithTitle:@"  Preview at this speed" systemImage:@"play.circle"];
    [self.speedPreviewButton addTarget:self action:@selector(handleSpeedPreviewTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.speedPreviewButton];
}

- (void)updateSpeedValueLabel {
    self.speedValueLabel.text = [NSString stringWithFormat:@"%.2fx", self.speedSlider.value];
}

- (void)handleSpeedSliderChanged:(UISlider *)slider {
    [self updateSpeedValueLabel];
    if (self.previewPlayer) {
        self.previewPlayer.rate = slider.value;
    }
}

- (void)handleSpeedSliderReleased:(UISlider *)slider {
    [[EZTTSLibraryManager sharedManager] setPlaybackRate:slider.value
                                              forClipUUID:self.entry.uuid
                                               completion:^(EZTTSManifestEntry * _Nullable entry, NSError * _Nullable error) {
        if (error) {
            EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Failed to persist playback rate: %@", error.localizedDescription);
            return;
        }
        EZLogf(EZLogLevelInfo, @"TTSLibrary", @"Saved playback rate %.2fx for clip %@", slider.value, entry.uuid);
    }];
}

- (void)handleSpeedPreviewTapped {
    if (self.previewPlayer) {
        [self.previewPlayer stop];
        self.previewPlayer = nil;
        [self.speedPreviewButton setImage:[UIImage systemImageNamed:@"play.circle"] forState:UIControlStateNormal];
        return;
    }
    [self startScrubPreviewFromFraction:0.0];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player == self.previewPlayer) {
        self.previewPlayer = nil;
        [self.speedPreviewButton setImage:[UIImage systemImageNamed:@"play.circle"] forState:UIControlStateNormal];
    }
}

/// Plays the clip starting from a given point — used both by the range selector's
/// scrub-to-preview and the speed preview button. Only one preview is ever audible at a
/// time; whichever control triggers this one takes over.
- (void)startScrubPreviewFromFraction:(CGFloat)fraction {
    NSError *sessionError = nil;
    if (!EZActivatePlaybackAudioSession(&sessionError)) {
        [self presentErrorAlert:sessionError title:@"Couldn't start audio playback"];
        return;
    }

    NSURL *audioURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:self.entry];
    NSError *error;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:audioURL error:&error];
    if (!player) {
        EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Preview failed to load: %@", error.localizedDescription);
        return;
    }
    player.delegate = self;
    player.enableRate = YES;
    player.rate = self.speedSlider.value;
    player.currentTime = MAX(0, self.entry.duration * fraction);
    [player prepareToPlay];
    if (![player play]) {
        NSError *playbackError = [self errorWithCode:-31 message:@"The audio player could not start playback."];
        [self presentErrorAlert:playbackError title:@"Couldn't preview clip"];
        return;
    }
    self.previewPlayer = player;
    [self.speedPreviewButton setImage:[UIImage systemImageNamed:@"stop.circle"] forState:UIControlStateNormal];
}

#pragma mark - Change voice section

- (void)setupVoiceSection {
    self.voiceSectionLabel = [self sectionHeaderLabel];
    self.voiceSectionLabel.text = @"CHANGE VOICE (REGENERATES A NEW CLIP)";
    [self.scrollView addSubview:self.voiceSectionLabel];

    self.voiceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.voiceButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.voiceButton.titleLabel.font = [UIFont systemFontOfSize:15];
    self.voiceButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.voiceButton.layer.cornerRadius = 8;
    self.voiceButton.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [self updateVoiceButtonTitle];
    [self.voiceButton addTarget:self action:@selector(handleVoiceButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.voiceButton];

    self.regenerateWithVoiceButton = [self actionButtonWithTitle:@"  Regenerate with this voice" systemImage:@"arrow.clockwise"];
    [self.regenerateWithVoiceButton addTarget:self action:@selector(handleRegenerateWithVoiceTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.regenerateWithVoiceButton];
}

- (void)updateVoiceButtonTitle {
    NSString *display = self.selectedVoiceName.length > 0 ? self.selectedVoiceName : self.selectedVoiceID;
    if (display.length == 0) display = @"Choose a voice…";
    [self.voiceButton setTitle:[NSString stringWithFormat:@"🎙️  %@   ›", display] forState:UIControlStateNormal];
}

- (void)handleVoiceButtonTapped {
    EZVoicePickerViewController *picker = [[EZVoicePickerViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    picker.onVoiceSelected = ^(NSString *voiceID, NSString * _Nullable voiceName) {
        weakSelf.selectedVoiceID = voiceID;
        weakSelf.selectedVoiceName = voiceName;
        [weakSelf updateVoiceButtonTitle];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)handleRegenerateWithVoiceTapped {
    if (self.selectedVoiceID.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Choose a voice first"
                                                                         message:@"Tap the voice field above to pick one."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    TextToSpeechViewController *composeVC = [[TextToSpeechViewController alloc] init];
    [composeVC prefillWithText:self.entry.prompt voiceID:self.selectedVoiceID voiceName:self.selectedVoiceName];
    [self.navigationController pushViewController:composeVC animated:YES];
}

#pragma mark - Effects (apply to the whole clip, always save as a new clip)

- (void)setupEffectsSection {
    self.effectsSectionLabel = [self sectionHeaderLabel];
    self.effectsSectionLabel.text = @"EFFECTS (WHOLE CLIP — ALWAYS SAVES AS A NEW CLIP)";
    [self.scrollView addSubview:self.effectsSectionLabel];

    self.pitchValueLabel = [[UILabel alloc] init];
    self.pitchValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.pitchValueLabel.textAlignment = NSTextAlignmentRight;
    [self.scrollView addSubview:self.pitchValueLabel];

    self.pitchSlider = [[UISlider alloc] init];
    self.pitchSlider.minimumValue = -1200; // cents: -12 semitones
    self.pitchSlider.maximumValue = 1200;  // +12 semitones
    self.pitchSlider.value = 0;
    self.pitchSlider.minimumValueImage = [UIImage systemImageNamed:@"arrow.down"];
    self.pitchSlider.maximumValueImage = [UIImage systemImageNamed:@"arrow.up"];
    [self.pitchSlider addTarget:self action:@selector(handlePitchSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.pitchSlider];
    [self updatePitchValueLabel];

    self.applyPitchButton = [self actionButtonWithTitle:@"  Apply Pitch Shift" systemImage:@"waveform"];
    [self.applyPitchButton addTarget:self action:@selector(handlePitchApplyTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.applyPitchButton];

    self.reverbButton = [self smallActionButtonWithTitle:@"Reverb" systemImage:@"circle.dashed"];
    self.reverbButton.hidden = NO; // unlike the range-tools row, these three are always available
    [self.reverbButton addTarget:self action:@selector(handleReverbTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.reverbButton];

    self.echoButton = [self smallActionButtonWithTitle:@"Echo" systemImage:@"waveform.path.ecg.rectangle"];
    self.echoButton.hidden = NO;
    [self.echoButton addTarget:self action:@selector(handleEchoTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.echoButton];

    self.eqButton = [self smallActionButtonWithTitle:@"EQ" systemImage:@"slider.horizontal.3"];
    self.eqButton.hidden = NO;
    [self.eqButton addTarget:self action:@selector(handleEQTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.eqButton];
}

- (void)updatePitchValueLabel {
    float semitones = self.pitchSlider.value / 100.0f;
    self.pitchValueLabel.text = [NSString stringWithFormat:@"%+.1f st", semitones];
}

- (void)handlePitchSliderChanged:(UISlider *)slider {
    [self updatePitchValueLabel];
}

- (void)handlePitchApplyTapped {
    if (fabsf(self.pitchSlider.value) < 1) return; // no meaningful shift to apply
    AVAudioUnitTimePitch *pitchUnit = [[AVAudioUnitTimePitch alloc] init];
    pitchUnit.pitch = self.pitchSlider.value; // cents — tempo (rate) stays 1.0, untouched
    pitchUnit.rate = 1.0;

    [self beginEffectUI];
    [self applyEffectNodes:@[pitchUnit] tailSeconds:0.2 promptSuffix:@" (pitch shifted)"
                completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithResult:newEntry error:error successMessage:@"Saved a new clip with the pitch shifted." replacedInPlace:NO];
    }];
}

- (void)handleReverbTapped {
    AVAudioUnitReverb *reverb = [[AVAudioUnitReverb alloc] init];
    [reverb loadFactoryPreset:AVAudioUnitReverbPresetMediumHall];
    reverb.wetDryMix = 35;

    [self beginEffectUI];
    [self applyEffectNodes:@[reverb] tailSeconds:2.5 promptSuffix:@" (reverb)"
                completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithResult:newEntry error:error successMessage:@"Saved a new clip with reverb added." replacedInPlace:NO];
    }];
}

- (void)handleEchoTapped {
    AVAudioUnitDelay *delay = [[AVAudioUnitDelay alloc] init];
    delay.delayTime = 0.32;
    delay.feedback = 32;
    delay.lowPassCutoff = 15000;
    delay.wetDryMix = 30;

    [self beginEffectUI];
    [self applyEffectNodes:@[delay] tailSeconds:2.0 promptSuffix:@" (echo)"
                completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithResult:newEntry error:error successMessage:@"Saved a new clip with echo added." replacedInPlace:NO];
    }];
}

- (void)handleEQTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Choose an EQ preset"
                                                                      message:nil
                                                               preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSString *preset in @[@"Bass Boost", @"Treble Boost", @"Vocal Clarity"]) {
        [sheet addAction:[UIAlertAction actionWithTitle:preset style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf applyEQPreset:preset];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)applyEQPreset:(NSString *)preset {
    AVAudioUnitEQ *eq = [[AVAudioUnitEQ alloc] initWithNumberOfBands:3];
    AVAudioUnitEQFilterParameters *low = eq.bands[0];
    AVAudioUnitEQFilterParameters *mid = eq.bands[1];
    AVAudioUnitEQFilterParameters *high = eq.bands[2];

    low.filterType = AVAudioUnitEQFilterTypeLowShelf;
    low.frequency = 200;
    low.bypass = NO;
    mid.filterType = AVAudioUnitEQFilterTypeParametric;
    mid.frequency = 1000;
    mid.bandwidth = 1.0;
    mid.bypass = NO;
    high.filterType = AVAudioUnitEQFilterTypeHighShelf;
    high.frequency = 6000;
    high.bypass = NO;

    if ([preset isEqualToString:@"Bass Boost"]) {
        low.gain = 8; mid.gain = 0; high.gain = -2;
    } else if ([preset isEqualToString:@"Treble Boost"]) {
        low.gain = -2; mid.gain = 0; high.gain = 8;
    } else { // Vocal Clarity
        low.gain = -3; mid.gain = 4; high.gain = 3;
    }

    [self beginEffectUI];
    [self applyEffectNodes:@[eq] tailSeconds:0.2 promptSuffix:[NSString stringWithFormat:@" (%@)", preset]
                completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithResult:newEntry error:error
                     successMessage:[NSString stringWithFormat:@"Saved a new clip with %@ applied.", preset] replacedInPlace:NO];
    }];
}

- (void)beginEffectUI {
    self.applyPitchButton.enabled = NO;
    self.reverbButton.enabled = NO;
    self.echoButton.enabled = NO;
    self.eqButton.enabled = NO;
    [self beginExportUI];
}

/// Runs the source audio through an offline AVAudioEngine graph containing the given
/// effect node(s), then archives the rendered result as a new clip. This is the one
/// piece of plumbing all four effects share — each just configures its own AVAudioUnit
/// and hands it to this. `tailSeconds` extends the render past the source's natural
/// length so effects with a decay (reverb, echo) don't get cut off mid-tail.
- (void)applyEffectNodes:(NSArray<AVAudioUnit *> *)effectNodes
              tailSeconds:(NSTimeInterval)tailSeconds
             promptSuffix:(NSString *)suffix
               completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    NSURL *sourceURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:self.entry];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *openError;
        AVAudioFile *sourceFile = [[AVAudioFile alloc] initForReading:sourceURL error:&openError];
        if (!sourceFile) { [self finishBackgroundWork:completion entry:nil error:openError]; return; }

        AVAudioFormat *format = sourceFile.processingFormat;
        AVAudioFrameCount sourceFrameCount = (AVAudioFrameCount)sourceFile.length;
        AVAudioPCMBuffer *sourceBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:sourceFrameCount];
        if (!sourceBuffer) { [self finishBackgroundWork:completion entry:nil error:[self errorWithCode:-30 message:@"Couldn't allocate a source buffer."]]; return; }

        NSError *readError;
        if (![sourceFile readIntoBuffer:sourceBuffer error:&readError]) { [self finishBackgroundWork:completion entry:nil error:readError]; return; }
        sourceBuffer.frameLength = sourceFrameCount;

        AVAudioEngine *engine = [[AVAudioEngine alloc] init];
        AVAudioPlayerNode *player = [[AVAudioPlayerNode alloc] init];
        [engine attachNode:player];
        for (AVAudioUnit *node in effectNodes) { [engine attachNode:node]; }

        AVAudioNode *previous = player;
        for (AVAudioUnit *node in effectNodes) {
            [engine connect:previous to:node format:format];
            previous = node;
        }
        [engine connect:previous to:engine.mainMixerNode format:format];

        NSError *manualRenderError;
        BOOL enabled = [engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                                                    format:format
                                         maximumFrameCount:4096
                                                     error:&manualRenderError];
        if (!enabled) { [self finishBackgroundWork:completion entry:nil error:manualRenderError]; return; }

        [engine prepare];
        NSError *startError;
        if (![engine startAndReturnError:&startError]) { [self finishBackgroundWork:completion entry:nil error:startError]; return; }

        [player scheduleBuffer:sourceBuffer completionHandler:nil];
        [player play];

        NSString *tempName = [NSString stringWithFormat:@"effect_%.0f.caf", [[NSDate date] timeIntervalSince1970]];
        NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:tempName]];
        [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

        NSError *writeSetupError;
        AVAudioFile *outputFile = [[AVAudioFile alloc] initForWriting:outputURL
                                                              settings:format.settings
                                                          commonFormat:format.commonFormat
                                                           interleaved:format.isInterleaved
                                                                 error:&writeSetupError];
        if (!outputFile) { [self finishBackgroundWork:completion entry:nil error:writeSetupError]; return; }

        AVAudioFrameCount totalFramesToRender = sourceFrameCount + (AVAudioFrameCount)(tailSeconds * format.sampleRate);
        AVAudioFrameCount framesRendered = 0;
        AVAudioPCMBuffer *renderBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:engine.manualRenderingFormat
                                                                        frameCapacity:engine.manualRenderingMaximumFrameCount];

        NSError *renderLoopError = nil;
        while (framesRendered < totalFramesToRender) {
            AVAudioFrameCount framesThisPass = MIN(engine.manualRenderingMaximumFrameCount, totalFramesToRender - framesRendered);
            renderBuffer.frameLength = framesThisPass;

            NSError *renderError;
            AVAudioEngineManualRenderingStatus status = [engine renderOffline:framesThisPass toBuffer:renderBuffer error:&renderError];
            if (status == AVAudioEngineManualRenderingStatusError) {
                renderLoopError = renderError ?: [self errorWithCode:-31 message:@"Offline rendering failed."];
                break;
            }

            NSError *chunkWriteError;
            if (![outputFile writeFromBuffer:renderBuffer error:&chunkWriteError]) {
                renderLoopError = chunkWriteError;
                break;
            }

            framesRendered += framesThisPass;
            if (status == AVAudioEngineManualRenderingStatusInsufficientDataFromInputNode) {
                break; // player has nothing more to give — tail has fully decayed
            }
        }

        [engine stop];

        if (renderLoopError) { [self finishBackgroundWork:completion entry:nil error:renderLoopError]; return; }

        NSData *audioData = [NSData dataWithContentsOfURL:outputURL];
        if (!audioData) { [self finishBackgroundWork:completion entry:nil error:[self errorWithCode:-32 message:@"Couldn't read back the processed audio."]]; return; }

        [[EZTTSLibraryManager sharedManager] saveAudioData:audioData
                                                      prompt:[self.entry.prompt stringByAppendingString:suffix]
                                                   voiceName:self.entry.voiceName
                                                     voiceID:self.entry.voiceID
                                                    provider:self.entry.provider
                                                       model:self.entry.model
                                                   extension:@"caf"
                                                  completion:completion];
    });
}

#pragma mark - Shared UI helpers

- (UIButton *)actionButtonWithTitle:(NSString *)title systemImage:(NSString *)imageName {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:imageName] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    return button;
}

- (UIButton *)smallActionButtonWithTitle:(NSString *)title systemImage:(NSString *)imageName {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = title;
    config.image = [UIImage systemImageNamed:imageName];
    config.imagePadding = 4;
    config.imagePlacement = NSDirectionalRectEdgeTop;
    config.baseBackgroundColor = [UIColor secondarySystemBackgroundColor];
    config.baseForegroundColor = self.view.tintColor;
    config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    config.titleTextAttributesTransformer =
        ^NSDictionary<NSAttributedStringKey,id> * _Nonnull(NSDictionary<NSAttributedStringKey,id> * _Nonnull attrs) {
        NSMutableDictionary *m = [attrs mutableCopy];
        m[NSFontAttributeName] = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        return m;
    };
    button.configuration = config;
    button.hidden = YES;
    return button;
}

- (void)presentErrorAlert:(NSError *)error title:(NSString *)title {
    EZLogf(EZLogLevelError, @"TTSLibrary", @"%@: %@", title, error.localizedDescription);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:error.localizedDescription
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat margin = 20;
    CGFloat width = self.view.bounds.size.width - margin * 2;
    CGFloat y = self.view.safeAreaInsets.top + 16;

    self.scrollView.frame = self.view.bounds;

    self.promptLabel.frame = CGRectMake(margin, y, width, 60);
    y = CGRectGetMaxY(self.promptLabel.frame) + 20;

    // Waveform section — first, right under the prompt.
    self.waveformSectionLabel.frame = CGRectMake(margin, y, width, 16);
    y = CGRectGetMaxY(self.waveformSectionLabel.frame) + 10;
    self.editWaveformView.frame = CGRectMake(margin, y, width, 70);
    self.rangeSelector.frame = self.editWaveformView.frame;
    y = CGRectGetMaxY(self.editWaveformView.frame) + 6;
    self.selectionTimeLabel.frame = CGRectMake(margin, y, width, 16);
    y = CGRectGetMaxY(self.selectionTimeLabel.frame) + 12;

    CGFloat actionButtonWidth = (width - 16) / 3.0;
    CGFloat actionButtonHeight = 56;
    self.insertSilenceButton.frame = CGRectMake(margin, y, actionButtonWidth, actionButtonHeight);
    self.normalizeButton.frame = CGRectMake(margin + actionButtonWidth + 8, y, actionButtonWidth, actionButtonHeight);
    self.trimButton.frame = CGRectMake(margin + (actionButtonWidth + 8) * 2, y, actionButtonWidth, actionButtonHeight);
    self.exportSpinner.center = CGPointMake(self.view.bounds.size.width / 2.0, y + actionButtonHeight / 2.0);
    y += actionButtonHeight + 28;

    // Speed section
    self.speedSectionLabel.frame = CGRectMake(margin, y, width, 16);
    y = CGRectGetMaxY(self.speedSectionLabel.frame) + 8;
    self.speedValueLabel.frame = CGRectMake(margin, y, 60, 24);
    self.speedSlider.frame = CGRectMake(margin + 68, y, width - 68, 24);
    y = CGRectGetMaxY(self.speedSlider.frame) + 10;
    self.speedPreviewButton.frame = CGRectMake(margin, y, width, 32);
    y = CGRectGetMaxY(self.speedPreviewButton.frame) + 28;

    // Voice section
    self.voiceSectionLabel.frame = CGRectMake(margin, y, width, 16);
    y = CGRectGetMaxY(self.voiceSectionLabel.frame) + 8;
    self.voiceButton.frame = CGRectMake(margin, y, width, 40);
    y = CGRectGetMaxY(self.voiceButton.frame) + 10;
    self.regenerateWithVoiceButton.frame = CGRectMake(margin, y, width, 32);
    y = CGRectGetMaxY(self.regenerateWithVoiceButton.frame) + 28;

    // Effects section
    self.effectsSectionLabel.frame = CGRectMake(margin, y, width, 16);
    y = CGRectGetMaxY(self.effectsSectionLabel.frame) + 8;
    self.pitchValueLabel.frame = CGRectMake(margin, y, 70, 24);
    self.pitchSlider.frame = CGRectMake(margin + 78, y, width - 78, 24);
    y = CGRectGetMaxY(self.pitchSlider.frame) + 10;
    self.applyPitchButton.frame = CGRectMake(margin, y, width, 32);
    y = CGRectGetMaxY(self.applyPitchButton.frame) + 20;

    CGFloat effectButtonWidth = (width - 16) / 3.0;
    CGFloat effectButtonHeight = 56;
    self.reverbButton.frame = CGRectMake(margin, y, effectButtonWidth, effectButtonHeight);
    self.echoButton.frame = CGRectMake(margin + effectButtonWidth + 8, y, effectButtonWidth, effectButtonHeight);
    self.eqButton.frame = CGRectMake(margin + (effectButtonWidth + 8) * 2, y, effectButtonWidth, effectButtonHeight);
    y += effectButtonHeight + 40;

    self.scrollView.contentSize = CGSizeMake(self.view.bounds.size.width, y);
}

@end
