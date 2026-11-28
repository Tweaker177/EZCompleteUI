// BRRouletteDealer.m
// EZCompleteUI v1.0
//
// Purpose:
//   The roulette dealer's voice (see BRRouletteDealer.h). One instance per
//   table screen. It owns the downloaded clip data, a short queue of calls,
//   and the Apple-voice fallback, so the table controller only says WHAT to
//   announce and never deals with audio details.
//
// Changes from v0 (new file):
//   - Initial version.

#import "BRRouletteDealer.h"
#import "BRRouletteAPI.h"
#import "BRBlackjackAPI.h"
#import "EZSupabaseConfig.h"
#import <AVFoundation/AVFoundation.h>

extern BOOL BRSlotSoundEnabled(void);   // shared game-sounds switch (BRSlotChatBar.h)

NSString *const BRRouletteClipPlaceBets = @"place_bets";
NSString *const BRRouletteClipNoMoreBets = @"no_more_bets";

NSString *BRRouletteClipKeyForNumber(NSInteger number) {
    return [NSString stringWithFormat:@"rl%ld", (long)number];
}

// A burst of calls (returning after time away, a late join) drops the oldest
// ones instead of announcing rounds that are long over.
static const NSUInteger kMaxQueuedCalls = 2;
// The server renders a missing library in the background, so ask again a few
// times, 15 seconds apart, until it reports complete.
static const NSInteger kMaxManifestAttempts = 8;
static const NSTimeInterval kManifestRetrySeconds = 15.0;

static NSDictionary *BRRouletteDealerDict(id value) { return [value isKindOfClass:[NSDictionary class]] ? value : @{}; }
static NSString *BRRouletteDealerString(id value) { return [value isKindOfClass:[NSString class]] ? value : @""; }

/// Prepares audio for dealer speech. Ambient respects the silent switch and mixes
/// with other audio; an existing playback session (music, the roulette sound
/// effects) is left alone.
static void BRRouletteDealerActivateAudioSession(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session.category isEqualToString:AVAudioSessionCategoryPlayback] && ![session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        [session setCategory:AVAudioSessionCategoryAmbient error:nil];
    }
    [session setActive:YES error:nil];
}

@interface BRRouletteDealer () <AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate>
@property (nonatomic, copy) NSString *tableID;
@end

@implementation BRRouletteDealer {
    NSMutableDictionary<NSString *, NSData *> *_clipData;     // key -> mp3 bytes
    NSMutableSet<NSString *> *_requestedKeys;                  // downloads in flight or done
    NSMutableArray<NSDictionary *> *_queue;                    // pending calls {keys, text}
    NSArray<NSString *> *_currentKeys;
    NSUInteger _currentIndex;
    BOOL _busy;
    BOOL _shutdown;
    NSInteger _rouletteAttempts;
    NSInteger _blackjackAttempts;
    NSInteger _generation;                                     // bumped by interrupt so late callbacks are ignored
    AVAudioPlayer *_player;
    AVSpeechSynthesizer *_appleVoice;
}

- (instancetype)initWithTableID:(NSString *)tableID {
    self = [super init];
    if (self) {
        _tableID = [tableID copy];
        _clipData = [NSMutableDictionary dictionary];
        _requestedKeys = [NSMutableSet set];
        _queue = [NSMutableArray array];
    }
    return self;
}

#pragma mark - Clip loading

- (NSString *)appLocale {
    // The app's own bundle localization, so the spoken call matches the
    // captions on screen (same value the blackjack dealer sends).
    return [NSBundle mainBundle].preferredLocalizations.firstObject ?: @"en";
}

- (BOOL)isTrustedClipURL:(NSURL *)url {
    NSString *trustedHost = [NSURL URLWithString:EZSupabaseURL].host;
    return url != nil && [url.scheme isEqualToString:@"https"] && [url.host isEqualToString:trustedHost];
}

- (BOOL)hasSharedClips {
    return _clipData[BRRouletteClipPlaceBets] != nil && _clipData[BRRouletteClipNoMoreBets] != nil;
}

- (void)loadClips {
    [self loadRouletteClips];
}

/// Winning-number calls ("rl0"..."rl36"). The answer also names this table's
/// blackjack twin, which is where the shared calls are fetched from.
- (void)loadRouletteClips {
    if (_shutdown) return;
    _rouletteAttempts += 1;
    __weak typeof(self) weakSelf = self;
    [BRRouletteAPI performAction:@"dealer_clips" params:@{ @"table_id": self.tableID, @"locale": [self appLocale] } completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self->_shutdown) return;
        NSDictionary *clips = BRRouletteDealerDict(json[@"clips"]);
        for (NSString *key in clips) [self downloadClipForKey:key fromURLString:BRRouletteDealerString(clips[key])];
        NSString *twinTableID = BRRouletteDealerString(json[@"blackjack_table_id"]);
        if (twinTableID.length > 0) [self loadSharedBlackjackClipsForTableID:twinTableID];
        BOOL complete = [json[@"complete"] respondsToSelector:@selector(boolValue)] && [json[@"complete"] boolValue];
        if (!complete && self->_rouletteAttempts < kMaxManifestAttempts) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kManifestRetrySeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf loadRouletteClips]; });
        }
    }];
}

/// "Place your bets" and "No more bets" from the blackjack library. Only those
/// two clips are downloaded; the rest of that library is blackjack's.
- (void)loadSharedBlackjackClipsForTableID:(NSString *)twinTableID {
    if (_shutdown || twinTableID.length == 0 || [self hasSharedClips]) return;
    if (_blackjackAttempts >= kMaxManifestAttempts) return;
    _blackjackAttempts += 1;
    __weak typeof(self) weakSelf = self;
    [BRBlackjackAPI performAction:@"dealer_clips" params:@{ @"table_id": twinTableID, @"locale": [self appLocale] } completion:^(NSDictionary *json, NSInteger status, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self->_shutdown) return;
        NSDictionary *clips = BRRouletteDealerDict(json[@"clips"]);
        for (NSString *key in @[BRRouletteClipPlaceBets, BRRouletteClipNoMoreBets]) {
            NSString *urlString = BRRouletteDealerString(clips[key]);
            if (urlString.length > 0) [self downloadClipForKey:key fromURLString:urlString];
        }
        // The library may still be rendering (first player in a language): ask again shortly.
        BOOL haveBothURLs = clips[BRRouletteClipPlaceBets] != nil && clips[BRRouletteClipNoMoreBets] != nil;
        if (!haveBothURLs && self->_blackjackAttempts < kMaxManifestAttempts) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kManifestRetrySeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf loadSharedBlackjackClipsForTableID:twinTableID]; });
        }
    }];
}

- (void)downloadClipForKey:(NSString *)key fromURLString:(NSString *)urlString {
    if (_clipData[key] != nil || [_requestedKeys containsObject:key]) return;
    NSURL *url = [NSURL URLWithString:urlString];
    if (![self isTrustedClipURL:url]) return;   // only ever fetch from our own storage
    [_requestedKeys addObject:key];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL usable = data.length > 0 && !error && [response isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)response).statusCode == 200;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (usable) self->_clipData[key] = data;
            else [self->_requestedKeys removeObject:key];   // let the next manifest pass retry it
        });
    }] resume];
}

#pragma mark - Speaking

- (BOOL)hasAllClips:(NSArray<NSString *> *)keys {
    for (NSString *key in keys) if (_clipData[key] == nil) return NO;
    return keys.count > 0;
}

- (void)speakKeys:(NSArray<NSString *> *)keys fallbackText:(NSString *)fallbackText {
    if (_shutdown || !BRSlotSoundEnabled()) return;
    while (_queue.count >= kMaxQueuedCalls) [_queue removeObjectAtIndex:0];
    [_queue addObject:@{ @"keys": keys ?: @[], @"text": fallbackText ?: @"" }];
    if (!_busy) [self playNextCall];
}

- (void)playNextCall {
    if (_shutdown || _queue.count == 0) { _busy = NO; return; }
    if (!BRSlotSoundEnabled()) { [self interrupt]; return; }
    _busy = YES;
    NSDictionary *call = _queue.firstObject;
    [_queue removeObjectAtIndex:0];
    _currentKeys = call[@"keys"];
    _currentIndex = 0;
    if ([self hasAllClips:_currentKeys]) {
        [self playCurrentKey];
    } else {
        [self speakWithAppleVoice:call[@"text"]];
    }
}

- (void)playNextCallAfter:(NSTimeInterval)delay {
    NSInteger generation = _generation;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self->_generation) return;   // interrupted meanwhile
        [self playNextCall];
    });
}

- (void)playCurrentKey {
    if (_shutdown) return;
    if (_currentIndex >= _currentKeys.count) { [self playNextCallAfter:0.2]; return; }
    NSData *data = _clipData[_currentKeys[_currentIndex]];
    NSError *playerError = nil;
    AVAudioPlayer *player = data ? [[AVAudioPlayer alloc] initWithData:data error:&playerError] : nil;
    if (!player) {   // undecodable clip: read the whole call with the Apple voice instead
        [self speakWithAppleVoice:@""];
        return;
    }
    BRRouletteDealerActivateAudioSession();
    player.delegate = self;
    player.volume = 1.0;
    [player prepareToPlay];
    [player play];
    _player = player;
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player != _player) return;
    _currentIndex += 1;
    [self playCurrentKey];
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    if (player != _player) return;
    _currentIndex += 1;
    [self playCurrentKey];
}

/// Fallback while the clips are still being rendered or the voice service is down.
- (void)speakWithAppleVoice:(NSString *)text {
    if (text.length == 0) { [self playNextCallAfter:0.2]; return; }
    if (!_appleVoice) {
        _appleVoice = [[AVSpeechSynthesizer alloc] init];
        _appleVoice.delegate = self;
    }
    BRRouletteDealerActivateAudioSession();
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
    // Speak in the language the text was localized to: the device language
    // only when the app really has a translation for it.
    NSString *localization = [self appLocale];
    NSString *preferred = NSLocale.preferredLanguages.firstObject ?: @"en-US";
    NSString *languagePrefix = [[localization substringToIndex:MIN((NSUInteger)2, localization.length)] lowercaseString];
    NSString *voiceLanguage = [preferred.lowercaseString hasPrefix:languagePrefix] ? preferred : @"en-US";
    utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:voiceLanguage] ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    utterance.pitchMultiplier = 0.9;
    [_appleVoice speakUtterance:utterance];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    [self playNextCallAfter:0.2];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance {
    // Cancelled by interrupt: the generation check stops the chain; nothing else to do.
}

#pragma mark - Stopping

- (void)interrupt {
    _generation += 1;
    [_queue removeAllObjects];
    _player.delegate = nil;
    [_player stop];
    _player = nil;
    if (_appleVoice.isSpeaking) [_appleVoice stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    _busy = NO;
}

- (void)shutdown {
    _shutdown = YES;
    [self interrupt];
    _appleVoice.delegate = nil;
}

@end
