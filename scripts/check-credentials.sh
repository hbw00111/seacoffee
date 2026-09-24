#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
CHECK_SERVICE="com.seacoffee.test.$(uuidgen)"
python3 - "$CHECK_DIR/Services.swift" "$CHECK_SERVICE" <<'PY'
import pathlib,sys
source=pathlib.Path('Sources/SeaCoffee/Services.swift').read_text()
source=source.replace('private static let service = "com.seacoffee.SeaIsland"', 'private static let service = "'+sys.argv[2]+'"')
pathlib.Path(sys.argv[1]).write_text(source)
PY
swift build --product IslandChecks >/dev/null
swiftc -parse-as-library -I .build/debug/Modules "$CHECK_DIR/Services.swift" \
    .build/debug/IslandCore.build/*.swift.o Tests/SeaCoffeeTests/CredentialCacheChecks.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check" "$CHECK_SERVICE"

swiftc Tests/SeaCoffeeTests/KeychainFixtureOwner.swift -o "$CHECK_DIR/owner"
swiftc -parse-as-library -I .build/debug/Modules "$CHECK_DIR/Services.swift" \
    .build/debug/IslandCore.build/*.swift.o Tests/SeaCoffeeTests/KeychainDeniedChecks.swift -o "$CHECK_DIR/reader"
"$CHECK_DIR/owner" "$CHECK_SERVICE"
# The owner's distinct identity creates an ACL the reader cannot read without authorization.
trap '"$CHECK_DIR/owner" "$CHECK_SERVICE" cleanup; rm -rf "$CHECK_DIR"' EXIT
"$CHECK_DIR/reader"
