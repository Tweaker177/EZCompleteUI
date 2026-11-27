// BRRouletteTableViewController.h
// EZCompleteUI v1.0
//
// Purpose:
//   The live multiplayer roulette table (European, single zero). Shows the
//   spinning wheel and ball, the last numbers, a real-table betting board
//   (zero, 1-36 in three columns, dozens, columns and the even-money bets),
//   a chip selector, the player's large coin balance, the other seated
//   players and the shared table chat (BRSlotChatBar, room "rl:<tableID>").
//   Every rule, draw, debit and payout runs on the server (br-roulette); this
//   screen only sends the player's intent and draws what the server answers.
//
// Changes from v0 (new file):
//   - Initial version.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BRRouletteTableViewController : UIViewController

/// tableID is the server id (e.g. "rl-main"); name is shown until the first
/// state response arrives.
- (instancetype)initWithTableID:(NSString *)tableID tableName:(nullable NSString *)tableName;

@end

NS_ASSUME_NONNULL_END
