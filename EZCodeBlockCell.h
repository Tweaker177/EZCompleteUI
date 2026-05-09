#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZCodeBlockCell : UITableViewCell
- (void)configureWithCode:(NSString *)code
                 language:(NSString *)language
                savedPath:(nullable NSString *)savedPath
           viewController:(__weak UIViewController *)vc;
@end

NS_ASSUME_NONNULL_END
