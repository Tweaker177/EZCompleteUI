#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when an inline code/document editor is unlocked or locked again.
/// The chat controller keeps its composer visible but inactive while editing.
FOUNDATION_EXPORT NSNotificationName const EZCodeBlockEditingStateDidChangeNotification;

@interface EZCodeBlockCell : UITableViewCell
- (void)configureWithCode:(NSString *)code
                 language:(NSString *)language
                savedPath:(nullable NSString *)savedPath
           viewController:(__weak UIViewController *)vc;
@end

NS_ASSUME_NONNULL_END
