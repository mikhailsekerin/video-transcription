#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Building arm64…"
swift build -c release --arch arm64

echo "Building x86_64…"
swift build -c release --arch x86_64

echo "Creating universal binary…"
lipo -create \
  .build/arm64-apple-macosx/release/TranscribeApp \
  .build/x86_64-apple-macosx/release/TranscribeApp \
  -output TranscribeApp-universal

mkdir -p TranscribeApp.app/Contents/MacOS
mkdir -p TranscribeApp.app/Contents/Resources
cp TranscribeApp-universal TranscribeApp.app/Contents/MacOS/TranscribeApp
cp Sources/TranscribeApp/Resources/AppIcon.icns TranscribeApp.app/Contents/Resources/AppIcon.icns
cp Sources/TranscribeApp/Resources/Info.plist TranscribeApp.app/Contents/Info.plist
rm TranscribeApp-universal

echo "Signing…"
codesign --force --deep --sign - TranscribeApp.app

echo "Creating DMG…"
rm -rf dmg-root
mkdir -p dmg-root
cp -R TranscribeApp.app dmg-root/
ln -s /Applications dmg-root/Applications
hdiutil create -volname "Video Transcriber" -srcfolder dmg-root -ov -format UDZO -o VideoTranscriber.dmg
rm -rf dmg-root

echo "✅ Done: $(du -sh VideoTranscriber.dmg | cut -f1) — VideoTranscriber.dmg"
