#!/bin/bash
# Builds "RubberMAC.app" into ~/Applications and relaunches it.
# Signed with the Developer ID so the Accessibility grant survives rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/RubberMAC.app"
. ./signing.sh

mkdir -p build
swiftc -O -o build/ScreenTools src/*.swift

pkill -x ScreenTools || true
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp build/ScreenTools "$APP/Contents/MacOS/ScreenTools"
mkdir -p "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$APP/Contents/Resources/Fonts"
ditto fonts/AtkinsonHyperlegibleNext "$APP/Contents/Resources/Fonts"
codesign --force --options runtime --entitlements ScreenTools.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

open "$APP"
echo "built and launched $APP"
