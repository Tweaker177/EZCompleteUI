//
//  EZCoinUsageViewController.h
//  EZCompleteUI
//
//  User-facing coin usage log. Shows where coins went in plain language.
//  No cost data, no API details — just what the user needs to understand
//  their balance and to support a chargeback dispute if needed.
//
//  Present from the coin store or settings:
//      EZCoinUsageViewController *vc = [EZCoinUsageViewController new];
//      UINavigationController *nav = [[UINavigationController alloc]
//          initWithRootViewController:vc];
//      nav.modalPresentationStyle = UIModalPresentationPageSheet;
//      [self presentViewController:nav animated:YES completion:nil];

#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN

@interface EZCoinUsageViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
