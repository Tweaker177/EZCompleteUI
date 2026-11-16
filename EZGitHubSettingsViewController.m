// EZGitHubSettingsViewController.m
// EZCompleteUI v1.0
//
// See EZGitHubSettingsViewController.h.

#import "EZGitHubSettingsViewController.h"
#import "EZGitHubService.h"
#import <SafariServices/SafariServices.h>

static NSString * const kEZGitHubNewTokenURL = @"https://github.com/settings/personal-access-tokens/new";

@interface EZGitHubSettingsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@property (nonatomic, strong) UILabel *statusLabel;

// Shown while not connected.
@property (nonatomic, strong) UIStackView *connectStack;
@property (nonatomic, strong) UITextField *tokenField;
@property (nonatomic, strong) UIButton *connectButton;

// Shown while connected.
@property (nonatomic, strong) UIStackView *connectedStack;
@property (nonatomic, strong) UISwitch *writesSwitch;
@property (nonatomic, strong) UIButton *disconnectButton;

@property (nonatomic, assign) BOOL busy;
@end

@implementation EZGitHubSettingsViewController

// ── Setup ───────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GitHub";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    if (self.navigationController && self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                          target:self action:@selector(dismissSelf)];
    }

    self.scrollView = [UIScrollView new];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    self.stack = [UIStackView new];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 14;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.stack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:20],
        [self.stack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-30],
        [self.stack.leadingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.leadingAnchor constant:20],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.trailingAnchor constant:-20],
    ]];

    // Status line.
    self.statusLabel = [self labelWithText:@"Checking…" font:[UIFont boldSystemFontOfSize:17]
                                     color:[UIColor labelColor]];
    [self.stack addArrangedSubview:self.statusLabel];

    [self.stack addArrangedSubview:[self labelWithText:
        @"Connect GitHub so the chat models can read your repositories: browse files, search code, "
         "review pull requests, and save a repo as a zip. Your token is stored encrypted on the server "
         "and is never shown to the models or sent back to this app."
                                                  font:[UIFont systemFontOfSize:14]
                                                 color:[UIColor secondaryLabelColor]]];

    [self buildConnectSection];
    [self buildConnectedSection];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [self.stack addArrangedSubview:self.spinner];

    [self applyConnected:NO login:nil allowWrites:NO];
    [self reload];
}

- (void)buildConnectSection {
    self.connectStack = [UIStackView new];
    self.connectStack.axis = UILayoutConstraintAxisVertical;
    self.connectStack.spacing = 12;

    [self.connectStack addArrangedSubview:[self labelWithText:
        @"1. Create a fine-grained token at github.com, limited to the repositories you want to share.\n"
         "2. For read-only access give it Contents: Read (add Pull requests: Read and Issues: Read to list those).\n"
         "3. To let the models propose changes, also give it Contents and Pull requests: Read and write. Leave Workflows off.\n"
         "4. Paste it below."
                                                              font:[UIFont systemFontOfSize:13]
                                                             color:[UIColor secondaryLabelColor]]];

    UIButton *create = [self filledButtonWithTitle:@"Create a token on GitHub"
                                            color:[UIColor systemGrayColor]
                                           action:@selector(openTokenPage)];
    [self.connectStack addArrangedSubview:create];

    self.tokenField = [UITextField new];
    self.tokenField.borderStyle = UITextBorderStyleRoundedRect;
    self.tokenField.placeholder = @"github_pat_…";
    self.tokenField.secureTextEntry = YES;
    self.tokenField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.tokenField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.tokenField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.tokenField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.tokenField.returnKeyType = UIReturnKeyGo;
    self.tokenField.font = [UIFont systemFontOfSize:15];
    self.tokenField.delegate = self;
    [self.tokenField.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.connectStack addArrangedSubview:self.tokenField];

    self.connectButton = [self filledButtonWithTitle:@"Connect GitHub"
                                              color:[UIColor systemBlueColor]
                                             action:@selector(connectTapped)];
    [self.connectStack addArrangedSubview:self.connectButton];

    [self.stack addArrangedSubview:self.connectStack];
}

- (void)buildConnectedSection {
    self.connectedStack = [UIStackView new];
    self.connectedStack.axis = UILayoutConstraintAxisVertical;
    self.connectedStack.spacing = 12;

    UILabel *writesTitle = [self labelWithText:@"Allow changes (branches, commits, pull requests)"
                                          font:[UIFont systemFontOfSize:15]
                                         color:[UIColor labelColor]];
    self.writesSwitch = [UISwitch new];
    [self.writesSwitch addTarget:self action:@selector(writesToggled:) forControlEvents:UIControlEventValueChanged];
    [self.writesSwitch setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[writesTitle, self.writesSwitch]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    [self.connectedStack addArrangedSubview:row];

    [self.connectedStack addArrangedSubview:[self labelWithText:
        @"Off by default. When on, the models can propose changes, but nothing happens until you approve each one "
         "in the app. They can never commit straight to your default branch, merge, or edit workflow files."
                                                           font:[UIFont systemFontOfSize:13]
                                                          color:[UIColor secondaryLabelColor]]];

    self.disconnectButton = [self filledButtonWithTitle:@"Disconnect GitHub"
                                                 color:[UIColor systemRedColor]
                                                action:@selector(disconnectTapped)];
    [self.connectedStack addArrangedSubview:self.disconnectButton];

    [self.stack addArrangedSubview:self.connectedStack];
}

// ── View helpers ────────────────────────────────────────────────────────────

- (UILabel *)labelWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UIButton *)filledButtonWithTitle:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.backgroundColor = color;
    button.tintColor = [UIColor whiteColor];
    button.layer.cornerRadius = 10;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:44].active = YES;
    return button;
}

// ── State ───────────────────────────────────────────────────────────────────

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    if (busy) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    self.connectButton.enabled = !busy;
    self.disconnectButton.enabled = !busy;
    self.writesSwitch.enabled = !busy;
    self.tokenField.enabled = !busy;
}

- (void)applyConnected:(BOOL)connected login:(NSString *)login allowWrites:(BOOL)allowWrites {
    self.connectStack.hidden = connected;
    self.connectedStack.hidden = !connected;
    self.writesSwitch.on = allowWrites;
    if (connected) {
        self.statusLabel.text = login.length
            ? [NSString stringWithFormat:@"Connected as @%@", login] : @"Connected to GitHub";
    } else {
        self.statusLabel.text = @"Not connected";
    }
}

- (void)reload {
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    [[EZGitHubService sharedService] fetchStatusWithCompletion:^(BOOL connected, NSString *login, BOOL allowWrites, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.busy = NO;
        if (error) {
            strongSelf.statusLabel.text = @"Couldn't check GitHub status";
            [strongSelf showMessage:error.localizedDescription title:@"GitHub"];
            return;
        }
        [strongSelf applyConnected:connected login:login allowWrites:allowWrites];
    }];
}

// ── Actions ─────────────────────────────────────────────────────────────────

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)openTokenPage {
    NSURL *url = [NSURL URLWithString:kEZGitHubNewTokenURL];
    if (!url) return;
    SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
    [self presentViewController:safari animated:YES completion:nil];
}

- (void)connectTapped {
    [self.view endEditing:YES];
    NSString *token = [self.tokenField.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (token.length == 0) {
        [self showMessage:@"Paste your GitHub token first." title:@"GitHub"];
        return;
    }
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    [[EZGitHubService sharedService] connectWithToken:token
                                           completion:^(NSString *login, NSString *expiresAt, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.busy = NO;
        if (error) {
            [strongSelf showMessage:error.localizedDescription title:@"Couldn't connect"];
            return;
        }
        strongSelf.tokenField.text = @"";   // the token is never kept on the device
        [strongSelf applyConnected:YES login:login allowWrites:NO];
        if (expiresAt.length > 0) {
            [strongSelf showMessage:[NSString stringWithFormat:@"This token expires %@. Reconnect with a new one before then.", expiresAt]
                              title:@"GitHub connected"];
        }
    }];
}

- (void)writesToggled:(UISwitch *)sender {
    BOOL desired = sender.isOn;
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    [[EZGitHubService sharedService] setAllowWrites:desired completion:^(BOOL allowWrites, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.busy = NO;
        if (error) {
            strongSelf.writesSwitch.on = !desired;   // put the switch back to what the server has
            [strongSelf showMessage:error.localizedDescription title:@"Couldn't update"];
            return;
        }
        strongSelf.writesSwitch.on = allowWrites;
    }];
}

- (void)disconnectTapped {
    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Disconnect GitHub?"
                         message:@"The saved token and any saved repository zips are deleted. You can reconnect any time."
                  preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"Disconnect" style:UIAlertActionStyleDestructive
                                              handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.busy = YES;
        [[EZGitHubService sharedService] disconnectWithCompletion:^(NSError *error) {
            strongSelf.busy = NO;
            if (error) {
                [strongSelf showMessage:error.localizedDescription title:@"Couldn't disconnect"];
                return;
            }
            [strongSelf applyConnected:NO login:nil allowWrites:NO];
        }];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ── UITextFieldDelegate ─────────────────────────────────────────────────────

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self connectTapped];
    return YES;
}

@end
