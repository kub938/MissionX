#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/module-cache}"
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
APP="$PWD/dist/MissionX.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/MissionX" "$APP/Contents/MacOS/MissionX"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/MissionX" --self-test
printf 'Created: %s\n' "$APP"
