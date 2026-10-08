#!/usr/bin/env bash
set -euo pipefail

# Record the README demo, "one morning with two agents" (#1847), as one take:
#   dist/demo/demo-raw.mov    the raw capture
#   dist/demo/timeline.json   where each beat starts and ends in it, with the
#                             waits to speed up and each beat's caption
#   dist/demo/demo.mp4        the raw take encoded, no captions
# scripts/edit-demo.py then cuts the take into the ~90 s story and one clip
# per beat, captions burned in (record-demo.yml runs it on a hosted runner,
# because Homebrew's ffmpeg has no drawtext).
#
# The scene: Ghostty runs an isolated herdr session with two panes, each a
# real Claude Code session with the localvoxtral plugin, in two staged repos
# whose origin is the throwaway T0mSIlver/localvoxtral-demo:
#
#   1 live      hold Right Command in payments, speak a task ending "send it":
#               Live Auto-Paste streams it and the spoken send submits it
#   2 overlay   focus docs, tap, speak code words; the overlay's agent polish
#               writes `useAuth.ts` and `--coverage`, then commits
#   3 needsyou  payments raises a permission request (STAGED: the plugin's
#               Notification hook event, sent by this script with payments'
#               real session id, pid and pane), then the real app: banner and
#               sound, orange dot, a tap, Tab Tab to payments, "yes, go ahead,
#               send it" lands in payments, which comes forward
#   4 inbox     tap, speak a bug, Tab to the Inbox; the app polishes, routes
#               and drafts it, Claude checks it against the code, and this
#               script presses File: a real issue in localvoxtral-demo, closed
#               again when the take ends
#   5 goto      "go to docs" brings the docs pane forward
#   6 learned   hold, dictate "Qwen" (heard "Quen"), fix it by hand and submit:
#               the "Learned" toast; then Settings > Projects with the terms
#               the agents proposed during setup (`localvoxtral terms propose`)
#   7 history   Settings > History, then Insights, on twelve weeks of
#               dictations seeded into the demo's own data folder
#
# Each beat checks what it needs (the session joined, the banner, the pane
# switch, the Inbox draft and its filing) and the run fails instead of
# producing a video when one is missing. Staged: the History rows, the
# permission request, and the speech and polish answers (below).
#
# Speech and polishing come from scripts/lib/demo-backend.py, which the app
# reaches in External URL mode: each dictation hears the line this script
# queued, and the polish writes the demo lines' spoken code forms as code. The
# 8 GB Mac Mini cannot run the bundled 4B models next to two Claude sessions,
# and the owner chose a scripted backend for the demo (#1847). The app, the
# agents, the gestures and every UI on screen are real.
#
# Runs on the Mac Mini runner (record-demo.yml), Right Command posted by a
# compiled helper. Run by hand ON A MAC from the repo root, in an unlocked
# GUI session:
#   ./scripts/record-demo.sh [path/to/localvoxtral.app]
# It needs: Ghostty (>= 1.4: the app's join reads the pane tty over
# AppleScript), herdr, a logged-in `claude`, `gh` logged in with write access
# to T0mSIlver/localvoxtral-demo (the app files the Inbox issue with it),
# ffmpeg, BlackHole 2ch, Notifications > "when mirroring or sharing the
# display" set to Allow (a recorded screen counts as shared, and macOS mutes
# banners there), and the TCC grants: Accessibility and Screen Recording for
# the runner, the app's microphone and Automation -> Ghostty
# (record-demo.yml answers those prompts on a dedicated GUI runner).
#
# The app runs on the harness defaults suite (#1450) and its own data folder
# (#985); the owner's settings and History are never touched.
#
# Tunables (env):
#   DEMO_WIDTH / DEMO_HEIGHT     capture region in points (default 1280x800),
#                                at the top right of the main display so the
#                                menu bar icon and the banners are in it
#   DEMO_WARMUP_SECONDS          off-camera speech warmup (default 12)
#   DEMO_COMMIT_SECONDS          max wait for an overlay commit (default 90)
#   DEMO_INBOX_SECONDS           max wait for the Inbox draft and check (default 300)
#   DEMO_HERDR_SESSION           the isolated herdr session (default lv-demo)
#   DEMO_DEMO_REPO               where the Inbox files (default T0mSIlver/localvoxtral-demo)
#   DEMO_MIC_DEVICE / DEMO_MIC_UID  the silent device the app's microphone is
#                                pinned to (default BlackHole 2ch)
#   DEMO_IDLE_REQUIRED_SECONDS   HID idle needed before a hands-free takeover (120)
#   DEMO_FORCE                   1 = skip the idle guard (attended rehearsal)
#   DEMO_TIMELINE_OFFSET         seconds to subtract from every timeline mark
#                                (default 0: the zero is the first frame)

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script records a macOS app — run it on the Mac." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/launch-app.sh
source "$SCRIPT_DIR/lib/launch-app.sh"

APP_PATH="${1:-dist/localvoxtral.app}"
APP_PROCESS="localvoxtral"
BUNDLE_ID="com.localvoxtral.app"
GHOSTTY_BUNDLE_ID="com.mitchellh.ghostty"

DEMO_WIDTH="${DEMO_WIDTH:-1280}"
DEMO_HEIGHT="${DEMO_HEIGHT:-800}"
DEMO_WARMUP_SECONDS="${DEMO_WARMUP_SECONDS:-12}"
DEMO_COMMIT_SECONDS="${DEMO_COMMIT_SECONDS:-90}"
DEMO_INBOX_SECONDS="${DEMO_INBOX_SECONDS:-300}"
DEMO_HERDR_SESSION="${DEMO_HERDR_SESSION:-lv-demo}"
DEMO_DEMO_REPO="${DEMO_DEMO_REPO:-T0mSIlver/localvoxtral-demo}"
DEMO_TIMELINE_OFFSET="${DEMO_TIMELINE_OFFSET:-0}"
# The app's microphone is pinned to a loopback device nothing plays into, so
# a take never records a real microphone; the words come from the scripted
# backend.
DEMO_MIC_DEVICE="${DEMO_MIC_DEVICE:-BlackHole 2ch}"
DEMO_MIC_UID="${DEMO_MIC_UID:-}"

# What the voice says, beat by beat. Beat 1 streams raw, so no spoken
# symbols; beat 2's "use auth dot t s" and "dash dash coverage" are what the
# agent polish turns into code; beat 6's "Qwen" is the word ASR mishears and
# the hand fix teaches.
LINE_LIVE="Add an item potency key to the refund webhook handler, and check with me before you change the database. Send it."
LINE_OVERLAY="In the README, show how to call use auth dot t s, and add the npm test dash dash coverage command."
LINE_ANSWER="Yes, go ahead. Send it."
LINE_INBOX="Bug: a refund of zero cents returns a 500 from the refunds endpoint."
LINE_GOTO="Go to docs."
LINE_LEARN="Benchmark the docs examples against Quen three."
LEARN_TERM="Qwen"

OUT_DIR="dist/demo"
RAW_MOV="$OUT_DIR/demo-raw.mov"
OUT_MP4="$OUT_DIR/demo.mp4"
TIMELINE_TSV="$OUT_DIR/segments.tsv"
TIMELINE_JSON="$OUT_DIR/timeline.json"

# shellcheck source=scripts/lib/owner-app-session.sh
source "$SCRIPT_DIR/lib/owner-app-session.sh"
record_fail() { echo "$*" >&2; }

[[ -d "$APP_PATH" ]] || { echo "App bundle not found: $APP_PATH (build with ./scripts/package_app.sh)" >&2; exit 1; }
APP_ABS="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
PUBLISHER_PATH="$APP_ABS/Contents/MacOS/localvoxtral-claude-hook"
CLI_PATH="$APP_ABS/Contents/MacOS/localvoxtral-cli"
[[ -x "$PUBLISHER_PATH" && -x "$CLI_PATH" ]] \
  || { echo "The bundle lacks localvoxtral-claude-hook or localvoxtral-cli; repackage with package_app.sh." >&2; exit 1; }

# --- compiled helpers -------------------------------------------------------------
# Compiled once: an interpreted `swift` call takes seconds on the 8 GB Mini,
# which would smear the tap timing and the polls. The target is pinned
# because swiftc defaults to the SDK's macOS, which can be newer than the
# running one.
HELPER_DIR="$(mktemp -d -t lv-demo-helpers)"
compile_helper() { # <name> <source file>
  swiftc -O -target "$(uname -m)-apple-macos15.0" -o "$HELPER_DIR/$1" "$2" \
    || { echo "Could not compile the $1 helper." >&2; exit 1; }
}

cat > "$HELPER_DIR/preflight.swift" <<'SWIFT'
import ApplicationServices
import Carbon
import CoreGraphics

var ok = true
if !AXIsProcessTrusted() {
    print("MISSING Accessibility for the process running this script.")
    ok = false
}
if !CGPreflightScreenCaptureAccess() {
    _ = CGRequestScreenCaptureAccess()
    print("MISSING Screen Recording for the process running this script.")
    ok = false
}
if IsSecureEventInputEnabled() {
    print("BLOCKED Secure Keyboard Entry is held (a locked screen or a password prompt); the live beats would be refused.")
    ok = false
}
exit(ok ? 0 : 1)
SWIFT

# Posts flagsChanged events for Right Command (keycode 54) at the HID tap, the
# real tap/hold gesture path. `key <code> [shift]` posts one key press, for
# Tab while an overlay runs (the app takes it as a Carbon hotkey); `mouse x y`
# moves the pointer.
cat > "$HELPER_DIR/gesture.swift" <<'SWIFT'
import CoreGraphics
import Foundation

let rightCommand: CGKeyCode = 54
func postModifier(down: Bool) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: rightCommand, keyDown: down) else { exit(3) }
    event.type = .flagsChanged
    event.flags = down ? [.maskCommand] : []
    event.post(tap: .cghidEventTap)
}
func postKey(_ code: CGKeyCode, shift: Bool) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { exit(3) }
        event.flags = shift ? [.maskShift] : []
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
    }
}
let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "tap":
    postModifier(down: true)
    Thread.sleep(forTimeInterval: 0.08)
    postModifier(down: false)
case "down": postModifier(down: true)
case "up": postModifier(down: false)
case "mouse":
    guard arguments.count > 3, let x = Double(arguments[2]), let y = Double(arguments[3]),
          let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { exit(2) }
    event.post(tap: .cghidEventTap)
case "key":
    guard arguments.count > 2, let code = UInt16(arguments[2]) else { exit(2) }
    postKey(code, shift: arguments.count > 3 && arguments[3] == "shift")
default: exit(2)
}
SWIFT

cat > "$HELPER_DIR/audiouid.swift" <<'SWIFT'
import CoreAudio
import Foundation

// usage: audiouid <device name> — prints its UID, exit 1 if absent; --list prints every name
guard CommandLine.arguments.count > 1 else { exit(2) }
let wanted = CommandLine.arguments[1]
func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
    guard status == noErr, let value else { return nil }
    return value as String
}
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { exit(1) }
var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { exit(1) }
if wanted == "--list" {
    for id in ids { if let name = stringProperty(id, kAudioObjectPropertyName) { print(name) } }
    exit(0)
}
for id in ids where stringProperty(id, kAudioObjectPropertyName) == wanted {
    if let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) { print(uid); exit(0) }
}
exit(1)
SWIFT

# Closes every notification on screen: a leftover macOS banner (a login item,
# a Tips card) would sit over the scene for the whole take. A single banner
# is a group of the scroll area, a stack a group inside one.
cat > "$HELPER_DIR/clear-notifications.applescript" <<'OSA'
on closeOne(el)
  tell application "System Events"
    repeat with act in (actions of el)
      set actName to name of act
      if actName contains "Clear All" or actName contains "Close" then
        perform act
        return true
      end if
    end repeat
  end tell
  return false
end closeOne

tell application "System Events" to tell process "NotificationCenter"
  set cleared to 0
  repeat 20 times
    set done to false
    try
      set area to scroll area 1 of group 1 of group 1 of window "Notification Center"
      if exists group 1 of group 1 of area then set done to my closeOne(group 1 of group 1 of area)
      if not done and (exists group 1 of area) then set done to my closeOne(group 1 of area)
    end try
    if not done then exit repeat
    set cleared to cleared + 1
    delay 0.5
  end repeat
  return cleared
end tell
OSA

compile_helper preflight "$HELPER_DIR/preflight.swift"
compile_helper gesture "$HELPER_DIR/gesture.swift"
compile_helper audiouid "$HELPER_DIR/audiouid.swift"
compile_helper ax-probe "$SCRIPT_DIR/lib/ax-probe.swift"

tap_hotkey()     { "$HELPER_DIR/gesture" tap; }
press_hotkey()   { "$HELPER_DIR/gesture" down; }
release_hotkey() { "$HELPER_DIR/gesture" up; }
press_tab()      { "$HELPER_DIR/gesture" key 48; }
ax_probe()       { "$HELPER_DIR/ax-probe" "$@"; }

# --- cleanup ----------------------------------------------------------------------
RECORDER_PID=""
BACKEND_PID=""
LAUNCHED_APP=0
LAUNCHED_GHOSTTY=0
DEMO_STAGE=""
ORIGINAL_DARK_MODE=""
DEMO_COMPLETED=0
CLAUDE_BIN=""
HERDR_BIN=""
GH_BIN=""
HERDR_SESSION_STARTED=0
PLUGIN_INSTALLED_THIS_RUN=0
MARKETPLACE_ADDED_THIS_RUN=0
PROMPT_ANSWERER_PID=""
DEDICATED_GUI="${LOCALVOXTRAL_DEDICATED_GUI:-0}"
TAKE_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The Inbox beat files a real issue in the throwaway repo; every take closes
# the issues it opened, whether it finished or not.
close_demo_issues() {
  [[ -n "$GH_BIN" ]] || return 0
  local numbers number
  numbers="$("$GH_BIN" issue list --repo "$DEMO_DEMO_REPO" --state open \
    --search "created:>=$TAKE_STARTED_AT" --json number --jq '.[].number' 2>/dev/null || true)"
  for number in $numbers; do
    "$GH_BIN" issue close "$number" --repo "$DEMO_DEMO_REPO" \
      --comment "Filed by a README demo take (record-demo.yml); closed when the take ended." >/dev/null 2>&1 \
      && echo "Closed $DEMO_DEMO_REPO#$number."
  done
}

cleanup() {
  set +e
  [[ -n "$BACKEND_PID" ]] && kill "$BACKEND_PID" 2>/dev/null
  if [[ -n "$PROMPT_ANSWERER_PID" ]]; then
    pkill -P "$PROMPT_ANSWERER_PID" 2>/dev/null || true
    kill "$PROMPT_ANSWERER_PID" 2>/dev/null || true
  fi
  [[ -x "$HELPER_DIR/gesture" ]] && "$HELPER_DIR/gesture" up >/dev/null 2>&1 # never leave Right Command down
  if [[ -n "$RECORDER_PID" ]] && kill -0 "$RECORDER_PID" 2>/dev/null; then
    kill -INT "$RECORDER_PID" 2>/dev/null || true
    wait "$RECORDER_PID" 2>/dev/null || true
  fi
  if [[ "$LAUNCHED_APP" == 1 ]]; then
    osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
    osascript -e "tell application \"$APP_PROCESS\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -x "$APP_PROCESS" >/dev/null 2>&1 || true
  fi
  # Only the named demo session this run started: `session stop` ends its
  # panes (both claudes), `session delete` its saved state.
  if [[ "$HERDR_SESSION_STARTED" == 1 && -n "$HERDR_BIN" ]]; then
    "$HERDR_BIN" session stop "$DEMO_HERDR_SESSION" >/dev/null 2>&1 || true
    "$HERDR_BIN" session delete "$DEMO_HERDR_SESSION" >/dev/null 2>&1 || true
  fi
  if [[ "$LAUNCHED_GHOSTTY" == 1 ]]; then
    osascript -e "tell application id \"$GHOSTTY_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -xi ghostty >/dev/null 2>&1 || true
  fi
  if [[ -n "$CLAUDE_BIN" ]]; then
    [[ "$PLUGIN_INSTALLED_THIS_RUN" == 1 ]] \
      && "$CLAUDE_BIN" plugin uninstall localvoxtral@localvoxtral >/dev/null 2>&1
    [[ "$MARKETPLACE_ADDED_THIS_RUN" == 1 ]] \
      && "$CLAUDE_BIN" plugin marketplace remove localvoxtral >/dev/null 2>&1
  fi
  close_demo_issues
  if [[ -n "$DEMO_STAGE" ]]; then
    rm -rf "$DEMO_STAGE" 2>/dev/null || { sleep 1; rm -rf "$DEMO_STAGE" 2>/dev/null || true; }
  fi
  [[ -n "${LOCALVOXTRAL_DATA_HOME:-}" && "$LOCALVOXTRAL_DATA_HOME" == */lv-demo-data.* ]] \
    && rm -rf "$LOCALVOXTRAL_DATA_HOME"
  rm -rf "$HELPER_DIR"
  drop_harness_defaults
  report_owner_defaults
  if [[ -n "$ORIGINAL_DARK_MODE" ]]; then
    osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $ORIGINAL_DARK_MODE" >/dev/null 2>&1 || true
  fi
  if [[ "$DEDICATED_GUI" != 1 ]]; then
    if [[ "$DEMO_COMPLETED" == 1 ]]; then say "record demo done" >/dev/null 2>&1; else say "record demo failed" >/dev/null 2>&1; fi
  fi
}
cleanup_once() {
  trap '' INT TERM HUP
  trap - EXIT
  cleanup
}
trap cleanup_once EXIT
trap 'cleanup_once; exit 130' INT
trap 'cleanup_once; exit 143' TERM
trap 'cleanup_once; exit 129' HUP

"$HELPER_DIR/preflight" || exit 1

if [[ -z "$DEMO_MIC_UID" ]]; then
  DEMO_MIC_UID="$("$HELPER_DIR/audiouid" "$DEMO_MIC_DEVICE")" || {
    echo "The demo pins the app's microphone to \"$DEMO_MIC_DEVICE\" (brew install blackhole-2ch), which is missing. Devices here:" >&2
    "$HELPER_DIR/audiouid" --list >&2 || true
    exit 1
  }
fi
echo "App microphone pinned to \"$DEMO_MIC_DEVICE\" ($DEMO_MIC_UID)"

# --- requirements -----------------------------------------------------------------
# Resolved through the login shell: the runner's PATH lacks ~/.local/bin.
CLAUDE_BIN="$(zsh -lc 'command -v claude' 2>/dev/null || true)"
HERDR_BIN="$(zsh -lc 'command -v herdr' 2>/dev/null || true)"
GH_BIN="$(zsh -lc 'command -v gh' 2>/dev/null || true)"
GHOSTTY_APP="${DEMO_GHOSTTY_APP:-}"
if [[ -z "$GHOSTTY_APP" ]]; then
  GHOSTTY_APP="$(mdfind "kMDItemCFBundleIdentifier == '$GHOSTTY_BUNDLE_ID'" 2>/dev/null | head -n 1 || true)"
  [[ -z "$GHOSTTY_APP" && -d /Applications/Ghostty.app ]] && GHOSTTY_APP="/Applications/Ghostty.app"
fi
missing=""
[[ -n "$CLAUDE_BIN" ]] && grep -q '"oauthAccount"' "$HOME/.claude.json" 2>/dev/null || missing="$missing a logged-in claude;"
[[ -n "$HERDR_BIN" ]] || missing="$missing herdr;"
[[ -n "$GH_BIN" ]] || missing="$missing gh;"
[[ -n "$GHOSTTY_APP" && -d "$GHOSTTY_APP" ]] || missing="$missing Ghostty;"
command -v ffmpeg >/dev/null || missing="$missing ffmpeg;"
if [[ -n "$missing" ]]; then
  echo "Missing on this Mac:$missing" >&2
  exit 1
fi
# The app files the Inbox issue with this gh, as this user.
"$GH_BIN" auth status >/dev/null 2>&1 \
  || { echo "gh is not logged in for $(whoami): the Inbox beat could not file its issue." >&2; exit 1; }
"$GH_BIN" repo view "$DEMO_DEMO_REPO" --json name >/dev/null \
  || { echo "Cannot see $DEMO_DEMO_REPO with this gh login." >&2; exit 1; }

herdr_cli() { "$HERDR_BIN" --session "$DEMO_HERDR_SESSION" "$@"; }

# --- never take over a machine someone is using -----------------------------------
DEMO_IDLE_REQUIRED_SECONDS="${DEMO_IDLE_REQUIRED_SECONDS:-120}"
if [[ "${DEMO_FORCE:-0}" != 1 ]]; then
  HID_IDLE_SECONDS="$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}' || true)"
  if [[ -z "$HID_IDLE_SECONDS" ]] || (( HID_IDLE_SECONDS < DEMO_IDLE_REQUIRED_SECONDS )); then
    echo "Machine in use or idle time unreadable (idle ${HID_IDLE_SECONDS:-?}s < ${DEMO_IDLE_REQUIRED_SECONDS}s); refusing to take over the GUI. DEMO_FORCE=1 overrides." >&2
    exit 1
  fi
fi
if [[ "$DEDICATED_GUI" != 1 ]]; then
  say "record demo taking control in 3" >/dev/null 2>&1 || true
  sleep 3
fi

frontmost_app() {
  osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true
}
assert_frontmost() { # <process name> <context>
  local front
  front="$(frontmost_app)"
  if [[ "$(printf '%s' "$front" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" ]]; then
    echo "Frontmost app is '${front:-unknown}', not $1 ($2). Aborting." >&2
    exit 1
  fi
}

# --- settings ---------------------------------------------------------------------
if pgrep -xq "$APP_PROCESS"; then
  osascript -e "tell application \"$APP_PROCESS\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do pgrep -xq "$APP_PROCESS" || break; sleep 0.5; done
  pkill -x "$APP_PROCESS" >/dev/null 2>&1 || true
  sleep 1
fi
pgrep -xq "$APP_PROCESS" && { echo "$APP_PROCESS refuses to quit; aborting." >&2; exit 1; }

recover_previous_defaults_backup || exit 1
OWNER_DEFAULTS_BEFORE="$(owner_defaults_digest)"
# The suite starts as a copy of this Mac's settings, so the backends are the
# real setup; the demo pins what its beats need.
use_harness_defaults
copy_owner_defaults_to_harness \
  || { echo "Could not copy $BUNDLE_ID defaults into $HARNESS_DEFAULTS_SUITE." >&2; exit 1; }
demo_default() { defaults write "$HARNESS_DEFAULTS_SUITE" "$@"; }
demo_default settings.onboarding_completed -bool true
demo_default settings.modifier_only_hotkey_enabled -bool true
demo_default settings.modifier_only_hotkey_modifier -string right_command
# Hold = Live Auto-Paste (off by default: a hold is otherwise an overlay).
demo_default settings.modifier_hold_live_auto_paste -bool true
demo_default settings.live_spoken_send_enabled -bool true
demo_default settings.overlay_spoken_send_enabled -bool true
# The script stops each dictation itself, before the spoken-send auto stop.
demo_default settings.spoken_stop_wait_ms -int 3000
# Needs-you cues, and waiting sessions as Tab destinations.
demo_default settings.agent_attention_enabled -bool true
demo_default settings.agent_attention_mark -string dot
demo_default settings.llm_polishing_enabled -bool true
demo_default settings.agent_polish_profile_enabled -bool true
demo_default settings.overlay_buffer_font_size -float 20
# Grounding in the joined session: its cwd, prompts and files, and the
# herdr pane's screen.
demo_default settings.repo_vocabulary_enabled -bool true
demo_default settings.claude_repo_context_enabled -bool true
demo_default settings.terminal_screen_context_enabled -bool true
demo_default settings.selected_input_device_uid -string "$DEMO_MIC_UID"
# Speech and polishing come from the scripted backend (scripts/lib/demo-backend.py):
# the 8 GB Mini cannot run the bundled 4B models next to two Claude sessions.
BACKEND_PORT_FILE="$HELPER_DIR/backend.port"
LINE_FILE="$HELPER_DIR/next-line.txt"
DEMO_ROUTE_TO="${DEMO_DEMO_REPO#*/},payments" python3 "$SCRIPT_DIR/lib/demo-backend.py" "$BACKEND_PORT_FILE" "$LINE_FILE" &
BACKEND_PID=$!
for _ in $(seq 1 20); do [[ -s "$BACKEND_PORT_FILE" ]] && break; sleep 0.25; done
[[ -s "$BACKEND_PORT_FILE" ]] || { echo "The demo backend did not start." >&2; exit 1; }
BACKEND_PORT="$(cat "$BACKEND_PORT_FILE")"
demo_default settings.dictation_backend_mode -string external_url
demo_default settings.realtime_provider -string realtime_api
demo_default settings.realtime_api_endpoint_url -string "ws://127.0.0.1:$BACKEND_PORT/v1/realtime"
demo_default settings.realtime_api_model_name -string demo
demo_default settings.polishing_backend_mode -string external_url
demo_default settings.llm_polishing_endpoint_url -string "http://127.0.0.1:$BACKEND_PORT/v1/chat/completions"
demo_default settings.llm_polishing_model -string demo
demo_default settings.quick_capture_router -string polishing_model
# queue_line <line>: what the next dictation hears; speak <line>: how long
# saying it takes at the backend's pace (2.8 words a second).
queue_line() { printf '%s\n' "$1" >"$LINE_FILE"; }
speak() { sleep "$(awk -v n="$(wc -w <<<"$1")" 'BEGIN { printf "%.1f", n / 2.8 + 0.8 }')"; }
defaults write "$HARNESS_DEFAULTS_SUITE" dictationInsightsPeriod -string month 2>/dev/null || true

ORIGINAL_DARK_MODE="$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode')"
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true'

# --- stage the two repos ----------------------------------------------------------
DEMO_STAGE="/tmp/lv-demo"
rm -rf "$DEMO_STAGE"
PAYMENTS_DIR="$DEMO_STAGE/payments"
DOCS_DIR="$DEMO_STAGE/docs"
STAGE_BIN="$DEMO_STAGE/bin"
mkdir -p "$PAYMENTS_DIR/src/refunds" "$PAYMENTS_DIR/src/clients" "$PAYMENTS_DIR/tests" \
  "$DOCS_DIR/examples" "$DOCS_DIR/guide" "$STAGE_BIN"
# The agents' `localvoxtral` is this bundle's CLI.
ln -s "$CLI_PATH" "$STAGE_BIN/localvoxtral"

cat > "$PAYMENTS_DIR/package.json" <<'JSON'
{ "name": "payments", "private": true, "scripts": { "test": "vitest run" } }
JSON
cat > "$PAYMENTS_DIR/src/refunds/RefundWebhookHandler.ts" <<'TS'
import { PaylaneClient } from "../clients/PaylaneClient";

export class RefundWebhookHandler {
  constructor(private readonly paylane: PaylaneClient) {}

  async handle(event: { refundId: string; amountCents: number }): Promise<number> {
    const refund = await this.paylane.refund(event.refundId, event.amountCents / event.amountCents);
    return refund.status === "succeeded" ? 200 : 502;
  }
}
TS
cat > "$PAYMENTS_DIR/src/clients/PaylaneClient.ts" <<'TS'
export class PaylaneClient {
  async refund(refundId: string, amount: number, idempotencyKey?: string) {
    return { refundId, amount, idempotencyKey, status: "succeeded" as const };
  }
}
TS
cat > "$PAYMENTS_DIR/tests/refunds.test.ts" <<'TS'
import { test } from "vitest";

test.todo("RefundWebhookHandler refunds the full amount");
TS
cat > "$DOCS_DIR/README.md" <<'MD'
# Acme docs

Guides and runnable examples for the Acme web app, built with Docusaurus.
Payments go through Paylane; the examples run under Vitest.
MD
cat > "$DOCS_DIR/examples/useAuth.ts" <<'TS'
import { useAuth } from "@acme/web";

export function Profile() {
  const { token, isAuthenticated } = useAuth();
  return isAuthenticated ? token : null;
}
TS
cat > "$DOCS_DIR/guide/authentication.md" <<'MD'
# Authentication

`useAuth` returns the session token and whether the user is signed in.
MD
# The dictation note the app's Integrations pane adds to CLAUDE.md
# (DictationNoteInstallService), so the agents know the prompts are dictated.
for repo in "$PAYMENTS_DIR" "$DOCS_DIR"; do
  cat > "$repo/CLAUDE.md" <<'MD'
<!-- begin localvoxtral dictation note -->
## Dictation

I dictate most prompts with a speech-to-text app, so they can hold transcription errors: misheard names, homophones, a word split or merged. Correct an obvious one yourself. When a likely error changes what I am asking, ask me before acting. When you create or rename something I will say aloud, run `localvoxtral terms propose` with its name. If dictation misbehaves, run `localvoxtral doctor`.
<!-- end localvoxtral dictation note -->
MD
  git -C "$repo" init -q -b main
  git -C "$repo" add -A
  git -C "$repo" -c user.name="demo" -c user.email="demo@example.com" commit -q -m "initial commit"
done

# The Inbox files payments' bugs in the throwaway repo. Docs gets no origin:
# two checkouts of one repository share one project and its terms.
git -C "$PAYMENTS_DIR" remote add origin "https://github.com/$DEMO_DEMO_REPO.git"

# --- launch the app on its own data folder, seed History --------------------------
lv_isolate_data lv-demo-data \
  || { echo "Could not make a data folder for the demo app; not launching it on the owner's data." >&2; exit 1; }
HISTORY_STORE="$LOCALVOXTRAL_DATA_HOME/history.store"

launch_app() {
  LAUNCHED_APP=1
  lv_open "$APP_PATH"
  for _ in $(seq 1 20); do pgrep -xq "$APP_PROCESS" && break; sleep 0.5; done
  pgrep -xq "$APP_PROCESS" || { echo "$APP_PROCESS did not launch." >&2; exit 1; }
  APP_PID="$(pgrep -x "$APP_PROCESS" | head -n 1)"
}
quit_demo_app() {
  osascript -e "tell application \"$APP_PROCESS\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -xq "$APP_PROCESS" || break; sleep 0.5; done
  pkill -x "$APP_PROCESS" >/dev/null 2>&1 || true
  sleep 1
}

# The microphone, notification and Automation -> Ghostty prompts, for the
# whole run. A fresh CI build gets the microphone prompt at every launch.
if [[ "$DEDICATED_GUI" == 1 ]]; then
  answer_app_prompts 1800 &
  PROMPT_ANSWERER_PID=$!
fi

# The app creates its store at launch; the rows go in while it is not running.
launch_app
for _ in $(seq 1 40); do [[ -s "$HISTORY_STORE" ]] && break; sleep 0.5; done
[[ -s "$HISTORY_STORE" ]] || { echo "The app never created $HISTORY_STORE." >&2; exit 1; }
sleep 2
quit_demo_app
python3 "$SCRIPT_DIR/lib/seed-demo-history.py" "$HISTORY_STORE" "$PAYMENTS_DIR" "$DOCS_DIR" \
  || { echo "Seeding History failed." >&2; exit 1; }
launch_app
sleep 3

echo "Warming up the dictation backend off-camera (${DEMO_WARMUP_SECONDS}s)..."
tap_hotkey
sleep "$DEMO_WARMUP_SECONDS"
tap_hotkey
sleep 3
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
sleep 1

# --- capture region: top right of the main display, menu bar included -----------
# The banners and the menu bar icon's dot sit at the top right.
read -r MAIN_X MAIN_Y MAIN_W MAIN_H < <(swift - <<'SWIFT'
import CoreGraphics
let b = CGDisplayBounds(CGMainDisplayID())
print("\(Int(b.origin.x)) \(Int(b.origin.y)) \(Int(b.width)) \(Int(b.height))")
SWIFT
)
(( MAIN_W < DEMO_WIDTH || MAIN_H < DEMO_HEIGHT )) && { echo "Main display (${MAIN_W}x${MAIN_H}) is smaller than ${DEMO_WIDTH}x${DEMO_HEIGHT}." >&2; exit 1; }
REGION_X=$(( MAIN_X + MAIN_W - DEMO_WIDTH ))
REGION_Y=$MAIN_Y
MENU_BAR_HEIGHT=40 # windows go below it; System Events clamps them under the bar anyway

place_window() { # <process> <window spec> <x> <y> <w> <h>
  osascript >/dev/null 2>&1 <<OSA || true
tell application "System Events" to tell process "$1"
  set position of $2 to {$3, $4}
  set size of $2 to {$5, $6}
end tell
OSA
}
# A window of fixed size is centered in the region instead.
center_window() { # <process> <window spec>
  local size w h
  size="$(osascript -e "tell application \"System Events\" to tell process \"$1\" to get size of $2" 2>/dev/null | tr -d ' ')" || return 0
  w="${size%,*}"; h="${size#*,}"
  [[ -n "$w" && -n "$h" ]] || return 0
  osascript -e "tell application \"System Events\" to tell process \"$1\" to set position of $2 to {$(( REGION_X + (DEMO_WIDTH - w) / 2 )), $(( REGION_Y + MENU_BAR_HEIGHT + (DEMO_HEIGHT - MENU_BAR_HEIGHT - h) / 2 ))}" >/dev/null 2>&1 || true
}

# --- the Claude Code plugin -------------------------------------------------------
MARKETPLACE_DIR="$REPO_ROOT/integrations/claude-code"
plugin_list_output="$("$CLAUDE_BIN" plugin list 2>/dev/null || true)"
if grep -qi 'localvoxtral@localvoxtral' <<<"$plugin_list_output"; then
  echo "localvoxtral plugin already installed; using it as is."
else
  "$CLAUDE_BIN" plugin marketplace add "$MARKETPLACE_DIR" && MARKETPLACE_ADDED_THIS_RUN=1
  if "$CLAUDE_BIN" plugin install localvoxtral@localvoxtral --config "publisher_path=$PUBLISHER_PATH"; then
    PLUGIN_INSTALLED_THIS_RUN=1
  else
    echo "Could not install the localvoxtral Claude Code plugin; nothing would join. Aborting." >&2
    exit 1
  fi
fi

# Trust both folders: the trust dialog's default is "No, exit" (2.1.29x).
python3 - "$PAYMENTS_DIR" "$DOCS_DIR" <<'PY'
import json, os, sys, tempfile
path = os.path.expanduser("~/.claude.json")
with open(path) as f:
    config = json.load(f)
projects = config.setdefault("projects", {})
for folder in sys.argv[1:]:
    for key in {folder, os.path.realpath(folder)}:
        projects.setdefault(key, {})["hasTrustDialogAccepted"] = True
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as f:
    json.dump(config, f, indent=2)
os.chmod(tmp, os.stat(path).st_mode & 0o777)
os.replace(tmp, path)
PY

# --- Ghostty + herdr: payments on the left, docs on the right ---------------------
if ! "$HERDR_BIN" session delete "$DEMO_HERDR_SESSION" >/dev/null 2>&1; then
  echo "herdr session \"$DEMO_HERDR_SESSION\" is running; refusing to touch it." >&2
  exit 1
fi
# On the dedicated runner the running Ghostty is the agent desktop's herdr
# client; its LaunchAgent reopens it after the run.
if [[ "$DEDICATED_GUI" == 1 ]] && pgrep -xiq ghostty; then
  osascript -e "tell application id \"$GHOSTTY_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -xiq ghostty || break; sleep 0.5; done
fi
pgrep -xiq ghostty && { echo "Ghostty is already running and would swallow the launch args. Quit it and rerun." >&2; exit 1; }
# The demo session's own herdr config: no sidebar, which would label both
# agents by the first pane's folder, and no onboarding.
HERDR_DEMO_CONFIG="$DEMO_STAGE/herdr.toml"
cat > "$HERDR_DEMO_CONFIG" <<'TOML'
onboarding = false

[ui]
sidebar_start_collapsed = true
sidebar_collapsed_mode = "hidden"
show_agent_labels_on_pane_borders = false

[ui.toast]
delivery = "off"

[update]
version_check = false
TOML
LAUNCHED_GHOSTTY=1
HERDR_SESSION_STARTED=1
open -na "$GHOSTTY_APP" --args \
  --working-directory="$PAYMENTS_DIR" \
  --title="localvoxtral demo" \
  --font-family="Menlo" \
  --font-size=15 \
  --background=1e1e1e \
  --foreground=e6e6e6 \
  --window-width=140 \
  --window-height=40 \
  -e /usr/bin/env HERDR_CONFIG_PATH="$HERDR_DEMO_CONFIG" "$HERDR_BIN" --session "$DEMO_HERDR_SESSION"
for _ in $(seq 1 20); do pgrep -xiq ghostty && break; sleep 0.5; done
pgrep -xiq ghostty || { echo "Ghostty did not launch." >&2; exit 1; }
sleep 4
osascript -e "tell application id \"$GHOSTTY_BUNDLE_ID\" to activate" >/dev/null 2>&1 || true
place_window Ghostty "front window" "$REGION_X" "$(( REGION_Y + MENU_BAR_HEIGHT ))" "$DEMO_WIDTH" "$(( DEMO_HEIGHT - MENU_BAR_HEIGHT ))"

PAYMENTS_PANE=""
HERDR_DEADLINE=$(( SECONDS + 30 ))
until [[ -n "$PAYMENTS_PANE" ]]; do
  (( SECONDS >= HERDR_DEADLINE )) && { echo "herdr session $DEMO_HERDR_SESSION never listed a pane." >&2; exit 1; }
  PAYMENTS_PANE="$(herdr_cli pane list 2>/dev/null | grep -o '"pane_id":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)"
  [[ -n "$PAYMENTS_PANE" ]] || sleep 1
done
SPLIT_OUT="$(herdr_cli pane split --pane "$PAYMENTS_PANE" --direction right --cwd "$DOCS_DIR" --no-focus 2>&1)" \
  || { echo "herdr pane split failed: $SPLIT_OUT" >&2; exit 1; }
DOCS_PANE="$(grep -o '"pane_id":"[^"]*"' <<<"$SPLIT_OUT" | head -n 1 | cut -d'"' -f4 || true)"
[[ -n "$DOCS_PANE" && "$DOCS_PANE" != "$PAYMENTS_PANE" ]] || { echo "Could not read the docs pane id ($SPLIT_OUT)." >&2; exit 1; }
echo "herdr panes: payments $PAYMENTS_PANE, docs $DOCS_PANE"
sleep 1

pane_text() { herdr_cli pane read "$1" --source recent --lines "${2:-80}" --format text 2>/dev/null || true; }
pane_focused() { herdr_cli pane get "$1" 2>/dev/null | grep -q '"focused":true'; }
wait_pane_text() { # <pane> <extended regex> <seconds>
  local deadline=$(( SECONDS + $3 ))
  until pane_text "$1" | grep -qiE -- "$2"; do
    (( SECONDS >= deadline )) && return 1
    sleep 1
  done
}
wait_pane_focused() { # <pane> <seconds>
  local deadline=$(( SECONDS + $2 ))
  until pane_focused "$1"; do
    (( SECONDS >= deadline )) && return 1
    sleep 0.5
  done
}
focus_pane() { # <pane> <direction it lies in>
  herdr_cli pane focus --direction "$2" >/dev/null 2>&1 || true
  wait_pane_focused "$1" 5 || { echo "herdr did not focus pane $1." >&2; exit 1; }
}

for pane in "$PAYMENTS_PANE" "$DOCS_PANE"; do
  if [[ "$pane" == "$PAYMENTS_PANE" ]]; then dir="$PAYMENTS_DIR"; else dir="$DOCS_DIR"; fi
  # Haiku: the owner's call, to keep each take's inference small.
  herdr_cli pane run "$pane" "cd $(printf %q "$dir") && PATH=$(printf %q "$STAGE_BIN"):\$PATH $(printf %q "$CLAUDE_BIN") --model haiku" >/dev/null \
    || { echo "Could not start claude in pane $pane." >&2; exit 1; }
done
sleep 8
# A no-op Return on an empty composer when the folder is trusted.
herdr_cli pane send-keys "$PAYMENTS_PANE" Enter >/dev/null || true
herdr_cli pane send-keys "$DOCS_PANE" Enter >/dev/null || true
sleep 2

# Setup, off camera: each agent proposes its repo's names to localvoxtral, as
# the dictation note tells it to. Those are the terms the Projects pane shows.
SETUP_PROMPT="Read this repo, then run \`localvoxtral terms propose\` once with the product, service and library names in it that I might say aloud (names, not code identifiers), with --project . — then answer in one short line."
herdr_cli pane run "$PAYMENTS_PANE" "$SETUP_PROMPT" >/dev/null
herdr_cli pane run "$DOCS_PANE" "$SETUP_PROMPT" >/dev/null
SETUP_DEADLINE=$(( SECONDS + 150 ))
project_terms() { "$CLI_PATH" terms list --project "$1" --json 2>/dev/null | python3 "$SCRIPT_DIR/lib/demo-cli-json.py" terms; }
until [[ -n "$(project_terms "$PAYMENTS_DIR")" && -n "$(project_terms "$DOCS_DIR")" ]]; do
  if pane_text "$PAYMENTS_PANE" 20 | grep -qE "Login expired|Please run /login"; then
    echo "claude's login on this Mac expired: run \`claude auth login\` in its GUI session (the keychain is not readable over ssh)." >&2
    exit 1
  fi
  if (( SECONDS >= SETUP_DEADLINE )); then
    echo "The agents proposed no terms within 150 s; the Projects beat would be empty." >&2
    echo "payments pane:" >&2; pane_text "$PAYMENTS_PANE" 30 >&2
    exit 1
  fi
  sleep 3
done
# Both turns end before /clear: Claude Code shows "esc to interrupt" while
# it works.
TURN_DEADLINE=$(( SECONDS + 120 ))
while pane_text "$PAYMENTS_PANE" 6 | grep -q "esc to interrupt" || pane_text "$DOCS_PANE" 6 | grep -q "esc to interrupt"; do
  (( SECONDS >= TURN_DEADLINE )) && break
  sleep 2
done
echo "Terms proposed: payments: $(project_terms "$PAYMENTS_DIR" | tr '\n' ' '); docs: $(project_terms "$DOCS_DIR" | tr '\n' ' ')"
# A fresh screen for the take: /clear starts a new session in each pane.
herdr_cli pane run "$PAYMENTS_PANE" "/clear" >/dev/null
herdr_cli pane run "$DOCS_PANE" "/clear" >/dev/null
sleep 4

# Warm the agent-profile polish off camera: the first agent polish pays the
# full prompt prefill. Its text is cleared with one Ctrl+C (two exit claude).
focus_pane "$PAYMENTS_PANE" left
last_raw_text() { "$CLI_PATH" history last --json 2>/dev/null | python3 "$SCRIPT_DIR/lib/demo-cli-json.py" last-raw; }
osascript -e "tell application id \"$GHOSTTY_BUNDLE_ID\" to activate" >/dev/null 2>&1 || true
sleep 1
queue_line "Ready to record the demo."
tap_hotkey
speak "Ready to record the demo."
tap_hotkey
WARM_DEADLINE=$(( SECONDS + DEMO_COMMIT_SECONDS ))
until last_raw_text | grep -qi "record"; do
  (( SECONDS >= WARM_DEADLINE )) && { echo "The warmup dictation never reached History: the app is not using the demo backend." >&2; exit 1; }
  sleep 1
done
sleep 1
herdr_cli pane send-keys "$PAYMENTS_PANE" ctrl+c >/dev/null
sleep 1.5

# --- the payments session's identity, for the staged permission request ----------
# The real claude process in the payments pane: its pid, and the herdr pane
# and socket its hooks report, read from its own environment.
PAYMENTS_CLAUDE_PID="$(herdr_cli pane process-info --pane "$PAYMENTS_PANE" 2>/dev/null | python3 -c '
import json, sys
info = json.load(sys.stdin)["result"]["process_info"]
for process in info.get("foreground_processes", []):
    if "claude" in (process.get("name", "") + " " + process.get("cmdline", "")):
        print(process["pid"]); break
' || true)"
[[ -n "$PAYMENTS_CLAUDE_PID" ]] || { echo "Could not find the claude process in the payments pane." >&2; exit 1; }
PAYMENTS_ENV="$(ps -E -ww -o command= -p "$PAYMENTS_CLAUDE_PID" 2>/dev/null || true)"
PAYMENTS_HERDR_SOCKET="$(grep -o 'HERDR_SOCKET_PATH=[^ ]*' <<<"$PAYMENTS_ENV" | head -n 1 | cut -d= -f2- || true)"
PAYMENTS_HERDR_PANE_ID="$(grep -o 'HERDR_PANE_ID=[^ ]*' <<<"$PAYMENTS_ENV" | head -n 1 | cut -d= -f2- || true)"
# Claude Code names a session's transcript after its id, in a folder named
# after its cwd; after /clear the newest one is the live session.
claude_session_id() { # <repo dir>
  local folder
  folder="$HOME/.claude/projects/$(python3 -c 'import os,re,sys; print(re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(sys.argv[1])))' "$1")"
  ls -t "$folder"/*.jsonl 2>/dev/null | head -n 1 | xargs -n 1 basename 2>/dev/null | sed 's/\.jsonl$//' || true
}

# --- record -----------------------------------------------------------------------
mkdir -p "$OUT_DIR"
rm -f "$RAW_MOV" "$OUT_MP4" "$TIMELINE_TSV" "$TIMELINE_JSON"
osascript -e "tell application id \"$GHOSTTY_BUNDLE_ID\" to activate" >/dev/null 2>&1 || true
sleep 1
assert_frontmost Ghostty "before recording"
osascript "$HELPER_DIR/clear-notifications.applescript" >/dev/null 2>&1 || true
"$HELPER_DIR/gesture" mouse "$(( MAIN_X + 10 ))" "$(( MAIN_Y + MAIN_H - 10 ))" # the pointer leaves the shot

now_s() { perl -MTime::HiRes=time -e 'printf("%.3f\n", time)'; }
TL_T0=""
TL_BEAT=""
TL_SPEED=""
TL_START=""
tl_close() {
  local t="$1"
  [[ -n "$TL_BEAT" ]] || return 0
  awk -v b="$TL_BEAT" -v s="$TL_SPEED" -v a="$TL_START" -v e="$t" -v z="$TL_T0" \
    'BEGIN { printf "%s\t%s\t%.3f\t%.3f\n", b, s, a - z, e - z }' >>"$TIMELINE_TSV"
  TL_BEAT=""
}
# tl_seg <beat> <speed>: from now on the take is <beat>, played at <speed>
# (0 drops it from the edit).
tl_seg() {
  local t
  t="$(now_s)"
  tl_close "$t"
  TL_BEAT="$1"; TL_SPEED="$2"; TL_START="$t"
}

# ffmpeg, not `screencapture -v`: on the loaded 8 GB Mini screencapture's
# clock loses seconds unevenly over a take (122 s came out 117 s), so no
# offset or scale put the captions on their beats. ffmpeg writes constant
# 30 fps on the wall clock, and its progress file says how much video
# exists, which puts the timeline's zero on the first frame. The crop is in
# capture pixels, so it holds on a Retina display too.
TAKE_LOG_START="$(date '+%Y-%m-%d %H:%M:%S')"
REC_PROGRESS="$HELPER_DIR/recorder.progress"
CROP="w=iw*$DEMO_WIDTH/$MAIN_W:h=ih*$DEMO_HEIGHT/$MAIN_H:x=iw*$(( REGION_X - MAIN_X ))/$MAIN_W:y=ih*$(( REGION_Y - MAIN_Y ))/$MAIN_H"
ffmpeg -hide_banner -loglevel error -nostdin -y \
  -f avfoundation -capture_cursor 0 -framerate 30 -i "Capture screen 0:none" \
  -vf "crop=$CROP,scale=$DEMO_WIDTH:-2" -fps_mode cfr -r 30 \
  -c:v h264_videotoolbox -b:v 12M -progress "$REC_PROGRESS" "$RAW_MOV" &
RECORDER_PID=$!
TL_T0=""
for _ in $(seq 1 100); do
  REC_US="$(grep '^out_time_us=' "$REC_PROGRESS" 2>/dev/null | tail -n 1 | cut -d= -f2 || true)"
  if [[ -n "$REC_US" && "$REC_US" =~ ^[0-9]+$ ]] && (( REC_US > 0 )); then
    TL_T0="$(awk -v n="$(now_s)" -v us="$REC_US" 'BEGIN { printf "%.3f", n - us / 1000000 }')"
    break
  fi
  kill -0 "$RECORDER_PID" 2>/dev/null || break
  sleep 0.1
done
[[ -n "$TL_T0" ]] || { echo "The screen recorder (ffmpeg avfoundation) never wrote a frame." >&2; exit 1; }
sleep 2
recorder_alive_or_abort() {
  kill -0 "$RECORDER_PID" 2>/dev/null && return 0
  RECORDER_PID=""
  rm -f "$RAW_MOV" "$OUT_MP4"
  echo "The screen recorder stopped before the take ended (someone using the Mac stopped it?)." >&2
  exit 1
}
recorder_alive_or_abort
# Every check below that fails ends the run without a video.
# The take is kept as failed-take.mov, with both panes and the app's log,
# for the workflow's debug artifact; it never becomes the demo.
beat_failed() {
  echo "BEAT FAILED: $*" >&2
  if [[ -n "$RECORDER_PID" ]] && kill -0 "$RECORDER_PID" 2>/dev/null; then
    kill -INT "$RECORDER_PID" 2>/dev/null || true
    wait "$RECORDER_PID" 2>/dev/null || true
  fi
  RECORDER_PID=""
  [[ -f "$RAW_MOV" ]] && mv -f "$RAW_MOV" "$OUT_DIR/failed-take.mov"
  rm -f "$OUT_MP4"
  {
    echo "== payments pane"; pane_text "$PAYMENTS_PANE" 40
    echo "== docs pane"; pane_text "$DOCS_PANE" 40
    echo "== app log since the take started"
    log show --info --start "$TAKE_LOG_START" --predicate 'subsystem == "com.localvoxtral"' 2>/dev/null | tail -n 400
  } >"$OUT_DIR/failed-take.txt" 2>&1
  [[ -f "$TIMELINE_TSV" ]] && cp "$TIMELINE_TSV" "$OUT_DIR/failed-take-segments.tsv"
  [[ -f "$LINE_FILE.log" ]] && cp "$LINE_FILE.log" "$OUT_DIR/failed-take-backend.log"
  exit 1
}
log_since() { # <start "YYYY-MM-DD HH:MM:SS">: the app's log since then
  log show --info --start "$1" --predicate 'subsystem == "com.localvoxtral"' 2>/dev/null || true
}

# Beat 1 — live: hold, the task streams into payments, "send it" submits it.
tl_seg live 1
BEAT_LOG_START="$(date '+%Y-%m-%d %H:%M:%S')"
queue_line "@1.2 $LINE_LIVE" # it starts once past the hold threshold
press_hotkey
sleep 1.2
speak "$LINE_LIVE"
release_hotkey
sleep 3
wait_pane_text "$PAYMENTS_PANE" "refund|database" 15 || beat_failed "live: the dictation never reached the payments pane."
log_since "$BEAT_LOG_START" | grep -q "spoken send: submit" || beat_failed "live: \"send it\" did not submit the prompt."
log_since "$BEAT_LOG_START" | grep -qiE 'joined to a live Claude session' \
  || echo "WARNING: no join line in the app log for beat 1." >&2
tl_seg live 2 # the agent starts on it
sleep 4

# Beat 2 — overlay: docs, tap, code words, agent polish, commit.
tl_seg overlay 1
focus_pane "$DOCS_PANE" right
sleep 1
queue_line "$LINE_OVERLAY"
tap_hotkey
speak "$LINE_OVERLAY"
tap_hotkey
tl_seg overlay 6 # polish
wait_pane_text "$DOCS_PANE" "coverage" "$DEMO_COMMIT_SECONDS" || beat_failed "overlay: nothing committed into the docs pane."
pane_text "$DOCS_PANE" 20 | grep -qF "useAuth" || echo "WARNING: the polish did not write useAuth in beat 2." >&2
tl_seg overlay 1
sleep 3
herdr_cli pane send-keys "$DOCS_PANE" Enter >/dev/null
sleep 2

# Beat 3 — needs you: payments asks for permission (staged hook event), the
# banner and dot, a tap, Tab Tab to payments, the spoken answer.
tl_seg needsyou 1
BEAT_LOG_START="$(date '+%Y-%m-%d %H:%M:%S')"
PAYMENTS_SESSION_ID="$(claude_session_id "$PAYMENTS_DIR")"
[[ -n "$PAYMENTS_SESSION_ID" ]] || beat_failed "needsyou: no Claude session id for payments."
printf '{"hook_event_name":"Notification","session_id":"%s","cwd":"%s","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}\n' \
  "$PAYMENTS_SESSION_ID" "$PAYMENTS_DIR" \
  | env LOCALVOXTRAL_CLAUDE_PPID="$PAYMENTS_CLAUDE_PID" TERM_PROGRAM=ghostty \
      HERDR_PANE_ID="$PAYMENTS_HERDR_PANE_ID" HERDR_SOCKET_PATH="$PAYMENTS_HERDR_SOCKET" \
      "$PUBLISHER_PATH" --event Notification
# The banner: NotificationCenter's window when AX can read it, else its log.
# A recorded screen counts as a shared display, and macOS mutes banners there
# unless Notifications > "when mirroring or sharing the display" allows them.
NC_PID="$(pgrep -x NotificationCenter | head -n 1 || true)"
if ! { [[ -n "$NC_PID" ]] && ax_probe "$NC_PID" --find "needs you" --timeout 8 >/dev/null 2>&1; }; then
  NC_LOG="$(log show --start "$BEAT_LOG_START" --predicate 'process == "NotificationCenter"' 2>/dev/null | grep 'com.localvoxtral.app' || true)"
  NC_ALLOWED_LOG="$(log show --start "$BEAT_LOG_START" --predicate 'process == "NotificationCenter"' 2>/dev/null | grep 'notificationsAllowed: false' | grep 'com.localvoxtral.app' || true)"
  if [[ -n "$NC_ALLOWED_LOG" ]]; then
    beat_failed "needsyou: notifications are off for localvoxtral (System Settings > Notifications > localvoxtral > Allow notifications)."
  fi
  if grep -q 'muted by display state' <<<"$NC_LOG"; then
    beat_failed "needsyou: macOS muted the banner because the screen is being recorded; allow notifications when sharing the display (System Settings > Notifications)."
  fi
  grep -q 'agent-attention' <<<"$NC_LOG" || beat_failed "needsyou: no \"needs you\" banner."
fi
sleep 3
queue_line "@3 $LINE_ANSWER" # the answer comes after the two Tabs
tap_hotkey
sleep 1
press_tab
sleep 0.7
press_tab
sleep 1.3
speak "$LINE_ANSWER"
tap_hotkey
tl_seg needsyou 4
wait_pane_focused "$PAYMENTS_PANE" "$DEMO_COMMIT_SECONDS" || beat_failed "needsyou: payments never came forward."
wait_pane_text "$PAYMENTS_PANE" "go ahead" "$DEMO_COMMIT_SECONDS" || beat_failed "needsyou: the answer never reached payments."
log_since "$BEAT_LOG_START" | grep -q "spoken send: submit" || beat_failed "needsyou: \"send it\" did not submit the answer."
tl_seg needsyou 1
sleep 3

# Beat 4 — Inbox: a bug, Tab to the Inbox; the draft is routed, checked
# against the code, and filed.
tl_seg inbox 1
BEAT_LOG_START="$(date '+%Y-%m-%d %H:%M:%S')"
capture_ids() { "$CLI_PATH" capture list --json 2>/dev/null | python3 "$SCRIPT_DIR/lib/demo-cli-json.py" capture-ids; }
CAPTURES_BEFORE="$(capture_ids)"
queue_line "$LINE_INBOX"
tap_hotkey
speak "$LINE_INBOX"
press_tab
sleep 1
tap_hotkey
tl_seg inbox 8
capture_id() { capture_ids | grep -vxF -e "${CAPTURES_BEFORE:-none}" | head -n 1 || true; }
CAPTURE_ID=""
INBOX_DEADLINE=$(( SECONDS + 60 ))
until [[ -n "$CAPTURE_ID" ]]; do
  (( SECONDS >= INBOX_DEADLINE )) && beat_failed "inbox: no quick capture within 60 s."
  sleep 2
  CAPTURE_ID="$(capture_id)"
done
"$CLI_PATH" capture open "$CAPTURE_ID" >/dev/null || beat_failed "inbox: capture open refused."
sleep 2
center_window "$APP_PROCESS" "front window"
# File is enabled once the draft is ready; Claude's check of the draft
# against the code comes after it, and the app logs its end.
CHECK_DEADLINE=$(( SECONDS + DEMO_INBOX_SECONDS ))
until log show --start "$BEAT_LOG_START" --predicate 'subsystem == "com.localvoxtral"' 2>/dev/null \
  | grep -qE 'Quick capture draft: (claude|vibe|opencode) checked'; do
  (( SECONDS >= CHECK_DEADLINE )) && beat_failed "inbox: the draft was never checked against the code. $("$CLI_PATH" capture show "$CAPTURE_ID" 2>&1 | head -n 20)"
  sleep 3
done
"$CLI_PATH" capture show "$CAPTURE_ID" 2>/dev/null | grep -q "Repository: $DEMO_DEMO_REPO" \
  || beat_failed "inbox: the draft does not file in $DEMO_DEMO_REPO. $("$CLI_PATH" capture show "$CAPTURE_ID" 2>&1 | head -n 3)"
tl_seg inbox 1
sleep 3
ax_probe "$APP_PID" --press inbox.row.file --title File --timeout 10 >/dev/null || beat_failed "inbox: could not press File."
tl_seg inbox 4
FILED_DEADLINE=$(( SECONDS + 90 ))
until "$CLI_PATH" capture show "$CAPTURE_ID" --json 2>/dev/null | python3 "$SCRIPT_DIR/lib/demo-cli-json.py" filed-url \
  | grep -q "github.com/$DEMO_DEMO_REPO/issues/"; do
  (( SECONDS >= FILED_DEADLINE )) && beat_failed "inbox: the issue was never filed in $DEMO_DEMO_REPO."
  sleep 2
done
tl_seg inbox 1
sleep 3

# Beat 5 — go to docs.
tl_seg goto 1
queue_line "$LINE_GOTO"
tap_hotkey
speak "$LINE_GOTO"
tap_hotkey
wait_pane_focused "$DOCS_PANE" 15 || beat_failed "goto: the docs pane never came forward."
sleep 1
assert_frontmost Ghostty "after go to docs"
sleep 2

# Beat 6 — learned: dictate a name ASR mishears, fix it by hand, submit; the
# app learns it from the difference. Then the Projects pane.
tl_seg learned 1
herdr_cli pane send-keys "$DOCS_PANE" ctrl+c >/dev/null # the composer starts empty
sleep 1
queue_line "@1.2 $LINE_LEARN"
press_hotkey
sleep 1.2
speak "$LINE_LEARN"
release_hotkey
sleep 3
# The composer's last line holds what was inserted; the word before "three"
# is how ASR heard the name.
HEARD="$(pane_text "$DOCS_PANE" 15 | grep -i "benchmark" | tail -n 1 \
  | python3 -c 'import re,sys; m=re.search(r"against\s+(.+?)\s+(three|3)", sys.stdin.read(), re.I); print(m.group(1) if m else "")')"
if [[ -z "$HEARD" ]]; then
  beat_failed "learned: the dictation never reached the docs pane."
elif [[ "$HEARD" == "$LEARN_TERM" ]]; then
  echo "WARNING: ASR already wrote $LEARN_TERM; there is nothing to fix by hand, so no Learned toast." >&2
else
  # The hand fix: erase back to the misheard word and retype it.
  TAIL="$(pane_text "$DOCS_PANE" 15 | grep -i "benchmark" | tail -n 1 \
    | python3 -c 'import re,sys; t=sys.stdin.read().rstrip(); m=re.search(r"against\s+", t, re.I); print(len(t) - m.end() if m else 0)')"
  tl_seg learned 3 # the hand fix: erase and retype
  for _ in $(seq 1 "$TAIL"); do herdr_cli pane send-keys "$DOCS_PANE" Backspace >/dev/null; done
  sleep 0.5
  herdr_cli pane send-text "$DOCS_PANE" "$LEARN_TERM three." >/dev/null
  sleep 1
fi
tl_seg learned 1
herdr_cli pane send-keys "$DOCS_PANE" Enter >/dev/null
if [[ "$HEARD" != "$LEARN_TERM" ]]; then
  ax_probe "$APP_PID" --find "Learned" --timeout 15 >/dev/null 2>&1 \
    || echo "WARNING: no Learned toast after the hand fix ($HEARD -> $LEARN_TERM)." >&2
fi
sleep 3
tl_seg learned 3 # opening Settings

open_settings_tab() { # <tab raw id> <title>
  ax_probe "$APP_PID" --press "settings.tab.$1" --title "$2" --window localvoxtral --timeout 10 >/dev/null \
    || beat_failed "could not open Settings > $2."
}
osascript >/dev/null <<OSA
tell application "System Events" to tell process "$APP_PROCESS"
  ignoring application responses
    click menu bar item 1 of menu bar 2
  end ignoring
end tell
delay 1
OSA
osascript >/dev/null <<OSA || beat_failed "learned: could not open Settings."
tell application "System Events" to tell process "$APP_PROCESS"
  click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
end tell
OSA
sleep 2
center_window "$APP_PROCESS" "front window"
open_settings_tab projects Projects
tl_seg learned 1
sleep 4

# Beat 7 — History, then Insights.
tl_seg history 1
open_settings_tab history History
sleep 6
open_settings_tab insights Insights
sleep 9
tl_close "$(now_s)"

recorder_alive_or_abort
TL_STOP="$(awk -v e="$(now_s)" -v z="$TL_T0" 'BEGIN { printf "%.3f", e - z }')"
kill -INT "$RECORDER_PID"
wait "$RECORDER_PID" 2>/dev/null || true
RECORDER_PID=""
[[ -s "$RAW_MOV" ]] || { echo "The screen recorder produced no output." >&2; exit 1; }

python3 - "$TIMELINE_TSV" "$TIMELINE_JSON" "$DEMO_TIMELINE_OFFSET" "$TL_STOP" <<'PY'
import json, sys
tsv, out, offset, stop = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
beats = [
    ("live", "Hold to talk: it streams into Claude Code. “Send it” submits"),
    ("overlay", "Tap to talk: the polish writes the session’s code words"),
    ("needsyou", "An agent needs you: Tab to it and answer by voice"),
    ("inbox", "A stray bug goes to the Inbox, checked and filed as an issue"),
    ("goto", "“Go to docs” brings that session forward"),
    ("learned", "Fix a word once and it is learned, with the agents’ terms"),
    ("history", "History and Insights: time saved, terms it learned"),
]
segments = []
with open(tsv) as f:
    for line in f:
        beat, speed, start, end = line.rstrip("\n").split("\t")
        segments.append({"beat": beat, "speed": float(speed), "start": float(start), "end": float(end)})
with open(out, "w") as f:
    json.dump({"offset": offset, "stop": stop, "beats": [{"id": b, "caption": c} for b, c in beats], "segments": segments}, f, indent=2)
PY

ffmpeg -hide_banner -loglevel error -y -i "$RAW_MOV" \
  -vf "scale=${DEMO_WIDTH}:-2:flags=lanczos,fps=30" \
  -c:v libx264 -crf 20 -preset slow -pix_fmt yuv420p -movflags +faststart -an "$OUT_MP4"
cp "$LINE_FILE.log" "$OUT_DIR/backend.log" 2>/dev/null || true
echo "Raw take: $RAW_MOV, encoded $OUT_MP4 ($(du -h "$OUT_MP4" | cut -f1)), timeline $TIMELINE_JSON"
DEMO_COMPLETED=1
