// BRRouletteAudio.h
// EZCompleteUI v1.0
//
// Purpose:
//   All roulette sound, synthesized in code (no audio files), in the same style
//   as the slot machines' audio classes: a soft lounge-jazz bed under the
//   table (electric piano chords, walking bass, brushes), chip clicks, a
//   "betting open" bell, a "no more bets" knock, a 10-second wheel-and-ball
//   spin (whirring wheel, rolling ball, ticks that slow down, final bounces and
//   the drop into the pocket), win jingles in three sizes and a gentle loss tone.
//   BRRouletteTableViewController owns one instance and calls these methods;
//   every method does nothing while the shared game-sounds switch is off.
//
// Changes from v0 (new file):
//   - Initial version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BRRouletteAudio : NSObject

/// YES once every sound has been synthesized and the engine is running.
@property (nonatomic, readonly) BOOL ready;
/// Mutes/unmutes everything without tearing the engine down.
@property (nonatomic, assign) BOOL muted;

/// Starts background synthesis and brings up the audio engine. Safe to call
/// more than once.
- (void)prepare;
/// Stops everything and releases the engine.
- (void)shutdown;
/// Restarts the engine (and the lounge bed, if wanted) after the app comes
/// back from the background or another app took the audio session.
- (void)resume;

/// Background lounge loop. Quiet, so the dealer's voice stays clear.
- (void)startAmbience;
- (void)stopAmbience;

- (void)playChipPlace;
- (void)playChipRemove;
/// Bell for "place your bets".
- (void)playBettingOpen;
/// Wood-block knock for "no more bets".
- (void)playBettingClosed;

/// Wheel whirr and ball. `seconds` is how long the spin has left on the server
/// clock; a player arriving late hears only the end of the sound.
- (void)playSpinWithRemaining:(NSTimeInterval)seconds;
- (void)stopSpin;

/// ratio = total payout / total stake. Three jingle sizes.
- (void)playWinForPayoutRatio:(double)ratio;
- (void)playLoss;

@end

NS_ASSUME_NONNULL_END
