#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One-time, account-scoped introduction displayed after a verified sign-in.
@interface EZFirstRunTutorialViewController : UIViewController
+ (BOOL)shouldShowTutorial;
@end

NS_ASSUME_NONNULL_END
