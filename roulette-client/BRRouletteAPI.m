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
//   - Every player-facing string goes through NSLocalizedStringWithDefaultValue
//     (keys BRRoulette.*), with the English text as the default value.

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
            [self finish:completion json:nil status:0 message:NSLocalizedStringWithDefaultValue(@"BRRoulette.Error.Request", nil, NSBundle.mainBundle, @"Couldn't build that request.", nil)];
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
            // Prefer our own translation of the server's error code; the server's English text is the last resort.
            NSString *code = [json[@"code"] isKindOfClass:[NSString class]] ? json[@"code"] : nil;
            NSString *message = (status == 401) ? NSLocalizedStringWithDefaultValue(@"BRRoulette.Error.SignIn", nil, NSBundle.mainBundle, @"Please sign in to play roulette.", nil) : [self localizedMessageForServerCode:code];
            if (message.length == 0) {
                message = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"]
                    : NSLocalizedStringWithDefaultValue(@"BRRoulette.Error.Generic", nil, NSBundle.mainBundle, @"Roulette is temporarily unavailable.", nil);
            }
            [self finish:completion json:json status:status message:message];
        }] resume];
    }];
}

/// Translated text for the game error codes br-roulette returns; nil for unknown codes.
+ (NSString *)localizedMessageForServerCode:(NSString *)code {
    if (code.length == 0) return nil;
    if ([code isEqualToString:@"rl_table_not_found"]) return NSLocalizedStringWithDefaultValue(@"BRRoulette.Server.rl_table_not_found", nil, NSBundle.mainBundle, @"That table doesn't exist.", nil);
    if ([code isEqualToString:@"rl_invalid_bet"]) return NSLocalizedStringWithDefaultValue(@"BRRoulette.Server.rl_invalid_bet", nil, NSBundle.mainBundle, @"That bet isn't allowed at this table.", nil);
    if ([code isEqualToString:@"rl_over_limit"]) return NSLocalizedStringWithDefaultValue(@"BRRoulette.Server.rl_over_limit", nil, NSBundle.mainBundle, @"That's over the table limit.", nil);
    if ([code isEqualToString:@"rl_insufficient_coins"]) return NSLocalizedStringWithDefaultValue(@"BRRoulette.Server.rl_insufficient_coins", nil, NSBundle.mainBundle, @"Not enough coins for that.", nil);
    if ([code isEqualToString:@"rl_table_full"]) return NSLocalizedStringWithDefaultValue(@"BRRoulette.Server.rl_table_full", nil, NSBundle.mainBundle, @"This table is full.", nil);
    if ([code isEqualToString:@"rl_active_bets_elsewhere"]) return NSLocalizedStringWithDefaultValue(@"BRRoulette.Server.rl_active_bets_elsewhere", nil, NSBundle.mainBundle, @"Wait for your spin at your other roulette table first.", nil);
    if ([code isEqualToString:@"rl_not_joined"]) return NSLocalizedStringWithDefaultValue(@"BRRoulette.Server.rl_not_joined", nil, NSBundle.mainBundle, @"Take a seat first.", nil);
    if ([code isEqualToString:@"rl_betting_closed"]) return NSLocalizedStringWithDefaultValue(@"BRRoulette.Server.rl_betting_closed", nil, NSBundle.mainBundle, @"Betting just closed. Your next bets count for the next spin.", nil);
    return nil;
}

+ (void)finish:(BRRouletteCompletion)completion json:(NSDictionary *)json status:(NSInteger)status message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(json, status, message); });
}

@end
