// helpers.h
// EZCompleteUI v5.0
//
// Changes from v4.0:
//   - Memory store changed from flat text log to JSON array (ezui_memory.json)
//   - Each memory entry is now a dictionary with timestamp, summary, chatKey
//   - EZThreadSearchMemory now does local relevance scoring (no token waste)
//     then sends only the top candidates to the AI for final ranking
//   - createMemoryFromCompletion updated to write JSON entry
//   - loadMemoryContext returns formatted string from JSON for backwards compat
//   - EZMemoryLoadAll returns raw array of entry dicts for new code
//   - Migration: old .log file is imported and converted on first run

#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────────────────────
// Logging
// ─────────────────────────────────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────────────────────────────────
// EZContextResult — the routing decision returned to ViewController
// ─────────────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, EZRoutingTier) {
    EZRoutingTierDirect   = 1,  ///< Helper model answered — skip main model entirely
    EZRoutingTierSimple   = 2,  ///< Main model, no context injected
    EZRoutingTierMemory   = 3,  ///< Main model + relevant memory summaries injected
    EZRoutingTierFullChat = 4,  ///< Main model + full chat turns loaded from disk
};

@interface EZContextResult : NSObject
/// Which routing tier was decided
@property (nonatomic, assign) EZRoutingTier tier;
/// Backwards-compat flag: YES when tier >= EZRoutingTierMemory
@property (nonatomic, assign) BOOL          needsContext;
/// One-sentence explanation of why this tier was chosen
@property (nonatomic, copy)   NSString     *reason;
/// Tier 1: the direct answer text to display to the user.
/// Tiers 2-4: the enriched prompt to send to the main model
/// (may include injected memory context as a preamble).
@property (nonatomic, copy)   NSString     *finalPrompt;
/// Rough token count of finalPrompt (used for budget logging)
@property (nonatomic, assign) NSInteger     estimatedTokens;
/// Tier 1 only: if non-nil, display this string and skip the API call entirely
@property (nonatomic, copy, nullable) NSString              *shortCircuitAnswer;
/// Tier 4 only: array of API-ready message dicts loaded from the thread on disk.
/// ViewController prepends these to chatContext before sending.
@property (nonatomic, strong, nullable) NSArray<NSDictionary *> *injectedHistory;
/// Confidence score the classifier assigned (0.0 – 1.0)
@property (nonatomic, assign) float         confidence;
@end

// ─────────────────────────────────────────────────────────────────────────────
// EZChatThread — one complete saved conversation
// ─────────────────────────────────────────────────────────────────────────────

@interface EZChatThread : NSObject
/// Unique identifier — ISO-8601 timestamp of when the thread was created,
/// e.g. "2026-03-20T13:28:20". Used as the filename and as the chatKey
/// stored in memory entries so we can find the thread later.
@property (nonatomic, copy)   NSString                *threadID;
/// Short title derived from the first user message (truncated to 60 chars)
@property (nonatomic, copy)   NSString                *title;
/// Longer display preview (currently same as title; reserved for future use)
@property (nonatomic, copy)   NSString                *displayText;
/// Full OpenAI-format message array: [{role, content}, ...]
@property (nonatomic, strong) NSArray<NSDictionary *> *chatContext;
/// The model name that was active when the thread was created
@property (nonatomic, copy)   NSString                *modelName;
/// ISO-8601 creation timestamp
@property (nonatomic, copy)   NSString                *createdAt;
/// ISO-8601 last-updated timestamp (set on every save)
@property (nonatomic, copy)   NSString                *updatedAt;
/// Local filesystem paths of files attached during this conversation
@property (nonatomic, strong) NSArray<NSString *>     *attachmentPaths;
/// Local path of the last image generated or edited in this thread (optional)
@property (nonatomic, copy, nullable) NSString        *lastImageLocalPath;
/// Local path of the last video generated in this thread (optional)
@property (nonatomic, copy, nullable) NSString        *lastVideoLocalPath;
- (NSDictionary *)toDictionary;
+ (nullable instancetype)fromDictionary:(NSDictionary *)dict;
@end

// ─────────────────────────────────────────────────────────────────────────────
// Context Analyzer (4-tier routing)
// ─────────────────────────────────────────────────────────────────────────────

/// Classify a user prompt and decide how much context to inject.
/// Dispatches to a background queue and calls completion on the main queue.
///
/// @param userPrompt    The raw text the user typed
/// @param memoryContext Pre-fetched relevant memory entries as a formatted string.
///                      Pass the result of EZThreadSearchMemory() or loadMemoryContext().
/// @param apiKey        OpenAI API key
/// @param chatKey       threadID of the currently active thread. Used as a
///                      fallback chatKey when loading Tier-4 history from disk.
/// @param completion    Called on main queue with the routing decision.
void analyzePromptForContext(NSString *userPrompt,
                             NSString * _Nullable memoryContext,
                             NSString *apiKey,
                             NSString * _Nullable chatKey,
                             void (^completion)(EZContextResult *result));

// ─────────────────────────────────────────────────────────────────────────────
// Memory Store  (JSON-based, replaces flat .log file)
// ─────────────────────────────────────────────────────────────────────────────

/// Path to the JSON memory store file (Documents/ezui_memory.json)
NSString *EZMemoryGetPath(void);

/// Save a new memory entry after a completed exchange.
/// The entry is a JSON dict with: timestamp, summary, chatKey (links to thread).
/// @param userPrompt    What the user asked
/// @param assistantReply What the model answered (truncated to 1200 chars)
/// @param apiKey        Used to call the summarizer model
/// @param chatKey       threadID to store so Tier-4 can find the full thread
/// @param completion    Called on main queue with the formatted entry string, or nil on failure
void createMemoryFromCompletion(NSString *userPrompt,
                                NSString *assistantReply,
                                NSString *apiKey,
                                NSString * _Nullable chatKey,
                                void (^completion)(NSString * _Nullable entry));

/// Load all memory entries from disk and return them as a formatted string.
/// @param maxEntries  Maximum number of entries to return (most recent first).
///                    Pass 0 to return all entries with no limit.
NSString *loadMemoryContext(NSInteger maxEntries);

/// Load all memory entries as a raw array of NSDictionary objects.
/// Each dict has keys: "timestamp" (NSString), "summary" (NSString), "chatKey" (NSString, may be empty).
/// Returns empty array if the store is empty or unreadable.
NSArray<NSDictionary *> *EZMemoryLoadAll(void);

/// Semantic memory search — finds the most relevant memory entries for a query.
///
/// Strategy (two-stage to control token cost):
///   Stage 1: Local keyword/word-overlap scoring over ALL entries in memory —
///            completely free, no API call. Returns up to 20 candidate entries.
///   Stage 2: Send only those candidates to gpt-4.1-nano with a large enough
///            token budget to rank them and return the top 5 most relevant.
///            If Stage 2 fails, Stage 1 results are returned directly.
///
/// Returns a formatted string of the top relevant entries, or empty string if none found.
/// MUST be called on a background thread (makes a synchronous network call).
NSString *EZThreadSearchMemory(NSString *query, NSString *apiKey);

BOOL clearMemoryLog(void);

// ─────────────────────────────────────────────────────────────────────────────
// Thread Store
// ─────────────────────────────────────────────────────────────────────────────

NSString *EZThreadStoreDir(void);
void EZThreadSave(EZChatThread *thread, void (^ _Nullable completion)(BOOL success));
EZChatThread * _Nullable EZThreadLoad(NSString *threadID);
NSArray<EZChatThread *> *EZThreadList(void);
BOOL EZThreadDelete(NSString *threadID);

/// Load the most-recent turns from a saved thread that fit within a token budget.
/// Walks backwards from the most recent message, accumulating turns until
/// the budget (approx 1 token = 4 chars) is exhausted.
/// Returns nil if the thread is not found or has no messages.
NSArray<NSDictionary *> * _Nullable EZThreadLoadContext(NSString *threadID,
                                                         NSInteger tokenBudget);

// ─────────────────────────────────────────────────────────────────────────────
// Attachment Store
// ─────────────────────────────────────────────────────────────────────────────

NSString * _Nullable EZAttachmentSave(NSData *data, NSString *fileName);
NSString * _Nullable EZAttachmentPath(NSString *savedFileName);

// ─────────────────────────────────────────────────────────────────────────────
// Stats
// ─────────────────────────────────────────────────────────────────────────────

NSString *EZHelperStats(void);

NS_ASSUME_NONNULL_END
