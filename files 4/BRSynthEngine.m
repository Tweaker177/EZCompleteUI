// BRSynthEngine.m
// BrainRotGame
// EZCompleteUI
//
// See BRSynthEngine.h for the overall purpose. Implementation notes:
//
//   - Each note is a hand-generated mono PCM buffer: a triangle wave
//     (via arcsin(sin(x)) shaping, cheap and warm) under a short
//     exponential decay envelope, scheduled on a single AVAudioPlayerNode.
//     AVAudioEngine happily overlaps scheduled buffers, so simultaneous or
//     closely-spaced notes layer naturally without extra voice management.
//   - Frequency math mirrors the web prototype: 220 Hz (A3) as the base,
//     scaled by 2^(semitone/12).

#import "BRSynthEngine.h"
#import <AVFoundation/AVFoundation.h>
#import <math.h>

static const double kBRSynthSampleRate  = 44100.0;
static const double kBRSynthBaseFreqHz  = 220.0; // A3
static const double kBRSynthNoteSeconds = 0.35;

@interface BRSynthEngine ()
@property (nonatomic, strong, nullable) AVAudioEngine *engine;
@property (nonatomic, strong, nullable) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong, nullable) AVAudioFormat *pcmFormat;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *hitQueue; // queued velocities, oldest first
@property (nonatomic, assign) CFTimeInterval lastScheduleTime;
@property (nonatomic, assign, readwrite) BOOL isStarted;
@end

@implementation BRSynthEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        _rootSemitone = 7; // G — matches the default the prototype shipped with
        _scale        = BRSynthScalePentatonic;
        _tempoBPM     = 120;
        _hitQueue     = [NSMutableArray array];
    }
    return self;
}

#pragma mark - Lifecycle

- (void)start {
    if (self.isStarted) return;

    self.engine     = [[AVAudioEngine alloc] init];
    self.playerNode = [[AVAudioPlayerNode alloc] init];
    self.pcmFormat  = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kBRSynthSampleRate
                                                                      channels:1];

    [self.engine attachNode:self.playerNode];
    [self.engine connect:self.playerNode to:self.engine.mainMixerNode format:self.pcmFormat];

    NSError *startError = nil;
    [self.engine startAndReturnError:&startError];
    if (startError) {
        NSLog(@"[BRSynthEngine] engine start failed: %@", startError.localizedDescription);
        self.engine = nil;
        self.playerNode = nil;
        return;
    }

    [self.playerNode play];
    self.isStarted = YES;
}

- (void)stop {
    [self.playerNode stop];
    [self.engine stop];
    self.engine     = nil;
    self.playerNode = nil;
    self.isStarted  = NO;
    [self.hitQueue removeAllObjects];
}

#pragma mark - Queue

- (void)queueHitWithVelocity:(float)velocity {
    if (self.hitQueue.count >= 8) {
        [self.hitQueue removeObjectAtIndex:0];
    }
    [self.hitQueue addObject:@(velocity)];
}

- (void)tick {
    if (!self.isStarted || self.hitQueue.count == 0) return;

    CFTimeInterval now = CACurrentMediaTime();
    // Eighth-note grid at the current tempo — e.g. 120 BPM → 0.25s between notes.
    CFTimeInterval gridInterval = (60.0 / MAX(self.tempoBPM, 1)) / 2.0;
    if (now - self.lastScheduleTime < gridInterval) return;

    self.lastScheduleTime = now;
    float velocity = self.hitQueue.firstObject.floatValue;
    [self.hitQueue removeObjectAtIndex:0];
    [self playRandomNoteWithVelocity:velocity];
}

#pragma mark - Note generation

- (NSArray<NSNumber *> *)currentScaleDegrees {
    switch (self.scale) {
        case BRSynthScaleMajor:      return @[@0, @2, @4, @5, @7, @9, @11];
        case BRSynthScaleMinor:      return @[@0, @2, @3, @5, @7, @8, @10];
        case BRSynthScalePentatonic: return @[@0, @2, @4, @7, @9];
    }
}

- (void)playRandomNoteWithVelocity:(float)velocity {
    if (!self.isStarted) return;

    NSArray<NSNumber *> *degrees = [self currentScaleDegrees];
    NSInteger degree    = degrees[arc4random_uniform((uint32_t)degrees.count)].integerValue;
    NSInteger octaveUp  = (arc4random_uniform(2) == 1) ? 12 : 0;
    NSInteger semitone  = self.rootSemitone + degree + octaveUp;
    double freqHz = kBRSynthBaseFreqHz * pow(2.0, semitone / 12.0);

    AVAudioFrameCount frameCount = (AVAudioFrameCount)(kBRSynthSampleRate * kBRSynthNoteSeconds);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.pcmFormat
                                                              frameCapacity:frameCount];
    if (!buffer) return;
    buffer.frameLength = frameCount;
    float *samples = buffer.floatChannelData[0];

    float peakAmplitude = MIN(0.35f, 0.12f + velocity * 0.10f);
    for (AVAudioFrameCount i = 0; i < frameCount; i++) {
        double t = (double)i / kBRSynthSampleRate;
        double phase = 2.0 * M_PI * freqHz * t;
        double triangle = (2.0 / M_PI) * asin(sin(phase));      // triangle wave, no aliasing tables needed
        double envelope = exp(-t * 7.0);                        // short percussive decay
        samples[i] = (float)(triangle * envelope * peakAmplitude);
    }

    [self.playerNode scheduleBuffer:buffer completionHandler:nil];
}

@end
