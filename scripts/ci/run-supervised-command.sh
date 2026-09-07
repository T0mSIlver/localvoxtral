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
# Same rule for each forensic `lsof` (default 3 s): lsof over a busy user's
# whole process set is the one forensic command that scans hundreds of
# processes, so it gets its own cap rather than borrowing the sampler's.
lsof_polls="${LOCALVOXTRAL_SUPERVISOR_LSOF_POLLS:-30}"
[[ "$term_polls" =~ ^[0-9]+$ ]] || usage
[[ "$sample_polls" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$lsof_polls" =~ ^[1-9][0-9]*$ ]] || usage

mkdir -p "$(dirname "$log_file")"
: >"$log_file"
timeout_marker="${log_file}.timeout"
rm -f "$timeout_marker"

command_pid=""
command_pgid=""
# Comma-separated live pids of the supervised tree (descendants of the
# command pid UNION its process group), filled by the tree dump and read by
# the sampler: `swift test` puts xctest in a process group of its OWN, so a
# group-only sampler captured the idle driver and never the wedged runner
# (hosted hang, 2026-09-07 run 34161722328).
forensic_tree_pids=""
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

# One bounded run of ANY forensic command, appending its output to the log:
# the same kill-at-the-cap rule as sample_one_bounded. `lsof` over a user's
# whole process set is normally 1-3 s, but a wedged box must never turn the
# diagnostic into a second hang.
run_forensic_bounded() {
  local label="$1" forensic_pid waited=0
  shift
  ( "$@" ) >>"$log_file" 2>&1 &
  local forensic_pid=$!
  while kill -0 "$forensic_pid" 2>/dev/null && (( waited < lsof_polls )); do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$forensic_pid" 2>/dev/null; then
    kill -KILL -- "-$forensic_pid" 2>/dev/null || kill -KILL "$forensic_pid" 2>/dev/null || true
    echo "--- $runner killed at the ${lsof_polls}00 ms cap ---" >>"$log_file"
  fi
  wait "$forensic_pid" 2>/dev/null || true
}

# Cross-reference the ps snapshot file (arg 2) with the lsof -F scan on stdin
# and print, for every pipe that the supervised tree (candidate pids, arg 1)
# holds, every OTHER process still holding the same pipe. That outside holder
# is the leaked grandchild keeping the driver's read() from EOF - it may long
# since have escaped the process group and re-parented to launchd, so neither
# pgid nor ppid can find it; only the shared pipe identifier can.
#
# Linux note: its lsof names every pipe "pipe" (no unique handle), so distinct
# pipes are indistinguishable; a name held by more than eight outside pids is
# reported once as ambiguous instead of manufacturing false matches. macOS -
# the platform this forensics exists for - prints a unique 0x handle.
print_shared_pipe_holders() {
  local candidates_csv="$1" ps_file="$2"
  lsof -n -P -w -F pftn -u "$(id -u)" 2>/dev/null | awk -v cand=",${candidates_csv}," '
    FNR == NR {
      if ($1 ~ /^[0-9]+$/) {
        command = ""
        for (i = 6; i <= NF; i++) command = command (i > 6 ? " " : "") $i
        cmdline[$1] = command
      }
      next
    }
    /^p[0-9]+$/ { current = substr($0, 2); next }
    /^f[0-9]+$/ { fd = substr($0, 2); next }
    /^t[0-9A-Za-z]+$/ { type = substr($0, 2); next }
    /^n/ {
      name = substr($0, 2)
      if ((type == "PIPE" || type == "pipe") && fd != "" && current != "") {
        holders[name] = holders[name] "," current ":" fd
      }
      fd = ""; type = ""; name = ""
      next
    }
    END {
      for (pipe in holders) {
        count = split(holders[pipe], list, ",")
        in_tree = 0
        outside = ""
        split("", distinct)
        for (i = 1; i <= count; i++) {
          split(list[i], pair, ":")
          pid = pair[1]; pfd = pair[2]
          if (pid == "") continue
          if (index(cand, "," pid ",") > 0) {
            in_tree = 1
          } else {
            outside = outside " " pid " fd" pfd
            distinct[pid] = 1
          }
        }
        if (in_tree == 0) continue
        n_outside = 0
        for (pid in distinct) n_outside++
        if (n_outside > 8) {
          printf "pipe %s: ambiguous pipe name (%d outside holders) - not matched\n", pipe, n_outside
          continue
        }
        for (pid in distinct) {
          command = (pid in cmdline) ? cmdline[pid] : "<unknown command>"
          printf "pipe %s ALSO HELD OUTSIDE THE SUPERVISED TREE by pid %s: %s\n", pipe, pid, command
        }
        if (outside != "") printf "(fd detail:%s)\n", outside
      }
    }
  ' "$ps_file" -
}

# On timeout, BEFORE the samples: dump the process tree and the pipe holders.
#
# The 2026-09-06/07 hosted hangs (runs 34056383664, 34109063527): the log cut
# mid-test-case, xctest was already gone from the group, and swift-package sat
# for 12 more minutes with both libSwiftToolsSupport reader threads blocked in
# read() - the shape of "the test process died, but a grandchild that
# inherited its stdout/stderr still holds the pipe's write end, so the driver
# never sees EOF and `swift test` never returns". Sampling the survivor shows
# the symptom; this dump names the HOLDER:
#   1. a full ps snapshot (pid, ppid, pgid, stat, etime, command),
#   2. the supervised tree: every descendant of the command pid plus every
#      member of its process group, tagged - descendants survive a leaked
#      child even when the leader exited first,
#   3. lsof: the supervised tree's fd table, and every OTHER same-uid process
#      sharing a pipe with it - the leaked write-end holder, findable by
#      neither pgid nor ppid once re-parented, only by the pipe identifier.
dump_tree_and_pipes_for_forensics() {
  local root_pid="$1" group_id="$2" ps_out ps_file tree_out candidates_csv
  {
    echo ""
    echo "=== supervisor timeout forensics: process tree and pipes (root pid ${root_pid:-<gone>}, group ${group_id:-<none>}) ==="
  } >>"$log_file"
  if ! command -v ps >/dev/null 2>&1; then
    echo "=== supervisor process-tree forensics skipped: ps unavailable ===" >>"$log_file"
    return 0
  fi
  ps_out="$(ps -axo pid,ppid,pgid,stat,etime,command 2>/dev/null || true)"
  if [[ -z "$ps_out" ]]; then
    echo "=== supervisor process-tree forensics skipped: ps printed nothing ===" >>"$log_file"
    return 0
  fi

  # The supervised tree: descendants of the command pid (ppid-walk to
  # fixpoint) UNION the process group, each tagged. The candidate list for
  # the lsof pass is the same set.
  ps_file="${log_file}.forensic-ps"
  printf '%s\n' "$ps_out" >"$ps_file"
  tree_out="$(awk -v root="$root_pid" -v grp="$group_id" '
    $1 !~ /^[0-9]+$/ { next }
    {
      ppid[$1] = $2
      pgid[$1] = $3
      ids[++n] = $1
      # ps right-aligns the pid column, so short pids arrive with leading
      # blanks; strip them so every line reads "DESCENDANT <pid> ..." and a
      # reader (or a grep) can key on the pid without guessing the padding.
      line = $0
      sub(/^[ \t]+/, "", line)
      full[$1] = line
    }
    END {
      if (root in ppid) {
        reach[root] = 1
        changed = 1
        while (changed) {
          changed = 0
          for (i = 1; i <= n; i++) {
            p = ids[i]
            if (!(p in reach) && (ppid[p] in reach)) { reach[p] = 1; changed = 1 }
          }
        }
      } else {
        print "ROOT pid " root " is gone from the table - descendants may have re-parented; group and pipe evidence still apply"
      }
      out = ""
      for (i = 1; i <= n; i++) {
        p = ids[i]
        if (p in reach) {
          tag = (pgid[p] == grp) ? " [in pgroup]" : " [left pgroup]"
          print "DESCENDANT " full[p] tag
          out = out p ","
        } else if (pgid[p] == grp) {
          print "GROUP-ONLY " full[p]
          out = out p ","
        }
      }
      sub(/,$/, "", out)
      print out
    }
  ' "$ps_file")"
  candidates_csv="$(printf '%s\n' "$tree_out" | grep '^[0-9]' | tail -n 1 || true)"
  forensic_tree_pids="$candidates_csv"
  {
    echo "--- supervised tree (ps pid ppid pgid stat etime command) ---"
    printf '%s\n' "$tree_out" | grep -v '^[0-9]' || true
    echo "--- full ps snapshot ---"
    printf '%s\n' "$ps_out"
  } >>"$log_file"

  if ! command -v lsof >/dev/null 2>&1; then
    echo "=== supervisor pipe forensics skipped: lsof unavailable ===" >>"$log_file"
    rm -f "$ps_file"
    return 0
  fi
  if [[ -z "$candidates_csv" ]]; then
    echo "=== supervisor pipe forensics skipped: no live processes in the supervised tree ===" >>"$log_file"
    rm -f "$ps_file"
    return 0
  fi

  {
    echo "--- lsof fd table of the supervised tree (pids: $candidates_csv) ---"
  } >>"$log_file"
  run_forensic_bounded lsof lsof -n -P -w -p "$candidates_csv"
  {
    echo "--- processes sharing a pipe with the supervised tree (leak suspects) ---"
  } >>"$log_file"
  run_forensic_bounded lsof-pipe-scan print_shared_pipe_holders "$candidates_csv" "$ps_file"
  rm -f "$ps_file"
  return 0
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
    echo "=== supervisor timeout forensics: sampling process group $pgid (tree pids: ${forensic_tree_pids:-none}) ==="
  } >>"$log_file"
  # Order: xctest anywhere in the supervised tree first (the runner is the
  # process that hangs, and `swift test` parks it in its own process group),
  # then the rest of the tree, then the group. Capped at 3 samples.
  local tree_xctest="" tree_rest="" p
  for p in ${forensic_tree_pids//,/ }; do
    if [[ "$(ps -o comm= -p "$p" 2>/dev/null)" == *xctest* ]]; then
      tree_xctest="$tree_xctest $p"
    else
      tree_rest="$tree_rest $p"
    fi
  done
  for pid in $tree_xctest $tree_rest $(pgrep -g "$pgid" -x xctest 2>/dev/null; pgrep -g "$pgid" 2>/dev/null); do
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
  # Tree + pipe holders first: they are cheap, and they are the only evidence
  # that can NAME a holder which has already escaped the process group.
  dump_tree_and_pipes_for_forensics "$command_pid" "$command_pgid"
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
