#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface UIViewController (EZViewDidLayoutSwizzle)
+ (void)load;
- (void)ez_viewDidLayoutSubviews_swizzled;
@end
