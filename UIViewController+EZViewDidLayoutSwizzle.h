#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern const void *kTopContainerKey;

@interface UIViewController (EZViewDidLayoutSwizzle)
//+ (void)load;
//- (void)ez_viewDidLayoutSubviews_swizzled;
@end
