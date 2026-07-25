#!/usr/bin/env bash
# Regression tests for runner-node-resign.sh's `run` verb: signing decisions,
# service stop/start ordering, busy-worker refusal, dry-run inertness, and
# the restart-even-on-sign-failure guarantee. codesign/pgrep are PATH stubs
# and svc.sh is a recording fake — no real signing or launchd, runs anywhere.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/mac/runner-node-resign.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-runner-node-resign-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  [[ -f "$TMP_DIR/calls.log" ]] && sed 's/^/  calls: /' "$TMP_DIR/calls.log" >&2
  exit 1
}

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"

# codesign stub: display mode reports our identity iff a "<file>.oursig"
# marker exists; sign mode creates the marker (or fails under
# STUB_CODESIGN_FAIL). Every invocation is recorded.
cat >"$STUB_BIN/codesign" <<'STUB'
#!/usr/bin/env bash
printf 'codesign %s\n' "$*" >>"$CALLS_LOG"
case "$1" in
  -dvv)
    target="$2"
    if [[ -f "$target.oursig" ]]; then
      cat "$target.oursig"
    else
      printf 'Identifier=node\nSignature=adhoc\n'
    fi
    ;;
  --force)
    if [[ -n "${STUB_CODESIGN_FAIL:-}" ]]; then exit 1; fi
    target="${!#}"
    # Record what a real signature would answer for the display probe.
    # argv: --force --sign <identity> --identifier <identifier> <file>
    printf 'Identifier=%s\nAuthority=%s\n' "$5" "$3" >"$target.oursig"
    ;;
  *)
    exit 64
    ;;
esac
STUB
chmod +x "$STUB_BIN/codesign"

# pgrep stub: "busy" (exit 0) for the first $STUB_PGREP_BUSY_COUNT calls,
# then idle (exit 1). Call count persists in a file across invocations.
cat >"$STUB_BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
printf 'pgrep %s\n' "$*" >>"$CALLS_LOG"
count_file="$CALLS_LOG.pgrep-count"
n="$(cat "$count_file" 2>/dev/null || echo 0)"
n=$((n + 1))
printf '%s\n' "$n" >"$count_file"
if [[ -n "${STUB_PGREP_BUSY_COUNT:-}" ]] && [[ "$n" -le "$STUB_PGREP_BUSY_COUNT" ]]; then
  echo 12345
  exit 0
fi
exit 1
STUB
chmod +x "$STUB_BIN/pgrep"

make_runner() {
  local dir="$TMP_DIR/runner"
  rm -rf "$dir"
  mkdir -p "$dir/externals/node20/bin" "$dir/externals/node24/bin" "$dir/bin"
  printf 'fake-node\n' >"$dir/externals/node20/bin/node"
  printf 'fake-node\n' >"$dir/externals/node24/bin/node"
  cat >"$dir/svc.sh" <<'SVC'
#!/usr/bin/env bash
printf 'svc.sh %s\n' "$*" >>"$CALLS_LOG"
if [[ -n "${STUB_SVC_FAIL_START:-}" && "$1" == "start" ]]; then exit 1; fi
exit 0
SVC
  chmod +x "$dir/svc.sh"
  : >"$TMP_DIR/calls.log"
  rm -f "$TMP_DIR/calls.log.pgrep-count"
  printf '%s\n' "$dir"
}

# run_script <expected-exit> [args/env...] — env pairs (VAR=val) then args.
run_script() {
  local expected="$1"
  shift
  local envs=() args=()
  local a
  for a in "$@"; do
    case "$a" in
      *=*) envs+=("$a") ;;
      *) args+=("$a") ;;
    esac
  done
  local status=0
  env CALLS_LOG="$TMP_DIR/calls.log" \
    PATH="$STUB_BIN:$PATH" \
    LV_RUNNER_DIR="$RUNNER" \
    LV_RESIGN_IDLE_POLL_SECS=0 \
    LV_RESIGN_IDLE_TIMEOUT_SECS=3 \
    LV_RESIGN_SETTLE_SECS=0 \
    ${envs[@]+"${envs[@]}"} \
    "$SCRIPT" run ${args[@]+"${args[@]}"} >"$TMP_DIR/out.log" 2>&1 \
    || status=$?
  [[ "$status" -eq "$expected" ]] \
    || { cat "$TMP_DIR/out.log" >&2; fail "expected exit $expected, got $status"; }
}

calls() { cat "$TMP_DIR/calls.log"; }

# --- fresh runner: both nodes unsigned -> stop, sign both, start ----------
RUNNER="$(make_runner)"
run_script 0
calls | grep -q 'svc.sh stop' || fail "unsigned pass: service was not stopped"
[[ "$(calls | grep -c -- '--force --sign localvoxtral-dev --identifier com.localvoxtral.runner-node')" -eq 2 ]] \
  || fail "unsigned pass: expected exactly 2 sign invocations with identity+identifier"
calls | grep -q 'svc.sh start' || fail "unsigned pass: service was not restarted"
stop_line="$(calls | grep -n 'svc.sh stop' | cut -d: -f1 | head -1)"
first_sign="$(calls | grep -n -- '--force' | cut -d: -f1 | head -1)"
start_line="$(calls | grep -n 'svc.sh start' | cut -d: -f1 | head -1)"
[[ "$stop_line" -lt "$first_sign" && "$first_sign" -lt "$start_line" ]] \
  || fail "unsigned pass: expected stop < sign < start ordering"
echo "PASS: unsigned nodes are signed between a service stop and start"

# --- second pass: everything signed -> pure no-op -------------------------
: >"$TMP_DIR/calls.log"
run_script 0
calls | grep -q 'svc.sh' && fail "signed pass: touched the service"
calls | grep -q -- '--force' && fail "signed pass: re-signed a signed node"
grep -q 'nothing to do' "$TMP_DIR/out.log" || fail "signed pass: missing no-op message"
echo "PASS: fully-signed state is a no-op"

# --- partial: only the unsigned node gets signed --------------------------
rm "$RUNNER/externals/node24/bin/node.oursig"
: >"$TMP_DIR/calls.log"
run_script 0
[[ "$(calls | grep -c -- '--force')" -eq 1 ]] || fail "partial pass: expected exactly 1 sign"
calls | grep -- '--force' | grep -q 'node24' || fail "partial pass: signed the wrong node"
echo "PASS: partial invalidation signs only the unsigned node"

# --- dry-run: reports, changes nothing ------------------------------------
RUNNER="$(make_runner)"
run_script 0 --dry-run
calls | grep -qE 'svc.sh|--force' && fail "dry-run: performed real actions"
grep -q 'would sign' "$TMP_DIR/out.log" || fail "dry-run: missing would-sign report"
echo "PASS: dry-run is inert"

# --- busy worker: refuse to touch anything, nonzero exit ------------------
RUNNER="$(make_runner)"
run_script 1 STUB_PGREP_BUSY_COUNT=999
calls | grep -qE 'svc.sh|--force' && fail "busy: touched service or signed under a live job"
grep -q 'still busy' "$TMP_DIR/out.log" || fail "busy: missing busy-timeout message"
echo "PASS: live runner job blocks the pass without side effects"

# --- busy then idle: waits, then proceeds ---------------------------------
RUNNER="$(make_runner)"
run_script 0 STUB_PGREP_BUSY_COUNT=2
[[ "$(calls | grep -c -- '--force')" -eq 2 ]] || fail "busy-then-idle: did not sign after wait"
echo "PASS: pass proceeds once the worker drains"

# --- sign failure: service still restarted, nonzero exit ------------------
RUNNER="$(make_runner)"
run_script 1 STUB_CODESIGN_FAIL=1
calls | grep -q 'svc.sh start' || fail "sign failure: service left stopped"
grep -q 'failed to sign' "$TMP_DIR/out.log" || fail "sign failure: missing failure message"
echo "PASS: sign failure never leaves the runner service down"

# --- missing runner dir: clear error --------------------------------------
RUNNER="$TMP_DIR/nonexistent"
run_script 1
grep -q 'externals dir not found' "$TMP_DIR/out.log" || fail "missing dir: unclear error"
echo "PASS: missing runner dir fails loudly"

echo "runner-node-resign tests passed"
