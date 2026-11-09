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
    #import <Vision/Vision.h>

    static NSString * const kHelperTemperatureDefaultsKey = @"helperTemperature";
    static NSString * const kSpeedModeDefaultsKey       = @"fastMode";

    // Speed modes in segment order. Index 1 (@"standard") is the default and
    // sends no service tier; the others map to service_tier in ez-chat.
    static NSArray<NSString *> *EZSpeedModeValues(void) {
        return @[@"flex", @"standard", @"fast", @"ultrafast"];
    }

    // PayPal sandbox plan ID — replace with live Plan ID before release
    static NSString * const kPayPalPlanID = @"P-1HW38522AL709604TNHUUASA";

    // ── NSFW (Seahorse) enrollment helpers ────────────────────────────────
    // Slim copies of the ID picker and the on-device face crop that live in
    // ViewController.m for the chat flow — file-local there, so these are
    // separate statics here. The picker class is renamed because
    // ViewController's EZSeahorseIDPicker is a real Objective-C class and
    // the name cannot repeat at link time.
    @interface EZSettingsSeahorseIDPicker : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
    @property (nonatomic, copy) void (^completion)(UIImage * _Nullable);
    + (void)pickFromViewController:(UIViewController *)presenter
                        completion:(void (^)(UIImage * _Nullable))completion;
    @end

    static EZSettingsSeahorseIDPicker *EZSettingsActiveSeahorsePicker = nil;

    @implementation EZSettingsSeahorseIDPicker

    + (void)pickFromViewController:(UIViewController *)presenter
                        completion:(void (^)(UIImage * _Nullable))completion {
        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
            if (completion) completion(nil);
            return;
        }
        EZSettingsSeahorseIDPicker *picker = [[EZSettingsSeahorseIDPicker alloc] init];
        picker.completion = completion;
        EZSettingsActiveSeahorsePicker = picker;
        UIImagePickerController *ipc = [[UIImagePickerController alloc] init];
        ipc.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        ipc.delegate = picker;
        ipc.allowsEditing = NO;
        [presenter presentViewController:ipc animated:YES completion:nil];
    }

    - (void)imagePickerController:(UIImagePickerController *)picker
            didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
        UIImage *image = info[UIImagePickerControllerOriginalImage];
        void (^completion)(UIImage *) = self.completion;
        [picker dismissViewControllerAnimated:YES completion:^{
            EZSettingsActiveSeahorsePicker = nil;
            if (completion) completion(image);
        }];
    }

    - (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
        void (^completion)(UIImage *) = self.completion;
        [picker dismissViewControllerAnimated:YES completion:^{
            EZSettingsActiveSeahorsePicker = nil;
            if (completion) completion(nil);
        }];
    }

    @end

    // Face-crops an image ON DEVICE (Vision): largest face, head-and-
    // shoulders JPEG, or nil when no usable face is present. Same math as
    // the chat flow's crop — the server compares against crops made this
    // way, so the two must stay in step.
    static NSData * _Nullable EZSettingsSeahorseFaceCropJPEGData(UIImage *image) {
        if (!image) return nil;
        UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
        format.scale = 1.0;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
        UIImage *flat = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
            [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
        }];
        CGImageRef cg = flat.CGImage;
        if (!cg) return nil;

        VNDetectFaceRectanglesRequest *request = [[VNDetectFaceRectanglesRequest alloc] init];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
        NSError *detectError = nil;
        if (![handler performRequests:@[request] error:&detectError]) return nil;

        VNFaceObservation *best = nil;
        CGFloat bestArea = 0;
        for (VNFaceObservation *obs in request.results) {
            CGFloat area = obs.boundingBox.size.width * obs.boundingBox.size.height;
            if (area > bestArea) { bestArea = area; best = obs; }
        }
        if (!best) return nil;

        CGFloat W = (CGFloat)CGImageGetWidth(cg);
        CGFloat H = (CGFloat)CGImageGetHeight(cg);
        CGRect bb = best.boundingBox; // normalized, origin at bottom-left
        CGFloat fx = bb.origin.x * W;
        CGFloat fw = bb.size.width * W;
        CGFloat fh = bb.size.height * H;
        CGFloat fyTop = (1.0 - bb.origin.y - bb.size.height) * H; // top-left origin
        CGRect crop = CGRectMake(fx - fw * 0.45, fyTop - fh * 0.75, fw * 1.9, fh * 2.3);
        crop = CGRectIntersection(crop, CGRectMake(0, 0, W, H));
        if (CGRectIsNull(crop) || crop.size.width < 40 || crop.size.height < 40) return nil;

        CGImageRef croppedRef = CGImageCreateWithImageInRect(cg, crop);
        if (!croppedRef) return nil;
        UIImage *cropImage = [UIImage imageWithCGImage:croppedRef];
        CGImageRelease(croppedRef);
        return UIImageJPEGRepresentation(cropImage, 0.7);
    }


    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Private interface
    // ─────────────────────────────────────────────────────────────────────────────

    @interface SettingsViewController () <UITextFieldDelegate, UITextViewDelegate,
                                          SFSafariViewControllerDelegate>

    // ── Scroll container ──────────────────────────────────────────────────────────
    @property (nonatomic, strong) UIScrollView *scrollView;

    // ── Subscription ──────────────────────────────────────────────────────────────
    @property (nonatomic, strong) UILabel  *subscriptionStatusLabel;
    @property (nonatomic, strong) UILabel  *seahorseStatusLabel;
    @property (nonatomic, strong) UIButton *seahorseSlot1Button;
    @property (nonatomic, strong) UIButton *seahorsePartnerButton;
    @property (nonatomic, strong) UIButton *seahorseRemovePartnerButton;
    @property (nonatomic, strong) UIButton *seahorseRemoveMineButton;
    @property (nonatomic, strong) NSDictionary *seahorseEligibility;
    @property (nonatomic) BOOL seahorseLoaded;
    @property (nonatomic) BOOL seahorseBusy;
    - (UILabel *)addWrappingLabel:(NSString *)text y:(CGFloat *)y minHeight:(CGFloat)minHeight;
    - (UIButton *)addSeahorseButton:(NSString *)title color:(UIColor *)color
                             action:(SEL)action y:(CGFloat *)y w:(CGFloat)width;
    - (void)seahorsePost:(NSDictionary *)body
              completion:(void (^)(NSDictionary * _Nullable json))completion;
    - (void)refreshSeahorseStatus;
    - (BOOL)seahorseSupported;
    - (NSDictionary *)seahorseEnrollmentForSlot:(NSInteger)slot;
    - (BOOL)seahorseSlot:(NSInteger)slot hasFlag:(NSString *)flag;
    - (void)setSeahorseButton:(UIButton *)button enabled:(BOOL)enabled;
    - (void)updateSeahorseUI;
    - (void)seahorseVerifyMineTapped;
    - (void)seahorseVerifyPartnerTapped;
    - (void)seahorseBeginVerifySlot:(NSInteger)slot;
    - (void)seahorseSubmitIDImage:(UIImage *)image slot:(NSInteger)slot
                  alreadyVerified:(BOOL)alreadyVerified;
    - (void)seahorseRemovePartnerTapped;
    - (void)seahorseRemoveMineTapped;
    - (void)seahorseConfirmRemoveSlot:(NSInteger)slot;
    - (void)seahorseRemoveSlot:(NSInteger)slot;
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
        [self refreshSeahorseStatus];
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

        // ── NSFW Images (Seahorse) ────────────────────────────────────
        [self addSection:@"🔞 NSFW Images (Seahorse)" y:&y];
        self.seahorseStatusLabel = [self addWrappingLabel:@"Checking enrollment…"
                                                        y:&y minHeight:40];
        self.seahorseSlot1Button = [self addSeahorseButton:@"Verify My ID"
                                                     color:[UIColor systemIndigoColor]
                                                    action:@selector(seahorseVerifyMineTapped)
                                                         y:&y w:w];
        self.seahorsePartnerButton = [self addSeahorseButton:@"Add a Second ID (Partner)"
                                                       color:[UIColor systemPurpleColor]
                                                      action:@selector(seahorseVerifyPartnerTapped)
                                                           y:&y w:w];
        self.seahorseRemovePartnerButton = [self addSeahorseButton:@"Remove Partner ID"
                                                              color:[UIColor systemOrangeColor]
                                                             action:@selector(seahorseRemovePartnerTapped)
                                                                  y:&y w:w];
        self.seahorseRemoveMineButton = [self addSeahorseButton:@"Remove My ID"
                                                           color:[UIColor systemRedColor]
                                                          action:@selector(seahorseRemoveMineTapped)
                                                               y:&y w:w];
        [self addWrappingLabel:@"Only add a partner who has agreed to have their ID checked and their likeness used in your images. Each ID is read once by AI to check the date of birth and is never stored; only the face crop from the ID photo is kept, privately, with your account."
                             y:&y minHeight:0];

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


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - NSFW (Seahorse) enrollment
    //
    // Manages the ez-seahorse enrollment from Settings: status for both
    // likeness slots, verify/replace an ID, add a partner ID, remove
    // either enrollment. All slot operations are gated on the v1.4
    // server capability (eligibility reports api_version >= 4 with an
    // enrollments array): against an older function, verify_id ignores
    // `slot` and would store a partner's crop over the account holder's,
    // and remove_enrollment does not exist — so on an old server the
    // section explains instead of acting. Settings copy is hard-coded
    // English, per this screen's convention.
    // ─────────────────────────────────────────────────────────────────────────

    - (UILabel *)addWrappingLabel:(NSString *)text y:(CGFloat *)y minHeight:(CGFloat)minHeight {
        UILabel *label      = [[UILabel alloc] initWithFrame:
                               CGRectMake(20, *y, self.view.frame.size.width - 40, 20)];
        label.text          = text;
        label.font          = [UIFont systemFontOfSize:13];
        label.textColor     = [UIColor secondaryLabelColor];
        label.numberOfLines = 0;
        [label sizeToFit];
        if (label.frame.size.height < minHeight) {
            label.frame = CGRectMake(20, *y, self.view.frame.size.width - 40, minHeight);
        }
        [self.scrollView addSubview:label];
        *y += label.frame.size.height + 6;
        return label;
    }

    // addButton: with the button handed back, so its title/enabled state
    // can track the enrollment status.
    - (UIButton *)addSeahorseButton:(NSString *)title color:(UIColor *)color
                             action:(SEL)action y:(CGFloat *)y w:(CGFloat)width {
        UIButton *button          = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame              = CGRectMake(20, *y, width, 44);
        button.backgroundColor    = color;
        button.tintColor          = [UIColor whiteColor];
        button.layer.cornerRadius = 10;
        [button setTitle:title forState:UIControlStateNormal];
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        [self.scrollView addSubview:button];
        *y += 55;
        return button;
    }

    - (void)seahorsePost:(NSDictionary *)body
              completion:(void (^)(NSDictionary * _Nullable json))completion {
        NSString *token = [EZAuthManager shared].accessToken;
        if (!token.length) { if (completion) completion(nil); return; }
        NSURL *url = [NSURL URLWithString:@"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-seahorse"];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        request.timeoutInterval = 60;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSDictionary *json = data.length
                ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![json isKindOfClass:NSDictionary.class]) json = nil;
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(json); });
        }] resume];
    }

    - (void)refreshSeahorseStatus {
        if (!self.seahorseStatusLabel) return;
        [self seahorsePost:@{ @"action": @"eligibility" }
                completion:^(NSDictionary *json) {
            self.seahorseLoaded = YES;
            self.seahorseEligibility = json;
            [self updateSeahorseUI];
        }];
    }

    - (BOOL)seahorseSupported {
        NSNumber *version = [self.seahorseEligibility[@"api_version"] isKindOfClass:NSNumber.class]
            ? self.seahorseEligibility[@"api_version"] : nil;
        return version && [version integerValue] >= 4 &&
               [self.seahorseEligibility[@"enrollments"] isKindOfClass:NSArray.class];
    }

    - (NSDictionary *)seahorseEnrollmentForSlot:(NSInteger)slot {
        NSArray *enrollments = [self.seahorseEligibility[@"enrollments"] isKindOfClass:NSArray.class]
            ? self.seahorseEligibility[@"enrollments"] : nil;
        for (id entry in enrollments) {
            if ([entry isKindOfClass:NSDictionary.class] &&
                [entry[@"slot"] isKindOfClass:NSNumber.class] &&
                [entry[@"slot"] integerValue] == slot) return entry;
        }
        return nil;
    }

    - (BOOL)seahorseSlot:(NSInteger)slot hasFlag:(NSString *)flag {
        NSDictionary *entry = [self seahorseEnrollmentForSlot:slot];
        return [entry[flag] isKindOfClass:NSNumber.class] && [entry[flag] boolValue];
    }

    - (void)setSeahorseButton:(UIButton *)button enabled:(BOOL)enabled {
        button.enabled = enabled;
        button.alpha   = enabled ? 1.0 : 0.45;
    }

    - (void)updateSeahorseUI {
        if (!self.seahorseStatusLabel) return;
        if (!self.seahorseLoaded) {
            self.seahorseStatusLabel.text = @"Checking enrollment…";
            [self setSeahorseButton:self.seahorseSlot1Button enabled:NO];
            [self setSeahorseButton:self.seahorsePartnerButton enabled:NO];
            [self setSeahorseButton:self.seahorseRemovePartnerButton enabled:NO];
            [self setSeahorseButton:self.seahorseRemoveMineButton enabled:NO];
            return;
        }
        if (!self.seahorseEligibility) {
            self.seahorseStatusLabel.text =
                @"Couldn't load enrollment status. Check your connection and reopen Settings.";
            [self setSeahorseButton:self.seahorseSlot1Button enabled:NO];
            [self setSeahorseButton:self.seahorsePartnerButton enabled:NO];
            [self setSeahorseButton:self.seahorseRemovePartnerButton enabled:NO];
            [self setSeahorseButton:self.seahorseRemoveMineButton enabled:NO];
            return;
        }
        if (![self seahorseSupported]) {
            self.seahorseStatusLabel.text =
                @"Update the ez-seahorse function to manage enrollment here.";
            [self setSeahorseButton:self.seahorseSlot1Button enabled:NO];
            [self setSeahorseButton:self.seahorsePartnerButton enabled:NO];
            [self setSeahorseButton:self.seahorseRemovePartnerButton enabled:NO];
            [self setSeahorseButton:self.seahorseRemoveMineButton enabled:NO];
            return;
        }
        BOOL mine         = [self seahorseSlot:1 hasFlag:@"verified"];
        BOOL mineCrop     = [self seahorseSlot:1 hasFlag:@"likeness_saved"];
        BOOL partner      = [self seahorseSlot:2 hasFlag:@"verified"];
        BOOL partnerCrop  = [self seahorseSlot:2 hasFlag:@"likeness_saved"];
        self.seahorseStatusLabel.text = [NSString stringWithFormat:
            @"Your ID: %@%@\nPartner ID: %@%@",
            mine ? @"verified ✓" : @"not verified",
            mine ? (mineCrop ? @" · likeness saved ✓" : @" · likeness NOT saved") : @"",
            partner ? @"added ✓" : @"not added",
            partner ? (partnerCrop ? @" · likeness saved ✓" : @" · likeness NOT saved") : @""];
        [self.seahorseSlot1Button setTitle:(mine ? @"Replace My ID" : @"Verify My ID")
                                  forState:UIControlStateNormal];
        [self.seahorsePartnerButton setTitle:(partner ? @"Replace Partner ID"
                                                       : @"Add a Second ID (Partner)")
                                    forState:UIControlStateNormal];
        [self setSeahorseButton:self.seahorseSlot1Button enabled:!self.seahorseBusy];
        [self setSeahorseButton:self.seahorsePartnerButton
                        enabled:!self.seahorseBusy && mine];
        [self setSeahorseButton:self.seahorseRemovePartnerButton
                        enabled:!self.seahorseBusy && partner];
        [self setSeahorseButton:self.seahorseRemoveMineButton
                        enabled:!self.seahorseBusy && mine];
    }

    - (void)seahorseVerifyMineTapped    { [self seahorseBeginVerifySlot:1]; }
    - (void)seahorseVerifyPartnerTapped { [self seahorseBeginVerifySlot:2]; }

    - (void)seahorseBeginVerifySlot:(NSInteger)slot {
        if (![self seahorseSupported]) {
            [self showAlert:@"NSFW Images"
                    message:@"Update the ez-seahorse function to manage enrollment here."];
            return;
        }
        if (slot == 2 && ![self seahorseSlot:1 hasFlag:@"verified"]) {
            [self showAlert:@"NSFW Images"
                    message:@"Verify your own ID first — a partner enrollment is attached to yours."];
            return;
        }
        BOOL alreadyVerified = [self seahorseSlot:slot hasFlag:@"verified"];
        [EZSettingsSeahorseIDPicker pickFromViewController:self
                                                completion:^(UIImage *image) {
            if (!image) return;
            [self seahorseSubmitIDImage:image slot:slot alreadyVerified:alreadyVerified];
        }];
    }

    // Mirrors the chat flow's verify payload: the on-device face crop
    // always goes (it becomes the saved likeness); the full ID image —
    // downscaled, for the one-time date-of-birth read only — goes only
    // when this slot's age check still has to run.
    - (void)seahorseSubmitIDImage:(UIImage *)image slot:(NSInteger)slot
                  alreadyVerified:(BOOL)alreadyVerified {
        NSData *crop = EZSettingsSeahorseFaceCropJPEGData(image);
        if (!crop) {
            [self showAlert:@"NSFW Images"
                    message:@"No face could be found in that photo. Use a clear photo of the ID."];
            return;
        }
        NSMutableDictionary *body = [@{
            @"action":                 @"verify_id",
            @"slot":                   @(slot),
            @"enrollment_crop_base64": [crop base64EncodedStringWithOptions:0],
        } mutableCopy];
        if (!alreadyVerified) {
            UIImage *idImage = image;
            CGFloat maxDim = MAX(image.size.width, image.size.height);
            if (maxDim > 1600) {
                CGFloat scale = 1600.0 / maxDim;
                CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
                UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
                idImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
                }];
            }
            NSData *idData = UIImageJPEGRepresentation(idImage, 0.7);
            if (!idData.length) {
                [self showAlert:@"NSFW Images"
                        message:@"That photo couldn't be read. Try a clearer photo of the ID."];
                return;
            }
            body[@"id_image_base64"] = [idData base64EncodedStringWithOptions:0];
        }
        self.seahorseBusy = YES;
        [self updateSeahorseUI];
        EZLogf(EZLogLevelInfo, @"SEAHORSE", @"settings verify_id: slot=%ld age_check=%d",
               (long)slot, !alreadyVerified);
        [self seahorsePost:body completion:^(NSDictionary *json) {
            self.seahorseBusy = NO;
            NSString *err = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : nil;
            BOOL verified = [json[@"verified"] isKindOfClass:NSNumber.class] &&
                            [json[@"verified"] boolValue];
            if (err.length) {
                [self showAlert:@"NSFW Images" message:err];
            } else if (!verified) {
                NSString *reason = [json[@"reason"] isKindOfClass:NSString.class]
                    ? json[@"reason"] : nil;
                [self showAlert:@"NSFW Images"
                        message:([reason isEqualToString:@"underage"]
                            ? @"This ID shows someone under 18, so it can't be enrolled."
                            : @"The date of birth couldn't be read from that ID. Try a clearer photo.")];
            } else {
                [self showAlert:@"NSFW Images"
                        message:(slot == 2 ? @"Partner ID saved." : @"Your ID is saved.")];
            }
            [self refreshSeahorseStatus];
        }];
    }

    - (void)seahorseRemovePartnerTapped { [self seahorseConfirmRemoveSlot:2]; }
    - (void)seahorseRemoveMineTapped    { [self seahorseConfirmRemoveSlot:1]; }

    - (void)seahorseConfirmRemoveSlot:(NSInteger)slot {
        if (![self seahorseSupported]) {
            [self showAlert:@"NSFW Images"
                    message:@"Update the ez-seahorse function to manage enrollment here."];
            return;
        }
        NSString *title   = slot == 2 ? @"Remove Partner ID?" : @"Remove Your ID?";
        NSString *message = slot == 2
            ? @"This deletes the partner's saved likeness. Their face will no longer pass the reference check."
            : @"This deletes your saved likeness AND your partner's, and removes your verification. You'll need to do the ID check again before generating NSFW images.";
        UIAlertController *confirm = [UIAlertController
            alertControllerWithTitle:title message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Remove"
                                                   style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction *a) {
            [self seahorseRemoveSlot:slot];
        }]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                   style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:confirm animated:YES completion:nil];
    }

    - (void)seahorseRemoveSlot:(NSInteger)slot {
        self.seahorseBusy = YES;
        [self updateSeahorseUI];
        [self seahorsePost:@{ @"action": @"remove_enrollment", @"slot": @(slot) }
                completion:^(NSDictionary *json) {
            self.seahorseBusy = NO;
            NSString *err = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : nil;
            EZLogf(EZLogLevelInfo, @"SEAHORSE", @"settings remove_enrollment: slot=%ld ok=%d",
                   (long)slot, !err.length);
            [self showAlert:@"NSFW Images"
                    message:(err.length ? err : @"Enrollment removed.")];
            [self refreshSeahorseStatus];
        }];
    }

    @end
