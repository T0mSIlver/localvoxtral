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
#   - `term focus` / `term close` act only on a window this gate opened,
#     identified by a random marker it put in that window's title.
#
# It refuses everything GUI-touching while the screen is locked (shared probe:
# scripts/ci/screen-lock-state.sh, fail CLOSED here), and honours the owner's
# takeover rule: any verb that steals focus (launch, ax click, ax type, key,
# term open, term focus) speaks a warning, waits, and announces completion.
# `state`, `shot`, `ax dump`, `quit` and `term close` do not warn: none of them
# takes the keyboard or raises a window in front of what the owner is doing.
#
# Verbs (each documented at its run_* function):
#   state
#   launch [--dogfood] <artifact>
#   shot [settings|popover|overlay|window <n>]
#   ax dump [settings|overlay|window <n>]
#   ax click <selector>
#   ax type <selector> -- <text>
#   key <escape|tab|return>
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

# `term open`'s allowlists. The command allowlist is the ONLY thing standing
# between this verb and a shell verb, so it holds first tokens only, and an
# entry that is itself a shell (bash, sh, zsh, ssh, osascript, python) or that
# takes an arbitrary child command (`claude --dangerously-skip-permissions`)
# hands the whole boundary away. Keep it to non-shell tools.
LV_UI_TERMINALS="${LV_UI_TERMINALS:-ghostty iterm terminal}"
LV_UI_TERM_COMMANDS="${LV_UI_TERM_COMMANDS:-herdr claude opencode codex}"
LV_UI_MAX_TERM_ARGS="${LV_UI_MAX_TERM_ARGS:-12}"

# Owner rule (2026-07-09): warn audibly and wait before stealing focus, and
# announce completion. Set to 0 in the conf file only if you are sitting in
# front of the machine — the default is the rule as stated.
LV_UI_WARN_SLEEP_SECONDS="${LV_UI_WARN_SLEEP_SECONDS:-3}"

# A window PNG is a few hundred KB; the cap exists so a pathological capture
# cannot dump tens of MB into an agent transcript.
LV_UI_SHOT_MAX_BYTES="${LV_UI_SHOT_MAX_BYTES:-8388608}"

LV_UI_MAX_COMMAND_BYTES="${LV_UI_MAX_COMMAND_BYTES:-2048}"
LV_UI_MAX_TEXT_BYTES="${LV_UI_MAX_TEXT_BYTES:-512}"

# Machine-local overrides (never committed). Same argument as the build gate:
# anyone who can write this file can already replace this script, so sourcing
# it adds no new trust.
GATE_CONF="${LV_UI_GATE_CONF:-$HOME/.localvoxtral-ui-gate.conf}"
if [[ -f "$GATE_CONF" ]]; then
  # shellcheck source=/dev/null
  source "$GATE_CONF"
fi

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
import CoreGraphics
import Foundation

// Subcommands (argv[1..]):
//   preflight
//   window <pid> <settings|popover|overlay|window> [index]   -> "<winid> <ownerpid>"
//   axdump <pid> [all|settings|overlay|window] [index]       -> JSON
//   axclick <pid> <selector>
//   axtype <pid> <selector> <text>
//   key <pid> <escape|tab|return>
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
  idle="$(ioreg -c IOHIDSystem 2>/dev/null \
    | awk '/HIDIdleTime/ { gsub(/[^0-9]/, "", $NF); if ($NF != "") { print int($NF / 1000000000); exit } }')"
  [[ "$idle" =~ ^[0-9]+$ ]] || idle="null"
  case "$(pmset -g ps 2>/dev/null | head -n 1)" in
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
  local dogfood=0 argument="" bundle stamp pid deadline
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
  list_contains "$terminal" "$LV_UI_TERMINALS" || deny "terminal not allowlisted"
  (( ${#argv[@]} >= 1 )) || deny "term open needs a command"
  (( ${#argv[@]} <= LV_UI_MAX_TERM_ARGS )) || deny "term open takes at most $LV_UI_MAX_TERM_ARGS tokens"
  list_contains "${argv[0]}" "$LV_UI_TERM_COMMANDS" || deny "command not allowlisted: ${argv[0]}"
  local token
  for token in "${argv[@]}"; do
    token_is_safe "$token" || deny "unsafe token in term command"
  done

  require_unlocked_screen
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

# Shell regression tests source the reviewed implementation directly; the
# variable cannot cross the forced-command SSH boundary, where sshd fixes the
# environment (keep AcceptEnv at its default — see scripts/mac/README.md).
if [[ "${LOCALVOXTRAL_UI_GATE_SOURCE_ONLY:-0}" == "1" ]]; then
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
  fi
  exit 0
fi

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
