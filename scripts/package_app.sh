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

ICON_SOURCE=""
for candidate in \
  "$ROOT_DIR/assets/icons/app/AppIcon.png" \
  "$ROOT_DIR/assets/icons/app/icon.png" \
  "$ROOT_DIR/AppIcon.png" \
  "$ROOT_DIR/icon.png" \
  "$ROOT_DIR/icon_v1.png"
do
  if [[ -f "$candidate" ]]; then
    ICON_SOURCE="$candidate"
    break
  fi
done

if [[ -z "$ICON_SOURCE" ]]; then
  FIRST_PNG="$(find "$ROOT_DIR" -maxdepth 1 -type f -name '*.png' | head -n 1 || true)"
  if [[ -n "$FIRST_PNG" ]]; then
    ICON_SOURCE="$FIRST_PNG"
  fi
fi

if [[ -n "$ICON_SOURCE" ]]; then
  ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

  iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

MENUBAR_SVG_SOURCE=""
for candidate in \
  "$ROOT_DIR/assets/icons/menubar/MenubarIcon.svg" \
  "$ROOT_DIR/assets/icons/menubar/icon.svg" \
  "$ROOT_DIR/menubar-icon.svg"
do
  if [[ -f "$candidate" ]]; then
    MENUBAR_SVG_SOURCE="$candidate"
    break
  fi
done

if [[ -z "$MENUBAR_SVG_SOURCE" ]]; then
  FIRST_MENUBAR_SVG="$(find "$ROOT_DIR/assets/icons/menubar" -maxdepth 1 -type f -name '*.svg' | head -n 1 || true)"
  if [[ -n "$FIRST_MENUBAR_SVG" ]]; then
    MENUBAR_SVG_SOURCE="$FIRST_MENUBAR_SVG"
  fi
fi

if [[ -n "$MENUBAR_SVG_SOURCE" ]]; then
  MENUBAR_TARGET="$APP_DIR/Contents/Resources/MenubarIconTemplate.png"
  if sips -s format png "$MENUBAR_SVG_SOURCE" --out "$MENUBAR_TARGET" >/dev/null 2>&1; then
    # Keep a small template image for the menu bar while preserving transparency.
    sips -z 36 36 "$MENUBAR_TARGET" --out "$MENUBAR_TARGET" >/dev/null 2>&1 || true
  fi
fi

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
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
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
