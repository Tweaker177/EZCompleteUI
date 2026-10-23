// EZMusicBubbleCell.h
// EZCompleteUI v1.0
//
// Purpose:
//   Chat row for a finished song that a chat model created through its
//   "create music" tool. It shows the song's title and length with two
//   buttons:
//     - Play:  opens the MP3 in Quick Look, which has its own playback
//              controls and a share/save button.
//     - Share: opens the system share sheet (Save to Files, AirDrop, ...).
//
//   The cell only knows the song's entry ID. The MP3 normally already sits in
//   the on-device music library (EZMusicLibraryManager); if it does not (for
//   example it was removed, or the earlier download failed), tapping Play or
//   Share fetches a fresh signed link from the ez-music function and
//   downloads it first.
//
//   Fed by ViewController for display messages whose role is "music".

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZMusicBubbleCell : UITableViewCell

/// `subtitle` is the line under the title (for example "AI song • 1:05").
/// `presentingController` is used to show Quick Look, the share sheet and any
/// error alert.
- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                   entryID:(NSString *)entryID
      presentingController:(UIViewController *)presentingController;

@end

NS_ASSUME_NONNULL_END
