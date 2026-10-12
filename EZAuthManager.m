// EZAuthManager.m
// EZCompleteUI
//
// Purpose:
//   Manages the Supabase authentication session for the device. Handles sign-in,
//   sign-up, sign-out, password reset, and keeping the JWT access token fresh.
//   All other classes that make authenticated Supabase requests should call
//   getValidAccessToken: — never read the accessToken property directly — so
//   they always send a valid token and never need to handle refresh themselves.
//
//   This class only talks to Supabase Auth (/auth/v1/*), not the Edge Functions.
//   The JWT it maintains is what Edge Functions receive as the caller's identity.
//
// Changes:
//   - Added getValidAccessToken: — public interface for obtaining a usable token.
//     All callers (e.g. EZEntitlementManager) should use this instead of the
//     raw accessToken property, which may be expired after backgrounding.
//   - Added sendPasswordResetEmail:completion: for the forgot-password flow.
//   - init now observes UIApplicationWillEnterForegroundNotification to proactively
//     refresh the JWT when the app returns from background, preventing stale-token
//     errors on the first API call after a long suspension.
//   - saveSession: now writes EZLastAuthenticatedDate to NSUserDefaults. Previously
//     only LoginViewController wrote this on manual sign-in, so silent token refreshes
//     and session restores never updated the timestamp — power users would get forced
//     re-auth after 7 days even if they used the app every day.
//   - postToPath: now surfaces HTTP 401 as a distinct NSError (domain EZAuth, code 401)
//     so callers can react to auth failures differently from network errors.
//   - Fixed inconsistent indentation throughout.
//   - Added full password reset recovery session flow:
//       applyPasswordResetTokens:refreshToken: — called by AppDelegate when the
//         ezcomplete://password-reset deep link is received. Stores recovery tokens
//         in memory (not keychain), sets isInPasswordRecoveryMode, and posts
//         EZPasswordResetReadyNotification so LoginViewController can show the
//         set-new-password UI.
//       setNewPassword:completion: — called from LoginViewController after the
//         user enters their new password. PUTs to /auth/v1/user with the recovery
//         access token as Bearer auth. Clears recovery state on success.
//       cancelPasswordReset — called if the user dismisses the reset UI without
//         completing. Clears recovery tokens and resets isInPasswordRecoveryMode.
//       putToPath:body:bearerToken:completion: — new private helper for
//         authenticated PUT requests (auth endpoints that require Bearer token).
//       sendPasswordResetEmail:completion: updated to include redirect_to pointing
//         to the Edge Function which provides branded UI and LiveContainer fallbacks.
//
// ─── EZAuthManager.h additions required ──────────────────────────────────────
// The following must be added to EZAuthManager.h before building:
//
//   extern NSString *const EZPasswordResetReadyNotification;
//
//   @property (nonatomic, assign, readonly) BOOL isInPasswordRecoveryMode;
//
//   - (void)applyPasswordResetTokens:(NSString *)accessToken
//                       refreshToken:(NSString *)refreshToken;
//
//   - (void)setNewPassword:(NSString *)newPassword
//               completion:(void(^)(BOOL success, NSString * _Nullable errorMessage))completion;
//
//   - (void)cancelPasswordReset;
// ─────────────────────────────────────────────────────────────────────────────

#import "EZAuthManager.h"
#import "EZKeyVault.h"
#import <UIKit/UIKit.h>

// ── Constants ─────────────────────────────────────────────────────────────────

static NSString *const kSupabaseURL     = @"https://spuoimtqofhbdzosrbng.supabase.co";

// kSupabaseAnonKey is the Supabase *publishable* anon key — it is intentionally
// public (analogous to a Firebase API key) and safe to ship in the binary.
// Never put the service_role key here.
static NSString *const kSupabaseAnonKey = @"sb_publishable_AzEVhLuIj1nSMwZvIgKw7A__Y3Ghdtl";

// Edge Function URL that handles the password reset redirect. Supabase verifies
// the token from the email link, then redirects to this URL with session tokens
// in the fragment. The Edge Function page extracts them client-side and opens
// the ezcomplete:// deep link (with LiveContainer fallbacks).
// This URL must also be whitelisted in:
//   Supabase Dashboard → Authentication → URL Configuration → Redirect URLs
static NSString *const kPasswordResetRedirectURL =
    @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/password-reset-redirect";

// The same public landing page safely routes both reset and signup-confirmation
// callbacks back into the app (including LiveContainer fallbacks).
static NSString *const kEmailConfirmationRedirectURL =
    @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/password-reset-redirect";

// The welcome grant must run through an Edge Function rather than the auth.users
// trigger: only the Edge Function receives the actual client IP forwarded by
// Supabase's proxy.  It quietly returns "already claimed" for established users.
static NSString *const kClaimWelcomeBonusPath = @"/functions/v1/claim-welcome-bonus";

// Keychain slot identifiers via EZKeyVault constants from EZKeyVault.h
#define kAccessTokenKey  EZVaultKeyAccessToken
#define kRefreshTokenKey EZVaultKeyRefreshToken
#define kUserIdKey       EZVaultKeyUserId
#define kInstallationIDKey EZVaultKeyInstallationID

// NSUserDefaults key for the last successful authentication timestamp.
// Read by requiresReAuthentication to enforce the 7-day periodic re-auth policy.
static NSString *const kLastAuthDateKey = @"EZLastAuthenticatedDate";

// Notification posted when a password reset deep link has been received and
// the recovery session tokens have been stored. LoginViewController observes
// this to trigger the set-new-password UI. Defined here and extern'd in the header.
 NSString *const EZPasswordResetReadyNotification = @"EZPasswordResetReadyNotification";

// ── Private interface ─────────────────────────────────────────────────────────

@interface EZAuthManager ()
// Normal session state
@property (nonatomic, copy, readwrite, nullable) NSString *accessToken;
@property (nonatomic, copy, readwrite, nullable) NSString *userId;

// Password recovery state — held in memory only, never persisted to keychain.
// If the app is killed mid-reset the user must request a new link (1-hour window).
@property (nonatomic, copy,   nullable) NSString *recoveryAccessToken;
@property (nonatomic, copy,   nullable) NSString *recoveryRefreshToken;
@property (nonatomic, assign, readwrite) BOOL isInPasswordRecoveryMode;
@end

@implementation EZAuthManager

// ── Singleton ─────────────────────────────────────────────────────────────────

+ (instancetype)shared {
    static EZAuthManager *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sharedInstance = [[self alloc] init]; });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Proactively refresh the token whenever the app returns from background.
        // UIApplicationWillEnterForeground only fires on background→foreground
        // transitions, not on initial launch, so this won't run redundantly at startup.
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(handleAppWillEnterForeground)
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// ── State ─────────────────────────────────────────────────────────────────────

- (BOOL)isLoggedIn {
    return self.accessToken != nil;
}

// ── Public token access ───────────────────────────────────────────────────────
// The correct way for any class to obtain a token before making an authenticated
// request. Validates expiry and silently refreshes if needed, so callers never
// have to think about token lifecycle.

- (void)getValidAccessToken:(void(^)(NSString * _Nullable token, NSError * _Nullable error))completion {
    [self refreshSessionIfNeeded:completion];
}

// ── Foreground refresh ────────────────────────────────────────────────────────

- (void)handleAppWillEnterForeground {
    if (!self.accessToken) return; // Not logged in — nothing to refresh

    [self refreshSessionIfNeeded:^(NSString *token, NSError *error) {
        if (error) {
            // If the refresh token itself expired, refreshSessionIfNeeded already
            // called signOut. The next authenticated request will get a nil token
            // and should redirect to the login screen at that point.
            NSLog(@"[EZAuth] Foreground token refresh failed: %@", error.localizedDescription);
        }
    }];
}

// ── Session refresh ───────────────────────────────────────────────────────────
// Checks the current token's expiry claim without a network call. If the token
// is still good (> 60 seconds remaining), calls completion immediately.
// If expired or missing, attempts a refresh_token grant.
// On unrecoverable failure, calls signOut before returning the error.

- (void)refreshSessionIfNeeded:(void(^)(NSString * _Nullable token, NSError * _Nullable error))completion {
    NSString *currentToken = self.accessToken;

    if (currentToken.length > 0) {
        // JWT format: header.payload.signature — payload is base64url-encoded JSON
        NSArray *jwtParts = [currentToken componentsSeparatedByString:@"."];
        if (jwtParts.count == 3) {
            // Convert base64url to standard base64 before decoding
            NSMutableString *base64Payload = [jwtParts[1] mutableCopy];
            [base64Payload replaceOccurrencesOfString:@"-" withString:@"+" options:0
                                               range:NSMakeRange(0, base64Payload.length)];
            [base64Payload replaceOccurrencesOfString:@"_" withString:@"/" options:0
                                               range:NSMakeRange(0, base64Payload.length)];
            while (base64Payload.length % 4 != 0) [base64Payload appendString:@"="];

            NSData *payloadData = [[NSData alloc] initWithBase64EncodedString:base64Payload options:0];
            if (payloadData) {
                NSDictionary *claims = [NSJSONSerialization JSONObjectWithData:payloadData
                                                                       options:0 error:nil];
                NSTimeInterval expiry = [claims[@"exp"] doubleValue];
                // 60-second buffer: if more than a minute remains, use it as-is
                if (expiry > 0 && [[NSDate date] timeIntervalSince1970] < expiry - 60) {
                    completion(currentToken, nil);
                    return;
                }
            }
        }
    }

    // Token is missing, malformed, or expiring within 60 seconds — attempt refresh
    NSString *refreshToken = [EZKeyVault loadKeyForIdentifier:kRefreshTokenKey];
    if (!refreshToken) {
        completion(nil, [NSError errorWithDomain:@"EZAuth" code:401
            userInfo:@{NSLocalizedDescriptionKey: @"No refresh token — please sign in again."}]);
        return;
    }

    [self postToPath:@"/auth/v1/token?grant_type=refresh_token"
                body:@{ @"refresh_token": refreshToken }
          completion:^(NSDictionary *responseData, NSError *error) {
        if (responseData[@"access_token"]) {
            [self saveSession:responseData];
            completion(self.accessToken, nil);
        } else {
            // Refresh token is expired or revoked — clear the session so the app
            // can detect the logged-out state and show the login screen
            [self signOut];
            completion(nil, error ?: [NSError errorWithDomain:@"EZAuth" code:401
                userInfo:@{NSLocalizedDescriptionKey: @"Session expired. Please sign in again."}]);
        }
    }];
}

// ── Restore session at launch ─────────────────────────────────────────────────
// Call from the app delegate or root VC at startup to silently resume a
// previous session. Always attempts a token refresh since the stored token
// may be hours old from the last session.

- (void)restoreSessionWithCompletion:(void(^)(BOOL loggedIn))completion {
    NSString *savedToken   = [EZKeyVault loadKeyForIdentifier:kAccessTokenKey];
    NSString *savedRefresh = [EZKeyVault loadKeyForIdentifier:kRefreshTokenKey];
    NSString *savedUserId  = [EZKeyVault loadKeyForIdentifier:kUserIdKey];

    if (!savedToken || !savedRefresh) {
        completion(NO);
        return;
    }

    [self postToPath:@"/auth/v1/token?grant_type=refresh_token"
                body:@{ @"refresh_token": savedRefresh }
          completion:^(NSDictionary *responseData, NSError *error) {
        if (responseData[@"access_token"]) {
            // Set the stored userId first so saveSession can use it as a fallback
            // if the refresh response omits the user object
            if (!self.userId) self.userId = savedUserId;
            [self saveSession:responseData];
            completion(YES);
        } else {
            [self signOut];
            completion(NO);
        }
    }];
}

// ── Sign up ───────────────────────────────────────────────────────────────────

- (void)signUpWithEmail:(NSString *)email
               password:(NSString *)password
             completion:(void(^)(BOOL success, NSString * _Nullable error))completion {
    // This is not a hardware identifier and is never used for tracking. It is
    // a random ID retained in Keychain so the welcome-credit trigger can
    // reject a second newly-created account from the same app installation.
    // If Keychain is unavailable, signup still works but receives no welcome
    // bonus once the server-side rule below is deployed.
    NSString *installationID = [EZKeyVault loadKeyForIdentifier:kInstallationIDKey];
    if (installationID.length == 0 || ![[NSUUID alloc] initWithUUIDString:installationID]) {
        installationID = NSUUID.UUID.UUIDString.lowercaseString;
        if (![EZKeyVault saveKey:installationID forIdentifier:kInstallationIDKey]) {
            installationID = nil;
        }
    }
    NSMutableDictionary *body = [@{
        @"email": email,
        @"password": password,
        @"email_redirect_to": kEmailConfirmationRedirectURL,
    } mutableCopy];
    if (installationID.length > 0) body[@"data"] = @{ @"installation_id": installationID };
    [self postToPath:@"/auth/v1/signup"
                body:body
          completion:^(NSDictionary *responseData, NSError *error) {
        if (error || responseData[@"error"] || responseData[@"error_code"]) {
            completion(NO, [self friendlyErrorFromData:responseData networkError:error]);
        } else if (responseData[@"access_token"]) {
            // Email confirmation is disabled — user is immediately logged in
            [self saveSession:responseData];
            completion(YES, nil);
        } else {
            // Supabase returned 200 with no token — email confirmation required.
            // The caller should check isLoggedIn to distinguish this from a full
            // successful login and show an appropriate "check your email" message.
            completion(YES, nil);
        }
    }];
}

// ── Sign in ───────────────────────────────────────────────────────────────────

- (void)signInWithEmail:(NSString *)email
               password:(NSString *)password
             completion:(void(^)(BOOL success, NSString * _Nullable error))completion {
    [self postToPath:@"/auth/v1/token?grant_type=password"
                body:@{ @"email": email, @"password": password }
          completion:^(NSDictionary *responseData, NSError *error) {
        if (error || responseData[@"error"] || responseData[@"error_code"]) {
            completion(NO, [self friendlyErrorFromData:responseData networkError:error]);
        } else if (responseData[@"access_token"]) {
            [self saveSession:responseData];
            completion(YES, nil);
        } else {
            completion(NO, [self friendlyErrorFromData:responseData networkError:nil]);
        }
    }];
}

// ── Password reset — send email ───────────────────────────────────────────────
// Sends a reset-password email via Supabase /auth/v1/recover.
// redirect_to points to our Edge Function, which:
//   1. Renders a branded page with the EZCompleteUI name
//   2. Extracts tokens from the URL fragment client-side
//   3. Opens ezcomplete://password-reset?access_token=...&refresh_token=...
//   4. Falls back to LiveContainer URL schemes if ezcomplete:// doesn't open
//
// The redirect_to URL must be whitelisted in:
//   Supabase Dashboard → Authentication → URL Configuration → Redirect URLs

- (void)sendPasswordResetEmail:(NSString *)email
                    completion:(void(^)(BOOL success, NSString * _Nullable error))completion {
    if (!email.length) {
        completion(NO, @"Please enter your email address first.");
        return;
    }
    [self postToPath:@"/auth/v1/recover"
                body:@{
                    @"email":       email,
                    @"redirect_to": kPasswordResetRedirectURL,
                }
          completion:^(NSDictionary *responseData, NSError *error) {
        if (error) {
            completion(NO, @"Network error. Check your connection and try again.");
        } else if (responseData[@"error"] || responseData[@"error_code"]) {
            completion(NO, [self friendlyErrorFromData:responseData networkError:nil]);
        } else {
            // Supabase returns an empty {} body on success
            completion(YES, nil);
        }
    }];
}

// ── Password reset — apply recovery session ───────────────────────────────────
// Called by AppDelegate when the ezcomplete://password-reset deep link arrives.
// Stores the recovery tokens in memory only — NOT in the keychain — so normal
// session state is not affected. Sets isInPasswordRecoveryMode and posts
// EZPasswordResetReadyNotification for LoginViewController to observe.
//
// Tokens are kept in memory only: if the app is killed before the user sets
// their password, they'll need to request a new reset link (valid 1 hour).
// This avoids the complexity of persisting a partial recovery state.

- (void)applyPasswordResetTokens:(NSString *)accessToken
                    refreshToken:(NSString *)refreshToken {
    if (!accessToken.length || !refreshToken.length) {
        NSLog(@"[EZAuth] applyPasswordResetTokens: called with empty tokens — ignoring.");
        return;
    }

    self.recoveryAccessToken  = accessToken;
    self.recoveryRefreshToken = refreshToken;
    self.isInPasswordRecoveryMode = YES;

    [[NSNotificationCenter defaultCenter]
        postNotificationName:EZPasswordResetReadyNotification object:nil];
}

// ── Password reset — set new password ────────────────────────────────────────
// Calls PUT /auth/v1/user with the recovery access token to update the password.
// Must only be called while isInPasswordRecoveryMode is YES.
// On success, clears recovery state. The caller is responsible for transitioning
// the user to the sign-in screen with a success message.

- (void)setNewPassword:(NSString *)newPassword
            completion:(void(^)(BOOL success, NSString * _Nullable errorMessage))completion {
    if (!self.isInPasswordRecoveryMode || !self.recoveryAccessToken.length) {
        completion(NO, @"No active reset session. Please request a new password reset link.");
        return;
    }
    if (newPassword.length < 8) {
        completion(NO, @"Password must be at least 8 characters.");
        return;
    }

    [self putToPath:@"/auth/v1/user"
               body:@{ @"password": newPassword }
        bearerToken:self.recoveryAccessToken
         completion:^(NSDictionary *responseData, NSError *error) {
        if (error) {
            if (error.code == 401) {
                // Recovery token expired — the 1-hour reset window has passed
                [self cancelPasswordReset];
                completion(NO, @"This reset link has expired. Please request a new one.");
            } else {
                completion(NO, @"Network error. Check your connection and try again.");
            }
            return;
        }

        // Supabase returns the updated user object on success (contains "id")
        if (responseData[@"id"]) {
            [self cancelPasswordReset];
            completion(YES, nil);
            return;
        }

        // 422 is returned for weak password or same-as-current password violations
        NSString *errorMessage = responseData[@"message"]
            ?: @"Password doesn't meet requirements. Use at least 8 characters "
               @"with a mix of letters and numbers.";
        completion(NO, errorMessage);
    }];
}

// ── Password reset — cancel ───────────────────────────────────────────────────
// Called when the user dismisses the reset UI without completing, or after a
// successful password change (to clear the recovery state).

- (void)cancelPasswordReset {
    self.recoveryAccessToken      = nil;
    self.recoveryRefreshToken     = nil;
    self.isInPasswordRecoveryMode = NO;
}

// ── Sign out ──────────────────────────────────────────────────────────────────

- (void)signOut {
    self.accessToken = nil;
    self.userId      = nil;
    [EZKeyVault deleteKeyForIdentifier:kAccessTokenKey];
    [EZKeyVault deleteKeyForIdentifier:kRefreshTokenKey];
    [EZKeyVault deleteKeyForIdentifier:kUserIdKey];
}

// ── Save session ──────────────────────────────────────────────────────────────
// Stores a fresh session to the keychain and updates in-memory state.
// Called after every successful authentication — sign-in, sign-up, or any
// token refresh — so the periodic re-auth timestamp stays current.

- (void)saveSession:(NSDictionary *)responseData {
    self.accessToken = responseData[@"access_token"];
    // Keep the existing userId if the refresh response doesn't include one
    if (responseData[@"user"][@"id"]) {
        self.userId = responseData[@"user"][@"id"];
    } else if (self.accessToken.length && !self.userId.length) {
        // Email-confirmation callbacks carry tokens but not a user object.
        // The JWT subject is the authenticated Supabase user ID.
        NSArray<NSString *> *parts = [self.accessToken componentsSeparatedByString:@"."];
        if (parts.count == 3) {
            NSMutableString *payload = [parts[1] mutableCopy];
            [payload replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, payload.length)];
            [payload replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, payload.length)];
            while (payload.length % 4) [payload appendString:@"="];
            NSData *data = [[NSData alloc] initWithBase64EncodedString:payload options:0];
            NSDictionary *claims = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([claims[@"sub"] isKindOfClass:NSString.class]) self.userId = claims[@"sub"];
        }
    }

    [EZKeyVault saveKey:self.accessToken forIdentifier:kAccessTokenKey];

    if (responseData[@"refresh_token"]) {
        [EZKeyVault saveKey:responseData[@"refresh_token"] forIdentifier:kRefreshTokenKey];
    }
    if (self.userId) {
        [EZKeyVault saveKey:self.userId forIdentifier:kUserIdKey];
    }

    // Update the re-auth clock on every session save, not just on manual sign-in.
    // This ensures users who auto-refresh tokens daily are never forced to
    // manually re-authenticate as long as they stay active.
    [[NSUserDefaults standardUserDefaults]
        setDouble:[[NSDate date] timeIntervalSince1970] forKey:kLastAuthDateKey];

    [self claimWelcomeBonusIfEligible];
}

// This request is deliberately best-effort and silent. The server is the sole
// authority: it grants at most once per account, Keychain installation, and
// network IP, so calling after every restored/refreshed session is harmless.
- (void)claimWelcomeBonusIfEligible {
    if (!self.accessToken.length || !self.userId.length) return;

    NSURL *url = [NSURL URLWithString:[kSupabaseURL stringByAppendingString:kClaimWelcomeBonusPath]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 15;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:kSupabaseAnonKey forHTTPHeaderField:@"apikey"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.accessToken]
   forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSData dataWithBytes:"{}" length:2];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(__unused NSData *data, __unused NSURLResponse *response,
                            __unused NSError *error) {
            // No client-side state is changed here. Coin balances remain
            // server-authoritative and refresh through the normal entitlement flow.
        }] resume];
}

// ── Network — unauthenticated POST ────────────────────────────────────────────
// Internal POST helper for Supabase Auth endpoints (/auth/v1/*) that don't
// require a Bearer token (sign-in, sign-up, token refresh, password recover).
// Not used by Edge Function calls — those go through EZEntitlementManager.

- (void)postToPath:(NSString *)path
              body:(NSDictionary *)body
        completion:(void(^)(NSDictionary *responseData, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:[kSupabaseURL stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod      = @"POST";
    request.timeoutInterval = 15;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:kSupabaseAnonKey     forHTTPHeaderField:@"apikey"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *responseBody, NSURLResponse *urlResponse, NSError *networkError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (networkError) {
                completion(@{}, networkError);
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)urlResponse;
            NSDictionary *json = [NSJSONSerialization
                JSONObjectWithData:responseBody ?: [NSData data] options:0 error:nil] ?: @{};

            if (httpResponse.statusCode == 401) {
                // Distinguish auth failures from network errors so callers can
                // take action (e.g. EZEntitlementManager can retry after a refresh)
                NSError *authError = [NSError errorWithDomain:@"EZAuth" code:401
                    userInfo:@{NSLocalizedDescriptionKey: @"Unauthorized — session may have expired."}];
                completion(json, authError);
                return;
            }

            completion(json, nil);
        });
    }] resume];
}

// ── Network — authenticated PUT ───────────────────────────────────────────────
// Used for Supabase Auth endpoints that require an active session Bearer token,
// specifically PUT /auth/v1/user for password updates during password recovery.

- (void)putToPath:(NSString *)path
             body:(NSDictionary *)body
      bearerToken:(NSString *)bearerToken
       completion:(void(^)(NSDictionary *responseData, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:[kSupabaseURL stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod      = @"PUT";
    request.timeoutInterval = 15;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:kSupabaseAnonKey     forHTTPHeaderField:@"apikey"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", bearerToken]
   forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *responseBody, NSURLResponse *urlResponse, NSError *networkError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (networkError) {
                completion(@{}, networkError);
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)urlResponse;
            NSDictionary *json = [NSJSONSerialization
                JSONObjectWithData:responseBody ?: [NSData data] options:0 error:nil] ?: @{};

            if (httpResponse.statusCode == 401) {
                NSError *authError = [NSError errorWithDomain:@"EZAuth" code:401
                    userInfo:@{NSLocalizedDescriptionKey: @"Reset session expired."}];
                completion(json, authError);
                return;
            }

            completion(json, nil);
        });
    }] resume];
}

// ── Error mapping ─────────────────────────────────────────────────────────────
// Converts raw Supabase error codes and descriptions into user-readable strings.

- (NSString *)friendlyErrorFromData:(NSDictionary *)data networkError:(NSError *)networkError {
    if (networkError) return @"Network error. Check your connection and try again.";
    if (!data)        return @"Something went wrong. Please try again.";

    NSString *code        = data[@"error_code"] ?: data[@"error"];
    NSString *description = data[@"error_description"] ?: data[@"message"] ?: @"";

    if ([code isEqualToString:@"invalid_credentials"] ||
        [description containsString:@"Invalid login credentials"] ||
        [description containsString:@"invalid_credentials"]) {
        return @"Incorrect email or password. Please try again.";
    }
    if ([code isEqualToString:@"email_not_confirmed"] ||
        [description containsString:@"Email not confirmed"]) {
        return @"Please confirm your email before signing in.";
    }
    if ([code isEqualToString:@"user_already_exists"] ||
        [description containsString:@"User already registered"]) {
        return @"An account with this email already exists. Try signing in instead.";
    }
    if ([code isEqualToString:@"weak_password"] ||
        [description containsString:@"Password should be"]) {
        return @"Password is too weak. Use at least 8 characters with a mix of letters and numbers.";
    }
    if ([code isEqualToString:@"over_email_send_rate_limit"] ||
        [description containsString:@"rate limit"]) {
        return @"Too many attempts. Please wait a few minutes and try again.";
    }
    if ([code isEqualToString:@"signup_disabled"] ||
        [description containsString:@"Signups not allowed"]) {
        return @"New signups are temporarily disabled. Please try again later.";
    }
    if ([code isEqualToString:@"email_address_invalid"] ||
        [description containsString:@"valid email"]) {
        return @"Please enter a valid email address.";
    }
    if ([description containsString:@"Network"] ||
        [description containsString:@"connection"]) {
        return @"Network error. Check your connection and try again.";
    }

    return description.length > 0 ? description : @"Something went wrong. Please try again.";
}

// ── Periodic re-auth check ────────────────────────────────────────────────────
// Returns YES if a manual sign-in is required. Call this at app launch before
// restoreSessionWithCompletion:. If YES and credentials exist, show the login screen.

- (BOOL)requiresReAuthentication {
    if (!self.accessToken) return YES;

    NSTimeInterval lastAuth = [[NSUserDefaults standardUserDefaults]
                               doubleForKey:kLastAuthDateKey];
    if (lastAuth == 0) return NO; // Key not yet written — don't force re-auth on first update

    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - lastAuth;
    return elapsed > (60 * 60 * 24 * 7); // 7 days
}

@end
