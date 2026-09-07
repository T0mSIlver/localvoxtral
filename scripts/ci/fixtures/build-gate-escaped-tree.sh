#!/usr/bin/env bash
# Fixture for test-run-supervised-command.sh's tree forensics. The grandchild
# escapes into its OWN process group (POSIX setsid, the shape `xctest` takes
# under `swift test` on macOS), so group-scoped sampling can never see it -
# only the supervisor's ppid-walk tree can. Both processes ignore TERM so the
# timeout path (not signal handling) is what ends the run.
set -euo pipefail

pid_fifo="$1"
command -v perl >/dev/null 2>&1 || { echo "fixture requires perl" >&2; exit 64; }
trap '' TERM
perl -MPOSIX -e 'setsid or die "setsid failed"; exec "sleep", "300"' &
escaped_child=$!
/bin/bash -c 'trap "" TERM; exec sleep 300' &
stubborn_child=$!
printf '%s %s %s\n' "$$" "$stubborn_child" "$escaped_child" >"$pid_fifo"
wait "$stubborn_child" "$escaped_child"
