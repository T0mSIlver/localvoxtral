#!/usr/bin/env bash
# Regression test for rc-version.sh.
#
# release.yml publishes real tags, so the RC version rule is never tried out
# by running the workflow. Everything it decides lives in the script under
# test, and the workflow's use of it is one command.
#
# Pure bash, no git, no network: ./scripts/ci/test-rc-version.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
RC="$ROOT_DIR/scripts/ci/rc-version.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-rc-version-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# expect_tag <description> <expected-tag> <expected-base> <tag>...
expect_tag() {
  local description="$1" expected_tag="$2" expected_base="$3"
  shift 3
  local tags_file="$TMP_DIR/tags.txt" out tag base version
  printf '%s\n' "$@" >"$tags_file"
  out="$("$RC" "$tags_file")" || fail "$description: exited non-zero"
  tag="$(sed -n 's/^tag=//p' <<<"$out")"
  base="$(sed -n 's/^base=//p' <<<"$out")"
  version="$(sed -n 's/^version=//p' <<<"$out")"
  [[ "$tag" == "$expected_tag" ]] \
    || fail "$description: expected tag='$expected_tag', got '$tag'"
  [[ "$base" == "$expected_base" ]] \
    || fail "$description: expected base='$expected_base', got '$base'"
  [[ "v$version" == "$tag" ]] \
    || fail "$description: version='$version' and tag='$tag' disagree"
  pass "$description -> $tag (base $base)"
}

expect_fail() {
  local description="$1"
  shift
  if "$RC" "$@" >/dev/null 2>&1; then
    fail "$description: expected a non-zero exit, got 0"
  fi
  pass "$description"
}

# --- the shape --------------------------------------------------------------

expect_tag "a plain stable history bumps the minor and starts at rc.1" \
  v0.9.0-rc.1 v0.8.4 \
  v0.8.2 v0.8.3 v0.8.4

expect_tag "the patch resets to 0" \
  v0.18.0-rc.1 v0.17.2 \
  v0.17.0 v0.17.1 v0.17.2

expect_tag "an empty tag list starts from v0.0.0" \
  v0.1.0-rc.1 v0.0.0 \
  ""

expect_tag "the base is the highest version, not the longest string" \
  v0.11.0-rc.1 v0.10.0 \
  v0.9.0 v0.10.0 v0.8.4

# --- rc and nightly tags never poison the base ------------------------------
# release.yml's stable path excludes `v*-*` from its bump base for the same
# reason; this is the assertion that keeps that property honest here.

expect_tag "an rc tag is not a base" \
  v0.9.0-rc.1 v0.8.4 \
  v0.8.4 v0.99.0-rc.1

expect_tag "an rc tag ahead of every stable tag still bumps from the stable one" \
  v0.9.0-rc.3 v0.8.4 \
  v0.8.4 v0.9.0-rc.1 v0.9.0-rc.2 v0.10.0-rc.1

expect_tag "old -nightly tags are ignored, as base and as counter" \
  v0.9.0-rc.1 v0.8.4 \
  v0.8.4 v0.9.0-nightly.20260915 v0.8.5-nightly.20260916 v0.99.0-nightly.20260101

# --- N counts every existing rc of that version -----------------------------

expect_tag "a hand-cut v0.18.0-rc.3 makes the next auto one rc.4" \
  v0.18.0-rc.4 v0.17.2 \
  v0.17.2 v0.18.0-rc.3

expect_tag "the highest N wins, not the count" \
  v0.18.0-rc.8 v0.17.2 \
  v0.17.2 v0.18.0-rc.1 v0.18.0-rc.7

expect_tag "N compares as a number, not a string" \
  v0.18.0-rc.11 v0.17.2 \
  v0.17.2 v0.18.0-rc.9 v0.18.0-rc.10

expect_tag "an rc of another version does not count" \
  v0.18.0-rc.1 v0.17.2 \
  v0.17.2 v0.17.3-rc.5 v0.19.0-rc.2 v0.180.0-rc.4

expect_tag "a stable tag at the next version moves the base, so N restarts" \
  v0.19.0-rc.1 v0.18.0 \
  v0.17.2 v0.18.0 v0.18.0-rc.3

# --- arguments ---------------------------------------------------------------

expect_fail "a missing tags file is refused" "$TMP_DIR/nope.txt"
expect_fail "two arguments is a usage error" a b

printf 'OK: rc-version tests passed\n'
