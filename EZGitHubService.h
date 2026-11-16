// EZGitHubService.h
// EZCompleteUI v1.0
//
// Purpose:
//   Network client for the ez-github Supabase Edge Function. It holds no
//   GitHub token and no GitHub logic: the token is sent once (connect), is
//   stored encrypted on the server, and never comes back. Everything the chat
//   models do on GitHub goes through -runRequest:, which sends the validated
//   github_request that ez-chat handed back and reports what the server says.
//
//   Writes are two steps. -runRequest:confirmed:NO on a write action returns a
//   preview (needs_confirmation, summary, details) and changes nothing; the
//   caller shows it to the user and, only if they approve, repeats the same
//   request with confirmed:YES. The server enforces this as well, so a modified
//   app cannot skip the preview or write while writes are switched off.
//
//   Networking behavior handled here so view controllers don't have to:
//     - Attaches a valid (refreshed if needed) access token to every request.
//     - Retries dropped connections once, EXCEPT for a confirmed write: that
//       could repeat a commit, so it is never retried automatically.
//     - Retries once on HTTP 401 after refreshing the session.
//     - Always calls completion blocks on the main queue.
//
// v1.0:
//   - Initial version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const EZGitHubServiceErrorDomain;

/// userInfo key holding the server's machine-readable error code, for example
/// "github_token_invalid" or "invalid_request".
extern NSString * const EZGitHubServiceServerCodeKey;

typedef NS_ENUM(NSInteger, EZGitHubServiceErrorCode) {
    EZGitHubServiceErrorNotSignedIn = 1,
    EZGitHubServiceErrorNetwork     = 2,
    EZGitHubServiceErrorServer      = 3,   // The server rejected or failed the request.
    EZGitHubServiceErrorBadResponse = 4,   // The reply was not the JSON we expected.
};

@interface EZGitHubService : NSObject

+ (instancetype)sharedService;
- (instancetype)init NS_UNAVAILABLE;

/// Verifies the token with GitHub and stores it (encrypted) on the server.
/// `tokenExpiresAt` is GitHub's expiry string for fine-grained tokens, or nil.
- (void)connectWithToken:(NSString *)token
              completion:(void (^)(NSString * _Nullable login,
                                   NSString * _Nullable tokenExpiresAt,
                                   NSError * _Nullable error))completion;

/// Whether this account has a saved GitHub token, which login it belongs to
/// and whether the user has allowed the chat models to propose changes.
- (void)fetchStatusWithCompletion:(void (^)(BOOL connected,
                                            NSString * _Nullable login,
                                            BOOL allowWrites,
                                            NSError * _Nullable error))completion;

/// Turns the models' write actions (branches, commits, pull requests,
/// comments) on or off. Every write still needs an approval each time.
- (void)setAllowWrites:(BOOL)allowWrites
            completion:(void (^)(BOOL allowWrites, NSError * _Nullable error))completion;

/// Forgets the saved token and any saved repository archives.
- (void)disconnectWithCompletion:(void (^)(NSError * _Nullable error))completion;

/// Runs one github_request returned by ez-chat. `result` is the server's JSON:
/// ok, action, summary, message_for_model, needs_confirmation, details,
/// archive {url, filename, bytes, expires_in}, links [{label, url}], and on
/// failure code + error. A GitHub-side failure (not found, rate limit, ...)
/// arrives as a result with ok = NO, not as an NSError; an NSError means the
/// server itself could not be reached or rejected the call.
- (void)runRequest:(NSDictionary *)request
         confirmed:(BOOL)confirmed
        completion:(void (^)(NSDictionary * _Nullable result,
                             NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
