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
#
# The lane holds a second check, the e2e dictation (scripts/e2e-dictation.sh),
# and it gets its OWN coverage answer (`e2e_run=`). One shared answer would be
# wrong both ways: a slot whose drill passed while the dictation could not run
# (STT server down at 18:00) would end the evening without a dictation, and a
# drill that is red for a standing reason would make all three slots take the
# keyboard for a dictation that already passed at the first. Power and lock
# decide both checks alike.
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
#   run=true|false          the AX smoke drill
#   reason=<one line>
#   e2e_run=true|false      the e2e dictation
#   e2e_reason=<one line>
#
# Test seams (see test-ui-smoke-guard.sh):
#   UI_SMOKE_GUARD_LOCK_STATE                locked|unlocked|no-session|error
#   UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS  integer, or "none"
#   UI_SMOKE_GUARD_LAST_E2E_SUCCESS_AGE_SECONDS  integer, or "none"
#   AC_POWER_GUARD_STATE                     ac|battery|error (passed through)
set -euo pipefail

# Power first: the cheapest probe (no gh API calls), and unplugged trumps
# everything else — a scheduled slot must not cost the battery a packaging
# build plus the AX drill (owner request, 2026-07-24).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
power_decision="$("$SCRIPT_DIR/ac-power-guard.sh")"
if [[ "$(sed -n 's/^run=//p' <<<"$power_decision")" == "false" ]]; then
  echo "$power_decision"
  echo "e2e_run=false"
  echo "e2e_reason=$(sed -n 's/^reason=//p' <<<"$power_decision")"
  exit 0
fi

# 20 h: slots are ~90 min apart within one evening, and consecutive days'
# anchors are 24 h apart — a success at any slot today never suppresses
# tomorrow's first slot.
RECENT_SUCCESS_WINDOW_SECONDS=$((20 * 60 * 60))

# The steps whose `success` conclusion means the check ran AND passed. Each
# must match ui-smoke.yml exactly; renaming one without the other makes every
# run look like a skip, which fails open into (at worst) an extra run — never
# a silent permanent skip. "E2E dictation scored" is a marker step that only
# runs when the dictation step scored every scenario: that step itself also
# concludes `success` when the Mac could not run it (exit 3 on a schedule).
DRILL_STEP="Run AX UI smoke"
E2E_STEP="E2E dictation scored"

# last_success_age_seconds <step-name> <runs-status> <override>
# Age in seconds of the most recent run whose <step-name> step concluded
# `success`; empty when none is found among the last 10 runs with
# <runs-status> (10 covers several evenings of pure guard-skips before a real
# run). The drill asks for `success` runs. The dictation asks for `completed`
# ones, because its pass must count on an evening when the drill was red.
last_success_age_seconds() {
  local step="$1" status="$2" override="$3"
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
    "repos/${GITHUB_REPOSITORY}/actions/workflows/ui-smoke.yml/runs?status=${status}&per_page=10" \
    --jq '.workflow_runs[] | "\(.id)\t\(.run_started_at)"' 2>/dev/null)" || runs=""
  if [[ -z "$runs" ]]; then
    echo ""
    return
  fi
  local id ts drill
  while IFS=$'\t' read -r id ts; do
    [[ -z "$id" || -z "$ts" ]] && continue
    drill="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${id}/jobs" \
      --jq "[.jobs[].steps[] | select(.name == \"${step}\") | .conclusion] | first // empty" \
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
  # The CGSessionCopyCurrentDictionary probe moved to screen-lock-state.sh so
  # the SSH UI gate (scripts/mac/localvoxtral-ui-gate.sh) shares it. This lane
  # keeps its own fail-OPEN policy below; the helper only reports.
  "$SCRIPT_DIR/screen-lock-state.sh" 2>/dev/null || echo "error"
}

state=""
probe_lock_once() {
  [[ -n "$state" ]] || state="$(lock_state)"
}

# decide <prefix> <what> <age>: prints <prefix>run= and <prefix>reason=.
decide() {
  local prefix="$1" what="$2" age="$3"
  if [[ -n "$age" && "$age" -lt "$RECENT_SUCCESS_WINDOW_SECONDS" ]]; then
    echo "${prefix}run=false"
    echo "${prefix}reason=$what ran and passed $((age / 3600)) h ago — today is already covered"
    return
  fi
  probe_lock_once
  case "$state" in
    locked | no-session)
      echo "${prefix}run=false"
      echo "${prefix}reason=screen is $state — $what would false-red; the next slot retries"
      ;;
    unlocked)
      echo "${prefix}run=true"
      echo "${prefix}reason=screen unlocked, no recent successful run"
      ;;
    *)
      echo "${prefix}run=true"
      echo "${prefix}reason=lock probe unavailable ($state) — failing open"
      ;;
  esac
}

decide "" "drill" \
  "$(last_success_age_seconds "$DRILL_STEP" success "${UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS:-}")"
decide "e2e_" "e2e dictation" \
  "$(last_success_age_seconds "$E2E_STEP" completed "${UI_SMOKE_GUARD_LAST_E2E_SUCCESS_AGE_SECONDS:-}")"
