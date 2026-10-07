#import <UIKit/UIKit.h>

/// Opt-in live lounge for a particular slot room. Messages and presence are
/// server-owned; no email address or account identifier is exposed to players.
@interface BRSlotRoomViewController : UIViewController
- (instancetype)initWithRoomID:(NSString *)roomID title:(NSString *)title;
@end
