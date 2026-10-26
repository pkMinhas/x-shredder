#!/bin/bash
# Source-level checks for two project rules:
#   1. No secrets in logs: no log call may mention key material.
#   2. No override: shipping code has no preference, command-line flag or
#      environment variable that could relax a DiskGuard rule.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/x-shredder"
SOURCES=(
    "$PROJECT/x-shredder"
    "$PROJECT/x-shredder-helper"
    "$PROJECT/Shared"
    "$PROJECT/Packages/DiskGuard/Sources/DiskGuard"
    "$PROJECT/Packages/Engine/Sources"
    "$PROJECT/Packages/Report/Sources"
)
status=0

if grep -rnE 'Log\.[a-zA-Z]+\.(debug|info|notice|warning|error|fault|log)\(.*(runKey|wrappedKey|state\.key|kek|privateKey|rawRepresentation|signingKey)' "${SOURCES[@]}" --include='*.swift'; then
    echo "error: a log call mentions key material" >&2
    status=1
fi

if grep -rnE 'UserDefaults|@AppStorage|CommandLine\.arguments|ProcessInfo\.processInfo\.environment|getenv\(' "${SOURCES[@]}" --include='*.swift'; then
    echo "error: shipping code reads a preference, argument or environment variable" >&2
    status=1
fi

if grep -rnE 'allowTestDiskImages[[:space:]]*=[[:space:]]*true' "${SOURCES[@]}" --include='*.swift' | grep -v 'Shared/HelperConstants.swift'; then
    echo "error: test disk images enabled outside Policy.active" >&2
    status=1
fi

[ "$status" -eq 0 ] && echo "lint-safety: ok"
exit "$status"
