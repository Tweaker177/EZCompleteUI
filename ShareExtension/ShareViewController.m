#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const EZShareAppGroup = @"group.com.i0stweak3r.ezcompleteui";
static NSString * const EZShareManifestName = @"pending-image-import.plist";
static NSUInteger const EZShareMaximumImages = 15;

@interface ShareViewController : UIViewController
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation ShareViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];
    [stack addArrangedSubview:self.spinner];
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"Preparing photos for EZCompleteUI…";
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [stack addArrangedSubview:self.statusLabel];
    [self stageIncomingImages];
}

- (void)stageIncomingImages {
    NSMutableArray<NSItemProvider *> *providers = [NSMutableArray array];
    for (NSExtensionItem *item in self.extensionContext.inputItems) {
        for (NSItemProvider *provider in item.attachments) {
            if ([provider hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) [providers addObject:provider];
        }
    }
    if (!providers.count) { [self finishWithMessage:@"No images were received."]; return; }
    if (providers.count > EZShareMaximumImages) {
        [self finishWithMessage:@"Choose up to 15 photos at a time."];
        return;
    }

    NSURL *container = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:EZShareAppGroup];
    if (!container) {
        [self finishWithMessage:@"Sharing is not configured on this build."];
        return;
    }
    NSURL *folder = [container URLByAppendingPathComponent:[NSString stringWithFormat:@"ShareInbox/%@", NSUUID.UUID.UUIDString] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSObject *lock = [NSObject new];
    for (NSUInteger index = 0; index < providers.count; index++) {
        NSItemProvider *provider = providers[index];
        dispatch_group_enter(group);
        [provider loadFileRepresentationForTypeIdentifier:UTTypeImage.identifier completionHandler:^(NSURL *url, NSError *error) {
            if (url && !error) {
                NSString *extension = url.pathExtension.length ? url.pathExtension : @"jpg";
                NSString *name = [NSString stringWithFormat:@"image-%02lu.%@", (unsigned long)(index + 1), extension];
                NSURL *destination = [folder URLByAppendingPathComponent:name];
                BOOL accessed = [url startAccessingSecurityScopedResource];
                NSData *data = [NSData dataWithContentsOfURL:url];
                if (accessed) [url stopAccessingSecurityScopedResource];
                if (data.length && [data writeToURL:destination atomically:YES]) {
                    @synchronized (lock) { [names addObject:name]; }
                }
            }
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (!names.count) { [self finishWithMessage:@"EZCompleteUI could not read those photos."]; return; }
        NSArray *orderedNames = [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        NSDictionary *manifest = @{ @"folder": folder.lastPathComponent, @"files": orderedNames };
        NSURL *manifestURL = [container URLByAppendingPathComponent:EZShareManifestName];
        [manifest writeToURL:manifestURL atomically:YES];
        self.statusLabel.text = [NSString stringWithFormat:@"%lu photo%@ ready in EZCompleteUI",
            (unsigned long)orderedNames.count, orderedNames.count == 1 ? @"" : @"s"];
        [self.spinner stopAnimating];
        NSURL *openAppURL = [NSURL URLWithString:@"ezcomplete://shared-images"];
        [self.extensionContext openURL:openAppURL completionHandler:^(__unused BOOL success) {
            [self.extensionContext completeRequestReturningItems:nil completionHandler:nil];
        }];
    });
}

- (void)finishWithMessage:(NSString *)message {
    [self.spinner stopAnimating];
    self.statusLabel.text = message;
}
@end
