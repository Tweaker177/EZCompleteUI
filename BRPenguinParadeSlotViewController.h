#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Penguin Parade: five reels, nine paylines, golden-egg scatters
/// that open a three-penguin egg-hatch pick, and free spins with a x2 / x3 / x5 multiplier.
///
/// The client half of the `ez-penguin-parade-spin` edge function (see
/// PenguinParadeServer/). The server owns every reel, payout, free-spin
/// award, the multiplier pick and all EZ Coins; this screen renders what it is
/// told. Symbols and sound are generated in code, so there are no asset files.
@interface BRPenguinParadeSlotViewController : UIViewController
/// VIP mode: extended bet ladder (to 125/line) and server-scaled line pays.
/// The server re-checks the 50,000-point gate on every spin.
@property (nonatomic) BOOL vipMode;
@end

NS_ASSUME_NONNULL_END
