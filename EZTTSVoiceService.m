//
//  EZTTSVoiceService.m
//  EZTTSLibrary
//

#import "EZTTSVoiceService.h"
#import "EZAuthManager.h"
#import "helpers.h"

NSString * const EZTTSVoiceServiceErrorDomain = @"EZTTSVoiceServiceErrorDomain";

// Stashes a human-readable alert title alongside the standard localized description,
// so callers that want to show it (e.g. TextToSpeechViewController's existing alert
// style) can, without this service knowing anything about UIAlertController.
static NSString * const kEZVoiceServiceTitleKey = @"EZTTSVoiceServiceAlertTitle";

static NSError *EZVoiceServiceError(NSInteger code, NSString *title, NSString *message) {
    return [NSError errorWithDomain:EZTTSVoiceServiceErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: message, kEZVoiceServiceTitleKey: title}];
}

@implementation EZTTSVoiceService

#pragma mark - Saved voice settings (Settings page sliders)

static NSString * const kEZTTSVoiceStabilityKey  = @"EZTTSVoiceStability";
static NSString * const kEZTTSVoiceStyleKey      = @"EZTTSVoiceStyle";
static NSString * const kEZTTSVoiceSimilarityKey = @"EZTTSVoiceSimilarity";
static NSString * const kEZTTSVoiceBoostKey      = @"EZTTSVoiceSpeakerBoost";
static NSString * const kEZTTSVoiceSpeedKey      = @"EZTTSVoiceSpeed";

static float EZTTSSavedFloat(NSString *key, float fallback) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:key] ? [defaults floatForKey:key] : fallback;
}

+ (float)savedStability       { return EZTTSSavedFloat(kEZTTSVoiceStabilityKey, 0.5f); }
+ (float)savedStyle           { return EZTTSSavedFloat(kEZTTSVoiceStyleKey, 0.0f); }
+ (float)savedSimilarityBoost { return EZTTSSavedFloat(kEZTTSVoiceSimilarityKey, 0.75f); }
+ (float)savedSpeed           { return EZTTSSavedFloat(kEZTTSVoiceSpeedKey, 1.0f); }
+ (BOOL)savedSpeakerBoost     { return [[NSUserDefaults standardUserDefaults] boolForKey:kEZTTSVoiceBoostKey]; }

+ (void)saveStability:(float)value       { [[NSUserDefaults standardUserDefaults] setFloat:value forKey:kEZTTSVoiceStabilityKey]; }
+ (void)saveStyle:(float)value           { [[NSUserDefaults standardUserDefaults] setFloat:value forKey:kEZTTSVoiceStyleKey]; }
+ (void)saveSimilarityBoost:(float)value { [[NSUserDefaults standardUserDefaults] setFloat:value forKey:kEZTTSVoiceSimilarityKey]; }
+ (void)saveSpeed:(float)value           { [[NSUserDefaults standardUserDefaults] setFloat:value forKey:kEZTTSVoiceSpeedKey]; }
+ (void)saveSpeakerBoost:(BOOL)value     { [[NSUserDefaults standardUserDefaults] setBool:value forKey:kEZTTSVoiceBoostKey]; }

+ (void)resetVoiceSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[kEZTTSVoiceStabilityKey, kEZTTSVoiceStyleKey, kEZTTSVoiceSimilarityKey, kEZTTSVoiceBoostKey, kEZTTSVoiceSpeedKey]) {
        [defaults removeObjectForKey:key];
    }
}

+ (NSDictionary<NSString *, id> *)voiceSettingsPayload {
    return @{
        @"stability":        @([self savedStability]),
        @"style":            @([self savedStyle]),
        @"similarity_boost": @([self savedSimilarityBoost]),
        @"use_speaker_boost": @([self savedSpeakerBoost]),
    };
}

+ (void)fetchVoicesWithCompletion:(void (^)(NSArray<NSDictionary<NSString *, id> *> * _Nullable, NSError * _Nullable))completion
{
    NSString *token = [EZAuthManager shared].accessToken;
    if (token.length == 0) {
        NSError *err = EZVoiceServiceError(1, @"Not logged in", @"Please sign in to fetch voices.");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-elevenlabs"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"action": @"fetch_voices"} options:0 error:nil];

    EZLog(EZLogLevelInfo, @"TTS", @"Fetching voices via Edge Function");

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err) {
                completion(nil, EZVoiceServiceError(2, @"Network error", err.localizedDescription));
                return;
            }

            NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
            if (http.statusCode == 402) {
                completion(nil, EZVoiceServiceError(3, @"Insufficient coins", @"You don't have enough coins for this action."));
                return;
            }
            if (http.statusCode == 403) {
                completion(nil, EZVoiceServiceError(4, @"Not authorized", @"Please sign in and try again."));
                return;
            }
            if (http.statusCode != 200) {
                NSString *msg = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"Server error";
                completion(nil, EZVoiceServiceError(5, @"Error", msg ?: @"Server error"));
                return;
            }

            NSError *jsonError;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (jsonError) {
                completion(nil, EZVoiceServiceError(6, @"Parse error", jsonError.localizedDescription));
                return;
            }

            NSArray *voicesArray = nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                voicesArray = json[@"voices"];
            } else if ([json isKindOfClass:[NSArray class]]) {
                voicesArray = json;
            }
            if (!voicesArray) {
                completion(nil, EZVoiceServiceError(7, @"Unexpected response", @"Voices response format was unexpected."));
                return;
            }

            NSMutableArray<NSDictionary *> *safe = [NSMutableArray array];
            for (id item in voicesArray) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *voice = (NSDictionary *)item;
                // The "famous"/celebrity-lookalike voices don't have their own category —
                // they live under "professional", which also throws an API error when used
                // outside the ElevenLabs app itself. Filtering the whole category out here
                // leaves premade + cloned voices, which is what's actually usable.
                id category = voice[@"category"];
                if ([category isKindOfClass:[NSString class]] &&
                    [[(NSString *)category lowercaseString] isEqualToString:@"professional"]) {
                    continue;
                }
                [safe addObject:voice];
            }
            EZLogf(EZLogLevelInfo, @"TTS", @"Fetched %lu voices", (unsigned long)safe.count);
            completion([safe copy], nil);
        });
    }] resume];
}

@end
