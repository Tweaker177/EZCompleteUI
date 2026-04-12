#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZBubbleCell : UITableViewCell <UIGestureRecognizerDelegate>
- (void)configureWithText:(NSString *)text isUser:(BOOL)isUser;
- (void)configureWithText:(NSString *)text
                   isUser:(BOOL)isUser
                timestamp:(nullable NSString *)timestamp
                  chatKey:(nullable NSString *)chatKey
                 threadID:(nullable NSString *)threadID;
@end

NS_ASSUME_NONNULL_END
