// HelperLogViewController.h
// EZCompleteUI
//
// Displays the full ezui_helpers.log in a card-based table view.
// Features: inline QL thumbnail previews for file/image paths, tappable
// chatKey deep-links that open the referenced thread via EZOpenChatThread,
// live search/filter, and a share + clear action.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HelperLogViewController : UIViewController

/// Optional: set before presentation if the VC is managed by a parent
/// (mirrors the same pattern used in MemoriesViewController).
@property (nonatomic, copy, nullable) void (^closeRequestHandler)(void (^ _Nullable completion)(void));

@end

NS_ASSUME_NONNULL_END
