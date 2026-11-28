// BRRouletteAudio.h
// EZCompleteUI v1.0
//
// Purpose:
//   Synthesized sound for the roulette tables — no audio files. Every sound
//   is rendered once at launch on a background queue into mono float buffers
//   (plain C in the .m), then played through a small pool of
//   AVAudioPlayerNodes. The same approach as the slot machines' audio
//   classes: Playback category with MixWithOthers, one shared sound switch
//   (BRSlotSoundEnabled), engine restart after interruptions, loops paused
//   while the app is in the background.
//
//   Sounds: chip place/remove clicks, betting open/closed stingers, a
//   10-second spin (wheel hum, rolling ball, slowing pocket ticks, the
//   drop), win jingles sized by payout ratio, a loss tone, and a looping
//   lounge ambience bed (electric piano, walking bass, brushes).
//
// Changes from v0 (new file):
//   - Initial version.

#import <Foundation/Foundation.h>

@interface BRRouletteAudio : NSObject

/// YES while the shared slot sound switch is off. Setting it updates the
/// engine's output volume immediately.
@property (nonatomic) BOOL muted;

/// Renders every buffer on a background queue and starts the engine.
/// Safe to call more than once; later calls do nothing.
- (void)prepare;

/// Restarts the engine after an interruption or route change.
- (void)resume;

/// Stops the engine and releases the player nodes.
- (void)shutdown;

#pragma mark Ambience

/// Starts the looping lounge bed (sounds only once preparation finished).
- (void)startAmbience;
- (void)stopAmbience;

#pragma mark Effects

- (void)playChipPlace;
- (void)playChipRemove;
- (void)playBettingOpen;
- (void)playBettingClosed;

/// Plays the spin sound trimmed to its last `seconds`, so it ends exactly
/// when the spin ends.
- (void)playSpinWithRemaining:(NSTimeInterval)seconds;
- (void)stopSpin;

/// Win jingle sized by payout / bet: small below 3x, medium from 3x,
/// big from 20x. A ratio of 1x or less (a push) plays nothing.
- (void)playWinForPayoutRatio:(double)ratio;
- (void)playLoss;

@end
