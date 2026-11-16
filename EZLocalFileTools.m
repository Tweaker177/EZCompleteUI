#import "EZLocalFileTools.h"
#import "helpers.h"

/// Text files are sent to the model in full up to this many characters
/// (the same ceiling the GitHub tool uses). Over it, the model gets the
/// file's name and size and a clear "too large" result instead of a
/// silently truncated file.
static const NSUInteger kEZLocalFileMaxTextChars = 1000000;
/// Images larger than this are reported, not loaded for the preparer.
static const unsigned long long kEZLocalFileMaxImageBytes = 50ULL * 1024 * 1024;
/// list_local_files never returns more entries than this.
static const NSUInteger kEZLocalFileMaxListEntries = 500;

/// The folders the local file tools may touch, in search order. Paths
/// shown to the model are always relative to Documents and start with
/// one of these names, e.g. "EZAttachments/notes/plan.md".
static NSArray<NSString *> *EZLocalFileRootNames(void) {
    return @[@"EZAttachments", @"EZPhotoGallery", @"EZSounds", @"EZMusic", @"EZThreads"];
}

@implementation EZLocalFileTools

#pragma mark - Roots and resolution

+ (NSString *)attachmentsDirectory {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [documents stringByAppendingPathComponent:@"EZAttachments"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
}

/// The allowed roots as @{@"name", @"path"}, in search order. Only
/// EZAttachments is created on demand; the others simply contribute
/// nothing until the app has put something in them.
+ (NSArray<NSDictionary *> *)roots {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSMutableArray<NSDictionary *> *roots = [NSMutableArray array];
    for (NSString *name in EZLocalFileRootNames()) {
        NSString *path = nil;
        if ([name isEqualToString:@"EZAttachments"]) {
            path = [self attachmentsDirectory];
        } else if ([name isEqualToString:@"EZPhotoGallery"]) {
            path = EZPhotoGalleryDirectory();
            if (!path.length) path = [documents stringByAppendingPathComponent:name];
        } else {
            path = [documents stringByAppendingPathComponent:name];
        }
        if (path.length) [roots addObject:@{ @"name": name, @"path": path }];
    }
    return [roots copy];
}

+ (NSDictionary *)rootNamed:(NSString *)name {
    for (NSDictionary *root in [self roots]) {
        if ([root[@"name"] caseInsensitiveCompare:name] == NSOrderedSame) return root;
    }
    return nil;
}

/// The one path rule: standardize the requested path, resolve any
/// ".." and symlinks, and the result must still sit inside one of the
/// allowed roots. Returns the resolved absolute path, or nil when the
/// path escapes (or its first component names no allowed root).
/// *rootName receives the canonical root name on success.
+ (NSString *)resolvedPathForRelativePath:(NSString *)relativePath rootName:(NSString **)rootName {
    NSArray<NSString *> *parts = [relativePath componentsSeparatedByString:@"/"];
    if (!parts.count || ![parts.firstObject length]) return nil;
    NSDictionary *root = [self rootNamed:parts.firstObject];
    if (!root) return nil;
    NSString *rest = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"/"];
    NSString *candidate = rest.length ? [root[@"path"] stringByAppendingPathComponent:rest] : root[@"path"];
    NSString *resolved = [[candidate stringByStandardizingPath] stringByResolvingSymlinksInPath];
    NSString *rootResolved = [[root[@"path"] stringByStandardizingPath] stringByResolvingSymlinksInPath];
    if (![resolved isEqualToString:rootResolved] &&
        ![resolved hasPrefix:[rootResolved stringByAppendingString:@"/"]]) return nil;
    if (rootName) *rootName = root[@"name"];
    return resolved;
}

/// The path of `absolute` shown to the model: canonical root name plus
/// the part below the root, e.g. "EZAttachments/notes/plan.md".
+ (NSString *)displayPathForAbsolutePath:(NSString *)absolute root:(NSDictionary *)root {
    NSString *rootResolved = [[root[@"path"] stringByStandardizingPath] stringByResolvingSymlinksInPath];
    if ([absolute isEqualToString:rootResolved]) return root[@"name"];
    if ([absolute hasPrefix:[rootResolved stringByAppendingString:@"/"]]) {
        return [root[@"name"] stringByAppendingPathComponent:[absolute substringFromIndex:rootResolved.length + 1]];
    }
    return absolute.lastPathComponent;
}

#pragma mark - Enumeration

/// Every regular file under one root, recursively, as
/// @{name, full, path, size} where "full" is the model-facing path
/// ("EZAttachments/notes/plan.md"). Hidden files and folders are
/// skipped. Sorted by full path.
+ (NSArray<NSDictionary *> *)fileEntriesInRoot:(NSDictionary *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator<NSString *> *walker = [fm enumeratorAtPath:root[@"path"]];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *rel in walker) {
        if ([rel hasPrefix:@"."] || [rel containsString:@"/."]) { [walker skipDescendants]; continue; }
        NSString *path = [root[@"path"] stringByAppendingPathComponent:rel];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
        [entries addObject:@{
            @"name": rel.lastPathComponent,
            @"full": [root[@"name"] stringByAppendingPathComponent:rel],
            @"path": path,
            @"size": attrs[NSFileSize] ?: @0,
        }];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"full"] localizedCaseInsensitiveCompare:b[@"full"]];
    }];
    return [entries copy];
}

/// The searchable files across all five roots, in root order.
+ (NSArray<NSDictionary *> *)fileEntries {
    NSMutableArray<NSDictionary *> *all = [NSMutableArray array];
    for (NSDictionary *root in [self roots]) {
        [all addObjectsFromArray:[self fileEntriesInRoot:root]];
    }
    return [all copy];
}

#pragma mark - Result framing

+ (NSString *)framed:(NSString *)header body:(NSString *)body {
    return [NSString stringWithFormat:@"[Local file result — %@]\n%@\n[End of local file result]", header, body];
}

+ (NSDictionary *)textResult:(NSString *)header body:(NSString *)body {
    return @{ @"kind": @"text", @"text": [self framed:header body:body] };
}

+ (NSDictionary *)outsideResult:(NSString *)what {
    return [self textResult:@"read_local_file: error" body:[NSString stringWithFormat:
        @"\"%@\" is outside the allowed folders (EZAttachments, EZPhotoGallery, EZSounds, EZMusic, EZThreads), so nothing was read.", what]];
}

+ (NSDictionary *)candidatesResult:(NSArray<NSDictionary *> *)matches asked:(NSString *)asked {
    NSMutableString *body = [NSMutableString stringWithFormat:
        @"Several files match \"%@\". Ask again with one full path:\n", asked];
    NSUInteger limit = MIN(matches.count, (NSUInteger)20);
    for (NSUInteger i = 0; i < limit; i++) {
        [body appendFormat:@"- %@ (%@ bytes)\n", matches[i][@"full"], matches[i][@"size"]];
    }
    return [self textResult:@"read_local_file: error"
                       body:[body stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
}

#pragma mark - Classification (content, never extension)

+ (BOOL)isImageExtension:(NSString *)ext {
    static NSSet<NSString *> *imageExts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageExts = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"heic", @"heif", @"bmp", @"tif", @"tiff"]];
    });
    return [imageExts containsObject:ext];
}

+ (NSString *)sniffedImageExtension:(NSData *)data {
    // Image routing also follows the bytes, so a photo saved under a
    // non-image name still rides the image pipeline.
    const unsigned char *b = data.bytes;
    NSUInteger n = data.length;
    if (n >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return @"jpg";
    if (n >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return @"png";
    if (n >= 4 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) return @"gif";
    if (n >= 12 && !memcmp(b, "RIFF", 4) && !memcmp(b + 8, "WEBP", 4)) return @"webp";
    if (n >= 2 && b[0] == 0x42 && b[1] == 0x4D) return @"bmp";
    if (n >= 4 && ((b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00) ||
                   (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A))) return @"tiff";
    if (n >= 12 && !memcmp(b + 4, "ftyp", 4) &&
        (!memcmp(b + 8, "heic", 4) || !memcmp(b + 8, "heix", 4) || !memcmp(b + 8, "hevc", 4) ||
         !memcmp(b + 8, "mif1", 4) || !memcmp(b + 8, "msf1", 4))) return @"heic";
    return nil;
}

#pragma mark - Entry point

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

#pragma mark - list_local_files

+ (NSDictionary *)runList:(NSDictionary *)request {
    NSString *path = [request[@"path"] isKindOfClass:[NSString class]]
        ? [request[@"path"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : nil;
    if (path.length) return [self runListFolder:path];
    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : nil;
    NSArray<NSDictionary *> *entries = [self fileEntries];
    NSMutableArray<NSDictionary *> *shown = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        if (query.length && [entry[@"full"] rangeOfString:query
                                                   options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [shown addObject:entry];
    }
    NSString *header = query.length
        ? [NSString stringWithFormat:@"list_local_files matching \"%@\"", query]
        : @"list_local_files";
    if (!shown.count) {
        return [self textResult:header body:query.length
            ? [NSString stringWithFormat:@"No files match \"%@\".", query]
            : @"There are no files to read yet."];
    }
    NSMutableString *body = [NSMutableString stringWithFormat:@"%lu file%@%@:\n",
        (unsigned long)shown.count, shown.count == 1 ? @"" : @"s",
        query.length ? [NSString stringWithFormat:@" matching \"%@\"", query] : @""];
    NSUInteger limit = MIN(shown.count, kEZLocalFileMaxListEntries);
    for (NSUInteger i = 0; i < limit; i++) {
        [body appendFormat:@"- %@ (%@ bytes)\n", shown[i][@"full"], shown[i][@"size"]];
    }
    if (shown.count > limit) {
        [body appendFormat:@"…and %lu more (list truncated).", (unsigned long)(shown.count - limit)];
    }
    return [self textResult:header body:[body stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
}

/// Lists one folder: a root ("EZMusic") or a subfolder inside one
/// ("EZAttachments/notes"). Immediate contents only — folders first,
/// so the model can browse the structure level by level.
+ (NSDictionary *)runListFolder:(NSString *)path {
    NSString *header = [NSString stringWithFormat:@"list_local_files: %@", path];
    NSString *rootName = nil;
    NSString *absolute = [self resolvedPathForRelativePath:path rootName:&rootName];
    if (!absolute) return [self outsideResult:path];
    NSDictionary *root = [self rootNamed:rootName];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:absolute error:nil];
    if (!attrs) {
        return [self textResult:header body:[NSString stringWithFormat:
            @"No folder at \"%@\" was found. Use list_local_files with no path to see everything.", path]];
    }
    if (![attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
        return [self textResult:header body:[NSString stringWithFormat:
            @"\"%@\" is a file, not a folder. Use read_local_file to read it.", [self displayPathForAbsolutePath:absolute root:root]]];
    }
    NSArray<NSString *> *names = [[fm contentsOfDirectoryAtPath:absolute error:nil] ?: @[]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *child = [absolute stringByAppendingPathComponent:name];
        NSDictionary *childAttrs = [fm attributesOfItemAtPath:child error:nil];
        NSString *display = [self displayPathForAbsolutePath:child root:root];
        if ([childAttrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
            [folders addObject:[NSString stringWithFormat:@"- %@/ (folder)", display]];
        } else if ([childAttrs[NSFileType] isEqualToString:NSFileTypeRegular]) {
            [files addObject:[NSString stringWithFormat:@"- %@ (%@ bytes)", display, childAttrs[NSFileSize] ?: @0]];
        }
    }
    NSUInteger total = folders.count + files.count;
    if (!total) {
        return [self textResult:header body:[NSString stringWithFormat:
            @"\"%@\" is empty.", [self displayPathForAbsolutePath:absolute root:root]]];
    }
    NSMutableString *body = [NSMutableString stringWithFormat:@"%@:\n",
        [self displayPathForAbsolutePath:absolute root:root]];
    NSUInteger shown = 0;
    for (NSString *line in [folders arrayByAddingObjectsFromArray:files]) {
        if (shown++ >= kEZLocalFileMaxListEntries) break;
        [body appendFormat:@"%@\n", line];
    }
    if (total > kEZLocalFileMaxListEntries) {
        [body appendFormat:@"…and %lu more (list truncated).", (unsigned long)(total - kEZLocalFileMaxListEntries)];
    }
    return [self textResult:header body:[body stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
}

#pragma mark - read_local_file

+ (NSDictionary *)runRead:(NSDictionary *)request {
    NSString *name = [request[@"name"] isKindOfClass:[NSString class]]
        ? [request[@"name"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
    NSString *header = [NSString stringWithFormat:@"read_local_file: %@", name.length ? name : @"(no name)"];
    if (!name.length) {
        return [self textResult:@"read_local_file: error"
                           body:@"No file name was given, so nothing was read. Use list_local_files to see what is available."];
    }
    if ([name containsString:@"/"]) {
        // A path: its first component names the root, the rest is a
        // subpath inside it. Subfolders are a feature — users organize
        // their own files — so this is resolved, not rejected; the
        // containment check in the resolver is the only restriction.
        NSString *rootName = nil;
        NSString *absolute = [self resolvedPathForRelativePath:name rootName:&rootName];
        if (!absolute) return [self outsideResult:name];
        NSDictionary *root = [self rootNamed:rootName];
        NSString *display = [self displayPathForAbsolutePath:absolute root:root];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:absolute error:nil];
        if (!attrs) {
            return [self textResult:header body:[NSString stringWithFormat:
                @"No file at \"%@\" was found. Use list_local_files to browse what is available.", name]];
        }
        if ([attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
            return [self textResult:header body:[NSString stringWithFormat:
                @"\"%@\" is a folder. Use list_local_files with that path to see inside it.", display]];
        }
        return [self readFileAtPath:absolute
                        displayName:display
                             header:header
                            byteSize:[attrs[NSFileSize] unsignedLongLongValue]];
    }

    // A bare file name: search every root (recursively) with the match
    // ladder — exact, then case-insensitive exact, then unique
    // substring. More than one hit at any rung is ambiguous and comes
    // back as a candidate list with full paths.
    NSArray<NSDictionary *> *entries = [self fileEntries];
    NSMutableArray<NSDictionary *> *exact = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *folded = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *partial = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        if ([entry[@"name"] isEqualToString:name]) [exact addObject:entry];
        else if ([entry[@"name"] caseInsensitiveCompare:name] == NSOrderedSame) [folded addObject:entry];
        else if ([entry[@"name"] rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound ||
                 [entry[@"full"] rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) [partial addObject:entry];
    }
    NSArray<NSDictionary *> *matches = exact.count ? exact : (folded.count ? folded : partial);
    if (matches.count == 1) {
        NSDictionary *match = matches.firstObject;
        return [self readFileAtPath:match[@"path"]
                        displayName:match[@"full"]
                             header:header
                            byteSize:[match[@"size"] unsignedLongLongValue]];
    }
    if (matches.count > 1) return [self candidatesResult:matches asked:name];
    return [self textResult:@"read_local_file: error"
                       body:[NSString stringWithFormat:
        @"No file named \"%@\" was found in EZAttachments, EZPhotoGallery, EZSounds, EZMusic or EZThreads. Use list_local_files to see what is available.", name]];
}

/// Reads one resolved file: images ride the image pipeline (decided
/// by extension or magic bytes), text-vs-binary is decided by CONTENT
/// (never by extension), and everything else returns name/size/type.
+ (NSDictionary *)readFileAtPath:(NSString *)path
                     displayName:(NSString *)displayName
                          header:(NSString *)header
                        byteSize:(unsigned long long)byteSize {
    NSString *ext = displayName.pathExtension.lowercaseString;
    if ([self isImageExtension:ext] && byteSize > kEZLocalFileMaxImageBytes) {
        return [self textResult:header body:[NSString stringWithFormat:
            @"[Local file: %@ — %llu bytes]\nThis image is too large to send as image context, so it was not attached.", displayName, byteSize]];
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return [self textResult:@"read_local_file: error"
                           body:[NSString stringWithFormat:@"%@ could not be read.", displayName]];
    }
    NSString *sniffedImageExt = [self sniffedImageExtension:data];
    if ([self isImageExtension:ext] || sniffedImageExt) {
        if (data.length > kEZLocalFileMaxImageBytes) {
            return [self textResult:header body:[NSString stringWithFormat:
                @"[Local file: %@ — %llu bytes]\nThis image is too large to send as image context, so it was not attached.", displayName, byteSize]];
        }
        return @{ @"kind": @"image",
                  @"fileName": displayName,
                  @"data": data,
                  @"extension": [self isImageExtension:ext] ? ext : sniffedImageExt,
                  @"byteSize": @(byteSize) };
    }

    // Text-vs-binary is decided by CONTENT, never by extension: a .ts,
    // .m, .py or extensionless file whose bytes decode as text IS text
    // and is returned in full like any other text file. Text means the
    // bytes contain no NUL and decode — UTF-8 first, Latin-1 as the
    // lenient fallback. Anything else is genuinely binary (audio,
    // archives, PDFs, compiled data) and its raw bytes are never
    // dumped into the conversation.
    NSString *text = nil;
    if (!memchr(data.bytes, 0, data.length)) {
        text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
            ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (!text) {
        NSString *typeLabel = ext.length ? [ext uppercaseString] : @"unknown type";
        return [self textResult:header body:[NSString stringWithFormat:
            @"[Local file: %@ — %llu bytes]\nThis is a binary file (%@); its contents were not sent.", displayName, byteSize, typeLabel]];
    }
    if (text.length > kEZLocalFileMaxTextChars) {
        return [self textResult:header body:[NSString stringWithFormat:
            @"[Local file: %@ — %llu bytes]\nThis file's text is %lu characters, over the 1,000,000-character limit, so its contents were not sent.",
            displayName, byteSize, (unsigned long)text.length]];
    }
    return [self textResult:header body:[NSString stringWithFormat:
        @"[Local file: %@ — %llu bytes]\n%@", displayName, byteSize, text]];
}

@end
