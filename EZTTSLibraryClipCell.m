//
//  EZTTSLibraryClipCell.m
//  EZTTSLibrary
//

#import "EZTTSLibraryClipCell.h"
#import "EZTheme.h"
#import "WaveformView.h"
#import "helpers.h"

static NSString * const kEZClipCellPlayGlyph  = @"play.circle.fill";
static NSString * const kEZClipCellPauseGlyph = @"pause.circle.fill";
static NSString * const kEZClipCellStarGlyph       = @"star";
static NSString * const kEZClipCellStarFilledGlyph = @"star.fill";

// Palette names kept for the existing call sites; every value now
// comes from EZTheme so this screen matches the rest of the app.
static UIColor *EZTTSNeonBackground(void) { return [EZTheme chatBackgroundColor]; }
static UIColor *EZTTSNeonPanel(void) { return [EZTheme cardColor]; }
static UIColor *EZTTSNeonField(void) { return [EZTheme backgroundColor]; }
static UIColor *EZTTSNeonViolet(void) { return [EZTheme goldColor]; }
static UIColor *EZTTSNeonCyan(void) { return [EZTheme goldColor]; }
static UIColor *EZTTSNeonPink(void) { return [EZTheme goldColor]; }
static UIColor *EZTTSNeonText(void) { return [EZTheme primaryTextColor]; }
static UIColor *EZTTSNeonDimText(void) { return [EZTheme secondaryTextColor]; }


@interface EZTTSLibraryClipCell ()

@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *favoriteButton;
@property (nonatomic, strong) UIButton *regenerateButton;
@property (nonatomic, strong) UIButton *editButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) WaveformView *waveformView;

@property (nonatomic, copy) NSString *currentAudioPath; // guards against stale async waveform loads

@end

@implementation EZTTSLibraryClipCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = EZTTSNeonPanel();
        self.contentView.backgroundColor = EZTTSNeonPanel();

        _playButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_playButton setImage:[UIImage systemImageNamed:kEZClipCellPlayGlyph] forState:UIControlStateNormal];
        _playButton.tintColor = EZTTSNeonPink();
        [_playButton addTarget:self action:@selector(handlePlayTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_playButton];

        _favoriteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_favoriteButton setImage:[UIImage systemImageNamed:kEZClipCellStarGlyph] forState:UIControlStateNormal];
        _favoriteButton.tintColor = [UIColor systemYellowColor];
        [_favoriteButton addTarget:self action:@selector(handleFavoriteTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_favoriteButton];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont boldSystemFontOfSize:18];
        _titleLabel.textColor = EZTTSNeonText();
        _titleLabel.numberOfLines = 1;
        [self.contentView addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.adjustsFontSizeToFitWidth = YES;
        _subtitleLabel.minimumScaleFactor = 0.5;
        _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = EZTTSNeonDimText();
        _subtitleLabel.numberOfLines = 1;
        [self.contentView addSubview:_subtitleLabel];

        _waveformView = [[WaveformView alloc] init];
        _waveformView.symmetric = YES;
        _waveformView.lineWidth = 1.5;
        _waveformView.waveColor = [EZTTSNeonViolet() colorWithAlphaComponent:0.55];
        _waveformView.progressColor = EZTTSNeonCyan();
        [self.contentView addSubview:_waveformView];

        _regenerateButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_regenerateButton setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
        [_regenerateButton setTitle:@" Regenerate" forState:UIControlStateNormal];
        _regenerateButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _regenerateButton.tintColor = EZTTSNeonCyan();
        _regenerateButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        [_regenerateButton addTarget:self action:@selector(handleRegenerateTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_regenerateButton];

        _editButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_editButton setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
        [_editButton setTitle:@" Edit" forState:UIControlStateNormal];
        _editButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _editButton.tintColor = EZTTSNeonCyan();
        _editButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
        _editButton.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        [_editButton addTarget:self action:@selector(handleEditTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_editButton];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = self.contentView.bounds.size.width;
    CGFloat height = self.contentView.bounds.size.height;
    CGFloat margin = 12;
    CGFloat playSize = 40;
    CGFloat favSize = 28;
    CGFloat actionRowHeight = 24;

    self.playButton.frame = CGRectMake(margin, (height - actionRowHeight - playSize) / 2.0, playSize, playSize);

    CGFloat textX = CGRectGetMaxX(self.playButton.frame) + 10;
    CGFloat textWidth = width - textX - favSize - margin * 2;

    self.favoriteButton.frame = CGRectMake(width - margin - favSize, margin - 4, favSize, favSize);

    // Title first, then the voice/duration/date subtitle, then the waveform, then the
    // action row pinned to the bottom.
    self.titleLabel.frame = CGRectMake(textX, 8, textWidth, 22);
    self.subtitleLabel.frame = CGRectMake(textX, CGRectGetMaxY(self.titleLabel.frame) + 2, textWidth, 14);

    CGFloat actionRowY = height - actionRowHeight - 6;
    CGFloat waveY = CGRectGetMaxY(self.subtitleLabel.frame) + 6;
    self.waveformView.frame = CGRectMake(textX, waveY, textWidth, actionRowY - waveY - 4);

    self.regenerateButton.frame = CGRectMake(textX, actionRowY, textWidth * 0.55, actionRowHeight);
    CGFloat editWidth = textWidth * 0.4;
    self.editButton.frame = CGRectMake(textX + textWidth - editWidth, actionRowY, editWidth, actionRowHeight);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.onPlayTapped = nil;
    self.onFavoriteTapped = nil;
    self.onRegenerateTapped = nil;
    self.onEditTapped = nil;
    self.currentAudioPath = nil;
    [self.waveformView clear];
    [self setPlaying:NO];
}

#pragma mark - Configuration

- (void)configureWithEntry:(EZTTSManifestEntry *)entry audioURL:(NSURL *)audioURL {
    NSString *title = entry.metadata[@"title"];
    if (![title isKindOfClass:[NSString class]] || title.length == 0) {
        title = entry.preview.length > 0 ? entry.preview : entry.prompt;
    }
    self.titleLabel.text = title;

    NSString *voiceLabel = entry.voiceName ?: (entry.voiceID ?: @"Unknown voice");
    NSString *durationLabel = [self formattedDuration:entry.duration];
    self.subtitleLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@", voiceLabel, durationLabel, [self formattedRelativeDate:entry.created]];

    UIImage *starImage = [UIImage systemImageNamed:entry.isFavorite ? kEZClipCellStarFilledGlyph : kEZClipCellStarGlyph];
    [self.favoriteButton setImage:starImage forState:UIControlStateNormal];

    [self.waveformView clear];
    self.currentAudioPath = audioURL.path;
    __weak typeof(self) weakSelf = self;
    NSString *pathAtLoadTime = audioURL.path;
    [self.waveformView loadAudioFileAtURL:audioURL completion:^(BOOL success, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // The cell may have been reused for a different row by the time this returns —
        // only apply the result if it's still showing the clip we asked for.
        if (![strongSelf.currentAudioPath isEqualToString:pathAtLoadTime]) return;
        if (!success) {
            EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Waveform render failed for %@: %@", pathAtLoadTime.lastPathComponent, error.localizedDescription);
        }
    }];
}

- (void)setPlaying:(BOOL)playing {
    NSString *glyph = playing ? kEZClipCellPauseGlyph : kEZClipCellPlayGlyph;
    [self.playButton setImage:[UIImage systemImageNamed:glyph] forState:UIControlStateNormal];
    if (!playing) {
        [self.waveformView setProgress:0 animated:NO];
    }
}

- (void)setFavorite:(BOOL)favorite {
    UIImage *starImage = [UIImage systemImageNamed:favorite ? kEZClipCellStarFilledGlyph : kEZClipCellStarGlyph];
    [self.favoriteButton setImage:starImage forState:UIControlStateNormal];
}

- (void)setPlaybackProgress:(CGFloat)progress animated:(BOOL)animated {
    [self.waveformView setProgress:progress animated:animated];
}

#pragma mark - Actions

- (void)handlePlayTapped {
    if (self.onPlayTapped) self.onPlayTapped();
}

- (void)handleFavoriteTapped {
    if (self.onFavoriteTapped) self.onFavoriteTapped();
}

- (void)handleRegenerateTapped {
    if (self.onRegenerateTapped) self.onRegenerateTapped();
}

- (void)handleEditTapped {
    if (self.onEditTapped) self.onEditTapped();
}

#pragma mark - Formatting

- (NSString *)formattedDuration:(double)seconds {
    if (seconds <= 0) return @"--:--";
    NSInteger total = (NSInteger)round(seconds);
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

- (NSString *)formattedRelativeDate:(NSDate *)date {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateStyle = NSDateFormatterShortStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
    });
    return [formatter stringFromDate:date];
}

@end
