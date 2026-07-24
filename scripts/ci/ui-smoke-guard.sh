#!/usr/bin/env bash
# ui-smoke-guard.sh — decide whether a SCHEDULED ui-smoke slot should run.
#
# The AX smoke drill needs an unlocked GUI session: on a locked screen the
# menu bar stays readable but no window can be presented, so every
# settings-tab interaction fails as a false red (nightly run 29722553773 is
# the reference failure — menu reads PASS, all six tab selections FAIL).
# The lane is therefore scheduled as an evening retry ladder, and each slot
# decides:
#
#   skip — the runner (the owner's MacBook) is on battery power
#          (ac-power-guard.sh, shared with eval-e2e.yml's nightly guard)
#   skip — a run whose DRILL actually executed and passed completed in the
#          recent window (the day is covered; later slots stay green no-ops)
#   skip — the console session is locked, or there is no GUI session
#   run  — otherwise. Probe/API errors fail OPEN: an uncomputable state must
#          never silently disable the lane (same philosophy as the CI lane
#          filters).
#
# Run-level status is NOT enough for the first rule: a guard-skipped slot
# also concludes `success` (skipped steps never fail a job), so counting any
# `status=success` run would let a locked 18:00 slot suppress the 19:30 and
# 21:00 retries — the exact failure the ladder exists to avoid (PR #158
# review finding). Candidate runs therefore only count when their
# "Run AX UI smoke" step conclusion is `success`.
#
# Output (GitHub-output style on stdout):
#   run=true|false
#   reason=<one line>
#
# Test seams (see test-ui-smoke-guard.sh):
#   UI_SMOKE_GUARD_LOCK_STATE                locked|unlocked|no-session|error
#   UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS  integer, or "none"
#   AC_POWER_GUARD_STATE                     ac|battery|error (passed through)
set -euo pipefail

# Power first: the cheapest probe (no gh API calls), and unplugged trumps
# everything else — a scheduled slot must not cost the battery a packaging
# build plus the AX drill (owner request, 2026-07-24).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
power_decision="$("$SCRIPT_DIR/ac-power-guard.sh")"
if [[ "$(sed -n 's/^run=//p' <<<"$power_decision")" == "false" ]]; then
  echo "$power_decision"
  exit 0
fi

# 20 h: slots are ~90 min apart within one evening, and consecutive days'
# anchors are 24 h apart — a success at any slot today never suppresses
# tomorrow's first slot.
RECENT_SUCCESS_WINDOW_SECONDS=$((20 * 60 * 60))

# Age in seconds of the most recent run whose drill step actually passed;
# empty when none is found among the last 10 success-concluded runs (10
# covers several evenings of pure guard-skips before a real drill).
last_success_age_seconds() {
  if [[ -n "${UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS:-}" ]]; then
    if [[ "$UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS" == "none" ]]; then
      echo ""
    else
      echo "$UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS"
    fi
    return
  fi
  local runs
  runs="$(gh api \
    "repos/${GITHUB_REPOSITORY}/actions/workflows/ui-smoke.yml/runs?status=success&per_page=10" \
    --jq '.workflow_runs[] | "\(.id)\t\(.run_started_at)"' 2>/dev/null)" || runs=""
  if [[ -z "$runs" ]]; then
    echo ""
    return
  fi
  local id ts drill
  while IFS=$'\t' read -r id ts; do
    [[ -z "$id" || -z "$ts" ]] && continue
    # Step name must match ui-smoke.yml's drill step exactly; renaming one
    # without the other makes every run look like a skip, which fails open
    # into (at worst) an extra drill — never a silent permanent skip.
    drill="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${id}/jobs" \
      --jq '[.jobs[].steps[] | select(.name == "Run AX UI smoke") | .conclusion] | first // empty' \
      2>/dev/null)" || drill=""
    if [[ "$drill" == "success" ]]; then
      python3 - "$ts" <<'PY' || echo ""
import datetime
import sys

# GitHub timestamps are usually second-granular, but tolerate a fractional
# part rather than silently defeating the dedup on a ValueError.
ts = sys.argv[1]
if "." in ts:
    ts = ts.split(".", 1)[0] + "Z"
started = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
started = started.replace(tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
print(int((now - started).total_seconds()))
PY
      return
    fi
  done <<<"$runs"
  echo ""
}

lock_state() {
  if [[ -n "${UI_SMOKE_GUARD_LOCK_STATE:-}" ]]; then
    echo "$UI_SMOKE_GUARD_LOCK_STATE"
    return
  fi
  # CGSessionCopyCurrentDictionary needs a GUI session context (the runner is
  # a LaunchAgent in the console session, so it has one). The lock key is only
  # present, with value 1, while the screen is actually locked.
  swift - <<'SWIFT' 2>/dev/null || echo "error"
import CoreGraphics

guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
  print("no-session")
  exit(0)
}
print(session["CGSSessionScreenIsLocked"] != nil ? "locked" : "unlocked")
SWIFT
}

age="$(last_success_age_seconds)"
if [[ -n "$age" && "$age" -lt "$RECENT_SUCCESS_WINDOW_SECONDS" ]]; then
  echo "run=false"
  echo "reason=drill ran and passed $((age / 3600)) h ago — today is already covered"
  exit 0
fi

state="$(lock_state)"
case "$state" in
  locked | no-session)
    echo "run=false"
    echo "reason=screen is $state — the AX window drill would false-red; the next slot retries"
    ;;
  unlocked)
    echo "run=true"
    echo "reason=screen unlocked, no recent successful run"
    ;;
  *)
    echo "run=true"
    echo "reason=lock probe unavailable ($state) — failing open"
    ;;
esac
