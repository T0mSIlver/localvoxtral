#!/usr/bin/env bash
# Regression test for ui-smoke-guard.sh's decision logic. Both probes are
# stubbed via the script's env seams — no gh, no swift, runs anywhere.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GUARD="$ROOT_DIR/scripts/ci/ui-smoke-guard.sh"

# Pin the power probe for every case that is not about power: without this,
# running the suite on a battery-powered Mac would flip every expectation.
export AC_POWER_GUARD_STATE=ac

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

# Battery power skips before the lock probe is consulted: the stubbed error
# state proves the probe is not reached (reaching it would fail open into
# run=true).
expect false "battery power skips regardless of lock state" \
  AC_POWER_GUARD_STATE=battery \
  UI_SMOKE_GUARD_LOCK_STATE=error

# A broken power probe must fail open INTO the lock rule, not into an
# unconditional run.
expect true "power probe error falls through to an unlocked run" \
  AC_POWER_GUARD_STATE=error \
  UI_SMOKE_GUARD_LOCK_STATE=unlocked
expect false "power probe error still respects a locked screen" \
  AC_POWER_GUARD_STATE=error \
  UI_SMOKE_GUARD_LOCK_STATE=locked

expect false "locked screen skips" UI_SMOKE_GUARD_LOCK_STATE=locked
expect false "missing GUI session skips" UI_SMOKE_GUARD_LOCK_STATE=no-session
expect true "unlocked screen runs" UI_SMOKE_GUARD_LOCK_STATE=unlocked

# A broken probe must fail OPEN — a silent permanent skip would disable the
# lane without anyone noticing.
expect true "probe error fails open into a run" UI_SMOKE_GUARD_LOCK_STATE=error

echo "ui-smoke-guard tests passed"
