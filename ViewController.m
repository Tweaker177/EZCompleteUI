#import "ViewController.h"
#import "SettingsViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuickLook/QuickLook.h>
#import <AVFoundation/AVFoundation.h>

@interface ViewController () <UIDocumentPickerDelegate, UITextFieldDelegate, QLPreviewControllerDataSource>
@property (nonatomic, strong) UITextView *chatHistoryView;
@property (nonatomic, strong) UIView *inputContainer;
@property (nonatomic, strong) UITextField *messageTextField;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) UIButton *modelButton;
@property (nonatomic, strong) UIButton *attachButton;
@property (nonatomic, strong) UIButton *settingsButton;
@property (nonatomic, strong) UIButton *clipboardButton;
@property (nonatomic, strong) UIButton *speakButton;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) NSArray *models;
@property (nonatomic, strong) NSString *selectedModel;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *chatContext;
@property (nonatomic, strong) NSLayoutConstraint *containerBottomConstraint;
@property (nonatomic, strong) NSURL *previewURL;
@property (nonatomic, strong) AVSpeechSynthesizer *speechSynthesizer;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer; // For ElevenLabs
@property (nonatomic, strong) NSString *lastAIResponse;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupData];
    [self setupUI];
    [self setupKeyboardObservers];
}

- (void)setupData {
    self.models = @[@"gpt-5-pro", @"gpt-5", @"gpt-5-mini", @"gpt-4o", @"gpt-3.5-turbo", @"dall-e-3", @"whisper-1"];
    self.chatContext = [NSMutableArray array];
    self.speechSynthesizer = [[AVSpeechSynthesizer alloc] init];
    self.selectedModel = [[NSUserDefaults standardUserDefaults] stringForKey:@"selectedModel"] ?: self.models[0];
}

- (void)setupUI {
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.settingsButton setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
    [self.settingsButton addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];

    self.clipboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.clipboardButton setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
    [self.clipboardButton addTarget:self action:@selector(copyLastResponse) forControlEvents:UIControlEventTouchUpInside];

    self.speakButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.speakButton setImage:[UIImage systemImageNamed:@"speaker.wave.2.fill"] forState:UIControlStateNormal];
    [self.speakButton addTarget:self action:@selector(speakLastResponse) forControlEvents:UIControlEventTouchUpInside];

    self.clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.clearButton setImage:[UIImage systemImageNamed:@"trash.fill"] forState:UIControlStateNormal];
    [self.clearButton setTintColor:[UIColor systemRedColor]];
    [self.clearButton addTarget:self action:@selector(clearConversation) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *topStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.clearButton, self.clipboardButton, self.speakButton, self.settingsButton]];
    topStack.spacing = 15;
    topStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:topStack];

    self.chatHistoryView = [[UITextView alloc] init];
    self.chatHistoryView.editable = NO;
    self.chatHistoryView.font = [UIFont systemFontOfSize:16];
    self.chatHistoryView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.chatHistoryView];

    self.inputContainer = [[UIView alloc] init];
    self.inputContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.inputContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.inputContainer];

    self.modelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", self.selectedModel] forState:UIControlStateNormal];
    [self.modelButton addTarget:self action:@selector(showModelPicker) forControlEvents:UIControlEventTouchUpInside];
    self.modelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.modelButton];

    self.attachButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.attachButton setImage:[UIImage systemImageNamed:@"paperclip.circle.fill"] forState:UIControlStateNormal];
    [self.attachButton addTarget:self action:@selector(presentFilePicker) forControlEvents:UIControlEventTouchUpInside];
    self.attachButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.attachButton];

    self.messageTextField = [[UITextField alloc] init];
    self.messageTextField.placeholder = @"Type message...";
    self.messageTextField.borderStyle = UITextBorderStyleRoundedRect;
    self.messageTextField.delegate = self;
    // FIX 2: Show "Done" on keyboard so tapping it dismisses
    self.messageTextField.returnKeyType = UIReturnKeyDone;
    self.messageTextField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.messageTextField];

    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendButton setTitle:@"Send" forState:UIControlStateNormal];
    [self.sendButton addTarget:self action:@selector(handleSend) forControlEvents:UIControlEventTouchUpInside];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.sendButton];

    // UI Robustness fix: Ensure send button doesn't hide
    [self.sendButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.messageTextField setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    self.containerBottomConstraint = [self.inputContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [topStack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:5],
        [topStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.chatHistoryView.topAnchor constraintEqualToAnchor:topStack.bottomAnchor constant:10],
        [self.chatHistoryView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.chatHistoryView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.chatHistoryView.bottomAnchor constraintEqualToAnchor:self.inputContainer.topAnchor],
        [self.inputContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.inputContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.containerBottomConstraint,
        [self.modelButton.topAnchor constraintEqualToAnchor:self.inputContainer.topAnchor constant:8],
        [self.modelButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],
        [self.attachButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],
        [self.attachButton.topAnchor constraintEqualToAnchor:self.modelButton.bottomAnchor constant:12],
        [self.messageTextField.leadingAnchor constraintEqualToAnchor:self.attachButton.trailingAnchor constant:8],
        [self.messageTextField.centerYAnchor constraintEqualToAnchor:self.attachButton.centerYAnchor],
        [self.messageTextField.trailingAnchor constraintEqualToAnchor:self.sendButton.leadingAnchor constant:-8],
        [self.sendButton.trailingAnchor constraintEqualToAnchor:self.inputContainer.trailingAnchor constant:-12],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:self.messageTextField.centerYAnchor],
        [self.inputContainer.bottomAnchor constraintEqualToAnchor:self.messageTextField.bottomAnchor constant:12]
    ]];
}

// FIX 2: textFieldShouldReturn was declared in the delegate but never implemented.
//         Now Return/Done key dismisses the keyboard on both main and settings screens.
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Speech Implementation (Apple & ElevenLabs)

- (void)speakLastResponse {
    if (!self.lastAIResponse) return;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *elKey   = [defaults stringForKey:@"elevenKey"];
    NSString *elVoice = [defaults stringForKey:@"elevenVoiceID"];

    if (elKey.length > 0 && elVoice.length > 0) {
        [self speakWithElevenLabs:self.lastAIResponse key:elKey voiceID:elVoice];
    } else {
        [self speakWithApple:self.lastAIResponse];
    }
}

- (void)speakWithApple:(NSString *)text {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionDuckOthers error:nil];
    [session setActive:YES error:nil];

    if (self.speechSynthesizer.isSpeaking) [self.speechSynthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];

    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
    utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    utterance.rate  = AVSpeechUtteranceDefaultSpeechRate;
    [self.speechSynthesizer speakUtterance:utterance];
}

// FIX 4: Completely rewrote the ElevenLabs completion handler.
//         Old code had a duplicated block body pasted after the first return,
//         missing AVAudioSession activation, and no diagnostic logging.
//         New code:
//           - Logs voice ID and text length before the request fires
//           - Logs HTTP status on every response
//           - On non-200, logs the full ElevenLabs JSON error body and shows it in chat
//           - On network error, logs NSError and shows it in chat
//           - Activates AVAudioSession before playback
//           - Logs AVAudioPlayer init errors and duration on success
- (void)speakWithElevenLabs:(NSString *)text key:(NSString *)key voiceID:(NSString *)voiceID {
    NSLog(@"[ElevenLabs] Starting TTS. VoiceID=%@ textLength=%lu", voiceID, (unsigned long)text.length);

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.elevenlabs.io/v1/text-to-speech/%@", voiceID]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:key forHTTPHeaderField:@"xi-api-key"];

    NSDictionary *body = @{
        @"text": text,
        @"model_id": @"eleven_turbo_v2_5",
        @"voice_settings": @{@"stability": @0.5, @"similarity_boost": @0.5}
    };
    NSError *serializationError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&serializationError];
    if (serializationError) {
        NSLog(@"[ElevenLabs] Body serialization error: %@", serializationError);
        return;
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[ElevenLabs] Network error: %@ — falling back to Apple TTS", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:[NSString stringWithFormat:@"[ElevenLabs Error — using Apple TTS]: %@", error.localizedDescription]];
                [self speakWithApple:text];
            });
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSLog(@"[ElevenLabs] HTTP %ld, %lu bytes received", (long)http.statusCode, (unsigned long)data.length);

        if (http.statusCode != 200) {
            NSString *errorBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSLog(@"[ElevenLabs] Non-200 body: %@ — falling back to Apple TTS", errorBody);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:[NSString stringWithFormat:@"[ElevenLabs HTTP %ld — using Apple TTS]: %@", (long)http.statusCode, errorBody]];
                [self speakWithApple:text];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *sessionError = nil;
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                                    mode:AVAudioSessionModeDefault
                                                 options:0
                                                   error:&sessionError];
            [[AVAudioSession sharedInstance] setActive:YES error:&sessionError];
            if (sessionError) NSLog(@"[ElevenLabs] AVAudioSession error: %@", sessionError);

            NSError *playerError = nil;
            self.audioPlayer = [[AVAudioPlayer alloc] initWithData:data error:&playerError];
            if (playerError) {
                NSLog(@"[ElevenLabs] AVAudioPlayer init error: %@ — falling back to Apple TTS", playerError);
                [self appendToChat:[NSString stringWithFormat:@"[ElevenLabs Player Error — using Apple TTS]: %@", playerError.localizedDescription]];
                [self speakWithApple:text];
                return;
            }
            NSLog(@"[ElevenLabs] Playing audio, duration=%.1fs", self.audioPlayer.duration);
            [self.audioPlayer prepareToPlay];
            [self.audioPlayer play];
        });
    }] resume];
}

#pragma mark - API Handlers

- (void)handleSend {
    NSString *text = self.messageTextField.text;
    if (text.length == 0) return;
    [self appendToChat:[NSString stringWithFormat:@"You: %@", text]];
    [self.chatContext addObject:@{@"role": @"user", @"content": text}];
    self.messageTextField.text = @"";
    [self.view endEditing:YES];

    if ([self.selectedModel isEqualToString:@"dall-e-3"]) {
        [self callDalle3:text];
    } else {
        [self callChatCompletions];
    }
}

- (void)callChatCompletions {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *apiKey = [defaults stringForKey:@"apiKey"];
    if (!apiKey) { [self appendToChat:@"[Error: No API Key]"]; return; }

    // FIX 3: GPT-5 models route to /v1/responses which has a different request
    //         schema ("input" key instead of "messages") and a different response
    //         shape (output[0].content[0].text instead of choices[0].message.content).
    BOOL isGPT5 = [self.selectedModel containsString:@"gpt-5"];
    NSString *endpointStr = isGPT5
        ? @"https://api.openai.com/v1/responses"
        : @"https://api.openai.com/v1/chat/completions";

    NSURL *url = [NSURL URLWithString:endpointStr];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"model"] = self.selectedModel;

    if (isGPT5) {
        // FIX 3: /v1/responses uses "input" array; temperature/frequency_penalty
        //         are not top-level params on this endpoint.
        NSMutableArray *inputMessages = [NSMutableArray array];
        NSString *sys = [defaults stringForKey:@"systemMessage"];
        if (sys.length > 0) [inputMessages addObject:@{@"role": @"system", @"content": sys}];
        [inputMessages addObjectsFromArray:self.chatContext];
        body[@"input"] = inputMessages;
    } else {
        body[@"temperature"]       = @([defaults floatForKey:@"temperature"] ?: 0.7);
        body[@"frequency_penalty"] = @([defaults floatForKey:@"frequency"]);
        NSMutableArray *messages = [NSMutableArray array];
        NSString *sys = [defaults stringForKey:@"systemMessage"];
        if (sys.length > 0) [messages addObject:@{@"role": @"system", @"content": sys}];
        [messages addObjectsFromArray:self.chatContext];
        body[@"messages"] = messages;
    }

    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { [self handleAPIError:error.localizedDescription]; return; }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (json[@"error"]) { [self handleAPIError:json[@"error"][@"message"]]; return; }

        // FIX 3: Parse the correct key path for each endpoint's response shape.
        NSString *reply = nil;
        if (isGPT5) {
            // /v1/responses: { "output": [ { "content": [ { "text": "..." } ] } ] }
            reply = json[@"output"][0][@"content"][0][@"text"];
        } else {
            // /v1/chat/completions: { "choices": [ { "message": { "content": "..." } } ] }
            reply = json[@"choices"][0][@"message"][@"content"];
        }

        if (!reply) {
            NSLog(@"[GPT] Unexpected response shape: %@", json);
            [self handleAPIError:@"Unexpected response format from API."];
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastAIResponse = reply;
            [self.chatContext addObject:@{@"role": @"assistant", @"content": reply}];
            [self appendToChat:[NSString stringWithFormat:@"AI: %@", reply]];
        });
    }] resume];
}

#pragma mark - Keyboard / Helpers

- (void)handleAPIError:(NSString *)errorMessage {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self appendToChat:[NSString stringWithFormat:@"[API Error]: %@", errorMessage]];
    });
}

// FIX 1: The original formula was wrong — it added safeAreaInsets.bottom back
//         onto a constraint already anchored to safeAreaLayoutGuide.bottomAnchor,
//         so the container moved up too far (by safeArea height twice) and left
//         a gap, or not far enough depending on device.
//         Correct formula: shift by -(keyboardHeight - safeAreaBottom) so the
//         container clears the keyboard exactly.
//         Also added UIKeyboardWillChangeFrameNotification so QuickType bar
//         size changes and rotation are handled correctly.
- (void)keyboardWillChange:(NSNotification *)notification {
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    double duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    BOOL isHiding = [notification.name isEqualToString:UIKeyboardWillHideNotification];

    if (isHiding) {
        self.containerBottomConstraint.constant = 0;
    } else {
        CGFloat safeBottom = self.view.safeAreaInsets.bottom;
        self.containerBottomConstraint.constant = -(keyboardFrame.size.height - safeBottom);
    }

    [UIView animateWithDuration:duration animations:^{ [self.view layoutIfNeeded]; }];
}

- (void)setupKeyboardObservers {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
    // FIX 1: Track frame changes (QuickType bar toggle, split-screen resize, rotation)
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (void)clearConversation { [self.chatContext removeAllObjects]; self.chatHistoryView.text = @"[System: Cleared]"; self.lastAIResponse = nil; }
- (void)copyLastResponse { if (self.lastAIResponse) [UIPasteboard generalPasteboard].string = self.lastAIResponse; }

- (void)showModelPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Model" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *model in self.models) {
        [alert addAction:[UIAlertAction actionWithTitle:model style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.selectedModel = model;
            [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", model] forState:UIControlStateNormal];
            [[NSUserDefaults standardUserDefaults] setObject:model forKey:@"selectedModel"];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)appendToChat:(NSString *)text {
    self.chatHistoryView.text = [self.chatHistoryView.text stringByAppendingFormat:@"\n\n%@", text];
    [self.chatHistoryView scrollRangeToVisible:NSMakeRange(self.chatHistoryView.text.length - 1, 1)];
}

- (void)presentFilePicker {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio, UTTypeVideo] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self transcribeAudio:urls.firstObject];
}

- (void)transcribeAudio:(NSURL *)fileURL {
    [self appendToChat:@"[System: Whisper Uploading...]"];
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"apiKey"];
    NSURL *url = [NSURL URLWithString:@"https://api.openai.com/v1/audio/transcriptions"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    NSMutableData *body = [NSMutableData data];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n", fileURL.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: audio/mpeg\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[NSData dataWithContentsOfURL:fileURL]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    request.HTTPBody = body;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            // FIX 5: Formatting extracted into helper — called once, result used in both places.
            NSString *formatted = [self formatWhisperTranscript:json[@"text"]];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.messageTextField.text = formatted;
                [self appendToChat:[NSString stringWithFormat:@"[Whisper]: %@", formatted]];
            });
        }
    }] resume];
}

// FIX 5: Single formatting helper replaces the duplicated inline block pattern.
- (NSString *)formatWhisperTranscript:(NSString *)raw {
    if (!raw) return @"";
    NSString *formatted = [raw stringByReplacingOccurrencesOfString:@". "  withString:@".\n"];
    formatted            = [formatted stringByReplacingOccurrencesOfString:@"! " withString:@"!\n"];
    formatted            = [formatted stringByReplacingOccurrencesOfString:@"? " withString:@"?\n"];
    return formatted;
}

- (void)callDalle3:(NSString *)prompt {
    [self appendToChat:@"[System: Generating Image...]"];
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"apiKey"];
    NSURL *url = [NSURL URLWithString:@"https://api.openai.com/v1/images/generations"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"model": @"dall-e-3", @"prompt": prompt} options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *imgURL = json[@"data"][0][@"url"];
            if (imgURL) { [self downloadAndShowImage:imgURL]; }
        }
    }] resume];
}

- (void)downloadAndShowImage:(NSString *)urlString {
    [[[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:urlString] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (location) {
            NSURL *tempURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"gen.png"]];
            [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
            [[NSFileManager defaultManager] copyItemAtURL:location toURL:tempURL error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.previewURL = tempURL;
                QLPreviewController *ql = [[QLPreviewController alloc] init];
                ql.dataSource = self;
                [self presentViewController:ql animated:YES completion:nil];
            });
        }
    }] resume];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)c { return 1; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)c previewItemAtIndex:(NSInteger)i { return self.previewURL; }

- (void)openSettings {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[SettingsViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}

@end


#pragma mark - SettingsViewController

@interface SettingsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextField *apiKeyField, *systemMsgField, *elKeyField, *elVoiceField;
@property (nonatomic, strong) UISlider *tempSlider, *freqSlider;
@property (nonatomic, strong) UILabel *tempLabel, *freqLabel;
@end

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(saveAndClose)];
    [self setupUI];
    [self loadSettings];
    // FIX 1 (Settings): Register keyboard observers so the scroll view inset adjusts
    //                    and text fields are never hidden behind the keyboard.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardHide:) name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardShow:) name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// FIX 1 (Settings): Push scroll content up so the active field stays visible.
- (void)keyboardShow:(NSNotification *)notification {
    CGRect kbFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, kbFrame.size.height, 0);
    self.scrollView.contentInset = insets;
    self.scrollView.scrollIndicatorInsets = insets;
}

- (void)keyboardHide:(NSNotification *)notification {
    self.scrollView.contentInset        = UIEdgeInsetsZero;
    self.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
}

// FIX 2 (Settings): Return/Done dismisses keyboard in all settings text fields.
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)setupUI {
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scrollView];
    CGFloat w = self.view.frame.size.width - 40;

    [self addLabel:@"OpenAI API Key:" y:20];
    self.apiKeyField = [self addField:50 w:w secure:NO placeholder:@"sk-..."];

    [self addLabel:@"System Message:" y:100];
    self.systemMsgField = [self addField:130 w:w secure:NO placeholder:@"Instructions..."];

    self.tempLabel = [self addLabel:@"Temperature" y:180];
    self.tempSlider = [self addSlider:210 min:0 max:2];

    self.freqLabel = [self addLabel:@"Frequency Penalty" y:260];
    self.freqSlider = [self addSlider:290 min:-2 max:2];

    [self addLabel:@"ElevenLabs API Key:" y:340];
    self.elKeyField = [self addField:370 w:w secure:NO placeholder:@"ElevenLabs Key"];

    [self addLabel:@"ElevenLabs Voice ID:" y:420];
    self.elVoiceField = [self addField:450 w:w-90 secure:NO placeholder:@"Voice ID"];

    UIButton *getVoices = [UIButton buttonWithType:UIButtonTypeSystem];
    getVoices.frame = CGRectMake(w-40, 450, 80, 40);
    [getVoices setTitle:@"Get Voices" forState:UIControlStateNormal];
    [getVoices addTarget:self action:@selector(fetchVoices) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:getVoices];

    UIButton *donate = [UIButton buttonWithType:UIButtonTypeSystem];
    donate.frame = CGRectMake(20, 520, w, 50);
    [donate setTitle:@"Donate via PayPal" forState:UIControlStateNormal];
    donate.backgroundColor = [UIColor systemBlueColor];
    donate.tintColor = [UIColor whiteColor];
    donate.layer.cornerRadius = 10;
    [donate addTarget:self action:@selector(donate) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:donate];

    self.scrollView.contentSize = CGSizeMake(self.view.frame.size.width, 600);
}

- (UILabel *)addLabel:(NSString *)txt y:(CGFloat)y {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, y, self.view.frame.size.width-40, 30)];
    l.text = txt;
    [self.scrollView addSubview:l];
    return l;
}

- (UITextField *)addField:(CGFloat)y w:(CGFloat)w secure:(BOOL)s placeholder:(NSString *)p {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(20, y, w, 40)];
    f.borderStyle   = UITextBorderStyleRoundedRect;
    f.secureTextEntry = s;
    f.placeholder   = p;
    f.delegate      = self;
    f.returnKeyType = UIReturnKeyDone; // FIX 2
    [self.scrollView addSubview:f];
    return f;
}

- (UISlider *)addSlider:(CGFloat)y min:(float)min max:(float)max {
    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(20, y, self.view.frame.size.width-40, 30)];
    s.minimumValue = min;
    s.maximumValue = max;
    [s addTarget:self action:@selector(updateLabels) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:s];
    return s;
}

- (void)updateLabels {
    self.tempLabel.text = [NSString stringWithFormat:@"Temperature: %.2f", self.tempSlider.value];
    self.freqLabel.text = [NSString stringWithFormat:@"Freq Penalty: %.2f", self.freqSlider.value];
}

- (void)fetchVoices {
    if (self.elKeyField.text.length == 0) return;
    NSURL *url = [NSURL URLWithString:@"https://api.elevenlabs.io/v1/voices"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:self.elKeyField.text forHTTPHeaderField:@"xi-api-key"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *voices = json[@"voices"];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Select Voice" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
                for (NSDictionary *v in voices) {
                    [sheet addAction:[UIAlertAction actionWithTitle:v[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                        self.elVoiceField.text = v[@"voice_id"];
                    }]];
                }
                [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:sheet animated:YES completion:nil];
            });
        }
    }] resume];
}

- (void)donate {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://paypal.me/i0stweak3r"] options:@{} completionHandler:nil];
}

- (void)loadSettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.apiKeyField.text    = [d stringForKey:@"apiKey"];
    self.systemMsgField.text = [d stringForKey:@"systemMessage"];
    self.tempSlider.value    = [d floatForKey:@"temperature"] ?: 0.7;
    self.freqSlider.value    = [d floatForKey:@"frequency"];
    self.elKeyField.text     = [d stringForKey:@"elevenKey"];
    self.elVoiceField.text   = [d stringForKey:@"elevenVoiceID"];
    [self updateLabels];
}

- (void)saveAndClose {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:self.apiKeyField.text    forKey:@"apiKey"];
    [d setObject:self.systemMsgField.text forKey:@"systemMessage"];
    [d setFloat:self.tempSlider.value     forKey:@"temperature"];
    [d setFloat:self.freqSlider.value     forKey:@"frequency"];
    [d setObject:self.elKeyField.text     forKey:@"elevenKey"];
    [d setObject:self.elVoiceField.text   forKey:@"elevenVoiceID"];
    [d synchronize];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
