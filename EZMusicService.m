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

NSString * const EZMusicServiceErrorDomain    = @"EZMusicServiceErrorDomain";
NSString * const EZMusicServiceServerCodeKey  = @"EZMusicServiceServerCode";

// Request and retry tuning.
static const NSTimeInterval kRequestTimeoutSeconds   = 45.0;
static const NSInteger      kMaxNetworkRetries       = 2;
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
