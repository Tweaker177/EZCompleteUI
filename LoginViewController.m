// LoginViewController.m
// EZCompleteUI
//
// Purpose:
//   Presents the sign-in / sign-up screen and handles the full authentication
//   flow: input validation, calling EZAuthManager, showing contextual errors,
//   handling email confirmation state after sign-up, and navigating into the app
//   on successful authentication. Also provides forgot-password via EZAuthManager,
//   and hosts the set-new-password overlay that appears when a password reset
//   deep link is received.
//
// Changes:
//   - Removed EZFriendlyAuthError() — it was dead code. EZAuthManager maps all
//     Supabase error codes to friendly strings internally before calling completions,
//     so this duplicate function was never actually reached.
//   - Added password visibility toggle button (eye icon) inside the password field.
//     Preserves entered text on toggle to work around the iOS quirk that clears
//     secure text fields when secureTextEntry is toggled.
//   - Added "Forgot Password?" button wired to sendPasswordResetEmail: in EZAuthManager.
//   - Fixed sign-up password minimum: was checking 6 chars (the sign-in hint minimum),
//     corrected to 8 chars to match Supabase's default minimum requirement.
//   - Fixed sign-up success: previously always called proceedToApp even when email
//     confirmation was required and no session token was issued. Now checks isLoggedIn
//     and shows a "check your email" confirmation state when appropriate.
//   - showError: extended to showMessage:isError: to support green informational
//     messages (e.g., "reset email sent") using the same label.
//   - Added UITextFieldDelegate: Return key on email jumps to password field;
//     Return on password triggers the sign-in/sign-up action.
//   - kLastAuthDateKey and its NSUserDefaults write removed — EZAuthManager.saveSession:
//     now owns that timestamp and updates it on every session save, not just manual logins.
//   - Added password reset overlay: a full-screen view that slides in when
//     EZPasswordResetReadyNotification is received (or when isInPasswordRecoveryMode
//     is already YES at viewDidLoad time — handles the case where AppDelegate created
//     a fresh LoginViewController after receiving the deep link). Overlay contains
//     two secure text fields with visibility toggles, a "Set Password" button,
//     a cancel link, and its own scroll view for correct keyboard avoidance.
//     On success, clears recovery state and returns to sign-in with a confirmation.

#import "LoginViewController.h"
#import "EZAuthManager.h"
#import "ViewController.h"

// Defined in EZAuthManager.m, declared extern in EZAuthManager.h.
// Repeated here as a safeguard in case the header hasn't been updated yet.
extern NSString *const EZPasswordResetReadyNotification;

// NSUserDefaults key for pre-filling the email field on next launch
static NSString *const kLastEmailKey = @"EZLastSignedInEmail";

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Interface
// ─────────────────────────────────────────────────────────────────────────────

@interface LoginViewController () <UITextFieldDelegate>

// ── Main login UI ─────────────────────────────────────────────────────────────
@property (nonatomic, strong) UIScrollView              *scrollView;
@property (nonatomic, strong) UIView                    *containerView;
@property (nonatomic, strong) UILabel                   *titleLabel;
@property (nonatomic, strong) UILabel                   *subtitleLabel;
@property (nonatomic, strong) UITextField               *emailField;
@property (nonatomic, strong) UITextField               *passwordField;
@property (nonatomic, strong) UIButton                  *passwordVisibilityButton;
@property (nonatomic, strong) UIButton                  *loginButton;
@property (nonatomic, strong) UIButton                  *forgotPasswordButton;
@property (nonatomic, strong) UIButton                  *toggleModeButton;
@property (nonatomic, strong) UIActivityIndicatorView   *spinner;
@property (nonatomic, strong) UILabel                   *messageLabel;  // errors (red) and info (green)
@property (nonatomic, strong) UILabel                   *savedAccountLabel;
@property (nonatomic, strong) UILabel                   *buildLabel;
@property (nonatomic, assign) BOOL                       isSignUpMode;

// ── Password reset overlay ────────────────────────────────────────────────────
// Shown when a password reset deep link is received. Covers the full screen.
// Lazily created by setupPasswordResetOverlay on first use.
@property (nonatomic, strong) UIView                    *passwordResetOverlayView;
@property (nonatomic, strong) UIScrollView              *passwordResetScrollView;
@property (nonatomic, strong) UITextField               *resetPasswordField;
@property (nonatomic, strong) UIButton                  *resetPasswordVisibilityButton;
@property (nonatomic, strong) UITextField               *confirmPasswordField;
@property (nonatomic, strong) UIButton                  *confirmPasswordVisibilityButton;
@property (nonatomic, strong) UIButton                  *setPasswordButton;
@property (nonatomic, strong) UIButton                  *cancelResetButton;
@property (nonatomic, strong) UILabel                   *resetMessageLabel;
@property (nonatomic, strong) UIActivityIndicatorView   *resetSpinner;

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation LoginViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self setupUI];
    [self prefillSavedEmail];
    [self registerForKeyboardNotifications];

    // Observe the notification for when AppDelegate receives the password reset
    // deep link while this LoginViewController is already the root view controller.
    // (The other case — where a fresh LoginVC is created by AppDelegate after the
    // deep link fires — is handled by the isInPasswordRecoveryMode check below.)
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(handlePasswordResetReady)
               name:EZPasswordResetReadyNotification
             object:nil];

    // If AppDelegate already applied recovery tokens before creating this
    // LoginViewController (e.g. user was in the main app, tapped the reset link),
    // the notification already fired before we registered for it. Check directly.
    if ([[EZAuthManager shared] isInPasswordRecoveryMode]) {
        [self showPasswordResetEntryState];
    }
}

#pragma mark - Pre-fill

- (void)prefillSavedEmail {
    NSString *savedEmail = [[NSUserDefaults standardUserDefaults] stringForKey:kLastEmailKey];
    if (!savedEmail.length) return;

    self.savedAccountLabel.text = [NSString stringWithFormat:@"Last signed in as %@", savedEmail];
    self.savedAccountLabel.hidden = NO;
    self.emailField.text = savedEmail;

    // Indicate a password exists without pre-filling it (security best practice)
    NSAttributedString *passwordHint = [[NSAttributedString alloc]
        initWithString:@"••••••••"
            attributes:@{
                NSForegroundColorAttributeName: [UIColor tertiaryLabelColor],
                NSFontAttributeName:            [UIFont systemFontOfSize:17],
            }];
    self.passwordField.attributedPlaceholder = passwordHint;
}

#pragma mark - UI Construction

- (void)setupUI {
    // Scroll view (handles keyboard avoidance)
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];

    self.containerView = [[UIView alloc] init];
    self.containerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.containerView];

    // Title
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"EZCompleteUI";
    self.titleLabel.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Subtitle (changes based on mode)
    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.text = @"Sign in to continue";
    self.subtitleLabel.font = [UIFont systemFontOfSize:16];
    self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.subtitleLabel.numberOfLines = 0;
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Last-used account hint
    self.savedAccountLabel = [[UILabel alloc] init];
    self.savedAccountLabel.font = [UIFont systemFontOfSize:12];
    self.savedAccountLabel.textColor = [UIColor secondaryLabelColor];
    self.savedAccountLabel.textAlignment = NSTextAlignmentCenter;
    self.savedAccountLabel.hidden = YES;
    self.savedAccountLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // A quiet footer helps identify exactly which installed build someone is
    // reporting without competing with the sign-in controls.
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: version;
    NSString *buildText = version.length
        ? [NSString stringWithFormat:@"v%@ · build %@", version, build]
        : [NSString stringWithFormat:@"build %@", build];
#if DEBUG
    buildText = [buildText stringByAppendingString:@" · debug"];
#endif
    self.buildLabel = [[UILabel alloc] init];
    self.buildLabel.text = buildText;
    self.buildLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.buildLabel.textColor = [UIColor tertiaryLabelColor];
    self.buildLabel.textAlignment = NSTextAlignmentCenter;
    self.buildLabel.alpha = 0.82;
    self.buildLabel.accessibilityLabel = [NSString stringWithFormat:@"App build %@", buildText];
    self.buildLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Email field
    self.emailField = [self makeTextField:@"Email" secure:NO];
    self.emailField.keyboardType = UIKeyboardTypeEmailAddress;
    self.emailField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.emailField.returnKeyType = UIReturnKeyNext;
    self.emailField.delegate = self;

    // Password field (with visibility toggle on the right)
    self.passwordField = [self makeTextField:@"Password" secure:YES];
    self.passwordField.returnKeyType = UIReturnKeyGo;
    self.passwordField.delegate = self;

    // Eye button lives inside the password field's right view
    self.passwordVisibilityButton = [self makePasswordVisibilityButton];
    [self.passwordVisibilityButton addTarget:self
                                      action:@selector(togglePasswordVisibility)
                            forControlEvents:UIControlEventTouchUpInside];
    self.passwordField.rightView = self.passwordVisibilityButton;
    self.passwordField.rightViewMode = UITextFieldViewModeAlways;

    // Message label — red for errors, green for info (password reset sent, etc.)
    self.messageLabel = [[UILabel alloc] init];
    self.messageLabel.textColor = [UIColor systemRedColor];
    self.messageLabel.font = [UIFont systemFontOfSize:13];
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.hidden = YES;
    self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Forgot password — shown only in sign-in mode
    self.forgotPasswordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.forgotPasswordButton setTitle:@"Forgot Password?" forState:UIControlStateNormal];
    self.forgotPasswordButton.titleLabel.font = [UIFont systemFontOfSize:13];
    self.forgotPasswordButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.forgotPasswordButton addTarget:self
                                  action:@selector(handleForgotPassword)
                        forControlEvents:UIControlEventTouchUpInside];

    // Primary action button
    self.loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.loginButton setTitle:@"Sign In" forState:UIControlStateNormal];
    self.loginButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.loginButton.backgroundColor = [UIColor systemBlueColor];
    [self.loginButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.loginButton.layer.cornerRadius = 12;
    self.loginButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.loginButton addTarget:self
                         action:@selector(handleLogin)
               forControlEvents:UIControlEventTouchUpInside];

    // Sign in ↔ sign up toggle
    self.toggleModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.toggleModeButton setTitle:@"Don't have an account? Sign Up"
                           forState:UIControlStateNormal];
    self.toggleModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.toggleModeButton addTarget:self
                              action:@selector(toggleMode)
                    forControlEvents:UIControlEventTouchUpInside];

    // Activity spinner (centered below toggle)
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidesWhenStopped = YES;

    for (UIView *subview in @[
        self.titleLabel, self.subtitleLabel, self.savedAccountLabel,
        self.emailField, self.passwordField, self.messageLabel,
        self.forgotPasswordButton, self.loginButton,
        self.toggleModeButton, self.spinner, self.buildLabel
    ]) {
        [self.containerView addSubview:subview];
    }

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor      constraintEqualToAnchor:safeArea.topAnchor],
        [self.scrollView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],

        [self.containerView.topAnchor      constraintEqualToAnchor:self.scrollView.topAnchor],
        [self.containerView.leadingAnchor  constraintEqualToAnchor:self.scrollView.leadingAnchor],
        [self.containerView.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor],
        [self.containerView.bottomAnchor   constraintEqualToAnchor:self.scrollView.bottomAnchor],
        [self.containerView.widthAnchor    constraintEqualToAnchor:self.scrollView.widthAnchor],

        [self.titleLabel.topAnchor      constraintEqualToAnchor:self.containerView.topAnchor constant:80],
        [self.titleLabel.leadingAnchor  constraintEqualToAnchor:self.containerView.leadingAnchor constant:32],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-32],

        [self.subtitleLabel.topAnchor      constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8],
        [self.subtitleLabel.leadingAnchor  constraintEqualToAnchor:self.containerView.leadingAnchor constant:32],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-32],

        [self.savedAccountLabel.topAnchor      constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:6],
        [self.savedAccountLabel.leadingAnchor  constraintEqualToAnchor:self.containerView.leadingAnchor constant:32],
        [self.savedAccountLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-32],

        [self.emailField.topAnchor      constraintEqualToAnchor:self.savedAccountLabel.bottomAnchor constant:32],
        [self.emailField.leadingAnchor  constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
        [self.emailField.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],
        [self.emailField.heightAnchor   constraintEqualToConstant:52],

        [self.passwordField.topAnchor      constraintEqualToAnchor:self.emailField.bottomAnchor constant:12],
        [self.passwordField.leadingAnchor  constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
        [self.passwordField.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],
        [self.passwordField.heightAnchor   constraintEqualToConstant:52],

        [self.forgotPasswordButton.topAnchor      constraintEqualToAnchor:self.passwordField.bottomAnchor constant:6],
        [self.forgotPasswordButton.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],

        [self.messageLabel.topAnchor      constraintEqualToAnchor:self.forgotPasswordButton.bottomAnchor constant:8],
        [self.messageLabel.leadingAnchor  constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
        [self.messageLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],

        [self.loginButton.topAnchor      constraintEqualToAnchor:self.messageLabel.bottomAnchor constant:20],
        [self.loginButton.leadingAnchor  constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
        [self.loginButton.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],
        [self.loginButton.heightAnchor   constraintEqualToConstant:52],

        [self.toggleModeButton.topAnchor     constraintEqualToAnchor:self.loginButton.bottomAnchor constant:16],
        [self.toggleModeButton.centerXAnchor constraintEqualToAnchor:self.containerView.centerXAnchor],

        [self.spinner.topAnchor     constraintEqualToAnchor:self.toggleModeButton.bottomAnchor constant:16],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.containerView.centerXAnchor],

        [self.buildLabel.topAnchor      constraintEqualToAnchor:self.spinner.bottomAnchor constant:7],
        [self.buildLabel.leadingAnchor  constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
        [self.buildLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],
        [self.buildLabel.bottomAnchor   constraintEqualToAnchor:self.containerView.bottomAnchor constant:-16],
    ]];
}

// ── Password reset overlay construction ──────────────────────────────────────
// Called lazily from showPasswordResetEntryState. Builds a full-screen overlay
// with its own scroll view (so keyboard avoidance works the same as the main UI)
// containing two secure text fields and action buttons styled to match the
// existing login form.

- (void)setupPasswordResetOverlay {
    if (self.passwordResetOverlayView) return; // Already built

    // Full-screen cover — starts invisible and animates in
    UIView *overlayView = [[UIView alloc] init];
    overlayView.backgroundColor = [UIColor systemBackgroundColor];
    overlayView.translatesAutoresizingMaskIntoConstraints = NO;
    overlayView.alpha = 0;
    [self.view addSubview:overlayView];
    self.passwordResetOverlayView = overlayView;

    // Scroll view inside overlay so fields scroll above keyboard
    UIScrollView *overlayScrollView = [[UIScrollView alloc] init];
    overlayScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [overlayView addSubview:overlayScrollView];
    self.passwordResetScrollView = overlayScrollView;

    // Content container inside scroll view — must match scroll view width
    UIView *contentView = [[UIView alloc] init];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [overlayScrollView addSubview:contentView];

    // Title
    UILabel *resetTitle = [[UILabel alloc] init];
    resetTitle.text = @"EZCompleteUI";
    resetTitle.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    resetTitle.textAlignment = NSTextAlignmentCenter;
    resetTitle.translatesAutoresizingMaskIntoConstraints = NO;

    // Subtitle
    UILabel *resetSubtitle = [[UILabel alloc] init];
    resetSubtitle.text = @"Choose a new password for your account";
    resetSubtitle.font = [UIFont systemFontOfSize:16];
    resetSubtitle.textColor = [UIColor secondaryLabelColor];
    resetSubtitle.textAlignment = NSTextAlignmentCenter;
    resetSubtitle.numberOfLines = 0;
    resetSubtitle.translatesAutoresizingMaskIntoConstraints = NO;

    // New password field with visibility toggle
    self.resetPasswordField = [self makeTextField:@"New Password" secure:YES];
    self.resetPasswordField.returnKeyType = UIReturnKeyNext;
    self.resetPasswordField.delegate = self;

    self.resetPasswordVisibilityButton = [self makePasswordVisibilityButton];
    [self.resetPasswordVisibilityButton addTarget:self
                                         action:@selector(toggleNewPasswordVisibility)
                               forControlEvents:UIControlEventTouchUpInside];
    self.resetPasswordField.rightView = self.resetPasswordVisibilityButton;
    self.resetPasswordField.rightViewMode = UITextFieldViewModeAlways;

    // Confirm password field with visibility toggle
    self.confirmPasswordField = [self makeTextField:@"Confirm New Password" secure:YES];
    self.confirmPasswordField.returnKeyType = UIReturnKeyGo;
    self.confirmPasswordField.delegate = self;

    self.confirmPasswordVisibilityButton = [self makePasswordVisibilityButton];
    [self.confirmPasswordVisibilityButton addTarget:self
                                              action:@selector(toggleConfirmPasswordVisibility)
                                    forControlEvents:UIControlEventTouchUpInside];
    self.confirmPasswordField.rightView = self.confirmPasswordVisibilityButton;
    self.confirmPasswordField.rightViewMode = UITextFieldViewModeAlways;

    // Error/info message label for the reset flow
    self.resetMessageLabel = [[UILabel alloc] init];
    self.resetMessageLabel.font = [UIFont systemFontOfSize:13];
    self.resetMessageLabel.textAlignment = NSTextAlignmentCenter;
    self.resetMessageLabel.numberOfLines = 0;
    self.resetMessageLabel.hidden = YES;
    self.resetMessageLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Primary action button — styled identically to the main loginButton
    self.setPasswordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.setPasswordButton setTitle:@"Set New Password" forState:UIControlStateNormal];
    self.setPasswordButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.setPasswordButton.backgroundColor = [UIColor systemBlueColor];
    [self.setPasswordButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.setPasswordButton.layer.cornerRadius = 12;
    self.setPasswordButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.setPasswordButton addTarget:self
                               action:@selector(handleSetPasswordSubmit)
                     forControlEvents:UIControlEventTouchUpInside];

    // Cancel — plain text link below the button
    self.cancelResetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cancelResetButton setTitle:@"Cancel" forState:UIControlStateNormal];
    self.cancelResetButton.titleLabel.font = [UIFont systemFontOfSize:15];
    self.cancelResetButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cancelResetButton addTarget:self
                               action:@selector(handleCancelPasswordReset)
                     forControlEvents:UIControlEventTouchUpInside];

    // Activity spinner
    self.resetSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.resetSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.resetSpinner.hidesWhenStopped = YES;

    for (UIView *subview in @[
        resetTitle, resetSubtitle,
        self.resetPasswordField, self.confirmPasswordField,
        self.resetMessageLabel, self.setPasswordButton,
        self.cancelResetButton, self.resetSpinner
    ]) {
        [contentView addSubview:subview];
    }

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        // Overlay covers the whole screen (over the safe area insets too, for
        // correct background fill on notched devices)
        [overlayView.topAnchor      constraintEqualToAnchor:self.view.topAnchor],
        [overlayView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [overlayView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [overlayView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],

        // Scroll view respects safe area so content isn't hidden under status bar / home indicator
        [overlayScrollView.topAnchor      constraintEqualToAnchor:safeArea.topAnchor],
        [overlayScrollView.leadingAnchor  constraintEqualToAnchor:overlayView.leadingAnchor],
        [overlayScrollView.trailingAnchor constraintEqualToAnchor:overlayView.trailingAnchor],
        [overlayScrollView.bottomAnchor   constraintEqualToAnchor:overlayView.bottomAnchor],

        // Content view fills scroll view width so fields don't wrap oddly
        [contentView.topAnchor      constraintEqualToAnchor:overlayScrollView.topAnchor],
        [contentView.leadingAnchor  constraintEqualToAnchor:overlayScrollView.leadingAnchor],
        [contentView.trailingAnchor constraintEqualToAnchor:overlayScrollView.trailingAnchor],
        [contentView.bottomAnchor   constraintEqualToAnchor:overlayScrollView.bottomAnchor],
        [contentView.widthAnchor    constraintEqualToAnchor:overlayScrollView.widthAnchor],

        // Layout mirrors the main login form for visual consistency
        [resetTitle.topAnchor      constraintEqualToAnchor:contentView.topAnchor constant:80],
        [resetTitle.leadingAnchor  constraintEqualToAnchor:contentView.leadingAnchor constant:32],
        [resetTitle.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-32],

        [resetSubtitle.topAnchor      constraintEqualToAnchor:resetTitle.bottomAnchor constant:8],
        [resetSubtitle.leadingAnchor  constraintEqualToAnchor:contentView.leadingAnchor constant:32],
        [resetSubtitle.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-32],

        [self.resetPasswordField.topAnchor      constraintEqualToAnchor:resetSubtitle.bottomAnchor constant:40],
        [self.resetPasswordField.leadingAnchor  constraintEqualToAnchor:contentView.leadingAnchor constant:24],
        [self.resetPasswordField.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-24],
        [self.resetPasswordField.heightAnchor   constraintEqualToConstant:52],

        [self.confirmPasswordField.topAnchor      constraintEqualToAnchor:self.resetPasswordField.bottomAnchor constant:12],
        [self.confirmPasswordField.leadingAnchor  constraintEqualToAnchor:contentView.leadingAnchor constant:24],
        [self.confirmPasswordField.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-24],
        [self.confirmPasswordField.heightAnchor   constraintEqualToConstant:52],

        [self.resetMessageLabel.topAnchor      constraintEqualToAnchor:self.confirmPasswordField.bottomAnchor constant:10],
        [self.resetMessageLabel.leadingAnchor  constraintEqualToAnchor:contentView.leadingAnchor constant:24],
        [self.resetMessageLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-24],

        [self.setPasswordButton.topAnchor      constraintEqualToAnchor:self.resetMessageLabel.bottomAnchor constant:20],
        [self.setPasswordButton.leadingAnchor  constraintEqualToAnchor:contentView.leadingAnchor constant:24],
        [self.setPasswordButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-24],
        [self.setPasswordButton.heightAnchor   constraintEqualToConstant:52],

        [self.cancelResetButton.topAnchor     constraintEqualToAnchor:self.setPasswordButton.bottomAnchor constant:16],
        [self.cancelResetButton.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],

        [self.resetSpinner.topAnchor     constraintEqualToAnchor:self.cancelResetButton.bottomAnchor constant:16],
        [self.resetSpinner.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],
        [self.resetSpinner.bottomAnchor  constraintEqualToAnchor:contentView.bottomAnchor constant:-40],
    ]];
}

#pragma mark - Password Reset — Entry State

// Called either by the EZPasswordResetReadyNotification handler (LoginVC already
// visible) or directly from viewDidLoad (fresh LoginVC created by AppDelegate
// after the deep link arrived while ViewController was the root).

- (void)handlePasswordResetReady {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showPasswordResetEntryState];
    });
}

- (void)showPasswordResetEntryState {
    [self setupPasswordResetOverlay]; // No-op if already built

    // Clear any previous state in the overlay fields before showing
    self.resetPasswordField.text     = @"";
    self.confirmPasswordField.text = @"";
    self.resetMessageLabel.hidden  = YES;

    // Ensure both fields are secure when the overlay appears
    if (!self.resetPasswordField.secureTextEntry) {
        [self toggleNewPasswordVisibility];
    }
    if (!self.confirmPasswordField.secureTextEntry) {
        [self toggleConfirmPasswordVisibility];
    }

    [UIView animateWithDuration:0.25 animations:^{
        self.passwordResetOverlayView.alpha = 1.0;
    } completion:^(BOOL finished) {
        [self.resetPasswordField becomeFirstResponder];
    }];
}

#pragma mark - Password Reset — Submit

- (void)handleSetPasswordSubmit {
    NSString *newPassword     = self.resetPasswordField.text;
    NSString *confirmPassword = self.confirmPasswordField.text;

    if (newPassword.length < 8) {
        [self showResetMessage:@"Password must be at least 8 characters." isError:YES];
        return;
    }
    if (![newPassword isEqualToString:confirmPassword]) {
        [self showResetMessage:@"Passwords don't match. Please try again." isError:YES];
        [self.confirmPasswordField becomeFirstResponder];
        return;
    }

    [self setResetLoading:YES];

    [[EZAuthManager shared] setNewPassword:newPassword
                                completion:^(BOOL success, NSString *errorMessage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setResetLoading:NO];

            if (!success) {
                [self showResetMessage:errorMessage ?: @"Something went wrong. Please try again."
                               isError:YES];
                return;
            }

            // Success — show a brief confirmation then dismiss the overlay and
            // return to the sign-in screen. The user signs in with their new password.
            [self showResetMessage:@"Password updated! Please sign in with your new password."
                           isError:NO];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self dismissPasswordResetOverlay];
            });
        });
    }];
}

#pragma mark - Password Reset — Cancel

- (void)handleCancelPasswordReset {
    [[EZAuthManager shared] cancelPasswordReset];
    [self dismissPasswordResetOverlay];
}

- (void)dismissPasswordResetOverlay {
    [self.resetPasswordField resignFirstResponder];
    [self.confirmPasswordField resignFirstResponder];

    [UIView animateWithDuration:0.25 animations:^{
        self.passwordResetOverlayView.alpha = 0;
    }];
}

#pragma mark - Password Visibility — Reset Overlay Fields

- (void)toggleNewPasswordVisibility {
    NSString *currentText = self.resetPasswordField.text;
    self.resetPasswordField.secureTextEntry = !self.resetPasswordField.secureTextEntry;
    self.resetPasswordField.text = currentText;

    NSString *iconName = self.resetPasswordField.secureTextEntry ? @"eye.slash" : @"eye";
    [self.resetPasswordVisibilityButton setImage:[UIImage systemImageNamed:iconName]
                                      forState:UIControlStateNormal];
}

- (void)toggleConfirmPasswordVisibility {
    NSString *currentText = self.confirmPasswordField.text;
    self.confirmPasswordField.secureTextEntry = !self.confirmPasswordField.secureTextEntry;
    self.confirmPasswordField.text = currentText;

    NSString *iconName = self.confirmPasswordField.secureTextEntry ? @"eye.slash" : @"eye";
    [self.confirmPasswordVisibilityButton setImage:[UIImage systemImageNamed:iconName]
                                          forState:UIControlStateNormal];
}

#pragma mark - UITextFieldDelegate (extended for reset overlay)

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.emailField) {
        [self.passwordField becomeFirstResponder];
    } else if (textField == self.passwordField) {
        [self.passwordField resignFirstResponder];
        [self handleLogin];
    } else if (textField == self.resetPasswordField) {
        // Move to confirm field when user taps Next in the reset overlay
        [self.confirmPasswordField becomeFirstResponder];
    } else if (textField == self.confirmPasswordField) {
        [self.confirmPasswordField resignFirstResponder];
        [self handleSetPasswordSubmit];
    }
    return YES;
}

#pragma mark - Password Visibility — Main Field

- (void)togglePasswordVisibility {
    // iOS clears the text when secureTextEntry changes — preserve it explicitly
    NSString *currentPassword = self.passwordField.text;
    self.passwordField.secureTextEntry = !self.passwordField.secureTextEntry;
    self.passwordField.text = currentPassword;

    NSString *iconName = self.passwordField.secureTextEntry ? @"eye.slash" : @"eye";
    [self.passwordVisibilityButton setImage:[UIImage systemImageNamed:iconName]
                                   forState:UIControlStateNormal];
}

#pragma mark - Mode Toggle

- (void)toggleMode {
    self.isSignUpMode = !self.isSignUpMode;

    if (self.isSignUpMode) {
        self.subtitleLabel.text = @"Create your account";
        self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
        [self.loginButton setTitle:@"Sign Up" forState:UIControlStateNormal];
        [self.toggleModeButton setTitle:@"Already have an account? Sign In"
                               forState:UIControlStateNormal];
        self.savedAccountLabel.hidden = YES;
        self.forgotPasswordButton.hidden = YES;
    } else {
        self.subtitleLabel.text = @"Sign in to continue";
        self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
        [self.loginButton setTitle:@"Sign In" forState:UIControlStateNormal];
        [self.toggleModeButton setTitle:@"Don't have an account? Sign Up"
                               forState:UIControlStateNormal];
        self.forgotPasswordButton.hidden = NO;
        [self prefillSavedEmail];
    }

    // Reset password field visibility when toggling modes
    if (!self.passwordField.secureTextEntry) {
        [self togglePasswordVisibility];
    }

    self.messageLabel.hidden = YES;
}

#pragma mark - Login / Sign Up

- (void)handleLogin {
    NSString *email    = [self.emailField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *password = self.passwordField.text;

    // Input validation — checked before any network call
    if (!email.length) {
        [self showError:@"Please enter your email address."];
        return;
    }
    if (![email containsString:@"@"] || ![email containsString:@"."]) {
        [self showError:@"Please enter a valid email address."];
        return;
    }
    if (!password.length) {
        [self showError:@"Please enter your password."];
        return;
    }
    // Supabase's default minimum is 8 characters for both sign-in attempts and sign-up
    NSInteger minimumPasswordLength = self.isSignUpMode ? 8 : 6;
    if (password.length < (NSUInteger)minimumPasswordLength) {
        NSString *lengthError = self.isSignUpMode
            ? @"Password must be at least 8 characters."
            : @"Please enter your password.";
        [self showError:lengthError];
        return;
    }

    [self setLoading:YES];
    self.messageLabel.hidden = YES;

    void(^authCompletion)(BOOL, NSString *) = ^(BOOL success, NSString *errorMessage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoading:NO];

            if (!success) {
                [self showError:errorMessage ?: @"Something went wrong. Please try again."];
                return;
            }

            if ([[EZAuthManager shared] isLoggedIn]) {
                // Full authentication — save email for prefill and go to app
                [[NSUserDefaults standardUserDefaults] setObject:email forKey:kLastEmailKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                [self proceedToApp];
            } else {
                // Sign-up succeeded but email confirmation is required.
                // Supabase returned 200 with no access token — show confirmation state.
                [self showEmailConfirmationStateForEmail:email];
            }
        });
    };

    if (self.isSignUpMode) {
        [[EZAuthManager shared] signUpWithEmail:email password:password completion:authCompletion];
    } else {
        [[EZAuthManager shared] signInWithEmail:email password:password completion:authCompletion];
    }
}

#pragma mark - Forgot Password

- (void)handleForgotPassword {
    NSString *email = [self.emailField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    if (!email.length) {
        [self showError:@"Enter your email address above, then tap Forgot Password."];
        return;
    }

    [self setLoading:YES];
    self.messageLabel.hidden = YES;

    [[EZAuthManager shared] sendPasswordResetEmail:email
                                        completion:^(BOOL success, NSString *errorMessage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoading:NO];
            if (success) {
                [self showMessage:@"Password reset email sent. Check your inbox."
                          isError:NO];
            } else {
                [self showError:errorMessage ?: @"Could not send reset email. Please try again."];
            }
        });
    }];
}

#pragma mark - Email Confirmation State

- (void)showEmailConfirmationStateForEmail:(NSString *)email {
    // Switch to sign-in mode and show a clear next-step message
    self.isSignUpMode = NO;
    [self.loginButton setTitle:@"Sign In" forState:UIControlStateNormal];
    [self.toggleModeButton setTitle:@"Don't have an account? Sign Up"
                           forState:UIControlStateNormal];
    self.forgotPasswordButton.hidden = NO;
    self.emailField.text   = email;
    self.passwordField.text = @"";

    // Reset password visibility for the sign-in flow
    if (!self.passwordField.secureTextEntry) {
        [self togglePasswordVisibility];
    }

    // Show a green confirmation message instead of the normal subtitle
    NSString *confirmationMessage = [NSString stringWithFormat:
        @"We sent a confirmation link to %@.\nTap it to activate your account, then sign in.",
        email];
    [self showMessage:confirmationMessage isError:NO];
}

#pragma mark - Navigation

- (void)proceedToApp {
    ViewController *mainVC = [[ViewController alloc] init];
    UIWindow *appWindow = self.view.window;
    appWindow.rootViewController = mainVC;
    [UIView transitionWithView:appWindow
                      duration:0.3
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:nil
                    completion:nil];
}

#pragma mark - Helpers

- (UITextField *)makeTextField:(NSString *)placeholder secure:(BOOL)secure {
    UITextField *textField = [[UITextField alloc] init];
    textField.placeholder        = placeholder;
    textField.secureTextEntry    = secure;
    textField.borderStyle        = UITextBorderStyleNone;
    textField.backgroundColor    = [UIColor secondarySystemBackgroundColor];
    textField.layer.cornerRadius = 12;
    textField.leftView           = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 16, 0)];
    textField.leftViewMode       = UITextFieldViewModeAlways;
    textField.translatesAutoresizingMaskIntoConstraints = NO;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    return textField;
}

// Returns a pre-styled eye/eye.slash button suitable for use as a text field's
// rightView. Caller is responsible for wiring the target/action.
- (UIButton *)makePasswordVisibilityButton {
    UIButton *visibilityButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [visibilityButton setImage:[UIImage systemImageNamed:@"eye.slash"]
                      forState:UIControlStateNormal];
    visibilityButton.tintColor = [UIColor secondaryLabelColor];
    visibilityButton.frame     = CGRectMake(0, 0, 44, 44);
    return visibilityButton;
}

- (void)showError:(NSString *)message {
    [self showMessage:message isError:YES];
}

// Dual-purpose message label: red for errors, green for informational feedback
- (void)showMessage:(NSString *)message isError:(BOOL)isError {
    self.messageLabel.text      = message;
    self.messageLabel.textColor = isError ? [UIColor systemRedColor] : [UIColor systemGreenColor];
    self.messageLabel.hidden    = NO;
}

// Same dual-purpose pattern, but for the reset overlay's own message label
- (void)showResetMessage:(NSString *)message isError:(BOOL)isError {
    self.resetMessageLabel.text      = message;
    self.resetMessageLabel.textColor = isError ? [UIColor systemRedColor] : [UIColor systemGreenColor];
    self.resetMessageLabel.hidden    = NO;
}

- (void)setLoading:(BOOL)isLoading {
    isLoading ? [self.spinner startAnimating] : [self.spinner stopAnimating];
    self.loginButton.enabled          = !isLoading;
    self.emailField.enabled           = !isLoading;
    self.passwordField.enabled        = !isLoading;
    self.toggleModeButton.enabled     = !isLoading;
    self.forgotPasswordButton.enabled = !isLoading;
}

// Separate loading state for the reset overlay so it doesn't touch the
// main login UI controls (which are hidden behind the overlay anyway)
- (void)setResetLoading:(BOOL)isLoading {
    isLoading ? [self.resetSpinner startAnimating] : [self.resetSpinner stopAnimating];
    self.setPasswordButton.enabled      = !isLoading;
    self.resetPasswordField.enabled       = !isLoading;
    self.confirmPasswordField.enabled   = !isLoading;
    self.cancelResetButton.enabled      = !isLoading;
}

#pragma mark - Keyboard

- (void)registerForKeyboardNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    CGSize keyboardSize = [notification.userInfo[UIKeyboardFrameEndUserInfoKey]
                           CGRectValue].size;
    UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, keyboardSize.height, 0);
    // Update both scroll views — messaging nil is safe if overlay hasn't been built yet
    self.scrollView.contentInset              = insets;
    self.passwordResetScrollView.contentInset = insets;
}

- (void)keyboardWillHide:(NSNotification *)notification {
    self.scrollView.contentInset              = UIEdgeInsetsZero;
    self.passwordResetScrollView.contentInset = UIEdgeInsetsZero;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
