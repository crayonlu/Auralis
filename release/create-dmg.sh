#!/bin/bash

# Creates a DMG from a pre-built Auralis.app
# Usage: ./release/create-dmg.sh [path-to-Auralis.app]
# If no path is given, builds from source with xcodebuild archive.
# Note: a source build requires the QCloudMusicApi checkout at ../QCloudMusicApi
# and Qt installed at ../Qt/<version>/macos (see .github/workflows/build.yml).

set -ex

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 1

APP_PATH="${1:-}"

if [ -z "$APP_PATH" ]; then
    # No app path provided - build from source
    xcodebuild archive \
        -project Auralis.xcodeproj \
        -scheme Auralis \
        -configuration Release \
        -archivePath Auralis.xcarchive \
        ONLY_ACTIVE_ARCH=NO
    APP_PATH="Auralis.xcarchive/Products/Applications/Auralis.app"
fi

# Resolve to an absolute path before we cd into release/
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Auralis.app not found at $APP_PATH"
    exit 1
fi

cd release
hdiutil detach /Volumes/Auralis 2>/dev/null || true
rm -f *.dmg
hdiutil create -size 200m -fs APFS -volname "Auralis" -o Auralis-tmp.dmg
hdiutil attach Auralis-tmp.dmg -noverify -mountpoint /Volumes/Auralis

cp -r "$APP_PATH" /Volumes/Auralis/
ln -s /Applications /Volumes/Auralis/Applications

osascript layout.scpt

hdiutil detach /Volumes/Auralis
hdiutil convert Auralis-tmp.dmg -format UDZO -o Auralis.dmg

rm Auralis-tmp.dmg
cd ..
rm -rf Auralis.xcarchive 2>/dev/null || true

echo "✅ DMG created at release/Auralis.dmg"
