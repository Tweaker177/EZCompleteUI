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
NSString * const BRRicochetEventPickupKind        = @"pickupKind";
NSString * const BRRicochetEventPickupValue       = @"pickupValue";

NSString * const BRRicochetEventTypeBoundsHit      = @"boundsHit";
NSString * const BRRicochetEventTypeWallHit        = @"wallHit";
NSString * const BRRicochetEventTypeBlockDestroyed = @"blockDestroyed";
NSString * const BRRicochetEventTypeEnemyHit       = @"enemyHit";
NSString * const BRRicochetEventTypeGameOver       = @"gameOver";
NSString * const BRRicochetEventTypeBoardCleared   = @"boardCleared";
NSString * const BRRicochetEventTypeHeartCollected = @"heartCollected";
NSString * const BRRicochetEventTypeCoinCollected  = @"coinCollected";

#pragma mark - BRObstacle

@implementation BRObstacle
@end

@implementation BRRicochetPickup
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
static const NSTimeInterval kBRRicochetHitGraceDuration = 1.75;

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
    if (dist >= radius) return NO;

    // When a frame step places the center inside a block, the usual nearest
    // point calculation has a zero-length normal. Previously that left the
    // player embedded in the block, most visibly at the upper-left edge.
    // Pick the closest exit face and push the circle completely outside it.
    CGFloat nx = 0, ny = 0, overlap = 0;
    if (dist < 0.0001) {
        CGFloat left = center->x - CGRectGetMinX(rect);
        CGFloat right = CGRectGetMaxX(rect) - center->x;
        CGFloat top = center->y - CGRectGetMinY(rect);
        CGFloat bottom = CGRectGetMaxY(rect) - center->y;
        CGFloat nearest = MIN(MIN(left, right), MIN(top, bottom));
        if (nearest == left)        { nx = -1; overlap = left + radius; }
        else if (nearest == right)  { nx =  1; overlap = right + radius; }
        else if (nearest == top)    { ny = -1; overlap = top + radius; }
        else                        { ny =  1; overlap = bottom + radius; }
    } else {
        nx = dx / dist;
        ny = dy / dist;
        overlap = radius - dist;
    }
    center->x += nx * overlap;
    center->y += ny * overlap;

    CGFloat dot = velocity->dx * nx + velocity->dy * ny;
    // Only reflect when travelling into the face. Reflecting an already
    // outgoing vector is what makes a ball jitter indefinitely in corners.
    if (dot < 0) {
        velocity->dx -= 2 * dot * nx;
        velocity->dy -= 2 * dot * ny;
    }
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
@property (nonatomic, assign) NSInteger _level;
@property (nonatomic, strong) NSMutableArray<BRObstacle *> *_obstacles;
@property (nonatomic, strong) NSMutableArray<BRRicochetPickup *> *_pickups;
@property (nonatomic, assign) BRRicochetLCG rng;
@property (nonatomic, assign) NSTimeInterval hitGraceRemaining;
@property (nonatomic, assign, readwrite) BOOL enemyActive;
@end

@implementation BRRicochetGameModel

- (CGSize)boardSize                             { return self._boardSize; }
- (NSInteger)level                               { return self._level; }
- (NSMutableArray<BRObstacle *> *)obstacles     { return self._obstacles; }
- (NSMutableArray<BRRicochetPickup *> *)pickups { return self._pickups; }
- (CGFloat)playerRadius                         { return kBRRicochetPlayerRadius; }
- (CGFloat)playerSpeed                          { return kBRRicochetPlayerSpeed; }
- (CGFloat)enemyRadius                          { return kBRRicochetEnemyRadius; }
- (CGFloat)enemySpeed                           { return MIN(310.0, kBRRicochetEnemySpeed + (self._level - 1) * 18.0); }

- (instancetype)initWithBoardSize:(CGSize)boardSize seed:(NSNumber *)seed {
    return [self initWithBoardSize:boardSize seed:seed level:1];
}

- (instancetype)initWithBoardSize:(CGSize)boardSize seed:(NSNumber *)seed level:(NSInteger)level {
    self = [super init];
    if (!self) return nil;

    self._boardSize = boardSize;
    self._level = MAX(1, level);
    self.score = 0;
    self.lives = 3;
    // Level one uses the original seed; later arenas are stable variations.
    uint64_t levelSeed = (uint64_t)seed.integerValue ^ ((uint64_t)(self._level - 1) * 0xD1B54A32D192ED03ULL);
    brRicochetLCGSeed(&_rng, levelSeed);

    self._obstacles = [self generateObstacles];
    self._pickups = [NSMutableArray array];

    // Player sits off-board at the mouth of the slide until -launchPlayer is called.
    self.playerPosition = CGPointMake(-24, boardSize.height * 0.18);
    self.playerVelocity = CGVectorMake(0, 0);
    self.playerLaunched = NO;

    CGFloat enemyStartAngle = 2.4 + MIN(0.75, (self._level - 1) * 0.12);
    CGFloat enemySpeed = MIN(310.0, kBRRicochetEnemySpeed + (self._level - 1) * 18.0);
    self.enemyPosition = CGPointMake(boardSize.width * 0.7, boardSize.height * 0.25);
    self.enemyVelocity = CGVectorMake(enemySpeed * (CGFloat)cos(enemyStartAngle),
                                       enemySpeed * (CGFloat)sin(enemyStartAngle));
    self.enemyActive = YES;

    return self;
}

- (void)revealPickupForDestroyedObstacle:(BRObstacle *)obstacle {
    // Drops are deterministic because they use the same seeded LCG as the
    // board. Hearts are intentionally rarer and only appear when they can
    // restore health; coins give a smaller but reliable score boost.
    double roll = brRicochetLCGNextUnit(&_rng);
    BRRicochetPickupKind kind;
    if (roll < 0.13 && self.lives < 3) {
        kind = BRRicochetPickupKindHeart;
    } else if (roll < 0.48) {
        kind = BRRicochetPickupKindCoin;
    } else {
        return;
    }
    CGFloat size = kind == BRRicochetPickupKindHeart ? 30.0 : 26.0;
    CGPoint center = CGPointMake(CGRectGetMidX(obstacle.frame), CGRectGetMidY(obstacle.frame));
    BRRicochetPickup *pickup = [BRRicochetPickup new];
    pickup.kind = kind;
    pickup.scoreValue = kind == BRRicochetPickupKindCoin ? 25 : 0;
    pickup.frame = CGRectMake(center.x - size / 2.0, center.y - size / 2.0, size, size);
    [self._pickups addObject:pickup];
}

/// Scatters rectangular obstacles with deliberate gaps — same reproducible-
/// via-seed intent as BRGameModel's maze, none of its corridor logic. ~1/3
/// of grid cells are left empty so the board always reads as open.
- (NSMutableArray<BRObstacle *> *)generateObstacles {
    NSMutableArray<BRObstacle *> *result = [NSMutableArray array];

    NSInteger levelOffset = self._level - 1;
    // Slightly fewer, roomier blocks make the musical wall art readable while
    // preserving clear ricochet lanes around the board.
    NSInteger cols = MIN(8, 5 + levelOffset / 2);
    NSInteger rows = MIN(7, 4 + levelOffset / 2);
    CGFloat marginX = 42, marginY = 76;
    CGFloat cellWidth  = (self._boardSize.width  - marginX * 2) / cols;
    CGFloat cellHeight = (self._boardSize.height - marginY * 2) / rows;

    for (NSInteger row = 0; row < rows; row++) {
        for (NSInteger col = 0; col < cols; col++) {
            double gapChance = MAX(0.16, 0.34 - levelOffset * 0.025);
            if (brRicochetLCGNextUnit(&_rng) < gapChance) continue;

            double roll = brRicochetLCGNextUnit(&_rng);
            double heavyThreshold = MIN(0.46, 0.15 + levelOffset * 0.04);
            double mediumThreshold = MIN(0.78, 0.45 + levelOffset * 0.05);
            NSInteger durability = (roll < heavyThreshold) ? 3 : ((roll < mediumThreshold) ? 2 : 1);

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
    self.hitGraceRemaining = MAX(0, self.hitGraceRemaining - dt);

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
                    [self revealPickupForDestroyedObstacle:obstacle];
                    self.score += 15;
                    [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeBlockDestroyed,
                                         BRRicochetEventFrame: [NSValue value:&destroyedFrame withObjCType:@encode(CGRect)] }];
                } else {
                    self.score += 5;
                    [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeWallHit }];
                }
                break; // one obstacle collision per step — keeps the reflection stable
            }
        }

        self.playerPosition = pos;
        self.playerVelocity = vel;

        for (NSInteger i = (NSInteger)self._pickups.count - 1; i >= 0; i--) {
            BRRicochetPickup *pickup = self._pickups[i];
            CGPoint pickupCenter = CGPointMake(CGRectGetMidX(pickup.frame), CGRectGetMidY(pickup.frame));
            CGFloat reach = kBRRicochetPlayerRadius + MAX(pickup.frame.size.width, pickup.frame.size.height) / 2.0;
            if (hypot(pos.x - pickupCenter.x, pos.y - pickupCenter.y) > reach) continue;
            [self._pickups removeObjectAtIndex:i];
            if (pickup.kind == BRRicochetPickupKindHeart) {
                self.lives = MIN(3, self.lives + 1);
                [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeHeartCollected,
                                     BRRicochetEventPickupKind: @(pickup.kind),
                                     BRRicochetEventLivesRemaining: @(self.lives) }];
            } else {
                self.score += pickup.scoreValue;
                [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeCoinCollected,
                                     BRRicochetEventPickupKind: @(pickup.kind),
                                     BRRicochetEventPickupValue: @(pickup.scoreValue),
                                     BRRicochetEventScore: @(self.score) }];
            }
        }
    }

    // ── Enemy ───────────────────────────────────────────────────────────────
    if (self.enemyActive) {
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
            CGFloat enemySpeed = MIN(310.0, kBRRicochetEnemySpeed + (self._level - 1) * 18.0);
            enemyVel = CGVectorMake(enemySpeed * (CGFloat)cos(angle),
                                     enemySpeed * (CGFloat)sin(angle));
        }
        self.enemyPosition = enemyPos;
        self.enemyVelocity = enemyVel;

        // ── Player vs enemy ─────────────────────────────────────────────────
        if (self.playerLaunched) {
        CGFloat dist = (CGFloat)hypot(self.playerPosition.x - enemyPos.x, self.playerPosition.y - enemyPos.y);
        if (dist < kBRRicochetPlayerRadius + kBRRicochetEnemyRadius && self.hitGraceRemaining <= 0) {
            self.lives -= 1;
            CGFloat knockbackAngle = atan2(self.playerPosition.y - enemyPos.y, self.playerPosition.x - enemyPos.x);
            if (dist < 0.001) knockbackAngle = 0; // deterministic escape if centers exactly overlap
            self.playerVelocity = CGVectorMake(kBRRicochetPlayerSpeed * (CGFloat)cos(knockbackAngle),
                                                kBRRicochetPlayerSpeed * (CGFloat)sin(knockbackAngle));
            // Separate the sprites immediately, then give the player a short
            // recovery window so a single collision cannot drain every life.
            CGFloat separation = kBRRicochetPlayerRadius + kBRRicochetEnemyRadius + 2;
            self.playerPosition = CGPointMake(enemyPos.x + separation * (CGFloat)cos(knockbackAngle),
                                               enemyPos.y + separation * (CGFloat)sin(knockbackAngle));
            self.hitGraceRemaining = kBRRicochetHitGraceDuration;
            [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeEnemyHit,
                                  BRRicochetEventLivesRemaining: @(self.lives) }];
            if (self.lives <= 0) {
                [events addObject:@{ BRRicochetEventType: BRRicochetEventTypeGameOver,
                                      BRRicochetEventScore: @(self.score) }];
            }
        }
        }
    }

    if (self._obstacles.count == 0 && self._pickups.count == 0) {
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
        CGFloat obstacleRadius = MAX(obstacle.frame.size.width, obstacle.frame.size.height) / 2.0;
        if (hypot(center.x - self.playerPosition.x, center.y - self.playerPosition.y) <= radius + obstacleRadius) {
            [self._obstacles removeObjectAtIndex:i];
            [self revealPickupForDestroyedObstacle:obstacle];
            self.score += 15;
            cleared++;
        }
    }
    return cleared;
}

- (BOOL)defeatEnemyWithBlastRadius:(CGFloat)radius {
    if (!self.enemyActive) return NO;
    CGFloat distance = (CGFloat)hypot(self.enemyPosition.x - self.playerPosition.x,
                                      self.enemyPosition.y - self.playerPosition.y);
    if (distance > radius + kBRRicochetEnemyRadius) return NO;
    self.enemyActive = NO;
    self.score += 75;
    return YES;
}

@end
