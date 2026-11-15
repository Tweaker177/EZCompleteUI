#import <UIKit/UIKit.h>

/// In-machine lounge chat bar. Pinned to the bottom of a slot screen it
/// shows one line — the newest lounge message — and keeps updating while
/// the player plays. Tapping the line expands it into the full lounge
/// conversation (scrollable history, composer, profile, winners board)
/// for the same server room the old separate lounge screen used.
@interface BRSlotChatBar : UIView

/// The view controller that presents sheets (profile, photo picker,
/// winners board) on the bar's behalf — the slot screen hosting the bar.
@property (nonatomic, weak) UIViewController *hostViewController;

- (instancetype)initWithRoomID:(NSString *)roomID;

/// Pins the bar to the bottom of the given view (leading / trailing /
/// safe-area bottom) at its collapsed one-line height.
- (void)attachToView:(UIView *)view;

/// Starts polling the room and asking for live-host turns. Call when the
/// hosting screen appears.
- (void)start;

/// Stops polling. Call when the hosting screen is popped or dismissed.
- (void)stop;

/// Presents the daily winners board on the host view controller (the
/// expanded lounge's old Wins button, now on the game picker). Works on
/// a bar that was never attached or started.
- (void)showWinnersBoard;

/// Presents the lounge profile editor on the host view controller (the
/// expanded lounge's old profile button, now on the game picker),
/// loading the saved profile first if this bar has not seen it yet.
- (void)showProfileEditor;

@end
