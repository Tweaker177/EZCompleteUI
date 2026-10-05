// BRGameLibrary.h
// BrainRotGame
// EZCompleteUI v1.0
//
// Persistent game library. Each saved game is stored as a folder under
// <Documents>/BRGames/<uuid>/ containing meta.json, background.png,
// player.png, and enemy.png. BRGameRecord is a lightweight in-memory
// representation of one saved game; images are loaded on demand.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - BRGameRecord

/// Lightweight in-memory descriptor for one saved game.
/// Images are loaded lazily from disk the first time they are requested.
@interface BRGameRecord : NSObject

@property (nonatomic, copy)   NSString *gameID;      ///< UUID — used as the folder name on disk
@property (nonatomic, copy)   NSString *themeTitle;  ///< e.g. "DUCK INSURGENCY"
@property (nonatomic, copy)   NSString *premise;     ///< 2-3 sentence story shown on loading screen
@property (nonatomic, copy)   NSString *hint;
@property (nonatomic, strong) NSArray<NSString *> *items;
@property (nonatomic, strong) NSArray<NSString *> *enemies;
@property (nonatomic, strong) NSNumber *seed;        ///< maze generation seed
@property (nonatomic, strong) NSDate   *createdDate;

/// Lazily decoded from disk. Returns nil if the file is missing.
@property (nonatomic, strong, readonly, nullable) UIImage *backgroundImage;
@property (nonatomic, strong, readonly, nullable) UIImage *playerImage;
@property (nonatomic, strong, readonly, nullable) UIImage *enemyImage;
/// Optional shared art for maze walls and Ricochet breakable blocks.
@property (nonatomic, strong, readonly, nullable) UIImage *obstacleImage;

/// Extensible named art slots. New game modes can opt into keys such as
/// "slot_brain", "slot_seven", or "slot_cherry" without requiring a schema
/// change. Older Maze/Ricochet records simply return an empty dictionary and
/// continue to use their built-in fallback art.
@property (nonatomic, strong, readonly) NSDictionary<NSString *, UIImage *> *customAssetImages;
/// Set only for a game downloaded from the Community browser. It prevents the
/// same remote game from being saved more than once on this device.
@property (nonatomic, copy, readonly, nullable) NSString *communitySharedGameID;

/// Convenience dictionary matching the shape that BrainRotViewController
/// already consumes from buildGameAssetsWithCompletion:.
- (NSDictionary *)asAssetDict;

@end

#pragma mark - BRGameLibrary

/// Singleton that manages saving, loading, and deleting game records on disk.
@interface BRGameLibrary : NSObject

+ (instancetype)shared;

/// Saves a game asynchronously. The completion block is called on the main
/// thread with the resulting BRGameRecord once all files are written.
/// Passing nil images is safe — those files are simply not written.
- (void)saveGameWithThemeTitle:(NSString *)themeTitle
                        premise:(NSString *)premise
                           hint:(NSString *)hint
                          items:(NSArray<NSString *> *)items
                        enemies:(NSArray<NSString *> *)enemies
                           seed:(NSNumber *)seed
               backgroundImage:(nullable UIImage *)backgroundImage
                    playerImage:(nullable UIImage *)playerImage
                     enemyImage:(nullable UIImage *)enemyImage
                     completion:(nullable void (^)(BRGameRecord *record))completion;

/// Variant used by Custom Workshop when a wall/block/obstacle asset is set.
- (void)saveGameWithThemeTitle:(NSString *)themeTitle
                        premise:(NSString *)premise
                           hint:(NSString *)hint
                          items:(NSArray<NSString *> *)items
                        enemies:(NSArray<NSString *> *)enemies
                           seed:(NSNumber *)seed
               backgroundImage:(nullable UIImage *)backgroundImage
                    playerImage:(nullable UIImage *)playerImage
                     enemyImage:(nullable UIImage *)enemyImage
                  obstacleImage:(nullable UIImage *)obstacleImage
                     completion:(nullable void (^)(BRGameRecord *record))completion;

/// General-purpose asset-map variant for current and future game modes.
/// Asset keys are persisted with the record and missing keys are intentionally
/// safe: each game mode supplies its normal default image in that case.
- (void)saveGameWithThemeTitle:(NSString *)themeTitle
                        premise:(NSString *)premise
                           hint:(NSString *)hint
                          items:(NSArray<NSString *> *)items
                        enemies:(NSArray<NSString *> *)enemies
                           seed:(NSNumber *)seed
               backgroundImage:(nullable UIImage *)backgroundImage
                    playerImage:(nullable UIImage *)playerImage
                     enemyImage:(nullable UIImage *)enemyImage
                  obstacleImage:(nullable UIImage *)obstacleImage
               customAssetImages:(nullable NSDictionary<NSString *, UIImage *> *)customAssetImages
                     completion:(nullable void (^)(BRGameRecord *record))completion;

/// Returns all saved records sorted newest-first. Synchronous; call off main
/// thread for large libraries, though in practice libraries stay small.
- (NSArray<BRGameRecord *> *)allRecords;

/// Finds an existing Community download. For downloads saved by older builds,
/// title/premise are used once to adopt the local record and collapse duplicates.
- (nullable BRGameRecord *)existingCommunityRecordWithSharedGameID:(NSString *)sharedGameID
                                                         themeTitle:(NSString *)themeTitle
                                                            premise:(NSString *)premise;

/// Persists the Community source identifier after a successful download.
- (void)markRecord:(BRGameRecord *)record downloadedFromCommunityGameID:(NSString *)sharedGameID;

/// Permanently deletes a record's folder from disk.
- (void)deleteRecord:(BRGameRecord *)record;

@end

NS_ASSUME_NONNULL_END
