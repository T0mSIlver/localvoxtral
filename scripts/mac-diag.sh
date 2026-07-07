#!/usr/bin/env bash
# mac-diag.sh — local-first diagnostics snapshot for localvoxtral.
#
# Prints a single readable report to stdout. Designed to run over ssh and to
# be piped to a file:  ssh mac-host 'bash -s' < scripts/mac-diag.sh > diag.txt
#
# It has NO dependency on the app's Swift sources — only standard macOS tools.
#
# Privacy: this script NEVER reads dictated content or transcript stores and
# NEVER raises log verbosity. The unified-log sections use the default level
# (the app only logs dictated text under an opt-in hidden debug flag). Missing
# artifacts are reported as "absent", never as errors.

# No `set -e`: a diagnostic snapshot must keep going when a probe fails.
set -uo pipefail

APP_NAME="localvoxtral"
APP_BUNDLE_ID="com.localvoxtral.app"
APP_DIR="/Applications/${APP_NAME}.app"
INFO_PLIST="${APP_DIR}/Contents/Info.plist"
BACKENDS_ROOT="${HOME}/Library/Application Support/${APP_NAME}/backends"
VOXMLX_LOG="${HOME}/Library/Logs/voxmlx.log"
VOXMLX_LAUNCHD_LABEL="com.localvoxtral.voxmlx"

# nc connect timeout (seconds) so a down port does not hang the report.
PORT_TIMEOUT=2

# Runs a command under a wall-clock bound when a timeout binary exists
# (log show can be slow over ssh); degrades to unbounded otherwise.
bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

print_header() {
  printf '\n=== %s ===\n' "$1"
}

print_kv() {
  printf '%-22s %s\n' "$1:" "$2"
}

run_section_raw() {
  # Print a section header then the captured stdout+stderr of the remaining
  # args. A nonzero exit is tolerated (the command's failure / stderr is often
  # itself the signal, e.g. launchctl on a missing service). Empty output is
  # reported as "absent" so the report shape stays stable.
  local title="$1"
  shift
  print_header "$title"
  local out
  out="$("$@" 2>&1)" || true
  if [[ -z "$out" ]]; then
    printf '(absent)\n'
  else
    printf '%s\n' "$out"
  fi
}

check_port() {
  local port="$1"
  local label="$2"
  if nc -z -G "$PORT_TIMEOUT" -w "$PORT_TIMEOUT" 127.0.0.1 "$port" >/dev/null 2>&1; then
    print_kv "127.0.0.1:${port} (${label})" "OPEN"
  else
    print_kv "127.0.0.1:${port} (${label})" "closed/unreachable"
  fi
}

dump_dir_listing() {
  local path="$1"
  if [[ -d "$path" ]]; then
    # -1 so each entry is on its own line; head keeps the report bounded.
    ls -1 "$path" 2>&1 | head -40
  else
    printf '(directory absent: %s)\n' "$path"
  fi
}

dump_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    cat "$path"
  else
    printf '(file absent: %s)\n' "$path"
  fi
}

# --- Report header --------------------------------------------------------

printf 'localvoxtral diagnostics snapshot\n'
printf 'generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'host: %s\n' "$(hostname 2>/dev/null || echo unknown)"
printf 'user: %s (uid=%s)\n' "$(id -F 2>/dev/null || id -un)" "$(id -u)"

# --- Versions -------------------------------------------------------------

print_header "Versions (system + app)"
sw_vers 2>&1 || printf '(sw_vers failed)\n'

if [[ -f "$INFO_PLIST" ]]; then
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || echo unknown)"
  app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || echo unknown)"
  print_kv "app version" "${app_version}"
  print_kv "app build" "${app_build}"
  print_kv "app bundle id" "${APP_BUNDLE_ID}"
else
  print_kv "app" "not installed at ${APP_DIR}"
fi

# Code signature tag (TeamIdentifier / Authority) — useful for TCC debugging.
if [[ -d "$APP_DIR" ]]; then
  print_header "App code signature (${APP_DIR})"
  codesign -dv "$APP_DIR" 2>&1 | head -20 || printf '(codesign failed)\n'
fi

# --- Process state --------------------------------------------------------

print_header "Process state"
for proc in localvoxtral voxmlx-serve mlx_lm.server localvoxtral-polishd; do
  # PIDs only — full command lines (pgrep -fl) could leak flags such as API
  # keys from user-run backend invocations.
  pids="$(pgrep -f "$proc" 2>/dev/null | tr '\n' ' ' || true)"
  if [[ -n "$pids" ]]; then
    print_kv "$proc" "running (pids: ${pids})"
  else
    print_kv "$proc" "not running"
  fi
done

# --- Ports ----------------------------------------------------------------

print_header "Local ports (127.0.0.1)"
check_port 8000 "user/external realtime"
check_port 8471 "managed voxmlx"
check_port 8472 "managed polishing engine (localvoxtral-polishd)"

# --- launchd --------------------------------------------------------------

run_section_raw "launchd: ${VOXMLX_LAUNCHD_LABEL}" \
  launchctl print "gui/$(id -u)/${VOXMLX_LAUNCHD_LABEL}"

# --- Managed install state ------------------------------------------------

print_header "Managed install state (Application Support)"
print_header "backends root (${BACKENDS_ROOT})"
dump_dir_listing "$BACKENDS_ROOT"
print_header "backends bin/"
dump_dir_listing "${BACKENDS_ROOT}/bin"
dump_file "${BACKENDS_ROOT}/installed.json"

# --- Recent app logs (default level only — never raises verbosity) --------

print_header "Recent app logs (last 10m, default level, last 80 lines)"
# Excludes the opt-in Deltas category, which logs dictated content in
# cleartext when debug.log_realtime_deltas is enabled.
app_logs="$(bounded 30 log show \
  --predicate 'process == "localvoxtral" AND NOT (category == "Deltas")' \
  --last 10m \
  --style compact 2>&1 | tail -80 || true)"
if [[ -z "$app_logs" ]]; then
  printf '(no log lines in the last 10m)\n'
else
  printf '%s\n' "$app_logs"
fi

# --- syspolicyd errors (macOS 26 launch-stall class) ----------------------

print_header "syspolicyd errors/rejections (last 10m, last 20 lines)"
syspolicy_logs="$(bounded 30 log show \
  --predicate 'process == "syspolicyd"' \
  --last 10m \
  --style compact 2>&1 | grep -iE 'error|reject' | tail -20 || true)"
if [[ -z "$syspolicy_logs" ]]; then
  printf '(no syspolicyd error/reject lines in the last 10m)\n'
else
  printf '%s\n' "$syspolicy_logs"
fi

# --- Backend logs ---------------------------------------------------------

print_header "voxmlx log (last 20 lines)"
if [[ -f "$VOXMLX_LOG" ]]; then
  tail -20 "$VOXMLX_LOG" 2>&1 || printf '(could not read %s)\n' "$VOXMLX_LOG"
else
  printf '(absent: %s)\n' "$VOXMLX_LOG"
fi

printf '\n=== end of diagnostics ===\n'
