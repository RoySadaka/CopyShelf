#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./test.sh
./build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
staging=$(mktemp -d)
trap 'find "$staging" -depth -delete' EXIT
ditto build/CopyShelf.app "$staging/CopyShelf.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname CopyShelf -srcfolder "$staging" -ov -format UDZO "build/CopyShelf-$version.dmg"
shasum -a 256 "build/CopyShelf-$version.dmg" > "build/CopyShelf-$version.dmg.sha256"
