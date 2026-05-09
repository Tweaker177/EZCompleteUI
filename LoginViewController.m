    // LoginViewController.m
    // EZCompleteUI

    #import "LoginViewController.h"
    #import "EZAuthManager.h"
    #import "ViewController.h"

    @interface LoginViewController ()
    @property (nonatomic, strong) UIScrollView *scrollView;
    @property (nonatomic, strong) UIView *containerView;
    @property (nonatomic, strong) UILabel *titleLabel;
    @property (nonatomic, strong) UILabel *subtitleLabel;
    @property (nonatomic, strong) UITextField *emailField;
    @property (nonatomic, strong) UITextField *passwordField;
    @property (nonatomic, strong) UIButton *loginButton;
    @property (nonatomic, strong) UIButton *signupButton;
    @property (nonatomic, strong) UIButton *toggleModeButton;
    @property (nonatomic, strong) UIActivityIndicatorView *spinner;
    @property (nonatomic, strong) UILabel *errorLabel;
    @property (nonatomic, assign) BOOL isSignUpMode;
    @end

    @implementation LoginViewController

    - (void)viewDidLoad {
        [super viewDidLoad];
        self.view.backgroundColor = [UIColor systemBackgroundColor];
        [self setupUI];
        [self registerForKeyboardNotifications];
    }

    - (void)setupUI {
        // Scroll view
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

        // Subtitle
        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.text = @"Sign in to continue";
        self.subtitleLabel.font = [UIFont systemFontOfSize:16];
        self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
        self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
        self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        // Email field
        self.emailField = [self makeTextField:@"Email" secure:NO];
        self.emailField.keyboardType = UIKeyboardTypeEmailAddress;
        self.emailField.autocapitalizationType = UITextAutocapitalizationTypeNone;

        // Password field
        self.passwordField = [self makeTextField:@"Password" secure:YES];

        // Error label
        self.errorLabel = [[UILabel alloc] init];
        self.errorLabel.textColor = [UIColor systemRedColor];
        self.errorLabel.font = [UIFont systemFontOfSize:13];
        self.errorLabel.textAlignment = NSTextAlignmentCenter;
        self.errorLabel.numberOfLines = 0;
        self.errorLabel.hidden = YES;
        self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;

        // Login button
        self.loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.loginButton setTitle:@"Sign In" forState:UIControlStateNormal];
        self.loginButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        self.loginButton.backgroundColor = [UIColor systemBlueColor];
        [self.loginButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.loginButton.layer.cornerRadius = 12;
        self.loginButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.loginButton addTarget:self action:@selector(handleLogin)
                   forControlEvents:UIControlEventTouchUpInside];

        // Toggle mode button
        self.toggleModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.toggleModeButton setTitle:@"Don't have an account? Sign Up"
                               forState:UIControlStateNormal];
        self.toggleModeButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.toggleModeButton addTarget:self action:@selector(toggleMode)
                        forControlEvents:UIControlEventTouchUpInside];

        // Spinner
        self.spinner = [[UIActivityIndicatorView alloc]
                        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
        self.spinner.hidesWhenStopped = YES;

        // Add subviews
        for (UIView *v in @[self.titleLabel, self.subtitleLabel, self.emailField,
                            self.passwordField, self.errorLabel, self.loginButton,
                            self.toggleModeButton, self.spinner]) {
            [self.containerView addSubview:v];
        }

        // Constraints
        [NSLayoutConstraint activateConstraints:@[
            [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
            [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

            [self.containerView.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor],
            [self.containerView.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor],
            [self.containerView.trailingAnchor constraintEqualToAnchor:self.scrollView.trailingAnchor],
            [self.containerView.bottomAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor],
            [self.containerView.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor],

            [self.titleLabel.topAnchor constraintEqualToAnchor:self.containerView.topAnchor constant:80],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:32],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-32],

            [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8],
            [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:32],
            [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-32],

            [self.emailField.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:48],
            [self.emailField.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
            [self.emailField.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],
            [self.emailField.heightAnchor constraintEqualToConstant:52],

            [self.passwordField.topAnchor constraintEqualToAnchor:self.emailField.bottomAnchor constant:12],
            [self.passwordField.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
            [self.passwordField.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],
            [self.passwordField.heightAnchor constraintEqualToConstant:52],

            [self.errorLabel.topAnchor constraintEqualToAnchor:self.passwordField.bottomAnchor constant:8],
            [self.errorLabel.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
            [self.errorLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],

            [self.loginButton.topAnchor constraintEqualToAnchor:self.errorLabel.bottomAnchor constant:24],
            [self.loginButton.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:24],
            [self.loginButton.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-24],
            [self.loginButton.heightAnchor constraintEqualToConstant:52],

            [self.toggleModeButton.topAnchor constraintEqualToAnchor:self.loginButton.bottomAnchor constant:16],
            [self.toggleModeButton.centerXAnchor constraintEqualToAnchor:self.containerView.centerXAnchor],

            [self.spinner.topAnchor constraintEqualToAnchor:self.toggleModeButton.bottomAnchor constant:16],
            [self.spinner.centerXAnchor constraintEqualToAnchor:self.containerView.centerXAnchor],
            [self.spinner.bottomAnchor constraintEqualToAnchor:self.containerView.bottomAnchor constant:-40],
        ]];
    }

    - (UITextField *)makeTextField:(NSString *)placeholder secure:(BOOL)secure {
        UITextField *tf = [[UITextField alloc] init];
        tf.placeholder = placeholder;
        tf.secureTextEntry = secure;
        tf.borderStyle = UITextBorderStyleNone;
        tf.backgroundColor = [UIColor secondarySystemBackgroundColor];
        tf.layer.cornerRadius = 12;
        tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 16, 0)];
        tf.leftViewMode = UITextFieldViewModeAlways;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        return tf;
    }

    - (void)toggleMode {
        self.isSignUpMode = !self.isSignUpMode;
        if (self.isSignUpMode) {
            self.subtitleLabel.text = @"Create your account";
            [self.loginButton setTitle:@"Sign Up" forState:UIControlStateNormal];
            [self.toggleModeButton setTitle:@"Already have an account? Sign In"
                                   forState:UIControlStateNormal];
        } else {
            self.subtitleLabel.text = @"Sign in to continue";
            [self.loginButton setTitle:@"Sign In" forState:UIControlStateNormal];
            [self.toggleModeButton setTitle:@"Don't have an account? Sign Up"
                                   forState:UIControlStateNormal];
        }
        self.errorLabel.hidden = YES;
    }

    - (void)handleLogin {
        NSString *email = self.emailField.text;
        NSString *password = self.passwordField.text;

        if (email.length == 0 || password.length == 0) {
            [self showError:@"Please enter your email and password"];
            return;
        }

        [self setLoading:YES];

        void(^completion)(BOOL, NSString *) = ^(BOOL success, NSString *error) {
            [self setLoading:NO];
            if (success) {
                [self proceedToApp];
            } else {
                [self showError:error ?: @"Something went wrong"];
            }
        };

        if (self.isSignUpMode) {
            [[EZAuthManager shared] signUpWithEmail:email
                                           password:password
                                         completion:completion];
        } else {
            [[EZAuthManager shared] signInWithEmail:email
                                           password:password
                                         completion:completion];
        }
    }

    - (void)proceedToApp {
        ViewController *vc = [[ViewController alloc] init];
        UIWindow *window = self.view.window;
        window.rootViewController = vc;
        [UIView transitionWithView:window
                          duration:0.3
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:nil
                        completion:nil];
    }

    - (void)showError:(NSString *)message {
        self.errorLabel.text = message;
        self.errorLabel.hidden = NO;
    }

    - (void)setLoading:(BOOL)loading {
        loading ? [self.spinner startAnimating] : [self.spinner stopAnimating];
        self.loginButton.enabled = !loading;
        self.emailField.enabled = !loading;
        self.passwordField.enabled = !loading;
    }

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
        CGSize keyboardSize = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue].size;
        self.scrollView.contentInset = UIEdgeInsetsMake(0, 0, keyboardSize.height, 0);
    }

    - (void)keyboardWillHide:(NSNotification *)notification {
        self.scrollView.contentInset = UIEdgeInsetsZero;
    }

    - (void)dealloc {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }

    @end
