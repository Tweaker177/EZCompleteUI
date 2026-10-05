#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Slot-specific library entry point. It deliberately stays separate from the
/// Maze/Ricochet picker because a slot theme has eight symbol assets rather
/// than the maze's player/enemy/background trio.
@interface BRSlotGamePickerViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
