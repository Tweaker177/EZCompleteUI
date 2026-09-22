#import "EZFirstRunTutorialViewController.h"
#import "EZAuthManager.h"
#import "EZCoinStoreViewController.h"
#import "SupportRequestViewController.h"

static NSString *const kEZTutorialCompletedPrefix = @"EZFirstRunTutorialCompleted.";

@interface EZFirstRunTutorialViewController ()
@property (nonatomic, assign) NSInteger pageIndex;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *bodyLabel;
@property (nonatomic, strong) UIImageView *heroIcon;
@property (nonatomic, strong) UIView *chatDemoView;
@property (nonatomic, strong) UIView *navigationDemoView;
@property (nonatomic, strong) UIView *galleryDemoView;
@property (nonatomic, strong) UIView *detailDemoView;
@property (nonatomic, strong) UIView *memoriesDemoView;
@property (nonatomic, strong) UIView *coinStoreDemoView;
@property (nonatomic, strong) NSLayoutConstraint *standardTitleTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *chatTitleTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *chatDemoTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *chatDemoBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *navigationDemoTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *navigationDemoBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *galleryDemoTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *galleryDemoBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *detailDemoTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *detailDemoBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *memoriesDemoTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *memoriesDemoBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *coinStoreDemoTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *coinStoreDemoBottomConstraint;
@property (nonatomic, strong) UIPageControl *pageControl;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *feedbackButton;
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
    self.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    self.titleLabel.textColor = UIColor.whiteColor;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 0;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.titleLabel];

    self.bodyLabel = [UILabel new];
    self.bodyLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightRegular];
    self.bodyLabel.textColor = [UIColor colorWithWhite:0.82 alpha:1];
    self.bodyLabel.textAlignment = NSTextAlignmentCenter;
    self.bodyLabel.numberOfLines = 0;
    self.bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.bodyLabel];

    self.pageControl = [UIPageControl new];
    self.pageControl.numberOfPages = 7;
    self.pageControl.currentPageIndicatorTintColor = [UIColor colorWithRed:0.08 green:0.90 blue:0.72 alpha:1];
    self.pageControl.pageIndicatorTintColor = [UIColor colorWithWhite:1 alpha:0.25];
    self.pageControl.userInteractionEnabled = NO;
    self.pageControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.pageControl];

    [self buildChatDemo];
    [self buildNavigationDemo];
    [self buildGalleryDemo];
    [self buildDetailDemo];
    [self buildMemoriesDemo];
    [self buildCoinStoreDemo];

    self.backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.backButton setTitle:NSLocalizedString(@"EZTutorial.Back", nil) forState:UIControlStateNormal];
    [self.backButton addTarget:self action:@selector(backTapped) forControlEvents:UIControlEventTouchUpInside];
    self.backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.backButton];

    self.nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.nextButton.backgroundColor = [UIColor colorWithRed:0.04 green:0.82 blue:0.65 alpha:1];
    self.nextButton.layer.cornerRadius = 14;
    self.nextButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [self.nextButton setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    [self.nextButton addTarget:self action:@selector(nextTapped) forControlEvents:UIControlEventTouchUpInside];
    self.nextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.nextButton];

    self.feedbackButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.feedbackButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.feedbackButton.titleLabel.numberOfLines = 2;
    self.feedbackButton.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.feedbackButton setTitle:NSLocalizedString(@"EZTutorial.Feedback", nil) forState:UIControlStateNormal];
    [self.feedbackButton setTitleColor:[UIColor colorWithRed:0.1 green:0.78 blue:1 alpha:1] forState:UIControlStateNormal];
    [self.feedbackButton addTarget:self action:@selector(feedbackTapped) forControlEvents:UIControlEventTouchUpInside];
    self.feedbackButton.hidden = YES;
    self.feedbackButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.feedbackButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [skip.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [skip.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-22],
        [self.heroIcon.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.heroIcon.topAnchor constraintEqualToAnchor:safe.topAnchor constant:88],
        [self.heroIcon.widthAnchor constraintEqualToConstant:76], [self.heroIcon.heightAnchor constraintEqualToConstant:76],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:30],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-30],
        [self.bodyLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:24],
        [self.bodyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:30],
        [self.bodyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-30],
        [self.chatDemoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [self.chatDemoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],
        [self.navigationDemoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [self.navigationDemoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],
        [self.galleryDemoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [self.galleryDemoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],
        [self.detailDemoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [self.detailDemoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],
        [self.memoriesDemoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [self.memoriesDemoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],
        [self.coinStoreDemoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [self.coinStoreDemoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],
        [self.pageControl.bottomAnchor constraintEqualToAnchor:self.nextButton.topAnchor constant:-22],
        [self.pageControl.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.feedbackButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:30],
        [self.feedbackButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-30],
        [self.feedbackButton.bottomAnchor constraintEqualToAnchor:self.pageControl.topAnchor constant:-26],
        [self.nextButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:30],
        [self.nextButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-30],
        [self.nextButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-20],
        [self.nextButton.heightAnchor constraintEqualToConstant:54],
        [self.backButton.leadingAnchor constraintEqualToAnchor:self.nextButton.leadingAnchor],
        [self.backButton.centerYAnchor constraintEqualToAnchor:self.pageControl.centerYAnchor],
    ]];
    self.standardTitleTopConstraint = [self.titleLabel.topAnchor constraintEqualToAnchor:self.heroIcon.bottomAnchor constant:32];
    self.chatTitleTopConstraint = [self.titleLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:64];
    self.chatDemoTopConstraint = [self.chatDemoView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:20];
    self.chatDemoBottomConstraint = [self.chatDemoView.bottomAnchor constraintEqualToAnchor:self.pageControl.topAnchor constant:-18];
    self.navigationDemoTopConstraint = [self.navigationDemoView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:20];
    self.navigationDemoBottomConstraint = [self.navigationDemoView.bottomAnchor constraintEqualToAnchor:self.pageControl.topAnchor constant:-18];
    self.galleryDemoTopConstraint = [self.galleryDemoView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:20];
    self.galleryDemoBottomConstraint = [self.galleryDemoView.bottomAnchor constraintEqualToAnchor:self.pageControl.topAnchor constant:-18];
    self.detailDemoTopConstraint = [self.detailDemoView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:20];
    self.detailDemoBottomConstraint = [self.detailDemoView.bottomAnchor constraintEqualToAnchor:self.pageControl.topAnchor constant:-18];
    self.memoriesDemoTopConstraint = [self.memoriesDemoView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:20];
    self.memoriesDemoBottomConstraint = [self.memoriesDemoView.bottomAnchor constraintEqualToAnchor:self.pageControl.topAnchor constant:-18];
    self.coinStoreDemoTopConstraint = [self.coinStoreDemoView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:20];
    self.coinStoreDemoBottomConstraint = [self.coinStoreDemoView.bottomAnchor constraintEqualToAnchor:self.pageControl.topAnchor constant:-18];
    [NSLayoutConstraint activateConstraints:@[
        self.standardTitleTopConstraint
    ]];
    [self refreshPageAnimated:NO];
}

- (UILabel *)demoLabel:(NSString *)text color:(UIColor *)color font:(CGFloat)size {
    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = color;
    label.font = [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (UIButton *)demoIconButton:(NSString *)symbol tint:(UIColor *)tint {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = tint;
    button.userInteractionEnabled = NO;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    return button;
}

- (void)buildChatDemo {
    self.chatDemoView = [UIView new];
    self.chatDemoView.backgroundColor = [UIColor colorWithRed:0.02 green:0.03 blue:0.07 alpha:1];
    self.chatDemoView.layer.cornerRadius = 22;
    self.chatDemoView.layer.borderWidth = 1;
    self.chatDemoView.layer.borderColor = [UIColor colorWithRed:0.05 green:0.9 blue:0.72 alpha:0.55].CGColor;
    self.chatDemoView.hidden = YES;
    self.chatDemoView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.chatDemoView];

    UILabel *hint = [self demoLabel:NSLocalizedString(@"EZTutorial.Demo.ModelPicker", nil)
                              color:[UIColor colorWithRed:0.05 green:0.9 blue:0.72 alpha:1] font:14];
    hint.textAlignment = NSTextAlignmentCenter;
    [self.chatDemoView addSubview:hint];

    UILabel *walkthrough = [self demoLabel:NSLocalizedString(@"EZTutorial.Chat.Body", nil)
                                     color:[UIColor colorWithWhite:0.82 alpha:1] font:14];
    walkthrough.textAlignment = NSTextAlignmentCenter;
    [self.chatDemoView addSubview:walkthrough];

    UIView *composer = [UIView new];
    composer.backgroundColor = [UIColor colorWithRed:0.03 green:0.36 blue:0.29 alpha:1];
    composer.layer.cornerRadius = 14;
    composer.layer.borderWidth = 1;
    composer.layer.borderColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:0.75].CGColor;
    composer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.chatDemoView addSubview:composer];

    UILabel *model = [self demoLabel:NSLocalizedString(@"EZTutorial.Demo.Model", nil)
                               color:[UIColor colorWithRed:0.1 green:0.78 blue:1 alpha:1] font:13];
    [composer addSubview:model];
    UILabel *caption = [self demoLabel:NSLocalizedString(@"EZTutorial.Demo.Controls", nil)
                                 color:[UIColor colorWithWhite:1 alpha:0.65] font:11];
    caption.textAlignment = NSTextAlignmentRight;
    [composer addSubview:caption];

    UIColor *blue = [UIColor colorWithRed:0.08 green:0.64 blue:1 alpha:1];
    UIButton *attach = [self demoIconButton:@"paperclip.circle.fill" tint:blue];
    UIButton *mic = [self demoIconButton:@"mic.fill" tint:blue];
    UIButton *web = [self demoIconButton:@"globe" tint:[UIColor colorWithRed:0.12 green:0.9 blue:0.42 alpha:1]];
    UIButton *helper = [self demoIconButton:@"bolt.fill" tint:[UIColor colorWithRed:1 green:0.78 blue:0.05 alpha:1]];
    [composer addSubview:attach]; [composer addSubview:mic]; [composer addSubview:web]; [composer addSubview:helper];

    UIView *field = [UIView new];
    field.backgroundColor = UIColor.blackColor;
    field.layer.cornerRadius = 8;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [composer addSubview:field];
    UILabel *placeholder = [self demoLabel:NSLocalizedString(@"EZTutorial.Demo.Placeholder", nil)
                                     color:[UIColor colorWithWhite:0.56 alpha:1] font:12];
    [field addSubview:placeholder];
    UILabel *send = [self demoLabel:NSLocalizedString(@"EZTutorial.Demo.Send", nil) color:blue font:13];
    [composer addSubview:send];

    [NSLayoutConstraint activateConstraints:@[
        [hint.topAnchor constraintEqualToAnchor:self.chatDemoView.topAnchor constant:14],
        [hint.leadingAnchor constraintEqualToAnchor:self.chatDemoView.leadingAnchor constant:12],
        [hint.trailingAnchor constraintEqualToAnchor:self.chatDemoView.trailingAnchor constant:-12],
        [walkthrough.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:14],
        [walkthrough.leadingAnchor constraintEqualToAnchor:self.chatDemoView.leadingAnchor constant:18],
        [walkthrough.trailingAnchor constraintEqualToAnchor:self.chatDemoView.trailingAnchor constant:-18],
        [walkthrough.bottomAnchor constraintLessThanOrEqualToAnchor:composer.topAnchor constant:-14],
        [composer.leadingAnchor constraintEqualToAnchor:self.chatDemoView.leadingAnchor constant:12],
        [composer.trailingAnchor constraintEqualToAnchor:self.chatDemoView.trailingAnchor constant:-12],
        [composer.bottomAnchor constraintEqualToAnchor:self.chatDemoView.bottomAnchor constant:-12],
        [composer.heightAnchor constraintEqualToConstant:116],
        [model.leadingAnchor constraintEqualToAnchor:composer.leadingAnchor constant:12],
        [model.topAnchor constraintEqualToAnchor:composer.topAnchor constant:10],
        [caption.trailingAnchor constraintEqualToAnchor:composer.trailingAnchor constant:-12],
        [caption.centerYAnchor constraintEqualToAnchor:model.centerYAnchor],
        [attach.leadingAnchor constraintEqualToAnchor:composer.leadingAnchor constant:12],
        [attach.topAnchor constraintEqualToAnchor:model.bottomAnchor constant:12],
        [attach.widthAnchor constraintEqualToConstant:27], [attach.heightAnchor constraintEqualToConstant:27],
        [mic.leadingAnchor constraintEqualToAnchor:attach.trailingAnchor constant:7], [mic.centerYAnchor constraintEqualToAnchor:attach.centerYAnchor],
        [web.leadingAnchor constraintEqualToAnchor:attach.leadingAnchor], [web.topAnchor constraintEqualToAnchor:attach.bottomAnchor constant:5],
        [helper.leadingAnchor constraintEqualToAnchor:mic.leadingAnchor], [helper.centerYAnchor constraintEqualToAnchor:web.centerYAnchor],
        [field.leadingAnchor constraintEqualToAnchor:helper.trailingAnchor constant:8],
        [field.topAnchor constraintEqualToAnchor:attach.topAnchor], [field.bottomAnchor constraintEqualToAnchor:web.bottomAnchor],
        [field.trailingAnchor constraintEqualToAnchor:send.leadingAnchor constant:-8],
        [placeholder.leadingAnchor constraintEqualToAnchor:field.leadingAnchor constant:8], [placeholder.centerYAnchor constraintEqualToAnchor:field.centerYAnchor],
        [send.trailingAnchor constraintEqualToAnchor:composer.trailingAnchor constant:-10], [send.centerYAnchor constraintEqualToAnchor:field.centerYAnchor],
    ]];
}

- (UIView *)navigationRowWithTitle:(NSString *)title symbol:(NSString *)symbol {
    UIView *row = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = [UIColor colorWithRed:0.10 green:0.78 blue:0.92 alpha:1];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];
    UILabel *label = [self demoLabel:title color:UIColor.whiteColor font:14];
    [row addSubview:label];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = [UIColor secondaryLabelColor];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:chevron];
    UIView *line = [UIView new];
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12], [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:22], [icon.heightAnchor constraintEqualToConstant:22],
        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12], [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12], [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [line.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12], [line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12], [line.bottomAnchor constraintEqualToAnchor:row.bottomAnchor], [line.heightAnchor constraintEqualToConstant:0.5],
    ]];
    return row;
}

- (void)buildNavigationDemo {
    self.navigationDemoView = [UIView new];
    self.navigationDemoView.backgroundColor = UIColor.blackColor;
    self.navigationDemoView.layer.cornerRadius = 22;
    self.navigationDemoView.layer.borderWidth = 1;
    self.navigationDemoView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    self.navigationDemoView.hidden = YES;
    self.navigationDemoView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.navigationDemoView];

    UILabel *appTitle = [self demoLabel:@"EZCompleteUI" color:UIColor.whiteColor font:20];
    [self.navigationDemoView addSubview:appTitle];
    UIImageView *search = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    search.tintColor = [UIColor colorWithRed:0.08 green:0.64 blue:1 alpha:1];
    search.translatesAutoresizingMaskIntoConstraints = NO;
    [self.navigationDemoView addSubview:search];

    UIStackView *rows = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self navigationRowWithTitle:NSLocalizedString(@"EZNav.NewChat", nil) symbol:@"square.and.pencil"],
        [self navigationRowWithTitle:NSLocalizedString(@"EZNav.PhotoGallery", nil) symbol:@"photo.on.rectangle.angled"],
        [self navigationRowWithTitle:NSLocalizedString(@"EZNav.TextToSpeech", nil) symbol:@"play.circle.fill"],
        [self navigationRowWithTitle:NSLocalizedString(@"EZNav.VoiceCloning", nil) symbol:@"waveform"],
        [self navigationRowWithTitle:NSLocalizedString(@"EZNav.BrainRot", nil) symbol:@"gamecontroller.fill"],
        [self navigationRowWithTitle:NSLocalizedString(@"EZNav.Memories", nil) symbol:@"brain.head.profile"],
        [self navigationRowWithTitle:NSLocalizedString(@"EZNav.CoinStore", nil) symbol:@"circle.grid.2x2.fill"]
    ]];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.distribution = UIStackViewDistributionFillEqually;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [self.navigationDemoView addSubview:rows];

    UILabel *recent = [self demoLabel:NSLocalizedString(@"EZNav.RecentChats", nil)
                                  color:[UIColor colorWithWhite:0.68 alpha:1] font:15];
    [self.navigationDemoView addSubview:recent];
    UIView *thread = [UIView new];
    thread.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    thread.layer.cornerRadius = 10;
    thread.translatesAutoresizingMaskIntoConstraints = NO;
    [self.navigationDemoView addSubview:thread];
    UILabel *threadTitle = [self demoLabel:NSLocalizedString(@"EZTutorial.Menu.SampleChat", nil) color:UIColor.whiteColor font:14];
    [thread addSubview:threadTitle];
    UILabel *threadMeta = [self demoLabel:@"gpt-6-astra  •  7:24 p.m." color:[UIColor secondaryLabelColor] font:11];
    [thread addSubview:threadMeta];
    [NSLayoutConstraint activateConstraints:@[
        [appTitle.topAnchor constraintEqualToAnchor:self.navigationDemoView.topAnchor constant:18], [appTitle.centerXAnchor constraintEqualToAnchor:self.navigationDemoView.centerXAnchor],
        [search.leadingAnchor constraintEqualToAnchor:self.navigationDemoView.leadingAnchor constant:18], [search.centerYAnchor constraintEqualToAnchor:appTitle.centerYAnchor], [search.widthAnchor constraintEqualToConstant:23], [search.heightAnchor constraintEqualToConstant:23],
        [rows.topAnchor constraintEqualToAnchor:appTitle.bottomAnchor constant:15], [rows.leadingAnchor constraintEqualToAnchor:self.navigationDemoView.leadingAnchor constant:12], [rows.trailingAnchor constraintEqualToAnchor:self.navigationDemoView.trailingAnchor constant:-12], [rows.heightAnchor constraintEqualToConstant:198],
        [recent.topAnchor constraintEqualToAnchor:rows.bottomAnchor constant:16], [recent.leadingAnchor constraintEqualToAnchor:self.navigationDemoView.leadingAnchor constant:18],
        [thread.topAnchor constraintEqualToAnchor:recent.bottomAnchor constant:8], [thread.leadingAnchor constraintEqualToAnchor:self.navigationDemoView.leadingAnchor constant:12], [thread.trailingAnchor constraintEqualToAnchor:self.navigationDemoView.trailingAnchor constant:-12], [thread.heightAnchor constraintEqualToConstant:54],
        [threadTitle.leadingAnchor constraintEqualToAnchor:thread.leadingAnchor constant:12], [threadTitle.topAnchor constraintEqualToAnchor:thread.topAnchor constant:8], [threadTitle.trailingAnchor constraintEqualToAnchor:thread.trailingAnchor constant:-12],
        [threadMeta.leadingAnchor constraintEqualToAnchor:threadTitle.leadingAnchor], [threadMeta.topAnchor constraintEqualToAnchor:threadTitle.bottomAnchor constant:4],
    ]];
}

- (UIView *)galleryTileWithColor:(UIColor *)color symbol:(NSString *)symbol {
    UIView *tile = [UIView new];
    tile.backgroundColor = color;
    tile.layer.cornerRadius = 10;
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = [UIColor colorWithWhite:1 alpha:0.86];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor], [icon.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor],
        [icon.widthAnchor constraintEqualToAnchor:tile.widthAnchor multiplier:0.42], [icon.heightAnchor constraintEqualToAnchor:tile.heightAnchor multiplier:0.42],
    ]];
    return tile;
}

- (void)buildGalleryDemo {
    self.galleryDemoView = [UIView new];
    self.galleryDemoView.backgroundColor = [UIColor colorWithRed:0.025 green:0.04 blue:0.10 alpha:1];
    self.galleryDemoView.layer.cornerRadius = 22;
    self.galleryDemoView.layer.borderWidth = 1;
    self.galleryDemoView.layer.borderColor = [UIColor colorWithRed:0.12 green:0.78 blue:1 alpha:0.55].CGColor;
    self.galleryDemoView.hidden = YES;
    self.galleryDemoView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.galleryDemoView];
    UILabel *caption = [self demoLabel:NSLocalizedString(@"EZTutorial.Gallery.Body", nil) color:[UIColor colorWithWhite:0.84 alpha:1] font:14];
    caption.textAlignment = NSTextAlignmentCenter;
    [self.galleryDemoView addSubview:caption];
    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    [add setImage:[UIImage systemImageNamed:@"plus.circle.fill"] forState:UIControlStateNormal];
    add.tintColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1];
    add.userInteractionEnabled = NO;
    add.translatesAutoresizingMaskIntoConstraints = NO;
    [self.galleryDemoView addSubview:add];
    UIButton *select = [UIButton buttonWithType:UIButtonTypeSystem];
    [select setTitle:NSLocalizedString(@"EZGallery.Select", nil) forState:UIControlStateNormal];
    select.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    select.tintColor = [UIColor colorWithRed:1.0 green:0.80 blue:0.05 alpha:1];
    select.userInteractionEnabled = NO;
    select.translatesAutoresizingMaskIntoConstraints = NO;
    [self.galleryDemoView addSubview:select];
    UIView *grid = [UIView new];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [self.galleryDemoView addSubview:grid];
    NSArray<UIColor *> *colors = @[
        [UIColor colorWithRed:0.12 green:0.50 blue:0.66 alpha:1], [UIColor colorWithRed:0.23 green:0.23 blue:0.54 alpha:1], [UIColor colorWithRed:0.08 green:0.42 blue:0.34 alpha:1],
        [UIColor colorWithRed:0.52 green:0.24 blue:0.45 alpha:1], [UIColor colorWithRed:0.42 green:0.31 blue:0.13 alpha:1], [UIColor colorWithRed:0.19 green:0.42 blue:0.52 alpha:1]
    ];
    NSMutableArray<UIView *> *tiles = [NSMutableArray array];
    for (UIColor *color in colors) [tiles addObject:[self galleryTileWithColor:color symbol:@"photo.fill"]];
    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:[tiles subarrayWithRange:NSMakeRange(0, 3)]];
    UIStackView *bottomRow = [[UIStackView alloc] initWithArrangedSubviews:[tiles subarrayWithRange:NSMakeRange(3, 3)]];
    for (UIStackView *row in @[topRow, bottomRow]) {
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 4;
    }
    UIStackView *tileRows = [[UIStackView alloc] initWithArrangedSubviews:@[topRow, bottomRow]];
    tileRows.axis = UILayoutConstraintAxisVertical;
    tileRows.distribution = UIStackViewDistributionFillEqually;
    tileRows.spacing = 4;
    tileRows.translatesAutoresizingMaskIntoConstraints = NO;
    [grid addSubview:tileRows];
    [NSLayoutConstraint activateConstraints:@[
        [tileRows.topAnchor constraintEqualToAnchor:grid.topAnchor], [tileRows.bottomAnchor constraintEqualToAnchor:grid.bottomAnchor],
        [tileRows.leadingAnchor constraintEqualToAnchor:grid.leadingAnchor], [tileRows.trailingAnchor constraintEqualToAnchor:grid.trailingAnchor],
    ]];
    [NSLayoutConstraint activateConstraints:@[
        [add.topAnchor constraintEqualToAnchor:self.galleryDemoView.topAnchor constant:13], [add.leadingAnchor constraintEqualToAnchor:self.galleryDemoView.leadingAnchor constant:14], [add.widthAnchor constraintEqualToConstant:28], [add.heightAnchor constraintEqualToConstant:28],
        [select.centerYAnchor constraintEqualToAnchor:add.centerYAnchor], [select.trailingAnchor constraintEqualToAnchor:self.galleryDemoView.trailingAnchor constant:-14],
        [caption.topAnchor constraintEqualToAnchor:self.galleryDemoView.topAnchor constant:16], [caption.leadingAnchor constraintEqualToAnchor:add.trailingAnchor constant:12], [caption.trailingAnchor constraintEqualToAnchor:select.leadingAnchor constant:-12],
        [grid.topAnchor constraintEqualToAnchor:caption.bottomAnchor constant:16], [grid.leadingAnchor constraintEqualToAnchor:self.galleryDemoView.leadingAnchor constant:14], [grid.trailingAnchor constraintEqualToAnchor:self.galleryDemoView.trailingAnchor constant:-14], [grid.bottomAnchor constraintEqualToAnchor:self.galleryDemoView.bottomAnchor constant:-14],
    ]];
}

- (UIButton *)detailActionWithTitle:(NSString *)title symbol:(NSString *)symbol color:(UIColor *)color {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = color;
    button.layer.cornerRadius = 12;
    button.userInteractionEnabled = NO;
    button.tintColor = UIColor.whiteColor;
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [button setTitle:title forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    button.translatesAutoresizingMaskIntoConstraints = NO;
    return button;
}

- (void)buildDetailDemo {
    self.detailDemoView = [UIView new];
    self.detailDemoView.backgroundColor = [UIColor colorWithRed:0.025 green:0.035 blue:0.085 alpha:1];
    self.detailDemoView.layer.cornerRadius = 22;
    self.detailDemoView.layer.borderWidth = 1;
    self.detailDemoView.layer.borderColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:0.55].CGColor;
    self.detailDemoView.hidden = YES;
    self.detailDemoView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.detailDemoView];

    UILabel *description = [self demoLabel:NSLocalizedString(@"EZTutorial.Detail.Body", nil) color:[UIColor colorWithWhite:0.84 alpha:1] font:14];
    description.textAlignment = NSTextAlignmentCenter;
    [self.detailDemoView addSubview:description];
    UIView *preview = [self galleryTileWithColor:[UIColor colorWithRed:0.16 green:0.31 blue:0.43 alpha:1] symbol:@"photo.fill"];
    [self.detailDemoView addSubview:preview];
    UIView *prompt = [UIView new];
    prompt.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    prompt.layer.cornerRadius = 13;
    prompt.translatesAutoresizingMaskIntoConstraints = NO;
    [self.detailDemoView addSubview:prompt];
    UIImageView *plus = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"plus.circle.fill"]];
    plus.tintColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1];
    plus.translatesAutoresizingMaskIntoConstraints = NO;
    [prompt addSubview:plus];
    UILabel *placeholder = [self demoLabel:NSLocalizedString(@"EZTutorial.Detail.Prompt", nil) color:[UIColor colorWithWhite:0.65 alpha:1] font:13];
    [prompt addSubview:placeholder];
    UIButton *ask = [self detailActionWithTitle:NSLocalizedString(@"EZTutorial.Detail.Ask", nil) symbol:@"bubble.left.and.bubble.right.fill" color:[UIColor colorWithRed:0.95 green:0.70 blue:0.02 alpha:1]];
    UIButton *edit = [self detailActionWithTitle:NSLocalizedString(@"EZTutorial.Detail.Edit", nil) symbol:@"wand.and.stars" color:[UIColor colorWithRed:0.10 green:0.38 blue:0.63 alpha:1]];
    [self.detailDemoView addSubview:ask]; [self.detailDemoView addSubview:edit];
    [NSLayoutConstraint activateConstraints:@[
        [description.topAnchor constraintEqualToAnchor:self.detailDemoView.topAnchor constant:15], [description.leadingAnchor constraintEqualToAnchor:self.detailDemoView.leadingAnchor constant:16], [description.trailingAnchor constraintEqualToAnchor:self.detailDemoView.trailingAnchor constant:-16],
        [preview.topAnchor constraintEqualToAnchor:description.bottomAnchor constant:12], [preview.centerXAnchor constraintEqualToAnchor:self.detailDemoView.centerXAnchor], [preview.widthAnchor constraintEqualToAnchor:self.detailDemoView.widthAnchor multiplier:0.46], [preview.heightAnchor constraintEqualToAnchor:preview.widthAnchor],
        [prompt.topAnchor constraintEqualToAnchor:preview.bottomAnchor constant:14], [prompt.leadingAnchor constraintEqualToAnchor:self.detailDemoView.leadingAnchor constant:14], [prompt.trailingAnchor constraintEqualToAnchor:self.detailDemoView.trailingAnchor constant:-14], [prompt.heightAnchor constraintEqualToConstant:48],
        [plus.leadingAnchor constraintEqualToAnchor:prompt.leadingAnchor constant:12], [plus.centerYAnchor constraintEqualToAnchor:prompt.centerYAnchor], [plus.widthAnchor constraintEqualToConstant:26], [plus.heightAnchor constraintEqualToConstant:26],
        [placeholder.leadingAnchor constraintEqualToAnchor:plus.trailingAnchor constant:9], [placeholder.centerYAnchor constraintEqualToAnchor:prompt.centerYAnchor],
        [ask.topAnchor constraintEqualToAnchor:prompt.bottomAnchor constant:14], [ask.leadingAnchor constraintEqualToAnchor:self.detailDemoView.leadingAnchor constant:14], [ask.heightAnchor constraintEqualToConstant:48],
        [edit.topAnchor constraintEqualToAnchor:ask.topAnchor], [edit.leadingAnchor constraintEqualToAnchor:ask.trailingAnchor constant:10], [edit.trailingAnchor constraintEqualToAnchor:self.detailDemoView.trailingAnchor constant:-14], [edit.widthAnchor constraintEqualToAnchor:ask.widthAnchor], [edit.heightAnchor constraintEqualToAnchor:ask.heightAnchor],
    ]];
}

- (void)buildMemoriesDemo {
    self.memoriesDemoView = [UIView new];
    self.memoriesDemoView.backgroundColor = [UIColor colorWithRed:0.025 green:0.035 blue:0.085 alpha:1];
    self.memoriesDemoView.layer.cornerRadius = 22;
    self.memoriesDemoView.layer.borderWidth = 1;
    self.memoriesDemoView.layer.borderColor = [UIColor colorWithRed:0.10 green:0.72 blue:1 alpha:0.55].CGColor;
    self.memoriesDemoView.hidden = YES;
    self.memoriesDemoView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.memoriesDemoView];

    UILabel *description = [self demoLabel:NSLocalizedString(@"EZTutorial.Memories.Intro", nil) color:[UIColor colorWithRed:0.10 green:0.78 blue:1 alpha:1] font:18];
    description.textAlignment = NSTextAlignmentCenter;
    [self.memoriesDemoView addSubview:description];
    UIView *search = [UIView new];
    search.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    search.layer.cornerRadius = 11;
    search.translatesAutoresizingMaskIntoConstraints = NO;
    [self.memoriesDemoView addSubview:search];
    UIImageView *searchIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    searchIcon.tintColor = [UIColor colorWithWhite:1 alpha:0.58];
    searchIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [search addSubview:searchIcon];
    UILabel *searchText = [self demoLabel:NSLocalizedString(@"EZTutorial.Memories.Search", nil) color:[UIColor colorWithWhite:1 alpha:0.58] font:12];
    [search addSubview:searchText];
    UIView *memory = [UIView new];
    memory.backgroundColor = [UIColor colorWithRed:0.05 green:0.11 blue:0.19 alpha:1];
    memory.layer.cornerRadius = 13;
    memory.translatesAutoresizingMaskIntoConstraints = NO;
    [self.memoriesDemoView addSubview:memory];
    UILabel *source = [self demoLabel:NSLocalizedString(@"EZTutorial.Memories.Source", nil) color:[UIColor colorWithRed:0.10 green:0.65 blue:1 alpha:1] font:12];
    [memory addSubview:source];
    UILabel *editable = [self demoLabel:NSLocalizedString(@"EZTutorial.Memories.Editable", nil) color:UIColor.whiteColor font:13];
    editable.numberOfLines = 2;
    [memory addSubview:editable];
    UIView *image = [self galleryTileWithColor:[UIColor colorWithRed:0.18 green:0.42 blue:0.54 alpha:1] symbol:@"photo.fill"];
    [memory addSubview:image];
    UILabel *details = [self demoLabel:NSLocalizedString(@"EZTutorial.Memories.Body", nil) color:[UIColor colorWithWhite:0.82 alpha:1] font:14];
    details.textAlignment = NSTextAlignmentCenter;
    [self.memoriesDemoView addSubview:details];
    [NSLayoutConstraint activateConstraints:@[
        [description.topAnchor constraintEqualToAnchor:self.memoriesDemoView.topAnchor constant:15], [description.leadingAnchor constraintEqualToAnchor:self.memoriesDemoView.leadingAnchor constant:16], [description.trailingAnchor constraintEqualToAnchor:self.memoriesDemoView.trailingAnchor constant:-16],
        [search.topAnchor constraintEqualToAnchor:description.bottomAnchor constant:20], [search.leadingAnchor constraintEqualToAnchor:self.memoriesDemoView.leadingAnchor constant:14], [search.trailingAnchor constraintEqualToAnchor:self.memoriesDemoView.trailingAnchor constant:-14], [search.heightAnchor constraintEqualToConstant:42],
        [searchIcon.leadingAnchor constraintEqualToAnchor:search.leadingAnchor constant:12], [searchIcon.centerYAnchor constraintEqualToAnchor:search.centerYAnchor], [searchIcon.widthAnchor constraintEqualToConstant:16], [searchIcon.heightAnchor constraintEqualToConstant:16],
        [searchText.leadingAnchor constraintEqualToAnchor:searchIcon.trailingAnchor constant:8], [searchText.centerYAnchor constraintEqualToAnchor:search.centerYAnchor],
        [memory.topAnchor constraintEqualToAnchor:search.bottomAnchor constant:12], [memory.leadingAnchor constraintEqualToAnchor:self.memoriesDemoView.leadingAnchor constant:14], [memory.trailingAnchor constraintEqualToAnchor:self.memoriesDemoView.trailingAnchor constant:-14], [memory.heightAnchor constraintEqualToConstant:105],
        [source.topAnchor constraintEqualToAnchor:memory.topAnchor constant:12], [source.leadingAnchor constraintEqualToAnchor:memory.leadingAnchor constant:12], [source.trailingAnchor constraintEqualToAnchor:image.leadingAnchor constant:-8],
        [editable.topAnchor constraintEqualToAnchor:source.bottomAnchor constant:8], [editable.leadingAnchor constraintEqualToAnchor:source.leadingAnchor], [editable.trailingAnchor constraintEqualToAnchor:image.leadingAnchor constant:-8],
        [image.trailingAnchor constraintEqualToAnchor:memory.trailingAnchor constant:-12], [image.centerYAnchor constraintEqualToAnchor:memory.centerYAnchor], [image.widthAnchor constraintEqualToConstant:70], [image.heightAnchor constraintEqualToConstant:70],
        [details.topAnchor constraintEqualToAnchor:memory.bottomAnchor constant:18], [details.leadingAnchor constraintEqualToAnchor:self.memoriesDemoView.leadingAnchor constant:16], [details.trailingAnchor constraintEqualToAnchor:self.memoriesDemoView.trailingAnchor constant:-16],
    ]];
}

- (void)buildCoinStoreDemo {
    self.coinStoreDemoView = [UIView new];
    self.coinStoreDemoView.backgroundColor = [UIColor colorWithRed:0.07 green:0.025 blue:0.10 alpha:1];
    self.coinStoreDemoView.layer.cornerRadius = 22;
    self.coinStoreDemoView.layer.borderWidth = 1;
    self.coinStoreDemoView.layer.borderColor = [UIColor colorWithRed:1.0 green:0.32 blue:0.52 alpha:0.55].CGColor;
    self.coinStoreDemoView.hidden = YES;
    self.coinStoreDemoView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.coinStoreDemoView];

    UILabel *description = [self demoLabel:NSLocalizedString(@"EZTutorial.CoinStore.BodyTop", nil) color:[UIColor colorWithWhite:0.88 alpha:1] font:14];
    description.textAlignment = NSTextAlignmentCenter;
    [self.coinStoreDemoView addSubview:description];
    UIButton *usage = [UIButton buttonWithType:UIButtonTypeSystem];
    [usage setImage:[UIImage systemImageNamed:@"clock.arrow.circlepath"] forState:UIControlStateNormal];
    [usage setTitle:[NSString stringWithFormat:@" %@", NSLocalizedString(@"EZTutorial.CoinStore.Usage", nil)] forState:UIControlStateNormal];
    usage.tintColor = [UIColor colorWithRed:1.0 green:0.80 blue:0.05 alpha:1];
    usage.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    usage.userInteractionEnabled = NO;
    usage.translatesAutoresizingMaskIntoConstraints = NO;
    [self.coinStoreDemoView addSubview:usage];
    UIView *free = [UIView new];
    free.translatesAutoresizingMaskIntoConstraints = NO;
    [self.coinStoreDemoView addSubview:free];
    UIImageView *gift = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"gift.fill"]];
    gift.tintColor = [UIColor colorWithRed:1.0 green:0.28 blue:0.42 alpha:1];
    gift.contentMode = UIViewContentModeScaleAspectFit;
    gift.translatesAutoresizingMaskIntoConstraints = NO;
    [free addSubview:gift];
    NSString *freeCopy = [NSString stringWithFormat:@"%@\n%@", NSLocalizedString(@"EZTutorial.CoinStore.Next", nil), NSLocalizedString(@"EZTutorial.CoinStore.Bonus", nil)];
    UILabel *freeText = [self demoLabel:freeCopy color:UIColor.whiteColor font:10];
    freeText.textAlignment = NSTextAlignmentLeft;
    [free addSubview:freeText];
    UIView *plan = [UIView new];
    plan.backgroundColor = [UIColor colorWithRed:0.24 green:0.08 blue:0.15 alpha:1];
    plan.layer.cornerRadius = 14;
    plan.layer.borderWidth = 1;
    plan.layer.borderColor = [UIColor colorWithRed:1 green:0.18 blue:0.42 alpha:0.5].CGColor;
    plan.translatesAutoresizingMaskIntoConstraints = NO;
    [self.coinStoreDemoView addSubview:plan];
    UILabel *offer = [self demoLabel:NSLocalizedString(@"EZTutorial.CoinStore.Offer", nil) color:[UIColor colorWithRed:1.0 green:0.30 blue:0.50 alpha:1] font:13];
    offer.textAlignment = NSTextAlignmentCenter;
    [plan addSubview:offer];
    UILabel *select = [self demoLabel:NSLocalizedString(@"EZTutorial.CoinStore.Select", nil) color:UIColor.whiteColor font:13];
    select.textAlignment = NSTextAlignmentCenter;
    [plan addSubview:select];
    UILabel *bottomDescription = [self demoLabel:NSLocalizedString(@"EZTutorial.CoinStore.BodyBottom", nil) color:[UIColor colorWithWhite:0.78 alpha:1] font:13];
    bottomDescription.textAlignment = NSTextAlignmentCenter;
    [self.coinStoreDemoView addSubview:bottomDescription];
    [NSLayoutConstraint activateConstraints:@[
        [usage.topAnchor constraintEqualToAnchor:self.coinStoreDemoView.topAnchor constant:18], [usage.trailingAnchor constraintEqualToAnchor:self.coinStoreDemoView.trailingAnchor constant:-14],
        [free.topAnchor constraintEqualToAnchor:self.coinStoreDemoView.topAnchor constant:13], [free.leadingAnchor constraintEqualToAnchor:self.coinStoreDemoView.leadingAnchor constant:14], [free.trailingAnchor constraintEqualToAnchor:usage.leadingAnchor constant:-10], [free.heightAnchor constraintEqualToConstant:60],
        [description.topAnchor constraintEqualToAnchor:free.bottomAnchor constant:14], [description.leadingAnchor constraintEqualToAnchor:self.coinStoreDemoView.leadingAnchor constant:16], [description.trailingAnchor constraintEqualToAnchor:self.coinStoreDemoView.trailingAnchor constant:-16],
        [gift.leadingAnchor constraintEqualToAnchor:free.leadingAnchor], [gift.centerYAnchor constraintEqualToAnchor:free.centerYAnchor], [gift.widthAnchor constraintEqualToConstant:32], [gift.heightAnchor constraintEqualToConstant:32],
        [freeText.leadingAnchor constraintEqualToAnchor:gift.trailingAnchor constant:7], [freeText.trailingAnchor constraintEqualToAnchor:free.trailingAnchor], [freeText.centerYAnchor constraintEqualToAnchor:free.centerYAnchor],
        [plan.topAnchor constraintEqualToAnchor:description.bottomAnchor constant:14], [plan.leadingAnchor constraintEqualToAnchor:self.coinStoreDemoView.leadingAnchor constant:14], [plan.trailingAnchor constraintEqualToAnchor:self.coinStoreDemoView.trailingAnchor constant:-14], [plan.heightAnchor constraintEqualToConstant:88],
        [offer.topAnchor constraintEqualToAnchor:plan.topAnchor constant:16], [offer.leadingAnchor constraintEqualToAnchor:plan.leadingAnchor constant:10], [offer.trailingAnchor constraintEqualToAnchor:plan.trailingAnchor constant:-10],
        [select.topAnchor constraintEqualToAnchor:offer.bottomAnchor constant:12], [select.leadingAnchor constraintEqualToAnchor:plan.leadingAnchor constant:10], [select.trailingAnchor constraintEqualToAnchor:plan.trailingAnchor constant:-10],
        [bottomDescription.topAnchor constraintEqualToAnchor:plan.bottomAnchor constant:18], [bottomDescription.leadingAnchor constraintEqualToAnchor:self.coinStoreDemoView.leadingAnchor constant:16], [bottomDescription.trailingAnchor constraintEqualToAnchor:self.coinStoreDemoView.trailingAnchor constant:-16],
    ]];
}

- (void)refreshPageAnimated:(BOOL)animated {
    NSArray<NSString *> *titles = @[
        NSLocalizedString(@"EZTutorial.Welcome.Title", nil), NSLocalizedString(@"EZTutorial.Chat.Title", nil),
        NSLocalizedString(@"EZTutorial.Navigate.Title", nil), NSLocalizedString(@"EZTutorial.Gallery.Title", nil),
        NSLocalizedString(@"EZTutorial.Detail.Title", nil), NSLocalizedString(@"EZTutorial.Memories.Title", nil), NSLocalizedString(@"EZTutorial.CoinStore.Title", nil)
    ];
    NSArray<NSString *> *bodies = @[
        NSLocalizedString(@"EZTutorial.Welcome.Body", nil), NSLocalizedString(@"EZTutorial.Chat.Body", nil),
        NSLocalizedString(@"EZTutorial.Navigate.Body", nil), NSLocalizedString(@"EZTutorial.Gallery.Body", nil),
        NSLocalizedString(@"EZTutorial.Detail.Body", nil), NSLocalizedString(@"EZTutorial.Memories.Body", nil), NSLocalizedString(@"EZTutorial.CoinStore.Body", nil)
    ];
    void (^changes)(void) = ^{
        self.titleLabel.text = titles[(NSUInteger)self.pageIndex];
        self.bodyLabel.text = bodies[(NSUInteger)self.pageIndex];
        self.pageControl.currentPage = self.pageIndex;
        self.backButton.hidden = self.pageIndex == 0;
        NSString *next = self.pageIndex == self.pageControl.numberOfPages - 1
            ? NSLocalizedString(@"EZTutorial.GetStarted", nil) : NSLocalizedString(@"EZTutorial.Next", nil);
        [self.nextButton setTitle:next forState:UIControlStateNormal];
        BOOL isChatPage = self.pageIndex == 1;
        BOOL isNavigationPage = self.pageIndex == 2;
        BOOL isGalleryPage = self.pageIndex == 3;
        BOOL isDetailPage = self.pageIndex == 4;
        BOOL isMemoriesPage = self.pageIndex == 5;
        BOOL isCoinStorePage = self.pageIndex == 6;
        BOOL isDemoPage = isChatPage || isNavigationPage || isGalleryPage || isDetailPage || isMemoriesPage || isCoinStorePage;
        self.feedbackButton.hidden = self.pageIndex != self.pageControl.numberOfPages - 1;
        self.heroIcon.hidden = isDemoPage;
        self.bodyLabel.hidden = isDemoPage;
        self.chatDemoView.hidden = !isChatPage;
        self.navigationDemoView.hidden = !isNavigationPage;
        self.galleryDemoView.hidden = !isGalleryPage;
        self.detailDemoView.hidden = !isDetailPage;
        self.memoriesDemoView.hidden = !isMemoriesPage;
        self.coinStoreDemoView.hidden = !isCoinStorePage;
        self.standardTitleTopConstraint.active = !isDemoPage;
        self.chatTitleTopConstraint.active = isDemoPage;
        self.chatDemoTopConstraint.active = isChatPage;
        self.chatDemoBottomConstraint.active = isChatPage;
        self.navigationDemoTopConstraint.active = isNavigationPage;
        self.navigationDemoBottomConstraint.active = isNavigationPage;
        self.galleryDemoTopConstraint.active = isGalleryPage;
        self.galleryDemoBottomConstraint.active = isGalleryPage;
        self.detailDemoTopConstraint.active = isDetailPage;
        self.detailDemoBottomConstraint.active = isDetailPage;
        self.memoriesDemoTopConstraint.active = isMemoriesPage;
        self.memoriesDemoBottomConstraint.active = isMemoriesPage;
        self.coinStoreDemoTopConstraint.active = isCoinStorePage;
        self.coinStoreDemoBottomConstraint.active = isCoinStorePage;
    };
    if (animated) [UIView transitionWithView:self.view duration:0.22 options:UIViewAnimationOptionTransitionCrossDissolve animations:changes completion:nil];
    else changes();
}

- (void)nextTapped { if (self.pageIndex + 1 < self.pageControl.numberOfPages) { self.pageIndex++; [self refreshPageAnimated:YES]; } else [self finishTutorial]; }
- (void)backTapped { if (self.pageIndex > 0) { self.pageIndex--; [self refreshPageAnimated:YES]; } }
- (void)feedbackTapped {
    SupportRequestViewController *support = [SupportRequestViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:support];
    [self presentViewController:nav animated:YES completion:nil];
}
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
