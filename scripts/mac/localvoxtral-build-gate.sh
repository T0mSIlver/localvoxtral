#!/usr/bin/env bash
set -euo pipefail

# localvoxtral build gate v2.
#
# This script is intended to be installed as the forced command for the Mac
# build-host SSH key. It keeps the existing build/test/package allowlist and
# adds read-only diagnostics without granting an interactive shell.
#
# Gate v2 install notes:
#   scp scripts/mac/localvoxtral-build-gate.sh <host>:bin/ && ssh <host> chmod +x bin/localvoxtral-build-gate.sh
#
# Run that from a trusted owner session, not through this gate. New diagnostic
# verbs allowed through the gate:
#   diag
#   applog [minutes]    # integer, clamped to 1..120, default 10
#   voxlog [lines]      # integer, clamped to 1..500, default 80
#   svc-status

LOG_FILE="$HOME/Library/Logs/localvoxtral-build-gate.log"
VOXLOG_FILE="$HOME/Library/Logs/voxmlx.log"
VOXMLX_SERVICE="com.localvoxtral.voxmlx"

original_command="${SSH_ORIGINAL_COMMAND:-}"

timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

log_denied() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '%s DENY %s\n' "$(timestamp)" "${original_command:-<empty>}" >>"$LOG_FILE" 2>/dev/null || true
}

deny() {
  log_denied
  printf 'localvoxtral build gate: denied command\n' >&2
  exit 126
}

section() {
  printf '\n== %s ==\n' "$1"
}

run_or_note() {
  if ! "$@" 2>&1; then
    printf '[failed:'
    printf ' %q' "$@"
    printf ']\n'
  fi
}

validate_work_dir() {
  local dir="$1"
  [[ "$dir" =~ ^work/localvoxtral-[A-Za-z0-9._-]+/?$ ]]
}

clamp_integer() {
  local raw="$1"
  local minimum="$2"
  local maximum="$3"

  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  if (( raw < minimum )); then
    printf '%s\n' "$minimum"
  elif (( raw > maximum )); then
    printf '%s\n' "$maximum"
  else
    printf '%s\n' "$raw"
  fi
}

launchctl_target() {
  printf 'gui/%s/%s\n' "$(id -u)" "$VOXMLX_SERVICE"
}

show_versions() {
  section "Versions"
  if command -v sw_vers >/dev/null 2>&1; then
    run_or_note sw_vers
  else
    printf 'sw_vers: not found\n'
  fi
  run_or_note uname -a
  if command -v xcodebuild >/dev/null 2>&1; then
    run_or_note xcodebuild -version
  else
    printf 'xcodebuild: not found\n'
  fi
  if command -v swift >/dev/null 2>&1; then
    run_or_note swift --version
  else
    printf 'swift: not found\n'
  fi
  if command -v rsync >/dev/null 2>&1; then
    (rsync --version 2>&1 || true) | head -n 1
  else
    printf 'rsync: not found\n'
  fi
}

show_processes() {
  section "Processes"
  local process pattern
  for process in localvoxtral voxmlx-serve mlx_lm.server; do
    printf -- '-- %s --\n' "$process"
    if command -v pgrep >/dev/null 2>&1; then
      case "$process" in
        localvoxtral) pattern='(^|/)localvoxtral( |$)' ;;
        voxmlx-serve) pattern='(^|/)voxmlx-serve( |$)' ;;
        mlx_lm.server) pattern='(^|/)mlx_lm[.]server( |$)' ;;
      esac
      pgrep -fl "$pattern" 2>&1 || printf 'not running\n'
    else
      printf 'pgrep: not found\n'
    fi
  done
}

show_ports() {
  section "Ports"
  local port
  for port in 8000 8471 8472; do
    printf -- '-- port %s --\n' "$port"
    if command -v lsof >/dev/null 2>&1; then
      lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>&1 || printf 'no listener\n'
    elif command -v nc >/dev/null 2>&1; then
      nc -vz 127.0.0.1 "$port" 2>&1 || printf 'no listener\n'
    else
      printf 'lsof/nc: not found\n'
    fi
  done
}

show_voxmlx_service() {
  local lines="$1"

  section "launchctl ${VOXMLX_SERVICE}"
  if command -v launchctl >/dev/null 2>&1; then
    (launchctl print "$(launchctl_target)" 2>&1 || true) | head -n "$lines"
  else
    printf 'launchctl: not found\n'
  fi
}

show_voxlog() {
  local lines="$1"

  section "voxmlx.log"
  if [[ -f "$VOXLOG_FILE" ]]; then
    tail -n "$lines" "$VOXLOG_FILE" 2>&1 || true
  else
    printf '%s: not found\n' "$VOXLOG_FILE"
  fi
}

show_applog() {
  local minutes="$1"
  local tail_lines="${2:-}"

  section "localvoxtral unified log"
  if command -v log >/dev/null 2>&1; then
    if [[ -n "$tail_lines" ]]; then
      (log show --style compact --last "${minutes}m" --predicate 'process == "localvoxtral"' 2>&1 || true) | tail -n "$tail_lines"
    else
      log show --style compact --last "${minutes}m" --predicate 'process == "localvoxtral"'
    fi
  else
    printf 'log: not found\n'
  fi
}

run_diag() {
  show_versions
  show_processes
  show_ports
  show_voxmlx_service 20
  show_voxlog 20
  show_applog 10 60
}

run_applog_command() {
  local minutes="${1:-10}"

  minutes="$(clamp_integer "$minutes" 1 120)" || deny
  show_applog "$minutes"
}

run_voxlog_command() {
  local lines="${1:-80}"

  lines="$(clamp_integer "$lines" 1 500)" || deny
  show_voxlog "$lines"
}

run_svc_status() {
  show_voxmlx_service 40
}

# Fail-closed metacharacter blocklist. Note the glob subtlety: a `]` inside
# the bracket expression terminates the set early, so part of this pattern
# matches as literal text — empirically ALL listed characters still block
# (verified on bash 5; bash 3.2 glob semantics are the same vintage), and the
# exact-prefix checks below are an independent second layer. Over-blocking is
# acceptable here; never "fix" this toward permissiveness without re-testing.
payload_has_safe_chars() {
  local payload="$1"
  case "$payload" in
    *[$'\n\r`$;&|<>(){}[]!*?~#\\']*) return 1 ;;
    *) return 0 ;;
  esac
}

payload_starts_with_command() {
  local payload="$1"
  local allowed="$2"

  [[ "$payload" == "$allowed" || "$payload" == "$allowed "* ]]
}

allow_build_payload() {
  local payload="$1"
  local integration_prefix="env VLLM_REALTIME_TEST_ENABLE=1 VLLM_REALTIME_TEST_MODEL=T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit swift test --filter RealtimeAPIVLLMIntegrationTests"

  payload_has_safe_chars "$payload" || return 1

  if payload_starts_with_command "$payload" "swift build"; then
    return 0
  fi
  if payload_starts_with_command "$payload" "swift test"; then
    return 0
  fi
  if payload_starts_with_command "$payload" "$integration_prefix"; then
    return 0
  fi
  if payload_starts_with_command "$payload" "./scripts/package_app.sh release"; then
    return 0
  fi

  return 1
}

run_cd_command() {
  local command="$1"
  local after_cd dir payload

  [[ "$command" == cd\ work/localvoxtral-* ]] || deny
  after_cd="${command#cd }"
  [[ "$after_cd" == *" && "* ]] || deny

  dir="${after_cd%% && *}"
  payload="${after_cd#"$dir && "}"

  validate_work_dir "$dir" || deny
  allow_build_payload "$payload" || deny

  cd "$HOME/${dir%/}"
  exec /bin/bash -c "$payload"
}

run_bash_lc_command() {
  local command="$1"
  local inner

  inner="${command#bash -lc }"
  case "$inner" in
    \"*\")
      inner="${inner#\"}"
      inner="${inner%\"}"
      ;;
    \'*\')
      inner="${inner#\'}"
      inner="${inner%\'}"
      ;;
  esac

  run_cd_command "$inner"
}

run_mkdir_command() {
  local dir="${1#mkdir -p }"

  validate_work_dir "$dir" || deny
  mkdir -p "$HOME/${dir%/}"
}

run_rsync_command() {
  local -a argv
  local argc dest

  read -r -a argv <<<"$1"
  argc="${#argv[@]}"
  (( argc == 6 )) || deny

  [[ "${argv[0]}" == "rsync" ]] || deny
  [[ "${argv[1]}" == "--server" ]] || deny
  if [[ "${argv[2]}" != "-logDtprze.iLsfxCIvu" ]]; then
    # Deliberately pinned to the exact flag string the current rsync client
    # sends. If rsync was upgraded on either end, this is the line to update
    # (compare against a logged deny below).
    deny
  fi
  [[ "${argv[3]}" == "--delete" ]] || deny
  [[ "${argv[argc - 2]}" == "." ]] || deny

  dest="${argv[argc - 1]}"
  validate_work_dir "$dest" || deny

  cd "$HOME"
  exec rsync "${argv[@]:1}"
}

case "$original_command" in
  diag)
    run_diag
    ;;
  applog)
    run_applog_command
    ;;
  applog\ *)
    arg="${original_command#applog }"
    [[ "$arg" != *" "* && -n "$arg" ]] || deny
    run_applog_command "$arg"
    ;;
  voxlog)
    run_voxlog_command
    ;;
  voxlog\ *)
    arg="${original_command#voxlog }"
    [[ "$arg" != *" "* && -n "$arg" ]] || deny
    run_voxlog_command "$arg"
    ;;
  svc-status)
    run_svc_status
    ;;
  mkdir\ -p\ work/localvoxtral-*)
    run_mkdir_command "$original_command"
    ;;
  rsync\ --server\ *)
    run_rsync_command "$original_command"
    ;;
  cd\ work/localvoxtral-*)
    run_cd_command "$original_command"
    ;;
  bash\ -lc\ *)
    run_bash_lc_command "$original_command"
    ;;
  *)
    deny
    ;;
esac
