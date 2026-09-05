import XCTest
@testable import VIPAccess

final class KeychainCredentialStoreTests: XCTestCase {

    private var store: KeychainCredentialStore!

    override func setUp() {
        super.setUp()
        store = KeychainCredentialStore()
    }

    override func tearDown() {
        // Always clean up keychain entries after each test to avoid polluting the system keychain.
        store.deleteFromDataProtectionKeychain()
        store = nil
        super.tearDown()
    }

    // MARK: - Base32 Encoding Tests

    /// Verify that "12345678901234567890" (20 bytes) encodes to the RFC 4648 expected value.
    func testBase32Encoding_knownValues() {
        let input = Data("12345678901234567890".utf8)
        let encoded = input.base32EncodedString()
        XCTAssertEqual(encoded, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    }

    /// Verify base32 encoding of an empty Data produces an empty string.
    func testBase32Encoding_emptyData() {
        let input = Data()
        let encoded = input.base32EncodedString()
        XCTAssertEqual(encoded, "")
    }

    /// Verify base32 encoding of a single byte.
    func testBase32Encoding_singleByte() {
        // 'f' (0x66) → base32 "MY======"
        let input = Data("f".utf8)
        let encoded = input.base32EncodedString()
        XCTAssertEqual(encoded, "MY======")
    }

    /// Verify base32 encoding of "foobar" → "MZXW6YTBOI======"
    func testBase32Encoding_foobar() {
        let input = Data("foobar".utf8)
        let encoded = input.base32EncodedString()
        XCTAssertEqual(encoded, "MZXW6YTBOI======")
    }

    // MARK: - Store and Read Credential

    /// Store a credential, read it back, verify all fields match.
    func testStoreAndReadCredential() throws {
        let secret = Data("12345678901234567890".utf8)
        let credential = Credential(
            id: "SYMC12345678",
            secret: secret,
            secretBase32: secret.base32EncodedString()
        )

        try store.storeInDataProtectionKeychain(credential: credential)
        let loaded = try store.readFromDataProtectionKeychain()

        XCTAssertEqual(loaded.id, credential.id)
        XCTAssertEqual(loaded.secret, credential.secret)
        XCTAssertEqual(loaded.secretBase32, credential.secretBase32)
    }

    // MARK: - Read From Empty Keychain

    /// Ensure reading when nothing is stored throws credentialNotFound.
    func testReadFromEmptyKeychain_throwsCredentialNotFound() {
        // Ensure keychain is clean
        store.deleteFromDataProtectionKeychain()

        XCTAssertThrowsError(try store.readFromDataProtectionKeychain()) { error in
            guard let keychainError = error as? KeychainError else {
                XCTFail("Expected KeychainError, got \(error)")
                return
            }
            switch keychainError {
            case .credentialNotFound:
                break // Expected
            default:
                XCTFail("Expected .credentialNotFound, got \(keychainError)")
            }
        }
    }

    // MARK: - Delete Credential

    /// Store then delete, verify read fails with credentialNotFound.
    func testDeleteCredential() throws {
        let secret = Data("testsecret123456".utf8)
        let credential = Credential(
            id: "SYMC99999999",
            secret: secret,
            secretBase32: secret.base32EncodedString()
        )

        try store.storeInDataProtectionKeychain(credential: credential)

        // Verify it was stored
        let loaded = try store.readFromDataProtectionKeychain()
        XCTAssertEqual(loaded.id, credential.id)

        // Delete
        store.deleteFromDataProtectionKeychain()

        // Verify it's gone
        XCTAssertThrowsError(try store.readFromDataProtectionKeychain()) { error in
            guard let keychainError = error as? KeychainError else {
                XCTFail("Expected KeychainError, got \(error)")
                return
            }
            switch keychainError {
            case .credentialNotFound:
                break // Expected
            default:
                XCTFail("Expected .credentialNotFound, got \(keychainError)")
            }
        }
    }

    // MARK: - Force Remigrate

    /// Verify forceRemigrate deletes existing entry and falls through to migration.
    /// Since LegacyKeychainReader is a stub that throws .legacyKeychainNotFound,
    /// forceRemigrate should delete the existing entry and then throw .legacyKeychainNotFound.
    /// On machines where VIPAccess.keychain-db exists, it may throw .credentialReadFailed instead.
    func testForceRemigrate_deletesExistingAndFallsToMigration() throws {
        let secret = Data("existingsecret12".utf8)
        let credential = Credential(
            id: "SYMCEXISTING",
            secret: secret,
            secretBase32: secret.base32EncodedString()
        )

        // Store a credential first
        try store.storeInDataProtectionKeychain(credential: credential)

        // forceRemigrate should delete existing and attempt migration (which throws)
        XCTAssertThrowsError(try store.forceRemigrate()) { error in
            guard let keychainError = error as? KeychainError else {
                XCTFail("Expected KeychainError, got \(error)")
                return
            }
            switch keychainError {
            case .legacyKeychainNotFound, .credentialReadFailed, .unlockFailed:
                break // Expected — migration fails because keychain is absent or unreadable
            default:
                XCTFail("Expected migration failure error, got \(keychainError)")
            }
        }

        // Verify the existing credential was deleted (the deletion part of forceRemigrate worked)
        XCTAssertThrowsError(try store.readFromDataProtectionKeychain()) { error in
            guard let keychainError = error as? KeychainError else {
                XCTFail("Expected KeychainError, got \(error)")
                return
            }
            switch keychainError {
            case .credentialNotFound:
                break // Expected — the entry was deleted
            default:
                XCTFail("Expected .credentialNotFound, got \(keychainError)")
            }
        }
    }

    // MARK: - loadCredential Two-Path Architecture

    /// When credential exists in data protection keychain, loadCredential returns it
    /// without attempting migration.
    func testLoadCredential_readsFromDataProtectionFirst() throws {
        let secret = Data("primarysecret123".utf8)
        let credential = Credential(
            id: "SYMCPRIMARY1",
            secret: secret,
            secretBase32: secret.base32EncodedString()
        )

        try store.storeInDataProtectionKeychain(credential: credential)
        let loaded = try store.loadCredential()

        XCTAssertEqual(loaded.id, credential.id)
        XCTAssertEqual(loaded.secret, credential.secret)
        XCTAssertEqual(loaded.secretBase32, credential.secretBase32)
    }

    /// With nothing stored in data protection keychain, loadCredential should attempt
    /// migration. Since LegacyKeychainReader is a stub, it throws .legacyKeychainNotFound.
    /// On machines where VIPAccess.keychain-db exists, it may throw .credentialReadFailed instead.
    func testLoadCredential_fallsBackToMigration_whenNotInDataProtection() {
        // Ensure data protection keychain is empty
        store.deleteFromDataProtectionKeychain()

        XCTAssertThrowsError(try store.loadCredential()) { error in
            guard let keychainError = error as? KeychainError else {
                XCTFail("Expected KeychainError, got \(error)")
                return
            }
            switch keychainError {
            case .legacyKeychainNotFound, .credentialReadFailed, .unlockFailed:
                break // Expected — fallback to migration, which fails
            default:
                XCTFail("Expected migration failure error, got \(keychainError)")
            }
        }
    }

    // MARK: - Error Handling

    /// Verify KeychainError.isItemNotFound returns true only for .credentialNotFound.
    func testKeychainError_isItemNotFound() {
        XCTAssertTrue(KeychainError.credentialNotFound.isItemNotFound)
        XCTAssertFalse(KeychainError.legacyKeychainNotFound.isItemNotFound)
        XCTAssertFalse(KeychainError.unlockFailed(-25293).isItemNotFound)
        XCTAssertFalse(KeychainError.credentialReadFailed.isItemNotFound)
        XCTAssertFalse(KeychainError.decryptionFailed.isItemNotFound)
        XCTAssertFalse(KeychainError.migrationStoreFailed(-25299).isItemNotFound)
        XCTAssertFalse(KeychainError.serialNumberUnavailable.isItemNotFound)
    }

    /// Verify all KeychainError cases have non-nil errorDescription.
    func testKeychainError_errorDescriptions() {
        let errors: [KeychainError] = [
            .credentialNotFound,
            .legacyKeychainNotFound,
            .unlockFailed(-25293),
            .credentialReadFailed,
            .decryptionFailed,
            .migrationStoreFailed(-25299),
            .serialNumberUnavailable,
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have an errorDescription")
            XCTAssertFalse(error.errorDescription!.isEmpty, "\(error) errorDescription should not be empty")
        }
    }

    // MARK: - Overwrite Behavior

    /// Storing a credential twice should overwrite the first entry without error.
    func testStoreCredential_overwritesExisting() throws {
        let secret1 = Data("firstsecret12345".utf8)
        let cred1 = Credential(
            id: "SYMCFIRST001",
            secret: secret1,
            secretBase32: secret1.base32EncodedString()
        )

        let secret2 = Data("secondsecret1234".utf8)
        let cred2 = Credential(
            id: "SYMCSECOND02",
            secret: secret2,
            secretBase32: secret2.base32EncodedString()
        )

        try store.storeInDataProtectionKeychain(credential: cred1)
        try store.storeInDataProtectionKeychain(credential: cred2)

        let loaded = try store.readFromDataProtectionKeychain()
        XCTAssertEqual(loaded.id, cred2.id)
        XCTAssertEqual(loaded.secret, cred2.secret)
    }
}
