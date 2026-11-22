// EZTermsAcceptanceViewController.m
// EZCompleteUI v1.1
//
// Changes from v1.0:
//   - Added #import "EZKeyVault.h" — support email now loaded from vault.

#import "EZTermsAcceptanceViewController.h"
#import "EZPoliciesViewController.h"
#import "EZAuthManager.h"
#import "EZKeyVault.h"
#import "LoginViewController.h"

NSString *const EZTermsAcceptedVersionKey = @"EZ_termsAcceptedVersion";

// ── Bump this when Terms, Privacy Policy, or Refund Policy change materially ─
// Users who accepted an older version will be re-prompted on next launch.
NSString *const EZCurrentTermsVersion = @"2026-09-18";

@interface EZTermsAcceptanceViewController ()
@property (nonatomic, strong) UIView   *cardView;
@property (nonatomic, strong) UIButton *acceptButton;
@property (nonatomic, strong) UIButton *declineButton;
@end

@implementation EZTermsAcceptanceViewController

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Class helpers
// ─────────────────────────────────────────────────────────────────────────────

+ (BOOL)hasUserAcceptedCurrentTerms {
    NSString *accepted = [[NSUserDefaults standardUserDefaults]
        stringForKey:EZTermsAcceptedVersionKey];
    return [accepted isEqualToString:EZCurrentTermsVersion];
}

+ (void)recordAcceptance {
    [[NSUserDefaults standardUserDefaults]
        setObject:EZCurrentTermsVersion forKey:EZTermsAcceptedVersionKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupUI];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UI Setup
// ─────────────────────────────────────────────────────────────────────────────

- (void)setupUI {
    // ── Dimmed background ─────────────────────────────────────────────────────
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];

    // ── Card ──────────────────────────────────────────────────────────────────
    self.cardView = [[UIView alloc] init];
    self.cardView.backgroundColor    = [UIColor systemBackgroundColor];
    self.cardView.layer.cornerRadius = 20;
    self.cardView.layer.shadowColor  = [UIColor blackColor].CGColor;
    self.cardView.layer.shadowOpacity = 0.25;
    self.cardView.layer.shadowRadius = 16;
    self.cardView.layer.shadowOffset = CGSizeMake(0, 4);
    self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.cardView];

    // ── App icon / emoji header ───────────────────────────────────────────────
    UILabel *iconLabel      = [UILabel new];
    iconLabel.adjustsFontSizeToFitWidth = YES;
    iconLabel.minimumScaleFactor = 0.5;
    iconLabel.text          = @"📋";
    iconLabel.font          = [UIFont systemFontOfSize:48];
    iconLabel.textAlignment = NSTextAlignmentCenter;
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardView addSubview:iconLabel];

    // ── Title ─────────────────────────────────────────────────────────────────
    UILabel *titleLabel      = [UILabel new];
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.5;
    titleLabel.text          = @"Terms & Privacy Updated";
    titleLabel.font          = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    titleLabel.textColor     = [UIColor labelColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardView addSubview:titleLabel];

    // ── Summary body ──────────────────────────────────────────────────────────
    UILabel *bodyLabel      = [UILabel new];
    bodyLabel.adjustsFontSizeToFitWidth = YES;
    bodyLabel.minimumScaleFactor = 0.5;
    bodyLabel.numberOfLines = 0;
    bodyLabel.textAlignment = NSTextAlignmentCenter;
    bodyLabel.textColor     = [UIColor secondaryLabelColor];
    bodyLabel.font          = [UIFont systemFontOfSize:15];
    bodyLabel.text          =
        @"We updated our Terms, Privacy Policy, and data-sharing information.\n\n"
        @"Resend now delivers signup and password-reset emails. Cloudflare supports our domain and may be used "
        @"for future network, security, or performance services. Namecheap provides domain and DNS infrastructure.\n\n"
        @"These providers may process limited information needed to provide their services. We do not sell your data. "
        @"Please review the updated policies before continuing.";
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardView addSubview:bodyLabel];

    // ── "Read Full Policies" link button ──────────────────────────────────────
    UIButton *readButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [readButton setTitle:@"Read Full Terms, Privacy Policy & Refund Policy"
               forState:UIControlStateNormal];
    readButton.titleLabel.font = [UIFont systemFontOfSize:14];
    readButton.titleLabel.numberOfLines = 0;
    readButton.titleLabel.textAlignment = NSTextAlignmentCenter;
    readButton.translatesAutoresizingMaskIntoConstraints = NO;
    [readButton addTarget:self action:@selector(readPoliciesTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [self.cardView addSubview:readButton];

    // ── Separator ─────────────────────────────────────────────────────────────
    UIView *separatorLine = [UIView new];
    separatorLine.backgroundColor = [UIColor separatorColor];
    separatorLine.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardView addSubview:separatorLine];

    // ── Accept button ─────────────────────────────────────────────────────────
    self.acceptButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.acceptButton setTitle:@"I Accept" forState:UIControlStateNormal];
    self.acceptButton.titleLabel.font   = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.acceptButton.backgroundColor   = [UIColor systemGreenColor];
    self.acceptButton.tintColor         = [UIColor whiteColor];
    self.acceptButton.layer.cornerRadius = 14;
    self.acceptButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.acceptButton addTarget:self action:@selector(acceptTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [self.cardView addSubview:self.acceptButton];

    // ── Decline link ──────────────────────────────────────────────────────────
    self.declineButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.declineButton setTitle:@"Decline & Sign Out" forState:UIControlStateNormal];
    self.declineButton.titleLabel.font = [UIFont systemFontOfSize:13];
    [self.declineButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    self.declineButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.declineButton addTarget:self action:@selector(declineTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    [self.cardView addSubview:self.declineButton];

    // ── Constraints ───────────────────────────────────────────────────────────
    [NSLayoutConstraint activateConstraints:@[
        // Card centered, inset from screen edges
        [self.cardView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.cardView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.cardView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.cardView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],

        // Icon
        [iconLabel.topAnchor constraintEqualToAnchor:self.cardView.topAnchor constant:28],
        [iconLabel.centerXAnchor constraintEqualToAnchor:self.cardView.centerXAnchor],

        // Title
        [titleLabel.topAnchor constraintEqualToAnchor:iconLabel.bottomAnchor constant:10],
        [titleLabel.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:20],
        [titleLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-20],

        // Body
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:14],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:20],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-20],

        // Read link
        [readButton.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:14],
        [readButton.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:20],
        [readButton.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-20],

        // Separator
        [separatorLine.topAnchor constraintEqualToAnchor:readButton.bottomAnchor constant:16],
        [separatorLine.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor],
        [separatorLine.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor],
        [separatorLine.heightAnchor constraintEqualToConstant:0.5],

        // Accept button
        [self.acceptButton.topAnchor constraintEqualToAnchor:separatorLine.bottomAnchor constant:16],
        [self.acceptButton.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:20],
        [self.acceptButton.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-20],
        [self.acceptButton.heightAnchor constraintEqualToConstant:50],

        // Decline link
        [self.declineButton.topAnchor constraintEqualToAnchor:self.acceptButton.bottomAnchor constant:10],
        [self.declineButton.centerXAnchor constraintEqualToAnchor:self.cardView.centerXAnchor],
        [self.declineButton.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor constant:-20],
    ]];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Actions
// ─────────────────────────────────────────────────────────────────────────────

- (void)readPoliciesTapped {
    EZPoliciesViewController *policiesVC = [EZPoliciesViewController new];
    policiesVC.initialTab = EZPolicyTabTerms;
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:policiesVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)acceptTapped {
    [EZTermsAcceptanceViewController recordAcceptance];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)declineTapped {
    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Decline Terms?"
                         message:@"You must accept the Terms of Service and Privacy Policy to use "
                                  "EZCompleteAI. Declining will sign you out."
                  preferredStyle:UIAlertControllerStyleAlert];

    [confirm addAction:[UIAlertAction
        actionWithTitle:@"Decline & Sign Out"
                  style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {
        [[EZAuthManager shared] signOut];
        [self dismissViewControllerAnimated:YES completion:^{
            UIWindow *window = [UIApplication sharedApplication].windows.firstObject;
            LoginViewController *loginVC = [[LoginViewController alloc] init];
            [UIView transitionWithView:window
                              duration:0.3
                               options:UIViewAnimationOptionTransitionCrossDissolve
                            animations:^{ window.rootViewController = loginVC; }
                            completion:nil];
        }];
    }]];

    [confirm addAction:[UIAlertAction
        actionWithTitle:@"Go Back"
                  style:UIAlertActionStyleCancel
                handler:nil]];

    [self presentViewController:confirm animated:YES completion:nil];
}

@end
