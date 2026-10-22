#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface EZMusicLibraryManager : NSObject
+ (instancetype)sharedManager;
@property (nonatomic, readonly) NSURL *libraryRootURL;
- (nullable NSURL *)localSongURLForEntryID:(NSString *)entryID;
/// Entry IDs in the on-device song manifest, in archive order. This is the
/// offline playlist source; references are deliberately excluded.
- (NSArray<NSString *> *)localSongEntryIDs;
/// Refreshes local metadata for an already archived song without copying audio again.
- (void)updateSongMetadataForEntry:(NSDictionary *)entry;
- (void)archiveSongAtTemporaryURL:(NSURL *)temporaryURL entry:(NSDictionary *)entry;
- (void)archiveSongAtTemporaryURL:(NSURL *)temporaryURL
                            entry:(NSDictionary *)entry
                       completion:(void (^ _Nullable)(NSURL * _Nullable localURL,
                                                      NSError * _Nullable error))completion;
- (void)archiveReferenceAtURL:(NSURL *)sourceURL sourceName:(NSString *)sourceName mode:(NSString *)mode;
@end
NS_ASSUME_NONNULL_END
