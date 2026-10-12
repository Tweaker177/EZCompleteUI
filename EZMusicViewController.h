// EZMusicViewController.h
// EZCompleteUI v1.0
//
// Purpose:
//   The "AI Music" screen: describe a song, pick a length and how many
//   variants to make, see the price, generate it with ElevenLabs, then play,
//   favorite, share/save or delete it from a personal library.
//
//   Two tabs share one controller:
//     Create  - prompt, optional title, instrumental switch, length slider,
//               variant count, live coin quote, Generate button.
//     Library - every song the account has made, newest first, including
//               songs still being composed and songs that failed (those were
//               refunded by the server automatically).
//
//   All pricing, billing and storage happen on the server through
//   EZMusicService. The price shown here is only a quote for display; the
//   server recomputes the real charge on every request.
//
//   Present it inside a UINavigationController, for example:
//     [self presentViewController:[[UINavigationController alloc]
//         initWithRootViewController:[[EZMusicViewController alloc] init]]
//                        animated:YES completion:nil];
//
// Changes:
//   - Initial version.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZMusicViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
