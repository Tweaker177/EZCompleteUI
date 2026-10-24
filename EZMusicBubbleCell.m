// EZMusicBubbleCell.m
// EZCompleteUI v1.2
//
// Purpose:
//   Implementation of the inline song player card described in
//   EZMusicBubbleCell.h.
//
//   How it works:
//     1. -configureWithTitle:... stores which song the row shows and redraws
//        (table cells are reused, so this runs for every row that appears).
//     2. -syncWithPlayer is the one place that draws the play button,
//        scrubber and time. It asks EZMediaPlayerManager "is MY song the
//        current one, and what is it doing?" and draws exactly that. It runs
//        after configure and again on every EZMediaPlayerDidUpdateNotification,
//        which is how the card follows playback it did not start itself.
//     3. Tapping play: if this song is already loaded it toggles pause/resume.
//        Otherwise -withLocalFile: gets the MP3 onto the device (downloading it
//        if needed) and hands it to the manager.
//
//   Cover art: the square at the top left shows the song's generated cover
//   (EZMusicArtworkService) or a music-note placeholder. Covers are made a few
//   seconds after a song finishes, so the card listens for
//   EZMusicArtworkDidUpdateNotification and swaps the picture in when it lands.
//
//   Edge cases handled on purpose:
//     - The row is reused for another song while a download is running: the
//       late result is ignored instead of playing the wrong song.
//     - The download fails (offline, expired session): an alert explains and
//       the button comes back so the user can try again.
//     - Dragging the scrubber stops incoming progress updates from fighting
//       the user's finger; the seek happens when they let go.
//     - Playback fails (corrupt file): the subtitle shows why; tapping play
//       tries again from scratch.

#import "EZMusicBubbleCell.h"
#import "EZMediaPlayerManager.h"
#import "EZMusicService.h"
#import "EZMusicLibraryManager.h"
#import "EZMusicArtworkService.h"

@implementation EZMusicBubbleCell {
    UIImageView *_artworkView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIButton *_playButton;
    UIButton *_shareButton;
    UISlider *_scrubber;
    UILabel *_timeLabel;
    UIActivityIndicatorView *_spinner;

    NSString *_entryID;
    NSString *_songTitle;
    NSString *_baseSubtitle;
    NSInteger _durationSeconds;
    BOOL _isPreparing;        // Fetching/downloading the MP3 before playback.
    BOOL _isScrubbing;        // The user's finger is on the scrubber.
    __weak UIViewController *_presentingController;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    // Same dark card look as EZCodeBlockCell so generated items match.
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    container.layer.cornerRadius = 10;
    container.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    container.layer.borderWidth = 0.5;
    container.clipsToBounds = YES;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:container];

    UIColor *accentColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];

    // Cover art, or a music-note placeholder until one exists.
    _artworkView = [[UIImageView alloc] init];
    _artworkView.tintColor = accentColor;
    _artworkView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    _artworkView.layer.cornerRadius = 8;
    _artworkView.clipsToBounds = YES;
    _artworkView.isAccessibilityElement = NO;
    _artworkView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_artworkView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont boldSystemFontOfSize:15];
    _titleLabel.textColor = [UIColor colorWithRed:0.85 green:0.95 blue:0.85 alpha:1.0];
    _titleLabel.numberOfLines = 2;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.font = [UIFont systemFontOfSize:12];
    _subtitleLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_subtitleLabel];

    _shareButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_shareButton setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    _shareButton.tintColor = accentColor;
    _shareButton.accessibilityLabel = @"Share song";
    _shareButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_shareButton addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:_shareButton];

    _playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _playButton.tintColor = accentColor;
    _playButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_playButton addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:_playButton];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.color = accentColor;
    _spinner.hidesWhenStopped = YES;
    _spinner.userInteractionEnabled = NO;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_spinner];

    _scrubber = [[UISlider alloc] init];
    _scrubber.minimumValue = 0;
    _scrubber.maximumValue = 1;
    _scrubber.minimumTrackTintColor = accentColor;
    _scrubber.maximumTrackTintColor = [UIColor colorWithWhite:0.3 alpha:1.0];
    _scrubber.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrubber addTarget:self action:@selector(scrubberTouchBegan) forControlEvents:UIControlEventTouchDown];
    [_scrubber addTarget:self action:@selector(scrubberValueChanged) forControlEvents:UIControlEventValueChanged];
    [_scrubber addTarget:self action:@selector(scrubberTouchEnded)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [container addSubview:_scrubber];

    _timeLabel = [[UILabel alloc] init];
    _timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    _timeLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    _timeLabel.textAlignment = NSTextAlignmentRight;
    _timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_timeLabel];

    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [container.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        [container.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [container.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],

        [_artworkView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12],
        [_artworkView.topAnchor constraintEqualToAnchor:container.topAnchor constant:12],
        [_artworkView.widthAnchor constraintEqualToConstant:48],
        [_artworkView.heightAnchor constraintEqualToConstant:48],

        [_shareButton.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [_shareButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-6],
        [_shareButton.widthAnchor constraintEqualToConstant:40],
        [_shareButton.heightAnchor constraintEqualToConstant:40],

        [_titleLabel.topAnchor constraintEqualToAnchor:container.topAnchor constant:12],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_artworkView.trailingAnchor constant:10],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_shareButton.leadingAnchor constant:-4],

        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12],

        [_playButton.topAnchor constraintGreaterThanOrEqualToAnchor:_artworkView.bottomAnchor constant:6],
        [_playButton.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:6],
        [_playButton.widthAnchor constraintEqualToConstant:44],
        [_playButton.heightAnchor constraintEqualToConstant:44],
        [_playButton.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],

        [_spinner.centerXAnchor constraintEqualToAnchor:_playButton.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:_playButton.centerYAnchor],

        [_timeLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12],
        [_timeLabel.centerYAnchor constraintEqualToAnchor:_playButton.centerYAnchor],
        [_timeLabel.widthAnchor constraintEqualToConstant:84],

        [_scrubber.leadingAnchor constraintEqualToAnchor:_playButton.trailingAnchor constant:4],
        [_scrubber.trailingAnchor constraintEqualToAnchor:_timeLabel.leadingAnchor constant:-8],
        [_scrubber.centerYAnchor constraintEqualToAnchor:_playButton.centerYAnchor],
    ]];

    // Stay close under the subtitle when it is tall; the rule above keeps the
    // controls clear of the cover when the text is short.
    NSLayoutConstraint *belowSubtitle = [_playButton.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:8];
    belowSubtitle.priority = UILayoutPriorityDefaultHigh;
    belowSubtitle.active = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerDidUpdate)
                                                 name:EZMediaPlayerDidUpdateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(artworkDidUpdate:)
                                                 name:EZMusicArtworkDidUpdateNotification object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _isPreparing = NO;
    _isScrubbing = NO;
}

- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
           durationSeconds:(NSInteger)durationSeconds
                   entryID:(NSString *)entryID
      presentingController:(UIViewController *)presentingController {
    _entryID = [entryID copy];
    _songTitle = title.length > 0 ? [title copy] : @"AI song";
    _baseSubtitle = [subtitle copy];
    _durationSeconds = MAX(durationSeconds, 0);
    _presentingController = presentingController;
    _titleLabel.text = _songTitle;
    _isPreparing = NO;
    _isScrubbing = NO;
    [self showArtwork:[[EZMusicArtworkService sharedService] cachedArtworkForEntryID:_entryID]];
    [self syncWithPlayer];
}

// MARK: - Cover art

/// Shows `artwork`, or the music-note placeholder when there is none.
- (void)showArtwork:(UIImage *)artwork {
    if (artwork) {
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.image = artwork;
    } else {
        _artworkView.contentMode = UIViewContentModeCenter;
        _artworkView.image = [UIImage systemImageNamed:@"music.note"
                                     withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22]];
    }
}

- (void)artworkDidUpdate:(NSNotification *)note {
    NSString *updatedEntryID = note.userInfo[EZMusicArtworkEntryIDKey];
    if (updatedEntryID.length == 0 || ![updatedEntryID isEqualToString:_entryID]) return;
    [self showArtwork:[[EZMusicArtworkService sharedService] cachedArtworkForEntryID:_entryID]];
}

// MARK: - Mirroring the shared player

- (void)playerDidUpdate {
    [self syncWithPlayer];
}

/// Draws the play button, scrubber, time and subtitle from the shared player's
/// current state. The only place those controls are updated.
- (void)syncWithPlayer {
    EZMediaPlayerManager *player = [EZMediaPlayerManager sharedManager];
    BOOL isCurrent = [player isCurrentItemWithIdentifier:_entryID];
    EZMediaPlayerState state = isCurrent ? player.state : EZMediaPlayerStateIdle;

    BOOL showSpinner = _isPreparing || (state == EZMediaPlayerStateLoading);
    NSString *symbol = (state == EZMediaPlayerStatePlaying) ? @"pause.fill" : @"play.fill";
    [_playButton setImage:(showSpinner ? nil : [UIImage systemImageNamed:symbol
                                                   withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22]])
                 forState:UIControlStateNormal];
    _playButton.accessibilityLabel = (state == EZMediaPlayerStatePlaying) ? @"Pause" : @"Play";
    // Tapping during a load would pause/resume something not yet playing.
    _playButton.enabled = !_isPreparing;
    if (showSpinner) [_spinner startAnimating]; else [_spinner stopAnimating];

    _subtitleLabel.text = (state == EZMediaPlayerStateFailed && player.errorMessage.length > 0)
        ? player.errorMessage : _baseSubtitle;

    NSTimeInterval total = isCurrent && player.duration > 0 ? player.duration : (NSTimeInterval)_durationSeconds;
    NSTimeInterval elapsed = isCurrent ? player.currentTime : 0;
    // The scrubber only means something for the song that is loaded.
    _scrubber.enabled = isCurrent && total > 0 && state != EZMediaPlayerStateFailed;
    if (!_isScrubbing) {
        _scrubber.value = (isCurrent && total > 0) ? (float)MIN(elapsed / total, 1.0) : 0;
        _timeLabel.text = [self timeTextForElapsed:elapsed total:total];
    }
}

- (NSString *)timeTextForElapsed:(NSTimeInterval)elapsed total:(NSTimeInterval)total {
    NSString *totalText = total > 0 ? [EZMediaPlayerManager formattedTime:total] : @"--:--";
    return [NSString stringWithFormat:@"%@ / %@", [EZMediaPlayerManager formattedTime:elapsed], totalText];
}

// MARK: - Scrubber

- (void)scrubberTouchBegan {
    _isScrubbing = YES;
}

- (void)scrubberValueChanged {
    // Show where the finger is; the actual seek waits until it lifts.
    EZMediaPlayerManager *player = [EZMediaPlayerManager sharedManager];
    NSTimeInterval total = player.duration > 0 ? player.duration : (NSTimeInterval)_durationSeconds;
    _timeLabel.text = [self timeTextForElapsed:_scrubber.value * total total:total];
}

- (void)scrubberTouchEnded {
    _isScrubbing = NO;
    EZMediaPlayerManager *player = [EZMediaPlayerManager sharedManager];
    if ([player isCurrentItemWithIdentifier:_entryID]) [player seekToFraction:_scrubber.value];
    [self syncWithPlayer];
}

// MARK: - Buttons

- (void)playTapped {
    EZMediaPlayerManager *player = [EZMediaPlayerManager sharedManager];
    BOOL isCurrent = [player isCurrentItemWithIdentifier:_entryID];
    if (isCurrent && player.state != EZMediaPlayerStateFailed) {
        [player togglePlayPause];
        return;
    }

    NSString *requestedEntryID = _entryID;
    __weak typeof(self) weakSelf = self;
    [self withLocalFile:^(NSURL *fileURL) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        // The row may have been reused for a different song while downloading.
        if (!strongSelf || ![strongSelf->_entryID isEqualToString:requestedEntryID]) return;
        EZMediaPlayerItem *item = [EZMediaPlayerItem itemWithIdentifier:requestedEntryID
                                                                  title:strongSelf->_songTitle
                                                               subtitle:strongSelf->_baseSubtitle
                                                                fileURL:fileURL
                                                           durationHint:(NSTimeInterval)strongSelf->_durationSeconds];
        // Cover for the lock screen; if it isn't ready yet the player adds it when it arrives.
        item.artwork = [[EZMusicArtworkService sharedService] cachedArtworkForEntryID:requestedEntryID];
        [[EZMediaPlayerManager sharedManager] playItem:item];
    }];
}

- (void)shareTapped {
    __weak typeof(self) weakSelf = self;
    [self withLocalFile:^(NSURL *fileURL) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        UIActivityViewController *shareController =
            [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
        // iPad requires an anchor for the share popover.
        shareController.popoverPresentationController.sourceView = strongSelf->_shareButton;
        shareController.popoverPresentationController.sourceRect = strongSelf->_shareButton.bounds;
        [[strongSelf topPresenter] presentViewController:shareController animated:YES completion:nil];
    }];
}

/// The controller that should show a sheet: the presenting controller, or
/// whatever it is already presenting, so the sheet is never silently dropped.
- (UIViewController *)topPresenter {
    UIViewController *presenter = _presentingController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    return presenter;
}

// MARK: - Getting the MP3 onto the device

/// Calls `ready` on the main queue with this song's MP3 on the device,
/// downloading it first when needed. Shows an alert if that fails.
- (void)withLocalFile:(void (^)(NSURL *fileURL))ready {
    NSString *requestedEntryID = _entryID;
    if (requestedEntryID.length == 0) return;

    NSURL *localURL = [[EZMusicLibraryManager sharedManager] localSongURLForEntryID:requestedEntryID];
    if (localURL) { ready(localURL); return; }

    _isPreparing = YES;
    [self syncWithPlayer];
    __weak typeof(self) weakSelf = self;
    [[EZMusicService sharedService] fetchPlaybackURLForEntryID:requestedEntryID forDownload:NO
                                                    completion:^(NSURL *remoteURL, NSError *linkError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!remoteURL) { [strongSelf finishFailedPrepareForEntryID:requestedEntryID error:linkError]; return; }

        NSDictionary *entry = @{ @"id": requestedEntryID, @"title": strongSelf->_songTitle ?: @"AI song" };
        [[EZMusicLibraryManager sharedManager] retainSongFromRemoteURL:remoteURL entry:entry
                                                            completion:^(NSURL *savedURL, NSError *downloadError) {
            __strong typeof(weakSelf) innerSelf = weakSelf;
            if (!innerSelf) return;
            // The row may have been reused for a different song meanwhile.
            if (![innerSelf->_entryID isEqualToString:requestedEntryID]) return;
            innerSelf->_isPreparing = NO;
            [innerSelf syncWithPlayer];
            if (!savedURL) { [innerSelf finishFailedPrepareForEntryID:requestedEntryID error:downloadError]; return; }
            ready(savedURL);
        }];
    }];
}

- (void)finishFailedPrepareForEntryID:(NSString *)entryID error:(NSError *)error {
    if (![_entryID isEqualToString:entryID]) return;
    _isPreparing = NO;
    [self syncWithPlayer];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Couldn't Open Song"
                         message:error.localizedDescription ?: @"The song couldn't be downloaded. Check your connection and try again."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self topPresenter] presentViewController:alert animated:YES completion:nil];
}

@end
