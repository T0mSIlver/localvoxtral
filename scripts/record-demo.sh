#!/usr/bin/env bash
set -euo pipefail

# Record the README demo video as H.264:
#   dist/demo/demo.mp4      (encoded, ready to drag-drop into a GitHub PR/issue
#                            comment — GitHub only renders inline video from
#                            user-attachments uploads, so that step is manual)
#   dist/demo/demo-raw.mov  (raw capture, kept so the encode can be redone)
#
# The scene is TERMINAL-CENTRIC — localvoxtral is the dictation app to talk to
# your coding agents. The script stages a small git repo, opens Terminal.app in
# it (Terminal is always installed; when a logged-in `claude` CLI is available
# it launches a real Claude Code session in that window instead of a bare
# shell — never a faked one), and records two beats:
#
#   Beat 1  hold Right Command -> live dictation streams word-by-word into the
#           terminal prompt while speaking (the differentiator; no stray
#           newline ever submits the prompt)
#   Beat 2  tap Right Command  -> overlay buffer -> speak a line with spoken
#           symbol forms -> tap -> the agent-profile LLM polish writes
#           `--flags` / `file.ts` and the commit lands in the terminal
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
#   - Accessibility     (posts the Right Command gesture, drives Terminal)
#   - Screen Recording  (screencapture -v)
#   - Microphone        (only when DEMO_CAPTURE_AUDIO=1, the default)
# The app itself must already have its mic + Accessibility grants and a
# working dictation backend (managed local installed, or your endpoints up).
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
#   DEMO_TERMINAL_AGENT           auto (default) | claude | shell — what runs in
#                                 the staged Terminal window. auto uses a real
#                                 Claude Code session when `claude` is on the
#                                 login-shell PATH and logged in, else a plain
#                                 zsh prompt in the staged repo.
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
# Beat 1 (hold -> live streaming): a technical sentence a developer would say
# to a coding agent; streamed raw, so no spoken symbol forms here.
DEMO_LINE_LIVE="${DEMO_LINE_LIVE:-Refactor the retry logic in the websocket client, and add a unit test for the reconnect path.}"
# Beat 2 (tap -> overlay + agent-profile polish): spoken symbol forms the
# polish profile turns into written forms (index.ts, --no-verify).
DEMO_LINE_OVERLAY="${DEMO_LINE_OVERLAY:-Open index dot t s and run the tests again, then commit with dash dash no verify.}"
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
  auto|claude|shell) ;;
  *) echo "DEMO_TERMINAL_AGENT must be auto, claude, or shell (got: $DEMO_TERMINAL_AGENT)" >&2; exit 1;;
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
TERMINAL_WINDOW_ID=""
TERMINAL_TTY=""
DEMO_STAGE=""
ORIGINAL_DARK_MODE=""
ANNOUNCED_TAKEOVER=0
DEMO_COMPLETED=0
cleanup() {
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
  if [[ -n "$DEMO_STAGE" ]]; then
    rm -rf "$DEMO_STAGE"
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
# A real Claude Code session is the ideal scene; fall back to a plain zsh
# prompt in the staged repo when the CLI is absent or not logged in. Never
# fake a running agent — a bare shell is honest, a painted TUI is not.
TERMINAL_AGENT="shell"
CLAUDE_BIN=""
if [[ "$DEMO_TERMINAL_AGENT" != "shell" ]]; then
  # Resolve the absolute binary via the login shell: the staged demo zsh has a
  # bare ZDOTDIR, so the user's own PATH additions won't exist inside it.
  CLAUDE_BIN="$(zsh -lc 'command -v claude' 2>/dev/null || true)"
  if [[ -n "$CLAUDE_BIN" ]] && grep -q '"oauthAccount"' "$HOME/.claude.json" 2>/dev/null; then
    TERMINAL_AGENT="claude"
  elif [[ "$DEMO_TERMINAL_AGENT" == "claude" ]]; then
    echo "DEMO_TERMINAL_AGENT=claude, but no usable claude CLI (binary missing from the login-shell PATH, or not logged in)." >&2
    exit 1
  fi
fi
echo "Terminal scene agent: $TERMINAL_AGENT"

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

# --- stage the demo repo + Terminal window inside the capture region --------------
DEMO_STAGE="$(mktemp -d -t lv-demo-stage)"
REPO_DIR="$DEMO_STAGE/webapp"
ZDOT_DIR="$DEMO_STAGE/zdot"
mkdir -p "$REPO_DIR/src" "$ZDOT_DIR"

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
cat > "$REPO_DIR/src/client.test.ts" <<'TS'
import { test } from "vitest";

test.todo("reconnects after a dropped connection");
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
        -- Dark Pro profile + big font so terminal text is legible at README
        -- width. Per-tab only: nothing is persisted to Terminal preferences.
        try
            set current settings of demoTab to settings set "Pro"
        end try
        try
            set font name of demoTab to "Menlo"
            set font size of demoTab to 21
        end try
        return (windowID as text) & " " & ttyName
    end tell
end run
OSA
TERMINAL_INFO="$(osascript "$STAGE_OSA" "$SHELL_CMD")"
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

# The window fills the region exactly so the recording never shows whatever
# else is on the desktop.
osascript >/dev/null <<OSA
tell application "Terminal" to activate
tell application "System Events" to tell process "Terminal"
  set position of front window to {$REGION_X, $REGION_Y}
  set size of front window to {$DEMO_WIDTH, $DEMO_HEIGHT}
end tell
OSA
sleep 1

# A real Claude Code session, launched visibly in the staged window. The only
# Return ever pressed is the folder-trust-dialog acceptance BEFORE any
# dictated text exists (on an already-trusted folder that Return hits the
# empty composer and is a no-op); once dictated text is on screen nothing
# ever submits it.
if [[ "$TERMINAL_AGENT" == "claude" ]]; then
  echo "Launching claude ($CLAUDE_BIN) in the demo window..."
  LAUNCH_OSA="$DEMO_STAGE/launch-claude.applescript"
  cat > "$LAUNCH_OSA" <<'OSA'
on run argv
    tell application "Terminal"
        do script (item 1 of argv) in selected tab of window id ((item 2 of argv) as integer)
    end tell
end run
OSA
  osascript "$LAUNCH_OSA" "$CLAUDE_BIN" "$TERMINAL_WINDOW_ID" >/dev/null
  sleep 10
  osascript -e 'tell application "Terminal" to activate' >/dev/null
  osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1 || true
  sleep 3
fi

# --- record ----------------------------------------------------------------------
mkdir -p "$OUT_DIR"
rm -f "$RAW_MOV" "$OUT_MP4"
CAPTURE_FLAGS=(-v -x)
[[ "$DEMO_CAPTURE_AUDIO" == 1 ]] && CAPTURE_FLAGS+=(-g)
screencapture "${CAPTURE_FLAGS[@]}" -R "${REGION_X},${REGION_Y},${DEMO_WIDTH},${DEMO_HEIGHT}" "$RAW_MOV" &
RECORDER_PID=$!
sleep 2

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

osascript -e 'tell application "Terminal" to activate' >/dev/null
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
# composer (a second one would exit claude — never send two).
osascript -e 'tell application "System Events" to keystroke "c" using control down' >/dev/null
sleep 1.5

# Beat 2 — tap: overlay buffer, spoken symbol forms, agent-profile polish,
# and the committed text lands in the terminal.
cue "BEAT 2 — overlay + agent polish (tap). Speak after the beep." "$DEMO_LINE_OVERLAY"
tap_hotkey
sleep 1
speak_or_wait "$DEMO_LINE_OVERLAY"
tap_hotkey
echo "Committing (agent-profile polish + insert)..."
sleep "$DEMO_COMMIT_SECONDS"
sleep 3 # let the committed text sit on screen

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
  echo "in README.md where the demo goes."
else
  echo "ffmpeg missing — upload $RAW_MOV as-is or install ffmpeg and re-run the encode."
fi

DEMO_COMPLETED=1
