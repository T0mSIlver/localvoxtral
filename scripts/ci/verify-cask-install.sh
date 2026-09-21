#!/usr/bin/env bash
# Installs localvoxtral from the public tap and checks what landed.
#
# Usage:
#   scripts/ci/verify-cask-install.sh <tag> [previous-tag previous-sha256]
#
# Meant for a hosted macOS runner, a Mac that has never had the app: it
# installs into /Applications and removes the cask again on the way out.
#
# With <previous-tag> the tap's local clone is first pinned back to that
# release, the old version is installed, the clone is restored, and the step
# from old to <tag> is made by `brew upgrade` — the path an existing user takes.
set -euo pipefail

if [[ $# -ne 1 && $# -ne 3 ]]; then
  echo "usage: $0 <tag> [previous-tag previous-sha256]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
TAG="$1"
PREVIOUS_TAG="${2:-}"
PREVIOUS_SHA256="${3:-}"
CASK="T0mSIlver/localvoxtral/localvoxtral"
APP="/Applications/localvoxtral.app"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

installed_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
}

expect_installed() {
  local expected="${1#v}" actual
  [[ -d "$APP" ]] || fail "$APP does not exist"
  actual="$(installed_version)"
  [[ "$actual" == "$expected" ]] || fail "$APP is version $actual, expected $expected"
  codesign --verify --deep --strict "$APP" || fail "$APP does not pass codesign --verify"
  if xattr -r "$APP" 2>/dev/null | grep -q com.apple.quarantine; then
    fail "$APP still carries com.apple.quarantine"
  fi
  pass "$APP is $actual, signature verifies, no quarantine flag"
}

[[ ! -e "$APP" ]] || fail "$APP already exists; this check is for a machine without the app"

cleanup() { brew uninstall --cask --force localvoxtral >/dev/null 2>&1 || true; }
trap cleanup EXIT

brew tap T0mSIlver/localvoxtral
TAP_DIR="$(brew --repository T0mSIlver/localvoxtral)"

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
