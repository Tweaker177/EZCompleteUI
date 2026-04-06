// ViewController.m
// EZCompleteUI v6.8
//
// Changes from v6.7:
//   - Fixed: stale lastImageLocalPath no longer injected into unrelated memory entries
//     Root cause: chatContext scan for _isVisionAttachment was permanently sticky after
//     the first image send; replaced with pendingImagePath check (this-turn-only signal)
//   - Fixed same bug in direct-answer (Tier 1) memory path — same stale injection removed
//   - pendingImagePath now cleared immediately after capture in both memory paths
//
// Changes from v6.6:
//   - GPT-5 timeout increased (180s solo, 240s with web search)
//   - Web search now silently skipped with warning for incompatible models
//   - Copy button shows checkmark confirmation for 1.5s
//   - Language→extension map fixed for objective-c/objc variants + normalization
//   - Image display intent detection: "show it again" reopens instead of regenerating
//   - attachmentPaths now always includes lastImageLocalPath + pendingImagePath
//   - Code block detection: extracts ```, saves to EZAttachments, renders inline widget
//   - processReplyWithCodeBlocks: saves snippets, returns display string with placeholders
//   - sanitizedContextForAPI: converts image/text block types for Responses vs Chat API
//   - ElevenLabs + Whisper keys now stored via EZKeyVault (Keychain), not NSUserDefaults
//   - URLs in AI responses are now tappable (dataDetectorTypes) with styled link appearance
//   - checkReplyForLocalFilePaths regex broadened to /var/mobile/ prefix + any extension
//   - Bubble chat UI: UITableView replaces UITextView; user (blue, right) and
//     assistant (gray, left) message bubbles with iMessage-style tail corners
//   - Code blocks rendered as EZCodeBlockCell with Copy + Share buttons
//   - Thread title now set from attachment filename when attachment is first action
//   - Sora: video deferred to pendingVideoURL when app is backgrounded, presented on foreground
//
// Changes from v6.5 / v6.6:
//   - Code blocks fixed at ~1/3 screen height with internal scrolling (restored original look)
//   - Spurious attachment bug fixed: lastImageLocalPath/pendingImagePath no longer blindly
//     injected into every chat completion's captured attachments
//   - gpt-image-1 models expanded: gpt-image-1.5, gpt-image-1-mini, chatgpt-image-latest
//   - Image generation settings: quality, size, output_format, background, moderation
//     stored in NSUserDefaults; showImageSettings sheet from model button when image model active

#import "ViewController.h"
#import "SettingsViewController.h"
#import "ChatHistoryViewController.h"
#import "helpers.h"
#import "EZKeyVault.h"
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuickLook/QuickLook.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <PDFKit/PDFKit.h>
#import <QuartzCore/QuartzCore.h>
#import "SidewaysScrollView.h"

@interface ViewController (EZKeepAwakeInjected)
- (void)ezcui_beginLongOperation:(NSString *)reason;
- (void)ezcui_endLongOperation;
@end



//@class SidewaysScrollView;


typedef NS_ENUM(NSInteger, EZAttachMode) {
    EZAttachModeNone,
    EZAttachModeWhisper,
    EZAttachModeAnalyze,
};

@interface ViewController () <UIDocumentPickerDelegate,
                               UITextFieldDelegate,
                               UITableViewDataSource,
                               UITableViewDelegate,
                               QLPreviewControllerDataSource,
                               SFSpeechRecognizerDelegate,
                               ChatHistoryViewControllerDelegate>




// UI
/// UITableView that renders all chat messages as bubble / system / code cells.
//@property (nonatomic, strong) UITableView   *chatTableView;
/// Flat array of display-message dicts driving chatTableView.
/// Keys: role (@"user"|@"assistant"|@"system"|@"code"), text, language, savedPath.
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *displayMessages;
@property (nonatomic, strong) UIView        *inputContainer;
@property (nonatomic, strong) UITextField   *messageTextField;
@property (nonatomic, strong) UIButton      *sendButton;
@property (nonatomic, strong) UIButton      *modelButton;
@property (nonatomic, strong) UIButton      *attachButton;
@property (nonatomic, strong) UIButton      *settingsButton;
@property (nonatomic, strong) UIButton      *clipboardButton;
@property (nonatomic, strong) UIButton      *speakButton;
@property (nonatomic, strong) UIButton      *clearButton;
/// Appears in input area when an image model is active — opens image parameter sheet.
@property (nonatomic, strong) UIButton      *imageSettingsButton;
@property (nonatomic, strong) UIButton      *dictateButton;
@property (nonatomic, strong) UIButton      *webSearchButton;
@property (nonatomic, strong) UIButton      *historyButton;
@property (nonatomic, strong) UIButton      *addChatButton;
@property (nonatomic, strong) NSLayoutConstraint *containerBottomConstraint;
/// Tappable label showing the active thread title — tap to rename.
@property (nonatomic, strong) UILabel       *threadTitleLabel;
/// Button in top bar that triggers renaming.
@property (nonatomic, strong) UIButton      *renameButton;

// State
@property (nonatomic, strong) NSArray       *models;
@property (nonatomic, strong) NSString      *selectedModel;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *chatContext;
@property (nonatomic, assign) BOOL          webSearchEnabled;

// Active thread
@property (nonatomic, strong) EZChatThread  *activeThread;

// Media / file state
@property (nonatomic, strong) NSURL         *previewURL;
/// Non-nil when a Sora video completed while the app was backgrounded.
/// Presented the next time the view becomes visible.
@property (nonatomic, strong) NSURL         *pendingVideoURL;
@property (nonatomic, strong) NSString      *pendingFileContext;   // text extracted from file
@property (nonatomic, strong) NSString      *pendingFileName;
@property (nonatomic, strong) NSString      *pendingImagePath;     // local path of attached image
@property (nonatomic, strong) NSString      *lastImagePrompt;      // last DALL-E prompt (for follow-ups)
@property (nonatomic, strong) NSString      *lastImageLocalPath;   // local path of last generated image

// TTS / audio
@property (nonatomic, strong) AVSpeechSynthesizer *speechSynthesizer;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSString      *lastAIResponse;
@property (nonatomic, strong) NSString      *lastUserPrompt;

// Dictation
@property (nonatomic, strong) SFSpeechRecognizer               *speechRecognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *recognitionRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask          *recognitionTask;
@property (nonatomic, strong) AVAudioEngine                    *audioEngine;
@property (nonatomic, assign) BOOL                              isDictating;


    // Sideways-scrolling top-row container (inserted)
    @property (nonatomic, strong) UIView *topButtonsContainer;
    @property (nonatomic, strong) SidewaysScrollView *sidewaysScrollView;
@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat Cell Classes
// ─────────────────────────────────────────────────────────────────────────────

// ── EZBubbleCell ──────────────────────────────────────────────────────────────
// Renders a single user or assistant chat message as a colored bubble.
// Uses UITextView (non-editable, selectable) so that:
//   • Links are detected and tappable
//   • The user can place the cursor and select any span of text
//   • The system copy/share/lookup menu appears on selection automatically
@interface EZBubbleCell : UITableViewCell
- (void)configureWithText:(NSString *)text isUser:(BOOL)isUser;
@end

@implementation EZBubbleCell {
    UIView     *_bubbleView;
    UITextView *_messageTextView;
    NSArray<NSLayoutConstraint *> *_alignmentConstraints;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle  = UITableViewCellSelectionStyleNone;

    _bubbleView = [[UIView alloc] init];
    _bubbleView.translatesAutoresizingMaskIntoConstraints = NO;
    _bubbleView.layer.cornerRadius = 18.0;
    _bubbleView.clipsToBounds      = YES;

    // Non-editable, selectable UITextView.
    // scrollEnabled=NO lets Auto Layout drive cell height from content.
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

    return self;
}

- (void)configureWithText:(NSString *)text isUser:(BOOL)isUser {
    _messageTextView.text = text;

    // ── Bubble background ────────────────────────────────────────────────────
    _bubbleView.backgroundColor      = isUser
        ? [UIColor systemBlueColor]
        : [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
               return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? [UIColor colorWithRed:0.20 green:0.20 blue:0.22 alpha:1.0]
                   : [UIColor colorWithRed:0.90 green:0.90 blue:0.92 alpha:1.0];
           }];
    _messageTextView.backgroundColor = [UIColor clearColor];

    // ── Text color ───────────────────────────────────────────────────────────
    _messageTextView.textColor = isUser ? [UIColor whiteColor] : [UIColor labelColor];

    // ── Link color: white on blue (user), system blue on gray (assistant) ────
    UIColor *linkColor = isUser
        ? [UIColor colorWithWhite:1.0 alpha:0.90]
        : [UIColor colorWithRed:0.231 green:0.510 blue:0.965 alpha:1.0];
    _messageTextView.linkTextAttributes = @{
        NSForegroundColorAttributeName : linkColor,
        NSUnderlineStyleAttributeName  : @(NSUnderlineStyleSingle),
    };

    // Selection handles match bubble context
    _messageTextView.tintColor = isUser
        ? [UIColor colorWithWhite:1.0 alpha:0.7]
        : [UIColor systemBlueColor];

    // ── Tail: one flat corner pointing toward the speaker ────────────────────
    if (@available(iOS 11.0, *)) {
        _bubbleView.layer.maskedCorners = isUser
            // User (right-aligned) → flat bottom-right corner
            ? (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner)
            // Assistant (left-aligned) → flat bottom-left corner
            : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner);
    }

    // ── Alignment: pin bubble to the appropriate side ────────────────────────
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
}
@end

// ── EZSystemCell ──────────────────────────────────────────────────────────────
// Centered small-font text for [System: ...] and [Error: ...] status lines.
@interface EZSystemCell : UITableViewCell
@property (nonatomic, strong) UILabel *messageLabel;
@end

@implementation EZSystemCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle  = UITableViewCellSelectionStyleNone;

    _messageLabel                = [[UILabel alloc] init];
    _messageLabel.numberOfLines  = 0;
    _messageLabel.textAlignment  = NSTextAlignmentCenter;
    _messageLabel.font           = [UIFont systemFontOfSize:12];
    _messageLabel.textColor      = [UIColor secondaryLabelColor];
    _messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_messageLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_messageLabel.topAnchor      constraintEqualToAnchor:self.contentView.topAnchor      constant:3],
        [_messageLabel.bottomAnchor   constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-3],
        [_messageLabel.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor  constant:16],
        [_messageLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
    ]];
    return self;
}
@end

// ── EZCodeBlockCell ───────────────────────────────────────────────────────────
// Full-width dark code block with language label, Copy button, and Share button.
@interface EZCodeBlockCell : UITableViewCell
- (void)configureWithCode:(NSString *)code
                 language:(NSString *)language
                savedPath:(nullable NSString *)savedPath
           viewController:(__weak UIViewController *)vc;
@end

@implementation EZCodeBlockCell {
    UILabel    *_langLabel;
    UIButton   *_copyBtn;
    UIButton   *_shareBtn;
    UITextView *_codeView;
    NSString   *_codeContent;
    NSString   *_savedPath;
    __weak UIViewController *_vc;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle  = UITableViewCellSelectionStyleNone;

    UIView *container          = [[UIView alloc] init];
    container.backgroundColor  = [UIColor colorWithWhite:0.12 alpha:1.0];
    container.layer.cornerRadius = 10;
    container.clipsToBounds    = YES;
    container.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    container.layer.borderWidth = 0.5;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:container];

    UIView *header              = [[UIView alloc] init];
    header.backgroundColor      = [UIColor colorWithWhite:0.18 alpha:1.0];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:header];

    _langLabel                  = [[UILabel alloc] init];
    _langLabel.font             = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    _langLabel.textColor        = [UIColor colorWithRed:0.6 green:0.8 blue:1.0 alpha:1.0];
    _langLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:_langLabel];

    // Share button (todo #5)
    _shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_shareBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    _shareBtn.tintColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    _shareBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_shareBtn addTarget:self action:@selector(_shareTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:_shareBtn];

    _copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_copyBtn setTitle:@"\u2398 Copy" forState:UIControlStateNormal];
    _copyBtn.tintColor          = [UIColor colorWithWhite:0.8 alpha:1.0];
    _copyBtn.titleLabel.font    = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _copyBtn.backgroundColor    = [UIColor colorWithWhite:0.28 alpha:1.0];
    _copyBtn.layer.cornerRadius = 5;
    _copyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_copyBtn addTarget:self action:@selector(_copyTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:_copyBtn];

    _codeView                       = [[UITextView alloc] init];
    _codeView.editable              = NO;
    _codeView.selectable            = YES;
    _codeView.backgroundColor       = [UIColor clearColor];
    _codeView.textColor             = [UIColor colorWithRed:0.85 green:0.95 blue:0.85 alpha:1.0];
    _codeView.font                  = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _codeView.textContainerInset    = UIEdgeInsetsMake(8, 10, 8, 10);
    // scrollEnabled=YES so content scrolls inside the fixed-height cell (original widget look)
    _codeView.scrollEnabled         = YES;
    _codeView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_codeView];

    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor      constraintEqualToAnchor:self.contentView.topAnchor      constant:4],
        [container.bottomAnchor   constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-4],
        [container.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor  constant:8],
        [container.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],

        [header.topAnchor      constraintEqualToAnchor:container.topAnchor],
        [header.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [header.heightAnchor   constraintEqualToConstant:36],

        [_langLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:12],
        [_langLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [_shareBtn.trailingAnchor  constraintEqualToAnchor:header.trailingAnchor constant:-8],
        [_shareBtn.centerYAnchor   constraintEqualToAnchor:header.centerYAnchor],
        [_shareBtn.widthAnchor     constraintEqualToConstant:30],
        [_shareBtn.heightAnchor    constraintEqualToConstant:30],

        [_copyBtn.trailingAnchor constraintEqualToAnchor:_shareBtn.leadingAnchor constant:-6],
        [_copyBtn.centerYAnchor  constraintEqualToAnchor:header.centerYAnchor],
        [_copyBtn.widthAnchor    constraintEqualToConstant:72],
        [_copyBtn.heightAnchor   constraintEqualToConstant:26],

        [_codeView.topAnchor      constraintEqualToAnchor:header.bottomAnchor],
        [_codeView.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor],
        [_codeView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        // Fixed height ~1/3 screen so the cell stays compact and content scrolls inside.
        // Container bottom is driven by this height rather than expanding to content.
        [_codeView.heightAnchor   constraintEqualToConstant:
            MAX(120.0, UIScreen.mainScreen.bounds.size.height / 3.0)],
        [_codeView.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor],
    ]];
    return self;
}

- (void)configureWithCode:(NSString *)code language:(NSString *)language
               savedPath:(NSString *)savedPath viewController:(__weak UIViewController *)vc {
    _codeContent        = code;
    _savedPath          = savedPath;
    _vc                 = vc;
    _langLabel.text     = language.length > 0 ? language.uppercaseString : @"CODE";
    _codeView.text      = code;
}

- (void)_copyTapped {
    if (!_codeContent.length) return;
    [UIPasteboard generalPasteboard].string = _codeContent;
    NSString *orig = [_copyBtn titleForState:UIControlStateNormal];
    [_copyBtn setTitle:@"✓ Copied!" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self->_copyBtn setTitle:orig forState:UIControlStateNormal]; });
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
    UIActivityViewController *av = [[UIActivityViewController alloc]
        initWithActivityItems:items applicationActivities:nil];
    if (av.popoverPresentationController) av.popoverPresentationController.sourceView = _shareBtn;
    [_vc presentViewController:av animated:YES completion:nil];
}
@end

/***/
//#pragma mark - SidewaysScrollView (inserted by patch_viewcontroller.py)

/*
 SidewaysScrollView
 - A lightweight horizontally-scrolling container that creates a seamless
   circular scroll effect (icons scroll off the left and reappear on the right).
 - Designed to be embedded inside ViewController.m (no separate header).
 - Buttons are duplicated internally to achieve wrap-around behavior.

@interface SidewaysScrollView : UIView <UIScrollViewDelegate>

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) NSArray<UIButton *> *sourceButtons; // original button prototypes
@property (nonatomic, assign) CGFloat buttonWidth;
@property (nonatomic, assign) CGFloat buttonHeight;

- (void)configureWithButtons:(NSArray<UIButton *> *)buttons doubleSize:(BOOL)doubleSize;

@end

@implementation SidewaysScrollView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];

    _scrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.delegate = self;
    _scrollView.alwaysBounceHorizontal = YES;
    _scrollView.clipsToBounds = NO; // allow shadow to be visible when going off edges
    [self addSubview:_scrollView];

    // Auto Layout for scrollView to fill self
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // If button sizes weren't set yet, attempt to relayout based on current size.
    if (self.sourceButtons && (self.buttonWidth == 0 || self.buttonHeight == 0)) {
        CGFloat h = CGRectGetHeight(self.bounds);
        // default: use full height for buttons
        self.buttonHeight = h;
        // width will be set proportionally if it was zero
        if (self.buttonWidth == 0) {
            self.buttonWidth = self.buttonHeight; // square by default; controller can override
        }
        [self rebuildScrollContent];
    }
}

- (void)configureWithButtons:(NSArray<UIButton *> *)buttons doubleSize:(BOOL)doubleSize {
    // Store prototype buttons (we will copy their visuals)
    NSMutableArray *clones = [NSMutableArray arrayWithCapacity:buttons.count];
    for (UIButton *b in buttons) {
        // create a lightweight prototype copy with same title/image/backgroundColor
        UIButton *copy = [UIButton buttonWithType:UIButtonTypeCustom];
        copy.tag = b.tag;
        copy.layer.cornerRadius = b.layer.cornerRadius;
        copy.layer.borderWidth = b.layer.borderWidth;
        copy.layer.borderColor = b.layer.borderColor;
        copy.layer.shadowColor = b.layer.shadowColor;
        copy.layer.shadowOffset = b.layer.shadowOffset;
        copy.layer.shadowOpacity = b.layer.shadowOpacity;
        copy.layer.shadowRadius = b.layer.shadowRadius;
        copy.titleLabel.font = b.titleLabel.font;
        copy.adjustsImageWhenHighlighted = NO;

        // copy title / image / background color states conservatively
        NSString *title = [b titleForState:UIControlStateNormal];
        if (title) [copy setTitle:title forState:UIControlStateNormal];
        UIImage *img = [b imageForState:UIControlStateNormal];
        if (img) [copy setImage:img forState:UIControlStateNormal];
        copy.backgroundColor = b.backgroundColor ?: [UIColor clearColor];

        [clones addObject:copy];
    }
    self.sourceButtons = clones;

    // default sizing: base on our own height; can be doubled by request
    CGFloat h = CGRectGetHeight(self.bounds);
    if (h <= 1.0) {
        // view hasn't been sized yet; pick a reasonable default
        h = 88.0;
    }
    self.buttonHeight = doubleSize ? (h * 2.0) : h;
    // default width proportional to height (square buttons)
    self.buttonWidth = self.buttonHeight;

    // rebuild content immediately if possible
    [self rebuildScrollContent];
}

- (void)rebuildScrollContent {
    // remove everything
    for (UIView *v in self.scrollView.subviews) {
        [v removeFromSuperview];
    }
    if (!self.sourceButtons || self.sourceButtons.count == 0) {
        self.scrollView.contentSize = CGSizeZero;
        return;
    }

    NSInteger n = (NSInteger)self.sourceButtons.count;
    // We duplicate the sequence twice to allow seamless wrap-around.
    CGFloat itemW = self.buttonWidth;
    CGFloat itemH = self.buttonHeight;

    // If the scrollView's height is smaller than itemH, adjust the itemH and keep corner radius reasonable
    if (CGRectGetHeight(self.bounds) < itemH) {
        itemH = CGRectGetHeight(self.bounds);
    }

    // create 2 * n buttons
    for (NSInteger copyIndex = 0; copyIndex < 2; copyIndex++) {
        for (NSInteger i = 0; i < n; i++) {
            UIButton *proto = self.sourceButtons[i];
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            // copy visuals
            btn.tag = proto.tag ?: i;
            NSString *title = [proto titleForState:UIControlStateNormal];
            if (title) [btn setTitle:title forState:UIControlStateNormal];
            UIImage *img = [proto imageForState:UIControlStateNormal];
            if (img) [btn setImage:img forState:UIControlStateNormal];
            btn.backgroundColor = proto.backgroundColor ?: [UIColor systemBlueColor];
            btn.titleLabel.font = proto.titleLabel.font ?: [UIFont systemFontOfSize:14];
            btn.layer.cornerRadius = MAX(8.0, MIN(itemH * 0.15, 16.0));
            btn.clipsToBounds = YES;
            // apply vibrant border/shadow styling for visibility
            btn.layer.borderWidth = 1.0;
            btn.layer.borderColor = [UIColor colorWithWhite:0.9 alpha:1.0].CGColor;
            btn.layer.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.25].CGColor;
            btn.layer.shadowOffset = CGSizeMake(0, 3);
            btn.layer.shadowOpacity = 0.6;
            btn.layer.shadowRadius = 6.0;
            btn.adjustsImageWhenHighlighted = YES;
            btn.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);

            // position
            CGFloat x = (copyIndex * n + i) * itemW + (itemW - itemW) / 2.0;
            btn.frame = CGRectMake(x, (CGRectGetHeight(self.bounds) - itemH) / 2.0, itemW, itemH);

            // ensure title color is readable
            UIColor *titleColor = [UIColor labelColor];
            if (btn.backgroundColor) {
                CGFloat white = 0.0;
                [btn.backgroundColor getWhite:&white alpha:NULL];
                // if background is dark-ish, use white
                if (white < 0.6) {
                    titleColor = [UIColor whiteColor];
                } else {
                    titleColor = [UIColor blackColor];
                }
            }
            [btn setTitleColor:titleColor forState:UIControlStateNormal];

            // map action to a generic selector which ViewController will pick up via responder chain
            [btn addTarget:nil action:@selector(sidewaysTopButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

            [self.scrollView addSubview:btn];
        }
    }

    CGFloat contentW = itemW * n * 2;
    self.scrollView.contentSize = CGSizeMake(contentW, CGRectGetHeight(self.bounds));

    // start centered on the first copy (i.e. offset 0)
    self.scrollView.contentOffset = CGPointMake(0, 0);

    // If content smaller than frame, center horizontally
    if (self.scrollView.contentSize.width <= CGRectGetWidth(self.scrollView.bounds)) {
        CGFloat inset = (CGRectGetWidth(self.scrollView.bounds) - self.scrollView.contentSize.width) / 2.0;
        self.scrollView.contentInset = UIEdgeInsetsMake(0, inset, 0, inset);
    } else {
        self.scrollView.contentInset = UIEdgeInsetsZero;
    }
}

#pragma mark - UIScrollViewDelegate (circular wrap)

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // perform wrap-around whenever the offset crosses the length of the source sequence
    if (!self.sourceButtons || self.sourceButtons.count == 0) return;
    CGFloat singleWidth = self.buttonWidth * (CGFloat)self.sourceButtons.count;
    if (singleWidth <= 0) return;

    CGFloat x = scrollView.contentOffset.x;

    // When we move beyond the first sequence into the second, wrap back by subtracting singleWidth.
    // When we move left before 0, wrap forward adding singleWidth.
    if (x >= singleWidth) {
        // Keep visual continuity by preserving fractional remainder
        scrollView.contentOffset = CGPointMake(fmod(x, singleWidth), 0);
    } else if (x < 0) {
        // Add singleWidth to move into the second copy equivalently
        CGFloat wrapped = singleWidth + fmod(x, singleWidth);
        // fmod can be negative; ensure within 0..singleWidth
        if (wrapped >= singleWidth) wrapped -= singleWidth;
        scrollView.contentOffset = CGPointMake(wrapped, 0);
    }
}

@end

#pragma mark - End SidewaysScrollView
********************/


@implementation ViewController

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];

    // --- START: Sideways scrolling top-row (injected) ---
    if (!self.topButtonsContainer) {
        UIView *container = [[UIView alloc] init];
        container.translatesAutoresizingMaskIntoConstraints = NO;
        container.backgroundColor = [UIColor clearColor];
        container.clipsToBounds = NO;
        [self.view addSubview:container];
        self.topButtonsContainer = container;

        CGFloat injectedHeight = 120.0; // double-size visual row (buttons will be ~240pt tall, centered)
        [NSLayoutConstraint activateConstraints:@[
            [container.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8.0],
            [container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8.0],
            [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8.0],
            [container.heightAnchor constraintEqualToConstant:injectedHeight]
        ]];

        SidewaysScrollView *ssv = [[SidewaysScrollView alloc] initWithFrame:CGRectZero];
        ssv.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:ssv];
        [NSLayoutConstraint activateConstraints:@[
            [ssv.topAnchor constraintEqualToAnchor:container.topAnchor],
            [ssv.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
            [ssv.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [ssv.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        ]];
        self.sidewaysScrollView = ssv;

        NSMutableArray<UIButton *> *protoButtons = [NSMutableArray array];
        NSArray<UIColor *> *colors = @[
            [UIColor colorWithRed:0.95 green:0.38 blue:0.38 alpha:1.0],
            [UIColor colorWithRed:0.95 green:0.70 blue:0.28 alpha:1.0],
            [UIColor colorWithRed:0.45 green:0.77 blue:0.33 alpha:1.0],
            [UIColor colorWithRed:0.36 green:0.66 blue:0.96 alpha:1.0],
            [UIColor colorWithRed:0.70 green:0.49 blue:0.96 alpha:1.0],
            [UIColor colorWithRed:0.95 green:0.55 blue:0.80 alpha:1.0],
            [UIColor colorWithRed:0.40 green:0.80 blue:0.72 alpha:1.0],
            [UIColor colorWithRed:0.98 green:0.62 blue:0.25 alpha:1.0],
            [UIColor colorWithRed:0.56 green:0.76 blue:0.98 alpha:1.0],
            [UIColor colorWithRed:0.85 green:0.46 blue:0.36 alpha:1.0],
        ];
        for (NSInteger i = 0; i < 10; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            b.tag = (int)i + 1000;
            [b setTitle:[NSString stringWithFormat:@"Item %ld", (long)i+1] forState:UIControlStateNormal];
            b.backgroundColor = colors[i % colors.count];
            b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            b.layer.cornerRadius = 12.0;
            [protoButtons addObject:b];
        }
        [self.sidewaysScrollView configureWithButtons:protoButtons doubleSize:YES];

        // Avoid overlaying the chat table: inset its content from the top if present
        if (self.chatTableView) {
            UIEdgeInsets insets = self.chatTableView.contentInset;
            CGFloat neededTop = injectedHeight + 12.0;
            if (insets.top < neededTop) {
                insets.top = neededTop;
                self.chatTableView.contentInset = insets;
                self.chatTableView.scrollIndicatorInsets = insets;
            }
        }
        [self.view bringSubviewToFront:self.topButtonsContainer];
    }
    // --- END: Sideways scrolling top-row (injected) ---


    EZLogRotateIfNeeded(512 * 1024);
    EZLog(EZLogLevelInfo, @"APP", @"EZCompleteUI v4.0 viewDidLoad");
    [self setupData];
    [self setupUI];
    [self setupKeyboardObservers];
    [self setupDictation];
    [self requestSpeechPermissionsIfNeeded];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(resumePendingSoraJobIfNeeded)
        name:@"EZAppDidBecomeActive" object:nil];
}

- (void)setupData {
    // Model list — internal identifiers. Display labels added in showModelPicker.
    self.models = @[
        // ── Chat / Reasoning ──────────────────────────────────────────────
        @"gpt-5-pro", @"gpt-5", @"gpt-5-mini",
        @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4",
        @"gpt-3.5-turbo",
        // ── Image Generation & Edit ───────────────────────────────────────
        @"gpt-image-1.5",        // newest image model
        @"gpt-image-1",          // generation + edit
        @"gpt-image-1-mini",     // faster/cheaper image generation
        @"chatgpt-image-latest", // always points to current ChatGPT image model
        @"dall-e-3",             // generation only (legacy)
        // ── Video ─────────────────────────────────────────────────────────
        @"sora-2", @"sora-2-pro",
        // ── Audio ─────────────────────────────────────────────────────────
        @"whisper-1"
    ];
    self.chatContext        = [NSMutableArray array];
    self.displayMessages    = [NSMutableArray array];
    self.speechSynthesizer = [[AVSpeechSynthesizer alloc] init];
    self.selectedModel     = [[NSUserDefaults standardUserDefaults] stringForKey:@"selectedModel"]
                             ?: self.models[0];
    self.webSearchEnabled  = [[NSUserDefaults standardUserDefaults] boolForKey:@"webSearchEnabled"];

    // Set a sensible default system message if the user hasn't configured one yet.
    // This avoids the model claiming it "can't" do things it absolutely can.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults stringForKey:@"systemMessage"].length) {
        [defaults setObject:
            @"You are a capable AI assistant with access to the user's conversation history and memories. "
             "When the user references a previous file, image, or conversation, use the context provided. "
             "If a local file path is provided in your context (e.g. in a memory entry), "
             "provide it exactly as given — never fabricate paths. "
             "You can display images by providing their exact local file path starting with /var/mobile/. "
             "Be direct and specific in responses."
                     forKey:@"systemMessage"];
    }

    // Restore persisted image/attachment paths so they survive app restarts.
    // This is the key fix for "reopen image" failing — lastImageLocalPath was
    // always nil after relaunch, so the intent check fell through to generation.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *savedImagePath = [d stringForKey:@"lastImageLocalPath"];
    if (savedImagePath.length > 0 &&
        [[NSFileManager defaultManager] fileExistsAtPath:savedImagePath]) {
        self.lastImageLocalPath = savedImagePath;
        EZLogf(EZLogLevelInfo, @"APP", @"Restored lastImageLocalPath: %@",
               savedImagePath.lastPathComponent);
    }
    NSString *savedPrompt = [d stringForKey:@"lastImagePrompt"];
    if (savedPrompt.length > 0) {
        self.lastImagePrompt = savedPrompt;
    }

    [self startNewThread];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Thread Management
// ─────────────────────────────────────────────────────────────────────────────

- (void)startNewThread {
    EZChatThread *t = [[EZChatThread alloc] init];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat       = @"yyyy-MM-dd'T'HH:mm:ss";
    fmt.locale           = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    t.threadID           = [fmt stringFromDate:[NSDate date]];
    t.modelName          = self.selectedModel;
    t.chatContext        = @[];
    t.attachmentPaths    = @[];
    self.activeThread    = t;
    EZLogf(EZLogLevelInfo, @"THREAD", @"New thread: %@", t.threadID);
}

- (void)saveActiveThread {
    if (!self.activeThread || self.chatContext.count == 0) return;

    // Sync chatContext into thread before saving
    self.activeThread.chatContext = [self.chatContext copy];
    self.activeThread.modelName   = self.selectedModel;

    // Set title from first user message if not set.
    // Strip Tier-3 context preamble if present — we want the raw user question, not the injected context.
    if ([self.activeThread.title isEqualToString:@"New Conversation"] ||
        self.activeThread.title.length == 0) {
        for (NSDictionary *msg in self.chatContext) {
            if ([msg[@"role"] isEqualToString:@"user"]) {
                id content = msg[@"content"];
                NSString *text = @"";

                if ([content isKindOfClass:[NSString class]]) {
                    text = content;
                } else if ([content isKindOfClass:[NSArray class]]) {
                    // Vision attachment: extract text block, or fall back to filename
                    for (NSDictionary *block in (NSArray *)content) {
                        NSString *t = block[@"text"];
                        if (t.length > 0 &&
                            ![t isEqualToString:@"[image attached \u2014 await user question]"]) {
                            text = t;
                            break;
                        }
                    }
                    if (text.length == 0) {
                        // No text block — use the attachment filename as the title
                        NSString *fname = self.activeThread.attachmentPaths.lastObject.lastPathComponent;
                        text = fname.length > 0
                            ? [@"Attachment: " stringByAppendingString:fname]
                            : @"[Attachment]";
                    }
                }

                // Strip Tier-3 context preamble
                NSString *contextPrefix = @"[Context from previous conversations]";
                if ([text hasPrefix:contextPrefix]) {
                    NSRange userMsgRange = [text rangeOfString:@"[User message]\n"];
                    if (userMsgRange.location != NSNotFound) {
                        text = [text substringFromIndex:userMsgRange.location + userMsgRange.length];
                    } else { continue; }
                }

                text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (text.length == 0) continue;
                self.activeThread.title = text.length > 60
                    ? [[text substringToIndex:60] stringByAppendingString:@"\u2026"]
                    : text;
                break;
            }
        }
    }
    // Carry last image path if any
    if (self.lastImageLocalPath) self.activeThread.lastImageLocalPath = self.lastImageLocalPath;

    // Keep visible label in sync whenever the title gets auto-derived
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateThreadTitleLabel]; });
    EZThreadSave(self.activeThread, nil);
    EZLogf(EZLogLevelInfo, @"THREAD", @"Saved: %@", self.activeThread.threadID);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ChatHistoryViewControllerDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)chatHistoryDidSelectThread:(EZChatThread *)thread {
    [self.chatContext removeAllObjects];
    [self.chatContext addObjectsFromArray:thread.chatContext];
    [self.displayMessages removeAllObjects];

    self.activeThread       = thread;
    self.selectedModel      = thread.modelName ?: self.selectedModel;
    self.lastImageLocalPath = thread.lastImageLocalPath;
    self.lastUserPrompt     = nil;
    self.lastAIResponse     = nil;
    self.pendingFileContext = nil;
    self.pendingFileName    = nil;
    self.pendingImagePath   = nil;

    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", self.selectedModel]
                      forState:UIControlStateNormal];

    // Rebuild display messages from saved context
    for (NSDictionary *msg in self.chatContext) {
        NSString *role    = msg[@"role"] ?: @"";
        id        content = msg[@"content"];
        NSString *text    = [content isKindOfClass:[NSString class]] ? content : nil;
        if (!text) continue; // skip vision attachment blobs on restore

        if ([role isEqualToString:@"user"]) {
            if ([text hasPrefix:@"[Context from previous conversations]"]) {
                NSRange r = [text rangeOfString:@"[User message]\n"];
                if (r.location != NSNotFound) text = [text substringFromIndex:r.location + r.length];
            }
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text.length > 0) [self appendToChat:[NSString stringWithFormat:@"You: %@", text]];
        } else if ([role isEqualToString:@"assistant"]) {
            self.lastAIResponse = text;
            if ([text containsString:@"```"]) {
                NSMutableArray *cp = [NSMutableArray array];
                NSString *processed = [self processReplyWithCodeBlocks:text savedPaths:cp isRestore:YES];
                [self appendToChat:[NSString stringWithFormat:@"AI: %@", processed]];
            } else {
                [self appendToChat:[NSString stringWithFormat:@"AI: %@", text]];
            }
        }
    }

    [self appendToChat:[NSString stringWithFormat:@"[System: Thread \"%@\" restored ✓]", thread.title]];
    [self scrollChatToBottom];
    [self updateThreadTitleLabel];
    EZLogf(EZLogLevelInfo, @"THREAD", @"Restored: %@ (%lu turns)",
           thread.threadID, (unsigned long)self.chatContext.count);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shake → Stats
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        NSString *stats = EZHelperStats();
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"EZHelper Stats"
                                                                   message:stats
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [UIPasteboard generalPasteboard].string = stats;
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Dictation
// ─────────────────────────────────────────────────────────────────────────────

- (void)setupDictation {
    self.speechRecognizer = [[SFSpeechRecognizer alloc]
        initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    self.speechRecognizer.delegate = self;
    self.audioEngine = [[AVAudioEngine alloc] init];
    self.isDictating = NO;
}

/// Request both speech recognition and microphone permissions upfront
/// so they appear in Privacy settings and don't surprise the user mid-tap.
- (void)requestSpeechPermissionsIfNeeded {
    // Only prompt if not yet determined
    if ([SFSpeechRecognizer authorizationStatus] == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.dictateButton.enabled = (status == SFSpeechRecognizerAuthorizationStatusAuthorized);
                EZLogf(EZLogLevelInfo, @"DICTATE", @"Speech auth: %ld", (long)status);
            });
        }];
    }
    AVAuthorizationStatus micStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (micStatus == AVAuthorizationStatusNotDetermined) {
        [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
            EZLogf(EZLogLevelInfo, @"DICTATE", @"Mic permission: %@", granted ? @"granted" : @"denied");
        }];
    }
}

- (void)speechRecognizer:(SFSpeechRecognizer *)speechRecognizer availabilityDidChange:(BOOL)available {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.dictateButton.enabled = available;
        EZLogf(EZLogLevelDebug, @"DICTATE", @"Availability: %@", available ? @"YES" : @"NO");
    });
}

- (void)toggleDictation {
    if (self.isDictating) { [self stopDictation]; return; }
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (granted) [self startDictation];
                        else [self appendToChat:@"[Dictation Error]: Mic permission denied."];
                    });
                }];
            } else {
                [self appendToChat:@"[Dictation Error]: Speech recognition permission denied."];
            }
        });
    }];
}

- (void)startDictation {
    if (self.recognitionTask) { [self.recognitionTask cancel]; self.recognitionTask = nil; }
    NSError *err;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryRecord
                    mode:AVAudioSessionModeMeasurement
                 options:AVAudioSessionCategoryOptionDuckOthers error:&err];
    [session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&err];
    if (err) { EZLogf(EZLogLevelError, @"DICTATE", @"Session: %@", err); return; }

    self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.recognitionRequest.shouldReportPartialResults = YES;
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    __weak typeof(self) ws = self;
    self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest
        resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        __strong typeof(ws) ss = ws; if (!ss) return;
        if (result) dispatch_async(dispatch_get_main_queue(), ^{
            [ss setInputText:result.bestTranscription.formattedString];
        });
        if (error || result.isFinal) {
            [ss.audioEngine stop]; [inputNode removeTapOnBus:0];
            ss.recognitionRequest = nil; ss.recognitionTask = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                ss.isDictating = NO;
                [ss.dictateButton setTintColor:[UIColor systemBlueColor]];
            });
        }
    }];
    [inputNode installTapOnBus:0 bufferSize:1024 format:[inputNode outputFormatForBus:0]
                         block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        [self.recognitionRequest appendAudioPCMBuffer:buf];
    }];
    [self.audioEngine prepare];
    NSError *engineErr;
    [self.audioEngine startAndReturnError:&engineErr];
    if (engineErr) { EZLogf(EZLogLevelError, @"DICTATE", @"Engine: %@", engineErr); return; }
    self.isDictating = YES;
    [self.dictateButton setTintColor:[UIColor systemRedColor]];
    EZLog(EZLogLevelInfo, @"DICTATE", @"Started");
}

- (void)stopDictation {
    if (self.audioEngine.isRunning) { [self.audioEngine stop]; [self.recognitionRequest endAudio]; }
    self.isDictating = NO;
    [self.dictateButton setTintColor:[UIColor systemBlueColor]];
    EZLog(EZLogLevelInfo, @"DICTATE", @"Stopped");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UI Setup
// ─────────────────────────────────────────────────────────────────────────────

- (void)setupUI {
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // Top bar buttons
    // + New chat (save current, start fresh)
    self.addChatButton   = [self _iconButton:@"square.and.pencil" tint:[UIColor systemGreenColor]
                                      action:@selector(newChat)];
    // History (browse/restore past threads)
    self.historyButton   = [self _iconButton:@"clock.arrow.circlepath" tint:nil
                                      action:@selector(openHistory)];
    // Copy last AI response
    self.clipboardButton = [self _iconButton:@"doc.on.doc" tint:nil
                                      action:@selector(copyLastResponse)];
    // Speak last AI response
    self.speakButton     = [self _iconButton:@"speaker.wave.2.fill" tint:nil
                                      action:@selector(speakLastResponse)];
    // Web search toggle
    self.webSearchButton = [self _iconButton:@"globe" tint:nil
                                      action:@selector(toggleWebSearch)];
    [self updateWebSearchButtonTint];
    // Settings
    self.settingsButton  = [self _iconButton:@"gearshape.fill" tint:nil
                                      action:@selector(openSettings)];
    // Trash = delete current chat (confirm) then start new one
    self.clearButton   = [self _iconButton:@"trash.fill" tint:[UIColor systemRedColor]
                                    action:@selector(deleteCurrentChat)];
    // Rename thread title
    self.renameButton  = [self _iconButton:@"pencil.line" tint:nil
                                    action:@selector(renameThread)];

    // Full-width stack — equalSpacing distributes buttons edge to edge
    UIStackView *topStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.addChatButton, self.historyButton, self.clipboardButton,
        self.speakButton, self.webSearchButton, self.settingsButton,
        self.renameButton, self.clearButton
    ]];
    topStack.distribution = UIStackViewDistributionEqualSpacing;
    topStack.alignment    = UIStackViewAlignmentCenter;
    topStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:topStack];

    // Thread title label — tappable, sits between top bar and chat table
    self.threadTitleLabel                 = [[UILabel alloc] init];
    self.threadTitleLabel.text            = @"New Conversation";
    self.threadTitleLabel.font            = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.threadTitleLabel.textColor       = [UIColor secondaryLabelColor];
    self.threadTitleLabel.textAlignment   = NSTextAlignmentCenter;
    self.threadTitleLabel.userInteractionEnabled = YES;
    self.threadTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UITapGestureRecognizer *titleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(renameThread)];
    [self.threadTitleLabel addGestureRecognizer:titleTap];
    [self.view addSubview:self.threadTitleLabel];

    // Chat table view — each message is a bubble, system, or code cell
    self.chatTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.chatTableView.dataSource         = self;
    self.chatTableView.delegate           = self;
    self.chatTableView.separatorStyle     = UITableViewCellSeparatorStyleNone;
    self.chatTableView.backgroundColor    = [UIColor systemBackgroundColor];
    self.chatTableView.estimatedRowHeight = 60;
    self.chatTableView.rowHeight          = UITableViewAutomaticDimension;
    self.chatTableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.chatTableView registerClass:[EZBubbleCell class]    forCellReuseIdentifier:@"EZBubble"];
    [self.chatTableView registerClass:[EZSystemCell class]    forCellReuseIdentifier:@"EZSystem"];
    [self.chatTableView registerClass:[EZCodeBlockCell class] forCellReuseIdentifier:@"EZCodeBlock"];
    [self.view addSubview:self.chatTableView];

    // Input container
    self.inputContainer = [[UIView alloc] init];
    self.inputContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.inputContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.inputContainer];

    // Model picker button
    self.modelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", self.selectedModel]
                      forState:UIControlStateNormal];
    [self.modelButton addTarget:self action:@selector(showModelPicker)
                forControlEvents:UIControlEventTouchUpInside];
    self.modelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.modelButton];

    // Attach button
    self.attachButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.attachButton setImage:[UIImage systemImageNamed:@"paperclip.circle.fill"]
                       forState:UIControlStateNormal];
    [self.attachButton addTarget:self action:@selector(showAttachMenu)
                forControlEvents:UIControlEventTouchUpInside];
    self.attachButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.attachButton];

    // Dictate button
    self.dictateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.dictateButton setImage:[UIImage systemImageNamed:@"mic.fill"] forState:UIControlStateNormal];
    [self.dictateButton setTintColor:[UIColor systemBlueColor]];
    [self.dictateButton addTarget:self action:@selector(toggleDictation)
                 forControlEvents:UIControlEventTouchUpInside];
    self.dictateButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.dictateButton];

    // Text field
    self.messageTextField = [[UITextField alloc] init];
    self.messageTextField.placeholder  = @"Type message...";
    self.messageTextField.borderStyle  = UITextBorderStyleRoundedRect;
    self.messageTextField.delegate     = self;
    self.messageTextField.returnKeyType = UIReturnKeyDone;
    self.messageTextField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.messageTextField];

    // Send button
    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendButton setTitle:@"Send" forState:UIControlStateNormal];
    [self.sendButton addTarget:self action:@selector(handleSend)
              forControlEvents:UIControlEventTouchUpInside];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.sendButton];

    [self.sendButton setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                     forAxis:UILayoutConstraintAxisHorizontal];
    [self.messageTextField setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                           forAxis:UILayoutConstraintAxisHorizontal];

    // Image settings button — only visible when an image model is selected
    self.imageSettingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.imageSettingsButton setImage:[UIImage systemImageNamed:@"slider.horizontal.3"]
                              forState:UIControlStateNormal];
    [self.imageSettingsButton addTarget:self action:@selector(showImageSettings)
                      forControlEvents:UIControlEventTouchUpInside];
    self.imageSettingsButton.hidden = YES; // shown when image model active
    self.imageSettingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.imageSettingsButton];

    self.containerBottomConstraint =
        [self.inputContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [topStack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:5],
        [topStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [topStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.threadTitleLabel.topAnchor    constraintEqualToAnchor:topStack.bottomAnchor constant:4],
        [self.threadTitleLabel.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.threadTitleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.chatTableView.topAnchor constraintEqualToAnchor:self.threadTitleLabel.bottomAnchor constant:4],
        [self.chatTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.chatTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.chatTableView.bottomAnchor constraintEqualToAnchor:self.inputContainer.topAnchor],
        [self.inputContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.inputContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.containerBottomConstraint,
        [self.modelButton.topAnchor constraintEqualToAnchor:self.inputContainer.topAnchor constant:8],
        [self.modelButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],
        [self.imageSettingsButton.centerYAnchor constraintEqualToAnchor:self.modelButton.centerYAnchor],
        [self.imageSettingsButton.leadingAnchor constraintEqualToAnchor:self.modelButton.trailingAnchor constant:8],
        [self.imageSettingsButton.widthAnchor constraintEqualToConstant:32],
        [self.imageSettingsButton.heightAnchor constraintEqualToConstant:32],
        [self.attachButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],
        [self.attachButton.topAnchor constraintEqualToAnchor:self.modelButton.bottomAnchor constant:12],
        [self.dictateButton.leadingAnchor constraintEqualToAnchor:self.attachButton.trailingAnchor constant:6],
        [self.dictateButton.centerYAnchor constraintEqualToAnchor:self.attachButton.centerYAnchor],
        [self.messageTextField.leadingAnchor constraintEqualToAnchor:self.dictateButton.trailingAnchor constant:8],
        [self.messageTextField.centerYAnchor constraintEqualToAnchor:self.attachButton.centerYAnchor],
        [self.messageTextField.trailingAnchor constraintEqualToAnchor:self.sendButton.leadingAnchor constant:-8],
        [self.sendButton.trailingAnchor constraintEqualToAnchor:self.inputContainer.trailingAnchor constant:-12],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:self.messageTextField.centerYAnchor],
        [self.inputContainer.bottomAnchor constraintEqualToAnchor:self.messageTextField.bottomAnchor constant:12],
    ]];
}

- (UIButton *)_iconButton:(NSString *)sfSymbol tint:(nullable UIColor *)tint action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:sfSymbol] forState:UIControlStateNormal];
    if (tint) [b setTintColor:tint];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder]; return YES;
}

- (void)setInputText:(NSString *)text {
    self.messageTextField.text = text;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Web Search Toggle
// ─────────────────────────────────────────────────────────────────────────────

- (void)toggleWebSearch {
    self.webSearchEnabled = !self.webSearchEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.webSearchEnabled forKey:@"webSearchEnabled"];
    [self updateWebSearchButtonTint];
    [self appendToChat:[NSString stringWithFormat:@"[System: Web Search %@]",
                        self.webSearchEnabled ? @"ON 🌐" : @"OFF"]];
    EZLogf(EZLogLevelInfo, @"WEBSEARCH", @"Toggled %@", self.webSearchEnabled ? @"ON" : @"OFF");
}

- (void)updateWebSearchButtonTint {
    [self.webSearchButton setTintColor:self.webSearchEnabled
        ? [UIColor systemGreenColor] : [UIColor systemGrayColor]];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Thread Title Editing
// ─────────────────────────────────────────────────────────────────────────────

/// Syncs the visible threadTitleLabel with the active thread's current title.
- (void)updateThreadTitleLabel {
    NSString *title = self.activeThread.title;
    if (!title.length || [title isEqualToString:@"New Conversation"]) {
        self.threadTitleLabel.text      = @"New Conversation";
        self.threadTitleLabel.textColor = [UIColor tertiaryLabelColor];
    } else {
        self.threadTitleLabel.text      = title;
        self.threadTitleLabel.textColor = [UIColor secondaryLabelColor];
    }
}

/// Shows an alert with a prefilled text field so the user can rename the thread.
- (void)renameThread {
    NSString *current = self.activeThread.title.length > 0
        ? self.activeThread.title : @"";
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Rename Thread"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text             = current;
        tf.placeholder      = @"Thread name";
        tf.clearButtonMode  = UITextFieldViewModeWhileEditing;
        tf.returnKeyType    = UIReturnKeyDone;
        tf.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    }];
    __weak typeof(self) ws = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
        NSString *newTitle = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!newTitle.length) return;
        ws.activeThread.title = newTitle;
        [ws updateThreadTitleLabel];
        [ws saveActiveThread];
        EZLogf(EZLogLevelInfo, @"THREAD", @"Renamed to: %@", newTitle);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Generation Settings
// ─────────────────────────────────────────────────────────────────────────────

/// Presents a series of action sheets to configure gpt-image-1 generation params.
/// Settings are persisted in NSUserDefaults and read in callGptImage1 / callImageEdit.
- (void)showImageSettings {
        // Creating an instance of NSUserDefaults
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

        // Fetching current values with defaults as fallback
        NSString *curSize = [d stringForKey:@"imgSize"] ?: @"1024x1024";
        NSString *curQual = [d stringForKey:@"imgQuality"] ?: @"auto";
        NSString *curFmt = [d stringForKey:@"imgFormat"] ?: @"png";
        NSString *curBg = [d stringForKey:@"imgBackground"] ?: @"auto";
        NSString *curMod = [d stringForKey:@"imgModeration"] ?: @"auto";

        // Creating an alert controller
        UIAlertController *sheet = [UIAlertController
            alertControllerWithTitle:@"Image Generation Settings"
            message:[NSString stringWithFormat:
                    @"Size: %@  |  Quality: %@  |  Format: %@  |  BG: %@  |  Mod: %@",
                    curSize, curQual, curFmt, curBg, curMod]
            preferredStyle:UIAlertControllerStyleActionSheet];    // ── Size ────────────────────────────────────────────────────────────────
    NSDictionary *sizes = @{
        @"1024x1024": @"Square (1024×1024)",
        @"1024x1536": @"Portrait (1024×1536)",
        @"1536x1024": @"Landscape (1536×1024)",
    };
    for (NSString *val in @[@"1024x1024", @"1024x1536", @"1536x1024"]) {
        NSString *label = [NSString stringWithFormat:@"%@ Size: %@",
                           [curSize isEqualToString:val] ? @"✓" : @" ", sizes[val]];
        [sheet addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
            [d setObject:val forKey:@"imgSize"];
            EZLogf(EZLogLevelInfo, @"IMGSET", @"Size → %@", val);
        }]];
    }

    // ── Quality ─────────────────────────────────────────────────────────────
    NSDictionary *quals = @{
        @"auto": @"Quality: Auto (recommended)",
        @"high": @"Quality: High",
        @"medium": @"Quality: Medium",
        @"low": @"Quality: Low (fastest)",
    };
    for (NSString *val in @[@"auto", @"high", @"medium", @"low"]) {
        NSString *label = [NSString stringWithFormat:@"%@ %@",
                           [curQual isEqualToString:val] ? @"✓" : @" ", quals[val]];
        [sheet addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
            [d setObject:val forKey:@"imgQuality"];
            EZLogf(EZLogLevelInfo, @"IMGSET", @"Quality → %@", val);
        }]];
    }

    // ── Output format ────────────────────────────────────────────────────────
    NSDictionary *fmts = @{
        @"png":  @"Format: PNG (lossless, supports transparency)",
        @"jpeg": @"Format: JPEG (lossy, no transparency)",
        @"webp": @"Format: WebP (modern, supports transparency)",
    };
    for (NSString *val in @[@"png", @"jpeg", @"webp"]) {
        NSString *label = [NSString stringWithFormat:@"%@ %@",
                           [curFmt isEqualToString:val] ? @"✓" : @" ", fmts[val]];
        [sheet addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
            [d setObject:val forKey:@"imgFormat"];
            EZLogf(EZLogLevelInfo, @"IMGSET", @"Format → %@", val);
        }]];
    }

    // ── Background ───────────────────────────────────────────────────────────
    NSDictionary *bgs = @{
        @"auto":        @"Background: Auto",
        @"transparent": @"Background: Transparent (PNG/WebP only)",
        @"opaque":      @"Background: Opaque",
    };
    for (NSString *val in @[@"auto", @"transparent", @"opaque"]) {
        NSString *label = [NSString stringWithFormat:@"%@ %@",
                           [curBg isEqualToString:val] ? @"✓" : @" ", bgs[val]];
        [sheet addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
            [d setObject:val forKey:@"imgBackground"];
            EZLogf(EZLogLevelInfo, @"IMGSET", @"Background → %@", val);
        }]];
    }

    // ── Moderation ───────────────────────────────────────────────────────────
    for (NSString *val in @[@"auto", @"low"]) {
        NSString *label = [NSString stringWithFormat:@"%@ Moderation: %@",
                           [curMod isEqualToString:val] ? @"✓" : @" ", val];
        [sheet addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
            [d setObject:val forKey:@"imgModeration"];
            EZLogf(EZLogLevelInfo, @"IMGSET", @"Moderation → %@", val);
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Done"
                                              style:UIAlertActionStyleCancel handler:nil]];

    // iPad support
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.imageSettingsButton;
        sheet.popoverPresentationController.sourceRect = self.imageSettingsButton.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat History
// ─────────────────────────────────────────────────────────────────────────────

- (void)openHistory {
    ChatHistoryViewController *vc = [[ChatHistoryViewController alloc] initWithStyle:UITableViewStylePlain];
    vc.delegate = self;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Attach Menu
// ─────────────────────────────────────────────────────────────────────────────

- (void)showAttachMenu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Attach File"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"🎙 Transcribe Audio/Video (Whisper)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        [self presentFilePickerForMode:EZAttachModeWhisper];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"📄 Analyze PDF / ePub / Text"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        [self presentFilePickerForMode:EZAttachModeAnalyze];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"🖼 Attach Image (Vision / Edit)"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        [self presentFilePickerForMode:EZAttachModeAnalyze
                           forceTypes:@[UTTypeImage]];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                             style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentFilePickerForMode:(EZAttachMode)mode {
    NSArray *types;
    if (mode == EZAttachModeWhisper) {
        types = @[UTTypeAudio, UTTypeVideo, UTTypeMovie, UTTypeAudiovisualContent];
    } else {
        // Be explicit — UTTypeData catch-all breaks iOS 15 file picker
        types = @[UTTypePDF,
                  [UTType typeWithIdentifier:@"org.idpf.epub-container"],
                  UTTypePlainText,
                  UTTypeRTF,
                  UTTypeHTML,
                  UTTypeImage,
                  [UTType typeWithIdentifier:@"public.comma-separated-values-text"],
                  [UTType typeWithIdentifier:@"public.json"],
                  [UTType typeWithIdentifier:@"public.xml"]];
    }
    [self presentFilePickerForMode:mode forceTypes:types];
}

- (void)presentFilePickerForMode:(EZAttachMode)mode forceTypes:(NSArray *)types {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    // Store mode via associated object — safer than .view.tag on iOS 15
    objc_setAssociatedObject(picker, "EZAttachMode",
                             @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Document Picker Delegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *fileURL = urls.firstObject;
    if (!fileURL) return;

    // Retrieve mode from associated object — fall back to analyze
    NSNumber *modeNum = objc_getAssociatedObject(controller, "EZAttachMode");
    EZAttachMode mode = modeNum ? (EZAttachMode)modeNum.integerValue : EZAttachModeAnalyze;

    NSString *ext = fileURL.pathExtension.lowercaseString;
    BOOL isImage  = [@[@"jpg",@"jpeg",@"png",@"gif",@"webp",@"heic"] containsObject:ext];

    if (mode == EZAttachModeWhisper) {
        [self transcribeAudio:fileURL];
    } else if (isImage) {
        [self attachImage:fileURL];
    } else {
        [self analyzeFile:fileURL];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    EZLog(EZLogLevelInfo, @"FILE", @"Document picker cancelled by user");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Attachment
// ─────────────────────────────────────────────────────────────────────────────

- (void)attachImage:(NSURL *)fileURL {
    NSData *rawData = [NSData dataWithContentsOfURL:fileURL];
    if (!rawData) {
        [self appendToChat:@"[Error: Could not read image]"]; return;
    }

    NSString *name = fileURL.lastPathComponent;
    NSString *ext  = fileURL.pathExtension.lowercaseString;

    // ── Format validation & conversion ───────────────────────────────────────
    // OpenAI vision + image edit APIs accept: png, jpeg, gif, webp ONLY.
    // HEIC (default iOS camera format) must be converted to JPEG.
    // Any other unsupported format also gets converted to JPEG.
    NSData   *imageData = rawData;
    NSString *mime      = @"image/jpeg";
    BOOL      converted = NO;

    NSSet *supported = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"gif", @"webp", nil];

    if (![supported containsObject:ext]) {
        // Attempt conversion via UIImage → JPEG
        UIImage *img = [UIImage imageWithData:rawData];
        if (img) {
            NSData *jpegData = UIImageJPEGRepresentation(img, 0.92);
            if (jpegData) {
                imageData  = jpegData;
                mime       = @"image/jpeg";
                converted  = YES;
                [self appendToChat:[NSString stringWithFormat:
                    @"[System: %@ converted from %@ to JPEG for API compatibility ✓]",
                    name, ext.uppercaseString]];
                EZLogf(EZLogLevelInfo, @"ATTACH", @"Converted %@ → JPEG (%lu bytes)",
                       ext, (unsigned long)imageData.length);
            } else {
                [self appendToChat:[NSString stringWithFormat:
                    @"[Error: Could not convert %@ to a supported format. "
                    @"Please use PNG, JPEG, GIF, or WebP.]", ext.uppercaseString]];
                return;
            }
        } else {
            [self appendToChat:[NSString stringWithFormat:
                @"[Error: Unsupported image format '%@'. Please use PNG, JPEG, GIF, or WebP.]",
                ext.uppercaseString]];
            return;
        }
    } else {
        // Set correct mime for supported formats
        if ([ext isEqualToString:@"png"])              mime = @"image/png";
        else if ([ext isEqualToString:@"gif"])         mime = @"image/gif";
        else if ([ext isEqualToString:@"webp"])        mime = @"image/webp";
        else                                           mime = @"image/jpeg";
    }

    // ── Save to EZAttachments ─────────────────────────────────────────────────
    NSString *saveName  = converted
        ? [[name stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpeg"]
        : name;
    NSString *localPath = EZAttachmentSave(imageData, saveName);
    self.pendingImagePath = localPath ?: fileURL.path;

    if (localPath) {
        NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
        [att addObject:localPath];
        self.activeThread.attachmentPaths = [att copy];
    }

    // ── Route based on selected model ─────────────────────────────────────────
    BOOL inImageGenMode = [self isGptImage1Family:self.selectedModel] ||
                          [self.selectedModel isEqualToString:@"dall-e-3"];

    if (inImageGenMode) {
        // Switch to image edit mode — gpt-image-1 handles both gen and edit
        self.selectedModel = @"gpt-image-1-edit";
        [self.modelButton setTitle:@"Model: gpt-image-1 (edit mode)" forState:UIControlStateNormal];
        [self appendToChat:[NSString stringWithFormat:
            @"[System: Image %@ attached — switched to image edit mode. "
            @"Type a prompt describing your edits.]", saveName]];
    } else {
        // Vision analysis mode — ensure model supports vision
        NSSet *visionModels = [NSSet setWithObjects:
            @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4",
            @"gpt-5", @"gpt-5-mini", @"gpt-5-pro", nil];

        if (![visionModels containsObject:self.selectedModel]) {
            NSString *prev     = self.selectedModel;
            self.selectedModel = @"gpt-4o";
            [self.modelButton setTitle:@"Model: gpt-4o" forState:UIControlStateNormal];
            [self appendToChat:[NSString stringWithFormat:
                @"[System: Image attached — %@ doesn't support vision. "
                @"Switched to gpt-4o. Type a prompt to analyze the image.]", prev]];
        } else {
            [self appendToChat:[NSString stringWithFormat:
                @"[System: Image %@ attached. Type a prompt to analyze or describe it.]", saveName]];
        }

        // Add vision message to context — use base64 data URL
        // NOTE: this message is marked so we can strip it after first use
        // to avoid re-sending huge base64 blobs on every subsequent turn
        NSString *base64  = [imageData base64EncodedStringWithOptions:0];
        NSString *dataURL = [NSString stringWithFormat:@"data:%@;base64,%@", mime, base64];
        NSDictionary *visionMsg = @{
            @"role":     @"user",
            @"content":  @[
                @{@"type": @"image_url", @"image_url": @{@"url": dataURL}},
                @{@"type": @"text",      @"text": @"[image attached — await user question]"}
            ],
            @"_isVisionAttachment": @YES   // internal flag — stripped before API call
        };
        [self.chatContext addObject:visionMsg];
    }

    EZLogf(EZLogLevelInfo, @"ATTACH", @"Image ready: %@ mime=%@ bytes=%lu",
           saveName, mime, (unsigned long)imageData.length);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - File Analysis (PDF / ePub / text)
// ─────────────────────────────────────────────────────────────────────────────

- (void)analyzeFile:(NSURL *)fileURL {
    NSString *ext  = fileURL.pathExtension.lowercaseString;
    NSString *name = fileURL.lastPathComponent;
    EZLogf(EZLogLevelInfo, @"FILE", @"Analyzing: %@", name);
    [self appendToChat:[NSString stringWithFormat:@"[System: Reading %@...]", name]];

    // Save a copy for persistence
    NSData *fileData = [NSData dataWithContentsOfURL:fileURL];
    if (fileData) {
        NSString *savedPath = EZAttachmentSave(fileData, name);
        if (savedPath) {
            NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
            [att addObject:savedPath];
            self.activeThread.attachmentPaths = [att copy];
        }
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *extractedText = nil;
        if ([ext isEqualToString:@"pdf"]) {
            extractedText = [self extractTextFromPDF:fileURL];
        } else if ([ext isEqualToString:@"epub"]) {
            extractedText = [self extractTextFromEPUB:fileURL];
        } else {
            extractedText = [NSString stringWithContentsOfURL:fileURL
                                                     encoding:NSUTF8StringEncoding error:nil]
                         ?: [NSString stringWithContentsOfURL:fileURL
                                                     encoding:NSISOLatin1StringEncoding error:nil];
        }
        if (!extractedText.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[Error: Could not extract text from file]"];
            });
            return;
        }
        if (extractedText.length > 12000) {
            extractedText = [[extractedText substringToIndex:12000]
                             stringByAppendingString:@"\n[...truncated...]"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.pendingFileContext = extractedText;
            self.pendingFileName    = name;
            [self appendToChat:[NSString stringWithFormat:
                @"[System: %@ ready (%lu chars). Ask me anything about it.]",
                name, (unsigned long)extractedText.length]];
            EZLogf(EZLogLevelInfo, @"FILE", @"Context ready: %@ (%lu chars)",
                   name, (unsigned long)extractedText.length);
        });
    });
}

- (NSString *)extractTextFromPDF:(NSURL *)url {
    PDFDocument *doc = [[PDFDocument alloc] initWithURL:url];
    if (!doc) return nil;
    NSMutableString *text = [NSMutableString string];
    for (NSInteger i = 0; i < doc.pageCount; i++) {
        NSString *pg = [[doc pageAtIndex:i] string];
        if (pg) [text appendFormat:@"%@\n", pg];
    }
    return text;
}

- (NSString *)extractTextFromEPUB:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                 ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!raw) return @"[Could not decode ePub]";
    NSMutableString *stripped = [NSMutableString string];
    BOOL inTag = NO;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c == '<')      { inTag = YES; continue; }
        if (c == '>')      { inTag = NO; [stripped appendString:@" "]; continue; }
        if (!inTag)        [stripped appendFormat:@"%C", c];
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\s{3,}"
                                                                        options:0 error:nil];
    return [re stringByReplacingMatchesInString:stripped options:0
                                          range:NSMakeRange(0, stripped.length)
                                   withTemplate:@"\n\n"];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - TTS
// ─────────────────────────────────────────────────────────────────────────────

- (void)speakLastResponse {
    if (!self.lastAIResponse) return;
    NSUserDefaults *d  = [NSUserDefaults standardUserDefaults];
    // CHANGED: ElevenLabs key now loaded from EZKeyVault (Keychain) instead of NSUserDefaults
    NSString *elKey    = [EZKeyVault loadKeyForIdentifier:EZVaultKeyElevenLabs];
    NSString *elVoice  = [d stringForKey:@"elevenVoiceID"];
    if (elKey.length > 0 && elVoice.length > 0) {
        [self speakWithElevenLabs:self.lastAIResponse key:elKey voiceID:elVoice];
    } else {
        [self speakWithApple:self.lastAIResponse];
    }
}

- (void)speakWithApple:(NSString *)text {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                            mode:AVAudioSessionModeDefault
                                         options:AVAudioSessionCategoryOptionDuckOthers error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    if (self.speechSynthesizer.isSpeaking)
        [self.speechSynthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
    u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    u.rate  = AVSpeechUtteranceDefaultSpeechRate;
    [self.speechSynthesizer speakUtterance:u];
}

- (void)speakWithElevenLabs:(NSString *)text key:(NSString *)key voiceID:(NSString *)voiceID {
    EZLogf(EZLogLevelInfo, @"TTS", @"ElevenLabs voiceID=%@", voiceID);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://api.elevenlabs.io/v1/text-to-speech/%@", voiceID]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:key forHTTPHeaderField:@"xi-api-key"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"text": text, @"model_id": @"eleven_turbo_v2_5",
        @"voice_settings": @{@"stability": @0.5, @"similarity_boost": @0.5}
    } options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self speakWithApple:text]; });
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200) {
            NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            EZLogf(EZLogLevelError, @"TTS", @"ElevenLabs %ld: %@", (long)http.statusCode, body);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:[NSString stringWithFormat:
                    @"[ElevenLabs HTTP %ld — falling back to Apple TTS]", (long)http.statusCode]];
                [self speakWithApple:text];
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                                    mode:AVAudioSessionModeDefault
                                                 options:0 error:nil];
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
            NSError *playerErr;
            self.audioPlayer = [[AVAudioPlayer alloc] initWithData:data error:&playerErr];
            if (playerErr) { [self speakWithApple:text]; return; }
            [self.audioPlayer prepareToPlay];
            [self.audioPlayer play];
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - handleSend
// ─────────────────────────────────────────────────────────────────────────────

- (void)handleSend {
    
    @try { [self ezcui_beginLongOperation:@"ChatCompletion"]; } @catch (NSException *e) { EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"begin failed in handleSend: %@", e); }
NSString *text = self.messageTextField.text;
    if (text.length == 0) return;
    if (self.isDictating) [self stopDictation];

    self.lastUserPrompt = text;

    // Inject pending file context
    NSString *fullPrompt = text;
    if (self.pendingFileContext.length > 0) {
        fullPrompt = [NSString stringWithFormat:
            @"[Attached file: %@]\n\n%@\n\n[User question]: %@",
            self.pendingFileName, self.pendingFileContext, text];
        self.pendingFileContext = nil;
        self.pendingFileName    = nil;
        [self appendToChat:@"[System: File context injected ✓]"];
    }

    [self appendToChat:[NSString stringWithFormat:@"You: %@", text]];
    [self.chatContext addObject:@{@"role": @"user", @"content": fullPrompt}];
    [self setInputText:@""];
    [self.view endEditing:YES];

    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    if (!apiKey.length) { [self appendToChat:@"[Error: No API Key]"]; return; }

    // ── Guard: Whisper is transcription-only, not a chat model ───────────────
    if ([self.selectedModel isEqualToString:@"whisper-1"]) {
        self.selectedModel = @"gpt-4o";
        [self.modelButton setTitle:@"Model: gpt-4o" forState:UIControlStateNormal];
        [self appendToChat:@"[System: Whisper is for audio transcription only — switched to gpt-4o for chat]"];
    }

    // ── Image edit mode (gpt-image-1 with attached image) ────────────────────
    if ([self.selectedModel isEqualToString:@"gpt-image-1-edit"]) {
        [self callImageEdit:text imagePath:self.pendingImagePath ?: self.lastImageLocalPath];
        self.pendingImagePath = nil;
        return;
    }

    // ── Legacy dall-e-2-edit fallback (in case old state persists) ───────────
    if ([self.selectedModel isEqualToString:@"dall-e-2-edit"]) {
        self.selectedModel = @"gpt-image-1-edit";
        [self callImageEdit:text imagePath:self.pendingImagePath ?: self.lastImageLocalPath];
        self.pendingImagePath = nil;
        return;
    }

    // ── Image model intent check ──────────────────────────────────────────────
    BOOL isImageModel = [self isGptImage1Family:self.selectedModel] ||
                        [self.selectedModel isEqualToString:@"dall-e-3"];
    if (isImageModel) {
        if (!self.lastImageLocalPath.length) {
            NSString *persisted = [[NSUserDefaults standardUserDefaults]
                                   stringForKey:@"lastImageLocalPath"];
            if (persisted.length > 0 &&
                [[NSFileManager defaultManager] fileExistsAtPath:persisted]) {
                self.lastImageLocalPath = persisted;
            }
        }
        BOOL hasLocal = self.lastImageLocalPath.length > 0;

        self.sendButton.enabled = NO;
        [self classifyImageIntent:text hasLocalImage:hasLocal apiKey:apiKey
                       completion:^(NSString *intent) {
            self.sendButton.enabled = YES;
            if ([intent isEqualToString:@"reopen"] && hasLocal) {
                EZLogf(EZLogLevelInfo, @"IMAGE", @"Intent=reopen → %@",
                       self.lastImageLocalPath.lastPathComponent);
                [self appendToChat:@"[System: Reopening last image ✓]"];
                [self offerToOpenLocalFile:self.lastImageLocalPath];
            } else if ([intent isEqualToString:@"edit"] && hasLocal) {
                EZLogf(EZLogLevelInfo, @"IMAGE", @"Intent=edit → switching to edit mode");
                self.selectedModel = @"gpt-image-1-edit";
                [self.modelButton setTitle:@"Model: gpt-image-1 (edit mode)"
                                  forState:UIControlStateNormal];
                [self callImageEdit:text imagePath:self.lastImageLocalPath];
            } else {
                EZLogf(EZLogLevelInfo, @"IMAGE", @"Intent=generate");
                if ([self isGptImage1Family:self.selectedModel] ||
                    [self.selectedModel isEqualToString:@"gpt-image-1-edit"]) {
                    [self callGptImage1:text];
                } else {
                    if (self.lastImagePrompt.length > 0) {
                        [self fetchRelevantMemories:text apiKey:apiKey
                                        completion:^(NSString *memories) {
                            analyzePromptForContext(text, memories, apiKey,
                                                   self.activeThread.threadID,
                            ^(EZContextResult *result) {
                                NSString *finalPrompt = text;
                                if (result.tier >= EZRoutingTierMemory) {
                                    finalPrompt = [NSString stringWithFormat:
                                        @"Previous image prompt was: \"%@\". Now create: %@",
                                        self.lastImagePrompt, text];
                                    [self appendToChat:@"[System: Previous image context included ✓]"];
                                }
                                [self callDalle3:finalPrompt];
                            });
                        }];
                    } else {
                        [self callDalle3:text];
                    }
                }
            }
        }];
        return;
    }

    // ── Sora ─────────────────────────────────────────────────────────────────
    if ([self.selectedModel hasPrefix:@"sora-"]) {
        [self callSora:fullPrompt];
        return;
    }

    // ── Chat / reasoning models ───────────────────────────────────────────────
    self.sendButton.enabled = NO;

    [self fetchRelevantMemories:text apiKey:apiKey completion:^(NSString *memories) {
        analyzePromptForContext(text, memories, apiKey, self.activeThread.threadID,
    ^(EZContextResult *result) {
        self.sendButton.enabled = YES;
        EZLogf(EZLogLevelInfo, @"SEND",
               @"Tier %ld — conf=%.2f tokens≈%ld reason: %@",
               (long)result.tier, result.confidence,
               (long)result.estimatedTokens, result.reason);

        if (result.tier == EZRoutingTierDirect && result.shortCircuitAnswer.length > 0) {
            NSString *answer = result.shortCircuitAnswer;
            self.lastAIResponse = answer;
            [self.chatContext addObject:@{@"role": @"assistant", @"content": answer}];
            [self appendToChat:[NSString stringWithFormat:@"AI: %@", answer]];
            [self appendToChat:@"[System: Answered directly by helper model ⚡]"];
            EZLogf(EZLogLevelInfo, @"SEND", @"Tier 1 direct answer displayed");
            // Only include the image that was explicitly attached THIS turn (pendingImagePath).
            // Never inject lastImageLocalPath here — it is a stale sticky path from a prior
            // turn or a prior DALL-E generation and has no guaranteed relevance to this exchange.
            NSMutableArray *attachmentsAtSend = [self.activeThread.attachmentPaths mutableCopy];
            if (self.pendingImagePath.length > 0 &&
                ![attachmentsAtSend containsObject:self.pendingImagePath]) {
                [attachmentsAtSend addObject:self.pendingImagePath];
            }
            self.pendingImagePath = nil; // consumed — belongs to this turn only
            createMemoryFromCompletion(text, answer, apiKey, self.activeThread.threadID,
                                       attachmentsAtSend,
                                       ^(NSString *entry) {
                if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved: %lu chars",
                                  (unsigned long)entry.length);
            });
            [self saveActiveThread];
            return;
        }

        if (result.tier == EZRoutingTierFullChat && result.injectedHistory.count > 0) {
            if (self.chatContext.count > 0) [self.chatContext removeLastObject];
            NSMutableArray *rebuilt = [NSMutableArray array];
            [rebuilt addObjectsFromArray:result.injectedHistory];
            [rebuilt addObjectsFromArray:self.chatContext];
            [rebuilt addObject:@{@"role": @"user", @"content": result.finalPrompt}];
            self.chatContext = rebuilt;
            [self appendToChat:@"[System: Full chat history injected ✓]"];
        } else if (result.tier >= EZRoutingTierMemory) {
            if (self.chatContext.count > 0) [self.chatContext removeLastObject];
            [self.chatContext addObject:@{@"role": @"user", @"content": result.finalPrompt}];
            [self appendToChat:@"[System: Memory context included ✓]"];
        }

        [self callChatCompletions];
    });
    }];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Memory Search
// ─────────────────────────────────────────────────────────────────────────────

- (void)fetchRelevantMemories:(NSString *)prompt
                       apiKey:(NSString *)apiKey
                   completion:(void (^)(NSString *memories))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *memories = @"";

        NSString *all = loadMemoryContext(0);
        NSInteger entryCount = 0;
        if (all.length > 0) {
            for (NSString *line in [all componentsSeparatedByString:@"\n"]) {
                if ([line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0) entryCount++;
            }
        }

        if (entryCount >= 5 && apiKey.length > 0) {
            EZLogf(EZLogLevelInfo, @"MEMORY", @"Semantic search over %ld entries for: %@",
                   (long)entryCount, prompt);
            NSString *searched = EZThreadSearchMemory(prompt, apiKey);
            memories = searched.length > 0 ? searched : loadMemoryContext(15);
            EZLogf(EZLogLevelInfo, @"MEMORY", @"Search returned %lu chars",
                   (unsigned long)memories.length);
        } else if (entryCount > 0) {
            memories = loadMemoryContext(15);
            EZLogf(EZLogLevelInfo, @"MEMORY", @"Using recency (%ld entries)", (long)entryCount);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(memories);
        });
    });
}

- (void)callChatCompletions {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    if (!apiKey) { [self appendToChat:@"[Error: No API Key]"]; return; }

    BOOL isGPT5          = [self.selectedModel hasPrefix:@"gpt-5"];
    NSSet *webSearchCompatible = [NSSet setWithObjects:
        @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo",
        @"gpt-5", @"gpt-5-mini", @"gpt-5-pro", nil];
    BOOL modelSupportsWebSearch = isGPT5 || [webSearchCompatible containsObject:self.selectedModel];
    BOOL useWebSearch    = self.webSearchEnabled && modelSupportsWebSearch;
    BOOL useResponsesAPI = isGPT5 || useWebSearch;

    if (self.webSearchEnabled && !modelSupportsWebSearch) {
        [self appendToChat:[NSString stringWithFormat:
            @"[System: Web search skipped — not supported by %@. "
             "Switch to gpt-4o or a gpt-5 model to use web search.]",
            self.selectedModel]];
        EZLogf(EZLogLevelWarning, @"WEBSEARCH",
               @"Skipped — model %@ doesn't support Responses API tools", self.selectedModel);
    }

    NSString *endpointStr = useResponsesAPI
        ? @"https://api.openai.com/v1/responses"
        : @"https://api.openai.com/v1/chat/completions";

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:endpointStr]];
    request.HTTPMethod = @"POST";
    if (isGPT5 && useWebSearch)       request.timeoutInterval = 240;
    else if (isGPT5)                  request.timeoutInterval = 180;
    else                              request.timeoutInterval = 90;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
   forHTTPHeaderField:@"Authorization"];

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"model"] = self.selectedModel;
    NSString *sys  = [defaults stringForKey:@"systemMessage"];

    NSArray *cleanContext = [self sanitizedContextForAPI:self.chatContext
                                           modelSupportsVision:[self modelSupportsVision:self.selectedModel]
                                               useResponsesAPI:useResponsesAPI];

    if (useResponsesAPI) {
        if (sys.length > 0) body[@"instructions"] = sys;
        body[@"input"] = cleanContext;
        if (useWebSearch) {
            NSString *loc = [defaults stringForKey:@"webSearchLocation"] ?: @"";
            NSMutableDictionary *webTool = [@{@"type": @"web_search_preview"} mutableCopy];
            if (loc.length > 0) webTool[@"user_location"] = @{@"type":@"approximate",@"city":loc};
            body[@"tools"] = @[webTool];
            EZLog(EZLogLevelInfo, @"WEBSEARCH", @"Tool attached");
        }
    } else {
        float temp = [defaults floatForKey:@"temperature"];
        body[@"temperature"]       = @(temp > 0 ? temp : 0.7);
        body[@"frequency_penalty"] = @([defaults floatForKey:@"frequency"]);
        NSMutableArray *messages   = [NSMutableArray array];
        if (sys.length > 0) [messages addObject:@{@"role":@"system",@"content":sys}];
        [messages addObjectsFromArray:cleanContext];
        body[@"messages"] = messages;
    }

    NSError *bodyErr;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyErr];
    if (bodyErr) { [self handleAPIError:@"Failed to build request"]; return; }

    EZLogf(EZLogLevelInfo, @"API", @"→ %@ [%@]%@",
           endpointStr, self.selectedModel, useWebSearch ? @" +web" : @"");

    NSString *capturedPrompt   = self.lastUserPrompt;
    NSString *capturedThreadID = self.activeThread.threadID;
    NSMutableArray *capturedAttachments = [self.activeThread.attachmentPaths mutableCopy];

    // pendingImagePath is set only when the user explicitly attaches a file THIS turn.
    // It is the sole reliable indicator that this exchange actually involves an image.
    // Scanning chatContext for _isVisionAttachment was NOT sufficient — that flag persists
    // on historical messages indefinitely, causing lastImageLocalPath to be injected into
    // every subsequent memory even when the image has nothing to do with the current turn.
    // lastImageLocalPath is intentionally excluded: it is a sticky path from a prior
    // generation/import and injecting it into unrelated memories is the reported bug.
    if (self.pendingImagePath.length > 0 &&
        ![capturedAttachments containsObject:self.pendingImagePath]) {
        [capturedAttachments addObject:self.pendingImagePath];
    }
    // Always clear pendingImagePath after capture — it belongs to this turn only.
    self.pendingImagePath = nil;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { [self handleAPIError:error.localizedDescription]; return; }

        NSError *jsonErr;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr || !jsonObj || [jsonObj isKindOfClass:[NSNull class]]) {
            [self handleAPIError:@"Could not parse API response"]; return;
        }
        NSDictionary *json = jsonObj;

        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id msg = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(msg && ![msg isKindOfClass:[NSNull class]])
                ? (NSString *)msg : @"Unknown API error"];
            return;
        }

        NSString *reply = nil;
        if (useResponsesAPI) {
            id outputObj = json[@"output"];
            if (outputObj && ![outputObj isKindOfClass:[NSNull class]]) {
                for (id item in (NSArray *)outputObj) {
                    if ([item isKindOfClass:[NSNull class]]) continue;
                    NSDictionary *d = item;
                    if (![[d[@"type"] description] isEqualToString:@"message"]) continue;
                    id contentArr = d[@"content"];
                    if (!contentArr || [contentArr isKindOfClass:[NSNull class]]) continue;
                    for (id block in (NSArray *)contentArr) {
                        if ([block isKindOfClass:[NSNull class]]) continue;
                        NSDictionary *b = block;
                        if (![[b[@"type"] description] isEqualToString:@"output_text"]) continue;
                        id t = b[@"text"];
                        if (t && ![t isKindOfClass:[NSNull class]]) { reply = (NSString *)t; break; }
                    }
                    if (reply) break;
                }
            }
        } else {
            id choicesObj = json[@"choices"];
            if (choicesObj && ![choicesObj isKindOfClass:[NSNull class]]
                && [(NSArray *)choicesObj count] > 0) {
                id first = ((NSArray *)choicesObj)[0];
                if (first && ![first isKindOfClass:[NSNull class]]) {
                    id msgObj = ((NSDictionary *)first)[@"message"];
                    if (msgObj && ![msgObj isKindOfClass:[NSNull class]]) {
                        id c = ((NSDictionary *)msgObj)[@"content"];
                        if (c && ![c isKindOfClass:[NSNull class]]) reply = (NSString *)c;
                    }
                }
            }
        }

        if (!reply.length) {
            EZLogf(EZLogLevelError, @"API", @"No reply. Raw: %@", json);
            [self handleAPIError:@"Unexpected response format"]; return;
        }
        EZLogf(EZLogLevelInfo, @"API", @"Reply %lu chars", (unsigned long)reply.length);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastAIResponse = reply;
            [self.chatContext addObject:@{@"role": @"assistant", @"content": reply}];

            NSMutableArray<NSString *> *codePaths = [NSMutableArray array];
            NSString *displayReply = [self processReplyWithCodeBlocks:reply savedPaths:codePaths];

            NSMutableArray *allAttachments = [capturedAttachments mutableCopy];
            for (NSString *p in codePaths) {
                if (![allAttachments containsObject:p]) [allAttachments addObject:p];
            }

            [self appendToChat:[NSString stringWithFormat:@"AI: %@", displayReply]];
            [self saveActiveThread];
            [self checkReplyForLocalFilePaths:reply];
        });

        createMemoryFromCompletion(capturedPrompt ?: @"", reply, apiKey, capturedThreadID,
                                   capturedAttachments,
        ^(NSString *entry) {
            if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved %lu chars",
                              (unsigned long)entry.length);
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DALL-E 3 Generation
// ─────────────────────────────────────────────────────────────────────────────

- (void)callDalle3:(NSString *)prompt {
    [self appendToChat:@"[System: Generating Image...]"];
    EZLog(EZLogLevelInfo, @"DALLE", @"Sending DALL-E 3 request");
    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/images/generations"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"model":@"dall-e-3", @"prompt":prompt, @"n":@1, @"size":@"1024x1024"
    } options:0 error:nil];

    NSString *savedPrompt = prompt;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (!data) { [self handleAPIError:error.localizedDescription ?: @"DALL-E failed"]; return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id m = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(m && ![m isKindOfClass:[NSNull class]]) ? m : @"DALL-E error"];
            return;
        }
        id dataArr = json[@"data"];
        if (!dataArr || [dataArr isKindOfClass:[NSNull class]] || [(NSArray *)dataArr count] == 0) {
            [self handleAPIError:@"No image in response"]; return;
        }
        id imgObj = ((NSArray *)dataArr)[0];
        id imgURL = ([imgObj isKindOfClass:[NSDictionary class]]) ? imgObj[@"url"] : nil;
        if (!imgURL || [imgURL isKindOfClass:[NSNull class]]) {
            [self handleAPIError:@"No image URL"]; return;
        }
        EZLog(EZLogLevelInfo, @"DALLE", @"Image URL received");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastImagePrompt = savedPrompt;
        });
        [self downloadAndSaveImage:(NSString *)imgURL purpose:@"dalle"];
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - gpt-image-1 Text-to-Image Generation
// ─────────────────────────────────────────────────────────────────────────────

- (void)callGptImage1:(NSString *)prompt {
    [self appendToChat:@"[System: Generating image with gpt-image-1...]"];
    EZLog(EZLogLevelInfo, @"GPTIMAGE", @"Sending generation request");
    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/images/generations"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 120;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    NSUserDefaults *imgDefaults = [NSUserDefaults standardUserDefaults];
    NSString *imgSize    = [imgDefaults stringForKey:@"imgSize"]    ?: @"1024x1024";
    NSString *imgQuality = [imgDefaults stringForKey:@"imgQuality"] ?: @"auto";
    NSString *imgFormat  = [imgDefaults stringForKey:@"imgFormat"]  ?: @"png";
    NSString *imgBg      = [imgDefaults stringForKey:@"imgBackground"] ?: @"auto";
    NSString *imgMod     = [imgDefaults stringForKey:@"imgModeration"] ?: @"auto";
    // Use the actual selected model so gpt-image-1.5, -mini, chatgpt-image-latest all work
    NSString *imgModel   = self.selectedModel;
    if ([imgModel isEqualToString:@"gpt-image-1-edit"]) imgModel = @"gpt-image-1";
    NSMutableDictionary *imgParams = [@{
        @"model":         imgModel,
        @"prompt":        prompt,
        @"n":             @1,
        @"size":          imgSize,
        @"quality":       imgQuality,
        @"output_format": imgFormat,
        @"background":    imgBg,
        @"moderation":    imgMod,
    } mutableCopy];
    // output_format=png always returns b64_json for gpt-image-1 family.
    // Request b64 explicitly so we can save directly without a second download.
    imgParams[@"response_format"] = @"b64_json";
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:imgParams options:0 error:nil];

    NSString *savedPrompt = prompt;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (!data) { [self handleAPIError:error.localizedDescription ?: @"gpt-image-1 request failed"]; return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        EZLogf(EZLogLevelDebug, @"GPTIMAGE", @"Response: %@", json);
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id m = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(m && ![m isKindOfClass:[NSNull class]]) ? m : @"gpt-image-1 error"];
            return;
        }
        id dataArr = json[@"data"];
        if (!dataArr || [dataArr isKindOfClass:[NSNull class]] || [(NSArray *)dataArr count] == 0) {
            [self handleAPIError:@"No image in response"]; return;
        }
        id imgObj  = ((NSArray *)dataArr)[0];
        id imgURL  = ([imgObj isKindOfClass:[NSDictionary class]]) ? imgObj[@"url"]      : nil;
        id b64     = ([imgObj isKindOfClass:[NSDictionary class]]) ? imgObj[@"b64_json"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastImagePrompt = savedPrompt;
        });
        if (imgURL && ![imgURL isKindOfClass:[NSNull class]]) {
            EZLog(EZLogLevelInfo, @"GPTIMAGE", @"URL received");
            [self downloadAndSaveImage:(NSString *)imgURL purpose:@"gptimage"];
        } else if (b64 && ![b64 isKindOfClass:[NSNull class]]) {
            EZLog(EZLogLevelInfo, @"GPTIMAGE", @"b64_json received");
            NSData *imgData = [[NSData alloc] initWithBase64EncodedString:(NSString *)b64 options:0];
            if (imgData) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *savedPath = EZAttachmentSave(imgData, @"gptimage_result.png");
                    if (savedPath) self.lastImageLocalPath = savedPath;
                    NSURL *tmp = [NSURL fileURLWithPath:
                        [NSTemporaryDirectory() stringByAppendingPathComponent:@"gptimage_gen.png"]];
                    [imgData writeToURL:tmp atomically:YES];
                    self.previewURL = tmp;
                    QLPreviewController *ql = [[QLPreviewController alloc] init];
                    ql.dataSource = self;
                    [self presentViewController:ql animated:YES completion:nil];
                });
            }
        } else {
            [self handleAPIError:@"No image URL or data in gpt-image-1 response"];
        }
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Edit (gpt-image-1)
// ─────────────────────────────────────────────────────────────────────────────

- (void)callImageEdit:(NSString *)prompt imagePath:(NSString *)imagePath {
    if (!imagePath) {
        [self appendToChat:@"[Error: No image attached for editing]"]; return;
    }
    [self appendToChat:@"[System: Editing image with gpt-image-1...]"];
    EZLog(EZLogLevelInfo, @"IMGEDIT", @"Sending image edit request");

    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    NSData *imageData = [NSData dataWithContentsOfFile:imagePath]
                     ?: [NSData dataWithContentsOfURL:[NSURL fileURLWithPath:imagePath]];
    if (!imageData) {
        [self appendToChat:@"[Error: Could not read image for editing]"]; return;
    }

    UIImage *img = [UIImage imageWithData:imageData];
    if (!img) { [self appendToChat:@"[Error: Could not decode image for editing]"]; return; }
    NSData *pngData = UIImagePNGRepresentation(img);
    if (!pngData) { [self appendToChat:@"[Error: Could not convert image to PNG]"]; return; }
    EZLogf(EZLogLevelInfo, @"IMGEDIT", @"PNG ready: %lu bytes", (unsigned long)pngData.length);

    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/images/edits"]];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 120;
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
       forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
       forHTTPHeaderField:@"Authorization"];

    NSMutableData *body = [NSMutableData data];

    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"model\"\r\n\r\ngpt-image-1\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"image\"; filename=\"image.png\"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: image/png\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:pngData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"prompt\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[prompt dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    NSUserDefaults *editDefaults = [NSUserDefaults standardUserDefaults];
    NSString *editSize   = [editDefaults stringForKey:@"imgSize"]       ?: @"1024x1024";
    NSString *editQual   = [editDefaults stringForKey:@"imgQuality"]    ?: @"auto";
    NSString *editFmt    = [editDefaults stringForKey:@"imgFormat"]     ?: @"png";
    NSString *editBg     = [editDefaults stringForKey:@"imgBackground"] ?: @"auto";

    // Helper block to append a form field
    void (^addField)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
        [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary]
                         dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:
            @"Content-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", name, value]
            dataUsingEncoding:NSUTF8StringEncoding]];
    };
    addField(@"n",             @"1");
    addField(@"size",          editSize);
    addField(@"quality",       editQual);
    addField(@"output_format", editFmt);
    addField(@"background",    editBg);
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary]
                     dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    EZLogf(EZLogLevelInfo, @"IMGEDIT", @"Sending — prompt: %@", prompt);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (!data) { [self handleAPIError:error.localizedDescription ?: @"Image edit failed"]; return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        EZLogf(EZLogLevelDebug, @"IMGEDIT", @"Response: %@", json);
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id m = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(m && ![m isKindOfClass:[NSNull class]]) ? m : @"Image edit error"];
            return;
        }
        id dataArr = json[@"data"];
        if (!dataArr || [dataArr isKindOfClass:[NSNull class]] || [(NSArray *)dataArr count] == 0) {
            [self handleAPIError:@"No image in edit response"]; return;
        }
        id imgObj = ((NSArray *)dataArr)[0];
        id imgURL = ([imgObj isKindOfClass:[NSDictionary class]]) ? imgObj[@"url"] : nil;
        id b64    = ([imgObj isKindOfClass:[NSDictionary class]]) ? imgObj[@"b64_json"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastImagePrompt = prompt;
            self.selectedModel = @"gpt-image-1-edit";
            [self.modelButton setTitle:@"Model: gpt-image-1 (edit mode)" forState:UIControlStateNormal];
            [self appendToChat:@"[System: Edit complete — still in edit mode. Attach a new image or type another edit prompt.]"];
        });
        if (imgURL && ![imgURL isKindOfClass:[NSNull class]]) {
            EZLog(EZLogLevelInfo, @"IMGEDIT", @"URL received");
            [[[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:(NSString *)imgURL]
                completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
                if (!location) { [self handleAPIError:@"Edit result download failed"]; return; }
                NSURL *tmp = [NSURL fileURLWithPath:
                    [NSTemporaryDirectory() stringByAppendingPathComponent:@"edit_gen.png"]];
                [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
                [[NSFileManager defaultManager] copyItemAtURL:location toURL:tmp error:nil];
                NSData *imgData = [NSData dataWithContentsOfURL:tmp];
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *savedPath = imgData ? EZAttachmentSave(imgData, @"edit_result.png") : nil;
                    if (savedPath) {
                        self.lastImageLocalPath = savedPath;
                        self.activeThread.lastImageLocalPath = savedPath;
                        [self saveActiveThread];
                        [self persistImagePath:savedPath prompt:self.lastImagePrompt];
                    }
                    self.previewURL = tmp;
                    QLPreviewController *ql = [[QLPreviewController alloc] init];
                    ql.dataSource = self;
                    [self presentViewController:ql animated:YES completion:nil];
                });
            }] resume];
        } else if (b64 && ![b64 isKindOfClass:[NSNull class]]) {
            EZLog(EZLogLevelInfo, @"IMGEDIT", @"b64_json received");
            NSData *imgData = [[NSData alloc] initWithBase64EncodedString:(NSString *)b64 options:0];
            if (imgData) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *savedPath = EZAttachmentSave(imgData, @"edit_result.png");
                    if (savedPath) {
                        self.lastImageLocalPath = savedPath;
                        self.activeThread.lastImageLocalPath = savedPath;
                        [self saveActiveThread];
                        [self persistImagePath:savedPath prompt:self.lastImagePrompt];
                    }
                    NSURL *tmp = [NSURL fileURLWithPath:
                        [NSTemporaryDirectory() stringByAppendingPathComponent:@"edit_gen.png"]];
                    [imgData writeToURL:tmp atomically:YES];
                    self.previewURL = tmp;
                    QLPreviewController *ql = [[QLPreviewController alloc] init];
                    ql.dataSource = self;
                    [self presentViewController:ql animated:YES completion:nil];
                });
            }
        } else {
            [self handleAPIError:@"No image URL or data in edit response"];
        }
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sora Text-to-Video (always async job)
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Sora 2 API spec:
//   sora-2:     "seconds" param as STRING — "4" | "8" | "12" | "16"
//   sora-2-pro: "seconds" param as STRING — "5" | "10" | "15" | "20"
//   "size" param: "480p" | "720p" | "1080p"
// Endpoint: POST /v1/videos  →  async job {id, status:"queued"}
// Poll:     GET  /v1/videos/{id}
// Content:  GET  /v1/videos/{id}/content
// ─────────────────────────────────────────────────────────────────────────────

- (void)callSora:(NSString *)prompt {
    [self appendToChat:@"[System: Submitting Sora 2 video job...]"];
    EZLog(EZLogLevelInfo, @"SORA", @"Sending request");

    NSUserDefaults *d    = [NSUserDefaults standardUserDefaults];
    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    NSString *videoModel = [d stringForKey:@"soraModel"] ?: @"sora-2";
    NSString *resolution = [d stringForKey:@"soraSize"]  ?: @"720p";
    NSInteger rawDur     = [d integerForKey:@"soraDuration"] ?: 4;

    NSString *secondsStr;
    BOOL isPro = [videoModel isEqualToString:@"sora-2-pro"];
    if (isPro) {
        NSArray<NSNumber *> *valid = @[@5, @10, @15, @20];
        NSInteger best = 5, bestDiff = NSIntegerMax;
        for (NSNumber *v in valid) {
            NSInteger diff = ABS(rawDur - v.integerValue);
            if (diff < bestDiff) { bestDiff = diff; best = v.integerValue; }
        }
        secondsStr = [NSString stringWithFormat:@"%ld", (long)best];
    } else {
        NSArray<NSNumber *> *valid = @[@4, @8, @12, @16];
        NSInteger best = 4, bestDiff = NSIntegerMax;
        for (NSNumber *v in valid) {
            NSInteger diff = ABS(rawDur - v.integerValue);
            if (diff < bestDiff) { bestDiff = diff; best = v.integerValue; }
        }
        secondsStr = [NSString stringWithFormat:@"%ld", (long)best];
    }

    NSArray<NSString *> *validRes = @[@"1280x720", @"720x1280", @"1024x1792", @"1792x1024"];
    if (![validRes containsObject:resolution]) {
        NSDictionary *resMap = @{
            @"480p":   @"1280x720",
            @"720p":   @"1280x720",
            @"1080p":  @"1792x1024",
            @"portrait": @"720x1280",
            @"landscape": @"1280x720",
            @"480x270":  @"1280x720",
            @"1280x720": @"1280x720",
            @"1920x1080":@"1792x1024"
        };
        resolution = resMap[resolution] ?: @"1280x720";
    }

    if (rawDur != secondsStr.integerValue) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:[NSString stringWithFormat:
                @"[System: Duration snapped to %@s (valid for %@)]",
                secondsStr, videoModel]];
        });
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/videos"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    NSError *bodyErr;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"model":   videoModel,
        @"prompt":  prompt,
        @"size":    resolution,
        @"seconds": secondsStr
    } options:0 error:&bodyErr];
    if (bodyErr) { [self handleAPIError:@"Failed to build Sora request"]; return; }

    EZLogf(EZLogLevelInfo, @"SORA", @"model=%@ size=%@ seconds=%@", videoModel, resolution, secondsStr);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { [self handleAPIError:error.localizedDescription]; return; }

        NSString *rawBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"(unreadable)";
        EZLogf(EZLogLevelDebug, @"SORA", @"Raw response: %@", rawBody);

        NSError *parseErr;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (parseErr || !jsonObj || [jsonObj isKindOfClass:[NSNull class]]) {
            EZLogf(EZLogLevelError, @"SORA", @"Parse failed. Raw: %@", rawBody);
            [self handleAPIError:@"Could not parse Sora response — check log"]; return;
        }
        NSDictionary *json = jsonObj;
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id m = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(m && ![m isKindOfClass:[NSNull class]]) ? m : @"Sora error"];
            return;
        }

        NSString *jobId = nil;
        id topId = json[@"id"];
        if (topId && ![topId isKindOfClass:[NSNull class]]) jobId = (NSString *)topId;

        if (!jobId.length) {
            EZLogf(EZLogLevelError, @"SORA", @"No job ID. Full response: %@", json);
            [self handleAPIError:@"Sora returned no job ID — check log"]; return;
        }

        EZLogf(EZLogLevelInfo, @"SORA", @"Job created: %@  status: %@", jobId, json[@"status"] ?: @"?");

        // Only persist the job ID — never store the API key in NSUserDefaults.
        // On resume, the key is reloaded from EZKeyVault (Keychain).
        [[NSUserDefaults standardUserDefaults] setObject:jobId forKey:@"soraActivejobId"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:[NSString stringWithFormat:
                @"[Sora: Job queued (%@) — polling for completion...]", jobId]];
        });
        [self pollSoraJob:jobId apiKey:apiKey];
    }] resume];
}

- (void)pollSoraJob:(NSString *)jobId apiKey:(NSString *)apiKey {
    __block NSInteger attempts = 0;
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    __block __weak void (^weakPoll)(void);
    void (^poll)(void);
    poll = ^{
        void (^strongPoll)(void) = weakPoll;
        if (!strongPoll) return;
        attempts++;
        if (attempts > 36) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[Sora: Generation is taking unusually long. "
                 "Check platform.openai.com/storage for your video.]"];
            });
            return;
        }
        NSTimeInterval delay = (attempts <= 6) ? 5.0 : 10.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), q, ^{
            NSString *pollURL = [NSString stringWithFormat:@"https://api.openai.com/v1/videos/%@", jobId];
            NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:pollURL]];
            r.HTTPMethod = @"GET";
            [r setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

            [[[NSURLSession sharedSession] dataTaskWithRequest:r
                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                void (^s)(void) = weakPoll;
                if (!data || err) { if (s) s(); return; }

                id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (!j || [j isKindOfClass:[NSNull class]]) { if (s) s(); return; }
                NSDictionary *jd = j;
                NSString *status = jd[@"status"] ?: @"";
                EZLogf(EZLogLevelInfo, @"SORA", @"Poll %ld — status: %@", (long)attempts, status);

                static NSString *lastShownStatus = nil;
                if (![status isEqualToString:lastShownStatus]) {
                    lastShownStatus = [status copy];
                    NSString *emoji = [status isEqualToString:@"queued"]     ? @"⏳" :
                                      [status isEqualToString:@"processing"] ? @"⚙️" :
                                      ([status isEqualToString:@"completed"] ||
                                       [status isEqualToString:@"succeeded"] ||
                                       [status isEqualToString:@"ready"])    ? @"✅" :
                                      ([status isEqualToString:@"failed"] ||
                                       [status isEqualToString:@"error"])    ? @"❌" : @"🔄";
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self appendToChat:[NSString stringWithFormat:@"[Sora: %@ %@]", emoji, status]];
                    });
                }

                if ([status isEqualToString:@"failed"] || [status isEqualToString:@"error"]) {
                    id errDetail = jd[@"error"];
                    NSString *msg = (errDetail && ![errDetail isKindOfClass:[NSNull class]])
                        ? [errDetail description] : @"Video generation failed";
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"soraActivejobId"];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self appendToChat:[NSString stringWithFormat:@"[Sora failed: %@]", msg]];
                    });
                    return;
                }

                BOOL done = ([status isEqualToString:@"completed"] ||
                             [status isEqualToString:@"succeeded"] ||
                             [status isEqualToString:@"ready"]);
                if (done) {
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"soraActivejobId"];
                    EZLogf(EZLogLevelInfo, @"SORA", @"Job complete — fetching content");
                    [self fetchSoraContent:jobId apiKey:apiKey];
                    return;
                }

                if (s) s();
            }] resume];
        });
    };
    weakPoll = poll;
    poll();
}

- (void)resumePendingSoraJobIfNeeded {
    if (!self.isViewLoaded || !self.view.window) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *jobId   = [d stringForKey:@"soraActivejobId"];
    // CHANGED: reload key from EZKeyVault — never stored in NSUserDefaults
    NSString *apiKey  = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];
    if (!jobId.length || !apiKey.length) return;
    EZLogf(EZLogLevelInfo, @"SORA", @"Resuming poll for job: %@", jobId);
    [self appendToChat:[NSString stringWithFormat:
        @"[Sora: Resuming poll for job %@...]", jobId]];
    [self pollSoraJob:jobId apiKey:apiKey];
}

- (void)fetchSoraContent:(NSString *)jobId apiKey:(NSString *)apiKey {
    NSString *contentURL = [NSString stringWithFormat:
        @"https://api.openai.com/v1/videos/%@/content", jobId];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:contentURL]];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { [self handleAPIError:error.localizedDescription]; return; }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        EZLogf(EZLogLevelInfo, @"SORA", @"Content fetch HTTP %ld, %lu bytes",
               (long)http.statusCode, (unsigned long)data.length);

        if (http.statusCode == 200 && data.length > 10000) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *savedPath = EZAttachmentSave(data, @"sora_video.mp4");
                NSURL *tmp = [NSURL fileURLWithPath:
                    [NSTemporaryDirectory() stringByAppendingPathComponent:@"sora_gen.mp4"]];
                [data writeToURL:tmp atomically:YES];
                if (savedPath) {
                    self.activeThread.lastVideoLocalPath = savedPath;
                    [self saveActiveThread];
                }
                [self appendToChat:@"[Sora: Video ready \u2713]"];
                // Present immediately if visible; defer to viewWillAppear if backgrounded
                if (self.view.window) {
                    self.previewURL = tmp;
                    QLPreviewController *ql = [[QLPreviewController alloc] init];
                    ql.dataSource = self;
                    [self presentViewController:ql animated:YES completion:nil];
                    EZLog(EZLogLevelInfo, @"SORA", @"Video saved and presented");
                } else {
                    self.pendingVideoURL = tmp;
                    EZLog(EZLogLevelInfo, @"SORA", @"Video saved — deferred (app backgrounded)");
                }
            });
            return;
        }

        NSError *parseErr;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (!parseErr && jsonObj && ![jsonObj isKindOfClass:[NSNull class]]) {
            NSDictionary *json = jsonObj;
            EZLogf(EZLogLevelDebug, @"SORA", @"Content JSON: %@", json);
            id urlObj = json[@"url"] ?: json[@"download_url"] ?: json[@"video_url"];
            if (urlObj && ![urlObj isKindOfClass:[NSNull class]]) {
                [self downloadAndShowVideo:(NSString *)urlObj]; return;
            }
        }

        NSURL *finalURL = response.URL;
        if (finalURL && ![finalURL.absoluteString containsString:@"/content"]) {
            EZLogf(EZLogLevelInfo, @"SORA", @"Following redirect to: %@", finalURL);
            [self downloadAndShowVideo:finalURL.absoluteString]; return;
        }

        [self handleAPIError:@"Could not retrieve Sora video content"];
        EZLogf(EZLogLevelError, @"SORA", @"Content fetch failed. HTTP %ld body: %@",
               (long)http.statusCode,
               [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"?");
    }] resume];
}

- (void)downloadAndShowVideo:(NSString *)urlString {
    EZLog(EZLogLevelInfo, @"SORA", @"Downloading video...");
    [[[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:urlString]
        completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
        if (!location) { [self handleAPIError:@"Video download failed"]; return; }
        NSURL *tmp = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"sora_gen.mp4"]];
        [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:location toURL:tmp error:nil];

        NSData *videoData = [NSData dataWithContentsOfURL:tmp];
        if (videoData) {
            NSString *savedPath = EZAttachmentSave(videoData, @"sora_video.mp4");
            if (savedPath) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.activeThread.lastVideoLocalPath = savedPath;
                    [self saveActiveThread];
                });
            }
        }

        EZLog(EZLogLevelInfo, @"SORA", @"Video ready");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:@"[Sora: Video ready \u2713]"];
            if (self.view.window) {
                self.previewURL = tmp;
                QLPreviewController *ql = [[QLPreviewController alloc] init];
                ql.dataSource = self;
                [self presentViewController:ql animated:YES completion:nil];
                EZLog(EZLogLevelInfo, @"SORA", @"Video presented immediately");
            } else {
                self.pendingVideoURL = tmp;
                EZLog(EZLogLevelInfo, @"SORA", @"Video deferred — app backgrounded");
            }
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Download / Save / QuickLook
// ─────────────────────────────────────────────────────────────────────────────

- (void)downloadAndSaveImage:(NSString *)urlString purpose:(NSString *)purpose {
    [[[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:urlString]
        completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
        if (!location) {
            EZLogf(EZLogLevelError, @"IMAGE", @"Download failed: %@", err.localizedDescription);
            [self handleAPIError:@"Image download failed"]; return;
        }
        NSString *tmpName = [NSString stringWithFormat:@"%@_gen.png", purpose];
        NSURL *tmp = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName]];
        [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:location toURL:tmp error:nil];

        NSData *imgData = [NSData dataWithContentsOfURL:tmp];
        NSString *savedPath = imgData ? EZAttachmentSave(imgData, tmpName) : nil;

        EZLogf(EZLogLevelInfo, @"IMAGE", @"Image saved: %@", savedPath ?: @"(temp only)");

        dispatch_async(dispatch_get_main_queue(), ^{
            if (savedPath) {
                self.lastImageLocalPath = savedPath;
                self.activeThread.lastImageLocalPath = savedPath;
                NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
                [att addObject:savedPath];
                self.activeThread.attachmentPaths = [att copy];
                [self saveActiveThread];
                [self persistImagePath:savedPath prompt:self.lastImagePrompt];
            }
            self.previewURL = tmp;
            QLPreviewController *ql = [[QLPreviewController alloc] init];
            ql.dataSource = self;
            [self presentViewController:ql animated:YES completion:nil];
        });
    }] resume];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)c { return 1; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)c previewItemAtIndex:(NSInteger)i {
    return self.previewURL;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Whisper
// ─────────────────────────────────────────────────────────────────────────────

- (void)transcribeAudio:(NSURL *)fileURL {
    [self appendToChat:@"[System: Whisper uploading...]"];
    EZLog(EZLogLevelInfo, @"WHISPER", @"Starting transcription");
    // CHANGED: Use EZKeyVault instead of legacy NSUserDefaults @"apiKey"
    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/audio/transcriptions"]];
    req.HTTPMethod = @"POST";
    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
       forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
       forHTTPHeaderField:@"Authorization"];
    NSMutableData *body = [NSMutableData data];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:
        @"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n",
        fileURL.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: audio/mpeg\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[NSData dataWithContentsOfURL:fileURL]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (!data) {
            EZLogf(EZLogLevelError, @"WHISPER", @"Failed: %@", error.localizedDescription); return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *formatted = [self formatWhisperTranscript:json[@"text"]];
        EZLogf(EZLogLevelInfo, @"WHISPER", @"Done (%lu chars)", (unsigned long)formatted.length);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.messageTextField.text = formatted;
            [self appendToChat:[NSString stringWithFormat:@"[Whisper]: %@", formatted]];
        });
    }] resume];
}

- (NSString *)formatWhisperTranscript:(NSString *)raw {
    if (!raw) return @"";
    return [[[raw stringByReplacingOccurrencesOfString:@". " withString:@".\n"]
                  stringByReplacingOccurrencesOfString:@"! " withString:@"!\n"]
                  stringByReplacingOccurrencesOfString:@"? " withString:@"?\n"];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Misc
// ─────────────────────────────────────────────────────────────────────────────

/// Returns YES for any model that goes to /v1/images/generations (not chat)
- (BOOL)isGptImage1Family:(NSString *)model {
    return [model hasPrefix:@"gpt-image-"] || [model isEqualToString:@"chatgpt-image-latest"];
}

- (BOOL)modelSupportsVision:(NSString *)model {
    NSSet *vision = [NSSet setWithObjects:
        @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4",
        @"gpt-5", @"gpt-5-mini", @"gpt-5-pro",
        @"gpt-image-1", nil];
    if ([model hasPrefix:@"gpt-5"]) return YES;
    return [vision containsObject:model];
}

- (NSArray *)sanitizedContextForAPI:(NSArray *)context
                  modelSupportsVision:(BOOL)supportsVision
                      useResponsesAPI:(BOOL)useResponsesAPI {
    NSInteger lastVisionIdx = -1;
    for (NSInteger i = (NSInteger)context.count - 1; i >= 0; i--) {
        NSDictionary *msg = context[(NSUInteger)i];
        if ([msg[@"_isVisionAttachment"] boolValue]) {
            lastVisionIdx = i; break;
        }
        id content = msg[@"content"];
        if ([content isKindOfClass:[NSArray class]]) {
            for (NSDictionary *block in (NSArray *)content) {
                NSString *type = [block[@"type"] description];
                if ([type isEqualToString:@"image_url"] || [type isEqualToString:@"input_image"]) {
                    lastVisionIdx = i; break;
                }
            }
        }
        if (lastVisionIdx >= 0) break;
    }

    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger i = 0; i < context.count; i++) {
        NSDictionary *msg = context[i];

        NSMutableDictionary *clean = [NSMutableDictionary dictionary];
        for (NSString *key in msg) {
            if ([key hasPrefix:@"_"]) continue;
            clean[key] = msg[key];
        }

        id content = clean[@"content"];
        if ([content isKindOfClass:[NSArray class]]) {
            NSArray *blocks   = (NSArray *)content;
            BOOL     hasImage = NO;
            for (NSDictionary *b in blocks) {
                NSString *t = [b[@"type"] description];
                if ([t isEqualToString:@"image_url"] || [t isEqualToString:@"input_image"]) {
                    hasImage = YES; break;
                }
            }

            if (hasImage) {
                BOOL isLatest   = ((NSInteger)i == lastVisionIdx);
                BOOL sendInline = isLatest && supportsVision;

                if (sendInline) {
                    NSMutableArray *convertedBlocks = [NSMutableArray array];
                    for (NSDictionary *b in blocks) {
                        NSString *type = [b[@"type"] description];

                        if ([type isEqualToString:@"image_url"] || [type isEqualToString:@"input_image"]) {
                            NSString *dataURL = nil;
                            id imgUrlVal = b[@"image_url"];
                            if ([imgUrlVal isKindOfClass:[NSDictionary class]]) {
                                dataURL = ((NSDictionary *)imgUrlVal)[@"url"];
                            } else if ([imgUrlVal isKindOfClass:[NSString class]]) {
                                dataURL = (NSString *)imgUrlVal;
                            }
                            if (!dataURL) continue;

                            if (useResponsesAPI) {
                                [convertedBlocks addObject:@{@"type":@"input_image", @"image_url":dataURL}];
                            } else {
                                [convertedBlocks addObject:@{@"type":@"image_url", @"image_url":@{@"url":dataURL}}];
                            }

                        } else if ([type isEqualToString:@"text"] || [type isEqualToString:@"input_text"]) {
                            NSString *text = b[@"text"] ?: @"";
                            if ([text isEqualToString:@"[image attached — await user question]"]) continue;
                            if (useResponsesAPI) {
                                [convertedBlocks addObject:@{@"type":@"input_text", @"text":text}];
                            } else {
                                [convertedBlocks addObject:@{@"type":@"text", @"text":text}];
                            }
                        } else {
                            [convertedBlocks addObject:b];
                        }
                    }
                    if (convertedBlocks.count > 0) {
                        clean[@"content"] = [convertedBlocks copy];
                        [result addObject:clean];
                    }
                } else {
                    NSMutableString *textContent = [NSMutableString string];
                    for (NSDictionary *b in blocks) {
                        NSString *t = [b[@"type"] description];
                        if ([t isEqualToString:@"text"] || [t isEqualToString:@"input_text"]) {
                            NSString *txt = b[@"text"] ?: @"";
                            if (![txt isEqualToString:@"[image attached — await user question]"]) {
                                [textContent appendString:txt];
                            }
                        }
                    }
                    if (textContent.length == 0) [textContent appendString:@"[image attached]"];
                    [result addObject:@{
                        @"role":    clean[@"role"] ?: @"user",
                        @"content": [textContent copy]
                    }];
                }
                continue;
            }

            if (useResponsesAPI) {
                NSMutableArray *convertedBlocks = [NSMutableArray array];
                for (NSDictionary *b in blocks) {
                    NSString *type = [b[@"type"] description];
                    if ([type isEqualToString:@"text"]) {
                        [convertedBlocks addObject:@{@"type":@"input_text", @"text":b[@"text"] ?: @""}];
                    } else {
                        [convertedBlocks addObject:b];
                    }
                }
                clean[@"content"] = [convertedBlocks copy];
                [result addObject:clean];
                continue;
            }
        }
        [result addObject:clean];
    }
    return [result copy];
}

- (void)handleAPIError:(NSString *)msg {
    EZLogf(EZLogLevelError, @"API", @"Error: %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self appendToChat:[NSString stringWithFormat:@"[API Error]: %@", msg]];
    });
}

- (void)keyboardWillChange:(NSNotification *)notification {
    CGRect kbFrame  = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    double duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    BOOL isHiding   = [notification.name isEqualToString:UIKeyboardWillHideNotification];
    self.containerBottomConstraint.constant = isHiding
        ? 0 : -(kbFrame.size.height - self.view.safeAreaInsets.bottom);
    [UIView animateWithDuration:duration animations:^{ [self.view layoutIfNeeded]; }];
}

- (void)setupKeyboardObservers {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification       object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification       object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (void)newChat {
    [self saveActiveThread];
    [self _resetConversation];
    [self appendToChat:@"[System: New chat started ✓]"];
    EZLog(EZLogLevelInfo, @"APP", @"New chat started by user");
}

- (void)deleteCurrentChat {
    if (self.chatContext.count == 0) return;
    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Delete This Chat?"
                         message:@"This conversation will be permanently deleted."
                  preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
        if (self.activeThread.threadID.length > 0) {
            EZThreadDelete(self.activeThread.threadID);
        }
        [self _resetConversation];
        [self appendToChat:@"[System: Chat deleted]"];
        EZLog(EZLogLevelInfo, @"APP", @"Chat deleted by user");
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)_resetConversation {
    [self.chatContext removeAllObjects];
    [self.displayMessages removeAllObjects];
    [self.chatTableView reloadData];
    self.lastAIResponse     = nil;
    self.lastUserPrompt     = nil;
    self.lastImagePrompt    = nil;
    self.lastImageLocalPath = nil;
    self.pendingFileContext = nil;
    self.pendingFileName    = nil;
    self.pendingImagePath   = nil;
    [self startNewThread];
    [self updateThreadTitleLabel];
}

- (void)clearConversation {
    [self saveActiveThread];
    [self _resetConversation];
    EZLog(EZLogLevelInfo, @"APP", @"Conversation cleared — new thread started");
}

- (void)copyLastResponse {
    if (!self.lastAIResponse) return;
    [UIPasteboard generalPasteboard].string = self.lastAIResponse;
    EZLog(EZLogLevelInfo, @"APP", @"Last response copied to clipboard");

    UIImage *checkImg = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    UIImage *origImg  = [UIImage systemImageNamed:@"doc.on.doc"];
    [self.clipboardButton setImage:checkImg forState:UIControlStateNormal];
    [self.clipboardButton setTintColor:[UIColor systemGreenColor]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.clipboardButton setImage:origImg forState:UIControlStateNormal];
        [self.clipboardButton setTintColor:nil];
    });
}

- (void)showModelPicker {
    NSDictionary *labels = @{
        @"gpt-5-pro":    @"💬 Chat + 👁 Vision",
        @"gpt-5":        @"💬 Chat + 👁 Vision",
        @"gpt-5-mini":   @"💬 Chat + 👁 Vision",
        @"gpt-4o":       @"💬 Chat + 👁 Vision ⭐",
        @"gpt-4o-mini":  @"💬 Chat + 👁 Vision (fast)",
        @"gpt-4-turbo":  @"💬 Chat + 👁 Vision",
        @"gpt-4":        @"💬 Chat + 👁 Vision",
        @"gpt-3.5-turbo":@"💬 Chat only",
        @"gpt-image-1.5":        @"🖼 Image gen (newest)",
        @"gpt-image-1":          @"🖼 Image gen + ✏️ Edit",
        @"gpt-image-1-mini":     @"🖼 Image gen (fast/cheap)",
        @"chatgpt-image-latest": @"🖼 ChatGPT image (latest)",
        @"dall-e-3":             @"🖼 Image gen only (legacy)",
        @"sora-2":       @"🎬 Video gen (4/8/12/16s)",
        @"sora-2-pro":   @"🎬 Video gen HQ (5/10/15/20s)",
        @"whisper-1":    @"🎙 Audio transcription only"
    };

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Model"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *model in self.models) {
        NSString *cap   = labels[model] ?: @"";
        NSString *title = cap.length > 0
            ? [NSString stringWithFormat:@"%@  —  %@", model, cap]
            : model;
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            if ([self.selectedModel isEqualToString:@"gpt-image-1-edit"] ||
                [self.selectedModel isEqualToString:@"dall-e-2-edit"]) {
                self.pendingImagePath = nil;
            }
            self.selectedModel = model;
            [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", model]
                              forState:UIControlStateNormal];
            [[NSUserDefaults standardUserDefaults] setObject:model forKey:@"selectedModel"];
            // Show image settings button only when an image generation model is active
            self.imageSettingsButton.hidden = !([self isGptImage1Family:model] ||
                                               [model isEqualToString:@"dall-e-3"]);
            EZLogf(EZLogLevelInfo, @"APP", @"Model → %@", model);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)persistImagePath:(NSString *)path prompt:(NSString *)prompt {
    if (!path.length) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:path   forKey:@"lastImageLocalPath"];
    [d setObject:prompt ?: @"" forKey:@"lastImagePrompt"];
    [d synchronize];
    EZLogf(EZLogLevelInfo, @"IMAGE", @"Persisted path: %@", path.lastPathComponent);
}

- (void)classifyImageIntent:(NSString *)prompt
              hasLocalImage:(BOOL)hasLocalImage
                     apiKey:(NSString *)apiKey
                 completion:(void(^)(NSString *intent))completion {

    NSString *lower = prompt.lowercaseString;

    NSArray *reopenSignals = @[
        @"again", @"reopen", @"re-open", @"pull up", @"pull it up",
        @"show it", @"display it", @"view it", @"see it again",
        @"missed it", @"didn't see", @"can't see", @"lost it",
        @"bring it back", @"show me again", @"display again",
        @"open it again", @"show that image", @"that image again",
        @"previous image", @"last image", @"the image again"
    ];

    NSArray *generateSignals = @[
        @"create", @"generate", @"make", @"draw", @"paint",
        @"a picture of", @"an image of", @"image of", @"picture of",
        @"new image", @"different image"
    ];

    NSArray *editSignals = @[
        @"edit", @"change", @"modify", @"adjust", @"alter",
        @"add to", @"remove from", @"make it", @"turn it into"
    ];

    NSInteger reopenScore = 0, generateScore = 0, editScore = 0;
    for (NSString *s in reopenSignals)   if ([lower containsString:s]) reopenScore++;
    for (NSString *s in generateSignals) if ([lower containsString:s]) generateScore++;
    for (NSString *s in editSignals)     if ([lower containsString:s]) editScore++;

    EZLogf(EZLogLevelDebug, @"IMAGE",
           @"Intent scores — reopen:%ld generate:%ld edit:%ld hasLocal:%d",
           (long)reopenScore, (long)generateScore, (long)editScore, hasLocalImage);

    if (reopenScore >= 2 && reopenScore > generateScore && hasLocalImage) {
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 1: reopen (score %ld)", (long)reopenScore);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"reopen"); });
        return;
    }
    if (generateScore >= 2 && generateScore > reopenScore) {
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 1: generate (score %ld)", (long)generateScore);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"generate"); });
        return;
    }
    if (editScore >= 2 && editScore > reopenScore && hasLocalImage) {
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 1: edit (score %ld)", (long)editScore);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"edit"); });
        return;
    }

    if (!hasLocalImage || !apiKey.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"generate"); });
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *sys =
            @"You classify user intent for an AI image app. The user may want to:\n"
             "  REOPEN — view/display a previously generated image they already have\n"
             "  GENERATE — create a brand new image from a description\n"
             "  EDIT — modify/edit a previously generated image\n\n"
             "Reply with exactly one word: REOPEN, GENERATE, or EDIT. Nothing else.";
        NSString *msg = [NSString stringWithFormat:
            @"User prompt: \"%@\"\nContext: User has a previously generated image available.",
            prompt];

        NSString *raw = EZCallHelperModel(sys, msg, apiKey, 10);
        NSString *result = [[raw uppercaseString]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 2 classifier: %@ → %@", prompt, result);

        NSString *intent = @"generate";
        if ([result isEqualToString:@"REOPEN"]) intent = @"reopen";
        else if ([result isEqualToString:@"EDIT"])   intent = @"edit";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(intent); });
    });
}

- (void)checkReplyForLocalFilePaths:(NSString *)reply {
    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docsDir) return;

    // Match any path under /var/mobile/ with any extension — fixes .ips, .json, etc.
    NSRegularExpression *pathRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(/var/mobile/[^\\s\"'<>]+\\.\\w+)"
                             options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray *matches = [pathRegex matchesInString:reply
                                          options:0
                                            range:NSMakeRange(0, reply.length)];
    for (NSTextCheckingResult *match in matches) {
        NSString *path = [reply substringWithRange:[match rangeAtIndex:1]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            EZLogf(EZLogLevelInfo, @"ATTACH", @"Model referenced local file: %@", path);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self offerToOpenLocalFile:path];
            });
            break;
        }
    }
}

- (void)reopenAttachmentFromMemory:(NSString *)keyword {
    NSArray<NSDictionary *> *allMemories = EZMemoryLoadAll();
    NSString *lowerKeyword = keyword.lowercaseString;

    for (NSDictionary *entry in allMemories.reverseObjectEnumerator) {
        NSArray *paths = entry[@"attachmentPaths"];
        for (NSString *path in paths) {
            if ([path.lastPathComponent.lowercaseString containsString:lowerKeyword] ||
                [[entry[@"summary"] lowercaseString] containsString:lowerKeyword]) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                    EZLogf(EZLogLevelInfo, @"ATTACH", @"Reopening from memory: %@", path);
                    [self offerToOpenLocalFile:path];
                    return;
                }
            }
        }
    }
    EZLogf(EZLogLevelInfo, @"ATTACH", @"No matching file found in memory for: %@", keyword);
}

- (void)offerToOpenLocalFile:(NSString *)path {
    self.previewURL = [NSURL fileURLWithPath:path];
    QLPreviewController *ql = [[QLPreviewController alloc] init];
    ql.dataSource = self;
    [self presentViewController:ql animated:YES completion:nil];
    [self appendToChat:[NSString stringWithFormat:@"[System: Opening %@]",
                        path.lastPathComponent]];
}

- (NSString *)fileExtensionForLanguage:(NSString *)lang {
    NSString *normalized = [[[lang lowercaseString]
                             stringByReplacingOccurrencesOfString:@"-" withString:@""]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSDictionary *map = @{
        @"python":        @"py",    @"py":           @"py",
        @"javascript":    @"js",    @"js":           @"js",
        @"typescript":    @"ts",    @"ts":           @"ts",
        @"swift":         @"swift",
        @"objc":          @"m",     @"objectivec":   @"m",
        @"objectivecpp":  @"mm",    @"objcpp":       @"mm",
        @"c":             @"c",
        @"cpp":           @"cpp",   @"c++":          @"cpp", @"cxx": @"cpp",
        @"java":          @"java",  @"kotlin":       @"kt",
        @"ruby":          @"rb",    @"go":           @"go",
        @"rust":          @"rs",    @"shell":        @"sh",
        @"bash":          @"sh",    @"sh":           @"sh",  @"zsh": @"sh",
        @"html":          @"html",  @"css":          @"css",
        @"json":          @"json",  @"xml":          @"xml",
        @"yaml":          @"yaml",  @"yml":          @"yaml",
        @"sql":           @"sql",   @"markdown":     @"md",  @"md": @"md",
        @"plaintext":     @"txt",   @"text":         @"txt", @"plain": @"txt",
        @"diff":          @"diff",  @"makefile":     @"mk",
        @"dart":          @"dart",  @"php":          @"php",
        @"cs":            @"cs",    @"csharp":       @"cs",
        @"r":             @"r",     @"matlab":       @"m",
        @"scala":         @"scala", @"lua":          @"lua",
        @"perl":          @"pl",    @"haskell":      @"hs",
    };
    NSString *ext = map[normalized];
    if (!ext) {
        NSCharacterSet *safe = [NSCharacterSet alphanumericCharacterSet];
        NSString *candidate = normalized.length > 6
            ? [normalized substringToIndex:6] : normalized;
        BOOL isSafe = YES;
        for (NSUInteger i = 0; i < candidate.length; i++) {
            if (![safe characterIsMember:[candidate characterAtIndex:i]]) { isSafe = NO; break; }
        }
        ext = (isSafe && candidate.length > 0) ? candidate : @"txt";
    }
    return ext;
}

- (NSString *)processReplyWithCodeBlocks:(NSString *)reply
                            savedPaths:(NSMutableArray<NSString *> *)savedPaths {
    return [self processReplyWithCodeBlocks:reply savedPaths:savedPaths isRestore:NO];
}

- (NSString *)processReplyWithCodeBlocks:(NSString *)reply
                            savedPaths:(NSMutableArray<NSString *> *)savedPaths
                             isRestore:(BOOL)isRestore {
    NSError *regexErr;
    NSRegularExpression *codeBlockRegex = [NSRegularExpression
        regularExpressionWithPattern:@"```([a-zA-Z0-9+#._-]*)[ \\t]*\\n([\\s\\S]+?)\\n[ \\t]*```"
                             options:0
                               error:&regexErr];
    if (regexErr || !codeBlockRegex) return reply;

    NSArray *matches = [codeBlockRegex matchesInString:reply
                                               options:0
                                                 range:NSMakeRange(0, reply.length)];
    if (matches.count == 0) return reply;

    NSMutableString *processed = [NSMutableString stringWithString:reply];
    NSInteger offset = 0;

    for (NSTextCheckingResult *match in matches) {
        NSRange langRange = [match rangeAtIndex:1];
        NSRange codeRange = [match rangeAtIndex:2];
        if (langRange.location == NSNotFound || codeRange.location == NSNotFound) continue;

        NSString *lang = [reply substringWithRange:langRange];
        NSString *code = [reply substringWithRange:codeRange];

        if (code.length < 5) continue;

        NSString *detectedName = nil;
        NSArray<NSString *> *firstLines = [[code componentsSeparatedByString:@"\n"]
                                           subarrayWithRange:NSMakeRange(0, MIN(2, [[code componentsSeparatedByString:@"\n"] count]))];
        NSError *fnErr;
        NSRegularExpression *fnRegex = [NSRegularExpression
            regularExpressionWithPattern:@"[\\w.+-]+\\.(?:m|h|mm|swift|py|js|ts|sh|bash|rb|go|rs|kt|java|c|cpp|cxx|cs|html|css|json|xml|yaml|yml|sql|md|txt|mk|makefile|gradle|plist|entitlements|pbxproj)"
                                 options:NSRegularExpressionCaseInsensitive error:&fnErr];
        if (!fnErr) {
            for (NSString *line in firstLines) {
                NSRange lineRange = NSMakeRange(0, line.length);
                NSTextCheckingResult *fnMatch = [fnRegex firstMatchInString:line options:0 range:lineRange];
                if (fnMatch) {
                    detectedName = [line substringWithRange:fnMatch.range];
                    break;
                }
            }
        }

        NSString *ext;
        NSString *label;
        if (detectedName.length > 0) {
            label = detectedName;
            ext   = detectedName.pathExtension.length > 0 ? detectedName.pathExtension : @"txt";
        } else {
            ext   = [self fileExtensionForLanguage:lang];
            label = lang.length > 0 ? lang : ext;
        }

        NSString *savedPath = nil;
        NSString *fileName  = detectedName.length > 0 ? detectedName
            : [NSString stringWithFormat:@"snippet.%@", ext];

        if (isRestore) {
            for (NSString *existingPath in self.activeThread.attachmentPaths) {
                if ([existingPath.lastPathComponent hasSuffix:[@"_" stringByAppendingString:fileName]] ||
                    [existingPath.lastPathComponent hasSuffix:fileName]) {
                    if ([[NSFileManager defaultManager] fileExistsAtPath:existingPath]) {
                        savedPath = existingPath;
                        break;
                    }
                }
            }
        }

        if (!savedPath) {
            NSData *codeData = [code dataUsingEncoding:NSUTF8StringEncoding];
            savedPath = codeData ? EZAttachmentSave(codeData, fileName) : nil;
            if (savedPath && !isRestore) {
                [savedPaths addObject:savedPath];
                NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
                if (![att containsObject:savedPath]) [att addObject:savedPath];
                self.activeThread.attachmentPaths = [att copy];
            }
            if (savedPath) EZLogf(EZLogLevelInfo, @"CODE", @"Saved %@ snippet: %@", label, savedPath);
        }

        NSString *placeholder = savedPath
            ? [NSString stringWithFormat:@"\n[CODE:%@:%@]\n", label, savedPath]
            : [NSString stringWithFormat:@"\n[CODE:%@]\n%@\n[/CODE]\n", label, code];

        NSRange originalRange  = [match range];
        NSRange adjustedRange  = NSMakeRange((NSUInteger)((NSInteger)originalRange.location + offset),
                                              originalRange.length);
        [processed replaceCharactersInRange:adjustedRange withString:placeholder];
        offset += (NSInteger)placeholder.length - (NSInteger)originalRange.length;
    }
    return [processed copy];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat display helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Primary append entry point. Detects role from prefix ("You: ", "AI: "),
/// splits [CODE:] markers into separate code cells, and reloads the table.
- (void)appendToChat:(NSString *)rawText {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self appendToChat:rawText]; });
        return;
    }
    NSString *role = @"system";
    NSString *text = rawText;
    if ([rawText hasPrefix:@"You: "]) { role = @"user";      text = [rawText substringFromIndex:5]; }
    else if ([rawText hasPrefix:@"AI: "]) { role = @"assistant"; text = [rawText substringFromIndex:4]; }

    if ([text containsString:@"[CODE:"]) {
        [self addMessageSegments:text defaultRole:role];
    } else {
        [self.displayMessages addObject:@{@"role": role, @"text": text}];
        [self reloadAndScrollTable];
    }
}

/// Splits text containing [CODE:lang:path] / [CODE:lang]...[/CODE] markers
/// into alternating text + code entries in displayMessages.
- (void)addMessageSegments:(NSString *)text defaultRole:(NSString *)role {
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:
            @"\\[CODE:([^:]+):([^\\]]+)\\]|\\[CODE:([^\\]]+)\\]([\\s\\S]*?)\\[/CODE\\]"
                             options:0 error:nil];
    if (!re) {
        [self.displayMessages addObject:@{@"role": role, @"text": text}];
        [self reloadAndScrollTable]; return;
    }
    NSArray *matches = [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    NSInteger lastEnd = 0;
    for (NSTextCheckingResult *match in matches) {
        // Plain text before this code block
        NSRange before = NSMakeRange((NSUInteger)lastEnd,
                                     match.range.location - (NSUInteger)lastEnd);
        if (before.length > 0) {
            NSString *seg = [[text substringWithRange:before]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (seg.length) [self.displayMessages addObject:@{@"role": role, @"text": seg}];
        }
        // Code block
        NSRange r1=[match rangeAtIndex:1], r2=[match rangeAtIndex:2];
        NSRange r3=[match rangeAtIndex:3], r4=[match rangeAtIndex:4];
        NSString *lang=@"", *savedPath=nil, *code=nil;
        if (r1.location != NSNotFound) {
            lang = [text substringWithRange:r1];
            savedPath = [text substringWithRange:r2];
            code = [NSString stringWithContentsOfFile:savedPath
                                             encoding:NSUTF8StringEncoding error:nil];
        } else if (r3.location != NSNotFound) {
            lang = [text substringWithRange:r3];
            code = r4.location != NSNotFound ? [text substringWithRange:r4] : @"";
        }
        if (!code) code = @"(code unavailable)";
        NSMutableDictionary *entry = [@{@"role":@"code",
                                        @"text": code,
                                        @"language": lang.length ? lang : @"code"} mutableCopy];
        if (savedPath) entry[@"savedPath"] = savedPath;
        [self.displayMessages addObject:[entry copy]];
        lastEnd = (NSInteger)(match.range.location + match.range.length);
    }
    // Remaining text after last code block
    if ((NSUInteger)lastEnd < text.length) {
        NSString *tail = [[text substringFromIndex:(NSUInteger)lastEnd]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (tail.length) [self.displayMessages addObject:@{@"role": role, @"text": tail}];
    }
    [self reloadAndScrollTable];
}

- (void)reloadAndScrollTable {
    [self.chatTableView reloadData];
    [self scrollChatToBottom];
}

/// Legacy name kept so all existing call sites compile unchanged.
- (void)appendToOldChat:(NSString *)text { [self appendToChat:text]; }


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UITableViewDataSource / UITableViewDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.displayMessages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *msg = self.displayMessages[(NSUInteger)indexPath.row];
    NSString *role    = msg[@"role"] ?: @"system";

    if ([role isEqualToString:@"code"]) {
        EZCodeBlockCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZCodeBlock"
                                                                forIndexPath:indexPath];
        [cell configureWithCode:msg[@"text"]
                       language:msg[@"language"]
                      savedPath:msg[@"savedPath"]
                 viewController:self];
        return cell;
    } else if ([role isEqualToString:@"user"] || [role isEqualToString:@"assistant"]) {
        EZBubbleCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZBubble"
                                                             forIndexPath:indexPath];
        [cell configureWithText:msg[@"text"] ?: @""
                         isUser:[role isEqualToString:@"user"]];
        return cell;
    } else {
        EZSystemCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZSystem"
                                                             forIndexPath:indexPath];
        cell.messageLabel.text = msg[@"text"] ?: @"";
        return cell;
    }
}

// ── Present deferred Sora video once the view is on screen ──────────────────
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.pendingVideoURL) {
        NSURL *url           = self.pendingVideoURL;
        self.pendingVideoURL = nil;
        self.previewURL      = url;
        QLPreviewController *ql = [[QLPreviewController alloc] init];
        ql.dataSource = self;
        [self presentViewController:ql animated:YES completion:nil];
        EZLog(EZLogLevelInfo, @"SORA", @"Deferred Sora video presented on viewWillAppear");
    }
}

- (void)codeBlockCopyTapped:(UIButton *)sender {
    NSString *code = objc_getAssociatedObject(sender, "EZCodeContent");
    if (code) {
        [UIPasteboard generalPasteboard].string = code;
        NSString *original = [sender titleForState:UIControlStateNormal];
        [sender setTitle:@"✓ Copied!" forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [sender setTitle:original forState:UIControlStateNormal];
        });
        EZLog(EZLogLevelInfo, @"CODE", @"Code copied to clipboard");
    }
}

- (void)codeBlockFileTapped:(UIButton *)sender {
    NSString *path = objc_getAssociatedObject(sender, "EZCodePath");
    if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self offerToOpenLocalFile:path];
    }
}

- (void)scrollChatToBottom {
    NSUInteger count = self.displayMessages.count;
    if (count == 0) return;
    NSIndexPath *last = [NSIndexPath indexPathForRow:(NSInteger)(count - 1) inSection:0];
    [self.chatTableView scrollToRowAtIndexPath:last
                             atScrollPosition:UITableViewScrollPositionBottom
                                     animated:YES];
}

// appendToOldChat: implemented above as a wrapper around appendToChat:

- (void)openSettings {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[SettingsViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}


- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    @try {
        [self ezcui_endLongOperation];
    } @catch (NSException *e) {
        EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"viewWillDisappear end failed: %@", e);
    }
}


- (void)dealloc {
    @try {
        [self ezcui_endLongOperation];
    } @catch (NSException *e) {
        EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"dealloc end failed: %@", e);
    }
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

@end

    @interface ViewController (EZTitleFix) @end
    @implementation ViewController (EZTitleFix)
    - (void)setTitle:(NSString *)title {
        [super setTitle:title];
        // If the top-buttons category is present, let it sync its label.
        if ([self respondsToSelector:@selector(ezcui_setTopTitle:)]) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self performSelector:@selector(ezcui_setTopTitle:) withObject:(title ?: @"")];
    #pragma clang diagnostic pop
        }
    }
    @end
#pragma mark - EZKeepAwake

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "helpers.h"

static const void *kEZKA_Count  = &kEZKA_Count;
static const void *kEZKA_BGTask = &kEZKA_BGTask;
static const void *kEZKA_Timer  = &kEZKA_Timer;

static inline NSInteger ezka_getCount(id vc) {
    NSNumber *n = objc_getAssociatedObject(vc, kEZKA_Count);
    return n ? n.integerValue : 0;
}
static inline void ezka_setCount(id vc, NSInteger c) {
    objc_setAssociatedObject(vc, kEZKA_Count, @(c), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
#if TARGET_OS_IOS
static inline UIBackgroundTaskIdentifier ezka_getBG(id vc) {
    NSNumber *n = objc_getAssociatedObject(vc, kEZKA_BGTask);
    return n ? (UIBackgroundTaskIdentifier)n.unsignedIntegerValue : UIBackgroundTaskInvalid;
}
static inline void ezka_setBG(id vc, UIBackgroundTaskIdentifier t) {
    objc_setAssociatedObject(vc, kEZKA_BGTask, @(t), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
#endif

@interface ViewController (EZKeepAwakeInjected)
- (void)ezcui_beginLongOperation:(NSString *)reason;
- (void)ezcui_endLongOperation;
@end

@implementation ViewController (EZKeepAwakeInjected)

- (void)ezcui_beginLongOperation:(NSString *)reason {
    @synchronized (self) {
        NSInteger c = ezka_getCount(self) + 1;
        ezka_setCount(self, c);
#if TARGET_OS_IOS
        if (c == 1) {
            [UIApplication sharedApplication].idleTimerDisabled = YES;
            EZLogf(EZLogLevelInfo, @"EZKeepAwake", @"Starting keep-awake: %@", reason ?: @"op");

            UIBackgroundTaskIdentifier bg = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
                EZLog(EZLogLevelWarning, @"EZKeepAwake", @"BG task expired; ending");
                UIBackgroundTaskIdentifier cur = ezka_getBG(self);
                if (cur != UIBackgroundTaskInvalid) {
                    [[UIApplication sharedApplication] endBackgroundTask:cur];
                    ezka_setBG(self, UIBackgroundTaskInvalid);
                }
            }];
            ezka_setBG(self, bg);

            NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:480.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
                EZLog(EZLogLevelWarning, @"EZKeepAwake", @"Failsafe timer fired; forcing end");
                [self ezcui_endLongOperation];
            }];
            objc_setAssociatedObject(self, kEZKA_Timer, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
#endif
    }
}

- (void)ezcui_endLongOperation {
    @synchronized (self) {
        NSInteger c = MAX(0, ezka_getCount(self) - 1);
        ezka_setCount(self, c);
#if TARGET_OS_IOS
        if (c == 0) {
            [UIApplication sharedApplication].idleTimerDisabled = NO;
            EZLog(EZLogLevelInfo, @"EZKeepAwake", @"Idle timer re-enabled");

            NSTimer *t = objc_getAssociatedObject(self, kEZKA_Timer);
            if (t) { [t invalidate]; objc_setAssociatedObject(self, kEZKA_Timer, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }

            UIBackgroundTaskIdentifier bg = ezka_getBG(self);
            if (bg != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:bg];
                ezka_setBG(self, UIBackgroundTaskInvalid);
                EZLog(EZLogLevelInfo, @"EZKeepAwake", @"Background task ended");
            }
        }
#endif
    }
}

@end
