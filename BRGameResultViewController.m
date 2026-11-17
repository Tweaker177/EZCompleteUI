// BRGameResultViewController.m
// BrainRotGame
// EZCompleteUI v2.0 — Custom Workshop / Saved-Game / Community-Preview Result Screen
//
// Changes from v1.1:
//   - Added resultControllerForCommunityPreviewWithTitle:... — a third
//     construction path for a community game not yet downloaded. Title and
//     premise are known immediately (from list_shared_games); the three
//     asset images are loaded asynchronously from signed URLs via
//     BRRemoteImageLoader (extracted to its own file specifically so this
//     class and BRGamePickerViewController could share it — see that
//     class's header for why).
//   - Generalized the bottom bar from a 2-state model (Finalizing <-> Ready)
//     to 3 states (Busy / ReadyToDownload / ReadyToPlay). The two visually
//     distinct "ready" sub-states (DOWNLOAD vs PLAY) now share ONE action
//     container with a single primary button whose title and behavior
//     switch based on state, rather than being two separate container view
//     hierarchies — simpler than it sounds: handlePrimaryActionTapped
//     dispatches to either beginDownload or the existing onPlayTapped path
//     depending on bottomBarState. The busy container is similarly reused
//     for both "Finalizing your world..." (generation) and "Downloading
//     your game..." (community download), parameterized by a status-text
//     property instead of being two separate containers.
//   - markReadyWithRecord: keeps its exact original contract and is now
//     also used internally once a community-preview download succeeds —
//     existing callers don't need to change anything.
//   - Added an inline error label, shown under the action button when a
//     download fails, with the button reverting to DOWNLOAD so the player
//     can retry without the whole screen needing to be re-presented.
//
// Purpose:
//   Implementation of BRGameResultViewController. See the header for the
//   full contract and the three flows this screen serves. Layout is:
//   full-bleed background (image or themed color) with a dim overlay, a
//   scrollable card containing the title/premise/thumbnails that fades +
//   slides in on first appearance, and a bottom bar whose state machine is
//   described above.

#import "BRGameResultViewController.h"
#import "BRRemoteImageLoader.h"

/// What the bottom bar currently shows. Derived automatically by
/// updateBottomBarAnimated: from readyRecord / isDownloadInFlight /
/// isCommunityPreviewMode — nothing else in this file sets it directly.
typedef NS_ENUM(NSInteger, BRGameResultBottomBarState) {
    BRGameResultBottomBarStateBusy,             // spinner + status text, no buttons
    BRGameResultBottomBarStateReadyToDownload,  // DOWNLOAD + Maybe Later
    BRGameResultBottomBarStateReadyToPlay,      // PLAY + Maybe Later
};

@interface BRGameResultViewController ()

// Data supplied at construction time (UIImage-based factory).
@property (nonatomic, copy) NSString *gameTitle;
@property (nonatomic, copy, nullable) NSString *premiseText;
@property (nonatomic, strong, nullable) UIImage *playerImage;
@property (nonatomic, strong, nullable) UIImage *enemyImage;
@property (nonatomic, strong, nullable) UIImage *backgroundImageSource;

// Data supplied at construction time (community-preview factory).
@property (nonatomic, assign) BOOL isCommunityPreviewMode;
@property (nonatomic, copy, nullable) NSString *playerImageURLString;
@property (nonatomic, copy, nullable) NSString *enemyImageURLString;
@property (nonatomic, copy, nullable) NSString *backgroundImageURLString;
@property (nonatomic, copy, nullable) BRGameResultDownloadHandler downloadHandler;

// Supplied later via markReadyWithRecord: (or internally, after a
// successful community download).
@property (nonatomic, strong, nullable) BRGameRecord *readyRecord;
@property (nonatomic, assign) BOOL isDownloadInFlight;

// Views that animate in on first appearance.
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *premiseCard;
@property (nonatomic, strong) UILabel *premiseLabel;
@property (nonatomic, assign) BOOL hasPlayedRevealAnimation;

// Background + thumbnails — stored as properties (rather than local
// variables in their build methods) so async URL loads can fill them in
// after construction.
@property (nonatomic, strong, nullable) UIImageView *backgroundImageView;
@property (nonatomic, strong, nullable) UIImageView *playerThumbnailView;
@property (nonatomic, strong, nullable) UIImageView *enemyThumbnailView;
@property (nonatomic, weak, nullable) NSURLSessionDataTask *backgroundImageLoadTask;
@property (nonatomic, weak, nullable) NSURLSessionDataTask *playerImageLoadTask;
@property (nonatomic, weak, nullable) NSURLSessionDataTask *enemyImageLoadTask;

// Bottom bar — one busy container (spinner + status text) and one action
// container (one primary button + Maybe Later), rather than three/four
// separate container hierarchies. See BRGameResultBottomBarState.
@property (nonatomic, strong) UIView *busyStateContainer;
@property (nonatomic, strong) UILabel *busyStatusLabel;
@property (nonatomic, strong) UIView *actionStateContainer;
@property (nonatomic, strong) UIButton *primaryActionButton;
@property (nonatomic, strong) UILabel *inlineErrorLabel;

@end

@implementation BRGameResultViewController

#pragma mark - Factory

+ (instancetype)resultControllerWithTitle:(NSString *)gameTitle
                                   premise:(nullable NSString *)premise
                               playerImage:(nullable UIImage *)playerImage
                                enemyImage:(nullable UIImage *)enemyImage
                           backgroundImage:(nullable UIImage *)backgroundImage {
    BRGameResultViewController *controller = [[BRGameResultViewController alloc] init];
    controller.gameTitle = gameTitle;
    controller.premiseText = premise;
    controller.playerImage = playerImage;
    controller.enemyImage = enemyImage;
    controller.backgroundImageSource = backgroundImage;
    return controller;
}

+ (instancetype)resultControllerForCommunityPreviewWithTitle:(NSString *)gameTitle
                                                       premise:(nullable NSString *)premise
                                          playerImageURLString:(nullable NSString *)playerImageURLString
                                           enemyImageURLString:(nullable NSString *)enemyImageURLString
                                      backgroundImageURLString:(nullable NSString *)backgroundImageURLString
                                               downloadHandler:(BRGameResultDownloadHandler)downloadHandler {
    BRGameResultViewController *controller = [[BRGameResultViewController alloc] init];
    controller.gameTitle = gameTitle;
    controller.premiseText = premise;
    controller.isCommunityPreviewMode = YES;
    controller.playerImageURLString = playerImageURLString;
    controller.enemyImageURLString = enemyImageURLString;
    controller.backgroundImageURLString = backgroundImageURLString;
    controller.downloadHandler = downloadHandler;
    return controller;
}

#pragma mark - Lifecycle

- (void)dealloc {
    [self.backgroundImageLoadTask cancel];
    [self.playerImageLoadTask cancel];
    [self.enemyImageLoadTask cancel];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.0 blue:0.12 alpha:1.0];

    [self buildBackgroundLayer];
    UIScrollView *scrollView = [self buildScrollView];
    [self buildRevealContentInScrollView:scrollView];
    [self buildBottomBar];

    // If markReadyWithRecord: was already called before the view loaded
    // (unlikely, but possible if a network call is very fast), reflect that
    // immediately without animating. Otherwise this resolves to Busy
    // (UIImage-based factory, generation in progress) or ReadyToDownload
    // (community-preview factory) per updateBottomBarAnimated:'s rules.
    [self updateBottomBarAnimated:NO];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.hasPlayedRevealAnimation) return;
    self.hasPlayedRevealAnimation = YES;
    [self playRevealAnimation];
}

#pragma mark - Background

- (void)buildBackgroundLayer {
    BOOL hasAnyBackgroundSource = (self.backgroundImageSource != nil) || (self.backgroundImageURLString != nil);

    if (hasAnyBackgroundSource) {
        self.backgroundImageView = [[UIImageView alloc] initWithImage:self.backgroundImageSource];
        self.backgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.backgroundImageView.clipsToBounds = YES;
        self.backgroundImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.backgroundImageView];
        [NSLayoutConstraint activateConstraints:@[
            [self.backgroundImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.backgroundImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [self.backgroundImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.backgroundImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        ]];

        if (self.backgroundImageURLString) {
            __weak typeof(self) weakSelf = self;
            NSString *requestedURLString = self.backgroundImageURLString;
            self.backgroundImageLoadTask = [[BRRemoteImageLoader shared] loadImageFromURLString:requestedURLString
                                                                                       completion:^(UIImage * _Nullable image) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || !image) return;
                // No reuse to guard against here (unlike a collection view
                // cell, this screen is only ever bound to one game), but
                // double-check the URL still matches in case a future
                // change allows rebinding this screen to different content.
                if (![strongSelf.backgroundImageURLString isEqualToString:requestedURLString]) return;
                strongSelf.backgroundImageView.image = image;
            }];
        }
    }

    // Dim overlay sits above the background image (or the plain theme
    // color, if there is no background image/URL at all) so light
    // AI-generated art doesn't wash out the title/premise text.
    UIView *dimOverlay = [[UIView alloc] init];
    dimOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:hasAnyBackgroundSource ? 0.45 : 0.0];
    dimOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:dimOverlay];
    [NSLayoutConstraint activateConstraints:@[
        [dimOverlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimOverlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [dimOverlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimOverlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

#pragma mark - Scrollable Content

- (UIScrollView *)buildScrollView {
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24.0],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    return scrollView;
}

/// Builds the title, premise card, and asset thumbnails — the content that
/// "reveals" itself on first appearance. Leaves room at the bottom for the
/// bottom bar by pinning the content's bottom anchor with extra padding.
- (void)buildRevealContentInScrollView:(UIScrollView *)scrollView {
    UIView *contentView = [[UIView alloc] init];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:contentView];

    [NSLayoutConstraint activateConstraints:@[
        [contentView.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [contentView.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [contentView.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [contentView.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [contentView.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],
    ]];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.5;
    self.titleLabel.text = self.gameTitle;
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:30.0];
    self.titleLabel.numberOfLines = 0;

    self.premiseCard = [[UIView alloc] init];
    self.premiseCard.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    self.premiseCard.layer.cornerRadius = 16.0;
    self.premiseCard.layer.borderWidth = 1.0;
    self.premiseCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;

    self.premiseLabel = [[UILabel alloc] init];
    self.premiseLabel.adjustsFontSizeToFitWidth = YES;
    self.premiseLabel.minimumScaleFactor = 0.5;
    NSString *premise = self.premiseText.length > 0 ? self.premiseText : @"No premise was generated for this world — jump in and see what you find.";
    self.premiseLabel.text = premise;
    self.premiseLabel.textColor = [UIColor whiteColor];
    self.premiseLabel.font = [UIFont systemFontOfSize:17.0];
    self.premiseLabel.numberOfLines = 0;

    UIStackView *thumbnailRow = [self buildThumbnailRow];

    for (UIView *view in @[self.titleLabel, self.premiseCard, thumbnailRow]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [contentView addSubview:view];
    }
    self.premiseLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.premiseCard addSubview:self.premiseLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:contentView.topAnchor],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:24.0],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-24.0],

        [self.premiseCard.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:18.0],
        [self.premiseCard.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:24.0],
        [self.premiseCard.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-24.0],

        [self.premiseLabel.topAnchor constraintEqualToAnchor:self.premiseCard.topAnchor constant:16.0],
        [self.premiseLabel.bottomAnchor constraintEqualToAnchor:self.premiseCard.bottomAnchor constant:-16.0],
        [self.premiseLabel.leadingAnchor constraintEqualToAnchor:self.premiseCard.leadingAnchor constant:16.0],
        [self.premiseLabel.trailingAnchor constraintEqualToAnchor:self.premiseCard.trailingAnchor constant:-16.0],

        [thumbnailRow.topAnchor constraintEqualToAnchor:self.premiseCard.bottomAnchor constant:20.0],
        [thumbnailRow.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:24.0],
        [thumbnailRow.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-160.0],
    ]];

    // The reveal animation starts from these states (faded out, slightly
    // lower than their final position) and animates to identity.
    for (UIView *view in @[self.titleLabel, self.premiseCard]) {
        view.alpha = 0.0;
        view.transform = CGAffineTransformMakeTranslation(0.0, 16.0);
    }
}

/// Small rounded thumbnails for the player/enemy art. A slot is built if
/// EITHER a UIImage or a URL string was supplied for it; if only a URL was
/// supplied, the thumbnail starts empty and is filled in asynchronously.
/// Returns an empty (zero-height) stack view if neither asset is available
/// in any form, so the layout degrades gracefully.
- (UIStackView *)buildThumbnailRow {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 12.0;
    stack.alignment = UIStackViewAlignmentCenter;

    if (self.playerImage || self.playerImageURLString) {
        self.playerThumbnailView = [self buildThumbnailViewWithImage:self.playerImage];
        [stack addArrangedSubview:self.playerThumbnailView];
        if (!self.playerImage && self.playerImageURLString) {
            [self loadThumbnailURLString:self.playerImageURLString
                                  intoView:self.playerThumbnailView
                                  taskSlot:^(NSURLSessionDataTask * _Nullable task) { self.playerImageLoadTask = task; }];
        }
    }

    if (self.enemyImage || self.enemyImageURLString) {
        self.enemyThumbnailView = [self buildThumbnailViewWithImage:self.enemyImage];
        [stack addArrangedSubview:self.enemyThumbnailView];
        if (!self.enemyImage && self.enemyImageURLString) {
            [self loadThumbnailURLString:self.enemyImageURLString
                                  intoView:self.enemyThumbnailView
                                  taskSlot:^(NSURLSessionDataTask * _Nullable task) { self.enemyImageLoadTask = task; }];
        }
    }

    return stack;
}

- (UIImageView *)buildThumbnailViewWithImage:(nullable UIImage *)image {
    UIImageView *thumbnail = [[UIImageView alloc] initWithImage:image];
    thumbnail.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06]; // visible while a URL-sourced image is still loading
    thumbnail.contentMode = UIViewContentModeScaleAspectFill;
    thumbnail.clipsToBounds = YES;
    thumbnail.layer.cornerRadius = 10.0;
    thumbnail.layer.borderWidth = 1.0;
    thumbnail.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    thumbnail.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [thumbnail.widthAnchor constraintEqualToConstant:56.0],
        [thumbnail.heightAnchor constraintEqualToConstant:56.0],
    ]];
    return thumbnail;
}

/// Shared helper for the two thumbnail slots' async loads. `taskSlot` lets
/// each call site stash the returned task into its own dedicated weak
/// property (playerImageLoadTask / enemyImageLoadTask) without duplicating
/// this method per-slot.
- (void)loadThumbnailURLString:(NSString *)urlString
                       intoView:(UIImageView *)imageView
                       taskSlot:(void (^)(NSURLSessionDataTask * _Nullable task))taskSlot {
    __weak UIImageView *weakImageView = imageView;
    NSURLSessionDataTask *task = [[BRRemoteImageLoader shared] loadImageFromURLString:urlString
                                                                             completion:^(UIImage * _Nullable image) {
        UIImageView *strongImageView = weakImageView;
        if (strongImageView && image) strongImageView.image = image;
    }];
    taskSlot(task);
}

#pragma mark - Reveal Animation

- (void)playRevealAnimation {
    [UIView animateWithDuration:0.45
                          delay:0.05
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.titleLabel.alpha = 1.0;
        self.titleLabel.transform = CGAffineTransformIdentity;
    } completion:nil];

    [UIView animateWithDuration:0.45
                          delay:0.20
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.premiseCard.alpha = 1.0;
        self.premiseCard.transform = CGAffineTransformIdentity;
    } completion:nil];
}

#pragma mark - Bottom Bar (Busy / ReadyToDownload / ReadyToPlay)

- (void)buildBottomBar {
    self.busyStateContainer = [self buildBusyStateContainer];
    self.actionStateContainer = [self buildActionStateContainer];

    for (UIView *container in @[self.busyStateContainer, self.actionStateContainer]) {
        container.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:container];
        [NSLayoutConstraint activateConstraints:@[
            [container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24.0],
            [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24.0],
            [container.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20.0],
        ]];
    }

    // Start hidden; updateBottomBarAnimated: in viewDidLoad picks the
    // correct initial state for whichever factory was used.
    self.actionStateContainer.alpha = 0.0;
    self.actionStateContainer.hidden = YES;
}

- (UIView *)buildBusyStateContainer {
    UIView *container = [[UIView alloc] init];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = [UIColor systemYellowColor];
    [spinner startAnimating];

    self.busyStatusLabel = [[UILabel alloc] init];
    self.busyStatusLabel.numberOfLines = 0;
    self.busyStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.busyStatusLabel.text = @"Finalizing your world...";
    self.busyStatusLabel.textColor = [UIColor systemGrayColor];
    self.busyStatusLabel.font = [UIFont systemFontOfSize:15.0];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[spinner, self.busyStatusLabel]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 10.0;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:container.widthAnchor constant:-48.0],
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:8.0],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0],
    ]];

    return container;
}

- (UIView *)buildActionStateContainer {
    UIView *container = [[UIView alloc] init];

    self.primaryActionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.primaryActionButton.titleLabel.font = [UIFont boldSystemFontOfSize:19.0];
    self.primaryActionButton.tintColor = [UIColor colorWithRed:0.04 green:0.0 blue:0.12 alpha:1.0];
    self.primaryActionButton.backgroundColor = [UIColor systemYellowColor];
    self.primaryActionButton.layer.cornerRadius = 16.0;
    [self.primaryActionButton addTarget:self action:@selector(handlePrimaryActionTapped) forControlEvents:UIControlEventTouchUpInside];

    self.inlineErrorLabel = [[UILabel alloc] init];
    self.inlineErrorLabel.adjustsFontSizeToFitWidth = YES;
    self.inlineErrorLabel.minimumScaleFactor = 0.5;
    self.inlineErrorLabel.textColor = [UIColor systemRedColor];
    self.inlineErrorLabel.font = [UIFont systemFontOfSize:13.0];
    self.inlineErrorLabel.numberOfLines = 0;
    self.inlineErrorLabel.textAlignment = NSTextAlignmentCenter;
    self.inlineErrorLabel.hidden = YES;

    UIButton *maybeLaterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [maybeLaterButton setTitle:@"Maybe Later" forState:UIControlStateNormal];
    maybeLaterButton.titleLabel.font = [UIFont systemFontOfSize:15.0];
    maybeLaterButton.tintColor = [UIColor systemGrayColor];
    [maybeLaterButton addTarget:self action:@selector(handleMaybeLaterTapped) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *view in @[self.primaryActionButton, self.inlineErrorLabel, maybeLaterButton]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.primaryActionButton.topAnchor constraintEqualToAnchor:container.topAnchor],
        [self.primaryActionButton.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.primaryActionButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.primaryActionButton.heightAnchor constraintEqualToConstant:56.0],

        [self.inlineErrorLabel.topAnchor constraintEqualToAnchor:self.primaryActionButton.bottomAnchor constant:8.0],
        [self.inlineErrorLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8.0],
        [self.inlineErrorLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8.0],

        [maybeLaterButton.topAnchor constraintEqualToAnchor:self.inlineErrorLabel.bottomAnchor constant:8.0],
        [maybeLaterButton.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [maybeLaterButton.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    return container;
}

/// Derives the target state from readyRecord / isDownloadInFlight /
/// isCommunityPreviewMode (in that priority order) and crossfades the
/// busy/action containers accordingly. Nothing in this file sets
/// bottomBarState directly — it's always computed fresh here, so there's
/// exactly one place that can get the state wrong instead of several call
/// sites each making their own judgment call.
- (void)updateBottomBarAnimated:(BOOL)animated {
    if (!self.isViewLoaded) return;

    BRGameResultBottomBarState state;
    if (self.readyRecord != nil) {
        state = BRGameResultBottomBarStateReadyToPlay;
    } else if (self.isDownloadInFlight) {
        state = BRGameResultBottomBarStateBusy;
        self.busyStatusLabel.text = @"Downloading your game...";
    } else if (self.isCommunityPreviewMode) {
        state = BRGameResultBottomBarStateReadyToDownload;
    } else {
        state = BRGameResultBottomBarStateBusy; // original generating-flow default
        self.busyStatusLabel.text = @"Finalizing your world...";
    }

    if (state == BRGameResultBottomBarStateReadyToPlay) {
        [self.primaryActionButton setTitle:@"▶  PLAY" forState:UIControlStateNormal];
    } else if (state == BRGameResultBottomBarStateReadyToDownload) {
        [self.primaryActionButton setTitle:@"⬇  DOWNLOAD" forState:UIControlStateNormal];
    }

    BOOL showAction = (state != BRGameResultBottomBarStateBusy);
    UIView *fadeInView  = showAction ? self.actionStateContainer : self.busyStateContainer;
    UIView *fadeOutView = showAction ? self.busyStateContainer : self.actionStateContainer;

    fadeInView.hidden = NO;

    void (^applyAlphas)(void) = ^{
        fadeInView.alpha = 1.0;
        fadeOutView.alpha = 0.0;
    };
    void (^hideFadedOutView)(BOOL) = ^(BOOL finished) {
        fadeOutView.hidden = YES;
    };

    if (animated) {
        [UIView animateWithDuration:0.35 animations:applyAlphas completion:hideFadedOutView];
    } else {
        applyAlphas();
        hideFadedOutView(YES);
    }
}

#pragma mark - markReadyWithRecord:

- (void)markReadyWithRecord:(BRGameRecord *)record {
    self.readyRecord = record;
    self.isDownloadInFlight = NO;
    BOOL animated = (self.viewIfLoaded.window != nil);
    [self updateBottomBarAnimated:animated];
}

#pragma mark - Actions

/// Single entry point for the one big yellow button, regardless of what
/// it currently says. Dispatches based on the same derivation
/// updateBottomBarAnimated: uses, so this can never act on a state the
/// button isn't actually showing.
- (void)handlePrimaryActionTapped {
    if (self.readyRecord != nil) {
        if (self.onPlayTapped) self.onPlayTapped(self.readyRecord);
        return;
    }
    if (self.isCommunityPreviewMode && !self.isDownloadInFlight) {
        [self beginDownload];
    }
    // Busy state: button is hidden during this state, so a tap reaching
    // here at all would mean a race during the crossfade — no-op is the
    // safe default rather than guessing at user intent.
}

- (void)beginDownload {
    if (!self.downloadHandler) return;

    self.inlineErrorLabel.hidden = YES;
    self.isDownloadInFlight = YES;
    [self updateBottomBarAnimated:YES];

    __weak typeof(self) weakSelf = self;
    self.downloadHandler(^(BRGameRecord * _Nullable record, NSString * _Nullable errorMessage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (record) {
                // markReadyWithRecord: clears isDownloadInFlight and moves
                // the bottom bar straight to ReadyToPlay — no separate
                // "success" state needed in between.
                [strongSelf markReadyWithRecord:record];
                return;
            }

            strongSelf.isDownloadInFlight = NO;
            strongSelf.inlineErrorLabel.text = errorMessage ?: @"Download failed. Please try again.";
            strongSelf.inlineErrorLabel.hidden = NO;
            [strongSelf updateBottomBarAnimated:YES];
        });
    });
}

- (void)handleMaybeLaterTapped {
    if (self.onMaybeLaterTapped) {
        self.onMaybeLaterTapped();
    }
}

@end
