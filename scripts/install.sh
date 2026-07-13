#!/usr/bin/env bash
set -euo pipefail

REPO="T0mSIlver/localvoxtral"
APP_NAME="localvoxtral.app"
INSTALL_PATH="/Applications/${APP_NAME}"
VERSION="${LOCALVOXTRAL_VERSION:-latest}"
DRYRUN="${LOCALVOXTRAL_INSTALL_DRYRUN:-0}"
INSTALL_TMP_DIR=""

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

cleanup() {
  if [ -n "$INSTALL_TMP_DIR" ]; then
    rm -rf "$INSTALL_TMP_DIR"
  fi
}

resolve_release_api_url() {
  if [ "$VERSION" = "latest" ]; then
    printf 'https://api.github.com/repos/%s/releases/latest\n' "$REPO"
  else
    printf 'https://api.github.com/repos/%s/releases/tags/%s\n' "$REPO" "$VERSION"
  fi
}

resolve_zip_url() {
  local api_url http_code release_json release_json_file tag zip_url zip_urls

  api_url="$(resolve_release_api_url)"
  release_json_file="$(mktemp "${TMPDIR:-/tmp}/localvoxtral-release.XXXXXX")"
  http_code="$(curl -sSL -o "$release_json_file" -w '%{http_code}' "$api_url")" || {
    rm -f "$release_json_file"
    die "Could not fetch GitHub release metadata from $api_url"
  }
  release_json="$(cat "$release_json_file")"
  rm -f "$release_json_file"

  if [ "$http_code" = "403" ]; then
    die "Could not fetch GitHub release metadata from $api_url (HTTP 403). GitHub may have rate-limited this client; wait and retry, or set LOCALVOXTRAL_VERSION to a direct release tag such as v1.2.3."
  fi
  case "$http_code" in
    2*) ;;
    *) die "Could not fetch GitHub release metadata from $api_url (HTTP $http_code)" ;;
  esac

  # Select the app asset by its exact, contractual name: release.yml has
  # named it localvoxtral-<tag>.zip in every release ever published. Picking
  # by position or by excluding known-bad names broke in v0.7.4, when the API
  # listed the dSYM archive before the app zip and the installer downloaded
  # debug symbols (issue #131); exact-name selection is immune to new assets
  # appearing in any order. The tag comes from the metadata itself so
  # VERSION=latest resolves correctly too.
  tag="$(printf '%s\n' "$release_json" |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    sed -n '1p')"
  [ -n "$tag" ] || die "Could not read tag_name from GitHub release metadata for '${VERSION}'"

  zip_urls="$(printf '%s\n' "$release_json" |
    grep '"browser_download_url"[[:space:]]*:' |
    sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\.zip\)".*/\1/p' || true)"
  zip_url="$(printf '%s\n' "$zip_urls" |
    awk -v want="localvoxtral-${tag}.zip" -F/ '$NF == want { print; exit }')"

  [ -n "$zip_url" ] || die "Release '${tag}' has no asset named localvoxtral-${tag}.zip. Check https://github.com/${REPO}/releases"
  printf '%s\n' "$zip_url"
}

fetch_checksum() {
  local checksum_path checksum_url http_code

  checksum_url="${1}.sha256"
  checksum_path="$2"

  http_code="$(curl -sSL -o "$checksum_path" -w '%{http_code}' "$checksum_url")" || {
    rm -f "$checksum_path"
    printf 'Warning: could not fetch checksum asset %s; continuing without checksum verification.\n' "$checksum_url" >&2
    return 1
  }

  case "$http_code" in
    2*) return 0 ;;
    *)
      rm -f "$checksum_path"
      printf 'Warning: checksum asset %s is not available (HTTP %s); continuing without checksum verification.\n' "$checksum_url" "$http_code" >&2
      return 1
      ;;
  esac
}

verify_zip_checksum() {
  local checksum_path computed expected zip_path

  zip_path="$1"
  checksum_path="$2"

  [ -s "$checksum_path" ] || die "Checksum file is empty: $checksum_path"
  expected="$(awk 'NR == 1 { print $1 }' "$checksum_path")"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || die "Checksum file $checksum_path does not start with a valid SHA-256 digest"

  require_command shasum
  computed="$(shasum -a 256 "$zip_path" | awk '{ print $1 }')"
  [ "$computed" = "$expected" ] || die "Checksum mismatch for downloaded zip: expected $expected, got $computed"
}

install_app_bundle() {
  local app_path old_path

  app_path="$1"

  if [ -d "$INSTALL_PATH" ]; then
    step "Replacing existing app in /Applications"
    old_path="${INSTALL_PATH}.old.$$"
    [ ! -e "$old_path" ] || die "Refusing to overwrite existing backup path: $old_path"
    osascript -e 'tell application "localvoxtral" to quit' >/dev/null 2>&1 || true
    sleep 2
    pkill -x localvoxtral >/dev/null 2>&1 || true
    mv "$INSTALL_PATH" "$old_path" || die "Could not move existing ${INSTALL_PATH} aside. Close localvoxtral and retry."
    if mv "$app_path" "$INSTALL_PATH"; then
      rm -rf "$old_path" || printf 'Warning: installed new app, but could not remove old app backup at %s\n' "$old_path" >&2
    else
      mv "$old_path" "$INSTALL_PATH" || printf 'Error: failed to restore previous app from %s to %s\n' "$old_path" "$INSTALL_PATH" >&2
      die "Could not move ${APP_NAME} into /Applications. Previous install was restored if possible."
    fi
  else
    step "Installing app into /Applications"
    mv "$app_path" "$INSTALL_PATH" || die "Could not move ${APP_NAME} into /Applications. You may need to run this installer from an administrator account."
  fi
}

main() {
  local app_path checksum_path zip_path zip_url

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

  INSTALL_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/localvoxtral-install.XXXXXX")"
  trap cleanup EXIT

  zip_path="${INSTALL_TMP_DIR}/localvoxtral.zip"
  checksum_path="${zip_path}.sha256"

  step "Downloading release"
  curl -fL "$zip_url" -o "$zip_path" || die "Download failed: $zip_url"

  # The checksum comes from the same GitHub release as the zip. It protects
  # against corruption or truncated downloads, not a compromised release account.
  step "Checking release checksum"
  if fetch_checksum "$zip_url" "$checksum_path"; then
    verify_zip_checksum "$zip_path" "$checksum_path"
  fi

  step "Extracting app bundle"
  ditto -x -k "$zip_path" "$INSTALL_TMP_DIR" || die "Could not extract release zip"
  app_path="$(find "$INSTALL_TMP_DIR" -type d -name "$APP_NAME" -prune -print | sed -n '1p')"
  [ -n "$app_path" ] || die "Extracted zip did not contain ${APP_NAME}"

  step "Clearing quarantine and local signing metadata"
  xattr -cr "$app_path" || die "Could not clear extended attributes from ${APP_NAME}"

  # macOS 26 can stall forever at _dyld_start while scanning downloaded foreign
  # ad-hoc-signed binaries. Re-signing locally outside /Applications avoids that
  # scan path. This should become unnecessary once releases are notarized.
  # --deep is deprecated but field-verified working on macOS 26.5 (2026-07-04);
  # if Apple removes it, sign nested executables explicitly instead.
  step "Re-signing app locally before it enters /Applications"
  codesign --force --deep --sign - "$app_path" || die "Local ad-hoc signing failed"

  install_app_bundle "$app_path"

  step "Launching localvoxtral"
  open "$INSTALL_PATH" || die "Installed app but could not launch it from ${INSTALL_PATH}"

  step "Done"
}

# BASH_SOURCE is unset when the script arrives on stdin (`curl ... | bash`),
# and `set -u` turns that into a fatal unbound-variable error. Empty means
# "not being sourced", so run main in that case too.
if [[ "${BASH_SOURCE[0]:-}" == "" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  main "$@"
fi
