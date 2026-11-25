// BRBlackjackAPI.h
// EZCompleteUI v1.0
//
// Purpose:
//   The single client-side entry point to the br-blackjack Edge Function.
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
typedef void (^BRBlackjackCompletion)(NSDictionary * _Nullable json, NSInteger statusCode, NSString * _Nullable errorMessage);

@interface BRBlackjackAPI : NSObject

/// Sends one action (list_tables, join, leave, state, bet, hit, stand, double).
/// Transient network failures are retried once automatically; the server
/// guards every action against duplicates (expected_version / already_bet),
/// so a retry can never double-charge.
+ (void)performAction:(NSString *)action
               params:(nullable NSDictionary *)params
           completion:(BRBlackjackCompletion)completion;

@end

/// The casino floor's background noise — the same crowded_casino loop
/// the slot picker plays — for the blackjack lobby. The table itself
/// stays quiet: the lobby starts the loop when it appears and stops
/// it when it goes away.
@interface BRBlackjackAmbience : NSObject
+ (void)start;
+ (void)stop;
@end

NS_ASSUME_NONNULL_END
