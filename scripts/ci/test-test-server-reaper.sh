#!/usr/bin/env bash
# Regression tests for the on-demand test servers' idle reaper and `diagnose`
# (#829). The reaper used to stop speechd 20 min after the last `ensure` even
# while a client was using it, which cost eval-e2e and long CI lanes their
# server mid-run. A client connection must count as use, and a failed lane
# must be able to say whether the server was reaped, never started, or lost
# its port to another process.
#
# lsof, nc, ps, launchctl and sleep are stubbed; their answers come
# from files under $TMP_DIR/state.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SERVERS="${LV_TEST_SERVERS_SCRIPT:-$ROOT_DIR/scripts/mac/lv-test-servers.sh}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-reaper-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
assert_has() {
  grep -qF -- "$2" "$1" || fail "$1 lacks \"$2\": $(cat "$1")"
}
assert_lacks() {
  ! grep -qF -- "$2" "$1" || fail "$1 has \"$2\": $(cat "$1")"
}

STATE="$TMP_DIR/state"
CALLS="$TMP_DIR/calls.log"
mkdir -p "$TMP_DIR/bin" "$STATE"
REAL_STAT="$(command -v stat)"

# lsof answers a -sTCP:ESTABLISHED query with state/conns.<n> on its n-th
# such call, or state/conns once those run out, so a test can make a client
# appear partway through a watch. A LISTEN query gets state/lsof.
cat >"$TMP_DIR/bin/lsof" <<STUB
#!/usr/bin/env bash
if [[ " \$* " == *" -sTCP:ESTABLISHED "* ]]; then
  n=\$(( \$(cat "$STATE/conns-calls" 2>/dev/null || echo 0) + 1 ))
  echo "\$n" >"$STATE/conns-calls"
  if [[ -f "$STATE/conns.\$n" ]]; then cat "$STATE/conns.\$n"; else cat "$STATE/conns" 2>/dev/null; fi
else
  cat "$STATE/lsof" 2>/dev/null
fi
exit 0
STUB
# nc: the port is up while state/up exists.
cat >"$TMP_DIR/bin/nc" <<STUB
#!/usr/bin/env bash
[[ -e "$STATE/up" ]]
STUB
# launchctl logs its arguments; a kill takes the server down, unless
# state/foreign-listener says another account's process holds the port.
cat >"$TMP_DIR/bin/launchctl" <<STUB
#!/usr/bin/env bash
printf 'launchctl %s\n' "\$*" >>"$CALLS"
[[ -e "$STATE/foreign-listener" ]] && exit 3
[[ "\$1" == kill ]] && rm -f "$STATE/up"
exit 0
STUB
cat >"$TMP_DIR/bin/ps" <<STUB
#!/usr/bin/env bash
cat "$STATE/ps" 2>/dev/null
exit 0
STUB
cat >"$TMP_DIR/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
# The script reads mtimes with BSD `stat -f %m`; GNU stat spells it -c %Y.
cat >"$TMP_DIR/bin/stat" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == -f && "\$2" == %m ]]; then
  "$REAL_STAT" -c %Y "\$3" 2>/dev/null || "$REAL_STAT" -f %m "\$3"
else
  "$REAL_STAT" "\$@"
fi
STUB
cat >"$TMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
chmod +x "$TMP_DIR/bin/"*

LIST="$TMP_DIR/models.tsv"
printf 'voxtral\t8000\tT0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead\t247f2eeccf962fbcaf85e361731a5e75b2d8cac1\n' >"$LIST"
RUN="$TMP_DIR/run"
LOGS="$TMP_DIR/logs"
mkdir -p "$RUN" "$LOGS"
servers() {
  env PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR/home" \
    LV_TEST_SPEECH_MODELS="$LIST" \
    LV_TEST_SERVER_RUN_DIR="$RUN" \
    LV_TEST_SERVER_LOG_DIR="$LOGS" \
    LV_TEST_SERVER_IDLE_SECONDS=1200 \
    LV_TEST_SERVER_USE_WATCH_SECONDS=5 \
    LV_TEST_SERVER_STOP_GRACE=1 \
    bash "$SERVERS" "$@"
}

TRIGGER="$RUN/voxmlx.want"
MY_STAMP="$RUN/voxmlx.seen.$(id -u)"
OTHER_STAMP="$RUN/voxmlx.seen.99999"
# A server started by another account's `ensure` an hour ago.
start_idle_server() {
  rm -f "$RUN"/* "$STATE"/conns* "$STATE/up"
  : >"$CALLS"
  touch "$TRIGGER" "$OTHER_STAMP" "$STATE/up"
  touch -t 202001010000 "$TRIGGER" "$OTHER_STAMP"
}
mtime() {
  "$TMP_DIR/bin/stat" -f %m "$1"
}
# lsof -Fn as measured on macOS 27: the server side of one client on 8000, its
# client side, and a server on 18000 that must not count as 8000.
CLIENT_SOCKETS='p4242
f20
n127.0.0.1:8000->127.0.0.1:52011
p78862
f3
n127.0.0.1:52011->127.0.0.1:8000
p5151
f7
n127.0.0.1:18000->127.0.0.1:52012'

# ---- a connection at the reaper's run counts as use ---------------------------

start_idle_server
printf '%s\n' "$CLIENT_SOCKETS" >"$STATE/conns"
servers reap >"$TMP_DIR/out" 2>&1 || fail "reap failed: $(cat "$TMP_DIR/out")"
assert_has "$TMP_DIR/out" "reap speechd-voxtral: in use (1 open connection(s) on port 8000) — kept warm"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z reap ' "$TMP_DIR/out" \
  || fail "reap lines carry no UTC timestamp: $(cat "$TMP_DIR/out")"
[[ -e "$TRIGGER" ]] || fail "reap removed the trigger of a server in use"
assert_lacks "$CALLS" "launchctl kill"
[[ -e "$MY_STAMP" ]] && (( $(date +%s) - $(mtime "$MY_STAMP") < 60 )) \
  || fail "reap did not refresh its own stamp for a server in use"

# The stamp that use refreshed keeps the next run, with the client gone, from
# stopping a server whose last `ensure` is past the window.
: >"$STATE/conns"
rm -f "$STATE"/conns-calls
servers reap >"$TMP_DIR/out" 2>&1 || fail "reap failed: $(cat "$TMP_DIR/out")"
assert_has "$TMP_DIR/out" "reap speechd-voxtral: active (idle"
[[ -e "$TRIGGER" ]] || fail "reap stopped a server used moments ago"
assert_lacks "$CALLS" "launchctl kill"

# ---- a request between two reaper runs counts too ------------------------------

# Past the window with no client at the first look; one connects on the third.
start_idle_server
: >"$STATE/conns"
printf '%s\n' "$CLIENT_SOCKETS" >"$STATE/conns.3"
servers reap >"$TMP_DIR/out" 2>&1 || fail "reap failed: $(cat "$TMP_DIR/out")"
assert_has "$TMP_DIR/out" "but a client connected after 1s — kept warm"
[[ -e "$TRIGGER" ]] || fail "reap stopped a server a client connected to while it watched"
assert_lacks "$CALLS" "launchctl kill"
[[ -e "$MY_STAMP" ]] || fail "a client seen during the watch did not refresh the stamp"

# ---- no client at all: stopped -------------------------------------------------

start_idle_server
: >"$STATE/conns"
servers reap >"$TMP_DIR/out" 2>&1 || fail "reap failed: $(cat "$TMP_DIR/out")"
assert_has "$TMP_DIR/out" "no client in 5s — stopped"
assert_has "$CALLS" "launchctl kill SIGTERM gui/$(id -u)/com.localvoxtral.testspeechd"
[[ ! -e "$TRIGGER" && ! -e "$OTHER_STAMP" ]] || fail "reap left the trigger or stamps of a stopped server"

# A server inside the window is kept without watching the port.
start_idle_server
touch "$OTHER_STAMP"
rm -f "$STATE/conns-calls"
servers reap >"$TMP_DIR/out" 2>&1 || fail "reap failed"
assert_has "$TMP_DIR/out" "active (idle"
[[ "$(cat "$STATE/conns-calls")" == 1 ]] || fail "reap watched the port of a server inside its window"

# ---- status counts clients -----------------------------------------------------

printf '%s\n' "$CLIENT_SOCKETS" >"$STATE/conns"
servers status >"$TMP_DIR/out" 2>&1 || fail "status failed: $(cat "$TMP_DIR/out")"
assert_has "$TMP_DIR/out" "clients=1   port 8000: up"

# ---- diagnose ------------------------------------------------------------------

diagnose() {
  servers diagnose speechd >"$TMP_DIR/out" 2>&1 || fail "diagnose failed: $(cat "$TMP_DIR/out")"
  head -1 "$TMP_DIR/out"
}
: >"$STATE/conns"
printf '%s reap speechd-voxtral: idle 1300s >= 1200s, no client in 60s — stopped (trigger removed + SIGTERM, drained in 1s)\n' \
  2026-09-27T07:03:00Z >"$LOGS/testservers-reaper.log"

rm -f "$RUN"/* "$STATE/up"
[[ "$(diagnose)" == "diagnose speechd-voxtral: GONE: "* ]] || fail "reaped server not GONE: $(cat "$TMP_DIR/out")"
assert_has "$TMP_DIR/out" "2026-09-27T07:03:00Z reap speechd-voxtral: idle 1300s"

touch "$TRIGGER"
printf 'speechd: ready on 127.0.0.1:8000\nspeechd: POSIXErrorCode(rawValue: 48): Address already in use\n' >"$LOGS/speechd.log"
[[ "$(diagnose)" == *"TAKEN: nothing listens on port 8000 now, but the last start failed with Address already in use" ]] \
  || fail "a start that lost the port is not TAKEN: $(cat "$TMP_DIR/out")"

printf 'speechd: ready on 127.0.0.1:8000\n' >"$LOGS/speechd.log"
[[ "$(diagnose)" == "diagnose speechd-voxtral: DOWN: "* ]] || fail "not DOWN: $(cat "$TMP_DIR/out")"

touch "$STATE/up"
echo 4242 >"$STATE/lsof"
echo '4242 tom /Users/Shared/localvoxtral/testservers/localvoxtral.app/Contents/MacOS/localvoxtral-speechd --model m --port 8000' >"$STATE/ps"
[[ "$(diagnose)" == "diagnose speechd-voxtral: up: the test service serves port 8000" ]] \
  || fail "the test service is not up: $(cat "$TMP_DIR/out")"
assert_has "$TMP_DIR/out" "listener: 4242 tom /Users/Shared/localvoxtral/testservers"

echo '4242 tom /tmp/localvoxtral-try.x/localvoxtral.app/Contents/MacOS/localvoxtral-speechd --model m --port 8000 --parent-pid 15839' >"$STATE/ps"
[[ "$(diagnose)" == *"TAKEN: port 8000 is held by a localvoxtral app's own helper, not the test service" ]] \
  || fail "an app's helper on 8000 is not TAKEN: $(cat "$TMP_DIR/out")"

echo '4242 tom /usr/bin/python3 -m http.server 8000' >"$STATE/ps"
[[ "$(diagnose)" == *"TAKEN: port 8000 is held by another process, not the test service" ]] \
  || fail "another process on 8000 is not TAKEN: $(cat "$TMP_DIR/out")"
assert_has "$TMP_DIR/out" "listener: 4242 tom /usr/bin/python3 -m http.server 8000"

: >"$STATE/lsof"
[[ "$(diagnose)" == *"cannot see which process holds it"* ]] \
  || fail "a hidden listener is not reported as such: $(cat "$TMP_DIR/out")"

status=0
servers diagnose bogus >/dev/null 2>&1 || status=$?
[[ "$status" == 2 ]] || fail "diagnose of an unknown service exited $status, expected 2"

echo "PASS: test-server reaper counts clients as use; diagnose names the cause"

# ---- a stop that leaves the listener answering is no stop ------------------

# Another account's process holds port 8000: launchctl reaches no job, and an
# unprivileged lsof finds no pid. `stop` used to say "stopped" and exit 0
# (#1722).
start_idle_server
: >"$STATE/lsof"
touch "$STATE/foreign-listener"
if servers stop speechd >"$TMP_DIR/out" 2>&1; then
  fail "stop exited 0 while the listener still answers: $(cat "$TMP_DIR/out")"
fi
assert_lacks "$TMP_DIR/out" "stopped"
assert_has "$TMP_DIR/out" "stop speechd-voxtral: still answering on port 8000"
rm -f "$STATE/foreign-listener"
printf 'PASS: a stop that leaves the listener answering fails\n'
