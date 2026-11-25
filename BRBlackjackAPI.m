// BRBlackjackAPI.m
// EZCompleteUI v1.0
//
// Purpose:
//   See BRBlackjackAPI.h. Builds authenticated POST requests to the
//   br-blackjack Edge Function, refreshes an expired session token through
//   EZAuthManager, retries once on transient network errors and turns every
//   failure into a short message the UI can show as-is.
//
// Changes from v0 (new file):
//   - Initial version.

#import "BRBlackjackAPI.h"
#import "EZAuthManager.h"
#import "EZSupabaseConfig.h"
#import <AVFoundation/AVFoundation.h>

extern BOOL BRSlotSoundEnabled(void);

static const NSTimeInterval kBlackjackRequestTimeout = 12.0;

@implementation BRBlackjackAPI

+ (NSURLSession *)session {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = kBlackjackRequestTimeout;
        configuration.waitsForConnectivity = NO;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

+ (void)performAction:(NSString *)action params:(NSDictionary *)params completion:(BRBlackjackCompletion)completion {
    [self performAction:action params:params attempt:1 completion:completion];
}

+ (void)performAction:(NSString *)action
               params:(NSDictionary *)params
              attempt:(NSInteger)attempt
           completion:(BRBlackjackCompletion)completion {
    // getValidAccessToken refreshes the session first when it is close to expiry.
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *tokenError) {
        if (token.length == 0) {
            [self finish:completion json:nil status:0
                 message:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Error.SignIn", nil, NSBundle.mainBundle, @"Please sign in to play blackjack.", nil)];
            return;
        }

        NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:params ?: @{}];
        body[@"action"] = action;
        NSError *encodeError = nil;
        NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encodeError];
        if (!bodyData) {
            [self finish:completion json:nil status:0 message:@"Couldn't build that request."];
            return;
        }

        NSURL *url = [NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/br-blackjack"]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        request.HTTPBody = bodyData;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];

        [[[self session] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSInteger status = [(NSHTTPURLResponse *)response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;

            // Transient failures (offline blip, timeout, 502/503/504): try once more.
            BOOL transient = networkError != nil || status == 502 || status == 503 || status == 504;
            if (transient && attempt < 2) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self performAction:action params:params attempt:attempt + 1 completion:completion];
                });
                return;
            }
            if (networkError) {
                [self finish:completion json:nil status:0
                     message:NSLocalizedStringWithDefaultValue(@"BRBlackjack.Error.Network", nil, NSBundle.mainBundle, @"Connection problem. Reconnecting…", nil)];
                return;
            }

            id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *json = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
            if (status >= 200 && status < 300 && json) {
                [self finish:completion json:json status:status message:nil];
                return;
            }
            NSString *message = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"]
                : NSLocalizedStringWithDefaultValue(@"BRBlackjack.Error.Generic", nil, NSBundle.mainBundle, @"Blackjack is temporarily unavailable.", nil);
            [self finish:completion json:json status:status message:message];
        }] resume];
    }];
}

+ (void)finish:(BRBlackjackCompletion)completion json:(NSDictionary *)json status:(NSInteger)status message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(json, status, message); });
}

@end


@implementation BRBlackjackAmbience

static AVAudioEngine *BJAmbienceEngine;
static AVAudioPlayerNode *BJAmbienceNode;
static AVAudioPCMBuffer *BJAmbienceBuffer;

+ (void)start {
    if (!BRSlotSoundEnabled()) return;
    @try {
        if (!BJAmbienceBuffer) [self buildLoop];
        if (!BJAmbienceNode) return;
        if (!BJAmbienceEngine.isRunning) [BJAmbienceEngine startAndReturnError:nil];
        if (!BJAmbienceNode.isPlaying) [BJAmbienceNode play];
    } @catch (NSException *e) {
    }
}

+ (void)stop {
    @try { [BJAmbienceNode pause]; } @catch (NSException *e) {
    }
}

/// Decodes crowded_casino once into a PCM buffer scheduled with
/// BufferLoops — the slot picker's gapless-loop recipe, at a lower
/// mixer volume than the picker's, a quiet bed under the lobby. A bad or
/// missing file stays silent; it never crashes the flow.
+ (void)buildLoop {
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"crowded_casino" withExtension:@"caf" subdirectory:@"sounds"];
    if (!url) url = [[NSBundle mainBundle] URLForResource:@"crowded_casino" withExtension:@"caf"];
    if (!url) url = [[NSBundle mainBundle] URLForResource:@"crowded_casino" withExtension:@"mp3" subdirectory:@"sounds"];
    if (!url) url = [[NSBundle mainBundle] URLForResource:@"crowded_casino" withExtension:@"mp3"];
    if (!url) return;
    @try {
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:nil];
        AVAudioFormat *format = file.processingFormat;
        if (!file || file.length == 0 || !format || format.sampleRate == 0 || format.channelCount == 0) return;
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)file.length];
        if (!buffer || ![file readIntoBuffer:buffer error:nil] || buffer.frameLength == 0) return;
        if (buffer.format.commonFormat == AVAudioPCMFormatFloat32 && !buffer.format.interleaved && buffer.floatChannelData) {
            AVAudioFrameCount frames = buffer.frameLength;
            float * const *channels = buffer.floatChannelData;
            NSUInteger channelCount = buffer.format.channelCount;
            while (frames > 0) {
                BOOL silent = YES;
                for (NSUInteger c = 0; c < channelCount; c++) {
                    if (fabsf(channels[c][frames - 1]) > 0.0005f) { silent = NO; break; }
                }
                if (!silent) break;
                frames--;
            }
            buffer.frameLength = frames;
        }
        if (buffer.frameLength == 0) return;
        BJAmbienceBuffer = buffer;
        BJAmbienceEngine = [AVAudioEngine new];
        BJAmbienceNode = [AVAudioPlayerNode new];
        [BJAmbienceEngine attachNode:BJAmbienceNode];
        [BJAmbienceEngine connect:BJAmbienceNode to:BJAmbienceEngine.mainMixerNode format:file.processingFormat];
        BJAmbienceEngine.mainMixerNode.outputVolume = .25;
        [BJAmbienceNode scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    } @catch (NSException *e) {
    }
}

@end
