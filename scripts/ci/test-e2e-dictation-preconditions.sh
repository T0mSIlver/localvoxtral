#!/usr/bin/env bash
# e2e-dictation.sh borrows the owner's Mac: it quits their app and takes the
# keyboard, and it must never write the owner's defaults. This pins the order of its refusals, so a
# run that cannot work never gets as far as touching any of that. Runs anywhere
# (every macOS tool is stubbed); the dictation itself is proven on the Mac.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lv-e2e-precondition-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export EVENTS="$WORK/events"
BIN="$WORK/bin"
mkdir -p "$BIN" "$WORK/home" "$WORK/app.app/Contents"
: >"$WORK/app.app/Contents/Info.plist"

fail() { echo "FAIL: $1" >&2; echo "--- events:" >&2; cat "$EVENTS" >&2 || true; exit 1; }

stub() { cat >"$BIN/$1"; chmod +x "$BIN/$1"; }
stub uname <<'STUB'
#!/bin/sh
if [ "$1" = -m ]; then echo arm64; else echo Darwin; fi
STUB
stub plistbuddy <<'STUB'
#!/bin/sh
case "$2" in
  'Print :CFBundleIdentifier') echo "${STUB_BUNDLE_ID:-com.localvoxtral.e2e-harness}" ;;
  *) echo "$STUB_HARNESS_STAMP" ;;
esac
STUB
stub nc <<'STUB'
#!/bin/sh
echo "nc $*" >>"$EVENTS"
exit "$STUB_NC_STATUS"
STUB
# Anything below must never run before the preconditions hold.
for tool in defaults open osascript say swiftc pkill; do
  stub "$tool" <<STUB
#!/bin/sh
echo "$tool \$*" >>"\$EVENTS"
exit 0
STUB
done
stub pgrep <<'STUB'
#!/bin/sh
exit 1
STUB

run() {
  : >"$EVENTS"
  set +e
  HOME="$WORK/home" PATH="$BIN:$PATH" LV_E2E_PLISTBUDDY="$BIN/plistbuddy" LV_E2E_ANNOUNCE=0 \
    LV_E2E_REALTIME_ENDPOINT="ws://127.0.0.1:59999/v1/realtime" \
    "$ROOT_DIR/scripts/e2e-dictation.sh" "$@" >"$WORK/out" 2>&1
  STATUS=$?
  set -e
}

untouched() {
  # untouched <case> [allowed]: `allowed` matches events the case may cause.
  if grep -E '^(defaults|open|osascript|say|swiftc|pkill) ' "$EVENTS" | grep -qvE "${2:-^$}"; then
    fail "$1: the run touched the machine before refusing"
  fi
}

export STUB_NC_STATUS=1

STUB_HARNESS_STAMP=false LV_SCREEN_LOCK_STATE=unlocked run "$WORK/app.app"
[ "$STATUS" -eq 1 ] || fail "a non-harness bundle exited $STATUS, want 1"
grep -q "is not a harness build" "$WORK/out" || fail "a non-harness bundle was not named as the reason"
untouched "non-harness bundle"
echo "PASS: a non-harness bundle is refused"

STUB_HARNESS_STAMP=true STUB_BUNDLE_ID=com.localvoxtral.app LV_SCREEN_LOCK_STATE=unlocked run "$WORK/app.app"
[ "$STATUS" -eq 1 ] || fail "a harness under the release's bundle id exited $STATUS, want 1"
grep -q "has bundle id 'com.localvoxtral.app', not com.localvoxtral.e2e-harness" "$WORK/out" \
  || fail "a harness under the release's bundle id was not named as the reason"
untouched "harness under the release's bundle id"
echo "PASS: a harness under the release's bundle id is refused (#1198)"

STUB_HARNESS_STAMP=true LV_SCREEN_LOCK_STATE=unlocked run "$WORK/missing.app"
[ "$STATUS" -eq 1 ] || fail "a missing bundle exited $STATUS, want 1"
untouched "missing bundle"
echo "PASS: a missing bundle is refused"

STUB_HARNESS_STAMP=true LV_SCREEN_LOCK_STATE=unlocked run "$WORK/app.app" "$WORK/no-such.scenario"
[ "$STATUS" -eq 1 ] || fail "a missing scenario exited $STATUS, want 1"
untouched "missing scenario"
echo "PASS: a missing scenario file is refused"

for state in locked no-session error; do
  STUB_HARNESS_STAMP=true LV_SCREEN_LOCK_STATE="$state" run "$WORK/app.app"
  [ "$STATUS" -eq 3 ] || fail "screen state '$state' exited $STATUS, want 3 (not runnable)"
  untouched "screen state $state"
done
echo "PASS: a screen that is not unlocked is 'not runnable', not a failure"

STUB_HARNESS_STAMP=true LV_SCREEN_LOCK_STATE=unlocked run "$WORK/app.app"
[ "$STATUS" -eq 3 ] || fail "an absent STT server exited $STATUS, want 3 (not runnable)"
grep -q "nc -z -w 3 127.0.0.1 59999" "$EVENTS" || fail "the STT endpoint's host and port were not probed"
untouched "absent STT server"
echo "PASS: an absent STT server is 'not runnable', and nothing was touched"

: >"$EVENTS"
set +e
HOME="$WORK/home" PATH="$BIN:$PATH" LV_E2E_PLISTBUDDY="$BIN/plistbuddy" LV_E2E_ANNOUNCE=0 \
  STUB_HARNESS_STAMP=true LV_SCREEN_LOCK_STATE=unlocked \
  LV_E2E_REALTIME_ENDPOINT="wss://stt.example/v1/realtime" \
  "$ROOT_DIR/scripts/e2e-dictation.sh" "$WORK/app.app" >"$WORK/out" 2>&1
set -e
grep -q "nc -z -w 3 stt.example 443" "$EVENTS" || fail "a portless wss endpoint was not probed on 443"
echo "PASS: a portless endpoint is probed on its scheme's port"

# The target app is built for the package's floor, not the SDK's macOS: an SDK
# newer than the running system made `open` refuse it (-10825).
: >"$EVENTS"
stub swiftc <<'STUB'
#!/bin/sh
echo "swiftc $*" >>"$EVENTS"
exit 1
STUB
STUB_HARNESS_STAMP=true LV_SCREEN_LOCK_STATE=unlocked STUB_NC_STATUS=0 run "$WORK/app.app"
[ "$STATUS" -eq 3 ] || fail "a failed target compile exited $STATUS, want 3 (not runnable)"
grep -qE '^swiftc .*-target arm64-apple-macos15\.0 ' "$EVENTS" \
  || fail "the target app was not compiled for arm64-apple-macos15.0"
echo "PASS: the target app is compiled for macOS 15.0"

# A speech service already lagging before the app starts is NOT RUN, and the
# owner's defaults are left alone (#548).
stub swiftc <<'STUB'
#!/bin/sh
echo "swiftc $*" >>"$EVENTS"
exit 0
STUB
stub say <<'STUB'
#!/bin/sh
echo "say $*" >>"$EVENTS"
[ "$1" = -o ] || exit 0
exec python3 -c 'import sys, wave
w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(bytes(32000)); w.close()' "$2"
STUB
port_file="$WORK/fake-port"
python3 "$ROOT_DIR/scripts/ci/fake-speech-service.py" "$port_file" 4 &
FAKE_PID=$!
trap 'kill "$FAKE_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
while [ ! -s "$port_file" ]; do python3 -c 'import time; time.sleep(0.05)'; done
: >"$EVENTS"
set +e
HOME="$WORK/home" PATH="$BIN:$PATH" LV_E2E_PLISTBUDDY="$BIN/plistbuddy" LV_E2E_ANNOUNCE=0 \
  STUB_HARNESS_STAMP=true LV_SCREEN_LOCK_STATE=unlocked STUB_NC_STATUS=0 \
  LV_E2E_REALTIME_ENDPOINT="ws://127.0.0.1:$(cat "$port_file")/v1/realtime" \
  "$ROOT_DIR/scripts/e2e-dictation.sh" "$WORK/app.app" >"$WORK/out" 2>&1
STATUS=$?
set -e
[ "$STATUS" -eq 3 ] || fail "a lagging speech service exited $STATUS, want 3 (not runnable): $(cat "$WORK/out")"
grep -q "NOT RUN: The speech service .* finished a clip [0-9.]* s after the speech ended, past the 3.5 s" "$WORK/out" \
  || fail "the NOT RUN line does not give the measured lag: $(cat "$WORK/out")"
# Compiling the target and writing the probe's WAV touch nothing of the
# owner's. The run ends its targets by the pids they wrote, never by a
# command-line match (#1011), so no pkill runs at all.
untouched "lagging speech service" '^(swiftc |say -o )'
echo "PASS: a speech service lagging before the app starts is 'not runnable', with its lag"

# The owner's app is quit before that probe, since its own speech helper
# loads the service the probe measures (#1832), and the NOT RUN relaunches it.
owner_bundle="$WORK/Owner/localvoxtral.app"
mkdir -p "$owner_bundle/Contents/MacOS"
stub pgrep <<'STUB'
#!/bin/sh
[ -e "$OWNER_QUIT" ] && exit 1
echo 777
STUB
stub ps <<STUB
#!/bin/sh
echo "$owner_bundle/Contents/MacOS/localvoxtral"
STUB
stub osascript <<'STUB'
#!/bin/sh
echo "osascript $*" >>"$EVENTS"
case "$*" in *'to quit'*) : >"$OWNER_QUIT" ;; esac
STUB
: >"$EVENTS"
rm -f "$WORK/owner-quit"
set +e
HOME="$WORK/home" PATH="$BIN:$PATH" LV_E2E_PLISTBUDDY="$BIN/plistbuddy" LV_E2E_ANNOUNCE=0 \
  STUB_HARNESS_STAMP=true LV_SCREEN_LOCK_STATE=unlocked STUB_NC_STATUS=0 OWNER_QUIT="$WORK/owner-quit" \
  LV_E2E_REALTIME_ENDPOINT="ws://127.0.0.1:$(cat "$port_file")/v1/realtime" \
  "$ROOT_DIR/scripts/e2e-dictation.sh" "$WORK/app.app" >"$WORK/out" 2>&1
STATUS=$?
set -e
[ "$STATUS" -eq 3 ] || fail "a lagging service with the owner's app up exited $STATUS, want 3: $(cat "$WORK/out")"
grep -q "^before the app, the owner's app quit: speech service probe: lag=" "$WORK/out" \
  || fail "the probe did not run after the owner's app quit: $(cat "$WORK/out")"
grep -q '^osascript .*localvoxtral" to quit' "$EVENTS" || fail "the owner's app was not quit"
grep -q "^open $owner_bundle\$" "$EVENTS" || fail "the NOT RUN did not relaunch the owner's app"
grep -q "NOT RUN: The speech service" "$WORK/out" || fail "no NOT RUN line: $(cat "$WORK/out")"
rm -f "$BIN/ps"
stub osascript <<'STUB'
#!/bin/sh
echo "osascript $*" >>"$EVENTS"
exit 0
STUB
echo "PASS: the owner's app quits before the probe, and a NOT RUN relaunches it (#1832)"

# A run that gets as far as dictating writes the harness's defaults and never
# the owner's (#1198). The stubs launch nothing, so each scenario fails to
# start; what matters is which domain the run wrote.
kill "$FAKE_PID" 2>/dev/null || true
wait "$FAKE_PID" 2>/dev/null || true
rm -f "$port_file"
python3 "$ROOT_DIR/scripts/ci/fake-speech-service.py" "$port_file" 0 &
FAKE_PID=$!
while [ ! -s "$port_file" ]; do python3 -c 'import time; time.sleep(0.05)'; done
# `open` stands in for both launches: the app under test opens its control
# socket, the target reports itself focused.
stub open <<'STUB'
#!/bin/sh
echo "open $*" >>"$EVENTS"
for arg; do last="$arg"; done
case "$*" in
  *e2e-target.app*) printf 'active=1 key=1 focused=1' >"$last/state" ;;
  # Bound from its folder: the full path is past AF_UNIX's length limit.
  *) python3 -c 'import os, socket, sys
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
os.chdir(os.path.dirname(sys.argv[1]))
socket.socket(socket.AF_UNIX).bind(os.path.basename(sys.argv[1]))' \
    "$HOME/Library/Application Support/localvoxtral/dogfood/control/control.sock" ;;
esac
STUB
# Only the newest-process query sees the app under test; no owner app runs.
stub pgrep <<'STUB'
#!/bin/sh
[ "$1" = -xn ] && { echo 4242; exit 0; }
exit 1
STUB
: >"$EVENTS"
set +e
HOME="$WORK/home" PATH="$BIN:$PATH" LV_E2E_PLISTBUDDY="$BIN/plistbuddy" LV_E2E_ANNOUNCE=0 \
  STUB_HARNESS_STAMP=true LV_SCREEN_LOCK_STATE=unlocked STUB_NC_STATUS=0 \
  LV_E2E_REALTIME_ENDPOINT="ws://127.0.0.1:$(cat "$port_file")/v1/realtime" \
  "$ROOT_DIR/scripts/e2e-dictation.sh" "$WORK/app.app" >"$WORK/out" 2>&1
set -e
grep -q "FAIL: .*the dictation did not start" "$WORK/out" \
  || fail "the run did not reach a dictation: $(cat "$WORK/out")"
grep -q '^defaults write com.localvoxtral.e2e-harness debug.dogfood_control_socket_enabled ' "$EVENTS" \
  || fail "the harness's defaults were not written"
if grep -E '^defaults ' "$EVENTS" | grep -q 'com\.localvoxtral\.app'; then
  fail "the run touched the owner's defaults domain"
fi
grep -q '^defaults delete com.localvoxtral.e2e-harness$' "$EVENTS" \
  || fail "the run left the harness's defaults behind"
echo "PASS: a run writes the harness's defaults and never the owner's"

# The scenarios that ship must parse.
for scenario in "$ROOT_DIR"/scripts/e2e/scenarios/*.scenario; do
  mode="$(sed -n 's/^mode=//p' "$scenario" | head -n 1)"
  phrase="$(sed -n 's/^phrase=//p' "$scenario" | head -n 1)"
  minimum="$(sed -n 's/^min_word_accuracy=//p' "$scenario" | head -n 1)"
  case "$mode" in live|overlay) ;; *) fail "$scenario: mode '$mode'" ;; esac
  [ -n "$phrase" ] || fail "$scenario: no phrase"
  awk -v m="$minimum" 'BEGIN { exit !(m ~ /^0?\.[0-9]+$|^1(\.0+)?$/) }' || fail "$scenario: min_word_accuracy '$minimum'"
done
echo "PASS: shipped scenarios are well-formed"

echo "e2e-dictation precondition tests passed"
