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
# with an allowlisted binary, must survive the same metacharacter blocklist as
# every other token, and is logged IN FULL. Adding a verb that can run
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
#     is not that pid. It can never photograph another application.
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
#   - `dictate` posts the app's OWN configured trigger — read from the app's
#     defaults, never hard-coded — as a modifier-only gesture at the HID tap.
#     It is the one verb that does not target a window, because the trigger is
#     global by design and the dictation grounds itself in whatever is FOCUSED;
#     activating localvoxtral first would defeat the thing under test. It
#     refuses unless the app is running, its modifier trigger is enabled in its
#     own settings, and Secure Keyboard Entry is not held.
#   - `term focus` / `term close` act only on a window this gate opened,
#     identified by a random marker it put in that window's title.
#   - `app` forwards ONE line to the control socket of the app under test —
#     never a shell, never a path of the caller's choosing. The socket only
#     exists in a dogfood build, so the verb refuses unless `launch --dogfood`
#     recorded one, and the forwarded line must be one of the five shapes the
#     socket's own grammar accepts. The socket answers in a closed vocabulary
#     of bools, counts and enum names (docs/dogfood-builds.md).
#   - `log` reads the unified log for localvoxtral's OWN subsystem only, over a
#     clamped window, with a line cap and token-shaped runs masked. It is not a
#     general system-log reader; every other application's activity on this
#     machine stays out of reach.
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
# `ax dump`, `menu dismiss`, `dictate cancel`, `quit` and `term close` do not
# warn: none of them takes the keyboard or raises a window in front of what the
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

# Machine-local overrides (never committed). Same argument as the build gate:
# anyone who can write this file can already replace this script, so sourcing
# it adds no new trust.
GATE_CONF="${LV_UI_GATE_CONF:-$HOME/.localvoxtral-ui-gate.conf}"
if [[ -f "$GATE_CONF" ]]; then
  # shellcheck source=/dev/null
  source "$GATE_CONF"
fi

# Second layer under the (empty by default) allowlist above: names that can run
# a child command are refused even when the conf allowlists them. Deliberately
# assigned AFTER the conf is sourced and NOT via ${VAR:-...}, so the conf can
# widen the allowlist but can never re-add one of these. A blocklist is a poor
# primary defence, which is why it is not the primary defence — it is here so
# that a mistake in a machine-local file fails loudly instead of silently.
LV_UI_TERM_FORBIDDEN="bash sh zsh ksh csh tcsh fish dash ssh scp sftp telnet \
osascript applescript python python2 python3 perl ruby node deno bun php lua \
env xargs find sudo doas su nohup script screen tmux herdr expect make just \
claude codex opencode aider goose amp cursor-agent gemini ollama"

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
//   termwindow <ownerpid> <marker>                           -> "<winid> <ownerpid>"
//   termaction <ownerpid> <marker> <focus|close>

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
        out.append(CGWindowRecord(id: id, ownerPID: owner, layer: layer, area: width * height, title: title))
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

func openMenu(of item: AXUIElement) -> AXUIElement? {
    for child in (copyAttr(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    where str(child, kAXRoleAttribute) == "AXMenu" {
        return child
    }
    return nil
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
    let item = extrasMenuBarItem(requirePID(argv[1]))
    if openMenu(of: item) != nil {
        print("ok already-open")
        break
    }
    _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
    // The press's own status is not the answer — it reports .cannotComplete
    // while the menu tracks. The menu's existence is the answer.
    let menuDeadline = Date().addingTimeInterval(3)
    while Date() < menuDeadline {
        if openMenu(of: item) != nil {
            print("ok")
            exit(0)
        }
        usleep(150_000)
    }
    die("the status item was pressed but no menu opened")

case "menuclick":
    guard argv.count >= 3 else { die("usage: menuclick <pid> <item-title>") }
    let wanted = argv[2].replacingOccurrences(of: "+", with: " ")
    guard let menu = openMenu(of: extrasMenuBarItem(requirePID(argv[1]))) else {
        die("no status menu is open — run `menu open` first")
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
    let dismissItem = extrasMenuBarItem(requirePID(argv[1]))
    guard let openMenuElement = openMenu(of: dismissItem) else {
        print("ok no-menu-open")
        break
    }
    // AXCancel on the app's own menu, not a synthesised Escape: a keystroke
    // goes to whatever owns the keyboard, and closing a menu never has to.
    if AXUIElementPerformAction(openMenuElement, kAXCancelAction as CFString) == .success {
        print("ok")
        break
    }
    // Fall back to toggling the status item shut — still the app's own element.
    _ = AXUIElementPerformAction(dismissItem, kAXPressAction as CFString)
    print("ok")

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

case "termwindow":
    guard argv.count >= 3 else { die("usage: termwindow <ownerpid> <marker>") }
    let pid = Int(requirePID(argv[1]))
    let marker = argv[2]
    guard let record = cgWindows(ownedBy: pid).first(where: { $0.title.contains(marker) }) else {
        die("no window of pid \(pid) carries marker \(marker)")
    }
    print("\(record.id) \(record.ownerPID)")

case "termaction":
    guard argv.count >= 4 else { die("usage: termaction <ownerpid> <marker> <focus|close>") }
    let pid = requirePID(argv[1])
    let marker = argv[2]
    // The marker in the title is the proof that THIS gate opened the window;
    // a window without it is never touched.
    guard let window = windowsOf(pid).first(where: { str($0, kAXTitleAttribute).contains(marker) }) else {
        die("no AX window of pid \(pid) carries marker \(marker)")
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
  resolved="$(cd "$argument" 2>/dev/null && pwd -P)" || return 1
  for root in $LV_UI_ARTIFACT_ROOTS; do
    root="$(cd "$root" 2>/dev/null && pwd -P)" || continue
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
  local file id term marker pid
  for file in "$STATE_DIR"/terms/*.state; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"
    id="${id%.state}"
    term="$(sed -n 's/^terminal=//p' "$file" | head -n 1)"
    marker="$(sed -n 's/^marker=//p' "$file" | head -n 1)"
    pid="$(sed -n 's/^pid=//p' "$file" | head -n 1)"
    [[ -n "$terminals" ]] && terminals+=","
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || pid=0
    terminals+="{\"id\":$(json_string "$id"),\"terminal\":$(json_string "$term"),\"pid\":$pid,\"alive\":$( (( pid > 0 )) && kill -0 "$pid" 2>/dev/null && echo true || echo false),\"marker\":$(json_string "$marker")}"
  done

  printf '{"screen_lock":%s,"idle_seconds":%s,"power":%s,"tcc":{"accessibility":%s,"screen_recording":%s},"app":%s,"terminals":[%s]}\n' \
    "$(json_string "$lock")" "$idle" "$(json_string "$power")" \
    "$accessibility" "$screen_recording" "$running_json" "$terminals"
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

  deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    pid="$(pgrep -n -f "^$bundle/Contents/MacOS/localvoxtral" 2>/dev/null || true)"
    [[ -n "$pid" ]] && break
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
#   * the PREDICATE scopes to localvoxtral's own subsystem. This is a debugging
#     aid on a personal machine, not a system-log reader; every other app's
#     activity stays out of reach and no argument widens it.
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

  log_command ALLOW "log minutes=$minutes subsystem=$LV_UI_LOG_SUBSYSTEM"

  # `|| status=$?` rather than dying under `set -e`: a restricted log store
  # exits non-zero AND prints the reason, and the reason is the whole answer.
  output="$(log show --style compact --info \
    --last "${minutes}m" \
    --predicate "subsystem == \"$LV_UI_LOG_SUBSYSTEM\"" 2>&1)" || status=$?

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
    printf 'localvoxtral ui gate: no %s entries in the last %s minute(s).\n' \
      "$LV_UI_LOG_SUBSYSTEM" "$minutes" >&2
  fi
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

  # Logged IN FULL: this is the one verb that carries a command line.
  log_command ALLOW "terminal=$terminal command=${argv[*]}"

  local id marker script app
  id="$(next_term_id)"
  marker="lvui-$id-$RANDOM$RANDOM"
  app="$(terminal_app_name "$terminal")"
  mkdir -p "$STATE_DIR/terms"
  script="$STATE_DIR/terms/$marker.command"
  {
    printf '#!/bin/sh\n'
    # OSC 0 title: how focus/close later prove this window is ours. Terminal
    # and iTerm also show the script's file name, which carries the marker.
    printf 'printf %s "%s"\n' "'\\033]0;%s\\007'" "$marker"
    printf 'exec'
    printf ' %q' "${argv[@]}"
    printf '\n'
  } >"$script"
  chmod 0700 "$script"

  announce_takeover "opening a $terminal window"
  case "$terminal" in
    ghostty) open -n -a "$app" --args -e "$script" || fail "could not open $app" ;;
    *) open -a "$app" "$script" || fail "could not open $app" ;;
  esac

  local pid deadline resolved winid owner=""
  deadline=$((SECONDS + 20))
  while (( SECONDS < deadline )); do
    pid="$(pgrep -n -x "$(terminal_process_name "$terminal")" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      resolved="$(helper termwindow "$pid" "$marker" 2>/dev/null || true)"
      if [[ -n "$resolved" ]]; then
        winid="${resolved%% *}"
        owner="${resolved##* }"
        break
      fi
    fi
    sleep 0.5
  done
  if [[ -z "$owner" ]]; then
    fail "opened $app but never saw a window carrying marker $marker"
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
  TERM_KIND="$(sed -n 's/^terminal=//p' "$file" | head -n 1)"
  # ^[1-9] on purpose: `kill -0 0` signals the whole process group and always
  # succeeds, so pid 0 would read as a live terminal.
  [[ "$TERM_PID" =~ ^[1-9][0-9]*$ && -n "$TERM_MARKER" ]] || deny "corrupt terminal state for $id"
  kill -0 "$TERM_PID" 2>/dev/null || deny "$id's terminal process is gone"
}

run_term_focus() {
  local id="$1"
  require_unlocked_screen
  load_term_state "$id"
  log_command ALLOW "id=$id pid=$TERM_PID"
  announce_takeover "focusing $TERM_KIND window $id"
  helper termaction "$TERM_PID" "$TERM_MARKER" focus || fail "could not focus $id"
  ACTION_COMPLETED=1
  printf 'focused %s\n' "$id"
}

run_term_close() {
  local id="$1"
  require_unlocked_screen
  load_term_state "$id"
  log_command ALLOW "id=$id pid=$TERM_PID"
  helper termaction "$TERM_PID" "$TERM_MARKER" close || fail "could not close $id"
  rm -f "$STATE_DIR/terms/$id.state" "$STATE_DIR/terms/$TERM_MARKER.command"
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
