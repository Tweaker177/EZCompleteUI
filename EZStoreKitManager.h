// EZStoreKitManager.h
// EZCompleteUI
//
// StoreKit purchasing for the App Store build (APPSTORE=1). In every other
// build this compiles to an inert shell: the coin store only references it
// under #if APPSTORE, and the implementation is empty, so the jailbreak and
// simulator builds keep using the PayPal flow untouched and never link
// StoreKit.
//
// The manager owns the SKPaymentQueue observer. A purchase is NOT finished
// with Apple until the server has verified it and granted the coins or the
// subscription (POST /functions/v1/verify-appstore-purchase, which answers
// with the same { success, coins_added, balance } shape as
// capture-paypal-order). If verification cannot reach the server, the
// transaction is left unfinished on purpose: StoreKit redelivers it on the
// next launch and the manager verifies it then, so a paid purchase is never
// lost to a network hiccup and the user is never shown an error the app
// could have recovered from silently.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Outcome of a purchase or restore attempt.
typedef NS_ENUM(NSUInteger, EZStoreKitOutcome) {
    /// Server verified the transaction and granted (or had already granted).
    EZStoreKitOutcomeSuccess,
    /// Server definitively rejected the transaction, or StoreKit failed it.
    EZStoreKitOutcomeFailed,
    /// The user cancelled the App Store purchase sheet. Stay silent.
    EZStoreKitOutcomeCancelled,
    /// Paid, but verification is still pending (network). The transaction is
    /// unfinished and will be verified on redelivery; refresh quietly.
    EZStoreKitOutcomePendingVerification,
};

/// coinsAdded / balance are meaningful only for EZStoreKitOutcomeSuccess
/// top-ups (they come straight from the server's grant response).
/// alreadyGranted is YES when the server had already credited this
/// transaction (redelivery) — refresh the balance, don't celebrate twice.
typedef void (^EZStoreKitPurchaseCompletion)(EZStoreKitOutcome outcome,
                                             NSInteger coinsAdded,
                                             NSInteger balance,
                                             BOOL alreadyGranted,
                                             NSString *_Nullable errorMessage);

/// restored is YES when at least one subscription transaction was restored
/// and verified with the server.
typedef void (^EZStoreKitRestoreCompletion)(BOOL restored, NSString *_Nullable errorMessage);

/// Maps a coin-store top-up package ID (@"TOPUP_2500") to its App Store
/// Connect product ID. Returns nil for an unknown package.
FOUNDATION_EXPORT NSString *_Nullable EZStoreKitProductIDForTopUpPackage(NSString *packageID);

/// Maps a subscription tier name (@"pro", @"pro_annual") to its App Store
/// Connect product ID. Returns nil for an unknown tier.
FOUNDATION_EXPORT NSString *_Nullable EZStoreKitProductIDForTier(NSString *tier);

@interface EZStoreKitManager : NSObject

+ (instancetype)shared;

/// Registers the transaction observer and warms the product cache. Safe to
/// call repeatedly; only the first call does anything. No-op outside the
/// App Store build.
- (void)startObserving;

/// Buys a one-time coin top-up package (consumable).
- (void)purchaseTopUpPackage:(NSString *)packageID
                  completion:(EZStoreKitPurchaseCompletion)completion;

/// Buys (or switches to) a subscription tier (auto-renewable). All tiers
/// live in one App Store subscription group, so switching tiers is handled
/// by Apple — there is no cancel step.
- (void)purchaseSubscriptionTier:(NSString *)tier
                      completion:(EZStoreKitPurchaseCompletion)completion;

/// Restores prior purchases (required for auto-renewable subscriptions).
/// Restored subscription transactions are verified with the server exactly
/// like new purchases.
- (void)restorePurchasesWithCompletion:(EZStoreKitRestoreCompletion)completion;

@end

NS_ASSUME_NONNULL_END
