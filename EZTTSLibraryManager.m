//
//  EZTTSLibraryManager.m
//  EZTTSLibrary
//

#import "EZTTSLibraryManager.h"
#import <AVFoundation/AVFoundation.h>
#import "helpers.h"   // EZLog / EZLogf — already used project-wide

NSString * const EZTTSLibraryErrorDomain = @"EZTTSLibraryErrorDomain";

static NSString * const kEZLibraryFolderName   = @"TTSLibrary";
static NSString * const kEZAudioFolderName     = @"Audio";
static NSString * const kEZWaveformsFolderName = @"Waveforms";
static NSString * const kEZCacheFolderName     = @"Cache";
static NSString * const kEZManifestFileName    = @"Manifest.json";
static NSInteger  const kEZManifestVersion     = 1;

static NSString * const kEZManifestKeyVersion  = @"version";
static NSString * const kEZManifestKeyClips    = @"clips";

static NSError *EZLibraryError(EZTTSLibraryErrorCode code, NSString *description) {
    return [NSError errorWithDomain:EZTTSLibraryErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: description}];
}

@interface EZTTSLibraryManager ()

// All manifest mutation and disk I/O happens serialized on this queue. Never touch
// _entries (the working copy) from any other queue.
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong) NSMutableArray<EZTTSManifestEntry *> *entries;

// A read-only, immutable copy of `entries`, refreshed under `snapshotLock` every time
// `entries` changes on ioQueue. Public read methods use this so they never have to hop
// onto ioQueue (and can safely be called from the main thread without risking a stall).
@property (nonatomic, strong) NSLock *snapshotLock;
@property (nonatomic, strong) NSArray<EZTTSManifestEntry *> *snapshot;

@property (nonatomic, strong) NSURL *libraryRootURL;
@property (nonatomic, strong) NSURL *audioDirectoryURL;
@property (nonatomic, strong) NSURL *waveformsDirectoryURL;
@property (nonatomic, strong) NSURL *cacheDirectoryURL;
@property (nonatomic, strong) NSURL *manifestFileURL;

@end

@implementation EZTTSLibraryManager

#pragma mark - Singleton / init

+ (instancetype)sharedManager {
    static EZTTSLibraryManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] initInternal];
    });
    return shared;
}

- (instancetype)initInternal {
    self = [super init];
    if (self) {
        _ioQueue = dispatch_queue_create("com.ez.ttslibrary.io", DISPATCH_QUEUE_SERIAL);
        _entries = [NSMutableArray array];
        _snapshotLock = [[NSLock alloc] init];
        _snapshot = @[];

        NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                                     inDomains:NSUserDomainMask].firstObject;
        NSAssert(documents != nil, @"Could not resolve Documents directory.");

        _libraryRootURL       = [documents URLByAppendingPathComponent:kEZLibraryFolderName isDirectory:YES];
        _audioDirectoryURL    = [_libraryRootURL URLByAppendingPathComponent:kEZAudioFolderName isDirectory:YES];
        _waveformsDirectoryURL = [_libraryRootURL URLByAppendingPathComponent:kEZWaveformsFolderName isDirectory:YES];
        _cacheDirectoryURL    = [_libraryRootURL URLByAppendingPathComponent:kEZCacheFolderName isDirectory:YES];
        _manifestFileURL      = [_libraryRootURL URLByAppendingPathComponent:kEZManifestFileName isDirectory:NO];

        NSError *setupError;
        if (![self ensureDirectoriesExistWithError:&setupError]) {
            EZLogf(EZLogLevelError, @"TTSLibrary", @"Failed to create library folders: %@", setupError.localizedDescription);
        }

        NSError *loadError;
        NSArray<EZTTSManifestEntry *> *loaded = [self loadOrCreateManifestWithError:&loadError];
        if (loaded) {
            [_entries addObjectsFromArray:loaded];
            [self refreshSnapshotLocked_NoLock:NO];
        } else {
            EZLogf(EZLogLevelError, @"TTSLibrary", @"Failed to load manifest: %@", loadError.localizedDescription);
        }

        EZLogf(EZLogLevelInfo, @"TTSLibrary", @"Ready at %@ (%lu clips)", _libraryRootURL.path, (unsigned long)_entries.count);
    }
    return self;
}

#pragma mark - Folder setup

- (BOOL)ensureDirectoriesExistWithError:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSURL *url in @[self.libraryRootURL, self.audioDirectoryURL, self.waveformsDirectoryURL, self.cacheDirectoryURL]) {
        NSError *dirError;
        BOOL ok = [fm createDirectoryAtURL:url
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&dirError];
        if (!ok) {
            if (error) *error = EZLibraryError(EZTTSLibraryErrorCodeFolderCreationFailed,
                [NSString stringWithFormat:@"Could not create %@: %@", url.path, dirError.localizedDescription]);
            return NO;
        }
    }
    return YES;
}

- (NSURL *)absoluteURLForEntry:(EZTTSManifestEntry *)entry {
    return [self.libraryRootURL URLByAppendingPathComponent:entry.relativePath isDirectory:NO];
}

#pragma mark - Manifest load / save (call only from ioQueue, except at init)

- (nullable NSArray<EZTTSManifestEntry *> *)loadOrCreateManifestWithError:(NSError **)error {
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
        // app never hard-fails on launch. We NEVER silently discard the user's clips —
        // the audio files on disk are untouched, only the manifest index is reset.
        [self quarantineCorruptManifestFile];
        if (![self persistEntriesToDisk:@[] error:error]) return nil;
        EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Manifest.json was corrupt (%@); quarantined and reset.", jsonError.localizedDescription);
        return @[];
    }

    NSDictionary *dict = (NSDictionary *)json;
    NSArray *clipsRaw = [dict[kEZManifestKeyClips] isKindOfClass:[NSArray class]] ? dict[kEZManifestKeyClips] : @[];

    NSMutableArray<EZTTSManifestEntry *> *result = [NSMutableArray arrayWithCapacity:clipsRaw.count];
    for (id clipDict in clipsRaw) {
        if (![clipDict isKindOfClass:[NSDictionary class]]) continue;
        NSError *entryError;
        EZTTSManifestEntry *entry = [EZTTSManifestEntry entryWithDictionary:clipDict error:&entryError];
        if (entry) {
            [result addObject:entry];
        } else {
            // Skip malformed individual rows rather than failing the whole manifest.
            EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Skipping malformed manifest entry: %@", entryError.localizedDescription);
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
- (BOOL)persistEntriesToDisk:(NSArray<EZTTSManifestEntry *> *)entries error:(NSError **)error {
    NSMutableArray<NSDictionary *> *clipDicts = [NSMutableArray arrayWithCapacity:entries.count];
    for (EZTTSManifestEntry *entry in entries) {
        [clipDicts addObject:[entry dictionaryRepresentation]];
    }
    NSDictionary *manifestDict = @{
        kEZManifestKeyVersion: @(kEZManifestVersion),
        kEZManifestKeyClips: clipDicts
    };

    if (![NSJSONSerialization isValidJSONObject:manifestDict]) {
        if (error) *error = EZLibraryError(EZTTSLibraryErrorCodeWriteFailed, @"Manifest contains non-JSON-safe data.");
        return NO;
    }

    NSError *serializeError;
    NSData *data = [NSJSONSerialization dataWithJSONObject:manifestDict options:NSJSONWritingPrettyPrinted error:&serializeError];
    if (!data) {
        if (error) *error = EZLibraryError(EZTTSLibraryErrorCodeWriteFailed,
            [NSString stringWithFormat:@"Could not serialize manifest: %@", serializeError.localizedDescription]);
        return NO;
    }

    NSError *writeError;
    BOOL ok = [data writeToURL:self.manifestFileURL options:NSDataWritingAtomic error:&writeError];
    if (!ok) {
        if (error) *error = EZLibraryError(EZTTSLibraryErrorCodeWriteFailed,
            [NSString stringWithFormat:@"Could not write manifest: %@", writeError.localizedDescription]);
        return NO;
    }
    return YES;
}

#pragma mark - Snapshot (thread-safe reads)

/// Call from ioQueue after mutating `_entries`. Pass NO for `lock` only during -init,
/// before any other thread could possibly be touching `snapshot`.
- (void)refreshSnapshotLocked_NoLock:(BOOL)lock {
    NSArray<EZTTSManifestEntry *> *copy = [self.entries copy];
    if (lock) [self.snapshotLock lock];
    self.snapshot = copy;
    if (lock) [self.snapshotLock unlock];
}

- (NSArray<EZTTSManifestEntry *> *)currentSnapshot {
    [self.snapshotLock lock];
    NSArray<EZTTSManifestEntry *> *copy = self.snapshot;
    [self.snapshotLock unlock];
    return copy;
}

#pragma mark - Reading (public, any thread)

- (NSArray<EZTTSManifestEntry *> *)allClipsSortedByDateDescending {
    NSArray<EZTTSManifestEntry *> *snapshot = [self currentSnapshot];
    return [snapshot sortedArrayUsingComparator:^NSComparisonResult(EZTTSManifestEntry *a, EZTTSManifestEntry *b) {
        return [b.created compare:a.created]; // newest first
    }];
}

- (nullable EZTTSManifestEntry *)clipWithUUID:(NSString *)uuid {
    if (uuid.length == 0) return nil;
    for (EZTTSManifestEntry *entry in [self currentSnapshot]) {
        if ([entry.uuid isEqualToString:uuid]) return entry;
    }
    return nil;
}

- (NSArray<EZTTSManifestEntry *> *)searchClipsWithQuery:(nullable NSString *)query {
    NSArray<EZTTSManifestEntry *> *all = [self allClipsSortedByDateDescending];
    NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return all;

    NSString *needle = trimmed.lowercaseString;
    NSMutableArray<EZTTSManifestEntry *> *matches = [NSMutableArray array];
    for (EZTTSManifestEntry *entry in all) {
        if ([entry.voiceName.lowercaseString containsString:needle]) { [matches addObject:entry]; continue; }
        if ([entry.voiceID.lowercaseString containsString:needle]) { [matches addObject:entry]; continue; }
        if ([entry.prompt.lowercaseString containsString:needle]) { [matches addObject:entry]; continue; }
        if ([entry.provider.lowercaseString containsString:needle]) { [matches addObject:entry]; continue; }
        BOOL tagMatch = NO;
        for (NSString *tag in entry.tags) {
            if ([tag.lowercaseString containsString:needle]) { tagMatch = YES; break; }
        }
        if (tagMatch) [matches addObject:entry];
    }
    return matches;
}

#pragma mark - Save

- (void)saveAudioData:(NSData *)audioData
                prompt:(NSString *)prompt
             voiceName:(nullable NSString *)voiceName
               voiceID:(nullable NSString *)voiceID
              provider:(NSString *)provider
                 model:(nullable NSString *)model
             extension:(NSString *)extension
            completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    [self saveAudioData:audioData prompt:prompt voiceName:voiceName voiceID:voiceID
               provider:provider model:model extension:extension metadata:nil completion:completion];
}

- (void)saveAudioData:(NSData *)audioData
                prompt:(NSString *)prompt
             voiceName:(nullable NSString *)voiceName
               voiceID:(nullable NSString *)voiceID
              provider:(NSString *)provider
                 model:(nullable NSString *)model
             extension:(NSString *)extension
              metadata:(nullable NSDictionary<NSString *, id> *)metadata
            completion:(void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    if (audioData.length == 0 || prompt.length == 0 || provider.length == 0 || extension.length == 0) {
        NSError *err = EZLibraryError(EZTTSLibraryErrorCodeInvalidArgument,
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

        NSString *filename = [self generateFilenameWithExtension:extension];
        NSString *relativePath = [NSString stringWithFormat:@"%@/%@", kEZAudioFolderName, filename];
        NSURL *destinationURL = [self.libraryRootURL URLByAppendingPathComponent:relativePath isDirectory:NO];

        NSError *writeError;
        if (![audioData writeToURL:destinationURL options:NSDataWritingAtomic error:&writeError]) {
            NSError *err = EZLibraryError(EZTTSLibraryErrorCodeWriteFailed,
                [NSString stringWithFormat:@"Could not write audio file: %@", writeError.localizedDescription]);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
            return;
        }

        double duration = 0.0;
        double sampleRate = 0.0;
        [self measureDurationAndSampleRateAtURL:destinationURL duration:&duration sampleRate:&sampleRate];

        unsigned long long fileSize = 0;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:destinationURL.path error:nil];
        if (attrs) fileSize = [attrs fileSize];

        EZTTSManifestEntry *entry = [EZTTSManifestEntry entryWithProvider:provider
                                                                  voiceName:voiceName
                                                                    voiceID:voiceID
                                                                      model:model
                                                                     prompt:prompt
                                                                   filename:filename
                                                               relativePath:relativePath
                                                                   duration:duration
                                                                 sampleRate:sampleRate
                                                                   fileSize:fileSize];
        entry.metadata = metadata ?: @{};

        [self.entries addObject:entry];

        NSError *persistError;
        if (![self persistEntriesToDisk:self.entries error:&persistError]) {
            // Roll back the in-memory add so the cache never claims a clip the manifest
            // doesn't actually have on disk. The audio file itself is left in place —
            // it's orphaned but harmless, and safer than deleting user data on a write error.
            [self.entries removeLastObject];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, persistError); });
            return;
        }

        [self refreshSnapshotLocked_NoLock:YES];

        EZLogf(EZLogLevelInfo, @"TTSLibrary", @"Archived clip %@ (%@, %.2fs)", entry.uuid, entry.provider, entry.duration);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(entry, nil); });
    });
}

- (NSString *)generateFilenameWithExtension:(NSString *)extension {
    long long timestamp = (long long)[[NSDate date] timeIntervalSince1970];
    NSString *shortUUID = [[[NSUUID UUID] UUIDString] substringToIndex:8];
    NSString *cleanExt = [extension hasPrefix:@"."] ? [extension substringFromIndex:1] : extension;
    return [NSString stringWithFormat:@"tts_%lld_%@.%@", timestamp, shortUUID, cleanExt];
}

/// Synchronous AVFoundation measurement. Always called from ioQueue (background), so
/// blocking here doesn't affect the UI. AVAudioFile reads just the header/format info
/// for this, not the whole file, so it's cheap even for longer clips.
- (void)measureDurationAndSampleRateAtURL:(NSURL *)url duration:(double *)duration sampleRate:(double *)sampleRate {
    NSError *avError;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&avError];
    if (!file || avError) {
        EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Could not measure audio at %@: %@", url.lastPathComponent, avError.localizedDescription);
        *duration = 0.0;
        *sampleRate = 0.0;
        return;
    }
    double rate = file.processingFormat.sampleRate;
    *sampleRate = rate;
    *duration = rate > 0 ? ((double)file.length / rate) : 0.0;
}

#pragma mark - Mutation

- (void)deleteClipWithUUID:(NSString *)uuid
                 completion:(nullable void (^)(BOOL, NSError * _Nullable))completion
{
    dispatch_async(self.ioQueue, ^{
        NSUInteger idx = [self.entries indexOfObjectPassingTest:^BOOL(EZTTSManifestEntry *e, NSUInteger i, BOOL *stop) {
            return [e.uuid isEqualToString:uuid];
        }];
        if (idx == NSNotFound) {
            NSError *err = EZLibraryError(EZTTSLibraryErrorCodeClipNotFound, @"No clip with that uuid.");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, err); });
            return;
        }

        EZTTSManifestEntry *entry = self.entries[idx];
        NSURL *fileURL = [self absoluteURLForEntry:entry];

        [self.entries removeObjectAtIndex:idx];

        NSError *persistError;
        if (![self persistEntriesToDisk:self.entries error:&persistError]) {
            // Manifest write failed — put the entry back so our in-memory state still
            // matches what's actually persisted on disk.
            [self.entries insertObject:entry atIndex:idx];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, persistError); });
            return;
        }

        // Manifest is already updated at this point; best-effort delete the audio file.
        // If this fails we log it but still report success — the clip is gone from the
        // library either way, and a stray file on disk is a much smaller problem than a
        // manifest entry that points nowhere.
        NSError *fileError;
        if (![[NSFileManager defaultManager] removeItemAtURL:fileURL error:&fileError]) {
            EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Deleted manifest entry %@ but could not remove file: %@", uuid, fileError.localizedDescription);
        }

        [self refreshSnapshotLocked_NoLock:YES];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
    });
}

- (void)renameClipWithUUID:(NSString *)uuid
                      title:(NSString *)title
                 completion:(nullable void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    [self mutateEntryWithUUID:uuid completion:completion mutator:^(EZTTSManifestEntry *entry) {
        NSMutableDictionary *meta = [entry.metadata mutableCopy] ?: [NSMutableDictionary dictionary];
        meta[@"title"] = title;
        entry.metadata = meta;
    }];
}

- (void)favoriteClipWithUUID:(NSString *)uuid
                   completion:(nullable void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    [self mutateEntryWithUUID:uuid completion:completion mutator:^(EZTTSManifestEntry *entry) {
        entry.favorite = YES;
        // Track *when* it was pinned, separately from when it was created, so pin order
        // can be driven by pin recency — re-pinning something always sends it back to
        // the top of the pinned group, giving the user manual control over ordering.
        NSMutableDictionary *meta = [entry.metadata mutableCopy] ?: [NSMutableDictionary dictionary];
        meta[@"pinnedAt"] = @([[NSDate date] timeIntervalSince1970]);
        entry.metadata = meta;
    }];
}

- (void)unfavoriteClipWithUUID:(NSString *)uuid
                     completion:(nullable void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    [self mutateEntryWithUUID:uuid completion:completion mutator:^(EZTTSManifestEntry *entry) {
        entry.favorite = NO;
    }];
}

- (void)setPlaybackRate:(float)rate
             forClipUUID:(NSString *)uuid
              completion:(nullable void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    [self mutateEntryWithUUID:uuid completion:completion mutator:^(EZTTSManifestEntry *entry) {
        NSMutableDictionary *meta = [entry.metadata mutableCopy] ?: [NSMutableDictionary dictionary];
        meta[@"playbackRate"] = @(rate);
        entry.metadata = meta;
    }];
}

- (void)setSceneBackgroundLevel:(float)level
                   forClipUUID:(NSString *)uuid
                     completion:(nullable void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    [self mutateEntryWithUUID:uuid completion:completion mutator:^(EZTTSManifestEntry *entry) {
        NSMutableDictionary *meta = [entry.metadata mutableCopy] ?: [NSMutableDictionary dictionary];
        meta[@"sceneBackgroundLevel"] = @(MIN(1.0f, MAX(0.0f, level)));
        entry.metadata = meta;
    }];
}

- (void)replaceAudioForClipUUID:(NSString *)uuid
                        withData:(NSData *)audioData
                       extension:(NSString *)extension
                      completion:(nullable void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
{
    dispatch_async(self.ioQueue, ^{
        NSUInteger idx = [self.entries indexOfObjectPassingTest:^BOOL(EZTTSManifestEntry *e, NSUInteger i, BOOL *stop) {
            return [e.uuid isEqualToString:uuid];
        }];
        if (idx == NSNotFound) {
            NSError *err = EZLibraryError(EZTTSLibraryErrorCodeClipNotFound, @"No clip with that uuid.");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
            return;
        }

        EZTTSManifestEntry *oldEntry = self.entries[idx];
        NSURL *oldFileURL = [self absoluteURLForEntry:oldEntry];

        // Always write to a fresh filename rather than overwriting oldEntry's file
        // directly — the new audio may be in a different container (e.g. normalizing
        // writes .caf regardless of the original's format), so reusing the old filename
        // could leave its extension mismatched with its actual contents.
        NSString *filename = [self generateFilenameWithExtension:extension];
        NSString *relativePath = [NSString stringWithFormat:@"%@/%@", kEZAudioFolderName, filename];
        NSURL *destinationURL = [self.libraryRootURL URLByAppendingPathComponent:relativePath isDirectory:NO];

        NSError *writeError;
        if (![audioData writeToURL:destinationURL options:NSDataWritingAtomic error:&writeError]) {
            NSError *err = EZLibraryError(EZTTSLibraryErrorCodeWriteFailed,
                [NSString stringWithFormat:@"Could not write replacement audio: %@", writeError.localizedDescription]);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
            return;
        }

        double duration = 0.0, sampleRate = 0.0;
        [self measureDurationAndSampleRateAtURL:destinationURL duration:&duration sampleRate:&sampleRate];
        unsigned long long fileSize = 0;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:destinationURL.path error:nil];
        if (attrs) fileSize = [attrs fileSize];

        EZTTSManifestEntry *updated = [oldEntry copy];
        updated.filename = filename;
        updated.relativePath = relativePath;
        updated.duration = duration;
        updated.sampleRate = sampleRate;
        updated.fileSize = fileSize;
        self.entries[idx] = updated;

        NSError *persistError;
        if (![self persistEntriesToDisk:self.entries error:&persistError]) {
            self.entries[idx] = oldEntry; // roll back the manifest
            [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil]; // clean up the orphaned new file
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, persistError); });
            return;
        }

        [self refreshSnapshotLocked_NoLock:YES];

        // Manifest is already updated at this point — best-effort delete the old file.
        // If this fails we log it but still report success, matching -deleteClipWithUUID:'s
        // reasoning: a stray old file on disk is a smaller problem than any inconsistency
        // in what's reported back to the caller.
        NSError *deleteError;
        if (![[NSFileManager defaultManager] removeItemAtURL:oldFileURL error:&deleteError]) {
            EZLogf(EZLogLevelWarning, @"TTSLibrary", @"Replaced audio for %@ but could not remove old file: %@", uuid, deleteError.localizedDescription);
        }

        EZLogf(EZLogLevelInfo, @"TTSLibrary", @"Replaced audio in place for clip %@", uuid);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(updated, nil); });
    });
}

/// Shared plumbing for the small in-place mutations above: find the entry, mutate a
/// mutable copy, persist, swap it into `_entries`, refresh the snapshot, report back.
- (void)mutateEntryWithUUID:(NSString *)uuid
                   completion:(nullable void (^)(EZTTSManifestEntry * _Nullable, NSError * _Nullable))completion
                     mutator:(void (^)(EZTTSManifestEntry *entry))mutator
{
    dispatch_async(self.ioQueue, ^{
        NSUInteger idx = [self.entries indexOfObjectPassingTest:^BOOL(EZTTSManifestEntry *e, NSUInteger i, BOOL *stop) {
            return [e.uuid isEqualToString:uuid];
        }];
        if (idx == NSNotFound) {
            NSError *err = EZLibraryError(EZTTSLibraryErrorCodeClipNotFound, @"No clip with that uuid.");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
            return;
        }

        EZTTSManifestEntry *original = self.entries[idx];
        EZTTSManifestEntry *mutated = [original copy];
        mutator(mutated);
        self.entries[idx] = mutated;

        NSError *persistError;
        if (![self persistEntriesToDisk:self.entries error:&persistError]) {
            self.entries[idx] = original; // roll back
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, persistError); });
            return;
        }

        [self refreshSnapshotLocked_NoLock:YES];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(mutated, nil); });
    });
}

#pragma mark - Export

- (nullable NSURL *)exportURLForClipWithUUID:(NSString *)uuid {
    EZTTSManifestEntry *entry = [self clipWithUUID:uuid];
    if (!entry) return nil;
    NSURL *url = [self absoluteURLForEntry:entry];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return nil;
    return url;
}

@end
