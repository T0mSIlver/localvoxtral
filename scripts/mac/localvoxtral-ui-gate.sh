#!/usr/bin/env bash
set -euo pipefail

# localvoxtral UI gate v1.
#
# A SECOND forced-command SSH gate, installed on the Mac's GUI account, next
# to (never merged with) the build gate. It lets an agent see and drive the
# localvoxtral build UNDER TEST — and nothing else on the owner's desktop.
#
# THE FORCED COMMAND IS THE ENTIRE TRUST BOUNDARY.
# Everything reachable through this key is in the `case` at the bottom of this
# file; everything else is denied and logged. There is deliberately NO shell
# verb: no `eval`, no `bash -c`, no verb that takes a free command line — with
# one narrowly constrained exception, `term open`, whose command must start
# with an allowlisted binary, is resolved to an absolute path under
# LV_UI_TERM_COMMAND_DIRS before anything is opened, must survive the same
# metacharacter blocklist as every other token, and is logged IN FULL. Adding a verb that can run
# arbitrary commands dissolves this boundary completely; do not.
#
# The invariant that keeps `term open` from BEING that verb, stated positively:
# AN ALLOWLISTED COMMAND MUST NOT BE ABLE TO RUN A CHILD COMMAND.
# Not "must not be a shell" — must not be able to start one, at any remove,
# through any flag or subcommand. Only the first token is checked and nothing
# inspects flags, so `claude --dangerously-skip-permissions -p <prompt>`,
# `codex exec`, `opencode run` and `herdr agent start` are each a full shell
# wearing one allowlisted name. The default allowlist is therefore EMPTY, a
# permanent denylist sits under it that the conf file cannot override, and the
# test to apply before adding a name is spelled out at LV_UI_TERM_COMMANDS.
#
# Why "semantic" verbs and not a computer-use harness: a generic harness
# clicks inferred pixel coordinates on whatever is on screen, which on this
# machine is the owner's mail, browser and messages. This gate cannot do that.
# There is no coordinate input at all, and no full-screen capture:
#
#   - `shot` resolves a CGWindowID from the window list FILTERED to the pid
#     this gate itself launched, and refuses when the resolved window's owner
#     is not that pid. It can never photograph another application. Its stdout
#     is PURE base64 and nothing else; the `shot: window <id> (<kind>), <n>
#     bytes` line goes to stderr, so `shot popover | base64 -d > x.png` is
#     correct as written and needs no `tail`. Over an interactive ssh both
#     streams land in the same terminal, which is the only reason it can look
#     like a header.
#   - `ax click` / `ax type` walk the accessibility tree rooted at
#     AXUIElementCreateApplication(<that same pid>). A selector cannot name an
#     element of another app.
#   - `key` posts one keycode from a three-entry allowlist, and only once the
#     app under test is frontmost — it activates that app first and refuses if
#     the activation did not take, so a keystroke never lands in whatever the
#     owner last touched.
#   - `menu open` / `menu click` / `menu dismiss` reach the status item of
#     that same pid, through AXUIElementCreateApplication(<it>). They exist
#     because localvoxtral opens no window at launch — without them every verb
#     above has nothing to address. No other app's menu bar is expressible.
#     `menu open` and `menu dismiss` decide "is a menu on screen" from the
#     WINDOW LIST, using the same layer >= 100 rule `shot popover` resolves,
#     so the two verbs agree by construction. The AXMenu attached to a status
#     item is NOT that evidence — it is there whether or not anything is
#     displayed, and taking it for evidence is what made `menu open` report
#     "ok already-open" without ever pressing anything (field check
#     2026-08-29).
#   - `dictate` posts the app's OWN configured trigger — read from the app's
#     defaults, never hard-coded — as a modifier-only gesture at the HID tap.
#     It is the one verb that does not target a window, because the trigger is
#     global by design and the dictation grounds itself in whatever is FOCUSED;
#     activating localvoxtral first would defeat the thing under test. It
#     refuses unless the app is running, its modifier trigger is enabled in its
#     own settings, and Secure Keyboard Entry is not held.
#   - `term focus` / `term close` act only on a window this gate opened,
#     identified by the CGWindowID that appeared while it was opening one. NOT
#     by a title marker: the command this verb exists to run is a whole-view
#     herdr client, and herdr owns the title from the moment it starts, so a
#     marker never survives to be seen (field failure 2026-08-30; the same
#     property is why the app's titleMarker join arm is suppressed there).
#   - `app` forwards ONE line to the control socket of the app under test —
#     never a shell, never a path of the caller's choosing. The socket only
#     exists in a dogfood build, so the verb refuses unless `launch --dogfood`
#     recorded one, and the forwarded line must be one of the five shapes the
#     socket's own grammar accepts. The socket answers in a closed vocabulary
#     of bools, counts and enum names (docs/dogfood-builds.md).
#   - `log` reads the unified log for localvoxtral's OWN subsystem only, over a
#     clamped window, with a line cap and token-shaped runs masked. It is not a
#     general system-log reader; every other application's activity on this
#     machine stays out of reach. It is scoped to one PROCESS as well as the
#     subsystem — the pid `launch` recorded, or the app's process name when
#     there is no app under test, which it then says. This Mac is also the
#     self-hosted CI runner and `xctest` logs under the same subsystem, so
#     subsystem alone hands back another run's lines (field check 2026-08-30).
#   - `gate-log` reads THIS gate's own log file and nothing else — the file
#     this script writes, one sanitised printable line per invocation. It is
#     how a denial's reason becomes readable without `deny` explaining itself
#     to the caller, which it deliberately does not.
#
# `state` additionally reports SETUP readiness — which config files exist,
# whether they parse, what `term open` would currently accept, whether the
# wrapper is installed, whether the app exposes a control socket — because in
# a real session (2026-08-30) every one of those was indistinguishable from a
# broken verb. It reports presence, parse verdicts and the gate's own
# vocabulary; never a file's contents (see setup_json).
#
# A `term open` window is therefore NOT a lateral path into the app-driving
# verbs, and the scoping above is why: `shot`, `ax dump`, `ax click`, `ax type`
# and `key` all take their pid from the app.state that `launch` wrote, and
# `launch` only ever records a validated localvoxtral bundle's pid. There is no
# verb that retargets them at a terminal — `term focus`/`term close` reach a
# terminal window, but only to raise or close it, and they carry no selector,
# no keystroke and no capture. Nothing typed by this gate can reach a shell
# prompt. (test-ui-gate.sh section 12 pins this: with both an app under test
# and an open terminal recorded, every helper call still carries the app pid.)
#
# It refuses everything GUI-touching while the screen is locked (shared probe:
# scripts/ci/screen-lock-state.sh, fail CLOSED here), and honours the owner's
# takeover rule: any verb that steals focus or takes input (launch, ax click,
# ax type, key, menu open, menu click, dictate tap/hold, term open, term focus)
# speaks a warning, waits, and announces completion. `state`, `shot`,
# `ax dump`, `menu dismiss`, `dictate cancel`, `log`, `gate-log`, `quit` and
# `term close` do not warn: none of them takes the keyboard or raises a window in front of what the
# owner is doing.
#
# Verbs (each documented at its run_* function):
#   state
#   launch [--dogfood] <artifact>
#   shot [settings|popover|overlay|window <n>]
#   ax dump [settings|overlay|window <n>]
#   ax click <selector>
#   ax type <selector> -- <text>
#   key <escape|tab|return>
#   menu <open|click <item-title>|dismiss>
#   dictate <tap|hold <seconds>|cancel>
#   app <control command>
#   log [minutes]
#   gate-log [lines]
#   quit
#   term open <ghostty|iterm|terminal> <command> [args...]
#   term focus <id>
#   term close <id>
#
# Install notes, TCC grants and the deny check: scripts/mac/README.md.
# Regression tests: scripts/ci/test-ui-gate.sh (runs in ci.yml; no GUI needed).

# Deterministic pattern matching and character classes regardless of the
# client's locale: [[:print:]] below must mean ASCII 0x20-0x7E, not whatever
# a forwarded LANG would widen it to.
export LC_ALL=C

LOG_FILE="${LV_UI_GATE_LOG:-$HOME/Library/Logs/localvoxtral-ui-gate.log}"
STATE_DIR="${LV_UI_STATE_DIR:-$HOME/.localvoxtral-ui-gate}"

# Where a launchable artifact may live. `launch` resolves the argument with
# `pwd -P` (so symlinks and .. cannot escape) and requires the result to sit
# under one of these roots AND to be a real localvoxtral bundle.
LV_UI_ARTIFACT_ROOTS="${LV_UI_ARTIFACT_ROOTS:-$HOME/Applications $HOME/localvoxtral-ui-artifacts}"

# `term open`'s allowlists.
#
# THE INVARIANT, stated positively: an allowlisted command must not be able to
# run a child command. Not "must not be a shell" — must not be able to start
# one, at any remove, through any flag or subcommand.
#
# The test to apply before adding a name: read its `--help`. If ANY flag or
# subcommand takes a command, a script, a prompt, or a file to execute — `-c`,
# `-e`, `exec`, `run`, `--eval`, `-p`, an agent that runs tools — it fails, and
# it does not go on this list. `list_contains` matches the FIRST TOKEN ONLY and
# nothing here inspects flags, so a name that passes the test is trusted with
# every argument it will ever be given.
#
# This rejects the obvious shells (bash, sh, zsh, ssh, osascript, python) AND
# every coding-agent CLI: `claude --dangerously-skip-permissions -p <prompt>`,
# `codex exec`, `opencode run` and `herdr agent start` each execute arbitrary
# code as this user, which is the whole boundary handed away by a default. An
# earlier revision of this file shipped `herdr claude opencode codex` as the
# default and was exactly that hole.
#
# So the default is EMPTY: `term open` denies until the owner opts in in
# ~/.localvoxtral-ui-gate.conf. The documented way to make it useful is a
# single-purpose wrapper the owner writes and installs — one that takes an
# identifier and execs one fixed command, never a command of the caller's
# choosing (scripts/mac/README.md).
LV_UI_TERMINALS="${LV_UI_TERMINALS:-ghostty iterm terminal}"
LV_UI_TERM_COMMANDS="${LV_UI_TERM_COMMANDS:-}"
LV_UI_MAX_TERM_ARGS="${LV_UI_MAX_TERM_ARGS:-12}"

# Where an allowlisted NAME is resolved to a file, and the reason resolution
# happens here at all (field failure 2026-08-30).
#
# `term open` used to write `exec lv-attach` into the launcher and let PATH
# find it. A script started by `open -n -a Ghostty --args -e <script>` does not
# get a login shell's environment, `$HOME/bin` is not on the PATH sshd hands
# this gate either, and the wrapper lives in `$HOME/bin`. So the launcher hit
# `command not found`, exited instantly, and left an EMPTY terminal window on
# the owner's desktop — which the gate then reported as a window-identification
# timeout. Two different faults telling one wrong story cost the operator
# twenty minutes and produced a confidently wrong root cause on top.
#
# So the name is resolved to an absolute path BEFORE anything is opened, the
# file has to exist and be executable, and a name that does not resolve is
# refused with nothing opened. `state` reports the same thing under
# setup.term_open.unresolvable, so it is visible before a verb is tried.
#
# The directory list is short on purpose: a name resolved out of a directory
# other accounts can write is the allowlist handed away. $HOME/bin is where
# install-ui-artifact.sh puts the wrapper and where the lock probe already
# lives.
LV_UI_TERM_COMMAND_DIRS="${LV_UI_TERM_COMMAND_DIRS:-$HOME/bin}"

# How long `term open` waits for its window. A seam, not a knob: the shell
# suite drives the three failure paths below and a 20-second wall-clock wait
# per case is most of the suite's runtime.
LV_UI_TERM_OPEN_TIMEOUT_SECONDS="${LV_UI_TERM_OPEN_TIMEOUT_SECONDS:-20}"
# How many windows a refused `term open` may record as UNCONFIRMED so
# `term close` can still reach them. Bounded because each record is a window
# this gate could not prove is its own.
LV_UI_TERM_MAX_UNCONFIRMED="${LV_UI_TERM_MAX_UNCONFIRMED:-6}"

# Owner rule (2026-07-09): warn audibly and wait before stealing focus, and
# announce completion. Set to 0 in the conf file only if you are sitting in
# front of the machine — the default is the rule as stated.
LV_UI_WARN_SLEEP_SECONDS="${LV_UI_WARN_SLEEP_SECONDS:-3}"

# A window PNG is a few hundred KB; the cap exists so a pathological capture
# cannot dump tens of MB into an agent transcript.
LV_UI_SHOT_MAX_BYTES="${LV_UI_SHOT_MAX_BYTES:-8388608}"

# `dictate hold` holds a real modifier down for this long at most. The SSH
# command blocks for the duration, and a modifier left latched is the owner's
# problem for the rest of the session, so it is bounded.
LV_UI_MAX_HOLD_SECONDS="${LV_UI_MAX_HOLD_SECONDS:-30}"

LV_UI_MAX_COMMAND_BYTES="${LV_UI_MAX_COMMAND_BYTES:-2048}"
LV_UI_MAX_TEXT_BYTES="${LV_UI_MAX_TEXT_BYTES:-512}"

# `app`'s target: the dogfood control socket of the app under test. Not
# discovered, not passed in — the one path a dogfood build ever binds
# (DogfoodControlSocket.defaultSocketPath). Overridable only so the test suite
# can point it at a fixture.
LV_UI_CONTROL_SOCKET="${LV_UI_CONTROL_SOCKET:-$HOME/Library/Application Support/localvoxtral/dogfood/control/control.sock}"

# `log`'s bounds. The window is clamped the way the build gate's `applog`
# clamps its own, and the line cap exists so a chatty minute cannot dump tens
# of thousands of lines into an agent transcript.
LV_UI_LOG_DEFAULT_MINUTES="${LV_UI_LOG_DEFAULT_MINUTES:-15}"
LV_UI_LOG_MAX_MINUTES="${LV_UI_LOG_MAX_MINUTES:-120}"
LV_UI_LOG_MAX_LINES="${LV_UI_LOG_MAX_LINES:-400}"
# The app's OWN subsystem and nothing else. This is the difference between a
# diagnostic and a machine-wide log reader on the owner's personal Mac.
LV_UI_LOG_SUBSYSTEM="${LV_UI_LOG_SUBSYSTEM:-com.localvoxtral}"
# The subsystem alone is NOT enough on this machine: the self-hosted CI runner
# shares it, and `xctest` running the unit suite logs under the very same
# subsystem (field check 2026-08-30: `log 2` returned 111 lines, all but one
# of them `xctest[19586]`). So the predicate also carries a process. The pid
# `launch` recorded is the preferred one — it scopes to the instance under
# test the way every other verb does; this name is the fallback used when
# there is no app under test, and the output says so when it is.
LV_UI_LOG_PROCESS="${LV_UI_LOG_PROCESS:-localvoxtral}"

# `gate-log`'s bounds. This file is written BY this gate, one sanitised
# printable line per invocation, so the cap is about transcript size and not
# about what may be seen.
LV_UI_GATE_LOG_DEFAULT_LINES="${LV_UI_GATE_LOG_DEFAULT_LINES:-20}"
LV_UI_GATE_LOG_MAX_LINES="${LV_UI_GATE_LOG_MAX_LINES:-200}"

# The `term open` wrapper `state` interrogates, and the config file the wrapper
# reads. `state` runs the wrapper's `--check` rather than re-implementing its
# destination validator: the validator is the load-bearing part of the wrapper
# and there must be exactly one of it, and asking the INSTALLED copy is what
# makes "the wrapper is missing" and "the wrapper is older than this gate"
# different answers instead of the same silence.
LV_UI_ATTACH_WRAPPER="${LV_UI_ATTACH_WRAPPER:-$HOME/bin/lv-attach}"
LV_UI_ATTACH_CONF="${LV_UI_ATTACH_CONF:-$HOME/.lv-attach.conf}"

# Machine-local overrides (never committed). Same argument as the build gate:
# anyone who can write this file can already replace this script, so sourcing
# it adds no new trust.
#
# Parsed before it is sourced, and IGNORED if it does not parse. A syntax error
# here used to kill every verb: `source` returns non-zero, `set -e` takes the
# whole gate down, and the client sees an empty answer with no exit line worth
# reading — the exact shape of failure this gate's setup reporting exists to
# end. So a broken conf now degrades to the built-in defaults (which are the
# CLOSED ones: an empty `term open` allowlist), says so on stderr on every
# invocation, and is reported by `state`.
GATE_CONF="${LV_UI_GATE_CONF:-$HOME/.localvoxtral-ui-gate.conf}"
GATE_CONF_STATUS=absent
if [[ -f "$GATE_CONF" ]]; then
  if bash -n "$GATE_CONF" 2>/dev/null; then
    GATE_CONF_STATUS=ok
    # shellcheck source=/dev/null
    source "$GATE_CONF"
  else
    GATE_CONF_STATUS=unparsable
    printf 'localvoxtral ui gate: %s has a syntax error and was IGNORED — every setting in it is at its built-in default, which means `term open` has an EMPTY allowlist. Check it with: bash -n %s\n' \
      "$GATE_CONF" "$GATE_CONF" >&2
  fi
fi

# Second layer under the (empty by default) allowlist above: names that can run
# a child command are refused even when the conf allowlists them. Deliberately
# assigned AFTER the conf is sourced and NOT via ${VAR:-...}, so the conf can
# widen the allowlist but can never re-add one of these. A blocklist is a poor
# primary defence, which is why it is not the primary defence — it is here so
# that a mistake in a machine-local file fails loudly instead of silently.
#
# Four classes, because "can run a child command" is wider than "is a shell":
#   * shells and interpreters — the obvious ones;
#   * coding-agent CLIs — each one IS a shell wearing a product name;
#   * editors and pagers — `vi`, `less`, `man` all reach a shell at RUNTIME
#     (`:!cmd`, `!cmd`, `v`). The admission test in the header ("read --help;
#     if any flag takes a command it fails") does NOT catch these, and they are
#     the names an owner is likeliest to allowlist meaning "just a viewer";
#   * command wrappers and toolchains — `nice`, `watch`, `timeout`, `env`,
#     `git` (hooks, GIT_SSH, its editor), `open` (`open -a Terminal`), `awk`
#     (`system()`), `npx`/`cargo`/`go`, and the fetchers whose normal argv is
#     someone else's code.
# Adding a name here costs nothing; leaving one out costs the boundary.
LV_UI_TERM_FORBIDDEN="bash sh zsh ksh csh tcsh fish dash ssh scp sftp telnet \
osascript applescript python python2 python3 perl ruby node deno bun php lua \
env xargs find sudo doas su nohup script screen tmux herdr expect make just \
claude codex opencode aider goose amp cursor-agent gemini ollama \
vi vim nvim view ex ed emacs nano pico less more most man info \
awk sed git swift open watch nice caffeinate arch time timeout stdbuf \
npm npx yarn pnpm cargo go rustc gcc clang cc ld dtrace lldb gdb \
nc netcat curl wget rsync ftp"

original_command="${SSH_ORIGINAL_COMMAND:-}"
ARGV=()
ANNOUNCED_TAKEOVER=0
ACTION_COMPLETED=0

timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

log_line() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '%s %s\n' "$(timestamp)" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# Every invocation is logged, allowed or denied. `ax type`'s text is NOT
# logged: the legitimate use for it is filling in an endpoint's API key field,
# and this log is read by agents and pasted into PRs.
log_command() {
  local verdict="$1" note="${2:-}" shown="${original_command:-<empty>}"
  case "$shown" in
    "ax type "*) shown="${shown%% -- *} -- <redacted>" ;;
  esac
  # Log-injection defence: a denied command is attacker-chosen text, and a
  # newline in it would otherwise write a second line into this log that reads
  # exactly like a genuine ALLOW entry. Every non-printable byte becomes `?`,
  # so one invocation is always exactly one line.
  shown="$(printf '%s' "${shown:0:512}" | tr -c '[:print:]' '?')"
  # The note gets the same treatment, and for the same reason. Today every note
  # is built from already-charset-checked input, so there is no live injection
  # — but "one invocation is always exactly one line" was enforced on only half
  # the line, and the next caller to interpolate something new here would not
  # know that. Bounded too: a denial's note can otherwise carry the whole
  # 2048-byte command back into the file.
  note="$(printf '%s' "${note:0:512}" | tr -c '[:print:]' '?')"
  if [[ -n "$note" ]]; then
    log_line "$verdict $shown (${note})"
  else
    log_line "$verdict $shown"
  fi
}

deny() {
  log_command DENY "${1:-unallowlisted}"
  printf 'localvoxtral ui gate: denied command\n' >&2
  exit 126
}

fail() {
  printf 'localvoxtral ui gate: %s\n' "$1" >&2
  exit "${2:-1}"
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

# Fail-closed token charset. No whitespace, no quote, no backslash, and none
# of `$ ; & | < > ( ) { } [ ] ! * ? # ' "` — so a token can never be anything
# but a literal even if some future code path did the wrong thing with it.
# Selector values spell a space as `+` (see validate_selector).
token_is_safe() {
  [[ "$1" =~ ^[A-Za-z0-9._:/=,~+@%-]+$ ]]
}

# Selector grammar: comma-separated key<op>value pairs, `=` exact, `~`
# contains, `+` decodes to a space.
#   role=AXButton,title=Dictation
#   role=AXButton,title~Text+Processing,index=0
# Keys: role, title, desc, value, index, window.
validate_selector() {
  local selector="$1" pair key matchable=0
  token_is_safe "$selector" || return 1
  (( ${#selector} <= 256 )) || return 1
  [[ "$selector" == *[=~]* ]] || return 1
  local IFS=,
  for pair in $selector; do
    [[ -n "$pair" ]] || return 1
    key="${pair%%[=~]*}"
    [[ "$key" != "$pair" ]] || return 1
    [[ -n "${pair#*[=~]}" ]] || return 1
    case "$key" in
      role | title | desc | value) matchable=1 ;;
      index | window) [[ "${pair#*[=~]}" =~ ^[0-9]+$ ]] || return 1 ;;
      *) return 1 ;;
    esac
  done
  # `index=0` alone names no element; it only disambiguates among matches.
  (( matchable == 1 ))
}

# A menu item title arrives as ONE token in the charset above, `+` for a space
# (`menu click Show+Log`). Real titles routinely carry characters that charset
# cannot express — localvoxtral's is "Settings…" — which is why the helper
# matches by containment with an exact title winning: `menu click Settings` is
# how you reach it, and an ambiguous substring is refused, not guessed at.
validate_menu_title() {
  local title="$1"
  token_is_safe "$title" || return 1
  (( ${#title} >= 1 && ${#title} <= 128 ))
}

# Typed text is the one place a wider charset is allowed: it never reaches a
# shell (the Swift helper receives it as argv) and API keys/URLs need it.
validate_typed_text() {
  local text="$1"
  (( ${#text} >= 1 && ${#text} <= LV_UI_MAX_TEXT_BYTES )) || return 1
  [[ "$text" =~ ^[[:print:]]+$ ]]
}

list_contains() {
  local needle="$1" item
  shift
  for item in $*; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Screen lock — fail CLOSED
# ---------------------------------------------------------------------------

# The shared probe (scripts/ci/screen-lock-state.sh) is installed alongside
# this gate. If it is missing or cannot decide, every GUI-touching verb is
# refused: this drives the owner's personal desktop, so "state unknown" must
# never mean "go ahead". (ui-smoke-guard.sh applies the opposite policy to the
# same probe on purpose — see the probe's header.)
LOCK_PROBE="${LV_UI_LOCK_PROBE:-$HOME/bin/localvoxtral-screen-lock-state.sh}"

screen_lock_state() {
  if [[ ! -x "$LOCK_PROBE" ]]; then
    echo "error"
    return
  fi
  "$LOCK_PROBE" 2>/dev/null || echo "error"
}

require_unlocked_screen() {
  local state
  state="$(screen_lock_state)"
  case "$state" in
    unlocked) return 0 ;;
    locked | no-session)
      deny "screen is $state"
      ;;
    *)
      if [[ ! -x "$LOCK_PROBE" ]]; then
        deny "lock probe missing at $LOCK_PROBE — install it (scripts/mac/README.md)"
      fi
      deny "lock state undeterminable ($state)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Owner rule: audible takeover warning
# ---------------------------------------------------------------------------

announce_takeover() {
  local what="$1"
  say "localvoxtral u i gate taking control in 3: $what" >/dev/null 2>&1 || true
  ANNOUNCED_TAKEOVER=1
  sleep "$LV_UI_WARN_SLEEP_SECONDS" 2>/dev/null || true
}

announce_result() {
  (( ANNOUNCED_TAKEOVER == 1 )) || return 0
  if (( ACTION_COMPLETED == 1 )); then
    say "localvoxtral u i gate done" >/dev/null 2>&1 || true
  else
    say "localvoxtral u i gate failed" >/dev/null 2>&1 || true
  fi
}

# One EXIT path for the whole gate: no capture file ever outlives the
# invocation that took it, whatever exit the verb takes.
SHOT_FILE=""
on_exit() {
  [[ -n "$SHOT_FILE" ]] && rm -f "$SHOT_FILE"
  announce_result
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Swift helper — every CoreGraphics/AX call lives here
# ---------------------------------------------------------------------------
# The helper receives selectors, text and window kinds as ARGV, never as
# interpolated source: the heredoc below is a constant. It is written into the
# 0700 state dir on each invocation and run with `swift <file> <subcommand>`.

HELPER_PATH=""

write_helper() {
  [[ -n "$HELPER_PATH" ]] && return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  chmod 0700 "$STATE_DIR" 2>/dev/null || true
  HELPER_PATH="$STATE_DIR/ui-gate-helper.swift"
  cat >"$HELPER_PATH" <<'SWIFT'
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

// Subcommands (argv[1..]):
//   preflight
//   window <pid> <settings|popover|overlay|window> [index]   -> "<winid> <ownerpid>"
//   axdump <pid> [all|settings|overlay|window] [index]       -> JSON
//   axclick <pid> <selector>
//   axtype <pid> <selector> <text>
//   key <pid> <escape|tab|return>
//   menuopen <pid>
//   menuclick <pid> <item-title>
//   menudismiss <pid>
//   dictate <pid> <fn|right_command|right_option> <tap|hold|cancel> [seconds]
//   termsnapshot [<pid>...]                                  -> "<id>,<id>,..."
//   termnew <ownerpid> <marker|-> <excluded-ids|->           -> "ok <winid> <ownerpid>"
//   termaction <ownerpid> <winid> <focus|close>

let argv = Array(CommandLine.arguments.dropFirst())

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("helper: " + message + "\n").utf8))
    exit(1)
}

func copyAttr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func str(_ element: AXUIElement, _ name: String) -> String {
    if let raw = copyAttr(element, name) {
        if let s = raw as? String { return s }
        return String(describing: raw)
    }
    return ""
}

func windowsOf(_ pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    return (copyAttr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

// The AX window whose frame matches a CGWindow's, or nil when zero or several
// do. Used to act on a window identified by CGWindowID (see termaction).
func axWindow(pid: pid_t, matching frame: CGRect) -> AXUIElement? {
    var matches: [AXUIElement] = []
    for window in windowsOf(pid) {
        guard let rawPosition = copyAttr(window, kAXPositionAttribute),
              let rawSize = copyAttr(window, kAXSizeAttribute),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { continue }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
        else { continue }
        // A couple of points of slack: the window list and AX round
        // independently, and a title bar can differ by a hair.
        if abs(origin.x - frame.origin.x) <= 2, abs(origin.y - frame.origin.y) <= 2,
           abs(size.width - frame.width) <= 2, abs(size.height - frame.height) <= 2 {
            matches.append(window)
        }
    }
    return matches.count == 1 ? matches[0] : nil
}

func jsonEscape(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
            else { out.unicodeScalars.append(scalar) }
        }
    }
    return out
}

// MARK: - CGWindow list, always filtered to one owner pid

struct CGWindowRecord {
    let id: Int
    let ownerPID: Int
    let layer: Int
    let area: Double
    let title: String
    // Kept so a CGWindowID can be mapped to an AX window later: AX exposes no
    // window id without private API, but AXPosition/AXSize are in the same
    // top-left screen coordinates kCGWindowBounds uses.
    let frame: CGRect
}

func cgWindows(ownedBy pid: Int) -> [CGWindowRecord] {
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [CGWindowRecord] = []
    for window in raw {
        guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner == pid,
              let id = window[kCGWindowNumber as String] as? Int,
              let layer = window[kCGWindowLayer as String] as? Int,
              let bounds = window[kCGWindowBounds as String] as? [String: Double],
              let width = bounds["Width"], let height = bounds["Height"]
        else { continue }
        let title = window[kCGWindowName as String] as? String ?? ""
        let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
        out.append(CGWindowRecord(id: id, ownerPID: owner, layer: layer, area: width * height,
                                  title: title, frame: frame))
    }
    return out.sorted { $0.id < $1.id }
}

// Window kinds. Layer 0 is a normal window (Settings); an open menu sits at
// layer >= 100; the dictation overlay is a floating panel in between. Tiny
// windows (shadows, 1x1 helpers) are excluded by area.
func resolveWindow(pid: Int, kind: String, index: Int?) -> CGWindowRecord? {
    let all = cgWindows(ownedBy: pid).filter { $0.area > 10_000 }
    switch kind {
    case "window":
        guard let index, index >= 1, index <= all.count else { return nil }
        return all[index - 1]
    case "settings":
        return all.filter { $0.layer == 0 }.max { $0.area < $1.area }
    case "popover":
        return all.filter { $0.layer >= 100 }.max { $0.area < $1.area }
    case "overlay":
        return all.filter { $0.layer > 0 && $0.layer < 100 }.max { $0.area < $1.area }
    default:
        return nil
    }
}

// MARK: - Selector

struct ElementSelector {
    var role: (String, Bool)?   // (value, exact)
    var title: (String, Bool)?
    var desc: (String, Bool)?
    var value: (String, Bool)?
    var index: Int?
    var window: Int?

    init?(_ raw: String) {
        for pair in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let text = String(pair)
            guard let opIndex = text.firstIndex(where: { $0 == "=" || $0 == "~" }) else { return nil }
            let key = String(text[text.startIndex..<opIndex])
            let exact = text[opIndex] == "="
            let rawValue = String(text[text.index(after: opIndex)...]).replacingOccurrences(of: "+", with: " ")
            if rawValue.isEmpty { return nil }
            switch key {
            case "role": role = (rawValue, exact)
            case "title": title = (rawValue, exact)
            case "desc": desc = (rawValue, exact)
            case "value": value = (rawValue, exact)
            case "index": guard let n = Int(rawValue), n >= 0 else { return nil }; index = n
            case "window": guard let n = Int(rawValue), n >= 1 else { return nil }; window = n
            default: return nil
            }
        }
        if role == nil, title == nil, desc == nil, value == nil { return nil }
    }

    private func matches(_ criterion: (String, Bool)?, _ actual: String) -> Bool {
        guard let criterion else { return true }
        return criterion.1 ? actual == criterion.0 : actual.contains(criterion.0)
    }

    func matches(_ element: AXUIElement) -> Bool {
        matches(role, str(element, kAXRoleAttribute))
            && matches(title, str(element, kAXTitleAttribute))
            && matches(desc, str(element, kAXDescriptionAttribute))
            && matches(value, str(element, kAXValueAttribute))
    }
}

func collectMatches(_ selector: ElementSelector, pid: pid_t) -> [AXUIElement] {
    var roots = windowsOf(pid)
    if let window = selector.window {
        guard window >= 1, window <= roots.count else { return [] }
        roots = [roots[window - 1]]
    }
    var found: [AXUIElement] = []
    var budget = 20_000
    func walk(_ element: AXUIElement, depth: Int) {
        if depth > 40 || budget <= 0 || found.count > 64 { return }
        budget -= 1
        if selector.matches(element) { found.append(element) }
        for child in (copyAttr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            walk(child, depth: depth + 1)
        }
    }
    for root in roots { walk(root, depth: 0) }
    return found
}

// An ambiguous selector is refused rather than guessed at: acting on "one of
// the four buttons that matched" is exactly the mistake-prone behaviour this
// gate exists to avoid. `index=` disambiguates explicitly.
func uniqueMatch(_ selector: ElementSelector, pid: pid_t) -> AXUIElement {
    let matches = collectMatches(selector, pid: pid)
    if let index = selector.index {
        guard index < matches.count else { die("selector matched \(matches.count) element(s); index=\(index) is out of range") }
        return matches[index]
    }
    guard matches.count != 0 else { die("selector matched no element") }
    guard matches.count == 1 else { die("selector matched \(matches.count) elements — add index=<n> or narrow it") }
    return matches[0]
}

// MARK: - Subcommands

func requirePID(_ raw: String) -> pid_t {
    guard let pid = Int32(raw), pid > 0 else { die("bad pid") }
    return pid
}

// MARK: - The status item
//
// localvoxtral is a menu bar app: it opens NO window at launch, so every
// window verb above has nothing to address until its status item is clicked.
// This is that click, and it stays inside the same boundary as everything
// else — the element is reached from AXUIElementCreateApplication(<the pid
// `launch` recorded>), so no other application's menu bar is expressible here.
//
// AX rather than System Events/AppleScript on purpose: the AX route needs only
// the Accessibility grant sshd already holds, while an Apple event to System
// Events would need a separate Automation grant whose consent sheet cannot be
// answered over SSH.
func extrasMenuBarItem(_ pid: pid_t) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    // Pressing a status item blocks the AX server for as long as the menu
    // tracks — the same reason capture-readme-assets.sh wraps its AppleScript
    // in `ignoring application responses`. Bound the wait instead of hanging
    // the SSH session. This is safe only because the press is verified
    // afterwards by looking for the menu: a timeout is never read as success.
    _ = AXUIElementSetMessagingTimeout(app, 2.0)
    guard let bar = copyAttr(app, "AXExtrasMenuBar") else {
        die("pid \(pid) exposes no status item (AXExtrasMenuBar)")
    }
    let items = (copyAttr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    guard let item = items.first else { die("pid \(pid) has an empty status menu bar") }
    return item
}

// The AXMenu ATTACHED to the status item — reachable, pressable, and NOT
// evidence that anything is on screen.
//
// An NSMenu handed to an NSStatusItem is an AXMenu child of that item for the
// whole life of the app, displayed or not. Field check 2026-08-29, against a
// freshly launched build that had shown nothing: `menu open` printed
// "ok already-open" and returned instantly, `shot popover` then reported no
// popover window at all, and `ax dump all` returned `[]`. The pre-check that
// used this function as "is the menu open" therefore matched every time, the
// status item was never pressed, and the verb reported success while doing
// nothing. Whatever else changes here, do not spell this `openMenu` again —
// the name was the bug.
//
// It stays because pressing a menu ITEM through AX works whether or not the
// menu is displayed (that is how the gate reached Settings while `menu open`
// was broken), so `menuclick` wants exactly this and not the window test
// below.
func attachedMenu(of item: AXUIElement) -> AXUIElement? {
    for child in (copyAttr(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    where str(child, kAXRoleAttribute) == "AXMenu" {
        return child
    }
    return nil
}

// "A menu is DISPLAYED" — the only honest test, and deliberately the SAME one
// `shot popover` resolves with: a window owned by this pid at layer >= 100
// (kCGPopUpMenuWindowLevel). Sharing resolveWindow rather than writing a
// second, similar rule is the point — `menu open` then succeeds exactly when
// `shot popover` can photograph something, by construction, and the two verbs
// cannot drift apart. If this ever answers wrongly on a live desktop, both
// verbs say so together instead of one lying to cover the other.
//
// Caveat worth knowing rather than coding around: any pid-owned window at that
// layer counts, so a context menu open inside Settings reads as "displayed"
// here. That is the same window `shot popover` would capture, which is the
// agreement this is for.
func displayedMenuWindow(pid: pid_t) -> CGWindowRecord? {
    resolveWindow(pid: Int(pid), kind: "popover", index: nil)
}

// Poll for the menu window to appear (`open`) or go away (`dismiss`). The AX
// press's own status is never the answer — it reports .cannotComplete while a
// menu tracks — so both verbs wait on the window list instead, which keeps
// answering while the app's AX server is blocked.
func waitForMenuWindow(pid: pid_t, seconds: Double) -> CGWindowRecord? {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
        if let window = displayedMenuWindow(pid: pid) { return window }
        if Date() >= deadline { return nil }
        usleep(150_000)
    }
}

func waitForMenuWindowToClose(pid: pid_t, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
        if displayedMenuWindow(pid: pid) == nil { return true }
        if Date() >= deadline { return false }
        usleep(150_000)
    }
}

// Bring one pid frontmost and give the activation up to two seconds to land.
// Callers still re-check afterwards — this only asks.
func activateAndWait(_ pid: pid_t) {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
    _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline,
          NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        usleep(100_000)
    }
}

guard let subcommand = argv.first else { die("no subcommand") }

switch subcommand {
case "preflight":
    print("accessibility=\(AXIsProcessTrusted() ? 1 : 0)")
    print("screen_recording=\(CGPreflightScreenCaptureAccess() ? 1 : 0)")
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    print("frontmost_pid=\(front)")

case "window":
    guard argv.count >= 3 else { die("usage: window <pid> <kind> [index]") }
    let pid = Int(requirePID(argv[1]))
    let index: Int? = argv.count >= 4 ? Int(argv[3]) : nil
    guard let record = resolveWindow(pid: pid, kind: argv[2], index: index) else {
        die("no \(argv[2]) window owned by pid \(pid)")
    }
    // The ownerpid is echoed so the SHELL can re-assert the ownership
    // invariant independently of this helper's filtering.
    print("\(record.id) \(record.ownerPID)")

case "axdump":
    guard argv.count >= 2 else { die("usage: axdump <pid> [kind] [index]") }
    let pid = requirePID(argv[1])
    let kind = argv.count >= 3 ? argv[2] : "all"
    var roots = windowsOf(pid)
    switch kind {
    case "all": break
    case "window":
        guard argv.count >= 4, let n = Int(argv[3]), n >= 1, n <= roots.count else { die("window index out of range") }
        roots = [roots[n - 1]]
    case "settings":
        roots = roots.filter { str($0, kAXSubroleAttribute) == "AXStandardWindow" }
        if roots.isEmpty { die("no standard window owned by pid \(pid)") }
        roots = [roots[0]]
    case "overlay":
        roots = roots.filter { str($0, kAXSubroleAttribute) != "AXStandardWindow" }
        if roots.isEmpty { die("no non-standard (overlay) window owned by pid \(pid)") }
        roots = [roots[0]]
    default:
        die("unknown dump kind \(kind)")
    }
    var out = "["
    var budget = 20_000
    func renderNode(_ element: AXUIElement, depth: Int) -> String {
        if depth > 40 || budget <= 0 { return "" }
        budget -= 1
        var node = "{\"role\":\"\(jsonEscape(str(element, kAXRoleAttribute)))\""
        node += ",\"subrole\":\"\(jsonEscape(str(element, kAXSubroleAttribute)))\""
        node += ",\"title\":\"\(jsonEscape(str(element, kAXTitleAttribute)))\""
        node += ",\"desc\":\"\(jsonEscape(str(element, kAXDescriptionAttribute)))\""
        node += ",\"value\":\"\(jsonEscape(String(str(element, kAXValueAttribute).prefix(200))))\""
        let children = (copyAttr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        let rendered = children.map { renderNode($0, depth: depth + 1) }.filter { !$0.isEmpty }
        node += ",\"children\":[" + rendered.joined(separator: ",") + "]}"
        return node
    }
    out += roots.map { renderNode($0, depth: 0) }.joined(separator: ",")
    out += "]"
    print(out)

case "axclick":
    guard argv.count >= 3, let selector = ElementSelector(argv[2]) else { die("bad selector") }
    let element = uniqueMatch(selector, pid: requirePID(argv[1]))
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { die("AXPress failed (\(result.rawValue))") }
    print("ok")

case "axtype":
    guard argv.count >= 4, let selector = ElementSelector(argv[2]) else { die("bad selector") }
    let pid = requirePID(argv[1])
    let text = argv[3]
    let element = uniqueMatch(selector, pid: pid)
    let role = str(element, kAXRoleAttribute)
    // Only text-bearing roles: typing into a button would just be a keystroke
    // sprayed at whatever has focus.
    guard ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) else {
        die("element role \(role) does not accept text")
    }
    _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, NSNumber(value: true))
    if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
        print("ok")
        break
    }
    // Fallback: synthesise the keystrokes. These are SYSTEM-WIDE events, so
    // they are only posted once the app under test owns the keyboard.
    activateAndWait(pid)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        die("AXValue was rejected and the app under test could not be brought frontmost — refusing to synthesise keystrokes")
    }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    else { die("could not create keyboard events") }
    var utf16 = Array(text.utf16)
    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    print("ok")

case "key":
    guard argv.count >= 3 else { die("usage: key <pid> <escape|tab|return>") }
    let pid = requirePID(argv[1])
    let codes: [String: CGKeyCode] = ["escape": 53, "tab": 48, "return": 36]
    guard let code = codes[argv[2]] else { die("key not in allowlist") }
    // A CGEvent goes to whatever owns the keyboard, so the app under test has
    // to own it. Ask for it, then RE-CHECK: the guarantee is not "we tried to
    // focus it", it is "the keystroke landed there or nowhere".
    activateAndWait(pid)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        die("app under test could not be brought frontmost — refusing to post a key event")
    }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    else { die("could not create keyboard events") }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    print("ok")

case "menuopen":
    guard argv.count >= 2 else { die("usage: menuopen <pid>") }
    let openPID = requirePID(argv[1])
    // The fast path is kept, but on evidence: a menu already ON SCREEN. The
    // window id is printed so the caller can see WHY this said ok, and so a
    // silent no-op can never look like a success again.
    if let existing = displayedMenuWindow(pid: openPID) {
        print("ok already-open window=\(existing.id)")
        break
    }
    let item = extrasMenuBarItem(openPID)
    _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
    // The press's own status is deliberately not trusted: it reports
    // .cannotComplete while the menu tracks. A window on screen is the answer.
    if let opened = waitForMenuWindow(pid: openPID, seconds: 3) {
        print("ok window=\(opened.id)")
        break
    }
    // Reached with the press already delivered, so the menu MAY be up and
    // simply not visible to the window list. Say that, rather than inviting a
    // second press that would toggle a tracking menu shut.
    die("the status item of pid \(openPID) was pressed but no window appeared at "
        + "layer >= 100 within 3s — the same window `shot popover` resolves. "
        + "Run `menu dismiss` before retrying; `menu click <title>` works "
        + "without a displayed menu.")

case "menuclick":
    guard argv.count >= 3 else { die("usage: menuclick <pid> <item-title>") }
    let wanted = argv[2].replacingOccurrences(of: "+", with: " ")
    // ATTACHED, not displayed, and that is the point: AXPress on a menu item
    // works whether or not the menu is on screen, so this verb keeps working
    // when `menu open` cannot resolve a window (it is how the gate reached
    // Settings on 2026-08-29).
    let clickPID = requirePID(argv[1])
    guard let menu = attachedMenu(of: extrasMenuBarItem(clickPID)) else {
        die("pid \(clickPID) exposes no status menu (no AXMenu under its status item)")
    }
    let entries = ((copyAttr(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
        .filter { !str($0, kAXTitleAttribute).isEmpty }
    // Menu titles carry characters the gate's token charset cannot express
    // (localvoxtral's is "Settings…"), so the argument is matched by
    // containment. An exact title still wins, so "Save" is never ambiguous
    // with "Save As…"; beyond that, ambiguity is refused rather than guessed
    // at — the same rule the element selector applies.
    var menuMatches = entries.filter { str($0, kAXTitleAttribute) == wanted }
    if menuMatches.isEmpty {
        menuMatches = entries.filter { str($0, kAXTitleAttribute).contains(wanted) }
    }
    guard !menuMatches.isEmpty else {
        die("no menu item matches \"\(wanted)\"; the menu holds: "
            + entries.map { str($0, kAXTitleAttribute) }.joined(separator: " | "))
    }
    guard menuMatches.count == 1 else {
        die("\(menuMatches.count) menu items contain \"\(wanted)\" — name more of the title")
    }
    let pressResult = AXUIElementPerformAction(menuMatches[0], kAXPressAction as CFString)
    guard pressResult == .success else { die("AXPress on the menu item failed (\(pressResult.rawValue))") }
    print("ok")

case "menudismiss":
    guard argv.count >= 2 else { die("usage: menudismiss <pid>") }
    let dismissPID = requirePID(argv[1])
    // Nothing on screen: return BEFORE touching the status item. This branch
    // used to be decided by attachment, which is always true, so it never ran
    // — and the fallback below presses the status item, which on a closed menu
    // OPENS one. A dismiss verb must never be able to open a menu.
    guard displayedMenuWindow(pid: dismissPID) != nil else {
        print("ok no-menu-open")
        break
    }
    let dismissItem = extrasMenuBarItem(dismissPID)
    // AXCancel on the app's own menu, not a synthesised Escape: a keystroke
    // goes to whatever owns the keyboard, and closing a menu never has to.
    // Its return code is trusted no further than AXPress's: the window going
    // away is the answer.
    if let attached = attachedMenu(of: dismissItem) {
        _ = AXUIElementPerformAction(attached, kAXCancelAction as CFString)
        if waitForMenuWindowToClose(pid: dismissPID, seconds: 2) {
            print("ok")
            break
        }
    }
    // Fall back to toggling the status item shut — still the app's own
    // element, and only ever reached with a menu confirmed on screen.
    _ = AXUIElementPerformAction(dismissItem, kAXPressAction as CFString)
    if waitForMenuWindowToClose(pid: dismissPID, seconds: 2) {
        print("ok pressed")
        break
    }
    die("the menu window of pid \(dismissPID) is still on screen after AXCancel and a status-item press")

case "dictate":
    guard argv.count >= 4 else { die("usage: dictate <pid> <modifier> <tap|hold|cancel> [seconds]") }
    let dictatePID = requirePID(argv[1])
    guard NSRunningApplication(processIdentifier: dictatePID) != nil else {
        die("the app under test (pid \(dictatePID)) is not running")
    }
    // Secure Keyboard Entry discards synthesised input outright — a locked
    // screen, a password field, or a terminal with the setting on. Without
    // this check the verb's failure shape is a silent no-op, which is the
    // worst one to debug (record-demo.sh checks the same thing before its
    // live-dictation beat).
    if IsSecureEventInputEnabled() {
        die("Secure Keyboard Entry is held by some process — synthesised input would be discarded")
    }
    let gesture = argv[3]
    if gesture == "cancel" {
        // The app registers a Carbon hotkey on plain Escape for the duration
        // of a dictation and consumes it system-wide, so cancelling needs
        // neither the trigger modifier nor a frontmost app.
        guard let cancelSource = CGEventSource(stateID: .hidSystemState),
              let escDown = CGEvent(keyboardEventSource: cancelSource, virtualKey: 53, keyDown: true),
              let escUp = CGEvent(keyboardEventSource: cancelSource, virtualKey: 53, keyDown: false)
        else { die("could not create keyboard events") }
        escDown.post(tap: .cghidEventTap)
        escUp.post(tap: .cghidEventTap)
        print("ok cancel")
        break
    }
    // The trigger is a modifier-ONLY gesture: a keyboard event whose type is
    // overridden to .flagsChanged and which carries that modifier's flag mask.
    // A plain keyDown never reaches the app's handleFlagsChanged and does
    // nothing at all. This is the shape scripts/record-demo.sh has driven on
    // this machine since the demo recording.
    let triggers: [String: (CGKeyCode, CGEventFlags)] = [
        "fn": (CGKeyCode(kVK_Function), .maskSecondaryFn),
        "right_command": (CGKeyCode(kVK_RightCommand), .maskCommand),
        "right_option": (CGKeyCode(kVK_RightOption), .maskAlternate),
    ]
    guard let trigger = triggers[argv[2]] else { die("unknown trigger modifier \(argv[2])") }
    func postTrigger(down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: trigger.0, keyDown: down) else {
            die("could not create the trigger event")
        }
        event.type = .flagsChanged
        event.flags = down ? trigger.1 : []
        event.post(tap: .cghidEventTap)
    }
    // A hold holds a real modifier down for seconds. If this process is killed
    // in between — a dropped SSH connection is the ordinary case — the flag
    // stays latched across the owner's entire session. Release it on the way
    // out rather than leaving that behind.
    var signalSources: [DispatchSourceSignal] = []
    for interrupting in [SIGTERM, SIGINT, SIGHUP] {
        signal(interrupting, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: interrupting, queue: .global())
        source.setEventHandler {
            postTrigger(down: false)
            exit(1)
        }
        source.resume()
        signalSources.append(source)
    }
    switch gesture {
    case "tap":
        postTrigger(down: true)
        Thread.sleep(forTimeInterval: 0.08)
        postTrigger(down: false)
    case "hold":
        guard argv.count >= 5, let seconds = Double(argv[4]), seconds > 0, seconds <= 60 else {
            die("hold needs a duration in seconds (0 < s <= 60)")
        }
        postTrigger(down: true)
        Thread.sleep(forTimeInterval: seconds)
        postTrigger(down: false)
    default:
        die("unknown gesture \(gesture)")
    }
    // Where the dictation actually landed. The trigger is global by design and
    // the session grounds itself in whatever is focused, so this is the single
    // most useful thing to report back.
    let front = NSWorkspace.shared.frontmostApplication
    let frontName = (front?.localizedName ?? "?").replacingOccurrences(of: "\n", with: " ")
    print("ok \(gesture) trigger=\(argv[2]) frontmost=\(front?.processIdentifier ?? -1) (\(frontName))")

// The window ids a terminal application owns right now, taken BEFORE `open`.
// A title marker cannot be the identity of a `term open` window: the one
// command this verb exists to run is a whole-view herdr client, and herdr owns
// the terminal title from the moment it starts (docs/agent/invariants.md says
// so outright, and the app's own titleMarker join arm is suppressed for the
// same reason). A window that is NEW since this snapshot needs no cooperation
// from the child process at all.
case "termsnapshot":
    var snapshot: [String] = []
    for raw in argv.dropFirst() {
        guard let pid = Int(raw), pid > 0 else { continue }
        snapshot.append(contentsOf: cgWindows(ownedBy: pid).filter { $0.area > 10_000 }.map { String($0.id) })
    }
    print(snapshot.joined(separator: ","))

// The window that appeared since that snapshot.
//
// Exit codes are the contract: 0 with "ok <winid> <ownerpid>", 1 when nothing
// new is there yet (the caller polls), 2 when SEVERAL windows appeared and
// this cannot tell which one it opened — that last one never guesses, because
// binding the wrong window would point `term close` at whatever the owner just
// opened.
case "termnew":
    guard argv.count >= 4 else { die("usage: termnew <ownerpid> <marker|-> <excluded-ids|->") }
    let pid = Int(requirePID(argv[1]))
    let marker = argv[2]
    let excluded = Set(argv[3].split(separator: ",").compactMap { Int($0) })
    let candidates = cgWindows(ownedBy: pid).filter { $0.area > 10_000 && !excluded.contains($0.id) }
    // The OSC title marker is kept as a TIE-BREAKER, never as the identity: it
    // still disambiguates for commands that leave the title alone, and it is
    // simply absent for a herdr-hosted one.
    let tagged = candidates.filter { !marker.isEmpty && marker != "-" && $0.title.contains(marker) }
    if tagged.count == 1 {
        print("ok \(tagged[0].id) \(tagged[0].ownerPID)")
        exit(0)
    }
    if candidates.count == 1 {
        print("ok \(candidates[0].id) \(candidates[0].ownerPID)")
        exit(0)
    }
    if candidates.isEmpty { die("no window of pid \(pid) appeared since the snapshot") }
    let ids = candidates.map { String($0.id) }.joined(separator: " ")
    // The ids go to STDOUT in a parseable line as well as into the sentence on
    // stderr. Refusing to guess is still the answer, but the caller has to be
    // able to TAKE BACK what it opened, and it cannot do that with a window it
    // was never told about (field failure 2026-09-05: two Ghostty windows the
    // gate could not name were left on the owner's desktop for him to close by
    // hand).
    print("ambiguous \(pid) \(ids)")
    FileHandle.standardError.write(Data((
        "helper: \(candidates.count) windows of pid \(pid) appeared since the snapshot "
        + "(ids \(ids)) and none carries the marker — refusing to guess which one this gate opened\n"
    ).utf8))
    exit(2)

case "termaction":
    guard argv.count >= 4 else { die("usage: termaction <ownerpid> <winid> <focus|close>") }
    let pid = requirePID(argv[1])
    guard let winid = Int(argv[2]), winid > 0 else { die("malformed window id") }
    // The recorded CGWindowID is the proof that THIS gate opened the window,
    // and it is still checked against the recorded owner pid: a window id is
    // only ever acted on when the live window list says that pid owns it.
    guard let record = cgWindows(ownedBy: Int(pid)).first(where: { $0.id == winid }) else {
        die("no window \(winid) owned by pid \(pid) — it is closed, or it was never this gate's")
    }
    // AX exposes no window id without private API, so the bridge is the frame:
    // AXPosition/AXSize and kCGWindowBounds are the same top-left screen
    // coordinates. Two windows sharing a frame to the pixel is refused rather
    // than guessed at.
    guard let window = axWindow(pid: pid, matching: record.frame) else {
        die("window \(winid) of pid \(pid) has no unique accessibility window at its frame")
    }
    switch argv[3] {
    case "focus":
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        print("ok")
    case "close":
        guard let rawButton = copyAttr(window, kAXCloseButtonAttribute) else {
            die("window has no close button")
        }
        let button = rawButton as! AXUIElement
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard result == .success else { die("close failed (\(result.rawValue))") }
        print("ok")
    default:
        die("unknown termaction")
    }

// control <socket-path> <line>
//
// One line to the dogfood control socket of the app under test, one line back.
// Written here rather than shelled out to `nc` for two reasons: the exact
// half-close/EOF behaviour of BSD nc's `-U` is a detail this must not depend
// on, and the embedded helper is compile-checked by test-ui-gate.sh while a
// shell pipeline would not be.
//
// It connects, writes, reads, prints, exits. It has no idea what the line
// means; the shell side decided that (run_app) and the app's own socket
// validates it again.
// Is anything LISTENING on the control socket right now.
//
// `state` used to answer this with `[[ -S … ]]`, which is a question about a
// FILE. A dogfood build that has quit leaves its socket behind (and a build
// with no control socket compiled in never removes a predecessor's), so the
// gate reported `"present":true` while every `app` command failed with
// `could not connect (61)`. That is a diagnostic saying "armed" about
// something that cannot answer — measured 2026-09-05, where the installed
// dogfood build predated the control socket entirely and `state` still
// claimed it was there.
//
// Connect and close, nothing sent. A refused connect is the answer, and it
// costs one syscall round trip on a path `state` already had to stat.
case "controlprobe":
    guard argv.count >= 2 else { die("usage: controlprobe <socket-path>") }
    let probePath = argv[1]
    var probeAddress = sockaddr_un()
    probeAddress.sun_family = sa_family_t(AF_UNIX)
    let probeBytes = Array(probePath.utf8)
    guard probeBytes.count < MemoryLayout.size(ofValue: probeAddress.sun_path) else { exit(1) }
    withUnsafeMutableBytes(of: &probeAddress.sun_path) { raw in
        raw.copyBytes(from: probeBytes)
        raw[probeBytes.count] = 0
    }
    probeAddress.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let probeFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard probeFD >= 0 else { exit(1) }
    defer { close(probeFD) }
    let probeConnected = withUnsafePointer(to: &probeAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(probeFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    exit(probeConnected == 0 ? 0 : 1)

case "control":
    guard argv.count >= 3 else { die("usage: control <socket-path> <line>") }
    let socketPath = argv[1]
    let line = argv[2]
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        die("socket path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
        raw[pathBytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let controlFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard controlFD >= 0 else { die("could not create a socket (\(errno))") }
    defer { close(controlFD) }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(controlFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        die("could not connect to the control socket (\(errno)) — is the app a dogfood build with debug.dogfood_control_socket_enabled armed?")
    }
    // Bounded on both halves: a wedged app must cost the operator a refusal,
    // never a hung SSH command.
    var controlTimeout = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(controlFD, SOL_SOCKET, SO_SNDTIMEO, &controlTimeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(controlFD, SOL_SOCKET, SO_RCVTIMEO, &controlTimeout, socklen_t(MemoryLayout<timeval>.size))
    let outgoing = Array((line + "\n").utf8)
    var sent = 0
    while sent < outgoing.count {
        let written = outgoing.withUnsafeBytes { raw -> Int in
            write(controlFD, raw.baseAddress!.advanced(by: sent), outgoing.count - sent)
        }
        if written <= 0 {
            if written < 0, errno == EINTR { continue }
            die("could not send the command (\(errno))")
        }
        sent += written
    }
    var incoming = [UInt8]()
    var controlChunk = [UInt8](repeating: 0, count: 4096)
    // 64 KiB is far past any reply the socket produces; the cap is a backstop
    // against a peer that is not the app we think it is.
    while incoming.count < 65_536 {
        let count = read(controlFD, &controlChunk, controlChunk.count)
        if count < 0 {
            if errno == EINTR { continue }
            die("could not read the reply (\(errno))")
        }
        if count == 0 { break }
        incoming.append(contentsOf: controlChunk[0..<count])
        if incoming.contains(0x0A) { break }
    }
    guard !incoming.isEmpty else { die("the control socket closed without answering") }
    if let newline = incoming.firstIndex(of: 0x0A) { incoming = Array(incoming[0..<newline]) }
    print(String(decoding: incoming, as: UTF8.self))

default:
    die("unknown subcommand \(subcommand)")
}
SWIFT
  chmod 0600 "$HELPER_PATH" 2>/dev/null || true
}

helper() {
  write_helper
  swift "$HELPER_PATH" "$@"
}

# ---------------------------------------------------------------------------
# App under test — identity that survives pid reuse
# ---------------------------------------------------------------------------
# Every window/AX/key verb is scoped to ONE pid: the one `launch` recorded.
# A recorded pid is only trusted when the live process still has the same
# start time and the same executable path, so a recycled pid can never inherit
# the gate's authority to be photographed and driven.
#
# No verb writes this file except `launch`, and `launch` only ever records a
# validated localvoxtral bundle's pid — that is what stops a `term open`
# terminal from ever becoming the target of `shot`/`ax *`/`key`. Forging the
# file needs local write access to the state dir, which is the same trust level
# as replacing this script (see GATE_CONF above).

APP_STATE="$STATE_DIR/app.state"
APP_PID=""
APP_BUNDLE=""
APP_DOGFOOD="0"

# Start time AND executable path. Either alone is forgeable by pid reuse:
# a recycled pid can match the path (relaunch) or the second (another app
# started in the same second), never both.
process_identity() { # <pid> -> "<lstart>|<executable>"
  local pid="$1" started executable
  started="$(ps -p "$pid" -o lstart= 2>/dev/null)" || return 1
  executable="$(ps -p "$pid" -o comm= 2>/dev/null)" || return 1
  [[ -n "$started" && -n "$executable" ]] || return 1
  printf '%s|%s\n' "$started" "$executable"
}

load_app_state() {
  APP_PID=""
  APP_BUNDLE=""
  APP_DOGFOOD="0"
  [[ -f "$APP_STATE" ]] || return 1
  local pid bundle identity dogfood live
  pid="$(sed -n 's/^pid=//p' "$APP_STATE" | head -n 1)"
  bundle="$(sed -n 's/^bundle=//p' "$APP_STATE" | head -n 1)"
  identity="$(sed -n 's/^identity=//p' "$APP_STATE" | head -n 1)"
  dogfood="$(sed -n 's/^dogfood=//p' "$APP_STATE" | head -n 1)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  live="$(process_identity "$pid")" || return 1
  [[ "$live" == "$identity" ]] || return 1
  APP_PID="$pid"
  APP_BUNDLE="$bundle"
  APP_DOGFOOD="${dogfood:-0}"
}

require_app_under_test() {
  load_app_state \
    || deny "no app under test — run \`launch <artifact>\` first"
}

# ---------------------------------------------------------------------------
# Bundle validation
# ---------------------------------------------------------------------------

plist_value() { # <plist> <key>
  local plist="$1" key="$2" value
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" || value=""
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  # XML fallback (also what makes bundle validation testable off a Mac): the
  # value element follows its <key> line.
  awk -v want="$key" '
    /<key>/ { k = $0; sub(/^.*<key>/, "", k); sub(/<\/key>.*$/, "", k); next }
    k == want {
      line = $0
      if (line ~ /<true\/>/) { print "true"; exit }
      if (line ~ /<false\/>/) { print "false"; exit }
      if (line ~ /<string>/) {
        sub(/^.*<string>/, "", line); sub(/<\/string>.*$/, "", line)
        print line; exit
      }
    }
  ' "$plist" 2>/dev/null
}

# A localvoxtral bundle and nothing else: the identifier, the declared
# executable name and an executable at the path that name implies all have to
# agree. This is what stops `launch` from being "start any application on the
# owner's Mac".
validate_localvoxtral_bundle() { # <resolved-bundle-path>
  local bundle="$1" plist="$1/Contents/Info.plist"
  [[ -d "$bundle" && "$bundle" == *.app ]] || return 1
  [[ -f "$plist" ]] || return 1
  [[ "$(plist_value "$plist" CFBundleIdentifier)" == "com.localvoxtral.app" ]] || return 1
  [[ "$(plist_value "$plist" CFBundleExecutable)" == "localvoxtral" ]] || return 1
  [[ -x "$bundle/Contents/MacOS/localvoxtral" ]] || return 1
}

resolve_artifact() { # <argument> -> absolute, symlink-free path under a root
  local argument="$1" resolved root
  token_is_safe "$argument" || return 1
  [[ "$argument" != *".."* ]] || return 1
  for root in $LV_UI_ARTIFACT_ROOTS; do
    root="$(cd "$root" 2>/dev/null && pwd -P)" || continue
    # A BARE NAME is resolved against each root, because that is the only form
    # `state` ever hands back: `setup.artifacts` lists names, and pasting one
    # into `launch` used to deny with "not inside an allowlisted root" — a
    # refusal for the one spelling the gate itself printed. An absolute or
    # relative path still works and is still bound by the same containment
    # check below; the name form just saves guessing WHICH root it came from.
    if [[ "$argument" != /* && "$argument" != */* ]]; then
      resolved="$(cd "$root/$argument" 2>/dev/null && pwd -P)" || continue
    else
      resolved="$(cd "$argument" 2>/dev/null && pwd -P)" || return 1
    fi
    if [[ "$resolved" == "$root"/* ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------

json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

json_bool() { # <truthy test result as 0/1>
  (( $1 == 1 )) && printf 'true' || printf 'false'
}

# A whitespace-separated list -> a JSON array of strings.
json_word_array() {
  local word out=""
  for word in $1; do
    [[ -n "$out" ]] && out+=","
    out+="$(json_string "$word")"
  done
  printf '[%s]' "$out"
}

# ---------------------------------------------------------------------------
# Setup readiness — the half of `state` that predicts a denial
# ---------------------------------------------------------------------------
#
# Why this exists, from a real session (2026-08-30): an operator drove this
# gate for an hour and hit `term open` refusing everything and `app` denying,
# and neither refusal was distinguishable from "the verb is broken" or "the
# gate is old". The causes were three ABSENT files and one unset default —
# each a one-line fix, each invisible until a verb failed. So `state` now
# reports the setup, and the bar it is held to is: an operator should be able
# to predict which verbs will work BEFORE trying them.
#
# What it reports and what it does not: file PRESENCE, whether a file PARSES,
# and the values that are already the gate's own vocabulary (allowlisted
# command names, terminal names, bundle names under a root this gate names in
# its own denials). Never a file's contents.

# Which build of this script is installed. The whole reason it is here: "the
# gate is old" was one of the indistinguishable explanations above, and a
# 12-character digest the operator can compare against
# `shasum -a 256 scripts/mac/localvoxtral-ui-gate.sh` settles it in one line.
gate_revision() {
  local digest=""
  if command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "$0" 2>/dev/null || true)"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$0" 2>/dev/null || true)"
  fi
  digest="${digest%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { printf 'unknown'; return; }
  printf '%s' "${digest:0:12}"
}

# The launchable bundles `launch` would accept, by NAME. Nothing here is a
# disclosure: the roots are named in `launch`'s own refusal text, and the two
# names the installer ever writes are in scripts/mac/README.md.
setup_artifacts_json() {
  local root bundle out="" name stamp
  for root in $LV_UI_ARTIFACT_ROOTS; do
    [[ -d "$root" ]] || continue
    for bundle in "$root"/*.app; do
      [[ -d "$bundle" ]] || continue
      name="${bundle##*/}"
      validate_localvoxtral_bundle "$bundle" || continue
      stamp="$(plist_value "$bundle/Contents/Info.plist" LVXDogfoodCapture)"
      [[ -n "$out" ]] && out+=","
      out+="{\"name\":$(json_string "$name"),\"dogfood\":$([[ "$stamp" == "true" ]] && echo true || echo false)}"
    done
  done
  printf '[%s]' "$out"
}

# Every conf-allowlisted name that the permanent denylist refuses anyway. A
# conf that allowlists `ssh` reads as configured and behaves as unconfigured;
# without this the operator sees only "denied command".
setup_denylisted_json() {
  local name out=""
  for name in $LV_UI_TERM_COMMANDS; do
    list_contains "$name" "$LV_UI_TERM_FORBIDDEN" || continue
    [[ -n "$out" ]] && out+=","
    out+="$(json_string "$name")"
  done
  printf '[%s]' "$out"
}

# Every allowlisted name with no executable file behind it. This is the whole
# of the 2026-08-30 failure, reported before a verb is tried: the name was
# allowlisted, the wrapper was not installed where the launcher could find it,
# and `term open` opened an empty window rather than saying so.
setup_unresolvable_json() {
  local name out=""
  for name in $LV_UI_TERM_COMMANDS; do
    list_contains "$name" "$LV_UI_TERM_FORBIDDEN" && continue
    resolve_term_command "$name" >/dev/null && continue
    [[ -n "$out" ]] && out+=","
    out+="$(json_string "$name")"
  done
  printf '[%s]' "$out"
}

ATTACH_CONF_STATUS="absent"
ATTACH_DESTINATION=""
ATTACH_SESSION=0

# Ask the INSTALLED wrapper, rather than re-reading its config here.
#
# One validator, in the file whose whole job is to hold that boundary: a copy
# of it in this script could drift, and the copy that matters is the one the
# `term open` window will actually run. It also makes three different failures
# three different answers — no wrapper, a wrapper too old to answer, and a
# wrapper that answers "no destination".
#
# `lv-attach --check` reads a file with `sed` and prints; it opens no network
# connection and starts no child. It is 0700 and owner-written, which is the
# same trust level as this script and as the conf file this gate sources.
attach_check() {
  ATTACH_CONF_STATUS="absent"
  ATTACH_DESTINATION=""
  ATTACH_SESSION=0
  if [[ ! -x "$LV_UI_ATTACH_WRAPPER" ]]; then
    [[ -f "$LV_UI_ATTACH_CONF" ]] && ATTACH_CONF_STATUS="present-unchecked"
    return
  fi
  local output status destination session
  output="$(LV_ATTACH_CONF="$LV_UI_ATTACH_CONF" "$LV_UI_ATTACH_WRAPPER" --check 2>/dev/null || true)"
  # An older wrapper refuses every flag, which is correct of it and is also
  # exactly how "you are running a wrapper from before this gate" looks.
  status="$(awk -F= '/^conf=/ { sub(/^conf=/, ""); print; exit }' <<<"$output")"
  [[ -n "$status" ]] || { ATTACH_CONF_STATUS="wrapper-too-old"; return; }
  case "$status" in
    ok | missing | no-destination | invalid-destination) ATTACH_CONF_STATUS="$status" ;;
    *) ATTACH_CONF_STATUS="unknown" ;;
  esac
  destination="$(awk -F= '/^destination=/ { sub(/^destination=/, ""); print; exit }' <<<"$output")"
  # Re-validated here even though the wrapper validated it: this string is
  # about to be printed, and a `state` that echoes whatever a file contained
  # is the disclosure this section exists to avoid.
  [[ "$destination" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || destination=""
  ATTACH_DESTINATION="$destination"
  session="$(awk -F= '/^session=/ { sub(/^session=/, ""); print; exit }' <<<"$output")"
  [[ "$session" == "configured" ]] && ATTACH_SESSION=1
}

# Whether the control socket ANSWERS, not whether its path exists.
#
# A dogfood build that quit leaves its socket file behind, and a build with no
# control socket compiled in never removes a predecessor's — so the file test
# this replaces reported `"present":true` for a socket that every `app` command
# then failed to reach with `could not connect (61)`. Measured 2026-09-05: the
# installed dogfood build predated the control socket entirely and `state`
# still said it was there. `state` exists to answer "is it safe to drive"; a
# field in it that cannot fail is not an answer.
control_socket_live() {
  [[ -S "$LV_UI_CONTROL_SOCKET" ]] || { printf 'false'; return; }
  if helper controlprobe "$LV_UI_CONTROL_SOCKET" >/dev/null 2>&1; then
    printf 'true'
  else
    printf 'false'
  fi
}

setup_json() {
  local socket_consent gate_conf_present lock_probe_present
  local attach_installed attach_allowlisted

  attach_check

  socket_consent="$(app_default debug.dogfood_control_socket_enabled)"
  case "$socket_consent" in
    1) socket_consent="on" ;;
    0) socket_consent="off" ;;
    *) socket_consent="unset" ;;
  esac

  gate_conf_present=0
  [[ -f "$GATE_CONF" ]] && gate_conf_present=1
  lock_probe_present=0
  [[ -x "$LOCK_PROBE" ]] && lock_probe_present=1
  attach_installed=0
  [[ -x "$LV_UI_ATTACH_WRAPPER" ]] && attach_installed=1
  attach_allowlisted=0
  list_contains lv-attach "$LV_UI_TERM_COMMANDS" && attach_allowlisted=1

  printf '{"gate":{"revision":%s},"lock_probe":{"installed":%s},"gate_conf":{"present":%s,"status":%s},"artifacts":%s,"term_open":{"terminals":%s,"commands":%s,"refused_by_denylist":%s,"unresolvable":%s},"lv_attach":{"installed":%s,"allowlisted":%s,"conf":%s,"destination":%s,"session_default":%s},"control_socket":{"present":%s,"consent":%s}}' \
    "$(json_string "$(gate_revision)")" \
    "$(json_bool "$lock_probe_present")" \
    "$(json_bool "$gate_conf_present")" "$(json_string "$GATE_CONF_STATUS")" \
    "$(setup_artifacts_json)" \
    "$(json_word_array "$LV_UI_TERMINALS")" \
    "$(json_word_array "$LV_UI_TERM_COMMANDS")" \
    "$(setup_denylisted_json)" \
    "$(setup_unresolvable_json)" \
    "$(json_bool "$attach_installed")" "$(json_bool "$attach_allowlisted")" \
    "$(json_string "$ATTACH_CONF_STATUS")" \
    "$([[ -n "$ATTACH_DESTINATION" ]] && json_string "$ATTACH_DESTINATION" || printf 'null')" \
    "$(json_bool "$ATTACH_SESSION")" \
    "$(control_socket_live)" \
    "$(json_string "$socket_consent")"
}

# state — the only verb that answers while the screen is locked, because
# "is it safe to drive right now" is exactly what it is for. Read-only.
run_state() {
  local lock idle power preflight accessibility screen_recording running_json terminals
  lock="$(screen_lock_state)"
  # `|| true` is load-bearing, not defensive noise: awk `exit`s on the first
  # match while ioreg is still writing, so ioreg takes SIGPIPE and `pipefail`
  # makes the whole substitution non-zero — under `set -e` that killed `state`
  # with rc 141 and no output at all (first install, 2026-08-28). The validity
  # guard on the next line already covers an empty result.
  idle="$(ioreg -c IOHIDSystem 2>/dev/null \
    | awk '/HIDIdleTime/ { gsub(/[^0-9]/, "", $NF); if ($NF != "") { print int($NF / 1000000000); exit } }' || true)"
  [[ "$idle" =~ ^[0-9]+$ ]] || idle="null"
  # Same SIGPIPE shape as the idle probe above: `head` closes the pipe while
  # pmset is still writing. `*)` already yields "unknown" for an empty read.
  case "$(pmset -g ps 2>/dev/null | head -n 1 || true)" in
    *"AC Power"*) power="ac" ;;
    *"Battery Power"* | *"UPS Power"*) power="battery" ;;
    *) power="unknown" ;;
  esac
  preflight="$(helper preflight 2>/dev/null || true)"
  accessibility="$(sed -n 's/^accessibility=//p' <<<"$preflight")"
  screen_recording="$(sed -n 's/^screen_recording=//p' <<<"$preflight")"
  [[ "$accessibility" == "1" ]] && accessibility=true || accessibility=false
  [[ "$screen_recording" == "1" ]] && screen_recording=true || screen_recording=false

  if load_app_state; then
    running_json="{\"running\":true,\"pid\":$APP_PID,\"bundle\":$(json_string "$APP_BUNDLE"),\"dogfood\":$([[ "$APP_DOGFOOD" == 1 ]] && echo true || echo false)}"
  else
    running_json='{"running":false}'
  fi

  terminals=""
  local file id term marker pid window unconfirmed
  for file in "$STATE_DIR"/terms/*.state; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"
    id="${id%.state}"
    term="$(sed -n 's/^terminal=//p' "$file" | head -n 1)"
    marker="$(sed -n 's/^marker=//p' "$file" | head -n 1)"
    pid="$(sed -n 's/^pid=//p' "$file" | head -n 1)"
    window="$(sed -n 's/^window=//p' "$file" | head -n 1)"
    unconfirmed=false
    [[ "$(sed -n 's/^unconfirmed=//p' "$file" | head -n 1)" == "1" ]] && unconfirmed=true
    [[ -n "$terminals" ]] && terminals+=","
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || pid=0
    [[ "$window" =~ ^[1-9][0-9]*$ ]] || window=0
    terminals+="{\"id\":$(json_string "$id"),\"terminal\":$(json_string "$term"),\"pid\":$pid,\"window\":$window,\"alive\":$( (( pid > 0 )) && kill -0 "$pid" 2>/dev/null && echo true || echo false),\"marker\":$(json_string "$marker"),\"unconfirmed\":$unconfirmed}"
  done

  printf '{"screen_lock":%s,"idle_seconds":%s,"power":%s,"tcc":{"accessibility":%s,"screen_recording":%s},"app":%s,"terminals":[%s],"setup":%s}\n' \
    "$(json_string "$lock")" "$idle" "$(json_string "$power")" \
    "$accessibility" "$screen_recording" "$running_json" "$terminals" \
    "$(setup_json)"
}

# launch [--dogfood] <artifact>
run_launch() {
  local dogfood=0 argument="" bundle stamp pid deadline foreign
  while (( $# > 0 )); do
    case "$1" in
      --dogfood) dogfood=1 ;;
      -*) deny "unknown launch flag" ;;
      *)
        [[ -z "$argument" ]] || deny "launch takes exactly one artifact"
        argument="$1"
        ;;
    esac
    shift
  done
  [[ -n "$argument" ]] || deny "launch needs an artifact path"

  bundle="$(resolve_artifact "$argument")" \
    || deny "artifact is not inside an allowlisted root ($LV_UI_ARTIFACT_ROOTS)"
  validate_localvoxtral_bundle "$bundle" \
    || deny "not a localvoxtral bundle: $bundle"

  stamp="$(plist_value "$bundle/Contents/Info.plist" LVXDogfoodCapture)"
  if (( dogfood == 1 )) && [[ "$stamp" != "true" ]]; then
    deny "--dogfood on a bundle without the LVXDogfoodCapture stamp (got: ${stamp:-absent})"
  fi

  # Refuse to start a second instance: it would orphan the recorded pid (two
  # menu bar icons, two hotkey owners) and silently retarget every later verb.
  if load_app_state; then
    deny "pid $APP_PID is already under test — quit it first"
  fi

  # A localvoxtral this gate did NOT start is the same conflict wearing a
  # different hat, and the gate cannot quit it (no recorded identity) or
  # address it (every other verb reads app.state). Two instances re-register
  # the global hotkey and fight over the speechd/polishd ports 8471/8472, and
  # the owner's daily driver is exactly what is running on this machine — on
  # 2026-08-29 `launch` would have started a second one beside pid 91687 and
  # only the operator noticing prevented it. So: refuse, and name the pid.
  foreign="$(pgrep -x localvoxtral 2>/dev/null | tr '\n' ' ' || true)"
  foreign="${foreign% }"
  if [[ -n "$foreign" ]]; then
    deny "localvoxtral is already running (pid $foreign) and this gate did not start it — quit it first (its menu bar item, or kill $foreign)"
  fi

  require_unlocked_screen
  log_command ALLOW "bundle=$bundle dogfood=$dogfood"
  announce_takeover "launching localvoxtral under test"

  if (( dogfood == 1 )); then
    # Same runtime opt-in try-pr.sh arms, for the same reason: a dogfood
    # launch that cannot capture is the wrong-binary confusion in disguise.
    defaults write com.localvoxtral.app debug.dogfood_capture_enabled -bool true >/dev/null 2>&1 || true
  fi

  open -n "$bundle" || fail "open refused the bundle"

  # `pgrep -f` matches its pattern as a PREFIX of the whole command line, and
  # this bundle ships localvoxtral-speechd, localvoxtral-polishd and
  # localvoxtral-claude-hook in the SAME directory (package_app.sh) — every one
  # of them matches "<bundle>/Contents/MacOS/localvoxtral". The app starts its
  # helpers during launch, and `pgrep -n` answers with the NEWEST match, so the
  # bare prefix could record a helper's pid: `ax dump` then returns [] forever,
  # `shot` never finds a window, and `quit` kills the helper while the real app
  # keeps running — after which `launch` refuses beside "a localvoxtral this
  # gate did not start" and only the owner can unwedge it. Timing-dependent,
  # and invisible to a stub that answers with one pid.
  #
  # So the prefix only nominates candidates; the executable path decides. BSD
  # `ps -o comm=` is the full path, which is the same fact `process_identity`
  # already trusts for pid reuse.
  local app_executable="$bundle/Contents/MacOS/localvoxtral" candidate
  deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    for candidate in $(pgrep -f "^$app_executable" 2>/dev/null | sort -rn); do
      [[ "$(ps -p "$candidate" -o comm= 2>/dev/null)" == "$app_executable" ]] || continue
      pid="$candidate"
      break
    done
    [[ -n "${pid:-}" ]] && break
    sleep 0.5
  done
  [[ -n "${pid:-}" ]] || fail "the app did not start within 20 seconds"

  mkdir -p "$STATE_DIR"
  chmod 0700 "$STATE_DIR" 2>/dev/null || true
  {
    printf 'pid=%s\n' "$pid"
    printf 'bundle=%s\n' "$bundle"
    printf 'identity=%s\n' "$(process_identity "$pid")"
    printf 'dogfood=%s\n' "$dogfood"
  } >"$APP_STATE"

  ACTION_COMPLETED=1
  printf 'launched pid=%s bundle=%s dogfood=%s\n' "$pid" "$bundle" "$dogfood"
}

# shot [settings|popover|overlay|window <n>] — ONE window, by CGWindowID, and
# only if that window's owner is the pid this gate launched.
#
# stdout is the base64 of the PNG and NOTHING else, so the documented form
#   ssh lv-ui 'shot popover' | base64 -d > /tmp/popover.png
# is correct with no `tail -n +2`. The `shot: window …` line below is on
# stderr for exactly that reason. It reads like a header only because an
# interactive ssh delivers both streams to the same terminal; redirect stdout
# and the header stays behind on the terminal, where it is useful.
run_shot() {
  local kind="${1:-settings}" index="${2:-}" resolved winid owner file size
  case "$kind" in
    settings | popover | overlay) [[ -z "$index" ]] || deny "$kind takes no index" ;;
    window) [[ "$index" =~ ^[1-9][0-9]{0,2}$ ]] || deny "window needs an index 1..999" ;;
    *) deny "unknown shot target" ;;
  esac
  require_unlocked_screen
  require_app_under_test

  resolved="$(helper window "$APP_PID" "$kind" ${index:+"$index"} 2>/dev/null)" \
    || fail "no $kind window owned by the app under test (pid $APP_PID)"
  winid="${resolved%% *}"
  owner="${resolved##* }"
  [[ "$winid" =~ ^[0-9]+$ && "$owner" =~ ^[0-9]+$ ]] || deny "window lookup returned garbage"
  # The invariant, re-asserted in the shell: a window whose owner is not the
  # app under test is never captured, whatever the helper thought.
  [[ "$owner" == "$APP_PID" ]] \
    || deny "resolved window $winid is owned by pid $owner, not the app under test ($APP_PID)"

  log_command ALLOW "window=$winid kind=$kind"
  mkdir -p "$STATE_DIR"
  chmod 0700 "$STATE_DIR" 2>/dev/null || true
  # Named per invocation (two concurrent shots must not swap images) and with a
  # .png suffix so screencapture picks the format from it. The EXIT trap owns
  # deletion, so no exit path leaves a window image on disk.
  SHOT_FILE="$STATE_DIR/shot.$$.png"
  file="$SHOT_FILE"
  rm -f "$file"
  screencapture -o -x -l "$winid" "$file" || fail "screencapture failed for window $winid"
  [[ -s "$file" ]] || fail "screencapture produced an empty file (Screen Recording grant?)"
  size="$(wc -c <"$file" | tr -d ' ')"
  if (( size > LV_UI_SHOT_MAX_BYTES )); then
    fail "capture is ${size} bytes, over the ${LV_UI_SHOT_MAX_BYTES} byte cap"
  fi
  printf 'shot: window %s (%s), %s bytes\n' "$winid" "$kind" "$size" >&2
  base64 <"$file"
  ACTION_COMPLETED=1
}

run_ax_dump() {
  local kind="${1:-all}" index="${2:-}"
  case "$kind" in
    all | settings | overlay) [[ -z "$index" ]] || deny "$kind takes no index" ;;
    window) [[ "$index" =~ ^[1-9][0-9]{0,2}$ ]] || deny "window needs an index 1..999" ;;
    *) deny "unknown dump pane" ;;
  esac
  require_unlocked_screen
  require_app_under_test
  log_command ALLOW "pane=$kind${index:+ index=$index}"
  helper axdump "$APP_PID" "$kind" ${index:+"$index"} || fail "AX dump failed"
  ACTION_COMPLETED=1
}

run_ax_click() {
  local selector="$1"
  validate_selector "$selector" || deny "malformed selector"
  require_unlocked_screen
  require_app_under_test
  log_command ALLOW "selector=$selector"
  announce_takeover "clicking in localvoxtral"
  helper axclick "$APP_PID" "$selector" || fail "AX click failed"
  ACTION_COMPLETED=1
}

run_ax_type() {
  local selector="$1" text="$2"
  validate_selector "$selector" || deny "malformed selector"
  validate_typed_text "$text" || deny "malformed text"
  require_unlocked_screen
  require_app_under_test
  log_command ALLOW "selector=$selector"
  announce_takeover "typing into localvoxtral"
  helper axtype "$APP_PID" "$selector" "$text" || fail "AX type failed"
  ACTION_COMPLETED=1
}

run_key() {
  local name="$1"
  case "$name" in
    escape | tab | return) ;;
    *) deny "key not in allowlist" ;;
  esac
  require_unlocked_screen
  require_app_under_test
  log_command ALLOW "key=$name"
  announce_takeover "sending $name to localvoxtral"
  helper key "$APP_PID" "$name" || fail "key event refused (is the app under test frontmost?)"
  ACTION_COMPLETED=1
}

# menu open | menu click <item-title> | menu dismiss
#
# The verb that makes every other verb reachable. localvoxtral opens no window
# at launch, so until the status item is clicked `shot`, `ax dump`, `ax click`,
# `ax type` and `key` all correctly report that there is nothing to address
# (field check, 2026-08-29: `launch` succeeded, `ax dump all` returned `[]`,
# and every UI verb was unusable). Scoped exactly like the others: the pid is
# the one `launch` recorded, and the AX element is that app's own status item.
run_menu_open() {
  require_unlocked_screen
  require_app_under_test
  log_command ALLOW "menu=open pid=$APP_PID"
  announce_takeover "opening the localvoxtral status menu"
  helper menuopen "$APP_PID" || fail "the status menu did not open"
  ACTION_COMPLETED=1
}

run_menu_click() {
  local title="$1"
  validate_menu_title "$title" || deny "malformed menu item title"
  require_unlocked_screen
  require_app_under_test
  log_command ALLOW "menu=click item=$title"
  announce_takeover "clicking $title in the localvoxtral status menu"
  helper menuclick "$APP_PID" "$title" || fail "menu item click failed"
  ACTION_COMPLETED=1
}

# No takeover warning, for the same reason `quit` has none: closing a menu
# takes nothing from the owner — it gives the screen back.
run_menu_dismiss() {
  require_unlocked_screen
  require_app_under_test
  log_command ALLOW "menu=dismiss pid=$APP_PID"
  helper menudismiss "$APP_PID" || fail "could not dismiss the status menu"
  ACTION_COMPLETED=1
}

# dictate tap | dictate hold <seconds> | dictate cancel
#
# The gate exists to debug the Claude Code / herdr session join, and that join
# resolves when a dictation STARTS — but nothing else here can start one.
# `key`'s allowlist is escape/tab/return and the app's trigger is a
# modifier-only GESTURE, so without this verb the thing under test cannot be
# exercised at all.
#
# It posts the app's OWN configured trigger, read from the app's defaults
# rather than hard-coded, at the HID tap — the path scripts/record-demo.sh has
# driven on this machine since the demo recording. The app detects it with an
# NSEvent .flagsChanged monitor and filters nothing, so this is the real
# gesture path, not a side door.
#
# It deliberately does NOT bring localvoxtral frontmost, and that is a
# decision, not an oversight: the modifier trigger is global by design and the
# session grounds its context in whatever IS focused — a terminal running
# Claude Code. Activating localvoxtral first would make every session resolve
# against the wrong surface, which is the exact thing under test. What stands
# in for the frontmost check is stricter about the only real hazard, a stray
# modifier landing in the owner's window: the app must be running AND its
# modifier-only trigger must be enabled in its own settings AND Secure
# Keyboard Entry must not be held; the frontmost app is then named in the
# result and the log so the operator knows where the dictation went.

app_default() { # <key> -> the app's stored value, empty when unset
  defaults read com.localvoxtral.app "$1" 2>/dev/null || true
}

TRIGGER_MODIFIER=""
TRIGGER_HOLD_DELAY=""

# Read, never assume. A guess about which key to press is a modifier posted
# into whatever the owner is doing.
resolve_dictation_trigger() {
  local enabled modifier delay
  enabled="$(app_default settings.modifier_only_hotkey_enabled)"
  [[ -n "$enabled" ]] \
    || deny "cannot read com.localvoxtral.app's trigger settings — refusing to guess which key to press"
  [[ "$enabled" == "1" ]] \
    || deny "the app's modifier-only trigger is disabled (settings.modifier_only_hotkey_enabled=$enabled); this verb does not synthesise the Carbon shortcut path — enable it in Settings"
  modifier="$(app_default settings.modifier_only_hotkey_modifier)"
  case "$modifier" in
    # fn/Globe is supported because it is a configurable trigger, but only
    # right_command has been driven synthetically on this machine
    # (record-demo.sh). If `dictate` reports ok and nothing happens under fn,
    # that is the first thing to suspect.
    fn | right_command | right_option) TRIGGER_MODIFIER="$modifier" ;;
    "") deny "settings.modifier_only_hotkey_modifier is unset — cannot determine the configured trigger" ;;
    *) deny "unrecognised configured trigger: $modifier" ;;
  esac
  delay="$(app_default settings.modifier_only_hold_delay)"
  # Absent means the app's own default, which is a value rather than an
  # identity — unlike the trigger, defaulting it guesses nothing.
  [[ "$delay" =~ ^[0-9]+(\.[0-9]+)?$ ]] || delay="0.35"
  TRIGGER_HOLD_DELAY="$delay"
}

run_dictate() {
  local gesture="$1" seconds="${2:-}"
  require_unlocked_screen
  require_app_under_test

  if [[ "$gesture" == "cancel" ]]; then
    log_command ALLOW "dictate=cancel pid=$APP_PID"
    # Escape only. It gives a session back rather than taking the screen, so
    # like `quit` and `menu dismiss` it does not warn.
    helper dictate "$APP_PID" none cancel || fail "could not post the cancel key"
    ACTION_COMPLETED=1
    return
  fi

  resolve_dictation_trigger
  if [[ "$gesture" == "hold" ]]; then
    [[ "$seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]] || deny "hold needs a duration in seconds"
    # A hold shorter than the app's own threshold is a tap, silently: it would
    # start an Overlay Buffer session while the caller asked for Live
    # Auto-Paste, and nothing would say so.
    awk -v s="$seconds" -v d="$TRIGGER_HOLD_DELAY" -v cap="$LV_UI_MAX_HOLD_SECONDS" \
      'BEGIN { exit !(s > d && s <= cap) }' \
      || deny "hold must be longer than the app's hold delay (${TRIGGER_HOLD_DELAY}s) and at most ${LV_UI_MAX_HOLD_SECONDS}s"
  fi

  log_command ALLOW "dictate=$gesture trigger=$TRIGGER_MODIFIER${seconds:+ seconds=$seconds}"
  announce_takeover "starting a localvoxtral dictation into the focused window"
  helper dictate "$APP_PID" "$TRIGGER_MODIFIER" "$gesture" ${seconds:+"$seconds"} \
    || fail "the trigger gesture was refused"
  ACTION_COMPLETED=1
}

# app <control command>
#
# Forwards ONE line to the dogfood control socket of the app under test and
# prints the reply. This is what makes the join debuggable at all: the socket
# can start a dictation deterministically (the real trigger is a modifier
# gesture) and can resolve the focused surface against the app's LIVE session
# registry, which is per-process and therefore invisible to `--probe-surface`
# or to anything else outside that process.
#
# What keeps it from being a lateral path:
#
#   * The socket path is fixed, not an argument. There is no way to point this
#     verb at another socket on the machine.
#   * The app under test must be a DOGFOOD build. A shipped build compiles no
#     socket at all, so forwarding to one would be a lie; refusing on the
#     recorded stamp says so in one line instead of hanging on a connect.
#   * The forwarded line must be one of the five shapes below. The socket
#     validates its own grammar too — this list exists so the GATE knows which
#     commands take the screen, and so a future socket verb is not
#     automatically reachable through an already-installed gate.
#   * Every token already survived the dispatch charset, so the reassembled
#     line is printable ASCII separated by single spaces, which is exactly what
#     the socket's parser accepts. Nothing here builds a shell command.
#
# Lock policy is per COMMAND, not per verb, because these differ in kind:
# `session start` takes the keyboard and types into whatever is focused, so it
# is refused on a locked screen and warns like `dictate`. `surface probe` reads
# the FOCUSED surface, and behind a lock screen the focused surface is not the
# one the operator is asking about — a truthful answer to the wrong question is
# the worst kind — so it is refused too. The rest are in-process reads (or, for
# `session stop`, a give-back) and are allowed while locked, like `state`.
run_app() {
  local -a parts=("$@")
  local line="${parts[*]}"
  local steals_focus=0 needs_unlocked=0

  case "$line" in
    "session start overlay" | "session start live")
      steals_focus=1
      needs_unlocked=1
      ;;
    # Not a focus steal — a correctness refusal. See above.
    "surface probe") needs_unlocked=1 ;;
    "session stop" | "join report" | "registry list") ;;
    *)
      deny "not a forwardable control command: $line"
      ;;
  esac

  # Lock before anything else the way `term open` does it, so no locked-screen
  # test can pass for an unrelated reason.
  if (( needs_unlocked == 1 )); then
    require_unlocked_screen
  fi
  require_app_under_test
  [[ "$APP_DOGFOOD" == "1" ]] \
    || deny "the app under test is not a dogfood build (launch it with --dogfood); a shipped build has no control socket"
  [[ -S "$LV_UI_CONTROL_SOCKET" ]] \
    || deny "no control socket at $LV_UI_CONTROL_SOCKET — arm it with: defaults write com.localvoxtral.app debug.dogfood_control_socket_enabled -bool true (then relaunch)"

  log_command ALLOW "app=$line pid=$APP_PID"
  if (( steals_focus == 1 )); then
    announce_takeover "starting a localvoxtral dictation into the focused window"
  fi
  helper control "$LV_UI_CONTROL_SOCKET" "$line" || fail "the control socket did not answer"
  ACTION_COMPLETED=1
}

# Masks maximal runs of exactly 43 base64url characters — the remote-enrollment
# token's shape. Deliberately the SAME rule as DogfoodCaptureRedaction (and the
# same trade: it over-matches an isolated 43-character identifier, and misses a
# token glued into a longer run), so a reviewer reading a `<redacted>` here and
# one in a capture record is reading the same decision.
redact_token_shaped_runs() {
  awk '{
    out = ""; run = ""; n = length($0)
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (c ~ /[A-Za-z0-9_-]/) { run = run c }
      else {
        out = out ((length(run) == 43) ? "<redacted>" : run) c
        run = ""
      }
    }
    print out ((length(run) == 43) ? "<redacted>" : run)
  }'
}

# log [minutes]
#
# The app's own unified-log lines, and nothing else on this machine.
#
# Read-only and focus-free, so unlike every actuation verb it is allowed while
# the screen is locked — a diagnostic that only works when the owner is sitting
# there is not a diagnostic for an agent.
#
# Three bounds, each doing a different job:
#   * the PREDICATE scopes to localvoxtral's own subsystem AND to one process.
#     This is a debugging aid on a personal machine, not a system-log reader;
#     every other app's activity stays out of reach and no argument widens it.
#
#     The process half is not tidiness, it is correctness. This Mac is also the
#     self-hosted CI runner, and a unit-suite run logs under localvoxtral's own
#     subsystem from `xctest` — different process, different machine-state,
#     same subsystem. Field check 2026-08-30: `log 2` returned 111 lines of
#     which exactly one was the app under test; the rest were a concurrent
#     xctest run, including "Terminal pane joined to a live Claude session via
#     title marker". Reading that as the join for the dictation you just made
#     is a wrong conclusion drawn from a real log line, which is the worst kind
#     this verb can produce.
#
#     So: with an app under test, the predicate carries `processIdentifier ==
#     <the pid launch recorded>` and the lines are ONE instance's. With none,
#     it falls back to `process == "localvoxtral"` — still never xctest, but no
#     longer one instance — and says so on stderr. Silently answering with
#     another process's lines is the one behaviour that is not available.
#   * the WINDOW is clamped 1..LV_UI_LOG_MAX_MINUTES, mirroring the build
#     gate's `applog`.
#   * the OUTPUT is line-capped and passed through the same token-shaped scrub
#     the dogfood records use. The app writes its categories `privacy: .public`
#     on purpose, but "the app's own lines are safe" is an assumption about
#     every line anyone ever adds, and this is the cheap way not to depend on it.
#
# `log show` is restricted for NON-ADMIN accounts — the build gate's account
# hits exactly that and scripts/mac/README.md records it ("Could not open local
# log store: Operation not permitted"). The UI gate runs as the GUI user, which
# is a different, admin account, so it is expected to work here. It is NOT
# verified as of this writing, so the failure is deliberately loud and
# specific: a diagnostic that returns an empty page when it is actually
# forbidden is worse than one that says it is forbidden.
run_log() {
  local minutes="${1:-$LV_UI_LOG_DEFAULT_MINUTES}" output="" status=0

  [[ "$minutes" =~ ^[0-9]{1,4}$ ]] || deny "log takes a whole number of minutes"
  (( minutes >= 1 )) || deny "log needs at least 1 minute"
  (( minutes <= LV_UI_LOG_MAX_MINUTES )) \
    || deny "log window is clamped to $LV_UI_LOG_MAX_MINUTES minutes"

  # Scope, decided before anything is read. `load_app_state` is the same
  # pid-with-identity check every other verb goes through, so a recycled pid
  # falls back rather than reading a stranger's lines.
  local predicate scope
  if load_app_state; then
    predicate="subsystem == \"$LV_UI_LOG_SUBSYSTEM\" AND processIdentifier == $APP_PID"
    scope="pid=$APP_PID"
  else
    predicate="subsystem == \"$LV_UI_LOG_SUBSYSTEM\" AND process == \"$LV_UI_LOG_PROCESS\""
    scope="process=$LV_UI_LOG_PROCESS not-pid-scoped"
  fi

  log_command ALLOW "log minutes=$minutes subsystem=$LV_UI_LOG_SUBSYSTEM $scope"

  # Said before the lines, not after: an operator who reads the output first
  # and the caveat second has already drawn the conclusion.
  if [[ -z "$APP_PID" ]]; then
    printf 'localvoxtral ui gate: no app under test — these lines are every process named "%s" on this machine, not one instance. Run `launch <artifact>` first to scope them to the build under test.\n' \
      "$LV_UI_LOG_PROCESS" >&2
  fi

  # `|| status=$?` rather than dying under `set -e`: a restricted log store
  # exits non-zero AND prints the reason, and the reason is the whole answer.
  output="$(log show --style compact --info \
    --last "${minutes}m" \
    --predicate "$predicate" 2>&1)" || status=$?

  if (( status != 0 )) || [[ "$output" == *"Could not open local log store"* ]]; then
    printf 'localvoxtral ui gate: log show failed (status %s).\n' "$status" >&2
    printf 'localvoxtral ui gate: %s\n' "$(printf '%s' "${output:0:400}" | tr -c '[:print:]' ' ')" >&2
    printf 'localvoxtral ui gate: if that says "Could not open local log store: Operation not permitted", this account cannot read the unified log — the same restriction scripts/mac/README.md records for the build gate account. No flag lifts it; the alternatives are mac-crashlog.yml on the runner, or the app writing its own file.\n' >&2
    exit 1
  fi

  output="$(printf '%s\n' "$output" | redact_token_shaped_runs)"

  local total capped
  total="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
  capped="$(printf '%s\n' "$output" | tail -n "$LV_UI_LOG_MAX_LINES")"
  printf '%s\n' "$capped"
  if (( total > LV_UI_LOG_MAX_LINES )); then
    printf 'localvoxtral ui gate: %s earlier line(s) dropped by the cap of %s\n' \
      "$(( total - LV_UI_LOG_MAX_LINES ))" "$LV_UI_LOG_MAX_LINES" >&2
  fi
  # Never silently empty: "no matching entries" and "the reader is broken" look
  # identical otherwise, and only one of them is a finding.
  if [[ -z "${capped//[[:space:]]/}" ]]; then
    printf 'localvoxtral ui gate: no %s entries for %s in the last %s minute(s).\n' \
      "$LV_UI_LOG_SUBSYSTEM" "$scope" "$minutes" >&2
  fi
  ACTION_COMPLETED=1
}

# gate-log [lines]
#
# The gate's OWN log — the one file that records why a command was denied.
#
# Why a verb and not a reason on stderr. `deny` answers every refusal with the
# same `denied command` on purpose: a gate that explains itself is an oracle
# for state the caller cannot otherwise see — whether a path exists, whether a
# bundle validated, whether a pid is running, which names a conf allowlists.
# The reason is still written, and it always was; what was missing is that NO
# verb could read it back, so an agent driving over SSH saw the generic line
# and had to go through the owner to learn the one-line fix behind it. That is
# a round trip, not a boundary — so the fix is a bounded reader, and the deny
# contract is untouched.
#
# What this can disclose is exactly what this gate wrote about itself: one
# sanitised, printable, 512-byte-capped line per invocation, `ax type`'s text
# already replaced by `<redacted>` at write time. It is passed through the
# same token-shaped scrub `log` uses, for the same reason — the lines are
# ours, but "every line anyone ever adds is safe" is not worth depending on.
#
# Read-only and focus-free, so it is allowed while the screen is locked: a
# diagnostic that stops working when the owner locks the machine is the one
# case an agent most needs it.
run_gate_log() {
  local lines="${1:-$LV_UI_GATE_LOG_DEFAULT_LINES}" output

  [[ "$lines" =~ ^[0-9]{1,4}$ ]] || deny "gate-log takes a whole number of lines"
  (( lines >= 1 )) || deny "gate-log needs at least 1 line"
  (( lines <= LV_UI_GATE_LOG_MAX_LINES )) \
    || deny "gate-log is clamped to $LV_UI_GATE_LOG_MAX_LINES lines"

  # Logged BEFORE the read, so this invocation is not in its own output and a
  # reader is never confused about which line is the one they are looking for.
  log_command ALLOW "gate-log lines=$lines"

  # The ALLOW line above is this invocation's own; dropping it keeps the
  # requested count meaning "the N entries before this one". It also means the
  # file always exists by the time it is read — `log_command` created it — so
  # an empty answer has exactly one meaning, said below.
  output="$(tail -n $((lines + 1)) "$LOG_FILE" 2>/dev/null | sed '$d' | redact_token_shaped_runs)"
  if [[ -z "${output//[[:space:]]/}" ]]; then
    printf 'localvoxtral ui gate: no entries before this one in %s (this is the first command through this gate).\n' "$LOG_FILE" >&2
    ACTION_COMPLETED=1
    return 0
  fi
  printf '%s\n' "$output"
  ACTION_COMPLETED=1
}

run_quit() {
  require_app_under_test
  log_command ALLOW "pid=$APP_PID"
  kill -TERM "$APP_PID" 2>/dev/null || true
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$APP_PID" 2>/dev/null; then
    kill -KILL "$APP_PID" 2>/dev/null || true
  fi
  rm -f "$APP_STATE"
  ACTION_COMPLETED=1
  printf 'quit pid=%s\n' "$APP_PID"
}

# ---------------------------------------------------------------------------
# Terminal verbs
# ---------------------------------------------------------------------------

terminal_app_name() {
  case "$1" in
    ghostty) printf 'Ghostty\n' ;;
    iterm) printf 'iTerm\n' ;;
    terminal) printf 'Terminal\n' ;;
    *) return 1 ;;
  esac
}

terminal_process_name() {
  case "$1" in
    ghostty) printf 'ghostty\n' ;;
    iterm) printf 'iTerm2\n' ;;
    terminal) printf 'Terminal\n' ;;
    *) return 1 ;;
  esac
}

# An allowlisted NAME -> the absolute path of the file that will run.
resolve_term_command() { # <name> -> absolute path, or non-zero
  local name="$1" dir root candidate
  # A name, never a path: the allowlist matches whole tokens, so `/bin/bash`
  # would not match `bash` anyway, but refusing the shape keeps the allowlist
  # about names and this function about where names live.
  [[ "$name" != */* && "$name" != "." && "$name" != ".." ]] || return 1
  for dir in $LV_UI_TERM_COMMAND_DIRS; do
    root="$(cd "$dir" 2>/dev/null && pwd -P)" || continue
    candidate="$root/$name"
    [[ -f "$candidate" && -x "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

next_term_id() {
  local counter_file="$STATE_DIR/terms/counter" n=0
  mkdir -p "$STATE_DIR/terms"
  [[ -f "$counter_file" ]] && n="$(cat "$counter_file" 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$((n + 1))
  printf '%s\n' "$n" >"$counter_file"
  printf 'term-%s\n' "$n"
}

# term open <terminal> <command> [args...]
#
# The widest surface in this gate, and the reason the command allowlist above
# is deliberately short. The command never reaches a shell as a string: every
# token has already passed token_is_safe, and the launcher script below is
# built with %q quoting, so a token is always one argv element.
# Processes of <procname> that did NOT exist before this gate ran `open -n`.
#
# The partition rides kernel pids, which no launcher gets to choose, so it can
# only ever be conservative: a pid the snapshot already listed is never
# reclaimed, and a pid that appeared since could only have come from the
# instance this gate started (the verb refuses to run twice concurrently for
# the same reason `launch` refuses a second app).
term_instance_pids() { # <procname> <space-separated before-pids>
  local procname="$1" before=" ${2} " pid out=""
  for pid in $(pgrep -x "$procname" 2>/dev/null || true); do
    [[ "$before" == *" $pid "* ]] && continue
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    out+="$pid "
  done
  printf '%s' "${out% }"
}

# Windows this gate SAW but could not prove it opened, written as ordinary
# terminal records carrying `unconfirmed=1`.
#
# The alternative is what shipped before: refuse, say "several windows
# appeared", and leave every one of them unnamed — which on 2026-09-05 meant
# the owner closed them by hand because no verb could address them. A record
# makes `term close` reachable without making `term focus` reachable, and the
# distinction is the point: closing a window the gate may have opened is
# recoverable, raising one in front of what the owner is doing is a takeover
# this gate has not earned.
UNCONFIRMED_TERM_IDS=""
record_unconfirmed_terms() { # <terminal> <ownerpid> <marker> <command> <ids...>
  local terminal="$1" ownerpid="$2" marker="$3" command="$4" ids="$5"
  local winid recorded="" id count=0
  UNCONFIRMED_TERM_IDS=""
  [[ "$ownerpid" =~ ^[1-9][0-9]*$ ]] || return 0
  for winid in $ids; do
    [[ "$winid" =~ ^[1-9][0-9]*$ ]] || continue
    (( count += 1 ))
    (( count <= LV_UI_TERM_MAX_UNCONFIRMED )) || break
    id="$(next_term_id)"
    {
      printf 'terminal=%s\n' "$terminal"
      printf 'pid=%s\n' "$ownerpid"
      printf 'window=%s\n' "$winid"
      printf 'marker=%s\n' "$marker"
      printf 'command=%s\n' "$command"
      printf 'unconfirmed=1\n'
    } >"$STATE_DIR/terms/$id.state"
    recorded+="$id "
  done
  UNCONFIRMED_TERM_IDS="${recorded% }"
  [[ -n "$UNCONFIRMED_TERM_IDS" ]] || UNCONFIRMED_TERM_IDS="none"
}

run_term_open() {
  local terminal="$1"
  shift
  local -a argv=("$@")
  # Lock first, like every other GUI-touching verb: on a locked screen this
  # denies before any argument is even considered, so no locked-screen test can
  # pass for an argument-validation reason.
  require_unlocked_screen
  list_contains "$terminal" "$LV_UI_TERMINALS" || deny "terminal not allowlisted"
  (( ${#argv[@]} >= 1 )) || deny "term open needs a command"
  (( ${#argv[@]} <= LV_UI_MAX_TERM_ARGS )) || deny "term open takes at most $LV_UI_MAX_TERM_ARGS tokens"
  # The denylist is checked FIRST and cannot be overridden by the conf file, so
  # allowlisting a shell or an agent CLI by mistake still denies.
  if list_contains "${argv[0]}" "$LV_UI_TERM_FORBIDDEN"; then
    deny "command can run a child command and is permanently refused: ${argv[0]}"
  fi
  if [[ -z "${LV_UI_TERM_COMMANDS// /}" ]]; then
    deny "term open has no allowlisted commands (the default is empty — see scripts/mac/README.md)"
  fi
  list_contains "${argv[0]}" "$LV_UI_TERM_COMMANDS" || deny "command not allowlisted: ${argv[0]}"
  local token
  for token in "${argv[@]}"; do
    token_is_safe "$token" || deny "unsafe token in term command"
  done

  # Bash 3.2 (the Mac's /bin/bash) errors on an EMPTY array slice under set -u,
  # so the arguments after the command name are rendered once, guarded, rather
  # than expanded at each use.
  local args_text=""
  if (( ${#argv[@]} > 1 )); then
    args_text=" ${argv[*]:1}"
  fi

  # Resolved BEFORE anything is opened. An allowlisted name that is not
  # installed used to open an empty window and then fail with a window-identity
  # message; this refuses with nothing opened and names the real problem.
  local resolved_command
  resolved_command="$(resolve_term_command "${argv[0]}")" \
    || deny "${argv[0]} is allowlisted but is not an executable file in $LV_UI_TERM_COMMAND_DIRS — nothing was opened (install it: scripts/mac/install-ui-artifact.sh, or see \`state\`'s setup.term_open.unresolvable)"

  # Logged IN FULL: this is the one verb that carries a command line.
  log_command ALLOW "terminal=$terminal command=${argv[*]} resolved=$resolved_command"

  local id marker script app procname pidfile ackfile ack_polls
  id="$(next_term_id)"
  marker="lvui-$id-$RANDOM$RANDOM"
  app="$(terminal_app_name "$terminal")"
  procname="$(terminal_process_name "$terminal")"
  mkdir -p "$STATE_DIR/terms"
  script="$STATE_DIR/terms/$marker.command"
  pidfile="$STATE_DIR/terms/$marker.pid"
  ackfile="$STATE_DIR/terms/$marker.ack"
  rm -f "$ackfile"
  # Two seconds past the gate's own deadline, in 100 ms steps: the launcher
  # must outlive the poll that is looking for it, and then stop waiting.
  ack_polls=$(( (LV_UI_TERM_OPEN_TIMEOUT_SECONDS + 2) * 10 ))
  {
    printf '#!/bin/sh\n'
    # `exec` keeps this pid, so the file names the process that ends up running
    # the command inside the window. It is the ONLY handle on that process once
    # the command has replaced this shell, and it is what lets a `term open`
    # that cannot identify its window still take back what it started instead
    # of leaving it on the owner's desktop.
    printf 'printf %%s "$$" > %q\n' "$pidfile"
    # OSC 0 title. A TIE-BREAKER, not the identity — see the snapshot below.
    printf 'printf %s "%s"\n' "'\\033]0;%s\\007'" "$marker"
    # HOLD THE TITLE UNTIL THE GATE HAS READ IT.
    #
    # This is what makes the tie-breaker deterministic instead of a race. The
    # command this verb exists to run is a whole-view herdr client, and herdr
    # owns the terminal title from its first painted frame — so the marker used
    # to survive only for as long as `open` plus an ssh handshake happened to
    # take, and any poll that arrived after herdr painted saw an untagged
    # window. Waiting here costs nothing when the gate is watching (it acks the
    # moment it resolves a window) and fails OPEN after the bound above, which
    # is exactly the pre-handshake behaviour.
    #
    # The ack path is inside the gate's own 0700 state dir and is only ever
    # tested for existence, so nothing the launcher reads can carry content.
    printf 'lvui_i=0\n'
    printf 'while [ ! -e %q ] && [ "$lvui_i" -lt %s ]; do\n' "$ackfile" "$ack_polls"
    printf '  sleep 0.1\n'
    printf '  lvui_i=$((lvui_i + 1))\n'
    printf 'done\n'
    # The ABSOLUTE path, not the name: PATH is not this launcher's to rely on.
    printf 'exec %q' "$resolved_command"
    if (( ${#argv[@]} > 1 )); then
      printf ' %q' "${argv[@]:1}"
    fi
    printf '\n'
  } >"$script"
  chmod 0700 "$script"

  # WHY A SNAPSHOT AND NOT THE TITLE MARKER (field failure 2026-08-30).
  #
  # The marker used to be the identity: the launcher printed it as an OSC 0
  # title and the gate polled for a window carrying it. That cannot work for
  # the one command this verb exists to run. `lv-attach` execs a whole-view
  # herdr client, and herdr owns the terminal title from the moment it starts
  # — docs/agent/invariants.md states it outright ("herdr intercepts OSC 2 per
  # pane, so a title marker can neither reach nor come back from a
  # herdr-hosted session"), which is also why the app's own titleMarker join
  # arm is suppressed there. The marker was overwritten before the poll could
  # see it, so `term open` reported failure while a real window sat on the
  # owner's screen that `term focus`/`term close` could never address.
  #
  # A window that is NEW since a snapshot taken immediately before `open`
  # needs no cooperation from the child process at all, so nothing the command
  # does to its title can hide it.
  local before_pids before_ids
  before_pids="$(pgrep -x "$procname" 2>/dev/null | tr '\n' ' ' || true)"
  # shellcheck disable=SC2086
  before_ids="$(helper termsnapshot $before_pids 2>/dev/null || true)"
  [[ -n "$before_ids" ]] || before_ids="-"

  # WHY ONLY GHOSTTY SPAWNS AN INSTANCE, AND WHY THAT MATTERS.
  #
  # `--args` are delivered to an application only when `open` LAUNCHES it, so
  # the one branch that has to pass `-e <script>` also has to pass `-n`, which
  # forces a brand-new instance. The other terminals take the launcher as a
  # DOCUMENT and reuse whatever is already running.
  #
  # A brand-new instance runs the whole macOS launch path, state restoration
  # included: Ghostty's `window-save-state` defaults to `default`, documented
  # as "the default system behavior… only save state if the application is
  # forcibly terminated or if it is configured systemwide via Settings.app",
  # and implemented as the `NSQuitAlwaysKeepsWindows` default. With the
  # systemwide "Close windows when quitting an application" unchecked, the new
  # instance recreates the app's saved window set ALONGSIDE the `-e` window.
  # Field failure 2026-09-05: `term open ghostty lv-attach` reported "several
  # windows appeared at once" twice in a row and left the extra windows on the
  # owner's desktop, unaddressable, because the gate had recorded no id for
  # them. `term open terminal lv-attach` — same moment, same machine, no `-n` —
  # opened exactly one window and bound it.
  #
  # This gate deliberately does NOT try to turn restoration off. Both ways of
  # doing that are worse than the problem: `--window-save-state=never` writes
  # `NSQuitAlwaysKeepsWindows` into the OWNER's persistent Ghostty defaults and
  # would silently disable his own window restoration, and an AppKit argument-
  # domain override (`--args -NSQuitAlwaysKeepsWindows NO`) has to survive
  # Ghostty's own argument parser, which is not this gate's to assume. Instead:
  # the marker handshake above makes the right window identifiable however many
  # appear, and the reclaim below makes every window of an instance THIS GATE
  # started the gate's to take back.
  local spawned_instance=0
  announce_takeover "opening a $terminal window"
  case "$terminal" in
    ghostty)
      spawned_instance=1
      open -n -a "$app" --args -e "$script" || fail "could not open $app"
      ;;
    *) open -a "$app" "$script" || fail "could not open $app" ;;
  esac

  local pid deadline resolved status winid owner="" ambiguous=0 ambiguous_ids=""
  deadline=$((SECONDS + LV_UI_TERM_OPEN_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    pid="$(pgrep -n -x "$procname" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      status=0
      resolved="$(helper termnew "$pid" "$marker" "$before_ids" 2>/dev/null)" || status=$?
      if (( status == 0 )) && [[ "$resolved" == ok\ * ]]; then
        resolved="${resolved#ok }"
        winid="${resolved%% *}"
        owner="${resolved##* }"
        break
      fi
      # Several windows appeared at once and none carries the marker. The
      # marker is HELD by the launcher until this gate acks it, so reaching
      # here means the tag never rendered at all rather than that we polled a
      # moment too late — waiting longer still cannot make it less ambiguous.
      # The ids are kept: whatever happens next, the caller must be able to
      # take back what was opened.
      if (( status == 2 )); then
        ambiguous=1
        # `ambiguous <ownerpid> <winid>...` — drop the verb AND the owner pid,
        # which is already in `$pid`; leaving it in would record a window whose
        # id is a process id.
        if [[ "$resolved" == ambiguous\ * ]]; then
          ambiguous_ids="${resolved#ambiguous }"
          ambiguous_ids="${ambiguous_ids#* }"
        fi
        break
      fi
    fi
    sleep 0.5
  done

  # Released here, on EVERY path out of the poll: the launcher must not sit on
  # its title after this gate has stopped looking, and a failure path is about
  # to terminate it anyway.
  : >"$ackfile" 2>/dev/null || true

  if [[ -z "$owner" ]]; then
    # THREE different faults live here and they have completely different
    # fixes, so they get three different sentences. Reporting a command that
    # never ran as a window-identification timeout is what sent the last
    # investigation down the wrong path entirely.
    #
    # The launcher writes its pid before `exec`, so the pid file separates
    # them: absent means the terminal never ran the launcher at all; present
    # with a dead process means the command ran and exited immediately (an
    # empty window is exactly what that looks like); present and alive means
    # the command is running and only the WINDOW could not be identified.
    local orphan="" reclaimed="nothing was left running"
    [[ -f "$pidfile" ]] && orphan="$(cat "$pidfile" 2>/dev/null || true)"
    local launcher_ran=0 still_running=0
    [[ "$orphan" =~ ^[1-9][0-9]*$ ]] && launcher_ran=1
    if (( launcher_ran == 1 )) && kill -0 "$orphan" 2>/dev/null; then
      still_running=1
      # A term open that cannot confirm what it started must not leave a window
      # on the owner's desktop. The pid is the only handle on it once the
      # window is unidentifiable.
      kill -TERM "$orphan" 2>/dev/null || true
      reclaimed="terminated the command it started (pid $orphan); in Ghostty the window closes with it, in Terminal/iTerm it stays showing a finished command"
    fi

    # Killing the launcher closes ONE window. When this gate spawned the whole
    # instance, every window that instance put on screen is the gate's — the
    # `-e` one and any macOS restored alongside it — and the pid partition
    # proves it: a process of this name that was not in the pre-open snapshot
    # cannot be one the owner was already using. So the reclaim is the whole
    # instance, which is the only thing that makes "nothing was left behind"
    # true for the branch that duplicates windows.
    local spawned_pids=""
    if (( spawned_instance == 1 )); then
      spawned_pids="$(term_instance_pids "$procname" "$before_pids")"
      if [[ -n "$spawned_pids" ]]; then
        local spawned_pid
        for spawned_pid in $spawned_pids; do
          kill -TERM "$spawned_pid" 2>/dev/null || true
        done
        reclaimed="terminated the $app instance it started (pid $spawned_pids), closing every window that instance opened"
      fi
    elif (( ambiguous == 1 )) && [[ -n "$ambiguous_ids" ]]; then
      # A REUSED instance's extra windows may be the owner's, so they are not
      # killed — but the ones this gate saw are recorded, unconfirmed, so
      # `term close` can still reach a window it may have opened. `term focus`
      # refuses an unconfirmed record: raising a window is a takeover of
      # whatever the owner is doing, and this gate does not know whose it is.
      record_unconfirmed_terms "$terminal" "$pid" "$marker" "${argv[*]}" "$ambiguous_ids"
    fi
    rm -f "$script" "$pidfile" "$ackfile"

    if (( launcher_ran == 0 )); then
      fail "$app opened but never ran the launcher, so ${argv[0]} was never executed — $reclaimed. This is not a window-identification problem: check that $app accepts the launcher ($script was removed; re-run to regenerate it)."
    fi
    if (( still_running == 0 )); then
      fail "${argv[0]} ran and exited immediately, which is what an empty terminal window means — $reclaimed. This is the COMMAND failing, not the window being unidentifiable: run it by hand as this user ($resolved_command$args_text) and read its error."
    fi
    if (( ambiguous == 1 )); then
      if (( spawned_instance == 1 )); then
        fail "$app opened, ${argv[0]} is running, but several windows appeared at once so this cannot tell which one it opened — $reclaimed, so nothing was left on the desktop. Re-run without opening a terminal window yourself at the same moment."
      fi
      fail "$app opened, ${argv[0]} is running, but several windows appeared at once so this cannot tell which one it opened — $reclaimed. The windows it saw are recorded UNCONFIRMED as $UNCONFIRMED_TERM_IDS: \`term close <id>\` can reach them, \`term focus\` will not (this gate cannot prove they are its own). Re-run without opening a terminal window yourself at the same moment."
    fi
    fail "$app opened and ${argv[0]} is running, but no new window appeared within $LV_UI_TERM_OPEN_TIMEOUT_SECONDS seconds — $reclaimed"
  fi

  {
    printf 'terminal=%s\n' "$terminal"
    printf 'pid=%s\n' "$owner"
    printf 'window=%s\n' "$winid"
    printf 'marker=%s\n' "$marker"
    printf 'command=%s\n' "${argv[*]}"
  } >"$STATE_DIR/terms/$id.state"

  ACTION_COMPLETED=1
  printf 'opened %s terminal=%s pid=%s window=%s\n' "$id" "$terminal" "$owner" "$winid"
}

load_term_state() { # <id>
  local id="$1" file
  [[ "$id" =~ ^term-[0-9]+$ ]] || deny "malformed terminal id"
  file="$STATE_DIR/terms/$id.state"
  [[ -f "$file" ]] || deny "unknown terminal id $id — this gate did not open it"
  TERM_PID="$(sed -n 's/^pid=//p' "$file" | head -n 1)"
  TERM_MARKER="$(sed -n 's/^marker=//p' "$file" | head -n 1)"
  TERM_WINDOW="$(sed -n 's/^window=//p' "$file" | head -n 1)"
  TERM_KIND="$(sed -n 's/^terminal=//p' "$file" | head -n 1)"
  TERM_UNCONFIRMED=0
  [[ "$(sed -n 's/^unconfirmed=//p' "$file" | head -n 1)" == "1" ]] && TERM_UNCONFIRMED=1
  # ^[1-9] on purpose: `kill -0 0` signals the whole process group and always
  # succeeds, so pid 0 would read as a live terminal.
  [[ "$TERM_PID" =~ ^[1-9][0-9]*$ && "$TERM_WINDOW" =~ ^[1-9][0-9]*$ ]] \
    || deny "corrupt terminal state for $id"
  kill -0 "$TERM_PID" 2>/dev/null || deny "$id's terminal process is gone"
}

run_term_focus() {
  local id="$1"
  require_unlocked_screen
  load_term_state "$id"
  # An unconfirmed record names a window that appeared at the same instant as
  # the one this gate opened, in an instance it did NOT start. Closing one is
  # recoverable; raising one in front of the owner is a takeover of a window
  # that may be his.
  (( TERM_UNCONFIRMED == 0 )) \
    || deny "$id is an UNCONFIRMED window — this gate saw it but cannot prove it opened it, so it may be focused but never raised; \`term close $id\` is available"
  log_command ALLOW "id=$id pid=$TERM_PID"
  announce_takeover "focusing $TERM_KIND window $id"
  helper termaction "$TERM_PID" "$TERM_WINDOW" focus || fail "could not focus $id"
  ACTION_COMPLETED=1
  printf 'focused %s\n' "$id"
}

run_term_close() {
  local id="$1"
  require_unlocked_screen
  load_term_state "$id"
  log_command ALLOW "id=$id pid=$TERM_PID"
  helper termaction "$TERM_PID" "$TERM_WINDOW" close || fail "could not close $id"
  rm -f "$STATE_DIR/terms/$id.state" \
    "$STATE_DIR/terms/$TERM_MARKER.command" "$STATE_DIR/terms/$TERM_MARKER.pid" \
    "$STATE_DIR/terms/$TERM_MARKER.ack"
  ACTION_COMPLETED=1
  printf 'closed %s\n' "$id"
}

# ---------------------------------------------------------------------------
# Dispatch — deny by default
# ---------------------------------------------------------------------------

# There is deliberately no "source only" escape hatch here (the build gate has
# one): test-ui-gate.sh executes this script for real against PATH stubs, so
# nothing needs to suppress dispatch — and an environment variable that turns
# the gate into a no-op is attack surface with no user.
#
# Reject the whole command before it is split: no newlines (only the first
# line would ever be parsed), no control characters, bounded length.
[[ -n "$original_command" ]] || deny "empty command"
(( ${#original_command} <= LV_UI_MAX_COMMAND_BYTES )) || deny "command too long"
[[ "$original_command" =~ ^[[:print:]]+$ ]] || deny "non-printable byte in command"

read -r -a ARGV <<<"$original_command"
(( ${#ARGV[@]} >= 1 )) || deny "empty command"

# Every token except `ax type`'s free text must survive the charset. The text
# is validated separately (validate_typed_text) because API keys and URLs need
# characters no other verb may carry.
if [[ "${ARGV[0]} ${ARGV[1]:-}" != "ax type" ]]; then
  for token in "${ARGV[@]}"; do
    token_is_safe "$token" || deny "unsafe token: $token"
  done
fi

case "${ARGV[0]}" in
  state)
    (( ${#ARGV[@]} == 1 )) || deny "state takes no arguments"
    log_command ALLOW
    run_state
    ;;
  launch)
    (( ${#ARGV[@]} >= 2 )) || deny "launch needs an artifact"
    run_launch "${ARGV[@]:1}"
    ;;
  shot)
    # Bash 3.2 (the Mac's /bin/bash) treats an empty "${a[@]:1}" as unbound
    # under set -u, so the no-argument form is dispatched explicitly.
    (( ${#ARGV[@]} <= 3 )) || deny "too many arguments for shot"
    if (( ${#ARGV[@]} == 1 )); then run_shot; else run_shot "${ARGV[@]:1}"; fi
    ;;
  key)
    (( ${#ARGV[@]} == 2 )) || deny "key takes exactly one name"
    run_key "${ARGV[1]}"
    ;;
  quit)
    (( ${#ARGV[@]} == 1 )) || deny "quit takes no arguments"
    run_quit
    ;;
  app)
    # Bounded here as well as in run_app: the forwardable shapes are two or
    # three tokens, so anything longer is refused before it is even joined
    # into a line.
    (( ${#ARGV[@]} >= 3 && ${#ARGV[@]} <= 4 )) \
      || deny "app takes a control command of two or three tokens"
    run_app "${ARGV[@]:1}"
    ;;
  log)
    (( ${#ARGV[@]} <= 2 )) || deny "log takes at most a number of minutes"
    if (( ${#ARGV[@]} == 1 )); then run_log; else run_log "${ARGV[1]}"; fi
    ;;
  gate-log)
    (( ${#ARGV[@]} <= 2 )) || deny "gate-log takes at most a number of lines"
    if (( ${#ARGV[@]} == 1 )); then run_gate_log; else run_gate_log "${ARGV[1]}"; fi
    ;;
  dictate)
    case "${ARGV[1]:-}" in
      tap | cancel)
        (( ${#ARGV[@]} == 2 )) || deny "dictate ${ARGV[1]} takes no arguments"
        run_dictate "${ARGV[1]}"
        ;;
      hold)
        (( ${#ARGV[@]} == 3 )) || deny "dictate hold takes exactly one duration in seconds"
        run_dictate hold "${ARGV[2]}"
        ;;
      *)
        deny "unknown dictate subverb"
        ;;
    esac
    ;;
  menu)
    case "${ARGV[1]:-}" in
      open)
        (( ${#ARGV[@]} == 2 )) || deny "menu open takes no arguments"
        run_menu_open
        ;;
      click)
        (( ${#ARGV[@]} == 3 )) || deny "menu click takes exactly one item title"
        run_menu_click "${ARGV[2]}"
        ;;
      dismiss)
        (( ${#ARGV[@]} == 2 )) || deny "menu dismiss takes no arguments"
        run_menu_dismiss
        ;;
      *)
        deny "unknown menu subverb"
        ;;
    esac
    ;;
  ax)
    case "${ARGV[1]:-}" in
      dump)
        (( ${#ARGV[@]} <= 4 )) || deny "too many arguments for ax dump"
        if (( ${#ARGV[@]} == 2 )); then run_ax_dump; else run_ax_dump "${ARGV[@]:2}"; fi
        ;;
      click)
        (( ${#ARGV[@]} == 3 )) || deny "ax click takes exactly one selector"
        run_ax_click "${ARGV[2]}"
        ;;
      type)
        # `ax type <selector> -- <text>`: the separator is mandatory so the
        # selector can never absorb text, or the text a selector.
        (( ${#ARGV[@]} >= 5 )) || deny "ax type needs a selector, --, and text"
        [[ "${ARGV[3]}" == "--" ]] || deny "ax type needs -- before the text"
        token_is_safe "${ARGV[2]}" || deny "unsafe selector token"
        [[ "$original_command" == *" -- "* ]] || deny "ax type needs -- before the text"
        run_ax_type "${ARGV[2]}" "${original_command#* -- }"
        ;;
      *)
        deny "unknown ax subverb"
        ;;
    esac
    ;;
  term)
    case "${ARGV[1]:-}" in
      open)
        (( ${#ARGV[@]} >= 4 )) || deny "term open needs a terminal and a command"
        run_term_open "${ARGV[@]:2}"
        ;;
      focus)
        (( ${#ARGV[@]} == 3 )) || deny "term focus takes exactly one id"
        run_term_focus "${ARGV[2]}"
        ;;
      close)
        (( ${#ARGV[@]} == 3 )) || deny "term close takes exactly one id"
        run_term_close "${ARGV[2]}"
        ;;
      *)
        deny "unknown term subverb"
        ;;
    esac
    ;;
  *)
    deny
    ;;
esac
