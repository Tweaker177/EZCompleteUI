// BRAssetSourceSheetViewController.h
// BrainRotGame
// EZCompleteUI v1.0 — Reusable Asset Source Bottom Sheet
//
// Purpose:
//   A themed bottom-sheet replacement for the UIAlertControllerStyleActionSheet
//   that used to ask "how do you want to provide this asset?". Shows the
//   current state of the asset (custom photo / AI prompt / default) plus a
//   table of three choices, each with an icon and short description.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The three ways a player can provide a single game asset (player sprite,
/// enemy sprite, or background).
typedef NS_ENUM(NSInteger, BRAssetSourceOption) {
    /// Pick a photo from the device's photo library.
    BRAssetSourceOptionUploadPhoto,

    /// Import an image from Files / a document provider.
    BRAssetSourceOptionUploadFile,

    /// Type a custom prompt for the AI image generator.
    BRAssetSourceOptionAIPrompt,

    /// Clear any custom photo/prompt and fall back to the backend's
    /// default AI-generated asset.
    BRAssetSourceOptionResetToDefault
};

/// Called once, after the sheet has finished dismissing itself. Not called
/// at all if the player dismisses without choosing (swipe-to-dismiss).
typedef void (^BRAssetSourceSheetCompletion)(BRAssetSourceOption selectedOption);

@interface BRAssetSourceSheetViewController : UIViewController

/// Builds a ready-to-present asset source sheet. Present it with
/// `presentViewController:animated:completion:` from any view controller.
///
/// @param displayName       Human-readable name of the asset being
///                            configured, e.g. "Player Asset".
/// @param currentStateLabel  One-line description of how this asset is
///                            currently configured, shown under the title
///                            (e.g. "Currently using a custom AI prompt:
///                            \"a glowing slime\"").
/// @param hasCustomAsset     YES if the player has already supplied a photo
///                            or prompt for this asset. Used to style the
///                            "Reset to Default" row appropriately.
/// @param completion         Invoked once a row is tapped, after the sheet
///                            has dismissed itself.
+ (instancetype)sheetForAssetDisplayName:(NSString *)displayName
                        currentStateLabel:(NSString *)currentStateLabel
                           hasCustomAsset:(BOOL)hasCustomAsset
                               completion:(BRAssetSourceSheetCompletion)completion;

@end

NS_ASSUME_NONNULL_END
