// EZPoliciesViewController.m
// EZPoliciesViewController.m
// EZCompleteUI v1.1
//
// Changes from v1.0:
//   - Support email now loaded from EZKeyVault (EZVaultKeySupportEmail) at
//     runtime instead of a hardcoded placeholder. Falls back to
//     "support@ezcompleteui.com" if the vault entry is not yet seeded.
#import "EZKeyVault.h"
#import <SafariServices/SafariServices.h>
#import <UIKit/UIKit.h>
#import "EZPoliciesViewController.h"
// ── Canonical web URLs ────────────────────────────────────────────────────────
// Update these once pages are published on WordPress.
static NSString *const kTermsURL   = @"https://yoursite.com/terms-of-service";
static NSString *const kPrivacyURL = @"https://yoursite.com/privacy-policy";
static NSString *const kRefundURL  = @"https://yoursite.com/refund-policy";

// ── Effective date shown in each policy ───────────────────────────────────────
static NSString *const kPolicyDate = @"September 18, 2026";

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Policy text
// ─────────────────────────────────────────────────────────────────────────────
/*
static NSString *EZTermsText(void) {
    return
    @"TERMS OF SERVICE\n"
    @"EZCompleteAI\n"
    @"Effective: "  kPolicyDate appended at call site
    ;
}
*/
// ── Support email ─────────────────────────────────────────────────────────────
// Loaded from the keychain at runtime; never hardcoded in source.
static NSString *EZSupportEmail(void) {
    NSString *email = [EZKeyVault loadKeyForIdentifier:EZVaultKeySupportEmail];
    return email.length ? email : @"support@ezcompleteui.com";
}

// We build the full strings at runtime so we can insert the date and email cleanly.
static NSString *EZFullTermsText(void) {
    return [NSString stringWithFormat:
    @"TERMS OF SERVICE — EZCompleteAI\n"
    @"Effective: %@\n"
    @"Developer: Brian Nooning (ios_tweak3r)\n\n"

    @"1. AGREEMENT\n"
    @"By using EZCompleteAI you agree to these Terms. If you disagree, do not use the app.\n\n"

    @"2. SERVICE DESCRIPTION\n"
    @"EZCompleteAI provides AI-powered tools (chat, image generation, video, text-to-speech) "
    @"via a virtual coin system. Coins are purchased within the app and consumed when features are used.\n\n"

    @"3. ELIGIBILITY\n"
    @"You must be at least 13 years old to use the app.\n\n"

    @"4. COIN PURCHASES\n"
    @"Coins are virtual currency with no cash value. All purchases are final and non-refundable "
    @"except as described in the Refund Policy. Coins do not expire while your account is active.\n\n"

    @"5. ACCEPTABLE USE\n"
    @"You agree not to use the app to generate illegal, harmful, or abusive content; "
    @"reverse-engineer or tamper with the app; circumvent coin deductions; or violate any law. "
    @"Violations may result in account termination without refund.\n\n"

    @"6. AI-GENERATED CONTENT\n"
    @"AI content may be inaccurate or incomplete. You are solely responsible for how you use it. "
    @"Content is also subject to OpenAI's and ElevenLabs' terms.\n\n"

    @"7. THIRD-PARTY SERVICES\n"
    @"The app relies on OpenAI, ElevenLabs, Supabase, Resend, Cloudflare, and Namecheap to operate "
    @"features, accounts, transactional email, and domain/network infrastructure. Your use is also governed "
    @"by their applicable terms and privacy policies.\n\n"

    @"8. DISCLAIMERS\n"
    @"The app is provided \"as is\" without warranties of any kind.\n\n"

    @"9. LIMITATION OF LIABILITY\n"
    @"Our total liability shall not exceed the amount you paid for coins in the prior 12 months.\n\n"

    @"10. GOVERNING LAW\n"
    @"These Terms are governed by Florida law. Disputes resolved in Monroe County, Florida courts.\n\n"

    @"11. CHANGES\n"
    @"We may update these Terms and will notify you of material changes through the app or by email.\n\n"

    @"Contact: %@\n",
    kPolicyDate, EZSupportEmail()];
}

static NSString *EZFullPrivacyText(void) {
    return [NSString stringWithFormat:
    @"PRIVACY POLICY — EZCompleteAI\n"
    @"Effective: %@\n"
    @"Developer: Brian Nooning (ios_tweak3r)\n\n"

    @"WHAT WE COLLECT\n"
    @"• Account info: email address, hashed password, account dates\n"
    @"• Usage data: features used, coins charged, a short prompt excerpt (up to 120 characters), "
    @"timestamp, success/failure status, coin balance after each request, and your IP address\n"
    @"• Coin transactions: full purchase and deduction ledger\n"
    @"• Support info: app version, iOS version, device model, settings — only when you submit "
    @"a support request\n\n"

    @"HOW WE USE IT\n"
    @"To operate the app, process purchases, resolve support and billing disputes, detect abuse, "
    @"monitor app health, and improve features.\n\n"

    @"WHO CAN SEE YOUR DATA\n\n"

    @"Brian Nooning (ios_tweak3r) — The developer has access to all data described above "
    @"for the purposes of operating the app, monitoring that it is working correctly, "
    @"resolving support requests, and improving the app.\n\n"

    @"OpenAI — When you use chat, image generation, transcription, or video features, your "
    @"prompts are transmitted to OpenAI's API. OpenAI may retain and use this data per their "
    @"privacy policy (openai.com/policies/privacy-policy). By using these features you "
    @"acknowledge your prompts are shared with OpenAI.\n\n"

    @"ElevenLabs — When you use text-to-speech or voice cloning, your text and audio are "
    @"transmitted to ElevenLabs' API. ElevenLabs may retain and use this data per their "
    @"privacy policy (elevenlabs.io/privacy). By using these features you acknowledge your "
    @"content is shared with ElevenLabs.\n\n"

    @"Supabase — Your account data, usage logs, and coin records are stored on Supabase's "
    @"secure hosted database (supabase.com/privacy).\n\n"

    @"Resend — We use Resend to deliver transactional account emails, including signup confirmation "
    @"and password-reset emails. Resend processes the recipient email address, message content needed "
    @"to deliver the email, and delivery-related technical data on our behalf (resend.com/legal/privacy-policy).\n\n"

    @"Cloudflare — Cloudflare provides domain-resolution and network/security services for EZCompleteAI. "
    @"When you access a domain, website, API, or other service routed through Cloudflare, Cloudflare may "
    @"process technical request information such as IP address, traffic-routing data, and device or system "
    @"configuration information (cloudflare.com/policies/privacy). Cloudflare may be used for additional "
    @"network, performance, and security services as the app develops.\n\n"

    @"Namecheap — Namecheap provides domain registration and DNS-related infrastructure for our domain. "
    @"Namecheap may process limited technical DNS or service information needed to operate that infrastructure "
    @"under its privacy policy (namecheap.com/legal/general/privacy-policy). We do not provide Namecheap with "
    @"your EZCompleteAI account profile, prompts, or payment information.\n\n"

    @"NO OTHER SHARING\n"
    @"Beyond the service providers identified above and disclosures required by law, your data is not sold, rented, or shared with anyone. "
    @"We have no advertising networks.\n\n"

    @"DATA RETENTION\n"
    @"Data is retained while your account is active. Deletion requests are fulfilled within "
    @"30 days except where legally required.\n\n"

    @"YOUR RIGHTS\n"
    @"You may request access, correction, deletion, or a copy of your data at any time "
    @"by contacting %@.\n\n"

    @"SECURITY\n"
    @"Passwords are hashed. All data is transmitted over HTTPS/TLS. API keys are stored "
    @"as server-side secrets.\n\n"

    @"CHILDREN\n"
    @"We do not knowingly collect data from anyone under 13.\n\n"

    @"Contact: %@\n",
    kPolicyDate, EZSupportEmail(), EZSupportEmail()];
}

static NSString *EZFullRefundText(void) {
    return [NSString stringWithFormat:
    @"REFUND POLICY — EZCompleteAI\n"
    @"Effective: %@\n"
    @"Developer: Brian Nooning (ios_tweak3r)\n\n"

    @"GENERAL RULE\n"
    @"Coin purchases are non-refundable once coins are consumed, because AI features have a "
    @"real cost each time they run.\n\n"

    @"WHEN YOU ARE ELIGIBLE FOR A REFUND\n"
    @"• A technical error caused coins to be deducted without delivering content\n"
    @"• Coins were deducted multiple times for a single request (duplicate charge bug)\n"
    @"• A confirmed billing error caused the wrong coin amount to be charged\n\n"

    @"NOT ELIGIBLE\n"
    @"• Dissatisfaction with AI-generated content quality\n"
    @"• Accidentally triggering a feature\n"
    @"• Running out of coins faster than expected through normal use\n"
    @"• Requests that succeeded and delivered content\n\n"

    @"HOW TO REQUEST A REFUND\n"
    @"1. Use the in-app Support & Feedback form within 7 days of the issue.\n"
    @"2. Include a description of what happened and attach your coin usage log "
    @"(the toggle in the support form does this automatically).\n"
    @"3. We will review your log against our server records within 5 business days.\n"
    @"4. If an error is confirmed, coins will be restored or a payment refund issued.\n\n"

    @"IMPORTANT: Contact us first before filing a PayPal or Apple dispute. Filing a "
    @"chargeback without contacting us may result in account suspension.\n\n"

    @"APPLE IN-APP PURCHASES\n"
    @"Apple purchases can also be disputed at reportaproblem.apple.com. Apple's payment "
    @"decision is separate from in-app coin balance restoration.\n\n"

    @"Contact: %@\n",
    kPolicyDate, EZSupportEmail()];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - View Controller
// ─────────────────────────────────────────────────────────────────────────────

@interface EZPoliciesViewController () <SFSafariViewControllerDelegate>
@property (nonatomic, strong) UISegmentedControl *segmentedControl;
@property (nonatomic, strong) UITextView         *policyTextView;
@property (nonatomic, strong) UIButton           *webButton;
@end

@implementation EZPoliciesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Legal & Policies";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(closeTapped)];

    [self setupUI];
    [self switchToTab:self.initialTab animated:NO];
}

- (void)setupUI {
    // ── Segmented control ─────────────────────────────────────────────────────
    self.segmentedControl = [[UISegmentedControl alloc]
        initWithItems:@[@"Terms", @"Privacy", @"Refund"]];
    self.segmentedControl.selectedSegmentIndex = self.initialTab;
    self.segmentedControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.segmentedControl addTarget:self
                              action:@selector(segmentChanged:)
                    forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.segmentedControl];

    // ── "View on Web" button ──────────────────────────────────────────────────
    self.webButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.webButton setTitle:@"View on Web ↗" forState:UIControlStateNormal];
    self.webButton.titleLabel.font = [UIFont systemFontOfSize:13];
    self.webButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.webButton addTarget:self action:@selector(openWeb)
             forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.webButton];

    // ── Policy text view ──────────────────────────────────────────────────────
    self.policyTextView = [[UITextView alloc] init];
    self.policyTextView.editable       = NO;
    self.policyTextView.selectable     = YES;
    self.policyTextView.font           = [UIFont systemFontOfSize:14];
    self.policyTextView.textColor      = [UIColor labelColor];
    self.policyTextView.backgroundColor = [UIColor systemBackgroundColor];
    self.policyTextView.textContainerInset = UIEdgeInsetsMake(16, 16, 32, 16);
    self.policyTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.policyTextView];

    // ── Constraints ───────────────────────────────────────────────────────────
    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.segmentedControl.topAnchor
            constraintEqualToAnchor:safeArea.topAnchor constant:12],
        [self.segmentedControl.leadingAnchor
            constraintEqualToAnchor:safeArea.leadingAnchor constant:16],
        [self.segmentedControl.trailingAnchor
            constraintEqualToAnchor:safeArea.trailingAnchor constant:-16],

        [self.webButton.topAnchor
            constraintEqualToAnchor:self.segmentedControl.bottomAnchor constant:8],
        [self.webButton.trailingAnchor
            constraintEqualToAnchor:safeArea.trailingAnchor constant:-16],

        [self.policyTextView.topAnchor
            constraintEqualToAnchor:self.webButton.bottomAnchor constant:4],
        [self.policyTextView.leadingAnchor
            constraintEqualToAnchor:safeArea.leadingAnchor],
        [self.policyTextView.trailingAnchor
            constraintEqualToAnchor:safeArea.trailingAnchor],
        [self.policyTextView.bottomAnchor
            constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    [self switchToTab:(EZPolicyTab)sender.selectedSegmentIndex animated:YES];
}

- (void)switchToTab:(EZPolicyTab)tab animated:(BOOL)animated {
    self.segmentedControl.selectedSegmentIndex = tab;
    NSString *text;
    switch (tab) {
        case EZPolicyTabTerms:   text = EZFullTermsText();   break;
        case EZPolicyTabPrivacy: text = EZFullPrivacyText(); break;
        case EZPolicyTabRefund:  text = EZFullRefundText();  break;
    }
    self.policyTextView.text = text;
    [self.policyTextView scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:animated];
}

- (void)openWeb {
    NSString *urlString;
    switch ((EZPolicyTab)self.segmentedControl.selectedSegmentIndex) {
        case EZPolicyTabTerms:   urlString = kTermsURL;   break;
        case EZPolicyTabPrivacy: urlString = kPrivacyURL; break;
        case EZPolicyTabRefund:  urlString = kRefundURL;  break;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    SFSafariViewController *safariVC = [[SFSafariViewController alloc] initWithURL:url];
    safariVC.delegate = self;
    [self presentViewController:safariVC animated:YES completion:nil];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
