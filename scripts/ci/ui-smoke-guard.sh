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
#   skip — a successful ui-smoke run already completed in the recent window
#          (the day is covered; later slots stay green no-ops)
#   skip — the console session is locked, or there is no GUI session
#   run  — otherwise. Probe/API errors fail OPEN: an uncomputable state must
#          never silently disable the lane (same philosophy as the CI lane
#          filters).
#
# Output (GitHub-output style on stdout):
#   run=true|false
#   reason=<one line>
#
# Test seams (see test-ui-smoke-guard.sh):
#   UI_SMOKE_GUARD_LOCK_STATE                locked|unlocked|no-session|error
#   UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS  integer, or "none"
set -euo pipefail

# 20 h: slots are ~90 min apart within one evening, and consecutive days'
# anchors are 24 h apart — a success at any slot today never suppresses
# tomorrow's first slot.
RECENT_SUCCESS_WINDOW_SECONDS=$((20 * 60 * 60))

last_success_age_seconds() {
  if [[ -n "${UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS:-}" ]]; then
    if [[ "$UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS" == "none" ]]; then
      echo ""
    else
      echo "$UI_SMOKE_GUARD_LAST_SUCCESS_AGE_SECONDS"
    fi
    return
  fi
  local ts
  ts="$(gh api \
    "repos/${GITHUB_REPOSITORY}/actions/workflows/ui-smoke.yml/runs?status=success&per_page=1" \
    --jq '.workflow_runs[0].run_started_at // empty' 2>/dev/null)" || ts=""
  if [[ -z "$ts" ]]; then
    echo ""
    return
  fi
  python3 - "$ts" <<'PY' || echo ""
import datetime
import sys

started = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
started = started.replace(tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
print(int((now - started).total_seconds()))
PY
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
  echo "reason=successful ui-smoke run $((age / 3600)) h ago — today is already covered"
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
