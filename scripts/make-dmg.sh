#!/bin/bash
# Builds MacHub for release and packs it in a disk image (background, Applications shortcut, volume icon).
#
#   scripts/make-dmg.sh [output-dir]           (default: build/release)
#
# By default the app is only ad-hoc signed (no Apple account): it runs on any Apple silicon Mac, but macOS asks the
# user to confirm the first launch (Privacy & Security › Open Anyway). MacHub is not signed with any developer
# account for now. To sign and notarize later:
# SIGN_IDENTITY   a "Developer ID Application: …" identity. Never picked automatically, so a certificate that
#                 belongs to another project can't end up on MacHub by mistake.
# NOTARY_PROFILE  notarytool keychain profile, created once with
#                 xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>
# NOTARY_KEYCHAIN keychain holding that profile, when it isn't the login keychain (CI)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/release}"
WORK="$ROOT/build/dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then echo "Ad-hoc signature (no developer account)"; else echo "Signing with: $SIGN_IDENTITY"; fi

rm -rf "$WORK"; mkdir -p "$WORK" "$OUT"

# 1. Release build. With a Developer ID: hardened runtime and secure timestamp, as notarization requires.
SIGN_FLAGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
[[ "$SIGN_IDENTITY" == "-" ]] || SIGN_FLAGS+=(ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp")
xcodebuild -project "$ROOT/MacHub.xcodeproj" -scheme MacHub -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath "$WORK/dd" "${SIGN_FLAGS[@]}" build -quiet
APP="$WORK/dd/Build/Products/Release/MacHub.app"
codesign --verify --deep --strict "$APP"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  [[ "$(codesign -dv "$APP" 2>&1)" == *"(runtime)"* ]] || { echo "Hardened runtime missing" >&2; exit 1; }
fi
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
[[ "$SIGN_IDENTITY" == "-" ]] || codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

# 3. Notarization and stapling (only with a Developer ID).
if [[ "$SIGN_IDENTITY" != "-" && -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
else
  echo "Not notarized: macOS will ask users to confirm the first launch"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Done: $DMG"
