#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WaveformView : UIView

// Appearance
@property (nonatomic, strong) UIColor *waveColor;        // main waveform color
@property (nonatomic, strong) UIColor *secondaryWaveColor; // slightly faded for tail / smoothing
@property (nonatomic, strong) UIColor *progressColor;    // playhead / played region color
@property (nonatomic) CGFloat lineWidth;                 // stroke width for waveform
@property (nonatomic) BOOL symmetric;                    // draw symmetric (top+bottom) or single-line
@property (nonatomic, assign) CGFloat progress;      // 0.0 – 1.0 playback position

// Realtime update (recording): pass the latest float samples [-1..1] from mic buffers.
// samples are not copied (read-only); method copies internally so you can free/retain as usual.
- (void)updateWithFloatSamples:(const float *)samples count:(NSUInteger)count;

// Static render: render full waveform from sample array (float [-1..1]). Ideally called after downsampling
- (void)renderSamples:(const float *)samples count:(NSUInteger)count;

// Convenience: read audio file and render compressed waveform asynchronously.
// Supported formats: any AVAsset-supported audio (it will be converted to 32-bit float PCM internally).
- (void)loadAudioFileAtURL:(NSURL *)fileURL completion:(void(^_Nullable)(BOOL success, NSError * _Nullable error))completion;

// Playback progress [0..1]
- (void)setProgress:(CGFloat)progress animated:(BOOL)animated;

// Clear waveform
- (void)clear;

@end

NS_ASSUME_NONNULL_END
