// EZMusicBubbleCell.h
// EZCompleteUI v1.2
//
// Purpose:
//   Chat row for a finished song that a chat model created through its
//   "create music" tool. It is a small inline player:
//     - A play/pause button (it shows a spinner while the file loads).
//     - A scrubber you can drag, enabled while this song is the one loaded.
//     - "elapsed / total" time.
//     - A share button (system share sheet: Save to Files, AirDrop, ...).
//
//   The cell does not own an audio player. It asks the app-wide
//   EZMediaPlayerManager to play the song and then mirrors that manager's
//   state, so the button, scrubber and time stay correct when playback is
//   paused from the lock screen, ends, or another song starts.
//
//   Playing needs the MP3 on this device. It normally already sits in the
//   on-device music library (EZMusicLibraryManager); if not, tapping play or
//   share fetches a fresh signed link from the ez-music function and downloads
//   it first.
//
//   Fed by ViewController for display messages whose role is "music".
//
// Changes from v1.1:
//   - Shows the song's generated cover art (or a placeholder) at the left.
//
// Changes from v1.0:
//   - Play no longer opens Quick Look; the card plays inline through
//     EZMediaPlayerManager (background audio, lock-screen controls).
//   - Added the scrubber and elapsed/total time.
//   - Added the durationSeconds parameter so the total shows before playing.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZMusicBubbleCell : UITableViewCell

/// `subtitle` is the line under the title (for example "AI song"). It is
/// temporarily replaced by a message if playback fails.
/// `durationSeconds` is the song length if known, otherwise 0.
/// `presentingController` is used for the share sheet and error alerts.
- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
           durationSeconds:(NSInteger)durationSeconds
                   entryID:(NSString *)entryID
      presentingController:(UIViewController *)presentingController;

@end

NS_ASSUME_NONNULL_END
