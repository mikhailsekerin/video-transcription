#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="VTT"
DMG_NAME="VTT-VideoTranscriber.dmg"
APP_BUNDLE="TranscribeApp.app"

echo "▸ Building release binary…"
swift build -c release

echo "▸ Updating app bundle…"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Find the binary in any architecture-specific build folder
BINARY=$(find .build -name "TranscribeApp" -type f -path "*/release/*" 2>/dev/null | head -1)
if [ -z "$BINARY" ]; then
    echo "❌ Error: Release build produced no binary"
    exit 1
fi

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/TranscribeApp"
cp Sources/TranscribeApp/Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "▸ Code signing (ad-hoc)…"
codesign --sign - --force --deep "$APP_BUNDLE"

echo "▸ Creating DMG…"
rm -f "$DMG_NAME"

# Staging folder: app + Applications symlink
STAGING=$(mktemp -d)
cp -R "$APP_BUNDLE" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME – Video Transcriber" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_NAME"

rm -rf "$STAGING"

echo ""
echo "✓ Done: $DMG_NAME"
echo ""
echo "Note: colleagues need to right-click → Open the first time"
echo "      (Gatekeeper warning due to ad-hoc signing)."
