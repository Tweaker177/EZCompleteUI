//
//  EZTheme.h
//  EZCompleteUI
//
//  One shared visual identity for the app: deep navy + gold, with a
//  subtle hand-drawn doodle pattern for chat-like surfaces. The pattern
//  is drawn in code at runtime (EZTheme.m) — no image assets — using
//  EZCompleteUI's own motifs (coins, stars, notes, chat bubbles).
//
//  Screens opt in piece by piece; every color the theme hands out is a
//  fixed brand color, so themed screens look the same in light and dark
//  mode, exactly like the slot family already does.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZTheme : NSObject

/// Deep navy base — the app's brand background (matches the slot family
/// and the styled approval cards).
+ (UIColor *)backgroundColor;

/// Navy + the faint doodle pattern, as a tiling background color.
/// Use for chat surfaces and other large themed backgrounds.
+ (UIColor *)chatBackgroundColor;

/// Lifted navy for cards, bars and assistant bubbles sitting on the
/// patterned background.
+ (UIColor *)cardColor;

/// Brand gold accent (buttons, highlights, links on dark).
+ (UIColor *)goldColor;

/// Gold gradient for the selected segment of a segmented control, as a
/// stretchable background image — selectedSegmentTintColor is flat-only,
/// so the gradient has to arrive as an image, and the control clips it to
/// the segment's pill shape. Mostly solid in feel: a lighter gold at the
/// top settling through the brand gold to a deeper gold at the bottom.
+ (UIImage *)selectedSegmentGradientImage;

/// 1pt borders on dark surfaces (white at 10%).
+ (UIColor *)hairlineColor;

/// Primary text on themed (dark) surfaces.
+ (UIColor *)primaryTextColor;

/// Secondary text on themed (dark) surfaces (white at 60%).
+ (UIColor *)secondaryTextColor;

/// The signed-in user's chat bubbles: solid brand gold.
+ (UIColor *)userBubbleColor;

/// Text on user bubbles: the deep navy base, for contrast on gold.
+ (UIColor *)userBubbleTextColor;

/// Assistant chat bubbles: the lifted card navy.
+ (UIColor *)assistantBubbleColor;

/// Opaque navy navigation-bar appearance (white title text) for themed
/// screens that live in their own navigation controller.
+ (UINavigationBarAppearance *)navigationBarAppearance;

/// Gold gradient for large primary buttons (Sign In, Generate), as a
/// stretchable background image: the segment gradient's stops — lighter
/// gold at the top through the brand gold to a deeper gold at the bottom.
/// Set it as a button's background image with navy text; the button's own
/// corner radius clips it.
+ (UIImage *)primaryGradientImage;

/// Solid gold slider thumb (28pt circle with a navy ring), drawn in code.
/// Sliders that rely on thumbTintColor alone can render with a faint,
/// washed-out thumb; an explicit thumb image keeps the thumb fully
/// visible on the navy surfaces at any size the system renders it.
+ (UIImage *)sliderThumbImage;

@end

NS_ASSUME_NONNULL_END
