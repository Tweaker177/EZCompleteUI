#import "EZCodeBlockCell.h"

@implementation EZCodeBlockCell {
    UILabel *_langLabel;
    UIButton *_copyBtn;
    UIButton *_shareBtn;
    UITextView *_codeView;
    NSString *_codeContent;
    NSString *_savedPath;
    __weak UIViewController *_vc;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    container.layer.cornerRadius = 10;
    container.clipsToBounds = YES;
    container.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    container.layer.borderWidth = 0.5;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:container];

    UIView *header = [[UIView alloc] init];
    header.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:header];

    _langLabel = [[UILabel alloc] init];
    _langLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    _langLabel.textColor = [UIColor colorWithRed:0.6 green:0.8 blue:1.0 alpha:1.0];
    _langLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:_langLabel];

    _shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_shareBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    _shareBtn.tintColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    _shareBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_shareBtn addTarget:self action:@selector(_shareTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:_shareBtn];

    _copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_copyBtn setTitle:@"⎘ Copy" forState:UIControlStateNormal];
    _copyBtn.tintColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    _copyBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _copyBtn.backgroundColor = [UIColor colorWithWhite:0.28 alpha:1.0];
    _copyBtn.layer.cornerRadius = 5;
    _copyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_copyBtn addTarget:self action:@selector(_copyTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:_copyBtn];

    _codeView = [[UITextView alloc] init];
    _codeView.editable = NO;
    _codeView.selectable = YES;
    _codeView.backgroundColor = [UIColor clearColor];
    _codeView.textColor = [UIColor colorWithRed:0.85 green:0.95 blue:0.85 alpha:1.0];
    _codeView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _codeView.textContainerInset = UIEdgeInsetsMake(8, 10, 8, 10);
    _codeView.scrollEnabled = YES;
    _codeView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_codeView];

    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [container.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        [container.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8],
        [container.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],

        [header.topAnchor constraintEqualToAnchor:container.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:36],

        [_langLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:12],
        [_langLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [_shareBtn.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-8],
        [_shareBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_shareBtn.widthAnchor constraintEqualToConstant:30],
        [_shareBtn.heightAnchor constraintEqualToConstant:30],

        [_copyBtn.trailingAnchor constraintEqualToAnchor:_shareBtn.leadingAnchor constant:-6],
        [_copyBtn.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [_copyBtn.widthAnchor constraintEqualToConstant:72],
        [_copyBtn.heightAnchor constraintEqualToConstant:26],

        [_codeView.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [_codeView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [_codeView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [_codeView.heightAnchor constraintEqualToConstant:MAX(120.0, UIScreen.mainScreen.bounds.size.height / 3.0)],
        [_codeView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];

    return self;
}

- (void)configureWithCode:(NSString *)code language:(NSString *)language savedPath:(NSString *)savedPath viewController:(__weak UIViewController *)vc {
    _codeContent = code;
    _savedPath = savedPath;
    _vc = vc;
    _langLabel.text = language.length > 0 ? language.uppercaseString : @"CODE";
    _codeView.text = code;
}

- (void)_copyTapped {
    if (!_codeContent.length) return;
    [UIPasteboard generalPasteboard].string = _codeContent;
    NSString *orig = [_copyBtn titleForState:UIControlStateNormal];
    [_copyBtn setTitle:@"✓ Copied!" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self->_copyBtn setTitle:orig forState:UIControlStateNormal];
    });
}

- (void)_shareTapped {
    if (!_vc) return;
    NSMutableArray *items = [NSMutableArray array];
    if (_savedPath.length && [[NSFileManager defaultManager] fileExistsAtPath:_savedPath]) {
        [items addObject:[NSURL fileURLWithPath:_savedPath]];
    } else if (_codeContent.length) {
        [items addObject:_codeContent];
    }
    if (!items.count) return;

    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    if (av.popoverPresentationController) av.popoverPresentationController.sourceView = _shareBtn;
    [_vc presentViewController:av animated:YES completion:nil];
}

@end
