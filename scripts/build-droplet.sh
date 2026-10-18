#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
SDK_ROOT="${SEACOFFEE_DROPPYKIT_PATH:-$REPO_ROOT/.build/droppykit}"
if [[ ! -f "$SDK_ROOT/Scripts/build-droplet.sh" ]]; then
    git clone --depth 1 --branch v1.20.1 https://gitlab.com/droppyformac1/droppykit.git "$SDK_ROOT"
fi
# Command Line Tools omit SwiftUIMacros; keep the fetched SDK unchanged.
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
    SDK_COPY="$REPO_ROOT/.build/droppykit-clt"
    python3 scripts/prepare-droppykit.py "$SDK_ROOT" "$SDK_COPY"
    SDK_ROOT="$SDK_COPY"
fi
export SEACOFFEE_DROPPYKIT_PATH="$SDK_ROOT"
STAGE="$REPO_ROOT/.build/droppy-package"
mkdir -p "$STAGE/Sources" "$REPO_ROOT/dist"
# A clean copy of owned build inputs, not a second maintained implementation.
rm -rf "$STAGE/Sources/IslandCore" "$STAGE/Sources/SeaCoffeeDroplet" "$STAGE/Harness" "$STAGE/Tests"
cp -R Sources/IslandCore "$STAGE/Sources/IslandCore"
cp -R Sources/SeaCoffee "$STAGE/Sources/SeaCoffeeDroplet"
rm "$STAGE/Sources/SeaCoffeeDroplet/Application.swift" "$STAGE/Sources/SeaCoffeeDroplet/MotionPreviewRenderer.swift"
cp Droplet/Package.swift Droplet/droplet.json "$STAGE/"
cp -R Droplet/Harness Droplet/Tests "$STAGE/"
rm -rf "$STAGE/SeaCoffee.icon" "$STAGE/Assets"
cp -R Droplet/SeaCoffee.icon Droplet/Assets "$STAGE/"
cd "$STAGE"
"$SDK_ROOT/Scripts/build-droplet.sh" --arch "${SEACOFFEE_ARCH:-universal}"
"$SDK_ROOT/Scripts/validate-droplet.sh" --no-submission --bundle "$STAGE/.build/SeaCoffeeDroplet.droplet"
rm -rf "$REPO_ROOT/dist/SeaCoffeeDroplet.droplet"
cp -R "$STAGE/.build/SeaCoffeeDroplet.droplet" "$REPO_ROOT/dist/"
printf 'Built %s\n' "$REPO_ROOT/dist/SeaCoffeeDroplet.droplet"
