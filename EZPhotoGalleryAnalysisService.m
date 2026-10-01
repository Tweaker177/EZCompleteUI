//
//  EZPhotoGalleryAnalysisService.m
//  EZCompleteUI
//

#import "EZPhotoGalleryAnalysisService.h"
#import "EZAuthManager.h"
#import "EZSupabaseConfig.h"
#import "helpers.h"
#import <UIKit/UIKit.h>

NSNotificationName const EZPhotoGalleryManifestDidChangeNotification =
    @"EZPhotoGalleryManifestDidChangeNotification";

static NSString *const kGalleryManifestFileName = @"gallery-manifest.json";
static NSString *const kVisionModel = @"gpt-4.1-nano";
static CGFloat const kAnalysisImageMaximumDimension = 640.0;

static BOOL EZGalleryAnalysisSupportsPath(NSString *path) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[
            @"jpg", @"jpeg", @"png", @"heic", @"heif", @"gif", @"webp", @"tif", @"tiff", @"bmp"
        ]];
    });
    return [extensions containsObject:path.pathExtension.lowercaseString];
}

@interface EZPhotoGalleryAnalysisService ()
@property (nonatomic, strong) dispatch_queue_t manifestQueue;
@property (nonatomic, strong) NSOperationQueue *analysisQueue;
@property (nonatomic, strong) NSMutableSet<NSString *> *inFlightPaths;
@end

@implementation EZPhotoGalleryAnalysisService

+ (instancetype)sharedService {
    static EZPhotoGalleryAnalysisService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ service = [[self alloc] initPrivate]; });
    return service;
}

- (instancetype)init {
    return [EZPhotoGalleryAnalysisService sharedService];
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _manifestQueue = dispatch_queue_create("com.ezcomplete.gallery-manifest", DISPATCH_QUEUE_SERIAL);
        _analysisQueue = [[NSOperationQueue alloc] init];
        // One request at a time keeps imports responsive and avoids charging
        // through an entire imported library all at once.
        _analysisQueue.maxConcurrentOperationCount = 1;
        _analysisQueue.qualityOfService = NSQualityOfServiceUtility;
        _inFlightPaths = [NSMutableSet set];
    }
    return self;
}

- (NSURL *)manifestURL {
    return [NSURL fileURLWithPath:[EZPhotoGalleryDirectory()
        stringByAppendingPathComponent:kGalleryManifestFileName]];
}

- (NSString *)fingerprintForPath:(NSString *)path {
    // A malformed external path should not make a gallery action ask
    // Foundation to construct an unbounded URL/string representation.
    if (path.length == 0 || path.length > 4096) return nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSNumber *size = attributes[NSFileSize];
    NSDate *modified = attributes[NSFileModificationDate];
    if (!size || !modified) return nil;
    return [NSString stringWithFormat:@"%@|%.6f", size, modified.timeIntervalSince1970];
}

- (NSMutableDictionary *)manifestRootLocked {
    NSData *data = [NSData dataWithContentsOfURL:[self manifestURL]];
    if (data.length) {
        id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([decoded isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *root = [decoded mutableCopy];
            if ([root[@"assets"] isKindOfClass:[NSDictionary class]]) return root;
        }
    }
    return [@{ @"version": @1, @"assets": @{} } mutableCopy];
}

- (BOOL)writeManifestRootLocked:(NSDictionary *)root {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:&error];
    if (!data) {
        EZLogf(EZLogLevelError, @"GALLERY", @"Could not encode gallery manifest: %@", error);
        return NO;
    }
    BOOL saved = [data writeToURL:[self manifestURL] options:NSDataWritingAtomic error:&error];
    if (!saved) EZLogf(EZLogLevelError, @"GALLERY", @"Could not save gallery manifest: %@", error);
    return saved;
}

- (void)postManifestChangeForPath:(NSString *)path {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:EZPhotoGalleryManifestDidChangeNotification
                          object:self
                        userInfo:@{ @"path": path ?: @"" }];
    });
}

- (UIImage *)analysisImageForPath:(NSString *)path {
    UIImage *source = [UIImage imageWithContentsOfFile:path];
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;
    CGFloat largest = MAX(source.size.width, source.size.height);
    if (largest <= kAnalysisImageMaximumDimension) return source;
    CGFloat scale = kAnalysisImageMaximumDimension / largest;
    CGSize size = CGSizeMake(MAX(1.0, floor(source.size.width * scale)),
                             MAX(1.0, floor(source.size.height * scale)));
    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    [[UIColor blackColor] setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    [source drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return resized;
}

- (NSArray<NSString *> *)normalizedTags:(id)rawTags {
    if (![rawTags isKindOfClass:[NSArray class]]) return @[];
    NSMutableOrderedSet<NSString *> *tags = [NSMutableOrderedSet orderedSet];
    for (id rawTag in (NSArray *)rawTags) {
        if (![rawTag isKindOfClass:[NSString class]]) continue;
        NSString *tag = [[(NSString *)rawTag lowercaseString]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (tag.length > 0 && tag.length <= 32) [tags addObject:tag];
        if (tags.count == 12) break;
    }
    return tags.array;
}

- (void)completeAnalysisForPath:(NSString *)path
                    fingerprint:(NSString *)fingerprint
                         summary:(NSString *)summary
                            tags:(NSArray<NSString *> *)tags
                           error:(NSString *)errorMessage {
    dispatch_sync(self.manifestQueue, ^{
        NSMutableDictionary *root = [self manifestRootLocked];
        NSMutableDictionary *assets = [root[@"assets"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSString *name = path.lastPathComponent;
        NSMutableDictionary *entry = [assets[name] mutableCopy] ?: [NSMutableDictionary dictionary];

        // Do not attach an old answer to a file that was replaced while the
        // request was in flight.
        if (![[self fingerprintForPath:path] isEqualToString:fingerprint]) {
            [self.inFlightPaths removeObject:path];
            return;
        }

        entry[@"file_name"] = name;
        entry[@"fingerprint"] = fingerprint;
        entry[@"model"] = kVisionModel;
        entry[@"updated_at"] = [[NSDate date] description];
        if (summary.length) {
            entry[@"summary"] = summary;
            entry[@"tags"] = tags ?: @[];
            entry[@"status"] = @"complete";
            [entry removeObjectForKey:@"last_error"];
        } else {
            // Leave this retryable. A transient connection error should never
            // permanently make a user's image ineligible for Surprise Me.
            entry[@"status"] = @"queued";
            entry[@"last_error"] = errorMessage ?: @"Analysis unavailable";
        }
        assets[name] = entry;
        root[@"assets"] = assets;
        [self writeManifestRootLocked:root];
        [self.inFlightPaths removeObject:path];
    });
    [self postManifestChangeForPath:path];
}

- (void)performAnalysisForPath:(NSString *)path fingerprint:(NSString *)fingerprint {
    UIImage *image = [self analysisImageForPath:path];
    NSData *jpeg = image ? UIImageJPEGRepresentation(image, 0.68) : nil;
    if (!jpeg.length) {
        [self completeAnalysisForPath:path fingerprint:fingerprint summary:nil tags:nil
                                  error:@"The image could not be prepared for analysis."];
        return;
    }

    if (![EZAuthManager shared].isLoggedIn) {
        [self completeAnalysisForPath:path fingerprint:fingerprint summary:nil tags:nil
                                  error:@"Sign in to analyze gallery photos."];
        return;
    }

    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *tokenError) {
        if (!token.length) {
            [self completeAnalysisForPath:path fingerprint:fingerprint summary:nil tags:nil
                                      error:tokenError.localizedDescription ?: @"Authentication expired."];
            dispatch_semaphore_signal(finished);
            return;
        }

        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/functions/v1/ez-image", EZSupabaseURL]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        request.timeoutInterval = 50.0;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
        NSDictionary *payload = @{
            @"action": @"analyze",
            @"image_b64": [jpeg base64EncodedStringWithOptions:0],
            @"mime_type": @"image/jpeg",
        };
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSDictionary *result = data.length
                ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *summary = [result[@"summary"] isKindOfClass:[NSString class]] ? result[@"summary"] : nil;
            if (summary.length > 220) summary = [summary substringToIndex:220];
            NSArray<NSString *> *tags = [self normalizedTags:result[@"tags"]];
            NSString *error = networkError.localizedDescription;
            if (!error.length && (http.statusCode < 200 || http.statusCode >= 300)) {
                error = [result[@"error"] isKindOfClass:[NSString class]] ? result[@"error"]
                    : [NSString stringWithFormat:@"Analysis request failed (%ld).", (long)http.statusCode];
            }
            if (!summary.length && !error.length) error = @"The analysis response was incomplete.";
            [self completeAnalysisForPath:path fingerprint:fingerprint summary:summary tags:tags error:error];
            dispatch_semaphore_signal(finished);
        }];
        [task resume];
    }];
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
}

- (void)queueAnalysisForPhotoAtPath:(NSString *)path {
    if (!path.length || !EZGalleryAnalysisSupportsPath(path)) return;
    NSString *fingerprint = [self fingerprintForPath:path];
    if (!fingerprint.length) return;
    NSString *pathCopy = [path copy];
    dispatch_async(self.manifestQueue, ^{
        if ([self.inFlightPaths containsObject:pathCopy]) return;
        NSMutableDictionary *root = [self manifestRootLocked];
        NSMutableDictionary *assets = [root[@"assets"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSString *name = pathCopy.lastPathComponent;
        NSDictionary *existing = assets[name];
        if ([existing[@"fingerprint"] isEqualToString:fingerprint] &&
            [existing[@"status"] isEqualToString:@"complete"]) return;

        assets[name] = @{
            @"file_name": name,
            @"fingerprint": fingerprint,
            @"summary": [existing[@"summary"] isKindOfClass:[NSString class]] ? existing[@"summary"] : @"",
            @"tags": [existing[@"tags"] isKindOfClass:[NSArray class]] ? existing[@"tags"] : @[],
            @"status": @"queued",
            @"model": kVisionModel,
            @"updated_at": [[NSDate date] description],
        };
        root[@"assets"] = assets;
        [self writeManifestRootLocked:root];
        [self.inFlightPaths addObject:pathCopy];
        [self.analysisQueue addOperationWithBlock:^{
            [self performAnalysisForPath:pathCopy fingerprint:fingerprint];
        }];
        [self postManifestChangeForPath:pathCopy];
    });
}

- (void)retryQueuedAnalyses {
    NSString *directory = EZPhotoGalleryDirectory();
    NSArray<NSString *> *paths = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    for (NSString *name in paths) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        [self queueAnalysisForPhotoAtPath:path];
    }
}

- (NSDictionary<NSString *,id> *)manifestEntryForPath:(NSString *)path {
    if (!path.length) return nil;
    NSString *fingerprint = [self fingerprintForPath:path];
    if (!fingerprint.length) return nil;
    __block NSDictionary *entry = nil;
    dispatch_sync(self.manifestQueue, ^{
        NSDictionary *assets = [self manifestRootLocked][@"assets"];
        NSDictionary *candidate = [assets[path.lastPathComponent] isKindOfClass:[NSDictionary class]]
            ? assets[path.lastPathComponent] : nil;
        if ([candidate[@"fingerprint"] isEqualToString:fingerprint]) entry = [candidate copy];
    });
    return entry;
}

- (NSDictionary<NSString *,NSDictionary<NSString *,id> *> *)manifestEntriesForPaths:(NSArray<NSString *> *)paths {
    if (paths.count == 0) return @{};
    __block NSDictionary<NSString *, NSDictionary<NSString *, id> *> *entries = nil;
    dispatch_sync(self.manifestQueue, ^{
        NSDictionary *assets = [self manifestRootLocked][@"assets"];
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (NSString *path in paths) {
            if (![path isKindOfClass:[NSString class]] || path.length == 0) continue;
            NSDictionary *entry = [assets[path.lastPathComponent] isKindOfClass:[NSDictionary class]]
                ? assets[path.lastPathComponent] : nil;
            if (!entry) continue;
            // Surprise Me needs only the state and classification, not the
            // summary/fingerprint payload for every image in the library.
            result[path] = @{
                @"status": [entry[@"status"] isKindOfClass:[NSString class]] ? entry[@"status"] : @"",
                @"tags": [entry[@"tags"] isKindOfClass:[NSArray class]] ? entry[@"tags"] : @[],
            };
        }
        entries = [result copy];
    });
    return entries ?: @{};
}

@end
