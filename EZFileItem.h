// EZFileItem.h
// EZCompleteUI
//
// Purpose:
//   Value object for one row of the file explorer — a single file or
//   folder on disk, with the metadata the listing, the info screen and
//   the archive operations need. The filesystem is the model (there is
//   no database or manifest to keep in sync), so this is deliberately a
//   dumb snapshot: everything is read once, up front, via
//   NSURLResourceValues prefetch on a background queue.
//
// Changes:
//   - Initial version (file explorer P0).

#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZFileItem : NSObject

/// The file or folder this row represents.
@property (nonatomic, strong, readonly) NSURL *url;

/// Last path component — the real on-disk name. Display code should use
/// -displayName, which falls back to this.
@property (nonatomic, copy, readonly) NSString *name;

/// Optional human-facing name override. Only used for the explorer's
/// root locations ("Documents", "Library", …), whose on-disk names are
/// not always what a person would call them.
@property (nonatomic, copy, readonly, nullable) NSString *displayNameOverride;

@property (nonatomic, assign, readonly) BOOL isDirectory;

/// File size in bytes. Meaningless for directories (0).
@property (nonatomic, assign, readonly) unsigned long long fileSize;

/// Number of entries directly inside a directory, or -1 when unknown
/// (not counted, or the count failed). Files always report -1.
@property (nonatomic, assign, readonly) NSInteger childCount;

@property (nonatomic, strong, readonly, nullable) NSDate *modifiedDate;
@property (nonatomic, strong, readonly, nullable) NSDate *creationDate;

/// Concrete content type from NSURLContentTypeKey, when the system
/// could determine one. May be nil for exotic extensions — the
/// classification helpers below fall back to the path extension.
@property (nonatomic, strong, readonly, nullable) UTType *contentType;

/// Designated initializer. `resourceValues` is a dictionary as returned
/// by -[NSURL resourceValuesForKeys:error:] for the prefetch key set
/// used by the scanner; missing keys are tolerated.
- (instancetype)initWithURL:(NSURL *)url
            resourceValues:(nullable NSDictionary<NSURLResourceKey, id> *)resourceValues
                 childCount:(NSInteger)childCount
        displayNameOverride:(nullable NSString *)displayNameOverride;

/// Convenience: build an item for a root location, fetching that single
/// URL's resource values synchronously. Root locations are few and
/// small, so the one-off stat cost is fine on the main thread.
+ (nullable instancetype)rootItemWithURL:(NSURL *)url
                     displayNameOverride:(nullable NSString *)displayNameOverride;

/// Scans one directory on a background queue (including a child count
/// for each subdirectory) and calls back on the main queue with the
/// items in directory order — sorting is the caller's job, because the
/// sort mode is a view preference. On failure the items array is empty
/// and `error` describes why.
+ (void)scanDirectoryAtURL:(NSURL *)directoryURL
                completion:(void (^)(NSArray<EZFileItem *> *items,
                                     NSError * _Nullable error))completion;

/// name, or displayNameOverride when one was supplied.
- (NSString *)displayName;

#pragma mark - Classification (routing + actions)

/// Image or movie per UTType — these go to the app's custom media
/// preview instead of QuickLook.
- (BOOL)isMediaFile;

/// Something the text editor can safely open: UTType text conformance,
/// or a well-known text-ish extension when no type was determined.
- (BOOL)isTextFile;

/// Any archive the explorer knows by name (zip, tar family, deb, rar,
/// 7z), whether or not this build can extract it — the UI needs to
/// distinguish "archive we can extract" from "archive we can only
/// explain", which is what the three checks below are for.
- (BOOL)isArchiveFile;
- (BOOL)isZipArchive;
- (BOOL)isRARArchive;

/// .tar, .tar.gz, .tgz — extractable by EZArchiveService's ustar parser.
- (BOOL)isTarArchive;

/// .deb — a GNU ar archive EZArchiveService can unpack.
- (BOOL)isDebPackage;

/// Archives whose compression this build cannot decode (xz, zstd,
/// bzip2, 7z, lz4, lzma) — routed to the "can't extract yet"
/// explanation instead of a mysterious failure.
- (BOOL)isUnsupportedArchive;

@end

NS_ASSUME_NONNULL_END
