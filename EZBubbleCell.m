#import "EZBubbleCell.h"
#import <QuartzCore/QuartzCore.h>

@implementation EZBubbleCell {
    UIView *_bubbleView;
    UITextView *_messageTextView;
    UILabel *_metaLabel;
    NSArray<NSLayoutConstraint *> *_alignmentConstraints;
    NSLayoutConstraint *_metaTrailing;
    NSLayoutConstraint *_metaLeading;
    BOOL _isUser;
    CGFloat _swipeOffset;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.clipsToBounds = YES;

    _metaLabel = [[UILabel alloc] init];
    _metaLabel.numberOfLines = 0;
    _metaLabel.font = [UIFont systemFontOfSize:11];
    _metaLabel.textColor = [UIColor secondaryLabelColor];
    _metaLabel.alpha = 0.0;
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_metaLabel];

    _bubbleView = [[UIView alloc] init];
    _bubbleView.translatesAutoresizingMaskIntoConstraints = NO;
    _bubbleView.layer.cornerRadius = 18.0;
    _bubbleView.clipsToBounds = YES;

    _messageTextView = [[UITextView alloc] init];
    _messageTextView.editable = NO;
    _messageTextView.selectable = YES;
    _messageTextView.scrollEnabled = NO;
    _messageTextView.dataDetectorTypes = UIDataDetectorTypeLink;
    _messageTextView.font = [UIFont systemFontOfSize:16];
    _messageTextView.backgroundColor = [UIColor clearColor];
    _messageTextView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    _messageTextView.textContainer.lineFragmentPadding = 0;
    _messageTextView.translatesAutoresizingMaskIntoConstraints = NO;

    [_bubbleView addSubview:_messageTextView];
    [self.contentView addSubview:_bubbleView];

    [NSLayoutConstraint activateConstraints:@[
        [_bubbleView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [_bubbleView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        [_messageTextView.topAnchor constraintEqualToAnchor:_bubbleView.topAnchor],
        [_messageTextView.bottomAnchor constraintEqualToAnchor:_bubbleView.bottomAnchor],
        [_messageTextView.leadingAnchor constraintEqualToAnchor:_bubbleView.leadingAnchor],
        [_messageTextView.trailingAnchor constraintEqualToAnchor:_bubbleView.trailingAnchor],
    ]];

    NSLayoutConstraint *maxW = [_bubbleView.widthAnchor constraintLessThanOrEqualToConstant:290];
    maxW.priority = UILayoutPriorityDefaultHigh;
    maxW.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [_metaLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_metaLabel.widthAnchor constraintLessThanOrEqualToConstant:160],
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_handleSwipePan:)];
    pan.delegate = self;
    pan.delaysTouchesBegan = NO;
    [self.contentView addGestureRecognizer:pan];

    return self;
}

- (void)configureWithText:(NSString *)text isUser:(BOOL)isUser {
    [self configureWithText:text isUser:isUser timestamp:nil chatKey:nil threadID:nil];
}

- (void)configureWithText:(NSString *)text
                   isUser:(BOOL)isUser
                timestamp:(nullable NSString *)timestamp
                  chatKey:(nullable NSString *)chatKey
                 threadID:(nullable NSString *)threadID {
    _isUser = isUser;
    _swipeOffset = 0.0;
    _bubbleView.transform = CGAffineTransformIdentity;
    _messageTextView.text = text;

    _bubbleView.backgroundColor = isUser
        ? [UIColor systemBlueColor]
        : [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithRed:0.20 green:0.20 blue:0.22 alpha:1.0]
                : [UIColor colorWithRed:0.90 green:0.90 blue:0.92 alpha:1.0];
        }];
    _messageTextView.backgroundColor = [UIColor clearColor];
    _messageTextView.textColor = isUser ? [UIColor whiteColor] : [UIColor labelColor];

    UIColor *linkColor = isUser
        ? [UIColor colorWithWhite:1.0 alpha:0.90]
        : [UIColor colorWithRed:0.231 green:0.510 blue:0.965 alpha:1.0];
    _messageTextView.linkTextAttributes = @{
        NSForegroundColorAttributeName: linkColor,
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
    };
    _messageTextView.tintColor = isUser ? [UIColor colorWithWhite:1.0 alpha:0.7] : [UIColor systemBlueColor];

    if (@available(iOS 11.0, *)) {
        _bubbleView.layer.maskedCorners = isUser
            ? (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner)
            : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner);
    }

    if (_alignmentConstraints) {
        [NSLayoutConstraint deactivateConstraints:_alignmentConstraints];
    }
    NSMutableArray *ac = [NSMutableArray array];
    if (isUser) {
        [ac addObject:[_bubbleView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12]];
        [ac addObject:[_bubbleView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor constant:60]];
    } else {
        [ac addObject:[_bubbleView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12]];
        [ac addObject:[_bubbleView.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-60]];
    }
    _alignmentConstraints = [ac copy];
    [NSLayoutConstraint activateConstraints:_alignmentConstraints];

    if (_metaLeading) { _metaLeading.active = NO; _metaLeading = nil; }
    if (_metaTrailing) { _metaTrailing.active = NO; _metaTrailing = nil; }

    if (isUser) {
        _metaTrailing = [_metaLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12];
    } else {
        _metaLeading = [_metaLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12];
    }
    if (_metaLeading) _metaLeading.active = YES;
    if (_metaTrailing) _metaTrailing.active = YES;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (timestamp.length > 0) [lines addObject:timestamp];
    if (chatKey.length > 0) [lines addObject:[NSString stringWithFormat:@"key: %@", chatKey]];
    if (threadID.length > 0) [lines addObject:[NSString stringWithFormat:@"thread: %@", threadID]];
    _metaLabel.text = [lines componentsJoinedByString:@"\n"];
    _metaLabel.alpha = 0.0;
    _metaLabel.textAlignment = isUser ? NSTextAlignmentRight : NSTextAlignmentLeft;
}

- (void)_handleSwipePan:(UIPanGestureRecognizer *)pan {
    static const CGFloat kMaxReveal = 140.0;
    static const CGFloat kFadeStart = 20.0;

    CGPoint translation = [pan translationInView:self.contentView];
    CGFloat raw = _isUser ? -translation.x : translation.x;
    CGFloat clamped = MAX(0.0, MIN(raw, kMaxReveal));

    switch (pan.state) {
        case UIGestureRecognizerStateChanged: {
            _swipeOffset = clamped;
            CGFloat tx = _isUser ? -clamped : clamped;
            _bubbleView.transform = CGAffineTransformMakeTranslation(tx, 0);
            CGFloat progress = MAX(0.0, (clamped - kFadeStart) / (kMaxReveal - kFadeStart));
            _metaLabel.alpha = progress;
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            _swipeOffset = 0.0;
            [UIView animateWithDuration:0.35
                                  delay:0.0
                 usingSpringWithDamping:0.75
                  initialSpringVelocity:0.5
                                options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{
                self->_bubbleView.transform = CGAffineTransformIdentity;
                self->_metaLabel.alpha = 0.0;
            } completion:nil];
            break;
        }
        default:
            break;
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)pan {
    CGPoint v = [pan velocityInView:self.contentView];
    return ABS(v.x) > ABS(v.y);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

@end
