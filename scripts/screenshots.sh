#!/bin/bash
# Regenerates the README images from built-in sample data (no real files, names or paths):
#   docs/screenshots/*.png   optimized screenshots (1600 px wide, 256-colour PNG)
#   docs/tour.gif            animated tour of the app
#   docs/social-preview.png  1280×640 image for GitHub's social preview (under 1 MB)
# Needs ffmpeg (brew install ffmpeg).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg"; exit 1; }

NATIVE_ONLY=1 scripts/build-app.sh >/dev/null
RAW="$(mktemp -d)"
trap 'rm -rf "$RAW"' EXIT
BIN="build/DiskLens.app/Contents/MacOS/DiskLens"
DISKLENS_DEMO=1 DISKLENS_SNAPSHOT_DIR="$RAW" "$BIN"
DISKLENS_DEMO=welcome DISKLENS_SNAPSHOT_DIR="$RAW" "$BIN"

# Optimized stills: same aspect ratio, 256-colour palette tuned per image.
OUT=docs/screenshots
mkdir -p "$OUT"
for f in "$RAW"/*.png; do
  ffmpeg -loglevel error -y -i "$f" \
    -vf "scale='min(1600,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" \
    "$OUT/$(basename "$f")"
done

# Tour frames (1200 px wide). Sheets are shown over a dimmed window, as in the app.
FR="$RAW/frames"; mkdir -p "$FR"
scale="scale=1200:-2:flags=lanczos"
frame() { ffmpeg -loglevel error -y -i "$RAW/$1.png" -vf "$scale,pad=1200:800:(ow-iw)/2:(oh-ih)/2:white" "$FR/$2.png"; }
sheet() {  # base window, sheet, output
  ffmpeg -loglevel error -y -i "$RAW/$1.png" -i "$RAW/$2.png" -filter_complex \
    "[0]$scale,pad=1200:800:(ow-iw)/2:(oh-ih)/2:white,colorchannelmixer=rr=0.82:gg=0.82:bb=0.82[bg];[1]scale=700:-2:flags=lanczos[s];[bg][s]overlay=(W-w)/2:40" \
    "$FR/$3.png"
}
frame welcome 01
frame overview 02
frame cleanup-selected 03
sheet cleanup-selected review-sheet 04
sheet overview quick-clean-sheet 05
frame explore 06
frame history 07
ffmpeg -loglevel error -y -framerate 0.4 -i "$FR/%02d.png" \
  -vf "split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  -loop 0 docs/tour.gif

# Social preview: the top of the overview at 1280×640.
ffmpeg -loglevel error -y -i "$RAW/overview.png" \
  -vf "scale=1280:-2:flags=lanczos,crop=1280:640:0:0,split[a][b];[a]palettegen=max_colors=256[p];[b][p]paletteuse=dither=sierra2_4a" \
  docs/social-preview.png

du -h docs/tour.gif docs/social-preview.png "$OUT"/*.png
