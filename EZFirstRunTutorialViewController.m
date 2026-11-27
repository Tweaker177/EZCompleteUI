#import "EZFirstRunTutorialViewController.h"
#import "EZAuthManager.h"
#import "EZCoinStoreViewController.h"

// Simple first-run walkthrough: four pages — welcome, the chat text entry,
// the navigation menu, and the coin store. It replaces the retired ten-page
// tutorial whose code-drawn screens no longer matched the app. The demos here
// are plain schematics built from the app's real labels (the menu rows use the
// drawer's own EZNav strings), so they cannot drift from what users see.

static NSString *const kEZTutorialCompletedPrefix = @"EZFirstRunTutorialCompleted.";

@interface EZFirstRunTutorialViewController ()
@property (nonatomic, assign) NSInteger pageIndex;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *bodyLabel;
@property (nonatomic, strong) UIImageView *heroIcon;
@property (nonatomic, strong) UIView *chatDemoView;
@property (nonatomic, strong) UIView *menuDemoView;
@property (nonatomic, strong) UIView *storeDemoView;
@property (nonatomic, strong) UIPageControl *pageControl;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) NSLayoutConstraint *welcomeTitleTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *demoTitleTopConstraint;
@end

@implementation EZFirstRunTutorialViewController

+ (NSString *)completionKey {
    NSString *userID = EZAuthManager.shared.userId ?: @"default";
    return [kEZTutorialCompletedPrefix stringByAppendingString:userID];
}

+ (BOOL)shouldShowTutorial {
    if (!EZAuthManager.shared.isLoggedIn) return NO;
    return ![[NSUserDefaults standardUserDefaults] boolForKey:[self completionKey]];
}

#pragma mark - Small building blocks

- (UILabel *)demoLabel:(NSString *)text color:(UIColor *)color font:(CGFloat)size weight:(UIFontWeight)weight {
    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = color;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (UIView *)skeletonBar:(CGFloat)width color:(UIColor *)color {
    UIView *bar = [UIView new];
    bar.backgroundColor = color;
    bar.layer.cornerRadius = 3;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [bar.widthAnchor constraintEqualToConstant:width].active = YES;
    [bar.heightAnchor constraintEqualToConstant:6].active = YES;
    return bar;
}

- (UIView *)demoPanel:(CGFloat)height {
    UIView *panel = [UIView new];
    panel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    panel.layer.cornerRadius = 18;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.heightAnchor constraintEqualToConstant:height].active = YES;
    return panel;
}

// The demo panels are fixed-height (264 or 392 pt). On a short landscape
// screen that height does not fit between the body text and the bottom
// controls, so each panel rides in a scroll view: full height in portrait,
// and the panel shrinks to the room available and scrolls in landscape
// instead of running offscreen behind the buttons.
- (UIScrollView *)scrollWrap:(UIView *)content {
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [scroll addSubview:content];
    NSLayoutConstraint *fitHeight = [scroll.heightAnchor constraintEqualToAnchor:content.heightAnchor];
    fitHeight.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        fitHeight,
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [scroll.bottomAnchor constraintLessThanOrEqualToAnchor:self.pageControl.topAnchor constant:-12],
    ]];
    return scroll;
}

#pragma mark - View lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.045 blue:0.12 alpha:1.0];

    UIButton *skip = [UIButton buttonWithType:UIButtonTypeSystem];
    [skip setTitle:NSLocalizedString(@"EZTutorial.Skip", nil) forState:UIControlStateNormal];
    skip.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [skip setTitleColor:[UIColor colorWithRed:0.08 green:0.90 blue:0.72 alpha:1] forState:UIControlStateNormal];
    [skip addTarget:self action:@selector(finishTutorial) forControlEvents:UIControlEventTouchUpInside];
    skip.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:skip];

    self.heroIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"sparkles"]];
    self.heroIcon.tintColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.1 alpha:1];
    self.heroIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.heroIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.heroIcon];

    self.titleLabel = [UILabel new];
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.5;
    self.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 0;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.titleLabel];

    self.bodyLabel = [UILabel new];
    self.bodyLabel.adjustsFontSizeToFitWidth = YES;
    self.bodyLabel.minimumScaleFactor = 0.5;
    self.bodyLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightRegular];
    self.bodyLabel.textColor = [UIColor colorWithWhite:0.82 alpha:1];
    self.bodyLabel.textAlignment = NSTextAlignmentCenter;
    self.bodyLabel.numberOfLines = 0;
    self.bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.bodyLabel];

    [self buildChatDemo];
    [self buildMenuDemo];
    [self buildStoreDemo];

    self.pageControl = [UIPageControl new];
    self.pageControl.numberOfPages = 4;
    self.pageControl.currentPageIndicatorTintColor = [UIColor colorWithRed:0.08 green:0.90 blue:0.72 alpha:1];
    self.pageControl.pageIndicatorTintColor = [UIColor colorWithWhite:1 alpha:0.25];
    self.pageControl.userInteractionEnabled = NO;
    self.pageControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.pageControl];

    self.backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.backButton setTitle:NSLocalizedString(@"EZTutorial.Back", nil) forState:UIControlStateNormal];
    self.backButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.backButton setTitleColor:[UIColor colorWithWhite:0.82 alpha:1] forState:UIControlStateNormal];
    [self.backButton addTarget:self action:@selector(backTapped) forControlEvents:UIControlEventTouchUpInside];
    self.backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.backButton];

    self.nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.nextButton setTitle:NSLocalizedString(@"EZTutorial.Next", nil) forState:UIControlStateNormal];
    self.nextButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [self.nextButton setTitleColor:[UIColor colorWithRed:0.08 green:0.90 blue:0.72 alpha:1] forState:UIControlStateNormal];
    [self.nextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];
    self.nextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.nextButton];

    // Wrap the demo panels in their scroll views before laying out: the
    // page control has to exist first, because the scroll views cap their
    // bottom edge against it.
    self.chatDemoView = [self scrollWrap:self.chatDemoView];
    self.menuDemoView = [self scrollWrap:self.menuDemoView];
    self.storeDemoView = [self scrollWrap:self.storeDemoView];
    [self.view addSubview:self.chatDemoView];
    [self.view addSubview:self.menuDemoView];
    [self.view addSubview:self.storeDemoView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [skip.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [skip.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [self.heroIcon.topAnchor constraintEqualToAnchor:safe.topAnchor constant:48],
        [self.heroIcon.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.heroIcon.widthAnchor constraintEqualToConstant:64],
        [self.heroIcon.heightAnchor constraintEqualToConstant:64],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:28],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-28],

        [self.bodyLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:10],
        [self.bodyLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:32],
        [self.bodyLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-32],

        [self.chatDemoView.topAnchor constraintEqualToAnchor:self.bodyLabel.bottomAnchor constant:26],
        [self.chatDemoView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.chatDemoView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],

        [self.menuDemoView.topAnchor constraintEqualToAnchor:self.bodyLabel.bottomAnchor constant:26],
        [self.menuDemoView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.menuDemoView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],

        [self.storeDemoView.topAnchor constraintEqualToAnchor:self.bodyLabel.bottomAnchor constant:26],
        [self.storeDemoView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.storeDemoView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],

        [self.pageControl.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.pageControl.bottomAnchor constraintEqualToAnchor:self.backButton.topAnchor constant:-10],

        [self.backButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [self.backButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-18],

        [self.nextButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [self.nextButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-18],
    ]];

    // The welcome page puts its title under the hero icon; demo pages start
    // their title near the top so the panel gets the room.
    self.welcomeTitleTopConstraint = [self.titleLabel.topAnchor constraintEqualToAnchor:self.heroIcon.bottomAnchor constant:18];
    self.demoTitleTopConstraint = [self.titleLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:56];

    [self refreshPageAnimated:NO];
}

#pragma mark - Demo panels

// Two bubbles over the real composer's shape: a pill text field with the
// app's own placeholder, and the send button beside it.
- (void)buildChatDemo {
    UIView *panel = [self demoPanel:264];
    self.chatDemoView = panel;

    UIView *userBubble = [UIView new];
    userBubble.backgroundColor = [UIColor colorWithRed:0.08 green:0.55 blue:0.48 alpha:1];
    userBubble.layer.cornerRadius = 14;
    userBubble.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:userBubble];
    UIView *userBar = [self skeletonBar:110 color:[UIColor colorWithWhite:1 alpha:0.75]];
    [userBubble addSubview:userBar];

    UIView *replyBubble = [UIView new];
    replyBubble.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    replyBubble.layer.cornerRadius = 14;
    replyBubble.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:replyBubble];
    UIView *replyBar1 = [self skeletonBar:170 color:[UIColor colorWithWhite:1 alpha:0.55]];
    UIView *replyBar2 = [self skeletonBar:130 color:[UIColor colorWithWhite:1 alpha:0.4]];
    [replyBubble addSubview:replyBar1];
    [replyBubble addSubview:replyBar2];

    UIView *composer = [UIView new];
    composer.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    composer.layer.cornerRadius = 21;
    composer.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:composer];

    UILabel *placeholder = [self demoLabel:@"Type a message..." color:[UIColor colorWithWhite:0.75 alpha:1] font:15 weight:UIFontWeightRegular];
    [composer addSubview:placeholder];

    UIView *sendCircle = [UIView new];
    sendCircle.backgroundColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.1 alpha:1];
    sendCircle.layer.cornerRadius = 15;
    sendCircle.translatesAutoresizingMaskIntoConstraints = NO;
    [composer addSubview:sendCircle];
    UIImageView *sendIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up"]];
    sendIcon.tintColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.16 alpha:1];
    sendIcon.contentMode = UIViewContentModeScaleAspectFit;
    sendIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [sendCircle addSubview:sendIcon];

    [NSLayoutConstraint activateConstraints:@[
        [userBubble.topAnchor constraintEqualToAnchor:panel.topAnchor constant:20],
        [userBubble.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        [userBubble.widthAnchor constraintEqualToConstant:150],
        [userBubble.heightAnchor constraintEqualToConstant:38],
        [userBar.leadingAnchor constraintEqualToAnchor:userBubble.leadingAnchor constant:12],
        [userBar.centerYAnchor constraintEqualToAnchor:userBubble.centerYAnchor],

        [replyBubble.topAnchor constraintEqualToAnchor:userBubble.bottomAnchor constant:14],
        [replyBubble.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [replyBubble.widthAnchor constraintEqualToConstant:210],
        [replyBubble.heightAnchor constraintEqualToConstant:56],
        [replyBar1.leadingAnchor constraintEqualToAnchor:replyBubble.leadingAnchor constant:12],
        [replyBar1.topAnchor constraintEqualToAnchor:replyBubble.topAnchor constant:14],
        [replyBar2.leadingAnchor constraintEqualToAnchor:replyBubble.leadingAnchor constant:12],
        [replyBar2.topAnchor constraintEqualToAnchor:replyBar1.bottomAnchor constant:10],

        [composer.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14],
        [composer.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
        [composer.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-16],
        [composer.heightAnchor constraintEqualToConstant:42],

        [placeholder.leadingAnchor constraintEqualToAnchor:composer.leadingAnchor constant:14],
        [placeholder.centerYAnchor constraintEqualToAnchor:composer.centerYAnchor],

        [sendCircle.trailingAnchor constraintEqualToAnchor:composer.trailingAnchor constant:-6],
        [sendCircle.centerYAnchor constraintEqualToAnchor:composer.centerYAnchor],
        [sendCircle.widthAnchor constraintEqualToConstant:30],
        [sendCircle.heightAnchor constraintEqualToConstant:30],
        [sendIcon.centerXAnchor constraintEqualToAnchor:sendCircle.centerXAnchor],
        [sendIcon.centerYAnchor constraintEqualToAnchor:sendCircle.centerYAnchor],
        [sendIcon.widthAnchor constraintEqualToConstant:15],
        [sendIcon.heightAnchor constraintEqualToConstant:15],
    ]];
}

// The real drawer: the same rows, in the same order, with the same localized
// labels the menu itself uses. The Coin Store row is highlighted — it is the
// one new users could not find.
- (void)buildMenuDemo {
    UIView *panel = [self demoPanel:392];
    self.menuDemoView = panel;

    UIImageView *burger = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal"]];
    burger.tintColor = UIColor.whiteColor;
    burger.contentMode = UIViewContentModeScaleAspectFit;
    burger.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:burger];

    UILabel *appTitle = [self demoLabel:NSLocalizedString(@"EZNav.AppTitle", nil)
                                  color:UIColor.whiteColor font:15 weight:UIFontWeightBold];
    [panel addSubview:appTitle];

    NSArray<NSString *> *rowTitles = @[
        NSLocalizedString(@"EZNav.NewChat", nil),
        NSLocalizedString(@"EZNav.PhotoGallery", nil),
        NSLocalizedString(@"EZNav.TextToSpeech", nil),
        NSLocalizedStringWithDefaultValue(@"EZNav.Music", nil, [NSBundle mainBundle], @"AI Music", nil),
        NSLocalizedString(@"EZNav.Files", nil),
        NSLocalizedString(@"EZNav.Sounds", nil),
        NSLocalizedString(@"EZNav.VoiceCloning", nil),
        NSLocalizedString(@"EZNav.BrainRot", nil),
        NSLocalizedString(@"EZNav.Memories", nil),
        NSLocalizedString(@"EZNav.CoinStore", nil),
        NSLocalizedString(@"EZNav.Settings", nil),
    ];

    UIView *previous = nil;
    for (NSUInteger i = 0; i < rowTitles.count; i++) {
        BOOL isStoreRow = (i == 9);
        UIView *row = [UIView new];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        if (isStoreRow) {
            row.backgroundColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.1 alpha:0.16];
            row.layer.cornerRadius = 8;
        }
        [panel addSubview:row];
        UILabel *rowLabel = [self demoLabel:rowTitles[i]
                                      color:isStoreRow ? [UIColor colorWithRed:1.0 green:0.78 blue:0.1 alpha:1] : [UIColor colorWithWhite:0.92 alpha:1]
                                       font:14 weight:isStoreRow ? UIFontWeightBold : UIFontWeightRegular];
        [row addSubview:rowLabel];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:12],
            [row.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12],
            [row.heightAnchor constraintEqualToConstant:27],
            previous ? [row.topAnchor constraintEqualToAnchor:previous.bottomAnchor constant:1]
                     : [row.topAnchor constraintEqualToAnchor:panel.topAnchor constant:46],
            [rowLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],
            [rowLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        ]];
        previous = row;
    }

    UILabel *recent = [self demoLabel:NSLocalizedString(@"EZNav.RecentChats", nil)
                                 color:[UIColor colorWithWhite:0.6 alpha:1] font:12 weight:UIFontWeightSemibold];
    [panel addSubview:recent];
    [NSLayoutConstraint activateConstraints:@[
        [burger.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [burger.topAnchor constraintEqualToAnchor:panel.topAnchor constant:14],
        [burger.widthAnchor constraintEqualToConstant:20],
        [burger.heightAnchor constraintEqualToConstant:20],
        [appTitle.leadingAnchor constraintEqualToAnchor:burger.trailingAnchor constant:10],
        [appTitle.centerYAnchor constraintEqualToAnchor:burger.centerYAnchor],
        [recent.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:22],
        [recent.topAnchor constraintEqualToAnchor:previous.bottomAnchor constant:10],
    ]];
}

// The store in one panel: a balance line, the gold website button, and a plan
// card — the three shapes that make up the real store's top.
- (void)buildStoreDemo {
    UIView *panel = [self demoPanel:264];
    self.storeDemoView = panel;

    UIView *coin = [UIView new];
    coin.backgroundColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.1 alpha:1];
    coin.layer.cornerRadius = 11;
    coin.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:coin];

    UILabel *balance = [self demoLabel:@"1,000" color:UIColor.whiteColor font:16 weight:UIFontWeightSemibold];
    [panel addSubview:balance];

    UIView *webButton = [UIView new];
    webButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.1 alpha:1];
    webButton.layer.cornerRadius = 24;
    webButton.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:webButton];
    UILabel *webTitle = [self demoLabel:NSLocalizedStringWithDefaultValue(@"EZCoinStore.WebStore.Title", nil, [NSBundle mainBundle], @"Buy coins on our website", nil)
                                   color:[UIColor colorWithRed:0.05 green:0.06 blue:0.16 alpha:1] font:16 weight:UIFontWeightHeavy];
    webTitle.textAlignment = NSTextAlignmentCenter;
    [webButton addSubview:webTitle];

    UIView *card = [UIView new];
    card.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    card.layer.cornerRadius = 14;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:card];
    UILabel *cardTitle = [self demoLabel:NSLocalizedString(@"EZTutorial.CoinStore.Title", nil)
                                   color:UIColor.whiteColor font:16 weight:UIFontWeightBold];
    [card addSubview:cardTitle];
    UIView *cardBar = [self skeletonBar:150 color:[UIColor colorWithWhite:1 alpha:0.45]];
    [card addSubview:cardBar];

    [NSLayoutConstraint activateConstraints:@[
        [coin.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:18],
        [coin.topAnchor constraintEqualToAnchor:panel.topAnchor constant:18],
        [coin.widthAnchor constraintEqualToConstant:22],
        [coin.heightAnchor constraintEqualToConstant:22],
        [balance.leadingAnchor constraintEqualToAnchor:coin.trailingAnchor constant:8],
        [balance.centerYAnchor constraintEqualToAnchor:coin.centerYAnchor],

        [webButton.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [webButton.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        [webButton.topAnchor constraintEqualToAnchor:coin.bottomAnchor constant:18],
        [webButton.heightAnchor constraintEqualToConstant:48],
        [webTitle.centerXAnchor constraintEqualToAnchor:webButton.centerXAnchor],
        [webTitle.centerYAnchor constraintEqualToAnchor:webButton.centerYAnchor],

        [card.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        [card.topAnchor constraintEqualToAnchor:webButton.bottomAnchor constant:16],
        [card.heightAnchor constraintEqualToConstant:76],
        [cardTitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [cardTitle.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [cardBar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [cardBar.topAnchor constraintEqualToAnchor:cardTitle.bottomAnchor constant:12],
    ]];
}

#pragma mark - Paging

- (void)refreshPageAnimated:(BOOL)animated {
    NSArray<NSString *> *titles = @[
        NSLocalizedString(@"EZTutorial.Welcome.Title", nil),
        NSLocalizedString(@"EZTutorial.Chat.Title", nil),
        NSLocalizedString(@"EZTutorial.Navigate.Title", nil),
        NSLocalizedString(@"EZTutorial.CoinStore.Title", nil)
    ];
    NSArray<NSString *> *bodies = @[
        NSLocalizedString(@"EZTutorial.Welcome.Body", nil),
        NSLocalizedString(@"EZTutorial.Chat.Body", nil),
        NSLocalizedString(@"EZTutorial.Navigate.Body", nil),
        NSLocalizedString(@"EZTutorial.CoinStore.Body", nil)
    ];
    void (^changes)(void) = ^{
        self.titleLabel.text = titles[(NSUInteger)self.pageIndex];
        self.bodyLabel.text = bodies[(NSUInteger)self.pageIndex];
        self.pageControl.currentPage = self.pageIndex;
        self.backButton.hidden = self.pageIndex == 0;
        NSString *next = self.pageIndex == self.pageControl.numberOfPages - 1
            ? NSLocalizedString(@"EZTutorial.GetStarted", nil) : NSLocalizedString(@"EZTutorial.Next", nil);
        [self.nextButton setTitle:next forState:UIControlStateNormal];
        self.heroIcon.hidden = self.pageIndex != 0;
        self.welcomeTitleTopConstraint.active = self.pageIndex == 0;
        self.demoTitleTopConstraint.active = self.pageIndex != 0;
        self.chatDemoView.hidden = self.pageIndex != 1;
        self.menuDemoView.hidden = self.pageIndex != 2;
        self.storeDemoView.hidden = self.pageIndex != 3;
    };
    if (animated) [UIView transitionWithView:self.view duration:0.22 options:UIViewAnimationOptionTransitionCrossDissolve animations:changes completion:nil];
    else changes();
}

- (void)nextTapped { if (self.pageIndex + 1 < self.pageControl.numberOfPages) { self.pageIndex++; [self refreshPageAnimated:YES]; } else [self finishTutorial]; }
- (void)backTapped { if (self.pageIndex > 0) { self.pageIndex--; [self refreshPageAnimated:YES]; } }

- (void)finishTutorial {
    BOOL shouldOpenCoinStore = self.pageIndex == self.pageControl.numberOfPages - 1;
    __weak UIViewController *presenter = self.presentingViewController;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:[EZFirstRunTutorialViewController completionKey]];
    [self dismissViewControllerAnimated:YES completion:^{
        if (!shouldOpenCoinStore || !presenter) return;
        EZCoinStoreViewController *store = [EZCoinStoreViewController new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:store];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [presenter presentViewController:nav animated:YES completion:nil];
    }];
}

@end
