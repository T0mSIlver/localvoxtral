#!/usr/bin/env bash
set -euo pipefail

# localvoxtral build gate v4.
#
# This script is intended to be installed as the forced command for the Mac
# build-host SSH key. It keeps the existing build/test/package allowlist and
# adds read-only diagnostics and scoped interrupted-test recovery without
# granting an interactive shell.
#
# Gate v2 install notes: see scripts/mac/README.md. Install from a trusted
# owner session, not through this gate. New diagnostic verbs allowed through
# the gate:
#   diag
#   applog [minutes]    # integer, clamped to 1..120, default 10
#   voxlog [lines]      # integer, clamped to 1..500, default 80
#   svc-status
#   ensure <speechd|polishd|all>  # warm an on-demand test server (touch + poll;
#                                 # retired voxmlx/mlxlm names accepted as aliases)
#   reap work/localvoxtral-<id>  # terminate stale tests in one exact work dir
#   disk                # df + per-work-dir du (du can take a while — on demand)
#   gc                  # delete work dirs unused > LV_GC_MAX_AGE_DAYS (v4)

LOG_FILE="$HOME/Library/Logs/localvoxtral-build-gate.log"
# `voxlog` tails the STT test-service log. Post-migration the on-demand STT
# service is the bundled Swift speechd (com.localvoxtral.testspeechd,
# StandardOutPath /Users/Shared/localvoxtral/speechd.log); the owner points
# VOXLOG_FILE at it in ~/.localvoxtral-gate.conf. The default keeps the retired
# voxmlx.log so an un-reconfigured gate still finds something.
VOXLOG_FILE="$HOME/Library/Logs/voxmlx.log"
# launchctl labels the STT/polish TEST services may be loaded under: the new
# bundled-helper plists (testspeechd/testpolishd) and the retired Python ones
# (voxmlx/mlxlm). svc-status prints whichever the owner's domain actually holds.
TEST_SERVICE_LABELS=(com.localvoxtral.testspeechd com.localvoxtral.testpolishd \
  com.localvoxtral.voxmlx com.localvoxtral.mlxlm)
# The GUI-session uid whose launchd domain hosts the test services. The gate
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
REAPER="$HOME/bin/localvoxtral-cleanup-stale-test-processes.sh"

# Work-dir garbage collection (`gc` verb): every ephemeral Linux worktree
# mints one ~/work/localvoxtral-* dir (remote-build.sh derives the name from
# the local checkout path) and nothing else ever deletes them, so stale
# multi-GB SwiftPM/xcodebuild trees accumulate until the disk fills. A dir
# whose newest activity is older than this many days is reclaimed.
LV_GC_MAX_AGE_DAYS=14

# Every gated use of a work dir refreshes this stamp file at its root, so gc
# staleness never depends on rsync-preserved source mtimes (rsync -a copies
# the SENDER's mtimes — a tree synced five minutes ago can look weeks old
# without it). remote-build.sh protects the stamp from its rsync --delete.
LV_LAST_USED_STAMP=".lv-last-used"

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
  printf 'gui/%s/%s\n' "$VOXMLX_GUI_UID" "$1"
}

# BSD stat on the Mac; GNU stat only so the shell regression tests can run on
# a Linux dev box. GNU must be tried FIRST: BSD's -f flag exists on GNU too
# but means "filesystem status" there, succeeding with a mount point instead
# of an mtime — while -c fails cleanly on BSD.
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Epoch seconds -> a `touch -t` timestamp. BSD `date -r <epoch>` on the Mac;
# GNU date treats -r as --reference=<file> and fails, so -d "@epoch" answers.
touch_timestamp_for_epoch() {
  date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S
}

touch_workdir_stamp() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    touch "$dir/$LV_LAST_USED_STAMP" 2>/dev/null || true
  fi
}

format_kib() {
  awk -v kb="$1" 'BEGIN {
    if (kb >= 1048576) printf "%.1f GiB", kb / 1048576
    else printf "%d MiB", kb / 1024
  }'
}

# Both BSD and GNU `df -k` print Available in column 4 and Capacity/Use% in
# column 5. mac-health.sh greps this exact line prefix — keep it stable.
# Never let a df hiccup abort diag under set -e: mac-health would misread the
# resulting non-zero ssh exit as "build host unreachable".
show_disk_free_line() {
  df -k "$HOME" 2>/dev/null \
    | awk 'NR == 2 { printf "Data volume free: %d GiB (%s used)\n", $4 / 1048576, $5 }' \
    || true
}

show_disk_summary() {
  section "Disk"
  run_or_note df -h "$HOME"
  show_disk_free_line
  local dir now mtime age
  now="$(date +%s)"
  for dir in "$HOME"/work/localvoxtral-*; do
    [[ -d "$dir" ]] || continue
    mtime="$(file_mtime "$dir/$LV_LAST_USED_STAMP" || true)"
    if [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
      mtime="$(file_mtime "$dir" || true)"
    fi
    if [[ "$mtime" =~ ^[0-9]+$ ]]; then
      age="$(( (now - mtime) / 86400 ))d"
    else
      age="?"
    fi
    printf 'workdir %s last-used %s ago\n' "${dir##*/}" "$age"
  done
}

# `du` over multi-GB build trees can take a while, so sizes are a separate
# on-demand verb rather than part of diag (mac-health runs diag under a
# 20-second timeout).
run_disk_command() {
  show_disk_summary
  section "Build work dir sizes"
  local dir
  for dir in "$HOME"/work/localvoxtral-*; do
    [[ -d "$dir" ]] || continue
    run_or_note du -sh "$dir"
  done
}

# A work dir is "in use" when any of this account's live processes has its
# cwd or a mapped executable inside it — the same evidence the reaper trusts.
# Fail CLOSED: whenever lsof is missing OR did not run cleanly we cannot
# prove the dir idle, so gc keeps it. lsof exits non-zero both on errors and
# when it selects no files at all — but this account's own gate shell always
# contributes at least its cwd record, so a healthy run selects something
# and exits 0; a non-zero exit here genuinely means "evidence unavailable".
workdir_in_use() {
  local dir="$1" records
  command -v lsof >/dev/null 2>&1 || return 0
  records="$(lsof -n -P -u "$(id -u)" -a -d cwd,txt -F n 2>/dev/null)" || return 0
  awk -v prefix="n$dir" '
    index($0, prefix "/") == 1 || $0 == prefix { found = 1; exit }
    END { exit found ? 0 : 1 }' <<<"$records"
}

# Delete a stale work dir's contents but keep EvalRecordings: the rsync in
# remote-build.sh receiver-protects that subtree because private human WAVs
# may exist ONLY in this remote copy — reclaiming build state must never
# destroy them. The skeleton dir that remains is tiny and harmless.
prune_workdir_keep_recordings() {
  local dir="$1" entry
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    if [[ ! -e "$entry" && ! -L "$entry" ]]; then
      continue
    fi
    if [[ "${entry##*/}" == "EvalRecordings" ]]; then
      continue
    fi
    # An un-removable entry (foreign owner, odd perms) must not abort the
    # rest of the prune — or, via set -e, the whole gc pass.
    rm -rf "$entry" 2>/dev/null || true
  done
}

# Does the dir hold anything BESIDES EvalRecordings? An already-pruned
# skeleton fails this, so repeat gc passes neither re-prune it nor report it.
workdir_has_prunable_entries() {
  local dir="$1" entry
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    if [[ ! -e "$entry" && ! -L "$entry" ]]; then
      continue
    fi
    if [[ "${entry##*/}" == "EvalRecordings" ]]; then
      continue
    fi
    return 0
  done
  return 1
}

# Age-based garbage collection for ~/work/localvoxtral-* build dirs. Getting
# deletion wrong is asymmetric: a live or recent dir must never go, a stale
# one costs only a cold rebuild — so three independent checks each fail
# toward "keep": (1) any entry modified since the cutoff, down to the
# build-product level (the per-use stamp guarantees a fresh depth-1 mtime for
# every gated run; the find catches pre-stamp dirs whose builds rewrote
# .build metadata); (2) live processes rooted in the dir; (3) EvalRecordings
# presence downgrades delete to a prune that keeps the recordings.
run_gc_command() {
  local max_age_days="$LV_GC_MAX_AGE_DAYS"
  if [[ ! "$max_age_days" =~ ^[1-9][0-9]*$ ]]; then
    printf 'gc: invalid LV_GC_MAX_AGE_DAYS: %s\n' "$max_age_days" >&2
    return 1
  fi
  local now cutoff ref dir recent size_kb remaining_kb
  local deleted=0 pruned=0 kept_active=0 kept_busy=0 freed_kb=0
  now="$(date +%s)"
  cutoff=$((now - max_age_days * 86400))
  ref="$(mktemp "${TMPDIR:-/tmp}/lv-gc-cutoff.XXXXXX")" || return 1
  touch -t "$(touch_timestamp_for_epoch "$cutoff")" "$ref" || { rm -f "$ref"; return 1; }

  for dir in "$HOME"/work/localvoxtral-*; do
    [[ -d "$dir" ]] || continue
    validate_work_dir "work/${dir##*/}" || continue
    # -mindepth 1 skips the dir's own mtime, which gc's pruning refreshes —
    # a pruned skeleton must not look active for another whole window.
    # -maxdepth 9 reaches the deepest build products (xcodebuild packages:
    # .build/xcode/Build/Products/Release/<app>/Contents/MacOS/<bin> is depth
    # 8; an incremental rebuild overwrites files there without bumping any
    # shallower dir mtime). -quit bounds the cost at the first fresh entry.
    recent="$(find "$dir" -mindepth 1 -maxdepth 9 -newer "$ref" -print -quit 2>/dev/null || true)"
    if [[ -n "$recent" ]]; then
      kept_active=$((kept_active + 1))
      continue
    fi
    if workdir_in_use "$dir"; then
      printf 'gc %s: stale but has live processes — kept\n' "${dir##*/}"
      kept_busy=$((kept_busy + 1))
      continue
    fi
    size_kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')" || size_kb=""
    [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
    if [[ -e "$dir/EvalRecordings" ]]; then
      # Already-pruned skeletons stay silent — reporting "pruned" every run
      # for a dir holding only recordings would misread as repeated action.
      workdir_has_prunable_entries "$dir" || continue
      prune_workdir_keep_recordings "$dir"
      remaining_kb="$(du -sk "$dir" 2>/dev/null | awk '{print $1}')" || remaining_kb=""
      [[ "$remaining_kb" =~ ^[0-9]+$ ]] || remaining_kb=0
      if (( size_kb > remaining_kb )); then
        freed_kb=$((freed_kb + size_kb - remaining_kb))
      fi
      printf 'gc %s: unused >= %sd — pruned (EvalRecordings kept)\n' \
        "${dir##*/}" "$max_age_days"
      pruned=$((pruned + 1))
    else
      # An un-removable entry must not abort the pass; whatever survived
      # will be reported (and retried) by later runs.
      rm -rf "$dir" 2>/dev/null || true
      freed_kb=$((freed_kb + size_kb))
      printf 'gc %s: unused >= %sd — deleted (%s)\n' \
        "${dir##*/}" "$max_age_days" "$(format_kib "$size_kb")"
      deleted=$((deleted + 1))
    fi
  done
  rm -f "$ref"
  printf 'gc: deleted %d, pruned %d, active %d, busy %d, freed ~%s\n' \
    "$deleted" "$pruned" "$kept_active" "$kept_busy" "$(format_kib "$freed_kb")"
  show_disk_free_line
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
  # localvoxtral(-speechd/-polishd) are the bundled Swift helpers (the current
  # test services); voxmlx-serve / mlx_lm.server are the retired Python ones,
  # kept so a pre-migration host still reports.
  for process in localvoxtral localvoxtral-speechd localvoxtral-polishd voxmlx-serve mlx_lm.server; do
    printf -- '-- %s --\n' "$process"
    if command -v pgrep >/dev/null 2>&1; then
      case "$process" in
        localvoxtral) pattern='(^|/)localvoxtral( |$)' ;;
        localvoxtral-speechd) pattern='(^|/)localvoxtral-speechd( |$)' ;;
        localvoxtral-polishd) pattern='(^|/)localvoxtral-polishd( |$)' ;;
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
  # 8000 = speechd test service (STT), 8080 = polishd test service (eval),
  # 8471/8472 = app-managed speechd/polishd.
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
  local lines="$1" label

  if ! command -v launchctl >/dev/null 2>&1; then
    section "launchctl test services"
    printf 'launchctl: not found\n'
    return
  fi
  # launchctl print cannot read another user's GUI domain, so most of these
  # come back empty from the gate account — processes/ports (below in
  # svc-status/diag) are the real signal. Print each candidate label so
  # whichever generation is loaded in the owner's domain is visible.
  for label in "${TEST_SERVICE_LABELS[@]}"; do
    section "launchctl ${label}"
    (launchctl print "$(launchctl_target "$label")" 2>&1 || true) | head -n "$lines"
  done
}

show_voxlog() {
  local lines="$1"

  section "STT service log (${VOXLOG_FILE##*/})"
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
  show_disk_summary
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
# The current names are speechd/polishd; voxmlx/mlxlm are deprecated aliases.
# The trigger/stamp filesystem KEYS stay at the retired names (voxmlx.want /
# mlxlm.want) so this gate and the newly-bootstrapped testspeechd/testpolishd
# plists rendezvous on the same paths (see lv-test-servers.sh header).
lv_service_canonical() {
  case "$1" in
    speechd|voxmlx) printf 'speechd\n' ;;
    polishd|mlxlm)  printf 'polishd\n' ;;
    *) return 1 ;;
  esac
}
lv_service_fskey() {
  case "$(lv_service_canonical "$1" 2>/dev/null)" in
    speechd) printf 'voxmlx\n' ;;
    polishd) printf 'mlxlm\n' ;;
    *) return 1 ;;
  esac
}
lv_service_trigger() {
  local key
  key="$(lv_service_fskey "$1")" || return 1
  printf '%s/%s.want\n' "$LV_RUN_DIR" "$key"
}
lv_service_port() {
  case "$(lv_service_canonical "$1" 2>/dev/null)" in
    speechd) printf '8000\n' ;;
    polishd) printf '8080\n' ;;
    *) return 1 ;;
  esac
}
lv_service_healthy() {
  # speechd (8000): TCP accept (model loads before the listener binds, no HTTP
  #   route) — same signal the retired voxmlx uvicorn gave.
  # polishd (8080): GET /health once the model is resident. Accept /v1/models
  #   too so the probe is correct against BOTH the new polishd and the retired
  #   mlx-lm behind the port. NOTE: an INSTALLED gate only gains the /health arm
  #   when the owner reinstalls it (scripts/mac/README.md) — until then it
  #   probes /v1/models only, so `ensure polishd` against a swapped-in polishd
  #   times out (best-effort; the eval itself still reaches /v1/chat/completions).
  local name="$1" port
  port="$(lv_service_port "$name")" || return 1
  case "$(lv_service_canonical "$name" 2>/dev/null)" in
    speechd)
      nc -z -G "$LV_ENSURE_PROBE_TIMEOUT" -w "$LV_ENSURE_PROBE_TIMEOUT" \
        127.0.0.1 "$port" >/dev/null 2>&1
      ;;
    polishd)
      curl -fsS -o /dev/null --max-time "$LV_ENSURE_PROBE_TIMEOUT" \
        "http://127.0.0.1:${port}/health" >/dev/null 2>&1 \
      || curl -fsS -o /dev/null --max-time "$LV_ENSURE_PROBE_TIMEOUT" \
        "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

ensure_one_service() {
  local name="$1" cname trigger port stamp waited=0
  cname="$(lv_service_canonical "$name")" || { printf 'ensure: unknown service %s\n' "$name" >&2; return 2; }
  trigger="$(lv_service_trigger "$cname")"
  port="$(lv_service_port "$cname")"
  stamp="$LV_RUN_DIR/$(lv_service_fskey "$cname").seen.$(id -u)"
  name="$cname"

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

  local label
  case "$name" in
    speechd) label="com.localvoxtral.testspeechd" ;;
    polishd) label="com.localvoxtral.testpolishd" ;;
    *) label="com.localvoxtral.test${name}" ;;
  esac
  printf 'ensure %s: NOT ready after %ss (port %s) — is %s bootstrapped and its model cached?\n' \
    "$name" "$LV_ENSURE_READY_TIMEOUT" "$port" "$label" >&2
  return 1
}

run_ensure_command() {
  local target="$1"
  case "$target" in
    speechd|polishd|voxmlx|mlxlm) ensure_one_service "$target" ;;
    all)
      local rc=0
      ensure_one_service speechd || rc=$?
      ensure_one_service polishd || rc=$?
      return "$rc"
      ;;
    *) deny ;;
  esac
}

run_reap_command() {
  local dir="$1"
  validate_work_dir "$dir" || deny
  if [[ ! -x "$REAPER" ]]; then
    printf 'reap: installed helper missing: %s\n' "$REAPER" >&2
    return 1
  fi
  "$REAPER" "$HOME/${dir%/}"
}

# The forced-command SSH session used to `exec bash -c` directly. When the
# client disappeared (Ctrl-C, agent output ceiling, network loss), SwiftPM's
# xctest descendants could outlive ssh for hours on the persistent Mac. Run
# every allowed payload in its own process group so the gate can terminate
# exactly that invocation without touching the owner's tests or another
# agent's worktree.
LV_GATE_PAYLOAD_PID=""
LV_GATE_PAYLOAD_PGID=""

payload_group_is_alive() {
  [[ -n "$LV_GATE_PAYLOAD_PGID" ]] \
    && kill -0 -- "-$LV_GATE_PAYLOAD_PGID" 2>/dev/null
}

terminate_payload_group() {
  local polls="${LOCALVOXTRAL_GATE_TERM_POLLS:-50}"
  local poll_seconds="${LOCALVOXTRAL_GATE_TERM_POLL_SECONDS:-0.1}"
  local poll=0

  if payload_group_is_alive; then
    kill -TERM -- "-$LV_GATE_PAYLOAD_PGID" 2>/dev/null || true
    while (( poll < polls )) && payload_group_is_alive; do
      sleep "$poll_seconds"
      poll=$((poll + 1))
    done
    if payload_group_is_alive; then
      kill -KILL -- "-$LV_GATE_PAYLOAD_PGID" 2>/dev/null || true
    fi
  fi
  if [[ -n "$LV_GATE_PAYLOAD_PID" ]]; then
    wait "$LV_GATE_PAYLOAD_PID" 2>/dev/null || true
  fi
  LV_GATE_PAYLOAD_PID=""
  LV_GATE_PAYLOAD_PGID=""
}

run_payload_with_cleanup() {
  local payload="$1" status=0 monitor_was_enabled=0

  [[ "${LOCALVOXTRAL_GATE_TERM_POLLS:-50}" =~ ^[0-9]+$ ]] || deny
  case "$-" in
    *m*) monitor_was_enabled=1 ;;
  esac

  # Monitor mode gives each background job a distinct process group even in
  # this non-interactive Bash 3.2 shell. The PGID is the first child's PID.
  set -m
  /bin/bash -c "$payload" &
  LV_GATE_PAYLOAD_PID=$!
  LV_GATE_PAYLOAD_PGID=$LV_GATE_PAYLOAD_PID
  (( monitor_was_enabled == 1 )) || set +m

  # Signal handlers exit with conventional shell statuses; EXIT owns the one
  # cleanup path. PIPE matters because stdout is `ssh | tee` on the client.
  trap 'status=$?; trap - EXIT HUP INT TERM PIPE; terminate_payload_group; exit "$status"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 141' PIPE

  if wait "$LV_GATE_PAYLOAD_PID"; then
    status=0
  else
    status=$?
  fi
  # The leader can exit on SIGPIPE while an xctest grandchild remains in the
  # group. Always drain the group, even when the leader reported success.
  terminate_payload_group
  trap - EXIT HUP INT TERM PIPE
  return "$status"
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
  local integration_prefix="env VLLM_REALTIME_TEST_ENABLE=1 VLLM_REALTIME_TEST_MODEL=T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead swift test --filter RealtimeAPIVLLMIntegrationTests"

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
  touch_workdir_stamp "$PWD"
  run_payload_with_cleanup "$payload"
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
  touch_workdir_stamp "$HOME/${dir%/}"
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

  touch_workdir_stamp "$HOME/${dest%/}"
  cd "$HOME"
  exec rsync "${argv[@]:1}"
}

# Shell regression tests source the reviewed implementation directly. This
# variable cannot cross the forced-command SSH boundary, where the environment
# is fixed by sshd; it only suppresses dispatch in a local test process.
if [[ "${LOCALVOXTRAL_BUILD_GATE_SOURCE_ONLY:-0}" == "1" ]]; then
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
  fi
  exit 0
fi

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
  disk)
    run_disk_command
    ;;
  gc)
    run_gc_command
    ;;
  ensure\ *)
    arg="${original_command#ensure }"
    [[ "$arg" != *" "* && -n "$arg" ]] || deny
    run_ensure_command "$arg"
    ;;
  reap\ work/localvoxtral-*)
    arg="${original_command#reap }"
    [[ "$arg" != *" "* && -n "$arg" ]] || deny
    run_reap_command "$arg"
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
