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
INSTALLER="$ROOT_DIR/scripts/mac/install-ui-artifact.sh"
TRY_PR="$ROOT_DIR/scripts/try-pr.sh"
LOCK_PROBE_SRC="$ROOT_DIR/scripts/ci/screen-lock-state.sh"
# Deliberately /tmp and not $TMPDIR: fixture bundle paths are fed through the
# gate's token charset, and a macOS per-user $TMPDIR can carry characters that
# charset rejects — which would fail the test for the wrong reason.
#
# Resolved with `pwd -P` because `launch` resolves its argument the same way:
# on macOS /tmp is a symlink to /private/tmp, so an unresolved fixture path
# would never equal the path the gate records and passes to `open`.
TMP_DIR="$(cd "$(mktemp -d "/tmp/lv-ui-gate-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_HOME="$TMP_DIR/home"
STUB_BIN="$TMP_DIR/stubbin"
LOG_FILE="$FAKE_HOME/Library/Logs/localvoxtral-ui-gate.log"
ARTIFACT_ROOT="$FAKE_HOME/localvoxtral-ui-artifacts"
mkdir -p "$FAKE_HOME/bin" "$STUB_BIN" "$ARTIFACT_ROOT" "$(dirname "$LOG_FILE")"
# Pinned rather than left to the runner's umask: install-ui-artifact.sh refuses
# a group/other-writable root, and a umask of 002 would otherwise make that
# refusal fire on the happy path.
chmod 0700 "$ARTIFACT_ROOT"
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

# `pgrep -x localvoxtral` asks a different question from every other pgrep the
# gate runs — "is ANY localvoxtral running", the refusal to launch beside an
# instance this gate did not start — so it gets its own answer. The bundle-path
# lookup (`-n -f`) and the terminal lookup (`-n -x Ghostty`) keep the old one.
cat >"$STUB_BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
last=""
for last in "$@"; do :; done
if [[ "$last" == "localvoxtral" ]]; then
  [[ -n "${STUB_PGREP_RUNNING:-}" ]] || exit 1
  printf '%s\n' "$STUB_PGREP_RUNNING"
  exit 0
fi
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
# Last argument is the output file. Walked rather than "${!#}" so this runs
# unchanged under the Mac's bash 3.2.
out=""
for out in "$@"; do :; done
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
  menuopen | menuclick | menudismiss)
    [[ -z "${STUB_MENU_FAIL:-}" ]] || exit 1
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
  make_bundle_in "$ARTIFACT_ROOT" "$@"
}

make_bundle_in() { # <parent> <name> <bundle-id> <executable> <dogfood-stamp>
  local parent="$1"
  shift
  local dir="$parent/$1" stamp=""
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

# The machine-local conf is the ONLY way `term open` ever becomes usable, so
# the opt-in tests go through the real file rather than an env override.
GATE_CONF="$FAKE_HOME/.localvoxtral-ui-gate.conf"
write_conf() {
  printf '%s\n' "$@" >"$GATE_CONF"
}
clear_conf() {
  rm -f "$GATE_CONF"
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
assert_denied 'menu' 'menu without a subverb'
assert_denied 'menu poke' 'unknown menu subverb'
assert_denied 'menu open now' 'menu open with an argument'
assert_denied 'menu dismiss all' 'menu dismiss with an argument'
assert_denied 'menu click' 'menu click without an item title'
assert_denied 'menu click Settings Advanced' 'menu click with two title words (use + for a space)'
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
assert_denied 'term open ghostty python3 -c id' 'term open running python3'
assert_denied 'term open bash lv-attach' 'a shell in the terminal position'
assert_denied 'term open ghostty lv-attach;id' 'metacharacter inside a command' \
  LV_UI_TERM_COMMANDS=lv-attach
assert_denied 'term open ghostty lv-attach `id`' 'backticks in a term command' \
  LV_UI_TERM_COMMANDS=lv-attach
assert_denied 'term open ghostty lv-attach a b c d e f g h i j k l m' 'more tokens than the cap' \
  LV_UI_TERM_COMMANDS=lv-attach

# An agent CLI is a shell wearing one allowlisted name: only the first token is
# checked and nothing inspects flags, so `claude -p`, `codex exec`,
# `opencode run` and `herdr agent start` each execute arbitrary code as the GUI
# user. An earlier revision shipped all four in the DEFAULT allowlist.
assert_denied 'term open ghostty claude' 'term open running claude'
assert_denied 'term open ghostty codex' 'term open running codex'
assert_denied 'term open ghostty opencode' 'term open running opencode'
assert_denied 'term open ghostty herdr' 'term open running herdr'
assert_denied 'term open ghostty aider' 'term open running another agent CLI'
assert_denied 'term open ghostty claude --dangerously-skip-permissions -p hello' \
  'the exact escape: claude --dangerously-skip-permissions -p <prompt>'
assert_denied 'term open ghostty codex exec whatever' 'codex exec'
assert_denied 'term open ghostty opencode run whatever' 'opencode run'
assert_denied 'term open ghostty herdr agent start' 'herdr agent start'

# The denylist is checked before the allowlist and is assigned after the conf
# is sourced, so a machine-local file cannot re-add any of these.
write_conf 'LV_UI_TERM_COMMANDS="claude codex opencode herdr bash ssh lv-attach"'
assert_denied 'term open ghostty claude -p hi' 'conf-allowlisted claude is STILL denied'
assert_denied 'term open ghostty codex exec x' 'conf-allowlisted codex is STILL denied'
assert_denied 'term open ghostty opencode run x' 'conf-allowlisted opencode is STILL denied'
assert_denied 'term open ghostty herdr agent start' 'conf-allowlisted herdr is STILL denied'
assert_denied 'term open ghostty bash -c id' 'conf-allowlisted bash is STILL denied'
assert_denied 'term open ghostty ssh host' 'conf-allowlisted ssh is STILL denied'
clear_conf

# With no conf at all the allowlist is empty, so every command denies — the
# verb is opt-in, not opt-out.
assert_denied 'term open ghostty lv-attach' 'the default allowlist is empty'
[[ "$(log_tail)" == *"no allowlisted commands"* ]] \
  || fail "the empty-allowlist denial did not say why: $(log_tail)"

# Pin the DEFAULT in the source, so re-adding a name fails here and not in the
# field. The default must be empty; anything else is a review conversation.
DEFAULT_LINE="$(grep -n 'LV_UI_TERM_COMMANDS="[$]{LV_UI_TERM_COMMANDS' "$GATE" | head -n 1)"
[[ "$DEFAULT_LINE" == *'LV_UI_TERM_COMMANDS="${LV_UI_TERM_COMMANDS:-}"' ]] \
  || fail "the default term-open allowlist is no longer empty: $DEFAULT_LINE"
FORBIDDEN_BLOCK="$(awk '/^LV_UI_TERM_FORBIDDEN=/ { capture = 1 } capture { print } capture && /"$/ { exit }' "$GATE")"
[[ -n "$FORBIDDEN_BLOCK" ]] || fail "the permanent denylist is gone"
for forbidden in bash sh zsh ssh osascript python3 claude codex opencode herdr aider; do
  grep -qw "$forbidden" <<<"$FORBIDDEN_BLOCK" \
    || fail "$forbidden is no longer on the permanent denylist"
done
pass "the default allowlist is empty and the permanent denylist still names every shell and agent CLI"

echo "== 5. the screen lock is a hard refusal (fail closed) =="

write_app_state 4242
# `term open` is opted in for this block on purpose: with the allowlist empty
# it would deny anyway, and the test would pass without ever reaching the lock.
write_conf 'LV_UI_TERM_COMMANDS="lv-attach"'
LOCK_STATE=locked
for locked_command in \
  "launch $CLEAN_APP" \
  'shot settings' \
  'ax dump all' \
  'ax click role=AXButton,title=General' \
  'ax type role=AXTextField -- hello' \
  'key escape' \
  'term open ghostty lv-attach' \
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
clear_conf

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

# A second launch while one is recorded would orphan that pid and silently
# retarget every later verb.
assert_denied "launch $CLEAN_APP" 'launch while an app is already under test' \
  "${APP_ENV[@]}" STUB_PGREP_PID=4242

# The same conflict without a recorded pid: the owner's daily driver, started
# from Finder or try-pr.sh. The gate can neither address it (every verb reads
# app.state) nor quit it, and a second instance re-registers the global hotkey
# and fights for the speechd/polishd ports 8471/8472. Field check 2026-08-29:
# launch would have started one beside pid 91687.
clear_state
assert_denied "launch $CLEAN_APP" 'launch beside a localvoxtral this gate did not start' \
  "${APP_ENV[@]}" STUB_PGREP_PID=4242 STUB_PGREP_RUNNING=91687
[[ "$(log_tail)" == *"91687"* ]] \
  || fail "the foreign-instance denial did not name the running pid: $(log_tail)"
[[ "$(log_tail)" == *"this gate did not start it"* ]] \
  || fail "the foreign-instance denial did not say why: $(log_tail)"
# It must be a refusal, not a warning: nothing may have been opened.
: >"$TMP_DIR/open.log"
run_gate "launch $CLEAN_APP" "${APP_ENV[@]}" STUB_PGREP_PID=4242 STUB_PGREP_RUNNING=91687
[[ ! -s "$TMP_DIR/open.log" ]] \
  || fail "launch opened the bundle despite a foreign instance: $(cat "$TMP_DIR/open.log")"
pass "launch refuses beside an instance it did not start, and opens nothing"
clear_state

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
# The documented opt-in: a single-purpose wrapper the owner installs, which
# takes an identifier and execs one fixed command. Never a general-purpose tool.
write_conf 'LV_UI_TERM_COMMANDS="lv-attach"'
run_gate 'term open ghostty lv-attach pane-7' STUB_PGREP_PID=$$
(( GATE_STATUS == 0 )) || fail "term open of an allowlisted command failed: $GATE_STDERR"
[[ "$GATE_STDOUT" == "opened term-1 "* ]] || fail "term open did not report an id: $GATE_STDOUT"
grep -q 'command=lv-attach pane-7' "$LOG_FILE" \
  || fail "term open did not log the command in full"
SCRIPT_FILE="$(find "$FAKE_HOME/.localvoxtral-ui-gate/terms" -name '*.command' | head -n 1)"
[[ -n "$SCRIPT_FILE" ]] || fail "term open did not write a launcher script"
grep -q '^exec lv-attach pane-7$' "$SCRIPT_FILE" \
  || fail "launcher script does not exec exactly the validated argv: $(cat "$SCRIPT_FILE")"
pass "allowed: term open runs an opted-in wrapper and logs the command in full"

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

echo "== 12. a term-open window is not a lateral path into the app verbs =="

# The reason `term open` can be tolerated at all: every app-driving verb takes
# its pid from the app.state that `launch` wrote, and `launch` only ever
# records a validated localvoxtral bundle. With BOTH an app under test (4242)
# and a terminal this gate opened (this test's own pid) recorded, no verb may
# ever address the terminal.
SELF_PID=$$
clear_state
write_conf 'LV_UI_TERM_COMMANDS="lv-attach"'
run_gate 'term open ghostty lv-attach pane-7' STUB_PGREP_PID="$SELF_PID"
(( GATE_STATUS == 0 )) || fail "scoping fixture: term open failed: $GATE_STDERR"
write_app_state 4242
: >"$TMP_DIR/swift.log"

for scoped_command in \
  'ax dump all' \
  'ax click role=AXButton,title=General' \
  'ax type role=AXTextField,title=Endpoint -- typed' \
  'key escape'; do
  run_gate "$scoped_command" "${APP_ENV[@]}"
  (( GATE_STATUS == 0 )) || fail "scoping fixture: '$scoped_command' failed: $GATE_STDERR"
done
run_gate 'shot settings' "${APP_ENV[@]}" STUB_WINDOW_RESULT="8123 4242"
(( GATE_STATUS == 0 )) || fail "scoping fixture: shot failed: $GATE_STDERR"

# Every helper call that can read or actuate the UI carries 4242.
while read -r line; do
  case "$line" in
    *" axdump "* | *" axclick "* | *" axtype "* | *" key "* | *" window "*)
      [[ "$line" == *" 4242 "* || "$line" == *" 4242" ]] \
        || fail "an app verb addressed a pid that is not the app under test: $line"
      ;;
  esac
done <"$TMP_DIR/swift.log"
# "$$(" would start a command substitution, so the pid goes through SELF_PID.
if grep -qE " (axdump|axclick|axtype|key|window) ${SELF_PID}( |$)" "$TMP_DIR/swift.log"; then
  fail "an app verb addressed the terminal's pid ($SELF_PID)"
fi
pass "ax dump/click/type, key and shot all address the app under test, never the terminal"

# And a window that belongs to the terminal is refused by the same ownership
# check that refuses any other application's window.
assert_denied 'shot settings' 'shot of a window owned by the terminal this gate opened' \
  "${APP_ENV[@]}" STUB_WINDOW_RESULT="9001 $SELF_PID"

# term focus/close do reach the terminal — but they carry no selector, no
# keystroke and no capture, so nothing typed by this gate can reach a shell.
: >"$TMP_DIR/swift.log"
assert_allowed 'term focus term-1' 'term focus reaches the terminal'
grep -q "termaction ${SELF_PID} " "$TMP_DIR/swift.log" \
  || fail "term focus did not address the terminal it opened"
if grep -qE " (axclick|axtype|key) " "$TMP_DIR/swift.log"; then
  fail "term focus reached an actuation subcommand"
fi
pass "term focus/close reach the terminal only to raise or close it"
clear_conf
clear_state

echo "== 13. the embedded Swift helper compiles =="

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

# ---------------------------------------------------------------------------
# 14. `state`'s live probes survive SIGPIPE
#
# Regression for the first-install failure (2026-08-28): `state` was reached,
# authorized, logged ALLOW — and then died with rc 141 and no output. `ioreg`
# writes far more than the first HIDIdleTime line, `awk` exits on that match,
# ioreg takes SIGPIPE, and `pipefail` + `set -e` killed the gate before it
# printed a byte. The suite could not see it because it stubs `ioreg`, so the
# guard here is twofold: the source shape (everywhere) and a real run (macOS).
# ---------------------------------------------------------------------------

echo
echo "== 14. state's live probes survive SIGPIPE =="

for probe in 'ioreg -c IOHIDSystem' 'pmset -g ps'; do
  line="$(grep -n -- "$probe" "$GATE" | head -n 1 || true)"
  [[ -n "$line" ]] || fail "no $probe probe found in the gate — did state change shape?"
done

# The ioreg substitution spans two lines; check the one carrying the pipeline.
grep -q "awk '/HIDIdleTime/.*|| true)\"" "$GATE" \
  || fail "the ioreg idle probe lost its \`|| true\` — state will die with rc 141 on a real Mac"
pass "the ioreg idle probe tolerates SIGPIPE"

grep -q 'pmset -g ps 2>/dev/null | head -n 1 || true' "$GATE" \
  || fail "the pmset power probe lost its \`|| true\`"
pass "the pmset power probe tolerates SIGPIPE"

# The source check above pins the shape; this runs the real thing. Extracting
# from the gate rather than restating the pipeline means a future edit is what
# gets tested, not a copy of it that can drift.
if command -v ioreg >/dev/null 2>&1 && command -v pmset >/dev/null 2>&1; then
  idle_expr="$(sed -n '/idle="\$(ioreg -c IOHIDSystem/,/|| true)"/p' "$GATE")"
  [[ -n "$idle_expr" ]] || fail "could not extract the idle probe from the gate"
  power_expr="$(grep -- 'pmset -g ps 2>/dev/null | head -n 1 || true' "$GATE" \
    | sed 's/^ *case "/probe_out="/; s/" in$/"/')"
  [[ -n "$power_expr" ]] || fail "could not extract the power probe from the gate"

  if ! ( set -euo pipefail; eval "$idle_expr"; printf '%s' "$idle" >/dev/null ) 2>/dev/null; then
    fail "the gate's real ioreg idle probe still fails under set -euo pipefail (rc 141 class)"
  fi
  pass "the idle probe runs clean against the real ioreg"

  if ! ( set -euo pipefail; eval "$power_expr" ) 2>/dev/null; then
    fail "the gate's real pmset power probe still fails under set -euo pipefail"
  fi
  pass "the power probe runs clean against the real pmset"
else
  printf 'SKIP: ioreg/pmset unavailable — the live SIGPIPE probes were not run\n'
fi

echo "== 15. menu — the verb that makes every other verb reachable =="

# Field check 2026-08-29: `launch` worked, `state` reported the app running,
# and `ax dump all` returned `[]` while `shot settings` reported no window.
# All correct: localvoxtral is a menu bar app and opens NO window at launch, so
# every window verb had nothing to address. `menu` is the missing first step.

clear_state
assert_denied 'menu open' 'menu open with no app under test'
assert_denied 'menu click Settings' 'menu click with no app under test'
assert_denied 'menu dismiss' 'menu dismiss with no app under test'

write_app_state 4242
LOCK_STATE=locked
assert_denied 'menu open' 'menu open while the screen is locked' "${APP_ENV[@]}"
assert_denied 'menu click Settings' 'menu click while the screen is locked' "${APP_ENV[@]}"
assert_denied 'menu dismiss' 'menu dismiss while the screen is locked' "${APP_ENV[@]}"
LOCK_STATE=unlocked

: >"$TMP_DIR/swift.log"
: >"$TMP_DIR/say.log"
assert_allowed 'menu open' 'menu open clicks the status item of the app under test' "${APP_ENV[@]}"
grep -q "menuopen 4242" "$TMP_DIR/swift.log" \
  || fail "menu open did not reach the helper for the app under test: $(cat "$TMP_DIR/swift.log")"
grep -q "taking control in 3" "$TMP_DIR/say.log" \
  || fail "menu open did not speak the takeover warning (owner rule)"
grep -q "done" "$TMP_DIR/say.log" \
  || fail "menu open did not announce completion (owner rule)"

: >"$TMP_DIR/swift.log"
assert_allowed 'menu click Settings' 'menu click by item title' "${APP_ENV[@]}"
grep -q "menuclick 4242 Settings" "$TMP_DIR/swift.log" \
  || fail "menu click did not pass the title through to the helper: $(cat "$TMP_DIR/swift.log")"

# A space in a title is spelled `+`, exactly as selector values are, because
# the token charset has no room for whitespace.
: >"$TMP_DIR/swift.log"
assert_allowed 'menu click Show+Log' 'menu click with + standing in for a space' "${APP_ENV[@]}"
grep -q "menuclick 4242 Show+Log" "$TMP_DIR/swift.log" \
  || fail "the + form was not passed through verbatim: $(cat "$TMP_DIR/swift.log")"

# Real menu titles carry characters the charset cannot express (localvoxtral's
# is "Settings…"). That is denied at the command level, which is why the helper
# matches by containment — `menu click Settings` is the way in.
assert_denied "$(printf 'menu click Settings\xe2\x80\xa6')" 'menu click with a non-ASCII title'

# Dismiss gives the screen back rather than taking it, so it does not warn —
# same rule as `quit`.
: >"$TMP_DIR/say.log"
: >"$TMP_DIR/swift.log"
assert_allowed 'menu dismiss' 'menu dismiss closes the app under test menu' "${APP_ENV[@]}"
grep -q "menudismiss 4242" "$TMP_DIR/swift.log" \
  || fail "menu dismiss did not reach the helper: $(cat "$TMP_DIR/swift.log")"
[[ ! -s "$TMP_DIR/say.log" ]] \
  || fail "menu dismiss spoke a takeover warning for a verb that steals nothing: $(cat "$TMP_DIR/say.log")"

# A helper that refuses must not be reported as success.
run_gate 'menu open' "${APP_ENV[@]}" STUB_MENU_FAIL=1
(( GATE_STATUS != 0 )) || fail "menu open reported success when the helper failed"
[[ "$GATE_STDERR" == *"status menu did not open"* ]] \
  || fail "menu open's failure message is unhelpful: $GATE_STDERR"
pass "a failed status-item click is a failure, not an ok"

# The scoping rule that section 12 pins for the other verbs, restated for
# `menu`: the pid is app.state's, so no other application's menu bar — the
# owner's, or a terminal this gate opened — is expressible.
: >"$TMP_DIR/swift.log"
run_gate 'menu open' "${APP_ENV[@]}"
while read -r line; do
  [[ "$line" == *"menu"* ]] || continue
  [[ "$line" == *" 4242"* ]] \
    || fail "a menu helper call did not carry the app-under-test pid: $line"
done <"$TMP_DIR/swift.log"
pass "menu addresses only the pid launch recorded"

# The shell verb and the helper subcommand have to land together: a verb whose
# helper case is missing fails only on the owner's desktop.
for subcommand in menuopen menuclick menudismiss; do
  grep -q "case \"$subcommand\":" "$GATE" \
    || fail "the Swift helper has no $subcommand subcommand"
done
# `AXExtrasMenuBar` is the whole mechanism: without it there is no status item.
grep -q 'AXExtrasMenuBar' "$GATE" \
  || fail "the helper no longer reaches the status item through AXExtrasMenuBar"
# The bounded messaging timeout is not a nicety: pressing a status item blocks
# the AX server for as long as the menu tracks, which without it hangs the SSH
# session (capture-readme-assets.sh needs `ignoring application responses` for
# exactly this reason).
grep -q 'AXUIElementSetMessagingTimeout' "$GATE" \
  || fail "the status-item press lost its messaging timeout — it can hang the gate"
pass "the menu helper subcommands, AXExtrasMenuBar and the messaging timeout are all present"

clear_state

echo "== 16. the artifact roots stay owner-only ground =="

# The roots are the whole reason `launch` is not "start any app on the owner's
# Mac": inside one, a bundle claiming com.localvoxtral.app is trusted. Add a
# world-writable directory and any local process can plant such a bundle and
# have the gate start it as the GUI user. The pressure to widen them is real —
# try-pr.sh extracts to /tmp — so the answer has to stay "move the install",
# and these assertions are what stops the other answer from landing quietly.

ROOTS_LINE="$(grep 'LV_UI_ARTIFACT_ROOTS="[$]{LV_UI_ARTIFACT_ROOTS' "$GATE" | head -n 1)"
[[ -n "$ROOTS_LINE" ]] || fail "could not find the default LV_UI_ARTIFACT_ROOTS in the gate"
ROOTS_DEFAULT="${ROOTS_LINE#*:-}"
ROOTS_DEFAULT="${ROOTS_DEFAULT%\}\"}"
[[ -n "$ROOTS_DEFAULT" ]] || fail "the default artifact-root list is empty: $ROOTS_LINE"

# Unquoted on purpose: word-splitting only. The entries are literal text here,
# so $HOME is NOT expanded — which is exactly what the prefix check wants.
for root in $ROOTS_DEFAULT; do
  case "$root" in
    '$HOME/'*) ;;
    *) fail "artifact root '$root' is not under \$HOME — only the owner may write a launchable root" ;;
  esac
  case "$root" in
    *'/tmp'* | *'/var/folders'* | *'/Users/Shared'* | *'/dev/shm'* | *'/var/tmp'*)
      fail "artifact root '$root' is a world-writable location — the gate would launch anything planted there" ;;
  esac
done
pass "every default artifact root is under \$HOME and none is a world-writable location"

mode_of() { # <path> -> octal permission bits (BSD stat, then GNU stat)
  # Validated per attempt, not chained with ||: GNU stat reads `-f` as
  # --file-system and prints a block of its own before failing.
  local mode
  mode="$(stat -f '%Lp' "$1" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]+$ ]] || mode="$(stat -c '%a' "$1" 2>/dev/null || true)"
  printf '%s\n' "$mode"
}

# The source pin above catches a widened list; this catches the same hole
# arriving through the filesystem — a root that exists but is group/other
# writable is as good as /tmp to an attacker.
for root in $ROOTS_DEFAULT; do
  expanded="$HOME${root#\$HOME}"
  [[ -d "$expanded" ]] || continue
  mode="$(mode_of "$expanded")"
  [[ "$mode" =~ ^[0-7]+$ ]] || fail "could not read the mode of $expanded"
  (( (8#$mode & 0022) == 0 )) \
    || fail "$expanded is mode $mode — group/other writable, so anyone local can plant a bundle the gate will launch"
  pass "existing artifact root $expanded is mode $mode (owner-writable only)"
done

# No script in this repo may hand the gate a world-writable root either.
for source_file in "$GATE" "$INSTALLER" "$TRY_PR"; do
  assignments="$(grep -h 'LV_UI_ARTIFACT_ROOTS=\|LV_UI_ARTIFACT_DEST_ROOT=' "$source_file" || true)"
  case "$assignments" in
    *'/tmp'* | *'/var/folders'* | *'/Users/Shared'* | *'/dev/shm'*)
      fail "$source_file points an artifact root at a world-writable directory" ;;
  esac
done
pass "no repo script points an artifact root at a world-writable directory"

echo "== 17. install-ui-artifact.sh puts bundles where launch can reach them =="

[[ -x "$INSTALLER" ]] || fail "$INSTALLER is not executable"

# The installer's destination must be one of the gate's roots; if these two
# defaults ever drift the install silently produces something unlaunchable.
grep -q 'LV_UI_ARTIFACT_DEST_ROOT:-\$HOME/localvoxtral-ui-artifacts' "$INSTALLER" \
  || fail "the installer's default destination changed — is it still a gate root?"
case "$ROOTS_DEFAULT" in
  *'$HOME/localvoxtral-ui-artifacts'*) ;;
  *) fail "the installer installs into \$HOME/localvoxtral-ui-artifacts but the gate no longer allowlists it" ;;
esac
pass "the installer's default destination is one of the gate's allowlisted roots"

SRC_DIR="$TMP_DIR/src"
mkdir -p "$SRC_DIR"
SRC_CLEAN="$(make_bundle_in "$SRC_DIR" build-clean.app com.localvoxtral.app localvoxtral absent)"
SRC_DOGFOOD="$(make_bundle_in "$SRC_DIR" build-dogfood.app com.localvoxtral.app localvoxtral true)"
SRC_IMPOSTOR="$(make_bundle_in "$SRC_DIR" Mail.app com.apple.mail Mail absent)"
INSTALL_ROOT="$FAKE_HOME/install-root"

INSTALL_STATUS=0
INSTALL_STDOUT=""
INSTALL_STDERR=""
INSTALL_ENV=()

run_install() { # <installer args...>   (env via INSTALL_ENV, consumed per call)
  local out_file="$TMP_DIR/install.out" err_file="$TMP_DIR/install.err"
  INSTALL_STATUS=0
  env -i \
    PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$FAKE_HOME" \
    STUB_OPEN_LOG="$TMP_DIR/open.log" \
    ${INSTALL_ENV[@]+"${INSTALL_ENV[@]}"} \
    bash "$INSTALLER" "$@" >"$out_file" 2>"$err_file" || INSTALL_STATUS=$?
  INSTALL_ENV=()
  INSTALL_STDOUT="$(cat "$out_file")"
  INSTALL_STDERR="$(cat "$err_file")"
}

assert_install_refused() { # <description> <installer args...>
  local description="$1"
  shift
  run_install "$@"
  (( INSTALL_STATUS != 0 )) \
    || fail "$description: the install succeeded (stdout: $INSTALL_STDOUT)"
  [[ "$INSTALL_STDERR" == *"install-ui-artifact:"* ]] \
    || fail "$description: no install-ui-artifact diagnostic (stderr: $INSTALL_STDERR)"
  pass "refused: $description"
}

# --- the happy path, into the real default root ----------------------------

: >"$TMP_DIR/open.log"
run_install "$SRC_CLEAN" --label "pr-238 @ CI run 123"
(( INSTALL_STATUS == 0 )) || fail "installing a clean bundle failed: $INSTALL_STDERR"
[[ "$INSTALL_STDOUT" == "$ARTIFACT_ROOT/localvoxtral.app" ]] \
  || fail "installer stdout is not the installed bundle path: $INSTALL_STDOUT"
[[ -x "$ARTIFACT_ROOT/localvoxtral.app/Contents/MacOS/localvoxtral" ]] \
  || fail "the installed bundle has no executable"
grep -q '^variant=clean$' "$ARTIFACT_ROOT/localvoxtral.app.source" \
  || fail "the provenance file does not record the clean variant"
grep -q "^label=pr-238 @ CI run 123$" "$ARTIFACT_ROOT/localvoxtral.app.source" \
  || fail "the provenance file does not record which build this is"
[[ ! -s "$TMP_DIR/open.log" ]] \
  || fail "the installer launched something — launching is the gate's job: $(cat "$TMP_DIR/open.log")"
# The hint is the gate-relative path, because that is what `launch` resolves.
[[ "$INSTALL_STDERR" == *"launch localvoxtral-ui-artifacts/localvoxtral.app"* ]] \
  || fail "no gate-launch hint, or not the path the gate resolves: $INSTALL_STDERR"
pass "a clean bundle installs into the default root, with provenance and no launch"

run_install "$SRC_CLEAN" --no-hint
(( INSTALL_STATUS == 0 )) || fail "--no-hint install failed: $INSTALL_STDERR"
[[ "$INSTALL_STDERR" != *"gate launch"* ]] \
  || fail "--no-hint still printed a launch hint (try-pr.sh prints its own, later)"
pass "--no-hint suppresses the duplicate launch hint"

# The point of the whole exercise: the gate accepts what the installer wrote.
clear_state
assert_allowed "launch $ARTIFACT_ROOT/localvoxtral.app" \
  'the gate launches the bundle the installer just installed' \
  "${APP_ENV[@]}" STUB_PGREP_PID=4242
clear_state

run_install "$SRC_DOGFOOD"
(( INSTALL_STATUS == 0 )) || fail "installing a dogfood bundle failed: $INSTALL_STDERR"
[[ "$INSTALL_STDOUT" == "$ARTIFACT_ROOT/localvoxtral-dogfood.app" ]] \
  || fail "the stamped bundle did not take the dogfood slot: $INSTALL_STDOUT"
grep -q '^variant=dogfood$' "$ARTIFACT_ROOT/localvoxtral-dogfood.app.source" \
  || fail "the provenance file does not record the dogfood variant"
assert_allowed "launch --dogfood $ARTIFACT_ROOT/localvoxtral-dogfood.app" \
  'the gate launches the installed dogfood bundle with --dogfood' \
  STUB_PS_LSTART="Mon Aug 24 09:00:00 2026" \
  STUB_PS_COMM="$ARTIFACT_ROOT/localvoxtral-dogfood.app/Contents/MacOS/localvoxtral" \
  STUB_PGREP_PID=4343
clear_state
pass "clean and dogfood builds occupy separate slots and both launch"

# --- reinstall replaces its slot -------------------------------------------
#
# Two slots, not one per build: N copies of the same bundle id share one
# defaults domain and one TCC grant, so a stale one is indistinguishable at
# runtime — the wrong-binary confusion, on disk.
SRC_SECOND="$(make_bundle_in "$SRC_DIR" build-second.app com.localvoxtral.app localvoxtral absent)"
printf 'second build\n' >"$SRC_SECOND/Contents/MacOS/localvoxtral"
chmod +x "$SRC_SECOND/Contents/MacOS/localvoxtral"
BEFORE_SLOTS="$(ls -d "$ARTIFACT_ROOT"/*.app 2>/dev/null | wc -l | tr -d ' ')"
INSTALL_ENV=(LV_UI_ARTIFACT_DEST_ROOT="$ARTIFACT_ROOT")
run_install "$SRC_SECOND"
(( INSTALL_STATUS == 0 )) || fail "reinstalling failed: $INSTALL_STDERR"
AFTER_SLOTS="$(ls -d "$ARTIFACT_ROOT"/*.app 2>/dev/null | wc -l | tr -d ' ')"
[[ "$BEFORE_SLOTS" == "$AFTER_SLOTS" ]] \
  || fail "a reinstall added a bundle instead of replacing its slot ($BEFORE_SLOTS -> $AFTER_SLOTS)"
grep -q 'second build' "$ARTIFACT_ROOT/localvoxtral.app/Contents/MacOS/localvoxtral" \
  || fail "the reinstall did not replace the previous bundle's contents"
grep -q "^source=$SRC_SECOND$" "$ARTIFACT_ROOT/localvoxtral.app.source" \
  || fail "the provenance file still points at the previous build"
[[ -z "$(ls -d "$ARTIFACT_ROOT"/.incoming-* "$ARTIFACT_ROOT"/.outgoing-* 2>/dev/null)" ]] \
  || fail "the install left staging directories behind"
pass "a reinstall replaces its slot and leaves no staging droppings"

# --- refusals --------------------------------------------------------------

assert_install_refused 'a source bundle that does not exist' \
  "$SRC_DIR/nope.app"
assert_install_refused 'a directory that is not a .app' \
  "$SRC_DIR"
assert_install_refused "another vendor's bundle" \
  "$SRC_IMPOSTOR"
assert_install_refused 'a .app with no Info.plist' \
  "$(mkdir -p "$SRC_DIR/empty.app" && printf '%s' "$SRC_DIR/empty.app")"
assert_install_refused 'an unknown flag' \
  "$SRC_CLEAN" --launch-it

# A destination the owner cannot write is a broken install, not a silent no-op.
mkdir -p "$INSTALL_ROOT/readonly"
chmod 0500 "$INSTALL_ROOT/readonly"
if [[ "$(id -u)" == "0" ]]; then
  printf 'SKIP: running as root — the unwritable-destination refusal cannot be exercised\n'
else
  INSTALL_ENV=(LV_UI_ARTIFACT_DEST_ROOT="$INSTALL_ROOT/readonly")
  assert_install_refused 'a destination root that is not writable' "$SRC_CLEAN"
fi
chmod 0700 "$INSTALL_ROOT/readonly"

# The install-side half of section 15: the installer refuses to feed a root
# that anyone local can write, rather than quietly making the gate launchable
# from one.
mkdir -p "$INSTALL_ROOT/world"
chmod 0777 "$INSTALL_ROOT/world"
INSTALL_ENV=(LV_UI_ARTIFACT_DEST_ROOT="$INSTALL_ROOT/world")
assert_install_refused 'a group/other-writable destination root' "$SRC_CLEAN"
[[ "$INSTALL_STDERR" == *"writable"* ]] \
  || fail "the world-writable refusal did not say why: $INSTALL_STDERR"
chmod 0755 "$INSTALL_ROOT/world"
INSTALL_ENV=(LV_UI_ARTIFACT_DEST_ROOT="$INSTALL_ROOT/world")
run_install "$SRC_CLEAN"
(( INSTALL_STATUS == 0 )) \
  || fail "an owner-only-writable root was refused: $INSTALL_STDERR"
pass "the same root installs fine once group/other write is removed"

# A root the installer creates itself must not be world-writable either.
INSTALL_ENV=(LV_UI_ARTIFACT_DEST_ROOT="$INSTALL_ROOT/fresh")
run_install "$SRC_CLEAN"
(( INSTALL_STATUS == 0 )) || fail "installing into a fresh root failed: $INSTALL_STDERR"
FRESH_MODE="$(mode_of "$INSTALL_ROOT/fresh")"
(( (8#$FRESH_MODE & 0022) == 0 )) \
  || fail "the installer created its root as mode $FRESH_MODE"
pass "a root the installer creates is owner-writable only (mode $FRESH_MODE)"

# Replacing files under a running process is how you get a half-swapped app.
# Quitting it is the operator's call (the gate has a `quit` verb); refusing is
# the installer's.
INSTALL_ENV=(LV_UI_ARTIFACT_DEST_ROOT="$ARTIFACT_ROOT" STUB_PGREP_PID=4242)
assert_install_refused 'overwriting a bundle that is currently running' "$SRC_CLEAN"
[[ "$INSTALL_STDERR" == *"quit it first"* ]] \
  || fail "the running-bundle refusal did not say what to do: $INSTALL_STDERR"

echo "== 18. try-pr.sh --ui-gate hands off to the gate =="

grep -q -- '--ui-gate) UI_GATE=1' "$TRY_PR" \
  || fail "try-pr.sh no longer parses --ui-gate"
grep -q 'mac/install-ui-artifact.sh' "$TRY_PR" \
  || fail "try-pr.sh --ui-gate no longer delegates to the installer"
pass "try-pr.sh --ui-gate installs through install-ui-artifact.sh"

# --ui-gate must not `open` the app itself: an instance the gate did not start
# is invisible to app.state and rivals the one it will start for the global
# hotkey and the speechd/polishd ports.
OPEN_LINE="$(grep -n '^open "\$APP"' "$TRY_PR" | head -n 1 | cut -d: -f1)"
[[ -n "$OPEN_LINE" ]] || fail "try-pr.sh no longer ends by opening the app"
GUARD_LINE="$(grep -n 'exit 0' "$TRY_PR" | awk -F: -v limit="$OPEN_LINE" '$1 < limit { last = $1 } END { print last }')"
[[ -n "$GUARD_LINE" ]] \
  || fail "nothing returns before try-pr.sh's final open — --ui-gate would launch an unrecorded instance"
awk -v start="$GUARD_LINE" -v stop="$OPEN_LINE" 'NR >= start - 20 && NR <= stop' "$TRY_PR" \
  | grep -q 'UI_GATE' \
  || fail "the early return before try-pr.sh's final open is not the --ui-gate branch"
pass "try-pr.sh --ui-gate returns before the launch, leaving it to the gate"

# The default is unchanged: /tmp, then launch.
grep -q 'DEST="\$(mktemp -d /tmp/localvoxtral-try.XXXXXX)"' "$TRY_PR" \
  || fail "try-pr.sh's default extraction directory changed — --ui-gate was meant to be additive"
pass "try-pr.sh's default (extract to /tmp, then open) is untouched"

echo
echo "ui gate tests passed"
