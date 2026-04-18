// helpers.m
// EZCompleteUI v7.0
//
// This file is the "engine room" of EZCompleteUI. It handles four major
// responsibilities that span the entire lifetime of every conversation:
//
//   1. LOGGING          — write timestamped diagnostic lines to a rotating log file
//   2. MEMORY           — save/load/search AI-generated summaries of past sessions
//   3. THREADS          — persist and reload full conversation objects (EZChatThread)
//   4. CONTEXT ROUTING  — a three-stage triage pipeline that decides how much
//                         history to attach to each new message before it reaches
//                         the main GPT model
//
// BEGINNER NOTE — What is a .m file?
//   In Objective-C, every class (or group of functions) is split across two files:
//   • The .h (header) file declares *what* exists — function names, class names,
//     constants — so other files can reference them.
//   • The .m (implementation) file defines *how* it works — the actual code.
//   This is helpers.m, so it contains the actual implementations that match
//   the declarations found in helpers.h.
//
// Low-risk update notes (v7.0):
// - Implements EZCreateMemoryEntry(...) declared in helpers.h
// - Keeps createMemoryFromCompletion(...) as a backwards-compatible wrapper
// - Avoids returning unrelated "recent memories" when search has zero keyword overlap
// - Makes broader thread fallback compatible with current ViewController injection logic
// - Skips duplicate consecutive memory entries
// - Adds a few classifier examples without changing the overall prompt structure

#import "helpers.h"   // Import our own header so the compiler can verify we
                      // implement everything that was promised there.

// ─────────────────────────────────────────────────────────────────────────────
// MODULE-LEVEL CONSTANTS
//
// `static` here means "visible only inside this .m file" — other files cannot
// accidentally reference or overwrite these values. Think of them as private
// configuration knobs for this module.
//
// Using named constants instead of raw strings/numbers ("magic values")
// makes the code self-documenting and lets you change a value in one place.
// ─────────────────────────────────────────────────────────────────────────────

// File names — stored in the app's Documents directory (see _documentsDirectory)
static NSString * const kLogFileName           = @"ezui_helpers.log";   // rolling diagnostic log
static NSString * const kMemoryJSONFileName    = @"ezui_memory.json";   // current memory store (JSON format)
static NSString * const kMemoryLegacyFileName  = @"ezui_memory.log";    // old plaintext format; migrated on first run
static NSString * const kThreadsDirName        = @"EZThreads";          // sub-folder that holds one .json file per thread
static NSString * const kAttachmentsDirName    = @"EZAttachments";      // sub-folder where user-uploaded files are copied

// The lightweight "helper" model used for cheap, fast classification calls.
// Deliberately separate from the main GPT model so we can swap it independently.
static NSString * const kHelperModel           = @"gpt-4.1-nano";
static NSString * const kHelperTemperatureDefaultsKey = @"helperTemperature";

// OpenAI chat endpoint — all helper model calls go here.
static NSString * const kChatCompletionsURL    = @"https://api.openai.com/v1/chat/completions";

// Minimum confidence score (0–1) required before we trust the triage model's
// "I can answer this directly" claim and skip the main model entirely.
// 0.85 = "85% sure" — calibrated to avoid wrong short-circuit answers.
static const float kDirectAnswerConfidenceThreshold = 0.85f;
static const float kAnswerValidatorConfidenceThreshold = 0.75f;

// Maximum tokens to allow the main GPT model to read from an injected thread.
// Higher values = more context but more cost and latency.
static const NSInteger kTier4MaxTokens = 2000;

// How many memory candidates we pre-filter with keyword scoring before handing
// them to the AI ranker. The ranker only ever sees this many entries.
static const NSInteger kMemorySearchCandidateLimit = 12;

// Token budget for the memory-search ranker call (Stage 2).
static const NSInteger kMemorySearchRankerMaxTokens = 1200;

// When the Stage 1 triage says "UNCERTAIN", we fetch this many recent turns
// from the active thread and send them to triage for a second opinion.
static const NSInteger kTriageUncertainTurnFetch = 3;

// Reads helper-model temperature from settings and keeps it in the supported range.
// Defaults to 0.2 when unset or invalid.
static float _helperModelTemperature(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id storedValue = [defaults objectForKey:kHelperTemperatureDefaultsKey];
    float temperature = [storedValue respondsToSelector:@selector(floatValue)]
        ? [storedValue floatValue]
        : 0.2f;
    return MIN(0.5f, MAX(0.0f, temperature));
}


// ─────────────────────────────────────────────────────────────────────────────
// EZContextResult — implementation
//
// This object is what the three-stage triage pipeline returns to the caller
// (ViewController). It answers: "given this user prompt, what should I send
// to GPT and how expensive will it be?"
//
// BEGINNER NOTE — @implementation / @end
//   Every class defined in a .h file must have a matching @implementation block
//   here. Anything you write between @implementation and @end belongs to that
//   class.
// ─────────────────────────────────────────────────────────────────────────────
@implementation EZContextResult

// Designated initializer — sets every property to a safe, non-nil default so
// callers never have to nil-check before reading a property.
- (instancetype)init {
    self = [super init];    // always call the parent's init first
    if (self) {
        // EZRoutingTierSimple is the "cheapest" tier — just send the prompt as-is.
        _tier               = EZRoutingTierSimple;
        _needsContext       = NO;       // assume no history injection needed
        _reason             = @"";     // human-readable explanation of the routing decision
        _finalPrompt        = @"";     // may be enriched with memory/history before sending
        _estimatedTokens    = 0;       // rough cost estimate for UI or logging
        _shortCircuitAnswer = nil;     // if non-nil, use this answer and skip the main model
        _injectedHistory    = nil;     // array of chat turns to prepend to the request
        _confidence         = 0.5f;    // neutral starting confidence
    }
    return self;
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// EZChatThread — private category extension
//
// The `+ez_fromDictionary:fallbackThreadID:` factory is declared here as a
// *class extension* (the empty parentheses `()` in the .h extension vs
// the named one here with "()") so it's invisible to callers outside this file.
// Public callers use `+fromDictionary:` which just forwards to this one.
//
// BEGINNER NOTE — @interface Class ()
//   You can add "private" methods to a class by declaring them in a
//   @interface ClassName () block inside the .m file. Other files importing
//   only the .h will never know this method exists.
// ─────────────────────────────────────────────────────────────────────────────
@interface EZChatThread ()
+ (nullable instancetype)ez_fromDictionary:(NSDictionary *)dict fallbackThreadID:(NSString * _Nullable)fallbackThreadID;
@end


// ─────────────────────────────────────────────────────────────────────────────
// EZChatThread — implementation
//
// EZChatThread is the data model for a single saved conversation. One thread =
// one chat session with its own title, list of messages (chatContext), and
// optional attachment file paths.
// ─────────────────────────────────────────────────────────────────────────────
@implementation EZChatThread

// -init: set every string property to @"" (never nil) and array properties to
// @[] (empty arrays) so property access is always safe without nil-checking.
- (instancetype)init {
    self = [super init];
    if (self) {
        _threadID        = @"";
        _title           = @"New Conversation";
        _displayText     = @"";
        _chatContext     = @[];   // array of {role, content} NSDictionary messages
        _modelName       = @"";
        _createdAt       = @"";
        _updatedAt       = @"";
        _attachmentPaths = @[];  // local file paths for user-uploaded attachments
    }
    return self;
}

// -toDictionary: serializes the object into a plain NSDictionary so it can be
// converted to JSON and written to disk. The ?: @"" / ?: @[] guards protect
// against nil values that would cause NSJSONSerialization to throw.
- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"threadID"]        = _threadID ?: @"";
    dict[@"title"]           = _title ?: @"";
    dict[@"displayText"]     = _displayText ?: @"";
    dict[@"chatContext"]     = _chatContext ?: @[];
    dict[@"modelName"]       = _modelName ?: @"";
    dict[@"createdAt"]       = _createdAt ?: @"";
    dict[@"updatedAt"]       = _updatedAt ?: @"";
    dict[@"attachmentPaths"] = _attachmentPaths ?: @[];

    // Optional image/video paths — only include the key if the value exists.
    // If we always included them, we'd write @"" to every thread even when
    // there's no image, needlessly bloating the files.
    if (_lastImageLocalPath.length > 0) dict[@"lastImageLocalPath"] = _lastImageLocalPath;
    if (_lastVideoLocalPath.length > 0) dict[@"lastVideoLocalPath"] = _lastVideoLocalPath;

    // [dict copy] returns an immutable NSDictionary — good practice before
    // handing data to external callers who shouldn't be able to mutate it.
    return [dict copy];
}

// +fromDictionary: — public factory. Delegates to the private version with no
// fallback threadID. The public interface stays clean while the private version
// handles the edge case of JSON files whose threadID key is missing.
+ (nullable instancetype)fromDictionary:(NSDictionary *)dict {
    return [self ez_fromDictionary:dict fallbackThreadID:nil];
}

// +ez_fromDictionary:fallbackThreadID: — the real deserializer.
//
// This handles JSON that may have come from different versions of the app or
// different external sources by checking multiple key name variants before
// giving up. That "try multiple keys" approach is called "lenient parsing"
// and is important any time JSON may have been created by code you don't
// fully control.
//
// BEGINNER NOTE — nullable return type
//   `nullable` means this method is allowed to return nil. The caller MUST
//   check the return value before using it.  The leading `+` means it's a
//   class method (called on the class, not an instance).
+ (nullable instancetype)ez_fromDictionary:(NSDictionary *)dict fallbackThreadID:(NSString * _Nullable)fallbackThreadID {

    // Safety check — bail immediately if we weren't even given a dictionary.
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;

    EZChatThread *thread = [[EZChatThread alloc] init];

    // ── threadID ─────────────────────────────────────────────────────────────
    // Try three different key names in order of preference (newest API format
    // first, then older variants). This keeps us compatible with data saved by
    // earlier app versions.
    id threadID = dict[@"threadID"] ?: dict[@"threadId"] ?: dict[@"id"];
    if ([threadID isKindOfClass:[NSString class]] && [(NSString *)threadID length] > 0) {
        thread.threadID = threadID;
    } else if (fallbackThreadID.length > 0) {
        // If the JSON has no usable threadID, use the filename stem (passed in
        // by EZThreadList as a last resort).
        thread.threadID = fallbackThreadID;
    }

    // ── title ─────────────────────────────────────────────────────────────────
    // Try "title" first, then "name" (some older exports used "name").
    id title = dict[@"title"] ?: dict[@"name"];
    if ([title isKindOfClass:[NSString class]] && [(NSString *)title length] > 0) {
        thread.title = title;
    }

    // ── displayText ──────────────────────────────────────────────────────────
    // displayText is the subtitle shown in the thread list.  Falls back through
    // several older key names, ultimately defaulting to the title itself.
    id displayText = dict[@"displayText"] ?: dict[@"preview"] ?: dict[@"subtitle"];
    if ([displayText isKindOfClass:[NSString class]]) {
        thread.displayText = displayText;
    } else {
        thread.displayText = thread.title ?: @"";
    }

    // ── modelName, createdAt, updatedAt ──────────────────────────────────────
    id modelName = dict[@"modelName"] ?: dict[@"model"];
    if ([modelName isKindOfClass:[NSString class]]) {
        thread.modelName = modelName;
    }

    id createdAt = dict[@"createdAt"] ?: dict[@"created_at"] ?: dict[@"timestamp"];
    if ([createdAt isKindOfClass:[NSString class]]) {
        thread.createdAt = createdAt;
    }

    // updatedAt falls back to createdAt if missing — better than @"".
    id updatedAt = dict[@"updatedAt"] ?: dict[@"updated_at"] ?: createdAt;
    if ([updatedAt isKindOfClass:[NSString class]]) {
        thread.updatedAt = updatedAt;
    }

    // ── chatContext (message array) ───────────────────────────────────────────
    // The array of {role, content} dictionaries that is the actual conversation.
    id ctx = dict[@"chatContext"] ?: dict[@"messages"] ?: dict[@"context"];
    if ([ctx isKindOfClass:[NSArray class]]) {
        thread.chatContext = ctx;
    }

    // ── attachmentPaths ───────────────────────────────────────────────────────
    // Filter the array to only include non-empty strings, discarding any
    // null/NSNull/non-string values that may have crept in.
    id attachments = dict[@"attachmentPaths"] ?: dict[@"attachments"];
    if ([attachments isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *valid = [NSMutableArray array];
        for (id obj in (NSArray *)attachments) {
            if ([obj isKindOfClass:[NSString class]] && [(NSString *)obj length] > 0) {
                [valid addObject:obj];
            }
        }
        thread.attachmentPaths = [valid copy];
    }

    // ── optional media paths ──────────────────────────────────────────────────
    id imagePath = dict[@"lastImageLocalPath"] ?: dict[@"lastImagePath"];
    if ([imagePath isKindOfClass:[NSString class]]) thread.lastImageLocalPath = imagePath;

    id videoPath = dict[@"lastVideoLocalPath"] ?: dict[@"lastVideoPath"];
    if ([videoPath isKindOfClass:[NSString class]]) thread.lastVideoLocalPath = videoPath;

    // ── Derived-value fallbacks ───────────────────────────────────────────────
    // If we still have no threadID, use createdAt as a unique-enough surrogate.
    if (thread.threadID.length == 0 && thread.createdAt.length > 0) {
        thread.threadID = thread.createdAt;
    }

    // If we have no title but DO have messages, synthesize one from the first
    // user message in the conversation (truncated to 60 chars).
    if (thread.title.length == 0 && thread.chatContext.count > 0) {
        for (NSDictionary *msg in thread.chatContext) {
            if (![msg isKindOfClass:[NSDictionary class]]) continue;
            NSString *role = [msg[@"role"] isKindOfClass:[NSString class]] ? msg[@"role"] : @"";
            if ([role isEqualToString:@"user"]) {
                id content = msg[@"content"];
                NSString *text = nil;
                if ([content isKindOfClass:[NSString class]]) {
                    text = content;
                }
                if (text.length > 0) {
                    // Truncate long first messages so the thread list stays tidy.
                    thread.title = text.length > 60
                        ? [[text substringToIndex:60] stringByAppendingString:@"…"]
                        : text;
                    thread.displayText = thread.title;
                    break;  // stop after the first user message
                }
            }
        }
    }

    // Final safety net — these properties must never be nil or empty.
    if (thread.title.length == 0)       thread.title       = @"New Conversation";
    if (thread.displayText.length == 0) thread.displayText = thread.title ?: @"";
    if (thread.chatContext == nil)       thread.chatContext  = @[];
    if (thread.attachmentPaths == nil)   thread.attachmentPaths = @[];

    return thread;
}

@end  // EZChatThread


// ═════════════════════════════════════════════════════════════════════════════
// SECTION 1 — PRIVATE UTILITY FUNCTIONS
//
// These are pure helper functions with `static` linkage, meaning they are
// completely invisible outside this .m file. They have no side-effects beyond
// what their names describe and are safe to call from anywhere in this file.
//
// BEGINNER NOTE — C functions vs Objective-C methods
//   Functions below start with a lowercase letter and an underscore (e.g.
//   `_safeString`). They are plain C functions, not methods on a class.
//   They take all their inputs as parameters and return a value. They cannot
//   access `self` because there is no object — they're stateless helpers.
// ═════════════════════════════════════════════════════════════════════════════

// Returns the path to the app's Documents directory.
// NSDocumentDirectory is the standard iOS location for user-facing data that
// persists across app launches and is included in iTunes/iCloud backups.
// Falls back to NSTemporaryDirectory() if something goes wrong (extremely rare).
static NSString *_documentsDirectory(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

// Safe cast for any value that should be a string.
// Returns the value as-is if it's already an NSString, otherwise returns @"".
// This prevents crashes when JSON data contains unexpected types (e.g. NSNull).
//
// BEGINNER NOTE — Why not just cast?
//   In Objective-C, casting (NSString *)someObject doesn't verify the type —
//   it just tells the compiler "trust me, it's an NSString." If someObject is
//   actually an NSNumber, you'll get a crash at runtime. `isKindOfClass:` is
//   the safe runtime type check.
static NSString *_safeString(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : @"";
}

// Safe cast for any value that should be an array.
// Returns @[] (empty immutable array) if value isn't an NSArray.
static NSArray *_safeArray(id value) {
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : @[];
}

// Rough token count estimator for cost/budget calculations.
// OpenAI charges per token. 1 token ≈ 4 characters of English text on average,
// so dividing character count by 4 gives a cheap approximation without calling
// the actual tokenizer. The +1 guards against the zero-length string case.
static NSInteger _estimateTokenCount(NSString *text) {
    return (NSInteger)(text.length / 4) + 1;
}

// Returns the current date/time as a human-readable string for display in the
// memory log and in EZHelperStats. Format: "2025-04-14 09:30:00"
// A new NSDateFormatter is created each call — fine here since this is called
// infrequently (once per memory save).
static NSString *_timestampForDisplay(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [formatter stringFromDate:[NSDate date]];
}

// Returns the current date/time as an ISO 8601 string used in thread metadata.
// ISO 8601 ("2025-04-14T09:30:00") is the international standard for timestamps
// and sorts lexicographically, so thread list sort-by-date works with a plain
// string comparison (see EZThreadList).
// The POSIX locale is set explicitly so the format is never affected by the
// user's regional settings (e.g. a 12-hour clock locale).
static NSString *_timestampISO8601(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [formatter stringFromDate:[NSDate date]];
}

// Maps an EZLogLevel enum value to its printable label.
// The trailing space on "INFO " and "WARN " keeps log lines column-aligned
// so they're easier to read in a text editor or grep.
static NSString *_logLevelString(EZLogLevel level) {
    switch (level) {
        case EZLogLevelDebug:   return @"DEBUG";
        case EZLogLevelInfo:    return @"INFO ";
        case EZLogLevelWarning: return @"WARN ";
        case EZLogLevelError:   return @"ERROR";
    }
    return @"INFO ";   // unreachable default satisfies the compiler
}

// Returns a shared serial dispatch queue used for ALL file I/O in this module.
//
// WHY A SERIAL QUEUE?
//   The app reads/writes log and memory files from multiple threads (main thread
//   UI + background network callbacks). If two threads write simultaneously,
//   data can be corrupted. A serial queue ensures operations run one-at-a-time,
//   in the order they were submitted.
//
// WHY dispatch_once?
//   `dispatch_once` guarantees the setup block runs exactly once, even if two
//   threads call this function simultaneously at startup. It's the standard
//   Objective-C pattern for lazy singletons.
static dispatch_queue_t _fileWriteQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ezui.filewrite", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Appends a single text line (plus a newline) to a file on the file-write queue.
// Creates the file if it doesn't exist yet; uses seek-to-end + write to avoid
// loading the entire file into memory just to append one line.
//
// @try/@catch wraps the write in case of a hardware error mid-write.
// @finally ensures the file handle is always closed, even if an exception fires.
//
// BEGINNER NOTE — dispatch_async vs dispatch_sync
//   dispatch_async puts work on a queue and returns immediately (non-blocking).
//   dispatch_sync puts work on a queue and WAITS for it to finish (blocking).
//   File appends use async because we don't need to know when the write finishes;
//   we just need the writes to be ordered.
static void _appendLineToFile(NSString *filePath, NSString *line) {
    dispatch_async(_fileWriteQueue(), ^{
        NSData *lineData = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:filePath]) {
            // File doesn't exist — create it with the first line as initial content.
            [fm createFileAtPath:filePath contents:lineData attributes:nil];
            return;
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:filePath];
        if (!fh) return;  // file exists but can't be opened (permissions issue?)
        @try {
            [fh seekToEndOfFile];
            [fh writeData:lineData];
        } @catch (__unused NSException *exception) {
            // Silently ignore write errors — logging must never crash the app.
            // The __unused attribute suppresses the "unused variable" compiler warning.
        } @finally {
            [fh closeFile];
        }
    });
}

// Strips ```json ... ``` (or any ``` ... ```) markdown code fences from a string.
//
// WHY IS THIS NEEDED?
//   Even at temperature=0.2 with explicit "no markdown" instructions, GPT models
//   occasionally wrap JSON output in markdown code fences. Without stripping them,
//   NSJSONSerialization will fail to parse the response and the whole feature breaks.
//
// Algorithm:
//   1. Trim leading/trailing whitespace.
//   2. If the string doesn't start with "```", return it unchanged.
//   3. Drop everything up to and including the first newline (the "```json" line).
//   4. Drop the trailing "```".
//   5. Trim again to remove any residual whitespace.
static NSString *_stripMarkdownFences(NSString *rawResponse) {
    NSString *trimmed = [rawResponse stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed hasPrefix:@"```"]) return trimmed;  // no fence, nothing to do

    // Find the end of the opening "```json\n" line and skip past it.
    NSRange firstNewline = [trimmed rangeOfString:@"\n"];
    if (firstNewline.location != NSNotFound) {
        trimmed = [trimmed substringFromIndex:firstNewline.location + 1];
    }
    // Remove the closing "```" at the end.
    if ([trimmed hasSuffix:@"```"] && trimmed.length >= 3) {
        trimmed = [trimmed substringToIndex:trimmed.length - 3];
    }
    return [trimmed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Normalizes a string for keyword search by:
//   • lowercasing every character
//   • replacing any non-alphanumeric character (punctuation, slashes, etc.)
//     with a space
//   • collapsing runs of whitespace into single spaces
//
// The output is used both to index memory entries and to tokenize queries,
// so the same normalization applies to both sides of a comparison.
//
// Example: "ViewController+EZTopButtons.m" → "viewcontroller eztopbuttons m"
static NSString *_normalizeForSearch(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return @"";
    NSMutableString *result = [NSMutableString stringWithCapacity:text.length];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ([alnum characterIsMember:c]) {
            [result appendFormat:@"%C", (unichar)tolower(c)];  // lowercase alphanumeric
        } else {
            [result appendString:@" "];  // replace punctuation/symbols with space
        }
    }
    // Split on whitespace, discard empty parts, rejoin with single spaces.
    NSArray *parts = [result componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    return [clean componentsJoinedByString:@" "];
}

// Tokenizes a search query into meaningful keywords by:
//   1. Normalizing (lowercasing + stripping punctuation).
//   2. Removing words shorter than 3 characters (mostly noise), while keeping
//      numeric tokens (e.g. "10", "2fa", "v2") because numbers are often
//      high-signal in memory lookups.
//   3. Removing common English stop words that carry no semantic weight.
//
// WHY STOP WORDS?
//   If you search for "what did we do with the file", the words "what", "did",
//   "we", "do", "with", "the" match almost everything. Removing them lets the
//   scorer focus on "file", which is the only word that distinguishes this query.
//
// The stop-word set is initialized once (dispatch_once) and reused — it's
// immutable after construction so it's safe to share across threads.
static NSArray<NSString *> *_searchTerms(NSString *query) {
    static NSSet<NSString *> *stopWords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stopWords = [NSSet setWithObjects:
                     @"a",@"an",@"the",@"is",@"was",@"are",@"were",@"i",@"my",@"me",@"you",
                     @"your",@"it",@"to",@"of",@"in",@"on",@"at",@"for",@"and",@"or",@"but",
                     @"can",@"do",@"did",@"will",@"with",@"that",@"this",@"what",@"how",@"we",
                     @"our",@"their",@"them",@"from",@"about",@"again", nil];
    });

    NSString *normalized = _normalizeForSearch(query);
    NSArray<NSString *> *rawParts = [normalized componentsSeparatedByString:@" "];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in rawParts) {
        BOOL hasDigit = [part rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound;
        if (part.length <= 2 && !hasDigit) continue;  // keep short numeric tokens
        if ([stopWords containsObject:part]) continue; // common word, skip
        [parts addObject:part];
    }
    return [parts copy];
}

// Extracts readable text from an OpenAI message's `content` field.
//
// WHY IS THIS NEEDED?
//   OpenAI message content can be:
//   a) A plain NSString — simple text message.
//   b) An NSArray of "content blocks" — used for multi-modal messages that
//      mix text with images (e.g. vision requests).
//
//   This function normalizes both forms into a single plain string so the rest
//   of the code never has to care which format it got.
//
// For content blocks, text blocks are concatenated; image blocks produce the
// placeholder "[image]" so downstream scorers know an image was present.
static NSString *_messageTextFromContent(id content) {
    if ([content isKindOfClass:[NSString class]]) {
        return (NSString *)content;
    }
    if ([content isKindOfClass:[NSArray class]]) {
        NSMutableString *out = [NSMutableString string];
        for (id block in (NSArray *)content) {
            if (![block isKindOfClass:[NSDictionary class]]) continue;
            NSString *type = _safeString(((NSDictionary *)block)[@"type"]);
            NSString *text = _safeString(((NSDictionary *)block)[@"text"]);
            if (text.length > 0) {
                if (out.length > 0) [out appendString:@"\n"];
                [out appendString:text];
            } else if ([type containsString:@"image"]) {
                if (out.length > 0) [out appendString:@"\n"];
                [out appendString:@"[image]"];  // placeholder so scorers see the signal
            }
        }
        return [out copy];
    }
    return @"";
}

// Returns YES if `term` looks like an Objective-C identifier, filename, or
// similarly structured technical token (contains ., _, :, or +).
// Deliberately does NOT include / (forward slash) anymore — we no longer
// store or search full file system paths in summaries.
//
// WHY DOES THIS MATTER?
//   Identifier-shaped terms ("helpers.m", "EZKeyVault", etc.) are often
//   strong precision signals when picking relevant turns from a thread.
//   Callers use this helper when they need raw-text matching for those terms.
static BOOL _looksLikePathOrIdentifier(NSString *term) {
    return ([term containsString:@"."] ||
            [term containsString:@"_"] ||
            [term containsString:@":"] ||
            [term containsString:@"+"]);
}


// ─────────────────────────────────────────────────────────────────────────────
// _callHelperModelSync — Core synchronous OpenAI API call
//
// This is the single function that all helper-model calls in this file funnel
// through. It sends a system prompt + one user message to kHelperModel and
// returns the model's plain-text reply (or nil on any error).
//
// "Sync" means it BLOCKS the calling thread until the network call completes.
// This is acceptable because every caller already runs on a background queue
// (see dispatch_async in analyzePromptForContext and EZCreateMemoryEntry).
// You must NEVER call this on the main thread.
//
// Request structure:
//   temperature: user-controlled helper setting (0.0–0.5, defaults to 0.2)
//   max_tokens: caller-specified — different tasks need different budgets
//
// BEGINNER NOTE — How the semaphore works
//   NSURLSession is asynchronous — it calls a completion block when done.
//   But we need the result before we can return from this function.
//   A dispatch_semaphore acts like a "gate":
//   • dispatch_semaphore_create(0)        → gate starts CLOSED
//   • dispatch_semaphore_signal(semaphore) → opens the gate (called inside the completion block)
//   • dispatch_semaphore_wait(...)         → blocks here until the gate opens
//   After the wait returns, responseData holds the result.
// ─────────────────────────────────────────────────────────────────────────────
static NSString *_callHelperModelSync(NSString *systemPrompt,
                                      NSString *userMessage,
                                      NSString *apiKey,
                                      NSInteger maxTokens) {
    if (apiKey.length == 0) return nil;  // no key → bail immediately, don't try to call the API

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kChatCompletionsURL]];
    request.HTTPMethod     = @"POST";
    request.timeoutInterval = 20;   // 20-second timeout — helper calls should be fast
    [request setValue:@"application/json"                          forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    // Build the JSON request body.
    // Helper temperature is clamped to 0.0–0.5 so classifier/ranker behavior
    // stays stable while still allowing small randomness tuning.
    NSDictionary *requestBody = @{
        @"model":       kHelperModel,
        @"max_tokens":  @(maxTokens),
        @"temperature": @(_helperModelTemperature()),
        @"messages": @[
            @{@"role": @"system", @"content": systemPrompt ?: @""},
            @{@"role": @"user",   @"content": userMessage  ?: @""}
        ]
    };

    NSError *encodingError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:requestBody options:0 error:&encodingError];
    if (encodingError || !request.HTTPBody) {
        return nil;  // shouldn't happen with well-formed dicts, but handle it anyway
    }

    // Set up the semaphore gate (starts closed).
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData  *responseData = nil;
    __block NSError *networkError = nil;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        // Cast response to NSHTTPURLResponse to read the HTTP status code.
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
                                    ? (NSHTTPURLResponse *)response : nil;
        if (http && (http.statusCode < 200 || http.statusCode >= 300)) {
            // Non-2xx status (e.g. 401 Unauthorized, 429 Rate Limited, 500 Server Error).
            // Store as an error; responseData stays nil.
            networkError = [NSError errorWithDomain:@"EZHelpersHTTP"
                                               code:http.statusCode
                                           userInfo:nil];
        } else {
            responseData = data;
            networkError = error;
        }
        dispatch_semaphore_signal(semaphore);  // open the gate — unblocks the wait below
    }] resume];  // don't forget to call resume! tasks start suspended.

    // Block here until the completion handler fires.
    // DISPATCH_TIME_FOREVER means wait as long as needed (the timeoutInterval
    // on the request will fire before this becomes infinite in practice).
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (networkError || responseData.length == 0) return nil;

    // Parse the response JSON. OpenAI returns:
    // { "choices": [ { "message": { "role": "assistant", "content": "..." } } ] }
    NSError *parseError = nil;
    NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&parseError];
    if (parseError || ![jsonResponse isKindOfClass:[NSDictionary class]]) return nil;

    // Safely walk the nested structure: choices[0].message.content
    id choices = jsonResponse[@"choices"];
    if (![choices isKindOfClass:[NSArray class]] || [(NSArray *)choices count] == 0) return nil;

    id firstChoice = ((NSArray *)choices)[0];
    if (![firstChoice isKindOfClass:[NSDictionary class]]) return nil;

    id message = ((NSDictionary *)firstChoice)[@"message"];
    if (![message isKindOfClass:[NSDictionary class]]) return nil;

    id content = ((NSDictionary *)message)[@"content"];
    if (![content isKindOfClass:[NSString class]]) return nil;

    // Trim whitespace/newlines from the response before returning it.
    return [(NSString *)content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}


// ═════════════════════════════════════════════════════════════════════════════
// SECTION 2 — LOGGING
//
// A minimal structured logging system that writes to a rotating text file.
// Every log line has the format:
//   [2025-04-14 09:30:00] [INFO ] [TAG] message text here
//
// In DEBUG builds, lines are also printed to the Xcode console via NSLog.
// ═════════════════════════════════════════════════════════════════════════════

// Returns the absolute path to the current log file.
// Exposed publicly (no `static`) so ViewController can show the log path in
// the stats UI or offer to share the file.
NSString *EZLogGetPath(void) {
    return [_documentsDirectory() stringByAppendingPathComponent:kLogFileName];
}

// EZLog — the primary logging function.
//
// Parameters:
//   level   — severity (EZLogLevelDebug / Info / Warning / Error)
//   tag     — short ALL-CAPS category, e.g. @"MEMORY", @"THREADS", @"TRIAGE"
//   message — the human-readable log message
//
// In DEBUG builds, NSLog prints to the Xcode console in real time.
// In Release builds (#ifdef DEBUG is false), only the file write happens.
//
// BEGINNER NOTE — #ifdef / #endif
//   These are "preprocessor directives" evaluated at compile time. When Xcode
//   builds for debugging, it defines the DEBUG symbol; when building for the
//   App Store, it doesn't. So the NSLog call literally doesn't exist in
//   release builds — it's removed before compilation.
void EZLog(EZLogLevel level, NSString *tag, NSString *message) {
    NSString *logLine = [NSString stringWithFormat:@"[%@] [%@] [%@] %@",
                         _timestampForDisplay(),
                         _logLevelString(level),
                         tag ?: @"GENERAL",
                         message ?: @""];
#ifdef DEBUG
    NSLog(@"%@", logLine);
#endif
    _appendLineToFile(EZLogGetPath(), logLine);
}

// EZLogRotateIfNeeded — rolls the log file when it exceeds maxSizeBytes.
//
// WHY ROTATE?
//   Log files grow indefinitely without rotation. On a device with limited
//   storage, a multi-MB log is wasteful and makes the file slow to scan.
//   Rotation renames the current log to a timestamped archive file and lets
//   the next EZLog call create a fresh empty file.
//
// Caller responsibility: call this at app launch or after significant activity.
// The archived file is NOT automatically deleted — add cleanup logic if needed.
void EZLogRotateIfNeeded(NSUInteger maxSizeBytes) {
    NSString *logPath = EZLogGetPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:logPath error:nil];
    NSUInteger size = (NSUInteger)[attrs[NSFileSize] unsignedLongLongValue];
    if (size < maxSizeBytes || size == 0) return;  // under the limit, nothing to do

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *archiveName = [NSString stringWithFormat:@"ezui_helpers_%@.log",
                              [formatter stringFromDate:[NSDate date]]];
    NSString *archivePath = [_documentsDirectory() stringByAppendingPathComponent:archiveName];
    [[NSFileManager defaultManager] moveItemAtPath:logPath toPath:archivePath error:nil];
    EZLog(EZLogLevelInfo, @"LOG", [NSString stringWithFormat:@"Rotated to %@", archiveName]);
}


// ═════════════════════════════════════════════════════════════════════════════
// SECTION 3 — MEMORY STORE
//
// "Memory" here means AI-generated one-sentence summaries of past chat turns,
// stored as a JSON array on disk. When a user returns and asks a follow-up
// question, the app searches this store to find relevant prior context.
//
// Storage format (ezui_memory.json):
//   [
//     { "timestamp": "2025-04-14 09:30:00",
//       "summary":   "User asked about X and assistant explained Y.",
//       "chatKey":   "2025-04-14T09:29:00",
//       "attachmentPaths": ["helpers.m"]   // stores original full paths; only
//                                          // filenames are shown in summaries
//     },
//     ...
//   ]
//
// Legacy support: older versions stored memories as a plaintext log
// (ezui_memory.log). _migrateMemoryIfNeeded() converts that format
// automatically on first run with the new code.
// ═════════════════════════════════════════════════════════════════════════════

// Returns the full path to the JSON memory store file.
NSString *EZMemoryGetPath(void) {
    return [_documentsDirectory() stringByAppendingPathComponent:kMemoryJSONFileName];
}

// Returns the full path to the OLD plaintext memory log (pre-JSON era).
// Only used by the migration function below.
static NSString *_legacyMemoryLogPath(void) {
    return [_documentsDirectory() stringByAppendingPathComponent:kMemoryLegacyFileName];
}

// _migrateMemoryIfNeeded — one-time migration from plaintext to JSON format.
//
// When to run: automatically called by _loadMemoryEntries() before every load.
// Early-exit conditions: JSON file already exists, or legacy file doesn't exist.
//
// Migration strategy:
//   Each line in the legacy file looks like one of:
//     [2025-04-14 09:30:00] [chatKey=2025-04-14T09:29:00] summary text here
//     [2025-04-14 09:30:00] summary text here (no chatKey)
//
//   Parse each line into its component parts and write a JSON array.
//   Lines that parse to empty summaries are silently dropped.
static void _migrateMemoryIfNeeded(void) {
    NSString *jsonPath    = EZMemoryGetPath();
    NSString *legacyPath  = _legacyMemoryLogPath();

    // Nothing to do if the JSON store already exists (migration already ran).
    if ([[NSFileManager defaultManager] fileExistsAtPath:jsonPath])   return;
    // Nothing to do if there's no legacy file to migrate from.
    if (![[NSFileManager defaultManager] fileExistsAtPath:legacyPath]) return;

    NSError  *readError     = nil;
    NSString *legacyContent = [NSString stringWithContentsOfFile:legacyPath
                                                         encoding:NSUTF8StringEncoding
                                                            error:&readError];
    if (readError || legacyContent.length == 0) return;

    NSMutableArray *migratedEntries = [NSMutableArray array];
    for (NSString *line in [legacyContent componentsSeparatedByString:@"\n"]) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmedLine.length == 0) continue;

        NSString *timestamp = @"";
        NSString *chatKey   = @"";
        NSString *summary   = trimmedLine;

        // Try to extract a leading "[timestamp]" token.
        NSRange tsStart = [trimmedLine rangeOfString:@"["];
        NSRange tsEnd   = [trimmedLine rangeOfString:@"]"];
        if (tsStart.location == 0 && tsEnd.location != NSNotFound && tsEnd.location > 1) {
            timestamp = [trimmedLine substringWithRange:NSMakeRange(1, tsEnd.location - 1)];
            // Everything after the closing ] is the rest of the line.
            summary   = [[trimmedLine substringFromIndex:tsEnd.location + 1]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }

        // Try to extract an embedded "[chatKey=...]" tag from the remaining text.
        NSRange ckRange = [summary rangeOfString:@"[chatKey="];
        if (ckRange.location != NSNotFound) {
            NSRange ckEnd = [summary rangeOfString:@"]" options:0
                                            range:NSMakeRange(ckRange.location, summary.length - ckRange.location)];
            if (ckEnd.location != NSNotFound && ckEnd.location > ckRange.location + 8) {
                NSRange valueRange = NSMakeRange(ckRange.location + 8,
                                                 ckEnd.location - ckRange.location - 8);
                chatKey = [summary substringWithRange:valueRange];
                // Rebuild summary without the [chatKey=...] tag.
                NSString *before = [summary substringToIndex:ckRange.location];
                NSString *after  = [summary substringFromIndex:ckEnd.location + 1];
                summary = [[before stringByAppendingString:after]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
        }

        if (summary.length > 0) {
            [migratedEntries addObject:@{
                @"timestamp": timestamp ?: @"",
                @"summary":   summary   ?: @"",
                @"chatKey":   chatKey   ?: @""
            }];
        }
    }

    if (migratedEntries.count == 0) return;

    // Write the migrated entries as a pretty-printed JSON array.
    // NSDataWritingAtomic writes to a temp file first then renames — this prevents
    // data corruption if the app is killed mid-write.
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:migratedEntries
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:nil];
    if (!jsonData) return;
    [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:nil];
    EZLogf(EZLogLevelInfo, @"MEMORY", @"Migrated %lu legacy entries to JSON store",
           (unsigned long)migratedEntries.count);
}

// _loadMemoryEntries — private. Reads and parses the JSON memory file.
// Runs migration first if needed. Returns a mutable array so callers can
// append to it before passing to _saveMemoryEntries.
// Returns an empty array (never nil) on any read/parse error.
static NSMutableArray<NSDictionary *> *_loadMemoryEntries(void) {
    _migrateMemoryIfNeeded();  // no-op after the first successful migration

    NSData *fileData = [NSData dataWithContentsOfFile:EZMemoryGetPath() options:0 error:nil];
    if (!fileData) return [NSMutableArray array];  // file doesn't exist yet

    id parsed = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:nil];
    if (![parsed isKindOfClass:[NSArray class]]) return [NSMutableArray array];

    // Filter out any non-dictionary elements that might have crept in
    // (e.g. from a partial write or manual file edit).
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (id obj in (NSArray *)parsed) {
        if ([obj isKindOfClass:[NSDictionary class]]) {
            [out addObject:obj];
        }
    }
    return out;
}

// _saveMemoryEntries — private. Serializes the array to pretty-printed JSON
// and writes atomically. Logs errors but never throws — failure to save a
// memory entry should never crash the app.
static void _saveMemoryEntries(NSArray<NSDictionary *> *entries) {
    NSError *serializeError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:entries
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&serializeError];
    if (serializeError || !jsonData) {
        EZLogf(EZLogLevelError, @"MEMORY", @"Failed to serialize entries: %@", serializeError);
        return;
    }

    NSError *writeError = nil;
    [jsonData writeToFile:EZMemoryGetPath() options:NSDataWritingAtomic error:&writeError];
    if (writeError) {
        EZLogf(EZLogLevelError, @"MEMORY", @"Failed to write memory JSON: %@", writeError);
    }
}

// EZMemoryLoadAll — public read-only access to the full memory store.
// Used by EZHelperStats for the stats display and by tests.
NSArray<NSDictionary *> *EZMemoryLoadAll(void) {
    return _loadMemoryEntries();
}

// loadMemoryContext — formats the most recent N memory entries as a single
// human-readable string suitable for injecting into a GPT prompt.
//
// maxEntries: maximum number of entries to include (0 = all entries).
//
// Output format per line:
//   [2025-04-14 09:30:00] [chatKey=2025-04-14T09:29:00] [file:foo.m] summary text
//
// The chatKey and file tags are included because downstream code (like
// _bestChatKeyFromMemoryContext) parses them back out to determine which
// saved thread to load.
NSString *loadMemoryContext(NSInteger maxEntries) {
    NSArray<NSDictionary *> *allEntries = _loadMemoryEntries();
    if (allEntries.count == 0) return @"";

    // Slice to the last N entries if a limit was given.
    NSArray<NSDictionary *> *entriesToReturn = allEntries;
    if (maxEntries > 0 && (NSInteger)allEntries.count > maxEntries) {
        NSRange range = NSMakeRange(allEntries.count - (NSUInteger)maxEntries, (NSUInteger)maxEntries);
        entriesToReturn = [allEntries subarrayWithRange:range];
    }

    NSMutableArray<NSString *> *formattedLines = [NSMutableArray array];
    for (NSDictionary *entry in entriesToReturn) {
        NSString *timestamp   = _safeString(entry[@"timestamp"]);
        NSString *summary     = _safeString(entry[@"summary"]);
        NSString *chatKey     = _safeString(entry[@"chatKey"]);
        NSArray  *attachments = _safeArray(entry[@"attachmentPaths"]);

        // Build optional inline tags.
        NSString *keyTag = chatKey.length > 0
            ? [NSString stringWithFormat:@" [chatKey=%@]", chatKey] : @"";

        NSMutableString *attachTag = [NSMutableString string];
        for (id obj in attachments) {
            NSString *path = _safeString(obj);
            if (path.length > 0) {
                // lastPathComponent extracts just the filename from a full path.
                [attachTag appendFormat:@" [file:%@]", path.lastPathComponent];
            }
        }

        [formattedLines addObject:[NSString stringWithFormat:@"[%@]%@%@ %@",
                                   timestamp, keyTag, attachTag, summary]];
    }

    return [formattedLines componentsJoinedByString:@"\n"];
}

// clearMemoryLog — deletes the entire memory JSON file.
// Returns YES if deletion succeeded, NO otherwise.
// Useful for the "Clear Memory" button in Settings.
BOOL clearMemoryLog(void) {
    NSError *error = nil;
    BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:EZMemoryGetPath() error:&error];
    if (!removed && error) {
        EZLogf(EZLogLevelError, @"MEMORY", @"Clear failed: %@", error);
    } else if (removed) {
        EZLog(EZLogLevelInfo, @"MEMORY", @"Memory store cleared.");
    }
    return removed;
}

// _memoryEntryLocalScore — keyword-based relevance scorer for a single memory entry.
//
// Higher score = more likely to be relevant to the query.
//
// Scoring logic (points per term that matches):
//   +8   term found in normalized summary text
//   +20  term found in chatKey (the session timestamp)
//
// NOTE: Attachment paths used to receive large separate bonuses (+15/+25) here,
// but since summaries now always embed filenames directly (Rule 1 of the
// summarizer prompt), the +8/+12 summary match already captures file hits.
// Keeping a separate attachment bonus on top just drowns out non-file memories.
static NSInteger _memoryEntryLocalScore(NSDictionary *entry, NSString *query) {
    NSString *summary     = _safeString(entry[@"summary"]);
    NSString *chatKey     = _safeString(entry[@"chatKey"]);
    NSArray<NSString *> *terms = _searchTerms(query);
    NSString *normalizedSummary = _normalizeForSearch(summary);
    NSInteger score = 0;

    for (NSString *term in terms) {
        // Summary match — the main scoring axis.
        if ([normalizedSummary containsString:term])                                    score += 8;
        // chatKey match — strongest relevance signal when the query includes
        // a timestamp-like term that points to a specific memory/thread.
       if ([chatKey.lowercaseString containsString:term.lowercaseString])              score += 20;
    }

    return score;
}

// EZThreadSearchMemory — the two-phase memory search used by Stage 2 of the
// triage pipeline.
//
// PHASE 1 — Keyword scoring (fast, local, no API call):
//   Score every memory entry against the query using _memoryEntryLocalScore.
//   Keep the top kMemorySearchCandidateLimit entries that have a score > 0.
//   If NONE have a positive score, return @"" immediately — no AI call needed.
//   (This is the key fix from v7.0: avoids surfacing unrelated memories.)
//
// PHASE 2 — AI ranker (smarter, costs one API call):
//   Send the top candidates to a small LLM ranker that reads them and picks
//   the 1-3 most semantically relevant. Returns the winning entries verbatim
//   (so the caller can display or inject them without re-formatting).
//
// If the AI ranker call fails, falls back to the top 3 keyword results.
// If apiKey is empty, falls back to loadMemoryContext(5) as a dumb fallback.
NSString *EZThreadSearchMemory(NSString *searchQuery, NSString *apiKey) {
    NSArray<NSDictionary *> *allEntries = _loadMemoryEntries();
    if (allEntries.count == 0) {
        EZLog(EZLogLevelInfo, @"MEMORY", @"Search: memory store is empty");
        return @"";
    }

    // No API key — can't call the ranker. Return the 5 most recent entries raw.
    if (apiKey.length == 0) {
        return loadMemoryContext(5);
    }

    // ── PHASE 1: Keyword scoring ──────────────────────────────────────────────
    NSMutableArray<NSDictionary *> *scoredEntries = [NSMutableArray array];
    for (NSDictionary *entry in allEntries) {
        NSInteger score = _memoryEntryLocalScore(entry, searchQuery ?: @"");
        [scoredEntries addObject:@{
            @"entry": entry,
            @"score": @(score)
        }];
    }

    // Sort descending by score; break ties by recency (higher original index = more recent).
    [scoredEntries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger scoreA = [a[@"score"] integerValue];
        NSInteger scoreB = [b[@"score"] integerValue];
        if (scoreA != scoreB) return scoreB > scoreA ? NSOrderedDescending : NSOrderedAscending;
        // Tie-break: prefer the more recent entry (higher index in allEntries).
        NSUInteger indexA = [allEntries indexOfObject:a[@"entry"]];
        NSUInteger indexB = [allEntries indexOfObject:b[@"entry"]];
        if (indexA == indexB) return NSOrderedSame;
        return indexB > indexA ? NSOrderedDescending : NSOrderedAscending;
    }];

    // Keep only the top N candidates.
    NSInteger candidateCount  = MIN(kMemorySearchCandidateLimit, (NSInteger)scoredEntries.count);
    NSArray  *topCandidates   = [scoredEntries subarrayWithRange:NSMakeRange(0, (NSUInteger)candidateCount)];

    // v7.0 fix: bail early if NOTHING scored above zero — returning random
    // recent memories when there's no keyword overlap just pollutes the context.
    BOOL anyPositive = NO;
    for (NSDictionary *scored in topCandidates) {
        if ([scored[@"score"] integerValue] > 0) { anyPositive = YES; break; }
    }
    if (!anyPositive) {
        EZLog(EZLogLevelInfo, @"MEMORY", @"Search: no keyword overlap found — returning empty result");
        return @"";
    }

    // Build the text block of candidate memory lines for the AI ranker.
    NSMutableArray<NSString *> *candidateLines = [NSMutableArray array];
    for (NSDictionary *scored in topCandidates) {
        NSDictionary *entry    = scored[@"entry"];
        NSString *timestamp    = _safeString(entry[@"timestamp"]);
        NSString *summary      = _safeString(entry[@"summary"]);
        NSString *chatKey      = _safeString(entry[@"chatKey"]);
        NSArray  *attachments  = _safeArray(entry[@"attachmentPaths"]);

        NSString *keyTag = chatKey.length > 0
            ? [NSString stringWithFormat:@" [chatKey=%@]", chatKey] : @"";

        NSMutableString *attachTag = [NSMutableString string];
        for (id obj in attachments) {
            NSString *path = _safeString(obj);
            if (path.length > 0) {
                // Emit only the filename — not the full path — in the candidate
                // line shown to the AI ranker. Full paths are long, stale between
                // installs, and add noise the tiny ranker model doesn't need.
                [attachTag appendFormat:@" [file:%@]", path.lastPathComponent];
            }
        }

        [candidateLines addObject:[NSString stringWithFormat:@"[%@]%@%@ %@",
                                   timestamp, keyTag, attachTag, summary]];
    }

    // ── PHASE 2: AI Ranker ────────────────────────────────────────────────────
    //
    // The ranker's job: read the candidate lines and return only those that are
    // truly relevant, verbatim. No summaries, no grep output, no invented text.
    //
    // WHY TWO SHORT EXAMPLES instead of one long one?
    //   Helper models like gpt-4.1-nano have small contexts and limited reasoning.
    //   One short "do this" example teaches the copy-verbatim rule. One short
    //   "no match → 0" example teaches the bail-out rule. Together they cover
    //   the two most common failure modes without overwhelming the model.
    NSString *rankerSystemPrompt =
        // Core task — one job, stated simply.
        @"You are a memory relevance ranker. "
        @"Read the search query and the list of memory entries below. "
        @"Pick up to 3 entries that would most help answer the query.\n\n"
        //
        // Rule 1: copy exactly — don't rewrite or summarize.
        @"RULE 1 — Copy the chosen entries EXACTLY as they appear in the list. "
        @"Do not change, shorten, or rewrite them.\n"
        //
        // Rule 2: no duplicates.
        @"RULE 2 — If two entries say basically the same thing, return only the more specific one.\n"
        //
        // Rule 3: none relevant → return 0. This prevents the model from
        // returning random entries just to appear helpful.
        @"RULE 3 — If no entries are relevant to the query, return the single digit: 0\n\n"
        //
        // ── EXAMPLE A: one match found ──────────────────────────────────────
        // Short and concrete: teaches copy-verbatim and relevance selection.
        @"EXAMPLE A — when one entry matches:\n"
        @"Query: \"EZKeyVault\"\n"
        @"Entries:\n"
        @"[2026-03-20 09:00:00] [chatKey=2026-03-20T08:59:00] User asked about migrating API keys to EZKeyVault in helpers.m\n"
        @"[2026-03-19 14:00:00] [chatKey=2026-03-19T13:59:00] User asked how to center a UILabel\n"
        @"Correct output:\n"
        @"[2026-03-20 09:00:00] [chatKey=2026-03-20T08:59:00] User asked about migrating API keys to EZKeyVault in helpers.m\n\n"
        //
        // ── EXAMPLE B: no match → 0 ─────────────────────────────────────────
        // The most common failure is returning unrelated entries instead of 0.
        @"EXAMPLE B — when nothing matches:\n"
        @"Query: \"Sora video generation\"\n"
        @"Entries:\n"
        @"[2026-03-18 10:00:00] [chatKey=2026-03-18T09:59:00] User asked about centering a UILabel\n"
        @"Correct output:\n"
        @"0\n\n"
        //
        // Final format reminder — no preamble, no numbering, no explanation.
        @"No preamble, no explanation, no numbering — just the entries (or 0).";
    NSString *candidatesText    = [candidateLines componentsJoinedByString:@"\n"];

    NSString *rankerUserMessage = [NSString stringWithFormat:@"Search query: \"%@\"\n\nMemory entries to rank:\n%@",
                                   searchQuery ?: @"", candidatesText];

    NSString *rankerResponse = _callHelperModelSync(rankerSystemPrompt,
                                                    rankerUserMessage,
                                                    apiKey,
                                                    kMemorySearchRankerMaxTokens);
    NSString *trimmed = [rankerResponse stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Ranker failed or returned empty — use the top 3 keyword results as a fallback.
    if (trimmed.length == 0) {
        EZLog(EZLogLevelWarning, @"MEMORY", @"Stage 2 ranker failed — using Stage 1 keyword results");
        NSInteger fallbackCount = MIN(3, (NSInteger)candidateLines.count);
        return [[candidateLines subarrayWithRange:NSMakeRange(0, (NSUInteger)fallbackCount)]
                    componentsJoinedByString:@"\n"];
    }

    // A lone "0" means the ranker found nothing relevant.
    if ([trimmed isEqualToString:@"0"]) {
        EZLog(EZLogLevelInfo, @"MEMORY", @"Stage 2 ranker found no relevant entries");
        return @"";
    }

    return trimmed;
}


// ═════════════════════════════════════════════════════════════════════════════
// SECTION 4 — THREAD STORE
//
// Each saved conversation (EZChatThread) is stored as an individual JSON file
// in the EZThreads/ sub-folder of the Documents directory. This is simpler
// and more crash-resilient than a single large JSON array — if one file
// corrupts, only that thread is lost.
//
// File naming: the threadID (an ISO 8601 timestamp) is sanitized to make a
// valid filename, e.g. "2025-04-14T09:30:00" → "2025-04-14T09-30-00.json".
// ═════════════════════════════════════════════════════════════════════════════

// Returns the path to the EZThreads/ directory, creating it if needed.
// Public so ViewController can display the path in debug info.
NSString *EZThreadStoreDir(void) {
    NSString *threadsDirectory = [_documentsDirectory() stringByAppendingPathComponent:kThreadsDirName];
    // withIntermediateDirectories:YES means create parent dirs too if they don't exist.
    [[NSFileManager defaultManager] createDirectoryAtPath:threadsDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return threadsDirectory;
}

// Converts a threadID into a safe file path by replacing characters that are
// illegal or inconvenient in file names. Appends ".json" extension.
//   "2025-04-14T09:30:00" → ".../EZThreads/2025-04-14T09-30-00.json"
static NSString *_threadFilePath(NSString *threadID) {
    NSString *safeFileName = [[threadID stringByReplacingOccurrencesOfString:@":" withString:@"-"]
                              stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    return [[EZThreadStoreDir() stringByAppendingPathComponent:safeFileName]
               stringByAppendingPathExtension:@"json"];
}

// Extracts the stem of a file path (no directory, no extension).
//   "/path/to/EZThreads/2025-04-14T09-30-00.json" → "2025-04-14T09-30-00"
// Used by EZThreadList as a fallback threadID when a JSON file is missing
// the threadID key.
static NSString *_threadStemFromPath(NSString *path) {
    return [[path lastPathComponent] stringByDeletingPathExtension];
}

// EZThreadSave — serializes an EZChatThread to JSON and writes it to disk
// on the file-write queue (background, serial).
//
// Side effects:
//   • Sets thread.updatedAt to the current ISO 8601 timestamp.
//   • Sets thread.createdAt if it was empty (first save).
//   • Ensures title and displayText are non-empty.
//
// completionCallback is called on the MAIN THREAD with YES/NO after the write.
// Passing nil for completionCallback is allowed (fire-and-forget).
void EZThreadSave(EZChatThread *thread, void (^ _Nullable completionCallback)(BOOL success)) {
    if (!thread || thread.threadID.length == 0) {
        EZLog(EZLogLevelWarning, @"THREADS", @"Save called with nil/empty thread — ignoring");
        if (completionCallback) dispatch_async(dispatch_get_main_queue(), ^{ completionCallback(NO); });
        return;
    }

    // Stamp timestamps before serialization.
    thread.updatedAt = _timestampISO8601();
    if (thread.createdAt.length == 0) thread.createdAt = thread.updatedAt;
    if (thread.title.length       == 0) thread.title       = @"New Conversation";
    if (thread.displayText.length == 0) thread.displayText = thread.title;

    NSDictionary *threadDict = [thread toDictionary];
    NSString     *filePath   = _threadFilePath(thread.threadID);

    // Offload file I/O to the background queue so the UI never blocks.
    dispatch_async(_fileWriteQueue(), ^{
        NSError *serializeError = nil;
        NSData  *jsonData = [NSJSONSerialization dataWithJSONObject:threadDict
                                                            options:NSJSONWritingPrettyPrinted
                                                              error:&serializeError];
        BOOL success = NO;
        if (!serializeError && jsonData) {
            NSError *writeError = nil;
            success = [jsonData writeToFile:filePath options:NSDataWritingAtomic error:&writeError];
            if (!success) EZLogf(EZLogLevelError, @"THREADS", @"Write failed: %@", writeError);
        } else {
            EZLogf(EZLogLevelError, @"THREADS", @"Serialize failed: %@", serializeError);
        }
        if (success) EZLogf(EZLogLevelInfo, @"THREADS", @"Saved: %@", thread.threadID);

        // Always call back on the main thread — UIKit is not thread-safe.
        if (completionCallback) dispatch_async(dispatch_get_main_queue(), ^{ completionCallback(success); });
    });
}

// EZThreadLoad — loads a single thread by its threadID from disk.
// Returns nil if the file doesn't exist, can't be read, or fails to parse.
EZChatThread * _Nullable EZThreadLoad(NSString *threadID) {
    if (threadID.length == 0) return nil;

    NSString *path     = _threadFilePath(threadID);
    NSData   *fileData = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!fileData) {
        EZLogf(EZLogLevelWarning, @"THREADS", @"Thread not found: %@", threadID);
        return nil;
    }

    id parsedJSON = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:nil];
    if (![parsedJSON isKindOfClass:[NSDictionary class]]) {
        EZLogf(EZLogLevelError, @"THREADS", @"Parse error for %@", threadID);
        return nil;
    }

    // Pass the threadID as a fallback in case the JSON is missing the key.
    EZChatThread *thread = [EZChatThread ez_fromDictionary:(NSDictionary *)parsedJSON
                                          fallbackThreadID:threadID];
    if (!thread) {
        EZLogf(EZLogLevelError, @"THREADS", @"Thread decode failed for %@", threadID);
    }
    return thread;
}

// EZThreadList — returns all saved threads, sorted newest-first by updatedAt.
//
// Iterates the EZThreads/ directory, skips non-.json files, loads each one,
// and filters out any that lack a threadID (likely corrupt files).
// The sort is a lexicographic string comparison on ISO 8601 timestamps, which
// works correctly because ISO 8601 sorts the same as chronological order.
NSArray<EZChatThread *> *EZThreadList(void) {
    NSString *threadsDirectory = EZThreadStoreDir();
    NSArray<NSString *> *fileNames = [[NSFileManager defaultManager]
                                        contentsOfDirectoryAtPath:threadsDirectory error:nil];
    if (fileNames.count == 0) return @[];

    NSMutableArray<EZChatThread *> *threads = [NSMutableArray array];
    for (NSString *fileName in fileNames) {
        if (![fileName hasSuffix:@".json"]) continue;  // skip .DS_Store etc.

        NSString *fullPath = [threadsDirectory stringByAppendingPathComponent:fileName];
        NSData   *fileData = [NSData dataWithContentsOfFile:fullPath];
        if (!fileData) continue;

        id parsedJSON = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:nil];
        if (![parsedJSON isKindOfClass:[NSDictionary class]]) continue;

        // Use the filename stem as a fallback threadID.
        NSString     *fallbackThreadID = _threadStemFromPath(fullPath);
        EZChatThread *thread           = [EZChatThread ez_fromDictionary:(NSDictionary *)parsedJSON
                                                        fallbackThreadID:fallbackThreadID];
        if (thread.threadID.length > 0) {
            [threads addObject:thread];
        }
    }

    // Sort newest-first. ISO 8601 strings compare correctly as plain strings.
    [threads sortUsingComparator:^NSComparisonResult(EZChatThread *a, EZChatThread *b) {
        NSString *updatedA = a.updatedAt ?: @"";
        NSString *updatedB = b.updatedAt ?: @"";
        return [updatedB compare:updatedA];  // descending (newest first)
    }];

    return [threads copy];  // return immutable copy
}

// EZThreadDelete — deletes the JSON file for a thread by ID.
// Returns YES if deleted successfully, NO otherwise.
BOOL EZThreadDelete(NSString *threadID) {
    NSError *deleteError = nil;
    BOOL deleted = [[NSFileManager defaultManager] removeItemAtPath:_threadFilePath(threadID)
                                                              error:&deleteError];
    if (deleted) {
        EZLogf(EZLogLevelInfo,  @"THREADS", @"Deleted: %@", threadID);
    } else {
        EZLogf(EZLogLevelError, @"THREADS", @"Delete failed for %@: %@", threadID, deleteError);
    }
    return deleted;
}


// ═════════════════════════════════════════════════════════════════════════════
// SECTION 5 — TURN SCORING & CONTEXT EXTRACTION
//
// When the triage pipeline decides to inject thread history into a prompt, we
// don't just dump the whole thread — that would waste tokens and hit context
// limits. Instead, we score individual turns and select the most relevant ones
// within a token budget.
// ═════════════════════════════════════════════════════════════════════════════

// Returns the character length of a turn's text content.
// Used to estimate token cost (length/4 ≈ tokens).
static NSInteger _turnLength(NSDictionary *turn) {
    return _messageTextFromContent(turn[@"content"]).length;
}

// Returns YES if a turn contains signals that suggest it involved a file or
// attachment. Turns with attachments are scored higher by the context selector
// because they tend to be the turns users most often want to "go back to."
//
// Detection methods:
//   1. Structural: the content array contains an "image" block (vision request).
//   2. Keyword: the message text mentions common attachment-related words.
static BOOL _turnHasAttachmentSignal(NSDictionary *turn) {
    id content = turn[@"content"];
    // Check for inline image blocks in multi-part message content.
    if ([content isKindOfClass:[NSArray class]]) {
        for (id block in (NSArray *)content) {
            if (![block isKindOfClass:[NSDictionary class]]) continue;
            NSString *type = _safeString(((NSDictionary *)block)[@"type"]);
            if ([type containsString:@"image"]) return YES;
        }
    }
    // Keyword heuristic on the message text.
    NSString *lower = _messageTextFromContent(content).lowercaseString;
    return [lower containsString:@"attached"]   ||
           [lower containsString:@"resume"]     ||
           [lower containsString:@"document"]   ||
           [lower containsString:@"pdf"]        ||
           [lower containsString:@"image"]      ||
           [lower containsString:@"generated"]  ||
           [lower containsString:@"edited"]     ||
           [lower containsString:@"file"]       ||
           [lower containsString:@"epub"]       ||
           [lower containsString:@"transcript"] ||
           [lower containsString:@"video"]      ||
           [lower containsString:@"patch"];
}

// Scores a single conversation turn for relevance to a search query.
//
// Scoring breakdown:
//   +10  per query term found in the normalized turn text
//   +18  per query term that looks like a path/identifier and is found verbatim
//         (precise identifiers are very strong signals)
//   +6   turn is from the assistant (assistant turns carry the actual answers)
//   +8   turn has an attachment signal (file-related turns are often what we need)
//   +3   turn is long (>120 chars) — longer turns tend to be more substantive
//   +2   query is a vague reference ("try again", "that one", etc.) — small boost
//        to prefer the most-recently-scored turn over nothing
static NSInteger _turnQueryScore(NSDictionary *turn, NSString *query) {
    NSString *text       = _messageTextFromContent(turn[@"content"]);
    NSString *normalized = _normalizeForSearch(text);
    NSArray<NSString *> *terms = _searchTerms(query);
    NSInteger score = 0;

    for (NSString *term in terms) {
        if ([normalized containsString:term])                                       score += 10;
        if (_looksLikePathOrIdentifier(term) &&
            [text.lowercaseString containsString:term.lowercaseString])             score += 10;
    }

    NSString *role = _safeString(turn[@"role"]);
    if ([role isEqualToString:@"assistant"])  score += 6;
   // if (_turnHasAttachmentSignal(turn))       score += 8;
    if (text.length > 120)                   score += 3;

    // Vague queries like "fix that" or "the code" shouldn't score zero even
    // when no keywords match — give a tiny bonus so the pipeline doesn't bail.
    if ([query.lowercaseString isEqualToString:@"try again"] ||
        [query.lowercaseString isEqualToString:@"that one"]  ||
        [query.lowercaseString isEqualToString:@"the code"]  ||
        [query.lowercaseString isEqualToString:@"the file"]) {
        score += 2;
    }

    return score;
}

// _bestTurnWindowForQuery — finds the highest-scoring turn in a thread and
// returns a small window of turns around it (±2 turns), capped by tokenBudget.
//
// WHY A WINDOW?
//   A single winning turn rarely makes sense in isolation. The turns immediately
//   before and after it provide the question + answer context needed for coherence.
//
// Returns nil if no turn scores above zero (nothing relevant in the thread).
static NSArray<NSDictionary *> *_bestTurnWindowForQuery(EZChatThread *thread,
                                                         NSString *query,
                                                         NSInteger tokenBudget) {
    if (!thread || thread.chatContext.count == 0) return nil;
    NSArray<NSDictionary *> *turns = thread.chatContext;
    NSInteger bestIndex = NSNotFound;
    NSInteger bestScore = 0;

    // Find the single highest-scoring turn.
    for (NSInteger i = 0; i < (NSInteger)turns.count; i++) {
        NSDictionary *turn = turns[(NSUInteger)i];
        if (![turn isKindOfClass:[NSDictionary class]]) continue;
        NSInteger score = _turnQueryScore(turn, query ?: @"");
        if (score > bestScore) {
            bestScore = score;
            bestIndex = i;
        }
    }

    if (bestIndex == NSNotFound || bestScore <= 0) return nil;  // nothing useful

    // Build the window: up to 2 turns before and after the best turn.
    NSInteger charBudget = tokenBudget * 4;   // rough char ↔ token conversion
    NSInteger start      = MAX(0, bestIndex - 2);
    NSInteger end        = MIN((NSInteger)turns.count - 1, bestIndex + 2);
    NSMutableArray<NSDictionary *> *window = [NSMutableArray array];
    NSInteger used = 0;

    for (NSInteger i = start; i <= end; i++) {
        NSDictionary *turn = turns[(NSUInteger)i];
        NSInteger len = _turnLength(turn);
        // Stop expanding the window if the next turn would exceed the budget.
        // Note: always include at least the first turn even if it's over budget.
        if (window.count > 0 && used + len > charBudget) break;
        [window addObject:turn];
        used += len;
    }

    return window.count > 0 ? [window copy] : nil;
}

// EZThreadLoadContext — loads the most useful subset of a thread's turns for
// context injection into a new request, staying within a token budget.
//
// Strategy:
//   1. Always include the 4 most recent turns (conversation continuity).
//   2. For older turns, score each on substance (length + attachment signal +
//      assistant role). Add higher-scoring turns until the budget is exhausted.
//   3. Re-sort the selected turns into original chronological order before
//      returning, so the injected history reads naturally.
//
// This is different from _bestTurnWindowForQuery: this function doesn't have
// a specific query — it picks the most informative turns from the whole thread.
// The query-specific function is called first (as a "tight window"); this
// broader approach is the fallback.
NSArray<NSDictionary *> * _Nullable EZThreadLoadContext(NSString *threadID, NSInteger tokenBudget) {
    EZChatThread *thread = EZThreadLoad(threadID);
    if (!thread || thread.chatContext.count == 0) return nil;

    NSInteger characterBudget    = tokenBudget * 4;
    NSArray<NSDictionary *> *allTurns = thread.chatContext;
    NSUInteger totalTurns        = allTurns.count;

    // Step 1: Lock in the 4 most recent turns unconditionally.
    NSInteger recentTurnCount = MIN(4, (NSInteger)totalTurns);
    NSMutableSet<NSNumber *> *includedIndices = [NSMutableSet set];
    NSInteger budgetUsed = 0;

    for (NSInteger i = (NSInteger)totalTurns - 1; i >= (NSInteger)totalTurns - recentTurnCount; i--) {
        [includedIndices addObject:@(i)];
        budgetUsed += _turnLength(allTurns[(NSUInteger)i]);
    }

    // Step 2: Score older turns and add the best ones until the budget runs out.
    NSMutableArray<NSDictionary *> *scoredTurns = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)totalTurns - recentTurnCount; i++) {
        NSDictionary *turn   = allTurns[(NSUInteger)i];
        NSString     *role   = _safeString(turn[@"role"]);
        NSInteger     length = _turnLength(turn);
        BOOL hasAttachment   = _turnHasAttachmentSignal(turn);

        BOOL isAssistant   = [role isEqualToString:@"assistant"];
        BOOL isSubstantial = length > 100 || hasAttachment;
        // Skip short, non-assistant turns with no attachment — they're usually
        // trivial acknowledgements ("ok", "thanks") that add noise.
        if (!isAssistant && !isSubstantial) continue;

        // Score is biased heavily toward attachment turns (likely the actual
        // "here is my file" exchange) and assistant turns (actual answers).
        NSInteger score = length;
        if (hasAttachment) score += 500;   // strong bias: this turn had a file
        if (isAssistant)   score += 200;   // mild bias: this turn was an answer

        [scoredTurns addObject:@{@"index": @(i), @"score": @(score), @"length": @(length)}];
    }

    // Sort by score descending so we can greedily add turns.
    [scoredTurns sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"score"] compare:a[@"score"]];
    }];

    for (NSDictionary *scored in scoredTurns) {
        NSInteger idx    = [scored[@"index"] integerValue];
        NSInteger length = [scored[@"length"] integerValue];
        if ([includedIndices containsObject:@(idx)]) continue;     // already included
        if (budgetUsed + length > characterBudget)  continue;      // would exceed budget
        [includedIndices addObject:@(idx)];
        budgetUsed += length;
        if (budgetUsed >= characterBudget) break;
    }

    // Step 3: Re-sort included indices into original chronological order.
    NSArray<NSNumber *> *sortedIndices = [[includedIndices allObjects]
                                            sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSDictionary *> *selectedTurns = [NSMutableArray array];
    for (NSNumber *idx in sortedIndices) {
        [selectedTurns addObject:allTurns[(NSUInteger)idx.integerValue]];
    }

    EZLogf(EZLogLevelInfo, @"THREADS",
           @"LoadContext: %lu/%lu turns selected from thread %@ (~%ld tokens)",
           (unsigned long)selectedTurns.count, (unsigned long)totalTurns,
           threadID, (long)(budgetUsed / 4));

    return selectedTurns.count > 0 ? [selectedTurns copy] : nil;
}


// ═════════════════════════════════════════════════════════════════════════════
// SECTION 6 — TRIAGE PIPELINE HELPERS
//
// These private helpers support the three-stage pipeline in analyzePromptForContext.
// ═════════════════════════════════════════════════════════════════════════════

// _bestChatKeyFromMemoryContext — scans a block of formatted memory text
// (as produced by loadMemoryContext / EZThreadSearchMemory) and returns the
// chatKey of the line with the highest keyword overlap with `query`.
//
// This is used as a fallback chatKey extraction when the AI ranker didn't
// return one, or when we want a second opinion on which thread is most relevant.
//
// Each line in memoryContext looks like:
//   [timestamp] [chatKey=XXXXXXXXX] [file:foo.m] summary text
//
// The function parses the [chatKey=...] tag from each line and scores the
// overall line against the query keywords.
static NSString *_bestChatKeyFromMemoryContext(NSString *memoryContext, NSString *query) {
    if (memoryContext.length == 0) return @"";

    NSArray<NSString *> *lines = [memoryContext componentsSeparatedByString:@"\n"];
    NSArray<NSString *> *terms = _searchTerms(query);
    NSString  *bestKey   = @"";
    NSInteger  bestScore = 0;

    for (NSString *line in lines) {
        // Find "[chatKey=" in the line.
        NSRange keyStart = [line rangeOfString:@"[chatKey="];
        if (keyStart.location == NSNotFound) continue;

        // Find the closing "]" after "[chatKey=".
        NSRange keyEnd = [line rangeOfString:@"]" options:0
                                       range:NSMakeRange(keyStart.location, line.length - keyStart.location)];
        // 9 = length of "[chatKey=" — the value must start after that.
        if (keyEnd.location == NSNotFound || keyEnd.location <= keyStart.location + 9) continue;

        // Extract the key value between "[chatKey=" and "]".
        NSString *key = [line substringWithRange:NSMakeRange(keyStart.location + 9,
                                                             keyEnd.location - keyStart.location - 9)];

        // Score this line against the query keywords.
        NSInteger score = 0;
        NSString *lower = line.lowercaseString;
        for (NSString *term in terms) {
            if ([lower containsString:term.lowercaseString]) score += 4;
        }
        if (score > bestScore) {
            bestScore = score;
            bestKey   = key;
        }
    }

    return bestKey;
}

// _validatedThreadID — checks whether a candidate threadID actually exists on
// disk; if not, tries the fallback. Returns @"" if neither exists.
//
// WHY VALIDATE?
//   The AI ranker returns a chatKey string from memory text. That key might be
//   stale (the thread was deleted) or misformatted. Before trying to load a
//   thread, always confirm the file exists.
static NSString *_validatedThreadID(NSString *candidate, NSString *fallback) {
    if (candidate.length > 0 && EZThreadLoad(candidate) != nil) return candidate;
    if (fallback.length  > 0 && EZThreadLoad(fallback)  != nil) return fallback;
    return @"";
}


// ─────────────────────────────────────────────────────────────────────────────
// STAGE 1 — Triage Helper
//
// The first AI call in the pipeline. Receives the raw user prompt and,
// optionally, recent-turn text (added on re-evaluation after UNCERTAIN).
//
// Returns a dictionary parsed from the model's JSON output, or nil on failure.
//
// VERDICTS:
//   SIMPLE        — answerable right now, no history needed
//   COMPLEX       — requires main model power, but no prior history needed
//   NEEDS_CONTEXT — references something from a prior session
//   UNCERTAIN     — can't classify without seeing recent turns first
//
// SHORT-CIRCUIT PATHS:
//   SIMPLE + high confidence → caller can emit direct_answer without GPT
//   COMPLEX                  → caller skips memory search, goes to main model
//   UNCERTAIN                → caller fetches recent turns, re-calls this (Stage 1b)
//   NEEDS_CONTEXT            → caller proceeds to Stage 2 memory search
//
// PROMPT DESIGN NOTES:
//   The system prompt includes four concrete examples (one per verdict) because
//   small models classify much more consistently with examples than with rules
//   alone. The JSON output schema is written inline so the model knows exactly
//   what keys and value types to produce.
// ─────────────────────────────────────────────────────────────────────────────
static NSDictionary * _Nullable _runTriageHelper(NSString *userPrompt,
                                                 NSString * _Nullable recentTurnsText,
                                                 NSString *apiKey) {
    // If recent turns were provided (Stage 1b re-evaluation), append them so
    // the model has the same context the user is currently seeing.
    NSMutableString *contextSection = [NSMutableString string];
    if (recentTurnsText.length > 0) {
        [contextSection appendFormat:@"\n\nRECENT CONVERSATION TURNS:\n%@", recentTurnsText];
    }

    NSString *systemPrompt =
        @"You are a triage classifier for an AI assistant. "
        @"Read the user prompt and decide if more info is needed to satisfactorily answer right now.\n\n"
        //
        // ── VERDICT DEFINITIONS ─────────────────────────────────────────────
        // Each verdict description tells the model both WHEN to use it and
        // what the downstream effect is. This helps the model pick correctly
        // when the prompt falls in a gray area.
        @"VERDICTS:\n"
        @"  SIMPLE        — greeting, quick fact, simple task; you can answer ONLY if confidence is high, and the query is trivial."
        @"                  Do not respond to user if prompt is complex, creative, involves coding, or needs more info from previous turns or memories.\n"
        @"  COMPLEX       — multi-step, coding, creative, or analytical task; main model needed, no prior history required\n"
        @"  NEEDS_CONTEXT — prompt references something from a prior session (past decision, past file, past event)\n"
        @"  UNCERTAIN     — genuinely cannot classify without seeing recent conversation turns\n\n"
        //
        // Key disambiguation rule: a file already in THIS session is not "prior context."
        @"If an attached file is already visible in this session classify as COMPLEX, not NEEDS_CONTEXT.\n\n"
        //
        // ── ONE-SHOT EXAMPLES ───────────────────────────────────────────────
        // One clear example per verdict. The examples were chosen to span the
        // most common real prompts so the model anchors on recognizable patterns.
        @"EXAMPLES:\n"
        @"1. \"What time is it in Tokyo?\" → SIMPLE\n"
        @"2. \"Write me a recursive merge-sort in Swift\" → COMPLEX\n"
        @"3. \"What did we decide to name the plugin last week?\" → NEEDS_CONTEXT\n"
        @"4. \"Fix that\" (no prior turns visible) → UNCERTAIN\n\n"
    
        @"Note: NEVER answer yourself telling the user what you don't have, or what you can't do.\n"

        @"Instead, classify it as \"needs context\" so the info needed can be found in the next step.\n\n"
        @"── OUTPUT SCHEMA ────────────────────────────────────────────────────\n"
        // Checklist fields are temporarily disabled to reduce prompt overload
        // and keep the helper focused on core routing outputs.
        /*
         @"OUTPUT CHECKLIST — include each field in your JSON:\n"
         @"  answered_directly : do you have all the info needed for completion already?\n"
         @"  references_past   : does the prompt point to a prior session?\n"
         @"  needs_creativity  : requires main model reasoning power?\n"
         @"  is_clear          : is intent clear enough to classify confidently?\n\n"
         */
        @"Return ONLY valid JSON, no markdown, no preamble:\n"
        @"{\n"
        @"  \"verdict\": \"SIMPLE\" | \"COMPLEX\" | \"NEEDS_CONTEXT\" | \"UNCERTAIN\",\n"
        @"  \"confidence\": <float 0.0-1.0>,\n"
        @"  \"direct_answer\": \"<full answer when SIMPLE and confidence >= 0.85, else null>\",\n"
        @"  \"tags\": [\"<synonym for keyword1>\", \"<synonym for keyword2>\"],\n"
        @"  \"reason\": \"<one sentence>\"\n"
        /*
         ,\n"
         @"  \"checklist\": {\n"
         @"    \"answered_directly\": <bool>,\n"
         @"    \"references_past\": <bool>,\n"
         @"    \"needs_creativity\": <bool>,\n"
         @"    \"is_clear\": <bool>\n"
         @"  }\n"
         */
        @"}";

    NSString *userMessage = [NSString stringWithFormat:@"User prompt: \"%@\"%@",
                              userPrompt, contextSection];
    NSString *rawResponse = _callHelperModelSync(systemPrompt, userMessage, apiKey, 350);
    if (rawResponse.length == 0) return nil;

    NSData *data   = [_stripMarkdownFences(rawResponse) dataUsingEncoding:NSUTF8StringEncoding];
    id      parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:[NSDictionary class]] ? (NSDictionary *)parsed : nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 1a — Direct Answer Validator
//
// Guards Stage 1 direct answers before they are shown to the user.
// Returns JSON with:
//   is_valid   — YES only when the answer actually satisfies the request
//   confidence — validator confidence (0-1)
//   reason     — one-sentence explanation
// ─────────────────────────────────────────────────────────────────────────────
static NSDictionary * _Nullable _runDirectAnswerValidator(NSString *userPrompt,
                                                          NSString *proposedAnswer,
                                                          NSString *apiKey) {
    if (userPrompt.length == 0 || proposedAnswer.length == 0 || apiKey.length == 0) return nil;

    NSString *systemPrompt =
        @"You are a strict answer validator for an AI assistant.\n"
        @"Given the user request and a proposed answer, decide if the answer fully satisfies the request.\n\n"
        @"Set is_valid=false if the answer is evasive, generic, or refuses due to missing memory/context.\n"
        @"Set is_valid=false if the user asked for work (code/explanation/task) and the answer does not do that work.\n"
        @"Set is_valid=true for genuinely complete responses, including short social replies when appropriate.\n\n"
        @"Return ONLY valid JSON:\n"
        @"{\n"
        @"  \"is_valid\": <bool>,\n"
        @"  \"confidence\": <float 0.0-1.0>,\n"
        @"  \"reason\": \"<one sentence>\"\n"
        @"}";

    NSString *userMessage = [NSString stringWithFormat:
        @"User request:\n%@\n\nProposed answer:\n%@",
        userPrompt, proposedAnswer];

    NSString *rawResponse = _callHelperModelSync(systemPrompt, userMessage, apiKey, 220);
    if (rawResponse.length == 0) return nil;

    NSData *data   = [_stripMarkdownFences(rawResponse) dataUsingEncoding:NSUTF8StringEncoding];
    id      parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:[NSDictionary class]] ? (NSDictionary *)parsed : nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 1b helper — _formatRecentTurns
//
// Formats the N most recent turns of a saved thread into a compact plain-text
// block for the triage re-evaluation call.
//
// Format per turn: "ROLE: message text (truncated to 2000 chars)\n"
// Truncation keeps the payload small — triage doesn't need to read full turns,
// just enough to classify the conversation's recent direction.
// ─────────────────────────────────────────────────────────────────────────────
static NSString *_formatRecentTurns(NSString *chatKey, NSInteger turnCount) {
    if (chatKey.length == 0) return @"";
    EZChatThread *thread = EZThreadLoad(chatKey);
    if (!thread || thread.chatContext.count == 0) return @"";

    NSArray<NSDictionary *> *allTurns = thread.chatContext;
    // Start from (count - turnCount) turns back, or from the beginning if the
    // thread is shorter than turnCount.
    NSInteger start = MAX(0LL, (NSInteger)allTurns.count - turnCount);
    NSMutableString *result = [NSMutableString string];

    for (NSInteger i = start; i < (NSInteger)allTurns.count; i++) {
        NSDictionary *turn = allTurns[(NSUInteger)i];
        NSString *role = _safeString(turn[@"role"]);
        NSString *text = _messageTextFromContent(turn[@"content"]);
        // Truncate long turns to keep the re-eval payload under ~2000 tokens. this was 300 updated 4-17
        if (text.length > 2000) text = [[text substringToIndex:2000] stringByAppendingString:@"…"];
        [result appendFormat:@"%@: %@\n", [role uppercaseString], text];
    }
    return [result copy];
}


// ─────────────────────────────────────────────────────────────────────────────
// STAGE 3 — Memory Ranker Helper
//
// The third AI call in the pipeline. Receives the user prompt, optional recent
// turns, and the keyword-ranked memory candidates from Stage 2.
//
// Decides: are the memories enough to answer, or do we need the full thread?
//
// Returns a dictionary parsed from the model's JSON output, or nil on failure.
//
// VERDICTS:
//   SIMPLE       — memories already contain the full answer; emit it directly
//   COMPLEX      — memories give enough context; inject and route to main model
//   NEEDS_THREAD — memories are insufficient; must load the original thread
//
// KEY DESIGN DECISION — "short-circuit first":
//   The prompt's CRITICAL RULE instructs the model to stop as soon as it has
//   enough. This prevents the model from escalating to NEEDS_THREAD (expensive)
//   when COMPLEX (cheap) would do fine.
//
// PROMPT DESIGN NOTES:
//   The checklist asks four boolean questions that mirror the decision tree,
//   forcing the model to commit to intermediate answers before producing a
//   verdict. This reduces hallucination on the verdict field because the model
//   has already "shown its work."
// ─────────────────────────────────────────────────────────────────────────────
static NSDictionary * _Nullable _runMemoryRanker(NSString *userPrompt,
                                                 NSString * _Nullable recentTurnsText,
                                                 NSString *rankedMemories,
                                                 NSString *apiKey) {
    NSMutableString *contextSection = [NSMutableString string];
    if (recentTurnsText.length > 0) {
        [contextSection appendFormat:@"\nRECENT TURNS:\n%@\n", recentTurnsText];
    }

    NSString *systemPrompt =
        @"You are a memory relevance ranker and context resolver for an AI assistant.\n"
        @"You receive: (1) the user's current prompt, (2) optionally recent turns from the current "
        @"session, and (3) a list of memory entries from past sessions.\n\n"
        @"Decide if the current memories and thread turns are sufficient to answer the user's question accurately.\n\n"
        //
        // ── VERDICT DEFINITIONS ─────────────────────────────────────────────
        @"VERDICTS:\n"
        @"  SIMPLE       — the memories clearly answer the question; output the answer directly\n"
        @"  COMPLEX      — memories provide enough context; the main model should answer with them injected\n"
        @"  NEEDS_THREAD — the top 1-2 memories are insufficient; we must load the full original thread\n\n"
        //
        // The critical rule: escalation is expensive, so prefer cheaper verdicts.
        @"CRITICAL SHORT-CIRCUIT RULE: stop ranking as soon as you have enough.\n"
        @"Do NOT request a full thread if a memory already contains the answer.\n"
        @"Return ONLY valid JSON, no markdown, no preamble:\n"
        @"{\n"
        @"  \"verdict\": \"SIMPLE\" | \"COMPLEX\" | \"NEEDS_THREAD\",\n"
        @"  \"confidence\": <float 0.0-1.0>,\n"
        @"  \"direct_answer\": \"<full answer if SIMPLE, else null>\",\n"
        @"  \"best_chat_key\": \"<chatKey value from the most relevant [chatKey=...] tag, or null>\",\n"
        @"  \"selected_memories\": \"<1-3 most relevant memory lines verbatim, newline-separated>\",\n"
        @"  \"reason\": \"<one sentence>\"\n"
        @"}";

    NSString *userMessage = [NSString stringWithFormat:
        @"User prompt: \"%@\"\n%@\nMemory entries:\n%@",
        userPrompt, contextSection, rankedMemories];

    NSString *rawResponse = _callHelperModelSync(systemPrompt, userMessage, apiKey, 600);
    if (rawResponse.length == 0) return nil;

    NSData *data   = [_stripMarkdownFences(rawResponse) dataUsingEncoding:NSUTF8StringEncoding];
    id      parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [parsed isKindOfClass:[NSDictionary class]] ? (NSDictionary *)parsed : nil;
}


// ═════════════════════════════════════════════════════════════════════════════
// SECTION 7 — analyzePromptForContext (PUBLIC ENTRY POINT)
//
// This is the main function called by ViewController when the user sends a
// message. It runs the full three-stage triage pipeline on a background thread
// and calls `completion` on the main thread with an EZContextResult.
//
// The result tells ViewController:
//   • Which routing tier to use (direct / simple / memory-enriched / full-history)
//   • Whether to skip the main model (shortCircuitAnswer is non-nil)
//   • What to send as the final prompt (may be enriched with history/memories)
//   • Roughly how many tokens this will cost
//
// FULL PIPELINE OVERVIEW:
//
//  ┌─ STAGE 1: Triage ─────────────────────────────────────────────────────────┐
//  │  Fast AI call. No memories yet.                                           │
//  │  SIMPLE + high conf → SHORT-CIRCUIT A: emit direct answer, done           │
//  │  COMPLEX            → SHORT-CIRCUIT B: route straight to main model       │
//  │  UNCERTAIN          → fetch recent turns, re-run triage (Stage 1b)        │
//  │    1b SIMPLE → SHORT-CIRCUIT A′    1b COMPLEX → SHORT-CIRCUIT B′         │
//  │    1b NEEDS_CONTEXT → fall through to Stage 2                             │
//  │  NEEDS_CONTEXT      → fall through to Stage 2                             │
//  └───────────────────────────────────────────────────────────────────────────┘
//  ┌─ STAGE 2: Memory Search ───────────────────────────────────────────────────┐
//  │  EZThreadSearchMemory — keyword + AI ranker.                              │
//  │  No results → SHORT-CIRCUIT: route to main model with no injection        │
//  └───────────────────────────────────────────────────────────────────────────┘
//  ┌─ STAGE 3: Memory Ranker ───────────────────────────────────────────────────┐
//  │  SIMPLE      → SHORT-CIRCUIT C: emit direct answer                        │
//  │  COMPLEX     → SHORT-CIRCUIT D: inject selected memories, main model      │
//  │  NEEDS_THREAD → resolve chatKey → load exact turn window (tight)          │
//  │                 or broad scored context → inject, main model              │
//  │  (fallback if thread missing: inject whatever memories we have)           │
//  └───────────────────────────────────────────────────────────────────────────┘
// ═════════════════════════════════════════════════════════════════════════════
void analyzePromptForContext(NSString *userPrompt,
                             NSString * _Nullable memoryContext,
                             NSString *apiKey,
                             NSString * _Nullable chatKey,
                             void (^completion)(EZContextResult *result)) {

    // NSCParameterAssert crashes in DEBUG builds if a required parameter is nil.
    // This catches programming errors (calling this without a prompt or key)
    // during development before they reach the network call.
    NSCParameterAssert(userPrompt);
    NSCParameterAssert(apiKey);
    NSCParameterAssert(completion);
    EZLog(EZLogLevelInfo, @"TRIAGE", @"Stage 1 — initial triage...");

    // All pipeline work happens on a background thread so the UI stays responsive.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        EZContextResult *result    = [[EZContextResult alloc] init];
        result.finalPrompt         = userPrompt;
        result.estimatedTokens     = _estimateTokenCount(userPrompt);

        // recentTurnsText is populated if triage returns UNCERTAIN and we
        // fetch turns for re-evaluation. It's then re-used in Stage 3 so
        // the ranker has the same context the re-eval used.
        __block NSString *recentTurnsText = @"";

        // ── STAGE 1: TRIAGE ──────────────────────────────────────────────────
        NSDictionary *triageResult = _runTriageHelper(userPrompt, nil, apiKey);

        if (!triageResult) {
            // Helper call failed (no network, bad key, etc.) — safe fallback:
            // treat as COMPLEX and let the main model handle it without history.
            result.tier       = EZRoutingTierSimple;
            result.needsContext = NO;
            result.reason     = @"Triage unavailable — defaulting to main model";
            result.confidence = 0.5f;
            EZLog(EZLogLevelWarning, @"TRIAGE", @"Stage 1 failed — safe fallback to main model");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // Safely extract every field from the triage JSON.
        NSString    *verdict      = _safeString(triageResult[@"verdict"]);
        float        confidence   = [triageResult[@"confidence"] respondsToSelector:@selector(floatValue)]
                                        ? [triageResult[@"confidence"] floatValue] : 0.5f;
        NSString    *reason       = _safeString(triageResult[@"reason"]);
        NSString    *directAnswer = [triageResult[@"direct_answer"] isKindOfClass:[NSString class]]
                                        ? triageResult[@"direct_answer"] : nil;
     //   NSDictionary *checklist   = [triageResult[@"checklist"] isKindOfClass:[NSDictionary class]]
                                 //       ? triageResult[@"checklist"] : @{};
        NSArray     *tags         = [triageResult[@"tags"] isKindOfClass:[NSArray class]]
                                        ? triageResult[@"tags"] : @[];

        EZLogf(EZLogLevelInfo,  @"TRIAGE", @"Stage 1  verdict=%-14s conf=%.2f  %@", verdict.UTF8String, confidence, reason);
      //  EZLogf(EZLogLevelDebug, @"TRIAGE", @"Stage 1  checklist=%@", checklist);

        result.confidence = confidence;
        result.reason     = reason;

        // ── SHORT-CIRCUIT A: Simple with high-confidence direct answer ────────
        // Stage 1 direct answers must pass a validator helper before use.
        // Rejected answers fall through to memory retrieval.
        if ([verdict isEqualToString:@"SIMPLE"] &&
            confidence >= kDirectAnswerConfidenceThreshold &&
            directAnswer.length > 0) {
            NSDictionary *validatorResult = _runDirectAnswerValidator(userPrompt, directAnswer, apiKey);
            BOOL validatorApproved = [validatorResult[@"is_valid"] respondsToSelector:@selector(boolValue)]
                ? [validatorResult[@"is_valid"] boolValue] : NO;
            float validatorConfidence = [validatorResult[@"confidence"] respondsToSelector:@selector(floatValue)]
                ? [validatorResult[@"confidence"] floatValue] : 0.0f;
            NSString *validatorReason = _safeString(validatorResult[@"reason"]);

            EZLogf(EZLogLevelInfo, @"TRIAGE",
                   @"Stage 1a validator approved=%d conf=%.2f reason=%@",
                   validatorApproved, validatorConfidence, validatorReason);

            if (validatorApproved && validatorConfidence >= kAnswerValidatorConfidenceThreshold) {
                result.tier               = EZRoutingTierDirect;
                result.needsContext       = NO;
                result.shortCircuitAnswer = directAnswer;
                result.estimatedTokens    = _estimateTokenCount(directAnswer);
                EZLog(EZLogLevelInfo, @"TRIAGE", @"✓ SHORT-CIRCUIT A — SIMPLE direct answer (validated)");
                dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
                return;
            }

            if (validatorReason.length > 0) {
                result.reason = [NSString stringWithFormat:@"Direct answer rejected by validator: %@", validatorReason];
            }
            verdict = @"NEEDS_CONTEXT";
            EZLog(EZLogLevelInfo, @"TRIAGE",
                  @"Stage 1a validator rejected direct answer — continuing to memory retrieval");
        }

        // ── SHORT-CIRCUIT B: Complex — straight to main model ────────────────
        // No history needed. Let the main model do the heavy lifting.
        if ([verdict isEqualToString:@"COMPLEX"]) {
            result.tier       = EZRoutingTierSimple;
            result.needsContext = NO;
            EZLog(EZLogLevelInfo, @"TRIAGE", @"✓ SHORT-CIRCUIT B — COMPLEX, skip to main model");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── STAGE 1b: UNCERTAIN — fetch recent turns then re-evaluate ─────────
        // We can't classify without seeing the conversation. Fetch the last few
        // turns from the active thread and call the triage helper again with
        // that context added.
        if ([verdict isEqualToString:@"UNCERTAIN"]) {
            EZLog(EZLogLevelInfo, @"TRIAGE", @"Stage 1b — UNCERTAIN, fetching recent turns for re-evaluation...");
            recentTurnsText = _formatRecentTurns(chatKey ?: @"", kTriageUncertainTurnFetch);

            NSDictionary *reEvalResult = _runTriageHelper(userPrompt, recentTurnsText, apiKey);

            if (reEvalResult) {
                // Overwrite all the stage-1 variables with the re-eval values.
                verdict      = _safeString(reEvalResult[@"verdict"]);
                confidence   = [reEvalResult[@"confidence"] respondsToSelector:@selector(floatValue)]
                                   ? [reEvalResult[@"confidence"] floatValue] : 0.5f;
                reason       = _safeString(reEvalResult[@"reason"]);
                directAnswer = [reEvalResult[@"direct_answer"] isKindOfClass:[NSString class]]
                                   ? reEvalResult[@"direct_answer"] : nil;
            //    checklist    = [reEvalResult[@"checklist"] isKindOfClass:[NSDictionary class]]
                //                   ? reEvalResult[@"checklist"] : @{};
                tags         = [reEvalResult[@"tags"] isKindOfClass:[NSArray class]]
                                   ? reEvalResult[@"tags"] : @[];
                result.confidence = confidence;
                result.reason     = reason;

                EZLogf(EZLogLevelInfo,  @"TRIAGE", @"Stage 1b verdict=%-14s conf=%.2f  %@", verdict.UTF8String, confidence, reason);
             //   EZLogf(EZLogLevelDebug, @"TRIAGE", @"Stage 1b checklist=%@", checklist);

                // SHORT-CIRCUIT A′: re-eval says simple — validator-gated direct answer.
                if ([verdict isEqualToString:@"SIMPLE"] &&
                    confidence >= kDirectAnswerConfidenceThreshold &&
                    directAnswer.length > 0) {
                    NSDictionary *validatorResult = _runDirectAnswerValidator(userPrompt, directAnswer, apiKey);
                    BOOL validatorApproved = [validatorResult[@"is_valid"] respondsToSelector:@selector(boolValue)]
                        ? [validatorResult[@"is_valid"] boolValue] : NO;
                    float validatorConfidence = [validatorResult[@"confidence"] respondsToSelector:@selector(floatValue)]
                        ? [validatorResult[@"confidence"] floatValue] : 0.0f;
                    NSString *validatorReason = _safeString(validatorResult[@"reason"]);

                    EZLogf(EZLogLevelInfo, @"TRIAGE",
                           @"Stage 1b validator approved=%d conf=%.2f reason=%@",
                           validatorApproved, validatorConfidence, validatorReason);

                    if (validatorApproved && validatorConfidence >= kAnswerValidatorConfidenceThreshold) {
                        result.tier               = EZRoutingTierDirect;
                        result.needsContext       = NO;
                        result.shortCircuitAnswer = directAnswer;
                        result.estimatedTokens    = _estimateTokenCount(directAnswer);
                        EZLog(EZLogLevelInfo, @"TRIAGE", @"✓ SHORT-CIRCUIT A′ — SIMPLE after re-eval (validated)");
                        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
                        return;
                    }

                    if (validatorReason.length > 0) {
                        result.reason = [NSString stringWithFormat:@"Direct answer rejected by validator: %@", validatorReason];
                    }
                    verdict = @"NEEDS_CONTEXT";
                    EZLog(EZLogLevelInfo, @"TRIAGE",
                          @"Stage 1b validator rejected direct answer — continuing to memory retrieval");
                }

                // SHORT-CIRCUIT B′: re-eval says complex — go to main model.
                if ([verdict isEqualToString:@"COMPLEX"] || [verdict isEqualToString:@"SIMPLE"]) {
                    result.tier       = EZRoutingTierSimple;
                    result.needsContext = NO;
                    EZLog(EZLogLevelInfo, @"TRIAGE", @"✓ SHORT-CIRCUIT B′ — COMPLEX after re-eval, skip to main model");
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
                    return;
                }
                // Falls through to Stage 2 if still NEEDS_CONTEXT.

            } else {
                // Re-eval call failed — safest assumption is that we DO need context.
                verdict = @"NEEDS_CONTEXT";
                EZLog(EZLogLevelWarning, @"TRIAGE", @"Stage 1b call failed — assuming NEEDS_CONTEXT, continuing");
            }
        }

        // ── STAGE 2: MEMORY SEARCH ───────────────────────────────────────────
        // Only reached for NEEDS_CONTEXT (initial or post-re-eval).
        // Build an enriched search query by appending the triage-supplied
        // keyword tags to the raw prompt — these are the model's best guess
        // at the key terms to search for.
        EZLog(EZLogLevelInfo, @"TRIAGE", @"Stage 2 — searching memories...");

        NSMutableString *searchQuery = [NSMutableString stringWithString:userPrompt];
        for (id tag in tags) {
            if ([tag isKindOfClass:[NSString class]] && [(NSString *)tag length] > 0) {
                [searchQuery appendFormat:@" %@", (NSString *)tag];
            }
        }

        NSString *rankedMemories = EZThreadSearchMemory([searchQuery copy], apiKey);

        if (rankedMemories.length == 0) {
            // No relevant memories found. Don't inject anything — routing to
            // the main model without context is better than injecting noise.
            EZLog(EZLogLevelInfo, @"TRIAGE", @"✓ SHORT-CIRCUIT — Stage 2 found no memories, routing to main model");
            result.tier       = EZRoutingTierSimple;
            result.needsContext = NO;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── STAGE 3: MEMORY RANKER ───────────────────────────────────────────
        EZLog(EZLogLevelInfo, @"TRIAGE", @"Stage 3 — memory ranker...");

        NSDictionary *rankerResult = _runMemoryRanker(userPrompt, recentTurnsText, rankedMemories, apiKey);

        if (!rankerResult) {
            // Ranker call failed — inject all keyword-ranked memories as-is and
            // route to main model. Imperfect but better than returning nothing.
            EZLog(EZLogLevelWarning, @"TRIAGE", @"Stage 3 ranker failed — injecting keyword memories as fallback");
            NSString *enrichedPrompt = [NSString stringWithFormat:
                @"[Relevant memory context:]\n%@\n\n[User message]\n%@", rankedMemories, userPrompt];
            result.tier            = EZRoutingTierMemory;
            result.needsContext    = YES;
            result.finalPrompt     = enrichedPrompt;
            result.estimatedTokens = _estimateTokenCount(enrichedPrompt);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // Extract all fields from the ranker's JSON response.
        NSString    *rankerVerdict    = _safeString(rankerResult[@"verdict"]);
        float        rankerConfidence = [rankerResult[@"confidence"] respondsToSelector:@selector(floatValue)]
                                           ? [rankerResult[@"confidence"] floatValue] : 0.5f;
        NSString    *rankerAnswer     = [rankerResult[@"direct_answer"] isKindOfClass:[NSString class]]
                                           ? rankerResult[@"direct_answer"] : nil;
        NSString    *rankerChatKey    = [rankerResult[@"best_chat_key"] isKindOfClass:[NSString class]]
                                           ? rankerResult[@"best_chat_key"] : @"";
        NSString    *selectedMems     = _safeString(rankerResult[@"selected_memories"]);
      //  NSDictionary *rankerCheck     = [rankerResult[@"checklist"] isKindOfClass:[NSDictionary class]]
                                        //   ? rankerResult[@"checklist"] : @{};

        result.confidence = rankerConfidence;
        result.reason     = _safeString(rankerResult[@"reason"]);

        EZLogf(EZLogLevelInfo,  @"TRIAGE", @"Stage 3  verdict=%-12s conf=%.2f  %@",
               rankerVerdict.UTF8String, rankerConfidence, result.reason);
    //    EZLogf(EZLogLevelDebug, @"TRIAGE", @"Stage 3  checklist=%@", rankerCheck);

        // ── SHORT-CIRCUIT C: Ranker can answer directly ───────────────────────
        // The selected memories already contain the full answer — no need to
        // send anything to the main model.
        if ([rankerVerdict isEqualToString:@"SIMPLE"] &&
            rankerConfidence >= kDirectAnswerConfidenceThreshold &&
            rankerAnswer.length > 0) {
            result.tier               = EZRoutingTierDirect;
            result.needsContext       = NO;
            result.shortCircuitAnswer = rankerAnswer;
            result.estimatedTokens    = _estimateTokenCount(rankerAnswer);
            EZLog(EZLogLevelInfo, @"TRIAGE", @"✓ SHORT-CIRCUIT C — ranker answered directly");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── SHORT-CIRCUIT D: Complex but memories are sufficient ──────────────
        // Inject the selected memories into the prompt and route to the main model.
        if ([rankerVerdict isEqualToString:@"COMPLEX"] || [rankerVerdict isEqualToString:@"SIMPLE"]) {
            NSString *memoriesToUse  = selectedMems.length > 0 ? selectedMems : rankedMemories;
            NSString *enrichedPrompt = [NSString stringWithFormat:
                @"[Relevant memory context:]\n%@\n\n[User message]\n%@", memoriesToUse, userPrompt];
            result.tier            = EZRoutingTierMemory;
            result.needsContext    = YES;
            result.finalPrompt     = enrichedPrompt;
            result.estimatedTokens = _estimateTokenCount(enrichedPrompt);
            EZLog(EZLogLevelInfo, @"TRIAGE", @"✓ SHORT-CIRCUIT D — COMPLEX with memories → main model");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── FULL THREAD LOAD: Ranker says memories are not enough ─────────────
        // We need to dig up the actual conversation history.
        if ([rankerVerdict isEqualToString:@"NEEDS_THREAD"]) {

            // Resolve the best chatKey using a three-tier priority:
            //   1. The chatKey the AI ranker explicitly returned
            //   2. The chatKey extracted from the highest-scoring memory line
            //   3. The chatKey passed in by the caller (current session)
            // _validatedThreadID confirms the key actually exists on disk.
            NSString *memBestKey      = _bestChatKeyFromMemoryContext(
                                            selectedMems.length > 0 ? selectedMems : rankedMemories,
                                            userPrompt);
            NSString *resolvedChatKey = _validatedThreadID(rankerChatKey, @"");
            if (resolvedChatKey.length == 0) resolvedChatKey = _validatedThreadID(memBestKey, @"");
            if (resolvedChatKey.length == 0) resolvedChatKey = _validatedThreadID(chatKey ?: @"", @"");

            if (resolvedChatKey.length > 0) {
                EZChatThread *thread = EZThreadLoad(resolvedChatKey);

                // Attempt 1: tight window around the most relevant turns.
                // This is cheaper and more focused than loading the full thread.
                NSArray<NSDictionary *> *exactWindow =
                    _bestTurnWindowForQuery(thread, userPrompt, kTier4MaxTokens);
                if (exactWindow.count > 0) {
                    NSInteger usedChars = 0;
                    for (NSDictionary *turn in exactWindow) usedChars += _turnLength(turn);
                    result.tier            = EZRoutingTierFullHistory;
                    result.needsContext    = YES;
                    result.finalPrompt     = userPrompt;
                    result.injectedHistory = exactWindow;
                    result.estimatedTokens = MAX(1, usedChars / 4);
                    EZLogf(EZLogLevelInfo, @"TRIAGE",
                           @"✓ Stage 3: NEEDS_THREAD exact window — %lu turns from %@",
                           (unsigned long)exactWindow.count, resolvedChatKey);
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
                    return;
                }

                // Attempt 2: broader scored-turn context (full budget allocation).
                // Falls back here if the query-specific window found nothing.
                NSArray<NSDictionary *> *broadTurns =
                    EZThreadLoadContext(resolvedChatKey, kTier4MaxTokens);
                if (broadTurns.count > 0) {
                    result.tier            = EZRoutingTierFullHistory;
                    result.needsContext    = YES;
                    result.finalPrompt     = userPrompt;
                    result.injectedHistory = broadTurns;
                    result.estimatedTokens = kTier4MaxTokens;
                    EZLogf(EZLogLevelInfo, @"TRIAGE",
                           @"✓ Stage 3: NEEDS_THREAD broad context — %lu turns from %@",
                           (unsigned long)broadTurns.count, resolvedChatKey);
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
                    return;
                }

                EZLogf(EZLogLevelWarning, @"TRIAGE",
                       @"Stage 3: thread %@ not found or empty — falling back to memories", resolvedChatKey);
            } else {
                EZLog(EZLogLevelWarning, @"TRIAGE",
                      @"Stage 3: NEEDS_THREAD but no chatKey resolved — falling back to memories");
            }

            // Final fallback: no usable thread found. Inject whatever memories
            // we have and let the main model do its best with limited context.
            NSString *memoriesToUse  = selectedMems.length > 0 ? selectedMems : rankedMemories;
            NSString *enrichedPrompt = [NSString stringWithFormat:
                @"[Possibly relevant memoryies:]\n%@\n\n[User message]\n%@", memoriesToUse, userPrompt];
            result.tier            = EZRoutingTierMemory;
            result.needsContext    = YES;
            result.finalPrompt     = enrichedPrompt;
            result.estimatedTokens = _estimateTokenCount(enrichedPrompt);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // Unexpected verdict from the ranker — safest to route to main model
        // without injection rather than potentially injecting wrong context.
        EZLogf(EZLogLevelWarning, @"TRIAGE",
               @"Unexpected ranker verdict '%@' — defaulting to main model", rankerVerdict);
        result.tier       = EZRoutingTierSimple;
        result.needsContext = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}


// ═════════════════════════════════════════════════════════════════════════════
// SECTION 8 — MEMORY WRITE (EZCreateMemoryEntry)
//
// Creates and saves a one-sentence AI summary of a completed chat turn.
// Called by ViewController after the main model responds successfully.
//
// The summary is generated by a helper model call and then written to the
// JSON memory store on a background queue. A duplicate-detection check
// prevents consecutive identical entries (e.g. if the user sends the same
// message twice in a row).
// ═════════════════════════════════════════════════════════════════════════════

// _attachmentPathArraysEqual — returns YES if two attachment path arrays are
// identical in length and content, in order.
// Used by _memoryEntryLooksDuplicate to compare attachment lists.
static BOOL _attachmentPathArraysEqual(NSArray<NSString *> *a, NSArray<NSString *> *b) {
    if (a == b) return YES;  // same object — definitely equal
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        NSString *lhs = _safeString(a[i]);
        NSString *rhs = _safeString(b[i]);
        if (![lhs isEqualToString:rhs]) return NO;
    }
    return YES;
}

// _memoryEntryLooksDuplicate — returns YES if `candidate` and `existing`
// represent the same memory event (same summary, same chatKey, same attachments).
// Timestamps are intentionally NOT compared — two entries for the same event
// generated seconds apart should still be deduplicated.
static BOOL _memoryEntryLooksDuplicate(NSDictionary *candidate, NSDictionary *existing) {
    NSString *candidateSummary  = _safeString(candidate[@"summary"]);
    NSString *existingSummary   = _safeString(existing[@"summary"]);
    NSString *candidateChatKey  = _safeString(candidate[@"chatKey"]);
    NSString *existingChatKey   = _safeString(existing[@"chatKey"]);
    NSArray<NSString *> *candidatePaths = _safeArray(candidate[@"attachmentPaths"]);
    NSArray<NSString *> *existingPaths  = _safeArray(existing[@"attachmentPaths"]);

    // All three fields must match for it to be a duplicate.
    return candidateSummary.length > 0 &&
           [candidateSummary isEqualToString:existingSummary] &&
           [candidateChatKey isEqualToString:existingChatKey] &&
           _attachmentPathArraysEqual(candidatePaths, existingPaths);
}

// EZCreateMemoryEntry — public entry point for saving a memory.
//
// Parameters:
//   userPrompt      — what the user asked
//   assistantReply  — what the assistant answered (truncated to 1200 chars
//                     before sending to the summarizer to control cost)
//   apiKey          — OpenAI API key for the summarizer call
//   promptID        — optional unique ID for the prompt (e.g. for deduplication
//                     across rapid re-sends); not currently used in scoring
//   threadID        — optional ID of the current thread (stored as chatKey)
//   attachmentPaths — optional list of file paths involved in this turn
//   completion      — called on the main thread with the formatted entry string,
//                     or nil if saving was skipped (duplicate or error)
//
// SUMMARIZER SYSTEM PROMPT NOTES:
//   The summarizer's job is to write ONE factual sentence that accurately
//   captures what happened. The rules and examples are critical because small
//   models default to vague, generalized output ("user asked about a file")
//   when you want specific, exact output ("user asked about helpers.m line 42").
//
//   Rules 1–7 address the specific failure modes observed in production:
//     1: Don't paraphrase technical terms — keep exact names
//     2: Include complete file paths verbatim
//     3: Mention image output filenames
//     4: Don't editorialize ("expressed frustration") — state facts
//     5: Don't say what the assistant DIDN'T do — say what it DID
//     6: Name the specific subject, not the category
//     7: List individual filenames — never say "multiple files" (breaks search)
//
//   GOOD/BAD EXAMPLES: The good example shows the verbatim input → output
//   transformation. The bad example shows the most common failure (vague
//   filename generalization) so the model knows exactly what to avoid.
void EZCreateMemoryEntry(NSString *userPrompt,
                         NSString *assistantReply,
                         NSString *apiKey,
                         NSString * _Nullable promptID,
                         NSString * _Nullable threadID,
                         NSArray<NSString *> * _Nullable attachmentPaths,
                         void (^completion)(NSString * _Nullable entry)) {

    NSCParameterAssert(userPrompt);
    NSCParameterAssert(assistantReply);
    NSCParameterAssert(apiKey);

    EZLog(EZLogLevelInfo, @"MEMORY", @"Creating summary...");

    // Run on a background queue — summarizer call blocks while waiting for the network.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{

        // Build the attachment context string and collect valid (non-empty) paths.
        NSMutableString *attachmentContext = [NSMutableString string];
        NSMutableArray<NSString *> *validPaths = [NSMutableArray array];

        for (id obj in attachmentPaths) {
            NSString *path = _safeString(obj);
            if (path.length == 0) continue;
            [validPaths addObject:path];
            // Only send the filename (not the full path) to the summarizer.
            // The Documents directory path changes between installs anyway, so
            // full paths stored in summaries become stale and waste token space.
            // The filename alone is enough for the search keyword scorer to
            // match a future query like "what did we do with helpers.m?".
            [attachmentContext appendFormat:@" [file: %@]", path.lastPathComponent];
        }

        // ── SUMMARIZER SYSTEM PROMPT ─────────────────────────────────────────
        // Design goals for this prompt:
        //   • The helper model (gpt-4.1-nano) has a small context and limited
        //     reasoning capacity. Keep instructions short and concrete.
        //   • Every rule addresses a specific failure mode seen in production.
        //   • Two short examples are better than one long complex one:
        //     the first teaches specificity; the second teaches the "don't parrot"
        //     rule by showing what "no answer yet" looks like.
        //   • We deliberately do NOT ask for file paths — they go stale between
        //     app installs and waste precious summary tokens. Filenames are enough
        //     for keyword search.
        NSString *systemPrompt =
            // Core identity: one job, one sentence.
            @"You are a memory indexer for an AI chat app. "
            @"Your only job: write 1-2 sentences saying what the user asked and what the assistant answered.\n\n"
            //
            // Rule 1 (specificity) — the single most important rule.
            // Small models default to vague category words. Stop that.
            @"RULE 1 — Use the EXACT names, words, and phrases from the conversation. "
            @"Never swap a specific name for a vague category word.\n"
            @"Example:\n"
            @"USER: do you know if helpers.m is up to date?\n"
            @"AI: It was updated at 2:02 AM both locally and on Github.\n"
            @"  GOOD OUTPUT:  User asked if the AI knew if helpers.m was up to date, and the AI responded \n"
            @"        that it was updated at 2:02 AM both locally and on Github."
            @"  BAD OUTPUT:  User asked if a file was current, and assistant said it was updated on Github\n\n"
            @"  Don't rephrase- use same specific phrase 'up to date'. Include key details like 'updated locally'"
            //
           
            //
            // Rule 2 (actions over emotions) — prevents editorializing.
            @"RULE 2 — Describe what happened, not feelings. "
            @"Never say 'user expressed frustration'. Say what they actually stated.\n\n"
            @"RULE 3 - NEVER state that the assistant said that it could not do something, or that it refused."
            @"         If the assistant did not provide what was asked for, simply state that 'the assistant asked for clarification.'"
            //
            // Reminder of the output format — no preamble, no labels.
            @"Output ONLY one to two sentences. No labels, no preamble.";

        // Truncate the assistant reply to 1200 chars before sending to the summarizer.
        // We don't need the full response to write a one-sentence summary, and
        // staying under the token limit keeps latency and cost low.
        NSString *truncatedReply = assistantReply.length > 1200
            ? [assistantReply substringToIndex:1200] : assistantReply;

        NSString *contentToSummarize = [NSString stringWithFormat:
            @"USER ASKED:\n%@%@\n\nASSISTANT REPLIED:\n%@",
            userPrompt,
            attachmentContext.length > 0
                ? [NSString stringWithFormat:@"\nAttachments: %@", attachmentContext] : @"",
            truncatedReply];

        NSString *summary = _callHelperModelSync(systemPrompt, contentToSummarize, apiKey, 150);
        if (summary.length == 0) {
            EZLog(EZLogLevelWarning, @"MEMORY", @"Summarizer returned empty — skipping save");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }

        // Build the new entry dictionary.
        NSMutableDictionary *newEntry = [NSMutableDictionary dictionaryWithDictionary:@{
            @"timestamp": _timestampForDisplay(),
            @"summary":   summary,
            @"chatKey":   threadID ?: @""
        }];
        if (promptID.length > 0)       newEntry[@"promptID"]        = promptID;
        if (validPaths.count > 0)      newEntry[@"attachmentPaths"] = [validPaths copy];

        // Duplicate check and write — both happen inside a dispatch_sync on the
        // file-write queue to prevent a race condition where two background threads
        // both read the "last entry" at the same time.
        __block BOOL didSkipDuplicate = NO;
        dispatch_sync(_fileWriteQueue(), ^{
            NSMutableArray *allEntries = _loadMemoryEntries();
            NSDictionary   *lastEntry  = allEntries.lastObject;
            if ([lastEntry isKindOfClass:[NSDictionary class]] &&
                _memoryEntryLooksDuplicate(newEntry, lastEntry)) {
                didSkipDuplicate = YES;
                EZLog(EZLogLevelInfo, @"MEMORY", @"Skipped duplicate memory entry");
                return;
            }
            [allEntries addObject:[newEntry copy]];
            _saveMemoryEntries(allEntries);
        });

        // Format the entry string for the completion callback.
        NSString *formattedEntry = [NSString stringWithFormat:@"[%@] [chatKey=%@]%@ %@",
                                    newEntry[@"timestamp"],
                                    newEntry[@"chatKey"],
                                    attachmentContext,
                                    summary];
        if (!didSkipDuplicate) {
            EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved: %@", formattedEntry);
        }
        // Return the formatted entry string (or the duplicate's string) to the caller.
        dispatch_async(dispatch_get_main_queue(), ^{ completion(formattedEntry); });
    });
}

// createMemoryFromCompletion — backwards-compatible wrapper around EZCreateMemoryEntry.
//
// Earlier versions of ViewController called this function directly. It is kept
// to avoid a compile error when old call sites haven't been updated yet.
// New code should call EZCreateMemoryEntry directly (it has a `promptID` param).
//
// BEGINNER NOTE — API backwards compatibility
//   When you rename or expand a function, keeping the old version as a thin
//   wrapper means existing callers compile without changes. Over time you
//   migrate callers to the new API and eventually delete the wrapper.
void createMemoryFromCompletion(NSString *userPrompt,
                                NSString *assistantReply,
                                NSString *apiKey,
                                NSString * _Nullable chatKey,
                                NSArray<NSString *> * _Nullable attachmentPaths,
                                void (^completion)(NSString * _Nullable entry)) {
    EZCreateMemoryEntry(userPrompt,
                        assistantReply,
                        apiKey,
                        nil,        // no promptID in the old API
                        chatKey,
                        attachmentPaths,
                        completion);
}


// ═════════════════════════════════════════════════════════════════════════════
// SECTION 9 — ATTACHMENT STORAGE
//
// When the user attaches a file in the chat UI, we copy it into the app's
// EZAttachments/ sub-directory under a UUID-prefixed filename to guarantee
// uniqueness even if the user uploads two files with the same name.
//
// Attachment paths stored in memory entries and thread objects are the full
// absolute paths to these copies, not the original source paths.
// ═════════════════════════════════════════════════════════════════════════════

// Returns the EZAttachments/ directory path, creating it if necessary.
static NSString *_attachmentDirectory(void) {
    NSString *directory = [_documentsDirectory() stringByAppendingPathComponent:kAttachmentsDirName];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return directory;
}

// EZAttachmentSave — copies raw file data into EZAttachments/ with a UUID prefix.
//
// Parameters:
//   data     — the file's raw bytes
//   fileName — the original filename (used as a suffix so the stored file
//               has a recognizable name, e.g. "UUID_ViewController.m")
//
// Returns the full path of the saved file, or nil on error.
// The UUID prefix ensures no two uploads ever collide, even across sessions.
NSString * _Nullable EZAttachmentSave(NSData *data, NSString *fileName) {
    if (!data || fileName.length == 0) return nil;

    // Prepend a UUID to guarantee uniqueness.
    NSString *uniqueFileName = [NSString stringWithFormat:@"%@_%@",
                                 [[NSUUID UUID] UUIDString], fileName];
    NSString *filePath = [_attachmentDirectory() stringByAppendingPathComponent:uniqueFileName];

    NSError *writeError = nil;
    // NSDataWritingAtomic: write to a temp file, then rename — prevents partial writes.
    BOOL saved = [data writeToFile:filePath options:NSDataWritingAtomic error:&writeError];
    if (!saved) {
        EZLogf(EZLogLevelError, @"ATTACH", @"Save failed for %@: %@", fileName, writeError);
        return nil;
    }

    EZLogf(EZLogLevelInfo, @"ATTACH", @"Saved: %@", uniqueFileName);
    return filePath;
}

// EZAttachmentPath — resolves a stored attachment filename back to its full
// absolute path, or returns nil if the file no longer exists on disk.
//
// This is needed because the Documents directory path can change between app
// installs (it contains the app's container UUID). Callers should use this
// function rather than storing and reusing the full path long-term.
NSString * _Nullable EZAttachmentPath(NSString *savedFileName) {
    if (savedFileName.length == 0) return nil;
    NSString *filePath = [_attachmentDirectory() stringByAppendingPathComponent:savedFileName];
    return [[NSFileManager defaultManager] fileExistsAtPath:filePath] ? filePath : nil;
}


// ═════════════════════════════════════════════════════════════════════════════
// SECTION 10 — PUBLIC HELPER MODEL ACCESS & STATS
// ═════════════════════════════════════════════════════════════════════════════

// EZCallHelperModel — public wrapper that exposes _callHelperModelSync to
// ViewController and other external callers. Useful for one-off tasks that
// need the helper model without going through the full triage pipeline.
NSString *EZCallHelperModel(NSString *systemPrompt,
                            NSString *userMessage,
                            NSString *apiKey,
                            NSInteger maxTokens) {
    return _callHelperModelSync(systemPrompt, userMessage, apiKey, maxTokens);
}

// EZHelperStats — generates a human-readable summary of the app's state:
//   • Log file size and severity-level counts (DEBUG / INFO / WARN / ERROR)
//   • Per-routing-tier request counts (Tier 1–4)
//   • The 5 most recent log lines
//   • Memory store entry count and file size
//   • Summaries of the 3 most recent memories
//   • Count of saved threads + titles of the 3 most recent
//
// Typically displayed in a settings/debug screen. Reads log and memory files
// synchronously — call on a background thread if the files are large.
NSString *EZHelperStats(void) {
    NSMutableString *report = [NSMutableString stringWithString:@"=== EZCompleteUI Stats ===\n\n"];

    // ── LOG FILE ──────────────────────────────────────────────────────────────
    NSString *logContent = [NSString stringWithContentsOfFile:EZLogGetPath()
                                                     encoding:NSUTF8StringEncoding
                                                        error:nil];
    if (!logContent) {
        [report appendString:@"No log file found.\n"];
    } else {
        NSInteger debugCount = 0, infoCount = 0, warnCount = 0, errorCount = 0;
        NSInteger tier1 = 0, tier2 = 0, tier3 = 0, tier4 = 0;
        NSMutableArray *last5Lines = [NSMutableArray array];

        // Scan every log line once, counting occurrences of level/tier keywords.
        // This is O(n) over the log file — acceptable since log rotation keeps
        // files small, but call on a background thread for very large logs.
        for (NSString *line in [logContent componentsSeparatedByString:@"\n"]) {
            if (line.length == 0) continue;
            if ([line containsString:@"DEBUG"]) debugCount++;
            if ([line containsString:@"INFO "])  infoCount++;
            if ([line containsString:@"WARN "])  warnCount++;
            if ([line containsString:@"ERROR"]) errorCount++;
            if ([line containsString:@"Tier 1"]) tier1++;
            if ([line containsString:@"Tier 2"]) tier2++;
            if ([line containsString:@"Tier 3"]) tier3++;
            if ([line containsString:@"Tier 4"]) tier4++;

            // Maintain a rolling window of the last 5 lines without loading
            // the whole array — useful for large log files.
            [last5Lines addObject:line];
            if (last5Lines.count > 5) [last5Lines removeObjectAtIndex:0];
        }

        NSDictionary *logAttributes = [[NSFileManager defaultManager]
                                         attributesOfItemAtPath:EZLogGetPath() error:nil];
        double logSizeKB = [logAttributes[NSFileSize] unsignedLongLongValue] / 1024.0;

        [report appendFormat:@"Log: %.1f KB  D:%ld I:%ld W:%ld E:%ld\n",
         logSizeKB, (long)debugCount, (long)infoCount, (long)warnCount, (long)errorCount];
        [report appendFormat:@"Routing — T1(direct):%ld T2(simple):%ld T3(memory):%ld T4(history):%ld\n",
         (long)tier1, (long)tier2, (long)tier3, (long)tier4];
        [report appendString:@"\nRecent log entries:\n"];
        for (NSString *line in last5Lines) {
            [report appendFormat:@"  %@\n", line];
        }
        [report appendString:@"\n"];
    }

    // ── MEMORY STORE ──────────────────────────────────────────────────────────
    NSArray<NSDictionary *> *memoryEntries = EZMemoryLoadAll();
    if (memoryEntries.count == 0) {
        [report appendString:@"Memory: empty\n"];
    } else {
        NSDictionary *memAttributes = [[NSFileManager defaultManager]
                                         attributesOfItemAtPath:EZMemoryGetPath() error:nil];
        double memorySizeKB = [memAttributes[NSFileSize] unsignedLongLongValue] / 1024.0;
        [report appendFormat:@"Memory: %lu entries, %.1f KB\n",
         (unsigned long)memoryEntries.count, memorySizeKB];

        // Show the 3 most recent entries (iterate from the end of the array).
        NSInteger previewCount = MIN(3, (NSInteger)memoryEntries.count);
        [report appendString:@"Recent memories:\n"];
        for (NSInteger i = (NSInteger)memoryEntries.count - 1;
             i >= (NSInteger)memoryEntries.count - previewCount; i--) {
            NSDictionary *entry    = memoryEntries[(NSUInteger)i];
            NSString     *summary   = _safeString(entry[@"summary"]);
            NSString     *timestamp = _safeString(entry[@"timestamp"]);
            // Truncate long summaries so the stats screen stays readable.
            NSString *truncated = summary.length > 80
                ? [[summary substringToIndex:80] stringByAppendingString:@"…"] : summary;
            [report appendFormat:@"  [%@] %@\n", timestamp, truncated];
        }
    }

    // ── THREAD STORE ──────────────────────────────────────────────────────────
    NSArray<EZChatThread *> *savedThreads = EZThreadList();
    [report appendFormat:@"\nSaved threads: %lu\n", (unsigned long)savedThreads.count];
    NSInteger threadPreviewCount = MIN(3, (NSInteger)savedThreads.count);
    for (NSInteger i = 0; i < threadPreviewCount; i++) {
        EZChatThread *thread = savedThreads[(NSUInteger)i];
        [report appendFormat:@"  • %@ — %@\n", thread.updatedAt, thread.title];
    }

    [report appendString:@"\n==========================\n"];
    return [report copy];
}
