// iCarouselCompat.h
// Shim to satisfy older iCarousel forks that reference
// UILongPressGestureRecognizerDelegate (which doesn’t exist in UIKit).

#import <UIKit/UIKit.h>

#ifndef UILongPressGestureRecognizerDelegate
@protocol UILongPressGestureRecognizerDelegate <UIGestureRecognizerDelegate>
@end
#endif