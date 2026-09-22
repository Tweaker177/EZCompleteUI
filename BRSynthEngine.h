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

typedef NS_ENUM(NSInteger, BRSynthScale) {
    BRSynthScaleMajor,
    BRSynthScaleMinor,
    BRSynthScalePentatonic
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

/// When enabled, publishes a virtual CoreMIDI source named “EZCompleteUI
/// Ricochet”. It sends Start/Stop, 24-PPQN MIDI Clock, and quantized note
/// events that mirror the synth's collision notes.
@property (nonatomic, assign, getter=isMIDIClockEnabled) BOOL midiClockEnabled;

@property (nonatomic, readonly) BOOL isStarted;

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

/// Call once per display-link frame. No-op if the engine hasn't been
/// started yet or the queue is empty.
- (void)tick;

@end

NS_ASSUME_NONNULL_END
