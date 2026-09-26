// BRSmartKeyboardView.h
// BrainRotGame
// EZCompleteUI
//
// Purpose:
//   A controller TYPE, not a separate game mode — this replaces the
//   leftBtn/rightBtn pair in place when the player switches to keyboard
//   input. Nothing else about the run changes (Use button, HUD, physics
//   all stay exactly as they are).
//
//   Two rows:
//     - Top row: a "smart" keyboard — only shows notes diatonic to
//       BRSynthEngine's current rootSemitone/scale, so there's no wrong
//       note to hit. Keys run left-to-right in pitch order like a real
//       keyboard. Touching a key plays it immediately (not queued to the
//       collision tempo grid — see BRSynthEngine's -playKeySemitone:
//       velocity:) AND steers the player: steering is the horizontal
//       centroid of all currently-held keys, normalized to -1...+1, so
//       reaching for a higher note naturally nudges you right and vice
//       versa. Multitouch works — hold several keys for a chord while the
//       centroid still drives steering.
//     - Bottom row: quick knobs (Filter / Saturation / Reverb / Synth Vol)
//       so switching to keyboard mode doesn't cost you tone-shaping
//       access — it relocates it, per the brief ("when the keyboard isn't
//       being used as an input, the bottom row could be full of knobs").
//       These are live BRSynthEngine properties; nothing here duplicates
//       BRMusicLabViewController's job, it's just a quick-access subset.
//
// Dependency note: this file includes a small self-contained
// BRMiniKnobControl for the bottom row. If the app already has a proper
// rotary knob control (the Music Lab screenshot shows one), swap that in
// instead and delete BRMiniKnobControl — the four bottom-row instances are
// the only thing that would need to change.

#import <UIKit/UIKit.h>
@class BRSynthEngine;

NS_ASSUME_NONNULL_BEGIN

@interface BRSmartKeyboardView : UIView

/// Not retained — set by the presenter, must outlive this view.
@property (nonatomic, weak, nullable) BRSynthEngine *synth;

/// Fired on every new key press (including a finger sliding onto a new key
/// mid-touch — a glissando triggers each key it crosses).
@property (nonatomic, copy, nullable) void (^onNote)(NSInteger semitone, float velocity);

/// Fired whenever the held-key centroid changes, including back to 0 when
/// the last key-row touch lifts. Range -1 (steer hard left) to +1 (hard
/// right); consume this once per frame the same way the old hold-buttons'
/// boolean flags were consumed, just proportionally instead of fixed-rate.
@property (nonatomic, copy, nullable) void (^onSteerChanged)(CGFloat steerAmount);

/// Fired after any bottom-row knob changes a synth property, so the
/// presenter can persist settings (same contract as BRMusicLabViewController
/// .onSettingsChanged — wire both to the same -persistSynthSettings).
@property (nonatomic, copy, nullable) void (^onSettingsChanged)(void);

/// Regenerates the key layout from synth.rootSemitone/scale and refreshes
/// knob positions from their current synth values. Call once after setting
/// .synth, and again any time the key/scale changes elsewhere (e.g. after
/// the Music Lab sheet is dismissed).
- (void)refreshFromSynth;

@end

NS_ASSUME_NONNULL_END
