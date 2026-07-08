#!/usr/bin/env bash
set -euo pipefail

# localvoxtral build gate v2.
#
# This script is intended to be installed as the forced command for the Mac
# build-host SSH key. It keeps the existing build/test/package allowlist and
# adds read-only diagnostics without granting an interactive shell.
#
# Gate v2 install notes: see scripts/mac/README.md. Install from a trusted
# owner session, not through this gate. New diagnostic verbs allowed through
# the gate:
#   diag
#   applog [minutes]    # integer, clamped to 1..120, default 10
#   voxlog [lines]      # integer, clamped to 1..500, default 80
#   svc-status
#   ensure <voxmlx|mlxlm|all>   # warm an on-demand test server (touch + poll)

LOG_FILE="$HOME/Library/Logs/localvoxtral-build-gate.log"
VOXLOG_FILE="$HOME/Library/Logs/voxmlx.log"
VOXMLX_SERVICE="com.localvoxtral.voxmlx"
# The GUI-session uid whose launchd domain hosts the voxmlx service. The gate
# account is deliberately not that user, so launchctl needs to be told.
VOXMLX_GUI_UID="$(id -u)"

# On-demand test-server triggers (see scripts/mac/lv-test-servers.sh — keep the
# paths/ports/probes in sync). The `ensure` verb touches a trigger file, which
# launchd's KeepAlive PathState turns into a server start, then polls the port
# until the model is warm. The touch is a bounded, low-risk write into a
# world-writable run dir; the gate does it INLINE (rather than exec'ing the
# helper) so this reviewed script stays the whole trust boundary.
LV_RUN_DIR="/Users/Shared/localvoxtral/run"
LV_ENSURE_READY_TIMEOUT=180
LV_ENSURE_PROBE_TIMEOUT=2

# Machine-local overrides (never committed): the gate account is separate
# from the GUI owner account, so voxmlx's log path and GUI uid differ per
# machine. Anyone who can write this file can already replace the gate
# script itself, so sourcing it adds no new trust.
GATE_CONF="$HOME/.localvoxtral-gate.conf"
if [[ -f "$GATE_CONF" ]]; then
  # shellcheck source=/dev/null
  source "$GATE_CONF"
fi

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
  printf 'gui/%s/%s\n' "$VOXMLX_GUI_UID" "$VOXMLX_SERVICE"
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
  local process pattern pids
  for process in localvoxtral voxmlx-serve mlx_lm.server; do
    printf -- '-- %s --\n' "$process"
    if command -v pgrep >/dev/null 2>&1; then
      case "$process" in
        localvoxtral) pattern='(^|/)localvoxtral( |$)' ;;
        voxmlx-serve) pattern='(^|/)voxmlx-serve( |$)' ;;
        mlx_lm.server) pattern='(^|/)mlx_lm[.]server( |$)' ;;
      esac
      # pid/user/executable only — NEVER full command lines: other users'
      # cmdlines can carry secrets in embedded env assignments (a Zed
      # remote-ssh cmdline leaked a GitHub PAT through diag, 2026-07-05),
      # and this output flows into agent transcripts and logs.
      pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
      if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        ps -o pid=,user=,comm= -p $pids 2>/dev/null || printf 'pids: %s\n' "$pids"
      else
        printf 'not running\n'
      fi
    else
      printf 'pgrep: not found\n'
    fi
  done
}

show_ports() {
  section "Ports"
  local port
  # 8000 = voxmlx launchd service, 8080 = mlx-lm eval launchd service,
  # 8471/8472 = app-managed voxmlx/mlx-lm.
  for port in 8000 8080 8471 8472; do
    printf -- '-- port %s --\n' "$port"
    # Connect test first: lsof only sees this account's sockets, so it
    # reported "no listener" while another user's voxmlx was serving.
    if command -v nc >/dev/null 2>&1; then
      if nc -z -w 2 127.0.0.1 "$port" >/dev/null 2>&1; then
        printf 'listening (connect test)\n'
      else
        printf 'no listener (connect test)\n'
      fi
    elif command -v lsof >/dev/null 2>&1; then
      lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>&1 || printf 'no listener\n'
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
    # Size/mtime line so an empty file is distinguishable from a missing one
    # when diagnosing remotely.
    ls -l "$VOXLOG_FILE" 2>/dev/null || true
    tail -n "$lines" "$VOXLOG_FILE" 2>&1 || true
  else
    printf '%s: not found\n' "$VOXLOG_FILE"
  fi
}

show_applog() {
  local minutes="$1"
  local tail_lines="${2:-}"
  local output

  section "localvoxtral unified log"
  if command -v log >/dev/null 2>&1; then
    output="$(log show --style compact --last "${minutes}m" --predicate 'process == "localvoxtral"' 2>&1 || true)"
    if [[ -n "$tail_lines" ]]; then
      printf '%s\n' "$output" | tail -n "$tail_lines"
    else
      printf '%s\n' "$output"
    fi
    if [[ "$output" == *"not permitted"* ]]; then
      printf '(unified log access is restricted for this account — dispatch mac-crashlog.yml for app logs)\n'
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
  # launchctl can't read another user's GUI domain, so when the gate account
  # is not the service owner the print above comes back empty — processes and
  # ports still answer the question that matters: is voxmlx up and serving?
  show_processes
  show_ports
}

# Map an on-demand service name to its trigger file, port, and readiness probe.
# Mirrors scripts/mac/lv-test-servers.sh; changing one means changing both.
lv_service_trigger() {
  case "$1" in
    voxmlx) printf '%s/voxmlx.want\n' "$LV_RUN_DIR" ;;
    mlxlm)  printf '%s/mlxlm.want\n' "$LV_RUN_DIR" ;;
    *) return 1 ;;
  esac
}
lv_service_port() {
  case "$1" in
    voxmlx) printf '8000\n' ;;
    mlxlm)  printf '8080\n' ;;
    *) return 1 ;;
  esac
}
lv_service_healthy() {
  # voxmlx: TCP accept (uvicorn binds only after model load, no HTTP route).
  # mlxlm: GET /v1/models returns 200 once weights are resident.
  local name="$1" port
  port="$(lv_service_port "$name")" || return 1
  case "$name" in
    voxmlx)
      nc -z -G "$LV_ENSURE_PROBE_TIMEOUT" -w "$LV_ENSURE_PROBE_TIMEOUT" \
        127.0.0.1 "$port" >/dev/null 2>&1
      ;;
    mlxlm)
      curl -fsS -o /dev/null --max-time "$LV_ENSURE_PROBE_TIMEOUT" \
        "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

ensure_one_service() {
  local name="$1" trigger port stamp waited=0
  trigger="$(lv_service_trigger "$name")" || { printf 'ensure: unknown service %s\n' "$name" >&2; return 2; }
  port="$(lv_service_port "$name")"
  stamp="$LV_RUN_DIR/${name}.seen.$(id -u)"

  if [[ ! -d "$LV_RUN_DIR" ]]; then
    printf 'ensure %s: run dir %s missing — owner must create it (see scripts/mac/README.md)\n' \
      "$name" "$LV_RUN_DIR" >&2
    return 1
  fi

  # Create the shared trigger if absent (launchd PathState starts the server).
  # Atomic O_EXCL create (`set -C` = noclobber) so a concurrent ensure from
  # another account can't make us truncate a trigger we don't own (permission
  # denied in the sticky run dir). If it already exists — whoever created it —
  # that's success; only a genuinely unwritable run dir fails the post-check.
  # Then stamp our own activity file to reset the idle window. (Mirrors
  # scripts/mac/lv-test-servers.sh ensure_one.)
  if [[ ! -e "$trigger" ]]; then
    ( set -C; : >"$trigger" ) 2>/dev/null || true
  fi
  if [[ ! -e "$trigger" ]]; then
    printf 'ensure %s: cannot create trigger %s\n' "$name" "$trigger" >&2
    return 1
  fi
  touch "$stamp" 2>/dev/null || {
    printf 'ensure %s: cannot write activity stamp %s\n' "$name" "$stamp" >&2
    return 1
  }

  if lv_service_healthy "$name"; then
    printf 'ensure %s: already warm (port %s)\n' "$name" "$port"
    return 0
  fi

  printf 'ensure %s: cold — waiting up to %ss for port %s...\n' "$name" "$LV_ENSURE_READY_TIMEOUT" "$port"
  while (( waited < LV_ENSURE_READY_TIMEOUT )); do
    if lv_service_healthy "$name"; then
      printf 'ensure %s: ready after %ss (port %s)\n' "$name" "$waited" "$port"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  printf 'ensure %s: NOT ready after %ss (port %s) — is com.localvoxtral.%s bootstrapped?\n' \
    "$name" "$LV_ENSURE_READY_TIMEOUT" "$port" "$name" >&2
  return 1
}

run_ensure_command() {
  local target="$1"
  case "$target" in
    voxmlx|mlxlm) ensure_one_service "$target" ;;
    all)
      local rc=0
      ensure_one_service voxmlx || rc=$?
      ensure_one_service mlxlm || rc=$?
      return "$rc"
      ;;
    *) deny ;;
  esac
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
  ensure\ *)
    arg="${original_command#ensure }"
    [[ "$arg" != *" "* && -n "$arg" ]] || deny
    run_ensure_command "$arg"
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
