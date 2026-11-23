// EZKeyVault.h
// EZCompleteUI
//
// Secure storage for the app's session tokens and a few small values:
// the Supabase access and refresh tokens, the user ID, the installation
// ID, and the support contact address. Values are stored in the iOS
// Keychain; if a Keychain write fails, an encrypted file is used as a
// fallback.
//
// This class originally stored user-supplied OpenAI and ElevenLabs API
// keys from the bring-your-own-key era. Nothing has been stored under
// those identifiers since the app moved to Supabase, and the constants
// were removed with this header.

#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonCryptor.h>

NS_ASSUME_NONNULL_BEGIN

/// Identifier constants — use these everywhere so the strings stay in sync.
/// Support contact address — value seeded only from EZKeyVault.m (never in open-source files).
extern NSString * const EZVaultKeySupportEmail;
extern NSString * const EZVaultKeyAccessToken;
extern NSString * const EZVaultKeyRefreshToken;
extern NSString * const EZVaultKeyUserId;
/// A random, per-installation identifier retained in the Keychain. It is used
/// only by Supabase to enforce one welcome-credit claim per device install.
extern NSString * const EZVaultKeyInstallationID;


@interface EZKeyVault : NSObject

/// Save (or overwrite) a value, protected before storage.
/// @param key        The plaintext value to protect.
/// @param identifier One of the EZVaultKey* constants.
/// @return YES on success.
+ (BOOL)saveKey:(NSString *)key forIdentifier:(NSString *)identifier;

/// Load a previously saved value.
/// @param identifier One of the EZVaultKey* constants.
/// @return The plaintext key, or nil if not found or decryption failed.
+ (nullable NSString *)loadKeyForIdentifier:(NSString *)identifier;

/// Delete a stored key entirely.
+ (BOOL)deleteKeyForIdentifier:(NSString *)identifier;

/// Returns YES if a key has been stored for the given identifier.
+ (BOOL)hasKeyForIdentifier:(NSString *)identifier;

/// Seeds the support contact email into the vault on first run.
/// The actual address is defined only in EZKeyVault.m (kept off GitHub).
/// Safe to call every launch — does nothing if the address is already stored.
+ (void)seedSupportEmailIfNeeded;

@end

NS_ASSUME_NONNULL_END
