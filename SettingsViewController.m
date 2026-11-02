    // SettingsViewController.m
    // EZCompleteUI v1.4
    //
    // Changes from v1.3:
    //   - Replaced "Donate via PayPal" button and method with "Legal & Policies"
    //     button that opens EZPoliciesViewController (Terms / Privacy / Refund).
    //   - Added #import for EZPoliciesViewController.
    //   - donate method removed (app now has a coin store; donation button obsolete).

    #import "SettingsViewController.h"
    #import "MemoriesViewController.h"
    #import "TextToSpeechViewController.h"
    #import "ElevenLabsCloneViewController.h"
    #import "SupportRequestViewController.h"
    #import "LoginViewController.h"
    #import "EZCoinStoreViewController.h"
    #import "EZPoliciesViewController.h"
    #import "EZAuthManager.h"
    #import "EZEntitlementManager.h"
    #import "EZReferralManager.h"
    #import "helpers.h"
    #import <SafariServices/SafariServices.h>

    static NSString * const kHelperTemperatureDefaultsKey = @"helperTemperature";
    static NSString * const kSpeedModeDefaultsKey       = @"fastMode";

    // Speed modes in segment order. Index 1 (@"standard") is the default and
    // sends no service tier; the others map to service_tier in ez-chat.
    static NSArray<NSString *> *EZSpeedModeValues(void) {
        return @[@"flex", @"standard", @"fast", @"ultrafast"];
    }

    // PayPal sandbox plan ID — replace with live Plan ID before release
    static NSString * const kPayPalPlanID = @"P-1HW38522AL709604TNHUUASA";

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Private interface
    // ─────────────────────────────────────────────────────────────────────────────

    @interface SettingsViewController () <UITextFieldDelegate, UITextViewDelegate,
                                          SFSafariViewControllerDelegate>

    // ── Scroll container ──────────────────────────────────────────────────────────
    @property (nonatomic, strong) UIScrollView *scrollView;

    // ── Subscription ──────────────────────────────────────────────────────────────
    @property (nonatomic, strong) UILabel  *subscriptionStatusLabel;
    @property (nonatomic, strong) UILabel  *coinBalanceLabel;
    @property (nonatomic, strong) UILabel  *referralCodeLabel;

    // ── System prompt ─────────────────────────────────────────────────────────────
    @property (nonatomic, strong) UITextView   *systemMsgView;
    @property (nonatomic, assign) CGFloat       systemMsgViewHeight;

    // ── Sliders ───────────────────────────────────────────────────────────────────
    @property (nonatomic, strong) UISlider     *tempSlider;
    @property (nonatomic, strong) UISlider     *helperTempSlider;
    @property (nonatomic, strong) UISlider     *freqSlider;
    @property (nonatomic, strong) UILabel      *tempLabel;
    @property (nonatomic, strong) UILabel      *helperTempLabel;
    @property (nonatomic, strong) UILabel      *freqLabel;

    // ── Speed mode ────────────────────────────────────────────────────────────────
    @property (nonatomic, strong) UISegmentedControl *speedModeControl;

    // ── Web search ────────────────────────────────────────────────────────────────
    @property (nonatomic, strong) UITextField  *webLocationField;
    @property (nonatomic, strong) UISwitch     *webSearchSwitch;

    // ── ElevenLabs TTS ────────────────────────────────────────────────────────────
    @property (nonatomic, strong) UITextField  *elVoiceField;

    // ── ElevenLabs Voice Cloning ──────────────────────────────────────────────────

/*
    // ── Sora video ────────────────────────────────────────────────────────────────
    @property (nonatomic, strong) UITextField  *soraModelField;
    @property (nonatomic, strong) UITextField  *soraSizeField;
    @property (nonatomic, strong) UISlider     *soraDurationSlider;
    @property (nonatomic, strong) UILabel      *soraDurationLabel;
**/
    @end


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Implementation
    // ─────────────────────────────────────────────────────────────────────────────

    @implementation SettingsViewController

    - (void)viewDidLoad {
        [super viewDidLoad];
        self.title = @"Settings";
        self.view.backgroundColor = [UIColor systemBackgroundColor];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                 target:self
                                 action:@selector(saveAndClose)];

        [self setupUI];
        [self loadSettings];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(keyboardShow:)
                   name:UIKeyboardWillShowNotification object:nil];
        [nc addObserver:self selector:@selector(keyboardHide:)
                   name:UIKeyboardWillHideNotification object:nil];
        [nc addObserver:self selector:@selector(keyboardShow:)
                   name:UIKeyboardWillChangeFrameNotification object:nil];
        [nc addObserver:self selector:@selector(refreshSubscriptionDisplay)
                   name:@"EZSubscriptionUpdated" object:nil];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(dismissKeyboard)];
        tap.cancelsTouchesInView = NO;
        [self.scrollView addGestureRecognizer:tap];

        EZLog(EZLogLevelInfo, @"SETTINGS", @"Settings opened");
    }

    - (void)viewWillAppear:(BOOL)animated {
        [super viewWillAppear:animated];
        [self refreshSubscriptionDisplay];
        [EZReferralManager applyPendingReferralCode];
        [self refreshReferralCodeLabel];
    }

    - (void)dealloc {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }

    - (void)dismissKeyboard {
        [self.view endEditing:YES];
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Keyboard handling
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)keyboardShow:(NSNotification *)notification {
        CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        UIEdgeInsets insets  = UIEdgeInsetsMake(0, 0, keyboardFrame.size.height, 0);
        self.scrollView.contentInset          = insets;
        self.scrollView.scrollIndicatorInsets = insets;
    }

    - (void)keyboardHide:(NSNotification *)notification {
        self.scrollView.contentInset          = UIEdgeInsetsZero;
        self.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
    }

    - (BOOL)textFieldShouldReturn:(UITextField *)textField {
        [textField resignFirstResponder];
        return YES;
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - API Key field masking
    // ─────────────────────────────────────────────────────────────────────────────


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - UI Setup
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)setupUI {
        self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
        self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:self.scrollView];

        CGFloat w = self.view.frame.size.width - 40;
        CGFloat y = 20;

        // ── App Version ──────────────────────────────────────────────────────────
        NSDictionary *infoPlist  = [NSBundle mainBundle].infoDictionary;
        NSString *appVersion     = infoPlist[@"CFBundleShortVersionString"] ?: @"?";
        NSString *buildNumber    = infoPlist[@"CFBundleVersion"]            ?: @"?";
        UILabel *versionLabel    = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 20)];
        versionLabel.text        = [NSString stringWithFormat:@"EZCompleteUI  v%@  (build %@)",
                                     appVersion, buildNumber];
        versionLabel.font        = [UIFont systemFontOfSize:12];
        versionLabel.textColor   = [UIColor tertiaryLabelColor];
        versionLabel.textAlignment = NSTextAlignmentCenter;
        [self.scrollView addSubview:versionLabel];
        y += 30;

        // ── Subscription ─────────────────────────────────────────────────────────
        [self addSection:@"💎 Subscription" y:&y];

        self.subscriptionStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 20)];
        self.subscriptionStatusLabel.font = [UIFont systemFontOfSize:13];
        self.subscriptionStatusLabel.textColor = [UIColor secondaryLabelColor];
        self.subscriptionStatusLabel.text = @"Loading...";
        [self.scrollView addSubview:self.subscriptionStatusLabel];
        y += 26;

        self.coinBalanceLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y, w, 20)];
        self.coinBalanceLabel.font = [UIFont systemFontOfSize:13];
        self.coinBalanceLabel.textColor = [UIColor secondaryLabelColor];
        self.coinBalanceLabel.text = @"";
        [self.scrollView addSubview:self.coinBalanceLabel];
        y += 30;

        [self addButton:@"💎 Subscribe / Manage Subscription"
                  color:[UIColor systemBlueColor]
                 action:@selector(openSubscribePage)
                      y:&y w:w];

        [self addButton:@"🔄 Restore / Refresh Subscription"
                  color:[UIColor systemGreenColor]
                 action:@selector(refreshSubscription)
                      y:&y w:w];

        [self addButton:@"🚪 Sign Out"
                  color:[UIColor systemGrayColor]
                 action:@selector(signOut)
                      y:&y w:w];

        // ── Invite Friends ───────────────────────────────────────────────────────
        [self addSection:@"🎁 Invite Friends" y:&y];
        self.referralCodeLabel = [self addLabel:@"Your referral code: …" y:&y];
        [self addLabel:@"Friends who sign up with your code get 200 free coins — and so do you." y:&y];
        [self addButton:@"📋 Copy My Referral Code"
                  color:[UIColor systemTealColor]
                 action:@selector(copyReferralCode)
                      y:&y w:w];
        [self addButton:@"📤 Share EZCompleteUI"
                  color:[UIColor systemIndigoColor]
                 action:@selector(shareApp)
                      y:&y w:w];

        // ── OpenAI ───────────────────────────────────────────────────────────────
        // ── Model Preferences ─────────────────────────────────────────────────────
        [self addLabel:@"Model Preferences (Optional):" y:&y];

        CGFloat minTextViewHeight = 80.0;
        self.systemMsgView = [[UITextView alloc] initWithFrame:CGRectMake(20, y, w, minTextViewHeight)];
        self.systemMsgView.font          = [UIFont systemFontOfSize:14];
        self.systemMsgView.delegate      = self;
        self.systemMsgView.layer.cornerRadius  = 8;
        self.systemMsgView.layer.borderWidth   = 1.0;
        self.systemMsgView.layer.borderColor   = [UIColor systemGray4Color].CGColor;
        self.systemMsgView.backgroundColor     = [UIColor secondarySystemBackgroundColor];
        self.systemMsgView.textContainerInset  = UIEdgeInsetsMake(8, 6, 8, 6);
        self.systemMsgView.scrollEnabled       = NO;
        self.systemMsgViewHeight               = minTextViewHeight;
        [self.scrollView addSubview:self.systemMsgView];
        y += minTextViewHeight + 10;

        // ── Sliders ───────────────────────────────────────────────────────────────
        self.tempLabel  = [self addLabel:@"Temperature: 0.70" y:&y];
        self.tempSlider = [self addSlider:w y:&y min:0 max:2];
        self.helperTempLabel  = [self addLabel:@"Helper Temperature: 0.20" y:&y];
        self.helperTempSlider = [self addSlider:w y:&y min:0 max:0.5f];
        self.freqLabel  = [self addLabel:@"Freq Penalty: 0.00" y:&y];
        self.freqSlider = [self addSlider:w y:&y min:-2 max:2];

        // ── Speed Mode ────────────────────────────────────────────────────────────
        [self addSection:@"⚡ Speed" y:&y];
        [self addLabel:@"Response speed:" y:&y];
        self.speedModeControl = [[UISegmentedControl alloc] initWithItems:@[@"Flex", @"Normal", @"Fast", @"Ultrafast"]];
        self.speedModeControl.frame = CGRectMake(20, y, w, 32);
        [self.scrollView addSubview:self.speedModeControl];
        y += 42;
        [self addLabel:@"Flex: slower, half price · Fast: 2× · Ultrafast: 6× (Sol & Astra only)" y:&y];

        // ── Web Search ────────────────────────────────────────────────────────────
        [self addSection:@"🌐 Web Search" y:&y];
        [self addLabel:@"Enable web search by default:" y:&y];
        self.webSearchSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 30, y - 28, 51, 31)];
        [self.scrollView addSubview:self.webSearchSwitch];
        [self addLabel:@"Location hint (optional city):" y:&y];
        self.webLocationField = [self addField:w y:&y placeholder:@"e.g. Miami, FL"];

        // ── ElevenLabs TTS ────────────────────────────────────────────────────────
        [self addSection:@"🎙 ElevenLabs TTS" y:&y];
        [self addLabel:@"Voice ID (preset or cloned):" y:&y];
        self.elVoiceField = [self addField:w y:&y placeholder:@"Voice ID"];

        [self addButton:@"🔊 Open Text to Speech"
                  color:[UIColor systemCyanColor]
                 action:@selector(openTextToSpeech)
                      y:&y w:w];

        // ── ElevenLabs Voice Cloning ──────────────────────────────────────────────
        [self addSection:@"🎤 Voice Cloning (ElevenLabs)" y:&y];
        [self addLabel:@"Upload an audio sample to create a custom voice clone." y:&y];
        [self addButton:@"🎤 Voice Cloning & Management"
                  color:[UIColor systemPurpleColor]
                 action:@selector(openElevenLabsCloneVC)
                      y:&y w:w];

        // The app's voice features run on ElevenLabs; users who want their
        // own account go through the affiliate link (disclosed, as the
        // affiliate program's terms require).
        [self addButton:@"🎧 Get ElevenLabs"
                  color:[UIColor systemOrangeColor]
                 action:@selector(openElevenLabsAffiliate)
                      y:&y w:w];
        [self addLabel:@"Affiliate link — I may earn a commission at no extra cost to you." y:&y];

        y += 35;
/*
        // ── Sora Text-to-Video ────────────────────────────────────────────────────
        [self addSection:@"🎬 Sora Text-to-Video" y:&y];

        [self addLabel:@"Model:" y:&y];
        self.soraModelField = [self addField:w y:&y placeholder:@"sora-2"];
        self.soraModelField.userInteractionEnabled = NO;
        UIButton *soraModelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        soraModelBtn.frame = CGRectMake(w - 74, y - 50, 84, 40);
        [soraModelBtn setTitle:@"Choose" forState:UIControlStateNormal];
        [soraModelBtn addTarget:self action:@selector(pickSoraModel)
              forControlEvents:UIControlEventTouchUpInside];
        [self.scrollView addSubview:soraModelBtn];

        [self addLabel:@"Resolution:" y:&y];
        self.soraSizeField = [self addField:w y:&y placeholder:@"1280x720"];
        self.soraSizeField.userInteractionEnabled = NO;
        UIButton *soraResBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        soraResBtn.frame = CGRectMake(w - 74, y - 50, 84, 40);
        [soraResBtn setTitle:@"Choose" forState:UIControlStateNormal];
        [soraResBtn addTarget:self action:@selector(pickSoraResolution)
             forControlEvents:UIControlEventTouchUpInside];
        [self.scrollView addSubview:soraResBtn];

        self.soraDurationLabel = [self addLabel:
            @"Duration: 4s  (sora-2: 4/8/12/16s  •  sora-2-pro: 5/10/15/20s)" y:&y];
        self.soraDurationSlider = [self addSlider:w y:&y min:1 max:20];
        [self.soraDurationSlider addTarget:self action:@selector(updateVideoLabels)
                          forControlEvents:UIControlEventValueChanged];
*/
        // ── AI Memory ─────────────────────────────────────────────────────────────
        [self addSection:@"🧠 AI Memory" y:&y];
        y += 8;
        [self addButton:@"📖 View / Edit Memories"
                  color:[UIColor systemGreenColor]
                 action:@selector(openMemoriesViewer)
                      y:&y w:w];
        [self addButton:@"Clear All Memories"
                  color:[UIColor systemOrangeColor]
                 action:@selector(confirmClearMemories)
                      y:&y w:w];
        [self addButton:@"View Helper Stats"
                  color:[UIColor systemIndigoColor]
                 action:@selector(showHelperStats)
                      y:&y w:w];
        [self addButton:@"📄 Legal & Policies"
                  color:[UIColor systemIndigoColor]
                 action:@selector(openPolicies)
                      y:&y w:w];
        [self addButton:@"📬 Support & Feedback"
                  color:[UIColor systemTealColor]
                 action:@selector(openSupportRequest)
                      y:&y w:w];

        self.scrollView.contentSize = CGSizeMake(self.view.frame.size.width, y + 30);
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Subscription
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)refreshSubscriptionDisplay {
        [[EZEntitlementManager shared] refreshSubscriptionStatusWithCompletion:
         ^(BOOL refreshed, NSInteger balance) {
            dispatch_async(dispatch_get_main_queue(), ^{
                EZEntitlementManager *entitlements = [EZEntitlementManager shared];
                NSString *tier   = entitlements.currentTier;
                NSString *status = entitlements.currentStatus;
                BOOL isActive = tier.length > 0 && [status isEqualToString:@"active"];

                if (!refreshed) {
                    self.subscriptionStatusLabel.text = @"⚠️ Unable to verify subscription";
                    self.subscriptionStatusLabel.textColor = [UIColor systemOrangeColor];
                } else if (isActive) {
                    self.subscriptionStatusLabel.text = [NSString stringWithFormat:
                        @"✅ Active — %@ plan", tier.capitalizedString];
                    self.subscriptionStatusLabel.textColor = [UIColor systemGreenColor];
                } else {
                    self.subscriptionStatusLabel.text = [status isEqualToString:@"coins_only"]
                        ? @"🪙 Coins only — no active subscription"
                        : @"❌ No active subscription";
                    self.subscriptionStatusLabel.textColor = [UIColor secondaryLabelColor];
                }
                self.coinBalanceLabel.text = [NSString stringWithFormat:
                    @"🪙 Coin balance: %ld", (long)balance];
            });
        }];
    }

- (void)refreshReferralCodeLabel {
    NSString *cached = [EZReferralManager cachedReferralCode];
    if (cached.length) {
        self.referralCodeLabel.text = [NSString stringWithFormat:@"Your referral code: %@", cached];
    }
    [EZReferralManager fetchReferralCodeWithCompletion:^(NSString *code) {
        if (code.length) {
            self.referralCodeLabel.text = [NSString stringWithFormat:@"Your referral code: %@", code];
        }
    }];
}

- (void)copyReferralCode {
    [EZReferralManager fetchReferralCodeWithCompletion:^(NSString *code) {
        if (!code.length) return;
        [UIPasteboard generalPasteboard].string = code;
        self.referralCodeLabel.text = [NSString stringWithFormat:@"Your referral code: %@ (copied)", code];
    }];
}

- (void)shareApp {
    [EZReferralManager fetchReferralCodeWithCompletion:^(NSString *code) {
        NSString *message = [EZReferralManager shareMessageWithReferralCode:code];
        UIActivityViewController *share = [[UIActivityViewController alloc]
            initWithActivityItems:@[message] applicationActivities:nil];
        share.popoverPresentationController.sourceView = self.view;
        share.popoverPresentationController.sourceRect =
            CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
        [self presentViewController:share animated:YES completion:nil];
    }];
}

- (void)openElevenLabsAffiliate {
    NSURL *url = [NSURL URLWithString:[EZReferralManager elevenLabsAffiliateURL]];
    if (url) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)openSubscribePage {
    [self openCoinStore:NO featureName:nil];
}

- (void)openCoinStore:(BOOL)showLowCoinsWarning featureName:(NSString * _Nullable)featureName {
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) {
        [self showAlert:@"Not logged in" message:@"Please sign in first."];
        return;
    }
    EZCoinStoreViewController *store = [[EZCoinStoreViewController alloc] init];
    store.showLowCoinsWarning  = showLowCoinsWarning;
    store.triggeringFeatureName = featureName;
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:store];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    // Refresh subscription display when store closes
    __weak typeof(self) weakSelf = self;
    nav.presentationController.delegate = (id<UIAdaptivePresentationControllerDelegate>)weakSelf;
    [self presentViewController:nav animated:YES completion:nil];
}

    - (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self refreshSubscriptionDisplay];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"EZSubscriptionUpdated" object:nil];
        });
    }

    - (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
        // Called when EZCoinStoreViewController is dismissed — refresh balance
        [self refreshSubscriptionDisplay];
    }

    - (void)refreshSubscription {
        self.subscriptionStatusLabel.text      = @"Checking...";
        self.subscriptionStatusLabel.textColor = [UIColor secondaryLabelColor];
        [self refreshSubscriptionDisplay];
    }

    - (void)signOut {
        UIAlertController *confirm = [UIAlertController
            alertControllerWithTitle:@"Sign Out?"
                             message:@"You will need to sign in again to use EZCompleteUI."
                      preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Sign Out"
                                                   style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction *a) {
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
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                   style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:confirm animated:YES completion:nil];
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - UITextViewDelegate (system prompt auto-expand)
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)textViewDidChange:(UITextView *)textView {
        if (textView != self.systemMsgView) return;
        [self resizeSystemMsgView];
    }

    - (void)resizeSystemMsgView {
        CGFloat w    = self.view.frame.size.width - 40;
        CGFloat minH = 80.0;

        CGSize sizeThatFits = [self.systemMsgView sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
        CGFloat newH = MAX(minH, sizeThatFits.height);

        if (ABS(newH - self.systemMsgViewHeight) < 1.0) return;

        CGFloat delta        = newH - self.systemMsgViewHeight;
        self.systemMsgViewHeight = newH;

        CGRect tvFrame       = self.systemMsgView.frame;
        tvFrame.size.height  = newH;
        self.systemMsgView.frame = tvFrame;

        CGFloat tvBottom = CGRectGetMaxY(tvFrame);
        for (UIView *sub in self.scrollView.subviews) {
            if (sub == self.systemMsgView) continue;
            if (sub.frame.origin.y >= tvBottom - delta - 1) {
                CGRect f   = sub.frame;
                f.origin.y += delta;
                sub.frame  = f;
            }
        }

        CGSize cs   = self.scrollView.contentSize;
        cs.height  += delta;
        self.scrollView.contentSize = cs;
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - UI Helper Methods
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)addSection:(NSString *)title y:(CGFloat *)y {
        *y += 10;
        UILabel *label  = [[UILabel alloc] initWithFrame:
                           CGRectMake(20, *y, self.view.frame.size.width - 40, 28)];
        label.text      = title;
        label.font      = [UIFont boldSystemFontOfSize:15];
        label.textColor = [UIColor systemBlueColor];
        [self.scrollView addSubview:label];
        *y += 34;
    }

    - (UILabel *)addLabel:(NSString *)text y:(CGFloat *)y {
        UILabel *label      = [[UILabel alloc] initWithFrame:
                               CGRectMake(20, *y, self.view.frame.size.width - 40, 20)];
        label.text          = text;
        label.font          = [UIFont systemFontOfSize:13];
        label.textColor     = [UIColor secondaryLabelColor];
        label.numberOfLines = 0;
        [self.scrollView addSubview:label];
        *y += 22;
        return label;
    }

    - (UITextField *)addField:(CGFloat)width y:(CGFloat *)y placeholder:(NSString *)placeholder {
        UITextField *field  = [[UITextField alloc] initWithFrame:CGRectMake(20, *y, width, 40)];
        field.borderStyle   = UITextBorderStyleRoundedRect;
        field.placeholder   = placeholder;
        field.delegate      = self;
        field.returnKeyType = UIReturnKeyDone;
        field.font          = [UIFont systemFontOfSize:14];
        [self.scrollView addSubview:field];
        *y += 50;
        return field;
    }

    - (UISlider *)addSlider:(CGFloat)width y:(CGFloat *)y min:(float)minVal max:(float)maxVal {
        UISlider *slider    = [[UISlider alloc] initWithFrame:CGRectMake(20, *y, width, 30)];
        slider.minimumValue = minVal;
        slider.maximumValue = maxVal;
        [slider addTarget:self action:@selector(updateLabels)
         forControlEvents:UIControlEventValueChanged];
        [self.scrollView addSubview:slider];
        *y += 45;
        return slider;
    }

    - (void)addButton:(NSString *)title color:(UIColor *)color action:(SEL)action
                    y:(CGFloat *)y w:(CGFloat)width {
        UIButton *button          = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame              = CGRectMake(20, *y, width, 44);
        button.backgroundColor    = color;
        button.tintColor          = [UIColor whiteColor];
        button.layer.cornerRadius = 10;
        [button setTitle:title forState:UIControlStateNormal];
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        [self.scrollView addSubview:button];
        *y += 55;
    }

    - (void)updateLabels {
        self.tempLabel.text = [NSString stringWithFormat:@"Temperature: %.2f",
                               self.tempSlider.value];
        self.helperTempLabel.text = [NSString stringWithFormat:@"Helper Temperature: %.2f",
                                     self.helperTempSlider.value];
        self.freqLabel.text = [NSString stringWithFormat:@"Freq Penalty: %.2f",
                               self.freqSlider.value];
    }
/*
    - (void)updateVideoLabels {
        NSString *model = self.soraModelField.text ?: @"sora-2";
        BOOL      isPro = [model isEqualToString:@"sora-2-pro"];
        NSInteger raw   = (NSInteger)self.soraDurationSlider.value;

        NSArray<NSNumber *> *validDurations = isPro
            ? @[@5, @10, @15, @20]
            : @[@4, @8, @12, @16];

        NSInteger snapped  = validDurations.firstObject.integerValue;
        NSInteger bestDiff = NSIntegerMax;
        for (NSNumber *v in validDurations) {
            NSInteger diff = ABS(raw - v.integerValue);
            if (diff < bestDiff) { bestDiff = diff; snapped = v.integerValue; }
        }
        NSString *hint = isPro ? @"(5/10/15/20s)" : @"(4/8/12/16s)";
        self.soraDurationLabel.text = [NSString stringWithFormat:@"Duration: %lds %@",
                                       (long)snapped, hint];
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Sora Model / Resolution Pickers
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)pickSoraModel {
        UIAlertController *sheet = [UIAlertController
            alertControllerWithTitle:@"Sora Model"
                             message:nil
                      preferredStyle:UIAlertControllerStyleActionSheet];
        NSDictionary *descriptions = @{
            @"sora-2":     @"Fast, flexible — 4/8/12/16s",
            @"sora-2-pro": @"High fidelity — 5/10/15/20s"
        };
        for (NSString *model in @[@"sora-2", @"sora-2-pro"]) {
            NSString *title = [NSString stringWithFormat:@"%@  (%@)", model, descriptions[model]];
            [sheet addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *a) {
                self.soraModelField.text = model;
                [self updateVideoLabels];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
    }

    - (void)pickSoraResolution {
        UIAlertController *sheet = [UIAlertController
            alertControllerWithTitle:@"Video Size"
                             message:nil
                      preferredStyle:UIAlertControllerStyleActionSheet];
        NSDictionary *descriptions = @{
            @"1280x720":  @"Landscape 720p  (recommended)",
            @"1792x1024": @"Landscape wide  (cinematic)",
            @"720x1280":  @"Portrait 720p   (social/reels)",
            @"1024x1792": @"Portrait tall   (stories)"
        };
        for (NSString *res in @[@"1280x720", @"1792x1024", @"720x1280", @"1024x1792"]) {
            NSString *title = [NSString stringWithFormat:@"%@  —  %@", res, descriptions[res]];
            [sheet addAction:[UIAlertAction actionWithTitle:title
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *a) {
                self.soraSizeField.text = res;
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
    }
***/

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - ElevenLabs Voice Fetching
    // ─────────────────────────────────────────────────────────────────────────────


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Memory & Stats Actions
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)openElevenLabsCloneVC {
        ElevenLabsCloneViewController *vc = [[ElevenLabsCloneViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc]
                                       initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:nav animated:YES completion:nil];
    }

    - (void)openSupportRequest {
        SupportRequestViewController *vc = [[SupportRequestViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc]
                                       initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:nav animated:YES completion:nil];
    }

    - (void)openTextToSpeech {
        TextToSpeechViewController *vc = [[TextToSpeechViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc]
                                       initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:nav animated:YES completion:nil];
    }

    - (void)openMemoriesViewer {
        MemoriesViewController *vc = [[MemoriesViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc]
                                       initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:nav animated:YES completion:nil];
    }

    - (void)confirmClearMemories {
        UIAlertController *confirm = [UIAlertController
            alertControllerWithTitle:@"Clear All Memories?"
                             message:@"This deletes all saved conversation summaries. Cannot be undone."
                      preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                                   style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction *a) {
            BOOL cleared   = clearMemoryLog();
            NSString *msg  = cleared ? @"All memories cleared." : @"Error clearing memories.";
            [self showAlert:@"Memory" message:msg];
        }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                   style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:confirm animated:YES completion:nil];
    }

    - (void)showHelperStats {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"EZHelper Stats"
                             message:EZHelperStats()
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Copy"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            [UIPasteboard generalPasteboard].string = EZHelperStats();
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                 style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Legal & Policies
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)openPolicies {
        EZPoliciesViewController *policiesVC = [EZPoliciesViewController new];
        policiesVC.initialTab = EZPolicyTabTerms;
        UINavigationController *nav = [[UINavigationController alloc]
            initWithRootViewController:policiesVC];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:nav animated:YES completion:nil];
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Load / Save Settings
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)loadSettings {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        // ── Non-sensitive settings ────────────────────────────────────────────────
        self.systemMsgView.text       = [defaults stringForKey:@"modelPreferences"] ?: @"";
        self.tempSlider.value         = [defaults floatForKey:@"temperature"] ?: 0.7f;
        id helperTempRaw = [defaults objectForKey:kHelperTemperatureDefaultsKey];
        float helperTemp = [helperTempRaw respondsToSelector:@selector(floatValue)]
            ? [helperTempRaw floatValue] : 0.2f;
        self.helperTempSlider.value   = MIN(0.5f, MAX(0.0f, helperTemp));
        self.freqSlider.value         = [defaults floatForKey:@"frequency"];
        self.elVoiceField.text        = [defaults stringForKey:@"elevenVoiceID"];
        self.webSearchSwitch.on       = [defaults boolForKey:@"webSearchEnabled"];
        NSUInteger savedSpeedIdx      = [EZSpeedModeValues() indexOfObject:[defaults stringForKey:kSpeedModeDefaultsKey] ?: @"standard"];
        self.speedModeControl.selectedSegmentIndex = (savedSpeedIdx == NSNotFound) ? 1 : (NSInteger)savedSpeedIdx;
        self.webLocationField.text    = [defaults stringForKey:@"webSearchLocation"];
   //     self.soraModelField.text      = [defaults stringForKey:@"soraModel"]   ?: @"sora-2";
   //     self.soraSizeField.text       = [defaults stringForKey:@"soraSize"]    ?: @"1280x720";
     //  self.soraDurationSlider.value = (float)([defaults integerForKey:@"soraDuration"] ?: 4);

        [self updateLabels];
      //  [self updateVideoLabels];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self resizeSystemMsgView];
        });
    }

    - (void)saveAndClose {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        [defaults setObject:self.systemMsgView.text     forKey:@"modelPreferences"];
        [defaults setFloat:self.tempSlider.value        forKey:@"temperature"];
        [defaults setFloat:self.helperTempSlider.value  forKey:kHelperTemperatureDefaultsKey];
        [defaults setFloat:self.freqSlider.value        forKey:@"frequency"];
        [defaults setObject:self.elVoiceField.text      forKey:@"elevenVoiceID"];
        [defaults setBool:self.webSearchSwitch.isOn     forKey:@"webSearchEnabled"];
        [defaults setObject:EZSpeedModeValues()[(NSUInteger)self.speedModeControl.selectedSegmentIndex] forKey:kSpeedModeDefaultsKey];
        [defaults setObject:self.webLocationField.text  forKey:@"webSearchLocation"];
      //  [defaults setObject:self.soraModelField.text    forKey:@"soraModel"];
      //  [defaults setObject:self.soraSizeField.text     forKey:@"soraSize"];
      //  [defaults setInteger:(NSInteger)self.soraDurationSlider.value forKey:@"soraDuration"];
        [defaults synchronize];

        EZLog(EZLogLevelInfo, @"SETTINGS", @"Settings saved");
        [self dismissViewControllerAnimated:YES completion:nil];
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Utility
    // ─────────────────────────────────────────────────────────────────────────────

    - (void)showAlert:(NSString *)title message:(NSString *)message {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:title
                                 message:message
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }

    @end
