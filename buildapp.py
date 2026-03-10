#!/usr/bin/env python3
import os
import shutil

def generate_ezcomplete_redesign():
    project_dir = "EZCompleteUI"
    os.makedirs(project_dir, exist_ok=True)

    files = {
        "Makefile": """
TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = EZCompleteUI

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = EZCompleteUI

EZCompleteUI_FILES = main.m AppDelegate.m ViewController.m MessageBubbleView.m
EZCompleteUI_FRAMEWORKS = UIKit Foundation CoreGraphics AVFoundation QuartzCore
EZCompleteUI_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/application.mk
""",
        "Info.plist": """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>EZCompleteUI</string>
    <key>CFBundleIdentifier</key>
    <string>com.i0stweak3r.ezcompleteui</string>
    <key>CFBundleName</key>
    <string>EZCompleteUI</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>4.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>MinimumOSVersion</key>
    <string>14.0</string>
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>
    <key>UILaunchStoryboardName</key>
    <string>LaunchScreen</string>
    <key>CFBundleIconFiles</key>
    <array>
        <string>Icon-1024.png</string>
    </array>
</dict>
</plist>
""",
        "control": """
Package: com.i0stweak3r.ezcompleteui
Name: EZCompleteUI
Version: 4.0.0
Architecture: iphoneos-arm64
Description: EZComplete UI with separate comic-book style chat views.
Maintainer: i0stweak3r
Author: i0stweak3r
Section: Utilities
""",
        "main.m": """
#import <UIKit/UIKit.h>
#import "AppDelegate.h"

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
""",
        "AppDelegate.h": """
#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
""",
        "AppDelegate.m": """
#import "AppDelegate.h"
#import "ViewController.h"

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
""",
        "MessageBubbleView.h": """
#import <UIKit/UIKit.h>

@interface MessageBubbleView : UIView
@property (nonatomic, strong) UILabel *messageLabel;
- (instancetype)initWithText:(NSString *)text isUser:(BOOL)isUser;
@end
""",
        "MessageBubbleView.m": """
#import "MessageBubbleView.h"
#import <QuartzCore/QuartzCore.h>

@implementation MessageBubbleView

- (instancetype)initWithText:(NSString *)text isUser:(BOOL)isUser {
    self = [super init];
    if (self) {
        _messageLabel = [[UILabel alloc] init];
        _messageLabel.numberOfLines = 0;
        _messageLabel.font = [UIFont systemFontOfSize:14];
        _messageLabel.text = text;
        [self addSubview:_messageLabel];

        // Bubble shape/color
        if (isUser) {
            self.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0]; // User (blue)
            _messageLabel.textColor = [UIColor whiteColor];
            _messageLabel.textAlignment = NSTextAlignmentRight;
        } else {
            self.backgroundColor = [UIColor systemGray5Color]; // AI (gray)
            _messageLabel.textColor = [UIColor blackColor];
            _messageLabel.textAlignment = NSTextAlignmentLeft;
        }
        self.layer.cornerRadius = 10;
        
        // Setup shape layers for the comic-book style curves
        [self setupMaskingForUser:isUser];
    }
    return self;
}

- (void)setupMaskingForUser:(BOOL)isUser {
    UIRectCorner corners;
    if (isUser) {
        // Curve to the right
        corners = UIRectCornerTopLeft | UIRectCornerTopRight | UIRectCornerBottomLeft;
    } else {
        // Curve to the left
        corners = UIRectCornerTopLeft | UIRectCornerTopRight | UIRectCornerBottomRight;
    }
    
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:self.bounds byRoundingCorners:corners cornerRadii:CGSizeMake(10, 10)];
    CAShapeLayer *maskLayer = [[CAShapeLayer alloc] init];
    maskLayer.frame = self.bounds;
    maskLayer.path = path.CGPath;
    self.layer.mask = maskLayer;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Re-apply mask to update the shape for new content size
    [self setupMaskingForUser:(self.backgroundColor == [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0])];
}

@end
""",
        "ViewController.h": """
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface ViewController : UIViewController <UITextFieldDelegate>
@end
""",
        "ViewController.m": """
#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "MessageBubbleView.h"

@interface ViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextField *draftPreviewField; 
@property (nonatomic, strong) UITextField *systemMsgField;
@property (nonatomic, strong) UISegmentedControl *modelPicker;
@property (nonatomic, strong) UISlider *tempSlider;
@property (nonatomic, strong) UISlider *freqSlider;
@property (nonatomic, strong) UILabel *tempLabel;
@property (nonatomic, strong) UILabel *freqLabel;
@property (nonatomic, strong) UIView *chatContainer;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) AVSpeechSynthesizer *speechSynthesizer;
@property (nonatomic, assign) CGFloat lastMessageY;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // dark mode background (user color)
    self.view.backgroundColor = [UIColor systemGray6Color];
    self.speechSynthesizer = [[AVSpeechSynthesizer alloc] init];
    self.lastMessageY = 20;

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scrollView];

    CGFloat w = self.view.bounds.size.width - 40;
    
    // 1. DRAFT PREVIEW BOX (light background, visible text)
    self.draftPreviewField = [self createTextFieldAt:60 placeholder:@"Live Typing Preview" enabled:NO];
    self.draftPreviewField.backgroundColor = [UIColor systemGray5Color];
    self.draftPreviewField.textColor = [UIColor systemBlueColor];
    
    // 2. API KEY MANAGEMENT (Button)
    UIButton *setKeyBtn = [self createButtonAt:CGRectMake(20, 110, w, 30) title:@"🔑 Set OpenAI API Key" action:@selector(promptForApiKey)];
    [self.scrollView addSubview:setKeyBtn];
    
    // System Message (Context)
    self.systemMsgField = [self createTextFieldAt:150 placeholder:@"System Message (Context)"];
    
    // Model Selection
    UILabel *modelLbl = [self createLabelAt:CGRectMake(20, 200, w, 20) text:@"Model Selection:"];
    [self.scrollView addSubview:modelLbl];
    
    self.modelPicker = [[UISegmentedControl alloc] initWithItems:@[@"gpt-3.5-turbo", @"gpt-4o", @"gpt-4-turbo"]];
    self.modelPicker.frame = CGRectMake(20, 225, w, 35);
    self.modelPicker.selectedSegmentIndex = 0;
    self.modelPicker.backgroundColor = [UIColor systemGray5Color];
    [self.scrollView addSubview:self.modelPicker];

    // Temperature & Frequency
    self.tempLabel = [self createLabelAt:CGRectMake(20, 270, w, 20) text:@"Temperature: 0.7"];
    [self.scrollView addSubview:self.tempLabel];
    self.tempSlider = [self createSliderAt:CGRectMake(20, 295, w, 30) value:0.7 action:@selector(sliderChanged)];
    [self.scrollView addSubview:self.tempSlider];

    self.freqLabel = [self createLabelAt:CGRectMake(20, 335, w, 20) text:@"Frequency Penalty: 0.0"];
    [self.scrollView addSubview:self.freqLabel];
    self.freqSlider = [self createSliderAt:CGRectMake(20, 360, w, 30) value:0.0 action:@selector(sliderChanged)];
    [self.scrollView addSubview:self.freqSlider];

    // 3. CHAT BUBBLES CONTAINER
    self.chatContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 400, self.view.bounds.size.width, 20)];
    [self.scrollView addSubview:self.chatContainer];

    // Utility Buttons (at the top of input area)
    UIButton *copyBtn = [self createButtonAt:CGRectMake(20, self.view.bounds.size.height - 180, 100, 40) title:@"📋 Copy Log" action:@selector(copyToClipboard)];
    UIButton *clearBtn = [self createButtonAt:CGRectMake(w/2 - 30, self.view.bounds.size.height - 180, 100, 40) title:@"🗑 Clear Chat" action:@selector(clearChat)];
    UIButton *speakBtn = [self createButtonAt:CGRectMake(w - 70, self.view.bounds.size.height - 180, 100, 40) title:@"🔊 Speak All" action:@selector(speakAllMessages)];
    [self.view addSubview:copyBtn]; [self.view addSubview:clearBtn]; [self.view addSubview:speakBtn];

    // 4. USER INPUT FIELD (Fixed visibility)
    self.inputField = [self createTextFieldAt:self.view.bounds.size.height - 130 placeholder:@"Type message..."];
    [self.inputField addTarget:self action:@selector(inputChanged:) forControlEvents:UIControlEventEditingChanged];
    self.inputField.delegate = self;
    [self.view addSubview:self.inputField];
    
    self.sendButton = [self createButtonAt:CGRectMake(20, self.view.bounds.size.height - 80, w, 50) title:@"Send Request" action:@selector(sendRequest)];
    self.sendButton.backgroundColor = [UIColor systemBlueColor];
    [self.sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.sendButton.layer.cornerRadius = 10;
    [self.view addSubview:self.sendButton];
}

- (UITextField *)createTextFieldAt:(CGFloat)y placeholder:(NSString *)p {
    return [self createTextFieldAt:y placeholder:p enabled:YES];
}

- (UITextField *)createTextFieldAt:(CGFloat)y placeholder:(NSString *)p enabled:(BOOL)enabled {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(20, y, self.view.bounds.size.width - 40, 40)];
    f.placeholder = p;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.enabled = enabled;
    // dark mode changes (simulated user color)
    f.backgroundColor = [UIColor systemGray5Color];
    f.textColor = [UIColor labelColor];
    [self.scrollView addSubview:f];
    return f;
}

- (UILabel *)createLabelAt:(CGRect)rect text:(NSString *)t {
    UILabel *l = [[UILabel alloc] initWithFrame:rect];
    l.text = t;
    // dark mode changes
    l.textColor = [UIColor labelColor];
    l.font = [UIFont systemFontOfSize:12];
    return l;
}

- (UIButton *)createButtonAt:(CGRect)rect title:(NSString *)t action:(SEL)s {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = rect;
    [b setTitle:t forState:UIControlStateNormal];
    [b addTarget:self action:s forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UISlider *)createSliderAt:(CGRect)rect value:(float)v action:(SEL)s {
    UISlider *sl = [[UISlider alloc] initWithFrame:rect];
    sl.minimumValue = 0.0; sl.maximumValue = 2.0; sl.value = v;
    [sl addTarget:self action:s forControlEvents:UIControlEventValueChanged];
    return sl;
}

- (void)inputChanged:(UITextField *)sender {
    self.draftPreviewField.text = sender.text;
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

- (void)sliderChanged {
    self.tempLabel.text = [NSString stringWithFormat:@"Temperature: %.1f", self.tempSlider.value];
    self.freqLabel.text = [NSString stringWithFormat:@"Frequency Penalty: %.1f", self.freqSlider.value];
}

- (void)clearChat {
    for (UIView *subview in self.chatContainer.subviews) {
        if ([subview isKindOfClass:[MessageBubbleView class]]) {
            [subview removeFromSuperview];
        }
    }
    self.lastMessageY = 20;
    [self updateChatContainerHeight:0];
}

- (void)addMessageToChat:(NSString *)text isUser:(BOOL)isUser {
    CGFloat maxWidth = self.view.bounds.size.width * 0.7; // Comic-book style
    
    // Pre-calculate label size
    UILabel *calculationLabel = [[UILabel alloc] init];
    calculationLabel.numberOfLines = 0;
    calculationLabel.font = [UIFont systemFontOfSize:14];
    calculationLabel.text = text;
    CGSize calculationSize = [calculationLabel sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];

    CGFloat bubbleWidth = calculationSize.width + 20;
    CGFloat bubbleHeight = calculationSize.height + 20;

    MessageBubbleView *bubble = [[MessageBubbleView alloc] initWithText:text isUser:isUser];
    bubble.frame = CGRectMake(isUser ? self.view.bounds.size.width - bubbleWidth - 20 : 20, self.lastMessageY, bubbleWidth, bubbleHeight);
    
    [self.chatContainer addSubview:bubble];
    
    // Position label inside bubble
    bubble.messageLabel.frame = CGRectMake(10, 10, calculationSize.width, calculationSize.height);
    
    self.lastMessageY += bubbleHeight + 10;
    [self updateChatContainerHeight:bubbleHeight + 10];
}

- (void)updateChatContainerHeight:(CGFloat)addedHeight {
    // Dynamic height based on lastMessageY
    CGRect currentContainerFrame = self.chatContainer.frame;
    currentContainerFrame.size.height = self.lastMessageY + 20;
    self.chatContainer.frame = currentContainerFrame;
    
    self.scrollView.contentSize = CGSizeMake(self.view.bounds.size.width, self.chatContainer.frame.origin.y + self.chatContainer.frame.size.height + 200);
    [self.scrollView scrollRangeToVisible:NSMakeRange(0, self.scrollView.contentSize.height - 1)];
}

- (void)copyToClipboard {
    NSString *allText = [self accumulateAllChatText];
    if (allText.length > 0) {
        [UIPasteboard generalPasteboard].string = allText;
    }
}

- (void)speakAllMessages {
    NSString *allText = [self accumulateAllChatText];
    if (allText.length > 0) {
        AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:allText];
        utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
        [self.speechSynthesizer speakUtterance:utterance];
    }
}

- (NSString *)accumulateAllChatText {
    __block NSMutableString *allText = [[NSMutableString alloc] init];
    NSArray *subviews = [self.chatContainer.subviews sortedArrayUsingComparator:^NSComparisonResult(UIView *obj1, UIView *obj2) {
        return obj1.frame.origin.y > obj2.frame.origin.y; // Assumes they were added in order
    }];

    for (UIView *view in subviews) {
        if ([view isKindOfClass:[MessageBubbleView class]]) {
            MessageBubbleView *bubble = (MessageBubbleView *)view;
            BOOL isUser = (bubble.backgroundColor == [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0]);
            [allText appendFormat:@"%@: %@\n", isUser ? @"You" : @"AI", bubble.messageLabel.text];
        }
    }
    return [allText copy];
}

- (void)sendRequest {
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"saved_api_key"];
    NSString *prompt = self.inputField.text;
    
    if (!apiKey || apiKey.length < 5) {
        [self addMessageToChat:@"[System: Please set your API Key first]" isUser:NO];
        [self promptForApiKey];
        return;
    }
    if (prompt.length == 0) return;

    [self addMessageToChat:prompt isUser:YES];
    self.inputField.text = @"";
    self.draftPreviewField.text = @"";
    [self.view endEditing:YES];

    NSString *system = self.systemMsgField.text.length > 0 ? self.systemMsgField.text : @"You are a helpful assistant.";
    NSString *model = [self.modelPicker titleForSegmentAtIndex:self.modelPicker.selectedSegmentIndex];

    NSDictionary *payload = @{
        @"model": model,
        @"messages": @[@{@"role": @"system", @"content": system}, @{@"role": @"user", @"content": prompt}],
        @"temperature": @(self.tempSlider.value),
        @"frequency_penalty": @(self.freqSlider.value)
    };

    NSData *postData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.openai.com/v1/chat/completions"]];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    [req setHTTPBody:postData];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err) { [self addMessageToChat:err.localizedDescription isUser:NO]; return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (json[@"choices"]) {
                NSString *reply = json[@"choices"][0][@"message"][@"content"];
                [self addMessageToChat:reply isUser:NO];
            } else { [self addMessageToChat:@"[Error: Response invalid. Check key/balance.]" isUser:NO]; }
        });
    }] resume];
}

- (BOOL)textFieldShouldReturn:(UITextField *)f { [f resignFirstResponder]; return YES; }

@end
"""
    }

    for filename, content in files.items():
        with open(os.path.join(project_dir, filename), "w") as f:
            f.write(content.strip() + "\n")
    
    with open(os.path.join(project_dir, "PkgInfo"), "w") as f:
        f.write("APPL????")

    # Copy the app icon from the generated source
    icon_filename = "Icon-1024.png"
    if os.path.exists(icon_filename):
        shutil.copyfile(icon_filename, os.path.join(project_dir, icon_filename))
        print(f"Success! All files generated in '{project_dir}' with the app icon.")
    else:
        print(f"Warning: The file '{icon_filename}' not found. You will need to place it in the project root yourself.")

if __name__ == "__main__":
    generate_ezcomplete_redesign()