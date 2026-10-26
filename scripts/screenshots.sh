#!/bin/bash
# Generates marketing screenshots in docs/screenshots.
# Builds the app with the SCREENSHOTS flag, which shows sample data and
# captures its own window (no card, helper or screen-recording permission
# needed), then composes each capture onto a background with a caption.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/x-shredder"
DERIVED="$ROOT/build/ScreenshotsDerivedData"
RAW="$ROOT/build/screenshots/raw"
OUT="$ROOT/docs/screenshots"

xcodebuild -project "$PROJECT/x-shredder.xcodeproj" -scheme x-shredder \
    -configuration Release -derivedDataPath "$DERIVED" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS=SCREENSHOTS build >/dev/null

rm -rf "$RAW"
# The app writes to build/screenshots/raw and quits when done.
open -W -n "$DERIVED/Build/Products/Release/x-shredder.app"

swift "$ROOT/scripts/compose-screenshots.swift" "$RAW" "$OUT"
