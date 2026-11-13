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

/// The name a sound is displayed under everywhere: the user's custom
/// title (metadata[@"title"], set by Rename) when there is one, else the
/// prompt preview — the same rule EZSoundsViewController renders by.
/// Since 2026-11-13 this is also the sound's FILE name (user rule: what
/// the list shows is what the file is called, so shares/exports never
/// surface a generated sound_<stamp>_<id> name).
static NSString *EZSoundDisplayNameForEntry(EZSoundManifestEntry *entry) {
    NSString *custom = [entry.metadata[@"title"] isKindOfClass:NSString.class] ? entry.metadata[@"title"] : nil;
    if (custom.length) return custom;
    if (entry.preview.length) return entry.preview;
    return entry.prompt.length ? entry.prompt : @"Sound";
}

/// Filesystem-safe form of a display name: path-hostile and control
/// characters become spaces, runs of spaces collapse, capped at 60
/// characters. Falls back to @"Sound" if nothing usable remains.
static NSString *EZSoundSanitizedFileBase(NSString *name) {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
    NSCharacterSet *control = [NSCharacterSet controlCharacterSet];
    NSMutableString *clean = [NSMutableString stringWithCapacity:trimmed.length];
    BOOL lastWasSpace = YES; // also strips leading spaces
    for (NSUInteger i = 0; i < trimmed.length; i++) {
        unichar c = [trimmed characterAtIndex:i];
        if ([bad characterIsMember:c] || [control characterIsMember:c]) c = ' ';
        if (c == ' ') {
            if (lastWasSpace) continue;
            lastWasSpace = YES;
        } else {
            lastWasSpace = NO;
        }
        [clean appendFormat:@"%C", c];
    }
    NSString *result = [clean stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
    if (result.length > 60) {
        result = [[result substringToIndex:60] stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceCharacterSet]];
    }
    return result.length ? result : @"Sound";
}

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

// File naming (ioQueue only): the unique on-disk filename for a display
// name + extension, and the launch-time pass that renames existing
// files to their display names.
- (NSString *)uniqueFilenameForDisplayName:(NSString *)displayName
                                 extension:(NSString *)extension
                            excludingEntry:(nullable EZSoundManifestEntry *)excluded;
- (void)reconcileFilenamesWithDisplayNames;

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
            [self reconcileFilenamesWithDisplayNames];
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

#pragma mark - File naming (ioQueue only, except at init)

/// The first free filename for `displayName` + `extension`: the plain
/// name, then " 2", " 3", ... A name is taken when another entry uses
/// it or an (orphan) file already sits at that path — existing audio is
/// never clobbered. The excluded entry's own current filename counts as
/// free, so a no-op rename stays a no-op.
- (NSString *)uniqueFilenameForDisplayName:(NSString *)displayName
                                 extension:(NSString *)extension
                            excludingEntry:(EZSoundManifestEntry *)excluded {
    NSString *base = EZSoundSanitizedFileBase(displayName);
    NSString *ext = extension.length ? extension : @"mp3";
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSInteger n = 1; ; n++) {
        NSString *candidate = (n == 1)
            ? [NSString stringWithFormat:@"%@.%@", base, ext]
            : [NSString stringWithFormat:@"%@ %ld.%@", base, (long)n, ext];
        if (excluded && [candidate isEqualToString:excluded.filename]) return candidate;
        BOOL taken = NO;
        for (EZSoundManifestEntry *other in self.entries) {
            if (other != excluded && [other.filename isEqualToString:candidate]) { taken = YES; break; }
        }
        if (!taken) {
            NSURL *url = [self.audioDirectoryURL URLByAppendingPathComponent:candidate isDirectory:NO];
            if ([fm fileExistsAtPath:url.path]) taken = YES;
        }
        if (!taken) return candidate;
    }
}

/// Brings every existing file in line with the display-name rule:
/// files saved before it (sound_<stamp>_<id>.mp3) are renamed to the
/// name the list shows. Per file: a missing file or a failed move just
/// leaves that sound as it was. If the manifest write fails after
/// moves, every move is rolled back so disk and manifest never
/// disagree.
- (void)reconcileFilenamesWithDisplayNames {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *moves = [NSMutableArray array];
    for (EZSoundManifestEntry *entry in self.entries) {
        NSString *ext = entry.filename.pathExtension.length ? entry.filename.pathExtension : @"mp3";
        NSString *desired = [self uniqueFilenameForDisplayName:EZSoundDisplayNameForEntry(entry)
                                                     extension:ext
                                                excludingEntry:entry];
        if ([desired isEqualToString:entry.filename]) continue;
        NSURL *oldURL = [self absoluteURLForEntry:entry];
        if (![fm fileExistsAtPath:oldURL.path]) continue;
        NSString *oldFilename = entry.filename;
        NSString *oldRelativePath = entry.relativePath;
        entry.filename = desired;
        entry.relativePath = [kEZAudioFolderName stringByAppendingPathComponent:desired];
        NSError *moveError;
        if (![fm moveItemAtURL:oldURL toURL:[self absoluteURLForEntry:entry] error:&moveError]) {
            entry.filename = oldFilename;
            entry.relativePath = oldRelativePath;
            EZLogf(EZLogLevelWarning, @"SoundLibrary",
                   @"Could not rename %@ to its display name: %@", oldFilename, moveError.localizedDescription);
            continue;
        }
        [moves addObject:@{@"uuid": entry.uuid,
                            @"oldFilename": oldFilename,
                            @"oldRelativePath": oldRelativePath}];
    }
    if (!moves.count) return;
    NSError *persistError;
    if ([self persistEntriesToDisk:self.entries error:&persistError]) {
        EZLogf(EZLogLevelInfo, @"SoundLibrary",
               @"Renamed %lu sound file(s) to their display names", (unsigned long)moves.count);
        return;
    }
    EZLogf(EZLogLevelError, @"SoundLibrary",
           @"Display-name rename could not save the manifest (%@); rolling files back", persistError.localizedDescription);
    for (NSDictionary *move in moves.reverseObjectEnumerator) {
        for (EZSoundManifestEntry *entry in self.entries) {
            if ([entry.uuid isEqualToString:move[@"uuid"]]) {
                NSURL *current = [self absoluteURLForEntry:entry];
                entry.filename = move[@"oldFilename"];
                entry.relativePath = move[@"oldRelativePath"];
                [fm moveItemAtURL:current toURL:[self absoluteURLForEntry:entry] error:nil];
                break;
            }
        }
    }
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

        // Build the entry first: the file takes the sound's display
        // name from birth (user rule, 2026-11-13) — what the list shows
        // is what the file is called, so shares/exports never surface a
        // generated sound_<stamp>_<id> name. The filename is filled in
        // below, once metadata is merged and the name is final.
        EZSoundManifestEntry *entry = [EZSoundManifestEntry entryWithProvider:provider
                                                                         model:model
                                                                        prompt:prompt
                                                                      filename:@""
                                                                  relativePath:@""
                                                                      duration:0
                                                                    sampleRate:0
                                                                      fileSize:(unsigned long long)audioData.length];
        if (metadata.count) {
            NSMutableDictionary *merged = [entry.metadata mutableCopy];
            [merged addEntriesFromDictionary:metadata];
            entry.metadata = merged;
        }
        NSString *filename = [self uniqueFilenameForDisplayName:EZSoundDisplayNameForEntry(entry)
                                                      extension:extension
                                                 excludingEntry:entry];
        NSString *relativePath = [kEZAudioFolderName stringByAppendingPathComponent:filename];
        entry.filename = filename;
        entry.relativePath = relativePath;
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
        entry.duration = duration;
        entry.sampleRate = sampleRate;
        entry.fileSize = fileSize;

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

- (void)renameSoundWithUUID:(NSString *)uuid
                       title:(NSString *)title
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
        NSString *trimmed = [title stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSDictionary *oldMetadata = target.metadata;
        NSMutableDictionary *meta = [oldMetadata mutableCopy];
        if (trimmed.length) meta[@"title"] = trimmed;
        else [meta removeObjectForKey:@"title"];
        target.metadata = meta;

        // The file takes the new display name too (user rule,
        // 2026-11-13): rename in the list == rename on disk, so a share
        // or export uses the name the user sees. A failed move keeps the
        // old filename rather than failing the rename — the title still
        // saves, and the launch-time reconcile retries the file later.
        NSString *oldFilename = target.filename;
        NSString *oldRelativePath = target.relativePath;
        NSString *ext = oldFilename.pathExtension.length ? oldFilename.pathExtension : @"mp3";
        NSString *desired = [self uniqueFilenameForDisplayName:EZSoundDisplayNameForEntry(target)
                                                     extension:ext
                                                excludingEntry:target];
        BOOL fileMoved = NO;
        if (![desired isEqualToString:oldFilename]) {
            NSURL *oldURL = [self absoluteURLForEntry:target];
            target.filename = desired;
            target.relativePath = [kEZAudioFolderName stringByAppendingPathComponent:desired];
            NSError *moveError;
            if ([[NSFileManager defaultManager] moveItemAtURL:oldURL
                                                        toURL:[self absoluteURLForEntry:target]
                                                        error:&moveError]) {
                fileMoved = YES;
            } else {
                EZLogf(EZLogLevelWarning, @"SoundLibrary",
                       @"Could not rename file for %@: %@", uuid, moveError.localizedDescription);
                target.filename = oldFilename;
                target.relativePath = oldRelativePath;
            }
        }

        NSError *persistError;
        if (![self persistEntriesToDisk:self.entries error:&persistError]) {
            target.metadata = oldMetadata;
            if (fileMoved) {
                NSURL *movedURL = [self absoluteURLForEntry:target];
                target.filename = oldFilename;
                target.relativePath = oldRelativePath;
                [[NSFileManager defaultManager] moveItemAtURL:movedURL
                                                        toURL:[self absoluteURLForEntry:target]
                                                        error:nil];
            }
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, persistError); });
            return;
        }
        [self refreshSnapshotLocked_NoLock:YES];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(target, nil); });
    });
}

- (void)replaceAudioForSoundUUID:(NSString *)uuid
                        withData:(NSData *)audioData
                       extension:(NSString *)extension
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
        NSURL *oldFileURL = [self absoluteURLForEntry:target];

        // Fresh filename carrying the sound's display name — the
        // replacement may be in a different container than the
        // original (edits export .caf / .m4a), so the extension comes
        // from the new audio while the name stays the displayed one.
        NSString *filename = [self uniqueFilenameForDisplayName:EZSoundDisplayNameForEntry(target)
                                                      extension:extension
                                                 excludingEntry:target];
        NSString *relativePath = [kEZAudioFolderName stringByAppendingPathComponent:filename];
        NSURL *destinationURL = [self.libraryRootURL URLByAppendingPathComponent:relativePath isDirectory:NO];

        NSError *writeError;
        if (![audioData writeToURL:destinationURL options:NSDataWritingAtomic error:&writeError]) {
            NSError *err = EZSoundLibraryError(EZSoundLibraryErrorCodeWriteFailed,
                [NSString stringWithFormat:@"Could not write replacement audio: %@", writeError.localizedDescription]);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
            return;
        }

        // Measure exactly like a fresh save does.
        double duration = 0, sampleRate = 0;
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:destinationURL options:nil];
        if (CMTIME_IS_NUMERIC(asset.duration)) duration = CMTimeGetSeconds(asset.duration);
        AVAudioFile *audioFile = [[AVAudioFile alloc] initForReading:destinationURL error:nil];
        if (audioFile) {
            sampleRate = audioFile.fileFormat.sampleRate;
            if (duration <= 0 && audioFile.fileFormat.sampleRate > 0) {
                duration = (double)audioFile.length / audioFile.fileFormat.sampleRate;
            }
        }
        unsigned long long fileSize = (unsigned long long)audioData.length;

        NSString *oldFilename = target.filename;
        NSString *oldRelativePath = target.relativePath;
        double oldDuration = target.duration, oldSampleRate = target.sampleRate;
        unsigned long long oldFileSize = target.fileSize;
        target.filename = filename;
        target.relativePath = relativePath;
        target.duration = duration;
        target.sampleRate = sampleRate;
        target.fileSize = fileSize;

        NSError *persistError;
        if (![self persistEntriesToDisk:self.entries error:&persistError]) {
            target.filename = oldFilename;
            target.relativePath = oldRelativePath;
            target.duration = oldDuration;
            target.sampleRate = oldSampleRate;
            target.fileSize = oldFileSize;
            [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, persistError); });
            return;
        }
        [self refreshSnapshotLocked_NoLock:YES];

        // Manifest is updated — best-effort delete of the old file; a
        // stray file on disk is a smaller problem than reporting a
        // failure for an edit that actually landed.
        NSError *deleteError;
        if (![oldFileURL isEqual:destinationURL] &&
            ![[NSFileManager defaultManager] removeItemAtURL:oldFileURL error:&deleteError]) {
            EZLogf(EZLogLevelWarning, @"SoundLibrary", @"Replaced audio for %@ but could not remove old file: %@", uuid, deleteError.localizedDescription);
        }
        EZLogf(EZLogLevelInfo, @"SoundLibrary", @"Replaced audio in place for sound %@", uuid);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(target, nil); });
    });
}

- (void)setPlaybackRate:(float)rate
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
        NSDictionary *oldMetadata = target.metadata;
        NSMutableDictionary *meta = [oldMetadata mutableCopy];
        meta[@"playbackRate"] = @(rate);
        target.metadata = meta;
        NSError *persistError;
        if (![self persistEntriesToDisk:self.entries error:&persistError]) {
            target.metadata = oldMetadata;
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
