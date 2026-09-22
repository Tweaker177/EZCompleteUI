// BRRicochetGameModel.m
// BrainRotGame
// EZCompleteUI
//
// See BRRicochetGameModel.h. Obstacle layout uses the same tiny seeded LCG
// as BRGameModel (kept as a local static copy rather than a shared header
// so this file has zero dependency on the maze model) but applies it to a
// scattered open layout instead of a recursive-backtracker maze.

#import "BRRicochetGameModel.h"
#import <math.h>

NSString * const BRRicochetEventType              = @"type";
NSString * const BRRicochetEventFrame             = @"frame";
NSString * const BRRicochetEventLivesRemaining    = @"livesRemaining";
NSString * const BRRicochetEventScore             = @"score";

NSString * const BRRicochetEventTypeBoundsHit      = @"boundsHit";
NSString * const BRRicochetEventTypeWallHit        = @"wallHit";
NSString * const BRRicochetEventTypeBlockDestroyed = @"blockDestroyed";
NSString * const BRRicochetEventTypeEnemyHit       = @"enemyHit";
NSString * const BRRicochetEventTypeGameOver       = @"gameOver";
NSString * const BRRicochetEventTypeBoardCleared   = @"boardCleared";

#pragma mark - BRObstacle

@implementation BRObstacle
@end

#pragma mark - Seeded LCG (see BRGameModel.m for the maze's version of the same idea)

typedef struct { uint64_t state; } BRRicochetLCG;

static void brRicochetLCGSeed(BRRicochetLCG *rng, uint64_t seed) {
    rng->state = seed ^ 0x9E3779B97F4A7C15ULL;
}

/// Returns a pseudo-random double in [0, 1).
static double brRicochetLCGNextUnit(BRRicochetLCG *rng) {
    rng->state = rng->state * 6364136223846793005ULL + 1442695040888963407ULL;
    uint64_t shifted = (rng->state >> 33) ^ rng->state;
    return (double)(shifted % 1000000ULL) / 1000000.0;
}

#pragma mark - Tuning constants

static const CGFloat kBRRicochetPlayerRadius = 18.0;
static const CGFloat kBRRicochetEnemyRadius  = 20.0;
static const CGFloat kBRRicochetPlayerSpeed  = 260.0; // pt/sec — held constant per the brief
static const CGFloat kBRRicochetEnemySpeed   = 190.0;
static const CGFloat kBRRicochetLaunchAngle  = 0.70;  // radians, down-and-right off the slide

#pragma mark - Collision helpers (file-local, no UIKit dependency)

/// Reflects `velocity` off the nearest point of `rect` for a circle of
/// `radius` centered at `center`. Mutates both by reference and returns YES
/// if a collision occurred this call.
static BOOL BRReflectCircleOffRect(CGPoint *center, CGVector *velocity, CGFloat radius, CGRect rect) {
    CGFloat closestX = MAX(CGRectGetMinX(rect), MIN(center->x, CGRectGetMaxX(rect)));
    CGFloat closestY = MAX(CGRectGetMinY(rect), MIN(center->y, CGRectGetMaxY(rect)));
    CGFloat dx = center->x - closestX;
    CGFloat dy = center->y - closestY;
    CGFloat dist = (CGFloat)hypot(dx, dy);
    if (dist >= radius || dist < 0.0001) return NO;

    CGFloat overlap = radius - dist;
    CGFloat nx = dx / dist, ny = dy / dist;
    center->x += nx * overlap;
    center->y += ny * overlap;

    CGFloat dot = velocity->dx * nx + velocity->dy * ny;
    velocity->dx -= 2 * dot * nx;
    velocity->dy -= 2 * dot * ny;
    return YES;
}

static BOOL BRReflectCircleOffBounds(CGPoint *center, CGVector *velocity, CGFloat radius, CGSize bounds) {
    BOOL hit = NO;
    if (center->x - radius < 0)             { center->x = radius;               velocity->dx = (CGFloat)fabs(velocity->dx);  hit = YES; }
    if (center->x + radius > bounds.width)  { center->x = bounds.width - radius; velocity->dx = -(CGFloat)fabs(velocity->dx); hit = YES; }
    if (center->y - radius < 0)             { center->y = radius;               velocity->dy = (CGFloat)fabs(velocity->dy);  hit = YES; }
    if (center->y + radius > bounds.height) { center->y = bounds.height - radius; velocity->dy = -(CGFloat)fabs(velocity->dy); hit = YES; }
    return hit;
}

#pragma mark - BRRicochetGameModel

@interface BRRicochetGameModel ()
@property (nonatomic, assign) CGSize _boardSize;                    // underscore-prefixed property, matches BRGameModel's convention
@property (nonatomic, strong) NSMutableArray<BRObstacle *> *_obstacles;
@property (nonatomic, assign) BRRicochetLCG rng;
@end

@implementation BRRicochetGameModel

- (CGSize)boardSize                             { return self._boardSize; }
- (NSMutableArray<BRObstacle *> *)obstacles     { return self._obstacles; }
- (CGFloat)playerRadius                         { return kBRRicochetPlayerRadius; }
- (CGFloat)playerSpeed                          { return kBRRicochetPlayerSpeed; }
- (CGFloat)enemyRadius                          { return kBRRicochetEnemyRadius; }
- (CGFloat)enemySpeed                           { return kBRRicochetEnemySpeed; }

- (instancetype)initWithBoardSize:(CGSize)boardSize seed:(NSNumber *)seed {
    self = [super init];
    if (!self) return nil;

    self._boardSize = boardSize;
    self.score = 0;
    self.lives = 3;
    brRicochetLCGSeed(&_rng, (uint64_t)seed.integerValue);

    self._obstacles = [self generateObstacles];

    // Player sits off-board at the mouth of the slide until -launchPlayer is called.
    self.playerPosition = CGPointMake(-24, boardSize.height * 0.18);
    self.playerVelocity = CGVectorMake(0, 0);
    self.playerLaunched = NO;

    CGFloat enemyStartAngle = 2.4;
    self.enemyPosition = CGPointMake(boardSize.width * 0.7, boardSize.height * 0.25);
    self.enemyVelocity = CGVectorMake(kBRRicochetEnemySpeed * (CGFloat)cos(enemyStartAngle),
                                       kBRRicochetEnemySpeed * (CGFloat)sin(enemyStartAngle));

    return self;
}

/// Scatters rectangular obstacles with deliberate gaps — same reproducible-
/// via-seed intent as BRGameModel's maze, none of its corridor logic. ~1/3
/// of grid cells are left empty so the board always reads as open.
- (NSMutableArray<BRObstacle *> *)generateObstacles {
    NSMutableArray<BRObstacle *> *result = [NSMutableArray array];

    NSInteger cols = 6, rows = 5;
    CGFloat marginX = 50, marginY = 90;
    CGFloat cellWidth  = (self._boardSize.width  - marginX * 2) / cols;
    CGFloat cellHeight = (self._boardSize.height - marginY * 2) / rows;

    for (NSInteger row = 0; row < rows; row++) {
        for (NSInteger col = 0; col < cols; col++) {
            if (brRicochetLCGNextUnit(&_rng) < 0.34) continue; // leave a gap — board must stay open

            double roll = brRicochetLCGNextUnit(&_rng);
            NSInteger durability = (roll < 0.15) ? 3 : ((roll < 0.45) ? 2 : 1);

            BRObstacle *obstacle = [[BRObstacle alloc] init];
            obstacle.frame = CGRectMake(marginX + col * cellWidth  + 8,
                                         marginY + row * cellHeight + 8,
                                         cellWidth  - 16,
                                         cellHeight - 16);
            obstacle.hp    = durability;
            obstacle.maxHP = durability;
            [result addObject:obstacle];
        }
    }
    return result;
}

- (void)launchPlayer {
    self.playerVelocity = CGVectorMake(kBRRicochetPlayerSpeed * (CGFloat)cos(kBRRicochetLaunchAngle),
                                        kBRRicochetPlayerSpeed * (CGFloat)sin(kBRRicochetLaunchAngle));
    self.playerLaunched = YES;
}

- (void)steerByRadians:(CGFloat)deltaRadians {
    if (!self.playerLaunched || deltaRadians == 0) return;
    CGFloat speed = (CGFloat)hypot(self.playerVelocity.dx, self.playerVelocity.dy);
    if (speed < 0.001) speed = kBRRicochetPlayerSpeed;
    CGFloat angle = atan2(self.playerVelocity.dy, self.playerVelocity.dx) + deltaRadians;
    self.playerVelocity = CGVectorMake(speed * (CGFloat)cos(angle), speed * (CGFloat)sin(angle));
}

- (NSArray<NSDictionary<NSString *, id> *> *)stepWithDeltaTime:(NSTimeInterval)dt {
    NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
    if (dt <= 0) return events;

    // ── Player ──────────────────────────────────────────────────────────────
    if (self.playerLaunched) {
        CGPoint pos  = self.playerPosition;
        CGVector vel = self.playerVelocity;
        pos.x += vel.dx * dt;
        pos.y += vel.dy * dt;

        if (BRReflectCircleOffBounds(&pos, &vel, kBRRicochetPlayerRadius, self._boardSize)) {
            [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeBoundsHit }];
        }

        for (NSInteger i = (NSInteger)self._obstacles.count - 1; i >= 0; i--) {
            BRObstacle *obstacle = self._obstacles[i];
            if (BRReflectCircleOffRect(&pos, &vel, kBRRicochetPlayerRadius, obstacle.frame)) {
                obstacle.hp -= 1;
                if (obstacle.hp <= 0) {
                    CGRect destroyedFrame = obstacle.frame;
                    [self._obstacles removeObjectAtIndex:i];
                    self.score += 15;
                    [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeBlockDestroyed,
                                         BRRicochetEventFrame: [NSValue valueWithCGRect:destroyedFrame] }];
                } else {
                    self.score += 5;
                    [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeWallHit }];
                }
                break; // one obstacle collision per step — keeps the reflection stable
            }
        }

        self.playerPosition = pos;
        self.playerVelocity = vel;
    }

    // ── Enemy ───────────────────────────────────────────────────────────────
    CGPoint enemyPos  = self.enemyPosition;
    CGVector enemyVel = self.enemyVelocity;
    enemyPos.x += enemyVel.dx * dt;
    enemyPos.y += enemyVel.dy * dt;
    BRReflectCircleOffBounds(&enemyPos, &enemyVel, kBRRicochetEnemyRadius, self._boardSize);
    for (BRObstacle *obstacle in self._obstacles) {
        BRReflectCircleOffRect(&enemyPos, &enemyVel, kBRRicochetEnemyRadius, obstacle.frame);
    }
    if (brRicochetLCGNextUnit(&_rng) < 0.01) {
        CGFloat wander = (CGFloat)(brRicochetLCGNextUnit(&_rng) - 0.5) * 0.6f;
        CGFloat angle  = atan2(enemyVel.dy, enemyVel.dx) + wander;
        enemyVel = CGVectorMake(kBRRicochetEnemySpeed * (CGFloat)cos(angle),
                                 kBRRicochetEnemySpeed * (CGFloat)sin(angle));
    }
    self.enemyPosition = enemyPos;
    self.enemyVelocity = enemyVel;

    // ── Player vs enemy ─────────────────────────────────────────────────────
    if (self.playerLaunched) {
        CGFloat dist = (CGFloat)hypot(self.playerPosition.x - enemyPos.x, self.playerPosition.y - enemyPos.y);
        if (dist < kBRRicochetPlayerRadius + kBRRicochetEnemyRadius) {
            self.lives -= 1;
            CGFloat knockbackAngle = atan2(self.playerPosition.y - enemyPos.y, self.playerPosition.x - enemyPos.x);
            self.playerVelocity = CGVectorMake(kBRRicochetPlayerSpeed * (CGFloat)cos(knockbackAngle),
                                                kBRRicochetPlayerSpeed * (CGFloat)sin(knockbackAngle));
            [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeEnemyHit,
                                  BRRicochetEventLivesRemaining: @(self.lives) }];
            if (self.lives <= 0) {
                [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeGameOver,
                                      BRRicochetEventScore: @(self.score) }];
            }
        }
    }

    if (self._obstacles.count == 0) {
        [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeBoardCleared,
                              BRRicochetEventScore: @(self.score) }];
    }

    return events;
}

- (NSInteger)blastAtPlayerWithRadius:(CGFloat)radius {
    NSInteger cleared = 0;
    for (NSInteger i = (NSInteger)self._obstacles.count - 1; i >= 0; i--) {
        BRObstacle *obstacle = self._obstacles[i];
        CGPoint center = CGPointMake(CGRectGetMidX(obstacle.frame), CGRectGetMidY(obstacle.frame));
        if (hypot(center.x - self.playerPosition.x, center.y - self.playerPosition.y) < radius) {
            [self._obstacles removeObjectAtIndex:i];
            self.score += 15;
            cleared++;
        }
    }
    return cleared;
}

@end
