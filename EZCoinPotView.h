// EZCoinPotView.h
// EZCompleteUI
//
// A custom UIView that draws a leprechaun-style pot of gold.
// Fill level (0.0–1.0) reflects remaining coins as a fraction of plan's included coins.
// Animates coins flying in when coins are added, and gently shrinks fill when coins are used.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZCoinPotView : UIView

/// 0.0 = empty, 1.0 = completely full. Animates smoothly when changed.
@property (nonatomic, assign) CGFloat fillLevel;

/// Current coin balance (shown as number inside pot).
@property (nonatomic, assign) NSInteger coinBalance;

/// Coin image used for the flying coin animation.
@property (nonatomic, strong, nullable) UIImage *coinImage;

/// Update balance and fill level with animation.
/// includedCoins = number of coins the user's plan includes (used to calculate fill %).
- (void)updateBalance:(NSInteger)balance
        includedCoins:(NSInteger)includedCoins
             animated:(BOOL)animated;

/// Play the coin-toss animation — coins fly in and land in the pot.
/// coinsAdded = number of coins gained (affects how many coins animate).
/// completion called when animation finishes.
- (void)animateCoinToss:(NSInteger)coinsAdded
             completion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
