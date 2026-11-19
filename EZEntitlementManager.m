// EZEntitlementManager.m
// EZCompleteUI
//
// Purpose:
//   iOS client wrapper around the Supabase Edge Function "check-entitlement".
//   Responsible for packaging feature-check and usage-logging requests, caching
//   the coin balance locally for immediate UI updates, and handling post-completion
//   accounting (image counts, token refunds). The actual entitlement logic and
//   ledger writes happen server-side in the edge function.
//
//   EZAuthManager provides the JWT for every request — never read accessToken
//   directly. Always call getValidAccessToken: so expired tokens are refreshed
//   before a request is sent.
//
// Changes:
//   - postEntitlementBody: now calls [EZAuthManager shared] getValidAccessToken:
//     instead of reading the raw accessToken property, which could be expired
//     after the app has been backgrounded. This is the fix for the "invalid token"
//     error users saw on the first action after returning from background.
//   - Factored the actual network call into executeEntitlementRequest:token:
//     retryOnAuthFailure:completion: (private). If the edge function returns HTTP
//     401 (token accepted by the device but rejected server-side), the method
//     refreshes the session and retries once before surfacing an error to the caller.
//     This handles the edge case where the device clock drift or a server-side
//     token revocation causes a rejection even after a local expiry check passes.
//   - Added a richer checkEntitlementForFeature:quantity:prompt:model:quality:size:
//     isEdit:completion: overload. The original 5-param version never sent quality,
//     size, or is_edit at all — only the flattened feature-tier string (image_low/
//     medium/high) — so an image request's pre-flight cost estimate was always
//     computed as if quality were unknown, which check-entitlement's estimator
//     conservatively (and, without the real value, correctly) treats as "high."
//     Every image request was being estimated at high-quality cost regardless of
//     what was actually selected, edit or not. The 5-param version now just
//     delegates to the new one with quality/size/isEdit omitted, for callers with
//     no meaningful quality/size concept — no duplicated request-building logic.

#import "EZEntitlementManager.h"
#import "EZAuthManager.h"

static NSString *const kSupabaseURL = @"https://spuoimtqofhbdzosrbng.supabase.co";

@interface EZEntitlementManager ()
@property (nonatomic, readwrite, nullable) NSNumber *coinBalance;
@property (nonatomic, readwrite, nullable) NSString *currentTier;
@property (nonatomic, readwrite, nullable) NSString *currentStatus;
@property (nonatomic, readwrite) BOOL hasEverPurchased;
@property (nonatomic, readwrite, nullable) NSString *lastLogID;
@end

@implementation EZEntitlementManager

// ── Singleton ─────────────────────────────────────────────────────────────────

+ (instancetype)shared {
    static EZEntitlementManager *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sharedInstance = [[self alloc] init]; });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _coinBalance   = nil;
        _currentTier   = nil;
        _currentStatus = nil;
        _hasEverPurchased = NO;
        _lastLogID     = nil;
    }
    return self;
}

// ── Feature key mapping ───────────────────────────────────────────────────────
// Returns the string identifier the edge function expects for each feature.
// Keep this in sync with the feature enum in EZEntitlementManager.h and the
// feature keys defined in the check-entitlement edge function.

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

// ── Internal POST with auth + retry ──────────────────────────────────────────
// Gets a validated (possibly freshly refreshed) token, then delegates to
// executeEntitlementRequest:. Callers never need to think about token state.

- (void)postEntitlementBody:(NSDictionary *)bodyDict
                 completion:(void(^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *authError) {
        if (!token) {
            // Auth manager couldn't produce a valid token — session is gone
            NSError *noTokenError = authError ?: [NSError errorWithDomain:@"EZEntitlement"
                code:401 userInfo:@{NSLocalizedDescriptionKey: @"Not logged in."}];
            // getValidAccessToken: already dispatches to main queue
            completion(nil, noTokenError);
            return;
        }
        [self executeEntitlementRequest:bodyDict
                                  token:token
                     retryOnAuthFailure:YES
                             completion:completion];
    }];
}

// ── Network execution with 401 retry ─────────────────────────────────────────
// Separated from postEntitlementBody: so the retry path can call back in with
// a fresh token and retryOnAuthFailure:NO to prevent infinite loops.
//
// Why retry at all: getValidAccessToken: validates expiry locally, but the server
// can still reject a token due to clock skew, a revocation, or a Supabase key
// rotation. One retry with a freshly issued token covers these cases cleanly.

- (void)executeEntitlementRequest:(NSDictionary *)bodyDict
                            token:(NSString *)bearerToken
               retryOnAuthFailure:(BOOL)shouldRetry
                       completion:(void(^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {
    NSURL *endpointURL = [NSURL URLWithString:[kSupabaseURL
        stringByAppendingString:@"/functions/v1/check-entitlement"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpointURL];
    request.HTTPMethod      = @"POST";
    request.timeoutInterval = 15;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", bearerToken]
   forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *responseBody, NSURLResponse *urlResponse, NSError *networkError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (networkError) {
                completion(nil, networkError);
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)urlResponse;
            NSDictionary *json = [NSJSONSerialization
                JSONObjectWithData:responseBody ?: [NSData data] options:0 error:nil];

            if (httpResponse.statusCode == 401 && shouldRetry) {
                // The server rejected our token. Force a session refresh and retry once.
                // This handles clock skew and server-side revocations that pass local
                // expiry checks but fail server-side validation.
                [[EZAuthManager shared] refreshSessionIfNeeded:^(NSString *freshToken, NSError *refreshError) {
                    if (freshToken) {
                        [self executeEntitlementRequest:bodyDict
                                                  token:freshToken
                                     retryOnAuthFailure:NO  // Never retry more than once
                                             completion:completion];
                    } else {
                        // Session is truly gone — surface a clear error
                        NSError *sessionError = [NSError errorWithDomain:@"EZEntitlement"
                            code:401 userInfo:@{NSLocalizedDescriptionKey:
                                @"Session expired. Please sign in again."}];
                        completion(nil, sessionError);
                    }
                }];
                return;
            }

            completion(json, nil);
        });
    }] resume];
}

// ── Prompt truncation ─────────────────────────────────────────────────────────
// Logs just enough of the prompt to identify the request server-side (first
// sentence up to 120 chars). Avoids sending full prompts to the accounting layer.

- (NSString *)truncatePrompt:(NSString *)prompt {
    if (!prompt.length) return @"";

    NSUInteger characterLimit = 120;
    NSRange searchRange = NSMakeRange(0, MIN(prompt.length, characterLimit));
    NSCharacterSet *sentenceEnders = [NSCharacterSet characterSetWithCharactersInString:@".?!\n"];
    NSRange sentenceEnd = [prompt rangeOfCharacterFromSet:sentenceEnders options:0 range:searchRange];

    if (sentenceEnd.location != NSNotFound && sentenceEnd.location > 10) {
        return [prompt substringToIndex:sentenceEnd.location + 1];
    }
    if (prompt.length <= characterLimit) return prompt;
    return [[prompt substringToIndex:characterLimit] stringByAppendingString:@"…"];
}

// ── Apply server response fields ──────────────────────────────────────────────
// Only updates cached values when the server actually returned them —
// never overwrites a valid cached value with nil or a missing key.

- (void)applyResponseFields:(NSDictionary *)json {
    if (json[@"balance"] && json[@"balance"] != [NSNull null]) {
        self.coinBalance = json[@"balance"];
    }
    if (json[@"tier"] && json[@"tier"] != [NSNull null]) {
        self.currentTier = json[@"tier"];
    }
    if (json[@"status"] && json[@"status"] != [NSNull null]) {
        self.currentStatus = json[@"status"];
        if ([self.currentStatus isEqualToString:@"coins_only"] &&
            (!json[@"tier"] || json[@"tier"] == [NSNull null])) {
            self.currentTier = nil;
        }
    }
    if ([json[@"has_ever_purchased"] respondsToSelector:@selector(boolValue)]) {
        self.hasEverPurchased = [json[@"has_ever_purchased"] boolValue];
    }
    if (json[@"log_id"] && json[@"log_id"] != [NSNull null]) {
        self.lastLogID = json[@"log_id"];
    }
}

// ── Flat-rate check: basic ────────────────────────────────────────────────────
// Convenience overload for single-unit checks with no metadata.

- (void)checkEntitlementForFeature:(EZFeature)feature
                        completion:(void(^)(BOOL allowed,
                                           NSInteger balance,
                                           NSString * _Nullable reason))completion {
    [self checkEntitlementForFeature:feature
                            quantity:1
                              prompt:nil
                               model:nil
                          completion:completion];
}

// ── Flat-rate check: quantity + metadata ─────────────────────────────────────

- (void)checkEntitlementForFeature:(EZFeature)feature
                          quantity:(NSInteger)quantity
                            prompt:(NSString *)prompt
                             model:(NSString *)model
                        completion:(void(^)(BOOL allowed,
                                           NSInteger balance,
                                           NSString * _Nullable reason))completion {
    // Delegates to the richer overload below with quality/size omitted —
    // for callers with no meaningful quality/size concept (flat-rate
    // non-image features). Kept as a thin wrapper rather than duplicating
    // the request-building logic, so there's one place that builds it.
    [self checkEntitlementForFeature:feature quantity:quantity prompt:prompt model:model
                              quality:nil size:nil isEdit:NO completion:completion];
}

// ── Richer flat-rate check: also forwards quality/size ──────────────────────
// Added because image requests were being estimated as "high" quality
// regardless of what was actually selected: the 5-param version above never
// sent quality or size at all, only the flattened feature-tier string
// (image_low/medium/high) — and check-entitlement's own cost estimator
// falls back to "high" whenever quality is missing (a deliberate
// conservative default for genuinely-unknown quality, not meant to apply
// when the real quality is known and simply never got forwarded). The
// caller already has the real quality/size sitting in local variables read
// from NSUserDefaults right before this call — this just actually sends
// them.
- (void)checkEntitlementForFeature:(EZFeature)feature
                          quantity:(NSInteger)quantity
                            prompt:(NSString *)prompt
                             model:(NSString *)model
                           quality:(nullable NSString *)quality
                              size:(nullable NSString *)size
                            isEdit:(BOOL)isEdit
                        completion:(void(^)(BOOL allowed,
                                           NSInteger balance,
                                           NSString * _Nullable reason))completion {
    NSMutableDictionary *requestBody = [@{
        @"action":   @"check",
        @"feature":  [self featureStringForFeature:feature],
        @"quantity": @(MAX(1, quantity)),
        @"is_edit":  @(isEdit),
    } mutableCopy];
    if (prompt.length  > 0) requestBody[@"prompt"]      = [self truncatePrompt:prompt];
    if (model.length   > 0) requestBody[@"model"]       = model;
    // Field names must match check-entitlement's estimateImageApiCost
    // params exactly — it reads body.img_quality / body.img_size, not
    // body.quality / body.size.
    if (quality.length > 0) requestBody[@"img_quality"] = quality;
    if (size.length    > 0) requestBody[@"img_size"]    = size;

    [self postEntitlementBody:requestBody completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(NO, self.coinBalance.integerValue, error.localizedDescription ?: @"Network error");
            return;
        }
        BOOL allowed     = [json[@"allowed"] boolValue];
        NSString *reason = json[@"reason"];
        [self applyResponseFields:json];
        completion(allowed, self.coinBalance.integerValue, reason);
    }];
}

// ── Token-based check: full metadata ─────────────────────────────────────────

- (void)checkEntitlementForFeature:(EZFeature)feature
                   estimatedTokens:(NSInteger)estimatedTokens
                        featureTier:(NSString *)featureTier
                             prompt:(NSString *)prompt
                              model:(NSString *)model
                         completion:(void(^)(BOOL allowed,
                                            NSInteger balance,
                                            NSString * _Nullable reason))completion {
    NSMutableDictionary *requestBody = [@{
        @"action":  @"check",
        @"feature": featureTier ?: [self featureStringForFeature:feature],
    } mutableCopy];
    if (estimatedTokens > 0) requestBody[@"estimated_tokens"] = @(estimatedTokens);
    if (prompt.length   > 0) requestBody[@"prompt"] = [self truncatePrompt:prompt];
    if (model.length    > 0) requestBody[@"model"]  = model;

    // Match ez-chat's per-model billing categories for the GPT-6 additions.
    if ([model isEqualToString:@"gpt-6-sol"]) requestBody[@"feature"] = @"chat_standard";
    else if ([model isEqualToString:@"gpt-6-luna"]) requestBody[@"feature"] = @"chat_mini";

    [self postEntitlementBody:requestBody completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(NO, self.coinBalance.integerValue, error.localizedDescription ?: @"Network error");
            return;
        }
        BOOL allowed     = [json[@"allowed"] boolValue];
        NSString *reason = json[@"reason"];
        [self applyResponseFields:json];
        completion(allowed, self.coinBalance.integerValue, reason);
    }];
}

// ── Token-based check: no metadata ───────────────────────────────────────────

- (void)checkEntitlementForFeature:(EZFeature)feature
                   estimatedTokens:(NSInteger)estimatedTokens
                        featureTier:(NSString *)featureTier
                         completion:(void(^)(BOOL allowed,
                                            NSInteger balance,
                                            NSString * _Nullable reason))completion {
    [self checkEntitlementForFeature:feature
                     estimatedTokens:estimatedTokens
                          featureTier:featureTier
                               prompt:nil
                                model:nil
                           completion:completion];
}

// ── Post-completion: image/video results ─────────────────────────────────────
// Call after image/Sora generation completes to log actual output count.

- (void)completeUsageLogWithImagesReturned:(NSInteger)imagesReturned
                                 errorText:(NSString *)errorText {
    NSString *logID = self.lastLogID;
    if (!logID.length) return;

    NSMutableDictionary *requestBody = [@{
        @"action": @"complete_usage",
        @"log_id": logID,
    } mutableCopy];
    if (imagesReturned > 0) requestBody[@"images_returned"] = @(imagesReturned);
    if (errorText.length)   requestBody[@"error_text"]      = errorText;

    [self postEntitlementBody:requestBody completion:^(NSDictionary *json, NSError *error) {
        if (error) NSLog(@"[EZEntitlement] complete_usage error: %@", error.localizedDescription);
    }];
}

// ── Post-completion: token refund ─────────────────────────────────────────────
// Call after a chat completion to refund the difference between the estimated
// token count charged upfront and the actual tokens consumed.

- (void)refundTokensForTier:(NSString *)tier
            estimatedTokens:(NSInteger)estimatedTokens
               actualTokens:(NSInteger)actualTokens
               inputTokens:(NSInteger)inputTokens
              outputTokens:(NSInteger)outputTokens {
    if (actualTokens >= estimatedTokens && !self.lastLogID.length) return;

    NSMutableDictionary *requestBody = [@{
        @"action":           @"refund_tokens",
        @"tier":             tier ?: @"chat_standard",
        @"estimated_tokens": @(estimatedTokens),
        @"actual_tokens":    @(actualTokens),
    } mutableCopy];
    if (inputTokens  > 0)         requestBody[@"input_tokens"]  = @(inputTokens);
    if (outputTokens > 0)         requestBody[@"output_tokens"] = @(outputTokens);
    if (self.lastLogID.length > 0) requestBody[@"log_id"]       = self.lastLogID;

    [self postEntitlementBody:requestBody completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            NSLog(@"[EZEntitlement] Refund network error: %@", error.localizedDescription);
            return;
        }
        [self applyResponseFields:json];
        NSInteger refundedCoins = [json[@"refunded"] integerValue];
        if (refundedCoins > 0) {
            NSLog(@"[EZEntitlement] Refunded %ld coins, balance now: %ld",
                  (long)refundedCoins, (long)self.coinBalance.integerValue);
        }
    }];
}

// ── Legacy refund (no input/output split) ────────────────────────────────────

- (void)refundTokensForTier:(NSString *)tier
            estimatedTokens:(NSInteger)estimatedTokens
               actualTokens:(NSInteger)actualTokens {
    [self refundTokensForTier:tier
              estimatedTokens:estimatedTokens
                 actualTokens:actualTokens
                 inputTokens:0
                outputTokens:0];
}

// ── Direct balance apply ──────────────────────────────────────────────────────
// Use when the balance is already known from a prior response to avoid a
// redundant network round-trip (e.g., after a successful sign-in that includes
// balance data).

- (void)applyKnownBalance:(NSInteger)balance {
    self.coinBalance = @(balance);
}

// ── Balance refresh ───────────────────────────────────────────────────────────

- (void)refreshBalanceWithCompletion:(void(^)(NSInteger balance))completion {
    [self postEntitlementBody:@{@"action": @"check_balance"}
                   completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            if (completion) completion(self.coinBalance.integerValue);
            return;
        }
        [self applyResponseFields:json];
        if (completion) completion(self.coinBalance.integerValue);
    }];
}

- (void)refreshSubscriptionStatusWithCompletion:(void(^)(BOOL refreshed,
                                                         NSInteger balance))completion {
    [self postEntitlementBody:@{@"action": @"check_balance"}
                   completion:^(NSDictionary *json, NSError *error) {
        BOOL hasSubscriptionState = !error &&
            [json[@"status"] isKindOfClass:NSString.class];
        if (hasSubscriptionState) [self applyResponseFields:json];
        if (completion) completion(hasSubscriptionState, self.coinBalance.integerValue);
    }];
}

@end
