// EZMusicLibraryManager.m
// EZCompleteUI v1.3
//
// Purpose:
//   Implementation of the on-device song library described in
//   EZMusicLibraryManager.h. All manifest reads and writes run on one serial
//   queue (`queue`) so the JSON file is never written by two threads at once.
//
// Changes from v1.0:
//   - Added -retainSongFromRemoteURL:entry:completion: (download + archive,
//     with one shared download per entry).
//   - Added this header comment.
//
// Changes from v1.2:
//   - Added -localSongRecordForEntryID:.
//
// Changes from v1.1:
//   - After a NEW song is saved on the device, cover art generation is
//     started through EZMusicArtworkService. Every path that saves a song
//     (chat tool, AI Music screen, share/download) ends up in the archive
//     method below, so this is the single place that triggers it.

#import "EZMusicLibraryManager.h"
#import "EZMusicArtworkService.h"
#import <AVFoundation/AVFoundation.h>
@interface EZMusicLibraryManager ()
@property (nonatomic, strong) NSURL *libraryRootURL, *songsURL, *referencesURL, *stagingURL, *manifestURL;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property (nonatomic) dispatch_queue_t queue;
// Completion blocks waiting on a song that is currently downloading, keyed by
// entry ID. Created on first use and only touched inside @synchronized(self).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *pendingRetainCompletions;
@end

static NSString *EZMusicStyleLabel(NSString *prompt) {
    NSString *trimmed = [prompt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return @"AI Music";
    // The prompt remains archived separately; this is intentionally only a
    // compact player subtitle, not a truncated paragraph.
    NSArray<NSString *> *words = [trimmed componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *labelWords = [NSMutableArray arrayWithCapacity:3];
    for (NSString *word in words) {
        NSString *clean = [word stringByTrimmingCharactersInSet:[NSCharacterSet punctuationCharacterSet]];
        if (clean.length) [labelWords addObject:clean];
        if (labelWords.count == 3) break;
    }
    NSString *label = [labelWords componentsJoinedByString:@" "];
    return label.length ? label : @"AI Music";
}
@implementation EZMusicLibraryManager
+ (instancetype)sharedManager { static EZMusicLibraryManager *m; static dispatch_once_t once; dispatch_once(&once, ^{ m = [[self alloc] initPrivate]; }); return m; }
- (instancetype)initPrivate { if ((self = [super init])) { _queue = dispatch_queue_create("com.ez.musiclibrary", DISPATCH_QUEUE_SERIAL); NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject; _libraryRootURL = [docs URLByAppendingPathComponent:@"EZMusic" isDirectory:YES]; _songsURL = [_libraryRootURL URLByAppendingPathComponent:@"Songs" isDirectory:YES]; _referencesURL = [_libraryRootURL URLByAppendingPathComponent:@"References" isDirectory:YES]; _stagingURL = [_libraryRootURL URLByAppendingPathComponent:@"Staging" isDirectory:YES]; _manifestURL = [_libraryRootURL URLByAppendingPathComponent:@"Manifest.json"]; _items = [NSMutableArray array]; [self setup]; NSData *data = [NSData dataWithContentsOfURL:_manifestURL]; NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; for (id item in [manifest[@"items"] isKindOfClass:NSArray.class] ? manifest[@"items"] : @[]) if ([item isKindOfClass:NSDictionary.class]) [_items addObject:item]; [self persist]; } return self; }
- (void)setup { [NSFileManager.defaultManager createDirectoryAtURL:self.songsURL withIntermediateDirectories:YES attributes:nil error:nil]; [NSFileManager.defaultManager createDirectoryAtURL:self.referencesURL withIntermediateDirectories:YES attributes:nil error:nil]; [NSFileManager.defaultManager createDirectoryAtURL:self.stagingURL withIntermediateDirectories:YES attributes:nil error:nil]; }
- (void)persist { NSData *data = [NSJSONSerialization dataWithJSONObject:@{ @"version": @1, @"items": self.items } options:NSJSONWritingPrettyPrinted error:nil]; [data writeToURL:self.manifestURL options:NSDataWritingAtomic error:nil]; }
- (NSDictionary *)localSongRecordForEntryID:(NSString *)entryID {
    if (entryID.length == 0) return nil;
    __block NSDictionary *record = nil;
    dispatch_sync(self.queue, ^{
        for (NSDictionary *item in self.items) {
            if ([item[@"kind"] isEqual:@"song"] && [item[@"entry_id"] isEqual:entryID]) {
                record = [item copy];
                break;
            }
        }
    });
    return record;
}

- (NSURL *)localSongURLForEntryID:(NSString *)entryID {
    __block NSString *path;
    dispatch_sync(self.queue, ^{
        for (NSDictionary *item in self.items) {
            if ([item[@"kind"] isEqual:@"song"] && [item[@"entry_id"] isEqual:entryID]) {
                path = item[@"path"];
                break;
            }
        }
    });
    NSURL *url = path ? [self.libraryRootURL URLByAppendingPathComponent:path] : nil;
    if (!url || ![NSFileManager.defaultManager fileExistsAtPath:url.path]) return nil;

    // Never prefer a stale/corrupt local candidate over a fresh signed stream.
    NSError *validationError = nil;
    AVAudioFile *audio = [[AVAudioFile alloc] initForReading:url error:&validationError];
    if (audio) return url;
    NSLog(@"EZMusic: ignoring invalid local archive %@: %@", url.lastPathComponent, validationError.localizedDescription);
    dispatch_async(self.queue, ^{
        NSUInteger index = [self.items indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
            return [item[@"kind"] isEqual:@"song"] && [item[@"entry_id"] isEqual:entryID];
        }];
        if (index != NSNotFound) {
            [self.items removeObjectAtIndex:index];
            [self persist];
        }
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    });
    return nil;
}

- (NSArray<NSString *> *)localSongEntryIDs {
    __block NSArray<NSString *> *identifiers;
    dispatch_sync(self.queue, ^{
        NSMutableArray<NSString *> *result = [NSMutableArray array];
        for (NSDictionary *item in self.items) {
            NSString *entryID = [item[@"entry_id"] isKindOfClass:NSString.class] ? item[@"entry_id"] : @"";
            NSString *path = [item[@"path"] isKindOfClass:NSString.class] ? item[@"path"] : @"";
            NSURL *url = path.length ? [self.libraryRootURL URLByAppendingPathComponent:path] : nil;
            if ([item[@"kind"] isEqual:@"song"] && entryID.length && url &&
                [NSFileManager.defaultManager fileExistsAtPath:url.path]) {
                [result addObject:entryID];
            }
        }
        identifiers = result.copy;
    });
    return identifiers ?: @[];
}

- (void)updateSongMetadataForEntry:(NSDictionary *)entry {
    NSString *entryID = [entry[@"id"] isKindOfClass:NSString.class] ? entry[@"id"] : @"";
    if (!entryID.length) return;
    NSDictionary *entryCopy = [entry copy];
    dispatch_async(self.queue, ^{
        NSUInteger index = [self.items indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
            return [item[@"kind"] isEqual:@"song"] && [item[@"entry_id"] isEqual:entryID];
        }];
        if (index == NSNotFound) return;
        NSMutableDictionary *record = [self.items[index] mutableCopy];
        for (NSString *key in @[ @"title", @"prompt", @"lyrics", @"generation_id", @"model_id", @"created_at", @"completed_at" ]) {
            if ([entryCopy[key] isKindOfClass:NSString.class]) record[key] = entryCopy[key];
        }
        if ([entryCopy[@"prompt"] isKindOfClass:NSString.class]) record[@"style"] = EZMusicStyleLabel(entryCopy[@"prompt"]);
        if ([entryCopy[@"duration_actual_ms"] isKindOfClass:NSNumber.class]) record[@"duration_ms"] = entryCopy[@"duration_actual_ms"];
        self.items[index] = record;
        [self persist];
    });
}
- (void)archiveSongAtTemporaryURL:(NSURL *)temporaryURL entry:(NSDictionary *)entry {
    [self archiveSongAtTemporaryURL:temporaryURL entry:entry completion:nil];
}

- (void)archiveSongAtTemporaryURL:(NSURL *)temporaryURL
                            entry:(NSDictionary *)entry
                       completion:(void (^)(NSURL *localURL, NSError *error))completion {
    if (!temporaryURL || !entry) {
        if (completion) completion(nil, [NSError errorWithDomain:@"EZMusicLibrary"
                                                             code:1
                                                         userInfo:@{NSLocalizedDescriptionKey: @"The downloaded song was unavailable."}]);
        return;
    }

    // NSURLSession owns `temporaryURL` and can delete it the instant its
    // completion handler returns. Copy it synchronously before handing work to
    // our serial archive queue.
    [self setup];
    NSString *extension = temporaryURL.pathExtension.length ? temporaryURL.pathExtension : @"audio";
    NSURL *stagedURL = [self.stagingURL URLByAppendingPathComponent:
        [[NSString stringWithFormat:@"download_%@", NSUUID.UUID.UUIDString] stringByAppendingPathExtension:extension]];
    NSError *stageError = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:temporaryURL toURL:stagedURL error:&stageError]) {
        if (completion) completion(nil, stageError ?: [NSError errorWithDomain:@"EZMusicLibrary" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Couldn’t save the downloaded song."}]);
        return;
    }
    NSDictionary *entryCopy = [entry copy];
    dispatch_async(self.queue, ^{
        [self setup];
        NSString *entryID = [entryCopy[@"id"] isKindOfClass:NSString.class] ? entryCopy[@"id"] : NSUUID.UUID.UUIDString;
        // Keep the exact bytes downloaded from our music service.  The previous
        // MP3-to-WAV conversion was unnecessary for AVPlayer playback and could
        // fail on valid provider MP3s, silently leaving Songs empty.
        NSString *path = [@"Songs" stringByAppendingPathComponent:[entryID stringByAppendingPathExtension:@"mp3"]];
        NSURL *destination = [self.libraryRootURL URLByAppendingPathComponent:path];
        [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
        NSError *archiveError = nil;
        BOOL copied = [NSFileManager.defaultManager copyItemAtURL:stagedURL toURL:destination error:&archiveError];
        [NSFileManager.defaultManager removeItemAtURL:stagedURL error:nil];
        if (!copied || ![NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
            [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
            NSLog(@"EZMusic: could not archive downloaded song: %@", archiveError.localizedDescription);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, archiveError ?: [NSError errorWithDomain:@"EZMusicLibrary" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Couldn’t save the downloaded song."}]); });
            return;
        }
        NSMutableDictionary *record = [@{ @"kind": @"song", @"entry_id": entryID, @"path": path,
            @"format": @"mp3", @"title": [entryCopy[@"title"] isKindOfClass:NSString.class] ? entryCopy[@"title"] : @"Untitled song",
            @"prompt": [entryCopy[@"prompt"] isKindOfClass:NSString.class] ? entryCopy[@"prompt"] : @"",
            @"style": EZMusicStyleLabel([entryCopy[@"prompt"] isKindOfClass:NSString.class] ? entryCopy[@"prompt"] : @""),
            @"lyrics": [entryCopy[@"lyrics"] isKindOfClass:NSString.class] ? entryCopy[@"lyrics"] : @"",
            @"generation_id": [entryCopy[@"generation_id"] isKindOfClass:NSString.class] ? entryCopy[@"generation_id"] : @"",
            @"model_id": [entryCopy[@"model_id"] isKindOfClass:NSString.class] ? entryCopy[@"model_id"] : @"",
            @"created_at": [entryCopy[@"created_at"] isKindOfClass:NSString.class] ? entryCopy[@"created_at"] : @"",
            @"completed_at": [entryCopy[@"completed_at"] isKindOfClass:NSString.class] ? entryCopy[@"completed_at"] : @"",
            @"duration_ms": [entryCopy[@"duration_actual_ms"] isKindOfClass:NSNumber.class] ? entryCopy[@"duration_actual_ms"] : @0,
            @"archived_at": @([[NSDate date] timeIntervalSince1970]) } mutableCopy];
        NSUInteger index = [self.items indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
            return [item[@"kind"] isEqual:@"song"] && [item[@"entry_id"] isEqual:entryID];
        }];
        if (index == NSNotFound) [self.items addObject:record]; else self.items[index] = record;
        [self persist];
        // The song is safely on the device; now start its cover art. The service
        // skips songs that already have a cover, so re-saving is harmless.
        NSMutableDictionary *artworkEntry = [entryCopy mutableCopy];
        artworkEntry[@"id"] = entryID;
        [[EZMusicArtworkService sharedService] generateArtworkIfNeededForEntry:artworkEntry];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(destination, nil); });
    });
}
- (void)retainSongFromRemoteURL:(NSURL *)remoteURL
                          entry:(NSDictionary *)entry
                     completion:(void (^)(NSURL *localURL, NSError *error))completion {
    NSString *entryID = [entry[@"id"] isKindOfClass:NSString.class] ? entry[@"id"] : @"";
    void (^finalCompletion)(NSURL *, NSError *) = completion ?: ^(NSURL *localURL, NSError *error) {};

    if (!remoteURL || entryID.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            finalCompletion(nil, [NSError errorWithDomain:@"EZMusicLibrary" code:4
                                                 userInfo:@{NSLocalizedDescriptionKey: @"The song's download link was unavailable."}]);
        });
        return;
    }

    // Already on the device and readable: nothing to download.
    NSURL *existingURL = [self localSongURLForEntryID:entryID];
    if (existingURL) {
        [self updateSongMetadataForEntry:entry];
        dispatch_async(dispatch_get_main_queue(), ^{ finalCompletion(existingURL, nil); });
        return;
    }

    // If this song is already downloading, wait for that download instead of
    // starting a second one.
    BOOL downloadAlreadyRunning = NO;
    @synchronized (self) {
        if (!self.pendingRetainCompletions) self.pendingRetainCompletions = [NSMutableDictionary dictionary];
        NSMutableArray *waitingCompletions = self.pendingRetainCompletions[entryID];
        downloadAlreadyRunning = (waitingCompletions != nil);
        if (!waitingCompletions) {
            waitingCompletions = [NSMutableArray array];
            self.pendingRetainCompletions[entryID] = waitingCompletions;
        }
        [waitingCompletions addObject:[finalCompletion copy]];
    }
    if (downloadAlreadyRunning) return;

    // Hands the result to everyone waiting on this song, on the main queue.
    void (^finishDownload)(NSURL *, NSError *) = ^(NSURL *localURL, NSError *error) {
        NSArray *waitingCompletions;
        @synchronized (self) {
            waitingCompletions = [self.pendingRetainCompletions[entryID] copy];
            [self.pendingRetainCompletions removeObjectForKey:entryID];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            for (id waitingBlock in waitingCompletions) {
                ((void (^)(NSURL *, NSError *))waitingBlock)(localURL, error);
            }
        });
    };

    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:remoteURL
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *downloadError) {
        NSInteger httpStatus = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (downloadError || !location || httpStatus < 200 || httpStatus >= 300) {
            NSString *reason = downloadError.localizedDescription
                ?: [NSString stringWithFormat:@"The song couldn't be downloaded (HTTP %ld).", (long)httpStatus];
            finishDownload(nil, downloadError ?: [NSError errorWithDomain:@"EZMusicLibrary" code:5
                                                                  userInfo:@{NSLocalizedDescriptionKey: reason}]);
            return;
        }
        // archiveSongAtTemporaryURL copies `location` before returning, which
        // matters because NSURLSession deletes it as soon as this block ends.
        [self archiveSongAtTemporaryURL:location entry:entry completion:^(NSURL *localURL, NSError *archiveError) {
            finishDownload(localURL, archiveError);
        }];
    }];
    [downloadTask resume];
}

- (void)archiveReferenceAtURL:(NSURL *)sourceURL sourceName:(NSString *)sourceName mode:(NSString *)mode { if (!sourceURL.isFileURL) return; dispatch_async(self.queue, ^{ [self setup]; NSString *identifier = NSUUID.UUID.UUIDString; NSString *ext = sourceURL.pathExtension.length ? sourceURL.pathExtension : @"m4a"; NSString *path = [@"References" stringByAppendingPathComponent:[[NSString stringWithFormat:@"reference_%@", identifier] stringByAppendingPathExtension:ext]]; NSURL *to = [self.libraryRootURL URLByAppendingPathComponent:path]; if (![NSFileManager.defaultManager copyItemAtURL:sourceURL toURL:to error:nil]) return; [self.items addObject:@{ @"kind": @"reference", @"id": identifier, @"path": path, @"source_name": sourceName ?: sourceURL.lastPathComponent ?: @"Reference", @"reference_mode": mode ?: @"style", @"added_at": @([[NSDate date] timeIntervalSince1970]) }]; [self persist]; }); }
@end
