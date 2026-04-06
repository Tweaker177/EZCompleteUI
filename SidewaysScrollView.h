//
//  SidewaysScrollView.h
//  EZCompleteUI
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SidewaysScrollView : UIView

/// Configure with prototype buttons. Their titles, images, colors, fonts,
/// and target-actions are copied to rendered items.
/// If doubleSize=YES, buttons are drawn at 2× the container’s height (centered vertically).
- (void)configureWithButtons:(NSArray<UIButton *> *)buttons doubleSize:(BOOL)doubleSize;

/// Optional spacing between buttons (default 12)
@property (nonatomic, assign) CGFloat interItemSpacing;

@end

NS_ASSUME_NONNULL_END