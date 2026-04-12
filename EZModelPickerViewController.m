#import "EZModelPickerViewController.h"

@implementation EZModelPickerViewController

static NSDictionary<NSString *, NSString *> *EZModelLabels(void) {
    return @{
        @"gpt-5-pro": @"💬 Chat + 👁 Vision",
        @"gpt-5": @"💬 Chat + 👁 Vision",
        @"gpt-5-mini": @"💬 Chat + 👁 Vision",
        @"gpt-4o": @"💬 Chat + 👁 Vision ⭐",
        @"gpt-4o-mini": @"💬 Chat + 👁 Vision (fast)",
        @"gpt-4-turbo": @"💬 Chat + 👁 Vision",
        @"gpt-4": @"💬 Chat + 👁 Vision",
        @"gpt-3.5-turbo": @"💬 Chat only",
        @"gpt-image-1.5": @"🖼 Image gen (newest)",
        @"gpt-image-1": @"🖼 Image gen + ✏️ Edit",
        @"gpt-image-1-mini": @"🖼 Image gen (fast/cheap)",
        @"chatgpt-image-latest": @"🖼 ChatGPT image (latest)",
        @"dall-e-3": @"🖼 Image gen only (legacy)",
        @"sora-2": @"🎬 Video gen (4/8/12/16s)",
        @"sora-2-pro": @"🎬 Video gen HQ (5/10/15/20s)",
        @"whisper-1": @"🎙 Audio transcription only",
    };
}

static NSArray<NSString *> *EZModelSectionTitles(void) {
    return @[@"GPT-5 Reasoning", @"GPT-4 Chat", @"Image Generation", @"Video", @"Audio"];
}

static NSArray<NSArray<NSString *> *> *EZModelSections(void) {
    return @[
        @[@"gpt-5-pro", @"gpt-5", @"gpt-5-mini"],
        @[@"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4", @"gpt-3.5-turbo"],
        @[@"gpt-image-1.5", @"gpt-image-1", @"gpt-image-1-mini", @"chatgpt-image-latest", @"dall-e-3"],
        @[@"sora-2", @"sora-2-pro"],
        @[@"whisper-1"],
    ];
}

- (instancetype)initWithModels:(NSArray<NSString *> *)models selectedModel:(NSString *)selected {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    self.models = models;
    self.selectedModel = selected;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Select Model";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(_dismiss)];
}

- (void)_dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)EZModelSections().count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return EZModelSectionTitles()[(NSUInteger)section];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)EZModelSections()[(NSUInteger)section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModelCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ModelCell"];
    }
    NSString *model = EZModelSections()[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    cell.textLabel.text = model;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    cell.detailTextLabel.text = EZModelLabels()[model] ?: @"";
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = [model isEqualToString:self.selectedModel] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *model = EZModelSections()[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    self.selectedModel = model;
    [tableView reloadData];
    if (self.onModelSelected) self.onModelSelected(model);
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
