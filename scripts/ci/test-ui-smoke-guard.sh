#!/usr/bin/env bash
# Regression test for ui-smoke-guard.sh's decision logic. Both probes are
# stubbed via the script's env seams — no gh, no swift, runs anywhere.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GUARD="$ROOT_DIR/scripts/ci/ui-smoke-guard.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <expected run=> <description> [env overrides...]
expect() {
  local expected="$1" description="$2"
  shift 2
  local output
  output="$(env "$@" "$GUARD")" || fail "$description: guard exited non-zero"
  local run reason
  run="$(sed -n 's/^run=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  [[ "$run" == "$expected" ]] \
    || fail "$description: expected run=$expected, got run=$run ($reason)"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  printf 'PASS: %s (%s)\n' "$description" "$reason"
}

# A recent success wins before the lock probe is even consulted: the lock
# state must not matter (and the stubbed "error" state proves the probe is
# not reached, because reaching it would fail open into run=true).
expect false "recent success skips regardless of lock state" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=3600 \
  UI_SMOKE_GUARD_LOCK_STATE=error

# 20 h window boundary: 19 h ago is covered, 21 h ago is stale.
expect false "success 19 h ago still counts as covered" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=$((19 * 3600)) \
  UI_SMOKE_GUARD_LOCK_STATE=unlocked
expect true "success 21 h ago is stale — run again" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=$((21 * 3600)) \
  UI_SMOKE_GUARD_LOCK_STATE=unlocked

# Lock states with no recent success.
expect false "locked screen skips" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=none \
  UI_SMOKE_GUARD_LOCK_STATE=locked
expect false "missing GUI session skips" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=none \
  UI_SMOKE_GUARD_LOCK_STATE=no-session
expect true "unlocked screen runs" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=none \
  UI_SMOKE_GUARD_LOCK_STATE=unlocked

# A broken probe must fail OPEN — a silent permanent skip would disable the
# lane without anyone noticing.
expect true "probe error fails open into a run" \
  UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS=none \
  UI_SMOKE_GUARD_LOCK_STATE=error

echo "ui-smoke-guard tests passed"
