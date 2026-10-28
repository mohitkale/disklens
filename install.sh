#!/bin/bash
# One-command install from source:  ./install.sh
# Builds DiskLens, puts it in /Applications (or ~/Applications), and opens it.
#   ./install.sh --universal   build for both Apple Silicon and Intel (slower)
#   INSTALL_DIR=/path ./install.sh   install somewhere else
set -euo pipefail
cd "$(dirname "$0")"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

bold "DiskLens installer"

# 1. Requirements: macOS 14+, Swift toolchain (Xcode or Command Line Tools).
[ "$(uname)" = "Darwin" ] || fail "DiskLens runs on macOS only."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "macOS 14 (Sonoma) or later is required. This Mac has $(sw_vers -productVersion)."
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  echo "The Swift toolchain is missing. Installing Apple's Command Line Tools (a system dialog will open)…"
  xcode-select --install || true
  fail "Run ./install.sh again once the Command Line Tools have finished installing."
fi
echo "✓ macOS $(sw_vers -productVersion), $(swift --version 2>/dev/null | head -1 | sed 's/.*Swift version \([0-9.]*\).*/Swift \1/')"

# 2. Build.
echo "Building DiskLens (first build takes a minute or two)…"
if [ "${1:-}" = "--universal" ]; then scripts/build-app.sh; else NATIVE_ONLY=1 scripts/build-app.sh; fi
echo "✓ Built build/DiskLens.app"

# 3. Install.
if [ -n "${INSTALL_DIR:-}" ]; then DEST="$INSTALL_DIR"
elif [ -w /Applications ]; then DEST=/Applications
else DEST="$HOME/Applications"; fi
mkdir -p "$DEST"
if [ -d "$DEST/DiskLens.app" ]; then
  osascript -e 'quit app "DiskLens"' >/dev/null 2>&1 || true
  sleep 1
  # Move the previous version to the Trash rather than deleting it.
  if command -v trash >/dev/null 2>&1; then trash "$DEST/DiskLens.app"; else mv "$DEST/DiskLens.app" "$HOME/.Trash/DiskLens-previous-$(date +%s).app"; fi
fi
ditto build/DiskLens.app "$DEST/DiskLens.app"
echo "✓ Installed to $DEST/DiskLens.app"

# 4. Open.
[ -n "${NO_OPEN:-}" ] || open "$DEST/DiskLens.app"
bold "Done. DiskLens is in $DEST. Start with a full scan, and nothing is cleaned without your confirmation."
