// helpers.m
// EZCompleteUI
//
// Implementation of all system-wide helpers.
// AI tasks use gpt-4.1-nano to minimize cost.
// Non-AI tasks (logging, file I/O) use only Foundation.

#import "helpers.h"

static NSString * const kEZLogFileName     = @"ezui_helpers.log";
static NSString * const kEZMemoryFileName  = @"ezui_memory.log";
static NSString * const kEZHelperModel     = @"gpt-4.1-nano";
static NSString * const kOpenAIEndpoint    = @"https://api.openai.com/v1/chat/completions";

@implementation EZContextResult
- (instancetype)init {
    self = [super init];
    if (self) {
        _needsContext     = NO;
        _reason           = @"";
        _finalPrompt      = @"";
        _estimatedTokens  = 0;
    }
    return self;
}
@end

static NSString *_EZDocumentsDir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static NSInteger _EZEstimateTokens(NSString *text) {
    return (NSInteger)(text.length / 4) + 1;
}

static NSString *_EZTimestamp(void) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [fmt stringFromDate:[NSDate date]];
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

static void _EZAppendLineToFile(NSString *filePath, NSString *line) {
    static dispatch_queue_t fileQ;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fileQ = dispatch_queue_create("com.ezui.filewrite", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(fileQ, ^{
        NSString *entry = [line stringByAppendingString:@"\n"];
        NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            [[NSFileManager defaultManager] createFileAtPath:filePath contents:data attributes:nil];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:filePath];
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    });
}

// FIX 1: Replaced removed sendSynchronousRequest API with semaphore wrapper.
// Fully null-safe: guards every JSON field against NSNull before subscripting.
static NSString *_EZOpenAICall(NSString *systemPrompt, NSString *userMessage,
                                NSString *apiKey, NSInteger maxTokens) {
    NSURL *url = [NSURL URLWithString:kOpenAIEndpoint];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
       forHTTPHeaderField:@"Authorization"];

    NSDictionary *body = @{
        @"model"      : kEZHelperModel,
        @"max_tokens" : @(maxTokens),
        @"temperature": @0.2,
        @"messages"   : @[
            @{ @"role": @"system", @"content": systemPrompt },
            @{ @"role": @"user",   @"content": userMessage  }
        ]
    };

    NSError *jsonErr;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr) { NSLog(@"[EZHelper] JSON encode error: %@", jsonErr); return nil; }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData  *responseData = nil;
    __block NSError *netErr       = nil;

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                       completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            responseData = d;
            netErr = e;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (netErr || !responseData) { NSLog(@"[EZHelper] Network error: %@", netErr); return nil; }

    NSError *parseErr;
    id jsonObj = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&parseErr];
    if (parseErr || !jsonObj || [jsonObj isKindOfClass:[NSNull class]]) {
        NSLog(@"[EZHelper] JSON parse error: %@", parseErr); return nil;
    }
    NSDictionary *json = jsonObj;

    id choicesObj = json[@"choices"];
    if (!choicesObj || [choicesObj isKindOfClass:[NSNull class]]) {
        NSLog(@"[EZHelper] Missing choices in response"); return nil;
    }
    NSArray *choices = choicesObj;
    if (choices.count == 0) {
        NSLog(@"[EZHelper] Empty choices array"); return nil;
    }

    id firstChoice = choices[0];
    if (!firstChoice || [firstChoice isKindOfClass:[NSNull class]]) {
        NSLog(@"[EZHelper] Null first choice"); return nil;
    }

    id msgObj = ((NSDictionary *)firstChoice)[@"message"];
    if (!msgObj || [msgObj isKindOfClass:[NSNull class]]) {
        NSLog(@"[EZHelper] Null message object"); return nil;
    }

    id contentObj = ((NSDictionary *)msgObj)[@"content"];
    if (!contentObj || [contentObj isKindOfClass:[NSNull class]]) {
        NSLog(@"[EZHelper] Null content — model may have refused"); return nil;
    }

    return [((NSString *)contentObj) stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// MARK: - 1. Logging

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
    NSString *logPath = EZLogGetPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:logPath]) return;
    NSDictionary *attrs = [fm attributesOfItemAtPath:logPath error:nil];
    NSUInteger size = (NSUInteger)[attrs[NSFileSize] unsignedLongLongValue];
    if (size < maxBytes) return;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *archiveName = [NSString stringWithFormat:@"ezui_helpers_%@.log",
                             [fmt stringFromDate:[NSDate date]]];
    NSString *archivePath = [_EZDocumentsDir() stringByAppendingPathComponent:archiveName];
    [fm moveItemAtPath:logPath toPath:archivePath error:nil];
    EZLog(EZLogLevelInfo, @"LOG", ([NSString stringWithFormat:@"Rotated log to %@", archiveName]));
}

// MARK: - 2. Prompt Context Analyzer
// FIX 2: NSParameterAssert -> NSCParameterAssert in all C functions.

void analyzePromptForContext(NSString *userPrompt, NSString *memoryContext,
                             NSString *apiKey, void (^completion)(EZContextResult *result)) {
    NSCParameterAssert(userPrompt);
    NSCParameterAssert(apiKey);
    NSCParameterAssert(completion);

    EZLog(EZLogLevelInfo, @"CONTEXT", @"Analyzing prompt complexity...");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *systemPrompt =
            @"You are a prompt complexity classifier for a chatbot app. "
            @"Your ONLY job is to decide whether a user prompt is SIMPLE or COMPLEX. "
            @"\n\nRULES:\n"
            @"- SIMPLE: greetings, short factual questions, single-step tasks, "
            @"  chit-chat, yes/no questions. These do NOT need extra memory context injected.\n"
            @"- COMPLEX: multi-step tasks, coding requests, \'explain in detail\', "
            @"  questions referencing earlier conversations, requests that benefit from "
            @"  knowing the user\'s history or preferences.\n"
            @"\nRespond ONLY with a JSON object in this exact format (no markdown):\n"
            @"{\"needs_context\": true, \"reason\": \"one short sentence\"}\n"
            @"or\n"
            @"{\"needs_context\": false, \"reason\": \"one short sentence\"}";

        NSString *classifyMessage = [NSString stringWithFormat:
            @"User prompt to classify:\n\"%@\"", userPrompt];

        NSString *rawResponse = _EZOpenAICall(systemPrompt, classifyMessage, apiKey, 120);
        EZContextResult *result = [[EZContextResult alloc] init];
        result.finalPrompt = userPrompt;

        if (!rawResponse) {
            result.needsContext    = NO;
            result.reason          = @"Classifier unavailable — sending without context";
            result.estimatedTokens = _EZEstimateTokens(userPrompt);
            EZLog(EZLogLevelWarning, @"CONTEXT", @"Classifier call failed, failing open");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        NSError *jsonErr;
        NSData *jsonData = [rawResponse dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonErr];
        if (jsonErr || !parsed) {
            result.needsContext    = NO;
            result.reason          = @"Parse error — sending without context";
            result.estimatedTokens = _EZEstimateTokens(userPrompt);
            EZLog(EZLogLevelWarning, @"CONTEXT", @"Could not parse classifier JSON, failing open");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        BOOL needsCtx    = [parsed[@"needs_context"] boolValue];
        NSString *reason = parsed[@"reason"] ?: @"";
        result.needsContext = needsCtx;
        result.reason       = reason;

        if (needsCtx && memoryContext.length > 0) {
            result.finalPrompt = [NSString stringWithFormat:
                @"[Relevant context from previous conversations]\n%@\n\n[User message]\n%@",
                memoryContext, userPrompt];
        } else {
            result.finalPrompt = userPrompt;
        }
        result.estimatedTokens = _EZEstimateTokens(result.finalPrompt);
        EZLogf(EZLogLevelInfo, @"CONTEXT", @"needsContext=%@ tokens=%ld reason=%@",
               needsCtx ? @"YES" : @"NO", (long)result.estimatedTokens, reason);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}

// MARK: - 3. Memory Creator

NSString *EZMemoryGetPath(void) {
    return [_EZDocumentsDir() stringByAppendingPathComponent:kEZMemoryFileName];
}

void createMemoryFromCompletion(NSString *userPrompt, NSString *assistantReply,
                                NSString *apiKey, void (^completion)(NSString *memoryEntry)) {
    NSCParameterAssert(userPrompt);
    NSCParameterAssert(assistantReply);
    NSCParameterAssert(apiKey);

    EZLog(EZLogLevelInfo, @"MEMORY", @"Creating memory from completion...");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSString *systemPrompt =
            @"You are a memory summarizer for an AI chatbot app. "
            @"Given a user question and an assistant reply, write a SINGLE concise summary "
            @"sentence (max 80 words) capturing: what was asked, what was answered, and any "
            @"key facts or preferences revealed. "
            @"Write ONLY the summary — no labels, no JSON, no preamble. "
            @"Be terse. Avoid filler words.";

        NSString *userMessage = [NSString stringWithFormat:
            @"USER ASKED:\n%@\n\nASSISTANT REPLIED:\n%@",
            userPrompt,
            (assistantReply.length > 1200) ? [assistantReply substringToIndex:1200] : assistantReply];

        NSString *summary = _EZOpenAICall(systemPrompt, userMessage, apiKey, 150);
        if (!summary || summary.length == 0) {
            EZLog(EZLogLevelWarning, @"MEMORY", @"Memory summarizer returned empty.");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }

        NSString *entry = [NSString stringWithFormat:@"[%@] %@", _EZTimestamp(), summary];
        _EZAppendLineToFile(EZMemoryGetPath(), entry);
        EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved memory: %@", entry);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(entry); });
    });
}

// MARK: - 4. Memory Loader

NSString *loadMemoryContext(NSInteger maxEntries) {
    NSString *path = EZMemoryGetPath();
    NSError *err;
    NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
    if (err || !raw || raw.length == 0) return @"";

    NSArray<NSString *> *lines = [raw componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) [entries addObject:trimmed];
    }
    if (entries.count == 0) return @"";

    NSArray<NSString *> *recent;
    if (maxEntries > 0 && (NSInteger)entries.count > maxEntries) {
        recent = [entries subarrayWithRange:NSMakeRange(entries.count - maxEntries, maxEntries)];
    } else {
        recent = entries;
    }
    return [recent componentsJoinedByString:@"\n"];
}

BOOL clearMemoryLog(void) {
    NSString *path = EZMemoryGetPath();
    NSError *err;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:path error:&err];
    if (ok) {
        EZLog(EZLogLevelInfo, @"MEMORY", @"Memory log cleared by user.");
    } else {
        EZLogf(EZLogLevelError, @"MEMORY", @"Failed to clear memory log: %@", err);
    }
    return ok;
}

// MARK: - 5. Stats / Diagnostics

NSString *EZHelperStats(void) {
    NSMutableString *report = [NSMutableString string];
    [report appendString:@"=== EZCompleteUI Helper Stats ===\n\n"];

    NSString *logPath = EZLogGetPath();
    NSError *err;
    NSString *rawLog = [NSString stringWithContentsOfFile:logPath
                                                 encoding:NSUTF8StringEncoding error:&err];
    if (!rawLog) {
        [report appendString:@"No helper log found.\n"];
    } else {
        NSArray<NSString *> *logLines = [rawLog componentsSeparatedByString:@"\n"];
        NSInteger debugCount = 0, infoCount = 0, warnCount = 0, errorCount = 0;
        NSInteger ctxYes = 0, ctxNo = 0;
        NSMutableArray<NSString *> *lastFive = [NSMutableArray array];

        for (NSString *line in logLines) {
            if (line.length == 0) continue;
            if ([line containsString:@"[DEBUG]"]) debugCount++;
            if ([line containsString:@"[INFO "]) infoCount++;
            if ([line containsString:@"[WARN "]) warnCount++;
            if ([line containsString:@"[ERROR]"]) errorCount++;
            if ([line containsString:@"needsContext=YES"]) ctxYes++;
            if ([line containsString:@"needsContext=NO"])  ctxNo++;
            [lastFive addObject:line];
            if (lastFive.count > 5) [lastFive removeObjectAtIndex:0];
        }

        NSDictionary *logAttrs = [[NSFileManager defaultManager]
                                  attributesOfItemAtPath:logPath error:nil];
        unsigned long long logSize = [logAttrs[NSFileSize] unsignedLongLongValue];
        [report appendFormat:@"Log: %.1f KB\n", logSize / 1024.0];
        [report appendFormat:@"  DEBUG: %ld  INFO: %ld  WARN: %ld  ERROR: %ld\n\n",
         (long)debugCount, (long)infoCount, (long)warnCount, (long)errorCount];

        [report appendString:@"Context Analyzer:\n"];
        NSInteger ctxTotal = ctxYes + ctxNo;
        if (ctxTotal > 0) {
            [report appendFormat:@"  Injected: %ld/%ld (%.0f%%)\n",
             (long)ctxYes, (long)ctxTotal, (ctxYes * 100.0 / ctxTotal)];
            [report appendFormat:@"  Skipped:  %ld/%ld (%.0f%%)\n\n",
             (long)ctxNo, (long)ctxTotal, (ctxNo * 100.0 / ctxTotal)];
        } else {
            [report appendString:@"  No context analysis entries yet.\n\n"];
        }

        [report appendString:@"Recent Log Entries:\n"];
        for (NSString *line in lastFive) {
            [report appendFormat:@"  %@\n", line];
        }
        [report appendString:@"\n"];
    }

    NSString *memPath = EZMemoryGetPath();
    NSString *rawMem = [NSString stringWithContentsOfFile:memPath
                                                 encoding:NSUTF8StringEncoding error:nil];
    if (!rawMem || rawMem.length == 0) {
        [report appendString:@"Memory Log: empty\n"];
    } else {
        NSArray<NSString *> *memLines = [rawMem componentsSeparatedByString:@"\n"];
        NSInteger memCount = 0;
        for (NSString *l in memLines) { if (l.length > 0) memCount++; }
        NSDictionary *memAttrs = [[NSFileManager defaultManager]
                                  attributesOfItemAtPath:memPath error:nil];
        unsigned long long memSize = [memAttrs[NSFileSize] unsignedLongLongValue];
        [report appendFormat:@"Memory Log: %ld entries, %.1f KB\n",
         (long)memCount, memSize / 1024.0];
    }

    [report appendString:@"\n=================================\n"];
    return [report copy];
}
