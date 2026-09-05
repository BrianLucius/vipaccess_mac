import Foundation
import Security

/// Errors that can occur during keychain operations.
public enum KeychainError: LocalizedError {
    /// Neither the data protection keychain nor the legacy keychain has a credential.
    case credentialNotFound
    /// No VIPAccess.keychain-db file exists on disk.
    case legacyKeychainNotFound
    /// Legacy keychain password was rejected.
    case unlockFailed(OSStatus)
    /// Could not read the CredentialStore entry from the legacy keychain.
    case credentialReadFailed
    /// AES decryption of the legacy credential produced invalid data.
    case decryptionFailed
    /// Failed to write the migrated credential to the data protection keychain.
    case migrationStoreFailed(OSStatus)
    /// IOKit could not retrieve the Mac serial number.
    case serialNumberUnavailable

    public var errorDescription: String? {
        switch self {
        case .credentialNotFound:
            return "No VIP Access credential found in any keychain."
        case .legacyKeychainNotFound:
            return "Symantec VIPAccess legacy keychain not found."
        case .unlockFailed(let status):
            return "Failed to unlock legacy keychain (OSStatus \(status))."
        case .credentialReadFailed:
            return "Failed to read credential from legacy keychain."
        case .decryptionFailed:
            return "Failed to decrypt legacy keychain credential."
        case .migrationStoreFailed(let status):
            return "Failed to store migrated credential (OSStatus \(status))."
        case .serialNumberUnavailable:
            return "Unable to retrieve Mac serial number."
        }
    }
}

/// Manages the app's VIP Access credential in the macOS data protection keychain,
/// with fallback migration from the Symantec legacy keychain on first launch.
public class KeychainCredentialStore {
    private static let serviceName = "com.vipaccess.credential"
    private static let secretAccountName = "secret"
    private static let idAccountName = "id"

    public init() {}

    // MARK: - Public API

    /// Loads the credential using the two-path architecture:
    /// 1. Try the modern data protection keychain first.
    /// 2. If not found, fall back to migration from the legacy keychain.
    ///
    /// - Note: This method is **idempotent with respect to re-migration**. If the data
    ///   protection keychain entry is lost (e.g., app reinstall, keychain reset, manual
    ///   deletion), the next call will automatically re-migrate from the Symantec legacy
    ///   keychain. This works because:
    ///   - The legacy keychain is never modified (read-only access), so it is always
    ///     available as a migration source.
    ///   - `storeInDataProtectionKeychain` uses a delete-then-add pattern, so re-storing
    ///     the credential overwrites cleanly without duplicate-item errors.
    ///   - The migration path does not track "already migrated" state — it always reads
    ///     fresh from the legacy keychain.
    public func loadCredential() throws -> Credential {
        do {
            return try readFromDataProtectionKeychain()
        } catch let error as KeychainError where error.isItemNotFound {
            return try migrateFromLegacyKeychain()
        }
    }

    /// Reads the credential from the modern data protection keychain.
    /// Throws `KeychainError.credentialNotFound` if no entry exists.
    public func readFromDataProtectionKeychain() throws -> Credential {
        let secretData = try readKeychainItem(account: Self.secretAccountName)
        let idData = try readKeychainItem(account: Self.idAccountName)

        guard let id = String(data: idData, encoding: .utf8) else {
            throw KeychainError.credentialNotFound
        }

        let secretBase32 = secretData.base32EncodedString()

        return Credential(id: id, secret: secretData, secretBase32: secretBase32)
    }

    /// Stores a credential in the data protection keychain with `.whenUnlocked` accessibility.
    /// Stores the ID and secret as separate entries under the same service.
    public func storeInDataProtectionKeychain(credential: Credential) throws {
        guard let idData = credential.id.data(using: .utf8) else {
            throw KeychainError.migrationStoreFailed(errSecParam)
        }

        try storeKeychainItem(account: Self.idAccountName, data: idData)
        try storeKeychainItem(account: Self.secretAccountName, data: credential.secret)
    }

    /// Deletes the credential from the data protection keychain (both ID and secret entries).
    public func deleteFromDataProtectionKeychain() {
        deleteKeychainItem(account: Self.idAccountName)
        deleteKeychainItem(account: Self.secretAccountName)
    }

    /// Deletes the existing data protection keychain entry and performs a fresh migration
    /// from the legacy Symantec keychain.
    public func forceRemigrate() throws -> Credential {
        deleteFromDataProtectionKeychain()
        return try migrateFromLegacyKeychain()
    }

    // MARK: - Migration

    /// Performs migration from the Symantec VIPAccess legacy keychain.
    /// Reads, decrypts, and stores the credential in the data protection keychain.
    @available(macOS, deprecated: 10.10)
    private func migrateFromLegacyKeychain() throws -> Credential {
        let credential = try LegacyKeychainReader.readCredential()
        try storeInDataProtectionKeychain(credential: credential)
        return credential
    }

    // MARK: - Data Protection Keychain Helpers

    /// Reads a single keychain item by account name under the app's service.
    private func readKeychainItem(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.credentialNotFound
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.credentialNotFound
        default:
            throw KeychainError.credentialNotFound
        }
    }

    /// Stores a single keychain item. Deletes any existing entry first to avoid duplicates.
    private func storeKeychainItem(account: String, data: Data) throws {
        // Remove existing entry if present (ignore errors)
        deleteKeychainItem(account: account)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.migrationStoreFailed(status)
        }
    }

    /// Deletes a single keychain item by account name. Errors are silently ignored.
    private func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - KeychainError Helpers

extension KeychainError {
    /// Returns true if this error represents an item-not-found condition,
    /// which should trigger the migration fallback path.
    var isItemNotFound: Bool {
        switch self {
        case .credentialNotFound:
            return true
        default:
            return false
        }
    }
}

// MARK: - Base32 Encoding

extension Data {
    /// Encodes the data as a base32 string (RFC 4648).
    func base32EncodedString() -> String {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        let alphabetArray = Array(alphabet)
        var result = ""
        var buffer: UInt64 = 0
        var bitsLeft = 0

        for byte in self {
            buffer = (buffer << 8) | UInt64(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> bitsLeft) & 0x1F)
                result.append(alphabetArray[index])
            }
        }

        if bitsLeft > 0 {
            let index = Int((buffer << (5 - bitsLeft)) & 0x1F)
            result.append(alphabetArray[index])
        }

        // Add padding
        while result.count % 8 != 0 {
            result.append("=")
        }

        return result
    }
}


