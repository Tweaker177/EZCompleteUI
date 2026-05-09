#import "EZBubbleCell.h"

@implementation EZBubbleCell {
    UIView     *_bubbleView;
    UITextView *_messageTextView;
    UILabel    *_metaLabel;          // shown when swiped left
    NSArray<NSLayoutConstraint *> *_alignmentConstraints;
    NSLayoutConstraint *_bubbleLeading;   // re-activated on swipe for user bubbles
    NSLayoutConstraint *_bubbleTrailing;  // re-activated on swipe for assistant bubbles
    NSLayoutConstraint *_metaTrailing;    // pins meta label to right of content view
    NSLayoutConstraint *_metaLeading;     // pins meta label to left of content view
    BOOL _isUser;
    CGFloat _swipeOffset;                 // current horizontal offset of bubbleView
}

// ─── init ──────────────────────────────────────────────────────────────────

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle  = UITableViewCellSelectionStyleNone;
    self.clipsToBounds   = YES;   // keep swiped bubble from rendering outside cell

    // ── Meta label (hidden until swipe) ─────────────────────────────────────
    _metaLabel = [[UILabel alloc] init];
    _metaLabel.numberOfLines  = 0;
    _metaLabel.font           = [UIFont systemFontOfSize:11];
    _metaLabel.textColor      = [UIColor secondaryLabelColor];
    _metaLabel.alpha          = 0.0;
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_metaLabel];

    // ── Bubble view ──────────────────────────────────────────────────────────
    _bubbleView = [[UIView alloc] init];
    _bubbleView.translatesAutoresizingMaskIntoConstraints = NO;
    _bubbleView.layer.cornerRadius = 18.0;
    _bubbleView.clipsToBounds      = YES;

    _messageTextView = [[UITextView alloc] init];
    _messageTextView.editable              = NO;
    _messageTextView.selectable            = YES;
    _messageTextView.scrollEnabled         = NO;
    _messageTextView.dataDetectorTypes     = UIDataDetectorTypeLink;
    _messageTextView.font                  = [UIFont systemFontOfSize:16];
    _messageTextView.backgroundColor       = [UIColor clearColor];
    _messageTextView.textContainerInset    = UIEdgeInsetsMake(10, 10, 10, 10);
    _messageTextView.textContainer.lineFragmentPadding = 0;
    _messageTextView.translatesAutoresizingMaskIntoConstraints = NO;

    [_bubbleView addSubview:_messageTextView];
    [self.contentView addSubview:_bubbleView];

    // Text view fills bubble
    [NSLayoutConstraint activateConstraints:@[
        [_bubbleView.topAnchor    constraintEqualToAnchor:self.contentView.topAnchor    constant:4],
        [_bubbleView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        [_messageTextView.topAnchor     constraintEqualToAnchor:_bubbleView.topAnchor],
        [_messageTextView.bottomAnchor  constraintEqualToAnchor:_bubbleView.bottomAnchor],
        [_messageTextView.leadingAnchor  constraintEqualToAnchor:_bubbleView.leadingAnchor],
        [_messageTextView.trailingAnchor constraintEqualToAnchor:_bubbleView.trailingAnchor],
    ]];

    // Width cap: bubble never wider than ~76% of a standard screen
    NSLayoutConstraint *maxW = [_bubbleView.widthAnchor constraintLessThanOrEqualToConstant:290];
    maxW.priority = UILayoutPriorityDefaultHigh;
    maxW.active   = YES;

    // Meta label constraints — vertically centred, width up to 160 pt
    [NSLayoutConstraint activateConstraints:@[
        [_metaLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_metaLabel.widthAnchor   constraintLessThanOrEqualToConstant:160],
    ]];
    // Horizontal pin constraints are created lazily in configure because
    // they depend on whether this is a user or assistant bubble.

    // ── Pan gesture for swipe-to-reveal ─────────────────────────────────────
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(_handleSwipePan:)];
    pan.delegate = self;
    pan.delaysTouchesBegan = NO;
    [self.contentView addGestureRecognizer:pan];


    return self;
}

// ─── configure (legacy — no metadata) ────────────────────────────────────────

- (void)configureWithText:(NSString *)text isUser:(BOOL)isUser {
    [self configureWithText:text isUser:isUser timestamp:nil chatKey:nil threadID:nil];
}

// ─── configure (with metadata) ───────────────────────────────────────────────

- (void)configureWithText:(NSString *)text
                   isUser:(BOOL)isUser
                timestamp:(nullable NSString *)timestamp
                  chatKey:(nullable NSString *)chatKey
                 threadID:(nullable NSString *)threadID {

    _isUser = isUser;
    _swipeOffset = 0.0;
    _bubbleView.transform = CGAffineTransformIdentity;

    _messageTextView.text = text;

    // ── Bubble background ────────────────────────────────────────────────────
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
        NSForegroundColorAttributeName : linkColor,
        NSUnderlineStyleAttributeName  : @(NSUnderlineStyleSingle),
    };
    _messageTextView.tintColor = isUser
        ? [UIColor colorWithWhite:1.0 alpha:0.7]
        : [UIColor systemBlueColor];

    // ── Tail ─────────────────────────────────────────────────────────────────
    if (@available(iOS 11.0, *)) {
        _bubbleView.layer.maskedCorners = isUser
            ? (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner)
            : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner);
    }

    // ── Bubble alignment ─────────────────────────────────────────────────────
    if (_alignmentConstraints) [NSLayoutConstraint deactivateConstraints:_alignmentConstraints];
    NSMutableArray *ac = [NSMutableArray array];
    if (isUser) {
        [ac addObject:[_bubbleView.trailingAnchor
            constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12]];
        [ac addObject:[_bubbleView.leadingAnchor
            constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor constant:60]];
    } else {
        [ac addObject:[_bubbleView.leadingAnchor
            constraintEqualToAnchor:self.contentView.leadingAnchor constant:12]];
        [ac addObject:[_bubbleView.trailingAnchor
            constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-60]];
    }
    _alignmentConstraints = [ac copy];
    [NSLayoutConstraint activateConstraints:_alignmentConstraints];

    // ── Meta label horizontal pin (once per isUser value) ────────────────────
    // Deactivate old pins first
    if (_metaLeading)  { _metaLeading.active  = NO; _metaLeading  = nil; }
    if (_metaTrailing) { _metaTrailing.active = NO; _metaTrailing = nil; }

    if (isUser) {
        // Meta text sits to the LEFT of the user bubble (like iMessage)
        _metaTrailing = [_metaLabel.trailingAnchor
            constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12];
    } else {
        // Meta text sits to the RIGHT of the assistant bubble
        _metaLeading = [_metaLabel.leadingAnchor
            constraintEqualToAnchor:self.contentView.leadingAnchor constant:12];
    }
    if (_metaLeading)  _metaLeading.active  = YES;
    if (_metaTrailing) _metaTrailing.active = YES;

    // ── Meta label content ────────────────────────────────────────────────────
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (timestamp.length > 0) [lines addObject:timestamp];
    if (chatKey.length  > 0) [lines addObject:[NSString stringWithFormat:@"key: %@", chatKey]];
    if (threadID.length > 0) [lines addObject:[NSString stringWithFormat:@"thread: %@", threadID]];
    _metaLabel.text  = [lines componentsJoinedByString:@"\n"];
    _metaLabel.alpha = 0.0;

    // Alignment: user messages → right-align the meta text; assistant → left
    _metaLabel.textAlignment = isUser ? NSTextAlignmentRight : NSTextAlignmentLeft;
}

// ─── Pan gesture handler ──────────────────────────────────────────────────────
// iMessage behaviour:
//   • Drag left  → bubble slides left, meta label fades in on the right
//   • Release    → springs back to origin, meta label fades out
//
// For assistant (left-aligned) bubbles we mirror: drag right reveals meta on left.

- (void)_handleSwipePan:(UIPanGestureRecognizer *)pan {
    static const CGFloat kMaxReveal = 140.0;
    static const CGFloat kFadeStart =  20.0;

    CGPoint translation = [pan translationInView:self.contentView];
    CGFloat raw     = _isUser ? -translation.x : translation.x;
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
        default: break;
    }
}


// Only begin if the gesture is more horizontal than vertical.
// This is checked before any touch is claimed, so the table's vertical
// scroll recognizer never loses its touch sequence.
- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)pan {
    CGPoint v = [pan velocityInView:self.contentView];
    return ABS(v.x) > ABS(v.y);
}

// Let the table scroll simultaneously so a slow diagonal drag doesn't
// freeze the table mid-scroll.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}

@end
