// helpers.h
// EZCompleteUI v4.0
//
// Changes from v3.0:
//   - EZContextResult: tier field (EZRoutingTier), injectedHistory, confidence
//   - analyzePromptForContext: gains chatKey param for Tier-4 disk lookup
//   - createMemoryFromCompletion: gains chatKey param (stored in entry)
//   - EZThreadLoadContext: returns minimum turns within a token budget

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
// EZContextResult
// ─────────────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, EZRoutingTier) {
    EZRoutingTierDirect   = 1,  ///< Helper answered directly — skip main model
    EZRoutingTierSimple   = 2,  ///< Main model, no context
    EZRoutingTierMemory   = 3,  ///< Main model + memory summary
    EZRoutingTierFullChat = 4,  ///< Main model + turns from disk
};

@interface EZContextResult : NSObject
@property (nonatomic, assign) EZRoutingTier tier;
@property (nonatomic, assign) BOOL          needsContext;   ///< YES when tier >= 3
@property (nonatomic, copy)   NSString     *reason;
/// Tier 1: the direct answer. Tiers 2-4: enriched prompt to send.
@property (nonatomic, copy)   NSString     *finalPrompt;
@property (nonatomic, assign) NSInteger     estimatedTokens;
/// Tier 1: non-nil → display this, skip API call
@property (nonatomic, copy, nullable) NSString              *shortCircuitAnswer;
/// Tier 4: prepend these turns to chatContext before the API call
@property (nonatomic, strong, nullable) NSArray<NSDictionary *> *injectedHistory;
@property (nonatomic, assign) float         confidence;
@end

// ─────────────────────────────────────────────────────────────────────────────
// EZChatThread
// ─────────────────────────────────────────────────────────────────────────────

@interface EZChatThread : NSObject
@property (nonatomic, copy)   NSString                *threadID;
@property (nonatomic, copy)   NSString                *title;
@property (nonatomic, copy)   NSString                *displayText;
@property (nonatomic, strong) NSArray<NSDictionary *> *chatContext;
@property (nonatomic, copy)   NSString                *modelName;
@property (nonatomic, copy)   NSString                *createdAt;
@property (nonatomic, copy)   NSString                *updatedAt;
@property (nonatomic, strong) NSArray<NSString *>     *attachmentPaths;
@property (nonatomic, copy, nullable) NSString        *lastImageLocalPath;
@property (nonatomic, copy, nullable) NSString        *lastVideoLocalPath;
- (NSDictionary *)toDictionary;
+ (nullable instancetype)fromDictionary:(NSDictionary *)dict;
@end

// ─────────────────────────────────────────────────────────────────────────────
// Context Analyzer (4-tier)
// ─────────────────────────────────────────────────────────────────────────────

void analyzePromptForContext(NSString *userPrompt,
                             NSString * _Nullable memoryContext,
                             NSString *apiKey,
                             NSString * _Nullable chatKey,
                             void (^completion)(EZContextResult *result));

// ─────────────────────────────────────────────────────────────────────────────
// Memory
// ─────────────────────────────────────────────────────────────────────────────

NSString *EZMemoryGetPath(void);
void createMemoryFromCompletion(NSString *userPrompt,
                                NSString *assistantReply,
                                NSString *apiKey,
                                NSString * _Nullable chatKey,
                                void (^completion)(NSString * _Nullable entry));
NSString *loadMemoryContext(NSInteger maxEntries);
BOOL clearMemoryLog(void);

// ─────────────────────────────────────────────────────────────────────────────
// Thread Store
// ─────────────────────────────────────────────────────────────────────────────

NSString *EZThreadStoreDir(void);
void EZThreadSave(EZChatThread *thread, void (^ _Nullable completion)(BOOL success));
EZChatThread * _Nullable EZThreadLoad(NSString *threadID);
NSArray<EZChatThread *> *EZThreadList(void);
BOOL EZThreadDelete(NSString *threadID);
NSString *EZThreadSearchMemory(NSString *query, NSString *apiKey);

/// Load the most-recent turns from a thread that fit within tokenBudget.
/// Returns nil if thread not found or empty.
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
