#import "UIViewController+EZViewDidLayoutSwizzle.h"
#import <objc/runtime.h>
#import <objc/message.h>



/// Single TU-local key for associated object storage used in this file.
/// If other files also need this same key, move this to a shared header as `extern` and define once.
 const void *kTopContainerKey = &kTopContainerKey;

static UITableView *EZFindFirstTableView(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UITableView class]]) {
        return (UITableView *)root;
    }
    for (UIView *sub in root.subviews) {
        UITableView *found = EZFindFirstTableView(sub);
        if (found) return found;
    }
    return nil;
}

@implementation UIViewController (EZViewDidLayoutSwizzle)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [self class];
        SEL originalSEL = @selector(viewDidLayoutSubviews);
        SEL swizzledSEL = @selector(ez_viewDidLayoutSubviews);

        Method originalMethod = class_getInstanceMethod(cls, originalSEL);
        Method swizzledMethod = class_getInstanceMethod(cls, swizzledSEL);

        if (originalMethod && swizzledMethod) {
            method_exchangeImplementations(originalMethod, swizzledMethod);
        }
    });
}

- (void)ez_viewDidLayoutSubviews {
    // Call the original implementation (swizzled)
    [self ez_viewDidLayoutSubviews];

    // Retrieve the associated header view (if any)
    UIView *header = objc_getAssociatedObject(self, kTopContainerKey);
    if (!header) {
        return;
    }

    // Try to obtain the table view this header belongs to:
    // 1) If this VC implements -chatTableView, use it.
    // 2) Otherwise, find the first UITableView in the view hierarchy.
    UITableView *tableView = nil;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if ([self respondsToSelector:@selector(chatTableView)]) {
        tableView = [self performSelector:@selector(chatTableView)];
    }
#pragma clang diagnostic pop

    if (!tableView) {
        tableView = EZFindFirstTableView(self.view);
    }
    if (!tableView) {
        return;
    }

    if (tableView.tableHeaderView == header) {
        CGFloat targetW = CGRectGetWidth(tableView.bounds);

        // Ask Auto Layout for the fitting size
        CGSize fitting = [header systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
        CGFloat targetH = ceil(fitting.height);

        BOOL needsUpdate =
            fabs(CGRectGetWidth(header.bounds) - targetW) > 0.5 ||
            fabs(CGRectGetHeight(header.bounds) - targetH) > 0.5;

        if (needsUpdate) {
            CGRect f = header.frame;
            f.size.width = targetW;
            f.size.height = targetH;
            header.frame = f;

            // Re-assign to force the table to re-measure header
            tableView.tableHeaderView = header;
        }
    }
}

@end
