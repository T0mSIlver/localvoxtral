#!/usr/bin/env bash
set -uo pipefail

# AX-driven packaged-app smoke drill. Run on a macOS GUI session:
#   ./scripts/ui-smoke.sh [dist/localvoxtral.app]
#
# Defaults isolation:
# localvoxtral uses UserDefaults.standard under bundle id com.localvoxtral.app.
# There is no app-code hook for a separate suite/domain, and NSUserDefaults
# command-line overrides do not move standard defaults to an isolated suite.
# This script therefore snapshots that defaults domain, forces only the smoke
# test's required managed-mode setting, and restores the snapshot on exit.

APP_PATH="${1:-dist/localvoxtral.app}"
APP_PROCESS="localvoxtral"
BUNDLE_ID="com.localvoxtral.app"
DEFAULTS_SNAPSHOT=""
HAD_DEFAULTS=0
PREFLIGHT_HELPER=""
APP_PID=""
FAILED=0
SUMMARY=()

record_pass() {
  SUMMARY+=("PASS: $1")
  printf 'PASS: %s\n' "$1"
}

record_fail() {
  SUMMARY+=("FAIL: $1")
  printf 'FAIL: %s\n' "$1" >&2
  FAILED=1
}

print_summary() {
  printf '\nUI smoke summary:\n'
  if ((${#SUMMARY[@]} == 0)); then
    printf 'FAIL: no smoke checks ran.\n'
    return
  fi
  local line
  for line in "${SUMMARY[@]}"; do
    printf '  %s\n' "$line"
  done
}

restore_defaults() {
  if [[ -z "$DEFAULTS_SNAPSHOT" ]]; then
    return
  fi

  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  if ((HAD_DEFAULTS)); then
    defaults import "$BUNDLE_ID" "$DEFAULTS_SNAPSHOT" >/dev/null 2>&1 || true
  fi
}

quit_app() {
  if ! pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
    return
  fi

  osascript -e "tell application \"$APP_PROCESS\" to quit" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if ! pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
      return
    fi
    sleep 0.5
  done
}

cleanup() {
  quit_app
  restore_defaults
  [[ -n "$PREFLIGHT_HELPER" ]] && rm -f "$PREFLIGHT_HELPER"
  [[ -n "$DEFAULTS_SNAPSHOT" ]] && rm -f "$DEFAULTS_SNAPSHOT"
}

trap cleanup EXIT

if [[ "$(uname)" != "Darwin" ]]; then
  record_fail "ui-smoke.sh drives macOS AX APIs and must run on macOS."
  print_summary
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  record_fail "App bundle not found: $APP_PATH (build with ./scripts/package_app.sh)."
  print_summary
  exit 1
fi

PREFLIGHT_STEM="$(mktemp -t localvoxtral-ui-preflight)"
PREFLIGHT_HELPER="${PREFLIGHT_STEM}.swift"
mv "$PREFLIGHT_STEM" "$PREFLIGHT_HELPER"
cat >"$PREFLIGHT_HELPER" <<'SWIFT'
import ApplicationServices
import CoreGraphics

var ok = true

if !AXIsProcessTrusted() {
    print("Missing Accessibility TCC grant: grant Accessibility to the self-hosted runner process in System Settings > Privacy & Security > Accessibility, then rerun.")
    ok = false
}

if !CGPreflightScreenCaptureAccess() {
    _ = CGRequestScreenCaptureAccess()
    print("Missing Screen Recording TCC grant: grant Screen Recording to the self-hosted runner process in System Settings > Privacy & Security > Screen Recording, then rerun.")
    ok = false
}

exit(ok ? 0 : 1)
SWIFT

if swift "$PREFLIGHT_HELPER"; then
  record_pass "TCC preflight has Accessibility and Screen Recording grants."
else
  record_fail "TCC preflight failed."
  print_summary
  exit 1
fi

DEFAULTS_SNAPSHOT="$(mktemp -t localvoxtral-defaults.XXXXXX.plist)"
if defaults export "$BUNDLE_ID" "$DEFAULTS_SNAPSHOT" >/dev/null 2>&1; then
  HAD_DEFAULTS=1
else
  HAD_DEFAULTS=0
fi
defaults write "$BUNDLE_ID" settings.backend_mode -string managed_local
record_pass "Defaults domain snapshot captured and smoke run forced to managed mode."

# Managed backends are Python entry-point processes, so match the full
# command line (-f). The runner legitimately hosts a voxmlx-serve launchd
# service, so the invariant is baseline-diffed: only processes that appear
# AFTER app launch count as violations.
managed_backend_pids() {
  pgrep -f 'voxmlx-serve|mlx_lm\.server' 2>/dev/null | sort || true
}

BASELINE_BACKEND_PIDS="$(managed_backend_pids)"

quit_app
if pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
  record_fail "Existing app instance did not quit before smoke launch; cannot launch a fresh instance."
  print_summary
  exit 1
fi

open -n "$APP_PATH"
launch_deadline=$((SECONDS + 10))
while ((SECONDS < launch_deadline)); do
  APP_PID="$(pgrep -xn "$APP_PROCESS" 2>/dev/null || true)"
  [[ -n "$APP_PID" ]] && break
  sleep 0.5
done

if [[ -z "$APP_PID" ]]; then
  record_fail "App process did not start within 10 seconds."
  print_summary
  exit 1
fi
record_pass "Fresh app instance launched with pid $APP_PID."

status_item_exists() {
  osascript <<OSA
tell application "System Events"
  if not (exists process "$APP_PROCESS") then return "missing"
  tell process "$APP_PROCESS"
    repeat with menuBarRef in menu bars
      repeat with itemRef in menu bar items of menuBarRef
        try
          set itemName to name of itemRef as text
          if itemName contains "localvoxtral" then return "found"
        end try
        try
          set itemDescription to description of itemRef as text
          if itemDescription contains "localvoxtral" then return "found"
        end try
        try
          set axDescription to value of attribute "AXDescription" of itemRef as text
          if axDescription contains "localvoxtral" then return "found"
        end try
      end repeat
    end repeat
    try
      if (count of menu bar items of menu bar 2) > 0 then return "found"
    end try
  end tell
end tell
return "missing"
OSA
}

status_deadline=$((SECONDS + 10))
status_found=0
while ((SECONDS < status_deadline)); do
  if [[ "$(status_item_exists 2>/dev/null || true)" == "found" ]]; then
    status_found=1
    break
  fi
  sleep 0.5
done

if ((status_found)); then
  record_pass "Menu bar status item appeared within 10 seconds."
else
  record_fail "Menu bar status item did not appear within 10 seconds."
fi

NEW_BACKEND_PIDS="$(comm -13 <(printf '%s\n' "$BASELINE_BACKEND_PIDS") <(managed_backend_pids) 2>/dev/null || true)"
if [[ -n "$NEW_BACKEND_PIDS" ]]; then
  record_fail "App launch spawned managed backend process(es) — lazy-bootstrap invariant violated. New pids: $NEW_BACKEND_PIDS"
else
  record_pass "No managed backend process spawned by app launch (baseline-diffed)."
fi

open_status_menu() {
  if ! osascript >/dev/null <<OSA
tell application "System Events" to tell process "$APP_PROCESS"
  ignoring application responses
    click menu bar item 1 of menu bar 2
  end ignoring
end tell
OSA
  then
    return 1
  fi
  sleep 1
}

dismiss_menu() {
  osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
  sleep 0.5
}

open_settings() {
  open_status_menu || return 1
  if osascript >/dev/null <<OSA
tell application "System Events" to tell process "$APP_PROCESS"
  click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
end tell
OSA
  then
    return 0
  fi

  dismiss_menu
  open_status_menu || return 1
  osascript >/dev/null <<OSA
tell application "System Events" to tell process "$APP_PROCESS"
  click menu item "Settings..." of menu 1 of menu bar item 1 of menu bar 2
end tell
OSA
}

wait_for_settings_window() {
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(osascript <<OSA 2>/dev/null
tell application "System Events"
  if not (exists process "$APP_PROCESS") then return "missing"
  tell process "$APP_PROCESS"
    if (count of windows) > 0 then return "found"
  end tell
end tell
return "missing"
OSA
)" == "found" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

if open_settings && wait_for_settings_window; then
  record_pass "Settings opened from the status menu."
else
  record_fail "Settings did not open from the status menu within 10 seconds."
fi

window_has_static_text() {
  local expected="$1"
  osascript <<OSA
on hasStaticText(elementRef, expectedText)
  try
    if class of elementRef is static text then
      try
        if (value of elementRef as text) contains expectedText then return true
      end try
      try
        if (name of elementRef as text) contains expectedText then return true
      end try
    end if
    repeat with childRef in UI elements of elementRef
      if my hasStaticText(childRef, expectedText) then return true
    end repeat
  end try
  return false
end hasStaticText

tell application "System Events"
  if not (exists process "$APP_PROCESS") then return "missing"
  tell process "$APP_PROCESS"
    if not (exists window 1) then return "missing"
    if my hasStaticText(window 1, "$expected") then return "found"
  end tell
end tell
return "missing"
OSA
}

select_tab() {
  local tab_name="$1"
  osascript >/dev/null <<OSA
tell application "System Events" to tell process "$APP_PROCESS"
  click button "$tab_name" of toolbar 1 of window 1
end tell
OSA
}

assert_tab() {
  local tab_name="$1"
  local expected_text="$2"

  if ! select_tab "$tab_name"; then
    record_fail "Could not select Settings tab: $tab_name."
    return
  fi
  sleep 0.5

  if [[ "$(window_has_static_text "$expected_text" 2>/dev/null || true)" == "found" ]]; then
    record_pass "Settings tab selectable: $tab_name."
  else
    record_fail "Settings tab selected but expected text was not visible: $tab_name -> $expected_text."
  fi
}

assert_tab "Realtime Endpoint" "Backend"
assert_tab "Dictation" "Start dictation with"
assert_tab "Text Processing" "Replacements"

select_tab "Realtime Endpoint" >/dev/null 2>&1 || true
sleep 0.5
if [[ "$(window_has_static_text "voxmlx - ws://127.0.0.1:8471/v1/realtime" 2>/dev/null || true)" == "found" ]] \
  && [[ "$(window_has_static_text "mlx-lm - http://127.0.0.1:8472/v1/chat/completions" 2>/dev/null || true)" == "found" ]]; then
  record_pass "Managed-mode Realtime Endpoint pane shows dictation and polishing backend rows."
else
  record_fail "Managed-mode Realtime Endpoint pane did not show both expected backend rows."
fi

quit_app
sleep 0.5
if pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
  record_fail "App did not quit cleanly; process still exists after quit."
else
  record_pass "App quit cleanly."
fi

if ps -axo stat=,comm= | awk -v app="/${APP_PROCESS}$" '$2 ~ app && $1 ~ /Z/ { found = 1 } END { exit found ? 0 : 1 }'; then
  record_fail "Zombie localvoxtral process found after quit."
else
  record_pass "No zombie localvoxtral process found after quit."
fi

print_summary
if ((FAILED)); then
  exit 1
fi
exit 0
