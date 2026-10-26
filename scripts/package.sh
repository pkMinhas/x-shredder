#!/bin/bash
# Builds the Apple silicon (arm64) Release app, signed with the personal-team certificate, checks
# the signatures and writes a zip to dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/x-shredder"
DERIVED="${DERIVED_DATA:-$ROOT/build/DerivedData}"
APP="$DERIVED/Build/Products/Release/x-shredder.app"
HELPER="$APP/Contents/MacOS/x-shredder-helper"

xcodebuild -project "$PROJECT/x-shredder.xcodeproj" -scheme x-shredder \
    -configuration Release -derivedDataPath "$DERIVED" \
    -destination 'generic/platform=macOS' build >/dev/null

codesign --verify --deep --strict "$APP"
team() { codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
APP_TEAM="$(team "$APP")"
HELPER_TEAM="$(team "$HELPER")"
if [ -z "$APP_TEAM" ] || [ "$APP_TEAM" = "not set" ] || [ "$APP_TEAM" != "$HELPER_TEAM" ]; then
    echo "error: app and helper must be signed by the same team (app: $APP_TEAM, helper: $HELPER_TEAM)" >&2
    exit 1
fi
test -f "$APP/Contents/Library/LaunchDaemons/com.withpreet.x-shredder.helper.plist"
for binary in "$APP/Contents/MacOS/x-shredder" "$HELPER"; do
    if [ "$(lipo -archs "$binary")" != "arm64" ]; then
        echo "error: $binary must be arm64 only (found: $(lipo -archs "$binary"))" >&2
        exit 1
    fi
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/x-shredder-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Packaged $ZIP (team $APP_TEAM, not notarized)"
