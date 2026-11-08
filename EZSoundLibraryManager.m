//
//  EZSoundLibraryManager.m
//  EZSounds
//

#import "EZSoundLibraryManager.h"
#import <AVFoundation/AVFoundation.h>
#import "helpers.h"   // EZLog / EZLogf — already used project-wide

NSString * const EZSoundLibraryErrorDomain = @"EZSoundLibraryErrorDomain";

static NSString * const kEZLibraryFolderName = @"EZSounds";
static NSString * const kEZAudioFolderName   = @"Audio";
static NSString * const kEZCacheFolderName   = @"Cache";
static NSString * const kEZManifestFileName  = @"Manifest.json";
static NSInteger  const kEZManifestVersion   = 1;

static NSString * const kEZManifestKeyVersion = @"version";
static NSString * const kEZManifestKeyClips   = @"clips";

static NSError *EZSoundLibraryError(EZSoundLibraryErrorCode code, NSString *description) {
    return [NSError errorWithDomain:EZSoundLibraryErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: description}];
}

@interface EZSoundLibraryManager ()

// All manifest mutation and disk I/O happens serialized on this queue. Never touch
// _entries (the working copy) from any other queue.
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong) NSMutableArray<EZSoundManifestEntry *> *entries;

// A read-only, immutable copy of `entries`, refreshed under `snapshotLock` every time
// `entries` changes on ioQueue. Public read methods use this so they never have to hop
// onto ioQueue (and can safely be called from the main thread without risking a stall).
@property (nonatomic, strong) NSLock *snapshotLock;
@property (nonatomic, strong) NSArray<EZSoundManifestEntry *> *snapshot;

@property (nonatomic, strong) NSURL *libraryRootURL;
@property (nonatomic, strong) NSURL *audioDirectoryURL;
@property (nonatomic, strong) NSURL *cacheDirectoryURL;
@property (nonatomic, strong) NSURL *manifestFileURL;

@end

@implementation EZSoundLibraryManager

#pragma mark - Singleton / init

+ (instancetype)sharedManager {
    static EZSoundLibraryManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] initInternal];
    });
    return shared;
}

- (instancetype)initInternal {
    self = [super init];
    if (self) {
        _ioQueue = dispatch_queue_create("com.ez.soundlibrary.io", DISPATCH_QUEUE_SERIAL);
        _entries = [NSMutableArray array];
        _snapshotLock = [[NSLock alloc] init];
        _snapshot = @[];

        NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                                     inDomains:NSUserDomainMask].firstObject;
        NSAssert(documents != nil, @"Could not resolve Documents directory.");

        _libraryRootURL    = [documents URLByAppendingPathComponent:kEZLibraryFolderName isDirectory:YES];
        _audioDirectoryURL = [_libraryRootURL URLByAppendingPathComponent:kEZAudioFolderName isDirectory:YES];
        _cacheDirectoryURL = [_libraryRootURL URLByAppendingPathComponent:kEZCacheFolderName isDirectory:YES];
        _manifestFileURL   = [_libraryRootURL URLByAppendingPathComponent:kEZManifestFileName isDirectory:NO];

        NSError *setupError;
        if (![self ensureDirectoriesExistWithError:&setupError]) {
            EZLogf(EZLogLevelError, @"SoundLibrary", @"Failed to create library folders: %@", setupError.localizedDescription);
        }

        NSError *loadError;
        NSArray<EZSoundManifestEntry *> *loaded = [self loadOrCreateManifestWithError:&loadError];
        if (loaded) {
            [_entries addObjectsFromArray:loaded];
            [self refreshSnapshotLocked_NoLock:NO];
        } else {
            EZLogf(EZLogLevelError, @"SoundLibrary", @"Failed to load manifest: %@", loadError.localizedDescription);
        }

        EZLogf(EZLogLevelInfo, @"SoundLibrary", @"Ready at %@ (%lu sounds)", _libraryRootURL.path, (unsigned long)_entries.count);
    }
    return self;
}

#pragma mark - Folder setup

- (BOOL)ensureDirectoriesExistWithError:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSURL *url in @[self.libraryRootURL, self.audioDirectoryURL, self.cacheDirectoryURL]) {
        NSError *dirError;
        BOOL ok = [fm createDirectoryAtURL:url
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&dirError];
        if (!ok) {
            if (error) *error = EZSoundLibraryError(EZSoundLibraryErrorCodeFolderCreationFailed,
                [NSString stringWithFormat:@"Could not create %@: %@", url.path, dirError.localizedDescription]);
            return NO;
        }
    }
    return YES;
}

- (NSURL *)absoluteURLForEntry:(EZSoundManifestEntry *)entry {
    return [self.libraryRootURL URLByAppendingPathComponent:entry.relativePath isDirectory:NO];
}

#pragma mark - Manifest load / save (call only from ioQueue, except at init)

- (nullable NSArray<EZSoundManifestEntry *> *)loadOrCreateManifestWithError:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:self.manifestFileURL.path]) {
        // First launch: seed an empty manifest.
        if (![self persistEntriesToDisk:@[] error:error]) return nil;
        return @[];
    }

    NSData *data = [NSData dataWithContentsOfURL:self.manifestFileURL options:0 error:error];
    if (!data) return nil;

    NSError *jsonError;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (!json || ![json isKindOfClass:[NSDictionary class]]) {
        // Corrupt manifest: quarantine it rather than deleting, then start fresh so the
        // app never hard-fails on launch. The audio files on disk are untouched, only
        // the manifest index is reset.
        [self quarantineCorruptManifestFile];
        if (![self persistEntriesToDisk:@[] error:error]) return nil;
        EZLogf(EZLogLevelWarning, @"SoundLibrary", @"Manifest.json was corrupt (%@); quarantined and reset.", jsonError.localizedDescription);
        return @[];
    }

    NSDictionary *dict = (NSDictionary *)json;
    NSArray *clipsRaw = [dict[kEZManifestKeyClips] isKindOfClass:[NSArray class]] ? dict[kEZManifestKeyClips] : @[];

    NSMutableArray<EZSoundManifestEntry *> *result = [NSMutableArray arrayWithCapacity:clipsRaw.count];
    for (id clipDict in clipsRaw) {
        if (![clipDict isKindOfClass:[NSDictionary class]]) continue;
        NSError *entryError;
        EZSoundManifestEntry *entry = [EZSoundManifestEntry entryWithDictionary:clipDict error:&entryError];
        if (entry) {
            [result addObject:entry];
        } else {
            // Skip malformed individual rows rather than failing the whole manifest.
            EZLogf(EZLogLevelWarning, @"SoundLibrary", @"Skipping malformed manifest entry: %@", entryError.localizedDescription);
        }
    }
    return result;
}

- (void)quarantineCorruptManifestFile {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    NSString *quarantineName = [NSString stringWithFormat:@"Manifest.corrupt.%@.json", stamp];
    NSURL *quarantineURL = [self.libraryRootURL URLByAppendingPathComponent:quarantineName isDirectory:NO];
    [fm moveItemAtURL:self.manifestFileURL toURL:quarantineURL error:nil];
}

/// Atomically writes `entries` to Manifest.json. NSDataWritingAtomic writes to a temp
/// file and renames over the destination, so a crash/power-loss mid-write can never
/// leave a half-written, corrupt Manifest.json on disk.
- (BOOL)persistEntriesToDisk:(NSArray<EZSoundManifestEntry *> *)entries error:(NSError **)error {
    NSMutableArray<NSDictionary *> *clipDicts = [NSMutableArray arrayWithCapacity:entries.count];
    for (EZSoundManifestEntry *entry in entries) {
        [clipDicts addObject:[entry dictionaryRepresentation]];
    }
    NSDictionary *manifestDict = @{
        kEZManifestKeyVersion: @(kEZManifestVersion),
        kEZManifestKeyClips: clipDicts
    };

    if (![NSJSONSerialization isValidJSONObject:manifestDict]) {
        if (error) *error = EZSoundLibraryError(EZSoundLibraryErrorCodeWriteFailed, @"Manifest contains non-JSON-safe data.");
        return NO;
    }

    NSError *serializeError;
    NSData *data = [NSJSONSerialization dataWithJSONObject:manifestDict options:NSJSONWritingPrettyPrinted error:&serializeError];
    if (!data) {
        if (error) *error = EZSoundLibraryError(EZSoundLibraryErrorCodeWriteFailed,
            [NSString stringWithFormat:@"Could not serialize manifest: %@", serializeError.localizedDescription]);
        return NO;
    }

    NSError *writeError;
    BOOL ok = [data writeToURL:self.manifestFileURL options:NSDataWritingAtomic error:&writeError];
    if (!ok) {
        if (error) *error = EZSoundLibraryError(EZSoundLibraryErrorCodeWriteFailed,
            [NSString stringWithFormat:@"Could not write manifest: %@", writeError.localizedDescription]);
        return NO;
    }
    return YES;
}

#pragma mark - Snapshot (thread-safe reads)

/// Call from ioQueue after mutating `_entries`. Pass NO for `lock` only during -init,
/// before any other thread could possibly be touching `snapshot`.
- (void)refreshSnapshotLocked_NoLock:(BOOL)lock {
    NSArray<EZSoundManifestEntry *> *copy = [self.entries copy];
    if (lock) [self.snapshotLock lock];
    self.snapshot = copy;
    if (lock) [self.snapshotLock unlock];
}

- (NSArray<EZSoundManifestEntry *> *)currentSnapshot {
    [self.snapshotLock lock];
    NSArray<EZSoundManifestEntry *> *copy = self.snapshot;
    [self.snapshotLock unlock];
    return copy;
}

#pragma mark - Reading (public, any thread)

- (NSArray<EZSoundManifestEntry *> *)allSoundsSortedByDateDescending {
    NSArray<EZSoundManifestEntry *> *snapshot = [self currentSnapshot];
    return [snapshot sortedArrayUsingComparator:^NSComparisonResult(EZSoundManifestEntry *a, EZSoundManifestEntry *b) {
        return [b.created compare:a.created]; // newest first
    }];
}

- (nullable EZSoundManifestEntry *)soundWithUUID:(NSString *)uuid {
    if (uuid.length == 0) return nil;
    for (EZSoundManifestEntry *entry in [self currentSnapshot]) {
        if ([entry.uuid isEqualToString:uuid]) return entry;
    }
    return nil;
}

#pragma mark - Save

- (void)saveAudioData:(NSData *)audioData
                prompt:(NSString *)prompt
              provider:(NSString *)provider
                 model:(nullable NSString *)model
             extension:(NSString *)extension
              metadata:(nullable NSDictionary<NSString *, id> *)metadata
            completion:(void (^)(EZSoundManifestEntry * _Nullable, NSError * _Nullable))completion
{
    if (audioData.length == 0 || prompt.length == 0 || provider.length == 0 || extension.length == 0) {
        NSError *err = EZSoundLibraryError(EZSoundLibraryErrorCodeInvalidArgument,
            @"audioData, prompt, provider, and extension are all required.");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
        return;
    }

    dispatch_async(self.ioQueue, ^{
        NSError *dirError;
        if (![self ensureDirectoriesExistWithError:&dirError]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, dirError); });
            return;
        }

        NSString *stamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
        NSString *unique = [[[NSUUID UUID] UUIDString] substringToIndex:8];
        NSString *filename = [NSString stringWithFormat:@"sound_%@_%@.%@", stamp, unique, extension];
        NSString *relativePath = [kEZAudioFolderName stringByAppendingPathComponent:filename];
        NSURL *fileURL = [self.libraryRootURL URLByAppendingPathComponent:relativePath isDirectory:NO];

        NSError *writeError;
        if (![audioData writeToURL:fileURL options:NSDataWritingAtomic error:&writeError]) {
            NSError *err = EZSoundLibraryError(EZSoundLibraryErrorCodeWriteFailed,
                [NSString stringWithFormat:@"Could not write audio file: %@", writeError.localizedDescription]);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
            return;
        }

        // Measure the saved file. A measurement failure doesn't fail the save —
        // the sound is playable regardless; duration/sample rate are display data.
        double duration = 0, sampleRate = 0;
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:nil];
        if (CMTIME_IS_NUMERIC(asset.duration)) duration = CMTimeGetSeconds(asset.duration);
        AVAudioFile *audioFile = [[AVAudioFile alloc] initForReading:fileURL error:nil];
        if (audioFile) {
            sampleRate = audioFile.fileFormat.sampleRate;
            if (duration <= 0 && audioFile.fileFormat.sampleRate > 0) {
                duration = (double)audioFile.length / audioFile.fileFormat.sampleRate;
            }
        }
        unsigned long long fileSize = (unsigned long long)audioData.length;

        EZSoundManifestEntry *entry = [EZSoundManifestEntry entryWithProvider:provider
                                                                         model:model
                                                                        prompt:prompt
                                                                      filename:filename
                                                                  relativePath:relativePath
                                                                      duration:duration
                                                                    sampleRate:sampleRate
                                                                      fileSize:fileSize];
        if (metadata.count) {
            NSMutableDictionary *merged = [entry.metadata mutableCopy];
            [merged addEntriesFromDictionary:metadata];
            entry.metadata = merged;
        }

        [self.entries insertObject:entry atIndex:0];
        NSError *persistError;
        if (![self persistEntriesToDisk:self.entries error:&persistError]) {
            [self.entries removeObject:entry];
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, persistError); });
            return;
        }
        [self refreshSnapshotLocked_NoLock:YES];
        EZLogf(EZLogLevelInfo, @"SoundLibrary", @"Saved sound %@ (%.1fs, %llu bytes)", entry.uuid, duration, fileSize);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(entry, nil); });
    });
}

#pragma mark - Mutation

- (void)deleteSoundWithUUID:(NSString *)uuid
                  completion:(nullable void (^)(BOOL, NSError * _Nullable))completion
{
    dispatch_async(self.ioQueue, ^{
        EZSoundManifestEntry *target = nil;
        for (EZSoundManifestEntry *entry in self.entries) {
            if ([entry.uuid isEqualToString:uuid]) { target = entry; break; }
        }
        if (!target) {
            NSError *err = EZSoundLibraryError(EZSoundLibraryErrorCodeSoundNotFound, @"No sound with that id.");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, err); });
            return;
        }
        NSURL *fileURL = [self absoluteURLForEntry:target];
        [self.entries removeObject:target];
        NSError *persistError;
        if (![self persistEntriesToDisk:self.entries error:&persistError]) {
            [self.entries addObject:target];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, persistError); });
            return;
        }
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
        [self refreshSnapshotLocked_NoLock:YES];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
    });
}

- (void)setFavorite:(BOOL)favorite
       forSoundUUID:(NSString *)uuid
         completion:(nullable void (^)(EZSoundManifestEntry * _Nullable, NSError * _Nullable))completion
{
    dispatch_async(self.ioQueue, ^{
        EZSoundManifestEntry *target = nil;
        for (EZSoundManifestEntry *entry in self.entries) {
            if ([entry.uuid isEqualToString:uuid]) { target = entry; break; }
        }
        if (!target) {
            NSError *err = EZSoundLibraryError(EZSoundLibraryErrorCodeSoundNotFound, @"No sound with that id.");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
            return;
        }
        target.favorite = favorite;
        NSError *persistError;
        if (![self persistEntriesToDisk:self.entries error:&persistError]) {
            target.favorite = !favorite;
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, persistError); });
            return;
        }
        [self refreshSnapshotLocked_NoLock:YES];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(target, nil); });
    });
}

#pragma mark - Export

- (nullable NSURL *)exportURLForSoundWithUUID:(NSString *)uuid {
    EZSoundManifestEntry *entry = [self soundWithUUID:uuid];
    if (!entry) return nil;
    NSURL *url = [self absoluteURLForEntry:entry];
    return [[NSFileManager defaultManager] fileExistsAtPath:url.path] ? url : nil;
}

@end
