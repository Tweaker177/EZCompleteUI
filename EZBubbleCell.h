#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZBubbleCell : UITableViewCell <UIGestureRecognizerDelegate>
- (void)configureWithText:(NSString *)text isUser:(BOOL)isUser;
- (void)configureWithText:(NSString *)text
                   isUser:(BOOL)isUser
                timestamp:(nullable NSString *)timestamp
                  chatKey:(nullable NSString *)chatKey
                 threadID:(nullable NSString *)threadID;
/// Tapback-style reaction badge on the bubble (nil hides it). Set on
/// every configure pass so reused cells never keep a stale reaction.
- (void)setReactionEmoji:(nullable NSString *)emoji;
@end

NS_ASSUME_NONNULL_END
