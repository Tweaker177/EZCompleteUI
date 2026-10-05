// BRGameLibrary.m
// BrainRotGame
// EZCompleteUI v1.0
//
// Disk layout:
//   <Documents>/BRGames/
//       <uuid>/
//           meta.json          { themeTitle, premise, hint, items, enemies, seed, createdDate }
//           background.png
//           player.png         (omitted if generation failed)
//           enemy.png          (omitted if generation failed)

#import "BRGameLibrary.h"

#pragma mark - BRGameRecord implementation

@interface BRGameRecord ()
@property (nonatomic, copy)   NSString *gameFolderPath; ///< full path to <uuid>/ folder
@property (nonatomic, copy)   NSString *communitySharedGameID;
@property (nonatomic, strong) UIImage  *cachedBackground;
@property (nonatomic, strong) UIImage  *cachedPlayer;
@property (nonatomic, strong) UIImage  *cachedEnemy;
@property (nonatomic, strong) UIImage  *cachedObstacle;
@property (nonatomic, assign) BOOL      backgroundLoaded;
@property (nonatomic, assign) BOOL      playerLoaded;
@property (nonatomic, assign) BOOL      enemyLoaded;
@property (nonatomic, assign) BOOL      obstacleLoaded;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *customAssetFiles;
@property (nonatomic, strong) NSDictionary<NSString *, UIImage *> *cachedCustomAssets;
@property (nonatomic, assign) BOOL customAssetsLoaded;
@end

@implementation BRGameRecord

- (UIImage *)backgroundImage {
    if (!self.backgroundLoaded) {
        NSString *path = [self.gameFolderPath stringByAppendingPathComponent:@"background.png"];
        self.cachedBackground = [UIImage imageWithContentsOfFile:path];
        self.backgroundLoaded = YES;
    }
    return self.cachedBackground;
}

- (UIImage *)playerImage {
    if (!self.playerLoaded) {
        NSString *path = [self.gameFolderPath stringByAppendingPathComponent:@"player.png"];
        self.cachedPlayer = [UIImage imageWithContentsOfFile:path];
        self.playerLoaded = YES;
    }
    return self.cachedPlayer;
}

- (UIImage *)enemyImage {
    if (!self.enemyLoaded) {
        NSString *path = [self.gameFolderPath stringByAppendingPathComponent:@"enemy.png"];
        self.cachedEnemy = [UIImage imageWithContentsOfFile:path];
        self.enemyLoaded = YES;
    }
    return self.cachedEnemy;
}

- (UIImage *)obstacleImage {
    if (!self.obstacleLoaded) {
        self.cachedObstacle = [UIImage imageWithContentsOfFile:[self.gameFolderPath stringByAppendingPathComponent:@"obstacle.png"]];
        self.obstacleLoaded = YES;
    }
    return self.cachedObstacle;
}

- (NSDictionary<NSString *,UIImage *> *)customAssetImages {
    if (!self.customAssetsLoaded) {
        NSMutableDictionary *images = [NSMutableDictionary dictionary];
        [self.customAssetFiles enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *filename, BOOL *stop) {
            if (![filename isKindOfClass:NSString.class]) return;
            UIImage *image = [UIImage imageWithContentsOfFile:[self.gameFolderPath stringByAppendingPathComponent:filename]];
            if (image) images[key] = image;
        }];
        self.cachedCustomAssets = images;
        self.customAssetsLoaded = YES;
    }
    return self.cachedCustomAssets ?: @{};
}

- (NSDictionary *)asAssetDict {
    // Matches the shape BrainRotViewController expects from buildGameAssetsWithCompletion:
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"themeTitle"] = self.themeTitle ?: @"BRAINROT";
    dict[@"levelDesc"]  = self.premise    ?: @"";
    dict[@"hint"]       = self.hint       ?: @"";
    dict[@"items"]      = self.items      ?: @[];
    dict[@"enemies"]    = self.enemies    ?: @[];
    UIImage *bg  = self.backgroundImage;
    UIImage *plr = self.playerImage;
    UIImage *enm = self.enemyImage;
    UIImage *obs = self.obstacleImage;
    if (bg)  dict[@"bgImage"]     = bg;
    if (plr) dict[@"playerImage"] = plr;
    if (enm) dict[@"enemyImage"]  = enm;
    if (obs) dict[@"obstacleImage"] = obs;
    return [dict copy];
}

@end

#pragma mark - BRGameLibrary implementation

@interface BRGameLibrary ()
@property (nonatomic, copy) NSString *libraryRootPath; ///< <Documents>/BRGames/
@end

@implementation BRGameLibrary

+ (instancetype)shared {
    static BRGameLibrary *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[BRGameLibrary alloc] init];
        [sharedInstance ensureLibraryDirectoryExists];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _libraryRootPath = [documents stringByAppendingPathComponent:@"BRGames"];
    }
    return self;
}

- (void)ensureLibraryDirectoryExists {
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.libraryRootPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
    if (error) NSLog(@"[BRGameLibrary] Failed to create root dir: %@", error);
}

// ── Save ──────────────────────────────────────────────────────────────────────

- (void)saveGameWithThemeTitle:(NSString *)themeTitle
                        premise:(NSString *)premise
                           hint:(NSString *)hint
                          items:(NSArray<NSString *> *)items
                        enemies:(NSArray<NSString *> *)enemies
                           seed:(NSNumber *)seed
               backgroundImage:(nullable UIImage *)backgroundImage
                    playerImage:(nullable UIImage *)playerImage
                     enemyImage:(nullable UIImage *)enemyImage
                     completion:(nullable void (^)(BRGameRecord *record))completion {
    [self saveGameWithThemeTitle:themeTitle premise:premise hint:hint items:items enemies:enemies seed:seed
                 backgroundImage:backgroundImage playerImage:playerImage enemyImage:enemyImage
                  obstacleImage:nil completion:completion];
}

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
                     completion:(nullable void (^)(BRGameRecord *record))completion {
    [self saveGameWithThemeTitle:themeTitle premise:premise hint:hint items:items enemies:enemies seed:seed backgroundImage:backgroundImage playerImage:playerImage enemyImage:enemyImage obstacleImage:obstacleImage customAssetImages:nil completion:completion];
}

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
               customAssetImages:(nullable NSDictionary<NSString *,UIImage *> *)customAssetImages
                     completion:(nullable void (^)(BRGameRecord *record))completion {

    NSString *gameID         = [[NSUUID UUID] UUIDString];
    NSString *gameFolderPath = [self.libraryRootPath stringByAppendingPathComponent:gameID];
    NSDate   *createdDate    = [NSDate date];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSError *error = nil;

        [fileManager createDirectoryAtPath:gameFolderPath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:&error];
        if (error) {
            NSLog(@"[BRGameLibrary] Failed to create game folder: %@", error);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }

        // Write meta.json
        NSMutableDictionary<NSString *, NSString *> *assetFiles = [NSMutableDictionary dictionary];
        NSDictionary *metaDict = @{
            @"themeTitle":   themeTitle  ?: @"",
            @"premise":      premise     ?: @"",
            @"hint":         hint        ?: @"",
            @"items":        items       ?: @[],
            @"enemies":      enemies     ?: @[],
            @"seed":         seed        ?: @(0),
            @"createdDate":  @(createdDate.timeIntervalSince1970),
            @"customAssetFiles": assetFiles,
        };
        NSData *metaData = [NSJSONSerialization dataWithJSONObject:metaDict options:0 error:&error];
        if (metaData) {
            [metaData writeToFile:[gameFolderPath stringByAppendingPathComponent:@"meta.json"]
                       atomically:YES];
        }

        // Write images (PNG). Missing images are silently skipped.
        void (^writePNG)(UIImage *, NSString *) = ^(UIImage *image, NSString *filename) {
            if (!image) return;
            NSData *pngData = UIImagePNGRepresentation(image);
            if (!pngData) return;
            [pngData writeToFile:[gameFolderPath stringByAppendingPathComponent:filename]
                      atomically:YES];
        };
        writePNG(backgroundImage, @"background.png");
        writePNG(playerImage,     @"player.png");
        writePNG(enemyImage,      @"enemy.png");
        writePNG(obstacleImage,   @"obstacle.png");
        [customAssetImages enumerateKeysAndObjectsUsingBlock:^(NSString *key, UIImage *image, BOOL *stop) {
            if (![key isKindOfClass:NSString.class] || ![image isKindOfClass:UIImage.class]) return;
            NSString *safeKey = [[key componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@"_"];
            if (!safeKey.length) return;
            NSString *filename = [NSString stringWithFormat:@"asset-%@.png", safeKey];
            writePNG(image, filename); assetFiles[key] = filename;
        }];
        // The asset map must be written after its files are named.
        NSMutableDictionary *finalMeta = [metaDict mutableCopy]; finalMeta[@"customAssetFiles"] = assetFiles;
        NSData *finalMetaData = [NSJSONSerialization dataWithJSONObject:finalMeta options:0 error:nil];
        if (finalMetaData) [finalMetaData writeToFile:[gameFolderPath stringByAppendingPathComponent:@"meta.json"] atomically:YES];

        // Build the in-memory record
        BRGameRecord *record = [[BRGameRecord alloc] init];
        record.gameID         = gameID;
        record.themeTitle     = themeTitle  ?: @"";
        record.premise        = premise     ?: @"";
        record.hint           = hint        ?: @"";
        record.items          = items       ?: @[];
        record.enemies        = enemies     ?: @[];
        record.seed           = seed        ?: @(0);
        record.createdDate    = createdDate;
        record.gameFolderPath = gameFolderPath;
        record.customAssetFiles = assetFiles;

        NSLog(@"[BRGameLibrary] Saved game '%@' → %@", themeTitle, gameID);

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(record); });
        }
    });
}

// ── Load ──────────────────────────────────────────────────────────────────────

- (NSArray<BRGameRecord *> *)allRecords {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray<NSString *> *subpaths = [fileManager contentsOfDirectoryAtPath:self.libraryRootPath
                                                                      error:&error];
    if (error || !subpaths) return @[];

    NSMutableArray<BRGameRecord *> *records = [NSMutableArray array];

    for (NSString *folderName in subpaths) {
        // Skip anything that's not a UUID-named directory
        NSString *folderPath = [self.libraryRootPath stringByAppendingPathComponent:folderName];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:folderPath isDirectory:&isDirectory] || !isDirectory) continue;

        NSString *metaPath = [folderPath stringByAppendingPathComponent:@"meta.json"];
        NSData   *metaData = [NSData dataWithContentsOfFile:metaPath];
        if (!metaData) continue;

        NSDictionary *metaDict = [NSJSONSerialization JSONObjectWithData:metaData
                                                                 options:0 error:nil];
        if (![metaDict isKindOfClass:[NSDictionary class]]) continue;

        BRGameRecord *record = [[BRGameRecord alloc] init];
        record.gameID         = folderName;
        record.gameFolderPath = folderPath;
        record.themeTitle     = metaDict[@"themeTitle"] ?: @"";
        record.premise        = metaDict[@"premise"]    ?: @"";
        record.hint           = metaDict[@"hint"]       ?: @"";
        record.items          = [metaDict[@"items"]   isKindOfClass:[NSArray class]]
                                     ? metaDict[@"items"]   : @[];
        record.enemies        = [metaDict[@"enemies"] isKindOfClass:[NSArray class]]
                                     ? metaDict[@"enemies"] : @[];
        record.seed           = [metaDict[@"seed"]    isKindOfClass:[NSNumber class]]
                                     ? metaDict[@"seed"]    : @(0);
        NSNumber *timestampNum = metaDict[@"createdDate"];
        record.createdDate    = timestampNum
                                     ? [NSDate dateWithTimeIntervalSince1970:timestampNum.doubleValue]
                                     : [NSDate distantPast];
        record.customAssetFiles = [metaDict[@"customAssetFiles"] isKindOfClass:NSDictionary.class] ? metaDict[@"customAssetFiles"] : @{};
        record.communitySharedGameID = [metaDict[@"communitySharedGameID"] isKindOfClass:NSString.class] ? metaDict[@"communitySharedGameID"] : nil;
        [records addObject:record];
    }

    // Sort newest first
    [records sortUsingComparator:^NSComparisonResult(BRGameRecord *a, BRGameRecord *b) {
        return [b.createdDate compare:a.createdDate];
    }];

    return [records copy];
}

- (void)markRecord:(BRGameRecord *)record downloadedFromCommunityGameID:(NSString *)sharedGameID {
    if (!record.gameFolderPath.length || !sharedGameID.length) return;
    NSString *metaPath = [record.gameFolderPath stringByAppendingPathComponent:@"meta.json"];
    NSData *data = [NSData dataWithContentsOfFile:metaPath];
    NSMutableDictionary *meta = [[NSJSONSerialization JSONObjectWithData:data options:0 error:nil] mutableCopy];
    if (!meta) return;
    meta[@"communitySharedGameID"] = sharedGameID;
    NSData *updated = [NSJSONSerialization dataWithJSONObject:meta options:0 error:nil];
    if ([updated writeToFile:metaPath atomically:YES]) record.communitySharedGameID = sharedGameID;
}

- (BRGameRecord *)existingCommunityRecordWithSharedGameID:(NSString *)sharedGameID
                                                themeTitle:(NSString *)themeTitle
                                                   premise:(NSString *)premise {
    NSArray<BRGameRecord *> *records = self.allRecords;
    for (BRGameRecord *record in records) if ([record.communitySharedGameID isEqualToString:sharedGameID]) return record;

    // Older app versions did not persist the Community ID. Adopt an exact
    // title/premise match once, and remove any extra copies created by retrying
    // the formerly broken download/play handoff.
    NSMutableArray<BRGameRecord *> *legacyMatches = [NSMutableArray array];
    for (BRGameRecord *record in records) {
        if ([record.themeTitle isEqualToString:themeTitle ?: @""] && [record.premise isEqualToString:premise ?: @""]) [legacyMatches addObject:record];
    }
    BRGameRecord *adopted = legacyMatches.firstObject;
    if (!adopted) return nil;
    [self markRecord:adopted downloadedFromCommunityGameID:sharedGameID];
    for (BRGameRecord *duplicate in legacyMatches) if (duplicate != adopted) [self deleteRecord:duplicate];
    return adopted;
}

// ── Delete ────────────────────────────────────────────────────────────────────

- (void)deleteRecord:(BRGameRecord *)record {
    if (!record.gameID.length) return;
    NSString *folderPath = [self.libraryRootPath stringByAppendingPathComponent:record.gameID];
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtPath:folderPath error:&error];
    if (error) NSLog(@"[BRGameLibrary] Delete failed: %@", error);
}

@end
