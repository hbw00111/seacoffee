#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product SeaCoffee
APP="$PWD/dist/Sea Coffee.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SeaCoffee "$APP/Contents/MacOS/SeaCoffee"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SeaCoffee</string>
<key>CFBundleIdentifier</key><string>com.seacoffee.SeaIsland</string>
<key>CFBundleName</key><string>Sea Coffee</string>
<key>CFBundleDisplayName</key><string>Sea Coffee</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"
# Local setup pins a certificate fingerprint. Never silently fall back if that identity is missing.
SIGNING_CONFIG="$HOME/Library/Application Support/SeaCoffee/Signing/identity.json"
SIGNING_IDENTITY="${SEACOFFEE_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && -f "$SIGNING_CONFIG" ]]; then
    SIGNING_IDENTITY=$(python3 -c 'import json,sys; value=json.load(open(sys.argv[1]))["identity"]; assert len(value)==40 and all(c in "0123456789abcdefABCDEF" for c in value); print(value)' "$SIGNING_CONFIG")
fi
codesign --force --sign "${SIGNING_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/SeaCoffee" --render-preview "$PWD/dist/preview.png"
printf 'Built %s\n' "$APP"
