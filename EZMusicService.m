// EZMusicService.m
// EZCompleteUI v1.0
//
// Purpose:
//   Implementation of the ez-music Edge Function client. See EZMusicService.h
//   for the overview. Every call funnels through one private method,
//   -performAction:payload:completion:, which owns authentication, retries and
//   error translation, so the public methods stay short and consistent.
//
// Changes:
//   - Initial version.

#import "EZMusicService.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZSupabaseConfig.h"
#import "helpers.h"
#import <AVFoundation/AVFoundation.h>

NSString * const EZMusicServiceErrorDomain    = @"EZMusicServiceErrorDomain";
NSString * const EZMusicServiceServerCodeKey  = @"EZMusicServiceServerCode";

// Request and retry tuning.
static const NSTimeInterval kRequestTimeoutSeconds   = 45.0;
static const NSInteger      kMaxNetworkRetries       = 2;
static const NSUInteger     kMaximumReferenceBytes   = 12 * 1024 * 1024;
static const NSUInteger     kMaximumVideoBytes       = 200 * 1024 * 1024;
static const NSTimeInterval kRetryBaseDelaySeconds   = 1.5;

// Polling tuning. The server refunds anything unfinished after ~15 minutes, so
// waiting longer than that here can never produce a different outcome.
static const NSTimeInterval kPollInitialIntervalSeconds = 4.0;
static const NSTimeInterval kPollMaxIntervalSeconds     = 10.0;
static const NSTimeInterval kPollOverallLimitSeconds    = 16.0 * 60.0;
static const NSInteger      kPollMaxConsecutiveFailures = 5;

#pragma mark - Poll token

@interface EZMusicPollToken ()
@property (nonatomic, readwrite, getter=isCancelled) BOOL cancelled;
@end

@implementation EZMusicPollToken
- (void)cancel { self.cancelled = YES; }
@end

#pragma mark - Helpers

static NSError *EZMusicError(NSInteger code, NSString *message, NSDictionary *extraInfo) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:message
                                                                    forKey:NSLocalizedDescriptionKey];
    if (extraInfo) [info addEntriesFromDictionary:extraInfo];
    return [NSError errorWithDomain:EZMusicServiceErrorDomain code:code userInfo:info];
}

// Network failures worth trying again; everything else (bad host, cancelled) is not.
static BOOL EZMusicIsTransientNetworkError(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorDNSLookupFailed:
            return YES;
        default:
            return NO;
    }
}

static NSArray<NSDictionary *> *EZMusicEntryDictionaries(id rawEntries) {
    if (![rawEntries isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (id item in (NSArray *)rawEntries) {
        if ([item isKindOfClass:[NSDictionary class]]) [entries addObject:item];
    }
    return [entries copy];
}

static BOOL EZMusicAnyEntryPending(NSArray<NSDictionary *> *entries) {
    for (NSDictionary *entry in entries) {
        if ([entry[@"status"] isEqual:@"pending"]) return YES;
    }
    return NO;
}

static NSString *EZMusicVideoMimeType(NSURL *url) {
    static NSDictionary<NSString *, NSString *> *types;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        types = @{ @"mp4": @"video/mp4", @"m4v": @"video/x-m4v",
                   @"mov": @"video/quicktime", @"webm": @"video/webm",
                   @"avi": @"video/x-msvideo" };
    });
    return types[url.pathExtension.lowercaseString] ?: @"application/octet-stream";
}

static BOOL EZMusicLooksLikeMP3(NSData *data) {
    if (data.length < 3) return NO;
    const uint8_t *bytes = data.bytes;
    return (bytes[0] == 'I' && bytes[1] == 'D' && bytes[2] == '3') ||
           (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0);
}

static NSError *EZMusicVideoError(NSData *data, NSInteger statusCode, NSError *networkError) {
    if (networkError) {
        return EZMusicError(EZMusicServiceErrorNetwork,
                            @"Couldn't reach the music service. Check your connection and try again.",
                            @{ NSUnderlyingErrorKey: networkError });
    }
    NSDictionary *json = nil;
    if (data.length) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) json = parsed;
    }
    NSString *serverCode = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"";
    NSString *message = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : nil;
    if (!message.length) {
        message = statusCode == 401 ? @"Your session expired. Please sign in again."
                : statusCode == 413 ? @"That video is too large. Choose videos totaling 200 MB or less."
                : @"Couldn't generate music for that video. Please try again.";
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (serverCode.length) info[EZMusicServiceServerCodeKey] = serverCode;
    return EZMusicError(statusCode == 401 ? EZMusicServiceErrorNotSignedIn : EZMusicServiceErrorServer,
                        message, info);
}

static BOOL EZMusicIsH264MP4(NSURL *url) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    CMFormatDescriptionRef description = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
    return track && description && CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264;
}

static void EZMusicPrepareVideoAtIndex(NSArray<NSURL *> *sourceURLs, NSMutableArray<NSURL *> *prepared,
                                       NSMutableArray<NSURL *> *temporary, NSUInteger index,
                                       void (^completion)(NSArray<NSURL *> * _Nullable, NSArray<NSURL *> *, NSError * _Nullable)) {
    if (index >= sourceURLs.count) { completion(prepared, temporary, nil); return; }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURLs[index] options:nil];
    if (![asset tracksWithMediaType:AVMediaTypeVideo].count) {
        completion(nil, temporary, EZMusicError(EZMusicServiceErrorInvalidInput, @"Choose a video file for Video Soundtrack.", nil));
        return;
    }
    // Normalize the source rather than merely changing its extension.  This
    // strips HEVC/HDR and high-resolution iPhone capture variants and creates
    // the conventional 720p H.264/AAC MP4 ingest format.
    NSString *preset = [[AVAssetExportSession exportPresetsCompatibleWithAsset:asset] containsObject:AVAssetExportPreset1280x720]
        ? AVAssetExportPreset1280x720 : AVAssetExportPresetMediumQuality;
    AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];
    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"music-upload-%@.mp4", NSUUID.UUID.UUIDString]]];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
    if (!exporter || ![exporter.supportedFileTypes containsObject:AVFileTypeMPEG4]) {
        completion(nil, temporary, EZMusicError(EZMusicServiceErrorInvalidInput, @"This video can't be converted to a compatible H.264 MP4.", nil));
        return;
    }
    exporter.outputURL = outputURL;
    exporter.outputFileType = AVFileTypeMPEG4;
    exporter.shouldOptimizeForNetworkUse = YES;
    [exporter exportAsynchronouslyWithCompletionHandler:^{
        if (exporter.status != AVAssetExportSessionStatusCompleted || !EZMusicIsH264MP4(outputURL)) {
            [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
            NSError *error = exporter.error;
            completion(nil, temporary, EZMusicError(EZMusicServiceErrorInvalidInput,
                error.localizedDescription ?: @"This video could not be normalized to an H.264 MP4.", error ? @{ NSUnderlyingErrorKey: error } : nil));
            return;
        }
        [prepared addObject:outputURL];
        [temporary addObject:outputURL];
        EZMusicPrepareVideoAtIndex(sourceURLs, prepared, temporary, index + 1, completion);
    }];
}

// ElevenLabs accepts MP4/MOV containers, but rejects some otherwise valid iOS
// recordings when their codec profile is not in its ingest set.  Re-exporting
// through AVFoundation produces an explicitly encoded H.264 MP4 copy.
static void EZMusicPrepareVideosForUpload(NSArray<NSURL *> *sourceURLs,
                                          void (^completion)(NSArray<NSURL *> * _Nullable preparedURLs,
                                                             NSArray<NSURL *> *temporaryURLs,
                                                             NSError * _Nullable error)) {
    EZMusicPrepareVideoAtIndex(sourceURLs, [NSMutableArray arrayWithCapacity:sourceURLs.count],
                               [NSMutableArray arrayWithCapacity:sourceURLs.count], 0, completion);
}

@interface EZMusicService ()
- (instancetype)initPrivate;
@end

@implementation EZMusicService

+ (instancetype)sharedService {
    static EZMusicService *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sharedInstance = [[EZMusicService alloc] initPrivate]; });
    return sharedInstance;
}

- (instancetype)initPrivate {
    return [super init];
}

#pragma mark - Core request

// Sends one action to the Edge Function and hands back the parsed JSON.
// Handles: token refresh, one 401 re-auth retry, transient-network and 5xx
// retries with backoff, and translation of server errors into NSError.
- (void)performAction:(NSString *)action
              payload:(NSDictionary *)payload
           completion:(void (^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {
    NSMutableDictionary *body = [payload mutableCopy] ?: [NSMutableDictionary dictionary];
    body[@"action"] = action;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, EZMusicError(EZMusicServiceErrorInvalidInput, @"That request couldn't be prepared.", nil));
        });
        return;
    }
    [self sendBodyData:bodyData action:action retriesLeft:kMaxNetworkRetries didReauthenticate:NO completion:completion];
}

- (void)sendBodyData:(NSData *)bodyData
              action:(NSString *)action
         retriesLeft:(NSInteger)retriesLeft
   didReauthenticate:(BOOL)didReauthenticate
          completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {

    [[EZAuthManager shared] getValidAccessToken:^(NSString * _Nullable token, NSError * _Nullable authError) {
        if (token.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, EZMusicError(EZMusicServiceErrorNotSignedIn, @"Please sign in to use music generation.", nil));
            });
            return;
        }

        NSURL *url = [NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/ez-music"]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:kRequestTimeoutSeconds];
        request.HTTPMethod = @"POST";
        request.HTTPBody = bodyData;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];

        [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;

            // Dropped connection: retry with the same body. Safe because the server
            // dedupes generation by generation_id and every other action is idempotent.
            if (networkError) {
                if (EZMusicIsTransientNetworkError(networkError) && retriesLeft > 0) {
                    NSInteger attemptNumber = kMaxNetworkRetries - retriesLeft + 1;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetryBaseDelaySeconds * attemptNumber * NSEC_PER_SEC)),
                                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        [self sendBodyData:bodyData action:action retriesLeft:retriesLeft - 1
                         didReauthenticate:didReauthenticate completion:completion];
                    });
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, EZMusicError(EZMusicServiceErrorNetwork,
                        @"Couldn't reach the server. Check your connection and try again.",
                        @{NSUnderlyingErrorKey: networkError}));
                });
                return;
            }

            // Expired token that slipped past the pre-check: re-auth once.
            if (statusCode == 401 && !didReauthenticate) {
                [self sendBodyData:bodyData action:action retriesLeft:retriesLeft
                 didReauthenticate:YES completion:completion];
                return;
            }

            // Gateway-type failures are transient; try again before surfacing them.
            if ((statusCode == 502 || statusCode == 503 || statusCode == 504) && retriesLeft > 0) {
                NSInteger attemptNumber = kMaxNetworkRetries - retriesLeft + 1;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetryBaseDelaySeconds * attemptNumber * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    [self sendBodyData:bodyData action:action retriesLeft:retriesLeft - 1
                     didReauthenticate:didReauthenticate completion:completion];
                });
                return;
            }

            id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *json = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;

            NSError *resultError = nil;
            if (statusCode == 401) {
                resultError = EZMusicError(EZMusicServiceErrorNotSignedIn, @"Your session expired. Please sign in again.", nil);
            } else if (statusCode < 200 || statusCode > 299) {
                NSString *serverCode = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"";
                NSString *message = [json[@"message"] isKindOfClass:[NSString class]]
                    ? json[@"message"] : @"The music service had a problem. Please try again.";
                NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:serverCode
                                                                                forKey:EZMusicServiceServerCodeKey];
                if (json[@"coins_required"]) info[@"coins_required"] = json[@"coins_required"];
                resultError = EZMusicError(EZMusicServiceErrorServer, message, info);
            } else if (!json) {
                resultError = EZMusicError(EZMusicServiceErrorBadResponse, @"The server sent an unexpected reply.", nil);
            }

            if (resultError) {
                EZLogf(EZLogLevelWarning, @"Music", @"%@ failed (HTTP %ld): %@", action, (long)statusCode, resultError.localizedDescription);
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(resultError ? nil : json, resultError); });
        }] resume];
    }];
}

#pragma mark - Config

- (void)fetchConfigWithCompletion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    [self performAction:@"config" payload:@{} completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *config = [json[@"config"] isKindOfClass:[NSDictionary class]] ? json[@"config"] : nil;
        if (!error && !config) error = EZMusicError(EZMusicServiceErrorBadResponse, @"The server sent an unexpected reply.", nil);
        completion(error ? nil : config, error);
    }];
}

- (void)generateMusicForVideoURLs:(NSArray<NSURL *> *)videoURLs description:(NSString *)description completion:(void (^)(NSData *, NSError *))completion {
    if (!videoURLs.count || videoURLs.count > 10) {
        completion(nil, EZMusicError(EZMusicServiceErrorInvalidInput, @"Choose 1–10 videos.", nil));
        return;
    }

    EZMusicPrepareVideosForUpload(videoURLs, ^(NSArray<NSURL *> *preparedURLs, NSArray<NSURL *> *temporaryURLs, NSError *preparationError) {
        if (preparationError) {
            for (NSURL *url in temporaryURLs) [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, preparationError); });
            return;
        }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *boundary = [NSString stringWithFormat:@"EZMusic%@", NSUUID.UUID.UUIDString];
        NSMutableData *body = [NSMutableData data];
        void (^field)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
            [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", boundary, name, value]
                              dataUsingEncoding:NSUTF8StringEncoding]];
        };
        field(@"action", @"video_to_music");
        NSString *trimmedDescription = [description stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmedDescription.length) field(@"description", [trimmedDescription substringToIndex:MIN(trimmedDescription.length, 4100)]);

        NSUInteger totalBytes = 0;
        for (NSURL *url in preparedURLs) {
            NSError *readError = nil;
            NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
            if (!data.length) {
                for (NSURL *temporaryURL in temporaryURLs) [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, EZMusicError(EZMusicServiceErrorInvalidInput, @"Couldn’t read a selected video.", readError ? @{ NSUnderlyingErrorKey: readError } : nil)); });
                return;
            }
            totalBytes += data.length;
            if (totalBytes > kMaximumVideoBytes) {
                for (NSURL *temporaryURL in temporaryURLs) [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, EZMusicError(EZMusicServiceErrorInvalidInput, @"Choose videos totaling 200 MB or less.", nil)); });
                return;
            }
            NSString *filename = url.lastPathComponent.length ? url.lastPathComponent : @"video";
            [body appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"videos[]\"; filename=\"%@\"\r\nContent-Type: %@\r\n\r\n", boundary, filename, EZMusicVideoMimeType(url)] dataUsingEncoding:NSUTF8StringEncoding]];
            [body appendData:data];
            [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
        [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

        [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *authError) {
            if (!token.length) {
                for (NSURL *temporaryURL in temporaryURLs) [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, EZMusicError(EZMusicServiceErrorNotSignedIn, @"Please sign in to use music generation.", authError ? @{ NSUnderlyingErrorKey: authError } : nil)); });
                return;
            }
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/ez-music"]]
                                                                   cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                               timeoutInterval:300.0];
            request.HTTPMethod = @"POST";
            request.HTTPBody = body;
            [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
            [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
            [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
            [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                BOOL succeeded = !error && status >= 200 && status < 300 && EZMusicLooksLikeMP3(data);
                NSError *resultError = succeeded ? nil : EZMusicVideoError(data, status, error);
                if (!succeeded && !error && status >= 200 && status < 300) {
                    resultError = EZMusicError(EZMusicServiceErrorBadResponse, @"The music service returned an unusable audio file. Please try again.", nil);
                }
                if (resultError) EZLogf(EZLogLevelWarning, @"Music", @"Video-to-music failed (HTTP %ld): %@", (long)status, resultError.localizedDescription);
                for (NSURL *temporaryURL in temporaryURLs) [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(succeeded ? data : nil, resultError); });
            }] resume];
        }];
    });
    });
}

#pragma mark - Generation

- (void)startGenerationWithPrompt:(NSString *)prompt
                  compositionPlan:(NSDictionary *)compositionPlan
                            title:(NSString *)title
                  durationSeconds:(NSInteger)durationSeconds
                     variantCount:(NSInteger)variantCount
                forceInstrumental:(BOOL)forceInstrumental
                       completion:(void (^)(NSString *, NSArray<NSDictionary *> *, NSInteger, NSError *))completion {

    NSString *trimmedPrompt = [prompt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL hasPrompt = trimmedPrompt.length > 0;
    BOOL hasPlan = compositionPlan.count > 0;
    if (hasPrompt == hasPlan) {   // neither, or both
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, nil, 0, EZMusicError(EZMusicServiceErrorInvalidInput,
                hasPrompt ? @"Use either a description or a composition plan, not both."
                          : @"Describe the music you want.", nil));
        });
        return;
    }

    // One ID per user action. Network retries inside -performAction reuse this
    // same body, so a retry can never be charged as a second song.
    NSString *generationID = [[NSUUID UUID].UUIDString lowercaseString];

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"generation_id"] = generationID;
    payload[@"variant_count"] = @(MAX(1, variantCount));
    if (hasPrompt) {
        payload[@"prompt"] = trimmedPrompt;
        payload[@"duration_seconds"] = @(durationSeconds);
        if (forceInstrumental) payload[@"force_instrumental"] = @YES;
    } else {
        payload[@"composition_plan"] = compositionPlan;
    }
    if (title.length > 0) payload[@"title"] = title;

    [self performAction:@"generate" payload:payload completion:^(NSDictionary *json, NSError *error) {
        if (error) { completion(nil, nil, 0, error); return; }

        NSArray<NSDictionary *> *entries = EZMusicEntryDictionaries(json[@"entries"]);
        if (entries.count == 0) {
            completion(nil, nil, 0, EZMusicError(EZMusicServiceErrorBadResponse, @"The server sent an unexpected reply.", nil));
            return;
        }
        NSInteger balance = [json[@"balance"] isKindOfClass:[NSNumber class]] ? [json[@"balance"] integerValue] : -1;
        if (balance >= 0) {
            [[EZEntitlementManager shared] applyKnownBalance:balance];
        } else {
            [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger refreshedBalance) {}];
        }
        completion(generationID, entries, MAX(balance, 0), nil);
    }];
}

- (void)startGenerationWithPrompt:(NSString *)prompt
                            lyrics:(NSString *)lyrics
                      referenceURL:(NSURL *)referenceURL
                     referenceMode:(NSString *)referenceMode
                            title:(NSString *)title
                  durationSeconds:(NSInteger)durationSeconds
                     variantCount:(NSInteger)variantCount
                forceInstrumental:(BOOL)forceInstrumental
                       completion:(void (^)(NSString *, NSArray<NSDictionary *> *, NSInteger, NSError *))completion {
    NSString *trimmedPrompt = [prompt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *trimmedLyrics = [lyrics stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedPrompt.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, nil, 0, EZMusicError(EZMusicServiceErrorInvalidInput, @"Describe the music you want.", nil));
        });
        return;
    }
    if (trimmedPrompt.length > 4100 || trimmedLyrics.length > 6100) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, nil, 0, EZMusicError(EZMusicServiceErrorInvalidInput, @"The description or lyrics are too long.", nil));
        });
        return;
    }

    NSMutableDictionary *payload = [@{
        @"generation_id": [[NSUUID UUID].UUIDString lowercaseString],
        @"prompt": trimmedPrompt,
        @"duration_seconds": @(durationSeconds),
        @"variant_count": @(MAX(1, variantCount)),
    } mutableCopy];
    if (trimmedLyrics.length) payload[@"lyrics"] = trimmedLyrics;
    if (title.length) payload[@"title"] = title;
    if (forceInstrumental) payload[@"force_instrumental"] = @YES;

    if (referenceURL.isFileURL) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:referenceURL options:nil];
        CMTime duration = asset.duration;
        NSInteger durationMs = CMTIME_IS_NUMERIC(duration) ? (NSInteger)llround(CMTimeGetSeconds(duration) * 1000.0) : 0;
        if (durationMs <= 0 || durationMs > 120000) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, nil, 0, EZMusicError(EZMusicServiceErrorInvalidInput,
                    @"Audio references must be two minutes or shorter. Choose a section before generating.", nil));
            });
            return;
        }
        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfURL:referenceURL options:NSDataReadingMappedIfSafe error:&readError];
        if (!data || data.length == 0 || data.length > kMaximumReferenceBytes) {
            NSString *message = data.length > kMaximumReferenceBytes
                ? @"That reference is over the 12 MB upload limit. Choose a shorter clip or a compressed copy."
                : @"Couldn’t read that audio reference.";
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, nil, 0, EZMusicError(EZMusicServiceErrorInvalidInput, message,
                    readError ? @{ NSUnderlyingErrorKey: readError } : nil));
            });
            return;
        }
        NSString *extension = referenceURL.pathExtension.lowercaseString;
        NSDictionary *mimeTypes = @{ @"mp3": @"audio/mpeg", @"m4a": @"audio/mp4", @"aac": @"audio/aac",
                                      @"wav": @"audio/wav", @"aif": @"audio/aiff", @"aiff": @"audio/aiff",
                                      @"flac": @"audio/flac", @"ogg": @"audio/ogg", @"opus": @"audio/ogg" };
        payload[@"reference"] = @{
            @"audio_base64": [data base64EncodedStringWithOptions:0],
            @"filename": referenceURL.lastPathComponent ?: @"reference.m4a",
            @"mime_type": mimeTypes[extension] ?: @"application/octet-stream",
            @"mode": [referenceMode isEqualToString:@"source"] ? @"source" : @"style",
            @"duration_ms": @(MAX(0, durationMs)),
        };
    }

    NSString *generationID = payload[@"generation_id"];
    [self performAction:@"generate" payload:payload completion:^(NSDictionary *json, NSError *error) {
        if (error) { completion(nil, nil, 0, error); return; }
        NSArray<NSDictionary *> *entries = EZMusicEntryDictionaries(json[@"entries"]);
        if (entries.count == 0) { completion(nil, nil, 0, EZMusicError(EZMusicServiceErrorBadResponse, @"The server sent an unexpected reply.", nil)); return; }
        NSInteger balance = [json[@"balance"] isKindOfClass:[NSNumber class]] ? [json[@"balance"] integerValue] : -1;
        if (balance >= 0) [[EZEntitlementManager shared] applyKnownBalance:balance];
        else [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger refreshedBalance) {}];
        completion(generationID, entries, MAX(balance, 0), nil);
    }];
}

- (EZMusicPollToken *)pollGenerationWithID:(NSString *)generationID
                                  progress:(void (^)(NSArray<NSDictionary *> *))progress
                                completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    EZMusicPollToken *token = [[EZMusicPollToken alloc] init];
    NSDate *startedAt = [NSDate date];
    [self pollStep:generationID token:token startedAt:startedAt interval:kPollInitialIntervalSeconds
 consecutiveFailures:0 progress:progress completion:completion];
    return token;
}

- (void)pollStep:(NSString *)generationID
           token:(EZMusicPollToken *)token
       startedAt:(NSDate *)startedAt
        interval:(NSTimeInterval)interval
consecutiveFailures:(NSInteger)consecutiveFailures
        progress:(void (^)(NSArray<NSDictionary *> *))progress
      completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {

    // Wait first: the song was only just queued, so an immediate check is wasted.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token.cancelled) return;

        [self performAction:@"status" payload:@{@"generation_id": generationID} completion:^(NSDictionary *json, NSError *error) {
            if (token.cancelled) return;

            NSTimeInterval nextInterval = MIN(interval * 1.3, kPollMaxIntervalSeconds);

            if (error) {
                // Not-signed-in and server rejections won't fix themselves; a bad
                // connection might, so tolerate a few in a row before giving up.
                BOOL isRetryable = error.code == EZMusicServiceErrorNetwork || error.code == EZMusicServiceErrorBadResponse;
                if (!isRetryable || consecutiveFailures + 1 >= kPollMaxConsecutiveFailures) {
                    completion(nil, error);
                    return;
                }
                [self pollStep:generationID token:token startedAt:startedAt interval:nextInterval
          consecutiveFailures:consecutiveFailures + 1 progress:progress completion:completion];
                return;
            }

            NSArray<NSDictionary *> *entries = EZMusicEntryDictionaries(json[@"entries"]);
            if (progress) progress(entries);

            if (entries.count > 0 && !EZMusicAnyEntryPending(entries)) {
                [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {}];
                completion(entries, nil);
                return;
            }
            if ([[NSDate date] timeIntervalSinceDate:startedAt] > kPollOverallLimitSeconds) {
                completion(entries, EZMusicError(EZMusicServiceErrorPollTimedOut,
                    @"This song is taking longer than expected. Check your library again in a few minutes; unfinished songs are refunded automatically.", nil));
                return;
            }
            [self pollStep:generationID token:token startedAt:startedAt interval:nextInterval
      consecutiveFailures:0 progress:progress completion:completion];
        }];
    });
}

#pragma mark - Library

- (void)fetchLibraryBefore:(NSString *)beforeTimestamp
                     limit:(NSInteger)limit
                completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObject:@(limit) forKey:@"limit"];
    if (beforeTimestamp.length > 0) payload[@"before"] = beforeTimestamp;
    [self performAction:@"status" payload:payload completion:^(NSDictionary *json, NSError *error) {
        completion(error ? nil : EZMusicEntryDictionaries(json[@"entries"]), error);
    }];
}

- (void)fetchPlaybackURLForEntryID:(NSString *)entryID
                       forDownload:(BOOL)forDownload
                        completion:(void (^)(NSURL *, NSError *))completion {
    [self performAction:@"signed_url" payload:@{@"entry_id": entryID, @"download": @(forDownload)}
             completion:^(NSDictionary *json, NSError *error) {
        NSString *urlString = [json[@"url"] isKindOfClass:[NSString class]] ? json[@"url"] : nil;
        NSURL *url = urlString ? [NSURL URLWithString:urlString] : nil;
        if (!error && !url) error = EZMusicError(EZMusicServiceErrorBadResponse, @"The server sent an unexpected reply.", nil);
        completion(error ? nil : url, error);
    }];
}

- (void)setFavorite:(BOOL)isFavorite forEntryID:(NSString *)entryID completion:(void (^)(NSError *))completion {
    [self performAction:@"set_favorite" payload:@{@"entry_id": entryID, @"is_favorite": @(isFavorite)}
             completion:^(NSDictionary *json, NSError *error) { completion(error); }];
}

- (void)deleteEntryID:(NSString *)entryID completion:(void (^)(NSError *))completion {
    [self performAction:@"delete" payload:@{@"entry_id": entryID}
             completion:^(NSDictionary *json, NSError *error) { completion(error); }];
}

@end
