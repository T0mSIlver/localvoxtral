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

# xctest under the gate writes its log unbuffered (#1387).
unbuffered="$( run_payload_with_cleanup 'printf %s "$NSUnbufferedIO"' )"
[[ "$unbuffered" == "YES" ]] || fail "payload saw NSUnbufferedIO='$unbuffered', not YES"

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

# Every process of the payload tree, and the gate's session watcher, inherits
# fd 5, the write end of a FIFO the test reads on fd 6, and closes it when it
# exits. End-of-file on fd 6
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
# Not `read -t`: bash 3.2 returns 1 on a timeout, the status of end-of-file,
# so a leak would pass.
expect_tree_exit() {
  local status=0
  perl -e '$SIG{ALRM} = sub { exit 2 }; alarm shift;
    1 while sysread STDIN, my $buf, 512; exit 0' \
    "$TREE_EXIT_DEADLINE_SECONDS" <&6 || status=$?
  exec 6<&-
  [[ "$status" == "0" ]] && return 0
  fail "$1: payload process $fixture_pid, descendant $stubborn_pid or the session watcher" \
    "held fd 5 past gate teardown for ${TREE_EXIT_DEADLINE_SECONDS}s (reader status $status)"
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

# A signal handled between the session watcher's fork and `$!` exited before
# the gate knew the watcher's pid, so its cleanup left the watcher running,
# holding fd 5 (LVX-107). The hook pauses the gate right there until the
# test has sent TERM: the old order fails, with the watcher as the holder.
mkfifo "$TMP_DIR/fork-reached" "$TMP_DIR/fork-release"
exec 7<>"$TMP_DIR/fork-reached" 8<>"$TMP_DIR/fork-release"
gate_after_watcher_fork() {
  printf 'forked\n' >&7
  read -r _ <&8 || true
}
LOCALVOXTRAL_GATE_SESSION_PID=$$ start_wrapper signal-at-watcher-fork
read -r _ <&7
kill -TERM "$wrapper_pid"
printf 'go\n' >&8
if wait "$wrapper_pid"; then
  fail "payload signalled at the watcher's fork unexpectedly succeeded"
else
  status=$?
fi
[[ "$status" == "143" ]] || fail "TERM at the watcher's fork: exit status $status, not 143"
wrapper_pid=""
expect_tree_exit "TERM between the watcher's fork and its pid"
fixture_pid=""
stubborn_pid=""
exec 7<&- 8<&-
gate_after_watcher_fork() { :; }

printf 'PASS: gate preserves status and drains signalled or leader-exited groups, and stops its watcher\n'
