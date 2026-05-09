// EZEntitlementManager.m
// EZCompleteUI

#import "EZEntitlementManager.h"
#import "EZAuthManager.h"

static NSString *const kSupabaseURL = @"https://spuoimtqofhbdzosrbng.supabase.co";

@interface EZEntitlementManager ()
@property (nonatomic, readwrite) NSInteger coinBalance;
@property (nonatomic, readwrite) NSString  *currentTier;
@end

@implementation EZEntitlementManager

+ (instancetype)shared {
    static EZEntitlementManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _coinBalance = 0;
        _currentTier = @"none";
    }
    return self;
}

// ── Feature → flat feature string (for non-chat features) ────────────────────

- (NSString *)featureStringForFeature:(EZFeature)feature {
    switch (feature) {
        case EZFeatureChatMini:        return @"chat_mini";
        case EZFeatureChatGPT4o:       return @"chat_standard";
        case EZFeatureImageLow:        return @"image_low";
        case EZFeatureImageMedium:     return @"image_medium";
        case EZFeatureImageHigh:       return @"image_high";
        case EZFeatureDalle3Standard:  return @"dalle3_standard";
        case EZFeatureDalle3HD:        return @"dalle3_hd";
        case EZFeatureSora10s:         return @"sora_10s";
        case EZFeatureSoraPro10s:      return @"sora_pro_10s";
        case EZFeatureTTS500Chars:     return @"tts";
        case EZFeatureVoiceClone:      return @"voice_clone";
        case EZFeatureWhisperMinute:   return @"whisper_minute";
    }
}

// ── Internal: POST to check-entitlement ───────────────────────────────────────

- (void)postEntitlementBody:(NSDictionary *)bodyDict
                 completion:(void(^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"EZEntitlement" code:401
                userInfo:@{NSLocalizedDescriptionKey: @"Not logged in"}]);
        });
        return;
    }

    NSURL *url = [NSURL URLWithString:[kSupabaseURL
        stringByAppendingString:@"/functions/v1/check-entitlement"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { completion(nil, error); return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data]
                                                                 options:0 error:nil];
            completion(json, nil);
        });
    }] resume];
}

// ── checkEntitlementForFeature:estimatedTokens:featureTier:completion: ────────
// Primary method for chat completions. Passes estimated token count so the
// edge function can deduct the right coin amount based on the actual payload.

- (void)checkEntitlementForFeature:(EZFeature)feature
                   estimatedTokens:(NSInteger)estimatedTokens
                        featureTier:(NSString *)featureTier
                         completion:(void(^)(BOOL allowed,
                                            NSInteger balance,
                                            NSString * _Nullable reason))completion {
    NSMutableDictionary *body = [@{
        @"action":  @"check",
        @"feature": featureTier ?: [self featureStringForFeature:feature],
    } mutableCopy];

    if (estimatedTokens > 0) {
        body[@"estimated_tokens"] = @(estimatedTokens);
    }

    [self postEntitlementBody:body completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(NO, self.coinBalance, error.localizedDescription ?: @"Network error");
            return;
        }
        BOOL allowed      = [json[@"allowed"] boolValue];
        NSInteger balance = [json[@"balance"] integerValue];
        NSString *reason  = json[@"reason"];

        self.coinBalance = balance;
        if (json[@"tier"]) self.currentTier = json[@"tier"];

        completion(allowed, balance, reason);
    }];
}

// ── checkEntitlementForFeature:completion: ────────────────────────────────────
// Legacy/flat-rate variant — used for image, sora, voice clone, etc.
// These features have a fixed coin cost so no token estimate needed.

- (void)checkEntitlementForFeature:(EZFeature)feature
                        completion:(void(^)(BOOL allowed,
                                           NSInteger balance,
                                           NSString * _Nullable reason))completion {
    [self checkEntitlementForFeature:feature
                     estimatedTokens:0
                          featureTier:[self featureStringForFeature:feature]
                           completion:completion];
}

// ── refreshBalanceWithCompletion: ─────────────────────────────────────────────
// Read-only balance fetch — no coin deduction. Safe to call on launch,
// foreground, and whenever the UI needs to display the current balance.

- (void)refreshBalanceWithCompletion:(void(^)(NSInteger balance))completion {
    [self postEntitlementBody:@{@"action": @"check_balance"}
                   completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            if (completion) completion(self.coinBalance);
            return;
        }
        NSInteger balance = [json[@"balance"] integerValue];
        self.coinBalance  = balance;
        if (json[@"tier"]) self.currentTier = json[@"tier"];
        if (completion) completion(balance);
    }];
}

// ── refundTokensForTier:estimatedTokens:actualTokens: ─────────────────────────
// Called after API completion returns actual token usage.
// If actual < estimated, credits the difference back to the user's balance.
// Fire-and-forget — logs success/failure internally.

- (void)refundTokensForTier:(NSString *)tier
            estimatedTokens:(NSInteger)estimatedTokens
               actualTokens:(NSInteger)actualTokens {
    if (actualTokens >= estimatedTokens) return;

    [self postEntitlementBody:@{
        @"action":           @"refund_tokens",
        @"tier":             tier ?: @"chat_standard",
        @"estimated_tokens": @(estimatedTokens),
        @"actual_tokens":    @(actualTokens),
    } completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            NSLog(@"[EZEntitlement] Refund network error: %@", error.localizedDescription);
            return;
        }
        NSInteger refunded = [json[@"refunded"] integerValue];
        if (refunded > 0) {
            self.coinBalance = [json[@"balance"] integerValue];
            NSLog(@"[EZEntitlement] Refunded %ld coins, balance now: %ld",
                  (long)refunded, (long)self.coinBalance);
        }
    }];
}

@end
