#!/bin/zsh
# Builds the dance-style animations for the iOS app's style sheet as HEVC-with-alpha .mov
# files (a few MB each) in Animations/Styles/<slug>.mov; the app reads the path (with a ?v=
# cache key) from dance_styles.animation_path.
#
# Apple's decoders ignore the alpha in the ffmpeg-made ProRes 4444 masters, so the input is a
# folder per dance of transparent PNG frames extracted with ffmpeg:
#   ffmpeg -i <slug>-transparent.mov -vf format=rgba "Frames/<slug>/%05d.png"
# Needs macOS with Xcode or the Command Line Tools. Run from anywhere:
#   zsh scripts/encode-style-animations.sh ["/path/to/Frames"] [fps]
set -euo pipefail

FRAMES="${1:-$HOME/Downloads/Mirrorball Animations/Claude Animation Handoff - 2026-11-02/Workspace/outputs/Dance Performances v5 - Claude Polish/Frames}"
FPS="${2:-30}"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPTS/.." && pwd)"
OUT="$REPO/Animations/Styles"

command -v xcrun >/dev/null || { echo "xcrun not found: install Xcode or the Command Line Tools." >&2; exit 1; }
[[ -d "$FRAMES" ]] || { echo "No frames folder at $FRAMES" >&2; exit 1; }
mkdir -p "$OUT"

# Compile the encoder and the alpha check once.
BIN="$(mktemp -d -t style-animations)"
trap 'rm -rf "$BIN"' EXIT
xcrun swiftc -O -suppress-warnings -o "$BIN/encode" "$SCRIPTS/encode-style-animation-frames.swift"
xcrun swiftc -O -suppress-warnings -o "$BIN/check" "$SCRIPTS/check-style-animation-alpha.swift"

count=0
for dir in "$FRAMES"/*(/N); do
  slug="${dir:t}"
  dest="$OUT/$slug.mov"
  echo "→ $slug"
  "$BIN/encode" "$dir" "$FPS" "$dest" >/dev/null
  size=$(( $(stat -f%z "$dest") / 1024 / 1024 ))
  printf '   %s MB · %s\n' "$size" "$("$BIN/check" "$dest" | sed 's/^[^:]*: //')"
  count=$((count + 1))
done
(( count > 0 )) || { echo "No frame folders in $FRAMES" >&2; exit 1; }
echo "Done: $count files in Animations/Styles. Check each line says ~80% transparent, then commit and push."
