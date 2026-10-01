//
//  EZTTSLibraryViewController.m
//  EZTTSLibrary
//

#import "EZTTSLibraryViewController.h"
#import "EZTTSLibraryManager.h"
#import "EZTTSLibraryClipCell.h"
#import "EZTTSClipEditViewController.h"
#import "TextToSpeechViewController.h"
#import "helpers.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

static NSString * const kEZClipCellReuseID = @"EZTTSLibraryClipCell";

@interface EZTTSLibraryViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, AVAudioPlayerDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UILabel *emptyStateLabel;

@property (nonatomic, copy) NSArray<EZTTSManifestEntry *> *clips;

@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, copy, nullable) NSString *playingUUID;

// Combine feature: UUIDs of clips picked in the History screen's multi-select mode,
// in the order the user tapped them — that tap order becomes the concatenation order.
@property (nonatomic, strong) NSMutableArray<NSString *> *selectedUUIDsInOrder;
@property (nonatomic, strong) UIBarButtonItem *selectBarButtonItem;
@property (nonatomic, strong) UIBarButtonItem *combineBarButtonItem;

@end

@implementation EZTTSLibraryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"History";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.clips = @[];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.rowHeight = 84;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[EZTTSLibraryClipCell class] forCellReuseIdentifier:kEZClipCellReuseID];
    [self.view addSubview:self.tableView];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search prompt, voice, or tag";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.emptyStateLabel = [[UILabel alloc] init];
    self.emptyStateLabel.text = @"No archived clips yet — generate something to see it here.";
    self.emptyStateLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyStateLabel.font = [UIFont systemFontOfSize:15];
    self.emptyStateLabel.numberOfLines = 0;
    self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyStateLabel.hidden = YES;
    [self.view addSubview:self.emptyStateLabel];

    self.selectedUUIDsInOrder = [NSMutableArray array];
    self.tableView.allowsMultipleSelectionDuringEditing = YES;

    self.selectBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Select"
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(selectButtonTapped)];
    self.navigationItem.rightBarButtonItem = self.selectBarButtonItem;

    self.combineBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Combine"
                                                                   style:UIBarButtonItemStyleDone
                                                                  target:self
                                                                  action:@selector(combineButtonTapped)];
    self.combineBarButtonItem.enabled = NO;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGFloat margin = 32;
    self.emptyStateLabel.frame = CGRectMake(margin, self.view.safeAreaInsets.top + 40,
                                             self.view.bounds.size.width - margin * 2, 80);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Clips may have changed since last time this screen was shown (new generations,
    // deletes elsewhere) — always refresh from the source of truth on appear.
    [self reloadClips];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopPlayback];
    if (self.tableView.isEditing) {
        [self setSelectionModeActive:NO];
    }
}

#pragma mark - Data

- (void)reloadClips {
    NSString *query = self.searchController.searchBar.text;
    NSArray<EZTTSManifestEntry *> *sorted = [[EZTTSLibraryManager sharedManager] searchClipsWithQuery:query];
    self.clips = [self partitionedPinnedFirst:sorted];
    self.emptyStateLabel.hidden = (self.clips.count > 0);
    [self.tableView reloadData];
}

/// Pins favorites to the top, ordered by when each was pinned (most recent pin first) —
/// not by creation date. That's what makes pin order fully user-controllable: pinning
/// (or re-pinning) something always sends it above every other pinned clip.
- (NSArray<EZTTSManifestEntry *> *)partitionedPinnedFirst:(NSArray<EZTTSManifestEntry *> *)sorted {
    NSMutableArray<EZTTSManifestEntry *> *pinned = [NSMutableArray array];
    NSMutableArray<EZTTSManifestEntry *> *unpinned = [NSMutableArray array];
    for (EZTTSManifestEntry *entry in sorted) {
        if (entry.isFavorite) {
            [pinned addObject:entry];
        } else {
            [unpinned addObject:entry];
        }
    }

    NSArray<EZTTSManifestEntry *> *pinnedByPinRecency = [pinned sortedArrayUsingComparator:^NSComparisonResult(EZTTSManifestEntry *a, EZTTSManifestEntry *b) {
        double aTime = [self pinnedAtTimestampForEntry:a];
        double bTime = [self pinnedAtTimestampForEntry:b];
        if (aTime == bTime) return NSOrderedSame;
        return aTime > bTime ? NSOrderedAscending : NSOrderedDescending; // most recent pin first
    }];

    return [pinnedByPinRecency arrayByAddingObjectsFromArray:unpinned];
}

/// Falls back to creation date for clips favorited before this feature existed (no
/// `pinnedAt` in their metadata yet), so old favorites still sort sensibly instead of
/// all colliding at the same default value.
- (double)pinnedAtTimestampForEntry:(EZTTSManifestEntry *)entry {
    id pinnedAt = entry.metadata[@"pinnedAt"];
    if ([pinnedAt isKindOfClass:[NSNumber class]]) return [pinnedAt doubleValue];
    return entry.created.timeIntervalSince1970;
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self reloadClips];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.clips.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    EZTTSLibraryClipCell *cell = [tableView dequeueReusableCellWithIdentifier:kEZClipCellReuseID forIndexPath:indexPath];
    EZTTSManifestEntry *entry = self.clips[indexPath.row];
    NSURL *audioURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:entry];

    [cell configureWithEntry:entry audioURL:audioURL];
    [cell setPlaying:[entry.uuid isEqualToString:self.playingUUID]];

    __weak typeof(self) weakSelf = self;
    cell.onPlayTapped = ^{ [weakSelf togglePlaybackForEntry:entry]; };
    cell.onFavoriteTapped = ^{ [weakSelf toggleFavoriteForEntry:entry]; };
    cell.onRegenerateTapped = ^{ [weakSelf regenerateEntry:entry]; };
    cell.onEditTapped = ^{ [weakSelf editEntry:entry]; };

    return cell;
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
                leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    EZTTSManifestEntry *entry = self.clips[indexPath.row];
    __weak typeof(self) weakSelf = self;

    UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                           title:@"Share"
                                                                         handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [weakSelf presentShareSheetForEntry:entry sourceView:sourceView];
        completionHandler(YES);
    }];
    share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    share.backgroundColor = [UIColor systemBlueColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[share]];
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
                trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    EZTTSManifestEntry *entry = self.clips[indexPath.row];
    __weak typeof(self) weakSelf = self;

    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                            title:@"Delete"
                                                                          handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        [weakSelf deleteEntry:entry completion:^(BOOL success) {
            completionHandler(success);
        }];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) {
        EZTTSManifestEntry *entry = self.clips[indexPath.row];
        // Guard against double-adding — shouldn't happen via UI, but keeps the order
        // list authoritative if selection state and the array ever drift.
        if (![self.selectedUUIDsInOrder containsObject:entry.uuid]) {
            [self.selectedUUIDsInOrder addObject:entry.uuid];
        }
        [self updateCombineButtonState];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    EZTTSManifestEntry *entry = self.clips[indexPath.row];
    [self togglePlaybackForEntry:entry];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!tableView.isEditing) return;
    EZTTSManifestEntry *entry = self.clips[indexPath.row];
    [self.selectedUUIDsInOrder removeObject:entry.uuid];
    [self updateCombineButtonState];
}

#pragma mark - Regenerate / Edit

/// "Regenerate" doesn't call any network code itself — it sends the user to the compose
/// screen with the same prompt and voice already filled in, one tap from a new clip.
/// This deliberately avoids duplicating -performTTSWithText:...'s network/auth logic
/// onto this screen; that method reads its voice/speed from live UI fields on the
/// compose screen, so reusing it safely means reusing that screen.
- (void)regenerateEntry:(EZTTSManifestEntry *)entry {
    TextToSpeechViewController *composeVC = [[TextToSpeechViewController alloc] init];
    [composeVC prefillWithText:entry.prompt voiceID:entry.voiceID voiceName:entry.voiceName];
    [self.navigationController pushViewController:composeVC animated:YES];
}

- (void)editEntry:(EZTTSManifestEntry *)entry {
    EZTTSClipEditViewController *editVC = [[EZTTSClipEditViewController alloc] initWithEntry:entry];
    [self.navigationController pushViewController:editVC animated:YES];
}

#pragma mark - Mutations

- (void)toggleFavoriteForEntry:(EZTTSManifestEntry *)entry {
    NSIndexPath *oldIndexPath = [self indexPathForClipUUID:entry.uuid];
    EZTTSLibraryManager *manager = [EZTTSLibraryManager sharedManager];
    __weak typeof(self) weakSelf = self;
    void (^completion)(EZTTSManifestEntry *, NSError *) = ^(EZTTSManifestEntry *updated, NSError *error) {
        if (error) {
            [weakSelf presentErrorAlert:error title:@"Couldn't update favorite"];
            return;
        }
        [weakSelf applyFavoriteChange:updated fromIndexPath:oldIndexPath];
    };
    if (entry.isFavorite) {
        [manager unfavoriteClipWithUUID:entry.uuid completion:completion];
    } else {
        [manager favoriteClipWithUUID:entry.uuid completion:completion];
    }
}

/// Recomputes the pinned-first ordering against the latest data, then animates just the
/// one row that changed from `oldIndexPath` to its new position — everything else on
/// screen stays exactly where it is, so this doesn't retrigger waveform loads or reset
/// scroll position for unrelated rows.
- (void)applyFavoriteChange:(EZTTSManifestEntry *)updatedEntry fromIndexPath:(nullable NSIndexPath *)oldIndexPath {
    NSString *query = self.searchController.searchBar.text;
    NSArray<EZTTSManifestEntry *> *sorted = [[EZTTSLibraryManager sharedManager] searchClipsWithQuery:query];
    NSArray<EZTTSManifestEntry *> *newClips = [self partitionedPinnedFirst:sorted];

    NSIndexPath *newIndexPath = nil;
    NSUInteger idx = [newClips indexOfObjectPassingTest:^BOOL(EZTTSManifestEntry *e, NSUInteger i, BOOL *stop) {
        return [e.uuid isEqualToString:updatedEntry.uuid];
    }];
    if (idx != NSNotFound) newIndexPath = [NSIndexPath indexPathForRow:idx inSection:0];

    self.clips = newClips;
    self.emptyStateLabel.hidden = (self.clips.count > 0);

    if (oldIndexPath && newIndexPath && ![oldIndexPath isEqual:newIndexPath]) {
        __weak typeof(self) weakSelf = self;
        [self.tableView performBatchUpdates:^{
            [self.tableView moveRowAtIndexPath:oldIndexPath toIndexPath:newIndexPath];
        } completion:^(BOOL finished) {
            // The move animation relocates the existing cell instance as-is — its star
            // glyph still reflects the pre-toggle state, so patch just that in place.
            EZTTSLibraryClipCell *cell = (EZTTSLibraryClipCell *)[weakSelf.tableView cellForRowAtIndexPath:newIndexPath];
            [cell setFavorite:updatedEntry.isFavorite];
        }];
    } else {
        // Nothing to animate (uuid not found, or position genuinely didn't change) —
        // fall back to a plain reload rather than risk an inconsistent table state.
        [self.tableView reloadData];
    }
}

- (void)deleteEntry:(EZTTSManifestEntry *)entry completion:(void (^)(BOOL success))completion {
    if ([entry.uuid isEqualToString:self.playingUUID]) {
        [self stopPlayback];
    }
    [[EZTTSLibraryManager sharedManager] deleteClipWithUUID:entry.uuid completion:^(BOOL success, NSError * _Nullable error) {
        if (!success) {
            [self presentErrorAlert:error title:@"Couldn't delete clip"];
            completion(NO);
            return;
        }
        [self reloadClips];
        completion(YES);
    }];
}

#pragma mark - Playback

- (void)togglePlaybackForEntry:(EZTTSManifestEntry *)entry {
    if ([entry.uuid isEqualToString:self.playingUUID]) {
        [self stopPlayback];
        return;
    }

    [self stopPlayback]; // stop whatever else was playing first

    NSError *sessionError = nil;
    if (!EZActivatePlaybackAudioSession(&sessionError)) {
        [self presentErrorAlert:sessionError title:@"Couldn't start audio playback"];
        return;
    }

    NSURL *audioURL = [[EZTTSLibraryManager sharedManager] absoluteURLForEntry:entry];
    NSError *playerError;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:audioURL error:&playerError];
    if (!player) {
        [self presentErrorAlert:playerError title:@"Couldn't play clip"];
        return;
    }

    player.delegate = self;
    player.enableRate = YES;
    id storedRate = entry.metadata[@"playbackRate"];
    player.rate = [storedRate isKindOfClass:[NSNumber class]] ? [storedRate floatValue] : 1.0f;
    [player prepareToPlay];
    if (![player play]) {
        NSError *error = [NSError errorWithDomain:@"EZTTSLibrary"
                                             code:-1
                                         userInfo:@{ NSLocalizedDescriptionKey: @"The audio player could not start playback." }];
        [self presentErrorAlert:error title:@"Couldn't play clip"];
        return;
    }

    self.player = player;
    self.playingUUID = entry.uuid;
    [self updateCellPlayingStateForUUID:entry.uuid playing:YES];

    self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                            target:self
                                                          selector:@selector(handleProgressTick)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (void)handleProgressTick {
    if (!self.player || self.playingUUID == nil) return;
    CGFloat progress = self.player.duration > 0 ? (CGFloat)(self.player.currentTime / self.player.duration) : 0;
    [self updateCellPlaybackProgressForUUID:self.playingUUID progress:progress];
}

- (void)stopPlayback {
    [self.player stop];
    self.player = nil;
    [self.progressTimer invalidate];
    self.progressTimer = nil;

    NSString *previousUUID = self.playingUUID;
    self.playingUUID = nil;
    if (previousUUID) [self updateCellPlayingStateForUUID:previousUUID playing:NO];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    [self stopPlayback];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError * _Nullable)error {
    [self stopPlayback];
    if (error) [self presentErrorAlert:error title:@"Playback error"];
}

#pragma mark - Cell lookup helpers

- (void)updateCellPlayingStateForUUID:(NSString *)uuid playing:(BOOL)playing {
    NSIndexPath *indexPath = [self indexPathForClipUUID:uuid];
    if (!indexPath) return;
    EZTTSLibraryClipCell *cell = (EZTTSLibraryClipCell *)[self.tableView cellForRowAtIndexPath:indexPath];
    if (cell) [cell setPlaying:playing];
}

- (void)updateCellPlaybackProgressForUUID:(NSString *)uuid progress:(CGFloat)progress {
    NSIndexPath *indexPath = [self indexPathForClipUUID:uuid];
    if (!indexPath) return;
    EZTTSLibraryClipCell *cell = (EZTTSLibraryClipCell *)[self.tableView cellForRowAtIndexPath:indexPath];
    if (cell) [cell setPlaybackProgress:progress animated:NO];
}

- (nullable NSIndexPath *)indexPathForClipUUID:(NSString *)uuid {
    NSUInteger idx = [self.clips indexOfObjectPassingTest:^BOOL(EZTTSManifestEntry *entry, NSUInteger i, BOOL *stop) {
        return [entry.uuid isEqualToString:uuid];
    }];
    if (idx == NSNotFound) return nil;
    return [NSIndexPath indexPathForRow:idx inSection:0];
}

#pragma mark - Multi-select mode

- (void)selectButtonTapped {
    [self setSelectionModeActive:!self.tableView.isEditing];
}

- (void)setSelectionModeActive:(BOOL)active {
    if (active) {
        [self stopPlayback]; // don't let a playing clip fight with picking clips to combine
    } else {
        [self.selectedUUIDsInOrder removeAllObjects];
    }
    [self.tableView setEditing:active animated:YES];
    self.selectBarButtonItem.title = active ? @"Cancel" : @"Select";

    if (active) {
        UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                                target:nil action:NULL];
        self.toolbarItems = @[flex, self.combineBarButtonItem];
    }
    [self.navigationController setToolbarHidden:!active animated:YES];
    [self updateCombineButtonState];
}

- (void)updateCombineButtonState {
    NSUInteger count = self.selectedUUIDsInOrder.count;
    self.combineBarButtonItem.enabled = (count >= 2);
    self.combineBarButtonItem.title = count > 0
        ? [NSString stringWithFormat:@"Combine (%lu)", (unsigned long)count]
        : @"Combine";
}

#pragma mark - Combine

- (void)combineButtonTapped {
    if (self.selectedUUIDsInOrder.count < 2) return;

    // Snapshot the order now — selectedUUIDsInOrder keeps mutating as the user taps,
    // and this button action shouldn't race with that.
    NSArray<NSString *> *orderedUUIDs = [self.selectedUUIDsInOrder copy];
    EZTTSLibraryManager *manager = [EZTTSLibraryManager sharedManager];

    NSMutableArray<EZTTSManifestEntry *> *orderedEntries = [NSMutableArray arrayWithCapacity:orderedUUIDs.count];
    for (NSString *uuid in orderedUUIDs) {
        EZTTSManifestEntry *entry = [manager clipWithUUID:uuid];
        if (entry) [orderedEntries addObject:entry];
    }
    if (orderedEntries.count < 2) {
        [self presentErrorAlert:[NSError errorWithDomain:@"EZTTSLibraryViewController" code:-2
            userInfo:@{NSLocalizedDescriptionKey: @"Some selected clips could no longer be found."}]
                            title:@"Couldn't combine"];
        return;
    }

    UIAlertController *progress = [UIAlertController alertControllerWithTitle:nil
                                                                        message:@"Combining clips…\n\n"
                                                                 preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [progress.view addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:progress.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:progress.view.bottomAnchor constant:-20]
    ]];
    [spinner startAnimating];
    [self presentViewController:progress animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    [self exportCombinedAudioForEntries:orderedEntries completion:^(NSURL * _Nullable outputURL, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [progress dismissViewControllerAnimated:YES completion:^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                if (error || !outputURL) {
                    [strongSelf presentErrorAlert:error ?: [NSError errorWithDomain:@"EZTTSLibraryViewController" code:-3
                        userInfo:@{NSLocalizedDescriptionKey: @"Could not combine the selected clips."}]
                                              title:@"Combine failed"];
                    return;
                }
                [strongSelf archiveAndPlayCombinedAudioAtURL:outputURL fromEntries:orderedEntries];
            }];
        });
    }];
}

/// Concatenates the given entries' audio, in the order provided, into a single track
/// via AVMutableComposition, then exports to a temp .m4a. m4a is used for the export
/// regardless of the sources' original formats — AVAssetExportPresetAppleM4A is always
/// available for an audio-only composition, and AVFoundation transparently decodes and
/// resamples each source (mp3, wav, whatever mix) while assembling the timeline, so
/// mismatched source formats/sample rates aren't a problem.
/// Runs entirely off the main thread: asset track/duration access below is synchronous
/// I/O, and this can be called right after the user taps Combine.
- (void)exportCombinedAudioForEntries:(NSArray<EZTTSManifestEntry *> *)entries
                            completion:(void (^)(NSURL * _Nullable outputURL, NSError * _Nullable error))completion
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        EZTTSLibraryManager *manager = [EZTTSLibraryManager sharedManager];
        AVMutableComposition *composition = [AVMutableComposition composition];
        AVMutableCompositionTrack *track = [composition addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                      preferredTrackID:kCMPersistentTrackID_Invalid];

        CMTime cursor = kCMTimeZero;
        for (EZTTSManifestEntry *entry in entries) {
            NSURL *sourceURL = [manager absoluteURLForEntry:entry];
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
            NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
            if (audioTracks.count == 0) {
                EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Combine: skipping clip %@ — no audio track found", entry.uuid);
                continue;
            }
            AVAssetTrack *sourceTrack = audioTracks.firstObject;
            CMTimeRange range = CMTimeRangeMake(kCMTimeZero, asset.duration);
            NSError *insertError;
            BOOL inserted = [track insertTimeRange:range ofTrack:sourceTrack atTime:cursor error:&insertError];
            if (!inserted) {
                EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Combine: failed to append clip %@: %@", entry.uuid, insertError.localizedDescription);
                continue;
            }
            cursor = CMTimeAdd(cursor, asset.duration);
        }

        if (CMTimeCompare(cursor, kCMTimeZero) == 0) {
            completion(nil, [NSError errorWithDomain:@"EZTTSLibraryViewController" code:-4
                userInfo:@{NSLocalizedDescriptionKey: @"None of the selected clips could be read."}]);
            return;
        }

        NSString *filename = [NSString stringWithFormat:@"combine_%lld.m4a", (long long)[[NSDate date] timeIntervalSince1970]];
        NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
        [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil]; // exporter refuses to overwrite

        AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:composition
                                                                                presetName:AVAssetExportPresetAppleM4A];
        exportSession.outputURL = outputURL;
        exportSession.outputFileType = AVFileTypeAppleM4A;

        [exportSession exportAsynchronouslyWithCompletionHandler:^{
            switch (exportSession.status) {
                case AVAssetExportSessionStatusCompleted:
                    completion(outputURL, nil);
                    break;
                case AVAssetExportSessionStatusCancelled:
                    completion(nil, [NSError errorWithDomain:@"EZTTSLibraryViewController" code:-5
                        userInfo:@{NSLocalizedDescriptionKey: @"Export was cancelled."}]);
                    break;
                default:
                    completion(nil, exportSession.error ?: [NSError errorWithDomain:@"EZTTSLibraryViewController" code:-6
                        userInfo:@{NSLocalizedDescriptionKey: @"Export failed."}]);
                    break;
            }
        }];
    });
}

/// Archives the merged file through the same manager path every other generated clip
/// goes through — saveAudioData:... — so it shows up in History like any other entry,
/// then plays it back and exits selection mode.
- (void)archiveAndPlayCombinedAudioAtURL:(NSURL *)fileURL fromEntries:(NSArray<EZTTSManifestEntry *> *)entries {
    NSData *audioData = [NSData dataWithContentsOfURL:fileURL];
    [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil]; // manager writes its own permanent copy

    if (!audioData || audioData.length == 0) {
        [self presentErrorAlert:[NSError errorWithDomain:@"EZTTSLibraryViewController" code:-7
            userInfo:@{NSLocalizedDescriptionKey: @"The combined audio came back empty."}]
                            title:@"Combine failed"];
        return;
    }

    NSMutableArray<NSString *> *promptFragments = [NSMutableArray arrayWithCapacity:entries.count];
    for (EZTTSManifestEntry *entry in entries) {
        [promptFragments addObject:entry.prompt.length > 0 ? entry.prompt : @"…"];
    }
    NSString *combinedPrompt = [NSString stringWithFormat:@"[Combined %lu clips] %@",
                                 (unsigned long)entries.count,
                                 [promptFragments componentsJoinedByString:@" | "]];

    EZTTSManifestEntry *firstEntry = entries.firstObject;
    __weak typeof(self) weakSelf = self;
    [[EZTTSLibraryManager sharedManager] saveAudioData:audioData
                                                  prompt:combinedPrompt
                                               voiceName:firstEntry.voiceName
                                                 voiceID:firstEntry.voiceID
                                                provider:@"combined"
                                                   model:nil
                                               extension:@"m4a"
                                              completion:^(EZTTSManifestEntry * _Nullable newEntry, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf setSelectionModeActive:NO];
            [strongSelf reloadClips];
            if (error || !newEntry) {
                [strongSelf presentErrorAlert:error ?: [NSError errorWithDomain:@"EZTTSLibraryViewController" code:-8
                    userInfo:@{NSLocalizedDescriptionKey: @"Could not save the combined clip."}]
                                          title:@"Combine failed"];
                return;
            }
            [strongSelf togglePlaybackForEntry:newEntry];
        });
    }];
}

#pragma mark - Sharing

- (void)presentShareSheetForEntry:(EZTTSManifestEntry *)entry sourceView:(UIView *)sourceView {
    NSURL *exportURL = [[EZTTSLibraryManager sharedManager] exportURLForClipWithUUID:entry.uuid];
    if (!exportURL) {
        NSError *missing = [NSError errorWithDomain:@"EZTTSLibraryViewController"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"That clip's audio file could not be found on disk."}];
        [self presentErrorAlert:missing title:@"Couldn't share clip"];
        return;
    }

    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[exportURL]
                                                                                applicationActivities:nil];
    // Required on iPad — UIActivityViewController is presented as a popover there, and
    // without an anchor it throws at presentation time.
    if (activityVC.popoverPresentationController) {
        activityVC.popoverPresentationController.sourceView = sourceView;
        activityVC.popoverPresentationController.sourceRect = sourceView.bounds;
    }
    [self presentViewController:activityVC animated:YES completion:nil];
}

#pragma mark - Errors

- (void)presentErrorAlert:(NSError *)error title:(NSString *)title {
    EZLogf(EZLogLevelError, @"TTSLibrary", @"%@: %@", title, error.localizedDescription);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:error.localizedDescription
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
