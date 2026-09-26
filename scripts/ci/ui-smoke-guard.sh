#!/usr/bin/env bash
# ui-smoke-guard.sh — decide whether the owner's UI Smoke dispatch on main
# runs the e2e dictation check (scripts/e2e-dictation.sh) on the self-hosted
# Mac, or skips green.
#
# The owner starts that run himself when the Mac is free (ui-smoke.yml has no
# schedule since 2026-09-26: GitHub cron started up to an hour late and took
# the Mac at unpredictable times). The guard catches a mistimed dispatch,
# e.g. one tapped from the phone before getting home:
#
#   skip — the runner (the owner's MacBook) is on battery power
#          (ac-power-guard.sh, shared with eval-e2e.yml's guard)
#   skip — the console session is locked, or there is no GUI session: no
#          window can be presented, so every interaction fails as a false
#          red (run 29722553773 is the reference failure)
#   run  — otherwise. Probe errors fail OPEN: an uncomputable state must
#          never silently disable the lane (same philosophy as the CI lane
#          filters).
#
# Branch dispatches (scripts/ui-smoke-dispatch.sh) and the needs-ui-smoke
# label do not consult this guard: they are a PR asking for a result.
#
# Output (GitHub-output style on stdout):
#   run=true|false
#   reason=<one line>
#
# Test seams (see test-ui-smoke-guard.sh):
#   UI_SMOKE_GUARD_LOCK_STATE                locked|unlocked|no-session|error
#   AC_POWER_GUARD_STATE                     ac|battery|error (passed through)
set -euo pipefail

# Power first: the cheapest probe, and unplugged trumps everything else — the
# run must not cost the battery a packaging build plus the dictation (owner
# request, 2026-07-24).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
power_decision="$("$SCRIPT_DIR/ac-power-guard.sh")"
if [[ "$(sed -n 's/^run=//p' <<<"$power_decision")" == "false" ]]; then
  echo "$power_decision"
  exit 0
fi

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

state="$(lock_state)"
case "$state" in
  locked | no-session)
    echo "run=false"
    echo "reason=screen is $state — e2e dictation would false-red; dispatch again with the Mac unlocked"
    ;;
  unlocked)
    echo "run=true"
    echo "reason=screen unlocked"
    ;;
  *)
    echo "run=true"
    echo "reason=lock probe unavailable ($state) — failing open"
    ;;
esac
