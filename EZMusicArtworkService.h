// EZMusicArtworkService.h
// EZCompleteUI v1.1
//
// Purpose:
//   Creates and stores cover art for AI songs. When a new song has been saved
//   on the device, the library manager calls -generateArtworkIfNeededForEntry:.
//   This service then:
//     1. Builds an image prompt from the song's title and lyrics (or from the
//        style description when the song is instrumental).
//     2. Sends it to the ez-image Edge Function with the cheapest, fastest image
//        model (gpt-image-1-mini, low quality, square). ez-image does all the
//        pricing and coin charging; this class never decides a price itself.
//     3. Downloads the result, shrinks it to a small JPEG and keeps it in the
//        music library folder (EZMusic/Artwork/<entryID>.jpg).
//     4. Posts EZMusicArtworkDidUpdateNotification so any visible song row,
//        the chat song card or the lock-screen entry can pick the picture up.
//
//   Everything is best effort. A song never waits on its cover and never fails
//   because of it: no coins, no network or a moderation refusal just means the
//   song has no cover art (the UI shows a music-note placeholder).
//
//   Only songs that finish saving AFTER this feature ships get art. Existing
//   songs are not back-filled automatically, because that would spend the
//   user's coins without them asking.
//
//   Songs can also get a new cover on request (-regenerateArtworkForEntry:...),
//   which the AI Music library uses for its double-tap-the-cover gesture. That
//   path works for any finished song, including ones from before covers
//   existed, and keeps the old cover until the new one is ready.
//
//   Turning it off: set the NSUserDefaults bool "musicAutoArtworkDisabled" to
//   YES (a Settings switch can write this key).
//
// Changes from v1.0:
//   - Added -regenerateArtworkForEntry:completion:.
//
//   Threading: call from any thread. Notifications are posted on the main queue.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when a song's artwork has been saved. userInfo has
/// the song's entry ID under EZMusicArtworkEntryIDKey.
extern NSNotificationName const EZMusicArtworkDidUpdateNotification;
extern NSString * const EZMusicArtworkEntryIDKey;

@interface EZMusicArtworkService : NSObject

+ (instancetype)sharedService;
- (instancetype)init NS_UNAVAILABLE;

/// The saved cover for a song, or nil if it has none (yet). Cheap to call from
/// table-view cell configuration; decoded images are cached in memory.
- (nullable UIImage *)cachedArtworkForEntryID:(NSString *)entryID;

/// Starts generating a cover for a freshly saved song unless it already has one
/// (or is already being made, or failed in a way retrying won't fix). `entry`
/// is the music service's song dictionary: it needs "id" and should have
/// "title", "lyrics" and "prompt".
- (void)generateArtworkIfNeededForEntry:(NSDictionary *)entry;

/// Makes a brand-new cover for a finished song, replacing any existing one once
/// the new picture is saved (the old one stays visible until then). Unlike the
/// automatic path this ignores the "auto artwork" setting, earlier failures and
/// the once-per-launch limit, because the user asked for it. Costs coins the
/// same way (charged by ez-image). `completion` runs once on the main queue:
/// YES on success, otherwise NO and a short message fit to show the user. If a
/// cover for this song is already being made, `completion` gets NO right away.
- (void)regenerateArtworkForEntry:(NSDictionary *)entry
                       completion:(void (^)(BOOL success, NSString * _Nullable errorMessage))completion;

/// YES while a cover is being generated for this song (automatic or requested).
- (BOOL)isGeneratingArtworkForEntryID:(NSString *)entryID;

/// Deletes a song's cover (call when the song itself is deleted).
- (void)removeArtworkForEntryID:(NSString *)entryID;

@end

NS_ASSUME_NONNULL_END
