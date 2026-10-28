#!/bin/bash
# Builds a universal (Apple Silicon + Intel) DiskLens.app into ./build and signs it.
# Usage: scripts/build-app.sh            (set CODESIGN_IDENTITY to override; "-" = ad-hoc)
#        NATIVE_ONLY=1 scripts/build-app.sh   (faster: this Mac's architecture only)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${NATIVE_ONLY:-0}" = "1" ]; then
  swift build -c release --product DiskLens
  BIN="$(swift build -c release --show-bin-path)/DiskLens"
else
  swift build -c release --product DiskLens --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DiskLens"
fi
APP="build/DiskLens.app"

[ -f build/AppIcon.icns ] || swift scripts/make-icon.swift build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskLens"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --options runtime --timestamp=none --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/DiskLens"), signed: ${IDENTITY:-ad-hoc})"
