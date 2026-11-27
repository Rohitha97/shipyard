#!/bin/bash
# Builds Shipyard.app next to this script.  ./build-app.sh && open Shipyard.app
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary, so the app also runs on Intel Macs
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Shipyard"
"$BIN" --selftest

APP=Shipyard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/"
cat >"$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.shipyard</string>
  <key>CFBundleName</key><string>Shipyard</string>
  <key>CFBundleExecutable</key><string>Shipyard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Shipyard finds and installs builds on phones connected over Wi-Fi.</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
