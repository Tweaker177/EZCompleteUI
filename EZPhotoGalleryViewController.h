//
//  EZPhotoGalleryViewController.h
//  EZCompleteUI
//
//  Scrollable, pinch-to-zoom photo gallery that reads from /Documents/EZPhotoGallery.
//  Present modally from the bottom:
//
//      EZPhotoGalleryViewController *vc = [EZPhotoGalleryViewController new];
//      UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
//      nav.modalPresentationStyle = UIModalPresentationPageSheet;
//      if (@available(iOS 15, *)) {
//          UISheetPresentationController *sheet = nav.sheetPresentationController;
//          sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
//          sheet.prefersGrabberVisible = YES;
//      }
//      [self presentViewController:nav animated:YES completion:nil];
//
//  Notifications posted:
//    EZAttachImageToChat  — userInfo: @{ @"image": UIImage }  (Ask a Question button)
//    EZEditImageInChat    — userInfo: @{ @"image": UIImage }  (Edit button, opens edit mode)

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const EZAttachImageToChat;
extern NSNotificationName const EZEditImageInChat;

@interface EZPhotoGalleryViewController : UIViewController
@end

/// Reusable image detail/editor used by the gallery and image-backed memories.
/// It provides the Ask in Chat and Edit Image actions, plus the same sharing UI.
@interface EZPhotoDetailViewController : UIViewController
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, copy, nullable) NSString *imagePrompt;
@property (nonatomic, copy) NSArray<NSString *> *galleryFilePaths;
@property (nonatomic, assign) NSUInteger galleryIndex;
@property (nonatomic, copy, nullable) void (^onDeleted)(void);
@end

NS_ASSUME_NONNULL_END
