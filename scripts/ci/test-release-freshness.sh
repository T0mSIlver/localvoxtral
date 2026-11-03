#!/usr/bin/env bash
# Regression test for release-freshness.sh: main must go red when commits have
# waited for a release longer than the limit, and stay green otherwise. The
# clock is injected (RELEASE_FRESHNESS_NOW); commit dates are fixed with
# GIT_COMMITTER_DATE.
#   ./scripts/ci/test-release-freshness.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
CHECK="$ROOT_DIR/scripts/ci/release-freshness.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-release-freshness-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

DAY=86400
T0=1790000000   # an arbitrary fixed epoch; every date below is relative to it

REPO="$TMP_DIR/repo"
git init -q -b main "$REPO"
# commit <message> <epoch>
commit() {
  GIT_AUTHOR_DATE="@$2 +0000" GIT_COMMITTER_DATE="@$2 +0000" \
    git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"
}
tag() { git -C "$REPO" -c user.name=t -c user.email=t@t tag -a "$1" -m "$1"; }

commit c1 "$T0"
tag v0.9.0
commit c2 "$((T0 + 1 * DAY))"       # first commit after the stable tag
commit c3 "$((T0 + 5 * DAY))"
tag v0.10.0-nightly.20260101         # a nightly never counts as a release
commit c4 "$((T0 + 9 * DAY))"

# check <now-offset-days> [limit-days]: prints the script's output, returns its status.
check() {
  local now="$((T0 + $1 * DAY))" limit="${2:-}" status=0
  (cd "$REPO" && env RELEASE_FRESHNESS_NOW="$now" ${limit:+RELEASE_FRESHNESS_DAYS="$limit"} "$CHECK") \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err" || status=$?
  return "$status"
}
field() { sed -n "s/^$1=//p" "$TMP_DIR/out"; }

# 1: the oldest unreleased commit (c2, day 1) is 11 days old on day 12.
if check 12; then fail "12 days without a release passed: $(cat "$TMP_DIR/out")"; fi
[[ "$(field stale)" == true ]] || fail "stale=$(field stale)"
[[ "$(field base)" == v0.9.0 ]] || fail "base must be the stable tag, never the nightly: $(field base)"
[[ "$(field waiting)" == 3 ]] || fail "waiting=$(field waiting), expected 3"
[[ "$(field oldest_days)" == 11 ]] || fail "oldest_days=$(field oldest_days), expected 11"
grep -q "gh run list -w release.yml" "$TMP_DIR/out" || fail "the reason names where to look: $(cat "$TMP_DIR/out")"
pass "a main that has waited 11 days for a release fails, naming the stable tag and where to look"

# 2: the same history, measured two days after the oldest commit.
check 3 || fail "2 days of waiting failed: $(cat "$TMP_DIR/out")"
[[ "$(field stale)" == false ]] || fail "stale=$(field stale)"
pass "a commit younger than the limit passes"

# 3: the limit is inclusive and configurable.
if check 4 3; then fail "a 3-day-old commit passed a 3-day limit: $(cat "$TMP_DIR/out")"; fi
check 3 3 || fail "a 2-day-old commit failed a 3-day limit"
pass "the limit is in whole days and configurable"

# 4: nothing since the stable tag.
tag v0.11.0
check 365 || fail "a released main failed: $(cat "$TMP_DIR/out")"
[[ "$(field waiting)" == 0 ]] || fail "waiting=$(field waiting)"
pass "main at the newest stable tag passes however old the tag is"

# 5: no stable tag at all does not fail the check.
git -C "$REPO" tag -d v0.9.0 v0.11.0 >/dev/null
check 365 || fail "no stable tag failed: $(cat "$TMP_DIR/out")"
[[ "$(field base)" == none ]] || fail "base=$(field base)"
pass "a history without a stable tag passes"

echo "OK: release freshness"
