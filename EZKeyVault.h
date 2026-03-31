// EZKeyVault.h
// EZCompleteUI
//
// Secure storage for sensitive API keys.
// Keys are encrypted with AES-256-GCM before being written to the Keychain.
// The wrapping key is itself stored in the Keychain, bound to this device.
//
// *** KEEP EZKeyVault.m OFF GITHUB ***
// This header is safe to commit. The implementation details that would allow
// an attacker to reverse the encryption must stay local.

#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonCryptor.h>

NS_ASSUME_NONNULL_BEGIN

/// Identifier constants — use these everywhere so the strings stay in sync.
extern NSString * const EZVaultKeyOpenAI;
extern NSString * const EZVaultKeyElevenLabs;

@interface EZKeyVault : NSObject

/// Save (or overwrite) a plaintext API key, encrypting it before storage.
/// @param key        The plaintext key string to protect.
/// @param identifier One of the EZVaultKey* constants.
/// @return YES on success.
+ (BOOL)saveKey:(NSString *)key forIdentifier:(NSString *)identifier;

/// Load and decrypt a previously saved API key.
/// @param identifier One of the EZVaultKey* constants.
/// @return The plaintext key, or nil if not found or decryption failed.
+ (nullable NSString *)loadKeyForIdentifier:(NSString *)identifier;

/// Delete a stored key entirely.
+ (BOOL)deleteKeyForIdentifier:(NSString *)identifier;

/// Returns YES if a key has been stored for the given identifier.
+ (BOOL)hasKeyForIdentifier:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
