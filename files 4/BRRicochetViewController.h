// BRRicochetViewController.h
// BrainRotGame
// EZCompleteUI
//
// Purpose:
//   Ricochet Blast — the open, physics-bounce sibling to
//   BrainRotViewController's maze game. It shares the exact same custom-
//   asset input as the maze game (player image, enemy image, background
//   image, all sourced from a BRGameRecord produced by
//   BRCustomGameCreatorViewController / BRGameLibrary) and nothing else:
//   no grid, no corridors, no items/hint/premise logic. Mechanics are
//   constant-speed ricochet physics, left/right steering only, and a Use
//   button that blasts nearby obstacles regardless of remaining HP.
//
// Wiring:
//   Wherever BrainRotViewController is currently pushed —
//   BRGamePickerViewController.onSelection and
//   BRCustomGameCreatorViewController.onPlayRequested are the two call
//   sites seen in BrainRotViewController.m — branch on whichever "game
//   type" flag your picker/creator UI ends up exposing and push this
//   controller instead via +ricochetControllerWithGameRecord:. This class
//   never reads record.items / record.enemies / record.hint / record.premise
//   — those are maze-only fields from the AI premise generation step and
//   are simply ignored here, so no changes are needed upstream in
//   BRCustomGameCreatorViewController to support this game type.

#import <UIKit/UIKit.h>
@class BRGameRecord;

NS_ASSUME_NONNULL_BEGIN

@interface BRRicochetViewController : UIViewController

/// Plain entry point — mirrors how BrainRotViewController itself is
/// presented. On first viewDidAppear: this presents BRGamePickerViewController
/// (members) or the Workshop directly (non-members), exactly like
/// BrainRotViewController's own one-shot _hasPresentedInitialFlow logic.
+ (instancetype)ricochetController;

/// Skips straight to a known record — useful for a future "Play as Ricochet"
/// action on an existing saved-game cell, without going through the picker.
+ (instancetype)ricochetControllerWithGameRecord:(BRGameRecord *)record;

/// Preloads a photo picked in EZ Attachments straight into the Workshop,
/// same contract as BrainRotViewController.initialWorkshopImage.
@property (nonatomic, strong, nullable) UIImage *initialWorkshopImage;

/// Rebuilds the board from a (possibly new) record — same reusable-loader
/// shape as BrainRotViewController's -loadGameRecord:, so this also covers
/// "Play Again" for a saved Ricochet Blast run.
- (void)loadGameRecord:(BRGameRecord *)record;

@end

NS_ASSUME_NONNULL_END
