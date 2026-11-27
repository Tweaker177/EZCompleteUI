// BRRouletteAPI.h
// EZCompleteUI v1.0
//
// Purpose:
//   The single client-side entry point to the br-roulette Edge Function.
//   The lobby and the table screen both talk to the server through this
//   class so URL building, auth, retry and error handling live in one place.
//   The client never decides anything about coins or cards; it sends the
//   player's intent and draws whatever the server answers.
//
// Changes from v0 (new file):
//   - Initial version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Completion handler. Always runs on the main queue.
///   json         - parsed response body (also present on HTTP errors, where it
///                  may carry a fresh "view" the caller can redraw from).
///   statusCode   - HTTP status, or 0 when the request never got a response.
///   errorMessage - player-facing text, nil on success.
typedef void (^BRRouletteCompletion)(NSDictionary * _Nullable json, NSInteger statusCode, NSString * _Nullable errorMessage);

@interface BRRouletteAPI : NSObject

/// Sends one action (list_tables, join, leave, state, bet, clear_bets).
/// Transient network failures are retried once automatically; the server
/// never double-charges: a bet request that was already applied is rejected by the server,
/// so a retry can never double-charge.
+ (void)performAction:(NSString *)action
               params:(nullable NSDictionary *)params
           completion:(BRRouletteCompletion)completion;

@end

NS_ASSUME_NONNULL_END
