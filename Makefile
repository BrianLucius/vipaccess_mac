.PHONY: build release universal test clean bundle sign dmg notarize staple distribute dev-cert sign-dev dev zip-dev dmg-dev

APP_NAME = VIP Access
BUNDLE_DIR = build/$(APP_NAME).app
CONTENTS_DIR = $(BUNDLE_DIR)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources
ENTITLEMENTS = VIPAccess/VIPAccess.entitlements
DMG_PATH = build/VIPAccess.dmg
DEV_IDENTITY = VIPAccess Dev
DEV_ENTITLEMENTS = VIPAccess/VIPAccess-dev.entitlements
DEV_ZIP_PATH = build/VIPAccess-dev.zip
DEV_DMG_PATH = build/VIPAccess-dev.dmg

# Code signing and notarization configuration.
# Override these on the command line or export them in your environment:
#   make sign DEVELOPER_ID="Developer ID Application: Jane Doe (ABCDE12345)"
#   make notarize APPLE_ID="jane@example.com" TEAM_ID="ABCDE12345"
DEVELOPER_ID ?= Developer ID Application: YOUR_NAME (TEAM_ID)
APPLE_ID ?= your@email.com
TEAM_ID ?= XXXXXXXXXX

# ---------------------------------------------------------------------------
# Build targets
# ---------------------------------------------------------------------------

build:
	swift build

release:
	swift build -c release

universal:
	swift build -c release --arch arm64 --arch x86_64

test:
	swift test

clean:
	swift package clean
	rm -rf build

bundle: release
	@echo "Creating app bundle..."
	rm -rf "$(BUNDLE_DIR)"
	mkdir -p "$(MACOS_DIR)"
	mkdir -p "$(RESOURCES_DIR)"
	cp .build/release/VIPAccess "$(MACOS_DIR)/VIPAccess"
	cp VIPAccess/Info.plist "$(CONTENTS_DIR)/Info.plist"
	cp icon.png "$(RESOURCES_DIR)/icon.png"
	cp icon.icns "$(RESOURCES_DIR)/icon.icns"
	cp -R .build/release/VIPAccess_VIPAccess.bundle "$(RESOURCES_DIR)/VIPAccess_VIPAccess.bundle"
	@echo "Bundle created at $(BUNDLE_DIR)"

# ---------------------------------------------------------------------------
# Development Signing (self-signed, for internal testing)
# ---------------------------------------------------------------------------

## Create the stable self-signed "VIPAccess Dev" code-signing certificate.
## Run once per development machine. Prompts for your admin password.
dev-cert:
	./scripts_create_dev_cert.sh

## Sign the .app with the self-signed development identity.
## This gives every build a consistent signature so macOS keychain access
## is preserved across rebuilds (no more "can't read previous entries").
sign-dev: bundle
	@echo "Signing $(BUNDLE_DIR) with development identity '$(DEV_IDENTITY)'..."
	codesign --force --deep --sign "$(DEV_IDENTITY)" \
		--entitlements "$(DEV_ENTITLEMENTS)" \
		"$(BUNDLE_DIR)"
	@echo "Verifying signature..."
	codesign --verify --deep --strict "$(BUNDLE_DIR)"
	@echo "Development signature OK."

## Full development build: bundle + sign with self-signed identity.
dev: sign-dev
	@echo "Development build complete and signed: $(BUNDLE_DIR)"

## Package the signed development build into a distributable .zip.
zip-dev: sign-dev
	@echo "Creating zip archive at $(DEV_ZIP_PATH) ..."
	rm -f "$(DEV_ZIP_PATH)"
	cd build && zip -qr -y "../$(DEV_ZIP_PATH)" "$(APP_NAME).app"
	@echo "Zip created at $(DEV_ZIP_PATH)"
	@echo "Share this with peers. On first launch they right-click the app -> Open,"
	@echo "or run: xattr -dr com.apple.quarantine \"/Applications/$(APP_NAME).app\""

## Package the signed development build into a distributable .dmg
## with a "drag to Applications" layout.
dmg-dev: sign-dev
	./scripts_make_dmg.sh
	@echo "Share this with peers. On first launch they right-click the app -> Open,"
	@echo "or run: xattr -dr com.apple.quarantine \"/Applications/$(APP_NAME).app\""

# ---------------------------------------------------------------------------
# Code Signing and Distribution
# ---------------------------------------------------------------------------

## Sign the .app bundle with a Developer ID certificate and hardened runtime.
## Requires a valid "Developer ID Application" identity in your keychain.
sign: bundle
	@echo "Signing $(BUNDLE_DIR) ..."
	codesign --force --deep --sign "$(DEVELOPER_ID)" \
		--options runtime \
		--entitlements "$(ENTITLEMENTS)" \
		"$(BUNDLE_DIR)"
	@echo "Verifying signature..."
	codesign --verify --deep --strict "$(BUNDLE_DIR)"
	@echo "Signature OK."

## Create a distributable DMG disk image from the signed app bundle.
dmg: sign
	@echo "Creating DMG at $(DMG_PATH) ..."
	hdiutil create -volname "$(APP_NAME)" \
		-srcfolder "$(BUNDLE_DIR)" \
		-ov -format UDZO \
		"$(DMG_PATH)"
	@echo "DMG created at $(DMG_PATH)"

## Submit the DMG to Apple's notary service and wait for approval.
## Requires valid Apple ID credentials stored in the keychain:
##   xcrun notarytool store-credentials "AC_PASSWORD" \
##       --apple-id "your@email.com" --team-id "TEAM_ID" --password "app-specific-password"
notarize: dmg
	@echo "Submitting $(DMG_PATH) for notarization..."
	xcrun notarytool submit "$(DMG_PATH)" \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(TEAM_ID)" \
		--password "@keychain:AC_PASSWORD" \
		--wait
	@echo "Notarization complete."

## Staple the notarization ticket to the DMG so it can be verified offline.
staple: notarize
	@echo "Stapling notarization ticket to $(DMG_PATH) ..."
	xcrun stapler staple "$(DMG_PATH)"
	@echo "Staple complete."

## Full distribution pipeline: build → sign → DMG → notarize → staple.
distribute: staple
	@echo "Distribution build complete: $(DMG_PATH)"
