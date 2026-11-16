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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="/Applications/Backbuffer.app"
BUNDLE_ID="io.malachiteore.backbuffer"

OLD_CDHASH=""
if [ -d "$TARGET" ]; then
    OLD_CDHASH="$({ codesign -dvvv "$TARGET" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}'; } || true)"
fi

NEW_CDHASH=""
if [ -d "$SCRIPT_DIR/Backbuffer.app" ]; then
    NEW_CDHASH="$({ codesign -dvvv "$SCRIPT_DIR/Backbuffer.app" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}'; } || true)"
fi

echo "Stopping any running Backbuffer process..."
killall Backbuffer 2>/dev/null || true
for _ in $(seq 1 30); do
    pgrep -x Backbuffer >/dev/null 2>&1 || break
    sleep 0.1
done

if [ -d "$SCRIPT_DIR/Backbuffer.app" ] && [ "$SCRIPT_DIR" != "/Applications" ]; then
    echo "Installing Backbuffer.app to /Applications..."
    rm -rf "$TARGET"
    ditto "$SCRIPT_DIR/Backbuffer.app" "$TARGET"
elif [ ! -d "$TARGET" ]; then
    echo "Backbuffer.app not found in /Applications or next to this script."
    exit 1
fi

echo "Clearing macOS Gatekeeper quarantine flag on $TARGET..."
xattr -cr "$TARGET" || true

if [ -n "$OLD_CDHASH" ] && [ "$OLD_CDHASH" != "$NEW_CDHASH" ]; then
    echo "Detected updated Backbuffer signature; resetting cached Screen Recording and Microphone permissions..."
    /usr/bin/tccutil reset ScreenCapture "$BUNDLE_ID" || true
    /usr/bin/tccutil reset Microphone "$BUNDLE_ID" || true
fi

echo "Launching Backbuffer..."
open "$TARGET"
EOF
chmod +x "$DMG_STAGE/Open First Time (Bypass Gatekeeper).command"

cat <<'EOF' > "$DMG_STAGE/Fix Stuck Screen Recording Permission.command"
#!/bin/bash
set -euo pipefail

TARGET="/Applications/Backbuffer.app"
BUNDLE_ID="io.malachiteore.backbuffer"

echo "Stopping any running Backbuffer process..."
killall Backbuffer 2>/dev/null || true
for _ in $(seq 1 30); do
    pgrep -x Backbuffer >/dev/null 2>&1 || break
    sleep 0.1
done

if [ -d "$TARGET" ]; then
    echo "Clearing Gatekeeper attributes on $TARGET..."
    xattr -cr "$TARGET" || true
fi

echo "Resetting cached Screen Recording and Microphone permissions for $BUNDLE_ID..."
/usr/bin/tccutil reset ScreenCapture "$BUNDLE_ID" || true
/usr/bin/tccutil reset Microphone "$BUNDLE_ID" || true

if [ -d "$TARGET" ]; then
    echo "Relaunching Backbuffer..."
    open "$TARGET"
else
    echo "Install Backbuffer.app to /Applications, then reopen it to grant Screen Recording permission."
fi
EOF
chmod +x "$DMG_STAGE/Fix Stuck Screen Recording Permission.command"

echo "==> Creating $DMG_PATH..."
hdiutil create \
    -volname "Backbuffer" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

ls -lh "$DMG_PATH"
echo "==> Done: $DMG_PATH"
