#!/bin/bash
# Builds the version in Info.plist into a disk image to hand to someone: dist/RubberMAC-<version>.dmg, holding the
# app and a link to Applications, signed, notarized and stapled so it opens on another Mac. Publishes nothing (the
# updater's feed is release.sh's job) and leaves the installed app alone.
# One-time setup: xcrun notarytool store-credentials screentools, and a signing identity (see signing.sh).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP="build/RubberMAC.app"
ZIP="build/RubberMAC-$VERSION-notarize.zip"
STAGE="build/dmg"
DMG="dist/RubberMAC-$VERSION.dmg"
. ./signing.sh

mkdir -p build dist
swiftc -O -o build/ScreenTools src/*.swift
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp build/ScreenTools "$APP/Contents/MacOS/ScreenTools"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto fonts/AtkinsonHyperlegibleNext "$APP/Contents/Resources/Fonts"
codesign --force --options runtime --entitlements ScreenTools.entitlements --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

# The app is notarized and stapled on its own first, so a copy dragged out of the image also opens offline.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile screentools --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

# Filled through a mount point of its own: macOS can refuse a script access to images mounted under /Volumes, which
# is where `hdiutil create -srcfolder` mounts its working copy ("create failed - Operation not permitted").
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE/mount"
hdiutil create -size "$(( $(du -sm "$APP" | cut -f1) + 20 ))m" -fs HFS+ -volname "RubberMAC $VERSION" -type UDIF "$STAGE/rw.dmg"
hdiutil attach -nobrowse -noautoopen -mountpoint "$STAGE/mount" "$STAGE/rw.dmg"
ditto "$APP" "$STAGE/mount/RubberMAC.app"
ln -s /Applications "$STAGE/mount/Applications"
hdiutil detach "$STAGE/mount"
hdiutil convert "$STAGE/rw.dmg" -format UDZO -o "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile screentools --wait
xcrun stapler staple "$DMG"

spctl --assess --type execute -vv "$APP"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
echo "made $DMG"
