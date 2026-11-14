// BRGoldenMandarinAudio.m
// EZCompleteUI — Golden Mandarin (金帽福运) slot

#import "BRGoldenMandarinAudio.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static const double kSR = 44100.0;
static const int kVoiceCount = 8;

#pragma mark - Synthesis primitives (plain C, run on a background queue)

typedef struct { uint64_t s; } BRNoise;
static inline float NoiseNext(BRNoise *n) {
    n->s ^= n->s << 13; n->s ^= n->s >> 7; n->s ^= n->s << 17;
    return (float)((n->s >> 40) & 0xFFFFFF) / 8388607.5f - 1.0f;
}
static inline double MidiHz(double midi) { return 440.0 * pow(2.0, (midi - 69.0) / 12.0); }

typedef struct { float *data; NSInteger frames; BRNoise noise; } BRTrack;

static BRTrack TrackMake(double seconds) {
    BRTrack t; t.frames = (NSInteger)(seconds * kSR);
    t.data = (float *)calloc((size_t)t.frames, sizeof(float));
    t.noise.s = 0x2545F4914F6CDD1DULL;
    return t;
}

/// Plucked string by additive synthesis: exact pitch, brighter attack, upper
/// partials dying faster. `tau` is the fundamental's decay time in seconds.
static void AddPluck(BRTrack *t, double start, double freq, double amp, double tau, int harmonics, double dur) {
    NSInteger s0 = (NSInteger)(start * kSR);
    NSInteger n = (NSInteger)(dur * kSR);
    if (s0 < 0 || s0 >= t->frames) return;
    if (s0 + n > t->frames) n = t->frames - s0;
    for (int h = 1; h <= harmonics; h++) {
        double f = freq * h * (1.0 + 0.0003 * h * h);
        if (f > 12000) break;
        double a = amp / pow(h, 1.15);
        double rate = (1.0 / tau) * (1.0 + 0.9 * (h - 1));
        double w = 2.0 * M_PI * f / kSR;
        double ph = 0.3 * h;
        double decay = exp(-rate / kSR), level = 1.0;
        for (NSInteger i = 0; i < n; i++) {
            double env = level * (i < 90 ? (double)i / 90.0 : 1.0);
            t->data[s0 + i] += (float)(sin(ph + w * i) * a * env);
            level *= decay;
        }
    }
    for (NSInteger i = 0; i < 160 && s0 + i < t->frames; i++)                  // finger click
        t->data[s0 + i] += NoiseNext(&t->noise) * (float)(amp * 0.18 * exp(-(double)i / 40.0));
}

/// Struck bell: inharmonic partials with a slow shimmer.
static void AddBell(BRTrack *t, double start, double freq, double amp, double decay) {
    static const double ratio[5] = { 1.0, 2.756, 5.404, 8.933, 13.34 };
    static const double gain[5]  = { 1.0, 0.55, 0.32, 0.20, 0.10 };
    NSInteger s0 = (NSInteger)(start * kSR);
    NSInteger n = (NSInteger)(decay * 1.6 * kSR);
    if (s0 < 0 || s0 >= t->frames) return;
    if (s0 + n > t->frames) n = t->frames - s0;
    for (int p = 0; p < 5; p++) {
        double f = freq * ratio[p];
        if (f > 14000) break;
        double w = 2.0 * M_PI * f / kSR;
        double w2 = 2.0 * M_PI * (f + 0.7 + p * 0.4) / kSR;
        double d = decay / (1.0 + p * 0.85);
        double step = exp(-1.0 / (kSR * d)), level = 1.0;
        for (NSInteger i = 0; i < n; i++) {
            double env = level * (i < 40 ? (double)i / 40.0 : 1.0);
            t->data[s0 + i] += (float)((sin(w * i) * 0.65 + sin(w2 * i) * 0.35) * amp * gain[p] * env);
            level *= step;
        }
    }
    for (NSInteger i = 0; i < 300 && s0 + i < t->frames; i++) {               // sparkle on the strike
        double e = exp(-(double)i / 70.0);
        t->data[s0 + i] += NoiseNext(&t->noise) * (float)(amp * 0.22 * e);
    }
}

static void AddGong(BRTrack *t, double start, double freq, double amp, double decay) {
    static const double ratio[6] = { 1.0, 1.47, 2.09, 2.56, 3.34, 4.04 };
    static const double gain[6]  = { 1.0, 0.7, 0.55, 0.5, 0.35, 0.3 };
    NSInteger s0 = (NSInteger)(start * kSR);
    NSInteger n = (NSInteger)(decay * 1.4 * kSR);
    if (s0 < 0 || s0 >= t->frames) return;
    if (s0 + n > t->frames) n = t->frames - s0;
    for (int p = 0; p < 6; p++) {
        double w = 2.0 * M_PI * freq * ratio[p] / kSR;
        double d = decay / (1.0 + p * 0.35);
        double step = exp(-1.0 / (kSR * d)), level = 1.0;
        for (NSInteger i = 0; i < n; i++) {
            double time = (double)i / kSR;
            double env = level * (i < 600 ? (double)i / 600.0 : 1.0);
            double wobble = 1.0 + 0.0018 * sin(2.0 * M_PI * 2.3 * time + p);
            t->data[s0 + i] += (float)(sin(w * i * wobble) * amp * gain[p] * env * 0.5);
            level *= step;
        }
    }
    double lp = 0;                                                             // crash wash
    for (NSInteger i = 0; i < n / 2 && s0 + i < t->frames; i++) {
        float x = NoiseNext(&t->noise);
        lp += 0.35 * (x - lp);
        t->data[s0 + i] += (float)((x - lp) * amp * 0.28 * exp(-(double)i / (kSR * decay * 0.28)));
    }
}

static void AddTom(BRTrack *t, double start, double freq, double amp, double dur) {
    NSInteger s0 = (NSInteger)(start * kSR);
    NSInteger n = (NSInteger)(dur * kSR);
    if (s0 < 0 || s0 >= t->frames) return;
    if (s0 + n > t->frames) n = t->frames - s0;
    double phase = 0;
    for (NSInteger i = 0; i < n; i++) {
        double time = (double)i / kSR;
        double f = freq * (1.0 + 0.9 * exp(-time / 0.035));
        phase += 2.0 * M_PI * f / kSR;
        double env = exp(-time / (dur * 0.33)) * (i < 30 ? (double)i / 30.0 : 1.0);
        t->data[s0 + i] += (float)(sin(phase) * amp * env);
    }
    for (NSInteger i = 0; i < 140 && s0 + i < t->frames; i++)
        t->data[s0 + i] += NoiseNext(&t->noise) * (float)(amp * 0.3 * exp(-(double)i / 30.0));
}

static void AddWood(BRTrack *t, double start, double freq, double amp) {
    NSInteger s0 = (NSInteger)(start * kSR);
    NSInteger n = (NSInteger)(0.09 * kSR);
    if (s0 < 0 || s0 >= t->frames) return;
    if (s0 + n > t->frames) n = t->frames - s0;
    double w1 = 2.0 * M_PI * freq / kSR, w2 = 2.0 * M_PI * freq * 1.52 / kSR;
    for (NSInteger i = 0; i < n; i++) {
        double env = exp(-(double)i / (kSR * 0.018)) * (i < 20 ? (double)i / 20.0 : 1.0);
        t->data[s0 + i] += (float)((sin(w1 * i) * 0.8 + sin(w2 * i) * 0.3) * amp * env);
        if (i < 110) t->data[s0 + i] += NoiseNext(&t->noise) * (float)(amp * 0.25 * exp(-(double)i / 25.0));
    }
}

/// High-passed noise burst — snare/hat/whoosh building block.
static void AddNoise(BRTrack *t, double start, double dur, double amp, double tau, double hpAlpha) {
    NSInteger s0 = (NSInteger)(start * kSR);
    NSInteger n = (NSInteger)(dur * kSR);
    if (s0 < 0 || s0 >= t->frames) return;
    if (s0 + n > t->frames) n = t->frames - s0;
    double lp = 0;
    for (NSInteger i = 0; i < n; i++) {
        float x = NoiseNext(&t->noise);
        lp += hpAlpha * (x - lp);
        double env = exp(-(double)i / (kSR * tau)) * (i < 20 ? (double)i / 20.0 : 1.0);
        t->data[s0 + i] += (float)((x - lp) * amp * env);
    }
}

/// Rising filtered-noise whoosh for the spin start.
static void AddWhoosh(BRTrack *t, double start, double dur, double amp) {
    NSInteger s0 = (NSInteger)(start * kSR);
    NSInteger n = (NSInteger)(dur * kSR);
    if (s0 < 0 || s0 >= t->frames) return;
    if (s0 + n > t->frames) n = t->frames - s0;
    double lp = 0;
    for (NSInteger i = 0; i < n; i++) {
        double p = (double)i / n;
        double a = 0.02 + 0.5 * p * p;                                         // cutoff opens
        lp += a * (NoiseNext(&t->noise) - lp);
        double env = sin(M_PI * MIN(1.0, p * 1.15)) * (1.0 - 0.3 * p);
        t->data[s0 + i] += (float)(lp * amp * env * 3.0);
    }
}

/// Bamboo-flute-like breathy tone with vibrato that blooms after the attack.
static void AddFlute(BRTrack *t, double start, double freq, double amp, double dur) {
    NSInteger s0 = (NSInteger)(start * kSR);
    NSInteger n = (NSInteger)(dur * kSR);
    if (s0 < 0 || s0 >= t->frames) return;
    if (s0 + n > t->frames) n = t->frames - s0;
    double phase = 0, breath = 0;
    for (NSInteger i = 0; i < n; i++) {
        double time = (double)i / kSR;
        double vib = 1.0 + 0.0045 * sin(2.0 * M_PI * 5.2 * time) * MIN(1.0, time / 0.25);
        phase += 2.0 * M_PI * freq * vib / kSR;
        double att = MIN(1.0, time / 0.06), rel = MIN(1.0, (dur - time) / 0.14);
        double env = att * MAX(0.0, rel);
        breath += 0.12 * (NoiseNext(&t->noise) - breath);
        double tone = sin(phase) + 0.32 * sin(2 * phase) + 0.09 * sin(3 * phase);
        t->data[s0 + i] += (float)((tone * 0.6 + breath * 0.5) * amp * env);
    }
}

/// Two-tone electronic alarm, gated like a bank alarm.
static void AddSiren(BRTrack *t, double start, double dur, double amp) {
    NSInteger s0 = (NSInteger)(start * kSR);
    NSInteger n = (NSInteger)(dur * kSR);
    if (s0 < 0 || s0 >= t->frames) return;
    if (s0 + n > t->frames) n = t->frames - s0;
    double phase = 0;
    for (NSInteger i = 0; i < n; i++) {
        double time = (double)i / kSR;
        int hi = ((int)(time / 0.16)) % 2 == 0;
        double f = hi ? 1046.5 : 784.0;
        phase += 2.0 * M_PI * f / kSR;
        double tone = sin(phase) + 0.33 * sin(3 * phase) + 0.2 * sin(5 * phase);
        double gate = fmod(time, 0.16) / 0.16;
        double env = MIN(1.0, gate * 14.0) * MIN(1.0, (1.0 - gate) * 10.0 + 0.35);
        double fade = MIN(1.0, time / 0.05) * MIN(1.0, (dur - time) / 0.4);
        t->data[s0 + i] += (float)(tone * amp * env * fade * 0.55);
    }
}

/// Feedback comb for a little room around the music.
static void AddEcho(BRTrack *t, double delaySec, float feedback) {
    NSInteger d = (NSInteger)(delaySec * kSR);
    for (NSInteger i = d; i < t->frames; i++) t->data[i] += feedback * t->data[i - d];
}

static void FoldTail(BRTrack *t, NSInteger loopFrames) {
    for (NSInteger i = 0; i + loopFrames < t->frames && i < loopFrames; i++) t->data[i] += t->data[loopFrames + i];
}

static void Normalize(BRTrack *t, float peak) {
    float m = 0;
    for (NSInteger i = 0; i < t->frames; i++) m = MAX(m, fabsf(t->data[i]));
    if (m < 1e-6f) return;
    float g = peak / m;
    for (NSInteger i = 0; i < t->frames; i++) t->data[i] *= g;
}

static AVAudioPCMBuffer *BufferFromTrack(BRTrack *t, AVAudioFormat *fmt, NSInteger frames) {
    if (frames > t->frames) frames = t->frames;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:(AVAudioFrameCount)frames];
    buffer.frameLength = (AVAudioFrameCount)frames;
    memcpy(buffer.floatChannelData[0], t->data, (size_t)frames * sizeof(float));
    free(t->data); t->data = NULL;
    return buffer;
}

#pragma mark - Composition

typedef struct { double pos; int midi; double dur; } NoteEv;

// Quirky 8-bar hook in D major pentatonic (D E F# A B). Positions are in eighth notes.
static const NoteEv kMelody[] = {
    {0,69,1},{1,71,1},{2,74,2},{4,71,1},{5,69,1},{6,66,2},
    {8,69,1},{9,66,1},{10,64,2},{12,66,1},{13,69,1},{14,71,2},
    {16,74,1},{17,76,1},{18,78,2},{20,76,1},{21,74,1},{22,71,2},
    {24,69,1},{25,71,1},{26,69,1},{27,66,1},{28,64,4},
    {32,69,1},{33,71,1},{34,74,2},{36,78,1},{37,76,1},{38,74,2},
    {40,71,1},{41,74,1},{42,71,1},{43,69,1},{44,66,2},{46,64,1},{47,66,1},
    {48,69,2},{50,74,1},{51,71,1},{52,69,2},{54,66,1},{55,64,1},
    {56,62,2},{58,64,1},{59,66,1},{60,69,3}
};
static const NoteEv kGrace[] = { {1.7,71,0.3}, {17.7,76,0.3}, {33.7,71,0.3}, {49.7,71,0.3} };
static const NoteEv kFlute[] = { {28,76,4}, {44,74,2}, {60,78,3} };
static const int kBassRoot[8] = { 38, 38, 33, 35, 38, 40, 33, 33 };

static AVAudioPCMBuffer *RenderTheme(AVAudioFormat *fmt, BOOL bonus) {
    double bpm = bonus ? 138.0 : 112.0;
    int transpose = bonus ? 5 : 0;
    double eighth = 60.0 / bpm / 2.0;
    NSInteger loopFrames = (NSInteger)(64 * eighth * kSR);
    BRTrack t = TrackMake(64 * eighth + 2.5);

    for (size_t i = 0; i < sizeof(kMelody) / sizeof(kMelody[0]); i++) {
        NoteEv e = kMelody[i];
        double accent = ((int)e.pos % 4 == 0) ? 1.0 : 0.78;
        AddPluck(&t, e.pos * eighth, MidiHz(e.midi + transpose), 0.34 * accent, bonus ? 0.4 : 0.55, 9, 1.3);
    }
    for (size_t i = 0; i < sizeof(kGrace) / sizeof(kGrace[0]); i++)
        AddPluck(&t, kGrace[i].pos * eighth, MidiHz(kGrace[i].midi + transpose), 0.2, 0.2, 6, 0.25);
    for (size_t i = 0; i < sizeof(kFlute) / sizeof(kFlute[0]); i++)
        AddFlute(&t, kFlute[i].pos * eighth, MidiHz(kFlute[i].midi + 12 + transpose), 0.2, kFlute[i].dur * eighth);

    for (int bar = 0; bar < 8; bar++) {
        double b0 = bar * 8;
        double root = MidiHz(kBassRoot[bar] + transpose);
        AddPluck(&t, b0 * eighth, root, 0.55, 0.5, 4, 0.9);
        AddPluck(&t, (b0 + 4) * eighth, root, 0.42, 0.45, 4, 0.8);
        AddPluck(&t, (b0 + 7) * eighth, root * 1.5, 0.22, 0.25, 3, 0.4);
        AddTom(&t, b0 * eighth, 74, 0.8, 0.28);
        AddTom(&t, (b0 + 4) * eighth, 74, 0.6, 0.24);
        if (bonus) { AddTom(&t, (b0 + 2) * eighth, 96, 0.35, 0.16); AddTom(&t, (b0 + 6) * eighth, 96, 0.35, 0.16); }
        AddWood(&t, (b0 + 2) * eighth, 880, 0.3);
        AddWood(&t, (b0 + 5) * eighth, 660, 0.26);
        AddWood(&t, (b0 + 7) * eighth, 1040, 0.22);
        if (bonus) for (int k = 1; k < 8; k += 2) AddNoise(&t, (b0 + k) * eighth, 0.05, 0.09, 0.012, 0.25);
        if (bar % 4 == 0) AddBell(&t, b0 * eighth, MidiHz(86 + transpose), 0.07, 1.2);
    }
    AddEcho(&t, 0.19, 0.24f);
    FoldTail(&t, loopFrames);
    Normalize(&t, 0.85f);
    return BufferFromTrack(&t, fmt, loopFrames);
}

#pragma mark - Effects

static AVAudioPCMBuffer *RenderSpinStart(AVAudioFormat *fmt) {
    BRTrack t = TrackMake(0.6);
    AddWhoosh(&t, 0, 0.5, 0.55);
    AddTom(&t, 0, 88, 0.6, 0.22);
    AddWood(&t, 0.02, 1200, 0.3);
    Normalize(&t, 0.8f);
    return BufferFromTrack(&t, fmt, t.frames);
}

static AVAudioPCMBuffer *RenderReelStop(AVAudioFormat *fmt, int index) {
    BRTrack t = TrackMake(0.25);
    AddWood(&t, 0, 620 + index * 45, 0.8);
    AddTom(&t, 0, 95, 0.7, 0.14);
    Normalize(&t, 0.75f);
    return BufferFromTrack(&t, fmt, t.frames);
}

static AVAudioPCMBuffer *RenderScatterNote(AVAudioFormat *fmt, double freq) {
    BRTrack t = TrackMake(2.2);
    AddBell(&t, 0, freq, 0.7, 0.8);
    AddBell(&t, 0.0, freq * 2.0, 0.22, 0.5);                                   // octave shimmer
    AddPluck(&t, 0, freq * 0.5, 0.3, 0.3, 5, 0.6);                             // warm body
    AddNoise(&t, 0, 0.12, 0.2, 0.025, 0.12);
    AddEcho(&t, 0.14, 0.22f);
    Normalize(&t, 0.9f);
    return BufferFromTrack(&t, fmt, t.frames);
}

static AVAudioPCMBuffer *RenderDrumRoll(AVAudioFormat *fmt, int hitsPerSecond) {
    double loopSec = 0.5;
    BRTrack t = TrackMake(loopSec + 0.2);
    int hits = (int)round(hitsPerSecond * loopSec);
    for (int i = 0; i < hits; i++) {
        double when = (double)i / hits * loopSec;
        double accent = (i % 4 == 0) ? 1.0 : (i % 2 == 0 ? 0.8 : 0.65);
        AddNoise(&t, when, 0.06, 0.55 * accent, 0.02, 0.28);
        AddTom(&t, when, 150, 0.42 * accent, 0.09);
    }
    NSInteger loopFrames = (NSInteger)(loopSec * kSR);
    FoldTail(&t, loopFrames);
    Normalize(&t, 0.8f);
    return BufferFromTrack(&t, fmt, loopFrames);
}

static AVAudioPCMBuffer *RenderCrash(AVAudioFormat *fmt) {
    BRTrack t = TrackMake(3.4);
    AddGong(&t, 0, 196, 0.8, 2.2);
    AddNoise(&t, 0, 1.4, 0.4, 0.5, 0.08);
    AddTom(&t, 0, 60, 0.8, 0.4);
    AddEcho(&t, 0.21, 0.25f);
    Normalize(&t, 0.92f);
    return BufferFromTrack(&t, fmt, t.frames);
}

static AVAudioPCMBuffer *RenderFanfare(AVAudioFormat *fmt) {
    BRTrack t = TrackMake(3.6);
    static const int run[] = { 62, 64, 66, 69, 71, 74, 76, 78, 81, 83 };
    for (int i = 0; i < 10; i++) AddPluck(&t, i * 0.075, MidiHz(run[i]), 0.42, 0.5, 9, 1.0);
    double hit = 0.85;
    for (int n = 0; n < 3; n++) {
        static const int chord[3] = { 74, 78, 81 };
        AddPluck(&t, hit, MidiHz(chord[n]), 0.4, 0.8, 9, 1.8);
        AddBell(&t, hit, MidiHz(chord[n] + 12), 0.25, 1.0);
    }
    AddGong(&t, hit, 220, 0.7, 2.0);
    AddTom(&t, hit, 70, 0.9, 0.4);
    AddEcho(&t, 0.17, 0.26f);
    Normalize(&t, 0.9f);
    return BufferFromTrack(&t, fmt, t.frames);
}

static AVAudioPCMBuffer *RenderAlarm(AVAudioFormat *fmt) {
    BRTrack t = TrackMake(6.2);
    static const int bellMidi[6] = { 84, 86, 88, 91, 93, 96 };                 // C6 D6 E6 G6 A6 C7
    AddGong(&t, 0, 175, 0.9, 2.6);
    AddSiren(&t, 0.1, 4.4, 0.5);
    BRNoise pick = { 0x9E3779B97F4A7C15ULL };
    int idx = 0;
    for (double when = 0.15; when < 4.5; when += 0.085) {
        uint32_t r = (uint32_t)((NoiseNext(&pick) + 1.0f) * 3.0f);
        idx = (idx + 1 + (int)(r % 2)) % 6;
        AddBell(&t, when, MidiHz(bellMidi[idx]), 0.3, 0.45);
    }
    for (double when = 0.0; when < 4.4; when += 0.3) AddTom(&t, when, 70, 0.55, 0.22);
    AddGong(&t, 2.2, 196, 0.7, 2.0);
    AddGong(&t, 4.4, 147, 0.85, 2.4);
    AddEcho(&t, 0.23, 0.22f);
    Normalize(&t, 0.92f);
    return BufferFromTrack(&t, fmt, t.frames);
}

static AVAudioPCMBuffer *RenderNearMiss(AVAudioFormat *fmt) {
    BRTrack t = TrackMake(1.8);
    static const int notes[3] = { 81, 78, 74 };
    for (int i = 0; i < 3; i++) AddPluck(&t, i * 0.2, MidiHz(notes[i]), 0.38, 0.35, 7, 0.9);
    AddTom(&t, 0.55, 80, 0.4, 0.3);
    Normalize(&t, 0.7f);
    return BufferFromTrack(&t, fmt, t.frames);
}

/// Pentatonic arpeggio; `count` plucks climbing D major pentatonic from D5.
static AVAudioPCMBuffer *RenderWin(AVAudioFormat *fmt, int count, BOOL gong) {
    static const int degrees[14] = { 74, 76, 78, 81, 83, 86, 88, 90, 93, 95, 98, 100, 102, 105 };
    BRTrack t = TrackMake(count * 0.075 + 2.4);
    for (int i = 0; i < count && i < 14; i++) {
        AddPluck(&t, i * 0.075, MidiHz(degrees[i] - 12), 0.38, 0.45, 8, 0.9);
        if (i >= count - 3) AddBell(&t, i * 0.075, MidiHz(degrees[i]), 0.16, 0.5);
    }
    if (gong) AddGong(&t, count * 0.075, 233, 0.55, 1.6);
    AddEcho(&t, 0.15, 0.22f);
    Normalize(&t, 0.85f);
    return BufferFromTrack(&t, fmt, t.frames);
}

static AVAudioPCMBuffer *RenderCardFlip(AVAudioFormat *fmt) {
    BRTrack t = TrackMake(0.3);
    AddNoise(&t, 0, 0.12, 0.35, 0.04, 0.2);
    AddWood(&t, 0.05, 1500, 0.45);
    Normalize(&t, 0.7f);
    return BufferFromTrack(&t, fmt, t.frames);
}

static AVAudioPCMBuffer *RenderCardPick(AVAudioFormat *fmt) {
    BRTrack t = TrackMake(1.2);
    AddBell(&t, 0, MidiHz(88), 0.6, 0.5);
    AddWood(&t, 0, 900, 0.5);
    Normalize(&t, 0.8f);
    return BufferFromTrack(&t, fmt, t.frames);
}

static AVAudioPCMBuffer *RenderReveal(AVAudioFormat *fmt, int bells) {
    BRTrack t = TrackMake(bells * 0.14 + 2.6);
    static const int notes[5] = { 84, 88, 91, 93, 96 };
    for (int i = 0; i < bells; i++) AddBell(&t, i * 0.14, MidiHz(notes[i]), 0.55, 0.7);
    if (bells >= 5) {
        AddGong(&t, bells * 0.14, 196, 0.8, 2.0);
        for (int i = 0; i < 8; i++) AddPluck(&t, 0.7 + i * 0.06, MidiHz(74 + (int[]){0,2,4,7,9,12,14,16}[i]), 0.3, 0.5, 8, 0.8);
    }
    AddEcho(&t, 0.16, 0.25f);
    Normalize(&t, 0.9f);
    return BufferFromTrack(&t, fmt, t.frames);
}

#pragma mark - Player

@interface BRGoldenMandarinAudio ()
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioFormat *format;
@property (nonatomic, strong) NSArray<AVAudioPlayerNode *> *voices;
@property (nonatomic, strong) AVAudioPlayerNode *themeNode, *rollNode;
@property (nonatomic, strong) NSDictionary<NSString *, AVAudioPCMBuffer *> *buffers;
@property (nonatomic) NSInteger voiceCursor;
@property (nonatomic) BOOL ready, preparing, themeWanted, themeBonus, ducked;
@property (nonatomic) NSInteger rollLevel;
@end

@implementation BRGoldenMandarinAudio

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; [self shutdown]; }

- (void)prepare {
    if (self.ready || self.preparing) return;
    self.preparing = YES;
    self.format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:kSR channels:1 interleaved:NO];
    AVAudioFormat *fmt = self.format;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *b = [NSMutableDictionary dictionary];
        b[@"theme"] = RenderTheme(fmt, NO);
        b[@"bonusTheme"] = RenderTheme(fmt, YES);
        b[@"spin"] = RenderSpinStart(fmt);
        for (int i = 0; i < 5; i++) b[[NSString stringWithFormat:@"stop%d", i]] = RenderReelStop(fmt, i);
        static const int scatterMidi[5] = { 84, 86, 88, 91, 93 };              // C6 D6 E6 G6 A6
        for (int i = 0; i < 5; i++) b[[NSString stringWithFormat:@"scatter%d", i]] = RenderScatterNote(fmt, MidiHz(scatterMidi[i]));
        static const int rolls[3] = { 14, 20, 28 };
        for (int i = 0; i < 3; i++) b[[NSString stringWithFormat:@"roll%d", i + 1]] = RenderDrumRoll(fmt, rolls[i]);
        b[@"crash"] = RenderCrash(fmt);
        b[@"fanfare"] = RenderFanfare(fmt);
        b[@"alarm"] = RenderAlarm(fmt);
        b[@"nearMiss"] = RenderNearMiss(fmt);
        b[@"winSmall"] = RenderWin(fmt, 4, NO);
        b[@"winMedium"] = RenderWin(fmt, 8, YES);
        b[@"winBig"] = RenderWin(fmt, 14, YES);
        b[@"flip"] = RenderCardFlip(fmt);
        b[@"pick"] = RenderCardPick(fmt);
        b[@"reveal2"] = RenderReveal(fmt, 2);
        b[@"reveal3"] = RenderReveal(fmt, 3);
        b[@"reveal5"] = RenderReveal(fmt, 5);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || !self.preparing) return;
            self.buffers = b;
            [self buildEngine];
            self.preparing = NO;
            if (!self.engine) return;
            self.ready = YES;
            if (self.themeWanted) [self startThemeBonus:self.themeBonus];
            if (self.onReady) self.onReady();
        });
    });
}

- (void)buildEngine {
    AVAudioEngine *engine = [AVAudioEngine new];
    NSMutableArray *voices = [NSMutableArray array];
    for (int i = 0; i < kVoiceCount; i++) {
        AVAudioPlayerNode *node = [AVAudioPlayerNode new];
        [engine attachNode:node];
        [engine connect:node to:engine.mainMixerNode format:self.format];
        [voices addObject:node];
    }
    self.themeNode = [AVAudioPlayerNode new];
    self.rollNode = [AVAudioPlayerNode new];
    for (AVAudioPlayerNode *node in @[self.themeNode, self.rollNode]) {
        [engine attachNode:node];
        [engine connect:node to:engine.mainMixerNode format:self.format];
    }
    self.themeNode.volume = 0.3;
    self.rollNode.volume = 0.55;
    engine.mainMixerNode.outputVolume = self.muted ? 0 : 1;
    self.voices = voices;
    self.engine = engine;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(engineConfigurationChanged:) name:AVAudioEngineConfigurationChangeNotification object:engine];
    [engine prepare];
    NSError *error = nil;
    if (![engine startAndReturnError:&error]) { self.engine = nil; self.voices = nil; }
}

- (void)engineConfigurationChanged:(NSNotification *)note {
    if (!self.engine) return;
    NSError *error = nil;
    if (!self.engine.isRunning) [self.engine startAndReturnError:&error];
    if (self.engine.isRunning && self.themeWanted) [self startThemeBonus:self.themeBonus];
}

- (void)resume { [self engineConfigurationChanged:nil]; }

- (void)shutdown {
    self.preparing = NO; self.ready = NO; self.themeWanted = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.themeNode stop]; [self.rollNode stop];
    for (AVAudioPlayerNode *node in self.voices) [node stop];
    [self.engine stop];
    self.engine = nil; self.voices = nil; self.themeNode = nil; self.rollNode = nil;
}

- (void)setMuted:(BOOL)muted { _muted = muted; self.engine.mainMixerNode.outputVolume = muted ? 0 : 1; }

- (void)playName:(NSString *)name volume:(float)volume {
    AVAudioPCMBuffer *buffer = self.buffers[name];
    if (!self.ready || !buffer || !self.engine.isRunning || !self.voices.count) return;
    AVAudioPlayerNode *node = self.voices[(NSUInteger)(self.voiceCursor++ % (NSInteger)self.voices.count)];
    node.volume = volume;
    [node scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferInterrupts completionHandler:nil];
    [node play];
}

#pragma mark Music

- (void)startThemeBonus:(BOOL)bonus {
    self.themeWanted = YES; self.themeBonus = bonus;
    AVAudioPCMBuffer *buffer = self.buffers[bonus ? @"bonusTheme" : @"theme"];
    if (!self.ready || !buffer || !self.engine.isRunning) return;
    [self.themeNode stop];
    self.themeNode.volume = self.ducked ? 0.1 : 0.3;
    [self.themeNode scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    [self.themeNode play];
}

- (void)stopTheme { self.themeWanted = NO; [self.themeNode stop]; }

- (void)duckTheme:(BOOL)duck {
    self.ducked = duck;
    self.themeNode.volume = duck ? 0.1 : 0.3;
}

#pragma mark Effects

- (void)playSpinStart { [self playName:@"spin" volume:0.7]; }
- (void)playReelStop:(NSInteger)reelIndex { [self playName:[NSString stringWithFormat:@"stop%ld", (long)MAX(0, MIN(4, reelIndex))] volume:0.7]; }
- (void)playScatterNoteAtIndex:(NSInteger)index { [self playName:[NSString stringWithFormat:@"scatter%ld", (long)MAX(0, MIN(4, index))] volume:1.0]; }

- (void)startDrumRollLevel:(NSInteger)level {
    level = MAX(1, MIN(3, level));
    AVAudioPCMBuffer *buffer = self.buffers[[NSString stringWithFormat:@"roll%ld", (long)level]];
    if (!self.ready || !buffer || !self.engine.isRunning) return;
    self.rollLevel = level;
    [self duckTheme:YES];
    [self.rollNode stop];
    self.rollNode.volume = 0.42 + 0.2 * level;
    [self.rollNode scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    [self.rollNode play];
}

- (void)stopDrumRoll {
    self.rollLevel = 0;
    [self.rollNode stop];
    [self duckTheme:NO];
}

- (void)playCrash { [self playName:@"crash" volume:1.0]; }
- (void)playBonusFanfare { [self playName:@"fanfare" volume:1.0]; }
- (void)playAlarmCelebration { [self playName:@"alarm" volume:1.0]; }
- (void)playNearMissSigh { [self playName:@"nearMiss" volume:0.7]; }

- (void)playWinForPayoutRatio:(double)ratio {
    if (ratio <= 0) return;
    [self playName:(ratio >= 25 ? @"winBig" : ratio >= 6 ? @"winMedium" : @"winSmall") volume:0.85];
}

- (void)playCardFlip { [self playName:@"flip" volume:0.8]; }
- (void)playCardPick { [self playName:@"pick" volume:0.9]; }
- (void)playMultiplierReveal:(NSInteger)multiplier {
    [self playName:(multiplier >= 5 ? @"reveal5" : multiplier == 3 ? @"reveal3" : @"reveal2") volume:1.0];
}

@end
