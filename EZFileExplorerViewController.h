// EZFileExplorerViewController.h
// EZCompleteUI
//
// Purpose:
//   Filza-style browser over a directory tree. One instance == one
//   folder; tapping a folder pushes another instance for that folder.
//   The default instance is a "home" screen listing the app's own
//   storage roots (Documents, Library, tmp, the app-group container,
//   Trash) plus — only when a runtime readability probe succeeds, e.g.
//   on a jailbroken install — a read-only "Device" section for
//   /var/mobile roots. This class never assumes sandbox reach: device
//   roots are probed, and folders handed in as read-only get no write
//   actions at all.
//
//   Files open in the app's existing preview paths: images/video go to
//   EZInsuranceFilePreviewViewController, text goes to
//   EZTextFileEditorViewController (writable locations) or QuickLook,
//   and everything else goes to QLPreviewController. RAR archives are
//   detected and explained (RAR extraction is not possible in-app);
//   ZIP and friends extract through EZArchiveService.
//
// Changes:
//   - Initial version (file explorer P0/P1/P2).

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZFileExplorerViewController : UIViewController

/// Home screen: the app's storage roots (+ probed device roots).
- (instancetype)init;

/// Browse one folder, writable. Used for drill-down pushes inside the
/// app container.
- (instancetype)initWithRootURL:(NSURL *)rootURL;

/// Browse one folder with an explicit title and writability. Device
/// roots pass readOnly:YES — every write action (rename, duplicate,
/// trash, import, new, edit) is then hidden, not just disabled.
- (instancetype)initWithRootURL:(NSURL *)rootURL
                          title:(nullable NSString *)title
                       readOnly:(BOOL)readOnly;

@end

NS_ASSUME_NONNULL_END
