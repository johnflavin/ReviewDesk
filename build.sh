#!/bin/bash
# Builds build/ReviewDesk.app with swiftc directly (no SwiftPM or Xcode needed).
# Usage: ./build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
APP="build/ReviewDesk.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

FLAGS=(-parse-as-library -swift-version 5 -module-name ReviewDesk -target "$(uname -m)-apple-macosx15.0")
if [ "$CONFIG" = release ]; then FLAGS+=(-O); else FLAGS+=(-Onone -g); fi

find Sources/ReviewDesk -name '*.swift' -print0 | xargs -0 swiftc "${FLAGS[@]}" -o "$APP/Contents/MacOS/ReviewDesk"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
