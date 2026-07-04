#!/usr/bin/env bash
set -euo pipefail

REPO="T0mSIlver/localvoxtral"
APP_NAME="localvoxtral.app"
INSTALL_PATH="/Applications/${APP_NAME}"
VERSION="${LOCALVOXTRAL_VERSION:-latest}"
DRYRUN="${LOCALVOXTRAL_INSTALL_DRYRUN:-0}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '==> %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

resolve_release_api_url() {
  if [ "$VERSION" = "latest" ]; then
    printf 'https://api.github.com/repos/%s/releases/latest\n' "$REPO"
  else
    printf 'https://api.github.com/repos/%s/releases/tags/%s\n' "$REPO" "$VERSION"
  fi
}

resolve_zip_url() {
  api_url="$(resolve_release_api_url)"
  release_json="$(curl -fsSL "$api_url")" || die "Could not fetch GitHub release metadata from $api_url"
  zip_urls="$(printf '%s\n' "$release_json" |
    grep '"browser_download_url"[[:space:]]*:' |
    sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\.zip\)".*/\1/p' || true)"
  zip_url="$(printf '%s\n' "$zip_urls" | sed -n '1p')"

  [ -n "$zip_url" ] || die "No .zip asset found for release '${VERSION}'. Check https://github.com/${REPO}/releases"
  printf '%s\n' "$zip_url"
}

require_command curl

step "Resolving localvoxtral release zip"
zip_url="$(resolve_zip_url)"
printf 'Resolved zip: %s\n' "$zip_url"

if [ "$DRYRUN" = "1" ]; then
  step "Dry run requested; stopping before download and macOS install steps"
  exit 0
fi

[ "$(uname -s)" = "Darwin" ] || die "This installer only runs on macOS. Set LOCALVOXTRAL_INSTALL_DRYRUN=1 to test release URL resolution elsewhere."

require_command ditto
require_command xattr
require_command codesign
require_command open

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/localvoxtral-install.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

zip_path="${tmp_dir}/localvoxtral.zip"

step "Downloading release"
curl -fL "$zip_url" -o "$zip_path" || die "Download failed: $zip_url"

step "Extracting app bundle"
ditto -x -k "$zip_path" "$tmp_dir" || die "Could not extract release zip"
app_path="$(find "$tmp_dir" -type d -name "$APP_NAME" -prune -print | sed -n '1p')"
[ -n "$app_path" ] || die "Extracted zip did not contain ${APP_NAME}"

step "Clearing quarantine and local signing metadata"
xattr -cr "$app_path" || die "Could not clear extended attributes from ${APP_NAME}"

# macOS 26 can stall forever at _dyld_start while scanning downloaded foreign
# ad-hoc-signed binaries. Re-signing locally outside /Applications avoids that
# scan path. This should become unnecessary once releases are notarized.
step "Re-signing app locally before it enters /Applications"
codesign --force --deep --sign - "$app_path" || die "Local ad-hoc signing failed"

if [ -d "$INSTALL_PATH" ]; then
  step "Replacing existing app in /Applications"
  osascript -e 'tell application "localvoxtral" to quit' >/dev/null 2>&1 || true
  sleep 2
  pkill -x localvoxtral >/dev/null 2>&1 || true
  rm -rf "$INSTALL_PATH" || die "Could not remove existing ${INSTALL_PATH}. Close localvoxtral and retry."
else
  step "Installing app into /Applications"
fi

mv "$app_path" "$INSTALL_PATH" || die "Could not move ${APP_NAME} into /Applications. You may need to run this installer from an administrator account."

step "Launching localvoxtral"
open "$INSTALL_PATH" || die "Installed app but could not launch it from ${INSTALL_PATH}"

step "Done"
