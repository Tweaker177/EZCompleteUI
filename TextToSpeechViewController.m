// TextToSpeechViewController.m
// - High-quality TTS via ElevenLabs
// - Download as WAV (uncompressed) or M4A (local transcode)
// - Robust error handling + EZLog
//
// Endpoints used:
//   POST https://api.elevenlabs.io/v1/text-to-speech/:voice_id?output_format=...
//   Header: xi-api-key: <key>
// Docs: https://elevenlabs.io/docs/api-reference/text-to-speech/convert

#import "TextToSpeechViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "EZKeyVault.h"
#import "helpers.h"

static NSString * const kDefaultVoiceID = @"JBFqnCBsd6RMkjVDRZzb"; // English premade (docs sample)
static NSString * const kDefaultModelID = @"eleven_multilingual_v2";

@interface TextToSpeechViewController () <UITextViewDelegate>
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UITextField *voiceField;
@property (nonatomic, strong) UISegmentedControl *formatControl; // 0=WAV 1=M4A
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *downloadButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) AVAudioPlayer *player;
@end

@implementation TextToSpeechViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Text to Speech";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    CGFloat m = 20;
    CGFloat w = self.view.bounds.size.width - m*2;
    CGFloat y = 20;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w, 20)];
    lbl.text = @"Enter text to synthesize:";
    lbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [self.view addSubview:lbl];
    y += 24;

    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(m, y, w, 160)];
    self.textView.font = [UIFont systemFontOfSize:15];
    self.textView.layer.cornerRadius = 8;
    self.textView.layer.borderWidth = 1;
    self.textView.layer.borderColor = [UIColor systemGray4Color].CGColor;
    [self.view addSubview:self.textView];
    y += 168;

    UILabel *vLbl = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w, 20)];
    vLbl.text = @"Voice ID (uses your library):";
    vLbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    [self.view addSubview:vLbl];
    y += 20;

    self.voiceField = [[UITextField alloc] initWithFrame:CGRectMake(m, y, w, 36)];
    self.voiceField.borderStyle = UITextBorderStyleRoundedRect;
    self.voiceField.placeholder = kDefaultVoiceID;
    self.voiceField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.voiceField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.voiceField.font = [UIFont systemFontOfSize:14];
    [self.view addSubview:self.voiceField];
    y += 44;

    UILabel *fmt = [[UILabel alloc] initWithFrame:CGRectMake(m, y, w, 20)];
    fmt.text = @"Download format:";
    fmt.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    [self.view addSubview:fmt];
    y += 20;

    self.formatControl = [[UISegmentedControl alloc] initWithItems:@[@"WAV (44.1k)", @"M4A"]];
    self.formatControl.frame = CGRectMake(m, y, w, 32);
    self.formatControl.selectedSegmentIndex = 0;
    [self.view addSubview:self.formatControl];
    y += 44;

    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playButton.frame = CGRectMake(m, y, (w-10)/2, 44);
    [self.playButton setTitle:@"Synthesize & Play" forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(synthesizeAndPlay:) forControlEvents:UIControlEventTouchUpInside];
    self.playButton.layer.cornerRadius = 8;
    self.playButton.backgroundColor = [UIColor systemFillColor];
    [self.view addSubview:self.playButton];

    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.frame = CGRectMake(m + (w+10)/2, y, (w-10)/2, 44);
    [self.downloadButton setTitle:@"Synthesize & Download" forState:UIControlStateNormal];
    [self.downloadButton addTarget:self action:@selector(synthesizeAndDownload:) forControlEvents:UIControlEventTouchUpInside];
    self.downloadButton.layer.cornerRadius = 8;
    self.downloadButton.backgroundColor = [UIColor systemFillColor];
    [self.view addSubview:self.downloadButton];
    y += 54;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(self.view.center.x, y);
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
}

#pragma mark - Actions

- (void)synthesizeAndPlay:(id)sender {
    NSString *text = self.textView.text ?: @"";
    if (text.length == 0) { [self showAlert:@"Missing text" message:@"Enter text to synthesize."]; return; }

    [self setLoading:YES];
    [self performTTS:text preferredDownloadFormat:nil completion:^(NSURL *tempFile, NSString *mime, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoading:NO];
            if (err) { [self showAlert:@"TTS Error" message:err.localizedDescription]; return; }
            NSError *playErr = nil;
            self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:tempFile error:&playErr];
            if (playErr) {
                EZLogf(EZLogLevelError, @"TTS", @"Playback failed: %@", playErr.localizedDescription);
                [self showAlert:@"Playback failed" message:playErr.localizedDescription];
                return;
            }
            [self.player prepareToPlay];
            [self.player play];
            EZLog(EZLogLevelInfo, @"TTS", @"Playback started");
        });
    }];
}

- (void)synthesizeAndDownload:(id)sender {
    NSString *text = self.textView.text ?: @"";
    if (text.length == 0) { [self showAlert:@"Missing text" message:@"Enter text to synthesize."]; return; }

    NSString *format = (self.formatControl.selectedSegmentIndex == 0) ? @"wav" : @"m4a";
    [self setLoading:YES];
    [self performTTS:text preferredDownloadFormat:format completion:^(NSURL *tempFile, NSString *mime, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoading:NO];
            if (err) { [self showAlert:@"TTS Error" message:err.localizedDescription]; return; }

            UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[tempFile] applicationActivities:nil];
            avc.popoverPresentationController.sourceView = self.downloadButton;
            [self presentViewController:avc animated:YES completion:nil];
            EZLogf(EZLogLevelInfo, @"TTS", @"Shared file: %@", tempFile.lastPathComponent);
        });
    }];
}

#pragma mark - Core TTS

- (NSString *)elevenLabsAPIKey {
    NSString *key = [EZKeyVault loadKeyForIdentifier:EZVaultKeyElevenLabs];
    return key;
}

// Returns a temp file URL for playback or sharing.
- (void)performTTS:(NSString *)text
preferredDownloadFormat:(NSString * _Nullable)preferred // @"wav" or @"m4a" or nil (playback only)
        completion:(void(^)(NSURL *tempFile, NSString *mime, NSError *err))completion {

    NSString *apiKey = [self elevenLabsAPIKey];
    if (apiKey.length == 0) {
        NSError *e = [NSError errorWithDomain:@"TTS" code:401 userInfo:@{NSLocalizedDescriptionKey: @"Missing ElevenLabs API key (Settings > ElevenLabs)."}];
        completion(nil, nil, e);
        return;
    }

    NSString *voiceID = self.voiceField.text.length ? self.voiceField.text : kDefaultVoiceID;

    // Decide output format:
    // - WAV path attempts uncompressed wav_44100 (Pro). If server rejects, fallback to pcm_44100 then wrap with WAV header.
    // - M4A path fetches mp3_44100_192 (highest listed MP3 tier) and locally transcodes to M4A.
    NSString *outputFormat = @"mp3_44100_128";
    BOOL wantWAV = NO, wantM4A = NO;
    if ([preferred isEqualToString:@"wav"]) {
        outputFormat = @"wav_44100"; // Pro tier needed per docs
        wantWAV = YES;
    } else if ([preferred isEqualToString:@"m4a"]) {
        outputFormat = @"mp3_44100_192";
        wantM4A = YES;
    }

    // Build request
    NSString *urlStr = [NSString stringWithFormat:@"https://api.elevenlabs.io/v1/text-to-speech/%@?output_format=%@", voiceID, outputFormat];
    NSURL *url = [NSURL URLWithString:urlStr];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60.0];
    req.HTTPMethod = @"POST";
    [req setValue:apiKey forHTTPHeaderField:@"xi-api-key"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"text": text ?: @"",
        @"model_id": kDefaultModelID
    };
    NSError *jsonErr = nil;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr) {
        EZLogf(EZLogLevelError, @"TTS", @"JSON encode failed: %@", jsonErr.localizedDescription);
        completion(nil, nil, jsonErr);
        return;
    }

    EZLogf(EZLogLevelInfo, @"TTS", @"Request: /text-to-speech %@ format=%@", voiceID, outputFormat);

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.timeoutIntervalForRequest = 60;
    cfg.timeoutIntervalForResource = 120;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            EZLogf(EZLogLevelError, @"TTS", @"Network error: %@", error.localizedDescription);
            completion(nil, nil, error);
            return;
        }
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *mime = response.MIMEType ?: @"application/octet-stream";

        if (http.statusCode == 429) {
            NSError *e = [NSError errorWithDomain:@"TTS" code:429 userInfo:@{NSLocalizedDescriptionKey: @"Rate limited by ElevenLabs (HTTP 429). Please retry in a moment."}];
            EZLog(EZLogLevelWarning, @"TTS", @"HTTP 429 rate limit");
            completion(nil, mime, e);
            return;
        }
        if (http.statusCode < 200 || http.statusCode >= 300 || data.length == 0) {
            NSString *serverMsg = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"Unknown server error";
            NSError *e = [NSError errorWithDomain:@"TTS" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey: serverMsg}];
            EZLogf(EZLogLevelError, @"TTS", @"Server error %ld: %@", (long)http.statusCode, serverMsg);
            // WAV fallback: if asked for wav and server failed (plan?), retry as pcm_44100 then wrap
            if (wantWAV && http.statusCode == 422) {
                [self retryPCMThenWrap:text voiceID:voiceID apiKey:apiKey completion:completion];
                return;
            }
            completion(nil, mime, e);
            return;
        }

        // Save response to temp and optionally transcode
        if (wantM4A) {
            // Save as .mp3 then convert to .m4a
            NSString *mp3Name = [NSString stringWithFormat:@"tts_%@.mp3", @((long)NSDate.date.timeIntervalSince1970)];
            NSURL *mp3URL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:mp3Name]];
            NSError *writeErr = nil;
            [data writeToURL:mp3URL options:NSDataWritingAtomic error:&writeErr];
            if (writeErr) {
                EZLogf(EZLogLevelError, @"TTS", @"Write MP3 failed: %@", writeErr.localizedDescription);
                completion(nil, mime, writeErr);
                return;
            }
            [self convertToM4AFromURL:mp3URL completion:^(NSURL *m4aURL, NSError *convErr) {
                if (convErr) {
                    completion(nil, mime, convErr);
                } else {
                    completion(m4aURL, @"audio/mp4", nil);
                }
            }];
            return;
        }

        if (wantWAV) {
            // If mime indicates raw PCM (or if server gave PCM anyway), wrap in WAV
            BOOL looksPCM = [mime containsString:@"application/octet-stream"] || [mime containsString:@"audio/L16"] || [mime containsString:@"audio/x-pcm"];
            if (looksPCM) {
                NSData *wav = [self wavDataFromPCM:data sampleRate:44100 channels:1 bitsPerSample:16];
                if (!wav) {
                    NSError *e = [NSError errorWithDomain:@"TTS" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to wrap PCM into WAV."}];
                    completion(nil, mime, e);
                    return;
                }
                NSString *wavName = [NSString stringWithFormat:@"tts_%@.wav", @((long)NSDate.date.timeIntervalSince1970)];
                NSURL *wavURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:wavName]];
                NSError *wErr = nil;
                [wav writeToURL:wavURL options:NSDataWritingAtomic error:&wErr];
                if (wErr) {
                    completion(nil, mime, wErr);
                    return;
                }
                completion(wavURL, @"audio/wav", nil);
                return;
            }
        }

        // Default: write whatever we got with an extension based on mime
        NSString *ext = @"bin";
        if ([mime containsString:@"wav"]) ext = @"wav";
        else if ([mime containsString:@"mpeg"]) ext = @"mp3";
        else if ([mime containsString:@"mp4"] || [mime containsString:@"m4a"]) ext = @"m4a";
        NSString *name = [NSString stringWithFormat:@"tts_%@.%@", @((long)NSDate.date.timeIntervalSince1970), ext];
        NSURL *tmpURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        NSError *wErr = nil;
        [data writeToURL:tmpURL options:NSDataWritingAtomic error:&wErr];
        if (wErr) {
            EZLogf(EZLogLevelError, @"TTS", @"Write file failed: %@", wErr.localizedDescription);
            completion(nil, mime, wErr);
            return;
        }
        completion(tmpURL, mime, nil);
    }];
    [task resume];
}

- (void)retryPCMThenWrap:(NSString *)text
                 voiceID:(NSString *)voiceID
                  apiKey:(NSString *)apiKey
              completion:(void(^)(NSURL *tempFile, NSString *mime, NSError *err))completion {

    NSString *urlStr = [NSString stringWithFormat:@"https://api.elevenlabs.io/v1/text-to-speech/%@?output_format=%@", voiceID, @"pcm_44100"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60.0];
    req.HTTPMethod = @"POST";
    [req setValue:apiKey forHTTPHeaderField:@"xi-api-key"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"text": text ?: @"", @"model_id": kDefaultModelID};
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    EZLog(EZLogLevelWarning, @"TTS", @"Falling back to pcm_44100 then WAV wrapping");

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * data, NSURLResponse *resp, NSError *error) {
        if (error) { completion(nil, resp.MIMEType, error); return; }
        if (data.length == 0) {
            NSError *e = [NSError errorWithDomain:@"TTS" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Empty audio in fallback."}];
            completion(nil, resp.MIMEType, e);
            return;
        }
        NSData *wav = [self wavDataFromPCM:data sampleRate:44100 channels:1 bitsPerSample:16];
        if (!wav) {
            NSError *e = [NSError errorWithDomain:@"TTS" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to wrap PCM into WAV (fallback)."}];
            completion(nil, resp.MIMEType, e);
            return;
        }
        NSURL *wavURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                                [NSString stringWithFormat:@"tts_%@.wav", @((long)NSDate.date.timeIntervalSince1970)]]];
        NSError *wErr = nil;
        [wav writeToURL:wavURL options:NSDataWritingAtomic error:&wErr];
        completion(wavURL, @"audio/wav", wErr);
    }] resume];
}

#pragma mark - Utils

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

// Wrap raw PCM S16LE into a WAV container
- (NSData *)wavDataFromPCM:(NSData *)pcm sampleRate:(int)sampleRate channels:(short)channels bitsPerSample:(short)bits {
    if (!pcm) return nil;
    uint32_t dataLen = (uint32_t)pcm.length;
    uint32_t chunkSize = 36 + dataLen;
    uint16_t audioFormat = 1; // PCM
    uint32_t byteRate = sampleRate * channels * (bits / 8);
    uint16_t blockAlign = channels * (bits / 8);

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataLen];
    // RIFF
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&chunkSize length:4];
    [wav appendBytes:"WAVE" length:4];
    // fmt
    [wav appendBytes:"fmt " length:4];
    uint32_t subchunk1Size = 16;
    [wav appendBytes:&subchunk1Size length:4];
    [wav appendBytes:&audioFormat length:2];
    [wav appendBytes:&channels length:2];
    [wav appendBytes:&sampleRate length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bits length:2];
    // data
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataLen length:4];
    [wav appendData:pcm];
    return wav;
}

- (void)convertToM4AFromURL:(NSURL *)srcURL completion:(void(^)(NSURL *m4aURL, NSError *err))completion {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:srcURL options:nil];
    if (![[AVAssetExportSession exportPresetsCompatibleWithAsset:asset] containsObject:AVAssetExportPresetAppleM4A]) {
        NSError *e = [NSError errorWithDomain:@"TTS" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"M4A export not supported on this device."}];
        completion(nil, e);
        return;
    }
    NSString *m4aName = [[srcURL.lastPathComponent stringByDeletingPathExtension] stringByAppendingPathExtension:@"m4a"];
    NSURL *dstURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:m4aName]];

    AVAssetExportSession *exp = [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    exp.outputURL = dstURL;
    exp.outputFileType = AVFileTypeAppleM4A;
    [exp exportAsynchronouslyWithCompletionHandler:^{
        if (exp.status == AVAssetExportSessionStatusCompleted) {
            completion(dstURL, nil);
        } else {
            NSError *e = exp.error ?: [NSError errorWithDomain:@"TTS" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Unknown M4A export failure."}];
            EZLogf(EZLogLevelError, @"TTS", @"M4A export failed: %@", e.localizedDescription);
            completion(nil, e);
        }
    }];
}

@end