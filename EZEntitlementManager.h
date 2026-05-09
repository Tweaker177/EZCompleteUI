// EZEntitlementManager.h
// EZCompleteUI

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, EZFeature) {
    EZFeatureChatMini,
    EZFeatureChatGPT4o,
    EZFeatureImageLow,
    EZFeatureImageMedium,
    EZFeatureImageHigh,
    EZFeatureDalle3Standard,
    EZFeatureDalle3HD,
    EZFeatureSora10s,
    EZFeatureSoraPro10s,
    EZFeatureTTS500Chars,
    EZFeatureVoiceClone,
    EZFeatureWhisperMinute,
};

@interface EZEntitlementManager : NSObject

@property (nonatomic, readonly) NSInteger coinBalance;
@property (nonatomic, readonly) NSString  *currentTier;

+ (instancetype)shared;

/// Flat-rate entitlement check — used for image, sora, voice clone, whisper.
/// Deducts the fixed coin cost for the feature.
- (void)checkEntitlementForFeature:(EZFeature)feature
                        completion:(void(^)(BOOL allowed,
                                           NSInteger balance,
                                           NSString * _Nullable reason))completion;

/// Token-based entitlement check — used for chat completions.
/// Pass the estimated total tokens (input + output) from the assembled payload.
/// The edge function deducts coins proportional to estimatedTokens and the tier rate.
/// Call refundTokensForTier:estimatedTokens:actualTokens: after the response
/// comes back to credit any overage.
- (void)checkEntitlementForFeature:(EZFeature)feature
                   estimatedTokens:(NSInteger)estimatedTokens
                        featureTier:(NSString *)featureTier
                         completion:(void(^)(BOOL allowed,
                                            NSInteger balance,
                                            NSString * _Nullable reason))completion;

/// Refunds coin overage after actual token usage is known from the API response.
/// Pass the same tier string used in the entitlement check.
/// No-op if actualTokens >= estimatedTokens.
- (void)refundTokensForTier:(NSString *)tier
            estimatedTokens:(NSInteger)estimatedTokens
               actualTokens:(NSInteger)actualTokens;

/// Read-only balance refresh — no coin deduction. Safe to call on launch and foreground.
- (void)refreshBalanceWithCompletion:(void(^)(NSInteger balance))completion;

@end

NS_ASSUME_NONNULL_END
