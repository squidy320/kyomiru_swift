#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_ROOT="$ROOT/Vendor/MPVKit/Local"
XCFRAMEWORK_DIR="$LOCAL_ROOT/xcframework"

if [ ! -d "$LOCAL_ROOT" ]; then
  echo "Missing Local MPV directory: $LOCAL_ROOT"
  exit 1
fi

mkdir -p "$XCFRAMEWORK_DIR"

shopt -s nullglob
zips=("$LOCAL_ROOT"/*.xcframework.zip)

if [ "${#zips[@]}" -eq 0 ]; then
  echo "No local MPV xcframework zip files found under $LOCAL_ROOT"
  exit 0
fi

for zip_path in "${zips[@]}"; do
  name="$(basename "$zip_path" .zip)"
  dir_path="$XCFRAMEWORK_DIR/$name"
  if [ -d "$dir_path" ]; then
    echo "Using existing xcframework: $name"
    continue
  fi

  echo "Expanding $name"
  unzip -q -o "$zip_path" -d "$XCFRAMEWORK_DIR"
done

echo "Expanded local MPV xcframework zips into $XCFRAMEWORK_DIR"
