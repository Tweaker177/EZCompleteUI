#import "EZAttachMenuViewController.h"

@interface EZAttachMenuViewController ()
@property (nonatomic, copy) void (^onWhisper)(void);
@property (nonatomic, copy) void (^onAnalyze)(void);
@property (nonatomic, copy) void (^onImageFiles)(void);
@property (nonatomic, copy) void (^onPhotoLibrary)(void);
@end

@implementation EZAttachMenuViewController

static NSArray<NSDictionary *> *EZAttachRows(void) {
    return @[
        @{ @"title": @"Transcribe Audio / Video", @"subtitle": @"Whisper transcription", @"icon": @"waveform" },
        @{ @"title": @"Analyze PDF / ePub / Text File", @"subtitle": @"Extracts and summarizes text", @"icon": @"doc.text" },
        @{ @"title": @"Attach Image from Files", @"subtitle": @"Vision analysis or image edit", @"icon": @"photo.on.rectangle" },
        @{ @"title": @"Choose from Photo Library", @"subtitle": @"Pick a photo from your library", @"icon": @"photo.stack" },
    ];
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Attach";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self action:@selector(_dismiss)];
}

- (void)_dismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)EZAttachRows().count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AttachCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"AttachCell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *row = EZAttachRows()[(NSUInteger)indexPath.row];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.detailTextLabel.text = row[@"subtitle"];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = [UIImage systemImageNamed:row[@"icon"]];
    cell.imageView.tintColor = [UIColor systemBlueColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self dismissViewControllerAnimated:YES completion:^{
        switch (indexPath.row) {
            case 0: if (self.onWhisper) self.onWhisper(); break;
            case 1: if (self.onAnalyze) self.onAnalyze(); break;
            case 2: if (self.onImageFiles) self.onImageFiles(); break;
            case 3: if (self.onPhotoLibrary) self.onPhotoLibrary(); break;
        }
    }];
}

@end
