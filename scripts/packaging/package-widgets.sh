#!/usr/bin/env bash
# Builds the WidgetKit extension with SwiftPM and wraps it into the app
# bundle as Contents/PlugIns/localvoxtralWidgets.appex (#630). Called by
# package_app.sh:
#
#   package-widgets.sh build <app-dir> <configuration> <version> <build-number>
#   package-widgets.sh sign  <app-dir> <codesign-identity>
#
# `sign` runs after package_app.sh's `codesign --deep`, which signs nested
# code without entitlements: the extension gets its sandbox entitlements
# here, then the app is resealed around it. A widget extension without its
# sandbox does not load.
#
# What Xcode would do and SwiftPM does not, each measured in the #630 spike:
# - link with `-e _NSExtensionMain`, as Apple's widgets are; with `@main`
#   alone the process exits as soon as WidgetKit launches it;
# - generate Metadata.appintents with `appintentsmetadataprocessor`, fed the
#   compiler's const values (Package.swift's LOCALVOXTRAL_WIDGET_CONST_VALUES)
#   and the linker's dependency info. Without it the buttons and Edit Widget
#   do nothing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPEX_NAME="localvoxtralWidgets"
BUNDLE_ID="com.localvoxtral.app.widgets"
MODULE="localvoxtralWidgets"

VERB="${1:-}"
APP_DIR="${2:-}"
APPEX="$APP_DIR/Contents/PlugIns/$APPEX_NAME.appex"

build() {
  local configuration="$1" version="$2" build_number="$3"
  local work="$ROOT_DIR/.build/widget-extension"
  local const_values="$work/$MODULE.swiftconstvalues"
  local dependency_info="$work/${MODULE}_dependency_info.dat"
  mkdir -p "$work"

  LOCALVOXTRAL_WIDGET_CONST_VALUES="$const_values" \
    swift build --build-system native -c "$configuration" --product localvoxtral-widgets -Xswiftc -g \
      -Xlinker -dependency_info -Xlinker "$dependency_info" \
      -Xlinker -e -Xlinker _NSExtensionMain

  local binary
  binary="$(find "$ROOT_DIR/.build" -type f -path "*/${configuration}/localvoxtral-widgets" | head -n 1)"
  if [[ -z "$binary" ]]; then
    echo "Widget extension binary missing under .build."
    exit 1
  fi
  if [[ ! -s "$const_values" || ! -s "$dependency_info" ]]; then
    echo "Widget extension build left no const values or linker dependency info;"
    echo "App Intents metadata cannot be generated. Expected:"
    echo "  $const_values"
    echo "  $dependency_info"
    exit 1
  fi

  rm -rf "$APPEX"
  mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
  cp "$binary" "$APPEX/Contents/MacOS/$APPEX_NAME"
  cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>localvoxtral</string>
  <key>CFBundleExecutable</key><string>$APPEX_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APPEX_NAME</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST

  printf '%s\n' "$ROOT_DIR"/Sources/"$MODULE"/*.swift > "$work/sources.list"
  printf '%s\n' "$const_values" > "$work/const-values.list"
  : > "$work/metadata.list"
  : > "$work/static-metadata.list"
  local log="$work/appintentsmetadataprocessor.log"
  if ! xcrun appintentsmetadataprocessor \
      --toolchain-dir "$(cd "$(dirname "$(xcrun --find swift)")/../.." && pwd)" \
      --module-name "$MODULE" \
      --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
      --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
      --platform-family macOS \
      --deployment-target 15.0 \
      --bundle-identifier "$BUNDLE_ID" \
      --output "$APPEX/Contents/Resources" \
      --target-triple "$(uname -m)-apple-macos15.0" \
      --binary-file "$APPEX/Contents/MacOS/$APPEX_NAME" \
      --dependency-file "$dependency_info" \
      --stringsdata-file "$work/ExtractedAppShortcutsMetadata.stringsdata" \
      --source-file-list "$work/sources.list" \
      --metadata-file-list "$work/metadata.list" \
      --static-metadata-file-list "$work/static-metadata.list" \
      --swift-const-vals-list "$work/const-values.list" \
      --compile-time-extraction \
      --deployment-aware-processing \
      --no-app-shortcuts-localization > "$log" 2>&1; then
    echo "appintentsmetadataprocessor failed; its output:"
    cat "$log"
    exit 1
  fi
  if [[ ! -d "$APPEX/Contents/Resources/Metadata.appintents" ]]; then
    echo "appintentsmetadataprocessor wrote no Metadata.appintents; its output:"
    cat "$log"
    exit 1
  fi
  echo "Widget extension: $APPEX (App Intents metadata generated)"
}

sign() {
  local identity="$1"
  codesign --force --sign "$identity" \
    --entitlements "$ROOT_DIR/scripts/packaging/widgets.entitlements" "$APPEX"
  codesign --force --sign "$identity" "$APP_DIR"
  if ! codesign -d --entitlements - "$APPEX" 2>/dev/null | grep -q 'com.apple.security.app-sandbox'; then
    echo "The widget extension lost its sandbox entitlement while signing." >&2
    exit 1
  fi
}

case "$VERB" in
  build) build "$3" "$4" "$5" ;;
  sign) sign "$3" ;;
  *)
    echo "usage: $0 build <app-dir> <configuration> <version> <build-number>" >&2
    echo "       $0 sign <app-dir> <codesign-identity>" >&2
    exit 2
    ;;
esac
