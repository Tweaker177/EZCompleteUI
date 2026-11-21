//
//  EZImageSettingsViewController.m
//  EZCompleteUI v1.1
//
//  Purpose: modal settings sheet for image generation options (size,
//  quality, format, background, moderation, variations), backed directly
//  by NSUserDefaults under the same keys ViewController.m reads at
//  generation time (imgSize/imgQuality/imgFormat/imgBackground/
//  imgModeration/imgVariations).
//
//  Changes from v1.0:
//   - Quality options are now model-aware. gpt-image-2.5-flare and
//     gpt-image-2.5-sunburst support xhigh/max in addition to the
//     existing high/medium/low/auto; every other model (gpt-image-1/1.5/
//     mini/2, chatgpt-image-latest) doesn't — ez-image validates this
//     server-side and returns a 400 for xhigh/max on an unsupported model
//     rather than silently mispricing it, so those two options only show
//     up here when the current model actually supports them.
//   - Added a stale-value guard: if imgQuality is already set to xhigh/max
//     from a previous session (picked while a 2.5 model was selected) and
//     the user has since switched to a model that doesn't support them,
//     this now resets it to "auto" instead of leaving a stored value that
//     (a) wouldn't show a checkmark against any visible option here, and
//     (b) would get rejected with a 400 the next time an image is
//     actually generated with the new model.
//   - gpt-image-2.6-flare / gpt-image-2.6-sunburst join the picker.
//     They support everything the 2.5 pair does, plus two things of
//     their own: a Complexity setting and GIF output. Complexity is
//     its OWN section next to Quality, never folded into it — quality
//     is fidelity, complexity is how much the model plans before it
//     draws, and the two are independent axes. It is stored under
//     imgComplexity (high/medium/low, default high — the API's own
//     default when the key is omitted, so a missing value must never
//     quietly undercut a quality pick) and is not purchase-gated.
//     GIF is generate-only and 2.6-only: it joins the Format options
//     only while a 2.6 model is selected, frames are fixed at
//     512x512 server-side, and a GIF left selected after switching to
//     another model is clamped back to PNG below, the same treatment
//     stale xhigh/max quality values already get.
//   - EZModelsSupportingXhighMax's model list must be kept in sync with
//     MODELS_SUPPORTING_XHIGH_MAX in ez-image/index.ts and
//     check-entitlement/index.ts — duplicated here rather than shared
//     since this file has no header in common with either.
//

#import "EZImageSettingsViewController.h"
#import "EZCoinStoreViewController.h"
#import "EZEntitlementManager.h"
#import "helpers.h"

static NSSet<NSString *> *EZModelsSupportingXhighMax(void) {
    static NSSet<NSString *> *models;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        models = [NSSet setWithObjects:@"gpt-image-2.5-flare", @"gpt-image-2.5-sunburst",
                                        @"gpt-image-2.6-flare", @"gpt-image-2.6-sunburst", nil];
    });
    return models;
}

static NSSet<NSString *> *EZModelsSupportingImage26(void) {
    static NSSet<NSString *> *models;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        models = [NSSet setWithObjects:@"gpt-image-2.6-flare", @"gpt-image-2.6-sunburst", nil];
    });
    return models;
}

static BOOL EZImageSettingRequiresSubscription(NSString *key, NSString *value) {
    return [key isEqualToString:@"imgQuality"] &&
           ![value isEqualToString:@"low"] &&
           ![value isEqualToString:@"medium"];
}

@implementation EZImageSettingsViewController {
    NSArray<NSDictionary *> *_sections;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Image Settings";

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *selectedModel  = self.modelIdentifier ?: [defaults stringForKey:@"selectedModel"] ?: @"";
    BOOL supportsXhighMax    = [EZModelsSupportingXhighMax() containsObject:selectedModel];
    BOOL supports26          = [EZModelsSupportingImage26() containsObject:selectedModel];

    NSArray<NSString *> *qualityOptions = supportsXhighMax
        ? @[@"auto", @"max", @"xhigh", @"high", @"medium", @"low"]
        : @[@"auto", @"high", @"medium", @"low"];
    NSArray<NSString *> *qualityLabels = supportsXhighMax
        ? @[@"Auto (recommended)", @"Max (highest quality)", @"Extra High", @"High", @"Medium", @"Low (fastest)"]
        : @[@"Auto (recommended)", @"High", @"Medium", @"Low (fastest)"];

    // Clamp a previously-stored quality that's no longer valid for the
    // current model — see this file's own changelog for why.
    NSString *storedQuality = [defaults stringForKey:@"imgQuality"];
    if (storedQuality.length > 0 && ![qualityOptions containsObject:storedQuality]) {
        [defaults setObject:@"auto" forKey:@"imgQuality"];
        EZLogf(EZLogLevelInfo, @"IMGSET", @"Reset imgQuality (%@ not valid for %@) → auto",
               storedQuality, selectedModel);
    }

    if (![self hasPurchasedAccess]) {
        NSString *currentQuality = [defaults stringForKey:@"imgQuality"] ?: @"auto";
        if (EZImageSettingRequiresSubscription(@"imgQuality", currentQuality))
            [defaults setObject:@"medium" forKey:@"imgQuality"];
    }

    // Same stale-value treatment for the 2.6-only settings: a GIF
    // format picked under a 2.6 model falls back to PNG once the model
    // no longer supports it, and an unrecognized complexity value
    // falls back to high.
    if (!supports26 && [[defaults stringForKey:@"imgFormat"] isEqualToString:@"gif"]) {
        [defaults setObject:@"png" forKey:@"imgFormat"];
        EZLogf(EZLogLevelInfo, @"IMGSET", @"Reset imgFormat (gif not valid for %@) → png", selectedModel);
    }
    NSString *storedComplexity = [defaults stringForKey:@"imgComplexity"];
    if (storedComplexity.length > 0 &&
        ![@[@"high", @"medium", @"low"] containsObject:storedComplexity]) {
        [defaults setObject:@"high" forKey:@"imgComplexity"];
    }

    NSArray<NSString *> *formatOptions = supports26
        ? @[@"png", @"jpeg", @"webp", @"gif"]
        : @[@"png", @"jpeg", @"webp"];
    NSArray<NSString *> *formatLabels = supports26
        ? @[@"PNG — lossless, transparency OK", @"JPEG — lossy, no transparency", @"WebP — modern, transparency OK", @"GIF — animated, 512 × 512"]
        : @[@"PNG — lossless, transparency OK", @"JPEG — lossy, no transparency", @"WebP — modern, transparency OK"];

    _sections = @[
        @{ @"title": @"Size",       @"key": @"imgSize",       @"default": @"1024x1024",
           @"options": @[@"1024x1024", @"1024x1536", @"1536x1024"],
           @"labels":  @[@"Square — 1024 × 1024", @"Portrait — 1024 × 1536", @"Landscape — 1536 × 1024"] },
        @{ @"title": @"Quality",    @"key": @"imgQuality",    @"default": @"auto",
           @"options": qualityOptions,
           @"labels":  qualityLabels },
        @{ @"title": @"Format",     @"key": @"imgFormat",     @"default": @"png",
           @"options": formatOptions,
           @"labels":  formatLabels },
        @{ @"title": @"Background", @"key": @"imgBackground", @"default": @"auto",
           @"options": @[@"auto", @"transparent", @"opaque"],
           @"labels":  @[@"Auto", @"Transparent (PNG/WebP only)", @"Opaque"] },
        @{ @"title": @"Moderation", @"key": @"imgModeration", @"default": @"auto",
           @"options": @[@"auto", @"low"],
           @"labels":  @[@"Auto", @"Low"] },
        @{ @"title": @"Variations", @"key": @"imgVariations", @"default": @"1",
           @"options": @[@"1", @"2", @"4"],
           @"labels":  @[@"1 — Single result", @"2 — Two variations", @"4 — Four variations (grid)"] },
    ];
    if (supports26) {
        // Complexity sits directly under Quality as its own section —
        // an independent axis, not another quality preset.
        NSMutableArray *withComplexity = [_sections mutableCopy];
        [withComplexity insertObject:@{ @"title": @"Complexity", @"key": @"imgComplexity", @"default": @"high",
                                        @"options": @[@"high", @"medium", @"low"],
                                        @"labels":  @[@"High — plans the most", @"Medium", @"Low — plans the least"] }
                             atIndex:2];
        _sections = [withComplexity copy];
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(_dismiss)];
}

- (void)_dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)hasPurchasedAccess {
    // `basic` is also the free welcome-row tier.  Only the durable server
    // purchase flag may unlock high/xhigh/max image quality.
    return [EZEntitlementManager shared].hasEverPurchased;
}

- (void)showSubscriptionRequiredAlert {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:NSLocalizedString(@"EZSubscription.RequiredTitle", nil)
                         message:NSLocalizedString(@"EZSubscription.ImageSettingsRequired", nil)
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSubscription.NotNow", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZSubscription.ViewPlans", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self.navigationController pushViewController:[[EZCoinStoreViewController alloc] init]
                                             animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return (NSInteger)_sections.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return _sections[(NSUInteger)s][@"title"];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)[_sections[(NSUInteger)s][@"options"] count];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"ImgCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"ImgCell"];
    NSDictionary *sec  = _sections[(NSUInteger)ip.section];
    NSString *val      = sec[@"options"][(NSUInteger)ip.row];
    NSString *current  = [[NSUserDefaults standardUserDefaults] stringForKey:sec[@"key"]] ?: sec[@"default"];
    cell.textLabel.text  = sec[@"labels"][(NSUInteger)ip.row];
    cell.textLabel.font  = [UIFont systemFontOfSize:15];
    cell.accessoryType   = [val isEqualToString:current]
                           ? UITableViewCellAccessoryCheckmark
                           : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *sec = _sections[(NSUInteger)ip.section];
    NSString *val     = sec[@"options"][(NSUInteger)ip.row];
    if (EZImageSettingRequiresSubscription(sec[@"key"], val) && ![self hasPurchasedAccess]) {
        [self showSubscriptionRequiredAlert];
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:val forKey:sec[@"key"]];
    EZLogf(EZLogLevelInfo, @"IMGSET", @"%@ → %@", sec[@"key"], val);
    [tv reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)ip.section]
      withRowAnimation:UITableViewRowAnimationNone];
}

@end
