#!/usr/bin/env bash
# Run one CI command with closed stdin, file-backed output, and an exact
# process-group timeout. Compatible with the Bash 3.2 shipped by macOS.
set -uo pipefail

usage() {
  echo "usage: $0 <timeout-seconds> <log-file> -- <command> [args...]" >&2
  exit 64
}

[[ $# -ge 4 ]] || usage
timeout_seconds="$1"
log_file="$2"
shift 2
[[ "$1" == "--" ]] || usage
shift
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || usage

term_polls="${LOCALVOXTRAL_SUPERVISOR_TERM_POLLS:-50}"
poll_seconds="${LOCALVOXTRAL_SUPERVISOR_TERM_POLL_SECONDS:-0.1}"
# Hard cap on each forensic `sample` (polls x 0.1 s; default 8 s): a sampler
# stuck on a badly wedged task must never postpone the kill it precedes.
sample_polls="${LOCALVOXTRAL_SUPERVISOR_SAMPLE_POLLS:-80}"
[[ "$term_polls" =~ ^[0-9]+$ ]] || usage
[[ "$sample_polls" =~ ^[1-9][0-9]*$ ]] || usage

mkdir -p "$(dirname "$log_file")"
: >"$log_file"
timeout_marker="${log_file}.timeout"
rm -f "$timeout_marker"

command_pid=""
command_pgid=""
watchdog_pid=""
watchdog_pgid=""
monitor_was_enabled=0

group_is_alive() {
  local pgid="$1"
  [[ -n "$pgid" ]] && kill -0 -- "-$pgid" 2>/dev/null
}

# On timeout, capture WHERE the command is stuck before killing it: the
# 2026-07-19/20 tier-0 hangs cost a blind rerun each because the group was
# killed with no stack evidence (the 07-19 NSAlert.runModal culprit was only
# found by hand-sampling a wedged xctest). Samples land in the log file,
# which CI already uploads as an artifact even on failure. xctest is sampled
# first (the interesting process for test hangs), then remaining group
# members, capped so forensics never delay the kill by more than ~10 s.
# One bounded sample: run the sampler in its own background group and kill
# it after sample_polls x 0.1 s. `sample` itself can stall on a badly wedged
# task, and an unbounded sampler here would postpone terminate_group —
# recreating the very blind hang this forensics exists to diagnose.
sample_one_bounded() {
  local pid="$1" sampler waited=0
  echo "--- sample pid $pid ($(ps -o ucomm= -p "$pid" 2>/dev/null || echo unknown)) ---" >>"$log_file"
  ( sample "$pid" 2 -mayDie 2>&1 ) >>"$log_file" 2>&1 &
  sampler=$!
  while kill -0 "$sampler" 2>/dev/null && (( waited < sample_polls )); do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$sampler" 2>/dev/null; then
    kill -KILL -- "-$sampler" 2>/dev/null || kill -KILL "$sampler" 2>/dev/null || true
    echo "--- sampler for pid $pid killed at the ${sample_polls}00 ms cap ---" >>"$log_file"
  fi
  wait "$sampler" 2>/dev/null || true
}

sample_group_for_forensics() {
  local pgid="$1" sampled=0 pid seen_pids=""
  [[ -n "$pgid" ]] || return 0
  command -v sample >/dev/null 2>&1 || return 0
  if ! command -v pgrep >/dev/null 2>&1; then
    echo "=== supervisor timeout forensics skipped: pgrep unavailable ===" >>"$log_file"
    return 0
  fi
  {
    echo ""
    echo "=== supervisor timeout forensics: sampling process group $pgid ==="
  } >>"$log_file"
  for pid in $(pgrep -g "$pgid" -x xctest 2>/dev/null; pgrep -g "$pgid" 2>/dev/null); do
    (( sampled >= 3 )) && break
    kill -0 "$pid" 2>/dev/null || continue
    case " $seen_pids " in *" $pid "*) continue ;; esac
    seen_pids="$seen_pids $pid"
    sample_one_bounded "$pid"
    sampled=$((sampled + 1))
  done
  return 0
}

terminate_group() {
  local pgid="$1" poll=0
  [[ -n "$pgid" ]] || return 0
  if group_is_alive "$pgid"; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
    while (( poll < term_polls )) && group_is_alive "$pgid"; do
      sleep "$poll_seconds"
      poll=$((poll + 1))
    done
    group_is_alive "$pgid" && kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
}

cleanup_owned_groups() {
  terminate_group "$watchdog_pgid"
  terminate_group "$command_pgid"
  [[ -z "$watchdog_pid" ]] || wait "$watchdog_pid" 2>/dev/null || true
  [[ -z "$command_pid" ]] || wait "$command_pid" 2>/dev/null || true
  watchdog_pid=""
  watchdog_pgid=""
  command_pid=""
  command_pgid=""
}

handle_signal() {
  local status="$1"
  trap - EXIT HUP INT TERM
  cleanup_owned_groups
  exit "$status"
}

trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
trap 'cleanup_owned_groups' EXIT

case "$-" in
  *m*) monitor_was_enabled=1 ;;
esac
set -m
"$@" </dev/null >"$log_file" 2>&1 &
command_pid=$!
command_pgid=$command_pid

(
  trap 'exit 0' HUP INT TERM
  if [[ -n "${LOCALVOXTRAL_SUPERVISOR_TIMEOUT_FIFO:-}" ]]; then
    read -r _ <"$LOCALVOXTRAL_SUPERVISOR_TIMEOUT_FIFO"
  else
    sleep "$timeout_seconds"
  fi
  # Sample BEFORE the marker/kill, and only mark the run as a timeout if the
  # group is still alive afterwards: forensics can take seconds, and a
  # command that finished naturally inside that window must keep its real
  # exit status instead of a mislabeled 124 (PR #160 review finding).
  group_is_alive "$command_pgid" || exit 0
  sample_group_for_forensics "$command_pgid"
  group_is_alive "$command_pgid" || exit 0
  : >"$timeout_marker"
  terminate_group "$command_pgid"
) &
watchdog_pid=$!
watchdog_pgid=$watchdog_pid
(( monitor_was_enabled == 1 )) || set +m

if wait "$command_pid"; then
  command_status=0
else
  command_status=$?
fi
command_pid=""

# Stop the timer first, then drain the whole command group. The leader may
# exit while an xctest descendant remains alive.
terminate_group "$watchdog_pgid"
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
watchdog_pgid=""
terminate_group "$command_pgid"
command_pgid=""

if [[ -f "$timeout_marker" ]]; then
  echo "Command exceeded ${timeout_seconds}s; final log output:" >&2
  tail -n 200 "$log_file" >&2 || true
  rm -f "$timeout_marker"
  trap - EXIT
  exit 124
fi

if (( command_status == 0 )); then
  echo "Command completed; final log output:"
  tail -n 40 "$log_file" || true
else
  echo "Command failed with status $command_status; final log output:" >&2
  tail -n 200 "$log_file" >&2 || true
fi

trap - EXIT
exit "$command_status"
