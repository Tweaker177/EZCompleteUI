//
//  EZImageGridCell.m
//  EZCompleteUI

#import "EZImageGridCell.h"

// ── Layout constants ──────────────────────────────────────────────────────────

static CGFloat const kIGCPad         = 12.0;
static CGFloat const kIGCGap         = 4.0;
static CGFloat const kIGCPromptH     = 40.0;
static CGFloat const kIGCShareAllH   = 40.0;
static CGFloat const kIGCCorner      = 12.0;
static CGFloat const kIGCCardPad     = 16.0;  // left/right margin from cell edge

// ── Full-screen image viewer ──────────────────────────────────────────────────

@interface EZFullScreenImageVC : UIViewController
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIImageView  *imageView;
@end

@implementation EZFullScreenImageVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.minimumZoomScale = 1.0;
    self.scrollView.maximumZoomScale = 6.0;
    self.scrollView.delegate = (id<UIScrollViewDelegate>)self;
    self.scrollView.showsVerticalScrollIndicator   = NO;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];

    self.imageView = [[UIImageView alloc] initWithImage:self.image];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.scrollView addSubview:self.imageView];

    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissSelf)];
    singleTap.numberOfTapsRequired = 1;
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    [singleTap requireGestureRecognizerToFail:doubleTap];
    [self.scrollView addGestureRecognizer:singleTap];
    [self.scrollView addGestureRecognizer:doubleTap];

    // Close button
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:cfg]
           forState:UIControlStateNormal];
    close.tintColor = [UIColor colorWithWhite:0.8 alpha:1];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
    [NSLayoutConstraint activateConstraints:@[
        [close.topAnchor    constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [close.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [close.widthAnchor  constraintEqualToConstant:44],
        [close.heightAnchor constraintEqualToConstant:44],
    ]];

    // Share button
    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    [share setImage:[UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:cfg]
           forState:UIControlStateNormal];
    share.tintColor = [UIColor colorWithWhite:0.8 alpha:1];
    share.translatesAutoresizingMaskIntoConstraints = NO;
    [share addTarget:self action:@selector(shareTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:share];
    [NSLayoutConstraint activateConstraints:@[
        [share.topAnchor    constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [share.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [share.widthAnchor  constraintEqualToConstant:44],
        [share.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.scrollView.frame = self.view.bounds;
    CGSize imgSize = self.image.size;
    if (imgSize.width > 0 && imgSize.height > 0) {
        CGFloat scale = MIN(self.view.bounds.size.width  / imgSize.width,
                            self.view.bounds.size.height / imgSize.height);
        self.imageView.frame = CGRectMake(0, 0, imgSize.width * scale, imgSize.height * scale);
        self.scrollView.contentSize = self.imageView.frame.size;
        self.imageView.center = CGPointMake(self.scrollView.bounds.size.width / 2,
                                            self.scrollView.bounds.size.height / 2);
    }
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)sv { return self.imageView; }

- (void)scrollViewDidZoom:(UIScrollView *)sv {
    CGSize  bounds = sv.bounds.size;
    CGRect  frame  = self.imageView.frame;
    frame.origin.x = frame.size.width  < bounds.width  ? (bounds.width  - frame.size.width)  / 2 : 0;
    frame.origin.y = frame.size.height < bounds.height ? (bounds.height - frame.size.height) / 2 : 0;
    self.imageView.frame = frame;
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    if (self.scrollView.zoomScale > 1.0) {
        [self.scrollView setZoomScale:1.0 animated:YES];
    } else {
        CGPoint pt   = [tap locationInView:self.imageView];
        CGRect  rect = CGRectMake(pt.x - 80, pt.y - 80, 160, 160);
        [self.scrollView zoomToRect:rect animated:YES];
    }
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)shareTapped:(UIButton *)btn {
    if (!self.image) return;
    UIActivityViewController *ac = [[UIActivityViewController alloc]
        initWithActivityItems:@[self.image] applicationActivities:nil];
    ac.popoverPresentationController.sourceView = btn;
    [self presentViewController:ac animated:YES completion:nil];
}

@end

// ── EZImageGridCell ───────────────────────────────────────────────────────────

@interface EZImageGridCell ()
@property (nonatomic, strong) UIView               *cardView;
@property (nonatomic, strong) UILabel              *promptLabel;
@property (nonatomic, strong) UILabel              *errorLabel;
@property (nonatomic, strong) UIImageView          *errorIcon;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *imageViews;
@property (nonatomic, strong) NSMutableArray<UIButton *>    *shareButtons;
@property (nonatomic, strong) UIButton             *shareAllButton;
@property (nonatomic, strong) NSArray<NSString *>  *currentPaths;
@property (nonatomic, weak)   UIViewController     *presenter;
@end

@implementation EZImageGridCell

// ── Height helper ─────────────────────────────────────────────────────────────

+ (CGFloat)heightForImageCount:(NSInteger)count
                    tableWidth:(CGFloat)width
                       isError:(BOOL)isError {
    if (isError) return kIGCPad + kIGCPromptH + 70 + kIGCPad;

    CGFloat cardW   = width - kIGCCardPad * 2;
    CGFloat imgAreaW = cardW - kIGCPad * 2;
    CGFloat imageH;

    if (count <= 1) {
        imageH = floor(imgAreaW * 0.75);
    } else if (count == 2) {
        CGFloat side = floor((imgAreaW - kIGCGap) / 2);
        imageH = side;
    } else { // 4
        CGFloat side = floor((imgAreaW - kIGCGap) / 2);
        imageH = side * 2 + kIGCGap;
    }

    CGFloat shareAllH = count > 1 ? kIGCShareAllH + kIGCPad : 0;
    return kIGCPad + kIGCPromptH + kIGCPad + imageH + kIGCPad + shareAllH + kIGCPad;
}

// ── Init ──────────────────────────────────────────────────────────────────────

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle  = UITableViewCellSelectionStyleNone;
        self.imageViews   = [NSMutableArray array];
        self.shareButtons = [NSMutableArray array];

        // Card
        self.cardView = [[UIView alloc] init];
        self.cardView.backgroundColor    = [UIColor colorWithRed:0.09 green:0.09 blue:0.14 alpha:1.0];
        self.cardView.layer.cornerRadius = kIGCCorner;
        self.cardView.layer.borderWidth  = 0.5;
        self.cardView.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
        self.cardView.layer.shadowColor  = [UIColor blackColor].CGColor;
        self.cardView.layer.shadowOpacity = 0.3;
        self.cardView.layer.shadowOffset  = CGSizeMake(0, 4);
        self.cardView.layer.shadowRadius  = 10;
        self.cardView.clipsToBounds      = NO;
        [self.contentView addSubview:self.cardView];

        // Prompt label
        self.promptLabel = [[UILabel alloc] init];
        self.promptLabel.font          = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        self.promptLabel.textColor     = [UIColor colorWithWhite:0.55 alpha:1];
        self.promptLabel.numberOfLines = 2;
        [self.cardView addSubview:self.promptLabel];

        // Error icon + label
        UIImageSymbolConfiguration *errCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:28 weight:UIImageSymbolWeightLight];
        self.errorIcon = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"exclamationmark.triangle" withConfiguration:errCfg]];
        self.errorIcon.tintColor = [UIColor systemOrangeColor];
        self.errorIcon.hidden    = YES;
        [self.cardView addSubview:self.errorIcon];

        self.errorLabel = [[UILabel alloc] init];
        self.errorLabel.font          = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        self.errorLabel.textColor     = [UIColor colorWithRed:1.0 green:0.45 blue:0.3 alpha:1.0];
        self.errorLabel.numberOfLines = 3;
        self.errorLabel.hidden        = YES;
        [self.cardView addSubview:self.errorLabel];

        // Share-all button
        self.shareAllButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.shareAllButton.backgroundColor    = [UIColor colorWithWhite:1 alpha:0.07];
        self.shareAllButton.layer.cornerRadius = 10;
        self.shareAllButton.tintColor          = [UIColor colorWithWhite:0.80 alpha:1];
        [self.shareAllButton addTarget:self action:@selector(shareAllTapped)
                      forControlEvents:UIControlEventTouchUpInside];
        UIImageSymbolConfiguration *shareCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
        if (@available(iOS 15, *)) {
            UIButtonConfiguration *bc = [UIButtonConfiguration plainButtonConfiguration];
            bc.title      = @"Save All";
            bc.image      = [UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:shareCfg];
            bc.imagePadding = 6;
            bc.baseForegroundColor = [UIColor colorWithWhite:0.80 alpha:1];
            self.shareAllButton.configuration = bc;
        } else {
            [self.shareAllButton setTitle:@"  Save All" forState:UIControlStateNormal];
            self.shareAllButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        }
        [self.cardView addSubview:self.shareAllButton];
    }
    return self;
}

// ── Configure ─────────────────────────────────────────────────────────────────

- (void)configureWithImagePaths:(NSArray<NSString *> *)paths
                         prompt:(NSString *)prompt
                        isError:(BOOL)isError
                      errorText:(NSString *)errorText
           presentingController:(UIViewController *)vc {
    self.currentPaths = paths;
    self.presenter    = vc;

    self.promptLabel.text = prompt.length > 0
        ? [NSString stringWithFormat:@"🖼 %@", prompt]
        : @"🖼 Image Result";

    // Clear old image views
    for (UIImageView *iv in self.imageViews) [iv removeFromSuperview];
    for (UIButton *btn in self.shareButtons) [btn removeFromSuperview];
    [self.imageViews   removeAllObjects];
    [self.shareButtons removeAllObjects];

    if (isError) {
        self.errorIcon.hidden  = NO;
        self.errorLabel.hidden = NO;
        self.errorLabel.text   = errorText ?: @"Image generation failed.";
        self.shareAllButton.hidden = YES;
        return;
    }

    self.errorIcon.hidden  = YES;
    self.errorLabel.hidden = YES;

    NSInteger count = MIN(paths.count, 4);
    self.shareAllButton.hidden = count <= 1;

    for (NSInteger i = 0; i < count; i++) {
        UIImageView *iv = [[UIImageView alloc] init];
        iv.contentMode          = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds        = YES;
        iv.layer.cornerRadius   = 8;
        iv.backgroundColor      = [UIColor colorWithWhite:0.15 alpha:1];
        iv.userInteractionEnabled = YES;
        iv.tag = i;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(imageTapped:)];
        [iv addGestureRecognizer:tap];
        [self.cardView addSubview:iv];
        [self.imageViews addObject:iv];

        // Load image async
        NSString *path = paths[(NSUInteger)i];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *img = [UIImage imageWithContentsOfFile:path];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (iv.tag == i) iv.image = img;
            });
        });

        // Per-image share button (only for multi-image results)
        if (count > 1) {
            UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            shareBtn.backgroundColor    = [UIColor colorWithWhite:0 alpha:0.55];
            shareBtn.layer.cornerRadius = 8;
            shareBtn.tintColor          = [UIColor whiteColor];
            shareBtn.tag                = i;
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
                configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
            [shareBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:cfg]
                      forState:UIControlStateNormal];
            [shareBtn addTarget:self action:@selector(perImageShareTapped:)
                      forControlEvents:UIControlEventTouchUpInside];
            [self.cardView addSubview:shareBtn];
            [self.shareButtons addObject:shareBtn];
        }
    }

    [self setNeedsLayout];
}

// ── Layout ────────────────────────────────────────────────────────────────────

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat W     = self.contentView.bounds.size.width;
    CGFloat cardW = W - kIGCCardPad * 2;
    self.cardView.frame = CGRectMake(kIGCCardPad, kIGCPad / 2,
                                     cardW, self.contentView.bounds.size.height - kIGCPad);

    CGFloat cW   = self.cardView.bounds.size.width;
    CGFloat cH   = self.cardView.bounds.size.height;
    CGFloat imgW = cW - kIGCPad * 2;

    self.promptLabel.frame = CGRectMake(kIGCPad, kIGCPad, imgW, kIGCPromptH);

    CGFloat imgTop = kIGCPad + kIGCPromptH + kIGCPad / 2;

    // Error layout
    if (!self.errorIcon.hidden) {
        self.errorIcon.frame  = CGRectMake(kIGCPad, imgTop, 32, 32);
        self.errorLabel.frame = CGRectMake(kIGCPad + 40, imgTop,
                                           imgW - 40, cH - imgTop - kIGCPad);
        return;
    }

    NSInteger count = (NSInteger)self.imageViews.count;
    if (count == 0) return;

    CGFloat shareAllY;

    if (count == 1) {
        CGFloat h = floor(imgW * 0.75);
        self.imageViews[0].frame = CGRectMake(kIGCPad, imgTop, imgW, h);
        shareAllY = imgTop + h + kIGCPad;
    } else if (count == 2) {
        CGFloat side = floor((imgW - kIGCGap) / 2);
        self.imageViews[0].frame = CGRectMake(kIGCPad,             imgTop, side, side);
        self.imageViews[1].frame = CGRectMake(kIGCPad + side + kIGCGap, imgTop, side, side);
        shareAllY = imgTop + side + kIGCPad;
    } else { // 4
        CGFloat side = floor((imgW - kIGCGap) / 2);
        self.imageViews[0].frame = CGRectMake(kIGCPad,             imgTop,             side, side);
        self.imageViews[1].frame = CGRectMake(kIGCPad + side + kIGCGap, imgTop,       side, side);
        self.imageViews[2].frame = CGRectMake(kIGCPad,             imgTop + side + kIGCGap, side, side);
        self.imageViews[3].frame = CGRectMake(kIGCPad + side + kIGCGap, imgTop + side + kIGCGap, side, side);
        shareAllY = imgTop + side * 2 + kIGCGap + kIGCPad;
    }

    // Per-image share button — bottom-right corner of each image view
    for (NSInteger i = 0; i < (NSInteger)self.shareButtons.count && i < (NSInteger)self.imageViews.count; i++) {
        CGRect ivFrame      = self.imageViews[(NSUInteger)i].frame;
        CGFloat btnSize     = 30;
        self.shareButtons[(NSUInteger)i].frame = CGRectMake(
            ivFrame.origin.x + ivFrame.size.width  - btnSize - 6,
            ivFrame.origin.y + ivFrame.size.height - btnSize - 6,
            btnSize, btnSize);
    }

    self.shareAllButton.frame = CGRectMake(kIGCPad, shareAllY, imgW, kIGCShareAllH);
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)imageTapped:(UITapGestureRecognizer *)tap {
    NSInteger idx = tap.view.tag;
    if (idx >= (NSInteger)self.currentPaths.count) return;
    UIImage *img = [UIImage imageWithContentsOfFile:self.currentPaths[(NSUInteger)idx]];
    if (!img || !self.presenter) return;
    EZFullScreenImageVC *fsvc = [EZFullScreenImageVC new];
    fsvc.image = img;
    fsvc.modalPresentationStyle = UIModalPresentationFullScreen;
    fsvc.modalTransitionStyle   = UIModalTransitionStyleCrossDissolve;
    [self.presenter presentViewController:fsvc animated:YES completion:nil];
}

- (void)perImageShareTapped:(UIButton *)btn {
    NSInteger idx = btn.tag;
    if (idx >= (NSInteger)self.currentPaths.count || !self.presenter) return;
    UIImage *img = [UIImage imageWithContentsOfFile:self.currentPaths[(NSUInteger)idx]];
    if (!img) return;
    UIActivityViewController *ac = [[UIActivityViewController alloc]
        initWithActivityItems:@[img] applicationActivities:nil];
    ac.popoverPresentationController.sourceView = btn;
    [self.presenter presentViewController:ac animated:YES completion:nil];
}

- (void)shareAllTapped {
    if (!self.presenter) return;
    NSMutableArray *images = [NSMutableArray array];
    for (NSString *path in self.currentPaths) {
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (img) [images addObject:img];
    }
    if (images.count == 0) return;
    UIActivityViewController *ac = [[UIActivityViewController alloc]
        initWithActivityItems:images applicationActivities:nil];
    ac.popoverPresentationController.sourceView = self.shareAllButton;
    [self.presenter presentViewController:ac animated:YES completion:nil];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    for (UIImageView *iv in self.imageViews) [iv removeFromSuperview];
    for (UIButton *btn in self.shareButtons) [btn removeFromSuperview];
    [self.imageViews   removeAllObjects];
    [self.shareButtons removeAllObjects];
    self.errorIcon.hidden  = YES;
    self.errorLabel.hidden = YES;
    self.shareAllButton.hidden = NO;
    self.currentPaths = nil;
    self.presenter    = nil;
}

@end

// ── EZAttachmentPreviewCell ───────────────────────────────────────────────────

@implementation EZAttachmentPreviewCell {
    UIView      *_bubbleView;
    UIImageView *_thumbView;
    UILabel     *_label;
}

+ (CGFloat)heightForTableWidth:(CGFloat)width {
    (void)width;
    return 120.0;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle  = UITableViewCellSelectionStyleNone;

        // Right-aligned bubble (user side)
        _bubbleView = [[UIView alloc] init];
        _bubbleView.backgroundColor    = [UIColor systemBlueColor];
        _bubbleView.layer.cornerRadius = 16;
        _bubbleView.clipsToBounds      = YES;
        [self.contentView addSubview:_bubbleView];

        _thumbView = [[UIImageView alloc] init];
        _thumbView.contentMode   = UIViewContentModeScaleAspectFill;
        _thumbView.clipsToBounds = YES;
        [_bubbleView addSubview:_thumbView];

        _label = [[UILabel alloc] init];
        _label.text      = @"📎 Attached";
        _label.font      = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _label.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        [_bubbleView addSubview:_label];
    }
    return self;
}

- (void)configureWithImagePath:(NSString *)path {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_thumbView.image = img;
        });
    });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W  = self.contentView.bounds.size.width;
    CGFloat bH = 92;
    CGFloat bW = 140;
    _bubbleView.frame = CGRectMake(W - bW - 16, 10, bW, bH);
    _thumbView.frame  = CGRectMake(0, 0, bW, bH - 22);
    _label.frame      = CGRectMake(8, bH - 20, bW - 16, 16);
}

@end
