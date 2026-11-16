#import "EZLocalFileTools.h"

/// Text files are sent to the model in full up to this many characters
/// (the same ceiling the GitHub tool uses). Over it, the model gets the
/// file's name and size and a clear "too large" result instead of a
/// silently truncated file.
static const NSUInteger kEZLocalFileMaxTextChars = 1000000;
/// Images larger than this are reported, not loaded for the preparer.
static const unsigned long long kEZLocalFileMaxImageBytes = 50ULL * 1024 * 1024;
/// list_local_files never returns more entries than this.
static const NSUInteger kEZLocalFileMaxListEntries = 500;

@implementation EZLocalFileTools

+ (NSString *)attachmentsDirectory {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [documents stringByAppendingPathComponent:@"EZAttachments"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
}

/// All regular files in EZAttachments as @{name, path, size}, sorted by
/// name. Directories and hidden files are skipped.
+ (NSArray<NSDictionary *> *)fileEntries {
    NSString *dir = [self attachmentsDirectory];
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
        [entries addObject:@{
            @"name": name,
            @"path": path,
            @"size": attrs[NSFileSize] ?: @0,
        }];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return [entries copy];
}

+ (NSString *)framed:(NSString *)header body:(NSString *)body {
    return [NSString stringWithFormat:@"[Local file result — %@]\n%@\n[End of local file result]", header, body];
}

+ (NSDictionary *)textResult:(NSString *)header body:(NSString *)body {
    return @{ @"kind": @"text", @"text": [self framed:header body:body] };
}

+ (BOOL)isImageExtension:(NSString *)ext {
    static NSSet<NSString *> *imageExts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageExts = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"heic", @"heif", @"bmp", @"tif", @"tiff"]];
    });
    return [imageExts containsObject:ext];
}

+ (BOOL)isTextExtension:(NSString *)ext {
    static NSSet<NSString *> *textExts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        textExts = [NSSet setWithArray:@[@"txt", @"text", @"md", @"markdown", @"csv", @"tsv", @"json", @"xml",
                                          @"html", @"htm", @"log", @"srt", @"swift", @"m", @"mm", @"h", @"c",
                                          @"cc", @"cpp", @"hpp", @"py", @"js", @"ts", @"sh", @"yaml", @"yml",
                                          @"toml", @"ini", @"cfg", @"conf", @"plist", @"strings", @"rtf"]];
    });
    return [textExts containsObject:ext];
}

+ (void)executeRequest:(NSDictionary *)request
            completion:(void (^)(NSDictionary *result))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self runRequest:request];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}

+ (NSDictionary *)runRequest:(NSDictionary *)request {
    NSString *tool = [request[@"tool"] isKindOfClass:[NSString class]] ? request[@"tool"] : @"";
    if ([tool isEqualToString:@"list_local_files"]) return [self runList:request];
    if ([tool isEqualToString:@"read_local_file"]) return [self runRead:request];
    return [self textResult:@"local file: error"
                       body:@"Unknown local file tool. Nothing was read."];
}

+ (NSDictionary *)runList:(NSDictionary *)request {
    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : nil;
    NSArray<NSDictionary *> *entries = [self fileEntries];
    NSMutableArray<NSDictionary *> *shown = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        if (query.length && [entry[@"name"] rangeOfString:query
                                                   options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [shown addObject:entry];
    }
    NSString *header = query.length
        ? [NSString stringWithFormat:@"list_local_files matching \"%@\"", query]
        : @"list_local_files";
    if (!shown.count) {
        return [self textResult:header body:query.length
            ? [NSString stringWithFormat:@"No files in EZAttachments match \"%@\".", query]
            : @"EZAttachments is empty: there are no files to read."];
    }
    NSMutableString *body = [NSMutableString stringWithFormat:@"%lu file%@ in EZAttachments%@:\n",
        (unsigned long)shown.count, shown.count == 1 ? @"" : @"s",
        query.length ? [NSString stringWithFormat:@" matching \"%@\"", query] : @""];
    NSUInteger limit = MIN(shown.count, kEZLocalFileMaxListEntries);
    for (NSUInteger i = 0; i < limit; i++) {
        [body appendFormat:@"- %@ (%@ bytes)\n", shown[i][@"name"], shown[i][@"size"]];
    }
    if (shown.count > limit) {
        [body appendFormat:@"…and %lu more (list truncated).", (unsigned long)(shown.count - limit)];
    }
    return [self textResult:header body:[body stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
}

+ (NSDictionary *)runRead:(NSDictionary *)request {
    NSString *name = [request[@"name"] isKindOfClass:[NSString class]] ? request[@"name"] : @"";
    NSString *header = [NSString stringWithFormat:@"read_local_file: %@", name.length ? name : @"(no name)"];

    // A plain file name only. This is the traversal guard: nothing with
    // a path separator or a parent reference is ever resolved.
    if (!name.length || [name containsString:@"/"] || [name containsString:@".."]) {
        return [self textResult:@"read_local_file: error"
                           body:@"That is not a plain file name, so nothing was read. Ask for a file by its name only — use list_local_files to see the names."];
    }

    NSArray<NSDictionary *> *entries = [self fileEntries];
    NSDictionary *match = nil;
    for (NSDictionary *entry in entries) {
        if ([entry[@"name"] isEqualToString:name]) { match = entry; break; }
    }
    if (!match) {
        for (NSDictionary *entry in entries) {
            if ([entry[@"name"] caseInsensitiveCompare:name] == NSOrderedSame) { match = entry; break; }
        }
    }
    if (!match) {
        NSMutableArray<NSDictionary *> *partial = [NSMutableArray array];
        for (NSDictionary *entry in entries) {
            if ([entry[@"name"] rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [partial addObject:entry];
            }
        }
        if (partial.count == 1) {
            match = partial.firstObject;
        } else if (partial.count > 1) {
            NSMutableString *body = [NSMutableString stringWithFormat:
                @"Several files match \"%@\". Ask again with one exact name:\n", name];
            NSUInteger limit = MIN(partial.count, (NSUInteger)20);
            for (NSUInteger i = 0; i < limit; i++) {
                [body appendFormat:@"- %@ (%@ bytes)\n", partial[i][@"name"], partial[i][@"size"]];
            }
            return [self textResult:@"read_local_file: error"
                               body:[body stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
        }
    }
    if (!match) {
        return [self textResult:@"read_local_file: error"
                           body:[NSString stringWithFormat:
            @"No file named \"%@\" is in EZAttachments. Use list_local_files to see what is there.", name]];
    }

    NSString *fileName = match[@"name"];
    unsigned long long byteSize = [match[@"size"] unsignedLongLongValue];
    NSString *ext = fileName.pathExtension.lowercaseString;

    if ([self isImageExtension:ext]) {
        if (byteSize > kEZLocalFileMaxImageBytes) {
            return [self textResult:header body:[NSString stringWithFormat:
                @"[Local file: %@ — %llu bytes]\nThis image is too large to send as image context, so it was not attached.", fileName, byteSize]];
        }
        NSData *data = [NSData dataWithContentsOfFile:match[@"path"]];
        if (!data) {
            return [self textResult:@"read_local_file: error"
                               body:[NSString stringWithFormat:@"%@ could not be read.", fileName]];
        }
        return @{ @"kind": @"image",
                  @"fileName": fileName,
                  @"data": data,
                  @"extension": ext.length ? ext : @"jpg",
                  @"byteSize": @(byteSize) };
    }

    NSData *data = [NSData dataWithContentsOfFile:match[@"path"]];
    if (!data) {
        return [self textResult:@"read_local_file: error"
                           body:[NSString stringWithFormat:@"%@ could not be read.", fileName]];
    }

    NSString *text = nil;
    if ([self isTextExtension:ext]) {
        text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
            ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    } else if (!memchr(data.bytes, 0, MIN(data.length, (NSUInteger)8192))) {
        // Unknown type: treat as text only when it decodes cleanly as
        // UTF-8 and has no NUL bytes — otherwise it is binary and its
        // raw bytes are never dumped into the conversation.
        text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    if (!text) {
        NSString *typeLabel = ext.length ? [ext uppercaseString] : @"unknown type";
        return [self textResult:header body:[NSString stringWithFormat:
            @"[Local file: %@ — %llu bytes]\nThis is a binary file (%@); its contents were not sent.", fileName, byteSize, typeLabel]];
    }
    if (text.length > kEZLocalFileMaxTextChars) {
        return [self textResult:header body:[NSString stringWithFormat:
            @"[Local file: %@ — %llu bytes]\nThis file's text is %lu characters, over the 1,000,000-character limit, so its contents were not sent.",
            fileName, byteSize, (unsigned long)text.length]];
    }
    return [self textResult:header body:[NSString stringWithFormat:
        @"[Local file: %@ — %llu bytes]\n%@", fileName, byteSize, text]];
}

@end
