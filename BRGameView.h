// BRGameView.h
// BrainRotGame
// EZCompleteUI v1.6
//
// Changes from v1.5:
//   - heartPulsePhase comment updated to reflect that the heart pickup now
//     draws heart.png (see BRGameView.m v1.6). The property itself and the
//     CADisplayLink driving it in BrainRotViewController are unchanged.
//
// Purpose:
//   Public interface for BRGameView, the custom UIView that renders the
//   visible maze viewport. The view is deliberately passive: it holds the
//   BRGameModel reference and a few display properties, and BrainRotViewController
//   calls setNeedsDisplay whenever the model changes. All drawing happens in
//   a single drawRect: pass — see BRGameView.m for the rendering pipeline.

#import <UIKit/UIKit.h>
#import "BRGameModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface BRGameView : UIView

@property (nonatomic, strong, nullable) BRGameModel *model;

/// When set, drawRect crops the viewport region of this image and draws it
/// as the bottom layer, perfectly synchronized with the camera offset.
/// Set to nil to use solid-color tile fills (fallback mode).
@property (nonatomic, strong, nullable) UIImage *backgroundImage;
/// Optional custom wall art. Drawn darker at 40% opacity; generated walls
/// remain the fallback whenever this asset is absent.
@property (nonatomic, strong, nullable) UIImage *wallImage;

/// When YES, the player dot is not drawn. Use when the ViewController
/// renders the hero with an animated UIImageView overlay instead.
/// Does NOT affect enemy indicators — those always draw.
@property (nonatomic, assign) BOOL hidePlayerDot;

/// Number of tile columns visible at once. Default 9.
@property (nonatomic, assign) NSInteger viewportCols;

/// Number of tile rows visible at once. Default 9.
@property (nonatomic, assign) NSInteger viewportRows;

/// Left edge of the visible window in model tile coordinates.
@property (nonatomic, assign) NSInteger cameraCol;

/// Top edge of the visible window in model tile coordinates.
@property (nonatomic, assign) NSInteger cameraRow;

/// Phase angle (0–2π) used to drive the heart pickup's pulse animation.
/// Incremented every CADisplayLink tick by BrainRotViewController's
/// heartPulseTick: and read in drawRect: to scale heart.png by
/// (1 + 0.12 × sin(phase)). Do not set this directly — use
/// startHeartPulseLink / stopHeartPulseLink in BrainRotViewController.
@property (nonatomic, assign) CGFloat heartPulsePhase;

@end

NS_ASSUME_NONNULL_END
