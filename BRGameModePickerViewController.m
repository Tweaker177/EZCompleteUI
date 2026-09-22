#import "BRGameModePickerViewController.h"

@implementation BRGameModePickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.preferredContentSize = CGSizeMake(420, 440);
    self.view.backgroundColor = [UIColor colorWithRed:0.025 green:0.03 blue:0.09 alpha:1];

    UILabel *title = [UILabel new];
    title.text = NSLocalizedString(@"EZGameMode.Title", nil);
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UILabel *subtitle = [UILabel new];
    subtitle.text = NSLocalizedString(@"EZGameMode.Subtitle", nil);
    subtitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    subtitle.textColor = [UIColor colorWithWhite:0.70 alpha:1];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:subtitle];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [UIColor colorWithWhite:0.72 alpha:1];
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:close];

    UIButton *maze = [self cardWithTitle:NSLocalizedString(@"EZGameMode.Maze", nil)
                               subtitle:NSLocalizedString(@"EZGameMode.MazeDescription", nil)
                                symbol:@"map.fill"
                                 color:[UIColor colorWithRed:0.10 green:0.55 blue:0.90 alpha:1]];
    [maze addTarget:self action:@selector(mazeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:maze];

    UIButton *ricochet = [self cardWithTitle:NSLocalizedString(@"EZGameMode.Ricochet", nil)
                                   subtitle:NSLocalizedString(@"EZGameMode.RicochetDescription", nil)
                                    symbol:@"music.note.list"
                                     color:[UIColor colorWithRed:0.92 green:0.18 blue:0.48 alpha:1]];
    [ricochet addTarget:self action:@selector(ricochetTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:ricochet];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [close.topAnchor constraintEqualToAnchor:safe.topAnchor constant:14], [close.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18], [close.widthAnchor constraintEqualToConstant:32], [close.heightAnchor constraintEqualToConstant:32],
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:38], [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28], [title.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10], [subtitle.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32], [subtitle.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
        [maze.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:34], [maze.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24], [maze.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24], [maze.heightAnchor constraintEqualToConstant:118],
        [ricochet.topAnchor constraintEqualToAnchor:maze.bottomAnchor constant:18], [ricochet.leadingAnchor constraintEqualToAnchor:maze.leadingAnchor], [ricochet.trailingAnchor constraintEqualToAnchor:maze.trailingAnchor], [ricochet.heightAnchor constraintEqualToAnchor:maze.heightAnchor],
    ]];
}

- (UIButton *)cardWithTitle:(NSString *)title subtitle:(NSString *)subtitle symbol:(NSString *)symbol color:(UIColor *)color {
    UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
    card.backgroundColor = [color colorWithAlphaComponent:0.22];
    card.layer.cornerRadius = 20;
    card.layer.borderWidth = 1.5;
    card.layer.borderColor = [color colorWithAlphaComponent:0.75].CGColor;
    card.layer.shadowColor = color.CGColor;
    card.layer.shadowOpacity = 0.42;
    card.layer.shadowRadius = 14;
    card.layer.shadowOffset = CGSizeMake(0, 6);
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = color;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:icon];
    UILabel *name = [UILabel new];
    name.text = title;
    name.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    name.textColor = UIColor.whiteColor;
    name.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:name];
    UILabel *detail = [UILabel new];
    detail.text = subtitle;
    detail.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    detail.textColor = [UIColor colorWithWhite:0.84 alpha:1];
    detail.numberOfLines = 2;
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:detail];
    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    arrow.tintColor = color;
    arrow.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:arrow];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20], [icon.centerYAnchor constraintEqualToAnchor:card.centerYAnchor], [icon.widthAnchor constraintEqualToConstant:42], [icon.heightAnchor constraintEqualToConstant:42],
        [name.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:17], [name.topAnchor constraintEqualToAnchor:card.topAnchor constant:22], [name.trailingAnchor constraintEqualToAnchor:arrow.leadingAnchor constant:-12],
        [detail.leadingAnchor constraintEqualToAnchor:name.leadingAnchor], [detail.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:6], [detail.trailingAnchor constraintEqualToAnchor:name.trailingAnchor],
        [arrow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-19], [arrow.centerYAnchor constraintEqualToAnchor:card.centerYAnchor], [arrow.widthAnchor constraintEqualToConstant:12], [arrow.heightAnchor constraintEqualToConstant:20],
    ]];
    return card;
}

- (void)mazeTapped { dispatch_block_t block = self.onMazeSelected; [self dismissViewControllerAnimated:YES completion:block]; }
- (void)ricochetTapped { dispatch_block_t block = self.onRicochetSelected; [self dismissViewControllerAnimated:YES completion:block]; }
- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }

@end
