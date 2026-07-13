#!/usr/bin/env bash
set -euo pipefail

# Regenerate the README screenshots:
#   assets/popover.png                     (menu bar menu)
#   assets/settings-general.png            (Settings > General)
#   assets/settings-endpoints.png          (Settings > Endpoints)
#   assets/settings-dictation.png          (Settings > Dictation)
#   assets/settings-text-processing.png    (Settings > Text Processing)
#
# Run ON A MAC from the repo root:
#   ./scripts/capture-readme-assets.sh [path/to/localvoxtral.app]
# Default app: dist/localvoxtral.app (build it with ./scripts/package_app.sh).
#
# One-time TCC grants required for the terminal you run this from
# (System Settings > Privacy & Security):
#   - Accessibility    (System Events drives the menu and settings tabs)
#   - Screen Recording (screencapture -l reads window contents)
#
# The run takes over the GUI session (appearance switch, app launch, menus,
# synthetic keystrokes), so it announces itself audibly and waits 3 seconds
# before the first focus-stealing action, and announces completion/failure.
#
# The demo video is separate — see scripts/record-demo.sh / record-demo.yml.

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script drives a macOS app — run it on the Mac." >&2
  exit 1
fi

APP_PATH="${1:-dist/localvoxtral.app}"
APP_PROCESS="localvoxtral"
BUNDLE_ID="com.localvoxtral.app"
PERSISTENT_DEFAULTS_BACKUP="${HOME}/.localvoxtral-capture-assets.pre.plist"
PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN="${PERSISTENT_DEFAULTS_BACKUP}.had-domain"
ASSETS_DIR="assets"
TAB_NAMES=("General" "Endpoints" "Dictation" "Text Processing")
TAB_FILES=("settings-general.png" "settings-endpoints.png" "settings-dictation.png" "settings-text-processing.png")

[[ -d "$APP_PATH" ]] || { echo "App bundle not found: $APP_PATH (build with ./scripts/package_app.sh)" >&2; exit 1; }
[[ -d "$ASSETS_DIR" ]] || { echo "Run from the repo root ($ASSETS_DIR/ not found)." >&2; exit 1; }

# Defaults isolation:
# localvoxtral uses UserDefaults.standard under bundle id com.localvoxtral.app.
# This script snapshots that domain, writes only settings.onboarding_completed
# so the first-launch wizard does not cover Settings, and restores on exit.
restore_defaults() {
  if [[ ! -f "$PERSISTENT_DEFAULTS_BACKUP" ]]; then
    return
  fi

  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -f "$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN" ]]; then
    defaults import "$BUNDLE_ID" "$PERSISTENT_DEFAULTS_BACKUP" >/dev/null 2>&1 || return 1
  fi
  rm -f "$PERSISTENT_DEFAULTS_BACKUP" "$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN"
}

write_empty_defaults_backup() {
  cat >"$PERSISTENT_DEFAULTS_BACKUP" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
}

snapshot_defaults() {
  rm -f "$PERSISTENT_DEFAULTS_BACKUP" "$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN"
  if defaults export "$BUNDLE_ID" "$PERSISTENT_DEFAULTS_BACKUP" >/dev/null 2>&1; then
    : >"$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN" || return 1
  elif defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    return 1
  else
    write_empty_defaults_backup || return 1
  fi
  [[ -f "$PERSISTENT_DEFAULTS_BACKUP" ]] || return 1
}

# --- permission preflight ----------------------------------------------------
# System Events needs Accessibility; screencapture -l needs Screen Recording.
# Without them the failures are cryptic (error 1002) or silent (empty grabs),
# so check both up front and say exactly what to enable.
PREFLIGHT="$(mktemp -t lv-preflight).swift"
trap 'rm -f "$PREFLIGHT"' EXIT
cat > "$PREFLIGHT" <<'SWIFT'
import ApplicationServices
import CoreGraphics

var ok = true
if !AXIsProcessTrusted() {
    print("MISSING Accessibility: System Settings > Privacy & Security > Accessibility — enable the app that launched this script (your terminal, or the CI runner app for workflow runs), then rerun.")
    ok = false
}
if !CGPreflightScreenCaptureAccess() {
    _ = CGRequestScreenCaptureAccess()
    print("MISSING Screen Recording: System Settings > Privacy & Security > Screen Recording — enable the app that launched this script (your terminal, or the CI runner app for workflow runs), then rerun.")
    ok = false
}
exit(ok ? 0 : 1)
SWIFT
swift "$PREFLIGHT" || exit 1

# --- window-id helper -------------------------------------------------------
# Prints the CGWindowID of the largest on-screen window owned by <pid> whose
# window layer is >= <min-layer> (0 = normal windows, 100+ = open menus).
HELPER="$(mktemp -t lv-windowid).swift"
# Cleanup must also quit the app we launch below: with set -e, any failed
# capture step would otherwise strand a localvoxtral instance (and possibly
# an open menu) in the GUI session, poisoning the next run.
LAUNCHED_APP=0
ANNOUNCED_TAKEOVER=0
CAPTURE_COMPLETED=0
cleanup() {
  rm -f "$HELPER" "$PREFLIGHT"
  if [[ "$LAUNCHED_APP" == 1 ]]; then
    osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
    osascript -e "tell application \"$APP_PROCESS\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -x "$APP_PROCESS" >/dev/null 2>&1 || true
  fi
  if ! restore_defaults; then
    echo "WARNING: failed to restore defaults backup at $PERSISTENT_DEFAULTS_BACKUP; leaving it in place." >&2
  fi
  if [[ -n "${ORIGINAL_DARK_MODE:-}" ]]; then
    osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to ${ORIGINAL_DARK_MODE}" >/dev/null 2>&1 || true
  fi
  # Owner rule: announce completion audibly whenever the script took over the
  # GUI session, so an unattended run never ends silently.
  if [[ "$ANNOUNCED_TAKEOVER" == 1 ]]; then
    if [[ "$CAPTURE_COMPLETED" == 1 ]]; then
      say "capture readme assets done" >/dev/null 2>&1 || true
    else
      say "capture readme assets failed" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT INT TERM HUP

# --- OWNER RULE: audible takeover warning BEFORE any focus-stealing action ---
# Everything below drives the GUI session (appearance switch, app launch,
# menus, synthetic keystrokes) — warn the human at the Mac first.
say "capture readme assets taking control in 3" >/dev/null 2>&1 || true
ANNOUNCED_TAKEOVER=1
sleep 3

# Appearance isolation: README assets are always captured in dark mode so
# reruns are deterministic regardless of the Mac's current (possibly
# auto-switching) appearance; restored in cleanup.
ORIGINAL_DARK_MODE="$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode')"
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true'
sleep 1
cat > "$HELPER" <<'SWIFT'
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 3,
      let pid = Int(CommandLine.arguments[1]),
      let minLayer = Int(CommandLine.arguments[2])
else { exit(2) }

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (id: Int, area: Double)?
for window in windows {
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int, ownerPID == pid,
          let layer = window[kCGWindowLayer as String] as? Int, layer >= minLayer,
          minLayer > 0 || layer == 0,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Double],
          let width = bounds["Width"], let height = bounds["Height"]
    else { continue }
    let area = width * height
    if area > 10_000, area > (best?.area ?? 0) { best = (id, area) }
}
guard let best else { exit(1) }
print(best.id)
SWIFT

window_id() { # <pid> <min-layer>
  swift "$HELPER" "$1" "$2" 2>/dev/null
}

wait_for_window() { # <pid> <min-layer> [timeout-seconds]
  local deadline=$((SECONDS + ${3:-10}))
  while ((SECONDS < deadline)); do
    if id="$(window_id "$1" "$2")"; then echo "$id"; return 0; fi
    sleep 0.3
  done
  return 1
}

# --- launch a fresh instance ------------------------------------------------
if pgrep -xq "$APP_PROCESS"; then
  echo "Quitting running $APP_PROCESS instance..."
  osascript -e "tell application \"$APP_PROCESS\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do pgrep -xq "$APP_PROCESS" || break; sleep 0.5; done
  pkill -x "$APP_PROCESS" >/dev/null 2>&1 || true
  sleep 1
fi
if pgrep -xq "$APP_PROCESS"; then
  echo "A previous $APP_PROCESS instance refuses to quit; captures would show stale state. Aborting." >&2
  exit 1
fi
snapshot_defaults || { echo "Could not snapshot $BUNDLE_ID defaults; refusing to mutate owner defaults." >&2; exit 1; }
# Capture the app as a NEW USER sees it, not as this Mac happens to be set up:
# clearing the domain drops personal and demo-staged values (record-demo leaves
# a 22 pt overlay; opt-in features may be switched on), so the shots show real
# defaults. AppleLanguages pins the app's language and AppleLocale its region
# — the region is what byte/number formatting follows, so a French Mac renders
# "3,3 GB" without it; this README is English and wants "3.3 GB". All these
# keys live in the snapshotted domain and are restored on exit.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
defaults write "$BUNDLE_ID" AppleLanguages -array en-US
defaults write "$BUNDLE_ID" AppleLocale -string en_US
defaults write "$BUNDLE_ID" "settings.onboarding_completed" -bool true

# The two settings a real first-time user ends up with, which marking onboarding
# complete above would otherwise hide — so the shots depict a state that exists:
#   - the gesture: SettingsStore seeds it only on a never-launched install, and
#     the onboarding key we just wrote makes this install look launched;
#   - polishing: the wizard enables it (consent defaults on) while downloading
#     the model, and we skip the wizard.
# Keep in step with SettingsStore.seedFreshInstallDefaults and
# OnboardingViewModel.startDownloads.
defaults write "$BUNDLE_ID" "settings.modifier_only_hotkey_enabled" -bool true
defaults write "$BUNDLE_ID" "settings.llm_polishing_enabled" -bool true
LAUNCHED_APP=1
open "$APP_PATH"
for _ in $(seq 1 20); do pgrep -xq "$APP_PROCESS" && break; sleep 0.5; done
APP_PID="$(pgrep -xn "$APP_PROCESS")"
sleep 2 # let the status item settle

open_status_menu() {
  # Clicking a menu bar item blocks System Events while the menu tracks, so
  # fire it with "ignoring application responses" and give it time to open.
  osascript >/dev/null <<OSA
tell application "System Events" to tell process "$APP_PROCESS"
  ignoring application responses
    click menu bar item 1 of menu bar 2
  end ignoring
end tell
OSA
  sleep 1
}

dismiss_menu() {
  osascript -e 'tell application "System Events" to key code 53' >/dev/null # Escape
  sleep 0.5
}

# --- 1. menu ("popover") shot -----------------------------------------------
echo "Capturing $ASSETS_DIR/popover.png"
open_status_menu
if MENU_ID="$(wait_for_window "$APP_PID" 100 5)"; then
  screencapture -o -x -l "$MENU_ID" "$ASSETS_DIR/popover.png"
  dismiss_menu
else
  dismiss_menu
  echo "WARNING: could not find the open menu window; skipped popover.png" >&2
fi

# --- 2. settings tabs ---------------------------------------------------------
echo "Opening Settings..."
open_status_menu
osascript >/dev/null <<OSA
tell application "System Events" to tell process "$APP_PROCESS"
  click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
end tell
OSA
SETTINGS_ID="$(wait_for_window "$APP_PID" 0 10)" || { echo "Settings window never appeared." >&2; exit 1; }
sleep 1

for i in "${!TAB_NAMES[@]}"; do
  tab="${TAB_NAMES[$i]}"
  out="$ASSETS_DIR/${TAB_FILES[$i]}"
  echo "Capturing $out"
  osascript >/dev/null <<OSA
tell application "System Events" to tell process "$APP_PROCESS"
  click button "$tab" of toolbar 1 of window 1
end tell
OSA
  sleep 1
  SETTINGS_ID="$(window_id "$APP_PID" 0)" || { echo "Lost the settings window." >&2; exit 1; }
  screencapture -o -x -l "$SETTINGS_ID" "$out"
done

osascript -e "tell application \"$APP_PROCESS\" to quit" >/dev/null 2>&1 || true
CAPTURE_COMPLETED=1
echo "Done. Review with: open $ASSETS_DIR"
