//
//  EZPhotoGalleryViewController.m
//  EZCompleteUI
//
//  Dark, polished photo gallery. Reads images from /Documents/EZPhotoGallery.
//  Pinch gesture cycles the grid between 2 – 5 columns.
//  Tap → full-screen detail sheet with action buttons.

#import "EZPhotoGalleryViewController.h"
#import "BrainRotViewController.h"
#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZImageSettingsViewController.h"
#import "EZSupabaseConfig.h"
#import "ViewController+EZKeepAwake.h"
#import "helpers.h"
#import <SafariServices/SafariServices.h>
#import <QuartzCore/QuartzCore.h>
#import <PhotosUI/PhotosUI.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CommonCrypto/CommonDigest.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

// ── Notification names ────────────────────────────────────────────────────────

NSNotificationName const EZAttachImageToChat = @"EZAttachImageToChat";
NSNotificationName const EZEditImageInChat   = @"EZEditImageInChat";

// ── Constants ─────────────────────────────────────────────────────────────────

static NSString *const kGalleryCellID   = @"EZGalleryCell";
static NSString *const kPhotoGalleryDir = @"EZPhotoGallery";
static NSString *const kLegacyAttachmentsDir = @"EZAttachments";
static CGFloat   const kCellSpacing     = 3.0;
static NSInteger const kMinColumns      = 2;
static NSInteger const kMaxColumns      = 5;
static NSInteger const kDefaultColumns  = 3;
static NSString *const kGalleryImagePromptsKey = @"EZGalleryImagePrompts";
static NSUInteger const kMaxImageEditSources = 4;

static NSString *EZGalleryContentDigest(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

typedef NS_ENUM(NSInteger, EZShareGIFStyle) {
    EZShareGIFStyleOriginalReveal = 0,
    EZShareGIFStyleMotionTransition,
};

// Supplying a naked file URL lets some activity extensions infer a static
// image from its first frame. This item source explicitly advertises animated
// GIF data so Messages, Mail, Files, and share extensions preserve the loop.
@interface EZGIFActivityItemSource : NSObject <UIActivityItemSource>
@property (nonatomic, strong) NSData *gifData;
- (instancetype)initWithGIFData:(NSData *)gifData;
@end

@implementation EZGIFActivityItemSource
- (instancetype)initWithGIFData:(NSData *)gifData {
    self = [super init];
    if (self) _gifData = gifData;
    return self;
}
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)activityViewController {
    return _gifData ?: [NSData data];
}
- (id)activityViewController:(UIActivityViewController *)activityViewController
 itemForActivityType:(UIActivityType)activityType {
    return _gifData;
}
- (NSString *)activityViewController:(UIActivityViewController *)activityViewController
 dataTypeIdentifierForActivityType:(UIActivityType)activityType {
    return @"com.compuserve.gif";
}
- (NSString *)activityViewController:(UIActivityViewController *)activityViewController
 attachmentNameForActivityType:(UIActivityType)activityType {
    return @"EZCompleteUI-animation.gif";
}
- (NSString *)activityViewController:(UIActivityViewController *)activityViewController
             subjectForActivityType:(UIActivityType)activityType {
    return @"EZCompleteUI";
}
@end

static CGRect EZAspectFillRect(CGSize imageSize, CGRect bounds) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return bounds;
    CGFloat scale = MAX(bounds.size.width / imageSize.width, bounds.size.height / imageSize.height);
    CGSize size = CGSizeMake(imageSize.width * scale, imageSize.height * scale);
    return CGRectMake(CGRectGetMidX(bounds) - size.width / 2.0,
                      CGRectGetMidY(bounds) - size.height / 2.0, size.width, size.height);
}

static CGRect EZAspectFitRect(CGSize imageSize, CGRect bounds) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return bounds;
    CGFloat scale = MIN(bounds.size.width / imageSize.width, bounds.size.height / imageSize.height);
    CGSize size = CGSizeMake(imageSize.width * scale, imageSize.height * scale);
    return CGRectMake(CGRectGetMidX(bounds) - size.width / 2.0,
                      CGRectGetMidY(bounds) - size.height / 2.0,
                      size.width, size.height);
}

// Shared by the gallery + button and the detail editor's reference-image +.
// This intentionally mirrors the coin-store upsell card rather than falling
// back to a plain system action sheet.
static void EZPresentPhotoSourcePicker(UIViewController *presenter,
                                       void (^openPhotos)(void),
                                       void (^openFiles)(void),
                                       void (^openGallery)(void)) {
    UIView *overlay = [[UIView alloc] initWithFrame:presenter.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    overlay.alpha = 0;
    [presenter.view addSubview:overlay];

    CGFloat cardWidth = MIN(340.0, presenter.view.bounds.size.width - 36.0);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardWidth, openGallery ? 435.0 : 354.0)];
    card.center = CGPointMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds));
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    card.backgroundColor = [UIColor colorWithRed:0.055 green:0.06 blue:0.13 alpha:1.0];
    card.layer.cornerRadius = 24.0;
    card.layer.borderWidth = 1.5;
    card.layer.borderColor = [[UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:0.65] CGColor];
    card.transform = CGAffineTransformMakeScale(0.82, 0.82);
    [overlay addSubview:card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 25, cardWidth - 40, 30)];
    title.text = @"Add to Photo Gallery";
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    title.textColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    [card addSubview:title];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(24, 58, cardWidth - 48, 38)];
    subtitle.text = @"Choose a source for photos and image references.";
    subtitle.numberOfLines = 2;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    subtitle.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    [card addSubview:subtitle];

    void (^dismissThen)(void (^)(void)) = ^(void (^completion)(void)) {
        [UIView animateWithDuration:0.20 animations:^{
            overlay.alpha = 0;
            card.transform = CGAffineTransformMakeScale(0.90, 0.90);
        } completion:^(BOOL finished) {
            [overlay removeFromSuperview];
            if (completion) completion();
        }];
    };
    void (^addSourceButton)(NSString *, NSString *, NSString *, UIColor *, CGFloat, void (^)(void)) =
    ^(NSString *titleText, NSString *detailText, NSString *symbol, UIColor *accent, CGFloat y, void (^handler)(void)) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(22, y, cardWidth - 44, 72);
        button.backgroundColor = [accent colorWithAlphaComponent:0.16];
        button.layer.cornerRadius = 16.0;
        button.layer.borderWidth = 1.0;
        button.layer.borderColor = [accent colorWithAlphaComponent:0.48].CGColor;
        button.tintColor = accent;
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:23 weight:UIImageSymbolWeightSemibold];
        [button setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.contentEdgeInsets = UIEdgeInsetsMake(0, 18, 0, 0);
        [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            dismissThen(handler);
        }] forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:button];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(64, 12, button.bounds.size.width - 80, 24)];
        label.text = titleText;
        label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
        label.textColor = [UIColor whiteColor];
        label.userInteractionEnabled = NO;
        [button addSubview:label];
        UILabel *detail = [[UILabel alloc] initWithFrame:CGRectMake(64, 37, button.bounds.size.width - 80, 20)];
        detail.text = detailText;
        detail.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        detail.textColor = [UIColor colorWithWhite:0.70 alpha:1.0];
        detail.userInteractionEnabled = NO;
        [button addSubview:detail];
    };
    addSourceButton(@"Photo Library", @"Photos, albums, and recent captures", @"photo.on.rectangle.angled",
                    [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0], 112.0, openPhotos);
    addSourceButton(@"Files & Cloud Providers", @"Files, Dropbox, Google Drive, Box, and more", @"folder.fill",
                    [UIColor colorWithRed:0.47 green:0.52 blue:1.0 alpha:1.0], 193.0, openFiles);
    if (openGallery) {
        addSourceButton(@"Open from Gallery", @"Use a saved image without importing it again", @"photo.stack",
                        [UIColor systemPurpleColor], 274.0, openGallery);
    }

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(40, openGallery ? 363.0 : 282.0, cardWidth - 80, 42);
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    [cancel setTitleColor:[UIColor colorWithWhite:0.75 alpha:1.0] forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [cancel addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        dismissThen(nil);
    }] forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancel];

    [UIView animateWithDuration:0.36 delay:0 usingSpringWithDamping:0.76 initialSpringVelocity:0.45
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        overlay.alpha = 1;
        card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

static void EZPresentPhotoExportPicker(UIViewController *presenter, BOOL hasEdit,
                                       void (^revealGIF)(void), void (^motionGIF)(void),
                                       void (^shareWithOriginal)(void), void (^shareClean)(void),
                                       void (^download)(void)) {
    UIView *overlay = [[UIView alloc] initWithFrame:presenter.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    overlay.alpha = 0;
    [presenter.view addSubview:overlay];

    NSArray<NSDictionary *> *options = hasEdit ? @[
        @{@"title": NSLocalizedString(@"EZGallery.Export.GIFReveal", nil), @"icon": @"rectangle.inset.filled.and.person.filled", @"color": [UIColor systemPurpleColor], @"action": revealGIF ?: ^{}},
        @{@"title": NSLocalizedString(@"EZGallery.Export.GIFMotion", nil), @"icon": @"sparkles.rectangle.stack", @"color": [UIColor systemIndigoColor], @"action": motionGIF ?: ^{}},
        @{@"title": NSLocalizedString(@"EZGallery.Export.ShareOriginal", nil), @"icon": @"rectangle.inset.filled", @"color": [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0], @"action": shareWithOriginal ?: ^{}},
        @{@"title": NSLocalizedString(@"EZGallery.Export.ShareClean", nil), @"icon": @"square.and.arrow.up", @"color": [UIColor systemTealColor], @"action": shareClean ?: ^{}},
        @{@"title": NSLocalizedString(@"EZGallery.Export.Download", nil), @"icon": @"arrow.down.to.line", @"color": [UIColor systemOrangeColor], @"action": download ?: ^{}},
    ] : @[
        @{@"title": NSLocalizedString(@"EZGallery.Export.ShareClean", nil), @"icon": @"square.and.arrow.up", @"color": [UIColor systemTealColor], @"action": shareClean ?: ^{}},
        @{@"title": NSLocalizedString(@"EZGallery.Export.Download", nil), @"icon": @"arrow.down.to.line", @"color": [UIColor systemOrangeColor], @"action": download ?: ^{}},
    ];
    CGFloat cardWidth = MIN(350.0, presenter.view.bounds.size.width - 36.0);
    CGFloat cardHeight = 129.0 + options.count * 51.0;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardWidth, cardHeight)];
    card.center = CGPointMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds));
    card.backgroundColor = [UIColor colorWithRed:0.055 green:0.06 blue:0.13 alpha:1.0];
    card.layer.cornerRadius = 24.0;
    card.layer.borderWidth = 1.5;
    card.layer.borderColor = [[UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:0.65] CGColor];
    card.transform = CGAffineTransformMakeScale(0.82, 0.82);
    [overlay addSubview:card];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 22, cardWidth - 40, 28)];
    title.text = NSLocalizedString(@"EZGallery.Export.Title", nil);
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    [card addSubview:title];
    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(24, 51, cardWidth - 48, 22)];
    subtitle.text = NSLocalizedString(@"EZGallery.Export.Subtitle", nil);
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    subtitle.textColor = [UIColor colorWithWhite:0.70 alpha:1.0];
    [card addSubview:subtitle];
    void (^dismissThen)(void (^)(void)) = ^(void (^completion)(void)) {
        [UIView animateWithDuration:0.20 animations:^{ overlay.alpha = 0; card.transform = CGAffineTransformMakeScale(0.90, 0.90); }
                         completion:^(BOOL finished) { [overlay removeFromSuperview]; if (completion) completion(); }];
    };
    CGFloat y = 83.0;
    for (NSDictionary *option in options) {
        UIColor *color = option[@"color"];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(20, y, cardWidth - 40, 43);
        button.backgroundColor = [color colorWithAlphaComponent:0.16];
        button.layer.cornerRadius = 13.0;
        button.layer.borderWidth = 1.0;
        button.layer.borderColor = [color colorWithAlphaComponent:0.45].CGColor;
        button.tintColor = color;
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        button.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 0);
        [button setImage:[UIImage systemImageNamed:option[@"icon"]] forState:UIControlStateNormal];
        [button setTitle:[@"  " stringByAppendingString:option[@"title"]] forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        void (^action)(void) = option[@"action"];
        [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *actionControl) { dismissThen(action); }]
      forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:button];
        y += 51.0;
    }
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(40, cardHeight - 48, cardWidth - 80, 34);
    [cancel setTitle:NSLocalizedString(@"EZGallery.Export.Cancel", nil) forState:UIControlStateNormal];
    [cancel setTitleColor:[UIColor colorWithWhite:0.75 alpha:1.0] forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [cancel addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) { dismissThen(nil); }]
  forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancel];
    [UIView animateWithDuration:0.36 delay:0 usingSpringWithDamping:0.76 initialSpringVelocity:0.45 options:0
                     animations:^{ overlay.alpha = 1; card.transform = CGAffineTransformIdentity; } completion:nil];
}

static NSString *EZGalleryPromptForPath(NSString *path) {
    NSDictionary *prompts = [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:kGalleryImagePromptsKey];
    NSString *prompt = [prompts[path] isKindOfClass:[NSString class]] ? prompts[path] : nil;
    if (!prompt.length && [path isEqualToString:[[NSUserDefaults standardUserDefaults]
                                           stringForKey:@"lastImageLocalPath"]]) {
        prompt = [[NSUserDefaults standardUserDefaults] stringForKey:@"lastImagePrompt"];
    }
    return prompt;
}

// ── Thumbnail cell ─────────────────────────────────────────────────────────────

@interface EZGalleryCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView  *imageView;
@property (nonatomic, strong) UIView       *selectionOverlay;
@property (nonatomic, strong) UIView       *shimmerView;
- (void)setImage:(UIImage * _Nullable)image;
- (void)startShimmer;
@end

@implementation EZGalleryCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];

        self.imageView = [[UIImageView alloc] initWithFrame:self.contentView.bounds];
        self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.imageView.contentMode      = UIViewContentModeScaleAspectFill;
        self.imageView.clipsToBounds    = YES;
        [self.contentView addSubview:self.imageView];

        // Subtle shimmer placeholder
        self.shimmerView = [[UIView alloc] initWithFrame:self.contentView.bounds];
        self.shimmerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.shimmerView.backgroundColor  = [UIColor colorWithWhite:0.18 alpha:1];
        self.shimmerView.hidden = YES;
        [self.contentView addSubview:self.shimmerView];

        // Selection highlight
        self.selectionOverlay = [[UIView alloc] initWithFrame:self.contentView.bounds];
        self.selectionOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.selectionOverlay.backgroundColor  = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:0.22];
        self.selectionOverlay.alpha = 0;
        [self.contentView addSubview:self.selectionOverlay];
    }
    return self;
}

- (void)setImage:(UIImage *)image {
    [self.shimmerView.layer removeAllAnimations];
    self.shimmerView.hidden = YES;
    self.imageView.alpha = 0;
    self.imageView.image = image;
    [UIView animateWithDuration:0.25 animations:^{ self.imageView.alpha = 1; }];
}

- (void)startShimmer {
    self.imageView.image    = nil;
    self.shimmerView.hidden = NO;
    [UIView animateWithDuration:0.9
                          delay:0
                        options:UIViewAnimationOptionAutoreverse | UIViewAnimationOptionRepeat
                     animations:^{ self.shimmerView.alpha = 0.4; }
                     completion:nil];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.imageView.image    = nil;
    self.shimmerView.hidden = YES;
    [self.shimmerView.layer removeAllAnimations];
    self.shimmerView.alpha  = 1;
    self.selectionOverlay.alpha = 0;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.12 animations:^{
        self.selectionOverlay.alpha = highlighted ? 1 : 0;
        self.transform = highlighted ? CGAffineTransformMakeScale(0.96, 0.96) : CGAffineTransformIdentity;
    }];
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    self.selectionOverlay.alpha = selected ? 1.0 : 0.0;
}

@end

// ── Detail / preview view controller ─────────────────────────────────────────
// Presented as a sheet from within the gallery.

@interface EZPhotoDetailViewController () <UITextViewDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
                                            UIContextMenuInteractionDelegate>
- (void)setupImageEditingControls;
- (void)layoutImageEditingControls;
- (CGFloat)editPromptHeight;
- (void)layoutProcessingOverlay;
- (void)layoutImagePresentation;
- (void)keyboardWillChange:(NSNotification *)notification;
- (void)addEditImageTapped;
- (void)addPickedEditImage:(UIImage *)image;
- (UIImage *)compositeEditSourceImage;
- (void)updateImageEditStatus;
- (BOOL)shouldRetryLastImageEditFailure;
- (void)sendImageEditTapped;
- (NSData *)PNGDataForImage:(UIImage *)image;
- (void)setImageEditing:(BOOL)editing;
- (void)startProcessingAnimation;
- (void)stopProcessingAnimationWithCompletion:(void (^ _Nullable)(void))completion;
- (void)finishImageEditWithImage:(UIImage * _Nullable)editedImage
                            error:(NSString * _Nullable)errorMessage;
- (void)showImageEditError:(NSString *)message;
- (UIImage *)shareImageWithBranding;
- (UIImage *)shareImageWithBrandingForImage:(UIImage *)image showOriginalCard:(BOOL)showOriginalCard;
- (CGRect)originalCardRectInImageArea:(CGRect)imageArea border:(CGFloat)border;
- (NSURL *)animatedShareGIFURLWithStyle:(EZShareGIFStyle)style;
- (UIImage *)originalRevealFrameForProgress:(CGFloat)progress;
- (UIImage *)motionTransitionFrameFrom:(UIImage *)before to:(UIImage *)after progress:(CGFloat)progress;
- (UIMenu *)shareMenu;
- (void)shareBrandedImage;
- (void)shareBrandedImageWithOriginalCard:(BOOL)showOriginalCard;
- (void)shareGIFWithStyle:(EZShareGIFStyle)style;
- (void)downloadTapped;
- (void)showImageSettings;
- (void)showPhotoAtGalleryIndex:(NSUInteger)index animated:(BOOL)animated;
@end

@implementation EZPhotoDetailViewController {
    UIScrollView      *_scrollView;
    UIView             *_imageCanvas;
    UIImageView       *_imageView;
    UIImage           *_originalImageForShare;
    // The asset selected when the edit began. It must never be reassigned or
    // removed as a side effect of creating a generated result.
    NSString          *_editSourceFilePath;
    NSMutableArray<UIImageView *> *_imageGridViews;
    NSMutableArray<UIImage *> *_editSourceImages;
    NSMutableArray<NSString *> *_editSourcePaths;
    UIVisualEffectView *_toolbar;
    UIButton          *_askButton;
    UIButton          *_editButton;
    UIButton          *_useInGameButton;
    UIButton          *_shareButton;
    UIButton          *_downloadButton;
    UIButton          *_imageSettingsButton;
    UIButton          *_deleteButton;
    UILabel           *_filenameLabel;

    // EZPhotoAIEditorPatchInstalled
    UITextView        *_editPromptField;
    UILabel           *_editPromptPlaceholderLabel;
    UIButton          *_addImageButton;
    UILabel           *_sourceCountLabel;
    UIButton          *_sendEditButton;
    UIView            *_processingOverlay;
    UIVisualEffectView *_processingBlurView;
    CAGradientLayer   *_waveGradientLayer;
    UIActivityIndicatorView *_editSpinner;
    UIActivityIndicatorView *_processingSpinner;
    UILabel           *_processingStatusLabel;
    UILabel           *_editErrorLabel;
    NSTimer           *_editStatusTimer;
    NSURLSessionDataTask *_imageEditTask;
    BOOL               _isEditingImage;
    BOOL               _hasEditedImage;
    NSUInteger         _galleryIndex;
    BOOL               _isRetryingImageEdit;
    BOOL               _imageEditUsageAuthorized;
    BOOL               _imageEditUsageLogPending;
    BOOL               _lastImageEditFailureWasTransient;
    NSInteger          _imageEditRetryCount;
    NSInteger          _imageEditStatusPhase;
    CGFloat            _keyboardOverlap;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:1.0];

    _editSourceImages = [NSMutableArray arrayWithObject:self.image];
    _originalImageForShare = self.image;
    _editSourcePaths = [NSMutableArray array];
    if (self.filePath.length) {
        [_editSourcePaths addObject:self.filePath];
        _editSourceFilePath = [self.filePath copy];
    }

    [self setupScrollView];
    [self setupToolbar];
    [self setupNavBar];
    [self setupImageEditingControls];

    _galleryIndex = self.galleryIndex;
    UISwipeGestureRecognizer *swipeLeft = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleGallerySwipe:)];
    swipeLeft.direction = UISwipeGestureRecognizerDirectionLeft;
    [self.view addGestureRecognizer:swipeLeft];
    UISwipeGestureRecognizer *swipeRight = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleGallerySwipe:)];
    swipeRight.direction = UISwipeGestureRecognizerDirectionRight;
    [self.view addGestureRecognizer:swipeRight];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(keyboardWillChange:)
                   name:UIKeyboardWillChangeFrameNotification object:nil];
    [center addObserver:self selector:@selector(keyboardWillChange:)
                   name:UIKeyboardWillHideNotification object:nil];
}

- (void)setupNavBar {
    UIBarButtonItem *dismissItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.down.circle.fill"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(dismiss)];
    dismissItem.tintColor = [UIColor colorWithWhite:0.6 alpha:1];

    _downloadButton = [self makeIconButton:@"arrow.down.to.line"
                                     color:[UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0]];
    _downloadButton.frame = CGRectMake(0, 0, 36, 36);
    [_downloadButton addTarget:self action:@selector(downloadTapped)
              forControlEvents:UIControlEventTouchUpInside];
    _imageSettingsButton = [self makeIconButton:@"slider.horizontal.3"
                                           color:[UIColor colorWithRed:0.10 green:0.64 blue:1.0 alpha:1.0]];
    _imageSettingsButton.frame = CGRectMake(0, 0, 36, 36);
    [_imageSettingsButton addTarget:self action:@selector(showImageSettings)
                   forControlEvents:UIControlEventTouchUpInside];
    _imageSettingsButton.accessibilityLabel = @"Image Settings";
    self.navigationItem.leftBarButtonItems = @[
        dismissItem,
        [[UIBarButtonItem alloc] initWithCustomView:_downloadButton],
        [[UIBarButtonItem alloc] initWithCustomView:_imageSettingsButton]
    ];

    _shareButton = [self makeIconButton:@"square.and.arrow.up" color:[UIColor colorWithWhite:0.75 alpha:1]];
    _shareButton.frame = CGRectMake(0, 0, 36, 36);
    [_shareButton addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];
    _deleteButton = [self makeIconButton:@"trash" color:[UIColor systemRedColor]];
    _deleteButton.frame = CGRectMake(0, 0, 36, 36);
    [_deleteButton addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithCustomView:_deleteButton],
        [[UIBarButtonItem alloc] initWithCustomView:_shareButton]
    ];

    // Attachment filenames are implementation details and are often UUIDs.
    self.title = @"";
}

- (void)setupScrollView {
    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.backgroundColor  = [UIColor clearColor];
    _scrollView.minimumZoomScale = 1.0;
    _scrollView.maximumZoomScale = 5.0;
    _scrollView.showsVerticalScrollIndicator   = NO;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scrollView.delegate = (id<UIScrollViewDelegate>)self;
    [self.view addSubview:_scrollView];

    _imageCanvas = [[UIView alloc] init];
    _imageCanvas.clipsToBounds = YES;
    [_scrollView addSubview:_imageCanvas];

    _imageView = [[UIImageView alloc] initWithImage:self.image];
    _imageView.contentMode   = UIViewContentModeScaleAspectFit;
    _imageView.clipsToBounds = NO;
    [_imageCanvas addSubview:_imageView];
    _imageGridViews = [NSMutableArray arrayWithObject:_imageView];

    // Double-tap to zoom
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    [_scrollView addGestureRecognizer:doubleTap];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _imageCanvas;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    [self centerImageView];
}

- (void)centerImageView {
    CGSize  boundsSize  = _scrollView.bounds.size;
    CGRect  frameToCenter = _imageCanvas.frame;
    frameToCenter.origin.x = frameToCenter.size.width < boundsSize.width
        ? (boundsSize.width - frameToCenter.size.width) / 2 : 0;
    frameToCenter.origin.y = frameToCenter.size.height < boundsSize.height
        ? (boundsSize.height - frameToCenter.size.height) / 2 : 0;
    _imageCanvas.frame = frameToCenter;
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    if (_scrollView.zoomScale > 1.0) {
        [_scrollView setZoomScale:1.0 animated:YES];
    } else {
    CGPoint  pt   = [tap locationInView:_imageCanvas];
        CGRect   rect = CGRectMake(pt.x - 60, pt.y - 60, 120, 120);
        [_scrollView zoomToRect:rect animated:YES];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat toolbarH = 184 + ([self editPromptHeight] - 56.0) + self.view.safeAreaInsets.bottom;
    CGFloat availableHeight = self.view.bounds.size.height - _keyboardOverlap;
    CGFloat imageAreaH = MAX(0.0, availableHeight - toolbarH);

    _scrollView.frame = CGRectMake(0, 0, self.view.bounds.size.width, imageAreaH);

    [self layoutImagePresentation];

    _toolbar.frame = CGRectMake(0, availableHeight - toolbarH,
                                self.view.bounds.size.width, toolbarH);
    [self layoutToolbarButtons];
    [self layoutImageEditingControls];
    [self layoutProcessingOverlay];
}

// A single reference keeps the familiar aspect-fit preview.  Two to four
// references become an equal-sized grid, giving each input the same visual
// weight before the edit is sent.
- (void)layoutImagePresentation {
    NSUInteger count = _editSourceImages.count;
    if (count == 0) return;

    CGFloat width = CGRectGetWidth(_scrollView.bounds);
    CGFloat height = CGRectGetHeight(_scrollView.bounds);
    if (count == 1) {
        CGSize imageSize = _editSourceImages.firstObject.size;
        if (imageSize.width <= 0 || imageSize.height <= 0) return;
        CGFloat scale = MIN(width / imageSize.width, height / imageSize.height);
        _imageCanvas.frame = CGRectMake(0, 0, imageSize.width * scale, imageSize.height * scale);
        _imageGridViews.firstObject.frame = _imageCanvas.bounds;
        _imageGridViews.firstObject.contentMode = UIViewContentModeScaleAspectFit;
    } else {
        _imageCanvas.frame = CGRectMake(0, 0, width, height);
        NSUInteger columns = 2;
        CGFloat gap = 4.0;
        CGFloat tileWidth = (width - gap) / columns;
        CGFloat tileHeight = (height - gap) / 2.0;
        for (NSUInteger index = 0; index < _imageGridViews.count; index++) {
            NSUInteger row = index / columns;
            NSUInteger column = index % columns;
            UIImageView *imageView = _imageGridViews[index];
            imageView.frame = CGRectMake(column * (tileWidth + gap), row * (tileHeight + gap),
                                         tileWidth, tileHeight);
            imageView.contentMode = UIViewContentModeScaleAspectFill;
            imageView.clipsToBounds = YES;
        }
    }
    _scrollView.contentSize = _imageCanvas.bounds.size;
    [self centerImageView];
}

// Keep the entire edit bar, including its text field, directly above the
// keyboard.  The intersection calculation also handles rotation and avoids
// moving the bar for a detached/floating keyboard that does not cover it.
- (void)keyboardWillChange:(NSNotification *)notification {
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardInView = [self.view convertRect:keyboardFrame fromView:nil];
    CGRect coveredArea = CGRectIntersection(self.view.bounds, keyboardInView);
    BOOL keyboardTouchesBottom = !CGRectIsNull(coveredArea) &&
        CGRectGetMaxY(coveredArea) >= CGRectGetMaxY(self.view.bounds) - 0.5;
    _keyboardOverlap = keyboardTouchesBottom ? CGRectGetHeight(coveredArea) : 0.0;

    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationOptions curve =
        [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16;
    [UIView animateWithDuration:duration
                          delay:0
                        options:curve | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)setupToolbar {
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _toolbar = [[UIVisualEffectView alloc] initWithEffect:blur];
    _toolbar.clipsToBounds = YES;

    // Top separator line
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 9999, 0.5)];
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_toolbar.contentView addSubview:line];

    // Ask button — gold, prominent
    _askButton = [self makeButtonTitle:NSLocalizedString(@"EZGallery.AskQuestion", nil)
                                  icon:@"bubble.left.and.bubble.right.fill"
                           accentColor:[UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0]
                                  dark:YES];
    [_askButton addTarget:self action:@selector(askTapped) forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_askButton];

    // Edit button — blue
    _editButton = [self makeButtonTitle:NSLocalizedString(@"EZGallery.EditWithAI", nil)
                                   icon:@"wand.and.stars"
                            accentColor:[UIColor systemBlueColor]
                                   dark:NO];
    [_editButton addTarget:self action:@selector(editTapped) forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_editButton];

    _useInGameButton = [self makeButtonTitle:NSLocalizedString(@"EZGallery.UseInVideoGame", nil)
                                         icon:@"gamecontroller.fill"
                                  accentColor:[UIColor systemPurpleColor]
                                         dark:NO];
    [_useInGameButton addTarget:self action:@selector(useInVideoGameTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_useInGameButton];

    [self.view addSubview:_toolbar];

    [self layoutToolbarButtons];
}

- (void)layoutToolbarButtons {
    CGFloat pad  = 16;
    CGFloat btnH = 56;
    // The prompt field grows as the user writes. Keep the action row below it
    // instead of at a fixed y-position, which previously caused long prompts
    // to paint underneath the buttons while the keyboard was visible.
    CGFloat y    = 14.0 + [self editPromptHeight] + 18.0;
    CGFloat W    = self.view.bounds.size.width;
    if (W == 0) W = UIScreen.mainScreen.bounds.size.width;

    CGFloat buttonW = (W - pad * 2 - 16) / 3.0;
    _askButton.frame       = CGRectMake(pad, y, buttonW, btnH);
    _editButton.frame      = CGRectMake(pad + buttonW + 8, y, buttonW, btnH);
    _useInGameButton.frame = CGRectMake(pad + (buttonW + 8) * 2, y, buttonW, btnH);
}

#pragma mark - AI Image Editing

- (void)setupImageEditingControls {
    UIView *promptContainer = [[UIView alloc] init];
    promptContainer.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    promptContainer.layer.cornerRadius = 18.0;
    promptContainer.layer.borderWidth = 1.0;
    promptContainer.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.11].CGColor;
    promptContainer.clipsToBounds = YES;
    [_toolbar.contentView addSubview:promptContainer];

    _editPromptField = [[UITextView alloc] init];
    _editPromptField.backgroundColor = [UIColor clearColor];
    _editPromptField.textColor = [UIColor whiteColor];
    _editPromptField.tintColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _editPromptField.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    _editPromptField.returnKeyType = UIReturnKeyDefault;
    _editPromptField.delegate = (id<UITextViewDelegate>)self;
    _editPromptField.textContainerInset = UIEdgeInsetsMake(8, 0, 8, 0);
    _editPromptField.textContainer.lineFragmentPadding = 0;
    _editPromptField.showsVerticalScrollIndicator = YES;
    _editPromptField.alwaysBounceVertical = NO;
    [promptContainer addSubview:_editPromptField];

    _editPromptPlaceholderLabel = [[UILabel alloc] init];
    _editPromptPlaceholderLabel.text = NSLocalizedString(@"EZGallery.EditPromptPlaceholder", nil);
    _editPromptPlaceholderLabel.textColor = [UIColor colorWithWhite:0.72 alpha:0.70];
    _editPromptPlaceholderLabel.font = _editPromptField.font;
    _editPromptPlaceholderLabel.numberOfLines = 0;
    _editPromptPlaceholderLabel.userInteractionEnabled = NO;
    [promptContainer addSubview:_editPromptPlaceholderLabel];

    _addImageButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _addImageButton.tintColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _addImageButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _addImageButton.layer.cornerRadius = 18.0;
    UIImageSymbolConfiguration *addConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold];
    [_addImageButton setImage:[UIImage systemImageNamed:@"plus" withConfiguration:addConfig]
                       forState:UIControlStateNormal];
    [_addImageButton addTarget:self action:@selector(addEditImageTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [promptContainer addSubview:_addImageButton];

    _sourceCountLabel = [[UILabel alloc] init];
    _sourceCountLabel.backgroundColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _sourceCountLabel.textColor = [UIColor colorWithRed:0.03 green:0.05 blue:0.10 alpha:1.0];
    _sourceCountLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
    _sourceCountLabel.textAlignment = NSTextAlignmentCenter;
    _sourceCountLabel.layer.cornerRadius = 8.0;
    _sourceCountLabel.clipsToBounds = YES;
    _sourceCountLabel.hidden = YES;
    [promptContainer addSubview:_sourceCountLabel];

    _sendEditButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _sendEditButton.backgroundColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _sendEditButton.tintColor = [UIColor colorWithRed:0.03 green:0.05 blue:0.10 alpha:1.0];
    _sendEditButton.layer.cornerRadius = 28.0;
    _sendEditButton.layer.shadowColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0].CGColor;
    _sendEditButton.layer.shadowOpacity = 0.30;
    _sendEditButton.layer.shadowRadius = 10.0;
    _sendEditButton.layer.shadowOffset = CGSizeMake(0, 4);
    UIImageSymbolConfiguration *symbolConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold];
    UIImage *sendImage = [UIImage systemImageNamed:@"arrow.up"
                                 withConfiguration:symbolConfig];
    [_sendEditButton setImage:sendImage forState:UIControlStateNormal];
    [_sendEditButton addTarget:self
                        action:@selector(sendImageEditTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_sendEditButton];

    _editSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _editSpinner.color = [UIColor colorWithRed:0.03 green:0.05 blue:0.10 alpha:1.0];
    _editSpinner.hidesWhenStopped = YES;
    [_sendEditButton addSubview:_editSpinner];

    _editErrorLabel = [[UILabel alloc] init];
    _editErrorLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _editErrorLabel.textColor = [UIColor systemOrangeColor];
    _editErrorLabel.textAlignment = NSTextAlignmentCenter;
    _editErrorLabel.numberOfLines = 1;
    _editErrorLabel.hidden = YES;
    [_toolbar.contentView addSubview:_editErrorLabel];
}

- (void)layoutImageEditingControls {
    if (!_editPromptField || !_sendEditButton) return;

    CGFloat pad = 16.0;
    CGFloat y = 14.0;
    CGFloat fieldHeight = [self editPromptHeight];
    CGFloat sendSize = 56.0;
    CGFloat width = _toolbar.contentView.bounds.size.width;
    if (width <= 0) width = self.view.bounds.size.width;

    _sendEditButton.frame = CGRectMake(width - pad - sendSize, y + (fieldHeight - sendSize) / 2.0, sendSize, sendSize);
    _editSpinner.center = CGPointMake(CGRectGetMidX(_sendEditButton.bounds),
                                      CGRectGetMidY(_sendEditButton.bounds));

    UIView *promptContainer = _editPromptField.superview;
    promptContainer.frame = CGRectMake(pad, y, width - (pad * 2.0) - sendSize - 10.0, fieldHeight);
    _addImageButton.frame = CGRectMake(8.0, 10.0, 36.0, 36.0);
    _sourceCountLabel.frame = CGRectMake(33.0, 5.0, 16.0, 16.0);
    _sourceCountLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)_editSourceImages.count];
    _sourceCountLabel.hidden = _editSourceImages.count < 2;
    _addImageButton.alpha = _editSourceImages.count >= kMaxImageEditSources ? 0.40 : 1.0;
    _editPromptField.frame = CGRectMake(54.0, 0.0,
                                        MAX(0.0, CGRectGetWidth(promptContainer.bounds) - 70.0),
                                        CGRectGetHeight(promptContainer.bounds));
    _editPromptPlaceholderLabel.frame = CGRectMake(54.0, 8.0,
        MAX(0.0, CGRectGetWidth(promptContainer.bounds) - 70.0), fieldHeight - 16.0);
    _editPromptPlaceholderLabel.hidden = _editPromptField.text.length > 0;
    _editErrorLabel.frame = CGRectMake(pad, y + fieldHeight + 2.0, width - pad * 2.0, 14.0);
}

- (CGFloat)editPromptHeight {
    CGFloat width = MAX(120.0, self.view.bounds.size.width - 16.0 * 2.0 - 56.0 - 10.0 - 54.0 - 16.0);
    CGSize measured = [_editPromptField sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    // Start compact, grow up to five lines, then let the editor scroll so no
    // prompt becomes inaccessible while typing.
    return MIN(128.0, MAX(56.0, ceil(measured.height)));
}

- (void)textViewDidChange:(UITextView *)textView {
    _editPromptPlaceholderLabel.hidden = textView.text.length > 0;
    [self.view setNeedsLayout];
}

- (void)addEditImageTapped {
    if (_isEditingImage || _editSourceImages.count >= kMaxImageEditSources) return;
    __weak typeof(self) weakSelf = self;
    EZPresentPhotoSourcePicker(self, ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
        configuration.filter = [PHPickerFilter imagesFilter];
        configuration.selectionLimit = kMaxImageEditSources - self->_editSourceImages.count;
        PHPickerViewController *picker = [[PHPickerViewController alloc]
            initWithConfiguration:configuration];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }, ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
        picker.delegate = self;
        picker.allowsMultipleSelection = YES;
        [self presentViewController:picker animated:YES completion:nil];
    }, ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        EZPhotoGalleryViewController *gallery = [EZPhotoGalleryViewController new];
        gallery.onSelectImage = ^(UIImage *image) { [self addPickedEditImage:image]; };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:gallery];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:nav animated:YES completion:nil];
    });
}

- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    for (PHPickerResult *result in results) {
        if (![result.itemProvider canLoadObjectOfClass:[UIImage class]]) continue;
        [result.itemProvider loadObjectOfClass:[UIImage class]
                           completionHandler:^(__kindof id<NSItemProviderReading> object, NSError *error) {
            UIImage *image = [object isKindOfClass:[UIImage class]] ? object : nil;
            if (!image || error) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self addPickedEditImage:image];
            });
        }];
    }
}

- (void)addPickedEditImage:(UIImage *)image {
    if (!image || _isEditingImage || _editSourceImages.count >= kMaxImageEditSources) return;
    [_editSourceImages addObject:image];
    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    imageView.clipsToBounds = YES;
    [_imageCanvas addSubview:imageView];
    [_imageGridViews addObject:imageView];

    [_scrollView setZoomScale:1.0 animated:NO];
    [UIView transitionWithView:_imageCanvas duration:0.28
                       options:UIViewAnimationOptionTransitionCrossDissolve |
                               UIViewAnimationOptionCurveEaseInOut
                    animations:^{
        [self layoutImagePresentation];
        [self layoutImageEditingControls];
    }
                    completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        if (_editSourceImages.count >= kMaxImageEditSources) break;
        BOOL accessed = [url startAccessingSecurityScopedResource];
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (accessed) [url stopAccessingSecurityScopedResource];
        UIImage *image = [UIImage imageWithData:data];
        if (image) [self addPickedEditImage:image];
    }
}

- (void)editTapped {
    [_editPromptField becomeFirstResponder];
    [UIView animateWithDuration:0.20 animations:^{
        _editPromptField.superview.transform = CGAffineTransformMakeScale(1.02, 1.02);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.18 animations:^{
            _editPromptField.superview.transform = CGAffineTransformIdentity;
        }];
    }];
}

- (void)sendImageEditTapped {
    if (_isEditingImage && !_isRetryingImageEdit) return;

    NSString *prompt = [_editPromptField.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (prompt.length == 0) {
        [self showImageEditError:@"Please describe the change you want to make."];
        [_editPromptField becomeFirstResponder];
        return;
    }

    _editErrorLabel.hidden = YES;
    if (!_isRetryingImageEdit) {
        _imageEditRetryCount = 0;
        _lastImageEditFailureWasTransient = NO;
        _imageEditUsageAuthorized = NO;
        _imageEditUsageLogPending = NO;
    }
    _isRetryingImageEdit = NO;

    NSString *accessToken = [EZAuthManager shared].accessToken;
    if (accessToken.length == 0) {
        [self showImageEditError:@"Please sign in before editing an image."];
        return;
    }

    NSMutableArray<NSString *> *imagePayloads = [NSMutableArray array];
    for (UIImage *sourceImage in _editSourceImages) {
        NSData *imageData = [self PNGDataForImage:sourceImage];
        if (imageData.length > 0) {
            [imagePayloads addObject:[imageData base64EncodedStringWithOptions:0]];
        }
    }
    if (imagePayloads.count == 0) {
        [self showImageEditError:@"The selected photo could not be prepared for editing."];
        return;
    }

    // This editor posts directly to ez-image, so it needs its own entitlement
    // preflight (the chat path normally does this before calling an image API).
    // The approved usage log is reused by automatic network retries.
    if (!_imageEditUsageAuthorized) {
        NSUserDefaults *billingDefaults = [NSUserDefaults standardUserDefaults];
        // Gallery edits should be predictable and available to every user by
        // default. "auto" is a server-side premium-quality choice; Medium is
        // the intended baseline until someone explicitly selects another tier.
        NSString *billingQuality = [billingDefaults stringForKey:@"imgQuality"] ?: @"medium";
        NSString *billingSize = [billingDefaults stringForKey:@"imgSize"] ?: @"1024x1024";
        NSInteger billingN = [billingDefaults integerForKey:@"imgVariations"];
        if (billingN < 1 || billingN > 4) billingN = 1;
        EZFeature feature = [billingQuality isEqualToString:@"high"] ? EZFeatureImageHigh :
                            [billingQuality isEqualToString:@"low"] ? EZFeatureImageLow : EZFeatureImageMedium;
        NSInteger quantity = (NSInteger)ceil(billingN * ([billingSize isEqualToString:@"1024x1024"] ? 1.0 : 1.25));
        [_editPromptField resignFirstResponder];
        [self setImageEditing:YES];
        [self startProcessingAnimation];
        __weak typeof(self) weakSelf = self;
        [[EZEntitlementManager shared] checkEntitlementForFeature:feature
                                                         quantity:quantity
                                                           prompt:prompt
                                                            model:@"gpt-image-2.5-sunburst"
                                                         quality:billingQuality
                                                            size:billingSize
                                                          isEdit:YES
                                                       completion:^(BOOL allowed, NSInteger balance, NSString *reason) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (!self || !self->_isEditingImage) return;
                if (!allowed) {
                    [self setImageEditing:NO];
                    [self stopProcessingAnimationWithCompletion:nil];
                    [self showImageEditError:reason.length ? reason : @"Image edit is not available right now."];
                    return;
                }
                self->_imageEditUsageAuthorized = YES;
                self->_imageEditUsageLogPending = YES;
                self->_isRetryingImageEdit = YES;
                [self sendImageEditTapped];
            });
        }];
        return;
    }

    [_editPromptField resignFirstResponder];
    // Freeze the selected asset identity before the asynchronous request so a
    // completion can only create a sibling file, never replace that source.
    _editSourceFilePath = [self.filePath copy];
    [self setImageEditing:YES];
    [self startProcessingAnimation];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Gallery edits use the precision image-editing model regardless of the
    // chat screen's active model.
    NSString *model = @"gpt-image-2.5-sunburst";

    NSInteger variationCount = [defaults integerForKey:@"imgVariations"];
    if (variationCount < 1 || variationCount > 4) variationCount = 1;
    NSString *size = [defaults stringForKey:@"imgSize"] ?: @"1024x1024";
    NSString *quality = [defaults stringForKey:@"imgQuality"] ?: @"medium";
    NSString *format = [defaults stringForKey:@"imgFormat"] ?: @"png";
    NSString *background = [defaults stringForKey:@"imgBackground"] ?: @"auto";
    NSString *moderation = [defaults stringForKey:@"imgModeration"] ?: @"low";
    // Older deployments of ez-image accept a single `image_b64` value. Send a
    // labelled-free composite there so every selected reference is still seen,
    // while newer deployments can use the individual source array directly.
    UIImage *compatibilityImage = [self compositeEditSourceImage];
    NSData *compatibilityData = [self PNGDataForImage:compatibilityImage];
    NSString *compatibilityPayload = compatibilityData.length
        ? [compatibilityData base64EncodedStringWithOptions:0] : imagePayloads.firstObject;
    NSDictionary *body = @{
        @"action": @"edit", @"model": model, @"prompt": prompt,
        @"image_b64": compatibilityPayload, @"images_b64": imagePayloads,
        @"n": @(variationCount), @"size": size, @"quality": quality,
        @"output_format": format, @"background": background, @"moderation": moderation,
    };
    NSError *encodingError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encodingError];
    if (!bodyData) {
        [self finishImageEditWithImage:nil error:encodingError.localizedDescription ?: @"Could not prepare the image edit."];
        return;
    }

    NSURL *endpoint = [NSURL URLWithString:[NSString stringWithFormat:
        @"%@/functions/v1/ez-image", EZSupabaseURL]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 330.0;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", accessToken]
   forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = bodyData;

    __weak typeof(self) weakSelf = self;
    _imageEditTask = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *failureMessage = nil;
        UIImage *editedImage = nil;
        BOOL transientFailure = NO;
        if (error) {
            failureMessage = error.localizedDescription;
            transientFailure = error.code == NSURLErrorTimedOut ||
                error.code == NSURLErrorNetworkConnectionLost ||
                error.code == NSURLErrorNotConnectedToInternet ||
                error.code == NSURLErrorCannotConnectToHost;
        } else {
            NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
            transientFailure = statusCode == 408 || statusCode == 429 || statusCode >= 500;
            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data]
                                                                  options:0 error:&jsonError];
            id errorValue = json[@"error"];
            NSString *reason = [json[@"reason"] isKindOfClass:[NSString class]] ? json[@"reason"] : nil;
            if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
                failureMessage = @"The image-edit service returned an invalid response.";
            } else if (errorValue && errorValue != [NSNull null]) {
                NSString *errorText = [errorValue isKindOfClass:[NSString class]] ? errorValue : @"Image edit failed.";
                failureMessage = reason.length ? [NSString stringWithFormat:@"%@ %@", errorText, reason] : errorText;
            } else {
                NSDictionary *firstImage = [json[@"images"] firstObject];
                NSString *signedURL = [firstImage[@"url"] isKindOfClass:[NSString class]] ? firstImage[@"url"] : nil;
                NSData *editedData = signedURL.length ? [NSData dataWithContentsOfURL:[NSURL URLWithString:signedURL]] : nil;
                editedImage = [UIImage imageWithData:editedData];
                if (!editedImage) failureMessage = @"The image-edit service did not return a usable image.";
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self) return;
            self->_imageEditTask = nil;
            self->_lastImageEditFailureWasTransient = transientFailure;
            [self finishImageEditWithImage:editedImage error:failureMessage];
        });
    }];
    [_imageEditTask resume];
}

- (NSData *)PNGDataForImage:(UIImage *)image {
    if (!image) return nil;

    CGFloat maximumDimension = 2048.0;
    CGSize sourceSize = image.size;
    CGFloat largestSide = MAX(sourceSize.width, sourceSize.height);
    UIImage *prepared = image;

    if (largestSide > maximumDimension) {
        CGFloat scale = maximumDimension / largestSide;
        CGSize targetSize = CGSizeMake(floor(sourceSize.width * scale),
                                       floor(sourceSize.height * scale));
        UIGraphicsBeginImageContextWithOptions(targetSize, NO, 1.0);
        [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
        prepared = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }

    return UIImagePNGRepresentation(prepared);
}

// A single-image edit endpoint can still receive all references as a 2×2
// contact sheet.  Each source is aspect-fit (never cropped), so the model can
// use every attachment even when it does not yet understand `images_b64`.
- (UIImage *)compositeEditSourceImage {
    if (_editSourceImages.count <= 1) return _editSourceImages.firstObject;

    CGFloat side = 2048.0;
    CGFloat gap = 12.0;
    CGFloat tileSide = (side - gap * 3.0) / 2.0;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), YES, 1.0);
    [[UIColor colorWithRed:0.025 green:0.035 blue:0.085 alpha:1] setFill];
    UIRectFill(CGRectMake(0, 0, side, side));
    for (NSUInteger index = 0; index < _editSourceImages.count; index++) {
        UIImage *image = _editSourceImages[index];
        if (image.size.width <= 0 || image.size.height <= 0) continue;
        NSUInteger row = index / 2;
        NSUInteger column = index % 2;
        CGRect tile = CGRectMake(gap + column * (tileSide + gap),
                                 gap + row * (tileSide + gap), tileSide, tileSide);
        CGFloat scale = MIN(tile.size.width / image.size.width, tile.size.height / image.size.height);
        CGSize fittedSize = CGSizeMake(image.size.width * scale, image.size.height * scale);
        CGRect drawRect = CGRectMake(CGRectGetMidX(tile) - fittedSize.width / 2.0,
                                     CGRectGetMidY(tile) - fittedSize.height / 2.0,
                                     fittedSize.width, fittedSize.height);
        [image drawInRect:drawRect];
    }
    UIImage *composite = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return composite;
}

- (void)setImageEditing:(BOOL)editing {
    _isEditingImage = editing;
    _editPromptField.editable = !editing;
    _addImageButton.enabled = !editing && _editSourceImages.count < kMaxImageEditSources;
    _sendEditButton.enabled = !editing;
    _askButton.enabled = !editing;
    _editButton.enabled = !editing;
    _useInGameButton.enabled = !editing;
    _shareButton.enabled = !editing;
    _downloadButton.enabled = !editing;
    _imageSettingsButton.enabled = !editing;
    _deleteButton.enabled = !editing;
    _sendEditButton.alpha = editing ? 0.92 : 1.0;

    if (editing) {
        [_sendEditButton setImage:nil forState:UIControlStateNormal];
        [_editSpinner startAnimating];
    } else {
        [_editSpinner stopAnimating];
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold];
        [_sendEditButton setImage:[UIImage systemImageNamed:@"arrow.up"
                                          withConfiguration:config]
                          forState:UIControlStateNormal];
    }
}

- (void)startProcessingAnimation {
    if (_processingOverlay) return;

    _processingOverlay = [[UIView alloc] initWithFrame:_imageCanvas.bounds];
    _processingOverlay.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _processingOverlay.userInteractionEnabled = NO;
    _processingOverlay.clipsToBounds = YES;
    _processingOverlay.backgroundColor = [UIColor colorWithRed:0.03 green:0.10 blue:0.18 alpha:0.12];
    [_imageCanvas addSubview:_processingOverlay];

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _processingBlurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    _processingBlurView.frame = _processingOverlay.bounds;
    _processingBlurView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _processingBlurView.alpha = 0.0;
    [_processingOverlay addSubview:_processingBlurView];

    _processingSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _processingSpinner.color = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _processingSpinner.transform = CGAffineTransformMakeScale(1.7, 1.7);
    [_processingOverlay addSubview:_processingSpinner];

    _processingStatusLabel = [[UILabel alloc] init];
    _processingStatusLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _processingStatusLabel.textColor = [UIColor whiteColor];
    _processingStatusLabel.textAlignment = NSTextAlignmentCenter;
    _processingStatusLabel.numberOfLines = 2;
    [_processingOverlay addSubview:_processingStatusLabel];
    [self layoutProcessingOverlay];
    _imageEditStatusPhase = 0;
    [_processingSpinner startAnimating];
    [self updateImageEditStatus];
    _editStatusTimer = [NSTimer scheduledTimerWithTimeInterval:4.0
                                                          target:self
                                                        selector:@selector(updateImageEditStatus)
                                                        userInfo:nil
                                                         repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_editStatusTimer forMode:NSRunLoopCommonModes];

    _waveGradientLayer = [CAGradientLayer layer];
    _waveGradientLayer.frame = CGRectInset(_processingOverlay.bounds,
                                           -_processingOverlay.bounds.size.width, 0);
    _waveGradientLayer.startPoint = CGPointMake(0.0, 0.5);
    _waveGradientLayer.endPoint = CGPointMake(1.0, 0.5);
    _waveGradientLayer.colors = @[
        (id)[UIColor clearColor].CGColor,
        (id)[UIColor colorWithRed:0.00 green:0.95 blue:0.74 alpha:0.06].CGColor,
        (id)[UIColor colorWithRed:0.20 green:0.45 blue:1.00 alpha:0.34].CGColor,
        (id)[UIColor colorWithRed:0.00 green:0.95 blue:0.74 alpha:0.06].CGColor,
        (id)[UIColor clearColor].CGColor
    ];
    _waveGradientLayer.locations = @[@0.0, @0.30, @0.50, @0.70, @1.0];
    _waveGradientLayer.compositingFilter = @"screenBlendMode";
    [_processingOverlay.layer addSublayer:_waveGradientLayer];

    CABasicAnimation *wave = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    wave.fromValue = @(-_processingOverlay.bounds.size.width);
    wave.toValue = @(_processingOverlay.bounds.size.width);
    wave.duration = 1.65;
    wave.repeatCount = HUGE_VALF;
    wave.timingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_waveGradientLayer addAnimation:wave forKey:@"ez.ai.wave"];

    [UIView animateWithDuration:0.45 animations:^{
        self->_processingBlurView.alpha = 0.90;
        self->_imageCanvas.transform = CGAffineTransformMakeScale(1.025, 1.025);
    }];

    [UIView animateWithDuration:1.05
                          delay:0.45
                        options:UIViewAnimationOptionAutoreverse |
                                UIViewAnimationOptionRepeat |
                                UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self->_imageCanvas.transform = CGAffineTransformMakeScale(1.055, 1.055);
        self->_processingOverlay.alpha = 0.78;
    } completion:nil];
}

- (void)layoutProcessingOverlay {
    if (!_processingOverlay) return;
    _processingOverlay.frame = _imageCanvas.bounds;
    _processingBlurView.frame = _processingOverlay.bounds;
    _waveGradientLayer.frame = CGRectInset(_processingOverlay.bounds,
                                           -_processingOverlay.bounds.size.width, 0);
    _processingSpinner.center = CGPointMake(CGRectGetMidX(_processingOverlay.bounds),
                                            CGRectGetMidY(_processingOverlay.bounds) - 18.0);
    _processingStatusLabel.frame = CGRectMake(24.0, CGRectGetMidY(_processingOverlay.bounds) + 24.0,
                                              MAX(0.0, CGRectGetWidth(_processingOverlay.bounds) - 48.0), 48.0);
}

- (void)updateImageEditStatus {
    NSArray<NSString *> *messages = @[
        @"Preparing your image edit…",
        @"Applying your requested changes…",
        @"Still working. Almost done.",
        @"Finishing the image…"
    ];
    _processingStatusLabel.text = messages[_imageEditStatusPhase % messages.count];
    _imageEditStatusPhase++;
}

- (BOOL)shouldRetryLastImageEditFailure {
    return _lastImageEditFailureWasTransient && _imageEditRetryCount < 2;
}

- (void)stopProcessingAnimationWithCompletion:(void (^)(void))completion {
    [_editStatusTimer invalidate];
    _editStatusTimer = nil;
    [_processingSpinner stopAnimating];
    [_processingOverlay.layer removeAllAnimations];
    [_waveGradientLayer removeAllAnimations];

    [UIView animateWithDuration:0.34 animations:^{
        self->_processingOverlay.alpha = 0.0;
        self->_imageCanvas.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        [self->_processingOverlay removeFromSuperview];
        self->_processingOverlay = nil;
        self->_processingBlurView = nil;
        self->_waveGradientLayer = nil;
        self->_processingSpinner = nil;
        self->_processingStatusLabel = nil;
        if (completion) completion();
    }];
}

- (void)finishImageEditWithImage:(UIImage *)editedImage error:(NSString *)errorMessage {
    if (errorMessage.length > 0 && [self shouldRetryLastImageEditFailure]) {
        _imageEditRetryCount++;
        _processingStatusLabel.text = [NSString stringWithFormat:
            @"Connection interrupted — retrying (%ld of 2)…", (long)_imageEditRetryCount];
        EZLogf(EZLogLevelWarning, @"IMGEDIT", @"Transient gallery edit failure; retry %ld: %@",
               (long)_imageEditRetryCount, errorMessage);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!self.viewIfLoaded.window || !self->_isEditingImage) return;
            self->_isRetryingImageEdit = YES;
            [self sendImageEditTapped];
        });
        return;
    }

    [self setImageEditing:NO];

    if (errorMessage.length > 0 || !editedImage) {
        if (_imageEditUsageLogPending) {
            [[EZEntitlementManager shared] completeUsageLogWithImagesReturned:0
                                                                     errorText:errorMessage ?: @"Image edit returned no image."];
            _imageEditUsageLogPending = NO;
        }
        [self stopProcessingAnimationWithCompletion:nil];
        [self showImageEditError:errorMessage ?: @"The image edit did not return an image."];
        return;
    }

    if (_imageEditUsageLogPending) {
        [[EZEntitlementManager shared] completeUsageLogWithImagesReturned:1 errorText:nil];
        _imageEditUsageLogPending = NO;
    }

    [self stopProcessingAnimationWithCompletion:^{
        // An edit is always a new attachment. EZAttachmentSave UUID-prefixes
        // the filename, so this write cannot replace the source asset.
        NSString *sourcePath = self->_editSourceFilePath ?: self.filePath;
        NSData *savedData = [self PNGDataForImage:editedImage];
        NSString *newFilePath = savedData.length
            ? EZPhotoGallerySave(savedData, @"gallery_edit.png") : nil;
        if (!newFilePath.length || [newFilePath isEqualToString:sourcePath]) {
            [self showImageEditError:@"The edit completed, but could not be saved as a new gallery image."];
            return;
        }

        // Keep the original in the detail controller's gallery sequence and
        // add the generated result as its own newest item. The displayed image
        // changes only as a preview of that new item; no source file is moved,
        // overwritten, or deleted.
        NSMutableArray<NSString *> *updatedPaths = [self.galleryFilePaths mutableCopy] ?: [NSMutableArray array];
        [updatedPaths removeObject:newFilePath];
        [updatedPaths insertObject:newFilePath atIndex:0];
        self.galleryFilePaths = updatedPaths;
        self->_galleryIndex = 0;
        self.image = editedImage;
        self->_hasEditedImage = YES;
        self.filePath = newFilePath;
        [_editSourcePaths removeAllObjects];
        [_editSourcePaths addObject:newFilePath];
        [_editSourceImages removeAllObjects];
        [_editSourceImages addObject:editedImage];
        while (_imageGridViews.count > 1) {
            UIImageView *extraView = _imageGridViews.lastObject;
            [extraView removeFromSuperview];
            [_imageGridViews removeLastObject];
        }
        [UIView transitionWithView:self->_imageCanvas
                          duration:0.42
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionCurveEaseInOut
                        animations:^{
            self->_imageView.image = editedImage;
            [self.view setNeedsLayout];
            [self.view layoutIfNeeded];
        } completion:nil];

        NSMutableDictionary *prompts = [[[NSUserDefaults standardUserDefaults]
            dictionaryForKey:kGalleryImagePromptsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
        prompts[newFilePath] = self->_editPromptField.text ?: @"";
        [[NSUserDefaults standardUserDefaults] setObject:prompts forKey:kGalleryImagePromptsKey];
        self.imagePrompt = self->_editPromptField.text;

        // Gallery edits bypass the chat controller, so save their one memory
        // entry here after the edited asset has been written successfully.
        NSString *prompt = [self->_editPromptField.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *token = [EZAuthManager shared].accessToken;
        if (prompt.length > 0 && token.length > 0) {
            NSString *answer = [NSString stringWithFormat:@"Edited a gallery image per: %@", prompt];
            NSArray<NSString *> *attachments = self.filePath.length ? @[self.filePath] : @[];
            createMemoryFromCompletion(prompt, answer, token, nil, attachments,
            ^(NSString *entry) {
                if (entry) EZLog(EZLogLevelInfo, @"MEMORY", @"Saved gallery image-edit memory");
            });
        }
    }];
}

- (void)showImageEditError:(NSString *)message {
    _editErrorLabel.text = message.length ? message : @"Image edit could not be completed.";
    _editErrorLabel.hidden = NO;
    EZLogf(EZLogLevelWarning, @"IMGEDIT", @"Gallery edit failed: %@", _editErrorLabel.text);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        [_imageEditTask cancel];
        _imageEditTask = nil;
        [_editStatusTimer invalidate];
        _editStatusTimer = nil;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIButton *)makeButtonTitle:(NSString *)title icon:(NSString *)iconName
                   accentColor:(UIColor *)color dark:(BOOL)dark {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.backgroundColor    = dark ? color : [color colorWithAlphaComponent:0.18];
    btn.layer.cornerRadius = 14;
    btn.layer.masksToBounds = YES;
    btn.tintColor          = dark ? [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1] : color;

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14
                                                                                         weight:UIImageSymbolWeightSemibold];
    UIImage *icon = [UIImage systemImageNamed:iconName withConfiguration:config];

    if (@available(iOS 15, *)) {
        UIButtonConfiguration *bc = [UIButtonConfiguration filledButtonConfiguration];
        bc.title             = title;
        bc.image             = icon;
        bc.imagePadding      = 6;
        bc.imagePlacement    = NSDirectionalRectEdgeLeading;
        bc.contentInsets     = NSDirectionalEdgeInsetsMake(0, 14, 0, 14);
        bc.titleTextAttributesTransformer =
            ^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *attrs) {
                NSMutableDictionary *m = [attrs mutableCopy];
                m[NSFontAttributeName] = [UIFont boldSystemFontOfSize:13];
                return m;
            };
        bc.background.backgroundColor = btn.backgroundColor;
        btn.configuration = bc;
        btn.tintColor = dark ? [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1] : color;
    } else {
        [btn setTitle:[@"  " stringByAppendingString:title] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [btn setTitleColor:dark ? [UIColor colorWithRed:0.05 green:0.05 blue:0.12 alpha:1] : color
                  forState:UIControlStateNormal];
    }
    return btn;
}

- (UIButton *)makeIconButton:(NSString *)iconName color:(UIColor *)color {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.backgroundColor    = [UIColor colorWithWhite:1 alpha:0.07];
    btn.layer.cornerRadius = 14;
    btn.tintColor          = color;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18
                                                                                       weight:UIImageSymbolWeightMedium];
    [btn setImage:[UIImage systemImageNamed:iconName withConfiguration:cfg] forState:UIControlStateNormal];
    return btn;
}

- (void)handleGallerySwipe:(UISwipeGestureRecognizer *)gesture {
    if (_isEditingImage || self.galleryFilePaths.count < 2) return;
    NSInteger destination = (NSInteger)_galleryIndex +
        (gesture.direction == UISwipeGestureRecognizerDirectionLeft ? 1 : -1);
    if (destination < 0 || destination >= (NSInteger)self.galleryFilePaths.count) return;
    [self showPhotoAtGalleryIndex:(NSUInteger)destination animated:YES];
}

- (void)showPhotoAtGalleryIndex:(NSUInteger)index animated:(BOOL)animated {
    if (index >= self.galleryFilePaths.count || _isEditingImage) return;
    NSString *path = self.galleryFilePaths[index];
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image) return;

    void (^applyPhoto)(void) = ^{
        self->_galleryIndex = index;
        self.image = image;
        self.filePath = path;
        self->_editSourceFilePath = [path copy];
        self.imagePrompt = EZGalleryPromptForPath(path);
        self->_originalImageForShare = image;
        self->_hasEditedImage = NO;
        [self->_editSourceImages removeAllObjects];
        [self->_editSourceImages addObject:image];
        [self->_editSourcePaths removeAllObjects];
        [self->_editSourcePaths addObject:path];
        while (self->_imageGridViews.count > 1) {
            UIImageView *extra = self->_imageGridViews.lastObject;
            [extra removeFromSuperview];
            [self->_imageGridViews removeLastObject];
        }
        self->_imageView.image = image;
        self->_imageCanvas.transform = CGAffineTransformIdentity;
        [self->_scrollView setZoomScale:1.0 animated:NO];
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    };
    if (animated) {
        [UIView transitionWithView:_imageCanvas duration:0.22
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionCurveEaseInOut
                        animations:applyPhoto completion:nil];
    } else {
        applyPhoto();
    }
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)askTapped {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:EZAttachImageToChat
                      object:nil
                    userInfo:@{ @"image": self.image }];
    [self dismissAllTheWay];
}

- (void)useInVideoGameTapped {
    UIViewController *presenter = self.navigationController.presentingViewController;
    if (!presenter) return;

    UIImage *selectedImage = self.image;
    [presenter dismissViewControllerAnimated:YES completion:^{
        BrainRotViewController *brainRot = [[BrainRotViewController alloc] init];
        brainRot.initialWorkshopImage = selectedImage;
        UINavigationController *gameNavigation =
            [[UINavigationController alloc] initWithRootViewController:brainRot];
        gameNavigation.modalPresentationStyle = UIModalPresentationPageSheet;
        [presenter presentViewController:gameNavigation animated:YES completion:nil];
    }];
}

- (void)shareTapped {
    __weak typeof(self) weakSelf = self;
    EZPresentPhotoExportPicker(self, _hasEditedImage && _originalImageForShare,
        ^{ [weakSelf shareGIFWithStyle:EZShareGIFStyleOriginalReveal]; },
        ^{ [weakSelf shareGIFWithStyle:EZShareGIFStyleMotionTransition]; },
        ^{ [weakSelf shareBrandedImageWithOriginalCard:YES]; },
        ^{ [weakSelf shareBrandedImageWithOriginalCard:NO]; },
        ^{ [weakSelf downloadTapped]; });
}

- (UIMenu *)shareMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *brandedShare = [UIAction actionWithTitle:@"Share Branded Image"
                                                  image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                             identifier:nil
                                                handler:^(__kindof UIAction *action) {
        [weakSelf shareBrandedImageWithOriginalCard:NO];
    }];
    UIAction *download = [UIAction actionWithTitle:@"Download Image"
                                              image:[UIImage systemImageNamed:@"arrow.down.to.line"]
                                         identifier:nil
                                            handler:^(__kindof UIAction *action) {
        [weakSelf downloadTapped];
    }];
    if (!_hasEditedImage || !_originalImageForShare) {
        return [UIMenu menuWithTitle:@"Export" children:@[brandedShare, download]];
    }
    UIAction *brandedShareWithOriginal =
        [UIAction actionWithTitle:@"Share Branded + Original"
                             image:[UIImage systemImageNamed:@"rectangle.inset.filled"]
                        identifier:nil
                           handler:^(__kindof UIAction *action) {
            [weakSelf shareBrandedImageWithOriginalCard:YES];
        }];
    UIAction *revealGIF = [UIAction actionWithTitle:@"GIF: Original Reveal"
                                               image:[UIImage systemImageNamed:@"rectangle.inset.filled.and.person.filled"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *action) {
        [weakSelf shareGIFWithStyle:EZShareGIFStyleOriginalReveal];
    }];
    UIAction *motionGIF = [UIAction actionWithTitle:@"GIF: Motion Transition"
                                               image:[UIImage systemImageNamed:@"sparkles.rectangle.stack"]
                                          identifier:nil
                                             handler:^(__kindof UIAction *action) {
        [weakSelf shareGIFWithStyle:EZShareGIFStyleMotionTransition];
    }];
    return [UIMenu menuWithTitle:@"Export" children:@[
        revealGIF, motionGIF, brandedShareWithOriginal, brandedShare, download
    ]];
}

- (void)shareBrandedImage {
    [self shareBrandedImageWithOriginalCard:_hasEditedImage];
}

- (void)shareBrandedImageWithOriginalCard:(BOOL)showOriginalCard {
    UIImage *brandedImage = [self shareImageWithBrandingForImage:self.image
                                                  showOriginalCard:showOriginalCard];
    id exportItem = brandedImage ?: self.image;
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[exportItem] applicationActivities:nil];
    share.popoverPresentationController.sourceView = _shareButton;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)shareGIFWithStyle:(EZShareGIFStyle)style {
    NSURL *gifURL = [self animatedShareGIFURLWithStyle:style];
    if (!gifURL) {
        // Never quietly substitute a JPEG for a requested GIF.  A static
        // fallback makes this look like the export worked while losing the
        // animation.  Leave the detail view in place and expose a small,
        // visible retry state instead.
        EZLog(EZLogLevelError, @"GALLERY", @"GIF export could not create its .gif file.");
        [_shareButton setImage:[UIImage systemImageNamed:@"exclamationmark.triangle"]
                      forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self->_shareButton setImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                  forState:UIControlStateNormal];
        });
        return;
    }
    // Keep the exact concrete file URL as the single activity item.  Do not
    // decode the GIF to NSData/UIImage and do not inspect it through
    // CGImageSource here: that validation was the source of a false negative
    // and silently routed successful GIF requests to the branded JPEG path.
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[gifURL] applicationActivities:nil];
    share.popoverPresentationController.sourceView = _shareButton;
    [self presentViewController:share animated:YES completion:nil];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                         configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                    previewProvider:nil
                                                     actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *save = [UIAction actionWithTitle:@"Save to Photos"
                                              image:[UIImage systemImageNamed:@"arrow.down.to.line"]
                                         identifier:nil
                                            handler:^(__kindof UIAction *action) {
            [self downloadTapped];
        }];
        UIMenu *menu = [self shareMenu];
        return [UIMenu menuWithTitle:menu.title children:[menu.children arrayByAddingObject:save]];
    }];
}

// Builds a lightweight, looping GIF for edited images. Both choices retain the
// prompt/branding; the reveal version ends with the original as a lower-right
// card, while the motion version creates a gentle camera-like transition.
- (NSURL *)animatedShareGIFURLWithStyle:(EZShareGIFStyle)style {
    if (!_hasEditedImage || !_originalImageForShare || !self.image) return nil;
    UIImage *before = [self shareImageWithBrandingForImage:_originalImageForShare showOriginalCard:NO];
    UIImage *after = [self shareImageWithBranding];
    if (!before.CGImage || !after.CGImage) return nil;

    CGFloat maxSide = 900.0;
    CGFloat scale = MIN(1.0, maxSide / MAX(after.size.width, after.size.height));
    CGSize frameSize = CGSizeMake(floor(after.size.width * scale), floor(after.size.height * scale));
    if (frameSize.width < 1 || frameSize.height < 1) return nil;

    NSMutableData *data = [NSMutableData data];
    // One opening frame + ten transition frames + one final frame + ten
    // reverse-transition frames.  This count must match the images added
    // below; declaring 14 (the old animation's count) makes ImageIO reject
    // finalization and leaves no file to share.
    const size_t frameCount = 22;
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)data, CFSTR("com.compuserve.gif"), frameCount, NULL);
    if (!destination) return nil;
    NSDictionary *gifProperties = @{(NSString *)kCGImagePropertyGIFDictionary: @{(NSString *)kCGImagePropertyGIFLoopCount: @0}};
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)gifProperties);

    void (^addFrame)(UIImage *, CGFloat) = ^(UIImage *image, CGFloat delay) {
        UIGraphicsBeginImageContextWithOptions(frameSize, YES, 1.0);
        [[UIColor colorWithRed:0.025 green:0.035 blue:0.085 alpha:1] setFill];
        UIRectFill((CGRect){CGPointZero, frameSize});
        CGFloat imageScale = MIN(frameSize.width / image.size.width, frameSize.height / image.size.height);
        CGSize size = CGSizeMake(image.size.width * imageScale, image.size.height * imageScale);
        [image drawInRect:CGRectMake((frameSize.width - size.width) / 2.0,
                                     (frameSize.height - size.height) / 2.0,
                                     size.width, size.height)];
        UIImage *frame = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        NSDictionary *frameProperties = @{
            (NSString *)kCGImagePropertyGIFDictionary: @{(NSString *)kCGImagePropertyGIFDelayTime: @(delay)}
        };
        CGImageDestinationAddImage(destination, frame.CGImage, (__bridge CFDictionaryRef)frameProperties);
    };

    addFrame(before, 0.85);
    for (NSInteger step = 1; step <= 10; step++) {
        CGFloat progress = step / 10.0;
        UIImage *frame = style == EZShareGIFStyleOriginalReveal
            ? [self originalRevealFrameForProgress:progress]
            : [self motionTransitionFrameFrom:before to:after progress:progress];
        addFrame(frame, 0.09);
    }
    addFrame(after, 1.15);
    for (NSInteger step = 9; step >= 0; step--) {
        CGFloat progress = step / 10.0;
        UIImage *frame = style == EZShareGIFStyleOriginalReveal
            ? [self originalRevealFrameForProgress:progress]
            : [self motionTransitionFrameFrom:before to:after progress:progress];
        addFrame(frame, 0.09);
    }

    if (!CGImageDestinationFinalize(destination)) {
        CFRelease(destination);
        return nil;
    }
    CFRelease(destination);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"EZCompleteUI-edit-%@.gif", NSUUID.UUID.UUIDString]];
    return [data writeToFile:path atomically:YES] ? [NSURL fileURLWithPath:path] : nil;
}

- (UIImage *)originalRevealFrameForProgress:(CGFloat)progress {
    UIImage *finalImage = [self shareImageWithBranding];
    if (!finalImage || !_originalImageForShare) return finalImage;
    CGFloat width = self.image.size.width;
    CGFloat border = MAX(12.0, width * 0.022);
    CGFloat headerHeight = MAX(58.0, width * 0.095);
    CGRect imageArea = CGRectMake(border, border + headerHeight,
                                  width - border * 2.0, self.image.size.height);
    CGRect cardRect = [self originalCardRectInImageArea:imageArea border:border];
    CGRect target = CGRectInset(cardRect, 4.0, 4.0);
    CGRect overlay = CGRectMake(imageArea.origin.x + (target.origin.x - imageArea.origin.x) * progress,
                                imageArea.origin.y + (target.origin.y - imageArea.origin.y) * progress,
                                imageArea.size.width + (target.size.width - imageArea.size.width) * progress,
                                imageArea.size.height + (target.size.height - imageArea.size.height) * progress);
    UIGraphicsBeginImageContextWithOptions(finalImage.size, YES, finalImage.scale);
    [finalImage drawAtPoint:CGPointZero];
    UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:overlay cornerRadius:12.0 * progress];
    [clip addClip];
    [_originalImageForShare drawInRect:EZAspectFitRect(_originalImageForShare.size, overlay)];
    UIImage *frame = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return frame;
}

- (UIImage *)motionTransitionFrameFrom:(UIImage *)before to:(UIImage *)after progress:(CGFloat)progress {
    CGSize size = after.size;
    UIGraphicsBeginImageContextWithOptions(size, YES, after.scale);
    CGRect bounds = (CGRect){CGPointZero, size};
    CGFloat beforeScale = 1.0 + progress * 0.055;
    CGRect beforeRect = CGRectInset(bounds, -size.width * (beforeScale - 1.0) / 2.0,
                                    -size.height * (beforeScale - 1.0) / 2.0);
    beforeRect.origin.x -= size.width * 0.035 * progress;
    [before drawInRect:EZAspectFillRect(before.size, beforeRect)];
    CGFloat afterScale = 1.055 - progress * 0.055;
    CGRect afterRect = CGRectInset(bounds, -size.width * (afterScale - 1.0) / 2.0,
                                   -size.height * (afterScale - 1.0) / 2.0);
    afterRect.origin.x += size.width * 0.035 * (1.0 - progress);
    [after drawInRect:EZAspectFillRect(after.size, afterRect)
            blendMode:kCGBlendModeNormal alpha:progress];
    UIImage *frame = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return frame;
}

- (void)downloadTapped {
    if (!self.image) return;
    _downloadButton.enabled = NO;
    UIImageWriteToSavedPhotosAlbum(self.image, self,
        @selector(image:didFinishSavingWithError:contextInfo:), NULL);
}

- (void)showImageSettings {
    EZImageSettingsViewController *settings = [EZImageSettingsViewController new];
    settings.modelIdentifier = @"gpt-image-2.5-sunburst";
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    if (@available(iOS 15.0, *)) {
        nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent];
        nav.sheetPresentationController.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error
 contextInfo:(void *)contextInfo {
    _downloadButton.enabled = YES;
    NSString *symbolName = error ? @"exclamationmark.triangle" : @"checkmark";
    [_downloadButton setImage:[UIImage systemImageNamed:symbolName] forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self->_downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.to.line"]
                                forState:UIControlStateNormal];
    });
}

// The reference card follows the source image's orientation.  A portrait
// original therefore remains a portrait card instead of being forced into a
// landscape slot and losing its top/bottom to an aspect-fill crop.
- (CGRect)originalCardRectInImageArea:(CGRect)imageArea border:(CGFloat)border {
    CGSize originalSize = _originalImageForShare.size;
    if (originalSize.width <= 0 || originalSize.height <= 0) return CGRectZero;
    CGFloat aspect = originalSize.width / originalSize.height;
    CGFloat maxWidth = MIN(CGRectGetWidth(imageArea) * 0.31, 300.0);
    CGFloat maxHeight = MIN(CGRectGetHeight(imageArea) * 0.34, 300.0);
    CGFloat cardWidth = maxWidth;
    CGFloat cardHeight = cardWidth / aspect;
    if (cardHeight > maxHeight) {
        cardHeight = maxHeight;
        cardWidth = cardHeight * aspect;
    }
    CGFloat cardInset = border * 1.25;
    return CGRectMake(CGRectGetMaxX(imageArea) - cardWidth - cardInset,
                      CGRectGetMaxY(imageArea) - cardHeight - cardInset,
                      cardWidth, cardHeight);
}

// Exports a self-contained presentation image without altering the original
// gallery asset.  Attachments that have no recorded generation prompt simply
// omit the bottom prompt card.
- (UIImage *)shareImageWithBranding {
    return [self shareImageWithBrandingForImage:self.image showOriginalCard:_hasEditedImage];
}

- (UIImage *)shareImageWithBrandingForImage:(UIImage *)source showOriginalCard:(BOOL)showOriginalCard {
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;

    NSString *prompt = [self.imagePrompt
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    CGFloat width = source.size.width;
    CGFloat border = MAX(12.0, width * 0.022);
    CGFloat headerHeight = MAX(58.0, width * 0.095);
    UIFont *captionFont = [UIFont systemFontOfSize:MAX(14.0, width * 0.024)
                                             weight:UIFontWeightMedium];
    NSMutableParagraphStyle *captionStyle = [[NSMutableParagraphStyle alloc] init];
    captionStyle.alignment = NSTextAlignmentCenter;
    captionStyle.lineBreakMode = NSLineBreakByWordWrapping;
    NSDictionary *captionAttributes = @{
        NSFontAttributeName: captionFont,
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.93 alpha:1],
        NSParagraphStyleAttributeName: captionStyle
    };
    CGFloat captionWidth = width - border * 2.0 - 36.0;
    CGRect captionBounds = prompt.length ? [prompt boundingRectWithSize:CGSizeMake(captionWidth, CGFLOAT_MAX)
                                                                  options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                               attributes:captionAttributes
                                                                  context:nil] : CGRectZero;
    // Allocate exactly the height the caption needs.  This deliberately does
    // not truncate long edit prompts in a branded export.
    CGFloat promptHeight = prompt.length ? MAX(62.0, ceil(CGRectGetHeight(captionBounds)) + 28.0) : 0.0;
    CGSize outputSize = CGSizeMake(width, source.size.height + headerHeight + promptHeight + border * 2.0);

    UIGraphicsBeginImageContextWithOptions(outputSize, YES, source.scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect outputRect = (CGRect){ .origin = CGPointZero, .size = outputSize };
    NSArray *colors = @[
        (id)[UIColor colorWithRed:0.08 green:0.86 blue:0.77 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.31 green:0.38 blue:1.00 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.88 green:0.24 blue:0.92 alpha:1].CGColor
    ];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)colors, NULL);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, 0),
                                CGPointMake(outputSize.width, outputSize.height), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);

    CGRect innerRect = CGRectInset(outputRect, border, border);
    [[UIColor colorWithRed:0.025 green:0.035 blue:0.085 alpha:1] setFill];
    UIRectFill(innerRect);

    NSDictionary *brandAttributes = @{
        NSFontAttributeName: [UIFont fontWithName:@"AvenirNext-DemiBoldItalic"
                                              size:MAX(19.0, width * 0.040)] ?: [UIFont boldSystemFontOfSize:22],
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSKernAttributeName: @(0.8)
    };
    [@"EZCompleteUI" drawAtPoint:CGPointMake(border * 2.0, border + (headerHeight - 28.0) / 2.0)
                    withAttributes:brandAttributes];

    CGRect imageArea = CGRectMake(border, border + headerHeight, width - border * 2.0, source.size.height);
    [source drawInRect:imageArea];

    if (prompt.length) {
        CGRect promptRect = CGRectMake(border, CGRectGetMaxY(imageArea), width - border * 2.0, promptHeight);
        [[UIColor colorWithWhite:1 alpha:0.075] setFill];
        UIRectFill(promptRect);
        [prompt drawInRect:CGRectInset(promptRect, 18.0, 14.0)
             withAttributes:captionAttributes];
    }

    // For an AI-edited result, keep a small, clearly labelled reference to
    // the image the edit began with.  It is part of the exported image only;
    // the gallery's original asset remains untouched.
    if (showOriginalCard && _originalImageForShare) {
        CGRect cardRect = [self originalCardRectInImageArea:imageArea border:border];
        UIBezierPath *outerPath = [UIBezierPath bezierPathWithRoundedRect:cardRect cornerRadius:12.0];
        CGContextSaveGState(context);
        [outerPath addClip];
        NSArray *cardColors = @[
            (id)[UIColor colorWithRed:0.08 green:0.86 blue:0.77 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.31 green:0.38 blue:1.00 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.88 green:0.24 blue:0.92 alpha:1].CGColor
        ];
        CGColorSpaceRef cardColorSpace = CGColorSpaceCreateDeviceRGB();
        CGGradientRef cardGradient = CGGradientCreateWithColors(cardColorSpace,
                                                                  (__bridge CFArrayRef)cardColors, NULL);
        CGContextDrawLinearGradient(context, cardGradient, cardRect.origin,
                                    CGPointMake(CGRectGetMaxX(cardRect), CGRectGetMaxY(cardRect)), 0);
        CGGradientRelease(cardGradient);
        CGColorSpaceRelease(cardColorSpace);
        CGContextRestoreGState(context);

        CGRect innerCard = CGRectInset(cardRect, 4.0, 4.0);
        UIBezierPath *innerPath = [UIBezierPath bezierPathWithRoundedRect:innerCard cornerRadius:9.0];
        CGContextSaveGState(context);
        [innerPath addClip];
        [[UIColor colorWithRed:0.025 green:0.035 blue:0.085 alpha:1] setFill];
        UIRectFill(innerCard);
        CGRect originalRect = EZAspectFitRect(_originalImageForShare.size, innerCard);
        [_originalImageForShare drawInRect:originalRect];
        CGContextRestoreGState(context);

        NSDictionary *originalLabelAttributes = @{
            NSFontAttributeName: [UIFont systemFontOfSize:MAX(9.0, width * 0.014) weight:UIFontWeightBold],
            NSForegroundColorAttributeName: [UIColor whiteColor],
            NSKernAttributeName: @(0.6)
        };
        [@"ORIGINAL" drawAtPoint:CGPointMake(CGRectGetMinX(cardRect) + 9.0,
                                               CGRectGetMinY(cardRect) + 8.0)
                    withAttributes:originalLabelAttributes];
    }

    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

- (void)deleteTapped {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Delete Photo"
                         message:@"This will permanently remove the photo from EZ Attachments."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_) {
        NSError *err;
        [[NSFileManager defaultManager] removeItemAtPath:self.filePath error:&err];
        if (self.onDeleted) self.onDeleted();
        [self dismiss];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = _deleteButton;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dismiss {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)dismissAllTheWay {
    // Dismiss the whole gallery sheet so the chat window is visible
    UIViewController *root = self.navigationController.presentingViewController;
    [root dismissViewControllerAnimated:YES completion:nil];
}

@end

// ── Gallery VC ────────────────────────────────────────────────────────────────

@interface EZPhotoGalleryViewController () <UICollectionViewDelegate,
                                             UICollectionViewDataSource,
                                             UICollectionViewDelegateFlowLayout,
                                             PHPickerViewControllerDelegate,
                                             UIDocumentPickerDelegate>
@property (nonatomic, strong) UICollectionView      *collectionView;
@property (nonatomic, strong) UICollectionViewFlowLayout *layout;
@property (nonatomic, strong) NSMutableArray<NSString *> *filePaths;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbnailCache;
@property (nonatomic, strong) NSOperationQueue      *loadQueue;
@property (nonatomic, assign) NSInteger              columnCount;
@property (nonatomic, strong) UILabel               *emptyLabel;
@property (nonatomic, strong) UILabel               *countLabel;
@property (nonatomic, strong) UIBarButtonItem       *selectButton;
@property (nonatomic, strong) UIBarButtonItem       *selectionMenuButton;
@property (nonatomic, assign) BOOL                   selectingPhotos;
@property (nonatomic, copy) NSArray<NSString *>     *musicVideoSourcePaths;
@property (nonatomic, strong) UIView                 *musicRenderingOverlay;
@property (nonatomic, strong) UIVisualEffectView     *musicRenderingBlur;
@property (nonatomic, strong) UIActivityIndicatorView *musicRenderingSpinner;
@property (nonatomic, strong) CAGradientLayer        *musicWaveLayer;
@end

@implementation EZPhotoGalleryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.columnCount = kDefaultColumns;
    self.filePaths   = [NSMutableArray array];
    self.thumbnailCache = [[NSCache alloc] init];
    self.thumbnailCache.countLimit = 200;
    self.loadQueue = [[NSOperationQueue alloc] init];
    self.loadQueue.maxConcurrentOperationCount = 4;
    self.loadQueue.qualityOfService = NSQualityOfServiceUserInitiated;

    [self styleNavBar];
    [self setupCollectionView];
    [self setupEmptyState];
    [self setupPinchGesture];
    [self loadFilePaths];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Includes edits saved by a pushed detail controller without requiring it
    // to mutate the gallery's data source directly.
    [self loadFilePaths];
}

- (void)styleNavBar {
    self.title = NSLocalizedString(@"EZGallery.Title", nil);

    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:1.0];
    appearance.titleTextAttributes = @{
        NSFontAttributeName:            [UIFont boldSystemFontOfSize:17],
        NSForegroundColorAttributeName: [UIColor whiteColor],
    };
    self.navigationController.navigationBar.standardAppearance   = appearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
    self.navigationController.navigationBar.tintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0];

    // The leading + imports images. Files exposes installed providers such as
    // Dropbox, Box, Google Drive, and any cloud-photo app with Files support.
    UIBarButtonItem *addItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"plus"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(addPhotosTapped)];
    addItem.tintColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];

    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeTapped)];
    closeItem.tintColor = [UIColor colorWithWhite:0.65 alpha:1];
    self.navigationItem.leftBarButtonItems = @[addItem, closeItem];

    // Count label plus an explicit multi-select entry point.
    self.countLabel = [[UILabel alloc] init];
    self.countLabel.font      = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.countLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    UIBarButtonItem *countItem = [[UIBarButtonItem alloc] initWithCustomView:self.countLabel];
    self.selectButton = [[UIBarButtonItem alloc]
        initWithTitle:NSLocalizedString(@"EZGallery.Select", nil)
                style:UIBarButtonItemStylePlain target:self action:@selector(selectTapped)];
    self.navigationItem.rightBarButtonItems = @[self.selectButton, countItem];
}

- (void)setupCollectionView {
    self.layout = [[UICollectionViewFlowLayout alloc] init];
    self.layout.minimumInteritemSpacing = kCellSpacing;
    self.layout.minimumLineSpacing      = kCellSpacing;
    self.layout.sectionInset            = UIEdgeInsetsZero;

    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds
                                             collectionViewLayout:self.layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor  = [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:1.0];
    self.collectionView.delegate         = self;
    self.collectionView.dataSource       = self;
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.allowsMultipleSelection = YES;
    [self.collectionView registerClass:[EZGalleryCell class] forCellWithReuseIdentifier:kGalleryCellID];
    [self.view addSubview:self.collectionView];
}

- (void)setupEmptyState {
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text          = @"No media yet.\nImages, GIFs, and videos saved from chats appear here.";
    self.emptyLabel.numberOfLines = 2;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font          = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    self.emptyLabel.textColor     = [UIColor colorWithWhite:0.4 alpha:1];
    self.emptyLabel.hidden        = YES;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor
                                                              constant:-60],
    ]];
}

- (void)setupPinchGesture {
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePinch:)];
    [self.collectionView addGestureRecognizer:pinch];
}

// ── File loading ──────────────────────────────────────────────────────────────

- (NSString *)attachmentsPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:kPhotoGalleryDir];
}

- (void)migrateLegacyGalleryImagesIfNeeded {
    static NSString *const kGalleryMigrationKey = @"EZPhotoGalleryMigratedLegacyImages";
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kGalleryMigrationKey]) return;

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *legacyDirectory = [docs stringByAppendingPathComponent:kLegacyAttachmentsDir];
    NSArray<NSString *> *legacyFiles = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:legacyDirectory error:nil] ?: @[];
    NSSet<NSString *> *imageExtensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"heic", @"gif", @"webp", @"tiff", @"bmp"]];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in legacyFiles) {
        if (![imageExtensions containsObject:name.pathExtension.lowercaseString]) continue;
        NSString *legacyPath = [legacyDirectory stringByAppendingPathComponent:name];
        NSString *galleryPath = [[self attachmentsPath] stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:galleryPath]) {
            // Copy first: old thread records can still contain the legacy
            // absolute path. New image writes never enter this directory.
            [fm copyItemAtPath:legacyPath toPath:galleryPath error:nil];
        }
    }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kGalleryMigrationKey];
}

- (void)loadFilePaths {
    NSString *dir = [self attachmentsPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [self migrateLegacyGalleryImagesIfNeeded];
    NSArray<NSString *> *all = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:dir error:nil] ?: @[];

    NSArray<NSString *> *imageExts = @[@"jpg", @"jpeg", @"png", @"heic", @"gif", @"webp", @"tiff", @"bmp"];
    NSArray<NSString *> *videoExts = @[@"mov", @"mp4", @"m4v", @"avi"];
    NSMutableArray *paths = [NSMutableArray array];
    NSMutableSet<NSString *> *seenDigests = [NSMutableSet set];
    for (NSString *name in all) {
        if ([imageExts containsObject:name.pathExtension.lowercaseString] ||
            [videoExts containsObject:name.pathExtension.lowercaseString]) {
            NSString *path = [dir stringByAppendingPathComponent:name];
            NSString *digest = EZGalleryContentDigest(path);
            if (digest.length && [seenDigests containsObject:digest]) {
                EZLogf(EZLogLevelInfo, @"GALLERY", @"Hiding duplicate image %@", name);
                continue;
            }
            if (digest.length) [seenDigests addObject:digest];
            [paths addObject:path];
        }
    }

    // Sort newest first (by modification date)
    NSFileManager *fm = [NSFileManager defaultManager];
    [paths sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [fm attributesOfItemAtPath:a error:nil][NSFileModificationDate] ?: [NSDate distantPast];
        NSDate *db = [fm attributesOfItemAtPath:b error:nil][NSFileModificationDate] ?: [NSDate distantPast];
        return [db compare:da];
    }];

    self.filePaths = paths;
    [self.collectionView reloadData];

    NSInteger count = paths.count;
    self.countLabel.text = count == 0 ? @"" :
        [NSString stringWithFormat:@"%ld %@", (long)count, count == 1 ? @"item" : @"items"];
    self.emptyLabel.hidden = count > 0;
}

// ── Pinch to resize grid ──────────────────────────────────────────────────────

- (void)handlePinch:(UIPinchGestureRecognizer *)pinch {
    static NSInteger startColumns;

    if (pinch.state == UIGestureRecognizerStateBegan) {
        startColumns = self.columnCount;
    }

    if (pinch.state == UIGestureRecognizerStateChanged ||
        pinch.state == UIGestureRecognizerStateEnded) {

        // Pinch out (scale > 1) → fewer columns (bigger cells)
        // Pinch in  (scale < 1) → more columns (smaller cells)
        NSInteger newCols = (NSInteger)round(startColumns / pinch.scale);
        newCols = MAX(kMinColumns, MIN(kMaxColumns, newCols));

        if (newCols != self.columnCount) {
            self.columnCount = newCols;
            [UIView animateWithDuration:0.2 animations:^{
                [self.collectionView performBatchUpdates:^{
                    [self.layout invalidateLayout];
                } completion:nil];
            }];

            // Haptic tick
            UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleLight];
            [haptic impactOccurred];
        }
    }
}

// ── UICollectionView ──────────────────────────────────────────────────────────

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return self.filePaths.count;
}

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat total = cv.bounds.size.width - kCellSpacing * (self.columnCount - 1);
    CGFloat side  = floor(total / self.columnCount);
    return CGSizeMake(side, side);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    EZGalleryCell *cell = [cv dequeueReusableCellWithReuseIdentifier:kGalleryCellID
                                                        forIndexPath:indexPath];
    NSString *path = self.filePaths[indexPath.item];
    UIImage  *cached = [self.thumbnailCache objectForKey:path];

    if (cached) {
        [cell setImage:cached];
    } else {
        [cell startShimmer];
        CGFloat side = [self collectionView:cv layout:cv.collectionViewLayout
                     sizeForItemAtIndexPath:indexPath].width * UIScreen.mainScreen.scale;

        NSIndexPath *ip = indexPath;
        [self.loadQueue addOperationWithBlock:^{
            UIImage *thumb = [self thumbnailForPath:path side:side];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (thumb) [self.thumbnailCache setObject:thumb forKey:path];
                EZGalleryCell *visible = (EZGalleryCell *)[cv cellForItemAtIndexPath:ip];
                if (visible) [visible setImage:thumb];
            });
        }];
    }
    return cell;
}

- (UIImage *)thumbnailForPath:(NSString *)path side:(CGFloat)side {
    NSString *ext = path.pathExtension.lowercaseString;
    if ([@[@"mov", @"mp4", @"m4v", @"avi"] containsObject:ext]) {
        AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil]];
        generator.appliesPreferredTrackTransform = YES;
        generator.maximumSize = CGSizeMake(side, side);
        CGImageRef frame = [generator copyCGImageAtTime:kCMTimeZero actualTime:nil error:nil];
        UIImage *image = frame ? [UIImage imageWithCGImage:frame] : nil;
        if (frame) CGImageRelease(frame);
        return image;
    }
    UIImage *full = [UIImage imageWithContentsOfFile:path];
    if (!full) return nil;
    CGSize  sz     = CGSizeMake(side, side);
    UIGraphicsBeginImageContextWithOptions(sz, YES, 0);
    CGFloat scale  = MAX(sz.width / full.size.width, sz.height / full.size.height);
    CGFloat w      = full.size.width  * scale;
    CGFloat h      = full.size.height * scale;
    [full drawInRect:CGRectMake((sz.width - w) / 2, (sz.height - h) / 2, w, h)];
    UIImage *thumb = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return thumb;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.selectingPhotos) {
        [self updateSelectionControls];
        return;
    }
    NSString *path  = self.filePaths[indexPath.item];
    if ([@[@"mov", @"mp4", @"m4v", @"avi"] containsObject:path.pathExtension.lowercaseString]) {
        AVPlayerViewController *player = [AVPlayerViewController new];
        player.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:path]];
        [self presentViewController:player animated:YES completion:^{ [player.player play]; }];
        return;
    }
    UIImage  *image = [UIImage imageWithContentsOfFile:path];
    if (!image) return;

    if (self.onSelectImage) {
        self.onSelectImage(image);
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    EZPhotoDetailViewController *detail = [EZPhotoDetailViewController new];
    detail.image    = image;
    detail.filePath = path;
    detail.imagePrompt = EZGalleryPromptForPath(path);
    detail.galleryFilePaths = [self.filePaths copy];
    detail.galleryIndex = indexPath.item;

    __weak typeof(self) weakSelf = self;
    detail.onDeleted = ^{
        [weakSelf loadFilePaths];
    };

    [self.navigationController pushViewController:detail animated:YES];
}

- (void)collectionView:(UICollectionView *)collectionView didDeselectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.selectingPhotos) [self updateSelectionControls];
}

- (void)selectTapped {
    self.selectingPhotos = !self.selectingPhotos;
    if (!self.selectingPhotos) [self.collectionView selectItemAtIndexPath:nil animated:NO scrollPosition:UICollectionViewScrollPositionNone];
    [self updateSelectionControls];
}

- (void)updateSelectionControls {
    if (!self.selectingPhotos) {
        [self.collectionView.indexPathsForSelectedItems enumerateObjectsUsingBlock:^(NSIndexPath *path, NSUInteger idx, BOOL *stop) {
            [self.collectionView deselectItemAtIndexPath:path animated:NO];
        }];
        self.selectButton.title = NSLocalizedString(@"EZGallery.Select", nil);
        UIBarButtonItem *countItem = [[UIBarButtonItem alloc] initWithCustomView:self.countLabel];
        self.navigationItem.rightBarButtonItems = @[self.selectButton, countItem];
        return;
    }
    NSUInteger count = self.collectionView.indexPathsForSelectedItems.count;
    self.selectButton.title = NSLocalizedString(@"EZGallery.Done", nil);
    __weak typeof(self) weakSelf = self;
    UIAction *share = [UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf shareSelectedTapped];
    }];
    UIAction *musicVideo = [UIAction actionWithTitle:@"Make Music Video" image:[UIImage systemImageNamed:@"film.stack"] identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf makeMusicVideoTapped];
    }];
    UIAction *delete = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__kindof UIAction *action) {
        [weakSelf deleteSelectedTapped];
    }];
    if (count == 0) {
        share.attributes = UIMenuElementAttributesDisabled;
        musicVideo.attributes = UIMenuElementAttributesDisabled;
        delete.attributes = UIMenuElementAttributesDisabled;
    }
    delete.attributes |= UIMenuElementAttributesDestructive;
    UIMenu *menu = [UIMenu menuWithTitle:@"Selected Media" children:@[share, musicVideo, delete]];
    self.selectionMenuButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:menu];
    self.countLabel.text = [NSString stringWithFormat:NSLocalizedString(@"EZGallery.SelectedCount", nil), (unsigned long)count];
    self.navigationItem.rightBarButtonItems = @[self.selectionMenuButton, self.selectButton];
}

- (NSArray<NSString *> *)selectedPhotoPaths {
    NSArray<NSIndexPath *> *selected = [self.collectionView.indexPathsForSelectedItems sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:selected.count];
    for (NSIndexPath *indexPath in selected) {
        if ((NSUInteger)indexPath.item < self.filePaths.count) [paths addObject:self.filePaths[(NSUInteger)indexPath.item]];
    }
    return paths;
}

- (void)shareSelectedTapped {
    NSArray<NSString *> *paths = [self selectedPhotoPaths];
    if (!paths.count) return;
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString *path in paths) [urls addObject:[NSURL fileURLWithPath:path]];
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = self.selectionMenuButton;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)startMusicRenderingOverlay {
    if (self.musicRenderingOverlay) return;
    EZKeepDeviceAwakeBegin(@"Music video rendering");
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithRed:0.03 green:0.10 blue:0.18 alpha:0.18];
    overlay.clipsToBounds = YES;
    self.musicRenderingOverlay = overlay;
    [self.view addSubview:overlay];

    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    self.musicRenderingBlur = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.musicRenderingBlur.frame = overlay.bounds;
    self.musicRenderingBlur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.musicRenderingBlur.alpha = 0;
    [overlay addSubview:self.musicRenderingBlur];

    self.musicRenderingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.musicRenderingSpinner.color = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    self.musicRenderingSpinner.transform = CGAffineTransformMakeScale(1.7, 1.7);
    self.musicRenderingSpinner.center = CGPointMake(CGRectGetMidX(overlay.bounds), CGRectGetMidY(overlay.bounds) - 24);
    self.musicRenderingSpinner.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [overlay addSubview:self.musicRenderingSpinner];
    [self.musicRenderingSpinner startAnimating];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(28, CGRectGetMidY(overlay.bounds) + 20, overlay.bounds.size.width - 56, 54)];
    label.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleWidth;
    label.text = @"MAKING MUSIC VIDEO…\nLooping visuals • syncing audio";
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter; label.numberOfLines = 2;
    [overlay addSubview:label];

    self.musicWaveLayer = [CAGradientLayer layer];
    self.musicWaveLayer.frame = CGRectInset(overlay.bounds, -overlay.bounds.size.width, 0);
    self.musicWaveLayer.startPoint = CGPointMake(0, .5); self.musicWaveLayer.endPoint = CGPointMake(1, .5);
    self.musicWaveLayer.colors = @[(id)UIColor.clearColor.CGColor,
        (id)[UIColor colorWithRed:0 green:.95 blue:.74 alpha:.07].CGColor,
        (id)[UIColor colorWithRed:.20 green:.45 blue:1 alpha:.34].CGColor,
        (id)[UIColor colorWithRed:0 green:.95 blue:.74 alpha:.07].CGColor, (id)UIColor.clearColor.CGColor];
    self.musicWaveLayer.locations = @[@0, @.30, @.50, @.70, @1];
    self.musicWaveLayer.compositingFilter = @"screenBlendMode";
    [overlay.layer addSublayer:self.musicWaveLayer];
    CABasicAnimation *wave = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    wave.fromValue = @(-overlay.bounds.size.width); wave.toValue = @(overlay.bounds.size.width);
    wave.duration = 1.65; wave.repeatCount = HUGE_VALF;
    wave.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.musicWaveLayer addAnimation:wave forKey:@"ez.music.wave"];
    [UIView animateWithDuration:.45 animations:^{ self.musicRenderingBlur.alpha = .90; }];
}

- (void)stopMusicRenderingOverlay {
    UIView *overlay = self.musicRenderingOverlay;
    if (!overlay) return;
    [UIView animateWithDuration:.25 animations:^{ overlay.alpha = 0; } completion:^(__unused BOOL done) { [overlay removeFromSuperview]; }];
    self.musicRenderingOverlay = nil; self.musicRenderingBlur = nil; self.musicRenderingSpinner = nil; self.musicWaveLayer = nil;
    EZKeepDeviceAwakeEnd();
}

// A deliberately quick first-pass editor: selected visual clips are sequenced
// (and repeated as needed), their source audio is never copied, and the chosen
// music track defines the final duration exactly.
- (void)makeMusicVideoTapped {
    NSArray<NSString *> *paths = [self selectedPhotoPaths];
    if (!paths.count) return;
    self.musicVideoSourcePaths = paths;
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"Make Music Video"
        message:@"Choose one audio track. Photos, GIFs, and videos will repeat in selection order until the music ends; original clip audio is removed."
        preferredStyle:UIAlertControllerStyleAlert];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Attach Audio" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[UTTypeAudio] asCopy:YES];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }]];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { self.musicVideoSourcePaths = nil; }]];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (void)renderMusicVideoWithAudioURL:(NSURL *)audioURL sources:(NSArray<NSString *> *)paths {
    AVURLAsset *audioAsset = [AVURLAsset URLAssetWithURL:audioURL options:nil];
    Float64 seconds = CMTimeGetSeconds(audioAsset.duration);
    if (!isfinite(seconds) || seconds <= 0) { self.musicVideoSourcePaths = nil; return; }
    [self startMusicRenderingOverlay];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Fast-cut preset: video does the heavy lifting here, so lower its
        // frame count and canvas before touching the music track. This cuts a
        // five-minute render from ~7,200 frames to ~3,600 and reduces each
        // frame's pixel work by over 2×, while audio remains untouched.
        NSInteger fps = 12;
        NSInteger outputWidth = 480;
        NSInteger outputHeight = 854;
        NSString *dir = [self attachmentsPath];
        NSString *tempPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"render-%@.mp4", NSUUID.UUID.UUIDString]];
        NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
        AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:tempURL fileType:AVFileTypeMPEG4 error:nil];
        NSDictionary *settings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(outputWidth), AVVideoHeightKey: @(outputHeight),
            AVVideoCompressionPropertiesKey: @{ AVVideoAverageBitRateKey: @1800000 }
        };
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
        input.expectsMediaDataInRealTime = NO;
        NSDictionary *pixelAttrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferWidthKey: @(outputWidth), (id)kCVPixelBufferHeightKey: @(outputHeight) };
        AVAssetWriterInputPixelBufferAdaptor *adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:input sourcePixelBufferAttributes:pixelAttrs];
        if (![writer canAddInput:input]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf stopMusicRenderingOverlay]; weakSelf.musicVideoSourcePaths = nil; });
            return;
        }
        [writer addInput:input];
        [writer startWriting]; [writer startSessionAtSourceTime:kCMTimeZero];
        NSMutableArray *generators = [NSMutableArray array];
        NSMutableArray<NSNumber *> *durations = [NSMutableArray array];
        for (NSString *path in paths) {
            BOOL video = [@[@"mov", @"mp4", @"m4v", @"avi"] containsObject:path.pathExtension.lowercaseString];
            AVAssetImageGenerator *generator = video ? [[AVAssetImageGenerator alloc] initWithAsset:[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil]] : nil;
            generator.appliesPreferredTrackTransform = YES;
            [generators addObject:generator ?: (id)[NSNull null]];
            Float64 d = video ? CMTimeGetSeconds(generator.asset.duration) : 3.0;
            [durations addObject:@(MAX(0.5, MIN(d, 12.0)))];
        }
        NSInteger totalFrames = (NSInteger)ceil(seconds * fps);
        for (NSInteger frameIndex = 0; frameIndex < totalFrames; frameIndex++) {
            Float64 timeline = frameIndex / (Float64)fps, cursor = 0; NSUInteger sourceIndex = 0;
            while (timeline >= cursor + durations[sourceIndex].doubleValue) { cursor += durations[sourceIndex].doubleValue; sourceIndex = (sourceIndex + 1) % paths.count; }
            NSString *path = paths[sourceIndex]; CGImageRef image = nil;
            AVAssetImageGenerator *generator = (id)generators[sourceIndex];
            if ((id)generator != (id)[NSNull null]) {
                image = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(timeline - cursor, 600) actualTime:nil error:nil];
            } else {
                CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
                if (source) {
                    size_t frameCount = CGImageSourceGetCount(source);
                    size_t gifFrame = frameCount > 1 ? (size_t)floor(fmod((timeline - cursor), durations[sourceIndex].doubleValue) / durations[sourceIndex].doubleValue * frameCount) : 0;
                    image = CGImageSourceCreateImageAtIndex(source, MIN(gifFrame, frameCount - 1), NULL);
                    CFRelease(source);
                }
            }
            CVPixelBufferRef buffer = NULL;
            if (!image || CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) != kCVReturnSuccess) { if (image) CGImageRelease(image); continue; }
            CVPixelBufferLockBaseAddress(buffer, 0);
            CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), outputWidth, outputHeight, 8, CVPixelBufferGetBytesPerRow(buffer), CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            CGContextSetRGBFillColor(ctx, 0, 0, 0, 1); CGContextFillRect(ctx, CGRectMake(0, 0, outputWidth, outputHeight));
            CGSize s = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image)); CGRect draw = EZAspectFillRect(s, CGRectMake(0, 0, outputWidth, outputHeight));
            CGContextDrawImage(ctx, draw, image); CGContextRelease(ctx); CVPixelBufferUnlockBaseAddress(buffer, 0); CGImageRelease(image);
            while (!input.readyForMoreMediaData) { [NSThread sleepForTimeInterval:0.002]; }
            [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(frameIndex, fps)]; CVPixelBufferRelease(buffer);
        }
        [input markAsFinished]; [writer finishWritingWithCompletionHandler:^{
            AVMutableComposition *mix = [AVMutableComposition composition];
            AVAssetTrack *video = [[AVURLAsset URLAssetWithURL:tempURL options:nil] tracksWithMediaType:AVMediaTypeVideo].firstObject;
            AVAssetTrack *audio = [audioAsset tracksWithMediaType:AVMediaTypeAudio].firstObject;
            NSError *err = nil;
            AVMutableCompositionTrack *videoTrack = [mix addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
            [videoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(seconds, 600)) ofTrack:video atTime:kCMTimeZero error:&err];
            if (audio) {
                AVMutableCompositionTrack *audioTrack = [mix addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
                [audioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(seconds, 600)) ofTrack:audio atTime:kCMTimeZero error:nil];
            }
            NSString *finalPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"music-video-%@.mp4", NSUUID.UUID.UUIDString]];
            AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:mix presetName:AVAssetExportPresetHighestQuality]; exporter.outputURL = [NSURL fileURLWithPath:finalPath]; exporter.outputFileType = AVFileTypeMPEG4;
            [exporter exportAsynchronouslyWithCompletionHandler:^{ dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf; [self stopMusicRenderingOverlay]; self.musicVideoSourcePaths = nil;
                if (exporter.status == AVAssetExportSessionStatusCompleted) { [self loadFilePaths]; UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[exporter.outputURL] applicationActivities:nil]; [self presentViewController:share animated:YES completion:nil]; }
                else { UIAlertController *failure = [UIAlertController alertControllerWithTitle:@"Couldn’t make video" message:exporter.error.localizedDescription ?: @"Please try different media." preferredStyle:UIAlertControllerStyleAlert]; [failure addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:failure animated:YES completion:nil]; }
            }); }];
        }];
    });
}

- (void)deleteSelectedTapped {
    NSArray<NSString *> *paths = [self selectedPhotoPaths];
    if (!paths.count) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"EZGallery.DeleteTitle", nil)
        message:[NSString stringWithFormat:NSLocalizedString(@"EZGallery.DeleteMessage", nil), (unsigned long)paths.count]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZGallery.Delete", nil) style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *path in paths) [fm removeItemAtPath:path error:nil];
        [self.thumbnailCache removeAllObjects];
        self.selectingPhotos = NO;
        [self loadFilePaths];
        [self updateSelectionControls];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZGallery.Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ── Close ─────────────────────────────────────────────────────────────────────

- (void)addPhotosTapped {
    __weak typeof(self) weakSelf = self;
    EZPresentPhotoSourcePicker(self, ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
        configuration.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]]];
        configuration.selectionLimit = 0; // Native Photos supports multi-select.
        PHPickerViewController *picker = [[PHPickerViewController alloc]
            initWithConfiguration:configuration];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }, ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[UTTypeImage, UTTypeMovie, UTTypeGIF] asCopy:YES];
        picker.delegate = self;
        picker.allowsMultipleSelection = YES;
        [self presentViewController:picker animated:YES completion:nil];
    }, nil);
}

- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    for (PHPickerResult *result in results) {
        NSItemProvider *provider = result.itemProvider;
        if ([provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
            [provider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *error) {
                NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
                if (!data.length) return;
                dispatch_async(dispatch_get_main_queue(), ^{ if (EZPhotoGallerySave(data, @"photo_video.mov")) [self loadFilePaths]; });
            }];
            continue;
        }
        if ([provider hasItemConformingToTypeIdentifier:UTTypeGIF.identifier]) {
            [provider loadFileRepresentationForTypeIdentifier:UTTypeGIF.identifier completionHandler:^(NSURL *url, NSError *error) {
                NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
                if (!data.length) return;
                dispatch_async(dispatch_get_main_queue(), ^{ if (EZPhotoGallerySave(data, @"photo_import.gif")) [self loadFilePaths]; });
            }];
            continue;
        }
        if (![provider canLoadObjectOfClass:[UIImage class]]) continue;
        [provider loadObjectOfClass:[UIImage class]
                 completionHandler:^(__kindof id<NSItemProviderReading> object, NSError *error) {
            UIImage *image = [object isKindOfClass:[UIImage class]] ? object : nil;
            NSData *data = image ? UIImagePNGRepresentation(image) : nil;
            if (!data.length) {
                EZLogf(EZLogLevelWarning, @"GALLERY", @"Could not import a selected Photos image: %@", error);
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (EZPhotoGallerySave(data, @"photo_import.png")) [self loadFilePaths];
            });
        }];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.musicVideoSourcePaths.count) {
        NSURL *audioURL = urls.firstObject;
        if (audioURL) [self renderMusicVideoWithAudioURL:audioURL sources:self.musicVideoSourcePaths];
        else self.musicVideoSourcePaths = nil;
        return;
    }
    for (NSURL *url in urls) {
        BOOL accessed = [url startAccessingSecurityScopedResource];
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (accessed) [url stopAccessingSecurityScopedResource];
        if (!data.length) {
            EZLogf(EZLogLevelWarning, @"GALLERY", @"Could not import image from %@", url.lastPathComponent);
            continue;
        }
        NSString *filename = url.lastPathComponent.length ? url.lastPathComponent : @"cloud_photo";
        EZPhotoGallerySave(data, filename);
    }
    [self loadFilePaths];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
