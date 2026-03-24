#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_DIR="$ROOT/Vendor/MPVKit/Local/xcframework"
TMP_DIR="$ROOT/Vendor/MPVKit/Local/tmp"

mkdir -p "$LOCAL_DIR"
mkdir -p "$TMP_DIR"

ensure_unzipped() {
  local name="$1"
  local url="$2"
  local framework_path="$LOCAL_DIR/$name.xcframework"
  local zip_path="$TMP_DIR/$name.xcframework.zip"

  if [ -d "$framework_path" ]; then
    echo "Using cached local framework: $name"
    return
  fi

  echo "Downloading $name"
  curl -L --fail --retry 3 --retry-delay 2 "$url" -o "$zip_path"
  unzip -q -o "$zip_path" -d "$LOCAL_DIR"
}

if [ ! -d "$LOCAL_DIR/Libmpv.xcframework" ]; then
  echo "Preparing Libmpv.xcframework from local MPV build"
  "$ROOT/scripts/build-mpv.sh"
  if [ ! -d "$ROOT/Vendor/MPVKit/dist/release/xcframework/Libmpv.xcframework" ]; then
    echo "Local Libmpv.xcframework was not produced."
    exit 1
  fi
  rm -rf "$LOCAL_DIR/Libmpv.xcframework"
  cp -R "$ROOT/Vendor/MPVKit/dist/release/xcframework/Libmpv.xcframework" "$LOCAL_DIR/"
fi

ensure_unzipped "Libcrypto" "https://github.com/mpvkit/openssl-build/releases/download/3.3.5/Libcrypto.xcframework.zip"
ensure_unzipped "Libssl" "https://github.com/mpvkit/openssl-build/releases/download/3.3.5/Libssl.xcframework.zip"
ensure_unzipped "gmp" "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gmp.xcframework.zip"
ensure_unzipped "nettle" "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/nettle.xcframework.zip"
ensure_unzipped "hogweed" "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/hogweed.xcframework.zip"
ensure_unzipped "gnutls" "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gnutls.xcframework.zip"
ensure_unzipped "Libunibreak" "https://github.com/mpvkit/libass-build/releases/download/0.17.4/Libunibreak.xcframework.zip"
ensure_unzipped "Libfreetype" "https://github.com/mpvkit/libass-build/releases/download/0.17.4/Libfreetype.xcframework.zip"
ensure_unzipped "Libfribidi" "https://github.com/mpvkit/libass-build/releases/download/0.17.4/Libfribidi.xcframework.zip"
ensure_unzipped "Libharfbuzz" "https://github.com/mpvkit/libass-build/releases/download/0.17.4/Libharfbuzz.xcframework.zip"
ensure_unzipped "Libass" "https://github.com/mpvkit/libass-build/releases/download/0.17.4/Libass.xcframework.zip"
ensure_unzipped "Libbluray" "https://github.com/mpvkit/libbluray-build/releases/download/1.4.0/Libbluray.xcframework.zip"
ensure_unzipped "Libuavs3d" "https://github.com/mpvkit/libuavs3d-build/releases/download/1.2.1-xcode/Libuavs3d.xcframework.zip"
ensure_unzipped "Libdovi" "https://github.com/mpvkit/libdovi-build/releases/download/3.3.2/Libdovi.xcframework.zip"
ensure_unzipped "MoltenVK" "https://github.com/mpvkit/moltenvk-build/releases/download/1.4.1/MoltenVK.xcframework.zip"
ensure_unzipped "Libshaderc_combined" "https://github.com/mpvkit/libshaderc-build/releases/download/2025.5.0/Libshaderc_combined.xcframework.zip"
ensure_unzipped "lcms2" "https://github.com/mpvkit/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip"
ensure_unzipped "Libplacebo" "https://github.com/mpvkit/libplacebo-build/releases/download/7.351.0-2512/Libplacebo.xcframework.zip"
ensure_unzipped "Libdav1d" "https://github.com/mpvkit/libdav1d-build/releases/download/1.5.2-xcode/Libdav1d.xcframework.zip"
ensure_unzipped "Libuchardet" "https://github.com/mpvkit/libuchardet-build/releases/download/0.0.8-xcode/Libuchardet.xcframework.zip"

echo "Local MPV frameworks prepared in $LOCAL_DIR"
