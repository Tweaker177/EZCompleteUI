//
//  EZTTSLibraryManager.h
//  EZTTSLibrary
//
//  Singleton that owns Documents/TTSLibrary/: the audio files, the waveform/cache
//  folders (reserved for future use), and Manifest.json. Every successful TTS
//  generation should be archived here via -saveAudioData:... regardless of whether
//  the user ever taps Play or Export in the UI.
//
//  Thread safety: all mutations (save/delete/rename/favorite) are serialized onto a
//  private background queue and persisted to disk atomically. Reads (allClips...,
//  clipWithUUID:, searchClipsWithQuery:) are safe to call from any thread, including
//  the main thread, and return an immediate in-memory snapshot.
//

#import <Foundation/Foundation.h>
#import "EZTTSManifestEntry.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const EZTTSLibraryErrorDomain;

typedef NS_ENUM(NSInteger, EZTTSLibraryErrorCode) {
    EZTTSLibraryErrorCodeFolderCreationFailed = 1,
    EZTTSLibraryErrorCodeWriteFailed          = 2,
    EZTTSLibraryErrorCodeManifestCorrupt      = 3,
    EZTTSLibraryErrorCodeClipNotFound         = 4,
    EZTTSLibraryErrorCodeAudioAnalysisFailed  = 5,
    EZTTSLibraryErrorCodeInvalidArgument      = 6,
};

@interface EZTTSLibraryManager : NSObject

/// Shared instance. Creates TTSLibrary/'s folder structure and loads (or creates)
/// Manifest.json on first access.
+ (instancetype)sharedManager;

- (instancetype)init NS_UNAVAILABLE;

#pragma mark - Paths

/// Documents/TTSLibrary/
@property (nonatomic, readonly) NSURL *libraryRootURL;
/// Documents/TTSLibrary/Audio/
@property (nonatomic, readonly) NSURL *audioDirectoryURL;
/// Documents/TTSLibrary/Waveforms/ — reserved for a future waveform PNG/data cache.
@property (nonatomic, readonly) NSURL *waveformsDirectoryURL;
/// Documents/TTSLibrary/Cache/ — reserved for scratch/derived files (e.g. transcoded exports).
@property (nonatomic, readonly) NSURL *cacheDirectoryURL;

/// Absolute file URL for a given entry, i.e. libraryRootURL + entry.relativePath.
- (NSURL *)absoluteURLForEntry:(EZTTSManifestEntry *)entry;

#pragma mark - Save (the primary archiving entry point)

/// Archives a successful TTS generation: writes the audio to disk, measures duration/
/// sample rate/file size via AVFoundation, creates the manifest entry, and persists the
/// updated manifest — then hands back the saved entry. This is the ONE call a view
/// controller should make after a successful generation; no other file-writing or
/// manifest logic should live outside this class.
///
/// `completion` is always called on the main queue.
- (void)saveAudioData:(NSData *)audioData
                prompt:(NSString *)prompt
             voiceName:(nullable NSString *)voiceName
               voiceID:(nullable NSString *)voiceID
              provider:(NSString *)provider
                 model:(nullable NSString *)model
             extension:(NSString *)extension
            completion:(void (^)(EZTTSManifestEntry * _Nullable entry, NSError * _Nullable error))completion;

/// Same as the primary save method, with JSON-safe metadata attached atomically to
/// the new manifest entry. Scene clips use this to retain links to their dry voice
/// and background assets for later re-mixing.
- (void)saveAudioData:(NSData *)audioData
                prompt:(NSString *)prompt
             voiceName:(nullable NSString *)voiceName
               voiceID:(nullable NSString *)voiceID
              provider:(NSString *)provider
                 model:(nullable NSString *)model
             extension:(NSString *)extension
              metadata:(nullable NSDictionary<NSString *, id> *)metadata
            completion:(void (^)(EZTTSManifestEntry * _Nullable entry, NSError * _Nullable error))completion;

#pragma mark - Reading

/// All clips, newest first. Safe to call from any thread; returns an immediate snapshot.
- (NSArray<EZTTSManifestEntry *> *)allClipsSortedByDateDescending;

/// nil if no clip with that uuid exists.
- (nullable EZTTSManifestEntry *)clipWithUUID:(NSString *)uuid;

/// Case-insensitive substring search across voiceName, voiceID, prompt, tags, and provider.
/// Passing nil or an empty string returns all clips (same as -allClipsSortedByDateDescending).
- (NSArray<EZTTSManifestEntry *> *)searchClipsWithQuery:(nullable NSString *)query;

#pragma mark - Mutation

/// Deletes both the audio file on disk and its manifest entry. `completion` is called
/// on the main queue; error is EZTTSLibraryErrorCodeClipNotFound if the uuid is unknown.
- (void)deleteClipWithUUID:(NSString *)uuid
                 completion:(nullable void (^)(BOOL success, NSError * _Nullable error))completion;

/// Sets a user-facing display title on the clip without touching the underlying audio
/// filename (the filename/relativePath are structural and never change after save).
/// UI should prefer entry.metadata[@"title"], falling back to entry.preview, when
/// displaying a clip's name.
- (void)renameClipWithUUID:(NSString *)uuid
                      title:(NSString *)title
                 completion:(nullable void (^)(EZTTSManifestEntry * _Nullable entry, NSError * _Nullable error))completion;

- (void)favoriteClipWithUUID:(NSString *)uuid
                   completion:(nullable void (^)(EZTTSManifestEntry * _Nullable entry, NSError * _Nullable error))completion;

- (void)unfavoriteClipWithUUID:(NSString *)uuid
                     completion:(nullable void (^)(EZTTSManifestEntry * _Nullable entry, NSError * _Nullable error))completion;

/// Stores a manual playback-rate override (e.g. 0.5–2.0) in the clip's metadata. This
/// changes only how the clip is *played back* — the archived audio file itself is never
/// touched or regenerated. Pass 1.0 to clear back to normal speed.
- (void)setPlaybackRate:(float)rate
             forClipUUID:(NSString *)uuid
              completion:(nullable void (^)(EZTTSManifestEntry * _Nullable entry, NSError * _Nullable error))completion;

/// Persists the bed level for a scene clip after its two original layers have been
/// re-mixed into the clip's existing History entry.
- (void)setSceneBackgroundLevel:(float)level
                   forClipUUID:(NSString *)uuid
                     completion:(nullable void (^)(EZTTSManifestEntry * _Nullable entry, NSError * _Nullable error))completion;

/// Replaces a clip's underlying audio file in place — same uuid, same position in
/// History, same favorite/tags/metadata — only the audio bytes, duration, sample rate,
/// and file size change. Use this for non-destructive enhancements (e.g. normalizing a
/// clip that's already too quiet) where there's no real reason to keep the original
/// around as a separate clip. The old audio file is deleted once the new one is safely
/// written and the manifest is updated; if anything fails partway, the clip is left
/// exactly as it was.
- (void)replaceAudioForClipUUID:(NSString *)uuid
                        withData:(NSData *)audioData
                       extension:(NSString *)extension
                      completion:(nullable void (^)(EZTTSManifestEntry * _Nullable entry, NSError * _Nullable error))completion;

#pragma mark - Export

/// Absolute file URL suitable for handing directly to UIActivityViewController, or nil
/// if the uuid is unknown or the file is missing on disk.
- (nullable NSURL *)exportURLForClipWithUUID:(NSString *)uuid;

@end

NS_ASSUME_NONNULL_END
