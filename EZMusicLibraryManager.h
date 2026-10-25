// EZMusicLibraryManager.h
// EZCompleteUI v1.1
//
// Purpose:
//   Owns the on-device copy of generated songs: Documents/EZMusic/Songs holds
//   the MP3 files, Documents/EZMusic/References holds audio the user supplied
//   as a style/source reference, and Manifest.json records what is stored.
//   Anything that needs a song to play offline, share, or show in a local
//   playlist asks this class instead of touching the file system itself.
//
//   Songs are created on the server by the ez-music Edge Function (see
//   EZMusicService). This class only keeps the downloaded audio and the small
//   amount of metadata (title, prompt, lyrics, length) that goes with it.
//
// Changes from v1.0:
//   - Added -retainSongFromRemoteURL:entry:completion: so the AI Music screen
//     and the chat music card share a single "download a finished song and
//     keep it on the device" implementation. Two callers asking for the same
//     song at the same time share one download.
//   - Added this header comment.
//
// v1.0:
//   - Initial version.

#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface EZMusicLibraryManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, readonly) NSURL *libraryRootURL;
- (nullable NSURL *)localSongURLForEntryID:(NSString *)entryID;
/// Entry IDs in the on-device song manifest, in archive order. This is the
/// offline playlist source; references are deliberately excluded.
- (NSArray<NSString *> *)localSongEntryIDs;
/// How many songs this user has ever ended up with on this device. Counted
/// when a finished song is first archived, persisted across launches, and
/// seeded from the on-device library so songs made before this counter
/// existed still count. Backs the one-free-song paywall: song creation is
/// free until this reaches 1 for a user who has never purchased.
@property (nonatomic, readonly) NSInteger createdSongCount;
/// Refreshes local metadata for an already archived song without copying audio again.
- (void)updateSongMetadataForEntry:(NSDictionary *)entry;
- (void)archiveSongAtTemporaryURL:(NSURL *)temporaryURL entry:(NSDictionary *)entry;
- (void)archiveSongAtTemporaryURL:(NSURL *)temporaryURL
                            entry:(NSDictionary *)entry
                       completion:(void (^ _Nullable)(NSURL * _Nullable localURL,
                                                      NSError * _Nullable error))completion;
/// Downloads a finished song from a signed URL (see
/// -[EZMusicService fetchPlaybackURLForEntryID:forDownload:completion:]) and
/// archives it. If the song is already on the device, completes right away
/// with the local file. Concurrent calls for the same entry share one
/// download and all receive the result. `entry` is the server row (it must
/// contain "id"). The completion always runs on the main queue.
- (void)retainSongFromRemoteURL:(NSURL *)remoteURL
                          entry:(NSDictionary *)entry
                     completion:(void (^ _Nullable)(NSURL * _Nullable localURL,
                                                    NSError * _Nullable error))completion;
- (void)archiveReferenceAtURL:(NSURL *)sourceURL sourceName:(NSString *)sourceName mode:(NSString *)mode;
@end
NS_ASSUME_NONNULL_END
