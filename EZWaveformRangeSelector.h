//
//  EZWaveformRangeSelector.h
//  EZTTSLibrary
//
//  A draggable start/end range selector overlaid on top of a WaveformView. Built as a
//  UIControl subclass (beginTracking/continueTracking/endTracking), the same official
//  mechanism UISlider itself uses — NOT UIGestureRecognizer-based, because a gesture
//  recognizer on a small subview inside this screen's UIScrollView previously lost the
//  fight against the scroll view's own pan gesture. UIControl tracking doesn't have
//  that problem.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZWaveformRangeSelector : UIControl

/// Both in 0...1, always startFraction <= endFraction (enforced internally).
@property (nonatomic, assign) CGFloat startFraction;
@property (nonatomic, assign) CGFloat endFraction;

@property (nonatomic, strong) UIColor *startHandleColor;
@property (nonatomic, strong) UIColor *endHandleColor;
/// Fill color used to dim the region OUTSIDE the current selection.
@property (nonatomic, strong) UIColor *highlightColor;

/// When YES, a bar is drawn across the top connecting the two handles,
/// marking the selection as a loop region.
@property (nonatomic, assign) BOOL loopEnabled;
/// Color of the loop bar. Defaults to system yellow; hosts override with
/// their accent.
@property (nonatomic, strong) UIColor *loopBarColor;

/// Sent continuously while a handle is being dragged (drives live label/highlight updates).
/// Standard UIControlEventValueChanged.
///
/// Sent once when a drag begins — used upstream to stop any currently-playing preview
/// before the selection changes out from under it. Repurposes UIControlEventEditingDidBegin.
///
/// Sent once when a drag ends — used upstream to start a fresh preview from the new
/// selection. Repurposes UIControlEventEditingDidEnd.

@end

NS_ASSUME_NONNULL_END
