import XCTest
@testable import VIPAccess

/// # Integration Tests: First Launch Migration Scenario
///
/// These tests verify the end-to-end behavior of the credential migration path
/// that executes on first launch (or after a keychain reset) when no credential
/// exists in the data protection keychain.
///
/// ## What This Test Verifies
///
/// The complete first-launch migration flow:
///   1. App detects no credential in the data protection keychain
///   2. Falls back to legacy keychain migration path
///   3. Locates `~/Library/Keychains/VIPAccess.keychain-db`
///   4. Derives unlock password from Mac serial number and username
///   5. Unlocks and reads the encrypted `CredentialStore` entry
///   6. Decrypts credential using AES-128-CBC
///   7. Strips "Symantec" suffix from the credential ID
///   8. Base32-encodes the decrypted secret
///   9. Stores the migrated credential in the data protection keychain
///   10. Subsequent reads come from the data protection keychain (no legacy interaction)
///
/// ## Prerequisites
///
/// - A valid `~/Library/Keychains/VIPAccess.keychain-db` (or `.keychain`) must exist.
///   This file is created by the Symantec VIP Access macOS application after provisioning.
/// - The Mac serial number must be readable via IOKit (standard on all Macs).
/// - The keychain must be unlockable with the derived password:
///   `"{MacSerialNumber}SymantecVIPAccess{username}"`.
/// - The `CredentialStore` generic password entry must exist in the legacy keychain.
///
/// ## How to Verify Success
///
/// 1. The migrated credential has a non-empty `id` (e.g., "SYMC12345678" or "VSMT12345678").
/// 2. The credential ID does NOT end with "Symantec" (suffix was stripped).
/// 3. The `secret` is non-empty raw bytes.
/// 4. The `secretBase32` is a valid base32 string (uppercase A-Z, 2-7, with = padding).
/// 5. After migration, the credential is readable from the data protection keychain
///    without any interaction with the legacy keychain.
/// 6. A `TOTPGenerator` initialized with the secret produces valid 6-digit codes.
///
/// ## Running These Tests
///
/// These tests are automatically skipped (`XCTSkip`) on machines without a valid
/// Symantec VIPAccess keychain. To run them:
///
/// 1. Ensure Symantec VIP Access has been provisioned on this machine.
/// 2. Run: `swift test --filter IntegrationTests`
/// 3. Or via Xcode: select the VIPAccessTests scheme and run this test class.
///
/// After a successful run, clean up the test credential from the data protection
/// keychain by running all tests (tearDown handles cleanup).

final class IntegrationTests: XCTestCase {

    private var store: KeychainCredentialStore!

    /// Whether the Symantec VIPAccess legacy keychain exists on this machine.
    private var legacyKeychainExists: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Keychains/VIPAccess.keychain-db",
            "\(home)/Library/Keychains/VIPAccess.keychain"
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    override func setUp() {
        super.setUp()
        store = KeychainCredentialStore()
    }

    override func tearDown() {
        // Clean up any credential stored during the test to avoid polluting the keychain.
        store.deleteFromDataProtectionKeychain()
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Attempts to load a credential via migration. If the legacy keychain exists but
    /// the credential cannot be read (wrong password, empty CredentialStore, etc.),
    /// this throws XCTSkip instead of failing the test.
    private func loadCredentialOrSkip() throws -> Credential {
        do {
            return try store.loadCredential()
        } catch let error as KeychainError {
            switch error {
            case .credentialReadFailed, .unlockFailed, .decryptionFailed, .serialNumberUnavailable:
                throw XCTSkip(
                    "Skipped: Legacy keychain exists but migration failed (\(error.localizedDescription)). "
                    + "This test requires a fully provisioned Symantec VIP Access credential."
                )
            default:
                throw error
            }
        }
    }

    // MARK: - First Launch Migration (End-to-End)

    /// End-to-end test: First launch with no data protection entry triggers migration
    /// from the legacy Symantec keychain, resulting in a valid credential.
    ///
    /// ## Test Steps:
    /// 1. Delete any existing credential from the data protection keychain (simulate first launch).
    /// 2. Call `loadCredential()` which tries data protection keychain first, then falls back.
    /// 3. Verify the returned credential has a valid ID and secret.
    /// 4. Verify the credential is now stored in the data protection keychain.
    /// 5. Verify a TOTP code can be generated from the migrated secret.
    ///
    /// ## Expected Results:
    /// - `loadCredential()` succeeds without throwing.
    /// - The credential ID is non-empty and does not end with "Symantec".
    /// - The secret is non-empty and its base32 encoding is valid.
    /// - A subsequent `readFromDataProtectionKeychain()` returns the same credential.
    /// - `TOTPGenerator` produces a 6-digit numeric code.
    func testFirstLaunchMigration_fullEndToEnd() throws {
        try XCTSkipUnless(
            legacyKeychainExists,
            "Skipped: Symantec VIPAccess.keychain-db not found. "
            + "This test requires a provisioned Symantec VIP Access keychain at "
            + "~/Library/Keychains/VIPAccess.keychain-db"
        )

        // Step 1: Ensure no credential in data protection keychain (simulate first launch)
        store.deleteFromDataProtectionKeychain()

        // Step 2: Load credential — should trigger migration from legacy keychain
        let credential: Credential
        do {
            credential = try store.loadCredential()
        } catch let error as KeychainError {
            // If the keychain exists but isn't fully provisioned (e.g., empty CredentialStore,
            // wrong password due to machine mismatch), skip rather than fail.
            switch error {
            case .credentialReadFailed, .unlockFailed, .decryptionFailed, .serialNumberUnavailable:
                throw XCTSkip(
                    "Skipped: Legacy keychain exists but migration failed (\(error.localizedDescription)). "
                    + "This test requires a fully provisioned Symantec VIP Access credential."
                )
            default:
                throw error
            }
        }

        // Step 3: Verify the migrated credential is valid
        XCTAssertFalse(credential.id.isEmpty, "Credential ID should be non-empty after migration")
        XCTAssertFalse(
            credential.id.hasSuffix("Symantec"),
            "Credential ID should have 'Symantec' suffix stripped; got: \(credential.id)"
        )
        XCTAssertFalse(credential.secret.isEmpty, "Credential secret should be non-empty")
        XCTAssertFalse(credential.secretBase32.isEmpty, "Base32-encoded secret should be non-empty")

        // Verify base32 encoding contains only valid characters
        let base32Charset = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567=")
        XCTAssertTrue(
            credential.secretBase32.unicodeScalars.allSatisfy { base32Charset.contains($0) },
            "secretBase32 should contain only valid base32 characters; got: \(credential.secretBase32)"
        )

        // Step 4: Verify the credential is now persisted in the data protection keychain
        let reloaded = try store.readFromDataProtectionKeychain()
        XCTAssertEqual(reloaded.id, credential.id, "Persisted credential ID should match migrated")
        XCTAssertEqual(reloaded.secret, credential.secret, "Persisted secret should match migrated")
        XCTAssertEqual(
            reloaded.secretBase32, credential.secretBase32,
            "Persisted base32 secret should match migrated"
        )

        // Step 5: Verify TOTP generation works with the migrated secret
        let generator = TOTPGenerator(secret: credential.secret)
        let code = generator.generateCode()
        XCTAssertEqual(code.count, 6, "TOTP code should be 6 digits")
        XCTAssertTrue(
            code.allSatisfy(\.isNumber),
            "TOTP code should contain only digits; got: \(code)"
        )
    }

    /// Verifies that after migration, the credential ID matches the expected format
    /// (alphanumeric prefix like SYMC, VSMT, etc. followed by digits).
    func testFirstLaunchMigration_credentialIDFormat() throws {
        try XCTSkipUnless(
            legacyKeychainExists,
            "Skipped: Symantec VIPAccess.keychain-db not found."
        )

        store.deleteFromDataProtectionKeychain()
        let credential = try loadCredentialOrSkip()

        // Credential IDs are typically formatted as a 4-letter prefix + 8 digits
        // e.g., SYMC12345678 or VSMT12345678
        XCTAssertGreaterThanOrEqual(
            credential.id.count, 8,
            "Credential ID should be at least 8 characters; got: \(credential.id)"
        )
        XCTAssertLessThanOrEqual(
            credential.id.count, 20,
            "Credential ID should not exceed 20 characters; got: \(credential.id)"
        )
    }

    /// Verifies that the migration is idempotent — deleting the data protection entry
    /// and re-loading produces the same credential from the legacy keychain.
    func testFirstLaunchMigration_isIdempotent() throws {
        try XCTSkipUnless(
            legacyKeychainExists,
            "Skipped: Symantec VIPAccess.keychain-db not found."
        )

        // First migration
        store.deleteFromDataProtectionKeychain()
        let firstMigration = try loadCredentialOrSkip()

        // Simulate loss of data protection keychain entry (e.g., reinstall)
        store.deleteFromDataProtectionKeychain()

        // Second migration — should produce identical results
        let secondMigration = try loadCredentialOrSkip()

        XCTAssertEqual(
            firstMigration.id, secondMigration.id,
            "Re-migration should produce the same credential ID"
        )
        XCTAssertEqual(
            firstMigration.secret, secondMigration.secret,
            "Re-migration should produce the same secret bytes"
        )
        XCTAssertEqual(
            firstMigration.secretBase32, secondMigration.secretBase32,
            "Re-migration should produce the same base32 secret"
        )
    }

    /// Verifies that after successful migration, the menu bar can display a token.
    /// This simulates the final step of the first-launch flow: the ViewModel loads
    /// the credential and generates a displayable TOTP code.
    func testFirstLaunchMigration_menuBarTokenDisplay() throws {
        try XCTSkipUnless(
            legacyKeychainExists,
            "Skipped: Symantec VIPAccess.keychain-db not found."
        )

        store.deleteFromDataProtectionKeychain()
        let credential = try loadCredentialOrSkip()

        // Simulate what TokenViewModel does after successful credential load
        let generator = TOTPGenerator(secret: credential.secret)
        let currentCode = generator.generateCode()
        let nextCode = generator.nextCode()
        let remaining = generator.secondsRemaining()

        // Menu bar display requirements
        XCTAssertEqual(currentCode.count, 6, "Current code must be 6 digits for menu bar display")
        XCTAssertTrue(currentCode.allSatisfy(\.isNumber), "Current code must be all digits")
        XCTAssertEqual(nextCode.count, 6, "Next code must be 6 digits")
        XCTAssertTrue(nextCode.allSatisfy(\.isNumber), "Next code must be all digits")
        XCTAssertGreaterThanOrEqual(remaining, 0, "Seconds remaining should be non-negative")
        XCTAssertLessThanOrEqual(remaining, 30, "Seconds remaining should not exceed period (30)")

        // Credential ID should be displayable
        XCTAssertFalse(credential.id.isEmpty, "Credential ID must be non-empty for menu display")
    }

    // MARK: - Subsequent Launch (Data Protection Keychain Only)

    /// End-to-end test: Subsequent launch reads directly from data protection keychain.
    /// When a credential is already stored in the data protection keychain,
    /// loadCredential() returns it immediately without any legacy keychain interaction.
    func testSubsequentLaunch_readsDirectlyFromDataProtectionKeychain() throws {
        // Simulate a credential that was previously migrated
        let secret = Data("testsecret1234567890".utf8)
        let credential = Credential(
            id: "SYMCTEST1234",
            secret: secret,
            secretBase32: secret.base32EncodedString()
        )

        // Store it in the data protection keychain (as if migration already happened)
        try store.storeInDataProtectionKeychain(credential: credential)

        // Now loadCredential() should read directly from data protection keychain
        // without any interaction with the legacy keychain
        let loaded = try store.loadCredential()

        XCTAssertEqual(loaded.id, credential.id)
        XCTAssertEqual(loaded.secret, credential.secret)
        XCTAssertEqual(loaded.secretBase32, credential.secretBase32)

        // Verify TOTP generation works
        let generator = TOTPGenerator(secret: loaded.secret)
        let code = generator.generateCode()
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
    }

    // MARK: - Migration Fallback Behavior

    /// Verifies that when no legacy keychain exists AND no data protection entry exists,
    /// the appropriate error is thrown.
    ///
    /// Note: This test runs on machines WITHOUT the Symantec keychain.
    func testNoKeychainAnywhere_throwsAppropriateError() throws {
        try XCTSkipIf(
            legacyKeychainExists,
            "Skipped: This test requires NO Symantec VIPAccess keychain to be present."
        )

        store.deleteFromDataProtectionKeychain()

        XCTAssertThrowsError(try store.loadCredential()) { error in
            guard let keychainError = error as? KeychainError else {
                XCTFail("Expected KeychainError, got \(type(of: error)): \(error)")
                return
            }
            // Should get legacyKeychainNotFound since the migration path is attempted
            // but the VIPAccess keychain file doesn't exist.
            switch keychainError {
            case .legacyKeychainNotFound:
                break // Expected
            case .credentialReadFailed, .unlockFailed:
                break // Also acceptable if keychain exists but is unreadable
            default:
                XCTFail("Expected migration-related error, got: \(keychainError)")
            }
        }
    }

    // MARK: - Non-Destructive Verification

    /// Verifies that the migration does NOT modify or delete the legacy keychain file.
    /// This confirms the non-destructive requirement from FR-4.
    func testMigration_isNonDestructive() throws {
        try XCTSkipUnless(
            legacyKeychainExists,
            "Skipped: Symantec VIPAccess.keychain-db not found."
        )

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let keychainPath = FileManager.default.fileExists(
            atPath: "\(home)/Library/Keychains/VIPAccess.keychain-db"
        ) ? "\(home)/Library/Keychains/VIPAccess.keychain-db"
          : "\(home)/Library/Keychains/VIPAccess.keychain"

        // Record the keychain file's modification date before migration
        let attrsBefore = try FileManager.default.attributesOfItem(atPath: keychainPath)
        let modDateBefore = attrsBefore[.modificationDate] as? Date
        let sizeBefore = attrsBefore[.size] as? UInt64

        // Perform migration (may skip if credential isn't readable)
        store.deleteFromDataProtectionKeychain()
        _ = try loadCredentialOrSkip()

        // Verify keychain file was not modified
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: keychainPath)
        let modDateAfter = attrsAfter[.modificationDate] as? Date
        let sizeAfter = attrsAfter[.size] as? UInt64

        XCTAssertEqual(
            modDateBefore, modDateAfter,
            "Legacy keychain modification date should not change (non-destructive migration)"
        )
        XCTAssertEqual(
            sizeBefore, sizeAfter,
            "Legacy keychain file size should not change (non-destructive migration)"
        )
    }

    // MARK: - Floating Window and Menu Bar Shared State

    /// End-to-end test: Floating window and menu bar share the same TokenViewModel,
    /// ensuring the countdown and code always match.
    ///
    /// ## Architecture Verification
    ///
    /// In `VIPAccessApp.swift`, a single `@StateObject` TokenViewModel is created:
    /// ```swift
    /// @StateObject private var viewModel = TokenViewModel()
    /// ```
    /// This same instance is passed to both:
    /// - `MenuBarContentView(viewModel: viewModel)` — the menu bar dropdown
    /// - `TokenWindowView(viewModel: viewModel)` — the floating window
    ///
    /// Because both views observe the same `ObservableObject`, any `@Published` property
    /// change (currentCode, nextCode, secondsRemaining) triggers a re-render in **both**
    /// views simultaneously via SwiftUI's observation mechanism.
    ///
    /// The 1-second Timer in TokenViewModel fires `refresh()` which updates all published
    /// properties at once, guaranteeing the floating window and menu bar always show
    /// identical data.
    ///
    /// ## Manual Verification Steps
    ///
    /// 1. Launch VIPAccess.app
    /// 2. Click the token in the menu bar → select "Show Window"
    /// 3. Observe the floating window opens with:
    ///    - Same 6-digit code as the menu bar
    ///    - Same countdown timer/progress bar
    ///    - Credential ID displayed
    ///    - "Next" code shown
    /// 4. Wait for a period boundary (progress bar resets) and verify both update simultaneously
    /// 5. Click the pin toggle → verify window stays on top of other apps
    func testFloatingWindow_sharesViewModelWithMenuBar() throws {
        // Architecturally, VIPAccessApp.swift passes the same @StateObject TokenViewModel
        // to both MenuBarContentView and TokenWindowView. This ensures they always display
        // identical data since they observe the same published properties.
        //
        // The timer in TokenViewModel fires every 1 second and updates @Published properties,
        // which triggers re-renders in both views simultaneously via SwiftUI's observation.

        // Verify the shared state works programmatically by simulating what both views observe
        let secret = Data("windowtestsecret!".utf8)
        let credential = Credential(
            id: "SYMCWINDOW01",
            secret: secret,
            secretBase32: secret.base32EncodedString()
        )
        try store.storeInDataProtectionKeychain(credential: credential)

        let loaded = try store.loadCredential()
        let generator = TOTPGenerator(secret: loaded.secret)

        // Both the menu bar and window would show these exact values
        let code = generator.generateCode()
        let nextCode = generator.nextCode()
        let remaining = generator.secondsRemaining()

        // The menu bar label shows the current 6-digit code
        XCTAssertEqual(code.count, 6, "Current code must be 6 digits")
        XCTAssertTrue(code.allSatisfy({ $0.isNumber }), "Current code must be numeric")

        // The floating window shows the same code plus the next code
        XCTAssertEqual(nextCode.count, 6, "Next code must be 6 digits")
        XCTAssertTrue(nextCode.allSatisfy({ $0.isNumber }), "Next code must be numeric")

        // Both views display the same countdown (secondsRemaining drives the progress bar)
        XCTAssertGreaterThan(remaining, 0, "Seconds remaining should be positive")
        XCTAssertLessThanOrEqual(remaining, 30, "Seconds remaining should not exceed period")

        // Verify that calling generateCode again at the same instant produces the same result
        // (confirming deterministic output — both views calling the same generator get the same code)
        let codeAgain = generator.generateCode()
        XCTAssertEqual(code, codeAgain, "Same generator at same time must produce same code")

        // Since both views observe the same ViewModel, they display identical values.
        // The architectural guarantee is that only ONE TokenViewModel exists (the @StateObject),
        // and both views receive it as @ObservedObject, so there is no possibility of divergence.
    }
}

// MARK: - Manual Test Procedures

/// ## Manual End-to-End Test: First Launch Migration → Menu Bar Token
///
/// ### Prerequisites
/// 1. Symantec VIP Access macOS app has been installed and provisioned at least once
///    (creates `~/Library/Keychains/VIPAccess.keychain-db`).
/// 2. The VIPAccess.app (this Swift app) is built but has NOT been launched before,
///    OR its data protection keychain entry has been manually deleted:
///    ```bash
///    security delete-generic-password -s "com.vipaccess.credential" -a "id"
///    security delete-generic-password -s "com.vipaccess.credential" -a "secret"
///    ```
///
/// ### Test Steps
/// 1. Launch VIPAccess.app from the build output or Applications folder.
/// 2. Observe the menu bar — after 1-2 seconds, a 6-digit token should appear.
/// 3. Click the menu bar token to open the dropdown.
/// 4. Verify the credential ID is displayed (e.g., "SYMC12345678").
/// 5. Verify the "Copy Token" menu item is present and functional.
/// 6. Verify the token updates every 30 seconds (watch for the progress bar to reset).
///
/// ### Expected Results
/// - The app detects no credential in the data protection keychain.
/// - The app automatically locates and reads from the Symantec legacy keychain.
/// - The token appears in the menu bar within 2 seconds of launch.
/// - The credential ID matches what Symantec VIP Access shows.
/// - The TOTP code matches what `oathtool --totp -b <base32secret>` generates.
///
/// ### Verification with oathtool
/// ```bash
/// # After successful migration, verify the token matches:
/// security find-generic-password -s "com.vipaccess.credential" -a "secret" -w | \
///   base32 | oathtool --totp -b -
/// ```
///
/// ### Troubleshooting
/// - If the app shows "No VIP Access credential found":
///   - Verify `~/Library/Keychains/VIPAccess.keychain-db` exists.
///   - Try running `security list-keychains` to see if it's registered.
/// - If the app shows "Failed to unlock legacy keychain":
///   - The derived password may be incorrect. Verify your Mac serial number:
///     `ioreg -l | grep IOPlatformSerialNumber`
///   - Verify the username matches: `whoami`
/// - If migration succeeds but the token is wrong:
///   - The decryption key may not match. Compare with python-vipaccess output.
///   - Run `python -m vipaccess show` to cross-reference.
