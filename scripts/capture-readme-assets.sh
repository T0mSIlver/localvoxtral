#!/usr/bin/env bash
set -euo pipefail

# Regenerate the README screenshots:
#   assets/popover.png                     (menu bar menu)
#   assets/settings-realtime-endpoint.png  (Settings > Realtime Endpoint)
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
# demo.gif is not automated — record it by hand.

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script drives a macOS app — run it on the Mac." >&2
  exit 1
fi

APP_PATH="${1:-dist/localvoxtral.app}"
APP_PROCESS="localvoxtral"
ASSETS_DIR="assets"
TAB_NAMES=("Realtime Endpoint" "Dictation" "Text Processing")
TAB_FILES=("settings-realtime-endpoint.png" "settings-dictation.png" "settings-text-processing.png")

[[ -d "$APP_PATH" ]] || { echo "App bundle not found: $APP_PATH (build with ./scripts/package_app.sh)" >&2; exit 1; }
[[ -d "$ASSETS_DIR" ]] || { echo "Run from the repo root ($ASSETS_DIR/ not found)." >&2; exit 1; }

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
    print("MISSING Accessibility: System Settings > Privacy & Security > Accessibility — enable the terminal app you are running this from, then rerun.")
    ok = false
}
if !CGPreflightScreenCaptureAccess() {
    _ = CGRequestScreenCaptureAccess()
    print("MISSING Screen Recording: System Settings > Privacy & Security > Screen Recording — enable the terminal app you are running this from, then rerun.")
    ok = false
}
exit(ok ? 0 : 1)
SWIFT
swift "$PREFLIGHT" || exit 1

# --- window-id helper -------------------------------------------------------
# Prints the CGWindowID of the largest on-screen window owned by <pid> whose
# window layer is >= <min-layer> (0 = normal windows, 100+ = open menus).
HELPER="$(mktemp -t lv-windowid).swift"
trap 'rm -f "$HELPER" "$PREFLIGHT"' EXIT
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
  osascript -e "tell application \"$APP_PROCESS\" to quit" >/dev/null 2>&1 || pkill -x "$APP_PROCESS" || true
  sleep 1
fi
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
echo "Done. Review with: open $ASSETS_DIR"
