// helpers.h
// EZCompleteUI
//
// System-wide AI and utility helper functions.
// All AI helpers use gpt-4.1-nano (cheap, fast) to minimize token usage.
// The main ViewController.m simply imports this header and calls these functions.
//
// HELPERS OVERVIEW:
//   1. EZLog()                  - Robust logging to file (no AI)
//   2. analyzePromptForContext() - AI "mini-app": decides if extra context is needed before send
//   3. createMemoryFromCompletion() - AI "mini-app": summarizes Q&A pairs into a memory log
//   4. loadMemoryContext()      - Reads the memory log for use as system context
//   5. helperStats()            - Reads logs and prints performance stats (no AI)

#import <Foundation/Foundation.h>

#ifndef helpers_h
#define helpers_h

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Log Level Enum
// ─────────────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, EZLogLevel) {
    EZLogLevelDebug   = 0,
    EZLogLevelInfo    = 1,
    EZLogLevelWarning = 2,
    EZLogLevelError   = 3
};

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Context Analysis Result
// ─────────────────────────────────────────────────────────────────────────────

/// Result returned by analyzePromptForContext()
@interface EZContextResult : NSObject

/// YES if the analyzer recommends injecting extra context before sending.
@property (nonatomic, assign) BOOL needsContext;

/// Human-readable reason from the AI (e.g. "Multi-step technical question").
@property (nonatomic, strong) NSString *reason;

/// The (possibly context-augmented) prompt ready to send to the main model.
/// If needsContext == NO this is identical to the original prompt.
@property (nonatomic, strong) NSString *finalPrompt;

/// Raw token count estimate for the final prompt (rough char/4 heuristic).
@property (nonatomic, assign) NSInteger estimatedTokens;

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 1. Logging
// ─────────────────────────────────────────────────────────────────────────────

/**
 * EZLog — Append a timestamped entry to EZCompleteUI's persistent log file.
 *
 * The log lives in the app's Documents directory: "ezui_helpers.log"
 * Each entry format:
 *   [YYYY-MM-DD HH:MM:SS] [LEVEL] [tag] message
 *
 * @param level   One of EZLogLevelDebug/Info/Warning/Error
 * @param tag     Short category string, e.g. @"CONTEXT", @"MEMORY", @"SEND"
 * @param message The log message (NSString format supported via EZLogf macro)
 */
void EZLog(EZLogLevel level, NSString *tag, NSString *message);

/// Convenience macro — accepts printf-style format args.
/// Usage: EZLogf(EZLogLevelInfo, @"SEND", @"Prompt tokens: %ld", (long)count);
#define EZLogf(level, tag, fmt, ...) \
    EZLog(level, tag, [NSString stringWithFormat:(fmt), ##__VA_ARGS__])

/**
 * EZLogGetPath — Returns the full filesystem path to the current log file.
 * Useful if you want to display or share the log from the UI.
 */
NSString *EZLogGetPath(void);

/**
 * EZLogRotateIfNeeded — If the log file exceeds maxBytes, archive it with a
 * date-stamped filename and start a fresh log. Call from applicationDidBecomeActive
 * or any convenient startup point.
 *
 * @param maxBytes  Rotate when file exceeds this size. Suggested: 512 * 1024 (512 KB).
 */
void EZLogRotateIfNeeded(NSUInteger maxBytes);

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 2. Prompt Context Analyzer (AI Mini-App)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * analyzePromptForContext — Before sending a user prompt to the main model,
 * call this helper. It uses gpt-4.1-nano to quickly decide:
 *   a) Is this a simple question that needs NO extra context? (saves tokens)
 *   b) Is this a complex prompt that SHOULD have memory context injected?
 *
 * The function is asynchronous. Results arrive on the main queue via the
 * completion block.
 *
 * @param userPrompt      The raw prompt the user typed.
 * @param memoryContext   Pass the result of loadMemoryContext() here.
 *                        Can be nil or empty string if no memories exist yet.
 * @param apiKey          Your OpenAI API key.
 * @param completion      Called on main thread with an EZContextResult.
 *                        On network error, result.needsContext == NO and
 *                        result.finalPrompt == userPrompt (fail-open, always send).
 *
 * Example call in ViewController.m:
 *
 *   NSString *memories = loadMemoryContext();
 *   analyzePromptForContext(self.inputField.text, memories, API_KEY, ^(EZContextResult *r) {
 *       [self sendToMainModel:r.finalPrompt];
 *       EZLogf(EZLogLevelInfo, @"CONTEXT", @"needsContext=%d tokens≈%ld reason=%@",
 *              r.needsContext, (long)r.estimatedTokens, r.reason);
 *   });
 */
void analyzePromptForContext(NSString *userPrompt,
                             NSString *memoryContext,
                             NSString *apiKey,
                             void (^completion)(EZContextResult *result));

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 3. Memory Creator (AI Mini-App)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * createMemoryFromCompletion — After each successful chat completion, call this
 * to summarize the Q&A exchange into a compact memory entry. The entry is
 * appended to "ezui_memory.log" in the app's Documents directory.
 *
 * Uses gpt-4.1-nano — very cheap. The summary is intentionally terse (<80 words)
 * so that loading all memories as context stays token-efficient.
 *
 * @param userPrompt       The user's original message.
 * @param assistantReply   The full response from the main model.
 * @param apiKey           Your OpenAI API key.
 * @param completion       Called on main thread. memoryEntry is the string that
 *                         was written to disk, or nil on failure.
 *
 * Example call in ViewController.m (inside your completion handler):
 *
 *   createMemoryFromCompletion(prompt, reply, API_KEY, ^(NSString *entry) {
 *       if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved: %@", entry);
 *   });
 */
void createMemoryFromCompletion(NSString *userPrompt,
                                NSString *assistantReply,
                                NSString *apiKey,
                                void (^completion)(NSString *memoryEntry));

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 4. Memory Loader
// ─────────────────────────────────────────────────────────────────────────────

/**
 * loadMemoryContext — Reads the memory log file and returns a single NSString
 * containing the most recent N memory entries, ready to be injected as context.
 *
 * This is a synchronous, blocking call (reads from disk — fast). Call it on a
 * background thread if you're worried about main-thread blocking on large files.
 *
 * @param maxEntries  Maximum number of recent memory entries to include.
 *                    Recommended: 10–20. Pass 0 to load all entries.
 * @return            A formatted context string, or empty string if no memories.
 *
 * Example:
 *   NSString *ctx = loadMemoryContext(15);
 *   // ctx now contains the last 15 memory summaries for injection into context
 */
NSString *loadMemoryContext(NSInteger maxEntries);

/**
 * EZMemoryGetPath — Returns the full filesystem path to the memory log file.
 */
NSString *EZMemoryGetPath(void);

/**
 * clearMemoryLog — Deletes all stored memories. Use with a confirmation dialog.
 * @return YES on success.
 */
BOOL clearMemoryLog(void);

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 5. Helper Stats / Diagnostics (no AI)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * EZHelperStats — Scans the helper log and returns a human-readable stats
 * summary string. Useful for a debug screen or shake-to-show panel.
 *
 * Reports:
 *   - Total log entries by level
 *   - Context analyzer: how often context was injected vs skipped
 *   - Memory creator: total memories saved, log file size
 *   - Most recent 5 log entries
 *
 * @return Formatted NSString stats report.
 */
NSString *EZHelperStats(void);

#endif /* helpers_h */
