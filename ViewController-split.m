// ViewController-split.m
// Helper companion for the split-out classes added on branch codex/split-viewcontroller-classes.
//
// This file is intentionally NOT a second compiled implementation of ViewController.
// It exists so you can rename/swap files locally without losing the exact import list
// and removal checklist for the extracted class/category pairs.
//
// Why this is a helper instead of a full duplicate implementation:
// - Compiling a second full ViewController translation unit would create duplicate symbols.
// - Leaving the embedded EZBubbleCell / EZSystemCell / EZCodeBlockCell / picker classes
//   inside a copied ViewController while also compiling the extracted .m files would also
//   create duplicate class implementations.
//
// Use this while swapping names locally:
// 1) Keep the extracted files that were added on this branch:
//    - EZBubbleCell.h/.m
//    - EZSystemCell.h/.m
//    - EZCodeBlockCell.h/.m
//    - EZModelPickerViewController.h/.m
//    - EZImageSettingsViewController.h/.m
//    - ViewController+EZTitleFix.h/.m
// 2) Open your real ViewController.m and add these imports near the top:
//
//    #import "EZBubbleCell.h"
//    #import "EZSystemCell.h"
//    #import "EZCodeBlockCell.h"
//    #import "EZModelPickerViewController.h"
//    #import "EZImageSettingsViewController.h"
//    #import "ViewController+EZTitleFix.h"
//
// 3) Remove these embedded blocks from ViewController.m:
//    - @interface EZBubbleCell ... @end
//    - @implementation EZBubbleCell ... @end
//    - @interface EZSystemCell ... @end
//    - @implementation EZSystemCell ... @end
//    - @interface EZCodeBlockCell ... @end
//    - @implementation EZCodeBlockCell ... @end
//    - @interface EZModelPickerViewController ... @end
//    - @implementation EZModelPickerViewController ... @end
//    - @interface EZImageSettingsViewController ... @end
//    - @implementation EZImageSettingsViewController ... @end
//    - @interface ViewController (EZTitleFix) ... @end
//    - @implementation ViewController (EZTitleFix) ... @end
//
// 4) Then replace your current Makefile with Makefile-split.
//
// That gets you the result you actually wanted without fake compile-ready lies.
