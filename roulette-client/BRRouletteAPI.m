// BRRouletteAPI.m
// EZCompleteUI v1.0
//
// Purpose:
//   See BRRouletteAPI.h. Builds authenticated POST requests to the
//   br-roulette Edge Function, refreshes an expired session token through
//   EZAuthManager, retries once on transient network errors and turns every
//   failure into a short message the UI can show as-is.
//
// Changes from v0 (new file):
//   - Initial version.

#import "BRRouletteAPI.h"
#import "EZAuthManager.h"
#import "EZSupabaseConfig.h"

static const NSTimeInterval kRouletteRequestTimeout = 12.0;

@implementation BRRouletteAPI

+ (NSURLSession *)session {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = kRouletteRequestTimeout;
        configuration.waitsForConnectivity = NO;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

+ (void)performAction:(NSString *)action params:(NSDictionary *)params completion:(BRRouletteCompletion)completion {
    [self performAction:action params:params attempt:1 completion:completion];
}

+ (void)performAction:(NSString *)action
               params:(NSDictionary *)params
              attempt:(NSInteger)attempt
           completion:(BRRouletteCompletion)completion {
    // getValidAccessToken refreshes the session first when it is close to expiry.
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *tokenError) {
        if (token.length == 0) {
            [self finish:completion json:nil status:0
                 message:NSLocalizedStringWithDefaultValue(@"BRRoulette.Error.SignIn", nil, NSBundle.mainBundle, @"Please sign in to play roulette.", nil)];
            return;
        }

        NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:params ?: @{}];
        body[@"action"] = action;
        NSError *encodeError = nil;
        NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encodeError];
        if (!bodyData) {
            [self finish:completion json:nil status:0 message:@"Couldn't build that request."];
            return;
        }

        NSURL *url = [NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/br-roulette"]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        request.HTTPBody = bodyData;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];

        [[[self session] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSInteger status = [(NSHTTPURLResponse *)response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;

            // Transient failures (offline blip, timeout, 502/503/504): try once more.
            BOOL transient = networkError != nil || status == 502 || status == 503 || status == 504;
            if (transient && attempt < 2) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self performAction:action params:params attempt:attempt + 1 completion:completion];
                });
                return;
            }
            if (networkError) {
                [self finish:completion json:nil status:0
                     message:NSLocalizedStringWithDefaultValue(@"BRRoulette.Error.Network", nil, NSBundle.mainBundle, @"Connection problem. Reconnecting…", nil)];
                return;
            }

            id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *json = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
            if (status >= 200 && status < 300 && json) {
                [self finish:completion json:json status:status message:nil];
                return;
            }
            NSString *message = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"]
                : NSLocalizedStringWithDefaultValue(@"BRRoulette.Error.Generic", nil, NSBundle.mainBundle, @"Roulette is temporarily unavailable.", nil);
            [self finish:completion json:json status:status message:message];
        }] resume];
    }];
}

+ (void)finish:(BRRouletteCompletion)completion json:(NSDictionary *)json status:(NSInteger)status message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(json, status, message); });
}

@end
