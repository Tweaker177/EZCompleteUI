// helpers.m
// EZCompleteUI v4.0

#import "helpers.h"

static NSString * const kEZLogFileName       = @"ezui_helpers.log";
static NSString * const kEZMemoryFileName    = @"ezui_memory.log";
static NSString * const kEZThreadDirName     = @"EZThreads";
static NSString * const kEZAttachmentDirName = @"EZAttachments";
static NSString * const kEZHelperModel       = @"gpt-4.1-nano";
static NSString * const kOpenAIEndpoint      = @"https://api.openai.com/v1/chat/completions";

static const float    kEZDirectAnswerThreshold = 0.85f;
static const NSInteger kEZTier4TokenBudget     = 2000;

// ─── EZContextResult ────────────────────────────────────────────────────────
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

// ─── EZChatThread ───────────────────────────────────────────────────────────
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
- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"threadID"]        = _threadID        ?: @"";
    d[@"title"]           = _title           ?: @"";
    d[@"displayText"]     = _displayText      ?: @"";
    d[@"chatContext"]     = _chatContext      ?: @[];
    d[@"modelName"]       = _modelName        ?: @"";
    d[@"createdAt"]       = _createdAt        ?: @"";
    d[@"updatedAt"]       = _updatedAt        ?: @"";
    d[@"attachmentPaths"] = _attachmentPaths  ?: @[];
    if (_lastImageLocalPath) d[@"lastImageLocalPath"] = _lastImageLocalPath;
    if (_lastVideoLocalPath) d[@"lastVideoLocalPath"] = _lastVideoLocalPath;
    return [d copy];
}
+ (nullable instancetype)fromDictionary:(NSDictionary *)dict {
    if (!dict || [dict isKindOfClass:[NSNull class]]) return nil;
    EZChatThread *t   = [[EZChatThread alloc] init];
    t.threadID        = dict[@"threadID"]    ?: @"";
    t.title           = dict[@"title"]       ?: @"New Conversation";
    t.displayText     = dict[@"displayText"] ?: @"";
    t.modelName       = dict[@"modelName"]   ?: @"";
    t.createdAt       = dict[@"createdAt"]   ?: @"";
    t.updatedAt       = dict[@"updatedAt"]   ?: @"";
    id ctx = dict[@"chatContext"];
    t.chatContext     = [ctx isKindOfClass:[NSArray class]] ? ctx : @[];
    id att = dict[@"attachmentPaths"];
    t.attachmentPaths = [att isKindOfClass:[NSArray class]] ? att : @[];
    id img = dict[@"lastImageLocalPath"];
    t.lastImageLocalPath = [img isKindOfClass:[NSString class]] ? img : nil;
    id vid = dict[@"lastVideoLocalPath"];
    t.lastVideoLocalPath = [vid isKindOfClass:[NSString class]] ? vid : nil;
    return t;
}
@end

// ─── Internal utilities ───────────────────────────────────────────────────────
static NSString *_EZDocumentsDir(void) {
    NSArray *p = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return p.firstObject ?: NSTemporaryDirectory();
}
static NSInteger _EZEstimateTokens(NSString *t) { return (NSInteger)(t.length / 4) + 1; }
static NSString *_EZTimestamp(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [f stringFromDate:[NSDate date]];
}
static NSString *_EZISO8601Now(void) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [f stringFromDate:[NSDate date]];
}
static NSString *_EZLevelString(EZLogLevel level) {
    switch (level) {
        case EZLogLevelDebug:   return @"DEBUG";
        case EZLogLevelInfo:    return @"INFO ";
        case EZLogLevelWarning: return @"WARN ";
        case EZLogLevelError:   return @"ERROR";
    }
    return @"INFO ";
}
static dispatch_queue_t _EZFileQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t  t;
    dispatch_once(&t, ^{ q = dispatch_queue_create("com.ezui.filewrite", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static void _EZAppendLineToFile(NSString *path, NSString *line) {
    dispatch_async(_EZFileQueue(), ^{
        NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:data attributes:nil];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    });
}
static NSString *_EZStripFences(NSString *raw) {
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"```"]) {
        NSRange nl = [s rangeOfString:@"\n"];
        if (nl.location != NSNotFound) s = [s substringFromIndex:nl.location + 1];
        if ([s hasSuffix:@"```"]) s = [s substringToIndex:s.length - 3];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return s;
}

// Synchronous OpenAI chat call — MUST be called on a background thread
static NSString *_EZOpenAICall(NSString *sys, NSString *user, NSString *apiKey, NSInteger maxTok) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kOpenAIEndpoint]];
    req.HTTPMethod       = @"POST";
    req.timeoutInterval  = 20;
    [req setValue:@"application/json"                              forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    NSDictionary *body = @{
        @"model": kEZHelperModel, @"max_tokens": @(maxTok), @"temperature": @0.2,
        @"messages": @[@{@"role":@"system",@"content":sys},
                       @{@"role":@"user",  @"content":user}]
    };
    NSError *encErr;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&encErr];
    if (encErr) { NSLog(@"[EZHelper] encode: %@", encErr); return nil; }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData  *rd = nil;
    __block NSError *ne = nil;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *err) {
        rd = d; ne = err; dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (ne || !rd) { NSLog(@"[EZHelper] net: %@", ne); return nil; }

    NSError *parseErr;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:rd options:0 error:&parseErr];
    if (!json || parseErr) return nil;
    id choices = json[@"choices"];
    if (!choices || [choices isKindOfClass:[NSNull class]] || [(NSArray *)choices count] == 0) return nil;
    id first = ((NSArray *)choices)[0];
    if (!first || [first isKindOfClass:[NSNull class]]) return nil;
    id msg = ((NSDictionary *)first)[@"message"];
    if (!msg || [msg isKindOfClass:[NSNull class]]) return nil;
    id content = ((NSDictionary *)msg)[@"content"];
    if (!content || [content isKindOfClass:[NSNull class]]) return nil;
    return [(NSString *)content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// ─── 1. Logging ──────────────────────────────────────────────────────────────
NSString *EZLogGetPath(void) {
    return [_EZDocumentsDir() stringByAppendingPathComponent:kEZLogFileName];
}
void EZLog(EZLogLevel level, NSString *tag, NSString *message) {
    NSString *line = [NSString stringWithFormat:@"[%@] [%@] [%@] %@",
                      _EZTimestamp(), _EZLevelString(level), tag ?: @"GENERAL", message ?: @""];
#ifdef DEBUG
    NSLog(@"%@", line);
#endif
    _EZAppendLineToFile(EZLogGetPath(), line);
}
void EZLogRotateIfNeeded(NSUInteger maxBytes) {
    NSString *lp = EZLogGetPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:lp]) return;
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:lp error:nil];
    if ((NSUInteger)[a[NSFileSize] unsignedLongLongValue] < maxBytes) return;
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *arch = [NSString stringWithFormat:@"ezui_helpers_%@.log", [f stringFromDate:[NSDate date]]];
    [[NSFileManager defaultManager] moveItemAtPath:lp
                                            toPath:[_EZDocumentsDir() stringByAppendingPathComponent:arch]
                                             error:nil];
    EZLog(EZLogLevelInfo, @"LOG", [NSString stringWithFormat:@"Rotated to %@", arch]);
}

// ─── 2. Context Analyzer (4-tier) ────────────────────────────────────────────
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
        NSString *memStr = (memoryContext.length > 0) ? memoryContext : @"(none)";
        NSString *sys =
            @"You are a routing classifier for an AI chatbot. Analyze the user prompt and return ONLY valid JSON, no markdown.\n\n"
            @"TIERS:\n"
            @"  SIMPLE        — greeting, basic fact, simple math, short task; answer with high confidence\n"
            @"  COMPLEX       — multi-step, coding, creative writing, explanation\n"
            @"  NEEDS_CONTEXT — references prior conversation, earlier results, or user preferences;\n"
            @"                  memory summary is sufficient to answer\n"
            @"  NEEDS_HISTORY — like NEEDS_CONTEXT but the summary alone is not enough;\n"
            @"                  the full original chat turns are required\n\n"
            @"Return this JSON with no extra text:\n"
            @"{\n"
            @"  \"classification\": \"SIMPLE\" | \"COMPLEX\" | \"NEEDS_CONTEXT\" | \"NEEDS_HISTORY\",\n"
            @"  \"confidence\": <float 0.0-1.0>,\n"
            @"  \"reason\": \"<one sentence>\",\n"
            @"  \"direct_answer\": \"<answer if SIMPLE + confidence>=0.85, else null>\",\n"
            @"  \"memory_sufficient\": <true | false>,\n"
            @"  \"chat_key\": \"<threadID from the most relevant memory [chatKey=...] tag, or null>\"\n"
            @"}";

        NSString *userMsg = [NSString stringWithFormat:
            @"User prompt: \"%@\"\n\nMemory entries:\n%@", userPrompt, memStr];

        NSString *raw = _EZOpenAICall(sys, userMsg, apiKey, 400);

        EZContextResult *result = [[EZContextResult alloc] init];
        result.finalPrompt     = userPrompt;
        result.estimatedTokens = _EZEstimateTokens(userPrompt);

        // ── Parse failure → Tier 2 pass-through ──────────────────────────────
        if (!raw) {
            result.tier        = EZRoutingTierSimple;
            result.needsContext = NO;
            result.reason      = @"Classifier unavailable";
            result.confidence  = 0.5f;
            EZLog(EZLogLevelWarning, @"CONTEXT", @"Classifier failed — Tier 2 default");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        NSError *je;
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:
            [_EZStripFences(raw) dataUsingEncoding:NSUTF8StringEncoding]
                                                          options:0 error:&je];
        if (je || !p || [p isKindOfClass:[NSNull class]]) {
            result.tier        = EZRoutingTierSimple;
            result.needsContext = NO;
            result.reason      = @"JSON parse error";
            result.confidence  = 0.5f;
            EZLogf(EZLogLevelWarning, @"CONTEXT", @"Parse failed: %@", raw);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        NSString *cls       = p[@"classification"] ?: @"COMPLEX";
        float     conf      = [p[@"confidence"]    floatValue];
        NSString *reason    = p[@"reason"]         ?: @"";
        id        daObj     = p[@"direct_answer"];
        NSString *da        = (daObj && ![daObj isKindOfClass:[NSNull class]]) ? (NSString *)daObj : nil;
        BOOL      memSuff   = [p[@"memory_sufficient"] boolValue];
        id        ckObj     = p[@"chat_key"];
        NSString *ck        = (ckObj && ![ckObj isKindOfClass:[NSNull class]]) ? (NSString *)ckObj : chatKey;

        result.confidence = conf;
        result.reason     = reason;

        // ── Tier 1: direct answer ─────────────────────────────────────────────
        if ([cls isEqualToString:@"SIMPLE"] && conf >= kEZDirectAnswerThreshold && da.length > 0) {
            result.tier               = EZRoutingTierDirect;
            result.needsContext       = NO;
            result.shortCircuitAnswer = da;
            result.estimatedTokens    = _EZEstimateTokens(da);
            EZLogf(EZLogLevelInfo, @"CONTEXT", @"Tier 1 direct — conf=%.2f", conf);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── Tier 2: no context ────────────────────────────────────────────────
        if ([cls isEqualToString:@"COMPLEX"] || [cls isEqualToString:@"SIMPLE"]) {
            result.tier        = EZRoutingTierSimple;
            result.needsContext = NO;
            EZLogf(EZLogLevelInfo, @"CONTEXT", @"Tier 2 — cls=%@ conf=%.2f", cls, conf);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── Tier 3: memory summary sufficient ────────────────────────────────
        BOOL isContextType = ([cls isEqualToString:@"NEEDS_CONTEXT"] ||
                              [cls isEqualToString:@"NEEDS_HISTORY"]);
        if (isContextType && memSuff && memoryContext.length > 0) {
            NSString *enriched = [NSString stringWithFormat:
                @"[Context from previous conversations]\n%@\n\n[User message]\n%@",
                memoryContext, userPrompt];
            result.tier            = EZRoutingTierMemory;
            result.needsContext    = YES;
            result.finalPrompt     = enriched;
            result.estimatedTokens = _EZEstimateTokens(enriched);
            EZLogf(EZLogLevelInfo, @"CONTEXT", @"Tier 3 — tokens=%ld", (long)result.estimatedTokens);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        // ── Tier 4: full chat history from disk ───────────────────────────────
        if ([cls isEqualToString:@"NEEDS_HISTORY"] && ck.length > 0) {
            NSArray<NSDictionary *> *history = EZThreadLoadContext(ck, kEZTier4TokenBudget);
            if (history.count > 0) {
                result.tier            = EZRoutingTierFullChat;
                result.needsContext    = YES;
                result.finalPrompt     = userPrompt;
                result.injectedHistory = history;
                result.estimatedTokens = kEZTier4TokenBudget;
                EZLogf(EZLogLevelInfo, @"CONTEXT", @"Tier 4 — %lu turns from %@",
                       (unsigned long)history.count, ck);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
                return;
            }
            EZLogf(EZLogLevelWarning, @"CONTEXT", @"Tier 4 thread not found (%@), fallback", ck);
        }

        // ── Fallback: Tier 3 with whatever memory we have ────────────────────
        if (memoryContext.length > 0) {
            NSString *enriched = [NSString stringWithFormat:
                @"[Context from previous conversations]\n%@\n\n[User message]\n%@",
                memoryContext, userPrompt];
            result.tier            = EZRoutingTierMemory;
            result.needsContext    = YES;
            result.finalPrompt     = enriched;
            result.estimatedTokens = _EZEstimateTokens(enriched);
        } else {
            result.tier        = EZRoutingTierSimple;
            result.needsContext = NO;
        }
        EZLogf(EZLogLevelInfo, @"CONTEXT", @"Fallback tier=%ld cls=%@ conf=%.2f reason=%@",
               (long)result.tier, cls, conf, reason);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}

// ─── 3. Memory ───────────────────────────────────────────────────────────────
NSString *EZMemoryGetPath(void) {
    return [_EZDocumentsDir() stringByAppendingPathComponent:kEZMemoryFileName];
}

void createMemoryFromCompletion(NSString *up, NSString *ar, NSString *ak,
                                NSString *_Nullable chatKey,
                                void (^cb)(NSString *_Nullable)) {
    NSCParameterAssert(up); NSCParameterAssert(ar); NSCParameterAssert(ak);
    EZLog(EZLogLevelInfo, @"MEMORY", @"Creating...");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSString *sys = @"You are a memory summarizer. Write ONE concise sentence (max 80 words) summarizing what was asked and answered. Only the summary, no labels.";
        NSString *msg = [NSString stringWithFormat:@"USER ASKED:\n%@\n\nASSISTANT:\n%@",
                         up, ar.length > 1200 ? [ar substringToIndex:1200] : ar];
        NSString *summary = _EZOpenAICall(sys, msg, ak, 150);
        if (!summary.length) {
            EZLog(EZLogLevelWarning, @"MEMORY", @"Empty summary");
            dispatch_async(dispatch_get_main_queue(), ^{ cb(nil); });
            return;
        }
        // [timestamp] [chatKey=threadID] summary text
        NSString *keyPart = (chatKey.length > 0)
            ? [NSString stringWithFormat:@" [chatKey=%@]", chatKey]
            : @"";
        NSString *entry = [NSString stringWithFormat:@"[%@]%@ %@", _EZTimestamp(), keyPart, summary];
        _EZAppendLineToFile(EZMemoryGetPath(), entry);
        EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved: %@", entry);
        dispatch_async(dispatch_get_main_queue(), ^{ cb(entry); });
    });
}

NSString *loadMemoryContext(NSInteger max) {
    NSError *e;
    NSString *raw = [NSString stringWithContentsOfFile:EZMemoryGetPath()
                                              encoding:NSUTF8StringEncoding error:&e];
    if (e || !raw.length) return @"";
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [entries addObject:t];
    }
    if (!entries.count) return @"";
    if (max > 0 && (NSInteger)entries.count > max)
        entries = [[entries subarrayWithRange:NSMakeRange(entries.count - max, max)] mutableCopy];
    return [entries componentsJoinedByString:@"\n"];
}

BOOL clearMemoryLog(void) {
    NSError *e;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:EZMemoryGetPath() error:&e];
    if (ok) EZLogf(EZLogLevelInfo,  @"MEMORY", @"Cleared.");
    else    EZLogf(EZLogLevelError, @"MEMORY", @"Clear failed: %@", e);
    return ok;
}

// ─── 4. Thread Store ─────────────────────────────────────────────────────────
NSString *EZThreadStoreDir(void) {
    NSString *dir = [_EZDocumentsDir() stringByAppendingPathComponent:kEZThreadDirName];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    return dir;
}
static NSString *_EZThreadPath(NSString *tid) {
    NSString *safe = [[tid stringByReplacingOccurrencesOfString:@":" withString:@"-"]
                          stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    return [[EZThreadStoreDir() stringByAppendingPathComponent:safe]
            stringByAppendingPathExtension:@"json"];
}
void EZThreadSave(EZChatThread *thread, void (^ _Nullable cb)(BOOL)) {
    if (!thread || !thread.threadID.length) {
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(NO); });
        return;
    }
    thread.updatedAt = _EZISO8601Now();
    if (!thread.createdAt.length) thread.createdAt = thread.updatedAt;
    NSDictionary *dict = [thread toDictionary];
    NSString *path     = _EZThreadPath(thread.threadID);
    dispatch_async(_EZFileQueue(), ^{
        NSError *e;
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&e];
        BOOL ok = (!e && data) ? [data writeToFile:path options:NSDataWritingAtomic error:&e] : NO;
        if (!ok) EZLogf(EZLogLevelError, @"THREADS", @"Save failed: %@", e);
        else     EZLogf(EZLogLevelInfo,  @"THREADS", @"Saved: %@", thread.threadID);
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(ok); });
    });
}
EZChatThread *_Nullable EZThreadLoad(NSString *tid) {
    NSError *e;
    NSData *data = [NSData dataWithContentsOfFile:_EZThreadPath(tid) options:0 error:&e];
    if (!data) { EZLogf(EZLogLevelWarning, @"THREADS", @"Not found: %@", tid); return nil; }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&e];
    if (e || ![json isKindOfClass:[NSDictionary class]]) {
        EZLogf(EZLogLevelError, @"THREADS", @"Parse error: %@", e);
        return nil;
    }
    return [EZChatThread fromDictionary:(NSDictionary *)json];
}
NSArray<EZChatThread *> *EZThreadList(void) {
    NSString *dir = EZThreadStoreDir();
    NSError  *e;
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:&e];
    if (!files.count) return @[];
    NSMutableArray<EZChatThread *> *threads = [NSMutableArray array];
    for (NSString *file in files) {
        if (![file hasSuffix:@".json"]) continue;
        NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:file]];
        if (!d) continue;
        id json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) continue;
        EZChatThread *t = [EZChatThread fromDictionary:(NSDictionary *)json];
        if (t.threadID.length) [threads addObject:t];
    }
    [threads sortUsingComparator:^NSComparisonResult(EZChatThread *a, EZChatThread *b) {
        return [b.updatedAt compare:a.updatedAt];
    }];
    return [threads copy];
}
BOOL EZThreadDelete(NSString *tid) {
    NSError *e;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:_EZThreadPath(tid) error:&e];
    if (ok) EZLogf(EZLogLevelInfo,  @"THREADS", @"Deleted: %@", tid);
    else    EZLogf(EZLogLevelError, @"THREADS", @"Delete failed: %@", e);
    return ok;
}
NSString *EZThreadSearchMemory(NSString *query, NSString *apiKey) {
    NSString *all = loadMemoryContext(100);
    if (!all.length || !apiKey.length) return @"";
    NSString *sys = @"You are a memory search assistant. Given a query and memory entries (each with timestamp and optional chatKey), return the 5 most relevant entries verbatim, separated by newlines. If none are relevant return empty string. No preamble.";
    NSString *msg = [NSString stringWithFormat:@"Query: %@\n\nMemories:\n%@", query, all];
    return _EZOpenAICall(sys, msg, apiKey, 400) ?: @"";
}
NSArray<NSDictionary *> *_Nullable EZThreadLoadContext(NSString *threadID, NSInteger tokenBudget) {
    EZChatThread *thread = EZThreadLoad(threadID);
    if (!thread || !thread.chatContext.count) return nil;
    NSInteger charBudget = tokenBudget * 4;
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *turn in thread.chatContext.reverseObjectEnumerator) {
        id content = turn[@"content"];
        NSInteger cost = 0;
        if ([content isKindOfClass:[NSString class]])      cost = ((NSString *)content).length;
        else if ([content isKindOfClass:[NSArray class]]) {
            for (NSDictionary *block in (NSArray *)content) {
                id text = block[@"text"];
                if ([text isKindOfClass:[NSString class]]) cost += ((NSString *)text).length;
            }
        }
        if (charBudget - cost < 0 && result.count > 0) break;
        [result insertObject:turn atIndex:0];
        charBudget -= cost;
    }
    EZLogf(EZLogLevelInfo, @"THREADS", @"LoadContext: %lu turns from %@",
           (unsigned long)result.count, threadID);
    return result.count > 0 ? [result copy] : nil;
}

// ─── 5. Attachment Store ──────────────────────────────────────────────────────
static NSString *_EZAttachDir(void) {
    NSString *dir = [_EZDocumentsDir() stringByAppendingPathComponent:kEZAttachmentDirName];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    return dir;
}
NSString *_Nullable EZAttachmentSave(NSData *data, NSString *fileName) {
    if (!data || !fileName.length) return nil;
    NSString *name = [NSString stringWithFormat:@"%@_%@", [[NSUUID UUID] UUIDString], fileName];
    NSString *path = [_EZAttachDir() stringByAppendingPathComponent:name];
    NSError  *e;
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&e];
    if (!ok) { EZLogf(EZLogLevelError, @"ATTACH", @"Save failed: %@", e); return nil; }
    EZLogf(EZLogLevelInfo, @"ATTACH", @"Saved: %@", name);
    return path;
}
NSString *_Nullable EZAttachmentPath(NSString *savedFileName) {
    if (!savedFileName.length) return nil;
    NSString *path = [_EZAttachDir() stringByAppendingPathComponent:savedFileName];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

// ─── 6. Stats ────────────────────────────────────────────────────────────────
NSString *EZHelperStats(void) {
    NSMutableString *r = [NSMutableString stringWithString:@"=== EZCompleteUI Stats ===\n\n"];
    NSString *rawLog = [NSString stringWithContentsOfFile:EZLogGetPath()
                                                encoding:NSUTF8StringEncoding error:nil];
    if (!rawLog) {
        [r appendString:@"No log found.\n"];
    } else {
        NSInteger dC=0,iC=0,wC=0,eC=0,t1=0,t2=0,t3=0,t4=0;
        NSMutableArray *last5 = [NSMutableArray array];
        for (NSString *line in [rawLog componentsSeparatedByString:@"\n"]) {
            if (!line.length) continue;
            if ([line containsString:@"DEBUG"]) dC++;
            if ([line containsString:@"INFO "]) iC++;
            if ([line containsString:@"WARN "]) wC++;
            if ([line containsString:@"ERROR"]) eC++;
            if ([line containsString:@"Tier 1"])  t1++;
            if ([line containsString:@"Tier 2"])  t2++;
            if ([line containsString:@"Tier 3"])  t3++;
            if ([line containsString:@"Tier 4"])  t4++;
            [last5 addObject:line];
            if (last5.count > 5) [last5 removeObjectAtIndex:0];
        }
        NSDictionary *la = [[NSFileManager defaultManager] attributesOfItemAtPath:EZLogGetPath() error:nil];
        [r appendFormat:@"Log: %.1f KB  D:%ld I:%ld W:%ld E:%ld\n",
         [la[NSFileSize] unsignedLongLongValue]/1024.0,(long)dC,(long)iC,(long)wC,(long)eC];
        [r appendFormat:@"Routing: T1=%ld T2=%ld T3=%ld T4=%ld\n",(long)t1,(long)t2,(long)t3,(long)t4];
        [r appendString:@"\nRecent:\n"];
        for (NSString *l in last5) if (l.length) [r appendFormat:@"  %@\n", l];
        [r appendString:@"\n"];
    }
    NSString *rawMem = [NSString stringWithContentsOfFile:EZMemoryGetPath()
                                                 encoding:NSUTF8StringEncoding error:nil];
    if (!rawMem.length) {
        [r appendString:@"Memory: empty\n"];
    } else {
        NSInteger mc = 0;
        for (NSString *l in [rawMem componentsSeparatedByString:@"\n"]) if (l.length) mc++;
        NSDictionary *ma = [[NSFileManager defaultManager] attributesOfItemAtPath:EZMemoryGetPath() error:nil];
        [r appendFormat:@"Memory: %ld entries, %.1f KB\n",
         (long)mc, [ma[NSFileSize] unsignedLongLongValue]/1024.0];
    }
    NSArray<EZChatThread *> *threads = EZThreadList();
    [r appendFormat:@"Saved threads: %lu\n", (unsigned long)threads.count];
    NSInteger show = MIN(3, (NSInteger)threads.count);
    for (NSInteger i = 0; i < show; i++) {
        EZChatThread *t = threads[(NSUInteger)i];
        [r appendFormat:@"  • %@ — %@\n", t.updatedAt, t.title];
    }
    [r appendString:@"\n==========================\n"];
    return [r copy];
}
