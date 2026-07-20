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

# On timeout, the watchdog samples the wedged group into the log BEFORE
# killing it (2026-07-20 hang forensics). `sample` is stubbed on PATH so the
# test is deterministic and runs on non-macOS too; the stub proves the
# sampled pid belongs to the command's group and its output lands in the log.
pid_fifo="$TMP_DIR/forensics-pids"
timeout_fifo="$TMP_DIR/forensics-trigger"
mkfifo "$pid_fifo" "$timeout_fifo"
mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/sample" <<'STUB'
#!/usr/bin/env bash
echo "stub-sample-of-pid-$1"
STUB
chmod +x "$TMP_DIR/bin/sample"
PATH="$TMP_DIR/bin:$PATH" \
LOCALVOXTRAL_SUPERVISOR_TIMEOUT_FIFO="$timeout_fifo" \
LOCALVOXTRAL_SUPERVISOR_TERM_POLLS=0 \
  "$SUPERVISOR" 999 "$TMP_DIR/forensics.log" -- "$FIXTURE" "$pid_fifo" &
supervisor_pid=$!
read -r fixture_pid stubborn_pid <"$pid_fifo"
printf 'fire\n' >"$timeout_fifo"
if wait "$supervisor_pid"; then
  fail "forensics-run command unexpectedly succeeded"
else
  status=$?
fi
supervisor_pid=""
[[ "$status" == "124" ]] || fail "forensics run: timeout status changed from 124 to $status"
grep -q 'supervisor timeout forensics' "$TMP_DIR/forensics.log" \
  || fail "timeout log is missing the forensics marker"
grep -qE "stub-sample-of-pid-($fixture_pid|$stubborn_pid)" "$TMP_DIR/forensics.log" \
  || fail "no group member was sampled into the log"
is_live_non_zombie "$fixture_pid" && fail "forensics run: leader survived"
is_live_non_zombie "$stubborn_pid" && fail "forensics run: descendant survived"
fixture_pid=""
stubborn_pid=""

# A sampler that hangs must be killed at the cap and never postpone the
# group kill (PR #160 review: an unbounded `sample` on a badly wedged task
# would recreate the blind hang the forensics exist to diagnose).
pid_fifo="$TMP_DIR/hung-sampler-pids"
timeout_fifo="$TMP_DIR/hung-sampler-trigger"
mkfifo "$pid_fifo" "$timeout_fifo"
cat >"$TMP_DIR/bin/sample" <<'STUB'
#!/usr/bin/env bash
echo "stub-sample-hanging-on-pid-$1"
exec sleep 300
STUB
chmod +x "$TMP_DIR/bin/sample"
PATH="$TMP_DIR/bin:$PATH" \
LOCALVOXTRAL_SUPERVISOR_TIMEOUT_FIFO="$timeout_fifo" \
LOCALVOXTRAL_SUPERVISOR_TERM_POLLS=0 \
LOCALVOXTRAL_SUPERVISOR_SAMPLE_POLLS=3 \
  "$SUPERVISOR" 999 "$TMP_DIR/hung-sampler.log" -- "$FIXTURE" "$pid_fifo" &
supervisor_pid=$!
read -r fixture_pid stubborn_pid <"$pid_fifo"
printf 'fire\n' >"$timeout_fifo"
if wait "$supervisor_pid"; then
  fail "hung-sampler run unexpectedly succeeded"
else
  status=$?
fi
supervisor_pid=""
[[ "$status" == "124" ]] || fail "hung-sampler run: timeout status changed from 124 to $status"
grep -q 'killed at the 300 ms cap' "$TMP_DIR/hung-sampler.log" \
  || fail "hung sampler was not killed at the cap"
is_live_non_zombie "$fixture_pid" && fail "hung-sampler run: leader survived"
is_live_non_zombie "$stubborn_pid" && fail "hung-sampler run: descendant survived"
fixture_pid=""
stubborn_pid=""

# A command that finishes naturally while forensics are running must keep
# its real exit status — the timeout marker is only written if the group is
# still alive after sampling (PR #160 review: the marker used to be written
# before sampling, widening the 124-mislabel race to seconds).
timeout_fifo="$TMP_DIR/natural-finish-trigger"
mkfifo "$timeout_fifo"
flag_file="$TMP_DIR/natural-finish-flag"
cat >"$TMP_DIR/bin/sample" <<STUB
#!/usr/bin/env bash
echo "stub-sample-releasing-command"
touch "$flag_file"
sleep 1
STUB
chmod +x "$TMP_DIR/bin/sample"
PATH="$TMP_DIR/bin:$PATH" \
LOCALVOXTRAL_SUPERVISOR_TIMEOUT_FIFO="$timeout_fifo" \
LOCALVOXTRAL_SUPERVISOR_TERM_POLLS=0 \
LOCALVOXTRAL_SUPERVISOR_SAMPLE_POLLS=50 \
  "$SUPERVISOR" 999 "$TMP_DIR/natural-finish.log" -- \
  /bin/bash -c "while [[ ! -f '$flag_file' ]]; do sleep 0.05; done; echo finished-naturally; exit 0" &
supervisor_pid=$!
printf 'fire\n' >"$timeout_fifo"
wait "$supervisor_pid" || fail "natural finish during forensics was mislabeled as status $?"
supervisor_pid=""
grep -q '^finished-naturally$' "$TMP_DIR/natural-finish.log" \
  || fail "natural-finish output missing from the log"

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
