// EZGitHubService.m
// EZCompleteUI v1.0
//
// See EZGitHubService.h for what this class does and does not do.

#import "EZGitHubService.h"
#import "EZAuthManager.h"
#import "EZSupabaseConfig.h"

NSString * const EZGitHubServiceErrorDomain    = @"EZGitHubServiceErrorDomain";
NSString * const EZGitHubServiceServerCodeKey  = @"EZGitHubServiceServerCode";

// A GitHub call can take up to ~25s on the server (and a repository zip a
// little longer), so leave headroom before the device gives up.
static NSTimeInterval const kRequestTimeoutSeconds = 90.0;
static NSTimeInterval const kRetryDelaySeconds     = 1.5;

static NSError *EZGitHubError(EZGitHubServiceErrorCode code, NSString *message, NSDictionary *extra) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:message
                                                                   forKey:NSLocalizedDescriptionKey];
    if (extra) [info addEntriesFromDictionary:extra];
    return [NSError errorWithDomain:EZGitHubServiceErrorDomain code:code userInfo:info];
}

static BOOL EZGitHubIsTransientNetworkError(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorNotConnectedToInternet:
            return YES;
        default:
            return NO;
    }
}

@implementation EZGitHubService

+ (instancetype)sharedService {
    static EZGitHubService *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[EZGitHubService alloc] initPrivate]; });
    return shared;
}

- (instancetype)initPrivate {
    return [super init];
}

// ── Transport ───────────────────────────────────────────────────────────────

/// Sends one JSON body to ez-github. The completion gets the HTTP status and
/// the parsed JSON object (nil if the body wasn't a JSON object); `error` is
/// set only when the call itself could not be completed.
- (void)postBody:(NSDictionary *)body
      retriesLeft:(NSInteger)retriesLeft
didReauthenticate:(BOOL)didReauthenticate
       completion:(void (^)(NSInteger status, NSDictionary * _Nullable json, NSHTTPURLResponse * _Nullable response, NSError * _Nullable error))completion {

    NSError *encodeError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encodeError];
    if (!bodyData.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(0, nil, nil, EZGitHubError(EZGitHubServiceErrorBadResponse,
                @"That GitHub request couldn't be prepared.", nil));
        });
        return;
    }

    [[EZAuthManager shared] getValidAccessToken:^(NSString * _Nullable token, NSError * _Nullable authError) {
        if (token.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(0, nil, nil, EZGitHubError(EZGitHubServiceErrorNotSignedIn,
                    @"Please sign in to use GitHub.", nil));
            });
            return;
        }

        NSURL *url = [NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/ez-github"]];
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
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? (NSHTTPURLResponse *)response : nil;
            NSInteger status = http.statusCode;

            if (networkError) {
                if (EZGitHubIsTransientNetworkError(networkError) && retriesLeft > 0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetryDelaySeconds * NSEC_PER_SEC)),
                                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        [self postBody:body retriesLeft:retriesLeft - 1
                     didReauthenticate:didReauthenticate completion:completion];
                    });
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(0, nil, nil, EZGitHubError(EZGitHubServiceErrorNetwork,
                        @"Couldn't reach the server. Check your connection and try again.",
                        @{NSUnderlyingErrorKey: networkError}));
                });
                return;
            }

            // Expired token that slipped past the pre-check: re-auth once.
            if (status == 401 && !didReauthenticate) {
                [self postBody:body retriesLeft:retriesLeft didReauthenticate:YES completion:completion];
                return;
            }

            if ((status == 502 || status == 503 || status == 504) && retriesLeft > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetryDelaySeconds * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    [self postBody:body retriesLeft:retriesLeft - 1
                 didReauthenticate:didReauthenticate completion:completion];
                });
                return;
            }

            id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *json = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(status, json, http, nil);
            });
        }] resume];
    }];
}

/// The user-facing message for a failed call, preferring the server's own text.
static NSString *EZGitHubServerMessage(NSDictionary *json, NSInteger status) {
    id message = json[@"error"];
    if ([message isKindOfClass:[NSString class]] && [(NSString *)message length] > 0) return message;
    if (status == 401) return @"Your session expired. Please sign in again.";
    return @"The GitHub service had a problem. Please try again.";
}

/// Maps a status + body to an NSError, or nil when the call succeeded.
static NSError *EZGitHubErrorForResponse(NSInteger status, NSDictionary *json) {
    if (status == 401) {
        return EZGitHubError(EZGitHubServiceErrorNotSignedIn,
            @"Your session expired. Please sign in again.", nil);
    }
    if (status < 200 || status > 299) {
        NSString *code = [json[@"code"] isKindOfClass:[NSString class]] ? json[@"code"] : @"";
        return EZGitHubError(EZGitHubServiceErrorServer, EZGitHubServerMessage(json, status),
                             @{EZGitHubServiceServerCodeKey: code});
    }
    if (!json) {
        return EZGitHubError(EZGitHubServiceErrorBadResponse,
            @"The GitHub service sent an unexpected reply. Please try again.", nil);
    }
    return nil;
}

// ── Public API ──────────────────────────────────────────────────────────────

- (void)connectWithToken:(NSString *)token
              completion:(void (^)(NSString *, NSString *, NSError *))completion {
    NSString *trimmed = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, nil, EZGitHubError(EZGitHubServiceErrorServer, @"Paste a GitHub token first.", nil));
        });
        return;
    }
    // Saving a token is idempotent, so one retry on a dropped connection is safe.
    [self postBody:@{@"op": @"connect", @"token": trimmed} retriesLeft:1 didReauthenticate:NO
        completion:^(NSInteger status, NSDictionary *json, NSHTTPURLResponse *response, NSError *error) {
        if (error) { completion(nil, nil, error); return; }
        NSError *failure = EZGitHubErrorForResponse(status, json);
        if (failure || ![json[@"ok"] boolValue]) {
            completion(nil, nil, failure ?: EZGitHubError(EZGitHubServiceErrorServer,
                                                          EZGitHubServerMessage(json, status), nil));
            return;
        }
        NSString *login = [json[@"login"] isKindOfClass:[NSString class]] ? json[@"login"] : nil;
        NSString *expires = [json[@"token_expires_at"] isKindOfClass:[NSString class]] ? json[@"token_expires_at"] : nil;
        completion(login, expires, nil);
    }];
}

- (void)fetchStatusWithCompletion:(void (^)(BOOL, NSString *, BOOL, NSError *))completion {
    [self postBody:@{@"op": @"status"} retriesLeft:1 didReauthenticate:NO
        completion:^(NSInteger status, NSDictionary *json, NSHTTPURLResponse *response, NSError *error) {
        if (error) { completion(NO, nil, NO, error); return; }
        NSError *failure = EZGitHubErrorForResponse(status, json);
        if (failure) { completion(NO, nil, NO, failure); return; }
        NSString *login = [json[@"login"] isKindOfClass:[NSString class]] ? json[@"login"] : nil;
        completion([json[@"connected"] boolValue], login, [json[@"allow_writes"] boolValue], nil);
    }];
}

- (void)setAllowWrites:(BOOL)allowWrites completion:(void (^)(BOOL, NSError *))completion {
    [self postBody:@{@"op": @"set_permissions", @"allow_writes": @(allowWrites)} retriesLeft:1 didReauthenticate:NO
        completion:^(NSInteger status, NSDictionary *json, NSHTTPURLResponse *response, NSError *error) {
        if (error) { completion(NO, error); return; }
        NSError *failure = EZGitHubErrorForResponse(status, json);
        if (failure || ![json[@"ok"] boolValue]) {
            completion(NO, failure ?: EZGitHubError(EZGitHubServiceErrorServer,
                                                    EZGitHubServerMessage(json, status), nil));
            return;
        }
        completion([json[@"allow_writes"] boolValue], nil);
    }];
}

- (void)disconnectWithCompletion:(void (^)(NSError *))completion {
    [self postBody:@{@"op": @"disconnect"} retriesLeft:1 didReauthenticate:NO
        completion:^(NSInteger status, NSDictionary *json, NSHTTPURLResponse *response, NSError *error) {
        if (error) { completion(error); return; }
        NSError *failure = EZGitHubErrorForResponse(status, json);
        if (failure || ![json[@"ok"] boolValue]) {
            completion(failure ?: EZGitHubError(EZGitHubServiceErrorServer,
                                                EZGitHubServerMessage(json, status), nil));
            return;
        }
        completion(nil);
    }];
}

- (void)runRequest:(NSDictionary *)request
         confirmed:(BOOL)confirmed
        completion:(void (^)(NSDictionary *, NSError *))completion {
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:@{
        @"op": @"run",
        @"request": request ?: @{},
    }];
    if (confirmed) body[@"confirmed"] = @YES;

    // A confirmed write must never be repeated automatically: a retry after a
    // dropped connection could commit twice. Everything else is a read or a
    // preview and is safe to try again.
    NSInteger retries = confirmed ? 0 : 1;

    [self postBody:body retriesLeft:retries didReauthenticate:NO
        completion:^(NSInteger status, NSDictionary *json, NSHTTPURLResponse *response, NSError *error) {
        if (error) { completion(nil, error); return; }
        if (status == 401) { completion(nil, EZGitHubErrorForResponse(status, json)); return; }
        // The server reports GitHub-side and validation failures as a JSON
        // body with ok = false (HTTP 200 or 400): hand those to the caller as
        // a result so the model can be told what went wrong.
        if (json && json[@"ok"] != nil && status >= 200 && status < 500) {
            completion(json, nil);
            return;
        }
        NSError *failure = EZGitHubErrorForResponse(status, json);
        completion(failure ? nil : json, failure);
    }];
}

@end
