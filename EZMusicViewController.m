// EZMusicViewController.m
// EZCompleteUI v1.0
//
// Purpose:
//   The "AI Music" screen. See EZMusicViewController.h for the overview.
//
//   How the pieces fit together (read this first if you're new to the file):
//     - EZMusicService (separate class) does every network call. This file never
//       builds a request itself, so pricing and billing stay on the server.
//     - The Create tab collects the user's choices and calls
//       -startGenerationWithPrompt:... The server reserves the coins and
//       replies right away; the song is composed in the background.
//     - The Library tab shows every song from the server. Songs that are still
//       composing show a spinner, and one poll per generation (EZMusicPollToken)
//       keeps them updating. If the user leaves and comes back, the library load
//       finds any still-pending songs and resumes polling, so nothing is lost.
//     - Playback streams from a short-lived signed URL fetched fresh on each
//       play, so an expired link can never break a song.
//     - Sharing downloads the MP3 to a temp file and opens the share sheet
//       (Save to Files, AirDrop, Messages, ...).
//
//   Edge cases handled on purpose:
//     - Not enough coins: shown before sending (from the cached balance) and
//       again if the server says so; both offer the coin store.
//     - Connection drops while starting: the song may have started anyway, so
//       the library is checked and the user is told not to blindly retry.
//     - Prices/limits can't be loaded: Generate becomes "Reload Pricing".
//     - Songs that fail are refunded by the server; the row says so.
//     - Closing the screen mid-generation: polling stops, the server finishes,
//       and the song is waiting in the Library next time.
//     - Pagination uses an inclusive timestamp cursor and de-duplicates by id,
//       so variants created at the same instant are never skipped.
//
// Changes:
//   - Initial version.

#import "EZMusicViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <math.h>
#import "EZMusicLibraryManager.h"
#import "EZPhotoGalleryViewController.h"
#import "EZMusicService.h"
#import "EZEntitlementManager.h"
#import "EZCoinStoreViewController.h"
#import "helpers.h"

// Looks up a localized string and falls back to the English text when a
// translation doesn't exist yet, so untranslated languages show English
// instead of a raw key.
#define EZMusicText(key, english) \
    NSLocalizedStringWithDefaultValue((key), nil, [NSBundle mainBundle], (english), nil)

static const NSInteger  kLibraryPageSize        = 30;
static const NSUInteger kPromptCharacterLimit   = 2000;
static const NSUInteger kTitleCharacterLimit    = 120;
static const NSInteger  kDurationStepSeconds    = 5;
static const NSInteger  kDefaultDurationSeconds = 60;
static const NSInteger  kMaxVariantChoices      = 5;

// KVO context for AVPlayerItem.status so we only react to our own observation.
static void *kEZMusicItemStatusContext = &kEZMusicItemStatusContext;

typedef NS_ENUM(NSInteger, EZMusicTab) {
    EZMusicTabCreate  = 0,
    EZMusicTabLibrary = 1,
};

#pragma mark - Safe value helpers

// Server JSON can contain NSNull or unexpected types; these never crash.
static NSString *EZMusicString(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : @"";
}

static NSInteger EZMusicInteger(id value) {
    return [value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value integerValue] : 0;
}

static NSString *EZMusicCompactStyle(NSString *prompt) {
    NSArray<NSString *> *words = [[prompt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *chosen = [NSMutableArray arrayWithCapacity:3];
    for (NSString *word in words) {
        NSString *clean = [word stringByTrimmingCharactersInSet:NSCharacterSet.punctuationCharacterSet];
        if (clean.length) [chosen addObject:clean];
        if (chosen.count == 3) break;
    }
    return [chosen componentsJoinedByString:@" "];
}

static NSString *EZMusicFormattedDuration(NSInteger totalSeconds) {
    NSInteger safeSeconds = MAX(0, totalSeconds);
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(safeSeconds / 60), (long)(safeSeconds % 60)];
}

// Makes a user-chosen title safe to use as a file name.
static NSString *EZMusicSafeFileName(NSString *title) {
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|\n\r\t"];
    NSString *cleaned = [[title componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@" "];
    cleaned = [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (cleaned.length > 60) cleaned = [cleaned substringToIndex:60];
    return cleaned.length > 0 ? cleaned : @"Song";
}

// created_at arrives as e.g. 2026-10-12T04:29:34.123456+00:00. The fractional
// part isn't needed for display and some formatter versions reject six digits,
// so it's stripped before parsing.
static NSDate *EZMusicDateFromServerString(NSString *serverString) {
    if (serverString.length == 0) return nil;
    NSString *trimmed = [serverString stringByReplacingOccurrencesOfString:@"\\.\\d+"
                                                                withString:@""
                                                                   options:NSRegularExpressionSearch
                                                                     range:NSMakeRange(0, serverString.length)];
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [formatter dateFromString:trimmed];
}

#pragma mark - Library row

@interface EZMusicWaveformView : UIView
@property (nonatomic, copy) NSString *representedIdentifier;
- (void)showWaveformForURL:(nullable NSURL *)url identifier:(NSString *)identifier;
@end

@implementation EZMusicWaveformView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    NSArray<NSNumber *> *levels = objc_getAssociatedObject(self, @selector(drawRect:));
    if (!levels.count) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGFloat count = levels.count, gap = 2.0;
    CGFloat width = MAX(1.0, (CGRectGetWidth(rect) - gap * (count - 1)) / count);
    CGFloat middle = CGRectGetMidY(rect);
    UIColor *color = [UIColor systemBlueColor];
    CGContextSetFillColorWithColor(context, [color colorWithAlphaComponent:0.68].CGColor);
    for (NSUInteger index = 0; index < levels.count; index++) {
        CGFloat height = MAX(3.0, MIN(CGRectGetHeight(rect), levels[index].doubleValue * CGRectGetHeight(rect)));
        CGRect bar = CGRectMake(index * (width + gap), middle - height / 2.0, width, height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:width / 2.0];
        [path fill];
    }
}

- (void)showWaveformForURL:(NSURL *)url identifier:(NSString *)identifier {
    self.representedIdentifier = identifier;
    static NSCache<NSString *, NSArray<NSNumber *> *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 80; });
    NSArray<NSNumber *> *cached = url.path.length ? [cache objectForKey:url.path] : nil;
    if (cached) { objc_setAssociatedObject(self, @selector(drawRect:), cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC); [self setNeedsDisplay]; return; }

    // A deterministic placeholder keeps completed rows visually informative
    // until their background local archive has finished downloading.
    NSMutableArray<NSNumber *> *placeholder = [NSMutableArray arrayWithCapacity:42];
    NSUInteger seed = identifier.hash;
    for (NSUInteger index = 0; index < 42; index++) {
        seed = seed * 1103515245u + 12345u;
        [placeholder addObject:@(0.18 + ((seed >> 16) & 0x7F) / 190.0)];
    }
    objc_setAssociatedObject(self, @selector(drawRect:), placeholder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self setNeedsDisplay];
    if (!url.isFileURL) return;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        if (!track) return;
        NSError *readerError = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
        if (!reader) return;
        NSDictionary *settings = @{ AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: @32,
                                    AVLinearPCMIsFloatKey: @YES, AVNumberOfChannelsKey: @1 };
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
        if (![reader canAddOutput:output]) return;
        [reader addOutput:output];
        if (![reader startReading]) return;
        NSMutableArray<NSNumber *> *samples = [NSMutableArray array];
        const NSUInteger stride = 1024, maximumSamples = 42000;
        NSUInteger sampleIndex = 0;
        CMSampleBufferRef buffer;
        while ((buffer = [output copyNextSampleBuffer])) {
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(buffer);
            size_t length = CMBlockBufferGetDataLength(block);
            char *bytes = NULL;
            if (CMBlockBufferGetDataPointer(block, 0, NULL, &length, &bytes) == kCMBlockBufferNoErr) {
                const float *values = (const float *)bytes;
                NSUInteger count = length / sizeof(float);
                for (NSUInteger i = 0; i < count; i++, sampleIndex++) {
                    if (sampleIndex % stride == 0) {
                        [samples addObject:@(MIN(1.0, fabsf(values[i])))];
                        if (samples.count >= maximumSamples) break;
                    }
                }
            }
            CFRelease(buffer);
            if (samples.count >= maximumSamples) break;
        }
        if (samples.count < 2) return;
        NSMutableArray<NSNumber *> *levels = [NSMutableArray arrayWithCapacity:42];
        for (NSUInteger bar = 0; bar < 42; bar++) {
            NSUInteger start = bar * samples.count / 42, end = MAX(start + 1, (bar + 1) * samples.count / 42);
            double peak = 0;
            for (NSUInteger i = start; i < MIN(end, samples.count); i++) peak = MAX(peak, samples[i].doubleValue);
            [levels addObject:@(0.12 + sqrt(peak) * 0.88)];
        }
        [cache setObject:levels forKey:url.path];
        dispatch_async(dispatch_get_main_queue(), ^{
            EZMusicWaveformView *strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf.representedIdentifier isEqualToString:identifier]) return;
            objc_setAssociatedObject(strongSelf, @selector(drawRect:), levels, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [strongSelf setNeedsDisplay];
        });
    });
}
@end

@interface EZMusicTrackCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UIImageView *favoriteView;
@property (nonatomic, strong) EZMusicWaveformView *waveformView;
@property (nonatomic, strong) NSLayoutConstraint *waveformHeightConstraint;
@property (nonatomic, copy, nullable) void (^playHandler)(void);
- (void)configureWithTitle:(NSString *)title
                    detail:(NSString *)detail
                    status:(NSString *)status
                 isCurrent:(BOOL)isCurrent
                 isPlaying:(BOOL)isPlaying
            isLoadingAudio:(BOOL)isLoadingAudio
                  favorite:(BOOL)favorite
             detailIsError:(BOOL)detailIsError
             waveformURL:(nullable NSURL *)waveformURL
      waveformIdentifier:(NSString *)waveformIdentifier;
@end

@implementation EZMusicTrackCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _playButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_playButton addTarget:self action:@selector(playButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_playButton];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    [self.contentView addSubview:_spinner];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.numberOfLines = 2;
    [self.contentView addSubview:_titleLabel];

    _detailLabel = [[UILabel alloc] init];
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _detailLabel.adjustsFontForContentSizeCategory = YES;
    _detailLabel.textColor = [UIColor secondaryLabelColor];
    _detailLabel.numberOfLines = 0;
    [self.contentView addSubview:_detailLabel];

    _waveformView = [[EZMusicWaveformView alloc] initWithFrame:CGRectZero];
    _waveformView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_waveformView];
    _waveformHeightConstraint = [_waveformView.heightAnchor constraintEqualToConstant:0];

    _favoriteView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"star.fill"]];
    _favoriteView.translatesAutoresizingMaskIntoConstraints = NO;
    _favoriteView.tintColor = [UIColor systemYellowColor];
    _favoriteView.hidden = YES;
    [self.contentView addSubview:_favoriteView];

    // Thin playback progress line along the bottom edge of the row.
    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    _progressView.translatesAutoresizingMaskIntoConstraints = NO;
    _progressView.hidden = YES;
    [self.contentView addSubview:_progressView];

    [NSLayoutConstraint activateConstraints:@[
        [_playButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
        [_playButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_playButton.widthAnchor constraintEqualToConstant:46],
        [_playButton.heightAnchor constraintEqualToConstant:46],

        [_spinner.centerXAnchor constraintEqualToAnchor:_playButton.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:_playButton.centerYAnchor],

        [_favoriteView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
        [_favoriteView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        [_favoriteView.widthAnchor constraintEqualToConstant:18],
        [_favoriteView.heightAnchor constraintEqualToConstant:18],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_playButton.trailingAnchor constant:8],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_favoriteView.leadingAnchor constant:-8],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],

        [_detailLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
        [_waveformView.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_waveformView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
        [_waveformView.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:5],
        _waveformHeightConstraint,
        [_detailLabel.topAnchor constraintEqualToAnchor:_waveformView.bottomAnchor constant:3],
        [_detailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],

        [_progressView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [_progressView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [_progressView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
    ]];
    return self;
}

- (void)playButtonTapped {
    if (self.playHandler) self.playHandler();
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.playHandler = nil;
    [self.spinner stopAnimating];
    self.progressView.progress = 0;
    self.progressView.hidden = YES;
}

- (void)configureWithTitle:(NSString *)title
                    detail:(NSString *)detail
                    status:(NSString *)status
                 isCurrent:(BOOL)isCurrent
                 isPlaying:(BOOL)isPlaying
            isLoadingAudio:(BOOL)isLoadingAudio
                  favorite:(BOOL)favorite
             detailIsError:(BOOL)detailIsError
             waveformURL:(NSURL *)waveformURL
      waveformIdentifier:(NSString *)waveformIdentifier {
    self.titleLabel.text = title;
    self.detailLabel.text = detail;
    self.detailLabel.textColor = detailIsError ? [UIColor systemOrangeColor] : [UIColor secondaryLabelColor];
    self.favoriteView.hidden = !favorite;
    BOOL showWaveform = [status isEqualToString:@"complete"];
    self.waveformHeightConstraint.constant = showWaveform ? 30 : 0;
    self.waveformView.hidden = !showWaveform;
    if (showWaveform) [self.waveformView showWaveformForURL:waveformURL identifier:waveformIdentifier];

    BOOL showSpinner = [status isEqualToString:@"pending"] || isLoadingAudio;
    if (showSpinner) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    self.playButton.hidden = showSpinner;

    UIImageSymbolConfiguration *symbolConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightRegular];
    if ([status isEqualToString:@"failed"]) {
        [self.playButton setImage:[UIImage systemImageNamed:@"exclamationmark.triangle.fill" withConfiguration:symbolConfig]
                         forState:UIControlStateNormal];
        self.playButton.tintColor = [UIColor systemOrangeColor];
        self.playButton.enabled = NO;
        self.playButton.accessibilityLabel = EZMusicText(@"EZMusic.A11y.Failed", @"Song failed");
    } else {
        NSString *symbol = (isCurrent && isPlaying) ? @"pause.circle.fill" : @"play.circle.fill";
        [self.playButton setImage:[UIImage systemImageNamed:symbol withConfiguration:symbolConfig]
                         forState:UIControlStateNormal];
        self.playButton.tintColor = [UIColor systemBlueColor];
        self.playButton.enabled = YES;
        self.playButton.accessibilityLabel = (isCurrent && isPlaying)
            ? EZMusicText(@"EZMusic.A11y.Pause", @"Pause")
            : EZMusicText(@"EZMusic.A11y.Play", @"Play");
    }

    self.progressView.hidden = !isCurrent;
    if (!isCurrent) self.progressView.progress = 0;
}

@end

#pragma mark - View controller

static const NSTimeInterval kEZMusicMaximumReferenceSeconds = 120.0;
static const unsigned long long kEZMusicMaximumReferenceBytes = 12ULL * 1024ULL * 1024ULL;

@interface EZMusicViewController () <UITableViewDataSource, UITableViewDelegate,
                                     UITextViewDelegate, UITextFieldDelegate, UIDocumentPickerDelegate,
                                     PHPickerViewControllerDelegate>

// Chrome
@property (nonatomic, strong) UISegmentedControl *tabControl;

// Create tab
@property (nonatomic, strong) UIScrollView *createScrollView;
@property (nonatomic, strong) UIView *promptContainer;
@property (nonatomic, strong) UITextView *promptTextView;
@property (nonatomic, strong) UILabel *promptPlaceholderLabel;
@property (nonatomic, strong) UILabel *characterCountLabel;
@property (nonatomic, strong) UITextView *lyricsTextView;
@property (nonatomic, strong) UIButton *referenceButton;
@property (nonatomic, strong) UILabel *referenceDetailLabel;
@property (nonatomic, strong) UISegmentedControl *referenceModeControl;
@property (nonatomic, strong) UIButton *videoSoundtrackButton;
@property (nonatomic, assign) BOOL pickingVideoSoundtrack;
@property (nonatomic, strong) UITextField *titleField;
@property (nonatomic, strong) UISwitch *instrumentalSwitch;
@property (nonatomic, strong) UISlider *durationSlider;
@property (nonatomic, strong) UILabel *durationValueLabel;
@property (nonatomic, strong) UISegmentedControl *variantControl;
@property (nonatomic, strong) UILabel *quoteLabel;
@property (nonatomic, strong) UIButton *generateButton;
@property (nonatomic, strong) UIButton *surpriseButton;
@property (nonatomic, strong) UILabel *statusLabel;

// Library tab
@property (nonatomic, strong) UITableView *libraryTable;
@property (nonatomic, strong) UILabel *emptyStateLabel;
@property (nonatomic, strong) UIRefreshControl *libraryRefreshControl;
@property (nonatomic, strong) UILabel *playlistTitleLabel;
@property (nonatomic, strong) UILabel *playlistDetailLabel;
@property (nonatomic, strong) UIButton *playlistPreviousButton;
@property (nonatomic, strong) UIButton *playlistPlayButton;
@property (nonatomic, strong) UIButton *playlistNextButton;

// Overlays
@property (nonatomic, strong, nullable) UIView *busyOverlay;
@property (nonatomic, strong, nullable) UIView *toastView;

// Server data
@property (nonatomic, copy, nullable) NSDictionary *config;
@property (nonatomic, assign) BOOL isLoadingConfig;
@property (nonatomic, assign) BOOL didApplyConfigOnce;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *entries;
@property (nonatomic, assign) BOOL hasMoreEntries;
@property (nonatomic, assign) BOOL isLoadingPage;
@property (nonatomic, assign) BOOL libraryLoadedOnce;
@property (nonatomic, assign) NSUInteger libraryRequestCounter;   // invalidates superseded responses
@property (nonatomic, copy, nullable) NSString *libraryErrorMessage;

// Generation
@property (nonatomic, assign) BOOL isStartingGeneration;
@property (nonatomic, strong) NSMutableDictionary<NSString *, EZMusicPollToken *> *pollTokens;
@property (nonatomic, strong) NSMutableSet<NSString *> *announcedGenerationIDs;
@property (nonatomic, strong) NSMutableSet<NSString *> *retainingEntryIDs;

// Playback
@property (nonatomic, strong, nullable) AVPlayer *player;
@property (nonatomic, strong, nullable) AVPlayerItem *observedItem;
@property (nonatomic, strong, nullable) id timeObserver;
@property (nonatomic, copy, nullable) NSString *playingEntryID;   // loaded song (may be paused)
@property (nonatomic, copy, nullable) NSString *loadingEntryID;   // song whose URL/audio is loading
@property (nonatomic, assign) BOOL isPlaybackActive;
@property (nonatomic, copy, nullable) NSURL *referenceURL;
@property (nonatomic, copy, nullable) NSString *referenceSourceName;
@property (nonatomic, assign) EZMusicReferenceMode referenceMode;
@property (nonatomic, assign) BOOL referenceModeLocked;
@property (nonatomic, strong, nullable) UIView *referenceSourceOverlay;
@property (nonatomic, strong, nullable) UIView *musicDialogOverlay;

@end

@implementation EZMusicViewController

- (instancetype)initWithReferenceURL:(NSURL *)referenceURL sourceName:(NSString *)sourceName {
    return [self initWithReferenceURL:referenceURL sourceName:sourceName referenceMode:EZMusicReferenceModeSource];
}

- (instancetype)initWithReferenceURL:(NSURL *)referenceURL
                          sourceName:(NSString *)sourceName
                       referenceMode:(EZMusicReferenceMode)referenceMode {
    self = [super init];
    if (self) {
        _referenceURL = [referenceURL copy];
        _referenceSourceName = [sourceName copy];
        _referenceMode = referenceMode;
        _referenceModeLocked = YES;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.entries = [NSMutableArray array];
    self.pollTokens = [NSMutableDictionary dictionary];
    self.announcedGenerationIDs = [NSMutableSet set];
    self.retainingEntryIDs = [NSMutableSet set];

    self.tabControl = [[UISegmentedControl alloc] initWithItems:@[
        EZMusicText(@"EZMusic.Tab.Create", @"Create"),
        EZMusicText(@"EZMusic.Tab.Library", @"Library"),
    ]];
    self.tabControl.selectedSegmentIndex = EZMusicTabCreate;
    [self.tabControl addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.tabControl;

    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                 target:self
                                 action:@selector(closeTapped)];
    }

    [self buildLibraryView];
    [self buildCreateView];
    if (self.referenceURL.isFileURL && self.referenceModeLocked) {
        [[EZMusicLibraryManager sharedManager] archiveReferenceAtURL:self.referenceURL
                                                           sourceName:self.referenceSourceName
                                                                mode:@"source"];
    }
    [self showTab:EZMusicTabCreate];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(keyboardWillChangeFrame:)
                   name:UIKeyboardWillChangeFrameNotification object:nil];
    [center addObserver:self selector:@selector(coinBalanceMayHaveChanged)
                   name:@"EZSubscriptionUpdated" object:nil];
    [center addObserver:self selector:@selector(coinBalanceMayHaveChanged)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(audioSessionInterrupted:)
                   name:AVAudioSessionInterruptionNotification object:nil];

    [self updateQuote];
    [self loadConfig];
    [self loadLibraryResetting:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self coinBalanceMayHaveChanged];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Only tear down when the screen is really going away, not when a share
    // sheet or the coin store is merely presented on top of it.
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed || self.isMovingFromParentViewController) {
        [self cancelAllPolling];
        [self stopPlaybackReleasingSession:YES];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cancelAllPolling];
    [self releasePlayerResources];
}

- (void)closeTapped {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Building the Create tab

- (UILabel *)sectionHeaderLabelWithText:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = [text uppercaseString];
    return label;
}

- (void)buildCreateView {
    self.createScrollView = [[UIScrollView alloc] init];
    self.createScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.createScrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.createScrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.createScrollView];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.layoutMarginsRelativeArrangement = YES;
    stack.layoutMargins = UIEdgeInsetsMake(16, 16, 32, 16);
    [self.createScrollView addSubview:stack];

    // ── Prompt ───────────────────────────────────────────────────────────────
    [stack addArrangedSubview:[self sectionHeaderLabelWithText:EZMusicText(@"EZMusic.Prompt.Header", @"Describe your song")]];

    self.promptContainer = [[UIView alloc] init];
    self.promptContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.promptContainer.layer.cornerRadius = 12;
    self.promptContainer.layer.borderWidth = 1;
    self.promptContainer.layer.borderColor = [UIColor systemGray4Color].CGColor;

    self.promptTextView = [[UITextView alloc] init];
    self.promptTextView.translatesAutoresizingMaskIntoConstraints = NO;
    self.promptTextView.backgroundColor = [UIColor clearColor];
    self.promptTextView.font = [UIFont systemFontOfSize:16];
    self.promptTextView.textContainerInset = UIEdgeInsetsMake(12, 10, 26, 10);
    self.promptTextView.delegate = self;
    self.promptTextView.accessibilityLabel = EZMusicText(@"EZMusic.Prompt.Header", @"Describe your song");
    [self.promptContainer addSubview:self.promptTextView];

    self.promptPlaceholderLabel = [[UILabel alloc] init];
    self.promptPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.promptPlaceholderLabel.font = [UIFont systemFontOfSize:16];
    self.promptPlaceholderLabel.textColor = [UIColor placeholderTextColor];
    self.promptPlaceholderLabel.numberOfLines = 0;
    self.promptPlaceholderLabel.userInteractionEnabled = NO;
    self.promptPlaceholderLabel.text = EZMusicText(@"EZMusic.Prompt.Placeholder",
        @"e.g. Upbeat 80s synthwave with driving bass and a dreamy chorus");
    [self.promptContainer addSubview:self.promptPlaceholderLabel];

    self.characterCountLabel = [[UILabel alloc] init];
    self.characterCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.characterCountLabel.font = [UIFont systemFontOfSize:12];
    self.characterCountLabel.textColor = [UIColor secondaryLabelColor];
    [self.promptContainer addSubview:self.characterCountLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.promptTextView.topAnchor constraintEqualToAnchor:self.promptContainer.topAnchor],
        [self.promptTextView.bottomAnchor constraintEqualToAnchor:self.promptContainer.bottomAnchor],
        [self.promptTextView.leadingAnchor constraintEqualToAnchor:self.promptContainer.leadingAnchor],
        [self.promptTextView.trailingAnchor constraintEqualToAnchor:self.promptContainer.trailingAnchor],
        [self.promptContainer.heightAnchor constraintGreaterThanOrEqualToConstant:150],
        [self.promptPlaceholderLabel.topAnchor constraintEqualToAnchor:self.promptContainer.topAnchor constant:12],
        [self.promptPlaceholderLabel.leadingAnchor constraintEqualToAnchor:self.promptContainer.leadingAnchor constant:15],
        [self.promptPlaceholderLabel.trailingAnchor constraintEqualToAnchor:self.promptContainer.trailingAnchor constant:-15],
        [self.characterCountLabel.trailingAnchor constraintEqualToAnchor:self.promptContainer.trailingAnchor constant:-12],
        [self.characterCountLabel.bottomAnchor constraintEqualToAnchor:self.promptContainer.bottomAnchor constant:-6],
    ]];
    [stack addArrangedSubview:self.promptContainer];

    // ── Lyrics ───────────────────────────────────────────────────────────────
    [stack setCustomSpacing:16 afterView:self.promptContainer];
    [stack addArrangedSubview:[self sectionHeaderLabelWithText:@"Lyrics (optional)"]];
    self.lyricsTextView = [[UITextView alloc] init];
    self.lyricsTextView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.lyricsTextView.layer.cornerRadius = 12;
    self.lyricsTextView.layer.borderWidth = 1;
    self.lyricsTextView.layer.borderColor = [UIColor systemGray4Color].CGColor;
    self.lyricsTextView.font = [UIFont systemFontOfSize:15];
    self.lyricsTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    self.lyricsTextView.text = @"";
    self.lyricsTextView.accessibilityLabel = @"Lyrics";
    [self.lyricsTextView.heightAnchor constraintEqualToConstant:116].active = YES;
    [stack addArrangedSubview:self.lyricsTextView];

    // ── Reference ────────────────────────────────────────────────────────────
    [stack setCustomSpacing:16 afterView:self.lyricsTextView];
    [stack addArrangedSubview:[self sectionHeaderLabelWithText:@"Audio reference (optional)"]];
    self.referenceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.referenceButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.referenceButton.layer.cornerRadius = 12;
    self.referenceButton.layer.borderWidth = 1;
    self.referenceButton.layer.borderColor = [UIColor systemGray4Color].CGColor;
    self.referenceButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.referenceButton.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
    [self.referenceButton setImage:[UIImage systemImageNamed:@"waveform.badge.plus"] forState:UIControlStateNormal];
    [self.referenceButton setTitle:@"  Add audio reference" forState:UIControlStateNormal];
    [self.referenceButton addTarget:self action:@selector(referenceTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.referenceButton.heightAnchor constraintEqualToConstant:48].active = YES;
    [stack addArrangedSubview:self.referenceButton];
    self.referenceModeControl = [[UISegmentedControl alloc] initWithItems:@[
        @"Guide new music", @"Use in song"
    ]];
    self.referenceModeControl.selectedSegmentIndex = self.referenceMode;
    self.referenceModeControl.accessibilityLabel = @"How to use the audio reference";
    self.referenceModeControl.enabled = self.referenceURL.isFileURL && !self.referenceModeLocked;
    [self.referenceModeControl addTarget:self action:@selector(referenceModeChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.referenceModeControl];
    self.referenceDetailLabel = [[UILabel alloc] init];
    self.referenceDetailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.referenceDetailLabel.textColor = [UIColor secondaryLabelColor];
    self.referenceDetailLabel.numberOfLines = 0;
    [stack addArrangedSubview:self.referenceDetailLabel];
    [self updateReferencePresentation];

    // Video-to-music is intentionally separate from audio reference modes.
    // It analyses the visual video and creates a soundtrack to mux onto it.
    [stack setCustomSpacing:18 afterView:self.referenceDetailLabel];
    [stack addArrangedSubview:[self sectionHeaderLabelWithText:@"Video soundtrack"]];
    self.videoSoundtrackButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.videoSoundtrackButton.backgroundColor = [UIColor systemPurpleColor];
    self.videoSoundtrackButton.layer.cornerRadius = 12;
    self.videoSoundtrackButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.videoSoundtrackButton.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
    [self.videoSoundtrackButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.videoSoundtrackButton setImage:[UIImage systemImageNamed:@"video.badge.plus"] forState:UIControlStateNormal];
    [self.videoSoundtrackButton setTintColor:UIColor.whiteColor];
    [self.videoSoundtrackButton setTitle:@"  Compose music for a video" forState:UIControlStateNormal];
    [self.videoSoundtrackButton addTarget:self action:@selector(videoSoundtrackTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.videoSoundtrackButton.heightAnchor constraintEqualToConstant:48].active = YES;
    [stack addArrangedSubview:self.videoSoundtrackButton];
    UILabel *videoDetail = [[UILabel alloc] init];
    videoDetail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    videoDetail.textColor = UIColor.secondaryLabelColor;
    videoDetail.numberOfLines = 0;
    videoDetail.text = @"Analyzes the video’s visuals, generates a matching soundtrack, then attaches it to the finished video. This is not a style or source-audio reference.";
    [stack addArrangedSubview:videoDetail];

    // ── Optional title ───────────────────────────────────────────────────────
    UILabel *titleHeader = [self sectionHeaderLabelWithText:EZMusicText(@"EZMusic.Title.Header", @"Title")];
    [stack addArrangedSubview:titleHeader];
    [stack setCustomSpacing:16 afterView:self.promptContainer];

    self.titleField = [[UITextField alloc] init];
    self.titleField.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.titleField.layer.cornerRadius = 10;
    self.titleField.font = [UIFont systemFontOfSize:16];
    self.titleField.placeholder = EZMusicText(@"EZMusic.Title.Placeholder", @"Optional - defaults to your description");
    self.titleField.returnKeyType = UIReturnKeyDone;
    self.titleField.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    self.titleField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.titleField.delegate = self;
    UIView *leftPadding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 10)];
    self.titleField.leftView = leftPadding;
    self.titleField.leftViewMode = UITextFieldViewModeAlways;
    [self.titleField.heightAnchor constraintEqualToConstant:44].active = YES;
    [stack addArrangedSubview:self.titleField];

    // ── Instrumental ─────────────────────────────────────────────────────────
    UILabel *instrumentalLabel = [[UILabel alloc] init];
    instrumentalLabel.font = [UIFont systemFontOfSize:16];
    instrumentalLabel.text = EZMusicText(@"EZMusic.Instrumental", @"Instrumental only (no vocals)");
    instrumentalLabel.numberOfLines = 0;
    self.instrumentalSwitch = [[UISwitch alloc] init];
    [self.instrumentalSwitch setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.instrumentalSwitch.accessibilityLabel = instrumentalLabel.text;
    UIStackView *instrumentalRow = [[UIStackView alloc] initWithArrangedSubviews:@[instrumentalLabel, self.instrumentalSwitch]];
    instrumentalRow.axis = UILayoutConstraintAxisHorizontal;
    instrumentalRow.alignment = UIStackViewAlignmentCenter;
    instrumentalRow.spacing = 12;
    [stack setCustomSpacing:16 afterView:self.titleField];
    [stack addArrangedSubview:instrumentalRow];

    // ── Length ───────────────────────────────────────────────────────────────
    UILabel *lengthHeader = [self sectionHeaderLabelWithText:EZMusicText(@"EZMusic.Length.Header", @"Length")];
    self.durationValueLabel = [[UILabel alloc] init];
    self.durationValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    self.durationValueLabel.textAlignment = NSTextAlignmentRight;
    UIStackView *lengthRow = [[UIStackView alloc] initWithArrangedSubviews:@[lengthHeader, self.durationValueLabel]];
    lengthRow.axis = UILayoutConstraintAxisHorizontal;
    [stack setCustomSpacing:16 afterView:instrumentalRow];
    [stack addArrangedSubview:lengthRow];

    self.durationSlider = [[UISlider alloc] init];
    self.durationSlider.minimumValue = 10;
    self.durationSlider.maximumValue = 300;
    self.durationSlider.value = kDefaultDurationSeconds;
    self.durationSlider.accessibilityLabel = EZMusicText(@"EZMusic.Length.Header", @"Length");
    [self.durationSlider addTarget:self action:@selector(durationChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.durationSlider];

    // ── Variants ─────────────────────────────────────────────────────────────
    UILabel *variantHeader = [self sectionHeaderLabelWithText:EZMusicText(@"EZMusic.Variants.Header", @"How many versions?")];
    [stack setCustomSpacing:16 afterView:self.durationSlider];
    [stack addArrangedSubview:variantHeader];

    self.variantControl = [[UISegmentedControl alloc] initWithItems:@[@"1", @"2", @"3"]];
    self.variantControl.selectedSegmentIndex = 0;
    [self.variantControl addTarget:self action:@selector(variantsChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.variantControl];

    // ── Quote and Generate ───────────────────────────────────────────────────
    self.quoteLabel = [[UILabel alloc] init];
    self.quoteLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.quoteLabel.numberOfLines = 0;
    self.quoteLabel.textAlignment = NSTextAlignmentCenter;
    [stack setCustomSpacing:20 afterView:self.variantControl];
    [stack addArrangedSubview:self.quoteLabel];

    self.generateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.generateButton.backgroundColor = [UIColor systemBlueColor];
    self.generateButton.layer.cornerRadius = 14;
    self.generateButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.generateButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.generateButton setTitleColor:[UIColor whiteColor] forState:UIControlStateDisabled];
    [self.generateButton addTarget:self action:@selector(generateTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.generateButton.heightAnchor constraintEqualToConstant:52].active = YES;
    self.surpriseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.surpriseButton.backgroundColor = [UIColor systemPurpleColor];
    self.surpriseButton.layer.cornerRadius = 14;
    [self.surpriseButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.surpriseButton setTitle:@"Surprise me" forState:UIControlStateNormal];
    [self.surpriseButton addTarget:self action:@selector(surpriseTapped) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[self.generateButton, self.surpriseButton]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.spacing = 10;
    actions.distribution = UIStackViewDistributionFillEqually;
    [actions.heightAnchor constraintEqualToConstant:52].active = YES;
    [stack addArrangedSubview:actions];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.hidden = YES;
    [stack addArrangedSubview:self.statusLabel];

    UILabel *footnote = [[UILabel alloc] init];
    footnote.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    footnote.textColor = [UIColor tertiaryLabelColor];
    footnote.numberOfLines = 0;
    footnote.textAlignment = NSTextAlignmentCenter;
    footnote.text = EZMusicText(@"EZMusic.Footnote",
        @"Songs are composed in the background, so you can close this screen and find them in your Library. If a song fails, your coins are refunded automatically.");
    [stack setCustomSpacing:16 afterView:self.generateButton];
    [stack addArrangedSubview:footnote];

    UILayoutGuide *contentGuide = self.createScrollView.contentLayoutGuide;
    UILayoutGuide *frameGuide = self.createScrollView.frameLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.createScrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.createScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.createScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.createScrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:contentGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:contentGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:contentGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:contentGuide.trailingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:frameGuide.widthAnchor],
    ]];

    [self updatePromptDecorations];
}

#pragma mark - Building the Library tab

- (void)buildLibraryView {
    self.libraryTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.libraryTable.translatesAutoresizingMaskIntoConstraints = NO;
    self.libraryTable.dataSource = self;
    self.libraryTable.delegate = self;
    self.libraryTable.rowHeight = UITableViewAutomaticDimension;
    self.libraryTable.estimatedRowHeight = 76;
    self.libraryTable.separatorInset = UIEdgeInsetsMake(0, 64, 0, 0);
    self.libraryTable.tableFooterView = [[UIView alloc] init];
    [self.libraryTable registerClass:[EZMusicTrackCell class] forCellReuseIdentifier:@"EZMusicTrackCell"];
    [self buildPlaylistHeader];

    self.libraryRefreshControl = [[UIRefreshControl alloc] init];
    [self.libraryRefreshControl addTarget:self action:@selector(libraryPulledToRefresh) forControlEvents:UIControlEventValueChanged];
    self.libraryTable.refreshControl = self.libraryRefreshControl;

    self.emptyStateLabel = [[UILabel alloc] init];
    self.emptyStateLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.emptyStateLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyStateLabel.numberOfLines = 0;
    self.libraryTable.backgroundView = self.emptyStateLabel;

    [self.view addSubview:self.libraryTable];
    [NSLayoutConstraint activateConstraints:@[
        [self.libraryTable.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.libraryTable.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.libraryTable.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.libraryTable.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self updateEmptyState];
}

- (void)buildPlaylistHeader {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 76)];
    header.backgroundColor = [UIColor secondarySystemBackgroundColor];
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.numberOfLines = 1;
    [header addSubview:title];
    self.playlistTitleLabel = title;

    UILabel *detail = [[UILabel alloc] init];
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    detail.textColor = UIColor.secondaryLabelColor;
    detail.numberOfLines = 1;
    [header addSubview:detail];
    self.playlistDetailLabel = detail;

    NSArray<NSString *> *symbols = @[ @"backward.end.fill", @"play.fill", @"forward.end.fill" ];
    SEL actions[] = { @selector(playlistPreviousTapped), @selector(playlistPlayTapped), @selector(playlistNextTapped) };
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (NSInteger index = 0; index < symbols.count; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [button setImage:[UIImage systemImageNamed:symbols[index]] forState:UIControlStateNormal];
        button.tintColor = UIColor.systemBlueColor;
        [button addTarget:self action:actions[index] forControlEvents:UIControlEventTouchUpInside];
        [header addSubview:button];
        [buttons addObject:button];
    }
    self.playlistPreviousButton = buttons[0];
    self.playlistPlayButton = buttons[1];
    self.playlistNextButton = buttons[2];
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:buttons[0].leadingAnchor constant:-8],
        [title.topAnchor constraintEqualToAnchor:header.topAnchor constant:13],
        [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [detail.trailingAnchor constraintLessThanOrEqualToAnchor:buttons[0].leadingAnchor constant:-8],
        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3],
        [buttons[2].trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-14],
        [buttons[2].centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [buttons[1].trailingAnchor constraintEqualToAnchor:buttons[2].leadingAnchor constant:-13],
        [buttons[1].centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [buttons[0].trailingAnchor constraintEqualToAnchor:buttons[1].leadingAnchor constant:-13],
        [buttons[0].centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];
    self.libraryTable.tableHeaderView = header;
    [self updatePlaylistHeader];
}

#pragma mark - Tabs

- (void)tabChanged:(UISegmentedControl *)sender {
    [self showTab:(EZMusicTab)sender.selectedSegmentIndex];
}

- (void)showTab:(EZMusicTab)tab {
    [self.view endEditing:YES];
    self.createScrollView.hidden = (tab != EZMusicTabCreate);
    self.libraryTable.hidden = (tab != EZMusicTabLibrary);
    if (self.tabControl.selectedSegmentIndex != tab) self.tabControl.selectedSegmentIndex = tab;
    if (tab == EZMusicTabLibrary && !self.libraryLoadedOnce && !self.isLoadingPage) {
        [self loadLibraryResetting:YES];
    }
}

#pragma mark - Config and pricing quote

- (void)loadConfig {
    if (self.isLoadingConfig) return;
    self.isLoadingConfig = YES;
    [self updateGenerateButtonState];

    __weak typeof(self) weakSelf = self;
    [[EZMusicService sharedService] fetchConfigWithCompletion:^(NSDictionary *config, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.isLoadingConfig = NO;
        if (config) {
            strongSelf.config = config;
            [strongSelf applyConfig];
            [strongSelf setStatusMessage:([config[@"enabled"] boolValue] ? nil
                : EZMusicText(@"EZMusic.Disabled", @"AI Music is temporarily unavailable. Please try again later."))];
        } else {
            [strongSelf setStatusMessage:EZMusicText(@"EZMusic.ConfigFailed",
                @"Couldn't load pricing. Check your connection, then tap Reload Pricing.")];
        }
        [strongSelf updateQuote];
    }];
}

// Pushes the server's limits into the slider and the variant picker.
- (void)applyConfig {
    NSInteger minSeconds = EZMusicInteger(self.config[@"minimum_song_duration_seconds"]);
    NSInteger maxSeconds = EZMusicInteger(self.config[@"max_song_duration_seconds"]);
    if (minSeconds <= 0) minSeconds = 10;
    if (maxSeconds < minSeconds) maxSeconds = MAX(minSeconds, 300);
    self.durationSlider.minimumValue = (float)minSeconds;
    self.durationSlider.maximumValue = (float)maxSeconds;
    if (!self.didApplyConfigOnce) {
        self.durationSlider.value = (float)MIN(MAX(kDefaultDurationSeconds, minSeconds), maxSeconds);
        self.didApplyConfigOnce = YES;
    } else {
        // Keep the current choice but pull it into the (possibly narrower) new range.
        self.durationSlider.value = MIN(MAX(self.durationSlider.value, (float)minSeconds), (float)maxSeconds);
    }

    NSInteger variantLimit = MIN(MAX(EZMusicInteger(self.config[@"variant_count_limit"]), 1), kMaxVariantChoices);
    NSInteger previousSelection = MAX(self.variantControl.selectedSegmentIndex, 0);
    [self.variantControl removeAllSegments];
    for (NSInteger count = 1; count <= variantLimit; count++) {
        [self.variantControl insertSegmentWithTitle:[NSString stringWithFormat:@"%ld", (long)count]
                                            atIndex:(NSUInteger)(count - 1)
                                           animated:NO];
    }
    self.variantControl.selectedSegmentIndex = MIN(previousSelection, variantLimit - 1);
}

- (NSInteger)selectedDurationSeconds {
    return (NSInteger)lroundf(self.durationSlider.value);
}

- (NSInteger)selectedVariantCount {
    return MAX(self.variantControl.selectedSegmentIndex, 0) + 1;
}

// Same rule the server applies (per-minute rate rounded up, with a minimum).
// This is only a quote for the label; the server recomputes the real charge.
- (NSInteger)quotedCoinsPerVariantForSeconds:(NSInteger)seconds {
    double coinsPerMinute = [self.config[@"coins_per_minute"] doubleValue];
    NSInteger minimumCharge = EZMusicInteger(self.config[@"minimum_generation_charge"]);
    NSInteger rawCoins = (NSInteger)ceil(((double)seconds / 60.0) * coinsPerMinute);
    return MAX(minimumCharge, rawCoins);
}

- (NSInteger)quotedTotalCoins {
    return [self quotedCoinsPerVariantForSeconds:[self selectedDurationSeconds]] * [self selectedVariantCount];
}

- (void)updateQuote {
    self.durationValueLabel.text = EZMusicFormattedDuration([self selectedDurationSeconds]);
    self.durationSlider.accessibilityValue = self.durationValueLabel.text;

    if (!self.config) {
        self.quoteLabel.text = EZMusicText(@"EZMusic.Quote.Loading", @"Loading prices...");
        self.quoteLabel.textColor = [UIColor secondaryLabelColor];
        [self updateGenerateButtonState];
        return;
    }

    NSInteger variants = [self selectedVariantCount];
    NSInteger perVariant = [self quotedCoinsPerVariantForSeconds:[self selectedDurationSeconds]];
    NSInteger total = perVariant * variants;
    NSNumber *balance = [EZEntitlementManager shared].coinBalance;

    NSMutableString *text = [NSMutableString string];
    if (variants > 1) {
        [text appendFormat:EZMusicText(@"EZMusic.Quote.Multi", @"%ld versions x %ld = %ld coins"),
            (long)variants, (long)perVariant, (long)total];
    } else {
        [text appendFormat:EZMusicText(@"EZMusic.Quote.Single", @"%ld coins"), (long)total];
    }
    BOOL insufficient = (balance != nil && balance.integerValue < total);
    if (balance) {
        [text appendFormat:EZMusicText(@"EZMusic.Quote.Balance", @"   |   Balance: %ld"), (long)balance.integerValue];
    }
    if (insufficient) {
        [text appendString:@"\n"];
        [text appendString:EZMusicText(@"EZMusic.Quote.Insufficient", @"Not enough coins - tap Generate to get more.")];
    }
    self.quoteLabel.text = text;
    self.quoteLabel.textColor = insufficient ? [UIColor systemRedColor] : [UIColor labelColor];
    [self updateGenerateButtonState];
}

- (void)coinBalanceMayHaveChanged {
    __weak typeof(self) weakSelf = self;
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        [weakSelf updateQuote];
    }];
    [self updateQuote];
}

- (void)updateGenerateButtonState {
    BOOL hasPrompt = [self trimmedPrompt].length > 0;
    BOOL enabled;
    NSString *title;
    if (self.isStartingGeneration) {
        title = EZMusicText(@"EZMusic.Button.Starting", @"Starting...");
        enabled = NO;
    } else if (!self.config) {
        title = self.isLoadingConfig ? EZMusicText(@"EZMusic.Button.Loading", @"Loading...")
                                     : EZMusicText(@"EZMusic.Button.ReloadPricing", @"Reload Pricing");
        enabled = !self.isLoadingConfig;
    } else {
        title = EZMusicText(@"EZMusic.Button.Generate", @"Generate");
        enabled = hasPrompt && [self.config[@"enabled"] boolValue];
    }
    [self.generateButton setTitle:title forState:UIControlStateNormal];
    [self.generateButton setTitle:title forState:UIControlStateDisabled];
    self.generateButton.enabled = enabled;
    self.generateButton.alpha = enabled ? 1.0 : 0.5;
}

- (void)setStatusMessage:(nullable NSString *)message {
    self.statusLabel.text = message;
    self.statusLabel.hidden = (message.length == 0);
}

#pragma mark - Create-tab actions

- (NSString *)trimmedPrompt {
    return [self.promptTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

- (void)durationChanged:(UISlider *)slider {
    float step = (float)kDurationStepSeconds;
    slider.value = roundf(slider.value / step) * step;   // the setter clamps to min/max
    [self updateQuote];
}

- (void)variantsChanged:(UISegmentedControl *)sender {
    [self updateQuote];
}

- (void)updateReferencePresentation {
    if (self.referenceURL.isFileURL) {
        NSString *name = self.referenceSourceName.length ? self.referenceSourceName : self.referenceURL.lastPathComponent;
        [self.referenceButton setTitle:[NSString stringWithFormat:@"  %@", name] forState:UIControlStateNormal];
        if (self.referenceMode == EZMusicReferenceModeSource) {
            self.referenceDetailLabel.text = self.referenceModeLocked
                ? @"This TTS clip will be kept in the song; music is composed after it."
                : @"The clip itself is kept in the finished song; new music is composed around it.";
        } else {
            self.referenceDetailLabel.text = @"New music is generated, guided by this clip’s sound. The source audio is not inserted into the song.";
        }
    } else {
        [self.referenceButton setTitle:@"  Add audio reference" forState:UIControlStateNormal];
        self.referenceDetailLabel.text = @"Compressed and lossless audio are accepted. Video soundtrack generation is separate below.";
        self.referenceModeControl.enabled = NO;
    }
}

- (void)referenceModeChanged:(UISegmentedControl *)sender {
    self.referenceMode = (EZMusicReferenceMode)sender.selectedSegmentIndex;
    [self updateReferencePresentation];
}

- (void)referenceTapped {
    self.pickingVideoSoundtrack = NO;
    [self presentReferenceSourceMenu];
}

- (void)videoSoundtrackTapped {
    self.pickingVideoSoundtrack = YES;
    [self presentReferenceSourceMenu];
}

- (void)presentReferenceSourceMenu {
    if (self.referenceSourceOverlay) return;
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.38];
    self.referenceSourceOverlay = overlay;
    [self.view addSubview:overlay];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor systemBackgroundColor];
    card.layer.cornerRadius = 22;
    [overlay addSubview:card];
    BOOL videoMode = self.pickingVideoSoundtrack;
    UILabel *title = [[UILabel alloc] init]; title.text = videoMode ? @"Compose music for video" : @"Add an audio reference"; title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold]; title.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *detail = [[UILabel alloc] init]; detail.text = videoMode ? @"The video’s visuals guide a new soundtrack." : @"Choose an audio clip to guide or include in a song."; detail.textColor = UIColor.secondaryLabelColor; detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; detail.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:title]; [card addSubview:detail];
    UIStackView *choices = [[UIStackView alloc] init]; choices.translatesAutoresizingMaskIntoConstraints = NO; choices.axis = UILayoutConstraintAxisVertical; choices.spacing = 10; [card addSubview:choices];
    NSArray *rows = videoMode
        ? @[@[@"Photo Library", @"Choose a video from Photos", @"photo.on.rectangle", @"photo"], @[@"EZ Photo Gallery", @"Use a video already in the app", @"square.grid.2x2", @"gallery"], @[@"Files", @"Choose a video file", @"folder", @"files"]]
        : @[@[@"Files", @"Compressed or lossless audio", @"folder", @"files"]];
    for (NSArray *row in rows) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; button.tag = [rows indexOfObject:row]; button.backgroundColor = UIColor.secondarySystemBackgroundColor; button.layer.cornerRadius = 14; button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft; button.contentEdgeInsets = UIEdgeInsetsMake(10, 14, 10, 14); [button addTarget:self action:@selector(referenceSourceChosen:) forControlEvents:UIControlEventTouchUpInside];
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:row[2]]]; icon.tintColor = UIColor.systemPurpleColor; icon.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *name = [[UILabel alloc] init]; name.text = row[0]; name.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        UILabel *sub = [[UILabel alloc] init]; sub.text = row[1]; sub.textColor = UIColor.secondaryLabelColor; sub.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[name, sub]]; labels.axis = UILayoutConstraintAxisVertical; labels.spacing = 2;
        UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:@[icon, labels]]; line.userInteractionEnabled = NO; line.axis = UILayoutConstraintAxisHorizontal; line.alignment = UIStackViewAlignmentCenter; line.spacing = 12; [button addSubview:line]; line.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[[line.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:14], [line.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-14], [line.topAnchor constraintEqualToAnchor:button.topAnchor constant:10], [line.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-10], [icon.widthAnchor constraintEqualToConstant:28]]];
        [choices addArrangedSubview:button];
    }
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem]; cancel.translatesAutoresizingMaskIntoConstraints = NO; [cancel setTitle:@"Cancel" forState:UIControlStateNormal]; cancel.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; [cancel addTarget:self action:@selector(dismissReferenceSourceMenu) forControlEvents:UIControlEventTouchUpInside]; [card addSubview:cancel];
    [NSLayoutConstraint activateConstraints:@[[card.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:18], [card.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-18], [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor], [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:22], [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20], [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3], [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [choices.topAnchor constraintEqualToAnchor:detail.bottomAnchor constant:20], [choices.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14], [choices.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14], [cancel.topAnchor constraintEqualToAnchor:choices.bottomAnchor constant:8], [cancel.centerXAnchor constraintEqualToAnchor:card.centerXAnchor], [cancel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12]]];
    overlay.alpha = 0; [UIView animateWithDuration:.2 animations:^{ overlay.alpha = 1; }];
}

- (void)dismissReferenceSourceMenu { UIView *overlay = self.referenceSourceOverlay; self.referenceSourceOverlay = nil; [UIView animateWithDuration:.18 animations:^{ overlay.alpha = 0; } completion:^(__unused BOOL done) { [overlay removeFromSuperview]; }]; }

- (void)referenceSourceChosen:(UIButton *)button {
    NSInteger source = button.tag; [self dismissReferenceSourceMenu];
    if (!self.pickingVideoSoundtrack) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initWithDocumentTypes:@[@"public.audio"] inMode:UIDocumentPickerModeImport];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
        return;
    }
    if (source == 0) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]];
        config.filter = [PHPickerFilter videosFilter]; config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config]; picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
    } else if (source == 1) {
        EZPhotoGalleryViewController *gallery = [EZPhotoGalleryViewController new]; __weak typeof(self) weakSelf = self;
        gallery.onSelectMediaURL = ^(NSURL *url) { [weakSelf importVideoForSoundtrackFromURL:url]; };
        [self presentViewController:[[UINavigationController alloc] initWithRootViewController:gallery] animated:YES completion:nil];
    } else {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.movie"]
                         inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *sourceURL = urls.firstObject;
    if (!sourceURL) return;
    if (self.pickingVideoSoundtrack) [self importVideoForSoundtrackFromURL:sourceURL];
    else [self importReferenceFromURL:sourceURL];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (!provider || ![provider hasItemConformingToTypeIdentifier:@"public.movie"]) return;
    __weak typeof(self) weakSelf = self;
    [provider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *error) {
        if (!url) { dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf setStatusMessage:@"Couldn’t load that video from Photos."]; }); return; }
        NSString *name = [NSString stringWithFormat:@"music_photo_%@.%@", NSUUID.UUID.UUIDString, url.pathExtension.length ? url.pathExtension : @"mov"];
        NSURL *copy = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        [[NSFileManager defaultManager] removeItemAtURL:copy error:nil];
        NSError *copyError = nil; [[NSFileManager defaultManager] copyItemAtURL:url toURL:copy error:&copyError];
        dispatch_async(dispatch_get_main_queue(), ^{ if (copyError) [weakSelf setStatusMessage:@"Couldn’t import that video from Photos."]; else [weakSelf importVideoForSoundtrackFromURL:copy]; });
    }];
}

- (void)usePreparedReferenceURL:(NSURL *)url sourceName:(NSString *)sourceName {
    self.referenceURL = url;
    self.referenceSourceName = sourceName;
    self.referenceModeLocked = NO;
    self.referenceModeControl.enabled = YES;
    [self updateReferencePresentation];
}

- (void)exportReferenceURL:(NSURL *)source timeRange:(CMTimeRange)timeRange completion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
    AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    NSURL *output = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"music_reference_%@.m4a", NSUUID.UUID.UUIDString]]];
    [[NSFileManager defaultManager] removeItemAtURL:output error:nil];
    if (!exporter || ![exporter.supportedFileTypes containsObject:AVFileTypeAppleM4A]) {
        completion(nil, [NSError errorWithDomain:@"EZMusic" code:20 userInfo:@{NSLocalizedDescriptionKey: @"This audio file can’t be prepared as a reference."}]);
        return;
    }
    exporter.outputURL = output;
    exporter.outputFileType = AVFileTypeAppleM4A;
    exporter.timeRange = timeRange;
    exporter.shouldOptimizeForNetworkUse = YES;
    [exporter exportAsynchronouslyWithCompletionHandler:^{
        NSError *error = exporter.status == AVAssetExportSessionStatusCompleted ? nil : exporter.error;
        NSDictionary *attributes = error ? nil : [[NSFileManager defaultManager] attributesOfItemAtPath:output.path error:nil];
        if (!error && [attributes fileSize] > kEZMusicMaximumReferenceBytes) {
            error = [NSError errorWithDomain:@"EZMusic" code:21 userInfo:@{NSLocalizedDescriptionKey: @"That reference could not be compressed below 12 MB."}];
            [[NSFileManager defaultManager] removeItemAtURL:output error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error ? nil : output, error); });
    }];
}

- (void)presentReferenceTrimPickerForURL:(NSURL *)url sourceName:(NSString *)sourceName duration:(NSTimeInterval)duration {
    if (self.musicDialogOverlay) return;
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.48];
    self.musicDialogOverlay = overlay;
    [self.view addSubview:overlay];
    UIView *card = [UIView new]; card.translatesAutoresizingMaskIntoConstraints = NO; card.backgroundColor = UIColor.systemBackgroundColor; card.layer.cornerRadius = 22; [overlay addSubview:card];
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem]; closeButton.translatesAutoresizingMaskIntoConstraints = NO; [closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal]; closeButton.tintColor = UIColor.secondaryLabelColor; [card addSubview:closeButton];
    [closeButton addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) { [overlay removeFromSuperview]; self.musicDialogOverlay = nil; }] forControlEvents:UIControlEventTouchUpInside];
    UILabel *title = [UILabel new]; title.translatesAutoresizingMaskIntoConstraints = NO; title.text = @"Choose a 2-minute reference"; title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold]; [card addSubview:title];
    UILabel *detail = [UILabel new]; detail.translatesAutoresizingMaskIntoConstraints = NO; detail.numberOfLines = 0; detail.textColor = UIColor.secondaryLabelColor; detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; detail.text = @"References longer than two minutes are rejected before generation. Pick the part of this song you want to use."; [card addSubview:detail];
    UILabel *range = [UILabel new]; range.translatesAutoresizingMaskIntoConstraints = NO; range.textAlignment = NSTextAlignmentCenter; range.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold]; [card addSubview:range];
    UISlider *slider = [UISlider new]; slider.translatesAutoresizingMaskIntoConstraints = NO; slider.minimumValue = 0; slider.maximumValue = MAX(0, duration - kEZMusicMaximumReferenceSeconds); [card addSubview:slider];
    void (^refresh)(void) = ^{ range.text = [NSString stringWithFormat:@"%.0f:%02.0f – %.0f:%02.0f", floor(slider.value / 60), fmod(slider.value, 60), floor((slider.value + 120) / 60), fmod(slider.value + 120, 60)]; };
    [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) { refresh(); }] forControlEvents:UIControlEventValueChanged]; refresh();
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem]; cancel.translatesAutoresizingMaskIntoConstraints = NO; [cancel setTitle:@"Cancel" forState:UIControlStateNormal]; [card addSubview:cancel];
    UIButton *use = [UIButton buttonWithType:UIButtonTypeSystem]; use.translatesAutoresizingMaskIntoConstraints = NO; use.backgroundColor = UIColor.systemPurpleColor; use.tintColor = UIColor.whiteColor; use.layer.cornerRadius = 12; [use setTitle:@"Use selected clip" forState:UIControlStateNormal]; [card addSubview:use];
    [cancel addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) { [overlay removeFromSuperview]; self.musicDialogOverlay = nil; }] forControlEvents:UIControlEventTouchUpInside];
    [use addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        [overlay removeFromSuperview]; self.musicDialogOverlay = nil;
        [self showBusyOverlayWithText:@"Preparing your selected reference…"];
        CMTime start = CMTimeMakeWithSeconds(slider.value, 600); CMTime length = CMTimeMakeWithSeconds(kEZMusicMaximumReferenceSeconds, 600);
        [self exportReferenceURL:url timeRange:CMTimeRangeMake(start, length) completion:^(NSURL *clip, NSError *error) {
            [self hideBusyOverlay];
            if (clip) [self usePreparedReferenceURL:clip sourceName:sourceName];
            else [self presentAlertWithTitle:@"Couldn’t prepare reference" message:error.localizedDescription];
        }];
    }] forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[[card.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:20], [card.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-20], [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor], [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:22], [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20], [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20], [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8], [detail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [detail.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [range.topAnchor constraintEqualToAnchor:detail.bottomAnchor constant:20], [range.centerXAnchor constraintEqualToAnchor:card.centerXAnchor], [slider.topAnchor constraintEqualToAnchor:range.bottomAnchor constant:8], [slider.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [slider.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [cancel.topAnchor constraintEqualToAnchor:slider.bottomAnchor constant:18], [cancel.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [cancel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16], [use.topAnchor constraintEqualToAnchor:cancel.topAnchor], [use.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [use.widthAnchor constraintEqualToConstant:150], [use.heightAnchor constraintEqualToConstant:44]]];
}

- (void)prepareReferenceURL:(NSURL *)url sourceName:(NSString *)sourceName {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSTimeInterval duration = CMTimeGetSeconds(asset.duration);
    if (!isfinite(duration) || duration <= 0) { [self setStatusMessage:@"Couldn’t read that audio reference."]; return; }
    if (duration > kEZMusicMaximumReferenceSeconds) { [self presentReferenceTrimPickerForURL:url sourceName:sourceName duration:duration]; return; }
    unsigned long long bytes = [[[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil] fileSize];
    if (bytes <= kEZMusicMaximumReferenceBytes) { [self usePreparedReferenceURL:url sourceName:sourceName]; return; }
    [self showBusyOverlayWithText:@"Compressing reference for upload…"];
    [self exportReferenceURL:url timeRange:CMTimeRangeMake(kCMTimeZero, asset.duration) completion:^(NSURL *clip, NSError *error) {
        [self hideBusyOverlay];
        if (clip) [self usePreparedReferenceURL:clip sourceName:sourceName];
        else [self presentAlertWithTitle:@"Couldn’t prepare reference" message:error.localizedDescription];
    }];
}

- (void)importReferenceFromURL:(NSURL *)sourceURL {
    if (!sourceURL) return;
    [sourceURL startAccessingSecurityScopedResource];
    NSString *suffix = sourceURL.pathExtension.length ? sourceURL.pathExtension : @"m4a";
    NSString *name = [NSString stringWithFormat:@"music_reference_%@.%@", NSUUID.UUID.UUIDString, suffix];
    NSURL *destination = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
    NSError *copyError = nil;
    [[NSFileManager defaultManager] copyItemAtURL:sourceURL toURL:destination error:&copyError];
    [sourceURL stopAccessingSecurityScopedResource];
    if (copyError) {
        [self setStatusMessage:@"Couldn’t import that reference file."];
        return;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:destination options:nil];
    if ([[asset tracksWithMediaType:AVMediaTypeVideo] count] > 0) {
        [self setStatusMessage:@"Videos are for Video Soundtrack, not audio reference. Choose Compose music for a video below."];
        return;
    }
    [self prepareReferenceURL:destination sourceName:sourceURL.lastPathComponent];
}

// This intentionally does not extract the video's audio. Video-to-music uses
// the picture/motion as the provider input and produces a new soundtrack.
- (void)importVideoForSoundtrackFromURL:(NSURL *)sourceURL {
    if (!sourceURL) return;
    self.pickingVideoSoundtrack = NO;
    [sourceURL startAccessingSecurityScopedResource];
    NSString *suffix = sourceURL.pathExtension.length ? sourceURL.pathExtension : @"mov";
    NSURL *videoURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"music_video_%@.%@", NSUUID.UUID.UUIDString, suffix]]];
    [[NSFileManager defaultManager] removeItemAtURL:videoURL error:nil];
    NSError *copyError = nil;
    [[NSFileManager defaultManager] copyItemAtURL:sourceURL toURL:videoURL error:&copyError];
    [sourceURL stopAccessingSecurityScopedResource];
    if (copyError) {
        [self setStatusMessage:@"Couldn’t import that video."];
        return;
    }
    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    if ([[videoAsset tracksWithMediaType:AVMediaTypeVideo] count] == 0) {
        [[NSFileManager defaultManager] removeItemAtURL:videoURL error:nil];
        [self setStatusMessage:@"Choose a video for Video Soundtrack. Audio files belong in Audio Reference."];
        return;
    }

    NSString *notes = [self trimmedPrompt];
    [self showBusyOverlayWithText:@"Analyzing video and composing its soundtrack…"];
    __weak typeof(self) weakSelf = self;
    [[EZMusicService sharedService] generateMusicForVideoURLs:@[videoURL]
                                                   description:notes.length ? notes : nil
                                                    completion:^(NSData *audioData, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!audioData.length) {
            [[NSFileManager defaultManager] removeItemAtURL:videoURL error:nil];
            [self hideBusyOverlay];
            [self presentAlertWithTitle:@"Couldn’t create soundtrack"
                                message:error.localizedDescription ?: @"The video-to-music service did not return audio."];
            return;
        }
        NSURL *audioURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"video_soundtrack_%@.mp3", NSUUID.UUID.UUIDString]]];
        if (![audioData writeToURL:audioURL atomically:YES]) {
            [[NSFileManager defaultManager] removeItemAtURL:videoURL error:nil];
            [self hideBusyOverlay];
            [self presentAlertWithTitle:@"Couldn’t save soundtrack" message:@"Please try the video again."];
            return;
        }
        [self muxVideoURL:videoURL audioURL:audioURL completion:^(NSURL *finishedVideoURL, NSError *muxError) {
            [[NSFileManager defaultManager] removeItemAtURL:videoURL error:nil];
            [[NSFileManager defaultManager] removeItemAtURL:audioURL error:nil];
            [self hideBusyOverlay];
            if (!finishedVideoURL) {
                [self presentAlertWithTitle:@"Couldn’t attach soundtrack"
                                    message:muxError.localizedDescription ?: @"The music was created but could not be attached to the video."];
                return;
            }
            UIActivityViewController *share = [[UIActivityViewController alloc]
                initWithActivityItems:@[finishedVideoURL] applicationActivities:nil];
            [self presentViewController:share animated:YES completion:nil];
        }];
    }];
}

- (void)muxVideoURL:(NSURL *)videoURL audioURL:(NSURL *)audioURL
          completion:(void (^)(NSURL * _Nullable finishedVideoURL, NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
        AVURLAsset *audioAsset = [AVURLAsset URLAssetWithURL:audioURL options:nil];
        AVAssetTrack *videoTrack = [videoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        AVAssetTrack *audioTrack = [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        if (!videoTrack || !audioTrack) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, [NSError errorWithDomain:@"EZMusic" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The video or generated soundtrack could not be read."}]); });
            return;
        }
        AVMutableComposition *composition = [AVMutableComposition composition];
        AVMutableCompositionTrack *outputVideo = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
        AVMutableCompositionTrack *outputAudio = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        NSError *insertError = nil;
        CMTimeRange videoRange = CMTimeRangeMake(kCMTimeZero, videoAsset.duration);
        if (![outputVideo insertTimeRange:videoRange ofTrack:videoTrack atTime:kCMTimeZero error:&insertError]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, insertError); });
            return;
        }
        CMTime audioDuration = CMTimeMinimum(audioAsset.duration, videoAsset.duration);
        if (![outputAudio insertTimeRange:CMTimeRangeMake(kCMTimeZero, audioDuration) ofTrack:audioTrack atTime:kCMTimeZero error:&insertError]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, insertError); });
            return;
        }
        outputVideo.preferredTransform = videoTrack.preferredTransform;
        NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"video_with_music_%@.mp4", NSUUID.UUID.UUIDString]]];
        AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetHighestQuality];
        exporter.outputURL = outputURL;
        exporter.outputFileType = AVFileTypeMPEG4;
        [exporter exportAsynchronouslyWithCompletionHandler:^{
            NSError *resultError = exporter.status == AVAssetExportSessionStatusCompleted ? nil : exporter.error;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(resultError ? nil : outputURL, resultError); });
        }];
    });
}

- (void)surpriseTapped {
    // One intentional take: duration is the only user-controlled cost factor.
    NSArray<NSString *> *ideas = @[
        @"Warm cinematic electronic track with a slow sunrise build, soft percussion, and an uplifting final chorus",
        @"Playful future-funk groove with crisp drums, elastic bass, and bright chopped vocal textures",
        @"Dreamy late-night R&B instrumental with intimate keys, vinyl warmth, and a restrained beat",
        @"Inventive indie-pop song with handclaps, shimmering guitars, and a memorable hopeful hook"
    ];
    self.promptTextView.text = ideas[arc4random_uniform((u_int32_t)ideas.count)];
    self.titleField.text = @"";
    self.lyricsTextView.text = @"";
    self.referenceURL = nil;
    self.referenceSourceName = nil;
    self.referenceModeLocked = NO;
    self.referenceMode = EZMusicReferenceModeStyle;
    self.referenceModeControl.selectedSegmentIndex = self.referenceMode;
    self.referenceModeControl.enabled = NO;
    [self updateReferencePresentation];
    self.instrumentalSwitch.on = NO;
    self.variantControl.selectedSegmentIndex = 0;
    [self updatePromptDecorations];
    [self updateQuote];
    [self generateTapped];
}

- (void)generateTapped {
    [self.view endEditing:YES];

    if (!self.config) {
        [self loadConfig];
        return;
    }
    if (self.isStartingGeneration) return;
    if (![self.config[@"enabled"] boolValue]) {
        [self presentAlertWithTitle:EZMusicText(@"EZMusic.Alert.UnavailableTitle", @"AI Music Unavailable")
                            message:EZMusicText(@"EZMusic.Disabled", @"AI Music is temporarily unavailable. Please try again later.")];
        return;
    }
    NSString *prompt = [self trimmedPrompt];
    NSString *lyrics = [self.lyricsTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (prompt.length > 4100 || lyrics.length > 6100) {
        [self setStatusMessage:@"The description may be up to 4,100 characters and lyrics up to 6,100."];
        return;
    }
    if (prompt.length == 0) {
        [self presentAlertWithTitle:EZMusicText(@"EZMusic.Alert.NeedPromptTitle", @"Describe Your Song")
                            message:EZMusicText(@"EZMusic.Alert.NeedPromptMessage", @"Tell me what kind of music you want, then tap Generate.")];
        return;
    }

    NSInteger totalCoins = [self quotedTotalCoins];
    NSNumber *balance = [EZEntitlementManager shared].coinBalance;
    if (balance && balance.integerValue < totalCoins) {
        [self presentInsufficientCoinsAlertRequiring:totalCoins];
        return;
    }

    self.isStartingGeneration = YES;
    [self setStatusMessage:nil];
    [self updateGenerateButtonState];

    NSString *title = [self.titleField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (self.referenceURL.isFileURL && !self.referenceModeLocked) {
        [[EZMusicLibraryManager sharedManager] archiveReferenceAtURL:self.referenceURL
                                                           sourceName:self.referenceSourceName
                                                                mode:(self.referenceMode == EZMusicReferenceModeSource ? @"source" : @"style")];
    }
    __weak typeof(self) weakSelf = self;
    [[EZMusicService sharedService]
        startGenerationWithPrompt:prompt
                            lyrics:lyrics
                      referenceURL:self.referenceURL
                     referenceMode:(self.referenceMode == EZMusicReferenceModeSource ? @"source" : @"style")
                            title:title
                  durationSeconds:[self selectedDurationSeconds]
                     variantCount:[self selectedVariantCount]
                forceInstrumental:self.instrumentalSwitch.isOn
                       completion:^(NSString *generationID, NSArray<NSDictionary *> *startedEntries, NSInteger balanceAfter, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.isStartingGeneration = NO;
        [strongSelf updateQuote];

        if (error) {
            [strongSelf handleGenerationStartError:error];
            return;
        }
        // The song is queued and paid for. Jump to the Library, where the new
        // rows show a spinner, and start watching this generation.
        [strongSelf ensurePollingForGenerationID:generationID];
        [strongSelf showTab:EZMusicTabLibrary];
        [strongSelf loadLibraryResetting:YES];
        [strongSelf showToast:EZMusicText(@"EZMusic.Toast.Started", @"Composing your song...")];
    }];
}

- (void)handleGenerationStartError:(NSError *)error {
    NSString *serverCode = EZMusicString(error.userInfo[EZMusicServiceServerCodeKey]);

    if ([serverCode isEqualToString:@"insufficient_coins"]) {
        [self coinBalanceMayHaveChanged];
        [self presentInsufficientCoinsAlertRequiring:EZMusicInteger(error.userInfo[@"coins_required"])];
        return;
    }
    if ([serverCode isEqualToString:@"too_many_active"]) {
        [self presentAlertWithTitle:EZMusicText(@"EZMusic.Alert.BusyTitle", @"Songs Still Composing")
                            message:EZMusicText(@"EZMusic.Alert.BusyMessage", @"You already have songs being created. Wait for them to finish, then try again.")];
        [self showTab:EZMusicTabLibrary];
        [self loadLibraryResetting:YES];
        return;
    }
    // The connection broke or the reply was unreadable. The server may have
    // accepted the request anyway, so check the Library before anyone retries.
    if (error.code == EZMusicServiceErrorNetwork || error.code == EZMusicServiceErrorBadResponse) {
        [self presentAlertWithTitle:EZMusicText(@"EZMusic.Alert.UnsureTitle", @"Couldn't Confirm Your Song")
                            message:EZMusicText(@"EZMusic.Alert.UnsureMessage",
                                @"The connection dropped before we heard back. Check your Library: if the song isn't there, you weren't charged and you can try again.")];
        [self loadLibraryResetting:YES];
        [self coinBalanceMayHaveChanged];
        return;
    }
    [self presentAlertWithTitle:EZMusicText(@"EZMusic.Alert.StartFailedTitle", @"Couldn't Start Song")
                        message:error.localizedDescription];
}

- (void)presentInsufficientCoinsAlertRequiring:(NSInteger)requiredCoins {
    NSNumber *balance = [EZEntitlementManager shared].coinBalance;
    NSString *message;
    if (requiredCoins > 0 && balance) {
        message = [NSString stringWithFormat:EZMusicText(@"EZMusic.Alert.CoinsMessageDetailed",
            @"This needs %ld coins and you have %ld."), (long)requiredCoins, (long)balance.integerValue];
    } else {
        message = EZMusicText(@"EZMusic.Alert.CoinsMessage", @"You don't have enough coins for this song.");
    }
    __weak typeof(self) weakSelf = self;
    [self presentMusicDialogWithTitle:EZMusicText(@"EZMusic.Alert.CoinsTitle", @"Not Enough Coins")
                              message:message primaryTitle:EZMusicText(@"EZMusic.Alert.GetCoins", @"Get Coins")
                       primaryHandler:^{ [weakSelf presentCoinStore]; }];
}

- (void)presentCoinStore {
    EZCoinStoreViewController *store = [[EZCoinStoreViewController alloc] init];
    store.showLowCoinsWarning = YES;
    store.triggeringFeatureName = @"AI music";
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:store];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}

#pragma mark - Prompt and text field delegates

- (void)updatePromptDecorations {
    self.promptPlaceholderLabel.hidden = (self.promptTextView.text.length > 0);
    self.characterCountLabel.text = [NSString stringWithFormat:@"%lu / %lu",
        (unsigned long)self.promptTextView.text.length, (unsigned long)kPromptCharacterLimit];
}

- (void)textViewDidChange:(UITextView *)textView {
    if (textView.text.length > kPromptCharacterLimit) {
        // A paste can overshoot; trim on a character boundary so emoji aren't split.
        NSRange safeRange = [textView.text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, kPromptCharacterLimit)];
        textView.text = [textView.text substringWithRange:safeRange];
    }
    [self updatePromptDecorations];
    [self updateGenerateButtonState];
}

- (void)textViewDidBeginEditing:(UITextView *)textView {
    [self scrollCreateTabToShowView:self.promptContainer];
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    [self scrollCreateTabToShowView:textField];
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    NSString *proposed = [textField.text stringByReplacingCharactersInRange:range withString:string];
    return proposed.length <= kTitleCharacterLimit;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)scrollCreateTabToShowView:(UIView *)view {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGRect rect = [self.createScrollView convertRect:view.bounds fromView:view];
        [self.createScrollView scrollRectToVisible:CGRectInset(rect, 0, -16) animated:YES];
    });
}

- (void)keyboardWillChangeFrame:(NSNotification *)note {
    CGRect endFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect localFrame = [self.view convertRect:endFrame fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(localFrame));
    // The scroll view already insets for the home indicator, so don't count it twice.
    CGFloat extra = MAX(0, overlap - self.view.safeAreaInsets.bottom);
    UIEdgeInsets insets = self.createScrollView.contentInset;
    insets.bottom = extra;
    self.createScrollView.contentInset = insets;
    self.createScrollView.scrollIndicatorInsets = insets;
}

#pragma mark - Library loading

- (void)libraryPulledToRefresh {
    [self loadLibraryResetting:YES];
}

- (void)loadLibraryResetting:(BOOL)reset {
    if (self.isLoadingPage && !reset) return;

    NSString *beforeTimestamp = nil;
    if (!reset) {
        beforeTimestamp = EZMusicString(self.entries.lastObject[@"created_at"]);
        if (beforeTimestamp.length == 0) return;
    }

    self.isLoadingPage = YES;
    NSUInteger requestNumber = ++self.libraryRequestCounter;
    __weak typeof(self) weakSelf = self;
    [[EZMusicService sharedService] fetchLibraryBefore:beforeTimestamp
                                                 limit:kLibraryPageSize
                                            completion:^(NSArray<NSDictionary *> *fetched, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (requestNumber != strongSelf.libraryRequestCounter) return;   // a newer request replaced this one

        strongSelf.isLoadingPage = NO;
        strongSelf.libraryLoadedOnce = YES;
        [strongSelf.libraryRefreshControl endRefreshing];

        if (error) {
            strongSelf.libraryErrorMessage = error.localizedDescription;
            EZLogf(EZLogLevelWarning, @"Music", @"Library load failed: %@", error.localizedDescription);
            [strongSelf updateEmptyState];
            return;
        }
        strongSelf.libraryErrorMessage = nil;

        if (reset) {
            strongSelf.entries = [fetched mutableCopy];
            strongSelf.hasMoreEntries = (fetched.count >= (NSUInteger)kLibraryPageSize);
        } else {
            // The cursor is inclusive so same-instant variants aren't skipped;
            // that means the first rows can repeat, so de-duplicate by id.
            NSInteger appended = 0;
            for (NSDictionary *entry in fetched) {
                if ([strongSelf rowForEntryID:EZMusicString(entry[@"id"])] == NSNotFound) {
                    [strongSelf.entries addObject:entry];
                    appended++;
                }
            }
            strongSelf.hasMoreEntries = (appended > 0 && fetched.count >= (NSUInteger)kLibraryPageSize);
        }
        [strongSelf.libraryTable reloadData];
        [strongSelf updateEmptyState];
        [strongSelf resumePollingForPendingEntries];
        // Backfill songs made before a prior archive attempt failed, and keep
        // every completed song available offline rather than only ones played.
        for (NSDictionary *entry in strongSelf.entries) {
            if ([EZMusicString(entry[@"status"]) isEqualToString:@"complete"]) {
                [strongSelf retainCompletedEntry:entry];
            }
        }
    }];
}

- (void)updateEmptyState {
    BOOL isEmpty = (self.entries.count == 0);
    self.emptyStateLabel.hidden = !isEmpty;
    if (!isEmpty) {
        [self updatePlaylistHeader];
        return;
    }
    if (!self.libraryLoadedOnce) {
        self.emptyStateLabel.text = EZMusicText(@"EZMusic.Library.Loading", @"Loading your songs...");
    } else if (self.libraryErrorMessage.length > 0) {
        self.emptyStateLabel.text = [NSString stringWithFormat:@"%@\n\n%@", self.libraryErrorMessage,
            EZMusicText(@"EZMusic.Library.PullToRetry", @"Pull down to try again.")];
    } else {
        self.emptyStateLabel.text = EZMusicText(@"EZMusic.Library.Empty", @"No songs yet.\nCreate one on the Create tab.");
    }
    [self updatePlaylistHeader];
}

- (NSInteger)rowForEntryID:(NSString *)entryID {
    if (entryID.length == 0) return NSNotFound;
    for (NSUInteger index = 0; index < self.entries.count; index++) {
        if ([EZMusicString(self.entries[index][@"id"]) isEqualToString:entryID]) return (NSInteger)index;
    }
    return NSNotFound;
}

- (nullable NSDictionary *)entryForID:(NSString *)entryID {
    NSInteger row = [self rowForEntryID:entryID];
    return row == NSNotFound ? nil : self.entries[(NSUInteger)row];
}

- (void)reloadRowForEntryID:(nullable NSString *)entryID {
    if (!self.isViewLoaded) return;
    NSInteger row = [self rowForEntryID:entryID];
    if (row == NSNotFound) return;
    [self.libraryTable reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]]
                             withRowAnimation:UITableViewRowAnimationNone];
}

// Newest first; variants of one request share a timestamp, so order those by take.
- (void)sortEntries {
    [self.entries sortUsingComparator:^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
        NSComparisonResult byDate = [EZMusicString(second[@"created_at"]) compare:EZMusicString(first[@"created_at"])];
        if (byDate != NSOrderedSame) return byDate;
        NSInteger firstVariant = EZMusicInteger(first[@"variant_index"]);
        NSInteger secondVariant = EZMusicInteger(second[@"variant_index"]);
        if (firstVariant == secondVariant) return NSOrderedSame;
        return firstVariant < secondVariant ? NSOrderedAscending : NSOrderedDescending;
    }];
}

#pragma mark - Generation polling

- (void)resumePollingForPendingEntries {
    NSMutableSet<NSString *> *pendingGenerationIDs = [NSMutableSet set];
    for (NSDictionary *entry in self.entries) {
        if ([EZMusicString(entry[@"status"]) isEqualToString:@"pending"]) {
            NSString *generationID = EZMusicString(entry[@"generation_id"]);
            if (generationID.length > 0) [pendingGenerationIDs addObject:generationID];
        }
    }
    for (NSString *generationID in pendingGenerationIDs) {
        [self ensurePollingForGenerationID:generationID];
    }
}

- (void)ensurePollingForGenerationID:(NSString *)generationID {
    if (generationID.length == 0 || self.pollTokens[generationID]) return;

    __weak typeof(self) weakSelf = self;
    EZMusicPollToken *token = [[EZMusicService sharedService]
        pollGenerationWithID:generationID
                    progress:^(NSArray<NSDictionary *> *latestEntries) {
            [weakSelf mergeUpdatedEntries:latestEntries];
        }
                  completion:^(NSArray<NSDictionary *> *finalEntries, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.pollTokens removeObjectForKey:generationID];
            if (finalEntries.count > 0) [strongSelf mergeUpdatedEntries:finalEntries];
            if (error) {
                EZLogf(EZLogLevelWarning, @"Music", @"Polling stopped: %@", error.localizedDescription);
                [strongSelf showToast:EZMusicText(@"EZMusic.Toast.PollLost", @"Couldn't check progress. Pull down in the Library to refresh.")];
                return;
            }
            [strongSelf handleFinishedGenerationID:generationID entries:finalEntries];
        }];
    self.pollTokens[generationID] = token;
}

- (void)cancelAllPolling {
    for (EZMusicPollToken *token in self.pollTokens.allValues) [token cancel];
    [self.pollTokens removeAllObjects];
}

// Applies fresh server rows to the list, touching only what changed.
- (void)mergeUpdatedEntries:(NSArray<NSDictionary *> *)updatedEntries {
    BOOL needsFullReload = NO;
    NSMutableArray<NSIndexPath *> *changedRows = [NSMutableArray array];
    for (NSDictionary *entry in updatedEntries) {
        NSInteger row = [self rowForEntryID:EZMusicString(entry[@"id"])];
        if (row == NSNotFound) {
            [self.entries addObject:entry];
            needsFullReload = YES;
        } else if (![self.entries[(NSUInteger)row] isEqualToDictionary:entry]) {
            self.entries[(NSUInteger)row] = entry;
            [changedRows addObject:[NSIndexPath indexPathForRow:row inSection:0]];
        }
    }
    if (needsFullReload) {
        [self sortEntries];
        [self.libraryTable reloadData];
    } else if (changedRows.count > 0) {
        [self.libraryTable reloadRowsAtIndexPaths:changedRows withRowAnimation:UITableViewRowAnimationNone];
    }
    [self updateEmptyState];
}

- (void)handleFinishedGenerationID:(NSString *)generationID entries:(NSArray<NSDictionary *> *)finalEntries {
    if ([self.announcedGenerationIDs containsObject:generationID]) return;
    [self.announcedGenerationIDs addObject:generationID];
    [self coinBalanceMayHaveChanged];

    NSInteger completedCount = 0;
    NSString *firstFailureText = nil;
    for (NSDictionary *entry in finalEntries) {
        NSString *status = EZMusicString(entry[@"status"]);
        if ([status isEqualToString:@"complete"]) {
            completedCount++;
            [self retainCompletedEntry:entry];
        } else if ([status isEqualToString:@"failed"] && !firstFailureText) {
            NSString *errorText = EZMusicString(entry[@"error_text"]);
            firstFailureText = errorText.length > 0 ? errorText
                : EZMusicText(@"EZMusic.Failure.Generic", @"The song couldn't be created.");
        }
    }

    // Skip popups if the screen isn't showing; the Library rows already say what happened.
    if (self.view.window == nil) return;

    if (completedCount > 0) {
        UINotificationFeedbackGenerator *haptics = [[UINotificationFeedbackGenerator alloc] init];
        [haptics notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
    if (firstFailureText) {
        NSString *message = [NSString stringWithFormat:@"%@\n\n%@", firstFailureText,
            EZMusicText(@"EZMusic.Failure.Refunded", @"Your coins for the songs that failed were refunded.")];
        [self presentAlertWithTitle:EZMusicText(@"EZMusic.Failure.Title", @"Song Couldn't Be Created") message:message];
    } else if (completedCount > 0) {
        [self showToast:(completedCount == 1)
            ? EZMusicText(@"EZMusic.Toast.ReadyOne", @"Your song is ready")
            : EZMusicText(@"EZMusic.Toast.ReadyMany", @"Your songs are ready")];
    }
}

- (void)retainCompletedEntry:(NSDictionary *)entry {
    NSString *entryID = EZMusicString(entry[@"id"]);
    if (entryID.length == 0 || [self.retainingEntryIDs containsObject:entryID]) return;
    if ([[EZMusicLibraryManager sharedManager] localSongURLForEntryID:entryID]) {
        [[EZMusicLibraryManager sharedManager] updateSongMetadataForEntry:entry];
        return;
    }
    [self.retainingEntryIDs addObject:entryID];
    __weak typeof(self) weakSelf = self;
    [[EZMusicService sharedService] fetchPlaybackURLForEntryID:entryID forDownload:NO completion:^(NSURL *url, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (url) [strongSelf retainStreamedSongAtURL:url entry:entry];
        else [strongSelf.retainingEntryIDs removeObject:entryID];
    }];
}

#pragma mark - Table data source

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.entries.count;
}

- (NSInteger)variantCountForGenerationID:(NSString *)generationID {
    NSInteger count = 0;
    for (NSDictionary *entry in self.entries) {
        if ([EZMusicString(entry[@"generation_id"]) isEqualToString:generationID]) count++;
    }
    return count;
}

- (NSString *)detailTextForEntry:(NSDictionary *)entry isError:(BOOL *)isError {
    NSString *status = EZMusicString(entry[@"status"]);
    *isError = NO;

    if ([status isEqualToString:@"pending"]) {
        return EZMusicText(@"EZMusic.Row.Composing", @"Composing your song... this can take a minute or two.");
    }
    if ([status isEqualToString:@"failed"]) {
        *isError = YES;
        NSString *errorText = EZMusicString(entry[@"error_text"]);
        if (errorText.length == 0) errorText = EZMusicText(@"EZMusic.Failure.Generic", @"The song couldn't be created.");
        if (EZMusicInteger(entry[@"coins_charged"]) == 0) {
            errorText = [errorText stringByAppendingFormat:@" %@",
                EZMusicText(@"EZMusic.Row.Refunded", @"Your coins were refunded.")];
        }
        return errorText;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSInteger durationMs = EZMusicInteger(entry[@"duration_actual_ms"]);
    if (durationMs <= 0) durationMs = EZMusicInteger(entry[@"duration_requested_ms"]);
    NSString *style = EZMusicCompactStyle(EZMusicString(entry[@"prompt"]));
    if (style.length) [parts addObject:style];
    [parts addObject:EZMusicFormattedDuration((durationMs + 500) / 1000)];

    NSString *generationID = EZMusicString(entry[@"generation_id"]);
    if ([self variantCountForGenerationID:generationID] > 1) {
        [parts addObject:[NSString stringWithFormat:EZMusicText(@"EZMusic.Row.Take", @"Version %ld"),
            (long)(EZMusicInteger(entry[@"variant_index"]) + 1)]];
    }
    NSDate *createdAt = EZMusicDateFromServerString(EZMusicString(entry[@"created_at"]));
    if (createdAt) {
        static NSDateFormatter *dateFormatter;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            dateFormatter = [[NSDateFormatter alloc] init];
            dateFormatter.dateStyle = NSDateFormatterShortStyle;
            dateFormatter.timeStyle = NSDateFormatterShortStyle;
            dateFormatter.doesRelativeDateFormatting = YES;
        });
        [parts addObject:[dateFormatter stringFromDate:createdAt]];
    }
    return [parts componentsJoinedByString:@"  |  "];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EZMusicTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZMusicTrackCell" forIndexPath:indexPath];
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *entryID = EZMusicString(entry[@"id"]);

    BOOL detailIsError = NO;
    NSString *detail = [self detailTextForEntry:entry isError:&detailIsError];
    NSString *title = EZMusicString(entry[@"title"]);
    if (title.length == 0) title = EZMusicText(@"EZMusic.Row.Untitled", @"Untitled song");

    [cell configureWithTitle:title
                      detail:detail
                      status:EZMusicString(entry[@"status"])
                   isCurrent:[entryID isEqualToString:self.playingEntryID]
                   isPlaying:self.isPlaybackActive
              isLoadingAudio:[entryID isEqualToString:self.loadingEntryID]
                    favorite:[entry[@"is_favorite"] boolValue]
               detailIsError:detailIsError
                 waveformURL:[[EZMusicLibraryManager sharedManager] localSongURLForEntryID:entryID]
          waveformIdentifier:entryID];

    __weak typeof(self) weakSelf = self;
    cell.playHandler = ^{ [weakSelf togglePlaybackForEntryID:entryID]; };
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.hasMoreEntries && !self.isLoadingPage && indexPath.row >= (NSInteger)self.entries.count - 3) {
        [self loadLibraryResetting:NO];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *status = EZMusicString(entry[@"status"]);
    if ([status isEqualToString:@"complete"]) {
        [self togglePlaybackForEntryID:EZMusicString(entry[@"id"])];
    } else if ([status isEqualToString:@"failed"]) {
        BOOL ignored = NO;
        [self presentAlertWithTitle:EZMusicText(@"EZMusic.Failure.Title", @"Song Couldn't Be Created")
                            message:[self detailTextForEntry:entry isError:&ignored]];
    }
}

#pragma mark - Swipe actions

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *status = EZMusicString(entry[@"status"]);
    NSString *entryID = EZMusicString(entry[@"id"]);
    if ([status isEqualToString:@"pending"]) return nil;   // the server refuses to delete songs still composing

    __weak typeof(self) weakSelf = self;
    UIContextualAction *deleteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:EZMusicText(@"EZMusic.Action.Delete", @"Delete")
                          handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        completionHandler(NO);   // keep the row until the user confirms
        [weakSelf confirmDeleteEntryID:entryID];
    }];
    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray arrayWithObject:deleteAction];

    if ([status isEqualToString:@"complete"]) {
        UIContextualAction *shareAction = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
                                title:EZMusicText(@"EZMusic.Action.Share", @"Share")
                              handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            completionHandler(YES);
            [weakSelf shareEntryID:entryID];
        }];
        shareAction.backgroundColor = [UIColor systemBlueColor];
        [actions addObject:shareAction];
    }
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:actions];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    if (![EZMusicString(entry[@"status"]) isEqualToString:@"complete"]) return nil;

    NSString *entryID = EZMusicString(entry[@"id"]);
    BOOL isFavorite = [entry[@"is_favorite"] boolValue];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *favoriteAction = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:isFavorite ? EZMusicText(@"EZMusic.Action.Unfavorite", @"Unstar")
                                             : EZMusicText(@"EZMusic.Action.Favorite", @"Star")
                          handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        completionHandler(YES);
        [weakSelf setFavorite:!isFavorite forEntryID:entryID];
    }];
    favoriteAction.backgroundColor = [UIColor systemYellowColor];
    favoriteAction.image = [UIImage systemImageNamed:isFavorite ? @"star.slash" : @"star"];
    return [UISwipeActionsConfiguration configurationWithActions:@[favoriteAction]];
}

#pragma mark - Favorite, delete, share

// Optimistic: the star changes immediately and is rolled back if the server says no.
- (void)setFavorite:(BOOL)isFavorite forEntryID:(NSString *)entryID {
    NSInteger row = [self rowForEntryID:entryID];
    if (row == NSNotFound) return;
    NSDictionary *original = self.entries[(NSUInteger)row];
    NSMutableDictionary *updated = [original mutableCopy];
    updated[@"is_favorite"] = @(isFavorite);
    self.entries[(NSUInteger)row] = updated;
    [self reloadRowForEntryID:entryID];

    __weak typeof(self) weakSelf = self;
    [[EZMusicService sharedService] setFavorite:isFavorite forEntryID:entryID completion:^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !error) return;
        NSInteger currentRow = [strongSelf rowForEntryID:entryID];
        if (currentRow != NSNotFound) {
            strongSelf.entries[(NSUInteger)currentRow] = original;
            [strongSelf reloadRowForEntryID:entryID];
        }
        [strongSelf showToast:EZMusicText(@"EZMusic.Toast.FavoriteFailed", @"Couldn't update the star. Try again.")];
    }];
}

- (void)confirmDeleteEntryID:(NSString *)entryID {
    __weak typeof(self) weakSelf = self;
    [self presentMusicDialogWithTitle:EZMusicText(@"EZMusic.Delete.Title", @"Delete This Song?")
                              message:EZMusicText(@"EZMusic.Delete.Message", @"This permanently removes the song and its audio. It can't be undone, and coins aren't refunded.")
                         primaryTitle:EZMusicText(@"EZMusic.Action.Delete", @"Delete")
                      primaryHandler:^{ [weakSelf deleteEntryID:entryID]; }];
}

- (void)deleteEntryID:(NSString *)entryID {
    [self showBusyOverlayWithText:EZMusicText(@"EZMusic.Busy.Deleting", @"Deleting...")];
    __weak typeof(self) weakSelf = self;
    [[EZMusicService sharedService] deleteEntryID:entryID completion:^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf hideBusyOverlay];
        if (error) {
            [strongSelf presentAlertWithTitle:EZMusicText(@"EZMusic.Delete.FailedTitle", @"Couldn't Delete")
                                      message:error.localizedDescription];
            return;
        }
        if ([entryID isEqualToString:strongSelf.playingEntryID] || [entryID isEqualToString:strongSelf.loadingEntryID]) {
            [strongSelf stopPlaybackReleasingSession:YES];
        }
        NSInteger row = [strongSelf rowForEntryID:entryID];
        if (row != NSNotFound) {
            [strongSelf.entries removeObjectAtIndex:(NSUInteger)row];
            [strongSelf.libraryTable deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]]
                                           withRowAnimation:UITableViewRowAnimationAutomatic];
        }
        [strongSelf updateEmptyState];
    }];
}

// Downloads the MP3 to a temporary file, then opens the system share sheet.
- (void)shareEntryID:(NSString *)entryID {
    NSDictionary *entry = [self entryForID:entryID];
    if (!entry) return;
    NSString *songTitle = EZMusicString(entry[@"title"]);

    [self showBusyOverlayWithText:EZMusicText(@"EZMusic.Busy.Preparing", @"Preparing song...")];
    __weak typeof(self) weakSelf = self;
    [[EZMusicService sharedService] fetchPlaybackURLForEntryID:entryID forDownload:YES completion:^(NSURL *url, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!url) {
            [strongSelf hideBusyOverlay];
            [strongSelf presentAlertWithTitle:EZMusicText(@"EZMusic.Share.FailedTitle", @"Couldn't Share Song")
                                      message:error.localizedDescription];
            return;
        }
        NSURLSessionDownloadTask *task = [[NSURLSession sharedSession]
            downloadTaskWithURL:url
              completionHandler:^(NSURL *location, NSURLResponse *response, NSError *downloadError) {
            NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            NSURL *destination = nil;
            if (!downloadError && location && statusCode >= 200 && statusCode < 300) {
                // The temp file from NSURLSession is deleted when this block returns,
                // so it has to be moved somewhere stable right here.
                NSFileManager *fileManager = [NSFileManager defaultManager];
                NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
                                    URLByAppendingPathComponent:@"EZMusicShare" isDirectory:YES];
                [fileManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
                NSURL *candidate = [directory URLByAppendingPathComponent:
                                    [EZMusicSafeFileName(songTitle) stringByAppendingString:@".mp3"]];
                [fileManager removeItemAtURL:candidate error:nil];
                if ([fileManager moveItemAtURL:location toURL:candidate error:nil]) destination = candidate;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) innerSelf = weakSelf;
                if (!innerSelf) return;
                [innerSelf hideBusyOverlay];
                if (!destination) {
                    [innerSelf presentAlertWithTitle:EZMusicText(@"EZMusic.Share.FailedTitle", @"Couldn't Share Song")
                                             message:EZMusicText(@"EZMusic.Share.DownloadFailed", @"The download didn't finish. Check your connection and try again.")];
                    return;
                }
                UIActivityViewController *activity = [[UIActivityViewController alloc]
                    initWithActivityItems:@[destination] applicationActivities:nil];
                activity.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *activityError) {
                    [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
                };
                // iPad shows the sheet as a popover and crashes without an anchor.
                activity.popoverPresentationController.sourceView = innerSelf.view;
                activity.popoverPresentationController.sourceRect =
                    CGRectMake(CGRectGetMidX(innerSelf.view.bounds), CGRectGetMidY(innerSelf.view.bounds), 1, 1);
                [innerSelf presentViewController:activity animated:YES completion:nil];
            });
        }];
        [task resume];
    }];
}

#pragma mark - Playback

// The manifest, rather than table order, is the playlist's source of truth.
// Keeping it local means an already-downloaded run can continue offline.
- (NSArray<NSString *> *)playlistEntryIDs {
    NSArray<NSString *> *manifestIDs = [[EZMusicLibraryManager sharedManager] localSongEntryIDs];
    NSMutableArray<NSString *> *playable = [NSMutableArray array];
    for (NSString *entryID in manifestIDs) {
        NSDictionary *entry = [self entryForID:entryID];
        if ([EZMusicString(entry[@"status"]) isEqualToString:@"complete"]) [playable addObject:entryID];
    }
    // Before the first local download completes, use completed library rows so
    // playback still behaves like a playlist for newly generated songs.
    if (playable.count == 0) {
        for (NSDictionary *entry in self.entries) {
            if ([EZMusicString(entry[@"status"]) isEqualToString:@"complete"]) {
                [playable addObject:EZMusicString(entry[@"id"])];
            }
        }
    }
    return playable;
}

- (nullable NSString *)playlistEntryIDFromCurrent:(NSString *)current direction:(NSInteger)direction wrap:(BOOL)wrap {
    NSArray<NSString *> *playlist = [self playlistEntryIDs];
    if (!playlist.count) return nil;
    NSInteger index = [playlist indexOfObject:current];
    if (index == NSNotFound) return playlist.firstObject;
    NSInteger target = index + direction;
    if (target < 0 || target >= (NSInteger)playlist.count) {
        if (!wrap) return nil;
        target = target < 0 ? (NSInteger)playlist.count - 1 : 0;
    }
    return playlist[(NSUInteger)target];
}

- (void)playlistPreviousTapped {
    NSString *current = self.playingEntryID ?: self.loadingEntryID;
    NSString *previous = [self playlistEntryIDFromCurrent:current direction:-1 wrap:YES];
    if (previous) [self togglePlaybackForEntryID:previous];
}

- (void)playlistNextTapped {
    NSString *current = self.playingEntryID ?: self.loadingEntryID;
    NSString *next = [self playlistEntryIDFromCurrent:current direction:1 wrap:YES];
    if (next) [self togglePlaybackForEntryID:next];
}

- (void)playlistPlayTapped {
    NSString *entryID = self.playingEntryID ?: self.loadingEntryID ?: [self playlistEntryIDs].firstObject;
    if (entryID) [self togglePlaybackForEntryID:entryID];
}

- (void)updatePlaylistHeader {
    if (!self.playlistTitleLabel) return;
    NSArray<NSString *> *playlist = [self playlistEntryIDs];
    NSString *current = self.playingEntryID ?: self.loadingEntryID;
    NSDictionary *entry = current.length ? [self entryForID:current] : nil;
    NSString *title = EZMusicString(entry[@"title"]);
    self.playlistTitleLabel.text = title.length ? title : EZMusicText(@"EZMusic.Playlist.Title", @"Local playlist");
    NSInteger currentIndex = current.length ? [playlist indexOfObject:current] + 1 : 0;
    self.playlistDetailLabel.text = playlist.count
        ? (currentIndex ? [NSString stringWithFormat:@"%ld of %ld  •  plays next automatically", (long)currentIndex, (long)playlist.count]
                        : [NSString stringWithFormat:@"%ld downloaded songs", (long)playlist.count])
        : EZMusicText(@"EZMusic.Playlist.Empty", @"Downloaded songs will appear here");
    NSString *symbol = self.isPlaybackActive ? @"pause.fill" : @"play.fill";
    [self.playlistPlayButton setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    BOOL hasSongs = playlist.count > 0;
    self.playlistPlayButton.enabled = hasSongs;
    self.playlistPreviousButton.enabled = hasSongs;
    self.playlistNextButton.enabled = hasSongs;
}

- (void)togglePlaybackForEntryID:(NSString *)entryID {
    // Same song: pause or resume.
    if ([entryID isEqualToString:self.playingEntryID]) {
        if (self.isPlaybackActive) {
            [self.player pause];
            self.isPlaybackActive = NO;
        } else {
            [self.player play];
            self.isPlaybackActive = YES;
        }
        [self reloadRowForEntryID:entryID];
        [self updatePlaylistHeader];
        return;
    }
    if ([entryID isEqualToString:self.loadingEntryID]) return;   // already fetching this one

    NSDictionary *entry = [self entryForID:entryID];
    if (![EZMusicString(entry[@"status"]) isEqualToString:@"complete"]) return;

    [self stopPlaybackReleasingSession:NO];
    self.loadingEntryID = entryID;
    [self reloadRowForEntryID:entryID];
    [self updatePlaylistHeader];

    // Offline/local playback wins once a streamed original has been retained.
    NSURL *localURL = [[EZMusicLibraryManager sharedManager] localSongURLForEntryID:entryID];
    if (localURL) {
        [self startPlayerWithURL:localURL];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[EZMusicService sharedService] fetchPlaybackURLForEntryID:entryID forDownload:NO completion:^(NSURL *url, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (![strongSelf.loadingEntryID isEqualToString:entryID]) return;   // the user picked something else meanwhile
        if (!url) {
            strongSelf.loadingEntryID = nil;
            [strongSelf reloadRowForEntryID:entryID];
            [strongSelf updatePlaylistHeader];
            [strongSelf presentAlertWithTitle:EZMusicText(@"EZMusic.Play.FailedTitle", @"Couldn't Play Song")
                                      message:error.localizedDescription];
            return;
        }
        [strongSelf startPlayerWithURL:url]; // start immediately; don't make playback wait for archiving
        [strongSelf retainStreamedSongAtURL:url entry:entry];
    }];
}

// AVPlayer streams the signed original for a fast first play.  In parallel we
// retain that same original in Documents/EZMusic so later plays work locally.
- (void)retainStreamedSongAtURL:(NSURL *)url entry:(NSDictionary *)entry {
    NSString *entryID = EZMusicString(entry[@"id"]);
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (!error && location && status >= 200 && status < 300) {
            [[EZMusicLibraryManager sharedManager] archiveSongAtTemporaryURL:location entry:entry completion:^(NSURL *localURL, NSError *archiveError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.retainingEntryIDs removeObject:entryID];
                    if (archiveError) {
                        EZLogf(EZLogLevelWarning, @"Music", @"Could not retain %@ locally: %@", entryID, archiveError.localizedDescription);
                    } else {
                        EZLogf(EZLogLevelInfo, @"Music", @"Archived %@ as %@", entryID, localURL.lastPathComponent);
                        [self reloadRowForEntryID:entryID];
                        [self updatePlaylistHeader];
                    }
                });
            }];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.retainingEntryIDs removeObject:entryID];
                EZLogf(EZLogLevelWarning, @"Music", @"Could not download %@ for local archive: %@", entryID,
                       error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status]);
            });
        }
    }];
    [task resume];
}

- (void)startPlayerWithURL:(NSURL *)url {
    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:&sessionError];
    [session setActive:YES error:&sessionError];
    if (sessionError) {
        EZLogf(EZLogLevelWarning, @"Music", @"Audio session setup failed: %@", sessionError.localizedDescription);
    }

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:kEZMusicItemStatusContext];
    self.observedItem = item;
    self.player = [AVPlayer playerWithPlayerItem:item];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(playerItemDidFinish:)
                   name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [center addObserver:self selector:@selector(playerItemFailedToFinish:)
                   name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];

    __weak typeof(self) weakSelf = self;
    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 4)
                                                                  queue:dispatch_get_main_queue()
                                                             usingBlock:^(CMTime time) {
        [weakSelf updatePlaybackProgress];
    }];
    // Playback starts from the KVO callback once the item reports it is ready.
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kEZMusicItemStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    AVPlayerItem *item = object;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (item != self.observedItem) return;   // a newer song replaced this one
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            NSString *entryID = self.loadingEntryID;
            if (!entryID) return;
            self.playingEntryID = entryID;
            self.loadingEntryID = nil;
            self.isPlaybackActive = YES;
            [self.player play];
            [self reloadRowForEntryID:entryID];
            [self updatePlaylistHeader];
        } else if (item.status == AVPlayerItemStatusFailed) {
            NSString *message = item.error.localizedDescription ?: EZMusicText(@"EZMusic.Play.Failed", @"The song couldn't be played.");
            [self stopPlaybackReleasingSession:YES];
            [self presentAlertWithTitle:EZMusicText(@"EZMusic.Play.FailedTitle", @"Couldn't Play Song") message:message];
        }
    });
}

- (void)playerItemDidFinish:(NSNotification *)note {
    NSString *finishedEntryID = self.playingEntryID;
    NSString *nextEntryID = [self playlistEntryIDFromCurrent:finishedEntryID direction:1 wrap:NO];
    // The queue ends naturally at the final song; it does not loop forever.
    if (nextEntryID) {
        [self togglePlaybackForEntryID:nextEntryID];
        return;
    }
    [self.player pause];
    [self.player seekToTime:kCMTimeZero];
    self.isPlaybackActive = NO;
    [self updatePlaybackProgress];
    [self reloadRowForEntryID:self.playingEntryID];
    [self updatePlaylistHeader];
}

- (void)playerItemFailedToFinish:(NSNotification *)note {
    NSError *playbackError = note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self stopPlaybackReleasingSession:YES];
    [self presentAlertWithTitle:EZMusicText(@"EZMusic.Play.FailedTitle", @"Couldn't Play Song")
                        message:playbackError.localizedDescription ?: EZMusicText(@"EZMusic.Play.Failed", @"The song couldn't be played.")];
}

- (void)audioSessionInterrupted:(NSNotification *)note {
    AVAudioSessionInterruptionType type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan && self.isPlaybackActive) {
        // A call or alarm paused audio; reflect that in the row instead of showing a stale pause icon.
        self.isPlaybackActive = NO;
        [self reloadRowForEntryID:self.playingEntryID];
        [self updatePlaylistHeader];
    }
}

- (void)updatePlaybackProgress {
    if (!self.playingEntryID || !self.player) return;
    NSInteger row = [self rowForEntryID:self.playingEntryID];
    if (row == NSNotFound) return;
    double duration = CMTimeGetSeconds(self.player.currentItem.duration);
    double current = CMTimeGetSeconds(self.player.currentTime);
    float progress = (isfinite(duration) && duration > 0 && isfinite(current)) ? (float)(current / duration) : 0.0f;
    EZMusicTrackCell *cell = (EZMusicTrackCell *)[self.libraryTable cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    [cell.progressView setProgress:MIN(MAX(progress, 0.0f), 1.0f) animated:NO];
}

// Frees the player objects without touching any UI. Safe from -dealloc.
- (void)releasePlayerResources {
    if (self.timeObserver && self.player) {
        [self.player removeTimeObserver:self.timeObserver];
    }
    self.timeObserver = nil;
    if (self.observedItem) {
        [self.observedItem removeObserver:self forKeyPath:@"status" context:kEZMusicItemStatusContext];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.observedItem];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.observedItem];
        self.observedItem = nil;
    }
    [self.player pause];
    self.player = nil;
}

- (void)stopPlaybackReleasingSession:(BOOL)releaseSession {
    NSString *previousPlaying = self.playingEntryID;
    NSString *previousLoading = self.loadingEntryID;
    [self releasePlayerResources];
    self.playingEntryID = nil;
    self.loadingEntryID = nil;
    self.isPlaybackActive = NO;
    [self reloadRowForEntryID:previousPlaying];
    [self reloadRowForEntryID:previousLoading];
    [self updatePlaylistHeader];
    if (releaseSession) {
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
    }
}

#pragma mark - Alerts, toast, busy overlay

- (void)presentMusicDialogWithTitle:(NSString *)title message:(NSString *)message primaryTitle:(NSString *)primaryTitle primaryHandler:(void (^)(void))primaryHandler {
    if (self.musicDialogOverlay || self.view.window == nil) return;
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.48];
    self.musicDialogOverlay = overlay;
    [self.view addSubview:overlay];
    UIView *card = [UIView new]; card.translatesAutoresizingMaskIntoConstraints = NO; card.backgroundColor = UIColor.systemBackgroundColor; card.layer.cornerRadius = 22; [overlay addSubview:card];
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem]; closeButton.translatesAutoresizingMaskIntoConstraints = NO; [closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal]; closeButton.tintColor = UIColor.secondaryLabelColor; [card addSubview:closeButton];
    [closeButton addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) { [overlay removeFromSuperview]; self.musicDialogOverlay = nil; }] forControlEvents:UIControlEventTouchUpInside];
    UILabel *heading = [UILabel new]; heading.translatesAutoresizingMaskIntoConstraints = NO; heading.text = title; heading.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold]; heading.numberOfLines = 0; [card addSubview:heading];
    UILabel *body = [UILabel new]; body.translatesAutoresizingMaskIntoConstraints = NO; body.text = message; body.textColor = UIColor.secondaryLabelColor; body.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; body.numberOfLines = 0; [card addSubview:body];
    UIButton *dismiss = [UIButton buttonWithType:UIButtonTypeSystem]; dismiss.translatesAutoresizingMaskIntoConstraints = NO; [dismiss setTitle:primaryTitle ?: EZMusicText(@"EZMusic.OK", @"OK") forState:UIControlStateNormal]; dismiss.backgroundColor = UIColor.systemPurpleColor; dismiss.tintColor = UIColor.whiteColor; dismiss.layer.cornerRadius = 12; [card addSubview:dismiss];
    [dismiss addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) { [overlay removeFromSuperview]; self.musicDialogOverlay = nil; if (primaryHandler) primaryHandler(); }] forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[[card.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:28], [card.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-28], [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor], [closeButton.topAnchor constraintEqualToAnchor:card.topAnchor constant:12], [closeButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12], [closeButton.widthAnchor constraintEqualToConstant:28], [closeButton.heightAnchor constraintEqualToConstant:28], [heading.topAnchor constraintEqualToAnchor:card.topAnchor constant:22], [heading.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20], [heading.trailingAnchor constraintEqualToAnchor:closeButton.leadingAnchor constant:-8], [body.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:9], [body.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor], [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20], [dismiss.topAnchor constraintEqualToAnchor:body.bottomAnchor constant:22], [dismiss.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor], [dismiss.trailingAnchor constraintEqualToAnchor:body.trailingAnchor], [dismiss.heightAnchor constraintEqualToConstant:46], [dismiss.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18]]];
    overlay.alpha = 0; [UIView animateWithDuration:.18 animations:^{ overlay.alpha = 1; }];
}

- (void)presentAlertWithTitle:(NSString *)title message:(NSString *)message {
    [self presentMusicDialogWithTitle:title message:message primaryTitle:nil primaryHandler:nil];
}

- (void)showToast:(NSString *)message {
    [self.toastView removeFromSuperview];

    UIView *toast = [[UIView alloc] init];
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    toast.layer.cornerRadius = 18;
    toast.alpha = 0;
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    label.textColor = [UIColor whiteColor];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.text = message;
    [toast addSubview:label];
    [self.view addSubview:toast];
    self.toastView = toast;

    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:toast.topAnchor constant:10],
        [label.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor constant:-10],
        [label.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor constant:-16],
        [toast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [toast.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [toast.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [toast.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);

    [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 1; } completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; } completion:^(BOOL done) {
                [toast removeFromSuperview];
                if (self.toastView == toast) self.toastView = nil;
            }];
        });
    }];
}

- (void)showBusyOverlayWithText:(NSString *)text {
    if (self.busyOverlay) return;
    UIView *overlay = [[UIView alloc] init];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 14;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter;
    label.text = text;
    [card addSubview:spinner];
    [card addSubview:label];
    [overlay addSubview:card];
    [self.view addSubview:overlay];
    self.busyOverlay = overlay;

    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintGreaterThanOrEqualToConstant:150],
        [spinner.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [label.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:12],
        [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
    ]];
}

- (void)hideBusyOverlay {
    [self.busyOverlay removeFromSuperview];
    self.busyOverlay = nil;
}

@end
