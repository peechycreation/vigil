#!/bin/zsh
# Construit Vigil.app en binaire universel (arm64 + x86_64), signé ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Vigil.app"
rm -rf "build/Vigil.app" "build/Vigil-arm64" "build/Vigil-x86_64"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=(Sources/main.swift Sources/PowerController.swift Sources/PopoverView.swift)
swiftc -O -target arm64-apple-macos13.0  -o build/Vigil-arm64  "${SOURCES[@]}"
swiftc -O -target x86_64-apple-macos13.0 -o build/Vigil-x86_64 "${SOURCES[@]}"
lipo -create -output "$APP/Contents/MacOS/Vigil" \
    build/Vigil-arm64 build/Vigil-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Icon.icns Resources/MenuIcon.png "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - "$APP"
echo "Build OK → $PWD/$APP"
lipo -archs "$APP/Contents/MacOS/Vigil"
