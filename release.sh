#!/bin/bash
# Builds, signs, notarizes and publishes the version in Info.plist as a release of this repo (the one origin points
# to), where the app's updater looks: a zip for the updater and a DMG for installing by hand. Then installs that
# exact build into ~/Applications. Release notes are the version's section of CHANGELOG.md.
# One-time setup: xcrun notarytool store-credentials screentools, gh logged in as the repo's owner, and a signing
# identity (see signing.sh).
set -euo pipefail
cd "$(dirname "$0")"

REPO=$(git remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP="build/RubberMAC.app"
ZIP="dist/RubberMAC-$VERSION.zip"
DMG="dist/RubberMAC-$VERSION.dmg"
INSTALLED="$HOME/Applications/RubberMAC.app"
export GH_TOKEN="$(gh auth token --user "${REPO%%/*}")"

NOTES=$(awk -v v="## $VERSION" '$0 == v {f=1; next} /^## / {f=0} f' CHANGELOG.md)
[ -n "$NOTES" ] || { echo "CHANGELOG.md has no '## $VERSION' section"; exit 1; }
if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then echo "v$VERSION is already released"; exit 1; fi

# Leaves the notarized, stapled app in build/ and the DMG in dist/.
./dmg.sh
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

gh release create "v$VERSION" "$ZIP" "$DMG" -R "$REPO" --title "RubberMAC $VERSION" --notes "$NOTES"

pkill -x ScreenTools || true
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
open "$INSTALLED"
echo "released v$VERSION and installed it"
