// EZFileItem.m
// EZCompleteUI

#import "EZFileItem.h"

@implementation EZFileItem

- (instancetype)initWithURL:(NSURL *)url
            resourceValues:(NSDictionary<NSURLResourceKey, id> *)resourceValues
                 childCount:(NSInteger)childCount
        displayNameOverride:(NSString *)displayNameOverride {
    self = [super init];
    if (self) {
        _url = url;
        _name = [url.lastPathComponent copy] ?: @"";
        _displayNameOverride = [displayNameOverride copy];
        _isDirectory = [resourceValues[NSURLIsDirectoryKey] boolValue];
        _fileSize = [resourceValues[NSURLFileSizeKey] unsignedLongLongValue];
        _childCount = childCount;
        _modifiedDate = resourceValues[NSURLContentModificationDateKey];
        _creationDate = resourceValues[NSURLCreationDateKey];
        _contentType = resourceValues[NSURLContentTypeKey];
    }
    return self;
}

+ (NSArray<NSURLResourceKey> *)ez_prefetchKeys {
    return @[ NSURLIsDirectoryKey,
              NSURLFileSizeKey,
              NSURLContentModificationDateKey,
              NSURLCreationDateKey,
              NSURLContentTypeKey ];
}

+ (instancetype)rootItemWithURL:(NSURL *)url
            displayNameOverride:(NSString *)displayNameOverride {
    NSDictionary *values = [url resourceValuesForKeys:[self ez_prefetchKeys]
                                                error:nil];
    if (!values) return nil;
    BOOL isDir = [values[NSURLIsDirectoryKey] boolValue];
    NSInteger childCount = -1;
    if (isDir) {
        NSArray *children = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:url.path error:nil];
        childCount = children ? (NSInteger)children.count : -1;
    }
    return [[self alloc] initWithURL:url
                     resourceValues:values
                          childCount:childCount
                 displayNameOverride:displayNameOverride];
}

+ (void)scanDirectoryAtURL:(NSURL *)directoryURL
                completion:(void (^)(NSArray<EZFileItem *> *,
                                     NSError * _Nullable))completion {
    NSArray<NSURLResourceKey> *keys = [self ez_prefetchKeys];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *scanError = nil;
        NSArray<NSURL *> *urls = [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:directoryURL
          includingPropertiesForKeys:keys
                             options:0
                               error:&scanError];
        if (!urls) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(@[], scanError);
            });
            return;
        }
        NSMutableArray<EZFileItem *> *items = [NSMutableArray arrayWithCapacity:urls.count];
        for (NSURL *url in urls) {
            NSDictionary *values = [url resourceValuesForKeys:keys error:nil];
            if (!values) continue; // vanished mid-scan (e.g. a temp file) — skip it
            NSInteger childCount = -1;
            if ([values[NSURLIsDirectoryKey] boolValue]) {
                // Names only, no per-file stat — cheap even for large
                // folders, and it is what makes "Folder — N items"
                // possible without a second pass.
                NSArray *children = [[NSFileManager defaultManager]
                    contentsOfDirectoryAtPath:url.path error:nil];
                childCount = children ? (NSInteger)children.count : -1;
            }
            [items addObject:[[self alloc] initWithURL:url
                                        resourceValues:values
                                             childCount:childCount
                                    displayNameOverride:nil]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(items, nil);
        });
    });
}

- (NSString *)displayName {
    return self.displayNameOverride.length ? self.displayNameOverride : self.name;
}

#pragma mark - Classification

- (NSString *)ez_lowercaseExtension {
    return self.name.pathExtension.lowercaseString;
}

- (BOOL)isMediaFile {
    if (self.isDirectory) return NO;
    UTType *type = self.contentType;
    return [type conformsToType:UTTypeImage] || [type conformsToType:UTTypeMovie];
}

- (BOOL)isTextFile {
    if (self.isDirectory) return NO;
    if ([self isArchiveFile]) return NO; // a .tar.gz is data, not text
    if ([self.contentType conformsToType:UTTypeText]) return YES;
    // No (or too generic) UTType: fall back to extensions the editor is
    // known to handle well. This is deliberately a whitelist — opening
    // an unknown binary in a text editor helps no one.
    static NSSet<NSString *> *textExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        textExtensions = [NSSet setWithArray:@[
            @"txt", @"text", @"md", @"markdown", @"json", @"xml", @"plist",
            @"csv", @"tsv", @"log", @"strings", @"srt", @"yml", @"yaml",
            @"toml", @"ini", @"conf", @"cfg",
            @"h", @"m", @"mm", @"c", @"hpp", @"cpp", @"cc", @"swift",
            @"js", @"ts", @"jsx", @"tsx", @"py", @"rb", @"sh", @"zsh",
            @"html", @"htm", @"css", @"java", @"kt", @"go", @"rs", @"php",
            @"sql", @"diff", @"patch",
        ]];
    });
    return [textExtensions containsObject:[self ez_lowercaseExtension]];
}

- (BOOL)isZipArchive {
    if (self.isDirectory) return NO;
    if ([self.contentType conformsToType:UTTypeZIP]) return YES;
    // ipa/cbz/jar are plain ZIP files wearing a different extension —
    // they extract exactly like one.
    static NSSet<NSString *> *zipExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        zipExtensions = [NSSet setWithArray:@[@"zip", @"ipa", @"cbz", @"jar"]];
    });
    return [zipExtensions containsObject:[self ez_lowercaseExtension]];
}

- (BOOL)isRARArchive {
    if (self.isDirectory) return NO;
    return [[self ez_lowercaseExtension] isEqualToString:@"rar"];
}

- (BOOL)isTarArchive {
    if (self.isDirectory) return NO;
    NSString *ext = [self ez_lowercaseExtension];
    if ([ext isEqualToString:@"tar"] || [ext isEqualToString:@"tgz"]) return YES;
    return [self.name.lowercaseString hasSuffix:@".tar.gz"];
}

- (BOOL)isDebPackage {
    if (self.isDirectory) return NO;
    return [[self ez_lowercaseExtension] isEqualToString:@"deb"];
}

- (BOOL)isUnsupportedArchive {
    if (self.isDirectory) return NO;
    static NSSet<NSString *> *unsupportedExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsupportedExtensions = [NSSet setWithArray:@[
            @"xz", @"zst", @"7z", @"bz2", @"bzip2", @"lz4", @"lzma",
        ]];
    });
    // pathExtension reports the last component, which covers both the
    // plain form (backup.xz) and the tar form (backup.tar.xz).
    return [unsupportedExtensions containsObject:[self ez_lowercaseExtension]];
}

- (BOOL)isArchiveFile {
    if (self.isDirectory) return NO;
    if ([self isZipArchive] || [self isRARArchive]) return YES;
    if ([self.contentType conformsToType:UTTypeArchive]) return YES;
    static NSSet<NSString *> *archiveExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        archiveExtensions = [NSSet setWithArray:@[
            @"tar", @"gz", @"tgz", @"bz2", @"xz", @"zst", @"lz4",
            @"7z", @"deb", @"ipa", @"jar", @"cbz",
        ]];
    });
    if ([archiveExtensions containsObject:[self ez_lowercaseExtension]]) return YES;
    // Double extensions: name.tar.gz / name.tar.xz — the inner "tar"
    // gives it away even though pathExtension only reports the last one.
    NSString *stem = self.name.stringByDeletingPathExtension;
    return [stem.pathExtension.lowercaseString isEqualToString:@"tar"];
}

@end
