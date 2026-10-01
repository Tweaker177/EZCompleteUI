//
//  EZVoicePickerViewController.m
//  EZTTSLibrary
//

#import "EZVoicePickerViewController.h"
#import "EZTTSVoiceService.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static NSString * const kEZVoicePickerCellID = @"EZVoicePickerCell";
static char kEZVoicePreviewVoiceKey;

@interface EZVoicePickerViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *emptyStateLabel;

@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *allVoices;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *filteredVoices;

/// ElevenLabs supplies a pre-recorded sample URL with voices that support
/// previews.  Playing that URL lets people audition a voice without creating
/// a billable text-to-speech generation.
@property (nonatomic, strong, nullable) AVPlayer *previewPlayer;
@property (nonatomic, copy, nullable) NSString *previewVoiceID;
@property (nonatomic, assign) BOOL previewIsPlaying;

@end

@implementation EZVoicePickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Choose a Voice";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.allVoices = @[];
    self.filteredVoices = @[];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                              target:self
                              action:@selector(handleCancelTapped)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search voices";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.emptyStateLabel = [[UILabel alloc] init];
    self.emptyStateLabel.text = @"No voices found.";
    self.emptyStateLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyStateLabel.hidden = YES;
    [self.view addSubview:self.emptyStateLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    [self fetchVoices];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.spinner.center = CGPointMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0);
    self.emptyStateLabel.frame = CGRectMake(20, self.view.safeAreaInsets.top + 40, self.view.bounds.size.width - 40, 40);
}

- (void)fetchVoices {
    [self.spinner startAnimating];
    self.tableView.hidden = YES;
    self.emptyStateLabel.hidden = YES;

    __weak typeof(self) weakSelf = self;
    [EZTTSVoiceService fetchVoicesWithCompletion:^(NSArray<NSDictionary<NSString *,id>*> * _Nullable voices, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.spinner stopAnimating];
        strongSelf.tableView.hidden = NO;

        if (error) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:error.userInfo[@"EZTTSVoiceServiceAlertTitle"] ?: @"Couldn't load voices"
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:alert animated:YES completion:nil];
            return;
        }

        strongSelf.allVoices = voices ?: @[];
        strongSelf.filteredVoices = strongSelf.allVoices;
        strongSelf.emptyStateLabel.hidden = (strongSelf.allVoices.count > 0);
        [strongSelf.tableView reloadData];
    }];
}

- (void)handleCancelTapped {
    [self stopVoicePreview];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        [self stopVoicePreview];
    }
}

- (void)dealloc {
    [self stopVoicePreview];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) {
        self.filteredVoices = self.allVoices;
    } else {
        NSString *needle = query.lowercaseString;
        NSMutableArray *matches = [NSMutableArray array];
        for (NSDictionary *voice in self.allVoices) {
            NSString *name = [self displayNameForVoice:voice];
            if ([name.lowercaseString containsString:needle]) [matches addObject:voice];
        }
        self.filteredVoices = matches;
    }
    self.emptyStateLabel.hidden = (self.filteredVoices.count > 0);
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource / Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredVoices.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kEZVoicePickerCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kEZVoicePickerCellID];
    }
    NSDictionary *voice = self.filteredVoices[indexPath.row];
    cell.textLabel.text = [self displayNameForVoice:voice];

    NSString *category = voice[@"category"];
    if ([category isKindOfClass:[NSString class]] && category.length > 0) {
        cell.detailTextLabel.text = [category capitalizedString];
    } else {
        cell.detailTextLabel.text = nil;
    }
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    NSString *previewURL = [self previewURLForVoice:voice];
    UIButton *previewButton = [self previewButtonForVoice:voice hasPreview:(previewURL.length > 0)];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = previewButton;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *voice = self.filteredVoices[indexPath.row];
    NSString *voiceID = [self voiceIDForVoice:voice];
    NSString *voiceName = [self displayNameForVoice:voice];

    void (^selected)(NSString *, NSString * _Nullable) = self.onVoiceSelected;
    [self stopVoicePreview];
    [self dismissViewControllerAnimated:YES completion:^{
        if (selected && voiceID.length > 0) selected(voiceID, voiceName);
    }];
}

#pragma mark - Helpers

- (UIButton *)previewButtonForVoice:(NSDictionary *)voice hasPreview:(BOOL)hasPreview {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 44, 44);
    button.layer.cornerRadius = 18.0;
    button.backgroundColor = hasPreview ? [UIColor systemFillColor] : [UIColor clearColor];
    button.tintColor = hasPreview ? self.view.tintColor : [UIColor tertiaryLabelColor];
    button.enabled = hasPreview;
    button.alpha = hasPreview ? 1.0 : 0.45;

    NSString *voiceID = [self voiceIDForVoice:voice];
    BOOL isPlaying = hasPreview &&
        self.previewIsPlaying &&
        voiceID.length > 0 &&
        [voiceID isEqualToString:self.previewVoiceID];
    UIImage *image = [UIImage systemImageNamed:(isPlaying ? @"stop.fill" : @"play.fill")];
    [button setImage:image forState:UIControlStateNormal];
    button.accessibilityLabel = hasPreview
        ? [NSString stringWithFormat:@"%@ voice sample", [self displayNameForVoice:voice]]
        : [NSString stringWithFormat:@"%@ has no voice sample", [self displayNameForVoice:voice]];
    button.accessibilityHint = hasPreview
        ? (isPlaying ? @"Stops the sample." : @"Plays ElevenLabs' included sample. This does not use coins.")
        : @"A preview is not available for this voice.";

    objc_setAssociatedObject(button, &kEZVoicePreviewVoiceKey, voice, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [button addTarget:self action:@selector(previewButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)previewButtonTapped:(UIButton *)sender {
    NSDictionary *voice = objc_getAssociatedObject(sender, &kEZVoicePreviewVoiceKey);
    NSString *voiceID = [self voiceIDForVoice:voice];
    NSString *previewURLString = [self previewURLForVoice:voice];
    NSURL *previewURL = [NSURL URLWithString:previewURLString];
    if (voiceID.length == 0 || previewURL == nil) {
        return;
    }

    if ([voiceID isEqualToString:self.previewVoiceID] && self.previewPlayer) {
        if (self.previewIsPlaying) {
            [self.previewPlayer pause];
            self.previewIsPlaying = NO;
        } else {
            [self.previewPlayer play];
            self.previewIsPlaying = YES;
        }
        [self.tableView reloadData];
        return;
    }

    [self stopVoicePreview];

    NSError *audioError = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&audioError];
    if (audioError) {
        NSLog(@"[EZVoicePicker] Could not configure audio session for voice preview: %@", audioError);
    }
    audioError = nil;
    [[AVAudioSession sharedInstance] setActive:YES error:&audioError];
    if (audioError) {
        NSLog(@"[EZVoicePicker] Could not activate audio session for voice preview: %@", audioError);
    }

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:previewURL];
    self.previewPlayer = [AVPlayer playerWithPlayerItem:item];
    self.previewVoiceID = voiceID;
    self.previewIsPlaying = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(voicePreviewDidEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(voicePreviewDidFail:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:item];
    [self.previewPlayer play];
    [self.tableView reloadData];
}

- (void)voicePreviewDidEnd:(NSNotification *)notification {
    [self stopVoicePreview];
    [self.tableView reloadData];
}

- (void)voicePreviewDidFail:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self stopVoicePreview];
    [self.tableView reloadData];

    if (self.view.window) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't play voice sample"
                                                                         message:error.localizedDescription ?: @"Please try again."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)stopVoicePreview {
    AVPlayerItem *item = self.previewPlayer.currentItem;
    if (item) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:item];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                      object:item];
    }
    [self.previewPlayer pause];
    self.previewPlayer = nil;
    self.previewVoiceID = nil;
    self.previewIsPlaying = NO;
}

- (NSString *)previewURLForVoice:(NSDictionary *)voice {
    id value = voice[@"preview_url"] ?: voice[@"previewUrl"];
    if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) {
        NSDictionary *sharing = [voice[@"sharing"] isKindOfClass:[NSDictionary class]] ? voice[@"sharing"] : nil;
        value = sharing[@"preview_url"] ?: sharing[@"previewUrl"];
    }
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

- (NSString *)voiceIDForVoice:(NSDictionary *)voice {
    id vid = voice[@"voice_id"] ?: voice[@"id"] ?: voice[@"voiceId"];
    return [vid isKindOfClass:[NSString class]] ? vid : @"";
}

- (NSString *)displayNameForVoice:(NSDictionary *)voice {
    id name = voice[@"name"] ?: voice[@"voice_name"];
    if ([name isKindOfClass:[NSString class]] && [(NSString *)name length] > 0) return name;
    return [self voiceIDForVoice:voice];
}

@end
