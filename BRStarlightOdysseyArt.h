// BRStarlightOdysseyArt.h
// EZCompleteUI — Starlight Odyssey slot
//
// Every symbol is illustrated in code (CoreGraphics / UIBezierPath) on a 100x100
// design grid, so the art stays sharp at any size and ships without image
// files. Symbols are drawn on a transparent background.

#import <UIKit/UIKit.h>
#import "BRStarlightOdysseyEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface BRStarlightOdysseyArt : NSObject

/// Cached, transparent-background illustration for a reel symbol.
+ (UIImage *)imageForSymbol:(SOSymbol)symbol size:(CGSize)size;

/// Short English name, e.g. "Rocket".
+ (NSString *)nameForSymbol:(SOSymbol)symbol;

/// Face-down card for the warp-card shuffle bonus: deep-space blue, cyan border, gold star.
+ (UIImage *)cardBackWithSize:(CGSize)size;

/// Drops cached images (call from didReceiveMemoryWarning).
+ (void)purgeCache;

@end

NS_ASSUME_NONNULL_END
