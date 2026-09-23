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

rm -rf "$DERIVED_DATA" "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

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
