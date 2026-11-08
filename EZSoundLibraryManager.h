//
//  EZSoundLibraryManager.h
//  EZSounds
//
//  Singleton that owns Documents/EZSounds/: the audio files, a cache folder,
//  and Manifest.json. Modeled on EZTTSLibraryManager — every generated sound
//  is archived here via -saveAudioData:... regardless of whether the user
//  ever taps Play or Share.
//
//  Thread safety: all mutations (save/delete/favorite) are serialized onto a
//  private background queue and persisted to disk atomically. Reads are safe
//  from any thread and return an immediate in-memory snapshot.
//

#import <Foundation/Foundation.h>
#import "EZSoundManifestEntry.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const EZSoundLibraryErrorDomain;

typedef NS_ENUM(NSInteger, EZSoundLibraryErrorCode) {
    EZSoundLibraryErrorCodeFolderCreationFailed = 1,
    EZSoundLibraryErrorCodeWriteFailed          = 2,
    EZSoundLibraryErrorCodeManifestCorrupt      = 3,
    EZSoundLibraryErrorCodeSoundNotFound        = 4,
    EZSoundLibraryErrorCodeAudioAnalysisFailed  = 5,
    EZSoundLibraryErrorCodeInvalidArgument      = 6,
};

@interface EZSoundLibraryManager : NSObject

/// Shared instance. Creates EZSounds/'s folder structure and loads (or creates)
/// Manifest.json on first access.
+ (instancetype)sharedManager;

- (instancetype)init NS_UNAVAILABLE;

#pragma mark - Paths

/// Documents/EZSounds/
@property (nonatomic, readonly) NSURL *libraryRootURL;
/// Documents/EZSounds/Audio/
@property (nonatomic, readonly) NSURL *audioDirectoryURL;
/// Documents/EZSounds/Cache/ — scratch/derived files (e.g. video exports).
@property (nonatomic, readonly) NSURL *cacheDirectoryURL;

/// Absolute file URL for a given entry, i.e. libraryRootURL + entry.relativePath.
- (NSURL *)absoluteURLForEntry:(EZSoundManifestEntry *)entry;

#pragma mark - Save (the primary archiving entry point)

/// Archives a successful generation: writes the audio to disk, measures
/// duration/sample rate/file size via AVFoundation, creates the manifest
/// entry, and persists the updated manifest — then hands back the saved
/// entry. `completion` is always called on the main queue.
- (void)saveAudioData:(NSData *)audioData
                prompt:(NSString *)prompt
              provider:(NSString *)provider
                 model:(nullable NSString *)model
             extension:(NSString *)extension
              metadata:(nullable NSDictionary<NSString *, id> *)metadata
            completion:(void (^)(EZSoundManifestEntry * _Nullable entry, NSError * _Nullable error))completion;

#pragma mark - Reading

/// All sounds, newest first. Safe to call from any thread; returns an immediate snapshot.
- (NSArray<EZSoundManifestEntry *> *)allSoundsSortedByDateDescending;

/// nil if no sound with that uuid exists.
- (nullable EZSoundManifestEntry *)soundWithUUID:(NSString *)uuid;

#pragma mark - Mutation

/// Deletes both the audio file on disk and its manifest entry. `completion` is
/// called on the main queue; error is EZSoundLibraryErrorCodeSoundNotFound if
/// the uuid is unknown.
- (void)deleteSoundWithUUID:(NSString *)uuid
                  completion:(nullable void (^)(BOOL success, NSError * _Nullable error))completion;

/// Sets or clears the favorite flag on a sound.
- (void)setFavorite:(BOOL)favorite
       forSoundUUID:(NSString *)uuid
         completion:(nullable void (^)(EZSoundManifestEntry * _Nullable entry, NSError * _Nullable error))completion;

#pragma mark - Export

/// Absolute file URL suitable for handing directly to UIActivityViewController,
/// or nil if the uuid is unknown or the file is missing on disk.
- (nullable NSURL *)exportURLForSoundWithUUID:(NSString *)uuid;

@end

NS_ASSUME_NONNULL_END
