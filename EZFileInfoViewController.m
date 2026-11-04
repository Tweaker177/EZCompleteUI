// EZFileInfoViewController.m
// EZCompleteUI

#import "EZFileInfoViewController.h"
#import "EZFileItem.h"

#import <CommonCrypto/CommonDigest.h>

typedef NS_ENUM(NSInteger, EZFileInfoSection) {
    EZFileInfoSectionIdentity = 0,
    EZFileInfoSectionDetails,
    EZFileInfoSectionHash,
    EZFileInfoSectionCount
};

@interface EZFileInfoViewController ()

@property (nonatomic, strong) EZFileItem *item;
/// nil until the background hash finishes; NSNull never appears here —
/// a failed hash stores the localized failure text instead, so the row
/// always settles into a final state.
@property (nonatomic, copy, nullable) NSString *sha256Hex;
@property (nonatomic, copy, nullable) NSString *hashFailureText;

@end

@implementation EZFileInfoViewController

- (instancetype)initWithFileItem:(EZFileItem *)item {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _item = item;
        self.title = NSLocalizedString(@"EZFileExplorer.GetInfo",
                                       @"Get Info screen title");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.item.isDirectory) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:NSLocalizedString(@"EZFileExplorer.OpenIn",
                                            @"Open in… button")
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(ez_openInTapped)];
        [self ez_startHashing];
    }
}

#pragma mark - Hashing

- (void)ez_startHashing {
    NSURL *url = self.item.url;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *hex = [self ez_sha256HexForFileAtURL:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hex) {
                self.sha256Hex = hex;
            } else {
                self.hashFailureText = NSLocalizedString(@"EZFileExplorer.Info.HashFailed",
                                                         @"Hash failure row text");
            }
            if (self.isViewLoaded && self.view.window) {
                [self.tableView reloadSections:
                    [NSIndexSet indexSetWithIndex:EZFileInfoSectionHash]
                                withRowAnimation:UITableViewRowAnimationNone];
            }
        });
    });
}

/// Streams the file through CC_SHA256 in 64 KB chunks. Returns nil on
/// any read failure (file deleted mid-hash, unreadable, …).
- (nullable NSString *)ez_sha256HexForFileAtURL:(NSURL *)url {
    NSInputStream *stream = [NSInputStream inputStreamWithURL:url];
    if (!stream) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    [stream open];
    uint8_t buffer[64 * 1024];
    NSInteger read = 0;
    BOOL failed = NO;
    while ((read = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        CC_SHA256_Update(&context, buffer, (CC_LONG)read);
    }
    if (read < 0) failed = YES;
    [stream close];
    if (failed) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

#pragma mark - Actions

- (void)ez_openInTapped {
    UIActivityViewController *avc = [[UIActivityViewController alloc]
        initWithActivityItems:@[self.item.url] applicationActivities:nil];
    avc.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:avc animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // Folders have no hash — a folder's "contents hash" is not a thing.
    return self.item.isDirectory ? EZFileInfoSectionCount - 1
                                 : EZFileInfoSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case EZFileInfoSectionIdentity: return 2; // name, path
        case EZFileInfoSectionDetails:
            return 4; // size-or-items, type, created, modified
        case EZFileInfoSectionHash:     return 1;
        default:                        return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Two reuse pools: standard rows, and monospaced rows (path, hash)
    // whose detail font differs — keeping them apart means a recycled
    // cell never leaks the wrong font or accessory into another row.
    BOOL monoRow = (indexPath.section == EZFileInfoSectionHash) ||
                   (indexPath.section == EZFileInfoSectionIdentity && indexPath.row == 1);
    NSString * const reuseID = monoRow ? @"EZFileInfoCellMono" : @"EZFileInfoCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:reuseID];
        if (monoRow) {
            cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11
                                                                      weight:UIFontWeightRegular];
            cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        }
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 1;

    EZFileItem *item = self.item;
    switch (indexPath.section) {
        case EZFileInfoSectionIdentity:
            if (indexPath.row == 0) {
                cell.textLabel.text = NSLocalizedString(@"EZFileExplorer.Info.Name",
                                                        @"Info: name label");
                cell.detailTextLabel.text = item.displayName;
            } else {
                cell.textLabel.text = NSLocalizedString(@"EZFileExplorer.Info.Path",
                                                        @"Info: path label");
                // Monospaced + middle truncation (set at cell creation)
                // keeps both the volume and the filename visible.
                cell.detailTextLabel.text = item.url.path;
            }
            break;

        case EZFileInfoSectionDetails: {
            NSArray<NSString *> *labels = @[
                NSLocalizedString(@"EZFileExplorer.Info.Size", @"Info: size label"),
                NSLocalizedString(@"EZFileExplorer.Info.Type", @"Info: type label"),
                NSLocalizedString(@"EZFileExplorer.Info.Created", @"Info: created label"),
                NSLocalizedString(@"EZFileExplorer.Info.Modified", @"Info: modified label"),
            ];
            cell.textLabel.text = labels[(NSUInteger)indexPath.row];
            switch (indexPath.row) {
                case 0:
                    cell.detailTextLabel.text = item.isDirectory
                        ? [self ez_itemsTextForCount:item.childCount]
                        : [self ez_sizeTextForBytes:item.fileSize];
                    break;
                case 1:
                    cell.detailTextLabel.text = [self ez_typeTextForItem:item];
                    break;
                case 2:
                    cell.detailTextLabel.text = [self ez_dateText:item.creationDate];
                    break;
                case 3:
                    cell.detailTextLabel.text = [self ez_dateText:item.modifiedDate];
                    break;
            }
            break;
        }

        case EZFileInfoSectionHash:
            cell.textLabel.text = NSLocalizedString(@"EZFileExplorer.Info.SHA256",
                                                    @"Info: SHA-256 label");
            if (self.sha256Hex) {
                cell.detailTextLabel.text = self.sha256Hex;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            } else if (self.hashFailureText) {
                cell.detailTextLabel.text = self.hashFailureText;
            } else {
                cell.detailTextLabel.text = NSLocalizedString(@"EZFileExplorer.Info.Calculating",
                                                              @"Info: hash in progress");
            }
            break;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // The hash row is the only tappable one: tap copies the hash.
    if (indexPath.section == EZFileInfoSectionHash && self.sha256Hex) {
        [UIPasteboard generalPasteboard].string = self.sha256Hex;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:NSLocalizedString(@"EZFileExplorer.Info.Copied",
                                                       @"Hash copied confirmation")
                             message:nil
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction
            actionWithTitle:NSLocalizedString(@"EZFileExplorer.OK", @"OK button")
                      style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - Formatting helpers

- (NSString *)ez_sizeTextForBytes:(unsigned long long)bytes {
    NSString *formatted = [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                                         countStyle:NSByteCountFormatterCountStyleFile];
    return [NSString stringWithFormat:@"%@ (%@)",
        formatted,
        [NSString stringWithFormat:NSLocalizedString(@"EZFileExplorer.Info.Bytes",
                                                     @"Info: exact byte count"),
            [NSNumberFormatter localizedStringFromNumber:@(bytes)
                                             numberStyle:NSNumberFormatterDecimalStyle]]];
}

- (NSString *)ez_itemsTextForCount:(NSInteger)count {
    if (count < 0) return @"—";
    if (count == 1) return NSLocalizedString(@"EZFileExplorer.ItemCountOne",
                                             @"One item");
    return [NSString stringWithFormat:NSLocalizedString(@"EZFileExplorer.ItemCountMany",
                                                        @"Item count"),
        (long)count];
}

- (NSString *)ez_typeTextForItem:(EZFileItem *)item {
    if (item.isDirectory) {
        return NSLocalizedString(@"EZFileExplorer.Folder", @"Folder type label");
    }
    UTType *type = item.contentType;
    if (type) {
        NSString *desc = type.localizedDescription;
        return desc.length
            ? [NSString stringWithFormat:@"%@ (%@)", desc, type.identifier]
            : type.identifier;
    }
    NSString *ext = item.name.pathExtension;
    return ext.length ? ext.uppercaseString : @"—";
}

- (NSString *)ez_dateText:(nullable NSDate *)date {
    if (!date) return @"—";
    return [NSDateFormatter localizedStringFromDate:date
                                          dateStyle:NSDateFormatterMediumStyle
                                          timeStyle:NSDateFormatterMediumStyle];
}

@end
