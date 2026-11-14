#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Golden Mandarin (金帽福运): five reels, nine paylines, golden-hat scatters
/// that open a three-card pick, and free spins with a x2 / x3 / x5 multiplier.
///
/// The client half of the `ez-golden-mandarin-spin` edge function (see
/// GoldenMandarinServer/). The server owns every reel, payout, free-spin
/// award, the multiplier pick and all EZ Coins; this screen renders what it is
/// told. Symbols and sound are generated in code, so there are no asset files.
@interface BRGoldenMandarinSlotViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
