#!/usr/bin/env bash
set -uo pipefail

# `lv_open`: `open`, plus the env the lanes need the app to see.
# shellcheck source=scripts/lib/launch-app.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/launch-app.sh"

# End-to-end dictation check of the PACKAGED app. Run on a macOS GUI session:
#   ./scripts/e2e-dictation.sh [dist/localvoxtral.app] [scenario-file ...]
#
# For each scenario (scripts/e2e/scenarios/*.scenario) it launches the dogfood
# build with a WAV in place of the microphone (docs/dogfood-builds.md,
# "Dictating from a file"), focuses a throwaway target window, runs one
# dictation through the control socket, and scores the text that landed in the
# target against the phrase that was spoken. Everything between the capture
# callback and the focused app is the production path: chunk buffering, the
# realtime socket, transcript merging, insertion, the overlay commit.
#
# What it does not cover: MicrophoneCaptureService (the file replaces it), the
# modifier gesture (the socket calls the handler the gesture reaches), and
# polishing, which is off so that the score measures the app and not a model.
#
# A scenario is data, not a script:
#   mode=live|overlay
#   phrase=<what `say` speaks and the score is measured against>
#   min_word_accuracy=<0..1, scripts/lib/word-accuracy.sh>
#
# It needs a dogfood bundle (`LOCALVOXTRAL_DOGFOOD=1 ./scripts/package_app.sh
# release`), an STT server on LV_E2E_REALTIME_ENDPOINT, an unlocked screen and
# the app's Accessibility grant. It takes the keyboard focus for about half a
# minute per scenario and says so out loud first (LV_E2E_ANNOUNCE=0 to mute).
#
# Exit status: 0 every scenario passed, 1 a scenario failed, 3 the machine was
# not in a state to run one (locked, no STT server, no grant). A caller that
# schedules this can treat 3 as "skipped" and 1 as a regression.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${1:-dist/localvoxtral.app}"
[ "$#" -gt 0 ] && shift
APP_PROCESS="localvoxtral"
BUNDLE_ID="com.localvoxtral.app"
OWNER_APP_BUNDLE=""
DRILL_LAUNCHED=0
FAILED=0
NOT_RUNNABLE=0
CLEANED_UP=0
ANNOUNCED=0
WORK_DIR=""
TARGET_PID=""
SUMMARY=()
OSASCRIPT_TIMEOUT_SECONDS="${OSASCRIPT_TIMEOUT_SECONDS:-8}"
OSASCRIPT_TIMEOUT_BIN=""

REALTIME_ENDPOINT="${LV_E2E_REALTIME_ENDPOINT:-ws://127.0.0.1:8000/v1/realtime}"
REALTIME_MODEL="${LV_E2E_REALTIME_MODEL:-T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead}"
CONTROL_SOCKET="${HOME}/Library/Application Support/localvoxtral/dogfood/control/control.sock"
TARGET_BUNDLE_ID="com.localvoxtral.e2e-target"

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

# The machine, not the app: nothing was measured, so nothing regressed.
record_not_runnable() {
  SUMMARY+=("NOT RUN: $1")
  printf 'NOT RUN: %s\n' "$1" >&2
  NOT_RUNNABLE=1
}

print_summary() {
  printf '\nE2E dictation summary:\n'
  if ((${#SUMMARY[@]} == 0)); then
    printf 'FAIL: no checks ran.\n'
    return
  fi
  local line
  for line in "${SUMMARY[@]}"; do
    printf '  %s\n' "$line"
  done
}

finish() {
  print_summary
  if ((FAILED)); then exit 1; fi
  if ((NOT_RUNNABLE)); then exit 3; fi
  exit 0
}

# shellcheck source=scripts/lib/owner-app-session.sh
source "${SCRIPT_DIR}/lib/owner-app-session.sh"

announce() {
  [[ "${LV_E2E_ANNOUNCE:-1}" == "1" ]] || return 0
  command -v say >/dev/null 2>&1 || return 0
  say "$1" >/dev/null 2>&1 || true
}

stop_target() {
  if [[ -n "$TARGET_PID" ]]; then
    kill "$TARGET_PID" >/dev/null 2>&1 || true
    TARGET_PID=""
  fi
  # `open` does not hand back the pid it started, so sweep by executable path.
  if [[ -n "$WORK_DIR" ]]; then
    pkill -f "$WORK_DIR/e2e-target.app/Contents/MacOS/e2e-target" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if ((CLEANED_UP)); then
    return
  fi
  CLEANED_UP=1
  # A signal mid-cleanup would re-enter it as a no-op and exit, leaving the
  # owner's app stopped and the lane's defaults installed. Every step below is
  # bounded, so finish it.
  trap '' INT TERM HUP

  stop_target
  # Only a run that launched, or cleared the slot to launch, owns whatever
  # localvoxtral is running now. Before that point it is the owner's app.
  if ((DRILL_LAUNCHED)) || [[ -n "$OWNER_APP_BUNDLE" ]]; then
    quit_app
  fi
  if restore_defaults; then
    relaunch_owner_app
  else
    printf 'WARNING: failed to restore defaults backup at %s; leaving it in place for the next run and NOT relaunching the owner app at %s.\n' "$PERSISTENT_DEFAULTS_BACKUP" "$OWNER_APP_BUNDLE" >&2
  fi
  [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  if ((ANNOUNCED)); then
    announce "localvoxtral end to end check finished."
  fi
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

# --- scenario files ---------------------------------------------------------

scenario_value() {
  # scenario_value <file> <key>: the text after the first `key=`, verbatim.
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# --- control socket ---------------------------------------------------------

control() {
  # One line in, one line of JSON out, then the server closes.
  printf '%s\n' "$1" | nc -U -w 10 "$CONTROL_SOCKET" 2>/dev/null
}

json_has() {
  # json_has <json> <"key":value>, against the socket's space-free rendering.
  [[ "$1" == *"$2"* ]]
}

# --- app log ----------------------------------------------------------------

app_log_since() {
  log show --start "$1" --style compact \
    --predicate 'subsystem == "com.localvoxtral" AND process == "localvoxtral"' 2>/dev/null
}

wait_for_audio_drained() {
  # wait_for_audio_drained <log-start> <timeout-seconds>
  local start="$1" deadline=$((SECONDS + $2)) lines
  if ! app_log_since "$start" >/dev/null; then
    return 2
  fi
  while ((SECONDS < deadline)); do
    # Captured, not piped into `grep -q`: grep leaving at the first match
    # SIGPIPEs `log show`, and under pipefail that reads as "no match".
    lines="$(app_log_since "$start")"
    if grep -q "dogfood audio file drained" <<<"$lines"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# --- target -----------------------------------------------------------------

build_target_app() {
  local bundle="$WORK_DIR/e2e-target.app"
  mkdir -p "$bundle/Contents/MacOS" || return 1
  cat >"$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$TARGET_BUNDLE_ID</string>
  <key>CFBundleName</key><string>e2e-target</string>
  <key>CFBundleExecutable</key><string>e2e-target</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  swiftc -O -o "$bundle/Contents/MacOS/e2e-target" "$SCRIPT_DIR/e2e/target-app.swift"
}

start_target() {
  # start_target <output-dir>: a focused, empty text view, or failure.
  local out="$1" deadline
  mkdir -p "$out" || return 1
  rm -f "$out/text" "$out/state"
  open -n "$WORK_DIR/e2e-target.app" --args "$out" || return 1
  deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    TARGET_PID="$(pgrep -f "$WORK_DIR/e2e-target.app/Contents/MacOS/e2e-target" 2>/dev/null | head -n 1)"
    if [[ -f "$out/state" ]] && [[ "$(cat "$out/state")" == "active=1 key=1 focused=1" ]]; then
      return 0
    fi
    sleep 0.5
  done
  printf 'target state: %s\n' "$(cat "$out/state" 2>/dev/null || echo missing)" >&2
  return 1
}

wait_for_settled_text() {
  # wait_for_settled_text <file> <timeout>: non-empty and unchanged for 3 s.
  local file="$1" deadline=$((SECONDS + $2)) last="" current stable_since=0
  while ((SECONDS < deadline)); do
    current="$(cat "$file" 2>/dev/null || true)"
    if [[ -n "$current" && "$current" == "$last" ]]; then
      ((stable_since == 0)) && stable_since=$SECONDS
      if ((SECONDS - stable_since >= 3)); then
        return 0
      fi
    else
      stable_since=0
      last="$current"
    fi
    sleep 0.5
  done
  [[ -n "$last" ]]
}

# --- one scenario -----------------------------------------------------------

launch_app_under_test() {
  local deadline app_pid=""
  rm -f "$CONTROL_SOCKET"
  DRILL_LAUNCHED=1
  lv_open -n "$APP_PATH" || return 1
  deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)); do
    app_pid="$(pgrep -xn "$APP_PROCESS" 2>/dev/null || true)"
    if [[ -n "$app_pid" && -S "$CONTROL_SOCKET" ]]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

run_scenario() {
  local file="$1" name mode phrase minimum wav out wav_bytes seconds log_start
  local reply drained text score
  name="$(basename "$file" .scenario)"
  mode="$(scenario_value "$file" mode)"
  phrase="$(scenario_value "$file" phrase)"
  minimum="$(scenario_value "$file" min_word_accuracy)"
  if [[ "$mode" != "live" && "$mode" != "overlay" ]] || [[ -z "$phrase" || -z "$minimum" ]]; then
    record_fail "$name: scenario needs mode=live|overlay, phrase= and min_word_accuracy=."
    return
  fi

  wav="$WORK_DIR/$name.wav"
  out="$WORK_DIR/$name"
  if ! say -o "$wav" --file-format=WAVE --data-format=LEI16@16000 "$phrase"; then
    record_not_runnable "$name: system TTS (say) could not write the WAV."
    return
  fi
  wav_bytes="$(wc -c <"$wav" | tr -d ' ')"
  seconds=$((wav_bytes / 32000 + 1))

  export LOCALVOXTRAL_DOGFOOD_AUDIO_FILE="$wav"
  if ! launch_app_under_test; then
    record_fail "$name: the app did not start and open its control socket within 20 s."
    return
  fi
  if ! start_target "$out"; then
    record_not_runnable "$name: the target window did not take the keyboard focus."
    return
  fi

  log_start="$(date '+%Y-%m-%d %H:%M:%S')"
  reply="$(control "session start $mode")"
  printf '%s: session start -> %s\n' "$name" "$reply"
  if json_has "$reply" '"accessibilityTrusted":false'; then
    record_not_runnable "$name: the app under test has no Accessibility grant."
    return
  fi
  if json_has "$reply" '"secureInputActive":true'; then
    record_not_runnable "$name: Secure Keyboard Entry is held by another app."
    return
  fi
  if ! json_has "$reply" '"started":true'; then
    record_fail "$name: the dictation did not start."
    return
  fi

  wait_for_audio_drained "$log_start" $((seconds + 45))
  drained=$?
  if ((drained == 2)); then
    printf 'WARNING: %s: the unified log is not readable here; waiting %s s instead.\n' "$name" $((seconds + 15)) >&2
    sleep $((seconds + 15))
  elif ((drained == 1)); then
    record_fail "$name: the audio file never finished playing, so capture never started."
    app_log_since "$log_start" | tail -n 60 >&2
    control "session stop" >/dev/null
    return
  fi
  # The source is sending silence now. Two seconds of it lets the server close
  # the last words before the stop finalizes.
  sleep 2

  reply="$(control "session stop")"
  printf '%s: session stop -> %s\n' "$name" "$reply"

  if ! wait_for_settled_text "$out/text" 45; then
    record_fail "$name: no text reached the target within 45 s of the stop."
    app_log_since "$log_start" | tail -n 60 >&2
    return
  fi
  if [[ "$(cat "$out/state" 2>/dev/null)" != "active=1 key=1 focused=1" ]]; then
    record_not_runnable "$name: the target lost the keyboard focus during the dictation."
    return
  fi

  text="$(cat "$out/text")"
  score="$("$SCRIPT_DIR/lib/word-accuracy.sh" "$phrase" "$text")"
  printf '%s: spoken:   %s\n%s: inserted: %s\n' "$name" "$phrase" "$name" "$text"
  if awk -v s="$score" -v m="$minimum" 'BEGIN { exit !(s + 0 >= m + 0) }'; then
    record_pass "$name: word accuracy $score (minimum $minimum)."
  else
    record_fail "$name: word accuracy $score is under the minimum $minimum."
    app_log_since "$log_start" | tail -n 60 >&2
  fi
}

end_scenario() {
  stop_target
  quit_app
  unset LOCALVOXTRAL_DOGFOOD_AUDIO_FILE
}

# --- preconditions ----------------------------------------------------------

if [[ "$(uname)" != "Darwin" ]]; then
  record_fail "e2e-dictation.sh drives the packaged macOS app and must run on macOS."
  finish
fi

if ! recover_previous_defaults_backup; then
  finish
fi

if [[ ! -d "$APP_PATH" ]]; then
  record_fail "App bundle not found: $APP_PATH (build with LOCALVOXTRAL_DOGFOOD=1 ./scripts/package_app.sh release)."
  finish
fi

# Test seam (test-e2e-dictation-preconditions.sh): no PlistBuddy off macOS.
PLISTBUDDY="${LV_E2E_PLISTBUDDY:-/usr/libexec/PlistBuddy}"
if [[ "$("$PLISTBUDDY" -c 'Print :LVXDogfoodCapture' "$APP_PATH/Contents/Info.plist" 2>/dev/null)" != "true" ]]; then
  record_fail "$APP_PATH is not a dogfood build; only a dogfood build can dictate from a file."
  finish
fi

SCENARIOS=("$@")
if ((${#SCENARIOS[@]} == 0)); then
  SCENARIOS=("$SCRIPT_DIR"/e2e/scenarios/*.scenario)
fi
for scenario in "${SCENARIOS[@]}"; do
  if [[ ! -f "$scenario" ]]; then
    record_fail "Scenario file not found: $scenario"
    finish
  fi
done

lock_state="$("$SCRIPT_DIR/ci/screen-lock-state.sh" 2>/dev/null || echo error)"
if [[ "$lock_state" != "unlocked" ]]; then
  record_not_runnable "The screen is not unlocked (probe: $lock_state); a locked session holds Secure Keyboard Entry."
  finish
fi

if [[ "$REALTIME_ENDPOINT" == "ws://127.0.0.1:8000/"* && -d /Users/Shared/localvoxtral/run ]]; then
  "$SCRIPT_DIR/mac/lv-test-servers.sh" ensure speechd || true
fi
endpoint_authority="${REALTIME_ENDPOINT#*://}"
endpoint_authority="${endpoint_authority%%/*}"
endpoint_host="${endpoint_authority%%:*}"
if [[ "$endpoint_authority" == *:* ]]; then
  endpoint_port="${endpoint_authority##*:}"
elif [[ "$REALTIME_ENDPOINT" == wss://* ]]; then
  endpoint_port=443
else
  endpoint_port=80
fi
if ! nc -z -w 3 "$endpoint_host" "$endpoint_port" >/dev/null 2>&1; then
  record_not_runnable "No STT server answers on $REALTIME_ENDPOINT."
  finish
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-e2e-dictation.XXXXXX")"
if ! build_target_app; then
  record_not_runnable "Could not compile the target app (scripts/e2e/target-app.swift)."
  finish
fi
record_pass "Target app compiled."

announce "localvoxtral end to end check starting. It takes the keyboard for about a minute."
ANNOUNCED=1
sleep 3

# Quit the owner's instance before touching defaults: a running app would see
# the forced modes live and could write its own values back on quit.
quit_owner_app
if pgrep -x "$APP_PROCESS" >/dev/null 2>&1; then
  record_fail "Existing app instance did not quit; cannot launch a fresh instance."
  finish
fi

if ! snapshot_defaults; then
  record_fail "Could not create persistent defaults backup at $PERSISTENT_DEFAULTS_BACKUP; refusing to mutate owner defaults."
  finish
fi
# External dictation so the app talks to the STT test service and spawns no
# helper of its own; polishing off so the inserted text is the transcript.
if ! defaults write "$BUNDLE_ID" settings.dictation_backend_mode -string external_url \
  || ! defaults write "$BUNDLE_ID" settings.polishing_backend_mode -string external_url \
  || ! defaults write "$BUNDLE_ID" settings.realtime_provider -string realtime_api \
  || ! defaults write "$BUNDLE_ID" settings.realtime_api_endpoint_url -string "$REALTIME_ENDPOINT" \
  || ! defaults write "$BUNDLE_ID" settings.realtime_api_model_name -string "$REALTIME_MODEL" \
  || ! defaults write "$BUNDLE_ID" settings.llm_polishing_enabled -bool false \
  || ! defaults write "$BUNDLE_ID" settings.onboarding_completed -bool true \
  || ! defaults write "$BUNDLE_ID" debug.dogfood_control_socket_enabled -bool true; then
  record_fail "Could not write the lane's defaults."
  finish
fi
record_pass "Defaults snapshot captured; external STT, polishing off, control socket on."

for scenario in "${SCENARIOS[@]}"; do
  run_scenario "$scenario"
  end_scenario
done

finish
