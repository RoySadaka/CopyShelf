#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

bundle="${1:-$PWD/build/CopyShelf.app}"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp assets/AppIcon.icns "$bundle/Contents/Resources/"
cp Info.plist "$bundle/Contents/Info.plist"
for arch in arm64 x86_64; do
    /usr/bin/swiftc -O -target "$arch-apple-macosx13.0" \
        History.swift QuickLookImage.swift main.swift -o "$bundle/Contents/MacOS/CopyShelf-$arch"
done
/usr/bin/lipo -create "$bundle/Contents/MacOS/CopyShelf-arm64" \
    "$bundle/Contents/MacOS/CopyShelf-x86_64" -output "$bundle/Contents/MacOS/CopyShelf"
find "$bundle/Contents/MacOS" -name 'CopyShelf-*' -type f -delete
/usr/bin/codesign --force --sign - "$bundle"
