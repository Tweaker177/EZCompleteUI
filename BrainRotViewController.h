//
//  BrainRotViewController.h
//  BrainRotGame
//
//  Created by AI on 2026-05-14.
//  This view controller runs the entire game inside itself.
//  NOTE: This code assumes the existence of an app-global helper method:
//        - (NSString *)callChatModel:(NSString *)model withPrompt:(NSString *)prompt
//        which returns a string response from an LLM (synchronously).
//        If your integration uses an async/callback style, adapt the call accordingly.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrainRotViewController : UIViewController

/// A gallery image to hand into the Custom Workshop when this controller is
/// opened from EZ Attachments. Leave nil for the normal game-library flow.
@property (nonatomic, strong, nullable) UIImage *initialWorkshopImage;

/// Called by the in-game Back control to return to the Brainrot mode picker.
@property (nonatomic, copy, nullable) dispatch_block_t onReturnToBrainRotMenu;

@end

NS_ASSUME_NONNULL_END
