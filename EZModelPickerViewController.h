//
//  EZModelPickerViewController.h
//  EZCompleteUI
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZModelPickerViewController : UITableViewController

@property (nonatomic, copy) NSArray<NSString *> *models;
@property (nonatomic, copy) NSString            *selectedModel;
@property (nonatomic, copy, nullable) void (^onModelSelected)(NSString *model);
/// Auto mode: when on, chat sends ask the server to pick the model.
/// Picking a specific model turns it off (selectModel does this).
@property (nonatomic) BOOL autoEnabled;
@property (nonatomic, copy, nullable) void (^onAutoToggled)(BOOL enabled);

- (instancetype)initWithModels:(NSArray<NSString *> *)models selectedModel:(NSString *)selected;

@end

NS_ASSUME_NONNULL_END
