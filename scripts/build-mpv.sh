#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MPVKIT_DIR="$ROOT/Vendor/MPVKit"
RELEASE_DIR="$MPVKIT_DIR/dist/release"
MODE="${1:-lgpl}"

if [ ! -d "$MPVKIT_DIR" ]; then
  echo "MPVKit source not found at $MPVKIT_DIR"
  exit 1
fi

if ! command -v make >/dev/null 2>&1; then
  echo "make is required to build MPVKit."
  exit 1
fi

case "$MODE" in
  lgpl)
    BUILD_ARGS=("build" "platform=ios,isimulator,maccatalyst")
    ;;
  gpl)
    BUILD_ARGS=("build" "enable-gpl" "platform=ios,isimulator,maccatalyst")
    ;;
  *)
    echo "Unknown build mode: $MODE"
    echo "Usage: scripts/build-mpv.sh [lgpl|gpl]"
    exit 1
    ;;
esac

echo "Building MPVKit from $MPVKIT_DIR"
(cd "$MPVKIT_DIR" && make "${BUILD_ARGS[@]}")

if [ ! -d "$RELEASE_DIR" ]; then
  echo "Build finished, but no release directory was created at $RELEASE_DIR"
  exit 1
fi

echo "MPV build complete."
echo "Expected local XCFramework zips are under: $RELEASE_DIR"
echo "Next step: run scripts/check-local-mpv.sh"
