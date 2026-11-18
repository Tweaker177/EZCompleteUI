#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Phoenix Pavilion (凤凰阁): five reels, 25 paylines, golden-hat scatters
/// that open a three-card pick, and free spins with a x2 / x3 / x5 multiplier.
///
/// The client half of the `ez-phoenix-pavilion-spin` edge function (see
/// PhoenixPavilionServer/). The server owns every reel, payout, free-spin
/// award, the multiplier pick and all EZ Coins; this screen renders what it is
/// told. Symbols and sound are generated in code, so there are no asset files.
@interface BRPhoenixPavilionSlotViewController : UIViewController
/// VIP mode: extended bet ladder (to 50/line) and richer line pays.
@property (nonatomic) BOOL vipMode;
@end

NS_ASSUME_NONNULL_END
