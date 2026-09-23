---
inclusion: always
---

# VIP Access (Swift) — Architecture

Native macOS menu bar app that generates Symantec VIP Access TOTP tokens. It is a
standalone reimplementation of the Python `python-vipaccess` GUI; the two projects
are now fully independent (the Swift project lives at `~/Repositories/vipaccess/`,
the Python app remains in the `python-vipaccess` repo).

## Platform & tooling
- Swift Package Manager executable target (no `.xcodeproj`). `swift-tools-version: 6.2`.
- Targets **macOS 26 (Tahoe)**. Universal binary supported via `swift build -c release --arch arm64 --arch x86_64`.
- No third-party dependencies. System frameworks only: SwiftUI, AppKit, Security, IOKit, CommonCrypto, ServiceManagement.
- Menu-bar-only app: `LSUIElement = true` in `Info.plist` (no Dock icon).

## Source layout (paths relative to project root)
- `VIPAccess/App/VIPAccessApp.swift` — `@main` App. Defines the `MenuBarExtra` scene and the floating `Window("VIP Access", id: "token-window")`. Owns the single `@StateObject TokenViewModel`. Kicks off the credential load in the label's `.onAppear` (fires at launch, not just when the menu opens). The load is async (see `TokenViewModel`), so the critical "No Credential Found" alert + quit is driven by `.onChange(of: viewModel.error)`, NOT a synchronous `isLoaded` check after the call.
- `VIPAccess/App/AppDelegate.swift` — `@MainActor NSApplicationDelegate`. Registers the Services provider and (best-effort) registers the app as a Login Item via `SMAppService`. Receives the shared view model via a `viewModel` property whose `didSet` triggers service registration.
- `VIPAccess/Core/TOTPGenerator.swift` — RFC 6238 TOTP via CommonCrypto HMAC-SHA1. Configurable `period` (default 30) and `digits` (default 6). `generateCode(at:)`, `nextCode(at:)`, `secondsRemaining(at:)`.
- `VIPAccess/Core/Credential.swift` — model: `id: String`, `secret: Data`, `secretBase32: String`.
- `VIPAccess/Core/KeychainCredentialStore.swift` — two-path credential access: read from the app's own login-keychain entry first (`SecItem`, service `com.vipaccess.credential`, separate `id` and `secret` accounts); on miss, migrate from the legacy Symantec keychain and store the result. Also defines `KeychainError` (which is `Equatable` + `Sendable`) and a base32 `Data` extension. The class is `final` + `Sendable` so it can cross to a background thread for the load. `Credential` is `Sendable` too.
- `VIPAccess/Core/LegacyKeychainReader.swift` — isolated, one-time migration reader for the Symantec `VIPAccess.keychain-db`. Contains all deprecated `SecKeychain*` usage plus the `/usr/bin/security` CLI fallback and AES-128-CBC decryption. `readCredential()` surfaces the derived password via `showKeychainPasswordHint(_:title:body:)` on ANY migration failure (outer `do/catch`), and that presenter activates the app before showing the alert (LSUIElement requirement). Also honors two debug env toggles (`VIPACCESS_DEBUG_FORCE_CLI_FAILURE`, `VIPACCESS_DEBUG_FORCE_MIGRATION_FAILURE`). See gotchas #3, #10–#12 before touching this.
- `VIPAccess/ViewModels/TokenViewModel.swift` — `@MainActor ObservableObject`. Published: `currentCode`, `nextCode`, `secondsRemaining`, `credentialID`, `isLoaded`, `error`. 1-second `Timer` (scheduled on `.common` run loop mode so it keeps firing during menu tracking). `loadCredential()` runs the blocking keychain read OFF the main thread (background queue via a checked continuation) and applies the `Result` back on the `@MainActor` in `apply(_:)`; `forceRemigrate()`, `startRefresh()`, `refresh()`.
- `VIPAccess/Services/TokenPasteService.swift` — `NSObject` with `@MainActor @objc pasteToken(_:userData:error:)`, the macOS Services provider that writes the current code to the pasteboard.
- `VIPAccess/Views/` —
  - `StatusItemLabel.swift` — the menu bar label (token + 2px progress bar), rendered via `ImageRenderer` to an `NSImage` (see gotchas).
  - `StatusItemView.swift` — earlier standalone status view (token + progress bar).
  - `MenuBarContentView.swift` — the dropdown: tap-to-copy token and credential ID, Copy Token, Show Window, Re-migrate Credential (confirmation dialog), Enable Paste Service…, Quit.
  - `TokenWindowView.swift` — the floating window styled to match the Python tkinter GUI. See gotchas for the exact sizing rules.
  - `ProgressBarView.swift` — window progress bar (green >10s, orange >5s, red ≤5s). Ticks in discrete 1-second steps (no animation) by design.

## Credential migration flow (first launch)
1. `TokenViewModel.loadCredential()` → `KeychainCredentialStore.loadCredential()`.
2. Try `readFromDataProtectionKeychain()` (name is a misnomer; it reads the app's own login-keychain entry via `SecItem`). On `credentialNotFound`, fall back to migration.
3. `LegacyKeychainReader.readCredential()`:
   - Locate `~/Library/Keychains/VIPAccess.keychain-db` (fallback `.keychain`).
   - Serial number via IOKit (`IOPlatformSerialNumber`), username via `NSUserName()`.
   - Password = `"{serial}SymantecVIPAccess{username}"`.
   - Unlock + read the `CredentialStore` entry (CLI-first, deprecated-API fallback).
   - AES-128-CBC decrypt (key `D0D0D0E0D0D0DFDFDF2C34323937D7AE`, zero IV). Strip trailing `"Symantec"` from the ID. Base32-encode the secret.
   - On ANY failure in this step, an activated, front-most alert surfaces the derived password + a manual `security unlock-keychain` command, then the error is rethrown (gotchas #10–#11).
4. Store the migrated credential back into the app's login-keychain entry.
- Migration is **non-destructive** (Symantec keychain is read-only) and **idempotent** (re-migrates if the app's entry is lost).
- The whole flow runs on a background thread (see `TokenViewModel.loadCredential()`); UI updates and any alerts marshal back to the main actor.
- **Reproducing failures is hard:** once a deprecated `SecKeychainUnlock` succeeds once, the keychain ACL trusts the app's stable signature, so deleting the app entry + re-locking still re-migrates silently. Use the debug env toggles (gotcha #12) to exercise the failure/hint paths.

## Key runtime behaviors
- Menu bar and floating window share the same `TokenViewModel` instance, so they always display identical values.
- "Show Window" calls `NSApp.activate(ignoringOtherApps: true)` before `openWindow` (required for LSUIElement apps).
- Clicking anywhere in the security code area of the window copies the current token.
