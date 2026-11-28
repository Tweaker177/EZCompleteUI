    // BRRouletteAudio.m
// EZCompleteUI v1.0
//
// Purpose:
//   See BRRouletteAudio.h. Every sound is rendered once at launch on a
//   background queue into mono float buffers (plain C below), then played through
//   a small pool of AVAudioPlayerNodes. The same approach as the slot machines'
//   audio classes: Playback category with MixWithOthers, one shared sound switch
//   (BRSlotSoundEnabled), engine restart after interruptions, loops paused while
//   the app is in the background.
//
// Changes from v0 (new file):
//   - Initial version.


#import "BRRouletteAudio.h"
#import "BRSlotChatBar.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static const int kRLVoiceCount = 6;
static const double kRLSpinSeconds = 10.0; // length of the pre-rendered spin sound

// ==== DSP BEGIN (plain C: also compiled on its own by the offline checks) ====

static const double kSR = 44100.0;

typedef struct { uint64_t s; } RLNoise;
static inline float RLNoiseNext(RLNoise *noise) {
    noise->s ^= noise->s << 13; noise->s ^= noise->s >> 7; noise->s ^= noise->s << 17;
    return (float)((noise->s >> 40) & 0xFFFFFF) / 8388607.5f - 1.0f;
}
static inline double RLMidiHz(double midi) { return 440.0 * pow(2.0, (midi - 69.0) / 12.0); }
static inline double RLSmoothstep(double edge0, double edge1, double x) {
    double t = (x - edge0) / (edge1 - edge0);
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    return t * t * (3.0 - 2.0 * t);
}

/// A mono sample buffer being mixed into. With wrap set (for loops), anything
/// that runs past the end continues at the start so the loop seam is silent.
typedef struct { float *data; long frames; int wrap; RLNoise noise; } RLTrack;

static RLTrack RLTrackMake(double seconds, int wrap, uint64_t seed) {
    RLTrack track;
    track.frames = (long)(seconds * kSR);
    track.data = (float *)calloc((size_t)track.frames, sizeof(float));
    track.wrap = wrap;
    track.noise.s = seed;
    return track;
}

static inline void RLTrackAdd(RLTrack *track, long index, float value) {
    if (index < 0) return;
    if (index >= track->frames) {
        if (!track->wrap) return;
        index %= track->frames;
    }
    track->data[index] += value;
}

static void RLNormalize(RLTrack *track, float peak) {
    float maxValue = 0;
    for (long i = 0; i < track->frames; i++) { float v = fabsf(track->data[i]); if (v > maxValue) maxValue = v; }
    if (maxValue < 1e-6f) return;
    float gain = peak / maxValue;
    for (long i = 0; i < track->frames; i++) track->data[i] *= gain;
}

/// Band-pass biquad (constant 0 dB peak), transposed direct form II.
typedef struct { double b0, b2, a1, a2, z1, z2; } RLBand;
static void RLBandSet(RLBand *band, double hz, double q) {
    double w = 2.0 * M_PI * hz / kSR;
    double alpha = sin(w) / (2.0 * q);
    double a0 = 1.0 + alpha;
    band->b0 = alpha / a0; band->b2 = -alpha / a0;
    band->a1 = -2.0 * cos(w) / a0; band->a2 = (1.0 - alpha) / a0;
}
static inline double RLBandRun(RLBand *band, double x) {
    double y = band->b0 * x + band->z1;
    band->z1 = -band->a1 * y + band->z2;
    band->z2 = band->b2 * x - band->a2 * y;
    return y;
}

/// A short burst of band-passed noise: the "click" of chips, wood and ball.
static void RLAddNoiseBurst(RLTrack *track, double start, double duration, double amp, double centerHz, double q) {
    RLBand band = {0, 0, 0, 0, 0, 0};
    RLBandSet(&band, centerHz, q);
    long first = (long)(start * kSR), count = (long)(duration * kSR);
    for (long k = 0; k < count; k++) {
        double env = exp(-6.0 * (double)k / (double)count);
        RLTrackAdd(track, first + k, (float)(RLBandRun(&band, RLNoiseNext(&track->noise)) * amp * env));
    }
}

/// Sine with a fast attack and exponential decay.
static void RLAddTone(RLTrack *track, double start, double hz, double amp, double decay, double harmonic2) {
    long first = (long)(start * kSR), count = (long)(decay * 6.0 * kSR);
    double step = 2.0 * M_PI * hz / kSR;
    for (long k = 0; k < count; k++) {
        double t = (double)k / kSR;
        double env = exp(-t / decay) * fmin(1.0, t / 0.003);
        double wave = sin(step * k) + harmonic2 * sin(2.0 * step * k);
        RLTrackAdd(track, first + k, (float)(wave * amp * env));
    }
}

/// Struck-bell tone: inharmonic partials that die away at different speeds.
static void RLAddBell(RLTrack *track, double start, double hz, double amp, double decay) {
    static const double ratio[4] = { 1.0, 2.76, 5.40, 8.93 };
    static const double level[4] = { 1.0, 0.45, 0.22, 0.10 };
    static const double life[4] = { 1.0, 0.6, 0.38, 0.22 };
    for (int p = 0; p < 4; p++) {
        if (hz * ratio[p] > 15000.0) continue;
        RLAddTone(track, start, hz * ratio[p], amp * level[p], decay * life[p], 0.0);
    }
}

/// Electric-piano style chord tone with a slight tremolo.
static void RLAddKeys(RLTrack *track, double start, double hz, double amp, double decay) {
    long first = (long)(start * kSR), count = (long)(decay * 5.0 * kSR);
    double step = 2.0 * M_PI * hz / kSR;
    for (long k = 0; k < count; k++) {
        double t = (double)k / kSR;
        double env = exp(-t / decay) * fmin(1.0, t / 0.006);
        double tremolo = 1.0 + 0.12 * sin(2.0 * M_PI * 4.2 * t);
        double wave = sin(step * k) + 0.30 * sin(2.0 * step * k) * exp(-t / (decay * 0.4)) + 0.08 * sin(4.0 * step * k);
        RLTrackAdd(track, first + k, (float)(wave * amp * env * tremolo));
    }
}

/// One tick of the ball hitting a pocket divider.
static void RLAddTick(RLTrack *track, double start, double amp, double hz) {
    RLAddTone(track, start, hz, amp * 0.55, 0.006, 0.0);
    RLAddNoiseBurst(track, start, 0.012, amp, hz * 2.4, 1.8);
}

// ---- Chips ----

static RLTrack RLRenderChip(int variant, int remove) {
    RLTrack track = RLTrackMake(0.20, 0, 0x9E3779B97F4A7C15ULL + (uint64_t)variant);
    double base = remove ? 1500.0 : 2300.0;
    double detune = 1.0 + 0.06 * variant;
    RLAddTick(&track, 0.000, 0.9, base * detune);
    RLAddTick(&track, 0.026, 0.6, base * 1.25 * detune);
    if (!remove) RLAddTick(&track, 0.050, 0.45, base * 1.5 * detune);
    RLNormalize(&track, remove ? 0.55f : 0.7f);
    return track;
}

// ---- Betting open / closed ----

static RLTrack RLRenderBettingOpen(void) {
    RLTrack track = RLTrackMake(1.4, 0, 0x1234ABCD5678EF01ULL);
    RLAddBell(&track, 0.00, RLMidiHz(88), 0.8, 0.55);   // E6
    RLAddBell(&track, 0.17, RLMidiHz(95), 0.55, 0.50);  // B6
    RLNormalize(&track, 0.7f);
    return track;
}

static RLTrack RLRenderBettingClosed(void) {
    RLTrack track = RLTrackMake(0.5, 0, 0x0F1E2D3C4B5A6978ULL);
    double hits[2] = { 0.0, 0.17 };
    double pitch[2] = { 540.0, 430.0 };
    for (int h = 0; h < 2; h++) {
        RLAddTone(&track, hits[h], pitch[h], 0.9, 0.035, 0.5);
        RLAddTone(&track, hits[h], pitch[h] * 1.9, 0.35, 0.02, 0.0);
        RLAddNoiseBurst(&track, hits[h], 0.015, 0.7, 1800.0, 1.2);
    }
    RLNormalize(&track, 0.8f);
    return track;
}

// ---- The spin: wheel whirr, rolling ball, slowing ticks, bounces, drop ----

static RLTrack RLRenderSpin(void) {
    const double total = kRLSpinSeconds;
    RLTrack track = RLTrackMake(total, 0, 0xC0FFEE1234567890ULL);

    // Wheel: a low hum with a soft whirr that dies down as the wheel slows.
    double humPhase = 0, lowNoise = 0;
    for (long k = 0; k < track.frames; k++) {
        double t = (double)k / kSR;
        double hz = 62.0 + 26.0 * exp(-t / 4.0);
        humPhase += 2.0 * M_PI * hz / kSR;
        lowNoise += 0.02 * ((double)RLNoiseNext(&track.noise) - lowNoise);
        double env = 0.20 * exp(-t / 6.0) + 0.035;
        double fadeIn = fmin(1.0, t / 0.08);
        track.data[k] += (float)((0.55 * sin(humPhase) + 9.0 * lowNoise) * env * fadeIn);
    }

    // Ball rolling around the rim: band-passed noise whose pitch and lap rate fall.
    RLBand band = {0, 0, 0, 0, 0, 0};
    double lapPhase = 0;
    for (long k = 0; k < track.frames; k++) {
        double t = (double)k / kSR;
        if (t > 6.0) break;
        if ((k & 63) == 0) RLBandSet(&band, 2400.0 - 1300.0 * fmin(1.0, t / 5.6), 1.6);
        double lapHz = 9.0 - 6.0 * fmin(1.0, t / 5.6);
        lapPhase += 2.0 * M_PI * lapHz / kSR;
        double swirl = 0.55 + 0.45 * sin(lapPhase);
        double fade = (1.0 - RLSmoothstep(4.6, 6.0, t)) * fmin(1.0, t / 0.15);
        double env = 0.30 * (1.0 - 0.45 * t / 6.0) * swirl * fade;
        track.data[k] += (float)(RLBandRun(&band, RLNoiseNext(&track.noise)) * env * 3.2);
    }

    // The ball drops into the pocket ring: ticks that space out more and more.
    double tickTime = 4.1, gap = 0.045;
    int tickIndex = 0;
    while (tickTime < total - 1.25) {
        double jitter = 1.0 + 0.04 * (double)RLNoiseNext(&track.noise);
        double amp = 0.45 + 0.30 * fabs((double)RLNoiseNext(&track.noise));
        double pitch = 2000.0 + 700.0 * (double)RLNoiseNext(&track.noise) + 20.0 * tickIndex;
        RLAddTick(&track, tickTime, amp, pitch);
        tickTime += gap * jitter;
        gap *= 1.09;
        tickIndex++;
    }

    // Last bounces and the drop into the winning pocket.
    RLAddTick(&track, total - 1.05, 0.90, 1800.0);
    RLAddTick(&track, total - 0.62, 0.70, 1500.0);
    RLAddTick(&track, total - 0.34, 0.80, 1250.0);
    RLAddTick(&track, total - 0.16, 1.00, 900.0);
    RLAddTone(&track, total - 0.16, 300.0, 0.7, 0.05, 0.4);   // the dull thunk of the dock
    RLAddNoiseBurst(&track, total - 0.16, 0.03, 0.5, 700.0, 0.9);

    RLNormalize(&track, 0.9f);
    return track;
}

// ---- Win and loss ----

/// A coin jingle: ascending bells plus a sparkle of tiny high ticks.
static RLTrack RLRenderWin(int notes, double spacing, int sparkle, double seconds) {
    RLTrack track = RLTrackMake(seconds, 0, 0xABCDEF0123456789ULL + (uint64_t)notes);
    static const int scale[8] = { 0, 2, 4, 7, 9, 12, 14, 16 };      // major pentatonic run
    for (int n = 0; n < notes; n++) {
        double midi = 84.0 + scale[n % 8] + 12.0 * (n / 8);
        if (midi > 108.0) midi -= 12.0;
        RLAddBell(&track, 0.02 + n * spacing, RLMidiHz(midi), 0.55 + 0.25 * (double)n / (double)notes, 0.45);
    }
    double end = 0.02 + notes * spacing;
    RLAddBell(&track, end, RLMidiHz(72), 0.7, 0.9);     // landing chord C5 E5 G5
    RLAddBell(&track, end, RLMidiHz(76), 0.55, 0.9);
    RLAddBell(&track, end, RLMidiHz(79), 0.5, 0.9);
    for (int s = 0; s < sparkle; s++) {
        double when = (double)s / (double)sparkle * (end + 0.4);
        double jitter = (double)(RLNoiseNext(&track.noise) * 0.5f + 0.5f) * 0.03;
        RLAddNoiseBurst(&track, when + jitter, 0.012, 0.18, 7000.0, 3.0);
    }
    RLNormalize(&track, 0.85f);
    return track;
}

static RLTrack RLRenderLoss(void) {
    RLTrack track = RLTrackMake(1.2, 0, 0x5555AAAA5555AAAAULL);
    RLAddTone(&track, 0.00, RLMidiHz(64), 0.6, 0.30, 0.25);   // E4
    RLAddTone(&track, 0.22, RLMidiHz(60), 0.6, 0.38, 0.25);   // C4
    RLNormalize(&track, 0.5f);
    return track;
}

// ---- Lounge bed: electric piano, walking bass and brushes (loops seamlessly) ----

static RLTrack RLRenderAmbience(void) {
    const double bpm = 84.0, beat = 60.0 / bpm;
    const int bars = 4;
    RLTrack track = RLTrackMake(beat * 4.0 * bars, 1, 0x7777EEEE7777EEEEULL);

    // Dm9, G13, Cmaj9, A7 (a ii-V-I-VI turnaround in C).
    static const int voicing[4][4] = { {53, 57, 60, 64}, {53, 59, 64, 69}, {52, 55, 59, 62}, {55, 61, 65, 64} };
    static const int bassRoot[4] = { 38, 43, 36, 33 };      // D2 G2 C2 A1
    static const int bassFifth[4] = { 45, 50, 43, 40 };
    static const int bassApproach[4] = { 41, 47, 40, 37 };

    for (int bar = 0; bar < bars; bar++) {
        double barStart = bar * 4.0 * beat;
        // Piano: a long chord on one, a short stab on the "and" of two.
        for (int v = 0; v < 4; v++) {
            RLAddKeys(&track, barStart + 0.01 * v, RLMidiHz(voicing[bar][v]), 0.20, 1.1);
            RLAddKeys(&track, barStart + 1.5 * beat + 0.012 * v, RLMidiHz(voicing[bar][v]), 0.11, 0.45);
        }
        // Walking bass.
        double bassNotes[4] = { RLMidiHz(bassRoot[bar]), RLMidiHz(bassFifth[bar]), RLMidiHz(bassRoot[bar] + 12), RLMidiHz(bassApproach[bar]) };
        for (int b = 0; b < 4; b++) {
            RLAddTone(&track, barStart + b * beat, bassNotes[b], 0.5, 0.32, 0.45);
        }
        // Brushes: a swish on two and four, light ticks between.
        for (int b = 0; b < 4; b++) {
            double when = barStart + b * beat;
            if (b == 1 || b == 3) RLAddNoiseBurst(&track, when, 0.20, 0.10, 6500.0, 0.8);
            RLAddNoiseBurst(&track, when + beat * 0.66, 0.05, 0.05, 8000.0, 1.2);
        }
    }
    RLNormalize(&track, 0.8f);
    return track;
}

// ==== DSP END ====

#pragma mark - Player

static AVAudioPCMBuffer *BRRouletteBufferFromTrack(RLTrack *track, AVAudioFormat *format) {
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)track->frames];
    buffer.frameLength = (AVAudioFrameCount)track->frames;
    memcpy(buffer.floatChannelData[0], track->data, (size_t)track->frames * sizeof(float));
    free(track->data);
    track->data = NULL;
    return buffer;
}

@interface BRRouletteAudio ()
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioFormat *format;
@property (nonatomic, strong) NSArray<AVAudioPlayerNode *> *voices;
@property (nonatomic, strong) AVAudioPlayerNode *ambienceNode;
@property (nonatomic, strong) AVAudioPlayerNode *spinNode;
@property (nonatomic, strong) NSDictionary<NSString *, AVAudioPCMBuffer *> *buffers;
@property (nonatomic) NSInteger voiceCursor;
@property (nonatomic) NSInteger chipVariantCursor;
@property (nonatomic) BOOL ready;
@property (nonatomic) BOOL preparing;
@property (nonatomic) BOOL ambienceWanted;
@property (nonatomic) BOOL ambiencePausedByBackground;
@end

@implementation BRRouletteAudio

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self shutdown];
}

- (void)prepare {
    if (self.ready || self.preparing) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(soundSettingChanged:) name:BRSlotSoundSettingChangedNotification object:nil];
    [center addObserver:self selector:@selector(appDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(appDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    self.muted = !BRSlotSoundEnabled();
    self.preparing = YES;
    self.format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:kSR channels:1 interleaved:NO];
    AVAudioFormat *format = self.format;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary<NSString *, AVAudioPCMBuffer *> *rendered = [NSMutableDictionary dictionary];
        for (int variant = 0; variant < 3; variant++) {
            RLTrack place = RLRenderChip(variant, 0);
            rendered[[NSString stringWithFormat:@"chipPlace%d", variant]] = BRRouletteBufferFromTrack(&place, format);
        }
        RLTrack remove = RLRenderChip(0, 1);
        rendered[@"chipRemove"] = BRRouletteBufferFromTrack(&remove, format);
        RLTrack open = RLRenderBettingOpen();
        rendered[@"bettingOpen"] = BRRouletteBufferFromTrack(&open, format);
        RLTrack closed = RLRenderBettingClosed();
        rendered[@"bettingClosed"] = BRRouletteBufferFromTrack(&closed, format);
        RLTrack spin = RLRenderSpin();
        rendered[@"spin"] = BRRouletteBufferFromTrack(&spin, format);
        RLTrack winSmall = RLRenderWin(4, 0.075, 6, 1.6);
        rendered[@"winSmall"] = BRRouletteBufferFromTrack(&winSmall, format);
        RLTrack winMedium = RLRenderWin(8, 0.060, 14, 2.4);
        rendered[@"winMedium"] = BRRouletteBufferFromTrack(&winMedium, format);
        RLTrack winBig = RLRenderWin(16, 0.048, 30, 3.6);
        rendered[@"winBig"] = BRRouletteBufferFromTrack(&winBig, format);
        RLTrack loss = RLRenderLoss();
        rendered[@"loss"] = BRRouletteBufferFromTrack(&loss, format);
        RLTrack ambience = RLRenderAmbience();
        rendered[@"ambience"] = BRRouletteBufferFromTrack(&ambience, format);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || !self.preparing) return;
            self.buffers = rendered;
            [self buildEngine];
            self.preparing = NO;
            if (!self.engine) return;
            self.ready = YES;
            if (self.ambienceWanted) [self startAmbience];
        });
    });
}

- (void)buildEngine {
    // Same session setup as the slot machines: Playback + MixWithOthers, so the
    // table layers over music the player already has playing.
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    AVAudioEngine *engine = [AVAudioEngine new];
    NSMutableArray<AVAudioPlayerNode *> *voices = [NSMutableArray array];
    for (int i = 0; i < kRLVoiceCount; i++) {
        AVAudioPlayerNode *node = [AVAudioPlayerNode new];
        [engine attachNode:node];
        [engine connect:node to:engine.mainMixerNode format:self.format];
        [voices addObject:node];
    }
    self.ambienceNode = [AVAudioPlayerNode new];
    self.spinNode = [AVAudioPlayerNode new];
    for (AVAudioPlayerNode *node in @[self.ambienceNode, self.spinNode]) {
        [engine attachNode:node];
        [engine connect:node to:engine.mainMixerNode format:self.format];
    }
    self.ambienceNode.volume = 0.16;
    self.spinNode.volume = 0.85;
    engine.mainMixerNode.outputVolume = self.muted ? 0 : 1;
    self.voices = voices;
    self.engine = engine;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(engineConfigurationChanged:) name:AVAudioEngineConfigurationChangeNotification object:engine];
    [engine prepare];
    NSError *error = nil;
    if (![engine startAndReturnError:&error]) {
        self.engine = nil;
        self.voices = nil;
    }
}

- (void)engineConfigurationChanged:(NSNotification *)note {
    if (!self.engine) return;
    NSError *error = nil;
    if (!self.engine.isRunning) [self.engine startAndReturnError:&error];
    if (self.engine.isRunning && self.ambienceWanted) [self startAmbience];
}

- (void)resume { [self engineConfigurationChanged:nil]; }

- (void)shutdown {
    self.preparing = NO;
    self.ready = NO;
    self.ambienceWanted = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.ambienceNode stop];
    [self.spinNode stop];
    for (AVAudioPlayerNode *node in self.voices) [node stop];
    [self.engine stop];
    self.engine = nil;
    self.voices = nil;
    self.ambienceNode = nil;
    self.spinNode = nil;
}

- (void)setMuted:(BOOL)muted {
    _muted = muted;
    self.engine.mainMixerNode.outputVolume = muted ? 0 : 1;
}

- (void)soundSettingChanged:(NSNotification *)note {
    BOOL enabled = BRSlotSoundEnabled();
    self.muted = !enabled;
    if (!enabled) { [self.ambienceNode stop]; [self stopSpin]; }
    else if (self.ambienceWanted) [self startAmbience];
}

// The app's audio background mode (kept for music) would otherwise keep the
// loops going on the lock screen: pause them while backgrounded.
- (void)appDidEnterBackground:(NSNotification *)note {
    self.ambiencePausedByBackground = self.ambienceWanted;
    [self.ambienceNode pause];
    [self.spinNode stop];
}

- (void)appDidBecomeActive:(NSNotification *)note {
    if (self.ambiencePausedByBackground && self.ambienceWanted && !self.muted) [self.ambienceNode play];
    self.ambiencePausedByBackground = NO;
}

- (void)playName:(NSString *)name volume:(float)volume {
    if (!BRSlotSoundEnabled()) return;
    AVAudioPCMBuffer *buffer = self.buffers[name];
    if (!self.ready || !buffer || !self.engine.isRunning || self.voices.count == 0) return;
    AVAudioPlayerNode *node = self.voices[(NSUInteger)(self.voiceCursor++ % (NSInteger)self.voices.count)];
    node.volume = volume;
    [node scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferInterrupts completionHandler:nil];
    [node play];
}

#pragma mark Ambience

- (void)startAmbience {
    self.ambienceWanted = YES;
    if (!BRSlotSoundEnabled()) return;
    AVAudioPCMBuffer *buffer = self.buffers[@"ambience"];
    if (!self.ready || !buffer || !self.engine.isRunning) return;
    [self.ambienceNode stop];
    [self.ambienceNode scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    [self.ambienceNode play];
}

- (void)stopAmbience {
    self.ambienceWanted = NO;
    [self.ambienceNode stop];
}

#pragma mark Effects

- (void)playChipPlace {
    // Rotate through three slightly different clicks so stacking chips doesn't sound mechanical.
    NSInteger variant = self.chipVariantCursor++ % 3;
    [self playName:[NSString stringWithFormat:@"chipPlace%ld", (long)variant] volume:0.8];
}
- (void)playChipRemove { [self playName:@"chipRemove" volume:0.7]; }
- (void)playBettingOpen { [self playName:@"bettingOpen" volume:0.7]; }
- (void)playBettingClosed { [self playName:@"bettingClosed" volume:0.8]; }

- (void)playSpinWithRemaining:(NSTimeInterval)seconds {
    if (!BRSlotSoundEnabled()) return;
    AVAudioPCMBuffer *master = self.buffers[@"spin"];
    if (!self.ready || !master || !self.engine.isRunning || !self.spinNode) return;
    // The sound is built to end exactly when the spin ends, so a late player
    // gets only the last part of it.
    NSTimeInterval available = (NSTimeInterval)master.frameLength / kSR;
    NSTimeInterval playSeconds = MAX(1.0, MIN(available, seconds));
    AVAudioFrameCount frames = (AVAudioFrameCount)(playSeconds * kSR);
    AVAudioFrameCount offset = master.frameLength - frames;
    AVAudioPCMBuffer *tail = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.format frameCapacity:frames];
    tail.frameLength = frames;
    float *destination = tail.floatChannelData[0];
    memcpy(destination, master.floatChannelData[0] + offset, (size_t)frames * sizeof(float));
    // A short fade-in avoids a click when starting part way through.
    AVAudioFrameCount fadeFrames = MIN(frames, (AVAudioFrameCount)(0.03 * kSR));
    for (AVAudioFrameCount i = 0; i < fadeFrames; i++) destination[i] *= (float)i / (float)fadeFrames;
    [self.spinNode stop];
    self.spinNode.volume = 0.85;
    [self.spinNode scheduleBuffer:tail atTime:nil options:0 completionHandler:nil];
    [self.spinNode play];
}

- (void)stopSpin { [self.spinNode stop]; }

- (void)playWinForPayoutRatio:(double)ratio {
    if (ratio <= 1.0) return;
    [self playName:(ratio >= 20.0 ? @"winBig" : ratio >= 3.0 ? @"winMedium" : @"winSmall") volume:0.85];
}

- (void)playLoss { [self playName:@"loss" volume:0.7]; }

@end
