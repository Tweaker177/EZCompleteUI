#import "EZMusicLibraryManager.h"
#import <AVFoundation/AVFoundation.h>
@interface EZMusicLibraryManager ()
@property (nonatomic, strong) NSURL *libraryRootURL, *songsURL, *referencesURL, *stagingURL, *manifestURL;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property (nonatomic) dispatch_queue_t queue;
@end
@implementation EZMusicLibraryManager
+ (instancetype)sharedManager { static EZMusicLibraryManager *m; static dispatch_once_t once; dispatch_once(&once, ^{ m = [[self alloc] initPrivate]; }); return m; }
- (instancetype)initPrivate { if ((self = [super init])) { _queue = dispatch_queue_create("com.ez.musiclibrary", DISPATCH_QUEUE_SERIAL); NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject; _libraryRootURL = [docs URLByAppendingPathComponent:@"EZMusic" isDirectory:YES]; _songsURL = [_libraryRootURL URLByAppendingPathComponent:@"Songs" isDirectory:YES]; _referencesURL = [_libraryRootURL URLByAppendingPathComponent:@"References" isDirectory:YES]; _stagingURL = [_libraryRootURL URLByAppendingPathComponent:@"Staging" isDirectory:YES]; _manifestURL = [_libraryRootURL URLByAppendingPathComponent:@"Manifest.json"]; _items = [NSMutableArray array]; [self setup]; NSData *data = [NSData dataWithContentsOfURL:_manifestURL]; NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; for (id item in [manifest[@"items"] isKindOfClass:NSArray.class] ? manifest[@"items"] : @[]) if ([item isKindOfClass:NSDictionary.class]) [_items addObject:item]; [self persist]; } return self; }
- (void)setup { [NSFileManager.defaultManager createDirectoryAtURL:self.songsURL withIntermediateDirectories:YES attributes:nil error:nil]; [NSFileManager.defaultManager createDirectoryAtURL:self.referencesURL withIntermediateDirectories:YES attributes:nil error:nil]; [NSFileManager.defaultManager createDirectoryAtURL:self.stagingURL withIntermediateDirectories:YES attributes:nil error:nil]; }
- (void)persist { NSData *data = [NSJSONSerialization dataWithJSONObject:@{ @"version": @1, @"items": self.items } options:NSJSONWritingPrettyPrinted error:nil]; [data writeToURL:self.manifestURL options:NSDataWritingAtomic error:nil]; }
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
- (BOOL)writeWAVFromURL:(NSURL *)source toURL:(NSURL *)destination error:(NSError **)error {
    AVAudioFile *input = [[AVAudioFile alloc] initForReading:source error:error];
    if (!input) return NO;
    AVAudioFile *output = [[AVAudioFile alloc] initForWriting:destination
                                                       settings:input.processingFormat.settings
                                                  commonFormat:input.processingFormat.commonFormat
                                                   interleaved:input.processingFormat.isInterleaved
                                                         error:error];
    if (!output) return NO;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:input.processingFormat frameCapacity:4096];
    while (YES) {
        buffer.frameLength = 0;
        if (![input readIntoBuffer:buffer error:error]) return NO;
        if (buffer.frameLength == 0) break;
        if (![output writeFromBuffer:buffer error:error]) return NO;
    }
    return YES;
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
    // our serial conversion queue; otherwise WAV conversion races that cleanup.
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
        NSString *path = [@"Songs" stringByAppendingPathComponent:[entryID stringByAppendingPathExtension:@"wav"]];
        NSURL *destination = [self.libraryRootURL URLByAppendingPathComponent:path];
        [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
        NSError *conversionError = nil;
        BOOL converted = [self writeWAVFromURL:stagedURL toURL:destination error:&conversionError];
        [NSFileManager.defaultManager removeItemAtURL:stagedURL error:nil];
        if (!converted) {
            [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
            NSLog(@"EZMusic: could not archive WAV: %@", conversionError.localizedDescription);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, conversionError ?: [NSError errorWithDomain:@"EZMusicLibrary" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Couldn’t convert the downloaded song to WAV."}]); });
            return;
        }
        NSMutableDictionary *record = [@{ @"kind": @"song", @"entry_id": entryID, @"path": path,
            @"format": @"wav", @"title": [entryCopy[@"title"] isKindOfClass:NSString.class] ? entryCopy[@"title"] : @"Untitled song",
            @"generation_id": [entryCopy[@"generation_id"] isKindOfClass:NSString.class] ? entryCopy[@"generation_id"] : @"",
            @"model_id": [entryCopy[@"model_id"] isKindOfClass:NSString.class] ? entryCopy[@"model_id"] : @"",
            @"created_at": [entryCopy[@"created_at"] isKindOfClass:NSString.class] ? entryCopy[@"created_at"] : @"",
            @"archived_at": @([[NSDate date] timeIntervalSince1970]) } mutableCopy];
        NSUInteger index = [self.items indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
            return [item[@"kind"] isEqual:@"song"] && [item[@"entry_id"] isEqual:entryID];
        }];
        if (index == NSNotFound) [self.items addObject:record]; else self.items[index] = record;
        [self persist];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(destination, nil); });
    });
}
- (void)archiveReferenceAtURL:(NSURL *)sourceURL sourceName:(NSString *)sourceName mode:(NSString *)mode { if (!sourceURL.isFileURL) return; dispatch_async(self.queue, ^{ [self setup]; NSString *identifier = NSUUID.UUID.UUIDString; NSString *ext = sourceURL.pathExtension.length ? sourceURL.pathExtension : @"m4a"; NSString *path = [@"References" stringByAppendingPathComponent:[[NSString stringWithFormat:@"reference_%@", identifier] stringByAppendingPathExtension:ext]]; NSURL *to = [self.libraryRootURL URLByAppendingPathComponent:path]; if (![NSFileManager.defaultManager copyItemAtURL:sourceURL toURL:to error:nil]) return; [self.items addObject:@{ @"kind": @"reference", @"id": identifier, @"path": path, @"source_name": sourceName ?: sourceURL.lastPathComponent ?: @"Reference", @"reference_mode": mode ?: @"style", @"added_at": @([[NSDate date] timeIntervalSince1970]) }]; [self persist]; }); }
@end
