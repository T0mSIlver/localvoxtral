#!/usr/bin/env bash
# Fixture for test-build-gate-process-cleanup.sh. Both processes ignore TERM
# so the gate's bounded KILL escalation is exercised deterministically.
set -euo pipefail

pid_fifo="$1"
mode="${2:-wait}"
trap '' TERM
if [[ "$mode" == "escape-group" ]]; then
  # The child moves to a process group of its own, the way `swift test`
  # parks xctest: a descendant by ppid, invisible to group-keyed tools.
  perl -e '$SIG{TERM} = "IGNORE"; setpgrp(0, 0); exec "sleep", "300"' &
  stubborn_child=$!
  # Report the pids only once the child has actually moved: perl's startup
  # is a few ms, and a reader keyed on the group must not see the old one.
  for _ in $(seq 1 200); do
    [[ "$(ps -o pgid= -p "$stubborn_child" | tr -d '[:space:]')" == "$stubborn_child" ]] && break
    sleep 0.05
  done
else
  /bin/bash -c 'trap "" TERM; exec sleep 300' &
  stubborn_child=$!
fi
printf '%s %s\n' "$$" "$stubborn_child" >"$pid_fifo"
if [[ "$mode" == "exit-leader" ]]; then
  exit 0
fi
wait "$stubborn_child"
