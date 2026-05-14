//
//  BRGameModel.m
//  BrainRotGame
//

#import "BRGameModel.h"

@implementation BRTile
- (instancetype)init {
    if (self = [super init]) {
        _type = BRTileTypeWall;
        _visited = NO;
        _itemName = nil;
        _enemyName = nil;
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    BRTile *t = [[[self class] allocWithZone:zone] init];
    t.type = self.type;
    t.visited = self.visited;
    t.itemName = self.itemName;
    t.enemyName = self.enemyName;
    return t;
}
@end

@interface BRGameModel ()
@property (nonatomic, strong) NSMutableArray<BRTile*> *grid;
@end

@implementation BRGameModel

- (instancetype)initWithCols:(NSInteger)cols rows:(NSInteger)rows seed:(nullable NSNumber*)seed {
    if (self = [super init]) {
        _cols = MAX(7, cols);
        _rows = MAX(7, rows);
        _grid = [NSMutableArray arrayWithCapacity:_cols * _rows];
        for (NSInteger i=0;i<_cols*_rows;i++) {
            [_grid addObject:[[BRTile alloc] init]];
        }
        if (seed) {
            srandom((unsigned)seed.integerValue);
        } else {
            srandom((unsigned)time(NULL));
        }
        _playerHP = 10;
        _levelFlavor = @"";
        _aiItems = @[];
        _aiEnemies = @[];
        _vulnerableHint = @"";
        [self generateMaze];
        [self placePlayerAtCenter];
        [self placeExitAtEdge];
    }
    return self;
}

- (BRTile *)tileAtCol:(NSInteger)c row:(NSInteger)r {
    if (c < 0 || c >= _cols || r < 0 || r >= _rows) return nil;
    return _grid[r * _cols + c];
}

- (void)generateMaze {
    // Simple randomized DFS maze generator on an odd-sized grid
    // We'll treat tiles as cells; convert grid coordinates to cell centers.
    // For simplicity, create a grid where every cell default floor and surrounding odd walls
    // A simple carve algorithm:
    for (NSInteger r=0;r<_rows;r++) {
        for (NSInteger c=0;c<_cols;c++) {
            BRTile *t = [self tileAtCol:c row:r];
            // initialize border walls, interior floors to allow simple pathing
            if (c==0 || r==0 || c==_cols-1 || r==_rows-1) {
                t.type = BRTileTypeWall;
            } else {
                // randomly carve floor or wall to make a different maze each time
                float p = ((float)random() / (float)RAND_MAX);
                t.type = (p > 0.35) ? BRTileTypeFloor : BRTileTypeWall;
            }
            t.itemName = nil;
            t.enemyName = nil;
            t.visited = NO;
        }
    }
    // Make sure center is floor and a path exists: run a few random walk carve passes
    NSInteger passes = (_cols * _rows) / 20;
    NSInteger c = _cols/2, r = _rows/2;
    [self tileAtCol:c row:r].type = BRTileTypeFloor;
    for (NSInteger i=0;i<passes;i++) {
        int dir = random() % 4;
        if (dir==0 && c+1 < _cols-1) c++;
        else if (dir==1 && c-1 > 0) c--;
        else if (dir==2 && r+1 < _rows-1) r++;
        else if (dir==3 && r-1 > 0) r--;
        [self tileAtCol:c row:r].type = BRTileTypeFloor;
    }
    // Ensure some floor around center
    for (NSInteger rr = _rows/2 -1; rr<=_rows/2 +1; rr++) {
        for (NSInteger cc = _cols/2 -1; cc<=_cols/2 +1; cc++) {
            BRTile *t = [self tileAtCol:cc row:rr];
            if (t) t.type = BRTileTypeFloor;
        }
    }
}

- (void)placePlayerAtCenter {
    self.playerCol = _cols/2;
    self.playerRow = _rows/2;
    if ([self tileAtCol:self.playerCol row:self.playerRow].type == BRTileTypeWall) {
        [self tileAtCol:self.playerCol row:self.playerRow].type = BRTileTypeFloor;
    }
}

- (void)placeExitAtEdge {
    // choose a random point on an edge that's a floor (or carve it)
    NSMutableArray<NSValue*> *candidates = [NSMutableArray array];
    for (NSInteger c=0;c<_cols;c++) {
        [candidates addObject:[NSValue valueWithCGPoint:CGPointMake(c, 0)]];
        [candidates addObject:[NSValue valueWithCGPoint:CGPointMake(c, _rows-1)]];
    }
    for (NSInteger r=1;r<_rows-1;r++) {
        [candidates addObject:[NSValue valueWithCGPoint:CGPointMake(0, r)]];
        [candidates addObject:[NSValue valueWithCGPoint:CGPointMake(_cols-1, r)]];
    }
    // shuffle
    for (NSInteger i=candidates.count-1;i>0;i--) {
        NSInteger j = random() % (i+1);
        [candidates exchangeObjectAtIndex:i withObjectAtIndex:j];
    }
    for (NSValue *v in candidates) {
        CGPoint p = v.CGPointValue;
        BRTile *t = [self tileAtCol:p.x row:p.y];
        if (!t) continue;
        if (t.type == BRTileTypeFloor) {
            t.type = BRTileTypeExit;
            self.exitCol = p.x;
            self.exitRow = p.y;
            return;
        }
    }
    // fallback: carve an exit
    CGPoint p = [[candidates firstObject] CGPointValue];
    [self tileAtCol:p.x row:p.y].type = BRTileTypeExit;
    self.exitCol = p.x;
    self.exitRow = p.y;
}

- (BOOL)movePlayerByDC:(NSInteger)dc DR:(NSInteger)dr {
    NSInteger nc = self.playerCol + dc;
    NSInteger nr = self.playerRow + dr;
    BRTile *t = [self tileAtCol:nc row:nr];
    if (!t) return NO;
    if (t.type == BRTileTypeWall) {
        // bump
        return NO;
    }
    // move
    self.playerCol = nc;
    self.playerRow = nr;
    // if there's an enemy, take some HP
    if (t.enemyName) {
        self.playerHP -= 2;
        // remove enemy to simulate a scuffle
        t.enemyName = nil;
    }
    return YES;
}

- (NSArray<NSValue*>*)neighborsOfCol:(NSInteger)c row:(NSInteger)r {
    NSMutableArray *arr = [NSMutableArray array];
    NSArray *deltas = @[@{@(1):@(0)}, @{@(-1):@(0)}, @{@(0):@(1)}, @{@(0):@(-1)}];
    for (NSDictionary *d in deltas) {
        NSInteger dc = [[[d allKeys] firstObject] integerValue];
        NSInteger dr = [[[d allValues] firstObject] integerValue];
        NSInteger nc = c + dc;
        NSInteger nr = r + dr;
        if (nc>=0 && nc<_cols && nr>=0 && nr<_rows) {
            [arr addObject:[NSValue valueWithCGPoint:CGPointMake(nc, nr)]];
        }
    }
    return arr;
}

- (void)placeItems:(NSArray<NSString*>*)items count:(NSInteger)count {
    if (items.count==0) return;
    for (NSInteger i=0;i<count;i++) {
        NSInteger attempts = 0;
        while (attempts++ < 200) {
            NSInteger c = (random() % (_cols-2)) + 1;
            NSInteger r = (random() % (_rows-2)) + 1;
            BRTile *t = [self tileAtCol:c row:r];
            if (t && t.type == BRTileTypeFloor && !t.itemName && !(c==self.playerCol && r==self.playerRow)) {
                t.itemName = items[random() % items.count];
                break;
            }
        }
    }
}

- (void)placeEnemies:(NSArray<NSString*>*)enemies count:(NSInteger)count {
    if (enemies.count==0) return;
    for (NSInteger i=0;i<count;i++) {
        NSInteger attempts = 0;
        while (attempts++ < 200) {
            NSInteger c = (random() % (_cols-2)) + 1;
            NSInteger r = (random() % (_rows-2)) + 1;
            BRTile *t = [self tileAtCol:c row:r];
            if (t && t.type == BRTileTypeFloor && !t.enemyName && !(c==self.playerCol && r==self.playerRow)) {
                t.enemyName = enemies[random() % enemies.count];
                break;
            }
        }
    }
}

@end