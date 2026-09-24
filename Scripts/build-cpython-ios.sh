#!/usr/bin/env bash
set -euo pipefail

PYTHON_VERSION="${PYTHON_VERSION:-3.14.7}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${NEXORA_PYTHON_BUILD_DIR:-$ROOT/.build/cpython-ios}"
SRC="$WORK/cpython"
DEST="$ROOT/Vendor/Python.xcframework"

if [[ -d "$DEST/ios-arm64/Python.framework" && -f "$DEST/Info.plist" ]]; then
  echo "Using cached Python.xcframework at $DEST"
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "CPython iOS must be built on macOS with full Xcode installed." >&2
  exit 1
fi
command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild not found" >&2; exit 1; }

mkdir -p "$WORK"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch "v${PYTHON_VERSION}" https://github.com/python/cpython.git "$SRC"
else
  git -C "$SRC" fetch --depth 1 origin "v${PYTHON_VERSION}"
  git -C "$SRC" checkout -f "v${PYTHON_VERSION}"
fi

cd "$SRC"
if [[ -d Apple ]]; then
  python3 Apple build iOS all
else
  echo "This CPython tag does not contain the Apple iOS build helper." >&2
  exit 1
fi

XC="$SRC/cross-build/iOS/Python.xcframework"
if [[ ! -d "$XC" ]]; then
  XC="$(find "$SRC/cross-build" -type d -name Python.xcframework -print -quit)"
fi
if [[ -z "${XC:-}" || ! -d "$XC" ]]; then
  echo "Build finished but Python.xcframework was not found." >&2
  exit 1
fi
rm -rf "$DEST"
cp -R "$XC" "$DEST"
echo "Installed: $DEST"
