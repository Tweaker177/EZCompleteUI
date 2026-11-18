// EZStoreKitManager.m
// EZCompleteUI
//
// See EZStoreKitManager.h. The real implementation exists only in the App
// Store build (APPSTORE=1); every other build compiles the stub at the
// bottom so the file can sit in the shared source list without linking
// StoreKit or changing the PayPal flow in any way.

#import "EZStoreKitManager.h"

#if APPSTORE

#import <StoreKit/StoreKit.h>
#import "EZAuthManager.h"

// Same Supabase project the coin store talks to (see EZCoinStoreViewController).
static NSString *const kSKSupabaseURL       = @"https://spuoimtqofhbdzosrbng.supabase.co";
static NSString *const kSKVerifyEndpoint    = @"/functions/v1/verify-appstore-purchase";
static NSInteger const kSKMaxVerifyAttempts = 3;

/// NSNull-safe JSON readers. The verify response should always carry real
/// numbers, but a null or mistyped value must fail closed, never crash on
/// integerValue / boolValue (NSNull answers neither).
static NSInteger SKInteger(id value) { return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0; }
static BOOL SKBool(id value) { return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO; }

// Forward declaration; defined at the bottom of the implementation.
static NSString *EZStoreKitProductIDForTierReverseLookup(NSString *productID);

NSString *EZStoreKitProductIDForTopUpPackage(NSString *packageID) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"TOPUP_400":   @"com.i0stweak3r.ezcompleteui.coins400",
            @"TOPUP_900":   @"com.i0stweak3r.ezcompleteui.coins900",
            @"TOPUP_2500":  @"com.i0stweak3r.ezcompleteui.coins2500",
            @"TOPUP_6250":  @"com.i0stweak3r.ezcompleteui.coins6250",
            @"TOPUP_12500": @"com.i0stweak3r.ezcompleteui.coins12500",
        };
    });
    return map[packageID];
}

NSString *EZStoreKitProductIDForTier(NSString *tier) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"basic_weekly":      @"com.i0stweak3r.ezcompleteui.sub.basic.weekly",
            @"basic":             @"com.i0stweak3r.ezcompleteui.sub.basic.monthly",
            @"standard":          @"com.i0stweak3r.ezcompleteui.sub.standard.monthly",
            @"standard_annual":   @"com.i0stweak3r.ezcompleteui.sub.standard.annual",
            @"pro":               @"com.i0stweak3r.ezcompleteui.sub.pro.monthly",
            @"pro_annual":        @"com.i0stweak3r.ezcompleteui.sub.pro.annual",
            @"ultra":             @"com.i0stweak3r.ezcompleteui.sub.ultra.monthly",
            @"ultra_annual":      @"com.i0stweak3r.ezcompleteui.sub.ultra.annual",
            @"power":             @"com.i0stweak3r.ezcompleteui.sub.power.monthly",
            @"power_annual":      @"com.i0stweak3r.ezcompleteui.sub.power.annual",
            @"enterprise":        @"com.i0stweak3r.ezcompleteui.sub.enterprise.monthly",
            @"enterprise_annual": @"com.i0stweak3r.ezcompleteui.sub.enterprise.annual",
        };
    });
    return map[tier];
}

/// One in-flight purchase (or restore verification) waiting on StoreKit
/// and/or the server. Keyed by product ID in the manager's pending map.
@interface EZSKPendingPurchase : NSObject
@property (nonatomic, copy)   EZStoreKitPurchaseCompletion completion;
@property (nonatomic, assign) BOOL isSubscription;
@end
@implementation EZSKPendingPurchase
@end

@interface EZStoreKitManager () <SKProductsRequestDelegate, SKPaymentTransactionObserver>
@property (nonatomic, strong) NSMutableDictionary<NSString *, SKProduct *> *productCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, EZSKPendingPurchase *> *pendingByProductID;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<EZStoreKitPurchaseCompletion> *> *productWaiters;
@property (nonatomic, strong) NSMutableSet<NSString *> *productsInFlight;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *verifyAttempts;
@property (nonatomic, copy)   EZStoreKitRestoreCompletion restoreCompletion;
@property (nonatomic, assign) BOOL restoreSawSubscription;
@property (nonatomic, assign) BOOL observing;
@end

@implementation EZStoreKitManager

+ (instancetype)shared {
    static EZStoreKitManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[EZStoreKitManager alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _productCache     = [NSMutableDictionary dictionary];
        _pendingByProductID = [NSMutableDictionary dictionary];
        _productWaiters   = [NSMutableDictionary dictionary];
        _productsInFlight = [NSMutableSet set];
        _verifyAttempts   = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)startObserving {
    if (self.observing) return;
    self.observing = YES;
    [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
    // Warm the product cache so a buy tap doesn't wait on a product fetch,
    // and so unfinished transactions redelivered at launch can be matched
    // to their product IDs immediately.
    NSMutableSet<NSString *> *all = [NSMutableSet set];
    for (NSString *pkg in @[@"TOPUP_400", @"TOPUP_900", @"TOPUP_2500", @"TOPUP_6250", @"TOPUP_12500"]) {
        NSString *pid = EZStoreKitProductIDForTopUpPackage(pkg);
        if (pid) [all addObject:pid];
    }
    for (NSString *tier in @[@"basic_weekly", @"basic", @"standard", @"standard_annual",
                             @"pro", @"pro_annual", @"ultra", @"ultra_annual",
                             @"power", @"power_annual", @"enterprise", @"enterprise_annual"]) {
        NSString *pid = EZStoreKitProductIDForTier(tier);
        if (pid) [all addObject:pid];
    }
    [self fetchProducts:all];
}

#pragma mark - Product fetching

- (void)fetchProducts:(NSSet<NSString *> *)productIDs {
    NSMutableSet<NSString *> *needed = [NSMutableSet setWithSet:productIDs];
    [needed minusSet:[NSSet setWithArray:self.productCache.allKeys]];
    [needed minusSet:self.productsInFlight];
    if (needed.count == 0) return;
    [self.productsInFlight unionSet:needed];
    SKProductsRequest *request = [[SKProductsRequest alloc] initWithProductIdentifiers:needed];
    request.delegate = self;
    [request start];
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (SKProduct *product in response.products) {
            self.productCache[product.productIdentifier] = product;
            [self.productsInFlight removeObject:product.productIdentifier];
        }
        for (NSString *invalid in response.invalidProductIdentifiers) {
            [self.productsInFlight removeObject:invalid];
        }
        // Wake up any purchases that were waiting on these products.
        NSArray<NSString *> *ready = self.productWaiters.allKeys;
        for (NSString *pid in ready) {
            if (self.productCache[pid] || ![self.productsInFlight containsObject:pid]) {
                NSArray<EZStoreKitPurchaseCompletion> *waiters = self.productWaiters[pid];
                [self.productWaiters removeObjectForKey:pid];
                SKProduct *product = self.productCache[pid];
                for (EZStoreKitPurchaseCompletion waiter in waiters) {
                    if (product) {
                        [self startPaymentForProduct:product];
                    } else {
                        EZSKPendingPurchase *pending = self.pendingByProductID[pid];
                        [self.pendingByProductID removeObjectForKey:pid];
                        if (pending.completion) {
                            pending.completion(EZStoreKitOutcomeFailed, 0, 0, NO,
                                               @"This item is not available right now.");
                        }
                        waiter(EZStoreKitOutcomeFailed, 0, 0, NO,
                               @"This item is not available right now.");
                    }
                }
            }
        }
    });
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Treat a failed product fetch like "not available" for waiters;
        // a later buy tap retries the fetch from scratch.
        NSArray<NSString *> *waiting = self.productWaiters.allKeys;
        [self.productsInFlight removeAllObjects];
        for (NSString *pid in waiting) {
            NSArray<EZStoreKitPurchaseCompletion> *waiters = self.productWaiters[pid];
            [self.productWaiters removeObjectForKey:pid];
            EZSKPendingPurchase *pending = self.pendingByProductID[pid];
            [self.pendingByProductID removeObjectForKey:pid];
            if (pending.completion) {
                pending.completion(EZStoreKitOutcomeFailed, 0, 0, NO,
                                   @"Could not reach the App Store. Please try again.");
            }
            for (EZStoreKitPurchaseCompletion waiter in waiters) {
                waiter(EZStoreKitOutcomeFailed, 0, 0, NO,
                       @"Could not reach the App Store. Please try again.");
            }
        }
    });
}

#pragma mark - Purchasing

- (void)purchaseTopUpPackage:(NSString *)packageID
                  completion:(EZStoreKitPurchaseCompletion)completion {
    NSString *productID = EZStoreKitProductIDForTopUpPackage(packageID);
    [self purchaseProductID:productID isSubscription:NO completion:completion];
}

- (void)purchaseSubscriptionTier:(NSString *)tier
                      completion:(EZStoreKitPurchaseCompletion)completion {
    NSString *productID = EZStoreKitProductIDForTier(tier);
    [self purchaseProductID:productID isSubscription:YES completion:completion];
}

- (void)purchaseProductID:(NSString *)productID
         isSubscription:(BOOL)isSubscription
             completion:(EZStoreKitPurchaseCompletion)completion {
    if (!productID) {
        if (completion) completion(EZStoreKitOutcomeFailed, 0, 0, NO,
                                   @"This item is not available right now.");
        return;
    }
    if (![SKPaymentQueue canMakePayments]) {
        if (completion) completion(EZStoreKitOutcomeFailed, 0, 0, NO,
                                   @"Purchases are disabled on this device.");
        return;
    }
    [self startObserving];

    EZSKPendingPurchase *pending = [[EZSKPendingPurchase alloc] init];
    pending.completion = completion;
    pending.isSubscription = isSubscription;
    self.pendingByProductID[productID] = pending;

    SKProduct *product = self.productCache[productID];
    if (product) {
        [self startPaymentForProduct:product];
    } else {
        // The completion doubles as the product-fetch waiter; the pending
        // entry carries it to the transaction stage, so the waiter call in
        // the fetch callbacks passes a no-op here and startPayment happens
        // there instead.
        NSMutableArray *waiters = self.productWaiters[productID];
        if (!waiters) {
            waiters = [NSMutableArray array];
            self.productWaiters[productID] = waiters;
        }
        [waiters addObject:^(EZStoreKitOutcome outcome, NSInteger coins, NSInteger bal, BOOL granted, NSString *err) {
            // Fetch-stage failures are delivered through pending.completion
            // by the fetch callbacks; success just means the payment sheet
            // was started, which startPaymentForProduct already handled.
            (void)outcome; (void)coins; (void)bal; (void)granted; (void)err;
        }];
        [self fetchProducts:[NSSet setWithObject:productID]];
    }
}

- (void)startPaymentForProduct:(SKProduct *)product {
    SKMutablePayment *payment = [SKMutablePayment paymentWithProduct:product];
    // Ties the App Store transaction to this account server-side; the
    // verify function cross-checks it when present.
    NSString *userId = [EZAuthManager shared].userId;
    if (userId.length > 0) payment.applicationUsername = userId;
    [[SKPaymentQueue defaultQueue] addPayment:payment];
}

#pragma mark - Restore

- (void)restorePurchasesWithCompletion:(EZStoreKitRestoreCompletion)completion {
    [self startObserving];
    self.restoreCompletion = completion;
    self.restoreSawSubscription = NO;
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue {
    dispatch_async(dispatch_get_main_queue(), ^{
        EZStoreKitRestoreCompletion completion = self.restoreCompletion;
        self.restoreCompletion = nil;
        if (completion) completion(self.restoreSawSubscription, nil);
    });
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        EZStoreKitRestoreCompletion completion = self.restoreCompletion;
        self.restoreCompletion = nil;
        if (completion) completion(NO, error.localizedDescription);
    });
}

#pragma mark - Transaction observer

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray<SKPaymentTransaction *> *)transactions {
    for (SKPaymentTransaction *transaction in transactions) {
        switch (transaction.transactionState) {
            case SKPaymentTransactionStatePurchased:
                [self verifyTransaction:transaction kind:@"purchase"];
                break;
            case SKPaymentTransactionStateRestored:
                [self verifyTransaction:transaction kind:@"restore"];
                break;
            case SKPaymentTransactionStateFailed: {
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                EZSKPendingPurchase *pending = self.pendingByProductID[transaction.payment.productIdentifier];
                [self.pendingByProductID removeObjectForKey:transaction.payment.productIdentifier];
                if (pending.completion) {
                    if (transaction.error.code == SKErrorPaymentCancelled) {
                        pending.completion(EZStoreKitOutcomeCancelled, 0, 0, NO, nil);
                    } else {
                        pending.completion(EZStoreKitOutcomeFailed, 0, 0, NO,
                                           transaction.error.localizedDescription);
                    }
                }
                break;
            }
            case SKPaymentTransactionStateDeferred: {
                EZSKPendingPurchase *pending = self.pendingByProductID[transaction.payment.productIdentifier];
                [self.pendingByProductID removeObjectForKey:transaction.payment.productIdentifier];
                if (pending.completion) {
                    pending.completion(EZStoreKitOutcomePendingVerification, 0, 0, NO, nil);
                }
                break;
            }
            case SKPaymentTransactionStatePurchasing:
                break;
        }
    }
}

#pragma mark - Server verification

- (void)verifyTransaction:(SKPaymentTransaction *)transaction kind:(NSString *)kind {
    NSString *productID = transaction.payment.productIdentifier;
    NSString *transactionID = transaction.transactionIdentifier ?: @"";
    NSString *originalID = transaction.originalTransaction.transactionIdentifier ?: transactionID;

    if ([kind isEqualToString:@"restore"]) {
        // Restored consumables need no server work (coins were granted at
        // purchase time); subscriptions are re-verified so a reinstall or
        // a new device picks the entitlement back up.
        BOOL isSub = (EZStoreKitProductIDForTierReverseLookup(productID) != nil);
        if (!isSub) {
            [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
            return;
        }
        self.restoreSawSubscription = YES;
    }

    NSString *token = [EZAuthManager shared].accessToken;
    if (token.length == 0) {
        // Not signed in — leave the transaction unfinished; it redelivers
        // after sign-in and verifies then.
        [self completePendingForProductID:productID
                                  outcome:EZStoreKitOutcomePendingVerification
                               coinsAdded:0 balance:0 alreadyGranted:NO errorMessage:nil];
        return;
    }

    NSURL *receiptURL = [[NSBundle mainBundle] appStoreReceiptURL];
    NSData *receiptData = receiptURL ? [NSData dataWithContentsOfURL:receiptURL] : nil;
    NSString *receipt = receiptData ? [receiptData base64EncodedStringWithOptions:0] : nil;

    NSMutableDictionary *body = [@{
        @"product_id":             productID,
        @"transaction_id":         transactionID,
        @"original_transaction_id": originalID,
        @"kind":                   kind,
        @"user_id":                [EZAuthManager shared].userId ?: @"",
    } mutableCopy];
    if (receipt) body[@"receipt"] = receipt;

    NSURL *url = [NSURL URLWithString:[kSKSupabaseURL stringByAppendingString:kSKVerifyEndpoint]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSString *attemptKey = transactionID;
    NSInteger attempt = [self.verifyAttempts[attemptKey] integerValue] + 1;
    self.verifyAttempts[attemptKey] = @(attempt);

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            BOOL granted = (http.statusCode == 200) &&
                           [json isKindOfClass:[NSDictionary class]] &&
                           SKBool(json[@"success"]);

            if (granted) {
                [self.verifyAttempts removeObjectForKey:attemptKey];
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                NSInteger coinsAdded = SKInteger(json[@"coins_added"]);
                NSInteger balance    = SKInteger(json[@"balance"]);
                BOOL already         = SKBool(json[@"already_granted"]);
                [self completePendingForProductID:productID
                                          outcome:EZStoreKitOutcomeSuccess
                                       coinsAdded:coinsAdded balance:balance
                                   alreadyGranted:already errorMessage:nil];
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"EZStoreKitVerifiedGrant"
                    object:nil
                    userInfo:@{ @"product_id": productID,
                                @"coins_added": @(coinsAdded),
                                @"balance": @(balance),
                                @"already_granted": @(already) }];
                return;
            }

            BOOL definitive = (http.statusCode >= 400 && http.statusCode < 500) && !error;
            if (definitive) {
                // The server looked at this transaction and said no (invalid,
                // refunded, or not ours). Finish it so it stops redelivering.
                [self.verifyAttempts removeObjectForKey:attemptKey];
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                NSString *message = [json[@"error"] isKindOfClass:[NSString class]]
                    ? json[@"error"]
                    : @"This purchase could not be verified.";
                [self completePendingForProductID:productID
                                          outcome:EZStoreKitOutcomeFailed
                                       coinsAdded:0 balance:0 alreadyGranted:NO
                                     errorMessage:message];
                return;
            }

            // Network error or server 5xx: retry a few times, then leave the
            // transaction unfinished — StoreKit redelivers it next launch
            // and verification runs again. Never surface this as an error.
            if (attempt < kSKMaxVerifyAttempts) {
                NSTimeInterval delay = (attempt == 1) ? 2.0 : 5.0;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self verifyTransaction:transaction kind:kind];
                });
            } else {
                [self.verifyAttempts removeObjectForKey:attemptKey];
                [self completePendingForProductID:productID
                                          outcome:EZStoreKitOutcomePendingVerification
                                       coinsAdded:0 balance:0 alreadyGranted:NO errorMessage:nil];
            }
        });
    }] resume];
}

- (void)completePendingForProductID:(NSString *)productID
                            outcome:(EZStoreKitOutcome)outcome
                         coinsAdded:(NSInteger)coinsAdded
                            balance:(NSInteger)balance
                     alreadyGranted:(BOOL)alreadyGranted
                       errorMessage:(NSString *)errorMessage {
    EZSKPendingPurchase *pending = self.pendingByProductID[productID];
    if (!pending) return;
    [self.pendingByProductID removeObjectForKey:productID];
    if (pending.completion) {
        pending.completion(outcome, coinsAdded, balance, alreadyGranted, errorMessage);
    }
}

// Reverse lookup used to tell subscription products from consumables for
// restored transactions. Declared here (not in the header) — file-local.
static NSString *EZStoreKitProductIDForTierReverseLookup(NSString *productID) {
    static NSDictionary<NSString *, NSString *> *reverse;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSString *tier in @[@"basic_weekly", @"basic", @"standard", @"standard_annual",
                                 @"pro", @"pro_annual", @"ultra", @"ultra_annual",
                                 @"power", @"power_annual", @"enterprise", @"enterprise_annual"]) {
            NSString *pid = EZStoreKitProductIDForTier(tier);
            if (pid) m[pid] = tier;
        }
        reverse = m;
    });
    return reverse[productID];
}

@end

#else // !APPSTORE — inert shell so non-store builds compile this file
      // without StoreKit and never change behavior.

NSString *EZStoreKitProductIDForTopUpPackage(NSString *packageID) { return nil; }
NSString *EZStoreKitProductIDForTier(NSString *tier) { return nil; }

@implementation EZStoreKitManager

+ (instancetype)shared {
    static EZStoreKitManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[EZStoreKitManager alloc] init]; });
    return instance;
}

- (void)startObserving {}
- (void)purchaseTopUpPackage:(NSString *)packageID completion:(EZStoreKitPurchaseCompletion)completion {}
- (void)purchaseSubscriptionTier:(NSString *)tier completion:(EZStoreKitPurchaseCompletion)completion {}
- (void)restorePurchasesWithCompletion:(EZStoreKitRestoreCompletion)completion {
    if (completion) completion(NO, nil);
}

@end

#endif
