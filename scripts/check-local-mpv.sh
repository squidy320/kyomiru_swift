#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_DIR="$ROOT/Vendor/MPVKit/Local/xcframework"

REQUIRED=(
  "Libavcodec.xcframework"
  "Libavdevice.xcframework"
  "Libavfilter.xcframework"
  "Libavformat.xcframework"
  "Libavutil.xcframework"
  "Libmpv.xcframework"
  "Libcrypto.xcframework"
  "Libssl.xcframework"
  "gmp.xcframework"
  "nettle.xcframework"
  "hogweed.xcframework"
  "gnutls.xcframework"
  "Libunibreak.xcframework"
  "Libfreetype.xcframework"
  "Libfribidi.xcframework"
  "Libharfbuzz.xcframework"
  "Libass.xcframework"
  "Libbluray.xcframework"
  "Libuavs3d.xcframework"
  "Libdovi.xcframework"
  "MoltenVK.xcframework"
  "Libshaderc_combined.xcframework"
  "lcms2.xcframework"
  "Libplacebo.xcframework"
  "Libdav1d.xcframework"
  "Libuchardet.xcframework"
  "Libswresample.xcframework"
  "Libswscale.xcframework"
)

if [ ! -d "$LOCAL_DIR" ]; then
  echo "Missing local xcframework directory: $LOCAL_DIR"
  exit 1
fi

MISSING=0
for name in "${REQUIRED[@]}"; do
  path="$LOCAL_DIR/$name"
  if [ ! -d "$path" ]; then
    echo "Missing: $path"
    MISSING=1
  else
    echo "Found: $path"
  fi
done

if [ "$MISSING" -ne 0 ]; then
  echo "Local MPV xcframework set is incomplete."
  echo "Generate the artifact with the 'Build Local MPV' workflow, then extract its Local/ folder into Vendor/MPVKit/Local and commit it."
  exit 1
fi

echo "Local MPV xcframework set looks complete."
