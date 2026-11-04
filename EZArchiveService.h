// EZArchiveService.h
// EZCompleteUI
//
// Purpose:
//   ZIP creation and extraction for the file explorer, on a background
//   queue with progress + completion blocks (all callbacks delivered on
//   the main queue). Built on the vendored SSZipArchive 2.6.0 (see
//   SSZipArchive/VENDORED.txt):
//     - Creation drives SSZipArchive's instance API so folders keep
//       their structure (the class API flattens file lists).
//     - Extraction drives the vendored minizip compat reader directly,
//       because the plan's zip-slip rule is "skip and report": entries
//       whose standardized path would land outside the destination —
//       and symlink entries, the other classic escape vector — are
//       skipped, counted, and returned to the caller, never rebased
//       into the destination the way SSZipArchive's own unzip does.
//   Password-protected archives (traditional ZipCrypto and WinZip AES)
//   are supported on extraction via the same reader.
//
// Changes:
//   - Initial version (file explorer P2).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const EZArchiveServiceErrorDomain;

/// userInfo key for EZArchiveServiceErrorUnsupportedCompression: the
/// display name of the compression that blocked extraction ("XZ",
/// "Zstandard", …), so the UI can name it instead of failing vaguely.
extern NSString * const EZArchiveServiceCompressionFormatKey;

typedef NS_ERROR_ENUM(EZArchiveServiceErrorDomain, EZArchiveServiceError) {
    EZArchiveServiceErrorCorruptArchive = 1,
    EZArchiveServiceErrorWrongPassword = 2,
    EZArchiveServiceErrorCreateFailed = 3,
    EZArchiveServiceErrorWriteFailed = 4,
    EZArchiveServiceErrorCancelled = 5,
    EZArchiveServiceErrorUnsupportedCompression = 6,
};

typedef void (^EZArchiveProgressBlock)(double fraction, NSString *currentEntry);
typedef void (^EZArchiveExtractCompletion)(BOOL success,
                                            NSArray<NSString *> *skippedEntries,
                                            NSError *_Nullable error);
typedef void (^EZArchiveCreateCompletion)(BOOL success, NSError *_Nullable error);

@interface EZArchiveService : NSObject

+ (instancetype)sharedService;

/// YES when any entry in the archive carries the encryption flag.
/// Cheap central-directory scan; does not read entry data.
+ (BOOL)archiveRequiresPassword:(NSURL *)archiveURL;

/// Validates a password against the archive (SSZipArchive's check).
+ (BOOL)isPasswordValid:(NSString *)password forArchiveAtURL:(NSURL *)archiveURL;

/// Extracts on a background queue. The destination directory is created
/// if needed. On failure the destination may contain partial output —
/// removing it is the caller's choice (the explorer deletes the fresh
/// folder it created). skippedEntries lists entry names skipped by the
/// zip-slip / symlink rules, in archive order.
- (void)extractZIPAtURL:(NSURL *)archiveURL
          toDirectory:(NSURL *)destinationDirectory
             password:(nullable NSString *)password
             progress:(nullable EZArchiveProgressBlock)progress
           completion:(EZArchiveExtractCompletion)completion;

/// Creates a ZIP at destinationURL from files and/or folders (folders
/// are stored with their structure, rooted at their own name). An
/// existing file at destinationURL is replaced.
- (void)createZIPAtURL:(NSURL *)destinationURL
          fromItemURLs:(NSArray<NSURL *> *)itemURLs
              progress:(nullable EZArchiveProgressBlock)progress
            completion:(EZArchiveCreateCompletion)completion;

/// Extracts a .tar, .tar.gz, or .tgz (own ustar parser over a zlib
/// inflate stream; GNU long names and pax path headers understood).
/// Same skip-and-report rules as ZIP extraction: escaping paths,
/// symlinks, hardlinks, and device entries are skipped and reported.
- (void)extractTarAtURL:(NSURL *)archiveURL
          toDirectory:(NSURL *)destinationDirectory
             progress:(nullable EZArchiveProgressBlock)progress
           completion:(EZArchiveExtractCompletion)completion;

/// Extracts a .deb (GNU ar archive): data.tar.* is unpacked into the
/// destination, control.tar.* into a DEBIAN subfolder, plain members
/// (debian-binary) as files. If an inner tar uses a compression the app
/// can't decode yet (xz, zstd, bzip2), the completion fails with
/// EZArchiveServiceErrorUnsupportedCompression before anything is
/// written, naming the compression in the error's userInfo.
- (void)extractDebAtURL:(NSURL *)archiveURL
          toDirectory:(NSURL *)destinationDirectory
             progress:(nullable EZArchiveProgressBlock)progress
           completion:(EZArchiveExtractCompletion)completion;

/// Asks the running operation (if any) to stop at the next entry or
/// chunk boundary. Its completion then reports
/// EZArchiveServiceErrorCancelled. Thread-safe; a no-op when idle.
- (void)cancelCurrentOperation;

@end

NS_ASSUME_NONNULL_END
