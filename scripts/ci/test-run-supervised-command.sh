#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SUPERVISOR="$ROOT_DIR/scripts/ci/run-supervised-command.sh"
FIXTURE="$ROOT_DIR/scripts/ci/fixtures/build-gate-stubborn-tree.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-supervisor-test.XXXXXX")"
supervisor_pid=""
fixture_pid=""
stubborn_pid=""
sibling_pid=""

cleanup() {
  [[ -z "$supervisor_pid" ]] || kill -TERM "$supervisor_pid" 2>/dev/null || true
  [[ -z "$supervisor_pid" ]] || wait "$supervisor_pid" 2>/dev/null || true
  [[ -z "$fixture_pid" ]] || kill -KILL "$fixture_pid" 2>/dev/null || true
  [[ -z "$stubborn_pid" ]] || kill -KILL "$stubborn_pid" 2>/dev/null || true
  [[ -z "$sibling_pid" ]] || kill -KILL "$sibling_pid" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

is_live_non_zombie() {
  local pid="$1" state
  state="$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$state" && "$state" != Z* ]]
}

success_log="$TMP_DIR/success.log"
"$SUPERVISOR" 30 "$success_log" -- /bin/bash -c 'echo supervised-output'
[[ "$(cat "$success_log")" == "supervised-output" ]] || fail "success output was not captured"

failure_log="$TMP_DIR/failure.log"
if "$SUPERVISOR" 30 "$failure_log" -- /bin/bash -c 'echo failed-output; exit 7'; then
  fail "non-zero command unexpectedly succeeded"
else
  status=$?
fi
[[ "$status" == "7" ]] || fail "exit status changed from 7 to $status"
grep -q '^failed-output$' "$failure_log" || fail "failure output was not captured"

# A FIFO triggers the timeout path deterministically; no wall-clock polling.
pid_fifo="$TMP_DIR/timeout-pids"
timeout_fifo="$TMP_DIR/timeout-trigger"
mkfifo "$pid_fifo" "$timeout_fifo"
LOCALVOXTRAL_SUPERVISOR_TIMEOUT_FIFO="$timeout_fifo" \
LOCALVOXTRAL_SUPERVISOR_TERM_POLLS=0 \
  "$SUPERVISOR" 999 "$TMP_DIR/timeout.log" -- "$FIXTURE" "$pid_fifo" &
supervisor_pid=$!
read -r fixture_pid stubborn_pid <"$pid_fifo"
/bin/bash -c 'exec sleep 300' &
sibling_pid=$!
printf 'fire\n' >"$timeout_fifo"
if wait "$supervisor_pid"; then
  fail "timed-out command unexpectedly succeeded"
else
  status=$?
fi
supervisor_pid=""
[[ "$status" == "124" ]] || fail "timeout status changed from 124 to $status"
is_live_non_zombie "$fixture_pid" && fail "timed-out leader survived"
is_live_non_zombie "$stubborn_pid" && fail "timed-out descendant survived"
is_live_non_zombie "$sibling_pid" || fail "unrelated sibling was terminated"
fixture_pid=""
stubborn_pid=""

# If the leader exits normally, the wrapper must still drain its descendant.
pid_fifo="$TMP_DIR/leader-exit-pids"
mkfifo "$pid_fifo"
LOCALVOXTRAL_SUPERVISOR_TERM_POLLS=0 \
  "$SUPERVISOR" 30 "$TMP_DIR/leader-exit.log" -- "$FIXTURE" "$pid_fifo" exit-leader &
supervisor_pid=$!
read -r fixture_pid stubborn_pid <"$pid_fifo"
wait "$supervisor_pid" || fail "leader-exit command should preserve status zero"
supervisor_pid=""
is_live_non_zombie "$stubborn_pid" && fail "descendant survived its leader"
fixture_pid=""
stubborn_pid=""

# Signal cancellation preserves the conventional status and drains the tree.
pid_fifo="$TMP_DIR/signal-pids"
mkfifo "$pid_fifo"
LOCALVOXTRAL_SUPERVISOR_TERM_POLLS=0 \
  "$SUPERVISOR" 300 "$TMP_DIR/signal.log" -- "$FIXTURE" "$pid_fifo" &
supervisor_pid=$!
read -r fixture_pid stubborn_pid <"$pid_fifo"
kill -TERM "$supervisor_pid"
if wait "$supervisor_pid"; then
  fail "signal-cancelled supervisor unexpectedly succeeded"
else
  status=$?
fi
supervisor_pid=""
[[ "$status" == "143" ]] || fail "TERM status changed from 143 to $status"
is_live_non_zombie "$fixture_pid" && fail "signal-cancelled leader survived"
is_live_non_zombie "$stubborn_pid" && fail "signal-cancelled descendant survived"
fixture_pid=""
stubborn_pid=""

printf 'PASS: supervisor captures output, preserves status, and drains exact groups\n'
