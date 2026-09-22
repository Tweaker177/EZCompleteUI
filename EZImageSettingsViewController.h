//
//  EZImageSettingsViewController.h
//  EZCompleteUI
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZImageSettingsViewController : UITableViewController
/// Optional image model context. Lets gallery editing expose the exact
/// capabilities of its editing model without changing the chat selection.
@property (nonatomic, copy, nullable) NSString *modelIdentifier;

@end

NS_ASSUME_NONNULL_END
