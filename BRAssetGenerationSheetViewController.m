// BRAssetGenerationSheetViewController.m
// BrainRotGame
// EZCompleteUI v1.0 — AI Asset Generate / Regenerate / Preview Sheet
//
// Purpose:
//   Implementation of BRAssetGenerationSheetViewController. See the header
//   for the public contract. Layout is: a Cancel-only header row, then a
//   scroll view containing the prompt field, a GENERATE/REGENERATE button,
//   an inline error label, a square preview (placeholder, image, or loading
//   spinner depending on state), and a "Use This Image" accept button that
//   only appears once a preview exists.

#import "BRAssetGenerationSheetViewController.h"

static const NSInteger kPromptCharacterLimit = 300;

@interface BRAssetGenerationSheetViewController () <UITextViewDelegate>

// Supplied at construction time.
@property (nonatomic, copy) NSString *assetDisplayName;
@property (nonatomic, copy) NSString *costDescription;
@property (nonatomic, copy, nullable) NSString *initialPrompt;
@property (nonatomic, copy) BRAssetGenerationHandler generateHandler;
@property (nonatomic, copy) void (^onAccept)(UIImage *image, NSString *prompt);

// State.
@property (nonatomic, strong, nullable) UIImage *currentImage;
@property (nonatomic, assign) BOOL isGenerating;

// Views referenced after construction.
@property (nonatomic, strong) UITextView *promptTextView;
@property (nonatomic, strong) UILabel *promptPlaceholderLabel;
@property (nonatomic, strong) UILabel *counterLabel;
@property (nonatomic, strong) UIButton *generateButton;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIView *previewContainer;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UIView *previewPlaceholder;
@property (nonatomic, strong) UIActivityIndicatorView *previewSpinner;
@property (nonatomic, strong) UIButton *acceptButton;

@end

@implementation BRAssetGenerationSheetViewController

#pragma mark - Factory

+ (instancetype)sheetForAssetDisplayName:(NSString *)displayName
                          costDescription:(NSString *)costDescription
                            initialPrompt:(nullable NSString *)initialPrompt
                             initialImage:(nullable UIImage *)initialImage
                          generateHandler:(BRAssetGenerationHandler)generateHandler
                                 onAccept:(void (^)(UIImage *image, NSString *prompt))onAccept {
    BRAssetGenerationSheetViewController *sheet = [[BRAssetGenerationSheetViewController alloc] init];
    sheet.assetDisplayName = displayName;
    sheet.costDescription = costDescription;
    sheet.initialPrompt = initialPrompt;
    sheet.currentImage = initialImage;
    sheet.generateHandler = generateHandler;
    sheet.onAccept = onAccept;
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    return sheet;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.03 blue:0.16 alpha:1.0];

    UIView *headerBottomAnchorView = [self buildHeaderRow];
    UIScrollView *scrollView = [self buildScrollViewBelow:headerBottomAnchorView];
    [self buildFormContentInScrollView:scrollView];

    self.promptTextView.text = self.initialPrompt ?: @"";
    [self updatePlaceholderVisibility];
    [self updateCharacterCounter];
    [self refreshPreviewAndButtons];

    [self configureSheetPresentationDetents];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.currentImage) {
        [self.promptTextView becomeFirstResponder];
    }
}

/// Configured here (not in viewDidAppear) so the sheet presents directly at
/// its final size — see BRTextInputSheetViewController for the full
/// explanation of why viewDidAppear causes a visible size jump.
- (void)configureSheetPresentationDetents {
    UISheetPresentationController *sheetController = self.sheetPresentationController;
    if (!sheetController) return;

    sheetController.prefersGrabberVisible = YES;
    sheetController.preferredCornerRadius = 24.0;
    sheetController.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
}

#pragma mark - Layout: Header

- (UIView *)buildHeaderRow {
    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
    cancelButton.tintColor = [UIColor systemGrayColor];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:17.0];
    [cancelButton addTarget:self action:@selector(handleCancelTapped) forControlEvents:UIControlEventTouchUpInside];

    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:cancelButton];

    [NSLayoutConstraint activateConstraints:@[
        [cancelButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16.0],
        [cancelButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
    ]];

    return cancelButton;
}

#pragma mark - Layout: Scroll View

- (UIScrollView *)buildScrollViewBelow:(UIView *)topAnchorView {
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:topAnchorView.bottomAnchor constant:16.0],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-12.0],
    ]];

    return scrollView;
}

#pragma mark - Layout: Form Content

- (void)buildFormContentInScrollView:(UIScrollView *)scrollView {
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

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.5;
    titleLabel.text = [NSString stringWithFormat:@"AI Prompt — %@", self.assetDisplayName];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:22.0];
    titleLabel.numberOfLines = 0;

    UILabel *costLabel = [[UILabel alloc] init];
    costLabel.adjustsFontSizeToFitWidth = YES;
    costLabel.minimumScaleFactor = 0.5;
    costLabel.text = self.costDescription;
    costLabel.textColor = [UIColor systemGrayColor];
    costLabel.font = [UIFont systemFontOfSize:14.0];
    costLabel.numberOfLines = 0;

    UIView *promptContainer = [self buildPromptFieldContainer];

    self.generateButton = [self buildPrimaryButtonWithTitle:@"GENERATE"];
    [self.generateButton addTarget:self action:@selector(handleGenerateTapped) forControlEvents:UIControlEventTouchUpInside];

    self.errorLabel = [[UILabel alloc] init];
    self.errorLabel.adjustsFontSizeToFitWidth = YES;
    self.errorLabel.minimumScaleFactor = 0.5;
    self.errorLabel.textColor = [UIColor systemRedColor];
    self.errorLabel.font = [UIFont systemFontOfSize:13.0];
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.hidden = YES;

    self.previewContainer = [self buildPreviewContainer];

    self.acceptButton = [self buildPrimaryButtonWithTitle:@"USE THIS IMAGE"];
    [self.acceptButton addTarget:self action:@selector(handleAcceptTapped) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *view in @[titleLabel, costLabel, promptContainer, self.generateButton, self.errorLabel, self.previewContainer, self.acceptButton]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [contentView addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:contentView.topAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20.0],

        [costLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6.0],
        [costLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [costLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],

        [promptContainer.topAnchor constraintEqualToAnchor:costLabel.bottomAnchor constant:18.0],
        [promptContainer.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20.0],
        [promptContainer.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20.0],

        [self.generateButton.topAnchor constraintEqualToAnchor:promptContainer.bottomAnchor constant:14.0],
        [self.generateButton.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20.0],
        [self.generateButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20.0],
        [self.generateButton.heightAnchor constraintEqualToConstant:50.0],

        [self.errorLabel.topAnchor constraintEqualToAnchor:self.generateButton.bottomAnchor constant:8.0],
        [self.errorLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20.0],
        [self.errorLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20.0],

        [self.previewContainer.topAnchor constraintEqualToAnchor:self.errorLabel.bottomAnchor constant:16.0],
        [self.previewContainer.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20.0],
        [self.previewContainer.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20.0],
        [self.previewContainer.heightAnchor constraintEqualToAnchor:self.previewContainer.widthAnchor],

        [self.acceptButton.topAnchor constraintEqualToAnchor:self.previewContainer.bottomAnchor constant:16.0],
        [self.acceptButton.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20.0],
        [self.acceptButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20.0],
        [self.acceptButton.heightAnchor constraintEqualToConstant:50.0],
        [self.acceptButton.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-24.0],
    ]];
}

/// Same visual treatment as BRTextInputSheetViewController's text field, but
/// built locally rather than shared since this sheet also needs to position
/// the preview/buttons around it.
- (UIView *)buildPromptFieldContainer {
    UIView *fieldContainer = [[UIView alloc] init];
    fieldContainer.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    fieldContainer.layer.cornerRadius = 12.0;
    fieldContainer.layer.borderWidth = 1.0;
    fieldContainer.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;

    self.promptTextView = [[UITextView alloc] init];
    self.promptTextView.backgroundColor = [UIColor clearColor];
    self.promptTextView.textColor = [UIColor whiteColor];
    self.promptTextView.font = [UIFont systemFontOfSize:16.0];
    self.promptTextView.tintColor = [UIColor systemYellowColor];
    self.promptTextView.delegate = self;
    self.promptTextView.textContainerInset = UIEdgeInsetsMake(12.0, 10.0, 12.0, 10.0);
    self.promptTextView.keyboardAppearance = UIKeyboardAppearanceDark;

    self.promptPlaceholderLabel = [[UILabel alloc] init];
    self.promptPlaceholderLabel.adjustsFontSizeToFitWidth = YES;
    self.promptPlaceholderLabel.minimumScaleFactor = 0.5;
    self.promptPlaceholderLabel.text = @"e.g., Cyberpunk character in red neon palette";
    self.promptPlaceholderLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    self.promptPlaceholderLabel.font = self.promptTextView.font;
    self.promptPlaceholderLabel.numberOfLines = 0;

    self.counterLabel = [[UILabel alloc] init];
    self.counterLabel.adjustsFontSizeToFitWidth = YES;
    self.counterLabel.minimumScaleFactor = 0.5;
    self.counterLabel.textColor = [UIColor systemGrayColor];
    self.counterLabel.font = [UIFont systemFontOfSize:12.0];
    self.counterLabel.textAlignment = NSTextAlignmentRight;

    for (UIView *view in @[fieldContainer, self.counterLabel]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
    }
    self.promptTextView.translatesAutoresizingMaskIntoConstraints = NO;
    self.promptPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [fieldContainer addSubview:self.promptTextView];
    [fieldContainer addSubview:self.promptPlaceholderLabel];

    // Wrap field + counter in a plain container so this method can return a
    // single view with a well-defined bottom edge for the caller's
    // constraints.
    UIView *wrapper = [[UIView alloc] init];
    wrapper.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:fieldContainer];
    [wrapper addSubview:self.counterLabel];

    [NSLayoutConstraint activateConstraints:@[
        [fieldContainer.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
        [fieldContainer.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
        [fieldContainer.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
        [fieldContainer.heightAnchor constraintEqualToConstant:140.0],

        [self.promptTextView.topAnchor constraintEqualToAnchor:fieldContainer.topAnchor],
        [self.promptTextView.leadingAnchor constraintEqualToAnchor:fieldContainer.leadingAnchor],
        [self.promptTextView.trailingAnchor constraintEqualToAnchor:fieldContainer.trailingAnchor],
        [self.promptTextView.bottomAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor],

        [self.promptPlaceholderLabel.topAnchor constraintEqualToAnchor:self.promptTextView.topAnchor constant:12.0],
        [self.promptPlaceholderLabel.leadingAnchor constraintEqualToAnchor:self.promptTextView.leadingAnchor constant:14.0],
        [self.promptPlaceholderLabel.trailingAnchor constraintEqualToAnchor:self.promptTextView.trailingAnchor constant:-14.0],

        [self.counterLabel.topAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor constant:4.0],
        [self.counterLabel.trailingAnchor constraintEqualToAnchor:fieldContainer.trailingAnchor],
        [self.counterLabel.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
    ]];

    return wrapper;
}

/// Square area that shows one of: a centered placeholder ("No preview yet"),
/// the current preview image, or a loading spinner — never more than one at
/// a time, toggled by refreshPreviewAndButtons.
- (UIView *)buildPreviewContainer {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
    container.layer.cornerRadius = 12.0;
    container.layer.borderWidth = 1.0;
    container.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    container.clipsToBounds = YES;

    self.previewImageView = [[UIImageView alloc] init];
    self.previewImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.previewImageView.clipsToBounds = YES;

    self.previewPlaceholder = [[UIView alloc] init];
    UIImageView *placeholderIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"photo"]];
    placeholderIcon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    placeholderIcon.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *placeholderLabel = [[UILabel alloc] init];
    placeholderLabel.adjustsFontSizeToFitWidth = YES;
    placeholderLabel.minimumScaleFactor = 0.5;
    placeholderLabel.text = @"No preview yet";
    placeholderLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    placeholderLabel.font = [UIFont systemFontOfSize:14.0];

    UIStackView *placeholderStack = [[UIStackView alloc] initWithArrangedSubviews:@[placeholderIcon, placeholderLabel]];
    placeholderStack.axis = UILayoutConstraintAxisVertical;
    placeholderStack.alignment = UIStackViewAlignmentCenter;
    placeholderStack.spacing = 8.0;
    placeholderStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.previewPlaceholder addSubview:placeholderStack];

    self.previewSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.previewSpinner.color = [UIColor systemYellowColor];
    self.previewSpinner.hidesWhenStopped = YES;

    for (UIView *view in @[self.previewImageView, self.previewPlaceholder, self.previewSpinner]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:view];
    }
    placeholderIcon.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        [self.previewImageView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [self.previewImageView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [self.previewImageView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.previewImageView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [placeholderIcon.widthAnchor constraintEqualToConstant:36.0],
        [placeholderIcon.heightAnchor constraintEqualToConstant:36.0],
        [placeholderStack.centerXAnchor constraintEqualToAnchor:self.previewPlaceholder.centerXAnchor],
        [placeholderStack.centerYAnchor constraintEqualToAnchor:self.previewPlaceholder.centerYAnchor],
        [self.previewPlaceholder.topAnchor constraintEqualToAnchor:container.topAnchor],
        [self.previewPlaceholder.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [self.previewPlaceholder.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.previewPlaceholder.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [self.previewSpinner.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [self.previewSpinner.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
    ]];

    return container;
}

- (UIButton *)buildPrimaryButtonWithTitle:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];
    button.tintColor = [UIColor colorWithRed:0.04 green:0.0 blue:0.12 alpha:1.0];
    button.backgroundColor = [UIColor systemYellowColor];
    button.layer.cornerRadius = 12.0;
    return button;
}

#pragma mark - UITextViewDelegate

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    NSInteger prospectiveLength = textView.text.length - range.length + text.length;
    return prospectiveLength <= kPromptCharacterLimit;
}

- (void)textViewDidChange:(UITextView *)textView {
    [self updatePlaceholderVisibility];
    [self updateCharacterCounter];
}

#pragma mark - Helpers

- (void)updatePlaceholderVisibility {
    self.promptPlaceholderLabel.hidden = (self.promptTextView.text.length > 0);
}

- (void)updateCharacterCounter {
    NSInteger currentLength = self.promptTextView.text.length;
    self.counterLabel.text = [NSString stringWithFormat:@"%ld / %ld", (long)currentLength, (long)kPromptCharacterLimit];
    self.counterLabel.textColor = (currentLength >= kPromptCharacterLimit) ? [UIColor systemOrangeColor] : [UIColor systemGrayColor];
}

/// Shows exactly one of {placeholder, image, spinner} in the preview area,
/// updates the Generate/Regenerate title, and shows/hides "Use This Image".
- (void)refreshPreviewAndButtons {
    BOOL hasImage = (self.currentImage != nil);

    self.previewImageView.image = self.currentImage;
    self.previewImageView.hidden = !hasImage || self.isGenerating;
    self.previewPlaceholder.hidden = hasImage || self.isGenerating;

    if (self.isGenerating) {
        [self.previewSpinner startAnimating];
    } else {
        [self.previewSpinner stopAnimating];
    }

    self.acceptButton.hidden = !hasImage;
    [self.generateButton setTitle:(hasImage ? @"REGENERATE" : @"GENERATE") forState:UIControlStateNormal];
}

- (void)setGenerating:(BOOL)generating {
    self.isGenerating = generating;
    self.generateButton.enabled = !generating;
    self.generateButton.alpha = generating ? 0.5 : 1.0;
    self.acceptButton.enabled = !generating;
    self.promptTextView.editable = !generating;
    [self refreshPreviewAndButtons];
}

#pragma mark - Actions

- (void)handleCancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleGenerateTapped {
    NSString *prompt = [self.promptTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (prompt.length == 0) {
        self.errorLabel.text = @"Enter a prompt before generating.";
        self.errorLabel.hidden = NO;
        return;
    }

    self.errorLabel.hidden = YES;
    [self setGenerating:YES];

    __weak typeof(self) weakSelf = self;
    self.generateHandler(prompt, ^(UIImage * _Nullable image, NSString * _Nullable errorMessage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleGenerationFinishedWithImage:image errorMessage:errorMessage];
        });
    });
}

- (void)handleGenerationFinishedWithImage:(nullable UIImage *)image errorMessage:(nullable NSString *)errorMessage {
    [self setGenerating:NO];

    if (image) {
        self.currentImage = image;
        [self refreshPreviewAndButtons];
        return;
    }

    self.errorLabel.text = errorMessage ?: @"Generation failed. Please try again.";
    self.errorLabel.hidden = NO;
}

- (void)handleAcceptTapped {
    if (!self.currentImage) return;

    NSString *prompt = [self.promptTextView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    UIImage *image = self.currentImage;

    __weak typeof(self) weakSelf = self;
    [self dismissViewControllerAnimated:YES completion:^{
        if (weakSelf.onAccept) {
            weakSelf.onAccept(image, prompt);
        }
    }];
}

@end
