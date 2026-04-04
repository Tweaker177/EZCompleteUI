// ElevenLabsCloneViewController.m
// - Record audio (48kHz / 16-bit mono WAV) for high-quality cloning
// - Instant Voice Cloning (IVC): POST /v1/voices/add (multipart)
// - Professional Voice Cloning (PVC): POST /v1/voices/pvc then POST /v1/voices/pvc/:voice_id/samples
// - Hooks/logs for optional verification+training
//
// Key endpoints:
//   IVC  : POST https://api.elevenlabs.io/v1/voices/add (multipart form: name, files[], remove_background_noise?)
//   PVC  : POST https://api.elevenlabs.io/v1/voices/pvc (JSON: {name, language})
//          POST https://api.elevenlabs.io/v1/voices/pvc/:voice_id/samples (multipart: files[], remove_background_noise?)
//          GET/POST verification captcha; POST /v1/voices/pvc/:voice_id/train for model_id
// Docs:  https://elevenlabs.io/docs/api-reference/voices/ivc/create
//        https://elevenlabs.io/docs/api-reference/voices/pvc/create
//        https://elevenlabs.io/docs/api-reference/voices/pvc/samples/create
//        https://elevenlabs.io/docs/api-reference/voices/pvc/verification/captcha
//        https://elevenlabs.io/docs/api-reference/voices/pvc/verification/captcha/verify
//        https://elevenlabs.io/docs/api-reference/voices/pvc/train

#import "ElevenLabsCloneViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "EZKeyVault.h"
#import "helpers.h"

@interface ElevenLabsCloneViewController () <AVAudioRecorderDelegate, AVAudioPlayerDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *langField;
@property (nonatomic, strong) UISegmentedControl *modeControl; // 0=Instant (IVC) 1=Pro (PVC)
@property (nonatomic, strong) UISwitch *noiseSwitch; // remove_background_noise
@property (nonatomic, strong) UIButton *recordButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *uploadButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, strong) NSURL *recordedFileURL;

@property (nonatomic, copy) NSString *createdPVCVoiceID; // remember last created PVC voice
@end

@implementation ElevenLabsCloneViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Voice Cloner";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    CGFloat m = 20, w = self.view.bounds.size.width - m*2, y = 20;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w, 22)];
    title.text = @"Record clean audio, then upload for cloning.";
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [self.view addSubview:title];
    y += 26;

    self.nameField = [[UITextField alloc] initWithFrame:CGRectMake(m, y, w, 36)];
    self.nameField.placeholder = @"Voice name (e.g., MyProVoice)";
    self.nameField.borderStyle = UITextBorderStyleRoundedRect;
    self.nameField.delegate = self;
    [self.view addSubview:self.nameField];
    y += 44;

    self.langField = [[UITextField alloc] initWithFrame:CGRectMake(m, y, w, 36)];
    self.langField.placeholder = @"Language code (e.g., en)";
    self.langField.borderStyle = UITextBorderStyleRoundedRect;
    self.langField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.langField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.langField.text = @"en";
    [self.view addSubview:self.langField];
    y += 44;

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Instant (IVC)", @"Professional (PVC)"]];
    self.modeControl.frame = CGRectMake(m, y, w, 32);
    self.modeControl.selectedSegmentIndex = 1;
    [self.view addSubview:self.modeControl];
    y += 44;

    UILabel *noiseLbl = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w-60, 24)];
    noiseLbl.text = @"Remove background noise";
    noiseLbl.font = [UIFont systemFontOfSize:13];
    [self.view addSubview:noiseLbl];

    self.noiseSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(m+w-60, y-4, 60, 32)];
    [self.view addSubview:self.noiseSwitch];
    y += 40;

    self.recordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.recordButton.frame = CGRectMake(m, y, w, 48);
    [self.recordButton setTitle:@"Start Recording" forState:UIControlStateNormal];
    self.recordButton.layer.cornerRadius = 8;
    self.recordButton.backgroundColor = [UIColor systemRedColor];
    [self.recordButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.recordButton addTarget:self action:@selector(toggleRecord:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.recordButton];
    y += 56;

    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playButton.frame = CGRectMake(m, y, w, 44);
    [self.playButton setTitle:@"Play Recording" forState:UIControlStateNormal];
    self.playButton.layer.cornerRadius = 8;
    self.playButton.backgroundColor = [UIColor systemFillColor];
    [self.playButton addTarget:self action:@selector(playRecording:) forControlEvents:UIControlEventTouchUpInside];
    self.playButton.enabled = NO;
    [self.view addSubview:self.playButton];
    y += 52;

    self.uploadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.uploadButton.frame = CGRectMake(m, y, w, 50);
    [self.uploadButton setTitle:@"Upload Recording" forState:UIControlStateNormal];
    self.uploadButton.layer.cornerRadius = 8;
    self.uploadButton.backgroundColor = [UIColor systemBlueColor];
    [self.uploadButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.uploadButton addTarget:self action:@selector(uploadClone:) forControlEvents:UIControlEventTouchUpInside];
    self.uploadButton.enabled = NO;
    [self.view addSubview:self.uploadButton];
    y += 58;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(self.view.center.x, y);
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
}

#pragma mark - Recording

- (void)toggleRecord:(id)sender {
    if (!self.recorder || !self.recorder.isRecording) {
        [self startRecording];
    } else {
        [self stopRecording];
    }
}

- (void)startRecording {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeMeasurement options:AVAudioSessionCategoryOptionDefaultToSpeaker error:&err];
    if (err) { EZLogf(EZLogLevelError, @"REC", @"Session cat error: %@", err.localizedDescription); }

    [session setActive:YES error:&err];
    if (err) { EZLogf(EZLogLevelError, @"REC", @"Session activate error: %@", err.localizedDescription); }

    // 48kHz 16-bit mono WAV-friendly
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @48000,
        AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @16,
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
        AVEncoderAudioQualityKey: @(AVAudioQualityHigh)
    };

    NSString *fn = [NSString stringWithFormat:@"clone_sample_%@.wav", @((long)NSDate.date.timeIntervalSince1970)];
    NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fn]];

    self.recorder = [[AVAudioRecorder alloc] initWithURL:fileURL settings:settings error:&err];
    self.recorder.delegate = self;
    if (err || ![self.recorder prepareToRecord]) {
        NSString *msg = err.localizedDescription ?: @"Recorder prepare failed.";
        EZLogf(EZLogLevelError, @"REC", @"Prepare failed: %@", msg);
        [self showAlert:@"Record error" message:msg];
        return;
    }

    [self.recorder record];
    self.recordedFileURL = fileURL;
    [self.recordButton setTitle:@"Stop Recording" forState:UIControlStateNormal];
    self.recordButton.backgroundColor = [UIColor systemGrayColor];
    self.playButton.enabled = NO;
    self.uploadButton.enabled = NO;
    EZLogf(EZLogLevelInfo, @"REC", @"Recording to %@", fileURL.lastPathComponent);
}

- (void)stopRecording {
    [self.recorder stop];
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
    [self.recordButton setTitle:@"Start Recording" forState:UIControlStateNormal];
    self.recordButton.backgroundColor = [UIColor systemRedColor];
    self.playButton.enabled = YES;
    self.uploadButton.enabled = YES;
    EZLog(EZLogLevelInfo, @"REC", @"Stopped recording");
}

- (void)playRecording:(id)sender {
    if (!self.recordedFileURL) return;
    NSError *err = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:self.recordedFileURL error:&err];
    if (err) { [self showAlert:@"Play error" message:err.localizedDescription]; return; }
    [self.player prepareToPlay];
    [self.player play];
}

#pragma mark - Upload / Clone

- (NSString *)apiKey {
    NSString *k = [EZKeyVault loadKeyForIdentifier:EZVaultKeyElevenLabs];
    return k ?: @"";
}

- (void)uploadClone:(id)sender {
    if (!self.recordedFileURL) { [self showAlert:@"No recording" message:@"Please record a sample first."]; return; }
    if (self.nameField.text.length == 0) { [self showAlert:@"Missing name" message:@"Enter a voice name."]; return; }

    NSString *apiKey = [self apiKey];
    if (apiKey.length == 0) { [self showAlert:@"Missing API Key" message:@"Set your ElevenLabs API key in Settings."]; return; }

    [self setLoading:YES];

    if (self.modeControl.selectedSegmentIndex == 0) {
        // IVC: /v1/voices/add
        [self uploadIVCWithAPIKey:apiKey completion:^(NSString *voiceID, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setLoading:NO];
                if (err) { [self showAlert:@"IVC upload failed" message:err.localizedDescription]; return; }
                [self showAlert:@"Instant Clone Created" message:[NSString stringWithFormat:@"Voice ID: %@", voiceID]];
            });
        }];
    } else {
        // PVC: create, then upload sample
        [self createPVCWithAPIKey:apiKey completion:^(NSString *voiceID, NSError *err) {
            if (err || voiceID.length == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setLoading:NO];
                    [self showAlert:@"PVC create failed" message:err.localizedDescription ?: @"No voice id returned."];
                });
                return;
            }
            self.createdPVCVoiceID = voiceID;
            [self uploadPVCSampleWithAPIKey:apiKey voiceID:voiceID completion:^(NSError *uErr) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setLoading:NO];
                    if (uErr) { [self showAlert:@"PVC sample upload failed" message:uErr.localizedDescription]; return; }
                    [self showAlert:@"PVC Voice Updated" message:[NSString stringWithFormat:@"Voice ID: %@\nNext: complete verification and training.", voiceID]];
                    EZLogf(EZLogLevelInfo, @"PVC", @"Uploaded sample to PVC voice %@", voiceID);
                });
            }];
        }];
    }
}

- (void)uploadIVCWithAPIKey:(NSString *)apiKey completion:(void(^)(NSString *voiceID, NSError *err))completion {
    NSString *endpoint = @"https://api.elevenlabs.io/v1/voices/add";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    [req setValue:apiKey forHTTPHeaderField:@"xi-api-key"];

    NSString *boundary = [NSUUID UUID].UUIDString;
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];

    NSMutableData *body = [NSMutableData data];
    // name
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"name\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // remove_background_noise
    NSString *rbn = self.noiseSwitch.isOn ? @"true" : @"false";
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"remove_background_noise\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[rbn dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // file
    NSData *fileData = [NSData dataWithContentsOfURL:self.recordedFileURL];
    if (!fileData) {
        NSError *e = [NSError errorWithDomain:@"IVC" code:-10 userInfo:@{NSLocalizedDescriptionKey: @"Failed to read recorded file."}];
        completion(nil, e);
        return;
    }
    NSString *filename = self.recordedFileURL.lastPathComponent;
    NSString *mimetype = @"audio/wav";
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"files\"; filename=\"%@\"\r\n", filename] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimetype] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:fileData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) { EZLogf(EZLogLevelError, @"IVC", @"Network: %@", err.localizedDescription); completion(nil, err); return; }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"Server error";
            EZLogf(EZLogLevelError, @"IVC", @"%ld: %@", (long)http.statusCode, s);
            completion(nil, [NSError errorWithDomain:@"IVC" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey: s}]);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *voiceID = [json[@"voice_id"] isKindOfClass:NSString.class] ? json[@"voice_id"] : nil;
        if (!voiceID) {
            completion(nil, [NSError errorWithDomain:@"IVC" code:-11 userInfo:@{NSLocalizedDescriptionKey: @"No voice_id in response."}]);
            return;
        }
        completion(voiceID, nil);
    }];
    [t resume];
}

- (void)createPVCWithAPIKey:(NSString *)apiKey completion:(void(^)(NSString *voiceID, NSError *err))completion {
    NSString *endpoint = @"https://api.elevenlabs.io/v1/voices/pvc";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    [req setValue:apiKey forHTTPHeaderField:@"xi-api-key"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *payload = @{
        @"name": self.nameField.text ?: @"Mobile PVC",
        @"language": self.langField.text.length ? self.langField.text : @"en",
        @"description": @"Created from iOS app"
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) { EZLogf(EZLogLevelError, @"PVC", @"Create network: %@", err.localizedDescription); completion(nil, err); return; }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"Server error";
            EZLogf(EZLogLevelError, @"PVC", @"Create %ld: %@", (long)http.statusCode, s);
            completion(nil, [NSError errorWithDomain:@"PVC" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey: s}]);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *voiceID = [json[@"voice_id"] isKindOfClass:NSString.class] ? json[@"voice_id"] : nil;
        if (!voiceID) {
            completion(nil, [NSError errorWithDomain:@"PVC" code:-20 userInfo:@{NSLocalizedDescriptionKey: @"No voice_id in PVC create."}]);
            return;
        }
        completion(voiceID, nil);
    }];
    [t resume];
}

- (void)uploadPVCSampleWithAPIKey:(NSString *)apiKey voiceID:(NSString *)voiceID completion:(void(^)(NSError *err))completion {
    NSString *endpoint = [NSString stringWithFormat:@"https://api.elevenlabs.io/v1/voices/pvc/%@/samples", voiceID];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    [req setValue:apiKey forHTTPHeaderField:@"xi-api-key"];

    NSString *boundary = [NSUUID UUID].UUIDString;
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];

    NSMutableData *body = [NSMutableData data];
    // remove_background_noise
    NSString *rbn = self.noiseSwitch.isOn ? @"true" : @"false";
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"remove_background_noise\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[rbn dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // files[]
    NSData *fileData = [NSData dataWithContentsOfURL:self.recordedFileURL];
    if (!fileData) {
        completion([NSError errorWithDomain:@"PVC" code:-21 userInfo:@{NSLocalizedDescriptionKey: @"Failed to read recorded file."}]);
        return;
    }
    NSString *filename = self.recordedFileURL.lastPathComponent;
    NSString *mimetype = @"audio/wav";
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"files\"; filename=\"%@\"\r\n", filename] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimetype] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:fileData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) { EZLogf(EZLogLevelError, @"PVC", @"Upload network: %@", err.localizedDescription); completion(err); return; }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"Server error";
            EZLogf(EZLogLevelError, @"PVC", @"Upload %ld: %@", (long)http.statusCode, s);
            completion([NSError errorWithDomain:@"PVC" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey: s}]);
            return;
        }
        completion(nil);
    }];
    [t resume];
}

#pragma mark - Helpers

- (void)setLoading:(BOOL)loading {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.view.userInteractionEnabled = !loading;
        loading ? [self.spinner startAnimating] : [self.spinner stopAnimating];
    });
}

- (void)showAlert:(NSString*)title message:(NSString*)message {
    EZLogf(EZLogLevelWarning, @"UI", @"%@ — %@", title, message);
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end