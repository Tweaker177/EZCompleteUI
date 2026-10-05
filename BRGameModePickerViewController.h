#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BRGameModePickerViewController : UIViewController
@property (nonatomic, copy, nullable) dispatch_block_t onMazeSelected;
@property (nonatomic, copy, nullable) dispatch_block_t onRicochetSelected;
@property (nonatomic, copy, nullable) dispatch_block_t onSlotsSelected;
@end

NS_ASSUME_NONNULL_END
