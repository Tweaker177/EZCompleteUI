//
//  EZTTSClipEditViewController.m
//  EZTTSLibrary
//
// Change: starting a preview here stops any clip still playing from the shared
// player (EZMediaPlayerManager), so the two never overlap.

#import "EZTTSClipEditViewController.h"
#import "EZTheme.h"
#import "EZTTSLibraryManager.h"
#import "EZSoundLibraryManager.h"
#import "EZSoundManifestEntry.h"
#import "EZMediaPlayerManager.h"
#import "TextToSpeechViewController.h"
#import "EZVoicePickerViewController.h"
#import "EZWaveformRangeSelector.h"
#import "WaveformView.h"
#import "helpers.h"
#import <AVFoundation/AVFoundation.h>

static CGFloat const kEZMinSelectionFractionToShowActions = 0.02;
static const Float64 kEZSceneBackgroundTailSeconds = 3.0;
static NSUInteger const kEZClipUndoMaxSnapshots = 10;

// Accent name kept for the existing call sites; the value is now the
// shared EZTheme gold so the editor matches the rest of the app.
static UIColor *EZEditElectricBlue(void) {
    return [EZTheme goldColor];
}

@interface EZTTSClipEditViewController () <AVAudioPlayerDelegate>

@property (nonatomic, strong) EZTTSManifestEntry *entry;

/// Non-nil when the editor was opened on a generated sound instead of
/// a TTS clip. The editor then works on a mirror entry (self.entry)
/// for display and persistence, and all archiving goes through
/// EZSoundLibraryManager (see the host-library seam below).
@property (nonatomic, strong, nullable) EZSoundManifestEntry *soundEntry;
/// The audio file being edited, resolved once at init and refreshed
/// after an in-place replace swaps the file underneath the entry.
@property (nonatomic, strong) NSURL *audioURL;
/// Root for scene-asset lookups (TTS clips only; nil for sounds).
@property (nonatomic, strong, nullable) NSURL *libraryRootURL;

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *promptContainer;
@property (nonatomic, strong) UILabel *promptLabel;
@property (nonatomic, strong) UIImageView *promptDisclosureImage;
@property (nonatomic) BOOL promptExpanded;

// Waveform + range selection — at the top of the screen, directly under the prompt.
@property (nonatomic, strong) UILabel *waveformSectionLabel;
@property (nonatomic, strong) WaveformView *editWaveformView;
@property (nonatomic, strong) EZWaveformRangeSelector *rangeSelector;
@property (nonatomic, strong) UILabel *selectionTimeLabel;
@property (nonatomic, strong) UIButton *insertSilenceButton;
@property (nonatomic, strong) UIButton *normalizeButton;
@property (nonatomic, strong) UIButton *trimButton;
@property (nonatomic, strong) UIActivityIndicatorView *exportSpinner;

@property (nonatomic, strong) UILabel *backgroundSectionLabel;
@property (nonatomic, strong) UISlider *backgroundLevelSlider;
@property (nonatomic, strong) UILabel *backgroundLevelLabel;

// Speed
@property (nonatomic, strong) UILabel *speedSectionLabel;
@property (nonatomic, strong) UIBarButtonItem *undoButtonItem;
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

// Effects — apply to the whole clip regardless of the current selection, in
// place like every other edit in this editor (the pre-edit audio is kept on
// the undo stack, so any of them can be walked back).
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
        _audioURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:entry];
        _libraryRootURL = [[EZTTSLibraryManager sharedManager] libraryRootURL];
    }
    return self;
}

- (instancetype)initWithSoundEntry:(EZSoundManifestEntry *)entry {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _soundEntry = entry;
        _entry = [self mirrorEntryForSoundEntry:entry];
        _selectedVoiceID = @"";
        _selectedVoiceName = nil;
        _audioURL = [[EZSoundLibraryManager sharedManager] absoluteURLForEntry:entry];
        _libraryRootURL = nil;
    }
    return self;
}

#pragma mark - Host library seam (TTS library or Sounds library)

/// The editor edits one audio file; which library archives the results
/// depends on how it was opened. For a sound, the editor displays and
/// tracks a detached EZTTSManifestEntry mirror of the sound entry —
/// every field the editing tools read exists on both entry types —
/// while the real persistence lands in the Sounds library.

- (EZTTSManifestEntry *)mirrorEntryForSoundEntry:(EZSoundManifestEntry *)sound {
    // EZTTSManifestEntry marks -init NS_UNAVAILABLE; the mirror is
    // built through the designated initializer in one shot (sounds
    // have no voice name/ID, so those two stay nil).
    return [[EZTTSManifestEntry alloc] initWithUUID:sound.uuid
                                             created:sound.created
                                            provider:sound.provider
                                           voiceName:nil
                                             voiceID:nil
                                               model:sound.model
                                              prompt:sound.prompt
                                             preview:sound.preview
                                            filename:sound.filename
                                        relativePath:sound.relativePath
                                            duration:sound.duration
                                          sampleRate:sound.sampleRate
                                            fileSize:sound.fileSize
                                            favorite:sound.isFavorite
                                                tags:sound.tags
                                            metadata:sound.metadata];
}



/// Replaces the audio underneath the SAME entry — the save convention for
/// every edit in this editor. The entry keeps its position, title, favorite
/// flag, and metadata; self.audioURL is refreshed to the replacement file
/// either way. Unless the caller is Undo itself, the current audio is
/// snapshotted first so the edit can be walked back.
- (void)replaceEditedAudioData:(NSData *)data
                     extension:(NSString *)extension
                    completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion {
    [self replaceEditedAudioData:data extension:extension snapshotForUndo:YES completion:completion];
}
- (void)replaceEditedAudioData:(NSData *)data
                     extension:(NSString *)extension
               snapshotForUndo:(BOOL)snapshotForUndo
                    completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion {
    if (snapshotForUndo) [self snapshotCurrentAudioForUndo];
    if (self.soundEntry) {
        [[EZSoundLibraryManager sharedManager] replaceAudioForSoundUUID:self.soundEntry.uuid
                                                                 withData:data
                                                                extension:extension
                                                               completion:^(EZSoundManifestEntry *updated, NSError *error) {
            if (updated) {
                self.soundEntry = updated;
                self.audioURL = [[EZSoundLibraryManager sharedManager] absoluteURLForEntry:updated];
            }
            completion(updated ? [self mirrorEntryForSoundEntry:updated] : nil, error);
        }];
        return;
    }
    [[EZTTSLibraryManager sharedManager] replaceAudioForClipUUID:self.entry.uuid
                                                          withData:data
                                                         extension:extension
                                                        completion:^(EZTTSManifestEntry *updated, NSError *error) {
        if (updated) {
            self.audioURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:updated];
        }
        completion(updated, error);
    }];
}

#pragma mark - Undo (in-place edits)

/// On-disk undo history for this clip: the audio as it was before each
/// in-place edit, oldest first, kept in a subfolder of the host library's
/// root (both libraries index by manifest, so the extra folder is invisible
/// to them). Survives leaving the editor; capped at kEZClipUndoMaxSnapshots.
- (NSURL *)undoDirectoryURLCreating:(BOOL)create {
    NSURL *root = self.soundEntry ? [EZSoundLibraryManager sharedManager].libraryRootURL
                                  : self.libraryRootURL;
    if (!root || self.entry.uuid.length == 0) return nil;
    NSURL *dir = [[root URLByAppendingPathComponent:@"EZClipUndo" isDirectory:YES]
        URLByAppendingPathComponent:self.entry.uuid isDirectory:YES];
    if (create) {
        [[NSFileManager defaultManager] createDirectoryAtURL:dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    } else if (![[NSFileManager defaultManager] fileExistsAtPath:dir.path]) {
        return nil;
    }
    return dir;
}
- (NSArray<NSURL *> *)undoSnapshotURLs {
    NSURL *dir = [self undoDirectoryURLCreating:NO];
    if (!dir) return @[];
    NSArray<NSURL *> *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:dir
      includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                         options:0
                           error:nil];
    NSMutableArray<NSURL *> *snapshots = [NSMutableArray array];
    for (NSURL *file in files) {
        if ([file.lastPathComponent hasPrefix:@"undo-"]) [snapshots addObject:file];
    }
    [snapshots sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da = nil, *db = nil;
        [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
        return [(da ?: [NSDate distantPast]) compare:(db ?: [NSDate distantPast])];
    }];
    return snapshots;
}
- (void)snapshotCurrentAudioForUndo {
    NSURL *dir = [self undoDirectoryURLCreating:YES];
    NSData *data = self.audioURL ? [NSData dataWithContentsOfURL:self.audioURL] : nil;
    if (!dir || !data) {
        EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Undo snapshot skipped: current audio unreadable.");
        return;
    }
    NSString *ext = self.audioURL.pathExtension.length > 0 ? self.audioURL.pathExtension : @"m4a";
    NSString *name = [NSString stringWithFormat:@"undo-%lld.%@",
                      (long long)([NSDate date].timeIntervalSince1970 * 1000.0), ext];
    if (![data writeToURL:[dir URLByAppendingPathComponent:name] atomically:YES]) {
        EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Undo snapshot failed to write.");
        return;
    }
    NSArray<NSURL *> *snapshots = [self undoSnapshotURLs];
    while (snapshots.count > kEZClipUndoMaxSnapshots) {
        [[NSFileManager defaultManager] removeItemAtURL:snapshots.firstObject error:nil];
        snapshots = [snapshots subarrayWithRange:NSMakeRange(1, snapshots.count - 1)];
    }
}
- (void)refreshUndoButton {
    self.undoButtonItem.enabled = [self undoSnapshotURLs].count > 0;
}
- (void)handleUndoTapped {
    NSArray<NSURL *> *snapshots = [self undoSnapshotURLs];
    NSURL *latest = snapshots.lastObject;
    if (!latest) { [self refreshUndoButton]; return; }
    NSData *data = [NSData dataWithContentsOfURL:latest];
    if (!data) {
        [[NSFileManager defaultManager] removeItemAtURL:latest error:nil];
        [self refreshUndoButton];
        return;
    }
    [self.previewPlayer stop];
    self.previewPlayer = nil;
    [self beginEffectUI];
    self.speedSlider.enabled = NO;
    self.backgroundLevelSlider.enabled = NO;
    NSString *ext = latest.pathExtension.length > 0 ? latest.pathExtension : @"m4a";
    [self replaceEditedAudioData:data extension:ext snapshotForUndo:NO
                      completion:^(EZTTSManifestEntry * _Nullable entry, NSError * _Nullable error) {
        if (!error) [[NSFileManager defaultManager] removeItemAtURL:latest error:nil];
        self.speedSlider.enabled = YES;
        self.backgroundLevelSlider.enabled = YES;
        [self endExportUIWithEntry:entry error:error];
    }];
}

/// Persists the legacy playback-rate metadata ("playbackRate"). The editor
/// now bakes speed into the audio itself (see handleSpeedSliderReleased:)
/// and keeps this cleared to 1.0 so list playback never applies a rate
/// twice; the managers still honor it for clips saved before the bake.
- (void)persistPlaybackRate:(float)rate {
    if (self.soundEntry) {
        [[EZSoundLibraryManager sharedManager] setPlaybackRate:rate
                                                  forSoundUUID:self.soundEntry.uuid
                                                    completion:^(EZSoundManifestEntry *entry, NSError *error) {
            if (error) {
                EZLogf(EZLogLevelWarning, @"SoundLibrary", @"Failed to persist playback rate: %@", error.localizedDescription);
                return;
            }
            EZLogf(EZLogLevelInfo, @"SoundLibrary", @"Saved playback rate %.2fx for sound %@", rate, entry.uuid);
        }];
        return;
    }
    [[EZTTSLibraryManager sharedManager] setPlaybackRate:rate
                                              forClipUUID:self.entry.uuid
                                               completion:^(EZTTSManifestEntry * _Nullable entry, NSError * _Nullable error) {
        if (error) {
            EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Failed to persist playback rate: %@", error.localizedDescription);
            return;
        }
        EZLogf(EZLogLevelInfo, @"TTSLibrary", @"Saved playback rate %.2fx for clip %@", rate, entry.uuid);
    }];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Edit Clip";
    self.view.backgroundColor = [EZTheme chatBackgroundColor];
    self.view.tintColor = EZEditElectricBlue();

    self.scrollView = [[UIScrollView alloc] init];
    [self.view addSubview:self.scrollView];

    self.promptContainer = [[UIView alloc] init];
    self.promptContainer.backgroundColor = [EZTheme cardColor];
    self.promptContainer.layer.cornerRadius = 12;
    self.promptContainer.layer.borderWidth = 1.0;
    self.promptContainer.layer.borderColor = [EZEditElectricBlue() colorWithAlphaComponent:0.35].CGColor;
    self.promptContainer.userInteractionEnabled = YES;
    [self.promptContainer addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePromptTapped:)]];
    [self.scrollView addSubview:self.promptContainer];

    self.promptLabel = [self sectionBodyLabel];
    NSString *displayTitle = self.entry.metadata[@"title"];
    self.promptLabel.text = [displayTitle isKindOfClass:[NSString class]] && displayTitle.length > 0
        ? displayTitle : self.entry.prompt;
    self.promptLabel.numberOfLines = 3;
    self.promptLabel.lineBreakMode = NSLineBreakByClipping;
    [self.promptContainer addSubview:self.promptLabel];
    self.promptDisclosureImage = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
    self.promptDisclosureImage.tintColor = [EZTheme secondaryTextColor];
    self.promptDisclosureImage.contentMode = UIViewContentModeCenter;
    [self.promptContainer addSubview:self.promptDisclosureImage];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]
                                                                               style:UIBarButtonItemStylePlain
                                                                              target:self
                                                                              action:@selector(copyPromptTapped:)];
    self.navigationItem.rightBarButtonItem.tintColor = EZEditElectricBlue();
    self.navigationItem.standardAppearance = [EZTheme navigationBarAppearance];
    self.navigationItem.scrollEdgeAppearance = [EZTheme navigationBarAppearance];
    self.navigationController.navigationBar.tintColor = [EZTheme goldColor];
    self.navigationItem.leftItemsSupplementBackButton = YES;
    self.undoButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"arrow.uturn.backward"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(handleUndoTapped)];
    self.undoButtonItem.accessibilityLabel = @"Undo last edit";
    self.navigationItem.leftBarButtonItem = self.undoButtonItem;
    [self refreshUndoButton];

    // Waveform sits directly under the prompt text now — it's the most important thing
    // on this screen, so it gets first billing.
    [self setupWaveformSection];
    if ([self hasEditableBackgroundAudio]) [self setupBackgroundAudioSection];
    [self setupSpeedSection];
    if (!self.soundEntry) [self setupVoiceSection];
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
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [EZEditElectricBlue() colorWithAlphaComponent:0.90];
    return label;
}

- (UILabel *)sectionBodyLabel {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:15];
    label.numberOfLines = 3;
    return label;
}

- (void)handlePromptTapped:(UITapGestureRecognizer *)gesture {
    self.promptExpanded = !self.promptExpanded;
    self.promptLabel.numberOfLines = self.promptExpanded ? 0 : 3;
    self.promptDisclosureImage.image = [UIImage systemImageNamed:self.promptExpanded ? @"chevron.up" : @"chevron.down"];
    [UIView animateWithDuration:0.2 animations:^{ [self.view setNeedsLayout]; [self.view layoutIfNeeded]; }];
}

- (void)copyPromptTapped:(id)sender {
    UIPasteboard.generalPasteboard.string = self.entry.prompt ?: @"";
    UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
}

#pragma mark - Waveform + range selection section

- (void)setupWaveformSection {
    self.waveformSectionLabel = [self sectionHeaderLabel];
    self.waveformSectionLabel.text = @"WAVEFORM — DRAG TO SELECT A RANGE";
    [self.scrollView addSubview:self.waveformSectionLabel];

    self.editWaveformView = [[WaveformView alloc] init];
    self.editWaveformView.symmetric = YES;
    self.editWaveformView.lineWidth = 1.5;
    self.editWaveformView.waveColor = [[EZTheme goldColor] colorWithAlphaComponent:0.55];
    self.editWaveformView.progressColor = EZEditElectricBlue();
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
    self.selectionTimeLabel.adjustsFontSizeToFitWidth = YES;
    self.selectionTimeLabel.minimumScaleFactor = 0.5;
    self.selectionTimeLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.selectionTimeLabel.textColor = [EZTheme secondaryTextColor];
    self.selectionTimeLabel.textAlignment = NSTextAlignmentCenter;
    [self.scrollView addSubview:self.selectionTimeLabel];

    self.insertSilenceButton = [self smallActionButtonWithTitle:@"Silence" systemImage:@"speaker.slash.fill" color:[UIColor systemOrangeColor]];
    [self.insertSilenceButton addTarget:self action:@selector(handleInsertSilenceTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.insertSilenceButton];

    self.normalizeButton = [self smallActionButtonWithTitle:@"Normalize" systemImage:@"waveform.path.ecg" color:[UIColor systemTealColor]];
    [self.normalizeButton addTarget:self action:@selector(handleNormalizeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.normalizeButton];

    self.trimButton = [self smallActionButtonWithTitle:@"Trim" systemImage:@"scissors" color:[UIColor systemPinkColor]];
    [self.trimButton addTarget:self action:@selector(handleTrimTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.trimButton];

    self.exportSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.exportSpinner.hidesWhenStopped = YES;
    [self.scrollView addSubview:self.exportSpinner];

    [self updateSelectionTimeLabel];
    [self updateActionRowVisibility];
}

- (void)loadWaveform {
    NSURL *audioURL = self.audioURL;
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

#pragma mark - Background scene mix

- (NSURL *)sceneAssetURLForMetadataKey:(NSString *)key {
    NSString *relativePath = [self.entry.metadata[key] isKindOfClass:NSString.class] ? self.entry.metadata[key] : nil;
    if (!relativePath.length || [relativePath hasPrefix:@"/"] || [relativePath containsString:@".."]) return nil;
    NSURL *url = [self.libraryRootURL URLByAppendingPathComponent:relativePath];
    return [[NSFileManager defaultManager] fileExistsAtPath:url.path] ? url : nil;
}

- (BOOL)hasEditableBackgroundAudio {
    return [self sceneAssetURLForMetadataKey:@"sceneNarrationPath"] != nil &&
           [self sceneAssetURLForMetadataKey:@"sceneBackgroundPath"] != nil;
}

- (void)setupBackgroundAudioSection {
    self.backgroundSectionLabel = [self sectionHeaderLabel];
    self.backgroundSectionLabel.text = @"BACKGROUND AUDIO — SAVES TO THIS CLIP";
    [self.scrollView addSubview:self.backgroundSectionLabel];
    self.backgroundLevelLabel = [[UILabel alloc] init];
    self.backgroundLevelLabel.adjustsFontSizeToFitWidth = YES;
    self.backgroundLevelLabel.minimumScaleFactor = 0.5;
    self.backgroundLevelLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.backgroundLevelLabel.textAlignment = NSTextAlignmentRight;
    [self.scrollView addSubview:self.backgroundLevelLabel];
    self.backgroundLevelSlider = [[UISlider alloc] init];
    self.backgroundLevelSlider.minimumValue = 0.0;
    self.backgroundLevelSlider.maximumValue = 1.0;
    self.backgroundLevelSlider.tintColor = EZEditElectricBlue();
    id saved = self.entry.metadata[@"sceneBackgroundLevel"];
    self.backgroundLevelSlider.value = [saved isKindOfClass:NSNumber.class] ? [saved floatValue] : 0.5f;
    [self.backgroundLevelSlider addTarget:self action:@selector(handleBackgroundLevelChanged:) forControlEvents:UIControlEventValueChanged];
    [self.backgroundLevelSlider addTarget:self action:@selector(handleBackgroundLevelReleased:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.scrollView addSubview:self.backgroundLevelSlider];
    [self updateBackgroundLevelLabel];
}

- (void)updateBackgroundLevelLabel {
    self.backgroundLevelLabel.text = [NSString stringWithFormat:@"%.0f%%", self.backgroundLevelSlider.value * 100.0f];
}

- (void)handleBackgroundLevelChanged:(UISlider *)slider { [self updateBackgroundLevelLabel]; }

- (void)handleBackgroundLevelReleased:(UISlider *)slider {
    NSURL *narrationURL = [self sceneAssetURLForMetadataKey:@"sceneNarrationPath"];
    NSURL *backgroundURL = [self sceneAssetURLForMetadataKey:@"sceneBackgroundPath"];
    if (!narrationURL || !backgroundURL) return;
    slider.enabled = NO;
    [self.exportSpinner startAnimating];
    [self remixNarrationURL:narrationURL backgroundURL:backgroundURL level:slider.value completion:^(NSData *audioData, NSError *error) {
        if (error || !audioData.length) {
            slider.enabled = YES; [self.exportSpinner stopAnimating];
            [self presentErrorAlert:error ?: [self errorWithCode:-40 message:@"Could not render the new background level."] title:@"Couldn't update background audio"];
            return;
        }
        [self replaceEditedAudioData:audioData extension:@"m4a" completion:^(EZTTSManifestEntry *entry, NSError *replaceError) {
            if (replaceError) { slider.enabled = YES; [self.exportSpinner stopAnimating]; [self presentErrorAlert:replaceError title:@"Couldn't update background audio"]; return; }
            [[EZTTSLibraryManager sharedManager] setSceneBackgroundLevel:slider.value forClipUUID:self.entry.uuid completion:^(EZTTSManifestEntry *updated, NSError *metadataError) {
                slider.enabled = YES; [self.exportSpinner stopAnimating];
                if (metadataError) { [self presentErrorAlert:metadataError title:@"Couldn't save background level"]; return; }
                self.entry = updated; [self loadWaveform]; [self refreshUndoButton];
            }];
        }];
    }];
}

- (void)remixNarrationURL:(NSURL *)narrationURL backgroundURL:(NSURL *)backgroundURL level:(float)level completion:(void (^)(NSData * _Nullable, NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        AVURLAsset *narration = [AVURLAsset URLAssetWithURL:narrationURL options:nil];
        AVURLAsset *background = [AVURLAsset URLAssetWithURL:backgroundURL options:nil];
        AVAssetTrack *voiceTrack = [[narration tracksWithMediaType:AVMediaTypeAudio] firstObject];
        AVAssetTrack *backgroundTrack = [[background tracksWithMediaType:AVMediaTypeAudio] firstObject];
        CMTime narrationDuration = narration.duration;
        CMTime tailDuration = CMTimeMakeWithSeconds(kEZSceneBackgroundTailSeconds, 600);
        CMTime mixDuration = CMTimeAdd(narrationDuration, tailDuration);
        if (!voiceTrack || !backgroundTrack || !CMTIME_IS_NUMERIC(narrationDuration) || CMTIME_COMPARE_INLINE(narrationDuration, <=, kCMTimeZero) || CMTIME_COMPARE_INLINE(background.duration, <=, kCMTimeZero)) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, [self errorWithCode:-41 message:@"The original scene layers are unavailable."]); }); return;
        }
        AVMutableComposition *composition = [AVMutableComposition composition]; NSError *insertError = nil;
        AVMutableCompositionTrack *voice = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        [voice insertTimeRange:CMTimeRangeMake(kCMTimeZero, narrationDuration) ofTrack:voiceTrack atTime:kCMTimeZero error:&insertError];
        AVMutableCompositionTrack *bed = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        for (CMTime cursor = kCMTimeZero; !insertError && CMTIME_COMPARE_INLINE(cursor, <, mixDuration); ) {
            CMTime part = CMTimeMinimum(background.duration, CMTimeSubtract(mixDuration, cursor));
            [bed insertTimeRange:CMTimeRangeMake(kCMTimeZero, part) ofTrack:backgroundTrack atTime:cursor error:&insertError]; cursor = CMTimeAdd(cursor, part);
        }
        if (insertError) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, insertError); }); return; }
        AVMutableAudioMixInputParameters *bedMix = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:bed];
        [bedMix setVolume:level atTime:kCMTimeZero];
        [bedMix setVolumeRampFromStartVolume:level toEndVolume:0.0 timeRange:CMTimeRangeMake(narrationDuration, tailDuration)];
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix]; mix.inputParameters = @[bedMix];
        NSURL *output = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"scene_remix_%@.m4a", NSUUID.UUID.UUIDString]]];
        AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetAppleM4A]; exporter.outputURL = output; exporter.outputFileType = AVFileTypeAppleM4A; exporter.audioMix = mix;
        [exporter exportAsynchronouslyWithCompletionHandler:^{
            NSData *data = exporter.status == AVAssetExportSessionStatusCompleted ? [NSData dataWithContentsOfURL:output] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(data, exporter.error); });
        }];
    });
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
        [self endExportUIWithEntry:newEntry error:error];
    }];
}

/// Splices a true silent gap into a copy of the clip using AVMutableComposition (an
/// empty time range on a composition track plays back as silence — no separately
/// generated silent audio file is needed), then exports and writes the result
/// back over the same clip.
- (void)insertSilenceAtFraction:(CGFloat)fraction
                        duration:(NSTimeInterval)silenceDuration
                      completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    NSURL *sourceURL = self.audioURL;
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

    [self exportComposition:composition completion:completion];
}

#pragma mark - Trim (keeps only the selected range, discards the rest)

- (void)handleTrimTapped {
    CGFloat start = self.rangeSelector.startFraction;
    CGFloat end = self.rangeSelector.endFraction;

    [self beginExportUI];
    [self trimToStartFraction:start endFraction:end completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithEntry:newEntry error:error];
    }];
}

- (void)trimToStartFraction:(CGFloat)startFraction
                  endFraction:(CGFloat)endFraction
                   completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    NSURL *sourceURL = self.audioURL;
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

    [self exportComposition:composition completion:completion];
}

#pragma mark - Normalize (real peak analysis + gain applied only within the selection)

- (void)handleNormalizeTapped {
    // Every edit in this editor applies to this clip in place now (the
    // pre-edit audio is snapshotted for Undo), so there is no save-as-new
    // choice to offer — partial selections work exactly like full ones.
    [self performNormalizeStart:self.rangeSelector.startFraction
                            end:self.rangeSelector.endFraction];
}

- (void)performNormalizeStart:(CGFloat)start end:(CGFloat)end {
    [self beginExportUI];
    [self normalizeStartFraction:start endFraction:end completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithEntry:newEntry error:error];
    }];
}

/// Reads the full clip into a PCM buffer, finds the peak sample magnitude within the
/// selected frame range, scales just those samples so that peak lands near -1 dBFS
/// (0.891 linear), then writes the whole buffer back out. Runs off the main thread since
/// it touches every sample in the file.
- (void)normalizeStartFraction:(CGFloat)startFraction
                     endFraction:(CGFloat)endFraction
                      completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    NSURL *sourceURL = self.audioURL;

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

        [self replaceEditedAudioData:audioData extension:@"caf" completion:completion];
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

#pragma mark - Shared export plumbing (Insert Silence + Trim both build a composition
#pragma mark   and just need it exported to m4a and written back over the same clip)

- (void)exportComposition:(AVMutableComposition *)composition
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

        [self replaceEditedAudioData:audioData extension:@"m4a" completion:completion];
    }];
}

- (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:@"EZTTSClipEditViewController" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)beginExportUI {
    self.insertSilenceButton.enabled = NO;
    self.normalizeButton.enabled = NO;
    self.trimButton.enabled = NO;
    self.undoButtonItem.enabled = NO;
    [self.exportSpinner startAnimating];
}

- (void)endExportUIWithEntry:(EZTTSManifestEntry * _Nullable)entry
                       error:(NSError * _Nullable)error
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
            [self refreshUndoButton];
            return;
        }
        // Every edit lands on this same clip now: sync the screen with the
        // updated entry and redraw the waveform. No confirmation alert —
        // the change is simply there, and Undo can walk it back.
        if (entry) self.entry = entry;
        [self loadWaveform];
        [self refreshUndoButton];
    });
}

#pragma mark - Speed section

- (void)setupSpeedSection {
    self.speedSectionLabel = [self sectionHeaderLabel];
    self.speedSectionLabel.text = @"SPEED";
    [self.scrollView addSubview:self.speedSectionLabel];

    self.speedSlider = [[UISlider alloc] init];
    self.speedSlider.minimumValue = 0.5;
    self.speedSlider.maximumValue = 2.0;
    self.speedSlider.tintColor = EZEditElectricBlue();
    id storedRate = self.entry.metadata[@"playbackRate"];
    self.speedSlider.value = [storedRate isKindOfClass:[NSNumber class]] ? [storedRate floatValue] : 1.0f;
    [self.speedSlider addTarget:self action:@selector(handleSpeedSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.speedSlider addTarget:self action:@selector(handleSpeedSliderReleased:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [self.scrollView addSubview:self.speedSlider];

    self.speedValueLabel = [[UILabel alloc] init];
    self.speedValueLabel.adjustsFontSizeToFitWidth = YES;
    self.speedValueLabel.minimumScaleFactor = 0.5;
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
    float rate = slider.value;
    if (fabsf(rate - 1.0f) < 0.005f) {
        [self persistPlaybackRate:1.0f];
        return;
    }
    // Bake the rate into the clip's audio (in place, undoable) instead of
    // storing a playback-only flag that other players ignore. The render
    // scales its frame count by 1/rate so nothing is padded or cut off.
    if (self.previewPlayer) {
        [self.previewPlayer stop];
        self.previewPlayer = nil;
        [self.speedPreviewButton setImage:[UIImage systemImageNamed:@"play.circle"] forState:UIControlStateNormal];
    }
    AVAudioUnitTimePitch *rateUnit = [[AVAudioUnitTimePitch alloc] init];
    rateUnit.rate = rate;
    slider.enabled = NO;
    [self beginExportUI];
    [self applyEffectNodes:@[rateUnit] tailSeconds:0 frameScale:(1.0 / rate)
                completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        slider.enabled = YES;
        if (!error) {
            // The rate now lives in the audio itself: clear the legacy
            // playback-only flag so list playback doesn't apply it twice,
            // and re-baseline the slider on the baked clip.
            [self persistPlaybackRate:1.0f];
            self.speedSlider.value = 1.0f;
            [self updateSpeedValueLabel];
        }
        [self endExportUIWithEntry:newEntry error:error];
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
    // A clip may still be playing from History; the preview takes over.
    [[EZMediaPlayerManager sharedManager] stop];
    NSError *sessionError = nil;
    if (!EZActivatePlaybackAudioSession(&sessionError)) {
        [self presentErrorAlert:sessionError title:@"Couldn't start audio playback"];
        return;
    }

    NSURL *audioURL = self.audioURL;
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
    self.voiceSectionLabel.text = @"CHANGE VOICE";
    [self.scrollView addSubview:self.voiceSectionLabel];

    self.voiceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.voiceButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.voiceButton.titleLabel.font = [UIFont systemFontOfSize:15];
    self.voiceButton.backgroundColor = [EZTheme cardColor];
    self.voiceButton.layer.cornerRadius = 8;
    self.voiceButton.layer.borderWidth = 1.0;
    self.voiceButton.layer.borderColor = [EZEditElectricBlue() colorWithAlphaComponent:0.3].CGColor;
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

#pragma mark - Effects (apply to the whole clip, in place)

- (void)setupEffectsSection {
    self.effectsSectionLabel = [self sectionHeaderLabel];
    self.effectsSectionLabel.text = @"EFFECTS — APPLIED TO WHOLE CLIP";
    [self.scrollView addSubview:self.effectsSectionLabel];

    self.pitchValueLabel = [[UILabel alloc] init];
    self.pitchValueLabel.adjustsFontSizeToFitWidth = YES;
    self.pitchValueLabel.minimumScaleFactor = 0.5;
    self.pitchValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.pitchValueLabel.textAlignment = NSTextAlignmentRight;
    [self.scrollView addSubview:self.pitchValueLabel];

    self.pitchSlider = [[UISlider alloc] init];
    self.pitchSlider.minimumValue = -1200; // cents: -12 semitones
    self.pitchSlider.maximumValue = 1200;  // +12 semitones
    self.pitchSlider.value = 0;
    self.pitchSlider.tintColor = EZEditElectricBlue();
    self.pitchSlider.minimumValueImage = [UIImage systemImageNamed:@"arrow.down"];
    self.pitchSlider.maximumValueImage = [UIImage systemImageNamed:@"arrow.up"];
    [self.pitchSlider addTarget:self action:@selector(handlePitchSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.pitchSlider];
    [self updatePitchValueLabel];

    self.applyPitchButton = [self actionButtonWithTitle:@"  Apply Pitch Shift" systemImage:@"waveform"];
    [self.applyPitchButton addTarget:self action:@selector(handlePitchApplyTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.applyPitchButton];

    self.reverbButton = [self smallActionButtonWithTitle:@"Reverb" systemImage:@"circle.dashed" color:[UIColor systemPurpleColor]];
    self.reverbButton.hidden = NO; // unlike the range-tools row, these three are always available
    [self.reverbButton addTarget:self action:@selector(handleReverbTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.reverbButton];

    self.echoButton = [self smallActionButtonWithTitle:@"Echo" systemImage:@"waveform.path.ecg.rectangle" color:[UIColor systemOrangeColor]];
    self.echoButton.hidden = NO;
    [self.echoButton addTarget:self action:@selector(handleEchoTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.echoButton];

    self.eqButton = [self smallActionButtonWithTitle:@"EQ" systemImage:@"slider.horizontal.3" color:[UIColor systemTealColor]];
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
    [self applyEffectNodes:@[pitchUnit] tailSeconds:0.2 frameScale:1.0
                completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithEntry:newEntry error:error];
    }];
}

- (void)handleReverbTapped {
    AVAudioUnitReverb *reverb = [[AVAudioUnitReverb alloc] init];
    [reverb loadFactoryPreset:AVAudioUnitReverbPresetMediumHall];
    reverb.wetDryMix = 35;

    [self beginEffectUI];
    [self applyEffectNodes:@[reverb] tailSeconds:2.5 frameScale:1.0
                completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithEntry:newEntry error:error];
    }];
}

- (void)handleEchoTapped {
    AVAudioUnitDelay *delay = [[AVAudioUnitDelay alloc] init];
    delay.delayTime = 0.32;
    delay.feedback = 32;
    delay.lowPassCutoff = 15000;
    delay.wetDryMix = 30;

    [self beginEffectUI];
    [self applyEffectNodes:@[delay] tailSeconds:2.0 frameScale:1.0
                completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithEntry:newEntry error:error];
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
    [self applyEffectNodes:@[eq] tailSeconds:0.2 frameScale:1.0
                completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        [self endExportUIWithEntry:newEntry error:error];
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
/// effect node(s), then writes the rendered result back over the same clip. This is
/// the one piece of plumbing all four effects (and the speed bake) share — each just
/// configures its own AVAudioUnit and hands it to this. `tailSeconds` extends the
/// render past the source's natural length so effects with a decay (reverb, echo)
/// don't get cut off mid-tail. `frameScale` scales the render length for nodes that
/// change the duration (the speed bake renders source/rate frames); effects pass 1.0.
- (void)applyEffectNodes:(NSArray<AVAudioUnit *> *)effectNodes
              tailSeconds:(NSTimeInterval)tailSeconds
               frameScale:(CGFloat)frameScale
               completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    NSURL *sourceURL = self.audioURL;

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

        AVAudioFrameCount totalFramesToRender = (AVAudioFrameCount)(sourceFrameCount * frameScale) + (AVAudioFrameCount)(tailSeconds * format.sampleRate);
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

        [self replaceEditedAudioData:audioData extension:@"caf" completion:completion];
    });
}

#pragma mark - Shared UI helpers

- (UIButton *)actionButtonWithTitle:(NSString *)title systemImage:(NSString *)imageName {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:imageName] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.tintColor = EZEditElectricBlue();
    return button;
}

- (UIButton *)smallActionButtonWithTitle:(NSString *)title systemImage:(NSString *)imageName color:(UIColor *)color {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = title;
    config.image = [UIImage systemImageNamed:imageName];
    config.imagePadding = 4;
    config.imagePlacement = NSDirectionalRectEdgeTop;
    config.baseBackgroundColor = [color colorWithAlphaComponent:0.16];
    config.baseForegroundColor = color;
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

    CGFloat promptTextWidth = width - 48;
    CGFloat promptTextHeight = [self.promptLabel sizeThatFits:CGSizeMake(promptTextWidth, CGFLOAT_MAX)].height;
    CGFloat collapsedHeight = 60;
    CGFloat promptHeight = self.promptExpanded ? MAX(collapsedHeight, ceil(promptTextHeight) + 24) : collapsedHeight;
    self.promptContainer.frame = CGRectMake(margin, y, width, promptHeight);
    self.promptLabel.frame = CGRectMake(12, 10, promptTextWidth, promptHeight - 20);
    self.promptDisclosureImage.frame = CGRectMake(width - 32, 8, 24, 24);
    y = CGRectGetMaxY(self.promptContainer.frame) + 20;

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

    if (self.backgroundSectionLabel) {
        self.backgroundSectionLabel.frame = CGRectMake(margin, y, width, 16);
        y = CGRectGetMaxY(self.backgroundSectionLabel.frame) + 8;
        self.backgroundLevelLabel.frame = CGRectMake(margin, y, 52, 24);
        self.backgroundLevelSlider.frame = CGRectMake(margin + 60, y, width - 60, 24);
        y = CGRectGetMaxY(self.backgroundLevelSlider.frame) + 28;
    }

    // Speed section
    self.speedSectionLabel.frame = CGRectMake(margin, y, width, 16);
    y = CGRectGetMaxY(self.speedSectionLabel.frame) + 8;
    self.speedValueLabel.frame = CGRectMake(margin, y, 60, 24);
    self.speedSlider.frame = CGRectMake(margin + 68, y, width - 68, 24);
    y = CGRectGetMaxY(self.speedSlider.frame) + 10;
    self.speedPreviewButton.frame = CGRectMake(margin, y, width, 32);
    y = CGRectGetMaxY(self.speedPreviewButton.frame) + 28;

    // Voice section (TTS clips only — absent entirely for sounds)
    if (self.voiceSectionLabel) {
        self.voiceSectionLabel.frame = CGRectMake(margin, y, width, 16);
        y = CGRectGetMaxY(self.voiceSectionLabel.frame) + 8;
        self.voiceButton.frame = CGRectMake(margin, y, width, 40);
        y = CGRectGetMaxY(self.voiceButton.frame) + 10;
        self.regenerateWithVoiceButton.frame = CGRectMake(margin, y, width, 32);
        y = CGRectGetMaxY(self.regenerateWithVoiceButton.frame) + 28;
    }

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
