// BRBlackjackTableViewController.h
// EZCompleteUI v1.0
//
// Purpose:
//   The live multiplayer blackjack table. Shows the dealer, every seated
//   player, the player's bet / hit / stand / double controls and the shared
//   table chat (BRSlotChatBar, room "bj:<tableID>"). All game logic runs on
//   the server (br-blackjack); this screen polls for state and draws it.
//
// Changes from v0 (new file):
//   - Initial version.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BRBlackjackTableViewController : UIViewController

/// tableID is the server id (e.g. "bj-main"); name is shown until the first
/// state response arrives.
- (instancetype)initWithTableID:(NSString *)tableID tableName:(nullable NSString *)tableName;

@end

NS_ASSUME_NONNULL_END
