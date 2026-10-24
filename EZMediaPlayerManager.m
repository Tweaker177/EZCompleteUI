// EZMediaPlayerManager.m
// EZCompleteUI v1.2
//
// Purpose:
//   Implementation of the app's shared audio player described in
//   EZMediaPlayerManager.h. Read that header first for what it offers and why.
//
//   How it is put together (for newcomers):
//     - One AVPlayer lives for the whole life of the app. "Playing a song"
//       means swapping the AVPlayerItem inside it.
//     - -state is never stored by hand-waving: -refreshStateAndPublish works it
//       out from the facts (is there a current item? did the file fail to load?
//       what does AVPlayer say it is doing?) every time something changes.
//       That keeps the buttons in the UI honest even when the system pauses us
//       (a phone call, unplugged headphones).
//     - After every change, -publishChange updates the lock-screen entry and
//       posts EZMediaPlayerDidUpdateNotification for any UI that is listening.
//     - Lock-screen buttons are registered once, the first time something plays.
//
//   Edge cases handled on purpose:
//     - The audio session cannot be activated: the item becomes Failed with an
//       explanation instead of silently not playing.
//     - The file is corrupt or a remote URL fails: Failed with a message; the
//       Up Next list is left alone so the user can skip to the next item.
//     - A call or Siri interrupts playback: it resumes afterward only if the
//       user hadn't paused it themselves and the system says resuming is OK.
//     - Headphones or a Bluetooth speaker disconnect: playback pauses, as
//       users expect, instead of blasting out of the phone speaker.
//     - Callbacks arrive on background threads (KVO, lock-screen buttons):
//       they all hop to the main queue before touching any state.
//     - Items with a custom speed keep it after pause/resume and seeking.
//
// Changes from v1.0:
//   - Per-item playback speed (pitch preserved).
//   - skipBySeconds:, playPrevious and a short play history.
//
// Changes from v1.1:
//   - Lock-screen artwork (EZMediaPlayerItem.artwork). When a song's cover
//     finishes generating while it is playing, the lock screen is refreshed.
//
// Changes from v1.0 (continued):
//   - Lock screen: skip forward/back 15s and previous track commands. iOS shows
//     the track buttons only when previous or next is enabled, so they are
//     enabled only when there actually is somewhere to go; a lone clip gets
//     the +/-15s buttons instead.

#import "EZMediaPlayerManager.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import "EZMusicArtworkService.h"
#import "helpers.h"

NSNotificationName const EZMediaPlayerDidUpdateNotification = @"EZMediaPlayerDidUpdateNotification";
NSNotificationName const EZMediaPlayerWillStartNotification = @"EZMediaPlayerWillStartNotification";

// KVO contexts. Their addresses identify who the callback is for.
static void *kPlayerItemStatusContext = &kPlayerItemStatusContext;
static void *kPlayerTimeControlContext = &kPlayerTimeControlContext;

// Lock-screen skip buttons jump this many seconds.
static const NSTimeInterval kEZMediaPlayerSkipSeconds = 15.0;
// "Previous" restarts the item if it has played longer than this.
static const NSTimeInterval kEZMediaPlayerRestartThreshold = 3.0;
// How many earlier items "previous" can walk back through.
static const NSUInteger kEZMediaPlayerHistoryLimit = 20;

#pragma mark - EZMediaPlayerItem

@implementation EZMediaPlayerItem

+ (instancetype)itemWithIdentifier:(NSString *)identifier
                             title:(NSString *)title
                          subtitle:(NSString *)subtitle
                           fileURL:(NSURL *)fileURL
                      durationHint:(NSTimeInterval)durationHint {
    EZMediaPlayerItem *item = [[self alloc] init];
    item->_identifier = [identifier copy];
    item->_title = title.length > 0 ? [title copy] : @"Audio";
    item->_subtitle = [subtitle copy];
    item->_fileURL = fileURL;
    item->_durationHint = MAX(durationHint, 0);
    item->_playbackRate = 1.0f;
    return item;
}

+ (instancetype)itemWithIdentifier:(NSString *)identifier
                             title:(NSString *)title
                          subtitle:(NSString *)subtitle
                           fileURL:(NSURL *)fileURL
                      durationHint:(NSTimeInterval)durationHint
                      playbackRate:(float)playbackRate {
    EZMediaPlayerItem *item = [self itemWithIdentifier:identifier title:title subtitle:subtitle
                                               fileURL:fileURL durationHint:durationHint];
    // AVPlayer supports roughly 0.5x-2x with pitch correction; stay in range.
    item->_playbackRate = (isfinite(playbackRate) && playbackRate > 0) ? MIN(MAX(playbackRate, 0.5f), 2.0f) : 1.0f;
    return item;
}

@end

#pragma mark - EZMediaPlayerManager

@interface EZMediaPlayerManager ()
@property (nonatomic) EZMediaPlayerState state;
@property (nonatomic, strong, nullable) EZMediaPlayerItem *currentItem;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic, strong) AVPlayer *player;
// The AVPlayerItem we are currently watching, kept so its observers can be
// removed exactly once when it is replaced.
@property (nonatomic, strong, nullable) AVPlayerItem *observedPlayerItem;
@property (nonatomic, strong) NSMutableArray<EZMediaPlayerItem *> *queue;
// Items that played before the current one, oldest first. Used by -playPrevious.
@property (nonatomic, strong) NSMutableArray<EZMediaPlayerItem *> *history;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, assign) BOOL commandsConfigured;
// YES once the user (or the lock screen) paused on purpose. An interruption
// that ends must not restart something the user had paused.
@property (nonatomic, assign) BOOL userRequestedPause;
@end

@implementation EZMediaPlayerManager

+ (instancetype)sharedManager {
    static EZMediaPlayerManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [[self alloc] initPrivate]; });
    return manager;
}

- (instancetype)initPrivate {
    self = [super init];
    if (!self) return nil;

    _queue = [NSMutableArray array];
    _history = [NSMutableArray array];
    _player = [[AVPlayer alloc] init];
    // Stop (rather than blank or loop) when an item ends; we decide what is next.
    _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
    [_player addObserver:self forKeyPath:@"timeControlStatus"
                 options:NSKeyValueObservingOptionNew context:kPlayerTimeControlContext];

    __weak typeof(self) weakSelf = self;
    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 4)
                                                          queue:dispatch_get_main_queue()
                                                     usingBlock:^(CMTime time) {
        [weakSelf playbackTick];
    }];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(audioSessionInterrupted:)
                   name:AVAudioSessionInterruptionNotification object:nil];
    [center addObserver:self selector:@selector(audioRouteChanged:)
                   name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:self selector:@selector(musicArtworkDidUpdate:)
                   name:EZMusicArtworkDidUpdateNotification object:nil];
    return self;
}

#pragma mark - Read-only state

- (NSArray<EZMediaPlayerItem *> *)upNext {
    return [self.queue copy];
}

- (BOOL)isCurrentItemWithIdentifier:(NSString *)identifier {
    return identifier.length > 0 && [self.currentItem.identifier isEqualToString:identifier];
}

- (NSTimeInterval)duration {
    AVPlayerItem *playerItem = self.observedPlayerItem;
    if (playerItem.status == AVPlayerItemStatusReadyToPlay) {
        CMTime itemDuration = playerItem.duration;
        double seconds = CMTIME_IS_NUMERIC(itemDuration) ? CMTimeGetSeconds(itemDuration) : 0;
        if (isfinite(seconds) && seconds > 0) return seconds;
    }
    return self.currentItem.durationHint;
}

- (NSTimeInterval)currentTime {
    if (!self.currentItem) return 0;
    CMTime playerTime = self.player.currentTime;
    double seconds = CMTIME_IS_NUMERIC(playerTime) ? CMTimeGetSeconds(playerTime) : 0;
    if (!isfinite(seconds) || seconds < 0) return 0;
    double length = self.duration;
    return length > 0 ? MIN(seconds, length) : seconds;
}

+ (NSString *)formattedTime:(NSTimeInterval)seconds {
    NSInteger total = (NSInteger)llround(MAX(seconds, 0));
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

#pragma mark - Starting, queueing, stopping

- (void)playItem:(EZMediaPlayerItem *)item {
    [self startItem:item recordingHistory:YES];
}

/// `recordHistory` is NO when going back, so "previous" doesn't pile up the
/// item we just left as if it were new history.
- (void)startItem:(EZMediaPlayerItem *)item recordingHistory:(BOOL)recordHistory {
    if (!item || !item.fileURL) return;

    if (recordHistory && self.currentItem && ![self.currentItem.identifier isEqualToString:item.identifier]) {
        [self.history addObject:self.currentItem];
        if (self.history.count > kEZMediaPlayerHistoryLimit) [self.history removeObjectAtIndex:0];
    }

    // Tell players that haven't moved onto this manager yet to stop.
    [[NSNotificationCenter defaultCenter] postNotificationName:EZMediaPlayerWillStartNotification object:self];

    [self detachObservedItem];
    self.currentItem = item;
    self.errorMessage = nil;
    self.userRequestedPause = NO;
    // It is playing now, so it should not also wait in line.
    NSMutableArray *remaining = [NSMutableArray array];
    for (EZMediaPlayerItem *queued in self.queue) {
        if (![queued.identifier isEqualToString:item.identifier]) [remaining addObject:queued];
    }
    self.queue = remaining;

    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:&sessionError];
    if (!sessionError) [session setActive:YES error:&sessionError];
    if (sessionError) {
        EZLogf(EZLogLevelWarning, @"Player", @"Audio session setup failed: %@", sessionError.localizedDescription);
        [self.player replaceCurrentItemWithPlayerItem:nil];
        self.errorMessage = @"The audio output couldn't be started. Close other audio apps and try again.";
        [self refreshStateAndPublish];
        return;
    }

    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:item.fileURL];
    // Keeps voices natural when a clip plays faster or slower than normal.
    playerItem.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
    [playerItem addObserver:self forKeyPath:@"status"
                    options:NSKeyValueObservingOptionNew context:kPlayerItemStatusContext];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(playerItemDidPlayToEnd:)
                   name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
    [center addObserver:self selector:@selector(playerItemFailedToPlayToEnd:)
                   name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
    self.observedPlayerItem = playerItem;

    [self configureRemoteCommandsIfNeeded];
    [self.player replaceCurrentItemWithPlayerItem:playerItem];
    [self startPlayerAtCurrentItemRate];   // Begins as soon as the file is ready.
    [self refreshStateAndPublish];
}

/// -play always starts at 1x, so a custom speed is applied right after it.
- (void)startPlayerAtCurrentItemRate {
    [self.player play];
    float rate = self.currentItem.playbackRate;
    if (rate > 0 && fabsf(rate - 1.0f) > 0.001f) self.player.rate = rate;
}

- (void)enqueueItem:(EZMediaPlayerItem *)item {
    if (!item || !item.fileURL) return;
    if (!self.currentItem) { [self playItem:item]; return; }
    if ([item.identifier isEqualToString:self.currentItem.identifier]) return;
    for (EZMediaPlayerItem *queued in self.queue) {
        if ([queued.identifier isEqualToString:item.identifier]) return;
    }
    [self.queue addObject:item];
    [self publishChange];
}

- (void)playNext {
    if (self.queue.count == 0) {
        [self clearCurrentItemDeactivatingSession:YES];
        return;
    }
    EZMediaPlayerItem *next = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];
    [self playItem:next];
}

- (void)playPrevious {
    if (!self.currentItem) return;
    EZMediaPlayerItem *previous = self.history.lastObject;
    if (self.currentTime > kEZMediaPlayerRestartThreshold || !previous) {
        [self seekToSeconds:0];
        return;
    }
    EZMediaPlayerItem *leaving = self.currentItem;
    [self.history removeLastObject];
    [self startItem:previous recordingHistory:NO];
    // The one we left is next in line again.
    [self.queue insertObject:leaving atIndex:0];
    [self publishChange];
}

- (void)stop {
    [self.history removeAllObjects];
    [self.queue removeAllObjects];
    [self clearCurrentItemDeactivatingSession:NO];
}

/// Unloads the current item. When `deactivate` is YES the audio session is
/// released too, so music from other apps can resume.
- (void)clearCurrentItemDeactivatingSession:(BOOL)deactivate {
    [self detachObservedItem];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    self.currentItem = nil;
    self.errorMessage = nil;
    self.userRequestedPause = NO;
    if (deactivate) {
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
    }
    [self refreshStateAndPublish];
}

- (void)detachObservedItem {
    AVPlayerItem *playerItem = self.observedPlayerItem;
    if (!playerItem) return;
    [playerItem removeObserver:self forKeyPath:@"status" context:kPlayerItemStatusContext];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
    [center removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
    self.observedPlayerItem = nil;
}

#pragma mark - Transport

- (void)togglePlayPause {
    if (self.state == EZMediaPlayerStatePlaying || self.state == EZMediaPlayerStateLoading) {
        [self pause];
    } else if (self.state == EZMediaPlayerStatePaused) {
        [self resume];
    }
}

- (void)pause {
    if (!self.currentItem) return;
    self.userRequestedPause = YES;
    [self.player pause];
    [self refreshStateAndPublish];
}

- (void)resume {
    if (!self.currentItem || self.state == EZMediaPlayerStateFailed) return;
    self.userRequestedPause = NO;
    NSError *sessionError = nil;
    [[AVAudioSession sharedInstance] setActive:YES error:&sessionError];
    if (sessionError) {
        EZLogf(EZLogLevelWarning, @"Player", @"Could not reactivate audio session: %@", sessionError.localizedDescription);
    }
    [self startPlayerAtCurrentItemRate];
    [self refreshStateAndPublish];
}

- (void)seekToFraction:(double)fraction {
    if (!self.currentItem || self.state == EZMediaPlayerStateFailed) return;
    double length = self.duration;
    if (length <= 0) return;
    double clamped = MIN(MAX(fraction, 0.0), 1.0);
    [self seekToSeconds:clamped * length];
}

/// Seeks to an absolute position. Position 0 works even before the length is known.
- (void)seekToSeconds:(NSTimeInterval)seconds {
    if (!self.currentItem || self.state == EZMediaPlayerStateFailed) return;
    CMTime target = CMTimeMakeWithSeconds(MAX(seconds, 0), 600);
    __weak typeof(self) weakSelf = self;
    [self.player seekToTime:target toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
          completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf publishChange]; });
    }];
}

- (void)skipBySeconds:(NSTimeInterval)seconds {
    if (!self.currentItem || self.state == EZMediaPlayerStateFailed) return;
    double length = self.duration;
    double target = self.currentTime + seconds;
    if (length > 0 && target >= length - 0.1) {
        [self playNext];   // Skipped past the end: same as finishing.
        return;
    }
    [self seekToSeconds:target];
}

#pragma mark - State

/// Works out the state from the facts and tells everyone. Call after any change.
- (void)refreshStateAndPublish {
    AVPlayerItem *playerItem = self.observedPlayerItem;
    EZMediaPlayerState newState;

    if (!self.currentItem) {
        newState = EZMediaPlayerStateIdle;
    } else {
        if (playerItem.status == AVPlayerItemStatusFailed && self.errorMessage.length == 0) {
            self.errorMessage = [self friendlyMessageForError:playerItem.error];
        }
        if (self.errorMessage.length > 0) {
            newState = EZMediaPlayerStateFailed;
        } else if (!playerItem || playerItem.status == AVPlayerItemStatusUnknown) {
            newState = EZMediaPlayerStateLoading;
        } else {
            switch (self.player.timeControlStatus) {
                case AVPlayerTimeControlStatusPlaying:
                    newState = EZMediaPlayerStatePlaying; break;
                case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate:
                    newState = EZMediaPlayerStateLoading; break;
                default:
                    newState = EZMediaPlayerStatePaused; break;
            }
        }
    }
    self.state = newState;
    [self publishChange];
}

- (NSString *)friendlyMessageForError:(NSError *)error {
    NSString *reason = error.localizedDescription;
    return reason.length > 0 ? [NSString stringWithFormat:@"This audio couldn't be played: %@", reason]
                             : @"This audio couldn't be played.";
}

- (void)publishChange {
    [self updateNowPlayingInfo];
    [self updateRemoteCommandAvailability];
    [[NSNotificationCenter defaultCenter] postNotificationName:EZMediaPlayerDidUpdateNotification object:self];
}

/// Four times a second while playing, so progress bars move smoothly.
- (void)playbackTick {
    if (self.state != EZMediaPlayerStatePlaying) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:EZMediaPlayerDidUpdateNotification object:self];
}

#pragma mark - KVO and AVFoundation notifications

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == kPlayerItemStatusContext || context == kPlayerTimeControlContext) {
        // AVFoundation can call this on any thread.
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshStateAndPublish]; });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)playerItemDidPlayToEnd:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (note.object != self.observedPlayerItem) return;   // a stale item
        [self playNext];   // With nothing queued this unloads and releases the session.
    });
}

- (void)playerItemFailedToPlayToEnd:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (note.object != self.observedPlayerItem) return;
        self.errorMessage = [self friendlyMessageForError:note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]];
        [self refreshStateAndPublish];
    });
}

- (void)audioSessionInterrupted:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAudioSessionInterruptionType type =
            [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        // AVPlayer pauses itself when an interruption begins and the KVO above
        // updates the buttons. On the way back, only restart what the user
        // hadn't paused on purpose, and only if the system says that is OK.
        if (type == AVAudioSessionInterruptionTypeEnded && self.currentItem && !self.userRequestedPause) {
            AVAudioSessionInterruptionOptions options =
                [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
            if (options & AVAudioSessionInterruptionOptionShouldResume) [self resume];
        }
    });
}

/// A cover finished generating. Song items use the song's entry ID as their
/// identifier, so if it is the one loaded, show the cover on the lock screen.
- (void)musicArtworkDidUpdate:(NSNotification *)note {
    NSString *entryID = note.userInfo[EZMusicArtworkEntryIDKey];
    EZMediaPlayerItem *item = self.currentItem;
    if (entryID.length == 0 || !item || ![item.identifier isEqualToString:entryID]) return;
    item.artwork = [[EZMusicArtworkService sharedService] cachedArtworkForEntryID:entryID];
    [self publishChange];
}

- (void)audioRouteChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAudioSessionRouteChangeReason reason =
            [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
        // Headphones unplugged or a Bluetooth speaker turned off.
        if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable &&
            self.state == EZMediaPlayerStatePlaying) {
            [self pause];
        }
    });
}

#pragma mark - Lock screen and Control Center

- (void)configureRemoteCommandsIfNeeded {
    if (self.commandsConfigured) return;
    self.commandsConfigured = YES;

    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    [commandCenter.playCommand addTarget:self action:@selector(handlePlayCommand:)];
    [commandCenter.pauseCommand addTarget:self action:@selector(handlePauseCommand:)];
    [commandCenter.togglePlayPauseCommand addTarget:self action:@selector(handleTogglePlayPauseCommand:)];
    [commandCenter.nextTrackCommand addTarget:self action:@selector(handleNextTrackCommand:)];
    [commandCenter.previousTrackCommand addTarget:self action:@selector(handlePreviousTrackCommand:)];
    [commandCenter.changePlaybackPositionCommand addTarget:self action:@selector(handleChangePositionCommand:)];
    commandCenter.skipForwardCommand.preferredIntervals = @[@(kEZMediaPlayerSkipSeconds)];
    commandCenter.skipBackwardCommand.preferredIntervals = @[@(kEZMediaPlayerSkipSeconds)];
    [commandCenter.skipForwardCommand addTarget:self action:@selector(handleSkipCommand:)];
    [commandCenter.skipBackwardCommand addTarget:self action:@selector(handleSkipCommand:)];
}

- (MPRemoteCommandHandlerStatus)handlePreviousTrackCommand:(MPRemoteCommandEvent *)event {
    if (!self.currentItem) return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
    dispatch_async(dispatch_get_main_queue(), ^{ [self playPrevious]; });
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handleSkipCommand:(MPSkipIntervalCommandEvent *)event {
    if (!self.currentItem) return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
    BOOL forward = (event.command == [MPRemoteCommandCenter sharedCommandCenter].skipForwardCommand);
    NSTimeInterval interval = event.interval > 0 ? event.interval : kEZMediaPlayerSkipSeconds;
    dispatch_async(dispatch_get_main_queue(), ^{ [self skipBySeconds:(forward ? interval : -interval)]; });
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handlePlayCommand:(MPRemoteCommandEvent *)event {
    if (!self.currentItem) return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
    dispatch_async(dispatch_get_main_queue(), ^{ [self resume]; });
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handlePauseCommand:(MPRemoteCommandEvent *)event {
    if (!self.currentItem) return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
    dispatch_async(dispatch_get_main_queue(), ^{ [self pause]; });
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handleTogglePlayPauseCommand:(MPRemoteCommandEvent *)event {
    if (!self.currentItem) return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
    dispatch_async(dispatch_get_main_queue(), ^{ [self togglePlayPause]; });
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handleNextTrackCommand:(MPRemoteCommandEvent *)event {
    if (self.queue.count == 0) return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
    dispatch_async(dispatch_get_main_queue(), ^{ [self playNext]; });
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handleChangePositionCommand:(MPChangePlaybackPositionCommandEvent *)event {
    if (!self.currentItem) return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
    NSTimeInterval requestedPosition = event.positionTime;
    dispatch_async(dispatch_get_main_queue(), ^{
        double length = self.duration;
        if (length > 0) [self seekToFraction:requestedPosition / length];
    });
    return MPRemoteCommandHandlerStatusSuccess;
}

- (void)updateRemoteCommandAvailability {
    if (!self.commandsConfigured) return;
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    BOOL hasItem = (self.currentItem != nil);
    commandCenter.playCommand.enabled = hasItem;
    commandCenter.pauseCommand.enabled = hasItem;
    commandCenter.togglePlayPauseCommand.enabled = hasItem;
    commandCenter.changePlaybackPositionCommand.enabled = hasItem;
    commandCenter.nextTrackCommand.enabled = (self.queue.count > 0);
    // iOS swaps the skip buttons for track buttons whenever previous or next is
    // enabled, so previous is only enabled when there is an earlier item.
    commandCenter.previousTrackCommand.enabled = (self.history.count > 0);
    commandCenter.skipForwardCommand.enabled = hasItem;
    commandCenter.skipBackwardCommand.enabled = hasItem;
}

- (void)updateNowPlayingInfo {
    MPNowPlayingInfoCenter *infoCenter = [MPNowPlayingInfoCenter defaultCenter];
    EZMediaPlayerItem *item = self.currentItem;
    if (!item) {
        infoCenter.nowPlayingInfo = nil;
        return;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = item.title;
    info[MPMediaItemPropertyArtist] = item.subtitle.length > 0 ? item.subtitle : @"EZCompleteUI";
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.currentTime);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.state == EZMediaPlayerStatePlaying ? item.playbackRate : 0.0);
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @(item.playbackRate);
    double length = self.duration;
    if (length > 0) info[MPMediaItemPropertyPlaybackDuration] = @(length);
    UIImage *artworkImage = item.artwork;
    if (artworkImage) {
        // The block is called by the system at whatever size it needs; the
        // stored cover is small and square, so returning it as-is is fine.
        info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc]
            initWithBoundsSize:artworkImage.size
                requestHandler:^UIImage * _Nonnull(CGSize size) { return artworkImage; }];
    }
    infoCenter.nowPlayingInfo = info;
}

@end
