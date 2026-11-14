// BRGoldenMandarinAudio.h
// EZCompleteUI — Golden Mandarin (金帽福运) slot
//
// All music and sound effects are synthesized in code (no audio files):
// plucked-string theme (D-major pentatonic, guzheng/pipa flavored), bamboo
// flute, taiko, temple blocks, gongs and bells. The scatter notes climb a
// pentatonic scale, a drum roll builds from the second hat, and five hats
// trigger an alarm-and-bells celebration.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BRGoldenMandarinAudio : NSObject

/// YES once every sound has been synthesized and the engine is running.
@property (nonatomic, readonly) BOOL ready;
/// Mutes/unmutes everything without tearing the engine down.
@property (nonatomic, assign) BOOL muted;
/// Called on the main queue when synthesis finishes.
@property (nonatomic, copy, nullable) dispatch_block_t onReady;

/// Starts background synthesis and brings up the audio engine. Safe to call
/// more than once.
- (void)prepare;
/// Stops everything and releases the engine.
- (void)shutdown;
/// Restarts the engine (and the music, if it was playing) after the app comes
/// back from the background or another app took the audio session.
- (void)resume;

// Music
- (void)startThemeBonus:(BOOL)bonus;
- (void)stopTheme;
/// Lowers the music so effects and the drum roll read clearly.
- (void)duckTheme:(BOOL)duck;

// Reels
- (void)playSpinStart;
- (void)playReelStop:(NSInteger)reelIndex;

// Scatter build-up
/// 0...4. Same bell each time, one pentatonic step higher per hat.
- (void)playScatterNoteAtIndex:(NSInteger)index;
/// level 1...3. Call again with a higher level as more hats land.
- (void)startDrumRollLevel:(NSInteger)level;
- (void)stopDrumRoll;
- (void)playCrash;
- (void)playBonusFanfare;
/// Five hats: siren, ringing bells, taiko and gongs (about 5 seconds).
- (void)playAlarmCelebration;
- (void)playNearMissSigh;

// Wins
/// ratio = payout / total bet.
- (void)playWinForPayoutRatio:(double)ratio;

// Hat shuffle bonus
- (void)playCardFlip;
- (void)playCardPick;
- (void)playMultiplierReveal:(NSInteger)multiplier;

@end

NS_ASSUME_NONNULL_END
