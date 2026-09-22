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
/// Invoked for the compact navigation choices shown above Recent Chats.
@property (nonatomic, copy, nullable) void (^navigationActionHandler)(NSString *action);
/// Lets this controller work inside the main screen's slide-out drawer.
@property (nonatomic, copy, nullable) dispatch_block_t closeHandler;
@end

NS_ASSUME_NONNULL_END
