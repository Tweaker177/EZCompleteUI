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
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>

static const double kBRSynthSampleRate  = 44100.0;
static const double kBRSynthBaseFreqHz  = 220.0; // A3
static const double kBRSynthNoteSeconds = 0.35;
static const NSUInteger kBRDrumStepsPerBar = 16;
static const NSUInteger kBRDrumLoopSteps = 32; // two 4/4 bars at 16th-note resolution

static double BRSynthSampleForWaveform(BRSynthWaveform waveform, double phase) {
    double cycle = phase / (M_PI * 2.0);
    cycle -= floor(cycle);
    switch (waveform) {
        case BRSynthWaveformSine:     return sin(phase);
        case BRSynthWaveformSawtooth: return cycle * 2.0 - 1.0;
        case BRSynthWaveformSquare:   return sin(phase) >= 0 ? 1.0 : -1.0;
        case BRSynthWaveformTriangle:
        default:                      return (2.0 / M_PI) * asin(sin(phase));
    }
}

@interface BRSynthEngine ()
@property (nonatomic, strong, nullable) AVAudioEngine *engine;
@property (nonatomic, strong, nullable) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong, nullable) AVAudioFormat *pcmFormat;
@property (nonatomic, strong, nullable) AVAudioUnitReverb *reverbNode;
@property (nonatomic, strong, nullable) AVAudioUnitEffect *compressorNode;
@property (nonatomic, strong, nullable) AVAudioUnitDelay *chorusNode;
@property (nonatomic, strong, nullable) AVAudioMixerNode *synthMixerNode;
@property (nonatomic, strong, nullable) AVAudioMixerNode *drumsMixerNode;
@property (nonatomic, strong, nullable) AVAudioMixerNode *masterMixerNode;
@property (nonatomic, strong) NSMutableArray *hitQueue; // queued velocity numbers or explicit collision notes
@property (nonatomic, assign) CFTimeInterval lastScheduleTime;
@property (nonatomic, assign) CFTimeInterval lastMIDIClockTime;
@property (nonatomic, assign, readwrite) BOOL isStarted;
@property (nonatomic, assign) MIDIClientRef midiClient;
@property (nonatomic, assign) MIDIEndpointRef midiSource;
@property (nonatomic, assign) BOOL midiTransportRunning;
@property (nonatomic, strong) NSDictionary<NSString *, NSArray<AVAudioPlayerNode *> *> *drumVoices;
@property (nonatomic, strong) NSDictionary<NSString *, AVAudioPCMBuffer *> *drumBuffers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *drumVoiceCursors;
@property (nonatomic, assign) CFTimeInterval lastDrumStepTime;
@property (nonatomic, assign) NSUInteger drumStep;
@property (nonatomic, assign) NSInteger activeDrumPatternIndex;
@property (nonatomic, assign) NSInteger pendingDrumPatternIndex;
@property (nonatomic, assign) CFTimeInterval lastArpeggioTime;
@property (nonatomic, assign) NSUInteger arpeggioStep;
@property (nonatomic, assign) float reactiveReverbBoost;
@property (nonatomic, assign) float reactiveCompressionBoost;
@property (nonatomic, assign) float reactiveChorusMix;
@property (nonatomic, assign) CFTimeInterval lastEffectsTickTime;
@property (nonatomic, assign) BOOL audioRecoveryPending;
@property (nonatomic, assign) BOOL audioInterrupted;
@end

@implementation BRSynthEngine

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
        _compressionMix = 0.28f;
        _synthVolume = 0.82f;
        _drumsVolume = 0.78f;
        _arpeggioDivision = BRSynthArpeggioDivisionEighth;
        _waveform = BRSynthWaveformTriangle;
        _oscillator2Enabled = YES;
        _oscillator2Waveform = BRSynthWaveformSawtooth;
        _oscillator2DetuneCents = 7.0f;
        _oscillator2Mix = 0.28f;
        _saturationDrive = 0.12f;
        _modulationRateHz = 4.0f;
        _modulationDepth = 0.0f;
        _modulationTarget = BRSynthModulationTargetAmplitude;
        _drumLoopEnabled = YES;
        _drumPatternIndex = 0;
        _activeDrumPatternIndex = 0;
        _pendingDrumPatternIndex = 0;
        _midiClockEnabled = NO;
        _hitQueue     = [NSMutableArray array];
        _drumVoiceCursors = [NSMutableDictionary dictionary];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(audioEngineConfigurationChanged:)
                    name:AVAudioEngineConfigurationChangeNotification object:nil];
        [center addObserver:self selector:@selector(audioSessionInterrupted:)
                    name:AVAudioSessionInterruptionNotification object:nil];
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
    // Ricochet is a continuous music experience. Prevent Core Audio from
    // opportunistically tearing down hardware I/O during a quiet moment.
    self.engine.autoShutdownEnabled = NO;
    self.playerNode = [[AVAudioPlayerNode alloc] init];
    self.synthMixerNode = [[AVAudioMixerNode alloc] init];
    self.drumsMixerNode = [[AVAudioMixerNode alloc] init];
    self.masterMixerNode = [[AVAudioMixerNode alloc] init];
    AudioComponentDescription dynamicsDescription = {
        .componentType = kAudioUnitType_Effect,
        .componentSubType = kAudioUnitSubType_DynamicsProcessor,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0,
    };
    self.compressorNode = [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:dynamicsDescription];
    self.chorusNode = [[AVAudioUnitDelay alloc] init];
    self.reverbNode = [[AVAudioUnitReverb alloc] init];
    [self.reverbNode loadFactoryPreset:AVAudioUnitReverbPresetMediumHall];
    self.reverbNode.wetDryMix = MAX(0, MIN(100, self.reverbMix * 100.0f));
    self.pcmFormat  = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kBRSynthSampleRate
                                                                      channels:1];

    [self.engine attachNode:self.playerNode];
    [self.engine attachNode:self.synthMixerNode];
    [self.engine attachNode:self.drumsMixerNode];
    [self.engine attachNode:self.masterMixerNode];
    [self.engine attachNode:self.compressorNode];
    [self.engine attachNode:self.chorusNode];
    [self.engine attachNode:self.reverbNode];
    // Synth and sample drums have their own volume mixers, then share
    // compression/reverb so Music Lab affects the whole musical mix.
    [self.engine connect:self.playerNode to:self.chorusNode format:self.pcmFormat];
    [self.engine connect:self.chorusNode to:self.synthMixerNode format:self.pcmFormat];
    // A mixer is the point where multiple sources meet. Feeding the two
    // sources directly into the compressor would replace its single input
    // connection, so combine them first and process the full music mix.
    [self.engine connect:self.synthMixerNode to:self.masterMixerNode format:nil];
    [self.engine connect:self.drumsMixerNode to:self.masterMixerNode format:nil];
    [self.engine connect:self.masterMixerNode to:self.compressorNode format:nil];
    [self.engine connect:self.compressorNode to:self.reverbNode format:nil];
    [self.engine connect:self.reverbNode to:self.engine.mainMixerNode format:nil];
    [self applyMixControls];
    [self loadDrumVoicesIfNeeded];

    NSError *startError = nil;
    [self.engine startAndReturnError:&startError];
    if (startError) {
        NSLog(@"[BRSynthEngine] engine start failed: %@", startError.localizedDescription);
        self.engine = nil;
        self.playerNode = nil;
        self.synthMixerNode = nil;
        self.drumsMixerNode = nil;
        self.masterMixerNode = nil;
        self.compressorNode = nil;
        self.chorusNode = nil;
        self.reverbNode = nil;
        return;
    }

    [self.playerNode play];
    for (NSArray<AVAudioPlayerNode *> *voices in self.drumVoices.allValues) {
        for (AVAudioPlayerNode *voice in voices) [voice play];
    }
    self.isStarted = YES;
    self.drumStep = 0;
    // The first kick starts immediately with MIDI Start/the synth transport.
    self.lastDrumStepTime = CACurrentMediaTime() - (60.0 / MAX(self.tempoBPM, 1) / 4.0);
    self.lastEffectsTickTime = CACurrentMediaTime();
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
    for (NSArray<AVAudioPlayerNode *> *voices in self.drumVoices.allValues) {
        for (AVAudioPlayerNode *voice in voices) if (!voice.isPlaying) [voice play];
    }
    return YES;
}

- (void)stop {
    [self stopMIDITransport];
    [self.playerNode stop];
    for (NSArray<AVAudioPlayerNode *> *voices in self.drumVoices.allValues) {
        for (AVAudioPlayerNode *voice in voices) [voice stop];
    }
    [self.engine stop];
    self.engine     = nil;
    self.playerNode = nil;
    self.reverbNode = nil;
    self.synthMixerNode = nil;
    self.drumsMixerNode = nil;
    self.masterMixerNode = nil;
    self.compressorNode = nil;
    self.chorusNode = nil;
    self.isStarted  = NO;
    [self.hitQueue removeAllObjects];
    self.drumVoices = nil;
    self.drumBuffers = nil;
    [self.drumVoiceCursors removeAllObjects];
    self.drumStep = 0;
    self.lastDrumStepTime = 0;
    self.lastEffectsTickTime = 0;
}

#pragma mark - Audio interruption and graph recovery

- (void)audioEngineConfigurationChanged:(NSNotification *)notification {
    // AVAudioEngine can retain isRunning == YES after its render graph has
    // been invalidated. Treat its configuration notification as authoritative
    // instead of waiting for a later level transition to recreate the graph.
    if (notification.object && notification.object != self.engine) return;
    [self requestAudioGraphRecovery];
}

- (void)audioSessionInterrupted:(NSNotification *)notification {
    NSNumber *typeValue = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    AVAudioSessionInterruptionType type = (AVAudioSessionInterruptionType)typeValue.unsignedIntegerValue;
    if (type == AVAudioSessionInterruptionTypeBegan) {
        self.audioInterrupted = YES;
        return;
    }
    self.audioInterrupted = NO;
    // iOS may mark an interruption as non-resumable even though reactivating
    // Playback succeeds; always make one best-effort recovery attempt.
    [self requestAudioGraphRecovery];
}

- (void)requestAudioGraphRecovery {
    if (!self.isStarted || self.audioInterrupted || self.audioRecoveryPending) return;
    self.audioRecoveryPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.audioRecoveryPending = NO;
        if (!self.isStarted || self.audioInterrupted) return;
        [self rebuildAudioGraph];
    });
}

- (void)rebuildAudioGraph {
    // Do not call -stop: it intentionally clears queued collisions and sends
    // MIDI Stop for a real end-of-game. A temporary audio disruption should
    // preserve musical intent and resume transport instead.
    [self.playerNode stop];
    for (NSArray<AVAudioPlayerNode *> *voices in self.drumVoices.allValues) {
        for (AVAudioPlayerNode *voice in voices) [voice stop];
    }
    [self.engine stop];
    self.engine = nil;
    self.playerNode = nil;
    self.pcmFormat = nil;
    self.reverbNode = nil;
    self.compressorNode = nil;
    self.chorusNode = nil;
    self.synthMixerNode = nil;
    self.drumsMixerNode = nil;
    self.masterMixerNode = nil;
    self.drumVoices = nil;
    self.drumBuffers = nil;
    [self.drumVoiceCursors removeAllObjects];
    self.isStarted = NO;
    self.midiTransportRunning = NO;
    self.lastScheduleTime = 0;
    self.lastArpeggioTime = 0;
    self.lastDrumStepTime = 0;
    [self start];
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
    [self applyMixControls];
}

- (void)setCompressionMix:(float)compressionMix { _compressionMix = MAX(0.0f, MIN(1.0f, compressionMix)); [self applyMixControls]; }
- (void)setSynthVolume:(float)synthVolume { _synthVolume = MAX(0.0f, MIN(1.0f, synthVolume)); [self applyMixControls]; }
- (void)setDrumsVolume:(float)drumsVolume { _drumsVolume = MAX(0.0f, MIN(1.0f, drumsVolume)); [self applyMixControls]; }

- (void)applyMixControls {
    self.synthMixerNode.outputVolume = self.synthVolume;
    self.drumsMixerNode.outputVolume = self.drumsVolume;
    self.reverbNode.wetDryMix = MAX(0, MIN(100, (self.reverbMix + self.reactiveReverbBoost) * 100.0f));
    self.chorusNode.delayTime = 0.024;
    self.chorusNode.feedback = 9.0f;
    self.chorusNode.wetDryMix = MAX(0, MIN(48, self.reactiveChorusMix * 48.0f));
    float compression = MAX(0, MIN(1, self.compressionMix + self.reactiveCompressionBoost));
    AudioUnit unit = self.compressorNode.audioUnit;
    if (!unit) return;
    AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0,
                          -5.0f - compression * 27.0f, 0);
    AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0,
                          18.0f - compression * 16.0f, 0);
    AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0,
                          0.002f + (1.0f - compression) * 0.015f, 0);
    AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0,
                          0.06f + (1.0f - compression) * 0.22f, 0);
    AudioUnitSetParameter(unit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0,
                          compression * 2.0f, 0);
}

- (void)setDrumLoopEnabled:(BOOL)drumLoopEnabled {
    if (_drumLoopEnabled == drumLoopEnabled) return;
    _drumLoopEnabled = drumLoopEnabled;
    if (!drumLoopEnabled) {
        for (NSArray<AVAudioPlayerNode *> *voices in self.drumVoices.allValues) {
            for (AVAudioPlayerNode *voice in voices) [voice stop];
        }
    } else if (self.isStarted) {
        for (NSArray<AVAudioPlayerNode *> *voices in self.drumVoices.allValues) {
            for (AVAudioPlayerNode *voice in voices) if (!voice.isPlaying) [voice play];
        }
    }
}

- (void)triggerReactiveEffect:(NSInteger)effect {
    // Musical blocks temporarily enrich the same effects controlled in Music
    // Lab. A new block refreshes its effect instead of stacking indefinitely.
    if (effect == 0) self.reactiveReverbBoost = 0.38f;
    else if (effect == 1) self.reactiveCompressionBoost = 0.46f;
    else self.reactiveChorusMix = 0.72f;
    [self applyMixControls];
}

- (void)setDrumPatternIndex:(NSInteger)drumPatternIndex {
    // Eight authored loops: 0–3 are four-to-the-floor, 4–7 are breakbeats.
    NSInteger normalized = ((drumPatternIndex % 8) + 8) % 8;
    _drumPatternIndex = normalized;
    if (!self.isStarted) {
        self.activeDrumPatternIndex = normalized;
        self.pendingDrumPatternIndex = normalized;
    } else {
        self.pendingDrumPatternIndex = normalized;
    }
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

- (void)sendMIDIDrumNote:(NSInteger)note velocity:(float)velocity {
    if (!self.midiClockEnabled || !self.midiTransportRunning) return;
    // MIDI channel 10 (zero-based 9) is the General MIDI percussion channel.
    Byte noteOn[] = { 0x99, (Byte)MAX(0, MIN(127, note)),
        (Byte)MAX(1, MIN(127, (NSInteger)lrintf(velocity * 127.0f))) };
    Byte noteNumber = noteOn[1];
    [self sendMIDIBytes:noteOn length:3];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.055 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.midiClockEnabled || !strongSelf.midiTransportRunning) return;
        Byte noteOff[] = { 0x89, noteNumber, 0 };
        [strongSelf sendMIDIBytes:noteOff length:3];
    });
}

#pragma mark - 808 Drum Loop

- (void)loadDrumVoicesIfNeeded {
    if (self.drumVoices.count > 0 || !self.engine) return;
    // Pool several voices per sample so hats/claps can ring naturally across
    // a subsequent step without cutting each other off.
    NSDictionary<NSString *, NSString *> *files = @{
        @"kick": @"808 Kick", @"snare": @"808 Snare 2", @"clap": @"808 Clap",
        @"closedHat": @"808 CL Hat", @"openHat": @"808 OP Hat",
        @"rim": @"808 Rim", @"conga": @"808 Conga", @"cymbal": @"808 Cymbal",
    };
    NSMutableDictionary *loaded = [NSMutableDictionary dictionary];
    NSMutableDictionary *buffers = [NSMutableDictionary dictionary];
    for (NSString *name in files) {
        NSURL *url = [[NSBundle mainBundle] URLForResource:files[name]
                                               withExtension:@"aif"
                                                subdirectory:@"sounds/808drums"];
        if (!url) { NSLog(@"[BRSynthEngine] missing 808 sample: %@", files[name]); continue; }
        NSError *readError = nil;
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&readError];
        AVAudioPCMBuffer *buffer = file ? [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                                           frameCapacity:(AVAudioFrameCount)file.length] : nil;
        if (!buffer || ![file readIntoBuffer:buffer error:&readError]) { NSLog(@"[BRSynthEngine] could not read %@: %@", files[name], readError); continue; }
        NSMutableArray<AVAudioPlayerNode *> *voices = [NSMutableArray array];
        for (NSUInteger i = 0; i < 3; i++) {
            AVAudioPlayerNode *voice = [[AVAudioPlayerNode alloc] init];
            [self.engine attachNode:voice];
            [self.engine connect:voice to:self.drumsMixerNode format:buffer.format];
            [voices addObject:voice];
        }
        if (voices.count) { loaded[name] = voices; buffers[name] = buffer; }
    }
    self.drumVoices = [loaded copy];
    self.drumBuffers = [buffers copy];
}

- (void)playDrum:(NSString *)name gain:(float)gain midiNote:(NSInteger)midiNote {
    NSArray<AVAudioPlayerNode *> *voices = self.drumVoices[name];
    AVAudioPCMBuffer *buffer = self.drumBuffers[name];
    NSUInteger cursor = self.drumVoiceCursors[name].unsignedIntegerValue;
    AVAudioPlayerNode *voice = voices.count ? voices[cursor % voices.count] : nil;
    if (voice && buffer) {
        self.drumVoiceCursors[name] = @(cursor + 1);
        // Player nodes can naturally stop once their last scheduled buffer
        // drains. Restarting at the actual beat avoids a silent drum loop
        // after a route/interruption without waiting for a level change.
        if (!voice.isPlaying) [voice play];
        voice.volume = MAX(0.0f, MIN(1.0f, gain));
        [voice scheduleBuffer:buffer atTime:nil options:0 completionHandler:nil];
    }
    [self sendMIDIDrumNote:midiNote velocity:gain];
}

- (BOOL)isKickStep:(NSUInteger)step bar:(NSUInteger)bar pattern:(NSInteger)pattern {
    switch (pattern) {
        // Four-on-the-floor patterns — kick is always on 1, 2, 3 and 4.
        case 0: return (step % 4) == 0;
        case 1: return (step % 4) == 0 || (bar == 1 && step == 15); // pickup into bar one
        case 2: return (step % 4) == 0 || step == 6 || (bar == 1 && step == 11);
        case 3: return (step % 4) == 0 || step == 3 || step == 14;
        // Breakbeats — strong 1/3 kicks plus syncopated ghost/pickup kicks.
        case 4: return step == 0 || step == 8 || (bar == 1 && step == 14);
        case 5: return step == 0 || step == 3 || step == 8 || step == 11 || step == 14;
        case 6: return step == 0 || step == 6 || step == 8 || step == 15;
        default: return step == 0 || step == 2 || step == 7 || step == 8 || step == 10 || step == 14;
    }
}

- (float)closedHatGainAtStep:(NSUInteger)step pattern:(NSInteger)pattern {
    // Different hat densities make each level feel like its own loop without
    // changing the shared BPM grid or the snare-on-2-and-4 backbone.
    if (pattern == 1 || pattern == 3) return (step % 2 == 0) ? 0.37f : 0.20f;
    if (pattern == 2) return (step == 0 || step == 2 || step == 4 || step == 6 || step == 8 || step == 10 || step == 12) ? 0.38f : 0.0f;
    if (pattern == 5 || pattern == 7) return (step % 2 == 0 || step == 3 || step == 7 || step == 11 || step == 15) ? 0.36f : 0.0f;
    return (step % 2 == 0) ? 0.34f : 0.0f;
}

- (void)playDrumStep:(NSUInteger)step {
    NSUInteger barStep = step % kBRDrumStepsPerBar;
    NSUInteger bar = step / kBRDrumStepsPerBar;
    NSInteger pattern = self.activeDrumPatternIndex;
    // Every loop keeps snares on beats 2 and 4; the kick/hats/percussion
    // change from level to level. Audio and MIDI are triggered together.
    if ([self isKickStep:barStep bar:bar pattern:pattern]) {
        [self playDrum:@"kick" gain:0.92f midiNote:36];
    }
    if (barStep == 4 || barStep == 12) [self playDrum:@"snare" gain:0.76f midiNote:38];
    if (barStep == 12 || (pattern >= 4 && barStep == 4)) [self playDrum:@"clap" gain:0.50f midiNote:39];
    float hatGain = [self closedHatGainAtStep:barStep pattern:pattern];
    if (hatGain > 0 && barStep != 14) [self playDrum:@"closedHat" gain:hatGain midiNote:42];
    if (barStep == 14 || (pattern == 3 && barStep == 6)) [self playDrum:@"openHat" gain:0.38f midiNote:46];
    if ((pattern == 2 && (barStep == 3 || barStep == 11)) ||
        (pattern >= 4 && (barStep == 3 || (bar == 1 && barStep == 10)))) [self playDrum:@"rim" gain:0.28f midiNote:37];
    if ((pattern == 3 && bar == 1 && (barStep == 5 || barStep == 13)) ||
        (pattern == 7 && (barStep == 5 || barStep == 13))) [self playDrum:@"conga" gain:0.30f midiNote:64];
    if (step == 0 || (pattern == 3 && step == 16)) [self playDrum:@"cymbal" gain:0.22f midiNote:49];
}

- (void)tickDrumLoopAtTime:(CFTimeInterval)now {
    if (!self.drumLoopEnabled) return;
    [self loadDrumVoicesIfNeeded];
    CFTimeInterval interval = 60.0 / MAX(self.tempoBPM, 1) / 4.0;
    NSUInteger emitted = 0;
    while (now - self.lastDrumStepTime >= interval && emitted < 4) {
        // Apply a level's new pattern only at the two-bar boundary.
        if (self.drumStep == 0) self.activeDrumPatternIndex = self.pendingDrumPatternIndex;
        [self playDrumStep:self.drumStep];
        self.drumStep = (self.drumStep + 1) % kBRDrumLoopSteps;
        self.lastDrumStepTime += interval;
        emitted++;
    }
    // Keep a paused/debugger-delayed game from emitting a burst of old beats.
    if (now - self.lastDrumStepTime >= interval) self.lastDrumStepTime = now;
}

#pragma mark - Arpeggiator

- (CFTimeInterval)arpeggioInterval {
    CFTimeInterval quarter = 60.0 / MAX(self.tempoBPM, 1);
    switch (self.arpeggioDivision) {
        case BRSynthArpeggioDivisionQuarter: return quarter;
        case BRSynthArpeggioDivisionSixteenth: return quarter / 4.0;
        case BRSynthArpeggioDivisionEighth:
        default: return quarter / 2.0;
    }
}

- (void)playSynthSemitone:(NSInteger)semitone velocity:(float)velocity noteSeconds:(double)noteSeconds {
    NSInteger midiNote = 57 + semitone; // A3 is MIDI note 57
    double freqHz = kBRSynthBaseFreqHz * pow(2.0, semitone / 12.0);
    double oscillator2FreqHz = freqHz * pow(2.0, self.oscillator2DetuneCents / 1200.0);
    AVAudioFrameCount frameCount = (AVAudioFrameCount)(kBRSynthSampleRate * noteSeconds);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.pcmFormat frameCapacity:frameCount];
    if (!buffer) return;
    buffer.frameLength = frameCount;
    float *samples = buffer.floatChannelData[0];
    float peakAmplitude = MIN(0.35f, 0.12f + velocity * 0.10f);
    double attack = MAX(0.005, MIN(0.25, self.attackSeconds));
    double release = MAX(0.04, MIN(noteSeconds, self.releaseSeconds));
    double cutoffHz = 350.0 + MAX(0.0, MIN(1.0, self.filterBrightness)) * 8200.0;
    double rc = 1.0 / (2.0 * M_PI * cutoffHz);
    double alpha = (1.0 / kBRSynthSampleRate) / (rc + (1.0 / kBRSynthSampleRate));
    double filtered = 0;
    float oscillator2Mix = self.isOscillator2Enabled ? MAX(0.0f, MIN(1.0f, self.oscillator2Mix)) : 0.0f;
    float saturation = MAX(0.0f, MIN(1.0f, self.saturationDrive));
    float modulationDepth = MAX(0.0f, MIN(1.0f, self.modulationDepth));
    float modulationRate = MAX(0.0f, MIN(20.0f, self.modulationRateHz));
    for (AVAudioFrameCount i = 0; i < frameCount; i++) {
        double t = (double)i / kBRSynthSampleRate;
        double lfo = sin(2.0 * M_PI * modulationRate * t);
        double pitchOffset = self.modulationTarget == BRSynthModulationTargetPitch ? lfo * modulationDepth * 0.16 : 0;
        double phase = 2.0 * M_PI * freqHz * t + pitchOffset;
        double primary = BRSynthSampleForWaveform(self.waveform, phase);
        double combined = primary;
        if (oscillator2Mix > 0) {
            double phase2 = 2.0 * M_PI * oscillator2FreqHz * t + pitchOffset;
            double secondary = BRSynthSampleForWaveform(self.oscillator2Waveform, phase2);
            combined = (primary + secondary * oscillator2Mix) / (1.0 + oscillator2Mix);
        }
        double attackEnvelope = MIN(1.0, t / attack);
        double releaseEnvelope = MIN(1.0, MAX(0.0, (noteSeconds - t) / release));
        filtered += alpha * (combined - filtered);
        if (saturation > 0) filtered = tanh(filtered * (1.0 + saturation * 5.0));
        double tremolo = self.modulationTarget == BRSynthModulationTargetAmplitude
            ? (1.0 - modulationDepth * 0.5 + lfo * modulationDepth * 0.5) : 1.0;
        samples[i] = (float)(filtered * tremolo * attackEnvelope * releaseEnvelope * peakAmplitude);
    }
    // As with the sample voices, a drained AVAudioPlayerNode can report
    // stopped even while the engine itself remains healthy. Resume it at the
    // point of scheduling so the arpeggiator cannot disappear mid-level.
    if (!self.playerNode.isPlaying) [self.playerNode play];
    [self.playerNode scheduleBuffer:buffer completionHandler:nil];
    [self sendMIDINote:midiNote velocity:velocity];
}
    // BRSynthEngine.m — add anywhere alongside playSynthSemitone:
    - (void)playKeySemitone:(NSInteger)semitone velocity:(float)velocity {
        if (!self.isStarted) [self start];
        if (![self ensureAudioEngineRunning]) return;
        double noteSeconds = MAX(0.18, MIN(0.60, self.attackSeconds + self.releaseSeconds + 0.06));
        [self playSynthSemitone:semitone velocity:velocity noteSeconds:noteSeconds];
    }
- (void)tickArpeggiatorAtTime:(CFTimeInterval)now {
    CFTimeInterval interval = [self arpeggioInterval];
    if (self.lastArpeggioTime == 0) self.lastArpeggioTime = now - interval;
    if (now - self.lastArpeggioTime < interval) return;
    self.lastArpeggioTime += interval;
    if (now - self.lastArpeggioTime >= interval) self.lastArpeggioTime = now;

    // Ascending/descending scale motion makes the collision synth feel like
    // a musical part even during a quiet ricochet stretch.
    static const NSInteger degrees[] = { 0, 2, 4, 6, 4, 2, 1, 3 };
    static const NSInteger octaves[] = { 0, 0, 0, 12, 12, 0, 0, 12 };
    NSArray<NSNumber *> *scale = [self currentScaleDegrees];
    NSUInteger index = self.arpeggioStep % 8;
    NSInteger degree = scale[(NSUInteger)degrees[index] % scale.count].integerValue;
    NSInteger semitone = self.rootSemitone + degree + octaves[index] + self.octaveOffset * 12;
    [self playSynthSemitone:semitone velocity:0.52f noteSeconds:MIN(0.32, interval * 0.84)];
    self.arpeggioStep++;
}

- (void)decayReactiveEffectsWithDeltaTime:(CFTimeInterval)dt {
    float decay = (float)MAX(0, 1.0 - dt / 5.0);
    self.reactiveReverbBoost *= decay;
    self.reactiveCompressionBoost *= decay;
    self.reactiveChorusMix *= decay;
    [self applyMixControls];
}

#pragma mark - Queue

- (void)queueHitWithVelocity:(float)velocity {
    if (self.hitQueue.count >= 8) {
        [self.hitQueue removeObjectAtIndex:0];
    }
    [self.hitQueue addObject:@(velocity)];
}

- (void)queueCollisionAtPoint:(CGPoint)point
                     boardSize:(CGSize)boardSize
                   impactAngle:(CGFloat)impactAngle
                      velocity:(float)velocity {
    if (self.hitQueue.count >= 8) [self.hitQueue removeObjectAtIndex:0];

    // Scale degrees 1, 3, 5, 7 and 9 are deliberately the only candidates.
    // Repeated impacts therefore stack into chord tones rather than a stream
    // of arbitrary chromatic-sounding notes. Horizontal/vertical impact
    // position and the rebound direction choose among those tones.
    CGFloat x = boardSize.width > 0 ? point.x / boardSize.width : 0.5f;
    CGFloat y = boardSize.height > 0 ? point.y / boardSize.height : 0.5f;
    x = MAX(0.0f, MIN(1.0f, x));
    y = MAX(0.0f, MIN(1.0f, y));
    CGFloat angleUnit = fmod(impactAngle + (CGFloat)(M_PI * 2.0), (CGFloat)(M_PI * 2.0)) / (CGFloat)(M_PI * 2.0);
    static const NSUInteger chordDegrees[] = { 0, 2, 4, 6, 8 }; // 1st, 3rd, 5th, 7th, 9th
    NSUInteger choice = (NSUInteger)floor((x * 3.0f + y * 2.0f + angleUnit * 5.0f) * 5.0f) % 5;
    NSUInteger requestedDegree = chordDegrees[choice];
    NSArray<NSNumber *> *scale = [self currentScaleDegrees];
    NSInteger degree = scale[requestedDegree % scale.count].integerValue;
    NSInteger extensionOctave = (NSInteger)(requestedDegree / scale.count);
    // Top-board rebounds and upward trajectories rise; lower/downward hits
    // answer lower, while retaining the player's chosen global octave.
    NSInteger impactOctave = (NSInteger)lrintf((0.5f - y) * 1.3f + sin(impactAngle) * 0.70f);
    impactOctave = MAX(-1, MIN(1, impactOctave));
    NSInteger semitone = self.rootSemitone + degree +
        (extensionOctave + impactOctave + self.octaveOffset) * 12;
    double noteSeconds = MAX(0.25, MIN(0.78, self.attackSeconds + self.releaseSeconds + 0.12));
    [self.hitQueue addObject:@{ @"semitone": @(semitone),
                                @"velocity": @(velocity),
                                @"duration": @(noteSeconds) }];
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
    CFTimeInterval previousTime = self.lastEffectsTickTime > 0 ? self.lastEffectsTickTime : now;
    self.lastEffectsTickTime = now;
    [self decayReactiveEffectsWithDeltaTime:MIN(0.10, MAX(0, now - previousTime))];
    [self tickMIDIClockAtTime:now];
    [self tickDrumLoopAtTime:now];
    [self tickArpeggiatorAtTime:now];
    if (self.hitQueue.count == 0) return;
    // Eighth-note grid at the current tempo — e.g. 120 BPM → 0.25s between notes.
    CFTimeInterval gridInterval = (60.0 / MAX(self.tempoBPM, 1)) / 2.0;
    if (now - self.lastScheduleTime < gridInterval) return;

    self.lastScheduleTime = now;
    id queuedHit = self.hitQueue.firstObject;
    [self.hitQueue removeObjectAtIndex:0];
    if ([queuedHit isKindOfClass:[NSDictionary class]]) {
        NSDictionary *note = queuedHit;
        [self playSynthSemitone:[note[@"semitone"] integerValue]
                        velocity:[note[@"velocity"] floatValue]
                     noteSeconds:[note[@"duration"] doubleValue]];
    } else {
        [self playRandomNoteWithVelocity:[queuedHit floatValue]];
    }
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
    double noteSeconds = MAX(kBRSynthNoteSeconds, MIN(0.90, self.attackSeconds + self.releaseSeconds + 0.10));
    [self playSynthSemitone:semitone velocity:velocity noteSeconds:noteSeconds];
}

@end
