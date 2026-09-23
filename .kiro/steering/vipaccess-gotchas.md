---
inclusion: always
---

# VIP Access (Swift) — Hard-Won Gotchas

Non-obvious lessons from building this app. Read before modifying the window UI,
keychain code, migration reader, signing, or resource loading. Each entry lists the
symptom, root cause, and the fix that is currently in place.

## 1. tkinter → SwiftUI font scaling is 1.333×
- **Symptom:** The floating window text rendered far too small compared to the original Python tkinter GUI, despite using the same point sizes.
- **Root cause:** tkinter on this Retina Mac applies a `tk scaling` factor of ~1.333, so a "16pt" tkinter font actually renders ~21pt. SwiftUI uses points directly with no such extra scaling.
- **Fix:** In `TokenWindowView.swift`, FONT sizes are the tkinter values × 1.333 (e.g., header 11→15, credential 16→21, current code 32→43, next code 14→19, countdown 10→13, status 9→12). Use `Font.custom("Helvetica", size:)` / `"Helvetica-Bold"` to match the family, not `.system`.
- **Do NOT** scale layout dimensions (window geometry, paddings, frame heights, copy-button width). tkinter `geometry("250x228")` and `padx/pady` are already in screen points — scaling them made the window huge with dead space. Layout values stay at their raw tkinter numbers.

## 2. `CredentialStore` is the keychain entry's LABEL, not its service
- **Symptom:** Migration failed with "Failed to read credential from legacy keychain."
- **Root cause:** The Symantec entry has `svce` (service) = NULL. `CredentialStore` is attribute `0x00000007` (the label). Original code searched by service name and never matched.
- **Fix:** In `LegacyKeychainReader.swift`, the deprecated `SecKeychainFindGenericPassword` call passes `0, nil` for the service; the CLI fallback uses `security find-generic-password -l "CredentialStore"` (`-l` = label, NOT `-s`).

## 3. CLI-first keychain unlock avoids the auth dialog
- **Symptom:** On macOS Tahoe, the deprecated `SecKeychainUnlock` triggered a system authorization dialog even when given the correct password programmatically.
- **Root cause:** Tahoe gates file-based keychain access through UI.
- **Fix:** `readCredential()` runs the `/usr/bin/security unlock-keychain` + `find-generic-password` CLI path FIRST; the deprecated `SecKeychain*` APIs are the fallback. If the fallback runs, `showKeychainPasswordHint(_:title:body:)` shows the derived password and copies it to the clipboard so the user can paste it into the system dialog. See gotchas #10–#12 for the hardening this hint required.

## 4. `keychain-access-groups` is FATAL with self-signed certs — do not add it
- **Symptom:** App refused to launch at all ("The application can't be opened"). AMFI log: "Code has restricted entitlements, but the validation of its code signature failed. No matching profile found. Unsatisfied Entitlements: keychain-access-groups".
- **Root cause:** `keychain-access-groups` is an Apple-restricted entitlement requiring a provisioning profile from a paid Developer ID (team ID). Self-signed certs cannot satisfy it, so AMFI kills the process.
- **Fix / rule:** The dev entitlements file (`VIPAccess-dev.entitlements`) must NOT contain `keychain-access-groups`. It only contains `com.apple.security.app-sandbox = false`. The data protection keychain (`kSecUseDataProtectionKeychain`, `kSecAttrAccessGroup`) is therefore NOT usable with self-signed builds — the code uses the plain login keychain instead. Only revisit this if the project moves to a paid Developer ID.

## 5. Keychain access breaks across rebuilds unless signed with a stable identity
- **Symptom:** After rebuilding, the app re-prompts for the login keychain password to read `com.vipaccess.credential` (previously stored by an earlier build).
- **Root cause:** The login keychain uses per-application ACLs keyed to the binary's code signature. Each unsigned/ad-hoc rebuild has a different signature, so macOS treats it as a new app.
- **Fix / workflow:** Sign every build with the stable self-signed `VIPAccess Dev` cert (`make dev`). After a one-time "Always Allow", same-signed builds are recognized. A fully prompt-free experience is only possible with a paid Developer ID + data protection keychain. When switching signing identity, delete the old entries: `security delete-generic-password -s "com.vipaccess.credential" -a "id"` and `... -a "secret"`, then relaunch to re-migrate.

## 6. `Bundle.module` fatal-errors if the resource bundle is missing
- **Symptom:** App crashed when "Show Window" (actually the footer pin icon) tried to load. Crash was in `NSBundle.module` one-time init → `assertionFailure`.
- **Root cause:** SPM's generated `Bundle.module` accessor calls `fatalError` if `VIPAccess_VIPAccess.bundle` isn't found. A force-unwrap of `Bundle.module.url(...)!` also contributed. This happened when the resource bundle wasn't copied into the `.app`.
- **Fix:** `TokenWindowView.swift` loads pin icons via a safe `resourceBundle` computed property that searches `Bundle.main.resourceURL`/`bundleURL` for `VIPAccess_VIPAccess.bundle` WITHOUT calling `Bundle.module` (no fatalError), and falls back to SF Symbol pins if not found. The `Makefile` `bundle` target copies `.build/release/VIPAccess_VIPAccess.bundle` into `Contents/Resources/`.

## 7. `MenuBarExtra` label clips multi-element SwiftUI content
- **Symptom:** A `VStack` (token text + progress bar) in the `MenuBarExtra` label showed only the text; the progress bar was clipped.
- **Root cause:** macOS constrains menu bar item labels to a single line of fixed height.
- **Fix:** `StatusItemLabel.swift` composes the token + 2px bar and renders them to an `NSImage` via `ImageRenderer` (with `renderer.scale = backingScaleFactor`, `isTemplate = false`), then displays `Image(nsImage:)`. This bypasses the height clipping.

## 8. macOS Services registration may need a pbs flush
- **Symptom:** "Paste VIP Access Token" didn't appear in the right-click Services menu.
- **Fix:** Run `/System/Library/CoreServices/pbs -flush` (and `-update`). Also helps to have the app in `/Applications` or `~/Applications`. The in-app "Enable Paste Service…" menu item documents the enable steps and deep-links to Keyboard settings.

## 9. Case-insensitive APFS: `VIPAccess/` vs `vipaccess/`
- During the original build the Swift project lived alongside the Python package on a case-insensitive volume, so `VIPAccess/` and `vipaccess/` resolved to the same directory. The projects are now separated (`~/Repositories/vipaccess/`), but keep this in mind if paths ever look surprising.

## 10. The keychain password hint deadlocks / is invisible without care (`LegacyKeychainReader.swift`)
Two separate bugs made the migration password hint fail to appear for testers. Both are fixed in `showKeychainPasswordHint(_:title:body:)`; keep all three guards if you touch it.
- **Deadlock:** The hint originally called `DispatchQueue.main.sync { … }` unconditionally. `loadCredential()` used to run on the main thread (from the `MenuBarExtra` label's `.onAppear`), so the self-dispatch deadlocked and the alert never ran. **Fix:** the presenter checks `Thread.isMainThread` — runs the alert directly (via `MainActor.assumeIsolated`) when already on main, and only uses `DispatchQueue.main.sync` from a background thread. Also see gotcha #11 (the load now runs off-main anyway).
- **Invisible alert (the one that actually bit a tester):** the derivation was correct and the hint code ran, but the `NSAlert` never appeared. This is an `LSUIElement` (menu-bar-only) app, so a modal alert shown WITHOUT `NSApp.activate(ignoringOtherApps: true)` is ordered *behind* the frontmost app and the user never sees it. Every other UI entry point (`MenuBarContentView` "Show Window"/"Enable Paste Service", `TokenWindowView` tap) already activates first — the hint was the one place missing it. **Fix:** the presenter calls `NSApp.activate(ignoringOtherApps: true)`, sets `alert.window.level = .modalPanel`, and `makeKeyAndOrderFront(nil)` before `runModal()`.
- **Rule:** any modal surfaced from this app MUST activate the app first, or it can render invisibly.

## 11. Migration hint must fire on ANY failure, and the keychain read must be off-main
- **Symptom / design flaw:** the hint was wired only into the `catch` around the CLI path, so it fired for a narrow branch and not for failures elsewhere (`locateKeychainFile`, `getSerialNumber`, decryption, parse). A tester hit a failure that produced no hint at all.
- **Fix:** `readCredential()` wraps the whole read/decrypt sequence in an outer `do/catch`. On ANY throw after the derived password is computed, it shows a "Manual Keychain Unlock Needed" alert containing the derived password (also copied to clipboard) plus the exact `security unlock-keychain "<path>"` command, then rethrows so the caller still sees the underlying error. The original up-front hint before the deprecated fallback is preserved.
- **Off-main load:** `TokenViewModel.loadCredential()` now dispatches the blocking keychain read (CLI `Process` calls + possible modal) to a background queue via a checked continuation and applies the `Result` back on the `@MainActor`. Because the load is async, `VIPAccessApp` can no longer check `viewModel.isLoaded` synchronously right after calling it — the terminal-error alert is driven by `.onChange(of: viewModel.error)` instead. This required `KeychainError: Equatable`, and `Credential`/`KeychainCredentialStore`/`KeychainError` to be `Sendable` for Swift 6.2 strict concurrency.

## 12. Migration failure paths are hard to reproduce locally — use the debug env toggles
- **Symptom:** After a successful migration, deleting the app's `com.vipaccess.credential` entries AND `security lock-keychain`-ing the Symantec keychain STILL re-migrates silently. Once the deprecated `SecKeychainUnlock` succeeds once, it re-establishes the keychain ACL/trust for the app's (stable, self-signed) code signature, so later unlocks succeed with no prompt. You cannot reliably force the failure branch just by resetting state.
- **Fix / workflow:** `LegacyKeychainReader` reads two env-gated debug toggles via `isDebugFlagSet(_:)` (truthy = `1`/`true`/`yes`). They are read from the environment only, so the shipped app is inert unless explicitly launched with them set. **NOTE: they currently ship in the release binary** (so validation uses the same package peers get); wrap in `#if DEBUG` if that ever becomes a concern.
  - `VIPACCESS_DEBUG_FORCE_CLI_FAILURE=1` — makes the CLI path throw, exercising the fallback + up-front hint (and the deprecated `SecKeychainUnlock`, which may itself show the system dialog).
  - `VIPACCESS_DEBUG_FORCE_MIGRATION_FAILURE=1` — throws right after the password is derived, exercising the outer "Manual Keychain Unlock Needed" alert in isolation (no deprecated APIs). Cleanest test of the front-most-alert fix from gotcha #10.
- Launch from the executable so the env var is inherited (double-clicking in Finder does NOT inherit it):
  `VIPACCESS_DEBUG_FORCE_MIGRATION_FAILURE=1 "build/VIP Access.app/Contents/MacOS/VIPAccess"`

### Manually derive the Symantec keychain password
The keychain password is `"{serial}SymantecVIPAccess{username}"` where `{serial}` is the IOKit `IOPlatformSerialNumber` and `{username}` is the short login name (`NSUserName()` / `id -un`). It is machine- AND account-specific — run this on the target machine/account. One-liner that reproduces exactly what the app computes:
```bash
echo "$(ioreg -c IOPlatformExpertDevice -d 2 | awk -F\" '/IOPlatformSerialNumber/{print $4}')SymantecVIPAccess$(id -un)"
```
Derive it and test the unlock in one shot (read-only, non-destructive to the Symantec keychain):
```bash
PW="$(ioreg -c IOPlatformExpertDevice -d 2 | awk -F\" '/IOPlatformSerialNumber/{print $4}')SymantecVIPAccess$(id -un)"
echo "$PW"
security unlock-keychain -p "$PW" ~/Library/Keychains/VIPAccess.keychain-db && echo UNLOCK_OK || echo UNLOCK_FAIL
```
If `UNLOCK_FAIL`, the derivation inputs don't match what Symantec used at provisioning (usually a renamed/different short username, occasionally a differently-formatted serial) — that is the class of failure that leaves a tester stuck and is exactly what the hint alert (gotchas #10–#11) is meant to surface.
