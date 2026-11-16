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

@end

NS_ASSUME_NONNULL_END
