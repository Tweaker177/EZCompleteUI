// BRRicochetGameView.h
// BrainRotGame
// EZCompleteUI
//
// Purpose:
//   Renders the open Ricochet Blast board: the background image (or a
//   fallback fill color if none was supplied) plus the breakable obstacle
//   particles. Deliberately simpler than BRGameView — there's no
//   camera/viewport scrolling and no per-tile wall-image cache, since the
//   whole board is visible at once and obstacles disappear outright rather
//   than swapping between wall art variants.
//
//   Player and enemy sprites are NOT drawn here. The view controller
//   positions floating UIImageViews above this view — the same pattern
//   BrainRotViewController already uses for playerImageView / enemyImage.

#import <UIKit/UIKit.h>
#import "BRRicochetGameModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface BRRicochetGameView : UIView

@property (nonatomic, strong, nullable) BRRicochetGameModel *model;
@property (nonatomic, strong, nullable) UIImage *backgroundImage;

/// Briefly set true (with blastPreviewCenter/Radius) to draw the Use
/// blast's radius ring, e.g. for the moment the charge becomes full.
@property (nonatomic, assign) BOOL showingBlastPreview;
@property (nonatomic, assign) CGPoint blastPreviewCenter;
@property (nonatomic, assign) CGFloat blastPreviewRadius;

@end

NS_ASSUME_NONNULL_END
