// EZMusicArtworkService.m
// EZCompleteUI v1.0
//
// Purpose:
//   Implementation of the song cover-art generator described in
//   EZMusicArtworkService.h. Read that header first.
//
//   Flow of -generateArtworkIfNeededForEntry: (all bookkeeping on the main queue):
//     checks (id, setting, signed in, not already done/started) -> prompt ->
//     POST ez-image -> download the picture -> shrink + save JPEG on a
//     background queue -> notify.
//
//   Failure handling, on purpose:
//     - Network trouble, timeouts, HTTP 429 and 5xx: retried once after a short
//       pause. If that fails too, give up quietly for this launch (nothing is
//       remembered on disk, so a later launch may try again).
//     - HTTP 402 (not enough coins): give up quietly, nothing remembered. The
//       song itself is already paid for and saved; the cover is a bonus.
//     - Any other 4xx (for example the prompt was refused by moderation):
//       remembered with a small "skip" marker file so the app never pays to
//       retry something that will keep failing.
//     - The server only charges for images it actually returns. The balance it
//       reports is passed to EZEntitlementManager so the coin display updates.
//     - At most one request per song at a time, and a song is only tried once
//       per launch, so a notification storm can't create duplicate charges.

#import "EZMusicArtworkService.h"
#import "EZMusicLibraryManager.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZSupabaseConfig.h"
#import "helpers.h"

NSNotificationName const EZMusicArtworkDidUpdateNotification = @"EZMusicArtworkDidUpdateNotification";
NSString * const EZMusicArtworkEntryIDKey = @"entryID";

// The cheapest and fastest image model ez-image offers.
static NSString * const kEZMusicArtworkModel = @"gpt-image-1-mini";
// Low quality at the smallest square size is plenty for a cover thumbnail.
static NSString * const kEZMusicArtworkQuality = @"low";
static NSString * const kEZMusicArtworkSize = @"1024x1024";
// Covers are shown at most ~56pt on screen (and on the lock screen at a
// larger size), so 512px keeps files small without looking soft.
static const CGFloat kEZMusicArtworkStoredPixels = 512.0;
static const NSUInteger kEZMusicArtworkMaxLyricCharacters = 700;
static const NSUInteger kEZMusicArtworkMaxStyleCharacters = 300;
static const NSUInteger kEZMusicArtworkMaxTitleCharacters = 80;
static const NSTimeInterval kEZMusicArtworkRetryDelaySeconds = 4.0;
static NSString * const kEZMusicArtworkDisabledDefaultsKey = @"musicAutoArtworkDisabled";

@interface EZMusicArtworkService ()
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *imageCache;
// Song IDs being generated right now / already tried this launch. Main queue only.
@property (nonatomic, strong) NSMutableSet<NSString *> *inFlightEntryIDs;
@property (nonatomic, strong) NSMutableSet<NSString *> *attemptedEntryIDs;
@property (nonatomic, strong) dispatch_queue_t imageQueue;
@end

@implementation EZMusicArtworkService

+ (instancetype)sharedService {
    static EZMusicArtworkService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ service = [[self alloc] initPrivate]; });
    return service;
}

- (instancetype)initPrivate {
    self = [super init];
    if (!self) return nil;
    _imageCache = [[NSCache alloc] init];
    _inFlightEntryIDs = [NSMutableSet set];
    _attemptedEntryIDs = [NSMutableSet set];
    _imageQueue = dispatch_queue_create("com.ezcompleteui.music-artwork", DISPATCH_QUEUE_SERIAL);
    return self;
}

#pragma mark - Files

- (NSURL *)artworkDirectoryURL {
    return [[EZMusicLibraryManager sharedManager].libraryRootURL URLByAppendingPathComponent:@"Artwork" isDirectory:YES];
}

/// Entry IDs come from our own server, but they become file names, so keep
/// only safe characters.
- (nullable NSString *)safeFileStemForEntryID:(NSString *)entryID {
    if (entryID.length == 0 || entryID.length > 128) return nil;
    NSCharacterSet *unsafe = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet];
    if ([entryID rangeOfCharacterFromSet:unsafe].location != NSNotFound) return nil;
    return entryID;
}

- (nullable NSURL *)artworkFileURLForEntryID:(NSString *)entryID {
    NSString *stem = [self safeFileStemForEntryID:entryID];
    return stem ? [[self artworkDirectoryURL] URLByAppendingPathComponent:[stem stringByAppendingPathExtension:@"jpg"]] : nil;
}

- (nullable NSURL *)skipMarkerURLForEntryID:(NSString *)entryID {
    NSString *stem = [self safeFileStemForEntryID:entryID];
    return stem ? [[self artworkDirectoryURL] URLByAppendingPathComponent:[stem stringByAppendingPathExtension:@"skip"]] : nil;
}

#pragma mark - Reading and removing

- (UIImage *)cachedArtworkForEntryID:(NSString *)entryID {
    if (entryID.length == 0) return nil;
    UIImage *cached = [self.imageCache objectForKey:entryID];
    if (cached) return cached;
    NSURL *fileURL = [self artworkFileURLForEntryID:entryID];
    if (!fileURL) return nil;
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    UIImage *image = data.length > 0 ? [UIImage imageWithData:data] : nil;
    if (image) [self.imageCache setObject:image forKey:entryID];
    return image;
}

- (void)removeArtworkForEntryID:(NSString *)entryID {
    [self.imageCache removeObjectForKey:entryID];
    NSURL *fileURL = [self artworkFileURLForEntryID:entryID];
    NSURL *markerURL = [self skipMarkerURLForEntryID:entryID];
    dispatch_async(self.imageQueue, ^{
        if (fileURL) [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
        if (markerURL) [[NSFileManager defaultManager] removeItemAtURL:markerURL error:nil];
    });
}

#pragma mark - Starting

- (void)generateArtworkIfNeededForEntry:(NSDictionary *)entry {
    if (![entry isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *entrySnapshot = [entry copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self startGenerationForEntry:entrySnapshot];
    });
}

- (void)startGenerationForEntry:(NSDictionary *)entry {
    NSString *entryID = [entry[@"id"] isKindOfClass:[NSString class]] ? entry[@"id"] : @"";
    NSURL *fileURL = [self artworkFileURLForEntryID:entryID];
    NSURL *markerURL = [self skipMarkerURLForEntryID:entryID];
    if (!fileURL || !markerURL) return;

    if ([[NSUserDefaults standardUserDefaults] boolForKey:kEZMusicArtworkDisabledDefaultsKey]) return;
    if (!EZAuthManager.shared.isLoggedIn) return;
    if ([self.inFlightEntryIDs containsObject:entryID] || [self.attemptedEntryIDs containsObject:entryID]) return;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:fileURL.path] || [fileManager fileExistsAtPath:markerURL.path]) return;

    NSString *prompt = [self imagePromptForEntry:entry];
    if (prompt.length == 0) return;

    [self.inFlightEntryIDs addObject:entryID];
    [self.attemptedEntryIDs addObject:entryID];
    EZLogf(EZLogLevelInfo, @"MusicArt", @"Generating cover art for %@", entryID);
    [self requestImageForEntryID:entryID prompt:prompt attempt:0];
}

#pragma mark - Prompt

/// Short, plain text with section tags like [Verse 1] and extra whitespace removed.
- (NSString *)cleanedLyricsFromLyrics:(NSString *)lyrics {
    if (lyrics.length == 0) return @"";
    NSMutableArray<NSString *> *keptLines = [NSMutableArray array];
    for (NSString *rawLine in [lyrics componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        if ([line hasPrefix:@"["] && [line hasSuffix:@"]"]) continue;   // [Chorus], [Verse 2], ...
        [keptLines addObject:line];
    }
    return [self truncatedText:[keptLines componentsJoinedByString:@" / "]
                  maxCharacters:kEZMusicArtworkMaxLyricCharacters];
}

/// Cuts at a word boundary so the prompt doesn't end mid-word.
- (NSString *)truncatedText:(NSString *)text maxCharacters:(NSUInteger)maxCharacters {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length <= maxCharacters) return trimmed;
    NSString *cut = [trimmed substringToIndex:maxCharacters];
    NSRange lastSpace = [cut rangeOfString:@" " options:NSBackwardsSearch];
    if (lastSpace.location != NSNotFound && lastSpace.location > maxCharacters / 2) cut = [cut substringToIndex:lastSpace.location];
    return cut;
}

- (NSString *)imagePromptForEntry:(NSDictionary *)entry {
    NSString *title = [entry[@"title"] isKindOfClass:[NSString class]] ? entry[@"title"] : @"";
    NSString *lyrics = [self cleanedLyricsFromLyrics:([entry[@"lyrics"] isKindOfClass:[NSString class]] ? entry[@"lyrics"] : @"")];
    NSString *style = [self truncatedText:([entry[@"prompt"] isKindOfClass:[NSString class]] ? entry[@"prompt"] : @"")
                             maxCharacters:kEZMusicArtworkMaxStyleCharacters];
    title = [self truncatedText:title maxCharacters:kEZMusicArtworkMaxTitleCharacters];

    // Nothing to base a picture on.
    if (lyrics.length == 0 && style.length == 0 && title.length == 0) return @"";

    NSMutableString *prompt = [NSMutableString stringWithString:@"Square album cover artwork for a song"];
    if (title.length > 0) [prompt appendFormat:@" titled \"%@\"", title];
    [prompt appendString:@". "];
    if (lyrics.length > 0) {
        [prompt appendFormat:@"Illustrate the mood, setting and imagery of these lyrics: %@. ", lyrics];
        if (style.length > 0) [prompt appendFormat:@"Musical style: %@. ", style];
    } else if (style.length > 0) {
        [prompt appendFormat:@"This is an instrumental piece described as: %@. Show the feeling of that music. ", style];
    }
    [prompt appendString:@"One striking, cohesive composition like a streaming-app album cover. "
                          @"No text, no letters, no words, no logos, no watermark."];
    return prompt;
}

#pragma mark - Request

- (void)requestImageForEntryID:(NSString *)entryID prompt:(NSString *)prompt attempt:(NSInteger)attempt {
    __weak typeof(self) weakSelf = self;
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *authError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (token.length == 0) {
            // Signed out or session expired: nothing to retry, and nothing worth remembering.
            [strongSelf finishEntryID:entryID rememberingSkip:NO reason:@"not signed in"];
            return;
        }
        [strongSelf sendImageRequestWithToken:token entryID:entryID prompt:prompt attempt:attempt];
    }];
}

- (void)sendImageRequestWithToken:(NSString *)token entryID:(NSString *)entryID prompt:(NSString *)prompt attempt:(NSInteger)attempt {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/functions/v1/ez-image", EZSupabaseURL]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 90.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    NSDictionary *body = @{
        @"action": @"generate",
        @"model": kEZMusicArtworkModel,
        @"prompt": prompt,
        @"n": @1,
        @"size": kEZMusicArtworkSize,
        @"quality": kEZMusicArtworkQuality,
        @"output_format": @"jpeg",
        @"background": @"opaque",
        @"moderation": @"low",
    };
    NSError *serializationError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&serializationError];
    if (serializationError) {
        [self finishEntryID:entryID rememberingSkip:NO reason:serializationError.localizedDescription];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:
      ^(NSData *data, NSURLResponse *response, NSError *networkError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        NSDictionary *json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) json = nil;

        if (networkError || statusCode == 429 || statusCode >= 500) {
            [strongSelf retryOrFinishEntryID:entryID prompt:prompt attempt:attempt
                                      reason:networkError.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]];
            return;
        }
        if (statusCode == 402) {
            [strongSelf finishEntryID:entryID rememberingSkip:NO reason:@"not enough coins for cover art"];
            return;
        }
        if (statusCode < 200 || statusCode >= 300) {
            NSString *serverError = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"request refused";
            [strongSelf finishEntryID:entryID rememberingSkip:YES
                               reason:[NSString stringWithFormat:@"HTTP %ld: %@", (long)statusCode, serverError]];
            return;
        }

        NSNumber *balance = [json[@"balance"] isKindOfClass:[NSNumber class]] ? json[@"balance"] : nil;
        if (balance) {
            dispatch_async(dispatch_get_main_queue(), ^{ [[EZEntitlementManager shared] applyKnownBalance:balance.integerValue]; });
        }
        NSDictionary *firstImage = [json[@"images"] isKindOfClass:[NSArray class]] ? [(NSArray *)json[@"images"] firstObject] : nil;
        if (![firstImage isKindOfClass:[NSDictionary class]]) firstImage = nil;
        [strongSelf loadImageFromResultEntry:firstImage entryID:entryID prompt:prompt attempt:attempt];
    }] resume];
}

/// The result is either a signed download link or inline base64 data.
- (void)loadImageFromResultEntry:(nullable NSDictionary *)resultEntry entryID:(NSString *)entryID
                          prompt:(NSString *)prompt attempt:(NSInteger)attempt {
    NSString *base64 = [resultEntry[@"b64_json"] isKindOfClass:[NSString class]] ? resultEntry[@"b64_json"] : nil;
    NSString *signedURLString = [resultEntry[@"url"] isKindOfClass:[NSString class]] ? resultEntry[@"url"] : nil;

    if (base64.length > 0) {
        NSData *imageData = [[NSData alloc] initWithBase64EncodedString:base64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        [self storeImageData:imageData entryID:entryID];
        return;
    }
    NSURL *signedURL = signedURLString.length > 0 ? [NSURL URLWithString:signedURLString] : nil;
    if (!signedURL) {
        // The server charged (or not) on its own terms; this response had no picture.
        [self finishEntryID:entryID rememberingSkip:NO reason:@"response had no image"];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:signedURL completionHandler:
      ^(NSData *data, NSURLResponse *response, NSError *downloadError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (downloadError || data.length == 0 || statusCode >= 400) {
            [strongSelf finishEntryID:entryID rememberingSkip:NO
                               reason:downloadError.localizedDescription ?: @"download failed"];
            return;
        }
        [strongSelf storeImageData:data entryID:entryID];
    }] resume];
}

- (void)retryOrFinishEntryID:(NSString *)entryID prompt:(NSString *)prompt attempt:(NSInteger)attempt reason:(NSString *)reason {
    if (attempt >= 1) {
        [self finishEntryID:entryID rememberingSkip:NO reason:reason];
        return;
    }
    EZLogf(EZLogLevelInfo, @"MusicArt", @"Cover art request for %@ failed (%@); retrying once", entryID, reason);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kEZMusicArtworkRetryDelaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self requestImageForEntryID:entryID prompt:prompt attempt:attempt + 1];
    });
}

#pragma mark - Saving

/// Shrinks the picture to a small JPEG and saves it, off the main thread.
- (void)storeImageData:(nullable NSData *)imageData entryID:(NSString *)entryID {
    NSURL *fileURL = [self artworkFileURLForEntryID:entryID];
    NSURL *directoryURL = [self artworkDirectoryURL];
    dispatch_async(self.imageQueue, ^{
        UIImage *original = imageData.length > 0 ? [UIImage imageWithData:imageData] : nil;
        if (!original || !fileURL) {
            [self finishEntryID:entryID rememberingSkip:NO reason:@"image data could not be decoded"];
            return;
        }
        UIImage *scaled = [self squareImageFromImage:original pixels:kEZMusicArtworkStoredPixels];
        NSData *jpegData = UIImageJPEGRepresentation(scaled, 0.85);
        NSError *writeError = nil;
        BOOL directoryReady = [[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                                       withIntermediateDirectories:YES attributes:nil error:&writeError];
        if (!directoryReady || jpegData.length == 0 || ![jpegData writeToURL:fileURL options:NSDataWritingAtomic error:&writeError]) {
            [self finishEntryID:entryID rememberingSkip:NO reason:writeError.localizedDescription ?: @"could not save image"];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.imageCache setObject:scaled forKey:entryID];
            [self.inFlightEntryIDs removeObject:entryID];
            EZLogf(EZLogLevelInfo, @"MusicArt", @"Saved cover art for %@", entryID);
            [[NSNotificationCenter defaultCenter] postNotificationName:EZMusicArtworkDidUpdateNotification
                                                                object:self
                                                              userInfo:@{ EZMusicArtworkEntryIDKey: entryID }];
        });
    });
}

/// Center-crops to a square and renders at exactly `pixels` x `pixels`.
- (UIImage *)squareImageFromImage:(UIImage *)image pixels:(CGFloat)pixels {
    CGFloat shortSide = MIN(image.size.width, image.size.height);
    if (shortSide <= 0) return image;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;   // `pixels` is already in pixels, not points.
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(pixels, pixels) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat scale = pixels / shortSide;
        CGSize drawSize = CGSizeMake(image.size.width * scale, image.size.height * scale);
        [image drawInRect:CGRectMake((pixels - drawSize.width) / 2.0, (pixels - drawSize.height) / 2.0,
                                     drawSize.width, drawSize.height)];
    }];
}

#pragma mark - Finishing

/// Ends an attempt that produced no picture. `rememberSkip` writes the marker
/// file so a failure that will keep failing is never paid for again.
- (void)finishEntryID:(NSString *)entryID rememberingSkip:(BOOL)rememberSkip reason:(NSString *)reason {
    EZLogf(EZLogLevelWarning, @"MusicArt", @"No cover art for %@: %@", entryID, reason);
    NSURL *markerURL = [self skipMarkerURLForEntryID:entryID];
    NSURL *directoryURL = [self artworkDirectoryURL];
    if (rememberSkip && markerURL) {
        dispatch_async(self.imageQueue, ^{
            [[NSFileManager defaultManager] createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
            [[reason dataUsingEncoding:NSUTF8StringEncoding] writeToURL:markerURL options:NSDataWritingAtomic error:nil];
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self.inFlightEntryIDs removeObject:entryID]; });
}

@end
