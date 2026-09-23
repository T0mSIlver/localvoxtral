#!/bin/bash
# Pins scripts/ci/background-step.sh: `finish` must fail the step exactly when
# the backgrounded command failed, show its output, and never pass on a
# command that is still running or was never started.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
STEP="$ROOT_DIR/scripts/ci/background-step.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-background-step-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# finish_status <state-dir> <timeout> — runs `finish`, output to $TMP_DIR/out.
finish_status() {
  local status=0
  "$STEP" finish "$1" "$2" >"$TMP_DIR/out" 2>&1 || status=$?
  echo "$status"
}

# start returns before the command ends.
started=$SECONDS
"$STEP" start "$TMP_DIR/slow" -- bash -c 'sleep 3; echo slow-done' >/dev/null
[[ $((SECONDS - started)) -lt 3 ]] || fail "start waited for the command"
[[ ! -f "$TMP_DIR/slow/status" ]] || fail "status recorded before the command ended"
printf 'PASS: start returns while the command runs\n'

# A command still running past the timeout fails with 124 and shows what it
# has printed so far.
"$STEP" start "$TMP_DIR/hang" -- bash -c 'echo partial-output; sleep 4' >/dev/null
status="$(finish_status "$TMP_DIR/hang" 1)"
[[ "$status" == "124" ]] || fail "timeout: expected exit 124, got $status"
grep -q 'partial-output' "$TMP_DIR/out" || fail "timeout: partial output not shown"
grep -q 'still running after 1s' "$TMP_DIR/out" || fail "timeout: no timeout message"
printf 'PASS: a command past its timeout fails with 124\n'

# finish waits for the slow command and passes its output through.
status="$(finish_status "$TMP_DIR/slow" 30)"
[[ "$status" == "0" ]] || fail "success: expected exit 0, got $status"
grep -q 'slow-done' "$TMP_DIR/out" || fail "success: output not shown"
printf 'PASS: finish waits and passes on success\n'

# A failing command fails finish with the same status, output shown.
"$STEP" start "$TMP_DIR/red" -- bash -c 'echo FAIL-line-from-suite >&2; exit 3' >/dev/null
status="$(finish_status "$TMP_DIR/red" 30)"
[[ "$status" == "3" ]] || fail "failure: expected exit 3, got $status"
grep -q 'FAIL-line-from-suite' "$TMP_DIR/out" || fail "failure: stderr not shown"
printf 'PASS: a failing command fails finish with its status\n'

# A command that cannot be run is a failure, not a pass.
"$STEP" start "$TMP_DIR/missing" -- "$TMP_DIR/no-such-command" >/dev/null
status="$(finish_status "$TMP_DIR/missing" 30)"
[[ "$status" == "127" ]] || fail "missing command: expected exit 127, got $status"
printf 'PASS: a missing command fails finish\n'

# finish without a start fails.
status="$(finish_status "$TMP_DIR/never" 30)"
[[ "$status" == "1" ]] || fail "never started: expected exit 1, got $status"
grep -q 'nothing was started' "$TMP_DIR/out" || fail "never started: no message"
printf 'PASS: finish without start fails\n'

# A restart clears the previous run's status, so a stale green cannot leak.
"$STEP" start "$TMP_DIR/red" -- bash -c 'sleep 2' >/dev/null
[[ ! -f "$TMP_DIR/red/status" ]] || fail "restart kept the previous status"
printf 'PASS: start clears a previous status\n'

# Bad usage is refused.
status=0
"$STEP" start "$TMP_DIR/usage" true >/dev/null 2>&1 || status=$?
[[ "$status" == "64" ]] || fail "usage: start without -- should exit 64, got $status"
status=0
"$STEP" finish "$TMP_DIR/slow" soon >/dev/null 2>&1 || status=$?
[[ "$status" == "64" ]] || fail "usage: non-numeric timeout should exit 64, got $status"
printf 'PASS: bad usage exits 64\n'

