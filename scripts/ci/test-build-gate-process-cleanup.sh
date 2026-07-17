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

if run_payload_with_cleanup 'exit 7'; then
  fail "non-zero payload unexpectedly succeeded"
else
  status=$?
fi
[[ "$status" == "7" ]] || fail "payload exit status changed from 7 to $status"

pid_fifo="$TMP_DIR/pids"
mkfifo "$pid_fifo"
printf -v payload '%q %q' "$FIXTURE" "$pid_fifo"

# No wall-clock wait: reading the FIFO is the readiness handshake, and
# waiting for the wrapper means its EXIT cleanup has completed.
(
  LOCALVOXTRAL_GATE_TERM_POLLS=0 run_payload_with_cleanup "$payload"
) &
wrapper_pid=$!
read -r fixture_pid stubborn_pid <"$pid_fifo"

kill -TERM "$wrapper_pid"
if wait "$wrapper_pid"; then
  fail "signal-interrupted payload unexpectedly succeeded"
else
  status=$?
fi
[[ "$status" == "143" ]] || fail "TERM exit status changed from 143 to $status"
wrapper_pid=""

is_live_non_zombie() {
  local pid="$1" state
  state="$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$state" && "$state" != Z* ]]
}

is_live_non_zombie "$fixture_pid" \
  && fail "payload process $fixture_pid survived gate teardown"
is_live_non_zombie "$stubborn_pid" \
  && fail "payload descendant $stubborn_pid survived gate teardown"
fixture_pid=""
stubborn_pid=""

pid_fifo="$TMP_DIR/normal-exit-pids"
mkfifo "$pid_fifo"
printf -v payload '%q %q %q' "$FIXTURE" "$pid_fifo" exit-leader
(
  LOCALVOXTRAL_GATE_TERM_POLLS=0 run_payload_with_cleanup "$payload"
) &
wrapper_pid=$!
read -r fixture_pid stubborn_pid <"$pid_fifo"
if ! wait "$wrapper_pid"; then
  fail "leader-exit payload should preserve its zero exit status"
fi
wrapper_pid=""
is_live_non_zombie "$stubborn_pid" \
  && fail "descendant $stubborn_pid survived after its leader exited"
fixture_pid=""
stubborn_pid=""

printf 'PASS: gate preserves status and drains signalled or leader-exited groups\n'
