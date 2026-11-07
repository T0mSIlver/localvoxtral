#!/usr/bin/env bash
# Regression test for prune-rc-releases.sh.
#
# What this protects: release.yml feeds this script's output straight into
# `gh release delete --cleanup-tag --yes`. A tag printed here is a release and
# a tag that stop existing, so the tests below care as much about what is NOT
# printed (stable tags, near-miss shapes) as about what is.
#
# Pure bash, no gh, no network: ./scripts/ci/test-prune-rc-releases.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
PRUNE="$ROOT_DIR/scripts/ci/prune-rc-releases.sh"

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

# --- keeping the newest N rc releases ---------------------------------------

expect_delete "fewer rcs than the keep count deletes nothing" 7 "" -- \
  v0.9.0-rc.1 v0.9.0-rc.2 v0.8.4

expect_delete "exactly the keep count deletes nothing" 3 "" -- \
  v0.9.0-rc.1 v0.9.0-rc.2 v0.9.0-rc.3

expect_delete "the oldest beyond the keep count go, newest first" 3 \
"v0.9.0-rc.2
v0.9.0-rc.1" -- \
  v0.9.0-rc.1 v0.9.0-rc.2 v0.9.0-rc.3 v0.9.0-rc.4 v0.9.0-rc.5

# --- rc ordering is by version and N, as numbers, not by input order --------

expect_delete "a higher version is newer whatever its N" 1 \
"v0.9.0-rc.5" -- \
  v0.9.0-rc.5 v0.10.0-rc.1

expect_delete "N orders numerically, not as a string" 1 \
"v0.9.0-rc.9
v0.9.0-rc.2" -- \
  v0.9.0-rc.2 v0.9.0-rc.9 v0.9.0-rc.10

expect_delete "input order does not matter" 2 \
"v0.9.0-rc.1" -- \
  v0.9.0-rc.3 v0.9.0-rc.1 v0.9.0-rc.2

# --- leftover nightlies always age out --------------------------------------

expect_delete "every nightly is deleted, newest first, whatever the keep count" 7 \
"v0.8.5-nightly.20260916.2
v0.8.5-nightly.20260916
v0.9.0-nightly.20260101" -- \
  v0.9.0-nightly.20260101 v0.8.5-nightly.20260916 v0.8.5-nightly.20260916.2 \
  v0.8.4

expect_delete "same-day nightly sequences order numerically, .N newer than the bare tag" 0 \
"v0.8.5-nightly.20260916.10
v0.8.5-nightly.20260916.9
v0.8.5-nightly.20260916.2
v0.8.5-nightly.20260916" -- \
  v0.8.5-nightly.20260916 v0.8.5-nightly.20260916.2 v0.8.5-nightly.20260916.9 \
  v0.8.5-nightly.20260916.10

expect_delete "pruned rcs come before nightlies, and nightlies never use up the keep count" 1 \
"v0.9.0-rc.1
v0.8.5-nightly.20260916" -- \
  v0.8.5-nightly.20260916 v0.9.0-rc.1 v0.9.0-rc.2

# --- everything else is invisible to this script ----------------------------
# These must never appear in the output, whatever the keep count.

expect_delete "stable and near-miss tags are never candidates" 0 \
"v0.9.0-rc.1
v0.8.5-nightly.20260916" -- \
  v0.8.4 \
  v0.9.0-rc.1 \
  v0.8.5-nightly.20260916 \
  latest \
  main \
  nightly \
  rc \
  v0.9.0-rc \
  v0.9.0-rc.1-extra \
  v0.9.0-rc.x \
  v0.9-rc.1 \
  release-v0.9.0-rc.1 \
  "v0.9.0-rc.1 --cleanup-tag" \
  "  v0.9.0-rc.2  " \
  v0.8.5-nightly \
  v0.8.5-nightly.2026091 \
  v0.8.5-nightly.202609167 \
  v0.8.5-nightly.20260916-extra \
  release-v0.8.5-nightly.20260916 \
  v0.8.5-nightly.20260916.x \
  "v0.8.5-nightly.20260916 --cleanup-tag" \
  "" \
  "  v0.8.5-nightly.20260915  "

expect_delete "an input with no rc or nightly tags prints nothing" 0 "" -- \
  v0.8.4 v0.9.0 latest

# --- the input plumbing -----------------------------------------------------

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-prune-rc-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
printf '%s\n' v0.9.0-rc.1 v0.9.0-rc.2 >"$TMP_DIR/tags.txt"
got="$("$PRUNE" --keep 1 "$TMP_DIR/tags.txt")"
[[ "$got" == "v0.9.0-rc.1" ]] \
  || fail "reading tags from a file: got [$got]"
pass "tags can come from a file as well as stdin"

got="$(printf '%s\n' v0.9.0-rc.1 v0.9.0-rc.2 v0.9.0-rc.3 v0.9.0-rc.4 \
  v0.9.0-rc.5 v0.9.0-rc.6 v0.9.0-rc.7 v0.9.0-rc.8 \
  | "$PRUNE")"
[[ "$got" == "v0.9.0-rc.1" ]] \
  || fail "the default keep count is not 7: got [$got]"
pass "the default keeps the newest 7"

if printf 'v0.9.0-rc.1\n' | "$PRUNE" --keep four >/dev/null 2>&1; then
  fail "a non-numeric --keep should be a usage error"
fi
pass "a non-numeric --keep is a usage error"

if printf 'v0.9.0-rc.1\n' | "$PRUNE" --keep >/dev/null 2>&1; then
  fail "--keep without a value should be a usage error"
fi
pass "--keep without a value is a usage error"

printf 'OK: prune-rc-releases tests passed\n'
