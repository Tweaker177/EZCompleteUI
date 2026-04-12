# Split ViewController integration steps

This branch adds extracted files for the class/category pairs currently embedded in `ViewController.m`:

- `EZBubbleCell.h` / `EZBubbleCell.m`
- `EZSystemCell.h` / `EZSystemCell.m`
- `EZCodeBlockCell.h` / `EZCodeBlockCell.m`
- `EZModelPickerViewController.h` / `EZModelPickerViewController.m`
- `EZImageSettingsViewController.h` / `EZImageSettingsViewController.m`
- `ViewController+EZTitleFix.h` / `ViewController+EZTitleFix.m`

## Remaining required edits

### 1) Update imports at the top of `ViewController.m`
Add these imports near the existing imports:

```objc
#import "EZBubbleCell.h"
#import "EZSystemCell.h"
#import "EZCodeBlockCell.h"
#import "EZModelPickerViewController.h"
#import "EZImageSettingsViewController.h"
#import "ViewController+EZTitleFix.h"
```

### 2) Remove moved declarations/implementations from `ViewController.m`
Delete these embedded blocks from `ViewController.m` after the private `@interface ViewController () ... @end` block:

- `@interface EZBubbleCell ... @end`
- `@implementation EZBubbleCell ... @end`
- `@interface EZSystemCell ... @end`
- `@implementation EZSystemCell ... @end`
- `@interface EZCodeBlockCell ... @end`
- `@implementation EZCodeBlockCell ... @end`
- `@interface EZModelPickerViewController ... @end`
- `@implementation EZModelPickerViewController ... @end`
- `@interface EZImageSettingsViewController ... @end`
- `@implementation EZImageSettingsViewController ... @end`
- `@interface ViewController (EZTitleFix) ... @end`
- `@implementation ViewController (EZTitleFix) ... @end`

Do **not** remove:

- `@interface ViewController () ... @end`
- `@interface ViewController (EZPrivateForward) ... @end`
- `@implementation ViewController`

### 3) Update `Makefile`
Append the new implementation files to `EZCompleteUI_FILES`:

```make
EZBubbleCell.m EZSystemCell.m EZCodeBlockCell.m \
EZModelPickerViewController.m EZImageSettingsViewController.m \
ViewController+EZTitleFix.m
```

A good insertion point is immediately after `ViewController.m` in the current list.

## Sanity check

After the edits above, the build should still resolve these references from `ViewController.m`:

- `EZBubbleCell`
- `EZSystemCell`
- `EZCodeBlockCell`
- `EZModelPickerViewController`
- `EZImageSettingsViewController`
- `ViewController (EZTitleFix)`

## Note

The GitHub connector used here allowed clean branch creation and file creation, but not safe in-place modification of the existing tracked files without tree metadata. So this branch contains the extracted sources plus this exact integration checklist.
