#!/usr/bin/env bash
set -euo pipefail

# lv-test-servers.sh — on-demand lifecycle for the Mac build host's model
# serving TEST services (NOT the app-managed backends).
#
# Two launchd LaunchAgents in the GUI-owner domain serve the integration/eval
# suites. As of the 2026-07 migration these are the app's OWN bundled Swift
# helpers (the retired Python voxmlx/mlx-lm services ran here before):
#   com.localvoxtral.testspeechd  port 8000  websocket realtime STT  (speechd)
#   com.localvoxtral.testpolishd  port 8080  http chat/completions   (polishd)
# The short service names are `speechd` / `polishd`; `voxmlx` / `mlxlm` remain
# accepted as DEPRECATED ALIASES so already-installed gates and un-updated
# checkouts keep working across the swap.
#
# Two file kinds live in the world-writable run dir:
#   <fskey>.want         the launchd trigger — its EXISTENCE means "run".
#   <fskey>.seen.<uid>   a per-caller activity stamp — its MTIME means "last
#                        used by uid". The idle reaper keys off the NEWEST
#                        stamp across all callers.
# The trigger/stamp FILESYSTEM KEYS are deliberately kept at the retired names
# `voxmlx` / `mlxlm` (voxmlx.want / mlxlm.want) even though the services are
# now speechd/polishd: these paths are the cross-generation rendezvous. An
# already-installed gate and an un-updated reaper touch and read exactly these
# paths, and the newly-bootstrapped testspeechd/testpolishd plists watch the
# SAME paths (see scripts/mac/README.md) — so warming and idle-accounting keep
# working through the swap with no gate/reaper reinstall required. Renaming
# them would break that window; do not, without also renaming the plist
# PathState keys AND reinstalling the gate + reaper in the same change.
#
# They are split because the run dir is a shared, sticky, world-writable dir:
# any account can CREATE a file, but only its owner (or the dir owner) can
# update/delete it. So each caller starts a server by creating the shared
# trigger (create-if-absent — allowed for everyone) and records activity by
# touching ITS OWN stamp (always permitted). The reaper runs as the run-dir
# owner, so the sticky-bit exemption lets it delete any caller's files.
#
# Used from four places:
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
#                        than the idle window it removes the trigger and sends
#                        the job an explicit SIGTERM, stopping the server and
#                        releasing its RAM.
#   * `stop <name>`    — a person unloading NOW, without waiting for the idle
#                        window (same stop path as reap: trigger removed,
#                        TERM→KILL, blocks until the port closes).
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
# The bundled helpers NEVER auto-download weights (a missing model makes
# speechd/polishd log an error and exit, so launchd relaunch-loops it and the
# health probe just times out with a clear "NOT ready" message — never a silent
# serve of the wrong thing). The owner pre-downloads the pinned models into the
# service account's Hugging Face cache once — see scripts/mac/README.md.
#
# Robustness: an interrupted run or a sleeping Mac just leaves the trigger and
# stamps in place — the server stays warm and the reaper collects it after the
# idle window. There is no lock to get stuck and no process to orphan: launchd
# owns every server, and the reaper stops an idle one by removing its trigger
# (so launchd won't relaunch it) and then SIGTERM'ing the running process.

# ---- configuration (keep in sync with the gate's `ensure` verb + plists) ----

RUN_DIR="${LV_TEST_SERVER_RUN_DIR:-/Users/Shared/localvoxtral/run}"
# Idle window: how long a server may sit unused before the reaper frees it.
# Default 20 min — long enough that an interactive session or a burst of CI
# runs reuses warm weights, short enough that an idle machine reclaims the RAM.
IDLE_SECONDS="${LV_TEST_SERVER_IDLE_SECONDS:-1200}"
# Cold-start budget: model load + (for MLX) first-run Metal JIT can be slow.
READY_TIMEOUT="${LV_TEST_SERVER_READY_TIMEOUT:-180}"
# How long reap waits for a SIGTERM'd server to close its port before it
# escalates to SIGKILL. The MLX server drains gracefully in ~2-3s; this is the
# ceiling before we stop being polite.
STOP_GRACE="${LV_TEST_SERVER_STOP_GRACE:-8}"
PORT_TIMEOUT=2

# Stable installed copy of the packaged .app whose Metal-capable helper
# binaries the plists run. The helpers MUST come from a packaged (xcodebuild)
# bundle — a bare `swift build` binary cannot load its metallib at runtime — so
# `install-helpers` copies a package_app.sh / try-pr.sh / release .app here and
# the plists point at
#   $STABLE_APP/Contents/MacOS/localvoxtral-speechd   (port 8000)
#   $STABLE_APP/Contents/MacOS/localvoxtral-polishd   (port 8080)
STABLE_APP="${LV_TEST_SERVER_APP:-/Users/Shared/localvoxtral/testservers/localvoxtral.app}"

# Canonical service names, iterated by reap/status. Deprecated aliases
# (voxmlx→speechd, mlxlm→polishd) are accepted on the command line via canonical().
ALL_SERVICES=(speechd polishd)

# Normalize a canonical name or a deprecated alias to the canonical name.
canonical() {
  case "$1" in
    speechd|voxmlx) printf 'speechd\n' ;;
    polishd|mlxlm)  printf 'polishd\n' ;;
    *) return 1 ;;
  esac
}
# Stable trigger/stamp filesystem key (see header) — retained at the retired
# names so old gates/reapers/plists keep rendezvousing on the same paths.
fskey_for() {
  case "$(canonical "$1" 2>/dev/null)" in
    speechd) printf 'voxmlx\n' ;;
    polishd) printf 'mlxlm\n' ;;
    *) return 1 ;;
  esac
}
trigger_for() {
  local key
  key="$(fskey_for "$1")" || return 1
  printf '%s/%s.want\n' "$RUN_DIR" "$key"
}
stamp_prefix_for() {
  local key
  key="$(fskey_for "$1")" || return 1
  printf '%s/%s.seen.' "$RUN_DIR" "$key"
}
port_for() {
  case "$(canonical "$1" 2>/dev/null)" in
    speechd) printf '8000\n' ;;
    polishd) printf '8080\n' ;;
    *) return 1 ;;
  esac
}
# launchd labels to signal on stop. Both generations are listed so the reaper
# tears down whichever plist is currently loaded (the retired Python
# voxmlx/mlxlm, or the new testspeechd/testpolishd) — plus the port-bound
# fallback below covers anything launchctl can't reach.
labels_for() {
  case "$(canonical "$1" 2>/dev/null)" in
    speechd) printf 'com.localvoxtral.testspeechd com.localvoxtral.voxmlx\n' ;;
    polishd) printf 'com.localvoxtral.testpolishd com.localvoxtral.mlxlm\n' ;;
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

# speechd (8000) exposes a websocket, not a documented HTTP readiness route, and
# loads its model BEFORE binding the listener, so a TCP-accept probe is a real
# readiness signal (matching the retired voxmlx uvicorn behavior).
#
# polishd (8080) serves GET /health once its model is resident — its readiness
# contract, and the probe to use going forward. The retired mlx-lm answered GET
# /v1/models instead. So the 8080 probe accepts EITHER route: /health OR
# /v1/models. This makes the probe correct against BOTH generations behind the
# port, so warming stays green before AND after the owner swaps the plist. (The
# gate mirrors this — see localvoxtral-build-gate.sh; the INSTALLED gate only
# picks up the /health arm when the owner reinstalls it.)
healthy() {
  local name="$1" port
  port="$(port_for "$name")" || return 1
  case "$(canonical "$name" 2>/dev/null)" in
    speechd) tcp_ok "$port" ;;
    polishd) http_ok "$port" "/health" || http_ok "$port" "/v1/models" ;;
    *) return 1 ;;
  esac
}

# Newest activity mtime (epoch secs) across this service's stamps + trigger, or
# empty if none exists. The trigger is included as a fallback so a
# manually-created trigger with no stamp still ages out.
newest_activity() {
  local name="$1" prefix trigger
  prefix="$(stamp_prefix_for "$name")" || return 1
  trigger="$(trigger_for "$name")"
  # shellcheck disable=SC2012
  ls -1 "${prefix}"* "$trigger" 2>/dev/null \
    | while read -r f; do stat -f %m "$f" 2>/dev/null || true; done \
    | sort -n | tail -1
}

# ---- commands ----------------------------------------------------------------

ensure_one() {
  local name="$1" cname trigger port stamp
  cname="$(canonical "$name")" || { echo "unknown service: $name" >&2; return 2; }
  trigger="$(trigger_for "$cname")"
  port="$(port_for "$cname")"
  stamp="$(stamp_prefix_for "$cname")$(id -u)"

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
  # server). Use an atomic O_EXCL create (`set -C` = noclobber) so a concurrent
  # ensure from ANOTHER account can't make us truncate a trigger we don't own —
  # a plain `>` would try to O_TRUNC the racer's file and hit permission-denied
  # in the sticky run dir, failing a legitimate build. If the trigger already
  # exists (whoever created it) that's success; only a genuinely unwritable run
  # dir is an error, which the post-check catches.
  if [[ ! -e "$trigger" ]]; then
    ( set -C; : >"$trigger" ) 2>/dev/null || true
  fi
  if [[ ! -e "$trigger" ]]; then
    echo "lv-test-servers: cannot create trigger $trigger (run dir not writable?)" >&2
    return 1
  fi
  # Stamp our own activity file — always permitted (we own it) — to reset the
  # idle window regardless of who created the trigger.
  touch "$stamp" 2>/dev/null || {
    echo "lv-test-servers: cannot write activity stamp $stamp" >&2
    return 1
  }

  # Warm path: already serving — return immediately so bursts are cheap.
  if healthy "$cname"; then
    echo "ensure $cname: already warm (port $port)"
    return 0
  fi

  echo "ensure $cname: cold — waiting up to ${READY_TIMEOUT}s for port $port..."
  local waited=0
  while (( waited < READY_TIMEOUT )); do
    if healthy "$cname"; then
      echo "ensure $cname: ready after ${waited}s (port $port)"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  local labels
  labels="$(labels_for "$cname")"
  cat >&2 <<MSG
ensure $cname: NOT ready after ${READY_TIMEOUT}s (port $port).
Likely one of these LaunchAgents is not bootstrapped in the owner's GUI domain,
or the pinned model is not in the service account's HF cache (the helpers do
not auto-download). Check:
  launchctl print gui/\$(id -u)/com.localvoxtral.testspeechd  # or testpolishd
  tail /Users/Shared/localvoxtral/${cname}.log
See scripts/mac/README.md (labels tried: ${labels}).
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

# Stop a running server and free its weights. Shared by `reap` (when idle) and
# `stop` (manual/immediate). Removing the PathState trigger stops launchd from
# RESTARTING the job, but launchd does NOT reliably terminate an already-running
# process when a KeepAlive condition flips false — so we drop the trigger FIRST
# (so launchd won't relaunch the instant we kill it) then SIGTERM the job(s),
# which tears down its whole process tree. The MLX server drains gracefully in
# ~2-3s; block until the port closes, and escalate to SIGKILL — plus, as a last
# resort, kill whatever still binds the port (only this test service does) — if
# it's still up after STOP_GRACE. Both generation labels are signaled so this
# works whether the retired Python plist or the new helper plist is loaded; the
# port-bound fallback covers any label launchctl cannot reach. The kill MUST
# finish here: once the trigger is gone a later reap run skips this service, so
# a server that ignored SIGTERM would leak forever. Must run as the GUI-owner
# (the reaper's user): `launchctl kill` into gui/$(id -u) needs the owning
# domain, and the sticky run-dir owner can delete any account's trigger/stamps.
# Echoes a short outcome fragment for the caller.
stop_one() {
  local name="$1" cname trigger prefix uid port label pids waited=0
  cname="$(canonical "$name")" || return 2
  trigger="$(trigger_for "$cname")"
  prefix="$(stamp_prefix_for "$cname")"
  uid="$(id -u)"
  port="$(port_for "$cname")"
  rm -f "$trigger" "${prefix}"* 2>/dev/null || true
  for label in $(labels_for "$cname"); do
    launchctl kill SIGTERM "gui/${uid}/${label}" 2>/dev/null || true
  done
  while (( waited < STOP_GRACE )) && healthy "$cname"; do sleep 1; waited=$((waited + 1)); done
  if healthy "$cname"; then
    for label in $(labels_for "$cname"); do
      launchctl kill SIGKILL "gui/${uid}/${label}" 2>/dev/null || true
    done
    pids="$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    [[ -n "$pids" ]] && kill -KILL $pids 2>/dev/null || true
    echo "stopped (SIGTERM ignored → SIGKILL after ${waited}s)"
  else
    echo "stopped (trigger removed + SIGTERM, drained in ${waited}s)"
  fi
}

cmd_reap() {
  # Stop any server idle longer than the window; leave the rest warm.
  local now newest age trigger
  now="$(date +%s)"
  for name in "${ALL_SERVICES[@]}"; do
    trigger="$(trigger_for "$name")"
    [[ -e "$trigger" ]] || continue
    newest="$(newest_activity "$name")"
    [[ "$newest" =~ ^[0-9]+$ ]] || newest=0
    age=$((now - newest))
    if (( age >= IDLE_SECONDS )); then
      printf 'reap %s: idle %ss >= %ss — %s\n' "$name" "$age" "$IDLE_SECONDS" "$(stop_one "$name")"
    else
      echo "reap $name: active (idle ${age}s < ${IDLE_SECONDS}s) — kept warm"
    fi
  done
}

cmd_stop() {
  # Manual, immediate unload — stop now regardless of the idle window.
  local target="${1:-all}"
  local -a names
  if [[ "$target" == "all" ]]; then names=("${ALL_SERVICES[@]}"); else names=("$target"); fi
  local rc=0
  for name in "${names[@]}"; do
    if ! canonical "$name" >/dev/null 2>&1; then
      echo "unknown service: $name" >&2; rc=2; continue
    fi
    if [[ -e "$(trigger_for "$name")" ]] || healthy "$name"; then
      printf 'stop %s: %s\n' "$(canonical "$name")" "$(stop_one "$name")"
    else
      echo "stop $(canonical "$name"): already down"
    fi
  done
  return "$rc"
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

# Install/refresh the stable .app copy whose helper binaries the plists run.
# Point it at a freshly packaged / try-pr'd / released bundle; the helpers must
# be from a packaged (xcodebuild) build so their Metal kernels load. Copies with
# `ditto` (preserves the bundle's code signature) into a temp sibling, then
# swaps via mv-aside + mv-in — not a single atomic rename, so the path is
# briefly absent; an already-running server keeps serving its open copy, and a
# concurrent launchd cold-start in that window just retries on the next ensure.
cmd_install_helpers() {
  local src="${1:-}"
  if [[ -z "$src" ]]; then
    echo "install-helpers: usage: lv-test-servers.sh install-helpers <path-to-.app>" >&2
    return 2
  fi
  src="${src%/}"
  if [[ ! -d "$src" ]]; then
    echo "install-helpers: source app not found: $src" >&2
    return 1
  fi
  local speechd_bin="$src/Contents/MacOS/localvoxtral-speechd"
  local polishd_bin="$src/Contents/MacOS/localvoxtral-polishd"
  if [[ ! -x "$speechd_bin" || ! -x "$polishd_bin" ]]; then
    cat >&2 <<MSG
install-helpers: $src is missing a bundled helper binary.
Expected both:
  $speechd_bin
  $polishd_bin
Package with helpers first (scripts/package_app.sh release, or a CI artifact via
scripts/try-pr.sh) — a bundle built with LOCALVOXTRAL_SKIP_SPEECHD/POLISHD=1 will
not contain them.
MSG
    return 1
  fi

  local dest_dir tmp
  dest_dir="$(dirname "$STABLE_APP")"
  if ! mkdir -p "$dest_dir" 2>/dev/null; then
    echo "install-helpers: cannot create $dest_dir (need: sudo install -d -m 0755 -o \"\$(id -un)\" $dest_dir)" >&2
    return 1
  fi
  tmp="${STABLE_APP}.new.$$"
  rm -rf "$tmp" 2>/dev/null || true
  echo "install-helpers: copying $src -> $STABLE_APP"
  if ! ditto "$src" "$tmp"; then
    echo "install-helpers: ditto copy failed" >&2
    rm -rf "$tmp" 2>/dev/null || true
    return 1
  fi
  rm -rf "${STABLE_APP}.old.$$" 2>/dev/null || true
  if [[ -e "$STABLE_APP" ]]; then
    # A swallowed mv-aside would make the next mv nest the new bundle INSIDE
    # the old one (mv dir existing-dir), leaving the plist path serving the old
    # binary while looking freshly installed. Fail loudly instead.
    if ! mv "$STABLE_APP" "${STABLE_APP}.old.$$"; then
      echo "install-helpers: cannot move aside existing $STABLE_APP (permissions? root-owned from an earlier sudo?)" >&2
      rm -rf "$tmp" 2>/dev/null || true
      return 1
    fi
  fi
  mv "$tmp" "$STABLE_APP"
  rm -rf "${STABLE_APP}.old.$$" 2>/dev/null || true
  echo "install-helpers: installed. Restart the services to pick it up:"
  echo "  lv-test-servers.sh stop all   # next ensure cold-starts from the new copy"
}

usage() {
  cat >&2 <<'MSG'
usage: lv-test-servers.sh <ensure [speechd|polishd|all] | stop [speechd|polishd|all]
                            | reap | status | install-helpers <path-to-.app>>
  ensure  start (if down) and block until the named server(s) are warm;
          resets the idle window. Default target: all.
  stop    unload the named server(s) NOW regardless of the idle window, freeing
          the weights (block until the port closes; TERM→KILL). Default: all.
  reap    stop any server idle longer than the idle window (reaper LaunchAgent;
          must run as the run-dir owner).
  status  print trigger + activity + port health for both services.
  install-helpers  copy a packaged .app's helper binaries to the stable path
          the plists run ($LV_TEST_SERVER_APP; default
          /Users/Shared/localvoxtral/testservers/localvoxtral.app).

  Service names: speechd (8000, realtime STT) and polishd (8080, chat
  completions). The retired names voxmlx/mlxlm are accepted as deprecated
  aliases during the migration.
MSG
}

case "${1:-}" in
  ensure) shift; cmd_ensure "${1:-all}" ;;
  stop)   shift; cmd_stop "${1:-all}" ;;
  reap)   cmd_reap ;;
  status) cmd_status ;;
  install-helpers) shift; cmd_install_helpers "${1:-}" ;;
  ""|-h|--help) usage; exit 2 ;;
  *) echo "unknown command: $1" >&2; usage; exit 2 ;;
esac
