// BRRouletteDealer.h
// EZCompleteUI v1.0
//
// Purpose:
//   The roulette dealer's voice. Plays the same pre-rendered ElevenLabs clips
//   the blackjack dealers use, so each roulette table sounds like the dealer
//   of its blackjack twin, in the app's language:
//     - "Place your bets" and "No more bets" come from the shared blackjack
//       clip library (br-blackjack, dealer_clips) and are never rendered twice.
//     - The winning-number call ("17, red") comes from the roulette clips
//       (br-roulette, dealer_clips), the only ones blackjack does not have.
//   All rendering (and its cost) happens on the server; this class only
//   downloads finished clips. While clips are still being rendered, or if the
//   voice service is down, the call is read by the built-in Apple voice so the
//   table is never silent and the game never waits on audio.
//
// Changes from v0 (new file):
//   - Initial version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Clip keys the table screen can ask for.
extern NSString *const BRRouletteClipPlaceBets;   // shared blackjack clip "place_bets"
extern NSString *const BRRouletteClipNoMoreBets;  // shared blackjack clip "no_more_bets"
/// Key of the winning-number call for a pocket (0-36), e.g. "rl17".
NSString *BRRouletteClipKeyForNumber(NSInteger number);

@interface BRRouletteDealer : NSObject

- (instancetype)initWithTableID:(NSString *)tableID;

/// Fetches the clip lists and downloads the clips. Safe to call once when the
/// table opens; it retries by itself while the server is still rendering.
- (void)loadClips;

/// Speaks one call. keys are played back to back; fallbackText is read by the
/// Apple voice when any clip is missing. Does nothing when the shared game
/// sound switch is off. A burst of calls drops the oldest unplayed ones.
- (void)speakKeys:(NSArray<NSString *> *)keys fallbackText:(NSString *)fallbackText;

/// Cuts off anything being spoken and clears the queue (leaving, backgrounding,
/// sound switched off). The dealer can be used again afterwards.
- (void)interrupt;

/// Final shutdown when the screen goes away: stops speech and network retries.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
