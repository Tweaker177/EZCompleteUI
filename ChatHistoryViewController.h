// ChatHistoryViewController.h
// EZCompleteUI

#import <UIKit/UIKit.h>
#import "helpers.h"

NS_ASSUME_NONNULL_BEGIN

@protocol ChatHistoryViewControllerDelegate <NSObject>
- (void)chatHistoryDidSelectThread:(EZChatThread *)thread;
@end

@interface ChatHistoryViewController : UITableViewController
@property (nonatomic, weak, nullable) id<ChatHistoryViewControllerDelegate> delegate;
@end

NS_ASSUME_NONNULL_END
