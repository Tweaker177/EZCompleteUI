#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Slot-specific library entry point. It deliberately stays separate from the
/// Maze/Ricochet picker because a slot theme has eight symbol assets rather
/// than the maze's player/enemy/background trio.
@interface BRSlotGamePickerViewController : UIViewController

/// Lets the slot library return to the Brainrot mode picker instead of
/// dismissing the entire Brainrot experience.
@property (nonatomic, copy, nullable) dispatch_block_t onReturnToBrainRotMenu;
@end

NS_ASSUME_NONNULL_END
