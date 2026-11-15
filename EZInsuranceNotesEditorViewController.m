// EZInsuranceNotesEditorViewController.m
// EZCompleteUI

#import "EZInsuranceNotesEditorViewController.h"

@interface EZInsuranceNotesEditorViewController () <UITextViewDelegate>
@property (nonatomic, copy) NSString *filename;
@property (nonatomic, copy, nullable) NSString *existingNotes;
@property (nonatomic, copy) void (^completion)(NSString * _Nullable);
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *placeholderLabel;
@end

@implementation EZInsuranceNotesEditorViewController

- (instancetype)initWithFilename:(NSString *)filename
                    existingNotes:(nullable NSString *)existingNotes
                       completion:(void (^)(NSString * _Nullable))completion {
    self = [super init];
    if (self) {
        _filename = [filename copy];
        _existingNotes = [existingNotes copy];
        _completion = [completion copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.filename;
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(ez_cancelTapped)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(ez_saveTapped)];

    self.textView = [[UITextView alloc] init];
    self.textView.font = [UIFont systemFontOfSize:16];
    self.textView.text = self.existingNotes ?: @"";
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.delegate = self;
    [self.view addSubview:self.textView];

    // UITextView has no built-in placeholder — a plain UILabel behind it,
    // hidden once there's real text, is the standard workaround.
    self.placeholderLabel = [[UILabel alloc] init];
    self.placeholderLabel.adjustsFontSizeToFitWidth = YES;
    self.placeholderLabel.minimumScaleFactor = 0.5;
    self.placeholderLabel.text = @"Why this file matters, what to look for, anything else worth noting…";
    self.placeholderLabel.font = self.textView.font;
    self.placeholderLabel.textColor = [UIColor placeholderTextColor];
    self.placeholderLabel.numberOfLines = 0;
    self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.placeholderLabel.hidden = self.textView.text.length > 0;
    [self.view addSubview:self.placeholderLabel];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8],
        [self.textView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12],
        [self.textView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12],
        [self.textView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-8],

        // textContainerInset default is (8,5,8,5) on all UITextViews —
        // matching that here keeps the placeholder sitting exactly where
        // typed text will start instead of visibly offset from it.
        [self.placeholderLabel.topAnchor constraintEqualToAnchor:self.textView.topAnchor constant:8],
        [self.placeholderLabel.leadingAnchor constraintEqualToAnchor:self.textView.leadingAnchor constant:9],
        [self.placeholderLabel.trailingAnchor constraintEqualToAnchor:self.textView.trailingAnchor constant:-9],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.textView becomeFirstResponder];
}

- (void)ez_cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)ez_saveTapped {
    NSString *trimmed = [self.textView.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    void (^completion)(NSString * _Nullable) = self.completion;
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion) completion(trimmed.length ? trimmed : nil);
    }];
}

#pragma mark - UITextViewDelegate

- (void)textViewDidChange:(UITextView *)textView {
    self.placeholderLabel.hidden = textView.text.length > 0;
}

@end
