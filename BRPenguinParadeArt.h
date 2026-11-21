// BRPenguinParadeArt.h
// EZCompleteUI — Penguin Parade 
//
// Every symbol is illustrated in code (CoreGraphics / UIBezierPath) on a 100x100
// design grid, so the art stays sharp at any size and ships without image
// files. Symbols are drawn on a transparent background.

#import <UIKit/UIKit.h>
#import "BRPenguinParadeEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface BRPenguinParadeArt : NSObject

/// Cached, transparent-background illustration for a reel symbol.
+ (UIImage *)imageForSymbol:(PGSymbol)symbol size:(CGSize)size;

/// Short English name, e.g. "Hot Cocoa".
+ (NSString *)nameForSymbol:(PGSymbol)symbol;

/// Front-facing bonus penguin (100x140 grid). variant 0-2 changes the scarf colour.
+ (UIImage *)bonusPenguinWithVariant:(NSInteger)variant size:(CGSize)size;

/// Speckled egg. stage 0 whole, 1 cracked, 2 badly cracked (glowing).
+ (UIImage *)eggWithStage:(NSInteger)stage size:(CGSize)size;

/// Eggshell halves (cap / base cup), 100x60 grid, for the hatch burst.
+ (UIImage *)shellHalfTop:(BOOL)top size:(CGSize)size;

/// The fluffy hatchling.
+ (UIImage *)hatchlingWithSize:(CGSize)size;

/// Ice floe the bonus penguins stand on (100x30 grid).
+ (UIImage *)floeWithSize:(CGSize)size;

/// Wide arctic header backdrop — aurora ribbons, stars, iceberg
/// silhouettes and a penguin standing on the right-hand berg —
/// drawn on a 400x250 grid scaled to `size`.
+ (UIImage *)arcticBackdropWithSize:(CGSize)size;

/// A strip of snow drifts with sparkles (400x36 grid), for laying
/// along the top edge of the reel cabinet.
+ (UIImage *)snowCapWithSize:(CGSize)size;

/// Drops cached images (call from didReceiveMemoryWarning).
+ (void)purgeCache;

@end

NS_ASSUME_NONNULL_END
