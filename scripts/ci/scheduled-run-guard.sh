#!/usr/bin/env bash
# scheduled-run-guard.sh — decide whether a run of a Mac workflow that runs
# inference proceeds, chaining the three guards a scheduled run takes:
#
#   1. night-window-guard.sh <job-minutes>: GitHub fires crons hours late
#      (#822, #826), and the run must end by 07:00 UTC;
#   2. recent-run-guard.sh <workflow-file> <hours>: the dev box's scheduler
#      dispatches the run at the cron's time, so the cron is a fallback that
#      skips when a run on main already succeeded, or is queued or running;
#   3. ac-power-guard.sh: scheduled runs never drain the MacBook's battery.
#
# The first guard that says run=false decides. Any event other than
# `schedule` (a dispatch) is explicit intent and runs without consulting them.
#
# Usage: scheduled-run-guard.sh <workflow-file> <job-minutes> <hours>
#   GITHUB_EVENT_NAME comes from Actions; the guards read their own
#   environment (GITHUB_REPOSITORY, GITHUB_RUN_ID, GH_TOKEN).
#
# Output (GitHub-output style on stdout):
#   run=true|false
#   reason=<one line>
#
# Tested by test-scheduled-run-guard.sh through the guards' own seams.
set -euo pipefail

if [[ $# -ne 3 || ! "$2" =~ ^[0-9]+$ || ! "$3" =~ ^[0-9]+$ ]]; then
  echo "usage: scheduled-run-guard.sh <workflow-file> <job-minutes> <hours>" >&2
  exit 2
fi
workflow="$1"
job_minutes="$2"
hours="$3"
dir="$(cd "$(dirname "$0")" && pwd -P)"

if [[ "${GITHUB_EVENT_NAME:-}" != "schedule" ]]; then
  echo "run=true"
  echo "reason=dispatched by hand (${GITHUB_EVENT_NAME:-unknown event})"
  exit 0
fi

proceeds() { [[ "$(sed -n 's/^run=//p' <<<"$decision")" == "true" ]]; }
decision="$("$dir/night-window-guard.sh" "$job_minutes")"
if proceeds; then
  decision="$("$dir/recent-run-guard.sh" "$workflow" "$hours")"
fi
if proceeds; then
  decision="$("$dir/ac-power-guard.sh")"
fi
printf '%s\n' "$decision"
