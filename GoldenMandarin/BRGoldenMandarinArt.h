// BRGoldenMandarinArt.h
// EZCompleteUI — Golden Mandarin (金帽福运) slot
//
// Every symbol is illustrated in code (CoreGraphics / UIBezierPath) on a 100x100
// design grid, so the art stays sharp at any size and ships without image
// files. Symbols are drawn on a transparent background.

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
