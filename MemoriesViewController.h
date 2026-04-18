// MemoriesViewController.h
// EZCompleteUI
//
// Displays, edits, and deletes saved AI memory entries from ezui_memories.json.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MemoriesViewController : UIViewController
@property (nonatomic, copy, nullable) void (^closeRequestHandler)(dispatch_block_t completion);

@end

NS_ASSUME_NONNULL_END
