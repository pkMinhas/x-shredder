#!/bin/bash
# Confirms the debug-only test disk image path is compiled out of release
# builds of the app and the helper.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/x-shredder"
DERIVED="${DERIVED_DATA:-$ROOT/build/DerivedData}"
MARKER="XSHREDDER-TEST-DISK-IMAGES-ENABLED"
SIGNING=()
if [ "${CI:-}" = "true" ]; then
    SIGNING=(CODE_SIGNING_ALLOWED=NO)
fi

build() {
    xcodebuild -project "$PROJECT/x-shredder.xcodeproj" -scheme x-shredder \
        -configuration "$1" -derivedDataPath "$DERIVED" ${SIGNING[@]+"${SIGNING[@]}"} build >/dev/null
}

has_marker() {
    # Debug builds keep app code in a separate dylib, so scan every binary.
    # grep -c reads all input. grep -q would close the pipe early and trip pipefail.
    local count
    count="$(find "$1/Contents/MacOS" -type f -exec strings -a {} + | grep -cE "$MARKER|allowTestDiskImages|maxTestDiskImageBytes" || true)"
    [ "$count" -gt 0 ]
}

build Debug
if ! has_marker "$DERIVED/Build/Products/Debug/x-shredder.app"; then
    echo "error: marker missing from the Debug build, so this check proves nothing" >&2
    exit 1
fi

build Release
if has_marker "$DERIVED/Build/Products/Release/x-shredder.app"; then
    echo "error: the test disk image path is present in the Release build" >&2
    exit 1
fi
echo "check-release-flags: ok (present in Debug, absent from Release)"
