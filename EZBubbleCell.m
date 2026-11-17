#import "EZBubbleCell.h"
#import "EZTheme.h"
#import <LinkPresentation/LinkPresentation.h>

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
    UIView     *_reactionBadge;           // tapback-style pill, hidden unless set
    UILabel    *_reactionLabel;
    NSLayoutConstraint *_reactionBadgeLeading;   // user bubbles: badge at leading edge
    NSLayoutConstraint *_reactionBadgeTrailing;  // assistant bubbles: badge at trailing edge
    NSLayoutConstraint *_bubbleBottomConstraint; // deepens when a badge needs room
    UIButton   *_ttsButton;              // play/pause for chat-TTS bubbles, hidden unless set
    UIButton   *_soundButton;            // play/pause for chat sound bubbles, hidden unless set
    UIStackView *_githubPreviews;
    NSLayoutConstraint *_githubPreviewsBottom;
    NSMutableArray<LPMetadataProvider *> *_githubMetadataProviders;
    NSUInteger _githubPreviewGeneration;
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
    _metaLabel.textColor      = [EZTheme secondaryTextColor];
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
    _githubPreviews = [[UIStackView alloc] init];
    _githubPreviews.axis = UILayoutConstraintAxisVertical;
    _githubPreviews.spacing = 8;
    _githubPreviews.alignment = UIStackViewAlignmentFill;
    _githubPreviews.translatesAutoresizingMaskIntoConstraints = NO;
    [_bubbleView addSubview:_githubPreviews];
    _githubMetadataProviders = [NSMutableArray array];
    [self.contentView addSubview:_bubbleView];

    // Text and optional link cards fill the bubble.
    _bubbleBottomConstraint = [_bubbleView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4];
    _githubPreviewsBottom = [_githubPreviews.bottomAnchor constraintEqualToAnchor:_bubbleView.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [_bubbleView.topAnchor    constraintEqualToAnchor:self.contentView.topAnchor    constant:4],
        _bubbleBottomConstraint,
        [_messageTextView.topAnchor     constraintEqualToAnchor:_bubbleView.topAnchor],
        [_messageTextView.leadingAnchor  constraintEqualToAnchor:_bubbleView.leadingAnchor],
        [_messageTextView.trailingAnchor constraintEqualToAnchor:_bubbleView.trailingAnchor],
        [_githubPreviews.topAnchor constraintEqualToAnchor:_messageTextView.bottomAnchor],
        [_githubPreviews.leadingAnchor constraintEqualToAnchor:_bubbleView.leadingAnchor constant:10],
        [_githubPreviews.trailingAnchor constraintEqualToAnchor:_bubbleView.trailingAnchor constant:-10],
        _githubPreviewsBottom,
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

    // ── Reaction badge (tapback-style) ──────────────────────────────────────
    // Overlaps the bubble's bottom corner, on the side toward the middle
    // of the screen. Hidden until setReactionEmoji: gives it an emoji;
    // the bubble's bottom inset deepens then so the badge stays inside
    // the (clipping) cell bounds.
    _reactionBadge = [[UIView alloc] init];
    _reactionBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _reactionBadge.layer.cornerRadius = 10.0;
    _reactionBadge.clipsToBounds = YES;
    _reactionBadge.backgroundColor = [EZTheme cardColor];
    _reactionBadge.layer.borderWidth = 1.0;
    _reactionBadge.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.25].CGColor;
    _reactionBadge.hidden = YES;
    _reactionLabel = [[UILabel alloc] init];
    _reactionLabel.font = [UIFont systemFontOfSize:12];
    _reactionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_reactionBadge addSubview:_reactionLabel];
    [self.contentView addSubview:_reactionBadge];
    _reactionBadgeLeading  = [_reactionBadge.leadingAnchor  constraintEqualToAnchor:_bubbleView.leadingAnchor  constant:8];
    _reactionBadgeTrailing = [_reactionBadge.trailingAnchor constraintEqualToAnchor:_bubbleView.trailingAnchor constant:-8];
    [NSLayoutConstraint activateConstraints:@[
        [_reactionBadge.centerYAnchor constraintEqualToAnchor:_bubbleView.bottomAnchor],
        [_reactionBadge.heightAnchor constraintEqualToConstant:20],
        [_reactionLabel.centerXAnchor constraintEqualToAnchor:_reactionBadge.centerXAnchor],
        [_reactionLabel.centerYAnchor constraintEqualToAnchor:_reactionBadge.centerYAnchor],
        [_reactionLabel.leadingAnchor constraintEqualToAnchor:_reactionBadge.leadingAnchor constant:5],
        [_reactionLabel.trailingAnchor constraintEqualToAnchor:_reactionBadge.trailingAnchor constant:-5],
    ]];

    // ── Chat-TTS play/pause button ───────────────────────────────────────────
    // Sits just right of an assistant bubble (the 60pt trailing slack in
    // the alignment constraints leaves room). Hidden unless the row is a
    // spoken (speak_text) bubble; the view controller sets visibility,
    // the play/pause state, and the tap block on every configure pass.
    _ttsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _ttsButton.translatesAutoresizingMaskIntoConstraints = NO;
    _ttsButton.layer.cornerRadius = 15.0;
    _ttsButton.clipsToBounds = YES;
    _ttsButton.backgroundColor = [EZTheme cardColor];
    _ttsButton.tintColor = [EZTheme goldColor];
    _ttsButton.hidden = YES;
    [_ttsButton addTarget:self action:@selector(_ttsButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_ttsButton];
    [NSLayoutConstraint activateConstraints:@[
        [_ttsButton.leadingAnchor constraintEqualToAnchor:_bubbleView.trailingAnchor constant:6],
        [_ttsButton.centerYAnchor constraintEqualToAnchor:_bubbleView.centerYAnchor],
        [_ttsButton.widthAnchor  constraintEqualToConstant:30],
        [_ttsButton.heightAnchor constraintEqualToConstant:30],
    ]];
    [self setTTSPlaybackVisible:NO playing:NO];

    // Same seat as the TTS button (bubble trailing +6, 30pt): a row
    // shows one or the other, never both.
    _soundButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _soundButton.translatesAutoresizingMaskIntoConstraints = NO;
    _soundButton.layer.cornerRadius = 15.0;
    _soundButton.clipsToBounds = YES;
    _soundButton.backgroundColor = [EZTheme cardColor];
    _soundButton.tintColor = [EZTheme goldColor];
    _soundButton.hidden = YES;
    [_soundButton addTarget:self action:@selector(_soundButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:_soundButton];
    [NSLayoutConstraint activateConstraints:@[
        [_soundButton.leadingAnchor constraintEqualToAnchor:_bubbleView.trailingAnchor constant:6],
        [_soundButton.centerYAnchor constraintEqualToAnchor:_bubbleView.centerYAnchor],
        [_soundButton.widthAnchor  constraintEqualToConstant:30],
        [_soundButton.heightAnchor constraintEqualToConstant:30],
    ]];
    [self setSoundPlaybackVisible:NO playing:NO];

    // ── Pan gesture for swipe-to-reveal ─────────────────────────────────────
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(_handleSwipePan:)];
    pan.delegate = self;
    pan.delaysTouchesBegan = NO;
    [self.contentView addGestureRecognizer:pan];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(_handleLongPress:)];
    longPress.minimumPressDuration = 0.75;
    longPress.delaysTouchesBegan = NO;
    longPress.cancelsTouchesInView = NO;
    longPress.delegate = self;
    [_bubbleView addGestureRecognizer:longPress];


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
    [self ez_configureGitHubPreviewsForText:text isUser:isUser];

    // ── Bubble background ────────────────────────────────────────────────────
    _bubbleView.backgroundColor = isUser ? [EZTheme userBubbleColor]
                                         : [EZTheme assistantBubbleColor];
    _bubbleView.layer.borderWidth = isUser ? 0.0 : 1.0;
    _bubbleView.layer.borderColor = [EZTheme hairlineColor].CGColor;
    _messageTextView.backgroundColor = [UIColor clearColor];
    _messageTextView.textColor = isUser ? [EZTheme userBubbleTextColor]
                                        : [EZTheme primaryTextColor];

    UIColor *linkColor = isUser
        ? [[EZTheme userBubbleTextColor] colorWithAlphaComponent:0.85]
        : [EZTheme goldColor];
    _messageTextView.linkTextAttributes = @{
        NSForegroundColorAttributeName : linkColor,
        NSUnderlineStyleAttributeName  : @(NSUnderlineStyleSingle),
    };
    _messageTextView.tintColor = isUser
        ? [[EZTheme userBubbleTextColor] colorWithAlphaComponent:0.6]
        : [EZTheme goldColor];

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

// GitHub cards are presentation only: the original response stays intact for
// copying, selection, reactions, export, and restoration. No GitHub token is
// sent to Link Presentation; private pages may therefore show the fallback.
- (void)ez_clearGitHubPreviews {
    _githubPreviewGeneration++;
    for (LPMetadataProvider *provider in _githubMetadataProviders) [provider cancel];
    [_githubMetadataProviders removeAllObjects];
    for (UIView *view in [_githubPreviews.arrangedSubviews copy]) {
        [_githubPreviews removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    _githubPreviewsBottom.constant = 0;
}

- (void)ez_configureGitHubPreviewsForText:(NSString *)text isUser:(BOOL)isUser {
    [self ez_clearGitHubPreviews];
    if (isUser || !text.length) return;

    static NSDataDetector *detector;
    static NSCache<NSString *, LPLinkMetadata *> *metadataCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
        metadataCache = [[NSCache alloc] init];
        metadataCache.countLimit = 100;
    });
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSArray<NSTextCheckingResult *> *matches = [detector matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *match in matches) {
        NSURL *url = match.URL;
        NSString *host = url.host.lowercaseString;
        if (![url.scheme.lowercaseString isEqualToString:@"https"] ||
            !([host isEqualToString:@"github.com"] || [host isEqualToString:@"www.github.com"]) ||
            url.user.length || url.password.length || url.port || !url.absoluteString.length ||
            [seen containsObject:url.absoluteString]) continue;
        [seen addObject:url.absoluteString];

        LPLinkMetadata *metadata = [metadataCache objectForKey:url.absoluteString];
        if (!metadata) {
            metadata = [[LPLinkMetadata alloc] init];
            metadata.originalURL = url;
            metadata.URL = url;
            metadata.title = url.path.length > 1 ? url.path : @"GitHub";
        }
        UIView *container = [[UIView alloc] init];
        container.translatesAutoresizingMaskIntoConstraints = NO;
        container.layer.cornerRadius = 12;
        container.clipsToBounds = YES;
        container.backgroundColor = [EZTheme cardColor];
        LPLinkView *preview = [[LPLinkView alloc] initWithMetadata:metadata];
        preview.translatesAutoresizingMaskIntoConstraints = NO;
        preview.userInteractionEnabled = NO;
        [container addSubview:preview];
        UIButton *openButton = [UIButton buttonWithType:UIButtonTypeCustom];
        openButton.translatesAutoresizingMaskIntoConstraints = NO;
        openButton.accessibilityLabel = [NSString stringWithFormat:@"Open GitHub link: %@", url.absoluteString];
        [openButton addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }] forControlEvents:UIControlEventTouchUpInside];
        [container addSubview:openButton];
        [_githubPreviews addArrangedSubview:container];
        NSLayoutConstraint *preferredWidth = [container.widthAnchor constraintEqualToConstant:250];
        preferredWidth.priority = UILayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[
            preferredWidth,
            [container.heightAnchor constraintEqualToConstant:210],
            [preview.topAnchor constraintEqualToAnchor:container.topAnchor],
            [preview.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
            [preview.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [preview.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [openButton.topAnchor constraintEqualToAnchor:container.topAnchor],
            [openButton.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
            [openButton.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [openButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        ]];
        _githubPreviewsBottom.constant = -10;

        if ([metadataCache objectForKey:url.absoluteString]) continue;
        LPMetadataProvider *provider = [[LPMetadataProvider alloc] init];
        provider.timeout = 12;
        [_githubMetadataProviders addObject:provider];
        NSUInteger generation = _githubPreviewGeneration;
        __weak typeof(self) weakSelf = self;
        __weak LPLinkView *weakPreview = preview;
        [provider startFetchingMetadataForURL:url completionHandler:^(LPLinkMetadata *result, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) cell = weakSelf;
                if (!cell || cell->_githubPreviewGeneration != generation) return;
                [cell->_githubMetadataProviders removeObject:provider];
                if (result && !error) {
                    [metadataCache setObject:result forKey:url.absoluteString];
                    weakPreview.metadata = result;
                }
            });
        }];
    }
}

// ─── Pan gesture handler ──────────────────────────────────────────────────────
// iMessage behaviour:
//   • Drag left  → bubble slides left, meta label fades in on the right
//   • Release    → springs back to origin, meta label fades out
//
// For assistant (left-aligned) bubbles we mirror: drag right reveals meta on left.

- (void)setTTSPlaybackVisible:(BOOL)visible playing:(BOOL)playing {
    _ttsButton.hidden = !visible;
    if (visible) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
        [_ttsButton setImage:[UIImage systemImageNamed:(playing ? @"pause.fill" : @"play.fill") withConfiguration:cfg]
                    forState:UIControlStateNormal];
    }
}

- (void)_ttsButtonTapped {
    if (self.ttsButtonTapped) self.ttsButtonTapped(self);
}

- (void)setSoundPlaybackVisible:(BOOL)visible playing:(BOOL)playing {
    _soundButton.hidden = !visible;
    if (visible) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
        [_soundButton setImage:[UIImage systemImageNamed:(playing ? @"pause.fill" : @"play.fill") withConfiguration:cfg]
                    forState:UIControlStateNormal];
    }
}

- (void)_soundButtonTapped {
    if (self.soundButtonTapped) self.soundButtonTapped(self);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self ez_clearGitHubPreviews];
    [self setTTSPlaybackVisible:NO playing:NO];
    self.ttsButtonTapped = nil;
    [self setSoundPlaybackVisible:NO playing:NO];
    self.soundButtonTapped = nil;
}

- (void)setReactionEmoji:(NSString *)emoji {
    if (emoji.length) {
        _reactionLabel.text = emoji;
        _reactionBadge.hidden = NO;
        _reactionBadgeLeading.active = _isUser;
        _reactionBadgeTrailing.active = !_isUser;
        _bubbleBottomConstraint.constant = -14;
    } else {
        _reactionLabel.text = nil;
        _reactionBadge.hidden = YES;
        _reactionBadgeLeading.active = NO;
        _reactionBadgeTrailing.active = NO;
        _bubbleBottomConstraint.constant = -4;
    }
}

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

// ── Long-press copy ────────────────────────────────────────────────────────

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    return action == @selector(copyBubbleText:);
}

- (void)copyBubbleText:(id)sender {
    if (_messageTextView.text.length == 0) return;
    [UIPasteboard generalPasteboard].string = _messageTextView.text;
    [[UIMenuController sharedMenuController] setMenuVisible:NO animated:YES];
    [self resignFirstResponder];
}

- (void)_handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    [self becomeFirstResponder];
    UIMenuItem *copyItem = [[UIMenuItem alloc] initWithTitle:@"Copy"
                                                      action:@selector(copyBubbleText:)];
    UIMenuController *menu = [UIMenuController sharedMenuController];
    menu.menuItems = @[copyItem];
    [menu setTargetRect:_bubbleView.frame inView:self];
    [menu setMenuVisible:YES animated:YES];
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
