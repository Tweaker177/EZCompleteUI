// BRGoldenMandarinArt.h
// EZCompleteUI — Golden Mandarin (金帽福运) slot
//
// The eight regular symbols come from the sprite sheet in
// Resources/IMG_2264.png, cropped and matte-cleaned at runtime; the
// code-drawn illustrations (CoreGraphics / UIBezierPath on a 100x100
// design grid) remain as the fallback and still draw the Golden Hat
// scatter. Symbols render on a transparent background.

#import <UIKit/UIKit.h>
#import "BRGoldenMandarinEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface BRGoldenMandarinArt : NSObject

/// Cached, transparent-background illustration for a reel symbol.
+ (UIImage *)imageForSymbol:(GMSymbol)symbol size:(CGSize)size;

/// Short English name, e.g. "Paper Lantern".
+ (NSString *)nameForSymbol:(GMSymbol)symbol;

/// Face-down card for the hat shuffle bonus: red lacquer, gold border, 福.
+ (UIImage *)cardBackWithSize:(CGSize)size;

/// Drops cached images (call from didReceiveMemoryWarning).
+ (void)purgeCache;

@end

NS_ASSUME_NONNULL_END
