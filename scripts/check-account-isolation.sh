#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product SeaCoffee
CHECK_DIR=$(mktemp -d /tmp/seacoffee-account-checks.XXXXXX)
trap 'rm -rf "$CHECK_DIR"' EXIT
BUILD_DIR=$(swift build --show-bin-path)
SOURCES=()
for source in Sources/SeaCoffee/*.swift; do
    [[ "$source" == */Application.swift ]] || SOURCES+=("$source")
done
swiftc -parse-as-library -swift-version 5 -I "$BUILD_DIR/Modules" \
    "${SOURCES[@]}" Tests/SeaCoffeeTests/AccountIsolationChecks.swift \
    "$BUILD_DIR"/IslandCore.build/*.swift.o -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"
