// EZFileInfoViewController.h
// EZCompleteUI
//
// Purpose:
//   "Get Info" screen for one file or folder: path, size, dates, type,
//   and — for files — a SHA-256 hash computed on a background queue
//   (streamed, so multi-hundred-MB files don't get loaded into memory).
//   Also the home of "Open in…", which hands the file to any other app
//   via the share sheet — the explorer's honest answer for formats it
//   can't handle itself (RAR, 7z, …).
//
// Changes:
//   - Initial version (file explorer P0).

#import <UIKit/UIKit.h>

@class EZFileItem;

NS_ASSUME_NONNULL_BEGIN

@interface EZFileInfoViewController : UITableViewController

- (instancetype)initWithFileItem:(EZFileItem *)item;

@end

NS_ASSUME_NONNULL_END
