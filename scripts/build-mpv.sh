#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MPVKIT_DIR="$ROOT/ThirdParty/mpvkit"

if [ ! -d "$MPVKIT_DIR" ]; then
  echo "MPVKit repo not found at $MPVKIT_DIR"
  echo "Clone your MPVKit/libmpv build repo into that path and re-run."
  exit 1
fi

if [ -f "$MPVKIT_DIR/build.sh" ]; then
  (cd "$MPVKIT_DIR" && ./build.sh)
elif [ -f "$MPVKIT_DIR/scripts/build.sh" ]; then
  (cd "$MPVKIT_DIR" && ./scripts/build.sh)
else
  echo "No build script found in $MPVKIT_DIR."
  echo "Expected build.sh or scripts/build.sh."
  exit 1
fi

echo "MPV build complete. Check $MPVKIT_DIR/dist for xcframework outputs."
