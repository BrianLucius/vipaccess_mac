import Foundation
import Security
import CommonCrypto
import IOKit
import AppKit

/// Isolated helper that uses deprecated `SecKeychain*` APIs for one-time migration
/// from the Symantec VIPAccess legacy keychain.
///
/// All deprecated API usage is contained within this file. The reader is non-destructive
/// (read-only access to Symantec's keychain) and idempotent (can be re-run safely).
public enum LegacyKeychainReader {

    // MARK: - Constants

    /// AES-128-CBC key derived from the existing python-vipaccess / shell script codebase.
    private static let aesKey = Data([
        0xD0, 0xD0, 0xD0, 0xE0, 0xD0, 0xD0, 0xDF, 0xDF,
        0xDF, 0x2C, 0x34, 0x32, 0x39, 0x37, 0xD7, 0xAE
    ])

    /// AES-128-CBC initialization vector: 16 zero bytes.
    private static let aesIV = Data(repeating: 0, count: 16)

    // MARK: - Debug Toggles

    /// Returns true if the named debug environment variable is set to a truthy value
    /// (`1`, `true`, or `yes`, case-insensitive).
    ///
    /// These flags let the migration failure paths be exercised on a machine whose
    /// keychain state would otherwise let migration succeed silently. They are read
    /// from the environment, so the shipped app is inert unless explicitly launched
    /// with the variable set, e.g.:
    ///
    ///     VIPACCESS_DEBUG_FORCE_CLI_FAILURE=1 "/Applications/VIP Access.app/Contents/MacOS/VIPAccess"
    private static func isDebugFlagSet(_ name: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return value == "1" || value == "true" || value == "yes"
    }

    // MARK: - Public API

    /// Reads and decrypts the credential from the Symantec VIPAccess legacy keychain.
    ///
    /// - Important: This method is **non-destructive** (read-only). It uses only read APIs
    ///   (`SecKeychainOpen`, `SecKeychainUnlock`, `SecKeychainFindGenericPassword`,
    ///   `SecKeychainItemCopyAttributesAndData`) and never calls any write, modify, or delete
    ///   APIs on the Symantec keychain. The unlock operation grants read access only and does
    ///   not alter the keychain file. All writes go exclusively to the app's own data protection
    ///   keychain (via `KeychainCredentialStore`).
    ///
    /// Steps:
    /// 1. Locate `VIPAccess.keychain-db` (fallback to `.keychain`)
    /// 2. Derive the unlock password from serial number and username
    /// 3. Unlock and read the `CredentialStore` entry
    /// 4. Decrypt with AES-128-CBC
    /// 5. Post-process (strip "Symantec" suffix, base32-encode secret)
    ///
    /// - Throws: `KeychainError` variants for each failure mode.
    /// - Returns: The decrypted `Credential`.
    @available(macOS, deprecated: 10.10, message: "Uses deprecated SecKeychain APIs for legacy migration")
    public static func readCredential() throws -> Credential {
        let keychainPath = try locateKeychainFile()
        let serial = try getSerialNumber()
        let username = NSUserName()
        let password = "\(serial)SymantecVIPAccess\(username)"

        do {
            // DEBUG: force the entire migration to fail right after the password is
            // derived, to validate the outer "Manual Keychain Unlock Needed" alert in
            // isolation (no deprecated-API path involved). Enable by launching with:
            //   VIPACCESS_DEBUG_FORCE_MIGRATION_FAILURE=1
            if isDebugFlagSet("VIPACCESS_DEBUG_FORCE_MIGRATION_FAILURE") {
                throw KeychainError.credentialReadFailed
            }

            // Primary path: CLI-based (/usr/bin/security) — avoids macOS authorization
            // dialogs that the deprecated SecKeychain* APIs trigger on Tahoe+.
            let accountData: Data
            let passwordData: Data
            do {
                // DEBUG: force the CLI path to fail so the fallback + up-front hint
                // path runs, matching a machine where the automatic unlock/read
                // cannot complete. Enable by launching with:
                //   VIPACCESS_DEBUG_FORCE_CLI_FAILURE=1
                if isDebugFlagSet("VIPACCESS_DEBUG_FORCE_CLI_FAILURE") {
                    throw KeychainError.unlockFailed(errSecAuthFailed)
                }

                let result = try readFromLegacyKeychainViaCLI(
                    path: keychainPath,
                    password: password
                )
                accountData = result.account
                passwordData = result.password
            } catch {
                // CLI path failed — fall back to deprecated SecKeychain* APIs.
                // This may trigger a system authorization dialog on macOS Tahoe+.
                // Show the user the derived password up front so they can enter it
                // if prompted, before the deprecated unlock puts up the system dialog.
                showKeychainPasswordHint(
                    password,
                    title: "Keychain Authorization Required",
                    body: """
                        macOS may prompt you for the "VIPAccess" keychain password. \
                        The password is:

                        \(password)

                        It has been copied to your clipboard, so you can paste it \
                        directly into the macOS prompt.
                        """
                )

                let result = try readFromLegacyKeychain(
                    path: keychainPath,
                    password: password
                )
                accountData = result.account
                passwordData = result.password
            }

            let decryptedID = try decryptAES128CBC(data: accountData)
            let decryptedSecret = try decryptAES128CBC(data: passwordData)

            // Strip trailing "Symantec" suffix from the credential ID
            var id = String(data: decryptedID, encoding: .utf8) ?? ""
            if id.hasSuffix("Symantec") {
                id = String(id.dropLast("Symantec".count))
            }

            let secretBase32 = decryptedSecret.base32EncodedString()

            return Credential(id: id, secret: decryptedSecret, secretBase32: secretBase32)
        } catch {
            // Migration failed for any reason after the derived password was computed
            // (unlock rejected, read/parse failure, decryption failure, etc.). Surface
            // the derived password and manual-unlock instructions so the user is never
            // left stuck — this is the information that actually unblocks a stalled
            // migration. Then rethrow so the caller still sees the underlying error.
            showKeychainPasswordHint(
                password,
                title: "VIP Access — Manual Keychain Unlock Needed",
                body: """
                    VIP Access could not automatically read your Symantec keychain \
                    (\(error.localizedDescription)).

                    The keychain password for "VIPAccess" is:

                    \(password)

                    It has been copied to your clipboard. To finish setup, unlock the \
                    keychain manually in Terminal:

                    security unlock-keychain "\(keychainPath)"

                    then paste the password when prompted and relaunch VIP Access.
                    """
            )
            throw error
        }
    }

    // MARK: - Keychain File Location

    /// Shows an alert with the derived keychain password and copies it to the
    /// clipboard so the user can complete a manual unlock.
    ///
    /// - Important: Two hazards this method guards against:
    ///   1. **Deadlock:** it must not call `DispatchQueue.main.sync` when already on
    ///      the main thread — that self-dispatch deadlocks. It detects the current
    ///      thread and runs the alert directly when already on main.
    ///   2. **Invisible alert:** this is a menu-bar-only (`LSUIElement`) app, so a
    ///      modal `NSAlert` shown without `NSApp.activate(ignoringOtherApps:)` is
    ///      ordered *behind* the frontmost app and the user never sees it. Every
    ///      other UI entry point in the app activates first for exactly this reason;
    ///      this presenter does the same before `runModal()`.
    private static func showKeychainPasswordHint(
        _ password: String,
        title: String,
        body: String
    ) {
        @MainActor
        func present() {
            // Copy first so the password is on the clipboard even if the user
            // dismisses the alert quickly.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(password, forType: .string)

            // Bring this LSUIElement app to the front so the alert is actually
            // visible instead of being ordered behind the active application.
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = body
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")

            // Belt-and-suspenders: force the alert window itself to the front and
            // above normal windows, in case activation alone isn't enough.
            alert.window.level = .modalPanel
            alert.window.makeKeyAndOrderFront(nil)

            alert.runModal()
        }

        if Thread.isMainThread {
            // Already on the main thread/actor: run the alert directly.
            MainActor.assumeIsolated { present() }
        } else {
            // Background thread (the normal migration path): hop to the main
            // queue synchronously so the hint is on screen before the
            // deprecated SecKeychainUnlock triggers the system prompt.
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { present() }
            }
        }
    }

    private static func locateKeychainFile() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Keychains/VIPAccess.keychain-db",
            "\(home)/Library/Keychains/VIPAccess.keychain"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        throw KeychainError.legacyKeychainNotFound
    }

    // MARK: - Serial Number via IOKit

    private static func getSerialNumber() throws -> String {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else {
            throw KeychainError.serialNumberUnavailable
        }
        defer { IOObjectRelease(platformExpert) }

        guard let serialRef = IORegistryEntryCreateCFProperty(
            platformExpert,
            "IOPlatformSerialNumber" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            throw KeychainError.serialNumberUnavailable
        }

        guard let serial = serialRef.takeRetainedValue() as? String, !serial.isEmpty else {
            throw KeychainError.serialNumberUnavailable
        }

        return serial
    }

    // MARK: - Legacy Keychain Read (Deprecated APIs)

    /// Opens, unlocks, and reads from the Symantec legacy keychain.
    ///
    /// Uses deprecated `SecKeychain*` APIs that are necessary for accessing
    /// file-based keychains. Suppressed via `@available` annotation.
    @available(macOS, deprecated: 10.10, message: "Uses deprecated SecKeychain APIs for legacy migration")
    private static func readFromLegacyKeychain(
        path: String,
        password: String
    ) throws -> (account: Data, password: Data) {
        var keychain: SecKeychain?
        var status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess, let kc = keychain else {
            throw KeychainError.unlockFailed(status)
        }

        // Unlock with the derived password
        status = SecKeychainUnlock(
            kc,
            UInt32(password.utf8.count),
            password,
            true
        )
        guard status == errSecSuccess else {
            throw KeychainError.unlockFailed(status)
        }

        // Read CredentialStore generic password entry
        // Note: The Symantec entry has a NULL service ("svce"<blob>=<NULL>)
        // and uses the label attribute (0x00000007) = "CredentialStore".
        // We pass 0/nil for both service and account to match any entry.
        var passwordLength: UInt32 = 0
        var passwordDataPtr: UnsafeMutableRawPointer?
        var itemRef: SecKeychainItem?

        status = SecKeychainFindGenericPassword(
            kc,
            0,      // service name length (0 = no service filter)
            nil,    // service name (nil = match any/empty service)
            0,      // account name length (0 = no account filter)
            nil,    // account name (nil = match any account)
            &passwordLength,
            &passwordDataPtr,
            &itemRef
        )

        guard status == errSecSuccess else {
            throw KeychainError.credentialReadFailed
        }

        defer {
            if let ptr = passwordDataPtr {
                SecKeychainItemFreeContent(nil, ptr)
            }
        }

        // Extract the password blob (encrypted secret)
        guard let pwdPtr = passwordDataPtr, passwordLength > 0 else {
            throw KeychainError.credentialReadFailed
        }
        let secretBlob = Data(bytes: pwdPtr, count: Int(passwordLength))

        // Extract the account attribute (encrypted ID)
        guard let item = itemRef else {
            throw KeychainError.credentialReadFailed
        }

        // kSecAccountItemAttr = 'acct' = 0x61636374
        var accountAttrTag: UInt32 = 0x61636374

        let accountBlob: Data = try withUnsafeMutablePointer(to: &accountAttrTag) { tagPtr in
            var attrInfo = SecKeychainAttributeInfo(
                count: 1,
                tag: tagPtr,
                format: nil
            )

            var outAttrList: UnsafeMutablePointer<SecKeychainAttributeList>?
            let attrStatus = SecKeychainItemCopyAttributesAndData(
                item,
                &attrInfo,
                nil,
                &outAttrList,
                nil,
                nil
            )

            guard attrStatus == errSecSuccess, let attrs = outAttrList else {
                throw KeychainError.credentialReadFailed
            }
            defer {
                SecKeychainItemFreeAttributesAndData(attrs, nil)
            }

            guard attrs.pointee.count > 0, let attrArray = attrs.pointee.attr else {
                throw KeychainError.credentialReadFailed
            }

            let attr = attrArray[0]
            guard let attrData = attr.data else {
                throw KeychainError.credentialReadFailed
            }
            return Data(bytes: attrData, count: Int(attr.length))
        }

        return (account: accountBlob, password: secretBlob)
    }

    // MARK: - Legacy Keychain Read via CLI Fallback

    /// Secondary fallback: reads from the Symantec legacy keychain by shelling out
    /// to `/usr/bin/security` CLI via `Process`.
    ///
    /// This fallback is used when the deprecated `SecKeychain*` APIs fail (e.g., if
    /// Apple removes them in a future macOS release). The CLI tool `security` provides
    /// equivalent functionality for unlocking keychains and reading generic passwords.
    ///
    /// - Parameters:
    ///   - path: Path to the legacy keychain file.
    ///   - password: The derived keychain unlock password.
    /// - Throws: `KeychainError` variants for unlock or read failures.
    /// - Returns: A tuple of (account data, password data) as raw `Data`.
    private static func readFromLegacyKeychainViaCLI(
        path: String,
        password: String
    ) throws -> (account: Data, password: Data) {
        // Step 1: Unlock the keychain
        try unlockKeychainViaCLI(path: path, password: password)

        // Step 2: Read the CredentialStore generic password entry
        let (accountData, passwordData) = try findGenericPasswordViaCLI(path: path)

        return (account: accountData, password: passwordData)
    }

    /// Unlocks the keychain using `/usr/bin/security unlock-keychain`.
    private static func unlockKeychainViaCLI(path: String, password: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["unlock-keychain", "-p", password, path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe() // discard stdout

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw KeychainError.unlockFailed(OSStatus(process.terminationStatus))
        }
    }

    /// Reads the `CredentialStore` generic password entry using
    /// `/usr/bin/security find-generic-password`.
    ///
    /// The `-g` flag causes the password to be printed to stderr in the format:
    /// ```
    /// password: 0x<hex bytes>
    /// ```
    /// or as a quoted string:
    /// ```
    /// password: "some string"
    /// ```
    ///
    /// Attributes are printed to stdout in the format:
    /// ```
    ///     "acct"<blob>=0x<hex bytes>  "<readable>"
    /// ```
    private static func findGenericPasswordViaCLI(
        path: String
    ) throws -> (account: Data, password: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-l", "CredentialStore",    // -l searches by label (attribute 0x00000007)
            "-g",
            path
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw KeychainError.credentialReadFailed
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

        // Parse the password from stderr
        let passwordData = try parsePasswordFromSecurityOutput(stderrString)

        // Parse the account attribute from stdout
        let accountData = try parseAccountFromSecurityOutput(stdoutString)

        return (account: accountData, password: passwordData)
    }

    /// Parses the password blob from `/usr/bin/security` stderr output.
    ///
    /// Expected format (hex):
    /// ```
    /// password: 0x48656C6C6F
    /// ```
    /// Or (string):
    /// ```
    /// password: "Hello"
    /// ```
    private static func parsePasswordFromSecurityOutput(_ output: String) throws -> Data {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Match hex format: password: 0x<hex>
            if trimmed.hasPrefix("password: 0x") || trimmed.hasPrefix("password:0x") {
                let hexStart = trimmed.range(of: "0x")!.upperBound
                // The hex string may be followed by a space and quoted readable form
                let hexPortion: String
                if let spaceRange = trimmed[hexStart...].range(of: " ") {
                    hexPortion = String(trimmed[hexStart..<spaceRange.lowerBound])
                } else {
                    hexPortion = String(trimmed[hexStart...])
                }
                guard let data = dataFromHexString(hexPortion) else {
                    throw KeychainError.credentialReadFailed
                }
                return data
            }

            // Match quoted string format: password: "..."
            if trimmed.hasPrefix("password: \"") || trimmed.hasPrefix("password:\"") {
                let quoteStart = trimmed.index(after: trimmed.firstIndex(of: "\"")!)
                if let quoteEnd = trimmed[quoteStart...].firstIndex(of: "\"") {
                    let value = String(trimmed[quoteStart..<quoteEnd])
                    guard let data = value.data(using: .utf8) else {
                        throw KeychainError.credentialReadFailed
                    }
                    return data
                }
            }
        }

        throw KeychainError.credentialReadFailed
    }

    /// Parses the account (`acct`) attribute from `/usr/bin/security` stdout output.
    ///
    /// Expected format (hex):
    /// ```
    ///     "acct"<blob>=0x48656C6C6F  "Hello"
    /// ```
    /// Or (string):
    /// ```
    ///     "acct"<blob>="Hello"
    /// ```
    private static func parseAccountFromSecurityOutput(_ output: String) throws -> Data {
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard trimmed.contains("\"acct\"") else { continue }

            // Try hex format: "acct"<blob>=0x<hex>
            if let hexRange = trimmed.range(of: "=0x") {
                let hexStart = hexRange.upperBound
                // Hex ends at whitespace or end of line
                let remaining = trimmed[hexStart...]
                let hexPortion: String
                if let spaceIdx = remaining.firstIndex(of: " ") {
                    hexPortion = String(remaining[..<spaceIdx])
                } else {
                    hexPortion = String(remaining)
                }
                guard let data = dataFromHexString(hexPortion) else {
                    throw KeychainError.credentialReadFailed
                }
                return data
            }

            // Try string format: "acct"<blob>="value"
            if let eqQuoteRange = trimmed.range(of: "=\"") {
                let valueStart = eqQuoteRange.upperBound
                if let quoteEnd = trimmed[valueStart...].firstIndex(of: "\"") {
                    let value = String(trimmed[valueStart..<quoteEnd])
                    guard let data = value.data(using: .utf8) else {
                        throw KeychainError.credentialReadFailed
                    }
                    return data
                }
            }
        }

        throw KeychainError.credentialReadFailed
    }

    /// Converts a hex string to Data.
    private static func dataFromHexString(_ hex: String) -> Data? {
        let cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanHex.count % 2 == 0 else { return nil }

        var data = Data(capacity: cleanHex.count / 2)
        var index = cleanHex.startIndex
        while index < cleanHex.endIndex {
            let nextIndex = cleanHex.index(index, offsetBy: 2)
            let byteString = cleanHex[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    // MARK: - AES-128-CBC Decryption

    /// Decrypts data using AES-128-CBC with the hardcoded key and zero IV.
    /// Handles both raw and base64-encoded input.
    private static func decryptAES128CBC(data: Data) throws -> Data {
        // The data may be base64-encoded; try decoding first
        let rawData: Data
        if let decoded = Data(base64Encoded: data) {
            rawData = decoded
        } else {
            rawData = data
        }

        let bufferSize = rawData.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesDecrypted: size_t = 0

        let cryptStatus = buffer.withUnsafeMutableBytes { bufferPtr in
            rawData.withUnsafeBytes { dataPtr in
                aesKey.withUnsafeBytes { keyPtr in
                    aesIV.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, kCCKeySizeAES128,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, rawData.count,
                            bufferPtr.baseAddress, bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard cryptStatus == kCCSuccess else {
            throw KeychainError.decryptionFailed
        }

        return buffer.prefix(numBytesDecrypted)
    }
}
