    // EZAuthManager.h
    #import <Foundation/Foundation.h>

    NS_ASSUME_NONNULL_BEGIN

    @interface EZAuthManager : NSObject

    @property (nonatomic, copy, readonly, nullable) NSString *accessToken;
    @property (nonatomic, copy, readonly, nullable) NSString *userId;
    @property (nonatomic, readonly) BOOL isLoggedIn;

    + (instancetype)shared;

    - (void)signUpWithEmail:(NSString *)email
                   password:(NSString *)password
                 completion:(void(^)(BOOL success, NSString * _Nullable error))completion;

    - (void)signInWithEmail:(NSString *)email
                   password:(NSString *)password
                 completion:(void(^)(BOOL success, NSString * _Nullable error))completion;

    - (void)signOut;

    - (void)restoreSessionWithCompletion:(void(^)(BOOL loggedIn))completion;

    @end

    NS_ASSUME_NONNULL_END
