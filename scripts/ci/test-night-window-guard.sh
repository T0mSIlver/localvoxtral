#!/usr/bin/env bash
# Tests night-window-guard.sh with the clock pinned through its seam.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GUARD="$ROOT_DIR/scripts/ci/night-window-guard.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <expected run=> <description> <now HH:MM> [job-minutes]
expect() {
  local expected="$1" description="$2" now="$3"
  shift 3
  local output run reason
  output="$(NIGHT_WINDOW_GUARD_NOW="$now" "$GUARD" "$@")" \
    || fail "$description: guard exited non-zero"
  run="$(sed -n 's/^run=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  [[ "$run" == "$expected" ]] \
    || fail "$description: expected run=$expected, got run=$run ($reason)"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  printf 'PASS: %s (%s)\n' "$description" "$reason"
}

expect_error() {
  local description="$1" now="$2"
  shift 2
  if NIGHT_WINDOW_GUARD_NOW="$now" "$GUARD" "$@" >/dev/null 2>&1; then
    fail "$description: guard accepted bad input"
  fi
  printf 'PASS: %s\n' "$description"
}

expect true "the cron time itself runs" 04:45 30
expect true "midnight opens the window" 00:00 30
expect true "the latest start that still ends by 07:00 runs" 06:30 30
expect false "one minute past the latest start skips" 06:31 30
expect false "a Sunday run GitHub created at 09:33 UTC skips" 09:33 30
expect false "the evening before the window skips" 23:59 30
expect true "a zero-length job may start at 07:00" 07:00
expect false "a zero-length job may not start at 07:01" 07:01
expect true "minute 09 parses as decimal, not octal" 00:09 0
expect false "08:08 parses and skips" 08:08 0
expect false "a job longer than the window never runs" 00:00 421

expect_error "a malformed time is an error, not a run" 7:00 30
expect_error "a malformed job length is an error" 04:45 thirty

# The real clock path: no seam, the output is still a decision.
output="$(NIGHT_WINDOW_GUARD_NOW= "$GUARD" 30)" || fail "real clock: guard exited non-zero"
grep -qE '^run=(true|false)$' <<<"$output" || fail "real clock: no run= line in: $output"
printf 'PASS: the real clock yields a decision\n'
