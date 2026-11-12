// helpers.h
// EZCompleteUI
//
// Replacement header focused on safer routing, saner memory metadata,
// and backwards-compatible decoding of legacy memory entries.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, EZLogLevel) {
    EZLogLevelDebug   = 0,
    EZLogLevelInfo    = 1,
    EZLogLevelWarning = 2,
    EZLogLevelError   = 3,
};

NSString *EZLogGetPath(void);
void EZLog(EZLogLevel level, NSString *tag, NSString *message);
#define EZLogf(level, tag, fmt, ...) EZLog((level),(tag),[NSString stringWithFormat:(fmt),##__VA_ARGS__])
void EZLogRotateIfNeeded(NSUInteger maxBytes);

/// Activates an audio session suitable for audible app playback.  Call this
/// immediately before AVAudioPlayer or AVSpeechSynthesizer playback so a
/// previous recording/dictation session cannot leave output muted.
BOOL EZActivatePlaybackAudioSession(NSError * _Nullable * _Nullable error);

NSString *EZHelperLogGetPath(void);
void EZHelperLog(NSString *tag, NSString *message);
void EZHelperLogRotateIfNeeded(NSUInteger maxBytes);

typedef NS_ENUM(NSInteger, EZRoutingTier) {
    EZRoutingTierDirect       = 1,
    EZRoutingTierSimple       = 2,
    EZRoutingTierMemory       = 3,
    EZRoutingTierFullHistory  = 4,
    EZRoutingTierFullThread   = 5,
};

@interface EZContextResult : NSObject
@property (nonatomic, assign) EZRoutingTier tier;
@property (nonatomic, assign) BOOL needsContext;
@property (nonatomic, copy) NSString *reason;
@property (nonatomic, copy) NSString *finalPrompt;
@property (nonatomic, assign) NSInteger estimatedTokens;
@property (nonatomic, copy, nullable) NSString *shortCircuitAnswer;
@property (nonatomic, strong, nullable) NSArray<NSDictionary *> *injectedHistory;
@property (nonatomic, assign) float confidence;
@end

@interface EZChatThread : NSObject
@property (nonatomic, copy) NSString *threadID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *displayText;
@property (nonatomic, strong) NSArray<NSDictionary *> *chatContext;
@property (nonatomic, copy) NSString *modelName;
@property (nonatomic, copy) NSString *createdAt;
@property (nonatomic, copy) NSString *updatedAt;
@property (nonatomic, strong) NSArray<NSString *> *attachmentPaths;
@property (nonatomic, copy, nullable) NSString *lastImageLocalPath;
@property (nonatomic, copy, nullable) NSString *lastVideoLocalPath;
- (NSDictionary *)toDictionary;
+ (nullable instancetype)fromDictionary:(NSDictionary *)dict;
@end

/// Backwards compatible analyzer. `chatKey` now acts only as a fallback current-thread ID.
void analyzePromptForContext(NSString *userPrompt,
                             NSString * _Nullable memoryContext,
                             NSString *apiKey,
                             NSString * _Nullable chatKey,
                             void (^completion)(EZContextResult *result));

/// Attachment-aware routing variant. `imageDataURLs` contains prepared image
/// data URLs for the current unsent turn; files are represented in userPrompt
/// by their extracted text.
void analyzePromptForContextWithImages(NSString *userPrompt,
                                       NSString * _Nullable memoryContext,
                                       NSArray<NSString *> * _Nullable imageDataURLs,
                                       NSString *apiKey,
                                       NSString * _Nullable chatKey,
                                       void (^completion)(EZContextResult *result));

NSString *EZMemoryGetPath(void);

/// Legacy-compatible wrapper. `chatKey` is treated as promptID.
void createMemoryFromCompletion(NSString *userPrompt,
                                NSString *assistantReply,
                                NSString *apiKey,
                                NSString * _Nullable chatKey,
                                NSArray<NSString *> * _Nullable attachmentPaths,
                                void (^completion)(NSString * _Nullable entry));

/// Preferred API for new code.
/// `promptID` identifies the summarized exchange.
/// `threadID` identifies the source thread containing the real full context.
void EZCreateMemoryEntry(NSString *userPrompt,
                         NSString *assistantReply,
                         NSString *apiKey,
                         NSString * _Nullable promptID,
                         NSString * _Nullable threadID,
                         NSArray<NSString *> * _Nullable attachmentPaths,
                         void (^completion)(NSString * _Nullable entry));

/// Song variant: the caller that finished a song passes its entry ID, which
/// is stored on the memory as structured data (songEntryIDs) — guaranteed by
/// code, never left for the summarizer to keep or drop in the prose summary.
void EZCreateSongMemory(NSString *userPrompt,
                        NSString *assistantReply,
                        NSString *apiKey,
                        NSString * _Nullable threadID,
                        NSString * _Nullable entryID,
                        void (^completion)(NSString * _Nullable entry));

/// Explicit fact save for the chat memory tool (update_memory): stores
/// `fact` verbatim as an important-memory entry WITHOUT the summarizer, so what the
/// user asked to remember is exactly what is kept and later recalled.
/// The entry also carries the fact under `explicitFact` so a later
/// forget can match it exactly. completion reports whether a new entry
/// was written (NO when the fact was empty or already stored).
void EZCreateExplicitMemory(NSString *fact,
                            NSString * _Nullable threadID,
                            void (^completion)(BOOL saved));

/// Forget counterpart: removes every important-memory entry whose stored fact
/// (explicitFact) or summary contains `text`, case-insensitive.
/// completion reports how many entries were removed.
void EZForgetMemoryMatching(NSString *text,
                            void (^completion)(NSUInteger removed));

/// Dry run for the forget confirmation gate: returns copies of the
/// entries a forget of `text` WOULD remove, changing nothing — no
/// deletion, no registration. The gate shows these to the user so what
/// they confirm is exactly what would go.
NSArray<NSDictionary *> *EZMemoryEntriesMatching(NSString *text);

/// Registers `text`'s needle in the forget registry immediately, so an
/// in-flight explicit save of the fact is invalidated even before any
/// deletion happens. EZForgetMemoryMatching registers as part of the
/// delete; the confirmation gate calls this up front, because the user
/// may take time to decide and the fact must not resurrect meanwhile.
void EZRegisterForgetNeedle(NSString *text);

/// Removes `text`'s needle from the forget registry — the rollback the
/// gate runs when the user declines a forget, so the state ends up
/// exactly as it was before the request: nothing deleted, nothing
/// blocked.
void EZUnregisterForgetNeedle(NSString *text);

/// ── Important memories (Memory Summary) ──────────────────────────────
/// Facts saved through the chat memory tool live in their own store
/// (ezui_important_memories.json), separate from the automatic per-turn
/// summaries in ezui_memory.json: they are the user's standing "always
/// remember this" list, shown and edited on the Settings → Memory
/// Summary screen, and injected into every chat send as a block.

/// Full path to the important-memories store file.
NSString *EZImportantMemoryGetPath(void);

/// One-time migration: moves every summaries entry carrying an
/// `explicitFact` (saved by the memory tool before the stores split)
/// into the important store, preserving order and all keys. Guarded by
/// a defaults flag; safe to call repeatedly — the store functions run
/// it automatically before first use.
void EZMigrateExplicitMemoriesIfNeeded(void);

/// The always-in-context block for outgoing chat sends: a header line
/// plus one "- <fact>" line per stored fact, oldest first. nil when
/// the important store is empty.
NSString * _Nullable EZImportantMemoryContextBlock(void);

/// All important-memory entries in file order (oldest first).
NSArray<NSDictionary *> *EZImportantMemoryLoadAll(void);

/// Appends a fact (trimmed; empty facts and identical duplicates are
/// refused, mirroring EZCreateExplicitMemory).
void EZImportantMemoryAddFact(NSString *fact);

/// Replaces the fact at `index`, updating both its summary and
/// explicitFact text; the original timestamp is kept. Out-of-range
/// indices and empty replacements are no-ops.
void EZImportantMemoryReplaceFactAtIndex(NSUInteger index, NSString *newFact);

/// Removes the fact at `index`. Out-of-range indices are a no-op.
void EZImportantMemoryDeleteAtIndex(NSUInteger index);

NSString *loadMemoryContext(NSInteger maxEntries);
NSArray<NSDictionary *> *EZMemoryLoadAll(void);
NSString *EZThreadSearchMemory(NSString *query, NSString *apiKey);
BOOL clearMemoryLog(void);

NSString *EZThreadStoreDir(void);
void EZThreadSave(EZChatThread *thread, void (^ _Nullable completion)(BOOL success));
EZChatThread * _Nullable EZThreadLoad(NSString *threadID);
NSArray<EZChatThread *> *EZThreadList(void);
BOOL EZThreadDelete(NSString *threadID);
NSArray<NSDictionary *> * _Nullable EZThreadLoadContext(NSString *threadID, NSInteger tokenBudget);

NSString * _Nullable EZAttachmentSave(NSData *data, NSString *fileName);
NSString * _Nullable EZAttachmentPath(NSString *savedFileName);
// Image-only storage. Gallery uploads, generations, and edits belong here,
// never in EZAttachments.
NSString *EZPhotoGalleryDirectory(void);
NSString * _Nullable EZPhotoGallerySave(NSData *data, NSString *fileName);
NSString * _Nullable EZPhotoGalleryPath(NSString *savedFileName);

NSString *EZHelperStats(void);

NSString * _Nullable EZCallHelperModel(NSString *systemPrompt,
                                       NSString *userMessage,
                                       NSString *apiKey,
                                       NSInteger maxTokens);

NS_ASSUME_NONNULL_END
