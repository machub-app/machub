#!/bin/bash
# Builds MacHub for release, signs it with a Developer ID, packs it in a disk image (background, Applications
# shortcut), then notarizes and staples the image so it opens without Gatekeeper warnings.
#
#   scripts/make-dmg.sh [output-dir]           (default: build/release)
#
# SIGN_IDENTITY   codesign identity (default: the first "Developer ID Application" in the keychain)
# NOTARY_PROFILE  notarytool keychain profile, created once with
#                 xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>
#                 Without it, the image is signed but not notarized (fine for testing, not for publishing).
# NOTARY_KEYCHAIN keychain holding that profile, when it isn't the login keychain (CI)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/release}"
WORK="$ROOT/build/dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[[ -n "$SIGN_IDENTITY" ]] || { echo "No Developer ID Application certificate in the keychain" >&2; exit 1; }
echo "Signing with: $SIGN_IDENTITY"

rm -rf "$WORK"; mkdir -p "$WORK" "$OUT"

# 1. Release build, signed with the Developer ID, hardened runtime and secure timestamp (required by notarization).
xcodebuild -project "$ROOT/MacHub.xcodeproj" -scheme MacHub -configuration Release -destination "generic/platform=macOS" -derivedDataPath "$WORK/dd" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build -quiet
APP="$WORK/dd/Build/Products/Release/MacHub.app"
codesign --verify --deep --strict "$APP"
[[ "$(codesign -dv "$APP" 2>&1)" == *"(runtime)"* ]] || { echo "Hardened runtime missing" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/MacHub-$VERSION.dmg"

# 2. Disk image: the app, a shortcut to Applications, a background and a fixed window layout.
STAGE="$WORK/stage"; mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/MacHub.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/tools/dmg/background.tiff" "$STAGE/.background/background.tiff"
hdiutil create -quiet -volname MacHub -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | tail -1)"
# Finder layout (needs Finder automation permission; the image still works without it, just less pretty).
osascript <<OSA || echo "Finder layout skipped (allow Terminal to control Finder to get it)"
tell application "Finder"
  tell disk "$(basename "$MOUNT")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 860, 520}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "MacHub.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
# Volume icon, set after the Finder step (Finder drops a .VolumeIcon.icns that is already there).
cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns" && SetFile -a C "$MOUNT"
sync; hdiutil detach -quiet "$MOUNT"
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULMO -o "$DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

# 3. Notarization and stapling.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
else
  echo "NOTARY_PROFILE not set: $DMG is signed but NOT notarized"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Done: $DMG"
