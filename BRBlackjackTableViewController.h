// BRBlackjackTableViewController.h
// EZCompleteUI v2.0
//
// Purpose:
//   The live multiplayer blackjack table. Shows the dealer (avatar, speech
//   bubble and optional voice), every seated player, the player's bet / hit /
//   stand / double / split controls, a large coin balance with a payout
//   animation, and the shared table chat (BRSlotChatBar, room "bj:<tableID>").
//   All game logic runs on the server (br-blackjack); this screen polls for
//   state and draws it.
//
// Changes from v1.0:
//   - Split button and two-hand seats, dealer avatar/voice, bigger cards and
//     balance, payout animation. See the .m header for details.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BRBlackjackTableViewController : UIViewController

/// tableID is the server id (e.g. "bj-main"); name is shown until the first
/// state response arrives.
- (instancetype)initWithTableID:(NSString *)tableID tableName:(nullable NSString *)tableName;

@end

NS_ASSUME_NONNULL_END
