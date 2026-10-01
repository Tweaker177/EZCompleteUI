//
//  EZPhotoGalleryAnalysisService.h
//  EZCompleteUI
//
//  Keeps a small, local manifest for gallery assets.  The manifest never
//  replaces the source photo; it only stores a compact description and tags
//  that can make gallery features more useful without re-reading every image.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const EZPhotoGalleryManifestDidChangeNotification;

@interface EZPhotoGalleryAnalysisService : NSObject

+ (instancetype)sharedService;

/// Schedules a low-resolution vision description after an image has been
/// saved. Videos and unsupported files are ignored.
- (void)queueAnalysisForPhotoAtPath:(NSString *)path;

/// Backfills missing/queued image entries when the gallery is opened.
- (void)retryQueuedAnalyses;

/// Returns the manifest entry for this exact version of a gallery file, or nil
/// when it has not been analyzed yet.
- (nullable NSDictionary<NSString *, id> *)manifestEntryForPath:(NSString *)path;

/// Returns a small read-only snapshot keyed by the supplied full paths. This
/// intentionally avoids a filesystem metadata lookup for every path, which is
/// important when a gallery action evaluates many possible reference images.
- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)manifestEntriesForPaths:(NSArray<NSString *> *)paths;

@end

NS_ASSUME_NONNULL_END
