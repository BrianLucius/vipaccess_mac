import SwiftUI
import Foundation

/// Observable view model that drives all token-related UI across the menu bar,
/// floating window, and Services provider.
@MainActor
public class TokenViewModel: ObservableObject {
    // MARK: - Published Properties

    /// The current 6-digit TOTP code.
    @Published public var currentCode: String = "------"
    /// The next 6-digit TOTP code (for the upcoming time period).
    @Published public var nextCode: String = "------"
    /// Seconds remaining until the current code expires (1–30).
    @Published public var secondsRemaining: Int = 30
    /// The credential identifier (e.g., "SYMC12345678").
    @Published public var credentialID: String = ""
    /// Whether a credential has been successfully loaded.
    @Published public var isLoaded: Bool = false
    /// The most recent keychain error, if any.
    @Published public var error: KeychainError? = nil

    // MARK: - Private State

    private var generator: TOTPGenerator?
    private var timer: Timer?
    private let store = KeychainCredentialStore()

    // MARK: - Public Methods

    /// Loads the credential from the keychain (data protection first, legacy migration fallback).
    /// On success, initializes the TOTP generator and starts the refresh timer.
    ///
    /// The keychain read runs off the main thread. Migration from the legacy Symantec
    /// keychain shells out to `/usr/bin/security` and may present a password-hint alert;
    /// running it on a background thread keeps the UI responsive and lets the hint alert
    /// be pumped on the main thread instead of deadlocking it (see `LegacyKeychainReader`).
    public func loadCredential() {
        Task {
            let result = await Self.loadCredentialInBackground(store: store)
            self.apply(result)
        }
    }

    /// Applies the outcome of a background credential load to the published state
    /// on the main actor.
    private func apply(_ result: Result<Credential, KeychainError>) {
        switch result {
        case .success(let credential):
            self.generator = TOTPGenerator(secret: credential.secret)
            self.credentialID = credential.id
            self.isLoaded = true
            self.error = nil
            refresh()
            startRefresh()
        case .failure(let err):
            self.error = err
            self.isLoaded = false
        }
    }

    /// Performs the blocking keychain read on a background thread and returns a
    /// `Result` so the caller can update `@MainActor` state.
    nonisolated private static func loadCredentialInBackground(
        store: KeychainCredentialStore
    ) async -> Result<Credential, KeychainError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let credential = try store.loadCredential()
                    continuation.resume(returning: .success(credential))
                } catch let err as KeychainError {
                    continuation.resume(returning: .failure(err))
                } catch {
                    continuation.resume(returning: .failure(.credentialNotFound))
                }
            }
        }
    }

    /// Forces a fresh migration from the Symantec legacy keychain, replacing
    /// any existing data protection keychain entry. Use when the credential
    /// has been re-provisioned through Symantec's app.
    public func forceRemigrate() {
        do {
            let credential = try store.forceRemigrate()
            self.generator = TOTPGenerator(secret: credential.secret)
            self.credentialID = credential.id
            self.isLoaded = true
            self.error = nil
            refresh()
        } catch let err as KeychainError {
            self.error = err
            self.isLoaded = false
            self.currentCode = "------"
            self.nextCode = "------"
            self.secondsRemaining = 30
            self.credentialID = ""
        } catch {
            self.error = .credentialNotFound
            self.isLoaded = false
        }
    }

    /// Starts (or restarts) the 1-second refresh timer. Each tick updates the
    /// published properties from the TOTP generator on the main actor.
    ///
    /// The timer is added to `.common` run loop modes so it continues firing
    /// during menu tracking (when the user clicks the menu bar item).
    public func startRefresh() {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    /// Updates all published properties from the current TOTP generator state.
    public func refresh() {
        guard let generator = generator else { return }
        let now = Date.now
        currentCode = generator.generateCode(at: now)
        nextCode = generator.nextCode(at: now)
        secondsRemaining = generator.secondsRemaining(at: now)
    }
}
