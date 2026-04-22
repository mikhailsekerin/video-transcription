#!/bin/bash
set -e
cd "$(dirname "$0")"
swift build
cp .build/arm64-apple-macosx/debug/TranscribeApp TranscribeApp.app/Contents/MacOS/TranscribeApp
mkdir -p TranscribeApp.app/Contents/Resources
cp Sources/TranscribeApp/Resources/AppIcon.icns TranscribeApp.app/Contents/Resources/AppIcon.icns
open TranscribeApp.app
