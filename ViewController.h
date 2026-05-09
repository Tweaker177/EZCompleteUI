#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
@interface ViewController : UIViewController
//@property (nonatomic, strong) UIView *inputContainer;
@property (nonatomic, strong) UITextView *messageTextView;
@property (nonatomic, strong) UITableView   *chatTableView;
@property (nonatomic, strong) UILabel       *threadTitleLabel;
@property (nonatomic, strong) NSLayoutConstraint *inputHeightConstraint;
//@property (nonatomic, strong) UIButton *sendButton;
@end


    // Forward declare private methods defined in ViewController.m
    @interface ViewController (EZPrivateMethods)
    - (void)appendToChat:(NSString *)text;
    - (NSString *)processReplyWithCodeBlocks:(NSString *)reply
                                  savedPaths:(NSMutableArray<NSString *> *)savedPaths;
    - (NSString *)processReplyWithCodeBlocks:(NSString *)reply
                                  savedPaths:(NSMutableArray<NSString *> *)savedPaths
                                   isRestore:(BOOL)isRestore;
    @end
