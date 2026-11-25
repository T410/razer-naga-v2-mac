#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Prefer the full Xcode toolchain, which includes SwiftUI/Testing plugins.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c release
NAGA_BIN_DIR="$(swift build -c release --show-bin-path)"
NAGA_APP_DIR="${NAGA_APP_DIR:-$PWD/build/Razer NAGA v2.app}"
mkdir -p "$NAGA_APP_DIR/Contents/MacOS" "$NAGA_APP_DIR/Contents/Resources"
cp "$NAGA_BIN_DIR/Naga" "$NAGA_APP_DIR/Contents/MacOS/Naga"
cp Resources/Info.plist "$NAGA_APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$NAGA_APP_DIR/Contents/Resources/AppIcon.icns"
cp LICENSE "$NAGA_APP_DIR/Contents/Resources/LICENSE.txt"
codesign --force --sign "${NAGA_SIGNING_IDENTITY:--}" --identifier com.tayyib.Naga "$NAGA_APP_DIR"
print "Built: $NAGA_APP_DIR"
