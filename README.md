# VIP Access — Swift macOS Menu Bar App

A native macOS menu bar application that generates Symantec VIP Access TOTP tokens. Displays the current token in the menu bar, provides a right-click Services menu for auto-paste into any text field, and includes an optional floating window.

## Prerequisites

- macOS 26.0 (Tahoe) or later
- Swift 5.9+ / Xcode command line tools
- **An existing `~/Library/Keychains/VIPAccess.keychain-db`** — the Symantec VIP Access desktop app must have been provisioned at least once on this machine. The Swift app migrates the credential from that keychain on first launch; it does not provision new tokens.

## Building

```bash
# Debug build
swift build

# Release build
swift build -c release

# Universal binary (Apple Silicon + Intel)
make universal

# Create .app bundle (release build + bundle structure)
make bundle

# Run tests
swift test
```

### Development Signing (recommended for internal testing)

For internal distribution and day-to-day development, sign the app with a stable
self-signed certificate. This gives every build a consistent code signature, which
helps macOS recognize successive builds as the same application. Without a stable
signature, each rebuild looks like a brand-new app and macOS re-prompts for
keychain access on every launch.

> **Note on keychain prompts:** The credential is stored in the login keychain,
> which protects items with a per-application access control list (ACL). The first
> time a build signed with your `VIPAccess Dev` certificate accesses the item, macOS
> shows a keychain prompt — click **Always Allow** once. Because a fully
> prompt-free experience requires the *data protection keychain* with a
> team-prefixed access group (only available with a paid Apple Developer ID), the
> one-time "Always Allow" per install is expected with self-signed builds.

**One-time setup per machine** (prompts for your admin password):

```bash
make dev-cert
```

This runs `scripts_create_dev_cert.sh`, which creates and trusts a code-signing
certificate named `VIPAccess Dev`.

**Build and sign** (use this instead of `make bundle`):

```bash
make dev
```

This bundles the app and signs it with the `VIPAccess Dev` identity. Because every
build shares the same signature, macOS recognizes them as the same app — after a
one-time **Always Allow** on the keychain prompt, subsequent same-signed builds
read the stored credential without re-migrating.

> **Note:** The `VIPAccess Dev` certificate is unique to each machine. A build
> signed on your machine is not recognized as "the same app" on another machine
> for keychain-ownership purposes. That only matters if a user swaps between
> differently-signed builds; a single distributed build writes and reads its own
> keychain entry normally.

### Distributing to peers (internal)

Package the signed development build for distribution:

```bash
make zip-dev    # produces build/VIPAccess-dev.zip
# or
make dmg-dev    # produces build/VIPAccess-dev.dmg
```

Both package the same self-signed build; choose whichever is more convenient.
The **DMG presents a "drag to Applications" install window** (app icon on the left,
an Applications shortcut on the right); the **zip** is a simpler archive. Since
every build you sign carries your stable `VIPAccess Dev` signature, peers can drop
in newer builds you send them and macOS treats them as the same app. On a peer's
machine the app writes its own keychain entry on first launch; they may see a
one-time keychain prompt (click **Always Allow**).

**Peer install instructions (share these):**

1. Unzip (or mount the DMG) and drag **VIP Access.app** to `/Applications`.
2. The build is signed but not notarized, so the first launch triggers Gatekeeper.
   Do one of the following **once**:
   - **Right-click** the app → **Open** → confirm in the dialog, **or**
   - Run in Terminal:
     ```bash
     xattr -dr com.apple.quarantine "/Applications/VIP Access.app"
     ```
3. Subsequent launches — and any future builds signed with the same certificate —
   open normally.

If peers build from source themselves, they run `make dev-cert` once, then `make dev`.

> **Keep your `VIPAccess Dev` certificate stable.** Every build must be signed with
> the same certificate for the seamless-update behavior to hold. If you regenerate
> the certificate or build on a different machine, peers' Macs will treat the app as
> new and re-trigger migration/Gatekeeper.

### Distribution (Developer ID signing + notarization)

For friction-free distribution (no Gatekeeper prompts), sign with an Apple
**Developer ID Application** certificate (requires a paid Apple Developer Program
membership) and notarize:

```bash
make sign DEVELOPER_ID="Developer ID Application: Your Name (TEAM_ID)"
make distribute APPLE_ID="you@example.com" TEAM_ID="XXXXXXXXXX"
```

See the `Makefile` for the full `sign → dmg → notarize → staple` pipeline.

## Enabling the Service

The app registers a macOS Service called **"Paste VIP Access Token"** that inserts the current TOTP code into any editable text field via right-click.

### Recommended: use the in-app helper

Click the menu bar token, then choose **"Enable Paste Service…"** from the dropdown.
This opens System Settings to the Keyboard pane and displays step-by-step
instructions. This is the easiest path and the one to share with users.

### Manual steps

If you prefer to navigate manually:

1. Open **System Settings → Keyboard → Keyboard Shortcuts… → Services → Text**.
2. Find **"Paste VIP Access Token"** and enable the checkbox.
3. Optionally assign a keyboard shortcut.

Once enabled, right-click in any text field and choose **Services → Paste VIP Access Token** to insert the current code.

> **If the service doesn't appear** in the Services list, make sure VIP Access is
> running, then refresh the Services database by running
> `/System/Library/CoreServices/pbs -flush` in Terminal (or log out and back in).

## Migration Behavior

On first launch, the app looks for its credential in the app's own login-keychain
entry (via the `SecItem` API, service `com.vipaccess.credential`). If not found, it
performs a one-time migration:

1. Locates `~/Library/Keychains/VIPAccess.keychain-db` (falls back to `.keychain`).
2. Derives the unlock password from the Mac serial number and username.
3. Unlocks the keychain and reads the `CredentialStore` entry — preferring the
   `/usr/bin/security` CLI (which avoids a macOS authorization dialog), with the
   deprecated `SecKeychain*` APIs as a fallback.
4. Decrypts the credential (AES-128-CBC) and stores it in the app's own login
   keychain entry for fast access on future launches.

Key properties:

- **Non-destructive** — the Symantec keychain is only read, never modified or deleted.
- **Idempotent** — if the app's keychain entry is lost (reinstall, keychain reset), it re-migrates automatically.
- **One-time** — after migration, subsequent launches read directly from the app's own keychain entry with no legacy keychain interaction.

If you re-provision your credential through Symantec VIP Access, use **Re-migrate Credential** from the menu bar dropdown to pick up the new credential.

## Helper Scripts

- **`scripts_create_dev_cert.sh`** — creates and trusts the stable self-signed
  `VIPAccess Dev` code-signing certificate. Run once per machine (or via
  `make dev-cert`).
- **`scripts_make_dmg.sh`** — builds the "drag to Applications" DMG (staging folder
  with an Applications symlink, Finder icon layout, compressed output). Invoked by
  `make dmg-dev`.

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make build` | Debug build |
| `make release` | Optimized release build |
| `make universal` | Universal binary (arm64 + x86_64) |
| `make bundle` | Assemble the unsigned `.app` bundle |
| `make test` | Run the test suite |
| `make dev-cert` | Create/trust the self-signed dev certificate (once per machine) |
| `make dev` | Build, bundle, and sign with the dev certificate |
| `make zip-dev` | Signed build packaged as a `.zip` |
| `make dmg-dev` | Signed build packaged as a "drag to Applications" `.dmg` |
| `make sign` | Sign with a Developer ID certificate (paid Apple account) |
| `make distribute` | Full Developer ID pipeline: sign → dmg → notarize → staple |
| `make clean` | Remove build artifacts |

## Known Limitations

- **No token provisioning** — cannot create new VIP Access tokens. Requires Symantec VIP Access to have been provisioned first.
- **macOS only** — no cross-platform support.
- **Deprecated APIs used for migration** — the legacy `SecKeychain*` APIs are used to read the Symantec keychain. These are isolated in `LegacyKeychainReader.swift` and only execute on first launch. A fallback to the `/usr/bin/security` CLI exists if the deprecated APIs are removed in a future macOS release.
- **No CLI interface** — this is a GUI-only app.
- **One-time keychain prompt with self-signed builds** — a fully prompt-free
  keychain experience requires a paid Apple Developer ID (for the data protection
  keychain with a team-prefixed access group). With self-signed development builds,
  expect a single "Always Allow" keychain prompt per install.
