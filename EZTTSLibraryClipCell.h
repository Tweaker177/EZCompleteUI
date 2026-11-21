//
//  EZTTSLibraryClipCell.h
//  EZTTSLibrary
//
//  A single row in the archived-clips list: title/prompt preview, voice + duration +
//  date subtitle, a compact WaveformView, and a play/pause button. Purely presentational
//  — it owns no audio playback or file I/O itself, it just renders whatever it's given
//  and reports taps back via `onPlayTapped`.
//

#import <UIKit/UIKit.h>
#import "EZTTSManifestEntry.h"

NS_ASSUME_NONNULL_BEGIN

@interface EZTTSLibraryClipCell : UITableViewCell

@property (nonatomic, copy, nullable) void (^onPlayTapped)(void);
@property (nonatomic, copy, nullable) void (^onFavoriteTapped)(void);
/// The row's one action button: a share glyph that opens the clip's
/// action menu (Share / Edit / Regenerate / Rename) in the controller.
@property (nonatomic, copy, nullable) void (^onShareTapped)(void);

/// Populates labels and kicks off an async waveform render from `audioURL`.
/// `audioURL` is the absolute file URL (from EZTTSLibraryManager -absoluteURLForEntry:).
- (void)configureWithEntry:(EZTTSManifestEntry *)entry audioURL:(NSURL *)audioURL;

/// Toggles the play/pause glyph. Does not start/stop any actual playback — the owning
/// view controller drives this based on its own AVAudioPlayer state.
- (void)setPlaying:(BOOL)playing;

/// Updates just the star glyph in place, without touching the waveform/labels or
/// restarting the async waveform load. Used when animating a favorited row's move to
/// the top of the list, where the cell instance itself relocates but its content doesn't
/// need to be rebuilt.
- (void)setFavorite:(BOOL)favorite;

/// 0.0–1.0 playhead position drawn on the waveform. Only meaningful while playing.
- (void)setPlaybackProgress:(CGFloat)progress animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
