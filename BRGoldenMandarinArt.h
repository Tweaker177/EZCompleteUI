// BRGoldenMandarinArt.h
// EZCompleteUI — Golden Mandarin (金帽福运) slot
//
// The eight regular symbols are sliced tiles from the user's
// white-background sprite sheet, keyed to transparency and shipped
// as .b64 PNGs decoded at runtime; the code-drawn illustrations
// (CoreGraphics / UIBezierPath on a 100x100 design grid) remain as
// the fallback and still draw the Golden Hat scatter. Symbols
// render on a transparent background.

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
