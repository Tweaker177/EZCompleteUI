//
//  EZCoinLedgerViewController.h
//  EZCompleteUI
//
//  Displays the full ez_usage_log for the current user with a running balance,
//  cost-per-100-coins efficiency metric, and aggregate summary header.
//
//  Present modally:
//      EZCoinLedgerViewController *vc = [EZCoinLedgerViewController new];
//      UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
//      nav.modalPresentationStyle = UIModalPresentationPageSheet;
//      [self presentViewController:nav animated:YES completion:nil];

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZCoinLedgerViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
