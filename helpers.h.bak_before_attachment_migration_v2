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

NSString *EZHelperStats(void);

NSString * _Nullable EZCallHelperModel(NSString *systemPrompt,
                                       NSString *userMessage,
                                       NSString *apiKey,
                                       NSInteger maxTokens);

NS_ASSUME_NONNULL_END
