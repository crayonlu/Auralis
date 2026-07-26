#!/bin/bash

set -ex

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 1

xcodebuild archive -project MusicBox.xcodeproj -scheme Auralis -archivePath Auralis ONLY_ACTIVE_ARCH=NO

cd release
hdiutil detach /Volumes/Auralis || true
rm -f *.dmg
hdiutil create -size 200m -fs APFS -volname "Auralis" -o Auralis-tmp.dmg
hdiutil attach Auralis-tmp.dmg -noverify -mountpoint /Volumes/Auralis

cp -r ../Auralis.xcarchive/Products/Applications/Auralis.app /Volumes/Auralis/
ln -s /Applications /Volumes/Auralis/Applications

osascript layout.scpt

hdiutil detach /Volumes/Auralis
hdiutil convert Auralis-tmp.dmg -format UDZO -o Auralis.dmg

rm Auralis-tmp.dmg
cd ..
rm -r Auralis.xcarchive
