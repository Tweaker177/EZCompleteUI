//
//  BRGameModel.h
//  BrainRotGame
//
//  A compact model for a simple maze + items + enemies.
//  Keeps data structures light so the entire game can run from the view controller.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BRTileType) {
    BRTileTypeWall,
    BRTileTypeFloor,
    BRTileTypeExit
};

@interface BRTile : NSObject <NSCopying>
@property (nonatomic) BRTileType type;
@property (nonatomic) BOOL visited; // for generation or gameplay flags
@property (nonatomic, strong, nullable) NSString *itemName;
@property (nonatomic, strong, nullable) NSString *enemyName;
@end

@interface BRGameModel : NSObject

@property (nonatomic, readonly) NSInteger cols;
@property (nonatomic, readonly) NSInteger rows;
@property (nonatomic, strong, readonly) NSMutableArray<BRTile*> *grid; // row-major: index = r*cols + c

@property (nonatomic) NSInteger playerCol;
@property (nonatomic) NSInteger playerRow;
@property (nonatomic) NSInteger playerHP;

@property (nonatomic) NSInteger exitCol;
@property (nonatomic) NSInteger exitRow;

@property (nonatomic, strong) NSString *levelFlavor; // text from AI
@property (nonatomic, strong) NSArray<NSString*> *aiItems; // item names from AI
@property (nonatomic, strong) NSArray<NSString*> *aiEnemies; // enemy descriptions from AI
@property (nonatomic, strong) NSString *vulnerableHint; // hint text from AI

- (instancetype)initWithCols:(NSInteger)cols rows:(NSInteger)rows seed:(nullable NSNumber*)seed;
- (BRTile *)tileAtCol:(NSInteger)c row:(NSInteger)r;
- (void)generateMaze;
- (void)placePlayerAtCenter;
- (void)placeExitAtEdge;
- (BOOL)movePlayerByDC:(NSInteger)dc DR:(NSInteger)dr; // returns YES if moved
- (NSArray<NSValue*>*)neighborsOfCol:(NSInteger)c row:(NSInteger)r; // list of NSValue points
- (void)placeItems:(NSArray<NSString*>*)items count:(NSInteger)count;
- (void)placeEnemies:(NSArray<NSString*>*)enemies count:(NSInteger)count;

@end

NS_ASSUME_NONNULL_END