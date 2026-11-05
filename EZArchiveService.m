// EZArchiveService.m
// EZCompleteUI

#import "EZArchiveService.h"
#import "SSZipArchive/SSZipArchive.h"
#import "SSZipArchive/SSZipCommon.h"
#import "SSZipArchive/minizip/mz_compat.h"

#import <sys/stat.h>
#import <zlib.h>

NSErrorDomain const EZArchiveServiceErrorDomain = @"EZArchiveService";
NSString * const EZArchiveServiceCompressionFormatKey = @"EZCompressionFormat";

NS_ASSUME_NONNULL_BEGIN

/// Byte source for the tar parser: a bounded range of a file, either
/// raw or gzip-inflated. tar files are stream formats — no seeking —
/// so the parser pulls exact byte counts through this reader whether
/// the source is a whole .tar.gz or one member inside a .deb.
@interface EZTarByteReader : NSObject
@property (nonatomic, strong) NSFileHandle *handle;
@property (nonatomic, assign) uint64_t compressedRemaining;
@property (nonatomic, assign) uint64_t totalLength;   // decompressed total if known (plain), else compressed size
@property (nonatomic, assign) uint64_t consumed;      // decompressed bytes served
@property (nonatomic, assign) BOOL gzip;
@property (nonatomic, assign) z_stream stream;
@property (nonatomic, assign) BOOL streamReady;
@property (nonatomic, strong) NSMutableData *carry;   // inflated bytes awaiting consumption
@property (nonatomic, assign) NSUInteger carryOffset;
@property (nonatomic, assign) BOOL inputEOF;
@property (nonatomic, strong, nullable) NSData *inChunkData; // current gzip input chunk — retained so _stream.next_in stays valid across fills
- (nullable instancetype)initWithFileHandle:(NSFileHandle *)handle
                                     offset:(uint64_t)offset
                                     length:(uint64_t)length
                                       gzip:(BOOL)gzip;
/// Reads exactly `length` bytes; NO when the stream ends first.
- (BOOL)readBytes:(void *)buffer length:(NSUInteger)length;
- (BOOL)skipBytes:(uint64_t)count;
- (double)progressFraction;
@end

@implementation EZTarByteReader

- (nullable instancetype)initWithFileHandle:(NSFileHandle *)handle
                                     offset:(uint64_t)offset
                                     length:(uint64_t)length
                                       gzip:(BOOL)gzip {
    self = [super init];
    if (self) {
        _handle = handle;
        _compressedRemaining = length;
        _totalLength = length;
        _gzip = gzip;
        _carry = [NSMutableData data];
        NSError *error = nil;
        [handle seekToOffset:offset error:&error];
        if (error) return nil;
        if (gzip) {
            _stream.zalloc = Z_NULL;
            _stream.zfree = Z_NULL;
            _stream.opaque = Z_NULL;
            _stream.avail_in = 0;
            _stream.next_in = Z_NULL;
            // 16 + MAX_WBITS selects the gzip wrapper (vs raw zlib).
            if (inflateInit2(&_stream, 16 + MAX_WBITS) != Z_OK) return nil;
            _streamReady = YES;
        }
    }
    return self;
}

- (void)dealloc {
    if (_streamReady) inflateEnd(&_stream);
}

/// Ensures the carry buffer holds at least one byte, or returns NO at
/// end of stream. Plain mode reads straight through and does not use
/// the carry for serving (see readBytes), so this is gzip-only work.
- (BOOL)ez_fillCarry {
    if (self.carryOffset < self.carry.length) return YES;
    [self.carry setLength:0];
    self.carryOffset = 0;
    if (self.inputEOF) return NO;
    uint8_t outChunk[64 * 1024];
    while (self.carry.length == 0) {
        if (_stream.avail_in == 0) {
            if (self.compressedRemaining == 0) { self.inputEOF = YES; return NO; }
            NSUInteger toRead = (NSUInteger)MIN((uint64_t)(32 * 1024),
                                                self.compressedRemaining);
            NSData *data = [self.handle readDataUpToLength:toRead error:nil];
            if (!data.length) { self.inputEOF = YES; return NO; }
            self.compressedRemaining -= data.length;
            // Retained, not a stack buffer: inflate keeps _stream.next_in
            // across calls whenever it stops with input unconsumed
            // (a 32 KB chunk inflating past the 64 KB output buffer),
            // so the chunk must outlive this stack frame.
            self.inChunkData = data;
            _stream.next_in = (Bytef *)self.inChunkData.bytes;
            _stream.avail_in = (uInt)data.length;
        }
        _stream.next_out = outChunk;
        _stream.avail_out = sizeof(outChunk);
        uInt availInBefore = _stream.avail_in;
        int result = inflate(&_stream, Z_NO_FLUSH);
        NSUInteger produced = sizeof(outChunk) - _stream.avail_out;
        if (produced) [self.carry appendBytes:outChunk length:produced];
        if (result == Z_BUF_ERROR && produced == 0 &&
            _stream.avail_in == availInBefore) {
            return NO; // no progress possible — corrupt stream
        }
        if (result == Z_STREAM_END) { self.inputEOF = YES; break; }
        if (result != Z_OK && result != Z_BUF_ERROR) return NO;
        if (result == Z_BUF_ERROR && _stream.avail_in == 0 &&
            self.compressedRemaining == 0) {
            self.inputEOF = YES;
            return self.carry.length > 0;
        }
    }
    return self.carry.length > 0;
}

- (BOOL)readBytes:(void *)buffer length:(NSUInteger)length {
    uint8_t *out = (uint8_t *)buffer;
    NSUInteger done = 0;
    while (done < length) {
        if (!self.gzip) {
            uint64_t want = MIN((uint64_t)(length - done), self.compressedRemaining);
            if (want == 0) return NO;
            NSData *data = [self.handle readDataUpToLength:(NSUInteger)want error:nil];
            if (!data.length) return NO;
            memcpy(out + done, data.bytes, data.length);
            self.compressedRemaining -= data.length;
            self.consumed += data.length;
            done += data.length;
            continue;
        }
        if (![self ez_fillCarry]) return NO;
        NSUInteger available = self.carry.length - self.carryOffset;
        NSUInteger take = MIN(available, length - done);
        memcpy(out + done, (const uint8_t *)self.carry.bytes + self.carryOffset, take);
        self.carryOffset += take;
        self.consumed += take;
        done += take;
    }
    return YES;
}

- (BOOL)skipBytes:(uint64_t)count {
    uint8_t scratch[32 * 1024];
    while (count > 0) {
        NSUInteger step = (NSUInteger)MIN((uint64_t)sizeof(scratch), count);
        if (![self readBytes:scratch length:step]) return NO;
        count -= step;
    }
    return YES;
}

- (double)progressFraction {
    if (!self.gzip) {
        if (self.totalLength == 0) return 0;
        return (double)self.consumed / (double)self.totalLength;
    }
    // Gzip: the decompressed total is unknown up front; the compressed
    // position is the honest proxy.
    uint64_t total = self.totalLength;
    if (total == 0) return 0;
    uint64_t compressedRead = total - self.compressedRemaining;
    return (double)compressedRead / (double)total;
}

@end

@interface EZArchiveService ()
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (atomic, assign) BOOL cancelRequested;
@end

@implementation EZArchiveService

+ (instancetype)sharedService {
    static EZArchiveService *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[EZArchiveService alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _workQueue = dispatch_queue_create("com.i0stweak3r.ezcompleteui.archive",
                                           DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSError *)ez_error:(EZArchiveServiceError)code {
    NSString *message;
    switch (code) {
        case EZArchiveServiceErrorWrongPassword:
            message = @"Wrong password"; break;
        case EZArchiveServiceErrorCorruptArchive:
            message = @"The archive is damaged or isn't a ZIP file"; break;
        case EZArchiveServiceErrorCreateFailed:
            message = @"Couldn't create the archive"; break;
        case EZArchiveServiceErrorWriteFailed:
            message = @"Couldn't write extracted data"; break;
        case EZArchiveServiceErrorCancelled:
            message = @"Cancelled"; break;
        case EZArchiveServiceErrorUnsupportedCompression:
            message = @"Unsupported compression"; break;
    }
    return [NSError errorWithDomain:EZArchiveServiceErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

#pragma mark - Password checks

+ (BOOL)archiveRequiresPassword:(NSURL *)archiveURL {
    unzFile uf = unzOpen64(archiveURL.fileSystemRepresentation);
    if (!uf) return NO;
    BOOL required = NO;
    unz_global_info64 gi;
    if (unzGetGlobalInfo64(uf, &gi) == UNZ_OK) {
        for (ZPOS64_T i = 0; i < gi.number_entry; i++) {
            if (i > 0 && unzGoToNextFile(uf) != UNZ_OK) break;
            unz_file_info64 info;
            if (unzGetCurrentFileInfo64(uf, &info, NULL, 0, NULL, 0, NULL, 0) == UNZ_OK &&
                (info.flag & 0x1)) {
                required = YES;
                break;
            }
        }
    }
    unzClose(uf);
    return required;
}

+ (BOOL)isPasswordValid:(NSString *)password forArchiveAtURL:(NSURL *)archiveURL {
    return [SSZipArchive isPasswordValidForArchiveAtPath:archiveURL.path
                                                password:password
                                                   error:nil];
}

#pragma mark - Extraction

- (void)extractZIPAtURL:(NSURL *)archiveURL
          toDirectory:(NSURL *)destinationDirectory
             password:(nullable NSString *)password
             progress:(nullable EZArchiveProgressBlock)progress
           completion:(EZArchiveExtractCompletion)completion {
    dispatch_async(self.workQueue, ^{
        self.cancelRequested = NO;
        NSMutableArray<NSString *> *skipped = [NSMutableArray array];
        NSError *error = [self ez_extractZIPAtURL:archiveURL
                                    toDirectory:destinationDirectory
                                       password:password
                                       progress:progress
                                        skipped:skipped];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error == nil, skipped, error);
        });
    });
}

/// The extraction loop. Returns nil on success, else the error.
/// Entries are processed strictly in archive order; any entry whose
/// standardized destination escapes the target folder is skipped and
/// reported rather than written (zip-slip). Symlink entries are
/// skipped for the same reason — recreating links from an archive is
/// how "harmless" archives plant pointers outside the folder.
- (nullable NSError *)ez_extractZIPAtURL:(NSURL *)archiveURL
                           toDirectory:(NSURL *)destination
                              password:(nullable NSString *)password
                              progress:(nullable EZArchiveProgressBlock)progress
                               skipped:(NSMutableArray<NSString *> *)skipped {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtURL:destination
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *destPath = destination.path.stringByStandardizingPath;

    unzFile uf = unzOpen64(archiveURL.fileSystemRepresentation);
    if (!uf) return [self ez_error:EZArchiveServiceErrorCorruptArchive];

    NSError *failure = nil;
    unz_global_info64 gi;
    if (unzGetGlobalInfo64(uf, &gi) != UNZ_OK) {
        unzClose(uf);
        return [self ez_error:EZArchiveServiceErrorCorruptArchive];
    }
    if (self.cancelRequested) {
        unzClose(uf);
        return [self ez_error:EZArchiveServiceErrorCancelled];
    }
    long total = (long)gi.number_entry;
    const char *passwordC = password.UTF8String;

    for (long i = 0; i < total && !failure; i++) {
        if (i > 0 && unzGoToNextFile(uf) != UNZ_OK) break;

        char nameBuffer[8192];
        unz_file_info64 info;
        if (unzGetCurrentFileInfo64(uf, &info, nameBuffer, sizeof(nameBuffer),
                                    NULL, 0, NULL, 0) != UNZ_OK) {
            failure = [self ez_error:EZArchiveServiceErrorCorruptArchive];
            break;
        }
        NSString *entryName = [self ez_entryNameFromRaw:nameBuffer
                                                   flag:info.flag];
        if (!entryName.length) {
            [skipped addObject:NSLocalizedString(@"EZFileExplorer.UnnamedEntry",
                                                 @"Unnamed entry")];
            continue;
        }
        BOOL isDirectory = [entryName hasSuffix:@"/"];
        // Unix mode lives in the top half of external_fa when the
        // archive was made on a unix host (version_madeby >> 8 == 3).
        BOOL madeOnUnix = ((info.version >> 8) == 3);
        mode_t unixMode = madeOnUnix ? (mode_t)(info.external_fa >> 16) : 0;

        NSString *fullPath = [[destPath stringByAppendingPathComponent:entryName]
            stringByStandardizingPath];
        BOOL escapes = ![fullPath isEqualToString:destPath] &&
                       ![fullPath hasPrefix:[destPath stringByAppendingString:@"/"]];
        if (escapes || (unixMode && S_ISLNK(unixMode))) {
            [skipped addObject:entryName];
            continue;
        }

        if (progress) {
            NSString *name = entryName;
            double fraction = (double)i / (double)total;
            dispatch_async(dispatch_get_main_queue(), ^{
                progress(fraction, name);
            });
        }

        if (isDirectory) {
            [fm createDirectoryAtPath:fullPath
                withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        [fm createDirectoryAtPath:fullPath.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];

        int openResult = unzOpenCurrentFilePassword(uf, passwordC);
        if (openResult != UNZ_OK) {
            failure = [self ez_error:(openResult == UNZ_BADPASSWORD ||
                                       (info.flag & 0x1))
                ? EZArchiveServiceErrorWrongPassword
                : EZArchiveServiceErrorCorruptArchive];
            break;
        }

        // Create-or-truncate first: two entries can legitimately share
        // a name, and an untruncated open would leave a stale tail.
        if (![fm createFileAtPath:fullPath contents:nil attributes:nil]) {
            unzCloseCurrentFile(uf);
            failure = [self ez_error:EZArchiveServiceErrorWriteFailed];
            break;
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:fullPath];
        if (!handle) {
            unzCloseCurrentFile(uf);
            failure = [self ez_error:EZArchiveServiceErrorWriteFailed];
            break;
        }
        static const uint32_t kChunk = 64 * 1024;
        void *buffer = malloc(kChunk);
        int readResult;
        BOOL writeOK = YES;
        while (!self.cancelRequested &&
               (readResult = unzReadCurrentFile(uf, buffer, kChunk)) > 0) {
            @autoreleasepool {
                NSData *chunk = [NSData dataWithBytesNoCopy:buffer
                                                     length:(NSUInteger)readResult
                                               freeWhenDone:NO];
                if (![handle writeData:chunk error:nil]) { writeOK = NO; break; }
            }
        }
        free(buffer);
        if (self.cancelRequested) {
            [handle closeFile];
            unzCloseCurrentFile(uf);
            [fm removeItemAtPath:fullPath error:nil];
            failure = [self ez_error:EZArchiveServiceErrorCancelled];
            break;
        }
        if (!writeOK) {
            [handle closeFile];
            unzCloseCurrentFile(uf);
            [fm removeItemAtPath:fullPath error:nil];
            failure = [self ez_error:EZArchiveServiceErrorWriteFailed];
            break;
        }
        [handle closeFile];
        int closeResult = unzCloseCurrentFile(uf);
        if (readResult < 0 || closeResult == UNZ_CRCERROR) {
            // A CRC failure on an encrypted entry overwhelmingly means
            // the password was wrong (ZipCrypto detects it only here);
            // on a plain entry it means the archive is damaged. Remove
            // the partial file either way — a truncated extraction that
            // looks complete is worse than an absent one.
            [fm removeItemAtPath:fullPath error:nil];
            BOOL encrypted = (info.flag & 0x1) != 0;
            failure = [self ez_error:(encrypted && password.length)
                ? EZArchiveServiceErrorWrongPassword
                : EZArchiveServiceErrorCorruptArchive];
            break;
        }
        if (unixMode) {
            mode_t permissions = unixMode & 0777;
            if (permissions) {
                [fm setAttributes:@{ NSFilePosixPermissions: @(permissions) }
                     ofItemAtPath:fullPath error:nil];
            }
        }
    }

    unzClose(uf);
    if (!failure && progress) {
        dispatch_async(dispatch_get_main_queue(), ^{ progress(1.0, @""); });
    }
    return failure;
}

/// Entry names are UTF-8 when flag bit 11 is set; legacy archives are
/// usually CP437. Decode accordingly instead of showing mojibake or,
/// worse, standardizing the wrong string for the zip-slip check.
- (NSString *)ez_entryNameFromRaw:(const char *)raw flag:(uint16_t)flag {
    NSData *data = [NSData dataWithBytes:raw length:strlen(raw)];
    NSStringEncoding encoding;
    if (flag & (1 << 11)) {
        encoding = NSUTF8StringEncoding;
    } else {
        encoding = CFStringConvertEncodingToNSStringEncoding(
            kCFStringEncodingDOSLatinUS); // CP437
    }
    NSString *name = [[NSString alloc] initWithData:data encoding:encoding];
    if (!name) {
        name = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return name ?: @"";
}

#pragma mark - Creation

- (void)createZIPAtURL:(NSURL *)destinationURL
          fromItemURLs:(NSArray<NSURL *> *)itemURLs
              progress:(nullable EZArchiveProgressBlock)progress
            completion:(EZArchiveCreateCompletion)completion {
    dispatch_async(self.workQueue, ^{
        self.cancelRequested = NO;
        NSError *error = [self ez_createZIPAtURL:destinationURL
                                   fromItemURLs:itemURLs
                                       progress:progress];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error == nil, error);
        });
    });
}

/// Builds the write list first (path + archive name pairs, folders
/// included so empty folders survive), then drives SSZipArchive's
/// instance writer over it — progress is exact because the total is
/// known before the first byte is written.
- (nullable NSError *)ez_createZIPAtURL:(NSURL *)destinationURL
                         fromItemURLs:(NSArray<NSURL *> *)itemURLs
                             progress:(nullable EZArchiveProgressBlock)progress {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSURL *item in itemURLs) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:item.path isDirectory:&isDir]) continue;
        if (!isDir) {
            [entries addObject:@{ @"path": item.path,
                                  @"arc": item.lastPathComponent,
                                  @"dir": @NO }];
            continue;
        }
        // Folder: store it rooted at its own name, structure preserved.
        NSString *rootPath = item.path;
        NSString *parent = rootPath.stringByDeletingLastPathComponent;
        NSDirectoryEnumerator<NSURL *> *enumerator =
            [fm enumeratorAtURL:item
                includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                   options:0
                              errorHandler:nil];
        NSMutableArray<NSURL *> *children = [NSMutableArray array];
        for (NSURL *child in enumerator) [children addObject:child];
        [children sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.path compare:b.path];
        }];
        [entries addObject:@{ @"path": rootPath,
                              @"arc": item.lastPathComponent,
                              @"dir": @YES }];
        for (NSURL *child in children) {
            NSString *relative = [child.path substringFromIndex:parent.length + 1];
            NSNumber *childIsDir = nil;
            [child getResourceValue:&childIsDir forKey:NSURLIsDirectoryKey error:nil];
            [entries addObject:@{ @"path": child.path,
                                  @"arc": relative,
                                  @"dir": childIsDir ?: @NO }];
        }
    }
    if (!entries.count) return [self ez_error:EZArchiveServiceErrorCreateFailed];

    [fm removeItemAtURL:destinationURL error:nil]; // replaced, per header docs
    SSZipArchive *zip = [[SSZipArchive alloc] initWithPath:destinationURL.path];
    if (![zip open]) return [self ez_error:EZArchiveServiceErrorCreateFailed];
    NSUInteger total = entries.count;
    NSUInteger index = 0;
    BOOL ok = YES;
    for (NSDictionary *entry in entries) {
        if (self.cancelRequested) {
            [zip close];
            [fm removeItemAtURL:destinationURL error:nil];
            return [self ez_error:EZArchiveServiceErrorCancelled];
        }
        NSString *path = entry[@"path"];
        NSString *arc = entry[@"arc"];
        BOOL success;
        if ([entry[@"dir"] boolValue]) {
            success = [zip writeFolderAtPath:path
                              withFolderName:arc
                                withPassword:nil];
        } else {
            success = [zip writeFileAtPath:path
                              withFileName:arc
                              withPassword:nil];
        }
        if (!success) { ok = NO; break; }
        index++;
        if (progress) {
            double fraction = (double)index / (double)total;
            dispatch_async(dispatch_get_main_queue(), ^{
                progress(fraction, arc);
            });
        }
    }
    if (![zip close] && ok) ok = NO;
    if (!ok) {
        [fm removeItemAtURL:destinationURL error:nil];
        return [self ez_error:EZArchiveServiceErrorCreateFailed];
    }
    return nil;
}

- (void)cancelCurrentOperation {
    self.cancelRequested = YES;
}

- (NSError *)ez_unsupportedErrorWithFormat:(NSString *)format {
    return [NSError errorWithDomain:EZArchiveServiceErrorDomain
                               code:EZArchiveServiceErrorUnsupportedCompression
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
            @"Unsupported compression: %@", format],
        EZArchiveServiceCompressionFormatKey: format,
    }];
}

#pragma mark - tar field parsing

/// tar numeric fields are ASCII octal, space/NUL padded — except GNU
/// base-256 for very large sizes, signaled by the top bit of the
/// first byte.
static uint64_t EZTarParseNumber(const uint8_t *field, NSUInteger length) {
    if (length && (field[0] & 0x80)) {
        uint64_t value = field[0] & 0x7F;
        for (NSUInteger i = 1; i < length; i++) {
            value = (value << 8) | field[i];
        }
        return value;
    }
    uint64_t value = 0;
    for (NSUInteger i = 0; i < length; i++) {
        uint8_t c = field[i];
        if (c == 0 || c == ' ') {
            if (value) break;
            continue;
        }
        if (c < '0' || c > '7') break;
        value = (value << 3) | (uint64_t)(c - '0');
    }
    return value;
}

static NSString *EZTarParseString(const uint8_t *field, NSUInteger length) {
    NSUInteger actual = 0;
    while (actual < length && field[actual] != 0) actual++;
    return [[NSString alloc] initWithBytes:field
                                    length:actual
                                  encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithBytes:field
                                    length:actual
                                  encoding:NSISOLatin1StringEncoding]
        ?: @"";
}

#pragma mark - tar extraction

- (void)extractTarAtURL:(NSURL *)archiveURL
          toDirectory:(NSURL *)destinationDirectory
             progress:(nullable EZArchiveProgressBlock)progress
           completion:(EZArchiveExtractCompletion)completion {
    dispatch_async(self.workQueue, ^{
        self.cancelRequested = NO;
        NSMutableArray<NSString *> *skipped = [NSMutableArray array];
        NSError *error = [self ez_extractTarFileAtURL:archiveURL
                                        toDirectory:destinationDirectory
                                            skipped:skipped
                                           progress:progress];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error == nil, skipped, error);
        });
    });
}

- (nullable NSError *)ez_extractTarFileAtURL:(NSURL *)archiveURL
                               toDirectory:(NSURL *)destination
                                   skipped:(NSMutableArray<NSString *> *)skipped
                                  progress:(nullable EZArchiveProgressBlock)progress {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:archiveURL.path];
    if (!handle) return [self ez_error:EZArchiveServiceErrorCorruptArchive];
    uint64_t fileSize = 0;
    if (![handle seekToEndReturningOffset:&fileSize error:nil]) {
        return [self ez_error:EZArchiveServiceErrorCorruptArchive];
    }
    [handle seekToOffset:0 error:nil];
    // Gzip is detected by magic bytes, not by trusting the extension.
    NSData *magic = [handle readDataUpToLength:2 error:nil];
    BOOL gzip = magic.length == 2 &&
        ((const uint8_t *)magic.bytes)[0] == 0x1F &&
        ((const uint8_t *)magic.bytes)[1] == 0x8B;
    [handle seekToOffset:0 error:nil];
    EZTarByteReader *reader = [[EZTarByteReader alloc]
        initWithFileHandle:handle offset:0 length:fileSize gzip:gzip];
    if (!reader) return [self ez_error:EZArchiveServiceErrorCorruptArchive];
    return [self ez_extractTarReader:reader
                       toDirectory:destination
                           skipped:skipped
                          progress:progress];
}

/// The ustar walk. Header blocks are 512 bytes; file data follows,
/// padded to a 512 multiple. GNU 'L'/'K' long-name records and pax
/// 'x' path records apply to the next real entry. Everything the ZIP
/// path refuses — escaping paths, symlinks, hardlinks — is refused
/// here too, plus device/fifo nodes, which have no business being
/// recreated from an archive.
- (nullable NSError *)ez_extractTarReader:(EZTarByteReader *)reader
                            toDirectory:(NSURL *)destination
                                skipped:(NSMutableArray<NSString *> *)skipped
                               progress:(nullable EZArchiveProgressBlock)progress {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtURL:destination
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *destPath = destination.path.stringByStandardizingPath;

    NSString *pendingName = nil;
    NSMutableArray<NSDictionary *> *directoryFixups = [NSMutableArray array];
    uint8_t header[512];
    uint8_t chunk[64 * 1024];

    while (!self.cancelRequested) {
        if (![reader readBytes:header length:sizeof(header)]) {
            // Sloppy tars end right after the last padded entry
            // instead of with the two zero blocks. Data already
            // written is complete at that point, so a stream that
            // ends exactly on a header boundary counts as finished;
            // an archive that yields nothing at all does not.
            if (reader.consumed == 0) {
                return [self ez_error:EZArchiveServiceErrorCorruptArchive];
            }
            break;
        }
        BOOL allZero = YES;
        for (NSUInteger i = 0; i < sizeof(header); i++) {
            if (header[i] != 0) { allZero = NO; break; }
        }
        if (allZero) break;

        // Header checksum: the checksum field itself counts as spaces.
        // Old tars may have used signed char arithmetic — accept both.
        uint64_t storedChecksum = EZTarParseNumber(header + 148, 8);
        int64_t unsignedSum = 0, signedSum = 0;
        for (NSUInteger i = 0; i < sizeof(header); i++) {
            uint8_t byte = (i >= 148 && i < 156) ? (uint8_t)' ' : header[i];
            unsignedSum += byte;
            signedSum += (int8_t)byte;
        }
        if ((uint64_t)unsignedSum != storedChecksum &&
            signedSum != (int64_t)storedChecksum) {
            return [self ez_error:EZArchiveServiceErrorCorruptArchive];
        }

        uint64_t size = EZTarParseNumber(header + 124, 12);
        uint64_t mode = EZTarParseNumber(header + 100, 8);
        uint64_t mtime = EZTarParseNumber(header + 136, 12);
        uint8_t typeflag = header[156];
        NSString *name = EZTarParseString(header, 100);
        BOOL isUstar = memcmp(header + 257, "ustar", 5) == 0;
        if (isUstar) {
            NSString *prefix = EZTarParseString(header + 345, 155);
            if (prefix.length) name = [prefix stringByAppendingPathComponent:name];
        }
        uint64_t paddedSize = ((size + 511) / 512) * 512;

        if (typeflag == 'L' || typeflag == 'K' || typeflag == 'x' || typeflag == 'g') {
            // Name-bearing records: payload first, header rules after.
            NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)size];
            if (size > 0 && ![reader readBytes:payload.mutableBytes
                                        length:(NSUInteger)size]) {
                return [self ez_error:EZArchiveServiceErrorCorruptArchive];
            }
            if (paddedSize > size &&
                ![reader skipBytes:paddedSize - size]) {
                return [self ez_error:EZArchiveServiceErrorCorruptArchive];
            }
            if (typeflag == 'L') {
                pendingName = EZTarParseString(payload.bytes,
                                               (NSUInteger)payload.length);
            } else if (typeflag == 'x') {
                NSString *path = [self ez_paxPathFromData:payload];
                if (path) pendingName = path;
            }
            // 'K' (long link name) and 'g' (global pax) need no state:
            // links are never recreated, and global records carry
            // nothing this extractor honors.
            continue;
        }

        NSString *entryName = pendingName.length ? pendingName : name;
        pendingName = nil;
        if (!entryName.length) {
            [skipped addObject:NSLocalizedString(@"EZFileExplorer.UnnamedEntry",
                                                 @"Unnamed entry")];
            if (![reader skipBytes:paddedSize]) break;
            continue;
        }

        if (progress) {
            NSString *entry = entryName;
            double fraction = [reader progressFraction];
            dispatch_async(dispatch_get_main_queue(), ^{
                progress(fraction, entry);
            });
        }

        NSString *fullPath = [[destPath stringByAppendingPathComponent:entryName]
            stringByStandardizingPath];
        BOOL escapes = ![fullPath isEqualToString:destPath] &&
                       ![fullPath hasPrefix:[destPath stringByAppendingString:@"/"]];
        BOOL isDirectoryEntry = (typeflag == '5') || [entryName hasSuffix:@"/"];
        BOOL isRegular = (typeflag == '0' || typeflag == 0 || typeflag == '7');

        if (escapes || (!isDirectoryEntry && !isRegular)) {
            // Links ('1','2'), devices ('3','4'), fifos ('6'), and
            // anything unrecognized land here — skipped and reported,
            // never recreated.
            [skipped addObject:entryName];
            if (![reader skipBytes:paddedSize]) {
                return [self ez_error:EZArchiveServiceErrorCorruptArchive];
            }
            continue;
        }

        if (isDirectoryEntry) {
            [fm createDirectoryAtPath:fullPath
                withIntermediateDirectories:YES attributes:nil error:nil];
            if (mode & 0777) {
                [fm setAttributes:@{ NSFilePosixPermissions: @(mode & 0777) }
                     ofItemAtPath:fullPath error:nil];
            }
            if (mtime) {
                [directoryFixups addObject:@{
                    @"path": fullPath,
                    @"date": [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)mtime],
                }];
            }
            if (![reader skipBytes:paddedSize]) {
                return [self ez_error:EZArchiveServiceErrorCorruptArchive];
            }
            continue;
        }

        // Regular file: stream exactly `size` bytes out, then padding.
        [fm createDirectoryAtPath:fullPath.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:nil];
        if (![fm createFileAtPath:fullPath contents:nil attributes:nil]) {
            if (![reader skipBytes:paddedSize]) {
                return [self ez_error:EZArchiveServiceErrorCorruptArchive];
            }
            [skipped addObject:entryName];
            continue;
        }
        NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:fullPath];
        if (!out) {
            if (![reader skipBytes:paddedSize]) {
                return [self ez_error:EZArchiveServiceErrorCorruptArchive];
            }
            [skipped addObject:entryName];
            continue;
        }
        uint64_t remainingBytes = size;
        BOOL entryOK = YES;
        while (remainingBytes > 0) {
            if (self.cancelRequested) break;
            NSUInteger step = (NSUInteger)MIN((uint64_t)sizeof(chunk), remainingBytes);
            if (![reader readBytes:chunk length:step]) { entryOK = NO; break; }
            if (![out writeData:[NSData dataWithBytes:chunk length:step]
                          error:nil]) { entryOK = NO; break; }
            remainingBytes -= step;
        }
        [out closeFile];
        if (self.cancelRequested) {
            [fm removeItemAtPath:fullPath error:nil];
            return [self ez_error:EZArchiveServiceErrorCancelled];
        }
        if (!entryOK) {
            [fm removeItemAtPath:fullPath error:nil];
            return [self ez_error:EZArchiveServiceErrorCorruptArchive];
        }
        if (paddedSize > size && ![reader skipBytes:paddedSize - size]) {
            return [self ez_error:EZArchiveServiceErrorCorruptArchive];
        }
        if (mode & 0777) {
            [fm setAttributes:@{ NSFilePosixPermissions: @(mode & 0777) }
                 ofItemAtPath:fullPath error:nil];
        }
        if (mtime) {
            [fm setAttributes:@{
                NSFileModificationDate:
                    [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)mtime] }
                 ofItemAtPath:fullPath error:nil];
        }
    }
    if (self.cancelRequested) {
        return [self ez_error:EZArchiveServiceErrorCancelled];
    }
    // Folder timestamps go on last — writing children into a folder
    // would otherwise bump them right back to "now".
    for (NSDictionary *fixup in directoryFixups) {
        [fm setAttributes:@{ NSFileModificationDate: fixup[@"date"] }
             ofItemAtPath:fixup[@"path"] error:nil];
    }
    if (progress) {
        dispatch_async(dispatch_get_main_queue(), ^{ progress(1.0, @""); });
    }
    return nil;
}

/// Pulls the "path" record out of a pax extended header payload.
/// Records are "<len> <key>=<value>\n" with len covering the record.
- (nullable NSString *)ez_paxPathFromData:(NSData *)data {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    NSUInteger pos = 0;
    NSString *path = nil;
    while (pos < length) {
        NSUInteger recordStart = pos;
        while (pos < length && bytes[pos] != ' ') pos++;
        if (pos >= length) break;
        NSString *lenString = [[NSString alloc]
            initWithBytes:bytes + recordStart
                   length:pos - recordStart
                 encoding:NSASCIIStringEncoding];
        NSUInteger recordLength = (NSUInteger)lenString.integerValue;
        if (recordLength < 3 || recordStart + recordLength > length) break;
        NSUInteger contentStart = pos + 1;
        NSUInteger contentLength = recordLength - (contentStart - recordStart) - 1;
        NSString *record = [[NSString alloc]
            initWithBytes:bytes + contentStart
                   length:contentLength
                 encoding:NSUTF8StringEncoding];
        if ([record hasPrefix:@"path="]) {
            path = [record substringFromIndex:5];
        }
        pos = recordStart + recordLength;
    }
    return path;
}

#pragma mark - deb (ar) extraction

- (void)extractDebAtURL:(NSURL *)archiveURL
          toDirectory:(NSURL *)destinationDirectory
             progress:(nullable EZArchiveProgressBlock)progress
           completion:(EZArchiveExtractCompletion)completion {
    dispatch_async(self.workQueue, ^{
        self.cancelRequested = NO;
        NSMutableArray<NSString *> *skipped = [NSMutableArray array];
        NSError *error = [self ez_extractDebFileAtURL:archiveURL
                                        toDirectory:destinationDirectory
                                            skipped:skipped
                                           progress:progress];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error == nil, skipped, error);
        });
    });
}

/// Two passes over the ar container. Pass 1 walks member headers only
/// (resolving GNU/BSD long names) and gates on inner compression —
/// a deb whose data.tar is xz-compressed fails here, before a single
/// byte is written, with the compression named. Pass 2 extracts:
/// data.tar.* to the destination root, control.tar.* to DEBIAN/,
/// plain members (debian-binary, …) as files.
- (nullable NSError *)ez_extractDebFileAtURL:(NSURL *)archiveURL
                               toDirectory:(NSURL *)destination
                                   skipped:(NSMutableArray<NSString *> *)skipped
                                  progress:(nullable EZArchiveProgressBlock)progress {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:archiveURL.path];
    if (!handle) return [self ez_error:EZArchiveServiceErrorCorruptArchive];
    uint64_t fileSize = 0;
    [handle seekToEndReturningOffset:&fileSize error:nil];
    [handle seekToOffset:0 error:nil];

    NSData *magic = [handle readDataUpToLength:8 error:nil];
    if (magic.length != 8 || memcmp(magic.bytes, "!<arch>\n", 8) != 0) {
        return [self ez_error:EZArchiveServiceErrorCorruptArchive];
    }

    // Pass 1: headers only.
    NSMutableArray<NSDictionary *> *members = [NSMutableArray array];
    NSData *stringTable = nil;
    uint64_t offset = 8;
    while (offset + 60 <= fileSize) {
        [handle seekToOffset:offset error:nil];
        NSData *headerData = [handle readDataUpToLength:60 error:nil];
        if (headerData.length != 60) break;
        const uint8_t *h = (const uint8_t *)headerData.bytes;
        if (h[58] != 0x60 || h[59] != 0x0A) {
            return [self ez_error:EZArchiveServiceErrorCorruptArchive];
        }
        // ar fields are space-padded — the name must be trimmed before
        // any of the "//", "/", "#1/", "/123" scheme checks can match.
        NSString *rawName = [EZTarParseString(h, 16)
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
        uint64_t memberSize = 0;
        {
            NSString *sizeString = EZTarParseString(h + 48, 10);
            memberSize = (uint64_t)strtoull(sizeString.UTF8String, NULL, 10);
        }
        uint64_t dataOffset = offset + 60;
        uint64_t dataSize = memberSize;
        NSString *name = rawName;
        if ([rawName isEqualToString:@"//"]) {
            stringTable = [handle readDataUpToLength:(NSUInteger)memberSize error:nil];
            name = nil; // the table itself is never a payload member
        } else if ([rawName isEqualToString:@"/"]) {
            name = nil; // symbol table — not payload
        } else if ([rawName hasPrefix:@"#1/"]) {
            // BSD long name: the first N bytes of the data are the name.
            NSUInteger nameLength = (NSUInteger)[rawName substringFromIndex:3].integerValue;
            [handle seekToOffset:dataOffset error:nil];
            NSData *nameData = [handle readDataUpToLength:nameLength error:nil];
            name = [[NSString alloc] initWithData:nameData
                                         encoding:NSUTF8StringEncoding] ?: @"";
            dataOffset += nameLength;
            dataSize -= nameLength;
        } else if ([rawName hasPrefix:@"/"] && rawName.length > 1) {
            // GNU long name: offset into the string table.
            NSUInteger tableOffset = (NSUInteger)[rawName substringFromIndex:1].integerValue;
            if (stringTable && tableOffset < stringTable.length) {
                const uint8_t *table = (const uint8_t *)stringTable.bytes;
                NSUInteger end = tableOffset;
                while (end < stringTable.length && table[end] != '\n' && table[end] != 0) end++;
                NSString *tableName = [[NSString alloc]
                    initWithBytes:table + tableOffset
                           length:end - tableOffset
                         encoding:NSUTF8StringEncoding];
                if ([tableName hasSuffix:@"/"]) {
                    tableName = [tableName substringToIndex:tableName.length - 1];
                }
                name = tableName;
            }
        } else if ([name hasSuffix:@"/"]) {
            name = [name substringToIndex:name.length - 1]; // GNU trailing slash
        }
        if (name.length) {
            [members addObject:@{ @"name": name,
                                  @"offset": @(dataOffset),
                                  @"size": @(dataSize) }];
            // Compression gate, before anything is written.
            NSString *format = [self ez_unsupportedTarCompressionForMemberName:name];
            if (format) return [self ez_unsupportedErrorWithFormat:format];
        }
        // Next member: members pad to an even offset with a '\n'. In
        // every naming scheme dataOffset + dataSize lands exactly on
        // the end of this member's data span (BSD names live inside
        // the span), so one expression covers all of them.
        offset = dataOffset + dataSize + (memberSize % 2);
    }
    if (!members.count) {
        return [self ez_error:EZArchiveServiceErrorCorruptArchive];
    }

    // Pass 2: extract.
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSDictionary *member in members) {
        if (self.cancelRequested) {
            return [self ez_error:EZArchiveServiceErrorCancelled];
        }
        NSString *name = member[@"name"];
        uint64_t dataOffset = [member[@"offset"] unsignedLongLongValue];
        uint64_t dataSize = [member[@"size"] unsignedLongLongValue];
        BOOL isData = [name hasPrefix:@"data.tar"];
        BOOL isControl = [name hasPrefix:@"control.tar"];
        if (isData || isControl) {
            BOOL gzip = [name hasSuffix:@".gz"] || [name hasSuffix:@".gzip"];
            NSURL *target = isControl
                ? [destination URLByAppendingPathComponent:@"DEBIAN"]
                : destination;
            NSFileHandle *memberHandle =
                [NSFileHandle fileHandleForReadingAtPath:archiveURL.path];
            if (!memberHandle) {
                return [self ez_error:EZArchiveServiceErrorCorruptArchive];
            }
            EZTarByteReader *reader = [[EZTarByteReader alloc]
                initWithFileHandle:memberHandle
                            offset:dataOffset
                            length:dataSize
                              gzip:gzip];
            if (!reader) {
                return [self ez_error:EZArchiveServiceErrorCorruptArchive];
            }
            EZArchiveProgressBlock memberProgress = nil;
            if (progress) {
                memberProgress = ^(double fraction, NSString *entry) {
                    double overall = fileSize
                        ? (double)(dataOffset + (uint64_t)(fraction * dataSize)) /
                              (double)fileSize
                        : fraction;
                    progress(overall, entry);
                };
            }
            NSError *error = [self ez_extractTarReader:reader
                                         toDirectory:target
                                             skipped:skipped
                                            progress:memberProgress];
            if (error) return error;
        } else {
            // Plain member (debian-binary and friends): copy the byte
            // range out as a file, with the same containment rule.
            NSString *destPath = destination.path.stringByStandardizingPath;
            NSString *fullPath = [[destPath stringByAppendingPathComponent:name]
                stringByStandardizingPath];
            BOOL escapes = ![fullPath hasPrefix:
                [destPath stringByAppendingString:@"/"]];
            if (escapes) {
                [skipped addObject:name];
                continue;
            }
            [fm createDirectoryAtURL:destination
                withIntermediateDirectories:YES attributes:nil error:nil];
            [handle seekToOffset:dataOffset error:nil];
            NSMutableData *data = [NSMutableData data];
            uint64_t left = dataSize;
            while (left > 0) {
                NSUInteger step = (NSUInteger)MIN((uint64_t)(64 * 1024), left);
                NSData *piece = [handle readDataUpToLength:step error:nil];
                if (!piece.length) break;
                [data appendData:piece];
                left -= piece.length;
            }
            [data writeToFile:fullPath atomically:YES];
        }
    }
    if (progress) {
        dispatch_async(dispatch_get_main_queue(), ^{ progress(1.0, @""); });
    }
    return nil;
}

/// For a deb member name like "data.tar.xz", the display name of the
/// compression the app can't extract yet — or nil when the member is
/// a plain/gzip tar this build handles.
- (nullable NSString *)ez_unsupportedTarCompressionForMemberName:(NSString *)name {
    if (![name containsString:@".tar"]) return nil;
    if ([name hasSuffix:@".tar"] || [name hasSuffix:@".tar.gz"] ||
        [name hasSuffix:@".tgz"] || [name hasSuffix:@".tar.gzip"]) {
        return nil;
    }
    if ([name hasSuffix:@".xz"]) return @"XZ";
    if ([name hasSuffix:@".zst"]) return @"Zstandard";
    if ([name hasSuffix:@".bz2"] || [name hasSuffix:@".bzip2"]) return @"bzip2";
    if ([name hasSuffix:@".lzma"]) return @"LZMA";
    if ([name hasSuffix:@".lz4"]) return @"LZ4";
    return @"unknown";
}

@end

NS_ASSUME_NONNULL_END
