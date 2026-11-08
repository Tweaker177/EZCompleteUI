//
//  EZTTSClipEditViewController.h
//  EZTTSLibrary
//
//  Expanded editing view for a single archived clip — or, via
//  -initWithSoundEntry:, a generated sound from the Sounds library:
//   - Waveform range tools: insert silence, trim to the selection, and
//     peak-normalize the selection (a full-clip normalize replaces the
//     audio in place; a partial one offers save-as-new or overwrite).
//   - Speed: playback-rate only, persisted per-entry, no regeneration.
//   - Effects (pitch shift, reverb, echo, EQ presets): applied to the
//     whole audio and always saved as a brand-new entry.
//   - Change voice (TTS clips only): hands off to the compose screen,
//     prefilled, for an actual regeneration (voice changes require new
//     audio — nothing in this view fakes that).
//   - Background scene level (TTS scene clips only).
//  Save convention in both libraries: edits land as NEW entries and the
//  original is never modified, except the explicit in-place normalize
//  paths.
//

#import <UIKit/UIKit.h>
#import "EZTTSManifestEntry.h"

@class EZSoundManifestEntry;

NS_ASSUME_NONNULL_BEGIN

@interface EZTTSClipEditViewController : UIViewController

- (instancetype)initWithEntry:(EZTTSManifestEntry *)entry;

/// Opens the editor on a generated sound instead of a TTS clip. Every
/// editing tool works the same and results archive into the Sounds
/// library under the same save convention; the Change Voice section is
/// hidden (it regenerates speech, which makes no sense for a sound)
/// and the background-scene section never applies.
- (instancetype)initWithSoundEntry:(EZSoundManifestEntry *)entry;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
