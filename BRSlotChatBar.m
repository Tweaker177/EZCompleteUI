#import "BRSlotChatBar.h"
#import "EZAuthManager.h"
#import "EZSupabaseConfig.h"

@interface BRSlotChatPromptController : UIViewController
@property (nonatomic, copy) NSString *promptTitle, *promptBody, *initialText;
@property (nonatomic, copy) NSArray<NSString *> *actions;
@property (nonatomic, copy) void (^selection)(NSInteger action, NSString *text);
@property (nonatomic, strong) UITextField *textField;
@end

@implementation BRSlotChatPromptController
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor = [UIColor colorWithRed:.055 green:.02 blue:.12 alpha:1]; self.modalPresentationStyle = UIModalPresentationPageSheet; self.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent mediumDetent]]; self.sheetPresentationController.prefersGrabberVisible = YES; self.sheetPresentationController.preferredCornerRadius = 25;
    UIView *card = [UIView new]; card.backgroundColor = [UIColor colorWithRed:.13 green:.045 blue:.23 alpha:1]; card.layer.cornerRadius = 22; card.layer.borderWidth = 1; card.layer.borderColor = [UIColor colorWithRed:1 green:.75 blue:.18 alpha:.62].CGColor; card.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:card];
    UILabel *title = [UILabel new]; title.text = self.promptTitle; title.textColor = UIColor.whiteColor; title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBlack]; title.numberOfLines = 2; title.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:title];
    UILabel *body = [UILabel new]; body.text = self.promptBody; body.textColor = [UIColor colorWithWhite:.73 alpha:1]; body.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium]; body.numberOfLines = 0; body.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:body];
    self.textField = [UITextField new]; self.textField.text = self.initialText; self.textField.placeholder = NSLocalizedString(@"BRSlot.Lounge.DisplayName", nil); self.textField.textColor = UIColor.whiteColor; self.textField.backgroundColor = [UIColor colorWithWhite:1 alpha:.09]; self.textField.layer.cornerRadius = 12; self.textField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,12,1)]; self.textField.leftViewMode = UITextFieldViewModeAlways; self.textField.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:self.textField]; self.textField.hidden = !self.initialText;
    UIStackView *buttons = [UIStackView new]; buttons.axis = UILayoutConstraintAxisVertical; buttons.spacing = 9; buttons.translatesAutoresizingMaskIntoConstraints = NO; [card addSubview:buttons]; [self.actions enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *stop) { UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:name forState:UIControlStateNormal]; [b setTitleColor:index == self.actions.count - 1 ? [UIColor colorWithWhite:.72 alpha:1] : UIColor.whiteColor forState:UIControlStateNormal]; b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBlack]; b.backgroundColor = index == self.actions.count - 1 ? [UIColor colorWithWhite:1 alpha:.07] : [UIColor colorWithRed:.58 green:.12 blue:.42 alpha:1]; b.layer.cornerRadius = 12; b.tag = index; [b addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside]; [buttons addArrangedSubview:b]; [b.heightAnchor constraintEqualToConstant:43].active = YES; }];
    [NSLayoutConstraint activateConstraints:@[[card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:18], [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-18], [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor], [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:22], [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20], [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20], [body.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:7], [body.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [body.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [self.textField.topAnchor constraintEqualToAnchor:body.bottomAnchor constant:16], [self.textField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [self.textField.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [self.textField.heightAnchor constraintEqualToConstant:46], [buttons.topAnchor constraintEqualToAnchor:self.textField.hidden ? body.bottomAnchor : self.textField.bottomAnchor constant:18], [buttons.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [buttons.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [buttons.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20]]]; }
- (void)tapped:(UIButton *)sender { NSString *text = self.textField.text ?: @""; NSInteger action = sender.tag; [self dismissViewControllerAnimated:YES completion:^{ if (self.selection) self.selection(action, text); }]; }
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
    // Header: presence on the left; winners board, profile, collapse on the right.
    self.presenceLabel = [UILabel new]; self.presenceLabel.text = NSLocalizedString(@"BRSlot.Lounge.Connecting", nil); self.presenceLabel.textColor = [UIColor colorWithRed:.55 green:1 blue:.72 alpha:1]; self.presenceLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightBold]; self.presenceLabel.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:self.presenceLabel];
    UIButton *wins = [UIButton buttonWithType:UIButtonTypeSystem]; [wins setTitle:NSLocalizedString(@"BRSlot.Lounge.Wins", nil) forState:UIControlStateNormal]; wins.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBlack]; wins.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1]; [wins addTarget:self action:@selector(showLeaderboard) forControlEvents:UIControlEventTouchUpInside]; wins.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:wins];
    UIButton *profile = [UIButton buttonWithType:UIButtonTypeSystem]; [profile setImage:[UIImage systemImageNamed:@"person.crop.circle"] forState:UIControlStateNormal]; profile.tintColor = [UIColor colorWithRed:1 green:.78 blue:.22 alpha:1]; [profile addTarget:self action:@selector(editProfile) forControlEvents:UIControlEventTouchUpInside]; profile.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:profile];
    UIButton *collapse = [UIButton buttonWithType:UIButtonTypeSystem]; [collapse setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal]; collapse.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1]; [collapse addTarget:self action:@selector(collapseTapped) forControlEvents:UIControlEventTouchUpInside]; collapse.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:collapse];
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain]; self.table.backgroundColor = UIColor.clearColor; self.table.separatorStyle = UITableViewCellSeparatorStyleNone; self.table.dataSource = self; self.table.delegate = self; self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive; self.table.estimatedRowHeight = 56; self.table.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:self.table];
    UILabel *note = [UILabel new]; note.text = NSLocalizedString(@"BRSlot.Lounge.Note", nil); note.numberOfLines = 2; note.textAlignment = NSTextAlignmentCenter; note.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium]; note.textColor = [UIColor colorWithWhite:.56 alpha:1]; note.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:note];
    UIView *bar = [UIView new]; bar.backgroundColor = [UIColor colorWithWhite:1 alpha:.08]; bar.layer.cornerRadius = 18; bar.translatesAutoresizingMaskIntoConstraints = NO; [self.expandedView addSubview:bar];
    self.composer = [UITextField new]; self.composer.placeholder = NSLocalizedString(@"BRSlot.Lounge.Composer", nil); self.composer.textColor = UIColor.whiteColor; self.composer.attributedPlaceholder = [[NSAttributedString alloc] initWithString:self.composer.placeholder attributes:@{NSForegroundColorAttributeName:[UIColor colorWithWhite:.62 alpha:1]}]; self.composer.delegate = self; self.composer.returnKeyType = UIReturnKeySend; self.composer.translatesAutoresizingMaskIntoConstraints = NO; [bar addSubview:self.composer];
    UIButton *send = [UIButton buttonWithType:UIButtonTypeSystem]; [send setImage:[UIImage systemImageNamed:@"paperplane.fill"] forState:UIControlStateNormal]; send.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1]; [send addTarget:self action:@selector(send) forControlEvents:UIControlEventTouchUpInside]; send.translatesAutoresizingMaskIntoConstraints = NO; [bar addSubview:send];
    [NSLayoutConstraint activateConstraints:@[
        [self.expandedView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.expandedView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.expandedView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.expandedView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.presenceLabel.topAnchor constraintEqualToAnchor:self.expandedView.topAnchor constant:9],
        [self.presenceLabel.leadingAnchor constraintEqualToAnchor:self.expandedView.leadingAnchor constant:12],
        [self.presenceLabel.trailingAnchor constraintLessThanOrEqualToAnchor:wins.leadingAnchor constant:-8],
        [collapse.trailingAnchor constraintEqualToAnchor:self.expandedView.trailingAnchor constant:-8],
        [collapse.centerYAnchor constraintEqualToAnchor:self.presenceLabel.centerYAnchor],
        [collapse.widthAnchor constraintEqualToConstant:30], [collapse.heightAnchor constraintEqualToConstant:26],
        [profile.trailingAnchor constraintEqualToAnchor:collapse.leadingAnchor constant:-4],
        [profile.centerYAnchor constraintEqualToAnchor:self.presenceLabel.centerYAnchor],
        [profile.widthAnchor constraintEqualToConstant:30], [profile.heightAnchor constraintEqualToConstant:26],
        [wins.trailingAnchor constraintEqualToAnchor:profile.leadingAnchor constant:-6],
        [wins.centerYAnchor constraintEqualToAnchor:self.presenceLabel.centerYAnchor],
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
    self.hostTimer = [NSTimer scheduledTimerWithTimeInterval:75 target:self selector:@selector(requestLiveHostTurn) userInfo:nil repeats:YES];
}

- (void)stop {
    self.started = NO;
    [self.pollTimer invalidate]; self.pollTimer = nil;
    [self.hostTimer invalidate]; self.hostTimer = nil;
}

- (void)expandTapped { [self setExpanded:YES animated:YES]; }
- (void)collapseTapped { [self setExpanded:NO animated:YES]; }

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (self.expanded == expanded) return;
    self.expanded = expanded;
    if (expanded) {
        CGFloat hostHeight = self.superview.bounds.size.height;
        self.heightConstraint.constant = hostHeight > 0 ? MIN(MAX(hostHeight * 0.62, 320), 560) : 420;
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
        if (expanded) [self scrollToBottomAnimated:NO];
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
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationOptions options = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue] << 16;
    [UIView animateWithDuration:duration delay:0 options:options animations:^{ [self.superview layoutIfNeeded]; [self scrollToBottomAnimated:NO]; } completion:nil];
}

- (void)scrollToBottomAnimated:(BOOL)animated {
    if (!self.messages.count) return;
    [self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:self.messages.count inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:animated];
}

- (void)request:(NSDictionary *)body completion:(void (^)(NSDictionary *, NSString *))completion {
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *error) {
        if (!token.length) { if (completion) completion(nil, NSLocalizedString(@"BRSlot.Lounge.SignIn", nil)); return; }
        NSURL *url = [NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/br-slot-social"]]; NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url]; request.HTTPMethod = @"POST"; request.timeoutInterval = 20; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"]; request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) { NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; NSString *message = networkError.localizedDescription ?: json[@"error"]; dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(json, message); }); }] resume];
    }];
}

- (void)refresh { if (self.loading || !self.started) return; self.loading = YES; [self request:@{ @"action": @"room_state", @"room_id": self.roomID } completion:^(NSDictionary *json, NSString *error) { self.loading = NO; if (error || !json) { self.presenceLabel.text = @"● Lounge reconnecting…"; self.presenceLabel.textColor = UIColor.systemOrangeColor; if (!self.messages.count) self.latestLabel.text = @"● Lounge reconnecting…"; return; } NSDictionary *profile = [json[@"profile"] isKindOfClass:NSDictionary.class] ? json[@"profile"] : nil; self.hasProfile = profile != nil; self.profileName = [profile[@"display_name"] isKindOfClass:NSString.class] ? profile[@"display_name"] : nil; self.musicEnabled = [profile[@"music_enabled"] boolValue]; NSInteger active = [json[@"active_players"] integerValue]; self.presenceLabel.text = [NSString stringWithFormat:@"● %ld player%@ in the lounge", (long)active, active == 1 ? @"" : @"s"]; self.presenceLabel.textColor = [UIColor colorWithRed:.55 green:1 blue:.72 alpha:1]; BOOL nearBottom = YES; if (self.expanded && self.messages.count) { CGFloat distance = self.table.contentSize.height - (self.table.contentOffset.y + self.table.bounds.size.height); nearBottom = distance < 90; } self.messages = [json[@"messages"] isKindOfClass:NSArray.class] ? json[@"messages"] : @[]; [self updateLatestLine]; if (self.expanded) { [self.table reloadData]; if (nearBottom || self.justSent) [self scrollToBottomAnimated:NO]; if (!self.hasProfile) [self offerProfileSetup]; } self.justSent = NO; }]; }

- (void)updateLatestLine {
    NSDictionary *message = self.messages.lastObject;
    if (![message isKindOfClass:NSDictionary.class]) { self.latestLabel.text = self.presenceLabel.text; return; }
    NSString *name = [message[@"display_name"] isKindOfClass:NSString.class] ? message[@"display_name"] : NSLocalizedString(@"BRSlot.Lounge.PlayerFallback", nil);
    NSString *body = [message[@"body"] isKindOfClass:NSString.class] ? message[@"body"] : @"";
    if ([message[@"is_house_host"] boolValue]) self.latestLabel.text = [NSString stringWithFormat:@"🎰 %@: %@", name, body];
    else self.latestLabel.text = [NSString stringWithFormat:@"%@: %@", name, body];
}

- (void)send { NSString *message = self.composer.text; if (!message.length) return; if (!self.hasProfile) { [self offerProfileSetup]; return; } self.composer.text = @""; [self request:@{ @"action": @"send", @"room_id": self.roomID, @"message": message } completion:^(NSDictionary *json, NSString *error) { if (error) { self.composer.text = message; return; } self.justSent = YES; [self refresh]; }]; }
- (void)requestLiveHostTurn { if (self.loading || !self.started || self.hostViewController.presentedViewController) return; [self request:@{ @"action": @"host_turn", @"room_id": self.roomID } completion:^(NSDictionary *json, NSString *error) { if (!error && [json[@"posted"] boolValue]) [self refresh]; }]; }
- (BOOL)textFieldShouldReturn:(UITextField *)textField { [self send]; return NO; }

- (void)offerProfileSetup { static BOOL showing = NO; if (showing || !self.hostViewController) return; showing = YES; BRSlotChatPromptController *sheet = [BRSlotChatPromptController new]; sheet.promptTitle = @"Join the lounge"; sheet.promptBody = @"Choose a public display name. Your email and account details stay private."; sheet.initialText = @""; sheet.actions = @[@"Save Profile", @"Not Now"]; sheet.selection = ^(NSInteger action, NSString *text) { showing = NO; if (action == 0) [self saveProfileName:text music:NO]; }; [self.hostViewController presentViewController:sheet animated:YES completion:nil]; }
- (void)editProfile { if (!self.hostViewController) return; BRSlotChatPromptController *sheet = [BRSlotChatPromptController new]; sheet.promptTitle = @"Your lounge profile"; sheet.promptBody = @"Your profile is shown only in game lounges."; sheet.initialText = self.profileName ?: @""; sheet.actions = @[@"Choose Photo", @"Save Profile", @"Cancel"]; __weak typeof(self) weakSelf = self; sheet.selection = ^(NSInteger action, NSString *text) { __strong typeof(weakSelf) self = weakSelf; if (!self) return; NSString *name = text.length ? text : (self.profileName ?: @"Player"); if (action == 0) { UIImagePickerController *picker = [UIImagePickerController new]; picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary; picker.delegate = self; [self.hostViewController presentViewController:picker animated:YES completion:nil]; } else if (action == 1) { [self saveProfileName:name music:self.musicEnabled]; } }; [self.hostViewController presentViewController:sheet animated:YES completion:nil]; }
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info { self.pendingAvatar = info[UIImagePickerControllerOriginalImage]; [picker dismissViewControllerAnimated:YES completion:^{ [self editProfile]; }]; }
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker { [picker dismissViewControllerAnimated:YES completion:nil]; }
- (void)saveProfileName:(NSString *)name music:(BOOL)music { if (name.length < 2) return; NSMutableDictionary *body = [@{ @"action": @"save_profile", @"display_name": name, @"music_enabled": @(music) } mutableCopy]; NSData *image = self.pendingAvatar ? UIImageJPEGRepresentation(self.pendingAvatar, .78) : nil; if (image.length) body[@"avatar_b64"] = [image base64EncodedStringWithOptions:0]; [self request:body completion:^(__unused NSDictionary *json, NSString *error) { if (!error) { self.pendingAvatar = nil; self.hasProfile = YES; [self refresh]; } }]; }

- (void)showLeaderboard { [self request:@{ @"action": @"leaderboard" } completion:^(NSDictionary *json, NSString *error) { NSDictionary *board = [json[@"leaderboard"] isKindOfClass:NSDictionary.class] ? json[@"leaderboard"] : nil; if (error || !board) return; [self presentLeaderboard:board]; }]; }
- (void)presentLeaderboard:(NSDictionary *)board { if (!self.hostViewController) return; UIViewController *sheet = [UIViewController new]; sheet.view.backgroundColor = [UIColor colorWithRed:.055 green:.02 blue:.12 alpha:1]; sheet.modalPresentationStyle = UIModalPresentationPageSheet; sheet.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent largeDetent]]; sheet.sheetPresentationController.prefersGrabberVisible = YES; UILabel *title = [UILabel new]; title.text = NSLocalizedString(@"BRSlot.Lounge.WinningsTitle", nil); title.font = [UIFont systemFontOfSize:25 weight:UIFontWeightBlack]; title.textColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1]; title.textAlignment = NSTextAlignmentCenter; title.translatesAutoresizingMaskIntoConstraints = NO; [sheet.view addSubview:title]; UILabel *mine = [UILabel new]; mine.text = [NSString stringWithFormat:NSLocalizedString(@"BRSlot.Lounge.WinningsMine", nil), board[@"my_today_total"] ?: @0, board[@"my_best_hit"] ?: @0]; mine.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold]; mine.textColor = UIColor.whiteColor; mine.textAlignment = NSTextAlignmentCenter; mine.translatesAutoresizingMaskIntoConstraints = NO; [sheet.view addSubview:mine]; UITextView *content = [UITextView new]; content.editable = NO; content.selectable = NO; content.backgroundColor = [UIColor colorWithWhite:1 alpha:.06]; content.layer.cornerRadius = 16; content.textColor = UIColor.whiteColor; content.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium]; NSMutableString *text = [NSMutableString stringWithString:NSLocalizedString(@"BRSlot.Lounge.WinningsTopTotals", nil)]; NSArray *daily = [board[@"daily_winnings"] isKindOfClass:NSArray.class] ? board[@"daily_winnings"] : @[]; if (!daily.count) [text appendString:NSLocalizedString(@"BRSlot.Lounge.WinningsNoWins", nil)]; [daily enumerateObjectsUsingBlock:^(NSDictionary *entry, NSUInteger i, BOOL *stop) { [text appendFormat:NSLocalizedString(@"BRSlot.Lounge.WinningsRow", nil), (unsigned long)i + 1, entry[@"name"] ?: NSLocalizedString(@"BRSlot.Lounge.PlayerFallback", nil), entry[@"total"] ?: @0]; }]; [text appendString:NSLocalizedString(@"BRSlot.Lounge.WinningsBiggestHits", nil)]; NSArray *hits = [board[@"biggest_hits"] isKindOfClass:NSArray.class] ? board[@"biggest_hits"] : @[]; if (!hits.count) [text appendString:NSLocalizedString(@"BRSlot.Lounge.WinningsNoHits", nil)]; [hits enumerateObjectsUsingBlock:^(NSDictionary *entry, NSUInteger i, BOOL *stop) { [text appendFormat:NSLocalizedString(@"BRSlot.Lounge.WinningsRow", nil), (unsigned long)i + 1, entry[@"name"] ?: NSLocalizedString(@"BRSlot.Lounge.PlayerFallback", nil), entry[@"payout"] ?: @0]; }]; [text appendString:NSLocalizedString(@"BRSlot.Lounge.WinningsFooter", nil)]; content.text = text; content.translatesAutoresizingMaskIntoConstraints = NO; [sheet.view addSubview:content]; UILayoutGuide *safe = sheet.view.safeAreaLayoutGuide; [NSLayoutConstraint activateConstraints:@[[title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:28], [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20], [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20], [mine.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8], [mine.leadingAnchor constraintEqualToAnchor:title.leadingAnchor], [mine.trailingAnchor constraintEqualToAnchor:title.trailingAnchor], [content.topAnchor constraintEqualToAnchor:mine.bottomAnchor constant:20], [content.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18], [content.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18], [content.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-18]]]; [self.hostViewController presentViewController:sheet animated:YES completion:nil]; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.messages.count + 1; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath { if (indexPath.row == 0) { UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]; cell.backgroundColor = [UIColor colorWithRed:.30 green:.08 blue:.42 alpha:.55]; cell.textLabel.text = @"🎰 Cherry Queen · Live house host"; cell.textLabel.textColor = [UIColor colorWithRed:1 green:.79 blue:.25 alpha:1]; cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBlack]; cell.detailTextLabel.text = @"A room character who keeps the lounge welcoming. Spin responsibly and celebrate each other."; cell.detailTextLabel.textColor = [UIColor colorWithWhite:.78 alpha:1]; cell.detailTextLabel.numberOfLines = 0; return cell; } NSDictionary *message = self.messages[indexPath.row - 1]; UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]; BOOL mine = [message[@"is_mine"] boolValue]; BOOL host = [message[@"is_house_host"] boolValue]; cell.backgroundColor = host ? [UIColor colorWithRed:.30 green:.08 blue:.42 alpha:.55] : (mine ? [UIColor colorWithRed:.22 green:.10 blue:.39 alpha:.65] : [UIColor colorWithWhite:1 alpha:.055]); cell.layer.cornerRadius = 12; cell.textLabel.text = host ? [NSString stringWithFormat:@"🎰 %@ · Live house host", message[@"display_name"] ?: @"Cherry Queen"] : (message[@"display_name"] ?: @"Player"); cell.textLabel.textColor = (mine || host) ? [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1] : UIColor.whiteColor; cell.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBlack]; cell.detailTextLabel.text = message[@"body"] ?: @""; cell.detailTextLabel.textColor = [UIColor colorWithWhite:.83 alpha:1]; cell.detailTextLabel.numberOfLines = 0; cell.imageView.image = host ? [UIImage systemImageNamed:@"sparkles"] : [UIImage systemImageNamed:@"person.crop.circle.fill"]; cell.imageView.tintColor = [UIColor colorWithRed:1 green:.78 blue:.2 alpha:1]; cell.imageView.layer.cornerRadius = 17; cell.imageView.clipsToBounds = YES; NSString *avatarURL = [message[@"avatar_url"] isKindOfClass:NSString.class] ? message[@"avatar_url"] : nil; if (!host && avatarURL.length) { NSURL *url = [NSURL URLWithString:avatarURL]; __weak UITableViewCell *weakCell = cell; [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) { UIImage *image = data ? [UIImage imageWithData:data] : nil; if (!image) return; dispatch_async(dispatch_get_main_queue(), ^{ weakCell.imageView.image = image; weakCell.imageView.contentMode = UIViewContentModeScaleAspectFill; }); }] resume]; } return cell; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return indexPath.row == 0 ? 62 : UITableViewAutomaticDimension; }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    if (indexPath.row == 0) return [UISwipeActionsConfiguration configurationWithActions:@[]];
    NSDictionary *message = self.messages[indexPath.row - 1];
    if (![message[@"is_mine"] boolValue] || [message[@"is_house_host"] boolValue]) return [UISwipeActionsConfiguration configurationWithActions:@[]];
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
