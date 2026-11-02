// EZReferralManager.h
// EZCompleteUI
//
// Purpose:
//   Referral program plumbing: the signed-in user's own referral code,
//   redemption of a code entered at sign-up, and the Share App message
//   (install link matched to how this copy of the app was installed).
//   All coin grants happen server-side in the `referral` Edge Function —
//   the client only carries codes; it never mints coins.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZReferralManager : NSObject

/// YES when this copy was installed as a jailbreak package (bundle lives
/// in /Applications or /var/jb), NO for a sideloaded IPA (AltStore etc.).
+ (BOOL)isJailbreakInstall;

/// The install link matching this install type: the YouRepo repo address
/// for jailbreak installs, the one-tap AltStore source link for IPAs.
+ (NSString *)shareInstallLink;

/// Share-sheet text: the 200-coin offer, the user's referral code when
/// known, and the install link for this install type.
+ (NSString *)shareMessageWithReferralCode:(nullable NSString *)code;

/// The user's referral code as last fetched from the server, if any.
/// Codes are issued once by the server and never change, so this cache
/// is permanent once set.
+ (nullable NSString *)cachedReferralCode;

/// Fetches the signed-in user's referral code (or resolves immediately
/// with the cached one). Completion runs on the main queue; the code is
/// nil when signed out, or when the server is unreachable and no cache
/// exists yet.
+ (void)fetchReferralCodeWithCompletion:(void (^)(NSString * _Nullable code))completion;

/// Stores a code entered at sign-up so it can be redeemed once a session
/// exists (sign-up may require email confirmation before a session is
/// issued). Trimmed and upper-cased; empty input is ignored.
+ (void)stashPendingReferralCode:(NSString *)code;

/// Redeems the stashed code, if any, against the signed-in account.
/// Silent on every outcome: the server is idempotent (one redemption per
/// account, ever), a server verdict clears the stash, and only a
/// transport failure keeps it for the next launch. Safe to call at every
/// launch, after every sign-in, and whenever Settings opens.
+ (void)applyPendingReferralCode;

/// ElevenLabs link shown in Settings. See the constant in the .m — swap
/// in the PartnerStack tracking link there to earn commission.
+ (NSString *)elevenLabsAffiliateURL;

@end

NS_ASSUME_NONNULL_END
