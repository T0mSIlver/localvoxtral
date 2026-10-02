#!/usr/bin/env bash
# Signs a packaged localvoxtral.app inside-out (#1430). Called by
# package_app.sh after the bundle is assembled:
#
#   sign-bundle.sh <app-dir> <codesign-identity>
#
# Each Mach-O gets its own signature and entitlements, nested code before the
# bundle that seals it. `--deep` is not used: it signs nested code without
# entitlements (the widget extension does not load without its sandbox) and
# Apple deprecates it for Developer ID.
#
# A "Developer ID Application" identity also gets the hardened runtime and a
# secure timestamp, both required for notarization. Ad-hoc and the runner's
# localvoxtral-dev identity sign without them, so dev builds behave as before.
# LOCALVOXTRAL_HARDENED_RUNTIME=1 forces the runtime on any identity, to test
# what the helpers need without a Developer ID certificate.
#
# Any Mach-O in the bundle that this script does not know fails the run: an
# unsigned nested binary is a notarization rejection, found here instead.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENTITLEMENTS_DIR="$ROOT_DIR/scripts/packaging"

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <app-dir> <codesign-identity>" >&2
  exit 2
fi
APP_DIR="$1"
IDENTITY="$2"

OPTIONS=(--force --sign "$IDENTITY")
DEVELOPER_ID=false
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
  DEVELOPER_ID=true
  OPTIONS+=(--options runtime --timestamp)
elif [[ "${LOCALVOXTRAL_HARDENED_RUNTIME:-0}" == "1" ]]; then
  OPTIONS+=(--options runtime)
fi

MACOS="$APP_DIR/Contents/MacOS"
APPEX="$APP_DIR/Contents/PlugIns/localvoxtralWidgets.appex"

# app.entitlements: the hardened runtime denies the microphone without
# device.audio-input, and in-process NSAppleScript (terminal panes, browser
# tabs) without automation.apple-events.
#
# Relative path inside the bundle -> entitlements file ("" = none). The two
# MLX helpers need helper.entitlements under the hardened runtime: without
# disable-library-validation they fail to load (measured in #1430).
NESTED=(
  "Contents/MacOS/localvoxtral-polishd|helper.entitlements"
  "Contents/MacOS/localvoxtral-speechd|helper.entitlements"
  "Contents/MacOS/localvoxtral-claude-hook|"
  "Contents/MacOS/localvoxtral-cli|"
)

sign_one() {
  local path="$1" entitlements="$2"
  local args=("${OPTIONS[@]}")
  [[ -z "$entitlements" ]] || args+=(--entitlements "$ENTITLEMENTS_DIR/$entitlements")
  codesign "${args[@]}" "$path"
}

# Every Mach-O must be one this script signs on purpose. Bundles without code
# (resource bundles, the metallib) are sealed as resources of the app.
known=("Contents/MacOS/localvoxtral" "Contents/PlugIns/localvoxtralWidgets.appex/Contents/MacOS/localvoxtralWidgets")
for entry in "${NESTED[@]}"; do known+=("${entry%%|*}"); done
unknown=()
while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q '^Mach-O'; then
    rel="${file#"$APP_DIR"/}"
    match=false
    for k in "${known[@]}"; do [[ "$rel" == "$k" ]] && match=true; done
    $match || unknown+=("$rel")
  fi
done < <(find "$APP_DIR" -type f -print0)
if [[ ${#unknown[@]} -gt 0 ]]; then
  echo "Mach-O files that sign-bundle.sh does not sign on purpose:" >&2
  printf '  %s\n' "${unknown[@]}" >&2
  echo "Add each to NESTED with its entitlements." >&2
  exit 1
fi

for entry in "${NESTED[@]}"; do
  rel="${entry%%|*}"
  entitlements="${entry#*|}"
  # LOCALVOXTRAL_SKIP_POLISHD / _SPEECHD build a bundle without that helper.
  [[ -e "$APP_DIR/$rel" ]] || continue
  sign_one "$APP_DIR/$rel" "$entitlements"
done
if [[ -d "$APPEX" ]]; then
  sign_one "$APPEX" widgets.entitlements
fi
sign_one "$APP_DIR" app.entitlements

if ! codesign --verify --deep --strict --verbose=2 "$APP_DIR"; then
  echo "Invalid code signature detected in packaged app bundle." >&2
  exit 1
fi
if [[ -d "$APPEX" ]] \
  && ! codesign -d --entitlements - "$APPEX" 2>/dev/null | grep -q 'com.apple.security.app-sandbox'; then
  echo "The widget extension lost its sandbox entitlement while signing." >&2
  exit 1
fi

# What notarization checks, per binary, so a CI log shows it before Apple does.
if $DEVELOPER_ID; then
  failed=false
  for rel in . Contents/PlugIns/localvoxtralWidgets.appex "${NESTED[@]%%|*}"; do
    code="$APP_DIR/$rel"
    [[ -e "$code" ]] || continue
    info="$(codesign -dvv "$code" 2>&1)"
    echo "$rel:"
    grep -E '^(Authority=Developer ID Application|CodeDirectory|Timestamp=)' <<<"$info" | sed 's/^/  /'
    if ! grep -q '^Authority=Developer ID Application' <<<"$info" \
      || ! grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime' <<<"$info" \
      || ! grep -q '^Timestamp=' <<<"$info"; then
      echo "  missing the Developer ID authority, the runtime flag or a timestamp" >&2
      failed=true
    fi
  done
  $failed && exit 1
fi
exit 0
