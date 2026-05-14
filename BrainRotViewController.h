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

@end

NS_ASSUME_NONNULL_END