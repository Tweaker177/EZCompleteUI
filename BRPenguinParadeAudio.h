// BRPenguinParadeAudio.h
// EZCompleteUI — Penguin Parade 
//
// All music and sound effects are synthesized in code (no audio files): a
// bouncy music-box and pizzicato waddle in C major pentatonic, penguin honks,
// egg knocks, cracks and chick chirps. The scatter notes climb a pentatonic
// scale, a drum roll builds from the second egg, and five eggs trigger an
// alarm-and-bells celebration.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BRPenguinParadeAudio : NSObject

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
/// 0...4. Same bell each time, one pentatonic step higher per egg.
- (void)playScatterNoteAtIndex:(NSInteger)index;
/// level 1...3. Call again with a higher level as more eggs land.
- (void)startDrumRollLevel:(NSInteger)level;
- (void)stopDrumRoll;
- (void)playCrash;
- (void)playBonusFanfare;
/// Five eggs: siren, ringing bells, taiko and gongs (about 5 seconds).
- (void)playAlarmCelebration;
- (void)playNearMissSigh;

// Egg meter
/// An egg flying off the reels into the meter; `index` raises the pitch for each successive egg.
- (void)playEggWhooshAtIndex:(NSInteger)index;
- (void)playMeterCharge;
- (void)playMeterBoom;

// Wins
/// ratio = payout / total bet.
- (void)playWinForPayoutRatio:(double)ratio;

// Egg-hatch bonus
- (void)playPenguinHonk;
- (void)playEggWobble;
- (void)playEggCrack;
- (void)playHatchlingChirp;
- (void)playMultiplierReveal:(NSInteger)multiplier;

@end

NS_ASSUME_NONNULL_END
