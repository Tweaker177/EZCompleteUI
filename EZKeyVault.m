    //
    //  EZKeyVault.m
    //

    #import "EZKeyVault.h"
    #import <Security/Security.h>
    #import <CommonCrypto/CommonCryptor.h>
    #import <CommonCrypto/CommonHMAC.h>
    #import <CommonCrypto/CommonRandom.h>
    #import "helpers.h"

    // Public identifiers
NSString * const EZVaultKeyAccessToken  = @"com.ezcompelteui.auth.accesstoken";
NSString * const EZVaultKeyRefreshToken = @"com.ezcompleteui.auth.refreshtoken";
NSString * const EZVaultKeyUserId       = @"com.ezcompleteui.auth.userid";
NSString * const EZVaultKeyInstallationID = @"com.ezcompleteui.auth.installationid";


    // Internal labels
    static NSString * const kEZVaultService       = @"com.apple.cache.db7f3";
    static NSString * const kEZWrappingKeyAccount = @"p0";

    // Crypto sizes
    static const size_t kKeyLength  = 32;
    static const size_t kIVLength   = 16;
    static const size_t kHMACLength = 32;

    @implementation EZKeyVault

    #pragma mark - Public API

NSString * const EZVaultKeySupportEmail = @"ez.support.email";

+ (void)seedSupportEmailIfNeeded {
    if (![self hasKeyForIdentifier:EZVaultKeySupportEmail]) {
        [self saveKey:@"support@mail.ezcompleteai.com" forIdentifier:EZVaultKeySupportEmail];
    }
}

    + (BOOL)saveKey:(NSString *)key forIdentifier:(NSString *)identifier {
        if (!key.length || !identifier.length) return NO;

        NSData *masterKey = [self wrappingKey];
        if (!masterKey) {
            EZLog(EZLogLevelError, @"EZKeyVault", @"Wrapping key unavailable");
            return NO;
        }

        NSData *plaintext = [key dataUsingEncoding:NSUTF8StringEncoding];
        if (!plaintext) {
            EZLog(EZLogLevelError, @"EZKeyVault", @"String encoding failed");
            return NO;
        }

        NSData *blob = [self encryptData:plaintext withKey:masterKey];
        if (!blob) {
            EZLogf(EZLogLevelError, @"EZKeyVault", @"Encryption failed for %@", identifier);
            return NO;
        }

        if (![self saveBlob:blob forAccount:identifier]) {
            EZLog(EZLogLevelError, @"EZKeyVault", @"Keychain save failed, falling back");
            return [self fallbackSaveKey:blob forIdentifier:identifier];
        }

        return YES;
    }

    + (nullable NSString *)loadKeyForIdentifier:(NSString *)identifier {
        if (!identifier.length) return nil;

        NSData *blob = [self loadBlobForAccount:identifier];
        if (!blob) {
            blob = [self fallbackLoadKeyForIdentifier:identifier];
            if (!blob) return nil;
        }

        NSData *masterKey = [self wrappingKey];
        if (!masterKey) {
            EZLog(EZLogLevelError, @"EZKeyVault", @"Wrapping key missing");
            return nil;
        }

        NSData *plaintext = [self decryptBlob:blob withKey:masterKey];
        if (!plaintext) {
            EZLogf(EZLogLevelWarning, @"EZKeyVault", @"Decrypt failed for %@", identifier);
            return nil;
        }

        return [[NSString alloc] initWithData:plaintext encoding:NSUTF8StringEncoding];
    }

    + (BOOL)deleteKeyForIdentifier:(NSString *)identifier {
        if (!identifier.length) return YES;

        NSDictionary *query = @{
            (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: kEZVaultService,
            (__bridge id)kSecAttrAccount: identifier
        };

        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);

        if (status != errSecSuccess && status != errSecItemNotFound) {
            EZLogf(EZLogLevelWarning, @"EZKeyVault", @"Delete failed (%d) for %@", (int)status, identifier);
        }

        // Also remove fallback file if exists
        NSString *path = [self fallbackFilePathForIdentifier:identifier];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }

        return (status == errSecSuccess || status == errSecItemNotFound);
    }

    + (BOOL)hasKeyForIdentifier:(NSString *)identifier {
        return ([self loadBlobForAccount:identifier] != nil || [self fallbackLoadKeyForIdentifier:identifier] != nil);
    }

    #pragma mark - Wrapping Key

    + (nullable NSData *)wrappingKey {
        NSData *existing = [self loadBlobForAccount:kEZWrappingKeyAccount];
        if (existing && existing.length == kKeyLength) {
            return existing;
        }

        NSMutableData *key = [NSMutableData dataWithLength:kKeyLength];
        if (CCRandomGenerateBytes(key.mutableBytes, kKeyLength) != kCCSuccess) {
            EZLog(EZLogLevelError, @"EZKeyVault", @"Random key generation failed");
            return nil;
        }

        if (![self saveBlob:key forAccount:kEZWrappingKeyAccount]) {
            EZLog(EZLogLevelError, @"EZKeyVault", @"Failed to persist wrapping key");
            return nil;
        }

        return [key copy];
    }

    #pragma mark - Crypto

    + (nullable NSData *)encryptData:(NSData *)data withKey:(NSData *)key {
        if (!data.length || key.length != kKeyLength) return nil;

        NSMutableData *iv = [NSMutableData dataWithLength:kIVLength];
        if (CCRandomGenerateBytes(iv.mutableBytes, kIVLength) != kCCSuccess) {
            EZLog(EZLogLevelError, @"EZKeyVault", @"IV generation failed");
            return nil;
        }

        size_t outLen = data.length + kCCBlockSizeAES128;
        NSMutableData *cipher = [NSMutableData dataWithLength:outLen];

        size_t moved = 0;
        CCCryptorStatus status = CCCrypt(
            kCCEncrypt,
            kCCAlgorithmAES,
            kCCOptionPKCS7Padding,
            key.bytes,
            key.length,
            iv.bytes,
            data.bytes,
            data.length,
            cipher.mutableBytes,
            cipher.length,
            &moved
        );

        if (status != kCCSuccess) {
            EZLogf(EZLogLevelError, @"EZKeyVault", @"AES encrypt failed (%d)", (int)status);
            return nil;
        }

        cipher.length = moved;

        uint8_t mac[kHMACLength];
        CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, cipher.bytes, cipher.length, mac);

        NSMutableData *blob = [NSMutableData data];
        [blob appendData:iv];
        [blob appendBytes:mac length:kHMACLength];
        [blob appendData:cipher];

        return blob;
    }

    + (nullable NSData *)decryptBlob:(NSData *)blob withKey:(NSData *)key {
        if (!blob.length || blob.length <= kIVLength + kHMACLength) return nil;
        if (key.length != kKeyLength) return nil;

        const uint8_t *bytes = blob.bytes;

        NSData *iv = [NSData dataWithBytes:bytes length:kIVLength];
        NSData *mac = [NSData dataWithBytes:bytes + kIVLength length:kHMACLength];
        NSData *cipher = [NSData dataWithBytes:bytes + kIVLength + kHMACLength
                                        length:blob.length - kIVLength - kHMACLength];

        uint8_t calc[kHMACLength];
        CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, cipher.bytes, cipher.length, calc);

        if (memcmp(calc, mac.bytes, kHMACLength) != 0) {
            EZLog(EZLogLevelWarning, @"EZKeyVault", @"HMAC mismatch");
            return nil;
        }

        NSMutableData *plain = [NSMutableData dataWithLength:cipher.length];
        size_t moved = 0;

        CCCryptorStatus status = CCCrypt(
            kCCDecrypt,
            kCCAlgorithmAES,
            kCCOptionPKCS7Padding,
            key.bytes,
            key.length,
            iv.bytes,
            cipher.bytes,
            cipher.length,
            plain.mutableBytes,
            plain.length,
            &moved
        );

        if (status != kCCSuccess) {
            EZLogf(EZLogLevelError, @"EZKeyVault", @"AES decrypt failed (%d)", (int)status);
            return nil;
        }

        plain.length = moved;
        return plain;
    }

    #pragma mark - Keychain (robust against -34018)

    + (BOOL)saveBlob:(NSData *)blob forAccount:(NSString *)account {
        if (!blob.length || !account.length) return NO;

        NSMutableDictionary *query = [@{
            (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: kEZVaultService,
            (__bridge id)kSecAttrAccount: account
        } mutableCopy];

        NSDictionary *update = @{
            (__bridge id)kSecValueData: blob
        };

        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                       (__bridge CFDictionaryRef)update);

        if (status == errSecSuccess) return YES;

        NSArray *accessLevels = @[
            (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            (__bridge id)kSecAttrAccessibleWhenUnlocked,
            (__bridge id)kSecAttrAccessibleAfterFirstUnlock
        ];

        for (id accessibility in accessLevels) {
            NSMutableDictionary *add = [query mutableCopy];
            add[(__bridge id)kSecValueData] = blob;
            add[(__bridge id)kSecAttrAccessible] = accessibility;
            add[(__bridge id)kSecAttrSynchronizable] = @NO;

            status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);

            if (status == errSecSuccess) return YES;

            EZLogf(EZLogLevelWarning, @"EZKeyVault",
                   @"SecItemAdd failed (%d) for %@", (int)status, account);
        }

        // Minimal fallback
        NSDictionary *minimal = @{
            (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: account,
            (__bridge id)kSecValueData:   blob
        };

        status = SecItemAdd((__bridge CFDictionaryRef)minimal, NULL);

        if (status == errSecSuccess) {
            EZLog(EZLogLevelWarning, @"EZKeyVault", @"Saved using minimal query fallback");
            return YES;
        }

        EZLogf(EZLogLevelError, @"EZKeyVault",
               @"SecItemAdd failed permanently (%d) for %@", (int)status, account);

        return NO;
    }

    + (nullable NSData *)loadBlobForAccount:(NSString *)account {
        if (!account.length) return nil;

        NSArray *queries = @[
            @{
                (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService: kEZVaultService,
                (__bridge id)kSecAttrAccount: account,
                (__bridge id)kSecReturnData:  @YES,
                (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne
            },
            @{
                (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrAccount: account,
                (__bridge id)kSecReturnData:  @YES,
                (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne
            }
        ];

        for (NSDictionary *query in queries) {
            CFTypeRef result = NULL;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);

            if (status == errSecSuccess && result) {
                return (__bridge_transfer NSData *)result;
            }
        }

        return nil;
    }

    #pragma mark - Fallback File Storage

    + (NSString *)fallbackFilePathForIdentifier:(NSString *)identifier {
        NSString *dir = @"/var/mobile/Library/ApplicationSupport/EZCompleteUI";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *fileName = [NSString stringWithFormat:@"log_%@.dat", identifier];
        return [dir stringByAppendingPathComponent:fileName];
    }

    + (BOOL)fallbackSaveKey:(NSData *)data forIdentifier:(NSString *)identifier {
        if (!data.length || !identifier.length) return NO;
        NSString *path = [self fallbackFilePathForIdentifier:identifier];
        BOOL success = [data writeToFile:path atomically:YES];
        if (!success) EZLogf(EZLogLevelError, @"EZKeyVault", @"Fallback save failed for %@", identifier);
        return success;
    }

    + (nullable NSData *)fallbackLoadKeyForIdentifier:(NSString *)identifier {
        NSString *path = [self fallbackFilePathForIdentifier:identifier];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) EZLogf(EZLogLevelWarning, @"EZKeyVault", @"Fallback load failed for %@", identifier);
        return data;
    }

    @end
