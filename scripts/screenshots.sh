#!/bin/bash
# Regenerates the README screenshots from built-in sample data (no real files, names or paths).
# Usage: scripts/screenshots.sh   →  docs/screenshots/*.png
set -euo pipefail
cd "$(dirname "$0")/.."
NATIVE_ONLY=1 scripts/build-app.sh >/dev/null
OUT="$PWD/docs/screenshots"
mkdir -p "$OUT"
BIN="build/DiskLens.app/Contents/MacOS/DiskLens"
DISKLENS_DEMO=1 DISKLENS_SNAPSHOT_DIR="$OUT" "$BIN"
DISKLENS_DEMO=welcome DISKLENS_SNAPSHOT_DIR="$OUT" "$BIN"
echo "Screenshots written to $OUT"
