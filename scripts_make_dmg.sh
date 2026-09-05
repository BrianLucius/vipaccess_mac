#!/bin/bash
#
# Builds a "drag to Applications" style DMG for VIP Access.
# Expects the signed app bundle to already exist at build/VIP Access.app.
#
# Usage: ./scripts_make_dmg.sh
#
set -e

APP_NAME="VIP Access"
BUNDLE_DIR="build/$APP_NAME.app"
DMG_PATH="build/VIPAccess-dev.dmg"
VOL_NAME="$APP_NAME"
STAGING="build/dmg_staging"
TMP_DMG="build/VIPAccess-tmp.dmg"
MOUNT_DIR="/Volumes/$VOL_NAME"

if [ ! -d "$BUNDLE_DIR" ]; then
    echo "Error: $BUNDLE_DIR not found. Run 'make sign-dev' first."
    exit 1
fi

# Clean up any prior state
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
rm -rf "$STAGING" "$TMP_DMG" "$DMG_PATH"

echo "Preparing DMG staging area..."
mkdir -p "$STAGING"
cp -R "$BUNDLE_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "Creating temporary read-write DMG..."
hdiutil create \
    -srcfolder "$STAGING" \
    -volname "$VOL_NAME" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "$TMP_DMG" >/dev/null

echo "Mounting DMG to configure layout..."
hdiutil attach "$TMP_DMG" -noautoopen -mountpoint "$MOUNT_DIR" >/dev/null
sleep 2

echo "Arranging icon layout..."
# Only set properties that are reliable across macOS versions.
# Wrap optional cosmetic settings in try blocks so a failure doesn't abort.
osascript <<EOF || echo "Warning: layout scripting partially failed (cosmetic only)"
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set the bounds of container window to {400, 150, 900, 480}
        try
            set toolbar visible of container window to false
        end try
        try
            set statusbar visible of container window to false
        end try
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        try
            set position of item "$APP_NAME.app" of container window to {120, 165}
        end try
        try
            set position of item "Applications" of container window to {380, 165}
        end try
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
sleep 2

echo "Unmounting..."
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || \
    (sleep 2 && hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1) || true

echo "Converting to final compressed DMG..."
hdiutil convert "$TMP_DMG" -format UDZO -ov -o "$DMG_PATH" >/dev/null

rm -rf "$STAGING" "$TMP_DMG"

echo "DMG created at $DMG_PATH"
