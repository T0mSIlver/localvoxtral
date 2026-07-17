#!/usr/bin/env bash
# Fixture for test-build-gate-process-cleanup.sh. Both processes ignore TERM
# so the gate's bounded KILL escalation is exercised deterministically.
set -euo pipefail

pid_fifo="$1"
mode="${2:-wait}"
trap '' TERM
/bin/bash -c 'trap "" TERM; exec sleep 300' &
stubborn_child=$!
printf '%s %s\n' "$$" "$stubborn_child" >"$pid_fifo"
if [[ "$mode" == "exit-leader" ]]; then
  exit 0
fi
wait "$stubborn_child"
