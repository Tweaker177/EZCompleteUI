// BRSlotChatBar.m
// EZCompleteUI
//
// Purpose:
//   The lounge chat used inside every slot machine and at every blackjack
//   table. It shows the newest message as a one-line bar and expands into the
//   full conversation (history, composer, profile, winners). The room id
//   decides which conversation it joins.
//
// Changes (blackjack tables):
//   - Rooms whose id starts with "bj:" belong to a blackjack table. They never
//     request lounge host turns (the table's dealer, Lucky Lou, is driven by
//     the br-blackjack function) and show Lucky Lou's name and caption instead
//     of the lounge host's.

#import "BRSlotChatBar.h"
#import "EZAuthManager.h"
#import "EZSupabaseConfig.h"
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>

// br-slot-social replies are parsed JSON: any field can be NSNull or the
// wrong type, and messaging boolValue/integerValue — or subscripting a
// non-dictionary — to one of those crashes mid-chat. Coerce every read.
static BOOL BRChatBool(id value) { return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO; }
static NSInteger BRChatInteger(id value) { return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0; }
static NSString *BRChatString(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
static NSNumber *BRChatNumber(id value) { return [value isKindOfClass:NSNumber.class] ? value : @0; }
static NSDictionary *BRChatDictionary(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
// Avatars show at up to 76pt: cap the upload at 512px so a full-resolution
// library photo doesn't become a multi-MB base64 JSON body that times out
// and silently fails the save (same shape as the 1600px ID-upload cap).
static UIImage *BRChatScaledAvatar(UIImage *image) {
    if (!image) return nil;
    CGFloat maxDim = MAX(image.size.width, image.size.height);
    if (maxDim < 1 || maxDim <= 512) return image;
    CGFloat scale = 512.0 / maxDim;
    CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
    UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) { [image drawInRect:CGRectMake(0, 0, size.width, size.height)]; }];
}

NSNotificationName const BRSlotProfileDidUpdateNotification = @"BRSlotProfileDidUpdateNotification";
NSNotificationName const BRSlotSoundSettingChangedNotification = @"BRSlotSoundSettingChangedNotification";

static NSString * const BRSlotSoundEnabledKey = @"BRSlotSoundEnabled";
BOOL BRSlotSoundEnabled(void) {
    NSNumber *value = [[NSUserDefaults standardUserDefaults] objectForKey:BRSlotSoundEnabledKey];
    return value ? value.boolValue : YES;
}
void BRSlotSetSoundEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:BRSlotSoundEnabledKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:BRSlotSoundSettingChangedNotification object:nil];
}

// Displayed avatars are small (76pt board rows, a ~40pt nav button, a 76pt
// editor preview): decode downloads straight to a cover thumbnail at the
// display size instead of keeping the 512px upload alive per row.
static UIImage *BRChatThumbnailFromData(NSData *data, CGFloat points) {
    UIImage *image = data ? [UIImage imageWithData:data] : nil;
    if (!image) return nil;
    if (points < 1) points = 68;
    // Target size in POINTS, rendered at the screen's scale, so the
    // returned image reports the requested point size. (This used to
    // compute the size in pixels with a 1.0 format scale: a 36pt
    // thumbnail came back as a ~108pt image. Fixed-size image views
    // cropped it and looked fine, but the slot picker's profile
    // button sizes itself from the image and ballooned into a big
    // filled slab instead of a photo.)
    CGFloat factor = MAX(points / image.size.width, points / image.size.height);
    CGSize size = CGSizeMake(MAX(1, round(image.size.width * factor)), MAX(1, round(image.size.height * factor)));
    UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
    format.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) { [image drawInRect:CGRectMake(0, 0, size.width, size.height)]; }];
}
static NSString *BRChatAvatarIdentity(NSString *url) { return url ? ([url componentsSeparatedByString:@"?"].firstObject ?: url) : nil; }
static NSCache<NSString *, UIImage *> *BRChatAvatarCache(void) { static NSCache *cache; static dispatch_once_t once; dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 64; }); return cache; }

// Avatars are also cached on disk (Library/Caches/BRChatAvatars), keyed by
// the same URL|points string as the memory cache, so the leaderboard shows
// real photos on a cold start instead of the gold placeholder while every
// avatar re-downloads. Caches is not backed up and the system may purge it;
// a miss just downloads again. A changed photo gets a new URL, so a stale
// file can never serve the wrong face.
static NSString *BRChatAvatarDiskPathForKey(NSString *key) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        dir = [caches stringByAppendingPathComponent:@"BRChatAvatars"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    NSData *keyData = [key dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256(keyData.bytes, (CC_LONG)keyData.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int j = 0; j < CC_SHA256_DIGEST_LENGTH; j++) [hex appendFormat:@"%02x", digest[j]];
    return [dir stringByAppendingPathComponent:[hex stringByAppendingString:@".jpg"]];
}

@interface BRSlotChatPromptController : UIViewController <UITextFieldDelegate, UITextViewDelegate>
@property (nonatomic, copy) NSString *promptTitle, *promptBody, *initialText;
@property (nonatomic, strong) UIImage *avatarImage;
@property (nonatomic, copy) NSString *avatarURLString;
@property (nonatomic, copy) NSArray<NSString *> *actions;
@property (nonatomic, copy) void (^selection)(NSInteger action, NSString *text);
@property (nonatomic, copy) NSString *initialStatus;
@property (nonatomic, copy) void (^selectionWithStatus)(NSInteger action, NSString *text, NSString *status);
@property (nonatomic, strong) UITextView *statusView;
@property (nonatomic, strong) UILabel *statusPlaceholderLabel;
@property (nonatomic, strong) UILabel *statusCountLabel;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) NSLayoutConstraint *cardCenterYConstraint;
@end

@implementation BRSlotChatPromptController
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor = [UIColor colorWithRed:.055 green:.02 blue:.12 alpha:1]; self.modalPresentationStyle = UIModalPresentationPageSheet; self.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent]]; self.sheetPresentationController.prefersGrabberVisible = YES; self.sheetPresentationController.preferredCornerRadius = 25;
    UIView *card = [UIView new]; card.backgroundColor = [UIColor colorWithRed:.13 green:.045 blue:.23 alpha:1]; card.layer.cornerRadius = 22; card.layer.borderWidth = 1; card.layer.borderColor = [UIColor colorWithRed:1 green:.75 blue:.18 alpha:.62].CGColor; card.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:card]; self.cardView = card; UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(br_backgroundTapped:)]; bgTap.cancelsTouchesInView = NO; [self.view addGestureRecognizer:bgTap];
    UILabel *title = [UILabel new]; title.text = self.promptTitle; title.textColor = UIColor.whiteColor; title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBlack]; title.numberOfLines = 2; title.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:title];
    UILabel *body = [UILabel new]; body.text = self.promptBody; body.textColor = [UIColor colorWithWhite:.73 alpha:1]; body.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium]; body.numberOfLines = 0; body.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:body];
    UIImageView *avatarView = nil;
    if (self.avatarImage || self.avatarURLString.length) { avatarView = [UIImageView new]; avatarView.image = self.avatarImage ?: [UIImage systemImageNamed:@"person.crop.circle.fill"]; avatarView.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1]; avatarView.contentMode = UIViewContentModeScaleAspectFill; avatarView.clipsToBounds = YES; avatarView.layer.cornerRadius = 38; avatarView.layer.borderWidth = 1; avatarView.layer.borderColor = [UIColor colorWithRed:1 green:.75 blue:.18 alpha:.62].CGColor; avatarView.backgroundColor = [UIColor colorWithWhite:1 alpha:.07]; avatarView.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:avatarView]; if (!self.avatarImage && self.avatarURLString.length) { __weak UIImageView *weakAvatar = avatarView; [BRSlotChatBar loadAvatarThumbnailForURL:self.avatarURLString points:76 completion:^(UIImage *image) { if (image) weakAvatar.image = image; }]; } }
    self.textField = [UITextField new]; self.textField.text = self.initialText; self.textField.placeholder = NSLocalizedString(@"BRSlot.Lounge.DisplayName", nil); self.textField.textColor = UIColor.whiteColor; self.textField.backgroundColor = [UIColor colorWithWhite:1 alpha:.09]; self.textField.layer.cornerRadius = 12; self.textField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,12,1)]; self.textField.leftViewMode = UITextFieldViewModeAlways; self.textField.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:self.textField]; self.textField.hidden = !self.initialText; self.textField.delegate = self; self.textField.returnKeyType = UIReturnKeyDone;
    if (self.initialStatus) {
        self.statusView = [UITextView new]; self.statusView.text = self.initialStatus; self.statusView.font = [UIFont systemFontOfSize:15]; self.statusView.textColor = UIColor.whiteColor; self.statusView.backgroundColor = [UIColor colorWithWhite:1 alpha:.09]; self.statusView.layer.cornerRadius = 12; self.statusView.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8); self.statusView.translatesAutoresizingMaskIntoConstraints = NO; self.statusView.delegate = self; [card addSubview:self.statusView];
        self.statusPlaceholderLabel = [UILabel new]; self.statusPlaceholderLabel.text = @"Add a status\u2026"; self.statusPlaceholderLabel.font = [UIFont systemFontOfSize:15]; self.statusPlaceholderLabel.textColor = [UIColor colorWithWhite:.55 alpha:1]; self.statusPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = NO; self.statusPlaceholderLabel.hidden = self.initialStatus.length > 0; [card addSubview:self.statusPlaceholderLabel];
        self.statusCountLabel = [UILabel new]; self.statusCountLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium]; self.statusCountLabel.textColor = [UIColor colorWithWhite:.55 alpha:1]; self.statusCountLabel.textAlignment = NSTextAlignmentRight; self.statusCountLabel.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:self.statusCountLabel];
        [self updateStatusCount];
    }
    UIStackView *buttons = [UIStackView new]; buttons.axis = UILayoutConstraintAxisVertical; buttons.spacing = 9; buttons.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:buttons]; [self.actions enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *stop) { UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:name forState:UIControlStateNormal]; [b setTitleColor:index == self.actions.count - 1 ? [UIColor colorWithWhite:.72 alpha:1] : UIColor.whiteColor forState:UIControlStateNormal]; b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBlack]; b.backgroundColor = index == self.actions.count - 1 ? [UIColor colorWithWhite:1 alpha:.07] : [UIColor colorWithRed:.58 green:.12 blue:.42 alpha:1]; b.layer.cornerRadius = 12; b.tag = index; [b addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside]; [buttons addArrangedSubview:b]; [b.heightAnchor constraintEqualToConstant:43].active = YES; }];
    NSLayoutYAxisAnchor *buttonsTop = self.statusCountLabel ? self.statusCountLabel.bottomAnchor : (self.textField.hidden ? (avatarView ? avatarView.bottomAnchor : body.bottomAnchor) : self.textField.bottomAnchor); CGFloat buttonsGap = self.statusCountLabel ? 14 : 18;
    self.cardCenterYConstraint = [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]; [NSLayoutConstraint activateConstraints:@[[card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:18], [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-18], self.cardCenterYConstraint, [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:22], [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20], [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20], [body.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:7], [body.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [body.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [self.textField.topAnchor constraintEqualToAnchor:avatarView ? avatarView.bottomAnchor : body.bottomAnchor constant:avatarView ? 14 : 16], [self.textField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [self.textField.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [self.textField.heightAnchor constraintEqualToConstant:46], [buttons.topAnchor constraintEqualToAnchor:buttonsTop constant:buttonsGap], [buttons.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [buttons.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [buttons.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20]]]; if (self.statusView) [NSLayoutConstraint activateConstraints:@[[self.statusView.topAnchor constraintEqualToAnchor:self.textField.bottomAnchor constant:10], [self.statusView.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [self.statusView.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [self.statusView.heightAnchor constraintEqualToConstant:66], [self.statusPlaceholderLabel.topAnchor constraintEqualToAnchor:self.statusView.topAnchor constant:10], [self.statusPlaceholderLabel.leadingAnchor constraintEqualToAnchor:self.statusView.leadingAnchor constant:13], [self.statusCountLabel.topAnchor constraintEqualToAnchor:self.statusView.bottomAnchor constant:5], [self.statusCountLabel.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [self.statusCountLabel.trailingAnchor constraintEqualToAnchor:title.trailingAnchor]]]; if (avatarView) [NSLayoutConstraint activateConstraints:@[[avatarView.topAnchor constraintEqualToAnchor:body.bottomAnchor constant:14], [avatarView.centerXAnchor constraintEqualToAnchor:card.centerXAnchor], [avatarView.widthAnchor constraintEqualToConstant:76], [avatarView.heightAnchor constraintEqualToConstant:76]]]; }
- (void)tapped:(UIButton *)sender { NSString *text = self.textField.text ?: @""; NSString *status = self.statusView ? (self.statusView.text ?: @"") : nil; NSInteger action = sender.tag; [self dismissViewControllerAnimated:YES completion:^{ if (self.selectionWithStatus) self.selectionWithStatus(action, text, status); else if (self.selection) self.selection(action, text); }]; }
- (void)updateStatusCount { self.statusCountLabel.text = [NSString stringWithFormat:@"%lu / 280", (unsigned long)self.statusView.text.length]; self.statusPlaceholderLabel.hidden = self.statusView.text.length > 0; }
- (void)textViewDidChange:(UITextView *)textView { [self updateStatusCount]; }
- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text { NSString *next = [textView.text stringByReplacingCharactersInRange:range withString:text]; return next.length <= 280; }
// Keyboard handling: the card is centered in a medium sheet and the
// action buttons sit at its bottom, so an open keyboard covers them
// and the name cannot be saved. While the keyboard is up, shift the
// card up by exactly the overlap; Done or a tap outside the card
// dismisses the keyboard and the card settles back.
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(br_keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil]; [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(br_keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil]; [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil]; }
- (void)br_keyboardWillShow:(NSNotification *)note { if (self.textField.hidden) return; [self.view layoutIfNeeded]; CGRect kb = [self.view convertRect:[note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil]; CGFloat overlap = CGRectGetMaxY(self.cardView.frame) - CGRectGetMinY(kb) + 16; if (overlap <= 0) return; self.cardCenterYConstraint.constant = -overlap; [UIView animateWithDuration:[note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] delay:0 options:([note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue] << 16) animations:^{ [self.view layoutIfNeeded]; } completion:nil]; }
- (void)br_keyboardWillHide:(NSNotification *)note { if (self.cardCenterYConstraint.constant == 0) return; self.cardCenterYConstraint.constant = 0; [UIView animateWithDuration:[note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue] delay:0 options:([note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue] << 16) animations:^{ [self.view layoutIfNeeded]; } completion:nil]; }
- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }
- (void)br_backgroundTapped:(UITapGestureRecognizer *)tap { if (!CGRectContainsPoint(self.cardView.frame, [tap locationInView:self.view])) { [self.textField resignFirstResponder]; [self.statusView resignFirstResponder]; } }
@end

// Full-screen player profile, opened by tapping a leaderboard row: big
// picture, their status, and their numbers for the day and all time. All
// data rides on the leaderboard row itself (br-slot-social enriches every
// row), so opening it needs no extra request.
@interface BRSlotPlayerProfileController : UIViewController
@property (nonatomic, copy) NSString *playerName;
@property (nonatomic, copy) NSString *avatarURLString;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, copy) NSDictionary *stats;
@end
@implementation BRSlotPlayerProfileController
- (NSString *)formattedNumber:(id)value {
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    return [formatter stringFromNumber:BRChatNumber(value)] ?: @"0";
}
- (void)addStatRowToStack:(UIStackView *)stack label:(NSString *)label value:(NSString *)value {
    UIView *row = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *name = [UILabel new];
    name.text = label;
    name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    name.textColor = [UIColor colorWithWhite:.72 alpha:1];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:name];
    UILabel *amount = [UILabel new];
    amount.text = value;
    amount.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    amount.textColor = UIColor.whiteColor;
    amount.textAlignment = NSTextAlignmentRight;
    amount.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:amount];
    [NSLayoutConstraint activateConstraints:@[
        [name.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [name.topAnchor constraintEqualToAnchor:row.topAnchor constant:7],
        [name.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-7],
        [amount.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [amount.leadingAnchor constraintGreaterThanOrEqualToAnchor:name.trailingAnchor constant:12],
        [amount.centerYAnchor constraintEqualToAnchor:name.centerYAnchor]]];
    [stack addArrangedSubview:row];
}
- (void)addSectionHeaderToStack:(UIStackView *)stack text:(NSString *)text {
    UILabel *header = [UILabel new];
    header.text = text;
    header.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBlack];
    header.textColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];
    [stack addArrangedSubview:header];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:.055 green:.02 blue:.12 alpha:1];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
    UIImageView *avatar = [UIImageView new];
    avatar.image = [UIImage systemImageNamed:@"person.crop.circle.fill"];
    avatar.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];
    avatar.contentMode = UIViewContentModeScaleAspectFill;
    avatar.clipsToBounds = YES;
    avatar.layer.cornerRadius = 28;
    avatar.layer.borderWidth = 1;
    avatar.layer.borderColor = [UIColor colorWithRed:1 green:.75 blue:.18 alpha:.62].CGColor;
    avatar.backgroundColor = [UIColor colorWithWhite:1 alpha:.07];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    [avatar.heightAnchor constraintEqualToConstant:280].active = YES;
    [stack addArrangedSubview:avatar];
    if (self.avatarURLString.length) {
        __weak UIImageView *weakAvatar = avatar;
        [BRSlotChatBar loadAvatarThumbnailForURL:self.avatarURLString points:280 completion:^(UIImage *image) { if (image) { weakAvatar.image = image; weakAvatar.tintColor = nil; } }];
    }
    UILabel *name = [UILabel new];
    name.text = self.playerName;
    name.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBlack];
    name.textColor = UIColor.whiteColor;
    name.textAlignment = NSTextAlignmentCenter;
    name.numberOfLines = 0;
    [stack addArrangedSubview:name];
    NSString *status = [self.statusText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (status.length) {
        UILabel *statusLabel = [UILabel new];
        statusLabel.text = status;
        statusLabel.font = [UIFont systemFontOfSize:16];
        statusLabel.textColor = [UIColor colorWithWhite:.88 alpha:1];
        statusLabel.textAlignment = NSTextAlignmentCenter;
        statusLabel.numberOfLines = 0;
        [stack addArrangedSubview:statusLabel];
    }
    UIView *card = [UIView new];
    card.backgroundColor = [UIColor colorWithRed:.13 green:.045 blue:.23 alpha:1];
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithRed:1 green:.75 blue:.18 alpha:.4].CGColor;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *statsStack = [UIStackView new];
    statsStack.axis = UILayoutConstraintAxisVertical;
    statsStack.spacing = 2;
    statsStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:statsStack];
    [NSLayoutConstraint activateConstraints:@[
        [statsStack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [statsStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [statsStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [statsStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18]]];
    [self addSectionHeaderToStack:statsStack text:@"TODAY"];
    [self addStatRowToStack:statsStack label:@"Won" value:[self formattedNumber:self.stats[@"won_24h"]]];
    [self addStatRowToStack:statsStack label:@"Best hit" value:[self formattedNumber:self.stats[@"best_24h"]]];
    [self addSectionHeaderToStack:statsStack text:@"ALL TIME"];
    [self addStatRowToStack:statsStack label:@"Winnings" value:[self formattedNumber:self.stats[@"won_all"]]];
    [self addStatRowToStack:statsStack label:@"Biggest win" value:[self formattedNumber:self.stats[@"best_all"]]];
    [self addStatRowToStack:statsStack label:@"Total spins" value:[self formattedNumber:self.stats[@"spins_all"]]];
    [self addStatRowToStack:statsStack label:@"Recorded wins" value:[self formattedNumber:self.stats[@"wins_all"]]];
    NSString *favorite = BRChatString(self.stats[@"favorite_game"]);
    [self addStatRowToStack:statsStack label:@"Favorite slot" value:favorite.length ? favorite : @"—"];
    // Blackjack record, shown once the player has played a hand.
    if ([self.stats[@"bj_hands"] respondsToSelector:@selector(integerValue)] && [self.stats[@"bj_hands"] integerValue] > 0) {
        [self addSectionHeaderToStack:statsStack text:@"BLACKJACK"];
        [self addStatRowToStack:statsStack label:@"Hands played" value:[self formattedNumber:self.stats[@"bj_hands"]]];
        [self addStatRowToStack:statsStack label:@"Hands won" value:[self formattedNumber:self.stats[@"bj_won"]]];
        [self addStatRowToStack:statsStack label:@"Biggest win" value:[self formattedNumber:self.stats[@"bj_best"]]];
        [self addStatRowToStack:statsStack label:@"Blackjacks" value:[self formattedNumber:self.stats[@"bj_blackjacks"]]];
        [self addStatRowToStack:statsStack label:@"Coins won" value:[self formattedNumber:self.stats[@"bj_total_won"]]];
    }
    [stack addArrangedSubview:card];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-32],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],
        [close.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [close.widthAnchor constraintEqualToConstant:36],
        [close.heightAnchor constraintEqualToConstant:36]]];
}
- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }
@end


@interface BRSlotChatBar () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, copy) NSString *roomID;
@property (nonatomic, strong) UIView *collapsedView;
@property (nonatomic, strong) UILabel *latestLabel;
@property (nonatomic, strong) UIView *expandedView;
@property (nonatomic, strong) UILabel *presenceLabel;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UITextField *composer;
@property (nonatomic, strong) NSLayoutConstraint *heightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *bottomConstraint;
@property (nonatomic, copy) NSArray<NSDictionary *> *messages;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTimer *hostTimer;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL expanded;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL justSent;
@property (nonatomic) BOOL hasProfile;
@property (nonatomic, strong) UIImage *pendingAvatar;
@property (nonatomic) BOOL musicEnabled;
@property (nonatomic, copy) NSString *profileName;
@property (nonatomic, copy) NSString *profileStatus;
@property (nonatomic, copy) NSString *profileAvatarURL;
@property (nonatomic) NSInteger profileVipPoints;
@end

@implementation BRSlotChatBar

- (instancetype)initWithRoomID:(NSString *)roomID {
    if ((self = [super initWithFrame:CGRectZero])) {
        _roomID = [roomID copy];
        _messages = @[];
        self.backgroundColor = [UIColor colorWithRed:.14 green:.055 blue:.24 alpha:.97];
        self.layer.cornerRadius = 16;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:.35].CGColor;
        self.clipsToBounds = YES;
        [self buildCollapsedView];
        [self buildExpandedView];
        self.expandedView.hidden = YES;
        self.expandedView.alpha = 0;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [self.pollTimer invalidate];
    [self.hostTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)buildCollapsedView {
    self.collapsedView = [UIView new];
    self.collapsedView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.collapsedView];
    UILabel *icon = [UILabel new]; icon.text = @"💬"; icon.font = [UIFont systemFontOfSize:13]; icon.translatesAutoresizingMaskIntoConstraints = NO; [self.collapsedView addSubview:icon];
    self.latestLabel = [UILabel new];
    self.latestLabel.text = NSLocalizedString(@"BRSlot.Lounge.Connecting", nil);
    self.latestLabel.textColor = [UIColor colorWithWhite:.88 alpha:1];
    self.latestLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.latestLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.latestLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.collapsedView addSubview:self.latestLabel];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.up"]];
    chevron.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [self.collapsedView addSubview:chevron];
    UIButton *tap = [UIButton buttonWithType:UIButtonTypeCustom];
    tap.translatesAutoresizingMaskIntoConstraints = NO;
    [tap addTarget:self action:@selector(expandTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.collapsedView addSubview:tap];
    [NSLayoutConstraint activateConstraints:@[
        [self.collapsedView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.collapsedView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.collapsedView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.collapsedView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [icon.leadingAnchor constraintEqualToAnchor:self.collapsedView.leadingAnchor constant:10],
        [icon.centerYAnchor constraintEqualToAnchor:self.collapsedView.centerYAnchor],
        [self.latestLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:7],
        [self.latestLabel.centerYAnchor constraintEqualToAnchor:self.collapsedView.centerYAnchor],
        [self.latestLabel.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-6],
        [chevron.trailingAnchor constraintEqualToAnchor:self.collapsedView.trailingAnchor constant:-10],
        [chevron.centerYAnchor constraintEqualToAnchor:self.collapsedView.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:14],
        [chevron.heightAnchor constraintEqualToConstant:14],
        [tap.topAnchor constraintEqualToAnchor:self.collapsedView.topAnchor],
        [tap.bottomAnchor constraintEqualToAnchor:self.collapsedView.bottomAnchor],
        [tap.leadingAnchor constraintEqualToAnchor:self.collapsedView.leadingAnchor],
        [tap.trailingAnchor constraintEqualToAnchor:self.collapsedView.trailingAnchor]]];
}

- (void)buildExpandedView {
    self.expandedView = [UIView new];
    self.expandedView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.expandedView];
    // Header: presence on the left, collapse on the right. The winners board and profile buttons live on the game picker now.
    self.presenceLabel = [UILabel new]; self.presenceLabel.text = NSLocalizedString(@"BRSlot.Lounge.Connecting", nil); self.presenceLabel.textColor = [UIColor colorWithRed:.55 green:1 blue:.72 alpha:1]; self.presenceLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightBold]; self.presenceLabel.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:self.presenceLabel];
    UIButton *collapse = [UIButton buttonWithType:UIButtonTypeSystem]; [collapse setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal]; [collapse setTitle:NSLocalizedString(@"BRSlot.Lounge.Close", nil) forState:UIControlStateNormal]; [collapse setTitleColor:[UIColor colorWithRed:1 green:.78 blue:.2 alpha:1] forState:UIControlStateNormal]; collapse.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold]; collapse.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 4); collapse.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1]; [collapse addTarget:self action:@selector(collapseTapped) forControlEvents:UIControlEventTouchUpInside]; collapse.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:collapse];
    // Grabber pill at the top centre: signals the panel can be pulled
    // down, and a downward swipe on the header strip collapses it. The
    // bare chevron alone was too easy to miss (feedback: "no dismiss
    // button, doesn't swipe down").
    UIView *grabber = [UIView new]; grabber.backgroundColor = [UIColor colorWithWhite:1 alpha:.55]; grabber.layer.cornerRadius = 2.5; grabber.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:grabber];
    [NSLayoutConstraint activateConstraints:@[[grabber.topAnchor constraintEqualToAnchor:self.expandedView.topAnchor constant:5], [grabber.centerXAnchor constraintEqualToAnchor:self.expandedView.centerXAnchor], [grabber.widthAnchor constraintEqualToConstant:44], [grabber.heightAnchor constraintEqualToConstant:5]]];
    self.presenceLabel.userInteractionEnabled = YES;
    UISwipeGestureRecognizer *headerSwipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(collapseTapped)]; headerSwipe.direction = UISwipeGestureRecognizerDirectionDown; [grabber addGestureRecognizer:headerSwipe];
    UISwipeGestureRecognizer *presenceSwipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(collapseTapped)]; presenceSwipe.direction = UISwipeGestureRecognizerDirectionDown; [self.presenceLabel addGestureRecognizer:presenceSwipe];
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain]; self.table.backgroundColor = UIColor.clearColor; self.table.separatorStyle = UITableViewCellSeparatorStyleNone; self.table.dataSource = self; self.table.delegate = self; self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive; self.table.estimatedRowHeight = 56; self.table.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:self.table];
    UILabel *note = [UILabel new]; note.text = NSLocalizedString(@"BRSlot.Lounge.Note", nil); note.numberOfLines = 2; note.textAlignment = NSTextAlignmentCenter; note.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium]; note.textColor = [UIColor colorWithWhite:.56 alpha:1]; note.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:note];
    UIView *bar = [UIView new]; bar.backgroundColor = [UIColor colorWithWhite:1 alpha:.08]; bar.layer.cornerRadius = 18; bar.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:bar];
    self.composer = [UITextField new]; self.composer.placeholder = NSLocalizedString(@"BRSlot.Lounge.Composer", nil); self.composer.textColor = UIColor.whiteColor; self.composer.attributedPlaceholder = [[NSAttributedString alloc] initWithString:self.composer.placeholder attributes:@{NSForegroundColorAttributeName:[UIColor colorWithWhite:.62 alpha:1]}]; self.composer.delegate = self; self.composer.returnKeyType = UIReturnKeySend; self.composer.translatesAutoresizingMaskIntoConstraints = NO; [bar addSubview:self.composer];
    UIToolbar *composerAccessory = [UIToolbar new];
    [composerAccessory sizeToFit];
    composerAccessory.barStyle = UIBarStyleBlack;
    UIBarButtonItem *composerFlex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *composerDone = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissComposerKeyboard)];
    [composerAccessory setItems:@[composerFlex, composerDone]];
    self.composer.inputAccessoryView = composerAccessory;
    UIButton *send = [UIButton buttonWithType:UIButtonTypeSystem]; [send setImage:[UIImage systemImageNamed:@"paperplane.fill"] forState:UIControlStateNormal]; send.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1]; [send addTarget:self action:@selector(send) forControlEvents:UIControlEventTouchUpInside]; send.translatesAutoresizingMaskIntoConstraints = NO; [bar addSubview:send];
    [NSLayoutConstraint activateConstraints:@[
        [self.expandedView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.expandedView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.expandedView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.expandedView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.presenceLabel.topAnchor constraintEqualToAnchor:self.expandedView.topAnchor constant:9],
        [self.presenceLabel.leadingAnchor constraintEqualToAnchor:self.expandedView.leadingAnchor constant:12],
        [self.presenceLabel.trailingAnchor constraintLessThanOrEqualToAnchor:collapse.leadingAnchor constant:-8],
        [collapse.trailingAnchor constraintEqualToAnchor:self.expandedView.trailingAnchor constant:-8],
        [collapse.centerYAnchor constraintEqualToAnchor:self.presenceLabel.centerYAnchor],
        [collapse.heightAnchor constraintEqualToConstant:26],
        [self.table.topAnchor constraintEqualToAnchor:self.presenceLabel.bottomAnchor constant:6],
        [self.table.leadingAnchor constraintEqualToAnchor:self.expandedView.leadingAnchor constant:6],
        [self.table.trailingAnchor constraintEqualToAnchor:self.expandedView.trailingAnchor constant:-6],
        [self.table.bottomAnchor constraintEqualToAnchor:note.topAnchor constant:-2],
        [note.leadingAnchor constraintEqualToAnchor:self.expandedView.leadingAnchor constant:14],
        [note.trailingAnchor constraintEqualToAnchor:self.expandedView.trailingAnchor constant:-14],
        [note.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-3],
        [bar.leadingAnchor constraintEqualToAnchor:self.expandedView.leadingAnchor constant:10],
        [bar.trailingAnchor constraintEqualToAnchor:self.expandedView.trailingAnchor constant:-10],
        [bar.bottomAnchor constraintEqualToAnchor:self.expandedView.bottomAnchor constant:-8],
        [bar.heightAnchor constraintEqualToConstant:44],
        [self.composer.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:14],
        [self.composer.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [self.composer.trailingAnchor constraintEqualToAnchor:send.leadingAnchor constant:-8],
        [send.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-10],
        [send.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [send.widthAnchor constraintEqualToConstant:32], [send.heightAnchor constraintEqualToConstant:32]]];
}

- (void)attachToView:(UIView *)view {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:self];
    UILayoutGuide *safe = view.safeAreaLayoutGuide;
    self.bottomConstraint = [self.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-6];
    self.heightConstraint = [self.heightAnchor constraintEqualToConstant:38];
    [NSLayoutConstraint activateConstraints:@[
        [self.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:10],
        [self.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-10],
        self.bottomConstraint, self.heightConstraint]];
}

- (void)start {
    if (self.started) return;
    self.started = YES;
    [self refresh];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:6 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    // Every listener can ask for a host turn, but the server atomically permits
    // only one live model response per room every three minutes.
    // Blackjack tables ("bj:" rooms) have their own dealer, Lucky Lou, who is
    // driven by the br-blackjack function, so no lounge host turns are requested.
    if (![self.roomID hasPrefix:@"bj:"]) self.hostTimer = [NSTimer scheduledTimerWithTimeInterval:75 target:self selector:@selector(requestLiveHostTurn) userInfo:nil repeats:YES];
}

- (void)stop {
    self.started = NO;
    [self.pollTimer invalidate]; self.pollTimer = nil;
    [self.hostTimer invalidate]; self.hostTimer = nil;
}

- (void)expandTapped { [self setExpanded:YES animated:YES]; }
- (void)collapseTapped { [self setExpanded:NO animated:YES]; }

// The expanded panel is 62% of the host height, capped at 560pt. With the
// keyboard up that height pushes the panel's top - Close button and grabber -
// off the screen, so the keyboard-up height is capped to leave the top row
// visible.
- (CGFloat)expandedPanelHeightForKeyboardOverlap:(CGFloat)overlap {
    CGFloat hostHeight = self.superview.bounds.size.height;
    CGFloat height = hostHeight > 0 ? MIN(MAX(hostHeight * 0.62, 320), 560) : 420;
    if (overlap > 0) {
        // The header has to clear the navigation bar, not just the top of
        // the screen: the host view runs underneath it, so a flat margin
        // leaves the grabber and Close hidden behind the nav pills.
        CGFloat topMargin = MAX(16, self.superview.safeAreaInsets.top + 8);
        CGFloat maxHeight = hostHeight - overlap + self.superview.safeAreaInsets.bottom - 6 - topMargin;
        height = MIN(height, MAX(maxHeight, 240));
    }
    return height;
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (self.expanded == expanded) return;
    self.expanded = expanded;
    if (expanded) {
        self.heightConstraint.constant = [self expandedPanelHeightForKeyboardOverlap:0];
        self.expandedView.hidden = NO;
        [self refresh];
    } else {
        self.heightConstraint.constant = 38;
        self.bottomConstraint.constant = -6;
        [self.composer resignFirstResponder];
    }
    void (^changes)(void) = ^{
        [self.superview layoutIfNeeded];
        self.collapsedView.alpha = expanded ? 0 : 1;
        self.expandedView.alpha = expanded ? 1 : 0;
    };
    void (^done)(BOOL) = ^(BOOL finished) {
        self.collapsedView.hidden = expanded;
        self.expandedView.hidden = !expanded;
        if (expanded) { [self.table reloadData]; [self scrollToBottomAnimated:NO]; }
    };
    if (animated) [UIView animateWithDuration:.28 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:changes completion:done];
    else { changes(); done(YES); }
}

- (void)keyboardWillChange:(NSNotification *)notification {
    if (!self.expanded) return;
    CGRect endFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboard = [self.superview convertRect:endFrame fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetHeight(self.superview.bounds) - CGRectGetMinY(keyboard));
    self.bottomConstraint.constant = overlap > 0 ? -(overlap - self.superview.safeAreaInsets.bottom + 6) : -6;
    self.heightConstraint.constant = [self expandedPanelHeightForKeyboardOverlap:overlap];
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationOptions options = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue] << 16;
    [UIView animateWithDuration:duration delay:0 options:options animations:^{ [self.superview layoutIfNeeded]; [self scrollToBottomAnimated:NO]; } completion:nil];
}

- (void)scrollToBottomAnimated:(BOOL)animated {
    // Scroll only to a row the table currently knows about: polls land
    // while the bar is collapsed and update messages without a reload, so
    // the newest message can be past the table's row count — and
    // scrollToRowAtIndexPath: throws for a row the table does not have.
    NSInteger rows = [self.table numberOfRowsInSection:0];
    if (rows == 0) return;
    NSInteger row = MIN((NSInteger)self.messages.count, rows - 1);
    [self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:animated];
}

- (void)request:(NSDictionary *)body completion:(void (^)(NSDictionary *, NSString *))completion {
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *error) {
        if (!token.length) { if (completion) completion(nil, NSLocalizedString(@"BRSlot.Lounge.SignIn", nil)); return; }
        NSURL *url = [NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/br-slot-social"]]; NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url]; request.HTTPMethod = @"POST"; request.timeoutInterval = 20; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"]; request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) { id rawJSON = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; NSDictionary *json = [rawJSON isKindOfClass:NSDictionary.class] ? rawJSON : nil; NSString *message = networkError.localizedDescription ?: BRChatString(json[@"error"]); dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(json, message); }); }] resume];
    }];
}

- (void)refresh { if (self.loading || !self.started) return; self.loading = YES; [self request:@{ @"action": @"room_state", @"room_id": self.roomID } completion:^(NSDictionary *json, NSString *error) { self.loading = NO; if (error || !json) { self.presenceLabel.text = @"● Lounge reconnecting…"; self.presenceLabel.textColor = UIColor.systemOrangeColor; if (!self.messages.count) self.latestLabel.text = @"● Lounge reconnecting…"; return; } NSDictionary *profile = [json[@"profile"] isKindOfClass:NSDictionary.class] ? json[@"profile"] : nil; self.hasProfile = profile != nil; self.profileName = BRChatString(profile[@"display_name"]); self.profileStatus = BRChatString(profile[@"status"]); self.musicEnabled = BRChatBool(profile[@"music_enabled"]); NSString *stateAvatarURL = BRChatString(profile[@"avatar_url"]); if (![BRChatAvatarIdentity(stateAvatarURL) isEqualToString:BRChatAvatarIdentity(self.profileAvatarURL)]) { self.profileAvatarURL = stateAvatarURL; [NSNotificationCenter.defaultCenter postNotificationName:BRSlotProfileDidUpdateNotification object:self]; } NSInteger active = BRChatInteger(json[@"active_players"]); self.presenceLabel.text = [NSString stringWithFormat:@"● %ld player%@ in the lounge", (long)active, active == 1 ? @"" : @"s"]; self.presenceLabel.textColor = [UIColor colorWithRed:.55 green:1 blue:.72 alpha:1]; BOOL nearBottom = YES; if (self.expanded && self.messages.count) { CGFloat distance = self.table.contentSize.height - (self.table.contentOffset.y + self.table.bounds.size.height); nearBottom = distance < 90; } self.messages = [json[@"messages"] isKindOfClass:NSArray.class] ? json[@"messages"] : @[]; [self updateLatestLine]; if (self.expanded) { [self.table reloadData]; if (nearBottom || self.justSent) [self scrollToBottomAnimated:NO]; if (!self.hasProfile) [self offerProfileSetup]; } self.justSent = NO; }]; }

- (void)updateLatestLine {
    NSDictionary *message = self.messages.lastObject;
    if (![message isKindOfClass:NSDictionary.class]) { self.latestLabel.text = self.presenceLabel.text; return; }
    NSString *name = BRChatString(message[@"display_name"]) ?: NSLocalizedString(@"BRSlot.Lounge.PlayerFallback", nil);
    NSString *body = BRChatString(message[@"body"]) ?: @"";
    if (BRChatBool(message[@"is_house_host"])) self.latestLabel.text = [NSString stringWithFormat:@"🎰 %@: %@", name, body];
    else self.latestLabel.text = [NSString stringWithFormat:@"%@: %@", name, body];
}

- (void)dismissComposerKeyboard { [self.composer resignFirstResponder]; }

- (void)send { NSString *message = self.composer.text; if (!message.length) return; if (!self.hasProfile) { [self offerProfileSetup]; return; } self.composer.text = @""; [self request:@{ @"action": @"send", @"room_id": self.roomID, @"message": message } completion:^(NSDictionary *json, NSString *error) { if (error) { self.composer.text = message; return; } self.justSent = YES; if ([self.roomID hasPrefix:@"bj:"]) [[NSNotificationCenter defaultCenter] postNotificationName:@"BRSlotChatMessageSentNotification" object:self.roomID]; [self refresh]; }]; }
- (void)requestLiveHostTurn { if ([self.roomID hasPrefix:@"bj:"]) return; if (self.loading || !self.started || self.hostViewController.presentedViewController) return; [self request:@{ @"action": @"host_turn", @"room_id": self.roomID } completion:^(NSDictionary *json, NSString *error) { if (!error && BRChatBool(json[@"posted"])) [self refresh]; }]; }
- (BOOL)textFieldShouldReturn:(UITextField *)textField { [self send]; return NO; }

- (void)offerProfileSetup { // No static "showing" flag: a swipe-dismissed sheet never ran the selection block, so the flag stuck and the prompt never appeared again. The presented controller is the guard — it clears itself on any dismissal.
    if (!self.hostViewController || self.hostViewController.presentedViewController) return; BRSlotChatPromptController *sheet = [BRSlotChatPromptController new]; sheet.promptTitle = @"Join the lounge"; sheet.promptBody = @"Choose a public display name. Your email and account details stay private."; sheet.initialText = @""; sheet.actions = @[@"Save Profile", @"Not Now"]; sheet.selection = ^(NSInteger action, NSString *text) { if (action == 0) [self saveProfileName:text music:NO]; }; [self.hostViewController presentViewController:sheet animated:YES completion:nil]; }
- (void)editProfile { if (!self.hostViewController) return; BRSlotChatPromptController *sheet = [BRSlotChatPromptController new]; sheet.promptTitle = @"Your lounge profile"; sheet.promptBody = @"Your profile is shown only in game lounges."; sheet.initialText = self.profileName ?: @""; sheet.initialStatus = self.profileStatus ?: @""; sheet.avatarImage = self.pendingAvatar; sheet.avatarURLString = self.pendingAvatar ? nil : self.profileAvatarURL; sheet.actions = @[@"Choose Photo", @"Save Profile", @"Cancel"]; __weak typeof(self) weakSelf = self; sheet.selectionWithStatus = ^(NSInteger action, NSString *text, NSString *status) { __strong typeof(weakSelf) self = weakSelf; if (!self) return; NSString *name = text.length ? text : (self.profileName ?: @"Player"); if (action == 0) { UIImagePickerController *picker = [UIImagePickerController new]; picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary; picker.delegate = self; [self.hostViewController presentViewController:picker animated:YES completion:nil]; } else if (action == 1) { [self saveProfileName:name status:status music:self.musicEnabled]; } }; [self.hostViewController presentViewController:sheet animated:YES completion:nil]; }
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info { self.pendingAvatar = info[UIImagePickerControllerOriginalImage]; [picker dismissViewControllerAnimated:YES completion:^{ [self editProfile]; }]; }
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker { [picker dismissViewControllerAnimated:YES completion:nil]; }
- (void)saveProfileName:(NSString *)name music:(BOOL)music { [self saveProfileName:name status:nil music:music]; }
- (void)saveProfileName:(NSString *)name status:(NSString *)status music:(BOOL)music { // A too-short name used to return silently, so the setup sheet was re-offered on every 6s poll until the user typed 2+ characters or tapped Not Now. Fall back to "Player" like the edit-profile path already does.
    if (name.length < 2) name = @"Player"; NSMutableDictionary *body = [@{ @"action": @"save_profile", @"display_name": name, @"music_enabled": @(music) } mutableCopy]; if (status) body[@"status"] = status; UIImage *avatar = BRChatScaledAvatar(self.pendingAvatar); NSData *image = avatar ? UIImageJPEGRepresentation(avatar, .78) : nil; if (image.length) body[@"avatar_b64"] = [image base64EncodedStringWithOptions:0]; [self request:body completion:^(NSDictionary *json, NSString *error) { if (!error) { self.pendingAvatar = nil; self.hasProfile = YES; NSDictionary *profile = [json[@"profile"] isKindOfClass:NSDictionary.class] ? json[@"profile"] : nil; if (profile) { self.profileName = BRChatString(profile[@"display_name"]); self.profileStatus = BRChatString(profile[@"status"]); NSString *savedAvatarURL = BRChatString(profile[@"avatar_url"]); if (![BRChatAvatarIdentity(savedAvatarURL) isEqualToString:BRChatAvatarIdentity(self.profileAvatarURL)]) self.profileAvatarURL = savedAvatarURL; [NSNotificationCenter.defaultCenter postNotificationName:BRSlotProfileDidUpdateNotification object:self]; } [self refresh]; } }]; }

- (void)showLeaderboard { [self request:@{ @"action": @"leaderboard" } completion:^(NSDictionary *json, NSString *error) { NSDictionary *board = [json[@"leaderboard"] isKindOfClass:NSDictionary.class] ? json[@"leaderboard"] : nil; if (error || !board) return; [self presentLeaderboard:board]; }]; }

- (void)showWinnersBoard { [self showLeaderboard]; }
+ (void)loadAvatarThumbnailForURL:(NSString *)urlString points:(CGFloat)points completion:(void (^)(UIImage *))completion {
    if (!completion) return;
    if (!urlString.length) { completion(nil); return; }
    NSString *key = [NSString stringWithFormat:@"%@|%.0f", urlString, points];
    UIImage *cached = [BRChatAvatarCache() objectForKey:key];
    if (cached) { completion(cached); return; }
    NSString *diskPath = BRChatAvatarDiskPathForKey(key);
    NSData *diskData = [NSData dataWithContentsOfFile:diskPath];
    if (diskData.length) {
        UIImage *diskImage = [UIImage imageWithData:diskData];
        if (diskImage) { [BRChatAvatarCache() setObject:diskImage forKey:key]; completion(diskImage); return; }
    }
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { completion(nil); return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = BRChatThumbnailFromData(data, points);
        if (image) {
            [BRChatAvatarCache() setObject:image forKey:key];
            NSData *jpeg = UIImageJPEGRepresentation(image, 0.85);
            if (jpeg.length) [jpeg writeToFile:diskPath atomically:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(image); });
    }] resume];
}
- (void)fetchOwnProfile { [self request:@{ @"action": @"profile" } completion:^(NSDictionary *json, NSString *error) { if (error || !json) return; NSDictionary *profile = [json[@"profile"] isKindOfClass:NSDictionary.class] ? json[@"profile"] : nil; if (!profile) return; self.hasProfile = YES; self.profileName = BRChatString(profile[@"display_name"]); self.profileStatus = BRChatString(profile[@"status"]); self.musicEnabled = BRChatBool(profile[@"music_enabled"]); NSInteger vipPoints = BRChatInteger(profile[@"vip_points"]); if (vipPoints != self.profileVipPoints) { self.profileVipPoints = vipPoints; [NSNotificationCenter.defaultCenter postNotificationName:BRSlotProfileDidUpdateNotification object:self]; } NSString *avatarURL = BRChatString(profile[@"avatar_url"]); if (![BRChatAvatarIdentity(avatarURL) isEqualToString:BRChatAvatarIdentity(self.profileAvatarURL)]) { self.profileAvatarURL = avatarURL; [NSNotificationCenter.defaultCenter postNotificationName:BRSlotProfileDidUpdateNotification object:self]; } }]; }
- (void)showProfileEditor {
    if (self.profileName.length) { [self editProfile]; return; }
    // A bar that never started (the game picker's logic owner) has not seen
    // the saved profile yet; load it once so the editor opens with the
    // current name instead of an empty field.
    [self request:@{ @"action": @"room_state", @"room_id": self.roomID } completion:^(NSDictionary *json, NSString *error) {
        NSDictionary *profile = [json[@"profile"] isKindOfClass:NSDictionary.class] ? json[@"profile"] : nil;
        if (!error && profile) { self.hasProfile = YES; self.profileName = BRChatString(profile[@"display_name"]); self.profileStatus = BRChatString(profile[@"status"]); self.musicEnabled = BRChatBool(profile[@"music_enabled"]); NSString *loadedAvatarURL = BRChatString(profile[@"avatar_url"]); if (![BRChatAvatarIdentity(loadedAvatarURL) isEqualToString:BRChatAvatarIdentity(self.profileAvatarURL)]) { self.profileAvatarURL = loadedAvatarURL; [NSNotificationCenter.defaultCenter postNotificationName:BRSlotProfileDidUpdateNotification object:self]; } }
        [self editProfile];
    }];
}
- (void)leaderboardRowTapped:(UITapGestureRecognizer *)tap {
    NSDictionary *row = objc_getAssociatedObject(tap.view, @"br_profileRow");
    if (![row isKindOfClass:NSDictionary.class]) return;
    BRSlotPlayerProfileController *profile = [BRSlotPlayerProfileController new];
    profile.modalPresentationStyle = UIModalPresentationFullScreen;
    profile.playerName = BRChatString(row[@"name"]) ?: NSLocalizedString(@"BRSlot.Lounge.PlayerFallback", nil);
    profile.avatarURLString = BRChatString(row[@"avatar_url"]);
    profile.statusText = BRChatString(row[@"status"]);
    profile.stats = row;
    UIViewController *presenter = self.hostViewController.presentedViewController ?: self.hostViewController;
    if (presenter) [presenter presentViewController:profile animated:YES completion:nil];
}
- (void)presentLeaderboard:(NSDictionary *)board {
    if (!self.hostViewController) return;
    UIViewController *sheet = [UIViewController new];
    sheet.view.backgroundColor = [UIColor colorWithRed:.055 green:.02 blue:.12 alpha:1];
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    sheet.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent largeDetent]];
    sheet.sheetPresentationController.prefersGrabberVisible = YES;
    UILabel *title = [UILabel new];
    title.text = NSLocalizedString(@"BRSlot.Lounge.WinningsTitle", nil);
    title.font = [UIFont systemFontOfSize:25 weight:UIFontWeightBlack];
    title.textColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [sheet.view addSubview:title];
    UILabel *mine = [UILabel new];
    mine.text = [NSString stringWithFormat:NSLocalizedString(@"BRSlot.Lounge.WinningsMine", nil), BRChatNumber(board[@"my_today_total"]), BRChatNumber(board[@"my_best_hit"])];
    if (board[@"my_alltime_total"]) mine.text = [mine.text stringByAppendingFormat:@"\n%@", [NSString stringWithFormat:NSLocalizedString(@"BRSlot.Lounge.WinningsMineAllTime", nil), BRChatNumber(board[@"my_alltime_total"])]];
    mine.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    mine.textColor = UIColor.whiteColor;
    mine.textAlignment = NSTextAlignmentCenter;
    mine.numberOfLines = 0;
    mine.translatesAutoresizingMaskIntoConstraints = NO;
    [sheet.view addSubview:mine];
    UIScrollView *scroll = [UIScrollView new];
    scroll.backgroundColor = [UIColor colorWithWhite:1 alpha:.06];
    scroll.layer.cornerRadius = 16;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [sheet.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    NSString *(^trimmed)(NSString *) = ^NSString *(NSString *value) { return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; };
    void (^addHeader)(NSString *) = ^(NSString *key) {
        UILabel *header = [UILabel new];
        header.text = trimmed(NSLocalizedString(key, nil));
        header.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBlack];
        header.textColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];
        [stack addArrangedSubview:header];
    };
    void (^addEmpty)(NSString *) = ^(NSString *key) {
        UILabel *empty = [UILabel new];
        empty.text = trimmed(NSLocalizedString(key, nil));
        empty.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        empty.textColor = [UIColor colorWithWhite:.75 alpha:1];
        empty.numberOfLines = 0;
        [stack addArrangedSubview:empty];
    };
    void (^addRow)(NSDictionary *, NSUInteger, NSString *) = ^(NSDictionary *entry, NSUInteger index, NSString *amountKey) {
        NSDictionary *row = BRChatDictionary(entry);
        UIView *line = [UIView new];
        UIImageView *avatar = [UIImageView new];
        avatar.image = [UIImage systemImageNamed:@"person.crop.circle.fill"];
        avatar.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1];
        avatar.contentMode = UIViewContentModeScaleAspectFill;
        avatar.clipsToBounds = YES;
        avatar.layer.cornerRadius = 38;
        avatar.layer.borderWidth = 2;
        avatar.layer.borderColor = [UIColor colorWithRed:1 green:.75 blue:.18 alpha:.62].CGColor;
        avatar.backgroundColor = [UIColor colorWithWhite:1 alpha:.07];
        avatar.translatesAutoresizingMaskIntoConstraints = NO;
        [line addSubview:avatar];
        UILabel *label = [UILabel new];
        label.text = trimmed([NSString stringWithFormat:NSLocalizedString(@"BRSlot.Lounge.WinningsRow", nil), (unsigned long)index + 1, BRChatString(row[@"name"]) ?: NSLocalizedString(@"BRSlot.Lounge.PlayerFallback", nil), BRChatNumber(row[amountKey])]);
        label.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightSemibold];
        label.textColor = UIColor.whiteColor;
        label.numberOfLines = 0;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [line addSubview:label];
        // Big rows: a 76pt avatar plus padding makes each entry ~92pt
        // tall, so about 6-7 entries fill the screen and the rest of
        // the board is reached by scrolling, as requested.
        [NSLayoutConstraint activateConstraints:@[
            [avatar.leadingAnchor constraintEqualToAnchor:line.leadingAnchor],
            [avatar.topAnchor constraintEqualToAnchor:line.topAnchor constant:8],
            [avatar.bottomAnchor constraintEqualToAnchor:line.bottomAnchor constant:-8],
            [avatar.widthAnchor constraintEqualToConstant:76],
            [avatar.heightAnchor constraintEqualToConstant:76],
            [label.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:14],
            [label.trailingAnchor constraintEqualToAnchor:line.trailingAnchor],
            [label.centerYAnchor constraintEqualToAnchor:line.centerYAnchor]]];
        [stack addArrangedSubview:line];
        NSString *avatarURL = BRChatString(row[@"avatar_url"]);
        line.userInteractionEnabled = YES;
        objc_setAssociatedObject(line, @"br_profileRow", entry, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [line addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(leaderboardRowTapped:)]];
        if (avatarURL.length) { __weak UIImageView *weakAvatar = avatar; [BRSlotChatBar loadAvatarThumbnailForURL:avatarURL points:76 completion:^(UIImage *image) { if (image) weakAvatar.image = image; }]; }
    };
    void (^addSection)(NSString *, NSArray *, NSString *, NSString *) = ^(NSString *headerKey, NSArray *entries, NSString *amountKey, NSString *emptyKey) {
        if (stack.arrangedSubviews.count) {
            UIView *spacer = [UIView new];
            spacer.translatesAutoresizingMaskIntoConstraints = NO;
            [spacer.heightAnchor constraintEqualToConstant:10].active = YES;
            [stack addArrangedSubview:spacer];
        }
        addHeader(headerKey);
        NSArray *rows = [entries isKindOfClass:NSArray.class] ? entries : @[];
        if (!rows.count) { addEmpty(emptyKey); return; }
        [rows enumerateObjectsUsingBlock:^(NSDictionary *entry, NSUInteger i, BOOL *stop) { addRow(entry, i, amountKey); }];
    };
    addSection(@"BRSlot.Lounge.WinningsTopTotals", board[@"daily_winnings"], @"total", @"BRSlot.Lounge.WinningsNoWins");
    addSection(@"BRSlot.Lounge.WinningsBiggestHits", board[@"biggest_hits"], @"payout", @"BRSlot.Lounge.WinningsNoHits");
    addSection(@"BRSlot.Lounge.WinningsAllTime", board[@"all_time_winnings"], @"total", @"BRSlot.Lounge.WinningsNoAllTime");
    NSArray *chips = [board[@"top_chips"] isKindOfClass:NSArray.class] ? board[@"top_chips"] : @[];
    if (chips.count > 5) chips = [chips subarrayWithRange:NSMakeRange(0, 5)];
    addSection(@"BRSlot.Lounge.WinningsMostChips", chips, @"balance", @"BRSlot.Lounge.WinningsNoChips");
    addSection(@"BRSlot.Lounge.BlackjackTop", board[@"blackjack"], @"bj_won", @"BRSlot.Lounge.BlackjackNone");
    addSection(@"BRSlot.Lounge.BlackjackHandsTop", board[@"blackjack_hands"], @"bj_hands", @"BRSlot.Lounge.BlackjackNone");
    addSection(@"BRSlot.Lounge.BlackjackCoinsTop", board[@"blackjack_coins"], @"bj_total_won", @"BRSlot.Lounge.BlackjackNone");
    UILabel *footer = [UILabel new];
    footer.text = trimmed(NSLocalizedString(@"BRSlot.Lounge.WinningsFooter", nil));
    footer.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    footer.textColor = [UIColor colorWithWhite:.6 alpha:1];
    footer.textAlignment = NSTextAlignmentCenter;
    footer.numberOfLines = 0;
    [stack addArrangedSubview:footer];
    UILayoutGuide *safe = sheet.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:28],
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [mine.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [mine.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [mine.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:mine.bottomAnchor constant:20],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-18],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-14],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-14],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-28]]];
    [self.hostViewController presentViewController:sheet animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.messages.count + 1; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath { if (indexPath.row == 0) { UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]; cell.backgroundColor = [UIColor colorWithRed:.30 green:.08 blue:.42 alpha:.55]; BOOL blackjackRoom = [self.roomID hasPrefix:@"bj:"]; cell.textLabel.text = blackjackRoom ? @"🃏 Lucky Lou · Your dealer" : @"🎰 Cherry Queen · Live house host"; cell.textLabel.textColor = [UIColor colorWithRed:1 green:.79 blue:.25 alpha:1]; cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBlack]; cell.detailTextLabel.text = blackjackRoom ? @"Your AI dealer. Chat with the table between hands, and play responsibly." : @"A room character who keeps the lounge welcoming. Spin responsibly and celebrate each other."; cell.detailTextLabel.textColor = [UIColor colorWithWhite:.78 alpha:1]; cell.detailTextLabel.numberOfLines = 0; return cell; } NSDictionary *message = BRChatDictionary(self.messages[indexPath.row - 1]); UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]; BOOL mine = BRChatBool(message[@"is_mine"]); BOOL host = BRChatBool(message[@"is_house_host"]); cell.backgroundColor = host ? [UIColor colorWithRed:.30 green:.08 blue:.42 alpha:.55] : (mine ? [UIColor colorWithRed:.22 green:.10 blue:.39 alpha:.65] : [UIColor colorWithWhite:1 alpha:.055]); cell.layer.cornerRadius = 12; NSString *displayName = BRChatString(message[@"display_name"]) ?: (host ? ([self.roomID hasPrefix:@"bj:"] ? @"Lucky Lou" : @"Cherry Queen") : @"Player"); cell.textLabel.text = host ? [NSString stringWithFormat:([self.roomID hasPrefix:@"bj:"] ? @"🃏 %@ · Dealer" : @"🎰 %@ · Live house host"), displayName] : displayName; cell.textLabel.textColor = (mine || host) ? [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1] : UIColor.whiteColor; cell.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBlack]; cell.detailTextLabel.text = BRChatString(message[@"body"]) ?: @""; cell.detailTextLabel.textColor = [UIColor colorWithWhite:.83 alpha:1]; cell.detailTextLabel.numberOfLines = 0; cell.imageView.image = host ? [UIImage systemImageNamed:@"sparkles"] : [UIImage systemImageNamed:@"person.crop.circle.fill"]; cell.imageView.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1]; cell.imageView.layer.cornerRadius = 17; cell.imageView.clipsToBounds = YES; NSString *avatarURL = BRChatString(message[@"avatar_url"]); if (!host && avatarURL.length) { __weak UITableViewCell *weakCell = cell; [BRSlotChatBar loadAvatarThumbnailForURL:avatarURL points:34 completion:^(UIImage *image) { if (!image) return; weakCell.imageView.image = image; weakCell.imageView.contentMode = UIViewContentModeScaleAspectFill; }]; } return cell; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return indexPath.row == 0 ? 62 : UITableViewAutomaticDimension; }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    if (indexPath.row == 0) return [UISwipeActionsConfiguration configurationWithActions:@[]];
    NSDictionary *message = BRChatDictionary(self.messages[indexPath.row - 1]);
    if (!BRChatBool(message[@"is_mine"]) || BRChatBool(message[@"is_house_host"])) return [UISwipeActionsConfiguration configurationWithActions:@[]];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:NSLocalizedString(@"BRSlot.Lounge.Delete", nil) handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        [weakSelf request:@{ @"action": @"delete_own_message", @"room_id": weakSelf.roomID, @"message_id": message[@"id"] } completion:^(__unused NSDictionary *json, NSString *error) { completionHandler(error == nil); if (!error) [weakSelf refresh]; }];
    }];
    remove.backgroundColor = [UIColor colorWithRed:.72 green:.12 blue:.22 alpha:1];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}
@end

#pragma mark - Big win celebration

/// Fireworks + coin-volcano celebration for huge wins, shared by every
/// slot machine. All artwork is drawn in code at runtime (no image
/// assets): gold coins for the volcano, stars and sparks for the
/// fireworks. The overlay never takes touches and removes itself.

#pragma mark - Shared slot chrome

// Distance from the centre of rect to its edge along angle a — the base
// radius the sun rays alternate around.
static CGFloat BRSRayBaseRadius(CGRect rect, CGFloat a) {
    CGFloat hw = CGRectGetWidth(rect) / 2, hh = CGRectGetHeight(rect) / 2;
    CGFloat c = fabs(cos(a)), s = fabs(sin(a));
    CGFloat rx = c > 0.0001 ? hw / c : CGFLOAT_MAX;
    CGFloat ry = s > 0.0001 ? hh / s : CGFLOAT_MAX;
    return MIN(rx, ry);
}

@interface BRSlotWinBannerView : UIView
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle;
@end

@implementation BRSlotWinBannerView {
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
}

- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = NO;
    self.layer.shadowColor = [UIColor colorWithRed:1 green:.78 blue:.10 alpha:1].CGColor;
    self.layer.shadowOpacity = .45;
    self.layer.shadowRadius = 14;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    _titleLabel = [UILabel new];
    _titleLabel.text = title;
    _titleLabel.font = [UIFont systemFontOfSize:29 weight:UIFontWeightBlack];
    _titleLabel.textColor = [UIColor colorWithRed:1 green:.80 blue:.15 alpha:1];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = .6;
    _titleLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    _titleLabel.layer.shadowOpacity = .55;
    _titleLabel.layer.shadowRadius = 4;
    _titleLabel.layer.shadowOffset = CGSizeMake(0, 2);
    [self addSubview:_titleLabel];
    _subtitleLabel = [UILabel new];
    _subtitleLabel.text = subtitle;
    _subtitleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightHeavy];
    _subtitleLabel.textColor = UIColor.whiteColor;
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    _subtitleLabel.adjustsFontSizeToFitWidth = YES;
    _subtitleLabel.minimumScaleFactor = .6;
    _subtitleLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    _subtitleLabel.layer.shadowOpacity = .5;
    _subtitleLabel.layer.shadowRadius = 3;
    _subtitleLabel.layer.shadowOffset = CGSizeMake(0, 1);
    [self addSubview:_subtitleLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat ray = 12;
    _titleLabel.frame = CGRectMake(ray + 10, ray + 8, w - 2 * (ray + 10), 36);
    _subtitleLabel.frame = CGRectMake(ray + 10, CGRectGetMaxY(_titleLabel.frame) + 2, w - 2 * (ray + 10), 24);
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, ray, ray) cornerRadius:16].CGPath;
    [self setNeedsDisplay];
}


- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat ray = 12;
    CGRect card = CGRectInset(self.bounds, ray, ray);
    CGPoint centre = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    // Sun-ray burst: a jagged gold edge all the way around the card.
    NSInteger teeth = 56;
    UIBezierPath *burst = [UIBezierPath bezierPath];
    for (NSInteger i = 0; i <= teeth * 2; i++) {
        CGFloat a = (CGFloat)i / (CGFloat)(teeth * 2) * (CGFloat)(2 * M_PI);
        CGFloat base = BRSRayBaseRadius(card, a) + 2;
        CGFloat r = (i % 2 == 0) ? base + ray : base;
        CGPoint pt = CGPointMake(centre.x + r * (CGFloat)cos(a), centre.y + r * (CGFloat)sin(a));
        if (i == 0) [burst moveToPoint:pt]; else [burst addLineToPoint:pt];
    }
    [burst closePath];
    CGContextSaveGState(ctx);
    [burst addClip];
    CGGradientRef gold = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)@[
        (id)[UIColor colorWithRed:1 green:.88 blue:.35 alpha:1].CGColor,
        (id)[UIColor colorWithRed:.85 green:.58 blue:.05 alpha:1].CGColor], (CGFloat[]){0, 1});
    CGContextDrawRadialGradient(ctx, gold, centre, 0, centre, CGRectGetWidth(self.bounds) * .62, 0);
    CGGradientRelease(gold);
    CGContextRestoreGState(ctx);
    // Card: deep vertical gradient, a glass gloss over the top half, gold rim.
    UIBezierPath *cardPath = [UIBezierPath bezierPathWithRoundedRect:card cornerRadius:16];
    CGContextSaveGState(ctx);
    [cardPath addClip];
    CGGradientRef fill = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)@[
        (id)[UIColor colorWithRed:.16 green:.05 blue:.32 alpha:.98].CGColor,
        (id)[UIColor colorWithRed:.05 green:.02 blue:.13 alpha:.98].CGColor], (CGFloat[]){0, 1});
    CGContextDrawLinearGradient(ctx, fill, CGPointMake(0, CGRectGetMinY(card)), CGPointMake(0, CGRectGetMaxY(card)), 0);
    CGGradientRelease(fill);
    CGGradientRef gloss = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)@[
        (id)[UIColor colorWithWhite:1 alpha:.20].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:0].CGColor], (CGFloat[]){0, 1});
    CGContextDrawLinearGradient(ctx, gloss, CGPointMake(0, CGRectGetMinY(card)), CGPointMake(0, CGRectGetMinY(card) + card.size.height * .5), 0);
    CGGradientRelease(gloss);
    CGContextRestoreGState(ctx);
    cardPath.lineWidth = 2;
    [[UIColor colorWithRed:1 green:.78 blue:.18 alpha:.95] setStroke];
    [cardPath stroke];
}

@end

@implementation BRSlotChrome

+ (CGFloat)winBannerHeight { return 108; }

+ (UIView *)winBannerWithTitle:(NSString *)title subtitle:(NSString *)subtitle width:(CGFloat)width {
    BRSlotWinBannerView *banner = [[BRSlotWinBannerView alloc] initWithTitle:title ?: @"" subtitle:subtitle ?: @""];
    banner.frame = CGRectMake(0, 0, width, [self winBannerHeight]);
    return banner;
}

+ (UIImage *)brs_gradientImageWithBaseColor:(UIColor *)baseColor highlighted:(BOOL)highlighted {
    CGSize size = CGSizeMake(120, 44);
    CGFloat hue = 0, saturation = 0, brightness = 0, alpha = 1;
    [baseColor getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
    UIColor *top = [UIColor colorWithHue:hue saturation:MAX(0, saturation - .06) brightness:MIN(1, MAX(0, brightness + (highlighted ? -.06 : .20))) alpha:1];
    UIColor *bottom = [UIColor colorWithHue:hue saturation:saturation brightness:MAX(0, brightness - (highlighted ? .20 : .12)) alpha:1];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat new];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef c = context.CGContext;
        // Rounded corners are baked into the image so the button's drop
        // shadow follows the same silhouette.
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:13] addClip];
        CGGradientRef gradient = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)@[(id)top.CGColor, (id)baseColor.CGColor, (id)bottom.CGColor], (CGFloat[]){0, .55, 1});
        CGContextDrawLinearGradient(c, gradient, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
        CGGradientRelease(gradient);
        CGGradientRef gloss = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)@[(id)[UIColor colorWithWhite:1 alpha:.30].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor], (CGFloat[]){0, 1});
        CGContextDrawLinearGradient(c, gloss, CGPointMake(0, 0), CGPointMake(0, size.height * .55), 0);
        CGGradientRelease(gloss);
        [[UIColor colorWithWhite:1 alpha:.45] setFill];
        CGContextFillRect(c, CGRectMake(0, 0, size.width, 1));
    }];
}

+ (void)applyToButton:(UIButton *)button baseColor:(UIColor *)baseColor {
    if (!button || !baseColor) return;
    UIImage *normal = [[self brs_gradientImageWithBaseColor:baseColor highlighted:NO] resizableImageWithCapInsets:UIEdgeInsetsMake(12, 12, 12, 12) resizingMode:UIImageResizingModeStretch];
    UIImage *pressed = [[self brs_gradientImageWithBaseColor:baseColor highlighted:YES] resizableImageWithCapInsets:UIEdgeInsetsMake(12, 12, 12, 12) resizingMode:UIImageResizingModeStretch];
    [button setBackgroundImage:normal forState:UIControlStateNormal];
    [button setBackgroundImage:pressed forState:UIControlStateHighlighted];
    button.backgroundColor = UIColor.clearColor;
    button.layer.cornerRadius = 13;
    button.layer.borderWidth = 1.5;
    button.layer.borderColor = [UIColor colorWithRed:1 green:.78 blue:.18 alpha:.85].CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = .35;
    button.layer.shadowRadius = 6;
    button.layer.shadowOffset = CGSizeMake(0, 3);
    button.clipsToBounds = NO;
}

@end

@implementation BRSlotCelebration

+ (UIImage *)brs_coinImage {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGSize size = CGSizeMake(30, 30);
        image = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
            CGRect bounds = CGRectMake(0, 0, size.width, size.height);
            [[UIColor colorWithRed:0.72 green:0.48 blue:0.04 alpha:1] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:bounds] fill];
            [[UIColor colorWithRed:1.00 green:0.78 blue:0.10 alpha:1] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(bounds, 2.5, 2.5)] fill];
            [[UIColor colorWithRed:1.00 green:0.92 blue:0.50 alpha:1] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(bounds, 6.5, 6.5)] fill];
        }];
    });
    return image;
}

+ (UIImage *)brs_starImage {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGSize size = CGSizeMake(24, 24);
        image = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
            UIBezierPath *star = [UIBezierPath bezierPath];
            CGFloat cx = 12, cy = 12, rOuter = 11, rInner = 4.6;
            for (NSInteger i = 0; i < 10; i++) {
                CGFloat r = (i % 2 == 0) ? rOuter : rInner;
                CGFloat a = (CGFloat)(-M_PI_2 + i * M_PI / 5);
                CGPoint pt = CGPointMake(cx + r * (CGFloat)cos(a), cy + r * (CGFloat)sin(a));
                if (i == 0) [star moveToPoint:pt]; else [star addLineToPoint:pt];
            }
            [star closePath];
            [[UIColor colorWithRed:1.00 green:0.85 blue:0.25 alpha:1] setFill];
            [star fill];
        }];
    });
    return image;
}

+ (UIImage *)brs_sparkImage {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGSize size = CGSizeMake(10, 10);
        image = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull ctx) {
            [[UIColor whiteColor] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, size.width, size.height)] fill];
        }];
    });
    return image;
}

+ (CAEmitterLayer *)brs_fireworkAt:(CGPoint)position {
    CAEmitterLayer *layer = [CAEmitterLayer layer];
    layer.emitterPosition = position;
    layer.emitterShape = kCAEmitterLayerPoint;
    layer.renderMode = kCAEmitterLayerAdditive;
    CAEmitterCell *star = [CAEmitterCell emitterCell];
    star.contents = (id)[self brs_starImage].CGImage;
    star.birthRate = 90;
    star.lifetime = 1.4;
    star.lifetimeRange = 0.4;
    star.velocity = 230;
    star.velocityRange = 90;
    star.emissionRange = (CGFloat)(2 * M_PI);
    star.yAcceleration = 150;
    star.scale = 0.55;
    star.scaleRange = 0.25;
    star.alphaSpeed = -0.7;
    star.spin = 2;
    star.spinRange = 4;
    CAEmitterCell *spark = [CAEmitterCell emitterCell];
    spark.contents = (id)[self brs_sparkImage].CGImage;
    spark.birthRate = 150;
    spark.lifetime = 1.1;
    spark.lifetimeRange = 0.3;
    spark.velocity = 285;
    spark.velocityRange = 120;
    spark.emissionRange = (CGFloat)(2 * M_PI);
    spark.yAcceleration = 170;
    spark.scale = 0.5;
    spark.scaleRange = 0.2;
    spark.alphaSpeed = -0.9;
    spark.color = [UIColor colorWithRed:1.00 green:0.80 blue:0.30 alpha:1].CGColor;
    layer.emitterCells = @[star, spark];
    return layer;
}

+ (CAEmitterLayer *)brs_coinVolcanoAt:(CGPoint)position width:(CGFloat)width mega:(BOOL)mega {
    CAEmitterLayer *layer = [CAEmitterLayer layer];
    layer.emitterPosition = position;
    layer.emitterShape = kCAEmitterLayerLine;
    layer.emitterSize = CGSizeMake(width, 1);
    layer.emitterMode = kCAEmitterLayerOutline;
    CAEmitterCell *coin = [CAEmitterCell emitterCell];
    coin.contents = (id)[self brs_coinImage].CGImage;
    coin.birthRate = mega ? 170 : 120;
    coin.lifetime = 2.6;
    coin.lifetimeRange = 0.5;
    coin.velocity = 560;
    coin.velocityRange = 150;
    coin.emissionLongitude = (CGFloat)(-M_PI_2);
    coin.emissionRange = 0.45;
    coin.yAcceleration = 980;
    coin.spin = 3;
    coin.spinRange = 7;
    coin.scale = 0.8;
    coin.scaleRange = 0.35;
    layer.emitterCells = @[coin];
    return layer;
}

+ (BOOL)celebrateBigWinInView:(UIView *)hostView payout:(NSInteger)payout totalBet:(NSInteger)totalBet {
    if (!hostView || totalBet <= 0 || payout <= 0) return NO;
    NSInteger multiple = payout / totalBet;
    if (multiple < 25) return NO;
    BOOL mega = multiple >= 75;

    UIView *overlay = [[UIView alloc] initWithFrame:hostView.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.userInteractionEnabled = NO;
    overlay.backgroundColor = UIColor.clearColor;
    [hostView addSubview:overlay];
    CGSize size = overlay.bounds.size;
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();

    if (!reduceMotion) {
        CAEmitterLayer *volcano = [self brs_coinVolcanoAt:CGPointMake(size.width / 2, size.height * 0.97)
                                                    width:MIN(150, size.width * 0.42) mega:mega];
        [overlay.layer addSublayer:volcano];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((mega ? 2.4 : 1.6) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            volcano.birthRate = 0;
        });
        NSArray<NSValue *> *spots = mega
            ? @[[NSValue valueWithCGPoint:CGPointMake(0.16, 0.20)], [NSValue valueWithCGPoint:CGPointMake(0.38, 0.12)],
                [NSValue valueWithCGPoint:CGPointMake(0.62, 0.22)], [NSValue valueWithCGPoint:CGPointMake(0.84, 0.13)],
                [NSValue valueWithCGPoint:CGPointMake(0.50, 0.30)]]
            : @[[NSValue valueWithCGPoint:CGPointMake(0.22, 0.18)], [NSValue valueWithCGPoint:CGPointMake(0.52, 0.11)],
                [NSValue valueWithCGPoint:CGPointMake(0.80, 0.19)]];
        [spots enumerateObjectsUsingBlock:^(NSValue *value, NSUInteger idx, BOOL *stop) {
            CGPoint fraction = value.CGPointValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(idx * 0.28 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!overlay.superview) return;
                CAEmitterLayer *burst = [self brs_fireworkAt:CGPointMake(size.width * fraction.x, size.height * fraction.y)];
                [overlay.layer addSublayer:burst];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    burst.birthRate = 0;
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [burst removeFromSuperlayer];
                });
            });
        }];
    }

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, size.width - 32, mega ? 74 : 60)];
    title.text = mega ? NSLocalizedStringWithDefaultValue(@"BRSlot.Win.Jackpot", nil, NSBundle.mainBundle, @"JACKPOT!", nil)
                      : NSLocalizedString(@"BRSlot.Win.BigWin", nil);
    title.font = [UIFont systemFontOfSize:mega ? 58 : 46 weight:UIFontWeightBlack];
    title.textColor = [UIColor colorWithRed:1.00 green:0.80 blue:0.15 alpha:1];
    title.textAlignment = NSTextAlignmentCenter;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.6;
    title.layer.shadowColor = UIColor.blackColor.CGColor;
    title.layer.shadowOpacity = 0.5;
    title.layer.shadowRadius = 7;
    title.layer.shadowOffset = CGSizeMake(0, 3);
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(16, CGRectGetMaxY(title.frame) + 2, size.width - 32, 30)];
    sub.text = [NSString stringWithFormat:NSLocalizedString(@"BRSlot.Win.BigWinSub", nil), (long)payout, (long)multiple];
    sub.font = [UIFont systemFontOfSize:21 weight:UIFontWeightHeavy];
    sub.textColor = UIColor.whiteColor;
    sub.textAlignment = NSTextAlignmentCenter;
    sub.adjustsFontSizeToFitWidth = YES;
    sub.minimumScaleFactor = 0.6;
    sub.layer.shadowColor = UIColor.blackColor.CGColor;
    sub.layer.shadowOpacity = 0.5;
    sub.layer.shadowRadius = 5;
    sub.layer.shadowOffset = CGSizeMake(0, 2);
    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(0, size.height * 0.30, size.width, CGRectGetMaxY(sub.frame))];
    banner.userInteractionEnabled = NO;
    [banner addSubview:title];
    [banner addSubview:sub];
    banner.transform = CGAffineTransformMakeScale(0.3, 0.3);
    banner.alpha = 0;
    [overlay addSubview:banner];
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.8 options:0 animations:^{
        banner.transform = CGAffineTransformIdentity;
        banner.alpha = 1;
    } completion:nil];

    NSTimeInterval total = reduceMotion ? 1.8 : (mega ? 5.6 : 4.2);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(total * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.35 animations:^{ overlay.alpha = 0; } completion:^(BOOL finished) {
            [overlay removeFromSuperview];
        }];
    });
    return YES;
}

@end
