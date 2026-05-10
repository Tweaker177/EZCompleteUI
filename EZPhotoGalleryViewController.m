//
//  EZPhotoGalleryViewController.m
//  EZCompleteUI
//
//  Dark, polished photo gallery. Reads images from /Documents/EZAttachments.
//  Pinch gesture cycles the grid between 2 – 5 columns.
//  Tap → full-screen detail sheet with action buttons.

#import "EZPhotoGalleryViewController.h"
#import <SafariServices/SafariServices.h>

// ── Notification names ────────────────────────────────────────────────────────

NSNotificationName const EZAttachImageToChat = @"EZAttachImageToChat";
NSNotificationName const EZEditImageInChat   = @"EZEditImageInChat";

// ── Constants ─────────────────────────────────────────────────────────────────

static NSString *const kGalleryCellID   = @"EZGalleryCell";
static NSString *const kAttachmentsDir  = @"EZAttachments";
static CGFloat   const kCellSpacing     = 3.0;
static NSInteger const kMinColumns      = 2;
static NSInteger const kMaxColumns      = 5;
static NSInteger const kDefaultColumns  = 3;

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

@end

// ── Detail / preview view controller ─────────────────────────────────────────
// Presented as a sheet from within the gallery.

@interface EZPhotoDetailViewController : UIViewController
@property (nonatomic, strong) UIImage  *image;
@property (nonatomic, copy)   NSString *filePath;
@property (nonatomic, copy)   void (^onDeleted)(void);
@end

@implementation EZPhotoDetailViewController {
    UIScrollView      *_scrollView;
    UIImageView       *_imageView;
    UIVisualEffectView *_toolbar;
    UIButton          *_askButton;
    UIButton          *_editButton;
    UIButton          *_shareButton;
    UIButton          *_deleteButton;
    UILabel           *_filenameLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.10 alpha:1.0];

    [self setupScrollView];
    [self setupToolbar];
    [self setupNavBar];
}

- (void)setupNavBar {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.down.circle.fill"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(dismiss)];
    self.navigationItem.leftBarButtonItem.tintColor = [UIColor colorWithWhite:0.6 alpha:1];

    // Filename as title
    NSString *name = self.filePath.lastPathComponent ?: @"";
    self.title = name;
    self.navigationController.navigationBar.titleTextAttributes = @{
        NSFontAttributeName:            [UIFont systemFontOfSize:13 weight:UIFontWeightMedium],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.55 alpha:1],
    };
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

    _imageView = [[UIImageView alloc] initWithImage:self.image];
    _imageView.contentMode   = UIViewContentModeScaleAspectFit;
    _imageView.clipsToBounds = NO;
    [_scrollView addSubview:_imageView];

    // Double-tap to zoom
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    [_scrollView addGestureRecognizer:doubleTap];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _imageView;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    [self centerImageView];
}

- (void)centerImageView {
    CGSize  boundsSize  = _scrollView.bounds.size;
    CGRect  frameToCenter = _imageView.frame;
    frameToCenter.origin.x = frameToCenter.size.width < boundsSize.width
        ? (boundsSize.width - frameToCenter.size.width) / 2 : 0;
    frameToCenter.origin.y = frameToCenter.size.height < boundsSize.height
        ? (boundsSize.height - frameToCenter.size.height) / 2 : 0;
    _imageView.frame = frameToCenter;
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    if (_scrollView.zoomScale > 1.0) {
        [_scrollView setZoomScale:1.0 animated:YES];
    } else {
        CGPoint  pt   = [tap locationInView:_imageView];
        CGRect   rect = CGRectMake(pt.x - 60, pt.y - 60, 120, 120);
        [_scrollView zoomToRect:rect animated:YES];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat toolbarH = 110 + self.view.safeAreaInsets.bottom;
    CGFloat imageAreaH = self.view.bounds.size.height - toolbarH;

    _scrollView.frame = CGRectMake(0, 0, self.view.bounds.size.width, imageAreaH);

    CGSize imgSize = self.image.size;
    if (imgSize.width > 0 && imgSize.height > 0) {
        CGFloat scale = MIN(self.view.bounds.size.width / imgSize.width,
                            imageAreaH / imgSize.height);
        _imageView.frame = CGRectMake(0, 0, imgSize.width * scale, imgSize.height * scale);
        _scrollView.contentSize = _imageView.frame.size;
        [self centerImageView];
    }

    _toolbar.frame = CGRectMake(0, self.view.bounds.size.height - toolbarH,
                                self.view.bounds.size.width, toolbarH);
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
    _askButton = [self makeButtonTitle:@"Ask a Question"
                                  icon:@"bubble.left.and.bubble.right.fill"
                           accentColor:[UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0]
                                  dark:YES];
    [_askButton addTarget:self action:@selector(askTapped) forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_askButton];

    // Edit button — blue
    _editButton = [self makeButtonTitle:@"Edit with AI"
                                   icon:@"wand.and.stars"
                            accentColor:[UIColor systemBlueColor]
                                   dark:NO];
    [_editButton addTarget:self action:@selector(editTapped) forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_editButton];

    // Share & Delete — icon-only
    _shareButton = [self makeIconButton:@"square.and.arrow.up" color:[UIColor colorWithWhite:0.75 alpha:1]];
    [_shareButton addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_shareButton];

    _deleteButton = [self makeIconButton:@"trash" color:[UIColor systemRedColor]];
    [_deleteButton addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
    [_toolbar.contentView addSubview:_deleteButton];

    [self.view addSubview:_toolbar];

    [self layoutToolbarButtons];
}

- (void)layoutToolbarButtons {
    CGFloat pad  = 16;
    CGFloat btnH = 48;
    CGFloat iconW = 48;
    CGFloat y    = 14;
    CGFloat W    = self.view.bounds.size.width;
    if (W == 0) W = UIScreen.mainScreen.bounds.size.width;

    CGFloat availW = W - pad * 2 - iconW * 2 - pad * 2;
    CGFloat halfW  = (availW - 8) / 2;

    _askButton.frame   = CGRectMake(pad, y, halfW, btnH);
    _editButton.frame  = CGRectMake(pad + halfW + 8, y, halfW, btnH);

    CGFloat iconY = y + (btnH - iconW) / 2;
    _shareButton.frame = CGRectMake(W - pad - iconW * 2 - 8, iconY, iconW, iconW);
    _deleteButton.frame = CGRectMake(W - pad - iconW, iconY, iconW, iconW);
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

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)askTapped {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:EZAttachImageToChat
                      object:nil
                    userInfo:@{ @"image": self.image }];
    [self dismissAllTheWay];
}

- (void)editTapped {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:EZEditImageInChat
                      object:nil
                    userInfo:@{ @"image": self.image, @"editMode": @YES }];
    [self dismissAllTheWay];
}

- (void)shareTapped {
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:@[self.image] applicationActivities:nil];
    share.popoverPresentationController.sourceView = _shareButton;
    [self presentViewController:share animated:YES completion:nil];
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
                                             UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UICollectionView      *collectionView;
@property (nonatomic, strong) UICollectionViewFlowLayout *layout;
@property (nonatomic, strong) NSMutableArray<NSString *> *filePaths;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *thumbnailCache;
@property (nonatomic, strong) NSOperationQueue      *loadQueue;
@property (nonatomic, assign) NSInteger              columnCount;
@property (nonatomic, strong) UILabel               *emptyLabel;
@property (nonatomic, strong) UILabel               *countLabel;
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

- (void)styleNavBar {
    self.title = @"EZ Attachments";

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

    // Close button
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeTapped)];
    self.navigationItem.leftBarButtonItem.tintColor = [UIColor colorWithWhite:0.65 alpha:1];

    // Count label as right item (updated after load)
    self.countLabel = [[UILabel alloc] init];
    self.countLabel.font      = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.countLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.countLabel];
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
    [self.collectionView registerClass:[EZGalleryCell class] forCellWithReuseIdentifier:kGalleryCellID];
    [self.view addSubview:self.collectionView];
}

- (void)setupEmptyState {
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text          = @"No attachments yet.\nImages saved from chats appear here.";
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
    return [docs stringByAppendingPathComponent:kAttachmentsDir];
}

- (void)loadFilePaths {
    NSString *dir = [self attachmentsPath];
    NSArray<NSString *> *all = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:dir error:nil] ?: @[];

    NSArray<NSString *> *imageExts = @[@"jpg", @"jpeg", @"png", @"heic", @"gif", @"webp", @"tiff", @"bmp"];
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *name in all) {
        if ([imageExts containsObject:name.pathExtension.lowercaseString]) {
            [paths addObject:[dir stringByAppendingPathComponent:name]];
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
        [NSString stringWithFormat:@"%ld %@", (long)count, count == 1 ? @"photo" : @"photos"];
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
    NSString *path  = self.filePaths[indexPath.item];
    UIImage  *image = [UIImage imageWithContentsOfFile:path];
    if (!image) return;

    EZPhotoDetailViewController *detail = [EZPhotoDetailViewController new];
    detail.image    = image;
    detail.filePath = path;

    __weak typeof(self) weakSelf = self;
    detail.onDeleted = ^{
        [weakSelf loadFilePaths];
    };

    [self.navigationController pushViewController:detail animated:YES];
}

// ── Close ─────────────────────────────────────────────────────────────────────

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
