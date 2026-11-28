//
//  EZSeahorseVideoViewController.m
//  EZCompleteUI
//
//  NSFW video composer for the ez-seahorse video actions. Mirrors the
//  provider playground's workflow:
//    1. Describe the scene (prompt).
//    2. Cast up to two characters — each an optional photo (run through
//       the same likeness check + presigned upload as image references)
//       or text-only (sex, name, looks).
//    3. Optionally pin a first and/or last frame image (not combinable
//       with character photos — the API renders framed shots from the
//       frame alone; the UI enforces the same rule the server does).
//    4. For videos over 15 seconds, choose Auto (the director plans
//       and renders) or Plan (a storyboard draft parks for editing:
//       per-shot beat, duration and explicit flag, then Render;
//       Cancel refunds in full).
//  The server charges coins at create and refunds in full on any
//  terminal failure; this screen polls video_status until the task
//  lands, then downloads the MP4 into the photo gallery directory.
//  Leaving mid-render is safe: on the next open, video_list finds the
//  account's open tasks and polling resumes.
//

#import "EZSeahorseVideoViewController.h"

#if !APPSTORE

#import "EZAuthManager.h"
#import "EZEntitlementManager.h"
#import "EZStoreKitManager.h"
#import "EZCoinStoreViewController.h"
#import "EZTheme.h"
#import "helpers.h"
#import <Vision/Vision.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *EZVideoLocalized(NSString *key) {
    NSString *localized = NSLocalizedString(key, nil);
    if (![localized isEqualToString:key]) return localized;
    NSString *englishPath = [[NSBundle mainBundle] pathForResource:@"en" ofType:@"lproj"];
    NSBundle *englishBundle = englishPath.length ? [NSBundle bundleWithPath:englishPath] : nil;
    return englishBundle
        ? [englishBundle localizedStringForKey:key value:key table:@"Localizable"]
        : localized;
}

// Face crop for the likeness check — the same approach as the image
// flow's crop in ViewController: bake orientation, cap the working
// size, detect the largest face, crop with padding. Returns nil when
// no face is found (callers fall back to a downscaled full image,
// which the check resolves as "unsure" and the flow proceeds).
static NSData * _Nullable EZVideoFaceCropJPEGData(UIImage *image) {
    if (!image || image.size.width < 1 || image.size.height < 1) return nil;
    CGSize workSize = image.size;
    CGFloat maxDim = MAX(workSize.width, workSize.height);
    if (maxDim > 1600) {
        CGFloat scale = 1600.0 / maxDim;
        workSize = CGSizeMake(workSize.width * scale, workSize.height * scale);
    }
    UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:workSize format:format];
    UIImage *flat = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
        [image drawInRect:CGRectMake(0, 0, workSize.width, workSize.height)];
    }];
    CGImageRef cg = flat.CGImage;
    if (!cg) return nil;
    CGFloat W = (CGFloat)CGImageGetWidth(cg);
    CGFloat H = (CGFloat)CGImageGetHeight(cg);
    VNDetectFaceRectanglesRequest *request = [[VNDetectFaceRectanglesRequest alloc] init];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    NSError *detectError = nil;
    CGRect bb = CGRectNull;
    if ([handler performRequests:@[request] error:&detectError]) {
        CGFloat bestArea = 0;
        for (VNFaceObservation *obs in request.results) {
            CGFloat area = obs.boundingBox.size.width * obs.boundingBox.size.height;
            if (area > bestArea) { bestArea = area; bb = obs.boundingBox; }
        }
    }
    if (CGRectIsNull(bb)) return nil;
    CGFloat fx = bb.origin.x * W;
    CGFloat fw = bb.size.width * W;
    CGFloat fh = bb.size.height * H;
    CGFloat fyTop = (1.0 - bb.origin.y - bb.size.height) * H;
    CGRect crop = CGRectMake(fx - fw * 0.45, fyTop - fh * 0.75, fw * 1.9, fh * 2.3);
    crop = CGRectIntersection(crop, CGRectMake(0, 0, W, H));
    if (CGRectIsNull(crop) || crop.size.width < 40 || crop.size.height < 40) return nil;
    CGImageRef croppedRef = CGImageCreateWithImageInRect(cg, crop);
    if (!croppedRef) return nil;
    UIImage *cropImage = [UIImage imageWithCGImage:croppedRef];
    CGImageRelease(croppedRef);
    return UIImageJPEGRepresentation(cropImage, 0.7);
}

static NSString *EZVideoSHA256Hex(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

// NSNull-safe reads of parsed server JSON: a null or mistyped value reads
// as the empty value instead of crashing (NSNull answers no integerValue,
// boolValue, doubleValue or isEqualToString:).
static NSInteger EZVideoInteger(id value) {
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}
static double EZVideoDouble(id value) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
}
static BOOL EZVideoBool(id value) {
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}
static NSString * _Nullable EZVideoString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}
static NSDictionary * _Nullable EZVideoDict(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static void EZVideoLoadImage(NSString * _Nullable urlString,
                             void (^completion)(UIImage * _Nullable image)) {
    NSURL *url = urlString.length ? [NSURL URLWithString:urlString] : nil;
    if (!url) { completion(nil); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:url];
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(image); });
    });
}

// The character studio (generate + save + manage library characters)
// lives in this file, below the composer.
@interface EZSeahorseCharacterStudioViewController : UIViewController
@property (nonatomic, copy, nullable) void (^onCharactersChanged)(void);
@end

typedef NS_ENUM(NSInteger, EZVideoPickerPurpose) {
    EZVideoPickerPurposeCast1 = 0,
    EZVideoPickerPurposeCast2 = 1,
    EZVideoPickerPurposeFirstFrame = 2,
    EZVideoPickerPurposeLastFrame = 3,
};

@interface EZSeahorseVideoViewController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UITextViewDelegate, UITextFieldDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, weak) UIView *activeInput;
@property (nonatomic, strong) UIStackView *stack;

// Eligibility / pricing state (rates come from the server).
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *rates;
@property (nonatomic) NSInteger maxDuration;
@property (nonatomic) NSInteger balance;
@property (nonatomic) BOOL idVerified;
@property (nonatomic) BOOL purchaseOK;
@property (nonatomic, strong) UILabel *gateLabel;

// Composer controls.
@property (nonatomic, strong) UITextView *promptView;
@property (nonatomic, strong) UISegmentedControl *resolutionSeg;
@property (nonatomic, strong) UISegmentedControl *durationSeg;
@property (nonatomic, strong) UISegmentedControl *modeSeg;
@property (nonatomic, strong) UISegmentedControl *ratioSeg;
@property (nonatomic, strong) UISwitch *autoChainSwitch;
@property (nonatomic, strong) UILabel *quoteLabel;
@property (nonatomic, strong) UIButton *createButton;

// Character slots (exactly two).
@property (nonatomic, strong) NSArray<UISwitch *> *castEnabled;
@property (nonatomic, strong) NSArray<UISegmentedControl *> *castSex;
@property (nonatomic, strong) NSArray<UITextField *> *castName;
@property (nonatomic, strong) NSArray<UITextField *> *castLooks;
@property (nonatomic, strong) NSArray<UIButton *> *castPhotoButton;
@property (nonatomic, strong) NSMutableArray<NSString *> *castPhotoURLs;   // asset URL or ""
@property (nonatomic, strong) NSMutableArray<UIImage *> *castPhotoImages;  // NSNull when none
@property (nonatomic, strong) NSArray<UISegmentedControl *> *castSource;   // 0 Photo, 1 Text, 2 Saved
@property (nonatomic, strong) NSArray<UIButton *> *castLibraryButton;
@property (nonatomic, strong) NSMutableArray<NSString *> *castLibraryIDs;  // chr_... or ""
@property (nonatomic, strong) NSArray<NSDictionary *> *savedCharacters;    // character_list cache
@property (nonatomic, strong) UIButton *studioButton;

// Frame pins.
@property (nonatomic, strong) UIButton *firstFrameButton;
@property (nonatomic, strong) UIButton *lastFrameButton;
@property (nonatomic, copy) NSString *firstFrameURL;
@property (nonatomic, copy) NSString *lastFrameURL;

// Run state.
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, copy) NSString *taskID;
@property (nonatomic) BOOL taskIsEditMode;
@property (nonatomic) BOOL busy;

// Storyboard editor.
@property (nonatomic, strong) UIStackView *storyboardStack;
@property (nonatomic, strong) UILabel *storyboardTotalLabel;
@property (nonatomic, strong) NSArray<NSDictionary *> *shotCards; // views per shot
@property (nonatomic, strong) NSDictionary *scene;
@property (nonatomic) NSInteger lockedSeconds;

@property (nonatomic) EZVideoPickerPurpose pickerPurpose;
@end

@implementation EZSeahorseVideoViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = EZVideoLocalized(@"EZSeahorseVideo.Title");
    self.view.backgroundColor = [EZTheme chatBackgroundColor];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self action:@selector(closeTapped)];
    self.rates = @{ @"480p": @95, @"720p": @140, @"1080p": @270 };
    self.maxDuration = 60;
    self.castPhotoURLs = [@[@"", @""] mutableCopy];
    self.castPhotoImages = [@[[NSNull null], [NSNull null]] mutableCopy];
    self.castLibraryIDs = [@[@"", @""] mutableCopy];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [self buildLayout];
    [self loadEligibility];
    [self refreshSavedCharacters];
    [self resumeOpenTask];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshSavedCharacters];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Only stop polling when this screen is really going away. Presenting
    // the photo picker or the character studio calls this too, and killing
    // the timer there would freeze the render status with no restart until
    // the composer is reopened.
    if (self.isBeingDismissed || self.isMovingFromParentViewController) {
        [self.pollTimer invalidate];
        self.pollTimer = nil;
    }
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// ── Keyboard ─────────────────────────────────────────────────────────

- (UIToolbar *)keyboardDoneToolbar {
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissKeyboard)];
    toolbar.items = @[flex, done];
    return toolbar;
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    while (v && v != self.scrollView) {
        if ([v isKindOfClass:UIControl.class] || [v isKindOfClass:UITextView.class]) return NO;
        v = v.superview;
    }
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    self.activeInput = textField;
}

- (void)textViewDidBeginEditing:(UITextView *)textView {
    self.activeInput = textView;
}

- (void)keyboardWillShow:(NSNotification *)note {
    CGRect kbFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat height = [self.view convertRect:kbFrame fromView:nil].size.height;
    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = height;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
    if (self.activeInput) {
        CGRect rect = [self.activeInput convertRect:self.activeInput.bounds toView:self.scrollView];
        [self.scrollView scrollRectToVisible:CGRectInset(rect, 0, -12) animated:YES];
    }
}

- (void)keyboardWillHide:(NSNotification *)note {
    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = 0;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// ── Layout ────────────────────────────────────────────────────────────

- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [EZTheme secondaryTextColor];
    return label;
}

- (void)buildLayout {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];
    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 10;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:16],
        [self.stack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-24],
        [self.stack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [self.stack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    dismissTap.delegate = self;
    [self.scrollView addGestureRecognizer:dismissTap];

    self.gateLabel = [[UILabel alloc] init];
    self.gateLabel.numberOfLines = 0;
    self.gateLabel.font = [UIFont systemFontOfSize:14];
    self.gateLabel.textColor = [EZTheme primaryTextColor];
    self.gateLabel.hidden = YES;
    [self.stack addArrangedSubview:self.gateLabel];

    [self.stack addArrangedSubview:[self sectionLabel:EZVideoLocalized(@"EZSeahorseVideo.Prompt")]];
    self.promptView = [[UITextView alloc] init];
    self.promptView.font = [UIFont systemFontOfSize:15];
    self.promptView.textColor = [EZTheme primaryTextColor];
    self.promptView.backgroundColor = [EZTheme cardColor];
    self.promptView.layer.cornerRadius = 10;
    self.promptView.delegate = self;
    self.promptView.inputAccessoryView = [self keyboardDoneToolbar];
    [self.promptView.heightAnchor constraintEqualToConstant:90].active = YES;
    [self.stack addArrangedSubview:self.promptView];

    [self.stack addArrangedSubview:[self sectionLabel:EZVideoLocalized(@"EZSeahorseVideo.Resolution")]];
    self.resolutionSeg = [[UISegmentedControl alloc] initWithItems:@[@"480p", @"720p", @"1080p"]];
    self.resolutionSeg.selectedSegmentIndex = 0;
    [self.resolutionSeg addTarget:self action:@selector(settingsChanged) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:self.resolutionSeg];

    [self.stack addArrangedSubview:[self sectionLabel:EZVideoLocalized(@"EZSeahorseVideo.Length")]];
    self.durationSeg = [[UISegmentedControl alloc] initWithItems:@[@"5s", @"10s", @"15s", @"30s", @"60s"]];
    self.durationSeg.selectedSegmentIndex = 0;
    [self.durationSeg addTarget:self action:@selector(settingsChanged) forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:self.durationSeg];

    [self.stack addArrangedSubview:[self sectionLabel:EZVideoLocalized(@"EZSeahorseVideo.Mode")]];
    self.modeSeg = [[UISegmentedControl alloc] initWithItems:@[
        EZVideoLocalized(@"EZSeahorseVideo.ModeAuto"), EZVideoLocalized(@"EZSeahorseVideo.ModePlan")]];
    self.modeSeg.selectedSegmentIndex = 0;
    self.modeSeg.enabled = NO;
    [self.stack addArrangedSubview:self.modeSeg];

    [self.stack addArrangedSubview:[self sectionLabel:EZVideoLocalized(@"EZSeahorseVideo.Ratio")]];
    self.ratioSeg = [[UISegmentedControl alloc] initWithItems:@[@"16:9", @"9:16"]];
    self.ratioSeg.selectedSegmentIndex = 1;
    [self.stack addArrangedSubview:self.ratioSeg];

    UIStackView *chainRow = [[UIStackView alloc] init];
    chainRow.axis = UILayoutConstraintAxisHorizontal;
    UILabel *chainLabel = [[UILabel alloc] init];
    chainLabel.text = EZVideoLocalized(@"EZSeahorseVideo.AutoChain");
    chainLabel.font = [UIFont systemFontOfSize:14];
    chainLabel.textColor = [EZTheme primaryTextColor];
    self.autoChainSwitch = [[UISwitch alloc] init];
    [chainRow addArrangedSubview:chainLabel];
    [chainRow addArrangedSubview:self.autoChainSwitch];
    [self.stack addArrangedSubview:chainRow];

    // Characters.
    [self.stack addArrangedSubview:[self sectionLabel:EZVideoLocalized(@"EZSeahorseVideo.Characters")]];
    NSMutableArray *enabled = [NSMutableArray array];
    NSMutableArray *sexs = [NSMutableArray array];
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *looks = [NSMutableArray array];
    NSMutableArray *photos = [NSMutableArray array];
    NSMutableArray *sources = [NSMutableArray array];
    NSMutableArray *libButtons = [NSMutableArray array];
    for (NSInteger i = 0; i < 2; i++) {
        UIStackView *card = [[UIStackView alloc] init];
        card.axis = UILayoutConstraintAxisVertical;
        card.spacing = 6;
        card.backgroundColor = [EZTheme cardColor];
        card.layer.cornerRadius = 10;
        card.layoutMargins = UIEdgeInsetsMake(10, 10, 10, 10);
        card.layoutMarginsRelativeArrangement = YES;

        UIStackView *head = [[UIStackView alloc] init];
        head.axis = UILayoutConstraintAxisHorizontal;
        UILabel *title = [[UILabel alloc] init];
        title.text = [NSString stringWithFormat:EZVideoLocalized(@"EZSeahorseVideo.CharacterFormat"), (long)i + 1];
        title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        title.textColor = [EZTheme primaryTextColor];
        UISwitch *on = [[UISwitch alloc] init];
        on.on = (i == 0);
        [on addTarget:self action:@selector(settingsChanged) forControlEvents:UIControlEventValueChanged];
        [head addArrangedSubview:title];
        [head addArrangedSubview:on];
        [card addArrangedSubview:head];

        UISegmentedControl *sex = [[UISegmentedControl alloc] initWithItems:@[
            EZVideoLocalized(@"EZSeahorseVideo.Female"), EZVideoLocalized(@"EZSeahorseVideo.Male")]];
        sex.selectedSegmentIndex = 0;
        [card addArrangedSubview:sex];

        UISegmentedControl *source = [[UISegmentedControl alloc] initWithItems:@[
            EZVideoLocalized(@"EZSeahorseVideo.SourcePhoto"),
            EZVideoLocalized(@"EZSeahorseVideo.SourceText"),
            EZVideoLocalized(@"EZSeahorseVideo.SourceSaved")]];
        source.selectedSegmentIndex = 1; // Text: describe them, no upload step
        [source addTarget:self action:@selector(settingsChanged) forControlEvents:UIControlEventValueChanged];
        [card addArrangedSubview:source];

        UITextField *name = [[UITextField alloc] init];
        name.placeholder = EZVideoLocalized(@"EZSeahorseVideo.NamePlaceholder");
        name.font = [UIFont systemFontOfSize:14];
        name.textColor = [EZTheme primaryTextColor];
        name.delegate = self;
        name.returnKeyType = UIReturnKeyDone;
        name.inputAccessoryView = [self keyboardDoneToolbar];
        [card addArrangedSubview:name];

        UITextField *look = [[UITextField alloc] init];
        look.placeholder = EZVideoLocalized(@"EZSeahorseVideo.LooksPlaceholder");
        look.font = [UIFont systemFontOfSize:14];
        look.textColor = [EZTheme primaryTextColor];
        look.delegate = self;
        look.returnKeyType = UIReturnKeyDone;
        look.inputAccessoryView = [self keyboardDoneToolbar];
        [card addArrangedSubview:look];

        UIButton *photo = [UIButton buttonWithType:UIButtonTypeSystem];
        [photo setTitle:EZVideoLocalized(@"EZSeahorseVideo.AddPhoto") forState:UIControlStateNormal];
        photo.tag = i;
        [photo addTarget:self action:@selector(castPhotoTapped:) forControlEvents:UIControlEventTouchUpInside];
        [card addArrangedSubview:photo];

        UIButton *lib = [UIButton buttonWithType:UIButtonTypeSystem];
        [lib setTitle:EZVideoLocalized(@"EZSeahorseVideo.ChooseSaved") forState:UIControlStateNormal];
        lib.tag = i;
        [lib addTarget:self action:@selector(castLibraryTapped:) forControlEvents:UIControlEventTouchUpInside];
        [card addArrangedSubview:lib];

        [self.stack addArrangedSubview:card];
        [enabled addObject:on];
        [sexs addObject:sex];
        [names addObject:name];
        [looks addObject:look];
        [photos addObject:photo];
        [sources addObject:source];
        [libButtons addObject:lib];
    }
    self.castEnabled = enabled;
    self.castSex = sexs;
    self.castName = names;
    self.castLooks = looks;
    self.castPhotoButton = photos;
    self.castSource = sources;
    self.castLibraryButton = libButtons;

    self.studioButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.studioButton setTitle:EZVideoLocalized(@"EZSeahorseVideo.CharacterStudio") forState:UIControlStateNormal];
    [self.studioButton addTarget:self action:@selector(studioTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:self.studioButton];

    // Frame pins.
    [self.stack addArrangedSubview:[self sectionLabel:EZVideoLocalized(@"EZSeahorseVideo.Frames")]];
    self.firstFrameButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.firstFrameButton setTitle:EZVideoLocalized(@"EZSeahorseVideo.FirstFrame") forState:UIControlStateNormal];
    [self.firstFrameButton addTarget:self action:@selector(firstFrameTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:self.firstFrameButton];
    self.lastFrameButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.lastFrameButton setTitle:EZVideoLocalized(@"EZSeahorseVideo.LastFrame") forState:UIControlStateNormal];
    [self.lastFrameButton addTarget:self action:@selector(lastFrameTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:self.lastFrameButton];

    self.quoteLabel = [[UILabel alloc] init];
    self.quoteLabel.numberOfLines = 0;
    self.quoteLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.quoteLabel.textColor = [EZTheme primaryTextColor];
    [self.stack addArrangedSubview:self.quoteLabel];

    self.createButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.createButton setTitle:EZVideoLocalized(@"EZSeahorseVideo.Create") forState:UIControlStateNormal];
    self.createButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [self.createButton addTarget:self action:@selector(createTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:self.createButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [self.stack addArrangedSubview:self.spinner];
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.textColor = [EZTheme secondaryTextColor];
    [self.stack addArrangedSubview:self.statusLabel];

    // Storyboard editor (hidden until a draft parks).
    self.storyboardStack = [[UIStackView alloc] init];
    self.storyboardStack.axis = UILayoutConstraintAxisVertical;
    self.storyboardStack.spacing = 10;
    self.storyboardStack.hidden = YES;
    [self.stack addArrangedSubview:self.storyboardStack];

    [self settingsChanged];
}

// ── Derived settings ──────────────────────────────────────────────────

- (NSString *)resolution {
    return @[@"480p", @"720p", @"1080p"][(NSUInteger)MAX(0, self.resolutionSeg.selectedSegmentIndex)];
}

- (NSInteger)durationSeconds {
    return [@[@5, @10, @15, @30, @60][(NSUInteger)MAX(0, self.durationSeg.selectedSegmentIndex)] integerValue];
}

- (NSInteger)coinQuote {
    NSNumber *rate = self.rates[self.resolution] ?: @95;
    return rate.integerValue * self.durationSeconds;
}

- (BOOL)anyCastPhoto {
    for (NSString *url in self.castPhotoURLs) if (url.length) return YES;
    return NO;
}

- (void)settingsChanged {
    BOOL storyboardLength = self.durationSeconds > 15;
    self.modeSeg.enabled = storyboardLength;
    if (!storyboardLength) self.modeSeg.selectedSegmentIndex = 0;
    // Per-slot source: Photo shows the photo button, Saved shows the
    // library picker, Text neither; a saved character carries its own
    // name and look, so the text fields lock for that source.
    for (NSInteger i = 0; i < 2; i++) {
        NSInteger source = self.castSource[(NSUInteger)i].selectedSegmentIndex;
        self.castPhotoButton[(NSUInteger)i].hidden = (source != 0);
        self.castLibraryButton[(NSUInteger)i].hidden = (source != 2);
        self.castName[(NSUInteger)i].enabled = (source != 2);
        self.castLooks[(NSUInteger)i].enabled = (source != 2);
    }
    // Cast and frame pins exclude each other (server rule: framed
    // shots render from the frame alone).
    BOOL framesUsed = self.firstFrameURL.length || self.lastFrameURL.length;
    BOOL castUsed = self.castEnabled[0].on || self.castEnabled[1].on;
    for (UISwitch *s in self.castEnabled) s.enabled = !framesUsed;
    self.firstFrameButton.enabled = !castUsed;
    self.lastFrameButton.enabled = !castUsed;
    self.quoteLabel.text = [NSString stringWithFormat:
        EZVideoLocalized(@"EZSeahorseVideo.QuoteFormat"),
        (long)self.coinQuote, (long)self.balance];
    self.createButton.enabled = !self.busy && self.idVerified && self.purchaseOK;
}

// ── Networking ────────────────────────────────────────────────────────

- (void)postSeahorse:(NSDictionary *)body
          completion:(void (^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {
    NSString *token = [EZAuthManager shared].accessToken;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-seahorse"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 240;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token ?: @""] forHTTPHeaderField:@"Authorization"];
    NSError *bodyErr = nil;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyErr];
    if (bodyErr) { completion(nil, bodyErr); return; }
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        id parsed = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data]
                                                      options:0 error:nil];
        NSDictionary *json = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json, nil); });
    }] resume];
}

- (void)loadEligibility {
    NSMutableDictionary *body = [@{ @"action": @"eligibility" } mutableCopy];
    NSString *storefront = [EZStoreKitManager storefrontCountryCode];
    if (storefront.length) body[@"storefront"] = storefront;
    [self postSeahorse:body completion:^(NSDictionary *json, NSError *error) {
        if (!json) {
            self.gateLabel.text = EZVideoLocalized(@"EZSeahorseVideo.LoadFailed");
            self.gateLabel.hidden = NO;
            return;
        }
        self.idVerified = EZVideoBool(json[@"id_verified"]);
        self.purchaseOK = EZVideoBool(json[@"recent_purchase"]);
        self.balance = EZVideoInteger(json[@"balance"]);
        NSDictionary *video = EZVideoDict(json[@"video"]);
        NSDictionary *rates = EZVideoDict(video[@"rates_coins_per_second"]);
        if (rates.count) {
            // Only adopt rates whose values are real numbers; a null rate
            // would crash coinQuote's integerValue.
            NSMutableDictionary *clean = [NSMutableDictionary dictionary];
            for (NSString *key in rates) {
                if ([rates[key] isKindOfClass:NSNumber.class]) clean[key] = rates[key];
            }
            if (clean.count) self.rates = clean;
        }
        if (EZVideoInteger(video[@"max_duration_seconds"]) > 0)
            self.maxDuration = EZVideoInteger(video[@"max_duration_seconds"]);
        if (!self.idVerified) {
            self.gateLabel.text = EZVideoLocalized(@"EZSeahorseVideo.IDCheckFirst");
            self.gateLabel.hidden = NO;
        } else if (!self.purchaseOK) {
            self.gateLabel.text = EZVideoLocalized(@"EZSeahorseVideo.PurchaseFirst");
            self.gateLabel.hidden = NO;
        }
        [self settingsChanged];
    }];
}

- (void)applyBalance:(NSDictionary *)json {
    id bal = json[@"balance"];
    if (bal && ![bal isKindOfClass:NSNull.class]) {
        self.balance = EZVideoInteger(bal);
        [[EZEntitlementManager shared] applyKnownBalance:self.balance];
    }
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.OK")
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ── Photo picking, likeness check, upload ─────────────────────────────

- (void)castPhotoTapped:(UIButton *)sender {
    [self pickImageForPurpose:(EZVideoPickerPurpose)sender.tag];
}

- (void)firstFrameTapped { [self pickImageForPurpose:EZVideoPickerPurposeFirstFrame]; }
- (void)lastFrameTapped  { [self pickImageForPurpose:EZVideoPickerPurposeLastFrame]; }

- (void)pickImageForPurpose:(EZVideoPickerPurpose)purpose {
    self.pickerPurpose = purpose;
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) return;
    UIImagePickerController *ipc = [[UIImagePickerController alloc] init];
    ipc.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    ipc.delegate = self;
    ipc.allowsEditing = NO;
    [self presentViewController:ipc animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    UIImage *image = info[UIImagePickerControllerEditedImage] ?: info[UIImagePickerControllerOriginalImage];
    EZVideoPickerPurpose purpose = self.pickerPurpose;
    [picker dismissViewControllerAnimated:YES completion:^{
        if (image) [self verifyAndUploadImage:image purpose:purpose];
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

// The same consent checkpoint as image references: face-crop the pick,
// ask the server for a likeness verdict (an app-generated image passes
// by hash), block only on a clear "different", then upload the full
// image through the presigned flow and keep its asset URL.
- (void)verifyAndUploadImage:(UIImage *)image purpose:(EZVideoPickerPurpose)purpose {
    [self setBusy:YES status:EZVideoLocalized(@"EZSeahorseVideo.CheckingPhoto")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *jpeg = UIImageJPEGRepresentation(image, 0.9);
        NSData *crop = EZVideoFaceCropJPEGData(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!jpeg) { [self setBusy:NO status:nil]; return; }
            NSDictionary *body = @{
                @"action": @"verify_reference",
                @"reference_image_base64": [(crop ?: jpeg) base64EncodedStringWithOptions:0],
                @"reference_sha256": EZVideoSHA256Hex(jpeg),
            };
            [self postSeahorse:body completion:^(NSDictionary *json, NSError *error) {
                NSString *verdict = [json[@"verdict"] isKindOfClass:NSString.class] ? json[@"verdict"] : nil;
                if ([verdict isEqualToString:@"different"]) {
                    [self setBusy:NO status:nil];
                    [self showError:EZVideoLocalized(@"EZSeahorseVideo.PhotoRefused")];
                    return;
                }
                [self uploadJPEG:jpeg completion:^(NSString *assetURL) {
                    [self setBusy:NO status:nil];
                    if (!assetURL) {
                        [self showError:EZVideoLocalized(@"EZSeahorseVideo.UploadFailed")];
                        return;
                    }
                    [self storePickedImage:image assetURL:assetURL purpose:purpose];
                }];
            }];
        });
    });
}

- (void)uploadJPEG:(NSData *)jpeg completion:(void (^)(NSString * _Nullable assetURL))completion {
    NSDictionary *body = @{
        @"action": @"upload_reference",
        @"content_type": @"image/jpeg",
        @"file_name": [NSString stringWithFormat:@"video-ref-%@.jpg", [NSUUID UUID].UUIDString],
    };
    [self postSeahorse:body completion:^(NSDictionary *json, NSError *error) {
        NSString *uploadURL = [json[@"upload_url"] isKindOfClass:NSString.class] ? json[@"upload_url"] : nil;
        NSString *assetURL  = [json[@"asset_url"] isKindOfClass:NSString.class] ? json[@"asset_url"] : nil;
        if (!uploadURL.length || !assetURL.length) { completion(nil); return; }
        NSMutableURLRequest *put = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:uploadURL]];
        put.HTTPMethod = @"PUT";
        [put setValue:@"image/jpeg" forHTTPHeaderField:@"Content-Type"];
        [[[NSURLSession sharedSession] uploadTaskWithRequest:put fromData:jpeg
            completionHandler:^(NSData *d, NSURLResponse *response, NSError *uploadError) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            BOOL ok = !uploadError && http.statusCode >= 200 && http.statusCode < 300;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok ? assetURL : nil); });
        }] resume];
    }];
}

- (void)storePickedImage:(UIImage *)image assetURL:(NSString *)assetURL purpose:(EZVideoPickerPurpose)purpose {
    switch (purpose) {
        case EZVideoPickerPurposeCast1:
        case EZVideoPickerPurposeCast2: {
            NSInteger i = (purpose == EZVideoPickerPurposeCast1) ? 0 : 1;
            self.castPhotoURLs[(NSUInteger)i] = assetURL;
            self.castPhotoImages[(NSUInteger)i] = image;
            [self.castPhotoButton[(NSUInteger)i] setTitle:EZVideoLocalized(@"EZSeahorseVideo.PhotoAdded")
                                                 forState:UIControlStateNormal];
            break;
        }
        case EZVideoPickerPurposeFirstFrame:
            self.firstFrameURL = assetURL;
            [self.firstFrameButton setTitle:EZVideoLocalized(@"EZSeahorseVideo.FirstFrameAdded")
                                   forState:UIControlStateNormal];
            break;
        case EZVideoPickerPurposeLastFrame:
            self.lastFrameURL = assetURL;
            [self.lastFrameButton setTitle:EZVideoLocalized(@"EZSeahorseVideo.LastFrameAdded")
                                  forState:UIControlStateNormal];
            break;
    }
    [self settingsChanged];
}

// ── Saved characters (library) ────────────────────────────────────────

- (void)studioTapped {
    EZSeahorseCharacterStudioViewController *studio =
        [[EZSeahorseCharacterStudioViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    studio.onCharactersChanged = ^{ [weakSelf refreshSavedCharacters]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:studio];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)refreshSavedCharacters {
    [self postSeahorse:@{ @"action": @"character_list" }
            completion:^(NSDictionary *json, NSError *error) {
        NSArray *items = [json[@"items"] isKindOfClass:NSArray.class] ? json[@"items"] : @[];
        self.savedCharacters = items;
    }];
}

- (void)castLibraryTapped:(UIButton *)sender {
    NSInteger slot = sender.tag;
    NSArray *items = self.savedCharacters ?: @[];
    if (!items.count) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
            message:EZVideoLocalized(@"EZSeahorseVideo.NoSavedCharacters")
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.OpenStudio")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            [self studioTapped];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.OK")
            style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *name = EZVideoString(item[@"name"]);
        if (!name.length) name = EZVideoString(item[@"item_id"]) ?: @"";
        NSString *itemID = [item[@"item_id"] isKindOfClass:NSString.class] ? item[@"item_id"] : @"";
        [sheet addAction:[UIAlertAction actionWithTitle:name
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            if (!itemID.length) return;
            self.castLibraryIDs[(NSUInteger)slot] = itemID;
            [self.castLibraryButton[(NSUInteger)slot]
                setTitle:[NSString stringWithFormat:EZVideoLocalized(@"EZSeahorseVideo.SavedChosenFormat"), name]
                forState:UIControlStateNormal];
            [self settingsChanged];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.OK")
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// ── Create + polling ──────────────────────────────────────────────────

- (void)setBusy:(BOOL)busy status:(NSString * _Nullable)status {
    self.busy = busy;
    if (busy) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    if (status) self.statusLabel.text = status;
    [self settingsChanged];
}

- (void)createTapped {
    NSString *prompt = [self.promptView.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!prompt.length && self.modeSeg.selectedSegmentIndex == 0) {
        [self showError:EZVideoLocalized(@"EZSeahorseVideo.PromptRequired")];
        return;
    }
    NSMutableDictionary *body = [@{
        @"action": @"video_create",
        @"nsfw": @YES,
        @"prompt": prompt,
        @"resolution": self.resolution,
        @"duration": @(self.durationSeconds),
        @"ratio": self.ratioSeg.selectedSegmentIndex == 1 ? @"9:16" : @"16:9",
    } mutableCopy];
    if (self.modeSeg.selectedSegmentIndex == 1 && self.durationSeconds > 15)
        body[@"mode"] = @"edit";
    if (self.autoChainSwitch.on && self.durationSeconds > 15)
        body[@"auto_chain"] = @YES;
    NSMutableArray *cast = [NSMutableArray array];
    for (NSInteger i = 0; i < 2; i++) {
        if (!self.castEnabled[(NSUInteger)i].on) continue;
        NSMutableDictionary *member = [@{
            @"sex": self.castSex[(NSUInteger)i].selectedSegmentIndex == 1 ? @"male" : @"female",
        } mutableCopy];
        NSInteger source = self.castSource[(NSUInteger)i].selectedSegmentIndex;
        if (source == 2) {
            NSString *libID = self.castLibraryIDs[(NSUInteger)i];
            if (!libID.length) {
                [self showError:EZVideoLocalized(@"EZSeahorseVideo.ChooseSavedFirst")];
                return;
            }
            member[@"library_item_id"] = libID;
        } else {
            NSString *name = [self.castName[(NSUInteger)i].text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            if (name.length) member[@"name"] = name;
            NSString *looks = [self.castLooks[(NSUInteger)i].text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            if (looks.length) member[@"looks"] = looks;
            if (source == 0) {
                NSString *photo = self.castPhotoURLs[(NSUInteger)i];
                if (photo.length) member[@"photo_asset_url"] = photo;
            }
        }
        [cast addObject:member];
    }
    if (cast.count) body[@"cast"] = cast;
    if (self.firstFrameURL.length) body[@"first_frame_url"] = self.firstFrameURL;
    if (self.lastFrameURL.length) body[@"last_frame_url"] = self.lastFrameURL;
    NSString *storefront = [EZStoreKitManager storefrontCountryCode];
    if (storefront.length) body[@"storefront"] = storefront;

    [self setBusy:YES status:EZVideoLocalized(@"EZSeahorseVideo.Starting")];
    [self postSeahorse:body completion:^(NSDictionary *json, NSError *error) {
        NSString *err = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : nil;
        if (!json || err.length) {
            [self setBusy:NO status:nil];
            [self handleCreateError:err ?: error.localizedDescription json:json];
            return;
        }
        [self applyBalance:json];
        self.taskID = [json[@"task_id"] isKindOfClass:NSString.class] ? json[@"task_id"] : nil;
        self.taskIsEditMode = [EZVideoString(json[@"mode"]) isEqualToString:@"edit"];
        [self setBusy:NO status:EZVideoLocalized(@"EZSeahorseVideo.Working")];
        [self startPolling];
    }];
}

- (void)handleCreateError:(NSString *)err json:(NSDictionary * _Nullable)json {
    if ([err isEqualToString:@"id_verification_required"]) {
        [self showError:EZVideoLocalized(@"EZSeahorseVideo.IDCheckFirst")];
    } else if ([err isEqualToString:@"recent_purchase_required"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
            message:EZVideoLocalized(@"EZSeahorseVideo.PurchaseFirst")
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.ViewPlans")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            [self.navigationController pushViewController:[[EZCoinStoreViewController alloc] init] animated:YES];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.OK")
            style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if ([err isEqualToString:@"Insufficient coins"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
            message:[NSString stringWithFormat:EZVideoLocalized(@"EZSeahorseVideo.InsufficientFormat"),
                     (long)self.coinQuote, (long)self.balance]
            preferredStyle:UIAlertControllerStyleAlert];
        NSString *webStoreURL = [json[@"web_store_url"] isKindOfClass:NSString.class] ? json[@"web_store_url"] : nil;
        if (webStoreURL.length) {
            [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.BuyOnWebsite")
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:webStoreURL]
                                                   options:@{} completionHandler:nil];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.ViewPlans")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            [self.navigationController pushViewController:[[EZCoinStoreViewController alloc] init] animated:YES];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.OK")
            style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self showError:err ?: EZVideoLocalized(@"EZSeahorseVideo.LoadFailed")];
    }
}

- (void)startPolling {
    [self.pollTimer invalidate];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:4.0
        target:self selector:@selector(pollTick) userInfo:nil repeats:YES];
    [self pollTick];
}

- (void)pollTick {
    if (!self.taskID.length) { [self.pollTimer invalidate]; self.pollTimer = nil; return; }
    [self postSeahorse:@{ @"action": @"video_status", @"task_id": self.taskID }
            completion:^(NSDictionary *json, NSError *error) {
        if (!json) return; // transient; the next tick retries
        [self applyBalance:json];
        NSString *status = [json[@"status"] isKindOfClass:NSString.class] ? json[@"status"] : @"";
        if ([status isEqualToString:@"succeeded"]) {
            [self.pollTimer invalidate]; self.pollTimer = nil;
            NSString *url = [json[@"video_url"] isKindOfClass:NSString.class] ? json[@"video_url"] : nil;
            [self downloadAndSaveVideo:url];
        } else if ([status isEqualToString:@"failed"] || [status isEqualToString:@"cancelled"]) {
            [self.pollTimer invalidate]; self.pollTimer = nil;
            self.storyboardStack.hidden = YES;
            self.statusLabel.text = EZVideoLocalized(@"EZSeahorseVideo.FailedRefunded");
        } else if ([status isEqualToString:@"planned"]) {
            [self.pollTimer invalidate]; self.pollTimer = nil;
            NSDictionary *scene = [json[@"scene"] isKindOfClass:NSDictionary.class] ? json[@"scene"] : nil;
            if (scene) [self showStoryboard:scene];
            else [self startPolling]; // draft still being written
        } else {
            self.statusLabel.text = [self statusTextForStep:json[@"step"]];
        }
    }];
}

- (NSString *)statusTextForStep:(id)step {
    NSString *code = [step isKindOfClass:NSDictionary.class] ? step[@"code"] : nil;
    if ([code isEqualToString:@"generating_script"]) return EZVideoLocalized(@"EZSeahorseVideo.StepScript");
    if ([code isEqualToString:@"generating_visuals"]) return EZVideoLocalized(@"EZSeahorseVideo.StepVisuals");
    if ([code isEqualToString:@"rendering"]) {
        id done = step[@"done"], total = step[@"total"];
        if ([done respondsToSelector:@selector(integerValue)] && [total respondsToSelector:@selector(integerValue)])
            return [NSString stringWithFormat:EZVideoLocalized(@"EZSeahorseVideo.StepRenderingFormat"),
                    (long)[done integerValue], (long)[total integerValue]];
        return EZVideoLocalized(@"EZSeahorseVideo.StepRendering");
    }
    if ([code isEqualToString:@"stitching"]) return EZVideoLocalized(@"EZSeahorseVideo.StepStitching");
    if ([code isEqualToString:@"reexpanding"]) return EZVideoLocalized(@"EZSeahorseVideo.StepReexpanding");
    return EZVideoLocalized(@"EZSeahorseVideo.Working");
}

- (void)downloadAndSaveVideo:(NSString *)urlString {
    self.statusLabel.text = EZVideoLocalized(@"EZSeahorseVideo.Saving");
    NSURL *url = urlString.length ? [NSURL URLWithString:urlString] : nil;
    if (!url) { self.statusLabel.text = EZVideoLocalized(@"EZSeahorseVideo.FailedRefunded"); return; }
    NSString *prompt = [self.promptView.text copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:url];
        NSString *name = [NSString stringWithFormat:@"seahorse_video_%@.mp4",
            @((long)[[NSDate date] timeIntervalSince1970])];
        NSString *path = data ? EZPhotoGallerySave(data, name) : nil;
        if (path.length) {
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            NSMutableDictionary *promptMap = [[d dictionaryForKey:@"EZGalleryImagePrompts"] mutableCopy]
                ?: [NSMutableDictionary dictionary];
            promptMap[path] = prompt ?: @"";
            [d setObject:promptMap forKey:@"EZGalleryImagePrompts"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.text = path.length
                ? EZVideoLocalized(@"EZSeahorseVideo.SavedToGallery")
                : EZVideoLocalized(@"EZSeahorseVideo.SaveFailed");
            self.taskID = nil;
        });
    });
}

// Resume an open task (a draft waiting for edits, or a render still
// running) when the composer opens — leaving mid-flight never strands
// a paid video.
- (void)resumeOpenTask {
    [self postSeahorse:@{ @"action": @"video_list" } completion:^(NSDictionary *json, NSError *error) {
        NSArray *tasks = [json[@"tasks"] isKindOfClass:NSArray.class] ? json[@"tasks"] : nil;
        for (NSDictionary *task in tasks) {
            if (![task isKindOfClass:NSDictionary.class]) continue;
            NSString *status = EZVideoString(task[@"status"]);
            if (![status isEqualToString:@"planned"] && ![status isEqualToString:@"rendering"]) continue;
            self.taskID = EZVideoString(task[@"task_id"]);
            self.taskIsEditMode = [EZVideoString(task[@"mode"]) isEqualToString:@"edit"];
            if (!self.taskID.length) continue;
            self.statusLabel.text = EZVideoLocalized(@"EZSeahorseVideo.Working");
            [self startPolling];
            return;
        }
    }];
}

// ── Storyboard editor (edit mode) ─────────────────────────────────────

- (void)showStoryboard:(NSDictionary *)scene {
    self.scene = scene;
    self.lockedSeconds = EZVideoInteger(scene[@"lockedDurationSeconds"]);
    if (self.lockedSeconds <= 0) self.lockedSeconds = self.durationSeconds;
    for (UIView *v in [self.storyboardStack.arrangedSubviews copy]) {
        [self.storyboardStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    UILabel *title = [[UILabel alloc] init];
    title.text = EZVideoLocalized(@"EZSeahorseVideo.Storyboard");
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = [EZTheme primaryTextColor];
    [self.storyboardStack addArrangedSubview:title];

    NSArray *segments = [scene[@"segments"] isKindOfClass:NSArray.class] ? scene[@"segments"] : @[];
    NSMutableArray *cards = [NSMutableArray array];
    for (NSDictionary *seg in segments) {
        if (![seg isKindOfClass:NSDictionary.class]) continue;
        UIStackView *card = [[UIStackView alloc] init];
        card.axis = UILayoutConstraintAxisVertical;
        card.spacing = 6;
        card.backgroundColor = [EZTheme cardColor];
        card.layer.cornerRadius = 10;
        card.layoutMargins = UIEdgeInsetsMake(10, 10, 10, 10);
        card.layoutMarginsRelativeArrangement = YES;

        UILabel *head = [[UILabel alloc] init];
        head.text = [NSString stringWithFormat:EZVideoLocalized(@"EZSeahorseVideo.ShotFormat"),
                     (long)EZVideoInteger(seg[@"index"])];
        head.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        head.textColor = [EZTheme secondaryTextColor];
        [card addArrangedSubview:head];

        UITextView *beat = [[UITextView alloc] init];
        beat.font = [UIFont systemFontOfSize:14];
        beat.textColor = [EZTheme primaryTextColor];
        beat.backgroundColor = [UIColor clearColor];
        NSString *beatText = [seg[@"beat"] isKindOfClass:NSString.class] ? seg[@"beat"]
            : ([seg[@"script"] isKindOfClass:NSString.class] ? seg[@"script"] : @"");
        beat.text = beatText;
        beat.delegate = self;
        beat.inputAccessoryView = [self keyboardDoneToolbar];
        [beat.heightAnchor constraintEqualToConstant:54].active = YES;
        [card addArrangedSubview:beat];

        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 8;
        UIStepper *stepper = [[UIStepper alloc] init];
        stepper.minimumValue = 4;
        stepper.maximumValue = 15;
        stepper.stepValue = 1;
        stepper.value = EZVideoDouble(seg[@"durationSeconds"]) ?: 9;
        [stepper addTarget:self action:@selector(shotDurationChanged) forControlEvents:UIControlEventValueChanged];
        UILabel *seconds = [[UILabel alloc] init];
        seconds.font = [UIFont systemFontOfSize:14];
        seconds.textColor = [EZTheme primaryTextColor];
        seconds.text = [NSString stringWithFormat:EZVideoLocalized(@"EZSeahorseVideo.SecondsFormat"),
                        (long)stepper.value];
        UILabel *explicitLabel = [[UILabel alloc] init];
        explicitLabel.text = EZVideoLocalized(@"EZSeahorseVideo.Explicit");
        explicitLabel.font = [UIFont systemFontOfSize:14];
        explicitLabel.textColor = [EZTheme primaryTextColor];
        UISwitch *explicitSwitch = [[UISwitch alloc] init];
        explicitSwitch.on = EZVideoBool(seg[@"explicit"]);
        [row addArrangedSubview:stepper];
        [row addArrangedSubview:seconds];
        [row addArrangedSubview:explicitLabel];
        [row addArrangedSubview:explicitSwitch];
        [card addArrangedSubview:row];

        [self.storyboardStack addArrangedSubview:card];
        [cards addObject:@{
            @"index": @(EZVideoInteger(seg[@"index"])),
            @"beat": beat,
            @"stepper": stepper,
            @"seconds": seconds,
            @"explicit": explicitSwitch,
        }];
    }
    self.shotCards = cards;

    self.storyboardTotalLabel = [[UILabel alloc] init];
    self.storyboardTotalLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.storyboardTotalLabel.textColor = [EZTheme primaryTextColor];
    [self.storyboardStack addArrangedSubview:self.storyboardTotalLabel];

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:EZVideoLocalized(@"EZSeahorseVideo.SaveStoryboard") forState:UIControlStateNormal];
    [save addTarget:self action:@selector(saveStoryboardTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.storyboardStack addArrangedSubview:save];

    UIButton *render = [UIButton buttonWithType:UIButtonTypeSystem];
    [render setTitle:EZVideoLocalized(@"EZSeahorseVideo.Render") forState:UIControlStateNormal];
    render.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [render addTarget:self action:@selector(renderTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.storyboardStack addArrangedSubview:render];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:EZVideoLocalized(@"EZSeahorseVideo.CancelDraft") forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancelDraftTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.storyboardStack addArrangedSubview:cancel];

    self.storyboardStack.hidden = NO;
    self.statusLabel.text = EZVideoLocalized(@"EZSeahorseVideo.DraftReady");
    [self updateStoryboardTotal];
}

- (NSInteger)storyboardSum {
    NSInteger sum = 0;
    for (NSDictionary *card in self.shotCards) {
        UIStepper *stepper = card[@"stepper"];
        sum += (NSInteger)stepper.value;
    }
    return sum;
}

- (void)shotDurationChanged {
    for (NSDictionary *card in self.shotCards) {
        UIStepper *stepper = card[@"stepper"];
        UILabel *seconds = card[@"seconds"];
        seconds.text = [NSString stringWithFormat:EZVideoLocalized(@"EZSeahorseVideo.SecondsFormat"),
                        (long)stepper.value];
    }
    [self updateStoryboardTotal];
}

- (void)updateStoryboardTotal {
    NSInteger sum = [self storyboardSum];
    self.storyboardTotalLabel.text = [NSString stringWithFormat:
        EZVideoLocalized(@"EZSeahorseVideo.TotalFormat"), (long)sum, (long)self.lockedSeconds];
    self.storyboardTotalLabel.textColor = (sum == self.lockedSeconds)
        ? [EZTheme primaryTextColor] : [UIColor systemRedColor];
}

- (NSArray<NSDictionary *> *)storyboardPayload {
    NSMutableArray *segs = [NSMutableArray array];
    for (NSDictionary *card in self.shotCards) {
        UITextView *beat = card[@"beat"];
        UIStepper *stepper = card[@"stepper"];
        UISwitch *explicitSwitch = card[@"explicit"];
        [segs addObject:@{
            @"index": card[@"index"],
            @"beat": [beat.text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"",
            @"duration_seconds": @((NSInteger)stepper.value),
            @"explicit": @(explicitSwitch.on),
        }];
    }
    return segs;
}

- (void)saveStoryboardTapped {
    if ([self storyboardSum] != self.lockedSeconds) {
        [self showError:[NSString stringWithFormat:EZVideoLocalized(@"EZSeahorseVideo.TotalMismatchFormat"),
                         (long)self.lockedSeconds]];
        return;
    }
    [self setBusy:YES status:EZVideoLocalized(@"EZSeahorseVideo.StepReexpanding")];
    [self postSeahorse:@{ @"action": @"video_plan", @"task_id": self.taskID ?: @"",
                          @"segments": [self storyboardPayload] }
            completion:^(NSDictionary *json, NSError *error) {
        [self setBusy:NO status:nil];
        NSString *err = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : nil;
        if (err.length) { [self showError:err]; return; }
        NSDictionary *scene = [json[@"scene"] isKindOfClass:NSDictionary.class] ? json[@"scene"] : nil;
        if (scene) [self showStoryboard:scene];
        self.statusLabel.text = EZVideoLocalized(@"EZSeahorseVideo.DraftReady");
    }];
}

- (void)renderTapped {
    if ([self storyboardSum] != self.lockedSeconds) {
        [self showError:[NSString stringWithFormat:EZVideoLocalized(@"EZSeahorseVideo.TotalMismatchFormat"),
                         (long)self.lockedSeconds]];
        return;
    }
    [self setBusy:YES status:EZVideoLocalized(@"EZSeahorseVideo.Working")];
    [self postSeahorse:@{ @"action": @"video_render", @"task_id": self.taskID ?: @"" }
            completion:^(NSDictionary *json, NSError *error) {
        [self setBusy:NO status:nil];
        NSString *err = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : nil;
        if (err.length) { [self showError:err]; return; }
        self.storyboardStack.hidden = YES;
        self.statusLabel.text = EZVideoLocalized(@"EZSeahorseVideo.Working");
        [self startPolling];
    }];
}

- (void)cancelDraftTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:EZVideoLocalized(@"EZSeahorseVideo.CancelDraftConfirm")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.KeepDraft")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.CancelDraft")
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [self postSeahorse:@{ @"action": @"video_cancel", @"task_id": self.taskID ?: @"" }
                completion:^(NSDictionary *json, NSError *error) {
            [self applyBalance:json];
            self.storyboardStack.hidden = YES;
            self.taskID = nil;
            self.statusLabel.text = EZVideoLocalized(@"EZSeahorseVideo.FailedRefunded");
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

// ── Character studio ──────────────────────────────────────────────────
// Describe a person and the library draws two candidates (flat coin
// price, the same as an image); save the one you like and they can be
// cast in any video from the composer's Saved source. Saved
// characters are the account's own — the server registers them per
// user, so nobody else's characters ever appear here.

@interface EZSeahorseCharacterStudioViewController () <UITextFieldDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, weak) UIView *activeInput;
@property (nonatomic, strong) UISegmentedControl *sexSeg;
@property (nonatomic, strong) UISegmentedControl *ageSeg;
@property (nonatomic, strong) UISegmentedControl *styleSeg;
@property (nonatomic, strong) UITextField *hairField;
@property (nonatomic, strong) UITextField *appearanceField;
@property (nonatomic, strong) UITextField *outfitField;
@property (nonatomic, strong) UITextField *extraField;
@property (nonatomic, strong) UIButton *generateButton;
@property (nonatomic, strong) UIStackView *candidateStack;
@property (nonatomic, strong) NSArray<NSDictionary *> *candidates;
@property (nonatomic) NSInteger selectedCandidate;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) UIStackView *savedStack;
@property (nonatomic, strong) NSArray<NSDictionary *> *savedItems;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic) NSInteger characterCost;
@property (nonatomic) BOOL busy;
@end

@implementation EZSeahorseCharacterStudioViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = EZVideoLocalized(@"EZSeahorseVideo.StudioTitle");
    self.view.backgroundColor = [EZTheme chatBackgroundColor];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self action:@selector(closeTapped)];
    self.characterCost = 50;
    self.selectedCandidate = -1;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [self buildLayout];
    [self loadCharacters];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// ── Keyboard ─────────────────────────────────────────────────────────

- (UIToolbar *)keyboardDoneToolbar {
    UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissKeyboard)];
    toolbar.items = @[flex, done];
    return toolbar;
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *v = touch.view;
    while (v && v != self.scrollView) {
        if ([v isKindOfClass:UIControl.class] || [v isKindOfClass:UITextView.class]) return NO;
        v = v.superview;
    }
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    self.activeInput = textField;
}

- (void)keyboardWillShow:(NSNotification *)note {
    CGRect kbFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat height = [self.view convertRect:kbFrame fromView:nil].size.height;
    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = height;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
    if (self.activeInput) {
        CGRect rect = [self.activeInput convertRect:self.activeInput.bounds toView:self.scrollView];
        [self.scrollView scrollRectToVisible:CGRectInset(rect, 0, -12) animated:YES];
    }
}

- (void)keyboardWillHide:(NSNotification *)note {
    UIEdgeInsets insets = self.scrollView.contentInset;
    insets.bottom = 0;
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [EZTheme secondaryTextColor];
    return label;
}

- (UITextField *)fieldWithPlaceholder:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] init];
    field.placeholder = placeholder;
    field.font = [UIFont systemFontOfSize:14];
    field.textColor = [EZTheme primaryTextColor];
    field.delegate = self;
    field.returnKeyType = UIReturnKeyDone;
    field.inputAccessoryView = [self keyboardDoneToolbar];
    return field;
}

- (void)buildLayout {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];
    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 10;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:16],
        [self.stack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-24],
        [self.stack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [self.stack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    dismissTap.delegate = self;
    [self.scrollView addGestureRecognizer:dismissTap];

    [self.stack addArrangedSubview:[self sectionLabel:EZVideoLocalized(@"EZSeahorseVideo.StudioDescribe")]];
    self.sexSeg = [[UISegmentedControl alloc] initWithItems:@[
        EZVideoLocalized(@"EZSeahorseVideo.Female"), EZVideoLocalized(@"EZSeahorseVideo.Male")]];
    self.sexSeg.selectedSegmentIndex = 0;
    [self.stack addArrangedSubview:self.sexSeg];
    self.ageSeg = [[UISegmentedControl alloc] initWithItems:@[@"20s", @"30s", @"40s", @"50+"]];
    self.ageSeg.selectedSegmentIndex = 1;
    [self.stack addArrangedSubview:self.ageSeg];
    self.styleSeg = [[UISegmentedControl alloc] initWithItems:@[@"realistic", @"anime", @"3d", @"illustration"]];
    self.styleSeg.selectedSegmentIndex = 0;
    [self.stack addArrangedSubview:self.styleSeg];
    self.hairField = [self fieldWithPlaceholder:EZVideoLocalized(@"EZSeahorseVideo.HairPlaceholder")];
    [self.stack addArrangedSubview:self.hairField];
    self.appearanceField = [self fieldWithPlaceholder:EZVideoLocalized(@"EZSeahorseVideo.AppearancePlaceholder")];
    [self.stack addArrangedSubview:self.appearanceField];
    self.outfitField = [self fieldWithPlaceholder:EZVideoLocalized(@"EZSeahorseVideo.OutfitPlaceholder")];
    [self.stack addArrangedSubview:self.outfitField];
    self.extraField = [self fieldWithPlaceholder:EZVideoLocalized(@"EZSeahorseVideo.ExtraPlaceholder")];
    [self.stack addArrangedSubview:self.extraField];

    self.generateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.generateButton setTitle:EZVideoLocalized(@"EZSeahorseVideo.GenerateCharacter")
                         forState:UIControlStateNormal];
    self.generateButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [self.generateButton addTarget:self action:@selector(generateTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:self.generateButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [self.stack addArrangedSubview:self.spinner];
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.textColor = [EZTheme secondaryTextColor];
    [self.stack addArrangedSubview:self.statusLabel];

    [self.stack addArrangedSubview:[self sectionLabel:EZVideoLocalized(@"EZSeahorseVideo.CandidatesTitle")]];
    self.candidateStack = [[UIStackView alloc] init];
    self.candidateStack.axis = UILayoutConstraintAxisHorizontal;
    self.candidateStack.spacing = 10;
    self.candidateStack.distribution = UIStackViewDistributionFillEqually;
    [self.stack addArrangedSubview:self.candidateStack];

    self.nameField = [self fieldWithPlaceholder:EZVideoLocalized(@"EZSeahorseVideo.CharacterNamePlaceholder")];
    [self.stack addArrangedSubview:self.nameField];
    self.saveButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.saveButton setTitle:EZVideoLocalized(@"EZSeahorseVideo.SaveCharacter") forState:UIControlStateNormal];
    self.saveButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.saveButton.enabled = NO;
    [self.saveButton addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:self.saveButton];

    [self.stack addArrangedSubview:[self sectionLabel:EZVideoLocalized(@"EZSeahorseVideo.SavedCharacters")]];
    self.savedStack = [[UIStackView alloc] init];
    self.savedStack.axis = UILayoutConstraintAxisVertical;
    self.savedStack.spacing = 8;
    [self.stack addArrangedSubview:self.savedStack];
}

- (void)postSeahorse:(NSDictionary *)body
          completion:(void (^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {
    NSString *token = [EZAuthManager shared].accessToken;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-seahorse"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 240;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token ?: @""] forHTTPHeaderField:@"Authorization"];
    NSError *bodyErr = nil;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyErr];
    if (bodyErr) { completion(nil, bodyErr); return; }
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        id parsed = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data]
                                                      options:0 error:nil];
        NSDictionary *json = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(json, nil); });
    }] resume];
}

- (void)setBusy:(BOOL)busy status:(NSString * _Nullable)status {
    self.busy = busy;
    if (busy) [self.spinner startAnimating]; else [self.spinner stopAnimating];
    if (status) self.statusLabel.text = status;
    self.generateButton.enabled = !busy;
    self.saveButton.enabled = !busy && self.selectedCandidate >= 0;
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.OK")
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)loadCharacters {
    [self postSeahorse:@{ @"action": @"character_list" }
            completion:^(NSDictionary *json, NSError *error) {
        if (EZVideoInteger(json[@"character_cost"]) > 0)
            self.characterCost = EZVideoInteger(json[@"character_cost"]);
        NSArray *items = [json[@"items"] isKindOfClass:NSArray.class] ? json[@"items"] : @[];
        self.savedItems = items;
        [self rebuildSavedList];
    }];
}

- (void)rebuildSavedList {
    for (UIView *v in [self.savedStack.arrangedSubviews copy]) {
        [self.savedStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSInteger idx = 0;
    for (NSDictionary *item in self.savedItems) {
        if (![item isKindOfClass:NSDictionary.class]) { idx++; continue; }
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 10;
        row.alignment = UIStackViewAlignmentCenter;
        UIImageView *thumb = [[UIImageView alloc] init];
        thumb.contentMode = UIViewContentModeScaleAspectFill;
        thumb.clipsToBounds = YES;
        thumb.layer.cornerRadius = 8;
        thumb.backgroundColor = [EZTheme cardColor];
        [thumb.widthAnchor constraintEqualToConstant:48].active = YES;
        [thumb.heightAnchor constraintEqualToConstant:48].active = YES;
        NSString *thumbURL = [item[@"thumb_url"] isKindOfClass:NSString.class] ? item[@"thumb_url"] : nil;
        EZVideoLoadImage(thumbURL, ^(UIImage *image) { thumb.image = image; });
        UILabel *name = [[UILabel alloc] init];
        name.text = EZVideoString(item[@"name"]);
        if (!name.text.length) name.text = EZVideoString(item[@"item_id"]) ?: @"";
        name.font = [UIFont systemFontOfSize:14];
        name.textColor = [EZTheme primaryTextColor];
        UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
        [del setTitle:EZVideoLocalized(@"EZSeahorseVideo.DeleteCharacter") forState:UIControlStateNormal];
        del.tag = idx;
        [del addTarget:self action:@selector(deleteTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:thumb];
        [row addArrangedSubview:name];
        [row addArrangedSubview:del];
        [self.savedStack addArrangedSubview:row];
        idx++;
    }
}

- (void)generateTapped {
    NSMutableDictionary *body = [@{
        @"action": @"character_generate",
        @"sex": self.sexSeg.selectedSegmentIndex == 1 ? @"male" : @"female",
        @"age_group": @[@"20s", @"30s", @"40s", @"50+"][(NSUInteger)MAX(0, self.ageSeg.selectedSegmentIndex)],
        @"style": @[@"realistic", @"anime", @"3d", @"illustration"][(NSUInteger)MAX(0, self.styleSeg.selectedSegmentIndex)],
    } mutableCopy];
    NSDictionary *fields = @{
        @"hair": self.hairField, @"appearance": self.appearanceField,
        @"outfit": self.outfitField,
    };
    for (NSString *key in fields) {
        UITextField *field = fields[key];
        NSString *value = [field.text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (value.length) body[key] = value;
    }
    NSString *extra = [self.extraField.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (extra.length) body[@"prompt"] = extra;
    NSString *storefront = [EZStoreKitManager storefrontCountryCode];
    if (storefront.length) body[@"storefront"] = storefront;

    [self setBusy:YES status:EZVideoLocalized(@"EZSeahorseVideo.GeneratingCharacter")];
    [self postSeahorse:body completion:^(NSDictionary *json, NSError *error) {
        [self setBusy:NO status:nil];
        NSString *err = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : nil;
        if (!json || err.length) {
            if ([err isEqualToString:@"id_verification_required"]) {
                [self showError:EZVideoLocalized(@"EZSeahorseVideo.IDCheckFirst")];
            } else if ([err isEqualToString:@"recent_purchase_required"]) {
                [self showError:EZVideoLocalized(@"EZSeahorseVideo.PurchaseFirst")];
            } else if ([err isEqualToString:@"Insufficient coins"]) {
                [self showError:[NSString stringWithFormat:
                    EZVideoLocalized(@"EZSeahorseVideo.InsufficientFormat"),
                    (long)self.characterCost, (long)EZVideoInteger(json[@"balance"])]];
            } else {
                [self showError:err ?: EZVideoLocalized(@"EZSeahorseVideo.LoadFailed")];
            }
            return;
        }
        id bal = json[@"balance"];
        if (bal && ![bal isKindOfClass:NSNull.class])
            [[EZEntitlementManager shared] applyKnownBalance:EZVideoInteger(bal)];
        NSArray *cands = [json[@"candidates"] isKindOfClass:NSArray.class] ? json[@"candidates"] : @[];
        NSMutableArray *valid = [NSMutableArray array];
        for (id cand in cands) if ([cand isKindOfClass:NSDictionary.class]) [valid addObject:cand];
        self.candidates = valid;
        self.selectedCandidate = cands.count ? 0 : -1;
        [self renderCandidates];
        self.statusLabel.text = EZVideoLocalized(@"EZSeahorseVideo.PickCandidate");
    }];
}

- (void)renderCandidates {
    for (UIView *v in [self.candidateStack.arrangedSubviews copy]) {
        [self.candidateStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSInteger idx = 0;
    for (NSDictionary *cand in self.candidates) {
        if (![cand isKindOfClass:NSDictionary.class]) { idx++; continue; }
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.backgroundColor = [EZTheme cardColor];
        button.layer.cornerRadius = 10;
        button.layer.borderWidth = (idx == self.selectedCandidate) ? 3 : 0;
        button.layer.borderColor = [EZTheme goldColor].CGColor;
        button.tag = idx;
        [button.heightAnchor constraintEqualToConstant:180].active = YES;
        [button addTarget:self action:@selector(candidateTapped:) forControlEvents:UIControlEventTouchUpInside];
        NSString *thumbURL = [cand[@"thumb_url"] isKindOfClass:NSString.class] ? cand[@"thumb_url"] : nil;
        EZVideoLoadImage(thumbURL, ^(UIImage *image) {
            [button setImage:image forState:UIControlStateNormal];
            button.imageView.contentMode = UIViewContentModeScaleAspectFit;
        });
        [self.candidateStack addArrangedSubview:button];
        idx++;
    }
    self.saveButton.enabled = !self.busy && self.selectedCandidate >= 0;
}

- (void)candidateTapped:(UIButton *)sender {
    self.selectedCandidate = sender.tag;
    [self renderCandidates];
}

- (void)saveTapped {
    if (self.selectedCandidate < 0 || self.selectedCandidate >= (NSInteger)self.candidates.count) return;
    NSDictionary *cand = self.candidates[(NSUInteger)self.selectedCandidate];
    NSString *ref = [cand[@"ref"] isKindOfClass:NSString.class] ? cand[@"ref"] : @"";
    if (!ref.length) return;
    NSMutableDictionary *body = [@{ @"action": @"character_save", @"from_ref": ref } mutableCopy];
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    if (name.length) body[@"name"] = name;
    NSString *thumbURL = [cand[@"thumb_url"] isKindOfClass:NSString.class] ? cand[@"thumb_url"] : nil;
    if (thumbURL.length) body[@"thumb_url"] = thumbURL;
    [self setBusy:YES status:nil];
    [self postSeahorse:body completion:^(NSDictionary *json, NSError *error) {
        [self setBusy:NO status:nil];
        NSString *err = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : nil;
        if (err.length) { [self showError:err]; return; }
        self.candidates = @[];
        self.selectedCandidate = -1;
        [self renderCandidates];
        self.statusLabel.text = EZVideoLocalized(@"EZSeahorseVideo.CharacterSaved");
        [self loadCharacters];
        if (self.onCharactersChanged) self.onCharactersChanged();
    }];
}

- (void)deleteTapped:(UIButton *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)self.savedItems.count) return;
    NSDictionary *item = self.savedItems[(NSUInteger)sender.tag];
    NSString *itemID = [item[@"item_id"] isKindOfClass:NSString.class] ? item[@"item_id"] : @"";
    if (!itemID.length) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:EZVideoLocalized(@"EZSeahorseVideo.DeleteCharacterConfirm")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.OK")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:EZVideoLocalized(@"EZSeahorseVideo.DeleteCharacter")
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [self postSeahorse:@{ @"action": @"character_delete", @"item_id": itemID }
                completion:^(NSDictionary *json, NSError *error) {
            NSString *err = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : nil;
            if (err.length) { [self showError:err]; return; }
            [self loadCharacters];
            if (self.onCharactersChanged) self.onCharactersChanged();
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#else // APPSTORE — NSFW video is not part of App Store builds.

@implementation EZSeahorseVideoViewController
@end

#endif
