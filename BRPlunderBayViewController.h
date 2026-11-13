#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Five-reel, twenty-line pirate machine (Plunder Bay) with
/// server-owned free spins, chest scatters and a ×3 bonus round.
@interface BRPlunderBayViewController : UIViewController
/// Bundled symbol art: a real plunder_<symbol> image when one is in
/// the bundle, otherwise the packaged .b64 copy decoded on first use.
+ (nullable UIImage *)plunderSymbolImage:(NSString *)symbol;
@end

NS_ASSUME_NONNULL_END
