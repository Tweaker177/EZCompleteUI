#import "EZImageSettingsViewController.h"
#import "helpers.h"

@implementation EZImageSettingsViewController {
    NSArray<NSDictionary *> *_sections;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Image Settings";
    _sections = @[
        @{ @"title": @"Size", @"key": @"imgSize", @"default": @"1024x1024",
           @"options": @[@"1024x1024", @"1024x1536", @"1536x1024"],
           @"labels": @[@"Square — 1024 × 1024", @"Portrait — 1024 × 1536", @"Landscape — 1536 × 1024"] },
        @{ @"title": @"Quality", @"key": @"imgQuality", @"default": @"auto",
           @"options": @[@"auto", @"high", @"medium", @"low"],
           @"labels": @[@"Auto (recommended)", @"High", @"Medium", @"Low (fastest)"] },
        @{ @"title": @"Format", @"key": @"imgFormat", @"default": @"png",
           @"options": @[@"png", @"jpeg", @"webp"],
           @"labels": @[@"PNG — lossless, transparency OK", @"JPEG — lossy, no transparency", @"WebP — modern, transparency OK"] },
        @{ @"title": @"Background", @"key": @"imgBackground", @"default": @"auto",
           @"options": @[@"auto", @"transparent", @"opaque"],
           @"labels": @[@"Auto", @"Transparent (PNG/WebP only)", @"Opaque"] },
        @{ @"title": @"Moderation", @"key": @"imgModeration", @"default": @"auto",
           @"options": @[@"auto", @"low"],
           @"labels": @[@"Auto", @"Low"] },
    ];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(_dismiss)];
}

- (void)_dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)_sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return _sections[(NSUInteger)section][@"title"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[_sections[(NSUInteger)section][@"options"] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ImgCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"ImgCell"];
    }
    NSDictionary *sec = _sections[(NSUInteger)indexPath.section];
    NSString *val = sec[@"options"][(NSUInteger)indexPath.row];
    NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:sec[@"key"]] ?: sec[@"default"];
    cell.textLabel.text = sec[@"labels"][(NSUInteger)indexPath.row];
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.accessoryType = [val isEqualToString:current] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *sec = _sections[(NSUInteger)indexPath.section];
    NSString *val = sec[@"options"][(NSUInteger)indexPath.row];
    [[NSUserDefaults standardUserDefaults] setObject:val forKey:sec[@"key"]];
    EZLogf(EZLogLevelInfo, @"IMGSET", @"%@ → %@", sec[@"key"], val);
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)indexPath.section] withRowAnimation:UITableViewRowAnimationNone];
}

@end
