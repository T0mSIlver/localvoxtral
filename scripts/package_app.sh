#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
  echo "Usage: ./scripts/package_app.sh [release|debug]"
  exit 1
fi

swift build -c "$CONFIGURATION"

BINARY_PATH="$(find "$ROOT_DIR/.build" -type f -path "*/${CONFIGURATION}/SuperVoxtral" | head -n 1)"
if [[ -z "$BINARY_PATH" ]]; then
  echo "Unable to find built SuperVoxtral binary under .build."
  exit 1
fi

APP_DIR="$ROOT_DIR/dist/SuperVoxtral.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/SuperVoxtral"
chmod +x "$APP_DIR/Contents/MacOS/SuperVoxtral"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>SuperVoxtral</string>
  <key>CFBundleIdentifier</key>
  <string>com.supervoxtral.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>SuperVoxtral</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>SuperVoxtral needs microphone access for live dictation.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>SuperVoxtral needs local network access to reach realtime transcription endpoints.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_services._dns-sd._udp</string>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Packaged app: $APP_DIR"
echo "Launch with: open \"$APP_DIR\""
