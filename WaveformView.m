#import "WaveformView.h"
@import AVFoundation;

@interface WaveformView ()

// internal downsampled amplitudes [0..1] — one value per horizontal sample
@property (nonatomic, strong) NSMutableData *amplitudesData; // floats
@property (nonatomic) NSUInteger amplitudeCount;
@property (nonatomic) CGFloat cachedScale; // for faster redraw decisions

// Realtime circular buffer for display
@property (nonatomic, strong) NSMutableData *realtimeData; // floats
@property (nonatomic) NSUInteger realtimeCount;
@property (nonatomic) NSUInteger realtimeWriteIndex;

// Display link for smooth progress updates (optional)
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic) CGFloat targetProgress;

@end

@implementation WaveformView

#pragma mark - Defaults

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super initWithCoder:coder]) [self commonInit];
    return self;
}

- (void)commonInit {
    self.backgroundColor = [UIColor clearColor];
    self.waveColor = [UIColor colorWithRed:0.12 green:0.56 blue:0.95 alpha:1.0]; // blue
    self.secondaryWaveColor = [self.waveColor colorWithAlphaComponent:0.45];
    self.progressColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.2 alpha:1.0]; // orange/red
    self.lineWidth = 1.0;
    self.symmetric = YES;

    self.amplitudeCount = 0;
    self.cachedScale = 0;

    self.realtimeCount = 256;
    self.realtimeData = [NSMutableData dataWithLength:sizeof(float) * self.realtimeCount];
    self.realtimeWriteIndex = 0;
    self.realtimeCount = self.realtimeCount;
    self.targetProgress = 0;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // If width changed enough, rebuild amplitudes slot count
    CGFloat width = CGRectGetWidth(self.bounds);
    if (width <= 0) return;
    if (self.cachedScale != width) {
        self.cachedScale = width;
        // Keep existing amplitudes if any by resampling to new count
        [self resampleAmplitudesToWidth:(NSUInteger)width];
    }
}

#pragma mark - Public APIs

- (void)clear {
    @synchronized(self) {
        self.amplitudeCount = 0;
        self.amplitudesData = nil;
    }
    [self setNeedsDisplay];
}

- (void)updateWithFloatSamples:(const float *)samples count:(NSUInteger)count {
    if (!samples || count == 0) return;

    // compute RMS or peak of the incoming buffer to a single value
    float sumSq = 0.0f;
    float peak = 0.0f;
    for (NSUInteger i = 0; i < count; i++) {
        float v = samples[i];
        sumSq += v * v;
        float av = fabsf(v);
        if (av > peak) peak = av;
    }
    float rms = sqrtf(sumSq / (float)count);
    // prefer RMS but take max with peak so short transients still show
    float value = MAX(rms, peak);
    value = fminf(1.0f, fmaxf(0.0f, value));

    // push into realtime circular buffer
    @synchronized (self) {
        float *buf = (float *)self.realtimeData.mutableBytes;
        buf[self.realtimeWriteIndex] = value;
        self.realtimeWriteIndex = (self.realtimeWriteIndex + 1) % self.realtimeCount;
    }

    // reflect realtime buffer to amplitudes used for drawing (shift left)
    [self mergeRealtimeBufferIntoAmplitudes];

    // redraw on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay];
    });
}

- (void)renderSamples:(const float *)samples count:(NSUInteger)count {
    if (!samples || count == 0) {
        [self clear];
        return;
    }

    NSUInteger targetWidth = MAX(1, (NSUInteger)CGRectGetWidth(self.bounds));
    // downsample into targetWidth buckets using RMS per bucket
    NSMutableData *data = [NSMutableData dataWithLength:sizeof(float) * targetWidth];
    float *out = (float *)data.mutableBytes;

    NSUInteger bucketSize = count / targetWidth;
    if (bucketSize == 0) bucketSize = 1;
    for (NSUInteger i = 0; i < targetWidth; i++) {
        NSUInteger start = i * bucketSize;
        NSUInteger end = MIN(count, start + bucketSize);
        double sumSq = 0.0;
        float peak = 0.0f;
        for (NSUInteger j = start; j < end; j++) {
            float v = samples[j];
            sumSq += v * v;
            float av = fabsf(v);
            if (av > peak) peak = av;
        }
        float rms = sqrtf(sumSq / (double)(end - start));
        float val = MAX(rms, peak);
        out[i] = fminf(1.0f, fmaxf(0.0f, val));
    }

    @synchronized(self) {
        self.amplitudesData = data;
        self.amplitudeCount = targetWidth;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay];
    });
}

- (void)loadAudioFileAtURL:(NSURL *)fileURL completion:(void(^__nullable)(BOOL success, NSError * __nullable error))completion {
    if (!fileURL) {
        if (completion) completion(NO, [NSError errorWithDomain:@"WaveformView" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No file URL"}]);
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:fileURL options:nil];
        NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (tracks.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [NSError errorWithDomain:@"WaveformView" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"No audio tracks found"}]);
            });
            return;
        }

        NSError *err = nil;
        AVAssetTrack *track = [tracks firstObject];

        // Reader settings: convert to 32-bit float, interleaved
        NSDictionary *outputSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVLinearPCMIsFloatKey: @YES,
            AVLinearPCMBitDepthKey: @32,
            AVLinearPCMIsNonInterleaved: @NO,
            AVLinearPCMIsBigEndianKey: @NO
        };

        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
        if (!reader || err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, err);
            });
            return;
        }

        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:outputSettings];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [NSError errorWithDomain:@"WaveformView" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Can't add reader output"}]);
            });
            return;
        }
        [reader addOutput:output];
        [reader startReading];

        NSMutableData *allSamples = [NSMutableData data];

        while (reader.status == AVAssetReaderStatusReading) {
            CMSampleBufferRef buf = [output copyNextSampleBuffer];
            if (!buf) break;

            CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(buf);
            size_t length = 0;
            char *dataPtr = NULL;
            if (CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &length, &dataPtr) == kCMBlockBufferNoErr && length > 0) {
                // The incoming format is float32 interleaved. Append raw bytes.
                [allSamples appendBytes:dataPtr length:length];
            }
            CFRelease(buf);
        }

        if (reader.status == AVAssetReaderStatusCompleted && allSamples.length > 0) {
            // Interpret bytes as float32 interleaved samples (stereo or mono).
            NSUInteger bytesPerSample = sizeof(float);
            NSUInteger totalFloats = allSamples.length / bytesPerSample;
            float *floats = (float *)allSamples.mutableBytes;

            // If stereo, average channels -> mono
            // We need to know number of channels: derive from track.formatDescriptions
            UInt32 channelCount = 1;
            for (id formatDesc in track.formatDescriptions) {
                CMAudioFormatDescriptionRef audioDesc = (__bridge CMAudioFormatDescriptionRef)formatDesc;
                const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioDesc);
                if (asbd) { channelCount = asbd->mChannelsPerFrame; break; }
            }
            NSUInteger frameCount = totalFloats / (channelCount ?: 1);

            // Create a float array of mono samples (averaging channels)
            float *mono = (float *)malloc(sizeof(float) * frameCount);
            if (!mono) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, [NSError errorWithDomain:@"WaveformView" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"Memory allocation failed"}]);
                });
                return;
            }

            if (channelCount <= 1) {
                memcpy(mono, floats, sizeof(float) * frameCount);
            } else {
                for (NSUInteger i = 0; i < frameCount; i++) {
                    double acc = 0.0;
                    for (NSUInteger ch = 0; ch < channelCount; ch++) {
                        acc += floats[i * channelCount + ch];
                    }
                    mono[i] = (float)(acc / (double)channelCount);
                }
            }

            // Downsample & render
            [self renderSamples:mono count:frameCount];

            free(mono);

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(YES, nil);
            });
            return;
        }

        // error / no data
        NSError *reason = [NSError errorWithDomain:@"WaveformView" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Failed to read audio or no sample data"}];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO, reason);
        });
    });
}

- (void)setProgress:(CGFloat)progress animated:(BOOL)animated {
    progress = fmaxf(0.0f, fminf(1.0f, progress));
    if (animated) {
        // animate via CADisplayLink (smooth)
        self.targetProgress = progress;
        if (!self.displayLink) {
            self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleDisplayLink:)];
            [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        }
    } else {
        self.targetProgress = progress;
        [self.displayLink invalidate];
        self.displayLink = nil;
        [self setNeedsDisplay];
    }
}

- (void)handleDisplayLink:(CADisplayLink *)dl {
    // simple easing to target
    CGFloat current = _progressValue;
    CGFloat diff = self.targetProgress - current;
    if (fabs(diff) < 0.001) {
        _progressValue = self.targetProgress;
        [self.displayLink invalidate];
        self.displayLink = nil;
    } else {
        _progressValue = current + diff * 0.2;
    }
    [self setNeedsDisplay];
}

// internal backing for progress property
@synthesize progress = _progressValue;
- (CGFloat)progress { return _progressValue; }
- (void)setProgress:(CGFloat)progress { [self setProgress:progress animated:NO]; }

#pragma mark - Internal helper: downsample/resample

- (void)resampleAmplitudesToWidth:(NSUInteger)width {
    if (width == 0) return;
    @synchronized(self) {
        if (self.amplitudeCount == 0 || !self.amplitudesData) {
            // initialize blank
            self.amplitudeCount = width;
            self.amplitudesData = [NSMutableData dataWithLength:sizeof(float) * width];
            float *out = (float *)self.amplitudesData.mutableBytes;
            for (NSUInteger i = 0; i < width; i++) out[i] = 0.0f;
            return;
        }
        // resample existing amplitudes to new width by simple averaging
        float *old = (float *)self.amplitudesData.mutableBytes;
        NSUInteger oldCount = self.amplitudeCount;
        NSMutableData *newData = [NSMutableData dataWithLength:sizeof(float) * width];
        float *newOut = (float *)newData.mutableBytes;
        for (NSUInteger i = 0; i < width; i++) {
            NSUInteger start = (NSUInteger)((double)i * oldCount / (double)width);
            NSUInteger end = MIN(oldCount, (NSUInteger)((double)(i+1) * oldCount / (double)width));
            if (end <= start) { newOut[i] = old[MIN(start, oldCount-1)]; continue; }
            double sum = 0;
            for (NSUInteger j = start; j < end; j++) sum += old[j];
            newOut[i] = (float)(sum / (double)(end - start));
        }
        self.amplitudesData = newData;
        self.amplitudeCount = width;
    }
}

- (void)mergeRealtimeBufferIntoAmplitudes {
    // copy realtime buffer into rightmost part of amplitudes (simulate scrolling waveform)
    @synchronized(self) {
        if (self.amplitudeCount == 0 || !self.amplitudesData) {
            // initialize amplitude array if missing
            NSUInteger width = MAX(1, (NSUInteger)self.cachedScale);
            self.amplitudeCount = width;
            self.amplitudesData = [NSMutableData dataWithLength:sizeof(float) * width];
            float *out = (float *)self.amplitudesData.mutableBytes;
            for (NSUInteger i = 0; i < width; i++) out[i] = 0.0f;
        }
        float *amp = (float *)self.amplitudesData.mutableBytes;
        float *realtime = (float *)self.realtimeData.mutableBytes;

        // shift left by realtimeCount and append realtime block, but to be efficient we rotate with memmove
        NSUInteger w = self.amplitudeCount;
        NSUInteger block = MIN(self.realtimeCount, w);
        if (block == 0) return;
        memmove(amp, amp + block, sizeof(float) * (w - block));
        // append realtime in chronological order (consider circular index)
        NSUInteger startIndex = (self.realtimeWriteIndex) % self.realtimeCount;
        for (NSUInteger i = 0; i < block; i++) {
            float v = realtime[(startIndex + i) % self.realtimeCount];
            // slightly dampen quick spikes for smoother look
            amp[w - block + i] = v;
        }
    }
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGSize size = rect.size;
    CGFloat midY = size.height / 2.0;
    CGFloat width = size.width;

    // background
    CGContextClearRect(ctx, rect);

    // get amplitudes
    NSUInteger count = 0;
    float *amps = NULL;
    @synchronized(self) {
        count = self.amplitudeCount;
        if (count > 0 && self.amplitudesData) amps = (float *)self.amplitudesData.bytes;
    }

    if (count == 0 || !amps) {
        // draw baseline
        CGContextSetStrokeColorWithColor(ctx, [self.waveColor colorWithAlphaComponent:0.2].CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextMoveToPoint(ctx, 0, midY);
        CGContextAddLineToPoint(ctx, width, midY);
        CGContextStrokePath(ctx);
        return;
    }

    // Prepare drawing path (smooth curve)
    UIBezierPath *path = [UIBezierPath bezierPath];
    path.lineWidth = self.lineWidth;
    UIBezierPath *pathLower = [UIBezierPath bezierPath];
    pathLower.lineWidth = self.lineWidth;

    CGFloat xStep = width / (CGFloat)count;
    if (xStep <= 0) xStep = 1.0;

    // Build top path (left->right), using amplitude scaled to view height
    BOOL first = YES;
    for (NSUInteger i = 0; i < count; i++) {
        float v = amps[i];
        CGFloat x = i * xStep;
        // Apply an ease curve for amplitude visual (exaggerate quieter signal gently)
        CGFloat scaled = powf(v, 0.7f); // gamma adjust for visual clarity
        CGFloat y = midY - (scaled * (midY - 2.0)); // leave small margin

        if (first) {
            [path moveToPoint:CGPointMake(x, y)];
            first = NO;
        } else {
            [path addLineToPoint:CGPointMake(x, y)];
        }
    }

    // Lower path (mirror) — draw from right->left to form closed shape if symmetric
    if (self.symmetric) {
        for (NSInteger i = (NSInteger)count - 1; i >= 0; i--) {
            float v = amps[i];
            CGFloat x = i * xStep;
            CGFloat scaled = powf(v, 0.7f);
            CGFloat y = midY + (scaled * (midY - 2.0));
            if (i == (NSInteger)count - 1) {
                [path addLineToPoint:CGPointMake(x, y)];
            } else {
                [path addLineToPoint:CGPointMake(x, y)];
            }
        }
        [path closePath];
        // fill shape
        CGContextSaveGState(ctx);
        CGContextSetFillColorWithColor(ctx, self.secondaryWaveColor.CGColor);
        [path fill];
        CGContextRestoreGState(ctx);

        // stroke centerline using primary color with slight alpha
        CGContextSaveGState(ctx);
        CGContextSetStrokeColorWithColor(ctx, self.waveColor.CGColor);
        CGContextSetLineWidth(ctx, self.lineWidth);
        [path stroke];
        CGContextRestoreGState(ctx);
    } else {
        // single line waveform
        CGContextSaveGState(ctx);
        CGContextSetStrokeColorWithColor(ctx, self.waveColor.CGColor);
        CGContextSetLineWidth(ctx, self.lineWidth);
        [path stroke];
        CGContextRestoreGState(ctx);
    }

    // Draw progress overlay (played region)
    if (self.progress > 0.0) {
        CGFloat px = width * self.progress;
        UIBezierPath *mask = [UIBezierPath bezierPathWithRect:CGRectMake(0, 0, px, size.height)];
        CGContextSaveGState(ctx);
        [mask addClip];
        // fill progress area with tinted secondary color
        CGContextSetFillColorWithColor(ctx, [self.progressColor colorWithAlphaComponent:0.12].CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, px, size.height));
        CGContextRestoreGState(ctx);

        // progress playhead line
        CGContextSetStrokeColorWithColor(ctx, self.progressColor.CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextMoveToPoint(ctx, px, 0);
        CGContextAddLineToPoint(ctx, px, size.height);
        CGContextStrokePath(ctx);
    }
}

@end