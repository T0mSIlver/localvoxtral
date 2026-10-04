#!/usr/bin/env bash
# ui-smoke.sh runs on the owner's Mac, where the owner's own localvoxtral is
# usually running. The drill has to quit it to launch a fresh instance, and on
# 2026-09-18 a drill that failed its TCC preflight still quit it on exit, three
# times in one evening, mid-dictation, without relaunching it. This suite runs
# the real script against stubbed macOS tools and asserts that the owner's app
# is only quit once the drill is really going to launch, and that it is
# relaunched from the same bundle with plain `open`, however the drill ends.
# The drill runs the app on its own defaults suite and never writes the
# owner's domain (#1029).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lv-ui-smoke-owner-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; echo "--- event log:" >&2; cat "$EVENTS" >&2 || true; exit 1; }

BIN="$WORK/bin"
mkdir -p "$BIN"

# Every stub appends to one ordered event log so the tests can assert order.
cat >"$BIN/uname" <<'STUB'
#!/bin/sh
echo Darwin
STUB
cat >"$BIN/swift" <<'STUB'
#!/bin/sh
echo "swift preflight" >>"$EVENTS"
exit "$STUB_PREFLIGHT_STATUS"
STUB
cat >"$BIN/pgrep" <<'STUB'
#!/bin/sh
# `pgrep -x[n] localvoxtral`: the pids in $RUNNING. `pgrep -f <backends>`: none.
case "$1" in
  -x|-xn) [ -s "$RUNNING" ] || exit 1; cat "$RUNNING" ;;
  *) exit 1 ;;
esac
STUB
cat >"$BIN/ps" <<'STUB'
#!/bin/sh
# `ps -o comm= -p <pid>`: the owner's executable path. Anything else: nothing.
case "$*" in
  *"-p "*) [ -s "$RUNNING" ] && echo "$STUB_OWNER_EXECUTABLE" ;;
esac
exit 0
STUB
cat >"$BIN/osascript" <<'STUB'
#!/bin/sh
case "$*" in
  *" to quit"*) echo "quit" >>"$EVENTS"; : >"$RUNNING" ;;
esac
exit 0
STUB
cat >"$BIN/log" <<'STUB'
#!/bin/sh
# `log stream`: attached, and the app never logs.
echo "log $1" >>"$EVENTS"
echo "Filtering the log data using \"stub\""
exec sleep 30
STUB
cat >"$BIN/open" <<'STUB'
#!/bin/sh
# The drill's own `open -n` never produces a process, so it ends at "did not
# start"; any other `open` is the owner relaunch and brings the owner back.
echo "open $*" >>"$EVENTS"
case "$1" in
  -n|--env) ;;
  *)
    echo 4242 >"$RUNNING"
    env | grep -E '^(RUNNER_TRACKING_ID|LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN|LOCALVOXTRAL_DATA_HOME|LOCALVOXTRAL_DEFAULTS_SUITE)=' >>"$EVENTS"
    ;;
esac
exit 0
STUB
cat >"$BIN/defaults" <<'STUB'
#!/bin/sh
echo "defaults $1 $2" >>"$EVENTS"
case "$1" in
  export) if [ "$3" = - ]; then printf '<plist/>\n'; else printf '<plist/>\n' >"$3"; fi ;;
esac
exit 0
STUB
cat >"$BIN/plutil" <<'STUB'
#!/bin/sh
exit "${STUB_LINT_STATUS:-0}"
STUB
chmod +x "$BIN"/*

APP="$WORK/dist/localvoxtral.app"
mkdir -p "$APP"
OWNER_BUNDLE="$WORK/Applications/localvoxtral.app"
mkdir -p "$OWNER_BUNDLE"

# run_drill <preflight status> <owner running: yes|no>
run_drill() {
  export EVENTS="$WORK/events" RUNNING="$WORK/running"
  export STUB_PREFLIGHT_STATUS="$1"
  export STUB_OWNER_EXECUTABLE="$OWNER_BUNDLE/Contents/MacOS/localvoxtral"
  : >"$EVENTS"
  if [ "$2" = yes ]; then echo 4242 >"$RUNNING"; else : >"$RUNNING"; fi
  rm -rf "$WORK/home"
  mkdir -p "$WORK/home"
  # The drill's own exit status is not under test here: every case ends red.
  HOME="$WORK/home" PATH="$BIN:$PATH" LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=1 RUNNER_TRACKING_ID=github_job \
    UI_SMOKE_LAUNCH_TIMEOUT_SECONDS=1 bash "$ROOT_DIR/scripts/ui-smoke.sh" "$APP" >"$WORK/out" 2>&1 || true
}

line_of() { grep -n -m1 -x -- "$1" "$EVENTS" | cut -d: -f1 || true; }

# Cases 2-4 must end at the drill's own launch; anything earlier would satisfy
# their assertions for the wrong reason.
assert_reached_launch() {
  grep -q "App process did not start" "$WORK/out" \
    || fail "the drill ended before its launch: $(tail -n 3 "$WORK/out")"
}

# 1. Preflight fails: the drill never launches, so the owner's app is untouched.
run_drill 1 yes
grep -qx "quit" "$EVENTS" && fail "a drill that failed its preflight quit the owner's app"
grep -q "^open" "$EVENTS" && fail "a drill that failed its preflight ran open"
[ -s "$RUNNING" ] || fail "the owner's app is not running after a failed preflight"
echo "PASS: failed preflight leaves the owner's app running"

# 2. Preflight passes, the drill's launch fails: the owner's app is quit before
#    the launch and relaunched from its own bundle without the CI-only env.
#    The drill writes only its own suite.
run_drill 0 yes
assert_reached_launch
quit_line="$(line_of "quit")"
write_line="$(line_of "defaults write com.localvoxtral.harness")"
relaunch_line="$(line_of "open $OWNER_BUNDLE")"
[ -n "$quit_line" ] || fail "the drill did not quit the owner's app before launching"
[ -n "$write_line" ] || fail "the drill never wrote its defaults suite"
grep -qE "^defaults (write|import|delete) com\.localvoxtral\.app$" "$EVENTS" \
  && fail "the drill wrote the owner's defaults domain"
[ -n "$relaunch_line" ] || fail "the owner's app was not relaunched from $OWNER_BUNDLE"
grep -q "^open --env.*$OWNER_BUNDLE" "$EVENTS" && fail "the owner relaunch carried the CI-only env"
# The runner kills every process that carries the job's tracking id when the
# job ends; on 2026-09-25 that was the relaunched owner app, seven seconds
# after the e2e check brought it back.
grep -q "^RUNNER_TRACKING_ID=" "$EVENTS" && fail "the owner relaunch carried the runner's tracking id, so the job's end kills it"
# The drill's data folder is deleted after the run: an owner app reopened on
# it would save the owner's dictations into a folder about to go (#985).
grep -q "^LOCALVOXTRAL_DATA_HOME=" "$EVENTS" && fail "the owner relaunch carried the drill's data folder"
grep -q "^LOCALVOXTRAL_DEFAULTS_SUITE=" "$EVENTS" && fail "the owner relaunch carried the drill's defaults suite"
grep -q "^LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=" "$EVENTS" && fail "the owner relaunch inherited the lane's keychain flag"
[ -s "$RUNNING" ] || fail "the owner's app is not running after the drill"
grep -q "Relaunched the owner's app" "$WORK/out" || fail "the relaunch is not reported in the drill output"
grep -q "Owner defaults unchanged" "$WORK/out" || fail "the drill did not report the owner's defaults"
echo "PASS: the owner's app is quit before the launch and relaunched after it; only the harness suite is written"

# The app's log is streamed from before its launch (#594): a line logged
# before the stream attaches is lost.
stream_line="$(line_of "log stream")"
launch_line="$(grep -nE -m1 "^open --env LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=1 (--env [^ ]+ )*-n" "$EVENTS" | cut -d: -f1 || true)"
[ -n "$stream_line" ] || fail "the drill never streamed the app's log"
[ -n "$launch_line" ] || fail "the drill never launched the app"
# Its data and preferences stay out of the owner's (#985, #1029).
grep -qE "^open .*--env LOCALVOXTRAL_DATA_HOME=/[^ ]+ .*-n" "$EVENTS" \
  || fail "the drill launched the app on the owner's data"
grep -qE "^open .*--env LOCALVOXTRAL_DEFAULTS_SUITE=com\.localvoxtral\.harness .*-n" "$EVENTS" \
  || fail "the drill launched the app on the owner's preferences"
[ "$stream_line" -lt "$launch_line" ] || fail "the app's log stream started after the launch"
echo "PASS: the app's log is streamed from before its launch"

# 3. No owner app running: nothing gets relaunched.
run_drill 0 no
assert_reached_launch
grep -q "^open $OWNER_BUNDLE" "$EVENTS" && fail "the drill relaunched an app that was not running before"
echo "PASS: no relaunch when the owner's app was not running"

echo "ui-smoke owner-app tests passed"
