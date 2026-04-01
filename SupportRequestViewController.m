// SupportRequestViewController.m
// EZCompleteUI v1.2
//
// Changes from v1.1:
//   - sendTapped: canSendMail now gates the send PATH, not whether to send at all
//   - Fallback to mailto: URL when MFMailComposeViewController is unavailable
//     (fixes jailbroken iOS 15 where canSendMail returns NO despite mail being configured)
//
// Changes from v1.0:
//   - System message no longer truncated in settings snapshot (full content included)
//
// Changes from (new):
//   - Initial implementation: support/feedback form with settings snapshot
//   - Recipient email loaded from EZKeyVault (never in source)
//   - Settings snapshot excludes all API key fields (vault and legacy UserDefaults)
//   - Optional debug log attachment behind explicit user permission switch
//   - App version + build read from main bundle Info.plist
//   - MFMailComposeViewController handles send; controller dismissed on any result

#import "SupportRequestViewController.h"
#import "EZKeyVault.h"
#import "helpers.h"
#import <MessageUI/MessageUI.h>

// Keys we explicitly must never include in the settings snapshot.
// Covers both the current vault-backed names and any un-migrated legacy names.
static NSArray<NSString *> *EZSensitiveUserDefaultsKeys(void) {
    return @[@"apiKey", @"elevenKey", @"openAIKey", @"elevenLabsKey",
             @"apikey", @"api_key", @"elevenlabs_key"];
}

@interface SupportRequestViewController () <MFMailComposeViewControllerDelegate,
                                            UITextViewDelegate>

// ── UI ─────────────────────────────────────────────────────────────────────
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextView   *messageTextView;
@property (nonatomic, strong) UISwitch     *includeLogSwitch;
@property (nonatomic, strong) UILabel      *settingsPreviewLabel;

@end


@implementation SupportRequestViewController

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Support & Feedback";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Send"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(sendTapped)];

    [self setupUI];

    // Dismiss keyboard on tap outside the text view
    UITapGestureRecognizer *dismissTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    [self.scrollView addGestureRecognizer:dismissTap];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UI Setup
// ─────────────────────────────────────────────────────────────────────────────

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    CGFloat contentWidth = self.view.frame.size.width - 32;
    CGFloat y = 20;

    // ── Intro label ──────────────────────────────────────────────────────────
    UILabel *introLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, contentWidth, 0)];
    introLabel.text =
        @"Describe your issue or feedback below. Your current app settings "
         "(no API keys) will be included automatically to help diagnose problems.";
    introLabel.font          = [UIFont systemFontOfSize:14];
    introLabel.textColor     = [UIColor secondaryLabelColor];
    introLabel.numberOfLines = 0;
    [introLabel sizeToFit];
    introLabel.frame = CGRectMake(16, y, contentWidth, introLabel.frame.size.height);
    [self.scrollView addSubview:introLabel];
    y += introLabel.frame.size.height + 14;

    // ── Message text view ────────────────────────────────────────────────────
    UILabel *messageLabel = [self makeSectionLabel:@"Your message:" y:&y];
    (void)messageLabel; // used for layout side-effect

    self.messageTextView = [[UITextView alloc] initWithFrame:CGRectMake(16, y, contentWidth, 160)];
    self.messageTextView.font                 = [UIFont systemFontOfSize:15];
    self.messageTextView.layer.cornerRadius   = 10;
    self.messageTextView.layer.borderWidth    = 1.0;
    self.messageTextView.layer.borderColor    = [UIColor systemGray4Color].CGColor;
    self.messageTextView.backgroundColor      = [UIColor secondarySystemBackgroundColor];
    self.messageTextView.textContainerInset   = UIEdgeInsetsMake(10, 8, 10, 8);
    self.messageTextView.delegate             = self;
    // Placeholder text — cleared on first edit via delegate
    self.messageTextView.text                 = @"Describe your issue or feedback here...";
    self.messageTextView.textColor            = [UIColor placeholderTextColor];
    [self.scrollView addSubview:self.messageTextView];
    y += 170;

    // ── Separator ────────────────────────────────────────────────────────────
    UIView *separator1       = [[UIView alloc] initWithFrame:CGRectMake(16, y, contentWidth, 0.5)];
    separator1.backgroundColor = [UIColor separatorColor];
    [self.scrollView addSubview:separator1];
    y += 16;

    // ── Include debug log toggle ─────────────────────────────────────────────
    UILabel *logToggleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, contentWidth - 60, 22)];
    logToggleLabel.text      = @"Include debug log";
    logToggleLabel.font      = [UIFont systemFontOfSize:15];
    logToggleLabel.textColor = [UIColor labelColor];
    [self.scrollView addSubview:logToggleLabel];

    self.includeLogSwitch = [[UISwitch alloc] init];
    CGSize switchSize = self.includeLogSwitch.intrinsicContentSize;
    self.includeLogSwitch.frame =
        CGRectMake(contentWidth - switchSize.width + 16, y - 1, switchSize.width, switchSize.height);
    self.includeLogSwitch.on = NO;
    [self.scrollView addSubview:self.includeLogSwitch];
    y += 30;

    UILabel *logHintLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, y, contentWidth, 0)];
    logHintLabel.text =
        @"The debug log records model calls and errors. It does not contain message content.";
    logHintLabel.font          = [UIFont systemFontOfSize:12];
    logHintLabel.textColor     = [UIColor secondaryLabelColor];
    logHintLabel.numberOfLines = 0;
    [logHintLabel sizeToFit];
    logHintLabel.frame = CGRectMake(16, y, contentWidth, logHintLabel.frame.size.height);
    [self.scrollView addSubview:logHintLabel];
    y += logHintLabel.frame.size.height + 16;

    // ── Separator ────────────────────────────────────────────────────────────
    UIView *separator2        = [[UIView alloc] initWithFrame:CGRectMake(16, y, contentWidth, 0.5)];
    separator2.backgroundColor = [UIColor separatorColor];
    [self.scrollView addSubview:separator2];
    y += 16;

    // ── Settings snapshot preview ─────────────────────────────────────────────
    [self makeSectionLabel:@"Settings that will be included:" y:&y];

    self.settingsPreviewLabel =
        [[UILabel alloc] initWithFrame:CGRectMake(16, y, contentWidth, 0)];
    self.settingsPreviewLabel.text          = [self buildSettingsSnapshotDisplayString];
    self.settingsPreviewLabel.font          = [UIFont monospacedSystemFontOfSize:11
                                                                          weight:UIFontWeightRegular];
    self.settingsPreviewLabel.textColor     = [UIColor secondaryLabelColor];
    self.settingsPreviewLabel.numberOfLines = 0;
    self.settingsPreviewLabel.backgroundColor =
        [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:0.12 alpha:1.0]
                : [UIColor colorWithWhite:0.95 alpha:1.0];
        }];
    self.settingsPreviewLabel.layer.cornerRadius = 8;
    self.settingsPreviewLabel.clipsToBounds      = YES;
    [self.settingsPreviewLabel sizeToFit];
    // Ensure it spans the full content width despite sizeToFit
    self.settingsPreviewLabel.frame =
        CGRectMake(16, y, contentWidth, self.settingsPreviewLabel.frame.size.height + 16);
    // Add a small left inset via layer — UILabel doesn't have textContainerInset,
    // so we just add a small invisible view as a left margin
    // (achieved by padding the text itself below in buildSettingsSnapshotDisplayString)
    [self.scrollView addSubview:self.settingsPreviewLabel];
    y += self.settingsPreviewLabel.frame.size.height + 24;

    self.scrollView.contentSize = CGSizeMake(self.view.frame.size.width, y);
}

/// Tiny helper that adds a bold section label and advances y.
- (UILabel *)makeSectionLabel:(NSString *)text y:(CGFloat *)y {
    UILabel *label      = [[UILabel alloc] initWithFrame:
                            CGRectMake(16, *y, self.view.frame.size.width - 32, 20)];
    label.text          = text;
    label.font          = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor     = [UIColor secondaryLabelColor];
    [self.scrollView addSubview:label];
    *y += 26;
    return label;
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Settings Snapshot
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the plain-text settings block that goes into the email.
/// Reads only from NSUserDefaults — vault keys are never touched here.
- (NSString *)buildSettingsSnapshot {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *sensitiveKeys = EZSensitiveUserDefaultsKeys();

    // Collect the keys we actually care about presenting
    NSDictionary<NSString *, NSString *> *knownSettings = @{
        @"selectedModel"    : @"Selected Model",
        @"temperature"      : @"Temperature",
        @"frequency"        : @"Freq Penalty",
        @"webSearchEnabled" : @"Web Search",
        @"webSearchLocation": @"Web Search Location",
        @"soraModel"        : @"Sora Model",
        @"soraSize"         : @"Sora Resolution",
        @"soraDuration"     : @"Sora Duration",
        @"elevenVoiceID"    : @"ElevenLabs Voice ID",
        @"systemMessage"    : @"System Message",
    };

    // Ordered display sequence
    NSArray<NSString *> *displayOrder = @[
        @"selectedModel", @"temperature", @"frequency",
        @"webSearchEnabled", @"webSearchLocation",
        @"soraModel", @"soraSize", @"soraDuration",
        @"elevenVoiceID", @"systemMessage"
    ];

    NSMutableString *snapshot = [NSMutableString string];
    [snapshot appendString:@"── App Settings ──────────────────────────\n"];

    // App version
    NSDictionary *infoPlist = [NSBundle mainBundle].infoDictionary;
    NSString *appVersion   = infoPlist[@"CFBundleShortVersionString"] ?: @"Unknown";
    NSString *buildNumber  = infoPlist[@"CFBundleVersion"]            ?: @"?";
    [snapshot appendFormat:@"App Version : %@ (build %@)\n", appVersion, buildNumber];

    // iOS + device
    UIDevice *device = [UIDevice currentDevice];
    [snapshot appendFormat:@"iOS         : %@\n", device.systemVersion];
    [snapshot appendFormat:@"Device      : %@\n", device.model];
    [snapshot appendString:@"\n"];

    for (NSString *key in displayOrder) {
        // Double-check against sensitive list — belt AND suspenders
        if ([sensitiveKeys containsObject:key]) continue;

        NSString *displayName = knownSettings[key] ?: key;
        id value = [defaults objectForKey:key];
        NSString *valueString = @"(not set)";

        if ([key isEqualToString:@"systemMessage"]) {
            // Include the full system message — important context when debugging
            NSString *sysMsg = [defaults stringForKey:key] ?: @"";
            valueString = sysMsg.length > 0 ? sysMsg : @"(not set)";
        } else if ([key isEqualToString:@"webSearchEnabled"]) {
            valueString = [defaults boolForKey:key] ? @"ON" : @"OFF";
        } else if ([key isEqualToString:@"temperature"] ||
                   [key isEqualToString:@"frequency"]) {
            valueString = value ? [NSString stringWithFormat:@"%.2f",
                                   [defaults floatForKey:key]] : @"(not set)";
        } else if ([key isEqualToString:@"soraDuration"]) {
            NSInteger dur = [defaults integerForKey:key];
            valueString = dur > 0 ? [NSString stringWithFormat:@"%lds", (long)dur] : @"(not set)";
        } else {
            valueString = ([value isKindOfClass:[NSString class]] && ((NSString *)value).length > 0)
                ? (NSString *)value : @"(not set)";
        }

        // Align the colon column for readability
        NSString *paddedName = [displayName stringByPaddingToLength:20
                                                         withString:@" "
                                                    startingAtIndex:0];
        [snapshot appendFormat:@"%@: %@\n", paddedName, valueString];
    }

    // Keychain presence indicators (no values, just "saved" or "not set")
    [snapshot appendString:@"\n── Key Storage (vault presence only) ────\n"];
    [snapshot appendFormat:@"OpenAI Key          : %@\n",
     [EZKeyVault hasKeyForIdentifier:EZVaultKeyOpenAI]      ? @"saved in vault" : @"not saved"];
    [snapshot appendFormat:@"ElevenLabs Key      : %@\n",
     [EZKeyVault hasKeyForIdentifier:EZVaultKeyElevenLabs]  ? @"saved in vault" : @"not saved"];

    return [snapshot copy];
}

/// Version shown in the settings preview label (indented for readability).
- (NSString *)buildSettingsSnapshotDisplayString {
    NSString *snapshot = [self buildSettingsSnapshot];
    // Add a little left padding since UILabel has no textContainerInset
    NSMutableString *padded = [NSMutableString string];
    for (NSString *line in [snapshot componentsSeparatedByString:@"\n"]) {
        [padded appendFormat:@"  %@\n", line];
    }
    return [padded copy];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Actions
// ─────────────────────────────────────────────────────────────────────────────

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)sendTapped {
    // Validate user has entered something beyond the placeholder
    BOOL hasMessage = self.messageTextView.textColor != [UIColor placeholderTextColor]
                      && self.messageTextView.text.length > 0;
    if (!hasMessage) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Message Required"
                                                message:@"Please describe your issue or feedback before sending."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    // Load recipient from vault — never hardcoded in this file
    NSString *recipientEmail = [EZKeyVault loadKeyForIdentifier:EZVaultKeySupportEmail];
    if (!recipientEmail.length) {
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Support Unavailable"
                                                message:@"Support contact could not be loaded. "
                                                         "Please update the app and try again."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        EZLog(EZLogLevelError, @"SUPPORT", @"EZVaultKeySupportEmail not found in vault");
        return;
    }

    // Build app version string for the subject line
    NSDictionary *infoPlist = [NSBundle mainBundle].infoDictionary;
    NSString *appVersion    = infoPlist[@"CFBundleShortVersionString"] ?: @"?";
    NSString *subject       = [NSString stringWithFormat:@"EZCompleteUI v%@ — Support Request",
                                appVersion];

    // Build the shared email body
    NSMutableString *body = [NSMutableString string];
    [body appendString:@"USER MESSAGE"];
    [body appendString:@"────────────────────────────────────────"];
    [body appendString:self.messageTextView.text];
    [body appendString:@""];
    [body appendString:[self buildSettingsSnapshot]];

    // ── Path 1: MFMailComposeViewController (preferred — supports log attachment) ──
    // canSendMail checks Apple Mail's IPC endpoint. On jailbroken iOS 15 this can
    // return NO even when mail is configured, so a failed check falls through to
    // the mailto: fallback rather than blocking the send entirely.
    if ([MFMailComposeViewController canSendMail]) {
        // Optionally append the debug log — only possible via the full composer
        if (self.includeLogSwitch.isOn) {
            NSString *logPath    = EZLogGetPath();
            NSString *logContent = [NSString stringWithContentsOfFile:logPath
                                                             encoding:NSUTF8StringEncoding
                                                                error:nil];
            if (logContent.length > 0) {
                // Cap at 50 KB — take the most recent portion so the newest events are included
                NSUInteger maxLogBytes = 50 * 1024;
                if (logContent.length > maxLogBytes) {
                    logContent = [logContent substringFromIndex:logContent.length - maxLogBytes];
                    logContent = [@"[Log truncated to last 50 KB]"
                                  stringByAppendingString:logContent];
                }
                [body appendString:@"

── Debug Log ─────────────────────────────
"];
                [body appendString:logContent];
            } else {
                [body appendString:@"

── Debug Log ─────────────────────────────
"];
                [body appendString:@"(log file is empty or could not be read)
"];
            }
        }

        MFMailComposeViewController *mailVC = [[MFMailComposeViewController alloc] init];
        mailVC.mailComposeDelegate = self;
        [mailVC setToRecipients:@[recipientEmail]];
        [mailVC setSubject:subject];
        [mailVC setMessageBody:body isHTML:NO];
        [self presentViewController:mailVC animated:YES completion:nil];
        EZLog(EZLogLevelInfo, @"SUPPORT", @"Mail composer presented (MFMailComposeViewController)");
        return;
    }

    // ── Path 2: mailto: URL fallback ─────────────────────────────────────────
    // Reaches here when canSendMail returns NO — most commonly on jailbroken
    // devices where the Apple Mail IPC check fails despite a working mail client.
    // mailto: is handled by whatever mail app the user has set as default.
    //
    // Limitation: mailto: body length is practically capped at a few KB by most
    // clients. The debug log is excluded here to avoid silent truncation; we
    // inform the user about this so they know what to expect.
    EZLog(EZLogLevelInfo, @"SUPPORT",
          @"canSendMail returned NO — falling back to mailto: URL");

    if (self.includeLogSwitch.isOn) {
        [body appendString:@"

── Debug Log ─────────────────────────────
"];
        [body appendString:@"[Log omitted: not supported via mailto: fallback. "
                            "Please send a follow-up with the log from Settings → Helper Stats.]
"];
    }

    // Percent-encode subject and body for the mailto: URL
    NSCharacterSet *mailtoAllowed = [NSCharacterSet
        characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"];
    NSString *encodedSubject = [subject
        stringByAddingPercentEncodingWithAllowedCharacters:mailtoAllowed];
    NSString *encodedBody    = [body
        stringByAddingPercentEncodingWithAllowedCharacters:mailtoAllowed];

    NSString *mailtoURLString = [NSString stringWithFormat:@"mailto:%@?subject=%@&body=%@",
                                 recipientEmail, encodedSubject, encodedBody];
    NSURL *mailtoURL = [NSURL URLWithString:mailtoURLString];

    if (!mailtoURL || ![[UIApplication sharedApplication] canOpenURL:mailtoURL]) {
        // No mail client at all — nothing we can do except tell the user
        UIAlertController *noMailAlert =
            [UIAlertController alertControllerWithTitle:@"No Mail App Found"
                                                message:@"Could not find a mail app to send with. "
                                                         "Please install or configure a mail app and try again."
                                         preferredStyle:UIAlertControllerStyleAlert];
        [noMailAlert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                        style:UIAlertActionStyleDefault
                                                      handler:nil]];
        [self presentViewController:noMailAlert animated:YES completion:nil];
        EZLog(EZLogLevelError, @"SUPPORT", @"mailto: URL also unavailable — no mail client found");
        return;
    }

    [[UIApplication sharedApplication] openURL:mailtoURL options:@{} completionHandler:^(BOOL success) {
        if (success) {
            EZLog(EZLogLevelInfo, @"SUPPORT", @"mailto: URL opened successfully");
            // Dismiss the support VC — the mail client takes it from here
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissViewControllerAnimated:YES completion:nil];
            });
        } else {
            EZLog(EZLogLevelError, @"SUPPORT", @"mailto: URL failed to open");
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *failAlert =
                    [UIAlertController alertControllerWithTitle:@"Could Not Open Mail"
                                                        message:@"The mail app could not be opened. "
                                                                 "Please try again or send feedback manually."
                                                 preferredStyle:UIAlertControllerStyleAlert];
                [failAlert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                              style:UIAlertActionStyleDefault
                                                            handler:nil]];
                [self presentViewController:failAlert animated:YES completion:nil];
            });
        }
    }];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - MFMailComposeViewControllerDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)mailComposeController:(MFMailComposeViewController *)controller
          didFinishWithResult:(MFMailComposeResult)result
                        error:(nullable NSError *)error {
    [controller dismissViewControllerAnimated:YES completion:^{
        switch (result) {
            case MFMailComposeResultSent:
                EZLog(EZLogLevelInfo, @"SUPPORT", @"Support email sent successfully");
                // Dismiss the support VC itself now that the mail is sent
                [self dismissViewControllerAnimated:YES completion:nil];
                break;
            case MFMailComposeResultCancelled:
                EZLog(EZLogLevelInfo, @"SUPPORT", @"Mail composer cancelled by user");
                // User cancelled the mail sheet — stay on the support VC so they can try again
                break;
            case MFMailComposeResultFailed:
                EZLogf(EZLogLevelError, @"SUPPORT", @"Mail send failed: %@", error.localizedDescription);
                [self showSendError:error];
                break;
            case MFMailComposeResultSaved:
                EZLog(EZLogLevelInfo, @"SUPPORT", @"Support email saved to drafts");
                [self dismissViewControllerAnimated:YES completion:nil];
                break;
        }
    }];
}

- (void)showSendError:(nullable NSError *)error {
    NSString *detail = error.localizedDescription ?: @"Unknown error.";
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Send Failed"
                                            message:[NSString stringWithFormat:
                                                     @"The email could not be sent. %@", detail]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UITextViewDelegate (placeholder simulation)
// ─────────────────────────────────────────────────────────────────────────────

- (void)textViewDidBeginEditing:(UITextView *)textView {
    if (textView == self.messageTextView &&
        textView.textColor == [UIColor placeholderTextColor]) {
        textView.text      = @"";
        textView.textColor = [UIColor labelColor];
    }
}

- (void)textViewDidEndEditing:(UITextView *)textView {
    if (textView == self.messageTextView && textView.text.length == 0) {
        textView.text      = @"Describe your issue or feedback here...";
        textView.textColor = [UIColor placeholderTextColor];
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Keyboard Avoidance
// ─────────────────────────────────────────────────────────────────────────────

- (void)keyboardWillShow:(NSNotification *)notification {
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIEdgeInsets insets  = UIEdgeInsetsMake(0, 0, keyboardFrame.size.height, 0);
    self.scrollView.contentInset          = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)keyboardWillHide:(NSNotification *)notification {
    self.scrollView.contentInset          = UIEdgeInsetsZero;
    self.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
}

@end
