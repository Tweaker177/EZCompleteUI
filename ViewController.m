#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <QuickLook/QuickLook.h>

// ==========================================
// MARK: - SETTINGS VIEW CONTROLLER
// ==========================================
@interface SettingsViewController : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextField *systemMsgField;
@property (nonatomic, strong) UISegmentedControl *modelPicker;
@property (nonatomic, strong) UISlider *tempSlider;
@property (nonatomic, strong) UILabel *tempLabel;
@property (nonatomic, strong) UISlider *freqSlider;
@property (nonatomic, strong) UILabel *freqLabel;
@end

@implementation SettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupGradientBackground];
    
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.contentSize = CGSizeMake(self.view.bounds.size.width, 700);
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scrollView];

    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 30, self.view.bounds.size.width - 40, 40)];
    titleLbl.text = @"Settings";
    titleLbl.textColor = [UIColor whiteColor];
    titleLbl.font = [UIFont boldSystemFontOfSize:28];
    [self.scrollView addSubview:titleLbl];
    
    CGFloat w = self.view.bounds.size.width - 40;
    
    // API Key Button
    UIButton *setKeyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    setKeyBtn.frame = CGRectMake(20, 90, w, 45);
    setKeyBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.9];
    setKeyBtn.layer.cornerRadius = 8;
    [setKeyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [setKeyBtn setTitle:@"🔑 Update / Set OpenAI API Key" forState:UIControlStateNormal];
    [setKeyBtn addTarget:self action:@selector(promptForApiKey) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:setKeyBtn];
    
    // System Message (Context)
    UILabel *sysLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 150, w, 20)];
    sysLbl.text = @"System Message (Context):";
    sysLbl.textColor = [UIColor yellowColor];
    [self.scrollView addSubview:sysLbl];
    
    self.systemMsgField = [[UITextField alloc] initWithFrame:CGRectMake(20, 180, w, 40)];
    self.systemMsgField.borderStyle = UITextBorderStyleRoundedRect;
    self.systemMsgField.placeholder = @"You are a helpful assistant.";
    self.systemMsgField.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.9];
    self.systemMsgField.delegate = self;
    
    NSString *savedSysMsg = [[NSUserDefaults standardUserDefaults] stringForKey:@"saved_system_msg"];
    if (savedSysMsg) self.systemMsgField.text = savedSysMsg;
    [self.systemMsgField addTarget:self action:@selector(systemMsgChanged:) forControlEvents:UIControlEventEditingChanged];
    [self.scrollView addSubview:self.systemMsgField];

    // Model Selection
    UILabel *modelLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 240, w, 20)];
    modelLbl.text = @"Model Selection:";
    modelLbl.textColor = [UIColor lightGrayColor];
    [self.scrollView addSubview:modelLbl];
    
    self.modelPicker = [[UISegmentedControl alloc] initWithItems:@[@"3.5", @"4o", @"4-turbo", @"5o", @"DALL-E 3"]];
    self.modelPicker.frame = CGRectMake(20, 270, w, 35);
    self.modelPicker.backgroundColor = [UIColor systemGrayColor];
    self.modelPicker.selectedSegmentIndex = [[NSUserDefaults standardUserDefaults] integerForKey:@"saved_model_index"];
    [self.modelPicker addTarget:self action:@selector(modelChanged) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.modelPicker];

    // Temperature
    self.tempLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 330, w, 20)];
    self.tempLabel.textColor = [UIColor lightGrayColor];
    [self.scrollView addSubview:self.tempLabel];
    
    self.tempSlider = [[UISlider alloc] initWithFrame:CGRectMake(20, 360, w, 30)];
    self.tempSlider.minimumValue = 0.0; self.tempSlider.maximumValue = 2.0;
    
    float savedTemp = [[NSUserDefaults standardUserDefaults] floatForKey:@"saved_temp"];
    if (savedTemp == 0.0 && ![[NSUserDefaults standardUserDefaults] boolForKey:@"temp_initialized"]) {
        savedTemp = 0.7; // Default
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"temp_initialized"];
    }
    self.tempSlider.value = savedTemp;
    self.tempLabel.text = [NSString stringWithFormat:@"Temperature: %.1f", self.tempSlider.value];
    [self.tempSlider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.tempSlider];

    // Frequency Penalty
    self.freqLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 410, w, 20)];
    self.freqLabel.textColor = [UIColor lightGrayColor];
    [self.scrollView addSubview:self.freqLabel];
    
    self.freqSlider = [[UISlider alloc] initWithFrame:CGRectMake(20, 440, w, 30)];
    self.freqSlider.minimumValue = -2.0; self.freqSlider.maximumValue = 2.0;
    
    float savedFreq = [[NSUserDefaults standardUserDefaults] floatForKey:@"saved_freq"];
    self.freqSlider.value = savedFreq;
    self.freqLabel.text = [NSString stringWithFormat:@"Frequency Penalty: %.1f", self.freqSlider.value];
    [self.freqSlider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.freqSlider];

    // Done Button
    UIButton *doneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    doneBtn.frame = CGRectMake(20, 500, w, 50);
    doneBtn.backgroundColor = [UIColor systemBlueColor];
    doneBtn.layer.cornerRadius = 10;
    [doneBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [doneBtn setTitle:@"Save & Close" forState:UIControlStateNormal];
    [doneBtn addTarget:self action:@selector(closeSettings) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:doneBtn];
}

- (void)setupGradientBackground {
    CAGradientLayer *bgGrad = [CAGradientLayer layer];
    bgGrad.frame = self.view.bounds;
    bgGrad.colors = @[(id)[UIColor colorWithRed:0.05 green:0.05 blue:0.1 alpha:1].CGColor,
                      (id)[UIColor colorWithRed:0.15 green:0.15 blue:0.25 alpha:1].CGColor];
    [self.view.layer insertSublayer:bgGrad atIndex:0];
}

- (void)modelChanged {
    [[NSUserDefaults standardUserDefaults] setInteger:self.modelPicker.selectedSegmentIndex forKey:@"saved_model_index"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)sliderChanged {
    self.tempLabel.text = [NSString stringWithFormat:@"Temperature: %.1f", self.tempSlider.value];
    self.freqLabel.text = [NSString stringWithFormat:@"Frequency Penalty: %.1f", self.freqSlider.value];
    [[NSUserDefaults standardUserDefaults] setFloat:self.tempSlider.value forKey:@"saved_temp"];
    [[NSUserDefaults standardUserDefaults] setFloat:self.freqSlider.value forKey:@"saved_freq"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)systemMsgChanged:(UITextField *)textField {
    [[NSUserDefaults standardUserDefaults] setObject:textField.text forKey:@"saved_system_msg"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)closeSettings {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)promptForApiKey {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"API Key" message:@"Enter your OpenAI API Key" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"sk-...";
        textField.secureTextEntry = YES;
        textField.text = [[NSUserDefaults standardUserDefaults] stringForKey:@"saved_api_key"];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *key = alert.textFields.firstObject.text;
        [[NSUserDefaults standardUserDefaults] setObject:key forKey:@"saved_api_key"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}
@end


// ==========================================
// MARK: - MAIN VIEW CONTROLLER
// ==========================================
@interface ViewController () <UITextFieldDelegate, QLPreviewControllerDataSource, QLPreviewControllerDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextField *draftPreviewField;
@property (nonatomic, strong) UITextView *outputView;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) AVSpeechSynthesizer *speechSynthesizer;
@property (nonatomic, strong) NSURL *previewItemURL;

// This array holds all current messages (user + AI) to act as conversation memory!
@property (nonatomic, strong) NSMutableArray *conversationHistory;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupMainGradient];
    self.speechSynthesizer = [[AVSpeechSynthesizer alloc] init];
    self.conversationHistory = [[NSMutableArray alloc] init];
    
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.contentSize = CGSizeMake(self.view.bounds.size.width, 900);
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scrollView];

    CGFloat w = self.view.bounds.size.width - 40;
    
    // Header & Settings Button
    UILabel *headerLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 50, w - 50, 30)];
    headerLbl.text = @"EZComplete Pro";
    headerLbl.textColor = [UIColor whiteColor];
    headerLbl.font = [UIFont boldSystemFontOfSize:24];
    [self.scrollView addSubview:headerLbl];
    
    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsBtn.frame = CGRectMake(self.view.bounds.size.width - 60, 45, 40, 40);
    [settingsBtn setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
    settingsBtn.tintColor = [UIColor whiteColor];
    [settingsBtn addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:settingsBtn];

    // Draft Preview
    self.draftPreviewField = [[UITextField alloc] initWithFrame:CGRectMake(20, 90, w, 40)];
    self.draftPreviewField.borderStyle = UITextBorderStyleRoundedRect;
    self.draftPreviewField.enabled = NO;
    self.draftPreviewField.textColor = [UIColor systemYellowColor];
    self.draftPreviewField.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.9];
    self.draftPreviewField.placeholder = @"Live typing preview...";
    [self.scrollView addSubview:self.draftPreviewField];
    
    // Output Box Container
    UIView *outputContainer = [[UIView alloc] initWithFrame:CGRectMake(20, 150, w, 400)];
    outputContainer.layer.cornerRadius = 10;
    outputContainer.clipsToBounds = YES;
    outputContainer.layer.borderColor = [UIColor systemBlueColor].CGColor;
    outputContainer.layer.borderWidth = 3.0;
    
    CAGradientLayer *outputGrad = [CAGradientLayer layer];
    outputGrad.frame = outputContainer.bounds;
    outputGrad.colors = @[(id)[UIColor colorWithRed:0.1 green:0.1 blue:0.15 alpha:1].CGColor,
                          (id)[UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:1].CGColor];
    [outputContainer.layer insertSublayer:outputGrad atIndex:0];
    [self.scrollView addSubview:outputContainer];

    // The Actual Output Text View
    self.outputView = [[UITextView alloc] initWithFrame:outputContainer.bounds];
    self.outputView.editable = NO;
    self.outputView.backgroundColor = [UIColor clearColor]; // Let gradient show through
    [outputContainer addSubview:self.outputView];

    // Utility Buttons
    UIButton *copyBtn = [self createButtonAt:CGRectMake(20, 570, 100, 40) title:@"📋 Copy" action:@selector(copyToClipboard)];
    UIButton *clearBtn = [self createButtonAt:CGRectMake(w/2 - 30, 570, 100, 40) title:@"🗑 Clear" action:@selector(clearChat)];
    UIButton *speakBtn = [self createButtonAt:CGRectMake(w - 80, 570, 100, 40) title:@"🔊 Speak" action:@selector(speakLastResponse)];
    [self.scrollView addSubview:copyBtn]; [self.scrollView addSubview:clearBtn]; [self.scrollView addSubview:speakBtn];

    // User Input Field
    self.inputField = [[UITextField alloc] initWithFrame:CGRectMake(20, 630, w, 45)];
    self.inputField.placeholder = @"Type your message or image prompt...";
    self.inputField.borderStyle = UITextBorderStyleRoundedRect;
    self.inputField.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.9];
    self.inputField.delegate = self;
    [self.inputField addTarget:self action:@selector(inputChanged:) forControlEvents:UIControlEventEditingChanged];
    [self.scrollView addSubview:self.inputField];
    
    // Send Button
    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendButton.frame = CGRectMake(20, 690, w, 50);
    self.sendButton.backgroundColor = [UIColor systemBlueColor];
    [self.sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.sendButton setTitle:@"Send Request" forState:UIControlStateNormal];
    self.sendButton.layer.cornerRadius = 10;
    [self.sendButton addTarget:self action:@selector(sendRequest) forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.sendButton];
}

- (void)setupMainGradient {
    CAGradientLayer *bgGrad = [CAGradientLayer layer];
    bgGrad.frame = self.view.bounds;
    bgGrad.colors = @[(id)[UIColor colorWithRed:0.0 green:0.1 blue:0.2 alpha:1].CGColor,
                      (id)[UIColor colorWithRed:0.0 green:0.0 blue:0.1 alpha:1].CGColor];
    [self.view.layer insertSublayer:bgGrad atIndex:0];
}

- (UIButton *)createButtonAt:(CGRect)rect title:(NSString *)t action:(SEL)s {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = rect;
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    b.layer.cornerRadius = 8;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:self action:s forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)openSettings {
    SettingsViewController *svc = [[SettingsViewController alloc] init];
    svc.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:svc animated:YES completion:nil];
}

- (void)inputChanged:(UITextField *)sender {
    self.draftPreviewField.text = sender.text;
}

// Clears both the visual chat and the underlying context memory
- (void)clearChat {
    self.outputView.attributedText = [[NSAttributedString alloc] initWithString:@""];
    [self.conversationHistory removeAllObjects];
}

- (void)copyToClipboard {
    if (self.outputView.text.length > 0) { [UIPasteboard generalPasteboard].string = self.outputView.text; }
}

- (void)speakLastResponse {
    if (self.outputView.text.length == 0) return;
    
    AVSpeechSynthesisVoice *bestVoice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    for (AVSpeechSynthesisVoice *voice  in [AVSpeechSynthesisVoice speechVoices]) {
        if ([voice.language hasPrefix:@"en"]) {
            if (voice.quality == AVSpeechSynthesisVoiceQualityPremium) {
                bestVoice = voice;
                break;
            } else if (voice.quality == AVSpeechSynthesisVoiceQualityEnhanced) {
                bestVoice = voice;
            }
        }
    }
    
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:self.outputView.text];
    utterance.voice = bestVoice;
    [self.speechSynthesizer speakUtterance:utterance];
}

- (void)appendMessage:(NSString *)text isUser:(BOOL)isUser {
    NSMutableAttributedString *currentText = [[NSMutableAttributedString alloc] initWithAttributedString:self.outputView.attributedText];
    
    UIColor *bgColor = isUser ? [UIColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:0.7] : [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.7];
    
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.paragraphSpacing = 10.0;
    style.headIndent = 8.0;
    style.firstLineHeadIndent = 8.0;
    style.tailIndent = -8.0;
    
    NSDictionary *attributes = @{
        NSBackgroundColorAttributeName: bgColor,
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName: [UIFont systemFontOfSize:15],
        NSParagraphStyleAttributeName: style
    };
    
    NSString *formattedString = [NSString stringWithFormat:@"%@\n\n", text];
    NSAttributedString *newStr = [[NSAttributedString alloc] initWithString:formattedString attributes:attributes];
    
    [currentText appendAttributedString:newStr];
    self.outputView.attributedText = currentText;
    
    if (self.outputView.text.length > 0) {
        [self.outputView scrollRangeToVisible:NSMakeRange(self.outputView.text.length - 1, 1)];
    }
}

- (void)sendRequest {
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"saved_api_key"];
    NSString *prompt = self.inputField.text;
    
    if (!apiKey || apiKey.length < 5) {
        [self appendMessage:@"[System: Please set your API Key in Settings first]" isUser:NO];
        [self openSettings];
        return;
    }
    if (prompt.length == 0) return;

    [self appendMessage:[NSString stringWithFormat:@"You: %@", prompt] isUser:YES];
    self.inputField.text = @"";
    self.draftPreviewField.text = @"";
    [self.view endEditing:YES];

    NSArray *models = @[@"gpt-3.5-turbo", @"gpt-4o", @"gpt-4-turbo", @"gpt-5o", @"dall-e-3"];
    NSInteger modelIdx = [[NSUserDefaults standardUserDefaults] integerForKey:@"saved_model_index"];
    NSString *selectedModel = models[modelIdx];
    BOOL isImageGen = [selectedModel isEqualToString:@"dall-e-3"];
    
    NSURL *url = isImageGen ? [NSURL URLWithString:@"https://api.openai.com/v1/images/generations"] : [NSURL URLWithString:@"https://api.openai.com/v1/chat/completions"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    NSDictionary *payload;
    if (isImageGen) {
        // DALL-E does not take conversation history
        payload = @{@"model": selectedModel, @"prompt": prompt, @"n": @1, @"size": @"1024x1024"};
    } else {
        // Chat completion models with conversation memory
        float temp = [[NSUserDefaults standardUserDefaults] floatForKey:@"saved_temp"];
        float freq = [[NSUserDefaults standardUserDefaults] floatForKey:@"saved_freq"];
        NSString *sysStr = [[NSUserDefaults standardUserDefaults] stringForKey:@"saved_system_msg"];
        if (!sysStr || sysStr.length == 0) sysStr = @"You are a helpful assistant.";
        
        // 1. Build messages array starting with System Instruction
        NSMutableArray *apiMessages = [NSMutableArray array];
        [apiMessages addObject:@{@"role": @"system", @"content": sysStr}];
        
        // 2. Add User message to memory
        [self.conversationHistory addObject:@{@"role": @"user", @"content": prompt}];
        
        // 3. Append full conversation memory
        [apiMessages addObjectsFromArray:self.conversationHistory];
        
        payload = @{
            @"model": selectedModel,
            @"messages": apiMessages,
            @"temperature": @(temp),
            @"frequency_penalty": @(freq)
        };
    }

    NSData *postData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [req setHTTPBody:postData];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err) { [self appendMessage:err.localizedDescription isUser:NO]; return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            
            if (isImageGen && json[@"data"]) {
                NSString *imgUrlStr = json[@"data"][0][@"url"];
                [self appendMessage:@"AI: Image Generated! Opening QuickLook..." isUser:NO];
                [self downloadAndPreviewImage:imgUrlStr];
            }
            else if (!isImageGen && json[@"choices"]) {
                NSString *reply = json[@"choices"][0][@"message"][@"content"];
                reply = [reply stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                
                // Add AI's reply to conversation memory!
                [self.conversationHistory addObject:@{@"role": @"assistant", @"content": reply}];
                [self appendMessage:[NSString stringWithFormat:@"AI: %@", reply] isUser:NO];
            } else {
                [self appendMessage:@"Error: Check API Key, Balance, or Model spelling." isUser:NO];
            }
        });
    }] resume];
}

// ==========================================
// MARK: - DALL-E 3 IMAGE DOWNLOADING & PREVIEW
// ==========================================
- (void)downloadAndPreviewImage:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSURL *tempDir = [NSURL fileURLWithPath:NSTemporaryDirectory()];
                self.previewItemURL = [tempDir URLByAppendingPathComponent:@"dalle_output.png"];
                [data writeToURL:self.previewItemURL atomically:YES];
                
                QLPreviewController *previewController = [[QLPreviewController alloc] init];
                previewController.dataSource = self;
                previewController.delegate = self;
                [self presentViewController:previewController animated:YES completion:nil];
            });
        }
    }] resume];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller { return 1; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index { return self.previewItemURL; }

- (BOOL)textFieldShouldReturn:(UITextField *)f { [f resignFirstResponder]; return YES; }

@end
