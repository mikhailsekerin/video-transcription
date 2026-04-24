#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Building…"
swift build

# Find the binary in any architecture-specific build folder
BINARY=$(find .build -name "TranscribeApp" -type f -path "*/debug/*" 2>/dev/null | head -1)

if [ -z "$BINARY" ]; then
    echo "❌ Error: Build produced no binary"
    echo "Check .build directory:"
    ls -la .build/ 2>/dev/null || echo "  .build directory not found"
    exit 1
fi

echo "Binary found at: $BINARY"

mkdir -p TranscribeApp.app/Contents/MacOS
mkdir -p TranscribeApp.app/Contents/Resources
cp "$BINARY" TranscribeApp.app/Contents/MacOS/TranscribeApp
cp Sources/TranscribeApp/Resources/AppIcon.icns TranscribeApp.app/Contents/Resources/AppIcon.icns

echo "Build complete! Opening app…"
pkill -x TranscribeApp 2>/dev/null; sleep 0.3
codesign --force --deep --sign - TranscribeApp.app 2>/dev/null
open TranscribeApp.app
