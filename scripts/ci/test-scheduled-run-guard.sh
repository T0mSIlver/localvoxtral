#!/usr/bin/env bash
# Tests scheduled-run-guard.sh, the chain release.yml's Plan step runs, as
# release.yml calls it: each guard is pinned through its own seam (clock, a
# stub `gh` on PATH, the power state), so the chain's order and the dispatch
# bypass are what is under test (needs jq).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GUARD="$ROOT_DIR/scripts/ci/scheduled-run-guard.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-scheduled-run-guard-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh: counts calls, prints $STUB_RUNS.
echo called >>"$STUB_CALLS_FILE"
printf '%s\n' "$STUB_RUNS"
STUB
chmod +x "$TMP_DIR/bin/gh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# 2026-09-28T04:00:00Z, recent-run-guard.sh's clock; the night window takes
# each case's own HH:MM. SELF is the run asking.
NOW=1790568000
SELF=900
NO_RUNS='{"workflow_runs":[]}'
# A dispatched release on main that succeeded at 03:16 the same night.
DISPATCH_SUCCEEDED='{"workflow_runs":[{"id":800,"event":"workflow_dispatch","status":"completed","conclusion":"success","created_at":"2026-09-28T03:16:00Z"}]}'

# expect <run=> <reason substring> <gh calls> <description> <event> <HH:MM> <runs json> <power>
expect() {
  local expected="$1" want_reason="$2" want_calls="$3" description="$4"
  local event="$5" clock="$6" json="$7" power="$8"
  local output run reason calls
  : >"$TMP_DIR/calls"
  output="$(env "PATH=$TMP_DIR/bin:$PATH" STUB_CALLS_FILE="$TMP_DIR/calls" \
    STUB_RUNS="$json" GITHUB_EVENT_NAME="$event" \
    NIGHT_WINDOW_GUARD_NOW="$clock" RECENT_RUN_GUARD_NOW="$NOW" \
    AC_POWER_GUARD_STATE="$power" \
    GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID="$SELF" \
    "$GUARD" release.yml 20 20)" || fail "$description: guard exited non-zero"
  run="$(sed -n 's/^run=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  calls="$(wc -l <"$TMP_DIR/calls" | tr -d ' ')"
  [[ "$run" == "$expected" ]] \
    || fail "$description: expected run=$expected, got run=$run ($reason)"
  [[ "$reason" == *"$want_reason"* ]] \
    || fail "$description: reason '$reason' lacks '$want_reason'"
  [[ "$calls" == "$want_calls" ]] \
    || fail "$description: expected $want_calls gh call(s), got $calls"
  printf 'PASS: %s (%s)\n' "$description" "$reason"
}

expect true "on AC power" 1 \
  "schedule at 03:15, nothing ran yet, on AC: releases" \
  schedule 03:15 "$NO_RUNS" ac
expect false "outside the night window" 0 \
  "schedule fired late at 08:30: skips before asking GitHub" \
  schedule 08:30 "$NO_RUNS" ac
expect false "outside the night window" 0 \
  "schedule at 06:45 cannot finish a 20-minute run by 07:00: skips" \
  schedule 06:45 "$NO_RUNS" ac
expect false "run 800 (workflow_dispatch" 1 \
  "schedule after tonight's dispatched release succeeded: skips" \
  schedule 04:00 "$DISPATCH_SUCCEEDED" ac
expect false "battery" 1 \
  "schedule in the window with nothing ran, on battery: skips" \
  schedule 03:15 "$NO_RUNS" battery
expect true "dispatched by hand" 0 \
  "dispatch at 08:30 on battery after a success: runs, no guard asked" \
  workflow_dispatch 08:30 "$DISPATCH_SUCCEEDED" battery

# Bad arguments are a caller bug and exit 2, never a silent run or skip.
set +e
GITHUB_EVENT_NAME=schedule "$GUARD" release.yml 20 >/dev/null 2>&1
status=$?
set -e
[[ "$status" == 2 ]] || fail "missing <hours>: expected exit 2, got $status"
echo "PASS: missing <hours> exits 2"
