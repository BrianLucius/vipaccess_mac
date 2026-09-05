---
inclusion: always
---

# VIP Access (Swift) — Build, Signing & Distribution

## Everyday build commands
- `swift build` — debug build.
- `swift build -c release` — optimized release.
- `swift test` — run the test suite (XCTest + Swift Testing suites).
- `make bundle` — assemble the unsigned `.app` at `build/VIP Access.app`.
- `make dev` — bundle AND sign with the self-signed `VIPAccess Dev` identity. **Use this for normal development** so keychain access survives rebuilds.

## Self-signed development signing (why it exists)
The app stores its credential in the login keychain, which ties access to the
binary's code signature. Unsigned/ad-hoc rebuilds each look like a new app and
re-trigger keychain prompts. Signing every build with one stable certificate fixes
this (after a one-time "Always Allow").

- **One-time per machine:** `make dev-cert` → runs `scripts_create_dev_cert.sh`, which creates a self-signed code-signing cert named `VIPAccess Dev`, imports it into the login keychain, and trusts it for code signing (needs admin password).
- **The cert is machine-specific.** A build signed on one machine is not "the same app" to another machine's keychain. Keep the cert stable; don't regenerate it casually.
- Entitlements for dev signing: `VIPAccess/VIPAccess-dev.entitlements` — MUST stay minimal (`app-sandbox = false` only). Never add `keychain-access-groups` here (see gotchas #4 — it makes the app un-launchable under self-signing).

## Packaging for peers (internal, self-signed)
- `make zip-dev` → `build/VIPAccess-dev.zip` (simple archive).
- `make dmg-dev` → `build/VIPAccess-dev.dmg` with a "drag to Applications" layout. This calls `scripts_make_dmg.sh`, which stages the app + an `/Applications` symlink, mounts a read-write DMG, arranges icon positions via AppleScript (cosmetic steps wrapped in `try` so Finder quirks don't abort), then converts to a compressed read-only DMG.
- Both packages are not notarized, so the first launch triggers Gatekeeper. Peers either right-click → Open once, or run `xattr -dr com.apple.quarantine "/Applications/VIP Access.app"`.

## Full Developer ID distribution (paid Apple account, optional)
- `make sign DEVELOPER_ID="Developer ID Application: Name (TEAMID)"` — hardened-runtime sign using `VIPAccess/VIPAccess.entitlements`.
- `make distribute APPLE_ID=... TEAM_ID=...` — full `sign → dmg → notarize → staple` pipeline.
- Only with a real Developer ID + team ID could the app move to the data protection keychain (team-prefixed `keychain-access-groups`) for a fully prompt-free keychain experience.

## App bundle contents (assembled by `make bundle`)
```
VIP Access.app/Contents/
  Info.plist                      # LSUIElement, NSServices, macOS 26 min
  MacOS/VIPAccess                 # the executable
  Resources/
    icon.png, icon.icns           # icns referenced by CFBundleIconFile
    VIPAccess_VIPAccess.bundle/   # SPM resource bundle (pin_color.png, pin_grey.png, Assets)
```
- If pin icons or window resources go missing at runtime, confirm `VIPAccess_VIPAccess.bundle` was copied into `Contents/Resources/` (see gotchas #6).

## Helper scripts
- `scripts_create_dev_cert.sh` — idempotent; skips if `VIPAccess Dev` already exists. Uses `openssl ... pkcs12 -export -legacy` (macOS `security import` can't read modern OpenSSL 3 PKCS#12 MAC) with a temp password, then trusts via `sudo security add-trusted-cert -r trustRoot -p codeSign`.
- `scripts_make_dmg.sh` — the "drag to Applications" DMG builder described above.

## Distribution UX summary for peers
1. Open the DMG (or unzip) and drag **VIP Access.app** to `/Applications`.
2. First launch: right-click → Open (one time), or strip quarantine via `xattr`.
3. First launch migrates the credential from their Symantec keychain; a one-time "Always Allow" keychain prompt is expected.
4. Enable the paste Service via the in-app "Enable Paste Service…" menu item (or System Settings → Keyboard → Keyboard Shortcuts → Services → Text). If it doesn't appear, `pbs -flush`.
