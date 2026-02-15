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
  "$ROOT_DIR/assets/icons/app/icon.png"
do
  if [[ -f "$candidate" ]]; then
    ICON_SOURCE="$candidate"
    break
  fi
done

if [[ -z "$ICON_SOURCE" ]]; then
  FIRST_APP_ICON="$(find "$ROOT_DIR/assets/icons/app" -maxdepth 1 -type f -name '*.png' 2>/dev/null | head -n 1 || true)"
  if [[ -n "$FIRST_APP_ICON" ]]; then
    ICON_SOURCE="$FIRST_APP_ICON"
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

MENUBAR_PNG_SOURCE=""
for candidate in \
  "$ROOT_DIR/assets/icons/menubar/MicIconTemplate.png" \
  "$ROOT_DIR/assets/icons/menubar/MenubarIconTemplate.png" \
  "$ROOT_DIR/assets/icons/menubar/MenubarIcon.png"
do
  if [[ -f "$candidate" ]]; then
    MENUBAR_PNG_SOURCE="$candidate"
    break
  fi
done

if [[ -z "$MENUBAR_PNG_SOURCE" ]]; then
  MENUBAR_PNG_SOURCE="$(find "$ROOT_DIR/assets/icons/menubar" -maxdepth 1 -type f -name '*.png' ! -name '*@2x.png' 2>/dev/null | head -n 1 || true)"
fi

MENUBAR_PNG_2X_SOURCE=""
if [[ -n "$MENUBAR_PNG_SOURCE" ]]; then
  MENUBAR_PNG_BASE="${MENUBAR_PNG_SOURCE%.png}"
  if [[ -f "${MENUBAR_PNG_BASE}@2x.png" ]]; then
    MENUBAR_PNG_2X_SOURCE="${MENUBAR_PNG_BASE}@2x.png"
  fi
fi

if [[ -z "$MENUBAR_PNG_2X_SOURCE" ]]; then
  for candidate in \
    "$ROOT_DIR/assets/icons/menubar/MicIconTemplate@2x.png" \
    "$ROOT_DIR/assets/icons/menubar/MenubarIconTemplate@2x.png" \
    "$ROOT_DIR/assets/icons/menubar/MenubarIcon@2x.png"
  do
    if [[ -f "$candidate" ]]; then
      MENUBAR_PNG_2X_SOURCE="$candidate"
      break
    fi
  done
fi

MENUBAR_PDF_SOURCE=""
if [[ -z "$MENUBAR_PNG_SOURCE" ]]; then
  for candidate in \
    "$ROOT_DIR/assets/icons/menubar/menubar-icon.pdf" \
    "$ROOT_DIR/assets/icons/menubar/MenubarIconTemplate.pdf" \
    "$ROOT_DIR/assets/icons/menubar/MenubarIcon.pdf"
  do
    if [[ -f "$candidate" ]]; then
      MENUBAR_PDF_SOURCE="$candidate"
      break
    fi
  done
fi

MENUBAR_SVG_SOURCE=""
if [[ -z "$MENUBAR_PNG_SOURCE" && -z "$MENUBAR_PDF_SOURCE" ]]; then
  for candidate in \
    "$ROOT_DIR/assets/icons/menubar/MenubarIcon.svg" \
    "$ROOT_DIR/assets/icons/menubar/icon.svg"
  do
    if [[ -f "$candidate" ]]; then
      MENUBAR_SVG_SOURCE="$candidate"
      break
    fi
  done

  if [[ -z "$MENUBAR_SVG_SOURCE" ]]; then
    FIRST_MENUBAR_SVG="$(find "$ROOT_DIR/assets/icons/menubar" -maxdepth 1 -type f -name '*.svg' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$FIRST_MENUBAR_SVG" ]]; then
      MENUBAR_SVG_SOURCE="$FIRST_MENUBAR_SVG"
    fi
  fi
fi

MENUBAR_PDF_TARGET="$APP_DIR/Contents/Resources/MenubarIconTemplate.pdf"
MENUBAR_PNG_TARGET="$APP_DIR/Contents/Resources/MicIconTemplate.png"
MENUBAR_PNG_2X_TARGET="$APP_DIR/Contents/Resources/MicIconTemplate@2x.png"
LEGACY_MENUBAR_PNG_TARGET="$APP_DIR/Contents/Resources/MenubarIconTemplate.png"
LEGACY_MENUBAR_PNG_2X_TARGET="$APP_DIR/Contents/Resources/MenubarIconTemplate@2x.png"

if [[ -n "$MENUBAR_PNG_SOURCE" ]]; then
  cp "$MENUBAR_PNG_SOURCE" "$MENUBAR_PNG_TARGET"
  cp "$MENUBAR_PNG_SOURCE" "$LEGACY_MENUBAR_PNG_TARGET"

  if [[ -n "$MENUBAR_PNG_2X_SOURCE" ]]; then
    cp "$MENUBAR_PNG_2X_SOURCE" "$MENUBAR_PNG_2X_TARGET"
    cp "$MENUBAR_PNG_2X_SOURCE" "$LEGACY_MENUBAR_PNG_2X_TARGET"
  else
    sips -z 32 32 "$MENUBAR_PNG_SOURCE" --out "$MENUBAR_PNG_2X_TARGET" >/dev/null 2>&1 || true
    if [[ -f "$MENUBAR_PNG_2X_TARGET" ]]; then
      cp "$MENUBAR_PNG_2X_TARGET" "$LEGACY_MENUBAR_PNG_2X_TARGET"
    fi
  fi
elif [[ -n "$MENUBAR_PDF_SOURCE" ]]; then
  cp "$MENUBAR_PDF_SOURCE" "$MENUBAR_PDF_TARGET"
  sips -s format png -Z 36 "$MENUBAR_PDF_TARGET" --out "$MENUBAR_PNG_TARGET" >/dev/null 2>&1 || true
  if [[ -f "$MENUBAR_PNG_TARGET" ]]; then
    cp "$MENUBAR_PNG_TARGET" "$LEGACY_MENUBAR_PNG_TARGET"
  fi
elif [[ -n "$MENUBAR_SVG_SOURCE" ]]; then
  # Keep a vector copy so SwiftUI can render it sharply in the menu bar.
  sips -s format pdf "$MENUBAR_SVG_SOURCE" --out "$MENUBAR_PDF_TARGET" >/dev/null 2>&1 || true

  # Produce a retina-sized PNG fallback.
  sips -s format png -Z 36 "$MENUBAR_SVG_SOURCE" --out "$MENUBAR_PNG_TARGET" >/dev/null 2>&1 || true
  if [[ -f "$MENUBAR_PNG_TARGET" ]]; then
    cp "$MENUBAR_PNG_TARGET" "$LEGACY_MENUBAR_PNG_TARGET"
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
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Packaged app: $APP_DIR"
echo "Launch with: open \"$APP_DIR\""
