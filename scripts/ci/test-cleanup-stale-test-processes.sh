#!/usr/bin/env bash
# Deterministic scope regression tests for cleanup-stale-test-processes.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/ci/cleanup-stale-test-processes.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-stale-selector.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
fixture_pid=""
sibling_pid=""

cleanup() {
  if [[ -n "$fixture_pid" ]]; then
    kill -KILL "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  if [[ -n "$sibling_pid" ]]; then
    kill -KILL "$sibling_pid" 2>/dev/null || true
    wait "$sibling_pid" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

workspace="$TMP_DIR/actions/localvoxtral"
mkdir -p "$workspace/subdir" "$TMP_DIR/actions/localvoxtral-other"

fixture="$TMP_DIR/processes.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  101 501 S xctest start-101 "$workspace/.build/tests.xctest" \
  102 501 S /usr/bin/swift-package start-102 "$workspace/subdir" \
  103 502 S xctest start-103 "$workspace" \
  104 501 S xctest start-104 "$TMP_DIR/actions/localvoxtral-other" \
  105 501 S bash start-105 "$workspace" \
  106 501 Z xctest start-106 "$workspace" \
  998 501 S xctest start-998 "$workspace" \
  999 501 S xctest start-999 "$workspace" \
  not-a-pid 501 S xctest start-bad "$workspace" \
  107 501 S swiftpm-testing-helper start-107 "$TMP_DIR/actions" \
  >"$fixture"

actual="$TMP_DIR/actual.tsv"
"$SCRIPT" --select "$workspace" 501 "998 999" <"$fixture" >"$actual"

expected="$TMP_DIR/expected.tsv"
printf '101\txctest\tstart-101\n102\tswift-package\tstart-102\n' >"$expected"

cmp -s "$expected" "$actual" || fail "selector crossed a user/path/state/name boundary:
expected:
$(cat "$expected")
actual:
$(cat "$actual")"

printf 'PASS: cleanup selection is user, state, name, ancestor, and workspace scoped\n'

if "$SCRIPT" >/dev/null 2>&1; then
  fail "cleanup without an explicit workspace root unexpectedly succeeded"
fi

# Exercise the production ps+lsof+TERM path with a controlled executable whose
# process name is exactly xctest. Do not copy a signed macOS system binary under
# a new name: AMFI kills that with SIGKILL before the test can inspect it.
# The fixture blocks in pause(); the test synchronizes through its PID and never
# waits on elapsed time.
cat >"$TMP_DIR/xctest.c" <<'C'
#include <signal.h>
#include <unistd.h>
int main(void) {
  for (;;) pause();
}
C
cc "$TMP_DIR/xctest.c" -o "$TMP_DIR/xctest"
(
  cd "$workspace"
  exec "$TMP_DIR/xctest" 300
) &
fixture_pid=$!
(
  cd "$TMP_DIR/actions/localvoxtral-other"
  exec "$TMP_DIR/xctest" 300
) &
sibling_pid=$!
fixture_name="$(ps -o ucomm= -p "$fixture_pid" | tr -d '[:space:]')"
[[ "${fixture_name##*/}" == "xctest" ]] \
  || fail "fixture process name is '$fixture_name', expected xctest"

LOCALVOXTRAL_STALE_TEST_TERM_POLLS=0 "$SCRIPT" "$workspace"
state="$(ps -o state= -p "$fixture_pid" 2>/dev/null | tr -d '[:space:]' || true)"
[[ -z "$state" || "$state" == Z* ]] \
  || fail "production cleanup left fixture pid $fixture_pid alive in state $state"
sibling_state="$(ps -o state= -p "$sibling_pid" 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$sibling_state" && "$sibling_state" != Z* ]] \
  || fail "production cleanup crossed into the sibling workspace"
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=""
kill -TERM "$sibling_pid" 2>/dev/null || true
wait "$sibling_pid" 2>/dev/null || true
sibling_pid=""

printf 'PASS: production cleanup terminates its xctest and preserves a sibling workspace\n'
