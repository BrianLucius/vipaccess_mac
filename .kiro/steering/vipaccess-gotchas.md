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
- **Fix:** `readCredential()` runs the `/usr/bin/security unlock-keychain` + `find-generic-password` CLI path FIRST; the deprecated `SecKeychain*` APIs are the fallback. If the fallback runs, `showKeychainPasswordHint(_:)` shows the derived password and copies it to the clipboard so the user can paste it into the system dialog.

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
