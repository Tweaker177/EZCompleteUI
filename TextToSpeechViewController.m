//
// TextToSpeechViewController.m//
// Notes:
//  
//  - Adds a proper NSTimer property `stopMeterTimer` and safe invalidation.
//  - Includes ElevenLabs TTS integration with safe fallback to mp3_44100_128,
//    voice listing, MP3->M4A conversion, PCM->WAV wrapping, UI styling, and safe-area inset.
//  - Uses EZKeyVault.loadKeyForIdentifier:EZVaultKeyElevenLabs for API key retrieval.
//  - Requires helpers.h (EZLog / EZLogf) and EZKeyVault.h in the project.
//  - Link against AVFoundation and UIKit.
//
// Replace your existing TextToSpeechViewController.m with this file.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "EZKeyVault.h"
#import "helpers.h"
#import "EZAuthManager.h"


static NSString * const kDefaultVoiceID = @"JBFqnCBsd6RMkjVDRZzb"; // fallback example
static NSString * const kDefaultModelID = @"eleven_multilingual_v2";
static NSString * const kFallbackMP3Format = @"mp3_44100_128";

@interface TextToSpeechViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextViewDelegate, UITextFieldDelegate>
@end

@interface TextToSpeechViewController ()
@property (nonatomic, strong) UIView *container;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UITextField *voiceField;
@property (nonatomic, strong) UISegmentedControl *formatControl; // 0=WAV 1=M4A
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *downloadButton;
@property (nonatomic, strong) UIButton *fetchVoicesButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) AVAudioPlayer *player;

@property (nonatomic, strong) UITableView *voicesTable;
@property (nonatomic, strong) NSArray<NSDictionary *> *voices; // raw voice dicts

// Timer added to address your invalidate error
@property (nonatomic, strong, nullable) NSTimer *stopMeterTimer;

// Speed slider (ElevenLabs speed param: 0.7–1.2)
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UILabel  *speedLabel;
@end

@implementation TextToSpeechViewController

#pragma mark - Helpers

static NSString *timestampString(void) {
    long long t = (long long)[[NSDate date] timeIntervalSince1970];
    return [NSString stringWithFormat:@"%lld", t];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Text to Speech";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // Container view (styled)
    self.container = [[UIView alloc] initWithFrame:CGRectZero];
    self.container.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.container.layer.cornerRadius = 12.0;
    self.container.layer.borderWidth = 1.0;
    self.container.layer.borderColor = [UIColor systemGray4Color].CGColor;
    self.container.layer.shadowColor = [UIColor colorWithRed:0 green:0.48 blue:1 alpha:0.15].CGColor;
    self.container.layer.shadowOpacity = 1.0;
    self.container.layer.shadowOffset = CGSizeMake(0, 6);
    self.container.layer.shadowRadius = 18;
    [self.view addSubview:self.container];

    // TextView
    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.delegate = self;
    self.textView.font = [UIFont systemFontOfSize:15];
    self.textView.layer.cornerRadius = 10;
    self.textView.layer.borderWidth = 1.0;
    self.textView.layer.borderColor = [UIColor systemGray4Color].CGColor;
    self.textView.backgroundColor = [UIColor systemBackgroundColor];
    self.textView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    [self.container addSubview:self.textView];

    // Voice field
    self.voiceField = [[UITextField alloc] initWithFrame:CGRectZero];
    self.voiceField.borderStyle = UITextBorderStyleRoundedRect;
    self.voiceField.placeholder = kDefaultVoiceID;
    self.voiceField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.voiceField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.voiceField.font = [UIFont systemFontOfSize:14];
    self.voiceField.returnKeyType = UIReturnKeyDone;
    self.voiceField.delegate = self;
    [self.container addSubview:self.voiceField];

    // Format control
    self.formatControl = [[UISegmentedControl alloc] initWithItems:@[@"WAV (44.1k)", @"M4A"]];
    self.formatControl.selectedSegmentIndex = 0;
    [self.container addSubview:self.formatControl];

    // Fetch voices button
    self.fetchVoicesButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.fetchVoicesButton setTitle:@"Fetch Voices" forState:UIControlStateNormal];
    self.fetchVoicesButton.layer.cornerRadius = 8;
    self.fetchVoicesButton.backgroundColor = [UIColor systemBlueColor];
    [self.fetchVoicesButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.fetchVoicesButton.layer.shadowColor = [UIColor systemBlueColor].CGColor;
    self.fetchVoicesButton.layer.shadowOpacity = 0.25;
    self.fetchVoicesButton.layer.shadowOffset = CGSizeMake(0,4);
    self.fetchVoicesButton.layer.shadowRadius = 8;
    [self.fetchVoicesButton addTarget:self action:@selector(fetchVoicesTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.container addSubview:self.fetchVoicesButton];

    // Play & Download buttons
    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.playButton setTitle:@"Synthesize & Play" forState:UIControlStateNormal];
    self.playButton.layer.cornerRadius = 8;
    self.playButton.backgroundColor = [UIColor systemGray5Color];
    [self.playButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.playButton.layer.borderWidth = 0.5;
    self.playButton.layer.borderColor = [UIColor systemGray3Color].CGColor;
    self.playButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.playButton.layer.shadowOpacity = 0.07;
    self.playButton.layer.shadowOffset = CGSizeMake(0,3);
    self.playButton.layer.shadowRadius = 6;
    [self.playButton addTarget:self action:@selector(synthesizeAndPlay:) forControlEvents:UIControlEventTouchUpInside];
    [self.container addSubview:self.playButton];

    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.downloadButton setTitle:@"Synthesize & Download" forState:UIControlStateNormal];
    self.downloadButton.layer.cornerRadius = 8;
    self.downloadButton.backgroundColor = [UIColor systemGray5Color];
    [self.downloadButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.downloadButton.layer.borderWidth = 0.5;
    self.downloadButton.layer.borderColor = [UIColor systemGray3Color].CGColor;
    self.downloadButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.downloadButton.layer.shadowOpacity = 0.07;
    self.downloadButton.layer.shadowOffset = CGSizeMake(0,3);
    self.downloadButton.layer.shadowRadius = 6;
    [self.downloadButton addTarget:self action:@selector(synthesizeAndDownload:) forControlEvents:UIControlEventTouchUpInside];
    [self.container addSubview:self.downloadButton];

    // Speed label + slider (ElevenLabs speed: 0.7 = slowest, 1.2 = fastest)
    self.speedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.speedLabel.text = @"Speed: 1.00×";
    self.speedLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.speedLabel.textAlignment = NSTextAlignmentCenter;
    self.speedLabel.textColor = [UIColor secondaryLabelColor];
    [self.container addSubview:self.speedLabel];

    self.speedSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.speedSlider.minimumValue = 0.7f;
    self.speedSlider.maximumValue = 1.2f;
    self.speedSlider.value = 1.0f;
    self.speedSlider.minimumValueImage = [UIImage systemImageNamed:@"tortoise.fill"];
    self.speedSlider.maximumValueImage = [UIImage systemImageNamed:@"hare.fill"];
    [self.speedSlider addTarget:self
                         action:@selector(speedSliderChanged:)
               forControlEvents:UIControlEventValueChanged];
    [self.container addSubview:self.speedSlider];

    // Spinner
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [self.container addSubview:self.spinner];

    // Voices table
    self.voicesTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.voicesTable.delegate = self;
    self.voicesTable.dataSource = self;
    self.voicesTable.layer.cornerRadius = 10;
    self.voicesTable.layer.borderWidth = 1.0;
    self.voicesTable.layer.borderColor = [UIColor systemGray4Color].CGColor;
    self.voicesTable.estimatedRowHeight = 56;
    [self.view addSubview:self.voicesTable];

    self.voices = @[];
    self.stopMeterTimer = nil;

    // Dismiss keyboard when tapping outside the text view
    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:dismissTap];

    // Keyboard avoidance — shift the container up so buttons stay visible
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardWillShow:)
        name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardWillHide:)
        name:UIKeyboardWillHideNotification object:nil];

    EZLog(EZLogLevelInfo, @"TTS_UI", @"TextToSpeechViewController loaded");
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self invalidateStopMeterTimer];
    [self.player stop];
    self.player = nil;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"elevenVoiceID"];
    if (saved.length > 0 && self.voiceField.text.length == 0) {
        self.voiceField.text = saved;
    }
    if (self.voices.count == 0 && [EZAuthManager shared].isLoggedIn) {
        [self fetchVoicesTapped:nil];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat topInset = self.view.safeAreaInsets.top + 12;
    CGFloat side = 16;
    CGFloat containerWidth = self.view.bounds.size.width - side*2;
    CGFloat y = topInset;

    CGFloat containerHeight = 424;
    self.container.frame = CGRectMake(side, y, containerWidth, containerHeight);

    CGFloat innerX = 12;
    CGFloat innerW = containerWidth - innerX*2;
    CGFloat curY = 12;

    self.textView.frame = CGRectMake(innerX, curY, innerW, 140);
    curY += 140 + 12;

    self.voiceField.frame = CGRectMake(innerX, curY, innerW, 36);
    curY += 36 + 10;

    self.formatControl.frame = CGRectMake(innerX, curY, innerW, 34);
    curY += 34 + 10;

    self.fetchVoicesButton.frame = CGRectMake(innerX, curY, innerW, 44);
    curY += 44 + 10;

    // Speed label
    self.speedLabel.frame = CGRectMake(innerX, curY, innerW, 18);
    curY += 18 + 4;

    // Speed slider
    self.speedSlider.frame = CGRectMake(innerX, curY, innerW, 28);
    curY += 28 + 12;

    CGFloat btnW = (innerW - 10) / 2.0;
    self.playButton.frame = CGRectMake(innerX, curY, btnW, 44);
    self.downloadButton.frame = CGRectMake(innerX + btnW + 10, curY, btnW, 44);
    curY += 44 + 12;

    self.spinner.center = CGPointMake(self.container.frame.origin.x + containerWidth/2.0, self.container.frame.origin.y + containerHeight - 28);

    CGFloat tableY = CGRectGetMaxY(self.container.frame) + 12;
    CGFloat tableH = self.view.bounds.size.height - tableY - self.view.safeAreaInsets.bottom - 12;
    if (tableH < 120) tableH = 120;
    self.voicesTable.frame = CGRectMake(side, tableY, containerWidth, tableH);
}

#pragma mark - Timer helpers (fix for your invalidate error)

- (void)startStopMeterTimerWithInterval:(NSTimeInterval)interval selector:(SEL)selector {
    // Ensure previous is invalidated
    [self invalidateStopMeterTimer];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.stopMeterTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:selector userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.stopMeterTimer forMode:NSRunLoopCommonModes];
    });
}

- (void)invalidateStopMeterTimer {
    if (self.stopMeterTimer) {
        [self.stopMeterTimer invalidate];
        self.stopMeterTimer = nil;
        EZLog(EZLogLevelDebug, @"TIMER", @"stopMeterTimer invalidated");
    }
}

#pragma mark - Buttons

- (void)speedSliderChanged:(UISlider *)slider {
    // Snap to nearest 0.05
    float snapped = roundf(slider.value / 0.05f) * 0.05f;
    slider.value = snapped;
    self.speedLabel.text = [NSString stringWithFormat:@"Speed: %.2f×", snapped];
}

- (void)fetchVoicesTapped:(id)sender {
    [self setLoading:YES];

    NSString *token = [EZAuthManager shared].accessToken;
    if (token.length == 0) {
        [self setLoading:NO];
        [self showAlert:@"Not logged in" message:@"Please sign in to fetch voices."];
        return;
    }

    NSURL *url = [NSURL URLWithString:
        @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-elevenlabs"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"action": @"fetch_voices"}
                                                  options:0 error:nil];

    EZLog(EZLogLevelInfo, @"TTS", @"Fetching voices via Edge Function");

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoading:NO];
            if (err) {
                [self showAlert:@"Network error" message:err.localizedDescription];
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
            if (http.statusCode == 402) {
                [self showAlert:@"Insufficient coins"
                        message:@"You don't have enough coins for this action."];
                return;
            }
            if (http.statusCode == 403) {
                [self showAlert:@"Not authorized"
                        message:@"Please sign in and try again."];
                return;
            }
            if (http.statusCode != 200) {
                NSString *msg = data.length
                    ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                    : @"Server error";
                [self showAlert:@"Error" message:msg];
                return;
            }

            NSError *jerr;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jerr];
            if (jerr) {
                [self showAlert:@"Parse error" message:jerr.localizedDescription];
                return;
            }

            NSArray *voicesArray = nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                voicesArray = json[@"voices"];
            } else if ([json isKindOfClass:[NSArray class]]) {
                voicesArray = json;
            }

            if (!voicesArray) {
                [self showAlert:@"Unexpected response"
                        message:@"Voices response format was unexpected."];
                return;
            }

            NSMutableArray *safe = [NSMutableArray array];
            for (id item in voicesArray) {
                if ([item isKindOfClass:[NSDictionary class]]) [safe addObject:item];
            }
            self.voices = [safe copy];
            [self.voicesTable reloadData];
            EZLogf(EZLogLevelInfo, @"TTS", @"Fetched %lu voices",
                   (unsigned long)self.voices.count);
            if (self.voices.count == 0) {
                [self showAlert:@"No voices" message:@"No voices returned."];
            }
        });
    }] resume];
}

#pragma mark - Synthesize actions

- (void)synthesizeAndPlay:(id)sender {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    if (text.length == 0) { [self showAlert:@"Missing text" message:@"Please enter text to synthesize."]; return; }
    [self setLoading:YES];
    [self performTTSWithText:text preferredFormat:nil completion:^(NSURL *fileURL, NSString *mime, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoading:NO];
            if (err) {
                [self showAlert:@"TTS Error" message:err.localizedDescription ?: @"Failed to synthesize."];
                return;
            }
            if (!fileURL) {
                [self showAlert:@"TTS Error" message:@"No audio returned."];
                return;
            }
            NSError *perr = nil;
            self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&perr];
            if (perr) {
                EZLogf(EZLogLevelError, @"TTS", @"Playback error: %@", perr.localizedDescription);
                [self showAlert:@"Playback error" message:perr.localizedDescription ?: @"Unable to play audio."];
                return;
            }
            [self.player prepareToPlay];
            [self.player play];
            EZLogf(EZLogLevelInfo, @"TTS", @"Playback started %@", fileURL.lastPathComponent);
        });
    }];
}

- (void)synthesizeAndDownload:(id)sender {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    if (text.length == 0) { [self showAlert:@"Missing text" message:@"Please enter text to synthesize."]; return; }

    BOOL userWantsWAV = (self.formatControl.selectedSegmentIndex == 0);
    NSString *requestFormat = userWantsWAV ? @"wav_44100" : kFallbackMP3Format;

    [self setLoading:YES];
    [self performTTSWithText:text preferredFormat:requestFormat completion:^(NSURL *fileURL, NSString *mime, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoading:NO];
            if (err) {
                [self showAlert:@"TTS Error" message:err.localizedDescription ?: @"Failed to synthesize."];
                return;
            }
            if (!fileURL) {
                [self showAlert:@"TTS Error" message:@"No audio returned."];
                return;
            }

            // If user requested M4A but server returned MP3, convert
            if (!userWantsWAV && [[fileURL.pathExtension lowercaseString] isEqualToString:@"mp3"]) {
                [self setLoading:YES];
                [self convertToM4AFromURL:fileURL completion:^(NSURL *m4aURL, NSError *convErr) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self setLoading:NO];
                        NSURL *shareURL = m4aURL ?: fileURL;
                        UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[shareURL] applicationActivities:nil];
                        avc.popoverPresentationController.sourceView = self.downloadButton;
                        [self presentViewController:avc animated:YES completion:nil];
                        if (convErr) {
                            EZLogf(EZLogLevelWarning, @"TTS", @"M4A conversion failed: %@", convErr.localizedDescription);
                        } else {
                            EZLog(EZLogLevelInfo, @"TTS", @"Converted and offered M4A");
                        }
                    });
                }];
                return;
            }

            if (userWantsWAV && ![[fileURL.pathExtension lowercaseString] isEqualToString:@"wav"]) {
                [self showAlert:@"Note" message:@"Uncompressed WAV requires Creator/Pro on ElevenLabs. Downloading highest-available MP3 instead."];
            }

            UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
            avc.popoverPresentationController.sourceView = self.downloadButton;
            [self presentViewController:avc animated:YES completion:nil];
            EZLogf(EZLogLevelInfo, @"TTS", @"Presented download for %@", fileURL.lastPathComponent);
        });
    }];
}

#pragma mark - Core: TTS with retry/fallback
/*
- (NSString *)elevenLabsAPIKey {
    NSString *key = [EZKeyVault loadKeyForIdentifier:EZVaultKeyElevenLabs];
    if (!key) EZLog(EZLogLevelWarning, @"TTS", @"Missing ElevenLabs API key in EZKeyVault");
    return key;
}
*/
/// Perform TTS; preferredFormat examples: @"wav_44100", @"mp3_44100_192", @"mp3_44100_128", or nil
// No longer needed — remove this method entirely
// - (NSString *)elevenLabsAPIKey { ... }

// ── Core: TTS via Supabase Edge Function ─────────────────────────────────────
- (void)performTTSWithText:(NSString *)text
           preferredFormat:(NSString * _Nullable)preferredFormat
                completion:(void(^)(NSURL *fileURL, NSString *mime, NSError *err))completion
{
    NSString *token = [EZAuthManager shared].accessToken;
    if (token.length == 0) {
        completion(nil, nil, [NSError errorWithDomain:@"TTS" code:401
            userInfo:@{NSLocalizedDescriptionKey: @"Not logged in."}]);
        return;
    }

    NSString *voiceID = (self.voiceField.text.length > 0)
        ? self.voiceField.text : kDefaultVoiceID;
    NSString *fmt = preferredFormat.length > 0 ? preferredFormat : kFallbackMP3Format;

    // Snap speed to 2 decimal places matching slider steps
    float speed = roundf(self.speedSlider.value / 0.05f) * 0.05f;
    NSUInteger charCount = text.length;

    NSURL *url = [NSURL URLWithString:
        @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-elevenlabs"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 80;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"action":        @"tts",
        @"text":          text ?: @"",
        @"voice_id":      voiceID,
        @"output_format": fmt,
        @"speed":         @(speed),
        @"char_count":    @(charCount)
    } options:0 error:nil];

    EZLogf(EZLogLevelInfo, @"TTS",
           @"Requesting via Edge Function voice=%@ format=%@ speed=%.2f chars=%lu",
           voiceID, fmt, speed, (unsigned long)charCount);

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest  = 80;
    cfg.timeoutIntervalForResource = 160;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            EZLogf(EZLogLevelError, @"TTS", @"Network error: %@", error.localizedDescription);
            completion(nil, nil, error);
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode == 402) {
            // Parse balance/cost from response if available
            NSString *coinMsg = @"You don't have enough coins for this synthesis.";
            if (data.length) {
                NSDictionary *errJson = [NSJSONSerialization
                    JSONObjectWithData:data options:0 error:nil];
                if ([errJson isKindOfClass:[NSDictionary class]]) {
                    NSNumber *bal  = errJson[@"balance"];
                    NSNumber *cost = errJson[@"cost"];
                    if (bal && cost) {
                        coinMsg = [NSString stringWithFormat:
                            @"Need %@ coins, you have %@.", cost, bal];
                    }
                }
            }
            completion(nil, nil, [NSError errorWithDomain:@"TTS" code:402
                userInfo:@{NSLocalizedDescriptionKey: coinMsg}]);
            return;
        }
        if (http.statusCode == 403) {
            completion(nil, nil, [NSError errorWithDomain:@"TTS" code:403
                userInfo:@{NSLocalizedDescriptionKey: @"Not authorized. Please sign in again."}]);
            return;
        }
        if (http.statusCode != 200) {
            NSString *msg = data.length
                ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                : @"Server error";
            completion(nil, nil, [NSError errorWithDomain:@"TTS" code:http.statusCode
                userInfo:@{NSLocalizedDescriptionKey: msg}]);
            return;
        }

        NSError *jerr;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                             options:0 error:&jerr];
        if (jerr || !json[@"audio_b64"]) {
            completion(nil, nil, [NSError errorWithDomain:@"TTS" code:-1
                userInfo:@{NSLocalizedDescriptionKey: @"Invalid response from server."}]);
            return;
        }

        NSData *audioData = [[NSData alloc]
            initWithBase64EncodedString:json[@"audio_b64"] options:0];
        if (!audioData || audioData.length == 0) {
            completion(nil, nil, [NSError errorWithDomain:@"TTS" code:-2
                userInfo:@{NSLocalizedDescriptionKey: @"Empty audio returned."}]);
            return;
        }

        NSString *returnedFmt  = json[@"format"] ?: fmt;
        NSString *returnedMime = json[@"mime_type"] ?: @"audio/mpeg";
        NSString *ext = [returnedFmt containsString:@"wav"] ? @"wav" :
                        [returnedFmt containsString:@"mp3"] ? @"mp3" : @"mp3";

        // If PCM wrap into WAV
        if ([returnedFmt containsString:@"pcm"] && [returnedFmt containsString:@"44100"]) {
            NSData *wavData = [self wavDataFromPCM:audioData
                                        sampleRate:44100
                                          channels:1
                                    bitsPerSample:16];
            if (!wavData) {
                completion(nil, nil, [NSError errorWithDomain:@"TTS" code:-3
                    userInfo:@{NSLocalizedDescriptionKey: @"Failed to wrap PCM into WAV."}]);
                return;
            }
            audioData = wavData;
            ext = @"wav";
            returnedMime = @"audio/wav";
        }

        NSString *fname  = [NSString stringWithFormat:@"tts_%@.%@", timestampString(), ext];
        NSURL    *tmpURL = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:fname]];
        NSError  *werr;
        [audioData writeToURL:tmpURL options:NSDataWritingAtomic error:&werr];
        if (werr) {
            completion(nil, nil, werr);
            return;
        }

        EZLogf(EZLogLevelInfo, @"TTS", @"Audio saved: %@", fname);
        completion(tmpURL, returnedMime, nil);

    }] resume];
}

#pragma mark - Conversion helpers

- (void)convertToM4AFromURL:(NSURL *)srcURL completion:(void(^)(NSURL *m4aURL, NSError *err))completion {
    if (!srcURL) {
        completion(nil, [NSError errorWithDomain:@"TTS" code:-10 userInfo:@{NSLocalizedDescriptionKey: @"Source file missing."}]);
        return;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:srcURL options:nil];
    if (![[AVAssetExportSession exportPresetsCompatibleWithAsset:asset] containsObject:AVAssetExportPresetAppleM4A]) {
        NSError *e = [NSError errorWithDomain:@"TTS" code:-11 userInfo:@{NSLocalizedDescriptionKey: @"M4A export not supported on this device."}];
        completion(nil, e);
        return;
    }
    NSString *dstName = [[srcURL.lastPathComponent stringByDeletingPathExtension] stringByAppendingPathExtension:@"m4a"];
    NSURL *dstURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:dstName]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:dstURL.path]) {
        [[NSFileManager defaultManager] removeItemAtURL:dstURL error:nil];
    }
    AVAssetExportSession *exp = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    exp.outputURL = dstURL;
    exp.outputFileType = AVFileTypeAppleM4A;
    exp.shouldOptimizeForNetworkUse = YES;
    [exp exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (exp.status == AVAssetExportSessionStatusCompleted) {
                EZLogf(EZLogLevelInfo, @"TTS", @"M4A conversion done: %@", dstURL.lastPathComponent);
                completion(dstURL, nil);
            } else {
                NSError *err = exp.error ?: [NSError errorWithDomain:@"TTS" code:-12 userInfo:@{NSLocalizedDescriptionKey: @"M4A conversion failed."}];
                EZLogf(EZLogLevelError, @"TTS", @"M4A conversion error: %@", err.localizedDescription);
                completion(nil, err);
            }
        });
    }];
}

// Wrap PCM (signed 16-bit little-endian) into WAV container using proper little-endian headers
- (NSData *)wavDataFromPCM:(NSData *)pcm sampleRate:(int)sampleRate channels:(short)channels bitsPerSample:(short)bitsPerSample {
    if (!pcm) return nil;

    uint32_t pcmDataLen = (uint32_t)pcm.length;
    uint16_t audioFormat = 1; // PCM
    uint16_t numChannels = channels;
    uint32_t byteRate = sampleRate * channels * (bitsPerSample / 8);
    uint16_t blockAlign = channels * (bitsPerSample / 8);
    uint32_t chunkSize = 36 + pcmDataLen;
    uint32_t subchunk1Size = 16;

    uint32_t chunkSizeLE = CFSwapInt32HostToLittle(chunkSize);
    uint32_t subchunk1SizeLE = CFSwapInt32HostToLittle(subchunk1Size);
    uint16_t audioFormatLE = CFSwapInt16HostToLittle(audioFormat);
    uint16_t channelsLE = CFSwapInt16HostToLittle(numChannels);
    uint32_t sampleRateLE = CFSwapInt32HostToLittle((uint32_t)sampleRate);
    uint32_t byteRateLE = CFSwapInt32HostToLittle(byteRate);
    uint16_t blockAlignLE = CFSwapInt16HostToLittle(blockAlign);
    uint16_t bitsPerSampleLE = CFSwapInt16HostToLittle(bitsPerSample);
    uint32_t dataLenLE = CFSwapInt32HostToLittle(pcmDataLen);

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + pcmDataLen];

    // RIFF header
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&chunkSizeLE length:4];
    [wav appendBytes:"WAVE" length:4];

    // fmt chunk
    [wav appendBytes:"fmt " length:4];
    [wav appendBytes:&subchunk1SizeLE length:4];
    [wav appendBytes:&audioFormatLE length:2];
    [wav appendBytes:&channelsLE length:2];
    [wav appendBytes:&sampleRateLE length:4];
    [wav appendBytes:&byteRateLE length:4];
    [wav appendBytes:&blockAlignLE length:2];
    [wav appendBytes:&bitsPerSampleLE length:2];

    // data chunk
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataLenLE length:4];

    [wav appendData:pcm];
    return wav;
}

#pragma mark - Table view (voices)

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.voices.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"VoiceCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *voice = self.voices[indexPath.row];
    NSString *name = voice[@"name"] ?: voice[@"voice_name"] ?: @"(unnamed)";
    NSString *vid = voice[@"voice_id"] ?: voice[@"id"] ?: voice[@"voiceId"] ?: @"";
    cell.textLabel.text = name;
    NSString *subtitle = vid.length ? vid : @"";
    BOOL isCustom = NO;
    if (voice[@"is_custom"]) {
        isCustom = [voice[@"is_custom"] boolValue];
    } else if (voice[@"type"]) {
        NSString *type = [NSString stringWithFormat:@"%@", voice[@"type"]];
        isCustom = ([type.lowercaseString containsString:@"custom"] || [type.lowercaseString containsString:@"clone"]);
    }
    if (isCustom) {
        subtitle = [subtitle stringByAppendingString:(subtitle.length ? @" • " : @"")];
        subtitle = [subtitle stringByAppendingString:@"custom"];
        cell.imageView.image = [self smallBadgeImageWithColor:[UIColor systemPurpleColor]];
    } else {
        cell.imageView.image = [self smallBadgeImageWithColor:[UIColor systemTealColor]];
    }
    cell.detailTextLabel.text = subtitle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
     [tableView deselectRowAtIndexPath:indexPath animated:YES];
     NSDictionary *voice = self.voices[indexPath.row];
     NSString *vid = voice[@"voice_id"] ?: voice[@"id"] ?: voice[@"voiceId"] ?: @"";
     if (vid.length == 0) {
         [self showAlert:@"No voice id" message:@"Selected voice had no usable id."];
         return;
     }
     self.voiceField.text = vid;
     // Persist so the voice survives leaving and returning to this VC
     [[NSUserDefaults standardUserDefaults] setObject:vid forKey:@"elevenVoiceID"];
     EZLogf(EZLogLevelInfo, @"TTS", @"Selected voice %@ (%@)", voice[@"name"] ?: @"", vid);
     [self showAlert:@"Voice selected" message:[NSString stringWithFormat:@"Using voice: %@", voice[@"name"] ?: vid]];
}

- (UIImage *)smallBadgeImageWithColor:(UIColor *)c {
    CGSize s = CGSizeMake(28,28);
    UIGraphicsBeginImageContextWithOptions(s, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, c.CGColor);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0,0,s.width,s.height) cornerRadius:6];
    [path fill];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    // Persist any manually typed voice ID on return
    if (textField == self.voiceField && textField.text.length > 0) {
        [[NSUserDefaults standardUserDefaults] setObject:textField.text forKey:@"elevenVoiceID"];
    }
    return YES;
}

#pragma mark - Keyboard handling

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    CGRect kbFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat kbH = kbFrame.size.height;
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        // Slide container up just enough that the buttons clear the keyboard
        CGFloat visibleH = self.view.bounds.size.height - kbH;
        CGFloat containerBottom = self.container.frame.origin.y + self.container.frame.size.height;
        if (containerBottom > visibleH - 12) {
            CGFloat shift = containerBottom - (visibleH - 12);
            CGRect f = self.container.frame;
            f.origin.y -= shift;
            if (f.origin.y < self.view.safeAreaInsets.top + 4) f.origin.y = self.view.safeAreaInsets.top + 4;
            self.container.frame = f;
            // Hide voices table while keyboard is up — it would be obscured anyway
            self.voicesTable.alpha = 0;
        }
    }];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        // Let viewDidLayoutSubviews restore the original position
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        self.voicesTable.alpha = 1;
    }];
}

#pragma mark - UI helpers

- (void)setLoading:(BOOL)loading {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.view.userInteractionEnabled = !loading;
        if (loading) {
            [self.spinner startAnimating];
        } else {
            [self.spinner stopAnimating];
        }
    });
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    EZLogf(EZLogLevelInfo, @"UI", @"%@ — %@", title, message ?: @"");
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:ac animated:YES completion:nil];
    });
}

@end
