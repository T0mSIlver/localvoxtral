#!/usr/bin/env bash
# ui-smoke-guard.sh — decide whether a SCHEDULED slot runs the e2e dictation
# check (scripts/e2e-dictation.sh) on the self-hosted Mac.
#
# The check drives windows in the owner's GUI session: on a locked screen no
# window can be presented, so every interaction fails as a false red (nightly
# run 29722553773 is the reference failure, from when the AX drill ran here
# too). The lane is therefore scheduled as an evening retry ladder, and each
# slot decides:
#
#   skip — the runner (the owner's MacBook) is on battery power
#          (ac-power-guard.sh, shared with eval-e2e.yml's nightly guard)
#   skip — a run whose dictation was scored in the recent window (the day is
#          covered; later slots stay green no-ops)
#   skip — the console session is locked, or there is no GUI session
#   run  — otherwise. Probe/API errors fail OPEN: an uncomputable state must
#          never silently disable the lane (same philosophy as the CI lane
#          filters).
#
# Run-level status is NOT enough for the coverage rule: a guard-skipped slot
# also concludes `success` (skipped steps never fail a job), so counting any
# successful run would let a locked 18:00 slot suppress the 19:30 and 21:00
# retries — the exact failure the ladder exists to avoid (PR #158 review
# finding). Candidate runs therefore only count when their "E2E dictation
# scored" marker step concluded `success`. The dictation step itself also
# concludes `success` when the Mac could not run it (exit 3 on a schedule),
# so it cannot answer that. The query reads `completed` runs, not `success`
# ones: a dictation that passed counts on an evening when the hosted AX drill
# in the same run was red.
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
# build plus the dictation (owner request, 2026-07-24).
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

# Must match the step name in ui-smoke.yml exactly; renaming one without the
# other makes every run look like a skip, which fails open into (at worst) an
# extra run — never a silent permanent skip.
E2E_STEP="E2E dictation scored"

# Age in seconds of the most recent run whose $E2E_STEP step concluded
# `success`; empty when none is found among the last 10 completed runs (10
# covers several evenings of pure guard-skips before a real run).
last_success_age_seconds() {
  local override="${UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS:-}"
  if [[ -n "$override" ]]; then
    if [[ "$override" == "none" ]]; then
      echo ""
    else
      echo "$override"
    fi
    return
  fi
  local runs
  runs="$(gh api \
    "repos/${GITHUB_REPOSITORY}/actions/workflows/ui-smoke.yml/runs?status=completed&per_page=10" \
    --jq '.workflow_runs[] | "\(.id)\t\(.run_started_at)"' 2>/dev/null)" || runs=""
  if [[ -z "$runs" ]]; then
    echo ""
    return
  fi
  local id ts scored
  while IFS=$'\t' read -r id ts; do
    [[ -z "$id" || -z "$ts" ]] && continue
    scored="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${id}/jobs" \
      --jq "[.jobs[].steps[] | select(.name == \"${E2E_STEP}\") | .conclusion] | first // empty" \
      2>/dev/null)" || scored=""
    if [[ "$scored" == "success" ]]; then
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
  # The CGSessionCopyCurrentDictionary probe moved to screen-lock-state.sh so
  # the SSH UI gate (scripts/mac/localvoxtral-ui-gate.sh) shares it. This lane
  # keeps its own fail-OPEN policy below; the helper only reports.
  "$SCRIPT_DIR/screen-lock-state.sh" 2>/dev/null || echo "error"
}

age="$(last_success_age_seconds)"
if [[ -n "$age" && "$age" -lt "$RECENT_SUCCESS_WINDOW_SECONDS" ]]; then
  echo "run=false"
  echo "reason=e2e dictation ran and passed $((age / 3600)) h ago — today is already covered"
  exit 0
fi
state="$(lock_state)"
case "$state" in
  locked | no-session)
    echo "run=false"
    echo "reason=screen is $state — e2e dictation would false-red; the next slot retries"
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
