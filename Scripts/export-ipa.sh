#!/bin/sh
set -eu
ARCHIVE_PATH="${1:-build/PocketHost.xcarchive}"
EXPORT_PATH="${2:-build/export}"
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" -exportOptionsPlist ExportOptions.plist
