// EZGitHubSettingsViewController.h
// EZCompleteUI v1.0
//
// Purpose:
//   The screen where the user connects GitHub so chat models can read their
//   repositories (and, if the user allows it, propose changes). The token is
//   pasted here once, verified and stored encrypted by the ez-github Edge
//   Function, and never shown again. Present it inside a navigation controller.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZGitHubSettingsViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
