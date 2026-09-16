#!/usr/bin/env bash
# Regression test for nightly-version.sh.
#
# release.yml publishes real tags, so the nightly version rule is never tried
# out by running the workflow. Everything it decides lives in the script under
# test, and the workflow's use of it is one command.
#
# Pure bash, no git, no network: ./scripts/ci/test-nightly-version.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
NIGHTLY="$ROOT_DIR/scripts/ci/nightly-version.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-nightly-version-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# expect_tag <description> <date> <expected-tag> <expected-base> <tag>...
expect_tag() {
  local description="$1" date="$2" expected_tag="$3" expected_base="$4"
  shift 4
  local tags_file="$TMP_DIR/tags.txt" out tag base version
  printf '%s\n' "$@" >"$tags_file"
  out="$("$NIGHTLY" "$date" "$tags_file")" || fail "$description: exited non-zero"
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
  if "$NIGHTLY" "$@" >/dev/null 2>&1; then
    fail "$description: expected a non-zero exit, got 0"
  fi
  pass "$description"
}

# --- the shape --------------------------------------------------------------

expect_tag "a plain stable history bumps the patch and dates the suffix" \
  20260916 v0.8.5-nightly.20260916 v0.8.4 \
  v0.8.2 v0.8.3 v0.8.4

expect_tag "an empty tag list starts from v0.0.0" \
  20260916 v0.0.1-nightly.20260916 v0.0.0 \
  ""

expect_tag "the base is the highest version, not the longest string" \
  20260916 v0.10.1-nightly.20260916 v0.10.0 \
  v0.9.0 v0.10.0 v0.8.4

# --- nightly and rc tags never poison the stable bump base ------------------
# release.yml's stable path excludes `v*-*` from its bump base for the same
# reason; this is the assertion that keeps that property honest here.

expect_tag "yesterday's nightly is not a bump base" \
  20260916 v0.8.5-nightly.20260916 v0.8.4 \
  v0.8.4 v0.8.5-nightly.20260915 v0.8.5-nightly.20260915.2

expect_tag "an rc tag is not a bump base either" \
  20260916 v0.8.5-nightly.20260916 v0.8.4 \
  v0.8.4 v0.9.0-rc.1

expect_tag "a nightly ahead of every stable tag still bumps from the stable one" \
  20260916 v0.8.5-nightly.20260916 v0.8.4 \
  v0.8.4 v0.99.0-nightly.20260101

# --- a second nightly the same day -----------------------------------------

expect_tag "a same-day collision takes the first free .N" \
  20260916 v0.8.5-nightly.20260916.2 v0.8.4 \
  v0.8.4 v0.8.5-nightly.20260916

expect_tag "and keeps counting past it" \
  20260916 v0.8.5-nightly.20260916.4 v0.8.4 \
  v0.8.4 v0.8.5-nightly.20260916 v0.8.5-nightly.20260916.2 v0.8.5-nightly.20260916.3

expect_tag "a collision on another day is not a collision here" \
  20260917 v0.8.5-nightly.20260917 v0.8.4 \
  v0.8.4 v0.8.5-nightly.20260916 v0.8.5-nightly.20260916.2

# --- the date reaches a tag name, so its shape is validated ----------------

expect_fail "a non-date argument is refused" "yesterday"
expect_fail "a short date is refused" "2026916"
expect_fail "a date with a separator is refused" "2026-09-16"
expect_fail "no arguments is a usage error"

printf 'OK: nightly-version tests passed\n'
