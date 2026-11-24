//
//  EZImageGridCell.h
//  EZCompleteUI
//
//  Inline image result cell for the chat table view.
//  Handles 1, 2, or 4 images (n-variations) in a polished dark grid layout.
//  Used for gpt-image-1, dall-e-3, and image edit results.
//
//  Display message dict keys (role = "imagegrid"):
//    imagePaths  — NSArray<NSString *>  local EZAttachments file paths
//    prompt      — NSString             the generation/edit prompt
//    isError     — NSNumber (BOOL)      YES = show error state
//    errorText   — NSString             error message shown in error state
//
//  Attachment preview dict keys (role = "attachment"):
//    imagePath   — NSString             path shown as user attachment bubble

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// ── Image grid cell ───────────────────────────────────────────────────────────

@interface EZImageGridCell : UITableViewCell

/// Returns the row height for a given image count and table width.
/// Call this from tableView:heightForRowAtIndexPath: to avoid auto-dimension cost.
+ (CGFloat)heightForImageCount:(NSInteger)count
                    tableWidth:(CGFloat)width
                       isError:(BOOL)isError;

- (void)configureWithImagePaths:(NSArray<NSString *> *)paths
                         prompt:(NSString *)prompt
                        isError:(BOOL)isError
                      errorText:(nullable NSString *)errorText
           presentingController:(UIViewController *)vc;

/// Thread multiselect mode: when YES, tapping an image does not open it
/// fullscreen; the tap is handed to imageTapWhileSelecting instead, so a
/// tap aimed at the selection dot selects the message rather than
/// expanding the image.
@property (nonatomic, assign) BOOL selectionMode;
@property (nonatomic, copy, nullable) void (^imageTapWhileSelecting)(void);

@end

// ── Attachment preview cell ───────────────────────────────────────────────────

@interface EZAttachmentPreviewCell : UITableViewCell

+ (CGFloat)heightForTableWidth:(CGFloat)width;

- (void)configureWithImagePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
