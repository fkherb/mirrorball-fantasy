#!/bin/zsh
# Converts the dance-style animations (ProRes 4444 with alpha, ~130-240 MB each) into
# HEVC-with-alpha .mov files (a few MB each) for the iOS app's dance style sheet.
# Writes Animations/Styles/<slug>.mov; the app reads the path from dance_styles.animation_path.
# Needs macOS with Xcode or the Command Line Tools (uses AVFoundation through
# scripts/encode-style-animation.swift). Run from anywhere:
#   zsh scripts/encode-style-animations.sh ["/path/to/Videos"]
set -euo pipefail

SRC="${1:-$HOME/Downloads/Mirrorball Animations/Claude Animation Handoff - 2026-11-02/Workspace/outputs/Dance Performances v5 - Claude Polish/Videos}"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPTS/.." && pwd)"
OUT="$REPO/Animations/Styles"
ENCODER="$SCRIPTS/encode-style-animation.swift"

command -v xcrun >/dev/null || { echo "xcrun not found: install Xcode or the Command Line Tools." >&2; exit 1; }
[[ -d "$SRC" ]] || { echo "No folder at $SRC" >&2; exit 1; }
mkdir -p "$OUT"

# Compile the encoder once instead of interpreting it for every file.
BIN="$(mktemp -t encode-style-animation)"
trap 'rm -f "$BIN"' EXIT
xcrun swiftc -O -o "$BIN" "$ENCODER"

count=0
for mov in "$SRC"/*-transparent.mov(N); do
  slug="${${mov:t}%-transparent.mov}"
  dest="$OUT/$slug.mov"
  echo "→ $slug"
  "$BIN" "$mov" "$dest"
  size=$(( $(stat -f%z "$dest") / 1024 / 1024 ))
  printf '   %s MB\n' "$size"
  (( size > 25 )) && echo "   warning: over 25 MB"
  count=$((count + 1))
done
(( count > 0 )) || { echo "No *-transparent.mov files in $SRC" >&2; exit 1; }
echo "Done: $count files in Animations/Styles. Commit and push them."
