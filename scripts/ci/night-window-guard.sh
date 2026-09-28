#!/usr/bin/env bash
# night-window-guard.sh — decide whether a SCHEDULED self-hosted lane that
# runs inference may start now, based on the time of day.
#
# The runner is the owner's MacBook. Scheduled inference belongs in the night
# window, 00:00–07:00 UTC; after that the owner works on the machine. GitHub
# delays `schedule:` events by hours (#822: the 04:45 UTC Sunday eval-e2e was
# created at 09:33 and 09:48 UTC), so a cron inside the window does not keep
# the run inside it. The caller passes how long its job runs, and the guard
# skips unless the job can finish by 07:00 UTC.
#
# Dispatches are explicit intent and never consult this guard; that is the
# caller's `github.event_name == 'schedule'` condition.
#
# Usage: night-window-guard.sh [job-minutes]   (default 0)
#
# Output (GitHub-output style on stdout):
#   run=true|false
#   reason=<one line>
#
# Test seam (see test-night-window-guard.sh):
#   NIGHT_WINDOW_GUARD_NOW  HH:MM, UTC, in place of the clock
set -euo pipefail

WINDOW_END_MINUTE=$((7 * 60))

job_minutes="${1:-0}"
if [[ ! "$job_minutes" =~ ^[0-9]+$ ]]; then
  echo "night-window-guard.sh: job minutes must be a whole number, got '$job_minutes'" >&2
  exit 2
fi

now="${NIGHT_WINDOW_GUARD_NOW:-$(date -u +%H:%M)}"
if [[ ! "$now" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
  echo "night-window-guard.sh: bad time '$now', expected HH:MM" >&2
  exit 2
fi
# 10# keeps 08 and 09 from reading as bad octal.
now_minute=$((10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]}))
latest_start=$((WINDOW_END_MINUTE - job_minutes))
latest_start_text="$(printf '%02d:%02d' $((latest_start / 60)) $((latest_start % 60)))"

if (( latest_start < 0 )); then
  echo "run=false"
  echo "reason=a ${job_minutes}-minute job cannot fit in the 00:00–07:00 UTC night window"
elif (( now_minute <= latest_start )); then
  echo "run=true"
  echo "reason=started at $now UTC, inside the night window (00:00 to $latest_start_text UTC for this job)"
else
  echo "run=false"
  echo "reason=started at $now UTC, outside the night window (00:00 to $latest_start_text UTC for this job, which must end by 07:00)"
fi
