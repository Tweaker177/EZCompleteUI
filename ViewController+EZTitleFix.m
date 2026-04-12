#import "ViewController+EZTitleFix.h"

@implementation ViewController (EZTitleFix)

- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    if ([self respondsToSelector:@selector(ezcui_setTopTitle:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:@selector(ezcui_setTopTitle:) withObject:(title ?: @"")];
#pragma clang diagnostic pop
    }
}

@end
