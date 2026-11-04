#!/usr/bin/env bash
# Regression test: a payload dies with its connection. When the ssh session
# that started it ends (the client killed or dropped), the gate ends the
# payload's process group; `reap` from a later session ends a group whose
# session never ended; and a remote-build.sh whose ssh client is killed mid-run
# leaves no payload running and releases its build host lock (2026-11-04: an
# orphaned package build kept an 8 GB Mac loaded for 40 minutes).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GATE="$ROOT_DIR/scripts/mac/localvoxtral-build-gate.sh"
REMOTE_BUILD="$ROOT_DIR/scripts/remote-build.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-gate-session-test.XXXXXX")"
FAKE_HOME="$TMP_DIR/home"
mkdir -p "$FAKE_HOME/work" "$TMP_DIR/bin"
spawned=()

cleanup() {
  local pid
  for pid in ${spawned[@]+"${spawned[@]}"}; do kill -KILL "$pid" 2>/dev/null || true; done
  [[ ! -f "$TMP_DIR/payload.pid" ]] || kill -KILL "$(cat "$TMP_DIR/payload.pid")" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do rm -rf "$TMP_DIR" 2>/dev/null && break; /bin/sleep 0.1; done
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# A build that runs until it is killed and says its pid first.
cat >"$TMP_DIR/bin/swift" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$LV_TEST_PAYLOAD_PID_FILE"
exec sleep 300
STUB
chmod +x "$TMP_DIR/bin/swift"

wait_for_file() {
  local _
  for _ in $(seq 1 100); do [[ -s "$1" ]] && return 0; /bin/sleep 0.1; done
  fail "$2"
}

# Whether pid $1 ends within 10 s.
ends_soon() {
  local _
  for _ in $(seq 1 100); do kill -0 "$1" 2>/dev/null || return 0; /bin/sleep 0.1; done
  return 1
}

gate_env=(
  "HOME=$FAKE_HOME"
  "PATH=$TMP_DIR/bin:$PATH"
  "LOCALVOXTRAL_GATE_SESSION_POLL_SECONDS=0.1"
  "LOCALVOXTRAL_GATE_TERM_POLLS=20"
  "LV_TEST_PAYLOAD_PID_FILE=$TMP_DIR/payload.pid"
)
mkdir -p "$FAKE_HOME/work/localvoxtral-session-1"

# --- the session ends: the gate ends the payload ------------------------------

sleep 300 &
session=$!
spawned+=("$session")
env "${gate_env[@]}" LOCALVOXTRAL_GATE_SESSION_PID="$session" \
  SSH_ORIGINAL_COMMAND='cd work/localvoxtral-session-1 && swift build --build-system native' \
  bash "$GATE" >/dev/null 2>&1 &
gate=$!
spawned+=("$gate")
wait_for_file "$TMP_DIR/payload.pid" "the payload never started"
payload="$(cat "$TMP_DIR/payload.pid")"
[[ -n "$(ls "$FAKE_HOME/.lv-gate-payloads/localvoxtral-session-1" 2>/dev/null)" ]] || fail "the payload group was not recorded"
kill -KILL "$session"
ends_soon "$payload" || fail "the payload outlived its session"
status=0
wait "$gate" || status=$?
[[ "$status" == 129 ]] || fail "the gate exited $status when its session ended, not 129"
[[ -z "$(ls "$FAKE_HOME/.lv-gate-payloads/localvoxtral-session-1" 2>/dev/null)" ]] || fail "the gate left its payload record behind"
rm -f "$TMP_DIR/payload.pid"

# --- sessions that never ended: reap ends every recorded group ---------------

# Two payloads in one work dir at once, as the unit-test shards run.
payloads=()
for shard in 1 2; do
  rm -f "$TMP_DIR/payload.pid"
  env "${gate_env[@]}" LOCALVOXTRAL_GATE_SESSION_PID="$$" \
    SSH_ORIGINAL_COMMAND='cd work/localvoxtral-session-1 && swift build --build-system native' \
    bash "$GATE" >/dev/null 2>&1 &
  spawned+=("$!")
  wait_for_file "$TMP_DIR/payload.pid" "shard $shard never started"
  payloads+=("$(cat "$TMP_DIR/payload.pid")")
done
reap_out="$(env "${gate_env[@]}" SSH_ORIGINAL_COMMAND='reap work/localvoxtral-session-1' bash "$GATE" 2>&1 || true)"
[[ "$(grep -c 'reap: ending the abandoned payload group' <<<"$reap_out")" == 2 ]] \
  || fail "reap did not end both recorded groups: $reap_out"
for payload in "${payloads[@]}"; do
  ends_soon "$payload" || fail "a payload outlived reap"
done
rm -f "$TMP_DIR/payload.pid"

# A stale record (its leader long gone) ends nothing and is dropped.
mkdir -p "$FAKE_HOME/.lv-gate-payloads/localvoxtral-session-1"
echo "Thu Jan  1 00:00:00 1970" >"$FAKE_HOME/.lv-gate-payloads/localvoxtral-session-1/999999"
reap_out="$(env "${gate_env[@]}" SSH_ORIGINAL_COMMAND='reap work/localvoxtral-session-1' bash "$GATE" 2>&1 || true)"
! grep -q 'ending the abandoned payload group' <<<"$reap_out" || fail "reap acted on a stale record"
[[ ! -e "$FAKE_HOME/.lv-gate-payloads/localvoxtral-session-1/999999" ]] || fail "reap kept a stale record"

# --- remote-build.sh whose ssh client is killed mid-run -----------------------

# The client's ssh: runs the real gate as its child, as sshd runs the forced
# command, and is the session the gate watches.
cat >"$TMP_DIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do shift; done
case "$1" in
  cd\ *) printf '%s\n' "$$" >"$LV_TEST_SSH_PID_FILE" ;;
esac
HOME="$LV_TEST_FAKE_HOME" LOCALVOXTRAL_GATE_SESSION_PID="$$" SSH_ORIGINAL_COMMAND="$1" \
  bash "$LV_TEST_GATE"
STUB
cat >"$TMP_DIR/bin/rsync" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_DIR/bin/ssh" "$TMP_DIR/bin/rsync"

LOCK="$TMP_DIR/locks/fake-host.lock"
env "${gate_env[@]}" \
  "HOME=$HOME" \
  LV_BUILD_HOST=fake-host LV_BUILD_DIR=work/localvoxtral-session-2 \
  LV_LOCK_DIR="$LOCK" LV_LOCK_OWNER=session-test \
  LV_TEST_FAKE_HOME="$FAKE_HOME" LV_TEST_GATE="$GATE" LV_TEST_SSH_PID_FILE="$TMP_DIR/ssh.pid" \
  LOCALVOXTRAL_REMOTE_LOG="$TMP_DIR/remote-build.log" \
  "$REMOTE_BUILD" build >"$TMP_DIR/client.out" 2>&1 &
client=$!
spawned+=("$client")
wait_for_file "$TMP_DIR/payload.pid" "the remote build never started: $(cat "$TMP_DIR/client.out")"
payload="$(cat "$TMP_DIR/payload.pid")"
[[ -f "$LOCK/owner" ]] || fail "the build ran without the build host lock"
kill -KILL "$(cat "$TMP_DIR/ssh.pid")"
ends_soon "$payload" || fail "the remote build outlived its killed ssh client"
ends_soon "$client" || fail "remote-build.sh did not finish after its ssh client was killed"
wait "$client" 2>/dev/null || true
[[ ! -e "$LOCK" ]] || fail "remote-build.sh kept the build host lock after its ssh client was killed"

printf 'PASS: a payload ends with its ssh session, reap ends an abandoned one, a killed client releases its lock\n'
