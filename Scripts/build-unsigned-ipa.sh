#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="PocketHost.xcodeproj"
SCHEME="PocketHost"
CONFIGURATION="Release"
DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/build/DerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/ipa}"
APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos/PocketHost.app"
IPA_PATH="$OUTPUT_DIR/PocketHost-unsigned.ipa"
PYTHON_VERSION="${PYTHON_VERSION:-3.14.7}"

rm -rf "$DERIVED_DATA" "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Build/cache the official CPython iOS XCFramework before compiling the app.
# PythonKit links dynamically at runtime, so this does not change Swift compilation.
chmod +x "$ROOT_DIR/Scripts/build-cpython-ios.sh"
"$ROOT_DIR/Scripts/build-cpython-ios.sh"

# The IPA produced here is intentionally unsigned. Tools such as AltStore,
# SideStore, or Sideloadly can sign it with the user's own Apple ID/certificate.
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM="" \
  clean build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle not found: $APP_PATH" >&2
  exit 1
fi

# Bundle the embedded NodeMobile runtime used for real local Node.js projects.
# The framework is fetched during CI instead of committing a ~40 MB binary to Git.
NODE_VERSION="24.18.0-0"
NODE_ARCHIVE="$ROOT_DIR/build/nodejs-mobile-ios-$NODE_VERSION.zip"
NODE_EXTRACT="$ROOT_DIR/build/nodejs-mobile-ios-$NODE_VERSION"
NODE_URL="https://github.com/gmaclennan/nodejs-mobile/releases/download/v$NODE_VERSION/nodejs-mobile-ios-$NODE_VERSION.zip"
NODE_SHA256="849526f5861a235e97d4ecc7a3272f1d6bb63d324716dbe1cc2bb5019992257a"

mkdir -p "$NODE_EXTRACT"
if [[ ! -f "$NODE_ARCHIVE" ]]; then
  curl -L --fail --retry 3 --retry-delay 2 "$NODE_URL" -o "$NODE_ARCHIVE"
fi
printf '%s  %s\n' "$NODE_SHA256" "$NODE_ARCHIVE" | shasum -a 256 -c -
rm -rf "$NODE_EXTRACT"/*
unzip -q "$NODE_ARCHIVE" -d "$NODE_EXTRACT"

NODE_FRAMEWORK="$(find "$NODE_EXTRACT" -type d -path '*/NodeMobile.xcframework/ios-arm64/NodeMobile.framework' -print -quit)"
if [[ -z "$NODE_FRAMEWORK" || ! -d "$NODE_FRAMEWORK" ]]; then
  echo "NodeMobile iOS arm64 framework not found in release archive" >&2
  exit 1
fi

mkdir -p "$APP_PATH/Frameworks"
rm -rf "$APP_PATH/Frameworks/NodeMobile.framework"
cp -R "$NODE_FRAMEWORK" "$APP_PATH/Frameworks/NodeMobile.framework"
rm -rf "$APP_PATH/Frameworks/NodeMobile.framework/_CodeSignature" || true
chmod +x "$APP_PATH/Frameworks/NodeMobile.framework/NodeMobile"

echo "Bundled NodeMobile $NODE_VERSION"

# Bundle the official CPython iOS framework and standard library.
PY_XC="$ROOT_DIR/Vendor/Python.xcframework"
PY_SLICE="$PY_XC/ios-arm64"
PY_FRAMEWORK="$PY_SLICE/Python.framework"
if [[ ! -d "$PY_FRAMEWORK" ]]; then
  echo "Python.framework missing from $PY_SLICE" >&2
  exit 1
fi
mkdir -p "$APP_PATH/Frameworks"
rm -rf "$APP_PATH/Frameworks/Python.framework"
cp -R "$PY_FRAMEWORK" "$APP_PATH/Frameworks/Python.framework"
rm -rf "$APP_PATH/Frameworks/Python.framework/_CodeSignature" || true
chmod +x "$APP_PATH/Frameworks/Python.framework/Python"

# Copy the Python stdlib. Full XCFrameworks may store common stdlib in /lib plus
# slice-specific extension modules in lib-arm64; single-arch layouts keep all of it in the slice.
mkdir -p "$APP_PATH/python/lib"
if [[ -d "$PY_XC/lib" ]]; then
  rsync -a --delete --exclude 'libpython*.dylib' "$PY_XC/lib/" "$APP_PATH/python/lib/"
  if [[ -d "$PY_SLICE/lib-arm64" ]]; then
    rsync -a --exclude 'libpython*.dylib' "$PY_SLICE/lib-arm64/" "$APP_PATH/python/lib/"
  fi
elif [[ -d "$PY_SLICE/lib" ]]; then
  rsync -a --delete --exclude 'libpython*.dylib' "$PY_SLICE/lib/" "$APP_PATH/python/lib/"
else
  echo "Python standard library not found in XCFramework" >&2
  exit 1
fi

# iOS cannot load loose .so files. Convert each stdlib extension module into a framework
# and leave a .fwork marker where CPython expects the extension.
PYVER_DIR="$(find "$APP_PATH/python/lib" -maxdepth 1 -type d -name 'python3.*' -print -quit)"
if [[ -n "$PYVER_DIR" && -d "$PYVER_DIR/lib-dynload" ]]; then
  while IFS= read -r -d '' EXT; do
    REL="${EXT#$APP_PATH/}"
    INSTALL_BASE="python/lib/$(basename "$PYVER_DIR")/lib-dynload/"
    PY_EXT="${REL#${INSTALL_BASE}}"
    FULL_MODULE_NAME="$(echo "$PY_EXT" | sed 's/\.so$//' | tr '/' '.')"
    FRAMEWORK_BUNDLE_ID="$(echo "app.nexorahost.local.$FULL_MODULE_NAME" | tr '_' '-')"
    FRAMEWORK_DIR="$APP_PATH/Frameworks/$FULL_MODULE_NAME.framework"
    mkdir -p "$FRAMEWORK_DIR"
    cp "$PY_XC/build/iOS-dylib-Info-template.plist" "$FRAMEWORK_DIR/Info.plist"
    plutil -replace CFBundleExecutable -string "$FULL_MODULE_NAME" "$FRAMEWORK_DIR/Info.plist"
    plutil -replace CFBundleIdentifier -string "$FRAMEWORK_BUNDLE_ID" "$FRAMEWORK_DIR/Info.plist"
    mv "$EXT" "$FRAMEWORK_DIR/$FULL_MODULE_NAME"
    chmod +x "$FRAMEWORK_DIR/$FULL_MODULE_NAME"
    printf 'Frameworks/%s.framework/%s\n' "$FULL_MODULE_NAME" "$FULL_MODULE_NAME" > "${EXT%.so}.fwork"
    printf '%s\n' "${REL%.so}.fwork" > "$FRAMEWORK_DIR/$FULL_MODULE_NAME.origin"
  done < <(find "$PYVER_DIR/lib-dynload" -type f -name '*.so' -print0)
fi

echo "Bundled CPython $PYTHON_VERSION"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/Payload"
cp -R "$APP_PATH" "$TMP_DIR/Payload/PocketHost.app"

(
  cd "$TMP_DIR"
  /usr/bin/zip -qry "$IPA_PATH" Payload
)

# Produce a checksum next to the IPA so downloads can be verified.
shasum -a 256 "$IPA_PATH" > "$IPA_PATH.sha256"

echo "Built: $IPA_PATH"
cat "$IPA_PATH.sha256"
