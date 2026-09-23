#!/usr/bin/env bash
set -euo pipefail

# Builds an official CPython iOS XCFramework on macOS and copies it into Vendor/.
# Requires a full Xcode installation (Command Line Tools alone are not enough).

PYTHON_VERSION="${PYTHON_VERSION:-3.14.7}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${POCKETHOST_PYTHON_BUILD_DIR:-$ROOT/.build/cpython-ios}"
SRC="$WORK/cpython"
DEST="$ROOT/Vendor/Python.xcframework"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "CPython iOS must be built on macOS with full Xcode installed." >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install/open full Xcode first." >&2
  exit 1
fi

mkdir -p "$WORK"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch "v${PYTHON_VERSION}" https://github.com/python/cpython.git "$SRC"
else
  git -C "$SRC" fetch --depth 1 origin "v${PYTHON_VERSION}"
  git -C "$SRC" checkout -f "v${PYTHON_VERSION}"
fi

cd "$SRC"
# Python 3.14 uses the Apple build helper; newer branches moved it to Platforms/Apple.
if [[ -e Apple ]]; then
  python3 Apple build iOS all
elif [[ -e Platforms/Apple ]]; then
  python3 Platforms/Apple build iOS
else
  echo "Could not locate CPython's Apple iOS build helper." >&2
  exit 1
fi

XC="$(find "$SRC" -type d -name Python.xcframework -print -quit)"
if [[ -z "$XC" ]]; then
  echo "Build finished but Python.xcframework was not found." >&2
  exit 1
fi

rm -rf "$DEST"
cp -R "$XC" "$DEST"
echo "Installed: $DEST"
echo "Next: follow Vendor/CPYTHON_IOS.md to Embed & Sign it and add the Python library processing build phase."
