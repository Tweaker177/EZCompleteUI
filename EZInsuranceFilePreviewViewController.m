// EZInsuranceFilePreviewViewController.m
// EZCompleteUI

#import "EZInsuranceFilePreviewViewController.h"
#import <AVKit/AVKit.h>

static const CGFloat kNotesCardHeight = 120;

@interface EZInsuranceFilePreviewViewController () <UIScrollViewDelegate>

@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, copy, nullable) NSString *mimeType;
@property (nonatomic, copy) NSString *previewTitle;
@property (nonatomic, copy, nullable) NSString *notes;

// Image mode only
@property (nonatomic, strong, nullable) UIScrollView *scrollView;
@property (nonatomic, strong, nullable) UIImageView *imageView;
@property (nonatomic, assign) BOOL hasSetInitialZoom;

// Video mode only
@property (nonatomic, strong, nullable) AVPlayerViewController *playerViewController;

@property (nonatomic, strong) UIView *contentContainerView;

@end

@implementation EZInsuranceFilePreviewViewController

- (instancetype)initWithFileURL:(NSURL *)fileURL
                        mimeType:(nullable NSString *)mimeType
                            title:(NSString *)title
                            notes:(nullable NSString *)notes {
    self = [super init];
    if (self) {
        _fileURL = fileURL;
        _mimeType = [mimeType copy];
        _previewTitle = [title copy];
        _notes = [notes copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Black, edge-to-edge — matches the platform convention for media
    // viewers (Photos, Messages attachments) rather than this app's usual
    // adaptive system background, which is the right call specifically
    // here: it makes the actual content the focus instead of competing
    // with surrounding chrome.
    self.view.backgroundColor = [UIColor blackColor];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.5;
    titleLabel.text = self.previewTitle;
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:17];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 1;
    titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:titleLabel];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    closeButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [closeButton addTarget:self action:@selector(ez_closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:closeButton];

    self.contentContainerView = [[UIView alloc] init];
    self.contentContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.contentContainerView];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [closeButton.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8],
        [closeButton.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-16],
        [closeButton.widthAnchor constraintEqualToConstant:32],
        [closeButton.heightAnchor constraintEqualToConstant:32],

        [titleLabel.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:44],
        // Keeps the title visually centered on screen while still
        // clearing the close button — trailing anchor matches the same
        // 44pt inset as leading rather than butting right up against the
        // button, so it doesn't look lopsided.
        [titleLabel.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-44],

        [self.contentContainerView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:12],
        [self.contentContainerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.contentContainerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];

    if (self.notes.length) {
        [self ez_buildNotesCardBelow:self.contentContainerView];
    } else {
        [self.contentContainerView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor].active = YES;
    }

    if ([self.mimeType hasPrefix:@"video/"]) {
        [self ez_buildVideoContent];
    } else {
        // Anything else routed here is treated as an image — the caller
        // (ez_previewFileRecord: in the detail view controller) only ever
        // sends image/* or video/* to this screen, everything else still
        // goes through QLPreviewController.
        [self ez_buildImageContent];
    }
}

- (void)ez_closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// ── Notes card ────────────────────────────────────────────────────────────

- (void)ez_buildNotesCardBelow:(UIView *)aboveView {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    card.layer.cornerRadius = 14;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    UILabel *header = [[UILabel alloc] init];
    header.adjustsFontSizeToFitWidth = YES;
    header.minimumScaleFactor = 0.5;
    header.text = @"NOTES";
    header.font = [UIFont boldSystemFontOfSize:11];
    header.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:header];

    // Non-editable — this is a viewer, not the notes editor (that's
    // EZInsuranceNotesEditorViewController, reached from the file's "•••"
    // menu). Fixed card height with internal scrolling for long notes
    // rather than trying to auto-size the card to content, which UITextView
    // makes more fiddly than it's worth for what this needs to do.
    UITextView *notesView = [[UITextView alloc] init];
    notesView.text = self.notes;
    notesView.font = [UIFont systemFontOfSize:15];
    notesView.textColor = [UIColor whiteColor];
    notesView.backgroundColor = [UIColor clearColor];
    notesView.editable = NO;
    notesView.scrollEnabled = YES;
    notesView.textContainerInset = UIEdgeInsetsZero;
    notesView.textContainer.lineFragmentPadding = 0;
    notesView.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:notesView];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [aboveView.bottomAnchor constraintEqualToAnchor:card.topAnchor constant:-12],

        [card.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-16],
        [card.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-12],
        [card.heightAnchor constraintEqualToConstant:kNotesCardHeight],

        [header.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
        [header.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [header.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],

        [notesView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:4],
        [notesView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [notesView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [notesView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10],
    ]];
}

// Leaving the preview stops the video: nothing pauses an AVPlayer on
// dismissal by itself, so do it explicitly on the way out and at teardown.
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        [self.playerViewController.player pause];
    }
}

- (void)dealloc {
    [_playerViewController.player pause];
}

// ── Video content ─────────────────────────────────────────────────────────

- (void)ez_buildVideoContent {
    AVPlayer *player = [AVPlayer playerWithURL:self.fileURL];
    self.playerViewController = [[AVPlayerViewController alloc] init];
    self.playerViewController.player = player;

    [self addChildViewController:self.playerViewController];
    self.playerViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainerView addSubview:self.playerViewController.view];
    [NSLayoutConstraint activateConstraints:@[
        [self.playerViewController.view.topAnchor constraintEqualToAnchor:self.contentContainerView.topAnchor],
        [self.playerViewController.view.bottomAnchor constraintEqualToAnchor:self.contentContainerView.bottomAnchor],
        [self.playerViewController.view.leadingAnchor constraintEqualToAnchor:self.contentContainerView.leadingAnchor],
        [self.playerViewController.view.trailingAnchor constraintEqualToAnchor:self.contentContainerView.trailingAnchor],
    ]];
    [self.playerViewController didMoveToParentViewController:self];
}

// ── Image content (zoomable) ────────────────────────────────────────────

- (void)ez_buildImageContent {
    UIImage *image = [UIImage imageWithContentsOfFile:self.fileURL.path];

    if (!image) {
        [self ez_showLoadFailedState];
        return;
    }

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.delegate = self;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainerView addSubview:self.scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.contentContainerView.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.contentContainerView.bottomAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.contentContainerView.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.contentContainerView.trailingAnchor],
    ]];

    self.imageView = [[UIImageView alloc] initWithImage:image];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.scrollView addSubview:self.imageView];

    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(ez_doubleTapped:)];
    doubleTap.numberOfTapsRequired = 2;
    [self.scrollView addGestureRecognizer:doubleTap];
}

- (void)ez_showLoadFailedState {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"exclamationmark.triangle"]];
    icon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [[UILabel alloc] init];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    label.text = @"Couldn't load preview";
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    label.font = [UIFont systemFontOfSize:15];
    label.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, label]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainerView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:40],
        [icon.heightAnchor constraintEqualToConstant:40],
        [stack.centerXAnchor constraintEqualToAnchor:self.contentContainerView.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.contentContainerView.centerYAnchor],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self ez_updateImageLayoutIfNeeded];
}

- (void)ez_updateImageLayoutIfNeeded {
    UIImage *image = self.imageView.image;
    if (!image || self.hasSetInitialZoom) return;

    CGSize boundsSize = self.scrollView.bounds.size;
    CGSize imageSize = image.size;
    if (boundsSize.width <= 0 || boundsSize.height <= 0 || imageSize.width <= 0 || imageSize.height <= 0) return;

    self.imageView.frame = CGRectMake(0, 0, imageSize.width, imageSize.height);
    self.scrollView.contentSize = imageSize;

    CGFloat minScale = MIN(boundsSize.width / imageSize.width, boundsSize.height / imageSize.height);
    self.scrollView.minimumZoomScale = minScale;
    self.scrollView.maximumZoomScale = MAX(minScale * 4, 1.0);
    self.scrollView.zoomScale = minScale;
    self.hasSetInitialZoom = YES;

    [self ez_centerImageView];
}

- (void)ez_centerImageView {
    CGSize boundsSize = self.scrollView.bounds.size;
    CGRect frame = self.imageView.frame;
    frame.origin.x = frame.size.width < boundsSize.width ? (boundsSize.width - frame.size.width) / 2.0 : 0;
    frame.origin.y = frame.size.height < boundsSize.height ? (boundsSize.height - frame.size.height) / 2.0 : 0;
    self.imageView.frame = frame;
}

- (void)ez_doubleTapped:(UITapGestureRecognizer *)recognizer {
    if (self.scrollView.zoomScale > self.scrollView.minimumZoomScale + 0.01) {
        [self.scrollView setZoomScale:self.scrollView.minimumZoomScale animated:YES];
        return;
    }
    CGPoint point = [recognizer locationInView:self.imageView];
    CGFloat zoom = self.scrollView.maximumZoomScale;
    CGSize size = CGSizeMake(self.scrollView.bounds.size.width / zoom, self.scrollView.bounds.size.height / zoom);
    CGRect zoomRect = CGRectMake(point.x - size.width / 2.0, point.y - size.height / 2.0, size.width, size.height);
    [self.scrollView zoomToRect:zoomRect animated:YES];
}

#pragma mark - UIScrollViewDelegate

- (nullable UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return self.imageView;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    [self ez_centerImageView];
}

@end
