// BRTextInputSheetViewController.m
// BrainRotGame
// EZCompleteUI v1.0 — Reusable Text Input Bottom Sheet
//
// Purpose:
//   Implementation of BRTextInputSheetViewController. See the header for
//   the public contract. Internally this is a small form: a fixed
//   Cancel/Save header row, then a scroll view (so long premises remain
//   reachable when the keyboard is up) containing a title, optional
//   subtitle, the text field itself, and an optional character counter.

#import "BRTextInputSheetViewController.h"

@interface BRTextInputSheetViewController () <UITextViewDelegate>

@property (nonatomic, copy) NSString *sheetTitle;
@property (nonatomic, copy, nullable) NSString *sheetSubtitle;
@property (nonatomic, copy, nullable) NSString *initialText;
@property (nonatomic, copy, nullable) NSString *placeholderText;
@property (nonatomic, assign) BOOL isMultiline;
@property (nonatomic, assign) NSInteger characterLimit;
@property (nonatomic, copy) BRTextInputSheetCompletion completion;

@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *placeholderLabel;
@property (nonatomic, strong) UILabel *counterLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;

/// Tracks whether the sheet has already reported its result, so a swipe-to-
/// dismiss after a tap on Save/Cancel can't fire the completion block twice.
@property (nonatomic, assign) BOOL didReportResult;

@end

@implementation BRTextInputSheetViewController

#pragma mark - Factory

+ (instancetype)sheetWithTitle:(NSString *)title
                       subtitle:(nullable NSString *)subtitle
                    initialText:(nullable NSString *)initialText
                    placeholder:(nullable NSString *)placeholder
                      multiline:(BOOL)multiline
                 characterLimit:(NSInteger)characterLimit
                     completion:(BRTextInputSheetCompletion)completion {
    BRTextInputSheetViewController *sheet = [[BRTextInputSheetViewController alloc] init];
    sheet.sheetTitle = title;
    sheet.sheetSubtitle = subtitle;
    sheet.initialText = initialText;
    sheet.placeholderText = placeholder;
    sheet.isMultiline = multiline;
    sheet.characterLimit = characterLimit;
    sheet.completion = completion;
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

    self.textView.text = self.initialText ?: @"";
    [self updatePlaceholderVisibility];
    [self updateCharacterCounter];

    // Configured here (not in viewDidAppear): the sheet presentation
    // controller already exists by viewDidLoad, and setting the detents
    // here means the sheet presents directly at its final size instead of
    // animating in at the default (large) detent and then snapping down.
    [self configureSheetPresentationDetents];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.textView becomeFirstResponder];
}

/// If the player dismisses by swiping the sheet away instead of tapping a
/// button, this still fires so the caller's completion handler always runs.
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self reportResult:BRTextInputSheetResultCancelled text:nil];
}

#pragma mark - Layout

- (void)configureSheetPresentationDetents {
    UISheetPresentationController *sheetController = self.sheetPresentationController;
    if (!sheetController) return;

    sheetController.prefersGrabberVisible = YES;
    sheetController.preferredCornerRadius = 24.0;
    if (self.isMultiline) {
        sheetController.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
    } else {
        sheetController.detents = @[[UISheetPresentationControllerDetent mediumDetent]];
    }
}

/// Builds the fixed Cancel / Save row pinned to the safe area. Returns the
/// view whose bottom edge subsequent content should anchor below.
- (UIView *)buildHeaderRow {
    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancelButton setTitle:@"Cancel" forState:UIControlStateNormal];
    cancelButton.tintColor = [UIColor systemGrayColor];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:17.0];
    [cancelButton addTarget:self action:@selector(handleCancelTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [saveButton setTitle:@"Save" forState:UIControlStateNormal];
    saveButton.tintColor = [UIColor systemYellowColor];
    saveButton.titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
    [saveButton addTarget:self action:@selector(handleSaveTapped) forControlEvents:UIControlEventTouchUpInside];

    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    saveButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:cancelButton];
    [self.view addSubview:saveButton];

    [NSLayoutConstraint activateConstraints:@[
        [cancelButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16.0],
        [cancelButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [saveButton.topAnchor constraintEqualToAnchor:cancelButton.topAnchor],
        [saveButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20.0],
    ]];

    return cancelButton;
}

/// Builds the scroll view that holds the form content. Its bottom edge is
/// pinned to the keyboard layout guide so the field and counter remain
/// visible once the keyboard appears, even on smaller screens.
- (UIScrollView *)buildScrollViewBelow:(UIView *)topAnchorView {
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = NO;
    scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:topAnchorView.bottomAnchor constant:20.0],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-12.0],
    ]];

    return scrollView;
}

/// Populates the scroll view with the title, subtitle, text field, and
/// character counter, all pinned edge-to-edge so the scroll view's content
/// size resolves correctly.
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
    titleLabel.text = self.sheetTitle;
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:22.0];
    titleLabel.numberOfLines = 0;

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.adjustsFontSizeToFitWidth = YES;
    subtitleLabel.minimumScaleFactor = 0.5;
    subtitleLabel.text = self.sheetSubtitle;
    subtitleLabel.textColor = [UIColor systemGrayColor];
    subtitleLabel.font = [UIFont systemFontOfSize:14.0];
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.hidden = (self.sheetSubtitle.length == 0);
    self.subtitleLabel = subtitleLabel;

    UIView *fieldContainer = [[UIView alloc] init];
    fieldContainer.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    fieldContainer.layer.cornerRadius = 12.0;
    fieldContainer.layer.borderWidth = 1.0;
    fieldContainer.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;

    self.textView = [[UITextView alloc] init];
    self.textView.backgroundColor = [UIColor clearColor];
    self.textView.textColor = [UIColor whiteColor];
    self.textView.font = [UIFont systemFontOfSize:16.0];
    self.textView.tintColor = [UIColor systemYellowColor];
    self.textView.delegate = self;
    self.textView.textContainerInset = UIEdgeInsetsMake(12.0, 10.0, 12.0, 10.0);
    self.textView.keyboardAppearance = UIKeyboardAppearanceDark;
    self.textView.returnKeyType = self.isMultiline ? UIReturnKeyDefault : UIReturnKeyDone;

    self.placeholderLabel = [[UILabel alloc] init];
    self.placeholderLabel.adjustsFontSizeToFitWidth = YES;
    self.placeholderLabel.minimumScaleFactor = 0.5;
    self.placeholderLabel.text = self.placeholderText;
    self.placeholderLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    self.placeholderLabel.font = self.textView.font;
    self.placeholderLabel.numberOfLines = 0;

    self.counterLabel = [[UILabel alloc] init];
    self.counterLabel.adjustsFontSizeToFitWidth = YES;
    self.counterLabel.minimumScaleFactor = 0.5;
    self.counterLabel.textColor = [UIColor systemGrayColor];
    self.counterLabel.font = [UIFont systemFontOfSize:12.0];
    self.counterLabel.textAlignment = NSTextAlignmentRight;
    self.counterLabel.hidden = (self.characterLimit <= 0);

    for (UIView *view in @[titleLabel, subtitleLabel, fieldContainer, self.counterLabel]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [contentView addSubview:view];
    }
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [fieldContainer addSubview:self.textView];
    [fieldContainer addSubview:self.placeholderLabel];

    CGFloat fieldHeight = self.isMultiline ? 180.0 : 50.0;

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:contentView.topAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20.0],

        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],

        [fieldContainer.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:18.0],
        [fieldContainer.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:20.0],
        [fieldContainer.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-20.0],
        [fieldContainer.heightAnchor constraintEqualToConstant:fieldHeight],

        [self.textView.topAnchor constraintEqualToAnchor:fieldContainer.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:fieldContainer.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:fieldContainer.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor],

        [self.placeholderLabel.topAnchor constraintEqualToAnchor:self.textView.topAnchor constant:12.0],
        [self.placeholderLabel.leadingAnchor constraintEqualToAnchor:self.textView.leadingAnchor constant:14.0],
        [self.placeholderLabel.trailingAnchor constraintEqualToAnchor:self.textView.trailingAnchor constant:-14.0],

        [self.counterLabel.topAnchor constraintEqualToAnchor:fieldContainer.bottomAnchor constant:6.0],
        [self.counterLabel.trailingAnchor constraintEqualToAnchor:fieldContainer.trailingAnchor],
        [self.counterLabel.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-24.0],
    ]];
}

#pragma mark - UITextViewDelegate

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    // In single-line mode, Return submits the sheet instead of inserting a newline.
    if (!self.isMultiline && [text isEqualToString:@"\n"]) {
        [self handleSaveTapped];
        return NO;
    }

    // Enforce the character limit (deletions/replacements that shorten the
    // text are always allowed; only growth beyond the limit is blocked).
    if (self.characterLimit > 0) {
        NSInteger prospectiveLength = textView.text.length - range.length + text.length;
        if (prospectiveLength > self.characterLimit) {
            return NO;
        }
    }

    return YES;
}

- (void)textViewDidChange:(UITextView *)textView {
    [self updatePlaceholderVisibility];
    [self updateCharacterCounter];
}

#pragma mark - Helpers

- (void)updatePlaceholderVisibility {
    self.placeholderLabel.hidden = (self.textView.text.length > 0);
}

- (void)updateCharacterCounter {
    if (self.characterLimit <= 0) return;

    NSInteger currentLength = self.textView.text.length;
    self.counterLabel.text = [NSString stringWithFormat:@"%ld / %ld", (long)currentLength, (long)self.characterLimit];

    BOOL nearLimit = (currentLength >= self.characterLimit);
    self.counterLabel.textColor = nearLimit ? [UIColor systemOrangeColor] : [UIColor systemGrayColor];
}

#pragma mark - Actions

- (void)handleCancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)handleSaveTapped {
    NSString *trimmed = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self reportResult:BRTextInputSheetResultSaved text:trimmed];
    [self dismissViewControllerAnimated:YES completion:nil];
}

/// Funnels every dismissal path (Cancel, Save, or swipe-to-dismiss) through
/// one place so `completion` always fires exactly once.
- (void)reportResult:(BRTextInputSheetResult)result text:(nullable NSString *)text {
    if (self.didReportResult) return;
    self.didReportResult = YES;

    if (self.completion) {
        self.completion(result, text);
    }
}

@end
