//
//  EZCodeBlockCell.m
//  EZCompleteUI v1.2
//
//  Purpose: table view cell for a code block or generated file inside a chat
//  reply. Shows a language/kind label, the text in a monospaced scrollable
//  view, and Copy/Share buttons. Fed by ViewController's
//  processReplyWithCodeBlocks / addMessageSegments, which parse [CODE:...]
//  markers out of an AI reply — either a plain code snippet, or (since
//  ViewController.m v8.6) a real generated PDF/RTF/CSV file from an
//  EZPDF/EZDOCX/EZXCEL fence.
//
//  Changes from v1.1:
//   - Added inline preview for real generated files (PDF/RTF/CSV), same
//     pattern as EZMemoryCell in MemoriesViewController.m: a thumbnail
//     generated via QLThumbnailGenerator, a "tap to preview" badge shown
//     while it loads, and a tap on either opens QuickLook. Deliberately
//     scoped to the three real-file extensions this app currently
//     generates, not every savedPath — an ordinary .py/.js code snippet
//     also has a savedPath, and a thumbnail of code text is far less
//     useful than reading/copying it in _codeView, which is what that case
//     still does, unchanged.
//   - One deliberate deviation from the Memories version: its thumbnail
//     cache is keyed by row index, and its own changelog notes a real bug
//     that caused — thumbnails on the wrong row after a reload changed
//     sort order — needing an explicit cache-clear workaround. This cache
//     is keyed by file path instead (EZCodeBlockThumbCache, shared via
//     NSCache across all cell instances), which sidesteps that whole bug
//     class: a file's thumbnail is correct regardless of which row it
//     lands on or how many times the table reloads, no manual
//     invalidation needed. Also guards against the async thumbnail
//     callback landing on a cell that's since been reused for a different
//     file, by checking _savedPath still matches before applying the result.
//   - This cell is now its own QLPreviewControllerDataSource for its single
//     file, rather than reaching into ViewController's existing
//     previewURL/dataSource — keeps this class decoupled from
//     ViewController's interface (only .m was available, not .h).
//
//  Changes from v1.0:
//   - _copyTapped now copies the actual file data (with the correct UTI)
//     for PDF/RTF saved paths, instead of always copying _codeContent as a
//     string. For those two, _codeContent is a friendly placeholder
//     description ("PDF generated — use Share..."), not real text — the
//     old behavior meant tapping Copy on a generated PDF copied that
//     description sentence to the pasteboard, not anything useful. CSV
//     (and plain code snippets) are unaffected and still copy as text,
//     which is the actually-useful behavior for those — CSV content is
//     something you'd genuinely want to paste as text.
//   - Extracted the "flash the button to ✓ Copied! for 1.5s" logic, which
//     was duplicated inline, into _flashCopyConfirmation so both copy paths
//     share it instead of each having their own dispatch_after block.
//

#import "EZCodeBlockCell.h"
#import "helpers.h"
#import <QuickLook/QuickLook.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

NSNotificationName const EZCodeBlockEditingStateDidChangeNotification = @"EZCodeBlockEditingStateDidChangeNotification";

@interface EZCodeBlockCell () <QLPreviewControllerDataSource, UITextViewDelegate>
@end

// Shared across every cell instance, keyed by file path rather than row
// index. MemoriesViewController's own thumbCache is keyed by row index and
// its changelog notes a real bug that caused from that: thumbnails showing
// up on the wrong row after a reload changed sort order, needing an
// explicit cache-clear on every reload to work around it. Keying by path
// instead sidesteps that whole bug class — a given file's thumbnail is
// correct regardless of which row it ends up on, or how many times the
// table reloads, with no manual invalidation needed. NSCache (not a plain
// NSMutableDictionary) so the system can evict entries under memory
// pressure automatically.
static NSCache<NSString *, UIImage *> *EZCodeBlockThumbCache(void) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 100;
    });
    return cache;
}

@implementation EZCodeBlockCell {
    UILabel    *_langLabel;
    UIButton   *_lockBtn;
    UIButton   *_copyBtn;
    UIButton   *_shareBtn;
    UITextView *_codeView;
    NSLayoutConstraint *_codeHeightConstraint;
    NSString   *_codeContent;
    NSString   *_savedPath;
    __weak UIViewController *_vc;
    BOOL        _isEditingDocument;
    BOOL        _documentHasUnsavedChanges;

    // Inline preview — same pattern as EZMemoryCell in
    // MemoriesViewController.m: a badge shown while the async thumbnail
    // generates, replaced by the real thumbnail once ready, both tappable
    // to open QuickLook. Occupies the same space _codeView normally does;
    // exactly one of the two is visible at a time (toggled in configure).
    UIImageView *_thumbView;
    UIButton    *_thumbButton;
    UILabel     *_thumbBadge;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.selectionStyle  = UITableViewCellSelectionStyleNone;

    UIView *container          = [[UIView alloc] init];
    container.backgroundColor  = [UIColor colorWithWhite:0.12 alpha:1.0];
    container.layer.cornerRadius = 10;
    container.clipsToBounds    = YES;
    container.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    container.layer.borderWidth = 0.5;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:container];

    UIView *header              = [[UIView alloc] init];
    header.backgroundColor      = [UIColor colorWithWhite:0.18 alpha:1.0];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:header];

    _langLabel                  = [[UILabel alloc] init];
    _langLabel.font             = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    _langLabel.textColor        = [UIColor colorWithRed:0.6 green:0.8 blue:1.0 alpha:1.0];
    _langLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:_langLabel];

    // A compact lock makes a code block feel like a small, safe document:
    // locked = read/preview mode; unlocked = edit in place. Saving happens
    // when it is locked again or when editing ends.
    _lockBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *lockedImage = [UIImage systemImageNamed:@"lock.fill"];
    [_lockBtn setImage:lockedImage forState:UIControlStateNormal];
    // The deployed minimum is iOS 15, which has this symbol. Keep a text
    // fallback anyway so a missing/custom Symbol font never makes the action
    // appear to be absent.
    if (!lockedImage) [_lockBtn setTitle:@"Lock" forState:UIControlStateNormal];
    _lockBtn.tintColor = [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _lockBtn.accessibilityLabel = @"Unlock document for editing";
    _lockBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_lockBtn addTarget:self action:@selector(_lockTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:_lockBtn];

    // Share button 
    _shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_shareBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    _shareBtn.tintColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    _shareBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_shareBtn addTarget:self action:@selector(_shareTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:_shareBtn];

    _copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [_copyBtn setTitle:@"\u2398 Copy" forState:UIControlStateNormal];
    _copyBtn.tintColor          = [UIColor colorWithWhite:0.8 alpha:1.0];
    _copyBtn.titleLabel.font    = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _copyBtn.backgroundColor    = [UIColor colorWithWhite:0.28 alpha:1.0];
    _copyBtn.layer.cornerRadius = 5;
    _copyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_copyBtn addTarget:self action:@selector(_copyTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:_copyBtn];

    _codeView                       = [[UITextView alloc] init];
    _codeView.editable              = NO;
    _codeView.selectable            = YES;
    _codeView.delegate              = self;
    _codeView.backgroundColor       = [UIColor clearColor];
    _codeView.textColor             = [UIColor colorWithRed:0.85 green:0.95 blue:0.85 alpha:1.0];
    _codeView.font                  = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _codeView.textContainerInset    = UIEdgeInsetsMake(8, 10, 8, 10);
    // scrollEnabled=YES so content scrolls inside the fixed-height cell (original widget look)
    _codeView.scrollEnabled         = YES;
    _codeView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_codeView];

    // ── Inline preview (thumbnail + tap-to-QuickLook) ─────────────────────
    // Same footprint as _codeView — see the constraints block below, where
    // both share the exact same top/leading/trailing/height/bottom anchors.
    _thumbView = [[UIImageView alloc] init];
    _thumbView.translatesAutoresizingMaskIntoConstraints = NO;
    _thumbView.contentMode   = UIViewContentModeScaleAspectFit;
    _thumbView.clipsToBounds = YES;
    _thumbView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    _thumbView.hidden = YES;
    [container addSubview:_thumbView];

    _thumbButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _thumbButton.translatesAutoresizingMaskIntoConstraints = NO;
    _thumbButton.hidden = YES;
    [_thumbButton addTarget:self action:@selector(_previewTapped) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:_thumbButton];

    _thumbBadge = [[UILabel alloc] init];
    _thumbBadge.font              = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _thumbBadge.textColor         = [UIColor whiteColor];
    _thumbBadge.backgroundColor   = [UIColor systemTealColor];
    _thumbBadge.text              = @"  👁  Tap to preview  ";
    _thumbBadge.textAlignment     = NSTextAlignmentCenter;
    _thumbBadge.layer.cornerRadius = 8;
    _thumbBadge.clipsToBounds     = YES;
    _thumbBadge.hidden            = YES;
    _thumbBadge.userInteractionEnabled = YES;
    _thumbBadge.translatesAutoresizingMaskIntoConstraints = NO;
    UITapGestureRecognizer *badgeTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(_previewTapped)];
    [_thumbBadge addGestureRecognizer:badgeTap];
    [container addSubview:_thumbBadge];

    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor      constraintEqualToAnchor:self.contentView.topAnchor      constant:4],
        [container.bottomAnchor   constraintEqualToAnchor:self.contentView.bottomAnchor   constant:-4],
        [container.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor  constant:8],
        [container.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],

        [header.topAnchor      constraintEqualToAnchor:container.topAnchor],
        [header.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [header.heightAnchor   constraintEqualToConstant:36],

        [_langLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:12],
        [_langLabel.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],

        [_shareBtn.trailingAnchor  constraintEqualToAnchor:header.trailingAnchor constant:-8],
        [_shareBtn.centerYAnchor   constraintEqualToAnchor:header.centerYAnchor],
        [_shareBtn.widthAnchor     constraintEqualToConstant:30],
        [_shareBtn.heightAnchor    constraintEqualToConstant:30],

        [_copyBtn.trailingAnchor constraintEqualToAnchor:_shareBtn.leadingAnchor constant:-6],
        [_copyBtn.centerYAnchor  constraintEqualToAnchor:header.centerYAnchor],
        [_copyBtn.widthAnchor    constraintEqualToConstant:72],
        [_copyBtn.heightAnchor   constraintEqualToConstant:26],

        [_lockBtn.trailingAnchor constraintEqualToAnchor:_copyBtn.leadingAnchor constant:-6],
        [_lockBtn.centerYAnchor  constraintEqualToAnchor:header.centerYAnchor],
        [_lockBtn.widthAnchor    constraintEqualToConstant:30],
        [_lockBtn.heightAnchor   constraintEqualToConstant:30],

        [_codeView.topAnchor      constraintEqualToAnchor:header.bottomAnchor],
        [_codeView.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor],
        [_codeView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        // Fixed height ~1/3 screen so the cell stays compact and content scrolls inside.
        // Container bottom is driven by this height rather than expanding to content.
        (_codeHeightConstraint = [_codeView.heightAnchor constraintEqualToConstant:
            MAX(120.0, UIScreen.mainScreen.bounds.size.height / 3.0)]),
        [_codeView.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor],

        // Thumbnail / button / badge share _codeView's exact footprint —
        // exactly one of _codeView / _thumbView+badge is visible at a time.
        [_thumbView.topAnchor      constraintEqualToAnchor:_codeView.topAnchor],
        [_thumbView.leadingAnchor  constraintEqualToAnchor:_codeView.leadingAnchor],
        [_thumbView.trailingAnchor constraintEqualToAnchor:_codeView.trailingAnchor],
        [_thumbView.bottomAnchor   constraintEqualToAnchor:_codeView.bottomAnchor],

        [_thumbButton.topAnchor      constraintEqualToAnchor:_thumbView.topAnchor],
        [_thumbButton.bottomAnchor   constraintEqualToAnchor:_thumbView.bottomAnchor],
        [_thumbButton.leadingAnchor  constraintEqualToAnchor:_thumbView.leadingAnchor],
        [_thumbButton.trailingAnchor constraintEqualToAnchor:_thumbView.trailingAnchor],

        [_thumbBadge.centerXAnchor  constraintEqualToAnchor:_codeView.centerXAnchor],
        [_thumbBadge.centerYAnchor  constraintEqualToAnchor:_codeView.centerYAnchor],
        [_thumbBadge.heightAnchor   constraintEqualToConstant:34],
    ]];
    return self;
}

- (void)prepareForReuse {
    [self _saveEditedDocumentIfNeeded];
    if (_isEditingDocument) [self _postEditingState:NO];
    [super prepareForReuse];
    _isEditingDocument = NO;
    _documentHasUnsavedChanges = NO;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    // A chat reload, navigation change, or dismissal can remove a cell before
    // the person taps its lock again. Persist any outstanding change on exit.
    if (!self.window) {
        [self _saveEditedDocumentIfNeeded];
        if (_isEditingDocument) [self _postEditingState:NO];
    }
}

- (void)configureWithCode:(NSString *)code language:(NSString *)language
               savedPath:(NSString *)savedPath viewController:(__weak UIViewController *)vc {
    _codeContent        = code;
    _savedPath          = savedPath;
    _vc                 = vc;
    _langLabel.text     = language.length > 0 ? language.uppercaseString : @"CODE";
    _isEditingDocument = NO;
    _documentHasUnsavedChanges = NO;
    _codeView.editable = NO;
    [self _setDocumentEditorAppearance:NO];
    [_lockBtn setImage:[UIImage systemImageNamed:@"lock.fill"] forState:UIControlStateNormal];
    _lockBtn.accessibilityLabel = @"Unlock document for editing";

    // A prior inline edit belongs to the existing attachment, not merely the
    // transient chat-cell string. Prefer the saved file when it is plain text
    // so edits remain visible after reload, scrolling, and thread restore.
    NSString *savedText = [self _plainTextFromSavedFile];
    _codeView.text = savedText ?: code;

    // Short snippets should read like compact chat content rather than a
    // full-screen terminal. Longer snippets retain the scrollable 1/3-screen
    // editor, while fewer than 12 source lines use roughly half that height.
    NSArray<NSString *> *lines = [_codeView.text componentsSeparatedByString:@"\n"];
    NSUInteger lineCount = lines.count;
    if (lineCount > 1 && [lines.lastObject length] == 0) lineCount--;
    CGFloat normalHeight = MAX(120.0, UIScreen.mainScreen.bounds.size.height / 3.0);
    CGFloat compactHeight = MAX(80.0, UIScreen.mainScreen.bounds.size.height / 6.0);
    _codeHeightConstraint.constant = lineCount < 12 ? compactHeight : normalHeight;

    // Reset preview state on every configure — cells get reused, so a
    // previous row's thumbnail/badge state must never leak into this one.
    _thumbView.image     = nil;
    _thumbView.hidden    = YES;
    _thumbButton.hidden  = YES;
    _thumbBadge.hidden   = YES;
    _codeView.hidden     = NO;

    // Only real generated files get the inline-preview treatment, not
    // ordinary code snippets — a plain .py/.js/.swift snippet also gets a
    // savedPath (see processReplyWithCodeBlocks), but a thumbnail of code
    // text is far less useful than actually reading/copying it in
    // _codeView, which is what that case already does well. Scoped
    // specifically to the three real-file formats ViewController.m
    // currently generates (EZPDF/EZDOCX/EZXCEL fences) — extend this set
    // if more real-file formats get added later.
    static NSSet<NSString *> *previewableExts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        previewableExts = [NSSet setWithObjects:@"pdf", @"rtf", @"csv", nil];
    });
    NSString *ext = [savedPath.pathExtension lowercaseString];
    BOOL hasSavedFile = savedPath.length > 0
        && [[NSFileManager defaultManager] fileExistsAtPath:savedPath];
    BOOL isPreviewable = hasSavedFile && [previewableExts containsObject:ext];
    _lockBtn.hidden = ![self _canEditDocument];
    if (!isPreviewable) return;

    _codeView.hidden = YES;
    UIImage *cached = [EZCodeBlockThumbCache() objectForKey:savedPath];
    if (cached) {
        [self _showThumbnail:cached];
    } else {
        _thumbBadge.hidden = NO;
        [self _generateThumbnailForPath:savedPath];
    }
}

// MARK: - Inline document editing

- (BOOL)_isRTFDocument {
    return [[_savedPath.pathExtension lowercaseString] isEqualToString:@"rtf"];
}

- (BOOL)_canEditDocument {
    // PDF is intentionally preview/share-only. CSV, RTF, and the text code
    // files produced by this cell can round-trip through UITextView safely.
    NSString *extension = _savedPath.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"pdf"]) return NO;

    if (_savedPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:_savedPath]) return YES;

    // A code cell may be restored from its transcript before its attachment
    // path is available (or a previous file write may have failed). The text
    // in the cell is still enough to recreate a safe editable source file.
    // RTF cannot be reconstructed from its human-readable placeholder, but
    // ordinary code and CSV can.
    return _codeContent.length > 0 && ![extension isEqualToString:@"rtf"];
}

- (BOOL)_ensureEditableBackingFile {
    if (_savedPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:_savedPath]) return YES;
    if (_codeContent.length == 0 || [self _isRTFDocument]) return NO;

    NSString *extension = _savedPath.pathExtension.lowercaseString;
    if (extension.length == 0) extension = @"txt";
    NSString *fileName = [NSString stringWithFormat:@"code-%@.%@",
                          NSUUID.UUID.UUIDString, extension];
    NSString *recreatedPath = EZAttachmentSave([_codeContent dataUsingEncoding:NSUTF8StringEncoding], fileName);
    if (!recreatedPath) return NO;
    _savedPath = recreatedPath;
    return YES;
}

- (NSString *)_plainTextFromSavedFile {
    if (![self _canEditDocument] || [self _isRTFDocument] || _savedPath.length == 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:_savedPath]) return nil;
    NSData *data = [NSData dataWithContentsOfFile:_savedPath];
    return data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

- (BOOL)_loadDocumentIntoEditor {
    if (![self _canEditDocument] || ![self _ensureEditableBackingFile]) return NO;
    if ([self _isRTFDocument]) {
        NSError *error = nil;
        NSData *rtfData = [NSData dataWithContentsOfFile:_savedPath];
        NSAttributedString *document = [[NSAttributedString alloc]
            initWithData:rtfData
                 options:@{ NSDocumentTypeDocumentAttribute: NSRTFTextDocumentType }
          documentAttributes:nil error:&error];
        if (!document || error) return NO;
        _codeView.attributedText = document;
        return YES;
    }

    NSString *text = [self _plainTextFromSavedFile];
    if (!text) return NO;
    _codeView.text = text;
    return YES;
}

- (void)_lockTapped {
    if (_isEditingDocument) {
        [self _finishDocumentEditing];
    } else {
        [self _beginDocumentEditing];
    }
}

- (void)_beginDocumentEditing {
    if (![self _canEditDocument] || ![self _loadDocumentIntoEditor]) return;

    _isEditingDocument = YES;
    _documentHasUnsavedChanges = NO;
    _thumbView.hidden = YES;
    _thumbButton.hidden = YES;
    _thumbBadge.hidden = YES;
    _codeView.hidden = NO;
    _codeView.editable = YES;
    _codeView.selectable = YES;
    [self _setDocumentEditorAppearance:YES];
    [_lockBtn setImage:[UIImage systemImageNamed:@"lock.open.fill"] forState:UIControlStateNormal];
    _lockBtn.accessibilityLabel = @"Save changes and lock document";
    [self _postEditingState:YES];
    [_codeView becomeFirstResponder];
}

- (void)_finishDocumentEditing {
    [self _saveEditedDocumentIfNeeded];
    _isEditingDocument = NO;
    _codeView.editable = NO;
    [_codeView resignFirstResponder];
    [self _setDocumentEditorAppearance:NO];
    [_lockBtn setImage:[UIImage systemImageNamed:@"lock.fill"] forState:UIControlStateNormal];
    _lockBtn.accessibilityLabel = @"Unlock document for editing";
    [self _postEditingState:NO];

    // Restore the rich-file preview after saving and invalidate its cached
    // thumbnail so Quick Look represents the newly written RTF/CSV bytes.
    NSString *ext = [_savedPath.pathExtension lowercaseString];
    if ([ext isEqualToString:@"rtf"] || [ext isEqualToString:@"csv"]) {
        [EZCodeBlockThumbCache() removeObjectForKey:_savedPath];
        _codeView.hidden = YES;
        _thumbView.image = nil;
        _thumbView.hidden = YES;
        _thumbButton.hidden = YES;
        _thumbBadge.hidden = NO;
        [self _generateThumbnailForPath:_savedPath];
    }
}

- (void)_saveEditedDocumentIfNeeded {
    if (!_documentHasUnsavedChanges || ![self _canEditDocument]) return;

    NSData *data = nil;
    NSError *error = nil;
    if ([self _isRTFDocument]) {
        data = [_codeView.attributedText dataFromRange:NSMakeRange(0, _codeView.attributedText.length)
                                    documentAttributes:@{ NSDocumentTypeDocumentAttribute: NSRTFTextDocumentType }
                                                 error:&error];
    } else {
        _codeContent = _codeView.text ?: @"";
        data = [_codeContent dataUsingEncoding:NSUTF8StringEncoding];
    }

    if (data.length && [data writeToFile:_savedPath options:NSDataWritingAtomic error:&error]) {
        _documentHasUnsavedChanges = NO;
        return;
    }
    NSLog(@"[EZCodeBlockCell] Could not save edited document %@: %@", _savedPath, error.localizedDescription);
}

- (void)textViewDidChange:(UITextView *)textView {
    if (textView == _codeView && _isEditingDocument) _documentHasUnsavedChanges = YES;
}

- (void)textViewDidEndEditing:(UITextView *)textView {
    if (textView == _codeView && _isEditingDocument) [self _saveEditedDocumentIfNeeded];
}

- (void)_setDocumentEditorAppearance:(BOOL)editing {
    // The rest of the app intentionally stays dark. A document editor is the
    // exception: user text must remain legible while the insertion cursor and
    // keyboard are active.
    _codeView.backgroundColor = editing ? [UIColor whiteColor] : [UIColor clearColor];
    _codeView.textColor = editing ? [UIColor blackColor]
                                  : [UIColor colorWithRed:0.85 green:0.95 blue:0.85 alpha:1.0];
    _codeView.tintColor = editing ? [UIColor systemGreenColor]
                                  : [UIColor colorWithRed:0.05 green:0.92 blue:0.72 alpha:1.0];
    _codeView.keyboardAppearance = editing ? UIKeyboardAppearanceLight : UIKeyboardAppearanceDark;
}

- (void)_postEditingState:(BOOL)editing {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:EZCodeBlockEditingStateDidChangeNotification
                      object:self
                    userInfo:@{ @"editing": @(editing) }];
}

/// Same QLThumbnailGenerator call as MemoriesViewController's
/// generateThumbnailsIfNeeded, adapted to a single cell/path rather than a
/// whole table pass. Deliberately keyed and cached by file path (see
/// EZCodeBlockThumbCache's own comment) rather than row index.
- (void)_generateThumbnailForPath:(NSString *)path {
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc]
        initWithFileAtURL:fileURL
                     size:CGSizeMake(600, 360)
                    scale:[UIScreen mainScreen].scale
      representationTypes:QLThumbnailGenerationRequestRepresentationTypeAll];

    __weak typeof(self) weakSelf = self;
    [QLThumbnailGenerator.sharedGenerator
        generateRepresentationsForRequest:req
        updateHandler:^(QLThumbnailRepresentation *thumb,
                        QLThumbnailRepresentationType type,
                        NSError *error) {
        UIImage *img = thumb.UIImage;
        if (!img || error) return;
        [EZCodeBlockThumbCache() setObject:img forKey:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            // Guard against cell reuse: this cell may have been dequeued
            // for a different row/file by the time this async callback
            // fires. Only apply the result if we're still showing the same
            // path we requested a thumbnail for.
            if (![strongSelf->_savedPath isEqualToString:path]) return;
            [strongSelf _showThumbnail:img];
        });
    }];
}

- (void)_showThumbnail:(UIImage *)image {
    _thumbView.image    = image;
    _thumbView.hidden   = NO;
    _thumbButton.hidden = NO;
    _thumbBadge.hidden  = YES;
}

- (void)_previewTapped {
    if (!_vc || !_savedPath.length) return;
    if (![[NSFileManager defaultManager] fileExistsAtPath:_savedPath]) return;
    QLPreviewController *ql = [[QLPreviewController alloc] init];
    ql.dataSource = self;
    [_vc presentViewController:ql animated:YES completion:nil];
}

// ── QLPreviewControllerDataSource ───────────────────────────────────────────
- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return 1;
}
- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller
                    previewItemAtIndex:(NSInteger)index {
    return [NSURL fileURLWithPath:_savedPath];
}

- (void)_copyTapped {
    NSString *pathExt = [_savedPath.pathExtension lowercaseString];
    BOOL hasSavedFile = _savedPath.length > 0
        && [[NSFileManager defaultManager] fileExistsAtPath:_savedPath];

    // PDF/RTF saved paths are real generated files (EZPDF/EZDOCX fences,
    // ViewController.m v8.6) — _codeContent for these is just a friendly
    // placeholder description, not real text worth copying. Copy the
    // actual file data instead, tagged with the right UTI, so pasting into
    // Files/Mail/Messages etc. pastes the real file rather than a sentence
    // describing it. CSV falls through to the text-copy path below on
    // purpose — CSV content is genuinely useful to copy as plain text.
    if (hasSavedFile && ([pathExt isEqualToString:@"pdf"] || [pathExt isEqualToString:@"rtf"])) {
        NSData *fileData = [NSData dataWithContentsOfFile:_savedPath];
        if (fileData) {
            NSString *uti = [pathExt isEqualToString:@"pdf"] ? @"com.adobe.pdf" : @"public.rtf";
            [[UIPasteboard generalPasteboard] setItems:@[@{ uti: fileData }]];
            [self _flashCopyConfirmation];
            return;
        }
        // Fall through to the text-copy path below if the file couldn't be
        // read — better to copy the placeholder description than nothing.
    }

    if (!_codeContent.length) return;
    [UIPasteboard generalPasteboard].string = _codeContent;
    [self _flashCopyConfirmation];
}

- (void)_flashCopyConfirmation {
    NSString *orig = [_copyBtn titleForState:UIControlStateNormal];
    [_copyBtn setTitle:@"✓ Copied!" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self->_copyBtn setTitle:orig forState:UIControlStateNormal]; });
}

- (void)_shareTapped {
    NSMutableArray *items = [NSMutableArray array];
    if (_savedPath.length && [[NSFileManager defaultManager] fileExistsAtPath:_savedPath]) {
        [items addObject:[NSURL fileURLWithPath:_savedPath]];
    } else if (_codeContent.length) {
        [items addObject:_codeContent];
    }
    if (!items.count) return;

    // A document can be tapped just as its chat cell is being recycled or
    // while the controller is dismissing. Presenting from such a controller
    // is a common source of share-sheet crashes/warnings on older iOS. Take a
    // strong snapshot and validate it again on the main queue.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        UIViewController *presenter = self->_vc;
        if (!presenter || !presenter.viewIfLoaded.window ||
            presenter.isBeingDismissed || presenter.isBeingPresented) return;

        UIActivityViewController *av = [[UIActivityViewController alloc]
            initWithActivityItems:items applicationActivities:nil];
        if (av.popoverPresentationController) {
            av.popoverPresentationController.sourceView = self->_shareBtn;
            av.popoverPresentationController.sourceRect = self->_shareBtn.bounds;
        }
        [presenter presentViewController:av animated:YES completion:nil];
    });
}
@end
