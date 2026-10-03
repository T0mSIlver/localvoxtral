#!/usr/bin/env bash
# night-deadline.sh — keep a daily release that starts at night inside the
# night window while it waits on Apple's notary service (#1554).
#
# night-window-guard.sh decides whether a scheduled run may START. A release
# then waits on two notarizations bounded at 3 h each, far longer than the
# rest of the run, so no start-time budget fits: the run's worst case would
# skip every 03:15 release, and the typical case lets a slow Apple hold the
# Mac into the owner's day. So a daily release that starts inside the window
# gets a deadline, 07:00 UTC that day, and each notarization wait is cut to
# what is left of it. A wait cut short fails the run before the Tag step:
# nothing is tagged or published, and the next night tries again.
#
# Usage:
#   night-deadline.sh deadline
#     prints deadline=<epoch seconds of 07:00 UTC today> when now is inside
#     00:00–07:00 UTC, else `deadline=` (empty: the run is not night-bound).
#   night-deadline.sh timeout <deadline-epoch|""> <cap-minutes> <reserve-minutes>
#     prints the NOTARIZE_TIMEOUT for one wait, in minutes (`<n>m`): the cap
#     with no deadline, else the smaller of the cap and the minutes left
#     before the deadline less <reserve>, which is what the rest of the run
#     needs after this wait. Exits 1 with an ::error:: line when not one
#     minute is left.
#
# Test seam (see test-night-deadline.sh):
#   NIGHT_DEADLINE_NOW  epoch seconds, in place of the clock
set -euo pipefail

WINDOW_END_SECONDS=$((7 * 3600))

usage() {
  echo "usage: night-deadline.sh deadline | timeout <deadline-epoch|\"\"> <cap-minutes> <reserve-minutes>" >&2
  exit 2
}

now="${NIGHT_DEADLINE_NOW:-$(date -u +%s)}"
[[ "$now" =~ ^[0-9]+$ ]] || { echo "night-deadline.sh: bad NIGHT_DEADLINE_NOW '$now'" >&2; exit 2; }

case "${1:-}" in
  deadline)
    [[ $# -eq 1 ]] || usage
    # Epoch seconds count UTC days of exactly 86400 s.
    day_start=$((now - now % 86400))
    if (( now - day_start < WINDOW_END_SECONDS )); then
      echo "deadline=$((day_start + WINDOW_END_SECONDS))"
    else
      echo "deadline="
    fi
    ;;
  timeout)
    [[ $# -eq 4 ]] || usage
    deadline="$2" cap="$3" reserve="$4"
    [[ -z "$deadline" || "$deadline" =~ ^[0-9]+$ ]] || usage
    [[ "$cap" =~ ^[1-9][0-9]*$ && "$reserve" =~ ^[0-9]+$ ]] || usage
    if [[ -z "$deadline" ]]; then
      echo "${cap}m"
      exit 0
    fi
    left=$(( (deadline - now) / 60 - reserve ))
    if (( left < 1 )); then
      echo "::error::The night window ends at 07:00 UTC, $(( (deadline - now) / 60 )) min from now, and this run needs $reserve min after this wait. Nothing was tagged or published; the next night's release tries again." >&2
      exit 1
    fi
    echo "$(( left < cap ? left : cap ))m"
    ;;
  *)
    usage
    ;;
esac
