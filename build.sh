#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

bundle="${1:-$PWD/build/CopyShelf.app}"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp assets/AppIcon.icns "$bundle/Contents/Resources/"
cp Info.plist "$bundle/Contents/Info.plist"
/usr/bin/swiftc -O -target "$(/usr/bin/uname -m)-apple-macosx13.0" \
    History.swift main.swift -o "$bundle/Contents/MacOS/CopyShelf"
/usr/bin/codesign --force --sign - "$bundle"
