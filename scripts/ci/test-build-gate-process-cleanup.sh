#!/usr/bin/env bash
# Regression test: an interrupted forced-command payload cannot orphan its
# descendants, and ordinary command exit statuses still cross the wrapper.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GATE="$ROOT_DIR/scripts/mac/localvoxtral-build-gate.sh"
FIXTURE="$ROOT_DIR/scripts/ci/fixtures/build-gate-stubborn-tree.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-gate-process-test.XXXXXX")"
wrapper_pid=""
fixture_pid=""
stubborn_pid=""

cleanup() {
  if [[ -n "$wrapper_pid" ]]; then
    kill -TERM "$wrapper_pid" 2>/dev/null || true
    wait "$wrapper_pid" 2>/dev/null || true
  fi
  [[ -z "$fixture_pid" ]] || kill -KILL "$fixture_pid" 2>/dev/null || true
  [[ -z "$stubborn_pid" ]] || kill -KILL "$stubborn_pid" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

LOCALVOXTRAL_BUILD_GATE_SOURCE_ONLY=1
export LOCALVOXTRAL_BUILD_GATE_SOURCE_ONLY
# shellcheck source=../mac/localvoxtral-build-gate.sh
source "$GATE"

# In a subshell: the wrapper owns EXIT while it runs and clears it on return,
# which would take this script's cleanup trap with it.
if ( run_payload_with_cleanup 'exit 7' ); then
  fail "non-zero payload unexpectedly succeeded"
else
  status=$?
fi
[[ "$status" == "7" ]] || fail "payload exit status changed from 7 to $status"

# No wall-clock wait: reading the FIFO is the readiness handshake, and
# waiting for the wrapper means its EXIT cleanup has completed.
#
# The FIFO is held open read-write on fd 3 before the wrapper starts, so no
# open() blocks on either side. `read ... <"$pid_fifo"` blocked in open(),
# and CI's bash 3.2 neither sets SA_RESTART nor retries a redirection on
# EINTR; on macOS a sleep woken normally still returns EINTR when a signal
# is pending (xnu kern_synch.c, _sleep_continue). In the leader-exit case
# the wrapper exits right behind the fixture's write, so its SIGCHLD could
# land first: "line 83: .../normal-exit-pids: Interrupted system call".
# The read builtin retries read() on EINTR.
open_pid_fifo() {
  pid_fifo="$1"
  mkfifo "$pid_fifo"
  exec 3<>"$pid_fifo"
}

# Every process of the payload tree inherits fd 5, the write end of a FIFO
# the test reads on fd 6, and closes it when it exits. End-of-file on fd 6
# therefore means the whole tree is gone, however long a loaded runner takes
# to finish the KILL; the wrapper waits only for the leader, so one `ps` right
# after it returned could race the descendant (#713). A tree that outlives the
# deadline is a leak.
TREE_EXIT_DEADLINE_SECONDS="${LV_TEST_TREE_EXIT_DEADLINE_SECONDS:-20}"
[[ "$TREE_EXIT_DEADLINE_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || fail "LV_TEST_TREE_EXIT_DEADLINE_SECONDS must be a positive integer"

# start_wrapper <fifo name> <fixture arg>...: runs the fixture under the gate
# in the background and returns once it has reported its pids.
start_wrapper() {
  local name="$1"
  shift
  open_pid_fifo "$TMP_DIR/$name-pids"
  mkfifo "$TMP_DIR/$name-tree"
  # fd 4 holds the tree FIFO open for both ends, so neither open below blocks.
  exec 4<>"$TMP_DIR/$name-tree"
  printf -v payload ' %q' "$FIXTURE" "$pid_fifo" "$@"
  (
    LOCALVOXTRAL_GATE_TERM_POLLS=0 run_payload_with_cleanup "$payload"
  ) 4<&- 5>"$TMP_DIR/$name-tree" &
  wrapper_pid=$!
  exec 6<"$TMP_DIR/$name-tree"
  read -r fixture_pid stubborn_pid <&3
  exec 3<&- 4<&-
}

# expect_tree_exit <what>: fails unless every holder of fd 5 exits in time.
expect_tree_exit() {
  local line status=0
  read -r -t "$TREE_EXIT_DEADLINE_SECONDS" line <&6 || status=$?
  exec 6<&-
  [[ "$status" == "1" ]] && return 0
  fail "$1: payload process $fixture_pid or descendant $stubborn_pid" \
    "survived gate teardown for ${TREE_EXIT_DEADLINE_SECONDS}s (read status $status)"
}

start_wrapper signalled
kill -TERM "$wrapper_pid"
if wait "$wrapper_pid"; then
  fail "signal-interrupted payload unexpectedly succeeded"
else
  status=$?
fi
[[ "$status" == "143" ]] || fail "TERM exit status changed from 143 to $status"
wrapper_pid=""
expect_tree_exit "signalled wrapper"
fixture_pid=""
stubborn_pid=""

start_wrapper normal-exit exit-leader
if ! wait "$wrapper_pid"; then
  fail "leader-exit payload should preserve its zero exit status"
fi
wrapper_pid=""
expect_tree_exit "leader-exit wrapper"
fixture_pid=""
stubborn_pid=""

printf 'PASS: gate preserves status and drains signalled or leader-exited groups\n'
