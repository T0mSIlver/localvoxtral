#!/usr/bin/env bash
# Regression test for the build host lock (scripts/lib/build-host-lock.sh): a
# run that sends work to the host holds the host's lock while its payload runs
# and releases it on success and failure; a held lock makes the next run wait;
# a lock left by a dead remote-build.sh is cleared; an old lock is reported,
# never broken; light verbs never wait. All transport commands are stubbed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
REMOTE_BUILD="$ROOT_DIR/scripts/remote-build.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-remote-lock-test.XXXXXX")"
# remote-build.sh's background GC can still be writing here as this script
# exits: retry the removal rather than fail the suite on its own cleanup.
trap 'for _ in 1 2 3 4 5 6 7 8 9 10; do rm -rf "$TMP_DIR" 2>/dev/null && break; /bin/sleep 0.1; done' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

LOCK="$TMP_DIR/locks/fake-host.lock"
mkdir -p "$TMP_DIR/bin"
# The payload records whether the lock was held, and by this run's line.
cat >"$TMP_DIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 1 ]]; do shift; done
command="$1"
case "$command" in
  cd\ *)
    if [[ -f "$LV_TEST_LOCK/owner" ]]; then
      printf 'held: %s\n' "$(cat "$LV_TEST_LOCK/owner")" >>"$LV_TEST_PAYLOAD_LOG"
    else
      printf 'not held\n' >>"$LV_TEST_PAYLOAD_LOG"
    fi
    [[ "$LV_TEST_PAYLOAD_RESULT" == "success" ]] && exit 0
    exit 42
    ;;
  *) exit 0 ;;
esac
STUB
cat >"$TMP_DIR/bin/rsync" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_DIR/bin/ssh" "$TMP_DIR/bin/rsync"

payload_log="$TMP_DIR/payload.log"
common_env=(
  "PATH=$TMP_DIR/bin:$PATH"
  "LV_BUILD_HOST=fake-host"
  "LV_BUILD_DIR=work/localvoxtral-lock-regression"
  "LV_LOCK_DIR=$LOCK"
  "LV_LOCK_OWNER=lock-test"
  "LV_LOCK_POLL_SECONDS=1"
  "LV_TEST_LOCK=$LOCK"
  "LV_TEST_PAYLOAD_LOG=$payload_log"
  "LV_TEST_PAYLOAD_RESULT=success"
  "LOCALVOXTRAL_REMOTE_LOG=$TMP_DIR/remote-build.log"
)

# --- held while the payload runs, released after ------------------------------

env "${common_env[@]}" "$REMOTE_BUILD" build >"$TMP_DIR/out" 2>&1 \
  || fail "a free lock did not let the run through: $(cat "$TMP_DIR/out")"
grep -q '^held: lock-test [0-9T:-]*Z remote-build.sh build host=' "$payload_log" \
  || fail "the payload ran without this run's lock: $(cat "$payload_log")"
[[ ! -e "$LOCK" ]] || fail "a successful run left its lock behind"

: >"$payload_log"
status=0
env "${common_env[@]}" LV_TEST_PAYLOAD_RESULT=failure "$REMOTE_BUILD" build >"$TMP_DIR/out" 2>&1 \
  || status=$?
[[ "$status" == 42 ]] || fail "a failed payload's status became $status"
grep -q '^held: ' "$payload_log" || fail "the failed payload ran unlocked"
[[ ! -e "$LOCK" ]] || fail "a failed run left its lock behind"

# --- a marker verb keeps its cleanup and still releases the lock -------------

: >"$payload_log"
env "${common_env[@]}" LV_ALLOW_HEAVY_MAC_RUN=1 "$REMOTE_BUILD" speechd-bench 1 >"$TMP_DIR/out" 2>&1 \
  || fail "speechd-bench failed: $(cat "$TMP_DIR/out")"
grep -q '^held: ' "$payload_log" || fail "speechd-bench ran unlocked"
[[ ! -e "$LOCK" ]] || fail "speechd-bench left its lock behind"
[[ ! -e "$ROOT_DIR/.speechd-bench-enable.json" ]] || fail "speechd-bench left its marker behind"

# --- a held lock makes the run wait until it is released ---------------------

mkdir -p "$LOCK"
echo "another-thread $(date -u +%Y-%m-%dT%H:%M:%SZ) package" >"$LOCK/owner"
: >"$payload_log"
env "${common_env[@]}" "$REMOTE_BUILD" build >"$TMP_DIR/wait.out" 2>&1 &
waiter=$!
for _ in $(seq 1 100); do
  grep -q 'Waiting for the build host lock' "$TMP_DIR/wait.out" 2>/dev/null && break
  /bin/sleep 0.1
done
grep -q "held by: another-thread .* package" "$TMP_DIR/wait.out" \
  || fail "the waiting run did not name the holder: $(cat "$TMP_DIR/wait.out")"
[[ ! -s "$payload_log" ]] || fail "the payload ran while another run held the lock"
rm -r "$LOCK"
wait "$waiter" || fail "the waiting run failed after the lock was released: $(cat "$TMP_DIR/wait.out")"
grep -q '^held: lock-test ' "$payload_log" || fail "the waiting run did not take the lock"

# --- a lock whose holder has not written its line yet is waited for ---------

mkdir -p "$LOCK"
: >"$payload_log"
env "${common_env[@]}" "$REMOTE_BUILD" build >"$TMP_DIR/wait.out" 2>&1 &
waiter=$!
for _ in $(seq 1 100); do
  grep -q 'Waiting for the build host lock' "$TMP_DIR/wait.out" 2>/dev/null && break
  /bin/sleep 0.1
done
grep -q 'held by: an owner that wrote no line' "$TMP_DIR/wait.out" \
  || fail "an ownerless lock did not make the run wait: $(cat "$TMP_DIR/wait.out")"
rm -r "$LOCK"
wait "$waiter" || fail "the run failed after an ownerless lock went: $(cat "$TMP_DIR/wait.out")"

# --- a reclaim that finds the lock already retaken leaves it -----------------

mkdir -p "$LOCK"
echo "live-thread $(date -u +%Y-%m-%dT%H:%M:%SZ) package" >"$LOCK/owner"
(
  LV_LOCK_DIR="$LOCK"
  # shellcheck source=../lib/build-host-lock.sh
  . "$ROOT_DIR/scripts/lib/build-host-lock.sh"
  ! lv_lock_reclaim "dead-thread 2026-01-01T00:00:00Z remote-build.sh test host=$(hostname) pid=1"
)
[[ "$(cat "$LOCK/owner")" == live-thread* ]] || fail "a late reclaim removed the lock another run had just taken"
[[ ! -e "$LOCK.reclaim" ]] || fail "the reclaim left its mutex behind"
rm -r "$LOCK"

# --- a reclaim mutex left without a pid does not make waiters spin -----------

mkdir -p "$LOCK" "$LOCK.reclaim"
dead_owner_line() {
  sh -c 'exit 0' &
  local dead=$!
  wait "$dead"
  echo "crashed $(date -u +%Y-%m-%dT%H:%M:%SZ) remote-build.sh test host=$(hostname) pid=$dead"
}
dead_owner_line >"$LOCK/owner"
status=0
env "${common_env[@]}" LV_LOCK_WAIT_SECONDS=2 "$REMOTE_BUILD" build >"$TMP_DIR/out" 2>&1 || status=$?
[[ "$status" == 75 ]] || fail "a fresh ownerless reclaim mutex did not leave the run waiting (exit $status)"
touch -t 202001010000 "$LOCK.reclaim"
env "${common_env[@]}" "$REMOTE_BUILD" build >"$TMP_DIR/out" 2>&1 \
  || fail "an old ownerless reclaim mutex was not cleared: $(cat "$TMP_DIR/out")"
[[ ! -e "$LOCK" && ! -e "$LOCK.reclaim" ]] || fail "the cleared lock or its mutex is still there"

# --- a lock left by a remote-build.sh that died is cleared -------------------

mkdir -p "$LOCK"
sh -c 'exit 0' &
dead=$!
wait "$dead"
echo "crashed $(date -u +%Y-%m-%dT%H:%M:%SZ) remote-build.sh test host=$(hostname) pid=$dead" >"$LOCK/owner"
env "${common_env[@]}" "$REMOTE_BUILD" build >"$TMP_DIR/out" 2>&1 \
  || fail "a dead holder's lock was not cleared: $(cat "$TMP_DIR/out")"
grep -q 'Clearing the build host lock left by a remote-build.sh that is gone' "$TMP_DIR/out" \
  || fail "clearing a dead holder's lock was not said"

# --- an old lock is reported, never broken -----------------------------------

mkdir -p "$LOCK"
echo "old-thread 2020-01-01T00:00:00Z eval" >"$LOCK/owner"
status=0
env "${common_env[@]}" LV_LOCK_WAIT_SECONDS=1 "$REMOTE_BUILD" build >"$TMP_DIR/out" 2>&1 || status=$?
[[ "$status" == 75 ]] || fail "giving up on a held lock exited $status, not 75"
grep -q 'That lock is over 3 h old' "$TMP_DIR/out" || fail "an old lock was not reported as old"
[[ "$(cat "$LOCK/owner")" == "old-thread 2020-01-01T00:00:00Z eval" ]] \
  || fail "the script broke a lock it did not take"

# --- light verbs and an unconfigured host never wait -------------------------

env "${common_env[@]}" "$REMOTE_BUILD" disk >"$TMP_DIR/out" 2>&1 \
  || fail "disk waited for or failed on a held lock: $(cat "$TMP_DIR/out")"
rm -r "$LOCK"
: >"$payload_log"
env "${common_env[@]}" LV_LOCK_DIR= "$REMOTE_BUILD" build >"$TMP_DIR/out" 2>&1 \
  || fail "a run with no lock configured failed: $(cat "$TMP_DIR/out")"
grep -q '^not held$' "$payload_log" || fail "a run with no lock configured took one"

printf 'PASS: remote-build holds the build host lock for its payload, waits for a held one and never breaks one\n'
