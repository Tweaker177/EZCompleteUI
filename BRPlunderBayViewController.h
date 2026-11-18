#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Five-reel, twenty-line pirate machine (Plunder Bay) with
/// server-owned free spins, chest scatters and a ×3 bonus round.
@interface BRPlunderBayViewController : UIViewController
/// Bundled symbol art: a real plunder_<symbol> image when one is in
/// the bundle, otherwise the packaged .b64 copy decoded on first use.
+ (nullable UIImage *)plunderSymbolImage:(NSString *)symbol;
/// VIP mode (Silver and up, 50,000+ VIP points): the same machine with
/// a higher bet ladder (to 500) and richer line pays, both enforced
/// server-side. Set before pushing; defaults to NO.
@property (nonatomic) BOOL vipMode;
@end

NS_ASSUME_NONNULL_END
