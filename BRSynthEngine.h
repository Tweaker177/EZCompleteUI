// BRSynthEngine.h
// BrainRotGame
// EZCompleteUI
//
// Purpose:
//   Minimal real-time synthesizer for Ricochet Blast. Unlike
//   BrainRotViewController's SFX system (preloaded .aiff files played via
//   AVAudioPlayer), this generates a short triangle-wave note on the fly
//   for every wall/bounds/enemy hit — no sound assets required. Notes are
//   picked at random from the current musical scale in the current key, and
//   playback is quantized to an eighth-note grid at the current tempo so a
//   burst of simultaneous collisions doesn't collapse into noise.
//
// Usage:
//   Own one instance per game session. Call -start once (after a user
//   gesture, e.g. the Launch tap — required by iOS audio session rules),
//   -queueHitWithVelocity: from collision handling, and -tick once per
//   CADisplayLink frame to drain the queue on the tempo grid.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, BRSynthScale) {
    BRSynthScaleMajor,
    BRSynthScaleMinor,
    BRSynthScalePentatonic
};

typedef NS_ENUM(NSInteger, BRSynthArpeggioDivision) {
    BRSynthArpeggioDivisionQuarter,
    BRSynthArpeggioDivisionEighth,
    BRSynthArpeggioDivisionSixteenth,
};

typedef NS_ENUM(NSInteger, BRSynthWaveform) {
    BRSynthWaveformSine,
    BRSynthWaveformTriangle,
    BRSynthWaveformSawtooth,
    BRSynthWaveformSquare,
};

typedef NS_ENUM(NSInteger, BRSynthModulationTarget) {
    BRSynthModulationTargetPitch,      // vibrato
    BRSynthModulationTargetAmplitude,  // tremolo
};

NS_ASSUME_NONNULL_BEGIN

@interface BRSynthEngine : NSObject

/// Root note as a semitone offset from A3 (220 Hz), 0-11 (0 = A, 2 = B, 3 = C, …).
/// The owning view controller persists this via NSUserDefaults; this class
/// only reads it at note-generation time.
@property (nonatomic, assign) NSInteger rootSemitone;
@property (nonatomic, assign) BRSynthScale scale;

/// Beats per minute. Queued hits are drained on an eighth-note grid at this
/// tempo — see -tick.
@property (nonatomic, assign) NSInteger tempoBPM;
/// Semitone register offset: -4...+3 octaves relative to the game default.
@property (nonatomic, assign) NSInteger octaveOffset;
@property (nonatomic, assign) float attackSeconds;          // 0.005...0.25
@property (nonatomic, assign) float releaseSeconds;         // 0.04...0.70
@property (nonatomic, assign) float filterBrightness;       // 0 = dark, 1 = bright
@property (nonatomic, assign) float reverbMix;              // 0 = dry, 1 = fully wet
@property (nonatomic, assign) float compressionMix;         // 0 = open, 1 = tightly compressed
@property (nonatomic, assign) float synthVolume;            // 0 = muted, 1 = unity
@property (nonatomic, assign) float drumsVolume;            // 0 = muted, 1 = unity
@property (nonatomic, assign) BRSynthArpeggioDivision arpeggioDivision;

// ── Oscillator / tone-shaping ────────────────────────────────────────────
// Every note (collision hits, arpeggiator, random hits) runs through this
// same voice: up to two detunable oscillators, a brightness filter (already
// existed), a saturation stage, and an LFO that can modulate pitch or
// amplitude. This is what actually determines the timbre — rootSemitone/
// scale/tempoBPM above only decide *which* notes play, not what they sound
// like.

/// Waveform for the primary oscillator.
@property (nonatomic, assign) BRSynthWaveform waveform;

/// Second oscillator, detuned from the first, for a fuller poly/duo-synth
/// tone. Disabled by default (single-oscillator voice, matches old behavior).
@property (nonatomic, assign, getter=isOscillator2Enabled) BOOL oscillator2Enabled;
@property (nonatomic, assign) BRSynthWaveform oscillator2Waveform;
/// Detune in cents, roughly -50...+50. Small values (5-15) thicken the tone;
/// larger values create a wider, more chorused/dissonant spread.
@property (nonatomic, assign) float oscillator2DetuneCents;
/// Blend between oscillator 1 only (0.0) and an equal 1:1 mix with
/// oscillator 2 (1.0).
@property (nonatomic, assign) float oscillator2Mix;

/// Soft-clip drive, 0 (clean) to 1 (heavily saturated/distorted). Applied
/// after filtering, before the envelope, so it warms up the waveform itself
/// rather than just adding gain.
@property (nonatomic, assign) float saturationDrive;

/// LFO rate in Hz (typical musical range ~0.5-12) and depth 0 (off) to 1
/// (strong). modulationTarget picks vibrato (pitch) vs tremolo (amplitude).
@property (nonatomic, assign) float modulationRateHz;
@property (nonatomic, assign) float modulationDepth;
@property (nonatomic, assign) BRSynthModulationTarget modulationTarget;

/// Plays Ricochet's bundled 808 pattern while the game is running. The loop
/// follows tempoBPM whether or not a MIDI receiver is connected.
@property (nonatomic, assign, getter=isDrumLoopEnabled) BOOL drumLoopEnabled;

/// Zero-based 808 beat selection. Changes made while playing take effect on
/// the next two-bar downbeat, so a new Ricochet level never cuts a beat off.
@property (nonatomic, assign) NSInteger drumPatternIndex;

/// When enabled, publishes a virtual CoreMIDI source named “EZCompleteUI
/// Ricochet”. It sends Start/Stop, 24-PPQN MIDI Clock, and quantized note
/// events that mirror the synth's collision notes and 808 drum pattern.
@property (nonatomic, assign, getter=isMIDIClockEnabled) BOOL midiClockEnabled;

@property (nonatomic, readonly) BOOL isStarted;
    // BRSynthEngine.h — add to the public interface
    /// Plays a note immediately (not queued to the tempo grid) — for real-time
    /// input like the on-screen smart keyboard, where quantized/delayed
    /// playback would feel laggy. Starts the engine automatically if needed.
    - (void)playKeySemitone:(NSInteger)semitone velocity:(float)velocity;
/// Lazily brings up the AVAudioEngine graph. Safe to call more than once —
/// no-ops after the first successful start. Call this from a user-gesture
/// handler (e.g. the Launch button), not from viewDidLoad, so it doesn't
/// fight the app's existing audio session activation.
- (void)start;

/// Tears down playback. Call from viewWillDisappear / dealloc-adjacent
/// cleanup so a backgrounded or dismissed game doesn't keep the engine hot.
- (void)stop;

/// Queues a hit. velocity is roughly in [0, 2.5] — wall bumps and bounds
/// hits should pass ~1.0, enemy contact and Use blasts can pass higher for
/// a louder, more urgent note. The queue caps at 8 pending hits; older
/// entries are dropped first so a chaotic moment on screen doesn't queue up
/// a long trailing arpeggio.
- (void)queueHitWithVelocity:(float)velocity;

/// Queues a chord-friendly impact note. The rebound angle and collision point
/// select root, third, fifth, seventh, or ninth positions and the octave.
- (void)queueCollisionAtPoint:(CGPoint)point
                     boardSize:(CGSize)boardSize
                   impactAngle:(CGFloat)impactAngle
                      velocity:(float)velocity;

/// Applies a temporary musical pickup effect: 0 = reverb, 1 = compression,
/// 2 = chorus. The effect decays naturally while the game continues.
- (void)triggerReactiveEffect:(NSInteger)effect;

/// Call once per display-link frame. No-op if the engine hasn't been
/// started yet or the queue is empty.
- (void)tick;

@end

NS_ASSUME_NONNULL_END
