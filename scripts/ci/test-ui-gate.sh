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
# Overridable so a NEW assertion can be shown failing against an OLDER copy
# of the gate (the red half of red/green); CI never sets it.
GATE="${LV_UI_GATE_TEST_GATE:-$ROOT_DIR/scripts/mac/localvoxtral-ui-gate.sh}"
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
# Every long-lived stand-in this suite starts appends its pid to SPAWNED_PIDS,
# the `open` stub's launcher included. Some cases hand that process to the
# gate and expect it killed; others (a reused Terminal instance) expect it
# left alone, so without this it outlived the suite by five minutes (#714).
SPAWNED_PIDS="$TMP_DIR/open.log.spawned"
reap_spawned() {
  local pid
  [[ -f "$SPAWNED_PIDS" ]] || return 0
  # Most of these died long ago, and macOS recycles pids within minutes on a
  # busy runner: signal a pid only while it still runs the command we started.
  while read -r pid; do
    [[ "$(ps -o command= -p "$pid" 2>/dev/null)" == "/bin/sleep 300" ]] \
      && kill "$pid" 2>/dev/null
  done <"$SPAWNED_PIDS"
  return 0
}
trap 'reap_spawned; rm -rf "$TMP_DIR"' EXIT

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

# A failure ends the run. LV_UI_GATE_TEST_KEEP_GOING=1 records it and carries
# on instead — for a red/green demonstration against an older gate (every new
# assertion shown failing in one run), never for CI, where the default stays.
FAILURES=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [[ "${LV_UI_GATE_TEST_KEEP_GOING:-0}" == "1" ]]; then
    FAILURES=$((FAILURES + 1))
    return 0
  fi
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

# Instant, and it records what it was asked to wait: the owner's 3 s warning
# pause is a `sleep 3` the lease tests (section 29) need to see on the first
# verb of a burst and NOT on the ones that follow. With STUB_SLEEP_HOLD_SECONDS
# set (one duration, or several separated by spaces), a call for exactly one
# of those durations blocks until STUB_SLEEP_HOLD_FILE exists (bounded), which
# is how the suite holds a done-announcer's `sleep <lease>` open while a later
# verb rewrites the lease's nonce.
cat >"$STUB_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_SLEEP_LOG:-/dev/null}"
if [[ -n "${STUB_SLEEP_HOLD_SECONDS:-}" && " $STUB_SLEEP_HOLD_SECONDS " == *" $* "* ]]; then
  hold_polls=0
  while (( hold_polls < 500 )); do
    [[ -e "${STUB_SLEEP_HOLD_FILE:-/nonexistent}" ]] && exit 0
    /bin/sleep 0.01
    hold_polls=$((hold_polls + 1))
  done
fi
exit 0
STUB

cat >"$STUB_BIN/open" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_OPEN_LOG"
# A flag the pgrep stub can see, so the suite can express "these processes did
# not exist before `open` ran". That distinction is the whole basis of the
# gate's instance reclaim, and a stub that answers the same list before and
# after cannot test it.
: >"$STUB_OPEN_LOG.opened"
# With STUB_OPEN_SPAWN set, stand in for a terminal that actually ran the
# launcher: a process that recorded its own pid the way the launcher's
# `printf "$$" > <pidfile>` does before `exec`. That pid is the handle
# `term open` uses to take back what it started when it cannot identify the
# window, so the suite needs a real process to watch die.
#
# `/bin/sh -c` and `$$`, NOT a `( … ) &` subshell and `$BASHPID`: the Mac's
# /bin/bash is 3.2, where BASHPID does not exist and expands to nothing — the
# pid file came out empty, the gate correctly read that as "the launcher never
# ran", and the test failed on the runner while passing on a bash-5 dev box
# (CI 33313541728). A separate `sh` process makes `$$` its OWN pid, which is
# also exactly what the real launcher does. `/bin/sleep`, not the stubbed
# `sleep` that returns instantly.
case "${STUB_OPEN_SPAWN:-}" in
  "") ;;
  dead)
    # The launcher ran and the command exited immediately — the pid file is
    # there, the process is not. An empty terminal window is what the owner
    # sees when this happens. Run it in the FOREGROUND so it has certainly
    # exited by the time the gate looks.
    launcher=""
    for launcher in "$@"; do :; done
    /bin/sh -c 'printf "%s" "$$" > "$1"' _ "${launcher%.command}.pid"
    ;;
  *)
    launcher=""
    for launcher in "$@"; do :; done
    /bin/sh -c 'printf "%s" "$$" > "$1"; exec /bin/sleep 300' _ "${launcher%.command}.pid" &
    printf '%s\n' "$!" >>"$STUB_OPEN_LOG.spawned"
    # The pid file has to exist before this returns, or the gate races it.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [[ -s "${launcher%.command}.pid" ]] && break
      /bin/sleep 0.1
    done
    ;;
esac
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
# Once `open` has run, a terminal lookup may answer a DIFFERENT list: the
# instance `open -n` just created did not exist a moment ago. Only the
# terminal lookup, and only when the test asked for it.
if [[ -n "${STUB_PGREP_PID_AFTER:-}" && -e "${STUB_OPEN_LOG:-}.opened" ]]; then
  STUB_PGREP_PID="$STUB_PGREP_PID_AFTER"
fi
[[ -n "${STUB_PGREP_PID:-}" ]] || exit 1
# Space-separated, one per line: the real pgrep answers a bundle-path PREFIX
# with EVERY match, and the bundle ships localvoxtral-speechd/-polishd beside
# the app. A stub that could only answer with one pid is what hid that.
#
# `-n` is honoured, because it is the half of the bug that bites: it asks for
# the NEWEST match, and a helper the app just spawned is newer than the app.
# The list is read as start order, so `-n` is its last entry.
stub_newest=0
for stub_arg in "$@"; do [[ "$stub_arg" == "-n" ]] && stub_newest=1; done
if (( stub_newest == 1 )); then
  stub_last=""
  for stub_last in $STUB_PGREP_PID; do :; done
  printf '%s\n' "$stub_last"
  exit 0
fi
for stub_pid in $STUB_PGREP_PID; do printf '%s\n' "$stub_pid"; done
STUB

# `ps -p <pid> -o lstart=` and `ps -p <pid> -o comm=` are the two halves of the
# gate's pid-reuse defence.
cat >"$STUB_BIN/ps" <<'STUB'
#!/usr/bin/env bash
# `-p <pid>` is remembered so `comm=` can answer PER PID: that is the fact that
# separates the app from a helper of its own that shares the pgrep prefix.
# STUB_PS_COMM_<pid> wins when set, STUB_PS_COMM is the fallback.
stub_pid=""
stub_want_pid=0
for arg in "$@"; do
  if (( stub_want_pid == 1 )); then stub_pid="$arg"; stub_want_pid=0; continue; fi
  case "$arg" in
    -p) stub_want_pid=1 ;;
    lstart=) printf '%s\n' "${STUB_PS_LSTART:-Mon Aug 24 09:00:00 2026}"; exit 0 ;;
    comm=)
      # Indirect expansion is bash 2.0+, so this is safe on the Mac's 3.2.
      stub_var="STUB_PS_COMM_${stub_pid}"
      if [[ -n "${!stub_var:-}" ]]; then
        printf '%s\n' "${!stub_var}"
      else
        printf '%s\n' "${STUB_PS_COMM:-/nonexistent}"
      fi
      exit 0
      ;;
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
#
# The same file is what the `swiftc` stub (section 30) installs as the
# "compiled" helper binary, which the gate then runs as `<binary> <subcommand>
# ...` with no source path in front. That form is normalised here by putting
# the word `compiled` where the source path would be, so the case below and
# every swift.log assertion in this suite read both forms alike — and so the
# log says which path ran.
cat >"$STUB_BIN/swift" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == *.swift ]] || set -- compiled "$@"
printf '%s\n' "$*" >>"$STUB_SWIFT_LOG"
case "$2" in
  preflight)
    echo "accessibility=1"; echo "screen_recording=1"; echo "frontmost_pid=$3"
    ;;
  axfind)
    # $3 pid, $4 selector: one matched node, echoing the selector back so a
    # test can see that the selector reached the helper unchanged.
    printf '[{"role":"AXButton","subrole":"","title":"%s","desc":"","value":"","children":[]}]\n' "$4"
    ;;
  window)
    [[ -n "${STUB_WINDOW_RESULT:-}" ]] || exit 1
    printf '%s\n' "$STUB_WINDOW_RESULT"
    ;;
  termsnapshot)
    # The window ids the terminal owned BEFORE `open`. The gate diffs against
    # these, so the suite can say "one new window", "none" or "several".
    printf '%s\n' "${STUB_TERM_SNAPSHOT:-}"
    ;;
  termnew)
    # $3 owner pid, $4 marker, $5 excluded ids. The exit code is the contract:
    # 0 with `ok <winid> <ownerpid>`, 1 for "nothing new yet", 2 for "several
    # appeared and I will not guess".
    case "${STUB_TERMNEW:-ok}" in
      ok) printf 'ok %s %s\n' "${STUB_TERMNEW_WINDOW:-9001}" "$3" ;;
      none) exit 1 ;;
      ambiguous)
        # stdout carries the ids in the parseable form the real helper prints,
        # so the gate can take back what it opened; the sentence stays on
        # stderr for the operator.
        printf 'ambiguous %s 9001 9002\n' "$3"
        printf 'helper: 2 windows of pid %s appeared since the snapshot (ids 9001 9002)\n' "$3" >&2
        exit 2
        ;;
    esac
    ;;
  axdump)
    echo '[{"role":"AXWindow","children":[]}]'
    ;;
  axclick | axtype | key | termaction)
    echo ok
    ;;
  menuopen)
    # The real helper prints the CGWindowID of the menu it resolved, so a
    # caller can tell a real open from a no-op. The stub says one too.
    [[ -z "${STUB_MENU_FAIL:-}" ]] || exit 1
    printf '%s\n' "${STUB_MENUOPEN_OUTPUT:-ok window=90210}"
    ;;
  menuclick | menudismiss)
    [[ -z "${STUB_MENU_FAIL:-}" ]] || exit 1
    echo ok
    ;;
  dictate)
    [[ -z "${STUB_DICTATE_FAIL:-}" ]] || exit 1
    echo "ok $5 trigger=$4 frontmost=7777 (Ghostty)"
    ;;
  controlprobe)
    # Connect-and-close, no payload: exit 0 when something is listening. The
    # suite drives it with STUB_CONTROL_DEAD so that "a socket FILE exists but
    # nothing answers" is expressible — the state field this replaced could not
    # tell that apart from a live listener.
    [[ -z "${STUB_CONTROL_DEAD:-}" ]] || exit 1
    exit 0
    ;;
  control)
    # $3 is the socket path, $4 the forwarded line. Echoed back so the suite
    # can assert exactly what crossed, and nothing more.
    [[ -z "${STUB_CONTROL_FAIL:-}" ]] || exit 1
    printf '{"ok":true,"command":"%s","error":null,"result":{}}\n' "$4"
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

# `log show ...` — the unified-log reader the `log` verb wraps. Answers from
# fixtures so the suite can exercise the happy path, the restricted-store
# refusal, and the line cap without a real log store.
cat >"$STUB_BIN/log" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG_LOG"
if [[ -n "${STUB_LOG_RESTRICTED:-}" ]]; then
  echo "log: Could not open local log store: Operation not permitted" >&2
  exit 64
fi
if [[ -n "${STUB_LOG_OUTPUT_FILE:-}" && -f "$STUB_LOG_OUTPUT_FILE" ]]; then
  cat "$STUB_LOG_OUTPUT_FILE"
  exit 0
fi
exit 0
STUB

# `lv-attach` execs exactly one ssh. The stub records the argv it was handed,
# which is the whole assertion.
cat >"$STUB_BIN/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_SSH_LOG"
STUB

cat >"$STUB_BIN/pmset" <<'STUB'
#!/usr/bin/env bash
echo "Now drawing from 'AC Power'"
STUB

# Reads as well as writes: `dictate` reads the app's OWN trigger settings out
# of its defaults domain rather than hard-coding a key, so the suite has to be
# able to say what the app is configured with. `settings.foo` is answered from
# $STUB_DEFAULT_settings_foo; an unset variable reads as "key absent".
cat >"$STUB_BIN/defaults" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DEFAULTS_LOG"
if [[ "${1:-}" == "read" ]]; then
  key="${3:-}"
  var="STUB_DEFAULT_${key//./_}"
  value="${!var:-}"
  [[ -n "$value" ]] || exit 1
  printf '%s\n' "$value"
fi
STUB

chmod +x "$STUB_BIN"/*

install -m 0755 "$LOCK_PROBE_SRC" "$FAKE_HOME/bin/localvoxtral-screen-lock-state.sh"
# `term open` resolves an allowlisted NAME to an executable file under
# LV_UI_TERM_COMMAND_DIRS ($HOME/bin) before it opens anything, so the happy
# paths below need the wrapper actually installed — which is also the state the
# owner's Mac was NOT in on 2026-08-30.
install -m 0700 "$ROOT_DIR/scripts/mac/lv-attach.sh" "$FAKE_HOME/bin/lv-attach"

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

# Two of the gate's waits are budgets in WALL CLOCK, and this suite stubs
# `sleep` to return instantly — so a case that drives one of them to its
# deadline spins for the whole budget instead of polling through it. Both are
# seams in the gate (defaults 20 s); here they are as short as the case needs.
# `TERM_OPEN_TIMEOUT` / `LAUNCH_WAIT` override them for a single case.
# The takeover LEASE is OFF here by default (`LEASE_SECONDS`, 0 = warn on every
# verb, the v1 behaviour every section below was written against, and the
# behaviour the owner gets with `LV_UI_TAKEOVER_LEASE_SECONDS=0`). Section 29
# turns it on explicitly and moves the clock through `NOW_EPOCH`, which the
# gate's now_epoch seam reads — no test here waits out a real lease window.
# The helper compiler is pointed at a path that does not exist unless a case
# sets `SWIFTC_CMD` (section 30's stand-in): the gate then runs the helper
# through the `swift` stub as it always has, on a Linux runner AND on a Mac
# that has the real swiftc — which must never compile the real helper under
# this suite. `GATE_UNDER_TEST` runs a different copy of the gate (a
# source-changed one). stdin is the caller's, so `run_gate batch … <<<"$lines"`
# feeds a batch.
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
    LV_UI_TERM_OPEN_TIMEOUT_SECONDS="${TERM_OPEN_TIMEOUT:-1}" \
    LV_UI_LAUNCH_WAIT_SECONDS="${LAUNCH_WAIT:-0}" \
    LV_UI_TAKEOVER_LEASE_SECONDS="${LEASE_SECONDS:-0}" \
    LV_UI_NOW_EPOCH="${NOW_EPOCH:-}" \
    LV_UI_SWIFTC="${SWIFTC_CMD:-$TMP_DIR/no-swiftc-here}" \
    LV_SCREEN_LOCK_STATE="${LOCK_STATE:-unlocked}" \
    STUB_SAY_LOG="$TMP_DIR/say.log" \
    STUB_SLEEP_LOG="$TMP_DIR/sleep.log" \
    STUB_OPEN_LOG="$TMP_DIR/open.log" \
    STUB_SWIFT_LOG="$TMP_DIR/swift.log" \
    STUB_SWIFTC_LOG="$TMP_DIR/swiftc.log" \
    STUB_DEFAULTS_LOG="$TMP_DIR/defaults.log" \
    STUB_SCREENCAPTURE_LOG="$TMP_DIR/screencapture.log" \
    STUB_LOG_LOG="$TMP_DIR/log.log" \
    "$@" \
    bash "${GATE_UNDER_TEST:-$GATE}" >"$out_file" 2>"$err_file" || GATE_STATUS=$?
  # `$(<file)` and not `$(cat file)`: bash reads the file itself, and this runs
  # twice for every one of the ~240 gate invocations below.
  GATE_STDOUT="$(<"$out_file")"
  GATE_STDERR="$(<"$err_file")"
  [[ -n "${SKIP_ANNOUNCER_WAIT:-}" ]] || wait_for_done_announcer
}

# With the lease on, "done" is spoken by a subshell the gate detaches and does
# not wait for. Its pid is in the lease file for exactly this purpose: the
# suite joins it here so every assertion about say.log is made after it has
# had its say (under the instant `sleep` stub that is milliseconds), and no
# announcer from one case can write into the next case's say.log.
wait_for_done_announcer() {
  local lease="$FAKE_HOME/.localvoxtral-ui-gate/takeover.lease" pid i
  [[ -f "$lease" ]] || return 0
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    for (( i = 0; i < 200; i++ )); do
      kill -0 "$pid" 2>/dev/null || break
      /bin/sleep 0.01
    done
    kill -0 "$pid" 2>/dev/null && fail "the done-announcer (pid $pid) is still running 2 s after the gate exited"
  done < <(sed -n 's/^announcer=//p' "$lease" 2>/dev/null || true)
  return 0
}

log_tail() {
  tail -n 1 "$LOG_FILE" 2>/dev/null || true
}

# Octal permission bits of a file, GNU stat or BSD stat, never a failure (an
# assignment from a failing substitution would end the run under `set -e`
# before `fail` could say what was missing).
file_mode() { # <path>
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

# The embedded helper is a heredoc, so its subcommands cannot be exercised
# without a live desktop — but WHICH evidence a subcommand decides on is a
# property of the source, and that is the half that regressed. These read one
# `case "<name>":` body (and one `func` body) out of the heredoc so an
# assertion can be about that block rather than about the whole 2000-line file.
helper_case_body() { # <helper subcommand>
  awk -v want="case \"$1\":" '
    /^case "[a-z]+":$/ { inside = ($0 == want) }
    inside { print }
  ' "$GATE"
}

helper_func_body() { # <swift function name>
  awk -v want="func $1(" '
    index($0, want) == 1 { inside = 1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$GATE"
}

assert_denied() { # <command> <description> [env...]
  local command="$1" description="$2"
  shift 2
  local before after last
  before="$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)"
  run_gate "$command" "$@"
  (( GATE_STATUS == 126 )) \
    || fail "$description: expected exit 126, got $GATE_STATUS (stderr: $GATE_STDERR)"
  [[ "$GATE_STDERR" == *"denied command"* ]] \
    || fail "$description: stderr did not say 'denied command' ($GATE_STDERR)"
  after="$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)"
  (( after > before )) || fail "$description: nothing was appended to the gate log"
  # Read the last line ONCE. The three assertions below are unchanged; they
  # used to re-run `tail` for each of them, five times per denial.
  last="$(log_tail)"
  [[ "$last" == *" DENY "* ]] \
    || fail "$description: last log line is not a DENY line: $last"
  [[ "$last" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]] \
    || fail "$description: DENY line has no timestamp: $last"
  pass "denied: $description"
}

assert_allowed() { # <command> <description> [env...]
  local command="$1" description="$2"
  shift 2
  run_gate "$command" "$@"
  (( GATE_STATUS == 0 )) \
    || fail "$description: expected exit 0, got $GATE_STATUS (stderr: $GATE_STDERR)"
  local last
  last="$(log_tail)"
  [[ "$last" == *" ALLOW "* ]] \
    || fail "$description: no ALLOW line was logged (last line: $last)"
  pass "allowed: $description"
}

write_app_state() { # <pid> [dogfood:0|1] [bundle]
  local pid="$1" dogfood="${2:-0}" bundle="${3:-$CLEAN_APP}"
  local dir="$FAKE_HOME/.localvoxtral-ui-gate"
  mkdir -p "$dir"
  {
    printf 'pid=%s\n' "$pid"
    printf 'bundle=%s\n' "$bundle"
    printf 'identity=%s|%s\n' "Mon Aug 24 09:00:00 2026" "$bundle/Contents/MacOS/localvoxtral"
    printf 'dogfood=%s\n' "$dogfood"
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
assert_denied 'dictate' 'dictate without a subverb'
assert_denied 'dictate now' 'unknown dictate subverb'
assert_denied 'dictate tap 3' 'dictate tap with a duration'
assert_denied 'dictate cancel now' 'dictate cancel with an argument'
assert_denied 'dictate hold' 'dictate hold without a duration'
assert_denied 'dictate hold 2 3' 'dictate hold with two durations'
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
# The classes the header's own admission test does NOT catch. `vi`, `less` and
# `man` expose no flag that takes a command — they reach a shell at RUNTIME
# (`:!cmd`, `!cmd`, `v`), so reading `--help` clears them, and they are exactly
# what an owner allowlists meaning "just a viewer". The wrappers below are the
# opposite shape: running someone else's command IS their normal argv.
for forbidden in vi vim nvim view ex ed less more man awk sed git swift open \
  watch nice caffeinate timeout env xargs npx cargo go nc curl wget; do
  grep -qw "$forbidden" <<<"$FORBIDDEN_BLOCK" \
    || fail "$forbidden can run a child command and is not on the permanent denylist"
done
pass "the default allowlist is empty and the permanent denylist still names every shell and agent CLI"

# The exploit that motivated widening it: an owner allowlists a pager, and
# `!bash` inside the window is an interactive shell as the GUI user.
write_conf 'LV_UI_TERM_COMMANDS="less vim git open"'
assert_denied 'term open ghostty less /etc/hosts' 'conf-allowlisted less is STILL denied'
assert_denied 'term open ghostty vim /etc/hosts' 'conf-allowlisted vim is STILL denied'
assert_denied 'term open ghostty git log' 'conf-allowlisted git is STILL denied'
assert_denied 'term open ghostty open -a Terminal' 'conf-allowlisted open is STILL denied'
clear_conf

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
  'term focus term-1' \
  'term close term-1'; do
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
# Said twice on purpose: `shot … | base64 -d > x.png` is the documented form,
# and it is only correct while stdout carries nothing but the payload. The
# "shot: window …" line reads like a header over an interactive ssh, which
# delivers both streams to one terminal — it must never actually be one.
[[ "$GATE_STDOUT" != *"shot:"* ]] \
  || fail "the shot header reached stdout — a caller piping into base64 -d now needs a tail: $GATE_STDOUT"
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
grep -q -- "-n --env LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=1 $CLEAN_APP" "$TMP_DIR/open.log" \
  || fail "launch did not open the validated bundle with the keychain off: $(cat "$TMP_DIR/open.log")"
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

# The bundle ships localvoxtral-speechd, localvoxtral-polishd and
# localvoxtral-claude-hook in the SAME Contents/MacOS directory
# (package_app.sh), so all of them match the pgrep prefix
# "<bundle>/Contents/MacOS/localvoxtral" — and the app starts its helpers
# during launch, so `pgrep -n` (newest) can hand back a helper. Recording a
# helper is worse than failing: every verb then drives a windowless process,
# and `quit` kills the helper while the real app keeps running, after which
# `launch` refuses beside "a localvoxtral this gate did not start" and only the
# owner can unwedge the machine. The executable path is what decides.
clear_state
run_gate "launch $CLEAN_APP" \
  STUB_PS_LSTART="Mon Aug 24 09:00:00 2026" \
  STUB_PGREP_PID="5000 5100 5200" \
  STUB_PS_COMM_5000="$CLEAN_APP/Contents/MacOS/localvoxtral" \
  STUB_PS_COMM_5100="$CLEAN_APP/Contents/MacOS/localvoxtral-speechd" \
  STUB_PS_COMM_5200="$CLEAN_APP/Contents/MacOS/localvoxtral-polishd"
(( GATE_STATUS == 0 )) || fail "launch failed while helpers shared the prefix: $GATE_STDERR"
[[ "$GATE_STDOUT" == *"launched pid=5000"* ]] \
  || fail "launch recorded a helper instead of the app: $GATE_STDOUT"
grep -q "pid=5000" "$FAKE_HOME/.localvoxtral-ui-gate/app.state" \
  || fail "app.state names a helper: $(cat "$FAKE_HOME/.localvoxtral-ui-gate/app.state")"
grep -q "identity=Mon Aug 24 09:00:00 2026|$CLEAN_APP/Contents/MacOS/localvoxtral$" \
  "$FAKE_HOME/.localvoxtral-ui-gate/app.state" \
  || fail "the recorded identity is not the app executable"
pass "launch records the APP, never a helper sharing the pgrep prefix"

# And the other direction: if the ONLY thing matching the prefix is a helper,
# there is no app under test and launch must say so rather than adopt it.
#
# The one case in this suite that runs `launch`'s wait loop to its DEADLINE, so
# it is also the one that pays for it: `sleep` is stubbed to return instantly,
# which turns the poll into a fork storm that runs for the whole budget. At the
# gate's 20-second default this single assertion was 19.2 s of a 32.6 s suite
# (measured 2026-09-05). One second still retries, still expires, still proves
# exactly what it proved before.
clear_state
LAUNCH_WAIT=1
run_gate "launch $CLEAN_APP" \
  STUB_PS_LSTART="Mon Aug 24 09:00:00 2026" \
  STUB_PGREP_PID="5100" \
  STUB_PS_COMM_5100="$CLEAN_APP/Contents/MacOS/localvoxtral-speechd"
unset LAUNCH_WAIT
(( GATE_STATUS != 0 )) || fail "launch adopted a helper as the app under test"
[[ ! -f "$FAKE_HOME/.localvoxtral-ui-gate/app.state" ]] \
  || fail "launch wrote app.state for a helper"
pass "a helper alone is not an app under test"
clear_state

# A hand-edited conf is where `20s` comes from, and the wait budget is consumed
# by `$(( ))`: a non-numeric value there is an arithmetic error, which under
# `set -e` kills the gate AFTER `open` has started the app and BEFORE app.state
# records it — the unrecorded-instance wedge the gate header warns about,
# reached by a typo. It must degrade to the built-in default instead.
clear_state
: >"$TMP_DIR/open.log"
write_conf 'LV_UI_LAUNCH_WAIT_SECONDS="20s"'
run_gate "launch $CLEAN_APP" "${APP_ENV[@]}" STUB_PGREP_PID=4242
clear_conf
(( GATE_STATUS == 0 )) \
  || fail "a junk launch budget in the conf broke launch: $GATE_STATUS ($GATE_STDERR)"
grep -q "pid=4242" "$FAKE_HOME/.localvoxtral-ui-gate/app.state" \
  || fail "launch opened the app but recorded nothing — the unrecorded-instance wedge"
pass "a junk launch budget in the conf falls back to the default, never opening without recording"
clear_state

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
grep -q "^exec $FAKE_HOME/bin/lv-attach pane-7\$" "$SCRIPT_FILE" \
  || fail "launcher script does not exec exactly the validated argv: $(cat "$SCRIPT_FILE")"
pass "allowed: term open runs an opted-in wrapper, by absolute path, and logs the command in full"

# The same arithmetic trap as `launch`'s budget, and worse placed: `term open`
# computes its deadline AFTER `open` has already put a window on the owner's
# desktop, so a `20s` in the conf left that window behind with no recorded id —
# unfocusable and uncloseable by this gate.
write_conf 'LV_UI_TERM_COMMANDS="lv-attach"' 'LV_UI_TERM_OPEN_TIMEOUT_SECONDS="20s"'
run_gate 'term open ghostty lv-attach pane-9' STUB_PGREP_PID=$$
write_conf 'LV_UI_TERM_COMMANDS="lv-attach"'
(( GATE_STATUS == 0 )) \
  || fail "a junk term-open budget in the conf broke term open: $GATE_STATUS ($GATE_STDERR)"
[[ "$GATE_STDOUT" == "opened term-"* ]] \
  || fail "term open opened a window but recorded no id: $GATE_STDOUT"
JUNK_BUDGET_TERM="${GATE_STDOUT#opened }"
JUNK_BUDGET_TERM="${JUNK_BUDGET_TERM%% *}"
assert_allowed "term close $JUNK_BUDGET_TERM" 'closing the window opened under a junk budget'
pass "a junk term-open budget in the conf falls back to the default, never opening without recording"

assert_allowed 'term focus term-1' 'term focus on a window this gate opened'
assert_allowed 'term close term-1' 'term close on a window this gate opened'
assert_denied 'term focus term-1' 'term focus after the window was closed'

# --- the command is resolved to a file BEFORE anything is opened ------------
#
# Field failure 2026-08-30: `term open ghostty lv-attach` opened an EMPTY
# Ghostty window and then failed with a window-identification message. The
# launcher said `exec lv-attach` and relied on PATH; a script started by
# `open -n -a Ghostty --args -e <script>` gets no login-shell environment and
# `$HOME/bin` is on neither its PATH nor sshd's, so the launcher hit `command
# not found` and exited instantly. The window was real, the diagnosis was not.

# An allowlisted name with nothing behind it must refuse with NOTHING opened,
# and say which of the two problems it is.
mv "$FAKE_HOME/bin/lv-attach" "$FAKE_HOME/bin/lv-attach.aside"
: >"$TMP_DIR/open.log"
assert_denied 'term open ghostty lv-attach' 'an allowlisted command that is not installed'
[[ ! -s "$TMP_DIR/open.log" ]] \
  || fail "term open opened a window for a command it could not resolve: $(cat "$TMP_DIR/open.log")"
[[ "$(log_tail)" == *"is not an executable file"* ]] \
  || fail "the unresolvable refusal did not name the real problem: $(log_tail)"
pass "an allowlisted command that is not installed refuses without opening a window"

# And it is visible BEFORE a verb is tried, which is the whole point.
run_gate 'state'
[[ "$GATE_STDOUT" == *'"unresolvable":["lv-attach"]'* ]] \
  || fail "state did not report the allowlisted name that resolves to nothing: $GATE_STDOUT"
pass "state reports an allowlisted command with no executable behind it"

# Not executable is the same fault wearing a different hat (a copy that lost
# its mode bit is exactly what an interrupted install leaves).
install -m 0600 "$FAKE_HOME/bin/lv-attach.aside" "$FAKE_HOME/bin/lv-attach"
assert_denied 'term open ghostty lv-attach' 'an allowlisted command that is not executable'
run_gate 'state'
[[ "$GATE_STDOUT" == *'"unresolvable":["lv-attach"]'* ]] \
  || fail "state treated a non-executable file as resolvable: $GATE_STDOUT"
install -m 0700 "$FAKE_HOME/bin/lv-attach.aside" "$FAKE_HOME/bin/lv-attach"
rm -f "$FAKE_HOME/bin/lv-attach.aside"
pass "a file that is not executable does not read as an installed command"

# The allowlist is about NAMES; resolution is about where a name lives. A path
# in the command position is refused outright rather than resolved.
write_conf 'LV_UI_TERM_COMMANDS="lv-attach /bin/sh ../bin/lv-attach"'
assert_denied 'term open ghostty /bin/sh' 'an absolute path in the command position'
assert_denied 'term open ghostty ../bin/lv-attach' 'a relative path in the command position'
write_conf 'LV_UI_TERM_COMMANDS="lv-attach"'
pass "term open takes a command name, never a path"

# --- the window is identified by a CGWindowID, never by a title marker ------
#
# Field failure 2026-08-30: `term open ghostty lv-attach` reported "opened
# Ghostty but never saw a window carrying marker lvui-term-1-…" while a real
# window sat on the owner's screen. `lv-attach` execs a whole-view herdr
# client, and herdr owns the terminal title from the moment it starts —
# docs/agent/invariants.md says a title marker "can neither reach nor come
# back from a herdr-hosted session", which is also why the app's own
# titleMarker join arm is suppressed there. The gate reused a title marker
# anyway, so the one command this verb exists to run could never be seen, and
# the window it did open was left unregistered: `term focus`/`term close`
# could not address it, and nothing could close it.

clear_state
: >"$TMP_DIR/swift.log"
run_gate 'term open ghostty lv-attach pane-7' STUB_PGREP_PID=$$ STUB_TERM_SNAPSHOT="4001,4002"
(( GATE_STATUS == 0 )) || fail "term open failed: $GATE_STDERR"
# The snapshot is taken BEFORE `open`, and the ids it found are what the new
# window is diffed against. Without that this verb is back to asking the child
# process to tag its own window.
grep -q 'termsnapshot' "$TMP_DIR/swift.log" \
  || fail "term open did not snapshot the terminal's windows before opening one: $(cat "$TMP_DIR/swift.log")"
grep -q 'termnew .* 4001,4002' "$TMP_DIR/swift.log" \
  || fail "term open did not exclude the windows that existed before it ran: $(cat "$TMP_DIR/swift.log")"
TERM_ID="${GATE_STDOUT#opened }"
TERM_ID="${TERM_ID%% *}"
grep -q 'window=9001' "$FAKE_HOME/.localvoxtral-ui-gate/terms/$TERM_ID.state" \
  || fail "term open did not record the window id it resolved"
pass "term open identifies its window by what appeared since a pre-open snapshot"

: >"$TMP_DIR/swift.log"
assert_allowed "term focus $TERM_ID" 'term focus by recorded window id'
grep -q "termaction $$ 9001 focus" "$TMP_DIR/swift.log" \
  || fail "term focus did not address the recorded window id: $(cat "$TMP_DIR/swift.log")"
: >"$TMP_DIR/swift.log"
assert_allowed "term close $TERM_ID" 'term close by recorded window id'
grep -q "termaction $$ 9001 close" "$TMP_DIR/swift.log" \
  || fail "term close did not address the recorded window id: $(cat "$TMP_DIR/swift.log")"
pass "term focus and term close address a window id, not a title"

# The marker survives only as a tie-breaker for commands that leave the title
# alone. It must not be what any verb depends on.
TERMNEW_BODY="$(helper_case_body termnew)"
grep -q 'excluded' <<<"$TERMNEW_BODY" \
  || fail "termnew no longer decides on the pre-open snapshot"
grep -q 'TIE-BREAKER' <<<"$TERMNEW_BODY" \
  || fail "the marker is no longer documented as a tie-breaker in termnew"
TERMACTION_BODY="$(helper_case_body termaction)"
grep -q 'marker' <<<"$TERMACTION_BODY" \
  && fail "termaction still resolves a window by title marker — herdr overwrites it"
pass "no term verb resolves a window by a title herdr can overwrite"

# --- a failed term open leaves no residue -----------------------------------
#
# The same field failure left an orphaned Ghostty window running a herdr client
# that no verb could reach. If this verb cannot identify what it opened, it
# must take back what it started.

clear_state
: >"$TMP_DIR/open.log"
run_gate 'term open ghostty lv-attach pane-7' \
  STUB_PGREP_PID=$$ STUB_TERMNEW=none STUB_OPEN_SPAWN=1
(( GATE_STATUS != 0 )) || fail "term open reported success with no window resolved"
[[ "$GATE_STDERR" == *"no new window appeared"* ]] \
  || fail "term open did not say what went wrong: $GATE_STDERR"
[[ "$GATE_STDERR" == *"terminated the command it started"* ]] \
  || fail "term open did not reclaim the process it started: $GATE_STDERR"
ORPHAN_PIDFILE="$(find "$FAKE_HOME/.localvoxtral-ui-gate/terms" -name '*.pid' 2>/dev/null | head -n 1 || true)"
[[ -z "$ORPHAN_PIDFILE" ]] \
  || fail "term open left a pid file behind after failing: $ORPHAN_PIDFILE"
[[ -z "$(find "$FAKE_HOME/.localvoxtral-ui-gate/terms" -name 'term-*.state' 2>/dev/null || true)" ]] \
  || fail "a failed term open registered a terminal anyway"
pass "a term open that cannot identify its window kills what it started and registers nothing"

# --- and it does not tell the wrong story about WHY -------------------------
#
# Three faults live behind "no window": the terminal never ran the launcher,
# the command ran and exited immediately, and the command is running but the
# window could not be identified. They have completely different fixes, and
# reporting the second as the third is what produced a confidently wrong root
# cause on 2026-08-30. The launcher writes its pid before `exec`, so the pid
# file separates them.

clear_state
run_gate 'term open ghostty lv-attach pane-7' STUB_PGREP_PID=$$ STUB_TERMNEW=none
(( GATE_STATUS != 0 )) || fail "term open reported success with no launcher run"
[[ "$GATE_STDERR" == *"never ran the launcher"* ]] \
  || fail "a launcher that never ran was not reported as such: $GATE_STDERR"
[[ "$GATE_STDERR" == *"not a window-identification problem"* ]] \
  || fail "the message does not rule out the fault it is NOT: $GATE_STDERR"
pass "a terminal that never ran the launcher says so, and says what it is not"

clear_state
run_gate 'term open ghostty lv-attach pane-7' \
  STUB_PGREP_PID=$$ STUB_TERMNEW=none STUB_OPEN_SPAWN=dead
(( GATE_STATUS != 0 )) || fail "term open reported success for a command that exited"
[[ "$GATE_STDERR" == *"exited immediately"* ]] \
  || fail "a command that exited was not reported as such: $GATE_STDERR"
[[ "$GATE_STDERR" == *"empty terminal window"* ]] \
  || fail "the message does not connect the fault to what the owner sees: $GATE_STDERR"
[[ "$GATE_STDERR" == *"$FAKE_HOME/bin/lv-attach pane-7"* ]] \
  || fail "the message does not hand back the command to run by hand: $GATE_STDERR"
[[ "$GATE_STDERR" != *"no new window appeared"* ]] \
  || fail "a failed COMMAND was reported as a window-identification timeout: $GATE_STDERR"
pass "a command that exits immediately is reported as a failed command, not a missing window"

# Several windows at once: waiting longer cannot make that less ambiguous, and
# binding the wrong one would point `term close` at whatever the owner just
# opened. Refuse, say so, and still leave nothing behind.
clear_state
run_gate 'term open ghostty lv-attach pane-7' \
  STUB_PGREP_PID=$$ STUB_TERMNEW=ambiguous STUB_OPEN_SPAWN=1
(( GATE_STATUS != 0 )) || fail "term open bound a window while several appeared at once"
[[ "$GATE_STDERR" == *"several windows appeared"* ]] \
  || fail "the ambiguous case did not explain itself: $GATE_STDERR"
[[ "$GATE_STDERR" == *"terminated the command it started"* ]] \
  || fail "the ambiguous case did not reclaim the process it started: $GATE_STDERR"
[[ -z "$(find "$FAKE_HOME/.localvoxtral-ui-gate/terms" -name 'term-*.state' 2>/dev/null || true)" ]] \
  || fail "the ambiguous case registered a terminal anyway"
pass "term open refuses to guess between windows that appeared at the same moment"

# --- the marker is HELD until this gate has read it -------------------------
#
# The tie-breaker used to be a race. `lv-attach` execs a whole-view herdr
# client and herdr owns the terminal title from its first painted frame, so
# the marker survived only for as long as `open` plus an ssh handshake
# happened to take — and a poll arriving after herdr painted saw an untagged
# window, which is how a real Ghostty open came back "several windows appeared
# at once" twice in a row on 2026-09-05. The launcher now blocks on an ack the
# gate writes when it resolves a window, so the tag is guaranteed to still be
# there while the gate is looking.

clear_state
run_gate 'term open ghostty lv-attach pane-7' STUB_PGREP_PID=$$ STUB_OPEN_SPAWN=1
(( GATE_STATUS == 0 )) || fail "term open failed: $GATE_STDERR"
HELD_ID="${GATE_STDOUT#opened }"
HELD_ID="${HELD_ID%% *}"
HELD_MARKER="$(sed -n 's/^marker=//p' "$FAKE_HOME/.localvoxtral-ui-gate/terms/$HELD_ID.state")"
HELD_SCRIPT="$FAKE_HOME/.localvoxtral-ui-gate/terms/$HELD_MARKER.command"
[[ -f "$HELD_SCRIPT" ]] || fail "term open did not keep the launcher it generated"
grep -q "$HELD_MARKER.ack" "$HELD_SCRIPT" \
  || fail "the launcher does not wait for the gate's ack before exec: $(cat "$HELD_SCRIPT")"
# The wait must sit BETWEEN the title write and the exec, or it holds nothing.
HELD_TITLE_LINE="$(grep -n '033]0;' "$HELD_SCRIPT" | head -n 1 | cut -d: -f1)"
HELD_WAIT_LINE="$(grep -n "$HELD_MARKER.ack" "$HELD_SCRIPT" | head -n 1 | cut -d: -f1)"
HELD_EXEC_LINE="$(grep -n '^exec ' "$HELD_SCRIPT" | head -n 1 | cut -d: -f1)"
(( HELD_TITLE_LINE < HELD_WAIT_LINE && HELD_WAIT_LINE < HELD_EXEC_LINE )) \
  || fail "the ack wait is not between the title write and the exec: $(cat "$HELD_SCRIPT")"
# And the gate released it, or the launcher would sit there after the gate
# stopped looking.
[[ -e "$FAKE_HOME/.localvoxtral-ui-gate/terms/$HELD_MARKER.ack" ]] \
  || fail "term open never acked the marker it asked the launcher to hold"
assert_allowed "term close $HELD_ID" 'term close after a held-marker open'
[[ ! -e "$FAKE_HOME/.localvoxtral-ui-gate/terms/$HELD_MARKER.ack" ]] \
  || fail "term close left the ack file behind"
pass "the launcher holds its marker until the gate acks it, and the gate always does"

# --- an instance this gate SPAWNED is reclaimed whole -----------------------
#
# Only the ghostty branch passes `open -n`, because `--args` reach an app only
# when `open` LAUNCHES it — and a brand-new instance runs the whole macOS
# launch path, state restoration included, so it can put the owner's saved
# window set on screen beside the `-e` window. Killing the launcher closes ONE
# of those. Every process of that name that was not in the pre-open snapshot
# belongs to the instance this gate started, so the reclaim is all of them.

clear_state
: >"$TMP_DIR/open.log"
rm -f "$TMP_DIR/open.log.opened"
# Two live stand-ins for the instance `open -n` created: the `-e` window's
# process and one macOS restored beside it.
/bin/sh -c 'exec /bin/sleep 300' &
INSTANCE_A=$!
/bin/sh -c 'exec /bin/sleep 300' &
INSTANCE_B=$!
printf '%s\n%s\n' "$INSTANCE_A" "$INSTANCE_B" >>"$SPAWNED_PIDS"
run_gate 'term open ghostty lv-attach pane-7' \
  STUB_PGREP_PID="$$" STUB_PGREP_PID_AFTER="$$ $INSTANCE_A $INSTANCE_B" \
  STUB_TERMNEW=ambiguous STUB_OPEN_SPAWN=1
(( GATE_STATUS != 0 )) || fail "term open bound a window while several appeared at once"
[[ "$GATE_STDERR" == *"terminated the Ghostty instance it started"* ]] \
  || fail "the gate did not reclaim the instance it spawned: $GATE_STDERR"
[[ "$GATE_STDERR" == *"nothing was left on the desktop"* ]] \
  || fail "the gate did not say the desktop was left clean: $GATE_STDERR"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$INSTANCE_A" 2>/dev/null || kill -0 "$INSTANCE_B" 2>/dev/null || break
  /bin/sleep 0.1
done
kill -0 "$INSTANCE_A" 2>/dev/null \
  && fail "the gate left a process of the instance it spawned running (pid $INSTANCE_A)"
kill -0 "$INSTANCE_B" 2>/dev/null \
  && fail "the gate left a window of the instance it spawned on the desktop (pid $INSTANCE_B)"
# The pid that was there BEFORE is the owner's, and it is never signalled.
kill -0 "$$" 2>/dev/null || fail "the gate reclaimed a process that predated it"
pass "a failed term open terminates the whole instance it spawned, and only that"

# --- a REUSED instance's windows are recorded, not killed -------------------
#
# Terminal and iTerm take the launcher as a document and reuse whatever is
# already running, so an extra window there may be the owner's and must not be
# closed on this gate's initiative. What it must not do either is what it did
# on 2026-09-05: refuse, and leave windows it had just seen with no id, so no
# verb could reach them and the owner closed them by hand.

clear_state
: >"$TMP_DIR/open.log"
rm -f "$TMP_DIR/open.log.opened"
run_gate 'term open terminal lv-attach pane-7' \
  STUB_PGREP_PID=$$ STUB_TERMNEW=ambiguous STUB_OPEN_SPAWN=1
(( GATE_STATUS != 0 )) || fail "term open bound a window while several appeared at once"
[[ "$GATE_STDERR" == *"recorded UNCONFIRMED"* ]] \
  || fail "the reused-instance ambiguity did not record what it saw: $GATE_STDERR"
UNCONFIRMED_STATES="$(find "$FAKE_HOME/.localvoxtral-ui-gate/terms" -name 'term-*.state' | sort)"
[[ -n "$UNCONFIRMED_STATES" ]] \
  || fail "the gate recorded no id for the windows it saw"
UNCONFIRMED_COUNT="$(printf '%s\n' "$UNCONFIRMED_STATES" | grep -c .)"
(( UNCONFIRMED_COUNT == 2 )) \
  || fail "expected one record per window the helper named, got $UNCONFIRMED_COUNT"
for state_file in $UNCONFIRMED_STATES; do
  grep -q '^unconfirmed=1$' "$state_file" \
    || fail "a recorded window is not marked unconfirmed: $state_file"
done
FIRST_UNCONFIRMED="$(basename "$(printf '%s\n' "$UNCONFIRMED_STATES" | head -n 1)" .state)"
# Reachable to CLOSE, never to FOCUS: closing a window this gate may have
# opened is recoverable; raising one in front of the owner is a takeover it
# cannot justify without knowing whose window it is.
assert_denied "term focus $FIRST_UNCONFIRMED" 'focusing an unconfirmed window' \
  STUB_PGREP_PID=$$
grep -q 'UNCONFIRMED' "$LOG_FILE" \
  || fail "the unconfirmed refusal was not logged with its reason"
run_gate 'state' STUB_PGREP_PID=$$
[[ "$GATE_STDOUT" == *'"unconfirmed":true'* ]] \
  || fail "state does not report an unconfirmed terminal as such: $GATE_STDOUT"
assert_allowed "term close $FIRST_UNCONFIRMED" 'closing an unconfirmed window' \
  STUB_PGREP_PID=$$
pass "a reused instance's ambiguous windows are recorded, closeable, and never focusable"

clear_state

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
grep -q "termaction ${SELF_PID} [0-9]" "$TMP_DIR/swift.log" \
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
# is a real compile; off a Mac (no AppKit) it is skipped, and says so.
if [[ "$(uname -s)" == Darwin ]] && command -v swiftc >/dev/null 2>&1; then
  HELPER_DIR="$TMP_DIR/helper"
  mkdir -p "$HELPER_DIR"
  awk '/^  cat <<.SWIFT.$/ { capture = 1; next }
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
  printf 'SKIP: no macOS swiftc — the embedded Swift helper was not type checked\n'
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
run_gate 'menu open' "${APP_ENV[@]}" "${LEASE_HOLD[@]}" STUB_MENU_FAIL=1
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

# `menu open` must report a menu it can SEE, not one that is merely attached.
#
# Field check 2026-08-29: against a freshly launched build that had displayed
# nothing, `menu open` printed "ok already-open" and returned instantly,
# `shot popover` then reported no popover window owned by that pid, and
# `ax dump all` returned `[]`. An NSMenu handed to an NSStatusItem is an AXMenu
# CHILD of the status item whether or not it is on screen, so the pre-check
# that looked for that child matched every time, the status item was never
# pressed, and the verb reported success for doing nothing.
#
# The suite stubs the helper, so it cannot run these AX/CGWindow calls. What it
# can pin — and what actually regressed — is which evidence each subcommand
# decides on.
: >"$TMP_DIR/swift.log"
assert_allowed 'menu open' 'menu open passes the helper evidence through' "${APP_ENV[@]}"
[[ "$GATE_STDOUT" == *"window=90210"* ]] \
  || fail "menu open swallowed the window id the helper resolved — a caller cannot tell an open from a no-op: $GATE_STDOUT"
pass "menu open reports the window it resolved, not a bare ok"

grep -q 'func displayedMenuWindow' "$GATE" \
  || fail "the helper has no displayed-menu test — menu open is deciding openness from something else"

# It must BE `shot popover`'s window rule, not a second copy of it: that is
# what makes `menu open` succeed exactly when `shot popover` can then find
# something, and what stops the two verbs drifting apart.
DISPLAYED_BODY="$(helper_func_body displayedMenuWindow)"
[[ "$DISPLAYED_BODY" == *'resolveWindow('*'kind: "popover"'* ]] \
  || fail "displayedMenuWindow does not go through resolveWindow(kind: \"popover\") — menu open and shot popover can now disagree: $DISPLAYED_BODY"

MENUOPEN_BODY="$(helper_case_body menuopen)"
[[ -n "$MENUOPEN_BODY" ]] || fail "could not read the menuopen case body out of the helper"
[[ "$MENUOPEN_BODY" == *'displayedMenuWindow('* ]] \
  || fail "menuopen does not consult the window list — it cannot know a menu is displayed"
[[ "$MENUOPEN_BODY" != *'attachedMenu('* ]] \
  || fail "menuopen decides from the ATTACHED AXMenu again: that child exists whether or not a menu is on screen, so the verb reports success without ever pressing (the 2026-08-29 field bug)"
# The press, and the deliberate not-trusting of its return code, both stay: it
# reports .cannotComplete while a menu tracks.
[[ "$MENUOPEN_BODY" == *'_ = AXUIElementPerformAction(item, kAXPressAction as CFString)'* ]] \
  || fail "menuopen either stopped pressing the status item or started trusting AXPress's return code"
pass "menu open decides openness from the same window rule shot popover resolves"

# The name was the bug: a function called openMenu that answers "is a menu
# attached" reads as correct at every call site.
if grep -q 'func openMenu' "$GATE"; then
  fail "openMenu(of:) is back — the name says 'open', the test is 'attached', and that gap is the whole 2026-08-29 field bug"
fi

# `menu click` deliberately does NOT require a displayed menu: AXPress on a
# menu item works either way, which is how the gate reached Settings while
# `menu open` was broken. It is the fallback when the window test cannot see a
# menu that is genuinely up.
MENUCLICK_BODY="$(helper_case_body menuclick)"
[[ "$MENUCLICK_BODY" == *'attachedMenu('* ]] \
  || fail "menu click no longer reaches the attached menu — it must keep working with the menu closed"
pass "menu click still works against an attached-but-closed menu"

# Dismiss had the same root cause with a worse outcome: its "nothing is open"
# branch was decided by attachment, which is always true, so it never ran — and
# the fallback below it presses the status item, which on a CLOSED menu opens
# one. A dismiss verb must never be able to open a menu.
MENUDISMISS_BODY="$(helper_case_body menudismiss)"
[[ "$MENUDISMISS_BODY" == *'displayedMenuWindow('* ]] \
  || fail "menu dismiss still decides 'nothing is open' from attachment"
NO_MENU_LINE="$(printf '%s\n' "$MENUDISMISS_BODY" | grep -n 'no-menu-open' | head -n 1 | cut -d: -f1 || true)"
FIRST_PRESS_LINE="$(printf '%s\n' "$MENUDISMISS_BODY" | grep -n 'kAXPressAction' | head -n 1 | cut -d: -f1 || true)"
[[ -n "$NO_MENU_LINE" && -n "$FIRST_PRESS_LINE" ]] \
  || fail "menudismiss lost either its no-menu-open answer or its status-item fallback"
(( NO_MENU_LINE < FIRST_PRESS_LINE )) \
  || fail "menu dismiss can reach a status-item press with nothing displayed — a press on a closed menu OPENS one, so dismiss would open the thing it exists to close"
pass "menu dismiss returns no-menu-open before it can press anything"

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

echo "== 16. dictate — the only verb that can start a session =="

# Without this verb the gate can open the UI but never exercise the thing it
# exists to debug: the Claude Code / herdr join resolves when a dictation
# STARTS, and `key`'s allowlist is escape/tab/return while the app's trigger is
# a modifier-only gesture.

DICTATE_ENV=(
  "${APP_ENV[@]}"
  STUB_DEFAULT_settings_modifier_only_hotkey_enabled=1
  STUB_DEFAULT_settings_modifier_only_hotkey_modifier=right_command
  STUB_DEFAULT_settings_modifier_only_hold_delay=0.35
)

clear_state
assert_denied 'dictate tap' 'dictate with no app under test' "${DICTATE_ENV[@]}"

write_app_state 4242
LOCK_STATE=locked
assert_denied 'dictate tap' 'dictate while the screen is locked' "${DICTATE_ENV[@]}"
assert_denied 'dictate cancel' 'dictate cancel while the screen is locked' "${DICTATE_ENV[@]}"
LOCK_STATE=unlocked

# Reading the trigger, never assuming it: a guess here is a modifier posted
# into whatever the owner has focused.
assert_denied 'dictate tap' 'dictate when the app trigger settings cannot be read' "${APP_ENV[@]}"
[[ "$(log_tail)" == *"refusing to guess"* ]] \
  || fail "the unreadable-settings denial did not say why: $(log_tail)"
assert_denied 'dictate tap' 'dictate when the modifier-only trigger is disabled' \
  "${APP_ENV[@]}" STUB_DEFAULT_settings_modifier_only_hotkey_enabled=0
assert_denied 'dictate tap' 'dictate when the configured trigger is unset' \
  "${APP_ENV[@]}" STUB_DEFAULT_settings_modifier_only_hotkey_enabled=1
[[ "$(log_tail)" == *"cannot determine the configured trigger"* ]] \
  || fail "the unset-trigger denial did not say why: $(log_tail)"
assert_denied 'dictate tap' 'dictate with a trigger the app does not define' \
  "${APP_ENV[@]}" STUB_DEFAULT_settings_modifier_only_hotkey_enabled=1 \
  STUB_DEFAULT_settings_modifier_only_hotkey_modifier=left_shift

: >"$TMP_DIR/swift.log"
: >"$TMP_DIR/say.log"
assert_allowed 'dictate tap' 'dictate tap posts the configured trigger' "${DICTATE_ENV[@]}"
grep -q "dictate 4242 right_command tap" "$TMP_DIR/swift.log" \
  || fail "dictate tap did not post the app's configured trigger: $(cat "$TMP_DIR/swift.log")"
grep -q "taking control in 3" "$TMP_DIR/say.log" \
  || fail "dictate tap did not speak the takeover warning (owner rule)"
[[ "$GATE_STDOUT" == *"frontmost="* ]] \
  || fail "dictate did not report where the dictation landed: $GATE_STDOUT"

# The configured trigger is read per invocation, not baked in.
: >"$TMP_DIR/swift.log"
assert_allowed 'dictate tap' 'dictate follows a changed trigger setting' \
  "${APP_ENV[@]}" STUB_DEFAULT_settings_modifier_only_hotkey_enabled=1 \
  STUB_DEFAULT_settings_modifier_only_hotkey_modifier=fn
grep -q "dictate 4242 fn tap" "$TMP_DIR/swift.log" \
  || fail "dictate ignored the app's configured trigger: $(cat "$TMP_DIR/swift.log")"

# A hold shorter than the app's own threshold is a TAP: it would open an
# Overlay Buffer session while the caller asked for Live Auto-Paste, and
# nothing would say so.
assert_denied 'dictate hold 0.2' 'a hold shorter than the app hold delay' "${DICTATE_ENV[@]}"
assert_denied 'dictate hold 0.35' 'a hold exactly equal to the hold delay' "${DICTATE_ENV[@]}"
assert_denied 'dictate hold 600' 'a hold past the duration cap' "${DICTATE_ENV[@]}"
assert_denied 'dictate hold soon' 'a non-numeric hold duration' "${DICTATE_ENV[@]}"
: >"$TMP_DIR/swift.log"
assert_allowed 'dictate hold 2' 'a hold past the threshold and inside the cap' "${DICTATE_ENV[@]}"
grep -q "dictate 4242 right_command hold 2" "$TMP_DIR/swift.log" \
  || fail "dictate hold did not pass the duration through: $(cat "$TMP_DIR/swift.log")"
# The cap follows the app's configured delay, not a constant.
assert_allowed 'dictate hold 0.2' 'a hold that clears a SHORTER configured delay' \
  "${APP_ENV[@]}" STUB_DEFAULT_settings_modifier_only_hotkey_enabled=1 \
  STUB_DEFAULT_settings_modifier_only_hotkey_modifier=right_command \
  STUB_DEFAULT_settings_modifier_only_hold_delay=0.1

# Cancel is Escape: it gives a session back rather than taking the screen, so
# like `quit` it does not warn, and it needs no trigger setting at all.
: >"$TMP_DIR/say.log"
: >"$TMP_DIR/swift.log"
assert_allowed 'dictate cancel' 'dictate cancel with no trigger settings readable' "${APP_ENV[@]}"
grep -q "dictate 4242 none cancel" "$TMP_DIR/swift.log" \
  || fail "dictate cancel did not reach the helper: $(cat "$TMP_DIR/swift.log")"
[[ ! -s "$TMP_DIR/say.log" ]] \
  || fail "dictate cancel spoke a takeover warning for a verb that takes nothing"

# A refused gesture must not read as a started session.
run_gate 'dictate tap' "${DICTATE_ENV[@]}" STUB_DICTATE_FAIL=1
(( GATE_STATUS != 0 )) || fail "dictate reported success when the helper refused"
[[ "$GATE_STDERR" == *"trigger gesture was refused"* ]] \
  || fail "dictate's failure message is unhelpful: $GATE_STDERR"
pass "a refused trigger gesture is a failure, not an ok"

# Source pins for the two things that make this verb work at all and cannot be
# exercised without a desktop.
grep -q 'event.type = .flagsChanged' "$GATE" \
  || fail "the trigger event is no longer a flagsChanged — a plain keyDown never reaches the app's monitor"
grep -q 'IsSecureEventInputEnabled()' "$GATE" \
  || fail "the Secure Keyboard Entry guard is gone — the verb would silently no-op"
grep -q 'DispatchSource.makeSignalSource' "$GATE" \
  || fail "a killed hold would leave the modifier latched down across the owner's session"
# Never activate the app under test before dictating: the session grounds its
# context in whatever is FOCUSED, so stealing focus first defeats the test.
DICTATE_BODY="$(awk '/^run_dictate\(\) \{/ { capture = 1 } capture { print } capture && /^\}$/ { exit }' "$GATE")"
[[ -n "$DICTATE_BODY" ]] || fail "could not find run_dictate in the gate"
grep -q 'activate' <<<"$DICTATE_BODY" \
  && fail "run_dictate activates something — the dictation must land in the FOCUSED app, not localvoxtral"
pass "the dictate verb posts a flagsChanged gesture, guards Secure Keyboard Entry, releases on signal, and never steals focus"

clear_state

echo "== 17. the artifact roots stay owner-only ground =="

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

echo "== 18. install-ui-artifact.sh puts bundles where launch can reach them =="

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
# That refusal, and ONLY that one, is exit 3: ci.yml turns it into a warning
# instead of a red build, because the build was fine and the owner merely had
# the app open. Every other refusal must stay fatal.
(( INSTALL_STATUS == 3 )) \
  || fail "the slot-is-running refusal is exit $INSTALL_STATUS, not the documented 3"
INSTALL_ENV=(LV_UI_ARTIFACT_DEST_ROOT="$INSTALL_ROOT/world")
chmod 0777 "$INSTALL_ROOT/world"
assert_install_refused 'a world-writable root (again, to pin its exit code)' "$SRC_CLEAN"
(( INSTALL_STATUS == 1 )) \
  || fail "a security refusal used exit $INSTALL_STATUS — ci.yml would treat 3 as a warning"
chmod 0755 "$INSTALL_ROOT/world"
pass "only the slot-is-running refusal is exit 3; security refusals stay exit 1"

echo "== 19. try-pr.sh --ui-gate hands off to the gate =="

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

echo "== 20. the dispatched CI build installs itself for the gate =="

# try-pr.sh --ui-gate serves an operator with a shell on the Mac. An agent
# driving the gate has neither a shell nor a verb that runs try-pr.sh, so the
# runner does the install instead: it is a launchd agent in the owner's GUI
# session, which is why $HOME there is the same home the gate's artifact root
# lives under.
CI_YML="$ROOT_DIR/.github/workflows/ci.yml"
INSTALL_STEP="$(awk '/^      - name: Install the dogfood build into the UI gate/ { capture = 1 }
                     capture && /^      - name: / && ++seen > 1 { exit }
                     capture { print }' "$CI_YML")"
[[ -n "$INSTALL_STEP" ]] || fail "ci.yml has no UI-gate install step"
grep -q 'install-ui-artifact.sh' <<<"$INSTALL_STEP" \
  || fail "the UI-gate install step does not go through install-ui-artifact.sh"

# The gating is the whole safety story: an ordinary PR push must never write
# into the owner's home, and the [dogfood-package] marker fires on those.
STEP_IF="$(awk '/^ *if: >-$/ { capture = 1; next } capture && /^ *run:/ { exit } capture { print }' <<<"$INSTALL_STEP")"
[[ -n "$STEP_IF" ]] || fail "the UI-gate install step has no multi-line if: gate"
for required in "runner.environment == 'self-hosted'" \
                "github.event_name == 'workflow_dispatch'" \
                "github.event.inputs.dogfood == 'true'"; do
  grep -qF "$required" <<<"$STEP_IF" \
    || fail "the UI-gate install step is not gated on $required"
done
# `inputs.dogfood` is declared `type: boolean`; comparing a boolean to the
# string 'true' coerces both to numbers (1 vs NaN), so that form is always
# false and the step would silently never run. Only the event payload's
# string copy compares as written.
grep -q "github\.event\.inputs\.dogfood == 'true'" <<<"$STEP_IF" \
  || fail "the dogfood gate must read github.event.inputs.dogfood (the boolean input never equals 'true')"
pass "the UI-gate install step runs only on a workflow_dispatch with dogfood=true"

# Exit 3 (the slot is running) is a warning; anything else fails the build.
grep -q 'STATUS == 3' <<<"$INSTALL_STEP" \
  || fail "the install step no longer special-cases the slot-is-running exit code"
grep -q '::warning::' <<<"$INSTALL_STEP" \
  || fail "the slot-is-running case must warn, not pass silently"
grep -q 'STATUS != 0' <<<"$INSTALL_STEP" \
  || fail "the install step swallows failures other than the slot-is-running one"
pass "a running slot warns; every other install failure is red"

echo "== 21. app — the passthrough to the dogfood control socket =="

# The verb exists because two things about the join are invisible from outside
# the app's process: a dictation has no deterministic trigger, and the session
# registry is per-process, so `--probe-surface` sees only the app's last saved
# copy. What is proved here is that the passthrough stayed a
# passthrough — one fixed socket, five known shapes, a dogfood-only gate.

DOGFOOD_APP_ENV=(
  STUB_PS_LSTART="Mon Aug 24 09:00:00 2026"
  STUB_PS_COMM="$DOGFOOD_APP/Contents/MacOS/localvoxtral"
)

# A real AF_UNIX inode: `[[ -S ]]` is the gate's "is the app exposing one"
# check, and a regular file would pass a laxer test while failing this one.
CONTROL_SOCKET="$TMP_DIR/control.sock"
command -v python3 >/dev/null 2>&1 \
  || fail "python3 is needed to create the AF_UNIX fixture socket"
python3 - "$CONTROL_SOCKET" <<'PYSOCK'
import socket
import sys

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen(1)
PYSOCK
[[ -S "$CONTROL_SOCKET" ]] || fail "the fixture control socket was not created"
NOT_A_SOCKET="$TMP_DIR/not-a-socket"
: >"$NOT_A_SOCKET"

APP_SOCKET_ENV=(LV_UI_CONTROL_SOCKET="$CONTROL_SOCKET")

clear_state
assert_denied 'app join report' 'app with no app under test' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"

# A shipped build compiles no socket at all, so this refusal is the difference
# between one clear line and a connect that never answers.
write_app_state 4242 0 "$CLEAN_APP"
assert_denied 'app join report' 'app against a build with no dogfood stamp' \
  "${APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
[[ "$(log_tail)" == *"not a dogfood build"* ]] \
  || fail "the non-dogfood refusal did not say why: $(log_tail)"

write_app_state 4242 1 "$DOGFOOD_APP"
assert_denied 'app join report' 'app when the app is not exposing a socket' \
  "${DOGFOOD_APP_ENV[@]}" LV_UI_CONTROL_SOCKET="$NOT_A_SOCKET"
[[ "$(log_tail)" == *"dogfood_control_socket_enabled"* ]] \
  || fail "the missing-socket refusal did not name the runtime opt-in: $(log_tail)"

# The forwardable shapes are an allowlist, not "whatever the socket happens to
# understand today". A verb added to the app must be added here too — which is
# the point: an already-installed gate must not gain a capability from an app
# update.
for hostile in \
  'app session start' \
  'app session start turbo' \
  'app session restart overlay' \
  'app registry dump' \
  'app surface read' \
  'app join' \
  'app quit' \
  'app state' \
  'app rm -rf /'
do
  assert_denied "$hostile" "app refuses: ${hostile#app }" \
    "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
done

# The socket path is not an argument, and there is no verb shape that makes it
# one — so a second socket on the machine is unreachable through this gate.
assert_denied "app join report $TMP_DIR/other.sock" 'app cannot be pointed at another socket' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
grep -q 'LV_UI_CONTROL_SOCKET' <<<"$(awk '/^run_app\(\) \{/ { capture = 1 } capture { print } capture && /^\}$/ { exit }' "$GATE")" \
  || fail "run_app no longer reads the fixed socket path"

: >"$TMP_DIR/swift.log"
: >"$TMP_DIR/say.log"
assert_allowed 'app join report' 'app forwards a read-only command' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
grep -q "control $CONTROL_SOCKET join report" "$TMP_DIR/swift.log" \
  || fail "app did not forward the line to the fixed socket: $(cat "$TMP_DIR/swift.log")"
[[ "$GATE_STDOUT" == *'"ok":true'* ]] \
  || fail "app did not return the socket's reply: $GATE_STDOUT"
[[ ! -s "$TMP_DIR/say.log" ]] \
  || fail "a read-only control command spoke a takeover warning"

: >"$TMP_DIR/swift.log"
assert_allowed 'app registry list' 'app forwards registry list' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
grep -q "control $CONTROL_SOCKET registry list" "$TMP_DIR/swift.log" \
  || fail "registry list did not reach the socket: $(cat "$TMP_DIR/swift.log")"

# Owner rule: anything that takes the keyboard warns and waits first.
: >"$TMP_DIR/say.log"
assert_allowed 'app session start overlay' 'app session start warns before taking the screen' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
grep -q "taking control in 3" "$TMP_DIR/say.log" \
  || fail "app session start did not speak the takeover warning (owner rule)"

: >"$TMP_DIR/say.log"
assert_allowed 'app session stop' 'app session stop gives the session back without warning' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
[[ ! -s "$TMP_DIR/say.log" ]] \
  || fail "session stop spoke a takeover warning for a verb that takes nothing"

# Lock policy is per COMMAND: what takes the keyboard, and what would answer a
# question about the wrong surface, are both refused; in-process reads are not.
LOCK_STATE=locked
assert_denied 'app session start overlay' 'app session start while the screen is locked' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
assert_denied 'app session start live' 'app session start live while the screen is locked' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
assert_denied 'app surface probe' 'app surface probe while the screen is locked' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
assert_allowed 'app join report' 'app join report is a read and survives a locked screen' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
assert_allowed 'app registry list' 'app registry list survives a locked screen' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
assert_allowed 'app session stop' 'app session stop survives a locked screen' \
  "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}"
LOCK_STATE=unlocked

# A socket that does not answer must not read as a completed command.
run_gate 'app join report' "${DOGFOOD_APP_ENV[@]}" "${APP_SOCKET_ENV[@]}" STUB_CONTROL_FAIL=1
(( GATE_STATUS != 0 )) || fail "app reported success when the control socket refused"
[[ "$GATE_STDERR" == *"control socket did not answer"* ]] \
  || fail "app's failure message is unhelpful: $GATE_STDERR"
pass "a control socket that does not answer is a failure, not an ok"

# Every invocation is logged with the exact line that crossed.
grep -q 'ALLOW app join report .*(app=join report' "$LOG_FILE" \
  || fail "the gate log does not record what was forwarded"
pass "every app invocation is logged with the forwarded line"

clear_state

echo "== 22. log — bounded, scoped, and never silently empty =="

LOG_FIXTURE="$TMP_DIR/logfixture.txt"

clear_state
# Read-only and focus-free, so unlike the actuation verbs it needs no app under
# test and survives a locked screen.
{
  echo '2026-08-30 10:00:00 localvoxtral ClaudeContext: join abstained tty: stale'
  echo '2026-08-30 10:00:01 localvoxtral Backends: speechd ready'
} >"$LOG_FIXTURE"
: >"$TMP_DIR/log.log"
assert_allowed 'log' 'log with no app under test' STUB_LOG_OUTPUT_FILE="$LOG_FIXTURE"
[[ "$GATE_STDOUT" == *"join abstained"* ]] \
  || fail "log did not return the app's lines: $GATE_STDOUT"

LOCK_STATE=locked
assert_allowed 'log' 'log survives a locked screen' STUB_LOG_OUTPUT_FILE="$LOG_FIXTURE"
LOCK_STATE=unlocked

# The predicate is the difference between a diagnostic and a system-log reader
# on the owner's personal machine.
grep -q 'subsystem == "com.localvoxtral"' "$TMP_DIR/log.log" \
  || fail "log show was not scoped to localvoxtral's subsystem: $(cat "$TMP_DIR/log.log")"
grep -q -- '--last 15m' "$TMP_DIR/log.log" \
  || fail "log did not use its default window: $(cat "$TMP_DIR/log.log")"
pass "log is predicate-scoped to localvoxtral's own subsystem"

# --- and the subsystem alone is NOT enough on this machine ------------------
#
# The Mac that runs this gate is also the self-hosted CI runner, and a unit
# suite logs under localvoxtral's OWN subsystem from `xctest`. Field check
# 2026-08-30: `log 2` returned 111 lines of which exactly one was the app under
# test; the rest were a concurrent CI run, including "Terminal pane joined to a
# live Claude session via title marker". Attributing that to the dictation you
# just made is a wrong conclusion drawn from a real log line — the worst kind
# this verb can produce. So the predicate carries a process as well.

{
  echo '2026-08-30 12:31:47 xctest[19586] [com.localvoxtral:ClaudeContext] Terminal pane joined to a live Claude session via title marker'
  echo '2026-08-30 12:31:49 localvoxtral[4242] [com.localvoxtral:ClaudeContext] Remote herdr forward activity refresh'
} >"$LOG_FIXTURE"

write_app_state 4242
: >"$TMP_DIR/log.log"
assert_allowed 'log' 'log with an app under test is scoped to its pid' \
  "${APP_ENV[@]}" STUB_LOG_OUTPUT_FILE="$LOG_FIXTURE"
grep -q 'processIdentifier == 4242' "$TMP_DIR/log.log" \
  || fail "log was not scoped to the pid launch recorded: $(cat "$TMP_DIR/log.log")"
grep -q 'subsystem == "com.localvoxtral"' "$TMP_DIR/log.log" \
  || fail "the pid scope replaced the subsystem scope instead of narrowing it: $(cat "$TMP_DIR/log.log")"
[[ "$GATE_STDERR" != *"not one instance"* ]] \
  || fail "log warned that it is not pid-scoped while it was: $GATE_STDERR"
grep -q 'log minutes=15 .*pid=4242' "$LOG_FILE" \
  || fail "the gate log does not record which scope the read used: $(log_tail)"
pass "log with an app under test carries the recorded pid in its predicate"

# No app under test: still never `xctest`, but no longer one instance — and it
# has to SAY so. Silently answering with another process's lines is the one
# behaviour that is not available.
clear_state
: >"$TMP_DIR/log.log"
assert_allowed 'log' 'log without an app under test falls back to the process name' \
  STUB_LOG_OUTPUT_FILE="$LOG_FIXTURE"
grep -q 'process == "localvoxtral"' "$TMP_DIR/log.log" \
  || fail "the fallback scope is not the app's process name: $(cat "$TMP_DIR/log.log")"
if grep -q 'processIdentifier' "$TMP_DIR/log.log"; then
  fail "log claimed a pid scope with no app under test: $(cat "$TMP_DIR/log.log")"
fi
[[ "$GATE_STDERR" == *"not one instance"* ]] \
  || fail "the un-pid-scoped fallback did not say so: $GATE_STDERR"
grep -q 'not-pid-scoped' "$LOG_FILE" \
  || fail "the gate log does not record that the read was not pid-scoped: $(log_tail)"
pass "log without an app under test falls back by process name and says it is not one instance"

# A recycled pid must fall back rather than read a stranger's lines: `log` goes
# through the same identity check every other verb does.
write_app_state 4242
: >"$TMP_DIR/log.log"
assert_allowed 'log' 'log falls back when the recorded pid was recycled' \
  STUB_PS_LSTART="Tue Aug 25 11:11:11 2026" \
  STUB_PS_COMM="$CLEAN_APP/Contents/MacOS/localvoxtral" \
  STUB_LOG_OUTPUT_FILE="$LOG_FIXTURE"
if grep -q 'processIdentifier == 4242' "$TMP_DIR/log.log"; then
  fail "log read the lines of a recycled pid as if it were the app under test"
fi
grep -q 'process == "localvoxtral"' "$TMP_DIR/log.log" \
  || fail "a recycled pid did not fall back to process scoping: $(cat "$TMP_DIR/log.log")"
pass "a recycled pid falls back instead of scoping the read to a stranger"

clear_state

: >"$TMP_DIR/log.log"
assert_allowed 'log 42' 'log with an explicit window' STUB_LOG_OUTPUT_FILE="$LOG_FIXTURE"
grep -q -- '--last 42m' "$TMP_DIR/log.log" || fail "log ignored the requested window"

assert_denied 'log 0' 'a zero-minute window'
assert_denied 'log 121' 'a window past the clamp'
assert_denied 'log soon' 'a non-numeric window'
assert_denied 'log 15 30' 'two windows'
assert_denied 'log -5' 'a negative window'

# The app writes its categories `privacy: .public` on purpose; this is the
# cheap way not to depend on every line anyone ever adds being safe.
{
  printf 'token %s in a line\n' "$(printf 'a%.0s' $(seq 1 43))"
  printf 'not a token %s\n' "$(printf 'b%.0s' $(seq 1 42))"
} >"$LOG_FIXTURE"
assert_allowed 'log' 'log masks token-shaped runs' STUB_LOG_OUTPUT_FILE="$LOG_FIXTURE"
[[ "$GATE_STDOUT" == *"<redacted>"* ]] \
  || fail "log did not mask a 43-character base64url run: $GATE_STDOUT"
[[ "$GATE_STDOUT" != *"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"* ]] \
  || fail "log emitted a token-shaped run verbatim"
[[ "$GATE_STDOUT" == *"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"* ]] \
  || fail "log masked a run that is not the token shape — the rule must match DogfoodCaptureRedaction exactly"
pass "log applies the same token-shaped scrub as the dogfood records"

# A cap that silently truncated would make a missing line look like a missing
# event, so the drop is announced.
seq 1 900 | sed 's/^/2026-08-30 10:00:00 localvoxtral line /' >"$LOG_FIXTURE"
assert_allowed 'log' 'log caps its own output' STUB_LOG_OUTPUT_FILE="$LOG_FIXTURE"
(( $(printf '%s\n' "$GATE_STDOUT" | wc -l) <= 400 )) \
  || fail "log exceeded its line cap"
[[ "$GATE_STDERR" == *"dropped by the cap"* ]] \
  || fail "log truncated silently: $GATE_STDERR"

# Nothing to report and the reader being broken must not look the same.
: >"$LOG_FIXTURE"
assert_allowed 'log' 'log says so when there is nothing to report' STUB_LOG_OUTPUT_FILE="$LOG_FIXTURE"
[[ "$GATE_STDERR" == *"no com.localvoxtral entries"* ]] \
  || fail "an empty log window produced no explanation: $GATE_STDERR"
# Which scope found nothing is half the answer: "the app said nothing" and
# "you were reading some other process" look identical without it.
[[ "$GATE_STDERR" == *"entries for process=localvoxtral"* ]] \
  || fail "the empty-window message does not name the scope it searched: $GATE_STDERR"

# The restriction the build gate account actually hits (scripts/mac/README.md).
# It is unverified for the GUI account, so the failure has to name itself.
run_gate 'log' STUB_LOG_RESTRICTED=1
(( GATE_STATUS != 0 )) || fail "a restricted log store read as success"
[[ "$GATE_STDERR" == *"Could not open local log store"* ]] \
  || fail "the restricted-store failure did not quote the reason: $GATE_STDERR"
[[ "$GATE_STDERR" == *"cannot read the unified log"* ]] \
  || fail "the restricted-store failure did not explain itself: $GATE_STDERR"
pass "a restricted log store fails loudly and names itself, rather than returning an empty page"

echo "== 23. lv-attach — the wrapper that makes term open usable =="

# `term open` matches the FIRST token only and then trusts the command with
# every argument it will ever be given, so an allowlisted name is holding the
# boundary. The documented answer used to be a script the owner wrote by hand;
# it ships here instead, and these are the properties that make allowlisting it
# safe.

ATTACH="$ROOT_DIR/scripts/mac/lv-attach.sh"
ATTACH_CONF="$TMP_DIR/lv-attach.conf"
SSH_LOG="$TMP_DIR/ssh.log"

run_attach() { # <conf-contents> [args...]
  local conf="$1"
  shift
  printf '%s\n' "$conf" >"$ATTACH_CONF"
  ATTACH_STATUS=0
  ATTACH_STDERR=""
  : >"$SSH_LOG"
  env -i \
    PATH="$STUB_BIN:/usr/bin:/bin" \
    HOME="$FAKE_HOME" \
    LV_ATTACH_CONF="$ATTACH_CONF" \
    STUB_SSH_LOG="$SSH_LOG" \
    bash "$ATTACH" "$@" >"$TMP_DIR/attach.out" 2>"$TMP_DIR/attach.err" \
    || ATTACH_STATUS=$?
  ATTACH_STDERR="$(cat "$TMP_DIR/attach.err")"
}

assert_attach_refused() { # <description> <conf> [args...]
  local description="$1"
  shift
  run_attach "$@"
  (( ATTACH_STATUS != 0 )) \
    || fail "lv-attach accepted $description (ssh argv: $(cat "$SSH_LOG"))"
  [[ ! -s "$SSH_LOG" ]] \
    || fail "lv-attach ran ssh for $description: $(cat "$SSH_LOG")"
  pass "lv-attach refuses: $description"
}

# The only two shapes the app's own HerdrInvocation classifier accepts. A
# wrapper that opened `herdr terminal attach <pane>` would reliably produce a
# window the app deliberately never joins.
run_attach 'destination=builder' work
(( ATTACH_STATUS == 0 )) || fail "lv-attach refused a valid session name: $ATTACH_STDERR"
[[ "$(cat "$SSH_LOG")" == "-t -- builder herdr --session work" ]] \
  || fail "lv-attach built the wrong argv: $(cat "$SSH_LOG")"
pass "lv-attach execs a fixed whole-view herdr client"

run_attach 'destination=builder'
(( ATTACH_STATUS == 0 )) || fail "lv-attach refused the no-session form: $ATTACH_STDERR"
[[ "$(cat "$SSH_LOG")" == "-t -- builder herdr" ]] \
  || fail "the no-session form built the wrong argv: $(cat "$SSH_LOG")"

run_attach $'destination=builder\nsession=default'
[[ "$(cat "$SSH_LOG")" == "-t -- builder herdr --session default" ]] \
  || fail "lv-attach ignored the configured default session: $(cat "$SSH_LOG")"

run_attach 'destination=deploy@build.local' work
[[ "$(cat "$SSH_LOG")" == "-t -- deploy@build.local herdr --session work" ]] \
  || fail "lv-attach mangled a user@host destination: $(cat "$SSH_LOG")"

# Injection through the identifier — the only caller-controlled value, and one
# that ssh assembles into a string a remote login shell interprets.
assert_attach_refused 'a semicolon in the identifier'   'destination=builder' 'work;id'
assert_attach_refused 'a command substitution'          'destination=builder' 'work$(id)'
assert_attach_refused 'a backtick'                      'destination=builder' 'work`id`'
assert_attach_refused 'a pipe'                          'destination=builder' 'work|id'
assert_attach_refused 'an ampersand'                    'destination=builder' 'work&'
assert_attach_refused 'a space'                         'destination=builder' 'work sh'
assert_attach_refused 'a newline'                       'destination=builder' $'work\nid'
assert_attach_refused 'a quote'                         'destination=builder' "work'"
assert_attach_refused 'a slash'                         'destination=builder' 'work/../etc'
assert_attach_refused 'an ssh option'                   'destination=builder' '-oProxyCommand=id'
assert_attach_refused 'a leading dash'                  'destination=builder' '-t'
assert_attach_refused 'a long identifier'               'destination=builder' "$(printf 'a%.0s' $(seq 1 65))"
assert_attach_refused 'a second argument'               'destination=builder' 'work' 'extra'
assert_attach_refused 'an empty identifier'             'destination=builder' ''

# The destination is not caller-controlled, but a config file is still a file.
rm -f "$ATTACH_CONF"
ATTACH_STATUS=0
env -i PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" \
  LV_ATTACH_CONF="$ATTACH_CONF" STUB_SSH_LOG="$SSH_LOG" \
  bash "$ATTACH" work >/dev/null 2>&1 || ATTACH_STATUS=$?
(( ATTACH_STATUS != 0 )) || fail "lv-attach ran with no config file"
pass "lv-attach refuses: no config file"

assert_attach_refused 'a config with no destination' 'session=work' 'work'
assert_attach_refused 'a destination that is an ssh option' 'destination=-oProxyCommand=id' 'work'
assert_attach_refused 'a destination with a space'   'destination=builder sh' 'work'
assert_attach_refused 'a destination with a colon'   'destination=builder:2222' 'work'

# --- `--check`: the one flag, and the reason the gate has one source of truth
#
# The UI gate's `state` asks the INSTALLED wrapper whether its config resolves
# rather than re-reading ~/.lv-attach.conf itself, so this flag is now part of
# the boundary's contract. What has to stay true: it prints a verdict, it runs
# NOTHING, and it does not turn the wrapper into a thing that takes flags.

run_attach $'destination=builder\n' --check
(( ATTACH_STATUS == 0 )) || fail "--check refused a resolvable config: $ATTACH_STDERR"
CHECK_OUT="$(cat "$TMP_DIR/attach.out")"
[[ "$CHECK_OUT" == *"conf=ok"* ]] || fail "--check did not report conf=ok: $CHECK_OUT"
[[ "$CHECK_OUT" == *"destination_kind=alias"* ]] \
  || fail "--check did not classify a bare alias: $CHECK_OUT"
[[ "$CHECK_OUT" == *"destination=builder"* ]] \
  || fail "--check withheld a bare alias, which is the value an operator needs: $CHECK_OUT"
[[ "$CHECK_OUT" == *"session=absent"* ]] || fail "--check misreported the session: $CHECK_OUT"
[[ ! -s "$SSH_LOG" ]] || fail "--check ran ssh: $(cat "$SSH_LOG")"
pass "lv-attach --check reports a resolvable config and runs nothing"

run_attach $'destination=builder\nsession=work\n' --check
[[ "$(cat "$TMP_DIR/attach.out")" == *"session=configured"* ]] \
  || fail "--check did not see the configured default session"

# A `user@host` destination is an account AND an address. The gate's stated
# posture is that no host, account or session id crosses it (`app` answers in a
# closed vocabulary for the same reason), so the SHAPE is reported and the
# value is not. A bare alias is a label in the owner's own ~/.ssh/config and is.
run_attach $'destination=deploy@build.local\n' --check
CHECK_OUT="$(cat "$TMP_DIR/attach.out")"
(( ATTACH_STATUS == 0 )) || fail "--check refused a valid user@host destination"
[[ "$CHECK_OUT" == *"destination_kind=user@host"* ]] \
  || fail "--check did not classify a user@host destination: $CHECK_OUT"
[[ "$CHECK_OUT" != *"build.local"* ]] \
  || fail "--check echoed a user@host destination — an account and an address must not cross"
[[ "$CHECK_OUT" != *"deploy"* ]] \
  || fail "--check echoed the account half of a user@host destination"
pass "lv-attach --check reports a user@host destination's shape and withholds its value"

for check_case in "no-destination:session=work" "invalid-destination:destination=-oProxyCommand=id"; do
  expected="${check_case%%:*}"
  conf="${check_case#*:}"
  run_attach "$conf" --check
  (( ATTACH_STATUS != 0 )) || fail "--check reported success for $expected"
  [[ "$(cat "$TMP_DIR/attach.out")" == *"conf=$expected"* ]] \
    || fail "--check did not report conf=$expected: $(cat "$TMP_DIR/attach.out")"
  [[ ! -s "$SSH_LOG" ]] || fail "--check ran ssh while reporting $expected"
  pass "lv-attach --check reports: $expected"
done
# The value it is refusing is arbitrary text from a file; it is not echoed.
[[ "$(cat "$TMP_DIR/attach.out")" != *"ProxyCommand"* ]] \
  || fail "--check echoed the destination it was refusing"

rm -f "$ATTACH_CONF"
ATTACH_STATUS=0
env -i PATH="$STUB_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" \
  LV_ATTACH_CONF="$ATTACH_CONF" STUB_SSH_LOG="$SSH_LOG" \
  bash "$ATTACH" --check >"$TMP_DIR/attach.out" 2>/dev/null || ATTACH_STATUS=$?
(( ATTACH_STATUS != 0 )) || fail "--check reported success with no config file"
[[ "$(cat "$TMP_DIR/attach.out")" == *"conf=missing"* ]] \
  || fail "--check did not report a missing config: $(cat "$TMP_DIR/attach.out")"
pass "lv-attach --check reports: missing"

# --check must not be a precedent. Every other flag is still refused outright.
assert_attach_refused 'a flag that is not --check' 'destination=builder' '--session'
assert_attach_refused 'a flag glued to a value'    'destination=builder' '--check=1'

# Source pins: the properties that make the NAME safe to allowlist, which no
# argv test can prove on its own.
# CODE lines only: the file's own header names `bash -c` and `eval` as the
# things it must not contain, and a scan that could not tell a comment from a
# call would report the documentation as the violation.
ATTACH_SRC="$(grep -v '^[[:space:]]*#' "$ATTACH")"
for forbidden in 'eval ' 'bash -c' 'sh -c' 'source ' '. "$CONF"'; do
  grep -qF "$forbidden" <<<"$ATTACH_SRC" \
    && fail "lv-attach contains a path that can run a command of its own: $forbidden"
done
# Exactly two exec lines, both the fixed ssh argv.
EXEC_LINES="$(grep -c '^[[:space:]]*exec ' <<<"$ATTACH_SRC")"
(( EXEC_LINES == 2 )) || fail "lv-attach has $EXEC_LINES exec lines; expected exactly the two fixed ssh invocations"
grep -q '^[[:space:]]*exec ssh -t -- "\$DESTINATION" herdr$' <<<"$ATTACH_SRC" \
  || fail "the no-session exec is no longer the fixed argv"
grep -q '^[[:space:]]*exec ssh -t -- "\$DESTINATION" herdr --session "\$SESSION"$' <<<"$ATTACH_SRC" \
  || fail "the session exec is no longer the fixed argv"
grep -q '"\$@"' <<<"$ATTACH_SRC" \
  && fail 'lv-attach expands "$@" — an allowlisted command must never forward its arguments to anything'
pass "lv-attach has no path that runs a command of the caller's choosing"

# `ssh` itself must stay permanently refused: the wrapper is the way in, not a
# precedent for widening the denylist.
clear_conf
write_conf 'LV_UI_TERM_COMMANDS="lv-attach ssh"'
assert_denied 'term open ghostty ssh builder' 'ssh stays denylisted even when a conf allowlists it'
: >"$TMP_DIR/open.log"
assert_allowed 'term open ghostty lv-attach work' 'an allowlisted lv-attach reaches term open' \
  STUB_PGREP_PID=5150
clear_conf

echo "== 24. install-ui-artifact.sh ships the wrapper with the build =="

WRAPPER_HOME="$TMP_DIR/wrapper-home"
mkdir -p "$WRAPPER_HOME"
WRAPPER_ROOT="$WRAPPER_HOME/localvoxtral-ui-artifacts"
mkdir -p "$WRAPPER_ROOT"
chmod 0700 "$WRAPPER_ROOT"
WRAPPER_SRC_APP="$(make_bundle_in "$TMP_DIR" wrapper-src.app com.localvoxtral.app localvoxtral absent)"
env HOME="$WRAPPER_HOME" LV_UI_ARTIFACT_DEST_ROOT="$WRAPPER_ROOT" \
  bash "$INSTALLER" "$WRAPPER_SRC_APP" --no-hint >/dev/null 2>&1 \
  || fail "the installer failed on a clean bundle"
[[ -x "$WRAPPER_HOME/bin/lv-attach" ]] \
  || fail "the installer did not place lv-attach where a GUI terminal can resolve it"
# It execs ssh as the owner; other accounts do not get to read or run it.
# BSD stat first, GNU second, each validated on its own — GNU stat's `-f` means
# --file-system and prints a whole block before failing, so an `a || b`
# substitution would capture that block instead of a mode (the same trap
# install-ui-artifact.sh documents).
WRAPPER_MODE="$(stat -f '%Lp' "$WRAPPER_HOME/bin/lv-attach" 2>/dev/null || true)"
[[ "$WRAPPER_MODE" =~ ^[0-7]+$ ]] \
  || WRAPPER_MODE="$(stat -c '%a' "$WRAPPER_HOME/bin/lv-attach" 2>/dev/null || true)"
[[ "$WRAPPER_MODE" == "700" ]] \
  || fail "the installed wrapper is mode $WRAPPER_MODE, not 700"
cmp -s "$ROOT_DIR/scripts/mac/lv-attach.sh" "$WRAPPER_HOME/bin/lv-attach" \
  || fail "the installed wrapper is not the reviewed one from the repo"
pass "a build install ships the reviewed wrapper rather than leaving it hand-maintained"

# The destination is ordinary configuration, and "what is this file called and
# what goes in it" cost a round trip through the owner. A template is written
# when nothing is there — with NO active destination, because an installer that
# filled one in would be guessing which machine to open a terminal onto.
ATTACH_TEMPLATE="$WRAPPER_HOME/.lv-attach.conf"
[[ -f "$ATTACH_TEMPLATE" ]] \
  || fail "the installer left the operator to discover ~/.lv-attach.conf's name and format"
grep -q '^[[:space:]]*destination=' "$ATTACH_TEMPLATE" \
  && fail "the installer wrote an ACTIVE destination — it cannot know which machine to reach"
grep -q '# destination=' "$ATTACH_TEMPLATE" \
  || fail "the template does not show the destination= line it is asking for"
# It resolves to a distinguishable verdict rather than looking like a missing
# file: `no-destination` is what ui-gate-doctor turns into a one-line fix.
ATTACH_STATUS=0
env -i PATH="$STUB_BIN:/usr/bin:/bin" HOME="$WRAPPER_HOME" \
  LV_ATTACH_CONF="$ATTACH_TEMPLATE" STUB_SSH_LOG="$SSH_LOG" \
  bash "$ATTACH" --check >"$TMP_DIR/attach.out" 2>/dev/null || ATTACH_STATUS=$?
[[ "$(cat "$TMP_DIR/attach.out")" == *"conf=no-destination"* ]] \
  || fail "the installed template does not read as no-destination: $(cat "$TMP_DIR/attach.out")"

# Never overwritten: a reinstall that reset the owner's destination would be
# worse than shipping no template at all.
printf 'destination=mymachine\n' >"$ATTACH_TEMPLATE"
env HOME="$WRAPPER_HOME" LV_UI_ARTIFACT_DEST_ROOT="$WRAPPER_ROOT" \
  bash "$INSTALLER" "$WRAPPER_SRC_APP" --no-hint >/dev/null 2>&1 \
  || fail "the installer failed on a reinstall"
[[ "$(cat "$ATTACH_TEMPLATE")" == "destination=mymachine" ]] \
  || fail "a reinstall clobbered the owner's lv-attach destination"
pass "the installer templates ~/.lv-attach.conf once and never overwrites it"

# --- and it does NOT write the gate's allowlist -----------------------------
#
# LV_UI_TERM_COMMANDS lives in ~/.localvoxtral-ui-gate.conf and is the gate's
# ALLOWLIST — the same object as the gate script, one layer up. The rule that
# CI must never write the gate script applies to what the gate will accept for
# exactly the same reason: an empty default exists to force a deliberate grant,
# and a grant that arrives with a build is not one. The owner runs one
# documented append (ui-gate-doctor.sh prints it); this pins that no installer
# ever does it for them.
[[ ! -e "$WRAPPER_HOME/.localvoxtral-ui-gate.conf" ]] \
  || fail "the installer wrote the gate's conf — the term-open allowlist must stay an owner grant"
grep -q 'LV_UI_TERM_COMMANDS=' "$INSTALLER" \
  && fail "install-ui-artifact.sh mentions LV_UI_TERM_COMMANDS as an assignment — it must never write the allowlist"
pass "no installer widens term open's allowlist"


echo
echo "== 25. state reports SETUP readiness, and reports facts rather than contents =="

# Field session 2026-08-30: an operator drove this gate for an hour and hit
# `term open` refusing everything and `app` denying. The causes were three
# ABSENT files and one unset default, each a one-line fix, and NONE of them was
# visible from outside — a missing conf and a broken verb produce the same
# `denied command`. `state` now answers the question the operator actually has,
# which is "which verbs will work if I try them".

state_json() { # <description> [env...]
  local description="$1"
  shift
  run_gate 'state' "$@"
  (( GATE_STATUS == 0 )) \
    || fail "$description: state exited $GATE_STATUS ($GATE_STDERR)"
  printf '%s' "$GATE_STDOUT"
}

state_field() { # <json> <python expression over `s`>
  python3 -c 'import json,sys; s=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$2" <<<"$1"
}

clear_state
clear_conf
rm -f "$FAKE_HOME/.lv-attach.conf" "$FAKE_HOME/bin/lv-attach"

# 1. The state the owner's Mac was actually in.
STATE="$(state_json 'the unconfigured machine')"
python3 -m json.tool <<<"$STATE" >/dev/null || fail "state is no longer valid JSON: $STATE"
[[ "$(state_field "$STATE" 's["setup"]["gate_conf"]["status"]')" == "absent" ]] \
  || fail "state did not report the missing gate conf: $STATE"
[[ "$(state_field "$STATE" 's["setup"]["term_open"]["commands"]')" == "[]" ]] \
  || fail "state claimed term open would accept something with no conf: $STATE"
[[ "$(state_field "$STATE" 's["setup"]["lv_attach"]["installed"]')" == "False" ]] \
  || fail "state claimed the wrapper is installed when it is not: $STATE"
[[ "$(state_field "$STATE" 's["setup"]["control_socket"]["consent"]')" == "unset" ]] \
  || fail "state did not report the control socket's runtime consent: $STATE"
pass "state names every absent piece of setup instead of leaving a verb to fail"

# The prediction has to hold: this is the same refusal the operator hit.
assert_denied 'term open ghostty lv-attach' 'term open with the setup state above'
pass "state's report and term open's refusal agree"

# 2. Configured. The wrapper answers for its own config (one validator, in the
#    file that holds the boundary), so `state` reports what the INSTALLED
#    wrapper says rather than a second copy of its rules.
install -m 0700 "$ATTACH" "$FAKE_HOME/bin/lv-attach"
printf 'destination=builder\nsession=work\n' >"$FAKE_HOME/.lv-attach.conf"
write_conf 'LV_UI_TERM_COMMANDS="lv-attach"'
STATE="$(state_json 'the configured machine')"
[[ "$(state_field "$STATE" 's["setup"]["gate_conf"]["status"]')" == "ok" ]] \
  || fail "state did not report a parsing conf: $STATE"
[[ "$(state_field "$STATE" '" ".join(s["setup"]["term_open"]["commands"])')" == "lv-attach" ]] \
  || fail "state did not report what term open would accept: $STATE"
[[ "$(state_field "$STATE" 's["setup"]["lv_attach"]["allowlisted"]')" == "True" ]] \
  || fail "state did not notice the wrapper is allowlisted: $STATE"
[[ "$(state_field "$STATE" 's["setup"]["lv_attach"]["conf"]')" == "ok" ]] \
  || fail "state did not resolve the wrapper's config: $STATE"
[[ "$(state_field "$STATE" 's["setup"]["lv_attach"]["destination"]')" == "builder" ]] \
  || fail "state withheld a bare ssh alias, which is the value an operator needs: $STATE"
pass "state predicts a working term open, down to the destination it would reach"

: >"$TMP_DIR/open.log"
assert_allowed 'term open ghostty lv-attach work' 'term open with the setup state above' \
  STUB_PGREP_PID=5150
pass "state's report and term open's success agree"

# 3. A user@host destination is an account and an address. `app`'s reply
#    vocabulary deliberately carries no host or session id; the same line is
#    drawn here.
printf 'destination=deploy@build.local\n' >"$FAKE_HOME/.lv-attach.conf"
STATE="$(state_json 'a user@host destination')"
[[ "$(state_field "$STATE" 's["setup"]["lv_attach"]["conf"]')" == "ok" ]] \
  || fail "a valid user@host destination did not resolve: $STATE"
[[ "$(state_field "$STATE" 'repr(s["setup"]["lv_attach"]["destination"])')" == "None" ]] \
  || fail "state echoed a user@host destination: $STATE"
[[ "$STATE" != *"build.local"* ]] || fail "state leaked a destination host: $STATE"
[[ "$STATE" != *"deploy"* ]] || fail "state leaked a destination account: $STATE"
pass "state reports a user@host destination as resolvable without naming it"

printf 'destination=-oProxyCommand=id\n' >"$FAKE_HOME/.lv-attach.conf"
STATE="$(state_json 'a destination the wrapper refuses')"
[[ "$(state_field "$STATE" 's["setup"]["lv_attach"]["conf"]')" == "invalid-destination" ]] \
  || fail "state did not report a refused destination: $STATE"
[[ "$STATE" != *"ProxyCommand"* ]] || fail "state echoed the destination it was refusing: $STATE"
pass "state reports a refused destination without quoting it"

printf 'destination=builder\n' >"$FAKE_HOME/.lv-attach.conf"

# 4. A conf that allowlists a permanently-denied name reads as configured and
#    behaves as unconfigured. Without this the operator sees only "denied".
write_conf 'LV_UI_TERM_COMMANDS="lv-attach ssh"'
STATE="$(state_json 'a conf that allowlists a denylisted name')"
[[ "$(state_field "$STATE" '" ".join(s["setup"]["term_open"]["refused_by_denylist"])')" == "ssh" ]] \
  || fail "state did not flag an allowlisted name the denylist refuses anyway: $STATE"
pass "state flags an allowlist entry the permanent denylist refuses"

# 5. A conf with a syntax error used to take the WHOLE gate down: `source`
#    returns non-zero, `set -e` exits, and the client sees nothing at all. It
#    now degrades to the closed defaults, says so, and is reported.
write_conf 'LV_UI_TERM_COMMANDS="lv-attach'
STATE="$(state_json 'a conf with a syntax error')"
[[ "$(state_field "$STATE" 's["setup"]["gate_conf"]["status"]')" == "unparsable" ]] \
  || fail "state did not report an unparsable conf: $STATE"
[[ "$(state_field "$STATE" 's["setup"]["term_open"]["commands"]')" == "[]" ]] \
  || fail "an unparsable conf did not fall back to the CLOSED default: $STATE"
# A fresh run, not the one above: `STATE="$(state_json ...)"` is a command
# substitution, so run_gate's GATE_STDERR is set in a subshell and never
# reaches here.
run_gate 'state'
[[ "$GATE_STDERR" == *"syntax error"* ]] \
  || fail "an unparsable conf was ignored silently: $GATE_STDERR"
[[ "$GATE_STDERR" == *"EMPTY allowlist"* ]] \
  || fail "the warning does not say what the fallback means: $GATE_STDERR"
assert_denied 'term open ghostty lv-attach' 'term open under an unparsable conf'
pass "an unparsable conf degrades to the closed defaults instead of killing every verb"
clear_conf

# 6. What `launch` would accept, by name — and nothing that is not a validated
#    localvoxtral bundle. Mail.app sits in the same fixture root.
STATE="$(state_json 'the artifact roots')"
ARTIFACT_NAMES="$(state_field "$STATE" '" ".join(sorted(a["name"] for a in s["setup"]["artifacts"]))')"
[[ "$ARTIFACT_NAMES" == "localvoxtral-dogfood.app localvoxtral.app" ]] \
  || fail "state listed the wrong launchable bundles: $ARTIFACT_NAMES"
[[ "$STATE" != *"Mail.app"* ]] \
  || fail "state listed a bundle launch would refuse — the list must be what launch accepts"
[[ "$(state_field "$STATE" 'str([a["dogfood"] for a in s["setup"]["artifacts"] if a["name"]=="localvoxtral-dogfood.app"])')" == "[True]" ]] \
  || fail "state did not distinguish the dogfood slot: $STATE"
pass "state lists exactly the bundles launch would accept, and which are dogfood"

# 7. The control socket: both halves, because `app` needs both.
STATE="$(state_json 'the control socket, armed and bound' \
  STUB_DEFAULT_debug_dogfood_control_socket_enabled=1 \
  LV_UI_CONTROL_SOCKET="$CONTROL_SOCKET")"
[[ "$(state_field "$STATE" 's["setup"]["control_socket"]["present"]')" == "True" ]] \
  || fail "state did not see a bound control socket: $STATE"
[[ "$(state_field "$STATE" 's["setup"]["control_socket"]["consent"]')" == "on" ]] \
  || fail "state did not read the runtime consent: $STATE"
STATE="$(state_json 'the control socket, unbound' LV_UI_CONTROL_SOCKET="$NOT_A_SOCKET")"
[[ "$(state_field "$STATE" 's["setup"]["control_socket"]["present"]')" == "False" ]] \
  || fail "a regular file read as a bound socket: $STATE"
pass "state reports the control socket's consent and whether anything is bound"

# A socket FILE that answers nothing is the case the file test could not see.
# A dogfood build that quit leaves its socket behind, and a build with no
# control socket compiled in never removes a predecessor's — so on 2026-09-05
# `state` said `"present":true` while every `app` command came back
# `could not connect to the control socket (61)`. `state` exists to answer
# "is it safe to drive"; a field in it that cannot fail is not an answer.
STATE="$(state_json 'a control socket file with nothing listening' \
  STUB_DEFAULT_debug_dogfood_control_socket_enabled=1 \
  STUB_CONTROL_DEAD=1 \
  LV_UI_CONTROL_SOCKET="$CONTROL_SOCKET")"
[[ "$(state_field "$STATE" 's["setup"]["control_socket"]["present"]')" == "False" ]] \
  || fail "a dead control socket still read as present: $STATE"
# The consent is a SEPARATE fact and must survive: "armed but not running" is
# exactly the state an operator needs to see, and collapsing it into one
# boolean would say the runtime opt-in had been lost.
[[ "$(state_field "$STATE" 's["setup"]["control_socket"]["consent"]')" == "on" ]] \
  || fail "a dead socket also lost the runtime consent: $STATE"
pass "state reports a socket nothing is listening on as absent, keeping the consent separate"

# 8. Facts, never contents. A conf is sourced by this gate and read by the
#    wrapper; neither file's text may reach the caller.
write_conf 'LV_UI_TERM_COMMANDS="lv-attach"' 'LV_UI_UNRELATED_SECRET="hunter2"'
printf 'destination=builder\n# a private note about the host\n' >"$FAKE_HOME/.lv-attach.conf"
STATE="$(state_json 'a conf carrying an unrelated value')"
[[ "$STATE" != *"hunter2"* ]] || fail "state echoed a conf file's contents: $STATE"
[[ "$STATE" != *"private note"* ]] || fail "state echoed the lv-attach conf's contents: $STATE"
[[ "$STATE" != *"LV_UI_UNRELATED_SECRET"* ]] || fail "state echoed a conf key it does not use: $STATE"
pass "state reports presence and verdicts, never a config file's contents"
clear_conf

# 9. The gate's own revision — "the gate is old" was one of the explanations
#    the operator could not rule out.
STATE="$(state_json 'the gate revision')"
GATE_REV="$(state_field "$STATE" 's["setup"]["gate"]["revision"]')"
[[ "$GATE_REV" =~ ^[0-9a-f]{12}$ ]] || fail "state did not report a gate revision: $GATE_REV"
GATE_SUM="$(shasum -a 256 "$GATE" 2>/dev/null || sha256sum "$GATE" 2>/dev/null || true)"
[[ "${GATE_SUM:0:12}" == "$GATE_REV" ]] \
  || fail "the reported revision is not this file's digest ($GATE_REV vs ${GATE_SUM:0:12})"
pass "state reports which build of the gate answered"

# 10. Still the one verb that answers while locked: readiness is exactly what
#     an operator needs before deciding whether to ask the owner to unlock.
LOCK_STATE=locked
STATE="$(state_json 'state while the screen is locked')"
[[ "$(state_field "$STATE" 's["screen_lock"]')" == "locked" ]] \
  || fail "state lost its lock reporting: $STATE"
[[ -n "$(state_field "$STATE" 's["setup"]["gate"]["revision"]')" ]] \
  || fail "state stopped reporting setup while locked: $STATE"
LOCK_STATE=unlocked
pass "state reports setup while the screen is locked"

echo
echo "== 26. gate-log — the denial reason, without deny explaining itself =="

# `deny` answers every refusal with the same `denied command` ON PURPOSE: a
# gate that explains itself is an oracle for state the caller cannot otherwise
# see. The reason was always written to the gate's own log; what was missing is
# that no verb could read it back, so an agent over SSH saw the generic line
# and had to go through the OWNER to learn a one-line fix. That is a round
# trip, not a boundary. So: a bounded reader, and the deny contract untouched
# (every assert_denied above still pins stdout, stderr and exit 126).

clear_state
clear_conf
assert_denied 'term open ghostty lv-attach' 'the refusal whose reason was invisible'
assert_allowed 'gate-log 5' 'gate-log reads the gate own log'
[[ "$GATE_STDOUT" == *"no allowlisted commands"* ]] \
  || fail "gate-log did not return the reason behind the last denial: $GATE_STDOUT"
[[ "$GATE_STDOUT" == *"DENY term open ghostty lv-attach"* ]] \
  || fail "gate-log did not return the denied command: $GATE_STDOUT"
pass "a denial's reason is reachable in one verb instead of one round trip through the owner"

# Its own ALLOW line is logged BEFORE the read and dropped from the output, so
# `gate-log 1` means "the entry before this one" and never answers with itself.
[[ "$GATE_STDOUT" != *"ALLOW gate-log"* ]] \
  || fail "gate-log returned its own invocation: $GATE_STDOUT"
grep -q 'ALLOW gate-log 5 (gate-log lines=5)' "$LOG_FILE" \
  || fail "gate-log did not log its own invocation: $(log_tail)"
pass "gate-log logs itself and does not answer with itself"

assert_denied 'gate-log 0' 'a zero-line window'
assert_denied 'gate-log 201' 'a window past the clamp'
assert_denied 'gate-log all' 'a non-numeric window'
assert_denied 'gate-log 5 10' 'two windows'
assert_denied 'gate-log -3' 'a negative window'

# Read-only and focus-free, like `log`: a diagnostic that stops working when
# the owner locks the machine is the one case an agent most needs it.
LOCK_STATE=locked
assert_allowed 'gate-log' 'gate-log survives a locked screen'
LOCK_STATE=unlocked
: >"$TMP_DIR/say.log"
run_gate 'gate-log'
[[ ! -s "$TMP_DIR/say.log" ]] \
  || fail "gate-log spoke a takeover warning: $(cat "$TMP_DIR/say.log")"

# It reads ONE file — the one this gate wrote — and it is not a second `log`.
run_gate 'gate-log' STUB_LOG_RESTRICTED=1
(( GATE_STATUS == 0 )) || fail "gate-log went near the unified log: $GATE_STDERR"
pass "gate-log reads the gate's own file and nothing else"

# The same token-shaped scrub the dogfood records and `log` use. These lines
# are ours, but "every line anyone ever adds is safe" is not worth depending on.
printf '%s\n' "2026-08-30T10:00:00+0000 DENY launch $(printf 'a%.0s' $(seq 1 43))" >>"$LOG_FILE"
assert_allowed 'gate-log 3' 'gate-log masks token-shaped runs'
[[ "$GATE_STDOUT" == *"<redacted>"* ]] \
  || fail "gate-log did not mask a 43-character base64url run: $GATE_STDOUT"
[[ "$GATE_STDOUT" != *"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"* ]] \
  || fail "gate-log emitted a token-shaped run verbatim"

# `ax type`'s text is redacted AT WRITE TIME (it is how an API key reaches the
# Engines pane), so reading the log back cannot resurrect it.
assert_denied 'ax type role=AXTextField,title~Endpoint -- sk-secret-value' \
  'ax type with no app under test'
assert_allowed 'gate-log 2' 'gate-log after an ax type'
[[ "$GATE_STDOUT" != *"sk-secret-value"* ]] \
  || fail "gate-log resurrected ax type's text: $GATE_STDOUT"
[[ "$GATE_STDOUT" == *"<redacted>"* ]] \
  || fail "gate-log did not show the redaction marker: $GATE_STDOUT"
pass "gate-log cannot resurrect ax type's text"

# Nothing to show is a sentence, not an empty answer — the same rule `log`
# follows. Its own ALLOW line is always there by then, so an empty result means
# one thing and the message says which.
mv "$LOG_FILE" "$LOG_FILE.aside"
run_gate 'gate-log'
(( GATE_STATUS == 0 )) || fail "gate-log failed with no log file: $GATE_STDERR"
[[ "$GATE_STDERR" == *"no entries before this one"* ]] \
  || fail "gate-log answered emptily with no log file: $GATE_STDERR"
[[ -z "$GATE_STDOUT" ]] || fail "gate-log invented output with no log file: $GATE_STDOUT"
mv "$LOG_FILE.aside" "$LOG_FILE"
pass "gate-log says so when there is nothing before this invocation"

echo
echo "== 27. ui-gate-doctor — the first-install checklist, executable =="

DOCTOR="$ROOT_DIR/scripts/mac/ui-gate-doctor.sh"
DOCTOR_STATE="$TMP_DIR/doctor-state.json"

run_doctor() { # <state-file>
  DOCTOR_STATUS=0
  env -i PATH="/usr/bin:/bin" HOME="$FAKE_HOME" \
    bash "$DOCTOR" --state-file "$1" >"$TMP_DIR/doctor.out" 2>"$TMP_DIR/doctor.err" \
    || DOCTOR_STATUS=$?
  DOCTOR_OUT="$(cat "$TMP_DIR/doctor.out")"
  DOCTOR_ERR="$(cat "$TMP_DIR/doctor.err")"
}

# The unconfigured machine, rendered from a REAL `state` rather than a
# hand-written fixture: the doctor and the gate must not drift apart.
clear_state
clear_conf
rm -f "$FAKE_HOME/.lv-attach.conf"
state_json 'the doctor input' >"$DOCTOR_STATE"
run_doctor "$DOCTOR_STATE"
(( DOCTOR_STATUS == 1 )) \
  || fail "the doctor did not report an unconfigured machine as needing attention (rc $DOCTOR_STATUS): $DOCTOR_ERR"
[[ "$DOCTOR_OUT" == *"[FIX] gate conf"* ]] \
  || fail "the doctor did not flag the missing gate conf: $DOCTOR_OUT"
[[ "$DOCTOR_OUT" == *"[FIX] control socket"* ]] \
  || fail "the doctor did not flag the control socket consent: $DOCTOR_OUT"
[[ "$DOCTOR_OUT" == *"[FIX] lv-attach destination"* ]] \
  || fail "the doctor did not flag the missing lv-attach config: $DOCTOR_OUT"
pass "the doctor turns each invisible piece of setup into a named item"

# The point of a fix line is that it FIXES it. This runs the one the doctor
# printed and then asks the gate whether the verb works — the same loop the
# owner will run, with nothing restated by hand.
DOCTOR_FIX="$(sed -n 's/^ *fix: //p' "$TMP_DIR/doctor.out" | grep 'LV_UI_TERM_COMMANDS' | head -n 1)"
[[ -n "$DOCTOR_FIX" ]] || fail "the doctor named no fix for the empty allowlist: $DOCTOR_OUT"
DOCTOR_FIX="${DOCTOR_FIX//\~\/.localvoxtral-ui-gate.conf/$GATE_CONF}"
( eval "$DOCTOR_FIX" ) || fail "the doctor's fix command did not run: $DOCTOR_FIX"
install -m 0700 "$ATTACH" "$FAKE_HOME/bin/lv-attach"
printf 'destination=builder\n' >"$FAKE_HOME/.lv-attach.conf"
: >"$TMP_DIR/open.log"
assert_allowed 'term open ghostty lv-attach' 'term open after running the doctor fix verbatim' \
  STUB_PGREP_PID=5150
pass "the doctor's fix line is the command that actually fixes it"

state_json 'the doctor input, configured' \
  STUB_DEFAULT_debug_dogfood_control_socket_enabled=1 \
  LV_UI_CONTROL_SOCKET="$CONTROL_SOCKET" >"$DOCTOR_STATE"
run_doctor "$DOCTOR_STATE"
[[ "$DOCTOR_OUT" == *"[ok ] term open allowlist"* ]] \
  || fail "the doctor still flags a configured allowlist: $DOCTOR_OUT"
[[ "$DOCTOR_OUT" == *"[ok ] control socket"* ]] \
  || fail "the doctor still flags an armed control socket: $DOCTOR_OUT"
[[ "$DOCTOR_OUT" == *"[ok ] lv-attach destination"* ]] \
  || fail "the doctor still flags a resolvable destination: $DOCTOR_OUT"
pass "the doctor clears each item as it is fixed"

# The 2026-08-30 blocking failure, as a readiness item: allowlisted, and
# nothing installed behind the name. `term open` used to open an empty window
# and report a window-identification timeout; the doctor now says which of the
# two it is before anything is opened.
mv "$FAKE_HOME/bin/lv-attach" "$FAKE_HOME/bin/lv-attach.aside"
state_json 'the doctor input, allowlisted but not installed' >"$DOCTOR_STATE"
run_doctor "$DOCTOR_STATE"
(( DOCTOR_STATUS == 1 )) || fail "the doctor passed an allowlist that resolves to nothing"
[[ "$DOCTOR_OUT" == *"no executable in ~/bin: lv-attach"* ]] \
  || fail "the doctor did not name the allowlisted command with nothing behind it: $DOCTOR_OUT"
mv "$FAKE_HOME/bin/lv-attach.aside" "$FAKE_HOME/bin/lv-attach"
pass "the doctor names an allowlisted command that is not installed"
clear_conf

# An OLD gate answers `state` without a setup section. Reporting "everything is
# fine" from a document that cannot say otherwise is the failure this whole
# change exists to end.
printf '{"screen_lock":"unlocked","tcc":{"accessibility":true,"screen_recording":true},"app":{"running":false}}\n' \
  >"$DOCTOR_STATE"
run_doctor "$DOCTOR_STATE"
(( DOCTOR_STATUS == 2 )) || fail "the doctor accepted a pre-setup state document (rc $DOCTOR_STATUS)"
[[ "$DOCTOR_ERR" == *"predates setup reporting"* ]] \
  || fail "the doctor did not say the gate is older than it: $DOCTOR_ERR"
pass "the doctor refuses to grade a gate that predates setup reporting"

printf 'localvoxtral ui gate: denied command\n' >"$DOCTOR_STATE"
run_doctor "$DOCTOR_STATE"
(( DOCTOR_STATUS == 2 )) || fail "the doctor read a non-JSON answer as a verdict"
[[ "$DOCTOR_ERR" == *"did not return JSON"* ]] \
  || fail "the doctor did not quote what it got instead of JSON: $DOCTOR_ERR"
pass "the doctor says what it got when the gate did not answer with JSON"

# --- local mode: the two facts the gate cannot report about itself ----------
#
# "The gate is old" and "the key does not force the gate" are the two
# explanations an operator could never rule out from the other end of an SSH
# connection, and they are the two this mode exists for. It runs the INSTALLED
# gate exactly as sshd would, so it grades the copy the key actually reaches.

DOCTOR_HOME="$TMP_DIR/doctor-home"
mkdir -p "$DOCTOR_HOME/bin" "$DOCTOR_HOME/.ssh"
INSTALLED_GATE="$DOCTOR_HOME/bin/localvoxtral-ui-gate.sh"
install -m 0755 "$GATE" "$INSTALLED_GATE"
printf 'restrict,command="%s" ssh-ed25519 AAAA localvoxtral-ui-gate\n' \
  "$INSTALLED_GATE" >"$DOCTOR_HOME/.ssh/authorized_keys"

run_doctor_local() {
  DOCTOR_STATUS=0
  env -i PATH="/usr/bin:/bin" HOME="$DOCTOR_HOME" \
    LV_UI_INSTALLED_GATE="$INSTALLED_GATE" \
    bash "$DOCTOR" >"$TMP_DIR/doctor.out" 2>"$TMP_DIR/doctor.err" \
    || DOCTOR_STATUS=$?
  DOCTOR_OUT="$(cat "$TMP_DIR/doctor.out")"
  DOCTOR_ERR="$(cat "$TMP_DIR/doctor.err")"
}

run_doctor_local
[[ "$DOCTOR_OUT" == *"matches this checkout"* ]] \
  || fail "the doctor did not compare the installed gate with this checkout: $DOCTOR_OUT"
[[ "$DOCTOR_OUT" == *"[ok ] forced command"* ]] \
  || fail "the doctor did not read the forced-command line: $DOCTOR_OUT"
pass "the doctor grades the INSTALLED gate, and says whether it is this one"

printf '# an older gate\n' >>"$INSTALLED_GATE"
run_doctor_local
[[ "$DOCTOR_OUT" == *"[FIX] gate script"* ]] \
  || fail "the doctor called a stale installed gate current: $DOCTOR_OUT"
[[ "$DOCTOR_OUT" == *"install -m 0755"* ]] \
  || fail "the doctor did not name the reinstall command: $DOCTOR_OUT"
install -m 0755 "$GATE" "$INSTALLED_GATE"
pass "an installed gate that differs from this checkout is a FIX, not a silent pass"

# `restrict` is what disables pty, forwarding and user rc files; a forced
# command without it is a gate with the door left ajar.
printf 'command="%s" ssh-ed25519 AAAA localvoxtral-ui-gate\n' \
  "$INSTALLED_GATE" >"$DOCTOR_HOME/.ssh/authorized_keys"
run_doctor_local
[[ "$DOCTOR_OUT" == *"without \`restrict\`"* ]] \
  || fail "the doctor accepted a forced command with no restrict: $DOCTOR_OUT"
: >"$DOCTOR_HOME/.ssh/authorized_keys"
run_doctor_local
[[ "$DOCTOR_OUT" == *"the key would get a shell"* ]] \
  || fail "the doctor accepted a key with no forced command at all: $DOCTOR_OUT"
pass "the doctor flags a key that does not force the gate, or forces it unrestricted"

# A help that trails off mid-sentence into the file's rationale is worse than
# none, so the range it prints is anchored on the usage block's own last line.
run_doctor_help() {
  DOCTOR_STATUS=0
  env -i PATH="/usr/bin:/bin" HOME="$FAKE_HOME" \
    bash "$DOCTOR" --help >"$TMP_DIR/doctor.out" 2>&1 || DOCTOR_STATUS=$?
  DOCTOR_OUT="$(cat "$TMP_DIR/doctor.out")"
}
run_doctor_help
(( DOCTOR_STATUS == 0 )) || fail "--help exited $DOCTOR_STATUS"
[[ "$DOCTOR_OUT" == *"--remote lv-ui"* && "$DOCTOR_OUT" == *"--state-file"* ]] \
  || fail "--help does not show all three modes: $DOCTOR_OUT"
[[ "$DOCTOR_OUT" != *"Why it exists"* ]] \
  || fail "--help spilled past the usage block into the rationale: $DOCTOR_OUT"
# The trailing `# on the Mac's GUI account` comments are part of the usage;
# what must not survive is the leading comment marker of each source line.
if grep -q '^#' "$TMP_DIR/doctor.out"; then
  fail "--help printed the source's leading comment markers: $DOCTOR_OUT"
fi
pass "the doctor's --help prints the usage block, and stops there"

# The README's numbered list is what this replaces; the pointer has to hold.
grep -q 'ui-gate-doctor.sh' "$ROOT_DIR/scripts/mac/README.md" \
  || fail "scripts/mac/README.md does not point at the doctor"

echo
echo "== 29. the takeover lease: one warning per burst, one done per burst =="

# Measured 2026-09-15: `ax click` cost 13.5 s, of which the owner-rule warning
# and its 3 s wait were paid on EVERY verb and "done" was spoken on every verb.
# The rule is about the owner being surprised, and a burst surprises him once.
# So the first GUI verb warns, waits and writes a lease; verbs inside the lease
# window skip the warning and carry it forward; "done" is spoken once, by a
# detached announcer that only speaks if its nonce is still the one on file
# after a window in which NOTHING ran — and speaking it retires the lease, so
# the next burst warns again. The clock is the gate's now_epoch seam
# (NOW_EPOCH), so nothing below waits out a real window.

LEASE_FILE="$FAKE_HOME/.localvoxtral-ui-gate/takeover.lease"
LEASE_SECONDS=120
NOW_EPOCH=1000
clear_state
clear_conf
write_app_state 4242

# `sleep` is instant here, so a burst that is not held open ends the moment it
# starts: the announcer wakes, finds the gate quiet, speaks and retires the
# lease. Every case below that is about a LIVE burst therefore holds the
# announcers inside their window (the sleep stub's hold file, released in case
# 7) and joins them by hand rather than through run_gate.
LEASE_HOLD=(STUB_SLEEP_HOLD_SECONDS=120 STUB_SLEEP_HOLD_FILE="$TMP_DIR/release-announcers")
rm -f "$TMP_DIR/release-announcers"
SKIP_ANNOUNCER_WAIT=1

# 1. The first GUI verb of a burst: warning, the 3 s wait, a lease, an armed
# announcer — and no "done" while the burst is still open.
: >"$TMP_DIR/say.log"
: >"$TMP_DIR/sleep.log"
run_gate 'ax click role=AXButton,title=General' "${APP_ENV[@]}" "${LEASE_HOLD[@]}"
(( GATE_STATUS == 0 )) || fail "lease: first ax click failed: $GATE_STDERR"
grep -q "taking control in 3" "$TMP_DIR/say.log" \
  || fail "lease: the first GUI verb of a burst did not speak the takeover warning"
grep -qx "3" "$TMP_DIR/sleep.log" \
  || fail "lease: the first GUI verb did not wait LV_UI_WARN_SLEEP_SECONDS (sleep.log: $(cat "$TMP_DIR/sleep.log"))"
[[ -f "$LEASE_FILE" ]] || fail "lease: no lease file was written after the first GUI verb"
lease_mode="$(file_mode "$LEASE_FILE")"
[[ "$lease_mode" == "600" ]] || fail "lease: the lease file is mode '$lease_mode', not 0600"
grep -qx "since=1000" "$LEASE_FILE" || fail "lease: the lease did not record the clock: $(cat "$LEASE_FILE")"
grep -q '^announcer=' "$LEASE_FILE" \
  || fail "lease: the warning armed no done-announcer: $(cat "$LEASE_FILE")"
if grep -q "done" "$TMP_DIR/say.log"; then
  fail "lease: done was spoken while the burst was still open"
fi
pass "the first GUI verb warns, waits, writes a 0600 lease and arms the burst's done"

# 2. A GUI verb inside the window: no warning, no wait, a refreshed lease.
: >"$TMP_DIR/say.log"
: >"$TMP_DIR/sleep.log"
NOW_EPOCH=1050
run_gate 'key escape' "${APP_ENV[@]}" "${LEASE_HOLD[@]}"
(( GATE_STATUS == 0 )) || fail "lease: key inside the window failed: $GATE_STDERR"
if grep -q "taking control" "$TMP_DIR/say.log"; then
  fail "lease: a GUI verb 50 s into a 120 s lease spoke the takeover warning again"
fi
if grep -qx "3" "$TMP_DIR/sleep.log"; then
  fail "lease: a GUI verb inside the lease still waited the warning pause"
fi
grep -qx "since=1050" "$LEASE_FILE" || fail "lease: the lease was not refreshed by the leased verb: $(cat "$LEASE_FILE")"
pass "a GUI verb inside the lease window skips the warning and the wait, and refreshes the lease"

# 3. Exactly at the window's edge the lease is spent, and the warning is back.
: >"$TMP_DIR/say.log"
: >"$TMP_DIR/sleep.log"
NOW_EPOCH=1170
run_gate 'ax click role=AXButton,title=General' "${APP_ENV[@]}" "${LEASE_HOLD[@]}"
(( GATE_STATUS == 0 )) || fail "lease: ax click after expiry failed: $GATE_STDERR"
grep -q "taking control in 3" "$TMP_DIR/say.log" \
  || fail "lease: a GUI verb after the lease expired did not warn again"
grep -qx "3" "$TMP_DIR/sleep.log" \
  || fail "lease: a GUI verb after the lease expired did not wait again"
pass "a GUI verb after the lease window warns and waits again"

# 4. A failure inside the window still says "failed" at once — the owner may
# be looking at whatever it left behind — and still skips the warning.
: >"$TMP_DIR/say.log"
NOW_EPOCH=1180
run_gate 'menu open' "${APP_ENV[@]}" "${LEASE_HOLD[@]}" STUB_MENU_FAIL=1
(( GATE_STATUS != 0 )) || fail "lease: menu open with a failing helper reported success"
grep -q "failed" "$TMP_DIR/say.log" \
  || fail "lease: a failed verb inside the lease did not say failed"
if grep -q "taking control" "$TMP_DIR/say.log"; then
  fail "lease: a failed verb inside the lease spoke the takeover warning"
fi
pass "a failed verb inside the lease says failed immediately, without re-warning"

# 5. A clock that stepped back makes the lease worthless, not eternal.
: >"$TMP_DIR/say.log"
NOW_EPOCH=900
run_gate 'key tab' "${APP_ENV[@]}" "${LEASE_HOLD[@]}"
(( GATE_STATUS == 0 )) || fail "lease: key with a stepped-back clock failed: $GATE_STDERR"
grep -q "taking control in 3" "$TMP_DIR/say.log" \
  || fail "lease: a lease dated in the future was honoured"
pass "a lease from the future is not a lease"

# 6. A read-only verb is still the gate working: it pushes the lease forward
# without touching the nonce, so a burst that spends a minute on `shot` and
# `ax dump` between two clicks stays ONE burst — one warning at the top, one
# "done" at the end, silence in between. Measuring the lease from the last
# focus-stealing verb instead announced "done" into the middle of a live
# session (field report 2026-09-20).
NOW_EPOCH=1000
: >"$TMP_DIR/say.log"
run_gate 'ax dump all' "${APP_ENV[@]}" "${LEASE_HOLD[@]}"
(( GATE_STATUS == 0 )) || fail "lease: ax dump failed: $GATE_STDERR"
grep -qx "since=1000" "$LEASE_FILE" \
  || fail "lease: a read-only verb did not carry the lease forward: $(cat "$LEASE_FILE")"
[[ ! -s "$TMP_DIR/say.log" ]] \
  || fail "lease: a read-only verb spoke: $(cat "$TMP_DIR/say.log")"
NOW_EPOCH=1050
run_gate 'key tab' "${APP_ENV[@]}" "${LEASE_HOLD[@]}"
(( GATE_STATUS == 0 )) || fail "lease: key after a read-only verb failed: $GATE_STDERR"
if grep -q "taking control" "$TMP_DIR/say.log"; then
  fail "lease: a GUI verb 50 s after a read-only verb warned again — the burst was cut in two"
fi
pass "read-only verbs carry the burst forward: no second warning inside a working session"

# 6b. And when the gate really does go quiet, the lease lapses: `state` says
# so, and it says how long is left before "done" is spoken.
NOW_EPOCH=1200
STATE="$(state_json 'state with an expired lease' "${APP_ENV[@]}" "${LEASE_HOLD[@]}")"
[[ "$(state_field "$STATE" 's["takeover"]["leased"]')" == "False" ]] \
  || fail "state reported a live lease 150 s after the last verb: $STATE"
NOW_EPOCH=1080
run_gate 'key tab' "${APP_ENV[@]}" "${LEASE_HOLD[@]}"
NOW_EPOCH=1110
STATE="$(state_json 'state with a live lease' "${APP_ENV[@]}" "${LEASE_HOLD[@]}")"
[[ "$(state_field "$STATE" 's["takeover"]["leased"]')" == "True" ]] \
  || fail "state did not report the live lease: $STATE"
# A full window, not 30 s less: `state` is a verb like any other, so asking
# carried the lease forward too. The number answers "if the gate stops now,
# when is done spoken", and `leased` answers "will my next click warn".
[[ "$(state_field "$STATE" 's["takeover"]["remaining_seconds"]')" == "120" ]] \
  || fail "state did not report the lease's remaining seconds: $STATE"
pass "a lease nothing refreshed lapses, and state reports what is left of a live one"

# 7. "done" is spoken ONCE per burst: an announcer whose nonce was superseded
# by a later verb wakes and says nothing. The `sleep 120` of the announcers is
# HELD by the sleep stub until the suite releases it, so two verbs arm two
# announcers before either can speak; on release only the later one may.
: >"$TMP_DIR/say.log"
rm -f "$TMP_DIR/release-announcers"
NOW_EPOCH=3000
SKIP_ANNOUNCER_WAIT=1
run_gate 'ax click role=AXButton,title=General' "${APP_ENV[@]}" \
  STUB_SLEEP_HOLD_SECONDS=120 STUB_SLEEP_HOLD_FILE="$TMP_DIR/release-announcers"
(( GATE_STATUS == 0 )) || fail "lease: burst verb 1 failed: $GATE_STDERR"
first_announcer="$(sed -n 's/^announcer=//p' "$LEASE_FILE" 2>/dev/null || true)"
NOW_EPOCH=3010
run_gate 'key return' "${APP_ENV[@]}" \
  STUB_SLEEP_HOLD_SECONDS=120 STUB_SLEEP_HOLD_FILE="$TMP_DIR/release-announcers"
(( GATE_STATUS == 0 )) || fail "lease: burst verb 2 failed: $GATE_STDERR"
second_announcer="$(sed -n 's/^announcer=//p' "$LEASE_FILE" 2>/dev/null || true)"
[[ -n "$first_announcer" && -n "$second_announcer" && "$first_announcer" != "$second_announcer" ]] \
  || fail "lease: expected two distinct announcers, got '$first_announcer' and '$second_announcer'"
kill -0 "$first_announcer" 2>/dev/null \
  || fail "lease: the first announcer exited before the window — the sleep hold did not take"
if grep -q "done" "$TMP_DIR/say.log"; then
  fail "lease: done was spoken while both announcers were still inside their window"
fi
: >"$TMP_DIR/release-announcers"
unset SKIP_ANNOUNCER_WAIT
for announcer in "$first_announcer" "$second_announcer"; do
  for (( i = 0; i < 300; i++ )); do
    kill -0 "$announcer" 2>/dev/null || break
    /bin/sleep 0.01
  done
  kill -0 "$announcer" 2>/dev/null && fail "lease: announcer $announcer did not exit after release"
done
[[ "$(grep -c "done" "$TMP_DIR/say.log")" == "1" ]] \
  || fail "lease: expected exactly one done for a two-verb burst, say.log: $(cat "$TMP_DIR/say.log")"
pass "done is spoken exactly once per burst: a superseded announcer stays silent"

# 7b. Speaking "done" ENDS the takeover: the announcer retires its own lease,
# so the next verb is a new burst and warns again. Without this the owner
# hears "done" and then a click he was never warned about.
[[ ! -e "$LEASE_FILE" ]] \
  || fail "lease: the announcer spoke done and left the lease standing: $(cat "$LEASE_FILE")"
: >"$TMP_DIR/say.log"
NOW_EPOCH=3020
run_gate 'ax click role=AXButton,title=General' "${APP_ENV[@]}"
(( GATE_STATUS == 0 )) || fail "lease: the verb after done failed: $GATE_STDERR"
grep -q "taking control in 3" "$TMP_DIR/say.log" \
  || fail "lease: the first verb after a spoken done did not warn"
pass "done retires the lease, so the burst after it warns again"

# 7c. The announcement is armed when the takeover is ANNOUNCED, not when the
# verb exits: an invocation killed mid-flight (a harness timeout, a dropped
# link) has already retired the previous announcer, and arming at exit meant
# the burst ended in silence with the lease standing. Here the gate is stopped
# with SIGKILL while `launch` waits for the app to appear — no EXIT trap runs
# — and the burst still announces itself.
#
# Both waits are held until the kill has landed: launch's 0.5 s poll, or the
# gate ends before the kill, and the announcer's `sleep <lease>`, or it speaks
# "done" and retires the lease before this case can see it armed. Either one
# left instant made the case a race it won only on a fast machine.
clear_state
: >"$TMP_DIR/say.log"
rm -f "$TMP_DIR/release-launch-wait"
NOW_EPOCH=4000
SKIP_ANNOUNCER_WAIT=1
# 2>/dev/null: the kill below is the point of the case, and the shell's
# "Killed" notice for it would read like a suite failure in the CI log.
( LAUNCH_WAIT=30; run_gate "launch $CLEAN_APP" "${APP_ENV[@]}" \
    STUB_SLEEP_HOLD_SECONDS="0.5 $LEASE_SECONDS" \
    STUB_SLEEP_HOLD_FILE="$TMP_DIR/release-launch-wait" ) 2>/dev/null &
killed_gate=""
for (( i = 0; i < 1000; i++ )); do
  killed_gate="$(pgrep -f "bash $GATE" 2>/dev/null | head -n 1 || true)"
  [[ -n "$killed_gate" ]] && grep -q '^announcer=' "$LEASE_FILE" 2>/dev/null && break
  killed_gate=""
  /bin/sleep 0.01
done
[[ -n "$killed_gate" ]] \
  || fail "lease: no gate process with an armed announcer appeared to kill"
kill -9 "$killed_gate" 2>/dev/null || true
wait
: >"$TMP_DIR/release-launch-wait"
[[ ! -e "$FAKE_HOME/.localvoxtral-ui-gate/app.state" ]] \
  || fail "lease: the gate finished its launch — the kill did not land where the case needs it"
for (( i = 0; i < 500; i++ )); do
  grep -q "done" "$TMP_DIR/say.log" && break
  /bin/sleep 0.01
done
grep -q "done" "$TMP_DIR/say.log" \
  || fail "lease: a verb killed before its EXIT trap swallowed the burst's done: $(cat "$TMP_DIR/say.log")"
unset SKIP_ANNOUNCER_WAIT
clear_state
write_app_state 4242
pass "a verb killed before its EXIT trap still announces the end of the burst"

# 8. Lease 0 is the v1 rule: warn on every verb, done on every verb, no file.
clear_state
write_app_state 4242
: >"$TMP_DIR/say.log"
LEASE_SECONDS=0
run_gate 'ax click role=AXButton,title=General' "${APP_ENV[@]}"
run_gate 'key escape' "${APP_ENV[@]}"
[[ "$(grep -c "taking control" "$TMP_DIR/say.log")" == "2" ]] \
  || fail "lease off: two GUI verbs should warn twice, say.log: $(cat "$TMP_DIR/say.log")"
[[ "$(grep -c "done" "$TMP_DIR/say.log")" == "2" ]] \
  || fail "lease off: two GUI verbs should announce done twice, say.log: $(cat "$TMP_DIR/say.log")"
[[ ! -e "$LEASE_FILE" ]] || fail "lease off: a lease file was written with the lease disabled"
pass "LV_UI_TAKEOVER_LEASE_SECONDS=0 restores warn-and-done on every verb"

# 9. The conf can set the lease, and a typo in it falls back to the default
# rather than taking the gate down mid-verb.
write_conf 'LV_UI_TAKEOVER_LEASE_SECONDS="two minutes"'
run_gate 'key escape' "${APP_ENV[@]}"
(( GATE_STATUS == 0 )) || fail "lease: a junk lease value in the conf took the gate down: $GATE_STDERR"
clear_conf
pass "a junk lease value in the conf falls back to the default"

unset NOW_EPOCH
LEASE_SECONDS=0
clear_state

echo "== 30. the helper is compiled once per revision, and interpreted only as a fallback =="

# Measured 2026-09-15: every helper call was `swift <file>` — the ~1,500-line
# helper INTERPRETED, about a second each, and some verbs call it twice. The
# gate now compiles it once with `swiftc -O` into a binary named by the
# source's digest, runs that, and falls back to the interpreter only when
# swiftc is missing or fails. There is no swiftc on the Linux runner, so one
# is stubbed here and handed to the gate through its LV_UI_SWIFTC seam
# (SWIFTC_CMD): it "compiles" by installing the swift stub as the output
# binary, which is what lets every swift.log assertion in this suite read the
# compiled form.

SWIFTC_BIN="$TMP_DIR/swiftcbin"
mkdir -p "$SWIFTC_BIN"
cat >"$SWIFTC_BIN/swiftc" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_SWIFTC_LOG"
if [[ -n "${STUB_SWIFTC_FAIL:-}" ]]; then
  echo "error: fake compiler failure" >&2
  exit 1
fi
out=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "-o" ]] && out="$arg"
  prev="$arg"
done
[[ -n "$out" ]] || exit 1
cp "$STUB_SWIFT_STUB" "$out"
chmod +x "$out"
STUB
chmod +x "$SWIFTC_BIN/swiftc"
COMPILED_ENV=("${APP_ENV[@]}" STUB_SWIFT_STUB="$STUB_BIN/swift")
GATE_STATE_DIR="$FAKE_HOME/.localvoxtral-ui-gate"

# The digest-named helper binaries in the state dir, one per line (never the
# source, the compile log, a failure marker or a staging file).
helper_binaries() {
  local candidate
  for candidate in "$GATE_STATE_DIR"/ui-gate-helper-*; do
    [[ -f "$candidate" ]] || continue
    [[ "${candidate##*/}" =~ ^ui-gate-helper-[0-9a-f]{16}$ ]] || continue
    printf '%s\n' "$candidate"
  done
}

clear_state
write_app_state 4242
: >"$TMP_DIR/swiftc.log"
: >"$TMP_DIR/swift.log"
: >"$LOG_FILE"

# 1. First call compiles with -O, runs the binary, and says so in the log.
SWIFTC_CMD="$SWIFTC_BIN/swiftc"
run_gate 'ax dump all' "${COMPILED_ENV[@]}"
(( GATE_STATUS == 0 )) || fail "compiled: ax dump failed: $GATE_STDERR"
[[ "$(wc -l <"$TMP_DIR/swiftc.log" | tr -d ' ')" == "1" ]] \
  || fail "compiled: expected exactly one swiftc invocation, got: $(cat "$TMP_DIR/swiftc.log")"
grep -q -- "-O " "$TMP_DIR/swiftc.log" || fail "compiled: swiftc was not run with -O: $(cat "$TMP_DIR/swiftc.log")"
grep -q -- "$GATE_STATE_DIR/ui-gate-helper.swift" "$TMP_DIR/swiftc.log" \
  || fail "compiled: swiftc was not handed the staged helper source: $(cat "$TMP_DIR/swiftc.log")"
helper_binary="$(helper_binaries)"
[[ -n "$helper_binary" && -x "$helper_binary" ]] \
  || fail "compiled: no digest-named helper binary in $GATE_STATE_DIR: $(ls "$GATE_STATE_DIR")"
helper_mode="$(file_mode "$helper_binary")"
[[ "$helper_mode" == "700" ]] || fail "compiled: the helper binary is mode '$helper_mode', not 0700"
grep -q '^compiled axdump 4242 all' "$TMP_DIR/swift.log" \
  || fail "compiled: ax dump did not run through the compiled binary: $(cat "$TMP_DIR/swift.log")"
grep -q "HELPER compiled ${helper_binary##*/}" "$LOG_FILE" \
  || fail "compiled: the gate log does not record the compile: $(cat "$LOG_FILE")"
[[ "$GATE_STDERR" != *"INTERPRETED"* ]] \
  || fail "compiled: stderr claims the interpreted path ran: $GATE_STDERR"
pass "the first helper call compiles the source with swiftc -O and runs the binary"

# 2. The second call is a cache hit: no swiftc, same binary, source untouched.
source_before="$(ls -i "$GATE_STATE_DIR/ui-gate-helper.swift")"
run_gate 'ax click role=AXButton,title=General' "${COMPILED_ENV[@]}"
(( GATE_STATUS == 0 )) || fail "compiled: cached ax click failed: $GATE_STDERR"
[[ "$(wc -l <"$TMP_DIR/swiftc.log" | tr -d ' ')" == "1" ]] \
  || fail "compiled: a second invocation recompiled: $(cat "$TMP_DIR/swiftc.log")"
grep -q '^compiled axclick 4242 role=AXButton,title=General' "$TMP_DIR/swift.log" \
  || fail "compiled: the cached call did not run the binary: $(cat "$TMP_DIR/swift.log")"
[[ "$(ls -i "$GATE_STATE_DIR/ui-gate-helper.swift")" == "$source_before" ]] \
  || fail "compiled: an unchanged helper source was rewritten (inode changed)"
if ls "$GATE_STATE_DIR"/ui-gate-helper.swift.new.* >/dev/null 2>&1; then
  fail "compiled: a staged source file was left behind: $(ls "$GATE_STATE_DIR")"
fi
pass "an unchanged source reuses the binary and is not rewritten"

# 3. A changed source invalidates the cache: a new binary, the old one gone.
CHANGED_GATE="$TMP_DIR/gate-with-changed-helper.sh"
sed 's|^import Darwin$|import Darwin // helper source changed for section 30|' "$GATE" >"$CHANGED_GATE"
grep -q 'helper source changed for section 30' "$CHANGED_GATE" \
  || fail "compiled: could not produce a gate copy with a changed helper source"
GATE_UNDER_TEST="$CHANGED_GATE"
run_gate 'ax dump all' "${COMPILED_ENV[@]}"
unset GATE_UNDER_TEST
(( GATE_STATUS == 0 )) || fail "compiled: ax dump with a changed helper failed: $GATE_STDERR"
[[ "$(wc -l <"$TMP_DIR/swiftc.log" | tr -d ' ')" == "2" ]] \
  || fail "compiled: a changed helper source did not recompile: $(cat "$TMP_DIR/swiftc.log")"
new_binary="$(helper_binaries)"
[[ -n "$new_binary" ]] || fail "compiled: no binary after the recompile: $(ls "$GATE_STATE_DIR")"
[[ "$new_binary" != "$helper_binary" ]] \
  || fail "compiled: the changed source compiled to the SAME digest name: $new_binary"
[[ ! -e "$helper_binary" ]] \
  || fail "compiled: the stale binary $helper_binary was not deleted"
[[ "$(printf '%s\n' "$new_binary" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "compiled: more than one binary survived the recompile: $new_binary"
pass "a changed helper source compiles to a new digest and deletes the stale binary"

# 4. swiftc failing falls back to the interpreter — loudly, once per digest.
clear_state
write_app_state 4242
: >"$TMP_DIR/swiftc.log"
: >"$TMP_DIR/swift.log"
: >"$LOG_FILE"
run_gate 'ax dump all' "${COMPILED_ENV[@]}" STUB_SWIFTC_FAIL=1
(( GATE_STATUS == 0 )) || fail "fallback: ax dump failed when swiftc failed: $GATE_STDERR"
[[ "$GATE_STDOUT" == '[{"role":"AXWindow"'* ]] || fail "fallback: ax dump lost its output: $GATE_STDOUT"
grep -q "^$GATE_STATE_DIR/ui-gate-helper.swift axdump 4242 all" "$TMP_DIR/swift.log" \
  || fail "fallback: the verb did not run through the interpreter: $(cat "$TMP_DIR/swift.log")"
grep -q "HELPER swiftc failed" "$LOG_FILE" \
  || fail "fallback: the gate log does not record the failed compile: $(cat "$LOG_FILE")"
[[ "$GATE_STDERR" == *"INTERPRETED (swiftc-failed)"* ]] \
  || fail "fallback: stderr did not say the interpreted path ran and why: $GATE_STDERR"
ls "$GATE_STATE_DIR"/ui-gate-helper-*.failed >/dev/null 2>&1 \
  || fail "fallback: no failure marker was left for this digest: $(ls "$GATE_STATE_DIR")"
run_gate 'ax dump all' "${COMPILED_ENV[@]}" STUB_SWIFTC_FAIL=1
(( GATE_STATUS == 0 )) || fail "fallback: second ax dump failed: $GATE_STDERR"
[[ "$(wc -l <"$TMP_DIR/swiftc.log" | tr -d ' ')" == "1" ]] \
  || fail "fallback: a failed compile was retried on the next verb: $(cat "$TMP_DIR/swiftc.log")"
[[ "$GATE_STDERR" == *"INTERPRETED (swiftc-failed)"* ]] \
  || fail "fallback: the second interpreted run was silent about it: $GATE_STDERR"
pass "a failing swiftc falls back to the interpreter, says so, and is not retried per verb"

# 5. `state` reports which path the helper runs on.
STATE="$(state_json 'state under a failed compile' "${COMPILED_ENV[@]}" STUB_SWIFTC_FAIL=1)"
[[ "$(state_field "$STATE" 's["setup"]["helper"]["mode"]')" == "interpreted" ]] \
  || fail "state did not report the interpreted helper: $STATE"
[[ "$(state_field "$STATE" 's["setup"]["helper"]["reason"]')" == "swiftc-failed" ]] \
  || fail "state did not report why the helper is interpreted: $STATE"
clear_state
write_app_state 4242
STATE="$(state_json 'state with a compiled helper' "${COMPILED_ENV[@]}")"
[[ "$(state_field "$STATE" 's["setup"]["helper"]["mode"]')" == "compiled" ]] \
  || fail "state did not report the compiled helper: $STATE"
[[ "$(state_field "$STATE" 's["setup"]["helper"]["binary"]')" =~ ^ui-gate-helper-[0-9a-f]{16}$ ]] \
  || fail "state did not name the helper binary: $STATE"
pass "state reports setup.helper: the mode, and the binary or the reason"

# 6. No swiftc at all (the Linux runner's own situation): interpreted, said on
# stderr, and the verb still works.
unset SWIFTC_CMD
clear_state
write_app_state 4242
run_gate 'ax dump all' "${APP_ENV[@]}"
(( GATE_STATUS == 0 )) || fail "no swiftc: ax dump failed: $GATE_STDERR"
[[ "$GATE_STDERR" == *"INTERPRETED (no-swiftc)"* ]] \
  || fail "no swiftc: stderr did not say why the interpreted path ran: $GATE_STDERR"
pass "without swiftc the helper runs interpreted and says so"
clear_state

echo "== 31. batch — several verbs, one connection, the same gate =="

# A click-by-click session paid an ssh connection, a gate start and (before
# section 30) an interpreted helper per verb. `batch` reads verbs from stdin
# and runs them in order through the very same dispatcher. What this section
# holds: every line is validated before ANY line runs (a bad line refuses the
# whole batch with nothing executed), execution stops at the first failure,
# `batch` is never a valid line, `ax type`'s `--` rule holds per line, and
# each line is its own gate-log entry.

clear_state
write_app_state 4242
: >"$TMP_DIR/swift.log"
: >"$LOG_FILE"

# 1. Happy path: framed output, one log entry per line, every line executed.
batch_lines=$'ax dump all\nax click role=AXButton,title=General\nkey escape'
run_gate 'batch' "${APP_ENV[@]}" <<<"$batch_lines"
(( GATE_STATUS == 0 )) || fail "batch: a valid three-line batch failed: $GATE_STDERR"
batch_tag="$(sed -n 's/^==lvui-batch-\([0-9-]*\)== lines=3$/\1/p' <<<"$GATE_STDOUT")"
[[ -n "$batch_tag" ]] || fail "batch: no tagged header line in the output: $GATE_STDOUT"
for n in 1 2 3; do
  grep -q "^==lvui-batch-$batch_tag== line $n/3 begin " <<<"$GATE_STDOUT" \
    || fail "batch: no begin frame for line $n: $GATE_STDOUT"
  grep -q "^==lvui-batch-$batch_tag== line $n/3 end status=0$" <<<"$GATE_STDOUT" \
    || fail "batch: no end frame with status 0 for line $n: $GATE_STDOUT"
done
grep -q "line 1/3 begin ax dump all" <<<"$GATE_STDOUT" || fail "batch: the begin frame does not name the verb: $GATE_STDOUT"
[[ "$GATE_STDOUT" == *'[{"role":"AXWindow"'* ]] || fail "batch: ax dump's output is missing: $GATE_STDOUT"
grep -q ' axdump 4242 all' "$TMP_DIR/swift.log" || fail "batch: line 1 did not run"
grep -q ' axclick 4242 role=AXButton,title=General' "$TMP_DIR/swift.log" || fail "batch: line 2 did not run"
grep -q ' key 4242 escape' "$TMP_DIR/swift.log" || fail "batch: line 3 did not run"
grep -q ' ALLOW batch (lines=3)' "$LOG_FILE" || fail "batch: no batch-level ALLOW entry: $(cat "$LOG_FILE")"
grep -q ' ALLOW ax dump all (batch line 1/3: pane=all)' "$LOG_FILE" \
  || fail "batch: line 1 has no gate-log entry of its own: $(cat "$LOG_FILE")"
grep -q ' ALLOW ax click role=AXButton,title=General (batch line 2/3: selector=' "$LOG_FILE" \
  || fail "batch: line 2 has no gate-log entry of its own: $(cat "$LOG_FILE")"
grep -q ' ALLOW key escape (batch line 3/3: key=escape)' "$LOG_FILE" \
  || fail "batch: line 3 has no gate-log entry of its own: $(cat "$LOG_FILE")"
pass "allowed: a valid batch runs every line in order, framed, each logged on its own"

# 2. One malformed line refuses the WHOLE batch, and nothing before it runs.
: >"$TMP_DIR/swift.log"
: >"$TMP_DIR/say.log"
for bad_batch in \
  $'ax dump all\nax click bogus=1\nkey escape' \
  $'ax dump all\necho pwned' \
  $'key escape\nstate; id' \
  $'ax dump all\nax type role=AXTextField hello' \
  $'ax dump all\nkey cmd+q' \
  $'ax dump all\nlaunch' \
  $'ax dump all\nterm open ghostty bash -c id' \
  $'ax dump all\ndictate hold soon'; do
  assert_denied 'batch' "batch refused whole for: $(tr '\n' '|' <<<"$bad_batch")" \
    "${APP_ENV[@]}" <<<"$bad_batch"
  [[ ! -s "$TMP_DIR/swift.log" ]] \
    || fail "batch: an earlier line ran before a later line failed validation: $(cat "$TMP_DIR/swift.log")"
  [[ "$GATE_STDERR" == *"nothing was run"* ]] \
    || fail "batch: the refusal did not say nothing was run: $GATE_STDERR"
done
[[ ! -s "$TMP_DIR/say.log" ]] || fail "batch: a refused batch spoke: $(cat "$TMP_DIR/say.log")"
grep -q ' DENY ax click bogus=1 (batch line 2/3 check: malformed selector)' "$LOG_FILE" \
  || fail "batch: the refusing line was not logged with its position and reason: $(cat "$LOG_FILE")"
pass "denied: a batch with any invalid line is refused before anything runs"

# 3. `batch` is never a valid line, wherever it sits.
for nested in $'batch' $'ax dump all\nbatch' $'batch\nax dump all'; do
  assert_denied 'batch' "batch containing batch: $(tr '\n' '|' <<<"$nested")" "${APP_ENV[@]}" <<<"$nested"
  [[ ! -s "$TMP_DIR/swift.log" ]] || fail "batch: a line ran from a batch that contained batch"
done
grep -q 'batch cannot contain batch' "$LOG_FILE" || fail "batch: nesting was not logged as the reason"
pass "denied: no batch line may be batch"

# 4. Execution stops at the first failing verb; the lines after it never run.
: >"$TMP_DIR/swift.log"
: >"$TMP_DIR/say.log"
run_gate 'batch' "${APP_ENV[@]}" STUB_MENU_FAIL=1 <<<$'ax dump all\nmenu open\nkey escape'
(( GATE_STATUS == 1 )) || fail "batch: expected the failing line's status 1, got $GATE_STATUS ($GATE_STDERR)"
grep -q "line 2/3 end status=1$" <<<"$GATE_STDOUT" || fail "batch: the failing line's end frame is missing: $GATE_STDOUT"
if grep -q "line 3/3 begin" <<<"$GATE_STDOUT"; then
  fail "batch: a line after the failure was started: $GATE_STDOUT"
fi
grep -q ' axdump 4242 all' "$TMP_DIR/swift.log" || fail "batch: line 1 did not run before the failure"
grep -q ' menuopen 4242' "$TMP_DIR/swift.log" || fail "batch: the failing line was never attempted"
if grep -q ' key 4242 escape' "$TMP_DIR/swift.log"; then
  fail "batch: the line after the failure ran"
fi
[[ "$GATE_STDERR" == *"batch stopped at line 2/3"*"1 line(s) not run"* ]] \
  || fail "batch: stderr did not say where it stopped: $GATE_STDERR"
grep -q "failed" "$TMP_DIR/say.log" || fail "batch: the failing GUI line did not say failed"
pass "a batch stops at the first failing verb"

# 5. A runtime denial stops it too: a locked screen lets the read-only line
# run and refuses the GUI line, in that order.
: >"$TMP_DIR/swift.log"
LOCK_STATE=locked
run_gate 'batch' "${APP_ENV[@]}" <<<$'gate-log 1\nax dump all\nkey escape'
LOCK_STATE=unlocked
(( GATE_STATUS == 126 )) || fail "batch: a locked screen did not deny the GUI line (status $GATE_STATUS)"
grep -q "line 1/3 end status=0$" <<<"$GATE_STDOUT" || fail "batch: gate-log did not run while locked: $GATE_STDOUT"
grep -q "line 2/3 end status=126$" <<<"$GATE_STDOUT" || fail "batch: the locked-screen denial is not framed: $GATE_STDOUT"
[[ ! -s "$TMP_DIR/swift.log" ]] || fail "batch: a GUI line ran on a locked screen"
pass "denied: a batch stops at a locked-screen refusal, after the read-only lines before it"

# 6. `ax type` keeps its `--` rule per line, its text reaches the helper, and
# the text is redacted in the frame and in the log.
: >"$TMP_DIR/swift.log"
: >"$LOG_FILE"
run_gate 'batch' "${APP_ENV[@]}" <<<$'ax type role=AXTextField,title=Endpoint -- sk-batch-secret-7!\nkey return'
(( GATE_STATUS == 0 )) || fail "batch: ax type inside a batch failed: $GATE_STDERR"
grep -q ' axtype 4242 role=AXTextField,title=Endpoint sk-batch-secret-7!' "$TMP_DIR/swift.log" \
  || fail "batch: ax type's text did not reach the helper as argv: $(cat "$TMP_DIR/swift.log")"
grep -q 'begin ax type role=AXTextField,title=Endpoint -- <redacted>$' <<<"$GATE_STDOUT" \
  || fail "batch: the frame did not redact ax type's text: $GATE_STDOUT"
if grep -q 'sk-batch-secret-7' <<<"$GATE_STDOUT"; then
  fail "batch: the typed text leaked into stdout framing"
fi
if grep -q 'sk-batch-secret-7' "$LOG_FILE"; then
  fail "batch: the typed text leaked into the gate log"
fi
grep -q ' ALLOW ax type role=AXTextField,title=Endpoint -- <redacted> (batch line 1/2' "$LOG_FILE" \
  || fail "batch: ax type's log entry is missing or unredacted: $(cat "$LOG_FILE")"
pass "ax type inside a batch keeps its -- rule, types the text, and redacts it everywhere"

# 7. Bounds: lines, bytes, and an empty stdin.
assert_denied 'batch' 'batch over the line cap' "${APP_ENV[@]}" LV_UI_BATCH_MAX_LINES=2 \
  <<<$'ax dump all\nax dump all\nax dump all'
assert_denied 'batch' 'batch over the byte cap' "${APP_ENV[@]}" LV_UI_BATCH_MAX_BYTES=20 \
  <<<$'ax dump all\nax dump all'
assert_denied 'batch' 'batch with nothing on stdin' "${APP_ENV[@]}" </dev/null
assert_denied 'batch' 'batch with only blank lines' "${APP_ENV[@]}" <<<$'\n  \n'
assert_denied 'batch now' 'batch takes no arguments' "${APP_ENV[@]}" <<<$'ax dump all'
run_gate 'batch' "${APP_ENV[@]}" <<<$'\nax dump all\n\nkey escape\n'
(( GATE_STATUS == 0 )) || fail "batch: blank spacer lines were not tolerated: $GATE_STDERR"
grep -q "lines=2$" <<<"$GATE_STDOUT" || fail "batch: blank lines were counted as verbs: $GATE_STDOUT"
pass "batch is bounded in lines and bytes, and blank lines are spacers, not verbs"

# 8. With the lease on, a batch of GUI verbs warns ONCE — and says "done"
# once, after the last line, not between them. The announcers are held inside
# their window the way section 29 holds them: `sleep` is instant here, so an
# unheld announcer would end the burst between two lines of the same batch.
clear_state
write_app_state 4242
: >"$TMP_DIR/say.log"
rm -f "$TMP_DIR/release-announcers"
LEASE_SECONDS=120
NOW_EPOCH=5000
SKIP_ANNOUNCER_WAIT=1
run_gate 'batch' "${APP_ENV[@]}" \
  STUB_SLEEP_HOLD_SECONDS=120 STUB_SLEEP_HOLD_FILE="$TMP_DIR/release-announcers" \
  <<<$'ax click role=AXButton,title=General\nkey escape\nkey tab'
(( GATE_STATUS == 0 )) || fail "batch: a leased GUI batch failed: $GATE_STDERR"
[[ "$(grep -c "taking control" "$TMP_DIR/say.log")" == "1" ]] \
  || fail "batch: three GUI lines under a lease warned $(grep -c "taking control" "$TMP_DIR/say.log") times"
if grep -q "done" "$TMP_DIR/say.log"; then
  fail "batch: done was spoken between the lines of one batch: $(cat "$TMP_DIR/say.log")"
fi
: >"$TMP_DIR/release-announcers"
unset SKIP_ANNOUNCER_WAIT
for (( i = 0; i < 500; i++ )); do
  grep -q "done" "$TMP_DIR/say.log" && break
  /bin/sleep 0.01
done
[[ "$(grep -c "done" "$TMP_DIR/say.log")" == "1" ]] \
  || fail "batch: expected one done after the batch, say.log: $(cat "$TMP_DIR/say.log")"
LEASE_SECONDS=0
unset NOW_EPOCH
pass "a batch of GUI verbs under the lease warns once, and says done once, after the last line"
clear_state

echo "== 32. ax find — the dump narrowed to a selector =="

# `ax dump` ships the whole tree (8 KB and up) on every step of a click-by-
# click session; `ax find` prints only what a selector matches. Same grammar,
# same validator, same keys as `ax click` — an unknown key is refused here
# exactly as it is there — and it is read-only, so no takeover warning.

clear_state
write_app_state 4242
assert_denied 'ax find' 'ax find without a selector' "${APP_ENV[@]}"
assert_denied 'ax find bogus=1' 'ax find with an unknown selector key' "${APP_ENV[@]}"
assert_denied 'ax find index=1' 'ax find naming no matchable attribute' "${APP_ENV[@]}"
assert_denied 'ax find title=' 'ax find with an empty value' "${APP_ENV[@]}"
assert_denied 'ax find role=AXButton extra' 'ax find with two arguments' "${APP_ENV[@]}"
assert_denied 'ax find role=AXButton;id' 'ax find with a metacharacter' "${APP_ENV[@]}"
assert_denied 'ax find role=AXButton,' 'ax find with a trailing comma' "${APP_ENV[@]}"

: >"$TMP_DIR/say.log"
: >"$TMP_DIR/swift.log"
assert_allowed 'ax find role=AXButton,title~Text+Processing' 'ax find by role and title' "${APP_ENV[@]}"
[[ "$GATE_STDOUT" == '[{"role":"AXButton"'* ]] || fail "ax find did not print the helper's JSON: $GATE_STDOUT"
grep -q 'axfind 4242 role=AXButton,title~Text+Processing' "$TMP_DIR/swift.log" \
  || fail "ax find did not hand the selector to the helper scoped to the app pid: $(cat "$TMP_DIR/swift.log")"
[[ ! -s "$TMP_DIR/say.log" ]] || fail "ax find spoke a takeover warning for a read-only verb: $(cat "$TMP_DIR/say.log")"
pass "ax find is read-only, pid-scoped, and silent"

LOCK_STATE=locked
assert_denied 'ax find role=AXButton' 'ax find on a locked screen' "${APP_ENV[@]}"
LOCK_STATE=unlocked
clear_state
assert_denied 'ax find role=AXButton' 'ax find with no app under test'

# The helper's subcommand resolves matches with the same walker `axclick`
# acts through, so what find shows is what click would press.
AXFIND_BODY="$(helper_case_body axfind)"
[[ -n "$AXFIND_BODY" ]] || fail "the helper has no axfind subcommand"
grep -q 'collectMatches(selector' <<<"$AXFIND_BODY" \
  || fail "axfind does not resolve its matches through collectMatches"
grep -q 'ElementSelector(argv\[2\])' <<<"$AXFIND_BODY" \
  || fail "axfind does not parse its selector with ElementSelector"
grep -q 'renderNode(' <<<"$AXFIND_BODY" \
  || fail "axfind does not render matches with the shared renderNode"
pass "the helper's axfind shares the selector, walker and renderer with click and dump"

echo "== 33. launch starts the app with the login keychain off =="

# The app reads the API key its selected engine needs during startup, on the
# main thread, and this app has no Team ID — so macOS partitions its keychain
# items by the build's code-signing hash and a freshly installed artifact's
# first read raises a MODAL prompt before the menu bar item exists. Nothing
# this gate has can answer that dialog (it belongs to SecurityAgent), so an
# unattended run stopped dead at it: securityd, 2026-09-20, `displaying
# keychain prompt for …/localvoxtral.app(19562)` 11 s after the `launch`.
#
# So `launch` opens the bundle with the same opt-out every CI lane that opens
# it already sets, and hands it whatever keys the machine-local secrets file
# carries. `--keychain` opts back in.

SECRETS_FILE="$FAKE_HOME/.localvoxtral-ui-gate.secrets"
clear_state
rm -f "$SECRETS_FILE"
: >"$TMP_DIR/open.log"
run_gate "launch $CLEAN_APP" "${APP_ENV[@]}" STUB_PGREP_PID=4242
(( GATE_STATUS == 0 )) || fail "keychain: launch failed: $GATE_STDERR"
grep -q -- "--env LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN=1" "$TMP_DIR/open.log" \
  || fail "keychain: launch did not disable the login keychain: $(cat "$TMP_DIR/open.log")"
[[ "$GATE_STDERR" == *"login keychain disabled for this launch; env keys: none"* ]] \
  || fail "keychain: launch did not say what the app started with: $GATE_STDERR"
grep -q "keychain=0" "$LOG_FILE" \
  || fail "keychain: the log line does not record the keychain decision: $(log_tail)"
pass "launch disables the login keychain, and says so"

# --keychain is the way back to the real thing, for the run whose subject IS
# the keychain path. The prompt is then the owner's to answer.
clear_state
: >"$TMP_DIR/open.log"
run_gate "launch --keychain $CLEAN_APP" "${APP_ENV[@]}" STUB_PGREP_PID=4242
(( GATE_STATUS == 0 )) || fail "keychain: launch --keychain failed: $GATE_STDERR"
if grep -q -- "--env" "$TMP_DIR/open.log"; then
  fail "keychain: launch --keychain still passed an environment: $(cat "$TMP_DIR/open.log")"
fi
grep -q -- "-n $CLEAN_APP" "$TMP_DIR/open.log" \
  || fail "keychain: launch --keychain did not open the bundle: $(cat "$TMP_DIR/open.log")"
grep -q "keychain=1" "$LOG_FILE" \
  || fail "keychain: --keychain is not in the log line: $(log_tail)"
pass "launch --keychain opts back in to the login keychain"

# The secrets file: only the three names the app reads, only from a 0600 file
# this account owns, and never a value in the log or on stderr.
clear_state
: >"$TMP_DIR/open.log"
{
  printf '# machine-local keys for the gate\n'
  printf '\n'
  printf 'MISTRAL_API_KEY=mk-test-0123456789\n'
  printf 'AWS_SECRET_ACCESS_KEY=nope\n'
  printf 'OPENAI_API_KEY=\n'
} >"$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"
run_gate "launch $CLEAN_APP" "${APP_ENV[@]}" STUB_PGREP_PID=4242
(( GATE_STATUS == 0 )) || fail "keychain: launch with a secrets file failed: $GATE_STDERR"
grep -q -- "--env MISTRAL_API_KEY=mk-test-0123456789" "$TMP_DIR/open.log" \
  || fail "keychain: the allowed key did not reach the app: $(cat "$TMP_DIR/open.log")"
if grep -q "AWS_SECRET_ACCESS_KEY" "$TMP_DIR/open.log"; then
  fail "keychain: a name outside the allowlist reached the app: $(cat "$TMP_DIR/open.log")"
fi
if grep -q -- "--env OPENAI_API_KEY=" "$TMP_DIR/open.log"; then
  fail "keychain: an empty value was passed as a key: $(cat "$TMP_DIR/open.log")"
fi
[[ "$GATE_STDERR" == *"env keys: MISTRAL_API_KEY"* ]] \
  || fail "keychain: launch did not name the keys it passed: $GATE_STDERR"
if grep -q "mk-test-0123456789" "$LOG_FILE"; then
  fail "keychain: a key value was written to the gate log"
fi
if [[ "$GATE_STDERR" == *"mk-test-0123456789"* ]]; then
  fail "keychain: a key value was printed on stderr"
fi
pass "the secrets file passes only allowlisted names, and never leaks a value"

# A file anyone else can read is not a file that may hold API keys, and the
# refusal says how to fix it rather than leaving an empty key field to explain.
clear_state
: >"$TMP_DIR/open.log"
chmod 644 "$SECRETS_FILE"
run_gate "launch $CLEAN_APP" "${APP_ENV[@]}" STUB_PGREP_PID=4242
(( GATE_STATUS == 0 )) || fail "keychain: launch with a loose secrets file failed: $GATE_STDERR"
if grep -q "MISTRAL_API_KEY" "$TMP_DIR/open.log"; then
  fail "keychain: keys were read out of a group-readable file: $(cat "$TMP_DIR/open.log")"
fi
[[ "$GATE_STDERR" == *"must be mode 0600"* && "$GATE_STDERR" == *"chmod 600"* ]] \
  || fail "keychain: the loose-permissions refusal does not say what to do: $GATE_STDERR"
pass "a secrets file the rest of the machine can read is ignored, loudly"

# --keychain means the login keychain, not the login keychain AND a file.
clear_state
: >"$TMP_DIR/open.log"
chmod 600 "$SECRETS_FILE"
run_gate "launch --keychain $CLEAN_APP" "${APP_ENV[@]}" STUB_PGREP_PID=4242
(( GATE_STATUS == 0 )) || fail "keychain: launch --keychain with a secrets file failed: $GATE_STDERR"
if grep -q "MISTRAL_API_KEY" "$TMP_DIR/open.log"; then
  fail "keychain: --keychain still handed the app a key from the file: $(cat "$TMP_DIR/open.log")"
fi
pass "--keychain takes the keys from the keychain and nowhere else"

rm -f "$SECRETS_FILE"
clear_state

echo "== 28. nothing here needs a bash newer than the Mac's /bin/bash 3.2 =="

# The gate runs under the Mac's /bin/bash, which is 3.2 (Apple has shipped that
# since the GPLv3 licence change). A bash-4 idiom is therefore a construct that
# works perfectly on a Linux dev box and misbehaves on the machine this gate
# exists for — the worst shape of failure available here, because the dev-box
# suite goes green and only the runner, or the OWNER, finds out.
#
# This branch has now hit it twice: once in a stub (daf6364) and once with
# BASHPID in the `open` stub, where an empty pid file made the gate report "the
# launcher never ran" and the test failed only on the runner (CI 33313541728).
# So it is a check rather than a habit.
#
# Two things are stripped before scanning, and both are the same lesson: a scan
# that cannot tell its own vocabulary from a call reports itself. Comments go
# (the explanations above name every idiom they warn about), and so does the
# definition block below, between its own sentinels — that is the grep
# self-poisoning trap, and the scanner is the most likely thing to trip it.

BASH4_FILES=(
  "$GATE"
  "$ATTACH"
  "$INSTALLER"
  "$ROOT_DIR/scripts/mac/ui-gate-doctor.sh"
  "$0"
)

# BASH4-SCANNER-BEGIN — not scanned; see above.
#
# name::extended-regex, `::` because one of the names contains a pipe. Each is
# bash 4.0+ and misbehaves QUIETLY on 3.2 rather than failing loudly: BASHPID
# expands to nothing, mapfile/readarray are "command not found" inside a
# pipeline whose status is ignored, an associative array declaration is a
# syntax error only when reached, and case conversion expands unmodified.
BASH4_IDIOMS=(
  'BASHPID::\$[{]?BASHPID'
  'mapfile::(^|[^[:alnum:]_])mapfile[[:space:]]'
  'readarray::(^|[^[:alnum:]_])readarray[[:space:]]'
  'an associative array::(declare|local|typeset)[[:space:]]+-[A-Za-z]*A[A-Za-z]*[[:space:]]'
  'case-conversion expansion::\$[{][A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^\^|,,)'
  'the |& pipe::[^|]\|&'
)
# BASH4-SCANNER-END

for bash4_file in "${BASH4_FILES[@]}"; do
  [[ -f "$bash4_file" ]] || fail "the bash-3.2 scan points at a file that is not there: $bash4_file"
  # The Swift heredoc goes too: the helper is Swift, where `,,` and `|&` mean
  # nothing to bash and `${…}` is not an expansion at all.
  BASH4_CODE="$(awk '/BASH4-SCANNER-BEGIN/ { skip = 1 }
                     /BASH4-SCANNER-END/   { skip = 0; next }
                     /^  cat <<.SWIFT.$/ { skip = 1 }
                     skip && /^SWIFT$/ { skip = 0; next }
                     skip { next }
                     { print }' "$bash4_file" | grep -v '^[[:space:]]*#' || true)"
  for bash4_idiom in "${BASH4_IDIOMS[@]}"; do
    idiom_name="${bash4_idiom%%::*}"
    idiom_re="${bash4_idiom#*::}"
    if grep -qE "$idiom_re" <<<"$BASH4_CODE"; then
      fail "$bash4_file uses $idiom_name, which is bash 4+ and misbehaves quietly on the Mac's /bin/bash 3.2: $(grep -nE "$idiom_re" <<<"$BASH4_CODE" | head -n 1)"
    fi
  done
done
pass "the gate, the wrapper, the installer, the doctor and this suite are bash 3.2 clean"

# An empty array expanded under `set -u` is the OTHER 3.2 trap, and the one the
# dispatch already carries a comment about: bash 3.2 calls "${a[@]:1}" unbound
# when the slice is empty. Every such expansion in the gate has to sit behind a
# length guard, so this pins that none of them is bare.
GATE_SLICES="$(grep -n '\${[A-Za-z_][A-Za-z0-9_]*\[[@*]\]:[0-9]' "$GATE" \
  | grep -v '^[0-9]*:[[:space:]]*#' || true)"
[[ -n "$GATE_SLICES" ]] || fail "no array slices found in the gate — did the scan's pattern rot?"
while IFS= read -r slice_line; do
  [[ -n "$slice_line" ]] || continue
  slice_no="${slice_line%%:*}"
  # The guard is on the same line (`if (( ${#a[@]} > 1 )); then …`) or within
  # the two lines above it.
  if ! sed -n "$(( slice_no > 2 ? slice_no - 2 : 1 )),${slice_no}p" "$GATE" | grep -q '\${#'; then
    fail "an unguarded array slice at $GATE:$slice_no — bash 3.2 calls an empty slice unbound under set -u: $slice_line"
  fi
done <<<"$GATE_SLICES"
pass "every array slice in the gate sits behind a length guard"

if (( FAILURES > 0 )); then
  printf '\n%s assertion(s) FAILED (LV_UI_GATE_TEST_KEEP_GOING=1 kept the run going)\n' "$FAILURES" >&2
  exit 1
fi

echo
echo "ui gate tests passed"
