// EZMusicBubbleCell.m
// EZCompleteUI v1.0
//
// Purpose:
//   Implementation of the chat song card described in EZMusicBubbleCell.h.
//
//   How it works:
//     1. -configureWithTitle:... stores which song the row shows and resets
//        the buttons (table cells are reused, so this runs for every row).
//     2. Play and Share both call -withLocalFile:, which hands back the MP3 on
//        this device. If the file isn't there yet it asks the ez-music
//        function for a signed link, downloads it through
//        EZMusicLibraryManager, and then continues.
//     3. While that download runs the buttons are disabled and a spinner is
//        shown, so a second tap can't start a second download.
//
//   Edge cases handled on purpose:
//     - The cell is reused for another song while a download is running: the
//       late result is ignored instead of opening the wrong song.
//     - The download fails (offline, expired session): the user gets an alert
//       and the buttons come back so they can try again.

#import "EZMusicBubbleCell.h"
#import <QuickLook/QuickLook.h>
#import "EZMusicService.h"
#import "EZMusicLibraryManager.h"

@interface EZMusicBubbleCell () <QLPreviewControllerDataSource>
@end

@implementation EZMusicBubbleCell {
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIButton *_playButton;
    UIButton *_shareButton;
    UIActivityIndicatorView *_spinner;

    NSString *_entryID;
    NSString *_songTitle;
    NSURL *_previewURL;                      // File shown by the Quick Look sheet.
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

    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"music.note"]];
    iconView.tintColor = accentColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:iconView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont boldSystemFontOfSize:15];
    _titleLabel.textColor = [UIColor colorWithRed:0.85 green:0.95 blue:0.85 alpha:1.0];
    _titleLabel.numberOfLines = 2;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.font = [UIFont systemFontOfSize:12];
    _subtitleLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_subtitleLabel];

    _playButton = [self makeButtonWithTitle:@"Play" symbol:@"play.fill" accentColor:accentColor];
    [_playButton addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    _shareButton = [self makeButtonWithTitle:@"Share" symbol:@"square.and.arrow.up" accentColor:accentColor];
    [_shareButton addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.color = accentColor;
    _spinner.hidesWhenStopped = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[_playButton, _shareButton, _spinner]];
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 16;
    buttonRow.alignment = UIStackViewAlignmentCenter;
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [container.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        [container.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [container.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],

        [iconView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12],
        [iconView.topAnchor constraintEqualToAnchor:container.topAnchor constant:14],
        [iconView.widthAnchor constraintEqualToConstant:22],
        [iconView.heightAnchor constraintEqualToConstant:22],

        [_titleLabel.topAnchor constraintEqualToAnchor:container.topAnchor constant:12],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-12],

        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],

        [buttonRow.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:10],
        [buttonRow.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [buttonRow.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-12],
    ]];
    return self;
}

- (UIButton *)makeButtonWithTitle:(NSString *)title symbol:(NSString *)symbolName accentColor:(UIColor *)accentColor {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:[@" " stringByAppendingString:title] forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:symbolName] forState:UIControlStateNormal];
    button.tintColor = accentColor;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    return button;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _previewURL = nil;
    [self setBusy:NO];
}

- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                   entryID:(NSString *)entryID
      presentingController:(UIViewController *)presentingController {
    _entryID = [entryID copy];
    _songTitle = title.length > 0 ? [title copy] : @"AI song";
    _presentingController = presentingController;
    _titleLabel.text = _songTitle;
    _subtitleLabel.text = subtitle;
    [self setBusy:NO];
}

// MARK: - Buttons

- (void)setBusy:(BOOL)busy {
    _playButton.enabled = !busy;
    _shareButton.enabled = !busy;
    if (busy) [_spinner startAnimating]; else [_spinner stopAnimating];
}

- (void)playTapped {
    __weak typeof(self) weakSelf = self;
    [self withLocalFile:^(NSURL *fileURL) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_previewURL = fileURL;
        QLPreviewController *previewController = [[QLPreviewController alloc] init];
        previewController.dataSource = strongSelf;
        [[strongSelf topPresenter] presentViewController:previewController animated:YES completion:nil];
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

    [self setBusy:YES];
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
            [innerSelf setBusy:NO];
            if (!savedURL) { [innerSelf finishFailedPrepareForEntryID:requestedEntryID error:downloadError]; return; }
            ready(savedURL);
        }];
    }];
}

- (void)finishFailedPrepareForEntryID:(NSString *)entryID error:(NSError *)error {
    if (![_entryID isEqualToString:entryID]) return;
    [self setBusy:NO];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Couldn't Open Song"
                         message:error.localizedDescription ?: @"The song couldn't be downloaded. Check your connection and try again."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self topPresenter] presentViewController:alert animated:YES completion:nil];
}

// MARK: - QLPreviewControllerDataSource

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return _previewURL ? 1 : 0;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return _previewURL;
}

@end
