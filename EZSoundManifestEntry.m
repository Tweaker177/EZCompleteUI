//
//  EZSoundManifestEntry.m
//  EZSounds
//

#import "EZSoundManifestEntry.h"

// Manifest.json key constants. Centralized so the dictionary/JSON paths and any
// future migration code all reference the same literal strings.
static NSString * const kEZKeyUUID         = @"uuid";
static NSString * const kEZKeyCreated      = @"created";
static NSString * const kEZKeyProvider     = @"provider";
static NSString * const kEZKeyModel        = @"model";
static NSString * const kEZKeyPrompt       = @"prompt";
static NSString * const kEZKeyPreview      = @"preview";
static NSString * const kEZKeyFilename     = @"filename";
static NSString * const kEZKeyRelativePath = @"relativePath";
static NSString * const kEZKeyDuration     = @"duration";
static NSString * const kEZKeySampleRate   = @"sampleRate";
static NSString * const kEZKeyFileSize     = @"fileSize";
static NSString * const kEZKeyFavorite     = @"favorite";
static NSString * const kEZKeyTags         = @"tags";
static NSString * const kEZKeyMetadata     = @"metadata";
static NSString * const kEZKeyUnknownBucket = @"__unknown";

static NSInteger const kEZPreviewMaxLength = 80;

static NSString *EZSoundDerivePreview(NSString *prompt) {
    if (prompt.length == 0) return @"";
    if (prompt.length <= kEZPreviewMaxLength) return prompt;
    NSString *truncated = [prompt substringToIndex:kEZPreviewMaxLength];
    // Avoid cutting mid-word where reasonably possible.
    NSRange lastSpace = [truncated rangeOfString:@" " options:NSBackwardsSearch];
    if (lastSpace.location != NSNotFound && lastSpace.location > kEZPreviewMaxLength / 2) {
        truncated = [truncated substringToIndex:lastSpace.location];
    }
    return [truncated stringByAppendingString:@"…"];
}

static NSError *EZSoundManifestEntryError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"EZSoundManifestEntry"
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey: description}];
}

@implementation EZSoundManifestEntry

#pragma mark - Init

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
                     metadata:(nullable NSDictionary<NSString *, id> *)metadata
{
    NSParameterAssert(uuid.length > 0);
    NSParameterAssert(created != nil);
    NSParameterAssert(provider.length > 0);
    NSParameterAssert(prompt != nil);
    NSParameterAssert(filename.length > 0);
    NSParameterAssert(relativePath.length > 0);

    self = [super init];
    if (self) {
        _uuid = [uuid copy];
        _created = created;
        _provider = [provider copy];
        _model = [model copy];
        _prompt = [prompt copy];
        _preview = preview.length > 0 ? [preview copy] : EZSoundDerivePreview(prompt);
        _filename = [filename copy];
        _relativePath = [relativePath copy];
        _duration = duration;
        _sampleRate = sampleRate;
        _fileSize = fileSize;
        _favorite = favorite;
        _tags = tags ? [tags copy] : @[];
        _metadata = metadata ? [metadata copy] : @{};
    }
    return self;
}

+ (instancetype)entryWithProvider:(NSString *)provider
                             model:(nullable NSString *)model
                            prompt:(NSString *)prompt
                          filename:(NSString *)filename
                      relativePath:(NSString *)relativePath
                          duration:(double)duration
                        sampleRate:(double)sampleRate
                          fileSize:(unsigned long long)fileSize
{
    NSString *uuid = [[NSUUID UUID] UUIDString];
    return [[self alloc] initWithUUID:uuid
                               created:[NSDate date]
                              provider:provider
                                 model:model
                                prompt:prompt
                               preview:nil
                              filename:filename
                          relativePath:relativePath
                              duration:duration
                            sampleRate:sampleRate
                              fileSize:fileSize
                              favorite:NO
                                  tags:nil
                              metadata:nil];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    return [[EZSoundManifestEntry alloc] initWithUUID:self.uuid
                                               created:self.created
                                              provider:self.provider
                                                 model:self.model
                                                prompt:self.prompt
                                               preview:self.preview
                                              filename:self.filename
                                          relativePath:self.relativePath
                                              duration:self.duration
                                            sampleRate:self.sampleRate
                                              fileSize:self.fileSize
                                              favorite:self.favorite
                                                  tags:self.tags
                                              metadata:self.metadata];
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.uuid forKey:kEZKeyUUID];
    [coder encodeObject:self.created forKey:kEZKeyCreated];
    [coder encodeObject:self.provider forKey:kEZKeyProvider];
    [coder encodeObject:self.model forKey:kEZKeyModel];
    [coder encodeObject:self.prompt forKey:kEZKeyPrompt];
    [coder encodeObject:self.preview forKey:kEZKeyPreview];
    [coder encodeObject:self.filename forKey:kEZKeyFilename];
    [coder encodeObject:self.relativePath forKey:kEZKeyRelativePath];
    [coder encodeDouble:self.duration forKey:kEZKeyDuration];
    [coder encodeDouble:self.sampleRate forKey:kEZKeySampleRate];
    [coder encodeInt64:(int64_t)self.fileSize forKey:kEZKeyFileSize];
    [coder encodeBool:self.favorite forKey:kEZKeyFavorite];
    [coder encodeObject:self.tags forKey:kEZKeyTags];
    [coder encodeObject:self.metadata forKey:kEZKeyMetadata];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    NSString *uuid = [coder decodeObjectOfClass:[NSString class] forKey:kEZKeyUUID];
    NSDate *created = [coder decodeObjectOfClass:[NSDate class] forKey:kEZKeyCreated];
    NSString *provider = [coder decodeObjectOfClass:[NSString class] forKey:kEZKeyProvider];
    NSString *model = [coder decodeObjectOfClass:[NSString class] forKey:kEZKeyModel];
    NSString *prompt = [coder decodeObjectOfClass:[NSString class] forKey:kEZKeyPrompt];
    NSString *preview = [coder decodeObjectOfClass:[NSString class] forKey:kEZKeyPreview];
    NSString *filename = [coder decodeObjectOfClass:[NSString class] forKey:kEZKeyFilename];
    NSString *relativePath = [coder decodeObjectOfClass:[NSString class] forKey:kEZKeyRelativePath];
    double duration = [coder decodeDoubleForKey:kEZKeyDuration];
    double sampleRate = [coder decodeDoubleForKey:kEZKeySampleRate];
    unsigned long long fileSize = (unsigned long long)[coder decodeInt64ForKey:kEZKeyFileSize];
    BOOL favorite = [coder decodeBoolForKey:kEZKeyFavorite];

    NSSet *stringArraySet = [NSSet setWithObjects:[NSArray class], [NSString class], nil];
    NSArray<NSString *> *tags = [coder decodeObjectOfClasses:stringArraySet forKey:kEZKeyTags];

    NSSet *dictionarySet = [NSSet setWithObjects:[NSDictionary class], [NSString class],
                             [NSNumber class], [NSArray class], [NSNull class], nil];
    NSDictionary *metadata = [coder decodeObjectOfClasses:dictionarySet forKey:kEZKeyMetadata];

    if (uuid.length == 0 || created == nil || provider.length == 0 ||
        prompt == nil || filename.length == 0 || relativePath.length == 0) {
        return nil;
    }

    return [self initWithUUID:uuid
                       created:created
                      provider:provider
                         model:model
                        prompt:prompt
                       preview:preview
                      filename:filename
                  relativePath:relativePath
                      duration:duration
                    sampleRate:sampleRate
                      fileSize:fileSize
                      favorite:favorite
                          tags:tags
                      metadata:metadata];
}

#pragma mark - Dictionary serialization

- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    NSMutableDictionary<NSString *, id> *dict = [NSMutableDictionary dictionaryWithCapacity:14];
    dict[kEZKeyUUID] = self.uuid;
    dict[kEZKeyCreated] = @([self.created timeIntervalSince1970]);
    dict[kEZKeyProvider] = self.provider;
    dict[kEZKeyModel] = self.model ?: [NSNull null];
    dict[kEZKeyPrompt] = self.prompt;
    dict[kEZKeyPreview] = self.preview ?: @"";
    dict[kEZKeyFilename] = self.filename;
    dict[kEZKeyRelativePath] = self.relativePath;
    dict[kEZKeyDuration] = @(self.duration);
    dict[kEZKeySampleRate] = @(self.sampleRate);
    dict[kEZKeyFileSize] = @(self.fileSize);
    dict[kEZKeyFavorite] = @(self.favorite);
    dict[kEZKeyTags] = self.tags;
    dict[kEZKeyMetadata] = self.metadata;
    return dict;
}

+ (nullable instancetype)entryWithDictionary:(NSDictionary<NSString *, id> *)dictionary
                                        error:(NSError * _Nullable * _Nullable)error
{
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        if (error) *error = EZSoundManifestEntryError(-1, @"Expected a dictionary.");
        return nil;
    }

    NSString *uuid = [dictionary[kEZKeyUUID] isKindOfClass:[NSString class]] ? dictionary[kEZKeyUUID] : nil;
    NSString *provider = [dictionary[kEZKeyProvider] isKindOfClass:[NSString class]] ? dictionary[kEZKeyProvider] : nil;
    NSString *prompt = [dictionary[kEZKeyPrompt] isKindOfClass:[NSString class]] ? dictionary[kEZKeyPrompt] : nil;
    NSString *filename = [dictionary[kEZKeyFilename] isKindOfClass:[NSString class]] ? dictionary[kEZKeyFilename] : nil;
    NSString *relativePath = [dictionary[kEZKeyRelativePath] isKindOfClass:[NSString class]] ? dictionary[kEZKeyRelativePath] : nil;

    if (uuid.length == 0 || provider.length == 0 || prompt == nil ||
        filename.length == 0 || relativePath.length == 0) {
        if (error) {
            *error = EZSoundManifestEntryError(-2, @"Manifest entry missing one or more required fields "
                                                @"(uuid, provider, prompt, filename, relativePath).");
        }
        return nil;
    }

    NSDate *created;
    id createdRaw = dictionary[kEZKeyCreated];
    if ([createdRaw isKindOfClass:[NSNumber class]]) {
        created = [NSDate dateWithTimeIntervalSince1970:[createdRaw doubleValue]];
    } else {
        // Missing/malformed timestamp shouldn't hard-fail the whole entry — fall back to
        // "now" so a hand-edited or partially-corrupted manifest row is still recoverable.
        created = [NSDate date];
    }

    NSString *model = [dictionary[kEZKeyModel] isKindOfClass:[NSString class]] ? dictionary[kEZKeyModel] : nil;
    NSString *preview = [dictionary[kEZKeyPreview] isKindOfClass:[NSString class]] ? dictionary[kEZKeyPreview] : nil;

    double duration = [dictionary[kEZKeyDuration] isKindOfClass:[NSNumber class]] ? [dictionary[kEZKeyDuration] doubleValue] : 0.0;
    double sampleRate = [dictionary[kEZKeySampleRate] isKindOfClass:[NSNumber class]] ? [dictionary[kEZKeySampleRate] doubleValue] : 0.0;
    unsigned long long fileSize = [dictionary[kEZKeyFileSize] isKindOfClass:[NSNumber class]] ? [dictionary[kEZKeyFileSize] unsignedLongLongValue] : 0;
    BOOL favorite = [dictionary[kEZKeyFavorite] isKindOfClass:[NSNumber class]] ? [dictionary[kEZKeyFavorite] boolValue] : NO;

    NSArray *tagsRaw = [dictionary[kEZKeyTags] isKindOfClass:[NSArray class]] ? dictionary[kEZKeyTags] : @[];
    NSMutableArray<NSString *> *tags = [NSMutableArray arrayWithCapacity:tagsRaw.count];
    for (id tag in tagsRaw) {
        if ([tag isKindOfClass:[NSString class]]) [tags addObject:tag];
    }

    NSMutableDictionary<NSString *, id> *metadata = [NSMutableDictionary dictionary];
    if ([dictionary[kEZKeyMetadata] isKindOfClass:[NSDictionary class]]) {
        [metadata addEntriesFromDictionary:dictionary[kEZKeyMetadata]];
    }

    // Forward-compatibility: preserve any keys this version of the app doesn't recognize
    // yet, so round-tripping through an older build never silently drops future fields.
    static NSSet<NSString *> *knownKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownKeys = [NSSet setWithArray:@[
            kEZKeyUUID, kEZKeyCreated, kEZKeyProvider, kEZKeyModel,
            kEZKeyPrompt, kEZKeyPreview, kEZKeyFilename, kEZKeyRelativePath,
            kEZKeyDuration, kEZKeySampleRate, kEZKeyFileSize, kEZKeyFavorite, kEZKeyTags,
            kEZKeyMetadata
        ]];
    });
    NSMutableDictionary<NSString *, id> *unknown = [NSMutableDictionary dictionary];
    [dictionary enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        if (![knownKeys containsObject:key]) unknown[key] = obj;
    }];
    if (unknown.count > 0) {
        metadata[kEZKeyUnknownBucket] = unknown;
    }

    return [[self alloc] initWithUUID:uuid
                               created:created
                              provider:provider
                                 model:model
                                prompt:prompt
                               preview:preview
                              filename:filename
                          relativePath:relativePath
                              duration:duration
                            sampleRate:sampleRate
                              fileSize:fileSize
                              favorite:favorite
                                  tags:tags
                              metadata:metadata];
}

#pragma mark - JSON serialization

- (nullable NSData *)jsonDataWithError:(NSError * _Nullable * _Nullable)error {
    NSDictionary *dict = [self dictionaryRepresentation];
    if (![NSJSONSerialization isValidJSONObject:dict]) {
        if (error) *error = EZSoundManifestEntryError(-3, @"Entry contains non-JSON-safe values in metadata.");
        return nil;
    }
    return [NSJSONSerialization dataWithJSONObject:dict options:0 error:error];
}

+ (nullable instancetype)entryWithJSONData:(NSData *)jsonData
                                      error:(NSError * _Nullable * _Nullable)error
{
    id obj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:error];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (error && *error == nil) *error = EZSoundManifestEntryError(-4, @"JSON did not decode to a dictionary.");
        return nil;
    }
    return [self entryWithDictionary:obj error:error];
}

#pragma mark - Debug

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p uuid=%@ provider=%@ duration=%.2fs \"%@\">",
            self.class, self, self.uuid, self.provider, self.duration, self.preview];
}

@end
