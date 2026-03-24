#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$ROOT/Vendor/MPVKit/dist/release"

REQUIRED=(
  "Libmpv.xcframework.zip"
  "Libavcodec.xcframework.zip"
  "Libavdevice.xcframework.zip"
  "Libavfilter.xcframework.zip"
  "Libavformat.xcframework.zip"
  "Libavutil.xcframework.zip"
  "Libswresample.xcframework.zip"
  "Libswscale.xcframework.zip"
)

if [ ! -d "$RELEASE_DIR" ]; then
  echo "Missing release directory: $RELEASE_DIR"
  exit 1
fi

MISSING=0
for name in "${REQUIRED[@]}"; do
  path="$RELEASE_DIR/$name"
  if [ ! -f "$path" ]; then
    echo "Missing: $path"
    MISSING=1
  else
    echo "Found: $path"
  fi
done

if [ "$MISSING" -ne 0 ]; then
  echo "Local MPV artifacts are incomplete."
  exit 1
fi

echo "Local MPV artifacts look complete."
