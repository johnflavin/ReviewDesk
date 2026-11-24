#!/bin/bash
# Builds build/ReviewDesk.app with SwiftPM.
# Usage: ./build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP="build/ReviewDesk.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift build -c "$CONFIG" --product ReviewDesk
cp "$(swift build -c "$CONFIG" --show-bin-path)/ReviewDesk" "$APP/Contents/MacOS/ReviewDesk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
