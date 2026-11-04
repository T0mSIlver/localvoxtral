#!/usr/bin/env bash
# Regression tests for reclaiming build-host disk on demand: the gate's
# `remove work/localvoxtral-<id>` deletes one idle work dir and keeps a dir in
# use, a symlink and EvalRecordings; `gc --idle <hours>` reclaims by hours;
# remote-build.sh's `remove` and `gc --idle` send exactly those commands.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GATE="$ROOT_DIR/scripts/mac/localvoxtral-build-gate.sh"
REMOTE_BUILD="$ROOT_DIR/scripts/remote-build.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-gate-remove-test.XXXXXX")"
FAKE_HOME="$TMP_DIR/home"
WORK="$FAKE_HOME/work"
mkdir -p "$WORK" "$TMP_DIR/bin"
gate_pid=""

cleanup() {
  [[ -z "$gate_pid" ]] || kill -KILL "$gate_pid" 2>/dev/null || true
  [[ ! -f "$TMP_DIR/payload.pid" ]] || kill -KILL "$(cat "$TMP_DIR/payload.pid")" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do rm -rf "$TMP_DIR" 2>/dev/null && break; /bin/sleep 0.1; done
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_gate() {
  HOME="$FAKE_HOME" PATH="$TMP_DIR/bin:$PATH" SSH_ORIGINAL_COMMAND="$1" bash "$GATE"
}

expect_denied() {
  local status=0
  run_gate "$1" >/dev/null 2>&1 || status=$?
  [[ "$status" == 126 ]] || fail "'$1' was not denied (exit $status)"
}

# --- remove ---------------------------------------------------------------------

mkdir -p "$WORK/localvoxtral-idle/.build/release"
echo artifact >"$WORK/localvoxtral-idle/.build/release/product"
out="$(run_gate 'remove work/localvoxtral-idle')"
grep -q 'remove localvoxtral-idle: deleted' <<<"$out" || fail "an idle dir was not deleted: $out"
[[ ! -e "$WORK/localvoxtral-idle" ]] || fail "the idle dir is still there"

expect_denied 'remove work/../etc'
expect_denied 'remove /etc'
expect_denied 'remove work/other-dir'
expect_denied 'remove work/localvoxtral-a work/localvoxtral-b'

mkdir -p "$WORK/localvoxtral-recordings/EvalRecordings" "$WORK/localvoxtral-recordings/.build"
echo wav >"$WORK/localvoxtral-recordings/EvalRecordings/owner.wav"
echo artifact >"$WORK/localvoxtral-recordings/.build/product"
out="$(run_gate 'remove work/localvoxtral-recordings')"
grep -q 'pruned, EvalRecordings kept' <<<"$out" || fail "a dir with recordings was not pruned: $out"
[[ -f "$WORK/localvoxtral-recordings/EvalRecordings/owner.wav" ]] || fail "remove deleted EvalRecordings"
[[ ! -e "$WORK/localvoxtral-recordings/.build" ]] || fail "remove left the build tree"

mkdir -p "$TMP_DIR/outside"
echo keep >"$TMP_DIR/outside/file"
ln -s "$TMP_DIR/outside" "$WORK/localvoxtral-link"
status=0
out="$(run_gate 'remove work/localvoxtral-link')" || status=$?
grep -q 'a symlink — kept' <<<"$out" || fail "a symlinked work dir was not kept: $out"
[[ -f "$TMP_DIR/outside/file" ]] || fail "remove followed a symlink out of ~/work"

out="$(run_gate 'remove work/localvoxtral-missing')"
grep -q 'no such work dir' <<<"$out" || fail "a missing dir was not reported: $out"

# A dir with a payload still running is kept.
cat >"$TMP_DIR/bin/swift" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$LV_TEST_PAYLOAD_PID_FILE"
exec sleep 300
STUB
chmod +x "$TMP_DIR/bin/swift"
mkdir -p "$WORK/localvoxtral-busy"
HOME="$FAKE_HOME" PATH="$TMP_DIR/bin:$PATH" LV_TEST_PAYLOAD_PID_FILE="$TMP_DIR/payload.pid" \
  LOCALVOXTRAL_GATE_SESSION_PID="$$" \
  SSH_ORIGINAL_COMMAND='cd work/localvoxtral-busy && swift build --build-system native' \
  bash "$GATE" >/dev/null 2>&1 &
gate_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$TMP_DIR/payload.pid" && -n "$(ls "$FAKE_HOME/.lv-gate-payloads/localvoxtral-busy" 2>/dev/null)" ]] && break
  /bin/sleep 0.1
done
[[ -s "$TMP_DIR/payload.pid" ]] || fail "the busy dir's payload never started"
status=0
out="$(run_gate 'remove work/localvoxtral-busy')" || status=$?
(( status != 0 )) || fail "removing a busy dir reported success"
grep -q -E 'still running in it — kept|has live processes — kept' <<<"$out" || fail "a busy dir was not kept: $out"
[[ -d "$WORK/localvoxtral-busy" ]] || fail "remove deleted a dir with a running payload"
kill -KILL "$(cat "$TMP_DIR/payload.pid")" 2>/dev/null || true
wait "$gate_pid" 2>/dev/null || true
gate_pid=""
rm -f "$TMP_DIR/payload.pid"

# --- gc --idle ------------------------------------------------------------------

two_hours_ago="$(date -d '-2 hours' +%Y%m%d%H%M.%S 2>/dev/null || date -v-2H +%Y%m%d%H%M.%S)"
mkdir -p "$WORK/localvoxtral-hours-old" "$WORK/localvoxtral-fresh"
echo old >"$WORK/localvoxtral-hours-old/file"
echo new >"$WORK/localvoxtral-fresh/file"
find "$WORK/localvoxtral-hours-old" -exec touch -t "$two_hours_ago" {} +
out="$(run_gate 'gc --idle 1')"
[[ ! -e "$WORK/localvoxtral-hours-old" ]] || fail "gc --idle 1 kept a dir idle for 2 h: $out"
[[ -d "$WORK/localvoxtral-fresh" ]] || fail "gc --idle 1 deleted a fresh dir: $out"
grep -q 'unused >= 1h — deleted' <<<"$out" || fail "gc --idle did not say its window: $out"
expect_denied 'gc --idle 0'
expect_denied 'gc --idle 721'
expect_denied 'gc --idle abc'
expect_denied 'gc --idle 1 2'

# --- remote-build.sh sends exactly these commands -------------------------------

cat >"$TMP_DIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do shift; done
printf '%s\n' "$1" >>"$LV_TEST_SSH_LOG"
STUB
chmod +x "$TMP_DIR/bin/ssh"
ssh_log="$TMP_DIR/ssh.log"
rb_env=(
  "PATH=$TMP_DIR/bin:$PATH"
  "LV_BUILD_HOST=fake-host"
  "LV_BUILD_DIR=work/localvoxtral-remove-regression"
  "LV_TEST_SSH_LOG=$ssh_log"
  "LOCALVOXTRAL_REMOTE_LOG=$TMP_DIR/remote-build.log"
)
env "${rb_env[@]}" "$REMOTE_BUILD" remove >/dev/null 2>&1 || fail "remote-build.sh remove failed"
env "${rb_env[@]}" "$REMOTE_BUILD" remove work/localvoxtral-other >/dev/null 2>&1 || fail "remove of a named dir failed"
env "${rb_env[@]}" "$REMOTE_BUILD" gc --idle 6 >/dev/null 2>&1 || fail "gc --idle 6 failed"
[[ "$(cat "$ssh_log")" == $'remove work/localvoxtral-remove-regression\nremove work/localvoxtral-other\ngc --idle 6' ]] \
  || fail "remote-build.sh sent: $(cat "$ssh_log")"
: >"$ssh_log"
! env "${rb_env[@]}" "$REMOTE_BUILD" remove /etc >/dev/null 2>&1 || fail "remove /etc was not refused"
! env "${rb_env[@]}" "$REMOTE_BUILD" gc --idle >/dev/null 2>&1 || fail "gc --idle with no hours was not refused"
[[ ! -s "$ssh_log" ]] || fail "a refused command still reached the host: $(cat "$ssh_log")"

printf 'PASS: remove deletes one idle work dir and keeps busy ones, symlinks and recordings; gc --idle reclaims by hours\n'
