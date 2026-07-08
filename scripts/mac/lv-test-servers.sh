#!/usr/bin/env bash
set -euo pipefail

# lv-test-servers.sh — on-demand lifecycle for the Mac build host's model
# serving TEST services (NOT the app-managed backends).
#
# Two launchd LaunchAgents in the GUI-owner domain serve the integration/eval
# suites:
#   com.localvoxtral.voxmlx  port 8000  websocket realtime STT (tier-1)
#   com.localvoxtral.mlxlm   port 8080  http chat/completions  (eval-llm)
#
# Keeping their multi-GB weights resident 24/7 wastes RAM. Instead both agents
# are configured launch-on-demand via a KeepAlive `PathState` TRIGGER FILE
# (RunAtLoad false, KeepAlive { PathState { <trigger>: true } }): launchd runs
# the server while the trigger file EXISTS and stops it (freeing the weights)
# when it is removed. See scripts/mac/README.md for the plists.
#
# Two file kinds live in the world-writable run dir:
#   <name>.want         the launchd trigger — its EXISTENCE means "run".
#   <name>.seen.<uid>   a per-caller activity stamp — its MTIME means "last
#                       used by uid". The idle reaper keys off the NEWEST
#                       stamp across all callers.
# They are split because the run dir is a shared, sticky, world-writable dir:
# any account can CREATE a file, but only its owner (or the dir owner) can
# update/delete it. So each caller starts a server by creating the shared
# trigger (create-if-absent — allowed for everyone) and records activity by
# touching ITS OWN stamp (always permitted). The reaper runs as the run-dir
# owner, so the sticky-bit exemption lets it delete any caller's files.
#
# Used from three places:
#   * `ensure <name>`  — a consumer (CI, remote-build's ensure step, or a
#                        person) calls this BEFORE running tests. It creates the
#                        trigger (starting the server if down), stamps its own
#                        activity file (resetting the idle window), and blocks
#                        until the port is healthy so weights are warm before
#                        the first request. A burst of runs reuses one warm
#                        process — no cold reload every few seconds.
#   * `reap`           — the idle-reaper LaunchAgent
#                        (com.localvoxtral.testservers-reaper) runs this on a
#                        StartInterval. If the newest activity stamp is older
#                        than the idle window it removes the trigger, which
#                        stops the server and releases its RAM.
#   * `status`         — human/CI readout of trigger + activity + port state.
#
# The trigger design is deliberately cross-user: launchd watches an absolute
# path in the owner's domain, but any account that can write the run dir (the
# CI runner user, the SSH build-gate account, the owner) can start a server
# without a `launchctl` call into another user's GUI domain (forbidden without
# root). The SSH build gate (scripts/mac/localvoxtral-build-gate.sh) reimplements
# the ensure logic INLINE rather than exec'ing this script, so its security
# review stays self-contained; keep the paths/ports/probes below in sync.
#
# Robustness: an interrupted run or a sleeping Mac just leaves the trigger and
# stamps in place — the server stays warm and the reaper collects it after the
# idle window. There is no lock to get stuck and no process to orphan (launchd
# owns every server; removing the trigger is a clean SIGTERM).

# ---- configuration (keep in sync with the gate's `ensure` verb + plists) ----

RUN_DIR="${LV_TEST_SERVER_RUN_DIR:-/Users/Shared/localvoxtral/run}"
# Idle window: how long a server may sit unused before the reaper frees it.
# Default 20 min — long enough that an interactive session or a burst of CI
# runs reuses warm weights, short enough that an idle machine reclaims the RAM.
IDLE_SECONDS="${LV_TEST_SERVER_IDLE_SECONDS:-1200}"
# Cold-start budget: model load + (for MLX) first-run Metal JIT can be slow.
READY_TIMEOUT="${LV_TEST_SERVER_READY_TIMEOUT:-180}"
PORT_TIMEOUT=2

ALL_SERVICES=(voxmlx mlxlm)

trigger_for() {
  case "$1" in
    voxmlx) printf '%s/voxmlx.want\n' "$RUN_DIR" ;;
    mlxlm)  printf '%s/mlxlm.want\n' "$RUN_DIR" ;;
    *) return 1 ;;
  esac
}
port_for() {
  case "$1" in
    voxmlx) printf '8000\n' ;;
    mlxlm)  printf '8080\n' ;;
    *) return 1 ;;
  esac
}
# voxmlx exposes a websocket, not a documented HTTP readiness route, so it uses
# a TCP-accept probe (uvicorn binds the port only after startup/model-load).
# mlxlm answers GET /v1/models once weights are resident — a real readiness
# signal — so it uses http.
probe_for() {
  case "$1" in
    voxmlx) printf 'tcp\n' ;;
    mlxlm)  printf 'http:/v1/models\n' ;;
    *) return 1 ;;
  esac
}

# ---- probes ------------------------------------------------------------------

tcp_ok() {
  local port="$1"
  nc -z -G "$PORT_TIMEOUT" -w "$PORT_TIMEOUT" 127.0.0.1 "$port" >/dev/null 2>&1
}

http_ok() {
  local port="$1" path="$2"
  curl -fsS -o /dev/null --max-time "$PORT_TIMEOUT" \
    "http://127.0.0.1:${port}${path}" >/dev/null 2>&1
}

healthy() {
  local name="$1" port probe
  port="$(port_for "$name")"
  probe="$(probe_for "$name")"
  case "$probe" in
    tcp) tcp_ok "$port" ;;
    http:*) http_ok "$port" "${probe#http:}" ;;
    *) return 1 ;;
  esac
}

# Newest activity mtime (epoch secs) across this service's stamps + trigger, or
# empty if none exists. The trigger is included as a fallback so a
# manually-created trigger with no stamp still ages out.
newest_activity() {
  local name="$1"
  # shellcheck disable=SC2012
  ls -1 "$RUN_DIR/${name}.seen."* "$(trigger_for "$name")" 2>/dev/null \
    | while read -r f; do stat -f %m "$f" 2>/dev/null || true; done \
    | sort -n | tail -1
}

# ---- commands ----------------------------------------------------------------

ensure_one() {
  local name="$1" trigger port stamp
  trigger="$(trigger_for "$name")" || { echo "unknown service: $name" >&2; return 2; }
  port="$(port_for "$name")"
  stamp="$RUN_DIR/${name}.seen.$(id -u)"

  if [[ ! -d "$RUN_DIR" ]]; then
    cat >&2 <<MSG
lv-test-servers: run dir missing: $RUN_DIR
The GUI owner must create it once (world-writable so any account can trigger a
start, owned by the reaper's user so it can clean up) and bootstrap the
on-demand LaunchAgents — see scripts/mac/README.md:
  sudo install -d -m 1777 -o "\$(id -un)" $RUN_DIR
MSG
    return 1
  fi

  # Create the shared trigger if absent (launchd PathState then starts the
  # server). Create-if-absent works for any account in the sticky run dir; we
  # never modify an existing trigger owned by another user.
  if [[ ! -e "$trigger" ]]; then
    : >"$trigger" 2>/dev/null || {
      echo "lv-test-servers: cannot create trigger $trigger (run dir not writable?)" >&2
      return 1
    }
  fi
  # Stamp our own activity file — always permitted (we own it) — to reset the
  # idle window regardless of who created the trigger.
  touch "$stamp" 2>/dev/null || {
    echo "lv-test-servers: cannot write activity stamp $stamp" >&2
    return 1
  }

  # Warm path: already serving — return immediately so bursts are cheap.
  if healthy "$name"; then
    echo "ensure $name: already warm (port $port)"
    return 0
  fi

  echo "ensure $name: cold — waiting up to ${READY_TIMEOUT}s for port $port..."
  local waited=0
  while (( waited < READY_TIMEOUT )); do
    if healthy "$name"; then
      echo "ensure $name: ready after ${waited}s (port $port)"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  cat >&2 <<MSG
ensure $name: NOT ready after ${READY_TIMEOUT}s (port $port).
Likely the LaunchAgent com.localvoxtral.${name} is not bootstrapped in the
owner's GUI domain, or the model failed to load. Check:
  launchctl print gui/\$(id -u)/com.localvoxtral.${name}
  tail /Users/Shared/localvoxtral/${name}.log
See scripts/mac/README.md.
MSG
  return 1
}

cmd_ensure() {
  local target="${1:-all}"
  local -a names
  if [[ "$target" == "all" ]]; then
    names=("${ALL_SERVICES[@]}")
  else
    names=("$target")
  fi
  local rc=0
  for name in "${names[@]}"; do
    ensure_one "$name" || rc=$?
  done
  return "$rc"
}

cmd_reap() {
  # If the newest activity stamp is older than the idle window, remove the
  # trigger (launchd stops the server, freeing weights) and clean the stamps.
  # Must run as the run-dir owner so the sticky-bit exemption allows deleting
  # other accounts' trigger/stamp files.
  local now newest age trigger
  now="$(date +%s)"
  for name in "${ALL_SERVICES[@]}"; do
    trigger="$(trigger_for "$name")"
    [[ -e "$trigger" ]] || continue
    newest="$(newest_activity "$name")"
    [[ "$newest" =~ ^[0-9]+$ ]] || newest=0
    age=$((now - newest))
    if (( age >= IDLE_SECONDS )); then
      rm -f "$trigger" "$RUN_DIR/${name}.seen."* 2>/dev/null || true
      echo "reap $name: idle ${age}s >= ${IDLE_SECONDS}s — stopped (trigger removed)"
    else
      echo "reap $name: active (idle ${age}s < ${IDLE_SECONDS}s) — kept warm"
    fi
  done
}

cmd_status() {
  local trigger port now newest
  now="$(date +%s)"
  for name in "${ALL_SERVICES[@]}"; do
    trigger="$(trigger_for "$name")"
    port="$(port_for "$name")"
    local trig_state="absent" health_state="down" idle="-"
    if [[ -e "$trigger" ]]; then
      trig_state="present"
      newest="$(newest_activity "$name")"
      [[ "$newest" =~ ^[0-9]+$ ]] && idle="$((now - newest))s"
    fi
    healthy "$name" && health_state="up"
    printf '%-8s trigger=%-8s idle=%-8s port %s: %s\n' \
      "$name" "$trig_state" "$idle" "$port" "$health_state"
  done
}

usage() {
  cat >&2 <<'MSG'
usage: lv-test-servers.sh <ensure [voxmlx|mlxlm|all] | reap | status>
  ensure  start (if down) and block until the named server(s) are warm;
          resets the idle window. Default target: all.
  reap    stop any server idle longer than the idle window (reaper LaunchAgent;
          must run as the run-dir owner).
  status  print trigger + activity + port health for both services.
MSG
}

case "${1:-}" in
  ensure) shift; cmd_ensure "${1:-all}" ;;
  reap)   cmd_reap ;;
  status) cmd_status ;;
  ""|-h|--help) usage; exit 2 ;;
  *) echo "unknown command: $1" >&2; usage; exit 2 ;;
esac
