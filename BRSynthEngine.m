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
#import <CoreMIDI/CoreMIDI.h>
#import <math.h>

static const double kBRSynthSampleRate  = 44100.0;
static const double kBRSynthBaseFreqHz  = 220.0; // A3
static const double kBRSynthNoteSeconds = 0.35;

@interface BRSynthEngine ()
@property (nonatomic, strong, nullable) AVAudioEngine *engine;
@property (nonatomic, strong, nullable) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong, nullable) AVAudioFormat *pcmFormat;
@property (nonatomic, strong, nullable) AVAudioUnitReverb *reverbNode;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *hitQueue; // queued velocities, oldest first
@property (nonatomic, assign) CFTimeInterval lastScheduleTime;
@property (nonatomic, assign) CFTimeInterval lastMIDIClockTime;
@property (nonatomic, assign, readwrite) BOOL isStarted;
@property (nonatomic, assign) MIDIClientRef midiClient;
@property (nonatomic, assign) MIDIEndpointRef midiSource;
@property (nonatomic, assign) BOOL midiTransportRunning;
@end

@implementation BRSynthEngine

- (void)dealloc {
    [self stop];
    if (self.midiSource != 0) MIDIEndpointDispose(self.midiSource);
    if (self.midiClient != 0) MIDIClientDispose(self.midiClient);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _rootSemitone = 7; // G — matches the default the prototype shipped with
        _scale        = BRSynthScalePentatonic;
        _tempoBPM     = 120;
        _octaveOffset = 0;
        _attackSeconds = 0.015f;
        _releaseSeconds = 0.32f;
        _filterBrightness = 0.72f;
        _reverbMix = 0.18f;
        _midiClockEnabled = NO;
        _hitQueue     = [NSMutableArray array];
    }
    return self;
}

#pragma mark - Lifecycle

- (void)start {
    if (self.isStarted) return;

    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    // Playback (rather than Ambient) keeps the sequencer alive when the app is
    // backgrounded. MixWithOthers leaves a user's music or podcast playing.
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers
                   error:&sessionError];
    if (!sessionError) [session setActive:YES error:&sessionError];
    if (sessionError) {
        NSLog(@"[BRSynthEngine] audio session activation failed: %@", sessionError.localizedDescription);
    }

    self.engine     = [[AVAudioEngine alloc] init];
    self.playerNode = [[AVAudioPlayerNode alloc] init];
    self.reverbNode = [[AVAudioUnitReverb alloc] init];
    [self.reverbNode loadFactoryPreset:AVAudioUnitReverbPresetMediumHall];
    self.reverbNode.wetDryMix = MAX(0, MIN(100, self.reverbMix * 100.0f));
    self.pcmFormat  = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kBRSynthSampleRate
                                                                      channels:1];

    [self.engine attachNode:self.playerNode];
    [self.engine attachNode:self.reverbNode];
    [self.engine connect:self.playerNode to:self.reverbNode format:self.pcmFormat];
    [self.engine connect:self.reverbNode to:self.engine.mainMixerNode format:self.pcmFormat];

    NSError *startError = nil;
    [self.engine startAndReturnError:&startError];
    if (startError) {
        NSLog(@"[BRSynthEngine] engine start failed: %@", startError.localizedDescription);
        self.engine = nil;
        self.playerNode = nil;
        self.reverbNode = nil;
        return;
    }

    [self.playerNode play];
    self.isStarted = YES;
    [self startMIDITransportIfNeeded];
}

- (BOOL)ensureAudioEngineRunning {
    if (!self.isStarted || !self.engine || !self.playerNode) return NO;
    if (!self.engine.isRunning) {
        NSError *error = nil;
        if (![self.engine startAndReturnError:&error]) {
            NSLog(@"[BRSynthEngine] audio engine restart failed: %@", error.localizedDescription);
            self.isStarted = NO;
            return NO;
        }
    }
    if (!self.playerNode.isPlaying) [self.playerNode play];
    return YES;
}

- (void)stop {
    [self stopMIDITransport];
    [self.playerNode stop];
    [self.engine stop];
    self.engine     = nil;
    self.playerNode = nil;
    self.reverbNode = nil;
    self.isStarted  = NO;
    [self.hitQueue removeAllObjects];
}

#pragma mark - CoreMIDI output

- (void)setMidiClockEnabled:(BOOL)midiClockEnabled {
    if (_midiClockEnabled == midiClockEnabled) return;
    _midiClockEnabled = midiClockEnabled;
    if (midiClockEnabled && self.isStarted) [self startMIDITransportIfNeeded];
    if (!midiClockEnabled) [self stopMIDITransport];
}

- (void)setReverbMix:(float)reverbMix {
    _reverbMix = MAX(0.0f, MIN(1.0f, reverbMix));
    self.reverbNode.wetDryMix = _reverbMix * 100.0f;
}

- (BOOL)ensureMIDISource {
    if (self.midiSource != 0) return YES;
    OSStatus status = MIDIClientCreate(CFSTR("EZCompleteUI Ricochet"), NULL, NULL, &_midiClient);
    if (status != noErr) {
        NSLog(@"[BRSynthEngine] MIDI client creation failed: %d", (int)status);
        self.midiClient = 0;
        return NO;
    }
    status = MIDISourceCreate(self.midiClient, CFSTR("EZCompleteUI Ricochet"), &_midiSource);
    if (status != noErr) {
        NSLog(@"[BRSynthEngine] MIDI source creation failed: %d", (int)status);
        MIDIClientDispose(self.midiClient);
        self.midiClient = 0;
        self.midiSource = 0;
        return NO;
    }
    return YES;
}

- (void)sendMIDIBytes:(const Byte *)bytes length:(NSUInteger)length {
    if (self.midiSource == 0 || length == 0 || length > 256) return;
    Byte storage[sizeof(MIDIPacketList) + 256];
    MIDIPacketList *packetList = (MIDIPacketList *)storage;
    MIDIPacket *packet = MIDIPacketListInit(packetList);
    packet = MIDIPacketListAdd(packetList, sizeof(storage), packet, 0, (UInt16)length, bytes);
    if (!packet) return;
    // A virtual source publishes packets with MIDIReceived; MIDISend is for
    // an output port addressing a concrete destination endpoint.
    OSStatus status = MIDIReceived(self.midiSource, packetList);
    if (status != noErr) NSLog(@"[BRSynthEngine] MIDI send failed: %d", (int)status);
}

- (void)startMIDITransportIfNeeded {
    if (!self.midiClockEnabled || self.midiTransportRunning || ![self ensureMIDISource]) return;
    const Byte start = 0xFA; // MIDI Start
    [self sendMIDIBytes:&start length:1];
    self.lastMIDIClockTime = CACurrentMediaTime();
    self.midiTransportRunning = YES;
}

- (void)stopMIDITransport {
    if (self.midiTransportRunning && self.midiSource != 0) {
        const Byte stop = 0xFC; // MIDI Stop
        [self sendMIDIBytes:&stop length:1];
    }
    self.midiTransportRunning = NO;
    self.lastMIDIClockTime = 0;
}

- (void)tickMIDIClockAtTime:(CFTimeInterval)now {
    if (!self.midiClockEnabled || !self.midiTransportRunning) return;
    CFTimeInterval interval = 60.0 / MAX(self.tempoBPM, 1) / 24.0;
    NSUInteger emitted = 0;
    while (now - self.lastMIDIClockTime >= interval && emitted < 8) {
        const Byte clock = 0xF8; // MIDI Timing Clock (24 pulses per quarter)
        [self sendMIDIBytes:&clock length:1];
        self.lastMIDIClockTime += interval;
        emitted++;
    }
    // Avoid an audible/MIDI burst after a lengthy debugger pause.
    if (now - self.lastMIDIClockTime >= interval) self.lastMIDIClockTime = now;
}

- (void)sendMIDINote:(NSInteger)note velocity:(float)velocity {
    if (!self.midiClockEnabled || !self.midiTransportRunning) return;
    Byte noteOn[] = { 0x90, (Byte)MAX(0, MIN(127, note)), (Byte)MAX(1, MIN(127, (NSInteger)lrintf(velocity * 48.0f))) };
    Byte noteNumber = noteOn[1];
    [self sendMIDIBytes:noteOn length:3];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBRSynthNoteSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.midiClockEnabled || !strongSelf.midiTransportRunning) return;
        Byte noteOff[] = { 0x80, noteNumber, 0 };
        [strongSelf sendMIDIBytes:noteOff length:3];
    });
}

#pragma mark - Queue

- (void)queueHitWithVelocity:(float)velocity {
    if (self.hitQueue.count >= 8) {
        [self.hitQueue removeObjectAtIndex:0];
    }
    [self.hitQueue addObject:@(velocity)];
}

- (void)tick {
    if (!self.isStarted) return;
    if (![self ensureAudioEngineRunning]) {
        // iOS can stop an AVAudioEngine after an interruption. Recreate the
        // graph on the next hit rather than silently leaving the game mute.
        [self start];
        if (!self.isStarted) return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    [self tickMIDIClockAtTime:now];
    if (self.hitQueue.count == 0) return;
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
    NSInteger semitone  = self.rootSemitone + degree + octaveUp + self.octaveOffset * 12;
    NSInteger midiNote  = 57 + semitone; // A3 is MIDI note 57
    double freqHz = kBRSynthBaseFreqHz * pow(2.0, semitone / 12.0);

    double noteSeconds = MAX(kBRSynthNoteSeconds, MIN(0.90, self.attackSeconds + self.releaseSeconds + 0.10));
    AVAudioFrameCount frameCount = (AVAudioFrameCount)(kBRSynthSampleRate * noteSeconds);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.pcmFormat
                                                              frameCapacity:frameCount];
    if (!buffer) return;
    buffer.frameLength = frameCount;
    float *samples = buffer.floatChannelData[0];

    float peakAmplitude = MIN(0.35f, 0.12f + velocity * 0.10f);
    double attack = MAX(0.005, MIN(0.25, self.attackSeconds));
    double release = MAX(0.04, MIN(noteSeconds, self.releaseSeconds));
    // One-pole low-pass filter: lower brightness audibly softens the triangle
    // harmonics while high brightness leaves its crisp collision character.
    double cutoffHz = 350.0 + MAX(0.0, MIN(1.0, self.filterBrightness)) * 8200.0;
    double rc = 1.0 / (2.0 * M_PI * cutoffHz);
    double alpha = (1.0 / kBRSynthSampleRate) / (rc + (1.0 / kBRSynthSampleRate));
    double filtered = 0;
    for (AVAudioFrameCount i = 0; i < frameCount; i++) {
        double t = (double)i / kBRSynthSampleRate;
        double phase = 2.0 * M_PI * freqHz * t;
        double triangle = (2.0 / M_PI) * asin(sin(phase));      // triangle wave, no aliasing tables needed
        double attackEnvelope = MIN(1.0, t / attack);
        double releaseEnvelope = MIN(1.0, MAX(0.0, (noteSeconds - t) / release));
        filtered += alpha * (triangle - filtered);
        samples[i] = (float)(filtered * attackEnvelope * releaseEnvelope * peakAmplitude);
    }

    [self.playerNode scheduleBuffer:buffer completionHandler:nil];
    [self sendMIDINote:midiNote velocity:velocity];
}

@end
