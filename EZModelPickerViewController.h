#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZModelPickerViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSString *> *models;
@property (nonatomic, copy) NSString *selectedModel;
@property (nonatomic, copy, nullable) void (^onModelSelected)(NSString *model);
- (instancetype)initWithModels:(NSArray<NSString *> *)models selectedModel:(NSString *)selected;
@end

NS_ASSUME_NONNULL_END
