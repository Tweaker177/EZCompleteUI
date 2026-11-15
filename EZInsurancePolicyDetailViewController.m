// EZInsurancePolicyDetailViewController.m
// EZCompleteUI

#import "EZInsurancePolicyDetailViewController.h"
#import "EZInsurancePolicyManager.h"
#import "EZInsuranceDateUtils.h"
#import "EZInsuranceNotesEditorViewController.h"
#import "EZInsuranceFilePreviewViewController.h"
#import "helpers.h" // EZLog/EZLogf
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <PhotosUI/PhotosUI.h>
#import <QuickLook/QuickLook.h>
#import <AVFoundation/AVFoundation.h>

// Tiny private helper — NOT exposed outside this file. Represents one file
// upload currently in flight, so its row can be shown with a spinner and
// then removed once EZInsurancePolicyManager's completion handler fires.
@interface EZInsurancePendingUpload : NSObject
@property (nonatomic, copy) NSString *filename;
// Filled in asynchronously shortly after the upload starts (see
// ez_generateThumbnailForLocalURL:completion:) — nil until then, in which
// case the row just shows a generic icon instead.
@property (nonatomic, strong, nullable) UIImage *thumbnail;
@end
@implementation EZInsurancePendingUpload
@end

// Also private. QLPreviewController needs an object conforming to
// QLPreviewItem — a plain local NSURL works too, but wrapping it lets the
// preview show the real original filename as its title instead of
// whatever the downloaded temp file happens to be named.
@interface EZInsurancePreviewItem : NSObject <QLPreviewItem>
@property (nonatomic, strong) NSURL *previewItemURL;
@property (nonatomic, copy) NSString *previewItemTitle;
@end
@implementation EZInsurancePreviewItem
@end

@interface EZInsurancePolicyDetailViewController () <UIDocumentPickerDelegate, PHPickerViewControllerDelegate, QLPreviewControllerDataSource>

// ── Policy state ──────────────────────────────────────────────────────────
// Kept as discrete fields rather than passing the raw dictionary around
// everywhere — every action below (check-in, send-now, cancel) changes one
// of these, and updating one field in one place is a lot easier to keep
// correct than re-deriving state from a dictionary throughout the file.
@property (nonatomic, copy, nullable) NSString *policyID;
@property (nonatomic, copy) NSString *policyStatus;
@property (nonatomic, strong, nullable) NSDate *lastCheckinAt;
@property (nonatomic, assign) NSInteger frequencyHours;

// Generated once in initWithPolicy: (new-policy mode only) and reused for
// every retry of the Create tap in this screen's lifetime — see
// createPolicyWithPassword:frequencyHours:clientRequestID:completion: for
// why regenerating this per-tap would defeat its whole purpose.
@property (nonatomic, copy, nullable) NSString *createRequestID;

@property (nonatomic, strong) NSMutableArray<NSDictionary *> *files;
@property (nonatomic, strong) NSMutableArray<EZInsurancePendingUpload *> *pendingUploads;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *recipients;

// Keyed by storage_path. Only ever populated for files uploaded during
// THIS screen instance (generated from the local file before it's
// uploaded — see ez_generateThumbnailForLocalURL:completion:). Files
// loaded from the server on an existing policy don't have a cheap local
// source for a real thumbnail, so they show a generic icon instead rather
// than downloading the whole file just to render a row. Tapping any row
// still opens the real full-size content regardless of which this is.
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *thumbnailCache;

// Non-nil while a row is being renamed inline — ez_rebuildFileRows checks
// this to decide whether to render that row's name as a static label or
// an editable text field. Only one row can be mid-rename at a time.
@property (nonatomic, copy, nullable) NSString *renamingFileID;

@property (nonatomic, strong, nullable) EZInsurancePreviewItem *currentPreviewItem;
// The temp file backing currentPreviewItem — tracked so it can be deleted
// once a new preview starts or this screen goes away, rather than
// accumulating one download per tap for the life of the app.
@property (nonatomic, strong, nullable) NSURL *previewingTempFileURL;

@property (nonatomic, strong, nullable) NSTimer *countdownTimer;

// ── Create-mode UI ─────────────────────────────────────────────────────────
@property (nonatomic, strong) UIView *createSectionView;
@property (nonatomic, strong) UITextField *passwordField;
@property (nonatomic, strong) UITextField *confirmPasswordField;
@property (nonatomic, strong) UISegmentedControl *frequencySegmentedControl;
@property (nonatomic, strong) UITextField *customHoursField;
@property (nonatomic, strong) UIButton *createButton;

// ── Existing-mode UI ────────────────────────────────────────────────────────
@property (nonatomic, strong) UIView *countdownSectionView;
@property (nonatomic, strong) UILabel *countdownLabel;
@property (nonatomic, strong) UILabel *countdownSubtitleLabel;

@property (nonatomic, strong) UIView *filesSectionView;
@property (nonatomic, strong) UIStackView *filesStackView;

@property (nonatomic, strong) UIView *recipientsSectionView;
@property (nonatomic, strong) UIStackView *recipientsStackView;
@property (nonatomic, strong) UITextField *recipientEmailField;

@property (nonatomic, strong) UIView *actionsSectionView;

@end

@implementation EZInsurancePolicyDetailViewController

- (instancetype)initWithPolicy:(nullable NSDictionary *)policy {
    self = [super init];
    if (self) {
        _files = [NSMutableArray array];
        _pendingUploads = [NSMutableArray array];
        _recipients = [NSMutableArray array];
        _thumbnailCache = [NSMutableDictionary dictionary];

        if (policy) {
            _policyID       = policy[@"id"];
            _policyStatus   = policy[@"status"] ?: @"active";
            _lastCheckinAt  = [EZInsuranceDateUtils dateFromPostgRESTString:policy[@"last_checkin_at"]];
            _frequencyHours = [policy[@"frequency_hours"] integerValue];
        } else {
            _policyID        = nil;
            _policyStatus    = @"active";
            _createRequestID = [NSUUID UUID].UUIDString;
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.policyID ? @"Manage Policy" : @"New Policy";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self ez_buildUI];
    [self ez_applyModeVisibility];

    if (self.policyID) {
        [self ez_loadFilesAndRecipients];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ez_startCountdownTimerIfNeeded];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.countdownTimer invalidate];
    self.countdownTimer = nil;
}

- (void)dealloc {
    // NOT done in viewWillDisappear — presenting QLPreviewController itself
    // triggers viewWillDisappear on this screen (it's being covered), which
    // would delete the very file QLPreviewController is displaying. Only
    // safe once this whole screen is actually going away for good.
    if (_previewingTempFileURL) {
        [[NSFileManager defaultManager] removeItemAtURL:_previewingTempFileURL.URLByDeletingLastPathComponent
                                                   error:nil];
    }
}

// ── Mode visibility ─────────────────────────────────────────────────────────

- (void)ez_applyModeVisibility {
    BOOL hasPolicy = (self.policyID != nil);
    self.createSectionView.hidden = hasPolicy;
    self.countdownSectionView.hidden = !hasPolicy;
    self.filesSectionView.hidden = !hasPolicy;
    self.recipientsSectionView.hidden = !hasPolicy;
    self.actionsSectionView.hidden = !hasPolicy;

    if (hasPolicy) [self ez_refreshCountdownDisplay];
}

// ── UI construction ─────────────────────────────────────────────────────────

- (void)ez_buildUI {
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scrollView];

    UIStackView *content = [[UIStackView alloc] init];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 28;
    content.layoutMarginsRelativeArrangement = YES;
    content.layoutMargins = UIEdgeInsetsMake(20, 20, 40, 20);
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:content];

    self.createSectionView     = [self ez_buildCreateSection];
    self.countdownSectionView  = [self ez_buildCountdownSection];
    self.filesSectionView      = [self ez_buildFilesSection];
    self.recipientsSectionView = [self ez_buildRecipientsSection];
    self.actionsSectionView    = [self ez_buildActionsSection];

    for (UIView *section in @[self.createSectionView, self.countdownSectionView,
                               self.filesSectionView, self.recipientsSectionView,
                               self.actionsSectionView]) {
        [content addArrangedSubview:section];
    }

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [content.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],
    ]];
}

/// Shared wrapper: bold title label above whatever content view is passed.
/// Every section below uses this so they all look consistent without
/// repeating the same three lines five times.
- (UIView *)ez_sectionWithTitle:(NSString *)title content:(UIView *)contentView {
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.5;
    titleLabel.text = title;
    titleLabel.font = [UIFont boldSystemFontOfSize:20];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, contentView]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    return stack;
}

- (UITextField *)ez_textFieldWithPlaceholder:(NSString *)placeholder secure:(BOOL)secure {
    UITextField *field = [[UITextField alloc] init];
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.secureTextEntry = secure;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    [field setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return field;
}

// ── Create section ───────────────────────────────────────────────────────

- (UIView *)ez_buildCreateSection {
    self.passwordField = [self ez_textFieldWithPlaceholder:@"Password (min. 8 characters)" secure:YES];
    self.confirmPasswordField = [self ez_textFieldWithPlaceholder:@"Confirm password" secure:YES];

    UILabel *passwordNote = [[UILabel alloc] init];
    passwordNote.adjustsFontSizeToFitWidth = YES;
    passwordNote.minimumScaleFactor = 0.5;
    passwordNote.text = @"This password is separate from your account login. "
        @"You'll need it to check in, send now, or cancel this policy — write it down somewhere safe. "
        @"It cannot be recovered if lost.";
    passwordNote.font = [UIFont systemFontOfSize:13];
    passwordNote.textColor = [UIColor secondaryLabelColor];
    passwordNote.numberOfLines = 0;

    self.frequencySegmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"24h", @"3d", @"7d", @"Custom"]];
    self.frequencySegmentedControl.selectedSegmentIndex = 1; // default: 3 days
    [self.frequencySegmentedControl addTarget:self action:@selector(ez_frequencySegmentChanged)
                              forControlEvents:UIControlEventValueChanged];

    self.customHoursField = [self ez_textFieldWithPlaceholder:@"Hours between check-ins" secure:NO];
    self.customHoursField.keyboardType = UIKeyboardTypeNumberPad;
    self.customHoursField.hidden = YES;

    self.createButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.createButton setTitle:@"Create Policy" forState:UIControlStateNormal];
    self.createButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    self.createButton.backgroundColor = [UIColor systemBlueColor];
    [self.createButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.createButton.layer.cornerRadius = 10;
    self.createButton.contentEdgeInsets = UIEdgeInsetsMake(12, 20, 12, 20);
    [self.createButton addTarget:self action:@selector(ez_createPolicyTapped)
                 forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.passwordField, self.confirmPasswordField, passwordNote,
        self.frequencySegmentedControl, self.customHoursField, self.createButton,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    [stack setCustomSpacing:4 afterView:self.confirmPasswordField];

    return [self ez_sectionWithTitle:@"Set Up Policy" content:stack];
}

- (void)ez_frequencySegmentChanged {
    self.customHoursField.hidden = (self.frequencySegmentedControl.selectedSegmentIndex != 3);
}

- (void)ez_createPolicyTapped {
    NSString *password = self.passwordField.text ?: @"";
    NSString *confirm   = self.confirmPasswordField.text ?: @"";

    if (password.length < 8) {
        [self ez_presentError:@"Password must be at least 8 characters."];
        return;
    }
    if (![password isEqualToString:confirm]) {
        [self ez_presentError:@"Passwords don't match."];
        return;
    }

    NSInteger frequencyHours;
    switch (self.frequencySegmentedControl.selectedSegmentIndex) {
        case 0: frequencyHours = 24; break;
        case 1: frequencyHours = 24 * 3; break;
        case 2: frequencyHours = 24 * 7; break;
        default: {
            frequencyHours = [self.customHoursField.text integerValue];
            if (frequencyHours <= 0) {
                [self ez_presentError:@"Enter how many hours between required check-ins."];
                return;
            }
            break;
        }
    }

    self.createButton.enabled = NO;
    __weak typeof(self) weakSelf = self;
    [[EZInsurancePolicyManager shared] createPolicyWithPassword:password
                                                   frequencyHours:frequencyHours
                                                   clientRequestID:self.createRequestID
                                                       completion:^(NSString *policyID, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.createButton.enabled = YES;

        if (errorMessage) {
            [strongSelf ez_presentError:errorMessage];
            return;
        }

        strongSelf.policyID       = policyID;
        strongSelf.policyStatus   = @"active";
        strongSelf.lastCheckinAt  = [NSDate date];
        strongSelf.frequencyHours = frequencyHours;
        strongSelf.title = @"Manage Policy";

        [strongSelf ez_applyModeVisibility];
        [strongSelf ez_startCountdownTimerIfNeeded];
        // Freshly created — files/recipients are known empty, no need to
        // round-trip to the server just to learn that.
        [strongSelf ez_rebuildFileRows];
        [strongSelf ez_rebuildRecipientRows];
    }];
}

// ── Countdown section ───────────────────────────────────────────────────────

- (UIView *)ez_buildCountdownSection {
    self.countdownLabel = [[UILabel alloc] init];
    self.countdownLabel.adjustsFontSizeToFitWidth = YES;
    self.countdownLabel.minimumScaleFactor = 0.5;
    self.countdownLabel.font = [UIFont monospacedDigitSystemFontOfSize:28 weight:UIFontWeightBold];
    self.countdownLabel.textAlignment = NSTextAlignmentCenter;

    self.countdownSubtitleLabel = [[UILabel alloc] init];
    self.countdownSubtitleLabel.adjustsFontSizeToFitWidth = YES;
    self.countdownSubtitleLabel.minimumScaleFactor = 0.5;
    self.countdownSubtitleLabel.font = [UIFont systemFontOfSize:14];
    self.countdownSubtitleLabel.textColor = [UIColor secondaryLabelColor];
    self.countdownSubtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.countdownSubtitleLabel.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.countdownLabel, self.countdownSubtitleLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    return stack;
}

- (void)ez_startCountdownTimerIfNeeded {
    [self.countdownTimer invalidate];
    self.countdownTimer = nil;
    if (!self.policyID) return;

    [self ez_refreshCountdownDisplay];
    self.countdownTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                             target:self
                                                           selector:@selector(ez_refreshCountdownDisplay)
                                                           userInfo:nil
                                                            repeats:YES];
}

- (void)ez_refreshCountdownDisplay {
    if ([self.policyStatus isEqualToString:@"releasing"]) {
        self.countdownLabel.text = @"Sending…";
        self.countdownSubtitleLabel.text = @"A release is currently in progress.";
    } else if ([self.policyStatus isEqualToString:@"release_failed"]) {
        self.countdownLabel.text = @"⚠️ Needs Attention";
        self.countdownSubtitleLabel.text = @"Automatic sending failed repeatedly. Check in to reset, or use Send Now below to retry immediately.";
    } else if ([self.policyStatus isEqualToString:@"released"]) {
        self.countdownLabel.text = @"Released";
        self.countdownSubtitleLabel.text = @"This policy's documents have already been sent.";
    } else if ([self.policyStatus isEqualToString:@"cancelled"]) {
        self.countdownLabel.text = @"Cancelled";
        self.countdownSubtitleLabel.text = @"This policy was cancelled and will not send.";
    } else if (self.lastCheckinAt) {
        NSDate *deadline = [EZInsuranceDateUtils deadlineFromLastCheckinAt:self.lastCheckinAt
                                                              frequencyHours:self.frequencyHours];
        self.countdownLabel.text = [EZInsuranceDateUtils countdownStringFromNowUntilDeadline:deadline];
        self.countdownSubtitleLabel.text = [NSString stringWithFormat:
            @"Check in at least every %ld hours or the files below are sent automatically.", (long)self.frequencyHours];
    } else {
        self.countdownLabel.text = @"—";
        self.countdownSubtitleLabel.text = @"";
    }
}

// ── Files section ────────────────────────────────────────────────────────

- (UIView *)ez_buildFilesSection {
    UIButton *uploadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [uploadButton setTitle:@"Add Files" forState:UIControlStateNormal];
    [uploadButton setImage:[UIImage systemImageNamed:@"paperclip"] forState:UIControlStateNormal];
    [uploadButton addTarget:self action:@selector(ez_uploadFilesTapped)
            forControlEvents:UIControlEventTouchUpInside];

    self.filesStackView = [[UIStackView alloc] init];
    self.filesStackView.axis = UILayoutConstraintAxisVertical;
    self.filesStackView.spacing = 8;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[uploadButton, self.filesStackView]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    return [self ez_sectionWithTitle:@"Files" content:stack];
}

- (void)ez_uploadFilesTapped {
    if (!self.policyID) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Photos or Videos" style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [self ez_presentPhotoPicker];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Files" style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [self ez_presentDocumentPicker];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    // Action sheets present as a popover on iPad — without a source, this
    // crashes there instead of just looking wrong, so anchor it to the
    // button that triggered it.
    sheet.popoverPresentationController.sourceView = self.view;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)ez_presentDocumentPicker {
    UTType *anyType = UTTypeItem;
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[anyType] asCopy:YES];
    // asCopy:YES — the system copies picked files into a temp location this
    // app already owns, so there's no security-scoped-resource dance to
    // get right here; we can hand the URL straight to the upload call.
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        [self ez_beginUploadForFileURL:url];
    }
}

// ── Photos/videos picker ─────────────────────────────────────────────────
// PHPickerViewController runs out-of-process and needs no photo-library
// permission at all — the app only ever sees the items the user actually
// picked, nothing else in their library. This is deliberately the modern
// picker, not the older UIImagePickerController.

- (void)ez_presentPhotoPicker {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.selectionLimit = 0; // 0 = unlimited
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
        PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter,
    ]];

    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    for (PHPickerResult *result in results) {
        [self ez_loadAndUploadPickerResult:result];
    }
}

- (void)ez_loadAndUploadPickerResult:(PHPickerResult *)result {
    NSItemProvider *provider = result.itemProvider;
    NSString *typeIdentifier = provider.registeredTypeIdentifiers.firstObject;
    if (!typeIdentifier.length) {
        [self ez_presentError:@"Could not read that item from Photos."];
        return;
    }
    NSString *suggestedName = provider.suggestedName;

    __weak typeof(self) weakSelf = self;
    [provider loadFileRepresentationForTypeIdentifier:typeIdentifier
                                      completionHandler:^(NSURL *sourceURL, NSError *error) {
        // sourceURL is only valid for the duration of this handler — PhotoKit
        // deletes the backing temp file as soon as it returns. Everything
        // that touches the file has to happen synchronously in here, before
        // handing a COPY of it off to the (asynchronous) upload call.
        if (!sourceURL || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf ez_presentError:@"Could not load that item from Photos."];
            });
            return;
        }

        NSString *filename = suggestedName.length ? suggestedName : sourceURL.lastPathComponent;
        if (!filename.pathExtension.length) {
            // suggestedName sometimes comes back without an extension —
            // without one, the upload's MIME-type detection falls back to
            // application/octet-stream and the recipient's device won't
            // know how to open it. Derive the right one from the UTI
            // instead of guessing.
            UTType *type = [UTType typeWithIdentifier:typeIdentifier];
            if (type.preferredFilenameExtension.length) {
                filename = [filename stringByAppendingPathExtension:type.preferredFilenameExtension];
            }
        }

        NSURL *uniqueSubdir = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:uniqueSubdir
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:nil];
        NSURL *localCopy = [uniqueSubdir URLByAppendingPathComponent:filename];

        NSError *copyError = nil;
        BOOL copied = [[NSFileManager defaultManager] copyItemAtURL:sourceURL toURL:localCopy error:&copyError];

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!copied) {
                EZLogf(EZLogLevelError, @"INSURANCE", @"Photo picker copy failed: %@", copyError);
                [strongSelf ez_presentError:@"Could not prepare that item for upload."];
                return;
            }
            [strongSelf ez_beginUploadForFileURL:localCopy];
        });
    }];
}

- (void)ez_beginUploadForFileURL:(NSURL *)fileURL {
    EZInsurancePendingUpload *pending = [[EZInsurancePendingUpload alloc] init];
    pending.filename = fileURL.lastPathComponent;
    [self.pendingUploads addObject:pending];
    [self ez_rebuildFileRows];

    __weak typeof(self) weakSelf = self;
    // Thumbnail generation now runs BEFORE the upload call starts (rather
    // than in parallel, as before) — the upload itself now needs the
    // thumbnail image up front to upload it alongside the main file. This
    // adds a small delay before the upload begins (usually well under a
    // second for a resize or single video frame grab), which is a
    // reasonable trade so this only has to be written once.
    [self ez_generateThumbnailForLocalURL:fileURL completion:^(UIImage *thumbnail) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (![strongSelf.pendingUploads containsObject:pending]) return; // shouldn't happen, but don't upload something the user already cancelled out of

        pending.thumbnail = thumbnail;
        [strongSelf ez_rebuildFileRows];

        [[EZInsurancePolicyManager shared] uploadFileAtURL:fileURL
                                                   policyID:strongSelf.policyID
                                                  thumbnail:thumbnail
                                                   progress:nil // per-row percentage is a nice upgrade for later, not needed for a working version
                                                 completion:^(NSDictionary *fileRecord, NSString *errorMessage) {
            typeof(self) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            [strongSelf2.pendingUploads removeObject:pending];

            if (errorMessage) {
                [strongSelf2 ez_presentError:[NSString stringWithFormat:@"%@: %@", pending.filename, errorMessage]];
                [strongSelf2 ez_rebuildFileRows];
                return;
            }

            NSString *storagePath = fileRecord[@"storage_path"];
            NSString *fileID = fileRecord[@"id"];
            if (thumbnail && storagePath.length) {
                strongSelf2.thumbnailCache[storagePath] = thumbnail;
                if (fileID.length) {
                    // Cache to disk now too, not just memory — so it's
                    // already there next time this policy is opened, no
                    // network fetch needed for files uploaded this way.
                    [strongSelf2 ez_writeThumbnailToDisk:thumbnail fileID:fileID];
                }
            }

            [strongSelf2.files addObject:fileRecord];
            [strongSelf2 ez_rebuildFileRows];
        }];
    }];
}

// ── Thumbnails ────────────────────────────────────────────────────────────

- (UIImageView *)ez_makeThumbnailImageView {
    UIImageView *imageView = [[UIImageView alloc] init];
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.layer.cornerRadius = 8;
    imageView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    imageView.tintColor = [UIColor secondaryLabelColor];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    [imageView.widthAnchor constraintEqualToConstant:48].active = YES;
    [imageView.heightAnchor constraintEqualToConstant:48].active = YES;
    return imageView;
}

- (UIImage *)ez_genericIconForMimeType:(NSString *)mimeType {
    NSString *symbolName = @"doc.fill";
    if ([mimeType hasPrefix:@"image/"])            symbolName = @"photo.fill";
    else if ([mimeType hasPrefix:@"video/"])       symbolName = @"video.fill";
    else if ([mimeType isEqualToString:@"application/pdf"]) symbolName = @"doc.richtext.fill";

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20
                                                                                          weight:UIImageSymbolWeightRegular];
    return [UIImage systemImageNamed:symbolName withConfiguration:config];
}

// Generates a small square thumbnail directly from the LOCAL file, before
// it's uploaded — this only works because we still have the file on disk
// at this point. Runs off the main thread since decoding a full-size image
// or seeking a video frame isn't free; only the completion block touches UI.
- (void)ez_generateThumbnailForLocalURL:(NSURL *)localURL completion:(void (^)(UIImage * _Nullable thumbnail))completion {
    static NSSet<NSString *> *imageExtensions;
    static NSSet<NSString *> *videoExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageExtensions = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"heic", @"heif", @"gif", @"webp", @"bmp", @"tiff", nil];
        videoExtensions = [NSSet setWithObjects:@"mp4", @"mov", @"m4v", @"avi", nil];
    });

    NSString *extension = localURL.pathExtension.lowercaseString;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UIImage *thumbnail = nil;

        if ([imageExtensions containsObject:extension]) {
            UIImage *fullImage = [UIImage imageWithContentsOfFile:localURL.path];
            thumbnail = [self ez_squareThumbnailFromImage:fullImage];
        } else if ([videoExtensions containsObject:extension]) {
            AVAsset *asset = [AVAsset assetWithURL:localURL];
            AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
            generator.appliesPreferredTrackTransform = YES;
            NSError *frameError = nil;
            CGImageRef frame = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&frameError];
            if (frame) {
                UIImage *frameImage = [UIImage imageWithCGImage:frame];
                CGImageRelease(frame);
                thumbnail = [self ez_squareThumbnailFromImage:frameImage];
            }
        }
        // Any other type (PDF, docs, etc.) just falls through to nil —
        // ez_rebuildFileRows falls back to a generic icon in that case.

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(thumbnail);
        });
    });
}

- (nullable UIImage *)ez_squareThumbnailFromImage:(UIImage *)image {
    if (!image || image.size.width <= 0 || image.size.height <= 0) return nil;

    CGSize targetSize = CGSizeMake(96, 96); // 2x for a 48pt image view
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGSize imageSize = image.size;
        CGFloat scale = MAX(targetSize.width / imageSize.width, targetSize.height / imageSize.height);
        CGSize scaledSize = CGSizeMake(imageSize.width * scale, imageSize.height * scale);
        CGRect drawRect = CGRectMake((targetSize.width - scaledSize.width) / 2.0,
                                      (targetSize.height - scaledSize.height) / 2.0,
                                      scaledSize.width, scaledSize.height);
        [image drawInRect:drawRect];
    }];
}

// ── Full preview ─────────────────────────────────────────────────────────
// Files live in a private storage bucket, so "tap to preview" means
// actually downloading the real content first — there's no shortcut here,
// a thumbnail (even a real one, when we have one) isn't the file itself.

- (void)ez_previewFileRecord:(NSDictionary *)record {
    NSString *storagePath = record[@"storage_path"];
    NSString *filename = record[@"original_filename"] ?: @"File";
    NSString *mimeType = record[@"mime_type"];
    if (!storagePath.length) return;

    UIActivityIndicatorView *loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    loadingSpinner.center = self.view.center;
    loadingSpinner.hidesWhenStopped = YES;
    [self.view addSubview:loadingSpinner];
    [loadingSpinner startAnimating];
    self.view.userInteractionEnabled = NO; // guard against a second tap firing a second download mid-flight

    __weak typeof(self) weakSelf = self;
    [[EZInsurancePolicyManager shared] downloadFileWithStoragePath:storagePath
                                                    originalFilename:filename
                                                            mimeType:mimeType
                                                         completion:^(NSURL *localFileURL, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        [loadingSpinner stopAnimating];
        [loadingSpinner removeFromSuperview];
        strongSelf.view.userInteractionEnabled = YES;

        if (errorMessage || !localFileURL) {
            [strongSelf ez_presentError:errorMessage ?: @"Could not load that file."];
            return;
        }

        // Clean up the previous preview's temp file before starting a new
        // one, so a long session browsing several attachments doesn't
        // quietly accumulate one download per tap on disk.
        if (strongSelf.previewingTempFileURL) {
            [[NSFileManager defaultManager] removeItemAtURL:strongSelf.previewingTempFileURL.URLByDeletingLastPathComponent
                                                       error:nil];
        }
        strongSelf.previewingTempFileURL = localFileURL;

        // Backfill a thumbnail for this file if it doesn't have one yet —
        // this is what lets files uploaded before thumbnail_storage_path
        // existed get a real thumbnail without re-uploading anything: the
        // preview tap already downloaded the file, so this reuses THAT
        // download rather than fetching it again separately.
        BOOL alreadyHasThumbnail = strongSelf.thumbnailCache[storagePath] != nil;
        if (!alreadyHasThumbnail) {
            [strongSelf ez_backfillThumbnailFromDownloadedFile:localFileURL forRecord:record];
        }

        EZInsurancePreviewItem *item = [[EZInsurancePreviewItem alloc] init];
        item.previewItemURL = localFileURL;
        item.previewItemTitle = filename;
        strongSelf.currentPreviewItem = item;

        id notesValue = record[@"notes"];
        NSString *notes = [notesValue isKindOfClass:[NSString class]] ? notesValue : nil;

        if ([mimeType hasPrefix:@"image/"] || [mimeType hasPrefix:@"video/"]) {
            // The custom immersive viewer — title, zoomable image or video
            // player, notes card. Everything else (PDFs, documents) still
            // goes through QLPreviewController below, where a custom
            // layout doesn't really make sense.
            EZInsuranceFilePreviewViewController *preview =
                [[EZInsuranceFilePreviewViewController alloc] initWithFileURL:localFileURL
                                                                       mimeType:mimeType
                                                                          title:filename
                                                                          notes:notes];
            [strongSelf presentViewController:preview animated:YES completion:nil];
            return;
        }

        QLPreviewController *previewController = [[QLPreviewController alloc] init];
        previewController.dataSource = strongSelf;
        // Presented modally (not pushed) so QLPreviewController supplies
        // its own full-screen "Done" button and swipe-down dismissal —
        // dismissing lands right back on this row, thumbnail unchanged.
        [strongSelf presentViewController:previewController animated:YES completion:nil];
    }];
}

// For files uploaded before thumbnail_storage_path existed. Generates a
// thumbnail from a file that's already been downloaded (for preview),
// shows it immediately (memory + disk cache, no need to wait on network),
// then best-effort saves it back to the server so it's there for every
// future open too — on this device or any other — not just this one.
- (void)ez_backfillThumbnailFromDownloadedFile:(NSURL *)localFileURL forRecord:(NSDictionary *)record {
    NSString *storagePath = record[@"storage_path"];
    NSString *fileID = record[@"id"];
    if (!storagePath.length || !fileID.length) return;

    __weak typeof(self) weakSelf = self;
    [self ez_generateThumbnailForLocalURL:localFileURL completion:^(UIImage *thumbnail) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !thumbnail) return; // non-image/video files still just don't get one, same as at upload time

        strongSelf.thumbnailCache[storagePath] = thumbnail;
        [strongSelf ez_writeThumbnailToDisk:thumbnail fileID:fileID];
        [strongSelf ez_rebuildFileRows];

        [[EZInsurancePolicyManager shared] backfillThumbnailImage:thumbnail
                                                          forFileID:fileID
                                                           policyID:strongSelf.policyID
                                                         completion:^(NSString *thumbnailStoragePath, NSString *errorMessage) {
            // Best-effort — this device already has it cached either way
            // (above), so a failure here just means another device (or a
            // reinstall on this one) would need one more tap to re-derive
            // it. Not worth an alert over.
            if (errorMessage) {
                EZLogf(EZLogLevelError, @"INSURANCE", @"Thumbnail backfill failed for file %@: %@", fileID, errorMessage);
                return;
            }
            typeof(self) strongSelf2 = weakSelf;
            if (!strongSelf2 || !thumbnailStoragePath.length) return;

            // Keep the in-memory file record consistent with the server —
            // nothing currently reads thumbnail_storage_path back out of
            // self.files after this point in the same session, but a
            // stale local copy is the kind of thing that bites later.
            NSUInteger index = [strongSelf2.files indexOfObjectPassingTest:
                ^BOOL(NSDictionary *candidate, NSUInteger idx, BOOL *stop) {
                return [candidate[@"id"] isEqual:fileID];
            }];
            if (index != NSNotFound) {
                NSMutableDictionary *updated = [strongSelf2.files[index] mutableCopy];
                updated[@"thumbnail_storage_path"] = thumbnailStoragePath;
                strongSelf2.files[index] = [updated copy];
            }
        }];
    }];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return self.currentPreviewItem ? 1 : 0;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return self.currentPreviewItem;
}

- (void)ez_rebuildFileRows {
    for (UIView *row in self.filesStackView.arrangedSubviews) {
        [self.filesStackView removeArrangedSubview:row];
        [row removeFromSuperview];
    }

    if (self.pendingUploads.count == 0 && self.files.count == 0) {
        UILabel *emptyLabel = [[UILabel alloc] init];
        emptyLabel.adjustsFontSizeToFitWidth = YES;
        emptyLabel.minimumScaleFactor = 0.5;
        emptyLabel.text = @"No files uploaded yet.";
        emptyLabel.textColor = [UIColor secondaryLabelColor];
        emptyLabel.font = [UIFont systemFontOfSize:14];
        [self.filesStackView addArrangedSubview:emptyLabel];
        return;
    }

    for (EZInsurancePendingUpload *pending in self.pendingUploads) {
        UIImageView *thumbnailView = [self ez_makeThumbnailImageView];
        if (pending.thumbnail) {
            thumbnailView.image = pending.thumbnail;
        } else {
            thumbnailView.image = [UIImage systemImageNamed:@"arrow.up.doc"];
            thumbnailView.contentMode = UIViewContentModeCenter;
        }

        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];

        UILabel *label = [[UILabel alloc] init];
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.5;
        label.text = [NSString stringWithFormat:@"Uploading %@…", pending.filename];
        label.font = [UIFont systemFontOfSize:15];
        label.numberOfLines = 1;
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[thumbnailView, spinner, label]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 10;
        row.alignment = UIStackViewAlignmentCenter;
        [self.filesStackView addArrangedSubview:row];
    }

    __weak typeof(self) weakSelf = self;
    for (NSDictionary *record in self.files) {
        NSString *filename = record[@"original_filename"] ?: @"Unnamed file";
        NSString *mimeType = record[@"mime_type"] ?: @"";
        NSString *storagePath = record[@"storage_path"];
        NSString *fileID = record[@"id"];
        long long sizeBytes = [record[@"size_bytes"] longLongValue];
        id notesValue = record[@"notes"];
        NSString *notes = [notesValue isKindOfClass:[NSString class]] ? notesValue : nil;
        BOOL isRenaming = fileID.length && [fileID isEqualToString:self.renamingFileID];

        UIImageView *thumbnailView = [self ez_makeThumbnailImageView];
        UIImage *cachedThumbnail = storagePath.length ? self.thumbnailCache[storagePath] : nil;
        if (cachedThumbnail) {
            thumbnailView.image = cachedThumbnail;
            thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        } else {
            thumbnailView.image = [self ez_genericIconForMimeType:mimeType];
            thumbnailView.contentMode = UIViewContentModeCenter;
        }

        UIButton *moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [moreButton setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
        moreButton.tintColor = [UIColor secondaryLabelColor];
        moreButton.menu = [self ez_fileOptionsMenuForRecord:record];
        moreButton.showsMenuAsPrimaryAction = YES; // native UIMenu on tap — no UIAlertController involved

        if (isRenaming) {
            // Inline rename — a real interactive text field, not wrapped in
            // the tap-to-preview control below (a UIControl with
            // userInteractionEnabled=NO subviews, which is how that tap
            // target works, would make a nested text field untappable and
            // uneditable). Renaming a row temporarily trades away
            // tap-to-preview for that row, which is the right trade — you
            // don't want a stray tap launching a file download while
            // you're mid-edit.
            UITextField *nameField = [[UITextField alloc] init];
            nameField.text = filename;
            nameField.font = [UIFont systemFontOfSize:15];
            nameField.borderStyle = UITextBorderStyleRoundedRect;
            nameField.returnKeyType = UIReturnKeyDone;
            nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
            nameField.autocorrectionType = UITextAutocorrectionTypeNo;
            [nameField addAction:[UIAction actionWithHandler:^(UIAction *action) {
                [nameField resignFirstResponder];
            }] forControlEvents:UIControlEventEditingDidEndOnExit];
            [nameField addAction:[UIAction actionWithHandler:^(UIAction *action) {
                [weakSelf ez_commitRenameForRecord:record newName:nameField.text];
            }] forControlEvents:UIControlEventEditingDidEnd];

            UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[thumbnailView, nameField]];
            row.axis = UILayoutConstraintAxisHorizontal;
            row.alignment = UIStackViewAlignmentCenter;
            row.spacing = 10;
            [self.filesStackView addArrangedSubview:row];
            [nameField becomeFirstResponder];
            continue;
        }

        UILabel *nameLabel = [[UILabel alloc] init];
        nameLabel.adjustsFontSizeToFitWidth = YES;
        nameLabel.minimumScaleFactor = 0.5;
        nameLabel.text = filename;
        nameLabel.font = [UIFont systemFontOfSize:15];
        nameLabel.numberOfLines = 1;
        nameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

        UILabel *sizeLabel = [[UILabel alloc] init];
        sizeLabel.adjustsFontSizeToFitWidth = YES;
        sizeLabel.minimumScaleFactor = 0.5;
        sizeLabel.text = [NSByteCountFormatter stringFromByteCount:sizeBytes countStyle:NSByteCountFormatterCountStyleFile];
        sizeLabel.font = [UIFont systemFontOfSize:12];
        sizeLabel.textColor = [UIColor secondaryLabelColor];

        NSArray<UIView *> *textStackViews = @[nameLabel, sizeLabel];
        if (notes.length) {
            UILabel *notesPreviewLabel = [[UILabel alloc] init];
            notesPreviewLabel.adjustsFontSizeToFitWidth = YES;
            notesPreviewLabel.minimumScaleFactor = 0.5;
            notesPreviewLabel.text = notes;
            notesPreviewLabel.font = [UIFont italicSystemFontOfSize:12];
            notesPreviewLabel.textColor = [UIColor secondaryLabelColor];
            notesPreviewLabel.numberOfLines = 2;
            textStackViews = @[nameLabel, sizeLabel, notesPreviewLabel];
        }

        UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:textStackViews];
        textStack.axis = UILayoutConstraintAxisVertical;
        textStack.spacing = 1;
        textStack.userInteractionEnabled = NO; // let touches pass through to previewControl below
        [textStack setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        // Thumbnail + name/size/notes together are one tappable region
        // that opens the full preview. The "more" button is a separate
        // sibling control, deliberately outside this one, so tapping it
        // never also triggers a preview download.
        UIStackView *previewContent = [[UIStackView alloc] initWithArrangedSubviews:@[thumbnailView, textStack]];
        previewContent.axis = UILayoutConstraintAxisHorizontal;
        previewContent.spacing = 10;
        previewContent.alignment = UIStackViewAlignmentCenter;
        previewContent.userInteractionEnabled = NO;
        previewContent.translatesAutoresizingMaskIntoConstraints = NO;

        UIControl *previewControl = [[UIControl alloc] init];
        [previewControl addSubview:previewContent];
        [NSLayoutConstraint activateConstraints:@[
            [previewContent.topAnchor constraintEqualToAnchor:previewControl.topAnchor],
            [previewContent.bottomAnchor constraintEqualToAnchor:previewControl.bottomAnchor],
            [previewContent.leadingAnchor constraintEqualToAnchor:previewControl.leadingAnchor],
            [previewContent.trailingAnchor constraintEqualToAnchor:previewControl.trailingAnchor],
        ]];
        [previewControl addAction:[UIAction actionWithHandler:^(UIAction *action) {
            [weakSelf ez_previewFileRecord:record];
        }] forControlEvents:UIControlEventTouchUpInside];

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[previewControl, moreButton]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 10;
        [self.filesStackView addArrangedSubview:row];
    }
}

// ── File row menu (rename / notes / delete) ─────────────────────────────
// A native UIMenu, not a UIAlertController action sheet — genuinely less
// code this way (UIButton.menu handles presentation entirely on its own),
// and it's the more current pattern for exactly this "a few actions on
// one item" case. Delete still confirms via a real alert afterward —
// that's a destructive confirmation, which is squarely what alerts
// should be used for.

- (UIMenu *)ez_fileOptionsMenuForRecord:(NSDictionary *)record {
    __weak typeof(self) weakSelf = self;

    UIAction *renameAction = [UIAction actionWithTitle:@"Rename"
                                                    image:[UIImage systemImageNamed:@"pencil"]
                                               identifier:nil
                                                  handler:^(UIAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.renamingFileID = record[@"id"];
        [strongSelf ez_rebuildFileRows];
    }];

    UIAction *notesAction = [UIAction actionWithTitle:@"Edit Notes"
                                                   image:[UIImage systemImageNamed:@"note.text"]
                                              identifier:nil
                                                 handler:^(UIAction *action) {
        [weakSelf ez_editNotesForFileRecord:record];
    }];

    UIAction *deleteAction = [UIAction actionWithTitle:@"Delete"
                                                    image:[UIImage systemImageNamed:@"trash"]
                                               identifier:nil
                                                  handler:^(UIAction *action) {
        [weakSelf ez_confirmDeleteFileRecord:record];
    }];
    deleteAction.attributes = UIMenuElementAttributesDestructive;

    return [UIMenu menuWithTitle:@"" children:@[renameAction, notesAction, deleteAction]];
}

- (void)ez_commitRenameForRecord:(NSDictionary *)record newName:(NSString *)newNameRaw {
    NSString *fileID = record[@"id"];
    NSString *currentName = record[@"original_filename"] ?: @"";
    NSString *newName = [newNameRaw stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    self.renamingFileID = nil; // leaving rename mode either way, below

    if (!newName.length || [newName isEqualToString:currentName]) {
        [self ez_rebuildFileRows]; // no real change — just revert to the static label
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[EZInsurancePolicyManager shared] renameFileWithID:fileID
                                              newFilename:newName
                                               completion:^(BOOL success, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (!success) {
            // A genuine failure — this is exactly the kind of thing an
            // alert IS the right tool for.
            [strongSelf ez_presentError:errorMessage ?: @"Could not rename file."];
            [strongSelf ez_rebuildFileRows];
            return;
        }

        NSUInteger index = [strongSelf.files indexOfObjectPassingTest:
            ^BOOL(NSDictionary *candidate, NSUInteger idx, BOOL *stop) {
            return [candidate[@"id"] isEqual:fileID];
        }];
        if (index != NSNotFound) {
            NSMutableDictionary *updated = [strongSelf.files[index] mutableCopy];
            updated[@"original_filename"] = newName;
            strongSelf.files[index] = [updated copy];
        }
        [strongSelf ez_rebuildFileRows];
    }];
}

// ── Notes ─────────────────────────────────────────────────────────────────

- (void)ez_editNotesForFileRecord:(NSDictionary *)record {
    NSString *fileID = record[@"id"];
    if (!fileID.length) return;
    NSString *filename = record[@"original_filename"] ?: @"Notes";
    id notesValue = record[@"notes"];
    NSString *existingNotes = [notesValue isKindOfClass:[NSString class]] ? notesValue : nil;

    __weak typeof(self) weakSelf = self;
    EZInsuranceNotesEditorViewController *editor = [[EZInsuranceNotesEditorViewController alloc]
        initWithFilename:filename
           existingNotes:existingNotes
              completion:^(NSString *updatedNotes) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        [[EZInsurancePolicyManager shared] updateNotesForFileID:fileID
                                                            notes:updatedNotes
                                                       completion:^(BOOL success, NSString *errorMessage) {
            typeof(self) strongSelf2 = weakSelf;
            if (!strongSelf2) return;
            if (!success) {
                [strongSelf2 ez_presentError:errorMessage ?: @"Could not save notes."];
                return;
            }
            NSUInteger index = [strongSelf2.files indexOfObjectPassingTest:
                ^BOOL(NSDictionary *candidate, NSUInteger idx, BOOL *stop) {
                return [candidate[@"id"] isEqual:fileID];
            }];
            if (index != NSNotFound) {
                NSMutableDictionary *updated = [strongSelf2.files[index] mutableCopy];
                updated[@"notes"] = updatedNotes ?: [NSNull null];
                strongSelf2.files[index] = [updated copy];
                [strongSelf2 ez_rebuildFileRows];
            }
        }];
    }];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    [self presentViewController:nav animated:YES completion:nil];
}

// ── Delete (now behind a confirmation — see the header changelog for why) ──

- (void)ez_confirmDeleteFileRecord:(NSDictionary *)record {
    NSString *filename = record[@"original_filename"] ?: @"this file";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete File?"
        message:[NSString stringWithFormat:@"\u201c%@\u201d will be permanently removed. This can't be undone.", filename]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *action) {
        [weakSelf ez_deleteFileRecord:record];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ez_deleteFileRecord:(NSDictionary *)record {
    NSString *fileID      = record[@"id"];
    NSString *storagePath = record[@"storage_path"];
    if (!fileID.length || !storagePath.length) return;

    __weak typeof(self) weakSelf = self;
    [[EZInsurancePolicyManager shared] deleteFileWithID:fileID
                                              storagePath:storagePath
                                               completion:^(BOOL success, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!success) {
            [strongSelf ez_presentError:errorMessage ?: @"Could not delete that file."];
            return;
        }
        [strongSelf.files removeObject:record];
        [strongSelf ez_rebuildFileRows];
    }];
}

// ── Recipients section ───────────────────────────────────────────────────

- (UIView *)ez_buildRecipientsSection {
    self.recipientEmailField = [self ez_textFieldWithPlaceholder:@"Recipient email address" secure:NO];
    self.recipientEmailField.keyboardType = UIKeyboardTypeEmailAddress;

    UIButton *addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [addButton setTitle:@"Add Extra Recipient" forState:UIControlStateNormal];
    [addButton addTarget:self action:@selector(ez_addRecipientTapped)
        forControlEvents:UIControlEventTouchUpInside];

    UIStackView *inputRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.recipientEmailField, addButton]];
    inputRow.axis = UILayoutConstraintAxisHorizontal;
    inputRow.spacing = 8;
    inputRow.alignment = UIStackViewAlignmentCenter;

    self.recipientsStackView = [[UIStackView alloc] init];
    self.recipientsStackView.axis = UILayoutConstraintAxisVertical;
    self.recipientsStackView.spacing = 8;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[inputRow, self.recipientsStackView]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    return [self ez_sectionWithTitle:@"Send Documents To" content:stack];
}

- (void)ez_addRecipientTapped {
    NSString *email = [self.recipientEmailField.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (email.length == 0 || ![email containsString:@"@"]) {
        [self ez_presentError:@"Enter a valid email address."];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [[EZInsurancePolicyManager shared] addRecipientEmail:email
                                                  policyID:self.policyID
                                                completion:^(NSDictionary *recipientRecord, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (errorMessage) {
            [strongSelf ez_presentError:errorMessage];
            return;
        }

        strongSelf.recipientEmailField.text = @"";
        [strongSelf.recipients addObject:recipientRecord];
        [strongSelf ez_rebuildRecipientRows];
    }];
}

- (void)ez_rebuildRecipientRows {
    for (UIView *row in self.recipientsStackView.arrangedSubviews) {
        [self.recipientsStackView removeArrangedSubview:row];
        [row removeFromSuperview];
    }

    if (self.recipients.count == 0) {
        UILabel *emptyLabel = [[UILabel alloc] init];
        emptyLabel.adjustsFontSizeToFitWidth = YES;
        emptyLabel.minimumScaleFactor = 0.5;
        emptyLabel.text = @"No recipients yet. Add at least one before sending.";
        emptyLabel.textColor = [UIColor secondaryLabelColor];
        emptyLabel.font = [UIFont systemFontOfSize:14];
        [self.recipientsStackView addArrangedSubview:emptyLabel];
        return;
    }

    __weak typeof(self) weakSelf = self;
    for (NSDictionary *record in self.recipients) {
        NSString *email = record[@"email"] ?: @"";
        BOOL alreadySent = ![record[@"sent_at"] isEqual:[NSNull null]] && record[@"sent_at"] != nil;

        UILabel *emailLabel = [[UILabel alloc] init];
        emailLabel.adjustsFontSizeToFitWidth = YES;
        emailLabel.minimumScaleFactor = 0.5;
        emailLabel.text = alreadySent ? [NSString stringWithFormat:@"%@ ✓ sent", email] : email;
        emailLabel.font = [UIFont systemFontOfSize:15];
        emailLabel.numberOfLines = 1;
        emailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [emailLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        UIAction *deleteAction = [UIAction actionWithTitle:@"" image:[UIImage systemImageNamed:@"trash"]
                                                  identifier:nil handler:^(UIAction *action) {
            [weakSelf ez_deleteRecipientRecord:record];
        }];
        UIButton *deleteButton = [UIButton buttonWithType:UIButtonTypeSystem primaryAction:deleteAction];
        deleteButton.tintColor = [UIColor systemRedColor];

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[emailLabel, deleteButton]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 10;
        [self.recipientsStackView addArrangedSubview:row];
    }
}

- (void)ez_deleteRecipientRecord:(NSDictionary *)record {
    NSString *recipientID = record[@"id"];
    if (!recipientID.length) return;

    __weak typeof(self) weakSelf = self;
    [[EZInsurancePolicyManager shared] deleteRecipientWithID:recipientID
                                                     policyID:self.policyID
                                                   completion:^(BOOL success, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!success) {
            [strongSelf ez_presentError:errorMessage ?: @"Could not remove that recipient."];
            return;
        }
        [strongSelf.recipients removeObject:record];
        [strongSelf ez_rebuildRecipientRows];
    }];
}

// ── Actions section ─────────────────────────────────────────────────────────

- (UIView *)ez_buildActionsSection {
    UIButton *checkInButton = [self ez_actionButtonWithTitle:@"Check In (Reset Timer)" color:[UIColor systemGreenColor]];
    [checkInButton addTarget:self action:@selector(ez_checkInTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *sendNowButton = [self ez_actionButtonWithTitle:@"Send Now" color:[UIColor systemOrangeColor]];
    [sendNowButton addTarget:self action:@selector(ez_sendNowTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *cancelButton = [self ez_actionButtonWithTitle:@"Cancel Policy" color:[UIColor systemRedColor]];
    [cancelButton addTarget:self action:@selector(ez_cancelPolicyTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[checkInButton, sendNowButton, cancelButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    return stack; // no title wrapper — these read fine on their own under the countdown
}

- (UIButton *)ez_actionButtonWithTitle:(NSString *)title color:(UIColor *)color {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = color;
    button.layer.cornerRadius = 10;
    button.contentEdgeInsets = UIEdgeInsetsMake(12, 20, 12, 20);
    return button;
}

// Every destructive/state-changing action needs the policy password. This
// one alert is shared by all three so the "enter your policy password"
// experience is identical everywhere instead of three subtly different
// implementations.
- (void)ez_promptForPasswordWithTitle:(NSString *)title
                                message:(NSString *)message
                     confirmButtonTitle:(NSString *)confirmTitle
                               destructive:(BOOL)destructive
                                 handler:(void (^)(NSString *password))handler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Policy password";
        textField.secureTextEntry = YES;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:confirmTitle
                                                style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                              handler:^(UIAlertAction *action) {
        NSString *password = alert.textFields.firstObject.text ?: @"";
        handler(password);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ez_checkInTapped {
    __weak typeof(self) weakSelf = self;
    [self ez_promptForPasswordWithTitle:@"Check In"
                                  message:@"Resets the countdown. Enter your policy password."
                       confirmButtonTitle:@"Check In"
                              destructive:NO
                                  handler:^(NSString *password) {
        [[EZInsurancePolicyManager shared] checkInPolicyID:weakSelf.policyID
                                                     password:password
                                                   completion:^(BOOL success, NSString *errorMessage) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!success) {
                [strongSelf ez_presentError:errorMessage ?: @"Check-in failed."];
                return;
            }
            strongSelf.lastCheckinAt = [NSDate date];
            [strongSelf ez_refreshCountdownDisplay];
        }];
    }];
}

- (void)ez_sendNowTapped {
    __weak typeof(self) weakSelf = self;
    [self ez_promptForPasswordWithTitle:@"Send Now"
                                  message:@"This immediately emails every uploaded file to every recipient and cannot be undone. Enter your policy password to confirm."
                       confirmButtonTitle:@"Send Now"
                              destructive:YES
                                  handler:^(NSString *password) {
        [[EZInsurancePolicyManager shared] sendNowPolicyID:weakSelf.policyID
                                                     password:password
                                                   completion:^(BOOL success, NSInteger filesSent, NSInteger recipientsSent, NSString *errorMessage) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (!success) {
                [strongSelf ez_presentError:errorMessage ?: @"Send failed."];
                // Even on failure, some recipients may have gone through —
                // refresh so the ✓ marks on the recipient list are accurate.
                [strongSelf ez_loadFilesAndRecipients];
                return;
            }

            strongSelf.policyStatus = @"released";
            [strongSelf ez_refreshCountdownDisplay];
            [strongSelf ez_loadFilesAndRecipients];

            UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:@"Sent"
                message:[NSString stringWithFormat:@"%ld file(s) sent to %ld recipient(s).", (long)filesSent, (long)recipientsSent]
                preferredStyle:UIAlertControllerStyleAlert];
            [confirmAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:confirmAlert animated:YES completion:nil];
        }];
    }];
}

- (void)ez_cancelPolicyTapped {
    __weak typeof(self) weakSelf = self;
    [self ez_promptForPasswordWithTitle:@"Cancel Policy"
                                  message:@"This stops the countdown permanently — nothing will ever be sent. Enter your policy password to confirm."
                       confirmButtonTitle:@"Cancel Policy"
                              destructive:YES
                                  handler:^(NSString *password) {
        [[EZInsurancePolicyManager shared] cancelPolicyID:weakSelf.policyID
                                                    password:password
                                                  completion:^(BOOL success, NSString *errorMessage) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!success) {
                [strongSelf ez_presentError:errorMessage ?: @"Cancel failed."];
                return;
            }
            strongSelf.policyStatus = @"cancelled";
            [strongSelf ez_refreshCountdownDisplay];
            [strongSelf.navigationController popViewControllerAnimated:YES];
        }];
    }];
}

// ── Loading files/recipients for an existing policy ─────────────────────

- (void)ez_loadFilesAndRecipients {
    __weak typeof(self) weakSelf = self;
    [[EZInsurancePolicyManager shared] listFilesForPolicyID:self.policyID
                                                    completion:^(NSArray<NSDictionary *> *files, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (errorMessage) { [strongSelf ez_presentError:errorMessage]; return; }
        strongSelf.files = [files mutableCopy];
        [strongSelf ez_rebuildFileRows];
        // Kicked off right after the file list itself renders — thumbnails
        // pop in as each one resolves (disk cache is instant, network
        // fetches trickle in), rather than blocking the row list on them.
        [strongSelf ez_loadThumbnailsForCurrentFiles];
    }];

    [[EZInsurancePolicyManager shared] listRecipientsForPolicyID:self.policyID
                                                        completion:^(NSArray<NSDictionary *> *recipients, NSString *errorMessage) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (errorMessage) { [strongSelf ez_presentError:errorMessage]; return; }
        strongSelf.recipients = [recipients mutableCopy];
        [strongSelf ez_rebuildRecipientRows];
    }];
}

// ── Thumbnail disk cache ─────────────────────────────────────────────────
// Keyed by file id (a clean UUID — safe as a bare filename, unlike
// storage_path which contains slashes). Stored under NSCachesDirectory
// since this is entirely regenerable data (re-downloadable from
// thumbnail_storage_path) — exactly what that directory is for, and the
// system is free to purge it under storage pressure without correctness
// consequences, just a re-fetch next time.

- (NSURL *)ez_thumbnailCacheDirectory {
    NSURL *cachesDir = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                                inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [cachesDir URLByAppendingPathComponent:@"InsuranceThumbnails" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSURL *)ez_thumbnailCacheURLForFileID:(NSString *)fileID {
    return [[self ez_thumbnailCacheDirectory] URLByAppendingPathComponent:[fileID stringByAppendingPathExtension:@"jpg"]];
}

- (nullable UIImage *)ez_cachedThumbnailOnDiskForFileID:(NSString *)fileID {
    NSData *data = [NSData dataWithContentsOfURL:[self ez_thumbnailCacheURLForFileID:fileID]];
    return data ? [UIImage imageWithData:data] : nil;
}

- (void)ez_writeThumbnailToDisk:(UIImage *)image fileID:(NSString *)fileID {
    NSData *jpegData = UIImageJPEGRepresentation(image, 0.7);
    if (!jpegData) return;
    [jpegData writeToURL:[self ez_thumbnailCacheURLForFileID:fileID] atomically:YES];
}

// Checks memory cache, then disk cache, then falls back to a network fetch
// — in that order of cost — for every file that has a thumbnail to fetch.
- (void)ez_loadThumbnailsForCurrentFiles {
    for (NSDictionary *record in self.files) {
        NSString *storagePath = record[@"storage_path"];
        NSString *fileID = record[@"id"];
        id thumbnailPathValue = record[@"thumbnail_storage_path"];
        NSString *thumbnailStoragePath = [thumbnailPathValue isKindOfClass:[NSString class]] ? thumbnailPathValue : nil;

        if (!storagePath.length || !fileID.length || !thumbnailStoragePath.length) continue;
        if (self.thumbnailCache[storagePath]) continue; // already resolved (e.g. uploaded this session)

        UIImage *diskCached = [self ez_cachedThumbnailOnDiskForFileID:fileID];
        if (diskCached) {
            self.thumbnailCache[storagePath] = diskCached;
            continue;
        }

        __weak typeof(self) weakSelf = self;
        [[EZInsurancePolicyManager shared] downloadThumbnailDataWithStoragePath:thumbnailStoragePath
                                                                       completion:^(NSData *jpegData, NSString *errorMessage) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !jpegData) return; // a missing thumbnail just means this row keeps its generic icon — not worth an error alert
            UIImage *image = [UIImage imageWithData:jpegData];
            if (!image) return;
            strongSelf.thumbnailCache[storagePath] = image;
            [strongSelf ez_writeThumbnailToDisk:image fileID:fileID];
            [strongSelf ez_rebuildFileRows]; // each fetch resolves independently; rebuilding per-arrival is cheap and keeps rows updating as thumbnails come in rather than waiting for all of them
        }];
    }
    [self ez_rebuildFileRows]; // picks up anything resolved synchronously from disk cache above
}

// ── Error presentation ───────────────────────────────────────────────────

- (void)ez_presentError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
