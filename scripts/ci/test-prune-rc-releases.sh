#!/usr/bin/env bash
# Regression test for prune-rc-releases.sh.
#
# What this protects: release.yml feeds this script's output straight into
# `gh release delete --cleanup-tag --yes`. A tag printed here is a release and
# a tag that stop existing, so the tests below care as much about what is NOT
# printed (stable tags, near-miss shapes) as about what is.
#
# Input lines are "tag" or "tag<TAB>published_at"; T below is the TAB.
#
# Pure bash, no gh, no network: ./scripts/ci/test-prune-rc-releases.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
PRUNE="$ROOT_DIR/scripts/ci/prune-rc-releases.sh"

T="$(printf '\t')"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# expect_delete <description> <keep> <expected-newline-separated> -- <tag>...
expect_delete() {
  local description="$1" keep="$2" expected="$3"
  shift 4  # description, keep, expected, and the literal --
  local got
  got="$(printf '%s\n' "$@" | "$PRUNE" --keep "$keep" ${PROTECT:+--protect "$PROTECT"})" \
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

# --- published order, not version order ------------------------------------
# The reported case: hand-cut v1.0.0-rc.1..7 are still around, and the
# automatic v0.18.0-rc.1 was published last. It must stay.

expect_delete "the oldest published goes, not the just-published lower-version rc" 7 \
"v1.0.0-rc.1" -- \
  "v1.0.0-rc.1${T}2026-11-01T10:00:00Z" "v1.0.0-rc.2${T}2026-11-01T11:00:00Z" \
  "v1.0.0-rc.3${T}2026-11-01T12:00:00Z" "v1.0.0-rc.4${T}2026-11-01T13:00:00Z" \
  "v1.0.0-rc.5${T}2026-11-01T14:00:00Z" "v1.0.0-rc.6${T}2026-11-01T15:00:00Z" \
  "v1.0.0-rc.7${T}2026-11-01T16:00:00Z" "v0.18.0-rc.1${T}2026-11-07T09:00:00Z"

# --protect is a belt: the tag the run just published is never printed, even
# when its timestamp is missing or wrong and it sorts oldest.
PROTECT=v0.18.0-rc.1 expect_delete "the protected tag is never selected" 1 \
"v1.0.0-rc.1" -- \
  "v1.0.0-rc.1${T}2026-11-01T10:00:00Z" "v1.0.0-rc.2${T}2026-11-01T11:00:00Z" \
  "v0.18.0-rc.1"

# --- rcs and leftover nightlies are one pool --------------------------------

expect_delete "a leftover nightly ages out as the pool exceeds the keep count" 2 \
"v0.9.1-nightly.20261001" -- \
  "v0.9.1-nightly.20261001${T}2026-10-01T03:00:00Z" \
  "v0.9.1-nightly.20261002${T}2026-10-02T03:00:00Z" \
  "v0.18.0-rc.1${T}2026-11-07T09:00:00Z"

expect_delete "nightlies newer than the rcs are kept, older rcs go, newest first" 2 \
"v0.9.0-rc.2
v0.9.0-rc.1" -- \
  "v0.9.0-rc.1${T}2026-10-01T03:00:00Z" "v0.9.0-rc.2${T}2026-10-02T03:00:00Z" \
  "v0.9.1-nightly.20261003${T}2026-10-03T03:00:00Z" \
  "v0.9.1-nightly.20261004${T}2026-10-04T03:00:00Z"

expect_delete "a pool at or under the keep count deletes nothing, nightlies included" 7 "" -- \
  v0.8.5-nightly.20260916 v0.8.5-nightly.20260916.2 v0.9.0-rc.1 v0.8.4

# Without timestamps the tie-break applies: nightly date then sequence.
expect_delete "same-day nightly sequences order numerically, .N newer than the bare tag" 1 \
"v0.8.5-nightly.20260916.9
v0.8.5-nightly.20260916.2
v0.8.5-nightly.20260916" -- \
  v0.8.5-nightly.20260916 v0.8.5-nightly.20260916.2 v0.8.5-nightly.20260916.9 \
  v0.8.5-nightly.20260916.10

# --- everything else is invisible to this script ----------------------------
# These must never appear in the output, whatever the keep count.

expect_delete "stable and near-miss tags are never candidates" 0 \
"v0.8.5-nightly.20260916
v0.9.0-rc.1" -- \
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
