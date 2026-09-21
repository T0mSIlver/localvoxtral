#!/usr/bin/env bash
# Installs localvoxtral with Homebrew and checks what landed.
#
# Usage:
#   scripts/ci/verify-cask-install.sh <tag>
#   scripts/ci/verify-cask-install.sh <tag> --cask-file <localvoxtral.rb>
#   scripts/ci/verify-cask-install.sh <tag> --upgrade-from <previous-tag> <previous-sha256>
#
# Meant for a hosted macOS runner, a Mac that has never had the app: it
# installs into /Applications, and zaps the cask on the way out.
#
# Plain: install from the public tap.
# --cask-file: install a cask that is not published yet, through a throwaway
#   local tap. cask.yml runs this BEFORE it pushes, so a cask that fails style,
#   audit, install or zap never reaches users.
# --upgrade-from: pin the public tap's local clone back to the previous
#   release, install it, restore the clone, and let `brew upgrade` make the
#   step — the path an existing user takes.
set -euo pipefail

usage() { sed -n '4,7p' "$0" >&2; exit 2; }

[[ $# -ge 1 ]] || usage
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TAG="$1"; shift
CASK_FILE="" PREVIOUS_TAG="" PREVIOUS_SHA256=""
case "${1:-}" in
  "") ;;
  --cask-file) [[ $# -eq 2 ]] || usage; CASK_FILE="$2" ;;
  --upgrade-from) [[ $# -eq 3 ]] || usage; PREVIOUS_TAG="$2"; PREVIOUS_SHA256="$3" ;;
  *) usage ;;
esac

APP="/Applications/localvoxtral.app"
PRIVATE_DIR="$HOME/Library/Application Support/localvoxtral"
SHARED_STORE="$HOME/Library/Application Support/default.store"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

expect_installed() {
  local expected="${1#v}" actual
  [[ -d "$APP" ]] || fail "$APP does not exist"
  actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  [[ "$actual" == "$expected" ]] || fail "$APP is version $actual, expected $expected"
  codesign --verify --deep --strict "$APP" || fail "$APP does not pass codesign --verify"
  if xattr -r "$APP" 2>/dev/null | grep -q com.apple.quarantine; then
    fail "$APP still carries com.apple.quarantine"
  fi
  pass "$APP is $actual, signature verifies, no quarantine flag"
}

[[ ! -e "$APP" ]] || fail "$APP already exists; this check is for a machine without the app"
[[ ! -e "$PRIVATE_DIR" && ! -e "$SHARED_STORE" ]] \
  || fail "app data already exists; the zap check would delete or misjudge real data"

if [[ -n "$CASK_FILE" ]]; then
  TAP="localvoxtral-ci/pretest"
  brew tap-new --no-git "$TAP" >/dev/null
  TAP_DIR="$(brew --repository "$TAP")"
  mkdir -p "$TAP_DIR/Casks"
  cp "$CASK_FILE" "$TAP_DIR/Casks/localvoxtral.rb"
else
  TAP="T0mSIlver/localvoxtral"
  brew tap "$TAP"
  TAP_DIR="$(brew --repository "$TAP")"
fi
CASK="$TAP/localvoxtral"

cleanup() {
  brew uninstall --cask --force localvoxtral >/dev/null 2>&1 || true
  [[ -z "$CASK_FILE" ]] || brew untap "$TAP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

brew style "$TAP_DIR/Casks/localvoxtral.rb"
brew audit --cask "$CASK"
pass "brew style and brew audit"

if [[ -n "$PREVIOUS_TAG" ]]; then
  "$ROOT_DIR/scripts/ci/render-cask.sh" "$PREVIOUS_TAG" "$PREVIOUS_SHA256" > "$TAP_DIR/Casks/localvoxtral.rb"
  brew install --cask "$CASK"
  expect_installed "$PREVIOUS_TAG"
  git -C "$TAP_DIR" checkout -- Casks/localvoxtral.rb
  brew outdated --cask --verbose | grep localvoxtral || fail "brew does not list localvoxtral as outdated"
  brew upgrade --cask "$CASK"
  expect_installed "$TAG"
  pass "brew upgrade ${PREVIOUS_TAG} -> ${TAG}"
else
  brew install --cask "$CASK"
  expect_installed "$TAG"
  pass "brew install --cask on a machine without the app"
fi

# Sentinels stand in for real data: zap must take the app's own directory and
# leave SwiftData's default store, a name other apps share.
mkdir -p "$PRIVATE_DIR"
touch "$PRIVATE_DIR/zap-sentinel" "$SHARED_STORE"
brew uninstall --cask --zap "$CASK"
[[ ! -e "$APP" ]] || fail "uninstall left $APP"
[[ ! -e "$PRIVATE_DIR" ]] || fail "zap left $PRIVATE_DIR"
[[ -e "$SHARED_STORE" ]] || fail "zap removed $SHARED_STORE, which other apps can share"
rm -f "$SHARED_STORE"
pass "zap removes the app's own data and leaves the shared store"
