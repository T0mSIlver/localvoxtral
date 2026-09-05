#!/usr/bin/env bash
# Regression test for resolve-release-notes.sh.
#
# This is the only automated proof the notes mechanism can have: release.yml
# publishes real releases and tags, so it is never run to try something out.
# Everything the workflow decides therefore lives in the script under test,
# and the workflow's own use of it is one `body_path:` line.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
RESOLVE="$ROOT_DIR/scripts/ci/resolve-release-notes.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-release-notes-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/docs/release-notes"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# expect_ok <tag> <expected-path> <description>
expect_ok() {
  local tag="$1" expected="$2" description="$3" out path reason
  out="$("$RESOLVE" "$tag" "$TMP_DIR")" || fail "$description: exited non-zero"
  path="$(sed -n 's/^path=//p' <<<"$out")"
  reason="$(sed -n 's/^reason=//p' <<<"$out")"
  [[ "$path" == "$expected" ]] \
    || fail "$description: expected path='$expected', got '$path'"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  pass "$description ($reason)"
}

expect_fail() {
  local description="$1"
  shift
  if "$RESOLVE" "$@" >/dev/null 2>&1; then
    fail "$description: expected a non-zero exit, got 0"
  fi
  pass "$description"
}

# --- the optional-file contract --------------------------------------------

expect_ok v0.9.0 "" "a tag with no notes file publishes with generated notes only"

printf '## Highlights\n\nSomething user-facing.\n' >"$TMP_DIR/docs/release-notes/v0.9.0.md"
expect_ok v0.9.0 "docs/release-notes/v0.9.0.md" "a tag WITH a notes file resolves it"

printf 'rc notes\n' >"$TMP_DIR/docs/release-notes/v1.0.0-rc.2.md"
expect_ok v1.0.0-rc.2 "docs/release-notes/v1.0.0-rc.2.md" "prerelease tags follow the same convention"

expect_ok v9.9.9 "" "an unrelated tag does not pick up another tag's file"

# --- the one hard failure ---------------------------------------------------
# A file that exists but says nothing would publish a release whose human
# section is blank, which reads as a broken pipeline rather than a missing file.

: >"$TMP_DIR/docs/release-notes/v0.0.1.md"
expect_fail "an empty notes file is a hard failure, not a silent blank release" \
  v0.0.1 "$TMP_DIR"
printf '   \n\t\n' >"$TMP_DIR/docs/release-notes/v0.0.2.md"
expect_fail "a whitespace-only notes file is a hard failure too" \
  v0.0.2 "$TMP_DIR"

# --- the tag reaches a filesystem path, so its shape is validated -----------

expect_fail "a tag with a path separator is refused" "v1.0.0/../../etc/passwd" "$TMP_DIR"
expect_fail "a traversal tag is refused" "../../etc/passwd" "$TMP_DIR"
expect_fail "an unversioned tag is refused" "latest" "$TMP_DIR"
expect_fail "a tag without the v prefix is refused" "0.9.0" "$TMP_DIR"
expect_fail "no arguments is a usage error"

# --- the real repo ----------------------------------------------------------
# Whatever notes files are committed must all be resolvable and non-empty:
# a broken one only shows up during a release otherwise.
shopt -s nullglob
for f in "$ROOT_DIR"/docs/release-notes/v*.md; do
  tag="$(basename "$f" .md)"
  out="$("$RESOLVE" "$tag" "$ROOT_DIR")" \
    || fail "committed notes file $f does not resolve (empty, or a bad tag name?)"
  [[ "$(sed -n 's/^path=//p' <<<"$out")" == "docs/release-notes/$tag.md" ]] \
    || fail "committed notes file $f resolved to something else"
  pass "committed notes file docs/release-notes/$tag.md resolves"
done

printf 'OK: resolve-release-notes tests passed\n'
