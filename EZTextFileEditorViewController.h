// EZTextFileEditorViewController.h
// EZCompleteUI
//
// Purpose:
//   Plain-text file editor, generalized from
//   EZInsuranceNotesEditorViewController (same modal-in-nav shape, own
//   Cancel/Save bar buttons) but backed by a file URL instead of a
//   string callback: monospaced text view, dirty tracking, atomic save
//   (temp file + replace). Safety rails, in order:
//     - files over 2 MB open read-only (banner says why);
//     - content that is not valid UTF-8, or contains NUL bytes, opens
//       read-only — never edited, so a binary or foreign-encoding file
//       can never be corrupted by a save;
//     - a readOnly flag from the caller (device roots, unwritable
//       locations) forces read-only regardless of content.
//
// Changes:
//   - Initial version (file explorer P1).

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZTextFileEditorViewController : UIViewController

/// Designated initializer. readOnly:YES presents a viewer (banner,
/// editing disabled, no Save button).
- (instancetype)initWithFileURL:(NSURL *)fileURL readOnly:(BOOL)readOnly;

@end

NS_ASSUME_NONNULL_END
