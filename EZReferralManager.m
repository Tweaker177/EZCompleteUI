// EZReferralManager.m
// EZCompleteUI
//
// Companion to EZReferralManager.h. Talks to the `referral` Supabase
// Edge Function:
//   POST {"action":"my_code"}            -> {"code":"XXXXXX"}
//   POST {"action":"apply","code":"..."} -> {"status":"rewarded", ...}
// Coin grants (200 to the referrer, 200 to the new user) are made by
// that function only. See the referral server spec in the goal files.

#import "EZReferralManager.h"
#import "EZAuthManager.h"
#import "EZSupabaseConfig.h"

// ── Share targets ────────────────────────────────────────────────────────────
// AltStore: the source this app itself ships through (see ALTSTORE_SETUP.md).
static NSString *const kEZAltStoreDeepLink =
    @"altstore://source?url=https://raw.githubusercontent.com/Tweaker177/EZCompleteUI/main/apps.json";
// Jailbreak: the YouRepo repo hosting the .deb.
static NSString *const kEZJailbreakRepoURL = @"https://i0s-tweak3r-betas.yourepo.com/";

// ── ElevenLabs affiliate link ────────────────────────────────────────────────
// TODO(owner): after joining the Creator Affiliate Program on PartnerStack
// (elevenlabs.io/affiliates), replace this with the personal tracking link
// from the PartnerStack dashboard. The plain site URL below works as a link
// but attributes no commission. Program rules: no self-referrals, and the
// affiliate relationship must be disclosed next to the link (Settings does).
static NSString *const kEZElevenLabsAffiliateURL = @"https://elevenlabs.io/";

// ── Local storage keys ───────────────────────────────────────────────────────
static NSString *const kEZReferralCodeCacheKey   = @"EZReferralCode";
static NSString *const kEZPendingReferralKey     = @"EZPendingReferralCode";

@implementation EZReferralManager

+ (BOOL)isJailbreakInstall {
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    if ([bundlePath hasPrefix:@"/Applications/"] || [bundlePath hasPrefix:@"/var/jb/"]) {
        return YES;
    }
    // Rootless jailbreaks keep the app in a container-looking path in some
    // install styles; the /var/jb tree existing at all is the tell.
    return [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"];
}

+ (NSString *)shareInstallLink {
    return [self isJailbreakInstall] ? kEZJailbreakRepoURL : kEZAltStoreDeepLink;
}

+ (NSString *)shareMessageWithReferralCode:(NSString *)code {
    NSMutableString *message = [NSMutableString stringWithString:
        @"I'm using EZCompleteUI — a multi-model AI chat app with image, music and voice tools."];
    if (code.length) {
        [message appendFormat:@" Sign up with my referral code %@ and we BOTH get 200 free coins.", code];
    }
    if ([self isJailbreakInstall]) {
        [message appendFormat:@" Get it from this repo: %@", kEZJailbreakRepoURL];
    } else {
        [message appendFormat:@" Add this source in AltStore to install it: %@", kEZAltStoreDeepLink];
    }
    return [message copy];
}

+ (NSString *)elevenLabsAffiliateURL {
    return kEZElevenLabsAffiliateURL;
}

// ── Server plumbing ──────────────────────────────────────────────────────────

+ (void)postAction:(NSDictionary *)body
        completion:(void (^)(NSDictionary * _Nullable json, BOOL transportFailed))completion {
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token.length) {
        completion(nil, YES);
        return;
    }
    NSURL *url = [NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/referral"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            // Only a 200 with a JSON object counts as a server verdict.
            // Anything else (offline, function not deployed yet, proxy
            // error page) is a transport failure so callers retry later
            // instead of treating it as a final answer.
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? (NSHTTPURLResponse *)response : nil;
            if (error || !data.length || (http && http.statusCode != 200)) {
                completion(nil, YES);
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:[NSDictionary class]]) {
                completion(nil, YES);
                return;
            }
            completion(json, NO);
        }] resume];
}

// ── Own code ─────────────────────────────────────────────────────────────────

+ (NSString *)cachedReferralCode {
    NSString *code = [[NSUserDefaults standardUserDefaults] stringForKey:kEZReferralCodeCacheKey];
    return code.length ? code : nil;
}

+ (void)fetchReferralCodeWithCompletion:(void (^)(NSString * _Nullable))completion {
    NSString *cached = [self cachedReferralCode];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }
    [self postAction:@{@"action": @"my_code"} completion:^(NSDictionary *json, BOOL transportFailed) {
        NSString *code = [json[@"code"] isKindOfClass:[NSString class]] ? json[@"code"] : nil;
        if (code.length) {
            [[NSUserDefaults standardUserDefaults] setObject:code forKey:kEZReferralCodeCacheKey];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(code.length ? code : nil); });
    }];
}

// ── Redemption ───────────────────────────────────────────────────────────────

+ (void)stashPendingReferralCode:(NSString *)code {
    NSString *clean = [[code stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if (!clean.length) return;
    [[NSUserDefaults standardUserDefaults] setObject:clean forKey:kEZPendingReferralKey];
}

+ (void)applyPendingReferralCode {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *code = [defaults stringForKey:kEZPendingReferralKey];
    if (!code.length) return;
    if (![EZAuthManager shared].isLoggedIn) return;
    [self postAction:@{@"action": @"apply", @"code": code}
          completion:^(NSDictionary *json, BOOL transportFailed) {
        // Transport failure: keep the code and try again next launch.
        // Any server verdict (rewarded, already applied, invalid code,
        // self-referral) is final: clear the stash and stay silent.
        if (transportFailed) return;
        [defaults removeObjectForKey:kEZPendingReferralKey];
    }];
}

@end
