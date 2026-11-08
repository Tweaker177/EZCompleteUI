//
//  EZSoundManifestEntry.h
//  EZSounds
//
//  Model object representing a single generated sound inside the Sounds
//  library's Manifest.json. Modeled on EZTTSManifestEntry — same JSON
//  discipline, minus the voice fields a sound doesn't have.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A single entry in the Sounds library manifest. One instance == one sound
/// file on disk, plus the metadata needed to list, search, and replay it.
///
/// The canonical on-disk representation is JSON via Manifest.json, produced by
/// -dictionaryRepresentation / +entryWithDictionary:.
@interface EZSoundManifestEntry : NSObject <NSSecureCoding, NSCopying>

/// Stable unique identifier for this sound. Generated once at save time, never reused.
@property (nonatomic, copy) NSString *uuid;

/// Creation timestamp (UTC). This is what "sorted by creation date" sorts on.
@property (nonatomic, strong) NSDate *created;

/// Generation backend that produced this sound, e.g. "elevenlabs".
/// Free-form string rather than an enum so new providers never require a manifest migration.
@property (nonatomic, copy) NSString *provider;

/// Provider-specific model identifier used for the request (e.g. "eleven_text_to_sound_v2").
@property (nonatomic, copy, nullable) NSString *model;

/// Full prompt that was generated ("rain on a tin roof", "coffee shop ambience"...).
@property (nonatomic, copy) NSString *prompt;

/// Short preview/snippet of the prompt, precomputed for fast list-cell rendering.
@property (nonatomic, copy, nullable) NSString *preview;

/// Filename on disk, e.g. "sound_1751567890_ABCDEF12.mp3". Lives under Audio/.
@property (nonatomic, copy) NSString *filename;

/// Path relative to the EZSounds/ root, e.g. "Audio/sound_1751567890_ABCDEF12.mp3".
@property (nonatomic, copy) NSString *relativePath;

/// Duration in seconds, as measured via AVFoundation at save time.
@property (nonatomic, assign) double duration;

/// Sample rate in Hz, as measured via AVFoundation at save time.
@property (nonatomic, assign) double sampleRate;

/// File size in bytes on disk.
@property (nonatomic, assign) unsigned long long fileSize;

/// User-toggleable favorite flag.
@property (nonatomic, assign, getter=isFavorite) BOOL favorite;

/// Free-form tags for search/filtering. Always non-nil (empty array if none).
@property (nonatomic, copy) NSArray<NSString *> *tags;

/// Open-ended bag for anything that doesn't deserve a first-class property yet
/// (requested duration, loop flag, coin cost...). Values must be JSON-safe
/// (NSString/NSNumber/NSArray/NSDictionary/NSNull) since this dictionary
/// round-trips through Manifest.json verbatim.
@property (nonatomic, copy) NSDictionary<NSString *, id> *metadata;

/// Designated initializer. `uuid` and `created` are generated automatically if you use
/// +entryWithProvider:... below instead of calling this directly.
- (instancetype)initWithUUID:(NSString *)uuid
                      created:(NSDate *)created
                     provider:(NSString *)provider
                        model:(nullable NSString *)model
                       prompt:(NSString *)prompt
                      preview:(nullable NSString *)preview
                     filename:(NSString *)filename
                 relativePath:(NSString *)relativePath
                     duration:(double)duration
                   sampleRate:(double)sampleRate
                     fileSize:(unsigned long long)fileSize
                     favorite:(BOOL)favorite
                         tags:(nullable NSArray<NSString *> *)tags
                     metadata:(nullable NSDictionary<NSString *, id> *)metadata NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Convenience initializer for freshly-generated sounds. Generates a new UUID and
/// stamps `created` to now. `preview` is auto-derived from `prompt` if not supplied.
+ (instancetype)entryWithProvider:(NSString *)provider
                             model:(nullable NSString *)model
                            prompt:(NSString *)prompt
                          filename:(NSString *)filename
                      relativePath:(NSString *)relativePath
                          duration:(double)duration
                        sampleRate:(double)sampleRate
                          fileSize:(unsigned long long)fileSize;

#pragma mark - Dictionary serialization

/// JSON-safe dictionary representation. Keys match Manifest.json exactly.
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;

/// Builds an entry from a dictionary previously produced by -dictionaryRepresentation.
/// Returns nil and populates `error` if required fields (uuid, created, provider,
/// prompt, filename, relativePath) are missing or malformed. Unknown keys are
/// preserved into `metadata` under an "__unknown" bucket so forward-compatible
/// manifests never lose data on round-trip through an older app version.
+ (nullable instancetype)entryWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                                        error:(NSError * _Nullable * _Nullable)error;

#pragma mark - JSON serialization

/// UTF-8 JSON data for this single entry.
- (nullable NSData *)jsonDataWithError:(NSError * _Nullable * _Nullable)error;

/// Inverse of -jsonDataWithError:.
+ (nullable instancetype)entryWithJSONData:(NSData *)jsonData
                                      error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
