#!/usr/bin/env bash
# recent-run-guard.sh — decide whether a SCHEDULED run is still needed, or a
# run of the same workflow on main already covered it.
#
# The dev box's scheduler dispatches the Mac's scheduled inference at the
# cron's time, and the cron stays as the fallback because the scheduler's
# timers are not reliable (#822). Without this check a dispatch plus a cron
# that GitHub fires a little late would run the same half hour of inference
# twice. So the scheduled run skips when another run of this workflow on main
# succeeded, or is queued or in progress, within the last <hours>.
#
# A failed or cancelled run does not count: the cron then retries it. A
# failed query fails OPEN (runs): a second run in the night window costs less
# than a silently missing one.
#
# Usage: recent-run-guard.sh <workflow-file> <hours>
#   GITHUB_REPOSITORY and GITHUB_RUN_ID come from Actions; gh needs GH_TOKEN
#   with actions: read.
#
# Output (GitHub-output style on stdout):
#   run=true|false
#   reason=<one line>
#
# Test seams (see test-recent-run-guard.sh): gh on PATH, and
#   RECENT_RUN_GUARD_NOW  epoch seconds, in place of the clock
set -euo pipefail

if [[ $# -ne 2 || ! "$2" =~ ^[0-9]+$ ]]; then
  echo "usage: recent-run-guard.sh <workflow-file> <hours>" >&2
  exit 2
fi
workflow="$1"
hours="$2"
: "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}"
now="${RECENT_RUN_GUARD_NOW:-$(date -u +%s)}"

if ! runs="$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs?branch=main&per_page=20" 2>&1)"; then
  echo "run=true"
  echo "reason=could not list recent $workflow runs — failing open (${runs%%$'\n'*})"
  exit 0
fi

if ! covering="$(jq -r \
    --argjson now "$now" --argjson window "$((hours * 3600))" \
    --argjson self "$GITHUB_RUN_ID" '
  [.workflow_runs[]
   | select(.id != $self)
   | select((.created_at | fromdateiso8601) > ($now - $window))
   | select(.status != "completed" or .conclusion == "success")]
  | first
  | if . == null then "" else "\(.id) \(.event) \(.status) \(.conclusion // "-") \(.created_at)" end
' <<<"$runs" 2>&1)"; then
  echo "run=true"
  echo "reason=could not read recent $workflow runs — failing open (${covering%%$'\n'*})"
  exit 0
fi

if [[ -z "$covering" ]]; then
  echo "run=true"
  echo "reason=no $workflow run on main succeeded or is running in the last ${hours} h"
else
  read -r id event status conclusion created <<<"$covering"
  if [[ "$status" == "completed" ]]; then
    state="succeeded"
  else
    state="is $status"
  fi
  echo "run=false"
  echo "reason=run $id ($event, created $created) $state within the last ${hours} h"
fi
