#!/usr/bin/env bash
# e2e-dictation.sh borrows the owner's Mac: it quits their app, rewrites its
# defaults and takes the keyboard. This pins the order of its refusals, so a
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
echo "$STUB_DOGFOOD_STAMP"
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
  if grep -qE '^(defaults|open|osascript|say|swiftc|pkill) ' "$EVENTS"; then
    fail "$1: the run touched the machine before refusing"
  fi
}

export STUB_NC_STATUS=1

STUB_DOGFOOD_STAMP=false LV_SCREEN_LOCK_STATE=unlocked run "$WORK/app.app"
[ "$STATUS" -eq 1 ] || fail "a non-dogfood bundle exited $STATUS, want 1"
grep -q "is not a dogfood build" "$WORK/out" || fail "a non-dogfood bundle was not named as the reason"
untouched "non-dogfood bundle"
echo "PASS: a non-dogfood bundle is refused"

STUB_DOGFOOD_STAMP=true LV_SCREEN_LOCK_STATE=unlocked run "$WORK/missing.app"
[ "$STATUS" -eq 1 ] || fail "a missing bundle exited $STATUS, want 1"
untouched "missing bundle"
echo "PASS: a missing bundle is refused"

STUB_DOGFOOD_STAMP=true LV_SCREEN_LOCK_STATE=unlocked run "$WORK/app.app" "$WORK/no-such.scenario"
[ "$STATUS" -eq 1 ] || fail "a missing scenario exited $STATUS, want 1"
untouched "missing scenario"
echo "PASS: a missing scenario file is refused"

for state in locked no-session error; do
  STUB_DOGFOOD_STAMP=true LV_SCREEN_LOCK_STATE="$state" run "$WORK/app.app"
  [ "$STATUS" -eq 3 ] || fail "screen state '$state' exited $STATUS, want 3 (not runnable)"
  untouched "screen state $state"
done
echo "PASS: a screen that is not unlocked is 'not runnable', not a failure"

STUB_DOGFOOD_STAMP=true LV_SCREEN_LOCK_STATE=unlocked run "$WORK/app.app"
[ "$STATUS" -eq 3 ] || fail "an absent STT server exited $STATUS, want 3 (not runnable)"
grep -q "nc -z -w 3 127.0.0.1 59999" "$EVENTS" || fail "the STT endpoint's host and port were not probed"
untouched "absent STT server"
echo "PASS: an absent STT server is 'not runnable', and nothing was touched"

: >"$EVENTS"
set +e
HOME="$WORK/home" PATH="$BIN:$PATH" LV_E2E_PLISTBUDDY="$BIN/plistbuddy" LV_E2E_ANNOUNCE=0 \
  STUB_DOGFOOD_STAMP=true LV_SCREEN_LOCK_STATE=unlocked \
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
STUB_DOGFOOD_STAMP=true LV_SCREEN_LOCK_STATE=unlocked STUB_NC_STATUS=0 run "$WORK/app.app"
[ "$STATUS" -eq 3 ] || fail "a failed target compile exited $STATUS, want 3 (not runnable)"
grep -qE '^swiftc .*-target arm64-apple-macos15\.0 ' "$EVENTS" \
  || fail "the target app was not compiled for arm64-apple-macos15.0"
echo "PASS: the target app is compiled for macOS 15.0"

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
