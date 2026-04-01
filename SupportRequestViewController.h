// SupportRequestViewController.h
// EZCompleteUI v1.0
//
// Presents a support / feedback form.
// On send: composes an email to the address stored in EZKeyVault (EZVaultKeySupportEmail),
// attaches the current app settings snapshot and optionally the helpers debug log,
// then dismisses itself.
//
// The recipient address is stored only in EZKeyVault.m (kept off GitHub).
// No API key values are ever included in the email body.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SupportRequestViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
