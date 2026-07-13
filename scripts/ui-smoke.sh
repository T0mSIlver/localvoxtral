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
# test's required external-mode setting, and restores the snapshot on exit.

APP_PATH="${1:-dist/localvoxtral.app}"
APP_PROCESS="localvoxtral"
BUNDLE_ID="com.localvoxtral.app"
PERSISTENT_DEFAULTS_BACKUP="${HOME}/.localvoxtral-ui-smoke.pre.plist"
PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN="${PERSISTENT_DEFAULTS_BACKUP}.had-domain"
PREFLIGHT_HELPER=""
AX_PROBE_HELPER=""
APP_PID=""
FAILED=0
CLEANED_UP=0
OSASCRIPT_TIMEOUT_SECONDS="${OSASCRIPT_TIMEOUT_SECONDS:-8}"
OSASCRIPT_TIMEOUT_BIN=""
BACKEND_SAMPLE_FILE=""
BACKEND_SAMPLER_PID=""
SUMMARY=()

if command -v timeout >/dev/null 2>&1; then
  OSASCRIPT_TIMEOUT_BIN="$(command -v timeout)"
fi

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
  if [[ ! -f "$PERSISTENT_DEFAULTS_BACKUP" ]]; then
    return
  fi

  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -f "$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN" ]]; then
    defaults import "$BUNDLE_ID" "$PERSISTENT_DEFAULTS_BACKUP" >/dev/null 2>&1 || return 1
  fi
  rm -f "$PERSISTENT_DEFAULTS_BACKUP" "$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN"
}

recover_previous_defaults_backup() {
  if [[ ! -f "$PERSISTENT_DEFAULTS_BACKUP" ]]; then
    rm -f "$PERSISTENT_DEFAULTS_BACKUP_HAD_DOMAIN"
    return 0
  fi

  printf 'WARNING: found %s from a previous interrupted UI smoke run; restoring owner defaults before continuing.\n' "$PERSISTENT_DEFAULTS_BACKUP" >&2
  if restore_defaults; then
    printf 'WARNING: previous UI smoke defaults backup restored and removed.\n' >&2
    return 0
  fi

  record_fail "Could not restore previous defaults backup at $PERSISTENT_DEFAULTS_BACKUP; refusing to mutate owner defaults."
  return 1
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

run_osascript() {
  if [[ -n "$OSASCRIPT_TIMEOUT_BIN" ]]; then
    "$OSASCRIPT_TIMEOUT_BIN" "${OSASCRIPT_TIMEOUT_SECONDS}s" osascript "$@"
  else
    # macOS does not ship GNU timeout; if it is unavailable, run osascript
    # directly rather than failing the smoke drill before AX checks can run.
    osascript "$@"
  fi
}

quit_app() {
  if ! pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
    return
  fi

  run_osascript -e "tell application \"$APP_PROCESS\" to quit" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if ! pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
      return
    fi
    sleep 0.5
  done
}

managed_backend_pids() {
  pgrep -f 'voxmlx-serve|mlx_lm\.server|localvoxtral-polishd' 2>/dev/null | sort || true
}

start_backend_sampler() {
  BACKEND_SAMPLE_FILE="$(mktemp -t localvoxtral-backend-samples.XXXXXX)"
  (
    while :; do
      managed_backend_pids >>"$BACKEND_SAMPLE_FILE"
      sleep 0.2
    done
  ) &
  BACKEND_SAMPLER_PID=$!
}

stop_backend_sampler() {
  if [[ -z "$BACKEND_SAMPLER_PID" ]]; then
    return
  fi

  kill "$BACKEND_SAMPLER_PID" >/dev/null 2>&1 || true
  wait "$BACKEND_SAMPLER_PID" >/dev/null 2>&1 || true
  BACKEND_SAMPLER_PID=""
}

sampled_backend_pids() {
  if [[ -n "$BACKEND_SAMPLE_FILE" && -f "$BACKEND_SAMPLE_FILE" ]]; then
    sort -u "$BACKEND_SAMPLE_FILE" | sed '/^$/d'
  fi
}

cleanup() {
  if ((CLEANED_UP)); then
    return
  fi
  CLEANED_UP=1

  stop_backend_sampler
  quit_app
  if ! restore_defaults; then
    printf 'WARNING: failed to restore defaults backup at %s; leaving it in place for the next run.\n' "$PERSISTENT_DEFAULTS_BACKUP" >&2
  fi
  [[ -n "$PREFLIGHT_HELPER" ]] && rm -f "$PREFLIGHT_HELPER"
  [[ -n "$AX_PROBE_HELPER" ]] && rm -f "$AX_PROBE_HELPER"
  [[ -n "$BACKEND_SAMPLE_FILE" ]] && rm -f "$BACKEND_SAMPLE_FILE"
}

signal_cleanup() {
  local status="$1"
  trap - EXIT INT TERM HUP
  cleanup
  exit "$status"
}

trap cleanup EXIT
trap 'signal_cleanup 130' INT
trap 'signal_cleanup 143' TERM
trap 'signal_cleanup 129' HUP

if [[ "$(uname)" != "Darwin" ]]; then
  record_fail "ui-smoke.sh drives macOS AX APIs and must run on macOS."
  print_summary
  exit 1
fi

if ! recover_previous_defaults_backup; then
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

if ! snapshot_defaults; then
  record_fail "Could not create persistent defaults backup at $PERSISTENT_DEFAULTS_BACKUP; refusing to mutate owner defaults."
  print_summary
  exit 1
fi
if ! defaults write "$BUNDLE_ID" settings.dictation_backend_mode -string external_url \
  || ! defaults write "$BUNDLE_ID" settings.polishing_backend_mode -string external_url \
  || ! defaults write "$BUNDLE_ID" settings.llm_polishing_enabled -bool false \
  || ! defaults write "$BUNDLE_ID" settings.onboarding_completed -bool true; then
  record_fail "Could not force external backend mode and completed onboarding in defaults."
  print_summary
  exit 1
fi
# Backend modes are forced external so the launch invariant below tests that
# externally managed servers are never spawned by the app. Managed local mode
# now intentionally launches required backends eagerly at app start.
# onboarding_completed is forced true so the first-launch wizard never appears
# and the launch invariants below (menu-bar item, no backend spawned) hold. A
# dedicated wizard smoke would need a second launch with the flag false plus AX
# drilling of the wizard window; that is out of scope for this single-launch
# drill.
# TODO(tier-2): add a wizard-appears smoke by launching once with
# settings.onboarding_completed=false and asserting the "Welcome to localvoxtral"
# window, then completing it.
record_pass "Defaults domain snapshot captured and smoke run forced to external mode with onboarding completed."

# Managed backends are Python entry-point processes, so match the full
# command line (-f). The runner legitimately hosts a voxmlx-serve launchd
# service, so the invariant is baseline-diffed: only processes that appear
# AFTER app launch count as violations.
BASELINE_BACKEND_PIDS="$(managed_backend_pids)"

quit_app
if pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
  record_fail "Existing app instance did not quit before smoke launch; cannot launch a fresh instance."
  print_summary
  exit 1
fi

start_backend_sampler
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
  run_osascript <<OSA
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

stop_backend_sampler
NEW_BACKEND_PIDS="$(comm -13 <(printf '%s\n' "$BASELINE_BACKEND_PIDS" | sed '/^$/d') <(sampled_backend_pids) 2>/dev/null || true)"
if [[ -n "$NEW_BACKEND_PIDS" ]]; then
  record_fail "App launch spawned managed backend process(es) in external mode. New pids: $NEW_BACKEND_PIDS"
else
  record_pass "No managed backend process spawned by app launch in external mode, including transient samples."
fi

open_status_menu() {
  if ! run_osascript >/dev/null <<OSA
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
  run_osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
  sleep 0.5
}

open_settings() {
  open_status_menu || return 1
  if run_osascript >/dev/null <<OSA
tell application "System Events" to tell process "$APP_PROCESS"
  click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
end tell
OSA
  then
    return 0
  fi

  dismiss_menu
  open_status_menu || return 1
  run_osascript >/dev/null <<OSA
tell application "System Events" to tell process "$APP_PROCESS"
  click menu item "Settings..." of menu 1 of menu bar item 1 of menu bar 2
end tell
OSA
}

wait_for_settings_window() {
  local deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(run_osascript <<OSA 2>/dev/null
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

# Content-visibility checks go through the direct AX C API, not System Events.
# The previous AppleScript walk never compiled (the `static text` class term is
# unresolvable outside a System Events tell block, error -2741) and the call
# sites' 2>/dev/null hid that for every CI run — issue #72. System Events is
# also unreliable against this SwiftUI window (`entire contents of window 1`
# returns 0 elements on the macOS 26 runner) while the AX API sees the full
# tree, so the AppleScript approach is dropped rather than fixed.
#
# The helper polls the app's windows until <needle> appears in any element's
# title/value/description or the deadline passes; with --dump-on-fail it prints
# the AX tree so the uploaded log shows what was actually on screen.
write_ax_probe_helper() {
  local stem
  stem="$(mktemp -t localvoxtral-ax-probe)" || return 1
  AX_PROBE_HELPER="${stem}.swift"
  mv "$stem" "$AX_PROBE_HELPER" || return 1
  cat >"$AX_PROBE_HELPER" <<'SWIFT'
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 4, let pid = Int32(args[1]), let timeoutSeconds = Double(args[3]) else {
    print("usage: ax-probe <pid> <needle> <timeout-seconds> [--dump-on-fail]")
    exit(2)
}
let needle = args[2]
let dumpOnFail = args.contains("--dump-on-fail")
let app = AXUIElementCreateApplication(pid)

func copyAttr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func windows() -> [AXUIElement] {
    (copyAttr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

func texts(_ element: AXUIElement) -> (role: String, title: String, value: String, desc: String) {
    let role = copyAttr(element, kAXRoleAttribute) as? String ?? "?"
    let title = copyAttr(element, kAXTitleAttribute) as? String ?? ""
    let desc = copyAttr(element, kAXDescriptionAttribute) as? String ?? ""
    var value = ""
    if let raw = copyAttr(element, kAXValueAttribute) { value = String(describing: raw) }
    return (role, title, value, desc)
}

// Only text-bearing roles count as visible pane content. The toolbar tab
// AXButtons (titled "General", "Endpoints", "Dictation", ...) exist on every
// pane, so an unscoped match would let e.g. the Endpoints check pass off the
// "Dictation" tab button without the pane ever rendering.
let textRoles: Set<String> = ["AXStaticText", "AXTextField", "AXTextArea"]

func containsNeedle(_ element: AXUIElement, depth: Int, budget: inout Int) -> Bool {
    if depth > 40 || budget <= 0 { return false }
    budget -= 1
    let t = texts(element)
    if textRoles.contains(t.role),
       t.title.contains(needle) || t.value.contains(needle) || t.desc.contains(needle) {
        return true
    }
    for child in (copyAttr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        if containsNeedle(child, depth: depth + 1, budget: &budget) { return true }
    }
    return false
}

func dump(_ element: AXUIElement, depth: Int, budget: inout Int) {
    if depth > 40 || budget <= 0 { return }
    budget -= 1
    let t = texts(element)
    let indent = String(repeating: "  ", count: depth)
    print("\(indent)\(t.role) title=\(t.title.prefix(60)) value=\(t.value.prefix(100)) desc=\(t.desc.prefix(60))")
    for child in (copyAttr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        dump(child, depth: depth + 1, budget: &budget)
    }
}

let deadline = Date().addingTimeInterval(timeoutSeconds)
repeat {
    for window in windows() {
        var budget = 20000
        if containsNeedle(window, depth: 0, budget: &budget) { exit(0) }
    }
    usleep(250_000)
} while Date() < deadline

if dumpOnFail {
    let wins = windows()
    print("AXPROBE: needle \"\(needle)\" not visible after \(timeoutSeconds)s; windows=\(wins.count)")
    for (index, window) in wins.enumerated() {
        print("AXPROBE: === window \(index) ===")
        var budget = 8000
        dump(window, depth: 0, budget: &budget)
    }
}
exit(1)
SWIFT
}

window_shows_text() {
  local expected="$1" timeout_seconds="${2:-10}"
  shift 2 || true
  swift "$AX_PROBE_HELPER" "$APP_PID" "$expected" "$timeout_seconds" "$@"
}

select_tab() {
  local tab_name="$1"
  run_osascript >/dev/null <<OSA
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

  if window_shows_text "$expected_text" 10 --dump-on-fail; then
    record_pass "Settings tab shows expected content: $tab_name -> $expected_text."
  else
    record_fail "Settings tab selected but expected text was not visible: $tab_name -> $expected_text."
  fi
}

if ! write_ax_probe_helper; then
  record_fail "Could not write the AX text-probe helper."
  print_summary
  exit 1
fi

assert_tab "General" "Permissions"
assert_tab "Endpoints" "Dictation"
assert_tab "Dictation" "Start dictation with"
assert_tab "Text Processing" "Replacements"
# The polish feature toggles live on Text Processing (moved from Endpoints).
assert_tab "Text Processing" "Polishing"
assert_tab "About" "Diagnostics"

# The launch phase forces external URL modes (managed mode now eagerly spawns
# at launch), so the Endpoints pane renders endpoint configuration fields, not
# the managed status rows. Managed-row AX coverage would need a second launch
# that tolerates the eager spawn.
select_tab "Endpoints" >/dev/null 2>&1 || true
if window_shows_text "Endpoint" 10 --dump-on-fail \
  && window_shows_text "API key" 10 --dump-on-fail; then
  record_pass "External-mode Endpoints pane shows endpoint configuration fields."
else
  record_fail "External-mode Endpoints pane did not show endpoint configuration fields."
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
