//
// TextToSpeechViewController.m
// EZCompleteUI v1.1
//
// Purpose: standalone "type text, pick a voice, synthesize" screen — distinct
// from the auto-read-AI-response flow in ViewController.m's speakLastResponse.
// ElevenLabs TTS integration via the ez-elevenlabs Supabase Edge Function,
// voice selection via a picker (never displays a raw voice ID — only names),
// auto-archives every successful generation to EZTTSLibraryManager, and plays
// it back with one big Play button. Downloading was removed as a separate
// action since everything is already saved automatically — use History's
// Share action for exporting a clip.
//
// Changes from v1.0:
//   - kPromptCharacterLimit doubled, 120 → 240. The old value predates a fix
//     to ez-elevenlabs' base64 encoding (see that file's v6.6 changelog): the
//     edge function used to crash on any audio beyond a few seconds, and
//     120 characters (~8-10s of speech, ~130-160KB of mp3) was already past
//     that threshold — so 120 was almost certainly chosen as a defensive
//     workaround for the crash, not a real UX or cost ceiling. That crash
//     is fixed; this cap can now track the model's actual limit instead.
//   - kDefaultModelID (eleven_multilingual_v2) actually allows up to 10,000
//     characters per request — same limit ViewController.m's
//     speakWithElevenLabsEdge and ez-elevenlabs' MAX_TTS_CHARS now enforce.
//     240 is a conservative first bump rather than jumping straight to
//     10,000; this is a dedicated "type text to synthesize" screen, so a
//     much higher cap is a reasonable next step if 240 still feels tight —
//     say the word and I'll raise it to match the other two files exactly.
//
// Requires helpers.h (EZLog / EZLogf) in the project.
// Link against AVFoundation and UIKit.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "helpers.h"
#import "EZAuthManager.h"
#import "EZTTSLibraryManager.h"
#import "EZTTSLibraryViewController.h"
#import "EZVoicePickerViewController.h"

static NSString * const kDefaultVoiceID = @"JBFqnCBsd6RMkjVDRZzb"; // fallback example
static NSString * const kDefaultModelID = @"eleven_v4";
static NSString * const kFallbackMP3Format = @"mp3_44100_128";
static NSString * const kVoiceIDDefaultsKey = @"elevenVoiceID";
static NSString * const kVoiceNameDefaultsKey = @"elevenVoiceName";
static NSString * const kPendingTTSRequestsDefaultsKey = @"EZTTSPendingRequests";

static NSUInteger const kPromptCharacterLimit = 2000;

@interface TextToSpeechViewController : UIViewController <UITextViewDelegate>
@end

@interface TextToSpeechViewController ()
@property (nonatomic, strong) UIView *container;
@property (nonatomic, strong) UILabel *promptSectionLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *charCountLabel;
@property (nonatomic, strong) UILabel *voiceSectionLabel;
@property (nonatomic, strong) UIButton *voiceButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) AVAudioPlayer *player;

// Timer added to address your invalidate error
@property (nonatomic, strong, nullable) NSTimer *stopMeterTimer;

// Speed slider (ElevenLabs speed param: 0.7–1.2)
@property (nonatomic, strong) UISlider *speedSlider;
@property (nonatomic, strong) UILabel  *speedLabel;

// Never displayed to the user as a raw string — only the resolved display name is
// ever shown, via -voiceButton. The id itself is what's actually sent to the API.
@property (nonatomic, copy) NSString *selectedVoiceID;
@property (nonatomic, copy, nullable) NSString *selectedVoiceName;

// Set via -prefillWithText:voiceID:voiceName: (e.g. from History's Regenerate/Change
// Voice) before the view has loaded; applied once the view's subviews actually exist.
@property (nonatomic, copy, nullable) NSString *pendingPrefillText;
@property (nonatomic, copy, nullable) NSString *pendingPrefillVoiceID;
@property (nonatomic, copy, nullable) NSString *pendingPrefillVoiceName;
@property (nonatomic, assign) BOOL hasPendingVoicePrefill;
@end

@implementation TextToSpeechViewController

#pragma mark - Helpers

static NSString *timestampString(void) {
    long long t = (long long)[[NSDate date] timeIntervalSince1970];
    return [NSString stringWithFormat:@"%lld", t];
}

- (NSMutableDictionary<NSString *, NSDictionary *> *)pendingTTSRequests {
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:kPendingTTSRequestsDefaultsKey];
    return saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)rememberPendingTTSRequest:(NSString *)requestID
                              text:(NSString *)text
                           voiceID:(NSString *)voiceID
                    preferredFormat:(NSString *)format {
    if (!requestID.length) return;
    NSMutableDictionary *pending = [self pendingTTSRequests];
    pending[requestID] = @{
        @"text": text ?: @"",
        @"voice_id": voiceID ?: @"",
        @"format": format ?: kFallbackMP3Format,
    };
    [[NSUserDefaults standardUserDefaults] setObject:pending
                                              forKey:kPendingTTSRequestsDefaultsKey];
}

- (void)forgetPendingTTSRequest:(NSString *)requestID {
    if (!requestID.length) return;
    NSMutableDictionary *pending = [self pendingTTSRequests];
    [pending removeObjectForKey:requestID];
    [[NSUserDefaults standardUserDefaults] setObject:pending
                                              forKey:kPendingTTSRequestsDefaultsKey];
}

- (NSError *)ttsErrorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:@"TTS" code:code userInfo:@{
        NSLocalizedDescriptionKey: description ?: NSLocalizedString(@"EZTTS.FailedToSynthesize", nil)
    }];
}

- (void)downloadTTSAssetAtURLString:(NSString *)URLString
                          completion:(void(^)(NSData * _Nullable audioData, NSError * _Nullable error))completion {
    NSURL *URL = [NSURL URLWithString:URLString];
    if (!URL) {
        completion(nil, [self ttsErrorWithCode:-20 description:@"The generated audio download link was invalid."]);
        return;
    }
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = 45;
    configuration.timeoutIntervalForResource = 90;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    [[session dataTaskWithURL:URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (error) {
            completion(nil, error);
        } else if (http.statusCode < 200 || http.statusCode >= 300 || data.length == 0) {
            completion(nil, [self ttsErrorWithCode:http.statusCode ?: -21
                                        description:@"The generated audio could not be downloaded."]);
        } else {
            completion(data, nil);
        }
    }] resume];
}

- (void)recoverTTSRequestID:(NSString *)requestID
                       token:(NSString *)token
                     attempt:(NSInteger)attempt
                  completion:(void(^)(NSData * _Nullable audioData,
                                      NSString * _Nullable format,
                                      NSString * _Nullable mime,
                                      NSError * _Nullable error))completion {
    NSURL *URL = [NSURL URLWithString:@"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-elevenlabs"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 45;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"action": @"recover_tts",
        @"request_id": requestID,
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, nil, nil, error);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        // A request can arrive while the original invocation is still writing
        // its private object. Retry briefly; this is free and never regenerates.
        if (http.statusCode == 202 && attempt < 6) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [self recoverTTSRequestID:requestID token:token attempt:attempt + 1 completion:completion];
            });
            return;
        }
        NSString *assetURL = [json[@"audio_url"] isKindOfClass:[NSString class]] ? json[@"audio_url"] : nil;
        if (http.statusCode != 200 || assetURL.length == 0) {
            NSString *message = [json[@"reason"] isKindOfClass:[NSString class]] ? json[@"reason"] :
                                @"The generated audio could not be recovered.";
            completion(nil, nil, nil, [self ttsErrorWithCode:http.statusCode ?: -22 description:message]);
            return;
        }
        [self downloadTTSAssetAtURLString:assetURL completion:^(NSData *audioData, NSError *downloadError) {
            completion(audioData, json[@"format"], json[@"mime_type"], downloadError);
        }];
    }] resume];
}

- (void)writeAndArchiveTTSData:(NSData *)audioData
                         format:(NSString *)returnedFmt
                           mime:(NSString *)returnedMime
                           text:(NSString *)text
                        voiceID:(NSString *)voiceID
                     completion:(void(^)(NSURL * _Nullable fileURL, NSString * _Nullable mime, NSError * _Nullable error))completion {
    if (!audioData.length) {
        completion(nil, nil, [self ttsErrorWithCode:-2 description:NSLocalizedString(@"EZTTS.EmptyAudio", nil)]);
        return;
    }
    NSString *format = returnedFmt.length ? returnedFmt : kFallbackMP3Format;
    NSString *mime = returnedMime.length ? returnedMime : @"audio/mpeg";
    NSString *extension = [format containsString:@"wav"] ? @"wav" :
                         [format containsString:@"mp3"] ? @"mp3" : @"mp3";

    // If PCM wrap into WAV.
    if ([format containsString:@"pcm"] && [format containsString:@"44100"]) {
        NSData *wavData = [self wavDataFromPCM:audioData sampleRate:44100 channels:1 bitsPerSample:16];
        if (!wavData) {
            completion(nil, nil, [self ttsErrorWithCode:-3 description:NSLocalizedString(@"EZTTS.FailedWavWrap", nil)]);
            return;
        }
        audioData = wavData;
        extension = @"wav";
        mime = @"audio/wav";
    }

    NSString *filename = [NSString stringWithFormat:@"tts_%@.%@", timestampString(), extension];
    NSURL *temporaryURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
    NSError *writeError = nil;
    [audioData writeToURL:temporaryURL options:NSDataWritingAtomic error:&writeError];
    if (writeError) {
        completion(nil, nil, writeError);
        return;
    }
    [self archiveGeneratedAudio:audioData extension:extension prompt:text voiceID:voiceID];
    EZLogf(EZLogLevelInfo, @"TTS", @"Audio saved: %@", filename);
    completion(temporaryURL, mime, nil);
}

- (void)recoverPendingTTSRequestsIfNeeded {
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token.length) return;

    NSDictionary<NSString *, NSDictionary *> *pending = [[self pendingTTSRequests] copy];
    [pending enumerateKeysAndObjectsUsingBlock:^(NSString *requestID, NSDictionary *details, BOOL *stop) {
        (void)stop;
        [self recoverTTSRequestID:requestID token:token attempt:0
                        completion:^(NSData *audioData, NSString *format, NSString *mime, NSError *error) {
            if (audioData.length) {
                [self writeAndArchiveTTSData:audioData
                                      format:format ?: details[@"format"]
                                        mime:mime
                                        text:details[@"text"] ?: @"Recovered TTS"
                                     voiceID:details[@"voice_id"] ?: @""
                                  completion:^(NSURL *fileURL, NSString *savedMime, NSError *writeError) {
                    (void)fileURL;
                    (void)savedMime;
                    if (!writeError) {
                        [self forgetPendingTTSRequest:requestID];
                        EZLogf(EZLogLevelInfo, @"TTS", @"Recovered interrupted generation %@", requestID);
                    }
                }];
            } else if (error.code == 404 || error.code == 409) {
                // No durable object exists (for example, this was made by an
                // older server before recovery was available), so don't retry
                // this stale id on every visit to the screen.
                [self forgetPendingTTSRequest:requestID];
            }
        }];
    }];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedString(@"EZTTS.Title", nil);
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"clock.arrow.circlepath"]
                 style:UIBarButtonItemStylePlain
                target:self
                action:@selector(historyButtonTapped)];

    NSString *savedID = [[NSUserDefaults standardUserDefaults] stringForKey:kVoiceIDDefaultsKey];
    self.selectedVoiceID = savedID.length > 0 ? savedID : kDefaultVoiceID;
    self.selectedVoiceName = [[NSUserDefaults standardUserDefaults] stringForKey:kVoiceNameDefaultsKey];

    // Container view (styled)
    self.container = [[UIView alloc] initWithFrame:CGRectZero];
    self.container.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.container.layer.cornerRadius = 16.0;
    self.container.layer.borderWidth = 1.0;
    self.container.layer.borderColor = [UIColor systemGray4Color].CGColor;
    self.container.layer.shadowColor = [UIColor colorWithRed:0 green:0.48 blue:1 alpha:0.15].CGColor;
    self.container.layer.shadowOpacity = 1.0;
    self.container.layer.shadowOffset = CGSizeMake(0, 6);
    self.container.layer.shadowRadius = 18;
    [self.view addSubview:self.container];

    self.promptSectionLabel = [self sectionHeaderLabel];
    self.promptSectionLabel.text = NSLocalizedString(@"EZTTS.PromptHeader", nil);
    [self.container addSubview:self.promptSectionLabel];

    // TextView
    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.font = [UIFont systemFontOfSize:16];
    self.textView.layer.cornerRadius = 12;
    self.textView.layer.borderWidth = 1.0;
    self.textView.layer.borderColor = [UIColor systemGray4Color].CGColor;
    self.textView.backgroundColor = [UIColor systemBackgroundColor];
    self.textView.textContainerInset = UIEdgeInsetsMake(14, 12, 14, 12);
    self.textView.delegate = self;
    [self.container addSubview:self.textView];

    // Character counter, bottom-right under the text input. Limit tracks
    // kPromptCharacterLimit — see the v1.1 changelog at the top of this file
    // for why 120 became 240 (it was never a real ceiling, just a defensive
    // cap around a since-fixed crash in ez-elevenlabs' base64 encoding).
    self.charCountLabel = [[UILabel alloc] init];
    self.charCountLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.charCountLabel.textColor = [UIColor secondaryLabelColor];
    self.charCountLabel.textAlignment = NSTextAlignmentRight;
    [self.container addSubview:self.charCountLabel];
    [self updateCharCountLabel];

    self.voiceSectionLabel = [self sectionHeaderLabel];
    self.voiceSectionLabel.text = NSLocalizedString(@"EZTTS.VoiceHeader", nil);
    [self.container addSubview:self.voiceSectionLabel];

    // Voice picker button — never shows a raw voice ID, only the resolved name.
    self.voiceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.voiceButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.voiceButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.voiceButton.backgroundColor = [UIColor systemBackgroundColor];
    self.voiceButton.layer.cornerRadius = 12;
    self.voiceButton.layer.borderWidth = 1.0;
    self.voiceButton.layer.borderColor = [UIColor systemGray4Color].CGColor;
    self.voiceButton.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
    [self updateVoiceButtonTitle];
    [self.voiceButton addTarget:self action:@selector(voiceButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.container addSubview:self.voiceButton];

    // Speed label + slider (ElevenLabs speed: 0.7 = slowest, 1.2 = fastest)
    self.speedLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.speedLabel.text = NSLocalizedString(@"EZTTS.SpeedFormat", nil);
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

    // One big, obvious primary action — everything generated is archived automatically,
    // so there's no separate Download button anymore; Play is the whole interaction.
    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *playConfig = [UIButtonConfiguration filledButtonConfiguration];
    playConfig.title = NSLocalizedString(@"EZTTS.Generate", nil);
    playConfig.image = [UIImage systemImageNamed:@"play.fill"];
    playConfig.imagePadding = 8;
    playConfig.baseBackgroundColor = [UIColor systemBlueColor];
    playConfig.baseForegroundColor = [UIColor whiteColor];
    playConfig.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    playConfig.titleTextAttributesTransformer =
        ^NSDictionary<NSAttributedStringKey,id> * _Nonnull(NSDictionary<NSAttributedStringKey,id> * _Nonnull attrs) {
        NSMutableDictionary *m = [attrs mutableCopy];
        m[NSFontAttributeName] = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
        return m;
    };
    self.playButton.configuration = playConfig;
    self.playButton.layer.shadowColor = [UIColor systemBlueColor].CGColor;
    self.playButton.layer.shadowOpacity = 0.3;
    self.playButton.layer.shadowOffset = CGSizeMake(0, 6);
    self.playButton.layer.shadowRadius = 12;
    [self.playButton addTarget:self action:@selector(synthesizeAndPlay:) forControlEvents:UIControlEventTouchUpInside];
    [self.container addSubview:self.playButton];

    // Spinner
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [self.container addSubview:self.spinner];

    self.stopMeterTimer = nil;

    // Dismiss keyboard when tapping outside the text view
    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:dismissTap];

    // Keyboard avoidance — shift the container up so the Play button stays visible
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardWillShow:)
        name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(keyboardWillHide:)
        name:UIKeyboardWillHideNotification object:nil];

    EZLog(EZLogLevelInfo, @"TTS_UI", @"TextToSpeechViewController loaded");

    [self applyPendingPrefillIfNeeded];
    [self recoverPendingTTSRequestsIfNeeded];
}

- (UILabel *)sectionHeaderLabel {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    return label;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self invalidateStopMeterTimer];
    [self.player stop];
    self.player = nil;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Nothing to fetch here anymore — the voice picker fetches for itself when opened.
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat topInset = self.view.safeAreaInsets.top + 12;
    CGFloat side = 16;
    CGFloat containerWidth = self.view.bounds.size.width - side * 2;

    CGFloat innerX = 16;
    CGFloat innerW = containerWidth - innerX * 2;
    CGFloat curY = 16;

    self.promptSectionLabel.frame = CGRectMake(innerX, curY, innerW, 14);
    curY += 14 + 6;

    self.textView.frame = CGRectMake(innerX, curY, innerW, 134);
    curY += 134 + 4;

    self.charCountLabel.frame = CGRectMake(innerX, curY, innerW, 16);
    curY += 16 + 16;

    self.voiceSectionLabel.frame = CGRectMake(innerX, curY, innerW, 14);
    curY += 14 + 6;

    self.voiceButton.frame = CGRectMake(innerX, curY, innerW, 48);
    curY += 48 + 20;

    self.speedLabel.frame = CGRectMake(innerX, curY, innerW, 18);
    curY += 18 + 4;

    self.speedSlider.frame = CGRectMake(innerX, curY, innerW, 28);
    curY += 28 + 24;

    self.playButton.frame = CGRectMake(innerX, curY, innerW, 58);
    curY += 58 + 16;

    // Container height derives from its actual content — no leftover empty space now
    // that the format picker, download button, fetch-voices button, and voices table
    // are all gone.
    CGFloat containerHeight = curY;
    self.container.frame = CGRectMake(side, topInset, containerWidth, containerHeight);

    self.spinner.center = CGPointMake(containerWidth / 2.0, containerHeight - 30);
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

#pragma mark - Voice picker

- (void)updateVoiceButtonTitle {
    NSString *display = self.selectedVoiceName.length > 0 ? self.selectedVoiceName : NSLocalizedString(@"EZTTS.ChooseVoice", nil);
    [self.voiceButton setTitle:[NSString stringWithFormat:@"🎙️  %@   ›", display] forState:UIControlStateNormal];
}

- (void)voiceButtonTapped {
    EZVoicePickerViewController *picker = [[EZVoicePickerViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    picker.onVoiceSelected = ^(NSString *voiceID, NSString * _Nullable voiceName) {
        weakSelf.selectedVoiceID = voiceID;
        weakSelf.selectedVoiceName = voiceName;
        [weakSelf updateVoiceButtonTitle];
        [[NSUserDefaults standardUserDefaults] setObject:voiceID forKey:kVoiceIDDefaultsKey];
        if (voiceName.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:voiceName forKey:kVoiceNameDefaultsKey];
        }
        EZLogf(EZLogLevelInfo, @"TTS", @"Selected voice %@ (%@)", voiceName ?: @"", voiceID);
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Buttons

- (void)speedSliderChanged:(UISlider *)slider {
    // Snap to nearest 0.05
    float snapped = roundf(slider.value / 0.05f) * 0.05f;
    slider.value = snapped;
    self.speedLabel.text = [NSString stringWithFormat:NSLocalizedString(@"EZTTS.SpeedFormat", nil), snapped];
}

#pragma mark - Character limit

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    NSUInteger newLength = textView.text.length - range.length + text.length;
    return newLength <= kPromptCharacterLimit;
}

- (void)textViewDidChange:(UITextView *)textView {
    [self updateCharCountLabel];
}

- (void)updateCharCountLabel {
    NSUInteger remaining = kPromptCharacterLimit - MIN(self.textView.text.length, kPromptCharacterLimit);
    self.charCountLabel.text = [NSString stringWithFormat:NSLocalizedString(@"EZTTS.CharactersRemaining", nil), (unsigned long)remaining];
    if (remaining <= 10) {
        self.charCountLabel.textColor = [UIColor systemRedColor];
    } else if (remaining <= 30) {
        self.charCountLabel.textColor = [UIColor systemOrangeColor];
    } else {
        self.charCountLabel.textColor = [UIColor secondaryLabelColor];
    }
}

#pragma mark - Synthesize actions

- (void)synthesizeAndPlay:(id)sender {
    NSString *text = [self.textView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    if (text.length == 0) { [self showAlert:NSLocalizedString(@"EZTTS.MissingTextTitle", nil) message:NSLocalizedString(@"EZTTS.MissingTextMessage", nil)]; return; }
    [self setLoading:YES];
    [self performTTSWithText:text preferredFormat:nil completion:^(NSURL *fileURL, NSString *mime, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoading:NO];
            if (err) {
                [self showAlert:NSLocalizedString(@"EZTTS.ErrorTitle", nil) message:err.localizedDescription ?: NSLocalizedString(@"EZTTS.FailedToSynthesize", nil)];
                return;
            }
            if (!fileURL) {
                [self showAlert:NSLocalizedString(@"EZTTS.ErrorTitle", nil) message:NSLocalizedString(@"EZTTS.NoAudioReturned", nil)];
                return;
            }

            NSError *sessionError = nil;
            if (!EZActivatePlaybackAudioSession(&sessionError)) {
                EZLogf(EZLogLevelError, @"TTS", @"Could not activate playback audio session: %@", sessionError.localizedDescription);
                [self showAlert:NSLocalizedString(@"EZTTS.PlaybackError", nil)
                         message:sessionError.localizedDescription ?: NSLocalizedString(@"EZTTS.UnableToPlay", nil)];
                return;
            }

            NSError *perr = nil;
            self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&perr];
            if (perr) {
                EZLogf(EZLogLevelError, @"TTS", @"Playback error: %@", perr.localizedDescription);
                [self showAlert:NSLocalizedString(@"EZTTS.PlaybackError", nil) message:perr.localizedDescription ?: NSLocalizedString(@"EZTTS.UnableToPlay", nil)];
                return;
            }
            [self.player prepareToPlay];
            if (![self.player play]) {
                EZLog(EZLogLevelError, @"TTS", @"AVAudioPlayer refused to start playback");
                [self showAlert:NSLocalizedString(@"EZTTS.PlaybackError", nil)
                         message:NSLocalizedString(@"EZTTS.UnableToPlay", nil)];
                return;
            }
            EZLogf(EZLogLevelInfo, @"TTS", @"Playback started %@", fileURL.lastPathComponent);
        });
    }];
}

#pragma mark - Core: TTS via Supabase Edge Function

/// Perform TTS; preferredFormat examples: @"wav_44100", @"mp3_44100_192", @"mp3_44100_128", or nil
- (void)performTTSWithText:(NSString *)text
           preferredFormat:(NSString * _Nullable)preferredFormat
                completion:(void(^)(NSURL *fileURL, NSString *mime, NSError *err))completion
{
    NSString *token = [EZAuthManager shared].accessToken;
    if (token.length == 0) {
        completion(nil, nil, [NSError errorWithDomain:@"TTS" code:401
            userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"EZTTS.NotLoggedIn", nil)}]);
        return;
    }

    NSString *voiceID = self.selectedVoiceID.length > 0 ? self.selectedVoiceID : kDefaultVoiceID;
    NSString *fmt = preferredFormat.length > 0 ? preferredFormat : kFallbackMP3Format;

    // Snap speed to 2 decimal places matching slider steps
    float speed = roundf(self.speedSlider.value / 0.05f) * 0.05f;
    NSUInteger charCount = text.length;
    NSString *requestID = [[NSUUID UUID] UUIDString];
    [self rememberPendingTTSRequest:requestID text:text voiceID:voiceID preferredFormat:fmt];

    void (^finishAudio)(NSData *, NSString *, NSString *) = ^(NSData *audioData, NSString *returnedFormat, NSString *returnedMime) {
        [self writeAndArchiveTTSData:audioData
                              format:returnedFormat ?: fmt
                                mime:returnedMime
                                text:text
                             voiceID:voiceID
                          completion:^(NSURL *fileURL, NSString *mime, NSError *writeError) {
            if (!writeError) [self forgetPendingTTSRequest:requestID];
            completion(fileURL, mime, writeError);
        }];
    };

    void (^recoverAndFinish)(NSError *) = ^(NSError *originalError) {
        [self recoverTTSRequestID:requestID token:token attempt:0
                        completion:^(NSData *audioData, NSString *returnedFormat, NSString *returnedMime, NSError *recoveryError) {
            if (audioData.length) {
                EZLogf(EZLogLevelInfo, @"TTS", @"Recovered generated audio %@ without another charge", requestID);
                finishAudio(audioData, returnedFormat, returnedMime);
                return;
            }
            // Failed/cancelled generations have already been refunded by the
            // Edge Function. A 404 also covers pre-recovery server versions.
            if (recoveryError.code == 404 || recoveryError.code == 409) {
                [self forgetPendingTTSRequest:requestID];
            }
            completion(nil, nil, recoveryError ?: originalError);
        }];
    };

    NSURL *url = [NSURL URLWithString:
        @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-elevenlabs"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    // The response is normally tiny now (a signed URL), but v4 generation can
    // still take a while. If the phone gives up first, request_id lets the
    // recovery call fetch the already-completed private asset for free.
    req.timeoutInterval = 130;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"action":        @"tts",
        @"text":          text ?: @"",
        @"voice_id":      voiceID,
        @"model_id":      kDefaultModelID,
        @"output_format": fmt,
        @"speed":         @(speed),
        @"char_count":    @(charCount),
        @"request_id":    requestID,
        @"accept_asset_url": @YES,
    } options:0 error:nil];

    EZLogf(EZLogLevelInfo, @"TTS",
           @"Requesting via Edge Function voice=%@ format=%@ speed=%.2f chars=%lu",
           voiceID, fmt, speed, (unsigned long)charCount);

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest  = 130;
    cfg.timeoutIntervalForResource = 190;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            EZLogf(EZLogLevelError, @"TTS", @"Network error: %@", error.localizedDescription);
            recoverAndFinish(error);
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (http.statusCode == 402) {
            // Parse balance/cost from response if available
            NSString *coinMsg = NSLocalizedString(@"EZTTS.InsufficientCoins", nil);
            if (data.length) {
                NSDictionary *errJson = [NSJSONSerialization
                    JSONObjectWithData:data options:0 error:nil];
                if ([errJson isKindOfClass:[NSDictionary class]]) {
                    NSNumber *bal  = errJson[@"balance"];
                    NSNumber *cost = errJson[@"cost"];
                    if (bal && cost) {
                        coinMsg = [NSString stringWithFormat:
                            NSLocalizedString(@"EZTTS.NeedCoins", nil), cost, bal];
                    }
                }
            }
            [self forgetPendingTTSRequest:requestID];
            completion(nil, nil, [NSError errorWithDomain:@"TTS" code:402
                userInfo:@{NSLocalizedDescriptionKey: coinMsg}]);
            return;
        }
        if (http.statusCode == 403) {
            [self forgetPendingTTSRequest:requestID];
            completion(nil, nil, [NSError errorWithDomain:@"TTS" code:403
                userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"EZTTS.NotAuthorized", nil)}]);
            return;
        }
        if (http.statusCode != 200) {
            // A 503 after generation means the object was saved but the server
            // could not sign its first URL. Recover it instead of exposing an
            // error or creating another paid request.
            if (http.statusCode == 202 || http.statusCode == 503) {
                recoverAndFinish([self ttsErrorWithCode:http.statusCode
                                              description:json[@"reason"] ?: @"The generated audio is being recovered."]);
                return;
            }
            NSString *msg = data.length
                ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                : NSLocalizedString(@"EZTTS.ServerError", nil);
            [self forgetPendingTTSRequest:requestID];
            completion(nil, nil, [NSError errorWithDomain:@"TTS" code:http.statusCode
                userInfo:@{NSLocalizedDescriptionKey: msg}]);
            return;
        }

        if (![json isKindOfClass:[NSDictionary class]]) {
            recoverAndFinish([self ttsErrorWithCode:-1 description:NSLocalizedString(@"EZTTS.InvalidServerResponse", nil)]);
            return;
        }

        NSString *returnedFmt  = json[@"format"] ?: fmt;
        NSString *returnedMime = json[@"mime_type"] ?: @"audio/mpeg";
        NSString *assetURL = [json[@"audio_url"] isKindOfClass:[NSString class]] ? json[@"audio_url"] : nil;
        if (assetURL.length) {
            [self downloadTTSAssetAtURLString:assetURL completion:^(NSData *audioData, NSError *downloadError) {
                if (audioData.length) {
                    finishAudio(audioData, returnedFmt, returnedMime);
                } else {
                    recoverAndFinish(downloadError);
                }
            }];
            return;
        }

        NSString *audioB64 = [json[@"audio_b64"] isKindOfClass:[NSString class]] ? json[@"audio_b64"] : nil;
        NSData *audioData = [[NSData alloc] initWithBase64EncodedString:audioB64 options:0];
        if (!audioData.length) {
            recoverAndFinish([self ttsErrorWithCode:-2 description:NSLocalizedString(@"EZTTS.EmptyAudio", nil)]);
            return;
        }
        finishAudio(audioData, returnedFmt, returnedMime);

    }] resume];
}

#pragma mark - Prefill (called from History's Regenerate / Change Voice)

/// Populates the prompt and voice, e.g. when the user taps Regenerate on an archived
/// clip. Does NOT auto-submit — this only gets them one tap away from generating,
/// without duplicating any of the network/auth logic in
/// -performTTSWithText:preferredFormat:completion: onto another screen. Pass the voice's
/// display name too (callers already have it, from the manifest entry or the picker) so
/// the button updates immediately instead of showing whatever voice was selected before —
/// passing voiceID alone left the old name displayed next to the new, wrong id.
- (void)prefillWithText:(nullable NSString *)text
                 voiceID:(nullable NSString *)voiceID
               voiceName:(nullable NSString *)voiceName
{
    self.pendingPrefillText = [text copy];
    if (voiceID.length > 0) {
        self.pendingPrefillVoiceID = [voiceID copy];
        self.pendingPrefillVoiceName = [voiceName copy];
        self.hasPendingVoicePrefill = YES;
    }
    if (self.isViewLoaded) {
        [self applyPendingPrefillIfNeeded];
    }
}

- (void)applyPendingPrefillIfNeeded {
    if (self.pendingPrefillText) {
        NSString *text = self.pendingPrefillText;
        if (text.length > kPromptCharacterLimit) {
            text = [text substringToIndex:kPromptCharacterLimit];
        }
        self.textView.text = text;
        [self updateCharCountLabel];
        self.pendingPrefillText = nil;
    }
    if (self.hasPendingVoicePrefill) {
        self.selectedVoiceID = self.pendingPrefillVoiceID;
        self.selectedVoiceName = self.pendingPrefillVoiceName; // may be nil — that's correct, not stale
        self.pendingPrefillVoiceID = nil;
        self.pendingPrefillVoiceName = nil;
        self.hasPendingVoicePrefill = NO;
        [[NSUserDefaults standardUserDefaults] setObject:self.selectedVoiceID forKey:kVoiceIDDefaultsKey];
        if (self.selectedVoiceName.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:self.selectedVoiceName forKey:kVoiceNameDefaultsKey];
        } else {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kVoiceNameDefaultsKey];
        }
        [self updateVoiceButtonTitle];
    }
}

#pragma mark - Library archiving / History

- (void)historyButtonTapped {
    EZTTSLibraryViewController *libraryVC = [[EZTTSLibraryViewController alloc] init];
    if (self.navigationController) {
        [self.navigationController pushViewController:libraryVC animated:YES];
    } else {
        // Not embedded in a navigation controller — fall back to a modal presentation
        // wrapped in its own nav bar so the user still has a way back.
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:libraryVC];
        [self presentViewController:nav animated:YES completion:nil];
    }
}

/// The one call this view controller makes into EZTTSLibraryManager. No manifest or
/// file-management logic lives here — this just gathers what the manager needs and
/// hands off. Safe to call from a background queue (performTTSWithText:'s completion
/// handler runs off the URLSession delegate queue, not main).
- (void)archiveGeneratedAudio:(NSData *)audioData
                     extension:(NSString *)extension
                        prompt:(NSString *)prompt
                       voiceID:(NSString *)voiceID
{
    [[EZTTSLibraryManager sharedManager] saveAudioData:audioData
                                                  prompt:prompt
                                               voiceName:self.selectedVoiceName
                                                 voiceID:voiceID
                                                provider:@"elevenlabs"
                                                   model:kDefaultModelID
                                               extension:extension
                                              completion:^(EZTTSManifestEntry *entry, NSError *error) {
        if (error) {
            EZLogf(EZLogLevelError, @"TTSLibrary", @"Archive failed: %@", error.localizedDescription);
            return;
        }
        EZLogf(EZLogLevelInfo, @"TTSLibrary", @"Archived clip %@", entry.uuid);
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

#pragma mark - Keyboard handling

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    CGRect kbFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat kbH = kbFrame.size.height;
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        // Slide container up just enough that the Play button clears the keyboard
        CGFloat visibleH = self.view.bounds.size.height - kbH;
        CGFloat containerBottom = self.container.frame.origin.y + self.container.frame.size.height;
        if (containerBottom > visibleH - 12) {
            CGFloat shift = containerBottom - (visibleH - 12);
            CGRect f = self.container.frame;
            f.origin.y -= shift;
            if (f.origin.y < self.view.safeAreaInsets.top + 4) f.origin.y = self.view.safeAreaInsets.top + 4;
            self.container.frame = f;
        }
    }];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        // Let viewDidLayoutSubviews restore the original position
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
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
    [ac addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"EZTTS.OK", nil) style:UIAlertActionStyleDefault handler:nil]];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:ac animated:YES completion:nil];
    });
}

@end
