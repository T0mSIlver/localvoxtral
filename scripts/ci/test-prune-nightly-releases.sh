#!/usr/bin/env bash
# Regression test for prune-nightly-releases.sh.
#
# What this protects: release.yml feeds this script's output straight into
# `gh release delete --cleanup-tag --yes`. A tag printed here is a release and
# a tag that stop existing, so the tests below care as much about what is NOT
# printed (stable tags, rc tags, near-miss shapes) as about what is.
#
# Pure bash, no gh, no network: ./scripts/ci/test-prune-nightly-releases.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
PRUNE="$ROOT_DIR/scripts/ci/prune-nightly-releases.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# expect_delete <description> <keep> <expected-newline-separated> -- <tag>...
expect_delete() {
  local description="$1" keep="$2" expected="$3"
  shift 4  # description, keep, expected, and the literal --
  local got
  got="$(printf '%s\n' "$@" | "$PRUNE" --keep "$keep")" \
    || fail "$description: exited non-zero"
  if [[ "$got" != "$expected" ]]; then
    fail "$description:
  expected: [$expected]
  got:      [$got]"
  fi
  pass "$description"
}

# --- keeping the newest N ---------------------------------------------------

expect_delete "fewer nightlies than the keep count deletes nothing" 7 "" -- \
  v0.8.5-nightly.20260910 v0.8.5-nightly.20260911 v0.8.4

expect_delete "exactly the keep count deletes nothing" 3 "" -- \
  v0.8.5-nightly.20260910 v0.8.5-nightly.20260911 v0.8.5-nightly.20260912

expect_delete "the oldest beyond the keep count go, newest first" 3 \
"v0.8.5-nightly.20260911
v0.8.5-nightly.20260910" -- \
  v0.8.5-nightly.20260910 v0.8.5-nightly.20260911 v0.8.5-nightly.20260912 \
  v0.8.5-nightly.20260913 v0.8.5-nightly.20260914

# --- ordering is by date and sequence, not by version or input order --------

expect_delete "a higher version with an older date is still the older nightly" 1 \
"v0.9.0-nightly.20260101" -- \
  v0.9.0-nightly.20260101 v0.8.5-nightly.20260201

expect_delete "same-day sequences order numerically, and .N is newer than the bare tag" 1 \
"v0.8.5-nightly.20260916.9
v0.8.5-nightly.20260916.2
v0.8.5-nightly.20260916" -- \
  v0.8.5-nightly.20260916 v0.8.5-nightly.20260916.2 v0.8.5-nightly.20260916.9 \
  v0.8.5-nightly.20260916.10

expect_delete "input order does not matter" 2 \
"v0.8.5-nightly.20260910" -- \
  v0.8.5-nightly.20260912 v0.8.5-nightly.20260910 v0.8.5-nightly.20260911

# --- everything that is not a nightly is invisible to this script -----------
# These must never appear in the output, whatever the keep count.

expect_delete "stable, rc and near-miss tags are never candidates" 0 \
"v0.8.5-nightly.20260916" -- \
  v0.8.4 \
  v0.9.0-rc.1 \
  v0.8.5-nightly.20260916 \
  latest \
  main \
  nightly \
  v0.8.5-nightly \
  v0.8.5-nightly.2026091 \
  v0.8.5-nightly.202609167 \
  v0.8.5-nightly.20260916-extra \
  release-v0.8.5-nightly.20260916 \
  v0.8.5-nightly.20260916.x \
  "v0.8.5-nightly.20260916 --cleanup-tag" \
  "" \
  "  v0.8.5-nightly.20260915  "

expect_delete "an input with no nightlies at all prints nothing" 0 "" -- \
  v0.8.4 v0.9.0-rc.1 latest

# --- the input plumbing -----------------------------------------------------

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-prune-nightly-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
printf '%s\n' v0.8.5-nightly.20260910 v0.8.5-nightly.20260911 >"$TMP_DIR/tags.txt"
got="$("$PRUNE" --keep 1 "$TMP_DIR/tags.txt")"
[[ "$got" == "v0.8.5-nightly.20260910" ]] \
  || fail "reading tags from a file: got [$got]"
pass "tags can come from a file as well as stdin"

got="$(printf '%s\n' v0.8.5-nightly.20260910 v0.8.5-nightly.20260911 \
  v0.8.5-nightly.20260912 v0.8.5-nightly.20260913 v0.8.5-nightly.20260914 \
  v0.8.5-nightly.20260915 v0.8.5-nightly.20260916 v0.8.5-nightly.20260917 \
  | "$PRUNE")"
[[ "$got" == "v0.8.5-nightly.20260910" ]] \
  || fail "the default keep count is not 7: got [$got]"
pass "the default keeps the newest 7"

if printf 'v0.8.5-nightly.20260916\n' | "$PRUNE" --keep four >/dev/null 2>&1; then
  fail "a non-numeric --keep should be a usage error"
fi
pass "a non-numeric --keep is a usage error"

if printf 'v0.8.5-nightly.20260916\n' | "$PRUNE" --keep >/dev/null 2>&1; then
  fail "--keep without a value should be a usage error"
fi
pass "--keep without a value is a usage error"

printf 'OK: prune-nightly-releases tests passed\n'
