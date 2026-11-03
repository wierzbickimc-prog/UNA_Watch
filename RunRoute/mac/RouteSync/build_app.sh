#!/bin/sh
# Builds build/RouteSync.app.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/RouteSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/RouteSync" "$APP/Contents/MacOS/RouteSync"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
