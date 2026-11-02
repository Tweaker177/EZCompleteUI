// EZMediaPlayerManager.h
// EZCompleteUI v1.3
//
// Purpose:
//   The app's single, shared audio player. Anything that wants to play a
//   finished audio file (today: songs from chat; planned: text-to-speech clips
//   and the AI Music library) hands it an EZMediaPlayerItem instead of making
//   its own AVPlayer. That gives the whole app one source of truth for "what is
//   playing right now", which is what makes these work:
//
//     - Playback keeps going when the screen that started it goes away. The
//       player is owned by this singleton, not by a view controller.
//     - Only one thing plays at a time. Starting a new item replaces the
//       current one.
//     - Background audio, lock-screen / Control Center controls (play, pause,
//       next, scrub bar) and the title shown there are handled once, here.
//     - Interruptions (phone call, Siri) pause playback and resume it when the
//       system says to; unplugging headphones pauses it.
//     - An "Up Next" list. When an item finishes, the next one starts.
//
//   Views never talk to AVPlayer. They read the properties below and listen for
//   EZMediaPlayerDidUpdateNotification, which is posted whenever the state
//   changes and about four times a second while something plays (for progress
//   bars). Use -isCurrentItemWithIdentifier: to find out whether a given row is
//   the one playing.
//
//   Threading: call everything from the main queue. Notifications are posted
//   on the main queue.
//
//   Who uses it today: song cards in chat, the AI Music screen, the Text to
//   Speech screen and the Text to Speech History list. The only other audio
//   player left in the app is the clip editor's short preview, which stops
//   this one before it starts.
//
// Changes from v1.0:
//   - Items can carry a playback speed (Text to Speech clips remember one).
//   - Added skip forward / back by a number of seconds and "previous" (restart
//     the item, or go back to the one that played before it). The lock screen
//     shows skip +/-15s for a single clip and previous/next once there is a
//     list to move through.
//
// Changes from v1.2:
//   - Added -replaceUpNext: and -removeItemWithIdentifier:.
//   - Removed EZMediaPlayerWillStartNotification: it existed only so screens
//     with their own players could stop themselves, and none are left.
//
// Changes from v1.1:
//   - Items can carry cover art, shown on the lock screen / Control Center.
//     Songs get theirs a little after they finish, so the player also picks it
//     up by itself when EZMusicArtworkService finishes a cover for the song
//     that is playing.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when playback state, the current item, Up Next or the duration
/// changes, and repeatedly while playing so progress UI can follow along.
extern NSNotificationName const EZMediaPlayerDidUpdateNotification;

typedef NS_ENUM(NSInteger, EZMediaPlayerState) {
    EZMediaPlayerStateIdle = 0,   // Nothing loaded.
    EZMediaPlayerStateLoading,    // An item is loading or buffering.
    EZMediaPlayerStatePlaying,
    EZMediaPlayerStatePaused,     // Includes "finished", rewound to the start.
    EZMediaPlayerStateFailed,     // See -errorMessage.
};

/// One playable thing. Immutable.
@interface EZMediaPlayerItem : NSObject
/// Unique and stable for the same content (for example a song's entry ID), so
/// every view can tell whether it is the item that is playing.
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *title;
/// Second line on the lock screen, for example "🔊EZCompleteUI🔊". Optional.
@property (nonatomic, copy, readonly, nullable) NSString *subtitle;
/// A file on this device or a remote URL AVPlayer can stream.
@property (nonatomic, strong, readonly) NSURL *fileURL;
/// Length in seconds if already known (shown before the file has loaded), or 0.
@property (nonatomic, readonly) NSTimeInterval durationHint;

+ (instancetype)itemWithIdentifier:(NSString *)identifier
                             title:(NSString *)title
                          subtitle:(nullable NSString *)subtitle
                           fileURL:(NSURL *)fileURL
                      durationHint:(NSTimeInterval)durationHint;

/// Speed the item plays at (1.0 = normal). Pitch is preserved.
@property (nonatomic, readonly) float playbackRate;

/// Cover picture for the lock screen. Optional; the player fills it in later
/// for songs whose cover arrives after playback started.
@property (nonatomic, strong, nullable) UIImage *artwork;

+ (instancetype)itemWithIdentifier:(NSString *)identifier
                             title:(NSString *)title
                          subtitle:(nullable NSString *)subtitle
                           fileURL:(NSURL *)fileURL
                      durationHint:(NSTimeInterval)durationHint
                      playbackRate:(float)playbackRate;
@end

@interface EZMediaPlayerManager : NSObject

+ (instancetype)sharedManager;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) EZMediaPlayerState state;
@property (nonatomic, strong, readonly, nullable) EZMediaPlayerItem *currentItem;
/// Items that will play after the current one, in order.
@property (nonatomic, copy, readonly) NSArray<EZMediaPlayerItem *> *upNext;
/// Seconds played in the current item (0 when nothing is loaded).
@property (nonatomic, readonly) NSTimeInterval currentTime;
/// Length of the current item in seconds. Falls back to the item's
/// durationHint until the file reports its real length. 0 if unknown.
@property (nonatomic, readonly) NSTimeInterval duration;
/// Plain-language reason for EZMediaPlayerStateFailed, otherwise nil.
@property (nonatomic, copy, readonly, nullable) NSString *errorMessage;

/// YES if `identifier` is the item that is loaded right now (whether it is
/// playing, paused or failed).
- (BOOL)isCurrentItemWithIdentifier:(NSString *)identifier;

/// Starts `item` right away, replacing whatever is playing. Up Next is kept.
- (void)playItem:(EZMediaPlayerItem *)item;

/// Adds `item` to the end of Up Next. If nothing is loaded, it starts at once.
/// An item that is already the current one or already queued is ignored.
- (void)enqueueItem:(EZMediaPlayerItem *)item;

/// Pause if playing or loading, otherwise resume. No effect when idle or failed.
- (void)togglePlayPause;
- (void)pause;
- (void)resume;

/// Jumps to a position in the current item. `fraction` is clamped to 0...1.
- (void)seekToFraction:(double)fraction;

/// Moves `seconds` forward (positive) or back (negative) in the current item.
/// Going back past the start lands on 0; going forward past the end counts as
/// finishing the item (the next one starts, or playback ends).
- (void)skipBySeconds:(NSTimeInterval)seconds;

/// Replaces the whole Up Next list. The current item and duplicates are left out.
- (void)replaceUpNext:(NSArray<EZMediaPlayerItem *> *)items;

/// Takes an item out of Up Next and the "previous" history (for example when
/// its file was deleted). If it is the current item, moves on to the next one
/// or, when nothing is queued, stops and releases the audio session.
- (void)removeItemWithIdentifier:(NSString *)identifier;

/// Skips to the first item in Up Next. If Up Next is empty, stops.
- (void)playNext;

/// Restarts the current item if it has played for more than a few seconds (or
/// nothing came before it); otherwise goes back to the item that played before.
/// The item that was playing returns to the front of Up Next.
- (void)playPrevious;

/// Removes the current item and Up Next and clears the lock-screen entry. Does
/// not change the audio session (callers that are about to play something
/// else will set it themselves).
- (void)stop;

/// "1:05" style text for a number of seconds (used by the song card).
+ (NSString *)formattedTime:(NSTimeInterval)seconds;

@end

NS_ASSUME_NONNULL_END
