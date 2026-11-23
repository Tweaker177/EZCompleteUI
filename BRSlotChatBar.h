#import <UIKit/UIKit.h>

/// Posted whenever a chat bar learns a new own-profile (room state, a
/// profile fetch, or a successful save). Surfaces that show the player's
/// own avatar — the game picker's profile button — observe it and refresh
/// from the posting bar's profileAvatarURL.
extern NSNotificationName const BRSlotProfileDidUpdateNotification;

/// Posted when the shared slot sound setting changes (see below).
extern NSNotificationName const BRSlotSoundSettingChangedNotification;

/// The one sound on/off setting for the whole slot family: the game
/// picker's casino ambience and every machine's sounds (reels, wins,
/// bonus music). Stored in NSUserDefaults and ON by default. Every
/// audio owner checks BRSlotSoundEnabled() at its play points and
/// observes BRSlotSoundSettingChangedNotification to stop live
/// playback the moment the setting flips off.
BOOL BRSlotSoundEnabled(void);
void BRSlotSetSoundEnabled(BOOL enabled);

/// In-machine lounge chat bar. Pinned to the bottom of a slot screen it
/// shows one line — the newest lounge message — and keeps updating while
/// the player plays. Tapping the line expands it into the full lounge
/// conversation (scrollable history, composer, profile, winners board)
/// for the same server room the old separate lounge screen used.
@interface BRSlotChatBar : UIView

/// The view controller that presents sheets (profile, photo picker,
/// winners board) on the bar's behalf — the slot screen hosting the bar.
@property (nonatomic, weak) UIViewController *hostViewController;

/// The signed URL of the player's own lounge avatar, once any profile
/// payload has provided it; nil while the player has no photo.
@property (nonatomic, copy, readonly) NSString *profileAvatarURL;
/// The signed-in player's lifetime VIP points (from the profile
/// response), for VIP unlock displays like the slot picker.
@property (nonatomic, readonly) NSInteger profileVipPoints;

/// Loads an avatar photo and hands back a thumbnail decoded at the
/// display size (a square-cover render at points × screen scale), cached
/// per URL + size. Avatars are shown at 34–76pt; the full 512px upload
/// never needs to live in memory per row. Completion runs on the main
/// queue with nil on any failure.
+ (void)loadAvatarThumbnailForURL:(NSString *)urlString points:(CGFloat)points completion:(void (^)(UIImage *image))completion;

/// Fetches the player's own lounge profile (no room needed) and updates
/// profileName / profileAvatarURL, posting
/// BRSlotProfileDidUpdateNotification when the avatar changes. Works on a
/// bar that was never attached or started.
- (void)fetchOwnProfile;

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

/// Full-screen big-win celebration — fireworks, a coin volcano, and a
/// BIG WIN / MEGA WIN banner — shared by every slot machine.
@interface BRSlotCelebration : NSObject

/// Fires the celebration inside hostView when the payout is at least
/// 25x the total bet (MEGA WIN at 75x+). Returns YES when it fired.
+ (BOOL)celebrateBigWinInView:(UIView *)hostView payout:(NSInteger)payout totalBet:(NSInteger)totalBet;

@end

/// Shared slot chrome: one button treatment and one win banner for every
/// slot machine, so the cabinets all wear the same metal.
@interface BRSlotChrome : NSObject

/// Height of the standard win banner (Penny / Plunder size).
+ (CGFloat)winBannerHeight;
/// Height of the large win banner (big-win celebration size).
+ (CGFloat)winBannerHeightLarge;

/// A win banner with a sun-ray burst edge, a deep gradient card, a gold
/// title and a white subtitle. userInteractionEnabled is NO; set the
/// frame's origin after creating it.
+ (UIView *)winBannerWithTitle:(NSString *)title subtitle:(NSString *)subtitle width:(CGFloat)width large:(BOOL)large;

/// Gives a plain button the shared pressable treatment: a vertical
/// gradient rendered from baseColor (gloss at the top, deeper shade at
/// the bottom, darker still when highlighted), a gold bevel border and
/// a drop shadow. Standardizes the corner radius to 13.
+ (void)applyToButton:(UIButton *)button baseColor:(UIColor *)baseColor;

@end
