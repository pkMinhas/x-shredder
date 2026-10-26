#!/bin/bash
# Builds everything and runs every unit and integration test.
# Set XSHREDDER_DISK_IMAGE_TESTS=1 to also run the tests that attach a small
# scratch disk image (debug builds only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/x-shredder"
DERIVED="${DERIVED_DATA:-$ROOT/build/DerivedData}"

"$ROOT/scripts/lint-safety.sh"

for package in DiskGuard Engine Report; do
    echo "== swift test: $package"
    swift test --package-path "$PROJECT/Packages/$package"
done

echo "== xcodebuild test: app and helper"
xcodebuild -project "$PROJECT/x-shredder.xcodeproj" -scheme x-shredder \
    -configuration Debug -derivedDataPath "$DERIVED" \
    -only-testing:x-shredderTests test

"$ROOT/scripts/check-release-flags.sh"
echo "All checks passed."
