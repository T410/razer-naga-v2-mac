#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

zsh Scripts/build.sh
NAGA_APP_DIR="${NAGA_APP_DIR:-$PWD/build/Razer NAGA v2.app}"
NAGA_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$NAGA_APP_DIR/Contents/Info.plist")"
NAGA_DMG_FILE="${NAGA_DMG_FILE:-$PWD/build/Razer NAGA v2-$NAGA_VERSION.dmg}"
NAGA_STAGING_DIR="$(mktemp -d "$PWD/build/dmg-staging.XXXXXX")"
NAGA_MOUNT_DIR=""
cleanup() {
    if [[ -n "$NAGA_MOUNT_DIR" ]]; then
        hdiutil detach "$NAGA_MOUNT_DIR" -quiet 2>/dev/null || true
        rmdir "$NAGA_MOUNT_DIR" 2>/dev/null || true
    fi
    if [[ "$NAGA_STAGING_DIR" == "$PWD/build/dmg-staging."* ]]; then rm -rf "$NAGA_STAGING_DIR"; fi
}
trap cleanup EXIT

codesign --verify --strict "$NAGA_APP_DIR"
ditto "$NAGA_APP_DIR" "$NAGA_STAGING_DIR/Razer NAGA v2.app"
ln -s /Applications "$NAGA_STAGING_DIR/Applications"
cp Resources/InstallInstructions.txt "$NAGA_STAGING_DIR/Install.txt"
cp LICENSE "$NAGA_STAGING_DIR/LICENSE.txt"

hdiutil create -volname "Razer NAGA v2" -fs HFS+ -srcfolder "$NAGA_STAGING_DIR" -format UDZO -ov "$NAGA_DMG_FILE"
hdiutil verify "$NAGA_DMG_FILE"
NAGA_MOUNT_DIR="$(mktemp -d "$PWD/build/dmg-check.XXXXXX")"
hdiutil attach "$NAGA_DMG_FILE" -readonly -nobrowse -mountpoint "$NAGA_MOUNT_DIR" -quiet
codesign --verify --strict "$NAGA_MOUNT_DIR/Razer NAGA v2.app"
cmp "$NAGA_APP_DIR/Contents/MacOS/Naga" "$NAGA_MOUNT_DIR/Razer NAGA v2.app/Contents/MacOS/Naga"
cmp Resources/InstallInstructions.txt "$NAGA_MOUNT_DIR/Install.txt"
cmp LICENSE "$NAGA_MOUNT_DIR/LICENSE.txt"
cmp LICENSE "$NAGA_MOUNT_DIR/Razer NAGA v2.app/Contents/Resources/LICENSE.txt"
[[ "$(readlink "$NAGA_MOUNT_DIR/Applications")" == /Applications ]]
(
    cd "${NAGA_DMG_FILE:h}"
    shasum -a 256 "${NAGA_DMG_FILE:t}" > "${NAGA_DMG_FILE:t}.sha256"
)
print "DMG ready: $NAGA_DMG_FILE"
