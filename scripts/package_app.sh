#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Building Universal Binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
UNIVERSAL_BIN="$BIN_DIR/BackbufferApp"
if [ ! -f "$UNIVERSAL_BIN" ]; then
    UNIVERSAL_BIN=".build/apple/Products/Release/BackbufferApp"
fi
if [ ! -f "$UNIVERSAL_BIN" ]; then
    echo "Error: Universal binary not found at $UNIVERSAL_BIN" >&2
    exit 1
fi

ARCHS="$(lipo -archs "$UNIVERSAL_BIN")"
echo "==> Verified binary architectures: $ARCHS"
if [[ "$ARCHS" != *"arm64"* ]] || [[ "$ARCHS" != *"x86_64"* ]]; then
    echo "Error: Expected both arm64 and x86_64 in Universal binary, got: $ARCHS" >&2
    exit 1
fi

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Backbuffer.app"
DMG_STAGE="$DIST_DIR/dmg"
DMG_PATH="$DIST_DIR/Backbuffer-Universal.dmg"

rm -rf "$APP_BUNDLE" "$DMG_STAGE" "$DMG_PATH"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$DMG_STAGE"

echo "==> Assembling Backbuffer.app bundle..."
cp "$UNIVERSAL_BIN" "$APP_BUNDLE/Contents/MacOS/Backbuffer"
chmod +x "$APP_BUNDLE/Contents/MacOS/Backbuffer"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Generating AppIcon.icns..."
swift "$SCRIPT_DIR/generate_icon.swift" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing Backbuffer.app..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> Staging Universal DMG..."
ditto "$APP_BUNDLE" "$DMG_STAGE/Backbuffer.app"
ln -s /Applications "$DMG_STAGE/Applications"

cat <<'EOF' > "$DMG_STAGE/Open First Time (Bypass Gatekeeper).command"
#!/bin/bash
set -euo pipefail

TARGET="/Applications/Backbuffer.app"
if [ ! -d "$TARGET" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -d "$SCRIPT_DIR/Backbuffer.app" ]; then
        TARGET="$SCRIPT_DIR/Backbuffer.app"
    else
        echo "Backbuffer.app not found in /Applications. Drag Backbuffer.app to Applications first."
        exit 1
    fi
fi

echo "Clearing macOS quarantine flag on $TARGET..."
xattr -cr "$TARGET" || true
open "$TARGET"
EOF
chmod +x "$DMG_STAGE/Open First Time (Bypass Gatekeeper).command"

echo "==> Creating $DMG_PATH..."
hdiutil create \
    -volname "Backbuffer" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

ls -lh "$DMG_PATH"
echo "==> Done: $DMG_PATH"
