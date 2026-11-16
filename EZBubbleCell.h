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
/// Play/pause button shown next to a chat-TTS bubble (nil-safe: hidden
/// unless the view controller marks the row as spoken). Set on every
/// configure pass, like the reaction badge. The tap block receives the
/// cell so the owner can resolve the row at tap time (reuse-safe).
@property (nonatomic, copy, nullable) void (^ttsButtonTapped)(EZBubbleCell *cell);
- (void)setTTSPlaybackVisible:(BOOL)visible playing:(BOOL)playing;
@end

NS_ASSUME_NONNULL_END
