// EZTextFileEditorViewController.m
// EZCompleteUI

#import "EZTextFileEditorViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// Over this size a file opens read-only (plan limit). Read-only
/// *display* is separately capped higher so big logs can still be
/// viewed; past the display cap the editor shows an explanation
/// instead of loading the file at all.
static const unsigned long long kEZEditorEditableLimit = 2ULL * 1024 * 1024;
static const unsigned long long kEZEditorDisplayLimit = 10ULL * 1024 * 1024;

typedef NS_ENUM(NSInteger, EZEditorReadOnlyReason) {
    EZEditorEditable = 0,
    EZEditorReadOnlyLocation,
    EZEditorReadOnlyTooLarge,
    EZEditorReadOnlyEncoding,
    EZEditorReadOnlyBinary,
};

@interface EZTextFileEditorViewController () <UITextViewDelegate>
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, assign) BOOL callerReadOnly;
@property (nonatomic, assign) EZEditorReadOnlyReason readOnlyReason;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIView *bannerView;
@property (nonatomic, strong) UILabel *bannerLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) NSLayoutConstraint *bannerHeight;
@property (nonatomic, strong) NSLayoutConstraint *countBottom;
@property (nonatomic, copy) NSString *originalText;
@property (nonatomic, assign) BOOL dirty;
@end

@implementation EZTextFileEditorViewController

- (instancetype)initWithFileURL:(NSURL *)fileURL readOnly:(BOOL)readOnly {
    self = [super init];
    if (self) {
        _fileURL = fileURL;
        _callerReadOnly = readOnly;
        _originalText = @"";
    }
    return self;
}

- (BOOL)ez_isReadOnly {
    return self.readOnlyReason != EZEditorEditable;
}

#pragma mark - Loading

/// Reads the file and settles the read-only reason. Returns the text to
/// display. Binary content is never placed in the text view — the
/// explanation string is displayed instead, so there is nothing a stray
/// edit could mangle even if editing were somehow enabled.
- (NSString *)ez_loadText {
    if (self.callerReadOnly) self.readOnlyReason = EZEditorReadOnlyLocation;
    NSDictionary<NSURLResourceKey, id> *values =
        [self.fileURL resourceValuesForKeys:@[NSURLFileSizeKey] error:nil];
    unsigned long long size = [values[NSURLFileSizeKey] unsignedLongLongValue];
    if (size > kEZEditorDisplayLimit) {
        if (self.readOnlyReason == EZEditorEditable) {
            self.readOnlyReason = EZEditorReadOnlyTooLarge;
        }
        // Too big to even display responsibly — the size banner plus
        // this line is the whole content.
        return NSLocalizedString(@"EZFileExplorer.Editor.ReadOnlyLarge",
                                 @"Read-only banner: too large");
    }
    NSData *data = [NSData dataWithContentsOfURL:self.fileURL options:0 error:nil];
    if (!data) {
        if (self.readOnlyReason == EZEditorEditable) {
            self.readOnlyReason = EZEditorReadOnlyLocation;
        }
        return NSLocalizedString(@"EZFileExplorer.Editor.LoadFailed",
                                 @"Editor load failure text");
    }
    if (size > kEZEditorEditableLimit &&
        self.readOnlyReason == EZEditorEditable) {
        self.readOnlyReason = EZEditorReadOnlyTooLarge;
    }
    if ([data rangeOfData:[NSData dataWithBytes:"\0" length:1]
                  options:0
                    range:NSMakeRange(0, data.length)].location != NSNotFound) {
        if (self.readOnlyReason == EZEditorEditable) {
            self.readOnlyReason = EZEditorReadOnlyBinary;
        }
        return NSLocalizedString(@"EZFileExplorer.Editor.ReadOnlyBinary",
                                 @"Binary explanation");
    }
    NSString *utf8 = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
    if (!utf8) {
        if (self.readOnlyReason == EZEditorEditable) {
            self.readOnlyReason = EZEditorReadOnlyEncoding;
        }
        // Latin-1 maps every byte 1:1, so this always succeeds and the
        // user sees the file's actual content — as a read-only view.
        return [[NSString alloc] initWithData:data
                                     encoding:NSISOLatin1StringEncoding] ?: @"";
    }
    return utf8;
}

- (NSString *)ez_bannerText {
    switch (self.readOnlyReason) {
        case EZEditorReadOnlyTooLarge:
            return NSLocalizedString(@"EZFileExplorer.Editor.ReadOnlyLarge",
                                     @"Read-only banner: too large");
        case EZEditorReadOnlyEncoding:
            return NSLocalizedString(@"EZFileExplorer.Editor.ReadOnlyEncoding",
                                     @"Read-only banner: not UTF-8");
        case EZEditorReadOnlyBinary:
            return NSLocalizedString(@"EZFileExplorer.Editor.ReadOnlyBinary",
                                     @"Read-only banner: binary");
        case EZEditorReadOnlyLocation:
            return NSLocalizedString(@"EZFileExplorer.Editor.ReadOnlyLocation",
                                     @"Read-only banner: location");
        case EZEditorEditable:
            return @"";
    }
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    NSString *text = [self ez_loadText];
    self.originalText = text;
    BOOL readOnly = [self ez_isReadOnly];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self
                             action:@selector(ez_cancelTapped)];
    if (!readOnly) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                 target:self
                                 action:@selector(ez_saveTapped)];
        self.navigationItem.rightBarButtonItem.enabled = NO;
    }
    [self ez_updateTitle];

    // Read-only banner strip (hidden entirely when editable).
    self.bannerView = [[UIView alloc] init];
    self.bannerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.bannerView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.bannerLabel = [[UILabel alloc] init];
    self.bannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.bannerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.bannerLabel.textColor = [UIColor secondaryLabelColor];
    self.bannerLabel.numberOfLines = 0;
    self.bannerLabel.text = [self ez_bannerText];
    [self.bannerView addSubview:self.bannerLabel];
    [self.view addSubview:self.bannerView];

    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:13
                                                     weight:UIFontWeightRegular];
    self.textView.text = text;
    self.textView.editable = !readOnly;
    self.textView.delegate = self;
    self.textView.alwaysBounceVertical = YES;
    // Code and logs must not be "helpfully" rewritten by the keyboard.
    self.textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.textView.smartQuotesType = UITextSmartQuotesTypeNo;
    self.textView.smartDashesType = UITextSmartDashesTypeNo;
    self.textView.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    [self.view addSubview:self.textView];

    self.countLabel = [[UILabel alloc] init];
    self.countLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.countLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.countLabel.textColor = [UIColor secondaryLabelColor];
    self.countLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.countLabel];
    [self ez_updateCount];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    self.bannerHeight = [self.bannerView.heightAnchor constraintEqualToConstant:0];
    self.countBottom = [self.countLabel.bottomAnchor
        constraintEqualToAnchor:safe.bottomAnchor constant:-4];
    [NSLayoutConstraint activateConstraints:@[
        [self.bannerView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.bannerView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.bannerView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        self.bannerHeight,
        [self.bannerLabel.topAnchor constraintEqualToAnchor:self.bannerView.topAnchor constant:6],
        [self.bannerLabel.bottomAnchor constraintEqualToAnchor:self.bannerView.bottomAnchor constant:-6],
        [self.bannerLabel.leadingAnchor constraintEqualToAnchor:self.bannerView.leadingAnchor constant:12],
        [self.bannerLabel.trailingAnchor constraintEqualToAnchor:self.bannerView.trailingAnchor constant:-12],

        [self.textView.topAnchor constraintEqualToAnchor:self.bannerView.bottomAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [self.textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.countLabel.topAnchor constant:-2],

        [self.countLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.countLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        self.countBottom,
    ]];
    if (readOnly) {
        // Measure the wrapped banner text and give the strip its height.
        CGFloat width = UIScreen.mainScreen.bounds.size.width - 24;
        CGRect rect = [self.bannerLabel textRectForBounds:CGRectMake(0, 0, width, CGFLOAT_MAX)
                                   limitedToNumberOfLines:0];
        self.bannerHeight.constant = CGRectGetHeight(rect) + 12;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ez_keyboardChanged:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ez_keyboardChanged:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (![self ez_isReadOnly]) [self.textView becomeFirstResponder];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)ez_keyboardChanged:(NSNotification *)note {
    CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    frame = [self.view convertRect:frame fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(frame));
    // Lift the character count (and with it the text view's bottom edge)
    // above the keyboard; on hide the frame sits below the view and
    // the overlap returns to 0.
    self.countBottom.constant = -4 - overlap;
    NSTimeInterval duration =
        [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{ [self.view layoutIfNeeded]; }];
}

#pragma mark - Title / dirty state

- (void)ez_updateTitle {
    NSString *name = self.fileURL.lastPathComponent;
    if (!self.dirty) {
        self.navigationItem.titleView = nil;
        self.title = name;
        return;
    }
    // Dirty indicator: orange dot before the filename, in the title
    // view (a plain title string can't carry the color).
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc]
        initWithString:@"● "
            attributes:@{ NSForegroundColorAttributeName: [UIColor systemOrangeColor],
                          NSFontAttributeName: [UIFont systemFontOfSize:13] }];
    [title appendAttributedString:[[NSAttributedString alloc]
        initWithString:name
            attributes:@{ NSForegroundColorAttributeName: [UIColor labelColor],
                          NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline] }]];
    UILabel *label = [[UILabel alloc] init];
    label.attributedText = title;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    self.navigationItem.titleView = label;
    self.title = name;
}

- (void)ez_updateCount {
    self.countLabel.text = [NSString stringWithFormat:
        NSLocalizedString(@"EZFileExplorer.Editor.Characters", @"Character count"),
        (long)self.textView.text.length];
}

#pragma mark - Actions

- (void)ez_cancelTapped {
    if (!self.dirty) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.Editor.DiscardTitle",
                                                   @"Discard changes title")
                         message:NSLocalizedString(@"EZFileExplorer.Editor.DiscardMessage",
                                                   @"Discard changes body")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Editor.KeepEditing",
                                          @"Keep editing button")
                  style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.Editor.Discard",
                                          @"Discard button")
                  style:UIAlertActionStyleDestructive
                handler:^(__unused UIAlertAction *a) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ez_saveTapped {
    NSString *text = self.textView.text ?: @"";
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    // Atomic save: write a sibling temp file, then swap it over the
    // original. A crash anywhere in here leaves either the old file or
    // the new file — never a half-written one.
    NSURL *directory = self.fileURL.URLByDeletingLastPathComponent;
    NSURL *temp = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@".ez-save-%@", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    if (![data writeToURL:temp options:NSDataWritingAtomic error:&error]) {
        [self ez_presentError:error];
        return;
    }
    NSURL *resulting = nil;
    if (![[NSFileManager defaultManager] replaceItemAtURL:self.fileURL
                                           withItemAtURL:temp
                                          backupItemName:nil
                                                 options:0
                                      resultingItemURL:&resulting
                                                   error:&error]) {
        [[NSFileManager defaultManager] removeItemAtURL:temp error:nil];
        [self ez_presentError:error];
        return;
    }
    self.originalText = text;
    self.dirty = NO;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)ez_presentError:(nullable NSError *)error {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.Error", @"Error title")
                         message:error.localizedDescription.length
                             ? error.localizedDescription
                             : NSLocalizedString(@"EZFileExplorer.ActionFailed",
                                                 @"Generic failure message")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
        actionWithTitle:NSLocalizedString(@"EZFileExplorer.OK", @"OK button")
                  style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITextViewDelegate

- (void)textViewDidChange:(UITextView *)textView {
    BOOL wasDirty = self.dirty;
    self.dirty = ![textView.text isEqualToString:self.originalText];
    if (self.dirty != wasDirty) {
        [self ez_updateTitle];
        self.navigationItem.rightBarButtonItem.enabled = self.dirty;
    }
    [self ez_updateCount];
}

@end

NS_ASSUME_NONNULL_END
