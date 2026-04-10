// helpers.m
// EZCompleteUI v6.0

#import "helpers.h"

static NSString * const kLogFileName           = @"ezui_helpers.log";
static NSString * const kMemoryJSONFileName    = @"ezui_memory.json";
static NSString * const kMemoryLegacyFileName  = @"ezui_memory.log";
static NSString * const kThreadsDirName        = @"EZThreads";
static NSString * const kAttachmentsDirName    = @"EZAttachments";
static NSString * const kHelperModel           = @"gpt-4.1-nano";
static NSString * const kChatCompletionsURL    = @"https://api.openai.com/v1/chat/completions";

static const float kDirectAnswerConfidenceThreshold = 0.85f;
static const NSInteger kTier4MaxTokens = 2000;
static const NSInteger kMemorySearchCandidateLimit = 20;
static const NSInteger kMemorySearchRankerMaxTokens = 1200;

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

@interface EZChatThread ()
+ (nullable instancetype)ez_fromDictionary:(NSDictionary *)dict fallbackThreadID:(NSString * _Nullable)fallbackThreadID;
@end

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
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"threadID"]        = _threadID ?: @"";
    dict[@"title"]           = _title ?: @"";
    dict[@"displayText"]     = _displayText ?: @"";
    dict[@"chatContext"]     = _chatContext ?: @[];
    dict[@"modelName"]       = _modelName ?: @"";
    dict[@"createdAt"]       = _createdAt ?: @"";
    dict[@"updatedAt"]       = _updatedAt ?: @"";
    dict[@"attachmentPaths"] = _attachmentPaths ?: @[];
    if (_lastImageLocalPath.length > 0) dict[@"lastImageLocalPath"] = _lastImageLocalPath;
    if (_lastVideoLocalPath.length > 0) dict[@"lastVideoLocalPath"] = _lastVideoLocalPath;
    return [dict copy];
}

+ (nullable instancetype)fromDictionary:(NSDictionary *)dict {
    return [self ez_fromDictionary:dict fallbackThreadID:nil];
}

+ (nullable instancetype)ez_fromDictionary:(NSDictionary *)dict fallbackThreadID:(NSString * _Nullable)fallbackThreadID {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;

    EZChatThread *thread = [[EZChatThread alloc] init];

    id threadID = dict[@"threadID"] ?: dict[@"threadId"] ?: dict[@"id"];
    if ([threadID isKindOfClass:[NSString class]] && [(NSString *)threadID length] > 0) {
        thread.threadID = threadID;
    } else if (fallbackThreadID.length > 0) {
        thread.threadID = fallbackThreadID;
    }

    id title = dict[@"title"] ?: dict[@"name"];
    if ([title isKindOfClass:[NSString class]] && [(NSString *)title length] > 0) {
        thread.title = title;
    }

    id displayText = dict[@"displayText"] ?: dict[@"preview"] ?: dict[@"subtitle"];
    if ([displayText isKindOfClass:[NSString class]]) {
        thread.displayText = displayText;
    } else {
        thread.displayText = thread.title ?: @"";
    }

    id modelName = dict[@"modelName"] ?: dict[@"model"];
    if ([modelName isKindOfClass:[NSString class]]) {
        thread.modelName = modelName;
    }

    id createdAt = dict[@"createdAt"] ?: dict[@"created_at"] ?: dict[@"timestamp"];
    if ([createdAt isKindOfClass:[NSString class]]) {
        thread.createdAt = createdAt;
    }

    id updatedAt = dict[@"updatedAt"] ?: dict[@"updated_at"] ?: createdAt;
    if ([updatedAt isKindOfClass:[NSString class]]) {
        thread.updatedAt = updatedAt;
    }

    id ctx = dict[@"chatContext"] ?: dict[@"messages"] ?: dict[@"context"];
    if ([ctx isKindOfClass:[NSArray class]]) {
        thread.chatContext = ctx;
    }

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

    id imagePath = dict[@"lastImageLocalPath"] ?: dict[@"lastImagePath"];
    if ([imagePath isKindOfClass:[NSString class]]) thread.lastImageLocalPath = imagePath;

    id videoPath = dict[@"lastVideoLocalPath"] ?: dict[@"lastVideoPath"];
    if ([videoPath isKindOfClass:[NSString class]]) thread.lastVideoLocalPath = videoPath;

    if (thread.threadID.length == 0 && thread.createdAt.length > 0) {
        thread.threadID = thread.createdAt;
    }
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
                    thread.title = text.length > 60 ? [[text substringToIndex:60] stringByAppendingString:@"…"] : text;
                    thread.displayText = thread.title;
                    break;
                }
            }
        }
    }

    if (thread.title.length == 0) thread.title = @"New Conversation";
    if (thread.displayText.length == 0) thread.displayText = thread.title ?: @"";
    if (thread.chatContext == nil) thread.chatContext = @[];
    if (thread.attachmentPaths == nil) thread.attachmentPaths = @[];

    return thread;
}

@end

static NSString *_documentsDirectory(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static NSString *_safeString(id value) {
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : @"";
}

static NSArray *_safeArray(id value) {
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : @[];
}

static NSInteger _estimateTokenCount(NSString *text) {
    return (NSInteger)(text.length / 4) + 1;
}

static NSString *_timestampForDisplay(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [formatter stringFromDate:[NSDate date]];
}

static NSString *_timestampISO8601(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [formatter stringFromDate:[NSDate date]];
}

static NSString *_logLevelString(EZLogLevel level) {
    switch (level) {
        case EZLogLevelDebug:   return @"DEBUG";
        case EZLogLevelInfo:    return @"INFO ";
        case EZLogLevelWarning: return @"WARN ";
        case EZLogLevelError:   return @"ERROR";
    }
    return @"INFO ";
}

static dispatch_queue_t _fileWriteQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ezui.filewrite", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void _appendLineToFile(NSString *filePath, NSString *line) {
    dispatch_async(_fileWriteQueue(), ^{
        NSData *lineData = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:filePath]) {
            [fm createFileAtPath:filePath contents:lineData attributes:nil];
            return;
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:filePath];
        if (!fh) return;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:lineData];
        } @catch (__unused NSException *exception) {
        } @finally {
            [fh closeFile];
        }
    });
}

static NSString *_stripMarkdownFences(NSString *rawResponse) {
    NSString *trimmed = [rawResponse stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed hasPrefix:@"```"]) return trimmed;

    NSRange firstNewline = [trimmed rangeOfString:@"\n"];
    if (firstNewline.location != NSNotFound) {
        trimmed = [trimmed substringFromIndex:firstNewline.location + 1];
    }
    if ([trimmed hasSuffix:@"```"] && trimmed.length >= 3) {
        trimmed = [trimmed substringToIndex:trimmed.length - 3];
    }
    return [trimmed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *_normalizeForSearch(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return @"";
    NSMutableString *result = [NSMutableString stringWithCapacity:text.length];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ([alnum characterIsMember:c]) {
            [result appendFormat:@"%C", (unichar)tolower(c)];
        } else {
            [result appendString:@" "];
        }
    }
    NSArray *parts = [result componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    return [clean componentsJoinedByString:@" "];
}

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
        if (part.length <= 2) continue;
        if ([stopWords containsObject:part]) continue;
        [parts addObject:part];
    }
    return [parts copy];
}

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
                [out appendString:@"[image]"];
            }
        }
        return [out copy];
    }
    return @"";
}

static BOOL _looksLikePathOrIdentifier(NSString *term) {
    return ([term containsString:@"/"] ||
            [term containsString:@"."] ||
            [term containsString:@"_"] ||
            [term containsString:@":"] ||
            [term containsString:@"+"]);
}

static NSString *_callHelperModelSync(NSString *systemPrompt,
                                      NSString *userMessage,
                                      NSString *apiKey,
                                      NSInteger maxTokens) {
    if (apiKey.length == 0) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kChatCompletionsURL]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    NSDictionary *requestBody = @{
        @"model": kHelperModel,
        @"max_tokens": @(maxTokens),
        @"temperature": @0.2,
        @"messages": @[
            @{@"role": @"system", @"content": systemPrompt ?: @""},
            @{@"role": @"user", @"content": userMessage ?: @""}
        ]
    };

    NSError *encodingError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:requestBody options:0 error:&encodingError];
    if (encodingError || !request.HTTPBody) {
        return nil;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData *responseData = nil;
    __block NSError *networkError = nil;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (http && (http.statusCode < 200 || http.statusCode >= 300)) {
            networkError = [NSError errorWithDomain:@"EZHelpersHTTP"
                                               code:http.statusCode
                                           userInfo:nil];
        } else {
            responseData = data;
            networkError = error;
        }
        dispatch_semaphore_signal(semaphore);
    }] resume];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (networkError || responseData.length == 0) return nil;

    NSError *parseError = nil;
    NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&parseError];
    if (parseError || ![jsonResponse isKindOfClass:[NSDictionary class]]) return nil;

    id choices = jsonResponse[@"choices"];
    if (![choices isKindOfClass:[NSArray class]] || [(NSArray *)choices count] == 0) return nil;

    id firstChoice = ((NSArray *)choices)[0];
    if (![firstChoice isKindOfClass:[NSDictionary class]]) return nil;

    id message = ((NSDictionary *)firstChoice)[@"message"];
    if (![message isKindOfClass:[NSDictionary class]]) return nil;

    id content = ((NSDictionary *)message)[@"content"];
    if (![content isKindOfClass:[NSString class]]) return nil;

    return [(NSString *)content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSString *EZLogGetPath(void) {
    return [_documentsDirectory() stringByAppendingPathComponent:kLogFileName];
}

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

void EZLogRotateIfNeeded(NSUInteger maxSizeBytes) {
    NSString *logPath = EZLogGetPath();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:logPath error:nil];
    NSUInteger size = (NSUInteger)[attrs[NSFileSize] unsignedLongLongValue];
    if (size < maxSizeBytes || size == 0) return;

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *archiveName = [NSString stringWithFormat:@"ezui_helpers_%@.log", [formatter stringFromDate:[NSDate date]]];
    NSString *archivePath = [_documentsDirectory() stringByAppendingPathComponent:archiveName];
    [[NSFileManager defaultManager] moveItemAtPath:logPath toPath:archivePath error:nil];
    EZLog(EZLogLevelInfo, @"LOG", [NSString stringWithFormat:@"Rotated to %@", archiveName]);
}

NSString *EZMemoryGetPath(void) {
    return [_documentsDirectory() stringByAppendingPathComponent:kMemoryJSONFileName];
}

static NSString *_legacyMemoryLogPath(void) {
    return [_documentsDirectory() stringByAppendingPathComponent:kMemoryLegacyFileName];
}

static void _migrateMemoryIfNeeded(void) {
    NSString *jsonPath = EZMemoryGetPath();
    NSString *legacyPath = _legacyMemoryLogPath();

    if ([[NSFileManager defaultManager] fileExistsAtPath:jsonPath]) return;
    if (![[NSFileManager defaultManager] fileExistsAtPath:legacyPath]) return;

    NSError *readError = nil;
    NSString *legacyContent = [NSString stringWithContentsOfFile:legacyPath encoding:NSUTF8StringEncoding error:&readError];
    if (readError || legacyContent.length == 0) return;

    NSMutableArray *migratedEntries = [NSMutableArray array];
    for (NSString *line in [legacyContent componentsSeparatedByString:@"\n"]) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmedLine.length == 0) continue;

        NSString *timestamp = @"";
        NSString *chatKey = @"";
        NSString *summary = trimmedLine;

        NSRange tsStart = [trimmedLine rangeOfString:@"["];
        NSRange tsEnd = [trimmedLine rangeOfString:@"]"];
        if (tsStart.location == 0 && tsEnd.location != NSNotFound && tsEnd.location > 1) {
            timestamp = [trimmedLine substringWithRange:NSMakeRange(1, tsEnd.location - 1)];
            summary = [[trimmedLine substringFromIndex:tsEnd.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }

        NSRange ckRange = [summary rangeOfString:@"[chatKey="];
        if (ckRange.location != NSNotFound) {
            NSRange ckEnd = [summary rangeOfString:@"]" options:0 range:NSMakeRange(ckRange.location, summary.length - ckRange.location)];
            if (ckEnd.location != NSNotFound && ckEnd.location > ckRange.location + 8) {
                NSRange valueRange = NSMakeRange(ckRange.location + 8, ckEnd.location - ckRange.location - 8);
                chatKey = [summary substringWithRange:valueRange];
                NSString *beforeTag = [summary substringToIndex:ckRange.location];
                NSString *afterTag = [summary substringFromIndex:ckEnd.location + 1];
                summary = [[beforeTag stringByAppendingString:afterTag] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
        }

        if (summary.length > 0) {
            [migratedEntries addObject:@{
                @"timestamp": timestamp ?: @"",
                @"summary": summary ?: @"",
                @"chatKey": chatKey ?: @""
            }];
        }
    }

    if (migratedEntries.count == 0) return;

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:migratedEntries options:NSJSONWritingPrettyPrinted error:nil];
    if (!jsonData) return;
    [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:nil];
    EZLogf(EZLogLevelInfo, @"MEMORY", @"Migrated %lu legacy entries to JSON store", (unsigned long)migratedEntries.count);
}

static NSMutableArray<NSDictionary *> *_loadMemoryEntries(void) {
    _migrateMemoryIfNeeded();

    NSData *fileData = [NSData dataWithContentsOfFile:EZMemoryGetPath() options:0 error:nil];
    if (!fileData) return [NSMutableArray array];

    id parsed = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:nil];
    if (![parsed isKindOfClass:[NSArray class]]) return [NSMutableArray array];

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (id obj in (NSArray *)parsed) {
        if ([obj isKindOfClass:[NSDictionary class]]) {
            [out addObject:obj];
        }
    }
    return out;
}

static void _saveMemoryEntries(NSArray<NSDictionary *> *entries) {
    NSError *serializeError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:entries options:NSJSONWritingPrettyPrinted error:&serializeError];
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

NSArray<NSDictionary *> *EZMemoryLoadAll(void) {
    return _loadMemoryEntries();
}

NSString *loadMemoryContext(NSInteger maxEntries) {
    NSArray<NSDictionary *> *allEntries = _loadMemoryEntries();
    if (allEntries.count == 0) return @"";

    NSArray<NSDictionary *> *entriesToReturn = allEntries;
    if (maxEntries > 0 && (NSInteger)allEntries.count > maxEntries) {
        NSRange range = NSMakeRange(allEntries.count - (NSUInteger)maxEntries, (NSUInteger)maxEntries);
        entriesToReturn = [allEntries subarrayWithRange:range];
    }

    NSMutableArray<NSString *> *formattedLines = [NSMutableArray array];
    for (NSDictionary *entry in entriesToReturn) {
        NSString *timestamp = _safeString(entry[@"timestamp"]);
        NSString *summary = _safeString(entry[@"summary"]);
        NSString *chatKey = _safeString(entry[@"chatKey"]);
        NSArray *attachments = _safeArray(entry[@"attachmentPaths"]);

        NSString *keyTag = chatKey.length > 0 ? [NSString stringWithFormat:@" [chatKey=%@]", chatKey] : @"";
        NSMutableString *attachTag = [NSMutableString string];
        for (id obj in attachments) {
            NSString *path = _safeString(obj);
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
    NSError *error = nil;
    BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:EZMemoryGetPath() error:&error];
    if (!removed && error) {
        EZLogf(EZLogLevelError, @"MEMORY", @"Clear failed: %@", error);
    } else if (removed) {
        EZLog(EZLogLevelInfo, @"MEMORY", @"Memory store cleared.");
    }
    return removed;
}

static NSInteger _memoryEntryLocalScore(NSDictionary *entry, NSString *query) {
    NSString *summary = _safeString(entry[@"summary"]);
    NSString *chatKey = _safeString(entry[@"chatKey"]);
    NSArray *attachments = _safeArray(entry[@"attachmentPaths"]);
    NSArray<NSString *> *terms = _searchTerms(query);
    NSString *normalizedSummary = _normalizeForSearch(summary);
    NSInteger score = 0;

    for (NSString *term in terms) {
        if ([normalizedSummary containsString:term]) score += 8;
        if (_looksLikePathOrIdentifier(term) && [summary.lowercaseString containsString:term.lowercaseString]) score += 12;
        if ([chatKey.lowercaseString containsString:term.lowercaseString]) score += 6;
        for (id obj in attachments) {
            NSString *path = _safeString(obj);
            if (path.length == 0) continue;
            if ([path.lowercaseString containsString:term.lowercaseString]) score += 15;
            if ([path.lastPathComponent.lowercaseString isEqualToString:term.lowercaseString]) score += 25;
        }
    }

    if (attachments.count > 0) score += 2;
    return score;
}

NSString *EZThreadSearchMemory(NSString *searchQuery, NSString *apiKey) {
    NSArray<NSDictionary *> *allEntries = _loadMemoryEntries();
    if (allEntries.count == 0) {
        EZLog(EZLogLevelInfo, @"MEMORY", @"Search: memory store is empty");
        return @"";
    }

    if (apiKey.length == 0) {
        return loadMemoryContext(5);
    }

    NSMutableArray<NSDictionary *> *scoredEntries = [NSMutableArray array];
    for (NSDictionary *entry in allEntries) {
        NSInteger score = _memoryEntryLocalScore(entry, searchQuery ?: @"");
        [scoredEntries addObject:@{
            @"entry": entry,
            @"score": @(score)
        }];
    }

    [scoredEntries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger scoreA = [a[@"score"] integerValue];
        NSInteger scoreB = [b[@"score"] integerValue];
        if (scoreA != scoreB) return scoreB > scoreA ? NSOrderedDescending : NSOrderedAscending;
        NSUInteger indexA = [allEntries indexOfObject:a[@"entry"]];
        NSUInteger indexB = [allEntries indexOfObject:b[@"entry"]];
        if (indexA == indexB) return NSOrderedSame;
        return indexB > indexA ? NSOrderedDescending : NSOrderedAscending;
    }];

    NSInteger candidateCount = MIN(kMemorySearchCandidateLimit, (NSInteger)scoredEntries.count);
    NSArray *topCandidates = [scoredEntries subarrayWithRange:NSMakeRange(0, (NSUInteger)candidateCount)];

    BOOL anyPositive = NO;
    for (NSDictionary *scored in topCandidates) {
        if ([scored[@"score"] integerValue] > 0) {
            anyPositive = YES;
            break;
        }
    }
    if (!anyPositive) {
        EZLog(EZLogLevelInfo, @"MEMORY", @"Search: no keyword overlap found — returning 5 most recent entries");
        return loadMemoryContext(5);
    }

    NSMutableArray<NSString *> *candidateLines = [NSMutableArray array];
    for (NSDictionary *scored in topCandidates) {
        NSDictionary *entry = scored[@"entry"];
        NSString *timestamp = _safeString(entry[@"timestamp"]);
        NSString *summary = _safeString(entry[@"summary"]);
        NSString *chatKey = _safeString(entry[@"chatKey"]);
        NSArray *attachments = _safeArray(entry[@"attachmentPaths"]);

        NSString *keyTag = chatKey.length > 0 ? [NSString stringWithFormat:@" [chatKey=%@]", chatKey] : @"";
        NSMutableString *attachTag = [NSMutableString string];
        for (id obj in attachments) {
            NSString *path = _safeString(obj);
            if (path.length > 0) {
                [attachTag appendFormat:@" [file:%@ path=%@]", path.lastPathComponent, path];
            }
        }

        [candidateLines addObject:[NSString stringWithFormat:@"[%@]%@%@ %@",
                                   timestamp, keyTag, attachTag, summary]];
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

    NSString *rankerUserMessage = [NSString stringWithFormat:@"Search query: \"%@\"\n\nMemory entries to rank:\n%@",
                                   searchQuery ?: @"", candidatesText];

    NSString *rankerResponse = _callHelperModelSync(rankerSystemPrompt,
                                                    rankerUserMessage,
                                                    apiKey,
                                                    kMemorySearchRankerMaxTokens);
    NSString *trimmed = [rankerResponse stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        EZLog(EZLogLevelWarning, @"MEMORY", @"Stage 2 ranker failed — using Stage 1 keyword results");
        NSInteger fallbackCount = MIN(3, (NSInteger)candidateLines.count);
        return [[candidateLines subarrayWithRange:NSMakeRange(0, (NSUInteger)fallbackCount)] componentsJoinedByString:@"\n"];
    }
    if ([trimmed isEqualToString:@"0"]) {
        EZLog(EZLogLevelInfo, @"MEMORY", @"Stage 2 ranker found no relevant entries");
        return @"";
    }

    return trimmed;
}

NSString *EZThreadStoreDir(void) {
    NSString *threadsDirectory = [_documentsDirectory() stringByAppendingPathComponent:kThreadsDirName];
    [[NSFileManager defaultManager] createDirectoryAtPath:threadsDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return threadsDirectory;
}

static NSString *_threadFilePath(NSString *threadID) {
    NSString *safeFileName = [[threadID stringByReplacingOccurrencesOfString:@":" withString:@"-"]
                              stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    return [[EZThreadStoreDir() stringByAppendingPathComponent:safeFileName] stringByAppendingPathExtension:@"json"];
}

static NSString *_threadStemFromPath(NSString *path) {
    return [[path lastPathComponent] stringByDeletingPathExtension];
}

void EZThreadSave(EZChatThread *thread, void (^ _Nullable completionCallback)(BOOL success)) {
    if (!thread || thread.threadID.length == 0) {
        EZLog(EZLogLevelWarning, @"THREADS", @"Save called with nil/empty thread — ignoring");
        if (completionCallback) dispatch_async(dispatch_get_main_queue(), ^{ completionCallback(NO); });
        return;
    }

    thread.updatedAt = _timestampISO8601();
    if (thread.createdAt.length == 0) thread.createdAt = thread.updatedAt;
    if (thread.title.length == 0) thread.title = @"New Conversation";
    if (thread.displayText.length == 0) thread.displayText = thread.title;

    NSDictionary *threadDict = [thread toDictionary];
    NSString *filePath = _threadFilePath(thread.threadID);

    dispatch_async(_fileWriteQueue(), ^{
        NSError *serializeError = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:threadDict options:NSJSONWritingPrettyPrinted error:&serializeError];
        BOOL success = NO;
        if (!serializeError && jsonData) {
            NSError *writeError = nil;
            success = [jsonData writeToFile:filePath options:NSDataWritingAtomic error:&writeError];
            if (!success) {
                EZLogf(EZLogLevelError, @"THREADS", @"Write failed: %@", writeError);
            }
        } else {
            EZLogf(EZLogLevelError, @"THREADS", @"Serialize failed: %@", serializeError);
        }
        if (success) EZLogf(EZLogLevelInfo, @"THREADS", @"Saved: %@", thread.threadID);
        if (completionCallback) dispatch_async(dispatch_get_main_queue(), ^{ completionCallback(success); });
    });
}

EZChatThread * _Nullable EZThreadLoad(NSString *threadID) {
    if (threadID.length == 0) return nil;

    NSString *path = _threadFilePath(threadID);
    NSData *fileData = [NSData dataWithContentsOfFile:path options:0 error:nil];
    if (!fileData) {
        EZLogf(EZLogLevelWarning, @"THREADS", @"Thread not found: %@", threadID);
        return nil;
    }

    id parsedJSON = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:nil];
    if (![parsedJSON isKindOfClass:[NSDictionary class]]) {
        EZLogf(EZLogLevelError, @"THREADS", @"Parse error for %@", threadID);
        return nil;
    }

    EZChatThread *thread = [EZChatThread ez_fromDictionary:(NSDictionary *)parsedJSON fallbackThreadID:threadID];
    if (!thread) {
        EZLogf(EZLogLevelError, @"THREADS", @"Thread decode failed for %@", threadID);
    }
    return thread;
}

NSArray<EZChatThread *> *EZThreadList(void) {
    NSString *threadsDirectory = EZThreadStoreDir();
    NSArray<NSString *> *fileNames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:threadsDirectory error:nil];
    if (fileNames.count == 0) return @[];

    NSMutableArray<EZChatThread *> *threads = [NSMutableArray array];
    for (NSString *fileName in fileNames) {
        if (![fileName hasSuffix:@".json"]) continue;

        NSString *fullPath = [threadsDirectory stringByAppendingPathComponent:fileName];
        NSData *fileData = [NSData dataWithContentsOfFile:fullPath];
        if (!fileData) continue;

        id parsedJSON = [NSJSONSerialization JSONObjectWithData:fileData options:0 error:nil];
        if (![parsedJSON isKindOfClass:[NSDictionary class]]) continue;

        NSString *fallbackThreadID = _threadStemFromPath(fullPath);
        EZChatThread *thread = [EZChatThread ez_fromDictionary:(NSDictionary *)parsedJSON fallbackThreadID:fallbackThreadID];
        if (thread.threadID.length > 0) {
            [threads addObject:thread];
        }
    }

    [threads sortUsingComparator:^NSComparisonResult(EZChatThread *a, EZChatThread *b) {
        NSString *updatedA = a.updatedAt ?: @"";
        NSString *updatedB = b.updatedAt ?: @"";
        return [updatedB compare:updatedA];
    }];

    return [threads copy];
}

BOOL EZThreadDelete(NSString *threadID) {
    NSError *deleteError = nil;
    BOOL deleted = [[NSFileManager defaultManager] removeItemAtPath:_threadFilePath(threadID) error:&deleteError];
    if (deleted) {
        EZLogf(EZLogLevelInfo, @"THREADS", @"Deleted: %@", threadID);
    } else {
        EZLogf(EZLogLevelError, @"THREADS", @"Delete failed for %@: %@", threadID, deleteError);
    }
    return deleted;
}

static NSInteger _turnLength(NSDictionary *turn) {
    return _messageTextFromContent(turn[@"content"]).length;
}

static BOOL _turnHasAttachmentSignal(NSDictionary *turn) {
    id content = turn[@"content"];
    if ([content isKindOfClass:[NSArray class]]) {
        for (id block in (NSArray *)content) {
            if (![block isKindOfClass:[NSDictionary class]]) continue;
            NSString *type = _safeString(((NSDictionary *)block)[@"type"]);
            if ([type containsString:@"image"]) return YES;
        }
    }
    NSString *lower = _messageTextFromContent(content).lowercaseString;
    return [lower containsString:@"attached"] ||
           [lower containsString:@"resume"] ||
           [lower containsString:@"document"] ||
           [lower containsString:@"pdf"] ||
           [lower containsString:@"image"] ||
           [lower containsString:@"generated"] ||
           [lower containsString:@"edited"] ||
           [lower containsString:@"file"] ||
           [lower containsString:@"epub"] ||
           [lower containsString:@"transcript"] ||
           [lower containsString:@"video"] ||
           [lower containsString:@"patch"];
}

static NSInteger _turnQueryScore(NSDictionary *turn, NSString *query) {
    NSString *text = _messageTextFromContent(turn[@"content"]);
    NSString *normalized = _normalizeForSearch(text);
    NSArray<NSString *> *terms = _searchTerms(query);
    NSInteger score = 0;

    for (NSString *term in terms) {
        if ([normalized containsString:term]) score += 10;
        if (_looksLikePathOrIdentifier(term) && [text.lowercaseString containsString:term.lowercaseString]) score += 18;
    }

    NSString *role = _safeString(turn[@"role"]);
    if ([role isEqualToString:@"assistant"]) score += 6;
    if (_turnHasAttachmentSignal(turn)) score += 8;
    if (text.length > 120) score += 3;

    if ([query.lowercaseString isEqualToString:@"try again"] ||
        [query.lowercaseString isEqualToString:@"that one"] ||
        [query.lowercaseString isEqualToString:@"the code"] ||
        [query.lowercaseString isEqualToString:@"the file"]) {
        score += 2;
    }

    return score;
}

static NSArray<NSDictionary *> *_bestTurnWindowForQuery(EZChatThread *thread, NSString *query, NSInteger tokenBudget) {
    if (!thread || thread.chatContext.count == 0) return nil;
    NSArray<NSDictionary *> *turns = thread.chatContext;
    NSInteger bestIndex = NSNotFound;
    NSInteger bestScore = 0;

    for (NSInteger i = 0; i < (NSInteger)turns.count; i++) {
        NSDictionary *turn = turns[(NSUInteger)i];
        if (![turn isKindOfClass:[NSDictionary class]]) continue;
        NSInteger score = _turnQueryScore(turn, query ?: @"");
        if (score > bestScore) {
            bestScore = score;
            bestIndex = i;
        }
    }

    if (bestIndex == NSNotFound || bestScore <= 0) return nil;

    NSInteger charBudget = tokenBudget * 4;
    NSInteger start = MAX(0, bestIndex - 2);
    NSInteger end = MIN((NSInteger)turns.count - 1, bestIndex + 2);
    NSMutableArray<NSDictionary *> *window = [NSMutableArray array];
    NSInteger used = 0;

    for (NSInteger i = start; i <= end; i++) {
        NSDictionary *turn = turns[(NSUInteger)i];
        NSInteger len = _turnLength(turn);
        if (window.count > 0 && used + len > charBudget) break;
        [window addObject:turn];
        used += len;
    }

    return window.count > 0 ? [window copy] : nil;
}

NSArray<NSDictionary *> * _Nullable EZThreadLoadContext(NSString *threadID, NSInteger tokenBudget) {
    EZChatThread *thread = EZThreadLoad(threadID);
    if (!thread || thread.chatContext.count == 0) return nil;

    NSInteger characterBudget = tokenBudget * 4;
    NSArray<NSDictionary *> *allTurns = thread.chatContext;
    NSUInteger totalTurns = allTurns.count;

    NSInteger recentTurnCount = MIN(4, (NSInteger)totalTurns);
    NSMutableSet<NSNumber *> *includedIndices = [NSMutableSet set];
    NSInteger budgetUsed = 0;

    for (NSInteger i = (NSInteger)totalTurns - 1; i >= (NSInteger)totalTurns - recentTurnCount; i--) {
        [includedIndices addObject:@(i)];
        budgetUsed += _turnLength(allTurns[(NSUInteger)i]);
    }

    NSMutableArray<NSDictionary *> *scoredTurns = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)totalTurns - recentTurnCount; i++) {
        NSDictionary *turn = allTurns[(NSUInteger)i];
        NSString *role = _safeString(turn[@"role"]);
        NSInteger length = _turnLength(turn);
        BOOL hasAttachment = _turnHasAttachmentSignal(turn);

        BOOL isAssistant = [role isEqualToString:@"assistant"];
        BOOL isSubstantial = length > 100 || hasAttachment;
        if (!isAssistant && !isSubstantial) continue;

        NSInteger score = length;
        if (hasAttachment) score += 500;
        if (isAssistant) score += 200;

        [scoredTurns addObject:@{@"index": @(i), @"score": @(score), @"length": @(length)}];
    }

    [scoredTurns sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"score"] compare:a[@"score"]];
    }];

    for (NSDictionary *scored in scoredTurns) {
        NSInteger idx = [scored[@"index"] integerValue];
        NSInteger length = [scored[@"length"] integerValue];
        if ([includedIndices containsObject:@(idx)]) continue;
        if (budgetUsed + length > characterBudget) continue;
        [includedIndices addObject:@(idx)];
        budgetUsed += length;
        if (budgetUsed >= characterBudget) break;
    }

    NSArray<NSNumber *> *sortedIndices = [[includedIndices allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSDictionary *> *selectedTurns = [NSMutableArray array];
    for (NSNumber *idx in sortedIndices) {
        [selectedTurns addObject:allTurns[(NSUInteger)idx.integerValue]];
    }

    EZLogf(EZLogLevelInfo, @"THREADS", @"LoadContext: %lu/%lu turns selected from thread %@ (~%ld tokens)",
           (unsigned long)selectedTurns.count, (unsigned long)totalTurns, threadID, (long)(budgetUsed / 4));
    return selectedTurns.count > 0 ? [selectedTurns copy] : nil;
}

static NSString *_bestChatKeyFromMemoryContext(NSString *memoryContext, NSString *query) {
    if (memoryContext.length == 0) return @"";

    NSArray<NSString *> *lines = [memoryContext componentsSeparatedByString:@"\n"];
    NSArray<NSString *> *terms = _searchTerms(query);
    NSString *bestKey = @"";
    NSInteger bestScore = 0;

    for (NSString *line in lines) {
        NSRange keyStart = [line rangeOfString:@"[chatKey="];
        if (keyStart.location == NSNotFound) continue;

        NSRange keyEnd = [line rangeOfString:@"]" options:0 range:NSMakeRange(keyStart.location, line.length - keyStart.location)];
        if (keyEnd.location == NSNotFound || keyEnd.location <= keyStart.location + 9) continue;

        NSString *key = [line substringWithRange:NSMakeRange(keyStart.location + 9, keyEnd.location - keyStart.location - 9)];
        NSInteger score = 0;
        NSString *lower = line.lowercaseString;
        for (NSString *term in terms) {
            if ([lower containsString:term.lowercaseString]) score += 4;
        }
        if (score > bestScore) {
            bestScore = score;
            bestKey = key;
        }
    }

    return bestKey;
}

static NSString *_validatedThreadID(NSString *candidate, NSString *fallback) {
    if (candidate.length > 0 && EZThreadLoad(candidate) != nil) return candidate;
    if (fallback.length > 0 && EZThreadLoad(fallback) != nil) return fallback;
    return @"";
}

void analyzePromptForContext(NSString *userPrompt,
                             NSString * _Nullable memoryContext,
                             NSString *apiKey,
                             NSString * _Nullable chatKey,
                             void (^completion)(EZContextResult *result)) {
    NSCParameterAssert(userPrompt);
    NSCParameterAssert(apiKey);
    NSCParameterAssert(completion);
    EZLog(EZLogLevelInfo, @"CONTEXT", @"Analyzing (4-tier)...");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *memoryContextForClassifier = memoryContext.length > 0 ? memoryContext : @"(none)";
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

        NSString *rawResponse = _callHelperModelSync(systemPrompt, userMessage, apiKey, 400);

        EZContextResult *result = [[EZContextResult alloc] init];
        result.finalPrompt = userPrompt;
        result.estimatedTokens = _estimateTokenCount(userPrompt);

        if (!rawResponse) {
            result.tier = EZRoutingTierSimple;
            result.needsContext = NO;
            result.reason = @"Classifier unavailable — defaulting to Tier 2";
            result.confidence = 0.5f;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        NSError *jsonParseError = nil;
        NSDictionary *classifierResult = [NSJSONSerialization JSONObjectWithData:[_stripMarkdownFences(rawResponse) dataUsingEncoding:NSUTF8StringEncoding]
                                                                         options:0
                                                                           error:&jsonParseError];
        if (jsonParseError || ![classifierResult isKindOfClass:[NSDictionary class]]) {
            result.tier = EZRoutingTierSimple;
            result.needsContext = NO;
            result.reason = @"JSON parse error — defaulting to Tier 2";
            result.confidence = 0.5f;
            EZLogf(EZLogLevelWarning, @"CONTEXT", @"Parse failed. Raw response: %@", rawResponse);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        NSString *classification = _safeString(classifierResult[@"classification"]);
        if (classification.length == 0) classification = @"COMPLEX";
        float confidence = [classifierResult[@"confidence"] respondsToSelector:@selector(floatValue)] ? [classifierResult[@"confidence"] floatValue] : 0.5f;
        NSString *reason = _safeString(classifierResult[@"reason"]);
        BOOL memorySufficient = [classifierResult[@"memory_sufficient"] respondsToSelector:@selector(boolValue)] ? [classifierResult[@"memory_sufficient"] boolValue] : NO;
        NSString *directAnswer = [classifierResult[@"direct_answer"] isKindOfClass:[NSString class]] ? classifierResult[@"direct_answer"] : nil;
        NSString *modelChatKey = [classifierResult[@"chat_key"] isKindOfClass:[NSString class]] ? classifierResult[@"chat_key"] : @"";

        NSString *memoryChatKey = _bestChatKeyFromMemoryContext(memoryContext ?: @"", userPrompt ?: @"");
        NSString *resolvedChatKey = _validatedThreadID(modelChatKey, @"");
        if (resolvedChatKey.length == 0) resolvedChatKey = _validatedThreadID(memoryChatKey, @"");
        if (resolvedChatKey.length == 0) resolvedChatKey = _validatedThreadID(chatKey ?: @"", @"");

        result.confidence = confidence;
        result.reason = reason;

        if ([classification isEqualToString:@"SIMPLE"] &&
            confidence >= kDirectAnswerConfidenceThreshold &&
            directAnswer.length > 0) {
            result.tier = EZRoutingTierDirect;
            result.needsContext = NO;
            result.shortCircuitAnswer = directAnswer;
            result.estimatedTokens = _estimateTokenCount(directAnswer);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        if ([classification isEqualToString:@"COMPLEX"] || [classification isEqualToString:@"SIMPLE"]) {
            result.tier = EZRoutingTierSimple;
            result.needsContext = NO;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        BOOL isContextClassification = ([classification isEqualToString:@"NEEDS_CONTEXT"] ||
                                        [classification isEqualToString:@"NEEDS_HISTORY"]);

        if (isContextClassification && memorySufficient && memoryContext.length > 0) {
            NSString *enrichedPrompt = [NSString stringWithFormat:
                                        @"[Memories with possible relevance:]\n%@\n\n[User message]\n%@",
                                        memoryContext, userPrompt];
            result.tier = EZRoutingTierMemory;
            result.needsContext = YES;
            result.finalPrompt = enrichedPrompt;
            result.estimatedTokens = _estimateTokenCount(enrichedPrompt);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
            return;
        }

        if ([classification isEqualToString:@"NEEDS_HISTORY"] && resolvedChatKey.length > 0) {
            EZChatThread *thread = EZThreadLoad(resolvedChatKey);
            NSArray<NSDictionary *> *exactWindow = _bestTurnWindowForQuery(thread, userPrompt, kTier4MaxTokens);
            if (exactWindow.count > 0) {
                result.tier = EZRoutingTierFullHistory;
                result.needsContext = YES;
                result.finalPrompt = userPrompt;
                result.injectedHistory = exactWindow;
                NSInteger usedChars = 0;
                for (NSDictionary *turn in exactWindow) usedChars += _turnLength(turn);
                result.estimatedTokens = MAX(1, usedChars / 4);
                EZLogf(EZLogLevelInfo, @"CONTEXT", @"Tier 4 exact-turn window — %lu turns from thread %@", (unsigned long)exactWindow.count, resolvedChatKey);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
                return;
            }

            NSArray<NSDictionary *> *conversationTurns = EZThreadLoadContext(resolvedChatKey, kTier4MaxTokens);
            if (conversationTurns.count > 0) {
                result.tier = EZRoutingTierFullThread;
                result.needsContext = YES;
                result.finalPrompt = userPrompt;
                result.injectedHistory = conversationTurns;
                result.estimatedTokens = kTier4MaxTokens;
                dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
                return;
            }

            EZLogf(EZLogLevelWarning, @"CONTEXT", @"Tier 4 thread not found or empty (%@) — falling back to memory", resolvedChatKey);
        }

        if (memoryContext.length > 0) {
            NSString *enrichedPrompt = [NSString stringWithFormat:
                                        @"[Memories with possible relevance: ]\n%@\n\n[User message]\n%@",
                                        memoryContext, userPrompt];
            result.tier = EZRoutingTierMemory;
            result.needsContext = YES;
            result.finalPrompt = enrichedPrompt;
            result.estimatedTokens = _estimateTokenCount(enrichedPrompt);
        } else {
            result.tier = EZRoutingTierSimple;
            result.needsContext = NO;
        }

        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}

void createMemoryFromCompletion(NSString *userPrompt,
                                NSString *assistantReply,
                                NSString *apiKey,
                                NSString * _Nullable chatKey,
                                NSArray<NSString *> * _Nullable attachmentPaths,
                                void (^completion)(NSString * _Nullable entry)) {
    NSCParameterAssert(userPrompt);
    NSCParameterAssert(assistantReply);
    NSCParameterAssert(apiKey);

    EZLog(EZLogLevelInfo, @"MEMORY", @"Creating summary...");

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSMutableString *attachmentContext = [NSMutableString string];
        NSMutableArray<NSString *> *validPaths = [NSMutableArray array];

        for (id obj in attachmentPaths) {
            NSString *path = _safeString(obj);
            if (path.length == 0) continue;
            [validPaths addObject:path];
            [attachmentContext appendFormat:@" [file: %@ full_path=%@]", path.lastPathComponent, path];
        }

        NSString *systemPrompt =
            @"You are a memory indexer for an AI chat app. Write ONE factual sentence "
            @"describing exactly what was asked and answered. Rules:\n"
            @"1. Keep the SAME specific words, names, file names, paths, and technical terms — do NOT paraphrase or generalize.\n"
            @"2. If a file path is provided (full_path=...) include the COMPLETE path verbatim in the summary.\n"
            @"3. If an image was generated or edited, include the output filename and full path.\n"
            @"4. Never say 'the user expressed frustration' — say what they actually asked.\n"
            @"5. Never say 'the assistant explained it cannot...' — say what the assistant actually did or provided.\n"
            @"6. Be specific: 'user asked for lyrics to Give Me Love by Ed Sheeran' not 'user asked about a song'.\n"
            @"7. When files are involved, LIST EACH filename explicitly — never say 'multiple files' or 'several .m files'.\n\n"
            @"GOOD EXAMPLE:\n"
            @"Input: User asked about duplicate methods ezcui_resolvedTopTitle and ezcui_beginLongOperation "
            @"in ViewController+EZTopButtons.m, ViewController+EZTitleResolver.m, and ViewController+EZKeepAwake.m. "
            @"[file: ViewController+EZTopButtons.m full_path=/var/mobile/Containers/.../ViewController+EZTopButtons.m]\n"
            @"Output: User asked about duplicate category methods ezcui_resolvedTopTitle and ezcui_beginLongOperation "
            @"found in ViewController+EZTopButtons.m, ViewController+EZTitleResolver.m, and ViewController+EZKeepAwake.m "
            @"and sought grep commands to identify and consolidate them; "
            @"full path: /var/mobile/Containers/.../ViewController+EZTopButtons.m\n\n"
            @"BAD EXAMPLE:\n"
            @"Input: (same as above)\n"
            @"Output: User asked about duplicate category methods in multiple .m files and sought steps to fix them.\n"
            @"(BAD: 'multiple .m files' is a generalization — list each filename explicitly)\n\n"
            @"Only the summary sentence, no labels or preamble.";

        NSString *truncatedReply = assistantReply.length > 1200 ? [assistantReply substringToIndex:1200] : assistantReply;
        NSString *contentToSummarize = [NSString stringWithFormat:
                                        @"USER ASKED:\n%@%@\n\nASSISTANT REPLIED:\n%@",
                                        userPrompt,
                                        attachmentContext.length > 0 ? [NSString stringWithFormat:@"\nAttachments: %@", attachmentContext] : @"",
                                        truncatedReply];

        NSString *summary = _callHelperModelSync(systemPrompt, contentToSummarize, apiKey, 150);
        if (summary.length == 0) {
            EZLog(EZLogLevelWarning, @"MEMORY", @"Summarizer returned empty — skipping save");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }

        NSMutableDictionary *newEntry = [NSMutableDictionary dictionaryWithDictionary:@{
            @"timestamp": _timestampForDisplay(),
            @"summary": summary,
            @"chatKey": chatKey ?: @""
        }];
        if (validPaths.count > 0) newEntry[@"attachmentPaths"] = [validPaths copy];

        dispatch_sync(_fileWriteQueue(), ^{
            NSMutableArray *allEntries = _loadMemoryEntries();
            [allEntries addObject:[newEntry copy]];
            _saveMemoryEntries(allEntries);
        });

        NSString *formattedEntry = [NSString stringWithFormat:@"[%@] [chatKey=%@]%@ %@",
                                    newEntry[@"timestamp"], newEntry[@"chatKey"], attachmentContext, summary];
        EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved: %@", formattedEntry);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(formattedEntry); });
    });
}

static NSString *_attachmentDirectory(void) {
    NSString *directory = [_documentsDirectory() stringByAppendingPathComponent:kAttachmentsDirName];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return directory;
}

NSString * _Nullable EZAttachmentSave(NSData *data, NSString *fileName) {
    if (!data || fileName.length == 0) return nil;

    NSString *uniqueFileName = [NSString stringWithFormat:@"%@_%@", [[NSUUID UUID] UUIDString], fileName];
    NSString *filePath = [_attachmentDirectory() stringByAppendingPathComponent:uniqueFileName];

    NSError *writeError = nil;
    BOOL saved = [data writeToFile:filePath options:NSDataWritingAtomic error:&writeError];
    if (!saved) {
        EZLogf(EZLogLevelError, @"ATTACH", @"Save failed for %@: %@", fileName, writeError);
        return nil;
    }

    EZLogf(EZLogLevelInfo, @"ATTACH", @"Saved: %@", uniqueFileName);
    return filePath;
}

NSString * _Nullable EZAttachmentPath(NSString *savedFileName) {
    if (savedFileName.length == 0) return nil;
    NSString *filePath = [_attachmentDirectory() stringByAppendingPathComponent:savedFileName];
    return [[NSFileManager defaultManager] fileExistsAtPath:filePath] ? filePath : nil;
}

NSString * _Nullable EZCallHelperModel(NSString *systemPrompt,
                                       NSString *userMessage,
                                       NSString *apiKey,
                                       NSInteger maxTokens) {
    return _callHelperModelSync(systemPrompt, userMessage, apiKey, maxTokens);
}

NSString *EZHelperStats(void) {
    NSMutableString *report = [NSMutableString stringWithString:@"=== EZCompleteUI Stats ===\n\n"];

    NSString *logContent = [NSString stringWithContentsOfFile:EZLogGetPath() encoding:NSUTF8StringEncoding error:nil];
    if (!logContent) {
        [report appendString:@"No log file found.\n"];
    } else {
        NSInteger debugCount = 0, infoCount = 0, warnCount = 0, errorCount = 0;
        NSInteger tier1 = 0, tier2 = 0, tier3 = 0, tier4 = 0;
        NSMutableArray *last5Lines = [NSMutableArray array];

        for (NSString *line in [logContent componentsSeparatedByString:@"\n"]) {
            if (line.length == 0) continue;
            if ([line containsString:@"DEBUG"]) debugCount++;
            if ([line containsString:@"INFO "]) infoCount++;
            if ([line containsString:@"WARN "]) warnCount++;
            if ([line containsString:@"ERROR"]) errorCount++;
            if ([line containsString:@"Tier 1"]) tier1++;
            if ([line containsString:@"Tier 2"]) tier2++;
            if ([line containsString:@"Tier 3"]) tier3++;
            if ([line containsString:@"Tier 4"]) tier4++;
            [last5Lines addObject:line];
            if (last5Lines.count > 5) [last5Lines removeObjectAtIndex:0];
        }

        NSDictionary *logAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:EZLogGetPath() error:nil];
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

    NSArray<NSDictionary *> *memoryEntries = EZMemoryLoadAll();
    if (memoryEntries.count == 0) {
        [report appendString:@"Memory: empty\n"];
    } else {
        NSDictionary *memAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:EZMemoryGetPath() error:nil];
        double memorySizeKB = [memAttributes[NSFileSize] unsignedLongLongValue] / 1024.0;
        [report appendFormat:@"Memory: %lu entries, %.1f KB\n",
         (unsigned long)memoryEntries.count, memorySizeKB];

        NSInteger previewCount = MIN(3, (NSInteger)memoryEntries.count);
        [report appendString:@"Recent memories:\n"];
        for (NSInteger i = (NSInteger)memoryEntries.count - 1;
             i >= (NSInteger)memoryEntries.count - previewCount; i--) {
            NSDictionary *entry = memoryEntries[(NSUInteger)i];
            NSString *summary = _safeString(entry[@"summary"]);
            NSString *timestamp = _safeString(entry[@"timestamp"]);
            NSString *truncated = summary.length > 80 ? [[summary substringToIndex:80] stringByAppendingString:@"…"] : summary;
            [report appendFormat:@"  [%@] %@\n", timestamp, truncated];
        }
    }

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
