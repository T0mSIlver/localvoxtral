#!/usr/bin/env bash
# Regression test for render-cask.sh.
#
# cask.yml pushes whatever the renderer prints to the public tap, and it only
# runs after a real stable release, so the pin and the stable-only refusal are
# tried here instead.
#
# Pure bash, no network: ./scripts/ci/test-render-cask.sh
# With ruby on PATH (macOS and the hosted runners have it) the output is also
# syntax-checked.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
RENDER="$ROOT_DIR/scripts/ci/render-cask.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-render-cask-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

SHA="20eb046ca113233364708c7445ae0e52609eefcbc89a25f8699522ef7cbfe837"

expect_refusal() {
  local description="$1"
  shift
  if "$RENDER" "$@" >"$TMP_DIR/refused.rb" 2>"$TMP_DIR/refused.err"; then
    fail "$description: expected a refusal, got exit 0"
  fi
  [[ ! -s "$TMP_DIR/refused.rb" ]] \
    || fail "$description: a refusal must print no cask, got $(wc -c <"$TMP_DIR/refused.rb") bytes"
  pass "$description -> refused ($(head -n1 "$TMP_DIR/refused.err"))"
}

CASK="$TMP_DIR/localvoxtral.rb"
"$RENDER" v0.9.0 "$SHA" >"$CASK" || fail "stable tag: exited non-zero"

grep -qx '  version "0.9.0"' "$CASK" || fail "stable tag: version is not pinned to 0.9.0"
grep -qx "  sha256 \"$SHA\"" "$CASK" || fail "stable tag: sha256 is not the one passed in"
pass "stable tag pins version and sha256"

# The url must stay interpolated: `brew bump-cask-pr`-style tooling and
# livecheck both rewrite `version` alone and expect the url to follow.
# shellcheck disable=SC2016
grep -qxF '  url "https://github.com/T0mSIlver/localvoxtral/releases/download/v#{version}/localvoxtral-v#{version}.zip"' "$CASK" \
  || fail "url does not name the contractual app zip, localvoxtral-v<version>.zip"
pass "url names the app zip by its contractual name"

# Both halves of install.sh's Gatekeeper handling; xattr alone leaves the
# macOS 26 first-launch hang.
grep -q '"/usr/bin/xattr"' "$CASK" || fail "postflight does not clear quarantine"
grep -q '"--force", "--deep", "--sign", "-"' "$CASK" || fail "postflight does not re-sign locally"
pass "postflight clears quarantine and re-signs"

ZAP="$(sed -n '/^  zap trash: \[/,/^  \]/p' "$CASK")"
[[ -n "$ZAP" ]] || fail "the cask has no zap stanza"
for path in \
  "~/Library/Application Support/localvoxtral" \
  "~/Library/Caches/com.localvoxtral.app" \
  "~/Library/HTTPStorages/com.localvoxtral.app" \
  "~/Library/Preferences/com.localvoxtral.app.plist" \
  "~/Library/Saved Application State/com.localvoxtral.app.savedState"; do
  grep -qF "\"$path\"," <<<"$ZAP" || fail "zap does not list $path"
done
pass "zap lists the app's own paths"
if grep -q 'default\.store\|huggingface' <<<"$ZAP"; then
  fail "zap lists a path other apps share"
fi
pass "zap leaves shared paths alone"

expect_refusal "nightly tag" v0.9.1-nightly.20260921 "$SHA"
expect_refusal "rc tag" v1.0.0-rc.1 "$SHA"
expect_refusal "tag without v" 0.9.0 "$SHA"
expect_refusal "short sha256" v0.9.0 abc123
expect_refusal "uppercase sha256" v0.9.0 "$(tr 'a-f' 'A-F' <<<"$SHA")"
expect_refusal "shasum line instead of the digest" v0.9.0 "$SHA  localvoxtral-v0.9.0.zip"
expect_refusal "missing sha256" v0.9.0

if command -v ruby >/dev/null 2>&1; then
  ruby -c "$CASK" >/dev/null || fail "rendered cask is not valid Ruby"
  pass "rendered cask is valid Ruby"
else
  printf 'SKIP: ruby not on PATH, syntax not checked\n'
fi

printf 'All render-cask tests passed.\n'
