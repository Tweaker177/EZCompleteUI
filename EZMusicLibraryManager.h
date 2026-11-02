// EZMusicLibraryManager.h
// EZCompleteUI v1.2
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
// Changes from v1.1:
//   - Added -localSongRecordForEntryID: (saved title/prompt/lyrics of a song).
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

/// The saved details of a song kept on this device (title, prompt, lyrics, ...),
/// or nil if it isn't saved here. The lyrics are only known to the app if they
/// were saved with the song, which is why callers that need them ask here.
- (nullable NSDictionary *)localSongRecordForEntryID:(NSString *)entryID;
/// Remembers the lyrics submitted for a generation, keyed by generation_id,
/// so they can be saved with the song when it is archived — even when the
/// server's entry for the song doesn't carry them. Empty lyrics note nothing.
- (void)noteLyrics:(NSString *)lyrics forGenerationID:(NSString *)generationID;
/// The best lyrics known for an entry: the entry's own, then the saved
/// record's, then any noted at generation time. @"" when none are known.
- (NSString *)lyricsForEntry:(NSDictionary *)entry;
/// Entry IDs in the on-device song manifest, in archive order. This is the
/// offline playlist source; references are deliberately excluded.
- (NSArray<NSString *> *)localSongEntryIDs;
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
