// BRGameView.m
// BrainRotGame
// EZCompleteUI v1.7
//
// Purpose:
//   Custom UIView responsible for rendering the visible portion of the maze
//   in a single drawRect: pass. Draws the background image cropped to the
//   current viewport, passability overlays for wall and exit tiles, coin and
//   heart item indicators, enemy position indicators, and (in no-image fallback
//   mode) the player dot. All layout is driven by cameraCol/cameraRow and the
//   viewport dimensions set by BrainRotViewController; this view is passive and
//   calls setNeedsDisplay only in response to property changes set externally.
//
// Changes from v1.6:
//   - Heart pickup icon enlarged to ~88% of the tile cell. Previously it was
//     sized against the inset baseRect (≈64% of the tile) and then scaled to
//     80% of that, resulting in an icon that covered roughly half the tile and
//     was hard to read at a glance during gameplay. Now uses tileRect directly
//     as the size reference so the heart nearly fills the cell, matching the
//     visual weight of the enemy and coin indicators.
//
// Changes from v1.5:
//   - Heart pickup icon replaced. The previous BRGameViewHeartPath() bezier
//     function produced a shape that read as a circle at typical tile sizes.
//     The pickup now draws heart.png from the main bundle instead, rendered
//     via UIGraphicsPushContext so UIKit handles the coordinate-system flip.
//   - BRGameViewHeartPath() removed entirely.

#import "BRGameView.h"
#import "BRGameModel.h"

#pragma mark - Individual Wall Tile Cache

static NSString *BRWallTileCacheKey(NSInteger col, NSInteger row) {
    return [NSString stringWithFormat:@"%ld,%ld", (long)col, (long)row];
}

static uint32_t BRWallTileSeed(NSInteger col, NSInteger row) {
    uint32_t value = (uint32_t)(col * 374761393 + row * 668265263);
    value = (value ^ (value >> 13)) * 1274126177;
    return value ^ (value >> 16);
}

@interface BRGameView ()

/// Cached visual pieces for the model's wall tiles.
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *wallTileCache;

@end

@implementation BRGameView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _viewportCols = 5;
        _viewportRows = 5;
        _cameraCol    = 0;
        _cameraRow    = 0;
        _wallTileCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        _viewportCols = 5;
        _viewportRows = 5;
        _cameraCol    = 0;
        _cameraRow    = 0;
        _wallTileCache = [NSMutableDictionary dictionary];
    }
    return self;
}



#pragma mark - Wall Image Tile Generation

- (void)setModel:(BRGameModel *)model {
    if (_model == model) return;

    _model = model;
    [self.wallTileCache removeAllObjects];
    [self setNeedsDisplay];
}

- (void)setBackgroundImage:(UIImage *)backgroundImage {
    if (_backgroundImage == backgroundImage) return;

    _backgroundImage = backgroundImage;
    [self.wallTileCache removeAllObjects];
    [self setNeedsDisplay];
}

- (void)setWallImage:(UIImage *)wallImage {
    if (_wallImage == wallImage) return;
    _wallImage = wallImage;
    [self.wallTileCache removeAllObjects];
    [self setNeedsDisplay];
}

/// Builds one themed, square obstacle image for one wall coordinate.
///
/// The image starts with the matching part of the generated world texture,
/// then receives an opaque obstacle layer, deterministic slabs, bevels, and
/// visible energy cracks. Since every wall is a real image piece, your existing
/// snapshotOfGameViewTileAtCol:row: explosion effect now destroys the actual
/// displayed wall artwork instead of a generic transparent dark overlay.
- (UIImage *)wallImageForCol:(NSInteger)col row:(NSInteger)row {
    NSString *cacheKey = BRWallTileCacheKey(col, row);
    UIImage *cachedImage = self.wallTileCache[cacheKey];
    if (cachedImage) return cachedImage;

    static const CGFloat kWallImageSize = 128.0;
    CGSize imageSize = CGSizeMake(kWallImageSize, kWallImageSize);

    UIGraphicsBeginImageContextWithOptions(imageSize, YES, 1.0);
    CGContextRef context = UIGraphicsGetCurrentContext();

    if (!context) {
        UIGraphicsEndImageContext();
        NSLog(@"[BrainRot] Failed to create graphics context for wall tile %ld,%ld.",
              (long)col, (long)row);
        return nil;
    }

    CGRect canvas = CGRectMake(0, 0, kWallImageSize, kWallImageSize);

    // Use the corresponding piece of the generated floor texture as a visual
    // foundation. This helps each wall belong to the AI-generated theme.
    if (self.backgroundImage && self.model) {
        CGRect fullWorldRect = CGRectMake(
            -col * kWallImageSize,
            -row * kWallImageSize,
            self.model.cols * kWallImageSize,
            self.model.rows * kWallImageSize
        );

        UIGraphicsPushContext(context);
        [self.backgroundImage drawInRect:fullWorldRect];
        UIGraphicsPopContext();
    } else {
        CGContextSetFillColorWithColor(context,
            [UIColor colorWithRed:0.10 green:0.06 blue:0.16 alpha:1.0].CGColor);
        CGContextFillRect(context, canvas);
    }

    // Custom workshop wall art stays deliberately dark and translucent, so the
    // maze remains readable over any theme background.
    if (self.wallImage) {
        UIGraphicsPushContext(context);
        [self.wallImage drawInRect:canvas blendMode:kCGBlendModeNormal alpha:0.40];
        UIGraphicsPopContext();
    }

    // Dense wall base. This gives unmistakable visual passability contrast
    // while retaining enough themed color from the source texture.
    CGContextSetFillColorWithColor(context,
        [UIColor colorWithRed:0.025 green:0.01 blue:0.06 alpha:0.80].CGColor);
    CGContextFillRect(context, canvas);

    uint32_t seed = BRWallTileSeed(col, row);
    NSInteger slabCount = 4 + (seed % 4);

    // Deterministic slab details prevent every 1x1 piece from looking cloned.
    for (NSInteger index = 0; index < slabCount; index++) {
        uint32_t slabSeed = seed + (uint32_t)(index * 7919);

        CGFloat width = 30.0 + ((slabSeed >> 3) % 50);
        CGFloat height = 16.0 + ((slabSeed >> 11) % 28);
        CGFloat x = ((slabSeed >> 17) % 128);
        CGFloat y = ((slabSeed >> 24) % 128);

        CGRect slabRect = CGRectMake(
            x - width / 2.0,
            y - height / 2.0,
            width,
            height
        );

        UIColor *slabColor = (index % 2 == 0)
            ? [UIColor colorWithRed:0.30 green:0.12 blue:0.42 alpha:0.55]
            : [UIColor colorWithRed:0.08 green:0.20 blue:0.30 alpha:0.62];

        CGContextSetFillColorWithColor(context, slabColor.CGColor);
        CGContextFillRect(context, slabRect);

        CGContextSetStrokeColorWithColor(context,
            [UIColor colorWithWhite:0.85 alpha:0.14].CGColor);
        CGContextSetLineWidth(context, 1.0);
        CGContextStrokeRect(context, CGRectInset(slabRect, 0.5, 0.5));
    }

    // Raised block bevel: light at top/left, shadow at bottom/right.
    CGContextSetStrokeColorWithColor(context,
        [UIColor colorWithWhite:1.0 alpha:0.20].CGColor);
    CGContextSetLineWidth(context, 3.0);
    CGContextMoveToPoint(context, 1.5, kWallImageSize - 1.5);
    CGContextAddLineToPoint(context, 1.5, 1.5);
    CGContextAddLineToPoint(context, kWallImageSize - 1.5, 1.5);
    CGContextStrokePath(context);

    CGContextSetStrokeColorWithColor(context,
        [UIColor colorWithWhite:0.0 alpha:0.72].CGColor);
    CGContextSetLineWidth(context, 3.0);
    CGContextMoveToPoint(context, kWallImageSize - 1.5, 1.5);
    CGContextAddLineToPoint(context, kWallImageSize - 1.5, kWallImageSize - 1.5);
    CGContextAddLineToPoint(context, 1.5, kWallImageSize - 1.5);
    CGContextStrokePath(context);

    // The crack is deterministic, ensuring a wall tile always looks identical
    // after scrolling, redrawing, reloading, or generating an explosion snapshot.
    CGContextSetStrokeColorWithColor(context,
        [UIColor colorWithRed:0.66 green:0.20 blue:0.95 alpha:0.34].CGColor);
    CGContextSetLineWidth(context, 1.5);

    CGFloat crackStartX = 18.0 + ((seed >> 5) % 70);
    CGFloat crackStartY = 18.0 + ((seed >> 13) % 60);

    CGContextMoveToPoint(context, crackStartX, crackStartY);
    CGContextAddLineToPoint(context, crackStartX + 14.0, crackStartY + 9.0);
    CGContextAddLineToPoint(context, crackStartX + 7.0, crackStartY + 25.0);
    CGContextAddLineToPoint(context, crackStartX + 27.0, crackStartY + 38.0);
    CGContextStrokePath(context);

    UIImage *wallImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!wallImage) {
        NSLog(@"[BrainRot] Failed to build wall image for tile %ld,%ld.",
              (long)col, (long)row);
        return nil;
    }

    self.wallTileCache[cacheKey] = wallImage;
    return wallImage;
}


- (void)drawRect:(CGRect)rect {
    if (!self.model) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGFloat viewWidth  = CGRectGetWidth(self.bounds);
    CGFloat viewHeight = CGRectGetHeight(self.bounds);
    CGFloat tileWidth  = viewWidth  / (CGFloat)self.viewportCols;
    CGFloat tileHeight = viewHeight / (CGFloat)self.viewportRows;

    NSInteger colStart = self.cameraCol;
    NSInteger rowStart = self.cameraRow;
    NSInteger colEnd   = MIN(self.model.cols, colStart + self.viewportCols);
    NSInteger rowEnd   = MIN(self.model.rows, rowStart + self.viewportRows);

    // ── Background image: crop viewport region and draw as base layer ─────────
    // CGImageCreateWithImageInRect works in pixel space, so multiply by scale.
    // The crop exactly matches colStart…colEnd / rowStart…rowEnd, so it is
    // always pixel-perfectly aligned with the tile overlay drawn below.
    if (self.backgroundImage) {
        CGFloat imageScale   = self.backgroundImage.scale;
        CGFloat imagePixelW  = self.backgroundImage.size.width  * imageScale;
        CGFloat imagePixelH  = self.backgroundImage.size.height * imageScale;
        CGFloat pixelsPerCol = imagePixelW / (CGFloat)self.model.cols;
        CGFloat pixelsPerRow = imagePixelH / (CGFloat)self.model.rows;

        CGRect sourcePixelRect = CGRectMake(
            colStart * pixelsPerCol,
            rowStart * pixelsPerRow,
            (colEnd - colStart) * pixelsPerCol,
            (rowEnd - rowStart) * pixelsPerRow);

        CGImageRef croppedImageRef = CGImageCreateWithImageInRect(
            self.backgroundImage.CGImage, sourcePixelRect);
        if (croppedImageRef) {
            // CGContextDrawImage draws upside-down relative to UIKit, so flip
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, 0, viewHeight);
            CGContextScaleCTM(ctx, 1.0, -1.0);
            CGContextDrawImage(ctx, CGRectMake(0, 0, viewWidth, viewHeight), croppedImageRef);
            CGContextRestoreGState(ctx);
            CGImageRelease(croppedImageRef);
        }
    }

    // ── Tile overlays ─────────────────────────────────────────────────────────
    for (NSInteger row = rowStart; row < rowEnd; row++) {
        for (NSInteger col = colStart; col < colEnd; col++) {
            BRTile    *tile       = [self.model tileAtCol:col row:row];
            NSInteger screenCol   = col - colStart;
            NSInteger screenRow   = row - rowStart;
            CGRect    tileRect    = CGRectMake(screenCol * tileWidth,
                                               screenRow * tileHeight,
                                               tileWidth, tileHeight);

            if (self.backgroundImage) {
                // ── Image mode: passability overlay ──────────────────────────
                // Wall tiles get a dark mask so the player knows they can't pass.
                // Floor tiles are left clear — the image shows through.
                // This is the only reliable way to communicate passability across
                // any AI art style without depending on image brightness.
                switch (tile.type) {
                    case BRTileTypeWall: {
                        // The authoritative BRGameModel wall now has its own real
                        // image tile. Maze topology is therefore always exact, and
                        // wall-blast snapshots contain the displayed wall artwork.
                        UIImage *wallImage = [self wallImageForCol:col row:row];
                        if (wallImage) {
                            UIGraphicsPushContext(ctx);
                            [wallImage drawInRect:tileRect];
                            UIGraphicsPopContext();
                        } else {
                            // Defensive fallback if image creation unexpectedly fails.
                            CGContextSetFillColorWithColor(ctx,
                                [UIColor colorWithRed:0.05 green:0.02 blue:0.10 alpha:1.0].CGColor);
                            CGContextFillRect(ctx, tileRect);
                        }
                        break;
                    }
                    case BRTileTypeExit:
                        CGContextSetFillColorWithColor(ctx,
                            [UIColor colorWithRed:0.05 green:0.85 blue:0.25 alpha:0.55].CGColor);
                        CGContextFillRect(ctx, tileRect);
                        // Bright ring so it stands out
                        CGContextSetStrokeColorWithColor(ctx,
                            [UIColor colorWithRed:0.1 green:1.0 blue:0.35 alpha:0.95].CGColor);
                        CGContextSetLineWidth(ctx, 2.5);
                        CGContextStrokeEllipseInRect(ctx,
                            CGRectInset(tileRect, tileWidth * 0.08, tileHeight * 0.08));
                        break;
                    case BRTileTypeFloor:
                    default:
                        break; // clear — image shows through
                }
            } else {
                // ── Fallback mode: solid-color tiles ─────────────────────────
                UIColor *fillColor;
                switch (tile.type) {
                    case BRTileTypeWall:
                        fillColor = [UIColor colorWithWhite:0.12 alpha:1.0]; break;
                    case BRTileTypeFloor:
                        fillColor = [UIColor colorWithWhite:0.92 alpha:1.0]; break;
                    case BRTileTypeExit:
                        fillColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.25 alpha:0.90]; break;
                    default:
                        fillColor = [UIColor blackColor]; break;
                }
                CGContextSetFillColorWithColor(ctx, fillColor.CGColor);
                CGContextFillRect(ctx, tileRect);

                // A saved Workshop wall asset still works when a game falls
                // back to solid-color floors (for example if its background
                // image is unavailable in this session).
                if (tile.type == BRTileTypeWall && self.wallImage) {
                    UIGraphicsPushContext(ctx);
                    [self.wallImage drawInRect:tileRect blendMode:kCGBlendModeNormal alpha:0.40];
                    UIGraphicsPopContext();
                }

                // Grid lines in fallback mode only
                CGContextSetStrokeColorWithColor(ctx,
                    [UIColor colorWithWhite:0.75 alpha:0.5].CGColor);
                CGContextSetLineWidth(ctx, 0.5);
                CGContextStrokeRect(ctx, tileRect);
            }

            // ── Item indicator — coins vs heart pickups ─────────────────────────
            if (tile.itemName) {
                CGRect baseRect = CGRectInset(tileRect, tileWidth * 0.18, tileHeight * 0.18);
                BOOL isHeartPickup = ([tile.itemName rangeOfString:@"heart"
                                                      options:NSCaseInsensitiveSearch].location != NSNotFound);
                if (isHeartPickup) {
                    // Load heart.png from the bundle (cached by UIImage after first call).
                    UIImage *heartImage = [UIImage imageNamed:@"heart"];
                    if (heartImage) {
                        // Use tileRect as the size reference rather than the inset
                        // baseRect, so the heart nearly fills the full tile cell.
                        // 0.88 leaves a small visible margin so adjacent tiles remain
                        // distinguishable even when two hearts are side by side.
                        CGFloat pulseScale  = 1.0 + 0.12 * sinf(self.heartPulsePhase);
                        CGFloat baseSize    = MIN(tileRect.size.width, tileRect.size.height) * 0.88;
                        CGFloat scaledSize  = baseSize * pulseScale;
                        CGRect heartDrawRect = CGRectMake(CGRectGetMidX(tileRect) - scaledSize / 2.0,
                                                          CGRectGetMidY(tileRect) - scaledSize / 2.0,
                                                          scaledSize, scaledSize);
                        UIGraphicsPushContext(ctx);
                        [heartImage drawInRect:heartDrawRect];
                        UIGraphicsPopContext();
                    }
                } else {
                    CGContextSetFillColorWithColor(ctx,
                        [UIColor colorWithRed:1.0 green:0.88 blue:0.0 alpha:1.0].CGColor);
                    CGContextFillEllipseInRect(ctx, baseRect);
                    CGContextSetStrokeColorWithColor(ctx,
                        [UIColor colorWithRed:0.55 green:0.40 blue:0.0 alpha:0.9].CGColor);
                    CGContextSetLineWidth(ctx, 1.0);
                    CGContextStrokeEllipseInRect(ctx, CGRectInset(baseRect, 0.5, 0.5));
                }
            }

            // ── Enemy indicator — always drawn regardless of hidePlayerDot ────
            if (tile.enemyName) {
                CGRect enemyRect = CGRectInset(tileRect, tileWidth * 0.12, tileHeight * 0.12);
                if (self.backgroundImage) {
                    CGContextSetFillColorWithColor(ctx,
                        [UIColor colorWithRed:0.9 green:0.1 blue:0.1 alpha:0.45].CGColor);
                    CGContextFillEllipseInRect(ctx, enemyRect);
                    CGContextSetStrokeColorWithColor(ctx,
                        [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:0.95].CGColor);
                    CGContextSetLineWidth(ctx, 2.0);
                    CGContextStrokeEllipseInRect(ctx, CGRectInset(enemyRect, 1.0, 1.0));
                } else {
                    CGContextSetFillColorWithColor(ctx,
                        [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1.0].CGColor);
                    CGContextFillEllipseInRect(ctx, enemyRect);
                }
            }

        }
    }

    // ── Player dot (fallback mode only) ───────────────────────────────────────
    if (!self.hidePlayerDot) {
        NSInteger playerScreenCol = self.model.playerCol - colStart;
        NSInteger playerScreenRow = self.model.playerRow - rowStart;
        if (playerScreenCol >= 0 && playerScreenCol < self.viewportCols &&
            playerScreenRow >= 0 && playerScreenRow < self.viewportRows) {
            CGFloat playerW = tileWidth  * 0.75;
            CGFloat playerH = tileHeight * 0.75;
            CGRect playerRect = CGRectMake(
                playerScreenCol * tileWidth  + (tileWidth  - playerW) / 2.0,
                playerScreenRow * tileHeight + (tileHeight - playerH) / 2.0,
                playerW, playerH);
            CGContextSetFillColorWithColor(ctx,
                [UIColor colorWithRed:0.12 green:0.45 blue:0.9 alpha:1.0].CGColor);
            CGContextFillEllipseInRect(ctx, playerRect);
        }
    }
}

@end
