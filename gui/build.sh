#!/bin/bash
# Builds Dmgexe.app (SwiftUI front-end with dmgexe.sh bundled inside).
# Usage: gui/build.sh [output-folder]   (default: the project root)
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$PWD/..}"; APP="$OUT/Dmgexe.app"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library Dmgexe.swift -o "$APP/Contents/MacOS/Dmgexe"
cp ../dmgexe.sh "$APP/Contents/Resources/dmgexe.sh"

# Icon: icon.svg -> 1024px PNG -> .iconset -> .icns
swiftc -O svg2png.swift -o "$TMP/svg2png"
"$TMP/svg2png" icon.svg "$TMP/icon.png"
SET="$TMP/AppIcon.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Dmgexe</string>
<key>CFBundleDisplayName</key><string>Dmgexe</string>
<key>CFBundleIdentifier</key><string>com.dmgexe.gui</string>
<key>CFBundleExecutable</key><string>Dmgexe</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force -s - "$APP" >/dev/null 2>&1 || true
echo "Created: $APP"
