#!/bin/sh
set -eu
SCHEME="PocketHost"
ARCHIVE_PATH="${1:-build/PocketHost.xcarchive}"
xcodebuild -project PocketHost.xcodeproj -scheme "$SCHEME" -configuration Release -destination 'generic/platform=iOS' -archivePath "$ARCHIVE_PATH" archive
