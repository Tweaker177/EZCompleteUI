//
//  EZAttachMenuViewController.h
//  EZCompleteUI
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^EZAttachAction)(void);

@interface EZAttachMenuViewController : UITableViewController

@property (nonatomic, copy, nullable) EZAttachAction onWhisper;
@property (nonatomic, copy, nullable) EZAttachAction onAnalyze;
@property (nonatomic, copy, nullable) EZAttachAction onImageFiles;
@property (nonatomic, copy, nullable) EZAttachAction onPhotoLibrary;

@end

NS_ASSUME_NONNULL_END
