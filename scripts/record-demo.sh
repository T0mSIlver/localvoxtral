#!/usr/bin/env bash
set -euo pipefail

# Record the README demo video as H.264:
#   dist/demo/demo.mp4      (encoded, ready to drag-drop into a GitHub PR/issue
#                            comment — GitHub only renders inline video from
#                            user-attachments uploads, so that step is manual)
#   dist/demo/demo-raw.mov  (raw capture, kept so the encode can be redone)
#
# The scene is TERMINAL-CENTRIC — localvoxtral is the dictation app to talk to
# your coding agents. The script stages a small git repo and records two beats.
# The terminal it uses depends on the scene:
#
#   * claude mode (the flagship): a REAL Claude Code session in GHOSTTY (>=1.4 /
#     tip). Ghostty is required here because the app joins the focused pane to
#     that session by the pane's controlling TTY (Ghostty exposes it over
#     AppleScript) — that TTY join is what lets polishing ground technical terms
#     in the SESSION's own reported cwd, prior prompt, and recently-touched
#     files, independent of the window title. Before launching, the script
#     installs the localvoxtral Claude Code plugin (hooks-only) so those hooks
#     report the session; it uninstalls afterwards only if it installed it.
#   * herdr mode (opt-in, DEMO_TERMINAL_AGENT=herdr — never chosen by auto): the
#     claude scene INSIDE a herdr pane. Ghostty runs `herdr --session <name>`
#     (an ISOLATED named demo session — the owner's own herdr sessions are never
#     attached, stopped, or split), with TWO panes: the focused pane runs the
#     real Claude Code session in the staged repo, the neighbor runs a decoy
#     watcher printing identifiers from a DIFFERENT fake repo. Beat 2's
#     grounding then rides the HERDR PANE JOIN (the app resolves the exact pane
#     over herdr's JSON socket — no title marker, no surface-tty match for the
#     inner session) and the pane-exact `pane.read` screen context — the visual
#     proof that the right session wins and neighboring panes never leak. After
#     beat 2 the script ASSERTS both from the app's unified log
#     (subsystem com.localvoxtral, category ClaudeContext) and deletes the
#     capture if the join silently fell back — never record a lying demo.
#     Pane management is herdr-CLI-only (split/run/send-keys over the socket);
#     no synthetic keystrokes are used for it.
#   * shell mode (fallback, no usable claude / no Ghostty): a plain zsh prompt in
#     Terminal.app (always installed). Here beat 2 grounds `useAuth.ts` from the
#     repo vocabulary the app reads out of the window-title cwd, as before.
#
#   Beat 1  hold Right Command -> live dictation streams word-by-word into the
#           session's prompt/composer while speaking (the differentiator; no
#           stray newline ever submits it)
#   Beat 2  tap Right Command  -> overlay buffer -> speak a line with a spoken
#           symbol form of a real repo identifier + spoken flags -> tap -> the
#           agent-profile LLM polish (grounded, in claude mode, by the JOINED
#           session's cwd/prior-prompt/recent-files) writes `useAuth.ts` /
#           `--coverage` and the commit lands in the terminal; in claude mode the
#           polished prompt is then genuinely SUBMITTED and the real response is
#           recorded (one small request against the owner's Claude usage —
#           DEMO_SUBMIT_PROMPT=0 disables)
#
# The voice is either YOU (default) or macOS text-to-speech through a loopback
# audio device (hands-free mode — how the CI runner records it, see
# record-demo.yml).
#
# OWNER RULE (this runs on a daily-driver Mac): before any focus-stealing
# automation the script announces itself audibly on the DEFAULT output and
# waits 3 seconds, and it announces completion/failure at the end — in
# hands-free mode too.
#
# Run ON A MAC from the repo root, in a GUI session:
#   ./scripts/record-demo.sh [path/to/localvoxtral.app]
# Default app: dist/localvoxtral.app (build it with ./scripts/package_app.sh).
#
# One-time TCC grants for the terminal running this script:
#   - Accessibility     (posts the Right Command gesture, drives the scene app)
#   - Screen Recording  (screencapture -v)
#   - Microphone        (only when DEMO_CAPTURE_AUDIO=1, the default)
#   - Automation -> Ghostty  (claude scene only: this script also reads Ghostty's
#                       focused-pane tty to confirm >=1.4 and for surgical
#                       cleanup — a separate grant from the app's, below)
# The app itself must already have its mic + Accessibility grants and a
# working dictation backend (managed local installed, or your endpoints up).
# For the CLAUDE scene the app ALSO needs its own Automation -> Ghostty grant:
# the join reads the focused pane's tty over AppleScript, and the app's #167
# consent prewarm raises that sheet at launch (it must be answered / already
# granted, or the join blocks and the grounding no-ops). The claude scene also
# needs Ghostty >=1.4 / tip installed and a logged-in `claude` CLI, and the
# script installs the localvoxtral Claude Code plugin for the session (removing
# it afterwards only if it installed it).
# The overlay beat needs the managed polishing helper: the script enables LLM
# polishing with the default 4B model and waits for polishd health on port
# 8472 before recording (a first-ever run may include a ~3.3 GB model
# download). ffmpeg (brew install ffmpeg) is needed for the final encode;
# without it the raw .mov is still produced (GitHub accepts .mov drag-drops).
#
# Tunables (env):
#   DEMO_WIDTH / DEMO_HEIGHT      capture region in points (default 1280x800)
#   DEMO_SPEAK_SECONDS            speaking window per beat (default 9)
#   DEMO_WARMUP_SECONDS           off-camera backend warmup (default 12)
#   DEMO_COMMIT_SECONDS           wait for polish+commit after beat 2 (default 12)
#   DEMO_POLISH_READY_SECONDS     max wait for polishd health (default 300)
#   DEMO_CAPTURE_AUDIO            1 = record default-input audio into the video
#                                 (default: 1 for a human take, 0 hands-free)
#   DEMO_LINE_LIVE / _OVERLAY     the lines shown in the prompts / spoken by TTS
#   DEMO_LINE_CLAUDE_SETUP        claude mode only: the FIRST prompt, typed (not
#                                 dictated) and submitted before the beats so the
#                                 plugin's hooks register this session's prior
#                                 prompt + recently-read file — the context that
#                                 grounds beat 2. Read-only; answers fast.
#   DEMO_CLAUDE_SETUP_SECONDS     how long to let the setup prompt's turn run
#                                 (default 18)
#   DEMO_SUBMIT_PROMPT            1 (default) = in claude mode, submit the
#                                 polished beat-2 prompt and record the response
#   DEMO_RESPONSE_SECONDS         how long to record the response (default 14)
#   DEMO_TERMINAL_AGENT           auto (default) | claude | herdr | shell —
#                                 which scene to record. auto records the Ghostty
#                                 Claude Code scene when `claude` is logged in
#                                 AND Ghostty is installed, else falls back to
#                                 the Terminal.app zsh scene (herdr is NEVER
#                                 chosen by auto — it must be explicit). claude
#                                 REQUIRES claude+Ghostty (fails fast if either
#                                 is missing, or if Ghostty is too old to expose
#                                 the pane tty); herdr additionally REQUIRES
#                                 `herdr` on the login-shell PATH; shell forces
#                                 Terminal.app.
#   DEMO_HERDR_SESSION            herdr mode: the ISOLATED named herdr session
#                                 the demo creates, drives, and tears down
#                                 (default "lv-demo"). The demo owns this name:
#                                 a stale stopped session dir with this name is
#                                 deleted at start, and the whole session is
#                                 stopped+deleted on exit. A RUNNING session by
#                                 this name is refused, never hijacked.
#   DEMO_GHOSTTY_APP              path to Ghostty.app (default: resolved via
#                                 mdfind / /Applications). Overrides detection.
#   DEMO_HANDS_FREE               1 = no human: render the lines with `say`
#                                 into the "BlackHole 2ch" loopback device and
#                                 pin the app's mic to it. One-time machine
#                                 setup: brew install blackhole-2ch
#   DEMO_SAY_DEVICE               loopback device name for hands-free mode
#                                 (default "BlackHole 2ch"; setting this also
#                                 implies hands-free)
#   DEMO_SAY_INPUT_UID            audio-device UID the app's mic is pinned to;
#                                 resolved automatically from DEMO_SAY_DEVICE
#                                 when unset
#   DEMO_IDLE_REQUIRED_SECONDS    hands-free only: minimum HID idle time before
#                                 the script may take over the GUI (default 120)
#   DEMO_FORCE                    1 = skip the idle guard for an attended
#                                 hands-free rehearsal

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script records a macOS app — run it on the Mac." >&2
  exit 1
fi

APP_PATH="${1:-dist/localvoxtral.app}"
APP_PROCESS="localvoxtral"
BUNDLE_ID="com.localvoxtral.app"

DEMO_WIDTH="${DEMO_WIDTH:-1280}"
DEMO_HEIGHT="${DEMO_HEIGHT:-800}"
DEMO_SPEAK_SECONDS="${DEMO_SPEAK_SECONDS:-9}"
DEMO_WARMUP_SECONDS="${DEMO_WARMUP_SECONDS:-12}"
DEMO_COMMIT_SECONDS="${DEMO_COMMIT_SECONDS:-12}"
DEMO_POLISH_READY_SECONDS="${DEMO_POLISH_READY_SECONDS:-300}"
DEMO_TERMINAL_AGENT="${DEMO_TERMINAL_AGENT:-auto}"
DEMO_HERDR_SESSION="${DEMO_HERDR_SESSION:-lv-demo}"
# Beat 1 (hold -> live streaming): a technical sentence a developer would say
# to a coding agent; streamed raw, so no spoken symbol forms here.
DEMO_LINE_LIVE="${DEMO_LINE_LIVE:-Refactor the retry logic in the websocket client, and add a unit test for the reconnect path.}"
# Beat 2 (tap -> overlay + agent-profile polish): a spoken identifier + spoken
# flag that the agent profile writes as code — `useAuth.ts` and `--coverage`.
# "use auth dot t s" is a proven ASR mishear (take 6: it lands as "the use of
# that TS" / "use of dot TS"), which is exactly the point — the correction
# demonstrably NEEDS session context. In the OLD Terminal.app claude scene the
# repo-vocabulary rescue no-op'd, because Claude Code overwrites the window
# title the cwd resolver read. The GHOSTTY scene fixes this at the root: the app
# joins the pane to the Claude session by its TTY (title-independent) and grounds
# `useAuth.ts` from the JOINED session's cwd (git ls-files finds
# src/auth/useAuth.ts), its prior prompt (DEMO_LINE_CLAUDE_SETUP names the file),
# and the file Claude just read. In shell mode the same line is rescued the old
# way, from the repo vocabulary the app reads out of the window-title cwd.
# Phrased read-only so submitting it yields a fast text answer, not a
# tool-permission stall.
DEMO_LINE_OVERLAY="${DEMO_LINE_OVERLAY:-Explain what use auth dot t s returns, then give me the test command with dash dash coverage.}"
# claude mode: the staged FIRST prompt. Typed literally (not dictated), so the
# exact spelling `src/auth/useAuth.ts` becomes the session's prior prompt and,
# once Claude reads it, a recently-touched file — both grounding beat 2. A
# read-only ask so the turn is fast.
DEMO_LINE_CLAUDE_SETUP="${DEMO_LINE_CLAUDE_SETUP:-Read src/auth/useAuth.ts and tell me in one sentence what the useAuth hook returns.}"
DEMO_CLAUDE_SETUP_SECONDS="${DEMO_CLAUDE_SETUP_SECONDS:-18}"
# In claude mode the polished beat-2 prompt is genuinely SUBMITTED (one small
# request against the owner's Claude usage) and the response is recorded for
# DEMO_RESPONSE_SECONDS. DEMO_SUBMIT_PROMPT=0 turns the ending off.
DEMO_SUBMIT_PROMPT="${DEMO_SUBMIT_PROMPT:-1}"
DEMO_RESPONSE_SECONDS="${DEMO_RESPONSE_SECONDS:-12}"
DEMO_HANDS_FREE="${DEMO_HANDS_FREE:-0}"
DEMO_SAY_DEVICE="${DEMO_SAY_DEVICE:-}"
DEMO_SAY_INPUT_UID="${DEMO_SAY_INPUT_UID:-}"
if [[ "$DEMO_HANDS_FREE" == 1 && -z "$DEMO_SAY_DEVICE" ]]; then
  DEMO_SAY_DEVICE="BlackHole 2ch"
fi
# Audio-track default: a human take records their real voice from the default
# input; a hands-free take renders TTS into the loopback, which the recorder's
# default input can't hear — so default the track off there.
if [[ -z "${DEMO_CAPTURE_AUDIO:-}" ]]; then
  if [[ -n "$DEMO_SAY_DEVICE" ]]; then DEMO_CAPTURE_AUDIO=0; else DEMO_CAPTURE_AUDIO=1; fi
fi

case "$DEMO_TERMINAL_AGENT" in
  auto|claude|herdr|shell) ;;
  *) echo "DEMO_TERMINAL_AGENT must be auto, claude, herdr, or shell (got: $DEMO_TERMINAL_AGENT)" >&2; exit 1;;
esac

OUT_DIR="dist/demo"
RAW_MOV="$OUT_DIR/demo-raw.mov"
OUT_MP4="$OUT_DIR/demo.mp4"

DEFAULTS_BACKUP="${HOME}/.localvoxtral-record-demo.pre.plist"
DEFAULTS_BACKUP_HAD_DOMAIN="${DEFAULTS_BACKUP}.had-domain"

[[ -d "$APP_PATH" ]] || { echo "App bundle not found: $APP_PATH (build with ./scripts/package_app.sh)" >&2; exit 1; }

# --- defaults snapshot/restore (same pattern as capture-readme-assets.sh) ----
write_empty_plist() {
  cat >"$1" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
}

snapshot_domain() { # <domain> <backup> <had-domain-marker>
  rm -f "$2" "$3"
  if defaults export "$1" "$2" >/dev/null 2>&1; then
    : >"$3" || return 1
  elif defaults read "$1" >/dev/null 2>&1; then
    return 1
  else
    write_empty_plist "$2" || return 1
  fi
  [[ -f "$2" ]] || return 1
}

restore_domain() { # <domain> <backup> <had-domain-marker>
  [[ -f "$2" ]] || return 0
  defaults delete "$1" >/dev/null 2>&1 || true
  if [[ -f "$3" ]]; then
    defaults import "$1" "$2" >/dev/null 2>&1 || return 1
  fi
  rm -f "$2" "$3"
}

# --- permission + secure-input preflight ------------------------------------------
PREFLIGHT="$(mktemp -t lv-demo-preflight).swift"
cat > "$PREFLIGHT" <<'SWIFT'
import ApplicationServices
import Carbon
import CoreGraphics

var ok = true
if !AXIsProcessTrusted() {
    print("MISSING Accessibility: System Settings > Privacy & Security > Accessibility — enable the app that launched this script, then rerun.")
    ok = false
}
if !CGPreflightScreenCaptureAccess() {
    _ = CGRequestScreenCaptureAccess()
    print("MISSING Screen Recording: System Settings > Privacy & Security > Screen Recording — enable the app that launched this script, then rerun.")
    ok = false
}
if IsSecureEventInputEnabled() {
    print("BLOCKED Secure Keyboard Entry is held by some process — usually a LOCKED SCREEN, a password prompt, or Terminal's own Secure Keyboard Entry setting. The live-dictation beat would be refused. Unlock the GUI session / disable it, then rerun.")
    ok = false
}
exit(ok ? 0 : 1)
SWIFT

# --- Right Command gesture helper ----------------------------------------------
# Posts synthetic flagsChanged events for Right Command (keycode 54) at the HID
# tap; the app's modifier-only monitors match on that keycode, so this drives
# the REAL tap/hold gesture path, not a side door.
GESTURE="$(mktemp -t lv-demo-gesture).swift"
cat > "$GESTURE" <<'SWIFT'
import CoreGraphics
import Foundation

// usage: gesture.swift tap | down | up | hold <seconds>
let rightCommand: CGKeyCode = 54
func post(down: Bool) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: rightCommand, keyDown: down) else { exit(3) }
    event.type = .flagsChanged
    event.flags = down ? [.maskCommand] : []
    event.post(tap: .cghidEventTap)
}
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tap"
switch mode {
case "tap":
    post(down: true)
    Thread.sleep(forTimeInterval: 0.08)
    post(down: false)
case "down":
    post(down: true)
case "up":
    post(down: false)
case "hold":
    let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 2 : 2
    post(down: true)
    Thread.sleep(forTimeInterval: seconds)
    post(down: false)
default:
    exit(2)
}
SWIFT

tap_hotkey()  { swift "$GESTURE" tap; }
hold_hotkey() { swift "$GESTURE" hold "$1"; } # blocks for the hold duration
press_hotkey()   { swift "$GESTURE" down; }
release_hotkey() { swift "$GESTURE" up; }

# --- audio-device UID resolver (hands-free mode) --------------------------------
# The app pins its mic by device UID; resolve it from the loopback's name so
# nothing is hardcoded and a missing BlackHole fails fast with instructions.
AUDIO_UID="$(mktemp -t lv-demo-audiouid).swift"
cat > "$AUDIO_UID" <<'SWIFT'
import CoreAudio
import Foundation

// usage: audiouid.swift <device name>  — prints the device UID, exit 1 if absent
//        audiouid.swift --list         — prints every audio device name
guard CommandLine.arguments.count > 1 else { exit(2) }
let wanted = CommandLine.arguments[1]

func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value as String
}

var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { exit(1) }
var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { exit(1) }

if wanted == "--list" {
    for id in ids {
        if let name = stringProperty(id, kAudioObjectPropertyName) {
            print(name)
        }
    }
    exit(0)
}

for id in ids where stringProperty(id, kAudioObjectPropertyName) == wanted {
    if let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) {
        print(uid)
        exit(0)
    }
}
exit(1)
SWIFT

# --- cleanup -------------------------------------------------------------------
RECORDER_PID=""
LAUNCHED_APP=0
LAUNCHED_TERMINAL_APP=0
LAUNCHED_GHOSTTY=0
TERMINAL_WINDOW_ID=""
TERMINAL_TTY=""
DEMO_STAGE=""
ORIGINAL_DARK_MODE=""
ANNOUNCED_TAKEOVER=0
DEMO_COMPLETED=0
# Declared here (ahead of the trap) so cleanup can reference them even if the
# script exits before they are assigned below — `set -u` would otherwise abort
# cleanup itself on an unbound reference.
CLAUDE_BIN=""
GHOSTTY_APP=""
SCENE_APP="Terminal"
SCENE_TELL="application \"Terminal\""
PLUGIN_INSTALLED_THIS_RUN=0
MARKETPLACE_ADDED_THIS_RUN=0
HERDR_BIN=""
HERDR_SESSION_STARTED=0
cleanup() {
  set +e # cleanup is best-effort: one failing teardown step must not abort the rest
  if [[ -f "$GESTURE" ]]; then
    swift "$GESTURE" up >/dev/null 2>&1 || true # never leave Right Command stuck down
  fi
  rm -f "$PREFLIGHT" "$GESTURE" "$AUDIO_UID"
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
  # Terminal teardown is surgical: kill only the processes on OUR window's
  # tty (never `pkill claude` — the owner may have his own sessions running),
  # close only OUR window, and quit Terminal only if WE launched it.
  if [[ -n "$TERMINAL_TTY" ]]; then
    pkill -t "${TERMINAL_TTY#/dev/}" >/dev/null 2>&1 || true
    sleep 1
  fi
  if [[ -n "$TERMINAL_WINDOW_ID" ]]; then
    osascript -e "tell application \"Terminal\" to close window id $TERMINAL_WINDOW_ID" >/dev/null 2>&1 || true
  fi
  if [[ "$LAUNCHED_TERMINAL_APP" == 1 ]]; then
    osascript -e 'tell application "Terminal" to quit' >/dev/null 2>&1 || true
  fi
  # herdr (herdr scene): stop and delete ONLY the named demo session this run
  # started — `session stop` exits the server and every pane process (claude,
  # the decoy loop), `session delete` removes its persisted state. The stop is
  # keyed on HERDR_SESSION_STARTED, so a refused/pre-existing session is never
  # touched, and the default session cannot be reached (every call is
  # --session-scoped to the demo name).
  if [[ "$HERDR_SESSION_STARTED" == 1 && -n "$HERDR_BIN" ]]; then
    "$HERDR_BIN" session stop "$DEMO_HERDR_SESSION" >/dev/null 2>&1 || true
    "$HERDR_BIN" session delete "$DEMO_HERDR_SESSION" >/dev/null 2>&1 || true
  fi
  # Ghostty (claude scene): kill only OUR pane's tty above, then quit the app
  # only if WE launched it — an owner's pre-existing Ghostty is never quit.
  if [[ "$LAUNCHED_GHOSTTY" == 1 ]]; then
    osascript -e 'tell application "Ghostty" to quit' >/dev/null 2>&1 || true
    sleep 1
    pkill -xi ghostty >/dev/null 2>&1 || true
  fi
  # Back out ONLY what this run added (probed with `claude plugin list` before
  # touching anything) — never disturb an owner's own install. The uninstall and
  # the marketplace-remove are keyed on SEPARATE flags: an add-succeeds/
  # install-fails run still removes the marketplace it added.
  if [[ -n "$CLAUDE_BIN" ]]; then
    if [[ "$PLUGIN_INSTALLED_THIS_RUN" == 1 ]]; then
      "$CLAUDE_BIN" plugin uninstall localvoxtral@localvoxtral >/dev/null 2>&1 || true
    fi
    if [[ "$MARKETPLACE_ADDED_THIS_RUN" == 1 ]]; then
      "$CLAUDE_BIN" plugin marketplace remove localvoxtral >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "$DEMO_STAGE" ]]; then
    # The staged zsh writes .zsh_sessions into ZDOTDIR while exiting (we just
    # killed its tty) — one rm can race that write (take 3 died here); retry.
    rm -rf "$DEMO_STAGE" 2>/dev/null || { sleep 1; rm -rf "$DEMO_STAGE" 2>/dev/null || true; }
  fi
  if ! restore_domain "$BUNDLE_ID" "$DEFAULTS_BACKUP" "$DEFAULTS_BACKUP_HAD_DOMAIN"; then
    echo "WARNING: failed to restore $BUNDLE_ID defaults; backup left at $DEFAULTS_BACKUP" >&2
  fi
  if [[ -n "$ORIGINAL_DARK_MODE" ]]; then
    osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to ${ORIGINAL_DARK_MODE}" >/dev/null 2>&1 || true
  fi
  # Owner rule: announce completion audibly (default output, never the
  # loopback) whenever the script took over the GUI session.
  if [[ "$ANNOUNCED_TAKEOVER" == 1 ]]; then
    if [[ "$DEMO_COMPLETED" == 1 ]]; then
      say "record demo done" >/dev/null 2>&1 || true
    else
      say "record demo failed" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT INT TERM HUP

swift "$PREFLIGHT" || exit 1

if [[ -n "$DEMO_SAY_DEVICE" ]]; then
  if [[ -z "$DEMO_SAY_INPUT_UID" ]]; then
    DEMO_SAY_INPUT_UID="$(swift "$AUDIO_UID" "$DEMO_SAY_DEVICE")" || {
      echo "Hands-free mode needs the loopback audio device \"$DEMO_SAY_DEVICE\", which is not present." >&2
      echo "One-time setup on this Mac: brew install blackhole-2ch" >&2
      echo "Audio devices visible to this session:" >&2
      swift "$AUDIO_UID" --list >&2 || true
      exit 1
    }
  fi
  echo "Hands-free mode: TTS -> \"$DEMO_SAY_DEVICE\", app mic pinned to UID $DEMO_SAY_INPUT_UID"
fi

command -v ffmpeg >/dev/null || \
  echo "NOTE: ffmpeg not found — the raw .mov will be produced but not encoded (brew install ffmpeg)." >&2

# --- resolve what runs in the terminal window ------------------------------------
# The flagship scene is a real Claude Code session in GHOSTTY, because the app
# joins the focused pane to that session by the pane's controlling TTY — the
# title-independent mechanism that makes beat 2's grounding fire. That needs
# BOTH a logged-in `claude` CLI AND Ghostty (>=1.4 / tip). If either is missing
# we fall back to the honest Terminal.app zsh scene rather than record a claude
# scene whose join can never resolve. Never fake a running agent.
GHOSTTY_BUNDLE_ID="com.mitchellh.ghostty"
# Default BEFORE the resolution block: DEMO_TERMINAL_AGENT=shell skips the whole
# `if`, and every later reference (and `set -u`) needs this bound regardless.
TERMINAL_AGENT="shell"
if [[ "$DEMO_TERMINAL_AGENT" != "shell" ]]; then
  # Resolve the absolute binary via the login shell: a staged demo shell has a
  # bare ZDOTDIR, so the user's own PATH additions won't exist inside it.
  CLAUDE_BIN="$(zsh -lc 'command -v claude' 2>/dev/null || true)"
  CLAUDE_USABLE=0
  [[ -n "$CLAUDE_BIN" ]] && grep -q '"oauthAccount"' "$HOME/.claude.json" 2>/dev/null && CLAUDE_USABLE=1

  # Locate Ghostty.app: explicit override, then Spotlight, then /Applications.
  # `|| true` inside the substitution: under `pipefail`, mdfind emitting more
  # than the pipe buffer holds SIGPIPEs `head` (exit 141), and a disabled
  # Spotlight returns non-zero — either would abort the script via `set -e`.
  GHOSTTY_APP="${DEMO_GHOSTTY_APP:-}"
  if [[ -z "$GHOSTTY_APP" ]]; then
    GHOSTTY_APP="$(mdfind "kMDItemCFBundleIdentifier == '$GHOSTTY_BUNDLE_ID'" 2>/dev/null | head -n 1 || true)"
    [[ -z "$GHOSTTY_APP" && -d /Applications/Ghostty.app ]] && GHOSTTY_APP="/Applications/Ghostty.app"
  fi
  GHOSTTY_PRESENT=0
  [[ -n "$GHOSTTY_APP" && -d "$GHOSTTY_APP" ]] && GHOSTTY_PRESENT=1

  if [[ "$DEMO_TERMINAL_AGENT" == "herdr" ]]; then
    # herdr scene: the claude scene's requirements PLUS the herdr CLI. Explicit
    # only — auto never picks it. Fail fast, one precise message per gap.
    if [[ "$CLAUDE_USABLE" != 1 ]]; then
      echo "DEMO_TERMINAL_AGENT=herdr, but no usable claude CLI (binary missing from the login-shell PATH, or not logged in)." >&2
      exit 1
    fi
    if [[ "$GHOSTTY_PRESENT" != 1 ]]; then
      echo "DEMO_TERMINAL_AGENT=herdr needs Ghostty (>=1.4 / tip): the app's herdr arm binds the focused surface's tty to the herdr client before it will ask herdr's socket anything. Install it (brew install --cask ghostty@tip) or set DEMO_GHOSTTY_APP." >&2
      exit 1
    fi
    HERDR_BIN="$(zsh -lc 'command -v herdr' 2>/dev/null || true)"
    if [[ -z "$HERDR_BIN" ]]; then
      echo "DEMO_TERMINAL_AGENT=herdr, but no herdr binary on the login-shell PATH (https://herdr.dev)." >&2
      exit 1
    fi
    TERMINAL_AGENT="herdr"
  elif [[ "$CLAUDE_USABLE" == 1 && "$GHOSTTY_PRESENT" == 1 ]]; then
    TERMINAL_AGENT="claude"
  elif [[ "$DEMO_TERMINAL_AGENT" == "claude" ]]; then
    # Explicit claude: fail fast with the precise missing piece.
    if [[ "$CLAUDE_USABLE" != 1 ]]; then
      echo "DEMO_TERMINAL_AGENT=claude, but no usable claude CLI (binary missing from the login-shell PATH, or not logged in)." >&2
    else
      echo "DEMO_TERMINAL_AGENT=claude needs Ghostty (>=1.4 / tip) for the focused-pane TTY join, but Ghostty.app was not found. Install it (brew install --cask ghostty@tip) or set DEMO_GHOSTTY_APP." >&2
    fi
    exit 1
  else
    # auto: degrade to the honest Terminal.app shell scene.
    if [[ "$CLAUDE_USABLE" == 1 && "$GHOSTTY_PRESENT" != 1 ]]; then
      echo "NOTE: claude is available but Ghostty is not — recording the Terminal.app shell scene instead (the Claude join needs Ghostty's focused-pane tty)." >&2
    fi
  fi
fi
echo "Terminal scene agent: $TERMINAL_AGENT"
# Scene identity used for activation / AX window placement below. SCENE_APP is
# the System Events PROCESS name (AX must address processes by name); SCENE_TELL
# is the `tell application …` target, keyed on Ghostty's BUNDLE ID (matching the
# app's own reader) rather than the fragile display name.
if [[ "$TERMINAL_AGENT" == "claude" || "$TERMINAL_AGENT" == "herdr" ]]; then
  SCENE_APP="Ghostty"
  SCENE_TELL="application id \"$GHOSTTY_BUNDLE_ID\""
else
  SCENE_APP="Terminal"
  SCENE_TELL="application \"Terminal\""
fi

# herdr scene: every herdr invocation is pinned to the isolated demo session —
# never the caller's HERDR_SESSION / HERDR_SOCKET_PATH (an explicit --session
# overrides both, so running this script from inside a herdr pane cannot leak
# commands into that session).
herdr_cli() { "$HERDR_BIN" --session "$DEMO_HERDR_SESSION" "$@"; }

# --- GUARD: never take over a machine someone is actively using ------------------
# Field incident 2026-07-21: a hands-free run fired while the owner watched a
# fullscreen video; every staged window landed on another Space and the region
# capture recorded the owner's screen — which then went up as a run artifact.
# The audible 3 s warning is not consent. In hands-free mode, require the
# machine to have been untouched for DEMO_IDLE_REQUIRED_SECONDS (default 120);
# an attended human take skips this (the operator at the keyboard IS the user).
# DEMO_FORCE=1 overrides for an attended hands-free rehearsal.
DEMO_IDLE_REQUIRED_SECONDS="${DEMO_IDLE_REQUIRED_SECONDS:-120}"
DEMO_FORCE="${DEMO_FORCE:-0}"
if [[ "$DEMO_HANDS_FREE" == 1 && "$DEMO_FORCE" != 1 ]]; then
  HID_IDLE_SECONDS="$(ioreg -c IOHIDSystem 2>/dev/null \
    | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}' || true)"
  if [[ -z "$HID_IDLE_SECONDS" ]]; then
    echo "Cannot read HID idle time; refusing a hands-free takeover blind (DEMO_FORCE=1 overrides)." >&2
    exit 1
  fi
  if (( HID_IDLE_SECONDS < DEMO_IDLE_REQUIRED_SECONDS )); then
    echo "Machine in active use (idle ${HID_IDLE_SECONDS}s < ${DEMO_IDLE_REQUIRED_SECONDS}s) — refusing to take over the GUI. Rerun when idle, or DEMO_FORCE=1 for an attended rehearsal." >&2
    exit 1
  fi
  echo "Idle guard: machine idle ${HID_IDLE_SECONDS}s (>= ${DEMO_IDLE_REQUIRED_SECONDS}s) — proceeding."
fi

# Synthetic keystrokes land in whatever is frontmost. Assert it is the staged
# scene app before every typing site — a user raising a window (or a fullscreen
# Space) between staging and typing must abort, never type into their app.
assert_scene_frontmost() {
  local context="$1" front
  front="$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)"
  if [[ "$(printf '%s' "$front" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$SCENE_APP" | tr '[:upper:]' '[:lower:]')" ]]; then
    echo "Frontmost app is '${front:-unknown}', not the staged $SCENE_APP — refusing to send keystrokes ($context)." >&2
    exit 1
  fi
}

# --- OWNER RULE: audible takeover warning BEFORE any focus-stealing action -------
# On the DEFAULT audio output (never the loopback — that device is inaudible).
say "record demo taking control in 3" >/dev/null 2>&1 || true
ANNOUNCED_TAKEOVER=1
sleep 3

# --- stage settings -------------------------------------------------------------
if pgrep -xq "$APP_PROCESS"; then
  echo "Quitting running $APP_PROCESS instance..."
  osascript -e "tell application \"$APP_PROCESS\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do pgrep -xq "$APP_PROCESS" || break; sleep 0.5; done
  pkill -x "$APP_PROCESS" >/dev/null 2>&1 || true
  sleep 1
fi
pgrep -xq "$APP_PROCESS" && { echo "$APP_PROCESS refuses to quit; aborting." >&2; exit 1; }

snapshot_domain "$BUNDLE_ID" "$DEFAULTS_BACKUP" "$DEFAULTS_BACKUP_HAD_DOMAIN" \
  || { echo "Could not snapshot $BUNDLE_ID defaults; refusing to mutate them." >&2; exit 1; }

# The demo always shows the Right Command tap/hold gesture. Backend MODES are
# left as configured on this Mac (the demo should use the real setup), but the
# overlay beat depends on agent-profile polishing with the default 4B model —
# the 0.8B does not normalize spoken flags reliably (see the demoted
# agent-flag-spoken eval case) — so those are pinned (snapshotted above,
# restored on exit).
defaults write "$BUNDLE_ID" "settings.onboarding_completed" -bool true
defaults write "$BUNDLE_ID" "settings.modifier_only_hotkey_enabled" -bool true
defaults write "$BUNDLE_ID" "settings.modifier_only_hotkey_modifier" -string "right_command"
defaults write "$BUNDLE_ID" "settings.llm_polishing_enabled" -bool true
defaults write "$BUNDLE_ID" "settings.agent_polish_profile_enabled" -bool true
defaults write "$BUNDLE_ID" "settings.managed_llm_polishing_model" -string "mlx-community/Qwen3.5-4B-OptiQ-4bit"
# Overlay body font scaled up to match the 21 pt terminal font so the overlay
# beat reads at README width (clamped to OverlayLayoutMetrics.maximum, 24).
defaults write "$BUNDLE_ID" "settings.overlay_buffer_font_size" -float 22
# Repo vocabulary grounds beat 2's spoken filename ("use auth dot t s" ->
# useAuth.ts, exactly as spelled in the staged repo). In SHELL mode the app reads
# the cwd out of the terminal window title, which must contain a /-prefixed path
# — the Terminal staging AppleScript pins the tab's custom title for that.
defaults write "$BUNDLE_ID" "settings.repo_vocabulary_enabled" -bool true
# claude mode: the beat-2 grounding comes from the JOINED Claude session, not the
# title. `claude_repo_context_enabled` is the gate for indexing the joined
# session's cwd (git ls-files) and attaching its prior prompt + recently-touched
# files to the polish prompt; it is ALSO what arms the app's one-time
# Automation->Ghostty consent prewarm (#167) at launch, so the pane-tty read the
# join depends on is not blocked mid-recording. (Default off; snapshotted above,
# restored on exit. Left off in shell mode, which has no session to join.)
if [[ "$TERMINAL_AGENT" == "claude" || "$TERMINAL_AGENT" == "herdr" ]]; then
  defaults write "$BUNDLE_ID" "settings.claude_repo_context_enabled" -bool true
fi
# herdr mode: the joined pane's screen context arrives over herdr's socket
# (`pane.read`), gated on the SAME opt-in as an AX screen read — enable it so
# the pane-exact capture the scene asserts on can fire. (Snapshotted above,
# restored on exit; left untouched in the other scenes.)
if [[ "$TERMINAL_AGENT" == "herdr" ]]; then
  defaults write "$BUNDLE_ID" "settings.terminal_screen_context_enabled" -bool true
fi
if [[ -n "$DEMO_SAY_INPUT_UID" ]]; then
  defaults write "$BUNDLE_ID" "settings.selected_input_device_uid" -string "$DEMO_SAY_INPUT_UID"
fi

# Dark mode pinned, like the README screenshots.
ORIGINAL_DARK_MODE="$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode')"
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true'
sleep 1

# --- launch + warm up the backends off-camera ------------------------------------
LAUNCHED_APP=1
open "$APP_PATH"
for _ in $(seq 1 20); do pgrep -xq "$APP_PROCESS" && break; sleep 0.5; done
pgrep -xq "$APP_PROCESS" || { echo "$APP_PROCESS did not launch." >&2; exit 1; }
sleep 2

echo "Warming up the dictation backend off-camera (${DEMO_WARMUP_SECONDS}s, stay quiet)..."
tap_hotkey
sleep "$DEMO_WARMUP_SECONDS"
tap_hotkey
sleep 3
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true # dismiss overlay
sleep 1

# The overlay beat's polish must be REAL — never record before the managed
# polishing helper answers its health endpoint. (An external-URL polishing
# setup is the owner's own working config and is not polled.)
POLISH_MODE="$(defaults read "$BUNDLE_ID" settings.polishing_backend_mode 2>/dev/null || echo managed_local)"
if [[ "$POLISH_MODE" != "external_url" ]]; then
  HF_HUB_DIR="${HF_HUB_CACHE:-}"
  [[ -z "$HF_HUB_DIR" && -n "${HF_HOME:-}" ]] && HF_HUB_DIR="$HF_HOME/hub"
  [[ -z "$HF_HUB_DIR" ]] && HF_HUB_DIR="$HOME/.cache/huggingface/hub"
  if [[ ! -d "$HF_HUB_DIR/models--mlx-community--Qwen3.5-4B-OptiQ-4bit" ]]; then
    echo "NOTE: the 4B polish model is not in the HF cache yet — readiness may include a ~3.3 GB download." >&2
  fi
  echo "Waiting for the polishing helper (http://127.0.0.1:8472/health, up to ${DEMO_POLISH_READY_SECONDS}s)..."
  POLISH_DEADLINE=$(( SECONDS + DEMO_POLISH_READY_SECONDS ))
  until curl -sf -m 2 http://127.0.0.1:8472/health >/dev/null 2>&1; do
    if (( SECONDS >= POLISH_DEADLINE )); then
      echo "polishd never became healthy within ${DEMO_POLISH_READY_SECONDS}s — aborting (the overlay beat would show unpolished text)." >&2
      exit 1
    fi
    sleep 2
  done
  echo "polishd healthy."
fi

# --- capture region (MAIN display only) -------------------------------------------
# The desktop-union bounding box is wrong on multi-monitor setups: its center
# can be a void between displays, which records as black while macOS clamps
# the window elsewhere (first hands-free runner take failed exactly like
# that). CGDisplayBounds uses the same global top-left coordinates as
# screencapture -R and System Events window positions.
read -r MAIN_X MAIN_Y MAIN_W MAIN_H < <(swift - <<'SWIFT'
import CoreGraphics
let b = CGDisplayBounds(CGMainDisplayID())
print("\(Int(b.origin.x)) \(Int(b.origin.y)) \(Int(b.width)) \(Int(b.height))")
SWIFT
)
REGION_X=$(( MAIN_X + (MAIN_W - DEMO_WIDTH) / 2 ))
REGION_Y=$(( MAIN_Y + (MAIN_H - DEMO_HEIGHT) / 2 ))
(( MAIN_W < DEMO_WIDTH || MAIN_H < DEMO_HEIGHT )) && { echo "Main display (${MAIN_W}x${MAIN_H}) is smaller than the ${DEMO_WIDTH}x${DEMO_HEIGHT} capture region." >&2; exit 1; }
(( REGION_Y < MAIN_Y + 30 )) && REGION_Y=$(( MAIN_Y + 30 )) # keep clear of the menu bar

# --- stage the demo repo + the scene window inside the capture region -------------
# Fixed short path (not mktemp): in shell mode the Terminal tab's custom title is
# set to this path so RepoVocabulary can resolve the repo from the window title,
# and a short path keeps that title readable on camera. In claude mode the join
# resolves the repo from the session's reported cwd instead, but the same staged
# path is Ghostty's --working-directory. Wiped before use and on cleanup.
DEMO_STAGE="/tmp/lv-demo"
rm -rf "$DEMO_STAGE"
REPO_DIR="$DEMO_STAGE/webapp"
ZDOT_DIR="$DEMO_STAGE/zdot"
mkdir -p "$REPO_DIR/src/auth" "$REPO_DIR/tests/auth" "$ZDOT_DIR"

cat > "$REPO_DIR/package.json" <<'JSON'
{
  "name": "webapp",
  "private": true,
  "scripts": {
    "test": "vitest run"
  }
}
JSON
cat > "$REPO_DIR/src/index.ts" <<'TS'
import { createClient } from "./client";

export function main(): void {
  const client = createClient();
  client.connect();
}
TS
cat > "$REPO_DIR/src/client.ts" <<'TS'
export function createClient() {
  return {
    connect(): void {
      // TODO: retry logic
    },
  };
}
TS
cat > "$REPO_DIR/src/auth/useAuth.ts" <<'TS'
import { useState } from "react";

export function useAuth() {
  const [token, setToken] = useState<string | null>(null);
  return { token, isAuthenticated: token !== null, setToken };
}
TS
cat > "$REPO_DIR/tests/auth/useAuth.test.ts" <<'TS'
import { test, expect } from "vitest";
import { useAuth } from "../../src/auth/useAuth";

test.todo("starts unauthenticated");
test.todo("exposes the token after setToken");
TS
git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" -c user.name="demo" -c user.email="demo@example.com" \
  commit -q -m "initial commit"

# Minimal zsh prompt (repo name + branch), no rprompt, cleared screen — the
# recording opens on a clean, legible prompt with no real username/hostname.
cat > "$ZDOT_DIR/.zshrc" <<'ZSHRC'
PROMPT='%F{green}➜%f %F{cyan}%1~%f %F{blue}git:(%F{red}main%F{blue})%f '
unset RPROMPT
clear
ZSHRC

# Size + position the scene window into the capture region via Accessibility
# (System Events). This is app-agnostic — the same AX path works for Terminal
# and for Ghostty, whose own AppleScript dictionary is too narrow to move/size a
# window — so the recording never shows the rest of the desktop.
# CAVEAT (claude mode): this targets `front window` of the process. When Ghostty
# was ALREADY running we cannot prove our just-opened window is the frontmost
# one, so in that case this may move the owner's window instead. There is no
# window-id handle to scope it to ours; noted as a residual risk in final.md.
# `|| true`: a positioning glitch must not waste the whole warmup cycle (this is
# a small behavior change from the pre-refactor Terminal path, which aborted).
position_scene_window() { # <process name>
  osascript >/dev/null <<OSA || true
tell application "$1" to activate
tell application "System Events" to tell process "$1"
  set position of front window to {$REGION_X, $REGION_Y}
  set size of front window to {$DEMO_WIDTH, $DEMO_HEIGHT}
end tell
OSA
}

# Every Ghostty pane's controlling tty, one per line (best-effort). Used to tell
# OUR just-opened pane apart from an owner's pre-existing panes before trusting a
# tty for surgical cleanup. Tolerant of Ghostty's object model: if the plural
# accessors are unsupported it returns empty, and the caller treats empty as
# "cannot prove ownership" (safe: skip the kill).
ghostty_pane_ttys() {
  osascript -e "tell application id \"$GHOSTTY_BUNDLE_ID\" to get tty of every terminal of every tab of every window" 2>/dev/null \
    | tr ',' '\n' | tr -d '{}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep '^/dev/tty' || true
}

# A general-purpose keystroke helper (types a literal string into the focused
# app). argv-based so punctuation in the string can't break out of the quoting —
# the same reason the staging AppleScript lives in a file.
KEYSTROKE_OSA="$DEMO_STAGE/keystroke.applescript"
cat > "$KEYSTROKE_OSA" <<'OSA'
on run argv
    tell application "System Events" to keystroke (item 1 of argv)
end run
OSA

if [[ "$TERMINAL_AGENT" == "claude" || "$TERMINAL_AGENT" == "herdr" ]]; then
  # ---- claude scene: GHOSTTY, so the app can join the pane by its TTY ----------
  # ---- herdr scene: the same Ghostty+claude scaffolding, with herdr between
  #      them — Ghostty runs the herdr client, claude runs inside a herdr pane,
  #      and the join is the pane-exact herdr socket join. ----------------------
  # Install the localvoxtral Claude Code plugin FIRST, so the session's
  # SessionStart/UserPromptSubmit/PostToolUse hooks fire from the moment claude
  # launches and report its tty + prior prompt + touched files to the app. We
  # pin `publisher_path` at the app bundle UNDER TEST (this build's publisher,
  # not one in /Applications). Probe `claude plugin list` first: uninstall on
  # cleanup ONLY if this run is the one that installed it.
  APP_ABS="$(cd "$(dirname "$APP_PATH")" >/dev/null 2>&1 && pwd)/$(basename "$APP_PATH")"
  PUBLISHER_PATH="$APP_ABS/Contents/MacOS/localvoxtral-claude-hook"
  [[ -x "$PUBLISHER_PATH" ]] || { echo "Publisher binary missing at $PUBLISHER_PATH — repackage with package_app.sh." >&2; exit 1; }
  MARKETPLACE_DIR="$(cd "$(dirname "$0")/.." >/dev/null 2>&1 && pwd)/integrations/claude-code"
  [[ -d "$MARKETPLACE_DIR/.claude-plugin" ]] || MARKETPLACE_DIR="$PWD/integrations/claude-code"
  # Capture the probe THEN grep the variable: `plugin list | grep` under
  # `pipefail` lets a failing `plugin list` (claude not initialized, a blip)
  # flip the `if` to false and re-install over — then uninstall — an owner's
  # plugin. The `|| true` keeps a probe failure from aborting the script; the
  # grep decides on the captured text alone.
  plugin_list_output="$("$CLAUDE_BIN" plugin list 2>/dev/null || true)"
  if grep -qi 'localvoxtral@localvoxtral' <<<"$plugin_list_output"; then
    echo "localvoxtral plugin already installed — using it as-is (will NOT uninstall on cleanup)."
  else
    echo "Installing the localvoxtral Claude Code plugin (marketplace: $MARKETPLACE_DIR)..."
    if "$CLAUDE_BIN" plugin marketplace add "$MARKETPLACE_DIR"; then
      MARKETPLACE_ADDED_THIS_RUN=1
    fi
    # stderr is intentionally NOT suppressed: a failed install must show claude's
    # own reason in the log, not just our one-liner.
    if "$CLAUDE_BIN" plugin install localvoxtral@localvoxtral --config "publisher_path=$PUBLISHER_PATH"; then
      PLUGIN_INSTALLED_THIS_RUN=1
      echo "Plugin installed (publisher_path=$PUBLISHER_PATH)."
    else
      # Install failed. Cleanup backs out the marketplace on exit whenever WE
      # added it this run (MARKETPLACE_ADDED_THIS_RUN), independently of whether
      # the plugin installed — so an add-succeeds/install-fails run does not leak
      # the marketplace into the owner's config.
      echo "Failed to install the localvoxtral Claude Code plugin — beat 2's join would never fire. Aborting." >&2
      exit 1
    fi
  fi

  if [[ "$TERMINAL_AGENT" == "herdr" ]]; then
    # Claim the isolated demo session name WITHOUT ever touching a running one.
    # `herdr session delete` succeeds for a missing or stopped session (clearing
    # stale state from a crashed earlier take) and REFUSES a running one
    # (src/session.rs delete_session) — exactly the guard we want: a live
    # session by this name, whoever owns it, is never hijacked or stopped.
    if ! "$HERDR_BIN" session delete "$DEMO_HERDR_SESSION" >/dev/null 2>&1; then
      echo "herdr session \"$DEMO_HERDR_SESSION\" is RUNNING — refusing to touch it (the demo needs to own its named session end to end)." >&2
      echo "If it is a leftover from an earlier demo take, stop it first: herdr session stop $DEMO_HERDR_SESSION — or pick another name via DEMO_HERDR_SESSION." >&2
      exit 1
    fi

    # The decoy pane's fake OTHER repo: real files (so the pane could even ls
    # them) plus a deterministic, network-free watcher loop printing its
    # identifiers. On camera this is the neighboring pane that must NOT leak
    # into the polish: beat 2 writes useAuth.ts from the JOINED pane's session,
    # never usePayment.ts from this one.
    DECOY_DIR="$DEMO_STAGE/billing"
    mkdir -p "$DECOY_DIR/src/billing" "$DECOY_DIR/tests"
    cat > "$DECOY_DIR/package.json" <<'JSON'
{
  "name": "billing",
  "private": true,
  "scripts": {
    "test": "vitest run"
  }
}
JSON
    cat > "$DECOY_DIR/src/billing/usePayment.ts" <<'TS'
export function usePayment() {
  return { status: "idle" };
}
TS
    cat > "$DECOY_DIR/src/billing/PaymentForm.tsx" <<'TS'
export function PaymentForm() {
  return null;
}
TS
    cat > "$DECOY_DIR/tests/checkout.spec.ts" <<'TS'
import { test } from "vitest";

test.todo("charges the saved card");
TS
    # Single-quoted on purpose (hence the shellcheck directive): the PANE's
    # shell expands $(date) live on every loop iteration; ours must not.
    # Prints a fresh line every few seconds so the pane reads as alive.
    # shellcheck disable=SC2016
    DECOY_CMD='clear; echo "billing — test watcher"; while :; do echo "$(date +%H:%M:%S)  watching  usePayment.ts  PaymentForm.tsx  checkout.spec.ts"; sleep 3; done'
  fi

  # `open -na … --args` delivers the args ONLY to a freshly launched instance.
  # Against an already-running Ghostty it degrades to a bare reopen: a new tab
  # in the existing window, no --working-directory, no `-e claude` — the scene
  # silently never exists (field incident 2026-07-21, the run "succeeded").
  # Refuse instead: the claude scene requires launching Ghostty ourselves.
  if pgrep -xiq ghostty; then
    echo "Ghostty is already running — its instance would swallow our launch args (no staged window, no claude). Quit Ghostty (or record from a machine/session where it is closed) and rerun." >&2
    exit 1
  fi
  LAUNCHED_GHOSTTY=1
  TTYS_BEFORE=""
  # Ghostty opens the pane directly on the scene command, cwd pinned to the
  # staged repo, with an opaque dark look + big font passed as CLI config
  # (Ghostty has no scriptable per-tab colors like Terminal). `-e` MUST be last —
  # everything after it is the command Ghostty runs. --window-width/-height are
  # grid CELLS, a rough first size that the AX resize below corrects to the
  # capture region. herdr mode runs the herdr CLIENT here (`herdr --session` =
  # launch or attach the isolated named session, which we just proved is not
  # running); claude then starts INSIDE a herdr pane over the socket, below.
  if [[ "$TERMINAL_AGENT" == "herdr" ]]; then
    SCENE_EXEC=(-e "$HERDR_BIN" --session "$DEMO_HERDR_SESSION")
    # From here the demo owns the session name (the stale-delete above proved
    # nothing was running under it) — cleanup stops+deletes it even if the
    # server only finishes coming up after a mid-staging abort.
    HERDR_SESSION_STARTED=1
    echo "Launching Ghostty ($GHOSTTY_APP) in $REPO_DIR with herdr ($HERDR_BIN, session $DEMO_HERDR_SESSION)..."
  else
    SCENE_EXEC=(-e "$CLAUDE_BIN")
    echo "Launching Ghostty ($GHOSTTY_APP) in $REPO_DIR with claude ($CLAUDE_BIN)..."
  fi
  open -na "$GHOSTTY_APP" --args \
    --working-directory="$REPO_DIR" \
    --title="webapp" \
    --font-family="Menlo" \
    --font-size=21 \
    --background=1e1e1e \
    --foreground=e6e6e6 \
    --window-width=100 \
    --window-height=30 \
    "${SCENE_EXEC[@]}"
  for _ in $(seq 1 20); do pgrep -xiq ghostty && break; sleep 0.5; done
  pgrep -xiq ghostty || { echo "Ghostty did not launch." >&2; exit 1; }
  sleep 4
  position_scene_window "$SCENE_APP"
  sleep 1

  # Folder-trust dialog acceptance (BEFORE any dictated text exists; a no-op on
  # an already-trusted folder). Same one-Return discipline as the shell path.
  # Address Ghostty by bundle id (not display name) — the app's own reader does
  # too, and a by-name tell is fragile under localization / name collisions.
  # herdr mode skips this: claude is not running yet (it starts inside a herdr
  # pane below, and its trust dialog is answered pane-exactly over the socket).
  if [[ "$TERMINAL_AGENT" == "claude" ]]; then
    osascript -e "tell application id \"$GHOSTTY_BUNDLE_ID\" to activate" >/dev/null 2>&1 || true
    assert_scene_frontmost "folder-trust Return"
    osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1 || true
    sleep 3
  fi

  # Capability check + cleanup tty: ask Ghostty for the focused pane's tty using
  # the SAME AppleScript the app's join uses. A /dev/tty result proves Ghostty
  # exposes the `tty` term (>=1.4). Whether that pane is OURS is decided below.
  # IMPORTANT: this probe consults the Automation grant of the app running THIS
  # script (Terminal / the runner shell), which is SEPARATE from the app's own
  # localvoxtral->Ghostty grant that the join relies on (see final.md checklist).
  GTTY_ERR="$DEMO_STAGE/ghostty-tty.err"
  GHOSTTY_TTY="$(osascript \
    -e 'with timeout of 3 seconds' \
    -e "tell application id \"$GHOSTTY_BUNDLE_ID\" to get tty of focused terminal of selected tab of front window" \
    -e 'end timeout' 2>"$GTTY_ERR")" || GHOSTTY_TTY=""
  if [[ "$GHOSTTY_TTY" == /dev/tty* ]]; then
    echo "Ghostty focused-pane tty: $GHOSTTY_TTY"
    # Only trust this tty for surgical `pkill -t` cleanup when it is PROVABLY
    # ours — otherwise cleanup could kill an owner's pre-existing claude session.
    #   * we launched Ghostty ourselves  -> the only pane is ours.
    #   * Ghostty was already running     -> ours only if this tty did NOT exist
    #     in the pre-launch snapshot (and the snapshot was actually readable).
    # Any ambiguity leaves TERMINAL_TTY empty, so cleanup skips the kill; the
    # LAUNCHED_GHOSTTY==1 quit path is then the only teardown, which is safe.
    if [[ "$LAUNCHED_GHOSTTY" == 1 ]]; then
      TERMINAL_TTY="$GHOSTTY_TTY"
    elif [[ -n "$TTYS_BEFORE" ]] && ! grep -Fxq "$GHOSTTY_TTY" <<<"$TTYS_BEFORE"; then
      TERMINAL_TTY="$GHOSTTY_TTY"
      echo "Identified our new pane by set difference against the pre-launch snapshot."
    else
      echo "WARNING: Ghostty was already running and this run cannot prove which pane is ours (the focused pane pre-existed our launch, or the pane list was unreadable). Skipping surgical pane cleanup to avoid killing the owner's session." >&2
    fi
  elif grep -q -- '-1700' "$GTTY_ERR" 2>/dev/null; then
    # -1700: `tty` is not in Ghostty's dictionary (pre-1.4). The TTY join cannot
    # resolve, so fail loudly rather than record a scene whose grounding no-ops.
    echo "This Ghostty is too old to expose the focused-pane tty (AppleScript -1700). Install Ghostty tip (brew install --cask ghostty@tip) and rerun." >&2
    exit 1
  else
    # -1743 (Automation denied to THIS script's app) or any other error. The
    # app's OWN grant is what the join needs, so this is a warning, not fatal.
    # Surface the actual stderr so a compile/usage error in the probe is not
    # silently misreported as a consent problem.
    echo "WARNING: could not read Ghostty's focused-pane tty from this script (Automation not granted to the app running the script, a compile error, or a transient failure). The join depends on the localvoxtral->Ghostty grant, which is separate. Surgical pane cleanup is unavailable this run." >&2
    echo "  osascript stderr: $(tr '\n' ' ' <"$GTTY_ERR" 2>/dev/null)" >&2
  fi
  rm -f "$GTTY_ERR"

  if [[ "$TERMINAL_AGENT" == "herdr" ]]; then
    # ---- herdr pane staging: CLI/socket only, no synthetic keystrokes --------
    # We just launched the herdr client in Ghostty; wait for its server to
    # answer on the demo session's socket and expose the initial pane.
    echo "Waiting for the herdr demo session ($DEMO_HERDR_SESSION) to come up..."
    HERDR_CLAUDE_PANE=""
    HERDR_DEADLINE=$(( SECONDS + 30 ))
    until [[ -n "$HERDR_CLAUDE_PANE" ]]; do
      if (( SECONDS >= HERDR_DEADLINE )); then
        echo "herdr session $DEMO_HERDR_SESSION never answered \`pane list\` within 30s — aborting." >&2
        exit 1
      fi
      # Compact one-line JSON: {"id":...,"result":{"panes":[{"pane_id":"...",...
      HERDR_CLAUDE_PANE="$(herdr_cli pane list 2>/dev/null \
        | grep -o '"pane_id":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)"
      [[ -n "$HERDR_CLAUDE_PANE" ]] || sleep 1
    done
    echo "herdr initial pane: $HERDR_CLAUDE_PANE"

    # Second pane: the decoy watcher, split to the RIGHT of the claude pane in
    # the fake billing repo. `pane split` leaves focus unchanged by default
    # (--no-focus states it explicitly), so the claude pane keeps the composer.
    # The split response is the new pane: .result.pane.pane_id.
    HERDR_SPLIT_OUT="$(herdr_cli pane split --pane "$HERDR_CLAUDE_PANE" --direction right --cwd "$DECOY_DIR" --no-focus 2>&1)" \
      || { echo "herdr pane split failed: $HERDR_SPLIT_OUT" >&2; exit 1; }
    HERDR_DECOY_PANE="$(grep -o '"pane_id":"[^"]*"' <<<"$HERDR_SPLIT_OUT" | head -n 1 | cut -d'"' -f4 || true)"
    [[ -n "$HERDR_DECOY_PANE" && "$HERDR_DECOY_PANE" != "$HERDR_CLAUDE_PANE" ]] \
      || { echo "Could not identify the new decoy pane (split response: $HERDR_SPLIT_OUT)." >&2; exit 1; }
    echo "herdr decoy pane:   $HERDR_DECOY_PANE"
    sleep 1 # let the new pane's shell finish spawning before typing into it
    # `pane run` submits text + Enter atomically into the pane's shell.
    herdr_cli pane run "$HERDR_DECOY_PANE" "$DECOY_CMD" >/dev/null \
      || { echo "Failed to start the decoy watcher in pane $HERDR_DECOY_PANE." >&2; exit 1; }

    # Claude in the FOCUSED pane, cd'd explicitly so the session cwd is the
    # staged repo regardless of the pane shell's starting directory.
    echo "Starting claude inside herdr pane $HERDR_CLAUDE_PANE..."
    herdr_cli pane run "$HERDR_CLAUDE_PANE" "cd $(printf %q "$REPO_DIR") && $(printf %q "$CLAUDE_BIN")" >/dev/null \
      || { echo "Failed to start claude in pane $HERDR_CLAUDE_PANE." >&2; exit 1; }
    sleep 6
    # Folder-trust dialog acceptance, pane-exact over the socket (a no-op Enter
    # on an empty composer when the folder is already trusted).
    herdr_cli pane send-keys "$HERDR_CLAUDE_PANE" Enter >/dev/null || true
    sleep 3

    # The dictated beats land in whatever pane herdr focuses — prove it is the
    # claude pane, or the demo would stream text into the decoy.
    if ! herdr_cli pane get "$HERDR_CLAUDE_PANE" | grep -q '"focused":true'; then
      echo "herdr focus is NOT on the claude pane ($HERDR_CLAUDE_PANE) — the beats would land in the wrong pane. Aborting." >&2
      exit 1
    fi
  fi

  # Staged FIRST prompt: submitted so the plugin's UserPromptSubmit +
  # PostToolUse(Read) hooks register this session's prior prompt and
  # recently-read file BEFORE beat 2 — the join + grounding are resolved at
  # beat 2's dictation START. Read-only, so the turn is fast.
  #
  # This submit is the ENTIRE mechanism that gives beat 2 its prior-prompt /
  # recent-file grounding, so it must NOT be swallowed. Fail fast on failure.
  echo "Submitting the staged setup prompt (grounds beat 2): \"$DEMO_LINE_CLAUDE_SETUP\""
  if [[ "$TERMINAL_AGENT" == "herdr" ]]; then
    # Pane-exact over the socket: `pane run` is bracketed-paste aware and
    # submits text + Enter atomically into claude's composer — no focus race.
    herdr_cli pane run "$HERDR_CLAUDE_PANE" "$DEMO_LINE_CLAUDE_SETUP" >/dev/null \
      || { echo "Setup-prompt pane run failed; beat 2 would ground on nothing. Aborting." >&2; exit 1; }
  else
    # claude mode: typed (not dictated) into the frontmost Ghostty window. If
    # focus slipped (trust dialog still up, wrong window frontmost) the
    # keystrokes are lost and the demo would silently record with the feature
    # no-op'd — fail fast on either failure.
    osascript -e "tell application id \"$GHOSTTY_BUNDLE_ID\" to activate" >/dev/null 2>&1 || true
    sleep 1
    assert_scene_frontmost "staged setup prompt"
    osascript "$KEYSTROKE_OSA" "$DEMO_LINE_CLAUDE_SETUP" \
      || { echo "Setup-prompt keystroke failed (focus lost?); beat 2 would ground on nothing. Aborting." >&2; exit 1; }
    sleep 0.5
    osascript -e 'tell application "System Events" to key code 36' \
      || { echo "Setup-prompt submit (Return) failed; beat 2 would ground on nothing. Aborting." >&2; exit 1; }
  fi
  sleep "$DEMO_CLAUDE_SETUP_SECONDS"
else
  # ---- shell scene: Terminal.app (unchanged honest fallback) -------------------
  pgrep -xq Terminal || LAUNCHED_TERMINAL_APP=1
  SHELL_CMD="cd $(printf %q "$REPO_DIR") && exec /usr/bin/env ZDOTDIR=$(printf %q "$ZDOT_DIR") /bin/zsh -i"
  # AppleScript lives in a temp FILE, never in a heredoc inside $(...): the
  # runner executes this with /bin/bash 3.2, whose command-substitution parser
  # naively scans heredoc bodies and chokes on their quotes/parens — the first
  # hands-free take died exactly there, with a bogus exit 0 on top.
  STAGE_OSA="$DEMO_STAGE/stage-terminal.applescript"
  cat > "$STAGE_OSA" <<'OSA'
on run argv
    tell application "Terminal"
        activate
        set demoTab to do script (item 1 of argv)
        delay 1
        set windowID to id of front window
        set ttyName to tty of demoTab
        -- Pin the tab title to the absolute repo path: RepoVocabulary only
        -- resolves a cwd from a /-prefixed path run in the window title
        -- (Terminal's bare "webapp" basename is explicitly not resolvable).
        try
            set custom title of demoTab to (item 2 of argv)
            set title displays custom title of demoTab to true
        end try
        -- Explicit OPAQUE colors + big font so terminal text is legible at
        -- README width. Never the "Pro" profile: it is translucent and the
        -- recording shows the desktop (and whatever is on it) through the
        -- window — take 2 leaked real Finder windows that way. Per-tab
        -- only: nothing is persisted to Terminal preferences.
        try
            set background color of demoTab to {0, 0, 0}
            set normal text color of demoTab to {59000, 59000, 59000}
            set bold text color of demoTab to {65535, 65535, 65535}
            set cursor color of demoTab to {45000, 45000, 45000}
        end try
        try
            set font name of demoTab to "Menlo"
            set font size of demoTab to 21
        end try
        return (windowID as text) & " " & ttyName
    end tell
end run
OSA
  TERMINAL_INFO="$(osascript "$STAGE_OSA" "$SHELL_CMD" "$REPO_DIR")"
  TERMINAL_WINDOW_ID="${TERMINAL_INFO%% *}"
  TERMINAL_TTY="${TERMINAL_INFO##* }"
  if [[ -z "$TERMINAL_WINDOW_ID" || -z "$TERMINAL_TTY" || "$TERMINAL_TTY" != /dev/* ]]; then
    echo "Failed to stage the Terminal window (osascript returned: '$TERMINAL_INFO')." >&2
    exit 1
  fi
  echo "Terminal demo window id $TERMINAL_WINDOW_ID on $TERMINAL_TTY"

  # If we launched Terminal ourselves it may have opened a default startup
  # window too — close everything that is not the demo window so nothing else
  # shows through the capture region.
  if [[ "$LAUNCHED_TERMINAL_APP" == 1 ]]; then
    osascript -e "tell application \"Terminal\" to close (every window whose id is not $TERMINAL_WINDOW_ID)" >/dev/null 2>&1 || true
  fi

  position_scene_window "$SCENE_APP"
  sleep 1
fi

cue() { # <beat-label> <sentence>
  echo
  echo "==================================================================="
  echo "  $1"
  echo "  SAY: \"$2\""
  echo "==================================================================="
  afplay /System/Library/Sounds/Tink.aiff >/dev/null 2>&1 || true
}

speak_or_wait() { # <sentence>
  if [[ -n "$DEMO_SAY_DEVICE" ]]; then
    say -a "$DEMO_SAY_DEVICE" -r 180 "$1"
    sleep 1
  else
    sleep "$DEMO_SPEAK_SECONDS"
  fi
}

# --- warm the AGENT-profile polish prompt cache off-camera ------------------------
# The app's own launch warmup (PolishPromptWarmup) primes the STANDARD
# profile's prefix slot; dictating into a terminal selects the AGENT profile,
# whose first polish would pay the full static-prefix prefill ON CAMERA
# (~2.6 s cold vs ~0.4 s warm). One throwaway overlay dictation with the
# staged terminal focused runs the real agent-profile request end to end and
# checkpoints the exact prefix the on-camera beat reuses; its residue is then
# cleared off-camera.
echo "Warming the agent-profile polish prompt cache off-camera..."
osascript -e "tell $SCENE_TELL to activate" >/dev/null 2>&1 || true
sleep 1
cue "WARMUP (off-camera, not recorded). Speak after the beep." "Ready to record the demo."
tap_hotkey
sleep 1
speak_or_wait "Ready to record the demo."
tap_hotkey
sleep $(( DEMO_COMMIT_SECONDS + 4 )) # cold polish — wait it out fully before clearing
if [[ "$TERMINAL_AGENT" == "herdr" ]]; then
  # Ctrl+C clears the composer text the warmup committed — pane-exact over the
  # socket, so it cannot land anywhere but claude's composer.
  herdr_cli pane send-keys "$HERDR_CLAUDE_PANE" ctrl+c >/dev/null
elif [[ "$TERMINAL_AGENT" == "claude" ]]; then
  # Ctrl+C clears the composer text the warmup committed.
  osascript -e 'tell application "System Events" to keystroke "c" using control down' >/dev/null
else
  # Kill the committed line, then run a literal `clear` — the ONLY Return
  # this script ever sends to a shell, and only for that exact staged text.
  osascript -e 'tell application "System Events" to keystroke "u" using control down' >/dev/null
  sleep 0.5
  osascript -e 'tell application "System Events" to keystroke "clear"' >/dev/null
  sleep 0.5
  osascript -e 'tell application "System Events" to key code 36' >/dev/null
fi
sleep 1.5

# --- GUARD: the scene app must actually own the screen before frames roll -------
# A region capture records the active Space, not the windows we staged — if a
# fullscreen app (or anything the user raised meanwhile) is frontmost, staging
# happened somewhere invisible and we would record the user's screen instead of
# the scene. Assert frontmost == the scene process; abort loudly otherwise.
FRONTMOST_APP="$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)"
if [[ "$(printf '%s' "$FRONTMOST_APP" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$SCENE_APP" | tr '[:upper:]' '[:lower:]')" ]]; then
  echo "Frontmost app is '${FRONTMOST_APP:-unknown}', not the staged $SCENE_APP — the capture region does not show the scene (fullscreen app / another Space / user activity). Aborting before recording anything." >&2
  exit 1
fi

# --- record ----------------------------------------------------------------------
mkdir -p "$OUT_DIR"
rm -f "$RAW_MOV" "$OUT_MP4"
CAPTURE_FLAGS=(-v -x)
[[ "$DEMO_CAPTURE_AUDIO" == 1 ]] && CAPTURE_FLAGS+=(-g)
screencapture "${CAPTURE_FLAGS[@]}" -R "${REGION_X},${REGION_Y},${DEMO_WIDTH},${DEMO_HEIGHT}" "$RAW_MOV" &
RECORDER_PID=$!
sleep 2

# The capture can be stopped from OUTSIDE at any time via the menu-bar
# recording indicator — exactly what happens when the owner is actively using
# the Mac (take 5 died that way and its 2-frame capture showed the owner's
# browser). A dead recorder means a partial capture of whoever is really at
# the machine: throw it away and fail loudly instead of uploading it.
recorder_alive_or_abort() {
  kill -0 "$RECORDER_PID" 2>/dev/null && return 0
  RECORDER_PID=""
  rm -f "$RAW_MOV" "$OUT_MP4"
  echo "The screen recorder stopped before the scene finished — the GUI session is likely IN USE by its human (the capture can be stopped from the menu-bar recording indicator). Re-run when the Mac is free." >&2
  exit 1
}
recorder_alive_or_abort

osascript -e "tell $SCENE_TELL to activate" >/dev/null 2>&1 || true
sleep 1

# Beat 1 — hold: live dictation streams word-by-word into the terminal prompt.
# No Return is ever pressed: the streamed text sits at the prompt, unsubmitted.
cue "BEAT 1 — live streaming into the terminal (hold). Speak after the beep, keep talking." "$DEMO_LINE_LIVE"
if [[ -n "$DEMO_SAY_DEVICE" ]]; then
  press_hotkey
  sleep 1.2 # get past the hold threshold so live dictation runs before the TTS starts
  say -a "$DEMO_SAY_DEVICE" -r 180 "$DEMO_LINE_LIVE"
  sleep 1.5
  release_hotkey
else
  hold_hotkey "$DEMO_SPEAK_SECONDS"
fi
sleep 3 # stop finalization + held-back tail flush

# Transition — clear the prompt line WITHOUT Return (Return would submit!).
# A single Ctrl+C gives a fresh prompt line in zsh and clears Claude Code's
# composer (a second one would exit claude — never send two). herdr mode sends
# it pane-exactly over the socket instead of as a synthetic keystroke.
if [[ "$TERMINAL_AGENT" == "herdr" ]]; then
  herdr_cli pane send-keys "$HERDR_CLAUDE_PANE" ctrl+c >/dev/null
else
  osascript -e 'tell application "System Events" to keystroke "c" using control down' >/dev/null
fi
sleep 1.5

# Beat 2 — tap: overlay buffer, spoken symbol forms, agent-profile polish,
# and the committed text lands in the terminal.
cue "BEAT 2 — overlay + agent polish (tap). Speak after the beep." "$DEMO_LINE_OVERLAY"
HERDR_ASSERT_LOG_START="$(date '+%Y-%m-%d %H:%M:%S')" # herdr join proof window
tap_hotkey
sleep 1
speak_or_wait "$DEMO_LINE_OVERLAY"
tap_hotkey
echo "Committing (agent-profile polish + insert)..."
sleep "$DEMO_COMMIT_SECONDS"
sleep 3 # let the committed text sit on screen

# VERIFICATION (herdr mode) — the demo's whole claim is that beat 2 was
# grounded through the HERDR PANE JOIN with pane-exact screen context. Prove
# both from the app's own unified log for beat 2's window, or destroy the
# capture: a take where the join silently abstained (falling back to
# no-context) is a lying demo, and "Never fake a running agent" extends to
# never faking a working join. The two lines asserted are emitted by
# TerminalScreenClaudeJoin.resolveViaHerdr and
# SocketPaneScreenContext.captureAtStart (subsystem com.localvoxtral,
# category ClaudeContext); every abstention logs its outcome publicly, so the
# failure path prints whatever the join said instead.
if [[ "$TERMINAL_AGENT" == "herdr" ]]; then
  echo "Verifying the herdr pane join from the app log..."
  HERDR_JOIN_OK=0
  HERDR_SCREEN_OK=0
  HERDR_LOG_SLICE=""
  HERDR_VERIFY_DEADLINE=$(( SECONDS + 20 )) # log ingestion can lag a little
  while :; do
    HERDR_LOG_SLICE="$(log show --info --start "$HERDR_ASSERT_LOG_START" \
      --predicate 'subsystem == "com.localvoxtral" AND category == "ClaudeContext"' 2>/dev/null || true)"
    grep -qF 'joined to a live Claude session via herdr pane' <<<"$HERDR_LOG_SLICE" && HERDR_JOIN_OK=1
    grep -qF 'Socket pane screen context captured at start' <<<"$HERDR_LOG_SLICE" && HERDR_SCREEN_OK=1
    [[ "$HERDR_JOIN_OK" == 1 && "$HERDR_SCREEN_OK" == 1 ]] && break
    (( SECONDS >= HERDR_VERIFY_DEADLINE )) && break
    sleep 2
  done
  if [[ "$HERDR_JOIN_OK" != 1 || "$HERDR_SCREEN_OK" != 1 ]]; then
    rm -f "$RAW_MOV" "$OUT_MP4" # never leave a lying capture behind
    [[ "$HERDR_JOIN_OK" != 1 ]] \
      && echo "HERDR VERIFICATION FAILED: no 'joined … via herdr pane' in the app log for beat 2 — the join abstained or fell back, so the recorded beat was NOT grounded by the pane join." >&2
    [[ "$HERDR_SCREEN_OK" != 1 ]] \
      && echo "HERDR VERIFICATION FAILED: no 'Socket pane screen context captured at start' — the pane-exact pane.read never attached." >&2
    echo "Likely causes: the app's Automation->Ghostty grant is missing (tty read blocked), another live herdr-hosted Claude session is registered (the resolver refuses to guess between sockets), the plugin hooks did not fire, or the screen-context consent gate rejected." >&2
    echo "ClaudeContext log for the window (join outcomes are public):" >&2
    grep -iE 'herdr|joined|marker|abstain|screen' <<<"$HERDR_LOG_SLICE" >&2 \
      || echo "  (no ClaudeContext lines at all — did the hooks/plugin publish this session?)" >&2
    exit 1
  fi
  echo "herdr join verified: pane join + pane-exact screen context both present in the app log."
fi

# Ending (claude/herdr modes) — genuinely submit the polished prompt and record
# the real response. This is the ONE deliberate Return on dictated text, owner-
# approved: one small read-only request against the owner's Claude usage.
if [[ ( "$TERMINAL_AGENT" == "claude" || "$TERMINAL_AGENT" == "herdr" ) && "$DEMO_SUBMIT_PROMPT" == 1 ]]; then
  echo "Submitting the polished prompt to claude (recording the response for ${DEMO_RESPONSE_SECONDS}s)..."
  if [[ "$TERMINAL_AGENT" == "herdr" ]]; then
    # Pane-exact Enter over the socket — it can only reach claude's composer.
    herdr_cli pane send-keys "$HERDR_CLAUDE_PANE" Enter >/dev/null
  else
    osascript -e "tell $SCENE_TELL to activate" >/dev/null 2>&1 || true
    assert_scene_frontmost "polished-prompt submit"
    osascript -e 'tell application "System Events" to key code 36' >/dev/null
  fi
  sleep "$DEMO_RESPONSE_SECONDS"
fi

recorder_alive_or_abort
kill -INT "$RECORDER_PID"
wait "$RECORDER_PID" 2>/dev/null || true
RECORDER_PID=""
[[ -s "$RAW_MOV" ]] || { echo "screencapture produced no output at $RAW_MOV" >&2; exit 1; }
echo "Raw capture: $RAW_MOV"

# --- encode ----------------------------------------------------------------------
if command -v ffmpeg >/dev/null; then
  AUDIO_OPTS=(-an)
  [[ "$DEMO_CAPTURE_AUDIO" == 1 ]] && AUDIO_OPTS=(-c:a aac -b:a 160k)
  ffmpeg -hide_banner -loglevel error -y -i "$RAW_MOV" \
    -vf "scale=${DEMO_WIDTH}:-2:flags=lanczos,fps=30" \
    -c:v libx264 -crf 20 -preset slow -pix_fmt yuv420p -movflags +faststart \
    "${AUDIO_OPTS[@]}" "$OUT_MP4"
  echo "Encoded:     $OUT_MP4 ($(du -h "$OUT_MP4" | cut -f1))"
  echo
  echo "Next: review it (open $OUT_MP4), then drag-drop it into a GitHub PR/issue"
  echo "comment to get a user-attachments URL, and put that URL on its own line"
  echo "where the demo goes (README.md for the hero demo; docs/coding-agents.md"
  echo "for the herdr scene)."
else
  echo "ffmpeg missing — upload $RAW_MOV as-is or install ffmpeg and re-run the encode."
fi

DEMO_COMPLETED=1
