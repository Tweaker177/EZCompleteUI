import sys, os, shutil

TARGET = "SidewaysScrollView.m"

# ── Patch 1: Add UIImpactFeedbackGenerator import after QuartzCore ────────────

OLD_IMPORT = '''#import "SidewaysScrollView.h"
#import <QuartzCore/QuartzCore.h>'''

NEW_IMPORT = '''#import "SidewaysScrollView.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>   // UIImpactFeedbackGenerator'''

# ── Patch 2: Wire up touch events in cloneFrom: just before return btn ────────

OLD_RETURN_BTN = '''    return btn;
}

#pragma mark - Coverflow Transform'''

NEW_RETURN_BTN = '''    // Press/release animation + haptic
    [btn addTarget:self action:@selector(ez_btnTouchDown:)
          forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [btn addTarget:self action:@selector(ez_btnTouchUp:)
          forControlEvents:UIControlEventTouchUpInside
                          | UIControlEventTouchUpOutside
                          | UIControlEventTouchCancel
                          | UIControlEventTouchDragExit];

    return btn;
}

#pragma mark - Button Press Animation

- (void)ez_btnTouchDown:(UIButton *)btn {
    // Scale down and darken slightly — feels like a physical press
    [UIView animateWithDuration:0.10
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:3.0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        btn.transform = CGAffineTransformMakeScale(0.88, 0.88);
        btn.alpha = btn.alpha * 0.75;
    } completion:nil];

    // Medium impact haptic — feels like a click
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *hap = [[UIImpactFeedbackGenerator alloc]
            initWithStyle:UIImpactFeedbackStyleMedium];
        [hap prepare];
        [hap impactOccurred];
    }
}

- (void)ez_btnTouchUp:(UIButton *)btn {
    // Spring back to whatever coverflow transform the scroll position dictates.
    // We restore identity here then let the next applyCoverflowTransforms call
    // re-apply the correct 3-D transform on the next scroll tick (or immediately).
    [UIView animateWithDuration:0.30
                          delay:0
         usingSpringWithDamping:0.55
          initialSpringVelocity:4.0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        btn.transform = CGAffineTransformIdentity;
        // Restore alpha to what coverflow would set for this button.
        // Use 1.0 as a safe default — applyCoverflowTransforms corrects it
        // on the very next scroll event.
        btn.alpha = 1.0;
    } completion:^(BOOL finished) {
        // Re-apply the correct coverflow state immediately after spring settles
        [self applyCoverflowTransforms];
    }];
}

#pragma mark - Coverflow Transform'''

# ── Apply ─────────────────────────────────────────────────────────────────────

def apply_patch(source, old, new, name):
    if old not in source:
        print(f"  FAIL: Could not find anchor for '{name}'")
        print(f"        The file may have changed since this patch was written.")
        return source, False
    if source.count(old) > 1:
        print(f"  WARN: Anchor for '{name}' appears multiple times — patching first only.")
    print(f"  OK:   '{name}' applied.")
    return source.replace(old, new, 1), True

def main():
    if not os.path.exists(TARGET):
        print(f"Error: {TARGET} not found in current directory.")
        sys.exit(1)

    backup = TARGET + ".bak"
    shutil.copy2(TARGET, backup)
    print(f"Backup → {backup}\n")

    with open(TARGET, "r", encoding="utf-8") as f:
        source = f.read()

    all_ok = True
    source, ok = apply_patch(source, OLD_IMPORT,      NEW_IMPORT,      "Add UIKit import")
    all_ok = all_ok and ok
    source, ok = apply_patch(source, OLD_RETURN_BTN,  NEW_RETURN_BTN,  "Wire touch events + add animation methods")
    all_ok = all_ok and ok

    if not all_ok:
        print("\nOne or more patches failed. Original file unchanged.")
        print(f"Restore: cp {backup} {TARGET}")
        sys.exit(1)

    with open(TARGET, "w", encoding="utf-8") as f:
        f.write(source)

    print(f"\nAll patches applied to {TARGET}")

if __name__ == "__main__":
    main()
