#!/usr/bin/env bash
# Security regression tests for the forced-command UI gate
# (scripts/mac/localvoxtral-ui-gate.sh).
#
# The gate drives a GUI this test suite cannot reach, so everything that would
# need one is stubbed on PATH (open/pgrep/ps/say/screencapture/swift/...) and
# the gate itself runs UNMODIFIED. What is proved here is the whole trust
# boundary — the allowlist, the argument validation, the lock refusal, and the
# "only the pid this gate launched" ownership rule — none of which needs a
# screen. What is NOT proved here is that the AX/CGWindow calls inside the
# Swift helper do the right thing on a live desktop; that is the owner's
# first-install check (scripts/mac/README.md).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GATE="$ROOT_DIR/scripts/mac/localvoxtral-ui-gate.sh"
LOCK_PROBE_SRC="$ROOT_DIR/scripts/ci/screen-lock-state.sh"
# Deliberately /tmp and not $TMPDIR: fixture bundle paths are fed through the
# gate's token charset, and a macOS per-user $TMPDIR can carry characters that
# charset rejects — which would fail the test for the wrong reason.
TMP_DIR="$(mktemp -d "/tmp/lv-ui-gate-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_HOME="$TMP_DIR/home"
STUB_BIN="$TMP_DIR/stubbin"
LOG_FILE="$FAKE_HOME/Library/Logs/localvoxtral-ui-gate.log"
ARTIFACT_ROOT="$FAKE_HOME/localvoxtral-ui-artifacts"
mkdir -p "$FAKE_HOME/bin" "$STUB_BIN" "$ARTIFACT_ROOT" "$(dirname "$LOG_FILE")"
: >"$LOG_FILE"

LOCK_STATE=unlocked

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

# --- stubs -----------------------------------------------------------------
# Named so they shadow only what the gate calls out to; sed/awk/date/mkdir
# stay real.

cat >"$STUB_BIN/say" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_SAY_LOG"
STUB

cat >"$STUB_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat >"$STUB_BIN/open" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_OPEN_LOG"
exit "${STUB_OPEN_STATUS:-0}"
STUB

cat >"$STUB_BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
[[ -n "${STUB_PGREP_PID:-}" ]] || exit 1
printf '%s\n' "$STUB_PGREP_PID"
STUB

# `ps -p <pid> -o lstart=` and `ps -p <pid> -o comm=` are the two halves of the
# gate's pid-reuse defence.
cat >"$STUB_BIN/ps" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    lstart=) printf '%s\n' "${STUB_PS_LSTART:-Mon Aug 24 09:00:00 2026}"; exit 0 ;;
    comm=) printf '%s\n' "${STUB_PS_COMM:-/nonexistent}"; exit 0 ;;
  esac
done
exit 1
STUB

cat >"$STUB_BIN/screencapture" <<'STUB'
#!/usr/bin/env bash
out="${!#}"
printf '%s\n' "$*" >>"$STUB_SCREENCAPTURE_LOG"
printf 'PNGSTUB%s' "${STUB_SHOT_PAYLOAD:-...}" >"$out"
STUB

# Stands in for `swift <helper.swift> <subcommand> ...`: the gate's only route
# to CoreGraphics/AX. $2 is the subcommand, $3.. the helper's own arguments.
cat >"$STUB_BIN/swift" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_SWIFT_LOG"
case "$2" in
  preflight)
    echo "accessibility=1"; echo "screen_recording=1"; echo "frontmost_pid=$3"
    ;;
  window)
    [[ -n "${STUB_WINDOW_RESULT:-}" ]] || exit 1
    printf '%s\n' "$STUB_WINDOW_RESULT"
    ;;
  termwindow)
    printf '9001 %s\n' "$3"
    ;;
  axdump)
    echo '[{"role":"AXWindow","children":[]}]'
    ;;
  axclick | axtype | key | termaction)
    echo ok
    ;;
  *)
    exit 1
    ;;
esac
STUB

cat >"$STUB_BIN/ioreg" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${STUB_IOREG_FILE:-}" && -f "${STUB_IOREG_FILE}" ]]; then
  cat "$STUB_IOREG_FILE"
  exit 0
fi
echo '"HIDIdleTime" = 42000000000'
STUB

cat >"$STUB_BIN/pmset" <<'STUB'
#!/usr/bin/env bash
echo "Now drawing from 'AC Power'"
STUB

cat >"$STUB_BIN/defaults" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DEFAULTS_LOG"
STUB

chmod +x "$STUB_BIN"/*

install -m 0755 "$LOCK_PROBE_SRC" "$FAKE_HOME/bin/localvoxtral-screen-lock-state.sh"

# --- fixtures --------------------------------------------------------------

make_bundle() { # <name> <bundle-id> <executable> <dogfood-stamp:true|absent>
  local dir="$ARTIFACT_ROOT/$1" stamp=""
  mkdir -p "$dir/Contents/MacOS"
  : >"$dir/Contents/MacOS/$3"
  chmod +x "$dir/Contents/MacOS/$3"
  if [[ "$4" == "true" ]]; then
    stamp=$'  <key>LVXDogfoodCapture</key>\n  <true/>'
  fi
  cat >"$dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$3</string>
  <key>CFBundleIdentifier</key>
  <string>$2</string>
$stamp
</dict>
</plist>
PLIST
  printf '%s\n' "$dir"
}

CLEAN_APP="$(make_bundle localvoxtral.app com.localvoxtral.app localvoxtral absent)"
DOGFOOD_APP="$(make_bundle localvoxtral-dogfood.app com.localvoxtral.app localvoxtral true)"
IMPOSTOR_APP="$(make_bundle Mail.app com.apple.mail Mail absent)"

# --- gate runner -----------------------------------------------------------

GATE_STATUS=0
GATE_STDOUT=""
GATE_STDERR=""

run_gate() { # <command> [env assignments...]
  local command="$1"
  shift
  local out_file="$TMP_DIR/out" err_file="$TMP_DIR/err"
  GATE_STATUS=0
  env -i \
    PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$FAKE_HOME" \
    SSH_ORIGINAL_COMMAND="$command" \
    LV_UI_LOCK_PROBE="$FAKE_HOME/bin/localvoxtral-screen-lock-state.sh" \
    LV_SCREEN_LOCK_STATE="${LOCK_STATE:-unlocked}" \
    STUB_SAY_LOG="$TMP_DIR/say.log" \
    STUB_OPEN_LOG="$TMP_DIR/open.log" \
    STUB_SWIFT_LOG="$TMP_DIR/swift.log" \
    STUB_DEFAULTS_LOG="$TMP_DIR/defaults.log" \
    STUB_SCREENCAPTURE_LOG="$TMP_DIR/screencapture.log" \
    "$@" \
    bash "$GATE" >"$out_file" 2>"$err_file" || GATE_STATUS=$?
  GATE_STDOUT="$(cat "$out_file")"
  GATE_STDERR="$(cat "$err_file")"
}

log_tail() {
  tail -n 1 "$LOG_FILE" 2>/dev/null || true
}

assert_denied() { # <command> <description> [env...]
  local command="$1" description="$2"
  shift 2
  local before after
  before="$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)"
  run_gate "$command" "$@"
  (( GATE_STATUS == 126 )) \
    || fail "$description: expected exit 126, got $GATE_STATUS (stderr: $GATE_STDERR)"
  [[ "$GATE_STDERR" == *"denied command"* ]] \
    || fail "$description: stderr did not say 'denied command' ($GATE_STDERR)"
  after="$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)"
  (( after > before )) || fail "$description: nothing was appended to the gate log"
  [[ "$(log_tail)" == *" DENY "* ]] \
    || fail "$description: last log line is not a DENY line: $(log_tail)"
  [[ "$(log_tail)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]] \
    || fail "$description: DENY line has no timestamp: $(log_tail)"
  pass "denied: $description"
}

assert_allowed() { # <command> <description> [env...]
  local command="$1" description="$2"
  shift 2
  run_gate "$command" "$@"
  (( GATE_STATUS == 0 )) \
    || fail "$description: expected exit 0, got $GATE_STATUS (stderr: $GATE_STDERR)"
  [[ "$(log_tail)" == *" ALLOW "* ]] \
    || fail "$description: no ALLOW line was logged (last line: $(log_tail))"
  pass "allowed: $description"
}

write_app_state() { # <pid>
  local pid="$1" dir="$FAKE_HOME/.localvoxtral-ui-gate"
  mkdir -p "$dir"
  {
    printf 'pid=%s\n' "$pid"
    printf 'bundle=%s\n' "$CLEAN_APP"
    printf 'identity=%s|%s\n' "Mon Aug 24 09:00:00 2026" "$CLEAN_APP/Contents/MacOS/localvoxtral"
    printf 'dogfood=0\n'
  } >"$dir/app.state"
}

clear_state() {
  rm -rf "$FAKE_HOME/.localvoxtral-ui-gate"
}

APP_ENV=(
  STUB_PS_LSTART="Mon Aug 24 09:00:00 2026"
  STUB_PS_COMM="$CLEAN_APP/Contents/MacOS/localvoxtral"
)

echo "== 1. unknown verbs and shell escapes =="

assert_denied 'echo pwned' 'echo pwned (the README deny check)'
assert_denied '' 'empty command'
assert_denied 'bash -lc id' 'bash -lc'
assert_denied 'sh -c id' 'sh -c'
assert_denied 'eval id' 'eval'
assert_denied 'exec id' 'exec'
assert_denied 'screenshot' 'unknown verb that looks plausible'
assert_denied 'STATE' 'verb allowlist is case sensitive'
assert_denied 'state; id' 'command chaining with ;'
assert_denied 'state && id' 'command chaining with &&'
assert_denied 'state | id' 'pipeline'
assert_denied 'state > /tmp/x' 'output redirection'
assert_denied 'state `id`' 'backtick substitution'
assert_denied 'state $(id)' 'dollar-paren substitution'
assert_denied 'state ${HOME}' 'parameter expansion'
assert_denied 'state *' 'glob'
assert_denied 'quit; rm -rf ~' 'chaining onto an allowed verb'
# A newline must both be denied AND collapse to a single log line: otherwise
# the denied text writes its own second line, which can be made to read like a
# genuine ALLOW entry.
assert_denied "$(printf 'state\nid')" 'embedded newline (only line 1 would ever parse)'
[[ "$(log_tail)" == *'state?id'* ]] \
  || fail "the newline in a denied command was not neutralised in the log: $(log_tail)"

assert_denied "$(printf 'state\tid')" 'embedded tab as an argument separator'
assert_denied "state $(head -c 4000 /dev/zero | tr '\0' 'a')" 'over-long command'

echo "== 2. per-verb argument validation =="

assert_denied 'state extra' 'state takes no arguments'
assert_denied 'quit now' 'quit takes no arguments'
assert_denied 'launch' 'launch without an artifact'
assert_denied "launch --wat $CLEAN_APP" 'launch with an unknown flag'
assert_denied "launch $CLEAN_APP $DOGFOOD_APP" 'launch with two artifacts'
assert_denied 'key' 'key without a name'
assert_denied 'key escape tab' 'key with two names'
assert_denied 'key cmd+q' 'key outside the three-entry allowlist'
assert_denied 'key space' 'another key outside the allowlist'
assert_denied 'shot fullscreen' 'shot of something that is not a window kind'
assert_denied 'shot screen' 'shot screen (no full-screen capture exists)'
assert_denied 'shot settings 2' 'shot settings with a stray index'
assert_denied 'shot window' 'shot window without an index'
assert_denied 'shot window 0' 'shot window index 0'
assert_denied 'shot window abc' 'shot window with a non-numeric index'
assert_denied 'shot window 1 2' 'shot with too many arguments'
assert_denied 'ax' 'ax without a subverb'
assert_denied 'ax poke role=AXButton' 'unknown ax subverb'
assert_denied 'ax dump menus' 'ax dump of an unknown pane'
assert_denied 'ax dump window' 'ax dump window without an index'
assert_denied 'ax click' 'ax click without a selector'
assert_denied 'ax click title' 'selector with no operator'
assert_denied 'ax click bogus=1' 'selector with an unknown key'
assert_denied 'ax click index=1' 'selector naming no matchable attribute'
assert_denied 'ax click title=' 'selector with an empty value'
assert_denied 'ax click role=AXButton,' 'selector with a trailing comma'
assert_denied 'ax click window=zero,title=A' 'selector with a non-numeric window index'
assert_denied 'ax type role=AXTextField hello' 'ax type without the -- separator'
assert_denied 'ax type role=AXTextField --' 'ax type with an empty text'
assert_denied 'term' 'term without a subverb'
assert_denied 'term open' 'term open without a terminal'
assert_denied 'term open ghostty' 'term open without a command'
assert_denied 'term focus' 'term focus without an id'
assert_denied 'term focus term-1 term-2' 'term focus with two ids'
assert_denied 'term close ../../etc' 'term close with a path as an id'
assert_denied 'term focus term-9' 'term focus on an id this gate never opened'

echo "== 3. launch refuses anything that is not a localvoxtral bundle =="

assert_denied "launch $IMPOSTOR_APP" 'launch of another vendor .app under the root'
assert_denied 'launch /Applications/Mail.app' 'launch outside the allowlisted roots'
assert_denied "launch $ARTIFACT_ROOT/../../etc" 'launch with .. in the path'
assert_denied "launch $ARTIFACT_ROOT/missing.app" 'launch of a path that does not exist'
assert_denied "launch --dogfood $CLEAN_APP" 'launch --dogfood on an unstamped bundle'

echo "== 4. term open is not a shell verb =="

assert_denied 'term open ghostty bash -c id' 'term open running bash'
assert_denied 'term open ghostty sh' 'term open running sh'
assert_denied 'term open ghostty ssh builder@mac' 'term open running ssh'
assert_denied 'term open ghostty osascript -e id' 'term open running osascript'
assert_denied 'term open bash herdr' 'a shell in the terminal position'
assert_denied 'term open ghostty herdr;id' 'metacharacter inside an allowlisted command'
assert_denied 'term open ghostty herdr `id`' 'backticks in a term command'
assert_denied 'term open ghostty herdr a b c d e f g h i j k l m' 'more tokens than the cap'

echo "== 5. the screen lock is a hard refusal (fail closed) =="

write_app_state 4242
LOCK_STATE=locked
for locked_command in \
  "launch $CLEAN_APP" \
  'shot settings' \
  'ax dump all' \
  'ax click role=AXButton,title=General' \
  'ax type role=AXTextField -- hello' \
  'key escape' \
  'term open ghostty herdr' \
  'term focus term-1'; do
  assert_denied "$locked_command" "locked screen refuses: $locked_command" \
    "${APP_ENV[@]}" STUB_PGREP_PID=4242 STUB_WINDOW_RESULT="7 4242"
done

LOCK_STATE=no-session
assert_denied 'shot settings' 'no console session refuses shot' \
  "${APP_ENV[@]}" STUB_WINDOW_RESULT="7 4242"
LOCK_STATE=error
assert_denied 'shot settings' 'undeterminable lock state refuses shot' \
  "${APP_ENV[@]}" STUB_WINDOW_RESULT="7 4242"

# A missing probe must deny, not fall through: this gate drives the owner's
# personal desktop, so "cannot tell" is never "go ahead".
GATE_STATUS=0
env -i PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" \
  SSH_ORIGINAL_COMMAND='shot settings' \
  LV_UI_LOCK_PROBE="$FAKE_HOME/bin/does-not-exist.sh" \
  bash "$GATE" >/dev/null 2>&1 || GATE_STATUS=$?
(( GATE_STATUS == 126 )) || fail "missing lock probe: expected 126, got $GATE_STATUS"
grep -q 'lock probe missing' "$LOG_FILE" || fail "missing lock probe was not logged with its reason"
pass "denied: a missing lock probe fails closed"

# `state` is the one verb that still answers while locked — deciding whether it
# is safe to drive is exactly what it is for.
LOCK_STATE=locked
run_gate 'state' "${APP_ENV[@]}"
(( GATE_STATUS == 0 )) || fail "state should answer on a locked screen (got $GATE_STATUS: $GATE_STDERR)"
[[ "$GATE_STDOUT" == *'"screen_lock":"locked"'* ]] \
  || fail "state did not report the locked screen: $GATE_STDOUT"
pass "allowed: state answers on a locked screen and reports it"
LOCK_STATE=unlocked

echo "== 6. shot captures only a window owned by the launched pid =="

clear_state
run_gate 'shot settings' "${APP_ENV[@]}"
(( GATE_STATUS == 126 )) || fail "shot with no app under test should be denied (got $GATE_STATUS)"
pass "denied: shot before any launch"

# A resolved window owned by SOMETHING ELSE is refused — the invariant that
# keeps this verb away from the owner's mail, browser and messages.
write_app_state 4242
assert_denied 'shot settings' 'shot of a window owned by another pid' \
  "${APP_ENV[@]}" STUB_WINDOW_RESULT="8123 999"
grep -q 'owned by pid 999' "$LOG_FILE" \
  || fail "the foreign-owner refusal was not logged with the owner pid"

assert_denied 'shot settings' 'shot when the window lookup returns garbage' \
  "${APP_ENV[@]}" STUB_WINDOW_RESULT="not-a-window"

# Same fixture, correct owner: the capture happens, base64 on stdout only.
run_gate 'shot settings' "${APP_ENV[@]}" STUB_WINDOW_RESULT="8123 4242"
(( GATE_STATUS == 0 )) || fail "shot of the app's own window failed: $GATE_STDERR"
# Round-trip through the SAME base64 binary: BSD and GNU disagree on the
# decode flag (-D vs -d), and this suite runs on both.
EXPECTED_B64="$(printf 'PNGSTUB...' | base64 | tr -d '\n')"
[[ "$(printf '%s' "$GATE_STDOUT" | tr -d '\n')" == "$EXPECTED_B64" ]] \
  || fail "shot stdout was not the base64 of the captured file: $GATE_STDOUT"
[[ "$GATE_STDERR" == *"window 8123"* ]] || fail "shot did not report the window id on stderr"
grep -q -- '-l 8123' "$TMP_DIR/screencapture.log" \
  || fail "screencapture was not scoped to the resolved window id"
# The image is the one thing this gate produces that is worth stealing; no exit
# path may leave it behind.
if compgen -G "$FAKE_HOME/.localvoxtral-ui-gate/shot.*" >/dev/null; then
  fail "shot left the captured window image on disk"
fi
pass "allowed: shot of the app-under-test's own window, and the file does not survive it"

# Pid reuse: the recorded pid is live but is a different process now.
assert_denied 'shot settings' 'shot after the recorded pid was recycled' \
  STUB_PS_LSTART="Tue Aug 25 11:11:11 2026" \
  STUB_PS_COMM="$CLEAN_APP/Contents/MacOS/localvoxtral" \
  STUB_WINDOW_RESULT="8123 4242"

echo "== 7. launch happy path, warning, and recorded identity =="

clear_state
: >"$TMP_DIR/say.log"
run_gate "launch $CLEAN_APP" "${APP_ENV[@]}" STUB_PGREP_PID=4242
(( GATE_STATUS == 0 )) || fail "launch of a valid bundle failed: $GATE_STDERR"
[[ "$GATE_STDOUT" == *"launched pid=4242"* ]] || fail "launch did not report the pid: $GATE_STDOUT"
grep -q "pid=4242" "$FAKE_HOME/.localvoxtral-ui-gate/app.state" \
  || fail "launch did not record the pid"
grep -q "identity=Mon Aug 24 09:00:00 2026|$CLEAN_APP/Contents/MacOS/localvoxtral" \
  "$FAKE_HOME/.localvoxtral-ui-gate/app.state" \
  || fail "launch did not record the start time + executable identity"
grep -q "taking control in 3" "$TMP_DIR/say.log" \
  || fail "launch did not speak the takeover warning (owner rule)"
grep -q "done" "$TMP_DIR/say.log" \
  || fail "launch did not announce completion (owner rule)"
grep -q -- "-n $CLEAN_APP" "$TMP_DIR/open.log" \
  || fail "launch did not open the validated bundle"
pass "allowed: launch records identity, warns audibly, announces completion"

# --dogfood requires the Info.plist stamp AND arms the runtime opt-in.
clear_state
: >"$TMP_DIR/defaults.log"
run_gate "launch --dogfood $DOGFOOD_APP" \
  STUB_PS_LSTART="Mon Aug 24 09:00:00 2026" \
  STUB_PS_COMM="$DOGFOOD_APP/Contents/MacOS/localvoxtral" \
  STUB_PGREP_PID=4343
(( GATE_STATUS == 0 )) || fail "launch --dogfood of a stamped bundle failed: $GATE_STDERR"
grep -q 'debug.dogfood_capture_enabled' "$TMP_DIR/defaults.log" \
  || fail "launch --dogfood did not arm the capture opt-in"
pass "allowed: launch --dogfood on a stamped bundle"

echo "== 8. ax and key verbs =="

clear_state
write_app_state 4242
assert_allowed 'ax dump all' 'ax dump of the app under test' "${APP_ENV[@]}"
[[ "$GATE_STDOUT" == '[{"role":"AXWindow"'* ]] || fail "ax dump did not emit the helper's JSON"
assert_allowed 'ax click role=AXButton,title~Text+Processing' 'ax click by role and title' "${APP_ENV[@]}"
grep -q 'axclick 4242 role=AXButton,title~Text+Processing' "$TMP_DIR/swift.log" \
  || fail "ax click did not scope the helper call to the launched pid"
assert_allowed 'key escape' 'key escape' "${APP_ENV[@]}"
assert_allowed 'key tab' 'key tab' "${APP_ENV[@]}"
assert_allowed 'key return' 'key return' "${APP_ENV[@]}"

# Typed text takes a wider charset than any other argument, and is the one
# thing the log must never keep.
: >"$LOG_FILE"
assert_allowed 'ax type role=AXTextField,title=Endpoint -- sk-secret-token-42!' \
  'ax type with a secret-looking value' "${APP_ENV[@]}"
grep -q -- '-- <redacted>' "$LOG_FILE" || fail "ax type text was not redacted in the log"
if grep -q 'sk-secret-token-42' "$LOG_FILE"; then
  fail "ax type leaked the typed text into the log"
fi
grep -q 'axtype 4242 role=AXTextField,title=Endpoint sk-secret-token-42!' "$TMP_DIR/swift.log" \
  || fail "ax type did not pass the text to the helper as argv"
pass "ax type redacts the typed text in the log but still types it"

echo "== 9. term verbs =="

clear_state
: >"$LOG_FILE"
: >"$TMP_DIR/open.log"
run_gate 'term open ghostty herdr agent list' STUB_PGREP_PID=$$
(( GATE_STATUS == 0 )) || fail "term open of an allowlisted command failed: $GATE_STDERR"
[[ "$GATE_STDOUT" == "opened term-1 "* ]] || fail "term open did not report an id: $GATE_STDOUT"
grep -q 'command=herdr agent list' "$LOG_FILE" \
  || fail "term open did not log the command in full"
SCRIPT_FILE="$(find "$FAKE_HOME/.localvoxtral-ui-gate/terms" -name '*.command' | head -n 1)"
[[ -n "$SCRIPT_FILE" ]] || fail "term open did not write a launcher script"
grep -q '^exec herdr agent list$' "$SCRIPT_FILE" \
  || fail "launcher script does not exec exactly the validated argv: $(cat "$SCRIPT_FILE")"
pass "allowed: term open runs an allowlisted command and logs it in full"

assert_allowed 'term focus term-1' 'term focus on a window this gate opened'
assert_allowed 'term close term-1' 'term close on a window this gate opened'
assert_denied 'term focus term-1' 'term focus after the window was closed'

echo "== 10. quit terminates only the recorded process =="

clear_state
tail -f /dev/null &
VICTIM_PID=$!
write_app_state "$VICTIM_PID"
run_gate 'quit' "${APP_ENV[@]}"
(( GATE_STATUS == 0 )) || fail "quit failed: $GATE_STDERR"
wait "$VICTIM_PID" 2>/dev/null || true
if kill -0 "$VICTIM_PID" 2>/dev/null; then
  fail "quit did not terminate the recorded process"
fi
if [[ -f "$FAKE_HOME/.localvoxtral-ui-gate/app.state" ]]; then
  fail "quit left the app state behind"
fi
pass "allowed: quit terminates the recorded pid and clears the state"

echo "== 11. the shared lock probe's ioreg arm =="

PROBE="$FAKE_HOME/bin/localvoxtral-screen-lock-state.sh"
FIXTURES="$TMP_DIR/ioreg"
mkdir -p "$FIXTURES"

cat >"$FIXTURES/locked.plist" <<'XML'
<plist><dict><key>IOConsoleUsers</key><array><dict>
  <key>kCGSSessionOnConsoleKey</key><true/>
  <key>CGSSessionScreenIsLocked</key><true/>
</dict></array></dict></plist>
XML
cat >"$FIXTURES/unlocked.plist" <<'XML'
<plist><dict><key>IOConsoleUsers</key><array><dict>
  <key>kCGSSessionOnConsoleKey</key><true/>
</dict></array></dict></plist>
XML
cat >"$FIXTURES/switched-away.plist" <<'XML'
<plist><dict><key>IOConsoleUsers</key><array><dict>
  <key>kCGSSessionOnConsoleKey</key><false/>
  <key>CGSSessionScreenIsLocked</key><true/>
</dict></array></dict></plist>
XML
cat >"$FIXTURES/no-console.plist" <<'XML'
<plist><dict><key>IOConsoleUsers</key><array/></dict></plist>
XML
echo 'garbage' >"$FIXTURES/garbage.plist"

expect_lock_state() { # <fixture> <expected>
  local actual
  actual="$(env -i PATH="/usr/bin:/bin" \
    LV_SCREEN_LOCK_SWIFT_CMD=/nonexistent-swift \
    LV_SCREEN_LOCK_IOREG_CMD="cat $FIXTURES/$1" \
    bash "$PROBE")"
  [[ "$actual" == "$2" ]] || fail "lock probe on $1: expected $2, got $actual"
  pass "lock probe: $1 -> $2"
}

expect_lock_state locked.plist locked
expect_lock_state unlocked.plist unlocked
# A fast-user-switched-away session keeps stale lock keys; only the session
# actually on the console decides.
expect_lock_state switched-away.plist no-session
expect_lock_state no-console.plist no-session
expect_lock_state garbage.plist error

echo "== 12. the embedded Swift helper compiles =="

# The gate's CoreGraphics/AX helper is a heredoc, so nothing else ever type
# checks it — and a helper that does not compile turns every GUI verb into a
# runtime failure the owner only discovers by hand. On the macOS runner this
# is a real compile; on a Linux dev box it is skipped (and says so).
if command -v swiftc >/dev/null 2>&1; then
  HELPER_DIR="$TMP_DIR/helper"
  mkdir -p "$HELPER_DIR"
  awk '/^  cat >"\$HELPER_PATH" <<.SWIFT.$/ { capture = 1; next }
       capture && /^SWIFT$/ { exit }
       capture { print }' "$GATE" >"$HELPER_DIR/main.swift"
  [[ -s "$HELPER_DIR/main.swift" ]] \
    || fail "could not extract the Swift helper from the gate (heredoc markers changed?)"
  grep -q 'AXUIElementCreateApplication' "$HELPER_DIR/main.swift" \
    || fail "the extracted Swift helper does not look like the helper"
  ( cd "$HELPER_DIR" && swiftc -typecheck main.swift ) \
    || fail "the embedded Swift helper does not type check"
  pass "the embedded Swift helper type checks"
else
  printf 'SKIP: swiftc not available — the embedded Swift helper was not type checked\n'
fi

echo
echo "ui gate tests passed"
