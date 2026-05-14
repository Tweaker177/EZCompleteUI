// ViewController.m
// EZCompleteUI v7.2
//
// Changes from v7.1:
//   - Fixed: tapping Send while keyboard is visible caused first tap to dismiss
//     keyboard but not send. Root cause: the view-wide UITapGestureRecognizer
//     (dismissTap) was firing on the same touch as the send button, starting a
//     keyboard-hide layout animation that repositioned the inputContainer mid-
//     touch, causing UIKit to cancel the button's touchUpInside before it fired.
//   - Fix: ViewController now adopts UIGestureRecognizerDelegate and implements
//     gestureRecognizer:shouldReceiveTouch: to return NO when the touch lands on
//     any UIControl (button, switch, etc.). The dismissTap gesture is therefore
//     skipped entirely on button taps — no animation race, send always fires.
//   - dismissTap.delegate = self wired in setupUI.
//
// Changes from v7.1:
//   - TTS now routed through ez-elevenlabs Supabase edge function (server-side
//     ElevenLabs key via Supabase secret) instead of the user's own API key.
//     Coins are deducted server-side at 1 coin per 50 chars (rounded up).
//   - speakLastResponse: responses > 160 chars now show a UIAlertController
//     warning with estimated coin cost, offering: Use ElevenLabs, Use Apple
//     TTS (free), or Don't Read — prevents accidentally reading huge responses.
//   - Insufficient-coins response (HTTP 402) from edge function shows its own
//     alert: Apple TTS fallback or Get Coins (opens coin store).
//   - All ElevenLabs error paths fall back to Apple TTS with a chat notice.
//   - Coin balance display is refreshed after a successful TTS call.
//   - Old direct-to-ElevenLabs code (user API key path) commented out, not
//     deleted, in case user keys need to be restored in the future.
//   - Added #import "EZAuthManager.h" for JWT access ([EZAuthManager shared].accessToken).
//
// Changes from v6.9:
//   - handleSend now disables send button and shows user bubble IMMEDIATELY on
//     tap, before any entitlement check or API call — eliminates the visible
//     delay where text sat in the input field doing nothing
//   - Same early UI commit (clear field, dismiss keyboard) now applies to all
//     model types: chat, image, sora — previously only chat got it synchronously
//   - Duplicate-send bug fixed: send button is disabled at the very top of
//     handleSend, so rapid taps during the async entitlement network round-trip
//     can no longer queue up extra calls
//   - handleSendAuthorized: removed redundant appendToChat/endEditing/setInputText
//     (already done in handleSend); chatContext addObject kept since it still
//     needs the fully-assembled fullPrompt (with file context injected)
//   - Removed two redundant sendButton.enabled = NO lines in handleSendAuthorized
//     (image intent path and chat path) — button is already disabled on entry
//   - handleAPIError now re-enables send button on main thread so any API failure
//     path correctly unlocks the button
//   - Both entitlement-denied blocks in handleSend now re-enable send button
//     before showing the error/coin-store so user can retry
//   - No-API-key early return in handleSendAuthorized re-enables send button
//   - callImageEdit early-exit guards (no path, bad data, decode fail, PNG fail)
//     all re-enable send button before returning
//
// Changes from v6.7:
//   - Fixed: stale lastImageLocalPath no longer injected into unrelated memory entries
//     Root cause: chatContext scan for _isVisionAttachment was permanently sticky after
//     the first image send; replaced with pendingImagePath check (this-turn-only signal)
//   - Fixed same bug in direct-answer (Tier 1) memory path — same stale injection removed
//   - pendingImagePath now cleared immediately after capture in both memory paths
//
// Changes from v6.6:
//   - GPT-5 timeout increased (180s solo, 240s with web search)
//   - Web search now silently skipped with warning for incompatible models
//   - Copy button shows checkmark confirmation for 1.5s
//   - Language→extension map fixed for objective-c/objc variants + normalization
//   - Image display intent detection: "show it again" reopens instead of regenerating
//   - attachmentPaths now always includes lastImageLocalPath + pendingImagePath
//   - Code block detection: extracts ```, saves to EZAttachments, renders inline widget
//   - processReplyWithCodeBlocks: saves snippets, returns display string with placeholders
//   - sanitizedContextForAPI: converts image/text block types for Responses vs Chat API
//   - ElevenLabs + Whisper keys now stored via EZKeyVault (Keychain), not NSUserDefaults
//   - URLs in AI responses are now tappable (dataDetectorTypes) with styled link appearance
//   - checkReplyForLocalFilePaths regex broadened to /var/mobile/ prefix + any extension
//   - Bubble chat UI: UITableView replaces UITextView; user (blue, right) and
//     assistant (gray, left) message bubbles with iMessage-style tail corners
//   - Code blocks rendered as EZCodeBlockCell with Copy + Share buttons
//   - Thread title now set from attachment filename when attachment is first action
//   - Sora: video deferred to pendingVideoURL when app is backgrounded, presented on foreground
//
// Changes from v6.5 / v6.6:
//   - Code blocks fixed at ~1/3 screen height with internal scrolling (restored original look)
//   - Spurious attachment bug fixed: lastImageLocalPath/pendingImagePath no longer blindly
//     injected into every chat completion's captured attachments
//   - gpt-image-1 models expanded: gpt-image-1.5, gpt-image-1-mini, chatgpt-image-latest
//   - Image generation settings: quality, size, output_format, background, moderation
//     stored in NSUserDefaults; showImageSettings sheet from model button when image model active

#import "ViewController.h"
#import "SettingsViewController.h"
#import "ChatHistoryViewController.h"
#import "helpers.h"
#import "EZKeyVault.h"
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuickLook/QuickLook.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <PDFKit/PDFKit.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <QuartzCore/QuartzCore.h>
#import "SidewaysScrollView.h"
#import "EZModelPickerViewController.h"
#import "EZImageSettingsViewController.h"
#import "EZAttachMenuViewController.h"
#import "ViewController+EZKeepAwake.h"
#import "ElevenLabsCloneViewController.h"
#import "EZCoinStoreViewController.h"
#import "EZPhotoGalleryViewController.h"
#import "EZCoinPotView.h"
#import "TextToSpeechViewController.h"
#import "MemoriesViewController.h"
#import "SupportRequestViewController.h"
#import "BrainRotViewController.h"
#import "EZBubbleCell.h"
#import "EZSystemCell.h"
#import "EZCodeBlockCell.h"
#import "EZImageGridCell.h"
#import "EZEntitlementManager.h"
#import "EZAuthManager.h"         // needed for [EZAuthManager shared].accessToken (edge function JWT)
#import "HelperLogViewController.h"



typedef NS_ENUM(NSInteger, EZAttachMode) {
    EZAttachModeNone,
    EZAttachModeWhisper,
    EZAttachModeAnalyze,
};

@interface ViewController () <UIDocumentPickerDelegate,
                               UITextFieldDelegate,
                               UITextViewDelegate,
                               UITableViewDataSource,
                               UITableViewDelegate,
                               QLPreviewControllerDataSource,
                               PHPickerViewControllerDelegate,
                               SFSpeechRecognizerDelegate,
                               UIGestureRecognizerDelegate,
                               ChatHistoryViewControllerDelegate>




// UI
/// UITableView that renders all chat messages as bubble / system / code cells.
//@property (nonatomic, strong) UITableView   *chatTableView;
/// Flat array of display-message dicts driving chatTableView.
/// Keys: role (@"user"|@"assistant"|@"system"|@"code"), text, language, savedPath.
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *displayMessages;
@property (nonatomic, strong) UIView        *inputContainer;
@property (nonatomic, strong) UITextView    *messageTextField;  // was UITextField; now expanding UITextView
@property (nonatomic, strong) UIButton      *sendButton;
@property (nonatomic, strong) UIButton      *modelButton;
@property (nonatomic, strong) UIButton      *attachButton;
@property (nonatomic, strong) UIButton      *settingsButton;
@property (nonatomic, strong) UIButton      *clipboardButton;
@property (nonatomic, strong) UIButton      *speakButton;
@property (nonatomic, strong) UIButton      *clearButton;
/// Appears in input area when an image model is active — opens image parameter sheet.
@property (nonatomic, strong) UIButton      *imageSettingsButton;
@property (nonatomic, strong) UIButton      *dictateButton;
@property (nonatomic, strong) UIButton      *webSearchButton;
@property (nonatomic, strong) UIButton      *historyButton;
@property (nonatomic, strong) UIButton      *addChatButton;
@property (nonatomic, strong) UIButton      *memoriesButton;
@property (nonatomic, strong) UIButton      *supportRequestButton;
@property (nonatomic, strong) UIButton      *textToSpeechButton;
@property (nonatomic, strong) UIButton      *cloningButton;
@property (nonatomic, strong) UIButton      *galleryButton;
@property (nonatomic, strong) UIButton      *brainRotButton;
//@property (nonatomic, strong) UIButton      *textToSpeechButton;

@property (nonatomic, strong) NSLayoutConstraint *containerBottomConstraint;
/// Height constraint on the message input view — animated on focus/blur.
@property (nonatomic, strong) NSLayoutConstraint *messageInputHeightConstraint;
/// Tappable label showing the active thread title — tap to rename.

/// Button in top bar that triggers renaming.
@property (nonatomic, strong) UIButton      *renameButton;

// State
@property (nonatomic, strong) NSArray       *models;
@property (nonatomic, strong) NSString      *selectedModel;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *chatContext;
@property (nonatomic, assign) BOOL          webSearchEnabled;

// Active thread
@property (nonatomic, strong) EZChatThread  *activeThread;

// Media / file state
@property (nonatomic, strong) NSURL         *previewURL;
/// Non-nil when a Sora video completed while the app was backgrounded.
/// Presented the next time the view becomes visible.
@property (nonatomic, strong) NSURL         *pendingVideoURL;
@property (nonatomic, strong) NSString      *pendingFileContext;   // text extracted from file
@property (nonatomic, strong) NSString      *pendingFileName;
@property (nonatomic, strong) NSString      *pendingImagePath;     // local path of attached image
@property (nonatomic, strong) NSString      *lastImagePrompt;      // last DALL-E prompt (for follow-ups)
@property (nonatomic, strong) NSString      *lastVideoPrompt;      // last Sora prompt (for memory indexing)
@property (nonatomic, strong) NSString      *lastImageLocalPath;   // local path of last generated image

// TTS / audio
@property (nonatomic, strong) AVSpeechSynthesizer *speechSynthesizer;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSString      *lastAIResponse;
@property (nonatomic, strong) NSString      *lastUserPrompt;

// Dictation
@property (nonatomic, strong) SFSpeechRecognizer               *speechRecognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *recognitionRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask          *recognitionTask;
@property (nonatomic, strong) AVAudioEngine                    *audioEngine;
@property (nonatomic, assign) BOOL                              isDictating;


    // Sideways-scrolling top-row container (inserted)
    @property (nonatomic, strong) UIView *topButtonsContainer;
    @property (nonatomic, strong) SidewaysScrollView *sidewaysScrollView;
@property (nonatomic, strong) UIView        *statusBannerView;
@property (nonatomic, strong) UILabel       *statusBannerLabel;
@property (nonatomic, strong) UIActivityIndicatorView *statusBannerSpinner;
@property (nonatomic, strong) NSTimer       *statusBannerTimer;
@property (nonatomic, assign) NSInteger      statusBannerPhase;
- (void)setupKeyboardObservers;

// History drawer (slide-in panel from left)
@property (nonatomic, strong) UIView                 *drawerContainerView;
@property (nonatomic, strong) UIView                 *drawerDimView;
@property (nonatomic, strong) UINavigationController *drawerNavController;
@property (nonatomic, strong) NSLayoutConstraint     *drawerLeadingConstraint;
@property (nonatomic, assign) BOOL                    drawerOpen;

// Memories drawer (slide-in panel from right)
@property (nonatomic, strong) UIView                 *memoriesDrawerContainerView;
@property (nonatomic, strong) UIView                 *memoriesDrawerDimView;
@property (nonatomic, strong) UINavigationController *memoriesDrawerNavController;
@property (nonatomic, strong) NSLayoutConstraint     *memoriesDrawerTrailingConstraint;
@property (nonatomic, assign) BOOL                    memoriesDrawerOpen;
@property (nonatomic, strong) UILabel *coinBalanceLabel; // kept for compatibility
@property (nonatomic, strong) EZCoinPotView *coinPotView;

@end
@interface ViewController (EZPrivateForward)
- (void)scrollChatToBottom;
- (void)transcribeAudio:(NSURL *)fileURL;
- (BOOL)isGptImage1Family:(NSString *)model;
- (void)analyzeFile:(NSURL *)fileURL;
- (void)setupKeyboardObservers;
- (void)closeDrawer;
@end

@implementation ViewController

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];

   
    EZLogRotateIfNeeded(512 * 1024);
    EZLog(EZLogLevelInfo, @"APP", @"EZCompleteUI v7.2 viewDidLoad");
    [self setupData];
    [self setupUI];
    [self setupKeyboardObservers];
    [self setupDictation];
    [self requestSpeechPermissionsIfNeeded];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(resumePendingSoraJobIfNeeded)
        name:@"EZAppDidBecomeActive" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleOpenChatThread:)
        name:@"EZOpenChatThread" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleSubscriptionUpdated)
        name:@"EZSubscriptionUpdated" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleAttachImageToChat:)
        name:EZAttachImageToChat object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleEditImageInChat:)
        name:EZEditImageInChat object:nil];
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        [self updateCoinBalanceDisplay];
    }];

}

- (void)setupData {
    // Model list — internal identifiers. Display labels added in showModelPicker.
    //added several gpt 5 models that are new, need to check any other references to gpt 5 includes them
    self.models = @[
           // ── Chat / Reasoning ──────────────────────────────────────────────
           @"gpt-5-pro", @"gpt-5", @"gpt-5-mini",
           @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4",
           @"gpt-3.5-turbo",
           // ── Image Generation & Edit ───────────────────────────────────────
           @"gpt-image-1.5",        // newest image model
           @"gpt-image-1",          // generation + edit
           @"gpt-image-1-mini",     // faster/cheaper image generation
           @"chatgpt-image-latest", // always points to current ChatGPT image model
           @"dall-e-3",             // generation only (legacy)
        // ── Video ─────────────────────────────────────────────────────────
        @"sora-2", @"sora-2-pro",
        // ── Audio ─────────────────────────────────────────────────────────
        @"whisper-1"
    ];
    self.chatContext        = [NSMutableArray array];
    self.displayMessages    = [NSMutableArray array];
    self.speechSynthesizer = [[AVSpeechSynthesizer alloc] init];
    self.selectedModel     = [[NSUserDefaults standardUserDefaults] stringForKey:@"selectedModel"]
                             ?: self.models[0];
    self.webSearchEnabled  = [[NSUserDefaults standardUserDefaults] boolForKey:@"webSearchEnabled"];

    // Set a sensible default system message if the user hasn't configured one yet.
    // This avoids the model claiming it "can't" do things it absolutely can.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults stringForKey:@"systemMessage"].length) {
        [defaults setObject:
            @"You are a capable AI assistant with access to the user's conversation history and memories. "
             "When the user references a previous file, image, or conversation, use the context provided. "
             "When providing code, always do so inside a codeblock, with the language and filename(or snippet name),"
              "as that will both create a code block and a new file the user can export."
             "You can display images by providing their exact local file path starting with \"EZPrefix/\". "
             "Be direct, specific and concise in responses, unless directed otherwise."
                     forKey:@"systemMessage"];
    }

    // Restore persisted image/attachment paths so they survive app restarts.
    // This is the key fix for "reopen image" failing — lastImageLocalPath was
    // always nil after relaunch, so the intent check fell through to generation.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *savedImagePath = [d stringForKey:@"lastImageLocalPath"];
    if (savedImagePath.length > 0 &&
        [[NSFileManager defaultManager] fileExistsAtPath:savedImagePath]) {
        self.lastImageLocalPath = savedImagePath;
        EZLogf(EZLogLevelInfo, @"APP", @"Restored lastImageLocalPath: %@",
               savedImagePath.lastPathComponent);
    }
    NSString *savedPrompt = [d stringForKey:@"lastImagePrompt"];
    if (savedPrompt.length > 0) {
        self.lastImagePrompt = savedPrompt;
    }

    [self startNewThread];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Thread Management
// ─────────────────────────────────────────────────────────────────────────────

- (void)startNewThread {
    EZChatThread *t = [[EZChatThread alloc] init];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat       = @"yyyy-MM-dd'T'HH:mm:ss";
    fmt.locale           = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    t.threadID           = [fmt stringFromDate:[NSDate date]];
    t.modelName          = self.selectedModel;
    t.chatContext        = @[];
    t.attachmentPaths    = @[];
    self.activeThread    = t;
    EZLogf(EZLogLevelInfo, @"THREAD", @"New thread: %@", t.threadID);
}

- (void)saveActiveThread {
    if (!self.activeThread || self.chatContext.count == 0) return;

    // Sync chatContext into thread before saving
    self.activeThread.chatContext = [self.chatContext copy];
    self.activeThread.modelName   = self.selectedModel;

    // Set title from first user message if not set.
    // Strip Tier-3 context preamble if present — we want the raw user question, not the injected context.
    if ([self.activeThread.title isEqualToString:@"New Conversation"] ||
        self.activeThread.title.length == 0) {
        for (NSDictionary *msg in self.chatContext) {
            if ([msg[@"role"] isEqualToString:@"user"]) {
                id content = msg[@"content"];
                NSString *text = @"";

                if ([content isKindOfClass:[NSString class]]) {
                    text = content;
                } else if ([content isKindOfClass:[NSArray class]]) {
                    // Vision attachment: extract text block, or fall back to filename
                    for (NSDictionary *block in (NSArray *)content) {
                        NSString *t = block[@"text"];
                        if (t.length > 0 &&
                            ![t isEqualToString:@"[image attached \u2014 await user question]"]) {
                            text = t;
                            break;
                        }
                    }
                    if (text.length == 0) {
                        // No text block — use the attachment filename as the title
                        NSString *fname = self.activeThread.attachmentPaths.lastObject.lastPathComponent;
                        text = fname.length > 0
                            ? [@"Attachment: " stringByAppendingString:fname]
                            : @"[Attachment]";
                    }
                }

                // Strip Tier-3 context preamble
                NSString *contextPrefix = @"[Memories with possible relevance:]";
                if ([text hasPrefix:contextPrefix]) {
                    NSRange userMsgRange = [text rangeOfString:@"[User message]\n"];
                    if (userMsgRange.location != NSNotFound) {
                        text = [text substringFromIndex:userMsgRange.location + userMsgRange.length];
                    } else { continue; }
                }

                text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (text.length == 0) continue;
                self.activeThread.title = text.length > 60
                    ? [[text substringToIndex:60] stringByAppendingString:@"\u2026"]
                    : text;
                break;
            }
        }
    }
    // Carry last image path if any
    if (self.lastImageLocalPath) self.activeThread.lastImageLocalPath = self.lastImageLocalPath;

    // Keep visible label in sync whenever the title gets auto-derived
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateThreadTitleLabel]; });
    EZThreadSave(self.activeThread, nil);
    EZLogf(EZLogLevelInfo, @"THREAD", @"Saved: %@", self.activeThread.threadID);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ChatHistoryViewControllerDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)chatHistoryDidSelectThread:(EZChatThread *)thread {
    [self closeDrawer];
    [self.chatContext removeAllObjects];
    [self.chatContext addObjectsFromArray:thread.chatContext];
    [self.displayMessages removeAllObjects];

    self.activeThread       = thread;
    self.selectedModel      = thread.modelName ?: self.selectedModel;
    self.lastImageLocalPath = thread.lastImageLocalPath;
    self.lastUserPrompt     = nil;
    self.lastAIResponse     = nil;
    self.pendingFileContext = nil;
    self.pendingFileName    = nil;
    self.pendingImagePath   = nil;

    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", self.selectedModel]
                      forState:UIControlStateNormal];

    // Rebuild display messages from saved context
    for (NSDictionary *msg in self.chatContext) {
        NSString *role    = msg[@"role"] ?: @"";
        id        content = msg[@"content"];
        NSString *text    = [content isKindOfClass:[NSString class]] ? content : nil;
        if (!text) continue; // skip vision attachment blobs on restore

        if ([role isEqualToString:@"user"]) {
            if ([text hasPrefix:@"[Memories with possible relevance:]"]) {
                NSRange r = [text rangeOfString:@"[User message]\n"];
                if (r.location != NSNotFound) text = [text substringFromIndex:r.location + r.length];
            }
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text.length > 0) [self appendToChat:[NSString stringWithFormat:@"You: %@", text]];
        } else if ([role isEqualToString:@"assistant"]) {
            self.lastAIResponse = text;
            if ([text containsString:@"```"]) {
                NSMutableArray *cp = [NSMutableArray array];
                NSString *processed = [self processReplyWithCodeBlocks:text savedPaths:cp isRestore:YES];
                [self appendToChat:[NSString stringWithFormat:@"AI: %@", processed]];
            } else {
                [self appendToChat:[NSString stringWithFormat:@"AI: %@", text]];
            }
        }
    }

    [self appendToChat:[NSString stringWithFormat:@"[System: Thread \"%@\" restored ✓]", thread.title]];
    [self restoreImageGridCellsForThread:thread.threadID];
    [self scrollChatToBottom];
    [self updateThreadTitleLabel];
    EZLogf(EZLogLevelInfo, @"THREAD", @"Restored: %@ (%lu turns)",
           thread.threadID, (unsigned long)self.chatContext.count);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EZOpenChatThread notification (from MemoriesViewController)
// ─────────────────────────────────────────────────────────────────────────────

/// Handles the "EZOpenChatThread" notification posted by MemoriesViewController
/// when the user taps a memory's timestamp label.
///
/// userInfo[@"threadID"] is the stem of the thread filename WITHOUT the .json
/// extension, using dashes for the time component, e.g. "2026-04-05T14-29-20".
/// EZChatThread.threadID uses colons internally ("2026-04-05T14:29:20"), so we
/// normalise before calling EZThreadLoad.
- (void)handleOpenChatThread:(NSNotification *)notification {
    NSString *rawID = notification.userInfo[@"threadID"];
    if (!rawID.length) {
        EZLog(EZLogLevelWarning, @"THREAD", @"handleOpenChatThread: missing threadID");
        return;
    }

    // Normalise: the memory helper emits "yyyy-MM-dd'T'HH-mm-ss" (dashes in
    // the time part).  EZChatThread.threadID and EZThreadLoad expect colons.
    // Replace only the time-separator dashes (after the 'T') with colons.
    NSString *threadID = rawID;
    NSRange tRange = [rawID rangeOfString:@"T"];
    if (tRange.location != NSNotFound) {
        NSString *datePart = [rawID substringToIndex:tRange.location + 1]; // "yyyy-MM-ddT"
        NSString *timePart = [rawID substringFromIndex:tRange.location + 1]; // "HH-mm-ss"
        timePart  = [timePart stringByReplacingOccurrencesOfString:@"-" withString:@":"];
        threadID  = [datePart stringByAppendingString:timePart];
    }

    EZLogf(EZLogLevelInfo, @"THREAD", @"Opening thread from memory tap: %@", threadID);

    // Save current work before switching away
    [self saveActiveThread];

    // Load the requested thread via the helpers API
    EZChatThread *thread = EZThreadLoad(threadID);
    if (!thread) {
        EZLogf(EZLogLevelWarning, @"THREAD", @"EZThreadLoad returned nil for: %@", threadID);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"Thread Not Found"
                                 message:[NSString stringWithFormat:
                                    @"Could not load thread %@ \n\nThe file may have been deleted.", threadID]
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
        return;
    }

    // Hand off to the existing delegate method which rebuilds the full UI
    dispatch_async(dispatch_get_main_queue(), ^{
        [self chatHistoryDidSelectThread:thread];
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shake → Stats
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        HelperLogViewController *helperLogVC = [[HelperLogViewController alloc] init];
        [self presentViewController: helperLogVC animated:YES completion:nil];
        /*
        NSString *stats = EZHelperStats();
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"EZHelper Stats"
                                                                   message:stats
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [UIPasteboard generalPasteboard].string = stats;
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
         */
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Dictation
// ─────────────────────────────────────────────────────────────────────────────

- (void)setupDictation {
    self.speechRecognizer = [[SFSpeechRecognizer alloc]
        initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    self.speechRecognizer.delegate = self;
    self.audioEngine = [[AVAudioEngine alloc] init];
    self.isDictating = NO;
}

/// Request both speech recognition and microphone permissions upfront
/// so they appear in Privacy settings and don't surprise the user mid-tap.
- (void)requestSpeechPermissionsIfNeeded {
    // Only prompt if not yet determined
    if ([SFSpeechRecognizer authorizationStatus] == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.dictateButton.enabled = (status == SFSpeechRecognizerAuthorizationStatusAuthorized);
                EZLogf(EZLogLevelInfo, @"DICTATE", @"Speech auth: %ld", (long)status);
            });
        }];
    }
    AVAuthorizationStatus micStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (micStatus == AVAuthorizationStatusNotDetermined) {
        [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
            EZLogf(EZLogLevelInfo, @"DICTATE", @"Mic permission: %@", granted ? @"granted" : @"denied");
        }];
    }
}

- (void)speechRecognizer:(SFSpeechRecognizer *)speechRecognizer availabilityDidChange:(BOOL)available {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.dictateButton.enabled = available;
        EZLogf(EZLogLevelDebug, @"DICTATE", @"Availability: %@", available ? @"YES" : @"NO");
    });
}

- (void)toggleDictation {
    if (self.isDictating) { [self stopDictation]; return; }
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (granted) [self startDictation];
                        else [self appendToChat:@"[Dictation Error]: Mic permission denied."];
                    });
                }];
            } else {
                [self appendToChat:@"[Dictation Error]: Speech recognition permission denied."];
            }
        });
    }];
}

- (void)startDictation {
    if (self.recognitionTask) { [self.recognitionTask cancel]; self.recognitionTask = nil; }
    NSError *err;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryRecord
                    mode:AVAudioSessionModeMeasurement
                 options:AVAudioSessionCategoryOptionDuckOthers error:&err];
    [session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&err];
    if (err) { EZLogf(EZLogLevelError, @"DICTATE", @"Session: %@", err); return; }

    self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.recognitionRequest.shouldReportPartialResults = YES;
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    __weak typeof(self) ws = self;
    self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest
        resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        __strong typeof(ws) ss = ws; if (!ss) return;
        if (result) dispatch_async(dispatch_get_main_queue(), ^{
            [ss setInputText:result.bestTranscription.formattedString];
        });
        if (error || result.isFinal) {
            [ss.audioEngine stop]; [inputNode removeTapOnBus:0];
            ss.recognitionRequest = nil; ss.recognitionTask = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                ss.isDictating = NO;
                [ss.dictateButton setTintColor:[UIColor systemBlueColor]];
            });
        }
    }];
    [inputNode installTapOnBus:0 bufferSize:1024 format:[inputNode outputFormatForBus:0]
                         block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        [self.recognitionRequest appendAudioPCMBuffer:buf];
    }];
    [self.audioEngine prepare];
    NSError *engineErr;
    [self.audioEngine startAndReturnError:&engineErr];
    if (engineErr) { EZLogf(EZLogLevelError, @"DICTATE", @"Engine: %@", engineErr); return; }
    self.isDictating = YES;
    [self.dictateButton setTintColor:[UIColor systemRedColor]];
    EZLog(EZLogLevelInfo, @"DICTATE", @"Started");
}

- (void)stopDictation {
    if (self.audioEngine.isRunning) { [self.audioEngine stop]; [self.recognitionRequest endAudio]; }
    self.isDictating = NO;
    [self.dictateButton setTintColor:[UIColor systemBlueColor]];
    EZLog(EZLogLevelInfo, @"DICTATE", @"Stopped");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UI Setup
// ─────────────────────────────────────────────────────────────────────────────

- (void)setupUI {
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // Top bar buttons
    // + New chat (save current, start fresh)
    self.addChatButton   = [self _iconButton:@"square.and.pencil" tint:[UIColor systemGreenColor]
                                      action:@selector(newChat)];
    self.supportRequestButton = [self _iconButton:@"questionmark.circle.fill" tint:[UIColor systemRedColor] action:@selector(openSupport)];
    // History (browse/restore past threads)
    self.historyButton   = [self _iconButton:@"clock.arrow.circlepath" tint:nil
                                      action:@selector(openHistory)];
    // Copy last AI response
    self.clipboardButton = [self _iconButton:@"doc.on.doc" tint:nil
                                      action:@selector(copyLastResponse)];
    // Speak last AI response
    self.speakButton     = [self _iconButton:@"speaker.wave.2.fill" tint:nil
                                      action:@selector(speakLastResponse)];

    
    self.cloningButton = [self _iconButton:@"doc.richtext" tint:nil action:@selector(openCloning)];
    
    self.galleryButton = [self _iconButton:@"photo.on.rectangle.angled" tint:nil action:@selector(openGallery)];
    self.brainRotButton = [self _iconButton:@"brain.head.profile" tint:nil action:@selector(openBrainRot)];

    self.textToSpeechButton = [self _iconButton:@"play.circle.fill" tint:nil action:@selector(openTTS)];
    
    
    
    
    self.memoriesButton   = [self _iconButton:@"memory" tint:nil
                                      action:@selector(openMemories)];
    // Web search toggle
    self.webSearchButton = [self _iconButton:@"globe" tint:nil
                                      action:@selector(toggleWebSearch)];
    [self updateWebSearchButtonTint];
    // Settings
    self.settingsButton  = [self _iconButton:@"gearshape.fill" tint:nil
                                      action:@selector(openSettings)];
    // Trash = delete current chat (confirm) then start new one
    self.clearButton   = [self _iconButton:@"trash.fill" tint:[UIColor systemRedColor]
                                    action:@selector(deleteCurrentChat)];
    // Rename thread title
    self.renameButton  = [self _iconButton:@"pencil.line" tint:nil
                                    action:@selector(renameThread)];

    // Create Coin Pot placeholder used inside the top row
    self.coinPotView = [[EZCoinPotView alloc] init];
    self.coinPotView.coinImage = [UIImage imageNamed:@"EZCoin"];
    self.coinPotView.translatesAutoresizingMaskIntoConstraints = NO;
    self.coinPotView.userInteractionEnabled = YES;
    UITapGestureRecognizer *potTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(coinPotTapped)];
    [self.coinPotView addGestureRecognizer:potTap];

    // Full-width stack — equalSpacing distributes buttons edge to edge
    UIStackView *topStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.addChatButton, self.historyButton, self.clipboardButton,
        self.speakButton, self.webSearchButton, self.coinPotView,
        self.renameButton, self.clearButton, self.memoriesButton, self.cloningButton, self.supportRequestButton,
        self.textToSpeechButton, self.galleryButton
    ]];
    topStack.distribution = UIStackViewDistributionEqualSpacing;
    topStack.alignment    = UIStackViewAlignmentCenter;
    topStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:topStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.coinPotView.widthAnchor constraintEqualToConstant:48],
        [self.coinPotView.heightAnchor constraintEqualToConstant:52],
    ]];
    [self.coinPotView setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisHorizontal];
    [self.coinPotView setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisVertical];

    // Legacy label — hidden, kept so any remaining references don't crash
    self.coinBalanceLabel = [[UILabel alloc] init];
    self.coinBalanceLabel.hidden = YES;
    self.coinBalanceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.coinBalanceLabel];

    // Thread title label — tappable, sits between top bar and chat table
    self.threadTitleLabel                 = [[UILabel alloc] init];
    self.threadTitleLabel.text            = @"New Conversation";
    self.threadTitleLabel.font            = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.threadTitleLabel.textColor       = [UIColor secondaryLabelColor];
    self.threadTitleLabel.textAlignment   = NSTextAlignmentCenter;
    self.threadTitleLabel.userInteractionEnabled = YES;
    self.threadTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UITapGestureRecognizer *titleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(renameThread)];
    [self.threadTitleLabel addGestureRecognizer:titleTap];
    [self.view addSubview:self.threadTitleLabel];

    // Chat table view — each message is a bubble, system, or code cell
    self.chatTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.chatTableView.dataSource         = self;
    self.chatTableView.delegate           = self;
    self.chatTableView.separatorStyle     = UITableViewCellSeparatorStyleNone;
    self.chatTableView.backgroundColor    = [UIColor systemBackgroundColor];
    self.chatTableView.estimatedRowHeight = 60;
    self.chatTableView.rowHeight          = UITableViewAutomaticDimension;
    self.chatTableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.chatTableView registerClass:[EZBubbleCell class]    forCellReuseIdentifier:@"EZBubble"];
    [self.chatTableView registerClass:[EZSystemCell class]    forCellReuseIdentifier:@"EZSystem"];
    [self.chatTableView registerClass:[EZCodeBlockCell class] forCellReuseIdentifier:@"EZCodeBlock"];
    [self.chatTableView registerClass:[EZImageGridCell class] forCellReuseIdentifier:@"EZImageGrid"];
    [self.chatTableView registerClass:[EZAttachmentPreviewCell class] forCellReuseIdentifier:@"EZAttachment"];
    [self.view addSubview:self.chatTableView];

    self.statusBannerView = [[UIView alloc] init];
    self.statusBannerView.backgroundColor = [UIColor colorWithDynamicProvider:
        ^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithRed:0.12 green:0.12 blue:0.16 alpha:0.96]
                : [UIColor colorWithRed:0.95 green:0.95 blue:0.98 alpha:0.97];
        }];
    self.statusBannerView.layer.cornerRadius = 10;
    self.statusBannerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusBannerView.alpha = 0;
    [self.view addSubview:self.statusBannerView];
    self.statusBannerSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.statusBannerSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusBannerSpinner.hidesWhenStopped = NO;
    [self.statusBannerView addSubview:self.statusBannerSpinner];
    self.statusBannerLabel = [[UILabel alloc] init];
    self.statusBannerLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.statusBannerLabel.textColor = [UIColor secondaryLabelColor];
    self.statusBannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusBannerView addSubview:self.statusBannerLabel];

    // Input container
    self.inputContainer = [[UIView alloc] init];
    self.inputContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.inputContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.inputContainer];
    
        // Dictate button
        self.dictateButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.dictateButton setImage:[UIImage systemImageNamed:@"mic.fill"] forState:UIControlStateNormal];
        [self.dictateButton setTintColor:[UIColor systemBlueColor]];
        [self.dictateButton addTarget:self action:@selector(toggleDictation)
                     forControlEvents:UIControlEventTouchUpInside];
        self.dictateButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.inputContainer addSubview:self.dictateButton];

    // Model picker button
    self.modelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", self.selectedModel]
                      forState:UIControlStateNormal];
    [self.modelButton addTarget:self action:@selector(showModelPicker)
                forControlEvents:UIControlEventTouchUpInside];
    self.modelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.modelButton];

    // Attach button
    self.attachButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.attachButton setImage:[UIImage systemImageNamed:@"paperclip.circle.fill"]
                       forState:UIControlStateNormal];
    [self.attachButton addTarget:self action:@selector(showAttachMenu)
                forControlEvents:UIControlEventTouchUpInside];
    self.attachButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.attachButton];

    

    // Message input — UITextView so it can expand to multiple lines.
    // Wrapped in a rounded container view to replicate UITextBorderStyleRoundedRect look.
    UIView *inputWrapper = [[UIView alloc] init];
    inputWrapper.backgroundColor   = [UIColor systemBackgroundColor];
    inputWrapper.layer.cornerRadius = 10.0;
    inputWrapper.layer.borderWidth  = 1.5;
    inputWrapper.layer.borderColor  = [UIColor separatorColor].CGColor;
    inputWrapper.clipsToBounds      = YES;
    inputWrapper.translatesAutoresizingMaskIntoConstraints = NO;

    self.messageTextField = [[UITextView alloc] init];
    self.messageTextField.font                  = [UIFont systemFontOfSize:16];
    self.messageTextField.textColor             = [UIColor labelColor];
    self.messageTextField.backgroundColor       = [UIColor clearColor];
    self.messageTextField.textContainerInset    = UIEdgeInsetsMake(8, 6, 8, 6);
    self.messageTextField.textContainer.lineFragmentPadding = 0;
    self.messageTextField.scrollEnabled         = YES;
    self.messageTextField.delegate              = self;
    self.messageTextField.returnKeyType         = UIReturnKeyDefault;
    self.messageTextField.translatesAutoresizingMaskIntoConstraints = NO;
    
    self.messageTextField.layer.cornerRadius = 10;
    self.messageTextField.layer.masksToBounds = YES;
    self.messageTextField.layer.borderColor = [UIColor secondaryLabelColor].CGColor;

    // Placeholder label — UITextView has no built-in placeholder
    UILabel *placeholder = [[UILabel alloc] init];
    placeholder.text      = @"Type message...";
    placeholder.font      = [UIFont systemFontOfSize:16];
    placeholder.textColor = [UIColor placeholderTextColor];
    placeholder.tag       = 9001;   // retrieved to show/hide as user types
    placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    [self.messageTextField addSubview:placeholder];
    [NSLayoutConstraint activateConstraints:@[
        [placeholder.leadingAnchor  constraintEqualToAnchor:self.messageTextField.leadingAnchor  constant:10],
        [placeholder.topAnchor      constraintEqualToAnchor:self.messageTextField.topAnchor      constant:9],
    ]];

    [inputWrapper addSubview:self.messageTextField];
    [NSLayoutConstraint activateConstraints:@[
        [self.messageTextField.topAnchor      constraintEqualToAnchor:inputWrapper.topAnchor],
        [self.messageTextField.bottomAnchor   constraintEqualToAnchor:inputWrapper.bottomAnchor],
        [self.messageTextField.leadingAnchor  constraintEqualToAnchor:inputWrapper.leadingAnchor],
        [self.messageTextField.trailingAnchor constraintEqualToAnchor:inputWrapper.trailingAnchor],
    ]];
    [self.inputContainer addSubview:inputWrapper];

    // Store inputWrapper so constraints can reference it below
    inputWrapper.tag = 9002;

    // Send button
    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendButton setTitle:@"Send" forState:UIControlStateNormal];
    [self.sendButton addTarget:self action:@selector(handleSend)
              forControlEvents:UIControlEventTouchUpInside];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.sendButton];
    self.inputContainer.backgroundColor = [UIColor colorWithRed:0 green:0.44 blue:0.34 alpha:0.8];
    self.inputContainer.layer.borderWidth = 2.0;
    self.inputContainer.layer.borderColor = [UIColor secondaryLabelColor].CGColor;
    self.inputContainer.layer.masksToBounds = YES;
    self.inputContainer.layer.cornerRadius = 10.0;

    [self.sendButton setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                     forAxis:UILayoutConstraintAxisHorizontal];
    [self.messageTextField setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                           forAxis:UILayoutConstraintAxisHorizontal];

    // Image settings button — only visible when an image model is selected
    self.imageSettingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.imageSettingsButton setImage:[UIImage systemImageNamed:@"slider.horizontal.3"]
                              forState:UIControlStateNormal];
    [self.imageSettingsButton addTarget:self action:@selector(showImageSettings)
                      forControlEvents:UIControlEventTouchUpInside];
    self.imageSettingsButton.hidden = YES; // shown when image model active
    self.imageSettingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.imageSettingsButton];

    self.containerBottomConstraint =
        [self.inputContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [topStack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:5],
        [topStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [topStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.threadTitleLabel.topAnchor    constraintEqualToAnchor:topStack.bottomAnchor constant:4],
        [self.threadTitleLabel.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.threadTitleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.chatTableView.topAnchor constraintEqualToAnchor:self.threadTitleLabel.bottomAnchor constant:52],
        [self.chatTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.chatTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.chatTableView.bottomAnchor constraintEqualToAnchor:self.inputContainer.topAnchor],
        [self.inputContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.inputContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.containerBottomConstraint,
        [self.modelButton.topAnchor constraintEqualToAnchor:self.inputContainer.topAnchor constant:8],
        [self.modelButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],
        [self.imageSettingsButton.centerYAnchor constraintEqualToAnchor:self.modelButton.centerYAnchor],
        [self.imageSettingsButton.leadingAnchor constraintEqualToAnchor:self.modelButton.trailingAnchor constant:8],
        [self.imageSettingsButton.widthAnchor constraintEqualToConstant:32],
        [self.imageSettingsButton.heightAnchor constraintEqualToConstant:32],
        [self.attachButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],
        [self.attachButton.topAnchor constraintEqualToAnchor:self.modelButton.bottomAnchor constant:12],
        [self.dictateButton.leadingAnchor constraintEqualToAnchor:self.attachButton.trailingAnchor constant:6],
        [self.dictateButton.centerYAnchor constraintEqualToAnchor:self.attachButton.centerYAnchor],
        [inputWrapper.leadingAnchor constraintEqualToAnchor:self.dictateButton.trailingAnchor constant:8],
        [inputWrapper.topAnchor     constraintEqualToAnchor:self.attachButton.topAnchor],
        [inputWrapper.trailingAnchor constraintEqualToAnchor:self.sendButton.leadingAnchor constant:-8],
        [self.sendButton.trailingAnchor constraintEqualToAnchor:self.inputContainer.trailingAnchor constant:-12],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:inputWrapper.centerYAnchor],
        [self.inputContainer.bottomAnchor constraintEqualToAnchor:inputWrapper.bottomAnchor constant:12],
    ]];
    // Collapsed height: ~2 lines (72pt). Expanded: ~4 lines (136pt).
    // The constraint is animated in textViewDidBeginEditing / textViewDidEndEditing.
    self.messageInputHeightConstraint = [inputWrapper.heightAnchor constraintEqualToConstant:72.0];
    self.messageInputHeightConstraint.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.statusBannerView.bottomAnchor constraintEqualToAnchor:self.inputContainer.topAnchor constant:-8],
        [self.statusBannerView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusBannerView.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-32],
        [self.statusBannerSpinner.leadingAnchor constraintEqualToAnchor:self.statusBannerView.leadingAnchor constant:12],
        [self.statusBannerSpinner.centerYAnchor constraintEqualToAnchor:self.statusBannerView.centerYAnchor],
        [self.statusBannerLabel.leadingAnchor constraintEqualToAnchor:self.statusBannerSpinner.trailingAnchor constant:8],
        [self.statusBannerLabel.trailingAnchor constraintEqualToAnchor:self.statusBannerView.trailingAnchor constant:-12],
        [self.statusBannerLabel.topAnchor constraintEqualToAnchor:self.statusBannerView.topAnchor constant:10],
        [self.statusBannerLabel.bottomAnchor constraintEqualToAnchor:self.statusBannerView.bottomAnchor constant:-10],
    ]];

    // Tap anywhere outside the input field to dismiss the keyboard.
    // delegate set to self so gestureRecognizer:shouldReceiveTouch: can
    // prevent the gesture from firing on buttons (avoids a layout-animation
    // race that cancelled touchUpInside on the first send tap).
    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    dismissTap.delegate = self;
    [self.view addGestureRecognizer:dismissTap];
}

- (UIButton *)_iconButton:(NSString *)sfSymbol tint:(nullable UIColor *)tint action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:sfSymbol] forState:UIControlStateNormal];
    if (tint) [b setTintColor:tint];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder]; return YES;
}

- (void)updateCoinBalanceDisplay {
    NSInteger balance      = [EZEntitlementManager shared].coinBalance;
    NSString  *tier        = [EZEntitlementManager shared].currentTier ?: @"basic";
    NSInteger includedCoins = 400; // default basic

    NSDictionary *tierCoins = @{
        @"basic":    @(400),
        @"standard": @(900),
        @"pro":      @(1600),
        @"ultra":    @(2500),
    };
    NSNumber *included = tierCoins[tier.lowercaseString];
    if (included) includedCoins = included.integerValue;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.coinPotView updateBalance:balance
                          includedCoins:includedCoins
                               animated:YES];
        // Legacy label kept in sync in case anything still reads it
        self.coinBalanceLabel.text = [NSString stringWithFormat:@"🪙 %ld", (long)balance];
    });
}

- (void)coinPotTapped {
    [self presentCoinStoreForFeature:nil];
}

- (void)handleSubscriptionUpdated {
    NSInteger previousBalance = [EZEntitlementManager shared].coinBalance;
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger newBalance) {
        NSInteger gained = newBalance - previousBalance;
        if (gained > 0) {
            [self animateCoinGain:gained newBalance:newBalance];
        } else {
            [self updateCoinBalanceDisplay];
        }
    }];
}

/// Called after coins are added (top-up or subscription) to play the toss animation
/// then update the pot fill level.
- (void)animateCoinGain:(NSInteger)coinsAdded newBalance:(NSInteger)newBalance {
    NSString  *tier         = [EZEntitlementManager shared].currentTier ?: @"basic";
    NSDictionary *tierCoins = @{
        @"basic":    @(400),
        @"standard": @(900),
        @"pro":      @(1600),
        @"ultra":    @(2500),
    };
    NSInteger includedCoins = [tierCoins[tier.lowercaseString] integerValue] ?: 400;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.coinPotView animateCoinToss:coinsAdded completion:^{
            [self.coinPotView updateBalance:newBalance
                              includedCoins:includedCoins
                                   animated:YES];
        }];
    });
}


// ── UITextViewDelegate — expanding input ─────────────────────────────────────

- (void)textViewDidBeginEditing:(UITextView *)textView {
    if (textView != self.messageTextField) return;
    self.messageInputHeightConstraint.constant = 120.0;  //was 136
    [UIView animateWithDuration:0.25
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self.view layoutIfNeeded]; }
                     completion:nil];
}

- (void)textViewDidEndEditing:(UITextView *)textView {
    if (textView != self.messageTextField) return;
    self.messageInputHeightConstraint.constant = 72.0;
    [UIView animateWithDuration:0.25
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self.view layoutIfNeeded]; }
                     completion:nil];
}

- (void)textViewDidChange:(UITextView *)textView {
    if (textView != self.messageTextField) return;
    // Show/hide placeholder
    UILabel *ph = (UILabel *)[textView viewWithTag:9001];
    ph.hidden = textView.text.length > 0;
}

// Return key inserts a newline. Send button is the only send trigger.
- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range
                                                replacementText:(NSString *)text {
    if (textView != self.messageTextField) return YES;
    return YES;
}

- (void)setInputText:(NSString *)text {
    self.messageTextField.text = text;
    // Keep placeholder in sync when text is set programmatically
    UILabel *ph = (UILabel *)[self.messageTextField viewWithTag:9001];
    if (ph) ph.hidden = text.length > 0;
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

// The dismissTap gesture must not fire when the touch lands on a UIControl
// (UIButton, UISwitch, etc.). Without this, tapping Send while the keyboard
// is visible starts a keyboard-hide layout animation mid-touch that moves the
// inputContainer, causing UIKit to cancel the button's touchUpInside event.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    return ![touch.view isKindOfClass:[UIControl class]];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Web Search Toggle
// ─────────────────────────────────────────────────────────────────────────────

- (void)toggleWebSearch {
    self.webSearchEnabled = !self.webSearchEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.webSearchEnabled forKey:@"webSearchEnabled"];
    [self updateWebSearchButtonTint];
    [self appendToChat:[NSString stringWithFormat:@"[System: Web Search %@]",
                        self.webSearchEnabled ? @"ON 🌐" : @"OFF"]];
    EZLogf(EZLogLevelInfo, @"WEBSEARCH", @"Toggled %@", self.webSearchEnabled ? @"ON" : @"OFF");
}

- (void)updateWebSearchButtonTint {
    [self.webSearchButton setTintColor:self.webSearchEnabled
        ? [UIColor systemGreenColor] : [UIColor systemGrayColor]];
}

    // ─────────────────────────────────────────────────────────────────────────────
// MARK: - Thread Title Editing
// ─────────────────────────────────────────────────────────────────────────────

/// Syncs the visible threadTitleLabel with the active thread's current title.
- (void)updateThreadTitleLabel {
    NSString *title = self.activeThread.title;
    if (!title.length || [title isEqualToString:@"New Conversation"]) {
        self.threadTitleLabel.text      = @"New Conversation";
        self.threadTitleLabel.textColor = [UIColor tertiaryLabelColor];
    } else {
        self.threadTitleLabel.text      = title;
        self.threadTitleLabel.textColor = [UIColor secondaryLabelColor];
    }
}

/// Shows an alert with a prefilled text field so the user can rename the thread.
- (void)renameThread {
    NSString *current = self.activeThread.title.length > 0
        ? self.activeThread.title : @"";
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Rename Thread"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text             = current;
        tf.placeholder      = @"Thread name";
        tf.clearButtonMode  = UITextFieldViewModeWhileEditing;
        tf.returnKeyType    = UIReturnKeyDone;
        tf.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    }];
    __weak typeof(self) ws = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
        NSString *newTitle = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!newTitle.length) return;
        ws.activeThread.title = newTitle;
        [ws updateThreadTitleLabel];
        [ws saveActiveThread];
        EZLogf(EZLogLevelInfo, @"THREAD", @"Renamed to: %@", newTitle);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Generation Settings
// ─────────────────────────────────────────────────────────────────────────────

/// Presents a series of action sheets to configure gpt-image-1 generation params.
/// Settings are persisted in NSUserDefaults and read in callGptImage1 / callImageEdit.
- (void)showImageSettings {
    EZImageSettingsViewController *vc = [[EZImageSettingsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat History
// ─────────────────────────────────────────────────────────────────────────────

- (void)openHistory {
    if (self.memoriesDrawerOpen) {
        [self closeMemoriesDrawerWithCompletion:nil];
    }
    if (self.drawerOpen) { [self closeDrawer]; return; }

    // ── Lazy build — only on first open ──────────────────────────────────────
    if (!self.drawerContainerView) {
        CGFloat drawerWidth = self.view.bounds.size.width * 0.75;

        // Dim overlay — full screen, tap anywhere right of drawer to close
        self.drawerDimView = [[UIView alloc] init];
        self.drawerDimView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        self.drawerDimView.alpha = 0;
        self.drawerDimView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.drawerDimView];
        [NSLayoutConstraint activateConstraints:@[
            [self.drawerDimView.topAnchor     constraintEqualToAnchor:self.view.topAnchor],
            [self.drawerDimView.bottomAnchor  constraintEqualToAnchor:self.view.bottomAnchor],
            [self.drawerDimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.drawerDimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        ]];
        UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(closeDrawer)];
        [self.drawerDimView addGestureRecognizer:dimTap];\
        
        // Drawer container — slides in from left
        self.drawerContainerView = [[UIView alloc] init];
        self.drawerContainerView.backgroundColor = [UIColor systemBackgroundColor];
        self.drawerContainerView.translatesAutoresizingMaskIntoConstraints = NO;
        self.drawerContainerView.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.drawerContainerView.layer.shadowOpacity = 0.22;
        self.drawerContainerView.layer.shadowRadius  = 14;
        self.drawerContainerView.layer.shadowOffset  = CGSizeMake(6, 0);
        [self.view addSubview:self.drawerContainerView];

        // Start fully off-screen to the left
        self.drawerLeadingConstraint = [self.drawerContainerView.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor constant:-drawerWidth];
        [NSLayoutConstraint activateConstraints:@[
            self.drawerLeadingConstraint,
            [self.drawerContainerView.topAnchor    constraintEqualToAnchor:self.view.topAnchor],
            [self.drawerContainerView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [self.drawerContainerView.widthAnchor  constraintEqualToConstant:drawerWidth],
        ]];

        // Embed ChatHistoryViewController as a child VC
        ChatHistoryViewController *historyVC = [[ChatHistoryViewController alloc]
            initWithStyle:UITableViewStylePlain];
        historyVC.delegate = self;
        self.drawerNavController = [[UINavigationController alloc]
            initWithRootViewController:historyVC];
        [self addChildViewController:self.drawerNavController];
        self.drawerNavController.view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.drawerContainerView addSubview:self.drawerNavController.view];
        [NSLayoutConstraint activateConstraints:@[
            [self.drawerNavController.view.topAnchor    constraintEqualToAnchor:self.drawerContainerView.topAnchor],
            [self.drawerNavController.view.bottomAnchor constraintEqualToAnchor:self.drawerContainerView.bottomAnchor],
            [self.drawerNavController.view.leadingAnchor constraintEqualToAnchor:self.drawerContainerView.leadingAnchor],
            [self.drawerNavController.view.trailingAnchor constraintEqualToAnchor:self.drawerContainerView.trailingAnchor],
        ]];
        [self.drawerNavController didMoveToParentViewController:self];
        [self.view layoutIfNeeded];
    }

    // ── Animate in ───────────────────────────────────────────────────────────
    self.drawerOpen = YES;
    self.drawerDimView.hidden = NO;
    self.drawerLeadingConstraint.constant = 0;
    [UIView animateWithDuration:0.32
                          delay:0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.drawerDimView.alpha = 1.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)closeDrawer {
    if (!self.drawerOpen) return;
    self.drawerOpen = NO;
    CGFloat drawerWidth = self.drawerContainerView.bounds.size.width;
    self.drawerLeadingConstraint.constant = -drawerWidth;
    [UIView animateWithDuration:0.26
                          delay:0
         usingSpringWithDamping:1.0
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.drawerDimView.alpha = 0;
        [self.view layoutIfNeeded];
    } completion:^(BOOL _) {
        self.drawerDimView.hidden = YES;
    }];
}

- (void)closeMemoriesDrawer {
    [self closeMemoriesDrawerWithCompletion:nil];
}

- (void)closeMemoriesDrawerWithCompletion:(dispatch_block_t)completion {
    if (!self.memoriesDrawerOpen) {
        if (completion) completion();
        return;
    }

    self.memoriesDrawerOpen = NO;
    CGFloat drawerWidth = self.memoriesDrawerContainerView.bounds.size.width;
    self.memoriesDrawerTrailingConstraint.constant = drawerWidth;
    [UIView animateWithDuration:0.26
                          delay:0
         usingSpringWithDamping:1.0
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.memoriesDrawerDimView.alpha = 0;
        [self.view layoutIfNeeded];
    } completion:^(BOOL _) {
        self.memoriesDrawerDimView.hidden = YES;
        if (completion) completion();
    }];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Attach Menu
// ─────────────────────────────────────────────────────────────────────────────

- (void)showAttachMenu {
    EZAttachMenuViewController *vc = [[EZAttachMenuViewController alloc] init];
    __weak typeof(self) ws = self;
    vc.onWhisper     = ^{ [ws presentFilePickerForMode:EZAttachModeWhisper]; };
    vc.onAnalyze     = ^{ [ws presentFilePickerForMode:EZAttachModeAnalyze]; };
    vc.onImageFiles  = ^{ [ws presentFilePickerForMode:EZAttachModeAnalyze forceTypes:@[UTTypeImage]]; };
    vc.onPhotoLibrary= ^{ [ws presentPhotoLibraryPicker]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)presentFilePickerForMode:(EZAttachMode)mode {
    NSArray *types;
    if (mode == EZAttachModeWhisper) {
        types = @[UTTypeAudio, UTTypeVideo, UTTypeMovie, UTTypeAudiovisualContent];
    } else {
        // Be explicit — UTTypeData catch-all breaks iOS 15 file picker
        types = @[UTTypePDF,
                  [UTType typeWithIdentifier:@"org.idpf.epub-container"],
                  UTTypePlainText,
                  UTTypeRTF,
                  UTTypeHTML,
                  UTTypeImage,
                  [UTType typeWithIdentifier:@"public.comma-separated-values-text"],
                  [UTType typeWithIdentifier:@"public.json"],
                  [UTType typeWithIdentifier:@"public.xml"]];
    }
    [self presentFilePickerForMode:mode forceTypes:types];
}

- (void)presentFilePickerForMode:(EZAttachMode)mode forceTypes:(NSArray *)types {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    // Store mode via associated object — safer than .view.tag on iOS 15
    objc_setAssociatedObject(picker, "EZAttachMode",
                             @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Document Picker Delegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *fileURL = urls.firstObject;
    if (!fileURL) return;

    // Retrieve mode from associated object — fall back to analyze
    NSNumber *modeNum = objc_getAssociatedObject(controller, "EZAttachMode");
    EZAttachMode mode = modeNum ? (EZAttachMode)modeNum.integerValue : EZAttachModeAnalyze;

    NSString *ext = fileURL.pathExtension.lowercaseString;
    BOOL isImage  = [@[@"jpg",@"jpeg",@"png",@"gif",@"webp",@"heic"] containsObject:ext];

    if (mode == EZAttachModeWhisper) {
        [self transcribeAudio:fileURL];
    } else if (isImage) {
        [self attachImage:fileURL];
    } else {
        [self analyzeFile:fileURL];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    EZLog(EZLogLevelInfo, @"FILE", @"Document picker cancelled by user");
}

- (void)presentPhotoLibraryPicker {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]];
    cfg.filter = [PHPickerFilter imagesFilter]; cfg.selectionLimit = 1;
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    p.delegate = self; [self presentViewController:p animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *r = results.firstObject; if (!r) return;
    NSItemProvider *pv = r.itemProvider;
    if ([pv hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) {
        [pv loadFileRepresentationForTypeIdentifier:UTTypeImage.identifier completionHandler:^(NSURL *url, NSError *e) {
            if (!url) { dispatch_async(dispatch_get_main_queue(), ^{ [self appendToChat:@"[Error: Could not load photo]"]; }); return; }
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            NSError *ce; [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:&ce];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ce) { [self appendToChat:@"[Error: Could not copy photo]"]; return; }
                [self attachImage:[NSURL fileURLWithPath:tmp]];
            });
        }];
    } else if ([pv canLoadObjectOfClass:[UIImage class]]) {
        [pv loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *img, NSError *e) {
            if (!img) return;
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"photo_pick.jpg"];
            [UIImageJPEGRepresentation(img, 0.92) writeToFile:tmp atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{ [self attachImage:[NSURL fileURLWithPath:tmp]]; });
        }];
    }
}
- (void)offerSaveToPhotos:(NSString *)path {
    if (!path.length) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save to Photos?"
        message:@"Save this image to your Photo Library." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) { [self saveImageToPhotos:path]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Not Now" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)saveImageToPhotos:(NSString *)localPath {
    if (![[NSFileManager defaultManager] fileExistsAtPath:localPath]) {
        [self appendToChat:@"[Error: Image not found]"]; return;
    }
    UIImage *img = [UIImage imageWithContentsOfFile:localPath];
    if (!img) { [self appendToChat:@"[Error: Cannot decode image]"]; return; }
    UIImageWriteToSavedPhotosAlbum(img, self,
        @selector(ezPhotoSaved:didFinishSavingWithError:contextInfo:), NULL);
}
- (void)ezPhotoSaved:(UIImage *)img didFinishSavingWithError:(NSError *)err contextInfo:(void *)ctx {
    if (err) [self appendToChat:[NSString stringWithFormat:@"[Error: Save failed \u2014 %@]", err.localizedDescription ?: @"?"]];
    else [self appendToChat:@"[System: Image saved to Photo Library \u2713]"];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Attachment
// ─────────────────────────────────────────────────────────────────────────────

- (void)attachImage:(NSURL *)fileURL {
    NSData *rawData = [NSData dataWithContentsOfURL:fileURL];
    if (!rawData) {
        [self appendToChat:@"[Error: Could not read image]"]; return;
    }

    NSString *name = fileURL.lastPathComponent;
    NSString *ext  = fileURL.pathExtension.lowercaseString;

    // ── Format validation & conversion ───────────────────────────────────────
    // OpenAI vision + image edit APIs accept: png, jpeg, gif, webp ONLY.
    // HEIC (default iOS camera format) must be converted to JPEG.
    // Any other unsupported format also gets converted to JPEG.
    NSData   *imageData = rawData;
    NSString *mime      = @"image/jpeg";
    BOOL      converted = NO;

    NSSet *supported = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"gif", @"webp", nil];

    if (![supported containsObject:ext]) {
        // Attempt conversion via UIImage → JPEG
        UIImage *img = [UIImage imageWithData:rawData];
        if (img) {
            NSData *jpegData = UIImageJPEGRepresentation(img, 0.92);
            if (jpegData) {
                imageData  = jpegData;
                mime       = @"image/jpeg";
                converted  = YES;
                [self appendToChat:[NSString stringWithFormat:
                    @"[System: %@ converted from %@ to JPEG for API compatibility ✓]",
                    name, ext.uppercaseString]];
                EZLogf(EZLogLevelInfo, @"ATTACH", @"Converted %@ → JPEG (%lu bytes)",
                       ext, (unsigned long)imageData.length);
            } else {
                [self appendToChat:[NSString stringWithFormat:
                    @"[Error: Could not convert %@ to a supported format. "
                    @"Please use PNG, JPEG, GIF, or WebP.]", ext.uppercaseString]];
                return;
            }
        } else {
            [self appendToChat:[NSString stringWithFormat:
                @"[Error: Unsupported image format '%@'. Please use PNG, JPEG, GIF, or WebP.]",
                ext.uppercaseString]];
            return;
        }
    } else {
        // Set correct mime for supported formats
        if ([ext isEqualToString:@"png"])              mime = @"image/png";
        else if ([ext isEqualToString:@"gif"])         mime = @"image/gif";
        else if ([ext isEqualToString:@"webp"])        mime = @"image/webp";
        else                                           mime = @"image/jpeg";
    }

    // ── Save to EZAttachments ─────────────────────────────────────────────────
    NSString *saveName  = converted
        ? [[name stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpeg"]
        : name;
    NSString *localPath = EZAttachmentSave(imageData, saveName);
    self.pendingImagePath = localPath ?: fileURL.path;
    [self appendAttachmentBubble:self.pendingImagePath];

    if (localPath) {
        NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
        [att addObject:localPath];
        self.activeThread.attachmentPaths = [att copy];
    }

    // ── Route based on selected model ─────────────────────────────────────────
    BOOL inImageGenMode = [self isGptImage1Family:self.selectedModel] ||
                          [self.selectedModel isEqualToString:@"dall-e-3"];

    if (inImageGenMode) {
        // Switch to image edit mode — gpt-image-1 handles both gen and edit
        self.selectedModel = @"gpt-image-1-edit";
        [self.modelButton setTitle:@"Model: gpt-image-1 (edit mode)" forState:UIControlStateNormal];
        [self appendToChat:[NSString stringWithFormat:
            @"[System: Image %@ attached — switched to image edit mode. "
            @"Type a prompt describing your edits.]", saveName]];
    } else {
        // Vision analysis mode — ensure model supports vision
        NSSet *visionModels = [NSSet setWithObjects:
            @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4",
            @"gpt-5", @"gpt-5-mini", @"gpt-5-pro", nil];

        if (![visionModels containsObject:self.selectedModel]) {
            NSString *prev     = self.selectedModel;
            self.selectedModel = @"gpt-4o";
            [self.modelButton setTitle:@"Model: gpt-4o" forState:UIControlStateNormal];
            [self appendToChat:[NSString stringWithFormat:
                @"[System: Image attached — %@ doesn't support vision. "
                @"Switched to gpt-4o. Type a prompt to analyze the image.]", prev]];
        } else {
            [self appendToChat:[NSString stringWithFormat:
                @"[System: Image %@ attached. Type a prompt to analyze or describe it.]", saveName]];
        }

        // Add vision message to context — use base64 data URL
        // NOTE: this message is marked so we can strip it after first use
        // to avoid re-sending huge base64 blobs on every subsequent turn
        NSString *base64  = [imageData base64EncodedStringWithOptions:0];
        NSString *dataURL = [NSString stringWithFormat:@"data:%@;base64,%@", mime, base64];
        NSDictionary *visionMsg = @{
            @"role":     @"user",
            @"content":  @[
                @{@"type": @"image_url", @"image_url": @{@"url": dataURL}},
                @{@"type": @"text",      @"text": @"[image attached — await user question]"}
            ],
            @"_isVisionAttachment": @YES   // internal flag — stripped before API call
        };
        [self.chatContext addObject:visionMsg];
    }

    EZLogf(EZLogLevelInfo, @"ATTACH", @"Image ready: %@ mime=%@ bytes=%lu",
           saveName, mime, (unsigned long)imageData.length);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - File Analysis (PDF / ePub / text)
// ─────────────────────────────────────────────────────────────────────────────

- (void)analyzeFile:(NSURL *)fileURL {
    NSString *ext  = fileURL.pathExtension.lowercaseString;
    NSString *name = fileURL.lastPathComponent;
    EZLogf(EZLogLevelInfo, @"FILE", @"Analyzing: %@", name);
    [self appendToChat:[NSString stringWithFormat:@"[System: Reading %@...]", name]];

    // Save a copy for persistence
    NSData *fileData = [NSData dataWithContentsOfURL:fileURL];
                    
    // Save a copy for persistataWithContentsOfURL:fileURL];
    if (fileData) {
        NSString *savedPath = EZAttachmentSave(fileData, name);
        if (savedPath) {
            NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
            [att addObject:savedPath];
            self.activeThread.attachmentPaths = [att copy];
        }
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *extractedText = nil;
        if ([ext isEqualToString:@"pdf"]) {
            extractedText = [self extractTextFromPDF:fileURL];
        } else if ([ext isEqualToString:@"epub"]) {
            extractedText = [self extractTextFromEPUB:fileURL];
        } else {
            extractedText = [NSString stringWithContentsOfURL:fileURL
                                                     encoding:NSUTF8StringEncoding error:nil]
                         ?: [NSString stringWithContentsOfURL:fileURL
                                                     encoding:NSISOLatin1StringEncoding error:nil];
        }
        if (!extractedText.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[Error: Could not extract text from file]"];
            });
            return;
        }
        if (extractedText.length > 12000) {
            extractedText = [[extractedText substringToIndex:12000]
                             stringByAppendingString:@"\n[...truncated...]"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.pendingFileContext = extractedText;
            self.pendingFileName    = name;
            [self appendToChat:[NSString stringWithFormat:
                @"[System: %@ ready (%lu chars). Ask me anything about it.]",
                name, (unsigned long)extractedText.length]];
            EZLogf(EZLogLevelInfo, @"FILE", @"Context ready: %@ (%lu chars)",
                   name, (unsigned long)extractedText.length);
        });
    });
}

- (NSString *)extractTextFromPDF:(NSURL *)url {
    PDFDocument *doc = [[PDFDocument alloc] initWithURL:url];
    if (!doc) return nil;
    NSMutableString *text = [NSMutableString string];
    for (NSInteger i = 0; i < doc.pageCount; i++) {
        NSString *pg = [[doc pageAtIndex:i] string];
        if (pg) [text appendFormat:@"%@\n", pg];
    }
    return text;
}

- (NSString *)extractTextFromEPUB:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                 ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!raw) return @"[Could not decode ePub]";
    NSMutableString *stripped = [NSMutableString string];
    BOOL inTag = NO;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c == '<')      { inTag = YES; continue; }
        if (c == '>')      { inTag = NO; [stripped appendString:@" "]; continue; }
        if (!inTag)        [stripped appendFormat:@"%C", c];
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\s{3,}"
                                                                        options:0 error:nil];
    return [re stringByReplacingMatchesInString:stripped options:0
                                          range:NSMakeRange(0, stripped.length)
                                   withTemplate:@"\n\n"];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - TTS
// ─────────────────────────────────────────────────────────────────────────────

- (void)speakLastResponse {
    if (!self.lastAIResponse) return;

    NSString *voiceID     = [[NSUserDefaults standardUserDefaults] stringForKey:@"elevenVoiceID"];
    NSString *textToSpeak = self.lastAIResponse;
    NSInteger charCount   = (NSInteger)textToSpeak.length;

    // ── Old user-API-key path — commented out, kept in case user keys return ──
    // NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    // // CHANGED: ElevenLabs key now loaded from EZKeyVault (Keychain) instead of NSUserDefaults
    // NSString *elKey   = [EZKeyVault loadKeyForIdentifier:EZVaultKeyElevenLabs];
    // NSString *elVoice = [d stringForKey:@"elevenVoiceID"];
    // if (elKey.length > 0 && elVoice.length > 0) {
    //     [self speakWithElevenLabs:textToSpeak key:elKey voiceID:elVoice];
    // } else {
    //     [self speakWithApple:textToSpeak];
    // }
    // ─────────────────────────────────────────────────────────────────────────

    // No voice configured — fall back to Apple TTS silently
    if (voiceID.length == 0) {
        [self speakWithApple:textToSpeak];
        return;
    }

    // ── Long-response guard (> 160 chars) ────────────────────────────────────
    // Coin cost mirrors the edge function: ceil(charCount / 50)
    NSInteger estimatedCoins = (NSInteger)ceil(charCount / 50.0);

    if (charCount > 160) {
        NSString *alertMessage = [NSString stringWithFormat:
            @"This response is %ld characters long.\n\n"
            @"Reading it with ElevenLabs will cost approximately %ld coins.\n\n"
            @"Choose an option:",
            (long)charCount, (long)estimatedCoins];

        UIAlertController *lengthAlert = [UIAlertController
            alertControllerWithTitle:@"Long Response"
                             message:alertMessage
                      preferredStyle:UIAlertControllerStyleAlert];

        NSString *elevenLabsLabel = [NSString stringWithFormat:
            @"ElevenLabs (≈%ld coins)", (long)estimatedCoins];
        [lengthAlert addAction:[UIAlertAction
            actionWithTitle:elevenLabsLabel
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
            [self speakWithElevenLabsEdge:textToSpeak voiceID:voiceID];
        }]];

        [lengthAlert addAction:[UIAlertAction
            actionWithTitle:@"Apple TTS (free)"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
            [self speakWithApple:textToSpeak];
        }]];

        [lengthAlert addAction:[UIAlertAction
            actionWithTitle:@"Don't Read"
                      style:UIAlertActionStyleCancel
                    handler:nil]];

        [self presentViewController:lengthAlert animated:YES completion:nil];
    } else {
        // Short response — go straight to ElevenLabs, no warning needed
        [self speakWithElevenLabsEdge:textToSpeak voiceID:voiceID];
    }
}

- (void)speakWithApple:(NSString *)text {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                            mode:AVAudioSessionModeDefault
                                         options:AVAudioSessionCategoryOptionDuckOthers error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    if (self.speechSynthesizer.isSpeaking)
        [self.speechSynthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
    u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    u.rate  = AVSpeechUtteranceDefaultSpeechRate;
    [self.speechSynthesizer speakUtterance:u];
}

// ── speakWithElevenLabs:key:voiceID: — COMMENTED OUT (user API key path) ────
// Kept in case user-supplied ElevenLabs keys need to be restored later.
// All TTS now routes through the ez-elevenlabs Supabase edge function.
//
// - (void)speakWithElevenLabs:(NSString *)text key:(NSString *)key voiceID:(NSString *)voiceID {
//     EZLogf(EZLogLevelInfo, @"TTS", @"ElevenLabs voiceID=%@", voiceID);
//     NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
//         @"https://api.elevenlabs.io/v1/text-to-speech/%@", voiceID]];
//     NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
//     req.HTTPMethod = @"POST";
//     [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
//     [req setValue:key forHTTPHeaderField:@"xi-api-key"];
//     req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
//         @"text": text, @"model_id": @"eleven_turbo_v2_5",
//         @"voice_settings": @{@"stability": @0.5, @"similarity_boost": @0.5}
//     } options:0 error:nil];
//     [[[NSURLSession sharedSession] dataTaskWithRequest:req
//         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
//         if (error) {
//             dispatch_async(dispatch_get_main_queue(), ^{ [self speakWithApple:text]; });
//             return;
//         }
//         NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
//         if (http.statusCode != 200) {
//             NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
//             EZLogf(EZLogLevelError, @"TTS", @"ElevenLabs %ld: %@", (long)http.statusCode, body);
//             dispatch_async(dispatch_get_main_queue(), ^{
//                 [self appendToChat:[NSString stringWithFormat:
//                     @"[ElevenLabs HTTP %ld — falling back to Apple TTS]", (long)http.statusCode]];
//                 [self speakWithApple:text];
//             });
//             return;
//         }
//         dispatch_async(dispatch_get_main_queue(), ^{
//             [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
//                                                     mode:AVAudioSessionModeDefault
//                                                  options:0 error:nil];
//             [[AVAudioSession sharedInstance] setActive:YES error:nil];
//             NSError *playerErr;
//             self.audioPlayer = [[AVAudioPlayer alloc] initWithData:data error:&playerErr];
//             if (playerErr) { [self speakWithApple:text]; return; }
//             [self.audioPlayer prepareToPlay];
//             [self.audioPlayer play];
//         });
//     }] resume];
// }
// ─────────────────────────────────────────────────────────────────────────────

// ── speakWithElevenLabsEdge:voiceID: — routes through ez-elevenlabs edge fn ─
// Sends text to the Supabase edge function which uses the server-side
// ElevenLabs API key (Supabase secret). Coins are deducted server-side at
// 1 coin per 50 characters, rounded up. Returns base64-encoded audio.
- (void)speakWithElevenLabsEdge:(NSString *)text voiceID:(NSString *)voiceID {
    NSString *jwt = [EZAuthManager shared].accessToken;
    if (!jwt.length) {
        EZLog(EZLogLevelError, @"TTS", @"No auth token — cannot call TTS edge function");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:@"[TTS Error: Not signed in — using Apple TTS]"];
            [self speakWithApple:text];
        });
        return;
    }

    NSInteger charCount = (NSInteger)text.length;
    EZLogf(EZLogLevelInfo, @"TTS", @"ElevenLabs edge TTS voiceID=%@ chars=%ld",
           voiceID, (long)charCount);

    NSURL *edgeURL = [NSURL URLWithString:
        @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-elevenlabs"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:edgeURL];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", jwt]
       forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"action":     @"tts",
        @"text":       text,
        @"voice_id":   voiceID,
        @"char_count": @(charCount),
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *networkError) {

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;

        // ── Network-level failure ─────────────────────────────────────────────
        if (networkError) {
            EZLogf(EZLogLevelError, @"TTS", @"Network error: %@",
                   networkError.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[TTS: Network error — using Apple TTS]"];
                [self speakWithApple:text];
            });
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseData
                                                             options:0 error:nil];

        // ── Insufficient coins (402) ──────────────────────────────────────────
        if (http.statusCode == 402) {
            NSInteger costNeeded   = [json[@"cost"] integerValue];
            NSInteger currentCoins = [json[@"balance"] integerValue];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *coinMessage = [NSString stringWithFormat:
                    @"This TTS request costs %ld coins but your balance is %ld.\n\n"
                    @"Use Apple TTS for free, or top up your coins.",
                    (long)costNeeded, (long)currentCoins];
                UIAlertController *coinAlert = [UIAlertController
                    alertControllerWithTitle:@"Not Enough Coins"
                                     message:coinMessage
                              preferredStyle:UIAlertControllerStyleAlert];
                [coinAlert addAction:[UIAlertAction
                    actionWithTitle:@"Use Apple TTS (free)"
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *a) { [self speakWithApple:text]; }]];
                [coinAlert addAction:[UIAlertAction
                    actionWithTitle:@"Get Coins"
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *a) {
                    [self presentCoinStoreForFeature:nil];
                }]];
                [coinAlert addAction:[UIAlertAction
                    actionWithTitle:@"Cancel"
                              style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:coinAlert animated:YES completion:nil];
            });
            return;
        }

        // ── Any other non-200 ─────────────────────────────────────────────────
        if (http.statusCode != 200) {
            NSString *errorDetail = json[@"error"] ?: @"Unknown error";
            EZLogf(EZLogLevelError, @"TTS", @"Edge function HTTP %ld: %@",
                   (long)http.statusCode, errorDetail);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:[NSString stringWithFormat:
                    @"[TTS Error %ld — using Apple TTS]", (long)http.statusCode]];
                [self speakWithApple:text];
            });
            return;
        }

        // ── Success ───────────────────────────────────────────────────────────
        NSString *audioB64   = json[@"audio_b64"];
        NSInteger newBalance = [json[@"balance"] integerValue];
        NSInteger coinsSpent = [json[@"coins_spent"] integerValue];

        if (!audioB64.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[TTS Error: No audio in response — using Apple TTS]"];
                [self speakWithApple:text];
            });
            return;
        }

        NSData *audioData = [[NSData alloc]
            initWithBase64EncodedString:audioB64
                                options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!audioData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[TTS Error: Could not decode audio — using Apple TTS]"];
                [self speakWithApple:text];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                                    mode:AVAudioSessionModeDefault
                                                 options:0 error:nil];
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
            NSError *playerErr = nil;
            self.audioPlayer = [[AVAudioPlayer alloc] initWithData:audioData error:&playerErr];
            if (playerErr) {
                EZLogf(EZLogLevelError, @"TTS", @"AVAudioPlayer error: %@",
                       playerErr.localizedDescription);
                [self speakWithApple:text];
                return;
            }
            [self.audioPlayer prepareToPlay];
            [self.audioPlayer play];

            // Refresh coin display — edge function already deducted server-side
            [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
                [self updateCoinBalanceDisplay];
            }];

            EZLogf(EZLogLevelInfo, @"TTS",
                   @"ElevenLabs audio playing — spent %ld coins, balance now %ld",
                   (long)coinsSpent, (long)newBalance);
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - handleSend
// ─────────────────────────────────────────────────────────────────────────────

- (void)handleSend {

    @try { [self ezcui_beginLongOperation:@"ChatCompletion"]; } @catch (NSException *e) {
        EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"begin failed in handleSend: %@", e);
    }

    NSString *text = self.messageTextField.text;
    if (text.length == 0) return;

    // ── Immediate UI feedback ─────────────────────────────────────────────────
    // Show the user bubble, clear the input field, and dismiss the keyboard NOW,
    // before any async entitlement check or API call. This eliminates the delay
    // where the user sees nothing happen after tapping Send. Disabling the button
    // here also blocks duplicate submissions during the async round-trip.
    self.sendButton.enabled = NO;
    [self appendToChat:[NSString stringWithFormat:@"You: %@", text]];
    [self.view endEditing:YES];
    [self setInputText:@""];

    // ── Determine feature for entitlement check ───────────────────────────────
    EZFeature feature = EZFeatureChatMini;

    if ([self.selectedModel isEqualToString:@"gpt-4o"] ||
        [self.selectedModel isEqualToString:@"gpt-4o-mini"] == NO) {
        feature = EZFeatureChatGPT4o;
    }
    if ([self isGptImage1Family:self.selectedModel] ||
        [self.selectedModel isEqualToString:@"gpt-image-1-edit"] ||
        [self.selectedModel isEqualToString:@"dall-e-2-edit"]) {
        feature = EZFeatureImageMedium;
    }
    if ([self.selectedModel isEqualToString:@"dall-e-3"]) {
        feature = EZFeatureDalle3Standard;
    }
    if ([self.selectedModel hasPrefix:@"sora-"]) {
        feature = EZFeatureSora10s;
    }

    // ── Entitlement check moved to callChatCompletions where we know the actual
    // token count from the assembled payload. For image/sora models we still
    // gate here since those don't go through callChatCompletions.
    BOOL isChatModel = ![self isGptImage1Family:self.selectedModel]
        && ![self.selectedModel isEqualToString:@"dall-e-3"]
        && ![self.selectedModel isEqualToString:@"dall-e-2-edit"]
        && ![self.selectedModel isEqualToString:@"gpt-image-1-edit"]
        && ![self.selectedModel hasPrefix:@"sora-"];

    if (isChatModel) {
        // Chat models — defer entitlement check to callChatCompletions
        // so we can pass the actual assembled token count.
        [self handleSendAuthorized:text];
        return;
    }

    // Non-chat models — check entitlement now with flat cost.
    // For image models, pick the feature tier by quality setting and multiply by n.
    if ([self isGptImage1Family:self.selectedModel] ||
        [self.selectedModel isEqualToString:@"gpt-image-1-edit"] ||
        [self.selectedModel isEqualToString:@"dall-e-2-edit"]) {

        NSUserDefaults *d  = [NSUserDefaults standardUserDefaults];
        NSString *quality  = [d stringForKey:@"imgQuality"] ?: @"auto";
        NSString *size     = [d stringForKey:@"imgSize"]    ?: @"1024x1024";
        NSInteger n        = [d integerForKey:@"imgVariations"];
        if (n < 1) n = 1;

        // Map quality → feature tier
        EZFeature imageFeature;
        if ([quality isEqualToString:@"high"]) {
            imageFeature = EZFeatureImageHigh;
        } else if ([quality isEqualToString:@"low"]) {
            imageFeature = EZFeatureImageLow;
        } else {
            imageFeature = EZFeatureImageMedium; // "auto" or "medium"
        }

        // Non-square sizes cost 25% more — round up to nearest whole image unit
        // so the edge function only needs to multiply by an integer quantity.
        CGFloat sizeMultiplier = [size isEqualToString:@"1024x1024"] ? 1.0 : 1.25;
        NSInteger quantity = (NSInteger)ceil(n * sizeMultiplier);

        BOOL isEdit = [self.selectedModel isEqualToString:@"gpt-image-1-edit"] ||
                      [self.selectedModel isEqualToString:@"dall-e-2-edit"];
        NSString *apiModel = isEdit ? @"gpt-image-1" : self.selectedModel;

        EZLogf(EZLogLevelInfo, @"COINS",
               @"Image cost: feature=%@ n=%ld size=%@ sizeMultiplier=%.2f quantity=%ld isEdit=%d",
               [self featureLabel:imageFeature], (long)n, size, sizeMultiplier, (long)quantity, isEdit);

        [[EZEntitlementManager shared] checkEntitlementForFeature:imageFeature
                                                         quantity:quantity
                                                           prompt:text
                                                            model:apiModel
                                                       completion:^(BOOL allowed,
                                                                    NSInteger balance,
                                                                    NSString *reason) {
            if (!allowed) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.sendButton.enabled = YES;
                    if ([reason isEqualToString:@"Not logged in"]) {
                        [self appendToChat:@"[Error: Please sign in to use EZCompleteUI]"];
                    } else if ([reason isEqualToString:@"Insufficient coins"] ||
                               [reason isEqualToString:@"No account found"]) {
                        [self presentCoinStoreForFeature:nil];
                    } else {
                        [self appendToChat:[NSString stringWithFormat:
                            @"[Error: %@]", reason ?: @"Access denied-please close app and log back in,"]];
                    }
                });
                return;
            }
            [self handleSendAuthorized:text];
        }];
        return;
    }

    [[EZEntitlementManager shared] checkEntitlementForFeature:feature
                                                         quantity:1
                                                           prompt:text
                                                            model:self.selectedModel
                                                       completion:^(BOOL allowed,
                                                                    NSInteger balance,
                                                                    NSString *reason) {
            if (!allowed) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.sendButton.enabled = YES;
                    if ([reason isEqualToString:@"Not logged in"]) {
                        [self appendToChat:@"[Error: Please sign in to use EZCompleteUI]"];
                    } else if ([reason isEqualToString:@"Insufficient coins"] ||
                               [reason isEqualToString:@"No account found"]) {
                        [self presentCoinStoreForFeature:nil];
                    } else {
                        [self appendToChat:[NSString stringWithFormat:
                            @"[Error: %@]", reason ?: @"Access denied-please reopen app and log in."]];
                    }
                });
                return;
            }
            [self handleSendAuthorized:text];
        }];
    }

- (void)handleSendAuthorized:(NSString *)text {

    if (self.isDictating) [self stopDictation];

    self.lastUserPrompt = text;

    // Inject pending file context
    NSString *fullPrompt = text;
    if (self.pendingFileContext.length > 0) {
        fullPrompt = [NSString stringWithFormat:
            @"[Attached file: %@]\n\n%@\n\n[User question]: %@",
            self.pendingFileName, self.pendingFileContext, text];
        self.pendingFileContext = nil;
        self.pendingFileName    = nil;
        [self appendToChat:@"[System: File context injected ✓]"];
    }

    [self.chatContext addObject:@{@"role": @"user", @"content": fullPrompt}];

    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    if (!apiKey.length) { self.sendButton.enabled = YES; [self appendToChat:@"[Error: No API Key]"]; return; }

    // ── Guard: Whisper is transcription-only, not a chat model ───────────────
    if ([self.selectedModel isEqualToString:@"whisper-1"]) {
        self.selectedModel = @"gpt-4o";
        [self.modelButton setTitle:@"Model: gpt-4o" forState:UIControlStateNormal];
        [self appendToChat:@"[System: Whisper is for audio transcription only — switched to gpt-4o for chat]"];
    }

    // ── Image edit mode (gpt-image-1 with attached image) ────────────────────
    if ([self.selectedModel isEqualToString:@"gpt-image-1-edit"]) {
        [self callImageEdit:text imagePath:self.pendingImagePath ?: self.lastImageLocalPath];
        self.pendingImagePath = nil;
        return;
    }

    // ── Legacy dall-e-2-edit fallback ────────────────────────────────────────
    if ([self.selectedModel isEqualToString:@"dall-e-2-edit"]) {
        self.selectedModel = @"gpt-image-1-edit";
        [self callImageEdit:text imagePath:self.pendingImagePath ?: self.lastImageLocalPath];
        self.pendingImagePath = nil;
        return;
    }

    // ── Image model intent check ──────────────────────────────────────────────
    BOOL isImageModel = [self isGptImage1Family:self.selectedModel] ||
                        [self.selectedModel isEqualToString:@"dall-e-3"];
    if (isImageModel) {
        if (!self.lastImageLocalPath.length) {
            NSString *persisted = [[NSUserDefaults standardUserDefaults]
                                   stringForKey:@"lastImageLocalPath"];
            if (persisted.length > 0 &&
                [[NSFileManager defaultManager] fileExistsAtPath:persisted]) {
                self.lastImageLocalPath = persisted;
            }
        }
        BOOL hasLocal = self.lastImageLocalPath.length > 0;

        [self classifyImageIntent:text hasLocalImage:hasLocal apiKey:apiKey
                       completion:^(NSString *intent) {
            self.sendButton.enabled = YES;
            if ([intent isEqualToString:@"reopen"] && hasLocal) {
                EZLogf(EZLogLevelInfo, @"IMAGE", @"Intent=reopen → %@",
                       self.lastImageLocalPath.lastPathComponent);
                [self appendToChat:@"[System: Reopening last image ✓]"];
                [self offerToOpenLocalFile:self.lastImageLocalPath];
            } else if ([intent isEqualToString:@"edit"] && hasLocal) {
                EZLogf(EZLogLevelInfo, @"IMAGE", @"Intent=edit → switching to edit mode");
                self.selectedModel = @"gpt-image-1-edit";
                [self.modelButton setTitle:@"Model: gpt-image-1 (edit mode)"
                                  forState:UIControlStateNormal];
                NSString *editPath = self.pendingImagePath ?: self.lastImageLocalPath;
                self.pendingImagePath = nil;
                [self callImageEdit:text imagePath:editPath];
            } else {
                EZLogf(EZLogLevelInfo, @"IMAGE", @"Intent=generate");
                if ([self isGptImage1Family:self.selectedModel] ||
                    [self.selectedModel isEqualToString:@"gpt-image-1-edit"]) {
                    [self callGptImage1:text];
                } else {
                    if (self.lastImagePrompt.length > 0) {
                        [self fetchRelevantMemories:text apiKey:apiKey
                                        completion:^(NSString *memories) {
                            analyzePromptForContext(text, memories, apiKey,
                                                   self.activeThread.threadID,
                            ^(EZContextResult *result) {
                                NSString *finalPrompt = text;
                                if (result.tier >= EZRoutingTierMemory) {
                                    finalPrompt = [NSString stringWithFormat:
                                        @"Previous image prompt was: \"%@\". Now create: %@",
                                        self.lastImagePrompt, text];
                                    [self appendToChat:@"[System: Previous image context included ✓]"];
                                }
                                [self callDalle3:finalPrompt];
                            });
                        }];
                    } else {
                        [self callDalle3:text];
                    }
                }
            }
        }];
        return;
    }

    // ── Sora ──────────────────────────────────────────────────────────────────
    if ([self.selectedModel hasPrefix:@"sora-"]) {
        [self callSora:fullPrompt];
        return;
    }

    // ── Chat / reasoning models ───────────────────────────────────────────────
    [self fetchRelevantMemories:text apiKey:apiKey completion:^(NSString *memories) {
        analyzePromptForContext(text, memories, apiKey, self.activeThread.threadID,
        ^(EZContextResult *result) {
            self.sendButton.enabled = YES;
            EZLogf(EZLogLevelInfo, @"SEND",
                   @"Tier %ld — conf=%.2f tokens≈%ld reason: %@",
                   (long)result.tier, result.confidence,
                   (long)result.estimatedTokens, result.reason);

            if (result.tier == EZRoutingTierDirect && result.shortCircuitAnswer.length > 0) {
                NSString *answer = result.shortCircuitAnswer;
                self.lastAIResponse = answer;
                [self.chatContext addObject:@{@"role": @"assistant", @"content": answer}];
                [self appendToChat:[NSString stringWithFormat:@"AI: %@", answer]];
                [self appendToChat:@"[System: Answered directly by helper model ⚡]"];
                EZLogf(EZLogLevelInfo, @"SEND", @"Tier 1 direct answer displayed");

                NSMutableArray *attachmentsAtSend = [NSMutableArray array];
                if (self.pendingImagePath.length > 0) {
                    [attachmentsAtSend addObject:self.pendingImagePath];
                }
                self.pendingImagePath = nil;

                createMemoryFromCompletion(text, answer, apiKey,
                                           self.activeThread.threadID,
                                           attachmentsAtSend,
                                           ^(NSString *entry) {
                    if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved: %lu chars",
                                      (unsigned long)entry.length);
                });
                [self saveActiveThread];
                return;
            }

            if (result.tier == EZRoutingTierFullHistory &&
                result.injectedHistory.count > 0) {
                if (self.chatContext.count > 0) [self.chatContext removeLastObject];
                NSMutableArray *rebuilt = [NSMutableArray array];
                [rebuilt addObjectsFromArray:result.injectedHistory];
                [rebuilt addObjectsFromArray:self.chatContext];
                [rebuilt addObject:@{@"role": @"user", @"content": result.finalPrompt}];
                self.chatContext = rebuilt;
                [self appendToChat:@"[System: Full chat history injected ✓]"];
            } else if (result.tier >= EZRoutingTierMemory) {
                if (self.chatContext.count > 0) [self.chatContext removeLastObject];
                [self.chatContext addObject:@{@"role": @"user",
                                              @"content": result.finalPrompt}];
                [self appendToChat:@"[System: Memory context included ✓]"];
            }

            [self callChatCompletions];
        });
    }];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Memory Search
// ─────────────────────────────────────────────────────────────────────────────

- (void)fetchRelevantMemories:(NSString *)prompt
                       apiKey:(NSString *)apiKey
                   completion:(void (^)(NSString *memories))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *memories = @"";

        NSString *all = loadMemoryContext(0);
        NSInteger entryCount = 0;
        if (all.length > 0) {
            for (NSString *line in [all componentsSeparatedByString:@"\n"]) {
                if ([line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0) entryCount++;
            }
        }

        if (entryCount >= 5 && apiKey.length > 0) {
            EZLogf(EZLogLevelInfo, @"MEMORY", @"Semantic search over %ld entries for: %@",
                   (long)entryCount, prompt);
            NSString *searched = EZThreadSearchMemory(prompt, apiKey);
            memories = searched.length > 0 ? searched : loadMemoryContext(15);
            EZLogf(EZLogLevelInfo, @"MEMORY", @"Search returned %lu chars",
                   (unsigned long)memories.length);
        } else if (entryCount > 0) {
            memories = loadMemoryContext(15);
            EZLogf(EZLogLevelInfo, @"MEMORY", @"Using recency (%ld entries)", (long)entryCount);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(memories);
        });
    });
}

- (void)callChatCompletions {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    if (!apiKey) { [self appendToChat:@"[Error: No API Key]"]; return; }

    BOOL isGPT5          = [self.selectedModel hasPrefix:@"gpt-5"];
    NSSet *webSearchCompatible = [NSSet setWithObjects:
        @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo",
        @"gpt-5", @"gpt-5-mini", @"gpt-5-pro", nil];
    BOOL modelSupportsWebSearch = isGPT5 || [webSearchCompatible containsObject:self.selectedModel];
    BOOL useWebSearch    = self.webSearchEnabled && modelSupportsWebSearch;
    BOOL useResponsesAPI = isGPT5 || useWebSearch;

    if (self.webSearchEnabled && !modelSupportsWebSearch) {
        [self appendToChat:[NSString stringWithFormat:
            @"[System: Web search skipped — not supported by %@. "
             "Switch to gpt-4o or a gpt-5 model to use web search.]",
            self.selectedModel]];
        EZLogf(EZLogLevelWarning, @"WEBSEARCH",
               @"Skipped — model %@ doesn't support Responses API tools", self.selectedModel);
    }

    NSString *endpointStr = useResponsesAPI
        ? @"https://api.openai.com/v1/responses"
        : @"https://api.openai.com/v1/chat/completions";

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:endpointStr]];
    request.HTTPMethod = @"POST";
    if (isGPT5 && useWebSearch)       request.timeoutInterval = 240;
    else if (isGPT5)                  request.timeoutInterval = 180;
    else                              request.timeoutInterval = 90;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
   forHTTPHeaderField:@"Authorization"];

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"model"] = self.selectedModel;
    NSString *sys  = [defaults stringForKey:@"systemMessage"];

    NSArray *cleanContext = [self sanitizedContextForAPI:self.chatContext
                                           modelSupportsVision:[self modelSupportsVision:self.selectedModel]
                                               useResponsesAPI:useResponsesAPI];

    if (useResponsesAPI) {
        if (sys.length > 0) body[@"instructions"] = sys;
        body[@"input"] = cleanContext;
        if (useWebSearch) {
            NSString *loc = [defaults stringForKey:@"webSearchLocation"] ?: @"";
            NSMutableDictionary *webTool = [@{@"type": @"web_search_preview"} mutableCopy];
            if (loc.length > 0) webTool[@"user_location"] = @{@"type":@"approximate",@"city":loc};
            body[@"tools"] = @[webTool];
            EZLog(EZLogLevelInfo, @"WEBSEARCH", @"Tool attached");
        }
    } else {
        float temp = [defaults floatForKey:@"temperature"];
        body[@"temperature"]       = @(temp > 0 ? temp : 0.7);
        body[@"frequency_penalty"] = @([defaults floatForKey:@"frequency"]);
        NSMutableArray *messages   = [NSMutableArray array];
        if (sys.length > 0) [messages addObject:@{@"role":@"system",@"content":sys}];
        [messages addObjectsFromArray:cleanContext];
        body[@"messages"] = messages;
    }

    NSError *bodyErr;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyErr];
    if (bodyErr) { [self handleAPIError:@"Failed to build request"]; return; }
    request.HTTPBody = bodyData;

    // ── Token estimation from actual assembled payload ────────────────────────
    // Input tokens: payload byte length / 4 (UTF-8 chars ≈ tokens for English).
    // Output estimate: 800 tokens for standard models, 1500 for GPT-5 (tends
    // toward longer reasoning responses). These are conservative — any overage
    // gets refunded after the real usage comes back from the API.
    NSInteger inputTokenEstimate  = (NSInteger)(bodyData.length / 4);
    NSInteger outputTokenEstimate = isGPT5 ? 1500 : 800;
    NSInteger totalTokenEstimate  = inputTokenEstimate + outputTokenEstimate;

    // Map selected model to entitlement tier string
    NSString *featureTier;
    if (isGPT5 || [self.selectedModel hasPrefix:@"o1"] || [self.selectedModel hasPrefix:@"o3"]) {
        featureTier = @"chat_premium";
    } else if ([self.selectedModel isEqualToString:@"gpt-4o-mini"] ||
               [self.selectedModel isEqualToString:@"gpt-4.1-mini"] ||
               [self.selectedModel isEqualToString:@"gpt-4o-mini-2024-07-18"]) {
        featureTier = @"chat_mini";
    } else {
        featureTier = @"chat_standard";
    }

    EZLogf(EZLogLevelInfo, @"COINS",
           @"Token estimate: input=%ld output=%ld total=%ld tier=%@",
           (long)inputTokenEstimate, (long)outputTokenEstimate,
           (long)totalTokenEstimate, featureTier);

    // Check entitlement and deduct estimated coins before firing the API call.
    NSString *capturedPrompt   = self.lastUserPrompt;
    NSString *capturedThreadID = self.activeThread.threadID;
    NSMutableArray *capturedAttachments = [NSMutableArray array];
    if (self.pendingImagePath.length > 0) {
        [capturedAttachments addObject:self.pendingImagePath];
    }
    self.pendingImagePath = nil;

    EZLogf(EZLogLevelInfo, @"API", @"→ %@ [%@]%@",
           endpointStr, self.selectedModel, useWebSearch ? @" +web" : @"");
    if (isGPT5) { dispatch_async(dispatch_get_main_queue(), ^{ [self showGPT5StatusBanner]; }); }

    [[EZEntitlementManager shared] checkEntitlementForFeature:EZFeatureChatMini
                                                  estimatedTokens:totalTokenEstimate
                                                      featureTier:featureTier
                                                           prompt:capturedPrompt
                                                            model:self.selectedModel
                                                       completion:^(BOOL allowed,
                                                                    NSInteger balance,
                                                                    NSString *reason) {
        if (!allowed) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideGPT5StatusBanner];
                if ([reason isEqualToString:@"Not logged in"]) {
                    [self appendToChat:@"[Error: Please sign in to use EZCompleteUI]"];
                } else if ([reason isEqualToString:@"Insufficient coins"] ||
                           [reason isEqualToString:@"No account found"]) {
                    [self presentCoinStoreForFeature:featureTier];
                } else {
                    [self appendToChat:[NSString stringWithFormat:
                        @"[Error: %@]", reason ?: @"Access denied"]];
                }
            });
            return;
        }

        [self fireAPIRequest:request
                 featureTier:featureTier
            estimatedTokens:totalTokenEstimate
             capturedPrompt:capturedPrompt
           capturedThreadID:capturedThreadID
        capturedAttachments:capturedAttachments
                     apiKey:apiKey
             useResponsesAPI:useResponsesAPI
                     isGPT5:isGPT5];
    }];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Fire API Request (after entitlement check passes)
// ─────────────────────────────────────────────────────────────────────────────

- (void)fireAPIRequest:(NSMutableURLRequest *)request
           featureTier:(NSString *)featureTier
       estimatedTokens:(NSInteger)estimatedTokens
        capturedPrompt:(NSString *)capturedPrompt
      capturedThreadID:(NSString *)capturedThreadID
   capturedAttachments:(NSArray *)capturedAttachments
                apiKey:(NSString *)apiKey
       useResponsesAPI:(BOOL)useResponsesAPI
               isGPT5:(BOOL)isGPT5 {

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self hideGPT5StatusBanner]; });
            [self handleAPIError:error.localizedDescription]; return;
        }

        NSError *jsonErr;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr || !jsonObj || [jsonObj isKindOfClass:[NSNull class]]) {
            [self handleAPIError:@"Could not parse API response"]; return;
        }
        NSDictionary *json = jsonObj;

        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id msg = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(msg && ![msg isKindOfClass:[NSNull class]])
                ? (NSString *)msg : @"Unknown API error"];
            return;
        }

        // ── Parse actual token usage and refund overage ───────────────────────
        NSInteger actualTokens = 0;
        id usageObj = json[@"usage"];
        if (usageObj && ![usageObj isKindOfClass:[NSNull class]]) {
            id total = ((NSDictionary *)usageObj)[@"total_tokens"];
            if (total && ![total isKindOfClass:[NSNull class]]) {
                actualTokens = [total integerValue];
            }
        }
        if (actualTokens > 0 && estimatedTokens > 0) {
            EZLogf(EZLogLevelInfo, @"COINS",
                   @"Actual tokens=%ld estimated=%ld",
                   (long)actualTokens, (long)estimatedTokens);
            [[EZEntitlementManager shared] refundTokensForTier:featureTier
                                               estimatedTokens:estimatedTokens
                                                  actualTokens:actualTokens];
        }

        NSString *reply = nil;
        if (useResponsesAPI) {
            id outputObj = json[@"output"];
            if (outputObj && ![outputObj isKindOfClass:[NSNull class]]) {
                for (id item in (NSArray *)outputObj) {
                    if ([item isKindOfClass:[NSNull class]]) continue;
                    NSDictionary *d = item;
                    if (![[d[@"type"] description] isEqualToString:@"message"]) continue;
                    id contentArr = d[@"content"];
                    if (!contentArr || [contentArr isKindOfClass:[NSNull class]]) continue;
                    for (id block in (NSArray *)contentArr) {
                        if ([block isKindOfClass:[NSNull class]]) continue;
                        NSDictionary *b = block;
                        if (![[b[@"type"] description] isEqualToString:@"output_text"]) continue;
                        id t = b[@"text"];
                        if (t && ![t isKindOfClass:[NSNull class]]) { reply = (NSString *)t; break; }
                    }
                    if (reply) break;
                }
            }
        } else {
            id choicesObj = json[@"choices"];
            if (choicesObj && ![choicesObj isKindOfClass:[NSNull class]]
                && [(NSArray *)choicesObj count] > 0) {
                id first = ((NSArray *)choicesObj)[0];
                if (first && ![first isKindOfClass:[NSNull class]]) {
                    id msgObj = ((NSDictionary *)first)[@"message"];
                    if (msgObj && ![msgObj isKindOfClass:[NSNull class]]) {
                        id c = ((NSDictionary *)msgObj)[@"content"];
                        if (c && ![c isKindOfClass:[NSNull class]]) reply = (NSString *)c;
                    }
                }
            }
        }

        if (!reply.length) {
            EZLogf(EZLogLevelError, @"API", @"No reply. Raw: %@", json);
            [self handleAPIError:@"Unexpected response format"]; return;
        }
        EZLogf(EZLogLevelInfo, @"API", @"Reply %lu chars", (unsigned long)reply.length);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self hideGPT5StatusBanner];
            self.lastAIResponse = reply;
            [self.chatContext addObject:@{@"role": @"assistant", @"content": reply}];

            NSMutableArray<NSString *> *codePaths = [NSMutableArray array];
            NSString *displayReply = [self processReplyWithCodeBlocks:reply savedPaths:codePaths];

            NSMutableArray *allAttachments = [capturedAttachments mutableCopy];
            for (NSString *p in codePaths) {
                if (![allAttachments containsObject:p]) [allAttachments addObject:p];
            }

            [self appendToChat:[NSString stringWithFormat:@"AI: %@", displayReply]];
            [self saveActiveThread];
            [self checkReplyForLocalFilePaths:reply];

            // Refresh coin display after refund settles
            [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
                [self updateCoinBalanceDisplay];
            }];
        });

        createMemoryFromCompletion(capturedPrompt ?: @"", reply, apiKey, capturedThreadID,
                                   capturedAttachments,
        ^(NSString *entry) {
            if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved %lu chars",
                              (unsigned long)entry.length);
        });
    }] resume];
}
// ─────────────────────────────────────────────────────────────────────────────

- (void)callDalle3:(NSString *)prompt {
    [self appendToChat:@"[System: Generating Image...]"];
    EZLog(EZLogLevelInfo, @"DALLE", @"Sending DALL-E 3 request");
    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/images/generations"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"model":@"dall-e-3", @"prompt":prompt, @"n":@1, @"size":@"1024x1024"
    } options:0 error:nil];

    NSString *savedPrompt = prompt;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (!data) { [self handleAPIError:error.localizedDescription ?: @"DALL-E failed"]; return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id m = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(m && ![m isKindOfClass:[NSNull class]]) ? m : @"DALL-E error"];
            return;
        }
        id dataArr = json[@"data"];
        if (!dataArr || [dataArr isKindOfClass:[NSNull class]] || [(NSArray *)dataArr count] == 0) {
            [self handleAPIError:@"No image in response"]; return;
        }
        id imgObj = ((NSArray *)dataArr)[0];
        id imgURL = ([imgObj isKindOfClass:[NSDictionary class]]) ? imgObj[@"url"] : nil;
        if (!imgURL || [imgURL isKindOfClass:[NSNull class]]) {
            [self handleAPIError:@"No image URL"]; return;
        }
        EZLog(EZLogLevelInfo, @"DALLE", @"Image URL received");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastImagePrompt = savedPrompt;
        });
        [self downloadAndSaveImage:(NSString *)imgURL purpose:@"dalle"];
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - gpt-image-1 Text-to-Image Generation
// ─────────────────────────────────────────────────────────────────────────────

- (void)callGptImage1:(NSString *)prompt {
    [self appendToChat:@"[System: Generating image with gpt-image-1...]"];
    EZLog(EZLogLevelInfo, @"GPTIMAGE", @"Sending generation request");
    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/images/generations"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 120;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    NSUserDefaults *imgDefaults = [NSUserDefaults standardUserDefaults];
    NSString *imgSize    = [imgDefaults stringForKey:@"imgSize"]    ?: @"1024x1024";
    NSString *imgQuality = [imgDefaults stringForKey:@"imgQuality"] ?: @"auto";
    NSString *imgFormat  = [imgDefaults stringForKey:@"imgFormat"]  ?: @"png";
    NSString *imgBg      = [imgDefaults stringForKey:@"imgBackground"] ?: @"auto";
    
    // Use the actual selected model so gpt-image-1.5, -mini, chatgpt-image-latest all work
    NSString *imgModel   = self.selectedModel;
    if ([imgModel isEqualToString:@"gpt-image-1-edit"]) imgModel = @"gpt-image-1";
    NSInteger imgN = [[NSUserDefaults standardUserDefaults] integerForKey:@"imgVariations"];
    if (imgN < 1 || imgN > 4) imgN = 1;
    NSMutableDictionary *imgParams = [@{
        @"model":           imgModel,
        @"prompt":          prompt,
        @"n":               @(imgN),
        @"size":            imgSize,
        @"quality":         imgQuality,
        @"output_format":   imgFormat
    } mutableCopy];

    // background is only valid when output_format supports transparency (png/webp).
    // Skip it when format is jpeg to avoid an API error.
    if (![imgFormat isEqualToString:@"jpeg"]) {
        imgParams[@"background"] = imgBg;
    }
    // NOTE: "moderation" is NOT a valid parameter for the generations endpoint —
    // it is edits-only. Removed entirely.

    // output_format=png always returns b64_json for gpt-image-1 family.
    // Request b64 explicitly so we can save directly without a second download.
    //imgParams[@"response_format"] = @"b64_json";
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:imgParams options:0 error:nil];

    NSString *savedPrompt = prompt;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (!data) { [self handleAPIError:error.localizedDescription ?: @"gpt-image-1 request failed"]; return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        // Sanitized log — never dump b64 image data into the log
        NSMutableDictionary *logJson = [json mutableCopy];
        if ([logJson[@"data"] isKindOfClass:[NSArray class]]) {
            NSMutableArray *sanitized = [NSMutableArray array];
            for (NSDictionary *item in logJson[@"data"]) {
                NSMutableDictionary *s = [item mutableCopy];
                if (s[@"b64_json"]) s[@"b64_json"] = [NSString stringWithFormat:@"<b64 %lu bytes>", (unsigned long)[(NSString *)s[@"b64_json"] length]];
                [sanitized addObject:s];
            }
            logJson[@"data"] = sanitized;
        }
        EZLogf(EZLogLevelDebug, @"GPTIMAGE", @"Response: %@", logJson);
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id m = ((NSDictionary *)errObj)[@"message"];
            NSString *errMsg = (m && ![m isKindOfClass:[NSNull class]]) ? m : @"gpt-image-1 error";
            [self handleAPIError:errMsg];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendImageGridToChat:@[] prompt:savedPrompt isError:YES errorText:errMsg];
            });
            return;
        }
        id dataArr = json[@"data"];
        if (!dataArr || [dataArr isKindOfClass:[NSNull class]] || [(NSArray *)dataArr count] == 0) {
            NSString *errMsg = @"No image in response";
            [self handleAPIError:errMsg];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendImageGridToChat:@[] prompt:savedPrompt isError:YES errorText:errMsg];
            });
            return;
        }
        // Collect all returned images (n variations)
        NSMutableArray<NSString *> *savedPaths = [NSMutableArray array];
        for (NSDictionary *imgObj in (NSArray *)dataArr) {
            NSString *imgURL = [imgObj isKindOfClass:[NSDictionary class]] ? imgObj[@"url"]      : nil;
            NSString *b64    = [imgObj isKindOfClass:[NSDictionary class]] ? imgObj[@"b64_json"] : nil;
            if (b64 && ![b64 isKindOfClass:[NSNull class]]) {
                NSData *imgData = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
                if (imgData) {
                    NSString *fname = [NSString stringWithFormat:@"gptimage_%lu.png",
                                      (unsigned long)savedPaths.count + 1];
                    NSString *path = EZAttachmentSave(imgData, fname);
                    if (path) [savedPaths addObject:path];
                }
            } else if (imgURL && ![imgURL isKindOfClass:[NSNull class]]) {
                // URL-format: download synchronously on this background thread
                NSData *imgData = [NSData dataWithContentsOfURL:[NSURL URLWithString:imgURL]];
                if (imgData) {
                    NSString *fname = [NSString stringWithFormat:@"gptimage_%lu.png",
                                      (unsigned long)savedPaths.count + 1];
                    NSString *path = EZAttachmentSave(imgData, fname);
                    if (path) [savedPaths addObject:path];
                }
            }
        }
        NSString *firstPath = savedPaths.firstObject;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastImagePrompt = savedPrompt;
            if (firstPath) {
                self.lastImageLocalPath = firstPath;
                self.activeThread.lastImageLocalPath = firstPath;
                NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
                [att addObjectsFromArray:savedPaths];
                self.activeThread.attachmentPaths = [att copy];
                [self saveActiveThread];
                [self persistImagePath:firstPath prompt:savedPrompt];
            }
            if (savedPaths.count > 0) {
                [self appendImageGridToChat:[savedPaths copy]
                                     prompt:savedPrompt
                                    isError:NO
                                  errorText:nil];
                [[EZEntitlementManager shared]
                    completeUsageLogWithImagesReturned:(NSInteger)savedPaths.count
                                            errorText:nil];
            } else {
                NSString *errMsg = @"Image generated but could not be saved.";
                [self appendImageGridToChat:@[]
                                     prompt:savedPrompt
                                    isError:YES
                                  errorText:errMsg];
                [[EZEntitlementManager shared]
                    completeUsageLogWithImagesReturned:0
                                            errorText:errMsg];
            }
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Edit (gpt-image-1)
// ─────────────────────────────────────────────────────────────────────────────

- (void)callImageEdit:(NSString *)prompt imagePath:(NSString *)imagePath {
    if (!imagePath) {
        self.sendButton.enabled = YES;
        [self appendToChat:@"[Error: No image attached for editing]"]; return;
    }
    [self appendToChat:@"[System: Editing image with gpt-image-1...]"];
    EZLog(EZLogLevelInfo, @"IMGEDIT", @"Sending image edit request");

    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    NSData *imageData = [NSData dataWithContentsOfFile:imagePath]
                     ?: [NSData dataWithContentsOfURL:[NSURL fileURLWithPath:imagePath]];
    if (!imageData) {
        self.sendButton.enabled = YES;
        [self appendToChat:@"[Error: Could not read image for editing]"]; return;
    }

    UIImage *img = [UIImage imageWithData:imageData];
    if (!img) { self.sendButton.enabled = YES; [self appendToChat:@"[Error: Could not decode image for editing]"]; return; }
    NSData *pngData = UIImagePNGRepresentation(img);
    if (!pngData) { self.sendButton.enabled = YES; [self appendToChat:@"[Error: Could not convert image to PNG]"]; return; }
    EZLogf(EZLogLevelInfo, @"IMGEDIT", @"PNG ready: %lu bytes", (unsigned long)pngData.length);

    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/images/edits"]];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 120;
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
       forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
       forHTTPHeaderField:@"Authorization"];

    NSMutableData *body = [NSMutableData data];

    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"model\"\r\n\r\ngpt-image-1\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"image\"; filename=\"image.png\"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: image/png\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:pngData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"prompt\"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[prompt dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    NSUserDefaults *editDefaults = [NSUserDefaults standardUserDefaults];
    NSString *editSize   = [editDefaults stringForKey:@"imgSize"]       ?: @"1024x1024";
    NSString *editQual   = [editDefaults stringForKey:@"imgQuality"]    ?: @"auto";
    NSString *editFmt    = [editDefaults stringForKey:@"imgFormat"]     ?: @"png";
    NSString *editBg     = [editDefaults stringForKey:@"imgBackground"] ?: @"auto";
    NSString *editModeration = [editDefaults stringForKey:@"imgModeration"] ?: @"low";

    // Helper block to append a form field
    void (^addField)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
        [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary]
                         dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:
            @"Content-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", name, value]
            dataUsingEncoding:NSUTF8StringEncoding]];
    };
    NSInteger editN = [[NSUserDefaults standardUserDefaults] integerForKey:@"imgVariations"];
    if (editN < 1 || editN > 4) editN = 1;
    addField(@"n",             [NSString stringWithFormat:@"%ld", (long)editN]);
    addField(@"size",          editSize);
    addField(@"quality",       editQual);
    addField(@"output_format", editFmt);
    addField(@"background",    editBg);
    addField(@"moderation",    editModeration);
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary]
                     dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    EZLogf(EZLogLevelInfo, @"IMGEDIT", @"Sending — prompt: %@", prompt);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (!data) { [self handleAPIError:error.localizedDescription ?: @"Image edit failed"]; return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        // Log sanitized response — never dump b64 image data into the log
        NSMutableDictionary *logJson = [json mutableCopy];
        if ([logJson[@"data"] isKindOfClass:[NSArray class]]) {
            NSMutableArray *sanitized = [NSMutableArray array];
            for (NSDictionary *item in logJson[@"data"]) {
                NSMutableDictionary *s = [item mutableCopy];
                if (s[@"b64_json"]) s[@"b64_json"] = [NSString stringWithFormat:@"<b64 %lu bytes>", (unsigned long)[(NSString *)s[@"b64_json"] length]];
                [sanitized addObject:s];
            }
            logJson[@"data"] = sanitized;
        }
        EZLogf(EZLogLevelDebug, @"IMGEDIT", @"Response: %@", logJson);
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id m = ((NSDictionary *)errObj)[@"message"];
            NSString *errMsg = (m && ![m isKindOfClass:[NSNull class]]) ? m : @"Image edit error";
            [self handleAPIError:errMsg];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendImageGridToChat:@[] prompt:prompt isError:YES errorText:errMsg];
            });
            return;
        }
        id dataArr = json[@"data"];
        if (!dataArr || [dataArr isKindOfClass:[NSNull class]] || [(NSArray *)dataArr count] == 0) {
            NSString *errMsg = @"No image in edit response";
            [self handleAPIError:errMsg];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendImageGridToChat:@[] prompt:prompt isError:YES errorText:errMsg];
            });
            return;
        }
        // Collect all returned edit images
        NSMutableArray<NSString *> *savedPaths = [NSMutableArray array];
        for (NSDictionary *imgObj in (NSArray *)dataArr) {
            NSString *imgURL = [imgObj isKindOfClass:[NSDictionary class]] ? imgObj[@"url"]      : nil;
            NSString *b64    = [imgObj isKindOfClass:[NSDictionary class]] ? imgObj[@"b64_json"] : nil;
            NSData *imgData = nil;
            if (b64 && ![b64 isKindOfClass:[NSNull class]]) {
                imgData = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
            } else if (imgURL && ![imgURL isKindOfClass:[NSNull class]]) {
                imgData = [NSData dataWithContentsOfURL:[NSURL URLWithString:imgURL]];
            }
            if (imgData) {
                NSString *fname = [NSString stringWithFormat:@"edit_%lu.png",
                                  (unsigned long)savedPaths.count + 1];
                NSString *path = EZAttachmentSave(imgData, fname);
                if (path) [savedPaths addObject:path];
            }
        }
        NSString *firstPath = savedPaths.firstObject;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastImagePrompt = prompt;
            self.selectedModel   = @"gpt-image-1-edit";
            [self.modelButton setTitle:@"Model: gpt-image-1 (edit mode)" forState:UIControlStateNormal];
            [self appendToChat:@"[System: Edit complete — still in edit mode. Attach a new image or type another edit prompt.]"];
            if (firstPath) {
                self.lastImageLocalPath = firstPath;
                self.activeThread.lastImageLocalPath = firstPath;
                NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
                [att addObjectsFromArray:savedPaths];
                self.activeThread.attachmentPaths = [att copy];
                [self saveActiveThread];
                [self persistImagePath:firstPath prompt:prompt];
            }
            if (savedPaths.count > 0) {
                [self appendImageGridToChat:[savedPaths copy]
                                     prompt:prompt
                                    isError:NO
                                  errorText:nil];
                [[EZEntitlementManager shared]
                    completeUsageLogWithImagesReturned:(NSInteger)savedPaths.count
                                            errorText:nil];
            } else {
                NSString *errMsg = @"Edit produced no image output.";
                [self appendImageGridToChat:@[]
                                     prompt:prompt
                                    isError:YES
                                  errorText:errMsg];
                [[EZEntitlementManager shared]
                    completeUsageLogWithImagesReturned:0
                                            errorText:errMsg];
            }
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sora Text-to-Video (always async job)
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Sora 2 API spec:
//   sora-2:     "seconds" param as STRING — "4" | "8" | "12" | "16"
//   sora-2-pro: "seconds" param as STRING — "5" | "10" | "15" | "20"
//   "size" param: "480p" | "720p" | "1080p"
// Endpoint: POST /v1/videos  →  async job {id, status:"queued"}
// Poll:     GET  /v1/videos/{id}
// Content:  GET  /v1/videos/{id}/content
// ─────────────────────────────────────────────────────────────────────────────

- (void)callSora:(NSString *)prompt {
    [self appendToChat:@"[System: Submitting Sora 2 video job...]"];
    EZLog(EZLogLevelInfo, @"SORA", @"Sending request");

    NSUserDefaults *d    = [NSUserDefaults standardUserDefaults];
    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];

    NSString *videoModel = [d stringForKey:@"soraModel"] ?: @"sora-2";
    NSString *resolution = [d stringForKey:@"soraSize"]  ?: @"720p";
    NSInteger rawDur     = [d integerForKey:@"soraDuration"] ?: 4;

    NSString *secondsStr;
    BOOL isPro = [videoModel isEqualToString:@"sora-2-pro"];
    if (isPro) {
        NSArray<NSNumber *> *valid = @[@5, @10, @15, @20];
        NSInteger best = 5, bestDiff = NSIntegerMax;
        for (NSNumber *v in valid) {
            NSInteger diff = ABS(rawDur - v.integerValue);
            if (diff < bestDiff) { bestDiff = diff; best = v.integerValue; }
        }
        secondsStr = [NSString stringWithFormat:@"%ld", (long)best];
    } else {
        NSArray<NSNumber *> *valid = @[@4, @8, @12, @16];
        NSInteger best = 4, bestDiff = NSIntegerMax;
        for (NSNumber *v in valid) {
            NSInteger diff = ABS(rawDur - v.integerValue);
            if (diff < bestDiff) { bestDiff = diff; best = v.integerValue; }
        }
        secondsStr = [NSString stringWithFormat:@"%ld", (long)best];
    }

    NSArray<NSString *> *validRes = @[@"1280x720", @"720x1280", @"1024x1792", @"1792x1024"];
    if (![validRes containsObject:resolution]) {
        NSDictionary *resMap = @{
            @"480p":   @"1280x720",
            @"720p":   @"1280x720",
            @"1080p":  @"1792x1024",
            @"portrait": @"720x1280",
            @"landscape": @"1280x720",
            @"480x270":  @"1280x720",
            @"1280x720": @"1280x720",
            @"1920x1080":@"1792x1024"
        };
        resolution = resMap[resolution] ?: @"1280x720";
    }

    if (rawDur != secondsStr.integerValue) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:[NSString stringWithFormat:
                @"[System: Duration snapped to %@s (valid for %@)]",
                secondsStr, videoModel]];
        });
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/videos"]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    NSError *bodyErr;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"model":   videoModel,
        @"prompt":  prompt,
        @"size":    resolution,
        @"seconds": secondsStr
    } options:0 error:&bodyErr];
    if (bodyErr) { [self handleAPIError:@"Failed to build Sora request"]; return; }

    EZLogf(EZLogLevelInfo, @"SORA", @"model=%@ size=%@ seconds=%@", videoModel, resolution, secondsStr);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { [self handleAPIError:error.localizedDescription]; return; }

        NSString *rawBody = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"(unreadable)";
        EZLogf(EZLogLevelDebug, @"SORA", @"Raw response: %@", rawBody);

        NSError *parseErr;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (parseErr || !jsonObj || [jsonObj isKindOfClass:[NSNull class]]) {
            EZLogf(EZLogLevelError, @"SORA", @"Parse failed. Raw: %@", rawBody);
            [self handleAPIError:@"Could not parse Sora response — check log"]; return;
        }
        NSDictionary *json = jsonObj;
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            id m = ((NSDictionary *)errObj)[@"message"];
            [self handleAPIError:(m && ![m isKindOfClass:[NSNull class]]) ? m : @"Sora error"];
            return;
        }

        NSString *jobId = nil;
        id topId = json[@"id"];
        if (topId && ![topId isKindOfClass:[NSNull class]]) jobId = (NSString *)topId;

        if (!jobId.length) {
            EZLogf(EZLogLevelError, @"SORA", @"No job ID. Full response: %@", json);
            [self handleAPIError:@"Sora returned no job ID — check log"]; return;
        }

        EZLogf(EZLogLevelInfo, @"SORA", @"Job created: %@  status: %@", jobId, json[@"status"] ?: @"?");

        // Only persist the job ID — never store the API key in NSUserDefaults.
        // On resume, the key is reloaded from EZKeyVault (Keychain).
        [[NSUserDefaults standardUserDefaults] setObject:jobId forKey:@"soraActivejobId"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:[NSString stringWithFormat:
                @"[Sora: Job queued (%@) — polling for completion...]", jobId]];
        });
        [self pollSoraJob:jobId apiKey:apiKey];
    }] resume];
}

- (void)pollSoraJob:(NSString *)jobId apiKey:(NSString *)apiKey {
    __block NSInteger attempts = 0;
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    __block __weak void (^weakPoll)(void);
    void (^poll)(void);
    poll = ^{
        void (^strongPoll)(void) = weakPoll;
        if (!strongPoll) return;
        attempts++;
        if (attempts > 36) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[Sora: Generation is taking unusually long. "
                 "Check platform.openai.com/storage for your video.]"];
            });
            return;
        }
        NSTimeInterval delay = (attempts <= 6) ? 5.0 : 10.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), q, ^{
            NSString *pollURL = [NSString stringWithFormat:@"https://api.openai.com/v1/videos/%@", jobId];
            NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:pollURL]];
            r.HTTPMethod = @"GET";
            [r setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

            [[[NSURLSession sharedSession] dataTaskWithRequest:r
                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                void (^s)(void) = weakPoll;
                if (!data || err) { if (s) s(); return; }

                id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (!j || [j isKindOfClass:[NSNull class]]) { if (s) s(); return; }
                NSDictionary *jd = j;
                NSString *status = jd[@"status"] ?: @"";
                EZLogf(EZLogLevelInfo, @"SORA", @"Poll %ld — status: %@", (long)attempts, status);

                static NSString *lastShownStatus = nil;
                if (![status isEqualToString:lastShownStatus]) {
                    lastShownStatus = [status copy];
                    NSString *emoji = [status isEqualToString:@"queued"]     ? @"⏳" :
                                      [status isEqualToString:@"processing"] ? @"⚙️" :
                                      ([status isEqualToString:@"completed"] ||
                                       [status isEqualToString:@"succeeded"] ||
                                       [status isEqualToString:@"ready"])    ? @"✅" :
                                      ([status isEqualToString:@"failed"] ||
                                       [status isEqualToString:@"error"])    ? @"❌" : @"🔄";
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self appendToChat:[NSString stringWithFormat:@"[Sora: %@ %@]", emoji, status]];
                    });
                }

                if ([status isEqualToString:@"failed"] || [status isEqualToString:@"error"]) {
                    id errDetail = jd[@"error"];
                    NSString *msg = (errDetail && ![errDetail isKindOfClass:[NSNull class]])
                        ? [errDetail description] : @"Video generation failed";
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"soraActivejobId"];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self appendToChat:[NSString stringWithFormat:@"[Sora failed: %@]", msg]];
                    });
                    return;
                }

                BOOL done = ([status isEqualToString:@"completed"] ||
                             [status isEqualToString:@"succeeded"] ||
                             [status isEqualToString:@"ready"]);
                if (done) {
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"soraActivejobId"];
                    EZLogf(EZLogLevelInfo, @"SORA", @"Job complete — fetching content");
                    [self fetchSoraContent:jobId apiKey:apiKey];
                    return;
                }

                if (s) s();
            }] resume];
        });
    };
    weakPoll = poll;
    poll();
}

- (void)resumePendingSoraJobIfNeeded {
    if (!self.isViewLoaded || !self.view.window) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *jobId   = [d stringForKey:@"soraActivejobId"];
    // CHANGED: reload key from EZKeyVault — never stored in NSUserDefaults
    NSString *apiKey  = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];
    if (!jobId.length || !apiKey.length) return;
    EZLogf(EZLogLevelInfo, @"SORA", @"Resuming poll for job: %@", jobId);
    [self appendToChat:[NSString stringWithFormat:
        @"[Sora: Resuming poll for job %@...]", jobId]];
    [self pollSoraJob:jobId apiKey:apiKey];
}

- (void)fetchSoraContent:(NSString *)jobId apiKey:(NSString *)apiKey {
    NSString *contentURL = [NSString stringWithFormat:
        @"https://api.openai.com/v1/videos/%@/content", jobId];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:contentURL]];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { [self handleAPIError:error.localizedDescription]; return; }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        EZLogf(EZLogLevelInfo, @"SORA", @"Content fetch HTTP %ld, %lu bytes",
               (long)http.statusCode, (unsigned long)data.length);

        if (http.statusCode == 200 && data.length > 10000) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *savedPath = EZAttachmentSave(data, @"sora_video.mp4");
                NSURL *tmp = [NSURL fileURLWithPath:
                    [NSTemporaryDirectory() stringByAppendingPathComponent:@"sora_gen.mp4"]];
                [data writeToURL:tmp atomically:YES];
                if (savedPath) {
                    self.activeThread.lastVideoLocalPath = savedPath;
                    [self saveActiveThread];
                }
                [self appendToChat:@"[Sora: Video ready \u2713]"];
                // Present immediately if visible; defer to viewWillAppear if backgrounded
                if (self.view.window) {
                    self.previewURL = tmp;
                    QLPreviewController *ql = [[QLPreviewController alloc] init];
                    ql.dataSource = self;
                    [self presentViewController:ql animated:YES completion:nil];
                    EZLog(EZLogLevelInfo, @"SORA", @"Video saved and presented");
                } else {
                    self.pendingVideoURL = tmp;
                    EZLog(EZLogLevelInfo, @"SORA", @"Video saved — deferred (app backgrounded)");
                }
            });
            return;
        }

        NSError *parseErr;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (!parseErr && jsonObj && ![jsonObj isKindOfClass:[NSNull class]]) {
            NSDictionary *json = jsonObj;
            EZLogf(EZLogLevelDebug, @"SORA", @"Content JSON: %@", json);
            id urlObj = json[@"url"] ?: json[@"download_url"] ?: json[@"video_url"];
            if (urlObj && ![urlObj isKindOfClass:[NSNull class]]) {
                [self downloadAndShowVideo:(NSString *)urlObj]; return;
            }
        }

        NSURL *finalURL = response.URL;
        if (finalURL && ![finalURL.absoluteString containsString:@"/content"]) {
            EZLogf(EZLogLevelInfo, @"SORA", @"Following redirect to: %@", finalURL);
            [self downloadAndShowVideo:finalURL.absoluteString]; return;
        }

        [self handleAPIError:@"Could not retrieve Sora video content"];
        EZLogf(EZLogLevelError, @"SORA", @"Content fetch failed. HTTP %ld body: %@",
               (long)http.statusCode,
               [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"?");
    }] resume];
}

- (void)downloadAndShowVideo:(NSString *)urlString {
    EZLog(EZLogLevelInfo, @"SORA", @"Downloading video...");
    [[[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:urlString]
        completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
        if (!location) { [self handleAPIError:@"Video download failed"]; return; }
        NSURL *tmp = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"sora_gen.mp4"]];
        [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:location toURL:tmp error:nil];

        NSData *videoData = [NSData dataWithContentsOfURL:tmp];
        if (videoData) {
            NSString *savedPath = EZAttachmentSave(videoData, @"sora_video.mp4");
            if (savedPath) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.activeThread.lastVideoLocalPath = savedPath;
                    [self saveActiveThread];
                });
            }
        }

        EZLog(EZLogLevelInfo, @"SORA", @"Video ready");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:@"[Sora: Video ready \u2713]"];
            if (self.view.window) {
                self.previewURL = tmp;
                QLPreviewController *ql = [[QLPreviewController alloc] init];
                ql.dataSource = self;
                [self presentViewController:ql animated:YES completion:nil];
                EZLog(EZLogLevelInfo, @"SORA", @"Video presented immediately");
            } else {
                self.pendingVideoURL = tmp;
                EZLog(EZLogLevelInfo, @"SORA", @"Video deferred — app backgrounded");
            }
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Download / Save / QuickLook
// ─────────────────────────────────────────────────────────────────────────────

- (void)downloadAndSaveImage:(NSString *)urlString purpose:(NSString *)purpose {
    [[[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:urlString]
        completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
        if (!location) {
            EZLogf(EZLogLevelError, @"IMAGE", @"Download failed: %@", err.localizedDescription);
            [self handleAPIError:@"Image download failed"]; return;
        }
        NSString *tmpName = [NSString stringWithFormat:@"%@_gen.png", purpose];
        NSURL *tmp = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName]];
        [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:location toURL:tmp error:nil];

        NSData *imgData = [NSData dataWithContentsOfURL:tmp];
        NSString *savedPath = imgData ? EZAttachmentSave(imgData, tmpName) : nil;

        EZLogf(EZLogLevelInfo, @"IMAGE", @"Image saved: %@", savedPath ?: @"(temp only)");

        dispatch_async(dispatch_get_main_queue(), ^{
            if (savedPath) {
                self.lastImageLocalPath = savedPath;
                self.activeThread.lastImageLocalPath = savedPath;
                NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
                [att addObject:savedPath];
                self.activeThread.attachmentPaths = [att copy];
                [self saveActiveThread];
                [self persistImagePath:savedPath prompt:self.lastImagePrompt];
            }
            self.previewURL = tmp;
            QLPreviewController *ql = [[QLPreviewController alloc] init];
            ql.dataSource = self;
            [self presentViewController:ql animated:YES completion:nil];
            if (savedPath.length) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.7*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self offerSaveToPhotos:savedPath];});
        });
    }] resume];
}

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)c { return 1; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)c previewItemAtIndex:(NSInteger)i {
    return self.previewURL;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Whisper
// ─────────────────────────────────────────────────────────────────────────────

- (void)transcribeAudio:(NSURL *)fileURL {
    [self appendToChat:@"[System: Whisper uploading...]"];
    EZLog(EZLogLevelInfo, @"WHISPER", @"Starting transcription");
    // CHANGED: Use EZKeyVault instead of legacy NSUserDefaults @"apiKey"
    NSString *apiKey = [EZKeyVault loadKeyForIdentifier:EZVaultKeyOpenAI];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.openai.com/v1/audio/transcriptions"]];
    req.HTTPMethod = @"POST";
    NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];
    [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
       forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
       forHTTPHeaderField:@"Authorization"];
    NSMutableData *body = [NSMutableData data];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:
        @"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n",
        fileURL.lastPathComponent] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: audio/mpeg\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[NSData dataWithContentsOfURL:fileURL]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    req.HTTPBody = body;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (!data) {
            EZLogf(EZLogLevelError, @"WHISPER", @"Failed: %@", error.localizedDescription); return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *formatted = [self formatWhisperTranscript:json[@"text"]];
        EZLogf(EZLogLevelInfo, @"WHISPER", @"Done (%lu chars)", (unsigned long)formatted.length);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.messageTextField.text = formatted;
            [self appendToChat:[NSString stringWithFormat:@"[Whisper]: %@", formatted]];
        });
    }] resume];
}

- (NSString *)formatWhisperTranscript:(NSString *)raw {
    if (!raw) return @"";
    return [[[raw stringByReplacingOccurrencesOfString:@". " withString:@".\n"]
                  stringByReplacingOccurrencesOfString:@"! " withString:@"!\n"]
                  stringByReplacingOccurrencesOfString:@"? " withString:@"?\n"];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Misc
// ─────────────────────────────────────────────────────────────────────────────

/// Returns YES for any model that goes to /v1/images/generations (not chat)
- (BOOL)isGptImage1Family:(NSString *)model {
    return [model hasPrefix:@"gpt-image-"] || [model isEqualToString:@"chatgpt-image-latest"];
}

- (BOOL)modelSupportsVision:(NSString *)model {
    NSSet *vision = [NSSet setWithObjects:
        @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4",
        @"gpt-5", @"gpt-5-mini", @"gpt-5-pro",
        @"gpt-image-1", nil];
    if ([model hasPrefix:@"gpt-5"]) return YES;
    return [vision containsObject:model];
}

- (NSArray *)sanitizedContextForAPI:(NSArray *)context
                  modelSupportsVision:(BOOL)supportsVision
                      useResponsesAPI:(BOOL)useResponsesAPI {
    NSInteger lastVisionIdx = -1;
    for (NSInteger i = (NSInteger)context.count - 1; i >= 0; i--) {
        NSDictionary *msg = context[(NSUInteger)i];
        if ([msg[@"_isVisionAttachment"] boolValue]) {
            lastVisionIdx = i; break;
        }
        id content = msg[@"content"];
        if ([content isKindOfClass:[NSArray class]]) {
            for (NSDictionary *block in (NSArray *)content) {
                NSString *type = [block[@"type"] description];
                if ([type isEqualToString:@"image_url"] || [type isEqualToString:@"input_image"]) {
                    lastVisionIdx = i; break;
                }
            }
        }
        if (lastVisionIdx >= 0) break;
    }

    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger i = 0; i < context.count; i++) {
        NSDictionary *msg = context[i];

        NSMutableDictionary *clean = [NSMutableDictionary dictionary];
        for (NSString *key in msg) {
            if ([key hasPrefix:@"_"]) continue;
            clean[key] = msg[key];
        }

        id content = clean[@"content"];
        if ([content isKindOfClass:[NSArray class]]) {
            NSArray *blocks   = (NSArray *)content;
            BOOL     hasImage = NO;
            for (NSDictionary *b in blocks) {
                NSString *t = [b[@"type"] description];
                if ([t isEqualToString:@"image_url"] || [t isEqualToString:@"input_image"]) {
                    hasImage = YES; break;
                }
            }

            if (hasImage) {
                BOOL isLatest   = ((NSInteger)i == lastVisionIdx);
                BOOL sendInline = isLatest && supportsVision;

                if (sendInline) {
                    NSMutableArray *convertedBlocks = [NSMutableArray array];
                    for (NSDictionary *b in blocks) {
                        NSString *type = [b[@"type"] description];

                        if ([type isEqualToString:@"image_url"] || [type isEqualToString:@"input_image"]) {
                            NSString *dataURL = nil;
                            id imgUrlVal = b[@"image_url"];
                            if ([imgUrlVal isKindOfClass:[NSDictionary class]]) {
                                dataURL = ((NSDictionary *)imgUrlVal)[@"url"];
                            } else if ([imgUrlVal isKindOfClass:[NSString class]]) {
                                dataURL = (NSString *)imgUrlVal;
                            }
                            if (!dataURL) continue;

                            if (useResponsesAPI) {
                                [convertedBlocks addObject:@{@"type":@"input_image", @"image_url":dataURL}];
                            } else {
                                [convertedBlocks addObject:@{@"type":@"image_url", @"image_url":@{@"url":dataURL}}];
                            }

                        } else if ([type isEqualToString:@"text"] || [type isEqualToString:@"input_text"]) {
                            NSString *text = b[@"text"] ?: @"";
                            if ([text isEqualToString:@"[image attached — await user question]"]) continue;
                            if (useResponsesAPI) {
                                [convertedBlocks addObject:@{@"type":@"input_text", @"text":text}];
                            } else {
                                [convertedBlocks addObject:@{@"type":@"text", @"text":text}];
                            }
                        } else {
                            [convertedBlocks addObject:b];
                        }
                    }
                    if (convertedBlocks.count > 0) {
                        clean[@"content"] = [convertedBlocks copy];
                        [result addObject:clean];
                    }
                } else {
                    NSMutableString *textContent = [NSMutableString string];
                    for (NSDictionary *b in blocks) {
                        NSString *t = [b[@"type"] description];
                        if ([t isEqualToString:@"text"] || [t isEqualToString:@"input_text"]) {
                            NSString *txt = b[@"text"] ?: @"";
                            if (![txt isEqualToString:@"[image attached — await user question]"]) {
                                [textContent appendString:txt];
                            }
                        }
                    }
                    if (textContent.length == 0) [textContent appendString:@"[image attached]"];
                    [result addObject:@{
                        @"role":    clean[@"role"] ?: @"user",
                        @"content": [textContent copy]
                    }];
                }
                continue;
            }

            if (useResponsesAPI) {
                NSMutableArray *convertedBlocks = [NSMutableArray array];
                for (NSDictionary *b in blocks) {
                    NSString *type = [b[@"type"] description];
                    if ([type isEqualToString:@"text"]) {
                        [convertedBlocks addObject:@{@"type":@"input_text", @"text":b[@"text"] ?: @""}];
                    } else {
                        [convertedBlocks addObject:b];
                    }
                }
                clean[@"content"] = [convertedBlocks copy];
                [result addObject:clean];
                continue;
            }
        }
        [result addObject:clean];
    }
    return [result copy];
}

- (NSString *)featureLabel:(EZFeature)feature {
    switch (feature) {
        case EZFeatureImageLow:    return @"image_low";
        case EZFeatureImageMedium: return @"image_medium";
        case EZFeatureImageHigh:   return @"image_high";
        default:                   return @"image_medium";
    }
}

- (void)handleAPIError:(NSString *)msg {
    EZLogf(EZLogLevelError, @"API", @"Error: %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.sendButton.enabled = YES;
        [self appendToChat:[NSString stringWithFormat:@"[API Error]: %@", msg]];
    });
}

- (void)keyboardWillChange:(NSNotification *)notification {
    CGRect kbFrame  = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    double duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    BOOL isHiding   = [notification.name isEqualToString:UIKeyboardWillHideNotification];
    self.containerBottomConstraint.constant = isHiding
        ? 0 : -(kbFrame.size.height - self.view.safeAreaInsets.bottom);
    [UIView animateWithDuration:duration animations:^{ [self.view layoutIfNeeded]; }];
}

- (void)setupKeyboardObservers {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification       object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification       object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (void)newChat {
    [self saveActiveThread];
    [self _resetConversation];
    [self appendToChat:@"[System: New chat started ✓]"];
    EZLog(EZLogLevelInfo, @"APP", @"New chat started by user");
}

- (void)deleteCurrentChat {
    if (self.chatContext.count == 0) return;
    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Delete This Chat?"
                         message:@"This conversation will be permanently deleted."
                  preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
        if (self.activeThread.threadID.length > 0) {
            EZThreadDelete(self.activeThread.threadID);
        }
        [self _resetConversation];
        [self appendToChat:@"[System: Chat deleted]"];
        EZLog(EZLogLevelInfo, @"APP", @"Chat deleted by user");
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)_resetConversation {
    [self.chatContext removeAllObjects];
    [self.displayMessages removeAllObjects];
    [self.chatTableView reloadData];
    self.lastAIResponse     = nil;
    self.lastUserPrompt     = nil;
    self.lastImagePrompt    = nil;
    self.lastImageLocalPath = nil;
    self.pendingFileContext = nil;
    self.pendingFileName    = nil;
    self.pendingImagePath   = nil;
    [self startNewThread];
    [self updateThreadTitleLabel];
}

- (void)clearConversation {
    [self saveActiveThread];
    [self _resetConversation];
    EZLog(EZLogLevelInfo, @"APP", @"Conversation cleared — new thread started");
}

- (void)copyLastResponse {
    if (!self.lastAIResponse) return;
    [UIPasteboard generalPasteboard].string = self.lastAIResponse;
    EZLog(EZLogLevelInfo, @"APP", @"Last response copied to clipboard");

    UIImage *checkImg = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    UIImage *origImg  = [UIImage systemImageNamed:@"doc.on.doc"];
    [self.clipboardButton setImage:checkImg forState:UIControlStateNormal];
    [self.clipboardButton setTintColor:[UIColor systemGreenColor]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.clipboardButton setImage:origImg forState:UIControlStateNormal];
        [self.clipboardButton setTintColor:nil];
    });
}

- (void)showModelPicker {
    EZModelPickerViewController *picker = [[EZModelPickerViewController alloc]
        initWithModels:self.models selectedModel:self.selectedModel];
    __weak typeof(self) ws = self;
    picker.onModelSelected = ^(NSString *model) {
        ws.selectedModel = model;
        [ws.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", model]
                        forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setObject:model forKey:@"selectedModel"];
        ws.imageSettingsButton.hidden = !([ws isGptImage1Family:model] ||
                                          [model isEqualToString:@"dall-e-3"]);
        EZLogf(EZLogLevelInfo, @"APP", @"Model → %@", model);
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                          UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)persistImagePath:(NSString *)path prompt:(NSString *)prompt {
    if (!path.length) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:path   forKey:@"lastImageLocalPath"];
    [d setObject:prompt ?: @"" forKey:@"lastImagePrompt"];
    [d synchronize];
    EZLogf(EZLogLevelInfo, @"IMAGE", @"Persisted path: %@", path.lastPathComponent);
}

- (void)classifyImageIntent:(NSString *)prompt
              hasLocalImage:(BOOL)hasLocalImage
                     apiKey:(NSString *)apiKey
                 completion:(void(^)(NSString *intent))completion {

    NSString *lower = prompt.lowercaseString;

    NSArray *reopenSignals = @[
        @"again", @"reopen", @"re-open", @"pull up", @"pull it up",
        @"see it again",
        @"missed it", @"didn't see", @"can't see", @"lost it",
        @"bring it back", @"show me again", @"display again",
        @"open it again", @"show that image", @"that image again",
        @"previous image", @"last image", @"the image again"
    ];

    NSArray *generateSignals = @[
        @"create", @"generate", @"make", @"draw", @"paint",
        @"a picture of", @"an image of", @"image of", @"picture of",
        @"new image"];

    NSArray *editSignals = @[
        @"edit", @"change", @"modify", @"adjust", @"alter",
        @"add to", @"remove from", @"make it", @"turn it into"
    ];

    NSInteger reopenScore = 0, generateScore = 0, editScore = 0;
    for (NSString *s in reopenSignals)   if ([lower containsString:s]) reopenScore++;
    for (NSString *s in generateSignals) if ([lower containsString:s]) generateScore++;
    for (NSString *s in editSignals)     if ([lower containsString:s]) editScore++;

    EZLogf(EZLogLevelDebug, @"IMAGE",
           @"Intent scores — reopen:%ld generate:%ld edit:%ld hasLocal:%d",
           (long)reopenScore, (long)generateScore, (long)editScore, hasLocalImage);

    if (reopenScore >= 2 && reopenScore > generateScore && hasLocalImage) {
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 1: reopen (score %ld)", (long)reopenScore);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"reopen"); });
        return;
    }
    if (generateScore >= 2 && generateScore > reopenScore) {
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 1: generate (score %ld)", (long)generateScore);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"generate"); });
        return;
    }
    if (editScore >= 2 && editScore > reopenScore && hasLocalImage) {
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 1: edit (score %ld)", (long)editScore);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"edit"); });
        return;
    }

    if (!hasLocalImage || !apiKey.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"generate"); });
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *sys =
            @"You classify user intent for an AI image app. The user may want to:\n"
             "  REOPEN — view/display a previously generated image they already have\n"
             "  GENERATE — create a brand new image from a description\n"
             "  EDIT — modify/edit a previously generated image\n\n"
             "Reply with exactly one word: REOPEN, GENERATE, or EDIT. Nothing else.";
        NSString *msg = [NSString stringWithFormat:
            @"User prompt: \"%@\"\nContext: User has a previously generated image available.",
            prompt];

        NSString *raw = EZCallHelperModel(sys, msg, apiKey, 10);
        NSString *result = [[raw uppercaseString]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 2 classifier: %@ → %@", prompt, result);

        NSString *intent = @"generate";
        if ([result isEqualToString:@"REOPEN"]) intent = @"reopen";
        else if ([result isEqualToString:@"EDIT"])   intent = @"edit";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(intent); });
    });
}

- (void)checkReplyForLocalFilePaths:(NSString *)reply {
    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docsDir) return;

    // Match any path under /var/mobile/ with any extension — fixes .ips, .json, etc.
    NSRegularExpression *pathRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(/var/mobile/[^\\s\"'<>]+\\.\\w+)"
                             options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray *matches = [pathRegex matchesInString:reply
                                          options:0
                                            range:NSMakeRange(0, reply.length)];
    for (NSTextCheckingResult *match in matches) {
        NSString *path = [reply substringWithRange:[match rangeAtIndex:1]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            EZLogf(EZLogLevelInfo, @"ATTACH", @"Model referenced local file: %@", path);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self offerToOpenLocalFile:path];
            });
            break;
        }
    }
}

- (void)reopenAttachmentFromMemory:(NSString *)keyword {
    NSArray<NSDictionary *> *allMemories = EZMemoryLoadAll();
    NSString *lowerKeyword = keyword.lowercaseString;

    for (NSDictionary *entry in allMemories.reverseObjectEnumerator) {
        NSArray *paths = entry[@"attachmentPaths"];
        for (NSString *path in paths) {
            if ([path.lastPathComponent.lowercaseString containsString:lowerKeyword] ||
                [[entry[@"summary"] lowercaseString] containsString:lowerKeyword]) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                    EZLogf(EZLogLevelInfo, @"ATTACH", @"Reopening from memory: %@", path);
                    [self offerToOpenLocalFile:path];
                    return;
                }
            }
        }
    }
    EZLogf(EZLogLevelInfo, @"ATTACH", @"No matching file found in memory for: %@", keyword);
}

- (void)offerToOpenLocalFile:(NSString *)path {
    self.previewURL = [NSURL fileURLWithPath:path];
    QLPreviewController *ql = [[QLPreviewController alloc] init];
    ql.dataSource = self;
    [self presentViewController:ql animated:YES completion:nil];
    [self appendToChat:[NSString stringWithFormat:@"[System: Opening %@]", path.lastPathComponent]];
    NSString *ext = path.pathExtension.lowercaseString;
    if ([@[@"jpg",@"jpeg",@"png",@"gif",@"webp",@"heic"] containsObject:ext])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.7*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self offerSaveToPhotos:path];});
}

- (NSString *)fileExtensionForLanguage:(NSString *)lang {
    NSString *normalized = [[[lang lowercaseString]
                             stringByReplacingOccurrencesOfString:@"-" withString:@""]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSDictionary *map = @{
        @"python":        @"py",    @"py":           @"py",
        @"javascript":    @"js",    @"js":           @"js",
        @"typescript":    @"ts",    @"ts":           @"ts",
        @"swift":         @"swift",
        @"objc":          @"m",     @"objectivec":   @"m",
        @"objectivecpp":  @"mm",    @"objcpp":       @"mm",
        @"c":             @"c",
        @"cpp":           @"cpp",   @"c++":          @"cpp", @"cxx": @"cpp",
        @"java":          @"java",  @"kotlin":       @"kt",
        @"ruby":          @"rb",    @"go":           @"go",
        @"rust":          @"rs",    @"shell":        @"sh",
        @"bash":          @"sh",    @"sh":           @"sh",  @"zsh": @"sh",
        @"html":          @"html",  @"css":          @"css",
        @"json":          @"json",  @"xml":          @"xml",
        @"yaml":          @"yaml",  @"yml":          @"yaml",
        @"sql":           @"sql",   @"markdown":     @"md",  @"md": @"md",
        @"plaintext":     @"txt",   @"text":         @"txt", @"plain": @"txt",
        @"diff":          @"diff",  @"makefile":     @"mk",
        @"dart":          @"dart",  @"php":          @"php",
        @"cs":            @"cs",    @"csharp":       @"cs",
        @"r":             @"r",     @"matlab":       @"m",
        @"scala":         @"scala", @"lua":          @"lua",
        @"perl":          @"pl",    @"haskell":      @"hs",
    };
    NSString *ext = map[normalized];
    if (!ext) {
        NSCharacterSet *safe = [NSCharacterSet alphanumericCharacterSet];
        NSString *candidate = normalized.length > 6
            ? [normalized substringToIndex:6] : normalized;
        BOOL isSafe = YES;
        for (NSUInteger i = 0; i < candidate.length; i++) {
            if (![safe characterIsMember:[candidate characterAtIndex:i]]) { isSafe = NO; break; }
        }
        ext = (isSafe && candidate.length > 0) ? candidate : @"txt";
    }
    return ext;
}

- (NSString *)processReplyWithCodeBlocks:(NSString *)reply
                            savedPaths:(NSMutableArray<NSString *> *)savedPaths {
    return [self processReplyWithCodeBlocks:reply savedPaths:savedPaths isRestore:NO];
}

- (NSString *)processReplyWithCodeBlocks:(NSString *)reply
                            savedPaths:(NSMutableArray<NSString *> *)savedPaths
                             isRestore:(BOOL)isRestore {
    NSError *regexErr;
    NSRegularExpression *codeBlockRegex = [NSRegularExpression
        regularExpressionWithPattern:@"```([a-zA-Z0-9+#._-]*)[ \\t]*\\n([\\s\\S]+?)\\n[ \\t]*```"
                             options:0
                               error:&regexErr];
    if (regexErr || !codeBlockRegex) return reply;

    NSArray *matches = [codeBlockRegex matchesInString:reply
                                               options:0
                                                 range:NSMakeRange(0, reply.length)];
    if (matches.count == 0) return reply;

    NSMutableString *processed = [NSMutableString stringWithString:reply];
    NSInteger offset = 0;

    for (NSTextCheckingResult *match in matches) {
        NSRange langRange = [match rangeAtIndex:1];
        NSRange codeRange = [match rangeAtIndex:2];
        if (langRange.location == NSNotFound || codeRange.location == NSNotFound) continue;

        NSString *lang = [reply substringWithRange:langRange];
        NSString *code = [reply substringWithRange:codeRange];

        if (code.length < 5) continue;

        NSString *detectedName = nil;
        NSArray<NSString *> *firstLines = [[code componentsSeparatedByString:@"\n"]
                                           subarrayWithRange:NSMakeRange(0, MIN(2, [[code componentsSeparatedByString:@"\n"] count]))];
        NSError *fnErr;
        NSRegularExpression *fnRegex = [NSRegularExpression
            regularExpressionWithPattern:@"[\\w.+-]+\\.(?:m|h|mm|swift|py|js|ts|sh|bash|rb|go|rs|kt|java|c|cpp|cxx|cs|html|css|json|xml|yaml|yml|sql|md|txt|mk|makefile|gradle|plist|entitlements|pbxproj)"
                                 options:NSRegularExpressionCaseInsensitive error:&fnErr];
        if (!fnErr) {
            for (NSString *line in firstLines) {
                NSRange lineRange = NSMakeRange(0, line.length);
                NSTextCheckingResult *fnMatch = [fnRegex firstMatchInString:line options:0 range:lineRange];
                if (fnMatch) {
                    detectedName = [line substringWithRange:fnMatch.range];
                    break;
                }
            }
        }

        NSString *ext;
        NSString *label;
        if (detectedName.length > 0) {
            label = detectedName;
            ext   = detectedName.pathExtension.length > 0 ? detectedName.pathExtension : @"txt";
        } else {
            ext   = [self fileExtensionForLanguage:lang];
            label = lang.length > 0 ? lang : ext;
        }

        NSString *savedPath = nil;
        NSString *fileName  = detectedName.length > 0 ? detectedName
            : [NSString stringWithFormat:@"snippet.%@", ext];

        if (isRestore) {
            for (NSString *existingPath in self.activeThread.attachmentPaths) {
                if ([existingPath.lastPathComponent hasSuffix:[@"_" stringByAppendingString:fileName]] ||
                    [existingPath.lastPathComponent hasSuffix:fileName]) {
                    if ([[NSFileManager defaultManager] fileExistsAtPath:existingPath]) {
                        savedPath = existingPath;
                        break;
                    }
                }
            }
        }

        if (!savedPath) {
            NSData *codeData = [code dataUsingEncoding:NSUTF8StringEncoding];
            savedPath = codeData ? EZAttachmentSave(codeData, fileName) : nil;
            if (savedPath && !isRestore) {
                [savedPaths addObject:savedPath];
                NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
                if (![att containsObject:savedPath]) [att addObject:savedPath];
                self.activeThread.attachmentPaths = [att copy];
            }
            if (savedPath) EZLogf(EZLogLevelInfo, @"CODE", @"Saved %@ snippet: %@", label, savedPath);
        }

        NSString *placeholder = savedPath
            ? [NSString stringWithFormat:@"\n[CODE:%@:%@]\n", label, savedPath]
            : [NSString stringWithFormat:@"\n[CODE:%@]\n%@\n[/CODE]\n", label, code];

        NSRange originalRange  = [match range];
        NSRange adjustedRange  = NSMakeRange((NSUInteger)((NSInteger)originalRange.location + offset),
                                              originalRange.length);
        [processed replaceCharactersInRange:adjustedRange withString:placeholder];
        offset += (NSInteger)placeholder.length - (NSInteger)originalRange.length;
    }
    return [processed copy];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat display helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Primary append entry point. Detects role from prefix ("You: ", "AI: "),
/// splits [CODE:] markers into separate code cells, and reloads the table.
- (void)appendToChat:(NSString *)rawText {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self appendToChat:rawText]; });
        return;
    }
    NSString *role = @"system";
    NSString *text = rawText;
    if ([rawText hasPrefix:@"You: "]) { role = @"user";      text = [rawText substringFromIndex:5]; }
    else if ([rawText hasPrefix:@"AI: "]) { role = @"assistant"; text = [rawText substringFromIndex:4]; }

    // Stamp timestamp + thread metadata so bubble cells can show them on swipe.
    static NSDateFormatter *_ezFmt;

    static dispatch_once_t _ezFmtOnce;
    dispatch_once(&_ezFmtOnce, ^{
        _ezFmt = [[NSDateFormatter alloc] init];
        _ezFmt.dateFormat = @"MMM d, h:mm a";
    });
    NSString *_ts = [_ezFmt stringFromDate:[NSDate date]];
    NSString *_ck    = self.activeThread.threadID ?: @"";
    NSString *_tid   = self.activeThread.threadID ?: @"";

    if ([text containsString:@"[CODE:"]) {
        [self addMessageSegments:text defaultRole:role];
    } else {
        [self.displayMessages addObject:@{
            @"role":     role,
            @"text":     text,
            @"timestamp": _ts,
            @"chatKey":  _ck,
            @"threadID": _tid,
        }];
        [self reloadAndScrollTable];
    }
}

/// Splits text containing [CODE:lang:path] / [CODE:lang]...[/CODE] markers
/// into alternating text + code entries in displayMessages.
- (void)addMessageSegments:(NSString *)text defaultRole:(NSString *)role {
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:
            @"\\[CODE:([^:]+):([^\\]]+)\\]|\\[CODE:([^\\]]+)\\]([\\s\\S]*?)\\[/CODE\\]"
                             options:0 error:nil];
    if (!re) {
        [self.displayMessages addObject:@{@"role": role, @"text": text}];
        [self reloadAndScrollTable]; return;
    }
    NSArray *matches = [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    NSInteger lastEnd = 0;
    for (NSTextCheckingResult *match in matches) {
        // Plain text before this code block
        NSRange before = NSMakeRange((NSUInteger)lastEnd,
                                     match.range.location - (NSUInteger)lastEnd);
        if (before.length > 0) {
            NSString *seg = [[text substringWithRange:before]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (seg.length) [self.displayMessages addObject:@{@"role": role, @"text": seg}];
        }
        // Code block
        NSRange r1=[match rangeAtIndex:1], r2=[match rangeAtIndex:2];
        NSRange r3=[match rangeAtIndex:3], r4=[match rangeAtIndex:4];
        NSString *lang=@"", *savedPath=nil, *code=nil;
        if (r1.location != NSNotFound) {
            lang = [text substringWithRange:r1];
            savedPath = [text substringWithRange:r2];
            code = [NSString stringWithContentsOfFile:savedPath
                                             encoding:NSUTF8StringEncoding error:nil];
        } else if (r3.location != NSNotFound) {
            lang = [text substringWithRange:r3];
            code = r4.location != NSNotFound ? [text substringWithRange:r4] : @"";
        }
        if (!code) code = @"(code unavailable)";
        NSMutableDictionary *entry = [@{@"role":@"code",
                                        @"text": code,
                                        @"language": lang.length ? lang : @"code"} mutableCopy];
        if (savedPath) entry[@"savedPath"] = savedPath;
        [self.displayMessages addObject:[entry copy]];
        lastEnd = (NSInteger)(match.range.location + match.range.length);
    }
    // Remaining text after last code block
    if ((NSUInteger)lastEnd < text.length) {
        NSString *tail = [[text substringFromIndex:(NSUInteger)lastEnd]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (tail.length) [self.displayMessages addObject:@{@"role": role, @"text": tail}];
    }
    [self reloadAndScrollTable];
}

- (void)reloadAndScrollTable {
    [self.chatTableView reloadData];
    [self scrollChatToBottom];
}

/// Legacy name kept so all existing call sites compile unchanged.
- (void)appendToOldChat:(NSString *)text { [self appendToChat:text]; }

// ── Inline image grid insertion ───────────────────────────────────────────────

/// Inserts an image grid cell into the chat for one or more generated/edited images.
/// On success, imagePaths contains 1–4 local EZAttachments paths.
/// On error, isError = YES and errorText describes what went wrong.
/// Also persists to NSUserDefaults so image cells survive thread restore.
- (void)appendImageGridToChat:(NSArray<NSString *> *)imagePaths
                       prompt:(NSString *)prompt
                      isError:(BOOL)isError
                    errorText:(nullable NSString *)errorText {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendImageGridToChat:imagePaths prompt:prompt isError:isError errorText:errorText];
        });
        return;
    }

    NSMutableDictionary *entry = [@{
        @"role":       @"imagegrid",
        @"imagePaths": imagePaths ?: @[],
        @"prompt":     prompt ?: @"",
        @"isError":    @(isError),
    } mutableCopy];
    if (errorText) entry[@"errorText"] = errorText;

    [self.displayMessages addObject:[entry copy]];
    [self reloadAndScrollTable];

    // Persist image cells keyed by threadID so they survive restore
    [self persistImageGridCells];
}

/// Appends the saved imagegrid cells for this threadID to NSUserDefaults.
- (void)persistImageGridCells {
    NSString *threadID = self.activeThread.threadID;
    if (!threadID.length) return;
    NSString *key = [NSString stringWithFormat:@"EZImageCells_%@", threadID];
    NSMutableArray *cells = [NSMutableArray array];
    for (NSDictionary *msg in self.displayMessages) {
        if ([msg[@"role"] isEqualToString:@"imagegrid"]) [cells addObject:msg];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:cells options:0 error:nil];
    if (data) [[NSUserDefaults standardUserDefaults] setObject:data forKey:key];
}

/// Restores image grid cells after a thread is loaded and displayMessages rebuilt.
- (void)restoreImageGridCellsForThread:(NSString *)threadID {
    if (!threadID.length) return;
    NSString *key  = [NSString stringWithFormat:@"EZImageCells_%@", threadID];
    NSData   *data = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (!data) return;
    NSArray *saved = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![saved isKindOfClass:[NSArray class]]) return;
    for (NSDictionary *cell in saved) {
        if (![cell[@"role"] isEqualToString:@"imagegrid"]) continue;
        // Only restore cells whose images still exist on disk
        NSArray<NSString *> *paths = cell[@"imagePaths"] ?: @[];
        NSMutableArray *validPaths = [NSMutableArray array];
        for (NSString *p in paths) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:p]) [validPaths addObject:p];
        }
        if (validPaths.count == 0 && ![cell[@"isError"] boolValue]) continue;
        NSMutableDictionary *entry = [cell mutableCopy];
        entry[@"imagePaths"] = [validPaths copy];
        [self.displayMessages addObject:[entry copy]];
    }
    [self reloadAndScrollTable];
}

/// Shows an inline attachment preview bubble when the user attaches an image.
- (void)appendAttachmentBubble:(NSString *)imagePath {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendAttachmentBubble:imagePath];
        });
        return;
    }
    if (!imagePath.length) return;
    [self.displayMessages addObject:@{
        @"role":      @"attachment",
        @"imagePath": imagePath,
    }];
    [self reloadAndScrollTable];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UITableViewDataSource / UITableViewDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.displayMessages.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *msg = self.displayMessages[(NSUInteger)indexPath.row];
    NSString *role    = msg[@"role"] ?: @"system";
    if ([role isEqualToString:@"imagegrid"]) {
        NSArray *paths = msg[@"imagePaths"] ?: @[];
        BOOL isError   = [msg[@"isError"] boolValue];
        return [EZImageGridCell heightForImageCount:(NSInteger)paths.count
                                        tableWidth:tableView.bounds.size.width
                                           isError:isError];
    }
    if ([role isEqualToString:@"attachment"]) {
        return [EZAttachmentPreviewCell heightForTableWidth:tableView.bounds.size.width];
    }
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *msg = self.displayMessages[(NSUInteger)indexPath.row];
    NSString *role    = msg[@"role"] ?: @"system";

    if ([role isEqualToString:@"imagegrid"]) {
        EZImageGridCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZImageGrid"
                                                                forIndexPath:indexPath];
        [cell configureWithImagePaths:msg[@"imagePaths"] ?: @[]
                               prompt:msg[@"prompt"] ?: @""
                              isError:[msg[@"isError"] boolValue]
                            errorText:msg[@"errorText"]
                 presentingController:self];
        return cell;
    }

    if ([role isEqualToString:@"attachment"]) {
        EZAttachmentPreviewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZAttachment"
                                                                        forIndexPath:indexPath];
        [cell configureWithImagePath:msg[@"imagePath"] ?: @""];
        return cell;
    }

    if ([role isEqualToString:@"code"]) {
        EZCodeBlockCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZCodeBlock"
                                                                forIndexPath:indexPath];
        [cell configureWithCode:msg[@"text"]
                       language:msg[@"language"]
                      savedPath:msg[@"savedPath"]
                 viewController:self];
        return cell;
    } else if ([role isEqualToString:@"user"] || [role isEqualToString:@"assistant"]) {
        EZBubbleCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZBubble"
                                                             forIndexPath:indexPath];
        [cell configureWithText:msg[@"text"] ?: @""
                         isUser:[role isEqualToString:@"user"]
                      timestamp:msg[@"timestamp"]
                        chatKey:msg[@"chatKey"]
                       threadID:msg[@"threadID"]];
        return cell;
    } else {
        EZSystemCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZSystem"
                                                             forIndexPath:indexPath];
        cell.messageLabel.text = msg[@"text"] ?: @"";
        return cell;
    }
}

// ── Present deferred Sora video once the view is on screen ──────────────────
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateCoinBalanceDisplay];
    if (self.pendingVideoURL) {
        NSURL *url           = self.pendingVideoURL;
        self.pendingVideoURL = nil;
        self.previewURL      = url;
        QLPreviewController *ql = [[QLPreviewController alloc] init];
        ql.dataSource = self;
        [self presentViewController:ql animated:YES completion:nil];
        EZLog(EZLogLevelInfo, @"SORA", @"Deferred Sora video presented on viewWillAppear");
    }
}

- (void)codeBlockCopyTapped:(UIButton *)sender {
    NSString *code = objc_getAssociatedObject(sender, "EZCodeContent");
    if (code) {
        [UIPasteboard generalPasteboard].string = code;
        NSString *original = [sender titleForState:UIControlStateNormal];
        [sender setTitle:@"✓ Copied!" forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [sender setTitle:original forState:UIControlStateNormal];
        });
        EZLog(EZLogLevelInfo, @"CODE", @"Code copied to clipboard");
    }
}

- (void)codeBlockFileTapped:(UIButton *)sender {
    NSString *path = objc_getAssociatedObject(sender, "EZCodePath");
    if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self offerToOpenLocalFile:path];
    }
}

- (void)scrollChatToBottom {
    NSUInteger count = self.displayMessages.count;
    if (count == 0) return;
    NSIndexPath *last = [NSIndexPath indexPathForRow:(NSInteger)(count - 1) inSection:0];
    [self.chatTableView scrollToRowAtIndexPath:last
                             atScrollPosition:UITableViewScrollPositionBottom
                                     animated:YES];
}

// appendToOldChat: implemented above as a wrapper around appendToChat:

- (void)showGPT5StatusBanner {
    self.statusBannerPhase = 0; [self.statusBannerSpinner startAnimating]; [self tickStatusBanner];
    self.statusBannerTimer = [NSTimer scheduledTimerWithTimeInterval:4.0 target:self
        selector:@selector(tickStatusBanner) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.statusBannerTimer forMode:NSRunLoopCommonModes];
    [UIView animateWithDuration:0.3 animations:^{ self.statusBannerView.alpha = 1.0; }];
}
- (void)hideGPT5StatusBanner {
    [self.statusBannerTimer invalidate]; self.statusBannerTimer = nil;
    [UIView animateWithDuration:0.3 animations:^{ self.statusBannerView.alpha = 0.0; }
     completion:^(BOOL _) { [self.statusBannerSpinner stopAnimating]; }];
}
- (void)tickStatusBanner {
    NSArray<NSString *> *m = @[@"GPT-5 is thinking…",@"Processing your request…",
        @"Still working — GPT-5 can take up to 3 min",@"Reasoning through your prompt…",
        @"Almost there — complex requests take longer",@"Hang tight, GPT-5 is thorough",
        @"Working hard on your answer…"];
    [UIView transitionWithView:self.statusBannerLabel duration:0.4
        options:UIViewAnimationOptionTransitionCrossDissolve
        animations:^{ self.statusBannerLabel.text = m[self.statusBannerPhase % m.count]; } completion:nil];
    self.statusBannerPhase++;
}
- (void)openSettings {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[SettingsViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openBrainRot {
    BrainRotViewController *brainRot = [[BrainRotViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:brainRot];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)presentCoinStoreForFeature:(NSString * _Nullable)featureName {
    EZCoinStoreViewController *store = [[EZCoinStoreViewController alloc] init];
    store.showLowCoinsWarning   = (featureName != nil);
    store.triggeringFeatureName = featureName ?: @"this feature";
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:store];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openSupport {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[SupportRequestViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openMemories {
    if (self.drawerOpen) {
        [self closeDrawer];
    }
    if (self.memoriesDrawerOpen) {
        [self closeMemoriesDrawerWithCompletion:nil];
        return;
    }

    if (!self.memoriesDrawerContainerView) {
        CGFloat drawerWidth = self.view.bounds.size.width * 0.75;

        self.memoriesDrawerDimView = [[UIView alloc] init];
        self.memoriesDrawerDimView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        self.memoriesDrawerDimView.alpha = 0;
        self.memoriesDrawerDimView.hidden = YES;
        self.memoriesDrawerDimView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.memoriesDrawerDimView];
        [NSLayoutConstraint activateConstraints:@[
            [self.memoriesDrawerDimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.memoriesDrawerDimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [self.memoriesDrawerDimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.memoriesDrawerDimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        ]];
        UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(closeMemoriesDrawer)];
        [self.memoriesDrawerDimView addGestureRecognizer:dimTap];

        self.memoriesDrawerContainerView = [[UIView alloc] init];
        self.memoriesDrawerContainerView.backgroundColor = [UIColor systemBackgroundColor];
        self.memoriesDrawerContainerView.translatesAutoresizingMaskIntoConstraints = NO;
        self.memoriesDrawerContainerView.layer.shadowColor = [UIColor blackColor].CGColor;
        self.memoriesDrawerContainerView.layer.shadowOpacity = 0.22;
        self.memoriesDrawerContainerView.layer.shadowRadius = 14;
        self.memoriesDrawerContainerView.layer.shadowOffset = CGSizeMake(-6, 0);
        [self.view addSubview:self.memoriesDrawerContainerView];

        self.memoriesDrawerTrailingConstraint = [self.memoriesDrawerContainerView.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor constant:drawerWidth];
        [NSLayoutConstraint activateConstraints:@[
            self.memoriesDrawerTrailingConstraint,
            [self.memoriesDrawerContainerView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.memoriesDrawerContainerView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [self.memoriesDrawerContainerView.widthAnchor constraintEqualToConstant:drawerWidth],
        ]];

        MemoriesViewController *memoriesVC = [[MemoriesViewController alloc] init];
        __weak typeof(self) weakSelf = self;
        memoriesVC.closeRequestHandler = ^(dispatch_block_t completion) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                if (completion) completion();
                return;
            }
            [strongSelf closeMemoriesDrawerWithCompletion:completion];
        };

        self.memoriesDrawerNavController = [[UINavigationController alloc]
            initWithRootViewController:memoriesVC];
        [self addChildViewController:self.memoriesDrawerNavController];
        self.memoriesDrawerNavController.view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.memoriesDrawerContainerView addSubview:self.memoriesDrawerNavController.view];
        [NSLayoutConstraint activateConstraints:@[
            [self.memoriesDrawerNavController.view.topAnchor constraintEqualToAnchor:self.memoriesDrawerContainerView.topAnchor],
            [self.memoriesDrawerNavController.view.bottomAnchor constraintEqualToAnchor:self.memoriesDrawerContainerView.bottomAnchor],
            [self.memoriesDrawerNavController.view.leadingAnchor constraintEqualToAnchor:self.memoriesDrawerContainerView.leadingAnchor],
            [self.memoriesDrawerNavController.view.trailingAnchor constraintEqualToAnchor:self.memoriesDrawerContainerView.trailingAnchor],
        ]];
        [self.memoriesDrawerNavController didMoveToParentViewController:self];
        [self.view layoutIfNeeded];
    }

    self.memoriesDrawerOpen = YES;
    self.memoriesDrawerDimView.hidden = NO;
    self.memoriesDrawerTrailingConstraint.constant = 0;
    [UIView animateWithDuration:0.32
                          delay:0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.memoriesDrawerDimView.alpha = 1.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)openTTS {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[TextToSpeechViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openCloning {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[ElevenLabsCloneViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openGallery {
    EZPhotoGalleryViewController *gallery = [EZPhotoGalleryViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:gallery];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

/// Called when user taps "Ask a Question" in the gallery detail view.
/// Attaches the image to the chat input so the user can type their question.
- (void)handleAttachImageToChat:(NSNotification *)notification {
    UIImage *image = notification.userInfo[@"image"];
    if (!image) return;

    // Save the image into EZAttachments so pendingImagePath works normally
    NSString *dir  = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:@"EZAttachments"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *filename = [NSString stringWithFormat:@"gallery_ask_%@.jpg",
                          [NSUUID UUID].UUIDString];
    NSString *path = [dir stringByAppendingPathComponent:filename];
    [UIImageJPEGRepresentation(image, 0.92) writeToFile:path atomically:YES];

    self.pendingImagePath = path;
    [self appendToChat:@"[Image attached from Gallery — type your question below]"];
    [self.messageTextField becomeFirstResponder];
}

/// Called when user taps "Edit with AI" in the gallery detail view.
/// Attaches the image and pre-fills the input with an edit prompt.
- (void)handleEditImageInChat:(NSNotification *)notification {
    UIImage *image = notification.userInfo[@"image"];
    if (!image) return;

    NSString *dir  = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:@"EZAttachments"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *filename = [NSString stringWithFormat:@"gallery_edit_%@.jpg",
                          [NSUUID UUID].UUIDString];
    NSString *path = [dir stringByAppendingPathComponent:filename];
    [UIImageJPEGRepresentation(image, 0.92) writeToFile:path atomically:YES];

    self.pendingImagePath = path;

    // Switch to edit mode — gpt-image-1-edit takes the direct path (line 1765)
    // which correctly uses pendingImagePath. Do NOT use a generation model here
    // or the intent classifier will be called and will ignore pendingImagePath.
    NSArray *imageModels = @[@"gpt-image-1.5", @"gpt-image-1", @"chatgpt-image-latest"];
    if (![imageModels containsObject:self.selectedModel]) {
        // wasn't on an image model at all — switch to edit mode directly
    }
    self.selectedModel = @"gpt-image-1-edit";
    [self.modelButton setTitle:@"Model: gpt-image-1 (edit mode)"
                      forState:UIControlStateNormal];

    [self appendToChat:@"[Image attached from Gallery — ready to edit]"];
    self.messageTextField.text = @"Edit this image: ";
    [self.messageTextField becomeFirstResponder];
    // Move cursor to end
    UITextRange *end = [self.messageTextField textRangeFromPosition:self.messageTextField.endOfDocument
                                                         toPosition:self.messageTextField.endOfDocument];
    self.messageTextField.selectedTextRange = end;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    @try {
        [self ezcui_endLongOperation];
    } @catch (NSException *e) {
        EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"viewWillDisappear end failed: %@", e);
    }
}


- (void)dealloc {
    @try {
        [self ezcui_endLongOperation];
    } @catch (NSException *e) {
        EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"dealloc end failed: %@", e);
    }
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

@end

@interface ViewController (EZTitleFix)
@end
@implementation ViewController (EZTitleFix)
    - (void)setTitle:(NSString *)title {
        [super setTitle:title];
        // If the top-buttons category is present, let it sync its label.
        if ([self respondsToSelector:@selector(ezcui_setTopTitle:)]) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self performSelector:@selector(ezcui_setTopTitle:) withObject:(title ?: @"")];
    #pragma clang diagnostic pop
        }
    }
@end
