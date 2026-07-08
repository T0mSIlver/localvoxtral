#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

patch_shortcutrecorder_bundle_lookup() {
  local sr_common
  sr_common="$(find "$ROOT_DIR/.build/checkouts/ShortcutRecorder/Sources/ShortcutRecorder" -maxdepth 1 -name 'SRCommon.m' -print -quit 2>/dev/null || true)"
  if [[ -z "$sr_common" || ! -f "$sr_common" ]]; then
    return
  fi

  if grep -q "localvoxtral packaged resources fallback" "$sr_common"; then
    return
  fi

  perl -0pi -e 's/return SWIFTPM_MODULE_BUNDLE;/\/\/ localvoxtral packaged resources fallback\n    \/\/ Try the app bundle first — this avoids a TCC Desktop-access prompt when\n    \/\/ the .app resides anywhere under ~\/Desktop.\n    NSURL *resourceBundleURL = [[[NSBundle mainBundle] resourceURL]\n        URLByAppendingPathComponent:@"ShortcutRecorder_ShortcutRecorder.bundle"];\n    NSBundle *bundle = [NSBundle bundleWithURL:resourceBundleURL];\n    if (bundle)\n        return bundle;\n\n    \/\/ Fall back to the SPM-generated lookup (development builds).\n    bundle = SWIFTPM_MODULE_BUNDLE;\n    if (bundle)\n        return bundle;\n\n    return nil;/g' "$sr_common"
}

CONFIGURATION="${1:-release}"
# Default the version from git so About, crash reports, and diagnostics can
# identify the exact build — every non-release build used to say "0.3.0".
# Releases still pass an explicit version. Fallback covers trees without git
# metadata (remote-build rsync excludes .git) and shallow clones without tags.
# `|| true` because trees without git metadata (remote-build rsync excludes
# .git) make git exit 128, which pipefail+set -e turns into a silent death
# before the first echo — the fallback below never got a chance (broke
# `remote-build.sh package` when #67 introduced git-derived versions).
GIT_VERSION="$(git describe --tags 2>/dev/null | sed 's/^v//' || true)"
GIT_BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || true)"
APP_VERSION="${2:-${GIT_VERSION:-0.0.0-dev}}"
BUILD_NUMBER="${3:-${GIT_BUILD_NUMBER:-1}}"

# Sign with a stable identity when available so TCC grants (Accessibility)
# survive rebuilds; ad-hoc signatures change every build and invalidate them.
CODESIGN_IDENTITY="${LOCALVOXTRAL_CODESIGN_IDENTITY:--}"
if [[ "$CODESIGN_IDENTITY" != "-" ]] \
  && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$CODESIGN_IDENTITY"; then
  # A SILENT ad-hoc fallback here is exactly how the TCC-grant regression
  # shipped unnoticed: when a same-repo CI build runs as a user whose login
  # keychain can't see the localvoxtral-dev cert, packaging quietly produced an
  # ad-hoc artifact, try-pr.sh then re-signed it ad-hoc on every launch, and
  # macOS invalidated the Accessibility grant each time (ad-hoc signatures carry
  # a fresh, cdhash-derived designated requirement every build). On lanes that
  # MUST ship an identity-signed bundle, fail loudly instead of downgrading.
  if [[ "${LOCALVOXTRAL_REQUIRE_CODESIGN_IDENTITY:-0}" == "1" ]]; then
    echo "FATAL: signing identity '$CODESIGN_IDENTITY' is required (LOCALVOXTRAL_REQUIRE_CODESIGN_IDENTITY=1)" >&2
    echo "       but is not visible to user '$(id -un)' via 'security find-identity -v -p codesigning'." >&2
    echo "       Refusing to fall back to ad-hoc: that changes the designated requirement every" >&2
    echo "       build and invalidates the app's Accessibility (TCC) grant on each rebuild." >&2
    echo "       Import the cert + private key into this user's login keychain (or unset" >&2
    echo "       LOCALVOXTRAL_REQUIRE_CODESIGN_IDENTITY for an intentionally ad-hoc build)." >&2
    exit 1
  fi
  echo "Signing identity '$CODESIGN_IDENTITY' not found in keychain; falling back to ad-hoc signing." >&2
  CODESIGN_IDENTITY="-"
fi

# Defense in depth: the block above only runs when an identity was *named*. A
# lane that sets REQUIRE=1 but no identity at all (LOCALVOXTRAL_CODESIGN_IDENTITY
# empty → CODESIGN_IDENTITY="-") would otherwise skip every check and ad-hoc
# sign silently — the exact silent-downgrade this flag exists to prevent. Fail.
if [[ "${LOCALVOXTRAL_REQUIRE_CODESIGN_IDENTITY:-0}" == "1" && "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "FATAL: LOCALVOXTRAL_REQUIRE_CODESIGN_IDENTITY=1 but no signing identity is set" >&2
  echo "       (LOCALVOXTRAL_CODESIGN_IDENTITY is empty or '-'). Refusing to ad-hoc sign:" >&2
  echo "       that changes the designated requirement every build and invalidates the" >&2
  echo "       app's Accessibility (TCC) grant. Set LOCALVOXTRAL_CODESIGN_IDENTITY." >&2
  exit 1
fi

if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
  echo "Usage: ./scripts/package_app.sh [release|debug] [app-version] [build-number]"
  exit 1
fi

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid app version: $APP_VERSION"
  echo "Expected semantic version like 0.3.0"
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid build number: $BUILD_NUMBER"
  echo "Expected a positive integer like 1"
  exit 1
fi

APP_ICON_SOURCE="$ROOT_DIR/assets/icons/app/AppIcon.png"
MENUBAR_ICON_SOURCE="$ROOT_DIR/assets/icons/menubar/MicIconTemplate.png"
MENUBAR_ICON_2X_SOURCE="$ROOT_DIR/assets/icons/menubar/MicIconTemplate@2x.png"
MENUBAR_ICON_CONNECTED_2X_SOURCE="$ROOT_DIR/assets/icons/menubar/MicIconTemplate@2x_connected.png"
MENUBAR_ICON_FAILURE_2X_SOURCE="$ROOT_DIR/assets/icons/menubar/MicIconTemplate@2x_failure.png"

for required_asset in \
  "$APP_ICON_SOURCE" \
  "$MENUBAR_ICON_SOURCE" \
  "$MENUBAR_ICON_2X_SOURCE" \
  "$MENUBAR_ICON_CONNECTED_2X_SOURCE" \
  "$MENUBAR_ICON_FAILURE_2X_SOURCE"; do
  if [[ ! -f "$required_asset" ]]; then
    echo "Missing required icon asset: $required_asset"
    exit 1
  fi
done

# Ensure dependency checkout exists, then patch ShortcutRecorder's SwiftPM
# lookup so packaged resources in Contents/Resources can be found at runtime.
swift package resolve >/dev/null
patch_shortcutrecorder_bundle_lookup

# -g keeps DWARF in the object files so dsymutil can produce a dSYM below —
# without it, field crash reports only symbolicate as well as the stripped
# binary allows. It does not change optimization (-O still applies in release).
# The app's OWN resource bundle needs no patching: Bundle.localvoxtralResources
# (AppResourceBundle.swift) resolves Contents/Resources first at runtime. The
# old approach — patching the generated resource_bundle_accessor.swift and
# rebuilding — was silently reverted by the rebuild itself (the toolchain
# regenerates DerivedSources every build) and shipped launch-broken artifacts
# for days (#87). Never patch DerivedSources; only dependency checkouts (the
# ShortcutRecorder patch above) persist across builds.
swift build -c "$CONFIGURATION" --product localvoxtral -Xswiftc -g

BINARY_PATH="$(find "$ROOT_DIR/.build" -type f -path "*/${CONFIGURATION}/localvoxtral" | head -n 1)"
if [[ -z "$BINARY_PATH" ]]; then
  echo "Unable to find built localvoxtral binary under .build."
  exit 1
fi

# Collect debug symbols while the object files still exist; CI uploads the
# dSYM so crashes from any distributed build can be symbolicated later.
DSYM_PATH="$ROOT_DIR/dist/localvoxtral.dSYM"
mkdir -p "$ROOT_DIR/dist"
rm -rf "$DSYM_PATH"
dsymutil "$BINARY_PATH" -o "$DSYM_PATH"

APP_DIR="$ROOT_DIR/dist/localvoxtral.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/localvoxtral"
chmod +x "$APP_DIR/Contents/MacOS/localvoxtral"

# Copy SwiftPM resource bundles into Contents/Resources so the app remains a
# signable macOS bundle (bundle root must not contain extra unsealed content).
BUILD_PRODUCTS_DIR="$(cd "$(dirname "$BINARY_PATH")" && pwd)"
while IFS= read -r bundle_path; do
  bundle_name="$(basename "$bundle_path")"
  bundle_destination="$APP_DIR/Contents/Resources/$bundle_name"
  cp -R "$bundle_path" "$bundle_destination"
  bundle_base_name="${bundle_name%.bundle}"
  bundle_info_plist="$bundle_destination/Info.plist"

  # NSDataAsset lookups require a fully-formed bundle metadata record.
  # SwiftPM resource bundles may omit keys like CFBundlePackageType.
  if [[ -f "$bundle_info_plist" ]]; then
    bundle_id_suffix="$(printf '%s' "$bundle_base_name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
    bundle_id_suffix="${bundle_id_suffix##-}"
    bundle_id_suffix="${bundle_id_suffix%%-}"
    if [[ -z "$bundle_id_suffix" ]]; then
      bundle_id_suffix="resources"
    fi

    /usr/libexec/PlistBuddy -c "Set :CFBundleName $bundle_base_name" "$bundle_info_plist" >/dev/null 2>&1 || \
      /usr/libexec/PlistBuddy -c "Add :CFBundleName string $bundle_base_name" "$bundle_info_plist" >/dev/null
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.localvoxtral.bundle.$bundle_id_suffix" "$bundle_info_plist" >/dev/null 2>&1 || \
      /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.localvoxtral.bundle.$bundle_id_suffix" "$bundle_info_plist" >/dev/null
    /usr/libexec/PlistBuddy -c "Set :CFBundlePackageType BNDL" "$bundle_info_plist" >/dev/null 2>&1 || \
      /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string BNDL" "$bundle_info_plist" >/dev/null
  fi

  # ShortcutRecorder expects data assets (e.g. sr-mojave-info) compiled into
  # Assets.car. SwiftPM bundle copies may contain raw .xcassets only.
  if [[ -d "$bundle_destination/Images.xcassets" ]]; then
    tmp_partial_plist="$(mktemp)"
    xcrun actool "$bundle_destination/Images.xcassets" \
      --compile "$bundle_destination" \
      --platform macosx \
      --minimum-deployment-target 15.0 \
      --target-device mac \
      --output-partial-info-plist "$tmp_partial_plist" >/dev/null
    rm -f "$tmp_partial_plist"
  fi
done < <(find "$BUILD_PRODUCTS_DIR" -maxdepth 1 -type d -name "*.bundle" -print)

ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16 "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$APP_ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

cp "$MENUBAR_ICON_SOURCE" "$APP_DIR/Contents/Resources/MicIconTemplate.png"
cp "$MENUBAR_ICON_2X_SOURCE" "$APP_DIR/Contents/Resources/MicIconTemplate@2x.png"
cp "$MENUBAR_ICON_CONNECTED_2X_SOURCE" "$APP_DIR/Contents/Resources/MicIconTemplate@2x_connected.png"
cp "$MENUBAR_ICON_FAILURE_2X_SOURCE" "$APP_DIR/Contents/Resources/MicIconTemplate@2x_failure.png"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>localvoxtral</string>
  <key>CFBundleIdentifier</key>
  <string>com.localvoxtral.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>localvoxtral</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>localvoxtral needs microphone access for live dictation.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>localvoxtral needs local network access to reach realtime transcription endpoints.</string>
</dict>
</plist>
PLIST

# Remove filesystem metadata from copied assets (e.g. FinderInfo/resource fork)
# because codesign rejects bundles containing that detritus.
chmod -R u+w "$APP_DIR"
xattr -cr "$APP_DIR"

# Sign the packaged app so Gatekeeper can evaluate a usable signature.
# This does not replace Developer ID signing/notarization, but it avoids the
# "no usable signature" path that breaks first-run open flows.
if ! codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"; then
  echo "Failed to code-sign packaged app bundle."
  exit 1
fi
if ! codesign --verify --deep --strict --verbose=2 "$APP_DIR"; then
  echo "Invalid code signature detected in packaged app bundle."
  exit 1
fi

# Prove we did not silently downgrade to ad-hoc when a stable identity was
# requested. TCC keys the Accessibility grant on the designated requirement; an
# ad-hoc signature's DR pins the per-build cdhash, so an accidental ad-hoc
# artifact quietly invalidates the grant on the owner's next try-pr launch.
# The reliable ad-hoc marker is the 'Signature=adhoc' line, and it MUST be read
# at -dvv: at -dv the Authority/Signature detail lines aren't printed, so a
# '! grep Authority' test would false-positive on EVERY (even correctly signed)
# bundle. Check the positive marker instead.
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  if codesign -dvv "$APP_DIR" 2>&1 | grep -q '^Signature=adhoc'; then
    echo "Identity '$CODESIGN_IDENTITY' was requested but the sealed bundle is ad-hoc." >&2
    echo "codesign said:" >&2
    codesign -dvv "$APP_DIR" 2>&1 | sed 's/^/  /' >&2 || true
    echo "Refusing to ship an artifact that would invalidate the TCC grant on every build." >&2
    exit 1
  fi
fi

# Record the signer and designated requirement so a CI log (or a local run)
# proves the DR is stable across builds — compare this block between two builds
# to confirm the Accessibility grant will survive. (-dvv so Authority= prints.)
echo "Signed as: $(codesign -dvv "$APP_DIR" 2>&1 | grep -m1 '^Authority=' || echo 'ad-hoc')"
echo "Designated requirement (TCC keys the Accessibility grant on this — must be stable across builds):"
codesign -d --requirements - "$APP_DIR" 2>&1 | sed 's/^/  /' || true

touch "$APP_DIR"

echo "Packaged app: $APP_DIR"
echo "Debug symbols: $DSYM_PATH"
dwarfdump --uuid "$DSYM_PATH" 2>/dev/null | head -n 1 || true
echo "Contents/MacOS:"
find "$APP_DIR/Contents/MacOS" -maxdepth 1 -type f -exec basename {} \; | sort | sed 's/^/  /'
echo "Launch with: open \"$APP_DIR\""
