                                                    // helpers.m
// EZCompleteUI v5.0
//
// This file implements all background intelligence for EZCompleteUI:
//   1. Logging        — thread-safe append-only log with rotation
//   2. Context Router — 4-tier classifier that decides what context to inject
//   3. Memory Store   — JSON-based memory with two-stage semantic search
//   4. Thread Store   — saves/loads full conversation threads as JSON files
//   5. Attachments    — saves user-attached files to Documents/EZAttachments/
//   6. Stats          — human-readable diagnostic summary

#import "helpers.h"
#include <stdarg.h>
#include <stdint.h>

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Constants
// ─────────────────────────────────────────────────────────────────────────────

/// Filename for the diagnostic/helper log (not the app's user-facing log)
static NSString * const kLogFileName           = @"ezui_helpers.log";

/// Filename for the JSON memory store (replaces the old ezui_memory.log text file)
static NSString * const kMemoryJSONFileName    = @"ezui_memory.json";

/// Legacy text memory log — kept so we can migrate existing entries on first run
static NSString * const kMemoryLegacyFileName  = @"ezui_memory.log";

/// Directory name for saved conversation threads (each thread = one JSON file)
static NSString * const kThreadsDirName        = @"EZThreads";

/// Directory name for saved user attachments (images, audio, documents)
static NSString * const kAttachmentsDirName    = @"EZAttachments";

/// The cheap/fast model used for all helper tasks (routing, summarizing, searching)
static NSString * const kHelperModel           = @"gpt-4.1-nano";

/// OpenAI Chat Completions endpoint used by all helper model calls
static NSString * const kChatCompletionsURL    = @"https://api.openai.com/v1/chat/completions";

/// Confidence threshold above which a SIMPLE query is answered directly (skips main model)
static const float kDirectAnswerConfidenceThreshold = 0.85f;

/// Maximum token budget when loading full chat turns for Tier-4 context injection
static const NSInteger kTier4MaxTokens = 2000;

/// Maximum number of candidate entries passed to the AI ranker in Stage 2 of memory search.
/// Keeping this small prevents token blowout when the memory store is large.
static const NSInteger kMemorySearchCandidateLimit = 20;

/// Token budget for the AI ranker call in EZThreadSearchMemory.
/// Needs to be large enough to receive 20 candidate entries + return 5 ranked ones.
static const NSInteger kMemorySearchRankerMaxTokens = 1200;


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EZContextResult
// ─────────────────────────────────────────────────────────────────────────────

@implementation EZContextResult
- (instancetype)init {
    self = [super init];
    if (self) {
        _tier               = EZRoutingTierSimple;
        _needsContext       = NO;
        _reason             = @"";
        _finalPrompt        = @"";
        _estimatedTokens    = 0;
        _shortCircuitAnswer = nil;
        _injectedHistory    = nil;
        _confidence         = 0.5f;
    }
    return self;
}
@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EZChatThread
// ─────────────────────────────────────────────────────────────────────────────

@implementation EZChatThread

- (instancetype)init {
    self = [super init];
    if (self) {
        _threadID        = @"";
        _title           = @"New Conversation";
        _displayText     = @"";
        _chatContext     = @[];
        _modelName       = @"";
        _createdAt       = @"";
        _updatedAt       = @"";
        _attachmentPaths = @[];
    }
    return self;
}

/// Serialize to a plain NSDictionary suitable for NSJSONSerialization
- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"threadID"]        = _threadID        ?: @"";
    dict[@"title"]           = _title           ?: @"";
    dict[@"displayText"]     = _displayText      ?: @"";
    dict[@"chatContext"]     = _chatContext      ?: @[];
    dict[@"modelName"]       = _modelName        ?: @"";
    dict[@"createdAt"]       = _createdAt        ?: @"";
    dict[@"updatedAt"]       = _updatedAt        ?: @"";
    dict[@"attachmentPaths"] = _attachmentPaths  ?: @[];
    if (_lastImageLocalPath) dict[@"lastImageLocalPath"] = _lastImageLocalPath;
    if (_lastVideoLocalPath) dict[@"lastVideoLocalPath"] = _lastVideoLocalPath;
    return [dict copy];
}

/// Deserialize from a dictionary read out of a JSON thread file
+ (nullable instancetype)fromDictionary:(NSDictionary *)dict {
    if (!dict || [dict isKindOfClass:[NSNull class]]) return nil;
    EZChatThread *thread      = [[EZChatThread alloc] init];
    thread.threadID           = dict[@"threadID"]    ?: @"";
    thread.title              = dict[@"title"]       ?: @"New Conversation";
    thread.displayText        = dict[@"displayText"] ?: @"";
    thread.modelName          = dict[@"modelName"]   ?: @"";
    thread.createdAt          = dict[@"createdAt"]   ?: @"";
    thread.updatedAt          = dict[@"updatedAt"]   ?: @"";
    id ctx                    = dict[@"chatContext"];
    thread.chatContext        = [ctx isKindOfClass:[NSArray class]] ? ctx : @[];
    id attachments            = dict[@"attachmentPaths"];
    thread.attachmentPaths    = [attachments isKindOfClass:[NSArray class]] ? attachments : @[];
    id imagePath              = dict[@"lastImageLocalPath"];
    thread.lastImageLocalPath = [imagePath isKindOfClass:[NSString class]] ? imagePath : nil;
    id videoPath              = dict[@"lastVideoLocalPath"];
    thread.lastVideoLocalPath = [videoPath isKindOfClass:[NSString class]] ? videoPath : nil;
    return thread;
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Internal Utilities (private — not exposed in header)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the app's Documents directory path, falling back to NSTemporaryDirectory
static NSString *_documentsDirectory(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

/// Rough token estimate: OpenAI uses ~4 chars per token on average for English text
static NSInteger _estimateTokenCount(NSString *text) {
    return (NSInteger)(text.length / 4) + 1;
}

/// Current timestamp formatted for display in log lines: "2026-03-20 13:28:20"
static NSString *_timestampForDisplay(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [formatter stringFromDate:[NSDate date]];
}

/// Current timestamp in ISO-8601 format for thread IDs and file names: "2026-03-20T13:28:20"
static NSString *_timestampISO8601(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
    formatter.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [formatter stringFromDate:[NSDate date]];
}

/// Map a log level enum to its display string
static NSString *_logLevelString(EZLogLevel level) {
    switch (level) {
        case EZLogLevelDebug:   return @"DEBUG";
        case EZLogLevelInfo:    return @"INFO ";
        case EZLogLevelWarning: return @"WARN ";
        case EZLogLevelError:   return @"ERROR";
    }
    return @"INFO ";
}

/// A serial GCD queue used for ALL file writes in this file.
/// Using a serial queue means log lines are never interleaved even from
/// multiple concurrent background threads.
static dispatch_queue_t _fileWriteQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t  onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ezui.filewrite", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

/// Append a single line of text to a file, creating the file if it doesn't exist.
/// Called asynchronously on the serial file queue so callers never block.
static void _appendLineToFile(NSString *filePath, NSString *line) {
    dispatch_async(_fileWriteQueue(), ^{
        NSData *lineData = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:filePath]) {
            // File doesn't exist yet — create it with the first line as initial content
            [fileManager createFileAtPath:filePath contents:lineData attributes:nil];
        } else {
            // File exists — seek to end and append
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
            [fileHandle seekToEndOfFile];
            [fileHandle writeData:lineData];
            [fileHandle closeFile];
        }
    });
}

/// Strip markdown code fences (```json ... ```) from a model response string.
/// The helper model sometimes wraps its JSON in fences despite being told not to.
static NSString *_stripMarkdownFences(NSString *rawResponse) {
    NSString *trimmed = [rawResponse stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"```"]) {
        // Remove the opening fence line (e.g. "```json\n")
        NSRange firstNewline = [trimmed rangeOfString:@"\n"];
        if (firstNewline.location != NSNotFound) {
            trimmed = [trimmed substringFromIndex:firstNewline.location + 1];
        }
        // Remove the closing fence
        if ([trimmed hasSuffix:@"```"]) {
            trimmed = [trimmed substringToIndex:trimmed.length - 3];
        }
        trimmed = [trimmed stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return trimmed;
}

/// Make a synchronous OpenAI Chat Completions API call using the helper model.
/// Returns the assistant's text response, or nil on network/parse error.
///
/// ⚠️ MUST be called on a background thread — uses a semaphore to block
/// until the network response arrives. Calling from the main thread will
/// deadlock if URLSession tries to deliver the callback on main.
///
/// @param systemPrompt  The system message telling the model its role
/// @param userMessage   The user message (the actual query/data)
/// @param apiKey        OpenAI API key
/// @param maxTokens     Maximum tokens in the response. Size this carefully —
///                      too small and the model truncates; too large wastes money.
static NSString *_callHelperModelSync(NSString *systemPrompt,
                                      NSString *userMessage,
                                      NSString *apiKey,
                                      NSInteger maxTokens) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
                                    [NSURL URLWithString:kChatCompletionsURL]];
    request.HTTPMethod      = @"POST";
    request.timeoutInterval = 20;
    [request setValue:@"application/json"
   forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
   forHTTPHeaderField:@"Authorization"];

    NSDictionary *requestBody = @{
        @"model":       kHelperModel,
        @"max_tokens":  @(maxTokens),
        @"temperature": @0.2,   // Low temperature = more deterministic, better for classification/ranking
        @"messages": @[
            @{@"role": @"system", @"content": systemPrompt},
            @{@"role": @"user",   @"content": userMessage}
        ]
    };

    NSError *encodingError;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:requestBody
                                                       options:0
                                                         error:&encodingError];
    if (encodingError) {
        NSLog(@"[EZHelper] Failed to encode request body: %@", encodingError);
        return nil;
    }

    // Block the background thread until the network response arrives
    dispatch_semaphore_t semaphore  = dispatch_semaphore_create(0);
    __block NSData  *responseData   = nil;
    __block NSError *networkError   = nil;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        responseData  = data;
        networkError  = error;
        dispatch_semaphore_signal(semaphore);
    }] resume];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (networkError || !responseData) {
        NSLog(@"[EZHelper] Network error: %@", networkError);
        return nil;
    }

    NSError *parseError;
    NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:responseData
                                                                 options:0
                                                                   error:&parseError];
    if (!jsonResponse || parseError) { return nil; }

    // Navigate the Chat Completions response structure:
    // { "choices": [ { "message": { "content": "..." } } ] }
    id choices = jsonResponse[@"choices"];
    if (!choices || [choices isKindOfClass:[NSNull class]] ||
        [(NSArray *)choices count] == 0) { return nil; }

    id firstChoice = ((NSArray *)choices)[0];
    if (!firstChoice || [firstChoice isKindOfClass:[NSNull class]]) { return nil; }

    id message = ((NSDictionary *)firstChoice)[@"message"];
    if (!message || [message isKindOfClass:[NSNull class]]) { return nil; }

    id content = ((NSDictionary *)message)[@"content"];
    if (!content || [content isKindOfClass:[NSNull class]]) { return nil; }

    return [(NSString *)content stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 1. Logging
// ─────────────────────────────────────────────────────────────────────────────

NSString *EZLogGetPath(void) {
    return [_documentsDirectory() stringByAppendingPathComponent:kLogFileName];
}

void EZLog(EZLogLevel level, ...) {
    EZLogLevel resolvedLevel = level;
    NSString *resolvedTag = nil;
    NSString *resolvedMessage = nil;

    va_list args;
    va_start(args, level);

    if (level >= EZLogLevelDebug && level <= EZLogLevelError) {
        id tagArg = va_arg(args, id);
        id messageArg = va_arg(args, id);
        if ([tagArg isKindOfClass:[NSString class]] && [messageArg isKindOfClass:[NSString class]]) {
            resolvedTag = (NSString *)tagArg;
            resolvedMessage = (NSString *)messageArg;
        } else {
            // Fallback: treat this as a legacy format invocation.
            NSString *legacyFormat = [tagArg isKindOfClass:[NSString class]] ? (NSString *)tagArg : @"(invalid legacy log format)";
            resolvedLevel = EZLogLevelInfo;
            resolvedTag = @"EZLegacyLog";
            resolvedMessage = [[NSString alloc] initWithFormat:legacyFormat arguments:args];
        }
    } else {
        // Legacy invocation where the first parameter was actually an NSString *format.
        NSString *legacyFormat = (__bridge id)(void *)(uintptr_t)level;
        if (![legacyFormat isKindOfClass:[NSString class]]) {
            legacyFormat = @"(invalid legacy log format)";
        }
        resolvedLevel = EZLogLevelInfo;
        resolvedTag = @"EZLegacyLog";
        resolvedMessage = [[NSString alloc] initWithFormat:legacyFormat arguments:args];
    }

    va_end(args);

    NSString *logLine = [NSString stringWithFormat:@"[%@] [%@] [%@] %@",
                         _timestampForDisplay(),
                         _logLevelString(resolvedLevel),
                         resolvedTag ?: @"GENERAL",
                         resolvedMessage ?: @""];
#ifdef DEBUG
    NSLog(@"%@", logLine);
#endif
    _appendLineToFile(EZLogGetPath(), logLine);
}

void EZLogRotateIfNeeded(NSUInteger maxSizeBytes) {
    NSString *logPath = EZLogGetPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) return;

    NSDictionary *fileAttributes = [[NSFileManager defaultManager]
                                    attributesOfItemAtPath:logPath error:nil];
    NSUInteger currentSize = (NSUInteger)[fileAttributes[NSFileSize] unsignedLongLongValue];

    if (currentSize < maxSizeBytes) return; // Still within size limit

    // Rotate by renaming the current log to a timestamped archive name
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat       = @"yyyyMMdd_HHmmss";
    NSString *archiveName  = [NSString stringWithFormat:@"ezui_helpers_%@.log",
                               [formatter stringFromDate:[NSDate date]]];
    NSString *archivePath  = [_documentsDirectory() stringByAppendingPathComponent:archiveName];

    [[NSFileManager defaultManager] moveItemAtPath:logPath toPath:archivePath error:nil];
    EZLog(EZLogLevelInfo, @"LOG", [NSString stringWithFormat:@"Rotated to %@", archiveName]);
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 2. Context Analyzer (4-tier routing)
// ─────────────────────────────────────────────────────────────────────────────
//
// The classifier asks gpt-4.1-nano to categorize the user's prompt into one
// of four tiers, then this function acts on that decision:
//
//  Tier 1 (SIMPLE, high confidence):
//    The helper model can answer directly — no main model call needed.
//    Saves tokens and is faster. E.g. "What's 15% of 80?" or "Say hello in French."
//
//  Tier 2 (COMPLEX, no prior context needed):
//    Send to main model as-is. E.g. "Write me a Python web scraper."
//
//  Tier 3 (NEEDS_CONTEXT, memory summary sufficient):
//    Prepend the relevant memory summaries to the prompt before sending.
//    E.g. "Continue our discussion about the loan options."
//
//  Tier 4 (NEEDS_HISTORY, full turns needed):
//    Load the actual conversation turns from disk and inject them into
//    chatContext. Used when the memory summary doesn't have enough detail.
//    E.g. "What was the exact code you wrote for me last week?"

void analyzePromptForContext(NSString *userPrompt,
                             NSString *_Nullable memoryContext,
                             NSString *apiKey,
                             NSString *_Nullable chatKey,
                             void (^completion)(EZContextResult *)) {
    NSCParameterAssert(userPrompt);
    NSCParameterAssert(apiKey);
    NSCParameterAssert(completion);
    EZLog(EZLogLevelInfo, @"CONTEXT", @"Analyzing (4-tier)...");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        // Show "(none)" if no memory was provided, so the classifier knows
        NSString *memoryContextForClassifier = (memoryContext.length > 0)
            ? memoryContext : @"(none)";

        // IMPORTANT: Pass the raw userPrompt to the classifier, NOT the file-enriched version.
        // The classifier only needs to know what the user asked, not the full file contents.
        // Truncate memory to prevent token blowout with large memory logs.
        NSString *truncatedMemory = memoryContextForClassifier.length > 3000
            ? [[memoryContextForClassifier substringToIndex:3000] stringByAppendingString:@"\n[...truncated]"]
            : memoryContextForClassifier;

        NSString *systemPrompt =
            @"You are a routing classifier for an AI chatbot. Analyze the user prompt and return ONLY valid JSON, no markdown.\n\n"
            @"IMPORTANT: The 'Memory entries' section below contains PAST conversation summaries — "
            @"they are provided as context, NOT as part of the user's current question.\n\n"
            @"TIERS:\n"
            @"  SIMPLE        — greeting, basic fact, simple math, short task; answer with high confidence\n"
            @"  COMPLEX       — multi-step, coding, creative writing, explanation; no prior context needed\n"
            @"  NEEDS_CONTEXT — user references something from a prior conversation; memory summaries are enough\n"
            @"  NEEDS_HISTORY — references prior conversation BUT summaries lack enough detail; full chat turns needed\n\n"
            @"If the user is asking about an ATTACHED FILE that was just added to context this session, "
            @"classify as COMPLEX (the file content is already in the conversation — no memory needed).\n\n"
            @"Return this JSON with no extra text:\n"
            @"{\n"
            @"  \"classification\": \"SIMPLE\" | \"COMPLEX\" | \"NEEDS_CONTEXT\" | \"NEEDS_HISTORY\",\n"
            @"  \"confidence\": <float 0.0-1.0>,\n"
            @"  \"reason\": \"<one sentence explaining the classification>\",\n"
            @"  \"direct_answer\": \"<your answer if SIMPLE + confidence>=0.85, else null>\",\n"
            @"  \"memory_sufficient\": <true if memory summaries are enough, false if full history needed>,\n"
            @"  \"chat_key\": \"<the threadID from the most relevant memory [chatKey=...] tag, or null>\"\n"
            @"}";

        NSString *userMessage = [NSString stringWithFormat:
            @"Current user prompt: \"%@\"\n\n--- Past memory entries (context only, not part of user's question) ---\n%@",
            userPrompt, truncatedMemory];

        // Call the helper model synchronously (we're already on a background thread)
        NSString *rawResponse = _callHelperModelSync(systemPrompt, userMessage, apiKey, 400);

        // Build a default result we can populate before dispatching
        EZContextResult *result    = [[EZContextResult alloc] init];
        result.finalPrompt         = userPrompt;
        result.estimatedTokens     = _estimateTokenCount(userPrompt);

        // ── Handle classifier failure (network down, API error, etc.) ─────────
        if (!rawResponse) {
            result.tier         = EZRoutingTierSimple;
            result.needsContext = NO;
            result.reason       = @"Classifier unavailable — defaulting to Tier 2";
            result.confidence   = 0.5f;
            EZLog(EZLogLevelWarning, @"CONTEXT", @"Classifier call failed — Tier 2 default");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── Parse the JSON response ───────────────────────────────────────────
        NSError *jsonParseError;
        NSDictionary *classifierResult = [NSJSONSerialization JSONObjectWithData:
            [_stripMarkdownFences(rawResponse) dataUsingEncoding:NSUTF8StringEncoding]
                                                                         options:0
                                                                           error:&jsonParseError];
        if (jsonParseError || !classifierResult ||
            [classifierResult isKindOfClass:[NSNull class]]) {
            result.tier         = EZRoutingTierSimple;
            result.needsContext = NO;
            result.reason       = @"JSON parse error — defaulting to Tier 2";
            result.confidence   = 0.5f;
            EZLogf(EZLogLevelWarning, @"CONTEXT", @"Parse failed. Raw response: %@", rawResponse);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── Extract classifier fields ─────────────────────────────────────────
        NSString *classification   = classifierResult[@"classification"] ?: @"COMPLEX";
        float     confidence       = [classifierResult[@"confidence"] floatValue];
        NSString *reason           = classifierResult[@"reason"]       ?: @"";
        BOOL      memorySufficient = [classifierResult[@"memory_sufficient"] boolValue];

        // direct_answer may be null in JSON — guard against NSNull
        id directAnswerObj = classifierResult[@"direct_answer"];
        NSString *directAnswer = (directAnswerObj && ![directAnswerObj isKindOfClass:[NSNull class]])
            ? (NSString *)directAnswerObj : nil;

        // chat_key from classifier, falling back to the threadID passed in
        id chatKeyObj = classifierResult[@"chat_key"];
        NSString *resolvedChatKey = (chatKeyObj && ![chatKeyObj isKindOfClass:[NSNull class]])
            ? (NSString *)chatKeyObj : chatKey;

        result.confidence = confidence;
        result.reason     = reason;

        // ── Tier 1: helper answers directly ──────────────────────────────────
        // Only used when: classification=SIMPLE, confidence≥0.85, and we have an answer
        if ([classification isEqualToString:@"SIMPLE"] &&
            confidence >= kDirectAnswerConfidenceThreshold &&
            directAnswer.length > 0) {
            result.tier               = EZRoutingTierDirect;
            result.needsContext       = NO;
            result.shortCircuitAnswer = directAnswer;
            result.estimatedTokens    = _estimateTokenCount(directAnswer);
            EZLogf(EZLogLevelInfo, @"CONTEXT", @"Tier 1 direct answer — conf=%.2f", confidence);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── Tier 2: no context needed ─────────────────────────────────────────
        // Used for COMPLEX or low-confidence SIMPLE prompts that don't reference history
        if ([classification isEqualToString:@"COMPLEX"] ||
            [classification isEqualToString:@"SIMPLE"]) {
            result.tier         = EZRoutingTierSimple;
            result.needsContext = NO;
            EZLogf(EZLogLevelInfo, @"CONTEXT", @"Tier 2 — cls=%@ conf=%.2f", classification, confidence);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── Tier 3: inject memory summaries ──────────────────────────────────
        // Used when the prompt references prior conversations AND the memory
        // summaries we have are detailed enough to answer without loading raw turns
        BOOL isContextClassification = ([classification isEqualToString:@"NEEDS_CONTEXT"] ||
                                        [classification isEqualToString:@"NEEDS_HISTORY"]);
        if (isContextClassification && memorySufficient && memoryContext.length > 0) {
            // Build enriched prompt: memory context as preamble, then user message
            NSString *enrichedPrompt = [NSString stringWithFormat:
                @"[Memories with possible relevance:]\n%@\n\n[User message]\n%@",
                memoryContext, userPrompt];
            result.tier            = EZRoutingTierMemory;
            result.needsContext    = YES;
            result.finalPrompt     = enrichedPrompt;
            result.estimatedTokens = _estimateTokenCount(enrichedPrompt);
            EZLogf(EZLogLevelInfo, @"CONTEXT", @"Tier 3 memory — ~%ld tokens",
                   (long)result.estimatedTokens);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── Tier 4: load full conversation turns from disk ────────────────────
        // Used when NEEDS_HISTORY and the memory summary isn't sufficient.
        // We load the most recent turns from the thread file up to the token budget.
        if ([classification isEqualToString:@"NEEDS_HISTORY"] && resolvedChatKey.length > 0) {
            NSArray<NSDictionary *> *conversationTurns = EZThreadLoadContext(resolvedChatKey,
                                                                             kTier4MaxTokens);
            if (conversationTurns.count > 0) {
                result.tier            = EZRoutingTierFullChat;
                result.needsContext    = YES;
                result.finalPrompt     = userPrompt;
                result.injectedHistory = conversationTurns;
                result.estimatedTokens = kTier4MaxTokens;
                EZLogf(EZLogLevelInfo, @"CONTEXT", @"Tier 4 — %lu turns from thread %@",
                       (unsigned long)conversationTurns.count, resolvedChatKey);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
                return;
            }
            // Thread file not found or empty — warn and fall through to Tier 3 fallback
            EZLogf(EZLogLevelWarning, @"CONTEXT",
                   @"Tier 4 thread not found (%@) — falling back to Tier 3", resolvedChatKey);
        }

        // ── Fallback: best-effort with whatever memory we have ────────────────
        if (memoryContext.length > 0) {
            NSString *enrichedPrompt = [NSString stringWithFormat:
                @"[Memories with possible relevance: ]\n%@\n\n[User message]\n%@",
                memoryContext, userPrompt];
            result.tier            = EZRoutingTierMemory;
            result.needsContext    = YES;
            result.finalPrompt     = enrichedPrompt;
            result.estimatedTokens = _estimateTokenCount(enrichedPrompt);
        } else {
            result.tier         = EZRoutingTierSimple;
            result.needsContext = NO;
        }

        EZLogf(EZLogLevelInfo, @"CONTEXT",
               @"Fallback tier=%ld cls=%@ conf=%.2f reason=%@",
               (long)result.tier, classification, confidence, reason);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 3. Memory Store (JSON)
// ─────────────────────────────────────────────────────────────────────────────
//
// Memory entries are stored as a JSON array in Documents/ezui_memory.json.
// Each entry is a dictionary:
//   {
//     "timestamp": "2026-03-20 13:51:45",   // display timestamp
//     "summary":   "The user asked about...", // one-sentence AI summary
//     "chatKey":   "2026-03-20T13:28:20"     // threadID — links back to full thread
//   }
//
// This structure lets us:
//   - Load all entries quickly without parsing text
//   - Do local keyword scoring without an API call
//   - Pass only the most promising candidates to the AI ranker
//   - Follow chatKey to load the full thread if needed (Tier 4)

NSString *EZMemoryGetPath(void) {
    return [_documentsDirectory() stringByAppendingPathComponent:kMemoryJSONFileName];
}

/// Internal: return the path to the legacy text-format memory log (if it exists)
static NSString *_legacyMemoryLogPath(void) {
    return [_documentsDirectory() stringByAppendingPathComponent:kMemoryLegacyFileName];
}

/// Internal: migrate old text-format memory entries to JSON on first run.
/// Parses lines like "[2026-03-20 13:51:45] [chatKey=...] Summary text"
/// and writes them to the new JSON store.
static void _migrateMemoryIfNeeded(void) {
    NSString *jsonPath   = EZMemoryGetPath();
    NSString *legacyPath = _legacyMemoryLogPath();

    // Only migrate if JSON store doesn't exist yet but legacy file does
    if ([[NSFileManager defaultManager] fileExistsAtPath:jsonPath]) return;
    if (![[NSFileManager defaultManager] fileExistsAtPath:legacyPath]) return;

    NSError  *readError;
    NSString *legacyContent = [NSString stringWithContentsOfFile:legacyPath
                                                        encoding:NSUTF8StringEncoding
                                                           error:&readError];
    if (readError || !legacyContent.length) return;

    NSMutableArray *migratedEntries = [NSMutableArray array];
    for (NSString *line in [legacyContent componentsSeparatedByString:@"\n"]) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!trimmedLine.length) continue;

        // Parse: "[timestamp] [chatKey=ID] summary text"
        // or:    "[timestamp] summary text"  (no chatKey)
        NSString *timestamp = @"";
        NSString *chatKey   = @"";
        NSString *summary   = trimmedLine;

        // Extract timestamp from first [...]
        NSRange tsStart = [trimmedLine rangeOfString:@"["];
        NSRange tsEnd   = [trimmedLine rangeOfString:@"]"];
        if (tsStart.location == 0 && tsEnd.location != NSNotFound) {
            timestamp = [trimmedLine substringWithRange:
                         NSMakeRange(1, tsEnd.location - 1)];
            summary   = [[trimmedLine substringFromIndex:tsEnd.location + 1]
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }

        // Extract chatKey from optional [chatKey=...] tag
        NSRange ckRange = [summary rangeOfString:@"[chatKey="];
        if (ckRange.location != NSNotFound) {
            NSRange ckEnd = [summary rangeOfString:@"]"
                                           options:0
                                             range:NSMakeRange(ckRange.location,
                                                               summary.length - ckRange.location)];
            if (ckEnd.location != NSNotFound) {
                NSRange valueRange = NSMakeRange(ckRange.location + 8,
                                                 ckEnd.location - ckRange.location - 8);
                chatKey = [summary substringWithRange:valueRange];
                // Remove the [chatKey=...] tag from the summary text
                NSString *beforeTag = [summary substringToIndex:ckRange.location];
                NSString *afterTag  = [summary substringFromIndex:ckEnd.location + 1];
                summary = [[beforeTag stringByAppendingString:afterTag]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
        }

        if (summary.length > 0) {
            [migratedEntries addObject:@{
                @"timestamp": timestamp,
                @"summary":   summary,
                @"chatKey":   chatKey
            }];
        }
    }

    if (migratedEntries.count > 0) {
        NSError *writeError;
        NSData  *jsonData = [NSJSONSerialization dataWithJSONObject:migratedEntries
                                                            options:NSJSONWritingPrettyPrinted
                                                              error:&writeError];
        if (!writeError && jsonData) {
            [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:nil];
            EZLogf(EZLogLevelInfo, @"MEMORY",
                   @"Migrated %lu legacy entries to JSON store", (unsigned long)migratedEntries.count);
        }
    }
}

/// Internal: load the full JSON memory array from disk.
/// Returns an empty array if the file doesn't exist or can't be parsed.
static NSMutableArray<NSDictionary *> *_loadMemoryEntries(void) {
    _migrateMemoryIfNeeded(); // No-op after first successful migration

    NSError *readError;
    NSData  *fileData = [NSData dataWithContentsOfFile:EZMemoryGetPath()
                                               options:0
                                                 error:&readError];
    if (readError || !fileData) return [NSMutableArray array];

    NSError *parseError;
    id parsed = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:&parseError];
    if (parseError || ![parsed isKindOfClass:[NSArray class]]) return [NSMutableArray array];

    return [((NSArray *)parsed) mutableCopy];
}

/// Internal: atomically write the full entries array back to the JSON file.
static void _saveMemoryEntries(NSArray<NSDictionary *> *entries) {
    NSError *serializeError;
    NSData  *jsonData = [NSJSONSerialization dataWithJSONObject:entries
                                                        options:NSJSONWritingPrettyPrinted
                                                          error:&serializeError];
    if (serializeError || !jsonData) {
        EZLogf(EZLogLevelError, @"MEMORY", @"Failed to serialize entries: %@", serializeError);
        return;
    }
    NSError *writeError;
    [jsonData writeToFile:EZMemoryGetPath() options:NSDataWritingAtomic error:&writeError];
    if (writeError) {
        EZLogf(EZLogLevelError, @"MEMORY", @"Failed to write memory JSON: %@", writeError);
    }
}

void createMemoryFromCompletion(NSString *userPrompt,
                                NSString *assistantReply,
                                NSString *apiKey,
                                NSString *_Nullable chatKey,
                                NSArray<NSString *> *_Nullable attachmentPaths,
                                void (^completion)(NSString *_Nullable)) {
    NSCParameterAssert(userPrompt);
    NSCParameterAssert(assistantReply);
    NSCParameterAssert(apiKey);

    EZLog(EZLogLevelInfo, @"MEMORY", @"Creating summary...");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{

        // Build full path info for attachments — store FULL paths not just filenames
        // so the model can provide the exact path when asked
        NSMutableString *attachmentContext = [NSMutableString string];
        NSMutableArray<NSString *> *validPaths = [NSMutableArray array];
        for (NSString *path in attachmentPaths) {
            if (!path.length) continue;
            [validPaths addObject:path];
            // Store the full path in the attachment context so it ends up in the summary
            [attachmentContext appendFormat:@" [file: %@ full_path=%@]",
             path.lastPathComponent, path];
        }

        NSString *systemPrompt =
            @"You are a memory indexer for an AI chat app. Write ONE factual sentence "
             "describing exactly what was asked and answered. Rules:\n"
             "1. Keep the SAME specific words, names, file names, paths, and technical terms — do NOT paraphrase or generalize.\n"
             "2. If a file path is provided (full_path=...) include the COMPLETE path verbatim in the summary.\n"
             "3. If an image was generated or edited, include the output filename and full path.\n"
             "4. Never say 'the user expressed frustration' — say what they actually asked.\n"
             "5. Never say 'the assistant explained it cannot...' — say what the assistant actually did or provided.\n"
             "6. Be specific: 'user asked for lyrics to Give Me Love by Ed Sheeran' not 'user asked about a song'.\n"
             "7. When files are involved, LIST EACH filename explicitly — never say 'multiple files' or 'several .m files'.\n\n"
             "GOOD EXAMPLE:\n"
             "Input: User asked about duplicate methods ezcui_resolvedTopTitle and ezcui_beginLongOperation "
             "in ViewController+EZTopButtons.m, ViewController+EZTitleResolver.m, and ViewController+EZKeepAwake.m. "
             "[file: ViewController+EZTopButtons.m full_path=/var/mobile/Containers/.../ViewController+EZTopButtons.m]\n"
             "Output: User asked about duplicate category methods ezcui_resolvedTopTitle and ezcui_beginLongOperation "
             "found in ViewController+EZTopButtons.m, ViewController+EZTitleResolver.m, and ViewController+EZKeepAwake.m "
             "and sought grep commands to identify and consolidate them; "
             "full path: /var/mobile/Containers/.../ViewController+EZTopButtons.m\n\n"
             "BAD EXAMPLE:\n"
             "Input: (same as above)\n"
             "Output: User asked about duplicate category methods in multiple .m files and sought steps to fix them.\n"
             "(BAD: 'multiple .m files' is a generalization — list each filename explicitly)\n\n"
             "Only the summary sentence, no labels or preamble.";


        // Truncate long replies to avoid burning too many tokens on the summarizer
        NSString *truncatedReply = assistantReply.length > 1200
            ? [assistantReply substringToIndex:1200]
            : assistantReply;

        // Include FULL attachment paths in the content so they appear in the summary
        NSString *contentToSummarize = [NSString stringWithFormat:
            @"USER ASKED:\n%@%@\n\nASSISTANT REPLIED:\n%@",
            userPrompt,
            attachmentContext.length > 0 ? [NSString stringWithFormat:@"\nAttachments: %@", attachmentContext] : @"",
            truncatedReply];

        NSString *summary = _callHelperModelSync(systemPrompt, contentToSummarize, apiKey, 150);
        if (!summary.length) {
            EZLog(EZLogLevelWarning, @"MEMORY", @"Summarizer returned empty — skipping save");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }

        // Build the memory entry dict.
        // attachmentPaths is stored as an array so the app can reopen any file
        // by asking "pull up my resume" — the path is right here in the memory entry.
        NSMutableDictionary *newEntry = [NSMutableDictionary dictionaryWithDictionary:@{
            @"timestamp":       _timestampForDisplay(),
            @"summary":         summary,
            @"chatKey":         chatKey ?: @""
        }];
        if (validPaths.count > 0) {
            newEntry[@"attachmentPaths"] = [validPaths copy];
        }

        // Load existing entries, append, and write back atomically
        dispatch_sync(_fileWriteQueue(), ^{
            NSMutableArray *allEntries = _loadMemoryEntries();
            [allEntries addObject:[newEntry copy]];
            _saveMemoryEntries(allEntries);
        });

        NSString *formattedEntry = [NSString stringWithFormat:@"[%@] [chatKey=%@]%@ %@",
                                    newEntry[@"timestamp"],
                                    newEntry[@"chatKey"],
                                    attachmentContext,
                                    summary];
        EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved: %@", formattedEntry);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(formattedEntry); });
    });
}

NSArray<NSDictionary *> *EZMemoryLoadAll(void) {
    return _loadMemoryEntries();
}

NSString *loadMemoryContext(NSInteger maxEntries) {
    NSArray<NSDictionary *> *allEntries = _loadMemoryEntries();
    if (!allEntries.count) return @"";

    // Slice to the N most recent entries if a limit is given
    NSArray<NSDictionary *> *entriesToReturn = allEntries;
    if (maxEntries > 0 && (NSInteger)allEntries.count > maxEntries) {
        NSRange recentRange = NSMakeRange(allEntries.count - (NSUInteger)maxEntries,
                                         (NSUInteger)maxEntries);
        entriesToReturn = [allEntries subarrayWithRange:recentRange];
    }

    // Format each entry as a single line including timestamp, chatKey, attachments, and summary
    NSMutableArray<NSString *> *formattedLines = [NSMutableArray array];
    for (NSDictionary *entry in entriesToReturn) {
        NSString *timestamp       = entry[@"timestamp"]  ?: @"";
        NSString *summary         = entry[@"summary"]    ?: @"";
        NSString *chatKey         = entry[@"chatKey"]    ?: @"";
        NSArray  *attachments     = entry[@"attachmentPaths"];

        NSString *keyTag = chatKey.length > 0
            ? [NSString stringWithFormat:@" [chatKey=%@]", chatKey] : @"";

        // Include attachment filenames so the classifier knows files were involved
        NSMutableString *attachTag = [NSMutableString string];
        for (NSString *path in attachments) {
            if (path.length > 0) {
                [attachTag appendFormat:@" [file:%@]", path.lastPathComponent];
            }
        }

        [formattedLines addObject:[NSString stringWithFormat:@"[%@]%@%@ %@",
                                   timestamp, keyTag, attachTag, summary]];
    }
    return [formattedLines componentsJoinedByString:@"\n"];
}

BOOL clearMemoryLog(void) {
    NSError *error;
    BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:EZMemoryGetPath() error:&error];
    if (removed) {
        EZLog(EZLogLevelInfo, @"MEMORY", @"Memory store cleared.");
    } else {
        EZLogf(EZLogLevelError, @"MEMORY", @"Clear failed: %@", error);
    }
    return removed;
}

NSString *EZThreadSearchMemory(NSString *searchQuery, NSString *apiKey) {
    // ── Stage 1: Local keyword scoring (free, no API call) ───────────────────
    //
    // We score every memory entry by how many words from the search query
    // appear in the summary. This is cheap and fast — it runs entirely in
    // memory with no network call. We then take the top candidates and pass
    // only those to the AI for final ranking.
    //
    
    NSArray<NSDictionary *> *allEntries = _loadMemoryEntries();
    if (!allEntries.count) {
        EZLogf(EZLogLevelInfo, @"MEMORY", @"Search: memory store is empty");
        return @"";
    }
    if (!apiKey.length) {
        // No API key — just return the most recent entries
        return loadMemoryContext(5);
    }

    EZLogf(EZLogLevelInfo, @"MEMORY", @"Semantic search: %lu entries for query: %@",
           (unsigned long)allEntries.count, searchQuery);

    // Split the query into individual words (lowercased) for matching
    NSArray<NSString *> *queryWords = [[searchQuery lowercaseString]
                                       componentsSeparatedByCharactersInSet:
                                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Remove short stop words that would match everything
    NSSet<NSString *> *stopWords = [NSSet setWithObjects:
        @"a",@"an",@"the",@"is",@"was",@"are",@"were",@"i",@"my",@"me",@"you",
        @"your",@"it",@"to",@"of",@"in",@"on",@"at",@"for",@"and",@"or",@"but",
        @"can",@"do",@"did",@"will",@"with",@"that",@"this",@"what",@"how",nil];
    NSMutableArray<NSString *> *meaningfulQueryWords = [NSMutableArray array];
    for (NSString *word in queryWords) {
        NSString *cleaned = [[word componentsSeparatedByCharactersInSet:
                              [NSCharacterSet punctuationCharacterSet]] componentsJoinedByString:@""];
        if (cleaned.length > 2 && ![stopWords containsObject:cleaned]) {
            [meaningfulQueryWords addObject:cleaned];
        }
    }

    // Score each entry by word overlap with the query
    NSMutableArray<NSDictionary *> *scoredEntries = [NSMutableArray array];
    for (NSDictionary *entry in allEntries) {
        NSString *summarylower = [entry[@"summary"] lowercaseString] ?: @"";
        NSInteger matchCount   = 0;
        for (NSString *queryWord in meaningfulQueryWords) {
            if ([summarylower containsString:queryWord]) {
                matchCount++;
            }
        }
        // Also boost entries whose chatKey matches (they're from related threads)
        NSInteger score = matchCount;
        [scoredEntries addObject:@{
            @"entry": entry,
            @"score": @(score)
        }];
    }

    // Sort by score descending, then by recency (index) descending as tiebreaker
    [scoredEntries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger scoreA = [a[@"score"] integerValue];
        NSInteger scoreB = [b[@"score"] integerValue];
        if (scoreB != scoreA) return scoreB > scoreA ? NSOrderedDescending : NSOrderedAscending;
        // Equal score — prefer more recent (higher index in original array means more recent)
        NSUInteger indexA = [allEntries indexOfObject:a[@"entry"]];
        NSUInteger indexB = [allEntries indexOfObject:b[@"entry"]];
        return indexB > indexA ? NSOrderedDescending : NSOrderedAscending;
    }];

    // Take only the top candidates to pass to Stage 2
    NSInteger candidateCount = MIN(kMemorySearchCandidateLimit, (NSInteger)scoredEntries.count);
    NSArray *topCandidates   = [scoredEntries subarrayWithRange:NSMakeRange(0, (NSUInteger)candidateCount)];

    // If all candidates scored 0 (no keyword overlap), fall back to most recent entries
    BOOL allScoresZero = YES;
    for (NSDictionary *scored in topCandidates) {
        if ([scored[@"score"] integerValue] > 0) { allScoresZero = NO; break; }
    }
    if (allScoresZero) {
        EZLogf(EZLogLevelInfo, @"MEMORY",
               @"Search: no keyword overlap found — returning 5 most recent entries");
        return loadMemoryContext(5);
    }

    // ── Stage 2: AI ranker — final relevance ranking ─────────────────────────
    //
    // Now we send only the top candidates (at most kMemorySearchCandidateLimit)
    // to the AI model with a token budget large enough to actually work.
    // The model returns the 5 most relevant entries verbatim.

    NSMutableArray<NSString *> *candidateLines = [NSMutableArray array];
    for (NSDictionary *scored in topCandidates) {
        NSDictionary *entry    = scored[@"entry"];
        NSString *timestamp    = entry[@"timestamp"] ?: @"";
        NSString *summary      = entry[@"summary"]   ?: @"";
        NSString *chatKey      = entry[@"chatKey"]   ?: @"";
        NSString *keyTag       = chatKey.length > 0
            ? [NSString stringWithFormat:@" [chatKey=%@]", chatKey] : @"";
        [candidateLines addObject:[NSString stringWithFormat:@"[%@]%@ %@",
                                   timestamp, keyTag, summary]];
    }
    NSString *candidatesText = [candidateLines componentsJoinedByString:@"\n"];

    NSString *rankerSystemPrompt =
        @"You are a memory relevance ranker. Given a search query and a list of memory entries, "
        @"select up to 3 entries that are MOST USEFUL for answering the query. "
        @"Rules:\n"
        @"1. Prefer entries with SPECIFIC details (exact file paths, filenames, values, names) over vague ones.\n"
        @"2. Do NOT return multiple entries that say essentially the same thing — pick the most specific version.\n"
        @"3. If an entry contains a file path, prefer it over one that only has a filename, if it's otherwise equally relevant.\n"
        @"4. Return selected entries VERBATIM (copy them exactly), one per line.\n"
        @"5. If fewer than 3 are truly relevant, return only those. If none relevant, return a single zero,.\n"
        @"6. CRITICAL: Your input is a list of memory entries. Return ONLY lines from that list — "
        @"never return grep output, tmp file paths, or any content that was not in the memory entries list.\n\n"
        @"GOOD EXAMPLE:\n"
        @"Search query: \"duplicate category methods\"\n"
        @"Memory entries:\n"
        @"[2026-03-20 09:15:00] [chatKey=2026-03-20T09:14:00] User asked about duplicate ezcui_resolvedTopTitle in ViewController+EZTopButtons.m and ViewController+EZTitleResolver.m\n"
        @"[2026-03-19 14:22:00] [chatKey=2026-03-19T14:21:00] User generated image of a sunset, saved to /var/mobile/.../sunset.png\n\n"
        @"Correct output:\n"
        @"[2026-03-20 09:15:00] [chatKey=2026-03-20T09:14:00] User asked about duplicate ezcui_resolvedTopTitle in ViewController+EZTopButtons.m and ViewController+EZTitleResolver.m\n\n"
        @"BAD EXAMPLE:\n"
        @"Search query: \"duplicate category methods\"\n"
        @"(same memory entries as above)\n\n"
        @"Bad output:\n"
        @"[ViewController+EZTopButtons.m:20:- (NSString *)ezcui_resolvedTopTitle; ./ViewController+EZTopButtons.m:20]\n"
        @"(BAD: this is grep output — you must only return lines from the memory entries list, verbatim)\n\n"
        @"No preamble, no explanation, no numbering — just the entries.";

    NSString *rankerUserMessage = [NSString stringWithFormat:
        @"Search query: \"%@\"\n\nMemory entries to rank:\n%@",
        searchQuery, candidatesText];

    EZLogf(EZLogLevelInfo, @"MEMORY",
           @"Search Stage 2: ranking %ld candidates (token budget: %ld)",
           (long)candidateCount, (long)kMemorySearchRankerMaxTokens);

    NSString *rankerResponse = _callHelperModelSync(rankerSystemPrompt,
                                                    rankerUserMessage,
                                                    apiKey,
                                                    kMemorySearchRankerMaxTokens);

    if (rankerResponse.length > 0) {
        EZLogf(EZLogLevelInfo, @"MEMORY",
               @"Search complete — %lu chars returned", (unsigned long)rankerResponse.length);
        return rankerResponse;
    }

    // Stage 2 failed — fall back to Stage 1 top 3 (not 5) by keyword score
    EZLog(EZLogLevelWarning, @"MEMORY", @"Stage 2 ranker failed — using Stage 1 keyword results");
    NSInteger fallbackCount = MIN(3, (NSInteger)topCandidates.count);
    NSArray *fallback = [candidateLines subarrayWithRange:NSMakeRange(0, (NSUInteger)fallbackCount)];
    return [fallback componentsJoinedByString:@"\n"];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 4. Thread Store
// ─────────────────────────────────────────────────────────────────────────────
//
// Each conversation thread is stored as a separate JSON file in:
//   Documents/EZThreads/<threadID>.json
//
// Using one file per thread (rather than one big file) means:
//   - Loading a specific thread (Tier-4) is O(1) — just read one file
//   - Saving doesn't require rewriting all threads
//   - Listing threads just reads directory contents

NSString *EZThreadStoreDir(void) {
    NSString *threadsDirectory = [_documentsDirectory()
                                  stringByAppendingPathComponent:kThreadsDirName];
    // Create the directory if it doesn't exist (withIntermediateDirectories:YES = no-op if exists)
    [[NSFileManager defaultManager] createDirectoryAtPath:threadsDirectory
                                  withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    return threadsDirectory;
}

/// Build the full file path for a thread file, sanitizing the threadID
/// (replaces colons and spaces which are illegal in some file system contexts)
static NSString *_threadFilePath(NSString *threadID) {
    NSString *safeFileName = [[threadID stringByReplacingOccurrencesOfString:@":" withString:@"-"]
                                        stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    return [[EZThreadStoreDir() stringByAppendingPathComponent:safeFileName]
            stringByAppendingPathExtension:@"json"];
}

void EZThreadSave(EZChatThread *thread, void (^ _Nullable completionCallback)(BOOL)) {
    if (!thread || !thread.threadID.length) {
        EZLog(EZLogLevelWarning, @"THREADS", @"Save called with nil/empty thread — ignoring");
        if (completionCallback) dispatch_async(dispatch_get_main_queue(), ^{ completionCallback(NO); });
        return;
    }

    // Update the timestamp before serializing
    thread.updatedAt = _timestampISO8601();
    if (!thread.createdAt.length) thread.createdAt = thread.updatedAt;

    NSDictionary *threadDict = [thread toDictionary];
    NSString     *filePath   = _threadFilePath(thread.threadID);

    // Write on the serial file queue to avoid concurrent writes to the same file
    dispatch_async(_fileWriteQueue(), ^{
        NSError *serializeError;
        NSData  *jsonData = [NSJSONSerialization dataWithJSONObject:threadDict
                                                            options:NSJSONWritingPrettyPrinted
                                                              error:&serializeError];
        BOOL success = NO;
        if (!serializeError && jsonData) {
            NSError *writeError;
            success = [jsonData writeToFile:filePath options:NSDataWritingAtomic error:&writeError];
            if (!success) EZLogf(EZLogLevelError, @"THREADS", @"Write failed: %@", writeError);
        } else {
            EZLogf(EZLogLevelError, @"THREADS", @"Serialize failed: %@", serializeError);
        }
        if (success) EZLogf(EZLogLevelInfo, @"THREADS", @"Saved: %@", thread.threadID);
        if (completionCallback) dispatch_async(dispatch_get_main_queue(), ^{ completionCallback(success); });
    });
}

EZChatThread *_Nullable EZThreadLoad(NSString *threadID) {
    NSError *readError;
    NSData  *fileData = [NSData dataWithContentsOfFile:_threadFilePath(threadID)
                                               options:0
                                                 error:&readError];
    if (!fileData) {
        EZLogf(EZLogLevelWarning, @"THREADS", @"Thread not found: %@", threadID);
        return nil;
    }

    NSError *parseError;
    id parsedJSON = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:&parseError];
    if (parseError || ![parsedJSON isKindOfClass:[NSDictionary class]]) {
        EZLogf(EZLogLevelError, @"THREADS", @"Parse error for %@: %@", threadID, parseError);
        return nil;
    }

    return [EZChatThread fromDictionary:(NSDictionary *)parsedJSON];
}

NSArray<EZChatThread *> *EZThreadList(void) {
    NSString *threadsDirectory = EZThreadStoreDir();
    NSError  *directoryError;
    NSArray<NSString *> *fileNames = [[NSFileManager defaultManager]
                                      contentsOfDirectoryAtPath:threadsDirectory
                                                          error:&directoryError];
    if (!fileNames.count) return @[];

    NSMutableArray<EZChatThread *> *threads = [NSMutableArray array];
    for (NSString *fileName in fileNames) {
        if (![fileName hasSuffix:@".json"]) continue;  // Skip non-thread files

        NSString *fullPath = [threadsDirectory stringByAppendingPathComponent:fileName];
        NSData   *fileData = [NSData dataWithContentsOfFile:fullPath];
        if (!fileData) continue;

        id parsedJSON = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:nil];
        if (![parsedJSON isKindOfClass:[NSDictionary class]]) continue;

        EZChatThread *thread = [EZChatThread fromDictionary:(NSDictionary *)parsedJSON];
        if (thread.threadID.length) [threads addObject:thread];
    }

    // Sort newest-first by updatedAt timestamp (ISO-8601 strings sort lexicographically)
    [threads sortUsingComparator:^NSComparisonResult(EZChatThread *a, EZChatThread *b) {
        return [b.updatedAt compare:a.updatedAt];
    }];
    return [threads copy];
}

BOOL EZThreadDelete(NSString *threadID) {
    NSError *deleteError;
    BOOL    deleted = [[NSFileManager defaultManager] removeItemAtPath:_threadFilePath(threadID)
                                                                 error:&deleteError];
    if (deleted) EZLogf(EZLogLevelInfo,  @"THREADS", @"Deleted: %@", threadID);
    else         EZLogf(EZLogLevelError, @"THREADS", @"Delete failed for %@: %@", threadID, deleteError);
    return deleted;
}

NSArray<NSDictionary *> *_Nullable EZThreadLoadContext(NSString *threadID, NSInteger tokenBudget) {
    EZChatThread *thread = EZThreadLoad(threadID);
    if (!thread || !thread.chatContext.count) return nil;

    // ── Strategy: relevance-aware turn selection ──────────────────────────────
    //
    // The old approach just took the most recent N turns up to the token budget.
    // Problem: if your resume discussion happened 200 turns ago in a long thread,
    // the budget window never reaches it.
    //
    // New approach:
    //   1. Always include the most recent 4 turns (gives the model recent context)
    //   2. Search ALL turns for ones that are semantically rich (long assistant
    //      replies, turns mentioning files/attachments, turns with detailed content)
    //   3. Fill remaining token budget with those relevant turns, oldest first
    //      so the model sees them in chronological order
    //
    // This is done without an API call — pure local heuristics — so it's free.

    NSInteger characterBudget = tokenBudget * 4; // 1 token ≈ 4 chars
    NSArray<NSDictionary *> *allTurns = thread.chatContext;
    NSUInteger totalTurns = allTurns.count;

    // Helper: get text content length of a turn (handles both string and array content)
    NSInteger (^turnLength)(NSDictionary *) = ^NSInteger(NSDictionary *turn) {
        id content = turn[@"content"];
        if ([content isKindOfClass:[NSString class]]) return ((NSString *)content).length;
        if ([content isKindOfClass:[NSArray class]]) {
            NSInteger total = 0;
            for (NSDictionary *block in (NSArray *)content) {
                id text = block[@"text"];
                if ([text isKindOfClass:[NSString class]]) total += ((NSString *)text).length;
            }
            return total;
        }
        return 0;
    };

    // Helper: does this turn mention a file, image, or attachment?
    BOOL (^turnHasAttachment)(NSDictionary *) = ^BOOL(NSDictionary *turn) {
        id content = turn[@"content"];
        NSString *text = @"";
        if ([content isKindOfClass:[NSString class]]) text = content;
        else if ([content isKindOfClass:[NSArray class]]) {
            for (NSDictionary *block in (NSArray *)content) {
                // Vision messages have image_url blocks — always relevant
                if ([[block[@"type"] description] containsString:@"image"]) return YES;
                id blockText = block[@"text"];
                if ([blockText isKindOfClass:[NSString class]]) {
                    text = [text stringByAppendingString:(NSString *)blockText];
                }
            }
        }
        // Check for keywords that indicate file work happened
        NSString *lower = text.lowercaseString;
        return [lower containsString:@"attached"]  || [lower containsString:@"resume"]     ||
               [lower containsString:@"document"]  || [lower containsString:@"pdf"]        ||
               [lower containsString:@"image"]     || [lower containsString:@"generated"]  ||
               [lower containsString:@"edited"]    || [lower containsString:@"file"]        ||
               [lower containsString:@"epub"]      || [lower containsString:@"transcript"];
    };

    // ── Step 1: reserve the most recent 4 turns ───────────────────────────────
    NSInteger recentTurnCount = MIN(4, (NSInteger)totalTurns);
    NSMutableSet<NSNumber *> *includedIndices = [NSMutableSet set];
    NSInteger budgetUsed = 0;

    for (NSInteger i = (NSInteger)totalTurns - 1;
         i >= (NSInteger)totalTurns - recentTurnCount; i--) {
        [includedIndices addObject:@(i)];
        budgetUsed += turnLength(allTurns[(NSUInteger)i]);
    }

    // ── Step 2: score remaining turns by relevance ────────────────────────────
    // Score = content length (longer = more substantive) + bonus for attachments
    NSMutableArray<NSDictionary *> *scoredTurns = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)totalTurns - recentTurnCount; i++) {
        NSDictionary *turn   = allTurns[(NSUInteger)i];
        NSString *role       = turn[@"role"] ?: @"";
        NSInteger length     = turnLength(turn);
        BOOL hasAttachment   = turnHasAttachment(turn);

        // Only score assistant turns and user turns with attachments or long content.
        // Skip short user messages like "ok" or "thanks" — low information density.
        BOOL isAssistant     = [role isEqualToString:@"assistant"];
        BOOL isSubstantial   = length > 100 || hasAttachment;
        if (!isAssistant && !isSubstantial) continue;

        NSInteger score = length;
        if (hasAttachment) score += 500;   // Strong bonus for file-related turns
        if (isAssistant)   score += 200;   // Prefer assistant turns (they have the answers)

        [scoredTurns addObject:@{@"index": @(i), @"score": @(score), @"length": @(length)}];
    }

    // Sort by score descending
    [scoredTurns sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"score"] compare:a[@"score"]];
    }];

    // ── Step 3: fill remaining budget with highest-scoring turns ─────────────
    for (NSDictionary *scored in scoredTurns) {
        NSInteger idx    = [scored[@"index"] integerValue];
        NSInteger length = [scored[@"length"] integerValue];
        if (budgetUsed + length > characterBudget) continue; // Skip if too large
        if ([includedIndices containsObject:@(idx)]) continue; // Already included
        [includedIndices addObject:@(idx)];
        budgetUsed += length;
        if (budgetUsed >= characterBudget) break;
    }

    // ── Step 4: collect selected turns in chronological order ─────────────────
    NSArray<NSNumber *> *sortedIndices = [[includedIndices allObjects]
        sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSDictionary *> *selectedTurns = [NSMutableArray array];
    for (NSNumber *index in sortedIndices) {
        [selectedTurns addObject:allTurns[(NSUInteger)index.integerValue]];
    }

    EZLogf(EZLogLevelInfo, @"THREADS",
           @"LoadContext: %lu/%lu turns selected from thread %@ (~%ld tokens)",
           (unsigned long)selectedTurns.count,
           (unsigned long)totalTurns,
           threadID,
           (long)(budgetUsed / 4));
    return selectedTurns.count > 0 ? [selectedTurns copy] : nil;
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 5. Attachment Store
// ─────────────────────────────────────────────────────────────────────────────
//
// User-attached files are saved to Documents/EZAttachments/ with a UUID prefix
// to prevent name collisions. The full local path is stored in:
//   - EZChatThread.attachmentPaths (for the thread that used it)
//   - Memory entry chatKey (indirectly via the thread)

static NSString *_attachmentDirectory(void) {
    NSString *directory = [_documentsDirectory() stringByAppendingPathComponent:kAttachmentsDirName];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    return directory;
}

NSString *_Nullable EZAttachmentSave(NSData *data, NSString *originalFileName) {
    if (!data || !originalFileName.length) return nil;

    // Prefix with UUID to guarantee uniqueness even if same file is attached twice
    NSString *uniqueFileName = [NSString stringWithFormat:@"%@_%@",
                                [[NSUUID UUID] UUIDString], originalFileName];
    NSString *filePath = [_attachmentDirectory() stringByAppendingPathComponent:uniqueFileName];

    NSError *writeError;
    BOOL    saved = [data writeToFile:filePath options:NSDataWritingAtomic error:&writeError];
    if (!saved) {
        EZLogf(EZLogLevelError, @"ATTACH", @"Save failed for %@: %@", originalFileName, writeError);
        return nil;
    }
    EZLogf(EZLogLevelInfo, @"ATTACH", @"Saved: %@", uniqueFileName);
    return filePath;
}

NSString *_Nullable EZAttachmentPath(NSString *savedFileName) {
    if (!savedFileName.length) return nil;
    NSString *filePath = [_attachmentDirectory() stringByAppendingPathComponent:savedFileName];
    return [[NSFileManager defaultManager] fileExistsAtPath:filePath] ? filePath : nil;
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 6. Stats
// ─────────────────────────────────────────────────────────────────────────────

/// Public wrapper around _callHelperModelSync for callers outside helpers.m
NSString *_Nullable EZCallHelperModel(NSString *systemPrompt,
                                       NSString *userMessage,
                                       NSString *apiKey,
                                       NSInteger maxTokens) {
    return _callHelperModelSync(systemPrompt, userMessage, apiKey, maxTokens);
}

NSString *EZHelperStats(void) {
    NSMutableString *report = [NSMutableString stringWithString:@"=== EZCompleteUI Stats ===\n\n"];

    // ── Log file stats ────────────────────────────────────────────────────────
    NSString *logContent = [NSString stringWithContentsOfFile:EZLogGetPath()
                                                     encoding:NSUTF8StringEncoding error:nil];
    if (!logContent) {
        [report appendString:@"No log file found.\n"];
    } else {
        NSInteger debugCount=0, infoCount=0, warnCount=0, errorCount=0;
        NSInteger tier1=0, tier2=0, tier3=0, tier4=0;
        NSMutableArray *last5Lines = [NSMutableArray array];

        for (NSString *line in [logContent componentsSeparatedByString:@"\n"]) {
            if (!line.length) continue;
            if ([line containsString:@"DEBUG"]) debugCount++;
            if ([line containsString:@"INFO "])  infoCount++;
            if ([line containsString:@"WARN "])  warnCount++;
            if ([line containsString:@"ERROR"])  errorCount++;
            if ([line containsString:@"Tier 1"]) tier1++;
            if ([line containsString:@"Tier 2"]) tier2++;
            if ([line containsString:@"Tier 3"]) tier3++;
            if ([line containsString:@"Tier 4"]) tier4++;
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
            if (line.length) [report appendFormat:@"  %@\n", line];
        }
        [report appendString:@"\n"];
    }

    // ── Memory store stats ────────────────────────────────────────────────────
    NSArray<NSDictionary *> *memoryEntries = EZMemoryLoadAll();
    if (!memoryEntries.count) {
        [report appendString:@"Memory: empty\n"];
    } else {
        NSDictionary *memAttributes = [[NSFileManager defaultManager]
                                       attributesOfItemAtPath:EZMemoryGetPath() error:nil];
        double memorySizeKB = [memAttributes[NSFileSize] unsignedLongLongValue] / 1024.0;
        [report appendFormat:@"Memory: %lu entries, %.1f KB\n",
         (unsigned long)memoryEntries.count, memorySizeKB];

        // Show the 3 most recent entries as a preview
        NSInteger previewCount = MIN(3, (NSInteger)memoryEntries.count);
        [report appendString:@"Recent memories:\n"];
        for (NSInteger i = (NSInteger)memoryEntries.count - 1;
             i >= (NSInteger)memoryEntries.count - previewCount; i--) {
            NSDictionary *entry = memoryEntries[(NSUInteger)i];
            NSString *summary   = entry[@"summary"] ?: @"";
            NSString *timestamp = entry[@"timestamp"] ?: @"";
            NSString *truncated = summary.length > 80
                ? [[summary substringToIndex:80] stringByAppendingString:@"…"]
                : summary;
            [report appendFormat:@"  [%@] %@\n", timestamp, truncated];
        }
    }

    // ── Saved threads stats ───────────────────────────────────────────────────
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
