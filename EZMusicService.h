// EZMusicService.h
// EZCompleteUI v1.0
//
// Purpose:
//   Network client for the ez-music Supabase Edge Function (ElevenLabs
//   text-to-music). It contains no pricing, no API keys and no billing logic:
//   the server decides what a song costs, charges coins, generates the audio
//   and stores it. This class only sends what the user picked and reports
//   what the server says, so a modified app cannot change a price.
//
//   Songs are generated in the background on the server. -startGeneration...
//   returns as soon as coins are reserved, and -pollGenerationWithID:... checks
//   progress until every variant is finished. If the app is closed mid-way,
//   the song still finishes and shows up in -fetchLibrary... next launch.
//
//   Networking behavior handled here so view controllers don't have to:
//     - Attaches a valid (refreshed if needed) access token to every request.
//     - Retries dropped connections and 502/503/504 responses. This is safe
//       for generation because every request carries a generation ID the server
//       uses to avoid charging twice.
//     - Retries once on HTTP 401 after refreshing the session.
//     - Always calls completion blocks on the main queue.
//
// Changes:
//   - Initial version.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const EZMusicServiceErrorDomain;

/// userInfo key holding the server's machine-readable error code, for example
/// "insufficient_coins", "too_many_active" or "prompt_rejected".
extern NSString * const EZMusicServiceServerCodeKey;

typedef NS_ENUM(NSInteger, EZMusicServiceErrorCode) {
    EZMusicServiceErrorNotSignedIn   = 1,
    EZMusicServiceErrorNetwork       = 2,
    EZMusicServiceErrorServer        = 3,   // The server rejected or failed the request.
    EZMusicServiceErrorBadResponse   = 4,   // The reply was not the JSON we expected.
    EZMusicServiceErrorPollTimedOut  = 5,
    EZMusicServiceErrorInvalidInput  = 6,
};

/// Handle returned by polling so the screen can stop checking when it goes away.
@interface EZMusicPollToken : NSObject
@property (nonatomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

@interface EZMusicService : NSObject

+ (instancetype)sharedService;
- (instancetype)init NS_UNAVAILABLE;

/// Current prices and limits (coins_per_minute, min/max duration, variant limit,
/// output formats). For showing a price quote only; the server recomputes the
/// real charge on every request.
- (void)fetchConfigWithCompletion:(void (^)(NSDictionary * _Nullable config,
                                            NSError * _Nullable error))completion;

/// Reserves coins and starts generation. Provide either `prompt` or `compositionPlan`.
/// For prompt mode `durationSeconds` is required; for a plan the server sums the
/// section durations. On success `entries` holds one dictionary per variant with
/// entry_id, variant_index and status, and `balance` is the user's new coin
/// balance (also applied to EZEntitlementManager).
- (void)startGenerationWithPrompt:(nullable NSString *)prompt
                  compositionPlan:(nullable NSDictionary *)compositionPlan
                            title:(nullable NSString *)title
                  durationSeconds:(NSInteger)durationSeconds
                     variantCount:(NSInteger)variantCount
                forceInstrumental:(BOOL)forceInstrumental
                       completion:(void (^)(NSString * _Nullable generationID,
                                            NSArray<NSDictionary *> * _Nullable entries,
                                            NSInteger balance,
                                            NSError * _Nullable error))completion;

/// Checks a generation every few seconds until no variant is "pending". `progress`
/// is called after every successful check with the latest entry dictionaries.
/// `completion` receives the final entries (some may be "failed"; failed variants
/// were already refunded by the server) or an error if checking kept failing or
/// the overall wait limit passed.
- (EZMusicPollToken *)pollGenerationWithID:(NSString *)generationID
                                  progress:(nullable void (^)(NSArray<NSDictionary *> *entries))progress
                                completion:(void (^)(NSArray<NSDictionary *> * _Nullable entries,
                                                     NSError * _Nullable error))completion;

/// Newest-first library page. Pass the last entry's created_at as `before` to page.
- (void)fetchLibraryBefore:(nullable NSString *)beforeTimestamp
                     limit:(NSInteger)limit
                completion:(void (^)(NSArray<NSDictionary *> * _Nullable entries,
                                     NSError * _Nullable error))completion;

/// Short-lived signed URL for playback, or for saving the file when `forDownload` is YES.
- (void)fetchPlaybackURLForEntryID:(NSString *)entryID
                       forDownload:(BOOL)forDownload
                        completion:(void (^)(NSURL * _Nullable url,
                                             NSError * _Nullable error))completion;

- (void)setFavorite:(BOOL)isFavorite
         forEntryID:(NSString *)entryID
         completion:(void (^)(NSError * _Nullable error))completion;

/// Deletes a finished or failed entry and its audio file.
- (void)deleteEntryID:(NSString *)entryID
           completion:(void (^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
