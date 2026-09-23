// BRRicochetGameModel.h
// BrainRotGame
// EZCompleteUI
//
// Purpose:
//   Physics model for Ricochet Blast, the open-arena sibling to
//   BRGameModel's maze. Reuses the same seeded-LCG approach for
//   reproducible layouts (Play Again works the same way), but there is no
//   maze topology at all here — positions are continuous CGPoints, not
//   tile coordinates, and the board is deliberately generated with gaps
//   rather than a wall-to-wall grid so nothing corridors the player in.
//
//   The model knows nothing about UIKit rendering or sound; it reports
//   what happened each step as an array of plain event dictionaries so the
//   owning view controller can react (SFX, synth notes, HUD, life loss)
//   without the model reaching back into app UI.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Event dictionary keys.
extern NSString * const BRRicochetEventType;              // NSString, one of the constants below
extern NSString * const BRRicochetEventFrame;              // NSValue(CGRect), present on blockDestroyed
extern NSString * const BRRicochetEventLivesRemaining;      // NSNumber, present on enemyHit
extern NSString * const BRRicochetEventScore;               // NSNumber, present on gameOver / boardCleared
extern NSString * const BRRicochetEventPickupKind;          // NSNumber(BRRicochetPickupKind)
extern NSString * const BRRicochetEventPickupValue;         // NSNumber, score value for a coin

extern NSString * const BRRicochetEventTypeBoundsHit;
extern NSString * const BRRicochetEventTypeWallHit;
extern NSString * const BRRicochetEventTypeBlockDestroyed;
extern NSString * const BRRicochetEventTypeEnemyHit;
extern NSString * const BRRicochetEventTypeGameOver;
extern NSString * const BRRicochetEventTypeBoardCleared;
extern NSString * const BRRicochetEventTypeHeartCollected;
extern NSString * const BRRicochetEventTypeCoinCollected;

typedef NS_ENUM(NSInteger, BRRicochetPickupKind) {
    BRRicochetPickupKindHeart,
    BRRicochetPickupKindCoin,
};

@interface BRRicochetPickup : NSObject
@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) BRRicochetPickupKind kind;
@property (nonatomic, assign) NSInteger scoreValue;
@end

/// One breakable obstacle particle. Unlike BRGameModel's maze walls (fixed
/// HP of 3, locked to the tile grid), these sit at arbitrary float rects
/// and can take 1, 2, or 3 hits — or be cleared instantly, regardless of
/// remaining HP, by a Use blast.
@interface BRObstacle : NSObject
@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) NSInteger hp;
@property (nonatomic, assign) NSInteger maxHP;
@end

@interface BRRicochetGameModel : NSObject

@property (nonatomic, readonly) CGSize boardSize;
@property (nonatomic, readonly) NSInteger level;
@property (nonatomic, readonly) NSMutableArray<BRObstacle *> *obstacles;
@property (nonatomic, readonly) NSMutableArray<BRRicochetPickup *> *pickups;

@property (nonatomic, readonly) CGFloat playerRadius;
@property (nonatomic, readonly) CGFloat playerSpeed;   // points/sec, held constant while launched
@property (nonatomic, assign) CGPoint playerPosition;
@property (nonatomic, assign) CGVector playerVelocity;
@property (nonatomic, assign) BOOL playerLaunched;

@property (nonatomic, readonly) CGFloat enemyRadius;
@property (nonatomic, readonly) CGFloat enemySpeed;
@property (nonatomic, assign) CGPoint enemyPosition;
@property (nonatomic, assign) CGVector enemyVelocity;
@property (nonatomic, readonly) BOOL enemyActive;

@property (nonatomic, assign) NSInteger score;
@property (nonatomic, assign) NSInteger lives;

/// boardSize should match the game view's bounds in points. seed drives
/// both obstacle layout and the enemy's wander decisions, so a saved run
/// seed reproduces the same board (same contract as BRGameModel).
- (instancetype)initWithBoardSize:(CGSize)boardSize seed:(NSNumber *)seed;

/// Level one retains the original layout density. Higher levels add blocks,
/// tougher obstacles, and a quicker enemy while retaining a reproducible run.
- (instancetype)initWithBoardSize:(CGSize)boardSize seed:(NSNumber *)seed level:(NSInteger)level;

/// Sends the player down the slide and onto the board at its starting
/// angle/speed. Call once, from the launch animation's completion.
- (void)launchPlayer;

/// Steers the player's heading by ±deltaRadians while holding speed
/// constant. Call every frame the left/right button is held; the view
/// controller is responsible for the sign (left = negative, right =
/// positive, or vice versa depending on your screen's Y axis).
- (void)steerByRadians:(CGFloat)deltaRadians;

/// Advances the simulation by dt seconds and returns what happened.
- (NSArray<NSDictionary<NSString *, id> *> *)stepWithDeltaTime:(NSTimeInterval)dt;

/// Instantly clears every obstacle within radius of the player's current
/// position, regardless of remaining HP. Returns the number cleared.
- (NSInteger)blastAtPlayerWithRadius:(CGFloat)radius;

/// Defeats the enemy when the same Use radius overlaps its collision body.
/// Returns YES only for a hit; a defeated enemy remains out for this level.
- (BOOL)defeatEnemyWithBlastRadius:(CGFloat)radius;

@end

NS_ASSUME_NONNULL_END
