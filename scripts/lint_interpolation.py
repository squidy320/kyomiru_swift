#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SWIFT_EXT = ".swift"
SKIP_DIRS = {
    ".git",
    ".build",
    "DerivedData",
    "Pods",
    "Carthage",
    "build",
}

# Matches escaped quotes inside string interpolation on the same line.
# Example: "...\(String(format: \"%.2f\", value))..."
BAD_INTERPOLATION = re.compile(r"\\\([^\\n]*\\\"")


def should_skip(path: Path) -> bool:
    return any(part in SKIP_DIRS for part in path.parts)


def main() -> int:
    failures: list[str] = []
    for path in REPO_ROOT.rglob(f"*{SWIFT_EXT}"):
        if should_skip(path):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            text = path.read_text(encoding="utf-8", errors="replace")

        for idx, line in enumerate(text.splitlines(), start=1):
            if BAD_INTERPOLATION.search(line):
                failures.append(f"{path}:{idx}: escaped quote inside interpolation")

    if failures:
        print("lint_interpolation: failed")
        for item in failures:
            print(item)
        print("Fix by removing escaped quotes inside \\(...).")
        return 1

    print("lint_interpolation: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
