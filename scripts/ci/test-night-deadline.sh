#!/usr/bin/env bash
# Tests night-deadline.sh with the clock pinned through its seam.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/ci/night-deadline.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# 2026-10-04 00:00:00 UTC.
DAY=1791072000
at() { echo $((DAY + $1 * 3600 + $2 * 60)); }
SEVEN=$(at 7 0)

# expect <expected stdout> <description> <now-epoch> <args...>
expect() {
  local expected="$1" description="$2" now="$3"
  shift 3
  local output
  output="$(NIGHT_DEADLINE_NOW="$now" "$SCRIPT" "$@")" \
    || fail "$description: exited non-zero"
  [[ "$output" == "$expected" ]] \
    || fail "$description: expected '$expected', got '$output'"
  printf 'PASS: %s (%s)\n' "$description" "$output"
}

# expect_refusal <exit> <description> <now-epoch> <args...>
expect_refusal() {
  local expected_rc="$1" description="$2" now="$3"
  shift 3
  local rc=0 output
  output="$(NIGHT_DEADLINE_NOW="$now" "$SCRIPT" "$@" 2>&1)" || rc=$?
  [[ "$rc" == "$expected_rc" ]] \
    || fail "$description: expected exit $expected_rc, got $rc ($output)"
  printf 'PASS: %s\n' "$description"
}

expect "deadline=$SEVEN" "a 03:15 start is bound to 07:00 that day" "$(at 3 15)" deadline
expect "deadline=$SEVEN" "midnight is inside the window" "$DAY" deadline
expect "deadline=$SEVEN" "06:59 is inside the window" "$(at 6 59)" deadline
expect "deadline=" "07:00 is outside: a daytime dispatch is not bound" "$SEVEN" deadline
expect "deadline=" "23:59 is outside" "$(at 23 59)" deadline

# The release's app wait: 180 min cap, 20 min reserved for the DMG and publish.
expect "180m" "no deadline keeps the whole cap" "$(at 12 0)" timeout "" 180 20
expect "135m" "a 04:25 app wait gets what is left before 07:00 less the reserve" "$(at 4 25)" timeout "$SEVEN" 180 20
expect "60m" "the cap wins when the window is long" "$(at 1 0)" timeout "$SEVEN" 60 10
expect "180m" "a midnight start keeps the 3 h cap" "$DAY" timeout "$SEVEN" 180 20
expect "1m" "one minute left is still a wait" "$(at 6 39)" timeout "$SEVEN" 180 20
expect_refusal 1 "no minute left fails before submitting" "$(at 6 40)" timeout "$SEVEN" 180 20
expect_refusal 1 "a deadline already past fails" "$(at 7 30)" timeout "$SEVEN" 60 10

out="$(NIGHT_DEADLINE_NOW="$(at 6 50)" "$SCRIPT" timeout "$SEVEN" 60 10 2>&1)" && fail "06:50 with a 10 min reserve ran"
grep -qF "::error::The night window ends at 07:00 UTC" <<<"$out" \
  || fail "the refusal does not say why: $out"
printf 'PASS: the refusal names the window\n'

expect_refusal 2 "an unknown verb is a usage error" "$DAY" later
expect_refusal 2 "a zero cap is a usage error" "$DAY" timeout "" 0 5
expect_refusal 2 "a malformed deadline is a usage error" "$DAY" timeout soon 60 5
expect_refusal 2 "a malformed clock is an error" "now" deadline

# The real clock path: no seam, the output is still a decision.
output="$(NIGHT_DEADLINE_NOW= "$SCRIPT" deadline)" || fail "real clock: exited non-zero"
grep -qE '^deadline=([0-9]+)?$' <<<"$output" || fail "real clock: no deadline= line in: $output"
printf 'PASS: the real clock yields a decision\n'
