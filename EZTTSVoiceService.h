//
//  EZTTSVoiceService.h
//  EZTTSLibrary
//
//  Extracted from TextToSpeechViewController's fetchVoicesTapped: so voice fetching
//  isn't tied to that screen's UI — both the compose screen and the clip-edit voice
//  picker call the same network/auth code instead of duplicating it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const EZTTSVoiceServiceErrorDomain;

@interface EZTTSVoiceService : NSObject

/// Fetches the caller's available ElevenLabs voices (their clones plus the shared/premade
/// set) via the same Supabase Edge Function the compose screen has always used. Each
/// dictionary matches the raw shape returned by that endpoint (voice_id/id, name, etc.) —
/// unchanged from before, so existing call sites don't need to adapt their parsing.
///
/// `completion` is always called on the main queue. An empty (non-nil) array is a valid,
/// non-error result — callers decide whether "zero voices" deserves its own message.
+ (void)fetchVoicesWithCompletion:(void (^)(NSArray<NSDictionary<NSString *, id> *> * _Nullable voices,
                                             NSError * _Nullable error))completion;

/// The user's saved voice settings for text-to-speak, set with the
/// sliders on the Settings page and stored in NSUserDefaults.
/// `voiceSettingsPayload` is merged into every `tts` request as
/// `voice_settings`; the server clamps the values and falls back to
/// these same defaults when a field is absent, so builds that never
/// send it are unaffected.
+ (NSDictionary<NSString *, id> *)voiceSettingsPayload;
+ (float)savedStability;
+ (float)savedStyle;
+ (float)savedSimilarityBoost;
+ (BOOL)savedSpeakerBoost;
+ (float)savedSpeed;
+ (void)saveStability:(float)value;
+ (void)saveStyle:(float)value;
+ (void)saveSimilarityBoost:(float)value;
+ (void)saveSpeakerBoost:(BOOL)value;
+ (void)saveSpeed:(float)value;
+ (void)resetVoiceSettings;

@end

NS_ASSUME_NONNULL_END
