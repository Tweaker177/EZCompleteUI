// BRGamePickerViewController.h
// BrainRotGame
// EZCompleteUI v2.2
//
// Full-screen game library picker. Displays saved games as a 2-column card grid
// with the background image filling each card and the title drawn over a gradient.
// A "New Game" card sits at index 0 always. A "✕" close button lets the player
// exit the picker without making any selection, firing onClosedWithoutSelection.
//
// Usage:
//   BRGamePickerViewController *picker = [BRGamePickerViewController new];
//   picker.onSelection = ^(BRGameRecord *record) {
//       // record == nil  →  user tapped New Game
//       // record != nil  →  user chose a saved game
//   };
//   picker.onClosedWithoutSelection = ^{
//       // user tapped ✕ — dismiss or pop yourself here
//   };
//   [self presentViewController:picker animated:YES completion:nil];

#import <UIKit/UIKit.h>
#import "BRGameLibrary.h"

NS_ASSUME_NONNULL_BEGIN

@interface BRGamePickerViewController : UIViewController

/// Called on the main thread when the user makes a selection.
/// nil record means New Game; non-nil means load that record.
/// The picker has already been dismissed before this block fires.
@property (nonatomic, copy) void (^onSelection)(BRGameRecord *_Nullable record);

/// Called on the main thread when the player taps "✕" to close the picker
/// without making any selection. The picker has already been dismissed before
/// this block fires. The presenter should use this to back out of its own
/// view rather than revealing whatever it was showing underneath the picker.
@property (nonatomic, copy, nullable) void (^onClosedWithoutSelection)(void);

/// Opens directly to the existing visual Community grid instead of My Games.
@property (nonatomic, assign) BOOL startsOnCommunityTab;

/// Optional alternate hand-off used by Slots. After a community game is
/// downloaded, its normal PLAY action delivers the saved record here so the
/// caller can adapt it as a slot theme rather than launch Maze gameplay.
@property (nonatomic, copy, nullable) void (^onSlotThemeSelection)(BRGameRecord *record);

@end

NS_ASSUME_NONNULL_END
